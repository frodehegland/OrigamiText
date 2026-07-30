import Foundation
import AppKit

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

// MARK: - Copy as Quote: the three-flavour citation clipboard

/// One "Copy as Quote" citation. Written to the clipboard in three flavours
/// (private JSON, HTML hyperlink, clean plain text) so the same command is a
/// clean citation in Word and a full-fidelity link in Origami Text / Author.
nonisolated struct OrigamiCitation: Codable, Sendable {
    /// The target document's address.
    var to: String
    /// The paragraph id within the target, when the cite is paragraph- or
    /// span-scoped.
    var fragment: String?
    /// Link kind; defaults to `cites`.
    var rel: String?
    /// The quoted words (a selection) or the document title (a whole-doc cite)
    /// — what appears in quotation marks.
    var quotedText: String
    var author: String
    var year: String
    /// The citation's BibTeX, when known — carried for full provenance.
    var bibtex: String?

    /// The address as written in the body: `to` or `to#fragment`.
    var address: String { to + (fragment.map { "#\($0)" } ?? "") }

    /// The `origamitext://` URL used in the HTML hyperlink flavour.
    var url: String { "origamitext://open/\(address)" }

    /// The clean, visible sentence — no machine token — for Word and plain text:
    /// “Quoted” (Author, Year).
    var displaySentence: String { "“\(quotedText)” (\(author), \(year))" }

    /// The form inserted into an Origami/Author draft: the sentence plus the
    /// bracketed address, so the editor makes a span-scoped `cites` link on
    /// save (the quotation before the address becomes the span).
    var insertionText: String { "\(displaySentence) [\(address)]" }
}

/// Reads and writes "Copy as Quote" on the general pasteboard, in three
/// flavours. Readers take the richest available: private JSON → HTML
/// hyperlink → plain text.
@MainActor
enum CitationClipboard {
    /// The private pasteboard type carrying the full citation as JSON.
    static let typeName = "info.futuretextlab.origami-citation"
    static var type: NSPasteboard.PasteboardType { .init(typeName) }

    static func write(_ citation: OrigamiCitation) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(citation.displaySentence, forType: .string)
        pasteboard.setString(html(for: citation), forType: .html)
        if let data = try? JSONEncoder().encode(citation) {
            pasteboard.setData(data, forType: type)
        }
    }

    /// The full citation on the clipboard, if any — private JSON first, then
    /// the HTML hyperlink. `matchingPlainText`, when given, gates on the
    /// pasteboard's plain string equalling the just-inserted text, so a
    /// citation is only consumed on an actual paste of it, never mid-typing.
    static func read(matchingPlainText plain: String? = nil) -> OrigamiCitation? {
        let pasteboard = NSPasteboard.general
        if let plain {
            let current = pasteboard.string(forType: .string)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard current == plain.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        }
        if let data = pasteboard.data(forType: type),
           let citation = try? JSONDecoder().decode(OrigamiCitation.self, from: data) {
            return citation
        }
        if let html = pasteboard.string(forType: .html) {
            return fromHTML(html)
        }
        return nil
    }

    static func html(for citation: OrigamiCitation) -> String {
        "<a href=\"\(citation.url)\">\(htmlEscaped(citation.displaySentence))</a>"
    }

    /// Recovers a citation from an HTML hyperlink whose href is an
    /// `origamitext://` URL — the lossy fallback (no BibTeX); the link's
    /// visible text is the quote.
    private static func fromHTML(_ html: String) -> OrigamiCitation? {
        guard let expression = try? NSRegularExpression(
            pattern: "<a[^>]*href=\"origamitext://open/([^\"#]+)(?:#([^\"]+))?\"[^>]*>(.*?)</a>",
            options: [.dotMatchesLineSeparators, .caseInsensitive]),
              let match = expression.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let toRange = Range(match.range(at: 1), in: html) else { return nil }
        let to = String(html[toRange])
        let fragment = Range(match.range(at: 2), in: html).map { String(html[$0]) }
        let visible = Range(match.range(at: 3), in: html)
            .map { htmlStripped(String(html[$0])) } ?? ""
        return OrigamiCitation(to: to, fragment: fragment, rel: "cites",
                               quotedText: visible, author: "", year: "", bibtex: nil)
    }

    private static func htmlEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func htmlStripped(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
