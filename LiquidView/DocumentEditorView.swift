import SwiftUI

// Editor Mode — the publisher's door (see EDITOR-MODE-PLAN.md). Hidden
// from readers behind the `editorMode` defaults flag; for the editors
// who answer for the EPUBs' correctness. The session edits an
// in-memory copy of the document; nothing distributed changes until
// Export writes a file of the editor's choosing, or Adopt — a second,
// deliberate act — replaces the shelf and community copies. Identity
// never changes: the document id, the DOI, and every untouched
// paragraph id travel exactly as they were, so what is exported IS the
// authoritative version, not an annotated variant of it.

/// One correction session over one book: the working copy, what
/// changed, and the ids discipline (an edited block keeps its id; a
/// new block gets a fresh one, never a reused one).
@MainActor @Observable
final class EditorSession {
    let record: EPUBRecord
    private let base: LiquidDoc

    var title: String
    var paragraphs: [LiquidDoc.Paragraph]
    var references: [LiquidDoc.Reference]
    var tables: [LiquidDoc.Table]

    /// The block being edited in place, if any.
    var editingID: String?

    private let originalTitle: String
    private let originalText: [String: String]
    private let originalOrder: [String]
    private let originalReferences: [String: String]

    init(record: EPUBRecord, doc: LiquidDoc) {
        self.record = record
        self.base = doc
        self.title = doc.title
        self.paragraphs = doc.body ?? []
        self.references = doc.references
        self.tables = doc.tables
        self.originalTitle = doc.title
        self.originalText = Dictionary(
            (doc.body ?? []).map { ($0.id, $0.text) },
            uniquingKeysWith: { first, _ in first })
        self.originalOrder = (doc.body ?? []).map(\.id)
        self.originalReferences = Dictionary(
            doc.references.map { ($0.id, $0.bibtex) },
            uniquingKeysWith: { first, _ in first })
    }

    // MARK: What changed

    var editedIDs: [String] {
        paragraphs.filter { paragraph in
            guard let original = originalText[paragraph.id] else { return false }
            return original != paragraph.text
        }.map(\.id)
    }
    var insertedIDs: [String] {
        paragraphs.filter { originalText[$0.id] == nil }.map(\.id)
    }
    var deletedIDs: [String] {
        let present = Set(paragraphs.map(\.id))
        return originalOrder.filter { !present.contains($0) }
    }
    var editedReferenceIDs: [String] {
        references.filter { reference in
            guard let original = originalReferences[reference.id] else { return false }
            return original != reference.bibtex
        }.map(\.id)
    }
    var titleChanged: Bool { title != originalTitle }
    var changeCount: Int {
        editedIDs.count + insertedIDs.count + deletedIDs.count
            + editedReferenceIDs.count + (titleChanged ? 1 : 0)
    }

    // MARK: The edits

    func commit(id: String, text: String, heading: Int??) {
        guard let index = paragraphs.firstIndex(where: { $0.id == id }) else { return }
        paragraphs[index] = paragraphs[index].replacing(text: text, heading: heading)
    }

    func insert(after id: String?) -> String {
        let fresh = freshID()
        let paragraph = LiquidDoc.Paragraph(id: fresh, heading: nil, text: "")
        if let id, let index = paragraphs.firstIndex(where: { $0.id == id }) {
            paragraphs.insert(paragraph, at: index + 1)
        } else {
            paragraphs.append(paragraph)
        }
        editingID = fresh
        return fresh
    }

    func delete(id: String) {
        paragraphs.removeAll { $0.id == id }
        if editingID == id { editingID = nil }
    }

    func revertAll() {
        title = originalTitle
        paragraphs = base.body ?? []
        references = base.references
        tables = base.tables
        editingID = nil
    }

    /// New blocks carry editor ids ("e1", "e2", …) — fresh, stable,
    /// never a reuse of an id some annotation may anchor to.
    private func freshID() -> String {
        var number = 0
        var candidate: String
        repeat {
            number += 1
            candidate = "e\(number)"
        } while paragraphs.contains { $0.id == candidate }
        return candidate
    }

    /// The working copy as a document again — identity untouched.
    func assembledDoc() -> LiquidDoc {
        var doc = base.replacingBody(paragraphs, title: title)
        doc.references = references
        doc.tables = tables
        return doc
    }

