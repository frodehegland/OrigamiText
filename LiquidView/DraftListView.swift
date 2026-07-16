import SwiftUI

/// The "My Documents" list of editable drafts.
struct DraftListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let drafts = model.filteredDrafts
        List(selection: draftSelection) {
            ForEach(drafts) { doc in
                DraftRow(doc: doc)
                    .tag(doc.id)
                    .contextMenu {
                        Button("Export…") { model.export(draft: doc) }
                        Divider()
                        Button("Delete", role: .destructive) { model.deleteDraft(doc) }
                    }
            }
        }
        .navigationTitle("My Documents")
        .toolbar {
            ToolbarItem {
                Button {
                    model.newDraft()
                } label: {
                    Label("New Document", systemImage: "square.and.pencil")
                }
                .help("New Document (⌘N)")
            }
        }
        .overlay {
            if drafts.isEmpty {
                ContentUnavailableView {
                    Label(model.searchText.isEmpty ? "No Documents Yet" : "No Results",
                          systemImage: "square.and.pencil")
                } description: {
                    Text("Create a new document to start writing.")
                } actions: {
                    if model.searchText.isEmpty {
                        Button("New Document") { model.newDraft() }
                    }
                }
            }
        }
    }

    private var draftSelection: Binding<String?> {
        Binding(
            get: { model.selectedDraftID },
            set: { id in
                guard let id,
                      let doc = model.drafts.documents.first(where: { $0.id == id }) else { return }
                model.editDraft(doc)
            }
        )
    }
}

/// Documents the user has published: the actual published copies,
/// read-only, opened in the reader.
struct PublishedListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let published = model.filteredPublished
        List(selection: selection) {
            ForEach(published) { doc in
                VStack(alignment: .leading, spacing: 2) {
                    Text(doc.title)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text(doc.date?.displayText ?? doc.created.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .tag(doc.id)
                .contextMenu {
                    Button("Copy to Cite") { model.copyCitation(doc: doc) }
                    Button("Export a Copy…") { model.exportDocument(doc) }
                }
            }
        }
        .navigationTitle("Published")
        .overlay {
            if published.isEmpty {
                ContentUnavailableView {
                    Label(model.searchText.isEmpty ? "Nothing Published Yet" : "No Results",
                          systemImage: "paperplane")
                } description: {
                    Text("Exporting a draft publishes it. Published documents are read-only.")
                }
            }
        }
    }

    private var selection: Binding<String?> {
        Binding(
            get: { model.current?.doc.id },
            set: { id in
                guard let id,
                      let doc = model.drafts.published.first(where: { $0.id == id }) else { return }
                model.open(doc)
            }
        )
    }
}

/// Shelved drafts: out of the way, deleted nothing. Selecting one shows it
/// read-only with Un-Archive at the bottom.
struct ArchivedListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let archived = model.filteredArchived
        List(selection: $model.selectedArchivedID) {
            ForEach(archived) { doc in
                VStack(alignment: .leading, spacing: 2) {
                    Text(doc.title)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text("\(doc.displayAuthor) · \(doc.date?.displayText ?? doc.created.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.vertical, 2)
                .tag(doc.id)
                .contextMenu {
                    Button("Un-Archive") { model.unarchiveDraft(doc) }
                }
            }
        }
        .navigationTitle("Archived")
        .overlay {
            if archived.isEmpty {
                ContentUnavailableView {
                    Label(model.searchText.isEmpty ? "Nothing Archived" : "No Results",
                          systemImage: "archivebox")
                } description: {
                    Text("Archiving a draft shelves it without deleting; it keeps its address and can return to Drafts any time.")
                }
            }
        }
    }
}

/// An archived draft, read-only: to work on it again, un-archive it.
struct ArchivedDocumentView: View {
    @Environment(AppModel.self) private var model
    let doc: LiquidDoc

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(doc.title)
                    .font(.system(size: 28, design: .serif))
                    .padding(.bottom, 4)
                Text("\(doc.displayAuthor) · \(doc.listedDateText)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 16)
                ForEach(doc.body ?? []) { paragraph in
                    ParagraphView(paragraph: paragraph, isHighlighted: false)
                }
            }
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(24)
        }
        .safeAreaInset(edge: .bottom) {
            Button("Un-Archive") { model.unarchiveDraft(doc) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Return this document to Drafts, exactly as it left")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(.bar)
        }
        .navigationTitle(doc.title)
    }
}

private struct DraftRow: View {
    @Environment(AppModel.self) private var model
    let doc: LiquidDoc

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text(doc.title)
                    .fontWeight(.medium)
                    .lineLimit(1)
                if model.draftEditor?.docID == doc.id, model.draftEditor?.hasUnsavedChanges == true {
                    Circle()
                        .fill(.secondary)
                        .frame(width: 6, height: 6)
                        .help("Unsaved changes")
                }
            }
            Text("\(doc.displayAuthor) · \(doc.date?.displayText ?? doc.created.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }
}
