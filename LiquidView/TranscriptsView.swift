import SwiftUI
import AppKit

/// Every meeting transcript in one place — library documents, drafts, and
/// published copies — sorted by meeting date. Clicking a row opens the
/// transcript where it lives: drafts in the editor, everything else in the
/// reader, where each statement's speaker can be lifted into a new document.
struct TranscriptsView: View {
    @Environment(AppModel.self) private var model

    /// Where a transcript currently lives, in click-through terms.
    private enum Origin: String {
        case library = "Library"
        case draft = "Draft"
        case published = "Published"
    }

    private struct Row: Identifiable {
        let doc: LiquidDoc
        let origin: Origin
        var id: String { doc.id }
    }

    /// A transcript is a document declared `transcript`, or — for documents
    /// imported before the type existed — one whose body carries at least
    /// two distinct speaker attributions.
    static func isTranscript(_ doc: LiquidDoc) -> Bool {
        if doc.documentType == LiquidDoc.DocumentType.transcript.rawValue { return true }
        return Set((doc.body ?? []).compactMap(\.speaker)).count >= 2
    }

    private var rows: [Row] {
        var seen: Set<String> = []
        var rows: [Row] = []
        func add(_ docs: [LiquidDoc], as origin: Origin) {
            for doc in docs where Self.isTranscript(doc) && seen.insert(doc.id).inserted {
                rows.append(Row(doc: doc, origin: origin))
            }
        }
        add(model.index.byID.values.map(\.doc), as: .library)
        add(model.drafts.published, as: .published)
        add(model.drafts.documents, as: .draft)
        if !model.searchText.isEmpty {
            rows = rows.filter { matches($0.doc) }
        }
        return rows.sorted { $0.doc.listedDate > $1.doc.listedDate }
    }

    private func matches(_ doc: LiquidDoc) -> Bool {
        doc.title.localizedCaseInsensitiveContains(model.searchText)
            || speakers(in: doc).contains { $0.localizedCaseInsensitiveContains(model.searchText) }
            || (doc.body ?? []).contains { $0.text.localizedCaseInsensitiveContains(model.searchText) }
    }

    /// Distinct speakers in order of first appearance.
    private func speakers(in doc: LiquidDoc) -> [String] {
        var seen: Set<String> = []
        return (doc.body ?? []).compactMap { paragraph in
            guard let speaker = paragraph.speaker, seen.insert(speaker).inserted else { return nil }
            return speaker
        }
    }

    @State private var selection: String?

