//
//  SelectionContext.swift
//  Origami Text
//
//  The reading's selection dot: select words in Scroll or Horizontal and a
//  small chrome ball stands just below and right of where the selection
//  ends — where a finger curls down to it. Hovering it opens a menu
//  (Annotate, Copy as Citation) and the context panel: what is known about
//  the words in this paper and in the reader's own library. The panel is a
//  card the reader drags by its header and closes with ✕.
//
//  Both readers report the same thing — the words, where they end in the
//  window, and closures for annotating and citing — into
//  `AppModel.selectionContext`; one `SelectionDotLayer` over the reading
//  screen draws the dot for either. See CONTEXT-PANEL-PLAN.md for where
//  the panel grows next (online sources, Claim Check).
//

import SwiftUI
import AppKit
import NaturalLanguage

/// Settings ▸ Reading ▸ Selection: the custom dot, or the system's own
/// selection behaviour alone (the right-click menu, no dot).
enum SelectionContextStyle: String, CaseIterable, Identifiable {
    case custom, system
    static let key = "selectionContextStyle"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .custom: "Custom"
        case .system: "System"
        }
    }
    /// Whether the readers report selections for the dot.
    static var showsDot: Bool {
        (UserDefaults.standard.string(forKey: key)).flatMap(Self.init(rawValue:)) != .system
    }
}

/// One selection, as the dot and its panel need it.
struct SelectionContext: Identifiable {
    let id = UUID()
    /// The selected words.
    var text: String
    /// The open document, for the panel's "in this paper".
    var doc: LiquidDoc?
    /// The open book's library address, left out of "in your library".
    var bookAddress: String?
    /// The reporter's own name for where the words are (a paragraph id),
    /// so a paragraph losing its selection clears only its own report.
    var sourceID: String?
    /// Where the hand let go of the selection (else where it ends), in
    /// SwiftUI global coordinates.
    var point: CGPoint
    var annotate: (ReaderAnnotationKind) -> Void
    var comment: (String) -> Void
    var copyCitation: () -> Void

    /// The words as the engine reads them: what kind of thing they are,
    /// People answering whether a name is known.
    @MainActor func query(_ model: AppModel) -> ContextQuery {
        ContextQuery.make(text: text, doc: doc, isKnownName: { model.knowsAuthor(named: $0) })
    }

    /// An AppKit window point as a SwiftUI global point: the window's
    /// content view is the hosting view whose top-left SwiftUI calls 0,0.
    static func globalPoint(fromWindow point: NSPoint, in window: NSWindow?) -> CGPoint? {
        guard let content = window?.contentView else { return nil }
        let local = content.convert(point, from: nil)
        return CGPoint(x: local.x,
                       y: content.isFlipped ? local.y : content.bounds.height - local.y)
    }
}

// MARK: - The reading theme

/// The reading's theme as the menu and panel wear it: the page's
/// background and ink, edited colours live.
struct ReadingThemeColors: ViewModifier {
    @AppStorage(AppSettings.readerThemeKey) private var themeRaw = ReaderTheme.highContrast.rawValue
    @AppStorage(ThemeColorOverrides.tickKey) private var themeEditTick = 0
    @Environment(\.colorScheme) private var colorScheme
    let cornerRadius: CGFloat
    let shadowRadius: CGFloat
    /// An outline in the theme's own ink, at this strength: darker on a
    /// light page, lighter on a dark one. Nil draws none.
    var outlineOpacity: Double? = nil

    func body(content: Content) -> some View {
        let _ = themeEditTick
        let theme = ReaderTheme(rawValue: themeRaw) ?? .highContrast
        let ink = theme.textColor(for: colorScheme) ?? Color.primary
        content
            .foregroundStyle(ink)
            .overlay {
                if let outlineOpacity {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(ink.opacity(outlineOpacity), lineWidth: 1)
                }
            }
            // The shadow belongs to the card, never to its words.
            .background {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(theme.background(for: colorScheme) ?? Color(nsColor: .textBackgroundColor))
                    .shadow(color: .black.opacity(0.2), radius: shadowRadius, y: shadowRadius / 2.5)
            }
    }
}

