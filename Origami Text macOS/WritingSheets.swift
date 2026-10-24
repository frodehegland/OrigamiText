import SwiftUI
import AppKit

/// Citation… (⌘T): a DOI or a BibTeX entry, pasted or typed, becomes a
/// citation at the caret — the DOI looked up on Crossref first.
struct CitationSheet: View {
    let controller: RichTextController
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var isLookingUp = false
    @State private var problem: String?

    private var trimmed: String { input.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isBibTeX: Bool { !BibTeXParser.parse(trimmed).isEmpty }
    private var doi: String? { isBibTeX ? nil : OnlineFetch.doi(in: trimmed) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cite")
                .font(.headline)
            Text("Paste a DOI (or a doi.org link) or a BibTeX entry. A DOI is looked up on Crossref; the record travels with the document.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $input)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                if isLookingUp { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isBibTeX ? "Add Citation" : "Look Up and Cite") { cite() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(isLookingUp || (!isBibTeX && doi == nil))
            }
        }
        .padding(18)
        .frame(width: 480)
        .onAppear {
            // What is on the clipboard is usually the answer.
            if let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !BibTeXParser.parse(clip).isEmpty || (clip.count <= 240 && OnlineFetch.doi(in: clip) != nil) {
                input = clip
            }
        }
    }

    private func cite() {
        problem = nil
        let entries = BibTeXParser.parse(trimmed)
        if !entries.isEmpty {
            for entry in entries { controller.insertCitation(AuthorCitation(bibtex: entry)) }
            dismiss()
            return
        }
        guard let doi else { return }
        isLookingUp = true
        Task {
            let citation = await CitationPaste.lookUp(doi: doi)
            isLookingUp = false
            guard let citation else {
                problem = "Crossref does not know \(doi). Check the DOI, or paste the work's BibTeX instead."
                return
            }
            controller.insertCitation(citation)
            dismiss()
        }
    }
}

/// Weblink… (⌘K): a URL on the selected words, or the address itself.
struct WeblinkSheet: View {
    let controller: RichTextController
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""

    private var url: URL? {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), url.host != nil else { return nil }
        return url
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Weblink")
                .font(.headline)
            TextField("https://", text: $address)
                .textFieldStyle(.roundedBorder)
                .onSubmit { link() }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Link") { link() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(url == nil)
            }
        }
        .padding(18)
        .frame(width: 420)
        .onAppear {
            if let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
               clip.hasPrefix("http"), URL(string: clip)?.host != nil {
                address = clip
            }
        }
    }

    private func link() {
        guard let url else { return }
        controller.insertLink(url)
        dismiss()
    }
}

/// Insert Table…: how many rows and columns.
struct TableSizeSheet: View {
    let controller: RichTextController
    @Environment(\.dismiss) private var dismiss
    @State private var rows = 3
    @State private var columns = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Table")
                .font(.headline)
            Stepper("Rows: \(rows)", value: $rows, in: 1...50)
            Stepper("Columns: \(columns)", value: $columns, in: 1...20)
            Text("The first row is the header. Click the table to edit its cells; a cell beginning with = is a formula.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Insert") {
                    controller.insertTable(rows: rows, columns: columns)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(width: 360)
    }
}

/// A table being edited, for the sheet.
struct EditingTable: Identifiable {
    let attachment: TableAttachment
    var id: ObjectIdentifier { ObjectIdentifier(attachment) }
}

/// The grid, cell by cell: values and formulas (a leading `=`), rows and
/// columns added or removed. Changes land in the table as they are made;
/// Done re-measures the attachment in the text.
struct TableGridEditor: View {
    let attachment: TableAttachment
    let controller: RichTextController
    @Environment(\.dismiss) private var dismiss
    /// Bumped on every structural change so the grid redraws.
    @State private var revision = 0

    private var table: LATable { attachment.table }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Table")
                    .font(.headline)
                Spacer()
                Button("Add Row") { table.appendRow(); changed() }
                Button("Add Column") { table.appendColumn(); changed() }
            }
            ScrollView([.horizontal, .vertical]) {
                Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 6) {
                    GridRow {
                        Color.clear.frame(width: 28, height: 1)
                        ForEach(0..<table.columnCount, id: \.self) { column in
                            HStack(spacing: 2) {
                                Text(LATable.columnLabel(for: column))
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 0)
                                Button {
                                    table.removeColumn(at: column); changed()
                                } label: {
                                    Image(systemName: "minus.circle")
                                        .font(.caption2)
                                }
                                .buttonStyle(.plain)
                                .disabled(table.columnCount <= 1)
                                .help("Remove column \(LATable.columnLabel(for: column))")
                            }
                            .frame(minWidth: 110)
                        }
                    }
                    ForEach(0..<table.rowCount, id: \.self) { row in
                        GridRow {
                            HStack(spacing: 2) {
                                Text("\(row + 1)")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Button {
                                    table.removeRow(at: row); changed()
                                } label: {
                                    Image(systemName: "minus.circle")
                                        .font(.caption2)
                                }
                                .buttonStyle(.plain)
                                .disabled(table.rowCount <= 1)
                                .help("Remove row \(row + 1)")
                            }
                            .frame(width: 28)
                            ForEach(0..<table.columnCount, id: \.self) { column in
                                TextField("", text: Binding(
                                    get: { table.editingInput(row: row, column: column) },
                                    set: { table.setInput($0, row: row, column: column); table.recalculate() }))
                                    .textFieldStyle(.roundedBorder)
                                    .frame(minWidth: 110)
                                    .fontWeight(row == 0 && table.rowCount > 1 ? .semibold : .regular)
                            }
                        }
                    }
                }
                .padding(4)
                .id(revision)
            }
            HStack {
                Text("A cell beginning with = is a formula: =SUM(A1:A3), =B2*1.2.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") {
                    table.recalculate()
                    controller.tableDidChange(attachment)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(minWidth: 560, minHeight: 360)
    }

    private func changed() {
        table.recalculate()
        revision += 1
    }
}