    /// The adopt log's payload: enough to know, later, what this
    /// correction touched. Kept locally, never written into the EPUB.
    var editLogJSON: Data? {
        let log: [String: Any] = [
            "date": ISO8601DateFormatter().string(from: .now),
            "documentID": base.id,
            "titleChanged": titleChanged,
            "editedBlocks": editedIDs,
            "insertedBlocks": insertedIDs,
            "deletedBlocks": deletedIDs,
            "editedReferences": editedReferenceIDs,
        ]
        return try? JSONSerialization.data(withJSONObject: log,
                                           options: [.prettyPrinted, .sortedKeys])
    }
}

/// The Editor window's content: the document as editable blocks, the
/// references beneath, Preview/Export/Adopt in the toolbar.
struct DocumentEditorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let session = model.editorSession {
            EditorContent(session: session)
                .navigationTitle("Edit — \(session.record.title)")
        } else {
            ContentUnavailableView(
                "Nothing Being Edited",
                systemImage: "pencil.slash",
                description: Text("Choose Edit Document… from a book's context menu."))
        }
    }
}

private struct EditorContent: View {
    @Bindable var session: EditorSession
    @Environment(AppModel.self) private var model
    @State private var showsPreview = false
    @State private var showsChanges = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                // The title, editable like any block — identity is the
                // id and the DOI, never the words.
                TextField("Title", text: $session.title, axis: .vertical)
                    .font(.title.weight(.semibold))
                    .textFieldStyle(.plain)
                    .padding(.bottom, 8)

                ForEach(session.paragraphs) { paragraph in
                    EditorBlock(session: session, paragraph: paragraph)
                }

                if !session.references.isEmpty {
                    Divider().padding(.vertical, 8)
                    Text("References")
                        .font(.title2.weight(.semibold))
                    Text("Each entry's BibTeX, editable — order and numbering recompute at export by the printed-order rules.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach($session.references, id: \.id) { $reference in
                        ReferenceEditor(reference: $reference)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    showsChanges = true
                } label: {
                    Label(session.changeCount == 1
                          ? "1 change" : "\(session.changeCount) changes",
                          systemImage: "pencil")
                }
                .disabled(session.changeCount == 0)
                .popover(isPresented: $showsChanges) { changeList }

                Button("Preview") { showsPreview = true }
                Button("Export Authoritative EPUB…") {
                    model.exportAuthoritativeEdition(session)
                }
                .disabled(session.changeCount == 0)
                Button("Adopt…") { model.adoptEdition(session) }
                    .disabled(session.changeCount == 0)
            }
        }
        .sheet(isPresented: $showsPreview) {
            NavigationStack {
                OrigamiReadingView(doc: session.assembledDoc())
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showsPreview = false }
                        }
                    }
            }
            .frame(minWidth: 760, minHeight: 820)
        }
    }

    private var changeList: some View {
        VStack(alignment: .leading, spacing: 6) {
            if session.titleChanged { Text("• Title") }
            ForEach(session.editedIDs, id: \.self) { id in
                Text("• Edited \(id): \(snippet(id))")
            }
            ForEach(session.insertedIDs, id: \.self) { id in
                Text("• Inserted \(id): \(snippet(id))")
            }
            ForEach(session.deletedIDs, id: \.self) { id in
                Text("• Deleted \(id)")
            }
            ForEach(session.editedReferenceIDs, id: \.self) { id in
                Text("• Reference \(id)")
            }
            Divider()
            Button("Revert All Changes", role: .destructive) {
                session.revertAll()
                showsChanges = false
            }
        }
        .font(.callout)
        .padding(14)
        .frame(maxWidth: 420, alignment: .leading)
    }

    private func snippet(_ id: String) -> String {
        let text = session.paragraphs.first { $0.id == id }?.text ?? ""
        return String(text.prefix(48))
    }
}

/// One block: rendered until clicked, an editor while it has the
/// floor. Headings carry a level control; a table block opens its grid.
private struct EditorBlock: View {
    @Bindable var session: EditorSession
    let paragraph: LiquidDoc.Paragraph
    @State private var draft = ""
    @State private var draftHeading: Int?
    @State private var showsTable = false

