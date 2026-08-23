import CryptoKit
import Foundation
import SwiftUI

// Ported from Knowledge Space's OrigamiReading.swift (itself from
// Augmented Library) — the Origami reading mode's UI-free
// underpinnings: the view styles a document can be read in, the
// context-menu actions a reader can invoke, the section structure
// derived from a body's headings, and the citation a paragraph travels
// as when copied. All value types, every piece testable without a
// window. Origami Text adaptations: no excerptOf (this library keeps
// whole books), and BibTeX records bridge through this app's own
// BibTeXParser. Keep the shared parts synced; a fix here should be
// carried back.

/// A BibTeX entry parsed just enough to read it — entry type, key, and
/// the display fields; the verbatim text remains the record. Bridged
/// from this app's BibTeXParser so both speak the same grammar.
nonisolated struct BibTeXRecord: Sendable {
    let raw: String
    let entryType: String
    let key: String
    let fields: [String: String]

    var author: String { fields["author"] ?? fields["editor"] ?? "" }
    var title: String { fields["title"] ?? "" }
    var year: String { fields["year"] ?? "" }

    /// True for the book-shaped entry types.
    var isBook: Bool { entryType.localizedCaseInsensitiveContains("book") }

    /// The Books shelf's rule: a book as the record says, or a work
    /// with an ISBN and no DOI.
    var shelvesAsBook: Bool {
        if isBook { return true }
        return fields["isbn"] != nil && fields["doi"] == nil
    }

    /// Authors as "First Last, First Last" for display; BibTeX's
    /// "Last, First" and "First Last" forms both read correctly.
    var displayAuthors: String {
        author.components(separatedBy: " and ")
            .map { name -> String in
                let parts = name.components(separatedBy: ",")
                guard parts.count == 2 else {
                    return name.trimmingCharacters(in: .whitespaces)
                }
                let last = parts[0].trimmingCharacters(in: .whitespaces)
                let first = parts[1].trimmingCharacters(in: .whitespaces)
                return first.isEmpty ? last : "\(first) \(last)"
            }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    /// The record's own way out to the work on the web: its DOI, else
    /// its URL field.
    var webURL: URL? {
        if let doi = fields["doi"], !doi.isEmpty {
            return URL(string: doi.hasPrefix("http") ? doi : "https://doi.org/\(doi)")
        }
        return fields["url"].flatMap(URL.init(string:))
    }

    /// The citation sentence for this record (without an address).
    var citationSentence: String {
        var sentence = "\u{201C}\(title.isEmpty ? "Untitled" : title)\u{201D}"
        let credit = [displayAuthors, year].filter { !$0.isEmpty }.joined(separator: ", ")
        if !credit.isEmpty { sentence += " (\(credit))" }
        return sentence
    }

    /// Every entry found in a text — tolerant: what does not parse is
    /// skipped.
    static func records(in text: String) -> [BibTeXRecord] {
        BibTeXParser.parse(text.trimmingCharacters(in: .whitespacesAndNewlines)).map {
            BibTeXRecord(raw: $0.raw, entryType: $0.type, key: $0.key, fields: $0.fields)
        }
    }
}

/// How the document is laid out for reading. The raw values are the
/// persisted form (`@AppStorage`), shared across platforms so a style
/// chosen on the Mac greets the reader on the Vision Pro.
nonisolated enum OrigamiReadingStyle: String, CaseIterable, Identifiable, Sendable {
    /// The classic flow: headings and paragraphs in order, one measure.
    case article
    /// The document by its structure: sections fold and unfold under
    /// their headings — read the skeleton first, open what matters.
    case outline
    /// One section at a time, large measure, nothing else on screen —
    /// previous/next moves through the document.
    case focus
    /// Speaker-labelled turns for meetings and interviews; documents
    /// without speakers read as the article flow.
    case transcript

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .article: "Article"
        case .outline: "Outline"
        case .focus: "Focus"
        case .transcript: "Transcript"
        }
    }

    var systemImage: String {
        switch self {
        case .article: "doc.text"
        case .outline: "list.bullet.indent"
        case .focus: "rectangle.center.inset.filled"
        case .transcript: "person.2.wave.2"
        }
    }

    /// One line for pickers and settings, saying what the style is for.
    var blurb: String {
        switch self {
        case .article: "The document as written, in one flow."
        case .outline: "Sections fold under their headings."
        case .focus: "One section at a time, nothing else."
        case .transcript: "Turns grouped by who is speaking."
        }
    }
}

