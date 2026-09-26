import SwiftUI
import AppKit

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(AppSettings.readerThemeKey) private var themeRaw = ReaderTheme.highContrast.rawValue
    // Edited theme colours (Settings ▸ Reading ▸ Edit Theme Colors…)
    // apply live: every override write bumps this key.
    @AppStorage(ThemeColorOverrides.tickKey) private var themeEditTick = 0
    private var theme: ReaderTheme {
        _ = themeEditTick
        return ReaderTheme(rawValue: themeRaw) ?? .highContrast
    }
    private var themeBG: Color {
        theme.background(for: colorScheme) ?? Color(nsColor: .textBackgroundColor)
    }
    private var themeFG: Color {
        theme.textColor(for: colorScheme) ?? Color.primary
    }
    /// Full screen keeps a doorway: hovering the left edge slides the
    /// sidebar in as an overlay; moving away lets it fade.
    @State private var showsPeekSidebar = false
    /// Clicking a sidebar item in the peek unfolds a second column listing
    /// its contents, so other documents can be opened without leaving
    /// full screen.
    @State private var showsPeekList = false
    @State private var peekHideTask: Task<Void, Never>?
    /// Every column, always: with the toolbar bare there is no sidebar
    /// toggle, so a collapse (a stray drag of the seam, or the split
    /// view's own narrow-window behavior) would have no way back. Any
    /// change away from all columns is snapped straight back.
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    /// When true the detail pane is hidden so the list column can expand freely.
    @State private var wideListMode = false

    private var venueIsSelected: Bool {
        switch model.sidebarSelection {
        case .epubPublication, .epubPublicationAuthor, .epubPublicationTopic: return true
        default: return false
        }
    }

    var body: some View {
        @Bindable var model = model
        Group {
            // Focus layouts leave the split view entirely: macOS does not
            // honor detail-only column visibility, so hiding means swapping.
            if model.isFullScreen || model.isListHidden {
                Group {
                    // A venue's wide face (the Map, a relation view) IS
                    // what the reader is looking at — full screen keeps
                    // it, rather than swapping to the reading pane.
                    if venueIsSelected && model.venueRelationsWantWidth {
                        listPane
                            .scrollContentBackground(.hidden)
                    } else {
                        detailPane
                    }
                }
                // The empty state sizes to its text; the peek must
                // anchor to the window, so the pane is stretched first.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(themeBG)
                .foregroundStyle(themeFG)
                .overlay(alignment: .leading) {
                    if model.isFullScreen {
                        peekSidebar
                    }
                }
            } else if LibraryViewRegistry.module(for: model.sidebarSelection)?.hidesDocumentList == true {
                // Whole-library views keep the sidebar — the way to every
                // other place — and give the canvas the list column's room.
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    SidebarView()
                        .toolbar(removing: .sidebarToggle)
                        .scrollContentBackground(.hidden)
                        .background(themeBG)
                        .foregroundStyle(themeFG)
                } detail: {
                    detailPane
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(themeBG)
                        .foregroundStyle(themeFG)
                }
            } else if wideListMode || (venueIsSelected && model.venueRelationsWantWidth) {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    SidebarView()
                        .toolbar(removing: .sidebarToggle)
                        .scrollContentBackground(.hidden)
                        .background(themeBG)
                        .foregroundStyle(themeFG)
                } detail: {
                    listPane
                        .scrollContentBackground(.hidden)
                        .background(themeBG)
                        .foregroundStyle(themeFG)
                        .safeAreaInset(edge: .bottom, spacing: 0) {
                            // The Map carries its own foot bar, and the
                            // venue's papers their own foot Find — the
                            // one that rides the full-screen peek. The
                            // model-wide bar would stack beneath either
                            // as a second Find.
                            if !(venueIsSelected
                                 && (model.venueViewMode == .map
                                     || model.venueViewMode == .documents)) {
                                findBar
                            }
                        }
                }
                .onChange(of: model.current) { _, new in
                    if new != nil { wideListMode = false }
                }
                .onChange(of: model.draftEditor?.docID) { _, new in
                    if new != nil { wideListMode = false }
                }
            } else {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    SidebarView()
                        .toolbar(removing: .sidebarToggle)
                        .scrollContentBackground(.hidden)
                        .background(themeBG)
                        .foregroundStyle(themeFG)
                } content: {
                    listPane
                        .scrollContentBackground(.hidden)
                        .background(themeBG)
                        .foregroundStyle(themeFG)
                        .navigationSplitViewColumnWidth(min: 260, ideal: 380, max: 900)
                        .safeAreaInset(edge: .bottom, spacing: 0) {
                            // The venue's papers carry their own foot
                            // Find — the one that also rides the
                            // full-screen peek; the model-wide bar
                            // would stack beneath it as a second Find.
                            if !(venueIsSelected && model.venueViewMode == .documents) {
                                findBar
                            }
                        }
                } detail: {
                    detailPane
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(themeBG)
                        .foregroundStyle(themeFG)
                }
            }
        }
        // The sidebar is protected: whatever collapsed it, it comes back
        // — but WITHOUT animation. Animated, NavigationSplitView slides
        // the column back with its internal move transition over the
        // sidebar's List — a platform view — and when the collapse came
        // from the full-screen transition this runs mid display-flush:
        // the macOS 27 layout crash's exact shape.
        .onChange(of: columnVisibility) {
            if columnVisibility != .all {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    columnVisibility = .all
                }
            }
        }
        // The catch-all: a ctrl-click on no text at all still answers.
        // Inner menus (paragraphs, names, rows) win where they exist, and
        // AppKit-backed text views keep their own richer menus.
        .contextMenu {
            ContextActionItems(target: .background)
        }
        // Continual profile building: every index change (a new letter,
        // an import, a rescan) offers the undigested documents to the
        // on-device model. See PersonProfiles.swift.
        .task(id: model.index.timeline) {
            model.digestAuthorProfiles()
            // Bots read the same way profiles build: continually, each
            // new letter judged as it arrives.
            model.digestBots()
            // And the record of places grows the same way. See
            // LocationRecord in LocationView.swift.
            model.recordLocations()
        }
        // The maps' beat, here at the root: adopt the shared standing
        // every few seconds, so a Pin or Set Aside made on the iPad or
        // the headset arrives live — not only when the folder watcher's
        // full scan completes. The read itself runs off the main actor.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                model.adoptStanding()
            }
        }
        .inspector(isPresented: $model.showLinksInspector) {
            LinksInspectorView()
        }
        .sheet(isPresented: $model.showXRExport) {
            ExportToXRSheet()
        }
        .sheet(item: $model.formatConversion) { conversion in
            FormatChoiceSheet(conversion: conversion)
        }
        .sheet(item: $model.newAuthor) { person in
            PersonFormView(person: person, heading: "New Author") { saved in
                model.people.upsert(saved)
                model.showNote("Added \(saved.displayName) to People")
            }
        }
        // The toolbar stays bare, as in Knowledge Space: no title over
        // the columns, no controls — Back/Forward, sorting, parallel
        // reading, and the links panel live in the menu bar; Find sits
        // at the foot of the letters list.
        .toolbar(removing: .title)
        .overlay(alignment: .bottom) {
            if let note = model.transientNote {
                Text(note)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(radius: 3)
                    .padding(.bottom, 24)
                    // A fade, not a move: the material capsule is a
                    // platform-hosted view, and a move transition sizing
                    // one mid-flush is the macOS 27 layout crash (seen
                    // 13 Sep: _postWindowNeedsUpdateConstraints threw
                    // under MoveTransition + AppKitPlatformViewHost).
                    .transition(.opacity)
            }
        }
        .animation(.default, value: model.transientNote)
        // The window toolbar stays available in full screen: macOS tucks
        // it away with the menu bar, and mousing to the top edge brings
        // it back — carrying the right toolbar's commands.
        .toolbar(.automatic, for: .windowToolbar)
        .toolbarBackground(themeBG, for: .windowToolbar)
        // The layout swap happens BEFORE the transition on both doors
        // (will-enter and will-exit), deferred one turn out of the
        // notification: the split view and its scroll views must never
        // participate in the animated resize — a scroll view changing
        // geometry mid-transition re-enters window layout (AppKit's
        // separator tracking registers right there) and AppKit
        // escalates that to a crash.
        // Synchronously: willEnter fires BEFORE AppKit animates, so the
        // split view is unmounted before any animated flush can catch it
        // mid-negotiation. (The one-turn deferral could land the swap
        // inside the animation instead.)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { _ in
            model.enterFullScreenLayout()
        }
        // The peek folds at once, but the split view REMOUNTS only when
        // the exit animation has finished (did, not will): a split view
        // negotiating its column sizes inside the animated resize pushes
        // min/max updates mid constraints-flush -- the macOS 27 crash.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { _ in
            Task { @MainActor in
                showsPeekSidebar = false
                showsPeekList = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            Task { @MainActor in
                model.exitFullScreenLayout()
            }
        }
        // The titlebar separator's scroll tracking is the code that
        // throws (NSWindowSectionController registering its adapter
        // during layout, macOS 27). The toolbar here is bare and the
        // hairline unwanted anyway: with the separator off, the
        // registration never happens.
        .background(TitlebarSeparatorDisabler())
        .background(WindowBackgroundSetter(color: NSColor(themeBG)))
        .environment(\.openURL, OpenURLAction { url in
            // Everything Origami Text can open itself — an in-app
            // address, a Seed document, a capsule page, an EPUB anywhere,
            // a DOI that may lead to one — is claimed here rather than
            // handed to a browser. See AppModel.claimLink.
            model.claimLink(url) ? .handled : .systemAction
        })
    }

    /// The full-screen sidebar peek: a slim invisible strip along the left
    /// edge summons the sidebar as a floating panel — the same gesture the
    /// system menu bar teaches at the top edge — and it fades once the
    /// pointer moves on.
    /// In full screen the sidebar is always hover-summoned — it never
    /// pins open. The reading area stays clear until the pointer visits
    /// the left edge.
    private var peekIsPinned: Bool { false }

    private var peekSidebar: some View {
        HStack(spacing: 0) {
            if showsPeekSidebar || peekIsPinned {
                HStack(spacing: 0) {
                    SidebarView()
                        .scrollContentBackground(.hidden)
                        .background(themeBG)
                        .foregroundStyle(themeFG)
                        .frame(width: 220)
                    if (showsPeekList || peekIsPinned) && peekSelectionHasList {
                        Divider()
                        listPane(papersOnly: true)
                            .scrollContentBackground(.hidden)
                            // To Acquire carries whole rows of scholarly
                            // detail — title, byline, the doors to the
                            // copy — a list's strip cuts them off.
                            .frame(width: model.sidebarSelection == .acquisitions
                                   ? 420 : 240)
                    }
                }
                .frame(maxHeight: .infinity)
                .background(.regularMaterial)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0,
                                                  bottomTrailingRadius: 12, topTrailingRadius: 12))
                .shadow(radius: 8, x: 2, y: 0)
                .background(HoverSensor { inside in
                    inside ? cancelPeekHide() : schedulePeekHide()
                })
                // A fade, not a slide: the peek holds Lists and material —
                // platform-hosted views — and a move transition sizing one
                // mid-flush is the macOS 27 layout crash (seen 13 Sep in
                // full screen, the peek's own home).
                .transition(.opacity)
            }
            HoverSensor { inside in
                if inside {
                    cancelPeekHide()
                    withAnimation(.easeOut(duration: 0.2)) { showsPeekSidebar = true }
                } else {
                    schedulePeekHide()
                }
            }
            .frame(width: 16)
        }
        .frame(maxHeight: .infinity)
        // Opening something from the peek list hands the room back to it.
        .onChange(of: model.current?.doc.id) { dismissPeek() }
        .onChange(of: model.draftEditor?.docID) { dismissPeek() }
        .onChange(of: model.selectedArchivedID) { dismissPeek() }
        // Choosing the Map (or a relation view) from the peek fills the
        // window with it — the panel steps aside so only the map shows.
        .onChange(of: model.venueViewMode) {
            if model.venueRelationsWantWidth { dismissPeek() }
        }
        // Reveal the list pane when the user picks a new place, or when the
        // peek first opens (so any existing selection shows its list immediately).
        .onChange(of: model.sidebarSelection) { revealPeekListIfAvailable() }
        .onChange(of: showsPeekSidebar) { if showsPeekSidebar { revealPeekListIfAvailable() } }
    }

    /// Whole-library views have no contents list to unfold; everything
    /// else answers a click with the same list the split view would show.
    private var peekSelectionHasList: Bool {
        LibraryViewRegistry.module(for: model.sidebarSelection)?.hidesDocumentList != true
    }

    private func revealPeekListIfAvailable() {
        guard showsPeekSidebar, peekSelectionHasList else { return }
        withAnimation(.easeOut(duration: 0.2)) { showsPeekList = true }
    }

    private func dismissPeek() {
        guard showsPeekSidebar else { return }
        peekHideTask?.cancel()
        withAnimation(.easeOut(duration: 0.25)) {
            showsPeekSidebar = false
            showsPeekList = false
        }
    }

    /// A short grace period, so the pointer can travel from the edge strip
    /// onto the panel without the panel vanishing under it.
    private func schedulePeekHide() {
        peekHideTask?.cancel()
        peekHideTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                showsPeekSidebar = false
                showsPeekList = false
            }
        }
    }

    private func cancelPeekHide() {
        peekHideTask?.cancel()
    }

    /// Find, framed at the foot of the letters list — it narrows the
    /// list to matching title, author, or text — with New Document
    /// beside it, the visible twin of ⌘N now that the toolbar is bare.
    private var findBar: some View {
        @Bindable var model = model
        return HStack(spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Find", text: $model.searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.2)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.quaternary))
            Button {
                wideListMode.toggle()
            } label: {
                Image(systemName: wideListMode
                      ? "rectangle.compress.horizontal"
                      : "rectangle.expand.horizontal")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(wideListMode ? "Show document alongside list" : "Wide list — hide document pane")
            Button {
                model.newDraft()
            } label: {
                Image(systemName: "square.and.pencil")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("New Document (⌘N)")
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(themeBG)
    }

    @ViewBuilder private var listPane: some View {
        listPane(papersOnly: false)
    }

    /// papersOnly: the peek's narrow column always shows a venue's
    /// papers list, never its wide faces (the Map, a relation view) —
    /// a 240-point strip is a list's width. The find bar rides with it.
    @ViewBuilder private func listPane(papersOnly: Bool) -> some View {
        if model.sidebarSelection == .epubsAll {
            EPUBLibraryListView(mode: .all)
        } else if model.sidebarSelection == .epubsInbox {
            EPUBLibraryListView(mode: .inbox)
        } else if model.sidebarSelection == .myEPUBs {
            EPUBLibraryListView(mode: .myEPUBs)
        } else if model.sidebarSelection == .epubsTopOfPile {
            EPUBLibraryListView(mode: .topOfPile)
        } else if model.sidebarSelection == .epubsTimeline {
            EPUBLibraryListView(mode: .timeline)
        } else if model.sidebarSelection == .epubsAlphabetical {
            EPUBLibraryListView(mode: .alphabetical)
        } else if model.sidebarSelection == .epubJournals {
            JournalsListView()
        } else if case .epubPublication(let name)? = model.sidebarSelection {
            JournalBooksListView(name: name, listOnly: papersOnly)
        } else if case .epubPublicationAuthor(let venue, let author)? = model.sidebarSelection {
            PublicationFilteredListView(venue: venue, filter: .author(author))
        } else if case .epubPublicationTopic(let venue, let topic)? = model.sidebarSelection {
            PublicationFilteredListView(venue: venue, filter: .topic(topic))
        } else if model.sidebarSelection == .hypermediaTimeline {
            HypermediaDocsListView(pinnedOnly: false)
        } else if model.sidebarSelection == .hypermediaPinned {
            HypermediaDocsListView(pinnedOnly: true)
        } else if model.sidebarSelection == .acquisitions {
            AcquisitionsListView()
        } else if model.sidebarSelection == .epubsSetAside {
            EPUBLibraryListView(mode: .setAside)
        } else if case .epubFolder(let folder)? = model.sidebarSelection {
            EPUBLibraryListView(mode: .folder(folder))
        } else if case .hypermediaSpace(let domain)? = model.sidebarSelection {
            HypermediaSpaceListView(domain: domain)
        } else if model.sidebarSelection == .authors {
            AuthorsListView()
        } else if case .epubAuthor(let name)? = model.sidebarSelection {
            AuthorBooksListView(name: name)
        } else if model.sidebarSelection == .annotations {
            AnnotationsListView()
        } else if case .person(let name)? = model.sidebarSelection {
            PersonListView(name: name)
        } else if model.sidebarSelection == .people {
            PeopleListView()
        } else if case .concept(let name)? = model.sidebarSelection {
            ConceptListView(name: name)
        } else if model.sidebarSelection == .concepts {
            ConceptsListView()
        } else if model.sidebarSelection == .conceptSpace {
            ConceptSpaceView()
        } else if model.sidebarSelection == .timeFlows {
            TimeFlowsListView()
        } else if model.sidebarSelection == .timelines {
            TimelinesListView()
        } else if model.sidebarSelection == .notes {
            NotesListView()
        } else if model.sidebarSelection == .noteLocations {
            NotesByLocationView()
        } else if model.sidebarSelection == .notePeople {
            NotesByPeopleView()
        } else if model.sidebarSelection == .filedNotes {
            NotesFiledView()
        } else if model.sidebarSelection == .drafts {
            DraftListView(kind: .letters)
        } else if model.sidebarSelection == .transcriptDrafts {
            DraftListView(kind: .transcripts)
        } else if model.sidebarSelection == .published {
            PublishedListView(kind: .letters)
        } else if model.sidebarSelection == .transcriptsPublished {
            PublishedListView(kind: .transcripts)
        } else if model.sidebarSelection == .bookDrafts {
            DraftListView(kind: .books)
        } else if model.sidebarSelection == .booksPublished {
            PublishedListView(kind: .books)
        } else if model.sidebarSelection == .archived {
            ArchivedListView()
        } else {
            switch model.sidebarSelection {
            case .inbox:
                InboxListView()
            case .filedReceived:
                LettersListView(scope: .received)
            case .filed:
                LettersListView()
            case .filedOutgoing:
                LettersListView(scope: .outgoing)
            case .filedBooks:
                LettersListView(scope: .books)
            case .transcriptExtracts:
                ExtractsListView()
            case .transcripts:
                TranscriptsView()
            case .extracts:
                ExtractsListView()
            case .timeline:
                TimelineListView()
            case .view(let id):
                if let module = LibraryViewRegistry.module(id: id) {
                    module.makeContent()
                } else {
                    DocumentListView()
                }
            default:
                DocumentListView()
            }
        }
    }

    @ViewBuilder private var detailPane: some View {
        if let epub = model.openEPUB {
            // A faithfully-rendered EPUB overrides the rest of the detail
            // pane; its own bar names it, toggles the Visual-Meta, and
            // gives the way back.
            EPUBReaderScreen(book: epub) { model.openEPUB = nil }
                .id(epub.id)
        } else if let selection = model.sidebarSelection,
           [.notes, .noteLocations, .notePeople, .filedNotes].contains(selection) {
            if let id = model.selectedNoteID,
               let editor = model.draftEditor, editor.docID == id {
                // A desk note opens straight into the editor.
                DraftEditorView(editor: editor)
                    .id(id)
            } else if let id = model.selectedNoteID,
                      let doc = model.filteredNotes.first(where: { $0.id == id }) {
                NoteReadingView(doc: doc)
                    .id(doc.id)
            } else {
                ContentUnavailableView(
                    "No Note Selected",
                    systemImage: "note.text",
                    description: Text("Select a note, or create one — notes made by voice arrive here through the community folder.")
                )
            }
        } else if model.sidebarSelection == .archived {
            if let doc = model.drafts.archived.first(where: { $0.id == model.selectedArchivedID }) {
                ArchivedDocumentView(doc: doc)
                    .id(doc.id)
            } else {
                ContentUnavailableView(
                    "No Archived Document Selected",
                    systemImage: "archivebox",
                    description: Text("Select an archived document to read it or return it to Drafts.")
                )
            }
        } else if model.sidebarSelection == .drafts || model.sidebarSelection == .transcriptDrafts
                    || model.sidebarSelection == .bookDrafts {
            if let editor = model.draftEditor {
                DraftEditorView(editor: editor)
                    .id(editor.docID)
            } else {
                ContentUnavailableView(
                    "No Draft Selected",
                    systemImage: "square.and.pencil",
                    description: Text("Select a draft, or create a new document (⌘N).")
                )
            }
        } else if let destination = model.current, let parallel = model.parallelDoc {
            ParallelReadingView(leftDoc: destination.doc, rightDoc: parallel)
                .id("\(destination.doc.id)-\(parallel.id)")
        } else if let module = LibraryViewRegistry.module(for: model.sidebarSelection),
                  let detail = module.makeDetail?(model) {
            detail
        } else if let destination = model.current {
            DocumentDetailView(destination: destination)
                .id(destination.doc.id)
        } else {
            ContentUnavailableView(
                "No Document Selected",
                systemImage: "doc.text",
                description: Text("Select a document from the list, or follow a link.")
            )
        }
    }
}
/// AppKit-backed hover detection. SwiftUI's `onHover` is unreliable on
/// fully transparent views on macOS — transparent pixels can fall out of
/// hit-testing — and the full-screen doorway must never miss. A real
/// NSTrackingArea is geometric: it fires no matter what is drawn.
private struct HoverSensor: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) {
        view.onChange = onChange
    }

    final class TrackingView: NSView {
        var onChange: ((Bool) -> Void)?

        override func updateTrackingAreas() {
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self, userInfo: nil))
            super.updateTrackingAreas()
        }

        override func mouseEntered(with event: NSEvent) { onChange?(true) }
        override func mouseExited(with event: NSEvent) { onChange?(false) }
    }
}

