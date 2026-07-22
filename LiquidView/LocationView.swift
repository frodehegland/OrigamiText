import SwiftUI

/// The record of every place the library's documents have carried —
/// notes captured on the move, letters written from somewhere,
/// transcripts of meetings held somewhere. A place, once used, is
/// remembered here even after its documents move on: Locations.json in
/// Application Support, folded up to date on every library change.
@MainActor @Observable
final class LocationRecord {

    struct Entry: Codable, Identifiable {
        var name: String      // the place as first written
        var firstUsed: Date
        var lastUsed: Date
        var id: String { name.lowercased() }
    }

    /// Every place ever used, most recently used first.
    private(set) var entries: [Entry] = []
    private let fileURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        fileURL = base.appendingPathComponent("Locations.json")
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = saved
        }
    }

    /// Folds every located document into the record — new places gain
    /// an entry, known places widen their first-to-last span. Costs
    /// nothing (and writes nothing) when nothing is new.
    func record(docs: [LiquidDoc]) {
        var byKey: [String: Entry] = [:]
        for entry in entries { byKey[entry.id] = entry }
        var changed = false
        for doc in docs {
            guard let place = doc.location?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !place.isEmpty else { continue }
            let key = place.lowercased()
            let when = doc.listedDate
            if var entry = byKey[key] {
                if when > entry.lastUsed { entry.lastUsed = when; changed = true }
                if when < entry.firstUsed { entry.firstUsed = when; changed = true }
                byKey[key] = entry
            } else {
                byKey[key] = Entry(name: place, firstUsed: when, lastUsed: when)
                changed = true
            }
        }
        guard changed else { return }
        entries = byKey.values.sorted { $0.lastUsed > $1.lastUsed }
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

/// Locations: everywhere the library has been. One section per recorded
/// place, most recently used first; under each, the located documents
/// the library holds there now, newest first. A place whose documents
/// have all moved on stays listed — the record remembers it. Notes show
/// only their when (a note is always its author's own); letters and
/// transcripts carry their author. Click a document to open it.
struct LocationView: View {
    @Environment(AppModel.self) private var model

    private struct Place: Identifiable {
        let id: String        // the place, lowercased — grouping key
        let name: String      // the place as recorded
        let docs: [LiquidDoc] // newest first
    }

    /// Every located note, transcript, and letter — desk notes included —
    /// the library holds now, by place key.
    private var locatedDocs: [String: [LiquidDoc]] {
        var docs: [LiquidDoc] = []
        var seen: Set<String> = []
        for doc in model.filteredNotes where doc.location != nil {
            if seen.insert(doc.id).inserted { docs.append(doc) }
        }
        for entry in model.filteredEntries {
            let doc = entry.doc
            guard doc.location != nil,
                  isNote(doc) || TranscriptsView.isTranscript(doc) || LettersListView.isLetter(doc),
                  seen.insert(doc.id).inserted else { continue }
            docs.append(doc)
        }
        return Dictionary(grouping: docs) { $0.location?.lowercased() ?? "" }
    }

    /// The recorded places, in record order, each carrying its current
    /// documents. A place the record has not caught up with yet (a note
    /// made moments ago) is appended rather than lost.
    private var places: [Place] {
        var docsByKey = locatedDocs
        var places = model.locations.entries.map { entry in
            Place(id: entry.id,
                  name: entry.name,
                  docs: (docsByKey.removeValue(forKey: entry.id) ?? [])
                      .sorted { $0.listedDate > $1.listedDate })
        }
        for (key, docs) in docsByKey {
            let sorted = docs.sorted { $0.listedDate > $1.listedDate }
            places.append(Place(id: key, name: sorted.first?.location ?? key, docs: sorted))
        }
        return places
    }

    var body: some View {
        let places = places
        Group {
            if places.isEmpty {
                ContentUnavailableView(
                    "Nowhere Yet",
                    systemImage: "mappin.and.ellipse",
                    description: Text("Locations appear once notes, transcripts, or letters carry a place — notes captured on the move bring theirs along."))
            } else {
                List {
                    ForEach(places) { place in
                        Section {
                            if place.docs.isEmpty {
                                Text("Nothing here now — the place is remembered.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(place.docs, id: \.id) { doc in
                                    row(for: doc)
                                }
                            }
                        } header: {
                            Label(place.name, systemImage: "mappin.and.ellipse")
                        }
                    }
                }
            }
        }
        // Fold in anything made since the last index change — desk
        // notes especially, which live outside the index.
        .task { model.recordLocations() }
    }

    private func row(for doc: LiquidDoc) -> some View {
        Button {
            open(doc)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(doc.title)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(caption(for: doc))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// A note says only when — it is always its author's own; letters and
    /// transcripts carry their author before the date.
    private func caption(for doc: LiquidDoc) -> String {
        let when = doc.date?.displayText
            ?? doc.created.formatted(date: .abbreviated, time: .shortened)
        if isNote(doc) { return when }
        return "\(doc.displayAuthor) · \(when)"
    }

    private func isNote(_ doc: LiquidDoc) -> Bool {
        doc.documentType == LiquidDoc.DocumentType.note.rawValue
    }

    /// Library documents open in the reader; a desk note goes home to
    /// Notes and its editor.
    private func open(_ doc: LiquidDoc) {
        if model.index.byID[doc.id] != nil {
            model.openInLibrary(doc)
        } else {
            model.sidebarSelection = .notes
            model.selectedNoteID = doc.id
            if let deskNote = model.drafts.documents.first(where: { $0.id == doc.id }) {
                model.editDraft(deskNote)
            }
        }
    }
}

extension LocationView {
    /// Locations as an exchangeable module.
    @MainActor static let module = LibraryViewModule(
        id: "location",
        name: "Locations",
        systemImage: "mappin.and.ellipse",
        makeContent: { AnyView(DocumentListView()) },
        makeDetail: { _ in AnyView(LocationView()) },
        hidesDocumentList: true
    )
}