/// Everything the reading context menu can offer. Which of these appear —
/// and in what order — is the reader's own choice, persisted through
/// `encodeList`/`decodeList` so both platforms honour the same setting.
nonisolated enum OrigamiContextAction: String, CaseIterable, Identifiable, Sendable {
    /// The paragraph's words onto the clipboard, plain.
    case copyText
    /// The paragraph as a quotation: the words, then the document's
    /// citation sentence and address — paste-ready provenance.
    case copyCitation
    /// The view itself as a citation: the paragraph's address plus
    /// every variable needed to re-create the view, as a viewspec
    /// JSON document any app can read.
    case copyViewSpec
    /// A W3C highlight on the paragraph, kept in the reader's sidecar,
    /// never in the document.
    case highlight
    /// A comment anchored to the paragraph, same store.
    case comment
    /// The document's own concept definitions that this paragraph
    /// mentions — the glossary the author shipped inside the document.
    case concepts
    /// The document's reference list, resolved and readable.
    case references
    /// Where this paragraph came from (the transcription's page, the
    /// speaker's turn) when the document says.
    case provenance

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .copyText: "Copy Text"
        case .copyCitation: "Copy as Citation"
        case .copyViewSpec: "Copy View Specification"
        case .highlight: "Highlight"
        case .comment: "Comment…"
        case .concepts: "Concepts Here"
        case .references: "Show References"
        case .provenance: "Provenance"
        }
    }

    var systemImage: String {
        switch self {
        case .copyText: "doc.on.doc"
        case .copyCitation: "quote.opening"
        case .copyViewSpec: "viewfinder.rectangular"
        case .highlight: "highlighter"
        case .comment: "text.bubble"
        case .concepts: "lightbulb"
        case .references: "list.bullet.rectangle"
        case .provenance: "signature"
        }
    }

    /// One line for the settings pane.
    var blurb: String {
        switch self {
        case .copyText: "The paragraph's words, plain."
        case .copyCitation: "The words plus the document's citation and address."
        case .copyViewSpec: "The address plus every view variable, as a viewspec any app can restore."
        case .highlight: "Mark the paragraph; kept in your library, not the document."
        case .comment: "Attach a note to the paragraph."
        case .concepts: "Definitions the document carries for terms in this paragraph."
        case .references: "The document's reference list."
        case .provenance: "Where the paragraph came from, when the document says."
        }
    }

    /// What a fresh install shows.
    static let defaultActions: [OrigamiContextAction] =
        [.copyText, .copyCitation, .copyViewSpec, .highlight, .comment, .concepts, .references]

    /// The persisted form: raw values, comma-joined, order kept.
    static func encodeList(_ actions: [OrigamiContextAction]) -> String {
        actions.map(\.rawValue).joined(separator: ",")
    }

    /// The stored string back into actions — unknown tokens (an older or
    /// newer app's actions) are dropped, order and duplicates-first kept.
    static func decodeList(_ stored: String?) -> [OrigamiContextAction] {
        guard let stored else { return defaultActions }
        var seen: Set<OrigamiContextAction> = []
        return stored.split(separator: ",")
            .compactMap { OrigamiContextAction(rawValue: String($0)) }
            .filter { seen.insert($0).inserted }
    }
}

/// How open stretchtext reads: set apart as a callout behind a quiet
/// rule, or inline as ordinary paragraphs in the flow. The raw value
/// is the persisted form (`@AppStorage` under "stretchtextDisplay"),
/// shared across platforms.
nonisolated enum StretchtextDisplay: String, CaseIterable, Identifiable, Sendable {
    case callout
    case inline

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .callout: "Callout"
        case .inline: "Inline"
        }
    }

    /// One line for the settings pane.
    var blurb: String {
        switch self {
        case .callout: "Opened stretchtext reads set apart, inset behind a quiet rule."
        case .inline: "Opened stretchtext reads as ordinary paragraphs in the flow."
        }
    }
}

/// How Author's ==Marked== text shows — its six styles carried across,
/// colour for colour, the raw values Author's own popup tags. Stored
/// under "markedTextStyle", shared across platforms.
nonisolated enum MarkedTextStyle: Int, CaseIterable, Identifiable, Sendable {
    case orange = 0
    case boldOrange = 1
    case boldHighContrast = 2
    case highContrast = 3
    case blue = 4
    case boldBlue = 5

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .orange: "Orange"
        case .boldOrange: "Bold Orange"
        case .boldHighContrast: "Bold High Contrast"
        case .highContrast: "High Contrast"
        case .blue: "Blue"
        case .boldBlue: "Bold Blue"
        }
    }

    /// Author bolds styles 1, 2, and 5.
    var isBold: Bool {
        switch self {
        case .boldOrange, .boldHighContrast, .boldBlue: true
        case .orange, .highContrast, .blue: false
        }
    }

    /// The mark's ink, from Author's assets, per appearance.
    func color(for scheme: ColorScheme) -> Color {
        switch self {
        case .orange, .boldOrange:
            return scheme == .dark
                ? Color(red: 1, green: 187 / 255, blue: 95 / 255)
                : OrigamiReading.markColor
        case .highContrast, .boldHighContrast:
            return scheme == .dark
                ? Color(white: 236 / 255)
                : OrigamiReading.markColor
        case .blue, .boldBlue:
            return Color(red: 54 / 255, green: 120 / 255, blue: 176 / 255)
        }
    }
}

/// How the document's glossary shows on its terms in the body: not at
/// all, the definition in brackets after the term, or a dagger the
/// reader opens and closes. The raw value is the persisted form
/// (`@AppStorage` under "glossaryDisplay"), shared across platforms.
nonisolated enum GlossaryDisplay: String, CaseIterable, Identifiable, Sendable {
    /// Terms read as plain text; definitions stay in the context menu.
    case hidden
    /// The definition follows its term in brackets, always visible.
    case bracketed
    /// A `]` follows the term; clicking it opens the definition inline
    /// in brackets, and a click in the brackets closes it.
    case icon
    /// Terms hide until the Tab key: the text greys, every term shows
    /// Marked (Author's orange); a click opens its definition in
    /// brackets, Tab again returns to normal reading.
    case tab

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .hidden: "Hidden"
        case .bracketed: "Bracketed"
        case .icon: "Icon"
        case .tab: "TAB"
        }
    }

    /// One line for the settings pane.
    var blurb: String {
        switch self {
        case .hidden: "Glossary terms read as plain text; definitions stay in the context menu."
        case .bracketed: "Each term's definition follows it in brackets."
        case .icon: "A ] follows each term; click it to open the definition inline, click the brackets to close."
        case .tab: "Press Tab while reading: the text greys and every term shows Marked; click a term for its definition, Tab again to return."
        }
    }
}

/// How citations read in the body: the author–date parenthesis, the
/// numbered bracket, or the number raised superscript — only the
/// displayed text changes; the citation's click, and the source it
/// reveals, are the same in every style. Stored under
/// "origamiCitationStyle", shared across platforms.
nonisolated enum OrigamiCitationStyle: String, CaseIterable, Identifiable, Sendable {
    /// (Hegland 2025) — who and when, inline, as the author wrote it.
    case authorDate
    /// [3] — the entry's number in the source's reference list.
    case numeric
    /// ³ — the same number, raised and small.
    case superscript

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .authorDate: "(Author Date)"
        case .numeric: "[Number]"
        case .superscript: "Superscript"
        }
    }

    /// One line for the settings pane.
    var blurb: String {
        switch self {
        case .authorDate: "Citations read as (Hegland 2025) — who and when, inline, as the author wrote them."
        case .numeric: "Citations read as [3] — the entry's number in the source's reference list."
        case .superscript: "Citations read as ³ — the entry's number, raised and small."
        }
    }
}

