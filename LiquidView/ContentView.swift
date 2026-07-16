import SwiftUI
import AppKit

struct ContentView: View {
    @Environment(AppModel.self) private var model
    /// Full screen keeps a doorway: hovering the left edge slides the
    /// sidebar in as an overlay; moving away lets it fade.
    @State private var showsPeekSidebar = false
    @State private var peekHideTask: Task<Void, Never>?

    var body: some View {
        @Bindable var model = model
        Group {
            // Focus layouts leave the split view entirely: macOS does not
            // honor detail-only column visibility, so hiding means swapping.
            if model.isFullScreen || model.isListHidden {
                detailPane
                    .overlay(alignment: .leading) {
                        if model.isFullScreen {
                            peekSidebar
                        }
                    }
            } else if LibraryViewRegistry.module(for: model.sidebarSelection)?.hidesDocumentList == true {
                // Whole-library views keep the sidebar — the way to every
                // other place — and give the canvas the list column's room.
                NavigationSplitView {
                    SidebarView()
                } detail: {
                    detailPane
                }
            } else {
                NavigationSplitView {
                    SidebarView()
                } content: {
                    listPane
                        .navigationSplitViewColumnWidth(min: 90, ideal: 120, max: 200)
                } detail: {
                    detailPane
                }
                .searchable(text: $model.searchText, prompt: "Title, author, or text")
            }
        }
        // The catch-all: a ctrl-click on no text at all still answers.
        // Inner menus (paragraphs, names, rows) win where they exist, and
        // AppKit-backed text views keep their own richer menus.
        .contextMenu {
            ContextActionItems(target: .background)
        }
        .inspector(isPresented: $model.showLinksInspector) {
            LinksInspectorView()
        }
        .sheet(isPresented: $model.showXRExport) {
            ExportToXRSheet()
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    model.toggleListColumn()
                } label: {
                    Label(model.isListHidden ? "Show List" : "Hide List",
                          systemImage: "rectangle.lefthalf.inset.filled")
                }
                .help("Show or hide the document list")

                Button {
                    model.goBack()
                } label: {
                    Label("Back", systemImage: "chevron.backward")
                }
                .disabled(!model.canGoBack)
                .help("Back (⌘[)")

                Button {
                    model.goForward()
                } label: {
                    Label("Forward", systemImage: "chevron.forward")
                }
                .disabled(!model.canGoForward)
                .help("Forward (⌘])")
            }
            ToolbarItemGroup {
                Menu {
                    Picker("Sort By", selection: $model.sortOrder) {
                        ForEach(ListSortOrder.allCases) { order in
                            Text(order.rawValue).tag(order)
                        }
                    }
                    Divider()
                    Toggle("Show Superseded", isOn: $model.showSuperseded)
                } label: {
                    Label("View Options", systemImage: "arrow.up.arrow.down")
                }
                .help("Sorting and visibility options")

                Menu {
                    if model.parallelDoc != nil {
                        Button("Exit Parallel Reading") { model.exitParallel() }
                        Divider()
                    }
                    ForEach(model.parallelCandidates) { entry in
                        Button(entry.doc.title) { model.enterParallel(with: entry.doc) }
                    }
                } label: {
                    Label("Read in Parallel", systemImage: "rectangle.split.2x1")
                }
                .disabled(model.current == nil
                          || (model.parallelCandidates.isEmpty && model.parallelDoc == nil))
                .help("Read a connected document side by side, with visible connections")

                Button {
                    model.showLinksInspector.toggle()
                } label: {
                    Label("Links", systemImage: "link")
                }
                .help("Show the links panel (⌥⌘L)")
            }
        }
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
        .toolbar(model.isFullScreen ? .hidden : .automatic, for: .windowToolbar)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            model.enterFullScreenLayout()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { _ in
            model.exitFullScreenLayout()
        }
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
    private var peekSidebar: some View {
        HStack(spacing: 0) {
            if showsPeekSidebar {
                SidebarView()
                    .scrollContentBackground(.hidden)
                    .frame(width: 220)
                    .background(.regularMaterial)
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0,
                                                      bottomTrailingRadius: 12, topTrailingRadius: 12))
                    .shadow(radius: 8, x: 2, y: 0)
                    .onHover { inside in
                        inside ? cancelPeekHide() : schedulePeekHide()
                    }
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            Color.clear
                .frame(width: 16)
                .contentShape(Rectangle())
                .onHover { inside in
                    if inside {
                        cancelPeekHide()
                        withAnimation(.easeOut(duration: 0.2)) { showsPeekSidebar = true }
                    } else {
                        schedulePeekHide()
                    }
                }
        }
        .frame(maxHeight: .infinity)
    }

    /// A short grace period, so the pointer can travel from the edge strip
    /// onto the panel without the panel vanishing under it.
    private func schedulePeekHide() {
        peekHideTask?.cancel()
        peekHideTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { showsPeekSidebar = false }
        }
    }

    private func cancelPeekHide() {
        peekHideTask?.cancel()
    }

    @ViewBuilder private var listPane: some View {
        if model.sidebarSelection == .drafts {
            DraftListView()
        } else if model.sidebarSelection == .published {
            PublishedListView()
        } else if model.sidebarSelection == .archived {
            ArchivedListView()
        } else if model.index.folderURL == nil {
            ContentUnavailableView {
                Label("No Community Folder", systemImage: "folder.badge.questionmark")
            } description: {
                Text("Choose a folder of Origami Documents to begin.")
            } actions: {
                Button("Choose Folder…") { model.chooseFolder() }
            }
        } else {
            switch model.sidebarSelection {
            case .letters:
                LettersListView()
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
        if model.sidebarSelection == .archived {
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
        } else if model.sidebarSelection == .drafts {
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
