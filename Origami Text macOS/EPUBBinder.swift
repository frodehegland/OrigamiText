import Foundation
import CryptoKit

// MARK: - What a shelved book holds

/// The works a shelved EPUB declares (Origami Binding Profile §3.3): one
/// `collection` with the distributable-object role per article, each with
/// its title, authors and files — and the package's own facts, so a plain
/// publication with no works can be bound whole as one.
nonisolated struct EPUBWorks: Sendable {

    struct Work: Identifiable, Hashable, Sendable {
        /// The work's own `urn:uuid:`, the same in every binding.
        let id: String
        let title: String
        let authors: [String]
        /// The files the work needs, relative to the package root — its
        /// content document first.
        let files: [String]
        /// Where it was first published: the source binding and edition.
        let sourceBinding: String?
        let sourceEdition: String?
        let year: String?
        /// The heading's id in the content document, from the record.
        let section: String?
        /// The compiler's word on it, from the record.
        let note: String?
    }

    /// The package document's path within the folder, "package.opf" or
    /// "OEBPS/content.opf".
    let opfPath: String
    let title: String
    let authors: [String]
    let language: String
    let date: String?
    /// `dc:identifier` — this edition.
    let edition: String?
    /// `dcterms:isVersionOf` — the work or binding across editions.
    let binding: String?
    /// The spine's content documents in reading order, relative to the
    /// package root, the navigation document left out.
    let spine: [String]
    let works: [Work]
    /// `origami:binding`, when the package says it is one.
    let bindingKind: String?
    let coverText: String?

    var hasWorks: Bool { !works.isEmpty }

    /// The package root's directory for a path relative to it.
    var opfDirectory: String { (opfPath as NSString).deletingLastPathComponent }

    /// Reads the shelved book's package and record from its unpacked folder.
    static func read(unpackedFolder folder: URL) -> EPUBWorks? {
        let container = (try? String(contentsOf: folder.appendingPathComponent("META-INF/container.xml"), encoding: .utf8)) ?? ""
        let opfPath = BinderText.capture(in: container, "full-path=\"([^\"]+)\"") ?? "package.opf"
        guard let opf = try? String(contentsOf: folder.appendingPathComponent(opfPath), encoding: .utf8) else { return nil }
        let opfDirectory = (opfPath as NSString).deletingLastPathComponent
        func rooted(_ href: String) -> String {
            opfDirectory.isEmpty ? href : "\(opfDirectory)/\(href)"
        }

        // The package's own metadata, before any collection's.
        let metadataBlock = BinderText.capture(in: opf, "(?s)<metadata\\b.*?</metadata>") ?? opf
        let title = BinderText.tagText(in: metadataBlock, "dc:title") ?? folder.lastPathComponent
        let authors = BinderText.tagTexts(in: metadataBlock, "dc:creator")
        let language = BinderText.tagText(in: metadataBlock, "dc:language") ?? "und"
        let date = BinderText.tagText(in: metadataBlock, "dc:date")
        let edition = BinderText.tagText(in: metadataBlock, "dc:identifier")
        let binding = BinderText.capture(in: metadataBlock, "<meta[^>]*property=\"dcterms:isVersionOf\"[^>]*>([^<]*)</meta>")
        let kind = BinderText.capture(in: metadataBlock, "<meta[^>]*property=\"origami:binding\"[^>]*>([^<]*)</meta>")

        // The spine, content documents only.
        var hrefByID: [String: (href: String, properties: String)] = [:]
        for item in BinderText.captures(in: opf, "<item\\s[^>]*>") {
            guard let id = BinderText.capture(in: item, "\\sid=\"([^\"]+)\""),
                  let href = BinderText.capture(in: item, "href=\"([^\"]+)\"") else { continue }
            hrefByID[id] = (href, BinderText.capture(in: item, "properties=\"([^\"]*)\"") ?? "")
        }
        var spine: [String] = []
        for itemref in BinderText.captures(in: opf, "<itemref\\b[^>]*>") {
            guard let idref = BinderText.capture(in: itemref, "idref=\"([^\"]+)\""),
                  let item = hrefByID[idref], !item.properties.contains("nav") else { continue }
            spine.append(rooted(item.href))
        }

        // The record's binding block: the works' sections, notes and the cover.
        var recordWorks: [String: [String: Any]] = [:]
        var coverText: String?
        if let record = recordJSON(in: folder, opf: opf, opfDirectory: opfDirectory),
           let document = record["document"] as? [String: Any],
           let bindingRecord = document["binding"] as? [String: Any] {
            coverText = (bindingRecord["cover"] as? [String: Any])?["text"] as? String
            for work in bindingRecord["works"] as? [[String: Any]] ?? [] {
                if let id = work["id"] as? String { recordWorks[id] = work }
            }
        }

        // The works: each collection with the distributable-object role.
        var works: [Work] = []
        for block in BinderText.captures(in: opf, "(?s)<collection\\b[^>]*role=\"distributable-object\"[^>]*>.*?</collection>") {
            guard let id = BinderText.tagText(in: block, "dc:identifier"),
                  let workTitle = BinderText.tagText(in: block, "dc:title") else { continue }
            let files = BinderText.captures(in: block, "<link\\b[^>]*href=\"([^\"]+)\"").map(rooted)
            let fromRecord = recordWorks[id]
            works.append(Work(
                id: id,
                title: workTitle,
                authors: BinderText.tagTexts(in: block, "dc:creator"),
                files: files,
                sourceBinding: BinderText.capture(in: block, "<meta[^>]*property=\"dcterms:isPartOf\"[^>]*>([^<]*)</meta>"),
                sourceEdition: BinderText.capture(in: block, "<meta[^>]*property=\"dcterms:source\"[^>]*>([^<]*)</meta>"),
                year: BinderText.tagText(in: block, "dc:date"),
                section: (fromRecord?["section"] as? String)
                    ?? (fromRecord?["href"] as? String).flatMap { $0.split(separator: "#").last.map(String.init) },
                note: fromRecord?["note"] as? String))
        }

        return EPUBWorks(opfPath: opfPath, title: title, authors: authors, language: language, date: date,
                         edition: edition, binding: binding, spine: spine, works: works,
                         bindingKind: kind, coverText: coverText)
    }

    /// The Visual-Meta record, by the package's declaration first.
    private static func recordJSON(in folder: URL, opf: String, opfDirectory: String) -> [String: Any]? {
        var candidates: [String] = []
        if let declared = BinderText.capture(in: opf, "<link[^>]*rel=\"record\"[^>]*properties=\"origami:visual-meta\"[^>]*href=\"([^\"]+)\"")
            ?? BinderText.capture(in: opf, "<link[^>]*href=\"([^\"]+)\"[^>]*properties=\"origami:visual-meta\"") {
            candidates.append(opfDirectory.isEmpty ? declared : "\(opfDirectory)/\(declared)")
        }
        candidates.append("visual-meta.json")
        for path in candidates {
            if let data = try? Data(contentsOf: folder.appendingPathComponent(path)),
               let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                return json
            }
        }
        return nil
    }
}