/// Turns the window's titlebar separator off. The separator's scroll
/// tracking (NSWindowSectionController's adapter) registers itself from
/// inside the window's layout pass when a scroll view's geometry moves —
/// AppKit (macOS 27) escalates that to a crash during the full-screen
/// transition. The toolbar here is bare and the hairline unwanted; with
/// the style `.none`, the tracking never registers.
private struct TitlebarSeparatorDisabler: NSViewRepresentable {
    func makeNSView(context: Context) -> SeparatorView { SeparatorView() }
    func updateNSView(_ view: SeparatorView, context: Context) {}

    final class SeparatorView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.titlebarSeparatorStyle = .none
        }
    }
}

/// Keeps NSWindow.backgroundColor in step with the app theme. macOS
/// captures the window's backgroundColor for its full-screen animation
/// snapshot — if it doesn't match the SwiftUI fill the edges flash the
/// wrong colour during the transition. updateNSView runs on every render,
/// so theme and appearance changes are reflected immediately.
private struct WindowBackgroundSetter: NSViewRepresentable {
    let color: NSColor

    func makeNSView(context: Context) -> BGSetterView {
        let view = BGSetterView()
        view.pendingColor = color
        return view
    }

    func updateNSView(_ view: BGSetterView, context: Context) {
        view.pendingColor = color
        view.window?.backgroundColor = color
    }

