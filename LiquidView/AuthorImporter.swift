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

        // 1. RTFD sub-packages are the richest representation.
        for rtfd in rtfdPackages {
            if let attributed = try? NSAttributedString(url: rtfd, options: [:], documentAttributes: nil),
               hasText(attributed) {
                return ImportResult(title: title, author: author, body: paragraphs(from: attributed))
            }
        }

        // 2. Any member whose content the text system recognizes.
        for file in files {
            if let attributed = readRichText(from: file), hasText(attributed) {
                return ImportResult(title: title, author: author, body: paragraphs(from: attributed))
            }
        }

        // 3. Last resort: text carried inside a JSON member.
        for file in files {
            if let body = paragraphsFromJSON(file), !body.isEmpty {
                return ImportResult(title: title, author: author, body: body)
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
}
