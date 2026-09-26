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
        // Notes ▸ Timeline: newest on top. A note filed under Archived
        // has left the timeline; any other folder is just a place.
        let notes = model.filteredNotes.filter { !model.isArchived($0) }
        List(selection: noteSelection(model)) {
            ForEach(notes) { doc in
                NoteRow(doc: doc)
                    .tag(doc.id)
                    .contextMenu { noteMenu(doc, model: model) }
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
}

/// The one selection behavior for every notes list: the note is chosen
/// for the reading pane, and a desk note opens straight into its editor.
@MainActor private func noteSelection(_ model: AppModel) -> Binding<String?> {
    Binding(
        get: { model.selectedNoteID },
        set: { id in
            guard let id else { return }
            model.selectedNoteID = id
            if let doc = model.drafts.documents.first(where: { $0.id == id }) {
                model.editDraft(doc)
            }
        }
    )
}

/// The one context menu for every notes list row: file, delete, and
/// the app-wide file actions.
@MainActor @ViewBuilder
private func noteMenu(_ doc: LiquidDoc, model: AppModel) -> some View {
    Menu("File") {
        FileUnderMenuItems(doc: doc)
    }
    Button("Export as EPUB…") { model.exportEPUB(doc) }
    Button("Delete", role: .destructive) {
        if model.selectedNoteID == doc.id { model.selectedNoteID = nil }
        model.deleteNote(doc)
    }
    Divider()
    DocumentFileActions(doc: doc)
}

/// Notes ▸ Locations: every located note under the broadest part of its
/// place — the country, where the capture recorded one; an older place
/// like "Wimbledon, London" falls back to its last part. Countries read
/// alphabetically; within one, places alphabetically, then newest first.
struct NotesByLocationView: View {
    @Environment(AppModel.self) private var model

    private var sections: [(country: String, docs: [LiquidDoc])] {
        let notes = model.filteredNotes.filter { !model.isArchived($0) && $0.location != nil }
        let grouped = Dictionary(grouping: notes) { countryHeading(for: $0.location ?? "") }
        return grouped.keys
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { country in
                let docs = grouped[country, default: []].sorted { a, b in
                    let placeA = a.location ?? "", placeB = b.location ?? ""
                    if placeA.caseInsensitiveCompare(placeB) != .orderedSame {
                        return placeA.localizedCaseInsensitiveCompare(placeB) == .orderedAscending
                    }
                    return a.listedDate > b.listedDate
                }
                return (country, docs)
            }
    }

    /// "Wimbledon, London, United Kingdom" → "United Kingdom".
    private func countryHeading(for place: String) -> String {
        place.split(separator: ",").last
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? place
    }

    var body: some View {
        let sections = sections
        List(selection: noteSelection(model)) {
            ForEach(sections, id: \.country) { section in
                Section {
                    ForEach(section.docs) { doc in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(doc.title)
                                .fontWeight(.medium)
                                .lineLimit(1)
                            Text("\(doc.location ?? "") · \(doc.created.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 2)
                        .listRowSeparator(.hidden)
                        .tag(doc.id)
                        .contextMenu { noteMenu(doc, model: model) }
                    }
                } header: {
                    Label(section.country, systemImage: "mappin.and.ellipse")
                }
            }
        }
        .overlay {
            if sections.isEmpty {
                ContentUnavailableView(
                    "Nowhere Yet",
                    systemImage: "mappin.and.ellipse",
                    description: Text("Notes that carry a place appear here, under the country they were made in."))
            }
        }
    }
}

/// Notes ▸ People: every note under its author, first-name alphabetical
/// (names are written first-name first); within a person, newest first.
struct NotesByPeopleView: View {
    @Environment(AppModel.self) private var model

    private var sections: [(person: String, docs: [LiquidDoc])] {
        let notes = model.filteredNotes.filter { !model.isArchived($0) }
        let grouped = Dictionary(grouping: notes) { doc in
            let name = doc.author.trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? "Unnamed" : name
        }
        return grouped.keys
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { ($0, grouped[$0, default: []].sorted { $0.listedDate > $1.listedDate }) }
    }

    var body: some View {
        let sections = sections
        List(selection: noteSelection(model)) {
            ForEach(sections, id: \.person) { section in
                Section {
                    ForEach(section.docs) { doc in
                        NoteRow(doc: doc)
                            .tag(doc.id)
                            .contextMenu { noteMenu(doc, model: model) }
                    }
                } header: {
                    Label(section.person, systemImage: "person")
                }
            }
        }
        .overlay {
            if sections.isEmpty {
                ContentUnavailableView(
                    "No Notes Yet",
                    systemImage: "person",
                    description: Text("Notes appear here under whoever made them."))
            }
        }
    }
}

/// Notes ▸ Filed: the filed notes, folder by folder — the same folders
/// and the same logic as the library's Filed: only Archived hides its
/// notes from the other notes lists.
struct NotesFiledView: View {
    @Environment(AppModel.self) private var model

    private var folders: [(name: String, docs: [LiquidDoc])] {
        let filed = model.filteredNotes.filter { model.folder(for: $0) != nil }
        let byFolder = Dictionary(grouping: filed) { model.folder(for: $0) ?? "" }
        // Every offered folder shows, holding notes or not; folders
        // surviving only in old filings join in, and Archived keeps
        // the last word.
        var names = model.filingFolders.filter { $0 != AppModel.archivedFolderName }
        names += byFolder.keys.filter { !model.filingFolders.contains($0) }.sorted()
        names.append(AppModel.archivedFolderName)
        return names.map { name in
            (name, byFolder[name, default: []].sorted { $0.listedDate > $1.listedDate })
        }
    }

    var body: some View {
        let folders = folders
        List(selection: noteSelection(model)) {
            ForEach(folders, id: \.name) { folder in
                Section {
                    if folder.docs.isEmpty {
                        Text("Nothing filed here yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(folder.docs) { doc in
                        NoteRow(doc: doc)
                            .tag(doc.id)
                            .contextMenu { noteMenu(doc, model: model) }
                    }
                } header: {
                    Label(folder.name,
                          systemImage: folder.name == AppModel.archivedFolderName
                              ? "archivebox" : "folder")
                }
            }
        }
        .overlay {
            if folders.isEmpty {
                ContentUnavailableView(
                    "Nothing Filed",
                    systemImage: "folder",
                    description: Text("File a note from its context menu — under Work, Personal, a folder of your own, or Archived, which alone takes it out of the timeline."))
            }
        }
    }
}

/// A note being read — one that arrived from outside the desk. Only the
/// text itself: the title and the when-and-where already sit in the
/// list's column, and a voice note carries its place and moment at the
/// bottom of its own body.
struct NoteReadingView: View {
    @Environment(AppModel.self) private var model
    let doc: LiquidDoc
    /// Flow: dense text broken open for reading — display only.
    @State private var flowText = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(doc.body ?? []) { paragraph in
                    ParagraphView(paragraph: paragraph, isHighlighted: false,
                                  flowed: flowText)
                }
                // The when-and-where fields at the end: doors to the
                // Locations view and the Timeline on ctrl-click.
                DocumentFooter(doc: doc)
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
        .listRowSeparator(.hidden)
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
