import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Library views are exchangeable modules: see LibraryViewModule.swift for
/// the recipe. They appear here as `.view(id)`.
enum SidebarItem: Hashable {
    // Received
    case inbox
    case filedReceived
    // Dialog
    case timeline
    case transcripts
    case extracts
    case filed
    // Outgoing
    case drafts
    case published
    case filedOutgoing
    // Notes
    case notes
    case noteLocations
    case notePeople
    case filedNotes
    // Transcripts
    case transcriptDrafts
    case transcriptsPublished
    case transcriptExtracts
    // Books
    case bookDrafts
    case booksPublished
    case filedBooks
    // Library: opened EPUBs — all, ways through them, or by folder
    case epubsAll
    case epubsInbox
    case myEPUBs
    case epubsTimeline
    case epubsAlphabetical
    case epubJournals
    case epubPublication(String)
    case epubPublicationAuthor(String, String)   // venue, author
    case epubPublicationTopic(String, String)    // venue, topic
    case epubsTopOfPile
    case epubsSetAside
    case epubFolder(String)
    case acquisitions
    // Views: ways into the opened EPUBs by who and what they hold.
    // Authors is automatic (the authors of record); People and Concepts
    // are user-curated buckets, added the way folders are.
    case authors
    case epubAuthor(String)
    case annotations
    case people
    case person(String)
    case concepts
    case concept(String)
    /// The full library-wide Concept Space: all AI-extracted concepts
    /// merged by name, with co-occurrence relationships and source docs.
    case conceptSpace
    /// The Time Flows: the data lines standing along the headset's
    /// corridor, curated here for easy access there.
    case timeFlows
    /// The floor timelines: the histories lying under the corridor —
    /// the built-in Wikidata themes and the user's own.
    case timelines
    // Reachable by code, not from the sidebar: Everything as a reading
    // context, and the drafts shelf.
    case allDocuments
    case archived
    case view(String)
}

enum ListSortOrder: String, CaseIterable, Identifiable {
    case byDate = "Date"
    case byTitle = "Title"
    var id: String { rawValue }
}

/// The 2D position of a citation anchor ([1], [2]…) in the reader's WebView,
/// normalized to the full document's scrollable dimensions. Shared by the
/// macOS reader (which populates it) and the visionOS hallway (which draws
/// lines from each anchor to its card in the cited-works wall).
struct InlineCitationAnchor: Sendable {
    /// `data-citation-id`, `data-citation-key`, or the href fragment — the
    /// key used to match this anchor to a hallway EPUBMapItem.
    let citationID: String
    /// `data-origami-ref` from the link, empty for external citations.
    let origamiRef: String
    /// The bare href fragment (e.g. "fn1", "ref-smith99").
    let hrefTarget: String
    /// X centre of the anchor, normalized to the full document width (0–1).
    let normalizedX: Double
    /// Y centre of the anchor, normalized to the full document height (0–1).
    let normalizedY: Double
    /// Whether the anchor falls inside the WebView's current visible viewport.
    let inView: Bool
}

/// App-wide state: the index, navigation history, folder access, and the
/// single `follow` entry point that all link navigation routes through.
@MainActor @Observable
final class AppModel {
    let index = LibraryIndex()
    /// The library's gazetteer — the Places view's memory of every
    /// distinct place a document has carried, geocoded by name once and
    /// remembered. (Knowledge Space's; travels with the view modules.)
    let places = PlaceDirectory()

    // MARK: - Navigation and history

    struct Destination: Hashable {
        let doc: LiquidDoc
        let fragment: String?
    }

    /// Asks the detail view to scroll to and flash-highlight a paragraph —
    /// and, when the link is span-scoped, the exact words within it.
    struct FragmentRequest: Equatable {
        let docID: String
        let paragraphID: String
        var span: String? = nil
        let token: UUID
    }

    // The app opens onto the Timeline — every book, newest first.
    var sidebarSelection: SidebarItem? = .epubsTimeline {
        didSet {
            if oldValue != sidebarSelection { previousSidebarSelection = oldValue }
        }
    }
    /// The selection before the current one — where ⌘W returns to when
    /// it closes a just-opened editor instead of the window.
    private var previousSidebarSelection: SidebarItem?
    /// Which Settings tab is showing — settable, so the sidebar's Edit
    /// can open Settings straight onto View Modules.
    var settingsTab: SettingsTab = .author
    private(set) var history: [Destination] = []
    private(set) var historyPosition = -1

    var current: Destination? {
        history.indices.contains(historyPosition) ? history[historyPosition] : nil
    }
    /// The showing document's id — Knowledge Space's name for it, read
    /// by the travelling view modules (the spherical weave's lit node).
    var selectedDocID: String? { current?.doc.id }
    var canGoBack: Bool { historyPosition > 0 }
    var canGoForward: Bool { !history.isEmpty && historyPosition < history.count - 1 }

    var fragmentRequest: FragmentRequest?
    private(set) var transientNote: String?
    private var noteToken = UUID()

    // MARK: - UI state

    var showLinksInspector = false
    var showXRExport = false
    /// The EPUB currently open in the faithful WebView reader, if any. When
    /// set, the detail pane renders it; navigating anywhere else clears it.
    var openEPUB: OpenEPUB?
    /// The inline citation anchors ([1], [2]…) the faithful reader found on
    /// the current page, updated on load and after every scroll. Empty when no
    /// book is open or the page has no recognised citation links.
    var openDocCitationAnchors: [InlineCitationAnchor] = []
    /// Spine results keyed by folder name — reading container.xml + OPF on
    /// every tap is the main source of selection lag, so we cache on first open.
    private var spineCache: [String: OrigamiEPUBImporter.BookSpine] = [:]
    /// The reader's most recent text selection, reported by the Step 0
    /// bridge. The seam for select-and-act and reading-as-making.
    var lastEPUBSelection: String?
    /// A blank contact record being created via File → New Author.
    var newAuthor: Person?
    var searchText = ""
    var sortOrder: ListSortOrder = .byDate
    var showSuperseded = false
    /// Hides the sidebar and document list, leaving only the detail area.
    var isListHidden = false
    private(set) var isFullScreen = false
    private var inspectorWasShown = false

    func toggleListColumn() {
        isListHidden.toggle()
    }

    /// The escape hatch when every column is hidden: restore the full
    /// library layout (and leave full screen if needed).
    func showLibrary() {
        isListHidden = false
        sidebarSelection = .allDocuments
        if let window = NSApp.keyWindow, window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
    }

    /// Full screen is a focus mode: only the writing/reading area shows.
    func enterFullScreenLayout() {
        isFullScreen = true
        inspectorWasShown = showLinksInspector
        showLinksInspector = false
    }

    func exitFullScreenLayout() {
        isFullScreen = false
        showLinksInspector = inspectorWasShown
    }

    // MARK: - Opening and following

    func open(_ doc: LiquidDoc, fragment: String? = nil, span: String? = nil) {
        openEPUB = nil   // opening a library document leaves the EPUB reader
        // Reading marks read — but only once the reader moves on.
        // Marking at once would drop the letter out of Unread (and its
        // bolding everywhere) while it is still being read.
        commitPendingRead(except: doc)
        if isUnread(doc) { pendingRead = doc }
        if current?.doc.id != doc.id {
            parallelDoc = nil   // navigation leaves parallel reading
            history = Array(history.prefix(historyPosition + 1))
            history.append(Destination(doc: doc, fragment: fragment))
            historyPosition = history.count - 1
        }
        deliverFragment(fragment, span: span, in: doc)
    }

    // MARK: - Read state (InBox and Attention)

