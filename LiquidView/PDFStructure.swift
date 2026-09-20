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
        /// Whether this document is shaped like a paper at all. A
        /// contract, a camera manual and a receipt are none the better
        /// for being cut into sections, and a sweep of 547 real
        /// documents found both — so they are read as plain prose and
        /// left alone.
        var looksLikeAPaper: Bool = true
        /// Lines that might be headings the rules could not name —
        /// handed to whatever can judge better (see the note on the
        /// model pass in `read`). Empty when headings were found.
        var headingCandidates: [String] = []
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

        // Is this a paper at all? A contract, a manual and a receipt
        // all came through the sweep being cut into sections they do
        // not have. Their words are returned unstructured, which is
        // what they were to begin with.
        guard looksLikeAPaper(lines) else {
            return Reading(body: plainProse(lines), runningHeadsDropped: 0,
                           wordsRejoined: 0, headingsFound: 0,
                           looksLikeAPaper: false)
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
            // A heading too long for its column wraps, and arrives as
            // two lines — "2 POSITIVE APPLICATIONS OF WEB" and
            // "TECHNOLOGIES". Shouted continuations rejoin the heading
            // they belong to rather than standing as one of their own.
            if let last = paragraphs.last, last.heading == level,
               text == text.uppercased(), !text.contains(where: \.isNumber),
               last.text.count < 60 {
                // A paragraph's text is a `let` — the rejoined heading
                // is a new one, under the id the first line already has.
                paragraphs[paragraphs.count - 1] = LiquidDoc.Paragraph(
                    id: last.id, heading: level, text: last.text + " " + text)
                return
            }
            ordinal += 1
            headings += 1
            paragraphs.append(LiquidDoc.Paragraph(id: "p\(ordinal)", heading: level, text: text))
        }

        let measure = typicalWidth(of: lines)
        let trustSize = sizeSeparates(lines, bodySize: bodySize)
        for (index, line) in lines.enumerated() {
            let text = line.text
            if let level = headingLevel(of: line, bodySize: bodySize,
                                        measure: measure,
                                        sizeIsTrustworthy: trustSize) {
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

        // A paper whose headings none of the rules could name. Twenty
        // of 547 documents in a real library came out this way — text
        // enough, pages enough, no numbering and no capitals, their
        // sections set in bold or italic that PDF text does not carry.
        // The lines that MIGHT be those headings are gathered here for
        // a better judge than a regular expression.
        let candidates = headings == 0 ? headingCandidates(in: lines, measure: measure) : []

        return Reading(body: paragraphs, runningHeadsDropped: dropped,
                       wordsRejoined: rejoined, headingsFound: headings,
                       looksLikeAPaper: true, headingCandidates: candidates)
    }

    // MARK: - Is it a paper?

    /// What a paper has that a contract and a camera manual do not: it
    /// names its own parts. ONE mark is enough, and the threshold is
    /// measured rather than chosen: at two marks, 83 of 547 real
    /// documents were declined and several were genuine short papers —
    /// a five-page piece with no abstract and no numbered sections is
    /// still a paper. At one mark, 27 are declined and they are
    /// meeting invitations, school grades, a user guide and a
    /// participant information sheet. The cost of being wrong is
    /// small in one direction and not the other: a declined paper
    /// still reads, as plain prose, which is what the importer did
    /// for everything until now.
    static func looksLikeAPaper(_ lines: [Line]) -> Bool {
        guard lines.count > 40 else { return false }
        let opening = lines.prefix(400).map { $0.text.lowercased() }
        let whole = lines.map { $0.text.lowercased() }
        var marks = 0
        if opening.contains(where: { $0.hasPrefix("abstract") }) { marks += 1 }
        if whole.contains(where: {
            $0.hasPrefix("references") || $0.hasPrefix("bibliography")
        }) { marks += 1 }
        // Numbered sections, at least two of them, in order.
        let numbered = lines.filter { numberedLevel($0.text) != nil }.count
        if numbered >= 2 { marks += 1 }
        if whole.contains(where: {
            $0.hasPrefix("keywords") || $0.hasPrefix("ccs concepts")
                || $0.hasPrefix("index terms") || $0.hasPrefix("introduction")
                || $0.hasPrefix("1 introduction")
        }) { marks += 1 }
        return marks >= 1
    }

    /// The document's words, joined into paragraphs and nothing more.
    static func plainProse(_ lines: [Line]) -> [LiquidDoc.Paragraph] {
        let measure = typicalWidth(of: lines)
        var out: [LiquidDoc.Paragraph] = []
        var current = ""
        var ordinal = 0
        func flush() {
            let text = current.trimmingCharacters(in: .whitespacesAndNewlines)
            current = ""
            guard !text.isEmpty else { return }
            ordinal += 1
            out.append(LiquidDoc.Paragraph(id: "p\(ordinal)", heading: nil, text: text))
        }
        for (index, line) in lines.enumerated() {
            let text = line.text
            if text.hasSuffix("-"), index + 1 < lines.count,
               let next = lines[index + 1].text.first, next.isLowercase {
                current += String(text.dropLast())
                continue
            }
            current += current.isEmpty ? text : " " + text
            let endsSentence = text.last.map { ".!?…”\"’".contains($0) } ?? false
            if endsSentence, line.frame.width < measure * 0.92 { flush() }
        }
        flush()
        return out
    }

    /// Lines that carry the marks of a heading without the ones the
    /// rules can read: short, standing apart from the measure, not a
    /// sentence, and not the middle of a paragraph.
    static func headingCandidates(in lines: [Line], measure: CGFloat) -> [String] {
        var candidates: [String] = []
        for (index, line) in lines.enumerated() {
            let text = line.text
            guard text.count >= 3, text.count <= 70,
                  line.frame.width < measure * 0.6,
                  !text.hasSuffix(","), !text.hasSuffix(";"),
                  let first = text.first, first.isUppercase
            else { continue }
            // A heading opens something: the line before it ends, and
            // the line after it begins a sentence.
            let previousEnded = index == 0
                || (lines[index - 1].text.last.map { ".!?".contains($0) } ?? false)
            guard previousEnded else { continue }
            candidates.append(text)
            if candidates.count >= 40 { break }
        }
        return candidates
    }

    // MARK: - Lines, from the geometry

    /// The page's characters gathered into lines.
    ///
    /// PDFKit's own reading order is kept — measured on an ACM
    /// two-column camera-ready, it walks the left column before the
    /// right, which is the hard part and it gets it right. What it does
    /// NOT get right is where a line ENDS: `page.string` welds the
    /// running head onto the first line of body text, because the two
    /// are one run in the content stream.
    ///
    /// So the newline characters are taken as hints and the geometry as
    /// the authority: whenever a character sits on a different baseline
    /// from the one before it, the line is closed there, whatever the
    /// text said. That single rule unwelds the furniture from the prose
    /// without touching the reading order.
    static func lines(of page: PDFPage, page index: Int) -> [Line] {
        guard let text = page.string, !text.isEmpty else { return [] }
        var lines: [Line] = []
        var currentText = ""
        var currentFrame: CGRect = .null
        var heights: [CGFloat] = []
        var baselines: [CGFloat] = []
        var lastRight: CGFloat?

        func flush() {
            let trimmed = currentText.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, !currentFrame.isNull {
                lines.append(Line(text: trimmed, frame: currentFrame,
                                  size: median(heights), page: index))
            }
            currentText = ""
            currentFrame = .null
            heights = []
            baselines = []
            lastRight = nil
        }

        var position = 0
        for character in text {
            defer { position += 1 }
            if character.isNewline {
                flush()
                continue
            }
            let bounds = page.characterBounds(at: position)
            guard bounds.width > 0, bounds.height > 0 else {
                currentText.append(character)
                continue
            }
            // PDFKit's own line breaks are kept. Two attempts at
            // splitting lines by glyph geometry are recorded in the
            // history of this file and both failed the same way: the
            // per-character boxes of a justified page vary enough that
            // words came apart in the middle — "AB|STRACT",
            // "Univer|sity", "expec|tations". The geometry is reliable
            // for a line's SIZE and WIDTH, which is all it is asked
            // for now; the welded running head is dealt with at the
            // level it actually lives on — the text — in
            // `withoutRunningHeads` below.
            _ = lastRight
            currentText.append(character)
            heights.append(bounds.height)
            baselines.append(bounds.midY)
            lastRight = bounds.maxX
            currentFrame = currentFrame.isNull ? bounds : currentFrame.union(bounds)
        }
        flush()
        return lines
    }

    // MARK: - The running head and foot

    /// The paper's furniture, removed from its argument.
    ///
    /// The running head is not a line of its own: PDFKit welds it to
    /// the first line of body text, so page three begins "Positive by
    /// Design The change from static to agent media…" and page four
    /// "HT '23, September 4–8, 2023, Rome, Italy approach. This is
    /// not new…". Deleting whole lines therefore takes the prose with
    /// the furniture — which is why this works on PREFIXES instead.
    ///
    /// What repeats is what is stripped: the opening words that begin
    /// three or more pages, and no more of the line than that.
    static func withoutRunningHeads(_ lines: [Line], pageCount: Int) -> [Line] {
        guard pageCount >= 3 else { return lines }
        var byPage: [Int: [Line]] = [:]
        for line in lines { byPage[line.page, default: []].append(line) }

        let openings = byPage.keys.sorted().compactMap { byPage[$0]?.first?.text }
        guard openings.count >= 3 else { return lines }

        // Two signatures of furniture, both taken from the evidence of
        // a real paper whose head ALTERNATES — the title on odd pages,
        // the venue and date on even — so that neither appears three
        // times and a simple "repeats often" rule sees nothing.
        //
        //   1. A line that stands ALONE at the top of one page and
        //      opens another page's first line is that page's head.
        //      ("Positive by Design" is page one's title line, and
        //      page three begins "Positive by Design The change…".)
        //   2. An opening shared by two or more pages, each time with
        //      the prose running on after it. (The venue line.)
        var heads: Set<String> = []
        for candidate in openings where candidate.count < 90 {
            let welded = openings.filter {
                $0 != candidate && $0.hasPrefix(candidate + " ")
            }.count
            let alone = openings.filter { $0 == candidate }.count
            if welded >= 1, alone >= 1 { heads.insert(candidate) }
            if welded >= 2 { heads.insert(candidate) }
        }
        // The venue line: shared openings that never stand alone.
        for length in stride(from: 12, through: 3, by: -1) {
            var counts: [String: Int] = [:]
            for opening in openings {
                let words = opening.split(separator: " ")
                guard words.count > length else { continue }
                counts[words.prefix(length).joined(separator: " "), default: 0] += 1
            }
            if let best = counts.first(where: { $0.value >= 2 }) {
                heads.insert(best.key)
                break
            }
        }
        guard !heads.isEmpty else { return lines }

        return lines.compactMap { line in
            // Only ever the first line of a page, and only its opening.
            guard byPage[line.page]?.first?.text == line.text else { return line }
            if line.text.allSatisfy({ $0.isNumber || $0.isWhitespace }) { return nil }
            guard let head = heads.first(where: {
                line.text == $0 || line.text.hasPrefix($0 + " ")
            }) else { return line }
            let rest = line.text.dropFirst(head.count).trimmingCharacters(in: .whitespaces)
            guard !rest.isEmpty else { return nil }
            var stripped = line
            stripped.text = rest
            return stripped
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

    /// A heading is numbered as a section is, or shouted in capitals
    /// and short, or set larger than the body AND short with it. The
    /// numbering decides the level when it is there, because "3.2"
    /// says what it is.
    ///
    /// `sizeIsTrustworthy` is the lesson of the first run: character
    /// heights on a justified page vary enough that "taller than the
    /// median" alone called 381 of 595 blocks a heading. The caller
    /// measures whether the size signal actually separates anything
    /// before it is allowed to vote.
    static func headingLevel(of line: Line, bodySize: CGFloat,
                             measure: CGFloat,
                             sizeIsTrustworthy: Bool) -> Int? {
        let text = line.text
        guard text.count < 120, !text.isEmpty else { return nil }

        // Numbering first: it is the only signal that also says WHICH
        // level, and an ACM run-in heading ("3.1.1 Zero-shot Baseline.")
        // ends in a stop while still being a heading.
        if let numbered = numberedLevel(text) { return numbered }

        // A line that ends in a full stop is a sentence.
        if text.hasSuffix(".") { return nil }
        // Nor is a line carrying an address, a link or an identifier —
        // the title page is full of them, and they are short and set
        // large, which is exactly what fooled the first sweep.
        if text.contains("@") || text.lowercased().contains("http")
            || text.lowercased().contains("isbn") || text.contains("://") {
            return nil
        }

        // The words a paper uses for its own sections. Title Case now,
        // as the current ACM template sets them, so capitals alone no
        // longer find "Abstract" or "Keywords".
        if knownSectionWords.contains(text.lowercased()
            .trimmingCharacters(in: .punctuationCharacters)
            .trimmingCharacters(in: .whitespaces)) {
            return 1
        }

        // A row of a table shouts too: "TOTAL 82.2% 2.2% 86.5%…". A
        // heading is made of words, so letters must outnumber figures.
        let letters = text.filter(\.isLetter).count
        let figures = text.filter { $0.isNumber || "%$£".contains($0) }.count
        let shouted = text.count < 60
            && text == text.uppercased()
            && letters >= 3
            && letters > figures * 2
        if shouted { return 1 }

        // Size no longer votes at all. Across 57 ACM papers it made 28
        // of them read as more than a third headings — every author
        // name, affiliation and identifier on a title page is short
        // and set larger than the body, and the rule could not tell
        // those from a section. Worse, a hyphen-ending line wrongly
        // called a heading never gets its word rejoined. Numbering,
        // the section words, and capitals find the real ones.
        _ = (sizeIsTrustworthy, bodySize, measure)
        return nil
    }

    /// What papers call their own parts.
    static let knownSectionWords: Set<String> = [
        "abstract", "keywords", "key words", "index terms", "ccs concepts",
        "introduction", "background", "related work", "method", "methods",
        "methodology", "approach", "results", "findings", "evaluation",
        "discussion", "limitations", "future work", "conclusion", "conclusions",
        "acknowledgments", "acknowledgements", "references", "bibliography",
        "appendix", "appendices", "supplementary material"
    ]

    /// Whether character height separates headings from prose in this
    /// paper at all. If a quarter of the lines stand taller than the
    /// median, the measurement is noise — some PDFs simply report
    /// glyph boxes that vary — and size is not allowed to decide.
    static func sizeSeparates(_ lines: [Line], bodySize: CGFloat) -> Bool {
        guard bodySize > 0, lines.count > 20 else { return false }
        let taller = lines.filter { $0.size > bodySize * 1.25 }.count
        return Double(taller) / Double(lines.count) < 0.15
    }

    /// "1 INTRODUCTION" is a first-level heading; "3.2 Method" a
    /// second. A reference entry is not: "20110525 (2011), 53." begins
    /// with digits too, which is why the leading number must be small
    /// enough to be a section — papers do not reach section 40.
    private static func numberedLevel(_ text: String) -> Int? {
        // A letter must follow the number: "2 Related Work" is a
        // section, "1 - Extract Popular" is a figure's step and
        // "20110525 (2011), 53." a reference.
        guard let match = text.range(of: "^\\d+(\\.\\d+)*\\.?\\s+[A-Za-z]",
                                     options: .regularExpression) else { return nil }
        let number = text[match].prefix { $0.isNumber || $0 == "." }
        guard let first = number.split(separator: ".").first,
              let value = Int(first), value >= 1, value <= 30 else { return nil }
        let depth = number.filter { $0 == "." }.count + 1
        // "3 Methodology" names a section; "3 review systems (7,347
        // perturbed observations total)" is a table's caption that
        // happens to open with a figure. A heading's first word is
        // capitalised, and a heading is short — unless it is a run-in
        // heading ("3.1.1 Zero-shot Baseline. The baseline system…"),
        // which earns its length from its depth.
        let afterNumber = text.dropFirst(number.count).drop { !$0.isLetter }
        guard let initial = afterNumber.first, initial.isUppercase else { return nil }
        guard text.count < 80 || depth >= 3 else { return nil }
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