    var body: some View {
        let rows = rows
        // Click to select (and open), ctrl-click for options — the same
        // contract as every other list.
        List(rows, selection: $selection) { row in
            rowLabel(row)
                .tag(row.doc.id)
                .contextMenu {
                    ContextActionItems(target: .document(row.doc))
                }
        }
        .onChange(of: selection) {
            guard let selection, let row = rows.first(where: { $0.doc.id == selection }) else { return }
            open(row)
        }
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView {
                    Label(model.searchText.isEmpty ? "No Transcripts" : "No Results",
                          systemImage: "text.bubble")
                } description: {
                    Text("Import a meeting transcript (File > Import — plain text or RTF with speaker names before statements) and it appears here.")
                }
            }
        }
    }

    @ViewBuilder
    private func rowLabel(_ row: Row) -> some View {
        let speakers = speakers(in: row.doc)
        let statements = (row.doc.body ?? []).count { $0.speaker != nil }
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "text.bubble")
                .foregroundStyle(.secondary)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.doc.title)
                    .lineLimit(2)
                Text("\(row.doc.listedDateText) · \(statements) \(statements == 1 ? "statement" : "statements")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !speakers.isEmpty {
                    Text(speakers.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if row.origin != .library {
                Text(row.origin.rawValue)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .listRowSeparator(.hidden)
        .help(row.origin == .draft
              ? "Open this transcript in the draft editor"
              : "Read this transcript — right-click a speaker's name to lift a statement into a new document")
    }

    private func open(_ row: Row) {
        switch row.origin {
        case .library, .published:
            // Reading keeps its place: the Transcripts list stays, the
            // transcript opens beside it.
            model.open(row.doc)
        case .draft:
            // Editing has a reason to move: the editor lives in the
            // drafts context — Transcripts ▸ Drafts, staying in the family.
            model.sidebarSelection = .transcriptDrafts
            model.editDraft(row.doc)
        }
    }
}

/// The library's extracts: statements lifted out of transcripts into
/// letters of their own — every one names whose words it carries and
/// points back at the transcript it came from. Gathered from the library,
/// published copies, and drafts, so an extract is findable from the moment
/// it is lifted.
struct ExtractsListView: View {
    @Environment(AppModel.self) private var model

    private enum Origin: String {
        case library = "Library"
        case draft = "Draft"
        case published = "Published"
    }

    private struct Row: Identifiable {
        let doc: LiquidDoc
        let origin: Origin
        var id: String { doc.id }
    }

    private var rows: [Row] {
        var seen: Set<String> = []
        var rows: [Row] = []
        func add(_ docs: [LiquidDoc], as origin: Origin) {
            for doc in docs where LiftWeaveView.isExtract(doc) && seen.insert(doc.id).inserted {
                rows.append(Row(doc: doc, origin: origin))
            }
        }
        add(model.index.byID.values.map(\.doc), as: .library)
        add(model.drafts.published, as: .published)
        add(model.drafts.documents, as: .draft)
        if !model.searchText.isEmpty {
            rows = rows.filter {
                $0.doc.title.localizedCaseInsensitiveContains(model.searchText)
                    || $0.doc.displayAuthor.localizedCaseInsensitiveContains(model.searchText)
                    || ($0.doc.body ?? []).contains { $0.text.localizedCaseInsensitiveContains(model.searchText) }
            }
        }
        return rows.sorted { $0.doc.listedDate > $1.doc.listedDate }
    }

    /// The transcript this extract was lifted from, when it resolves.
    private func sourceTitle(of doc: LiquidDoc) -> String? {
        doc.links.first { $0.rel == DocumentRelation.cites.rawValue }
            .map { model.index.latestRevision(of: LiquidAddress.canonical($0.to)) }
            .flatMap { model.title(for: $0) }
    }

    @State private var selection: String?

    var body: some View {
        let rows = rows
        // Click to select (and open), ctrl-click for options — the same
        // contract as every other list.
        List(rows, selection: $selection) { row in
            Group {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "quote.opening")
                        .foregroundStyle(.secondary)
                        .padding(.top, 3)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.doc.title)
                            .fontWeight(model.isUnread(row.doc) ? .bold : .regular)
                            .lineLimit(2)
                        Text("\(row.doc.displayAuthor) · \(row.doc.listedDateText)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if let source = sourceTitle(of: row.doc) {
                            Text("from “\(source)”")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    if row.origin != .library {
                        Text(row.origin.rawValue)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .listRowSeparator(.hidden)
            .tag(row.doc.id)
            .contextMenu {
                ContextActionItems(target: .document(row.doc))
            }
        }
        .onChange(of: selection) {
            guard let selection, let row = rows.first(where: { $0.doc.id == selection }) else { return }
            open(row)
        }
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView {
                    Label(model.searchText.isEmpty ? "No Extracts" : "No Results",
                          systemImage: "quote.opening")
                } description: {
                    Text("Lift a statement out of a transcript (click a speaker's name) and it becomes an extract — a letter of its own, linked back to the words it came from.")
                }
            }
        }
    }

    private func open(_ row: Row) {
        switch row.origin {
        case .library, .published:
            // Reading keeps its place; only editing moves the selection.
            model.open(row.doc)
        case .draft:
            model.sidebarSelection = .drafts
            model.editDraft(row.doc)
        }
    }
}

/// The library's letters: documents declared `letter`, plus documents from
/// before types existed — an undeclared document that doesn't read as a
/// transcript is, in this community's terms, a letter. Letters are the
/// core kind; transcripts are letters between people in a meeting.
/// Which filings a Filed list shows: everything (Dialog), only what
/// others sent (Received), only the user's own hand (Outgoing), or the
/// books (Books). Notes keep their own Filed, under Notes.
enum FiledScope {
    case all, received, outgoing, books
}