    /// Documents the reader has opened, by id. The complement is "unread";
    /// the user's own documents are never unread. Persisted across launches.
    private(set) var readDocumentIDs: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: "readDocumentIDs") ?? [])

    func isUnread(_ doc: LiquidDoc) -> Bool {
        !authorIdentity.matches(author: doc.author) && !readDocumentIDs.contains(doc.id)
    }

    /// The letter being read but not yet marked so: the marking waits
    /// until another document takes the reading pane, so an unread
    /// letter does not vanish from the Unread list under the reader's
    /// eyes. (Quitting mid-read leaves it unread — the conservative
    /// answer.)
    private var pendingRead: LiquidDoc?

    private func commitPendingRead(except doc: LiquidDoc?) {
        guard let pending = pendingRead, pending.id != doc?.id else { return }
        pendingRead = nil
        markRead(pending)
    }

    func markRead(_ doc: LiquidDoc) {
        guard !authorIdentity.matches(author: doc.author),
              readDocumentIDs.insert(doc.id).inserted else { return }
        persistReadIDs()
    }

    /// The reader's "put it back": the letter stays unread until it is
    /// opened again.
    func markUnread(_ doc: LiquidDoc) {
        // Unread by request must survive leaving the letter — cancel
        // any waiting mark.
        if pendingRead?.id == doc.id { pendingRead = nil }
        guard readDocumentIDs.remove(doc.id) != nil else { return }
        persistReadIDs()
    }

    private func persistReadIDs() {
        UserDefaults.standard.set(Array(readDocumentIDs), forKey: "readDocumentIDs")
    }

    // MARK: - Filing

    /// The one folder with special meaning: a document filed here leaves
    /// the Timeline and the library's other lists. Every other folder is
    /// just a place — its documents stay visible everywhere.
    static let archivedFolderName = "Archived"

    /// Where documents are filed: id → folder name. Filing is a private
    /// judgement, persisted like read state — the files themselves never
    /// move, the community folder being shared.
    private(set) var filedFolders: [String: String] =
        UserDefaults.standard.dictionary(forKey: "filedFolders") as? [String: String] ?? [:]

    /// The folders offered for filing, user-extendable through New…;
    /// Archived stays last.
    private(set) var filingFolders: [String] =
        UserDefaults.standard.stringArray(forKey: "filingFolders")
            ?? ["Work", "Personal", "Archived"]

    func folder(for doc: LiquidDoc) -> String? {
        filedFolders[doc.id]
    }

    func isArchived(_ doc: LiquidDoc) -> Bool {
        filedFolders[doc.id] == Self.archivedFolderName
    }

    func fileDocument(_ doc: LiquidDoc, under folder: String) {
        filedFolders[doc.id] = folder
        persistFiling()
    }

    func unfile(_ doc: LiquidDoc) {
        guard filedFolders.removeValue(forKey: doc.id) != nil else { return }
        persistFiling()
    }

    /// A new folder joins just above Archived, which keeps the last word.
    func addFilingFolder(_ name: String) {
        guard !filingFolders.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame })
        else { return }
        let index = filingFolders.firstIndex(of: Self.archivedFolderName) ?? filingFolders.endIndex
        filingFolders.insert(name, at: index)
        UserDefaults.standard.set(filingFolders, forKey: "filingFolders")
    }

    /// Asks for a new folder's name and files the document there.
    func fileInNewFolder(_ doc: LiquidDoc) {
        let alert = NSAlert()
        alert.messageText = "New Folder"
        alert.informativeText = "Name the folder to file “\(doc.title)” under."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "File")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        addFilingFolder(name)
        // Filing under the offered spelling, when the name already
        // existed in another case.
        let folder = filingFolders.first { $0.caseInsensitiveCompare(name) == .orderedSame } ?? name
        fileDocument(doc, under: folder)
    }

    private func persistFiling() {
        UserDefaults.standard.set(filedFolders, forKey: "filedFolders")
    }

    // MARK: - Views on show

    /// Sidebar views switched off in Edit Views, by module id. The
    /// module stays installed — it just leaves the sidebar.
    private(set) var hiddenViewIDs: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: "hiddenViewIDs") ?? [])

    func isViewHidden(_ id: String) -> Bool {
        hiddenViewIDs.contains(id)
    }

    func setView(_ id: String, hidden: Bool) {
        if hidden {
            hiddenViewIDs.insert(id)
            // The view being read leaves the sidebar: land somewhere real.
            if sidebarSelection == .view(id) { sidebarSelection = .timeline }
        } else {
            hiddenViewIDs.remove(id)
        }
        UserDefaults.standard.set(Array(hiddenViewIDs), forKey: "hiddenViewIDs")
    }

    /// A section's sidebar places, minus the views switched off.
    func shownPlaces(of places: [SidebarPlace]) -> [SidebarPlace] {
        places.filter { place in
            if case .view(let id) = place.item { return !isViewHidden(id) }
            return true
        }
    }

    /// What "Show in <View>" handed over: the selected words for a
    /// view about text snippets, or the document for a view about
    /// documents as nodes. The named view takes it once and it is gone.
    /// (Kept identical to Knowledge Space's, so view modules travel.)
    struct ShowInPayload {
        let viewID: String
        let text: String?
        let docID: String
    }
    private(set) var showInPayload: ShowInPayload?

    /// Show in <view>: navigates there carrying the selection or the
    /// document, per the view's declared appetite.
    func showIn(viewID: String, selectedText: String?, docID: String) {
        let module = LibraryViewRegistry.module(id: viewID)
        let text = module?.showInAppetite == .text ? selectedText : nil
        showInPayload = ShowInPayload(viewID: viewID, text: text, docID: docID)
        sidebarSelection = .view(viewID)
    }

    /// A view's one-time pickup of what Show in brought it.
    func takeShowInPayload(for viewID: String) -> ShowInPayload? {
        guard let payload = showInPayload, payload.viewID == viewID else { return nil }
        showInPayload = nil
        return payload
    }

    /// The citation a "View as Tree" request is about. Consumed by the
    /// Citation Tree view; persists across sheet dismissal so the tree
    /// renders once the sheet is gone.
    struct CitationTreeTarget {
        var title: String
        var author: String
        var year: Int?
        var doi: String?
        var graphKey: String
    }
    private(set) var citationTreeTarget: CitationTreeTarget?

    func showCitationTree(title: String, author: String, year: Int?, doi: String?) {
        citationTreeTarget = CitationTreeTarget(
            title: title,
            author: author,
            year: year,
            doi: doi,
            graphKey: CitationGraph.key(title: title, author: author))
        sidebarSelection = .view("citation-tree")
    }

    /// The distinct names credited as authors in the library — the
    /// spherical weave's rim, the person form's suggestions.
    var libraryAuthorNames: [String] {
        var seen = Set<String>()
        var names: [String] = []
        for entry in index.timeline {
            let name = entry.doc.author.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { continue }
            names.append(name)
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// One-time migration: the old archived id sets become filings
    /// under Archived.
    private func migrateArchivedIDs() {
        let defaults = UserDefaults.standard
        var changed = false
        for key in ["archivedLetterIDs", "archivedNoteIDs"] {
            guard let ids = defaults.stringArray(forKey: key) else { continue }
            for id in ids where filedFolders[id] == nil {
                filedFolders[id] = Self.archivedFolderName
                changed = true
            }
            defaults.removeObject(forKey: key)
        }
        if changed { persistFiling() }
    }

    /// Received ▸ Inbox: everything from someone else — the unread
    /// first, then only the twenty most recently read; older read
    /// documents fall away here (Dialog's timeline keeps them all).
    /// The bots' InBox scope reads the same list.
    var inboxEntries: [IndexEntry] {
        let others = filteredEntries.filter { !authorIdentity.matches(author: $0.doc.author) }
        let unread = others.filter { isUnread($0.doc) }
        let read = others.filter { !isUnread($0.doc) }.prefix(20)
        var result = Array(unread) + Array(read)
        // Opened EPUBs authored by someone else join the inbox, newest
        // first, without duplicating anything the index already holds. When
        // there are none from others, the inbox is empty.
        for entry in epubEntries
        where !isOwnAuthor(entry.doc.author)
            && !result.contains(where: { $0.id == entry.id }) {
            result.insert(entry, at: 0)
        }
        return result
    }

    /// Whether an author name is the user's own, tolerant of middle names
    /// and initials — "Frode Hegland" recognises "Frode Alexander Hegland"
    /// and vice versa, so a book the user wrote never lands in their inbox.
    private func isOwnAuthor(_ name: String) -> Bool {
        if authorIdentity.matches(author: name) { return true }
        func tokens(_ string: String) -> Set<String> {
            Set(string.lowercased().split { !$0.isLetter }.map(String.init))
        }
        let mine = tokens(authorName)
        let theirs = tokens(name)
        guard !mine.isEmpty, !theirs.isEmpty else { return false }
        return mine.isSubset(of: theirs) || theirs.isSubset(of: mine)
    }

    /// Bold on the sidebar's Inbox while anything unread waits.
    var hasUnreadInbox: Bool {
        inboxEntries.contains { isUnread($0.doc) }
    }

    /// Everything addressed for the user's attention, read or not.
    var attentionEntries: [IndexEntry] {
        filteredEntries.filter { entry in
            entry.doc.attention.contains { authorIdentity.matches(author: $0) }
        }
    }


    // MARK: - Parallel reading (transpointing windows)

    private(set) var parallelDoc: LiquidDoc?

    /// Documents connected to the current one, offered for parallel reading.
    var parallelCandidates: [IndexEntry] {
        guard let doc = current?.doc else { return [] }
        return ParallelReading.candidates(for: doc, byID: index.byID, backlinks: index.backlinks)
    }

    func enterParallel(with doc: LiquidDoc) {
        parallelDoc = doc
    }

    /// Opens a pair side by side directly (used by the Connections web).
    func openTranspointing(from: LiquidDoc, to: LiquidDoc) {
        open(from)
        enterParallel(with: to)
    }

    func exitParallel() {
        parallelDoc = nil
    }

    func follow(_ link: LiquidDoc.Link, from source: LiquidDoc) {
        follow(to: link.to, fragment: link.fragment, rel: link.rel, span: link.span)
    }

    func follow(to target: String, fragment: String?, rel: String?, span: String? = nil) {
        if let entry = resolve(target: target, rel: rel) {
            open(entry.doc, fragment: fragment, span: span)
            return
        }
        // The community folder is authoritative, but a source can live on
        // the user's own shelves — an extract lifted from a transcript
        // still in Drafts or Published. A published copy reads like any
        // document; a draft opens in its editor.
        if let published = drafts.published.first(where: { $0.id == target }) {
            sidebarSelection = .published
            open(published, fragment: fragment, span: span)
            return
        }
        if let draft = drafts.documents.first(where: { $0.id == target }) {
            sidebarSelection = .drafts
            editDraft(draft)
            return
        }
        // A person address ("f.hegla") opens that author's page.
        if LiquidAddress.isPersonAddress(target),
           let author = index.byID.values.map(\.doc.author)
               .first(where: { LiquidAddress.personPrefix(author: $0) == target }) {
            sidebarSelection = .view("authors")
            selectedAuthor = author
            return
        }
        // Citations to PDFs resolve against the Reader Library; they don't
        // need to be in the community folder.
        if let pdf = readerPDFsByID[target] {
            openPDFInReader(pdf)
            return
        }
        if readerLibraryURL == nil, !UserDefaults.standard.bool(forKey: Self.readerPromptedKey) {
            UserDefaults.standard.set(true, forKey: Self.readerPromptedKey)
            chooseReaderLibrary()
            if let pdf = readerPDFsByID[target] {
                openPDFInReader(pdf)
                return
            }
        }
        NSSound.beep()
    }

    // MARK: - Reader Library (cited PDFs live there, not in the community folder)

    private static let readerBookmarkKey = "readerLibraryBookmark"
    private static let readerPromptedKey = "readerLibraryPrompted"
    private(set) var readerLibraryURL: URL?
    private var readerPDFsByID: [String: URL] = [:]
    private var readerScopedURL: URL?

    func restoreReaderLibrary() {
        guard readerLibraryURL == nil,
              let data = UserDefaults.standard.data(forKey: Self.readerBookmarkKey) else { return }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope],
                                 relativeTo: nil, bookmarkDataIsStale: &isStale),
              url.startAccessingSecurityScopedResource() else { return }
        readerScopedURL = url
        readerLibraryURL = url
        rescanReaderLibrary()
    }

    func chooseReaderLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose your Reader Library folder, so citations to PDFs can resolve there."
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let data = try? url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil, relativeTo: nil
        ) {
            UserDefaults.standard.set(data, forKey: Self.readerBookmarkKey)
        }
        readerScopedURL?.stopAccessingSecurityScopedResource()
        _ = url.startAccessingSecurityScopedResource()
        readerScopedURL = url
        readerLibraryURL = url
        rescanReaderLibrary()
        showNote("Reader Library: \(readerPDFsByID.count) identified PDFs")
    }

    func rescanReaderLibrary() {
        guard let readerLibraryURL else { return }
        readerPDFsByID = Self.scanReaderLibrary(at: readerLibraryURL)
    }

    func openPDFInReader(_ url: URL) {
        let workspace = NSWorkspace.shared
        if let readerApp = workspace.urlForApplication(withBundleIdentifier: "com.liquid.Reader") {
            workspace.open([url], withApplicationAt: readerApp,
                           configuration: NSWorkspace.OpenConfiguration())
        } else {
            workspace.open(url)
        }
    }

    /// Indexes Reader's PDFs by their derived library address. The identity
    /// key in each filename — "(Frode-Hegland-2026-07-11T09_32_52Z)" —
    /// yields author and creation time, which determine the address.
    private nonisolated static func scanReaderLibrary(at url: URL) -> [String: URL] {
        var result: [String: URL] = [:]
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return result }
        for case let fileURL as URL in enumerator where fileURL.pathExtension.lowercased() == "pdf" {
            let name = fileURL.deletingPathExtension().lastPathComponent
            guard let id = LiquidDoc.identityKeyID(inFileName: name) else { continue }
            result[id] = fileURL
        }
        return result
    }

    /// Revision links deliberately point at the historical version;
    /// everything else is mapped forward through the revision chain.
    func resolve(target: String, rel: String?) -> IndexEntry? {
        let resolvedID = (rel == "revises") ? target : index.latestRevision(of: target)
        return index.byID[resolvedID]
    }

    private func deliverFragment(_ fragment: String?, span: String? = nil, in doc: LiquidDoc) {
        guard let fragment else { return }
        guard let body = doc.body else { return }   // fragments on sidecars are ignored in v1
        if body.contains(where: { $0.id == fragment }) {
            fragmentRequest = FragmentRequest(docID: doc.id, paragraphID: fragment,
                                              span: span, token: UUID())
        } else {
            showNote("Paragraph “\(fragment)” was not found in “\(doc.title)”.")
        }
    }

    /// Opens a document in the reading context (All Documents), used by
    /// insight views whose rows lead to a document.
    func openInLibrary(_ doc: LiquidDoc, fragment: String? = nil) {
        sidebarSelection = .allDocuments
        open(doc, fragment: fragment)
    }

    /// The place the Locations view should scroll to and mark — set by
    /// a document footer's Location menu, cleared when the view closes.
    var highlightedLocation: String?

    /// Opens the Locations view on the named place.
    func openLocations(highlighting place: String) {
        highlightedLocation = place
        sidebarSelection = .view("location")
    }

    /// The document the Timeline should scroll to — set by a document
    /// footer's Timeline menu, consumed by the scroll.
    var timelineRevealID: String?

    /// Opens the Timeline scrolled to (and reading) this document.
    func openTimeline(revealing doc: LiquidDoc) {
        timelineRevealID = doc.id
        sidebarSelection = .timeline
        if index.byID[doc.id] != nil, current?.doc.id != doc.id {
            open(doc)
        }
    }

    func goBack() {
        guard canGoBack else { return }
        historyPosition -= 1
        commitPendingRead(except: current?.doc)
    }

    func goForward() {
        guard canGoForward else { return }
        historyPosition += 1
        commitPendingRead(except: current?.doc)
    }

    // MARK: - External URLs and files

    /// Handles both `origamitext://open/<uuid>[#fragment]` and document file opens.
    func handleURL(_ url: URL) {
        if url.isFileURL {
            openFile(at: url)
            return
        }
        guard url.scheme?.lowercased() == "origamitext",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.host?.lowercased() == "open"
        else { return }
        let id = LiquidAddress.canonical(String(components.path.trimmingPrefix("/")))
        guard LiquidAddress.isValid(id) else { return }
        if resolve(target: id, rel: nil) == nil {
            showNote("That document is not in the community folder yet.")
        }
        follow(to: id, fragment: components.fragment, rel: nil)
    }

    func openFile(at url: URL) {
        // Origami Text is an EPUB reader now: an EPUB opens in the faithful
        // WebView reader; a LaTeX project (zip or bare .tex) becomes an
        // EPUB first — the reverse of Author's LaTeX export. Anything else
        // (including native JSON documents) is declined.
        switch url.pathExtension.lowercased() {
        case "epub":
            openEPUBFile(at: url)
        case "zip", "tex":
            importLaTeX(at: url)
        default:
            NSSound.beep()
            showNote("Origami Text opens EPUB files (and imports LaTeX).")
        }
    }

    // MARK: - LaTeX import (the reverse of Author's LaTeX export)

    /// A zipped LaTeX project (Author's export: main.tex, references.bib,
    /// figures/) or a bare .tex file, turned into an EPUB: the source is
    /// parsed into the document model, written through the Origami EPUB
    /// exporter, and filed into the reader's library — then opened.
    func importLaTeX(at url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let result = url.pathExtension.lowercased() == "tex"
                ? try LaTeXImporter.importTeXFile(at: url)
                : try LaTeXImporter.importArchive(at: url)
            let created = Date.now
            let author = result.author ?? authorName
            let id = LiquidAddress.makeID(author: author, created: created)
            var doc = LiquidDoc(format: LiquidDoc.knownFormat, id: id,
                                title: result.title, author: author,
                                created: created, body: result.body,
                                links: [], wraps: nil,
                                fileURL: FileManager.default.temporaryDirectory)
            doc.documentType = LiquidDoc.DocumentType.book.rawValue
            doc.publication = result.publication
            doc.references = result.references
            doc.tables = result.tables
            doc.assets = result.assets
            // Through the exporter and straight back in: the EPUB is the
            // document; the .tex was only ever a carrier.
            let epubURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(id + ".epub")
            try OrigamiEPUBExporter.write(doc: doc, resolve: { _ in nil }, to: epubURL)
            defer { try? FileManager.default.removeItem(at: epubURL) }
            guard let record = importEPUB(at: epubURL) else { return }
            openStoredEPUB(record)
            showNote("Imported \u{201C}\(result.title)\u{201D} from LaTeX")
        } catch {
            NSSound.beep()
            showNote("Could not import LaTeX: \(error.localizedDescription)")
        }
    }

    // MARK: - EPUB library (opened EPUBs, remembered internally)

    /// The root under the app container where opened EPUBs are unpacked and
    /// the library manifest lives.
    private static var epubsRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("EPUBs", isDirectory: true)
    }

    private static var epubManifestURL: URL {
        epubsRoot.appendingPathComponent("library.json")
    }

    /// Every EPUB the user has opened, newest first. Persisted internally —
    /// no `.origamitext` is written.
    private(set) var epubRecords: [EPUBRecord] = AppModel.loadEPUBRecords()

    private static func loadEPUBRecords() -> [EPUBRecord] {
        guard let data = try? Data(contentsOf: epubManifestURL),
              let records = try? JSONDecoder().decode([EPUBRecord].self, from: data)
        else { return [] }
        return records.sorted { $0.openedAt > $1.openedAt }
    }

    private func persistEPUBRecords() {
        try? FileManager.default.createDirectory(at: Self.epubsRoot, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(epubRecords) {
            try? data.write(to: Self.epubManifestURL, options: .atomic)
        }
    }

    /// The opened EPUBs as library entries, for the lists that show them.
    var epubEntries: [IndexEntry] {
        epubRecords.map { IndexEntry(doc: epubListingDoc($0)) }
    }

    /// The record of the book open in the reader — what the book lists
    /// highlight as their selection.
    var openEPUBRecordID: String? {
        guard let open = openEPUB else { return nil }
        return epubRecords.first { $0.folder == open.id }?.id
    }

    /// Opens a listed book by its record id — the selection-driven twin
    /// of `openStoredEPUB`, for the lists.
    func openEPUBRecord(withID id: String) {
        guard let record = epubRecords.first(where: { $0.id == id }) else { return }
        openStoredEPUB(record)
    }

    /// An opened EPUB is unread until it has been opened in the reader —
    /// the Files list shows unread records bold. The user's own authored
    /// EPUBs are never unread.
    func isUnread(_ record: EPUBRecord) -> Bool {
        isUnread(epubListingDoc(record))
    }

    /// A lightweight library document standing for an opened EPUB — metadata
    /// only (no body); the words live in the rendered page.
    private func epubListingDoc(_ record: EPUBRecord) -> LiquidDoc {
        let created = record.dateISO.flatMap(LiquidDoc.parseISO8601) ?? record.openedAt
        return LiquidDoc(format: LiquidDoc.knownFormat, id: record.id, title: record.title,
                         author: record.author, created: created, body: [], links: [], wraps: nil,
                         date: record.dateISO.flatMap(LiquidDate.init(isoString:)),
                         documentType: LiquidDoc.DocumentType.book.rawValue,
                         fileURL: Self.epubsRoot.appendingPathComponent(record.folder, isDirectory: true))
    }

    /// Unpacks an EPUB into the app container (once per identity) and remembers
    /// it in the reader's library, so it appears in the Files list — without
    /// opening it in the reader. Reused by the open path and by the community
    /// folder scan. Already-imported, still-unpacked books are reused as-is,
    /// so a rescan never re-unpacks. Returns the record, or nil on failure.
    @discardableResult
    func importEPUB(at url: URL) -> EPUBRecord? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        // A stable folder per EPUB identity, so reopening reuses it and two
        // different books never collide.
        let name = url.deletingPathExtension().lastPathComponent
        let identity = LiquidDoc.identityKeyID(inFileName: name) ?? name
        let safe = identity.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let directory = Self.epubsRoot.appendingPathComponent(safe, isDirectory: true)

        // Already known and still on disk? Keep the existing record — no
        // re-unpack — unless the source file is newer than the unpacked
        // copy: a re-export of the same document (an added figure, a
        // corrected paragraph) must show, so a newer file refreshes.
        if let existing = epubRecords.first(where: { $0.folder == safe }) {
            let content = directory.appendingPathComponent(existing.contentSubpath)
            let sourceStamp = (try? url.resourceValues(
                forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let unpackedStamp = (try? content.resourceValues(
                forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if FileManager.default.fileExists(atPath: content.path),
               let sourceStamp, let unpackedStamp, sourceStamp <= unpackedStamp {
                return enrichRecordIfNeeded(existing, directory: directory)
            }
        }

        do {
            let unpacked = try OrigamiEPUBImporter.unpack(at: url, into: directory)
            // Read OPF + Visual-Meta only — no body parsing, so large
            // multi-chapter EPUBs don't block the main thread.
            let meta = OrigamiEPUBImporter.importMetadata(inUnpackedFolder: directory)
            let bookID = meta.origamiID ?? identity
            let contentSubpath = unpacked.content.path
                .replacingOccurrences(of: directory.path + "/", with: "")
            // Rows display the authors joined; the Authors view lists
            // the book under each of them.
            let authors = meta.authors
            // A refreshed book keeps its place in time; only a truly
            // new one arrives at the top as just-opened.
            let openedAt = epubRecords.first(where: { $0.folder == safe })?.openedAt ?? .now
            let record = EPUBRecord(id: bookID, title: unpacked.title,
                                    author: authors.count > 1
                                        ? authors.joined(separator: ", ")
                                        : (authors.first ?? meta.author ?? "Unknown"),
                                    authors: authors.isEmpty ? nil : authors,
                                    dateISO: meta.date, folder: safe,
                                    contentSubpath: contentSubpath, openedAt: openedAt,
                                    publication: meta.publication ?? "",
                                    doi: meta.doi)
            epubRecords.removeAll { $0.id == bookID || $0.folder == safe }
            epubRecords.insert(record, at: 0)
            // When this book carries a DOI that matches a pending
            // acquisition, the wish is fulfilled — remove it.
            if let doi = meta.doi {
                for wanted in acquisitions where wanted.doi == doi {
                    removeAcquisition(wanted.id)
                }
            }
            // A fresh unpack means a new spine — drop the cached one.
            spineCache.removeValue(forKey: safe)
            // The reading cache may hold the pre-refresh text.
            readingDocCache = nil
            persistEPUBRecords()
            rebuildEPUBIndex()
            return record
        } catch {
            NSSound.beep()
            showNote("Could not read “\(url.lastPathComponent)”: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Scene links (Interatlas and Liquid)

    /// The app that opens Interatlas links: Open Source on an image's
    /// citation recreates the scene there rather than in the browser.
    /// Nil falls back to the system default until Interatlas registers
    /// its universal link domain.
    var interatlasAppPath: String? =
        UserDefaults.standard.string(forKey: "interatlasAppPath") {
        didSet { UserDefaults.standard.set(interatlasAppPath, forKey: "interatlasAppPath") }
    }

    /// The app that opens Liquid view links (Author, or Liquid).
    var liquidAppPath: String? =
        UserDefaults.standard.string(forKey: "liquidAppPath") {
        didSet { UserDefaults.standard.set(liquidAppPath, forKey: "liquidAppPath") }
    }

    /// Opens an Interatlas link where the reader said to. The URL
    /// carries the whole scene; the question is only which door the
    /// app offers. In order: the `interatlas://` scheme once Interatlas
    /// declares one; the chosen app handed the https link; and when the
    /// app declares no way to receive a URL at all — today's Interatlas
    /// — the link goes to the clipboard and the app comes forward,
    /// rather than a dead system alert.
    func openInteratlasLink(_ url: URL) {
        openSceneLink(url, schemedForms: [InteratlasLink.schemed(url)].compactMap { $0 },
                      appPath: interatlasAppPath,
                      cantReceiveNote: "Interatlas can\u{2019}t receive links yet — the scene link is on the clipboard, ready to paste there.")
    }

    /// Opens a Liquid view link — Author's 3D view citation on the
    /// same link domain, path /liquid/ — by the same ladder, through
    /// Liquid's own doors (`liquidinfo://`, the old `liquid://`, or
    /// the chosen app).
    func openLiquidViewLink(_ url: URL) {
        openSceneLink(url, schemedForms: LiquidViewLink.schemedForms(url),
                      appPath: liquidAppPath,
                      cantReceiveNote: "That app can\u{2019}t receive links yet — the view link is on the clipboard, ready to paste there.")
    }

    /// Hands a complete scene to Liquid Information as a `.liquidinfo`
    /// file — the road for scenes too large to ride in any URL. The
    /// doors, in order: the chosen app, whatever app is registered for
    /// the file type, and failing both, the file revealed in the
    /// Finder with the truth on the status line — never a click that
    /// does nothing.
    func openLiquidScene(json: String, link: URL) {
        let name = link.pathComponents.last.flatMap { $0.isEmpty ? nil : $0 } ?? "scene"
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(name)
            .appendingPathExtension("liquidinfo")
        do {
            try Data(json.utf8).write(to: fileURL, options: .atomic)
        } catch {
            showNote("Couldn\u{2019}t write the scene file: \(error.localizedDescription)")
            return
        }
        func reveal() {
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            showNote("The scene is too large for a link — it is written as \(fileURL.lastPathComponent) and revealed in the Finder, ready to open in Liquid Information.")
        }
        if let liquidAppPath, FileManager.default.fileExists(atPath: liquidAppPath) {
            NSWorkspace.shared.open([fileURL],
                                    withApplicationAt: URL(fileURLWithPath: liquidAppPath),
                                    configuration: NSWorkspace.OpenConfiguration()) { _, error in
                guard error != nil else { return }
                Task { @MainActor in reveal() }
            }
            return
        }
        if NSWorkspace.shared.urlForApplication(toOpen: fileURL) != nil,
           NSWorkspace.shared.open(fileURL) {
            return
        }
        reveal()
    }

    /// The one ladder every scene-link kind climbs. The chosen app
    /// always wins: an explicit choice outranks whatever app happens
    /// to have claimed a scheme — stale archive builds do, and Launch
    /// Services remembers them. Only without a choice do the schemes'
    /// registered handlers get the link, newest scheme first, and
    /// failing those the browser.
    private func openSceneLink(_ url: URL, schemedForms: [URL], appPath: String?,
                               cantReceiveNote: String) {
        if let appPath, FileManager.default.fileExists(atPath: appPath) {
            openSceneLink(url, schemedForms: schemedForms,
                          withApplicationAt: URL(fileURLWithPath: appPath),
                          cantReceiveNote: cantReceiveNote)
            return
        }
        // Every rung answers or the ladder climbs on: a scheme whose
        // registered app has moved or been deleted (a stale Launch
        // Services memory) fails in silence unless the result is
        // checked.
        for schemed in schemedForms
        where NSWorkspace.shared.urlForApplication(toOpen: schemed) != nil {
            if NSWorkspace.shared.open(schemed) { return }
        }
        if NSWorkspace.shared.open(url) { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        showNote("The link couldn\u{2019}t be opened here — it is on the clipboard, ready to paste.")
    }

    /// The chosen app's own doors, in order: whichever scheme form the
    /// app claims; the https link when Launch Services agrees the app
    /// can take it; and failing both, the link to the clipboard and
    /// the app to the front, with the truth on the status line.
    private func openSceneLink(_ url: URL, schemedForms: [URL],
                               withApplicationAt appURL: URL,
                               cantReceiveNote: String) {
        let appPath = appURL.standardizedFileURL.path
        func claims(_ candidate: URL) -> Bool {
            NSWorkspace.shared.urlsForApplications(toOpen: candidate)
                .contains { $0.standardizedFileURL.path == appPath }
        }
        // The last resort, shared by every failed hand-off: the link
        // onto the clipboard, the app to the front, and the truth on
        // the status line — never a click that does nothing.
        func fallBack() {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
            NSWorkspace.shared.openApplication(at: appURL,
                                               configuration: NSWorkspace.OpenConfiguration())
            showNote(cantReceiveNote)
        }
        // A hand-off's failure arrives in its completion, off the main
        // thread and easy to lose — heard here, it falls back visibly.
        func hand(_ links: [URL]) {
            NSWorkspace.shared.open(links, withApplicationAt: appURL,
                                    configuration: NSWorkspace.OpenConfiguration()) { _, error in
                guard error != nil else { return }
                Task { @MainActor in fallBack() }
            }
        }
        for schemed in schemedForms where claims(schemed) {
            hand([schemed])
            return
        }
        if claims(url) {
            hand([url])
            return
        }
        fallBack()
    }

    /// Records written before every author and the venue were kept carry
    /// only the first author and no publication. One-time, from the
    /// unpacked package on disk: read the full record, remember it, and
    /// never parse again — a non-nil publication ("" when the book names
    /// no venue) marks the record checked.
    private func enrichRecordIfNeeded(_ record: EPUBRecord, directory: URL) -> EPUBRecord {
        guard record.publication == nil || record.doi == nil,
              let meta = try? OrigamiEPUBImporter.importDocument(inUnpackedFolder: directory)
        else { return record }
        let authors = record.authors ?? (meta.authors.isEmpty ? nil : meta.authors)
        let names = authors ?? [record.author]
        let refreshed = EPUBRecord(id: record.id, title: record.title,
                                   author: names.count > 1
                                       ? names.joined(separator: ", ")
                                       : names[0],
                                   authors: authors,
                                   dateISO: record.dateISO, folder: record.folder,
                                   contentSubpath: record.contentSubpath,
                                   openedAt: record.openedAt,
                                   publication: meta.publication ?? "",
                                   doi: record.doi ?? meta.doi)
        if let index = epubRecords.firstIndex(where: { $0.id == record.id }) {
            epubRecords[index] = refreshed
            persistEPUBRecords()
        }
        return refreshed
    }

    /// Moves an opened EPUB to the Trash: its unpacked package leaves
    /// the app container (recoverable from the Trash), the record leaves
    /// the library, and its filing is forgotten. A book open in the
    /// reader closes first.
    func trashEPUB(_ record: EPUBRecord) {
        if openEPUB?.id == record.folder { openEPUB = nil }
        let directory = Self.epubsRoot.appendingPathComponent(record.folder, isDirectory: true)
        try? FileManager.default.trashItem(at: directory, resultingItemURL: nil)
        try? FileManager.default.removeItem(
            at: ReadingAnalysisStore.fileURL(for: record.id, in: Self.analysesRoot))
        // Remove from community folder so a subsequent scan doesn't re-import it.
        if let communityFolder = index.folderURL {
            let scoped = communityFolder.startAccessingSecurityScopedResource()
            defer { if scoped { communityFolder.stopAccessingSecurityScopedResource() } }
            try? FileManager.default.removeItem(
                at: communityFolder.appendingPathComponent(record.folder + ".epub"))
            // iCloud placeholder: present when the file hasn't been downloaded locally.
            try? FileManager.default.removeItem(
                at: communityFolder.appendingPathComponent("." + record.folder + ".epub.icloud"))
        }
        epubRecords.removeAll { $0.id == record.id }
        unfileEPUB(record.id)
        if epubTopOfPile.remove(record.id) != nil {
            UserDefaults.standard.set(epubTopOfPile.sorted(), forKey: "epubTopOfPile")
        }
        if epubSetAsideIDs.remove(record.id) != nil {
            UserDefaults.standard.set(epubSetAsideIDs.sorted(), forKey: "epubSetAside")
        }
        persistEPUBRecords()
        rebuildEPUBIndex()
        showNote("Moved “\(record.title)” to the Trash")
    }

    /// Opens an EPUB in the faithful WebView reader: imports it (unpacking as
    /// needed), then shows paper.html as authored. Opening marks it read.
    func openEPUBFile(at url: URL) {
        guard let record = importEPUB(at: url) else { return }
        openStoredEPUB(record)
        showNote("Opened “\(record.title)”")
        // The new arrival joins the community folder too, so every
        // device reading it shows the same shelf.
        mirrorShelfToCommunityFolder()
    }

    /// The sidebar's Intro button: opens the built-in guide (IntroGuide.swift),
    /// exporting it through the app's own EPUB writer on first use — and again
    /// whenever `introGuideVersion` has moved, so a revised guide replaces the
    /// stale unpack. The document id never changes, so annotations on the
    /// guide survive editions.
    func openIntroGuide() {
        let versionKey = "introGuideVersion"
        if UserDefaults.standard.integer(forKey: versionKey) != Self.introGuideVersion,
           let stale = epubRecords.first(where: { $0.id == Self.introGuideID }) {
            if openEPUB?.id == stale.folder { openEPUB = nil }
            try? FileManager.default.removeItem(
                at: Self.epubsRoot.appendingPathComponent(stale.folder, isDirectory: true))
            epubRecords.removeAll { $0.id == stale.id }
            persistEPUBRecords()
        }
        if let record = epubRecords.first(where: { $0.id == Self.introGuideID }) {
            openStoredEPUB(record)
            return
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Introducing Origami Text.epub")
        do {
            try OrigamiEPUBExporter.write(doc: Self.introGuideDoc(),
                                          resolve: { _ in nil }, to: url)
        } catch {
            NSSound.beep()
            showNote("Could not write the introduction: \(error.localizedDescription)")
            return
        }
        openEPUBFile(at: url)
        UserDefaults.standard.set(Self.introGuideVersion, forKey: versionKey)
    }

    // MARK: - Cross-document quote links (live + transclusion)

    /// A paragraph the reader should scroll to and flash after the next EPUB
    /// finishes loading — set when a cross-document link is followed.
    var pendingReaderFragment: String?

    /// The AI reading standing over the page, if any — Summary,
    /// Proposals, or Issues takes the whole reading area until closed.
    /// Set by the foot bar's AI group; cleared by Close, a mode word,
    /// or opening another book.
    var readingAnalysisKind: ReadingAnalysisKind?

    /// The find-fold: a term clicked in an AI analysis folds the
    /// reading to headings plus the full sentences carrying the words.
    /// Cleared by any mode word, an Outline shape, or closing Find.
    var readerFindFoldTerm: String?

    /// A keyword clicked in an AI analysis: the analysis closes and the
    /// reading returns folded to the find — the document's headings
    /// with the full sentences around every match, each highlighted,
    /// ⌘G stepping through them.
    func showFindFold(term: String) {
        readingAnalysisKind = nil
        // The fold lives on the native flow, as the Outline group's.
        UserDefaults.standard.set(EPUBReaderMode.scroll.rawValue, forKey: "readerMode")
        readerFindFoldTerm = term
        readerFoldLevel = 1
        requestReaderFind(term)
    }

    // MARK: Stored AI analyses (Regenerate / Remove)

    /// Analyses live beside the unpacked books like annotations do —
    /// one JSON per analyzed book, keyed by the book's address.
    static var analysesRoot: URL {
        epubsRoot.appendingPathComponent("Analyses", isDirectory: true)
    }

    /// The stored analysis of this kind for the book, if one is kept.
    func storedAnalysis(_ kind: ReadingAnalysisKind,
                        forBook book: OpenEPUB) -> StoredReadingAnalysis? {
        ReadingAnalysisStore.load(for: annotationAddress(forBook: book),
                                  in: Self.analysesRoot)[kind.rawValue]
    }

    /// Keeps an analysis, replacing any earlier one of its kind.
    func saveAnalysis(_ kind: ReadingAnalysisKind,
                      result: ReadingAnalysisResult, forBook book: OpenEPUB) {
        let address = annotationAddress(forBook: book)
        var all = ReadingAnalysisStore.load(for: address, in: Self.analysesRoot)
        all[kind.rawValue] = StoredReadingAnalysis(
            text: result.text, names: result.names,
            keywords: result.keywords, created: .now)
        ReadingAnalysisStore.save(all, for: address, in: Self.analysesRoot)
    }

    /// Remembers which of an analysis's blocks the reader dismissed —
    /// the Issues the reader judged not to be real issues.
    func setAnalysisDismissed(_ dismissed: Set<Int>,
                              kind: ReadingAnalysisKind, forBook book: OpenEPUB) {
        let address = annotationAddress(forBook: book)
        var all = ReadingAnalysisStore.load(for: address, in: Self.analysesRoot)
        guard var entry = all[kind.rawValue] else { return }
        entry.dismissed = dismissed.isEmpty ? nil : dismissed.sorted()
        all[kind.rawValue] = entry
        ReadingAnalysisStore.save(all, for: address, in: Self.analysesRoot)
    }

    /// Deletes an analysis without regenerating it.
    func removeAnalysis(_ kind: ReadingAnalysisKind, forBook book: OpenEPUB) {
        let address = annotationAddress(forBook: book)
        var all = ReadingAnalysisStore.load(for: address, in: Self.analysesRoot)
        all.removeValue(forKey: kind.rawValue)
        ReadingAnalysisStore.save(all, for: address, in: Self.analysesRoot)
    }

    /// A find the AI panel (or any tool) asks the open reading to run.
    /// The reader screen watches the stamp and feeds its own find bar,
    /// so the same term can be asked again.
    struct ReaderFindRequest: Equatable {
        let text: String
        let stamp: Int
    }
    private(set) var readerFindRequest: ReaderFindRequest?

    func requestReaderFind(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        readerFindRequest = ReaderFindRequest(
            text: trimmed, stamp: (readerFindRequest?.stamp ?? 0) + 1)
    }

    /// Asks the open reading to clear its find — after a find-fold
    /// landing has shown its matches, the highlight fades and the
    /// reading returns to rest. Stamped so repeated asks fire.
    private(set) var readerFindClear = 0
    func requestReaderFindClear() { readerFindClear += 1 }

    /// The Flow display: body text broken into reading lines at sentence
    /// and clause marks. A view choice, never the document's — the View
    /// menu (⌘⇧F) and the bare `f` key toggle the same switch, and it
    /// rests off when the reading moves to another book.
    var flowReading = false

    /// Find in the open book: ⌘F asks for the bar, ⌘G and ⇧⌘G step the
    /// matches. Counters, so repeated asks always land — the reader
    /// screen watches them.
    var readerFindShow = 0
    var readerFindNext = 0
    var readerFindPrevious = 0

    /// How far the open book is folded (0 reads whole) — shared between
    /// the foot bar's Outline group and the reading view, so the fold
    /// can be asked for from either presentation. Rests when the
    /// reading moves.
    var readerFoldLevel = 0

    /// The opened EPUB whose address (its Origami id, or the identity of its
    /// unpacked folder) matches — how an `origamitext://open/<address>` link
    /// resolves to a book already in the library.
    func epubRecord(forAddress address: String) -> EPUBRecord? {
        let canonical = LiquidAddress.canonical(address)
        return epubRecords.first { $0.id == canonical }
            ?? epubRecords.first { $0.id == address }
            ?? epubRecords.first { $0.folder == address || $0.folder == canonical }
    }

    /// Follows a cross-document quote link: opens the target book in the
    /// reader and, when the link named a paragraph, scrolls to it once the
    /// page has loaded. The "live" half of a quote link.
    func openEPUB(address: String, fragment: String?) {
        guard let record = epubRecord(forAddress: address) else {
            showNote("That document is not in your library yet.")
            return
        }
        openStoredEPUB(record)
        // Set after opening: openStoredEPUB clears any stale fragment, and the
        // reader is (re)built reading this one for the book it just opened.
        pendingReaderFragment = (fragment?.isEmpty == false) ? fragment : nil
    }

    /// The transcluded source of a quote link: the plain text of the named
    /// paragraph in the target book, read from its unpacked content document.
    /// The inline-expansion half of a quote link. Nil when the target is not
    /// in the library, or the paragraph cannot be found.
    func transcludedText(forAddress address: String, fragment: String?) -> String? {
        guard let fragment, !fragment.isEmpty,
              let record = epubRecord(forAddress: address) else { return nil }
        let content = Self.epubsRoot
            .appendingPathComponent(record.folder, isDirectory: true)
            .appendingPathComponent(record.contentSubpath)
        guard let html = try? String(contentsOf: content, encoding: .utf8) else { return nil }
        return Self.elementText(in: html, matchingID: fragment)
    }

    /// Pulls the readable text of the block whose `id` or `data-id` is `id`
    /// out of a content document. A pragmatic paragraph-level extractor: it
    /// finds the opening tag carrying the id and returns its content up to the
    /// matching close tag, tags stripped and the common entities decoded.
    private static func elementText(in html: String, matchingIDSuffix id: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: id)
        return elementText(in: html, idPattern: "[^\"]*-\(escaped)")
    }

    private static func elementText(in html: String, matchingID id: String) -> String? {
        elementText(in: html, idPattern: NSRegularExpression.escapedPattern(for: id))
    }

    private static func elementText(in html: String, idPattern: String) -> String? {
        let pattern = "<(p|li|h[1-6]|blockquote|figure|td|th|aside)\\b[^>]*\\b(?:id|data-id)=\"\(idPattern)\"[^>]*>(.*?)</\\1>"
        guard let expression = try? NSRegularExpression(
            pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]),
              let match = expression.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let innerRange = Range(match.range(at: 2), in: html) else { return nil }
        let inner = String(html[innerRange])
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#10;", with: "\n")
            .replacingOccurrences(of: "&#160;", with: " ")
            .replacingOccurrences(of: "&nbsp;", with: " ")
        let collapsed = inner.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }.joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }

    /// An endnote's words, found by the id its dagger points at — in the
    /// loaded chapter or any other (Author files endnotes in
    /// backmatter.xhtml; its footnote asides carry their own ids). The
    /// faithful reader unfolds this in place instead of navigating away.
    func endnoteText(inBook book: OpenEPUB, id: String) -> String? {
        let chapters = book.chapters.isEmpty ? [book.content] : book.chapters
        for chapter in chapters {
            guard let html = try? String(contentsOf: chapter, encoding: .utf8),
                  let text = Self.elementText(in: html, matchingID: id) else { continue }
            return text
        }
        // A re-exported chaptered book prefixes its ids per chapter
        // (s2-en-1) while the dagger still carries the document's own
        // (en-1) — the suffix bridges the two.
        for chapter in chapters {
            guard let html = try? String(contentsOf: chapter, encoding: .utf8),
                  let text = Self.elementText(in: html, matchingIDSuffix: id) else { continue }
            return text
        }
        return nil
    }

    // MARK: - Glossary of the open book (Show Definition)

    /// The open book's defined concepts, keyed by lowercased name — loaded
    /// lazily from its Visual-Meta (the package's `visual-meta.json`, else
    /// the copy embedded in the content document) and cached per book.
    private var glossaryCache: (bookID: String, byName: [String: (name: String, description: String)])?

    /// The glossary entry the selected text names, if the open book defines
    /// one: the selection is trimmed of whitespace and surrounding
    /// quotes/punctuation and matched case-insensitively against the
    /// concepts' names. Nil when no book is open or the term is not defined.
    func glossaryDefinition(matching text: String) -> (name: String, description: String)? {
        guard let book = openEPUB else { return nil }
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "“”\"'‘’.,;:!?()[]"))
            .lowercased()
        guard !key.isEmpty, key.count <= 100 else { return nil }
        if glossaryCache?.bookID != book.id {
            glossaryCache = (book.id, Self.loadGlossary(content: book.content, base: book.base))
        }
        return glossaryCache?.byName[key]
    }

    /// Reads an unpacked book's defined terms, from either carrier: the
    /// Visual-Meta `concepts` (this app's exports — the package's
    /// `visual-meta.json`, else the copy embedded in the content document),
    /// and Author's `origami.json` `glossary` (phrase/entry pairs, next to
    /// the content document).
    private static func loadGlossary(content: URL, base: URL)
        -> [String: (name: String, description: String)] {
        var byName: [String: (name: String, description: String)] = [:]
        func add(_ name: String?, _ description: String?) {
            guard let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
                  let description = description?
                      .trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty
            else { return }
            byName[name.lowercased()] = (name, description)
        }
        let visualMeta = (try? Data(contentsOf: base.appendingPathComponent("visual-meta.json")))
            ?? (try? String(contentsOf: content, encoding: .utf8))
                .flatMap(OrigamiEPUBImporter.embeddedVisualMeta(in:))
        if let visualMeta,
           let object = (try? JSONSerialization.jsonObject(with: visualMeta)) as? [String: Any],
           let concepts = object["concepts"] as? [[String: Any]] {
            for concept in concepts where (concept["tag"] as? String) != "heading" {
                add(concept["name"] as? String, concept["description"] as? String)
            }
        }
        let origamiURL = content.deletingLastPathComponent()
            .appendingPathComponent("origami.json")
        if let data = try? Data(contentsOf: origamiURL),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let glossary = object["glossary"] as? [String: [String: Any]] {
            for node in glossary.values {
                add(node["phrase"] as? String, node["entry"] as? String)
            }
        }
        return byName
    }

    /// Reopens a remembered EPUB from its unpacked folder in the container.
    func openStoredEPUB(_ record: EPUBRecord) {
        pendingReaderFragment = nil   // a plain open scrolls to the top
        flowReading = false           // Flow rests when the reading moves
        readerFoldLevel = 0           // and so does the fold
        readingAnalysisKind = nil     // a new book begins on its page
        readerFindFoldTerm = nil      // and without a standing find-fold
        let base = Self.epubsRoot.appendingPathComponent(record.folder, isDirectory: true)
        let content = base.appendingPathComponent(record.contentSubpath)
        guard FileManager.default.fileExists(atPath: content.path) else {
            NSSound.beep()
            showNote("“\(record.title)” is no longer unpacked — open the EPUB file again.")
            return
        }
        // The whole spine, derived once from the unpacked package and then
        // cached — re-reading container.xml + OPF on every selection tap
        // was the main source of list-selection lag.
        let spine = spineCache[record.folder]
            ?? OrigamiEPUBImporter.spine(inUnpackedFolder: base)
        if let spine { spineCache[record.folder] = spine }
        let chapters = (spine?.chapters ?? []).map { base.appendingPathComponent($0) }
        openEPUB = OpenEPUB(id: record.folder, title: record.title, content: content, base: base,
                            chapters: chapters.isEmpty ? [content] : chapters,
                            nav: spine?.nav.map { base.appendingPathComponent($0) })
        markRead(epubListingDoc(record))
    }

    // MARK: - Reading positions (where the reader left each book)

    /// Where the reader left a book: the chapter subpath and the scroll
    /// fraction within it. Nil until the book has been read.
    func readingPosition(forFolder folder: String) -> (chapter: String?, fraction: Double)? {
        guard let stored = UserDefaults.standard.dictionary(forKey: "readingPosition:" + folder)
        else { return nil }
        return (stored["chapter"] as? String, stored["fraction"] as? Double ?? 0)
    }

    func saveReadingPosition(forFolder folder: String, chapter: String, fraction: Double) {
        UserDefaults.standard.set(["chapter": chapter, "fraction": fraction],
                                  forKey: "readingPosition:" + folder)
    }

    // MARK: - Annotations (the reader's highlights and comments)

    /// Sidecars live in one folder beside the unpacked books, keyed by book
    /// address, so a re-unpack never loses a reader's notes. The book itself
    /// is never modified — the book is the author's; the annotations are
    /// the reader's.
    static var annotationsRoot: URL {
        epubsRoot.appendingPathComponent("Annotations", isDirectory: true)
    }

    /// Bumped whenever the open book's annotations change, so the reader
    /// repaints its highlights.
    private(set) var annotationsStamp = 0

    /// The address a book's annotations are filed under: its Origami id
    /// when its record is known, else its unpack folder name.
    private func annotationAddress(forBook book: OpenEPUB) -> String {
        epubRecords.first { $0.folder == book.id }?.id ?? book.id
    }

    /// Every annotation on the given book, oldest first.
    func annotations(forBook book: OpenEPUB) -> [WebAnnotation] {
        AnnotationStore.load(for: annotationAddress(forBook: book), in: Self.annotationsRoot)
    }

    /// Highlights the selection in the open book.
    func addHighlight(on selection: ReaderSelection) {
        addAnnotation(motivation: WebAnnotation.Motivation.highlighting, note: nil, on: selection)
    }

    /// Attaches the reader's comment to the selection in the open book.
    func addComment(_ note: String, on selection: ReaderSelection) {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        addAnnotation(motivation: WebAnnotation.Motivation.commenting, note: trimmed, on: selection)
    }

    /// Stamps one of the reader's judgments (Important, Disagree, …) on
    /// the selection in the open book — a W3C tagging annotation.
    func addTag(_ kind: ReaderAnnotationKind, on selection: ReaderSelection) {
        if kind == .highlight {
            addHighlight(on: selection)
            return
        }
        addAnnotation(motivation: WebAnnotation.Motivation.tagging,
                      note: kind.rawValue, purpose: "tagging", on: selection)
    }

    private func addAnnotation(motivation: String, note: String?,
                               purpose: String? = nil, on selection: ReaderSelection) {
        guard let book = openEPUB, !selection.text.isEmpty else { return }
        // The anchoring ladder, most robust first: the enclosing element's
        // stable id, then the exact words with disambiguating context.
        var selectors: [WebAnnotation.Selector] = []
        if let fragment = selection.fragment, !fragment.isEmpty {
            selectors.append(.fragment(value: fragment,
                                       conformsTo: WebAnnotation.fragmentConformsTo))
        }
        selectors.append(.quote(exact: selection.text,
                                prefix: selection.prefix?.isEmpty == false ? selection.prefix : nil,
                                suffix: selection.suffix?.isEmpty == false ? selection.suffix : nil))
        let address = annotationAddress(forBook: book)
        let annotation = WebAnnotation(
            motivation: motivation,
            creator: WebAnnotation.Person(name: authorName),
            body: note.map { WebAnnotation.TextualBody(value: $0, purpose: purpose) },
            target: WebAnnotation.Target(source: "origamitext://open/" + address,
                                         selectors: selectors))
        var all = AnnotationStore.load(for: address, in: Self.annotationsRoot)
        all.append(annotation)
        AnnotationStore.save(all, for: address, in: Self.annotationsRoot)
        annotationsStamp += 1
    }

    /// Removes one annotation from the open book's sidecar.
    func removeAnnotation(id: String) {
        guard let book = openEPUB else { return }
        removeAnnotation(id: id, address: annotationAddress(forBook: book))
    }

    /// Removes one annotation from any book's sidecar — how the
    /// cross-document Annotations view deletes.
    func removeAnnotation(id: String, address: String) {
        var all = AnnotationStore.load(for: address, in: Self.annotationsRoot)
        all.removeAll { $0.id == id }
        AnnotationStore.save(all, for: address, in: Self.annotationsRoot)
        annotationsStamp += 1
    }

    // MARK: Annotations across the library

    /// One annotation with the address of the book it targets — the
    /// unit the cross-document Annotations view lists and searches.
    struct LibraryAnnotation: Identifiable, Hashable {
        let annotation: WebAnnotation
        let address: String
        var id: String { annotation.id }

        /// The annotated words, when the annotation quotes any.
        var exact: String? {
            for selector in annotation.target.selectors {
                if case .quote(let exact, _, _) = selector, !exact.isEmpty { return exact }
            }
            return nil
        }

        /// The stable element id the annotation anchors to, when known.
        var fragment: String? {
            for selector in annotation.target.selectors {
                if case .fragment(let value, _) = selector, !value.isEmpty { return value }
            }
            return nil
        }

        /// The fraction through the document, when the annotation
        /// carries a ProgressionSelector — the lists' reading order.
        var progression: Double? {
            for selector in annotation.target.selectors {
                if case .progression(let value) = selector { return value }
            }
            return nil
        }
    }

    /// Sidecar reads are cheap but not free; recomputed only when a
    /// sidecar changes (`annotationsStamp`).
    @ObservationIgnored private var annotationsCache: (stamp: Int, items: [LibraryAnnotation])?

    /// Every annotation across every book, newest first — read from the
    /// JSON-LD sidecars beside the unpacked books.
    var allAnnotations: [LibraryAnnotation] {
        if let cached = annotationsCache, cached.stamp == annotationsStamp {
            return cached.items
        }
        let items = AnnotationStore.loadAll(in: Self.annotationsRoot)
            .flatMap { address, list in
                list.map { LibraryAnnotation(annotation: $0, address: address) }
            }
            .sorted { $0.annotation.created > $1.annotation.created }
        annotationsCache = (annotationsStamp, items)
        return items
    }

    /// Opens the annotated book at the annotation's own paragraph.
    func openAnnotation(_ item: LibraryAnnotation) {
        openEPUB(address: item.address, fragment: item.fragment)
    }

    // MARK: - The native reading styles' document

    /// The open book as a structured Origami document — the body the
    /// native reading styles (Scroll, Horizontal, Focus, Outline,
    /// Transcript) read, re-imported from the unpacked package and
    /// cached per book. Nil when the package cannot be read back.
    private var readingDocCache: (bookID: String, doc: LiquidDoc)?

    func readingDoc(forBook book: OpenEPUB) -> LiquidDoc? {
        if let cached = readingDocCache, cached.bookID == book.id {
            return cached.doc
        }
        guard let result = try? OrigamiEPUBImporter.importDocument(inUnpackedFolder: book.base)
        else { return nil }
        let record = epubRecords.first { $0.folder == book.id }
        let doc = Self.structuredDoc(from: result, record: record,
                                     fallbackID: book.id, base: book.base)
        readingDocCache = (book.id, doc)
        return doc
    }

    /// The full structured document standing for an unpacked book — the
    /// package's import result joined with the shelf record's metadata.
    /// Shared by the reader (`readingDoc`) and by the view modules'
    /// index (`rebuildEPUBIndex`).
    nonisolated private static func structuredDoc(
        from result: OrigamiEPUBImporter.ImportResult,
        record: EPUBRecord?, fallbackID: String, base: URL) -> LiquidDoc {
        let address = record?.id ?? result.origamiID ?? fallbackID
        let created = (record?.dateISO ?? result.date).flatMap(LiquidDoc.parseISO8601)
            ?? record?.openedAt ?? .now
        var doc = LiquidDoc(format: LiquidDoc.knownFormat,
                            id: address,
                            title: result.title,
                            author: result.author ?? record?.author ?? "Unknown",
                            created: created,
                            body: result.body,
                            links: result.links,
                            wraps: nil,
                            fileURL: base)
        doc.date = (record?.dateISO ?? result.date).flatMap(LiquidDate.init(isoString:))
        doc.documentType = LiquidDoc.DocumentType.book.rawValue
        doc.publication = result.publication ?? record?.publication
        doc.concepts = result.concepts
        doc.layouts = result.layouts
        doc.mapConnections = result.mapConnections
        doc.references = result.references
        doc.tables = result.tables
        doc.assets = result.assets
        return doc
    }

    /// Rebuilds the view modules' index from the EPUB shelf: every
    /// opened book re-imported from its unpacked package as a structured
    /// document — the Visual-Meta metadata, headings, concepts,
    /// citations, references, and the typed links between books. Runs in
    /// the background; a newer rebuild supersedes an older one mid-flight.
    private var epubIndexGeneration = 0
    func rebuildEPUBIndex() {
        epubIndexGeneration += 1
        let generation = epubIndexGeneration
        let records = epubRecords
        let root = Self.epubsRoot
        Task.detached(priority: .utility) {
            var docs: [LiquidDoc] = []
            for record in records {
                let base = root.appendingPathComponent(record.folder, isDirectory: true)
                guard let result = try? OrigamiEPUBImporter.importDocument(
                    inUnpackedFolder: base) else { continue }
                docs.append(Self.structuredDoc(from: result, record: record,
                                               fallbackID: record.folder, base: base))
            }
            let built = docs
            await MainActor.run {
                guard generation == self.epubIndexGeneration else { return }
                self.index.setEPUBDocuments(built)
            }
        }
    }

    /// The document the citation card reads: the full structured import,
    /// or — for a book whose content document will not parse (older
    /// exports predating the well-formedness check) — the Visual-Meta
    /// citation pool alone, abstracts folded in.
    func citationCardDoc(forBook book: OpenEPUB) -> LiquidDoc? {
        if let doc = readingDoc(forBook: book) { return doc }
        let visualMetaData = (try? Data(contentsOf:
                book.base.appendingPathComponent("visual-meta.json")))
            ?? (try? String(contentsOf: book.content, encoding: .utf8))
                .flatMap(OrigamiEPUBImporter.embeddedVisualMeta(in:))
        guard let visualMetaData,
              let object = (try? JSONSerialization.jsonObject(with: visualMetaData))
                  as? [String: Any]
        else { return nil }
        let pool = OrigamiEPUBImporter.citationPool(fromVisualMeta: object)
        guard !pool.references.isEmpty else { return nil }
        var doc = LiquidDoc(format: LiquidDoc.knownFormat, id: book.id, title: book.title,
                            author: "", created: .now, body: [], links: [], wraps: nil,
                            fileURL: book.base)
        doc.references = pool.references
        return doc
    }

    // MARK: Annotations for the native reader (doc-based, same sidecars)

    /// The document's annotations — the same sidecar the WebView reader
    /// writes, keyed by the book's address (`doc.id`).
    func annotations(for doc: LiquidDoc) -> [WebAnnotation] {
        _ = annotationsStamp
        return AnnotationStore.load(for: doc.id, in: Self.annotationsRoot)
    }

    func addHighlight(to doc: LiquidDoc, paragraphID: String, exact: String? = nil) {
        let annotation = WebAnnotation(
            motivation: WebAnnotation.Motivation.highlighting,
            target: AnnotationAnchor.target(in: doc, paragraphID: paragraphID, exact: exact))
        appendAnnotation(annotation, for: doc)
    }

    /// Stamps one of the reader's judgments on a paragraph (or its
    /// selected words) in a native reading — the tagging twin of
    /// `addHighlight(to:paragraphID:exact:)`.
    func addTag(_ kind: ReaderAnnotationKind, to doc: LiquidDoc,
                paragraphID: String, exact: String? = nil) {
        if kind == .highlight {
            addHighlight(to: doc, paragraphID: paragraphID, exact: exact)
            return
        }
        let annotation = WebAnnotation(
            motivation: WebAnnotation.Motivation.tagging,
            creator: WebAnnotation.Person(name: authorName),
            body: WebAnnotation.TextualBody(value: kind.rawValue, purpose: "tagging"),
            target: AnnotationAnchor.target(in: doc, paragraphID: paragraphID, exact: exact))
        appendAnnotation(annotation, for: doc)
    }

    func addComment(_ text: String, to doc: LiquidDoc, paragraphID: String,
                    exact: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let annotation = WebAnnotation(
            motivation: WebAnnotation.Motivation.commenting,
            body: WebAnnotation.TextualBody(value: trimmed),
            target: AnnotationAnchor.target(in: doc, paragraphID: paragraphID,
                                            exact: exact))
        appendAnnotation(annotation, for: doc)
    }

    /// A note written on the page itself — a ctrl-click where no
    /// paragraph is. It targets the whole document (no selectors); its
    /// standing place travels IN the annotation, as the sidecar's
    /// origami:placement extension — anchored to the nearest stable
    /// element, so it survives resizes and other Macs alike.
    func addMarginNote(_ text: String, to doc: LiquidDoc,
                       placement: WebAnnotation.Placement) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var annotation = WebAnnotation(
            motivation: WebAnnotation.Motivation.commenting,
            creator: WebAnnotation.Person(name: authorName),
            body: WebAnnotation.TextualBody(value: trimmed),
            target: WebAnnotation.Target(source: "origamitext://open/" + doc.id,
                                         selectors: []))
        annotation.placement = placement
        appendAnnotation(annotation, for: doc)
    }

    /// Moves a page note's standing place — into the sidecar, where it
    /// travels with the annotation.
    func setNotePlacement(_ placement: WebAnnotation.Placement,
                          for annotation: WebAnnotation, in doc: LiquidDoc) {
        var all = AnnotationStore.load(for: doc.id, in: Self.annotationsRoot)
        guard let index = all.firstIndex(where: { $0.id == annotation.id }) else { return }
        all[index].placement = placement
        all[index].modified = .now
        AnnotationStore.save(all, for: doc.id, in: Self.annotationsRoot)
        annotationsStamp += 1
    }

    /// The notes standing on a document's page — written annotations
    /// anchored to the document as a whole, not to any paragraph. (The
    /// document annotation also targets the whole document, but is a
    /// "describing" annotation, not a page note.)
    func marginNotes(for doc: LiquidDoc) -> [WebAnnotation] {
        annotations(for: doc).filter {
            $0.target.selectors.isEmpty && $0.body?.value.isEmpty == false
                && $0.motivation == WebAnnotation.Motivation.commenting
        }
    }

    // MARK: The document annotation (one note on the whole document)

    /// The reader's annotation on the document as a whole — a W3C
    /// "describing" annotation with no selectors. One per book: the
    /// reading header's pill fills when it exists, and the book lists
    /// print it beneath the author's name.
    func documentAnnotation(forAddress address: String) -> WebAnnotation? {
        _ = annotationsStamp
        return AnnotationStore.load(for: address, in: Self.annotationsRoot).first {
            $0.motivation == WebAnnotation.Motivation.describing
                && $0.target.selectors.isEmpty
        }
    }

    /// Writes or rewrites the document annotation; empty text removes it.
    func setDocumentAnnotation(_ text: String, forAddress address: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var all = AnnotationStore.load(for: address, in: Self.annotationsRoot)
        if let index = all.firstIndex(where: {
            $0.motivation == WebAnnotation.Motivation.describing
                && $0.target.selectors.isEmpty
        }) {
            if trimmed.isEmpty {
                all.remove(at: index)
            } else {
                all[index].body = WebAnnotation.TextualBody(value: trimmed,
                                                            purpose: "describing")
                all[index].modified = .now
            }
        } else {
            guard !trimmed.isEmpty else { return }
            all.append(WebAnnotation(
                motivation: WebAnnotation.Motivation.describing,
                creator: WebAnnotation.Person(name: authorName),
                body: WebAnnotation.TextualBody(value: trimmed, purpose: "describing"),
                target: WebAnnotation.Target(source: "origamitext://open/" + address,
                                             selectors: [])))
        }
        AnnotationStore.save(all, for: address, in: Self.annotationsRoot)
        annotationsStamp += 1
    }

    // MARK: Resolution — where annotations land, and the orphans

    /// One annotation resolved against its document: where it landed,
    /// or nowhere — an orphan, kept and shown, never lost.
    struct ResolvedDocAnnotation: Identifiable {
        let annotation: WebAnnotation
        let resolution: AnnotationAnchor.Resolution?
        var id: String { annotation.id }
    }

    /// Fuzzy re-anchoring costs real work; the result holds until the
    /// sidecar changes or another document asks.
    @ObservationIgnored private var resolutionCache:
        (docID: String, stamp: Int, resolved: [ResolvedDocAnnotation])?

    /// Every annotation on the document with where it landed.
    func resolvedAnnotations(for doc: LiquidDoc) -> [ResolvedDocAnnotation] {
        if let cached = resolutionCache, cached.docID == doc.id,
           cached.stamp == annotationsStamp {
            return cached.resolved
        }
        let resolved = annotations(for: doc).map {
            ResolvedDocAnnotation(annotation: $0,
                                  resolution: AnnotationAnchor.resolve($0, in: doc))
        }
        resolutionCache = (doc.id, annotationsStamp, resolved)
        return resolved
    }

    /// The annotations that no longer find their place in this
    /// document — page notes (which have no selectors) are not orphans.
    func orphanedAnnotationIDs(for doc: LiquidDoc) -> Set<String> {
        Set(resolvedAnnotations(for: doc)
            .filter { $0.resolution == nil && !$0.annotation.target.selectors.isEmpty }
            .map(\.annotation.id))
    }

    /// Where each margin note stands, by annotation id — kept on this
    /// Mac (the sidecar carries the note, not the layout).
    private(set) var marginNotePositions: [String: CGPoint] = {
        guard let stored = UserDefaults.standard.dictionary(forKey: "marginNotePositions")
            as? [String: [Double]] else { return [:] }
        return stored.compactMapValues { pair in
            pair.count == 2 ? CGPoint(x: pair[0], y: pair[1]) : nil
        }
    }()

    func marginNotePosition(forAnnotationID id: String) -> CGPoint? {
        marginNotePositions[id]
    }

    func setMarginNotePosition(_ point: CGPoint, forAnnotationID id: String) {
        marginNotePositions[id] = point
        let stored = marginNotePositions.mapValues { [Double($0.x), Double($0.y)] }
        UserDefaults.standard.set(stored, forKey: "marginNotePositions")
    }

    func removeAnnotation(_ annotation: WebAnnotation, for doc: LiquidDoc) {
        var all = AnnotationStore.load(for: doc.id, in: Self.annotationsRoot)
        all.removeAll { $0.id == annotation.id }
        AnnotationStore.save(all, for: doc.id, in: Self.annotationsRoot)
        annotationsStamp += 1
    }

    /// Rewrites a written annotation's words, stamping when.
    func updateAnnotation(_ annotation: WebAnnotation, note: String, for doc: LiquidDoc) {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var all = AnnotationStore.load(for: doc.id, in: Self.annotationsRoot)
        guard let index = all.firstIndex(where: { $0.id == annotation.id }) else { return }
        all[index].body = WebAnnotation.TextualBody(value: trimmed,
                                                    purpose: annotation.body?.purpose)
        all[index].modified = .now
        AnnotationStore.save(all, for: doc.id, in: Self.annotationsRoot)
        annotationsStamp += 1
    }

    /// The reader's annotation on the document as a whole — the line
    /// the book lists show beneath the author's name.
    func documentAnnotationNote(forRecordID id: String) -> String? {
        let text = documentAnnotation(forAddress: id)?.body?.value
        return text?.isEmpty == false ? text : nil
    }

    private func appendAnnotation(_ annotation: WebAnnotation, for doc: LiquidDoc) {
        var all = AnnotationStore.load(for: doc.id, in: Self.annotationsRoot)
        all.append(annotation)
        AnnotationStore.save(all, for: doc.id, in: Self.annotationsRoot)
        annotationsStamp += 1
    }

    // MARK: - Filing opened EPUBs

    /// Folders the user has made for filing opened EPUBs. "All" is implicit
    /// (every opened EPUB); these are the named folders below it.
    private(set) var epubFolders: [String] =
        UserDefaults.standard.stringArray(forKey: "epubFolders") ?? []

    /// Which folder each opened EPUB is filed under, by record id.
    private(set) var epubFiling: [String: String] =
        (UserDefaults.standard.dictionary(forKey: "epubFiling") as? [String: String]) ?? [:]

    func addEPUBFolder(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              !epubFolders.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame })
        else { return }
        epubFolders.append(trimmed)
        UserDefaults.standard.set(epubFolders, forKey: "epubFolders")
    }

    func fileEPUB(_ id: String, under folder: String) {
        epubFiling[id] = folder
        UserDefaults.standard.set(epubFiling, forKey: "epubFiling")
    }

    func unfileEPUB(_ id: String) {
        guard epubFiling.removeValue(forKey: id) != nil else { return }
        UserDefaults.standard.set(epubFiling, forKey: "epubFiling")
    }

    /// The folder an opened EPUB is filed under, if any.
    func epubFolder(for id: String) -> String? { epubFiling[id] }

    // MARK: - Top of Pile and Set Aside

    /// Books pinned to the top of every Library list, by record id.
    private(set) var epubTopOfPile: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: "epubTopOfPile") ?? [])

    /// Books set aside — out of every list and view until brought back,
    /// by record id. They wait in the sidebar's Set Aside shelf.
    private(set) var epubSetAsideIDs: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: "epubSetAside") ?? [])

    func isTopOfPile(_ record: EPUBRecord) -> Bool { epubTopOfPile.contains(record.id) }
    func isSetAside(_ record: EPUBRecord) -> Bool { epubSetAsideIDs.contains(record.id) }

    func toggleTopOfPile(_ record: EPUBRecord) {
        if !epubTopOfPile.insert(record.id).inserted { epubTopOfPile.remove(record.id) }
        UserDefaults.standard.set(epubTopOfPile.sorted(), forKey: "epubTopOfPile")
        publishStanding()
    }

    func setAside(_ record: EPUBRecord) {
        if openEPUB?.id == record.folder { openEPUB = nil }
        epubSetAsideIDs.insert(record.id)
        UserDefaults.standard.set(epubSetAsideIDs.sorted(), forKey: "epubSetAside")
        publishStanding()
    }

    func bringBack(_ record: EPUBRecord) {
        epubSetAsideIDs.remove(record.id)
        UserDefaults.standard.set(epubSetAsideIDs.sorted(), forKey: "epubSetAside")
        publishStanding()
    }

    /// When this device last wrote the shared standing file — an older
    /// file read back never clobbers a newer local change.
    @ObservationIgnored private var standingWrittenAt: Date = .distantPast

    /// Writes the pinned/set-aside standing into the community folder,
    /// so the Vision Pro (and any other Mac) adopts it.
    private func publishStanding() {
        guard let folder = index.folderURL else { return }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        standingWrittenAt = EPUBStanding.write(pinned: epubTopOfPile,
                                               setAside: epubSetAsideIDs,
                                               concepts: viewConcepts,
                                               to: folder)
    }

    /// Adopts the shared standing when another device wrote it more
    /// recently than this one did.
    func adoptStanding() {
        guard let folder = index.folderURL else { return }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        guard let state = EPUBStanding.read(from: folder),
              state.modified > standingWrittenAt else { return }
        standingWrittenAt = state.modified
        epubTopOfPile = Set(state.pinned)
        epubSetAsideIDs = Set(state.setAside)
        UserDefaults.standard.set(epubTopOfPile.sorted(), forKey: "epubTopOfPile")
        UserDefaults.standard.set(epubSetAsideIDs.sorted(), forKey: "epubSetAside")
        // Concepts ride the same file; a file from before they
        // travelled leaves this device's list alone.
        if let concepts = state.concepts {
            viewConcepts = concepts
            UserDefaults.standard.set(viewConcepts, forKey: "viewConcepts")
        }
    }

    /// The records the lists and views show — everything not set aside.
    var shownEPUBRecords: [EPUBRecord] {
        epubRecords.filter { !epubSetAsideIDs.contains($0.id) }
    }

    /// The Set Aside shelf's records, in library order.
    var epubSetAsideRecords: [EPUBRecord] {
        epubRecords.filter { epubSetAsideIDs.contains($0.id) }
    }

    /// Top of Pile first, otherwise keeping the given order.
    func pinnedFirst(_ records: [EPUBRecord]) -> [EPUBRecord] {
        records.filter { isTopOfPile($0) } + records.filter { !isTopOfPile($0) }
    }

    /// Opened EPUBs the lists show, all of them or just those filed
    /// under `folder`. Set-aside books wait in their own shelf.
    func epubRecords(inFolder folder: String?) -> [EPUBRecord] {
        guard let folder else { return shownEPUBRecords }
        return shownEPUBRecords.filter { epubFiling[$0.id] == folder }
    }

    // MARK: - Views (Authors, People, Concepts)

    /// The distinct authors of the opened EPUBs, alphabetically — the
    /// "Authors" view. Built from the records' authors of record, every
    /// name a co-authored book carries; nothing the user has to curate.
    var epubAuthors: [String] {
        let names = Set(shownEPUBRecords.flatMap(\.authorList)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// The opened EPUBs carrying a given author of record — co-authored
    /// books appear under each of their authors.
    func epubRecords(byAuthor author: String) -> [EPUBRecord] {
        shownEPUBRecords.filter { record in
            record.authorList.contains {
                $0.trimmingCharacters(in: .whitespaces)
                    .caseInsensitiveCompare(author) == .orderedSame
            }
        }
    }

    // MARK: Venue aliases — merged journal names

    /// Venues the reader has declared the same: the written name → the
    /// name it files under. Papers write the same venue slightly
    /// differently (\acmConference here, a fuller \acmBooktitle there);
    /// "Is the Same As" folds them without touching any document.
    private(set) var venueAliases: [String: String] =
        (UserDefaults.standard.dictionary(forKey: "venueAliases") as? [String: String]) ?? [:]

    private func persistVenueAliases() {
        UserDefaults.standard.set(venueAliases, forKey: "venueAliases")
    }

    /// The name a venue files under once aliases are applied. Venue
    /// counts are small; the scan is nothing.
    func canonicalVenue(_ name: String) -> String {
        var current = name.trimmingCharacters(in: .whitespaces)
        var hops = 0
        while hops < 10,
              let match = venueAliases.first(where: {
                  $0.key.caseInsensitiveCompare(current) == .orderedSame }) {
            current = match.value
            hops += 1
        }
        return current
    }

    /// Declares one venue the same as another: its papers file under
    /// the other's name from now on, and it leaves the Journals list.
    /// Existing aliases are re-pointed so every one aims straight at
    /// the surviving name.
    func mergeVenue(_ alias: String, into target: String) {
        let aliasName = alias.trimmingCharacters(in: .whitespaces)
        let targetName = target.trimmingCharacters(in: .whitespaces)
        guard !aliasName.isEmpty, !targetName.isEmpty,
              aliasName.caseInsensitiveCompare(targetName) != .orderedSame else { return }
        venueAliases[aliasName] = targetName
        for (key, value) in venueAliases
        where value.caseInsensitiveCompare(aliasName) == .orderedSame {
            venueAliases[key] = targetName
        }
        persistVenueAliases()
    }

    /// Undoes a merge: the name stands on its own in Journals again.
    func separateVenue(_ alias: String) {
        let keys = venueAliases.keys.filter {
            $0.caseInsensitiveCompare(alias) == .orderedSame
        }
        guard !keys.isEmpty else { return }
        for key in keys { venueAliases.removeValue(forKey: key) }
        persistVenueAliases()
    }

    /// The written names filed under this venue by "Is the Same As" —
    /// what the Separate menu offers back.
    func aliasesFiled(under venue: String) -> [String] {
        venueAliases
            .filter { $0.value.caseInsensitiveCompare(venue) == .orderedSame }
            .map(\.key)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// The distinct journals and proceedings the opened EPUBs declare
    /// themselves part of, aliases folded in, alphabetically — the
    /// Journals view.
    var epubPublications: [String] {
        var names: [String] = []
        for record in shownEPUBRecords {
            guard let venue = record.venue.map(canonicalVenue) else { continue }
            if !names.contains(where: { $0.caseInsensitiveCompare(venue) == .orderedSame }) {
                names.append(venue)
            }
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// The opened EPUBs that are part of a given journal or proceedings,
    /// under whichever of its names their pages carry.
    func epubRecords(inPublication name: String) -> [EPUBRecord] {
        let wanted = canonicalVenue(name)
        return shownEPUBRecords.filter {
            $0.venue.map(canonicalVenue)?.caseInsensitiveCompare(wanted) == .orderedSame
        }
    }

    /// The set-aside books that are part of a given journal or
    /// proceedings — the venue drill-in shows them apart, below a rule.
    func epubSetAsideRecords(inPublication name: String) -> [EPUBRecord] {
        let wanted = canonicalVenue(name)
        return epubSetAsideRecords.filter {
            $0.venue.map(canonicalVenue)?.caseInsensitiveCompare(wanted) == .orderedSame
        }
    }

    /// People the user is tracking across the library — added by hand the
    /// way folders are. (Automatic extraction of names from the EPUBs is a
    /// later step; these are the user's own for now.)
    private(set) var viewPeople: [String] =
        UserDefaults.standard.stringArray(forKey: "viewPeople") ?? []

    /// Concepts the user is tracking across the library — added by hand,
    /// like folders and people. (Pulling concepts out of the EPUBs is a
    /// later step.)
    private(set) var viewConcepts: [String] =
        UserDefaults.standard.stringArray(forKey: "viewConcepts") ?? []

    func addPerson(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              !viewPeople.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame })
        else { return }
        viewPeople.append(trimmed)
        viewPeople.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        UserDefaults.standard.set(viewPeople, forKey: "viewPeople")
    }

    func removePerson(_ name: String) {
        guard let index = viewPeople.firstIndex(where: { $0.caseInsensitiveCompare(name) == .orderedSame })
        else { return }
        viewPeople.remove(at: index)
        UserDefaults.standard.set(viewPeople, forKey: "viewPeople")
    }

    func addConcept(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              !viewConcepts.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame })
        else { return }
        viewConcepts.append(trimmed)
        viewConcepts.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        UserDefaults.standard.set(viewConcepts, forKey: "viewConcepts")
        // Concepts travel in the standing file, so the Vision Pro's
        // arm offers the new one without waiting for a pin to change.
        publishStanding()
    }

    func removeConcept(_ name: String) {
        guard let index = viewConcepts.firstIndex(where: { $0.caseInsensitiveCompare(name) == .orderedSame })
        else { return }
        viewConcepts.remove(at: index)
        UserDefaults.standard.set(viewConcepts, forKey: "viewConcepts")
        publishStanding()
    }

    /// Asks for a person's name and adds them to the People view.
    func promptNewPerson() {
        guard let name = promptForName(title: "Add Person",
                                       message: "Name a person to track across the library.",
                                       placeholder: "Person’s name") else { return }
        addPerson(name)
    }

    /// Asks for a concept and adds it to the Concepts view.
    func promptNewConcept() {
        guard let name = promptForName(title: "Add Concept",
                                       message: "Name a concept to track across the library.",
                                       placeholder: "Concept") else { return }
        addConcept(name)
    }

    /// A one-field naming sheet, shared by the People and Concepts adders —
    /// the same modal the folder adder uses.
    private func promptForName(title: String, message: String, placeholder: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = placeholder
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// Asks for a folder name and adds it — optionally filing an EPUB there
    /// straightaway (used by "New Folder…" in a record's File Under menu).
    func promptNewEPUBFolder(fileAfter id: String? = nil) {
        let alert = NSAlert()
        alert.messageText = "New Folder"
        alert.informativeText = "Name a folder to file EPUBs under."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = "Folder name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        addEPUBFolder(name)
        if let id { fileEPUB(id, under: name) }
    }

    // MARK: - Community folder access

    private static let bookmarkKey = "communityFolderBookmark"
    private var securityScopedFolder: URL?
    #if os(macOS)
    /// Watches the community folder for EPUBs arriving (an export from Author,
    /// or an iCloud sync landing) so the Files list stays current live.
    private var epubFolderWatcher: FolderWatcher?
    #endif

    func restoreFolderAccess() {
        // Restore the chosen community folder on launch: reopen its
        // security scope, re-establish the index and the EPUB watch, and scan
        // for EPUBs already sitting in it (typically an iCloud folder the
        // community publishes into).
        guard securityScopedFolder == nil,
              let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope],
                                 relativeTo: nil, bookmarkDataIsStale: &isStale),
              url.startAccessingSecurityScopedResource() else { return }
        securityScopedFolder = url
        index.setFolder(url)
        watchCommunityFolderForEPUBs(url)
        scanCommunityFolderForEPUBs()
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose the folder your community publishes EPUBs into — typically an iCloud folder."
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        saveBookmark(for: url)
        securityScopedFolder?.stopAccessingSecurityScopedResource()
        _ = url.startAccessingSecurityScopedResource()
        securityScopedFolder = url
        index.setFolder(url)
        shareContacts(into: url)
        watchCommunityFolderForEPUBs(url)
        scanCommunityFolderForEPUBs()
    }

    /// Watches the community folder and rescans it for EPUBs when its contents
    /// change (a new export, an iCloud download completing).
    private func watchCommunityFolderForEPUBs(_ folder: URL) {
        #if os(macOS)
        epubFolderWatcher?.stop()
        epubFolderWatcher = FolderWatcher(url: folder) { [weak self] in
            Task { @MainActor in self?.scanCommunityFolderForEPUBs() }
        }
        #endif
    }

    /// Imports every EPUB found in the community folder into the Files list.
    /// New books arrive unread (bold) until opened; ones already imported are
    /// left untouched. iCloud placeholders are nudged to download, and the
    /// folder watch rescans once they land. Afterwards the mirror runs the
    /// other way: shelf books the folder lacks are published into it.
    func scanCommunityFolderForEPUBs() {
        guard let folder = index.folderURL else { return }
        LibraryScanner.requestICloudDownloads(in: folder)
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return }
        for case let url as URL in enumerator
        where url.pathExtension.lowercased() == "epub" {
            importEPUB(at: url)
        }
        mirrorShelfToCommunityFolder()
        adoptStanding()
        // The headset's wishes: cited works asked for as books, shown
        // in the Time view until acquired or dismissed.
        acquisitions = EPUBAcquisitions.read(from: folder)
        // Publication analyses live in the shared folder so visionOS reads the same data.
        // Migrate from UserDefaults once if the file doesn't exist yet.
        var analysesFile = AnalysesFile.read(from: folder)
        if analysesFile.analyses.isEmpty,
           let data = UserDefaults.standard.data(forKey: "publicationAnalyses"),
           let legacy = try? JSONDecoder().decode([String: PublicationAnalysis].self, from: data) {
            analysesFile.analyses = legacy
            analysesFile.write(to: folder)
            // Only remove the legacy key once the file is confirmed on disk.
            let migratedURL = folder.appendingPathComponent(AnalysesFile.filename)
            if FileManager.default.fileExists(atPath: migratedURL.path) {
                UserDefaults.standard.removeObject(forKey: "publicationAnalyses")
            }
        }
        publicationAnalyses = analysesFile.analyses
        globalPinnedAuthors = analysesFile.pinnedAuthors
        globalPinnedTopics = analysesFile.pinnedTopics
        // The citation graph shares the folder: adopt what other
        // devices fetched, then quietly research a few more works.
        CitationGraph.mirrorFolder = folder
        CitationGraph.adoptMirror(from: folder)
        prefetchCitationGraph()
        ensureSankeyData(in: folder)
        ensureFloorHistory(in: folder)
    }

    /// The floor's histories — every theme's Wikidata sweep, fetched
    /// once each and mirrored for the Vision Pro's floor. Themes the
    /// mirror already holds are left in peace.
    @ObservationIgnored private var isFetchingFloorHistory = false

    private func ensureFloorHistory(in folder: URL) {
        let missing = SankeySpace.FloorTheme.allCases.filter {
            SankeySpace.readFloorHistory(theme: $0, from: folder)?.events.isEmpty ?? true
        }
        guard !isFetchingFloorHistory, !missing.isEmpty else { return }
        isFetchingFloorHistory = true
        Task { @MainActor in
            defer { isFetchingFloorHistory = false }
            for theme in missing {
                guard let events = try? await SankeySpace.fetchFloorHistory(theme: theme),
                      !events.isEmpty else { continue }
                let scoped = folder.startAccessingSecurityScopedResource()
                defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
                SankeySpace.writeFloorHistory(
                    SankeySpace.FloorHistory(events: events, modified: .now),
                    theme: theme, to: folder)
            }
        }
    }

    /// Ticks when the Time Flows mirror changes, so the sidebar list
    /// rereads it.
    var timeFlowsRevision = 0

    /// Books the headset asked to acquire — the sidebar lists them with
    /// an ember dot and their download link.
    private(set) var acquisitions: [EPUBAcquisitions.Wanted] = []

    // MARK: Publication AI analysis

    /// Per-venue analysis results: topic keywords per paper, plus per-venue set-aside lists.
    struct PublicationAnalysis: Codable {
        var paperTopics: [String: [String]] = [:]   // record.id → [topic]
        var setAsideAuthors: Set<String> = []
        var setAsideTopics: Set<String> = []

        /// Visible topics after filtering set-aside items, sorted.
        var allTopics: [String] {
            Array(Set(paperTopics.values.flatMap { $0 }))
                .filter { !setAsideTopics.contains($0) }
                .sorted()
        }
    }

    /// On-disk container stored in the shared library folder so visionOS reads the same data.
    private struct AnalysesFile: Codable {
        var analyses: [String: PublicationAnalysis] = [:]
        var pinnedAuthors: [String] = []    // global — floats to top in every venue
        var pinnedTopics: [String] = []     // global — floats to top in every venue
        static let filename = "_publication-analyses.json"

        static func read(from folder: URL) -> AnalysesFile {
            let url = folder.appendingPathComponent(filename)
            guard let data = try? Data(contentsOf: url),
                  let file = try? JSONDecoder().decode(AnalysesFile.self, from: data)
            else { return AnalysesFile() }
            return file
        }

        func write(to folder: URL) {
            let url = folder.appendingPathComponent(Self.filename)
            if let data = try? JSONEncoder().encode(self) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private(set) var publicationAnalyses: [String: PublicationAnalysis] = [:]
    private(set) var globalPinnedAuthors: [String] = []
    private(set) var globalPinnedTopics: [String] = []

    /// Publications currently being analysed — drives the spinner in the sidebar.
    private(set) var analysisInProgress: Set<String> = []

    private func saveAnalysesFile() {
        guard let folder = index.folderURL else { return }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        var file = AnalysesFile()
        file.analyses = publicationAnalyses
        file.pinnedAuthors = globalPinnedAuthors
        file.pinnedTopics = globalPinnedTopics
        file.write(to: folder)
    }

    /// Analyses each paper in the venue with one LLM call each, storing per-paper topic lists.
    /// Re-analysis preserves existing set-aside author/topic lists.
    func analysePublication(_ name: String) async {
        guard !analysisInProgress.contains(name) else { return }
        analysisInProgress.insert(name)
        defer { analysisInProgress.remove(name) }

        let records = epubRecords(inPublication: name)
        guard !records.isEmpty else { return }

        var paperTopics: [String: [String]] = [:]
        for record in records {
            let prompt = """
                Title: \(record.title)
                Author: \(record.author)

                List 3 to 5 short topic keywords or phrases for this paper. \
                Reply with only a comma-separated list, nothing else.
                """
            guard let (text, _) = try? await OrigamiLLM.shared.respond(
                instructions: "Extract topic keywords from academic paper titles. Be concise and specific.",
                to: prompt)
            else { continue }

            let topics = text
                .components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0.count < 60 }
            paperTopics[record.id] = topics
        }

        var updated = publicationAnalyses[name] ?? PublicationAnalysis()
        updated.paperTopics = paperTopics
        publicationAnalyses[name] = updated
        saveAnalysesFile()
    }

    func pinGlobalAuthor(_ name: String) {
        guard !globalPinnedAuthors.contains(name) else { return }
        globalPinnedAuthors.append(name)
        saveAnalysesFile()
    }

    func unpinGlobalAuthor(_ name: String) {
        globalPinnedAuthors.removeAll { $0 == name }
        saveAnalysesFile()
    }

    func pinGlobalTopic(_ name: String) {
        guard !globalPinnedTopics.contains(name) else { return }
        globalPinnedTopics.append(name)
        saveAnalysesFile()
    }

    func unpinGlobalTopic(_ name: String) {
        globalPinnedTopics.removeAll { $0 == name }
        saveAnalysesFile()
    }

    func setAsideAuthor(_ author: String, inPublication pub: String) {
        var entry = publicationAnalyses[pub] ?? PublicationAnalysis()
        entry.setAsideAuthors.insert(author)
        publicationAnalyses[pub] = entry
        saveAnalysesFile()
    }

    func setAsideTopic(_ topic: String, inPublication pub: String) {
        var entry = publicationAnalyses[pub] ?? PublicationAnalysis()
        entry.setAsideTopics.insert(topic)
        publicationAnalyses[pub] = entry
        saveAnalysesFile()
    }

    /// Papers in a venue whose per-paper topic list contains the given topic.
    func epubRecords(inPublication venue: String, matchingTopic topic: String) -> [EPUBRecord] {
        let analysis = publicationAnalyses[venue]
        return epubRecords(inPublication: venue).filter { record in
            analysis?.paperTopics[record.id]?.contains {
                $0.localizedCaseInsensitiveCompare(topic) == .orderedSame
            } ?? false
        }
    }

    func removeAcquisition(_ id: String) {
        guard let folder = index.folderURL else { return }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        EPUBAcquisitions.remove(id: id, in: folder)
        acquisitions.removeAll { $0.id == id }
    }

    func addAcquisition(key: String, title: String, author: String, year: Int?, doi: String?) {
        guard !acquisitions.contains(where: { $0.id == key }),
              let folder = index.folderURL else { return }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let item = EPUBAcquisitions.Wanted(id: key, title: title, author: author,
                                           year: year, doi: doi, added: .now)
        EPUBAcquisitions.add(item, in: folder)
        acquisitions.append(item)
    }

    /// The time-spread's first data lines: New York's yearly min/max
    /// temperatures, fetched once from Open-Meteo and mirrored through
    /// the community folder for the Vision Pro's Sankey. Quiet when the
    /// mirror already holds data.
    @ObservationIgnored private var isFetchingSankey = false

    private func ensureSankeyData(in folder: URL) {
        guard !isFetchingSankey,
              SankeySpace.read(from: folder)?.series.isEmpty ?? true else { return }
        isFetchingSankey = true
        Task { @MainActor in
            defer { isFetchingSankey = false }
            guard let series = try? await SankeySpace.temperatureSeries(city: "New York")
            else { return }
            let scoped = folder.startAccessingSecurityScopedResource()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            SankeySpace.write(SankeySpace.Dataset(series: series, modified: .now),
                              to: folder)
        }
    }

    /// Quietly gathers what the shelf's cited works themselves cite —
    /// the second-order references the longer Maps draw — a budgeted
    /// handful per scan, one polite request a second, everything
    /// cached and mirrored for the Vision Pro. The full journal fills
    /// in over a few sessions rather than hammering the services once.
    @ObservationIgnored private var isPrefetchingGraph = false

    private func prefetchCitationGraph(budget: Int = 50) {
        guard CitationGraph.isEnabled, !isPrefetchingGraph else { return }
        isPrefetchingGraph = true
        Task { @MainActor in
            defer { isPrefetchingGraph = false }
            var remaining = budget
            var seen = Set<String>()
            for record in epubRecords {
                guard remaining > 0 else { break }
                guard let doc = index.byID[record.id]?.doc else { continue }
                for reference in doc.references {
                    guard remaining > 0 else { break }
                    let fields = BibTeXParser.first(reference.bibtex)?.fields ?? [:]
                    guard let title = fields["title"] ?? reference.citedAs,
                          !title.isEmpty else { continue }
                    let author = fields["author"] ?? ""
                    let key = CitationGraph.key(title: title, author: author)
                    guard seen.insert(key).inserted,
                          CitationGraph.cached(forKey: key) == nil else { continue }
                    await CitationGraph.references(
                        title: title,
                        author: author,
                        year: fields["year"].flatMap { Int($0.filter(\.isNumber).prefix(4)) },
                        doi: fields["doi"]?.lowercased())
                    remaining -= 1
                }
            }
        }
    }

    /// Publishes every shelf book the community folder lacks into it, as
    /// a packed EPUB — the folder is the library's shared truth, so
    /// visionOS (and any other Mac) reading the same iCloud folder shows
    /// the same journals and the same articles. Files are named by the
    /// book's unpack identity ("<folder>.epub"), the same identity every
    /// import derives, so no device ever re-imports its own copy.
    func mirrorShelfToCommunityFolder() {
        guard let folder = index.folderURL else { return }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        // The identities already present, however their files are named
        // — including still-undownloaded iCloud placeholders, so a book
        // another device published is never doubled.
        var present: Set<String> = []
        if let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsPackageDescendants]) {
            for case let url as URL in enumerator {
                var name = url.lastPathComponent
                if name.hasSuffix(".icloud") {
                    if name.hasPrefix(".") { name.removeFirst() }
                    name = String(name.dropLast(".icloud".count))
                }
                guard name.lowercased().hasSuffix(".epub") else { continue }
                name = String(name.dropLast(".epub".count))
                let identity = LiquidDoc.identityKeyID(inFileName: name) ?? name
                present.insert(identity.replacingOccurrences(of: "/", with: "_")
                    .replacingOccurrences(of: ":", with: "_"))
            }
        }
        for record in epubRecords where !present.contains(record.folder) {
            let unpacked = Self.epubsRoot.appendingPathComponent(record.folder,
                                                                 isDirectory: true)
            guard FileManager.default.fileExists(atPath:
                    unpacked.appendingPathComponent(record.contentSubpath).path),
                  let data = try? OrigamiEPUBExporter.pack(unpackedFolder: unpacked)
            else { continue }
            try? data.write(to: folder.appendingPathComponent(record.folder + ".epub"),
                            options: .atomic)
        }
    }

    // Write access matters: the folder carries the community's contact
    // information (People.json) and the bots' documents, both written by
    // this app.
    private func saveBookmark(for url: URL) {
        guard let data = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil, relativeTo: nil
        ) else { return }
        UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
    }

    /// Puts the contact directory into the community folder, where the
    /// phone and the headset find it. The user's own record is added
    /// first if the directory does not hold one yet — their name is the
    /// one iOS most needs to offer.
    private func shareContacts(into folder: URL) {
        if people.person(named: authorName) == nil {
            var me = Person(displayName: authorName)
            let identity = authorIdentity
            me.orcid = identity.orcid
            me.affiliation = identity.affiliation
            people.upsert(me)
        }
        people.attach(folder: folder)
        if people.communityWriteFailed {
            showNote("Contact information could not be written to the community folder — choose the folder again (File ▸ Choose Folder…) to renew write access.")
        }
    }

    // MARK: - List filtering and sorting

    var filteredEntries: [IndexEntry] {
        var entries = visibleEntries
        switch sortOrder {
        case .byTitle:
            entries.sort { $0.doc.title.localizedCaseInsensitiveCompare($1.doc.title) == .orderedAscending }
        case .byDate:
            entries.sort { $0.doc.listedDate > $1.doc.listedDate }
        }
        return entries
    }

    /// Dialog ▸ Timeline: every letter to and from the user — the
    /// community's letters plus the user's own published copies —
    /// month by month, the newest on top.
    var timelineGroups: [(label: String, entries: [IndexEntry])] {
        var letters = visibleEntries.filter { LettersListView.isLetter($0.doc) }
        let seen = Set(letters.map(\.doc.id))
        letters += drafts.published
            .filter { LettersListView.isLetter($0) && !seen.contains($0.id) && !isArchived($0) }
            .map { IndexEntry(doc: $0) }
        let entries = letters.sorted { $0.doc.listedDate > $1.doc.listedDate }
        var groups: [(label: String, entries: [IndexEntry])] = []
        for entry in entries {
            let label = entry.doc.date?.monthYearText
                ?? entry.doc.created.formatted(.dateTime.year().month(.wide))
            if groups.last?.label == label {
                groups[groups.count - 1].entries.append(entry)
            } else {
                groups.append((label: label, entries: [entry]))
            }
        }
        return groups
    }

    private var visibleEntries: [IndexEntry] {
        var entries = Array(index.byID.values)
        entries.removeAll { isMuted($0.doc.author) }
        // Documents filed under Archived live in the Filed list alone;
        // Everything and the timeline let them go. Any other folder is
        // just a place — its documents stay.
        entries.removeAll { isArchived($0.doc) }
        if !showSuperseded {
            let superseded = index.supersededIDs
            entries.removeAll { superseded.contains($0.id) }
        }
        if !searchText.isEmpty {
            entries = entries.filter { matches($0.doc) }
        }
        return entries
    }

    private func matches(_ doc: LiquidDoc) -> Bool {
        doc.title.localizedCaseInsensitiveContains(searchText)
            || doc.author.localizedCaseInsensitiveContains(searchText)
            || doc.onBehalfOf?.localizedCaseInsensitiveContains(searchText) == true
            || (doc.body ?? []).contains { $0.text.localizedCaseInsensitiveContains(searchText) }
    }

    // MARK: - Authoring

    let drafts = DraftStore()
    let people = PersonDirectory()
    /// What the library has taught the on-device model about each person,
    /// revised as their letters arrive. See PersonProfiles.swift.
    let profiles = PersonProfileStore()
    /// Every place the library's notes, letters, and transcripts have
    /// carried — kept even after the documents leave. See LocationView.swift.
    let locations = LocationRecord()

    /// The hook for views: a person's known personality, built on this
    /// Mac from their letters, or nil while there is nothing yet. Any
    /// view coloring people by character reads it from here.
    func personality(for name: String) -> String? {
        profiles.personality(for: name)
    }

    /// The continual pass: folds documents the profiles haven't seen into
    /// their authors' profiles. Called whenever the library index changes;
    /// costs nothing when there is nothing new.
    func digestAuthorProfiles() {
        profiles.digest(entries: Array(index.byID.values))
    }

    /// The bots' continual pass: every library change first refreshes the
    /// shelf from the folder's bot documents, then lets each bot judge
    /// the documents it has not yet seen. Superseded revisions, shelved
    /// letters, and the bot documents themselves are left alone. See
    /// BotsView.swift and BotDocument in LiquidDocWriting.swift.
    func digestBots() {
        bots.sync(entries: index.timeline, folder: index.folderURL)
        let superseded = index.supersededIDs
        let docs = index.byID.values.map(\.doc)
            .filter { !superseded.contains($0.id) && !isArchived($0)
                && $0.documentType != BotDocument.documentType }
        bots.digestAll(documents: docs)
    }

    /// The places pass: folds the locations of notes (desk and folder),
    /// letters, and transcripts into the permanent record of where the
    /// library has been. Called whenever the library index changes.
    func recordLocations() {
        let noteType = LiquidDoc.DocumentType.note.rawValue
        var docs = drafts.documents.filter { $0.documentType == noteType }
        docs += index.byID.values.map(\.doc).filter {
            $0.documentType == noteType
                || LettersListView.isLetter($0)
                || TranscriptsView.isTranscript($0)
        }
        locations.record(docs: docs)
    }
    let portraits = PersonPortraitStore()
    /// Bots: famous people, living or dead, standing in the library as
    /// readers. See BotsView.swift.
    let bots = BotStore()
    /// The letter post: published letters travel by Apple Mail, arriving
    /// ones are filed into the community folder. See LetterPost.swift.
    let letterPost = LetterPostStore()

    init() {
        letterPost.attach(self)
        migrateArchivedIDs()
        placeFinder.onPlace = { [weak self] place in
            self?.currentPlace = place
        }
        // Launch never asks for location permission — the dialog waits
        // for a deliberate act (publishing, turning sharing on). If
        // permission was already given, the place refreshes quietly.
        refreshPlace(promptIfNeeded: false)
        // The views' index reads the EPUB shelf; build it for the books
        // already on it.
        rebuildEPUBIndex()
    }

    /// The place this Mac last resolved — stamped onto a letter at
    /// publication when Settings ▸ Dialog shares it. See PlaceFinder
    /// in LocationView.swift.
    private(set) var currentPlace: String?
    private let placeFinder = PlaceFinder()

    /// Settings ▸ Dialog ▸ Share General Location: on unless turned off.
    var sharesGeneralLocation: Bool {
        UserDefaults.standard.object(forKey: AppSettings.shareGeneralLocationKey) as? Bool ?? true
    }

    /// Asks for a fresh place, so the next publication carries it.
    /// Never runs while sharing is off, and only shows the system's
    /// permission dialog when the caller is a deliberate act.
    func refreshPlace(promptIfNeeded: Bool = true) {
        guard sharesGeneralLocation else { return }
        placeFinder.begin(promptIfNeeded: promptIfNeeded)
    }
    var draftEditor: DraftEditor?
    var selectedDraftID: String?
    var selectedArchivedID: String?

    /// Testing aid: while active the whole app takes on the test identity —
    /// new drafts, attention bolding, and correspondent ranking all see the
    /// library as that person. The real identity in Settings stays stored
    /// and returns when switched off.
    var isTestAccountActive: Bool = UserDefaults.standard.bool(forKey: AppSettings.testAccountActiveKey) {
        didSet { UserDefaults.standard.set(isTestAccountActive, forKey: AppSettings.testAccountActiveKey) }
    }

    var testAccountName: String = UserDefaults.standard.string(forKey: AppSettings.testAccountNameKey) ?? "Test Reader" {
        didSet { UserDefaults.standard.set(testAccountName, forKey: AppSettings.testAccountNameKey) }
    }

    var authorName: String {
        get {
            if isTestAccountActive { return testAccountName }
            let stored = UserDefaults.standard.string(forKey: AppSettings.authorNameKey) ?? ""
            return stored.isEmpty ? NSFullUserName() : stored
        }
        set {
            if isTestAccountActive {
                testAccountName = newValue
            } else {
                UserDefaults.standard.set(newValue, forKey: AppSettings.authorNameKey)
            }
        }
    }

    /// The user's identity from Settings, for the Visual-Meta self-citation.
    /// The test account is name-only — it never carries the real title,
    /// ORCID, or affiliation.
    var authorIdentity: AuthorIdentity {
        if isTestAccountActive {
            return AuthorIdentity(name: testAccountName, personalTitle: "", orcid: "", affiliation: "")
        }
        let defaults = UserDefaults.standard
        return AuthorIdentity(
            name: authorName,
            personalTitle: defaults.string(forKey: AppSettings.authorTitleKey) ?? "",
            orcid: defaults.string(forKey: AppSettings.authorORCIDKey) ?? "",
            affiliation: defaults.string(forKey: AppSettings.authorAffiliationKey) ?? ""
        )
    }

    func newDraft() {
        // Words selected in the document being read travel into the new
        // document — captured before focus moves away. Selected in a
        // transcript, they are lifted as an extract on the speaker's
        // behalf; selected anywhere else they start a reply, the reader
        // choosing its kind; with nothing selected there is nothing to
        // ask — a new document is a Letter, the core kind.
        let selection = readingSelection()
        saveDraftIfNeeded()
        if let selection, let speaker = selection.speaker, let paragraph = selection.paragraph {
            liftExtract(statement: selection.text, speaker: speaker,
                        paragraph: paragraph, from: selection.doc)
            return
        }
        if let selection {
            guard let relation = askReplyKind(about: selection.doc) else { return }
            startDiscourse(relation, about: selection.doc)
            // The selected words arrive as a citation (§4).
            draftEditor?.bodyText =
                ContextActionBuilder.quote(selection.text, from: selection.doc) + "\n\n"
            return
        }
        do {
            let doc = try drafts.create(author: authorName,
                                        documentType: LiquidDoc.DocumentType.letter.rawValue)
            sidebarSelection = .drafts
            editDraft(doc)
        } catch {
            NSSound.beep()
            showNote("Could not create document: \(error.localizedDescription)")
        }
    }

    /// A new book: the long form begins like any draft, declared a book
    /// from birth so it lives under Books.
    func newBook() {
        saveDraftIfNeeded()
        do {
            let doc = try drafts.create(author: authorName,
                                        documentType: LiquidDoc.DocumentType.book.rawValue)
            sidebarSelection = .bookDrafts
            editDraft(doc)
        } catch {
            NSSound.beep()
            showNote("Could not create book: \(error.localizedDescription)")
        }
    }

    /// A new note on the desk: no questions asked, straight into the
    /// editor. Notes made elsewhere (voice capture and other producers)
    /// arrive through the folder instead.
    func newNote() {
        saveDraftIfNeeded()
        do {
            let doc = try drafts.create(author: authorName,
                                        documentType: LiquidDoc.DocumentType.note.rawValue)
            sidebarSelection = .notes
            selectedNoteID = doc.id
            editDraft(doc)
        } catch {
            NSSound.beep()
            showNote("Could not create note: \(error.localizedDescription)")
        }
    }

    /// The reply pop-up, shown only when words were selected: the new
    /// document answers the one being read — in which manner? Nil means
    /// the author thought better of it.
    private func askReplyKind(about doc: LiquidDoc) -> DocumentRelation? {
        let alert = NSAlert()
        alert.messageText = "New Reply"
        alert.informativeText = "The selected words travel into a reply to “\(doc.title)”. What kind of reply?"
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        for relation in DocumentRelation.discourseActions {
            popup.addItem(withTitle: relation.actionTitle ?? relation.rawValue)
        }
        popup.sizeToFit()
        alert.accessoryView = popup
        alert.window.initialFirstResponder = popup
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return DocumentRelation.discourseActions[popup.indexOfSelectedItem]
    }

    /// The live selection in the focused reader text view, with the
    /// paragraph it sits in and — in a transcript — whose words these are:
    /// the paragraph's own speaker, or the nearest attributed statement
    /// above. Nil when nothing is selected or the focus is not on read
    /// text, so plain ⌘N stays an empty document.
    private func readingSelection() -> (text: String, doc: LiquidDoc,
                                        paragraph: LiquidDoc.Paragraph?,
                                        speaker: String?)? {
        guard let textView = NSApp.keyWindow?.firstResponder
                as? ReaderTextView.ReaderNSTextView,
              let doc = textView.doc else { return nil }
        let range = textView.selectedRange()
        guard range.length > 0 else { return nil }
        let text = (textView.string as NSString).substring(with: range)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var speaker: String?
        if let paragraph = textView.paragraph {
            speaker = paragraph.speaker
            if speaker == nil, let body = doc.body,
               let index = body.firstIndex(where: { $0.id == paragraph.id }) {
                speaker = body[..<index].reversed().compactMap(\.speaker).first
            }
        }
        return (text, doc, textView.paragraph, speaker)
    }

    func editDraft(_ doc: LiquidDoc) {
        guard draftEditor?.docID != doc.id else { return }
        openEPUB = nil   // editing leaves the EPUB reader
        saveDraftIfNeeded()
        draftEditor = DraftEditor(doc: doc)
        selectedDraftID = doc.id
    }

    func saveDraft() {
        guard let draftEditor else { return }
        let doc = draftEditor.buildDocument()
        do {
            try drafts.save(doc)
            draftEditor.markSaved(doc)
            authorName = draftEditor.author
        } catch {
            NSSound.beep()
            showNote("Could not save: \(error.localizedDescription)")
        }
    }

    func saveDraftIfNeeded() {
        if draftEditor?.hasUnsavedChanges == true {
            saveDraft()
        }
    }

    /// ⌘W while writing: the just-opened editor closes instead of the
    /// window. An untouched empty document is deleted — nothing worth
    /// keeping is lost; anything with words is saved and stays in
    /// Drafts. The view goes back one, to wherever the writer stood
    /// before the document opened.
    func closeEditor() {
        guard let draftEditor else { return }
        let doc = draftEditor.buildDocument()
        let bodyIsEmpty = (doc.body ?? []).allSatisfy {
            $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let titleUnset = doc.title.trimmingCharacters(in: .whitespaces).isEmpty
            || doc.title == "Untitled"
        if bodyIsEmpty && titleUnset && doc.attention.isEmpty {
            deleteDraft(draftEditor.original)
        } else {
            saveDraftIfNeeded()
            self.draftEditor = nil
            selectedDraftID = nil
        }
        if let previousSidebarSelection, previousSidebarSelection != sidebarSelection {
            sidebarSelection = previousSidebarSelection
        }
    }

    func deleteDraft(_ doc: LiquidDoc) {
        drafts.delete(doc)
        if draftEditor?.docID == doc.id {
            draftEditor = nil
            selectedDraftID = nil
        }
    }

    /// Deletes a note wherever it lives: the file — a desk note's or a
    /// community-folder note's — goes to the Trash, recoverable there.
    func deleteNote(_ doc: LiquidDoc) {
        if drafts.documents.contains(where: { $0.id == doc.id }) {
            deleteDraft(doc)
            return
        }
        do {
            try FileManager.default.trashItem(at: doc.fileURL, resultingItemURL: nil)
            index.rescan()
        } catch {
            NSSound.beep()
            showNote("Could not delete “\(doc.title)”: \(error.localizedDescription)")
        }
    }

    /// Deletes a published copy: its file goes to the Trash. Copies the
    /// letter post already delivered stay with their recipients.
    func deletePublished(_ doc: LiquidDoc) {
        drafts.trashPublished(doc)
    }

    /// Exports the open editor's live contents (saving first). ⌘⇧E
    /// does the right thing for the kind: a book exports as an Origami
    /// Text EPUB; everything else exports as .origamitext.
    func exportDraft() {
        guard let draftEditor else { return }
        saveDraftIfNeeded()
        // Origami Text authors to EPUB — the format's distributable form —
        // regardless of the draft's internal kind.
        exportEPUB(draftEditor.buildDocument())
    }

    func export(draft doc: LiquidDoc) {
        if draftEditor?.docID == doc.id {
            exportDraft()
        } else {
            exportEPUB(doc)
        }
    }

    /// Exports the document as an Origami Text EPUB — the format's
    /// EPUB 3 profile: one semantic HTML file, Visual-Meta in the
    /// package and on the page. See OrigamiEPUB.swift.
    func exportEPUB(_ doc: LiquidDoc) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.epub]
        // The name carries the whole identity — full title, author, and
        // moment — so it stays unique and, unrenamed, the address
        // derives from it, exactly like the ecosystem's PDFs.
        panel.nameFieldStringValue = doc.identityFileName(extension: "epub")
        panel.canCreateDirectories = true
        panel.message = "Export this document as an Origami Text EPUB — readable in any EPUB reader, its Visual-Meta carried within."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try OrigamiEPUBExporter.write(
                doc: doc,
                resolve: { [index] id in index.byID[LiquidAddress.canonical(id)]?.doc },
                to: url)
            // Exporting a draft as an EPUB publishes it, exactly as the
            // .origamitext export does: the draft retires, and the
            // published .origamitext copy (appendix and all) becomes
            // the read-only record. Books never enter the letter post —
            // they travel as EPUBs, by hand.
            if drafts.documents.contains(where: { $0.id == doc.id }) {
                let record = VisualMeta.appendingAppendix(to: doc, identity: authorIdentity)
                try drafts.markPublished(draftID: doc.id, publishedDoc: record)
                if draftEditor?.docID == doc.id {
                    draftEditor = nil
                    selectedDraftID = nil
                }
                if doc.documentType == LiquidDoc.DocumentType.book.rawValue {
                    sidebarSelection = .booksPublished
                }
                if let published = drafts.published.first(where: { $0.id == doc.id }) {
                    open(published)
                }
                showNote("Published “\(doc.title)” as an EPUB")
            } else {
                showNote("Exported “\(url.lastPathComponent)”")
            }
        } catch {
            NSSound.beep()
            showNote("EPUB export failed: \(error.localizedDescription)")
        }
    }

    func exportDocument(_ doc: LiquidDoc) {
        refreshPlace()   // so the next publication has a fresh place
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType("info.futuretextlab.origami-doc") ?? .json]
        panel.nameFieldStringValue = doc.suggestedExportFileName
        panel.canCreateDirectories = true
        panel.message = "Export this document as .origamitext for sharing."

        // Provenance: much shared work is AI-produced (meeting summaries
        // especially). The author stays the human name — the one who
        // reviewed it and stands by it — and the AI production is declared
        // in the document and its Visual-Meta.
        let aiCheckbox = NSButton(checkboxWithTitle: "Produced by AI on behalf of \(doc.author)",
                                  target: nil, action: nil)
        aiCheckbox.state = doc.aiOnBehalf ? .on : .off

        // A document carrying someone else's words — a statement lifted
        // from a transcript — declares whose they are the same way: the
        // exporter stays the author, the speaker is named on the record.
        // One's own words need no declaration, so a speaker who is the
        // author themselves is not offered.
        var behalfCheckbox: NSButton?
        if let onBehalfOf = doc.onBehalfOf,
           onBehalfOf.caseInsensitiveCompare(doc.author) != .orderedSame {
            let checkbox = NSButton(checkboxWithTitle: "Exported by \(doc.author) on behalf of \(onBehalfOf)",
                                    target: nil, action: nil)
            checkbox.state = .on
            behalfCheckbox = checkbox
        }

        // Document type: what the author declares this to be, so readers
        // can triage without opening it. "None" leaves it unspecified.
        // The vocabulary is open — a token this app doesn't know (from
        // another writer) stays choosable so export never drops it.
        var typeTokens = LiquidDoc.DocumentType.allCases.map(\.rawValue)
        var typeLabels = LiquidDoc.DocumentType.allCases.map(\.displayName)
        if let existing = doc.documentType, !typeTokens.contains(existing) {
            typeTokens.append(existing)
            typeLabels.append(existing)
        }
        let typeControl = NSSegmentedControl(labels: ["None"] + typeLabels,
                                             trackingMode: .selectOne,
                                             target: nil, action: nil)
        // An undeclared document defaults to Letter — the core kind; the
        // author can still choose differently, or None.
        let letterSegment = (typeTokens.firstIndex(of: LiquidDoc.DocumentType.letter.rawValue) ?? -1) + 1
        typeControl.selectedSegment = doc.documentType.flatMap { typeTokens.firstIndex(of: $0) }.map { $0 + 1 }
            ?? letterSegment
        let typeRow = NSStackView(views: [NSTextField(labelWithString: "This document is:"), typeControl])
        typeRow.orientation = .horizontal
        typeRow.spacing = 8

        let stack = NSStackView(views: [typeRow, aiCheckbox] + (behalfCheckbox.map { [$0] } ?? []))
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 20, bottom: 12, right: 20)
        // The panel sizes itself to the accessory view; a generous minimum
        // width keeps the whole export file name readable in the Save As
        // field. This must be an Auto Layout constraint — a frame size set
        // on the stack view is recomputed away before the panel reads it.
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 920).isActive = true
        panel.accessoryView = stack

        guard panel.runModal() == .OK, let url = panel.url else { return }
        var doc = doc
        doc.aiOnBehalf = aiCheckbox.state == .on
        if let behalfCheckbox, behalfCheckbox.state == .off {
            doc.onBehalfOf = nil
        }
        // Older lifted documents may still carry a self-referential name.
        if doc.onBehalfOf?.caseInsensitiveCompare(doc.author) == .orderedSame {
            doc.onBehalfOf = nil
        }
        doc.documentType = typeControl.selectedSegment > 0 ? typeTokens[typeControl.selectedSegment - 1] : nil
        // A letter carries the place it was written when the author
        // shares it (Settings ▸ Dialog ▸ Share General Location) — a
        // place name, never coordinates, per the format.
        if doc.documentType == LiquidDoc.DocumentType.letter.rawValue,
           doc.location == nil, sharesGeneralLocation {
            doc.location = currentPlace
        }
        do {
            // Shared copies carry their metadata on the page, as an appendix.
            let exportDoc = VisualMeta.appendingAppendix(to: doc, identity: authorIdentity)
            try exportDoc.jsonData().write(to: url, options: .atomic)
            // Exporting a draft publishes it: the draft retires, the
            // published copy becomes the read-only record.
            if drafts.documents.contains(where: { $0.id == doc.id }) {
                try drafts.markPublished(draftID: doc.id, publishedDoc: exportDoc)
                if draftEditor?.docID == doc.id {
                    draftEditor = nil
                    selectedDraftID = nil
                }
                if let publishedDoc = drafts.published.first(where: { $0.id == doc.id }) {
                    sidebarSelection = .published
                    open(publishedDoc)
                }
                showNote("Published “\(doc.title)”")
                // Publishing is what puts a letter in the post.
                letterPost.notePublished(exportDoc)
            } else {
                showNote("Exported “\(url.lastPathComponent)”")
            }
        } catch {
            NSSound.beep()
            showNote("Export failed: \(error.localizedDescription)")
        }
    }

    /// Export to XR: merges the chosen documents and people into a copy of
    /// an Author (.liquid) document as Map nodes and connections.
    func exportToXR(documentIDs: Set<String>, people: Set<String>, includeConnections: Bool) {
        // The Author document that receives the web.
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = true   // .liquid packages show as folders if Author's type isn't registered
        openPanel.treatsFilePackagesAsDirectories = false
        openPanel.allowsMultipleSelection = false
        openPanel.message = "Choose the Author document (.liquid) whose Map will receive the export. It is copied, not modified."
        openPanel.prompt = "Receive Into"
        guard openPanel.runModal() == .OK, let source = openPanel.url else { return }

        let savePanel = NSSavePanel()
        savePanel.message = "Where to save the new Author document carrying the Origami web."
        savePanel.nameFieldStringValue = source.deletingPathExtension()
            .lastPathComponent + " + Origami.liquid"
        savePanel.canCreateDirectories = true
        guard savePanel.runModal() == .OK, var destination = savePanel.url else { return }
        if destination.pathExtension != "liquid" {
            destination.appendPathExtension("liquid")
        }

        var nodes: [AuthorMapExporter.Node] = []
        var connections: [AuthorMapExporter.Connection] = []
        let docs = documentIDs.compactMap { index.byID[$0]?.doc }.sorted { $0.listedDate < $1.listedDate }
        for doc in docs {
            let firstText = doc.body?.first(where: { $0.heading == nil && !$0.displayText.isEmpty })?
                .displayText.prefix(300)
            nodes.append(.init(key: doc.id,
                               phrase: doc.title,
                               description: "\(doc.displayAuthor), \(doc.listedDateText) — Origami document \(doc.id).\n\n\(firstText ?? "")",
                               tag: nil,
                               url: "origamitext://open/\(doc.id)",
                               date: doc.created,
                               z: 0))
        }
        for name in people.sorted() {
            let record = self.people.person(named: name)
            let affiliation = record?.affiliation.isEmpty == false ? " \(record?.affiliation ?? "")." : ""
            nodes.append(.init(key: "person:\(name)",
                               phrase: name,
                               description: "Voice in the Origami community.\(affiliation)",
                               tag: "person",
                               url: nil,
                               date: .now,
                               z: 0.4))
        }
        if includeConnections {
            for doc in docs {
                // Citations and discourse between exported documents.
                for link in doc.links where documentIDs.contains(LiquidAddress.canonical(link.to)) {
                    connections.append(.init(fromKey: doc.id, toKey: LiquidAddress.canonical(link.to)))
                }
                // Authorship, and who spoke in which meeting.
                if people.contains(doc.author) {
                    connections.append(.init(fromKey: "person:\(doc.author)", toKey: doc.id))
                }
                for speaker in Set((doc.body ?? []).compactMap(\.speaker)) where people.contains(speaker) {
                    connections.append(.init(fromKey: "person:\(speaker)", toKey: doc.id))
                }
            }
        }

        do {
            let added = try AuthorMapExporter.export(nodes: nodes, connections: connections,
                                                     from: source, to: destination)
            showNote("Exported \(added) nodes to “\(destination.lastPathComponent)” — open it in Author and choose the “Origami Web” layout.")
        } catch {
            NSSound.beep()
            showNote("Export to XR failed: \(error.localizedDescription)")
        }
    }

    /// Exports a library manifest: a dated snapshot of what the community
    /// folder holds, as an ordinary .origamitext document. Produced only on
    /// request — it is a record of a moment, never a maintained index; the
    /// folder itself remains the sole authority on what the library is.
    func exportLibraryManifest() {
        guard let folderURL = index.folderURL else {
            NSSound.beep()
            showNote("Choose a community folder first — the manifest describes it")
            return
        }
        let author = authorName
        let created = Date.now
        let id = LiquidAddress.makeID(author: author, created: created) { candidate in
            self.index.byID[candidate] != nil
                || self.drafts.documents.contains { $0.id == candidate }
        }
        let entries = index.timeline
        let authorCount = Set(entries.map { $0.doc.author.lowercased() }).count
        let folderName = folderURL.lastPathComponent
        let dateText = created.formatted(date: .long, time: .shortened)

        var paragraphs: [LiquidDoc.Paragraph] = []
        func add(_ text: String, heading: Int? = nil) {
            paragraphs.append(LiquidDoc.Paragraph(id: "p\(paragraphs.count + 1)",
                                                  heading: heading, text: text))
        }
        add("This is a snapshot of the library in “\(folderName)” as \(author) saw it on \(dateText): \(entries.count) \(entries.count == 1 ? "document" : "documents") by \(authorCount) \(authorCount == 1 ? "author" : "authors"). It was produced from the folder on request and is true only for that moment — the folder of documents is always the authority. Each entry ends with the document's address, which resolves in any library holding the document.")
        for entry in entries {
            let doc = entry.doc
            var line = "\(doc.title) — \(doc.displayAuthor), \(doc.listedDateText)"
            if let type = doc.documentType { line += " · \(type)" }
            if index.supersededIDs.contains(doc.id) { line += " · superseded" }
            if index.retractedIDs.contains(doc.id) { line += " · retracted" }
            add(line + " [\(doc.id)]")
        }
        if !index.unreadableFiles.isEmpty {
            add("Files not readable at snapshot time", heading: 2)
            for file in index.unreadableFiles {
                add("\(file.fileURL.lastPathComponent) — \(file.reason)")
            }
        }

        let doc = LiquidDoc(format: LiquidDoc.knownFormat,
                            id: id,
                            title: "Library Manifest — \(folderName), \(dateText)",
                            author: author,
                            created: created,
                            body: paragraphs,
                            links: [],
                            wraps: nil,
                            documentType: "manifest",
                            fileURL: FileManager.default.temporaryDirectory
                                .appendingPathComponent(id)
                                .appendingPathExtension(LiquidDoc.fileExtension))

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType("info.futuretextlab.origami-doc") ?? .json]
        panel.nameFieldStringValue = doc.suggestedExportFileName
        panel.canCreateDirectories = true
        panel.message = "Save a dated snapshot of the library. Saved into the community folder, it becomes a visible document like any other."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let exportDoc = VisualMeta.appendingAppendix(to: doc, identity: authorIdentity)
            try exportDoc.jsonData().write(to: url, options: .atomic)
            showNote("Exported manifest of \(entries.count) documents")
        } catch {
            NSSound.beep()
            showNote("Manifest export failed: \(error.localizedDescription)")
        }
    }

    /// The File ▸ Open… command. Presents an Open panel for any supported
    /// file: a native Origami Document opens in place, while an EPUB, PDF,
    /// Word, Markdown, or transcript file imports into a new draft. Routing
    /// (open vs. import) is decided by `openFile(at:)`.
    func openDocumentFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.treatsFilePackagesAsDirectories = false
        // EPUBs open; a LaTeX project (an Overleaf/Author zip, or a
        // bare .tex) imports — becoming an EPUB on the way in.
        panel.allowedContentTypes = [.epub, .zip]
            + (UTType(filenameExtension: "tex").map { [$0] } ?? [])
        panel.message = "Open an EPUB to read it, or a LaTeX project (.zip or .tex) to import."
        panel.prompt = "Open"
        panel.setContentSize(NSSize(width: 450, height: 600))
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { openFile(at: url) }
    }

    /// Imports an Author (.liquid) document, a Markdown (.md) file, or a
    /// Word (.docx/.doc) file as a new draft, ready to edit and export as .origamitext.
    func importDocumentFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true   // .liquid packages show as folders if Author's type isn't registered
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        // Keep this short: NSOpenPanel lays the message out on one line and
        // grows the window to fit it, then won't shrink below that width.
        panel.message = "Import a Word, Markdown, PDF, transcript, or LaTeX (zip/.tex) file."
        panel.prompt = "Import"
        // Room to browse. The panel is user-resizable on its own — touching
        // its style mask breaks the sandboxed panel's dragging — and macOS
        // remembers the size and sidebar width the user leaves it with.
        panel.setContentSize(NSSize(width: 450, height: 600))
        // The sidebar (Favorites and locations) is out of reach: the
        // system panel takes its width from Finder's preference domain
        // (FK_SidebarWidth2 in com.apple.finder), which a sandboxed app
        // cannot write. Users widen it by dragging the divider; macOS
        // keeps it system-wide.
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importFile(at: url)
    }

    /// Extensions the importer understands. Anything else opened or dropped
    /// is treated as a native Origami Document and decoded (see `openFile`).
    static let importableExtensions: Set<String> = [
        "epub", "pdf", "doc", "docx", "md", "markdown", "txt", "rtf", "rtfd", "liquid",
        "zip", "tex"
    ]

    /// Imports one file into a new draft — an Origami Text EPUB, a PDF with
    /// a text layer, a Word or Markdown file, a plain-text or RTF meeting
    /// transcript, or an Author document. Shared by the Import… panel, files
    /// opened from Finder or dropped on the app icon, and files dropped into
    /// the window.
    func importFile(at url: URL) {
        // Files arriving by Finder-open or drag carry their sandbox access
        // as a security-scoped resource; the Import… panel grants access a
        // different way, so starting it here is harmless there and necessary
        // for the open/drop paths.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let title: String
            let author: String
            let body: [LiquidDoc.Paragraph]
            var date: LiquidDate?
            var documentType: String?
            var concepts: [LiquidDoc.Concept] = []
            var layouts: [LiquidDoc.Layout] = []
            var mapConnections: [LiquidDoc.MapConnection] = []
            var references: [LiquidDoc.Reference] = []
            var tables: [LiquidDoc.Table] = []
            var assets: [LiquidDoc.Asset] = []
            var importedLinks: [LiquidDoc.Link] = []
            var preservedID: String?
            switch url.pathExtension.lowercased() {
            case "zip", "tex":
                // A LaTeX project becomes an EPUB in the library, not a
                // draft — the reverse of Author's LaTeX export.
                importLaTeX(at: url)
                return
            case "md", "markdown", "txt":
                // A file that reads as a meeting transcript (speaker names
                // before statements) keeps its attributions structurally.
                let text = try String(contentsOf: url, encoding: .utf8)
                if TranscriptImporter.looksLikeTranscript(text) {
                    let result = TranscriptImporter.importText(
                        text, fallbackTitle: url.deletingPathExtension().lastPathComponent)
                    title = result.title
                    author = authorName
                    body = result.body
                    date = result.date
                    documentType = LiquidDoc.DocumentType.transcript.rawValue
                } else {
                    let result = try MarkdownImporter.importFile(at: url)
                    title = result.title
                    author = result.author ?? authorName
                    body = result.body
                }
            case "rtf", "rtfd":
                // Meeting transcripts arrive as rich text; the plain text
                // is what matters.
                let attributed = try NSAttributedString(url: url, options: [:],
                                                        documentAttributes: nil)
                let text = attributed.string.strippingEmbeddedObjectMarkers
                let fallbackTitle = url.deletingPathExtension().lastPathComponent
                if TranscriptImporter.looksLikeTranscript(text) {
                    let result = TranscriptImporter.importText(text, fallbackTitle: fallbackTitle)
                    title = result.title
                    author = authorName
                    body = result.body
                    date = result.date
                    documentType = LiquidDoc.DocumentType.transcript.rawValue
                } else {
                    title = fallbackTitle
                    author = authorName
                    body = LiquidDoc.parseBody(from: text)
                }
            case "doc", "docx":
                let result = try WordImporter.importFile(at: url)
                title = result.title
                author = result.author ?? authorName
                body = result.body
                assets = result.assets
                references = result.references
                if let first = result.notices.first {
                    let more = result.notices.count - 1
                    showNote(more > 0 ? "\(first) (+\(more) more)" : first)
                }
            case "epub":
                // An Origami Text EPUB comes back whole: the body with
                // its stable paragraph ids, and the Visual-Meta layer —
                // concepts, citations (links and references), views,
                // connections. It returns as a book, like its source.
                let result = try OrigamiEPUBImporter.importDocument(at: url)
                title = result.title
                author = result.author ?? authorName
                body = result.body
                importedLinks = result.links
                concepts = result.concepts
                layouts = result.layouts
                mapConnections = result.mapConnections
                references = result.references
                tables = result.tables
                assets = result.assets
                date = result.date.flatMap(LiquidDate.init(isoString:))
                documentType = LiquidDoc.DocumentType.book.rawValue
                // The EPUB names its origami address: the book keeps
                // its identity here, so citations to it resolve. A
                // stripped EPUB still yields it from the file name's
                // identity key, PDF-style.
                preservedID = result.origamiID
                    ?? LiquidDoc.identityKeyID(
                        inFileName: url.deletingPathExtension().lastPathComponent)
            case "pdf":
                // Born-digital PDFs come across as paragraphs; a PDF
                // carrying Visual-Meta supplies its own title, author,
                // and date. Scans are declined with the reason.
                let result = try PDFImporter.importFile(at: url)
                title = result.title
                author = result.author ?? authorName
                body = result.body
                date = result.date
            default:
                let result = try AuthorImporter.importDocument(at: url)
                title = result.title
                author = result.author ?? authorName
                body = result.body
                // The knowledge layer arrives with the words: glossary
                // as concepts, the Map's arrangements as layouts, the
                // citation store as BibTeX references.
                concepts = result.concepts
                layouts = result.layouts
                mapConnections = result.mapConnections
                references = result.references
                // An Author document is the long form: it arrives as a
                // book, drafts under Books, and publishes as an EPUB.
                documentType = LiquidDoc.DocumentType.book.rawValue
            }
            let created = Date.now
            // An arriving document that names its own address keeps it,
            // unless something here already answers to it — then this
            // import is a copy and mints a fresh identity.
            let id: String
            if let preservedID = preservedID.map(LiquidAddress.canonical),
               LiquidAddress.isValid(preservedID),
               index.byID[preservedID] == nil,
               !drafts.documents.contains(where: { $0.id == preservedID }),
               !drafts.published.contains(where: { $0.id == preservedID }) {
                id = preservedID
            } else {
                id = LiquidAddress.makeID(author: author, created: created) { candidate in
                    self.index.byID[candidate] != nil
                        || self.drafts.documents.contains { $0.id == candidate }
                }
            }
            let doc = LiquidDoc(format: LiquidDoc.knownFormat,
                                id: id,
                                title: title,
                                author: author,
                                created: created,
                                body: body,
                                links: importedLinks,
                                wraps: nil,
                                date: date,
                                documentType: documentType,
                                concepts: concepts,
                                layouts: layouts,
                                mapConnections: mapConnections,
                                references: references,
                                tables: tables,
                                assets: assets,
                                fileURL: drafts.fileURL(for: id))
            try drafts.save(doc)
            // The draft opens where its kind lives on the sidebar.
            switch documentType {
            case LiquidDoc.DocumentType.book.rawValue:
                sidebarSelection = .bookDrafts
            case LiquidDoc.DocumentType.transcript.rawValue:
                sidebarSelection = .transcriptDrafts
            default:
                sidebarSelection = .drafts
            }
            editDraft(doc)
            let speakerNames = Set(body.compactMap(\.speaker))
            if speakerNames.isEmpty {
                showNote("Imported “\(title)” (\(body.count) paragraphs)")
            } else {
                showNote("Imported meeting transcript “\(title)” — \(body.count) statements by \(speakerNames.count) speakers")
            }
        } catch {
            NSSound.beep()
            showNote("Import failed: \(error.localizedDescription)")
        }
    }

    /// Lifts one transcript statement into a new draft of its own: the
    /// speaker's words become the body, a citation links back to the
    /// statement in the source, and `onBehalfOf` records whose words they
    /// are — the user is the author who prepares and exports the document,
    /// on the speaker's behalf. Publishing on someone's behalf also
    /// addresses them: the speaker starts on the attention list, visible
    /// as a removable chip in the editor.
    func liftStatement(_ paragraph: LiquidDoc.Paragraph, from source: LiquidDoc) {
        guard let speaker = paragraph.speaker else { return }
        liftExtract(statement: paragraph.displayText, speaker: speaker,
                    paragraph: paragraph, from: source)
    }

    /// The lift itself, for a whole statement or any selected span of one:
    /// the words become the body of a new extract draft, cited back to
    /// their paragraph, `onBehalfOf` the speaker.
    func liftExtract(statement: String, speaker: String,
                     paragraph: LiquidDoc.Paragraph, from source: LiquidDoc) {
        let author = authorName
        let isOwnWords = speaker.caseInsensitiveCompare(author) == .orderedSame
        let created = Date.now
        let id = LiquidAddress.makeID(author: author, created: created) { candidate in
            self.index.byID[candidate] != nil
                || self.drafts.documents.contains { $0.id == candidate }
        }
        let body = [
            LiquidDoc.Paragraph(id: "p1", heading: nil, text: statement),
            LiquidDoc.Paragraph(id: "p2", heading: nil,
                                text: "Spoken by \(speaker) in “\(source.title)”, \(source.listedDateText) [\(source.id)#\(paragraph.id)]"),
        ]
        // The way back: a span-scoped citation to the statement it was
        // lifted from.
        let link = LiquidDoc.Link(to: source.id, fragment: paragraph.id,
                                  rel: DocumentRelation.cites.rawValue, span: statement)
        let doc = LiquidDoc(format: LiquidDoc.knownFormat,
                            id: id,
                            title: "\(speaker) — \(source.title)",
                            author: author,
                            created: created,
                            body: body,
                            links: [link],
                            wraps: nil,
                            attention: isOwnWords ? [] : [speaker],
                            date: source.date,
                            // Lifting your own statement needs no
                            // declaration — you speak for yourself.
                            onBehalfOf: isOwnWords ? nil : speaker,
                            // The act names the kind: lifted from a
                            // transcript, this is an extract.
                            documentType: LiquidDoc.DocumentType.extract.rawValue,
                            fileURL: drafts.fileURL(for: id))
        do {
            try drafts.save(doc)
            sidebarSelection = .drafts
            editDraft(doc)
            showNote("Lifted \(speaker)’s statement into a new draft")
        } catch {
            NSSound.beep()
            showNote("Could not lift statement: \(error.localizedDescription)")
        }
    }

    /// Lift from the open draft's editor: the draft is saved first, so the
    /// citation in the lifted document points at a real, stable paragraph
    /// address in the transcript.
    func liftStatement(fromDraftParagraph paragraphText: String) {
        guard draftEditor != nil else { return }
        saveDraftIfNeeded()
        guard let source = draftEditor?.original else { return }
        let statement = paragraphText.trimmingCharacters(in: .whitespaces)
        guard let paragraph = (source.body ?? [])
            .first(where: { $0.speaker != nil && $0.text == statement }) else { return }
        liftStatement(paragraph, from: source)
    }

    // MARK: - Correspondents and muting

    /// The people the user most interacts with through documents — linked
    /// to or from, and addressed for attention — ranked by interaction
    /// count; other library authors fill the list up to ten.
    var topCorrespondents: [String] {
        var counts: [String: Int] = [:]
        func credit(_ name: String) {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !authorIdentity.matches(author: trimmed) else { return }
            counts[trimmed, default: 0] += 1
        }
        for entry in index.byID.values {
            let mine = authorIdentity.matches(author: entry.doc.author)
            for link in entry.doc.links {
                guard let target = index.byID[link.to] else { continue }
                if mine {
                    credit(target.doc.creditedAuthor)
                } else if authorIdentity.matches(author: target.doc.author) {
                    credit(entry.doc.creditedAuthor)
                }
            }
            if mine {
                entry.doc.attention.forEach(credit)
            } else if entry.doc.attention.contains(where: { authorIdentity.matches(author: $0) }) {
                credit(entry.doc.creditedAuthor)
            }
        }
        var ranked = counts
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map(\.key)
        if ranked.count < 10 {
            let already = Set(ranked.map { $0.lowercased() })
            let others = Set(index.byID.values.map {
                $0.doc.author.trimmingCharacters(in: .whitespaces)
            })
            .filter { !$0.isEmpty && !authorIdentity.matches(author: $0) && !already.contains($0.lowercased()) }
            .sorted()
            ranked.append(contentsOf: others)
        }
        return Array(ranked.prefix(10))
    }

    /// People whose documents are hidden from the library lists. The files
    /// themselves are untouched.
    var mutedAuthors: [String] = UserDefaults.standard.stringArray(forKey: "mutedAuthors") ?? [] {
        didSet { UserDefaults.standard.set(mutedAuthors, forKey: "mutedAuthors") }
    }

    func isMuted(_ author: String) -> Bool {
        let trimmed = author.trimmingCharacters(in: .whitespaces)
        return mutedAuthors.contains { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    /// The note now selected in the Notes list.
    var selectedNoteID: String?

    /// Notes, newest first: the desk's own quick documents plus any notes
    /// that arrived through the community folder — voice capture and
    /// other producers write notes too.
    var filteredNotes: [LiquidDoc] {
        let noteType = LiquidDoc.DocumentType.note.rawValue
        var seen: Set<String> = []
        var notes: [LiquidDoc] = []
        for doc in drafts.documents where doc.documentType == noteType {
            if seen.insert(doc.id).inserted { notes.append(doc) }
        }
        for entry in index.timeline where entry.doc.documentType == noteType {
            if seen.insert(entry.doc.id).inserted { notes.append(entry.doc) }
        }
        let sorted = notes.sorted { $0.listedDate > $1.listedDate }
        guard !searchText.isEmpty else { return sorted }
        return sorted.filter { matches($0) }
    }

    var filteredDrafts: [LiquidDoc] {
        // Notes keep their own place in the sidebar.
        let all = drafts.documents.filter {
            $0.documentType != LiquidDoc.DocumentType.note.rawValue
        }
        guard !searchText.isEmpty else { return all }
        return all.filter { matches($0) }
    }

    var filteredPublished: [LiquidDoc] {
        // A shelved published letter shows in the Library's Archived
        // list alone, like every archived document.
        let all = drafts.published.filter { !isArchived($0) }
        guard !searchText.isEmpty else { return all }
        return all.filter { matches($0) }
    }

    var filteredArchived: [LiquidDoc] {
        let all = drafts.archived
        guard !searchText.isEmpty else { return all }
        return all.filter { matches($0) }
    }

    /// Shelves a draft: it leaves Drafts for Archived, nothing deleted.
    func archiveDraft(_ doc: LiquidDoc) {
        if draftEditor?.docID == doc.id {
            saveDraftIfNeeded()
            draftEditor = nil
            selectedDraftID = nil
        }
        do {
            try drafts.archive(doc)
            showNote("Archived “\(doc.title)” — find it under Archived")
        } catch {
            NSSound.beep()
            showNote("Could not archive: \(error.localizedDescription)")
        }
    }

    /// Corrects a document's declared type in place: import can guess
    /// (a transcript), the reader can overrule, and the correction is
    /// written into the file itself, wherever it lives. Any Visual-Meta
    /// appendix baked into the body has its document-type field corrected
    /// too, so the page and the JSON never disagree.
    func setDocumentType(_ doc: LiquidDoc, to type: LiquidDoc.DocumentType) {
        let correctedBody: [LiquidDoc.Paragraph]? = doc.body.map { body in
            guard let oldType = doc.documentType else { return body }
            return body.map { paragraph in
                guard paragraph.text.contains("document-type = {\(oldType)}") else { return paragraph }
                return LiquidDoc.Paragraph(
                    id: paragraph.id,
                    heading: paragraph.heading,
                    text: paragraph.text.replacingOccurrences(of: "document-type = {\(oldType)}",
                                                              with: "document-type = {\(type.rawValue)}"),
                    speaker: paragraph.speaker)
            }
        }
        let updated = LiquidDoc(format: doc.format, id: doc.id, title: doc.title,
                                author: doc.author, created: doc.created,
                                body: correctedBody, links: doc.links, wraps: doc.wraps,
                                attention: doc.attention, date: doc.date,
                                aiOnBehalf: doc.aiOnBehalf, onBehalfOf: doc.onBehalfOf,
                                documentType: type.rawValue, fileURL: doc.fileURL)
        do {
            try updated.jsonData().write(to: doc.fileURL, options: .atomic)
            if drafts.documents.contains(where: { $0.id == doc.id })
                || drafts.published.contains(where: { $0.id == doc.id })
                || drafts.archived.contains(where: { $0.id == doc.id }) {
                drafts.reload()
            } else {
                index.rescan()
            }
            refreshCurrent(with: updated)
            showNote("“\(doc.title)” is now a \(type.displayName.lowercased())")
        } catch {
            NSSound.beep()
            showNote("Could not change the type: \(error.localizedDescription)")
        }
    }

    /// Declares a document a transcript and processes it as one: every
    /// paragraph opening "Name: …" gains its structural speaker, and
    /// the declared type — on the page and in the Visual-Meta appendix
    /// both — becomes transcript, so lifting, speaker attribution, and
    /// Summary & Notes all apply. The correction is written into the
    /// document itself, like the type corrections the reader already
    /// makes; everything else the document carries rides through.
    func processTranscript(_ doc: LiquidDoc) {
        let transcript = LiquidDoc.DocumentType.transcript.rawValue
        let appendix = doc.visualMetaParagraphIDs
        // Attribution follows the importer's principle: a name earns
        // its statements by recurring — real conversation alternates —
        // or by already being someone the community knows. A colon
        // after a few words of prose ("The problem is this: …") does
        // not make a speaker.
        var nameCounts: [String: Int] = [:]
        for paragraph in doc.body ?? []
        where paragraph.heading == nil && !appendix.contains(paragraph.id) {
            if let name = TranscriptImporter.speakerName(inStatement: paragraph.text) {
                nameCounts[name, default: 0] += 1
            }
        }
        let existingSpeakers = Set((doc.body ?? []).compactMap(\.speaker))
        func qualifies(_ name: String) -> Bool {
            (nameCounts[name] ?? 0) >= 2
                || existingSpeakers.contains(name)
                || people.person(named: name) != nil
        }
        var attributed = 0
        let body: [LiquidDoc.Paragraph]? = doc.body.map { body in
            body.map { paragraph in
                var text = paragraph.text
                if let oldType = doc.documentType, oldType != transcript,
                   text.contains("document-type = {\(oldType)}") {
                    text = text.replacingOccurrences(of: "document-type = {\(oldType)}",
                                                     with: "document-type = {\(transcript)}")
                }
                var speaker = paragraph.speaker
                if speaker == nil, paragraph.heading == nil, !appendix.contains(paragraph.id),
                   let name = TranscriptImporter.speakerName(inStatement: text),
                   qualifies(name) {
                    speaker = name
                    attributed += 1
                }
                return LiquidDoc.Paragraph(id: paragraph.id, heading: paragraph.heading,
                                           text: text, speaker: speaker)
            }
        }
        let updated = LiquidDoc(format: doc.format, id: doc.id, title: doc.title,
                                author: doc.author, created: doc.created,
                                body: body, links: doc.links, wraps: doc.wraps,
                                attention: doc.attention, date: doc.date,
                                aiOnBehalf: doc.aiOnBehalf, onBehalfOf: doc.onBehalfOf,
                                documentType: transcript,
                                location: doc.location,
                                concepts: doc.concepts,
                                layouts: doc.layouts,
                                mapConnections: doc.mapConnections,
                                references: doc.references,
                                fileURL: doc.fileURL)
        do {
            try updated.jsonData().write(to: doc.fileURL, options: .atomic)
            if drafts.documents.contains(where: { $0.id == doc.id })
                || drafts.published.contains(where: { $0.id == doc.id })
                || drafts.archived.contains(where: { $0.id == doc.id }) {
                drafts.reload()
            } else {
                index.rescan()
            }
            refreshCurrent(with: updated)
            showNote(attributed > 0
                     ? "Processed “\(doc.title)” as a transcript — \(attributed) \(attributed == 1 ? "statement" : "statements") attributed"
                     : "“\(doc.title)” is now a transcript")
        } catch {
            NSSound.beep()
            showNote("Could not process the transcript: \(error.localizedDescription)")
        }
    }

    // MARK: - Transcript summaries

    /// Every document that `summarizes` this transcript — in the
    /// library or on the desk.
    private func summaryDocuments(for transcript: LiquidDoc) -> [LiquidDoc] {
        (index.byID.values.map(\.doc) + drafts.documents).filter { doc in
            doc.links.contains {
                $0.rel == DocumentRelation.summarizes.rawValue
                    && LiquidAddress.canonical($0.to) == transcript.id
            }
        }
    }

    /// The transcript's summary document, when one exists: the newest
    /// document that `summarizes` it.
    func transcriptSummaryDocument(for transcript: LiquidDoc) -> LiquidDoc? {
        summaryDocuments(for: transcript).max { $0.created < $1.created }
    }

    /// Writes a summary beside its transcript as an ordinary linked
    /// document: into the community folder (Visual-Meta appendix and
    /// all) for a library transcript, or onto the desk as a draft for
    /// a transcript still being prepared — publishable and shareable
    /// like anything else. Redoing replaces: this author's earlier
    /// summaries of the same transcript go to the Trash.
    @discardableResult
    func saveTranscriptSummary(_ summary: TranscriptSummary,
                               for transcript: LiquidDoc) -> LiquidDoc? {
        let author = authorName
        guard !author.isEmpty else {
            showNote("Set your name in Settings → Author first — the summary carries it.")
            return nil
        }
        let id = LiquidAddress.makeID(author: author, created: summary.generated) { candidate in
            self.index.byID[candidate] != nil
                || self.drafts.documents.contains { $0.id == candidate }
        }
        let inLibrary = index.byID[transcript.id] != nil
        let fileURL = inLibrary
            ? transcript.fileURL.deletingLastPathComponent()
                .appendingPathComponent(id)
                .appendingPathExtension(LiquidDoc.fileExtension)
            : drafts.fileURL(for: id)
        var doc = summary.makeDocument(for: transcript, author: author,
                                       id: id, fileURL: fileURL)
        if inLibrary {
            // Shared copies carry their metadata on the page.
            doc = VisualMeta.appendingAppendix(to: doc, identity: authorIdentity)
        }
        let superseded = summaryDocuments(for: transcript)
            .filter { authorIdentity.matches(author: $0.author) }
        do {
            try doc.jsonData().write(to: fileURL, options: .atomic)
            for old in superseded where old.id != id {
                try? FileManager.default.trashItem(at: old.fileURL, resultingItemURL: nil)
            }
            if inLibrary {
                index.rescan()
            } else {
                drafts.reload()
            }
            showNote(inLibrary
                     ? "Saved “\(doc.title)” into the library, linked to the transcript"
                     : "Saved “\(doc.title)” to Drafts, linked to the transcript")
            return doc
        } catch {
            NSSound.beep()
            showNote("Could not save the summary: \(error.localizedDescription)")
            return nil
        }
    }

    /// Removes a summary document: its file goes to the Trash,
    /// recoverable there like every other deletion.
    func removeTranscriptSummary(_ doc: LiquidDoc) {
        try? FileManager.default.trashItem(at: doc.fileURL, resultingItemURL: nil)
        if drafts.documents.contains(where: { $0.id == doc.id }) {
            drafts.reload()
        } else {
            index.rescan()
        }
    }

    /// Replaces the reader's current document in place (same id), so a
    /// correction shows immediately without a navigation step.
    private func refreshCurrent(with doc: LiquidDoc) {
        guard history.indices.contains(historyPosition),
              history[historyPosition].doc.id == doc.id else { return }
        history[historyPosition] = Destination(doc: doc, fragment: history[historyPosition].fragment)
    }

    /// Returns an archived draft to Drafts, exactly as it left.
    func unarchiveDraft(_ doc: LiquidDoc) {
        do {
            try drafts.unarchive(doc)
            if selectedArchivedID == doc.id { selectedArchivedID = nil }
            showNote("“\(doc.title)” is a draft again")
        } catch {
            NSSound.beep()
            showNote("Could not un-archive: \(error.localizedDescription)")
        }
    }

    // MARK: - Supersede and follow up (published documents)

    /// Starts a new version of a published document: same content, versioned
    /// title, and a `revises` link so revision chains, superseded-hiding,
    /// and the Visual-Meta record all know.
    func supersede(_ doc: LiquidDoc) {
        startDerivedDraft(from: doc,
                          title: Self.incrementedVersionTitle(doc.title),
                          rel: "revises",
                          copyBody: true)
    }

    /// Starts a follow-up to a published document: fresh content, linked
    /// with `responds-to` so the two stay connected.
    func followUp(_ doc: LiquidDoc) {
        startDerivedDraft(from: doc,
                          title: "\(doc.title) (follow up)",
                          rel: "responds-to",
                          copyBody: false)
    }

    /// Starts a discourse document about someone else's work: "Respond",
    /// "Extend", or "Disagree" — a titled draft linked with that relation.
    func startDiscourse(_ relation: DocumentRelation, about doc: LiquidDoc) {
        guard let prefix = relation.titlePrefix else { return }
        startDerivedDraft(from: doc,
                          title: "\(prefix)\(doc.title)",
                          rel: relation.rawValue,
                          copyBody: false)
    }

    /// Resolves a document from anywhere it might live: the community
    /// index, the published shelf, or drafts.
    func document(for id: String) -> LiquidDoc? {
        index.byID[id]?.doc
            ?? drafts.published.first(where: { $0.id == id })
            ?? drafts.documents.first(where: { $0.id == id })
    }

    func title(for id: String) -> String? {
        document(for: id)?.title
    }

    /// Starts a fresh, unlinked document from this content.
    func useAsTemplate(_ doc: LiquidDoc) {
        startDerivedDraft(from: doc,
                          title: "\(doc.title) (new)",
                          rel: nil,
                          copyBody: true)
    }

    /// Starts a retraction notice: itself a published statement carrying a
    /// `retracts` link, so every reader's index marks the target withdrawn.
    func retract(_ doc: LiquidDoc) {
        startDerivedDraft(from: doc,
                          title: "Retraction of \(doc.title)",
                          rel: "retracts",
                          copyBody: false,
                          templateBody: [LiquidDoc.Paragraph(
                              id: "p1",
                              heading: nil,
                              text: "This document retracts “\(doc.title)” [\(doc.id)].")])
    }

    private func startDerivedDraft(from doc: LiquidDoc, title: String, rel: String?,
                                   copyBody: Bool,
                                   templateBody: [LiquidDoc.Paragraph]? = nil) {
        saveDraftIfNeeded()
        do {
            let draft = try drafts.create(author: authorName)
            let appendixIDs = doc.visualMetaParagraphIDs
            let body = templateBody
                ?? (copyBody ? (doc.body ?? []).filter { !appendixIDs.contains($0.id) } : [])
            let links = rel.map { [LiquidDoc.Link(to: doc.id, fragment: nil, rel: $0)] } ?? []
            let derived = LiquidDoc(format: draft.format,
                                    id: draft.id,
                                    title: title,
                                    author: draft.author,
                                    created: draft.created,
                                    body: body,
                                    links: links,
                                    wraps: nil,
                                    fileURL: draft.fileURL)
            try drafts.save(derived)
            sidebarSelection = .drafts
            editDraft(derived)
        } catch {
            NSSound.beep()
            showNote("Could not create the new document: \(error.localizedDescription)")
        }
    }

    /// "Title" -> "Title (v2)"; "Title (v2)" -> "Title (v3)".
    private static func incrementedVersionTitle(_ title: String) -> String {
        if let regex = try? NSRegularExpression(pattern: "^(.*)\\(v(\\d+)\\)\\s*$"),
           let match = regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
           let baseRange = Range(match.range(at: 1), in: title),
           let numberRange = Range(match.range(at: 2), in: title),
           let number = Int(title[numberRange]) {
            let base = String(title[baseRange]).trimmingCharacters(in: .whitespaces)
            return "\(base) (v\(number + 1))"
        }
        return "\(title) (v2)"
    }

    // MARK: - Library insights

    var selectedAuthor: String?

    /// Opens the Authors view on the named person — speaker labels and
    /// byline names route here.
    func openAuthorPage(named name: String) {
        sidebarSelection = .view("authors")
        selectedAuthor = name
    }

    /// Everything the named person has said across meeting transcripts.
    func statements(by name: String) -> [SpokenStatement] {
        LibraryInsights.statements(by: name, byID: index.byID)
    }

    var authorSummaries: [AuthorSummary] {
        var summaries = LibraryInsights.authors(byID: index.byID)
        // Names answering to the same contact record read as one author:
        // a merged record's aliases fold its other spellings in, letters
        // and connections combined under the record's display name.
        var order: [String] = []
        var groups: [String: (display: String, members: [AuthorSummary])] = [:]
        for summary in summaries {
            let person = people.person(named: summary.name)
            let key = person.map { "person:\($0.localID)" } ?? "name:\(summary.name.lowercased())"
            if groups[key] == nil {
                order.append(key)
                groups[key] = (person?.displayName ?? summary.name, [])
            }
            groups[key]?.members.append(summary)
        }
        summaries = order.compactMap { key -> AuthorSummary? in
            guard let group = groups[key] else { return nil }
            if group.members.count == 1, group.members[0].name == group.display {
                return group.members[0]
            }
            return Self.combinedSummary(group.members, name: group.display)
        }
        // Everyone in People is an author: records without documents yet
        // (File → New Author) follow the document-derived authors, so a
        // newly added person is visible immediately.
        let known = Set(summaries.map { $0.name.lowercased() })
        let recordOnly = people.people
            .filter { !$0.displayName.isEmpty && !known.contains($0.displayName.lowercased()) }
            .map { AuthorSummary(name: $0.displayName, entries: [], cites: [], citedBy: []) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        summaries.append(contentsOf: recordOnly)
        if !searchText.isEmpty {
            summaries = summaries.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
        return summaries
    }

    /// Several spellings of one person, read as a single author: their
    /// letters interleaved by date, their citation counts summed.
    private static func combinedSummary(_ members: [AuthorSummary],
                                        name: String) -> AuthorSummary {
        let entries = members.flatMap(\.entries).sorted { $0.doc.created < $1.doc.created }
        func combine(_ lists: [[AuthorLinkCount]]) -> [AuthorLinkCount] {
            var counts: [String: Int] = [:]
            for item in lists.flatMap({ $0 }) {
                counts[item.name, default: 0] += item.count
            }
            return counts.map { AuthorLinkCount(name: $0.key, count: $0.value) }
                .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
        }
        return AuthorSummary(name: name,
                             entries: entries,
                             cites: combine(members.map(\.cites)),
                             citedBy: combine(members.map(\.citedBy)))
    }

    /// Applies an approved merge of two contact records: the originals
    /// leave the directory, the approved card stands, and a portrait
    /// the absorbed record had follows when the surviving one has none.
    func approveMergedPerson(_ merged: Person, replacing originals: [Person]) {
        if portraits.original(for: merged.localID) == nil,
           let donor = originals.first(where: {
               $0.localID != merged.localID && portraits.original(for: $0.localID) != nil
           }),
           let photo = portraits.original(for: donor.localID) {
            portraits.adoptPhoto(photo, for: merged.localID)
        }
        for original in originals {
            people.remove(original)
        }
        people.upsert(merged)
        showNote("Merged into “\(merged.displayName)” — every name on the record answers to it now")
    }

    var hotParagraphs: [HotParagraph] {
        var paragraphs = LibraryInsights.hotParagraphs(byID: index.byID, backlinks: index.backlinks)
        if !searchText.isEmpty {
            paragraphs = paragraphs.filter {
                $0.paragraph.text.localizedCaseInsensitiveContains(searchText)
                    || $0.doc.title.localizedCaseInsensitiveContains(searchText)
                    || $0.doc.author.localizedCaseInsensitiveContains(searchText)
            }
        }
        return paragraphs
    }

    var healthReport: HealthReport {
        LibraryInsights.healthReport(byID: index.byID,
                                     backlinks: index.backlinks,
                                     unreadable: index.unreadableFiles,
                                     superseded: index.supersededIDs)
    }

    // MARK: - Misc

    /// Puts a pure BibTeX citation for the document on the pasteboard —
    /// with the reader's whole-document annotation as an extra field
    /// when one is written. Pasted into a draft, the private flavour
    /// still becomes a structured `cites` link on save.
    func copyCitation(doc: LiquidDoc, paragraphID: String? = nil) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let year = doc.date?.yearText ?? String(calendar.component(.year, from: doc.created))
        let annotation = documentAnnotation(forAddress: doc.id)?.body?.value
        CitationClipboard.write(OrigamiCitation(
            to: doc.id, fragment: paragraphID, rel: "cites",
            quotedText: doc.title, author: doc.displayAuthor, year: year,
            bibtex: OrigamiReading.bibTeXEntry(for: doc, fragment: paragraphID,
                                               annotation: annotation)))
        showNote("Citation copied as BibTeX")
    }

    func copyParagraphLink(doc: LiquidDoc, paragraphID: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("[\(doc.id)#\(paragraphID)]", forType: .string)
        showNote("Link copied")
    }

    func showNote(_ text: String) {
        let token = UUID()
        noteToken = token
        transientNote = text
        Task {
            try? await Task.sleep(for: .seconds(3))
            if noteToken == token { transientNote = nil }
        }
    }
}
