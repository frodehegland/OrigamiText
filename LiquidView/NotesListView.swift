import SwiftUI

/// Notes: the desk's quickest documents, newest on top. A note is always
/// the user's own, so the row says nothing about who — only when, and
/// where when the capture recorded a place. Notes made on the desk open
/// straight into the editor; notes that arrived through the community
/// folder (voice capture and other producers) open for reading, with the
/// Flow option to break dense speech open.
struct NotesListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let notes = model.filteredNotes
        List(selection: selection) {
            ForEach(notes) { doc in
                NoteRow(doc: doc)
                    .tag(doc.id)
                    .contextMenu {
                        if isDeskNote(doc) {
                            Button("Delete", role: .destructive) {
                                if model.selectedNoteID == doc.id { model.selectedNoteID = nil }
                                model.deleteDraft(doc)
                            }
                            Divider()
                        }
                        DocumentFileActions(doc: doc)
                    }
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    model.newNote()
                } label: {
                    Label("New Note", systemImage: "note.text.badge.plus")
                }
                .help("New Note")
            }
        }
        .overlay {
            if notes.isEmpty {
                ContentUnavailableView {
                    Label(model.searchText.isEmpty ? "No Notes Yet" : "No Results",
                          systemImage: "note.text")
                } description: {
                    Text("Create a note here, or capture one elsewhere — notes made by voice arrive through the community folder.")
                } actions: {
                    if model.searchText.isEmpty {
                        Button("New Note") { model.newNote() }
                    }
                }
            }
        }
    }

    private func isDeskNote(_ doc: LiquidDoc) -> Bool {
        model.drafts.documents.contains { $0.id == doc.id }
    }

    private var selection: Binding<String?> {
        Binding(
            get: { model.selectedNoteID },
            set: { id in
                guard let id else { return }
                model.selectedNoteID = id
                // A desk note is the user's to edit; anything else reads.
                if let doc = model.drafts.documents.first(where: { $0.id == id }) {
                    model.editDraft(doc)
                }
            }
        )
    }
}

/// A note being read — one that arrived from outside the desk. The line
/// under the title carries only the when and, when the capture recorded
/// one, the where: the author is always the user, and goes unsaid.
struct NoteReadingView: View {
    @Environment(AppModel.self) private var model
    let doc: LiquidDoc
    /// Flow: dense text broken open for reading — display only.
    @State private var flowText = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(doc.title)
                    .font(.system(size: 28, design: .serif))
                    .padding(.bottom, 4)
                Text(NoteRow.whenAndWhere(for: doc))
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
                .help("Break dense text open while reading: sentences get their own lines, clauses break after commas, parentheses stand apart — the note itself is untouched")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }
}

struct NoteRow: View {
    let doc: LiquidDoc

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(doc.title)
                .fontWeight(.medium)
                .lineLimit(1)
            Text(Self.whenAndWhere(for: doc))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    /// The note's whole byline: when, and where when a place was
    /// recorded. Never who — a note is always the user's own.
    static func whenAndWhere(for doc: LiquidDoc) -> String {
        let when = doc.date?.displayText
            ?? doc.created.formatted(date: .abbreviated, time: .shortened)
        guard let location = doc.location else { return when }
        return "\(when) · \(location)"
    }
}