    private var isEditing: Bool { session.editingID == paragraph.id }
    private var isChanged: Bool {
        session.editedIDs.contains(paragraph.id)
            || session.insertedIDs.contains(paragraph.id)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(isChanged ? Color.orange : Color.clear)
                .frame(width: 6, height: 6)
                .padding(.top, 8)
            if isEditing {
                editor
            } else {
                display
            }
        }
        .contextMenu {
            Button("Edit") { begin() }
            Button("Insert Paragraph Below") { _ = session.insert(after: paragraph.id) }
            if let tableID = paragraph.tableID,
               session.tables.contains(where: { $0.identifier == tableID }) {
                Button("Edit Table…") { showsTable = true }
            }
            Divider()
            Button("Delete Block", role: .destructive) {
                session.delete(id: paragraph.id)
            }
        }
        .sheet(isPresented: $showsTable) {
            if let tableID = paragraph.tableID {
                TableEditor(session: session, tableID: tableID)
            }
        }
    }

    private var display: some View {
        Group {
            if let level = paragraph.heading {
                Text(paragraph.text)
                    .font(level == 1 ? .title2.weight(.semibold)
                          : level == 2 ? .title3.weight(.semibold)
                          : .headline)
            } else {
                Text(paragraph.text.isEmpty ? " " : paragraph.text)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { begin() }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $draft)
                .font(.body)
                .frame(minHeight: 60)
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.accentColor.opacity(0.6)))
            HStack {
                Picker("Level", selection: $draftHeading) {
                    Text("Body").tag(Int?.none)
                    Text("Heading 1").tag(Int?.some(1))
                    Text("Heading 2").tag(Int?.some(2))
                    Text("Heading 3").tag(Int?.some(3))
                }
                .frame(width: 200)
                Spacer()
                Button("Cancel") { session.editingID = nil }
                Button("Done") {
                    session.commit(id: paragraph.id, text: draft,
                                   heading: .some(draftHeading))
                    session.editingID = nil
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
            }
        }
        .onAppear {
            draft = paragraph.text
            draftHeading = paragraph.heading
        }
    }

    private func begin() {
        session.editingID = paragraph.id
    }
}

/// One reference: the citation sentence as orientation, its BibTeX as
/// the editable truth. A record that stops parsing refuses to save.
private struct ReferenceEditor: View {
    @Binding var reference: LiquidDoc.Reference
    @State private var editing = false
    @State private var draft = ""
    @State private var parseFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let record = BibTeXRecord.records(in: reference.bibtex).first {
                Text(record.citationSentence)
                    .font(.callout)
            } else {
                Text(reference.id).font(.callout)
            }
            if editing {
                TextEditor(text: $draft)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 100)
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .stroke(parseFailed ? Color.red : Color.accentColor.opacity(0.6)))
                if parseFailed {
                    Text("That does not parse as BibTeX — not saved.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { editing = false; parseFailed = false }
                    Button("Done") {
                        if BibTeXParser.parse(draft).first != nil {
                            reference.bibtex = draft
                            editing = false
                            parseFailed = false
                        } else {
                            parseFailed = true
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                Button("Edit BibTeX") {
                    draft = reference.bibtex
                    editing = true
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

/// A live table's cells, editable in place. Values only — formulas
/// travel unchanged.
private struct TableEditor: View {
    @Bindable var session: EditorSession
    let tableID: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Table \(tableID)")
                .font(.headline)
            if let tableIndex = session.tables.firstIndex(where: { $0.identifier == tableID }) {
                ScrollView([.horizontal, .vertical]) {
                    Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                        ForEach(session.tables[tableIndex].cells.indices, id: \.self) { row in
                            GridRow {
                                ForEach(session.tables[tableIndex].cells[row].indices, id: \.self) { column in
                                    TextField("", text: Binding(
                                        get: { session.tables[tableIndex].cells[row][column].value },
                                        set: { session.tables[tableIndex].cells[row][column].value = $0 }))
                                        .textFieldStyle(.roundedBorder)
                                        .frame(minWidth: 90)
                                }
                            }
                        }
                    }
                    .padding(4)
                }
            }
            HStack {
                Text("The block's pipe-text fallback rewrites at export.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") {
                    session.syncTableFallback(tableID: tableID)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 380)
    }
}

extension EditorSession {
    /// The paragraph's pipe-text fallback follows its table's cells, so
    /// a reader without table support sees the corrected values too.
    func syncTableFallback(tableID: String) {
        guard let table = tables.first(where: { $0.identifier == tableID }),
              let index = paragraphs.firstIndex(where: { $0.tableID == tableID })
        else { return }
        let text = table.cells.map { row in
            "| " + row.map(\.value).joined(separator: " | ") + " |"
        }.joined(separator: "\n")
        paragraphs[index] = paragraphs[index].replacing(text: text)
    }
}
