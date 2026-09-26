import Foundation

// Gemtext — the native hypertext of the Gemini protocol.
//
// MIME `text/gemini`, extensions .gmi/.gemini, UTF-8, strictly
// line-oriented: a document is a flat sequence of lines, each classified by
// its first characters in one top-to-bottom pass. There is no inline markup
// of any kind — no inline links, no emphasis, no images. Styling belongs
// entirely to the client; authors have no display control, by design.
//
// The format is frozen and the community is explicitly anti-extension, so
// nothing here invents syntax: everything Origami needs beyond the six line
// types rides in the ignorable Visual-Meta appendix (§3.4), which any
// Gemini client renders as visible monospaced text — Visual-Meta's whole
// premise.
//
// Parse leniently, emit strictly: accept LF/CRLF/mixed and `#Heading`
// without the space on the way in; write a space after the hashes, LF
// endings, UTF-8, no BOM on the way out.

nonisolated enum Gemtext {

    /// The unofficial MIME type, its charset default, and the extensions
    /// the importer answers to.
    static let mimeType = "text/gemini"
    static let fileExtensions = ["gmi", "gemini"]

    // MARK: - Line types

    /// One classified source line. `preLine` only ever appears between a
    /// pair of `preToggle`s, where every line is verbatim.
    enum Line: Hashable, Sendable {
        case text(String)
        case link(url: String, label: String?)
        case heading(level: Int, text: String)      // 1...3, never deeper
        case listItem(String)
        case quote(String)
        case preToggle(alt: String?)
        case preLine(String)
        case blank
    }

    // MARK: - Tokenizer

    /// Classifies a whole document, one pass, no lookahead. Pure: identical
    /// bytes in, identical tokens out.
    static func tokenize(_ source: String) -> [Line] {
        var lines: [Line] = []
        var preformatted = false
        for raw in sourceLines(source) {
            // Inside a preformatted block only a fence toggles; everything
            // else — whitespace-only lines included — is verbatim.
            if preformatted {
                if raw.hasPrefix("```") {
                    preformatted = false
                    // Text after the closing fence is ignored, per spec.
                    lines.append(.preToggle(alt: nil))
                } else {
                    lines.append(.preLine(raw))
                }
                continue
            }
            if raw.hasPrefix("```") {
                preformatted = true
                let alt = String(raw.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                lines.append(.preToggle(alt: alt.isEmpty ? nil : alt))
                continue
            }
            if raw.hasPrefix("=>") {
                if let link = link(in: raw) {
                    lines.append(link)
                } else {
                    // An empty URL is not a link line; the words stand.
                    lines.append(.text(raw))
                }
                continue
            }
            if raw.hasPrefix("#") {
                let hashes = raw.prefix(while: { $0 == "#" }).count
                // Three levels exist and no more: `####` is plain text.
                if hashes <= 3 {
                    let text = String(raw.dropFirst(hashes))
                        .trimmingCharacters(in: .whitespaces)
                    lines.append(.heading(level: hashes, text: text))
                    continue
                }
                lines.append(.text(raw))
                continue
            }
            // The bullet is asterisk-space exactly: `*x` is plain text.
            if raw.hasPrefix("* ") {
                lines.append(.listItem(String(raw.dropFirst(2))))
                continue
            }
            if raw.hasPrefix(">") {
                var content = String(raw.dropFirst())
                // The space after `>` is conventional, not required — one
                // is dropped when present so quotes don't gain an indent.
                if content.hasPrefix(" ") { content.removeFirst() }
                lines.append(.quote(content))
                continue
            }
            if raw.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append(.blank)
                continue
            }
            lines.append(.text(raw))
        }
        // An unterminated preformatted block closes at EOF rather than
        // failing the parse.
        if preformatted { lines.append(.preToggle(alt: nil)) }
        return lines
    }

    /// The source split into lines: a leading BOM goes, CRLF and LF both
    /// terminate, and the newline that ends the file is a terminator, not
    /// an empty last line.
    private static func sourceLines(_ source: String) -> [String] {
        var text = source
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = text.components(separatedBy: "\n")
        if text.hasSuffix("\n"), !lines.isEmpty { lines.removeLast() }
        return lines
    }

    /// `=>`, whitespace, a URL of non-whitespace characters, optional
    /// whitespace, and a label to end of line.
    private static func link(in raw: String) -> Line? {
        let afterArrow = raw.dropFirst(2).drop(while: { $0 == " " || $0 == "\t" })
        let url = afterArrow.prefix(while: { $0 != " " && $0 != "\t" })
        guard !url.isEmpty else { return nil }
        let label = afterArrow.dropFirst(url.count)
            .drop(while: { $0 == " " || $0 == "\t" })
            .trimmingCharacters(in: .whitespaces)
        return .link(url: String(url), label: label.isEmpty ? nil : label)
    }

    // MARK: - Assembly into the document model

    /// A parsed gemtext document, ready to become a `LiquidDoc`.
    struct Assembled: Sendable {
        /// A leading level-1 heading, else the caller's fallback.
        let title: String
        let body: [LiquidDoc.Paragraph]
        /// SHA-256 of the raw source bytes — exact-version provenance.
        let sourceDigest: String
        /// SHA-256 over the assembled block content — the same digest the
        /// rest of the app takes of derived documents (OrigamiMath §6.3).
        let contentDigest: String
        /// Every link line's resolved URL, in source order.
        let links: [String]
    }

    /// Tokens → blocks. One source line is one block: adjacent short lines
    /// are never merged, which is what preserves poems and deliberately
    /// broken lines exactly as authored.
    ///
    /// Element ids are `gmi-L<n>`, n being the 1-based line number the
    /// block begins on (the opening fence, for preformatted blocks), so
    /// identical bytes in yield identical ids out, always — and they are
    /// unique per document by construction. Those line numbers are also
    /// what lets the export put the blank lines back exactly where the
    /// source had them, without the document model needing a per-block
    /// attribute for spacing.
    static func assemble(_ source: String, base: URL? = nil,
                         fallbackTitle: String) -> Assembled {
        let lines = tokenize(source)
        var paragraphs: [LiquidDoc.Paragraph] = []
        var links: [String] = []

        // Line numbers count source lines, and the token stream holds one
        // token per source line — except the synthetic closing fence an
        // unterminated block earns at EOF, which claims no line of its own.
        var lineNumber = 0
        var index = 0
        func add(_ id: String, heading: Int? = nil, _ text: String) {
            paragraphs.append(LiquidDoc.Paragraph(id: id, heading: heading, text: text))
        }

        while index < lines.count {
            lineNumber += 1
            let id = "gmi-L\(lineNumber)"
            switch lines[index] {
            case .blank:
                index += 1

            case .text(let text):
                add(id, text)
                index += 1

            case .heading(let level, let text):
                add(id, heading: level, text)
                index += 1

            case .listItem(let item):
                // The format's list convention, as the Markdown import
                // also writes it: the marker leads the words, so a reader
                // without list support loses nothing.
                add(id, "* " + item)
                index += 1

            case .quote(let quoted):
                add(id, "> " + quoted)
                index += 1

            case .link(let url, let label):
                // A gemtext link is a standalone block-level object. As a
                // paragraph holding nothing but one anchor it round-trips
                // back to a `=>` line (see `isLinkOnly`) instead of being
                // unfolded as an inline-link paragraph.
                let resolved = resolve(url, against: base)
                links.append(resolved)
                let words = label ?? url
                add(id, "[\(escapedLinkLabel(words))](\(resolved))")
                index += 1

            case .preToggle(let alt):
                // The fence and everything inside it is one block, with the
                // alt text in the fence's own slot — where it doubles as
                // the language name and the accessibility description.
                var content: [String] = []
                var cursor = index + 1
                while cursor < lines.count {
                    if case .preLine(let verbatim) = lines[cursor] {
                        content.append(verbatim)
                        cursor += 1
                    } else {
                        break
                    }
                }
                // The closing fence, when the source had one.
                var consumed = cursor - index
                if cursor < lines.count, case .preToggle = lines[cursor] {
                    consumed += 1
                }
                add(id, "```\(alt ?? "")\n\(content.joined(separator: "\n"))\n```")
                lineNumber += consumed - 1
                index += consumed

            case .preLine(let verbatim):
                // Only reachable from a malformed token stream; treat the
                // words as words rather than dropping them.
                add(id, verbatim)
                index += 1
            }
        }

        // A leading level-1 heading is the document's title, not a body
        // block — the same rule the Markdown import follows.
        var title = fallbackTitle
        if let first = paragraphs.first, first.heading == 1, !first.text.isEmpty {
            title = first.text
            paragraphs.removeFirst()
        }

        return Assembled(title: title,
                         body: paragraphs,
                         sourceDigest: OrigamiMath.sha256Hex(source),
                         contentDigest: contentDigest(of: paragraphs),
                         links: links)
    }

    /// The canonical digest of assembled content: each block as
    /// `id\theading\ttext`, newline-joined, hashed with the app's one
    /// SHA-256 (OrigamiMath §6.3) so digest code never forks.
    static func contentDigest(of body: [LiquidDoc.Paragraph]) -> String {
        let canonical = body.map { paragraph in
            "\(paragraph.id)\t\(paragraph.heading.map(String.init) ?? "")\t\(paragraph.text)"
        }.joined(separator: "\n")
        return OrigamiMath.sha256Hex(canonical)
    }

    /// A relative link resolved against the document's base — the fetched
    /// URL, or the containing folder for a file import. Absolute URLs and
    /// anything unresolvable pass through untouched.
    static func resolve(_ url: String, against base: URL?) -> String {
        guard let base else { return url }
        if url.contains("://") || url.hasPrefix("mailto:") { return url }
        return URL(string: url, relativeTo: base)?.absoluteURL.absoluteString ?? url
    }

    /// Brackets in a link's words would end the anchor early.
    private static func escapedLinkLabel(_ label: String) -> String {
        label.replacingOccurrences(of: "[", with: "(")
            .replacingOccurrences(of: "]", with: ")")
    }

    // MARK: - Export

    /// One emitted block: its lines, how many source lines it stood on
    /// when it came from gemtext, and what kind it is — enough to space
    /// the file exactly as the source spaced it.
    private struct Block {
        enum Kind { case heading, text, list, quote, link, pre, meta }
        var lines: [String]
        var kind: Kind
        /// The 1-based source line the block began on, from a `gmi-L<n>`
        /// id. Nil for blocks that were never gemtext.
        var sourceLine: Int?
        /// Source lines occupied — more than one only for fences.
        var sourceSpan: Int = 1
    }

    /// The document as a well-formed `.gmi` file: UTF-8, LF endings, no
    /// BOM, one long line per paragraph (the client wraps), and the
    /// Visual-Meta appendix as the final preformatted block.
    ///
    /// Gemtext is the lowest rung of the graceful-degradation ladder, so
    /// the flattening here is decisive: emphasis loses its markers, inline
    /// links unfold to `=>` lines after their paragraph, tables and math
    /// become preformatted blocks, and spatial metadata rides only in the
    /// appendix.
    ///
    /// The document carries no byline: the authoritative author and date
    /// are the appendix's self-citation, and a line the source never had
    /// would cost the round trip.
    static func export(_ doc: LiquidDoc, identity: AuthorIdentity? = nil) -> String {
        let appendixIDs = doc.visualMetaParagraphIDs
        let tablesByID = Dictionary(doc.tables.map { ($0.identifier, $0) },
                                    uniquingKeysWith: { first, _ in first })
        let assetsByID = Dictionary(doc.assets.map { ($0.id, $0) },
                                    uniquingKeysWith: { first, _ in first })
        let citations = citationIndex(for: doc)

        var body = (doc.body ?? []).filter { !appendixIDs.contains($0.id) }
        // The appendix's own divider rule would trail the body as a bare
        // "---" once the appendix itself is gone.
        if body.last?.text.trimmingCharacters(in: .whitespaces) == "---", !appendixIDs.isEmpty {
            body.removeLast()
        }

        // The title leads the page — unless the body already opens with it
        // as a level-1 heading, as a book's own first heading does and as
        // every gemtext import's does once the source is regenerated.
        var blocks: [Block] = []
        let opensWithTitle = body.first?.effectiveHeading == 1
            && collapsed(body.first?.displayText ?? "") == collapsed(doc.title)
        if !opensWithTitle {
            blocks.append(Block(lines: ["# " + collapsed(doc.title)],
                                kind: .heading, sourceLine: 1))
        }
        for paragraph in body {
            blocks.append(contentsOf: gemtextBlocks(for: paragraph,
                                                    tables: tablesByID,
                                                    assets: assetsByID,
                                                    citations: citations))
        }

        blocks.append(contentsOf: referenceBlocks(for: doc))
        blocks.append(Block(lines: visualMetaBlock(for: doc, identity: identity), kind: .meta))

        var lines: [String] = []
        var previous: Block?
        for block in blocks {
            if let previous {
                lines.append(contentsOf: Array(repeating: "",
                                               count: blankLines(between: previous, and: block)))
            }
            lines.append(contentsOf: block.lines)
            previous = block
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// How the file breathes between two blocks. Blocks that came from
    /// gemtext know their own line numbers, so the gap the source had —
    /// none between a poem's lines or a list's items, two where the author
    /// left two — comes back exactly. Everything else gets the default
    /// single blank line, except runs of the same grouping kind (a list,
    /// a block of links, a quotation), which stay tight.
    private static func blankLines(between previous: Block, and next: Block) -> Int {
        if let from = previous.sourceLine, let to = next.sourceLine, to > 1, to > from {
            return max(0, to - (from + previous.sourceSpan))
        }
        switch (previous.kind, next.kind) {
        case (.list, .list), (.quote, .quote), (.link, .link):
            return 0
        default:
            return 1
        }
    }

    /// The source line a `gmi-L<n>` id names.
    private static func sourceLine(inID id: String) -> Int? {
        guard id.hasPrefix("gmi-L") else { return nil }
        return Int(id.dropFirst(5))
    }

    /// One paragraph as one or more gemtext blocks.
    private static func gemtextBlocks(for paragraph: LiquidDoc.Paragraph,
                                      tables: [String: LiquidDoc.Table],
                                      assets: [String: LiquidDoc.Asset],
                                      citations: [String: Citation] = [:]) -> [Block] {
        let text = paragraph.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let line = sourceLine(inID: paragraph.id)
        // A block that came from gemtext carries no inline markup — the
        // format has none — so its words go back out exactly as they
        // arrived: no markers unwrapped, no whitespace collapsed. Only
        // authored Origami paragraphs need flattening.
        let literal = line != nil
        func block(_ lines: [String], _ kind: Block.Kind, span: Int = 1) -> [Block] {
            [Block(lines: lines, kind: kind, sourceLine: line, sourceSpan: span)]
        }

        // A block imported from gemtext as a link line goes back out as
        // one, rather than unfolding as a paragraph plus its link.
        if let anchor = linkOnlyAnchor(in: text) {
            return block([linkLine(url: anchor.url, label: anchor.label)], .link)
        }
        // A live table has no gemtext equivalent: space-padded columns in
        // a preformatted block, which is what a monospace client shows.
        if let id = paragraph.tableID, let table = tables[id] {
            let fence = preBlock(alt: "table", lines: tableLines(table))
            return block(fence, .pre, span: fence.count)
        }
        // A fenced code block keeps its fence and its language as alt.
        if let code = OrigamiReading.fencedCode(in: paragraph.text) {
            let language = fenceLanguage(in: paragraph.text)
            let fence = preBlock(alt: language, lines: code.components(separatedBy: "\n"))
            return block(fence, .pre, span: fence.count)
        }
        // Math: the LaTeX source as authored, in a block marked `math`.
        if text.hasPrefix("$$"), text.hasSuffix("$$"), text.count > 4 {
            let inner = String(text.dropFirst(2).dropLast(2))
                .trimmingCharacters(in: .newlines)
            let fence = preBlock(alt: "math", lines: inner.components(separatedBy: "\n"))
            return block(fence, .pre, span: fence.count)
        }
        // A figure cannot travel in a single text file: the alt text
        // stands as words, and an external rendition earns a link line.
        if let reference = LiquidDoc.imageReference(in: paragraph.text) {
            let alt = reference.alt.isEmpty
                ? (assets[reference.id]?.alt ?? "") : reference.alt
            return block([textLine("[Figure: \(collapsed(alt))]")], .text)
        }
        if let image = markdownImage(in: text) {
            return block([textLine("[Figure: \(collapsed(image.alt))]"),
                          linkLine(url: image.url,
                                   label: image.alt.isEmpty ? nil : collapsed(image.alt))],
                         .text)
        }

        if let level = paragraph.effectiveHeading {
            // Heading 4 and deeper collapse to the deepest level gemtext
            // has, so a deep heading still reads as a heading.
            let hashes = String(repeating: "#", count: min(max(level, 1), 3))
            let words = literal
                ? paragraph.displayText
                : flattened(paragraph.displayText, citations: citations).words
            return block([hashes + " " + collapsed(words)], .heading)
        }

        var words = paragraph.displayText
        if let speaker = paragraph.speaker, !words.hasPrefix("\(speaker):") {
            words = "\(speaker): " + words
        }
        let trimmedWords = words.trimmingCharacters(in: .whitespacesAndNewlines)

        // A blockquote line, as the format writes it in a paragraph.
        if trimmedWords.hasPrefix("> ") || trimmedWords == ">" {
            // The marker and the one space that conventionally follows it
            // are the format's, not the words'.
            var quoted = String(trimmedWords.dropFirst())
            if quoted.hasPrefix(" ") { quoted.removeFirst() }
            return block(["> " + (literal ? quoted : collapsed(quoted))], .quote)
        }
        // An unordered list item at any depth: gemtext has one level, so
        // deeper items carry their depth inside the label.
        if let item = listItem(in: words) {
            if literal { return block(["* " + item.text], .list) }
            let flat = flattened(item.text, citations: citations)
            let marker = item.depth >= 2 ? "– " : ""
            return block(["* " + marker + collapsed(flat.words)] + unfolded(flat.links), .list)
        }

        if literal { return block([textLine(words, collapsing: false)], .text) }
        let flat = flattened(trimmedWords, citations: citations)
        return block([textLine(flat.words)] + unfolded(flat.links), .text)
    }

    // MARK: Line builders

    /// A plain text line, reserved prefixes made safe (§3.3). Words that
    /// came from gemtext are not collapsed: their spacing is the author's.
    private static func textLine(_ text: String, collapsing: Bool = true) -> String {
        let line = collapsing ? collapsed(text) : text
        for prefix in ["=>", ">", "```", "* "] where line.hasPrefix(prefix) {
            // One leading space is all it takes for the line to parse as
            // words; clients strip nothing else.
            return " " + line
        }
        // One to three hashes read as a heading, so they need the space.
        // Four or more are plain text in gemtext already — escaping them
        // would add a space the format never asked for.
        if line.hasPrefix("#"), line.prefix(while: { $0 == "#" }).count <= 3 {
            return " " + line
        }
        return line
    }

    private static func linkLine(url: String, label: String?) -> String {
        let words = (label?.trimmingCharacters(in: .whitespaces)).flatMap {
            $0.isEmpty ? nil : collapsed($0)
        }
        // URLs stay raw here — a Gemini client has to be able to open them.
        return words.map { "=> \(url) \($0)" } ?? "=> \(url)"
    }

    /// Links grouped under the paragraph that referenced them — the
    /// established gemtext idiom — in order of first appearance, one line
    /// each, deduplicated within the paragraph.
    private static func unfolded(_ links: [(url: String, label: String)]) -> [String] {
        var seen: Set<String> = []
        return links.compactMap { link in
            guard seen.insert(link.url).inserted else { return nil }
            return linkLine(url: link.url, label: link.label)
        }
    }

    private static func preBlock(alt: String, lines: [String]) -> [String] {
        // Nothing inside a fence is escaped — it is verbatim by
        // definition — but a body line must never open a fence by
        // accident, so an inner ``` is nudged out of the first column.
        let safe = lines.map { $0.hasPrefix("```") ? " " + $0 : $0 }
        return ["```" + alt] + safe + ["```"]
    }

    /// A table as space-padded columns: every column as wide as its widest
    /// cell, which is what makes a monospace rendering line up.
    private static func tableLines(_ table: LiquidDoc.Table) -> [String] {
        let rows = table.cells.map { $0.map { collapsed($0.value) } }
        guard let columns = rows.map(\.count).max(), columns > 0 else { return [] }
        var widths = [Int](repeating: 0, count: columns)
        for row in rows {
            for (index, cell) in row.enumerated() {
                widths[index] = max(widths[index], cell.count)
            }
        }
        return rows.map { row in
            (0..<columns).map { index -> String in
                let cell = index < row.count ? row[index] : ""
                return cell.padding(toLength: widths[index], withPad: " ", startingAt: 0)
            }.joined(separator: "  ").trimmingCharacters(in: .whitespaces)
        }
    }

    // MARK: Inline flattening

    /// Emphasis loses its markers, code its backticks, and every inline
    /// link its anchor — the label stays in the words, the URL comes back
    /// for its own `=>` line. Note markers become `[n]`, and a citation
    /// token becomes the words the reader would see, its work's URL
    /// unfolding with the paragraph's other links.
    static func flattened(_ text: String,
                          citations: [String: Citation] = [:])
        -> (words: String, links: [(url: String, label: String)]) {
        var words = text
        var links: [(url: String, label: String)] = []

        // Links first: their labels are words, their URLs are not.
        if let regex = try? NSRegularExpression(pattern: #"\[([^\]]*)\]\(([^)\s]+)\)"#) {
            var result = ""
            var cursor = words.startIndex
            let full = NSRange(words.startIndex..., in: words)
            for match in regex.matches(in: words, range: full) {
                guard let range = Range(match.range, in: words),
                      let labelRange = Range(match.range(at: 1), in: words),
                      let urlRange = Range(match.range(at: 2), in: words) else { continue }
                result += words[cursor..<range.lowerBound]
                let label = String(words[labelRange])
                let url = String(words[urlRange])
                result += label.isEmpty ? url : label
                links.append((url: url, label: label.isEmpty ? url : label))
                cursor = range.upperBound
            }
            result += words[cursor...]
            words = result
        }
        // Citation tokens: the words a reader sees stand in the text — the
        // author's own rendering where the source carried one, else a
        // short author-and-year form — and the cited work's URL unfolds
        // beneath the paragraph, where a Gemini client can open it. A
        // token whose record is missing leaves its label behind rather
        // than a raw token.
        words = replacing(#"\[cite:([^\]]+)\]"#, in: words) { key in
            guard let citation = citations[key] else { return "(\(key))" }
            if let url = citation.url { links.append((url: url, label: citation.label)) }
            return citation.label
        }
        // Note tokens: the mark stands in the words, the note itself is a
        // body paragraph the export carries like any other.
        for pattern in [#"\[note:([^\]]+)\]"#, #"\[inote:([^\]]+)\]"#] {
            words = replacing(pattern, in: words) { id in
                let digits = String(id.reversed().prefix { $0.isNumber }.reversed())
                return digits.isEmpty ? "[*]" : "[\(digits)]"
            }
        }
        // Emphasis markers, longest first so `**` never leaves a stray `*`.
        for marker in ["***", "**", "~~", "__", "*", "_", "`"] {
            words = unwrapping(marker, in: words)
        }
        return (collapsed(words), links)
    }

    /// Drops paired inline markers, keeping the words between them. A pair
    /// must hold something: an empty span is not emphasis, and a line of
    /// three backticks must stay three backticks so the reserved-prefix
    /// escape can still see a fence forming.
    private static func unwrapping(_ marker: String, in text: String) -> String {
        guard text.contains(marker) else { return text }
        let escaped = NSRegularExpression.escapedPattern(for: marker)
        let inner = marker == "`" ? #"([^`\n]+)"# : #"([^\n]+?)"#
        return replacing(escaped + inner + escaped, in: text) { $0 }
    }

    private static func replacing(_ pattern: String, in text: String,
                                  with transform: (String) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var result = ""
        var cursor = text.startIndex
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text),
                  let inner = Range(match.range(at: 1), in: text),
                  range.lowerBound >= cursor else { continue }
            result += text[cursor..<range.lowerBound]
            result += transform(String(text[inner]))
            cursor = range.upperBound
        }
        result += text[cursor...]
        return result
    }

    /// One long line per paragraph: newlines and runs of whitespace inside
    /// a block become single spaces, because the client does the wrapping.
    private static func collapsed(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: Block recognition

    /// A paragraph that is nothing but one anchor — how an imported `=>`
    /// line is held — and so goes back out as a link line.
    private static func linkOnlyAnchor(in text: String) -> (url: String, label: String?)? {
        guard let regex = try? NSRegularExpression(pattern: #"^\[([^\]]*)\]\(([^)\s]+)\)$"#),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let labelRange = Range(match.range(at: 1), in: text),
              let urlRange = Range(match.range(at: 2), in: text) else { return nil }
        let label = String(text[labelRange])
        let url = String(text[urlRange])
        return (url, label.isEmpty || label == url ? nil : label)
    }

    /// `![alt](https://…)` — an image the document names by URL rather
    /// than carrying as an asset.
    private static func markdownImage(in text: String) -> (alt: String, url: String)? {
        guard let regex = try? NSRegularExpression(pattern: #"^!\[(.*)\]\(([^)\s]+)\)$"#,
                                                   options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let altRange = Range(match.range(at: 1), in: text),
              let urlRange = Range(match.range(at: 2), in: text) else { return nil }
        let url = String(text[urlRange])
        guard !url.hasPrefix("asset:") else { return nil }
        return (String(text[altRange]), url)
    }

    /// A list item and its nesting depth — two spaces, or one tab, per
    /// level, as the importers write them.
    private static func listItem(in text: String) -> (depth: Int, text: String)? {
        let indent = text.prefix { $0 == " " || $0 == "\t" }
        let body = text.dropFirst(indent.count)
        guard body.hasPrefix("* ") || body.hasPrefix("- ") || body.hasPrefix("• ") else { return nil }
        let spaces = indent.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) }
        return (depth: spaces / 2 + 1, text: String(body.dropFirst(2)))
    }

    /// The language written on a fenced block's opening line.
    private static func fenceLanguage(in text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```"), let end = trimmed.firstIndex(of: "\n") else { return "" }
        return String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 3)..<end])
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: References

    /// A cited work as the export needs it: the words that stand where the
    /// body's token was, and an address a Gemini client can open.
    struct Citation: Sendable {
        let label: String
        let url: String?
    }

    /// Every work the body can cite, under both the id the document
    /// carries it by and the BibTeX key its `[cite:…]` tokens use.
    private static func citationIndex(for doc: LiquidDoc) -> [String: Citation] {
        var index: [String: Citation] = [:]
        func add(id: String, bibtex: String, citedAs: String?) {
            let words = citedAs?.trimmingCharacters(in: .whitespaces)
            guard let entry = BibTeXParser.first(bibtex) else {
                index[id] = Citation(label: words?.isEmpty == false ? words! : "(\(id))",
                                     url: nil)
                return
            }
            // The author's own rendering, where the source carried one —
            // "(Nelson 1965)" as it was written — else the short form.
            let label = words?.isEmpty == false ? words! : shortCitation(entry)
            let citation = Citation(label: label, url: referenceURL(entry))
            index[id] = citation
            if !entry.key.isEmpty, index[entry.key] == nil { index[entry.key] = citation }
        }
        for reference in doc.references {
            add(id: reference.id, bibtex: reference.bibtex, citedAs: reference.citedAs)
        }
        for link in doc.links {
            guard let bibtex = link.bibtex, index[link.to] == nil else { continue }
            add(id: link.to, bibtex: bibtex, citedAs: nil)
        }
        return index
    }

    /// "(Nelson et al. 1965)" — the marker a paragraph carries inline when
    /// the source recorded no rendering of its own.
    private static func shortCitation(_ entry: BibTeXEntry) -> String {
        var parts: [String] = []
        if let author = entry.firstAuthor {
            parts.append(entry.hasMultipleAuthors ? "\(author) et al." : author)
        }
        if let year = entry.year { parts.append(year) }
        guard !parts.isEmpty else { return "(\(entry.title ?? entry.key))" }
        return "(" + parts.joined(separator: " ") + ")"
    }

    /// The entry's address as a URL, with the plain-BibTeX escaping undone:
    /// a DOI field in a Visual-Meta context carries `10.1145/123\_456`, and
    /// a link line must carry the address a client can actually open. The
    /// appendix keeps its escapes; only the body's URLs are unescaped.
    private static func referenceURL(_ entry: BibTeXEntry) -> String? {
        guard let raw = entry.externalURL?.trimmingCharacters(in: .whitespaces),
              !raw.isEmpty else { return nil }
        var url = raw.replacingOccurrences(of: "\\textbackslash{}", with: "\\")
        for special in ["&", "%", "$", "#", "_", "{", "}", "~", "^"] {
            url = url.replacingOccurrences(of: "\\" + special, with: special)
        }
        return url
    }

    /// `## References`: one `=>` line per entry that has a resolvable URL —
    /// DOI first, since a Gemini client can actually open it — and a `* `
    /// item for an entry that has none.
    private static func referenceBlocks(for doc: LiquidDoc) -> [Block] {
        var records: [(bibtex: String, key: String)] = []
        var seen: Set<String> = []
        for link in doc.links {
            guard let bibtex = link.bibtex?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !bibtex.isEmpty, seen.insert(link.to).inserted else { continue }
            records.append((bibtex, link.to))
        }
        for reference in doc.references {
            let bibtex = reference.bibtex.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !bibtex.isEmpty, seen.insert(reference.id).inserted else { continue }
            records.append((bibtex, reference.id))
        }
        guard !records.isEmpty else { return [] }

        var blocks = [Block(lines: ["## References"], kind: .heading)]
        for record in records {
            guard let entry = BibTeXParser.first(record.bibtex) else {
                blocks.append(Block(lines: ["* " + collapsed(record.key)], kind: .list))
                continue
            }
            let label = referenceLabel(entry)
            // A DOI first: a Gemini client can open it, and it is the
            // entry's most durable address.
            if let url = referenceURL(entry) {
                blocks.append(Block(lines: [linkLine(url: url, label: label)], kind: .link))
            } else {
                blocks.append(Block(lines: ["* " + collapsed(label)], kind: .list))
            }
        }
        return blocks
    }

    /// The human-readable reference, as the reader prints it: author,
    /// year, title.
    private static func referenceLabel(_ entry: BibTeXEntry) -> String {
        var parts: [String] = []
        if let author = entry.firstAuthor {
            parts.append(entry.hasMultipleAuthors ? "\(author) et al." : author)
        }
        if let year = entry.year { parts.append(year) }
        if let title = entry.title { parts.append(title) }
        // "Hegland et al." already ends in a stop; a second one reads as a
        // typo in a reference list.
        let label = parts.reduce("") { joined, part in
            guard !joined.isEmpty else { return part }
            return joined + (joined.hasSuffix(".") ? " " : ". ") + part
        }
        return label.isEmpty ? entry.key : collapsed(label)
    }

    // MARK: Visual-Meta appendix

    /// The final block of every export: the standard Visual-Meta payload
    /// from the app's one generator, inside a preformatted fence named
    /// `visual-meta`. Verbatim inside the fence, so no gemtext escaping
    /// applies — and visible monospaced text in any Gemini client, which
    /// is the point.
    private static func visualMetaBlock(for doc: LiquidDoc,
                                        identity: AuthorIdentity?) -> [String] {
        let payload = VisualMeta.metaBlock(for: doc, identity: identity)
        return preBlock(alt: "visual-meta", lines: payload.components(separatedBy: "\n"))
    }
}