struct LettersListView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Set<String> = []
    var scope: FiledScope = .all

    static func isLetter(_ doc: LiquidDoc) -> Bool {
        // Extracts are letters too — lifted ones, with a known origin.
        if doc.documentType == LiquidDoc.DocumentType.letter.rawValue
            || doc.documentType == LiquidDoc.DocumentType.extract.rawValue { return true }
        return doc.documentType == nil && !doc.isSidecar && !TranscriptsView.isTranscript(doc)
    }

    /// Every filed document, by folder, in the filing menu's order.
    /// A folder that survives only in old filings still appears, after
    /// the offered ones. Desk notes join through the drafts store.
    private var folders: [(name: String, docs: [LiquidDoc])] {
        var seen: Set<String> = []
        var byFolder: [String: [LiquidDoc]] = [:]
        let source = model.index.byID.values.map(\.doc) + model.drafts.published
            + model.drafts.documents
        for doc in source where seen.insert(doc.id).inserted {
            guard let folder = model.folder(for: doc), inScope(doc) else { continue }
            if model.searchText.isEmpty
                || doc.title.localizedCaseInsensitiveContains(model.searchText)
                || doc.displayAuthor.localizedCaseInsensitiveContains(model.searchText)
                || (doc.body ?? []).contains(where: { $0.text.localizedCaseInsensitiveContains(model.searchText) }) {
                byFolder[folder, default: []].append(doc)
            }
        }
        // Every offered folder shows, holding documents or not — a
        // folder is a place before it is a list. Folders surviving only
        // in old filings join in, and Archived keeps the last word.
        var names = model.filingFolders.filter { $0 != AppModel.archivedFolderName }
        names += byFolder.keys.filter { !model.filingFolders.contains($0) }.sorted()
        names.append(AppModel.archivedFolderName)
        return names.map { name in
            (name, byFolder[name, default: []].sorted { $0.listedDate > $1.listedDate })
        }
    }

    /// Whether a filing belongs to this list. Notes and books never
    /// join the letter scopes — each kind files under its own section.
    private func inScope(_ doc: LiquidDoc) -> Bool {
        let type = doc.documentType
        let isNote = type == LiquidDoc.DocumentType.note.rawValue
        let isBook = type == LiquidDoc.DocumentType.book.rawValue
        switch scope {
        case .all:
            return true
        case .received:
            return !isNote && !isBook && !model.authorIdentity.matches(author: doc.author)
        case .outgoing:
            return !isNote && !isBook && model.authorIdentity.matches(author: doc.author)
        case .books:
            return isBook
        }
    }

    var body: some View {
        let folders = folders
        let allDocs = folders.flatMap(\.docs)
        List(selection: $selection) {
            ForEach(folders, id: \.name) { folder in
                Section {
                    if folder.docs.isEmpty {
                        Text("Nothing filed here yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(folder.docs, id: \.id) { doc in
                        row(for: doc)
                            .tag(doc.id)
                    }
                } header: {
                    Label(folder.name,
                          systemImage: folder.name == AppModel.archivedFolderName
                              ? "archivebox" : "folder")
                }
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            let selected = allDocs.filter { ids.contains($0.id) }
            if selected.count == 1, let doc = selected.first {
                Menu("File") {
                    FileUnderMenuItems(doc: doc)
                }
                Divider()
                // One document answers with the app-wide document menu —
                // cite, file, and the reply family, same as every row.
                ContextActionItems(target: .document(doc))
            } else if !selected.isEmpty {
                Button("Unfile \(selected.count) Documents") {
                    for doc in selected { model.unfile(doc) }
                }
                Divider()
                let urls = selected.map(\.fileURL)
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(urls)
                }
                Button("Copy \(urls.count) Documents") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.writeObjects(urls.map { $0 as NSURL })
                }
            }
        } primaryAction: { ids in
            guard ids.count == 1, let doc = allDocs.first(where: { ids.contains($0.id) }) else { return }
            open(doc)
        }
        // Click to select (and open), as in every other list; ⌘-clicking
        // a second document builds a selection for Copy without opening.
        .onChange(of: selection) {
            guard selection.count == 1, let id = selection.first,
                  let doc = allDocs.first(where: { $0.id == id }) else { return }
            model.open(doc)
        }
        .overlay {
            if folders.isEmpty {
                ContentUnavailableView {
                    Label(model.searchText.isEmpty ? "Nothing Filed" : "No Results",
                          systemImage: "folder")
                } description: {
                    Text("File a letter or note from its context menu — under Work, Personal, a folder of your own, or Archived, which alone hides its documents from the other views.")
                }
            }
        }
    }

    private func row(for doc: LiquidDoc) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: doc.documentType == LiquidDoc.DocumentType.note.rawValue
                  ? "note.text" : "envelope")
                .foregroundStyle(.secondary)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 3) {
                Text(doc.title)
                    .fontWeight(model.isUnread(doc) ? .bold : .regular)
                    .lineLimit(2)
                Text("\(doc.displayAuthor) · \(doc.listedDateText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
        .listRowSeparator(.hidden)
    }

    private func open(_ doc: LiquidDoc) {
        if doc.documentType == LiquidDoc.DocumentType.note.rawValue {
            // A note reads at home, in its Notes list — a filed one in
            // Notes ▸ Filed, since Archived leaves the timeline. The
            // note reader needs that context; plain reading below
            // keeps its place.
            model.sidebarSelection = model.folder(for: doc) != nil ? .filedNotes : .notes
            model.selectedNoteID = doc.id
        } else {
            model.open(doc)
        }
    }
}
