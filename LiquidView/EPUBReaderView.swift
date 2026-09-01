import SwiftUI
import WebKit

/// One open EPUB, rendered faithfully from its own content documents.
/// `content` is the first spine document (paper.html) on disk; `base` is the
/// unpacked package root the WebView is allowed to read, so relative images
/// and style.css resolve. A plain chaptered book carries its whole spine in
/// `chapters`, in reading order, and the reader pages through them; an
/// Origami-profile book has one. `nav` is the EPUB navigation document,
/// when the book names one — the table of contents.
struct OpenEPUB: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let content: URL
    let base: URL
    var chapters: [URL] = []
    var nav: URL? = nil
}

// EPUBRecord — the shelf's remembered book — lives in EPUBShelf.swift,
// shared with the visionOS target.

/// A semantic element the reader's WebView reported — the Step 0 bridge.
/// `kind` is the format's own type (equation, citation, concept, heading,
/// paragraph); `id` is the element id / address; `text` is a short excerpt.
/// Everything richer (view-spec, stretchtext, select-and-act) is built on
/// this round trip.
struct EPUBElementRef: Hashable, Sendable {
    let kind: String
    let id: String
    let text: String
}

/// A text selection in the rendered page, carrying the W3C anchoring
/// ladder's raw material: the enclosing element's stable id (`data-id` or
/// `id`) and up to 32 characters of disambiguating context either side.
/// This is what a new highlight or comment is anchored to.
struct ReaderSelection: Identifiable, Hashable, Sendable {
    let text: String
    let fragment: String?
    let prefix: String?
    let suffix: String?
    var id: String { (fragment ?? "") + "·" + text }
}

/// One annotation as the page script paints it: resolved from the sidecar's
/// W3C selectors to the fields the JavaScript ladder needs — the stable
/// element id first, the exact words as fallback.
struct PaintedAnnotation: Hashable, Sendable {
    let id: String
    let fragment: String?
    let exact: String
    let note: String?
    /// "highlight" or "comment" — the popover's wording.
    let kind: String
    /// The kind's ink, "RRGGBB" — the annotated words take this colour
    /// in the type itself (Settings ▸ Annotations).
    let colorHex: String
    /// Strikethrough draws its line instead of colouring.
    let strike: Bool
}

/// An app-wide colour theme: background and text for every column — the
/// list, the detail, and the reading surface. The CSS variant also themes
/// EPUBs shown in the faithful WebView. Light/dark handled per theme.
/// Sources: Knowledge Space AppTheme (gentle–coolStrong); BDA Style Guide
/// 2014 & Rello/Bigham CHI 2017 (cream, softPeach); Irlen Institute
/// (irlenYellow, irlenGreen, irlenPurple); Almutairi et al. PMC3880533
/// (macular); Ethan Schoonover Solarized (solarized); TheraSpecs FL-41 (night).
enum ReaderTheme: String, CaseIterable, Identifiable, Sendable {
    // ── Standard ─────────────────────────────────────────────────────────
    case highContrast
    case sepia
    case grey
    // ── From Knowledge Space (gentle contrast gradations) ─────────────────
    case gentle
    case lowContrast
    case warm
    case warmStrong
    case cool
    case coolStrong
    // ── Dyslexia / visual stress ──────────────────────────────────────────
    case cream        // BDA standard; intentionally below 4.5:1
    case softPeach    // top CHI 2017 performer for dyslexic readers
    // ── Irlen syndrome overlay simulations ────────────────────────────────
    case irlenYellow
    case irlenGreen
    case irlenPurple
    // ── Macular degeneration ──────────────────────────────────────────────
    case macular      // black on yellow; 71% of AMD patients preferred this
    // ── Photophobia / night reading ───────────────────────────────────────
    case night        // warm dark; avoids blue-heavy tones that trigger photophobia
    case solarized    // Schoonover's perceptually uniform scheme

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .highContrast: "High Contrast"
        case .sepia:        "Sepia"
        case .grey:         "Grey"
        case .gentle:       "Gentle"
        case .lowContrast:  "Low Contrast"
        case .warm:         "Warm"
        case .warmStrong:   "Warm Strong"
        case .cool:         "Cool"
        case .coolStrong:   "Cool Strong"
        case .cream:        "Cream"
        case .softPeach:    "Soft Peach"
        case .irlenYellow:  "Yellow Tint"
        case .irlenGreen:   "Green Tint"
        case .irlenPurple:  "Purple Tint"
        case .macular:      "Black on Yellow"
        case .night:        "Night"
        case .solarized:    "Solarized"
        }
    }

    /// CSS injected into the faithful (WebView) rendering. High Contrast
    /// keeps the EPUB's own black-on-white; every other theme overrides
    /// background and text so the page matches the rest of the app.
    var css: String {
        switch self {
        case .highContrast:
            return ":root { color-scheme: light; }"
        case .sepia:
            return themeCSS(lb: "#eee2cc", lt: "#32281d",
                            db: "#393329", dt: "#ede3d3")
        case .grey:
            return themeCSS(lb: "#dddddd", lt: "#272727",
                            db: "#3f3f3f", dt: "#dddddd")
        case .gentle:
            return themeCSS(lb: "#ffffff", lt: "#666666",
                            db: "#353534", dt: "#aeaeae")
        case .lowContrast:
            return themeCSS(lb: "#dcdddc", lt: "#585958",
                            db: "#222221", dt: "#7b7a79")
        case .warm:
            return themeCSS(lb: "#f5ecdc", lt: "#494742",
                            db: "#3d3633", dt: "#f9f9f8")
        case .warmStrong:
            return themeCSS(lb: "#c3ad9b", lt: "#26231f",
                            db: "#26201e", dt: "#ffffff")
        case .cool:
            return themeCSS(lb: "#d8e1ea", lt: "#575a5d",
                            db: "#2b3e4f", dt: "#b1bbc0")
        case .coolStrong:
            return themeCSS(lb: "#b7c4cf", lt: "#37536b",
                            db: "#2c3840", dt: "#b1b9be")
        case .cream:
            return themeCSS(lb: "#fffdd0", lt: "#1a1a2e",
                            db: "#1a1a0a", dt: "#fffdd0")
        case .softPeach:
            return themeCSS(lb: "#ffe4c4", lt: "#2c1810",
                            db: "#2c1810", dt: "#ffe4c4")
        case .irlenYellow:
            return themeCSS(lb: "#fffff0", lt: "#1a1a1a",
                            db: "#1a1a00", dt: "#fffff0")
        case .irlenGreen:
            return themeCSS(lb: "#d8f5d8", lt: "#0d2d0d",
                            db: "#0d2d0d", dt: "#d8f5d8")
        case .irlenPurple:
            return themeCSS(lb: "#e8d9f0", lt: "#1f0d2d",
                            db: "#1f0d2d", dt: "#e8d9f0")
        case .macular:
            return themeCSS(lb: "#ffff00", lt: "#000000",
                            db: "#333300", dt: "#ffff00")
        case .night:
            return themeCSS(lb: "#faf5e4", lt: "#2d1a0d",
                            db: "#1a1209", dt: "#d4b896")
        case .solarized:
            return themeCSS(lb: "#fdf6e3", lt: "#657b83",
                            db: "#002b36", dt: "#839496")
        }
    }

    private func themeCSS(lb: String, lt: String, db: String, dt: String) -> String {
        """
        :root { color-scheme: light dark; }
        html, body { background-color: \(lb); color: \(lt); }
        @media (prefers-color-scheme: dark) {
          html, body { background-color: \(db); color: \(dt); }
        }
        """
    }

    /// Background colour for native views. Nil for High Contrast means
    /// use the system text background unchanged.
    func background(for scheme: ColorScheme) -> Color? {
        let d = scheme == .dark
        switch self {
        case .highContrast: return nil
        case .sepia:        return Color(hexCode: d ? "#393329" : "#eee2cc")
        case .grey:         return Color(hexCode: d ? "#3f3f3f" : "#dddddd")
        case .gentle:       return Color(hexCode: d ? "#353534" : "#ffffff")
        case .lowContrast:  return Color(hexCode: d ? "#222221" : "#dcdddc")
        case .warm:         return Color(hexCode: d ? "#3d3633" : "#f5ecdc")
        case .warmStrong:   return Color(hexCode: d ? "#26201e" : "#c3ad9b")
        case .cool:         return Color(hexCode: d ? "#2b3e4f" : "#d8e1ea")
        case .coolStrong:   return Color(hexCode: d ? "#2c3840" : "#b7c4cf")
        case .cream:        return Color(hexCode: d ? "#1a1a0a" : "#fffdd0")
        case .softPeach:    return Color(hexCode: d ? "#2c1810" : "#ffe4c4")
        case .irlenYellow:  return Color(hexCode: d ? "#1a1a00" : "#fffff0")
        case .irlenGreen:   return Color(hexCode: d ? "#0d2d0d" : "#d8f5d8")
        case .irlenPurple:  return Color(hexCode: d ? "#1f0d2d" : "#e8d9f0")
        case .macular:      return Color(hexCode: d ? "#333300" : "#ffff00")
        case .night:        return Color(hexCode: d ? "#1a1209" : "#faf5e4")
        case .solarized:    return Color(hexCode: d ? "#002b36" : "#fdf6e3")
        }
    }

    /// Text colour for native views. Nil for High Contrast means use the
    /// system label colour unchanged.
    func textColor(for scheme: ColorScheme) -> Color? {
        let d = scheme == .dark
        switch self {
        case .highContrast: return nil
        case .sepia:        return Color(hexCode: d ? "#ede3d3" : "#32281d")
        case .grey:         return Color(hexCode: d ? "#dddddd" : "#272727")
        case .gentle:       return Color(hexCode: d ? "#aeaeae" : "#666666")
        case .lowContrast:  return Color(hexCode: d ? "#7b7a79" : "#585958")
        case .warm:         return Color(hexCode: d ? "#f9f9f8" : "#494742")
        case .warmStrong:   return Color(hexCode: d ? "#ffffff" : "#26231f")
        case .cool:         return Color(hexCode: d ? "#b1bbc0" : "#575a5d")
        case .coolStrong:   return Color(hexCode: d ? "#b1b9be" : "#37536b")
        case .cream:        return Color(hexCode: d ? "#fffdd0" : "#1a1a2e")
        case .softPeach:    return Color(hexCode: d ? "#ffe4c4" : "#2c1810")
        case .irlenYellow:  return Color(hexCode: d ? "#fffff0" : "#1a1a1a")
        case .irlenGreen:   return Color(hexCode: d ? "#d8f5d8" : "#0d2d0d")
        case .irlenPurple:  return Color(hexCode: d ? "#e8d9f0" : "#1f0d2d")
        case .macular:      return Color(hexCode: d ? "#ffff00" : "#000000")
        case .night:        return Color(hexCode: d ? "#d4b896" : "#2d1a0d")
        case .solarized:    return Color(hexCode: d ? "#839496" : "#657b83")
        }
    }
}

