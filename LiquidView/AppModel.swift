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

/// App-wide state: the index, navigation history, folder access, and the
/// single `follow` entry point that all link navigation routes through.
@MainActor @Observable
final class AppModel {
    let index = LibraryIndex()

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

    var sidebarSelection: SidebarItem? = .timeline {
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
    var canGoBack: Bool { historyPosition > 0 }
    var canGoForward: Bool { !history.isEmpty && historyPosition < history.count - 1 }

    var fragmentRequest: FragmentRequest?
    private(set) var transientNote: String?
    private var noteToken = UUID()

    // MARK: - UI state

    var showLinksInspector = false
    var showXRExport = false
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
        return unread + read
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
        do {
            let data = try Data(contentsOf: url)
            let doc = try LiquidDoc.decode(data: data, fileURL: url)
            // Prefer the indexed copy so backlinks and revision state stay consistent.
            if let entry = index.byID[doc.id], entry.doc.fileURL == doc.fileURL {
                open(entry.doc)
            } else {
                open(doc)
            }
        } catch {
            NSSound.beep()
            showNote("Could not open “\(url.lastPathComponent)”: \(error.localizedDescription)")
        }
    }

    // MARK: - Community folder access

    private static let bookmarkKey = "communityFolderBookmark"
    private var securityScopedFolder: URL?

    func restoreFolderAccess() {
        guard index.folderURL == nil,
              let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope],
                                 relativeTo: nil, bookmarkDataIsStale: &isStale),
              url.startAccessingSecurityScopedResource() else { return }
        securityScopedFolder = url
        if isStale {
            saveBookmark(for: url)
        }
        index.setFolder(url)
        shareContacts(into: url)
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose the community folder containing Origami Documents (.origamitext)."
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        saveBookmark(for: url)
        securityScopedFolder?.stopAccessingSecurityScopedResource()
        _ = url.startAccessingSecurityScopedResource()
        securityScopedFolder = url
        index.setFolder(url)
        shareContacts(into: url)
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
        refreshPlace()
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
    /// Never runs while sharing is off.
    func refreshPlace() {
        guard sharesGeneralLocation else { return }
        placeFinder.begin()
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
        let doc = draftEditor.buildDocument()
        if doc.documentType == LiquidDoc.DocumentType.book.rawValue {
            exportEPUB(doc)
        } else {
            exportDocument(doc)
        }
    }

    func export(draft doc: LiquidDoc) {
        if draftEditor?.docID == doc.id {
            exportDraft()
        } else {
            exportDocument(doc)
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

    /// Imports an Author (.liquid) document, a Markdown (.md) file, or a
    /// Word (.docx/.doc) file as a new draft, ready to edit and export as .origamitext.
    func importDocumentFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true   // .liquid packages show as folders if Author's type isn't registered
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.message = "Choose an Author document (.liquid), an Origami Text EPUB (.epub), a Markdown file (.md), a Word document (.docx), a PDF with a text layer, or a meeting transcript (.txt or .rtf, speaker names before statements) to import."
        panel.prompt = "Import"
        // Room to browse. The panel is user-resizable on its own — touching
        // its style mask breaks the sandboxed panel's dragging — and macOS
        // remembers the size and sidebar width the user leaves it with.
        panel.setContentSize(NSSize(width: 900, height: 600))
        // The sidebar (Favorites and locations) is out of reach: the
        // system panel takes its width from Finder's preference domain
        // (FK_SidebarWidth2 in com.apple.finder), which a sandboxed app
        // cannot write. Users widen it by dragging the divider; macOS
        // keeps it system-wide.
        guard panel.runModal() == .OK, let url = panel.url else { return }
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
            var importedLinks: [LiquidDoc.Link] = []
            var preservedID: String?
            switch url.pathExtension.lowercased() {
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

    /// Puts a human-readable citation with the embedded document address on
    /// the pasteboard. Pasted into a draft, the address becomes a structured
    /// `cites` link when the draft is saved.
    func copyCitation(doc: LiquidDoc, paragraphID: String? = nil) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let year = doc.date?.yearText ?? String(calendar.component(.year, from: doc.created))
        let address = doc.id + (paragraphID.map { "#\($0)" } ?? "")
        let citation = "“\(doc.title)” (\(doc.author), \(year)) [\(address)]"
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(citation, forType: .string)
        showNote("Citation copied — paste it into a draft to cite")
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
