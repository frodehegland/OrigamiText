import SwiftUI

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

    var body: some View {
        let rows = rows
        List {
            ForEach(rows) { row in
                Button {
                    open(row)
                } label: {
                    rowLabel(row)
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle("Transcripts")
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
        .help(row.origin == .draft
              ? "Open this transcript in the draft editor"
              : "Read this transcript — right-click a speaker's name to lift a statement into a new document")
    }

    private func open(_ row: Row) {
        switch row.origin {
        case .library:
            model.openInLibrary(row.doc)
        case .published:
            model.sidebarSelection = .published
            model.open(row.doc)
        case .draft:
            model.sidebarSelection = .drafts
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

    var body: some View {
        let rows = rows
        List(rows) { row in
            Button {
                open(row)
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "quote.opening")
                        .foregroundStyle(.secondary)
                        .padding(.top, 3)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.doc.title)
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
            .buttonStyle(.plain)
        }
        .navigationTitle("Extracts")
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
        case .library:
            model.openInLibrary(row.doc)
        case .published:
            model.sidebarSelection = .published
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
struct LettersListView: View {
    @Environment(AppModel.self) private var model

    private static func isLetter(_ doc: LiquidDoc) -> Bool {
        // Extracts are letters too — lifted ones, with a known origin.
        if doc.documentType == LiquidDoc.DocumentType.letter.rawValue
            || doc.documentType == LiquidDoc.DocumentType.extract.rawValue { return true }
        return doc.documentType == nil && !doc.isSidecar && !TranscriptsView.isTranscript(doc)
    }

    private var letters: [LiquidDoc] {
        var seen: Set<String> = []
        var letters: [LiquidDoc] = []
        for doc in model.index.byID.values.map(\.doc) + model.drafts.published
        where Self.isLetter(doc) && seen.insert(doc.id).inserted {
            letters.append(doc)
        }
        if !model.searchText.isEmpty {
            letters = letters.filter {
                $0.title.localizedCaseInsensitiveContains(model.searchText)
                    || $0.displayAuthor.localizedCaseInsensitiveContains(model.searchText)
                    || ($0.body ?? []).contains { $0.text.localizedCaseInsensitiveContains(model.searchText) }
            }
        }
        return letters.sorted { $0.listedDate > $1.listedDate }
    }

    var body: some View {
        let letters = letters
        List(letters) { doc in
            Button {
                if model.index.byID[doc.id] != nil {
                    model.openInLibrary(doc)
                } else {
                    model.sidebarSelection = .published
                    model.open(doc)
                }
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "envelope")
                        .foregroundStyle(.secondary)
                        .padding(.top, 3)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(doc.title)
                            .lineLimit(2)
                        Text("\(doc.displayAuthor) · \(doc.listedDateText)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .navigationTitle("Letters")
        .overlay {
            if letters.isEmpty {
                ContentUnavailableView {
                    Label(model.searchText.isEmpty ? "No Letters" : "No Results",
                          systemImage: "envelope")
                } description: {
                    Text("Letters are the community's core documents — exporting a draft declares it a letter unless you choose otherwise.")
                }
            }
        }
    }
}