// MARK: - The binder

/// What goes into a binder: a shelved book, whole or some of its works.
struct BinderPart: Identifiable, Hashable {
    var id: String { record.id }
    let record: EPUBRecord
    /// The chosen works' ids; nil binds the book whole as one work.
    var workIDs: [String]?

    func title(_ info: EPUBWorks?) -> String {
        guard let info, let ids = workIDs else { return record.title }
        let chosen = info.works.filter { ids.contains($0.id) }
        if chosen.count == 1 { return chosen[0].title }
        return "\(record.title) (\(chosen.count) articles)"
    }
}

/// A binder being made: the parts added so far, until it is exported or
/// cancelled. One at a time, app-wide.
@MainActor @Observable
final class BinderModel {
    static let shared = BinderModel()

    /// Nil when no binder is being made.
    var parts: [BinderPart]?
    /// What the works chooser is open for.
    var chooser: BinderChooserRequest?
    /// The cover sheet, before Export As Binder with Cover.
    var coverRequest: Bool = false

    var isActive: Bool { parts != nil }

    func start() { parts = [] }
    func cancel() { parts = nil }

    func contains(_ record: EPUBRecord) -> Bool {
        parts?.contains { $0.record.id == record.id } == true
    }

    func add(_ part: BinderPart) {
        if parts == nil { parts = [] }
        parts?.removeAll { $0.record.id == part.record.id }
        parts?.append(part)
    }

    func remove(_ record: EPUBRecord) {
        parts?.removeAll { $0.record.id == record.id }
    }
}

/// The works chooser: for one book — Export Selection…, or adding
/// articles to the binder.
struct BinderChooserRequest: Identifiable {
    enum Purpose { case exportSelection, addToBinder }
    let id = UUID()
    let record: EPUBRecord
    let info: EPUBWorks
    let purpose: Purpose
}

// MARK: - Writing the binder (Origami Binding Profile)

