import SwiftUI
import AppKit
import UniformTypeIdentifiers
import WebKit

// Ported from Knowledge Space's OrigamiReadingView.swift (itself from
// Augmented Library) — the book reader: an Origami document read
// natively in the reader's chosen view style with the reading menu on
// every paragraph, W3C highlights and comments in sidecars, the
// glossary's four displays, progressive folding, flow reading, and the
// on-device reading functions. Keep the shared parts synced; a fix here
// should be carried back.
//
// Origami Text adaptations, each marked "OT:" where it lands:
//  - AppState → AppModel; annotations live in the EPUBs/Annotations
//    sidecars the WebView reader shares.
//  - The mode words gain Faithful (the WebView rendering, this app's
//    own) plus Outline and Transcript — every reading mode, one foot.
//  - No LaTeX profile, no excerpt handling, no external source
//    resolvers: a citation always shows its card.

/// How the book is presented: faithfully (the EPUB's own HTML in the
/// WebView) or natively in one of the reading styles. Stored under
/// "readerMode", the foot's words.
enum EPUBReaderMode: String, CaseIterable, Identifiable {
    case faithful, scroll, horizontal, focus, outline, transcript

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .faithful: "Default"
        case .scroll: "Scroll"
        case .horizontal: "Horizontal"
        case .focus: "Focus"
        case .outline: "Outline"
        case .transcript: "Transcript"
        }
    }

    var help: String {
        switch self {
        case .faithful: "The book's own pages, exactly as published"
        case .scroll: "The document as written, one flow"
        case .horizontal: "Pages side by side — two, or more when the window is wide"
        case .focus: "One section alone, to settle into — arrows move through"
        case .outline: "Sections fold under their headings"
        case .transcript: "Turns grouped by who is speaking"
        }
    }
}

/// The fold-into-outline verbs and the type-setting verbs a reading
/// offers the View menu while it is front.
struct OutlineFoldActions {
    let folded: Bool
    let fold: () -> Void
    let unfold: () -> Void
}

struct ReadingTypographyActions {
    let bigger: () -> Void
    let smaller: () -> Void
    let looser: () -> Void
    let tighter: () -> Void
}

extension FocusedValues {
    @Entry var outlineFold: OutlineFoldActions?
    @Entry var readingTypography: ReadingTypographyActions?
}

/// The View-menu verbs a front reading answers: ⌘− folds into the
/// outline, ⌘+ opens the reading whole; ⇧⌘± sizes the type, ⌥⌘± sets
/// the leading. Disabled while nothing readable is front.
struct ReadingCommands: Commands {
    let model: AppModel
    @AppStorage("textColoringMode") private var coloringModeRaw = TextColoringMode.off.rawValue
    @FocusedValue(\.outlineFold) private var outlineFold
    @FocusedValue(\.readingTypography) private var typography

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Divider()
            // The ways of seeing the words, as in Knowledge Space: Flow
            // breaks the body into reading lines at sentence and clause
            // marks; the colour views paint by grammar (parts of speech)
            // or meaning (the people, places, and organizations named).
            Toggle("Flow", isOn: Binding(
                get: { model.flowReading },
                set: { model.flowReading = $0 }))
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Picker("Colour Words By", selection: $coloringModeRaw) {
                ForEach(TextColoringMode.allCases) { mode in
                    Text(mode.displayName).tag(mode.rawValue)
                }
            }
            Divider()
            // Find in the open book — both presentations answer.
            Button("Find in Book") { model.readerFindShow += 1 }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(model.openEPUB == nil)
            Button("Find Next") { model.readerFindNext += 1 }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(model.openEPUB == nil)
            Button("Find Previous") { model.readerFindPrevious += 1 }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(model.openEPUB == nil)
            Divider()
            Button("Fold") { outlineFold?.fold() }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(outlineFold == nil)
            Button("Unfold") { outlineFold?.unfold() }
                .keyboardShortcut("=", modifiers: .command)
                .disabled(outlineFold == nil || outlineFold?.folded != true)
            Divider()
            Button("Bigger Text") { typography?.bigger() }
                .keyboardShortcut("+", modifiers: [.command, .shift])
                .disabled(typography == nil)
            Button("Smaller Text") { typography?.smaller() }
                .keyboardShortcut("-", modifiers: [.command, .shift])
                .disabled(typography == nil)
            Button("Looser Lines") { typography?.looser() }
                .keyboardShortcut("+", modifiers: [.command, .option])
                .disabled(typography == nil)
            Button("Tighter Lines") { typography?.tighter() }
                .keyboardShortcut("-", modifiers: [.command, .option])
                .disabled(typography == nil)
        }
    }
}

// MARK: - The reader

struct OrigamiReadingView: View {
    @Environment(AppModel.self) private var model   // OT: was AppState
    /// Lift opens the document annotation in its own window.
    @Environment(\.openWindow) private var openWindow
    let doc: LiquidDoc

    /// Find in the book: the screen's ⌘F bar feeds these; each stamp
    /// steps to the next (or previous) paragraph carrying the words,
    /// every occurrence reading highlighted while the bar is up.
    var findText: String = ""
    var findStamp: Int = 0
    var findForward: Bool = true
    @State private var findCurrentID: String?

    /// Author's foot modes — Scroll is the article flow; Horizontal is
    /// pages side by side, two at least, a page more for every 460
    /// points the window offers.
    @AppStorage("readerMode") private var readerModeRaw = EPUBReaderMode.faithful.rawValue

    /// Whether this book explicitly is a transcript — its paragraphs
    /// carry speakers (or its metadata says so). Only then does the
    /// foot offer the Transcript mode.
    private var isTranscript: Bool {
        doc.documentType == LiquidDoc.DocumentType.transcript.rawValue
            || (doc.body ?? []).contains { $0.speaker != nil }
    }

    private var availableModes: [EPUBReaderMode] {
        // The Outline group beside Scroll folds the reading now; the
        // old Outline mode word no longer rides at the end.
        EPUBReaderMode.allCases.filter {
            $0 != .outline && ($0 != .transcript || isTranscript)
        }
    }

    private var readerMode: EPUBReaderMode {
        let mode = EPUBReaderMode(rawValue: readerModeRaw) ?? .scroll
        // A transcript mode left over from a transcript book reads as
        // the flow here; a persisted Outline mode reads as the flow
        // too, folded or not by the Outline group.
        if mode == .transcript, !isTranscript { return .scroll }
        if mode == .outline { return .scroll }
        return mode
    }

    @AppStorage("origamiCitationStyle") private var citationsRaw =
        OrigamiCitationStyle.authorDate.rawValue
    @AppStorage("origamiContextActions") private var actionsRaw =
        OrigamiContextAction.encodeList(OrigamiContextAction.defaultActions)
    @AppStorage("readingAIPrompts") private var aiPromptsRaw =
        AIPromptPreset.encodeList(AIPromptPreset.defaultPresets)
    /// The reader's chosen faces — the same Settings ▸ Reading ▸ Fonts
    /// choice the faithful view and every other view honours.
    @AppStorage(AppSettings.readerBodyFontKey)
    private var bodyFontName = ReaderStyle.defaultBodyFont
    @AppStorage(AppSettings.readerHeadingFontKey)
    private var headingFontName = ReaderStyle.defaultHeadingFont
    /// Points added to (or taken from) every reading size — ⌘⇧+ and
    /// ⌘⇧−. One value for all windows, kept until changed.
    @AppStorage("readingFontDelta") private var fontDelta = 3.0
    /// Extra points between lines — ⌥⌘+ and ⌥⌘−. Shared and kept the
    /// same way.
    @AppStorage("readingLineSpacing") private var lineSpacing = 3.0
    @AppStorage("stretchtextDisplay") private var stretchDisplayRaw =
        StretchtextDisplay.callout.rawValue
    @AppStorage("glossaryDisplay") private var glossaryDisplayRaw =
        GlossaryDisplay.hidden.rawValue
    @AppStorage("markedTextStyle") private var markedStyleRaw = MarkedTextStyle.orange.rawValue
    /// Engelbart's grammar-of-the-view: colour code words by part of
    /// speech or named entity.
    @AppStorage("textColoringMode") private var coloringModeRaw = TextColoringMode.off.rawValue
    @AppStorage("textColorRules") private var colorRulesRaw =
        TextColorRule.encodeList(TextColorRule.defaultRules)
    @Environment(\.colorScheme) private var colorScheme

    private var coloringMode: TextColoringMode {
        TextColoringMode(rawValue: coloringModeRaw) ?? .off
    }

    /// Author's full-screen measure: the text column as a percentage
    /// of the display's width, one value for the built-in display and
    /// one for an external.
    @AppStorage("fullScreenWidthInternal") private var fullScreenWidthInternal = 67.0
    @AppStorage("fullScreenWidthExternal") private var fullScreenWidthExternal = 45.0
    /// The windowed measure, Wider/Narrower in the Aa popover.
    @AppStorage("readingMeasure") private var windowedMeasure = 680.0
    @State private var windowState = ReaderWindowState()

    /// The reading column's width: the chosen points in a window; in
    /// full screen, the chosen percentage of this display's width.
    private var measure: CGFloat {
        guard windowState.isFullScreen else { return CGFloat(windowedMeasure) }
        let percent = windowState.isBuiltInDisplay
            ? fullScreenWidthInternal : fullScreenWidthExternal
        return max(windowState.screenWidth * percent / 100, 300)
    }

    private var markedStyle: MarkedTextStyle {
        MarkedTextStyle(rawValue: Int(markedStyleRaw)) ?? .orange
    }

    /// Any stretchtext open puts the reader in stretch focus: the
    /// revealed text keeps its ink, everything else reads grey.
    private var stretchFocus: Bool { !openStretch.isEmpty }

    private var stretchDisplay: StretchtextDisplay {
        StretchtextDisplay(rawValue: stretchDisplayRaw) ?? .callout
    }

    private var glossaryDisplay: GlossaryDisplay {
        GlossaryDisplay(rawValue: glossaryDisplayRaw) ?? .hidden
    }

    @State private var focusIndex = 0
    @State private var collapsed: Set<String> = []
    @State private var openStretch: Set<String> = []
    /// Inline notes travelling as stretchtext: the ids whose [] is
    /// unfolded, the words bracketed in place.
    @State private var openInlineNotes: Set<String> = []
    @State private var annotationEditor: AnnotationEditTarget?
    @State private var marginNoteTarget: MarginNoteTarget?
    /// The page surface, for turning a menu click's window point into
    /// page coordinates — where a new Note stands.
    @State private var surfaceBox = MarginNoteSurfaceBox()
    /// Where each paragraph stands on the page — reported after layout,
    /// so page notes can anchor their placement to the nearest one.
    @State private var paragraphFrames: [String: CGRect] = [:]

    /// A page point as a placement: anchored to the nearest paragraph
    /// (by its top edge) with the offset from its top-left, so the note
    /// re-places itself across resizes and Macs. With no paragraphs
    /// laid out yet, the point stands absolute.
    private func placement(for point: CGPoint) -> WebAnnotation.Placement {
        let nearest = paragraphFrames.min {
            abs($0.value.midY - point.y) < abs($1.value.midY - point.y)
        }
        guard let nearest else {
            return WebAnnotation.Placement(near: nil, dx: point.x, dy: point.y)
        }
        return WebAnnotation.Placement(near: nearest.key,
                                       dx: point.x - nearest.value.minX,
                                       dy: point.y - nearest.value.minY)
    }

    /// Where a page note stands now: its placement resolved against the
    /// current layout, the anchor paragraph's drift followed; absolute
    /// when the anchor is gone; the pre-placement local position for
    /// notes from before placements travelled.
    private func slipPosition(for annotation: WebAnnotation) -> CGPoint? {
        if let placement = annotation.placement {
            if let near = placement.near, let frame = paragraphFrames[near] {
                return CGPoint(x: frame.minX + placement.dx,
                               y: frame.minY + placement.dy)
            }
            return CGPoint(x: placement.dx, y: placement.dy)
        }
        return model.marginNotePosition(forAnnotationID: annotation.id)
    }
    @State private var conceptTarget: LiquidDoc.Concept?
    @State private var citationTarget: CitationTarget?
    @State private var noteTarget: NoteTarget?
    @State private var showReferences = false
    /// The header pill's editor for the whole-document annotation.
    @State private var showsDocumentAnnotation = false
    /// A selection being viewed differently — Flow lines or an AI
    /// rewrite. While set, everything unselected reads grey and any
    /// click on the grey returns to normal.
    @State private var selectionMode: SelectionViewMode?
    /// The glossary definitions currently unfolded, by concept id
    /// (the Icon display's daggers).
    @State private var openGlossary: Set<String> = []
    /// How far the document is folded (⌘− folds, ⌘+ unfolds): 0 reads
    /// whole; 1 is headings, first sentences, and Marked lines; deeper
    /// levels are headings alone, then fewer ranks of them. Shared on
    /// the model, so the foot bar's Outline group drives it too.
    private var foldLevel: Int {
        get { model.readerFoldLevel }
        nonmutating set { model.readerFoldLevel = newValue }
    }
    /// Sections clicked open while folded, by heading id.
    @State private var expandedFold: Set<String> = []
    /// What the fold shows under its headings — nothing (the headings
    /// alone speak), the sections' Defined Concepts, or the people
    /// named. Author's alternate pinch targets.
    @AppStorage("readingFoldTarget") private var foldTargetRaw = FoldTarget.headings.rawValue
    /// The Tab glossary overview: text grey, terms Marked, definitions
    /// a click away. Tab again returns to normal reading.
    @State private var glossaryOverviewOn = false
    @State private var tabMonitor: Any?
    /// The moment's confirmation line at the window's foot.
    @State private var keepNotice: String?
    // The reading functions: the text expanded into meaning-paragraphs
    // (p), broken into flow lines (f), and each paragraph's key
    // sentence bolded (b).
    @State private var expandParagraphs = false

    @State private var boldKeySentences = false
    /// The model's paragraph breaks, cached per paragraph id.
    @State private var paragraphSplits: [String: String] = [:]
    /// The model's key sentence per paragraph id, cached — empty where
    /// it chose none, so a paragraph is never asked twice.
    @State private var keySentences: [String: String] = [:]
    @State private var keyMonitor: Any?
    @AppStorage("flowBreakOnComma") private var flowBreakOnComma = true
    @AppStorage("flowDoubleBreakOnPeriod") private var flowDoubleBreakOnPeriod = false
    @State private var pinchMonitor: Any?
    @State private var pinchAccumulator: CGFloat = 0
    /// Two-finger page turns in Horizontal — the swipe's travel, one
    /// turn per gesture, and the reading area's live width (the page
    /// count follows it).
    @State private var swipeMonitor: Any?
    @State private var swipeAccumulatorX: CGFloat = 0
    @State private var swipeTurned = false
    @State private var horizontalViewWidth: CGFloat = 0
    /// The table of contents popover.
    @State private var showContents = false
    /// Where the next layout pass should land — a heading id from the
    /// contents, a fold toggle, or an arriving fragment.
    @State private var pendingScrollID: String?
    /// Reading-progress memory (the article flow): the scroll offset,
    /// saved a moment after every move and restored on return.
    @State private var scrollPosition = ScrollPosition()
    @State private var progressSaveTask: Task<Void, Never>?