extension View {
    func readingThemeCard(cornerRadius: CGFloat, shadow: CGFloat,
                          outline: Double? = nil) -> some View {
        modifier(ReadingThemeColors(cornerRadius: cornerRadius, shadowRadius: shadow,
                                    outlineOpacity: outline))
    }
}

// The dot itself, SelectionDot, is shared with Vision Pro: OrigamiReading.swift.

// MARK: - The layer over the reading

/// Draws the dot where the selection ends, its menu beside it on hover,
/// and the context panel. Sits over the whole reading screen; only the
/// dot, the menu and the panel take the pointer.
struct SelectionDotLayer: View {
    @Environment(AppModel.self) private var model
    @State private var origin: CGPoint = .zero
    @State private var hovering = false
    @State private var showsMenu = false
    /// The panel's selection: kept while open, so a dragged-aside panel
    /// follows each new selection rather than vanishing with the dot.
    @State private var panelContext: SelectionContext?
    @State private var panelPlace: CGPoint?
    @State private var dragStart: CGPoint?
    @State private var writesComment = false
    @AppStorage(SelectionContextStyle.key) private var styleRaw = SelectionContextStyle.custom.rawValue
    private var showsDot: Bool { styleRaw != SelectionContextStyle.system.rawValue }

    /// Below and to the right of where the hand let go — a finger curls
    /// down to it without covering the words.
    private static let reach = CGSize(width: 12, height: 16)

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear.allowsHitTesting(false)
            if showsDot, let context = model.selectionContext {
                let dot = CGPoint(x: context.point.x - origin.x + Self.reach.width,
                                  y: context.point.y - origin.y + Self.reach.height)
                SelectionDot(lifted: hovering)
                    .frame(width: 30, height: 30)   // a forgiving target
                    .contentShape(Circle())
                    .onHover { inside in
                        hovering = inside
                        if inside { showsMenu = true }
                    }
                    .onTapGesture { showsMenu = true }
                    .help("Context, Annotate, Copy as Citation")
                    .position(dot)
                if showsMenu {
                    SelectionMenu(context: context, onComment: {
                        writesComment = true
                        open(context)
                    }, onContext: {
                        open(context)
                    })
                    .fixedSize()
                    // Hung by its top-left corner beside the dot, so a
                    // long quick answer grows away from it.
                    .frame(width: 0, height: 0, alignment: .topLeading)
                    .position(x: dot.x + 18, y: dot.y - 8)
                }
            }
            if showsDot, let panel = panelContext {
                let place = panelPlace ?? defaultPlace(for: panel)
                SelectionContextPanel(
                    context: panel,
                    writesComment: $writesComment,
                    onClose: closePanel,
                    onDrag: { translation in
                        if dragStart == nil { dragStart = place }
                        if let start = dragStart {
                            panelPlace = CGPoint(x: start.x + translation.width,
                                                 y: start.y + translation.height)
                        }
                    },
                    onDragEnd: { dragStart = nil })
                    .frame(width: 380)
                    .fixedSize(horizontal: false, vertical: true)
                    .position(place)
            }
        }
        .onGeometryChange(for: CGPoint.self) { $0.frame(in: .global).origin } action: {
            origin = $0
        }
        // A new selection: the menu waits for the next hover; an open
        // panel follows the new words, where the reader left it.
        .onChange(of: model.selectionContext?.id) {
            showsMenu = false
            hovering = false
            if panelContext != nil, let next = model.selectionContext {
                panelContext = next
                writesComment = false
            }
        }
    }

    /// The panel, asked for from the menu (Context, or Comment's box):
    /// the menu steps aside as the panel opens.
    private func open(_ context: SelectionContext) {
        showsMenu = false
        if panelContext?.id != context.id { panelContext = context }
    }

    private func closePanel() {
        panelContext = nil
        panelPlace = nil
        writesComment = false
    }

    /// First opening: right of the selection, a little below the dot.
    private func defaultPlace(for context: SelectionContext) -> CGPoint {
        CGPoint(x: context.point.x - origin.x + 220 + 40,
                y: context.point.y - origin.y + 170)
    }
}

