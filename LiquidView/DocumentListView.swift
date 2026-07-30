import SwiftUI

/// The "All Documents" list: title/author/date rows, sidecar and duplicate
/// badges, and unreadable files greyed out at the bottom.
struct DocumentListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let entries = model.filteredEntries
        List(selection: model.listSelection) {
            ForEach(entries) { entry in
                DocumentRow(entry: entry)
                    .tag(entry.id)
                    .contextMenu {
                        DocumentRowMenu(entry: entry)
                    }
            }
            UnreadableFilesSection()
        }
        .overlay {
            if entries.isEmpty && model.index.unreadableFiles.isEmpty && !model.index.isScanning {
                ContentUnavailableView(
                    model.searchText.isEmpty ? "No Documents" : "No Results",
                    systemImage: "doc.text.magnifyingglass"
                )
            }
        }
    }
}

/// The Files shelf: opened EPUBs, all of them or one folder's worth. Rows
/// reopen the rendered page; a context menu files them into folders.
struct EPUBLibraryListView: View {
    @Environment(AppModel.self) private var model
    /// nil = All opened EPUBs; otherwise just this folder's.
    var folder: String?

    var body: some View {
        let records = model.epubRecords(inFolder: folder)
        List {
            ForEach(records) { record in
                Button {
                    model.openStoredEPUB(record)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.title)
                            .fontWeight(model.isUnread(record) ? .bold : .regular)
                            .lineLimit(2)
                        HStack(spacing: 6) {
                            Text(record.author)
                            if let filed = model.epubFolder(for: record.id), folder == nil {
                                Text("· \(filed)")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Menu("File Under") {
                        ForEach(model.epubFolders, id: \.self) { name in
                            Button(name) { model.fileEPUB(record.id, under: name) }
                        }
                        if !model.epubFolders.isEmpty { Divider() }
                        Button("New Folder…") { model.promptNewEPUBFolder(fileAfter: record.id) }
                    }
                    if model.epubFolder(for: record.id) != nil {
                        Button("Remove from Folder") { model.unfileEPUB(record.id) }
                    }
                }
            }
        }
        .overlay {
            if records.isEmpty {
                ContentUnavailableView {
                    Label(folder == nil ? "No EPUBs Yet" : "Empty Folder",
                          systemImage: "books.vertical")
                } description: {
                    Text(folder == nil
                         ? "Open an EPUB (⌘O) or drag one in, and it appears here."
                         : "File EPUBs into “\(folder ?? "")” from the All list's context menu.")
                }
            }
        }
    }
}

/// One opened-EPUB row: title (bold while unread), author, and filed
/// folder. Reused by the Files shelf and the Views lists.
struct EPUBRecordRow: View {
    @Environment(AppModel.self) private var model
    let record: EPUBRecord
    /// When shown inside a folder or author group, the redundant subtitle
    /// line can be dropped.
    var showsSubtitle: Bool = true

    var body: some View {
        Button {
            model.openStoredEPUB(record)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.title)
                    .fontWeight(model.isUnread(record) ? .bold : .regular)
                    .lineLimit(2)
                if showsSubtitle {
                    Text(record.author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Views ▸ Authors: the opened EPUBs grouped under their author of record,
/// alphabetically. Automatic — nothing the user curates.
struct AuthorsListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let authors = model.epubAuthors
        List {
            ForEach(authors, id: \.self) { author in
                Section(author) {
                    ForEach(model.epubRecords(byAuthor: author)) { record in
                        EPUBRecordRow(record: record, showsSubtitle: false)
                    }
                }
            }
        }
        .overlay {
            if authors.isEmpty {
                ContentUnavailableView {
                    Label("No Authors Yet", systemImage: "person.2")
                } description: {
                    Text("Open an EPUB and its author appears here.")
                }
            }
        }
    }
}

/// Views ▸ People: the people the user is tracking. Automatic extraction of
/// names from the EPUBs is a later step; for now this lists what the user
/// has added (with “Add Person” in the sidebar).
struct PeopleListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            ForEach(model.viewPeople, id: \.self) { name in
                Label(name, systemImage: "person")
                    .tag(SidebarItem.person(name))
                    .contextMenu {
                        Button("Remove") { model.removePerson(name) }
                    }
            }
        }
        .overlay {
            if model.viewPeople.isEmpty {
                ContentUnavailableView {
                    Label("No People Yet", systemImage: "person.crop.circle")
                } description: {
                    Text("Add people with “Add Person” in the sidebar. Pulling names out of the EPUBs automatically is a later step.")
                }
            }
        }
    }
}

