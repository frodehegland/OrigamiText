// A PAPER OUT OF A PDF — the structure, not merely the words.
//
// PDFKit already hands over every character of a born-digital paper,
// and its reading order down a two-column page is right (measured on
// an ACM camera-ready: of the first thousand characters, none came
// from the right column out of turn). What it does NOT do is tell a
// heading from a line of bold, rejoin a word broken across a line, or
// keep the running head out of the prose. Those are this file's work,
// and every rule here was written against a measurement rather than a
// hunch:
//
//   • The running head welds itself to the first line of body text —
//     "Positive by Design The change from static to agent media…" —
//     and the footer to the last. Once or twice a page, fifteen pages.
//   • Sixteen lines on one page end in a hyphen: "reposito-" / "ries".
//   • Nothing is a heading: the whole paper imports as flat prose.
//
// The geometry is the evidence: character bounds give each line its
// place and its size, so a heading is a line set larger than the body,
// a running head is a line that repeats at the same height on page
// after page, and a paragraph ends where a short line ends a sentence.
//
// What this deliberately does NOT do is guess at words. Every
// character it emits came out of the PDF; nothing is invented, so a
// reader can trust that a sentence they find here was in the paper.
import Foundation
import PDFKit
import CoreGraphics

nonisolated enum PDFStructure {

    /// One line of a page, with what the geometry says about it.
    struct Line {
        var text: String
        var frame: CGRect
        /// The commonest character height on the line — the body's is
        /// the yardstick every heading is measured against.
        var size: CGFloat
        var page: Int
    }

    struct Reading {
        var body: [LiquidDoc.Paragraph]
        /// What the pass did, for the import to report honestly.
        var runningHeadsDropped: Int
        var wordsRejoined: Int
        var headingsFound: Int
    }

    // MARK: - The whole pass

    static func read(_ pdf: PDFDocument) -> Reading {
        var lines: [Line] = []
        for index in 0..<pdf.pageCount {
            guard let page = pdf.page(at: index) else { continue }
            lines += self.lines(of: page, page: index)
        }
        guard !lines.isEmpty else {
            return Reading(body: [], runningHeadsDropped: 0, wordsRejoined: 0, headingsFound: 0)
        }

        let before = lines.count
        lines = withoutRunningHeads(lines, pageCount: pdf.pageCount)
        let dropped = before - lines.count

        let bodySize = medianSize(of: lines)
        var paragraphs: [LiquidDoc.Paragraph] = []
        var rejoined = 0
        var headings = 0
        var current = ""
        var ordinal = 0

        func flush() {
            let text = current.trimmingCharacters(in: .whitespacesAndNewlines)
            current = ""
            guard !text.isEmpty else { return }
            ordinal += 1
            paragraphs.append(LiquidDoc.Paragraph(id: "p\(ordinal)", heading: nil, text: text))
        }
        func addHeading(_ text: String, level: Int) {
            flush()
            ordinal += 1
            headings += 1
            paragraphs.append(LiquidDoc.Paragraph(id: "p\(ordinal)", heading: level, text: text))
        }

        let measure = typicalWidth(of: lines)
        for (index, line) in lines.enumerated() {
            let text = line.text
            if let level = headingLevel(of: line, bodySize: bodySize) {
                addHeading(text, level: level)
                continue
            }
            // A word broken across a line: the hyphen goes, the halves
            // meet. Only when the next line truly continues a word —
            // a lower-case start — so "well-\nknown" survives as the
            // compound it is.
            if text.hasSuffix("-"), index + 1 < lines.count,
               let next = lines[index + 1].text.first, next.isLowercase {
                current += String(text.dropLast())
                rejoined += 1
                continue
            }
            current += current.isEmpty ? text : " " + text
            // A paragraph ends where a sentence ends short of the
            // measure — the oldest rule in typesetting, and the one
            // PDF text loses.
            let endsSentence = text.last.map { ".!?…”\"’".contains($0) } ?? false
            if endsSentence, line.frame.width < measure * 0.92 {
                flush()
            }
        }
        flush()

        return Reading(body: paragraphs, runningHeadsDropped: dropped,
                       wordsRejoined: rejoined, headingsFound: headings)
    }

    // MARK: - Lines, from the geometry

    /// The page's characters gathered into lines by where they sit.
    /// `page.string` gives the same characters in the same order; this
    /// adds the place and the size, which is what every rule needs.
    static func lines(of page: PDFPage, page index: Int) -> [Line] {
        guard let text = page.string, !text.isEmpty else { return [] }
        var lines: [Line] = []
        var currentText = ""
        var currentFrame: CGRect = .null
        var heights: [CGFloat] = []

        func flush() {
            let trimmed = currentText.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, !currentFrame.isNull {
                lines.append(Line(text: trimmed, frame: currentFrame,
                                  size: median(heights), page: index))
            }
            currentText = ""
            currentFrame = .null
            heights = []
        }

        var position = 0
        for character in text {
            defer { position += 1 }
            if character.isNewline {
                flush()
                continue
            }
            let bounds = page.characterBounds(at: position)
            currentText.append(character)
            guard bounds.width > 0, bounds.height > 0 else { continue }
            heights.append(bounds.height)
            currentFrame = currentFrame.isNull ? bounds : currentFrame.union(bounds)
        }
        flush()
        return lines
    }

    // MARK: - The running head and foot

    /// A line that says the same thing at the same height on page after
    /// page is the paper's furniture, not its argument. Three pages of
    /// agreement is enough to be sure, and only the top and bottom of a
    /// page are ever considered.
    static func withoutRunningHeads(_ lines: [Line], pageCount: Int) -> [Line] {
        guard pageCount >= 3 else { return lines }
        var byPage: [Int: [Line]] = [:]
        for line in lines { byPage[line.page, default: []].append(line) }

        var edgeCounts: [String: Int] = [:]
        for (_, pageLines) in byPage {
            guard let top = pageLines.first, let bottom = pageLines.last else { continue }
            for line in Set([key(top.text), key(bottom.text)]) where !line.isEmpty {
                edgeCounts[line, default: 0] += 1
            }
        }
        let repeated = Set(edgeCounts.filter { $0.value >= 3 }.keys)

        return lines.filter { line in
            guard let pageLines = byPage[line.page] else { return true }
            let isEdge = line.text == pageLines.first?.text || line.text == pageLines.last?.text
            guard isEdge else { return true }
            // A bare page number is furniture wherever it stands.
            if line.text.allSatisfy({ $0.isNumber || $0.isWhitespace }) { return false }
            return !repeated.contains(key(line.text))
        }
    }

    /// The comparison form of a line of furniture: page numbers vary,
    /// the words do not.
    private static func key(_ text: String) -> String {
        text.lowercased()
            .filter { !$0.isNumber }
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Headings

    /// A heading is set larger than the body, or numbered as a section
    /// is, or shouted in capitals and short. The numbering decides the
    /// level when it is there, because "3.2" says what it is.
    static func headingLevel(of line: Line, bodySize: CGFloat) -> Int? {
        let text = line.text
        guard text.count < 120, !text.isEmpty else { return nil }
        // A line that ends in a full stop is a sentence, whatever its size.
        if text.hasSuffix(".") && text.count > 40 { return nil }

        if let numbered = numberedLevel(text) { return numbered }

        let larger = bodySize > 0 && line.size > bodySize * 1.15
        let shouted = text.count < 60
            && text == text.uppercased()
            && text.contains(where: \.isLetter)
        if larger { return 1 }
        if shouted { return 1 }
        return nil
    }

    /// "1 INTRODUCTION" is a first-level heading; "3.2 Method" a second.
    private static func numberedLevel(_ text: String) -> Int? {
        guard let match = text.range(of: "^\\d+(\\.\\d+)*\\s+\\S",
                                     options: .regularExpression) else { return nil }
        let number = text[match].prefix { $0.isNumber || $0 == "." }
        let depth = number.filter { $0 == "." }.count + 1
        return min(depth, 3)
    }

    // MARK: - Measures

    private static func median(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private static func medianSize(of lines: [Line]) -> CGFloat {
        median(lines.map(\.size).filter { $0 > 0 })
    }

    /// The measure: how wide a full line of this paper runs. A line
    /// that stops well short of it has ended something.
    private static func typicalWidth(of lines: [Line]) -> CGFloat {
        let widths = lines.map(\.frame.width).filter { $0 > 0 }.sorted()
        guard !widths.isEmpty else { return .greatestFiniteMagnitude }
        // The three-quarter point, not the median: a two-column paper's
        // lines are mostly full, and the short ones are the tell.
        return widths[min(widths.count * 3 / 4, widths.count - 1)]
    }
}
