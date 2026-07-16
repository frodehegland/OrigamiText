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
                        Button("Copy to Cite") { model.copyCitation(doc: entry.doc) }
                        if !model.authorIdentity.matches(author: entry.doc.author) {
                            Divider()
                            ForEach(DocumentRelation.discourseActions, id: \.self) { relation in
                                Button(relation.actionTitle ?? relation.rawValue) {
                                    model.startDiscourse(relation, about: entry.doc)
                                }
                            }
                        }
                    }
            }
            UnreadableFilesSection()
        }
        .navigationTitle("All Documents")
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

/// The same entries ordered strictly by creation date, under month headers.
struct TimelineListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List(selection: model.listSelection) {
            ForEach(model.timelineGroups, id: \.label) { group in
                Section(group.label) {
                    ForEach(group.entries) { entry in
                        DocumentRow(entry: entry, showsTime: true)
                            .tag(entry.id)
                            .contextMenu {
                                Button("Copy to Cite") { model.copyCitation(doc: entry.doc) }
                                if !model.authorIdentity.matches(author: entry.doc.author) {
                                    Divider()
                                    ForEach(DocumentRelation.discourseActions, id: \.self) { relation in
                                        Button(relation.actionTitle ?? relation.rawValue) {
                                            model.startDiscourse(relation, about: entry.doc)
                                        }
                                    }
                                }
                            }
                    }
                }
            }
        }
        .navigationTitle("Timeline")
    }
}

struct DocumentRow: View {
    @Environment(AppModel.self) private var model
    let entry: IndexEntry
    var showsTime = false

    private var isRetracted: Bool {
        model.index.retractedIDs.contains(entry.id)
    }

    /// Addressed for the reader's attention: shown bold in the library.
    private var isForMyAttention: Bool {
        entry.doc.attention.contains { model.authorIdentity.matches(author: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text(entry.doc.title)
                    .fontWeight(isForMyAttention ? .bold : .medium)
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
                guard let id, id != self.current?.doc.id,
                      let entry = self.index.byID[id] else { return }
                self.open(entry.doc)
            }
        )
    }
}
