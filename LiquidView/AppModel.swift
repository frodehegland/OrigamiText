import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Library views are exchangeable modules: see LibraryViewModule.swift for
/// the recipe. They appear here as `.view(id)`.
enum SidebarItem: Hashable {
    case allDocuments
    case letters
    case transcripts
    case extracts
    case timeline
    case drafts
    case published
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

    var sidebarSelection: SidebarItem? = .allDocuments
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
        if current?.doc.id != doc.id {
            parallelDoc = nil   // navigation leaves parallel reading
            history = Array(history.prefix(historyPosition + 1))
            history.append(Destination(doc: doc, fragment: fragment))
            historyPosition = history.count - 1
        }
        deliverFragment(fragment, span: span, in: doc)
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
        let keyPattern = "\\((.+?)-(\\d{4}-\\d{2}-\\d{2}T\\d{2}_\\d{2}_\\d{2}Z)\\)"
        guard let regex = try? NSRegularExpression(pattern: keyPattern),
              let enumerator = FileManager.default.enumerator(
                  at: url, includingPropertiesForKeys: nil,
                  options: [.skipsHiddenFiles, .skipsPackageDescendants]
              ) else { return result }
        for case let fileURL as URL in enumerator where fileURL.pathExtension.lowercased() == "pdf" {
            let name = fileURL.deletingPathExtension().lastPathComponent
            guard let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
                  let slugRange = Range(match.range(at: 1), in: name),
                  let stampRange = Range(match.range(at: 2), in: name),
                  let created = LiquidDoc.parseISO8601(
                      name[stampRange].replacingOccurrences(of: "_", with: ":"))
            else { continue }
            let author = name[slugRange].replacingOccurrences(of: "-", with: " ")
            result[LiquidAddress.makeID(author: author, created: created)] = fileURL
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

    func goBack() {
        guard canGoBack else { return }
        historyPosition -= 1
    }

    func goForward() {
        guard canGoForward else { return }
        historyPosition += 1
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
    }

    private func saveBookmark(for url: URL) {
        guard let data = try? url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil, relativeTo: nil
        ) else { return }
        UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
    }

    // MARK: - List filtering and sorting

    var filteredEntries: [IndexEntry] {
        var entries = visibleEntries
        switch sortOrder {
        case .byTitle:
            entries.sort { $0.doc.title.localizedCaseInsensitiveCompare($1.doc.title) == .orderedAscending }
        case .byDate:
            entries.sort { $0.doc.listedDate < $1.doc.listedDate }
        }
        return entries
    }

    var timelineGroups: [(label: String, entries: [IndexEntry])] {
        let entries = visibleEntries.sorted { $0.doc.listedDate < $1.doc.listedDate }
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
        saveDraftIfNeeded()
        do {
            let doc = try drafts.create(author: authorName)
            sidebarSelection = .drafts
            editDraft(doc)
        } catch {
            NSSound.beep()
            showNote("Could not create document: \(error.localizedDescription)")
        }
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

    func deleteDraft(_ doc: LiquidDoc) {
        drafts.delete(doc)
        if draftEditor?.docID == doc.id {
            draftEditor = nil
            selectedDraftID = nil
        }
    }

    /// Exports the open editor's live contents (saving first).
    func exportDraft() {
        guard let draftEditor else { return }
        saveDraftIfNeeded()
        exportDocument(draftEditor.buildDocument())
    }

    func export(draft doc: LiquidDoc) {
        if draftEditor?.docID == doc.id {
            exportDraft()
        } else {
            exportDocument(doc)
        }
    }

    func exportDocument(_ doc: LiquidDoc) {
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
        panel.message = "Choose an Author document (.liquid), a Markdown file (.md), a Word document (.docx), a PDF with a text layer, or a meeting transcript (.txt or .rtf, speaker names before statements) to import."
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
            }
            let created = Date.now
            let id = LiquidAddress.makeID(author: author, created: created) { candidate in
                self.index.byID[candidate] != nil
                    || self.drafts.documents.contains { $0.id == candidate }
            }
            let doc = LiquidDoc(format: LiquidDoc.knownFormat,
                                id: id,
                                title: title,
                                author: author,
                                created: created,
                                body: body,
                                links: [],
                                wraps: nil,
                                date: date,
                                documentType: documentType,
                                fileURL: drafts.fileURL(for: id))
            try drafts.save(doc)
            sidebarSelection = .drafts
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
        let statement = paragraph.displayText
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
                    credit(target.doc.author)
                } else if authorIdentity.matches(author: target.doc.author) {
                    credit(entry.doc.author)
                }
            }
            if mine {
                entry.doc.attention.forEach(credit)
            } else if entry.doc.attention.contains(where: { authorIdentity.matches(author: $0) }) {
                credit(entry.doc.author)
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

    var filteredDrafts: [LiquidDoc] {
        let all = drafts.documents
        guard !searchText.isEmpty else { return all }
        return all.filter { matches($0) }
    }

    var filteredPublished: [LiquidDoc] {
        let all = drafts.published
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

    /// Resolves a title from anywhere the document might live: the
    /// community index, the published shelf, or drafts.
    func title(for id: String) -> String? {
        index.byID[id]?.doc.title
            ?? drafts.published.first(where: { $0.id == id })?.title
            ?? drafts.documents.first(where: { $0.id == id })?.title
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
        if !searchText.isEmpty {
            summaries = summaries.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
        return summaries
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