/// The panel's close button: macOS's round close, in grey rather than
/// red, its ✕ always showing.
struct WindowCloseButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                // A quiet grey disc, a shade darker under the pointer.
                Circle()
                    .fill(Color.secondary.opacity(hovering ? 0.45 : 0.28))
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(Color.primary.opacity(0.7))
            }
            .frame(width: 12, height: 12)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Close")
        .accessibilityLabel("Close")
    }
}

// MARK: - The menu beside the dot

/// The quick answer first, when the paper has one. Then Show All — the paper folded to its headings and every sentence
/// using the words — then Annotate (every highlight kind, and a comment),
/// Copy as Citation, and Context last, which alone opens the context
/// panel. More verbs to come.
struct SelectionMenu: View {
    @Environment(AppModel.self) private var model
    let context: SelectionContext
    let onComment: () -> Void
    let onContext: () -> Void
    @State private var copied = false
    /// The one line the paper can say at once (CONTEXT-PANEL-PLAN §2).
    @State private var quickAnswer: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let quickAnswer {
                Text(quickAnswer)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 320, alignment: .leading)
                    .help(quickAnswer)
                Divider()
            }
            Button {
                // The find-fold: the Outline view of the words — headings
                // and the sentences carrying them, highlighted, ⌘G
                // stepping through; leaving it returns to this view.
                model.showFindFold(term: context.text)
                model.selectionContext = nil
            } label: {
                HoverBoldLabel(title: "Show All", systemImage: "list.bullet.indent")
            }
            .buttonStyle(.plain)
            .help("Fold the paper to its headings and every sentence using these words")
            Menu {
                ForEach(ReaderAnnotationKind.allCases, id: \.self) { kind in
                    Button(kind.rawValue) { context.annotate(kind) }
                }
                Divider()
                Button("Comment\u{2026}", action: onComment)
            } label: {
                HoverBoldLabel(title: "Annotate", systemImage: "highlighter")
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.visible)
            Button {
                context.copyCitation()
                copied = true
            } label: {
                HoverBoldLabel(title: copied ? "Copied" : "Copy as Citation",
                               systemImage: "quote.opening")
            }
            .buttonStyle(.plain)
            Button(action: onContext) {
                HoverBoldLabel(title: "Context", systemImage: "info.circle")
            }
            .buttonStyle(.plain)
            .help("What this paper and your library know about the words")
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .readingThemeCard(cornerRadius: 8, shadow: 4)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))
        .task(id: context.id) {
            quickAnswer = nil
            let query = context.query(model)
            guard let doc = context.doc else { return }
            let words = query.text
            let outside = words.count <= 80 ? model.glossaryDefinition(matching: words) : nil
            quickAnswer = ContextPaperFindings.gather(for: query, in: doc)
                .quickAnswer(for: query, definition: outside)
        }
    }
}

