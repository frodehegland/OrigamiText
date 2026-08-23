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

    /// The identity carrier host. The link's *path* is the document id — never
    /// a filesystem location — so a citation resolves by identity inside the
    /// user's folder. The `https://` shape exists only so foreign editors
    /// (Pages especially) keep the hyperlink; nothing is ever fetched from it.
    /// Both apps agree on this prefix. Change it in one place.
    static let webCarrierPrefix = "https://origamitext.app/o/"

    /// The address as written in the body: `to` or `to#fragment`.
    var address: String { to + (fragment.map { "#\($0)" } ?? "") }

    /// The in-app URL used inside the EPUB body and the reader:
    /// `origamitext://open/<to>?q=<quoted>#<fragment>`.
    var url: String { appendingQuoteAndFragment(to: "origamitext://open/\(to)") }

    /// The Pages/Word-safe carrier written to the clipboard hyperlink:
    /// `https://origamitext.app/o/<to>?q=<quoted>#<fragment>`. Identity in the
    /// path; resolved locally, not over the network.
    var webURL: String { appendingQuoteAndFragment(to: Self.webCarrierPrefix + to) }

    /// Appends the hidden quote (`?q=`) and paragraph (`#fragment`) to a base
    /// URL — shared by the in-app and carrier forms so they never drift.
    private func appendingQuoteAndFragment(to base: String) -> String {
        var string = base
        if !quotedText.isEmpty {
            var allowed = CharacterSet.urlQueryAllowed
            allowed.remove(charactersIn: "&=+#?")
            let encoded = quotedText.addingPercentEncoding(withAllowedCharacters: allowed) ?? quotedText
            string += "?q=\(encoded)"
        }
        if let fragment, !fragment.isEmpty { string += "#\(fragment)" }
        return string
    }

    /// The visible citation marker shown in Word/Pages and as plain text:
    /// `(Author, Year)`, or `(source)` when neither is known. The quoted words
    /// are never shown — they live in the link — so the citation reads as one
    /// tidy package the user is unlikely to edit apart.
    var marker: String {
        let inside = [author, year]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        return inside.isEmpty ? "(source)" : "(\(inside))"
    }

    /// The clean, visible sentence — “Quoted” (Author, Year) — kept for the
    /// native Origami/Author draft editors, which show the quote in full.
    var displaySentence: String { "“\(quotedText)” (\(author), \(year))" }

    /// The form inserted into an Origami/Author draft: the sentence plus the
    /// bracketed address, so the editor makes a span-scoped `cites` link on
    /// save (the quotation before the address becomes the span).
    var insertionText: String { "\(displaySentence) [\(address)]" }

    /// The entry synthesized when the writer supplied no richer BibTeX —
    /// the quoted words (or title), author, year, and the vm-id address:
    /// still one valid entry.
    var fallbackBibTeX: String {
        OrigamiReading.bibTeXEntry(title: quotedText, author: author,
                                   year: year, address: address)
    }
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
        // What every editor receives is pure BibTeX — one entry any
        // reference manager, Author, or plain text field accepts, its
        // extra fields carrying the quote, the reader's annotation, and
        // the vm-id address that reopens the original. The private JSON
        // flavour keeps in-app pastes full-fidelity. (The earlier
        // RTF/HTML hyperlink flavours are gone deliberately: they took
        // precedence in rich editors and the paste was no longer BibTeX.)
        pasteboard.setString(citation.bibtex ?? citation.fallbackBibTeX, forType: .string)
        if let data = try? JSONEncoder().encode(citation) {
            pasteboard.setData(data, forType: type)
        }
    }

    /// The citation as RTF, generated by AppKit from an attributed string whose
    /// marker carries a `.link` — the exact clipboard form TextEdit produces,
    /// which Pages honours (a hand-built RTF `HYPERLINK` field does not survive
    /// Pages' paste importer).
    static func rtf(for citation: OrigamiCitation) -> Data? {
        guard let url = URL(string: citation.webURL) else { return nil }
        let attributed = NSMutableAttributedString(string: citation.marker)
        let range = NSRange(location: 0, length: attributed.length)
        attributed.addAttribute(.link, value: url, range: range)
        return try? attributed.data(
            from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }

    /// A complete HTML document carrying the citation hyperlink — Pages' HTML
    /// paste path wants a full document, not a bare `<a>` fragment.
    private static func htmlDocument(for citation: OrigamiCitation) -> String {
        "<!DOCTYPE html><html><head><meta charset=\"utf-8\"></head><body>"
            + html(for: citation)
            + "</body></html>"
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
        // The visible hyperlink uses the Pages-safe https carrier; the private
        // JSON flavour still carries the exact origamitext:// address.
        "<a href=\"\(citation.webURL)\">\(htmlEscaped(citation.marker))</a>"
    }

    /// Recovers a citation from the first hyperlink whose href is one of ours
    /// — either the in-app `origamitext://open/…` or the https identity carrier
    /// — the lossy fallback (no BibTeX/author/year); the quoted words come from
    /// the `q` query.
    private static func fromHTML(_ html: String) -> OrigamiCitation? {
        guard let expression = try? NSRegularExpression(
            pattern: "href=\"([^\"]+)\"", options: [.caseInsensitive]),
              let match = expression.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let hrefRange = Range(match.range(at: 1), in: html),
              let link = parse(href: String(html[hrefRange])) else { return nil }
        return OrigamiCitation(to: link.to, fragment: link.fragment, rel: "cites",
                               quotedText: link.quote ?? "", author: "", year: "", bibtex: nil)
    }

    /// Splits an Origami citation href — `origamitext://open/<to>` or
    /// `https://…/o/<to>` — into id, `#fragment`, and the `q` quote. Nil for
    /// any other URL, so ordinary links are never mistaken for citations.
    nonisolated static func parse(href: String) -> (to: String, fragment: String?, quote: String?)? {
        var rest: String
        if let range = href.range(of: "origamitext://open/") {
            rest = String(href[range.upperBound...])
        } else if href.hasPrefix(OrigamiCitation.webCarrierPrefix) {
            rest = String(href.dropFirst(OrigamiCitation.webCarrierPrefix.count))
        } else {
            return nil
        }
        var fragment: String?
        if let hash = rest.firstIndex(of: "#") {
            fragment = String(rest[rest.index(after: hash)...])
            rest = String(rest[..<hash])
        }
        var quote: String?
        if let mark = rest.firstIndex(of: "?") {
            quote = queryValue(named: "q", in: String(rest[rest.index(after: mark)...]))
            rest = String(rest[..<mark])
        }
        let to = rest.removingPercentEncoding ?? rest
        guard !to.isEmpty else { return nil }
        return (to, fragment?.isEmpty == false ? fragment : nil, quote?.isEmpty == false ? quote : nil)
    }

    /// Pulls a value out of an `a=1&b=2` query string, percent-decoded.
    nonisolated private static func queryValue(named name: String, in query: String?) -> String? {
        guard let query else { return nil }
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.first == name {
                let raw = parts.count == 2 ? parts[1] : ""
                return raw.removingPercentEncoding ?? raw
            }
        }
        return nil
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