/// Assembles the full CSS the reader injects: links in the body colour
/// (never browser blue), the user's chosen body and heading fonts, images
/// scaled to the text column (a natural-size image would overflow it,
/// glaringly in full screen), then the theme's colours. One string so theme
/// and fonts switch together, live.
enum ReaderStyle {
    // One source of truth for the default faces: AppFonts (shared with
    // the visionOS target).
    static let defaultBodyFont = AppFonts.defaultBodyFamily
    static let defaultHeadingFont = AppFonts.defaultHeadingFamily

    static func css(bodyFont: String, headingFont: String, theme: ReaderTheme) -> String {
        """
        a, a:link, a:visited { color: inherit; }
        body { font-family: \(family(bodyFont, fallback: "'Times New Roman', Times, serif")); }
        h1, h2, h3, h4, h5, h6 { font-family: \(family(headingFont, fallback: "Georgia, serif")); }
        dfn { font-style: inherit; border-bottom: none; }
        a[role="doc-glossref"], a[data-glossary-id] { text-decoration: none; cursor: text; }
        img { max-width: 100%; height: auto; }
        figure { margin-left: 0; margin-right: 0; }
        \(theme.css)
        """
    }

    private static func family(_ name: String, fallback: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : "\"\(trimmed)\", \(fallback)"
    }
}

// AppFonts — the reader's chosen faces — lives in AppFonts.swift,
// shared with the visionOS target.

/// The rendered EPUB with its chrome: a thin bar naming the book and the
/// way back. The Visual-Meta toggle lives inline in the page itself (a
/// centered button where the appendix sits), not up here.
struct EPUBReaderScreen: View {
    @AppStorage(AppSettings.readerThemeKey) private var themeRaw = ReaderTheme.highContrast.rawValue
    @AppStorage(AppSettings.readerBodyFontKey) private var bodyFont = ReaderStyle.defaultBodyFont
    @AppStorage(AppSettings.readerHeadingFontKey) private var headingFont = ReaderStyle.defaultHeadingFont
    /// The foot's mode words: Faithful is the WebView rendering; the
    /// rest are the native reading styles (OrigamiReadingView).
    @AppStorage("readerMode") private var readerModeRaw = EPUBReaderMode.faithful.rawValue
    @Environment(AppModel.self) private var model
    let book: OpenEPUB
    var onClose: () -> Void

    private var theme: ReaderTheme { ReaderTheme(rawValue: themeRaw) ?? .highContrast }

    /// Whether this book explicitly is a transcript — only then does
    /// the foot offer the Transcript mode. (The structured document is
    /// cached per book, so the check costs one import at most.)
    private var isTranscriptBook: Bool {
        guard let doc = model.readingDoc(forBook: book) else { return false }
        return doc.documentType == LiquidDoc.DocumentType.transcript.rawValue
            || (doc.body ?? []).contains { $0.speaker != nil }
    }

    private var availableModes: [EPUBReaderMode] {
        // Full Width (.scroll) is nested inside the Default group bracket,
        // not shown as a standalone mode word. Outline mode is also hidden
        // (its group appears inline beside Default).
        EPUBReaderMode.allCases.filter {
            $0 != .outline && $0 != .scroll && ($0 != .transcript || isTranscriptBook)
        }
    }

    private var readerMode: EPUBReaderMode {
        let mode = EPUBReaderMode(rawValue: readerModeRaw) ?? .faithful
        // A transcript mode left over from a transcript book falls back
        // to the book's own pages here.
        if mode == .transcript, !isTranscriptBook { return .faithful }
        return mode
    }

    private var readerCSS: String {
        ReaderStyle.css(bodyFont: bodyFont, headingFont: headingFont, theme: theme)
    }

    // MARK: Chapters (the whole spine, for plain chaptered books)

    @State private var chapterIndex = 0
    /// Bumped per table-of-contents jump so the same fragment can be
    /// revisited; the view scrolls when the stamp changes.
    @State private var requestedFragment: String?
    @State private var fragmentStamp = 0
    /// The scroll fraction to restore once, when reopening where the
    /// reader left off.
    @State private var initialFraction: Double?
    @State private var showsContents = false
    @State private var tocEntries: [OrigamiEPUBImporter.TOCEntry] = []
    /// The selection a comment is being written for; non-nil shows the sheet.
    @State private var commentSelection: ReaderSelection?
    /// The citation whose card is up — the same card the native styles
    /// show, over the faithful page.
    @State private var citationCard: FaithfulCitation?

    private struct FaithfulCitation: Identifiable {
        let key: String
        var id: String { key }
    }

    // MARK: Find in the book (⌘F, ⌘G, ⇧⌘G)

    @State private var showsFind = false
    @State private var findText = ""
    /// Bumped per step; the direction rides beside it. Whichever
    /// presentation is up answers — the WebView's own find, or the
    /// native styles' paragraph search.
    @State private var findStamp = 0
    @State private var findForward = true
    @FocusState private var findFocused: Bool

    private var findBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find in book", text: $findText)
                .textFieldStyle(.plain)
                .focused($findFocused)
                .onSubmit { stepFind(forward: true) }
            Button {
                stepFind(forward: false)
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.plain)
            .disabled(findText.isEmpty)
            .help("Previous match (⇧⌘G)")
            Button {
                stepFind(forward: true)
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.plain)
            .disabled(findText.isEmpty)
            .help("Next match (⌘G)")
            Button {
                closeFind()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Done")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func stepFind(forward: Bool) {
        guard !findText.isEmpty else { return }
        findForward = forward
        findStamp += 1
    }

    /// The words selected in the reading right now — the paragraphs
    /// are AppKit text views, so the key window's first responder
    /// carries the selection. Nil when nothing is selected.
    private func selectedReadingText() -> String? {
        guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView else {
            return nil
        }
        let range = textView.selectedRange()
        guard range.length > 0, range.location != NSNotFound,
              range.location + range.length <= (textView.string as NSString).length
        else { return nil }
        let selected = (textView.string as NSString).substring(with: range)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return selected.isEmpty ? nil : selected
    }

    private func closeFind() {
        showsFind = false
        findText = ""
        findStamp += 1   // an empty find clears the page's highlights
        // Closing Find also closes a standing find-fold: the reading
        // unfolds to where it stood.
        if model.readerFindFoldTerm != nil {
            model.readerFindFoldTerm = nil
            model.readerFoldLevel = 0
        }
    }

    private var chapters: [URL] {
        book.chapters.isEmpty ? [book.content] : book.chapters
    }

    private var currentContent: URL {
        chapters[max(0, min(chapterIndex, chapters.count - 1))]
    }

    /// A content URL as the folder-relative subpath the importer and the
    /// reading-position store both speak.
    private func subpath(of url: URL) -> String {
        url.path.replacingOccurrences(of: book.base.path + "/", with: "")
    }