/// Writes a binding from shelved books: every chosen work's own files
/// carried over — its content document with its notes and references,
/// its images — plus a cover of plain text, the glossary entries the
/// works reach, a colophon, the records and the package. Nothing is
/// re-rendered; the format's per-work files are what make this a copy.
nonisolated enum EPUBBinderWriter {

    struct Input {
        let title: String
        let coverText: String?
        let compiler: String
        let parts: [(part: BinderPart, folder: URL, info: EPUBWorks)]
    }

    /// One work in the binder — a chosen article, or a whole publication.
    private struct Piece {
        let id: String
        let title: String
        let authors: [String]
        let sourceTitle: String
        let sourceEditors: [String]
        let sourceBinding: String?
        let sourceEdition: String?
        let year: String?
        let note: String?
        /// The content documents, in order, by their new path under the
        /// binder root — the first carries the heading.
        var documents: [String] = []
        var headingID: String?
        var images: [String] = []
        var referenceKeys: [String] = []
    }

    static func write(_ input: Input, to destination: URL) throws {
        let fileManager = FileManager.default
        // Symlinks resolved: the packer names each entry by the path
        // under the folder, and /var is /private/var once enumerated.
        let root = fileManager.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("Binder-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root.appendingPathComponent("content/images"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: root.appendingPathComponent("content/models"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: root.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        var pieces: [Piece] = []
        var glossary: [(id: String, term: String, definition: String)] = []
        var bibliography: [String] = []
        var language = "und"
        var css: String?

        for (number, entry) in input.parts.enumerated() {
            let prefix = "s\(number + 1)-"
            let info = entry.info
            let folder = entry.folder
            if language == "und", info.language != "und" { language = info.language }
            if css == nil, let found = try? String(contentsOf: folder.appendingPathComponent("content/style.css"), encoding: .utf8) {
                css = found
            }
            let sourceBibliography = (try? String(contentsOf: folder.appendingPathComponent("references.bib"), encoding: .utf8)) ?? ""
            let sourceGlossary = glossaryEntries(in: folder, info: info)

            // Which works: the chosen ones, or the publication whole.
            var selected: [(work: EPUBWorks.Work?, files: [String])] = []
            if let ids = entry.part.workIDs, info.hasWorks {
                for work in info.works where ids.contains(work.id) {
                    selected.append((work, work.files))
                }
            } else {
                // The whole publication as one work: its spine, less a
                // back matter document that is only records and colophon.
                let docs = info.spine.filter { path in
                    guard let text = try? String(contentsOf: folder.appendingPathComponent(path), encoding: .utf8) else { return false }
                    let isBack = text.contains("epub:type=\"colophon\"") && !text.contains("<main")
                    let isCover = text.contains("epub:type=\"cover\"")
                    return !isBack && !isCover
                }
                selected.append((nil, docs))
            }

            // The files each selected work brings, under new names.
            var renamed: [String: String] = [:]   // source path → binder path
            for (_, files) in selected {
                for file in files where renamed[file] == nil {
                    renamed[file] = newPath(for: file, prefix: prefix)
                }
            }

            for (work, files) in selected {
                var piece = Piece(
                    id: work?.id ?? info.binding ?? info.edition ?? "urn:uuid:\(stableUUID(from: folder.lastPathComponent))",
                    title: work?.title ?? info.title,
                    authors: work?.authors ?? info.authors,
                    sourceTitle: info.title,
                    sourceEditors: work == nil ? [] : info.authors,
                    sourceBinding: work?.sourceBinding ?? info.binding,
                    sourceEdition: work?.sourceEdition ?? info.edition,
                    year: work?.year ?? info.date.map { String($0.prefix(4)) },
                    note: work?.note)
                piece.headingID = work?.section
                for file in files {
                    guard let target = renamed[file] else { continue }
                    let source = folder.appendingPathComponent(file)
                    guard fileManager.fileExists(atPath: source.path) else { continue }
                    if isContentDocument(file) {
                        guard let text = try? String(contentsOf: source, encoding: .utf8) else { continue }
                        let rewritten = rewrite(text, sourcePath: file, folder: folder, prefix: prefix,
                                                renamed: &renamed, glossary: sourceGlossary,
                                                collected: &glossary, images: &piece.images, root: root)
                        try Data(rewritten.utf8).write(to: root.appendingPathComponent(target), options: .atomic)
                        piece.documents.append(target)
                        if piece.headingID == nil {
                            piece.headingID = BinderText.capture(in: rewritten, "<h1\\b[^>]*\\sid=\"([^\"]+)\"")
                                ?? BinderText.capture(in: rewritten, "<h2\\b[^>]*\\sid=\"([^\"]+)\"")
                        }
                        for key in BinderText.captures(in: rewritten, "id=\"bib-([^\"]+)\"") where !piece.referenceKeys.contains(key) {
                            piece.referenceKeys.append(key)
                            if let entry = bibliographyEntry(for: key, in: sourceBibliography) { bibliography.append(entry) }
                        }
                    } else {
                        // An image or a model named by the collection.
                        try copyAsset(from: source, to: root.appendingPathComponent(target))
                        if target.hasPrefix("content/images/") { piece.images.append(target) }
                    }
                }
                if !piece.documents.isEmpty { pieces.append(piece) }
            }
        }
        guard !pieces.isEmpty else { throw BinderError.nothingToBind }

        let editionID = "urn:uuid:\(UUID().uuidString.lowercased())"
        let bindingID = "urn:uuid:\(stableUUID(from: "binder:" + pieces.map(\.id).sorted().joined(separator: ",")))"
        let sources = Set(pieces.compactMap(\.sourceBinding))
        let kind = sources.count > 1 ? "reading-list" : "selection"
        let modified = ISO8601DateFormatter().string(from: Date())
        let today = String(modified.prefix(10))
        let compiler = input.compiler.trimmingCharacters(in: .whitespaces)

        try Data("application/epub+zip".utf8).write(to: root.appendingPathComponent("mimetype"))
        try Data(containerXML.utf8).write(to: root.appendingPathComponent("META-INF/container.xml"))
        try Data((css ?? defaultCSS).utf8).write(to: root.appendingPathComponent("content/style.css"))
        try Data(coverHTML(input: input, pieces: pieces, language: language, today: today).utf8)
            .write(to: root.appendingPathComponent("content/cover.html"))
        try Data(backHTML(input: input, pieces: pieces, glossary: glossary, language: language,
                          editionID: editionID, bindingID: bindingID, kind: kind, today: today, compiler: compiler).utf8)
            .write(to: root.appendingPathComponent("content/back.html"))
        try Data(navHTML(input: input, pieces: pieces, language: language).utf8)
            .write(to: root.appendingPathComponent("content/nav.html"))
        try Data(packageOPF(input: input, pieces: pieces, language: language, editionID: editionID,
                            bindingID: bindingID, kind: kind, modified: modified, compiler: compiler, root: root).utf8)
            .write(to: root.appendingPathComponent("package.opf"))
        let record = visualMeta(input: input, pieces: pieces, glossary: glossary, language: language,
                                editionID: editionID, bindingID: bindingID, kind: kind, today: today, compiler: compiler)
        try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("visual-meta.json"))
        let interaction: [String: Any] = ["origami": ["format": "origami-text", "version": "1.0",
                                                      "profile": OrigamiEPUBExporter.profileURI,
                                                      "describes": editionID, "generator": "Origami Text"]]
        try JSONSerialization.data(withJSONObject: interaction, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("origami.json"))
        try Data((bibliography.joined(separator: "\n\n") + "\n").utf8).write(to: root.appendingPathComponent("references.bib"))

        let data = try OrigamiEPUBExporter.pack(unpackedFolder: root)
        try data.write(to: destination, options: .atomic)
    }

    enum BinderError: LocalizedError {
        case nothingToBind
        var errorDescription: String? {
            switch self {
            case .nothingToBind: return "None of the chosen books had text that could be bound."
            }
        }
    }

    // MARK: Files

    private static func isContentDocument(_ path: String) -> Bool {
        let lower = path.lowercased()
        return lower.hasSuffix(".html") || lower.hasSuffix(".xhtml") || lower.hasSuffix(".htm")
    }

    /// Where a source file goes in the binder: content documents under
    /// content/, images under content/images/, models under
    /// content/models/, each prefixed by its source's number.
    private static func newPath(for sourcePath: String, prefix: String) -> String {
        let name = (sourcePath as NSString).lastPathComponent
        let lower = sourcePath.lowercased()
        if isContentDocument(sourcePath) { return "content/\(prefix)\(name)" }
        if lower.contains("/models/") || lower.hasSuffix(".usdz") || lower.hasSuffix(".glb") || lower.hasSuffix(".gltf") {
            return "content/models/\(prefix)\(name)"
        }
        return "content/images/\(prefix)\(name)"
    }

    private static func copyAsset(from source: URL, to target: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: target.path) { return }
        try fileManager.copyItem(at: source, to: target)
    }

    /// A content document carried over: its colophon and Visual-Meta
    /// sections gone (the binder has its own), its images and models
    /// copied and renamed, its links to other files of the same book
    /// followed to their new names — or, where the target is not in the
    /// binder, let go, their words kept. A glossary reference becomes
    /// one into the binder's own glossary, the entry collected.
    private static func rewrite(_ text: String, sourcePath: String, folder: URL, prefix: String,
                                renamed: inout [String: String],
                                glossary: [String: (term: String, definition: String)],
                                collected: inout [(id: String, term: String, definition: String)],
                                images: inout [String], root: URL) -> String {
        var out = text
        out = BinderText.removing(in: out, "(?s)<section\\b[^>]*epub:type=\"colophon\"[^>]*>.*?</section>\\s*")
        out = BinderText.removing(in: out, "(?s)<section\\b[^>]*id=\"visual-meta\"[^>]*>.*?</section>\\s*")
        let directory = (sourcePath as NSString).deletingLastPathComponent

        // Assets by relative path: src, poster, model sources.
        for attribute in ["src", "data-model-src", "poster"] {
            out = BinderText.replacingCaptures(in: out, "\\b\(attribute)=\"([^\"#:]+)\"") { relative in
                let sourceRelative = joined(directory, relative)
                let source = folder.appendingPathComponent(sourceRelative)
                guard FileManager.default.fileExists(atPath: source.path) else { return nil }
                let target = renamed[sourceRelative] ?? newPath(for: sourceRelative, prefix: prefix)
                renamed[sourceRelative] = target
                try? copyAsset(from: source, to: root.appendingPathComponent(target))
                if target.hasPrefix("content/images/"), !images.contains(target) { images.append(target) }
                // Every binder document sits in content/, so the path from it.
                return String(target.dropFirst("content/".count))
            }
        }

        // Links to other files of this book.
        out = BinderText.replacingAnchors(in: out) { href, inner in
            guard !href.hasPrefix("#"), !href.contains(":"), !href.hasPrefix("mailto") else { return nil }
            let parts = href.split(separator: "#", maxSplits: 1).map(String.init)
            let file = parts[0]
            let fragment = parts.count > 1 ? parts[1] : nil
            let sourceRelative = joined(directory, file)
            if let fragment, fragment.hasPrefix("gloss-") {
                let conceptID = String(fragment.dropFirst("gloss-".count))
                if let entry = glossary[conceptID] {
                    let binderID = prefix + conceptID
                    if !collected.contains(where: { $0.id == binderID }) {
                        collected.append((binderID, entry.term, entry.definition))
                    }
                    return .relink("back.html#gloss-\(binderID)")
                }
                return .unlink
            }
            if let target = renamed[sourceRelative], isContentDocument(sourceRelative) {
                let name = String(target.dropFirst("content/".count))
                return .relink(fragment.map { "\(name)#\($0)" } ?? name)
            }
            _ = inner
            return .unlink
        }
        return out
    }

    private static func joined(_ directory: String, _ relative: String) -> String {
        var parts = directory.isEmpty ? [] : directory.split(separator: "/").map(String.init)
        for component in relative.split(separator: "/").map(String.init) {
            if component == ".." { if !parts.isEmpty { parts.removeLast() } }
            else if component != "." { parts.append(component) }
        }
        return parts.joined(separator: "/")
    }

    /// The book's glossary entries by concept id, from whichever content
    /// document holds them.
    private static func glossaryEntries(in folder: URL, info: EPUBWorks) -> [String: (term: String, definition: String)] {
        var entries: [String: (String, String)] = [:]
        for path in info.spine {
            guard let text = try? String(contentsOf: folder.appendingPathComponent(path), encoding: .utf8),
                  text.contains("id=\"gloss-") else { continue }
            let pattern = "(?s)<dt\\b[^>]*id=\"gloss-([^\"]+)\"[^>]*>(.*?)</dt>\\s*<dd\\b[^>]*>(.*?)</dd>"
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let whole = text as NSString
            for match in expression.matches(in: text, range: NSRange(location: 0, length: whole.length)) {
                let id = whole.substring(with: match.range(at: 1))
                entries[id] = (whole.substring(with: match.range(at: 2)), whole.substring(with: match.range(at: 3)))
            }
        }
        return entries
    }

    /// One `@type{key, …}` entry of a bibliography record.
    private static func bibliographyEntry(for key: String, in bibliography: String) -> String? {
        guard let start = bibliography.range(of: "{\(key),") ?? bibliography.range(of: "{\(key)}") else { return nil }
        guard let at = bibliography[..<start.lowerBound].lastIndex(of: "@") else { return nil }
        var depth = 0
        var index = start.lowerBound
        while index < bibliography.endIndex {
            let character = bibliography[index]
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 { return String(bibliography[at...index]) }
            }
            index = bibliography.index(after: index)
        }
        return nil
    }

    // MARK: The binder's own documents

    private static func documentOpen(title: String, language: String) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="\(escaped(language))" lang="\(escaped(language))">
        <head>
        <meta charset="utf-8"/>
        <title>\(escaped(title))</title>
        <link rel="stylesheet" type="text/css" href="style.css"/>
        </head>
        <body>
        """
    }

    private static func fileName(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    private static func coverHTML(input: Input, pieces: [Piece], language: String, today: String) -> String {
        var lines = [documentOpen(title: input.title, language: language)]
        lines.append("<section epub:type=\"cover\" id=\"cover\">")
        lines.append("<h1>\(escaped(input.title))</h1>")
        let compiler = input.compiler.trimmingCharacters(in: .whitespaces)
        lines.append("<p class=\"compiler\">\(escaped(compiler.isEmpty ? today : "Compiled by \(compiler) · \(today)"))</p>")
        if let text = input.coverText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            for paragraph in text.components(separatedBy: "\n\n") {
                let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                lines.append("<p>\(escaped(trimmed).replacingOccurrences(of: "\n", with: "<br/>"))</p>")
            }
        }
        lines.append("<ol class=\"works\">")
        for piece in pieces {
            var entry = ""
            if !piece.authors.isEmpty { entry += escaped(sentenceList(piece.authors)) + ", " }
            let href = fileName(piece.documents[0]) + (piece.headingID.map { "#\($0)" } ?? "")
            entry += "<a href=\"\(escaped(href))\"><em>\(escaped(piece.title))</em></a>."
            if piece.sourceTitle != piece.title {
                entry += " From <cite>\(escaped(piece.sourceTitle))</cite>"
                if let year = piece.year, !year.isEmpty { entry += ", \(escaped(year))" }
                entry += "."
            } else if let year = piece.year, !year.isEmpty {
                entry += " \(escaped(year))."
            }
            if let note = piece.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
                entry += " <span class=\"work-note\">\(escaped(note))</span>"
            }
            lines.append("<li>\(entry)</li>")
        }
        lines.append("</ol>")
        lines.append("</section>")
        lines.append("</body>\n</html>")
        return lines.joined(separator: "\n")
    }

    private static func backHTML(input: Input, pieces: [Piece], glossary: [(id: String, term: String, definition: String)],
                                 language: String, editionID: String, bindingID: String, kind: String,
                                 today: String, compiler: String) -> String {
        var lines = [documentOpen(title: input.title, language: language)]
        if !glossary.isEmpty {
            lines.append("<section epub:type=\"glossary\" role=\"doc-glossary\" id=\"glossary\">")
            lines.append("<h2>Glossary</h2>")
            lines.append("<dl>")
            for entry in glossary {
                lines.append("<dt id=\"gloss-\(escaped(entry.id))\">\(entry.term)</dt>")
                lines.append("<dd>\(entry.definition)</dd>")
            }
            lines.append("</dl>")
            lines.append("</section>")
        }
        let works = pieces.map { "<pre>\(escaped(workBibTeX($0)))</pre>" }.joined(separator: "\n")
        lines.append("""
        <section epub:type="colophon" id="origami-publication-info">
        <h2>Visual-Meta Colophon</h2>
        <p>This document includes Visual-Meta to enable permanent
        self-citation, metadata preservation, and seamless reference management
        across digital, Web, and printed formats.</p>
        <h3>Self-citation record</h3>
        <pre>\(escaped(selfCitationBibTeX(title: input.title, compiler: compiler, kind: kind, year: String(today.prefix(4)))))</pre>
        <h3>Works in this binding</h3>
        \(works)
        <h3>Embedded machine-readable metadata</h3>
        <p>Structured metadata records are declared in this publication's package
        document and stored inside the EPUB container:</p>
        <ul>
        <li>Bibliographic and structural identity: <code>visual-meta.json</code></li>
        <li>Authored interaction and layout: <code>origami.json</code></li>
        <li>Bibliography: <code>references.bib</code></li>
        </ul>
        <p>This publication is <code>\(escaped(editionID))</code>, an edition of
        <code>\(escaped(bindingID))</code>, and conforms to the Origami Text 1.0 profile
        (\(OrigamiEPUBExporter.profileURI)).</p>
        </section>
        </body>
        </html>
        """)
        return lines.joined(separator: "\n")
    }

    private static func navHTML(input: Input, pieces: [Piece], language: String) -> String {
        let items = pieces.map { piece -> String in
            let href = fileName(piece.documents[0]) + (piece.headingID.map { "#\($0)" } ?? "")
            return "<li><a href=\"\(escaped(href))\">\(escaped(piece.title))</a></li>"
        }.joined(separator: "\n")
        let first = pieces[0]
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="\(escaped(language))" lang="\(escaped(language))">
        <head>
        <meta charset="utf-8"/>
        <title>\(escaped(input.title))</title>
        </head>
        <body>
        <nav epub:type="toc" role="doc-toc">
        <h1>Contents</h1>
        <ol>
        <li><a href="cover.html">Cover</a></li>
        \(items)
        </ol>
        </nav>
        <nav epub:type="landmarks" hidden="hidden">
        <h1>Landmarks</h1>
        <ol>
        <li><a epub:type="cover" href="cover.html">Cover</a></li>
        <li><a epub:type="bodymatter" href="\(escaped(fileName(first.documents[0])))">\(escaped(first.title))</a></li>
        </ol>
        </nav>
        </body>
        </html>
        """
    }

    private static func packageOPF(input: Input, pieces: [Piece], language: String, editionID: String,
                                   bindingID: String, kind: String, modified: String, compiler: String,
                                   root: URL) -> String {
        var metadata = [
            "<dc:identifier id=\"pub-id\">\(escaped(editionID))</dc:identifier>",
            "<dc:title>\(escaped(input.title))</dc:title>",
            "<dc:language>\(escaped(language))</dc:language>"
        ]
        if !compiler.isEmpty {
            metadata.append("<dc:creator id=\"compiler1\">\(escaped(compiler))</dc:creator>")
            metadata.append("<meta refines=\"#compiler1\" property=\"role\" scheme=\"marc:relators\">com</meta>")
        }
        metadata += [
            "<dc:date>\(String(modified.prefix(10)))</dc:date>",
            "<meta property=\"origami:binding\">\(kind)</meta>",
            "<meta property=\"dcterms:modified\">\(modified)</meta>",
            "<meta property=\"dcterms:conformsTo\">\(OrigamiEPUBExporter.profileURI)</meta>",
            "<meta property=\"dcterms:isVersionOf\">\(escaped(bindingID))</meta>",
            "<meta property=\"schema:accessMode\">textual</meta>",
            "<meta property=\"schema:accessibilityFeature\">structuralNavigation</meta>",
            "<meta property=\"schema:accessibilityFeature\">tableOfContents</meta>",
            "<meta property=\"schema:accessibilityHazard\">none</meta>",
            "<meta property=\"schema:accessModeSufficient\">textual</meta>",
            "<meta property=\"schema:accessibilitySummary\">Reflowable text with full structural navigation.</meta>",
            "<link rel=\"record\" href=\"visual-meta.json\" media-type=\"application/json\" properties=\"origami:visual-meta\"/>",
            "<link rel=\"record\" href=\"origami.json\" media-type=\"application/json\" properties=\"origami:interaction\"/>",
            "<link rel=\"record\" href=\"references.bib\" media-type=\"application/x-bibtex\" properties=\"origami:bibliography\"/>"
        ]
        var items = ["<item id=\"cover\" href=\"content/cover.html\" media-type=\"application/xhtml+xml\"/>"]
        var spine = ["<itemref idref=\"cover\"/>"]
        var number = 0
        for piece in pieces {
            for document in piece.documents {
                number += 1
                let text = (try? String(contentsOf: root.appendingPathComponent(document), encoding: .utf8)) ?? ""
                let properties = text.contains("<math") ? " properties=\"mathml\"" : ""
                items.append("<item id=\"doc\(number)\" href=\"\(escaped(document))\" media-type=\"application/xhtml+xml\"\(properties)/>")
                spine.append("<itemref idref=\"doc\(number)\"/>")
            }
        }
        items.append("<item id=\"back\" href=\"content/back.html\" media-type=\"application/xhtml+xml\"/>")
        spine.append("<itemref idref=\"back\"/>")
        items.append("<item id=\"nav\" href=\"content/nav.html\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>")
        items.append("<item id=\"css\" href=\"content/style.css\" media-type=\"text/css\"/>")
        // Every image and model in the binder.
        var assetNumber = 0
        for subfolder in ["content/images", "content/models"] {
            let folder = root.appendingPathComponent(subfolder)
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
            for name in names {
                assetNumber += 1
                items.append("<item id=\"asset\(assetNumber)\" href=\"\(escaped("\(subfolder)/\(name)"))\" media-type=\"\(mediaType(for: name))\"/>")
            }
        }
        var collections: [String] = []
        for (index, piece) in pieces.enumerated() {
            let id = "work\(index + 1)"
            // The collection's metadata declares the Dublin Core prefix for
            // itself: the package's declaration on its own <metadata> does
            // not reach here.
            var lines = ["<collection role=\"distributable-object\" id=\"\(id)\">",
                         "<metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\">",
                         "<dc:identifier>\(escaped(piece.id))</dc:identifier>",
                         "<dc:title>\(escaped(piece.title))</dc:title>"]
            for (authorIndex, author) in piece.authors.enumerated() where !author.isEmpty {
                lines.append("<dc:creator id=\"\(id)-author\(authorIndex + 1)\">\(escaped(author))</dc:creator>")
                lines.append("<meta refines=\"#\(id)-author\(authorIndex + 1)\" property=\"role\" scheme=\"marc:relators\">aut</meta>")
            }
            if let year = piece.year, !year.isEmpty { lines.append("<dc:date>\(escaped(year))</dc:date>") }
            if let source = piece.sourceBinding { lines.append("<meta property=\"dcterms:isPartOf\">\(escaped(source))</meta>") }
            if let edition = piece.sourceEdition { lines.append("<meta property=\"dcterms:source\">\(escaped(edition))</meta>") }
            lines.append("</metadata>")
            for document in piece.documents { lines.append("<link href=\"\(escaped(document))\"/>") }
            for image in piece.images { lines.append("<link href=\"\(escaped(image))\"/>") }
            lines.append("</collection>")
            collections.append(lines.joined(separator: "\n"))
        }
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="pub-id" xml:lang="\(escaped(language))" prefix="origami: https://github.com/frodehegland/OrigamiText/blob/main/profile/vocab.md#">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        \(metadata.joined(separator: "\n"))
        </metadata>
        <manifest>
        \(items.joined(separator: "\n"))
        </manifest>
        <spine>
        \(spine.joined(separator: "\n"))
        </spine>
        \(collections.joined(separator: "\n"))
        </package>
        """
    }

    private static func visualMeta(input: Input, pieces: [Piece], glossary: [(id: String, term: String, definition: String)],
                                   language: String, editionID: String, bindingID: String, kind: String,
                                   today: String, compiler: String) -> [String: Any] {
        func tagged(_ value: String) -> [String: Any] { ["value": value, "lang": language] }
        var document: [String: Any] = [
            "language": language,
            "title": tagged(input.title),
            "authors": compiler.isEmpty ? [] : [["name": tagged(compiler)]],
            "identifier": editionID,
            "work": bindingID,
            "date": today,
            "defaultDocument": "content/cover.html"
        ]
        var binding: [String: Any] = [
            "kind": kind,
            "id": bindingID,
            "compilers": compiler.isEmpty ? [] : [["name": compiler, "role": "compiler"]]
        ]
        if let text = input.coverText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            binding["cover"] = ["text": text]
        }
        binding["works"] = pieces.map { piece -> [String: Any] in
            var source: [String: Any] = ["title": piece.sourceTitle]
            if let binding = piece.sourceBinding { source["binding"] = binding }
            if let edition = piece.sourceEdition { source["edition"] = edition }
            if !piece.sourceEditors.isEmpty { source["editors"] = piece.sourceEditors }
            if let year = piece.year, !year.isEmpty { source["year"] = year }
            var work: [String: Any] = [
                "id": piece.id,
                "title": piece.title,
                "authors": piece.authors.map { ["name": $0] },
                "href": piece.documents[0] + (piece.headingID.map { "#\($0)" } ?? ""),
                "source": source,
                "resources": ["references": piece.referenceKeys, "images": piece.images, "notes": [], "concepts": [], "models": []]
            ]
            if let section = piece.headingID { work["section"] = section }
            if let note = piece.note, !note.isEmpty { work["note"] = note }
            return work
        }
        document["binding"] = binding
        var meta: [String: Any] = [
            "visual-meta": ["format": "visual-meta", "version": "1.1", "profile": OrigamiEPUBExporter.profileURI,
                            "describes": editionID, "generator": "Origami Text",
                            "introduction": "This is Visual-Meta: the document's intellectual structure — its concepts, its citations, and any spatial layouts — carried with the document itself, readable by people and machines alike. See https://visual-meta.info."],
            "document": document,
            "structure": ["headings": pieces.enumerated().map { index, piece -> [String: Any] in
                ["id": piece.headingID ?? "work\(index + 1)", "address": "\(index + 1)",
                 "href": piece.documents[0] + (piece.headingID.map { "#\($0)" } ?? ""),
                 "level": 1, "text": piece.title]
            }],
            "concepts": glossary.map { ["id": $0.id, "name": BinderText.plain($0.term), "description": BinderText.plain($0.definition),
                                        "tag": "concept", "urls": [], "citationIdentifiers": [],
                                        "href": "content/back.html#gloss-\($0.id)"] }
        ]
        var citations: [[String: Any]] = []
        for piece in pieces {
            for key in piece.referenceKeys {
                citations.append(["id": key, "number": citations.count + 1, "href": "\(piece.documents[0])#bib-\(key)"])
            }
        }
        meta["citations"] = citations
        if !citations.isEmpty { meta["bibliography"] = ["href": "references.bib"] }
        return meta
    }

    // MARK: Citations and names

    private static func selfCitationBibTeX(title: String, compiler: String, kind: String, year: String) -> String {
        var fields: [String] = []
        if !compiler.isEmpty { fields.append("author    = {\(familyGiven(compiler))}") }
        fields.append("title     = {\(title)}")
        let what = kind == "reading-list" ? "Reading list" : "Selection"
        fields.append("howpublished = {\(what)\(compiler.isEmpty ? "" : " compiled by \(compiler)")}")
        if !year.isEmpty { fields.append("year      = {\(year)}") }
        return "@misc{\(citationKey(authors: [compiler], year: year, title: title)),\n" + fields.joined(separator: ",\n") + "\n}"
    }

    private static func workBibTeX(_ piece: Piece) -> String {
        var fields: [String] = []
        if !piece.authors.isEmpty { fields.append("author    = {\(piece.authors.map(familyGiven).joined(separator: " and "))}") }
        fields.append("title     = {\(piece.title)}")
        let inCollection = piece.sourceTitle != piece.title
        if inCollection { fields.append("booktitle = {\(piece.sourceTitle)}") }
        if !piece.sourceEditors.isEmpty { fields.append("editor    = {\(piece.sourceEditors.map(familyGiven).joined(separator: " and "))}") }
        if let year = piece.year, !year.isEmpty { fields.append("year      = {\(year)}") }
        let type = inCollection ? "incollection" : "misc"
        return "@\(type){\(citationKey(authors: piece.authors, year: piece.year ?? "", title: piece.title)),\n" + fields.joined(separator: ",\n") + "\n}"
    }

    private static func citationKey(authors: [String], year: String, title: String) -> String {
        func letters(_ text: String) -> String { text.lowercased().filter { $0.isLetter } }
        let name = authors.first(where: { !$0.isEmpty }) ?? "anon"
        let family = name.contains(",") ? String(name[name.startIndex..<name.firstIndex(of: ",")!])
            : (name.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? name)
        let skip: Set<String> = ["a", "an", "the", "on", "of", "in", "and", "for"]
        let word = title.split(whereSeparator: { !$0.isLetter }).map { letters(String($0)) }
            .first { !$0.isEmpty && !skip.contains($0) } ?? "untitled"
        return letters(family) + String(year.prefix(4)) + word
    }

    private static func familyGiven(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.contains(","), let space = trimmed.lastIndex(where: \.isWhitespace) else { return trimmed }
        return "\(trimmed[trimmed.index(after: space)...]), \(trimmed[..<space].trimmingCharacters(in: .whitespaces))"
    }

    private static func sentenceList(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }

    private static func mediaType(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "webp": return "image/webp"
        case "usdz": return "model/vnd.usdz+zip"
        case "glb": return "model/gltf-binary"
        case "gltf": return "model/gltf+json"
        default: return "image/jpeg"
        }
    }

    /// A deterministic UUID from a seed, as AuthorKit derives identities.
    static func stableUUID(from seed: String) -> String {
        var bytes = Array(SHA256.hash(data: Data("origami-text:\(seed)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        func slice(_ from: Int, _ to: Int) -> Substring {
            hex[hex.index(hex.startIndex, offsetBy: from)..<hex.index(hex.startIndex, offsetBy: to)]
        }
        return "\(slice(0, 8))-\(slice(8, 12))-\(slice(12, 16))-\(slice(16, 20))-\(slice(20, 32))"
    }

    static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static let containerXML = """
    <?xml version="1.0" encoding="utf-8"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
    <rootfiles>
    <rootfile full-path="package.opf" media-type="application/oebps-package+xml"/>
    </rootfiles>
    </container>
    """

    private static let defaultCSS = """
    body { font-family: Georgia, serif; line-height: 1.5; max-width: 40em; margin: 0 auto; padding: 1em; }
    header h1 { font-size: 1.8em; margin-bottom: 0.2em; }
    .byline { color: #555555; font-style: italic; margin-top: 0.8em; }
    .work-authors { font-style: normal; font-weight: bold; margin-top: 0; }
    .compiler { color: #555555; font-style: italic; }
    ol.works { margin-top: 2em; }
    ol.works li { margin-bottom: 0.6em; }
    .work-note { color: #555555; }
    figure { text-align: center; margin: 1.5em 0; }
    img { max-width: 100%; }
    """
}

// MARK: - Text helpers

nonisolated enum BinderText {
    static func capture(in text: String, _ pattern: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)),
              match.numberOfRanges > 1, match.range(at: 1).location != NSNotFound else { return nil }
        return (text as NSString).substring(with: match.range(at: 1))
    }

    /// Every match: the first group where the pattern has one, else the
    /// whole match.
    static func captures(in text: String, _ pattern: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let whole = text as NSString
        return expression.matches(in: text, range: NSRange(location: 0, length: whole.length)).map { match in
            let range = match.numberOfRanges > 1 && match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range
            return whole.substring(with: range)
        }
    }

    static func tagText(in xml: String, _ tag: String) -> String? {
        capture(in: xml, "<\(tag)\\b[^>]*>([^<]*)</\(tag)>").map(unescaped).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    static func tagTexts(in xml: String, _ tag: String) -> [String] {
        captures(in: xml, "<\(tag)\\b[^>]*>([^<]*)</\(tag)>").map(unescaped)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    static func unescaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'").replacingOccurrences(of: "&amp;", with: "&")
    }

    static func plain(_ xhtml: String) -> String {
        unescaped(xhtml.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func removing(in text: String, _ pattern: String) -> String {
        text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }

    /// Rewrites the first group of every match; nil keeps the match.
    static func replacingCaptures(in text: String, _ pattern: String, _ replacement: (String) -> String?) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
        var out = text
        let whole = text as NSString
        for match in expression.matches(in: text, range: NSRange(location: 0, length: whole.length)).reversed() {
            let value = whole.substring(with: match.range(at: 1))
            guard let replaced = replacement(value) else { continue }
            out = (out as NSString).replacingCharacters(in: match.range(at: 1), with: replaced)
        }
        return out
    }

    enum AnchorFate { case relink(String), unlink }

    /// Every `<a … href="…">text</a>`: relinked, unlinked to its text, or
    /// (nil) left alone.
    static func replacingAnchors(in text: String, _ decide: (String, String) -> AnchorFate?) -> String {
        guard let expression = try? NSRegularExpression(pattern: "(?s)<a\\b([^>]*)\\bhref=\"([^\"]*)\"([^>]*)>(.*?)</a>") else { return text }
        var out = text
        let whole = text as NSString
        for match in expression.matches(in: text, range: NSRange(location: 0, length: whole.length)).reversed() {
            let href = whole.substring(with: match.range(at: 2))
            let inner = whole.substring(with: match.range(at: 4))
            guard let fate = decide(href, inner) else { continue }
            let replacement: String
            switch fate {
            case .relink(let newHref):
                replacement = "<a\(whole.substring(with: match.range(at: 1)))href=\"\(EPUBBinderWriter.escaped(newHref))\"\(whole.substring(with: match.range(at: 3)))>\(inner)</a>"
            case .unlink:
                replacement = inner
            }
            out = (out as NSString).replacingCharacters(in: match.range, with: replacement)
        }
        return out
    }
}
