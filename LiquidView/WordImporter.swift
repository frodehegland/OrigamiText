import AppKit

/// Imports Word documents (.docx, .doc) as drafts. AppKit reads the file
/// into rich text; headings are recovered from the paragraph outline level
/// when Word's heading styles survive, otherwise from font size relative to
/// the body text. Bold and italic runs become inline markdown, list items
/// become dashed lines, and a leading level-1 heading becomes the document
/// title. Embedded images are dropped (the format carries text only).
nonisolated enum WordImporter {

    struct ImportResult: Sendable {
        let title: String
        let author: String?
        let body: [LiquidDoc.Paragraph]
    }

    static func importFile(at url: URL) throws -> ImportResult {
        var documentAttributes: NSDictionary?
        let rich = try NSAttributedString(url: url,
                                          options: [:],
                                          documentAttributes: &documentAttributes)

        // The body point size — the most common size weighted by character
        // count — is the baseline against which headings are judged.
        var sizeWeights: [Int: Int] = [:]
        rich.enumerateAttribute(.font, in: NSRange(location: 0, length: rich.length)) { value, range, _ in
            guard let font = value as? NSFont else { return }
            sizeWeights[Int(font.pointSize.rounded()), default: 0] += range.length
        }
        let bodySize = sizeWeights.max { $0.value < $1.value }?.key ?? 12

        var blocks: [(heading: Int?, text: String)] = []
        let nsString = rich.string as NSString
        nsString.enumerateSubstrings(in: NSRange(location: 0, length: nsString.length),
                                     options: .byParagraphs) { _, range, _, _ in
            guard range.length > 0,
                  !nsString.substring(with: range)
                      .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return }
            let attributes = rich.attributes(at: range.location, effectiveRange: nil)
            let style = attributes[.paragraphStyle] as? NSParagraphStyle
            let heading = headingLevel(for: range, attributes: attributes,
                                       bodySize: bodySize, in: rich)
            var text = heading == nil
                ? markdownText(for: range, in: rich)
                : plainText(for: range, in: rich)
            if let style, !style.textLists.isEmpty {
                text = "- " + strippingListMarker(text)
            }
            if !text.isEmpty {
                blocks.append((heading, text))
            }
        }

        // Word's Title property, else a leading level-1 heading, else the
        // filename — same order of preference as the Markdown importer.
        let metaTitle = (documentAttributes?[NSAttributedString.DocumentAttributeKey.title] as? String)?
            .trimmingCharacters(in: .whitespaces)
        var title = metaTitle?.isEmpty == false
            ? metaTitle!
            : url.deletingPathExtension().lastPathComponent
        if let first = blocks.first, first.heading == 1,
           metaTitle?.isEmpty != false || first.text == title {
            title = first.text
            blocks.removeFirst()
        }
        let author = (documentAttributes?[NSAttributedString.DocumentAttributeKey.author] as? String)?
            .trimmingCharacters(in: .whitespaces)

        var paragraphs: [LiquidDoc.Paragraph] = []
        for block in blocks {
            paragraphs.append(LiquidDoc.Paragraph(id: "p\(paragraphs.count + 1)",
                                                  heading: block.heading,
                                                  text: block.text))
        }
        return ImportResult(title: title,
                            author: author?.isEmpty == false ? author : nil,
                            body: paragraphs)
    }

    /// Word heading styles usually arrive as an outline level; when they
    /// don't, a short paragraph notably larger than the body text is taken
    /// as a heading, ranked by how much larger.
    private static func headingLevel(for range: NSRange,
                                     attributes: [NSAttributedString.Key: Any],
                                     bodySize: Int,
                                     in rich: NSAttributedString) -> Int? {
        if let style = attributes[.paragraphStyle] as? NSParagraphStyle, style.headerLevel > 0 {
            return min(style.headerLevel, 3)
        }
        guard range.length <= 120, let font = attributes[.font] as? NSFont else { return nil }
        let size = Int(font.pointSize.rounded())
        guard size >= bodySize + 2 else { return nil }
        if size >= bodySize + 8 { return 1 }
        if size >= bodySize + 4 { return 2 }
        return 3
    }

    /// The paragraph's text with bold and italic runs wrapped in markdown
    /// markers. Runs are coalesced by trait first so a bold phrase split
    /// across several font runs gets one pair of markers.
    private static func markdownText(for range: NSRange, in rich: NSAttributedString) -> String {
        var pieces: [(text: String, bold: Bool, italic: Bool)] = []
        rich.enumerateAttributes(in: range) { attributes, runRange, _ in
            let traits = (attributes[.font] as? NSFont)?.fontDescriptor.symbolicTraits ?? []
            let text = (rich.string as NSString).substring(with: runRange)
            let bold = traits.contains(.bold)
            let italic = traits.contains(.italic)
            if let last = pieces.last, last.bold == bold, last.italic == italic {
                pieces[pieces.count - 1].text += text
            } else {
                pieces.append((text, bold, italic))
            }
        }
        var result = ""
        for piece in pieces {
            let cleaned = sanitize(piece.text)
            let core = cleaned.trimmingCharacters(in: .whitespaces)
            guard !core.isEmpty else {
                result += cleaned
                continue
            }
            let marker = piece.bold && piece.italic ? "***" : piece.bold ? "**" : piece.italic ? "*" : ""
            // Markers hug the words; surrounding whitespace stays outside.
            let leading = cleaned.prefix(while: { $0 == " " || $0 == "\t" })
            let trailing = cleaned.reversed().prefix(while: { $0 == " " || $0 == "\t" }).reversed()
            result += "\(leading)\(marker)\(core)\(marker)\(String(trailing))"
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func plainText(for range: NSRange, in rich: NSAttributedString) -> String {
        sanitize((rich.string as NSString).substring(with: range))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Drops attachment placeholders (embedded images and the like) and
    /// normalizes the whitespace Word likes to leave behind.
    private static func sanitize(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{FFFC}", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    /// Cocoa's list import keeps the literal marker ("\t•\t1." etc.) in the
    /// text; remove it since the dash prefix carries the meaning.
    private static func strippingListMarker(_ text: String) -> String {
        var result = Substring(text).drop(while: { $0 == " " || $0 == "\t" })
        while let first = result.first, "•◦▪‣·–-".contains(first) {
            result = result.dropFirst().drop(while: { $0 == " " || $0 == "\t" })
        }
        if let dot = result.firstIndex(where: { $0 == "." || $0 == ")" }),
           result.startIndex < dot,
           result[result.startIndex..<dot].allSatisfy(\.isNumber) {
            result = result[result.index(after: dot)...].drop(while: { $0 == " " || $0 == "\t" })
        }
        return String(result)
    }
}
