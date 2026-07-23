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

/// Received ▸ Inbox: everything from other people — the unread on top,
/// bold; the recently read below, plain, only the last twenty (Dialog's
/// timeline keeps them all). A letter being read stays put until the
/// reader moves on; a small person icon marks what is addressed for the
/// user's attention.
struct InboxListView: View {
    @Environment(AppModel.self) private var model

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
                    Text("Letters and other documents from the community arrive here — unread in bold, the recently read below them.")
                }
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
                }
            }
        )
    }
}