/// Views ▸ a single person. Where the documents that mention this person
/// will gather once name extraction is added.
struct PersonListView: View {
    let name: String

    var body: some View {
        ContentUnavailableView {
            Label(name, systemImage: "person")
        } description: {
            Text("Documents mentioning \(name) will gather here once names are pulled from the EPUBs.")
        }
    }
}

/// Views ▸ Concepts: the concepts the user is tracking. Pulling concepts
/// out of the EPUBs is a later step; this lists what the user has added.
struct ConceptsListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            ForEach(model.viewConcepts, id: \.self) { name in
                Label(name, systemImage: "tag")
                    .tag(SidebarItem.concept(name))
                    .contextMenu {
                        Button("Remove") { model.removeConcept(name) }
                    }
            }
        }
        .overlay {
            if model.viewConcepts.isEmpty {
                ContentUnavailableView {
                    Label("No Concepts Yet", systemImage: "lightbulb")
                } description: {
                    Text("Add concepts with “Add Concept” in the sidebar. Pulling concepts out of the EPUBs automatically is a later step.")
                }
            }
        }
    }
}

/// Views ▸ a single concept. Where the documents that contain this concept
/// will gather once concept extraction is added.
struct ConceptListView: View {
    let name: String

    var body: some View {
        ContentUnavailableView {
            Label(name, systemImage: "tag")
        } description: {
            Text("Documents containing \(name) will gather here once concepts are pulled from the EPUBs.")
        }
    }
}

/// Received ▸ Inbox: everything from other people — the unread on top,
/// bold; the recently read below, plain, only the last twenty (Dialog's
/// timeline keeps them all). A letter being read stays put until the
/// reader moves on; a small person icon marks what is addressed for the
/// user's attention.
struct InboxListView: View {
    @Environment(AppModel.self) private var model
    /// Highlighted while a file is dragged over the inbox to be imported.
    @State private var isDropTargeted = false

    var body: some View {
        let entries = model.inboxEntries
        let unread = entries.filter { model.isUnread($0.doc) }
        let read = entries.filter { !model.isUnread($0.doc) }
        List(selection: model.listSelection) {
            ForEach(unread) { row($0) }
            // Not a hairline: a soft bar marks the shelf edge between
            // what waits and what has been read.
            if !unread.isEmpty && !read.isEmpty {
                Capsule()
                    .fill(.quaternary)
                    .frame(height: 4)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            ForEach(read) { row($0) }
        }
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView {
                    Label(model.searchText.isEmpty ? "Nothing Received" : "No Results",
                          systemImage: "tray")
                } description: {
                    Text("Letters and other documents from the community arrive here — unread in bold, the recently read below them. Drop an EPUB here to import it.")
                }
            }
        }
        // Drop an EPUB (or other importable file) onto the inbox to import
        // it into a new draft.
        .dropDestination(for: URL.self) { urls, _ in
            let epubs = urls.filter { $0.pathExtension.lowercased() == "epub" }
            guard !epubs.isEmpty else { return false }
            for url in epubs { model.openFile(at: url) }
            return true
        } isTargeted: { isDropTargeted = $0 }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
    }

    private func row(_ entry: IndexEntry) -> some View {
        DocumentRow(entry: entry)
            .tag(entry.id)
            .contextMenu {
                Menu("File") {
                    FileUnderMenuItems(doc: entry.doc)
                }
                Divider()
                DocumentRowMenu(entry: entry)
            }
    }
}

/// The letters ordered strictly by date under month headers, the newest
/// on top.
struct TimelineListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: model.listSelection) {
                ForEach(model.timelineGroups, id: \.label) { group in
                    Section(group.label) {
                        // No explicit .id() here: it would defeat the
                        // row's .tag and clicks would stop selecting.
                        // scrollTo finds rows by their ForEach identity.
                        ForEach(group.entries) { entry in
                            DocumentRow(entry: entry, showsTime: true)
                                .tag(entry.id)
                                .contextMenu {
                                    DocumentRowMenu(entry: entry)
                                }
                        }
                    }
                }
            }
            // A document footer's Timeline menu arrives here: scroll to
            // the document, which opening has already selected.
            .task(id: model.timelineRevealID) {
                guard let id = model.timelineRevealID else { return }
                model.timelineRevealID = nil
                withAnimation(.snappy) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }
}

