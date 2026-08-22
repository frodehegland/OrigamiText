import SwiftUI

/// What an authored list holds: the letters (and everything else that
/// is not a transcript or a book), the transcripts, or the books —
/// Outgoing, Transcripts, and Books each get their own Drafts and
/// Sent/Published.
enum AuthoredKind {
    case letters, transcripts, books

    @MainActor func includes(_ doc: LiquidDoc) -> Bool {
        let isBook = doc.documentType == LiquidDoc.DocumentType.book.rawValue
        switch self {
        case .books: return isBook
        case .transcripts: return !isBook && TranscriptsView.isTranscript(doc)
        case .letters: return !isBook && !TranscriptsView.isTranscript(doc)
        }
    }
}

/// The editable drafts of one kind, letters or transcripts.
struct DraftListView: View {
    @Environment(AppModel.self) private var model
    var kind: AuthoredKind = .letters

    var body: some View {
        let drafts = model.filteredDrafts.filter { kind.includes($0) }
        List(selection: draftSelection) {
            ForEach(drafts) { doc in
                DraftRow(doc: doc)
                    .tag(doc.id)
                    .contextMenu {
                        Button("Export…") { model.export(draft: doc) }
                        Button("Export as EPUB…") { model.exportEPUB(doc) }
                        Divider()
                        DocumentFileActions(doc: doc)
                        Divider()
                        Button("Delete", role: .destructive) { model.deleteDraft(doc) }
                    }
            }
        }
        .toolbar {
            if kind == .letters {
                ToolbarItem {
                    Button {
                        model.newDraft()
                    } label: {
                        Label("New Document", systemImage: "square.and.pencil")
                    }
                    .help("New Document (⌘N)")
                }
            }
        }
        .overlay {
            if drafts.isEmpty {
                if kind == .books {
                    ContentUnavailableView {
                        Label(model.searchText.isEmpty ? "No Books Yet" : "No Results",
                              systemImage: "books.vertical")
                    } description: {
                        Text("Begin a book with ⌘⇧B, or ctrl-click Drafts under Books.")
                    }
                } else if kind == .transcripts {
                    ContentUnavailableView {
                        Label(model.searchText.isEmpty ? "No Transcript Drafts" : "No Results",
                              systemImage: "text.bubble")
                    } description: {
                        Text("Importing a meeting transcript starts a draft here, ready to correct and publish.")
                    }
                } else {
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

/// Documents the user has published, of one kind: the actual published
/// copies, read-only, opened in the reader.
struct PublishedListView: View {
    @Environment(AppModel.self) private var model
    var kind: AuthoredKind = .letters

    var body: some View {
        let published = model.filteredPublished.filter { kind.includes($0) }
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
                .listRowSeparator(.hidden)
                .tag(doc.id)
                .contextMenu {
                    Button("Copy to Cite") { model.copyCitation(doc: doc) }
                    Button("Export a Copy…") { model.exportDocument(doc) }
                    Button("Export as EPUB…") { model.exportEPUB(doc) }
                    Menu("File") {
                        FileUnderMenuItems(doc: doc)
                    }
                    Button("Delete", role: .destructive) { model.deletePublished(doc) }
                    Divider()
                    DocumentFileActions(doc: doc)
                }
            }
        }
        .overlay {
            if published.isEmpty {
                ContentUnavailableView {
                    Label(model.searchText.isEmpty
                          ? (kind == .transcripts ? "No Sent Transcripts"
                             : kind == .books ? "No Published Books" : "Nothing Sent Yet")
                          : "No Results",
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
                .listRowSeparator(.hidden)
                .tag(doc.id)
                .contextMenu {
                    Button("Un-Archive") { model.unarchiveDraft(doc) }
                    Divider()
                    DocumentFileActions(doc: doc)
                }
            }
        }
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
    /// Flow: dense text broken open for reading — display only.
    @State private var flowText = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(doc.title)
                    .font(AppFonts.heading(28))
                    .padding(.bottom, 4)
                Text("\(doc.displayAuthor) · \(doc.listedDateText)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 16)
                ForEach(doc.body ?? []) { paragraph in
                    ParagraphView(paragraph: paragraph, isHighlighted: false,
                                  flowed: flowText)
                }
            }
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(24)
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.snappy) { flowText.toggle() }
                } label: {
                    Label(flowText ? "Unflow" : "Flow", systemImage: "text.alignleft")
                }
                .help("Break dense text open while reading: sentences get their own lines, clauses break after commas, parentheses stand apart — the document itself is untouched")
                Button("Un-Archive") { model.unarchiveDraft(doc) }
                    .help("Return this document to Drafts, exactly as it left")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(.bar)
        }
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
        .listRowSeparator(.hidden)
    }
}