    var body: some View {
        VStack(spacing: 0) {
            // No top strip: the article opens straight onto its own
            // title. Contents and chapter stepping live in the foot
            // bar's contents popover; the way back to the library is
            // the sidebar (or ⌘L), never a close button.
            if showsFind {
                findBar
            }
            if let kind = model.readingAnalysisKind {
                // An AI reading takes the whole page; the foot stays,
                // so the way back is one click on any word.
                ReadingAnalysisScreen(kind: kind)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        ReadingFootBar(modes: availableModes,
                                       outlineAvailable: model.readingDoc(forBook: book) != nil)
                    }
            } else if readerMode == .faithful {
                faithfulReader
            } else if let doc = model.readingDoc(forBook: book) {
                // A native reading style over the book's structured
                // body — the OrigamiReadingView carries the foot bar,
                // the folding, and the Aa menu itself.
                OrigamiReadingView(doc: doc,
                                   findText: showsFind ? findText : "",
                                   findStamp: findStamp,
                                   findForward: findForward)
                    .id(book.id)
            } else {
                // The package would not read back as a structured
                // document: the faithful rendering stands.
                faithfulReader
            }
        }
        // ⌘F, ⌘G, and ⇧⌘G land here from the View menu's counters.
        .onChange(of: model.readerFindShow) {
            // ⌘F over a live selection IS the search: no typing — the
            // reading folds at once to its headings with the full
            // sentences carrying the selected words, each highlighted.
            if let selected = selectedReadingText() {
                model.showFindFold(term: selected)
            } else {
                showsFind = true
                findFocused = true
            }
        }
        .onChange(of: model.readerFindNext) {
            if showsFind { stepFind(forward: true) } else { showsFind = true; findFocused = true }
        }
        .onChange(of: model.readerFindPrevious) {
            if showsFind { stepFind(forward: false) } else { showsFind = true; findFocused = true }
        }
        // The AI panel's names and keywords land here: each click asks
        // Find to run on those very words.
        .onChange(of: model.readerFindRequest) {
            guard let request = model.readerFindRequest else { return }
            findText = request.text
            showsFind = true
            findForward = true
            findStamp += 1
        }
        // ContentView gives EPUBReaderScreen a .id(epub.id) so SwiftUI
        // recreates the view on every new book or paper — onChange would
        // never fire because each instance only ever sees its own book.
        // onAppear fires on every (re)creation, which is the right moment.
        .onAppear {
            readerModeRaw = EPUBReaderMode.faithful.rawValue
        }
        // A find-fold landing has shown its matches; the highlight
        // fades and the find bar folds away.
        .onChange(of: model.readerFindClear) {
            withAnimation(.easeInOut(duration: 0.6)) {
                showsFind = false
                findText = ""
                findStamp += 1
            }
        }
        .sheet(item: $commentSelection) { selection in
            ReaderCommentSheet(selection: selection) { note in
                model.addComment(note, on: selection)
            }
        }
        .sheet(item: $citationCard) { citation in
            // The same card the native styles show — the book's
            // structured document supplies the reference pool, or the
            // Visual-Meta pool alone when the body will not parse.
            if let doc = model.citationCardDoc(forBook: book) {
                CitationCardSheet(doc: doc, key: citation.key)
            } else {
                Text("The reference could not be read from this book.")
                    .foregroundStyle(.secondary)
                    .padding(30)
            }
        }
        .task(id: book.id) {
            // A fresh book: start where the reader left off — unless it was
            // opened by following a quote link, in which case land on the
            // linked paragraph's chapter instead.
            chapterIndex = 0
            requestedFragment = nil
            initialFraction = nil
            tocEntries = []
            if let fragment = model.pendingReaderFragment, !fragment.isEmpty {
                if chapters.count > 1, let index = chapterIndex(containing: fragment) {
                    chapterIndex = index
                }
                return
            }
            guard let position = model.readingPosition(forFolder: book.id) else { return }
            if let stored = position.chapter,
               let index = chapters.firstIndex(where: { subpath(of: $0) == stored }) {
                chapterIndex = index
            }
            if position.fraction > 0.01 { initialFraction = position.fraction }
        }
    }

    /// The faithful rendering: the EPUB's own pages in the WebView, the
    /// mode words at the foot so the native styles are one click away.
    private var faithfulReader: some View {
        EPUBReaderView(
            book: book,
            css: readerCSS,
            content: currentContent,
            chapterIndex: chapterIndex,
            chapterCount: chapters.count,
            onChapterStep: { delta in step(by: delta) },
            annotations: paintedAnnotations,
            annotationsStamp: model.annotationsStamp,
            onHighlight: { selection in model.addHighlight(on: selection) },
            onAnnotate: { kind, selection in model.addTag(kind, on: selection) },
            onAddComment: { selection in commentSelection = selection },
            onRemoveAnnotation: { id in model.removeAnnotation(id: id) },
            // Step 0 substrate: for now, clicking a semantic element
            // names it and selecting text records the selection. Real
            // behaviours (furl/unfurl, select-and-act) plug in here next.
            onActivate: { ref in
                model.showNote("\(ref.kind.capitalized)\(ref.id.isEmpty ? "" : " · \(ref.id)")")
            },
            onSelect: { text in
                model.lastEPUBSelection = text
            },
            onCopyQuote: { text in copyAsQuote(text) },
            glossaryDefinition: { text in model.glossaryDefinition(matching: text) },
            onFollowLink: { address, fragment in
                model.openEPUB(address: address, fragment: fragment)
            },
            resolveTransclusion: { address, fragment in
                model.transcludedText(forAddress: address, fragment: fragment)
            },
            resolveEndnote: { id in model.endnoteText(inBook: book, id: id) },
            onCitation: { key, ref in
                // An internal citation carries its address (typed rel and
                // #fragment included): when the cited book is here, follow
                // it. Everything else answers with the card.
                if !ref.isEmpty {
                    var address = ref
                    var fragment: String?
                    if let hash = address.firstIndex(of: "#") {
                        fragment = String(address[address.index(after: hash)...])
                        address = String(address[..<hash])
                    }
                    if let colon = address.firstIndex(of: ":"),
                       !address[..<colon].contains(".") {
                        address = String(address[address.index(after: colon)...])
                    }
                    if model.epubRecord(forAddress: address) != nil {
                        model.openEPUB(address: address, fragment: fragment)
                        return
                    }
                }
                let key = key.isEmpty ? ref : key
                if !key.isEmpty { citationCard = FaithfulCitation(key: key) }
            },
            initialFragment: model.pendingReaderFragment,
            requestedFragment: requestedFragment,
            fragmentStamp: fragmentStamp,
            initialScrollFraction: initialFraction,
            onProgress: { fraction in
                model.saveReadingPosition(forFolder: book.id,
                                          chapter: subpath(of: currentContent),
                                          fraction: fraction)
            },
            onCitationAnchors: { anchors in
                model.openDocCitationAnchors = anchors
            },
            findText: showsFind ? findText : "",
            findStamp: findStamp,
            findForward: findForward)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // The same foot the native styles carry — clicking Full Width
            // (or an Outline shape) leaves the faithful page. The
            // contents button opens the book's own TOC, with the
            // chapter stepper for plain chaptered books.
            ReadingFootBar(modes: availableModes,
                           outlineAvailable: model.readingDoc(forBook: book) != nil,
                           showContents: $showsContents,
                           contents: { AnyView(faithfulContents) })
        }
    }

    /// The faithful page's contents popover — the TOC, and for a plain
    /// chaptered book the chapter stepper — living in the foot bar now
    /// that the top strip is gone.
    private var faithfulContents: some View {
        VStack(spacing: 0) {
            if chapters.count > 1 {
                HStack(spacing: 10) {
                    Button {
                        step(by: -1)
                    } label: {
                        Label("Previous Chapter", systemImage: "chevron.left")
                    }
                    .disabled(chapterIndex == 0)
                    .help("Previous chapter")
                    Text("\(chapterIndex + 1) / \(chapters.count)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Button {
                        step(by: 1)
                    } label: {
                        Label("Next Chapter", systemImage: "chevron.right")
                    }
                    .disabled(chapterIndex >= chapters.count - 1)
                    .help("Next chapter")
                }
                .labelStyle(.iconOnly)
                .padding(8)
                Divider()
            }
            ReaderContentsList(entries: tocEntries,
                               currentSubpath: subpath(of: currentContent)) { entry in
                showsContents = false
                open(entry)
            }
        }
        .onAppear {
            if tocEntries.isEmpty { loadContents() }
        }
    }

    /// The open book's sidecar annotations, flattened to what the page
    /// script paints: the stable fragment id, the exact words, the note.
    private var paintedAnnotations: [PaintedAnnotation] {
        _ = model.annotationsStamp   // repaint when annotations change
        return model.annotations(forBook: book).map { annotation in
            var fragment: String?
            var exact = ""
            for selector in annotation.target.selectors {
                switch selector {
                case .fragment(let value, _): fragment = fragment ?? value
                case .quote(let words, _, _): if exact.isEmpty { exact = words }
                case .position, .progression: break
                }
            }
            let kind = ReaderAnnotationKind.kind(of: annotation)
            return PaintedAnnotation(
                id: annotation.id,
                fragment: fragment,
                exact: exact,
                note: annotation.body?.value,
                kind: annotation.motivation == WebAnnotation.Motivation.commenting
                    ? "comment" : "highlight",
                colorHex: AnnotationKindStyle.hex(of: kind ?? .highlight),
                strike: kind == .strikethrough)
        }
    }

    private func step(by delta: Int) {
        let next = chapterIndex + delta
        guard chapters.indices.contains(next) else { return }
        chapterIndex = next
        requestedFragment = nil
        initialFraction = nil
    }

    private func loadContents() {
        let spine = OrigamiEPUBImporter.BookSpine(
            chapters: chapters.map { subpath(of: $0) },
            nav: book.nav.map { subpath(of: $0) })
        tocEntries = OrigamiEPUBImporter.tocEntries(inUnpackedFolder: book.base, spine: spine)
    }

    private func open(_ entry: OrigamiEPUBImporter.TOCEntry) {
        if let index = chapters.firstIndex(where: { subpath(of: $0) == entry.subpath }) {
            chapterIndex = index
        }
        initialFraction = nil
        requestedFragment = entry.fragment
        fragmentStamp += 1
    }

    /// The chapter whose content document carries the element — how a quote
    /// link lands in the right chapter of a plain chaptered book.
    private func chapterIndex(containing fragment: String) -> Int? {
        chapters.firstIndex { url in
            guard let html = try? String(contentsOf: url, encoding: .utf8) else { return false }
            return html.contains("id=\"\(fragment)\"") || html.contains("data-id=\"\(fragment)\"")
        }
    }

    /// Builds the citation from the selection and the open book's stored
    /// metadata, then writes it to the clipboard as pure BibTeX — the
    /// same "Copy as Quote" that the document reader offers, reachable
    /// in the EPUB's own context menu. The address is the book's Origami
    /// id; paragraph-scoped fragments are a later step.
    private func copyAsQuote(_ text: String) {
        guard !text.isEmpty else { return }
        let record = model.epubRecords.first { $0.folder == book.id }
        let address = record?.id ?? book.id
        let citation = OrigamiCitation(
            to: address,
            fragment: nil,
            rel: "cites",
            quotedText: text,
            author: record?.author ?? "",
            year: record?.dateISO.map { String($0.prefix(4)) } ?? "",
            bibtex: OrigamiReading.bibTeXEntry(
                title: record?.title ?? book.title,
                author: record?.author ?? "",
                year: record?.dateISO.map { String($0.prefix(4)) },
                publication: record?.publication,
                quote: text,
                annotation: model.documentAnnotation(forAddress: address)?.body?.value,
                address: address,
                sourceFile: record?.originalFilename),
            documentTitle: record?.title ?? book.title,
            documentFilename: record?.originalFilename)
        CitationClipboard.write(citation)
        model.showNote("Copied citation to clipboard")
    }
}

/// Renders an EPUB's own `paper.html` + `style.css` in a `WKWebView` —
/// headings, sub-headings, images, tables, lists, and formatting exactly as
/// authored. The Visual-Meta appendix starts hidden, with a centered
/// "Metadata" button injected inline in the page to reveal it.
struct EPUBReaderView: NSViewRepresentable {
    let book: OpenEPUB
    /// The reader styling (link colour, fonts, theme colours) as one CSS
    /// string, injected over the EPUB's own stylesheet.
    var css: String = ""
    /// The content document to render — the current chapter. Defaults to
    /// the book's first spine document.
    var content: URL? = nil
    /// Where the current chapter sits in the spine, for the in-page
    /// Previous/Next buttons a chaptered book gets at the page's end.
    var chapterIndex: Int = 0
    var chapterCount: Int = 1
    /// The reader stepped chapters from within the page (±1).
    var onChapterStep: (Int) -> Void = { _ in }
    /// The book's annotations, painted over the words with the CSS Custom
    /// Highlight API — the page's DOM is never modified.
    var annotations: [PaintedAnnotation] = []
    /// Bumped when annotations change, so the painting re-runs.
    var annotationsStamp: Int = 0
    /// "Highlight" was chosen from the context menu, on this selection.
    var onHighlight: (ReaderSelection) -> Void = { _ in }
    /// An Annotate kind was chosen from the context menu, on this selection.
    var onAnnotate: (ReaderAnnotationKind, ReaderSelection) -> Void = { _, _ in }
    /// "Add Comment…" was chosen from the context menu, on this selection.
    var onAddComment: (ReaderSelection) -> Void = { _ in }
    /// The reader asked to remove an annotation (from its click-popover).
    var onRemoveAnnotation: (String) -> Void = { _ in }
    /// A semantic element was clicked (Step 0 bridge).
    var onActivate: (EPUBElementRef) -> Void = { _ in }
    /// The reader's text selection changed (empty string when cleared).
    var onSelect: (String) -> Void = { _ in }
    /// "Copy as Quote" was chosen from the page's context menu, carrying the
    /// selected text. The screen builds the citation from the book's metadata.
    var onCopyQuote: (String) -> Void = { _ in }
    /// Resolves selected text to the open book's glossary entry (name and
    /// description), for the context menu's "Show Definition".
    var glossaryDefinition: (String) -> (name: String, description: String)? = { _ in nil }
    /// A cross-document quote link was clicked — its target address and the
    /// paragraph fragment, if any. The "live" half of a quote link.
    var onFollowLink: (_ address: String, _ fragment: String?) -> Void = { _, _ in }
    /// Resolves a quote link to its source passage for inline transclusion.
    var resolveTransclusion: (_ address: String, _ fragment: String?) -> String? = { _, _ in nil }
    /// Resolves an endnote dagger's id to the note's words — Author's
    /// inline notes as stretchtext, unfolding in place.
    var resolveEndnote: (String) -> String? = { _ in nil }
    /// A citation was clicked: its key (`data-citation-id`) and the
    /// full-resolution reference (`data-origami-ref`, empty when the
    /// citation is external). The screen answers with the citation card.
    var onCitation: (_ key: String, _ ref: String) -> Void = { _, _ in }
    /// A paragraph to scroll to and flash once this book finishes loading —
    /// set when the reader was opened by following a quote link.
    var initialFragment: String? = nil
    /// A fragment to scroll to on demand (a table-of-contents jump); the
    /// stamp distinguishes repeated jumps to the same fragment.
    var requestedFragment: String? = nil
    var fragmentStamp: Int = 0
    /// The scroll fraction to restore once the first page finishes loading —
    /// reopening where the reader left off.
    var initialScrollFraction: Double? = nil
    /// The page's scroll position changed (throttled), as a 0–1 fraction —
    /// the reading-position memory's feed.
    var onProgress: (Double) -> Void = { _ in }
    /// The inline citation anchors found on the current page changed —
    /// called after load and after each scroll. The visionOS hallway reads
    /// this to draw lines from `[N]` markers to their hallway cards.
    var onCitationAnchors: ([InlineCitationAnchor]) -> Void = { _ in }
    /// Find in the page: each stamp steps to the next (or previous)
    /// match of the text, WebKit's own find doing the walking. An
    /// empty text clears the search.
    var findText: String = ""
    var findStamp: Int = 0
    var findForward: Bool = true