/// The document sliced by its headings: each section is a heading (or the
/// untitled opening) and the paragraphs under it, in order. The outline
/// and focus styles read this; building it is pure.
nonisolated struct OrigamiSection: Identifiable, Hashable, Sendable {
    /// The heading paragraph, nil for the opening run before any heading.
    let heading: LiquidDoc.Paragraph?
    let paragraphs: [LiquidDoc.Paragraph]

    var id: String { heading?.id ?? paragraphs.first?.id ?? "empty" }

    /// The section's name as a table of contents shows it.
    var title: String { heading?.text ?? "Opening" }

    var level: Int { heading?.heading ?? 1 }

    /// The body split at every heading. Content before the first heading
    /// becomes an untitled opening section; an empty body yields nothing.
    static func build(from doc: LiquidDoc) -> [OrigamiSection] {
        guard let body = doc.body, !body.isEmpty else { return [] }
        var sections: [OrigamiSection] = []
        var heading: LiquidDoc.Paragraph?
        var run: [LiquidDoc.Paragraph] = []
        func flush() {
            guard heading != nil || !run.isEmpty else { return }
            sections.append(OrigamiSection(heading: heading, paragraphs: run))
        }
        for paragraph in body {
            if paragraph.heading != nil {
                flush()
                heading = paragraph
                run = []
            } else {
                run.append(paragraph)
            }
        }
        flush()
        return sections
    }
}

/// Everything the reader has done to shape the view of a document: the
/// style it is read in, the outline sections folded closed, the
/// stretchtext blocks opened, the focused section. A citation copied
/// while any of this is in effect carries it — one readable line and a
/// restorable address fragment.
nonisolated struct OrigamiViewState: Equatable, Sendable {
    var style: OrigamiReadingStyle
    /// The heading ids of sections folded closed (the outline style).
    var closedSections: [String]
    /// The stretch block ids opened (closed is stretchtext's default).
    var openStretch: [String]
    /// The heading id of the section in view (the focus style).
    var focusSectionID: String?

    init(style: OrigamiReadingStyle,
         closedSections: [String] = [],
         openStretch: [String] = [],
         focusSectionID: String? = nil) {
        self.style = style
        self.closedSections = closedSections
        self.openStretch = openStretch
        self.focusSectionID = focusSectionID
    }

    /// The plain article with nothing applied — a citation from it
    /// carries no view note.
    var isDefault: Bool {
        style == .article && closedSections.isEmpty && openStretch.isEmpty
    }

    /// The state as queries after the address's paragraph fragment:
    /// `?view=outline&closed=a,b&open=c&focus=d`. Empty when default.
    var fragmentSuffix: String {
        guard !isDefault else { return "" }
        var parts = ["view=" + style.rawValue]
        if !closedSections.isEmpty {
            parts.append("closed=" + closedSections.map(Self.escape).joined(separator: ","))
        }
        if !openStretch.isEmpty {
            parts.append("open=" + openStretch.map(Self.escape).joined(separator: ","))
        }
        if let focusSectionID {
            parts.append("focus=" + Self.escape(focusSectionID))
        }
        return "?" + parts.joined(separator: "&")
    }

    /// The suffix back into a state — how a reader following the
    /// citation restores the view. Nil when no view query is present.
    static func parse(fragmentSuffix: String) -> OrigamiViewState? {
        guard let question = fragmentSuffix.firstIndex(of: "?") else { return nil }
        var values: [String: String] = [:]
        for pair in fragmentSuffix[fragmentSuffix.index(after: question)...]
            .split(separator: "&") {
            let sides = pair.split(separator: "=", maxSplits: 1)
            guard sides.count == 2 else { continue }
            values[String(sides[0])] = String(sides[1])
        }
        guard let style = values["view"].flatMap(OrigamiReadingStyle.init) else { return nil }
        func list(_ name: String) -> [String] {
            (values[name] ?? "").split(separator: ",")
                .compactMap { String($0).removingPercentEncoding }
        }
        return OrigamiViewState(style: style,
                                closedSections: list("closed"),
                                openStretch: list("open"),
                                focusSectionID: values["focus"]?.removingPercentEncoding)
    }

    /// One line for the quotation block: "Viewed as Outline — “Method”
    /// folded closed; 1 stretchtext open". Nil when default.
    func readableLine(in doc: LiquidDoc) -> String? {
        guard !isDefault else { return nil }
        func title(_ headingID: String) -> String {
            doc.body?.first { $0.id == headingID }.map { "\u{201C}\($0.text)\u{201D}" } ?? headingID
        }
        var clauses: [String] = []
        if style == .focus, let focusSectionID {
            clauses.append("Viewed in Focus on \(title(focusSectionID))")
        } else {
            clauses.append("Viewed as \(style.displayName)")
        }
        if !closedSections.isEmpty {
            clauses.append(closedSections.map(title).joined(separator: ", ") + " folded closed")
        }
        if !openStretch.isEmpty {
            clauses.append("\(openStretch.count) stretchtext\(openStretch.count == 1 ? "" : "s") open")
        }
        return clauses.joined(separator: "; ")
    }

    private static func escape(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"))
            ?? id
    }
}