    final class BGSetterView: NSView {
        var pendingColor: NSColor = .textBackgroundColor

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.backgroundColor = pendingColor
        }
    }
}



/// The front matter as the export sheet edits it — a working copy of
/// what the EPUB states, corrected for this rendering only. The EPUB is
/// never changed: a date that was the day of export, a venue the paper
/// has since moved to, a DOI assigned after the file was written, all
/// get fixed here.
struct FrontMatterDraft: Equatable {
    struct Author: Identifiable, Equatable {
        let id = UUID()
        var name = ""
        var affiliation = ""
        var email = ""
        var orcid = ""
    }

    var title = ""
    var subtitle = ""
    var date = Date()
    var authors: [Author] = []
    var venue = ""
    var eventShort = ""
    var eventDates = ""
    var eventPlace = ""
    var doi = ""
    var isbn = ""
    var keywords = ""
    var ccs = ""
    var abstract = ""

    init(_ doc: LiquidDoc) {
        title = doc.title
        subtitle = doc.subtitle ?? ""
        date = doc.listedDate
        let names = doc.authors.isEmpty
            ? [doc.displayAuthor].filter { !$0.isEmpty } : doc.authors
        authors = names.map { name in
            Author(name: name,
                   affiliation: doc.authorAffiliations[name]
                       ?? (names.count == 1 ? doc.affiliations.first ?? "" : ""),
                   email: doc.authorEmails[name] ?? "",
                   orcid: doc.authorORCIDs[name] ?? "")
        }
        if authors.isEmpty { authors = [Author()] }
        venue = doc.publication ?? ""
        let front = ACMLaTeX.withFrontMatterFromBody(doc)
        if let event = ACMLaTeX.conferenceFromReference(doc) {
            if venue.isEmpty { venue = event.name }
            eventShort = event.short
            eventDates = event.date
            eventPlace = event.place
        }
        doi = doc.doi ?? ""
        isbn = doc.isbn ?? ACMLaTeX.isbnFromLicence(doc) ?? ""
        keywords = front.keywords.joined(separator: ", ")
        ccs = front.ccsConcepts.joined(separator: "\n")
        abstract = front.abstract ?? ""
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The paper as it will be rendered: the EPUB's document with the
    /// corrected front matter laid over it.
    func applied(to source: LiquidDoc) -> LiquidDoc {
        var doc = source
        doc.title = Self.trimmed(title)
        doc.subtitle = Self.trimmed(subtitle).isEmpty ? nil : Self.trimmed(subtitle)
        doc.date = LiquidDate(isoString: date.formatted(.iso8601.year().month().day()))
        let people = authors.filter { !Self.trimmed($0.name).isEmpty }
        doc.authors = people.map { Self.trimmed($0.name) }
        doc.authorAffiliations = [:]
        doc.authorEmails = [:]
        doc.authorORCIDs = [:]
        doc.affiliations = []
        for person in people {
            let name = Self.trimmed(person.name)
            if !Self.trimmed(person.affiliation).isEmpty {
                doc.authorAffiliations[name] = Self.trimmed(person.affiliation)
            }
            if !Self.trimmed(person.email).isEmpty {
                doc.authorEmails[name] = Self.trimmed(person.email)
                    .replacingOccurrences(of: "mailto:", with: "")
            }
            let orcid = Self.bareORCID(person.orcid)
            if !orcid.isEmpty { doc.authorORCIDs[name] = orcid }
        }
        doc.publication = Self.trimmed(venue).isEmpty ? nil : Self.trimmed(venue)
        doc.doi = Self.trimmed(doi).isEmpty ? nil : Self.trimmed(doi)
            .replacingOccurrences(of: "https://doi.org/", with: "")
        doc.isbn = Self.trimmed(isbn).isEmpty ? nil : Self.trimmed(isbn)
        doc.keywords = keywords.components(separatedBy: ",")
            .map(Self.trimmed).filter { !$0.isEmpty }
        doc.ccsConcepts = ccs.components(separatedBy: .newlines)
            .map(Self.trimmed).filter { !$0.isEmpty }
        doc.abstract = Self.trimmed(abstract).isEmpty ? nil : Self.trimmed(abstract)
        return doc
    }

    /// The event for acmart, when any of its parts is stated.
    var event: ACMLaTeX.Conference? {
        let name = Self.trimmed(venue)
        guard !name.isEmpty,
              !(Self.trimmed(eventShort).isEmpty && Self.trimmed(eventDates).isEmpty
                && Self.trimmed(eventPlace).isEmpty) else { return nil }
        return ACMLaTeX.Conference(name: name, short: Self.trimmed(eventShort),
                                   date: Self.trimmed(eventDates),
                                   place: Self.trimmed(eventPlace))
    }

    static func bareORCID(_ text: String) -> String {
        trimmed(text)
            .replacingOccurrences(of: "https://orcid.org/", with: "")
            .replacingOccurrences(of: "http://orcid.org/", with: "")
    }

    /// ORCID's own check (ISO 7064 mod 11-2): nil when the id is fine
    /// or empty, a sentence when it is not.
    static func orcidProblem(_ text: String) -> String? {
        let id = bareORCID(text)
        guard !id.isEmpty else { return nil }
        let digits = id.replacingOccurrences(of: "-", with: "")
        guard id.range(of: #"^\d{4}-\d{4}-\d{4}-\d{3}[\dX]$"#, options: .regularExpression) != nil
        else { return "An ORCID has the form 0000-0000-0000-0000." }
        var total = 0
        for character in digits.dropLast() {
            total = (total + Int(String(character))!) * 2
        }
        let result = (12 - total % 11) % 11
        let check = result == 10 ? "X" : String(result)
        return String(digits.last!) == check ? nil : "This ORCID's check digit does not match."
    }

    /// What the rendering will lack — shown so it is no surprise.
    var missing: [String] {
        var out: [String] = []
        if authors.allSatisfy({ Self.trimmed($0.name).isEmpty }) { out.append("authors") }
        if authors.contains(where: { !Self.trimmed($0.name).isEmpty
            && Self.trimmed($0.affiliation).isEmpty }) { out.append("an affiliation") }
        if Self.trimmed(abstract).isEmpty { out.append("an abstract") }
        if Self.trimmed(ccs).isEmpty { out.append("CCS concepts") }
        if Self.trimmed(keywords).isEmpty { out.append("keywords") }
        if Self.trimmed(venue).isEmpty { out.append("a venue") }
        return out
    }
}

/// Choosing the publisher's format a paper is rendered in, and correcting
/// its front matter for that rendering.
///
/// Every field starts from what the EPUB states and may be changed —
/// the date an export stamped, a venue, a DOI assigned since, an ORCID.
/// The corrections shape this rendering only; the EPUB is untouched.
struct FormatChoiceSheet: View {
    let conversion: AppModel.FormatConversion
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var style: ACMLaTeX.Style = .sigconf
    /// Whose format: ACM (with its own format choice below), IEEE,
    /// Springer LNCS, Elsevier, or a plain preprint.
    @State private var publisher: ACMLaTeX.Publisher = .acm
    /// The same corrected paper as an Origami EPUB in the publisher's
    /// house style, written into the bundle beside the LaTeX.
    @State private var alsoEPUB = true
    /// The rights the rendered edition is published under. Origami Text
    /// decides this, not the writing tool: it starts from whatever the
    /// paper states, else CC BY 4.0, ACM's open-access default.
    @State private var rights: ACMLaTeX.Rights = .ccBy
    @State private var compile = true
    @State private var draft: FrontMatterDraft
    /// Re-read after the helper is installed, so the toggle wakes up
    /// without reopening the sheet.
    @State private var canCompile = ACMLaTeX.isTeXAvailable

    init(conversion: AppModel.FormatConversion) {
        self.conversion = conversion
        _draft = State(initialValue: FrontMatterDraft(conversion.doc))
    }

    /// TeX is on the machine but behind the sandbox, and the helper that
    /// reaches it is not yet in place — the one case a button can fix.
    private var helperWouldHelp: Bool {
        if case .unreachable = ACMLaTeX.tex { return !ACMLaTeX.isHelperInstalled }
        return false
    }

    /// Why the PDF cannot be produced here — which is not the same
    /// question as whether TeX is installed. Telling someone to install
    /// TeX when they already have it is the one message worth avoiding.
    private var unreachableNote: String {
        switch ACMLaTeX.tex {
        case .runnable:
            ""
        case .unreachable:
            "TeX is installed, but this app's sandbox keeps it from running "
            + "it directly. Save the compile helper once — a small script "
            + "macOS lets sandboxed apps run — and the PDF is made here. "
            + "Without it, the LaTeX bundle is written and its README.txt "
            + "holds the one command that builds the PDF."
        case .absent:
            "No TeX installation was found, so the LaTeX bundle is written "
            + "and its README.txt says how to compile it. TeX Live and "
            + "MacTeX both include the ACM class."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Render in a publisher's format")
                    .font(.headline)
                Text("Every field starts from the EPUB and may be corrected. "
                     + "Changes shape this rendering only; the EPUB is not altered.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 10)

            Form {
                formatSection
                paperSection
                authorsSection
                venueSection
                classificationSection
                outputSection
            }
            .formStyle(.grouped)

            HStack {
                if !draft.missing.isEmpty {
                    Label("Absent: \(draft.missing.joined(separator: ", "))",
                          systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(compile && canCompile ? "Render PDF\u{2026}" : "Write Bundle\u{2026}") {
                    let makePDF = compile && canCompile
                    let chosen = style
                    let chosenPublisher = publisher
                    let writeEPUB = alsoEPUB
                    let chosenRights = rights
                    let edited = draft.applied(to: conversion.doc)
                    let event = draft.event
                    // The save panel follows the sheet rather than
                    // stacking over it.
                    dismiss()
                    Task { @MainActor in
                        model.writeFormat(chosen, of: conversion, publisher: chosenPublisher,
                                          rights: chosenRights,
                                          edited: edited, event: event,
                                          alsoEPUB: writeEPUB,
                                          compile: makePDF)
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 600, height: 720)
        .onAppear {
            compile = canCompile
            rights = ACMLaTeX.Rights.stated(by: conversion.doc) ?? .ccBy
        }
    }

    private var formatSection: some View {
        Section("Format") {
            Picker("Publisher", selection: $publisher) {
                ForEach(ACMLaTeX.Publisher.allCases) { option in
                    Text(option.columns.isEmpty ? option.label
                         : "\(option.label) — \(option.columns)").tag(option)
                }
            }
            Text(publisher.note)
                .font(.caption)
                .foregroundStyle(.secondary)
            if publisher == .acm {
                acmFormatPicker
            }
        }
    }

    @ViewBuilder private var acmFormatPicker: some View {
            Picker("ACM format", selection: $style) {
                // The formats we have compiled and looked at come first
                // and are the only ones offered without a caveat.
                Section("Verified") {
                    ForEach(ACMLaTeX.Style.allCases.filter(\.supported)) { option in
                        Text("\(option.label) — \(option.columns)").tag(option)
                    }
                }
                Section("Offered on acmart's word, not yet checked here") {
                    ForEach(ACMLaTeX.Style.allCases.filter { !$0.supported }) { option in
                        Text("\(option.label) — \(option.columns)").tag(option)
                    }
                }
            }
            Text(style.note)
                .font(.caption)
                .foregroundStyle(.secondary)
    }

    private var paperSection: some View {
        Section("Paper") {
            TextField("Title", text: $draft.title)
            TextField("Subtitle", text: $draft.subtitle, prompt: Text("None"))
            DatePicker("Date", selection: $draft.date, displayedComponents: .date)
            VStack(alignment: .leading, spacing: 4) {
                Text("Abstract")
                TextEditor(text: $draft.abstract)
                    .font(.body)
                    .frame(minHeight: 90)
            }
        }
    }

    private var authorsSection: some View {
        Section {
            ForEach($draft.authors) { $author in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("Name", text: $author.name)
                        Button {
                            draft.authors.removeAll { $0.id == author.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove this author")
                        .disabled(draft.authors.count == 1)
                    }
                    TextField("Affiliation", text: $author.affiliation,
                              prompt: Text("Institution, City, Country"))
                    TextField("Email", text: $author.email)
                    TextField("ORCID", text: $author.orcid,
                              prompt: Text("0000-0000-0000-0000"))
                    if let problem = FrontMatterDraft.orcidProblem(author.orcid) {
                        Label(problem, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(.vertical, 4)
            }
            .onMove { draft.authors.move(fromOffsets: $0, toOffset: $1) }
            Button("Add Author") { draft.authors.append(.init()) }
        } header: {
            Text("Authors")
        } footer: {
            Text("In printed order. The affiliation is read from the end — "
                 + "country last — and ACM's class requires the country.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var venueSection: some View {
        Section {
            TextField("Venue", text: $draft.venue,
                      prompt: Text("37th ACM Conference on Hypertext"))
            TextField("Short name", text: $draft.eventShort, prompt: Text("HT ’26"))
            TextField("Dates", text: $draft.eventDates,
                      prompt: Text("September 14–18, 2026"))
            TextField("Place", text: $draft.eventPlace,
                      prompt: Text("London, United Kingdom"))
            TextField("DOI", text: $draft.doi, prompt: Text("10.1145/…"))
            TextField("ISBN", text: $draft.isbn, prompt: Text("None"))
        } header: {
            Text("Venue and identifiers")
        } footer: {
            Text("The short name, dates and place fill the running head and the "
                 + "rights block. Leave them empty for a paper not yet placed.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var classificationSection: some View {
        Section {
            TextField("Keywords", text: $draft.keywords,
                      prompt: Text("Separated by commas"))
            VStack(alignment: .leading, spacing: 4) {
                Text("CCS Concepts")
                TextEditor(text: $draft.ccs)
                    .font(.body)
                    .frame(minHeight: 50)
            }
        } header: {
            Text("Classification")
        } footer: {
            Text("One concept per line, levels joined with →, e.g. "
                 + "“Human-centered computing → Hypertext / hypermedia”.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var outputSection: some View {
        Section("Rights and output") {
            Picker("Rights", selection: $rights) {
                ForEach(ACMLaTeX.Rights.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            Text(ACMLaTeX.Rights.stated(by: conversion.doc) == nil
                 ? "The paper states no rights, so they are set here."
                 : "Starting from the rights the paper states.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Also write an EPUB in this style", isOn: $alsoEPUB)
            Text("An Origami EPUB with the corrected front matter, its "
                 + "references set in \(publisher == .acm ? "ACM" : publisher.label)'s style.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Also compile to PDF", isOn: $compile)
                .disabled(!canCompile)
            if !canCompile {
                Text(unreachableNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if helperWouldHelp {
                    Button("Save Compile Helper\u{2026}") {
                        if ACMLaTeX.installHelper() {
                            canCompile = ACMLaTeX.isTeXAvailable
                            compile = canCompile
                        }
                    }
                }
            }
        }
    }
}
