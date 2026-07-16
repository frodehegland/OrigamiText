import Foundation

/// A quotation copied with Reader's "Copy Quote" from a PDF carrying
/// Visual-Meta: curly-quoted text, an attribution line, and a locator line
/// whose parenthesized key is the document's identity (author slug plus
/// ISO 8601 creation time).
nonisolated struct ReaderQuote {
    let quote: String
    let author: String
    let title: String
    let page: String?
    let created: Date?

    /// The library address this document has — or will have — as an Origami Document.
    /// Derivable in advance because ids are deterministic from author and
    /// creation time, so the citation resolves when the document arrives.
    var derivedID: String? {
        guard let created else { return nil }
        return LiquidAddress.makeID(author: author, created: created)
    }

    /// A BibTeX record synthesized from the quote's metadata, so the link
    /// carries full provenance into the Visual-Meta references block.
    var synthesizedBibTeX: String? {
        guard let created else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let year = calendar.component(.year, from: created)

        func alphanumeric(_ string: String) -> String {
            String(string.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        }
        let surname = author.split(separator: " ").last.map(String.init) ?? "unknown"
        let firstWord = title.split(separator: " ").first.map(String.init) ?? "untitled"
        let key = alphanumeric(surname) + String(year) + alphanumeric(firstWord)

        var fields = [
            "author = {\(author)}",
            "title = {\(title)}",
            "year = {\(year)}",
        ]
        if let page { fields.append("pages = {\(page)}") }
        fields.append("vm-id = {\(formatter.string(from: created))}")
        return "@article{\(key.isEmpty ? "quoted\(year)" : key),\n\(fields.joined(separator: ",\n"))\n}"
    }

    /// The paste replacement: the quote healed into one paragraph, then an
    /// attribution line carrying the citation address.
    var draftText: String {
        var attribution = "— \(author), '\(title)'"
        if let page { attribution += ", p.\(page)" }
        if let derivedID { attribution += " [\(derivedID)]" }
        return "\(quote)\n\n\(attribution)"
    }
}

nonisolated enum ReaderQuoteParser {

    /// Parses Reader's Copy Quote format. Returns nil for anything else,
    /// so ordinary pasting is never hijacked.
    static func parse(_ text: String) -> ReaderQuote? {
        let quoteMarks = CharacterSet(charactersIn: "“”")
        guard let first = text.rangeOfCharacter(from: quoteMarks),
              let last = text.rangeOfCharacter(from: quoteMarks, options: .backwards),
              first.lowerBound < last.lowerBound
        else { return nil }

        // Heal the PDF's hard line wraps into one flowing paragraph.
        let quote = String(text[first.upperBound..<last.lowerBound])
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !quote.isEmpty else { return nil }

        let lines = String(text[last.upperBound...])
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let attributionLine = lines.first else { return nil }

        // "Frode Alexander Hegland. 'Use Cases for Headset Work'.  p.3"
        let attributionPattern = "^(.+?)\\.\\s*['‘](.+?)['’]\\.?(?:\\s*p\\.?\\s*(\\S+))?$"
        guard let regex = try? NSRegularExpression(pattern: attributionPattern),
              let match = regex.firstMatch(
                  in: attributionLine,
                  range: NSRange(attributionLine.startIndex..., in: attributionLine)),
              let authorRange = Range(match.range(at: 1), in: attributionLine),
              let titleRange = Range(match.range(at: 2), in: attributionLine)
        else { return nil }

        let author = String(attributionLine[authorRange]).trimmingCharacters(in: .whitespaces)
        let title = String(attributionLine[titleRange]).trimmingCharacters(in: .whitespaces)
        var page: String?
        if match.range(at: 3).location != NSNotFound,
           let pageRange = Range(match.range(at: 3), in: attributionLine) {
            page = String(attributionLine[pageRange])
        }

        // Locator key: "…(Frode-Hegland-2026-07-11T09_32_52Z)"
        var created: Date?
        let locatorPattern = "\\((?:.+?)-(\\d{4}-\\d{2}-\\d{2}T\\d{2}_\\d{2}_\\d{2}Z)\\)"
        if let locatorRegex = try? NSRegularExpression(pattern: locatorPattern) {
            for line in lines.dropFirst() {
                if let locatorMatch = locatorRegex.firstMatch(
                       in: line, range: NSRange(line.startIndex..., in: line)),
                   let stampRange = Range(locatorMatch.range(at: 1), in: line) {
                    let stamp = line[stampRange].replacingOccurrences(of: "_", with: ":")
                    created = LiquidDoc.parseISO8601(stamp)
                    break
                }
            }
        }

        return ReaderQuote(quote: quote, author: author, title: title, page: page, created: created)
    }
}
