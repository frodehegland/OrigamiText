import SwiftUI
import AppKit

struct ContentView: View {
    @Environment(AppModel.self) private var model
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

    var body: some View {
        @Bindable var model = model
        Group {
            // Focus layouts leave the split view entirely: macOS does not
            // honor detail-only column visibility, so hiding means swapping.
            if model.isFullScreen || model.isListHidden {
                detailPane
                    // The empty state sizes to its text; the peek must
                    // anchor to the window, so the pane is stretched first.
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                } detail: {
                    detailPane
                }
            } else {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    SidebarView()
                        .toolbar(removing: .sidebarToggle)
                } content: {
                    listPane
                        .navigationSplitViewColumnWidth(min: 120, ideal: 195, max: 600)
                        // Find sits framed at the foot of the letters
                        // list, as in Knowledge Space; the top stays bare.
                        .safeAreaInset(edge: .bottom, spacing: 0) { findBar }
                } detail: {
                    detailPane
                }
            }
        }
        // The sidebar is protected: whatever collapsed it, it comes back.
        .onChange(of: columnVisibility) {
            if columnVisibility != .all {
                columnVisibility = .all
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
        .inspector(isPresented: $model.showLinksInspector) {
            LinksInspectorView()
        }
        .sheet(isPresented: $model.showXRExport) {
            ExportToXRSheet()
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
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.default, value: model.transientNote)
        // The window toolbar stays available in full screen: macOS tucks
        // it away with the menu bar, and mousing to the top edge brings
        // it back — carrying the right toolbar's commands.
        .toolbar(.automatic, for: .windowToolbar)
        // The layout swap happens BEFORE the transition on both doors
        // (will-enter and will-exit), deferred one turn out of the
        // notification: the split view and its scroll views must never
        // participate in the animated resize — a scroll view changing
        // geometry mid-transition re-enters window layout (AppKit's
        // separator tracking registers right there) and AppKit
        // escalates that to a crash.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { _ in
            Task { @MainActor in
                model.enterFullScreenLayout()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { _ in
            Task { @MainActor in
                model.exitFullScreenLayout()
                showsPeekSidebar = false
                showsPeekList = false
            }
        }
        // The titlebar separator's scroll tracking is the code that
        // throws (NSWindowSectionController registering its adapter
        // during layout, macOS 27). The toolbar here is bare and the
        // hairline unwanted anyway: with the separator off, the
        // registration never happens.
        .background(TitlebarSeparatorDisabler())
        .environment(\.openURL, OpenURLAction { url in
            // origamitext:// links clicked inside documents navigate in-app,
            // through the same follow path as the links panel.
            if url.scheme?.lowercased() == "origamitext" {
                model.handleURL(url)
                return .handled
            }
            return .systemAction
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
                    peekSidebarList
                        .scrollContentBackground(.hidden)
                        .frame(width: 220)
                    if (showsPeekList || peekIsPinned) && peekSelectionHasList {
                        Divider()
                        listPane
                            .scrollContentBackground(.hidden)
                            .frame(width: 240)
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
                .transition(.move(edge: .leading).combined(with: .opacity))
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
    }

    /// The peek's own sidebar: the same places as the split-view sidebar,
    /// but as explicit buttons — List selection swallows repeat clicks, and
    /// here every click must answer by unfolding the contents column.
    private var peekSidebarList: some View {
        List {
            ForEach(SidebarCatalog.sections, id: \.title) { section in
                if section.title.isEmpty {
                    // The library's "All" stands alone at the top.
                    Section {
                        peekRows(of: section)
                    }
                } else {
                    Section(section.title) {
                        peekRows(of: section)
                    }
                }
            }
        }
    }

    private func peekRows(of section: (title: String, places: [SidebarPlace])) -> some View {
        let places = section.title == "Views"
            ? model.shownPlaces(of: section.places)
            : section.places
        return ForEach(places) { place in
            Button {
                model.sidebarSelection = place.item
                revealPeekListIfAvailable()
            } label: {
                Label(place.name, systemImage: place.systemImage)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(
                RoundedRectangle(cornerRadius: 5)
                    .fill(model.sidebarSelection == place.item
                          ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear))
            )
        }
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
            .background(RoundedRectangle(cornerRadius: 7).fill(.background))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.quaternary))
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
        .background(.bar)
    }

    @ViewBuilder private var listPane: some View {
        if model.sidebarSelection == .epubsAll {
            EPUBLibraryListView(folder: nil)
        } else if case .epubFolder(let folder)? = model.sidebarSelection {
            EPUBLibraryListView(folder: folder)
        } else if model.sidebarSelection == .authors {
            AuthorsListView()
        } else if case .person(let name)? = model.sidebarSelection {
            PersonListView(name: name)
        } else if model.sidebarSelection == .people {
            PeopleListView()
        } else if case .concept(let name)? = model.sidebarSelection {
            ConceptListView(name: name)
        } else if model.sidebarSelection == .concepts {
            ConceptsListView()
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

