import Foundation
import PDFKit

/// Imports a PDF as a draft: the text layer becomes paragraphs, and when
/// the PDF carries a Visual-Meta appendix its self-citation supplies the
/// title, author, and date — the app reads its own medicine. Scanned PDFs
/// (no text layer) are declined with a clear reason rather than imported
/// as noise.
nonisolated enum PDFImporter {

    struct Result {
        let title: String
        let author: String?
        let date: LiquidDate?
        let body: [LiquidDoc.Paragraph]
    }

    enum PDFImportError: LocalizedError {
        case unreadable
        case noTextLayer

        var errorDescription: String? {
            switch self {
            case .unreadable:
                "Could not open the PDF"
            case .noTextLayer:
                "The PDF has no extractable text — likely a scan. Run OCR on it first, or keep it in Reader and cite it from here."
            }
        }
    }

    static func importFile(at url: URL) throws -> Result {
        guard let pdf = PDFDocument(url: url) else { throw PDFImportError.unreadable }
        let raw = (0..<pdf.pageCount)
            .compactMap { pdf.page(at: $0)?.string }
            .joined(separator: "\n\n")
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 20 else { throw PDFImportError.noTextLayer }

        // Visual-Meta: parsed from the end, as the format instructs. The
        // self-citation is authoritative for title, author, and date; the
        // body ends where the appendix begins — export grows a fresh one.
        var title: String?
        var author: String?
        var date: LiquidDate?
        var content = text
        if let end = text.range(of: "@{visual-meta-end}", options: .backwards),
           let start = text.range(of: VisualMeta.startMarker, options: .backwards,
                                  range: text.startIndex..<end.lowerBound) {
            let block = String(text[start.upperBound..<end.lowerBound])
            if let citationStart = block.range(of: "@{visual-meta-bibtex-self-citation-start}"),
               let citationEnd = block.range(of: "@{visual-meta-bibtex-self-citation-end}"),
               citationStart.upperBound <= citationEnd.lowerBound,
               let entry = BibTeXParser.parse(
                   String(block[citationStart.upperBound..<citationEnd.lowerBound])
                       .trimmingCharacters(in: .whitespacesAndNewlines)
               ).first {
                title = entry.title
                author = entry.fields["author"]
                date = liquidDate(from: entry)
            }
            content = String(text[..<start.lowerBound])
        }

        let body = paragraphs(from: content)
        guard !body.isEmpty else { throw PDFImportError.noTextLayer }
        return Result(title: title ?? url.deletingPathExtension().lastPathComponent,
                      author: author,
                      date: date,
                      body: body)
    }

    /// Citation dates use BibTeX day/month/year (§ conventions).
    private static func liquidDate(from entry: BibTeXEntry) -> LiquidDate? {
        guard let yearString = entry.year, let year = Int(yearString), year > 0 else { return nil }
        let monthNames = ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
                          "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12]
        let month = entry.fields["month"].flatMap { monthNames[String($0.lowercased().prefix(3))] }
        let day = month == nil ? nil : entry.fields["day"].flatMap { Int($0) }
        return LiquidDate(displayYear: year,
                          isBCE: entry.fields["era"] == "1",
                          month: month,
                          day: day)
    }

    /// PDF text arrives line-wrapped by page layout, not by meaning.
    /// Rebuild paragraphs: blank lines always break; a line that ends a
    /// sentence and stops well short of the page's typical measure is a
    /// paragraph's last line; everything else joins with a space.
    static func paragraphs(from text: String) -> [LiquidDoc.Paragraph] {
        let lines = text.strippingEmbeddedObjectMarkers
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let lengths = lines.map(\.count).filter { $0 > 0 }.sorted()
        let typicalLength = lengths.isEmpty ? 80 : lengths[lengths.count / 2]

        var paragraphs: [String] = []
        var current = ""
        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { paragraphs.append(trimmed) }
            current = ""
        }
        for line in lines {
            if line.isEmpty {
                flush()
                continue
            }
            current += current.isEmpty ? line : " " + line
            let endsSentence = line.last.map { ".!?…”\"".contains($0) } ?? false
            if endsSentence, line.count < Int(Double(typicalLength) * 0.75) {
                flush()
            }
        }
        flush()

        return paragraphs.enumerated().map { index, text in
            LiquidDoc.Paragraph(id: "p\(index + 1)", heading: nil, text: text)
        }
    }
}

nonisolated extension String {
    /// Rich sources leave placeholders where images and attachments sat:
    /// U+FFFC (the object replacement character, rendered "[obj]") and
    /// U+FFFD (the decoding-failure mark). Neither is text; both go.
    /// Non-breaking spaces become ordinary ones while we're at it.
    var strippingEmbeddedObjectMarkers: String {
        replacingOccurrences(of: "\u{FFFC}", with: "")
            .replacingOccurrences(of: "\u{FFFD}", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
    }
}