/// The body flow as the reader walks it: plain paragraphs interleaved
/// with stretch blocks — consecutive paragraphs sharing a `stretchID`,
/// folded together behind one `›` toggle.
nonisolated enum OrigamiFlowItem: Identifiable, Hashable, Sendable {
    case paragraph(LiquidDoc.Paragraph)
    case stretch(id: String, paragraphs: [LiquidDoc.Paragraph])

    var id: String {
        switch self {
        case .paragraph(let paragraph): paragraph.id
        case .stretch(let id, _): "stretch:" + id
        }
    }

    /// A paragraph run grouped into flow items.
    static func build(_ paragraphs: [LiquidDoc.Paragraph]) -> [OrigamiFlowItem] {
        var items: [OrigamiFlowItem] = []
        for paragraph in paragraphs {
            if let stretchID = paragraph.stretchID {
                if case .stretch(let lastID, let run) = items.last, lastID == stretchID {
                    items[items.count - 1] = .stretch(id: stretchID,
                                                      paragraphs: run + [paragraph])
                } else {
                    items.append(.stretch(id: stretchID, paragraphs: [paragraph]))
                }
            } else {
                items.append(.paragraph(paragraph))
            }
        }
        return items
    }
}

/// How a paragraph travels when copied as a citation, and which of the
/// document's concepts a paragraph touches.
nonisolated enum OrigamiReading {

    /// The quotation block: the words, the document's citation sentence,
    /// and its address — everything a paste needs to stay traceable.
    /// When the reader has shaped the view (a style, folded sections,
    /// opened stretchtext), the block also carries it: one readable
    /// line, and the state on the address fragment so a reader
    /// following the citation can restore the view exactly.
    /// `quote` narrows the quoted words to the reader's selection;
    /// nil quotes the paragraph whole.
    static func citation(for paragraph: LiquidDoc.Paragraph,
                         in doc: LiquidDoc,
                         view state: OrigamiViewState? = nil,
                         quote: String? = nil) -> String {
        var line = "\u{201C}\(doc.title.isEmpty ? "Untitled" : doc.title)\u{201D}"
        let credit = [doc.displayAuthor, doc.listedDateText]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        if !credit.isEmpty { line += " (\(credit))" }
        let address = doc.id + "#" + paragraph.id
        var block = (quote ?? paragraph.text) + "\n\u{2014} " + line
        if let viewLine = state?.readableLine(in: doc) {
            block += "\n" + viewLine
        }
        return block + "\n" + address + (state?.fragmentSuffix ?? "")
    }

    /// Author's citation payload for a paragraph: the quoted words
    /// plain, and a full BibTeX entry for the cited work whose `vm-id`
    /// carries the document's address with the paragraph fragment, so
    /// a citation exported onward (Author's EPUB) still opens the
    /// original at the right place.
    static func authorCitationPayload(for paragraph: LiquidDoc.Paragraph,
                                      in doc: LiquidDoc,
                                      quote quoted: String? = nil)
        -> (content: String, bibtex: String) {
        let address = doc.id + "#" + paragraph.id
        let quote = plainQuote(quoted ?? paragraph.text, in: doc)

        var fields: [(String, String)] = []
        if !doc.author.isEmpty { fields.append(("author", doc.author)) }
        fields.append(("title", doc.title))
        if let year = doc.date?.isoString.prefix(4), year.count == 4 {
            fields.append(("year", String(year)))
        }
        if !quote.isEmpty { fields.append(("quote", quote)) }
        fields.append(("vm-id", address))

        let key = "ot" + String(stableHash(of: address).prefix(10))
        var bibtex = "@misc{\(key),\n"
        for (name, value) in fields {
            bibtex += " \(name) = {\(bibValue(value))},\n"
        }
        bibtex += "}"
        return (content: quote, bibtex: bibtex)
    }

    /// A paragraph's words with the reading conventions resolved away —
    /// citations in author–date words, note daggers and mark/emphasis
    /// syntax gone — fit for a quotation field.
    static func plainQuote(_ text: String, in doc: LiquidDoc) -> String {
        var out = citationsResolved(text, in: doc, style: .authorDate)
        if let regex = try? NSRegularExpression(pattern: #"\[i?note:[^\]]+\]"#) {
            let ns = out as NSString
            out = regex.stringByReplacingMatches(
                in: out, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        }
        for marker in ["==", "**", "*", "`"] {
            out = out.replacingOccurrences(of: marker, with: "")
        }
        return out.replacingOccurrences(of: #"\s+"#, with: " ",
                                        options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A value safe inside one BibTeX brace pair — braces and newlines
    /// would break the receiving parsers.
    private static func bibValue(_ value: String) -> String {
        value.replacingOccurrences(of: "{", with: "(")
            .replacingOccurrences(of: "}", with: ")")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    /// The document's concepts whose names appear in the paragraph —
    /// whole-word, case-insensitive — in the order the document lists them.
    static func concepts(in paragraph: LiquidDoc.Paragraph,
                         of doc: LiquidDoc) -> [LiquidDoc.Concept] {
        guard !doc.concepts.isEmpty else { return [] }
        let words = Set(normalize(paragraph.text)
            .split(separator: " ").map(String.init))
        return doc.concepts.filter { concept in
            let name = normalize(concept.name)
                .split(separator: " ").map(String.init)
            return !name.isEmpty && name.allSatisfy { words.contains($0) }
        }
    }

    /// Case- and diacritic-folded words, punctuation dropped — the
    /// concept matcher's common ground.
    static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                  locale: Locale(identifier: "en_US_POSIX"))
        let kept = folded.map { $0.isLetter || $0.isNumber ? $0 : " " }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    /// A SHA-256 of a string, as lowercase hex — a stable identity for
    /// derived documents.
    static func stableHash(of string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Author's marked-text orange (#BB6A26), the colour marked spans
    /// paint in when a document reads back.
    static let markColor = Color(red: 0xBB / 255, green: 0x6A / 255, blue: 0x26 / 255)

    /// A paragraph's text with the format's inline conventions rendered:
    /// markdown (`**bold**`, `*italic*`, backticks, links) through the
    /// system parser, and the `==marked==` convention — Author's Mark —
    /// painted in the chosen style with the markers stripped.
    static func inlineAttributed(_ text: String,
                                 markStyle: MarkedTextStyle = .orange,
                                 appearance: ColorScheme = .light) -> AttributedString {
        func parsed(_ part: String) -> AttributedString {
            (try? AttributedString(
                markdown: part,
                options: AttributedString.MarkdownParsingOptions(
                    interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                ?? AttributedString(part)
        }
        let parts = text.components(separatedBy: "==")
        // Marks come in pairs; anything else is literal text.
        guard parts.count >= 3, parts.count % 2 == 1 else { return parsed(text) }
        var out = AttributedString()
        for (index, part) in parts.enumerated() {
            var piece = parsed(part)
            if index % 2 == 1 {
                piece.foregroundColor = markStyle.color(for: appearance)
                if markStyle.isBold {
                    let ranges = piece.runs.map { ($0.range, $0.inlinePresentationIntent) }
                    for (range, intent) in ranges {
                        piece[range].inlinePresentationIntent =
                            (intent ?? []).union(.stronglyEmphasized)
                    }
                }
            }
            out += piece
        }
        return out
    }

    /// A paragraph's text rendered for a document: its `[cite:key]`
    /// tokens resolved to the reader's chosen citation form first — each
    /// a link carrying the `origami-cite:` scheme, so a tap can show the
    /// source's card — its `[note:id]` endnote tokens as clickable
    /// daggers, then the inline conventions as `inlineAttributed(_:)`
    /// renders them.
    static func inlineAttributed(_ text: String, in doc: LiquidDoc,
                                 citations style: OrigamiCitationStyle,
                                 markStyle: MarkedTextStyle = .orange,
                                 appearance: ColorScheme = .light) -> AttributedString {
        inlineAttributed(noteTokensResolved(
            citationsResolved(text, in: doc, style: style, linked: true)),
            markStyle: markStyle, appearance: appearance)
    }

    /// The URL scheme the stretchtext toggles carry: the closed `»`,
    /// the open frame's `‹` and `›`, and the revealed words themselves —
    /// a click on any of them folds the stretch.
    static let stretchScheme = "origami-stretch"

    /// Revealed stretchtext made clickable-to-close: every run that is
    /// not already a link gains the stretch's own link, and `closing`
    /// appends the frame's `›`. The caller sets the opening `‹`.
    static func stretchRevealed(_ attributed: AttributedString,
                                id: String, closing: Bool) -> AttributedString {
        var out = attributed
        guard let url = URL(string: stretchScheme + ":" + id) else { return out }
        let plainRanges = out.runs.compactMap { $0.link == nil ? $0.range : nil }
        for range in plainRanges { out[range].link = url }
        if closing {
            var mark = AttributedString(" \u{203A}")   // ›
            mark.link = url
            out += mark
        }
        return out
    }

    /// The URL scheme an endnote's dagger carries; the readers catch it
    /// and show the note in a pop-up, its links live.
    static let noteScheme = "origami-note"

    /// The endnote id a dagger points at — nil for other URLs.
    static func noteID(from url: URL) -> String? {
        guard url.scheme == noteScheme else { return nil }
        let raw = String(url.absoluteString.dropFirst(noteScheme.count + 1))
        return raw.removingPercentEncoding ?? raw
    }

    /// The endnote a dagger reveals: the body paragraph carrying the
    /// note's id (the import files endnotes under a Notes heading). A
    /// chaptered book's import prefixes ids per chapter (s2-en-1) while
    /// the dagger's href carries the document's own (en-1) — the suffix
    /// match bridges the two.
    static func endnote(withID id: String, in doc: LiquidDoc) -> LiquidDoc.Paragraph? {
        doc.body?.first { $0.id == id }
            ?? doc.body?.first { $0.id.hasSuffix("-" + id) }
    }

    /// `[note:id]` tokens as markdown daggers on the note scheme.
    static func noteTokensResolved(_ text: String) -> String {
        guard text.contains("[note:") else { return text }
        guard let regex = try? NSRegularExpression(pattern: #"\[note:([^\]]+)\]"#) else {
            return text
        }
        var out = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: out.length))
        for match in matches.reversed() {
            let id = out.substring(with: match.range(at: 1))
            let escaped = id.addingPercentEncoding(withAllowedCharacters: keyAllowed) ?? id
            out = out.replacingCharacters(in: match.range,
                                          with: "[\u{2020}](\(noteScheme):\(escaped))") as NSString
        }
        return out as String
    }

    /// The URL scheme an inline note's fold carries: closed, the []
    /// standing at the note's mark; open, the bracketed words
    /// themselves — a click on any of them folds the note back.
    static let inlineNoteScheme = "origami-inote"

    /// The inline note id a fold points at — nil for other URLs.
    static func inlineNoteID(from url: URL) -> String? {
        guard url.scheme == inlineNoteScheme else { return nil }
        let raw = String(url.absoluteString.dropFirst(inlineNoteScheme.count + 1))
        return raw.removingPercentEncoding ?? raw
    }

    /// `[inote:id]` tokens — inline notes travelling as stretchtext —
    /// resolved on the rendered text. Closed, the token stands as []
    /// on the fold's own scheme; open, the note's words continue the
    /// sentence in place, [ opening them and ] closing them, every
    /// part a click to fold. The words come from the note filed with
    /// the endnotes under the token's id.
    static func inlineNotesResolved(_ attributed: AttributedString,
                                    in doc: LiquidDoc,
                                    open: Set<String>,
                                    citations style: OrigamiCitationStyle,
                                    markStyle: MarkedTextStyle = .orange,
                                    appearance: ColorScheme = .light) -> AttributedString {
        var out = attributed
        // Each pass resolves the first remaining token; the cap is a
        // guard against a note whose own words carry a token.
        for _ in 0..<64 {
            let plain = String(out.characters)
            guard let match = plain.range(of: #"\[inote:[^\]]+\]"#,
                                          options: .regularExpression),
                  let attributedRange = Range(match, in: out) else { break }
            let id = String(plain[match].dropFirst("[inote:".count).dropLast())
            let escaped = id.addingPercentEncoding(withAllowedCharacters: keyAllowed) ?? id
            guard let url = URL(string: inlineNoteScheme + ":" + escaped) else { break }
            var replacement = AttributedString()
            if open.contains(id), let note = endnote(withID: id, in: doc) {
                var opening = AttributedString("[")
                opening.link = url
                replacement += opening
                var words = inlineAttributed(note.text, in: doc, citations: style,
                                             markStyle: markStyle, appearance: appearance)
                // The words fold the note like the brackets do — except
                // where they already link somewhere of their own.
                let plainRuns = words.runs.compactMap { $0.link == nil ? $0.range : nil }
                for range in plainRuns { words[range].link = url }
                replacement += words
                var closing = AttributedString("]")
                closing.link = url
                replacement += closing
            } else {
                var mark = AttributedString("[]")
                mark.link = url
                replacement = mark
            }
            out.replaceSubrange(attributedRange, with: replacement)
        }
        return out
    }

    /// The URL scheme a rendered citation link carries. The readers
    /// catch it in an `OpenURLAction` and show the source's card.
    static let citationScheme = "origami-cite"

    /// The reference key a citation link points at, percent-decoded —
    /// nil for any other URL, which should open normally.
    static func citationKey(from url: URL) -> String? {
        guard url.scheme == citationScheme else { return nil }
        let raw = String(url.absoluteString.dropFirst(citationScheme.count + 1))
        return raw.removingPercentEncoding ?? raw
    }

    /// The characters a reference key may carry into its link unescaped.
    private static let keyAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// The text with its citation tokens — `[cite:key]`, the key naming
    /// an entry in the document's reference pool — resolved to the
    /// chosen form: the citation as its author wrote it ("(Hegland
    /// 2025)"), or its number in the source's reference list, bracketed
    /// or superscript. With `linked`, each becomes a markdown link on
    /// the `origami-cite:` scheme. The raw token is never shown: a key
    /// the pool does not know reads as the bracketed key, still legible
    /// and still honest about the gap.
    static func citationsResolved(_ text: String, in doc: LiquidDoc,
                                  style: OrigamiCitationStyle,
                                  linked: Bool = false) -> String {
        guard text.contains("[cite:") else { return text }
        guard let regex = try? NSRegularExpression(pattern: #"\[cite:([^\]]+)\]"#) else {
            return text
        }
        var out = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: out.length))
        for match in matches.reversed() {
            let key = out.substring(with: match.range(at: 1))
            let index = doc.references.firstIndex(where: { $0.id == key })
            let reference = index.map { doc.references[$0] }
            // The display text the author wrote, carried on the record
            // by the EPUB import.
            let citedAs = (reference?.citedAs).flatMap { text -> String? in
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            // The file's own number first (it agrees with the source's
            // visible reference list where one travels); the pool's
            // position stands in when the file carries none, so the
            // numbered styles always have a number to show.
            let number = reference?.number ?? index.map { $0 + 1 }
            // As written only when what was written reads as an inline
            // citation — a pasted passage or a long title is a record,
            // not a label.
            let inline = citedAs.flatMap { $0.count <= 80 ? $0 : nil }
            let record = reference.flatMap { BibTeXRecord.records(in: $0.bibtex).first }
            var label: String
            switch style {
            case .authorDate:
                // As written first — read, never re-derived; the
                // BibTeX author–date next; the work's title, clipped,
                // when the record names no author; a number last.
                label = inline
                    ?? authorDateLabel(of: record).map { "(\($0))" }
                    ?? record.flatMap { $0.title.isEmpty ? nil : $0.title }
                        .map { "(\(clippedLabel($0)))" }
                    ?? number.map { "[\($0)]" }
                    ?? "[\(key)]"
            case .numeric:
                label = number.map { "[\($0)]" } ?? inline ?? "[\(key)]"
            case .superscript:
                label = number.map(superscriptDigits) ?? inline ?? "[\(key)]"
            }
            if linked, reference != nil {
                let escaped = key.addingPercentEncoding(withAllowedCharacters: keyAllowed) ?? key
                label = "[\(label)](\(citationScheme):\(escaped))"
            }
            out = out.replacingCharacters(in: match.range, with: label) as NSString
        }
        return out as String
    }

    /// A title short enough to sit inline — clipped at a word break.
    private static func clippedLabel(_ text: String) -> String {
        guard text.count > 60 else { return text }
        let cut = text.prefix(60)
        let broken = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return broken + "\u{2026}"
    }

    /// 12 as ¹² — the raised small digits `<sup>` asks for, carried by
    /// the characters themselves so selection, links, and every view
    /// render them alike.
    private static func superscriptDigits(_ number: Int) -> String {
        let raised: [Character: Character] = [
            "0": "\u{2070}", "1": "\u{00B9}", "2": "\u{00B2}", "3": "\u{00B3}",
            "4": "\u{2074}", "5": "\u{2075}", "6": "\u{2076}", "7": "\u{2077}",
            "8": "\u{2078}", "9": "\u{2079}", "-": "\u{207B}"]
        return String(String(number).map { raised[$0] ?? $0 })
    }

    /// "Hegland 2025", "Nelson & Engelbart 1968", "Bush et al. 1945" —
    /// surnames from the entry's author field, the year when it has one.
    private static func authorDateLabel(of record: BibTeXRecord?) -> String? {
        guard let record else { return nil }
        let surnames = record.author
            .components(separatedBy: " and ")
            .map { name -> String in
                // BibTeX's "Last, First" names its surname outright;
                // "First Last" ends with it.
                if let comma = name.firstIndex(of: ",") {
                    return String(name[..<comma]).trimmingCharacters(in: .whitespaces)
                }
                return name.components(separatedBy: " ")
                    .last { !$0.isEmpty }?
                    .trimmingCharacters(in: .whitespaces) ?? ""
            }
            .filter { !$0.isEmpty }
        guard let first = surnames.first else { return nil }
        let names = switch surnames.count {
        case 1: first
        case 2: "\(first) & \(surnames[1])"
        default: "\(first) et al."
        }
        return record.year.isEmpty ? names : "\(names) \(record.year)"
    }

    /// The URL scheme a glossary dagger (and its opened brackets)
    /// carries; the readers catch it and toggle the definition.
    static let glossaryScheme = "origami-gloss"

    /// The concept id a glossary link points at — nil for other URLs.
    static func glossaryConceptID(from url: URL) -> String? {
        guard url.scheme == glossaryScheme else { return nil }
        let raw = String(url.absoluteString.dropFirst(glossaryScheme.count + 1))
        return raw.removingPercentEncoding ?? raw
    }

    /// A rendered paragraph with the document's glossary shown on its
    /// terms: after the first whole-word occurrence of each concept's
    /// name, the definition in brackets (`.bracketed`), or a clickable
    /// dagger whose definition opens inline when its id is in `open`
    /// (`.icon`) — the opened brackets carry the same link, so a click
    /// in them closes. `.hidden` returns the text untouched.
    static func glossaryAnnotated(_ attributed: AttributedString,
                                  in doc: LiquidDoc,
                                  display: GlossaryDisplay,
                                  open: Set<String> = []) -> AttributedString {
        guard display == .bracketed || display == .icon,
              !doc.concepts.isEmpty else { return attributed }
        let plain = String(attributed.characters)
        guard !plain.isEmpty else { return attributed }

        func isWordCharacter(_ character: Character) -> Bool {
            character.isLetter || character.isNumber
        }

        // Where each concept's definition attaches: after the first
        // whole-word occurrence of its name, as a character offset.
        var insertions: [(offset: Int, piece: AttributedString)] = []
        for concept in doc.concepts where !concept.description.isEmpty && !concept.name.isEmpty {
            var searchStart = plain.startIndex
            var found: Range<String.Index>?
            while let range = plain.range(of: concept.name,
                                          options: [.caseInsensitive, .diacriticInsensitive],
                                          range: searchStart..<plain.endIndex) {
                let openOK = range.lowerBound == plain.startIndex
                    || !isWordCharacter(plain[plain.index(before: range.lowerBound)])
                let closeOK = range.upperBound == plain.endIndex
                    || !isWordCharacter(plain[range.upperBound])
                if openOK && closeOK {
                    found = range
                    break
                }
                searchStart = range.upperBound
            }
            guard let found else { continue }

            let link = URL(string: glossaryScheme + ":"
                + (concept.id.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
                   ?? concept.id))
            var piece = AttributedString()
            switch display {
            case .bracketed:
                var definition = AttributedString(" [\(concept.description)]")
                definition.foregroundColor = .secondary
                piece = definition
            case .icon:
                if open.contains(concept.id) {
                    // Open, the ] marker gives way to the definition
                    // framed in brackets, in the body's own ink — a
                    // click anywhere in it closes.
                    var definition = AttributedString(" [\(concept.description)]")
                    definition.link = link
                    piece = definition
                } else {
                    var marker = AttributedString("]")
                    marker.link = link
                    piece = marker
                }
            case .hidden, .tab:
                break
            }
            insertions.append((plain.distance(from: plain.startIndex, to: found.upperBound),
                               piece))
        }
        guard !insertions.isEmpty else { return attributed }

        // Rebuilt in one pass, the pieces spliced in at their offsets.
        var result = AttributedString()
        var last = attributed.startIndex
        for (offset, piece) in insertions.sorted(by: { $0.offset < $1.offset }) {
            let cut = attributed.characters.index(attributed.startIndex, offsetBy: offset)
            guard cut >= last else { continue }   // overlapping names: first wins
            result += AttributedString(attributed[last..<cut])
            result += piece
            last = cut
        }
        result += AttributedString(attributed[last...])
        return result
    }

    /// The Tab overview of a paragraph: everything reads slightly grey
    /// except the glossary's terms, each Marked in Author's orange and
    /// clickable; an open term's definition follows its first
    /// occurrence in brackets, in full ink, itself a link so a click
    /// in the brackets closes it.
    static func glossaryOverviewed(_ attributed: AttributedString,
                                   in doc: LiquidDoc,
                                   open: Set<String> = []) -> AttributedString {
        var work = attributed
        work.foregroundColor = .secondary
        guard !doc.concepts.isEmpty else { return work }
        let plain = String(work.characters)
        guard !plain.isEmpty else { return work }

        func isWordCharacter(_ character: Character) -> Bool {
            character.isLetter || character.isNumber
        }

        var insertions: [(offset: Int, piece: AttributedString)] = []
        for concept in doc.concepts where !concept.description.isEmpty && !concept.name.isEmpty {
            let link = URL(string: glossaryScheme + ":"
                + (concept.id.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
                   ?? concept.id))
            var searchStart = plain.startIndex
            var isFirst = true
            while let range = plain.range(of: concept.name,
                                          options: [.caseInsensitive, .diacriticInsensitive],
                                          range: searchStart..<plain.endIndex) {
                searchStart = range.upperBound
                let openOK = range.lowerBound == plain.startIndex
                    || !isWordCharacter(plain[plain.index(before: range.lowerBound)])
                let closeOK = range.upperBound == plain.endIndex
                    || !isWordCharacter(plain[range.upperBound])
                guard openOK && closeOK else { continue }
                if let attributedRange = Range(range, in: work) {
                    work[attributedRange].foregroundColor = markColor
                    work[attributedRange].link = link
                }
                if isFirst, open.contains(concept.id) {
                    var definition = AttributedString(" [\(concept.description)]")
                    definition.link = link
                    insertions.append((plain.distance(from: plain.startIndex,
                                                      to: range.upperBound), definition))
                }
                isFirst = false
            }
        }
        guard !insertions.isEmpty else { return work }

        var result = AttributedString()
        var last = work.startIndex
        for (offset, piece) in insertions.sorted(by: { $0.offset < $1.offset }) {
            let cut = work.characters.index(work.startIndex, offsetBy: offset)
            guard cut >= last else { continue }
            result += AttributedString(work[last..<cut])
            result += piece
            last = cut
        }
        result += AttributedString(work[last...])
        return result
    }

    // MARK: - Folding

    /// The text split into sentences, each closing at a `.`, `!`, or
    /// `?` that stands at a word's end — decimals and abbreviations
    /// mid-word do not break.
    static func sentences(of text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        var iterator = text.makeIterator()
        var pending = iterator.next()
        while let character = pending {
            let next = iterator.next()
            current.append(character)
            if character == "." || character == "!" || character == "?" {
                if next == nil || next?.isWhitespace == true {
                    let sentence = current.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !sentence.isEmpty { sentences.append(sentence) }
                    current = ""
                }
            }
            pending = next
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { sentences.append(tail) }
        return sentences
    }

    /// How far a document folds: 1 is the headings with their first
    /// sentences, 2 the headings alone, and one step more for every
    /// finer heading rank that can drop away. 0 for an empty body.
    static func maxFoldLevel(of doc: LiquidDoc) -> Int {
        guard let body = doc.body, !body.isEmpty else { return 0 }
        let ranks = Set(body.compactMap(\.heading))
        guard !ranks.isEmpty else { return 1 }
        return ranks.count + 1
    }

    /// The body folded to a level. Level 1: every heading, the first
    /// sentence of the paragraph that follows it, and every sentence
    /// carrying Author's ==Mark==. Level 2: the headings alone. Each
    /// level beyond drops the finest heading rank still showing.
    /// A heading id in `expanded` opens its whole subtree — everything
    /// under it, unfolded, until the next heading of its rank or
    /// coarser. Level 0 returns nil — the document unfolded.
    static func folded(_ doc: LiquidDoc, level: Int,
                       expanded: Set<String> = []) -> [LiquidDoc.Paragraph]? {
        guard level > 0, let body = doc.body, !body.isEmpty else { return nil }
        let clamped = min(level, maxFoldLevel(of: doc))
        let ranks = Set(body.compactMap(\.heading)).sorted()
        let cutoff = clamped <= 2
            ? (ranks.last ?? 1)
            : (ranks.dropLast(clamped - 2).last ?? ranks.first ?? 1)

        var out: [LiquidDoc.Paragraph] = []
        var awaitingFirst = true          // the section's opening sentence
        var expandedRank: Int?            // inside an opened subtree
        for paragraph in body {
            if let rank = paragraph.heading {
                if let openRank = expandedRank, rank <= openRank {
                    expandedRank = nil    // the opened subtree has ended
                }
                if expandedRank != nil {
                    out.append(paragraph)
                    continue
                }
                guard clamped == 1 || rank <= cutoff else { continue }
                out.append(paragraph)
                awaitingFirst = true
                if expanded.contains(paragraph.id) {
                    expandedRank = rank
                }
                continue
            }
            if expandedRank != nil {
                out.append(paragraph)     // opened section: everything, whole
                continue
            }
            guard clamped == 1 else { continue }
            guard paragraph.stretchID == nil, paragraph.tableID == nil,
                  paragraph.text != "---",
                  LiquidDoc.imageReference(in: paragraph.text) == nil else { continue }
            var chosen: [String] = []
            if awaitingFirst, let first = sentences(of: paragraph.text).first {
                chosen.append(first)
                awaitingFirst = false
            }
            // Marked sentences always surface — the author flagged them.
            for sentence in sentences(of: paragraph.text)
            where sentence.components(separatedBy: "==").count >= 3
                && !chosen.contains(sentence) {
                chosen.append(sentence)
            }
            if !chosen.isEmpty {
                out.append(LiquidDoc.Paragraph(id: paragraph.id, heading: nil,
                                               text: chosen.joined(separator: " ")))
            }
        }
        return out
    }

    /// The body folded to a find: every heading — the document's
    /// skeleton — and, in place, the full sentences carrying the term,
    /// so every match reads in its own context. Case- and diacritic-
    /// insensitive, the format's matching. Nil when the term is blank
    /// or nothing matches at all.
    static func folded(_ doc: LiquidDoc, matching term: String) -> [LiquidDoc.Paragraph]? {
        let wanted = term.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty, let body = doc.body, !body.isEmpty else { return nil }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        var out: [LiquidDoc.Paragraph] = []
        for paragraph in body {
            if paragraph.heading != nil {
                out.append(paragraph)
                continue
            }
            guard paragraph.text.range(of: wanted, options: options) != nil else { continue }
            let hits = sentences(of: paragraph.text)
                .filter { $0.range(of: wanted, options: options) != nil }
            guard !hits.isEmpty else { continue }
            out.append(LiquidDoc.Paragraph(id: paragraph.id, heading: nil,
                                           text: hits.joined(separator: " ")))
        }
        return out.contains(where: { $0.heading == nil }) ? out : nil
    }

    /// The reference list as readable sentences: each BibTeX entry
    /// parsed into "“Title” (Authors, Year)", the raw entry standing in
    /// when parsing fails. Pairs with the entry id for anchoring.
    static func readableReferences(of doc: LiquidDoc) -> [(id: String, text: String)] {
        doc.references.map { reference in
            let text = BibTeXRecord.records(in: reference.bibtex).first?.citationSentence
                ?? reference.bibtex
            return (reference.id, text)
        }
    }
}