    /// The message channel name the injected bridge posts to.
    private static let bridgeName = "origami"

    /// Installs the document scripts: theme + appendix-hide before paint,
    /// then the metadata toggle button, the stretchtext toggler (before the
    /// bridge, so a marker click never doubles as a Step 0 activation), the
    /// Step 0 semantic bridge, and the quote-link enhancer.
    private static func installUserScripts(into controller: WKUserContentController, themeCSS: String) {
        controller.addUserScript(WKUserScript(source: themeScript(css: themeCSS),
                                              injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(source: hideScript,
                                              injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(source: toggleButtonScript,
                                              injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(source: glossaryScript,
                                              injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        // The endnote daggers' listener must register before the
        // stretchtext script's in-page-link handler, so a dagger click
        // unfolds its note instead of jumping (or navigating away to
        // the backmatter chapter).
        controller.addUserScript(WKUserScript(source: endnoteScript,
                                              injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(source: stretchtextScript,
                                              injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        // Citations answer with their card, as in Knowledge Space — the
        // listener registers before the bridge's, so a click never
        // doubles as a Step 0 activation or a jump to the References.
        controller.addUserScript(WKUserScript(source: citationScript,
                                              injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(source: citationAnchorScript,
                                              injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        // The annotation script's click listener must register before the
        // bridge's, so a click on a highlight opens its popover instead of
        // doubling as a Step 0 activation.
        controller.addUserScript(WKUserScript(source: annotationScript,
                                              injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(source: bridgeScript,
                                              injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(source: quoteLinkScript,
                                              injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(source: progressScript,
                                              injectionTime: .atDocumentEnd, forMainFrameOnly: true))
    }

    func makeNSView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        Self.installUserScripts(into: controller, themeCSS: css)
        controller.add(context.coordinator, name: Self.bridgeName)
        context.coordinator.themeCSS = css

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = ReaderWebView(frame: .zero, configuration: configuration)
        // Prevent the native WKWebView layer from flashing white during
        // full-screen transitions. The page CSS controls the visible
        // background; making the view transparent lets the SwiftUI themed
        // background show through during any repaint gap.
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        webView.allowsBackForwardNavigationGestures = false
        webView.navigationDelegate = context.coordinator
        // The subclass owns the page's context menu; it calls back through
        // the coordinator so the latest closure (and book) is always used.
        webView.onCopyQuote = { [weak coordinator = context.coordinator] text in
            coordinator?.onCopyQuote(text)
        }
        webView.resolveDefinition = { [weak coordinator = context.coordinator] text in
            coordinator?.glossaryDefinition(text)
        }
        webView.onHighlight = { [weak coordinator = context.coordinator] selection in
            coordinator?.onHighlight(selection)
        }
        webView.onAnnotate = { [weak coordinator = context.coordinator] kind, selection in
            coordinator?.onAnnotate(kind, selection)
        }
        webView.onAddComment = { [weak coordinator = context.coordinator] selection in
            coordinator?.onAddComment(selection)
        }
        webView.onRemoveAnnotation = { [weak coordinator = context.coordinator] id in
            coordinator?.onRemoveAnnotation(id)
        }
        context.coordinator.webView = webView
        context.coordinator.pendingFragment = initialFragment
        context.coordinator.pendingScrollFraction = initialScrollFraction
        if initialScrollFraction != nil { context.coordinator.restoredBookID = book.id }
        context.coordinator.handledFragmentStamp = fragmentStamp
        load(into: webView, context: context)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onActivate = onActivate
        coordinator.onSelect = onSelect
        coordinator.onCopyQuote = onCopyQuote
        coordinator.glossaryDefinition = glossaryDefinition
        coordinator.onFollowLink = onFollowLink
        coordinator.resolveTransclusion = resolveTransclusion
        coordinator.resolveEndnote = resolveEndnote
        coordinator.onCitation = onCitation
        coordinator.onHighlight = onHighlight
        coordinator.onAnnotate = onAnnotate
        coordinator.onAddComment = onAddComment
        coordinator.onRemoveAnnotation = onRemoveAnnotation
        coordinator.onChapterStep = onChapterStep
        coordinator.onProgress = onProgress
        coordinator.onCitationAnchors = onCitationAnchors
        coordinator.annotations = annotations
        coordinator.chapterIndex = chapterIndex
        coordinator.chapterCount = chapterCount
        if coordinator.loadedID != (content ?? book.content).path {
            coordinator.themeCSS = css
            // A chapter change scrolls to the TOC's fragment; a book change
            // to the quote link's. A restored position applies once, to the
            // first page of a freshly opened book.
            coordinator.pendingFragment = requestedFragment ?? initialFragment
            coordinator.pendingScrollFraction =
                coordinator.openedBookID == book.id ? nil : initialScrollFraction
            coordinator.handledFragmentStamp = fragmentStamp
            load(into: webView, context: context)
            return
        }
        // The restored reading position can arrive after the first load
        // (the screen's task sets it asynchronously): apply it once, live
        // when the page is up, at load's end otherwise.
        if let fraction = initialScrollFraction, coordinator.restoredBookID != book.id {
            coordinator.restoredBookID = book.id
            if coordinator.finishedLoadID == coordinator.loadedID {
                webView.evaluateJavaScript(
                    "if (window.origamiScrollToFraction) window.origamiScrollToFraction(\(fraction));")
            } else {
                coordinator.pendingScrollFraction = fraction
            }
        }
        // A table-of-contents jump within the loaded chapter: scroll live.
        if fragmentStamp != coordinator.handledFragmentStamp {
            coordinator.handledFragmentStamp = fragmentStamp
            if let fragment = requestedFragment, !fragment.isEmpty {
                coordinator.scrollToFragment(fragment, in: webView)
            }
        }
        // Find: each stamp is one step through the matches.
        if findStamp != coordinator.handledFindStamp {
            coordinator.handledFindStamp = findStamp
            if !findText.isEmpty {
                let configuration = WKFindConfiguration()
                configuration.backwards = !findForward
                configuration.caseSensitive = false
                configuration.wraps = true
                webView.find(findText, configuration: configuration) { _ in }
            }
        }
        // Annotations changed while the page is up: repaint, no reload.
        if annotationsStamp != coordinator.paintedStamp {
            coordinator.paintedStamp = annotationsStamp
            coordinator.paintAnnotations(in: webView)
        }
        // A theme or font change: re-inject the style live, no reload, so the
        // reader's scroll position holds.
        if coordinator.themeCSS != css {
            coordinator.themeCSS = css
            let controller = webView.configuration.userContentController
            controller.removeAllUserScripts()
            Self.installUserScripts(into: controller, themeCSS: css)
            webView.evaluateJavaScript(Self.themeScript(css: css))
        }
    }

    private func load(into webView: WKWebView, context: Context) {
        context.coordinator.onActivate = onActivate
        context.coordinator.onSelect = onSelect
        context.coordinator.annotations = annotations
        context.coordinator.paintedStamp = annotationsStamp
        context.coordinator.chapterIndex = chapterIndex
        context.coordinator.chapterCount = chapterCount
        context.coordinator.openedBookID = book.id
        context.coordinator.loadedID = (content ?? book.content).path
        webView.loadFileURL(content ?? book.content, allowingReadAccessTo: book.base)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var loadedID: String?
        /// The book the current load belongs to — a chapter step within one
        /// book keeps it, so the restored scroll position applies only once.
        var openedBookID: String?
        var themeCSS: String = ""
        var onActivate: (EPUBElementRef) -> Void = { _ in }
        var onSelect: (String) -> Void = { _ in }
        var onCopyQuote: (String) -> Void = { _ in }
        var glossaryDefinition: (String) -> (name: String, description: String)? = { _ in nil }
        var onFollowLink: (_ address: String, _ fragment: String?) -> Void = { _, _ in }
        var resolveTransclusion: (_ address: String, _ fragment: String?) -> String? = { _, _ in nil }
        var resolveEndnote: (String) -> String? = { _ in nil }
        var onCitation: (_ key: String, _ ref: String) -> Void = { _, _ in }
        var onHighlight: (ReaderSelection) -> Void = { _ in }
        var onAnnotate: (ReaderAnnotationKind, ReaderSelection) -> Void = { _, _ in }
        var onAddComment: (ReaderSelection) -> Void = { _ in }
        var onRemoveAnnotation: (String) -> Void = { _ in }
        var onChapterStep: (Int) -> Void = { _ in }
        var onProgress: (Double) -> Void = { _ in }
        var onCitationAnchors: ([InlineCitationAnchor]) -> Void = { _ in }
        /// A paragraph to scroll to after the current load finishes, consumed
        /// once. Set when this book was opened by following a quote link.
        var pendingFragment: String?
        /// A scroll fraction to restore after the current load finishes,
        /// consumed once — reopening where the reader left off.
        var pendingScrollFraction: Double?
        /// The book whose stored position has been applied (or scheduled),
        /// so a restore happens once per opened book.
        var restoredBookID: String?
        /// The load that has actually finished, vs `loadedID` which is set
        /// when a load starts.
        var finishedLoadID: String?
        var handledFragmentStamp = 0
        var handledFindStamp = 0
        /// What the page paints, kept current so a fresh load repaints.
        var annotations: [PaintedAnnotation] = []
        var paintedStamp = 0
        var chapterIndex = 0
        var chapterCount = 1
        weak var webView: ReaderWebView?

        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            switch body["event"] as? String {
            case "activate":
                onActivate(EPUBElementRef(
                    kind: body["kind"] as? String ?? "element",
                    id: body["id"] as? String ?? "",
                    text: body["text"] as? String ?? ""))
            case "selection":
                let text = body["text"] as? String ?? ""
                // The subclass reads this when the page's menu opens, to
                // decide whether to offer "Copy as Quote".
                webView?.selectedText = text
                // And the full anchoring ladder, for "Highlight" and
                // "Add Comment…" — the enclosing element's stable id plus
                // disambiguating context either side of the words.
                webView?.currentSelection = text.isEmpty ? nil : ReaderSelection(
                    text: text,
                    fragment: (body["fragment"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                    prefix: (body["prefix"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                    suffix: (body["suffix"] as? String).flatMap { $0.isEmpty ? nil : $0 })
                onSelect(text)
            case "annotation":
                // A click on a painted highlight: show its popover (the
                // comment's words, and the way to remove it).
                guard let id = body["id"] as? String, let webView else { return }
                let note = (body["note"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let x = (body["x"] as? NSNumber)?.doubleValue ?? 0
                let y = (body["y"] as? NSNumber)?.doubleValue ?? 0
                webView.showAnnotation(id: id, note: note, at: NSPoint(x: x, y: y))
            case "chapterStep":
                if let delta = (body["delta"] as? NSNumber)?.intValue { onChapterStep(delta) }
            case "progress":
                if let fraction = (body["fraction"] as? NSNumber)?.doubleValue {
                    onProgress(min(1, max(0, fraction)))
                }
            case "citation":
                onCitation(body["key"] as? String ?? "",
                           body["ref"] as? String ?? "")
            case "citationAnchors":
                guard let raw = body["anchors"] as? [[String: Any]] else { break }
                let anchors: [InlineCitationAnchor] = raw.compactMap { d in
                    guard let id = d["id"] as? String, !id.isEmpty else { return nil }
                    return InlineCitationAnchor(
                        citationID: id,
                        origamiRef: d["ref"]  as? String ?? "",
                        hrefTarget: d["href"] as? String ?? "",
                        normalizedX: (d["nx"] as? NSNumber)?.doubleValue ?? 0,
                        normalizedY: (d["ny"] as? NSNumber)?.doubleValue ?? 0,
                        inView: (d["inView"] as? NSNumber)?.boolValue ?? false)
                }
                onCitationAnchors(anchors)
            case "endnote":
                // A dagger asked for its note's words: resolve the id
                // its href carries and unfold them in place.
                guard let reqID = body["reqId"] as? String,
                      let webView else { return }
                let href = body["href"] as? String ?? ""
                let id = href.firstIndex(of: "#")
                    .map { String(href[href.index(after: $0)...]) } ?? href
                let text = resolveEndnote(id) ?? "The note could not be found."
                webView.evaluateJavaScript(
                    "window.origamiInsertEndnote(\(Self.jsStringLiteral(reqID)), \(Self.jsStringLiteral(text)));")
            case "transclude":
                // The reader asked for the source passage of a quote link.
                // Prefer the live source paragraph; fall back to the quoted
                // words carried in the link itself (its `q` query), so a
                // whole-document link with no fragment still unfurls.
                guard let reqID = body["reqId"] as? String else { return }
                let link = Self.parseOrigamiURL(body["href"] as? String)
                let text = resolveTransclusion(link.address, link.fragment)
                    ?? link.quote
                let payload = text ?? "The quoted document is not in your library."
                let encoded = Self.jsStringLiteral(payload)
                let reqLiteral = Self.jsStringLiteral(reqID)
                webView?.evaluateJavaScript("window.origamiInsertTransclusion(\(reqLiteral), \(encoded));")
            default:
                break
            }
        }

        // MARK: Navigation: quote links live, external links to the browser

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow); return
            }
            let scheme = url.scheme?.lowercased()
            if scheme == "origamitext" {
                let link = Self.parseOrigamiURL(url.absoluteString)
                if !link.address.isEmpty { onFollowLink(link.address, link.fragment) }
                decisionHandler(.cancel); return
            }
            // A clicked web link opens in the user's browser, not in the reader.
            // Exception: the https://origamitext.app/o/ carrier URL is our own
            // identity link — intercept it just like origamitext://.
            if (scheme == "http" || scheme == "https"), navigationAction.navigationType == .linkActivated {
                if let parsed = CitationClipboard.parse(href: url.absoluteString),
                   !parsed.to.isEmpty {
                    onFollowLink(parsed.to, parsed.fragment)
                    decisionHandler(.cancel); return
                }
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel); return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            finishedLoadID = loadedID
            if let fragment = pendingFragment, !fragment.isEmpty {
                pendingFragment = nil
                pendingScrollFraction = nil
                scrollToFragment(fragment, in: webView)
            } else if let fraction = pendingScrollFraction {
                pendingScrollFraction = nil
                webView.evaluateJavaScript(
                    "if (window.origamiScrollToFraction) window.origamiScrollToFraction(\(fraction));")
            }
            paintAnnotations(in: webView)
            injectChapterFooter(in: webView)
            webView.evaluateJavaScript(
                "if (window.origamiFindCitationAnchors) window.origamiFindCitationAnchors();")
        }

        /// Scrolls the loaded page to the element and flashes it once.
        func scrollToFragment(_ fragment: String, in webView: WKWebView) {
            let id = Self.jsStringLiteral(fragment)
            webView.evaluateJavaScript("""
            (function(){
              var key = \(id);
              // A target inside a collapsed stretchtext region: unfold it
              // first, or the scroll would land on a display:none element.
              if (window.origamiRevealStretchtext) { window.origamiRevealStretchtext(key); }
              var el = document.getElementById(key) || document.querySelector('[data-id="' + key + '"]');
              if (!el) return;
              el.scrollIntoView({block:'center'});
              var prior = el.style.backgroundColor;
              el.style.transition = 'background-color 1.2s';
              el.style.backgroundColor = 'rgba(255,214,10,0.45)';
              setTimeout(function(){ el.style.backgroundColor = prior; }, 1600);
            })();
            """)
        }

        /// Paints the book's annotations over the loaded page. Anchors that
        /// belong to other chapters simply find nothing here and stay
        /// unpainted — no chapter bookkeeping needed.
        func paintAnnotations(in webView: WKWebView) {
            let list = annotations.map { annotation -> [String: Any] in
                var item: [String: Any] = ["id": annotation.id,
                                           "exact": annotation.exact,
                                           "kind": annotation.kind,
                                           "color": annotation.colorHex,
                                           "strike": annotation.strike]
                if let fragment = annotation.fragment { item["fragment"] = fragment }
                if let note = annotation.note { item["note"] = note }
                return item
            }
            guard let data = try? JSONSerialization.data(withJSONObject: list),
                  var json = String(data: data, encoding: .utf8) else { return }
            json = json.replacingOccurrences(of: "\u{2028}", with: "\\u2028")
                .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
            webView.evaluateJavaScript(
                "if (window.origamiPaintAnnotations) window.origamiPaintAnnotations(\(json));")
        }

        /// Appends the in-page chapter controls to a chaptered book: a
        /// centered "‹ Previous · Next ›" footer at the document's end, so
        /// paging works in full screen too, where the chrome bar is gone.
        private func injectChapterFooter(in webView: WKWebView) {
            guard chapterCount > 1 else { return }
            let hasPrevious = chapterIndex > 0
            let hasNext = chapterIndex < chapterCount - 1
            webView.evaluateJavaScript("""
            (function(){
              if (document.getElementById('origami-chapter-nav')) return;
              var bridge = window.webkit && window.webkit.messageHandlers
                && window.webkit.messageHandlers.origami;
              if (!bridge) return;
              var nav = document.createElement('div');
              nav.id = 'origami-chapter-nav';
              nav.style.cssText = 'display:flex;justify-content:center;gap:1.5em;'
                + 'margin:3em auto 2em;font:inherit;';
              function button(label, delta){
                var b = document.createElement('button');
                b.type = 'button';
                b.textContent = label;
                b.style.cssText = 'padding:0.4em 1.2em;font:inherit;cursor:pointer;'
                  + 'border:1px solid currentColor;border-radius:6px;'
                  + 'background:transparent;color:inherit;opacity:0.7;';
                b.addEventListener('click', function(){
                  bridge.postMessage({event:'chapterStep', delta: delta});
                });
                return b;
              }
              if (\(hasPrevious)) nav.appendChild(button('\u{2039} Previous Chapter', -1));
              if (\(hasNext)) nav.appendChild(button('Next Chapter \u{203A}', 1));
              document.body.appendChild(nav);
            })();
            """)
        }

        /// Splits `origamitext://open/<address>?q=<quote>#<fragment>` into its
        /// parts: the target address, the paragraph fragment, and the quoted
        /// words the link carries (the `q` query), if any.
        static func parseOrigamiURL(_ string: String?) -> (address: String, fragment: String?, quote: String?) {
            guard let string, let url = URL(string: string),
                  url.scheme?.lowercased() == "origamitext",
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  components.host?.lowercased() == "open"
            else { return ("", nil, nil) }
            let address = String(components.path.drop(while: { $0 == "/" }))
            let quote = components.queryItems?.first(where: { $0.name == "q" })?.value
            return (address, components.fragment, quote?.isEmpty == false ? quote : nil)
        }

        /// A safely-quoted JavaScript string literal.
        static func jsStringLiteral(_ string: String) -> String {
            let escaped = string
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "")
                .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
                .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
            return "\"\(escaped)\""
        }
    }

    /// Injects (or updates) the theme's `<style id="origami-theme">` with the
    /// given CSS. Runs both at document start (before paint) and live on a
    /// theme change. The CSS goes in a template literal — it carries no
    /// backticks or `${`, so it needs no escaping.
    private static func themeScript(css: String) -> String {
        """
        (function(){
          var s = document.getElementById('origami-theme') || document.createElement('style');
          s.id = 'origami-theme';
          s.textContent = `\(css)`;
          (document.head || document.documentElement).appendChild(s);
        })();
        """
    }

    /// Hides the appendix before first paint.
    private static let hideScript = """
    (function(){
      var s = document.getElementById('origami-vm-style') || document.createElement('style');
      s.id = 'origami-vm-style';
      s.textContent = '#visual-meta{display:none;}';
      (document.head || document.documentElement).appendChild(s);
    })();
    """

    /// Inserts a horizontally-centered toggle button in the document flow,
    /// just before the Visual-Meta appendix. Hidden by default, it reads
    /// "Metadata"; revealed, it reads "Hide Metadata".
    private static let toggleButtonScript = """
    (function(){
      var vm = document.getElementById('visual-meta');
      if (!vm || document.getElementById('origami-vm-toggle')) return;
      var btn = document.createElement('button');
      btn.id = 'origami-vm-toggle';
      btn.type = 'button';
      btn.textContent = 'Metadata';
      btn.style.cssText = 'display:block;margin:2em auto;padding:0.4em 1.2em;font:inherit;'
        + 'cursor:pointer;border:1px solid currentColor;border-radius:6px;'
        + 'background:transparent;color:inherit;opacity:0.7;';
      btn.addEventListener('click', function(){
        var hidden = (vm.style.display === 'none' || vm.style.display === '');
        vm.style.display = hidden ? 'block' : 'none';
        btn.textContent = hidden ? 'Hide Metadata' : 'Metadata';
      });
      vm.parentNode.insertBefore(btn, vm);
    })();
    """

    /// Glossary terms are not links. Author exports them as anchors
    /// (`a[epub:type="glossref"]` into the backmatter glossary), and this
    /// app's own EPUBs as `<dfn>` — either way the reader shows plain body
    /// text (see the `dfn`/glossref rules in `ReaderStyle.css`) and a click
    /// goes nowhere: the definition is reached by selecting the words and
    /// choosing Show Definition from the context menu.
    private static let glossaryScript = """
    (function(){
      document.addEventListener('click', function(e){
        var a = e.target.closest
          ? e.target.closest('a[data-glossary-id], a[role="doc-glossref"]') : null;
        if (a) e.preventDefault();
      }, true);
    })();
    """

    /// A citation click answers with its card, as in Knowledge Space —
    /// never a jump down to the References list. The key and the
    /// full-resolution reference (internal citations) go to Swift; the
    /// screen shows the card, or opens the cited book.
    private static let citationScript = """
    (function(){
      var bridge = window.webkit && window.webkit.messageHandlers
        && window.webkit.messageHandlers.origami;
      // Every citation shape a package may carry: this app's exports
      // (class "citation", data-citation-id) and Author's biblioref
      // anchors (data-citation-key, epub:type/role biblioref).
      function isCitation(a){
        if (!a) return false;
        if (a.classList && a.classList.contains('citation')) return true;
        if (a.getAttribute('data-citation-id')) return true;
        if (a.getAttribute('data-citation-key')) return true;
        if ((a.getAttribute('role') || '').indexOf('doc-biblioref') >= 0) return true;
        if ((a.getAttribute('epub:type') || '').indexOf('biblioref') >= 0) return true;
        return false;
      }
      document.addEventListener('click', function(e){
        var a = e.target.closest ? e.target.closest('a') : null;
        if (!isCitation(a)) return;
        e.preventDefault();
        e.stopImmediatePropagation();
        if (!bridge) return;
        bridge.postMessage({event:'citation',
                            key: a.getAttribute('data-citation-id')
                                 || a.getAttribute('data-citation-key') || '',
                            ref: a.getAttribute('data-origami-ref') || ''});
      }, true);
    })();
    """

    /// Locates every inline citation anchor in the document and posts their
    /// normalised document-space positions as a `citationAnchors` message.
    /// Runs once on load, then re-runs 150 ms after each scroll so the
    /// positions stay current as the user moves through the page. Also
    /// exposes `window.origamiFindCitationAnchors()` for Swift to call
    /// explicitly (e.g. after a programmatic scroll-to-fragment).
    private static let citationAnchorScript = """
    (function(){
      var bridge = window.webkit && window.webkit.messageHandlers
        && window.webkit.messageHandlers.origami;
      if (!bridge) return;

      // Recognises the same citation shapes as citationScript, plus
      // EPUB noteref anchors for foreign EPUBs.
      function isCitationAnchor(a) {
        if (!a || a.tagName !== 'A') return false;
        if (a.classList.contains('citation')) return true;
        if (a.getAttribute('data-citation-id')) return true;
        if (a.getAttribute('data-citation-key')) return true;
        if ((a.getAttribute('role') || '').indexOf('doc-biblioref') >= 0) return true;
        if ((a.getAttribute('epub:type') || '').indexOf('biblioref') >= 0) return true;
        return false;
      }

      function scan() {
        var docW = document.documentElement.scrollWidth;
        var docH = document.documentElement.scrollHeight;
        if (!docW || !docH) return;
        var vW = window.innerWidth, vH = window.innerHeight;
        var sX = window.scrollX,   sY = window.scrollY;
        var all = document.querySelectorAll('a');
        var seen = [];
        var results = [];
        for (var i = 0; i < all.length; i++) {
          var a = all[i];
          if (!isCitationAnchor(a) || seen.indexOf(a) >= 0) continue;
          seen.push(a);
          var r = a.getBoundingClientRect();
          var cx = r.left + r.width  / 2;
          var cy = r.top  + r.height / 2;
          results.push({
            id:   a.getAttribute('data-citation-id')
                  || a.getAttribute('data-citation-key')
                  || (a.getAttribute('href') || '').replace(/^#/, ''),
            ref:  a.getAttribute('data-origami-ref') || '',
            href: (a.getAttribute('href') || '').replace(/^#/, ''),
            nx:   (cx + sX) / docW,
            ny:   (cy + sY) / docH,
            inView: r.bottom > 0 && r.top < vH && r.right > 0 && r.left < vW
          });
        }
        bridge.postMessage({event: 'citationAnchors', anchors: results});
      }

      var scrollTimer;
      window.addEventListener('scroll', function() {
        clearTimeout(scrollTimer);
        scrollTimer = setTimeout(scan, 150);
      }, {passive: true});

      window.origamiFindCitationAnchors = scan;
      scan();
    })();
    """

    /// The endnote daggers, made stretchtext: the export's ‡ (a plain
    /// reader's mark) reads here as the format's fold — `[]` closed; a
    /// click unfolds the note in place, `[` standing to the left of the
    /// words and `]` after, every part a click to fold again. Never a
    /// jump to the appendix (or, worse, a navigation off to the
    /// backmatter chapter). The words come from Swift
    /// (`origamiInsertEndnote`), which finds the note by its id in any
    /// of the book's chapters.
    private static let endnoteScript = """
    (function(){
      var bridge = window.webkit && window.webkit.messageHandlers
        && window.webkit.messageHandlers.origami;

      var style = document.getElementById('origami-endnote-style') || document.createElement('style');
      style.id = 'origami-endnote-style';
      style.textContent =
        'a.origami-note-fold{text-decoration:none;cursor:pointer;opacity:0.7;font-style:normal;}'
        + 'a.origami-note-fold:hover{opacity:1;}'
        + 'a.origami-note-fold.open{opacity:1;}'
        + '.origami-note-inline{font-style:italic;cursor:pointer;}'
        + '.origami-note-inline::after{content:"]";font-style:normal;}';
      (document.head || document.documentElement).appendChild(style);

      function isDagger(a){
        if (!a) return false;
        if (a.classList && a.classList.contains('ot-inline-note')) return true;
        if ((a.getAttribute('role') || '').indexOf('doc-noteref') >= 0) return true;
        if ((a.getAttribute('epub:type') || '').indexOf('noteref') >= 0) return true;
        return false;
      }

      // The printed mark (‡, a number) gives way to the fold's []: the
      // note is an offer to stretch the text, not a footnote to chase.
      var daggers = document.querySelectorAll('a');
      Array.prototype.forEach.call(daggers, function(a){
        if (!isDagger(a)) return;
        a.classList.add('origami-note-fold');
        a.textContent = '[]';
      });

      function fold(a){
        var open = a.nextElementSibling;
        if (open && open.classList && open.classList.contains('origami-note-inline')) {
          open.remove();
        }
        a.textContent = '[]';
        a.classList.remove('open');
      }

      var pending = {};
      var counter = 0;
      document.addEventListener('click', function(e){
        // A click anywhere in the unfolded words folds them back.
        var span = e.target.closest ? e.target.closest('.origami-note-inline') : null;
        if (span) {
          e.preventDefault();
          e.stopImmediatePropagation();
          var anchor = span.previousElementSibling;
          if (anchor && isDagger(anchor)) { fold(anchor); } else { span.remove(); }
          return;
        }
        var a = e.target.closest ? e.target.closest('a') : null;
        if (!isDagger(a)) return;
        e.preventDefault();
        e.stopImmediatePropagation();
        if (a.classList.contains('open')) {
          fold(a);   // a second click folds the note back
          return;
        }
        if (!bridge) return;
        counter += 1;
        var reqId = 'note' + counter;
        pending[reqId] = a;
        bridge.postMessage({event:'endnote', href: a.getAttribute('href') || '', reqId: reqId});
      }, true);

      window.origamiInsertEndnote = function(reqId, text){
        var a = pending[reqId];
        delete pending[reqId];
        if (!a) return;
        // Open: the anchor is the [ to the left of the stretched text;
        // the words follow, ] closing them.
        a.textContent = '[';
        a.classList.add('open');
        var span = document.createElement('span');
        span.className = 'origami-note-inline';
        span.textContent = text;
        a.insertAdjacentElement('afterend', span);
      };
    })();
    """

    /// Author's stretchtext (§ "Do Not Expand ››"): a contracted span ships
    /// as an `a.ot-stretchtext` marker in the running text plus a hidden
    /// `aside.ot-stretchtext-content` directly after the enclosing block.
    /// This script makes the marker a live toggle: click (or Space/Enter —
    /// the anchor is `role="button"`) unfolds the aside in place with a
    /// brief fade and swaps the glyph `››` → `‹‹`; again folds it back.
    /// The document is never modified — the `hidden` attribute is the only
    /// state, per-session. `origamiRevealStretchtext(id)` is the shared
    /// unfold-before-landing helper: in-page links (footnote back-refs) and
    /// fragment arrivals whose target sits inside a collapsed region expand
    /// it first, and a future search lands hits the same way. It must run
    /// before the Step 0 bridge so a marker click is a toggle, not an
    /// element activation.
    private static let stretchtextScript = """
    (function(){
      if (!document.querySelector('a.ot-stretchtext')) return;

      // Fallback styling, in case the package's origami.css is absent.
      // `[hidden]` presence is the contract — the exporter writes
      // hidden="hidden", and non-Origami readers show just the marker.
      var style = document.getElementById('origami-stretchtext-style') || document.createElement('style');
      style.id = 'origami-stretchtext-style';
      style.textContent =
        'a.ot-stretchtext{text-decoration:none;cursor:pointer;opacity:0.7;}'
        + 'a.ot-stretchtext:hover{opacity:1;}'
        + 'a.ot-stretchtext[aria-expanded="true"]{opacity:1;}'
        + 'aside.ot-stretchtext-content{margin:0.5em 0 0.5em 1em;border-left:2px solid;padding-left:0.75em;}'
        + 'aside.ot-stretchtext-content[hidden]{display:none;}';
      (document.head || document.documentElement).appendChild(style);

      function asideFor(a){
        var id = a.getAttribute('aria-controls')
          || (a.getAttribute('href') || '').replace(/^#/, '');
        return id ? document.getElementById(id) : null;
      }
      function anchorFor(aside){
        return document.querySelector('a.ot-stretchtext[aria-controls="' + aside.id + '"]')
          || document.querySelector('a.ot-stretchtext[href="#' + aside.id + '"]');
      }
      function expand(a, aside){
        if (!aside.hasAttribute('hidden')) return;
        aside.removeAttribute('hidden');
        if (a) {
          // Keep the original marker text (image contractions read
          // "‹‹ ImageName ››", not just "››") to restore on collapse.
          a.dataset.otMarker = a.textContent;
          a.textContent = '‹‹';
          a.setAttribute('aria-expanded', 'true');
        }
        aside.style.opacity = '0';
        aside.style.transition = 'opacity 0.18s ease-out';
        requestAnimationFrame(function(){ aside.style.opacity = '1'; });
        setTimeout(function(){ aside.style.transition = ''; aside.style.opacity = ''; }, 250);
      }
      function collapse(a, aside){
        if (aside.hasAttribute('hidden')) return;
        aside.setAttribute('hidden', 'hidden');
        if (a) {
          a.textContent = a.dataset.otMarker || '››';
          a.setAttribute('aria-expanded', 'false');
        }
      }
      // Unfolds the collapsed region containing the element with `id` (or
      // `data-id` id), so navigation and search never land on a hidden
      // target. True when something was expanded.
      window.origamiRevealStretchtext = function(id){
        var el = document.getElementById(id) || document.querySelector('[data-id="' + id + '"]');
        if (!el) return false;
        var aside = el.closest('aside.ot-stretchtext-content');
        if (!aside || !aside.hasAttribute('hidden')) return false;
        expand(anchorFor(aside), aside);
        return true;
      };

      document.addEventListener('click', function(e){
        var a = e.target.closest ? e.target.closest('a.ot-stretchtext') : null;
        if (a) {
          // A toggle, never a navigation — and never a Step 0 activation.
          e.preventDefault();
          e.stopImmediatePropagation();
          var aside = asideFor(a);
          if (!aside) return;
          if (aside.hasAttribute('hidden')) expand(a, aside); else collapse(a, aside);
          return;
        }
        // Any in-page link whose target sits inside a collapsed region
        // (footnote back-references): unfold first, then let the default
        // jump land on a now-visible target.
        var link = e.target.closest ? e.target.closest('a[href^="#"]') : null;
        if (link) window.origamiRevealStretchtext(link.getAttribute('href').slice(1));
      }, true);

      // Space activates the marker, per role="button" (Enter already
      // produces a click on an anchor, so only Space needs help).
      document.addEventListener('keydown', function(e){
        if (e.key !== ' ' && e.key !== 'Spacebar') return;
        var a = e.target.closest ? e.target.closest('a.ot-stretchtext') : null;
        if (!a) return;
        e.preventDefault();
        e.stopImmediatePropagation();
        a.click();
      }, true);
    })();
    """

    /// The Step 0 bridge. One delegated click listener classifies the
    /// nearest semantic ancestor by the format's own markup and posts its
    /// kind + id to Swift; a mouseup listener reports any non-empty text
    /// selection. This is the substrate the reader's real interactions
    /// (view specification, stretchtext, select-and-act) will be built on.
    private static let bridgeScript = """
    (function(){
      function classify(el){
        while (el && el !== document.body) {
          var tag = el.tagName ? el.tagName.toLowerCase() : '';
          if (tag === 'math' && el.id) return {kind:'equation', id:el.id};
          if (tag === 'a' && (el.className || '').indexOf('citation') >= 0)
            return {kind:'citation', id: el.getAttribute('data-origami-ref')
              || el.getAttribute('data-citation-id') || el.id || ''};
          // dfn (glossary terms) intentionally not classified: terms read
          // as plain text — the definition is reached by selecting the
          // words and choosing Show Definition, never by a link-like click.
          if (/^h[1-6]$/.test(tag) && el.id) return {kind:'heading', id: el.id};
          if ((tag === 'p' || tag === 'li') && el.id) return {kind:'paragraph', id: el.id};
          el = el.parentElement;
        }
        return null;
      }
      var bridge = window.webkit && window.webkit.messageHandlers
        && window.webkit.messageHandlers.origami;
      if (!bridge) return;
      document.addEventListener('click', function(e){
        var info = classify(e.target);
        if (!info) return;
        var text = (e.target.textContent || '').trim().slice(0, 200);
        bridge.postMessage({event:'activate', kind:info.kind, id:info.id, text:text});
      }, true);
      document.addEventListener('mouseup', function(){
        // Report every mouseup, empty included, so the native "Copy as
        // Quote" item appears only while text is actually selected. A real
        // selection also carries its anchoring ladder: the enclosing
        // element's stable id and up to 32 characters of context either
        // side — what a highlight or comment is anchored to.
        var sel = window.getSelection ? window.getSelection() : null;
        var raw = sel ? String(sel) : '';
        var info = {event:'selection', text: raw.trim().slice(0, 500),
                    fragment:'', prefix:'', suffix:''};
        if (sel && !sel.isCollapsed && raw) {
          var node = sel.anchorNode;
          var el = node ? (node.nodeType === 1 ? node : node.parentElement) : null;
          var host = el && el.closest ? el.closest('[data-id], [id]') : null;
          if (host) info.fragment = host.getAttribute('data-id') || host.id || '';
          var context = (host || document.body || {textContent:''}).textContent || '';
          var at = context.indexOf(raw);
          if (at >= 0) {
            info.prefix = context.slice(Math.max(0, at - 32), at);
            info.suffix = context.slice(at + raw.length, at + raw.length + 32);
          }
        }
        bridge.postMessage(info);
      }, false);
    })();
    """

    /// The annotation painter. `origamiPaintAnnotations(list)` resolves each
    /// annotation with the format's anchoring ladder — the stable element id
    /// first, the exact words within it, a document-wide text search as the
    /// re-anchoring fallback — and paints matches with the CSS Custom
    /// Highlight API, so the page's DOM is never modified. A click on a
    /// painted range reports the annotation to Swift (its popover); the
    /// listener registers before the Step 0 bridge's, so the click never
    /// doubles as an element activation.
    private static let annotationScript = """
    (function(){
      var style = document.getElementById('origami-annotation-style') || document.createElement('style');
      style.id = 'origami-annotation-style';
      (document.head || document.documentElement).appendChild(style);

      var painted = [];

      // The exact words within a container, found across its text nodes
      // (formatting splits them), case-insensitively — the format's span rule.
      function findRange(container, exact){
        if (!container || !exact) return null;
        var walker = document.createTreeWalker(container, NodeFilter.SHOW_TEXT);
        var nodes = [], full = '';
        while (walker.nextNode()) {
          nodes.push({node: walker.currentNode, start: full.length});
          full += walker.currentNode.data;
        }
        var at = full.toLowerCase().indexOf(exact.toLowerCase());
        if (at < 0) return null;
        var end = at + exact.length;
        var range = document.createRange();
        var started = false;
        for (var i = 0; i < nodes.length; i++) {
          var n = nodes[i], len = n.node.data.length;
          if (!started && at >= n.start && at <= n.start + len) {
            range.setStart(n.node, at - n.start);
            started = true;
          }
          if (started && end >= n.start && end <= n.start + len) {
            range.setEnd(n.node, end - n.start);
            return range.collapsed ? null : range;
          }
        }
        return null;
      }

      window.origamiPaintAnnotations = function(list){
        if (typeof Highlight === 'undefined' || !CSS.highlights) return;
        painted = [];
        // The annotated words take their kind's colour in the type
        // itself — one highlight group per colour (and one more for
        // strikethrough), styled as it arrives from Settings.
        var groups = {}, rules = '';
        (list || []).forEach(function(a){
          var host = a.fragment
            ? (document.getElementById(a.fragment)
               || document.querySelector('[data-id="' + a.fragment + '"]'))
            : null;
          // The ladder: words in their element, words anywhere, whole
          // element when the words are gone — degrade, never break.
          var range = findRange(host, a.exact)
            || findRange(document.body, a.exact);
          if (!range && host) {
            range = document.createRange();
            range.selectNodeContents(host);
          }
          if (!range) return;
          var color = a.color || 'E8C51D';
          var key = 'origami-k' + color + (a.strike ? '-s' : '');
          if (!groups[key]) {
            groups[key] = new Highlight();
            rules += '::highlight(' + key + '){'
              + (a.strike
                 ? 'text-decoration:line-through;text-decoration-color:#' + color + ';'
                 : 'color:#' + color + ';')
              + '}';
          }
          groups[key].add(range);
          painted.push({id: a.id, kind: a.kind, note: a.note || '', range: range});
        });
        CSS.highlights.clear();
        Object.keys(groups).forEach(function(key){
          CSS.highlights.set(key, groups[key]);
        });
        style.textContent = rules;
      };

      var bridge = window.webkit && window.webkit.messageHandlers
        && window.webkit.messageHandlers.origami;
      document.addEventListener('click', function(e){
        if (!bridge || !painted.length || !document.caretRangeFromPoint) return;
        // A click that is really a selection gesture is not an annotation tap.
        var sel = window.getSelection ? window.getSelection() : null;
        if (sel && !sel.isCollapsed) return;
        var caret = document.caretRangeFromPoint(e.clientX, e.clientY);
        if (!caret) return;
        for (var i = 0; i < painted.length; i++) {
          var p = painted[i];
          try {
            if (p.range.comparePoint(caret.startContainer, caret.startOffset) === 0) {
              e.preventDefault();
              e.stopImmediatePropagation();
              bridge.postMessage({event:'annotation', id: p.id, kind: p.kind,
                                  note: p.note, x: e.clientX, y: e.clientY});
              return;
            }
          } catch (err) {}
        }
      }, true);
    })();
    """

    /// The reading-position feed: reports the page's scroll fraction
    /// (throttled) so the reader can reopen where it left off, and the
    /// restore half, `origamiScrollToFraction`.
    private static let progressScript = """
    (function(){
      var bridge = window.webkit && window.webkit.messageHandlers
        && window.webkit.messageHandlers.origami;
      window.origamiScrollToFraction = function(f){
        var h = document.documentElement.scrollHeight - window.innerHeight;
        window.scrollTo(0, Math.max(0, h * f));
      };
      if (!bridge) return;
      var timer = null;
      window.addEventListener('scroll', function(){
        if (timer) return;
        timer = setTimeout(function(){
          timer = null;
          var h = document.documentElement.scrollHeight - window.innerHeight;
          var f = h > 0 ? (window.scrollY / h) : 0;
          bridge.postMessage({event:'progress', fraction: Math.max(0, Math.min(1, f))});
        }, 400);
      }, {passive: true});
    })();
    """

    /// The quote-link enhancer. Every `origamitext://` anchor is a live link
    /// (a solid-underlined `(Author, Year)` — clicking it opens the target,
    /// handled by the navigation delegate) followed by a `[]` control that
    /// unfurls the quoted source *inline*, stretchtext-style, between the
    /// brackets. `origamiInsertTransclusion` is the callback Swift evaluates
    /// with the resolved passage.
    private static let quoteLinkScript = """
    (function(){
      var bridge = window.webkit && window.webkit.messageHandlers
        && window.webkit.messageHandlers.origami;

      var style = document.getElementById('origami-quote-style') || document.createElement('style');
      style.id = 'origami-quote-style';
      style.textContent =
        'a.origami-quote{text-decoration:none;cursor:pointer;}'
        + 'a.origami-quote:hover{text-decoration:underline;}'
        + '.origami-stretch{cursor:pointer;opacity:0.7;font-style:normal;}'
        + '.origami-stretch::before{content:"[";font-style:normal;}'
        + '.origami-stretch::after{content:"]";font-style:normal;}'
        + '.origami-stretch.expanded{opacity:1;font-style:italic;}';
      (document.head || document.documentElement).appendChild(style);

      var links = document.querySelectorAll('a[href^="origamitext://"]');
      Array.prototype.forEach.call(links, function(a, i){
        a.classList.add('origami-quote');
        a.setAttribute('data-oq', i);
        // The stretchtext control: renders as "[]" collapsed, "[source]" open.
        var stretch = document.createElement('span');
        stretch.className = 'origami-stretch';
        stretch.setAttribute('data-oq', i);
        stretch.setAttribute('role', 'button');
        stretch.title = 'Show the quoted source';
        stretch.addEventListener('click', function(e){
          e.preventDefault(); e.stopPropagation();
          if (stretch.classList.contains('expanded')) {
            stretch.classList.remove('expanded');
            stretch.textContent = '';
            return;
          }
          var cached = stretch.getAttribute('data-text');
          if (cached !== null) {
            stretch.textContent = cached;
            stretch.classList.add('expanded');
          } else if (bridge) {
            bridge.postMessage({event:'transclude', href:a.getAttribute('href'), reqId:'oq' + i});
          }
        });
        a.insertAdjacentElement('afterend', stretch);
      });

      window.origamiInsertTransclusion = function(reqId, text){
        var i = reqId.replace('oq', '');
        var stretch = document.querySelector('.origami-stretch[data-oq="' + i + '"]');
        if (!stretch) return;
        stretch.setAttribute('data-text', text);
        stretch.textContent = text;
        stretch.classList.add('expanded');
      };
    })();
    """
}

/// The EPUB reader's `WKWebView`, with a context menu we own completely.
/// The rendered page is a real web view with its own AppKit menu, so the
/// SwiftUI `.contextMenu` never reaches it; instead `willOpenMenu` clears
/// WebKit's default items and builds ours from scratch. This is the one
/// place to add, remove, or reorder what appears on ctrl-click in an EPUB.
final class ReaderWebView: WKWebView {
    /// The page's current selection, kept current by the Step 0 bridge's
    /// mouseup reports (see `bridgeScript`).
    var selectedText: String = ""
    /// The selection with its anchoring ladder (enclosing element id and
    /// context), for "Highlight" and "Add Comment…". Nil when nothing is
    /// selected.
    var currentSelection: ReaderSelection?
    /// Invoked with the selected text when "Copy as Quote" is chosen.
    var onCopyQuote: (String) -> Void = { _ in }
    /// Invoked when "Highlight" is chosen on the current selection.
    var onHighlight: (ReaderSelection) -> Void = { _ in }
    /// Invoked when an Annotate kind is chosen on the current selection.
    var onAnnotate: (ReaderAnnotationKind, ReaderSelection) -> Void = { _, _ in }
    /// Invoked when "Add Comment…" is chosen on the current selection.
    var onAddComment: (ReaderSelection) -> Void = { _ in }
    /// Invoked when Remove is chosen in an annotation's popover.
    var onRemoveAnnotation: (String) -> Void = { _ in }
    /// Resolves selected text to the open book's glossary entry, when the
    /// words are a defined concept — what puts "Show Definition" on the menu.
    var resolveDefinition: (String) -> (name: String, description: String)? = { _ in nil }
    /// The entry and click point held between building the menu and the
    /// "Show Definition" item firing.
    private var pendingDefinition: (name: String, description: String)?
    private var menuLocation: NSPoint = .zero
    /// The definition popover, retained while shown (transient: it closes
    /// itself on any outside click).
    private var definitionPopover: NSPopover?

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        // Take full ownership: drop everything WebKit proposes (Reload,
        // Back/Forward, Look Up, …) and show only our own commands.
        menu.removeAllItems()
        // Services, Share, and "Ask Siri" are contextual-menu plug-in items
        // AppKit appends *after* this method returns, so removeAllItems can't
        // reach them. Turning off plug-ins keeps them off the menu.
        menu.allowsContextMenuPlugIns = false

        let text = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            // Selected words the book's glossary defines: the definition
            // leads the menu and pops up in place (glossary terms are
            // deliberately not links — this is the way to a definition).
            menuLocation = convert(event.locationInWindow, from: nil)
            if let entry = resolveDefinition(text) {
                pendingDefinition = entry
                addItem(to: menu, title: "Show Definition", action: #selector(showDefinition(_:)))
            }
            // The reader's own marks: the Annotate vocabulary (after
            // Reader's), or a comment anchored to the words — stored in
            // the book's sidecar, never in the book.
            if currentSelection != nil {
                let annotate = NSMenuItem(title: "Highlight", action: nil, keyEquivalent: "")
                let submenu = NSMenu(title: "Highlight")
                for kind in ReaderAnnotationKind.allCases {
                    // Reader's grouping: Important/Quotable, the
                    // judgments, then Strikethrough on its own.
                    if kind == .great || kind == .strikethrough {
                        submenu.addItem(.separator())
                    }
                    let item = NSMenuItem(title: AnnotationKindStyle.displayName(of: kind),
                                          action: #selector(annotateSelection(_:)),
                                          keyEquivalent: kind.keyEquivalent)
                    item.keyEquivalentModifierMask = []
                    item.target = self
                    item.representedObject = kind.rawValue
                    submenu.addItem(item)
                }
                annotate.submenu = submenu
                menu.addItem(annotate)
                addItem(to: menu, title: "Add Comment…", action: #selector(commentOnSelection(_:)))
            }
            addItem(to: menu, title: "Copy to Cite", action: #selector(copyAsQuote(_:)))
            addItem(to: menu, title: "Copy", action: #selector(copySelection(_:)))
        }
        // With no selection the menu is intentionally empty, so nothing
        // extraneous appears. New commands (Define, Copy Link, Add to
        // Concepts, …) go here.
    }

    @objc private func showDefinition(_ sender: Any?) {
        guard let entry = pendingDefinition else { return }
        pendingDefinition = nil
        definitionPopover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: GlossaryDefinitionPopup(name: entry.name, definition: entry.description))
        definitionPopover = popover
        let anchor = NSRect(x: menuLocation.x - 2, y: menuLocation.y - 2, width: 4, height: 4)
        popover.show(relativeTo: anchor, of: self, preferredEdge: .maxY)
    }

    private func addItem(to menu: NSMenu, title: String, action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    @objc private func copyAsQuote(_ sender: Any?) {
        onCopyQuote(selectedText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @objc private func highlightSelection(_ sender: Any?) {
        guard let selection = currentSelection else { return }
        onHighlight(selection)
    }

    @objc private func annotateSelection(_ sender: NSMenuItem) {
        guard let selection = currentSelection,
              let raw = sender.representedObject as? String,
              let kind = ReaderAnnotationKind(rawValue: raw) else { return }
        onAnnotate(kind, selection)
    }

    @objc private func commentOnSelection(_ sender: Any?) {
        guard let selection = currentSelection else { return }
        onAddComment(selection)
    }

    /// Shows a clicked annotation's popover at the page point the click
    /// landed on: the comment's words (highlights have none) and Remove.
    func showAnnotation(id: String, note: String?, at pagePoint: NSPoint) {
        definitionPopover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: AnnotationPopup(note: note) { [weak self, weak popover] in
                popover?.close()
                self?.onRemoveAnnotation(id)
            })
        definitionPopover = popover
        let anchor = NSRect(x: pagePoint.x - 2, y: pagePoint.y - 2, width: 4, height: 4)
        popover.show(relativeTo: anchor, of: self, preferredEdge: .maxY)
    }

    /// Plain "Copy" of the current selection — WebKit's own copy, so rich
    /// text and formatting come along, not just the plain string.
    @objc private func copySelection(_ sender: Any?) {
        evaluateJavaScript("document.execCommand('copy')")
    }
}

/// The table of contents, in the reader's Contents popover: the book's own
/// navigation when it carries one, its headings or chapters otherwise. The
/// entry being read is marked.
private struct ReaderContentsList: View {
    let entries: [OrigamiEPUBImporter.TOCEntry]
    let currentSubpath: String
    var onOpen: (OrigamiEPUBImporter.TOCEntry) -> Void

    var body: some View {
        Group {
            if entries.isEmpty {
                Text("This book carries no table of contents.")
                    .foregroundStyle(.secondary)
                    .padding(20)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(entries) { entry in
                            Button {
                                onOpen(entry)
                            } label: {
                                HStack {
                                    Text(entry.label)
                                        .lineLimit(2)
                                    Spacer()
                                    if entry.subpath == currentSubpath && entry.fragment == nil {
                                        Image(systemName: "book")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 4)
                            .padding(.horizontal, 8)
                        }
                    }
                    .padding(8)
                }
            }
        }
        .frame(width: 320)
        .frame(maxHeight: 420)
    }
}

/// The Add Comment sheet: the quoted words over a field for the reader's
/// own, saved into the book's annotation sidecar.
private struct ReaderCommentSheet: View {
    let selection: ReaderSelection
    var onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Comment")
                .font(.headline)
            Text("“\(selection.text)”")
                .foregroundStyle(.secondary)
                .lineLimit(3)
            TextEditor(text: $note)
                .font(.body)
                .frame(minHeight: 90)
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(.quaternary))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(note)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

/// A clicked annotation's pop-up: the comment's words (a plain highlight
/// has none) and the way to remove the mark.
private struct AnnotationPopup: View {
    let note: String?
    var onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let note, !note.isEmpty {
                Text(note)
                    .font(.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Highlight")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            Button(role: .destructive) {
                onRemove()
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
    }
}

/// The Show Definition pop-up: the concept's name over its glossary
/// description, sized for reading in place.
private struct GlossaryDefinitionPopup: View {
    let name: String
    let definition: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(name)
                .font(.headline)
            Text(definition)
                .font(.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
    }
}