/// The filing menu's contents: New… asks for a folder name, then the
/// folders in order — Archived last, the one folder that hides its
/// documents from the Timeline and the other lists. A filed document
/// shows its folder checked, and can be unfiled.
struct FileUnderMenuItems: View {
    @Environment(AppModel.self) private var model
    let doc: LiquidDoc

    var body: some View {
        Button("New…") { model.fileInNewFolder(doc) }
        Divider()
        ForEach(model.filingFolders, id: \.self) { folder in
            Button {
                model.fileDocument(doc, under: folder)
            } label: {
                if model.folder(for: doc) == folder {
                    Label(folder, systemImage: "checkmark")
                } else {
                    Text(folder)
                }
            }
        }
        if model.folder(for: doc) != nil {
            Divider()
            Button("Unfile") { model.unfile(doc) }
        }
    }
}

/// The when and the where at the end of a document being read. Each is
/// a door on ctrl-click: the place opens the Locations view on that
/// place; the date opens the Timeline on this document.
struct DocumentFooter: View {
    @Environment(AppModel.self) private var model
    let doc: LiquidDoc

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let location = doc.location {
                Text(location)
                    .contextMenu {
                        Button("Location") { model.openLocations(highlighting: location) }
                    }
            }
            Text(doc.date?.displayText ?? doc.created.formatted(date: .abbreviated, time: .shortened))
                .contextMenu {
                    Button("Timeline") { model.openTimeline(revealing: doc) }
                }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.top, 20)
    }
}

/// The one right-click answer for a library document row, shared by every
/// list that shows them — and it is the app-wide document menu, so an
/// action added in ContextActions.swift appears on every row at once.
struct DocumentRowMenu: View {
    let entry: IndexEntry

    var body: some View {
        ContextActionItems(target: .document(entry.doc))
    }
}

struct DocumentRow: View {
    @Environment(AppModel.self) private var model
    let entry: IndexEntry
    var showsTime = false

    private var isRetracted: Bool {
        model.index.retractedIDs.contains(entry.id)
    }

    /// Addressed for the reader's attention: a small person marks it.
    private var isForMyAttention: Bool {
        entry.doc.attention.contains { model.authorIdentity.matches(author: $0) }
    }

    /// Unread reads bold, mail-style, until the reader moves on from it.
    private var isUnread: Bool {
        model.isUnread(entry.doc)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                if isForMyAttention {
                    Image(systemName: "person.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("For your attention")
                }
                Text(entry.doc.title)
                    .fontWeight(isUnread ? .bold : .medium)
                    .lineLimit(1)
                if isRetracted {
                    Image(systemName: "exclamationmark.octagon")
                        .foregroundStyle(.red)
                        .help("Retracted by its author")
                }
                if entry.doc.isSidecar {
                    Image(systemName: "doc.richtext")
                        .foregroundStyle(.secondary)
                        .help("Wraps an external file")
                }
                if entry.hasDuplicate {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .help("Multiple files claim this document ID; showing the most recently modified one.")
                }
            }
            Text("\(entry.doc.displayAuthor) · \(dateText)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
        .opacity(isRetracted ? 0.55 : 1)
        .listRowSeparator(.hidden)
    }

    private var dateText: String {
        if let date = entry.doc.date { return date.displayText }
        return showsTime
            ? entry.doc.created.formatted(date: .abbreviated, time: .shortened)
            : entry.doc.created.formatted(date: .abbreviated, time: .omitted)
    }
}

struct UnreadableFilesSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.index.unreadableFiles.isEmpty {
            Section("Unreadable Files") {
                ForEach(model.index.unreadableFiles) { file in
                    Label(file.fileURL.lastPathComponent, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.tertiary)
                        .help(file.reason)
                }
            }
        }
    }
}

extension AppModel {
    /// List selection mirrors the current destination; selecting a row
    /// navigates through the same history as link following.
    var listSelection: Binding<String?> {
        Binding(
            get: { self.current?.doc.id },
            set: { id in
                guard let id, id != self.current?.doc.id else { return }
                if let entry = self.index.byID[id] {
                    self.open(entry.doc)
                } else if let published = self.drafts.published.first(where: { $0.id == id }) {
                    // Dialog's timeline carries the user's own published
                    // copies too; they read like any document.
                    self.open(published)
                } else if let record = self.epubRecords.first(where: { $0.id == id }) {
                    // An opened EPUB listed in the inbox reopens its
                    // rendered page rather than the native reader.
                    self.openStoredEPUB(record)
                }
            }
        )
    }
}