    enum FoldTarget: String, CaseIterable, Identifiable {
        case headings, concepts, names, citations
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .headings: "Headings"
            case .concepts: "Concepts"
            case .names: "Names"
            case .citations: "Citations"
            }
        }
    }


    private var foldTarget: FoldTarget {
        FoldTarget(rawValue: foldTargetRaw) ?? .headings
    }

    /// The paragraph's own sentence for a click with no selection: the
    /// clicked sentence's position in the rendered words, carried to
    /// the same position in the raw text (rendering resolves citations
    /// and marks, so the words can differ). A heading is its own
    /// sentence; an unplaceable click anchors to the first sentence —
    /// never to the whole paragraph.
    private func anchorSentence(for paragraph: LiquidDoc.Paragraph,
                                rendered clicked: String?) -> String? {
        let rawSentences = OrigamiReading.sentences(of: paragraph.text)
        guard paragraph.heading == nil else { return paragraph.text }
        guard let clicked else { return rawSentences.first }
        let renderedText = String(rendered(readingText(for: paragraph)).characters)
        let renderedSentences = OrigamiReading.sentences(of: renderedText)
        let wanted = clicked.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = renderedSentences.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines) == wanted
        }), rawSentences.indices.contains(index) {
            return rawSentences[index]
        }
        // The click's words as they stand, when the raw text carries
        // them verbatim; else the paragraph's opening sentence.
        if paragraph.text.range(of: wanted,
                                options: [.caseInsensitive, .diacriticInsensitive]) != nil {
            return wanted
        }
        return rawSentences.first
    }

    /// A written annotation opened from its words, for the editor sheet.
    struct AnnotationEditTarget: Identifiable {
        let annotation: WebAnnotation
        let paragraphID: String
        var id: String { annotation.id }
    }

    /// A margin note being written: where the ctrl-click fell, in the
    /// article's own coordinates.
    private struct MarginNoteTarget: Identifiable {
        let point: CGPoint
        var id: String { "\(point.x)×\(point.y)" }
    }

    /// The notes standing on the page, each at the spot it was written —
    /// free to sit anywhere, like little slips on the document. A click
    /// opens the whole note with Delete, Copy, and Save; click-and-hold
    /// drags one to a new spot, remembered on this Mac.
    @ViewBuilder private var marginNotesLayer: some View {
        let noteSize = max((NSFont.preferredFont(forTextStyle: .body).pointSize
                            + CGFloat(fontDelta)) / 3, 8)
        ForEach(model.marginNotes(for: doc), id: \.id) { annotation in
            if let position = slipPosition(for: annotation) {
                MarginNoteView(
                    note: annotation,
                    fontSize: noteSize,
                    position: position,
                    onMove: { moved in
                        // The move travels in the sidecar, anchored to
                        // the nearest paragraph at the new spot.
                        model.setNotePlacement(placement(for: moved),
                                               for: annotation, in: doc)
                    },
                    onOpen: {
                        annotationEditor = AnnotationEditTarget(
                            annotation: annotation, paragraphID: "")
                    })
            }
        }
    }

    private struct CitationTarget: Identifiable {
        let key: String
        var id: String { key }
    }

    private struct NoteTarget: Identifiable {
        let noteID: String
        var id: String { noteID }
    }

    private var citationStyle: OrigamiCitationStyle {
        OrigamiCitationStyle(rawValue: citationsRaw) ?? .authorDate
    }

    // MARK: - Theme (OT: the system's own inks)

    private var themeText: Color? { nil }
    private var themeHeading: Color? { nil }
    private var themeDimmed: Color? { Color.secondary }

    /// A paragraph's ink for the AppKit text view.
    private func inkColor(for paragraph: LiquidDoc.Paragraph) -> NSColor? {
        let color = paragraph.heading != nil ? themeHeading : themeText
        return color.map(NSColor.init)
    }

    /// A heading or paragraph rendered with the document's conventions —
    /// citations in the reader's style, then the inline markdown.
    private func rendered(_ text: String) -> AttributedString {
        OrigamiReading.inlineAttributed(text, in: doc, citations: citationStyle,
                                        markStyle: markedStyle, appearance: colorScheme)
    }

    private var enabledActions: [OrigamiContextAction] {
        OrigamiContextAction.decodeList(actionsRaw)
    }

    private var sections: [OrigamiSection] { OrigamiSection.build(from: doc) }

    var body: some View {
        let annotations = resolvedByParagraph
        ScrollViewReader { proxy in
            Group {
                if let term = model.readerFindFoldTerm,
                   let found = OrigamiReading.folded(doc, matching: term) {
                    // The find-fold: headings and the full sentences
                    // around every match, each highlighted by Find and
                    // each a click into the full reading at that place.
                    findFoldView(found, annotations: annotations)
                } else if foldLevel > 0,
                   let folded = OrigamiReading.folded(doc, level: foldLevel,
                                                      expanded: expandedFold) {
                    foldedView(folded, annotations: annotations)
                } else {
                    switch readerMode {
                    case .faithful, .scroll: articleView(annotations)
                    case .horizontal: horizontalView(annotations)
                    case .focus: focusView(annotations)
                    case .outline: outlineView(annotations)
                    case .transcript: transcriptView(annotations)
                    }
                }
            }
            // The contents, the fold toggles, and arriving fragments
            // all land through one door, after layout.
            .onChange(of: pendingScrollID) {
                guard let id = pendingScrollID else { return }
                pendingScrollID = nil
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(id, anchor: .top)
                }
            }
            // A fragment can arrive while this reading already stands
            // open, not only on appearance.
            .onChange(of: model.pendingReaderFragment) {
                guard let fragment = model.pendingReaderFragment else { return }
                land(fragment, with: proxy)
            }
            // The find bar's steps: each stamp walks to the next (or
            // previous) paragraph carrying the words.
            .onChange(of: findStamp) {
                stepFind(with: proxy)
            }
            .onAppear { landOnArrival(proxy) }
        }
        // Author's foot — the mode words at the bottom of the page,
        // with the contents, the fold, and the type at the trailing
        // edge. (The EPUBReaderScreen shows the same foot over the
        // faithful WebView, so the words are always there to click.)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ReadingFootBar(
                modes: availableModes,
                foldLevelLabel: model.readerFindFoldTerm.map { "Finding “\($0)”" }
                    ?? (foldLevel > 0 ? "Folded — level \(foldLevel)" : nil),
                contentsDisabled: sections.isEmpty,
                showContents: $showContents,
                contents: { AnyView(contentsList) },
                typeMenu: { AnyView(typeMenu) })
        }
        // A fold asked for from the foot (or ⌘−/⌘+) resets the opened
        // sections — the shape changed under them.
        .onChange(of: model.readerFoldLevel) {
            expandedFold = []
        }
        .onChange(of: foldTargetRaw) {
            expandedFold = []
        }
        .background(Color(nsColor: .textBackgroundColor).ignoresSafeArea())
        // Where this window is: full screen or not, and on which kind
        // of display — the full-screen measure follows.
        .background {
            ReaderWindowWatcher { state in
                windowState = state
            }
        }
        // ⌘−/⌘+ fold and unfold through the View menu; ⌘⇧± and ⌥⌘± set
        // the type the same way. The menu asks the focused scene, so
        // the front reading answers.
        .focusedSceneValue(\.outlineFold, OutlineFoldActions(
            folded: foldLevel > 0,
            fold: { fold(by: 1) },
            unfold: { fold(by: -1) }))
        .focusedSceneValue(\.readingTypography, ReadingTypographyActions(
            bigger: { stepFontSize(by: 1) },
            smaller: { stepFontSize(by: -1) },
            looser: { stepLineSpacing(by: 1) },
            tighter: { stepLineSpacing(by: -1) }))
        .onChange(of: expandParagraphs) { _, on in
            if on { computeParagraphSplits() }
        }
        .onChange(of: boldKeySentences) { _, on in
            if on { computeKeySentences() }
        }
        // The moment's notice, briefly.
        .overlay(alignment: .bottom) {
            if let keepNotice {
                Text(keepNotice)
                    .font(.callout)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 44)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // Tab toggles the glossary overview — grey text, Marked terms,
        // definitions a click away — unless something is being edited.
        .onAppear {
            tabMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.keyCode == 48,   // Tab
                      event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
                      let window = NSApp.keyWindow,
                      window.windowNumber == windowState.windowNumber,
                      window.attachedSheet == nil
                else { return event }
                if let editor = window.firstResponder as? NSTextView, editor.isEditable {
                    return event
                }
                withAnimation(.easeInOut(duration: 0.15)) {
                    glossaryOverviewOn.toggle()
                }
                return nil
            }
            // Bare p, f, and b — the reading functions — and Esc,
            // Author's door in and out of full screen.
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
                      let window = NSApp.keyWindow,
                      window.windowNumber == windowState.windowNumber,
                      window.attachedSheet == nil
                else { return event }
                if let editor = window.firstResponder as? NSTextView, editor.isEditable {
                    return event
                }
                if event.keyCode == 53 {   // Esc
                    window.toggleFullScreen(nil)
                    return nil
                }
                guard let letter = event.charactersIgnoringModifiers?.lowercased(),
                      letter == "p" || letter == "f" || letter == "b"
                else { return event }
                if letter == "p" {
                    expandParagraphs.toggle()
                } else if letter == "b" {
                    boldKeySentences.toggle()
                } else {
                    model.flowReading.toggle()
                }
                return nil
            }
            // Pinch on the trackpad folds and unfolds — in is ⌘−,
            // out is ⌘+ — one step per gesture's worth of travel.
            pinchMonitor = NSEvent.addLocalMonitorForEvents(matching: .magnify) { event in
                guard event.window?.windowNumber == windowState.windowNumber else {
                    return event
                }
                if event.phase == .began { pinchAccumulator = 0 }
                pinchAccumulator += event.magnification
                if pinchAccumulator <= -0.3 {
                    fold(by: 1)
                    pinchAccumulator = 0
                } else if pinchAccumulator >= 0.3 {
                    fold(by: -1)
                    pinchAccumulator = 0
                }
                return nil
            }
            // Two-finger swipes turn the pages in Horizontal when more
            // than two columns stand across — a clearly sideways
            // movement only, one turn per gesture.
            swipeMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                guard event.window?.windowNumber == windowState.windowNumber,
                      readerMode == .horizontal, foldLevel == 0,
                      event.hasPreciseScrollingDeltas else { return event }
                let shown = horizontalPageCount(width: horizontalViewWidth,
                                                sections: horizontalPages.count)
                guard shown > 2 else { return event }
                if event.phase == .began {
                    swipeAccumulatorX = 0
                    swipeTurned = false
                }
                guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
                else { return event }
                if event.momentumPhase != [] { return nil }
                swipeAccumulatorX += event.scrollingDeltaX
                if !swipeTurned, abs(swipeAccumulatorX) > 60 {
                    swipeTurned = true
                    // Natural scrolling: fingers left brings the pages
                    // to the right — the next spread.
                    turnPages(by: swipeAccumulatorX < 0 ? shown : -shown)
                }
                if event.phase == .ended || event.phase == .cancelled {
                    swipeAccumulatorX = 0
                    swipeTurned = false
                }
                return nil
            }
        }
        .onDisappear {
            if let tabMonitor { NSEvent.removeMonitor(tabMonitor) }
            tabMonitor = nil
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
            if let pinchMonitor { NSEvent.removeMonitor(pinchMonitor) }
            pinchMonitor = nil
            if let swipeMonitor { NSEvent.removeMonitor(swipeMonitor) }
            swipeMonitor = nil
        }
        // A note being written: Save stands its first sentence where
        // the ctrl-click fell — a free slip on the page, touching no
        // text, its place travelling in the sidecar; dismissing writes
        // nothing.
        .sheet(item: $marginNoteTarget) { target in
            ReadingCommentComposer(preview: doc.title) { text in
                model.addMarginNote(text, to: doc,
                                    placement: placement(for: target.point))
            }
        }
        // An annotation chip opened: the whole note, with Delete, Copy
        // (a citation to this document, the note in its Annotation
        // field), and Save.
        .sheet(item: $annotationEditor) { target in
            AnnotationEditorSheet(
                text: target.annotation.body?.value ?? "",
                onDelete: { model.removeAnnotation(target.annotation, for: doc) },
                onCopy: { text in
                    copyAnnotationCitation(paragraphID: target.paragraphID,
                                           annotation: text)
                },
                onSave: { text in
                    model.updateAnnotation(target.annotation, note: text, for: doc)
                })
        }
        .sheet(item: $conceptTarget) { concept in
            ConceptSheet(concept: concept)
        }
        .sheet(item: $citationTarget) { target in
            CitationCardSheet(doc: doc, key: target.key)
        }
        .sheet(item: $noteTarget) { target in
            EndnoteSheet(text: OrigamiReading.endnote(withID: target.noteID, in: doc)
                .map { rendered($0.text) }
                ?? AttributedString("The document carries no note \(target.noteID)."))
        }
        .sheet(isPresented: $showReferences) {
            ReferencesSheet(doc: doc)
        }
        // A tapped citation opens the source's card; a fold-to-concepts
        // term opens its definition; every other link opens as links do.
        .environment(\.openURL, OpenURLAction { url in
            if let key = OrigamiReading.citationKey(from: url) {
                citationTarget = CitationTarget(key: key)
                return .handled
            }
            if url.scheme == "origami-conceptcard" {
                let id = String(url.absoluteString.dropFirst("origami-conceptcard:".count))
                if let concept = doc.concepts.first(where: { $0.id == id }) {
                    conceptTarget = concept
                }
                return .handled
            }
            return .systemAction
        })
    }

    // MARK: - Arriving and remembering

    /// Land where the reading asks: a fragment link's paragraph first;
    /// otherwise, in the article flow, where the reader left off.
    private func landOnArrival(_ proxy: ScrollViewProxy) {
        if let fragment = model.pendingReaderFragment, land(fragment, with: proxy) {
            return
        }
        if readerMode == .scroll, foldLevel == 0 {
            let saved = UserDefaults.standard.double(forKey: progressKey)
            guard saved > 0 else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(120))
                scrollPosition.scrollTo(y: saved)
            }
        }
    }

    /// An arriving fragment, landed — but only a fragment of THIS
    /// document. Scroll flows to the paragraph; Horizontal and Focus
    /// turn to its page first.
    @discardableResult
    private func land(_ fragment: String, with proxy: ScrollViewProxy) -> Bool {
        let mine = (doc.body ?? []).contains { $0.id == fragment }
            || sections.contains { $0.heading?.id == fragment }
        guard mine else { return false }
        model.pendingReaderFragment = nil
        // A target inside a folded stretch block: unfold it first, or the
        // scroll would land on nothing — the WebView reader's
        // origamiRevealStretchtext, natively.
        if let stretchID = (doc.body ?? []).first(where: { $0.id == fragment })?.stretchID {
            openStretch.insert(stretchID)
        }
        if readerMode == .horizontal || readerMode == .focus {
            if let page = horizontalPages.firstIndex(where: { page in
                page.contains { section in
                    section.heading?.id == fragment
                        || section.paragraphs.contains { $0.id == fragment }
                }
            }) {
                withAnimation(.easeInOut(duration: 0.2)) { focusIndex = page }
            }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            withAnimation(.easeInOut(duration: 0.3)) {
                proxy.scrollTo(fragment, anchor: .top)
            }
        }
        return true
    }

    /// One find step: the next (or previous) body paragraph carrying
    /// the words, wrapped at the ends, folded stretchtext unfolding
    /// first — so no match hides.
    private func stepFind(with proxy: ScrollViewProxy) {
        let term = findText.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else {
            findCurrentID = nil
            return
        }
        let matches = (doc.body ?? []).filter {
            $0.text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }.map(\.id)
        guard !matches.isEmpty else { return }
        let next: Int
        if let current = findCurrentID.flatMap({ matches.firstIndex(of: $0) }) {
            next = findForward ? (current + 1) % matches.count
                               : (current - 1 + matches.count) % matches.count
        } else {
            next = findForward ? 0 : matches.count - 1
        }
        let target = matches[next]
        findCurrentID = target
        if let stretchID = (doc.body ?? []).first(where: { $0.id == target })?.stretchID {
            openStretch.insert(stretchID)
        }
        // Horizontal and Focus turn to the match's page first.
        if readerMode == .horizontal || readerMode == .focus {
            if let page = horizontalPages.firstIndex(where: { page in
                page.contains { section in
                    section.heading?.id == target
                        || section.paragraphs.contains { $0.id == target }
                }
            }) {
                focusIndex = page
            }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(target, anchor: .center)
            }
        }
    }

    private var progressKey: String { "readingProgress.\(doc.id)" }

    /// The scroll offset, saved a moment after each move.
    private func noteProgress(_ offset: CGFloat) {
        progressSaveTask?.cancel()
        let key = progressKey
        progressSaveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            UserDefaults.standard.set(Double(max(offset, 0)), forKey: key)
        }
    }

    // MARK: - The foot's menus

    /// The contents — the document by its headings, each a click.
    private var contentsList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(sections) { section in
                    Button {
                        showContents = false
                        jump(to: section)
                    } label: {
                        Text(section.title)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                            .padding(.leading, CGFloat(max(section.level - 1, 0)) * 14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
        }
        .frame(width: 340, height: min(CGFloat(sections.count) * 30 + 40, 460))
    }


    /// The Aa menu — every way the type is set.
    @ViewBuilder private var typeMenu: some View {
        Section("Text Size") {
            Button("Bigger (⇧⌘+)") { stepFontSize(by: 1) }
            Button("Smaller (⇧⌘−)") { stepFontSize(by: -1) }
        }
        Section("Line Spacing") {
            Button("Looser (⌥⌘+)") { stepLineSpacing(by: 1) }
            Button("Tighter (⌥⌘−)") { stepLineSpacing(by: -1) }
        }
        Section("Measure") {
            if windowState.isFullScreen {
                Button("Wider") { stepFullScreenMeasure(by: 4) }
                Button("Narrower") { stepFullScreenMeasure(by: -4) }
            } else {
                Button("Wider") { windowedMeasure = min(windowedMeasure + 40, 1200) }
                Button("Narrower") { windowedMeasure = max(windowedMeasure - 40, 380) }
            }
        }
        Picker("Citations", selection: $citationsRaw) {
            ForEach(OrigamiCitationStyle.allCases) { style in
                Text(style.displayName).tag(style.rawValue)
            }
        }
        Picker("Marked Text", selection: $markedStyleRaw) {
            ForEach(MarkedTextStyle.allCases) { style in
                Text(style.displayName).tag(style.rawValue)
            }
        }
        Picker("Glossary", selection: $glossaryDisplayRaw) {
            ForEach(GlossaryDisplay.allCases) { display in
                Text(display.displayName).tag(display.rawValue)
            }
        }
        Picker("Colour Words By", selection: $coloringModeRaw) {
            ForEach(TextColoringMode.allCases) { mode in
                Text(mode.displayName).tag(mode.rawValue)
            }
        }
        Picker("Stretchtext", selection: $stretchDisplayRaw) {
            ForEach(StretchtextDisplay.allCases) { display in
                Text(display.displayName).tag(display.rawValue)
            }
        }
    }

    /// One section into view, whichever mode is reading.
    private func jump(to section: OrigamiSection) {
        if readerMode == .horizontal || readerMode == .focus {
            if let page = horizontalPages.firstIndex(where: { $0.contains(section) }) {
                focusIndex = page
            }
            return
        }
        // Folded or flowing: land on the section's first paragraph.
        if let target = section.heading?.id ?? section.paragraphs.first?.id {
            pendingScrollID = target
        }
    }

    private func stepFullScreenMeasure(by delta: Double) {
        if windowState.isBuiltInDisplay {
            fullScreenWidthInternal = min(max(fullScreenWidthInternal + delta, 25), 100)
        } else {
            fullScreenWidthExternal = min(max(fullScreenWidthExternal + delta, 25), 100)
        }
    }

    // MARK: - The styles

    /// The classic flow: everything in order, one measure — and the
    /// scroll remembered per document.
    private func articleView(_ annotations: [String: [ResolvedAnnotation]]) -> some View {
        ScrollView {
            ZStack(alignment: .topLeading) {
                // The page behind the paragraphs: a ctrl-click on no
                // paragraph offers "Note…" — the note then stands where
                // the click fell.
                MarginNoteSurface(box: surfaceBox) { point in
                    marginNoteTarget = MarginNoteTarget(point: point)
                }
                VStack(alignment: .leading, spacing: flowSpacing) {
                    header
                    Divider()
                    flow(doc.body ?? [], annotations: annotations)
                    referencesSection
                }
                .padding([.horizontal, .bottom], 32).padding(.top, 10)
                .frame(maxWidth: measure, alignment: .leading)
                .frame(maxWidth: .infinity)
                marginNotesLayer
            }
            .coordinateSpace(name: "origamiPage")
        }
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y
        } action: { _, offset in
            noteProgress(offset)
        }
    }

    /// The document folded to the current level: headings with their
    /// first sentences and Marked lines, or fewer — the same measure
    /// as the article. A click on any heading opens every section and
    /// the view stays on the heading clicked; a second click folds
    /// them again.
    private func foldedView(_ paragraphs: [LiquidDoc.Paragraph],
                            annotations: [String: [ResolvedAnnotation]]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: flowSpacing) {
                header
                Divider()
                ForEach(foldedSegments(paragraphs)) { segment in
                    switch segment {
                    case .heading(let paragraph):
                        Text(rendered(paragraph.text))
                            .font(paragraphFont(paragraph))
                            .foregroundStyle(themeHeading.map(AnyShapeStyle.init)
                                             ?? AnyShapeStyle(.primary))
                            .contentShape(Rectangle())
                            .contextMenu {
                                menuView(menuEntries(for: paragraph, highlights: []))
                            }
                            .onTapGesture { toggleFoldSection(paragraph.id) }
                            .help(expandedFold.isEmpty
                                  ? "Open all sections" : "Fold all sections")
                            .id(paragraph.id)
                        // The alternate fold targets — under each
                        // heading, the section's Defined Concepts, the
                        // people it names, or the works it cites, each
                        // a click to its card.
                        if expandedFold.isEmpty {
                            switch foldTarget {
                            case .headings:
                                EmptyView()
                            case .citations:
                                citationsLine(under: paragraph)
                            case .concepts, .names:
                                termsLine(under: paragraph)
                            }
                            // The reader's own layer stays visible in
                            // the overview: the section's highlights
                            // and comments, whatever the fold target.
                            annotationsLine(under: paragraph,
                                            annotations: annotations)
                        }
                    case .run(let run):
                        flow(run, annotations: annotations)
                    }
                }
                referencesSection
            }
            .padding([.horizontal, .bottom], 32).padding(.top, 10)
            .frame(maxWidth: measure, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    /// The find-fold's page: every heading and the full sentences
    /// carrying the found words, matches highlighted — and every line
    /// a click, leaving the fold and landing the full reading on that
    /// very place.
    private func findFoldView(_ paragraphs: [LiquidDoc.Paragraph],
                              annotations: [String: [ResolvedAnnotation]]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: flowSpacing) {
                header
                Divider()
                ForEach(paragraphs, id: \.id) { paragraph in
                    Text(inlineText(paragraph,
                                    highlights: annotations[paragraph.id] ?? []))
                        .font(paragraphFont(paragraph))
                        .foregroundStyle(paragraph.heading != nil
                            ? (themeHeading.map(AnyShapeStyle.init)
                               ?? AnyShapeStyle(.primary))
                            : AnyShapeStyle(.primary))
                        .contentShape(Rectangle())
                        .onTapGesture { jumpFromFindFold(to: paragraph.id) }
                        .help("Open the full reading at this place")
                        .id(paragraph.id)
                }
            }
            .padding([.horizontal, .bottom], 32).padding(.top, 10)
            .frame(maxWidth: measure, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    /// A find-fold line clicked: the fold leaves, the full reading
    /// stands, and the view lands on the clicked place — after the new
    /// layout is in, the fold toggles' own measure.
    private func jumpFromFindFold(to paragraphID: String) {
        withAnimation(.easeInOut(duration: 0.15)) {
            model.readerFindFoldTerm = nil
            model.readerFoldLevel = 0
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            pendingScrollID = paragraphID
            // The landing shows its matches; two seconds later the
            // orange fades and the reading stands at rest.
            try? await Task.sleep(for: .seconds(2))
            model.requestReaderFindClear()
        }
    }

    /// The section's annotations under its folded heading: each
    /// highlight's quoted words and each comment, a click opening the
    /// section on the very paragraph. The overview keeps the reader's
    /// layer in sight even while the body text is furled.
    @ViewBuilder
    private func annotationsLine(under heading: LiquidDoc.Paragraph,
                                 annotations: [String: [ResolvedAnnotation]]) -> some View {
        let entries = sectionAnnotations(under: heading, annotations: annotations)
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(entries) { entry in
                    Button {
                        expandedFold.insert(heading.id)
                        pendingScrollID = entry.resolution.paragraphID
                    } label: {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: ReaderAnnotationKind.kind(of: entry.annotation)?.systemImage
                                  ?? (entry.annotation.motivation
                                      == WebAnnotation.Motivation.commenting
                                      ? "text.bubble" : "highlighter"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.top, 3)
                            VStack(alignment: .leading, spacing: 1) {
                                if let quote = quotedWords(of: entry) {
                                    Text("“\(quote)”")
                                        .italic()
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                if let note = entry.annotation.body?.value,
                                   !note.isEmpty {
                                    Text(note)
                                        .lineLimit(2)
                                }
                            }
                        }
                        .font(.callout)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open the section on this annotation")
                }
            }
            .padding(.leading, 4)
        }
    }

    /// The annotations landing anywhere in the section under a heading.
    private func sectionAnnotations(under heading: LiquidDoc.Paragraph,
                                    annotations: [String: [ResolvedAnnotation]])
        -> [ResolvedAnnotation] {
        guard let section = sections.first(where: { $0.heading?.id == heading.id })
        else { return [] }
        return ([heading] + section.paragraphs).flatMap { annotations[$0.id] ?? [] }
    }

    /// The annotated words: what the anchor resolved, else what the
    /// annotation's own quote selector carries.
    private func quotedWords(of entry: ResolvedAnnotation) -> String? {
        if let exact = entry.resolution.exact { return exact }
        for selector in entry.annotation.target.selectors {
            if case .quote(let exact, _, _) = selector, !exact.isEmpty { return exact }
        }
        return nil
    }

    /// The terms a section mentions, as quiet clickable words under
    /// its folded heading — Author's fold-to-glossary and fold-to-names.
    @ViewBuilder
    private func termsLine(under heading: LiquidDoc.Paragraph) -> some View {
        let terms = sectionTerms(under: heading)
        if !terms.isEmpty {
            Text(termsAttributed(terms))
                .font(.callout)
                .padding(.leading, 4)
        }
    }

    /// The works a section cites, under its folded heading — Author's
    /// Citations outline: each cited work one line, title and author
    /// and date, a click opening its card.
    @ViewBuilder
    private func citationsLine(under heading: LiquidDoc.Paragraph) -> some View {
        if let lines = sectionCitationLines(under: heading) {
            Text(lines)
                .font(.callout)
                .padding(.leading, 4)
        }
    }

    private func sectionCitationLines(under heading: LiquidDoc.Paragraph) -> AttributedString? {
        guard let section = sections.first(where: { $0.heading?.id == heading.id })
        else { return nil }
        var seen = Set<String>()
        var out = AttributedString()
        var empty = true
        for paragraph in section.paragraphs {
            for key in citationKeys(in: paragraph.text) where seen.insert(key).inserted {
                guard let line = citationLine(forKey: key) else { continue }
                if !empty { out += AttributedString("\n") }
                out += line
                empty = false
            }
        }
        return empty ? nil : out
    }

    /// The `[cite:key]` tokens a paragraph carries, in order.
    private func citationKeys(in text: String) -> [String] {
        guard text.contains("[cite:"),
              let regex = try? NSRegularExpression(pattern: #"\[cite:([^\]]+)\]"#)
        else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) }
    }

    /// One cited work as a quiet clickable line: "Title — Author, Year",
    /// linked to its citation card.
    private func citationLine(forKey key: String) -> AttributedString? {
        guard let reference = doc.references.first(where: { $0.id == key })
        else { return nil }
        let record = BibTeXRecord.records(in: reference.bibtex).first
        var parts: [String] = []
        if let title = record?.title, !title.isEmpty { parts.append(title) }
        let credit = [record?.displayAuthors ?? "", record?.year ?? ""]
            .filter { !$0.isEmpty }.joined(separator: ", ")
        if !credit.isEmpty { parts.append(credit) }
        if parts.isEmpty {
            parts.append(reference.citedAs ?? key)
        }
        var line = AttributedString(parts.joined(separator: " \u{2014} "))
        line.foregroundColor = themeDimmed
        let escaped = key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? key
        line.link = URL(string: OrigamiReading.citationScheme + ":" + escaped)
        return line
    }

    private func sectionTerms(under heading: LiquidDoc.Paragraph) -> [LiquidDoc.Concept] {
        guard let section = sections.first(where: { $0.heading?.id == heading.id })
        else { return [] }
        var seen = Set<String>()
        var terms: [LiquidDoc.Concept] = []
        for paragraph in section.paragraphs {
            for concept in OrigamiReading.concepts(in: paragraph, of: doc) {
                let isPerson = concept.tag?.caseInsensitiveCompare("person") == .orderedSame
                guard foldTarget == .names ? isPerson : !isPerson else { continue }
                if seen.insert(concept.id).inserted { terms.append(concept) }
            }
        }
        return terms
    }

    private func termsAttributed(_ terms: [LiquidDoc.Concept]) -> AttributedString {
        var out = AttributedString()
        for (index, concept) in terms.enumerated() {
            if index > 0 {
                var dot = AttributedString("  \u{00B7}  ")
                dot.foregroundColor = themeDimmed
                out += dot
            }
            var term = AttributedString(concept.name)
            term.foregroundColor = themeDimmed
            term.link = URL(string: "origami-conceptcard:" + concept.id)
            out += term
        }
        return out
    }

    /// The folded list split for rendering: each heading stands alone
    /// (clickable), the paragraphs between flow with their stretch
    /// blocks intact.
    private enum FoldedSegment: Identifiable {
        case heading(LiquidDoc.Paragraph)
        case run([LiquidDoc.Paragraph])

        var id: String {
            switch self {
            case .heading(let paragraph): paragraph.id
            case .run(let run): "run-" + (run.first?.id ?? "empty")
            }
        }
    }

    private func foldedSegments(_ paragraphs: [LiquidDoc.Paragraph]) -> [FoldedSegment] {
        var segments: [FoldedSegment] = []
        var run: [LiquidDoc.Paragraph] = []
        for paragraph in paragraphs {
            if paragraph.heading != nil {
                if !run.isEmpty { segments.append(.run(run)); run = [] }
                segments.append(.heading(paragraph))
            } else {
                run.append(paragraph)
            }
        }
        if !run.isEmpty { segments.append(.run(run)) }
        return segments
    }

    /// A click on any folded heading opens every section — the whole
    /// document unfolds in place; a second click folds them all again.
    private func toggleFoldSection(_ headingID: String) {
        withAnimation(.easeInOut(duration: 0.15)) {
            if expandedFold.isEmpty {
                expandedFold = Set((doc.body ?? []).compactMap {
                    $0.heading != nil ? $0.id : nil
                })
            } else {
                expandedFold = []
            }
        }
        // Land after the new layout is in.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            pendingScrollID = headingID
        }
    }

    /// One fold step in either direction, clamped to the document's
    /// ladder — 0 is fully open. Stepping resets the opened sections.
    private func fold(by delta: Int) {
        withAnimation(.easeInOut(duration: 0.15)) {
            foldLevel = min(max(foldLevel + delta, 0), OrigamiReading.maxFoldLevel(of: doc))
            expandedFold = []
        }
    }

    /// A paragraph run with its stretch blocks folded. The `»` toggle
    /// rides inline at the end of the paragraph the stretch follows,
    /// and the opened detail reads as a callout or inline.
    @ViewBuilder
    private func flow(_ paragraphs: [LiquidDoc.Paragraph],
                      annotations: [String: [ResolvedAnnotation]]) -> some View {
        let items = OrigamiFlowItem.build(paragraphs)
        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
            switch item {
            case .paragraph(let paragraph):
                let trailing: (id: String, run: [LiquidDoc.Paragraph])? = {
                    guard isPlainText(paragraph), index + 1 < items.count,
                          case .stretch(let id, let run) = items[index + 1]
                    else { return nil }
                    return (id, run)
                }()
                paragraphView(paragraph, annotations: annotations[paragraph.id] ?? [],
                              trailingStretch: trailing)
                    .id(paragraph.id)   // the contents and fragments land here
            case .stretch(let id, let run):
                let hosted: Bool = {
                    guard index > 0, case .paragraph(let host) = items[index - 1]
                    else { return false }
                    return isPlainText(host)
                }()
                stretchBlock(id: id, run: run, annotations: annotations, hosted: hosted)
            }
        }
    }

    /// Whether a paragraph is running text — something an inline
    /// stretch toggle can end. Images, tables, and rules are not.
    private func isPlainText(_ paragraph: LiquidDoc.Paragraph) -> Bool {
        paragraph.tableID == nil && paragraph.text != "---"
            && LiquidDoc.imageReference(in: paragraph.text) == nil
    }

    /// One stretchtext block's detail. Its toggle lives inline in the
    /// host paragraph; only a stretch with no text before it (rare)
    /// gets a toggle of its own here.
    @ViewBuilder
    private func stretchBlock(id: String, run: [LiquidDoc.Paragraph],
                              annotations: [String: [ResolvedAnnotation]],
                              hosted: Bool) -> some View {
        let isOpen = openStretch.contains(id)
        if !hosted {
            Button {
                toggleStretch(id)
            } label: {
                Text(isOpen ? "\u{2039}" : "\u{00BB}")
                    .font(.callout.bold())
                    .foregroundStyle(themeText.map(AnyShapeStyle.init) ?? AnyShapeStyle(.primary))
            }
            .buttonStyle(.plain)
            .help(isOpen ? "Close the stretchtext" : "Open the stretchtext")
        }
        // Inline display continues in the host paragraph itself, no
        // break — the block below only renders for callout (or for a
        // hostless stretch, which has no line to continue).
        if isOpen, !(hosted && stretchDisplay == .inline) {
            let content = VStack(alignment: .leading, spacing: 14) {
                ForEach(run) { paragraph in
                    paragraphView(paragraph, annotations: annotations[paragraph.id] ?? [],
                                  closeStretch: (id, paragraph.id == run.last?.id))
                }
            }
            switch stretchDisplay {
            case .callout:
                content
                    .padding(.leading, 14)
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(.tertiary)
                            .frame(width: 3)
                    }
            case .inline:
                content
            }
        }
    }

    private func toggleStretch(_ id: String) {
        withAnimation(.easeInOut(duration: 0.15)) {
            if openStretch.contains(id) {
                openStretch.remove(id)
            } else {
                openStretch.insert(id)
            }
        }
    }

    /// The document by its structure: sections fold under their headings.
    private func outlineView(_ annotations: [String: [ResolvedAnnotation]]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                Divider()
                ForEach(sections) { section in
                    if let heading = section.heading {
                        DisclosureGroup(isExpanded: expansion(of: section)) {
                            VStack(alignment: .leading, spacing: 14) {
                                flow(section.paragraphs, annotations: annotations)
                            }
                            .padding(.top, 8)
                        } label: {
                            Text(rendered(heading.text))
                                .font(headingFont(level: section.level))
                                .foregroundStyle(themeHeading.map(AnyShapeStyle.init)
                                                 ?? AnyShapeStyle(.primary))
                                .greyedOut(selectionMode != nil) { selectionMode = nil }
                                .dimmedForStretch(stretchFocus)
                        }
                        .id(heading.id)
                    } else {
                        flow(section.paragraphs, annotations: annotations)
                    }
                }
                referencesSection
            }
            .padding([.horizontal, .bottom], 32).padding(.top, 10)
            .frame(maxWidth: measure, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    /// Horizontal — the document as pages side by side: a spread of two
    /// at least, a page more for every 460 points the window offers.
    private func horizontalView(_ annotations: [String: [ResolvedAnnotation]]) -> some View {
        let pages = horizontalPages
        let shown = horizontalPageCount(width: horizontalViewWidth,
                                        sections: pages.count)
        let index = min(max(focusIndex, 0), max(pages.count - 1, 0))
        return VStack(spacing: 0) {
            if pages.isEmpty {
                ContentUnavailableView("Nothing to Read", systemImage: "doc.text",
                                       description: Text("This document has no body."))
            } else {
                HStack(spacing: 0) {
                    ForEach(0..<shown, id: \.self) { offset in
                        Group {
                            if index + offset < pages.count {
                                focusColumn(pages[index + offset],
                                            annotations: annotations,
                                            closesBook: index + offset == pages.count - 1)
                            } else {
                                Color.clear.frame(maxWidth: .infinity)
                            }
                        }
                        if offset < shown - 1 { Divider() }
                    }
                }
                Divider()
                HStack {
                    Button {
                        turnPages(by: -shown)
                    } label: {
                        Label("Previous", systemImage: "chevron.left")
                    }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .disabled(index == 0)

                    Spacer()
                    Text(pageLabel(pages: pages, index: index, shown: shown))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()

                    Button {
                        turnPages(by: shown)
                    } label: {
                        Label("Next", systemImage: "chevron.right")
                    }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .disabled(index + shown >= pages.count)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            }
        }
        // The page count follows the reading area's width.
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            horizontalViewWidth = width
        }
    }

    /// Focus — one section alone on the page, to help the reading
    /// settle. Previous/Next (and the arrow keys) move a section at a
    /// time; the section scrolls within itself.
    private func focusView(_ annotations: [String: [ResolvedAnnotation]]) -> some View {
        let pages = horizontalPages
        let index = min(max(focusIndex, 0), max(pages.count - 1, 0))
        return VStack(spacing: 0) {
            if pages.isEmpty {
                ContentUnavailableView("Nothing to Read", systemImage: "doc.text",
                                       description: Text("This document has no body."))
            } else {
                focusColumn(pages[index], annotations: annotations,
                            closesBook: index == pages.count - 1)
                Divider()
                HStack {
                    Button {
                        turnPages(by: -1)
                    } label: {
                        Label("Previous", systemImage: "chevron.left")
                    }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .disabled(index == 0)

                    Spacer()
                    Text(pageLabel(pages: pages, index: index, shown: 1))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()

                    Button {
                        turnPages(by: 1)
                    } label: {
                        Label("Next", systemImage: "chevron.right")
                    }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .disabled(index >= pages.count - 1)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            }
        }
    }

    /// The Horizontal pages — one section each, except that a heading
    /// with no body of its own never breaks to a page alone: it rides
    /// atop the section that follows.
    private var horizontalPages: [[OrigamiSection]] {
        var pages: [[OrigamiSection]] = []
        var pending: [OrigamiSection] = []
        for section in sections {
            if hasBody(section) {
                pages.append(pending + [section])
                pending = []
            } else {
                pending.append(section)
            }
        }
        if !pending.isEmpty {
            // Bare headings at the very end stay with the last page.
            if pages.isEmpty {
                pages.append(pending)
            } else {
                pages[pages.count - 1] += pending
            }
        }
        return pages
    }

    /// A section with something of its own to read — words, a figure,
    /// a table.
    private func hasBody(_ section: OrigamiSection) -> Bool {
        section.paragraphs.contains { paragraph in
            paragraph.tableID != nil
                || LiquidDoc.imageReference(in: paragraph.text) != nil
                || !paragraph.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Pages across the width: two at least, a page more for every 460
    /// points, never more pages than sections.
    private func horizontalPageCount(width: CGFloat, sections: Int) -> Int {
        guard sections > 0 else { return 1 }
        guard width > 0 else { return min(2, sections) }
        return min(max(Int(width / 460), 2), sections)
    }

    /// One whole spread forward or back, clamped to the document.
    private func turnPages(by delta: Int) {
        let count = horizontalPages.count
        guard count > 0 else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            focusIndex = min(max(focusIndex + delta, 0), count - 1)
        }
    }

    /// "Introduction — 3–5 of 12": the spread's place in the whole.
    private func pageLabel(pages: [[OrigamiSection]], index: Int, shown: Int) -> String {
        let count = pages.count
        let last = min(index + shown, count)
        let title = pages[index].first(where: hasBody)?.title
            ?? pages[index].first?.title ?? ""
        if last - index <= 1 {
            return "\(title) — \(index + 1) of \(count)"
        }
        return "\(title) — \(index + 1)–\(last) of \(count)"
    }

    /// One Horizontal page: its section — with any bodyless headings
    /// that ride above it, stacked without a break.
    private func focusColumn(_ page: [OrigamiSection],
                             annotations: [String: [ResolvedAnnotation]],
                             closesBook: Bool = false) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(page) { section in
                    if let heading = section.heading {
                        Text(rendered(heading.text))
                            .font(headingFont(level: section.level))
                            .foregroundStyle(themeHeading.map(AnyShapeStyle.init)
                                             ?? AnyShapeStyle(.primary))
                            .greyedOut(selectionMode != nil) { selectionMode = nil }
                            .dimmedForStretch(stretchFocus)
                            .id(heading.id)
                    }
                    flow(section.paragraphs, annotations: annotations)
                }
                if closesBook {
                    referencesSection
                }
            }
            .padding(40)
            .frame(maxWidth: windowState.isFullScreen ? measure : 560,
                   alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    /// Speaker-labelled turns; a document without speakers reads as flow.
    private func transcriptView(_ annotations: [String: [ResolvedAnnotation]]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                Divider()
                ForEach(turns) { turn in
                    VStack(alignment: .leading, spacing: 8) {
                        if let speaker = turn.speaker {
                            Text(speaker)
                                .font(.headline)
                                .foregroundStyle(.tint)
                        }
                        flow(turn.paragraphs, annotations: annotations)
                    }
                    .padding(.leading, turn.speaker == nil ? 0 : 12)
                    .overlay(alignment: .leading) {
                        if turn.speaker != nil {
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(.tertiary)
                                .frame(width: 3)
                        }
                    }
                }
                referencesSection
            }
            .padding([.horizontal, .bottom], 32).padding(.top, 10)
            .frame(maxWidth: measure, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    /// Consecutive paragraphs by the same speaker, one turn.
    private struct Turn: Identifiable {
        let speaker: String?
        let paragraphs: [LiquidDoc.Paragraph]
        var id: String { paragraphs.first?.id ?? "turn" }
    }

    private var turns: [Turn] {
        var turns: [Turn] = []
        var speaker: String?
        var run: [LiquidDoc.Paragraph] = []
        for paragraph in doc.body ?? [] {
            if paragraph.speaker != speaker, !run.isEmpty {
                turns.append(Turn(speaker: speaker, paragraphs: run))
                run = []
            }
            speaker = paragraph.speaker
            run.append(paragraph)
        }
        if !run.isEmpty { turns.append(Turn(speaker: speaker, paragraphs: run)) }
        return turns
    }

    // MARK: - Header and shared pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            // A book opens on its cover, when the EPUB carried one.
            if let cover = coverImage {
                Image(nsImage: cover)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 420)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .shadow(radius: 3, y: 1)
                    .padding(.bottom, 12)
            }
            Text(doc.title)
                .font(Font.custom(headingFontName,
                                  size: max(NSFont.preferredFont(forTextStyle: .largeTitle).pointSize
                                            + fontDelta - 1, 8)))
                .foregroundStyle(themeHeading.map(AnyShapeStyle.init) ?? AnyShapeStyle(.primary))
            Text("\(doc.displayAuthor) \u{00B7} \(doc.listedDateText)")
                .font(.headline)
                .foregroundStyle(themeDimmed.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
            HStack(spacing: 12) {
                documentAnnotationPill
                if sections.count > 1 {
                    Label("\(sections.count) sections", systemImage: "list.bullet.indent")
                }
                if !doc.references.isEmpty {
                    Label("\(doc.references.count) references",
                          systemImage: "list.bullet.rectangle")
                }
                if !doc.concepts.isEmpty {
                    Label("\(doc.concepts.count) concepts", systemImage: "lightbulb")
                }
            }
            .font(.caption)
            .foregroundStyle(themeDimmed.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
        }
        .greyedOut(selectionMode != nil) { selectionMode = nil }
        .dimmedForStretch(stretchFocus)
    }

    /// The pill opening the whole-document annotation: an outlined
    /// "Annotate" while none is written, a filled "Annotation" once
    /// one is — the line the book lists show under the author's name.
    private var documentAnnotationPill: some View {
        let written = model.documentAnnotation(forAddress: doc.id)?.body?.value ?? ""
        return Button {
            showsDocumentAnnotation = true
        } label: {
            Text(written.isEmpty ? "Annotate" : "Annotation")
                .font(.caption)
                .padding(.horizontal, 9)
                .padding(.vertical, 2)
                .foregroundStyle(written.isEmpty
                                 ? AnyShapeStyle(.secondary)
                                 : AnyShapeStyle(Color.white))
                .background(Capsule().fill(written.isEmpty ? Color.clear : Color.accentColor))
                .overlay {
                    if written.isEmpty {
                        Capsule().strokeBorder(.secondary.opacity(0.6))
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(written.isEmpty
              ? "Annotate the document as a whole"
              : "“\(written)” — click to edit")
        .sheet(isPresented: $showsDocumentAnnotation) {
            DocumentAnnotationComposer(title: doc.title, text: written) { text in
                model.setDocumentAnnotation(text, forAddress: doc.id)
            } onLift: { draft in
                // The draft moves to a window of its own; the address
                // pins it to this document wherever the reader goes.
                openWindow(value: LiftedAnnotation(address: doc.id,
                                                   title: doc.title,
                                                   draft: draft))
            }
        }
    }

    /// The reference list closing the reading, numbered as the body's
    /// citations count them — the end-of-paper review the reader is
    /// owed, in every style. (The Faithful view prints the page's own
    /// References section.)
    @ViewBuilder private var referencesSection: some View {
        if !doc.references.isEmpty {
            Divider()
                .padding(.top, 12)
            Text("References")
                .font(headingFont(level: 1))
                .foregroundStyle(themeHeading.map(AnyShapeStyle.init) ?? AnyShapeStyle(.primary))
                .id("references")
            let rowFont = Font.custom(
                bodyFontName,
                size: max(NSFont.preferredFont(forTextStyle: .body).pointSize + fontDelta - 2, 8))
            ForEach(Array(OrigamiReading.readableReferences(of: doc).enumerated()),
                    id: \.element.id) { index, reference in
                Text("[\(index + 1)] \(reference.text)")
                    .font(rowFont)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// The EPUB's cover, when the import carried one — an asset whose
    /// id, file name, or alt says "cover".
    private var coverImage: NSImage? {
        let asset = doc.assets.first { asset in
            asset.id.localizedCaseInsensitiveContains("cover")
                || asset.filename.localizedCaseInsensitiveContains("cover")
                || asset.alt?.localizedCaseInsensitiveContains("cover") == true
        }
        return asset?.data.flatMap(NSImage.init(data:))
    }

    private func headingFont(level: Int) -> Font {
        Font.custom(headingFontName, size: headingPointSize(level: level))
    }

    private func expansion(of section: OrigamiSection) -> Binding<Bool> {
        Binding(get: { !collapsed.contains(section.id) },
                set: { open in
                    if open { collapsed.remove(section.id) }
                    else { collapsed.insert(section.id) }
                })
    }

    /// What the reader has done to the view right now — the style, the
    /// outline sections folded closed, the stretchtext opened, the
    /// focused section. Copied citations carry this.
    private var viewState: OrigamiViewState {
        var focusSectionID: String?
        let pages = horizontalPages
        if readerMode == .horizontal || readerMode == .focus, !pages.isEmpty {
            let index = min(max(focusIndex, 0), pages.count - 1)
            focusSectionID = pages[index].first?.heading?.id
        }
        let style: OrigamiReadingStyle = switch readerMode {
        case .outline: .outline
        case .transcript: .transcript
        case .horizontal, .focus: .focus
        case .faithful, .scroll: .article
        }
        return OrigamiViewState(
            style: style,
            closedSections: readerMode == .outline ? collapsed.sorted() : [],
            openStretch: openStretch.sorted(),
            focusSectionID: focusSectionID)
    }

    /// Every annotation on the document, re-anchored through the selector
    /// ladder and grouped by the paragraph it lands on.
    private var resolvedByParagraph: [String: [ResolvedAnnotation]] {
        // The model resolves (and caches) the whole sidecar — fuzzy
        // re-anchoring included; orphans simply land nowhere here and
        // wait, marked, in the Annotations shelf.
        var map: [String: [ResolvedAnnotation]] = [:]
        for entry in model.resolvedAnnotations(for: doc) {
            guard let resolution = entry.resolution else { continue }
            map[resolution.paragraphID, default: []]
                .append(ResolvedAnnotation(annotation: entry.annotation,
                                           resolution: resolution))
        }
        return map
    }

    // MARK: - One paragraph

    /// One body element: a heading, a rule, an image from the asset pool, a
    /// table's live grid, or a text paragraph with its inline markdown
    /// rendered, highlights painted, comments beneath — and the reader's
    /// chosen context menu.
    @ViewBuilder
    private func paragraphView(_ paragraph: LiquidDoc.Paragraph,
                               annotations: [ResolvedAnnotation],
                               trailingStretch: (id: String, run: [LiquidDoc.Paragraph])? = nil,
                               closeStretch: (id: String, isLast: Bool)? = nil)
        -> some View {
        if let mode = selectionMode, mode.paragraphID == paragraph.id {
            SelectionModeView(mode: mode, font: paragraphFont(paragraph)) {
                selectionMode = nil
            }
        } else {
            standardParagraphView(paragraph, annotations: annotations,
                                  trailingStretch: trailingStretch,
                                  closeStretch: closeStretch)
                .greyedOut(selectionMode != nil) { selectionMode = nil }
        }
    }

    @ViewBuilder
    private func standardParagraphView(_ paragraph: LiquidDoc.Paragraph,
                                       annotations: [ResolvedAnnotation],
                                       trailingStretch: (id: String, run: [LiquidDoc.Paragraph])? = nil,
                                       closeStretch: (id: String, isLast: Bool)? = nil)
        -> some View {
        let inlineOpenHost = trailingStretch.map {
            openStretch.contains($0.id) && stretchDisplay == .inline
        } ?? false
        let dim = stretchFocus && closeStretch == nil && !inlineOpenHost
        if let modelRef = LiquidDoc.modelReference(in: paragraph.text) {
            // An embedded 3D model (the EPUB <model> element): an
            // interactive orbit stage, the poster standing in when
            // the model cannot show.
            OrigamiModelView(path: modelRef.path, alt: modelRef.alt,
                             posterID: modelRef.posterID, doc: doc)
                .dimmedForStretch(dim)
        } else if let image = LiquidDoc.imageReference(in: paragraph.text),
           let asset = doc.assets.first(where: { $0.id == image.id }) {
            // A citable figure (an Interatlas screenshot carrying its
            // View Citation in the PNG itself) answers a click with
            // the record and Open Source; a plain image just stands.
            OrigamiAssetView(
                asset: asset,
                fallback: OrigamiAssetView.imageCitation(after: paragraph, in: doc),
                doc: doc)
                .dimmedForStretch(dim)
        } else if let tableID = paragraph.tableID,
                  let table = doc.tables.first(where: { $0.identifier == tableID }) {
            // A live table from the document's pool — a clean grid,
            // its header ruled off — never the pipe-text stand-in.
            OrigamiTableView(table: table)
                .contextMenu {
                    menuView(menuEntries(for: paragraph, highlights: []))
                }
                .dimmedForStretch(dim)
        } else if paragraph.tableID != nil {
            // The pool lost this table: the paragraph's own pipe-text
            // stands in, plainly marked as such.
            Text(paragraph.text)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(themeText.map(AnyShapeStyle.init) ?? AnyShapeStyle(.primary))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                .contextMenu {
                    menuView(menuEntries(for: paragraph, highlights: []))
                }
                .dimmedForStretch(dim)
        } else if paragraph.text == "---" {
            Divider()
                .dimmedForStretch(dim)
        } else {
            annotatedParagraph(paragraph, annotations: annotations,
                               trailingStretch: trailingStretch,
                               closeStretch: closeStretch,
                               dimmed: dim)
        }
    }

    private func annotatedParagraph(_ paragraph: LiquidDoc.Paragraph,
                                    annotations: [ResolvedAnnotation],
                                    trailingStretch: (id: String, run: [LiquidDoc.Paragraph])? = nil,
                                    closeStretch: (id: String, isLast: Bool)? = nil,
                                    dimmed: Bool = false)
        -> some View {
        // Every annotation paints in the type itself — inlineText
        // colours the words (or the whole paragraph) in the kind's ink.
        // The paragraph reports where it stands on the page, so page
        // notes can anchor their placement to their nearest paragraph.
        return VStack(alignment: .leading, spacing: 8) {
            // An NSTextView-backed paragraph: text selects normally, but
            // right-click shows exactly the reading menu — none of the
            // items macOS adds to selectable SwiftUI text.
            SelectableParagraph(
                attributed: inlineText(paragraph, highlights: annotations,
                                       trailingStretch: trailingStretch,
                                       closeStretch: closeStretch),
                baseFont: nsFont(for: paragraph),
                lineSpacing: CGFloat(lineSpacing),
                inkColor: inkColor(for: paragraph),
                dimmed: dimmed,
                dimInk: themeDimmed.map(NSColor.init) ?? .secondaryLabelColor,
                entriesFor: { clicked, windowPoint in
                    menuEntries(for: paragraph, highlights: annotations,
                                clickedSentence: clicked,
                                clickWindowPoint: windowPoint)
                },
                selectionEntries: selectionEntries(for: paragraph),
                onLink: handleLink)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named("origamiPage"))
        } action: { frame in
            paragraphFrames[paragraph.id] = frame
        }
    }

    /// The reading context menu as data — exactly the verbs (and order)
    /// of the reader's chosen set, verbs with nothing to say here
    /// staying out.
    private func menuEntries(for paragraph: LiquidDoc.Paragraph,
                             highlights: [ResolvedAnnotation],
                             clickedSentence: String? = nil,
                             clickWindowPoint: NSPoint? = nil) -> [ParagraphMenuEntry] {
        var entries: [ParagraphMenuEntry] = []
        // What a no-selection annotation anchors to: the sentence under
        // the click, carried from the rendered words back to the
        // paragraph's own — never the whole paragraph.
        let anchor = anchorSentence(for: paragraph, rendered: clickedSentence)
        for action in enabledActions {
            switch action {
            case .copyText:
                entries.append(.action(title: "Copy Text", symbol: "doc.on.doc") {
                    copy(paragraph.text)
                })
            case .copyCitation:
                entries.append(.action(title: "Copy as Citation", symbol: "quote.opening") {
                    copyCitation(for: paragraph)
                })
            case .copyViewSpec:
                entries.append(.action(title: "Copy View Specification",
                                       symbol: "viewfinder.rectangular") {
                    copy(OrigamiReading.viewSpecification(
                        for: paragraph, in: doc, view: viewState,
                        generator: "Origami Text (macOS)").clipboardText())
                })
            case .highlight:
                // The Annotate vocabulary (after Reader's): judgments
                // stamped on the paragraph, kept in the sidecar.
                entries.append(.submenu(
                    title: "Highlight", symbol: "highlighter",
                    items: ReaderAnnotationKind.allCases.map { kind in
                        (AnnotationKindStyle.displayName(of: kind), kind.keyEquivalent, {
                            model.addTag(kind, to: doc, paragraphID: paragraph.id,
                                         exact: anchor)
                        })
                    }))
                if !highlights.isEmpty {
                    entries.append(.action(title: "Remove Annotations", symbol: "eraser") {
                        for entry in highlights {
                            model.removeAnnotation(entry.annotation, for: doc)
                        }
                    })
                }
            case .comment:
                entries.append(.action(title: "Note…", symbol: "square.and.pencil") {
                    // A Note is a free slip on the page — it touches no
                    // text. It stands where the click fell (a quiet
                    // corner when the spot cannot be told).
                    let point = clickWindowPoint.flatMap { windowPoint in
                        surfaceBox.surface.map { $0.convert(windowPoint, from: nil) }
                    } ?? CGPoint(x: 120, y: 120)
                    marginNoteTarget = MarginNoteTarget(point: point)
                })
                // A written note without its own words to click (it
                // covers the whole paragraph) opens from the menu.
                for entry in highlights
                where entry.annotation.motivation == WebAnnotation.Motivation.commenting
                    && entry.resolution.exact == nil {
                    entries.append(.action(title: "Open Note…",
                                           symbol: "text.bubble") {
                        annotationEditor = AnnotationEditTarget(
                            annotation: entry.annotation,
                            paragraphID: paragraph.id)
                    })
                }
            case .concepts:
                let matched = OrigamiReading.concepts(in: paragraph, of: doc)
                if !matched.isEmpty {
                    entries.append(.submenu(title: "Concepts Here", symbol: "lightbulb",
                                            items: matched.map { concept in
                                                (concept.name, "", { conceptTarget = concept })
                                            }))
                }
            case .references:
                if !doc.references.isEmpty {
                    entries.append(.action(title: "Show References (\(doc.references.count))",
                                           symbol: "list.bullet.rectangle") {
                        showReferences = true
                    })
                }
            case .provenance:
                if let provenance = paragraph.provenance, !provenance.isEmpty {
                    entries.append(.action(title: "Copy Provenance", symbol: "signature") {
                        copy(provenance)
                    })
                }
            }
        }
        return entries
    }

    /// The entries as SwiftUI menu items, for the table fallback's
    /// contextMenu.
    @ViewBuilder
    private func menuView(_ entries: [ParagraphMenuEntry]) -> some View {
        ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
            switch entry {
            case .action(let title, let symbol, let run):
                Button(title, systemImage: symbol, action: run)
            case .submenu(let title, let symbol, let items):
                Menu(title, systemImage: symbol) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        Button(item.0, action: item.2)
                    }
                }
            case .separator:
                Divider()
            }
        }
    }

    /// The verbs offered over a live selection: cite or highlight
    /// exactly these words, the Flow view, and the AI submenu with the
    /// reader's prompts.
    private func selectionEntries(for paragraph: LiquidDoc.Paragraph)
        -> (String, NSRange) -> [ParagraphMenuEntry] {
        { fullText, range in
            guard range.length > 0,
                  let swiftRange = Range(range, in: fullText) else { return [] }
            let prefix = String(fullText[..<swiftRange.lowerBound])
            let selected = String(fullText[swiftRange])
            let suffix = String(fullText[swiftRange.upperBound...])
            guard !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return [] }

            var entries: [ParagraphMenuEntry] = [.separator]
            entries.append(.action(title: "Copy to Cite", symbol: "quote.opening") {
                copyCitation(for: paragraph, quote: selected)
            })
            entries.append(.submenu(
                title: "Highlight", symbol: "highlighter",
                items: ReaderAnnotationKind.allCases.map { kind in
                    (AnnotationKindStyle.displayName(of: kind), kind.keyEquivalent, {
                        model.addTag(kind, to: doc, paragraphID: paragraph.id,
                                     exact: selected)
                    })
                }))
            entries.append(.action(title: "Flow", symbol: "text.line.first.and.arrowtriangle.forward") {
                selectionMode = SelectionViewMode(
                    paragraphID: paragraph.id, prefix: prefix,
                    selected: selected, suffix: suffix, display: .flow)
            })
            let presets = AIPromptPreset.decodeList(aiPromptsRaw)
            if !presets.isEmpty {
                entries.append(.submenu(
                    title: "AI", symbol: "sparkles",
                    items: presets.map { preset in
                        (preset.name, "", {
                            runAI(preset, paragraphID: paragraph.id,
                                  prefix: prefix, selected: selected, suffix: suffix)
                        })
                    }))
            }
            return entries
        }
    }

    /// Runs one AI preset over the selection on the device's model,
    /// the mode showing its progress and then the rewrite in place.
    private func runAI(_ preset: AIPromptPreset, paragraphID: String,
                       prefix: String, selected: String, suffix: String) {
        selectionMode = SelectionViewMode(
            paragraphID: paragraphID, prefix: prefix,
            selected: selected, suffix: suffix,
            display: .aiLoading(preset.name))
        Task {
            do {
                let rewritten = try await ReadingAI.rewrite(selected, with: preset)
                if selectionMode?.paragraphID == paragraphID {
                    selectionMode?.display = .aiResult(rewritten)
                }
            } catch {
                if selectionMode?.paragraphID == paragraphID {
                    selectionMode?.display = .aiFailed(error.localizedDescription)
                }
            }
        }
    }

    /// A link clicked inside a paragraph: the `»` stretch toggle opens
    /// and closes its detail, citations open their source card,
    /// everything else opens as links do.
    private func handleLink(_ url: URL) -> Bool {
        if url.scheme == "origami-stretch" {
            let id = String(url.absoluteString.dropFirst("origami-stretch:".count))
            toggleStretch(id)
            return true
        }
        if url.scheme == "origami-conceptcard" {
            let id = String(url.absoluteString.dropFirst("origami-conceptcard:".count))
            if let concept = doc.concepts.first(where: { $0.id == id }) {
                conceptTarget = concept
            }
            return true
        }
        if url.scheme == "origami-annotation" {
            let id = String(url.absoluteString.dropFirst("origami-annotation:".count))
            if let annotation = model.annotations(for: doc).first(where: { $0.id == id }) {
                let paragraphID = AnnotationAnchor.resolve(annotation, in: doc)?.paragraphID
                annotationEditor = AnnotationEditTarget(
                    annotation: annotation,
                    paragraphID: paragraphID ?? "")
            }
            return true
        }
        if let conceptID = OrigamiReading.glossaryConceptID(from: url) {
            withAnimation(.easeInOut(duration: 0.15)) {
                if openGlossary.contains(conceptID) {
                    openGlossary.remove(conceptID)
                } else {
                    openGlossary.insert(conceptID)
                }
            }
            return true
        }
        if let inlineID = OrigamiReading.inlineNoteID(from: url) {
            withAnimation(.easeInOut(duration: 0.15)) {
                if openInlineNotes.contains(inlineID) {
                    openInlineNotes.remove(inlineID)
                } else {
                    openInlineNotes.insert(inlineID)
                }
            }
            return true
        }
        if let noteID = OrigamiReading.noteID(from: url) {
            noteTarget = NoteTarget(noteID: noteID)
            return true
        }
        if let key = OrigamiReading.citationKey(from: url) {
            citationTarget = CitationTarget(key: key)
            return true
        }
        // A cross-document quote link opens in this library.
        if url.scheme?.lowercased() == "origamitext" {
            let link = EPUBReaderView.Coordinator.parseOrigamiURL(url.absoluteString)
            if !link.address.isEmpty {
                model.openEPUB(address: link.address, fragment: link.fragment)
                return true
            }
        }
        return NSWorkspace.shared.open(url)
    }

    /// The rank's point size — the platform's text style plus the
    /// reader's ⌘⇧+/⌘⇧− adjustment.
    private func fontSize(for paragraph: LiquidDoc.Paragraph) -> CGFloat {
        guard let level = paragraph.heading else {
            return max(NSFont.preferredFont(forTextStyle: .body).pointSize + fontDelta, 8)
        }
        return headingPointSize(level: level)
    }

    /// The heading ladder: level 1 at the title size as ever, each
    /// deeper level about an eighth smaller, never sinking to the
    /// body size — every rank visibly its own.
    private func headingPointSize(level: Int) -> CGFloat {
        let top = NSFont.preferredFont(forTextStyle: .title1).pointSize
        let body = NSFont.preferredFont(forTextStyle: .body).pointSize
        let stepped = top * pow(0.88, CGFloat(max(level, 1) - 1))
        return max(max(stepped, body + 1) + fontDelta - 1, 8)
    }

    /// The paragraph's font in the chosen families — headings in the
    /// heading font, everything else in the body font.
    private func nsFont(for paragraph: LiquidDoc.Paragraph) -> NSFont {
        let family = paragraph.heading != nil ? headingFontName : bodyFontName
        let size = fontSize(for: paragraph)
        return NSFont(name: family, size: size)
            ?? NSFont.preferredFont(forTextStyle: paragraph.heading != nil ? .title2 : .body)
    }

    private func paragraphFont(_ paragraph: LiquidDoc.Paragraph) -> Font {
        let family = paragraph.heading != nil ? headingFontName : bodyFontName
        return Font.custom(family, size: fontSize(for: paragraph))
    }

    /// The air between paragraphs.
    private var flowSpacing: CGFloat { 18 }

    /// One point in either direction, for every window at once,
    /// remembered until changed.
    private func stepFontSize(by delta: Double) {
        fontDelta = min(max(fontDelta + delta, -6), 18)
    }

    /// One point of line spacing in either direction, shared and kept.
    private func stepLineSpacing(by delta: Double) {
        lineSpacing = min(max(lineSpacing + delta, 0), 24)
    }

    /// The citation onto the clipboard in both dialects: pure BibTeX as
    /// the text — usable in Author, reference managers, and anywhere
    /// else — and Author's private payload beside it, so Author pastes
    /// it as a real citation. The entry's vm-id addresses the original
    /// document and paragraph.
    private func copyCitation(for paragraph: LiquidDoc.Paragraph,
                              quote: String? = nil) {
        let payload = OrigamiReading.authorCitationPayload(for: paragraph, in: doc,
                                                           quote: quote)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(payload.bibtex, forType: .string)
        let dictionary: [String: Any] = ["Content": payload.content,
                                         "BibTeX": payload.bibtex]
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: dictionary,
                                                        requiringSecureCoding: false) {
            pasteboard.setData(data, forType:
                NSPasteboard.PasteboardType("Liquid Author Citation pasteboard type"))
        }
    }

    /// A citation to this document with the reader's own note in its
    /// Annotation field — Copy in an annotation's editor, ready to
    /// paste into Author's citation dialog.
    private func copyAnnotationCitation(paragraphID: String, annotation text: String) {
        // A margin note has no paragraph of its own: the citation
        // stands on the document's opening element instead.
        guard let paragraph = (doc.body ?? []).first(where: { $0.id == paragraphID })
            ?? doc.body?.first
        else { return }
        let payload = OrigamiReading.authorCitationPayload(for: paragraph, in: doc,
                                                           annotation: text)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        // Pure BibTeX as the text — the annotation travels in its
        // Annotation field, ready for Author's citation dialog.
        pasteboard.setString(payload.bibtex, forType: .string)
        let dictionary: [String: Any] = ["Content": payload.content,
                                         "BibTeX": payload.bibtex,
                                         "Annotation": text]
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: dictionary,
                                                        requiringSecureCoding: false) {
            pasteboard.setData(data, forType:
                NSPasteboard.PasteboardType("Liquid Author Citation pasteboard type"))
        }
        model.showNote("Citation with your annotation copied — paste it in Author")
    }

    /// The paragraph's words as the view functions ask: expanded into
    /// meaning-paragraphs when the model has read it, then broken into
    /// flow lines. Headings stay as written.
    private func readingText(for paragraph: LiquidDoc.Paragraph) -> String {
        guard paragraph.heading == nil else { return paragraph.text }
        var text = paragraph.text
        if expandParagraphs, let split = paragraphSplits[paragraph.id] {
            text = split
        }
        if model.flowReading {
            text = text.components(separatedBy: "\n\n")
                .map {
                    OrigamiReading.flowText($0, breakOnComma: flowBreakOnComma,
                                            doubleBreakOnPeriod: flowDoubleBreakOnPeriod)
                }
                .joined(separator: "\n\n")
        }
        return text
    }

    /// Reads every long paragraph the model has not yet read, one at a
    /// time, caching where the meaning shifts — the view updates as
    /// each paragraph's breaks arrive.
    private func computeParagraphSplits() {
        guard ReadingAI.isAvailable else {
            flashNotice("The on-device model isn\u{2019}t available, so paragraphs stay as written.")
            expandParagraphs = false
            return
        }
        let candidates = (doc.body ?? []).filter { paragraph in
            paragraph.heading == nil && paragraph.tableID == nil
                && paragraph.text != "---"
                && LiquidDoc.imageReference(in: paragraph.text) == nil
                && paragraphSplits[paragraph.id] == nil
                && wantsParagraphBreaks(paragraph.text)
        }
        guard !candidates.isEmpty else { return }
        flashNotice("Reading for shifts in meaning\u{2026}")
        Task {
            for paragraph in candidates {
                guard expandParagraphs else { break }
                let segments = (try? await ReadingAI.paragraphBreaks(paragraph.text))
                    ?? [paragraph.text]
                paragraphSplits[paragraph.id] = segments.joined(separator: "\n\n")
            }
        }
    }

    /// Only long, multi-sentence paragraphs are worth the model's
    /// reading — the author's own short paragraphs stand as written.
    private func wantsParagraphBreaks(_ text: String) -> Bool {
        guard text.count > 350 else { return false }
        return OrigamiReading.flowLines(text, breakOnComma: false).count
            >= ReadingAI.minimumRun * 2
    }

    /// Asks the model for every substantial paragraph's key sentence,
    /// one paragraph at a time, caching each answer; the bolding lands
    /// as the answers arrive.
    private func computeKeySentences() {
        guard ReadingAI.isAvailable else {
            flashNotice("The on-device model isn\u{2019}t available, so nothing can be bolded.")
            boldKeySentences = false
            return
        }
        let candidates = (doc.body ?? []).filter { paragraph in
            paragraph.heading == nil && paragraph.tableID == nil
                && paragraph.text != "---"
                && LiquidDoc.imageReference(in: paragraph.text) == nil
                && keySentences[paragraph.id] == nil
                && wantsKeySentence(paragraph.text)
        }
        guard !candidates.isEmpty else { return }
        flashNotice("Reading for each paragraph\u{2019}s key sentence\u{2026}")
        Task {
            for paragraph in candidates {
                guard boldKeySentences else { break }
                let sentence = (try? await ReadingAI.keySentence(paragraph.text)) ?? nil
                keySentences[paragraph.id] = sentence ?? ""
            }
        }
    }

    /// Only a paragraph of several sentences has filler for its key
    /// sentence to stand out from — one or two stand as written.
    private func wantsKeySentence(_ text: String) -> Bool {
        OrigamiReading.flowLines(text, breakOnComma: false).count
            >= ReadingAI.minimumRun
    }

    /// One line at the bottom of the window, briefly.
    private func flashNotice(_ message: String) {
        Task {
            withAnimation(.easeInOut(duration: 0.2)) { keepNotice = message }
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation(.easeInOut(duration: 0.2)) { keepNotice = nil }
        }
    }

    /// The paragraph with its inline conventions rendered — citations in
    /// the reader's style, markdown, the ==marked== style — exact-word
    /// highlights painted in, and the `»` stretch toggle at its end
    /// when a stretch block follows.
    private func inlineText(_ paragraph: LiquidDoc.Paragraph,
                            highlights: [ResolvedAnnotation],
                            trailingStretch: (id: String, run: [LiquidDoc.Paragraph])? = nil,
                            closeStretch: (id: String, isLast: Bool)? = nil)
        -> AttributedString {
        var attributed = rendered(readingText(for: paragraph))
        // The b view function: the paragraph's key sentence — the
        // model's cached choice — stands bold.
        if boldKeySentences, paragraph.heading == nil,
           let sentence = keySentences[paragraph.id], !sentence.isEmpty {
            var needle = sentence
            if model.flowReading {
                needle = OrigamiReading.flowText(needle,
                                                 breakOnComma: flowBreakOnComma,
                                                 doubleBreakOnPeriod: false)
            }
            needle = String(rendered(needle).characters)
            let plain = String(attributed.characters)
            if let range = plain.range(of: needle),
               let attributedRange = Range(range, in: attributed) {
                let runs = attributed[attributedRange].runs
                    .map { ($0.range, $0.inlinePresentationIntent) }
                for (runRange, intent) in runs {
                    attributed[runRange].inlinePresentationIntent =
                        (intent ?? []).union(.stronglyEmphasized)
                }
            }
        }
        for entry in highlights {
            // The annotated words take their kind's colour in the type
            // itself (Settings ▸ Annotation) — never a background frame.
            // Strikethrough draws its line; a whole-paragraph annotation
            // colours the whole paragraph; a written note is a click
            // away on its words.
            // Only the annotated words themselves colour — an anchor
            // that degraded to paragraph scope paints nothing rather
            // than claim the whole paragraph.
            let plain = String(attributed.characters)
            guard let exact = entry.resolution.exact,
                  let range = plain.range(of: exact,
                                          options: [.caseInsensitive, .diacriticInsensitive]),
                  let attributedRange = Range(range, in: attributed) else { continue }
            let kind = ReaderAnnotationKind.kind(of: entry.annotation)
            let color = AnnotationKindStyle.color(of: kind ?? .highlight)
            if kind == .strikethrough {
                attributed[attributedRange].strikethroughStyle = .single
                attributed[attributedRange].strikethroughColor = NSColor(color)
            } else {
                attributed[attributedRange].foregroundColor = color
            }
            if entry.annotation.motivation == WebAnnotation.Motivation.commenting,
               let url = URL(string: "origami-annotation:" + entry.annotation.id) {
                attributed[attributedRange].link = url
            }
        }
        // The find bar's words read highlighted wherever they occur —
        // stronger in the paragraph the walk stands on.
        let findTerm = findText.trimmingCharacters(in: .whitespaces)
        if !findTerm.isEmpty {
            let plain = String(attributed.characters)
            var search = plain.startIndex..<plain.endIndex
            while let range = plain.range(of: findTerm,
                                          options: [.caseInsensitive, .diacriticInsensitive],
                                          range: search) {
                if let attributedRange = Range(range, in: attributed) {
                    attributed[attributedRange].backgroundColor =
                        Color.orange.opacity(paragraph.id == findCurrentID ? 0.5 : 0.22)
                }
                guard range.upperBound < plain.endIndex else { break }
                search = range.upperBound..<plain.endIndex
            }
        }
        // The glossary on its terms — the Tab overview when it is up,
        // otherwise brackets or daggers per the Aa menu.
        if glossaryOverviewOn {
            attributed = OrigamiReading.glossaryOverviewed(attributed, in: doc,
                                                           open: openGlossary)
        } else {
            attributed = OrigamiReading.glossaryAnnotated(attributed, in: doc,
                                                          display: glossaryDisplay,
                                                          open: openGlossary)
        }
        // Inline notes travelling as stretchtext: [] at the note's
        // mark; open, [ the note's words ] continue the sentence.
        attributed = OrigamiReading.inlineNotesResolved(
            attributed, in: doc, open: openInlineNotes,
            citations: citationStyle, markStyle: markedStyle,
            appearance: colorScheme)
        if let stretch = trailingStretch,
           let url = URL(string: OrigamiReading.stretchScheme + ":" + stretch.id) {
            let isOpen = openStretch.contains(stretch.id)
            let inlineOpen = isOpen && stretchDisplay == .inline
            // Stretch focus: the revealed words keep their ink; the
            // host's own words grey with the rest of the page.
            if inlineOpen {
                attributed.foregroundColor =
                    themeDimmed ?? Color(nsColor: .secondaryLabelColor)
            }
            // The stretch toggle, inline where Author writes it — at
            // the end of the paragraph the detail expands from. Open,
            // the frame reads ‹ revealed words ›, every part a click
            // to fold again.
            attributed += AttributedString(" ")
            var toggle = AttributedString(isOpen ? "\u{2039}" : "\u{00BB}")
            toggle.link = url
            attributed += toggle
            // Inline display: the opened detail continues in the same
            // paragraph, no line break.
            if inlineOpen {
                for (index, paragraph) in stretch.run.enumerated() {
                    attributed += AttributedString(" ")
                    attributed += OrigamiReading.stretchRevealed(
                        rendered(paragraph.text), id: stretch.id,
                        closing: index == stretch.run.count - 1)
                }
            }
        }
        // Revealed callout paragraphs close on a click anywhere in
        // them; the last one carries the frame's ›.
        if let closeStretch {
            attributed = OrigamiReading.stretchRevealed(
                attributed, id: closeStretch.id, closing: closeStretch.isLast)
        }
        // The colour-coded view, when the Aa menu has it on: words
        // painted by grammar or meaning, everything already coloured
        // or linked keeping its own.
        if coloringMode != .off {
            attributed = OrigamiReading.colorCoded(
                attributed, mode: coloringMode,
                rules: TextColorRule.decodeList(colorRulesRaw))
        }
        return attributed
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - The foot bar (shared with the faithful mode)

/// Author's foot, carried across: the mode words at the bottom of the
/// page — Faithful | Scroll | Horizontal | Focus | Outline | Transcript
/// — with the contents, the fold, and the type standing quietly at the
/// trailing edge. The EPUBReaderScreen shows the same bar over the
/// faithful WebView (without the reading-only controls), so the words
/// are always there to click.
struct ReadingFootBar: View {
    @Environment(AppModel.self) private var model
    @AppStorage("readerMode") private var readerModeRaw = EPUBReaderMode.faithful.rawValue
    @AppStorage("readingFoldTarget") private var foldTargetRaw =
        OrigamiReadingView.FoldTarget.headings.rawValue

    /// The modes the open book offers. Transcript joins only when the
    /// book explicitly is one (its paragraphs carry speakers); Outline
    /// never — the group beside Scroll folds the reading now.
    var modes: [EPUBReaderMode] = EPUBReaderMode.allCases.filter {
        $0 != .transcript && $0 != .outline
    }
    /// "Folded — level 2" while the reading is folded; nil otherwise.
    var foldLevelLabel: String? = nil
    /// Whether the book folds at all (its structured document reads).
    var outlineAvailable = true
    var contentsDisabled = false
    var showContents: Binding<Bool>? = nil
    /// The contents popover's content; nil hides the contents button.
    var contents: (() -> AnyView)? = nil
    /// The Aa menu's items; nil hides the Aa button.
    var typeMenu: (() -> AnyView)? = nil

    private var readerMode: EPUBReaderMode {
        EPUBReaderMode(rawValue: readerModeRaw) ?? .faithful
    }

    var body: some View {
        ZStack {
            // The trailing edge lies beneath the mode words: nothing —
            // the folded-state caption least of all — may shadow a tap
            // on the words or the Outline group.
            HStack(spacing: 14) {
                if let foldLevelLabel {
                    Text(foldLevelLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                }
                Spacer()
                if let contents, let showContents {
                    Button {
                        showContents.wrappedValue = true
                    } label: {
                        Image(systemName: "list.bullet")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(contentsDisabled)
                    .help("Contents — every section, one click away")
                    .popover(isPresented: showContents) { contents() }
                }
                if let typeMenu {
                    Menu {
                        typeMenu()
                    } label: {
                        Text("Aa")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .menuIndicator(.hidden)
                    .buttonStyle(.plain)
                    .fixedSize()
                    .help("The reading's type: size, spacing, measure, marks, glossary, colour")
                }
            }
            // The mode words render last — topmost — so every tap on
            // Default, Scroll, the Outline group's shapes, Horizontal,
            // or Focus lands on its word, never on the layer beneath.
            HStack(spacing: 14) {
                // The AI group stands left of Default: the on-device
                // model's readings of the open book, unfolding in place
                // like the Outline group.
                if model.openEPUB != nil {
                    aiGroup
                    separator
                }
                ForEach(Array(modes.enumerated()), id: \.element) { index, mode in
                    if index > 0 {
                        separator
                    }
                    modeWord(mode)
                    // The Outline group rides beside Scroll — the flow
                    // it folds. Closed, one quiet word; open, its three
                    // shapes bracketed in place, the active one bold.
                    if mode == .scroll, outlineAvailable {
                        separator
                        outlineGroup
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(alignment: .top) { Divider() }
    }

    private var separator: some View {
        Rectangle()
            .fill(.quaternary)
            .frame(width: 1, height: 14)
    }

    /// One mode word at the foot, Author's way: the chosen one in the
    /// heading ink, the others resting quiet.
    private func modeWord(_ mode: EPUBReaderMode) -> some View {
        Button {
            withAnimation(.snappy) {
                readerModeRaw = mode.rawValue
                // A mode word always shows its own view: any standing
                // fold (the Outline group's shapes), find-fold, or AI
                // reading steps aside first, otherwise it keeps the
                // screen and the word appears to do nothing.
                model.readerFoldLevel = 0
                model.readingAnalysisKind = nil
                model.readerFindFoldTerm = nil
            }
        } label: {
            Text(mode.displayName)
                .font(.callout.weight(readerMode == mode ? .semibold : .regular))
                .foregroundStyle(readerMode == mode ? AnyShapeStyle(.primary)
                                 : AnyShapeStyle(.secondary))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(mode.help)
    }

    // MARK: The AI group — the model's readings, unfolding in place

    @State private var aiExpanded = false

    /// A standing analysis keeps the group unfolded, whatever the
    /// local expansion state says.
    private var aiShowsExpanded: Bool {
        aiExpanded || model.readingAnalysisKind != nil
    }

    @ViewBuilder private var aiGroup: some View {
        if !aiShowsExpanded {
            Button {
                withAnimation(.snappy) {
                    aiExpanded = true
                    // AI opens onto the Summary; the other readings
                    // stand unfolded beside it.
                    model.readingAnalysisKind = .summary
                }
            } label: {
                Text("AI")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("This Mac's model reads the open book — the Summary opens, Proposals and Issues beside it")
        } else {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.snappy) {
                        aiExpanded = false
                        model.readingAnalysisKind = nil
                    }
                } label: {
                    Text("[")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Fold the AI group away — back to the reading")
                aiWord(.summary)
                separator
                aiWord(.proposals)
                separator
                aiWord(.issues)
                Text("]")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// One reading chosen: it takes the whole page — or, chosen again
    /// while standing, the page returns (the Outline group's toggles).
    private func aiWord(_ kind: ReadingAnalysisKind) -> some View {
        Button {
            withAnimation(.snappy) {
                model.readingAnalysisKind =
                    model.readingAnalysisKind == kind ? nil : kind
            }
        } label: {
            Text(kind.displayName)
                .font(.callout.weight(model.readingAnalysisKind == kind
                                      ? .semibold : .regular))
                .foregroundStyle(model.readingAnalysisKind == kind
                                 ? AnyShapeStyle(.primary)
                                 : AnyShapeStyle(.secondary))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(kind.help)
    }

    // MARK: The Outline group — Author's foot, unfolding in place

    private enum OutlineShape {
        case outline, overview, citations
    }

    /// Which shape the fold stands in, read from the shared fold level
    /// and target — ⌘− folding by hand still reads as Outline.
    private var outlineShape: OutlineShape? {
        guard model.readerFoldLevel > 0 else { return nil }
        switch OrigamiReadingView.FoldTarget(rawValue: foldTargetRaw) ?? .headings {
        case .citations: return .citations
        case .concepts, .names: return .overview
        case .headings: return model.readerFoldLevel == 1 ? .overview : .outline
        }
    }

    @ViewBuilder private var outlineGroup: some View {
        if outlineShape == nil {
            Button {
                choose(.outline)
            } label: {
                Text("Outline")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Fold the document into its outline — headings alone; Overview and Citations unfold beside it")
        } else {
            HStack(spacing: 8) {
                Text("[")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                shapeWord("Outline", .outline,
                          help: "Headings alone — the document's skeleton")
                separator
                shapeWord("Overview", .overview,
                          help: "Headings with each section's first sentence, Marked lines, and concepts")
                separator
                shapeWord("Citations", .citations,
                          help: "Headings with the works each section cites")
                Text("]")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func shapeWord(_ title: String, _ shape: OutlineShape, help: String) -> some View {
        Button {
            choose(shape)
        } label: {
            Text(title)
                .font(.callout.weight(outlineShape == shape ? .semibold : .regular))
                .foregroundStyle(outlineShape == shape ? AnyShapeStyle(.primary)
                                 : AnyShapeStyle(.secondary))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// One shape chosen: fold to it — or, chosen again while standing,
    /// unfold (Author's toggles). The fold lives on the native flow, so
    /// choosing from the book's own pages moves the reading to Scroll.
    private func choose(_ shape: OutlineShape) {
        withAnimation(.snappy) {
            // An Outline shape replaces any standing find-fold — and a
            // standing AI reading: the foot's words always answer with
            // their own view.
            model.readerFindFoldTerm = nil
            model.readingAnalysisKind = nil
            if outlineShape == shape {
                model.readerFoldLevel = 0
                return
            }
            // The fold lives on the native flow: whatever mode the
            // reading stood in, folding moves it to Scroll.
            if readerMode != .scroll {
                readerModeRaw = EPUBReaderMode.scroll.rawValue
            }
            switch shape {
            case .outline:
                foldTargetRaw = OrigamiReadingView.FoldTarget.headings.rawValue
                model.readerFoldLevel = 2
            case .overview:
                foldTargetRaw = OrigamiReadingView.FoldTarget.concepts.rawValue
                model.readerFoldLevel = 1
            case .citations:
                foldTargetRaw = OrigamiReadingView.FoldTarget.citations.rawValue
                model.readerFoldLevel = 2
            }
        }
    }
}

/// An annotation paired with where it landed in this document.
private struct ResolvedAnnotation: Identifiable {
    let annotation: WebAnnotation
    let resolution: AnnotationAnchor.Resolution
    var id: String { annotation.id }
}

/// One comment shown beneath its paragraph, with who and when.
/// One note standing on the page where it was written: its first
/// sentence at a third of the body size, on paper-white (light mode) or
/// ink-black (dark). A click opens the whole note; click-and-hold drags
/// it anywhere on the page, remembered on this Mac.
private struct MarginNoteView: View {
    @Environment(\.colorScheme) private var colorScheme
    let note: WebAnnotation
    let fontSize: CGFloat
    let position: CGPoint
    let onMove: (CGPoint) -> Void
    let onOpen: () -> Void

    @State private var drag: CGSize = .zero

    @State private var hovering = false

    /// The first sentence, "…" trailing when the note carries more.
    private var slipText: String {
        let whole = note.body?.value ?? ""
        let sentences = OrigamiReading.sentences(of: whole)
        guard let first = sentences.first?
            .trimmingCharacters(in: .whitespacesAndNewlines), !first.isEmpty
        else { return whole }
        return sentences.count > 1 ? first + " …" : first
    }

    private var paper: Color {
        colorScheme == .dark ? Color(white: 0.13) : .white
    }

    /// The slip's own type, as AppKit measures and SwiftUI draws it.
    private var slipFont: NSFont {
        let size = max(fontSize, 10)
        let descriptor = NSFont.systemFont(ofSize: size).fontDescriptor
            .withDesign(.serif)?
            .withSymbolicTraits(.italic)
        return descriptor.flatMap { NSFont(descriptor: $0, size: size) }
            ?? NSFont.systemFont(ofSize: size)
    }

    /// The text's own extent, wrapped at the slip's measure — the card
    /// is never wider (or taller) than the words ask.
    private var textSize: CGSize {
        let bounds = (slipText as NSString).boundingRect(
            with: NSSize(width: 170, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: slipFont])
        return CGSize(width: ceil(bounds.width), height: ceil(bounds.height))
    }

    var body: some View {
        Text(slipText)
            .font(Font(slipFont as CTFont))
            .foregroundStyle(colorScheme == .dark
                             ? Color(white: 0.85) : Color(white: 0.25))
            .multilineTextAlignment(.leading)
            .frame(width: textSize.width, height: textSize.height,
                   alignment: .topLeading)
            .padding(.leading, 13)
            .padding(.trailing, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(paper)
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.55 : 0.16),
                            radius: hovering ? 5 : 2.5, y: hovering ? 2.5 : 1.5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color.primary.opacity(0.08)))
            // The slip's quiet spine — the lab's ember, a thread of
            // identity without a post-it's shout. An overlay, so the
            // card's height is the text's alone.
            .overlay(alignment: .leading) {
                UnevenRoundedRectangle(topLeadingRadius: 5, bottomLeadingRadius: 5)
                    .fill(EmberIconLabelStyle.ember.opacity(0.85))
                    .frame(width: 3)
            }
            .scaleEffect(hovering ? 1.02 : 1)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .onHover { hovering = $0 }
            .onTapGesture(perform: onOpen)
            .gesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { value in
                        drag = value.translation
                    }
                    .onEnded { value in
                        onMove(CGPoint(x: position.x + value.translation.width,
                                       y: position.y + value.translation.height))
                        drag = .zero
                    })
            .position(x: position.x + drag.width, y: position.y + drag.height)
            .help("Click to open — drag to move")
    }
}

#Preview("Margin note slips") {
    ZStack(alignment: .topLeading) {
        Color(nsColor: .textBackgroundColor)
        MarginNoteView(
            note: WebAnnotation(
                motivation: WebAnnotation.Motivation.commenting,
                body: WebAnnotation.TextualBody(
                    value: "This argument echoes Engelbart's bootstrapping. Worth comparing with the 1962 framework paper in detail."),
                target: WebAnnotation.Target(source: "origamitext://open/x", selectors: [])),
            fontSize: 10.5,
            position: CGPoint(x: 130, y: 60),
            onMove: { _ in }, onOpen: {})
        MarginNoteView(
            note: WebAnnotation(
                motivation: WebAnnotation.Motivation.commenting,
                body: WebAnnotation.TextualBody(value: "Ask Mark about this."),
                target: WebAnnotation.Target(source: "origamitext://open/x", selectors: [])),
            fontSize: 10.5,
            position: CGPoint(x: 150, y: 160),
            onMove: { _ in }, onOpen: {})
    }
    .frame(width: 420, height: 240)
}

/// The page behind the paragraphs: a ctrl-click on no paragraph and no
/// selection offers "Note…", reporting where the click fell (top-left
/// origin, the article's coordinates) so the note can stand exactly
/// there. Paragraphs above take their own clicks; only the empty page
/// answers here.
/// A weak hand on the page surface, so menu actions elsewhere in the
/// view can convert a window point into the page's own coordinates.
final class MarginNoteSurfaceBox {
    weak var surface: MarginNoteSurface.Surface?
}

struct MarginNoteSurface: NSViewRepresentable {
    let box: MarginNoteSurfaceBox
    let onNote: (CGPoint) -> Void

    final class Surface: NSView {
        var onNote: ((CGPoint) -> Void)?
        override var isFlipped: Bool { true }

        override func menu(for event: NSEvent) -> NSMenu? {
            let point = convert(event.locationInWindow, from: nil)
            let menu = NSMenu()
            menu.allowsContextMenuPlugIns = false
            let item = NSMenuItem(title: "Note…", action: #selector(note(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = NSValue(point: point)
            menu.addItem(item)
            return menu
        }

        @objc private func note(_ sender: NSMenuItem) {
            guard let value = sender.representedObject as? NSValue else { return }
            onNote?(value.pointValue)
        }
    }

    func makeNSView(context: Context) -> Surface {
        let view = Surface()
        view.onNote = onNote
        box.surface = view
        return view
    }

    func updateNSView(_ view: Surface, context: Context) {
        view.onNote = onNote
        box.surface = view
    }
}

/// The opened annotation: the whole note, editable, with the reader's
/// three verbs — Delete it, Copy it as a citation to this document
/// (the note riding in the citation's Annotation field, for Author),
/// or Save the rewrite.
private struct AnnotationEditorSheet: View {
    let text: String
    let onDelete: () -> Void
    let onCopy: (String) -> Void
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Annotation").font(.headline)
            TextEditor(text: $draft)
                .font(.body)
                .frame(minHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            HStack {
                Button("Delete", role: .destructive) {
                    onDelete()
                    dismiss()
                }
                Spacer()
                Button("Copy") {
                    onCopy(draft)
                    dismiss()
                }
                .help("Copy as a citation to this document, your annotation in its Annotation field — paste into Author")
                Button("Save") {
                    onSave(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { draft = text }
    }
}

/// The comment sheet: the paragraph being commented on, and the note.
private struct ReadingCommentComposer: View {
    let preview: String
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Comment").font(.headline)
            Text(preview)
                .lineLimit(4)
                .foregroundStyle(.secondary)
            TextField("Your note…", text: $text, axis: .vertical)
                .lineLimit(3...8)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(text)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 440)
    }
}

/// The whole-document annotation sheet: one note describing the
/// document itself, opened from the header pill. Saving empty text
/// removes the annotation. Lift carries the draft into its own window
/// (LiftedAnnotationWindow) — room to write, free to browse — still
/// bound to this document.
private struct DocumentAnnotationComposer: View {
    let title: String
    let text: String
    let onSave: (String) -> Void
    let onLift: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Annotate Document").font(.headline)
            Text(title)
                .lineLimit(2)
                .foregroundStyle(.secondary)
            TextField("Your annotation…", text: $draft, axis: .vertical)
                .lineLimit(3...8)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Lift") {
                    dismiss()
                    onLift(draft)
                }
                .help("Write in a window of its own — read anything meanwhile; the annotation stays this document's")
                if !text.isEmpty {
                    Button("Remove", role: .destructive) {
                        onSave("")
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.isEmpty
                          && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 440)
        .onAppear { draft = text }
    }
}

/// A lifted document annotation: the address and title it belongs to,
/// and the draft as it stood when lifted — the value a lifted window
/// opens on.
nonisolated struct LiftedAnnotation: Codable, Hashable {
    var address: String
    var title: String
    var draft: String
}

/// The lifted annotation in its own window, titled with the article:
/// a full text editor to think in, while the main window reads
/// whatever it likes. Save writes the annotation to the original
/// document; the association never moves.
struct LiftedAnnotationWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let target: LiftedAnnotation

    @State private var draft = ""
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(target.title)
                .font(.headline)
                .lineLimit(2)
                .foregroundStyle(.secondary)
            TextEditor(text: $draft)
                .font(.body)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                if model.documentAnnotation(forAddress: target.address) != nil {
                    Button("Remove", role: .destructive) {
                        model.setDocumentAnnotation("", forAddress: target.address)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    model.setDocumentAnnotation(draft, forAddress: target.address)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          && model.documentAnnotation(forAddress: target.address) == nil)
            }
        }
        .padding(16)
        .frame(minWidth: 480, minHeight: 360)
        .navigationTitle(target.title)
        .onAppear {
            guard !loaded else { return }
            draft = target.draft
            loaded = true
        }
    }
}

/// One of the document's own concept definitions — the glossary the
/// author shipped inside the document.
private struct ConceptSheet: View {
    let concept: LiquidDoc.Concept
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(concept.name).font(.title2).bold()
            if !concept.description.isEmpty {
                Text(concept.description)
            } else {
                Text("The document names this concept but carries no description.")
                    .foregroundStyle(.secondary)
            }
            if let tag = concept.tag, !tag.isEmpty {
                Label(tag, systemImage: "tag")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(concept.urls, id: \.self) { url in
                if let link = URL(string: url) {
                    Link(url, destination: link).font(.caption)
                }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 420, maxWidth: 520)
    }
}

/// One endnote, revealed by its dagger: the note's text with its
/// conventions rendered — links included, live.
private struct EndnoteSheet: View {
    @Environment(\.dismiss) private var dismiss
    let text: AttributedString

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Note").font(.headline)
            ScrollView {
                Text(text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 260)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 380, maxWidth: 480)
    }
}

/// The card of a cited source, opened by tapping its citation in the
/// body — in the native styles and the faithful WebView alike: the
/// reference entry parsed into title, credit, venue, and DOI, the raw
/// BibTeX one copy away — and, when the cited document is a book in
/// this library, the way to open it at the very paragraph.
struct CitationCardSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let doc: LiquidDoc
    let key: String

    private var reference: LiquidDoc.Reference? {
        if let direct = doc.references.first(where: { $0.id == key }) { return direct }
        // An internal citation: the link to the cited document carries
        // its own BibTeX — the card reads it the same way.
        if let bibtex = doc.links.first(where: { $0.to == key })?.bibtex {
            return LiquidDoc.Reference(id: key, bibtex: bibtex)
        }
        return nil
    }

    private var record: BibTeXRecord? {
        reference.flatMap { BibTeXRecord.records(in: $0.bibtex).first }
    }

    /// What the lookup services gathered about the work — the abstract
    /// the package did not carry, the TL;DR, an open-access way in.
    /// See CitationLookup.swift.
    @State private var enrichment: CitationLookup.Enrichment?
    @State private var lookingUp = false

    /// What this cited work itself cites — the second-order references
    /// the longer Maps draw. See CitationGraph.swift.
    @State private var graph: CitationGraph.Entry?
    @State private var fetchingGraph = false

    /// The address a vm-id field carries: the cited document in the
    /// origami id space and, after the #, the very paragraph.
    private var citedAddress: (docID: String, paragraphID: String?)? {
        guard let raw = record?.fields["vm-id"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty
        else { return nil }
        guard let hash = raw.firstIndex(of: "#") else { return (raw, nil) }
        return (String(raw[..<hash]), String(raw[raw.index(after: hash)...]))
    }

    /// The record's own abstract when it carries one; the services'
    /// stands in otherwise.
    private var recordAbstract: String? {
        (record?.fields["abstract"])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let record {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: record.shelvesAsBook ? "book.closed" : "doc.text")
                        .font(.title2)
                        .foregroundStyle(.tint)
                        .frame(width: 44, height: 44)
                        .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.title.isEmpty ? "Untitled" : record.title)
                            .font(.title3).bold()
                        if !record.displayAuthors.isEmpty {
                            Text(record.displayAuthors)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if let abstract = recordAbstract ?? enrichment?.abstract {
                    // The abstract reads as the body does — the card is
                    // a page to read, not a footnote.
                    let readingFont = AppFonts.body(
                        NSFont.preferredFont(forTextStyle: .body).pointSize + 2)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            if let tldr = enrichment?.tldr {
                                Text("TL;DR \u{2014} \(tldr)")
                                    .font(readingFont)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Text(abstract)
                                .font(readingFont)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(maxHeight: 300)
                    if recordAbstract == nil, let source = enrichment?.source, !source.isEmpty {
                        Text("Abstract via \(source)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                } else if let tldr = enrichment?.tldr {
                    // No abstract anywhere, but the AI summary answers.
                    Text("TL;DR \u{2014} \(tldr)")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Summary via \(enrichment?.source ?? "")")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else if lookingUp {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Looking up the work\u{2026}")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    // The record's own fields lead; the services fill
                    // what it left blank.
                    let year = record.year.isEmpty ? (enrichment?.year ?? "") : record.year
                    if !year.isEmpty {
                        LabeledContent("Year", value: year)
                            .font(.callout)
                    }
                    if let venue = [record.fields["journal"], record.fields["booktitle"],
                                    record.fields["series"], enrichment?.venue]
                        .compactMap({ $0 }).first(where: { !$0.isEmpty }) {
                        LabeledContent("Published in", value: venue)
                            .font(.callout)
                    }
                    let doi = record.fields["doi"].flatMap { $0.isEmpty ? nil : $0 }
                        ?? enrichment?.doi
                    if let doi, let link = URL(string: "https://doi.org/\(doi)") {
                        LabeledContent("DOI") {
                            Link("doi.org/\(doi)", destination: link)
                        }
                        .font(.callout)
                    }
                    if let openAccess = enrichment?.openAccessURL,
                       let link = URL(string: openAccess) {
                        LabeledContent("Open access") {
                            Link("Read the full text", destination: link)
                        }
                        .font(.callout)
                    }
                }
                citesSection(record)
            } else if let reference {
                // No parseable BibTeX to render a card from — the raw
                // entry is all there is to show.
                Text("This entry's BibTeX did not parse; the raw entry:")
                    .foregroundStyle(.secondary)
                ScrollView {
                    Text(reference.bibtex)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
                .padding(8)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            } else {
                Text("The document's reference list has no entry \u{201C}\(key)\u{201D}.")
                    .foregroundStyle(.secondary)
            }

            HStack {
                if let reference {
                    Button("Copy BibTeX", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(reference.bibtex, forType: .string)
                    }
                    .help("The reference's BibTeX entry, whole")
                }
                Spacer()
                if let address = citedAddress,
                   model.epubRecord(forAddress: address.docID) != nil {
                    // The entry names the cited document by address —
                    // and this library holds it: open it right there,
                    // at the very paragraph the citation quotes.
                    Button("Open Original") {
                        dismiss()
                        model.openEPUB(address: address.docID,
                                       fragment: address.paragraphID)
                    }
                    .keyboardShortcut(.defaultAction)
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                } else if model.epubRecord(forAddress: key) != nil {
                    // An internal citation: its key IS the cited
                    // document's address, and the book is here.
                    Button("Open Original") {
                        dismiss()
                        model.openEPUB(address: key, fragment: nil)
                    }
                    .keyboardShortcut(.defaultAction)
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                } else if let url = record?.webURL {
                    Button("Open on the Web") {
                        openURL(url)
                    }
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 480, maxWidth: 680)
        // What the package left out, the services fill in: the cache
        // answers free; the network is asked only when the record
        // carries no abstract of its own (Settings ▸ Reading turns
        // lookups off entirely).
        .task(id: key) {
            guard let record else { return }
            // The citation graph's answer, when the quiet prefetch (or
            // an earlier ask) already holds it.
            graph = CitationGraph.cached(forKey: CitationGraph.key(
                title: record.title, author: record.fields["author"] ?? ""))
            if let cached = CitationLookup.cached(for: record) {
                enrichment = cached
                return
            }
            guard recordAbstract == nil, CitationLookup.isEnabled else { return }
            lookingUp = true
            enrichment = await CitationLookup.enrich(record)
            lookingUp = false
        }
    }

    /// What this work itself cites — the second-order references the
    /// longer Maps draw, fetched once and cached (CitationGraph).
    @ViewBuilder private func citesSection(_ record: BibTeXRecord) -> some View {
        Divider()
        if let graph, graph.found {
            DisclosureGroup {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(graph.references.enumerated()), id: \.offset) { _, cited in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(cited.title)
                                    .font(.callout)
                                    .textSelection(.enabled)
                                let line = [cited.authors,
                                            cited.year.map(String.init) ?? ""]
                                    .filter { !$0.isEmpty }.joined(separator: " · ")
                                if !line.isEmpty {
                                    Text(line)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
            } label: {
                Text("Cites \(graph.references.count) works")
                    .font(.callout)
            }
            Text("References via \(graph.source)")
                .font(.caption)
                .foregroundStyle(.tertiary)
        } else if fetchingGraph {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Asking what this work cites\u{2026}")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else if graph != nil {
            Text("The services do not list this work's references.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        } else if CitationGraph.isEnabled {
            Button("What does this work cite?") {
                fetchingGraph = true
                Task { @MainActor in
                    graph = await CitationGraph.references(
                        title: record.title,
                        author: record.fields["author"] ?? "",
                        year: Int(record.year.prefix(4)),
                        doi: record.fields["doi"]?.lowercased())
                    fetchingGraph = false
                }
            }
            .font(.callout)
            .help("The work's own reference list, from the scholarly services — how the Maps grow longer chains")
        }
    }
}

/// The document's reference list, each entry parsed into a readable
/// citation sentence, the raw BibTeX one copy away.
private struct ReferencesSheet: View {
    let doc: LiquidDoc
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("References (\(doc.references.count))").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()
            // Numbered as the body's [n] citations count them.
            List(Array(OrigamiReading.readableReferences(of: doc).enumerated()),
                 id: \.element.id) { index, reference in
                Text("[\(index + 1)] \(reference.text)")
                    .textSelection(.enabled)
                    .contextMenu {
                        Button("Copy", systemImage: "doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(reference.text, forType: .string)
                        }
                    }
            }
        }
        .frame(minWidth: 520, minHeight: 380)
    }
}

// MARK: - The live table

/// A live table from the document's pool: the computed grid, its header
/// ruled off — computed cells follow the inputs, and an input answers a
/// what-if that lives only as long as the view.
private struct OrigamiTableView: View {
    let table: LiquidDoc.Table

    /// The reader's what-ifs: numbers typed over the inputs, keyed
    /// "row,col" — never the document's words.
    @State private var overrides: [String: String] = [:]

    /// Whether any cell computes — a static table reads as written.
    private var live: Bool {
        table.cells.contains { row in
            row.contains { ($0.formula ?? "").isEmpty == false }
        }
    }

    /// The grid with the overrides applied and formulas recomputed.
    private var computed: [[LiquidDoc.Table.Cell]] {
        let laTable = table.laTable()
        for (key, value) in overrides {
            let parts = key.split(separator: ",")
            guard parts.count == 2, let row = Int(parts[0]), let col = Int(parts[1])
            else { continue }
            laTable.setValue(value, row: row, column: col)
        }
        laTable.recalculate()
        return LiquidDoc.Table(laTable).cells
    }

    var body: some View {
        let cells = live ? computed : table.cells
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 5) {
                    ForEach(Array(cells.enumerated()), id: \.offset) { row, rowCells in
                        GridRow {
                            ForEach(Array(rowCells.enumerated()), id: \.offset) { col, cell in
                                cellView(cell, original: table.cells[safe: row]?[safe: col],
                                         row: row, col: col)
                            }
                        }
                        if row == 0 && cells.count > 1 {
                            Divider()
                        }
                    }
                }
                .padding(10)
            }
            if live, !overrides.isEmpty {
                Button("Reset") {
                    withAnimation(.snappy) { overrides = [:] }
                }
                .buttonStyle(.link)
                .font(.caption)
                .help("Back to the document's own numbers")
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary.opacity(0.4))
        }
    }

    @ViewBuilder
    private func cellView(_ cell: LiquidDoc.Table.Cell,
                          original: LiquidDoc.Table.Cell?,
                          row: Int, col: Int) -> some View {
        let key = "\(row),\(col)"
        if let formula = cell.formula, !formula.isEmpty {
            Text(cell.value)
                .font(cellFont(row: row))
                // A computed cell whispers what it is: a dotted line
                // under the number, the formula on the pointer.
                .underline(pattern: .dot, color: .secondary.opacity(0.5))
                .help(formula.hasPrefix("=") ? formula : "= " + formula)
                .contentTransition(.numericText())
                .animation(.snappy, value: cell.value)
        } else if live, Double((original?.value ?? cell.value)
            .replacingOccurrences(of: ",", with: "")) != nil {
            TextField("", text: overrideBinding(key, original: original?.value ?? cell.value))
                .textFieldStyle(.plain)
                .font(cellFont(row: row))
                .fixedSize()
                .foregroundStyle(overrides[key] == nil
                                 ? AnyShapeStyle(.primary)
                                 : AnyShapeStyle(Color.accentColor))
                .help("An input the maths reads — try another number; Reset restores the document's.")
        } else {
            Text(cell.value)
                .font(cellFont(row: row))
                .textSelection(.enabled)
        }
    }

    private func cellFont(row: Int) -> Font {
        AppFonts.body(14, weight: row == 0 ? .semibold : .regular)
    }

    /// Typing over an input keeps the what-if beside the document's
    /// own number; typing the original back lets the what-if go.
    private func overrideBinding(_ key: String, original: String) -> Binding<String> {
        Binding(get: { overrides[key] ?? original },
                set: { typed in
                    if typed == original {
                        overrides.removeValue(forKey: key)
                    } else {
                        overrides[key] = typed
                    }
                })
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Selection view modes

/// One selection viewed differently: the words around it grey out and
/// wait for a click to restore normal reading; the selection itself
/// shows as Flow lines or as the on-device model's rewrite.
private struct SelectionViewMode {
    enum Display: Equatable {
        /// The selection broken into reading lines at . and , marks.
        case flow
        /// The named AI verb is still thinking.
        case aiLoading(String)
        /// The model's rewrite, read in place.
        case aiResult(String)
        /// Why there is no rewrite.
        case aiFailed(String)
    }

    let paragraphID: String
    let prefix: String
    let selected: String
    let suffix: String
    var display: Display
}

/// The mode's rendering of its paragraph: grey unselected words either
/// side (click to leave the mode), the transformed selection between.
private struct SelectionModeView: View {
    let mode: SelectionViewMode
    let font: Font
    let exit: () -> Void
    @AppStorage("flowBreakOnComma") private var flowBreakOnComma = true
    @AppStorage("flowDoubleBreakOnPeriod") private var flowDoubleBreakOnPeriod = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            greyText(mode.prefix)
            switch mode.display {
            case .flow:
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(OrigamiReading.flowLines(
                        mode.selected,
                        breakOnComma: flowBreakOnComma,
                        doubleBreakOnPeriod: flowDoubleBreakOnPeriod).enumerated()),
                            id: \.offset) { _, line in
                        // An empty entry is the double break: a blank
                        // line between sentences.
                        Text(line.isEmpty ? " " : line).font(font)
                    }
                }
            case .aiLoading(let name):
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("\(name)…").foregroundStyle(.secondary)
                }
            case .aiResult(let text):
                Text(text).font(font)
            case .aiFailed(let reason):
                Label(reason, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            greyText(mode.suffix)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func greyText(_ text: String) -> some View {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            Text(trimmed)
                .font(font)
                .foregroundStyle(.tertiary)
                .contentShape(Rectangle())
                .onTapGesture(perform: exit)
        }
    }
}

extension View {
    /// While a stretchtext is open, everything but the revealed words
    /// reads grey — a visual focus, clicks unchanged.
    @ViewBuilder
    fileprivate func dimmedForStretch(_ active: Bool) -> some View {
        if active {
            self.grayscale(1).opacity(0.4)
        } else {
            self
        }
    }

    /// While a selection view mode is on, everything unselected greys
    /// out and any click on it leaves the mode.
    @ViewBuilder
    fileprivate func greyedOut(_ active: Bool, exit: @escaping () -> Void) -> some View {
        if active {
            self
                .grayscale(1)
                .opacity(0.35)
                .overlay {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture(perform: exit)
                }
        } else {
            self
        }
    }
}

// MARK: - The selectable paragraph

/// One verb of the paragraph menu, as data — built once, rendered as an
/// NSMenu on the selectable paragraphs and as SwiftUI items on the
/// table fallback.
private enum ParagraphMenuEntry {
    case action(title: String, symbol: String, run: () -> Void)
    case submenu(title: String, symbol: String, items: [(String, String, () -> Void)])
    case separator
}

/// A paragraph as an NSTextView: text selects like any Mac text, but
/// right-click shows only the reading menu — SwiftUI's selectable Text
/// always merges the system's items (Look Up, Translate, Services…)
/// into a custom context menu; AppKit lets the menu be replaced whole.
/// Links route through `onLink`, so citations still open their source
/// card.
private struct SelectableParagraph: NSViewRepresentable {
    let attributed: AttributedString
    let baseFont: NSFont
    /// Extra points between lines (⌥⌘+/⌥⌘−).
    let lineSpacing: CGFloat
    /// The theme's ink for this paragraph; nil reads as the platform's.
    let inkColor: NSColor?
    /// Stretch focus: everything greys except the stretch's own
    /// controls. Ink only — a compositing effect would freeze the
    /// AppKit view into a picture and swallow its clicks.
    let dimmed: Bool
    let dimInk: NSColor
    /// The paragraph's verbs, built at right-click time with the
    /// sentence under the click (nil when it cannot be told) and the
    /// click's window point — so annotating without a selection takes
    /// the sentence, never the whole paragraph, and a Note can stand
    /// where the click fell.
    let entriesFor: (String?, NSPoint?) -> [ParagraphMenuEntry]
    /// Extra verbs built at right-click time from the live selection —
    /// the view options over selected text (Flow, the AI submenu).
    let selectionEntries: (String, NSRange) -> [ParagraphMenuEntry]
    let onLink: (URL) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MenuTextView {
        let view = MenuTextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        view.isHorizontallyResizable = false
        // Links read in the body ink, not browser blue — the run's own
        // attributes carry the colour and a quiet underline, so the
        // view must not paint links over them.
        view.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        view.delegate = context.coordinator
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ view: MenuTextView, context: Context) {
        context.coordinator.entriesFor = entriesFor
        context.coordinator.selectionEntries = selectionEntries
        context.coordinator.onLink = onLink
        let converted = converted()
        // Replacing the storage drops any live selection; only real
        // content changes are worth that.
        if view.textStorage?.isEqual(to: converted) != true {
            view.textStorage?.setAttributedString(converted)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MenuTextView,
                      context: Context) -> CGSize? {
        guard let container = nsView.textContainer,
              let layout = nsView.layoutManager else { return nil }
        // Measure at the proposed width; when none is proposed, at the
        // width the view actually has, so every pass agrees.
        let width = proposal.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            ?? (nsView.bounds.width > 0 ? nsView.bounds.width : 680)
        container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        return CGSize(width: width, height: ceil(used.height))
    }

    /// The AttributedString with its semantic runs resolved into AppKit
    /// attributes: presentation intents to bold/italic/monospace on the
    /// base font, colours and links carried across.
    private func converted() -> NSAttributedString {
        let out = NSMutableAttributedString()
        for run in attributed.runs {
            let text = String(attributed.characters[run.range])
            var font = baseFont
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) {
                    font = .monospacedSystemFont(ofSize: baseFont.pointSize * 0.92,
                                                 weight: .regular)
                }
                var traits: NSFontDescriptor.SymbolicTraits = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
                if intent.contains(.emphasized) { traits.insert(.italic) }
                if !traits.isEmpty {
                    let descriptor = font.fontDescriptor.withSymbolicTraits(
                        font.fontDescriptor.symbolicTraits.union(traits))
                    font = NSFont(descriptor: descriptor, size: font.pointSize) ?? font
                }
            }
            var ink = run.foregroundColor.map(NSColor.init) ?? inkColor ?? .labelColor
            if dimmed, run.link?.scheme != "origami-stretch" {
                ink = dimInk
            }
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineSpacing = lineSpacing
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: ink,
                .paragraphStyle: paragraphStyle,
            ]
            if let background = run.backgroundColor {
                attributes[.backgroundColor] = NSColor(background)
            }
            if let link = run.link {
                // Body ink with a quiet underline — the format's rule
                // for links, never browser blue. The stretch toggle
                // and the glossary daggers are controls, not
                // references: no underline.
                attributes[.link] = link
                if link.scheme != "origami-stretch", link.scheme != "origami-gloss",
                   link.scheme != "origami-note", link.scheme != "origami-inote",
                   link.scheme != "origami-conceptcard" {
                    attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                    attributes[.underlineColor] = ink.withAlphaComponent(0.35)
                }
            }
            out.append(NSAttributedString(string: text, attributes: attributes))
        }
        return out
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var entriesFor: (String?, NSPoint?) -> [ParagraphMenuEntry] = { _, _ in [] }
        var selectionEntries: (String, NSRange) -> [ParagraphMenuEntry] = { _, _ in [] }
        var onLink: (URL) -> Bool = { _ in false }

        func textView(_ textView: NSTextView, clickedOnLink link: Any,
                      at charIndex: Int) -> Bool {
            guard let url = link as? URL else { return false }
            return onLink(url)
        }

        /// The sentence under a character index in the view's text —
        /// what a no-selection annotation anchors to.
        private func sentence(in textView: NSTextView, at index: Int) -> String? {
            let text = textView.string as NSString
            guard index >= 0, index < text.length else { return nil }
            var found: String?
            text.enumerateSubstrings(in: NSRange(location: 0, length: text.length),
                                     options: .bySentences) { sub, range, _, stop in
                if NSLocationInRange(index, range) {
                    found = sub
                    stop.pointee = true
                }
            }
            return found?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// The context menu, built fresh on each right-click — the
        /// paragraph's verbs (knowing the clicked sentence), then the
        /// selection's view options when words are selected. Nothing of
        /// the system's.
        func makeMenu(for textView: NSTextView, at clickIndex: Int?,
                      windowPoint: NSPoint?) -> NSMenu {
            let menu = NSMenu()
            let clicked = clickIndex.flatMap { sentence(in: textView, at: $0) }
            var all = entriesFor(clicked, windowPoint)
            let range = textView.selectedRange()
            if range.length > 0 {
                all += selectionEntries(textView.string, range)
            }
            for entry in all {
                switch entry {
                case .action(let title, let symbol, let run):
                    menu.addItem(item(title: title, symbol: symbol, run: run))
                case .submenu(let title, let symbol, let items):
                    let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                    parent.image = NSImage(systemSymbolName: symbol,
                                           accessibilityDescription: nil)
                    let submenu = NSMenu()
                    for (subtitle, key, run) in items {
                        let child = item(title: subtitle, symbol: nil, run: run)
                        // Bare keys, Reader's way: pressing the letter
                        // fires the kind while the menu is open.
                        child.keyEquivalent = key
                        child.keyEquivalentModifierMask = []
                        submenu.addItem(child)
                    }
                    parent.submenu = submenu
                    menu.addItem(parent)
                case .separator:
                    menu.addItem(.separator())
                }
            }
            return menu
        }

        private func item(title: String, symbol: String?,
                          run: @escaping () -> Void) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: #selector(fire(_:)),
                                  keyEquivalent: "")
            item.target = self
            if let symbol {
                item.image = NSImage(systemSymbolName: symbol,
                                     accessibilityDescription: nil)
            }
            item.representedObject = MenuClosure(run)
            return item
        }

        @objc private func fire(_ sender: NSMenuItem) {
            (sender.representedObject as? MenuClosure)?.run()
        }
    }

    /// A closure a menu item can carry.
    final class MenuClosure {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
    }

    /// NSTextView whose context menu is the coordinator's, whole, and
    /// whose reading controls act on the press itself.
    final class MenuTextView: NSTextView {
        weak var coordinator: Coordinator?

        /// The wrap follows the frame the moment the frame changes —
        /// measured height and drawn text can never disagree, which
        /// would read as overlapping paragraphs (text views do not
        /// clip). Width tracking is kept manual so measurement passes
        /// at other widths stay undisturbed.
        override func setFrameSize(_ newSize: NSSize) {
            if let container = textContainer, container.size.width != newSize.width {
                container.size = NSSize(width: newSize.width,
                                        height: .greatestFiniteMagnitude)
            }
            super.setFrameSize(newSize)
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            // The clicked character, so a no-selection annotation can
            // take the sentence under the cursor.
            let point = convert(event.locationInWindow, from: nil)
            var clickIndex: Int?
            if let layoutManager, let textContainer, let storage = textStorage,
               storage.length > 0 {
                var fraction: CGFloat = 0
                let index = layoutManager.characterIndex(
                    for: point, in: textContainer, fractionOfDistanceBetweenInsertionPoints: &fraction)
                if index < storage.length { clickIndex = index }
            }
            return coordinator?.makeMenu(for: self, at: clickIndex,
                                         windowPoint: event.locationInWindow)
        }

        /// The empty page to the right of a short line belongs to the
        /// page behind (the margin notes' surface), not to this
        /// paragraph — a row spans the full column, but its words do not.
        override func hitTest(_ point: NSPoint) -> NSView? {
            let local = convert(point, from: superview)
            if let layoutManager, let textContainer {
                let used = layoutManager.usedRect(for: textContainer)
                if local.x > used.maxX + 12 { return nil }
            }
            return super.hitTest(point)
        }

        /// The document's own controls — the stretch toggles and
        /// revealed text, glossary marks, endnote daggers, citations —
        /// respond to the mouse-down directly, not the link-click
        /// machinery, so they work wherever the text sits.
        override func mouseDown(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            if let layoutManager, let textContainer, let storage = textStorage,
               storage.length > 0 {
                var fraction: CGFloat = 0
                let index = layoutManager.characterIndex(
                    for: point, in: textContainer,
                    fractionOfDistanceBetweenInsertionPoints: &fraction)
                if index < storage.length,
                   let url = storage.attribute(.link, at: index,
                                               effectiveRange: nil) as? URL,
                   ["origami-stretch", "origami-gloss", "origami-note", "origami-inote",
                    "origami-cite", "origami-conceptcard"]
                       .contains(url.scheme ?? "") {
                    let glyphRange = layoutManager.glyphRange(
                        forCharacterRange: NSRange(location: index, length: 1),
                        actualCharacterRange: nil)
                    let rect = layoutManager.boundingRect(forGlyphRange: glyphRange,
                                                          in: textContainer)
                    if rect.insetBy(dx: -3, dy: -3).contains(point) {
                        _ = coordinator?.onLink(url)
                        return
                    }
                }
            }
            super.mouseDown(with: event)
        }
    }
}

// MARK: - The window's state

/// What the reading measure needs to know about its window.
struct ReaderWindowState: Equatable {
    var isFullScreen = false
    var isBuiltInDisplay = true
    var screenWidth: CGFloat = 1512
    /// The hosting window's number, so event monitors act only on
    /// their own window's events.
    var windowNumber = 0
}

/// Reports the hosting window's full-screen state and display — on
/// arrival, on enter/exit, and when the window changes screens.
private struct ReaderWindowWatcher: NSViewRepresentable {
    let onChange: (ReaderWindowState) -> Void

    func makeNSView(context: Context) -> WatcherView {
        let view = WatcherView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: WatcherView, context: Context) {
        view.onChange = onChange
    }

    final class WatcherView: NSView {
        var onChange: ((ReaderWindowState) -> Void)?
        private var observers: [any NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            report()
            for name in [NSWindow.didEnterFullScreenNotification,
                         NSWindow.didExitFullScreenNotification,
                         NSWindow.didChangeScreenNotification] {
                observers.append(NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main) { [weak self] _ in
                    self?.report()
                })
            }
        }

        private func report() {
            guard let window else { return }
            var state = ReaderWindowState()
            state.isFullScreen = window.styleMask.contains(.fullScreen)
            state.windowNumber = window.windowNumber
            if let screen = window.screen {
                state.screenWidth = screen.frame.width
                let number = (screen.deviceDescription[
                    NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                    .uint32Value ?? 0
                state.isBuiltInDisplay = CGDisplayIsBuiltin(number) != 0
            }
            DispatchQueue.main.async { [onChange] in
                onChange?(state)
            }
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }
}

// MARK: - Citable figures

/// An image a document carries aboard (an imported EPUB's figure), its
/// alt text as a quiet caption. An Interatlas screenshot carries its
/// View Citation inside the PNG itself; such an image answers a click
/// with the citation and Open Source — the link that recreates the
/// very scene. Brought across from Knowledge Space; keep in step.
struct OrigamiAssetView: View {
    @Environment(AppModel.self) private var model
    let asset: LiquidDoc.Asset
    /// The citation standing beside the image in the document, for a
    /// PNG whose own embedded copy did not survive its export.
    var fallback: BibTeXRecord? = nil
    /// The document the figure stands in, for the package's own scene
    /// datasets (data/<scene-id>.liquidinfo.json, spec §2.4).
    var doc: LiquidDoc? = nil

    /// The citation read out of the PNG, once, on appearance.
    @State private var record: BibTeXRecord?
    /// The complete `.liquidinfo` scene a Liquid PNG carries in its
    /// `liquid-scene` chunk — the image as its own source of truth.
    @State private var scene: String?
    @State private var showsCitation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if record != nil {
                Button {
                    showsCitation = true
                } label: {
                    imageContent
                }
                .buttonStyle(.plain)
                .help("This image carries its citation — click for the record and Open Source")
                .popover(isPresented: $showsCitation) { citationPopover }
            } else {
                imageContent
            }
            if let alt = asset.alt, !alt.isEmpty {
                Text(alt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task {
            // The PNG's own embedded citation first; the one standing
            // beside the image in the document otherwise. The scene
            // rides along for Open Source, by the format's ladder:
            // the package's data/ file is the full truth — the chunk
            // may be the trimmed form when the data is large — and
            // the chunk stands in otherwise.
            if asset.mediaType == "image/png", let data = asset.data {
                scene = PNGCitation.sceneText(inPNGData: data)
                if let text = PNGCitation.citationText(inPNGData: data),
                   let found = BibTeXRecord.records(in: text).first {
                    record = found
                }
            }
            if record == nil { record = fallback }
            if let packaged = packagedScene() { scene = packaged }
        }
    }

    /// The record an image cites when its citation stands beside it:
    /// Author's export wraps a figure in a citation anchor and repeats
    /// the key in the caption paragraph, so the nearest `[cite:]`
    /// within the two paragraphs after the image is the image's own.
    /// Failing that, a document with exactly one Interatlas-linked
    /// reference gives its images that one — never a guess between
    /// several.
    static func imageCitation(after paragraph: LiquidDoc.Paragraph,
                              in doc: LiquidDoc) -> BibTeXRecord? {
        func record(forKey key: String) -> BibTeXRecord? {
            doc.references.first { $0.id == key }
                .flatMap { BibTeXRecord.records(in: $0.bibtex).first }
        }
        if let body = doc.body,
           let index = body.firstIndex(where: { $0.id == paragraph.id }) {
            for next in body[(index + 1)...].prefix(2) {
                guard let match = next.text.range(of: #"\[cite:([^\]]+)\]"#,
                                                  options: .regularExpression) else { continue }
                let token = String(next.text[match])
                let key = String(token.dropFirst("[cite:".count).dropLast())
                if let found = record(forKey: key) { return found }
            }
        }
        let interatlas = doc.references.compactMap { reference -> BibTeXRecord? in
            guard let parsed = BibTeXRecord.records(in: reference.bibtex).first,
                  let url = parsed.fields["url"],
                  InteratlasLink.isInteratlasLink(url) else { return nil }
            return parsed
        }
        return interatlas.count == 1 ? interatlas.first : nil
    }

    /// The scene dataset the document's package carries for this
    /// figure (spec §2.4) — named by the citation's `scene-resource`
    /// field (the pool's copy carries it; the PNG's embedded record
    /// cannot know package paths), or matched to the link's scene id
    /// when the field is absent.
    private func packagedScene() -> String? {
        guard let doc else { return nil }
        var names: [String] = []
        if let resource = record?.fields["scene-resource"]
            ?? fallback?.fields["scene-resource"] {
            let trimmed = resource.trimmingCharacters(in: .whitespaces)
            names.append((trimmed as NSString).lastPathComponent.lowercased())
        }
        if let urlText = record?.fields["url"] ?? fallback?.fields["url"],
           let url = URL(string: urlText.trimmingCharacters(in: .whitespaces)),
           LiquidViewLink.isLiquidViewLink(url),
           let sceneID = url.pathComponents.last, !sceneID.isEmpty {
            names.append("\(sceneID.lowercased()).liquidinfo.json")
        }
        guard !names.isEmpty else { return nil }
        for candidate in doc.assets
        where candidate.isLiquidSceneResource
            && names.contains(candidate.filename.lowercased()) {
            if let data = candidate.data {
                return String(data: data, encoding: .utf8)
            }
        }
        return nil
    }

    /// Open Source: a Liquid view link that does not itself carry the
    /// scene is handed over with the scene the document holds — the
    /// package's data/ file or the PNG's own `liquid-scene` chunk — so
    /// what is sent is always enough to re-create the very view. A
    /// scene over the link ceiling travels as a `.liquidinfo` file.
    private func openSource(_ url: URL) {
        var url = url
        var sceneAsFile: String?
        if LiquidViewLink.isLiquidViewLink(url), let scene {
            if LiquidViewLink.sceneTravelsInLink(scene) {
                url = LiquidViewLink.carryingScene(url, sceneJSON: scene)
            } else if !LiquidViewLink.carriesScene(url) {
                sceneAsFile = scene
            }
        }
        if let sceneAsFile {
            model.openLiquidScene(json: sceneAsFile, link: url)
            return
        }
        // The Liquid check first: a Liquid view link lives on the same
        // link domain as Interatlas, told apart by its /liquid/ path.
        if LiquidViewLink.isLiquidViewLink(url) {
            model.openLiquidViewLink(url)
        } else if InteratlasLink.isInteratlasLink(url) {
            model.openInteratlasLink(url)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    @ViewBuilder private var imageContent: some View {
        if let data = asset.data, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 560)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            Label(asset.filename, systemImage: "photo")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// The citation as the source speaks it, with its doors.
    @ViewBuilder private var citationPopover: some View {
        if let record {
            VStack(alignment: .leading, spacing: 10) {
                Text(record.citationSentence)
                    .font(.system(size: 14, design: .serif))
                    .textSelection(.enabled)
                if let abstract = record.fields["abstract"], !abstract.isEmpty {
                    Text(abstract)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                HStack(spacing: 8) {
                    if let urlText = record.fields["url"],
                       let url = URL(string: urlText.trimmingCharacters(in: .whitespaces)) {
                        Button("Open Source") { openSource(url) }
                            .help(LiquidViewLink.isLiquidViewLink(url)
                                  ? "Opens this very view in Liquid — the link carries the whole view state"
                                  : InteratlasLink.isInteratlasLink(url)
                                  ? "Opens this very scene in Interatlas — the link carries the whole view state"
                                  : "Opens the cited source")
                    }
                    Button("Copy Citation") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(record.raw, forType: .string)
                    }
                    .help("The full BibTeX record, onto the clipboard")
                }
            }
            .padding(14)
            .frame(minWidth: 260, maxWidth: 420, alignment: .leading)
        }
    }
}

// MARK: - Embedded 3D models

/// An EPUB's embedded 3D model (the `<model>` element), shown on an
/// interactive orbit stage. Apple's frameworks read USD, not glTF, so
/// the stage is the vendored model-viewer (BSD-3-Clause, WebGL) in a
/// web view — everything local: the viewer page and script are laid
/// down beside the model inside the book's own unpacked folder. Where
/// the stage cannot be built, the poster stands in, plainly saying why.
struct OrigamiModelView: View {
    /// The model file's path, relative to the unpacked package.
    let path: String
    let alt: String
    /// The poster image's asset id, when the marker carries one.
    let posterID: String?
    let doc: LiquidDoc

    /// The viewer page written beside the model, or the reason not.
    @State private var stage: Result<URL, StageFailure>?

    enum StageFailure: Error {
        case modelMissing
        case viewerMissing
        case couldNotWrite(String)

        var explanation: String {
            switch self {
            case .modelMissing: "The model file is not in the unpacked book."
            case .viewerMissing: "The 3D viewer script is missing from the app."
            case .couldNotWrite(let why): "The stage could not be written: \(why)"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch stage {
            case .success(let page):
                ModelStageWebView(page: page,
                                  base: page.deletingLastPathComponent())
                    .frame(height: 460)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                Text("3D — drag to orbit, scroll to zoom")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            case .failure(let failure):
                posterView
                Label(failure.explanation, systemImage: "cube.transparent")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case nil:
                posterView
            }
            if !alt.isEmpty {
                Text(alt).font(.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: path) { stage = buildStage() }
    }

    /// The poster asset, while the stage builds or where it cannot.
    @ViewBuilder private var posterView: some View {
        if let posterID,
           let asset = doc.assets.first(where: { $0.id == posterID }),
           let nsImage = asset.data.flatMap(NSImage.init(data:)) {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 460)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            Label((path as NSString).lastPathComponent, systemImage: "cube.transparent")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// Lays the stage down inside the book's folder — the page, the
    /// viewer script beside it — so one file-access grant covers the
    /// page, the script, and the model. Cheap to repeat; a re-unpack
    /// sweeps the folder and the next look rebuilds it.
    private func buildStage() -> Result<URL, StageFailure> {
        let base = doc.fileURL
        let model = base.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: model.path) else {
            return .failure(.modelMissing)
        }
        guard let script = Bundle.main.url(forResource: "model-viewer.min",
                                           withExtension: "js") else {
            return .failure(.viewerMissing)
        }
        let stagedScript = base.appendingPathComponent("origami-model-viewer.js")
        let page = base.appendingPathComponent(
            "origami-model-stage-\((path as NSString).lastPathComponent).html")
        do {
            if !FileManager.default.fileExists(atPath: stagedScript.path) {
                try FileManager.default.copyItem(at: script, to: stagedScript)
            }
            // The model's path relative to the page — both live in base.
            let html = """
            <!doctype html><html><head><meta charset="utf-8">
            <script type="module" src="origami-model-viewer.js"></script>
            <style>
            html, body { margin: 0; height: 100%; background: transparent; }
            model-viewer { width: 100%; height: 100%; --poster-color: transparent; }
            </style></head><body>
            <model-viewer src="\(path)" camera-controls interaction-prompt="none"></model-viewer>
            </body></html>
            """
            try Data(html.utf8).write(to: page, options: .atomic)
        } catch {
            return .failure(.couldNotWrite(error.localizedDescription))
        }
        return .success(page)
    }
}

/// The stage's web view: local files only, no navigation away.
private struct ModelStageWebView: NSViewRepresentable {
    let page: URL
    let base: URL

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        view.loadFileURL(page, allowingReadAccessTo: base)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}
}