/// A menu item's words, bold while the pointer is over them. The bold
/// width is held from the start, so the menu never shifts as it hovers.
struct HoverBoldLabel: View {
    let title: String
    let systemImage: String
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .leading) {
            Label(title, systemImage: systemImage).bold().hidden()
            Label(title, systemImage: systemImage)
                .fontWeight(hovering ? .bold : .regular)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

// MARK: - The context panel

/// What is known about the words: in this paper, then in the reader's own
/// library. Offline, every line from a named place.
struct SelectionContextPanel: View {
    @Environment(AppModel.self) private var model
    let context: SelectionContext
    @Binding var writesComment: Bool
    let onClose: () -> Void
    let onDrag: (CGSize) -> Void
    let onDragEnd: () -> Void

    @State private var query: ContextQuery?
    @State private var paper = ContextPaperFindings()
    @State private var definition: (name: String, description: String)?
    @State private var person: String?
    @State private var kept = false
    /// Your library's papers that cite this one, and the standing of a
    /// selected citation's work.
    @State private var citingPapers: [LiquidDoc] = []
    @State private var standing: [ReferenceStatus.Mark] = []
    @State private var notes: [(book: String, words: String, note: String?)] = []
    @State private var library: [(record: EPUBRecord, passage: String, count: Int)] = []
    @State private var searchedLibrary = false
    @State private var commentText = ""
    @FocusState private var commentFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("\u{201C}\(context.text)\u{201D}")
                        .font(AppFonts.body(16).italic())
                        .lineLimit(4)
                        .textSelection(.enabled)
                    if writesComment { commentBox }
                    paperSpecifics
                    if let definition {
                        section("Definition") {
                            Text(definition.name).font(.body.weight(.semibold))
                            Text(definition.description).font(AppFonts.body(15))
                        }
                    }
                    if let person {
                        section("Person") {
                            Button("Open \(person)\u{2019}s profile") { model.openAuthorPage(named: person) }
                                .buttonStyle(.link)
                        }
                    }
                    section("In this paper") {
                        if paper.uses == 0 {
                            quiet("Not found elsewhere in this paper.")
                        } else {
                            Text("Used \(ContextPaperFindings.times(paper.uses)).")
                                .font(.body)
                            if let first = paper.firstUse { usage("First", first) }
                            if let last = paper.lastUse { usage("Last", last) }
                        }
                    }
                    section("Your notes") {
                        if notes.isEmpty {
                            quiet("No notes of yours on these words.")
                        } else {
                            ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(note.note ?? "\u{201C}\(note.words)\u{201D}")
                                        .font(AppFonts.body(15)).lineLimit(3)
                                    Text(note.book).font(.callout).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    if !standing.isEmpty {
                        section("Standing") {
                            ForEach(standing, id: \.self) { mark in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(mark.text)
                                        .font(.callout.weight(mark.pill ? .semibold : .regular))
                                        .foregroundStyle(Self.color(of: mark.tone))
                                    if !mark.meaning.isEmpty {
                                        Text(mark.meaning).font(.callout).foregroundStyle(.secondary)
                                    }
                                }
                                .help(mark.detail)
                            }
                        }
                    }
                    if !citingPapers.isEmpty {
                        section("Cited Here") {
                            Text("Papers in your library citing this one:")
                                .font(.callout).foregroundStyle(.secondary)
                            ForEach(citingPapers, id: \.id) { paper in
                                Text(paper.title).font(.body.weight(.medium)).lineLimit(2)
                            }
                        }
                    }
                    section("In your library") {
                        if !searchedLibrary {
                            ProgressView().controlSize(.small)
                        } else if library.isEmpty {
                            quiet("No other paper in your library uses these words.")
                        } else {
                            ForEach(library, id: \.record.id) { hit in
                                Button {
                                    model.openEPUBRecord(withID: hit.record.id)
                                } label: {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(hit.record.title).font(.body.weight(.medium))
                                            .lineLimit(2).multilineTextAlignment(.leading)
                                        Text(hit.passage).font(AppFonts.body(14))
                                            .foregroundStyle(.secondary).lineLimit(2)
                                            .multilineTextAlignment(.leading)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("Open this paper")
                            }
                        }
                    }
                    if let query {
                        ContextOnlineSection(query: query)
                        if searchedLibrary {
                            ContextAISection(query: query, sentence: aiSentence,
                                             material: aiMaterial)
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 420)
        }
        .readingThemeCard(cornerRadius: 10, shadow: 10, outline: 0.5)
        .task(id: context.id) { await gather() }
        .onChange(of: writesComment) { if writesComment { commentFocused = true } }
    }

    /// The header: the panel's name, the grip it is dragged by, ✕.
    private var header: some View {
        HStack(spacing: 8) {
            WindowCloseButton(action: onClose)
            Text("Context").font(.body.weight(.semibold))
            if let query {
                Text(query.kind.label).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: keep) {
                Image(systemName: kept ? "checkmark.circle.fill" : "checkmark.circle")
                    .font(.system(size: 15))
            }
            .buttonStyle(.plain)
            .disabled(kept || query == nil)
            .help(kept ? "Kept as a comment on these words"
                  : "Keep what the panel found as a comment on these words")
            .accessibilityLabel(kept ? "Kept" : "Keep")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .gesture(DragGesture(coordinateSpace: .global)
            .onChanged { onDrag($0.translation) }
            .onEnded { _ in onDragEnd() })
        .help("Drag to move")
    }

    private var commentBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Comment").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
            TextEditor(text: $commentText)
                .font(AppFonts.body(15))
                .frame(minHeight: 60)
                .focused($commentFocused)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.3)))
            HStack {
                Spacer()
                Button("Cancel") {
                    writesComment = false
                    commentText = ""
                }
                Button("Save") {
                    context.comment(commentText)
                    commentText = ""
                    writesComment = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func quiet(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.tertiary)
    }

    private func usage(_ label: String, _ sentence: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)
            Text(sentence).font(AppFonts.body(15)).lineLimit(4)
        }
    }

    /// What only this kind of selection has: the reference a citation
    /// names, where an identifier resolves, a figure's caption, what a
    /// symbol stands for.
    @ViewBuilder private var paperSpecifics: some View {
        if let line = paper.citationLine {
            section("Reference") {
                Text(line).font(AppFonts.body(15)).textSelection(.enabled)
                if let url = paper.citationURL {
                    Link(url.absoluteString, destination: url).font(.callout)
                }
            }
        }
        if query?.kind == .identifier, let url = query?.identifierURL {
            section("Identifier") {
                Link("Open at \(url.host() ?? url.absoluteString)", destination: url)
            }
        }
        if query?.kind == .figureOrTable {
            section(query?.label ?? "Figure") {
                if let caption = paper.caption {
                    Text(caption).font(AppFonts.body(15))
                    Text(paper.mentions == 0 ? "Not discussed elsewhere in the text."
                         : "Discussed \(ContextPaperFindings.times(paper.mentions)) in the text.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    quiet("No caption with this label in the paper.")
                }
            }
        }
        if query?.kind == .symbol {
            section("Symbol") {
                if let defined = paper.symbolDefinition {
                    Text(defined).font(AppFonts.body(15))
                } else {
                    quiet("The paper does not say what it stands for.")
                }
            }
        }
    }

    static func color(of tone: ReferenceStatus.Mark.Tone) -> Color {
        switch tone {
        case .alarm: .red
        case .caution: .orange
        case .info: .blue
        case .good: .green
        case .positive: .accentColor
        case .quiet: .secondary
        }
    }

    /// The paragraph the words are in, as the AI's first source.
    private var aiParagraph: String? {
        guard let doc = context.doc else { return nil }
        return (doc.body ?? []).lazy.map { ContextQuery.plain($0.text) }
            .first { $0.localizedCaseInsensitiveContains(context.text) }
    }

    private var aiSentence: String? {
        guard let paragraph = aiParagraph else { return nil }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = paragraph
        return tokenizer.tokens(for: paragraph.startIndex..<paragraph.endIndex)
            .map { String(paragraph[$0]) }
            .first { $0.localizedCaseInsensitiveContains(context.text) }
    }

    /// Everything the panel found, as quotable material for the AI.
    private var aiMaterial: [ContextAI.Source] {
        var out: [ContextAI.Source] = []
        if let aiParagraph { out.append(.init(text: aiParagraph, name: "This paper")) }
        if let first = paper.firstUse { out.append(.init(text: first, name: "This paper")) }
        if let last = paper.lastUse { out.append(.init(text: last, name: "This paper")) }
        if let definition { out.append(.init(text: definition.description, name: "Glossary: \(definition.name)")) }
        for note in notes { out.append(.init(text: note.note ?? note.words, name: "Your note, \(note.book)")) }
        for hit in library where hit.count > 0 {
            out.append(.init(text: hit.passage, name: hit.record.title))
        }
        return out
    }

    /// Keep: the findings, as words, become a comment on the selection —
    /// an annotation like any other, found again in Your notes.
    private func keep() {
        guard let query else { return }
        var extra: [String] = []
        if let person { extra.append("Person: \(person)") }
        if !library.isEmpty {
            extra.append("In your library: " + library.map(\.record.title).joined(separator: "; "))
        }
        if !standing.isEmpty {
            extra.append("Standing: " + standing.map(\.text).joined(separator: ", "))
        }
        context.comment(paper.keptText(for: query, definition: definition, extra: extra))
        kept = true
    }

    // MARK: Gathering

    /// The local rings: this paper first, then the reader's notes and
    /// library. Words longer than a phrase skip the term lookups.
    private func gather() async {
        // A selection still being dragged changes many times a second:
        // gather once it rests.
        try? await Task.sleep(for: .milliseconds(250))
        if Task.isCancelled { return }
        let query = context.query(model)
        let words = query.text
        self.query = query
        definition = nil; person = nil; kept = false
        notes = []; library = []; searchedLibrary = false
        paper = context.doc.map { ContextPaperFindings.gather(for: query, in: $0) }
            ?? ContextPaperFindings()
        let phrase = words.count <= 80
        if phrase {
            definition = model.glossaryDefinition(matching: words) ?? paper.definition
            if query.kind == .name { person = words }
        }
        citingPapers = []; standing = []
        if let reference = query.reference, let doc = context.doc {
            let record = BibTeXRecord.records(in: reference.bibtex).first
            let title = record?.title ?? reference.citedAs ?? ""
            let doi = ReferenceStatus.cleanDOI(record?.fields["doi"])
            await ReferenceStatus.loadIndexIfNeeded()
            let all = ReferenceStatus.marks(for: ReferenceStatus.MarkInput(
                doi: doi, title: title,
                year: Int((record?.year ?? "").filter(\.isNumber).prefix(4)),
                entryType: record?.entryType ?? "", fields: record?.fields ?? [:],
                smallList: doc.references.count < 15))
            standing = ReferenceStatus.visible(all, for: ReferenceStatus.workKeys(doi: doi, title: title))
        }
        if let doc = context.doc {
            citingPapers = Array(ContextPaperFindings.papers(
                citing: doc, among: model.index.byID.values.map(\.doc)).prefix(5))
        }
        // Your notes: annotations on the same words, or whose comment
        // mentions them, in any book.
        let folded = words.lowercased()
        notes = model.allAnnotations.compactMap { item in
            let exact = item.exact ?? ""
            let note = item.annotation.body?.value
            guard exact.lowercased().contains(folded)
                    || (note?.lowercased().contains(folded) ?? false) else { return nil }
            let book = model.epubRecords.first { $0.id == item.address || $0.folder == item.address }?
                .title ?? "A document"
            return (book, exact, note)
        }.prefix(5).map { $0 }
        // In your library: other papers whose text uses the words.
        await Task.yield()
        if Task.isCancelled { return }
        if phrase {
            let others = model.epubRecords.filter {
                $0.id != context.bookAddress && $0.folder != context.bookAddress
            }
            let split = model.searchSplitEPUBs(others, query: words, quietly: true)
            // Works named by the words (title, author) first, then those
            // whose text uses them, most uses first.
            let named = split.named.prefix(3).map { (record: $0, passage: "Title or author", count: 0) }
            let inText = split.inText.map { (record: $0.record, passage: $0.match.passage, count: $0.match.count) }
            library = Array((named + inText).prefix(6))
        }
        searchedLibrary = true
    }
}

#Preview("Selection dot") {
    HStack(spacing: 24) {
        SelectionDot()
        SelectionDot(lifted: true)
        SelectionDot(size: 64)
    }
    .padding(30)
    .background(Color.white)
}
