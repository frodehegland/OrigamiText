import Foundation
import AppKit

nonisolated enum AuthorImportError: LocalizedError {
    case notALiquidDocument
    case notDownloadedFromICloud
    case noTextContent(members: [String])

    var errorDescription: String? {
        switch self {
        case .notALiquidDocument:
            "This does not look like an Author document (.liquid)."
        case .notDownloadedFromICloud:
            "This document hasn’t finished downloading from iCloud. A download was requested — try again in a moment."
        case .noTextContent(let members):
            members.isEmpty
                ? "No readable text was found in the document."
                : "No readable text was found. The document contains: \(members.prefix(30).joined(separator: ", "))"
        }
    }
}

/// Importer for Author (.liquid) documents. A `.liquid` document is a
/// package; its exact internal layout isn't publicly documented, so this
/// scans the whole package recursively and identifies content by sniffing
/// rather than relying on fixed file names:
///   1. RTFD sub-packages, read through the text system.
///   2. Any member whose bytes look like RTF, flat RTFD, or an archived
///      NSAttributedString (binary plist).
///   3. Text carried in JSON members, as a last resort.
/// Title/author metadata is scraped from JSON/plist members by key name.
nonisolated enum AuthorImporter {

    struct ImportResult: Sendable {
        let title: String
        let author: String?
        let body: [LiquidDoc.Paragraph]
        /// The knowledge layer, when the package carries one: Defined
        /// Concepts from Contents/glossary.json, spatial layouts from
        /// Contents/DynamicView.json, citation records (as BibTeX) from
        /// Contents/Citations.plist.
        var concepts: [LiquidDoc.Concept] = []
        var layouts: [LiquidDoc.Layout] = []
        var mapConnections: [LiquidDoc.MapConnection] = []
        var references: [LiquidDoc.Reference] = []
    }

    static func importDocument(at url: URL) throws -> ImportResult {
        guard url.pathExtension.lowercased() == "liquid" else {
            throw AuthorImportError.notALiquidDocument
        }
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw AuthorImportError.notALiquidDocument
        }

        var files: [URL] = []
        var rtfdPackages: [URL] = []
        var icloudPlaceholders: [URL] = []

        if isDirectory.boolValue {
            if let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey]) {
                for case let member as URL in enumerator {
                    let isMemberDirectory = (try? member.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                    if isMemberDirectory {
                        if member.pathExtension.lowercased() == "rtfd" {
                            rtfdPackages.append(member)
                            enumerator.skipDescendants()
                        }
                        continue
                    }
                    if member.lastPathComponent.hasSuffix(".icloud") {
                        icloudPlaceholders.append(member)
                    } else {
                        files.append(member)
                    }
                }
            }
        } else {
            files.append(url)
        }

        let memberNames = (files + rtfdPackages).map { relativeName(of: $0, in: url) }.sorted()
        #if DEBUG
        print("AuthorImporter: members of “\(url.lastPathComponent)”: \(memberNames.joined(separator: ", "))")
        #endif

        if files.isEmpty, rtfdPackages.isEmpty {
            if !icloudPlaceholders.isEmpty {
                try? fileManager.startDownloadingUbiquitousItem(at: url)
                throw AuthorImportError.notDownloadedFromICloud
            }
            throw AuthorImportError.noTextContent(members: [])
        }

        // Title/author metadata from any member that parses as JSON or plist.
        var metadata: [String: String] = [:]
        for file in files {
            guard let data = try? Data(contentsOf: file), !data.isEmpty, data.count < 5_000_000 else { continue }
            if let object = try? JSONSerialization.jsonObject(with: data) {
                scanMetadata(object, into: &metadata)
            } else if let object = try? PropertyListSerialization.propertyList(from: data, format: nil) {
                scanMetadata(object, into: &metadata)
            }
        }
        let title = metadata["title"] ?? url.deletingPathExtension().lastPathComponent
        let author = metadata["author"]

        // The knowledge layer travels whichever way the text arrives:
        // glossary, layouts, and the citation store.
        let knowledge = knowledgeLayer(in: url, files: files)

        func finish(_ body: [LiquidDoc.Paragraph]) -> ImportResult {
            ImportResult(title: title, author: author,
                         body: applyingSectionLevels(knowledge.sections, to: body),
                         concepts: knowledge.concepts, layouts: knowledge.layouts,
                         mapConnections: knowledge.connections,
                         references: knowledge.references)
        }

        // 1. RTFD sub-packages are the richest representation.
        for rtfd in rtfdPackages {
            if let attributed = try? NSAttributedString(url: rtfd, options: [:], documentAttributes: nil),
               hasText(attributed) {
                return finish(paragraphs(from: attributed))
            }
        }

        // 2. Any member whose content the text system recognizes.
        for file in files {
            if let attributed = readRichText(from: file), hasText(attributed) {
                return finish(paragraphs(from: attributed))
            }
        }

        // 3. Last resort: text carried inside a JSON member.
        for file in files {
            if let body = paragraphsFromJSON(file), !body.isEmpty {
                return finish(body)
            }
        }

        throw AuthorImportError.noTextContent(members: memberNames)
    }

    // MARK: - Rich text reading

    /// Identifies rich text by its leading bytes rather than file name, so
    /// unusual member names inside the package still get found.
    private static func readRichText(from file: URL) -> NSAttributedString? {
        guard let data = try? Data(contentsOf: file), !data.isEmpty else { return nil }

        if data.starts(with: Array("{\\rtf".utf8)) {
            return try? NSAttributedString(
                data: data, options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil)
        }
        if data.starts(with: Array("rtfd".utf8)) {
            return try? NSAttributedString(
                data: data, options: [.documentType: NSAttributedString.DocumentType.rtfd],
                documentAttributes: nil)
        }
        if data.starts(with: Array("bplist00".utf8)) {
            // Author may archive attributed text directly.
            return try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSAttributedString.self, from: data)
        }
        switch file.pathExtension.lowercased() {
        case "html", "htm":
            return try? NSAttributedString(
                data: data, options: [.documentType: NSAttributedString.DocumentType.html],
                documentAttributes: nil)
        case "txt", "text", "md", "markdown":
            return String(data: data, encoding: .utf8).map { NSAttributedString(string: $0) }
        default:
            return nil
        }
    }

    private static func hasText(_ attributed: NSAttributedString) -> Bool {
        !attributed.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Maps attributed-string paragraphs to Liquid paragraphs. The most
    /// common font size is body text; larger sizes become heading levels
    /// 1–3 in descending order.
    static func paragraphs(from attributed: NSAttributedString) -> [LiquidDoc.Paragraph] {
        struct RawParagraph {
            let text: String
            let pointSize: CGFloat
        }
        var raws: [RawParagraph] = []
        let full = attributed.string as NSString
        full.enumerateSubstrings(
            in: NSRange(location: 0, length: full.length),
            options: .byParagraphs
        ) { substring, range, _, _ in
            guard let substring else { return }
            let trimmed = substring.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            let font = attributed.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
            raws.append(RawParagraph(text: trimmed, pointSize: font?.pointSize ?? 0))
        }
        guard !raws.isEmpty else { return [] }

        var sizeCounts: [CGFloat: Int] = [:]
        for raw in raws {
            sizeCounts[raw.pointSize, default: 0] += 1
        }
        let bodySize = sizeCounts.max { $0.value < $1.value }?.key ?? 0
        let headingSizes = Set(raws.map(\.pointSize))
            .filter { $0 > bodySize + 0.5 }
            .sorted(by: >)

        func headingLevel(for size: CGFloat) -> Int? {
            guard let index = headingSizes.firstIndex(of: size), index < 3 else { return nil }
            return index + 1
        }

        return raws.enumerated().map { index, raw in
            var level = headingLevel(for: raw.pointSize)
            var text = raw.text
            // Literal markdown heading prefixes become structured headings.
            if let markdown = LiquidDoc.markdownHeading(in: text) {
                level = level ?? markdown.level
                text = markdown.text
            }
            return LiquidDoc.Paragraph(id: "p\(index + 1)", heading: level, text: text)
        }
    }

    // MARK: - JSON fallbacks

    private static func paragraphsFromJSON(_ url: URL) -> [LiquidDoc.Paragraph]? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        var texts: [String] = []
        collectTexts(object, into: &texts)
        var paragraphs: [LiquidDoc.Paragraph] = []
        for text in texts {
            for line in text.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                let markdown = LiquidDoc.markdownHeading(in: trimmed)
                paragraphs.append(LiquidDoc.Paragraph(id: "p\(paragraphs.count + 1)",
                                                      heading: markdown?.level,
                                                      text: markdown?.text ?? trimmed))
            }
        }
        return paragraphs
    }

    /// Collects likely body text from arbitrary JSON. Arrays preserve order;
    /// dictionaries contribute their known text keys, then their container
    /// values in sorted-key order for determinism.
    private static func collectTexts(_ object: Any, into texts: inout [String]) {
        if let string = object as? String {
            texts.append(string)
        } else if let array = object as? [Any] {
            for element in array {
                collectTexts(element, into: &texts)
            }
        } else if let dict = object as? [String: Any] {
            let textKeys = ["text", "string", "content", "body", "characters"]
            var consumed: Set<String> = []
            for key in textKeys {
                if let string = dict[key] as? String {
                    texts.append(string)
                    consumed.insert(key)
                }
            }
            for key in dict.keys.sorted() where !consumed.contains(key) {
                if let value = dict[key], !(value is String) {
                    collectTexts(value, into: &texts)
                }
            }
        }
    }

    /// Recursively scrapes title/author-looking string values. Purely
    /// numeric values are rejected (Author's metadata carries numeric
    /// internal IDs under author-like keys), and exact key matches beat
    /// fuzzy ones.
    private static func scanMetadata(_ object: Any, into metadata: inout [String: String]) {
        if let dict = object as? [String: Any] {
            for (key, value) in dict {
                if let string = value as? String, !string.isEmpty {
                    let lowered = key.lowercased()
                    let isPlausibleText = !string.allSatisfy { $0.isNumber || $0 == "-" || $0 == "." }
                    if lowered == "title", isPlausibleText {
                        metadata["title"] = string
                    } else if lowered == "author", isPlausibleText {
                        metadata["author"] = string
                    } else if lowered.contains("title"), metadata["title"] == nil, isPlausibleText {
                        metadata["title"] = string
                    } else if lowered.contains("author"), metadata["author"] == nil, isPlausibleText {
                        metadata["author"] = string
                    }
                } else {
                    scanMetadata(value, into: &metadata)
                }
            }
        } else if let array = object as? [Any] {
            for element in array {
                scanMetadata(element, into: &metadata)
            }
        }
    }

    private static func relativeName(of member: URL, in package: URL) -> String {
        let path = member.path
        guard path.hasPrefix(package.path) else { return member.lastPathComponent }
        return String(path.dropFirst(package.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    // MARK: - The knowledge layer

    /// The package's knowledge, beyond its words — read from Author's
    /// own members, whose shapes come from a real document:
    /// - Contents/glossary.json → Defined Concepts. Entries tagged
    ///   "section" are Author's auto-generated heading anchors, not
    ///   concepts; they are skipped (the headings travel in the body).
    /// - Contents/DynamicView.json → spatial layouts: the Map's
    ///   current arrangement ("layout") first, then every saved
    ///   custom layout.
    /// - Contents/Citations.plist → citation records, each synthesized
    ///   into BibTeX under its Author identifier, so concepts'
    ///   citationIdentifiers keep pointing at the right records.
    /// A heading as Author's glossary records it: the numbered phrase
    /// ("1.1.1. This is heading level 3") gives the true depth — dots
    /// the font-size heuristic cannot see.
    struct SectionEntry: Sendable {
        let text: String    // the heading's words, numbering stripped
        let level: Int
    }

    private static func knowledgeLayer(in package: URL, files: [URL])
        -> (concepts: [LiquidDoc.Concept], layouts: [LiquidDoc.Layout],
            connections: [LiquidDoc.MapConnection],
            references: [LiquidDoc.Reference], sections: [SectionEntry]) {

        func member(named name: String) -> URL? {
            let fixed = package.appendingPathComponent("Contents/\(name)")
            if FileManager.default.fileExists(atPath: fixed.path) { return fixed }
            return files.first { $0.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame }
        }

        var concepts: [LiquidDoc.Concept] = []
        var sections: [SectionEntry] = []
        if let glossaryURL = member(named: "glossary.json"),
           let data = try? Data(contentsOf: glossaryURL),
           let glossary = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let entries = glossary["entries"] as? [String: Any] {
            for (key, value) in entries {
                guard let entry = value as? [String: Any],
                      let phrase = (entry["phrase"] as? String)?
                          .trimmingCharacters(in: .whitespaces),
                      !phrase.isEmpty else { continue }
                let tag = (entry["tag"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                if tag == "section" {
                    // "1.1.1. Words" — the dotted numbers are the depth.
                    let numbering = phrase.prefix { $0.isNumber || $0 == "." || $0 == " " }
                    let level = numbering.filter { $0 == "." }.count
                    let text = (entry["description"] as? String)
                        ?? String(phrase.dropFirst(numbering.count))
                    if level > 0, !text.isEmpty {
                        sections.append(SectionEntry(text: text, level: level))
                    }
                    // Heading-concepts stay in the pool (spec J1 — nothing
                    // is silently dropped); their ids are the headings'
                    // stable UUIDs, which the exporter writes as data-id.
                    let headingText = text.isEmpty ? phrase : text
                    concepts.append(LiquidDoc.Concept(
                        id: (entry["identifier"] as? String) ?? key,
                        name: headingText.trimmingCharacters(in: .whitespaces),
                        description: "",
                        tag: "heading",
                        citationIdentifiers: entry["citationIdentifiers"] as? [String] ?? [],
                        urls: []))
                    continue
                }
                let urls = (entry["urls"] as? [[String: Any]] ?? [])
                    .compactMap { $0["url"] as? String }
                    .filter { !$0.isEmpty }
                concepts.append(LiquidDoc.Concept(
                    id: (entry["identifier"] as? String) ?? key,
                    name: phrase,
                    description: entry["description"] as? String ?? "",
                    tag: tag,
                    citationIdentifiers: entry["citationIdentifiers"] as? [String] ?? [],
                    urls: urls))
            }
            concepts.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }

        var layouts: [LiquidDoc.Layout] = []
        var connections: [LiquidDoc.MapConnection] = []
        if let dynamicURL = member(named: "DynamicView.json"),
           let data = try? Data(contentsOf: dynamicURL),
           let dynamic = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {

            func positions(of layout: Any?) -> [LiquidDoc.Layout.Position] {
                (((layout as? [String: Any])?["nodePositions"]) as? [[String: Any]] ?? [])
                    .compactMap { node -> LiquidDoc.Layout.Position? in
                        guard let nodeID = node["id"] as? String else { return nil }
                        return LiquidDoc.Layout.Position(
                            id: nodeID,
                            x: (node["x"] as? NSNumber)?.doubleValue ?? 0,
                            y: (node["y"] as? NSNumber)?.doubleValue ?? 0,
                            z: (node["z"] as? NSNumber)?.doubleValue ?? 0)
                    }
            }

            let current = positions(of: dynamic["layout"])
            if !current.isEmpty {
                layouts.append(LiquidDoc.Layout(index: 1, name: "Current Layout", positions: current))
            }
            for raw in dynamic["customLayouts"] as? [[String: Any]] ?? [] {
                let saved = positions(of: raw["layout"])
                guard !saved.isEmpty else { continue }
                layouts.append(LiquidDoc.Layout(index: layouts.count + 1,
                                                name: (raw["name"] as? String) ?? "",
                                                positions: saved,
                                                sourceID: raw["id"] as? String))
            }

            for raw in dynamic["connections"] as? [[String: Any]] ?? [] {
                guard let from = raw["startNodeIdentifier"] as? String,
                      let to = raw["endingNodeIdentifier"] as? String else { continue }
                let connection = LiquidDoc.MapConnection(from: from, to: to)
                if !connections.contains(connection) {
                    connections.append(connection)
                }
            }
        }

        var references: [LiquidDoc.Reference] = []
        if let citationsURL = member(named: "Citations.plist"),
           let data = try? Data(contentsOf: citationsURL),
           let store = try? PropertyListSerialization.propertyList(from: data, format: nil)
               as? [String: Any] {
            references = store.compactMap { key, value -> LiquidDoc.Reference? in
                guard let record = value as? [String: Any] else { return nil }
                let identifier = (record["identifier"] as? String) ?? key
                guard let bibtex = bibtex(from: record, key: identifier) else { return nil }
                return LiquidDoc.Reference(id: identifier, bibtex: bibtex)
            }
            .sorted { $0.id < $1.id }
        }

        return (concepts, layouts, connections, references, sections)
    }

    /// Corrects heading levels from Author's own record of them: a body
    /// paragraph whose text matches a section entry takes that entry's
    /// depth (clamped to the format's three levels) — exact where the
    /// font-size heuristic can only guess.
    private static func applyingSectionLevels(_ sections: [SectionEntry],
                                              to body: [LiquidDoc.Paragraph]) -> [LiquidDoc.Paragraph] {
        guard !sections.isEmpty else { return body }
        var levelByText: [String: Int] = [:]
        for section in sections {
            levelByText[section.text.trimmingCharacters(in: .whitespaces).lowercased()]
                = min(max(section.level, 1), 3)
        }
        return body.map { paragraph in
            guard paragraph.speaker == nil,
                  let level = levelByText[paragraph.text.trimmingCharacters(in: .whitespaces).lowercased()]
            else { return paragraph }
            return LiquidDoc.Paragraph(id: paragraph.id, heading: level,
                                       text: paragraph.text, speaker: paragraph.speaker)
        }
    }

    /// One BibTeX entry from one Author citation record — the fields a
    /// real Citations.plist carries, escaped by the app's one escaper.
    private static func bibtex(from record: [String: Any], key: String) -> String? {
        func text(_ field: String) -> String? {
            (record[field] as? String)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .flatMap { $0.isEmpty ? nil : $0 }
        }
        guard let title = text("title") else { return nil }

        // "First [Middle] Last", BibTeX order, joined by " and ".
        var names: [String] = []
        for author in record["citationAuthors"] as? [[String: Any]] ?? [] {
            let parts = ["firstName", "middleName", "lastName"]
                .compactMap { (author[$0] as? String)?.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if !parts.isEmpty { names.append(parts.joined(separator: " ")) }
        }
        if names.isEmpty {
            names = (record["authors"] as? [String] ?? []).filter { !$0.isEmpty }
        }

        let escape = VisualMeta.bibtexEscaped
        var fields: [String] = []
        if !names.isEmpty {
            fields.append("author = {\(names.map(escape).joined(separator: " and "))}")
        }
        fields.append("title = {\(escape(title))}")
        if let year = record["yearComponent"] as? Int, year > 0 {
            fields.append("year = {\(year)}")
        }
        let fieldMap = [
            ("journal", "journal"), ("publication", "publication"),
            ("publisher", "publisher"), ("doi", "doi"), ("isbn", "isbn"),
            ("issn", "issn"), ("volume", "volume"), ("issue", "number"),
            ("editor", "editor"), ("series", "series"),
            ("location", "address"), ("pageRange", "pages"),
            ("webAddress", "url"), ("vm-id", "vm-id"),
        ]
        for (source, target) in fieldMap {
            guard let value = text(source) else { continue }
            // Author writes placeholder page ranges as "0".
            if target == "pages", value == "0" { continue }
            fields.append("\(target) = {\(escape(value))}")
        }
        let type = text("bibTeXType") ?? "misc"
        return "@\(type){\(key),\n\(fields.joined(separator: ",\n"))\n}"
    }
}
