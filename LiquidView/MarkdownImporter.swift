import Foundation

/// Imports plain Markdown (.md) files as drafts. Headings map to the three
/// Liquid heading levels, blank-line-separated paragraphs are healed into
/// single flowing paragraphs, list/quote lines stand alone, and simple YAML
/// front matter (title:, author:) is honored when present. A leading
/// level-1 heading becomes the document title.
nonisolated enum MarkdownImporter {

    struct ImportResult: Sendable {
        let title: String
        let author: String?
        let body: [LiquidDoc.Paragraph]
    }

    static func importFile(at url: URL) throws -> ImportResult {
        let raw = try String(contentsOf: url, encoding: .utf8)
        var lines = raw.components(separatedBy: .newlines)

        // Simple YAML front matter: --- ... --- at the very top.
        var frontTitle: String?
        var frontAuthor: String?
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let end = lines.dropFirst().firstIndex(where: {
               $0.trimmingCharacters(in: .whitespaces) == "---"
           }) {
            for line in lines[1..<end] {
                let parts = line.split(separator: ":", maxSplits: 1)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2 else { continue }
                let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                if parts[0].lowercased() == "title", !value.isEmpty { frontTitle = value }
                if parts[0].lowercased() == "author", !value.isEmpty { frontAuthor = value }
            }
            lines.removeSubrange(0...end)
        }

        // Group into blocks: blank lines separate paragraphs; headings,
        // rules, list items, and quotes stand alone; wrapped lines within
        // a paragraph are healed into one.
        var blocks: [String] = []
        var current: [String] = []
        func flush() {
            if !current.isEmpty {
                blocks.append(current.joined(separator: " "))
                current = []
            }
        }
        func standsAlone(_ line: String) -> Bool {
            LiquidDoc.markdownHeading(in: line) != nil
                || (line.count >= 3 && line.allSatisfy { $0 == "-" })
                || line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("> ")
        }
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flush()
            } else if standsAlone(trimmed) {
                flush()
                blocks.append(trimmed)
            } else {
                current.append(trimmed)
            }
        }
        flush()

        // A leading level-1 heading is the title, not a body paragraph.
        var title = frontTitle ?? url.deletingPathExtension().lastPathComponent
        if frontTitle == nil,
           let first = blocks.first,
           let heading = LiquidDoc.markdownHeading(in: first),
           heading.level == 1 {
            title = heading.text
            blocks.removeFirst()
        }

        var paragraphs: [LiquidDoc.Paragraph] = []
        for block in blocks {
            let markdown = LiquidDoc.markdownHeading(in: block)
            paragraphs.append(LiquidDoc.Paragraph(id: "p\(paragraphs.count + 1)",
                                                  heading: markdown?.level,
                                                  text: markdown?.text ?? block))
        }
        return ImportResult(title: title, author: frontAuthor, body: paragraphs)
    }
}
