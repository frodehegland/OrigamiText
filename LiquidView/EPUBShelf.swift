import Foundation
import Observation
import SwiftUI
#if os(iOS)
import UIKit
#endif
#if os(macOS)
import AppKit
#endif

/// A remembered EPUB in the reader's library: enough to list it (title,
/// author, date) and to reopen its rendered page (the unpacked `folder`
/// under the app container's EPUBs directory, and the content document's
/// path within it). Persisted to an internal manifest — no JSON document
/// is written, per the EPUB-only direction.
///
/// In its own file (not EPUBReaderView.swift, which is WebKit/macOS)
/// so the visionOS target shares the shelf's record type.
struct EPUBRecord: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let author: String
    /// Every author of record, in order, when the book named more than
    /// one. Optional so manifests written before it decode unchanged.
    var authors: [String]? = nil
    /// ISO 8601, when the Visual-Meta carried a date.
    let dateISO: String?
    /// The unpack folder name under the EPUBs directory.
    let folder: String
    /// The content document's path within `folder`, e.g. "content/paper.html".
    let contentSubpath: String
    /// When it was opened, for ordering the library newest-first.
    let openedAt: Date
    /// The journal or proceedings the book is part of, when it declares
    /// one. "" means the package was checked and names none; nil means
    /// a record written before venues were kept (not yet checked).
    var publication: String? = nil

    /// The Digital Object Identifier the package declares, normalised to
    /// bare form (e.g. "10.1145/3290605.3300526"). nil for records written
    /// before DOI tracking was added or for books that carry none.
    var doi: String? = nil

    /// The original .epub filename (e.g. "My Paper.epub") — the value Author
    /// stores as `origami-source-file` in its BibTeX, used as a library
    /// fallback when UUID lookup fails. nil for records written before this
    /// field was added.
    var originalFilename: String? = nil

    /// The EPUB package's own publication identifier (the `dc:identifier`
    /// value from package.opf, typically a `urn:uuid:…`). Unlike the Origami
    /// address, this is embedded in the EPUB file itself and therefore
    /// identical across every installation that opens the same file — used
    /// as the fallback canonical URI for community annotation services when
    /// no DOI is available.
    var packageIdentifier: String? = nil

    /// The authors to list the book under: the full list when known,
    /// else the single author of record.
    var authorList: [String] { authors ?? [author] }

    /// The declared venue, empty-checked: nil when the book names none.
    var venue: String? {
        let name = publication?.trimmingCharacters(in: .whitespaces) ?? ""
        return name.isEmpty ? nil : name
    }
}

/// The reader's standing over the shelf — which books are pinned and
/// which set aside — as one small file in the community folder, so the
/// Mac and the Vision Pro agree. Whole-file, last-writer-wins: each
/// device writes on every change and adopts on every scan, skipping
/// files older than its own last write.
/// Books the reader asked for from the headset: cited works not yet in
/// the library, listed for the Mac to acquire — one small file in the
/// community folder, merged by key so a wish is never doubled.
nonisolated enum EPUBAcquisitions {

    struct Wanted: Codable, Sendable, Identifiable {
        /// The citation key — title|author, lowercased, spaceless.
        var id: String
        var title: String
        var author: String
        var year: Int?
        var doi: String?
        var added: Date
    }

    private struct State: Codable {
        var wanted: [Wanted]
        var modified: Date
    }

    private static let fileName = "origami-acquisitions.json"

    static func read(from folder: URL) -> [Wanted] {
        let url = folder.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(State.self, from: data)
        else { return [] }
        return state.wanted
    }

    static func add(_ item: Wanted, in folder: URL) {
        var wanted = read(from: folder)
        guard !wanted.contains(where: { $0.id == item.id }) else { return }
        wanted.append(item)
        write(wanted, to: folder)
    }

    static func remove(id: String, in folder: URL) {
        var wanted = read(from: folder)
        wanted.removeAll { $0.id == id }
        write(wanted, to: folder)
    }

    private static func write(_ wanted: [Wanted], to folder: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(State(wanted: wanted, modified: .now)) {
            try? data.write(to: folder.appendingPathComponent(fileName),
                            options: .atomic)
        }
    }
}

nonisolated enum EPUBStanding {

    struct State: Codable {
        var pinned: [String]
        var setAside: [String]
        /// The reader's tracked concepts (the macOS Concepts view),
        /// riding along so the Vision Pro's arm can offer them.
        /// Optional: files written before concepts travelled decode
        /// without them.
        var concepts: [String]?
        var modified: Date
    }

    private static let fileName = "origami-standing.json"

    static func read(from folder: URL) -> State? {
        let url = folder.appendingPathComponent(fileName)
        // An uncoordinated read of an iCloud item serves whatever bytes
        // are already local — stale for as long as nothing asks the
        // provider for the version another device wrote. The coordinated
        // read requests the current version and waits for this small
        // file to land; the adopt paths hold it off the main actor.
        var data: Data?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [],
                                       error: &coordinationError) { readURL in
            data = try? Data(contentsOf: readURL)
        }
        guard let data else { return nil }
        return try? JSONDecoder().decode(State.self, from: data)
    }

    /// The shared file names books by their community-file identity
    /// (EPUBRecord.folder) — internal record ids differ between
    /// devices' import histories; the file name is the one name every
    /// device agrees on, exactly as the Map's layout keys. A name with
    /// no record here — a hypermedia address, a book this device does
    /// not hold — passes through unchanged, so its standing survives
    /// this device's writes.
    static func fileNames(for ids: Set<String>,
                          records: [EPUBRecord]) -> Set<String> {
        var folderByID: [String: String] = [:]
        for record in records { folderByID[record.id] = record.folder }
        return Set(ids.map { folderByID[$0] ?? $0 })
    }

    /// The file's names brought home: a community file name becomes
    /// the local record's id; an id from a file written before names
    /// travelled stands as it is; anything unknown passes through, so
    /// a book absent here keeps its standing everywhere else.
    static func localIDs(from names: some Sequence<String>,
                         records: [EPUBRecord]) -> Set<String> {
        var idByFolder: [String: String] = [:]
        for record in records { idByFolder[record.folder] = record.id }
        return Set(names.map { idByFolder[$0] ?? $0 })
    }

    @discardableResult
    static func write(pinned: Set<String>, setAside: Set<String>,
                      concepts: [String], to folder: URL) -> Date {
        let state = State(pinned: pinned.sorted(), setAside: setAside.sorted(),
                          concepts: concepts,
                          modified: .now)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(state) {
            try? data.write(to: folder.appendingPathComponent(fileName), options: .atomic)
        }
        return state.modified
    }
}

/// Persists user-written definitions and category overrides for merged
/// concepts. Stored in Application Support (personal, not community folder)
/// so the user's annotations are never overwritten by shared library state.
@Observable
final class ConceptOverrideStore {
    private struct Entry: Codable {
        var definition: String?
        var category: String?
    }
    private var entries: [String: Entry] = [:]
    private static let fileName = "origami-concept-overrides.json"

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(fileName)
    }

    init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let loaded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = loaded
        }
    }

    func definition(for id: String) -> String? { entries[id]?.definition }
    func category(for id: String) -> String? { entries[id]?.category }

    func set(definition: String?, for id: String) {
        entries[id, default: Entry()].definition = definition?.isEmpty == true ? nil : definition
        persist()
    }

    func set(category: String?, for id: String) {
        entries[id, default: Entry()].category = category?.isEmpty == true ? nil : category
        persist()
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(entries) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }
}

/// Community supersession: when a shelf book's own file has left the
/// community folder while a same-titled sibling's file is present, the
/// absent one has been re-published — a corrected conversion, a
/// DOI-named replacement — and the old copy retires in the successor's
/// favour. Decision logic only, shared by the phone and the headset;
/// each model carries out its own retirements (standing and
/// annotations move to the successor first). The Mac needs none of
/// this: its mirror republishes anything the folder lacks, so absence
/// cannot arise there.
nonisolated enum EPUBSupersession {

    /// Case-, diacritic- and punctuation-blind title identity.
    static func titleKey(_ title: String) -> String {
        title.folding(options: [.diacriticInsensitive, .caseInsensitive],
                      locale: nil)
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    /// The unpack-folder name a file would import under — the same
    /// derivation `importEPUB` uses, so presence in the community
    /// folder can be matched against `EPUBRecord.folder`.
    static func folderName(forFileName name: String) -> String {
        let identity = LiquidDoc.identityKeyID(inFileName: name) ?? name
        return identity.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
    }

    /// The records to retire, each with its successor: the record's own
    /// file is absent from the folder while a same-titled sibling's is
    /// present. An iCloud placeholder counts as present — undownloaded
    /// is not removed, and no book retires mid-sync.
    static func retirements(records: [EPUBRecord], presentFolders: Set<String>)
        -> [(old: EPUBRecord, successor: EPUBRecord)] {
        var presentByTitle: [String: EPUBRecord] = [:]
        for record in records where presentFolders.contains(record.folder) {
            let key = titleKey(record.title)
            if !key.isEmpty, presentByTitle[key] == nil {
                presentByTitle[key] = record
            }
        }
        var retirements: [(EPUBRecord, EPUBRecord)] = []
        for record in records where !presentFolders.contains(record.folder) {
            guard let successor = presentByTitle[titleKey(record.title)],
                  successor.id != record.id else { continue }
            retirements.append((record, successor))
        }
        return retirements
    }
}

// MARK: - The proceedings map

/// The map's node positions, shared across every device the community
/// folder reaches: lay the venue out on the iPad and the same X and Y
/// stand on the Mac and in the Vision Pro's hallway (which keeps its
/// own Z). Units are the hallway's meters — x right of its center,
/// y up from the floor; the flat map scales them to points. One file,
/// last writer wins, exactly as the standing file resolves. A mirror
/// in Application Support serves when no community folder is chosen,
/// and lets the Vision Pro's map (which loads before any model is in
/// reach) read state refreshed during the shelf scan.
nonisolated enum EPUBMapSharedLayout {

    struct Point: Codable {
        var x: Double
        var y: Double
        /// When this entry was placed. Merging is per entry, newest
        /// wins — a device saving from a stale copy of the file can
        /// no longer roll every other card back. Nil in files written
        /// before the stamp: treated as oldest.
        var t: Date? = nil
    }

    struct State: Codable {
        var positions: [String: Point]
        var modified: Date
    }

    private static let fileName = "origami-map-layout.json"

    private static var mirrorURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(
            at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent(fileName)
    }

    /// The community file and the local mirror, merged entry by entry —
    /// per card, the newest placement wins, whichever home holds it.
    static func load(community folder: URL?) -> State {
        let mirror = read(at: mirrorURL)
        let shared = folder.flatMap { url in
            withScope(url) { read(at: $0.appendingPathComponent(fileName)) }
        }
        return merged(mirror, shared)
    }

    /// Merges the given positions (stamped now) into the merged state
    /// and writes it to both homes. Only the given ids move; every
    /// other entry — the other venues', the hallway's extras — stands.
    static func save(updating updates: [String: Point], community folder: URL?) {
        var state = load(community: folder)
        let now = Date()
        for (id, point) in updates {
            state.positions[id] = Point(x: point.x, y: point.y, t: now)
        }
        state.modified = now
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(state) else { return }
        try? data.write(to: mirrorURL, options: .atomic)
        if let folder {
            withScope(folder) {
                try? data.write(to: $0.appendingPathComponent(fileName),
                                options: .atomic)
            }
        }
    }

    /// Merges the community file into the local mirror — called beside
    /// the standing adoption on each shelf scan.
    static func refreshMirror(community folder: URL) {
        let shared = withScope(folder) {
            read(at: $0.appendingPathComponent(fileName))
        }
        guard shared != nil else { return }
        let state = merged(read(at: mirrorURL), shared)
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: mirrorURL, options: .atomic)
    }

    private static func merged(_ a: State?, _ b: State?) -> State {
        switch (a, b) {
        case (nil, nil): return State(positions: [:], modified: .distantPast)
        case let (one?, nil): return one
        case let (nil, one?): return one
        case let (l?, r?):
            var positions = l.positions
            for (key, point) in r.positions {
                let held = positions[key]?.t ?? .distantPast
                if (point.t ?? .distantPast) > held || positions[key] == nil {
                    positions[key] = point
                }
            }
            return State(positions: positions,
                         modified: max(l.modified, r.modified))
        }
    }

    private static func read(at url: URL) -> State? {
        // An iCloud copy that is a placeholder or has gone stale reads
        // as absent or old. Nudge the download and give this small file
        // a short moment to land, so the first open after another
        // device's write reads fresh; offline, the wait caps out and
        // what is here (if anything) serves.
        func status(_ url: URL) -> URLUbiquitousItemDownloadingStatus? {
            let fresh = URL(fileURLWithPath: url.path)
            return (try? fresh.resourceValues(
                forKeys: [.ubiquitousItemDownloadingStatusKey]))?
                .ubiquitousItemDownloadingStatus
        }
        if let state = status(url), state != .current {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            for _ in 0..<6 {
                Thread.sleep(forTimeInterval: 0.15)
                if status(url) == .current { break }
            }
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(State.self, from: data)
    }

    private static func withScope<T>(_ url: URL, _ body: (URL) -> T) -> T {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return body(url)
    }
}

/// The Map's saved views: named arrangements kept on this device, and
/// the shared copies a reader chose to publish to the community folder.
/// Positions speak the layout file's meters, keyed by the book's
/// community identity, so every device replays the same picture.
nonisolated enum EPUBMapViews {

    struct File: Codable {
        /// venue → view name → book key → position in meters.
        var venues: [String: [String: [String: EPUBMapSharedLayout.Point]]] = [:]

        func names(venue: String) -> [String] {
            (venues[venue] ?? [:]).keys.sorted()
        }
    }

    private static let sharedName = "_map-views.json"

    private static var localURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(
            at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("origami-map-views.json")
    }

    static func local() -> File {
        read(at: localURL) ?? File()
    }

    static func shared(community folder: URL?) -> File {
        guard let folder else { return File() }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        return read(at: folder.appendingPathComponent(sharedName)) ?? File()
    }

    static func saveLocal(venue: String, name: String,
                          positions: [String: EPUBMapSharedLayout.Point]) {
        var file = local()
        file.venues[venue, default: [:]][name] = positions
        write(file, to: localURL)
    }

    /// Publishes one kept view into the community folder — merged into
    /// whatever views others shared, never replacing the whole file.
    static func share(venue: String, name: String,
                      positions: [String: EPUBMapSharedLayout.Point],
                      community folder: URL?) {
        guard let folder else { return }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let url = folder.appendingPathComponent(sharedName)
        var file = read(at: url) ?? File()
        file.venues[venue, default: [:]][name] = positions
        write(file, to: url)
    }

    private static func read(at url: URL) -> File? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(File.self, from: data)
    }

    private static func write(_ file: File, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(file) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// The Map's topic magnets, shared by the Mac's bar and the hallway's
/// row: the naming that fills the slots from the papers' AI labels and
/// titles, and the pull that decides which papers a topic speaks for.
/// One algorithm, so both rooms show the same topics for a venue.
nonisolated enum MapTopics {

    /// A standing paper as the naming sees it: its identity, its title,
    /// and the AI's labels for it (concepts, keywords, title topics).
    typealias Paper = (id: String, title: String, topics: [String])

    /// The words of a pole, topic, or title — lowercased, split on
    /// anything that isn't a letter or digit.
    static func words(_ text: String) -> Set<String> {
        Set(text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty })
    }

    /// Everyday words that must not name a pole when the titles do.
    static let stopWords: Set<String> = [
        "the", "and", "for", "with", "from", "into", "through", "towards",
        "toward", "using", "under", "over", "between", "across", "about",
        "study", "case", "paper", "papers", "approach", "based", "beyond",
        "when", "what", "where", "how", "why", "does", "their", "your",
    ]
    /// Short words that may: the field's own initialisms.
    static let shortWords: Set<String> = [
        "ai", "xr", "vr", "ar", "llm", "llms", "web", "html",
    ]

    /// A topic speaks for a text when each of its words stands in it —
    /// whole, or as the stem of a longer word, so "hyper" pulls
    /// "hypertextual" but "AI" never pulls "maintain".
    static func speaks(_ pole: Set<String>, for textWords: Set<String>) -> Bool {
        guard !pole.isEmpty else { return false }
        return pole.allSatisfy { word in
            textWords.contains {
                $0 == word || ($0.hasPrefix(word) && word.count >= 4)
            }
        }
    }

    /// The pull: one per topic label the pole speaks for, and one for
    /// the title — so papers the AI hasn't read yet answer too, and
    /// sharpen as the extractions land.
    static func pull(pole: Set<String>, topics: [String], title: String) -> Int {
        var count = topics.reduce(0) { count, topic in
            speaks(pole, for: words(topic)) ? count + 1 : count
        }
        if speaks(pole, for: words(title)) { count += 1 }
        return count
    }

    /// The candidate names: every topic label and title word, each with
    /// the papers it speaks for — so the titles hold the board up until
    /// the AI's topics arrive.
    static func candidates(_ standing: [Paper])
        -> [(name: String, covers: Set<String>)] {
        var covers: [String: Set<String>] = [:]
        var display: [String: String] = [:]
        for paper in standing {
            for raw in paper.topics {
                let label = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard label.count > 1 else { continue }
                let key = label.lowercased()
                if display[key] == nil { display[key] = label }
                covers[key, default: []].insert(paper.id)
            }
            for word in words(paper.title)
            where (word.count > 3 || shortWords.contains(word))
                && !stopWords.contains(word) {
                if display[word] == nil {
                    display[word] = shortWords.contains(word) && word != "web"
                        ? word.uppercased() : word.capitalized
                }
                covers[word, default: []].insert(paper.id)
            }
        }
        return covers.sorted {
            $0.value.count != $1.value.count
                ? $0.value.count > $1.value.count : $0.key < $1.key
        }.map { (display[$0.key] ?? $0.key, $0.value) }
    }

    /// Names the topic slots: the reader's kept names take theirs, then
    /// the empty slots fill greedily — each next name the one that
    /// speaks for the most papers still unspoken for, so the set covers
    /// the venue rather than repeating its loudest topic. No two names
    /// mere longer or shorter forms of each other. Empty slots drop.
    static func names(standing: [Paper], kept: [String] = [],
                      slots: Int = 12) -> [String] {
        var names = Array(repeating: "", count: slots)
        for (slot, name) in kept.enumerated() where slot < slots {
            names[slot] = name.trimmingCharacters(in: .whitespaces)
        }
        var taken = Set(names.map { $0.lowercased() }.filter { !$0.isEmpty })
        var covered = Set<String>()
        for name in taken {
            let pole = words(name)
            for paper in standing
            where pull(pole: pole, topics: paper.topics, title: paper.title) > 0 {
                covered.insert(paper.id)
            }
        }
        var pool = candidates(standing).filter { candidate in
            let key = candidate.name.lowercased()
            return !taken.contains(where: { $0.contains(key) || key.contains($0) })
        }
        for slot in names.indices where names[slot].isEmpty {
            guard let best = pool.indices.max(by: {
                let a = pool[$0], b = pool[$1]
                let newA = a.covers.subtracting(covered).count
                let newB = b.covers.subtracting(covered).count
                if newA != newB { return newA < newB }
                if a.covers.count != b.covers.count { return a.covers.count < b.covers.count }
                return a.name > b.name
            }) else { break }
            let chosen = pool.remove(at: best)
            let key = chosen.name.lowercased()
            names[slot] = chosen.name
            taken.insert(key)
            covered.formUnion(chosen.covers)
            pool.removeAll {
                let other = $0.name.lowercased()
                return other.contains(key) || key.contains(other)
            }
        }
        return names.filter { !$0.isEmpty }
    }
}

/// The proceedings as a flat map — Author's Map for one venue: every
/// article a card on the plane, dragged where the reader wants it,
/// opened with a double click. Positions persist through EPUBMapSharedLayout in
/// the hallway's meters; Pin and Set Aside ride the standing file as
/// they do everywhere. Closure-driven so the Mac's and the phone's
/// models plug in without this shared file knowing either.
struct ProceedingsMapView: View {

    struct Item: Identifiable {
        let id: String
        /// The book's community-file identity (EPUBRecord.folder) — the
        /// shared layout's key. Internal record ids differ between
        /// devices' import histories; the file name is the one name
        /// every device agrees on.
        let key: String
        let title: String
        let author: String
        var isPinned = false
        var isSetAside = false
        /// The AI's short labels for this paper — the computed views'
        /// magnets. Topics fold concepts, keywords, and title topics;
        /// entities fold technologies and places.
        var topics: [String] = []
        var people: [String] = []
        var entities: [String] = []
        /// The paper's best-ranked series author (the imported dataset's
        /// person) and their paper count — the Author Rank view's rungs.
        var seriesName: String? = nil
        var seriesCount: Int = 0
    }

    let items: [Item]
    /// The community folder carrying the shared layout; nil reads and
    /// writes the local mirror alone.
    let folder: URL?
    /// The journal's name — the saved views' shelf key.
    var venue: String = ""
    let open: (String) -> Void
    /// The paper's abstract by id, read live at lift time — the index
    /// builds the books in the background, so a value baked into the
    /// items when the plane first stood could be empty for good.
    var abstractFor: (String) -> String = { _ in "" }
    let togglePin: (String) -> Void
    let toggleSetAside: (String) -> Void
    /// Back to the journal's list of books — the foot bar's leading
    /// chevron.
    var back: (() -> Void)? = nil
    /// Called on each refresh beat while the map is visible — the
    /// platforms adopt the shared standing here, so Pin and Set Aside
    /// travel live between open maps, not only on the next shelf scan.
    var tick: (() -> Void)? = nil

    /// Canvas positions in points, by book id — the shared meters
    /// drawn onto the plane.
    @State private var positions: [String: CGPoint] = [:]

    /// The foot bar's Find: matching cards light up, the rest recede.
    @State private var findText = ""

    /// The clicked card, lifted off the plane until clicked again or
    /// another takes its place. Views are only layouts: switching one
    /// never touches this, so the selection survives the crossing.
    @State private var liftedID: String?

    /// ⌘A's whole-plane selection: dragging any member moves them all
    /// together. A click on empty plane lets go. Survives view switches
    /// like the lift does.
    @State private var selectedIDs: Set<String> = []
    /// Where every selected card stood when the group drag began.
    @State private var groupDragBase: [String: CGPoint]?
    #if os(macOS)
    @State private var selectAllMonitor: Any?
    #endif

    /// Which layout the plane shows. Default is the hand-placed shared
    /// layout; the computed views arrange the same cards around their
    /// labels; a saved view replays a kept arrangement.
    enum MapViewChoice: Equatable {
        case standard, topics, authors, people, rank
        case saved(String)

        var title: String {
            switch self {
            case .standard: "Default"
            case .topics: "Topics"
            case .authors: "Authors"
            case .people: "People"
            case .rank: "Author Rank"
            case .saved(let name): name
            }
        }
    }

    @State private var viewChoice: MapViewChoice = .standard
    /// The non-default views' positions — an overlay over the same
    /// cards. Drags here stay here; only the Default layout persists
    /// to the shared file.
    @State private var overlayPositions: [String: CGPoint] = [:]
    /// The computed view's magnet captions, drawn under the cards.
    @State private var clusterCaptions: [(label: String, at: CGPoint)] = []
    /// The saved arrangements on this Mac, and the ones shared through
    /// the community folder.
    @State private var savedLocalNames: [String] = []
    @State private var savedSharedNames: [String] = []
    @State private var showsSavePrompt = false
    @State private var saveName = ""
    /// The Magnets view's poles in a row along the plane's top —
    /// auto-named from the papers' topics and titles, each editable in
    /// place; every paper stands in the column of its strongest magnet.
    @State private var magnetNames: [String] = Array(repeating: "", count: 12)
    /// The clicked magnet: threads run from it to every paper it
    /// speaks for, thicker where the pull is stronger. Clicking the
    /// empty plane lets go.
    @FocusState private var focusedMagnet: Int?
    /// The magnet bar across the top of the screen — toggled from the
    /// foot bar, standing over every view, kept per user.
    @AppStorage("mapMagnetBar") private var showsMagnetBar = false
    /// The measured geometry that lets the threads bridge the scrolling
    /// plane and the screen-pinned bar — nothing assumed, everything
    /// read from the named "mapPlane" space: each magnet chip's centre,
    /// the plane's (0,0) as it scrolls, and the overlay's own frame.
    @State private var magnetCenters: [Int: CGPoint] = [:]
    @State private var canvasOrigin: CGPoint = .zero

    /// One hallway meter drawn at this many points; the canvas center
    /// is the hallway's (0, 1.2) — mid-height of its article grid.
    private static let pointsPerMeter: CGFloat = 620
    private static let canvasSize = CGSize(width: 2600, height: 1800)

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                canvasBase
                // The plane's (0,0), reported in screen space as it
                // scrolls — the thread overlay's bridge to the cards.
                Color.clear
                    .frame(width: 1, height: 1)
                    .onGeometryChange(for: CGPoint.self, of: {
                        $0.frame(in: .named("mapPlane")).origin
                    }) { canvasOrigin = $0 }
                // The threads, on the plane BENEATH every card — their
                // upper ends chase the screen-pinned chips as the plane
                // scrolls under them.
                if showsMagnetBar {
                    threadOverlay
                        .frame(width: Self.canvasSize.width,
                               height: Self.canvasSize.height)
                }
                // The computed view's magnets, named — quiet captions
                // beneath the cards that gather around them.
                ForEach(clusterCaptions.indices, id: \.self) { index in
                    let caption = clusterCaptions[index]
                    Text(caption.label)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary.opacity(0.55))
                        .position(caption.at)
                        .allowsHitTesting(false)
                }
                let connected = threadConnectedIDs
                ForEach(items) { item in
                    ProceedingsMapNode(
                        item: item,
                        emphasis: emphasis(for: item),
                        isLifted: liftedID == item.id,
                        isGrouped: selectedIDs.contains(item.id),
                        position: binding(for: item),
                        bounds: Self.canvasSize,
                        open: { open(item.id) },
                        abstractFor: abstractFor,
                        select: {
                            liftedID = liftedID == item.id ? nil : item.id
                        },
                        togglePin: { togglePin(item.id) },
                        toggleSetAside: { setAsideDroppingToFloor(item) },
                        // A member of the ⌘A selection carries the rest.
                        groupDragged: { translation in
                            groupDragged(item, translation: translation)
                        },
                        moved: { nodeMoved(item) })
                    // While threads stand, the cards they touch are the
                    // subject — everything unthreaded steps back.
                    .opacity(connected == nil || connected!.contains(item.id)
                             ? 1 : 0.25)
                    // The lifted card rises above its neighbours — its
                    // grown frame must never swallow a click meant for
                    // the card visually beside it.
                    .zIndex(liftedID == item.id ? 1 : 0)
                }
            }
        }
        .defaultScrollAnchor(.center)
        .background(Color.secondary.opacity(0.06))
        .safeAreaInset(edge: .bottom, spacing: 0) { footBar }
        .safeAreaInset(edge: .top, spacing: 0) {
            if showsMagnetBar { magnetBar }
        }
        .coordinateSpace(.named("mapPlane"))
        .onAppear(perform: reload)
        #if os(macOS)
        // ⌘A takes the whole plane — unless the Find field is writing.
        .onAppear {
            guard selectAllMonitor == nil else { return }
            selectAllMonitor = NSEvent.addLocalMonitorForEvents(
                matching: .keyDown
            ) { event in
                guard event.modifierFlags
                    .intersection(.deviceIndependentFlagsMask) == .command,
                      event.charactersIgnoringModifiers?.lowercased() == "a",
                      !(NSApp.keyWindow?.firstResponder is NSTextView)
                else { return event }
                selectedIDs = Set(items.map(\.id))
                return nil
            }
        }
        .onDisappear {
            if let selectAllMonitor {
                NSEvent.removeMonitor(selectAllMonitor)
            }
            selectAllMonitor = nil
        }
        #endif
        // The AI's labels land asynchronously: when they change while a
        // computed view is up, the magnets re-gather.
        .onChange(of: tagsFingerprint) {
            switch viewChoice {
            case .topics, .authors, .people, .rank: switchView(to: viewChoice)
            default: break
            }
        }
        .alert("Save View", isPresented: $showsSavePrompt) {
            TextField("Name", text: $saveName)
            Button("Save") { saveCurrentView() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Keeps this arrangement on this Mac. Share it to the community folder from the view menu.")
        }
        // Two maps open at once converse through the file: while this
        // one is visible it re-reads every few beats, off the main
        // actor, and the per-entry merge lets both sides move cards at
        // the same time — per card, the newest touch wins.
        .task {
            let folder = folder
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                tick?()
                let state = await Task.detached(priority: .utility) {
                    EPUBMapSharedLayout.load(community: folder)
                }.value
                apply(state)
            }
        }
    }

    /// Lays the given shared state onto the canvas — reload's arithmetic
    /// on already-fetched bytes.
    private func apply(_ state: EPUBMapSharedLayout.State) {
        let seeds = Self.seeds(for: items)
        seedCache = seeds
        var next: [String: CGPoint] = [:]
        for item in items {
            next[item.id] = state.positions[item.key].map { Self.canvasPoint($0) }
                ?? seeds[item.id] ?? Self.canvasCenter
        }
        if next != positions { positions = next }
    }

    /// The Map's foot: the way back to the journal's list at the left,
    /// the view menu beside it, Find in the middle.
    private var footBar: some View {
        HStack(spacing: 12) {
            if let back {
                Button(action: back) {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.semibold))
                }
                .buttonStyle(.plain)
                .help("Back to the journal's articles")
            }
            viewMenu
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Find", text: $findText)
                    .textFieldStyle(.plain)
                    // Words no card carries: an error beep answers each
                    // keystroke that stays unmatched.
                    .onChange(of: findText) {
                        guard !findText.trimmingCharacters(in: .whitespaces).isEmpty,
                              !items.contains(where: matchesFind) else { return }
                        #if os(macOS)
                        NSSound.beep()
                        #endif
                    }
                if !findText.isEmpty {
                    Button {
                        findText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 2)
            .frame(maxWidth: 280)
            .background(Capsule().fill(Color.secondary.opacity(0.12)))
            // The topic bar's switch: topics across the top of the
            // screen, threads to and from the cards.
            Button {
                showsMagnetBar.toggle()
                if showsMagnetBar { ensureMagnetNames() }
            } label: {
                Label("Topics", systemImage: "rectangle.topthird.inset.filled")
                    .font(.callout)
                    .foregroundStyle(showsMagnetBar ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help(showsMagnetBar ? "Hide the topic bar" : "Show the topic bar")
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    /// The view menu: the Default hand layout, the computed views, the
    /// saved arrangements — and the keeping and sharing of them.
    private var viewMenu: some View {
        Menu {
            Button("Default") { switchView(to: .standard) }
            Button("Topics") { switchView(to: .topics) }
            Button("Authors") { switchView(to: .authors) }
            Button("People") { switchView(to: .people) }
            Button("Author Rank") { switchView(to: .rank) }
            // Magnets left this menu: the bar arranges nothing on its
            // own — ctrl-click a topic and choose Arrange instead.
            let names = savedViewNames
            if !names.isEmpty {
                Divider()
                ForEach(names, id: \.self) { name in
                    Button(name) { switchView(to: .saved(name)) }
                }
            }
            Divider()
            Button("Save Current View…") {
                saveName = viewChoice.title == "Default" ? "" : viewChoice.title
                showsSavePrompt = true
            }
            if !savedLocalNames.isEmpty {
                Menu("Share View") {
                    ForEach(savedLocalNames, id: \.self) { name in
                        Button(name) { shareView(name) }
                    }
                }
            }
        } label: {
            Label(viewChoice.title, systemImage: "square.grid.3x3.topleft.filled")
                .font(.callout)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("The Map's views: layouts over the same cards — the selection travels with you")
    }

    /// Local and shared saved views, locals first, shared ones that
    /// aren't also local after.
    private var savedViewNames: [String] {
        savedLocalNames + savedSharedNames.filter { !savedLocalNames.contains($0) }
    }

    /// One string that changes when any card's AI labels do — the
    /// recompute trigger for a standing computed view.
    private var tagsFingerprint: String {
        items.map {
            "\($0.id):\($0.topics.count).\($0.people.count).\($0.entities.count).\($0.seriesCount)"
        }.joined(separator: "|")
    }

    /// The plane's floor: set-aside cards rest in a row along the
    /// bottom edge, wrapping upward when the row fills.
    private static func asideFloorPoint(index: Int) -> CGPoint {
        CGPoint(x: 150 + CGFloat(index % 16) * 150,
                y: canvasSize.height - 60 - CGFloat(index / 16) * 70)
    }

    /// Setting a card aside drops it to the plane's floor row; bringing
    /// it back leaves it there for the hand to lift where it pleases.
    private func setAsideDroppingToFloor(_ item: Item) {
        if !item.isSetAside {
            let point = Self.asideFloorPoint(
                index: items.filter(\.isSetAside).count)
            if viewChoice == .standard {
                positions[item.id] = point
                EPUBMapSharedLayout.save(
                    updating: [item.key: Self.sharedPoint(point)],
                    community: folder)
            } else {
                overlayPositions[item.id] = point
            }
        }
        toggleSetAside(item.id)
    }

    /// Find on the plane: a card whose title or author carries the words
    /// stands forward; the rest recede until the field clears. When NO
    /// card carries them, nothing fades — the map stands as it was, and
    /// the beep on the field has already said why.
    private func emphasis(for item: Item) -> ProceedingsMapNode.Emphasis {
        let query = findText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return .normal }
        guard items.contains(where: matchesFind) else { return .normal }
        return matchesFind(item) ? .matched : .dimmed
    }

    /// Whether Find's words stand in the card's title or author.
    private func matchesFind(_ item: Item) -> Bool {
        let query = findText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return false }
        return item.title.localizedCaseInsensitiveContains(query)
            || item.author.localizedCaseInsensitiveContains(query)
    }

    /// The plane itself. A click on empty plane lets the ⌘A selection
    /// go. On the iPad it carries the two-finger probe: panning the map
    /// takes two fingers, leaving one free for the cards.
    private var canvasBase: some View {
        let base = Color.clear
            .frame(width: Self.canvasSize.width,
                   height: Self.canvasSize.height)
            .contentShape(Rectangle())
            .onTapGesture {
                selectedIDs = []
                focusedMagnet = nil
                // The lifted card sets down too — empty plane lets
                // everything go.
                liftedID = nil
            }
        #if os(iOS)
        return base.background(TwoFingerScrollConfigurator())
        #else
        return base
        #endif
    }

    // MARK: The ⌘A group — every selected card moves with the one in hand

    /// The dragged member's translation, applied to the rest of the
    /// selection from where each stood when the drag began.
    private func groupDragged(_ item: Item, translation: CGSize) {
        guard selectedIDs.contains(item.id), selectedIDs.count > 1 else { return }
        let base = groupDragBase ?? {
            var snapshot: [String: CGPoint] = [:]
            for other in items where selectedIDs.contains(other.id) {
                snapshot[other.id] = binding(for: other).wrappedValue
            }
            groupDragBase = snapshot
            return snapshot
        }()
        for other in items where selectedIDs.contains(other.id) && other.id != item.id {
            guard let start = base[other.id] else { continue }
            let point = CGPoint(
                x: min(max(start.x + translation.width, 90),
                       Self.canvasSize.width - 90),
                y: min(max(start.y + translation.height, 40),
                       Self.canvasSize.height - 40))
            if viewChoice == .standard {
                positions[other.id] = point
            } else {
                overlayPositions[other.id] = point
            }
        }
    }

    /// A drag ended: in the Default view the moved cards persist to the
    /// shared layout — the whole group in one write when the card was a
    /// member, the one card alone otherwise.
    private func nodeMoved(_ item: Item) {
        let wasGroupDrag = groupDragBase != nil && selectedIDs.contains(item.id)
        groupDragBase = nil
        guard viewChoice == .standard else { return }
        if wasGroupDrag {
            var updates: [String: EPUBMapSharedLayout.Point] = [:]
            for other in items where selectedIDs.contains(other.id) {
                guard let point = positions[other.id] else { continue }
                updates[other.key] = Self.sharedPoint(point)
            }
            EPUBMapSharedLayout.save(updating: updates, community: folder)
        } else {
            persist(item)
        }
    }

    /// The default grid, computed once per reload — the binding's
    /// fallback must not rebuild it per card per body pass.
    @State private var seedCache: [String: CGPoint] = [:]

    private func binding(for item: Item) -> Binding<CGPoint> {
        if viewChoice == .standard {
            return Binding(
                get: { positions[item.id] ?? seedCache[item.id]
                    ?? Self.canvasCenter },
                set: { positions[item.id] = $0 })
        }
        // A computed or saved view: same cards, another arrangement —
        // dragged cards move in this view alone.
        return Binding(
            get: { overlayPositions[item.id] ?? positions[item.id]
                ?? seedCache[item.id] ?? Self.canvasCenter },
            set: { overlayPositions[item.id] = $0 })
    }

    private static var canvasCenter: CGPoint {
        CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
    }

    /// Meters to canvas points: x right stays right, y up flips down.
    private static func canvasPoint(_ point: EPUBMapSharedLayout.Point) -> CGPoint {
        CGPoint(x: canvasCenter.x + point.x * pointsPerMeter,
                y: canvasCenter.y + (1.2 - point.y) * pointsPerMeter)
    }

    private static func sharedPoint(_ point: CGPoint) -> EPUBMapSharedLayout.Point {
        EPUBMapSharedLayout.Point(
            x: Double((point.x - canvasCenter.x) / pointsPerMeter),
            y: Double(1.2 - (point.y - canvasCenter.y) / pointsPerMeter))
    }

    /// The hallway's own seeding — the same wide grid the Vision Pro
    /// lays out, the Set Aside books in their quiet row beneath — so an
    /// untouched venue looks the same here and there. Keep the numbers
    /// in step with EPUBMapView's article grid.
    private static func seeds(for items: [Item]) -> [String: CGPoint] {
        let standing = items.filter { !$0.isSetAside }
        let asides = items.filter { $0.isSetAside }
        let columns = max(1, Int((Double(standing.count) * 7).squareRoot() / 2))
        var result: [String: CGPoint] = [:]
        for (index, item) in standing.enumerated() {
            let column = index % columns
            let row = index / columns
            result[item.id] = canvasPoint(EPUBMapSharedLayout.Point(
                x: (Double(column) - Double(columns - 1) / 2) * 0.28,
                y: 1.55 - Double(row) * 0.18))
        }
        let gridRows = standing.isEmpty ? 0 : (standing.count - 1) / columns + 1
        let asideTop = 1.55 - Double(gridRows) * 0.18 - 0.10
        let asideColumns = max(1, min(asides.count, 5))
        for (index, item) in asides.enumerated() {
            let column = index % asideColumns
            let row = index / asideColumns
            result[item.id] = canvasPoint(EPUBMapSharedLayout.Point(
                x: (Double(column) - Double(asideColumns - 1) / 2) * 0.24,
                y: asideTop - Double(row) * 0.08))
        }
        return result
    }

    private func reload() {
        apply(EPUBMapSharedLayout.load(community: folder))
        refreshSavedNames()
    }

    // MARK: Views — layouts over the same cards

    private func switchView(to choice: MapViewChoice) {
        viewChoice = choice
        clusterCaptions = []
        switch choice {
        case .standard:
            overlayPositions = [:]
        case .topics:
            applyComputed { $0.topics }
        case .authors:
            applyComputed {
                $0.author.components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
            }
        case .people:
            applyComputed { $0.people + $0.entities }
        case .rank:
            applyRankLadder()
        case .saved(let name):
            applySaved(name)
        }
    }

    // MARK: The magnet bar — topics across the top, threads on demand

    /// The magnet bar: twelve topics across the top of the screen, each
    /// an editable field. Clicking one draws its threads down to the
    /// papers it speaks for; Return lays the Magnets view out anew; an
    /// emptied set names itself again from the papers.
    private var magnetBar: some View {
        HStack(spacing: 0) {
            ForEach(magnetNames.indices, id: \.self) { slot in
                TextField("Topic", text: $magnetNames[slot])
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(focusedMagnet == slot
                                     ? Color.accentColor : .secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .focused($focusedMagnet, equals: slot)
                    .onSubmit { magnetsEdited() }
                    .frame(maxWidth: .infinity)
                    .onGeometryChange(for: CGPoint.self, of: {
                        let frame = $0.frame(in: .named("mapPlane"))
                        return CGPoint(x: frame.midX, y: frame.midY)
                    }) { magnetCenters[slot] = $0 }
                    .contextMenu {
                        Button("Arrange") { arrangeColumn(under: slot) }
                    }
                    .help("A magnet's topic — click for its threads; ctrl-click and Arrange to column its papers beneath it")
            }
        }
        .frame(height: Self.magnetBarHeight)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
        .onAppear { ensureMagnetNames() }
    }

    /// The bar's height.
    private static let magnetBarHeight: CGFloat = 30

    /// A magnet chip's measured centre, carried onto the plane — the
    /// canvas point currently standing beneath the chip, refreshed as
    /// the plane scrolls. Nil until the bar has laid out.
    private func magnetAnchor(_ slot: Int) -> CGPoint? {
        guard let center = magnetCenters[slot] else { return nil }
        return CGPoint(x: center.x - canvasOrigin.x,
                       y: center.y - canvasOrigin.y)
    }

    /// The cards holding a thread right now — nil when no threads
    /// stand. While threads do, every card outside this set fades, so
    /// the connected read as the room's subject.
    private var threadConnectedIDs: Set<String>? {
        guard showsMagnetBar else { return nil }
        var connected: Set<String> = []
        var standing = false
        if let slot = focusedMagnet, slot < magnetNames.count {
            standing = true
            let pole = Self.poleWords(magnetNames[slot])
            for item in items where !item.isSetAside && magnetPull(item, pole) > 0 {
                connected.insert(item.id)
            }
        }
        if let lifted = liftedID,
           items.contains(where: { $0.id == lifted && !$0.isSetAside }) {
            standing = true
            connected.insert(lifted)
        }
        return standing ? connected : nil
    }

    /// The threads, drawn over the viewport: a clicked magnet's lines
    /// run down to every paper it speaks for, and a selected (lifted)
    /// card answers upward with a line to every magnet whose topic it
    /// carries — weight and shade by strength, in quiet grey. The bar
    /// and foot bar draw over this, so a line vanishes cleanly under
    /// them rather than crossing.
    private var threadOverlay: some View {
        Canvas { context, size in
            func stroke(_ from: CGPoint, _ to: CGPoint, share: CGFloat) {
                var path = Path()
                path.move(to: from)
                path.addLine(to: to)
                context.stroke(
                    path,
                    with: .color(Color.gray.opacity(0.3 + 0.3 * share)),
                    lineWidth: 0.5 + 1.5 * share)
            }
            if let slot = focusedMagnet, slot < magnetNames.count,
               let anchor = magnetAnchor(slot) {
                let pole = Self.poleWords(magnetNames[slot])
                let pulls: [(at: CGPoint, strength: Int)] = items
                    .filter { !$0.isSetAside }
                    .compactMap { item in
                        let strength = magnetPull(item, pole)
                        guard strength > 0 else { return nil }
                        let at = overlayPositions[item.id] ?? positions[item.id]
                            ?? seedCache[item.id] ?? Self.canvasCenter
                        return (at, strength)
                    }
                let strongest = pulls.map(\.strength).max() ?? 1
                for pull in pulls {
                    stroke(anchor, pull.at,
                           share: CGFloat(pull.strength) / CGFloat(strongest))
                }
            }
            if let lifted = liftedID,
               let item = items.first(where: { $0.id == lifted && !$0.isSetAside }) {
                let at = overlayPositions[item.id] ?? positions[item.id]
                    ?? seedCache[item.id] ?? Self.canvasCenter
                let pulls: [(slot: Int, strength: Int)] = magnetNames.indices
                    .compactMap { slot in
                        let strength = magnetPull(
                            item, Self.poleWords(magnetNames[slot]))
                        guard strength > 0 else { return nil }
                        return (slot, strength)
                    }
                let strongest = pulls.map(\.strength).max() ?? 1
                for pull in pulls {
                    guard let anchor = magnetAnchor(pull.slot) else { continue }
                    stroke(at, anchor,
                           share: CGFloat(pull.strength) / CGFloat(strongest))
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// Where an edited set of magnets is kept for this venue.
    private var magnetsKey: String { "mapMagnets:\(venue)" }

    /// The reader renamed a magnet: keep the set for this venue — or,
    /// if every slot stands empty, forget it so the papers name them
    /// again. Renaming never rearranges the plane; emptied slots just
    /// name themselves anew from the papers.
    private func magnetsEdited() {
        let names = magnetNames.map { $0.trimmingCharacters(in: .whitespaces) }
        if names.allSatisfy(\.isEmpty) {
            UserDefaults.standard.removeObject(forKey: magnetsKey)
            magnetNames = Array(repeating: "", count: 12)
        } else {
            UserDefaults.standard.set(names, forKey: magnetsKey)
        }
        nameMagnets(standing: items.filter { !$0.isSetAside })
    }

    /// The chip's Arrange (ctrl-click): every card the topic speaks for
    /// steps into a column beneath the chip, strongest pull first —
    /// the rest of the plane stands untouched. In the Default view the
    /// column persists to the shared layout like any hand move.
    private func arrangeColumn(under slot: Int) {
        let pole = Self.poleWords(magnetNames[slot])
        guard !pole.isEmpty, let anchor = magnetAnchor(slot) else { return }
        let members = items
            .filter { !$0.isSetAside && magnetPull($0, pole) > 0 }
            .sorted {
                let a = magnetPull($0, pole), b = magnetPull($1, pole)
                return a != b ? a > b : $0.title < $1.title
            }
        guard !members.isEmpty else { return }
        let x = min(max(anchor.x, 90), Self.canvasSize.width - 90)
        let top = min(max(anchor.y + 90, 40), Self.canvasSize.height - 40)
        let step: CGFloat = members.count > 1
            ? min(96, (Self.canvasSize.height - 80 - top) / CGFloat(members.count - 1))
            : 96
        for (index, item) in members.enumerated() {
            let point = CGPoint(x: x, y: top + step * CGFloat(index))
            if viewChoice == .standard {
                positions[item.id] = point
            } else {
                overlayPositions[item.id] = point
            }
        }
        if viewChoice == .standard {
            var updates: [String: EPUBMapSharedLayout.Point] = [:]
            for item in members {
                if let point = positions[item.id] {
                    updates[item.key] = Self.sharedPoint(point)
                }
            }
            EPUBMapSharedLayout.save(updating: updates, community: folder)
        }
    }

    /// The words of a pole, topic, or title — the shared engine's split,
    /// so the Mac's bar and the hallway's row agree to the letter.
    private static func poleWords(_ text: String) -> Set<String> {
        MapTopics.words(text)
    }

    /// The candidate names for the magnet slots: every topic label and
    /// title word, each with the papers it speaks for — so the titles
    /// hold the board up until the AI's topics arrive.
    private func autoMagnetCandidates(_ standing: [Item])
        -> [(name: String, covers: Set<String>)] {
        MapTopics.candidates(standing.map { ($0.id, $0.title, $0.topics) })
    }

    /// The pull: one per topic label the magnet speaks for, and one
    /// for the title — so papers the AI hasn't read yet answer the
    /// magnets too, and sharpen as the extractions land.
    private func magnetPull(_ item: Item, _ pole: Set<String>) -> Int {
        MapTopics.pull(pole: pole, topics: item.topics, title: item.title)
    }

    /// Names the twelve magnets: the reader's kept names take their
    /// slots, then the empty slots fill greedily — each next name the
    /// one that speaks for the most papers still unspoken for, so the
    /// board covers the venue rather than repeating its loudest topic.
    /// No two names mere longer or shorter forms of each other.
    private func nameMagnets(standing: [Item]) {
        let kept = UserDefaults.standard.stringArray(forKey: magnetsKey) ?? []
        for (slot, name) in kept.enumerated() where slot < magnetNames.count {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            if magnetNames[slot].trimmingCharacters(in: .whitespaces).isEmpty {
                magnetNames[slot] = trimmed
            }
        }
        var taken = Set(magnetNames
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty })
        var covered = Set<String>()
        for name in taken {
            let pole = Self.poleWords(name)
            for item in standing where magnetPull(item, pole) > 0 {
                covered.insert(item.id)
            }
        }
        var candidates = autoMagnetCandidates(standing).filter { candidate in
            let key = candidate.name.lowercased()
            return !taken.contains(where: { $0.contains(key) || key.contains($0) })
        }
        for slot in magnetNames.indices
        where magnetNames[slot].trimmingCharacters(in: .whitespaces).isEmpty {
            guard let best = candidates.indices.max(by: {
                let a = candidates[$0], b = candidates[$1]
                let newA = a.covers.subtracting(covered).count
                let newB = b.covers.subtracting(covered).count
                if newA != newB { return newA < newB }
                if a.covers.count != b.covers.count { return a.covers.count < b.covers.count }
                return a.name > b.name
            }) else { break }
            let chosen = candidates.remove(at: best)
            let key = chosen.name.lowercased()
            magnetNames[slot] = chosen.name
            taken.insert(key)
            covered.formUnion(chosen.covers)
            candidates.removeAll {
                let other = $0.name.lowercased()
                return other.contains(key) || key.contains(other)
            }
        }
    }

    /// The bar shown outside the Magnets view names itself from the
    /// papers if the reader hasn't yet — without touching the layout.
    private func ensureMagnetNames() {
        guard magnetNames.allSatisfy({
            $0.trimmingCharacters(in: .whitespaces).isEmpty
        }) else { return }
        nameMagnets(standing: items.filter { !$0.isSetAside })
    }

    /// The magnetic arrangement: every label two or more papers share
    /// becomes a magnet on a ring; a paper with one magnet gathers
    /// around it on a small spiral, one with several stands at their
    /// centre of pull. Papers the facet says nothing about wait in a
    /// row at the foot; Set Aside cards keep their quiet row.
    private func applyComputed(_ facet: (Item) -> [String]) {
        let standing = items.filter { !$0.isSetAside }
        var members: [String: Int] = [:]
        var display: [String: String] = [:]
        func labels(_ item: Item) -> [String] {
            var seen = Set<String>()
            return facet(item).compactMap { raw in
                let label = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard label.count > 1 else { return nil }
                let key = label.lowercased()
                guard seen.insert(key).inserted else { return nil }
                if display[key] == nil { display[key] = label }
                return key
            }
        }
        let byItem = Dictionary(uniqueKeysWithValues: standing.map { ($0.id, labels($0)) })
        for keys in byItem.values {
            for key in keys { members[key, default: 0] += 1 }
        }
        let magnets = members.filter { $0.value >= 2 }
            .sorted {
                $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key
            }
            .prefix(14)

        let center = Self.canvasCenter
        var magnetAt: [String: CGPoint] = [:]
        for (index, magnet) in magnets.enumerated() {
            let angle = Double(index) / Double(max(magnets.count, 1)) * 2 * .pi - .pi / 2
            let radius: Double = magnets.count <= 8 ? 430 : 580
            magnetAt[magnet.key] = CGPoint(
                x: center.x + CGFloat(cos(angle) * radius),
                y: center.y + CGFloat(sin(angle) * radius * 0.62))
        }

        var next: [String: CGPoint] = [:]
        var clusterCount: [String: Int] = [:]
        var unsorted: [Item] = []
        for item in standing {
            let mine = (byItem[item.id] ?? []).filter { magnetAt[$0] != nil }
            if mine.isEmpty {
                unsorted.append(item)
            } else if mine.count == 1, let key = mine.first, let anchor = magnetAt[key] {
                let position = clusterCount[key, default: 0]
                clusterCount[key] = position + 1
                // The golden-angle spiral: each next member a step
                // further out, never two on the same spot.
                let angle = Double(position) * 2.399963
                let radius = 62.0 + Double(position) * 30.0
                next[item.id] = CGPoint(
                    x: anchor.x + CGFloat(cos(angle) * radius),
                    y: anchor.y + CGFloat(sin(angle) * radius * 0.8) + 34)
            } else {
                let anchors = mine.compactMap { magnetAt[$0] }
                let jitter = Self.stableJitter(item.id)
                next[item.id] = CGPoint(
                    x: anchors.map(\.x).reduce(0, +) / CGFloat(anchors.count) + jitter.x,
                    y: anchors.map(\.y).reduce(0, +) / CGFloat(anchors.count) + jitter.y + 34)
            }
        }
        let columns = max(1, min(unsorted.count, 8))
        for (index, item) in unsorted.enumerated() {
            next[item.id] = CGPoint(
                x: center.x + CGFloat(index % columns) * 190
                    - CGFloat(columns - 1) * 95,
                y: Self.canvasSize.height - 240 + CGFloat(index / columns) * 92)
        }
        for (index, item) in items.filter(\.isSetAside).enumerated() {
            next[item.id] = Self.asideFloorPoint(index: index)
        }
        let fit = planeFit(for: next)
        if let fit { next = next.mapValues(fit) }
        overlayPositions = next
        clusterCaptions = magnets.compactMap { magnet in
            magnetAt[magnet.key].map {
                (display[magnet.key] ?? magnet.key, fit?($0) ?? $0)
            }
        }
    }

    /// The Author Rank ladder: the series' most published authors as
    /// rungs, highest first, each paper standing beside the best-ranked
    /// person on its byline. Papers whose authors the dataset has never
    /// seen gather under "New to the series".
    private func applyRankLadder() {
        let standing = items.filter { !$0.isSetAside }
        var groups: [String: (count: Int, items: [Item])] = [:]
        var newcomers: [Item] = []
        for item in standing {
            if let name = item.seriesName, item.seriesCount > 0 {
                var group = groups[name] ?? (item.seriesCount, [])
                group.items.append(item)
                groups[name] = group
            } else {
                newcomers.append(item)
            }
        }
        let ordered = groups.sorted {
            $0.value.count != $1.value.count
                ? $0.value.count > $1.value.count
                : $0.key < $1.key
        }
        // The top rungs stand alone; the long tail shares one row so
        // sixty papers still fit the plane.
        let rungs = ordered.prefix(12)
        let tail = ordered.dropFirst(12).flatMap { $0.value.items }

        var next: [String: CGPoint] = [:]
        var captions: [(label: String, at: CGPoint)] = []
        let labelX: CGFloat = 340
        let firstCard: CGFloat = 680
        let perRow = 9
        var y: CGFloat = 180

        func layRow(_ label: String, _ rowItems: [Item]) {
            captions.append((label, CGPoint(x: labelX, y: y)))
            for (index, item) in rowItems.enumerated() {
                next[item.id] = CGPoint(
                    x: firstCard + CGFloat(index % perRow) * 185,
                    y: y + CGFloat(index / perRow) * 96)
            }
            let subRows = rowItems.isEmpty ? 1 : (rowItems.count - 1) / perRow + 1
            y += CGFloat(subRows) * 96 + 28
        }

        for (name, group) in rungs {
            layRow("\(group.count) × \(name)",
                   group.items.sorted { $0.title < $1.title })
        }
        if !tail.isEmpty {
            layRow("More of the series", tail.sorted { $0.title < $1.title })
        }
        if !newcomers.isEmpty {
            layRow("New to the series", newcomers.sorted { $0.title < $1.title })
        }
        for (index, item) in items.filter(\.isSetAside).enumerated() {
            next[item.id] = Self.asideFloorPoint(index: index)
        }
        if let fit = planeFit(for: next) {
            next = next.mapValues(fit)
            captions = captions.map { ($0.label, fit($0.at)) }
        }
        overlayPositions = next
        clusterCaptions = captions
    }

    /// A small deterministic offset from the id alone — the same on
    /// every device, every run.
    private static func stableJitter(_ id: String) -> CGPoint {
        var hash: UInt64 = 5381
        for byte in id.utf8 { hash = hash &* 33 &+ UInt64(byte) }
        let x = Double(hash % 97) - 48
        let y = Double((hash / 97) % 61) - 30
        return CGPoint(x: x, y: y)
    }

    // MARK: Saved views — kept on this Mac, shareable to the folder

    private func refreshSavedNames() {
        savedLocalNames = EPUBMapViews.local().names(venue: venue)
        savedSharedNames = EPUBMapViews.shared(community: folder).names(venue: venue)
    }

    private func saveCurrentView() {
        let name = saveName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var meters: [String: EPUBMapSharedLayout.Point] = [:]
        for item in items {
            let point = binding(for: item).wrappedValue
            meters[item.key] = Self.sharedPoint(point)
        }
        EPUBMapViews.saveLocal(venue: venue, name: name, positions: meters)
        refreshSavedNames()
        viewChoice = .saved(name)
    }

    private func shareView(_ name: String) {
        guard let positions = EPUBMapViews.local().venues[venue]?[name] else { return }
        EPUBMapViews.share(venue: venue, name: name, positions: positions,
                           community: folder)
        refreshSavedNames()
    }

    private func applySaved(_ name: String) {
        let stored = EPUBMapViews.local().venues[venue]?[name]
            ?? EPUBMapViews.shared(community: folder).venues[venue]?[name]
        guard let stored else { return }
        var next: [String: CGPoint] = [:]
        let seeds = Self.seeds(for: items)
        for item in items {
            next[item.id] = stored[item.key].map { Self.canvasPoint($0) }
                ?? seeds[item.id] ?? Self.canvasCenter
        }
        if let fit = planeFit(for: next) { next = next.mapValues(fit) }
        overlayPositions = next
    }

    /// Every card reachable: an arrangement that leaks past the plane's
    /// edges cannot be scrolled to. Returns the correction — a shrink
    /// only if the arrangement is genuinely larger than the plane, else
    /// the smallest slide that brings every card inside the margin — or
    /// nil when the layout already fits, so captions and cards alike
    /// can ride the same transform.
    private func planeFit(for layout: [String: CGPoint]) -> ((CGPoint) -> CGPoint)? {
        guard !layout.isEmpty else { return nil }
        let margin: CGFloat = 120
        let plane = CGRect(x: margin, y: margin,
                           width: Self.canvasSize.width - 2 * margin,
                           height: Self.canvasSize.height - 2 * margin)
        let xs = layout.values.map(\.x)
        let ys = layout.values.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return nil }
        let scale = min(1,
                        plane.width / max(maxX - minX, 1),
                        plane.height / max(maxY - minY, 1))
        // Bounds after the (possibly identity) shrink about the plane's
        // centre, then the minimal slide back inside.
        func scaled(_ value: CGFloat, about center: CGFloat) -> CGFloat {
            center + (value - center) * scale
        }
        let sMinX = scaled(minX, about: plane.midX)
        let sMaxX = scaled(maxX, about: plane.midX)
        let sMinY = scaled(minY, about: plane.midY)
        let sMaxY = scaled(maxY, about: plane.midY)
        var dx: CGFloat = 0
        var dy: CGFloat = 0
        if sMinX < plane.minX { dx = plane.minX - sMinX }
        else if sMaxX > plane.maxX { dx = plane.maxX - sMaxX }
        if sMinY < plane.minY { dy = plane.minY - sMinY }
        else if sMaxY > plane.maxY { dy = plane.maxY - sMaxY }
        guard scale < 1 || dx != 0 || dy != 0 else { return nil }
        return { point in
            CGPoint(x: scaled(point.x, about: plane.midX) + dx,
                    y: scaled(point.y, about: plane.midY) + dy)
        }
    }

    /// The moved card's place, written on drag end — that one entry
    /// alone, stamped now. Writing every card here would re-stamp this
    /// device's possibly-stale copies as newest and roll back placements
    /// made on an open map elsewhere — cards seen twitching between two
    /// homes are that fight.
    private func persist(_ item: Item) {
        guard let position = positions[item.id] else { return }
        EPUBMapSharedLayout.save(
            updating: [item.key: Self.sharedPoint(position)],
            community: folder)
    }
}

#if os(iOS)
/// Raises the enclosing scroll view's pan gesture to two touches — the
/// Map's convention on the iPad: two fingers move the plane, one finger
/// moves a card. Sits invisibly in the scroll content and walks up to
/// the UIScrollView once it joins the window.
private struct TwoFingerScrollConfigurator: UIViewRepresentable {
    private final class Probe: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            var parent = superview
            while let current = parent {
                if let scroll = current as? UIScrollView {
                    scroll.panGestureRecognizer.minimumNumberOfTouches = 2
                    break
                }
                parent = current.superview
            }
        }
    }

    func makeUIView(context: Context) -> UIView {
        let view = Probe()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
#endif

/// One article on the map: a card that drags and opens on a double
/// click or tap. The pile choices ride the Mac's context menu; on
/// touch they appear on the lifted card, since a long press there
/// must stay free for hold-and-drag.
private struct ProceedingsMapNode: View {
    enum Emphasis { case normal, matched, dimmed }

    let item: ProceedingsMapView.Item
    let emphasis: Emphasis
    let isLifted: Bool
    /// Part of the ⌘A selection: wears the ring, and its drag carries
    /// the whole group through `groupDragged`.
    var isGrouped = false
    @Binding var position: CGPoint
    let bounds: CGSize
    let open: () -> Void
    var abstractFor: (String) -> String = { _ in "" }
    let select: () -> Void
    let togglePin: () -> Void
    let toggleSetAside: () -> Void
    var groupDragged: ((CGSize) -> Void)? = nil
    let moved: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    @State private var dragStart: CGPoint?
    /// The card's place while in hand. Local to the node so a drag
    /// re-renders this card alone; the map's dictionary — whose every
    /// write re-renders the whole plane — learns the place on release.
    @State private var livePosition: CGPoint?

    /// Lifted: clicked, or in hand — a breath of shadow and a nudge up
    /// and left, as though raised off the plane.
    private var lifted: Bool { isLifted || dragStart != nil }

    var body: some View {
        // The context menu is the Mac's alone: on the iPad its long
        // press swallows press-and-hold-then-drag (shrinking the card
        // into the menu preview), so there the pile choices ride the
        // lifted card instead — tap to lift, the buttons appear.
        #if os(macOS)
        card.contextMenu {
            Button(item.isPinned ? "Unpin" : "Pin", action: togglePin)
            Button(item.isSetAside ? "Bring Back" : "Set Aside",
                   action: toggleSetAside)
        }
        #else
        card
        #endif
    }

    /// The card's type, two points under the callout/caption pair it
    /// grew up with — sixty cards on the plane read better smaller.
    private var titleFont: Font {
        #if os(macOS)
        .system(size: 10, weight: .semibold)
        #else
        .system(size: 14, weight: .semibold)
        #endif
    }

    private var authorFont: Font {
        #if os(macOS)
        .system(size: 8)
        #else
        .system(size: 10)
        #endif
    }

    /// The abstract reads as text, not chrome: the app's serif body
    /// face, full black on the light card. The iOS target does not
    /// carry AppFonts; the system serif stands in there.
    private var abstractFont: Font {
        #if os(macOS)
        AppFonts.body(10)
        #else
        .system(size: 12, design: .serif)
        #endif
    }

    /// Standing cards stay small; a lifted card grows to carry its
    /// full title and byline — wider still when it carries the
    /// abstract, so the fine print reads as a paragraph, not a ribbon.
    private func cardWidth(abstract: String) -> CGFloat {
        #if os(macOS)
        lifted ? (abstract.isEmpty ? 168 : 260) : 122
        #else
        lifted ? (abstract.isEmpty ? 168 : 260) : 150
        #endif
    }

    private var card: some View {
        // Read only on the lifted card, live from the index — the
        // standing plane never pays for sixty abstract walks a render.
        let abstract = lifted && !item.isSetAside ? abstractFor(item.id) : ""
        return VStack(alignment: .leading, spacing: 3) {
            // A quiet plane: one line of title per standing card — the
            // full title and the authors unfold on the lifted one.
            Text(item.title)
                .font(titleFont)
                .lineLimit(lifted && !item.isSetAside ? nil : 1)
            if lifted, !item.isSetAside {
                Text(item.author)
                    .font(authorFont)
                    .foregroundStyle(.secondary)
                // The abstract unfolds beneath the byline — capped, so
                // a long one lifts a card, not a wall.
                if !abstract.isEmpty {
                    Text(abstract)
                        .font(abstractFont)
                        // Black on the light card; the dark scheme's
                        // card is near-black, so there it stays white.
                        .foregroundStyle(colorScheme == .dark
                                         ? Color.white : .black)
                        .lineLimit(12)
                        .padding(.top, 3)
                }
            }
            #if !os(macOS)
            if isLifted {
                HStack(spacing: 6) {
                    liftAction(item.isPinned ? "Unpin" : "Pin",
                               action: togglePin)
                    liftAction(item.isSetAside ? "Bring Back" : "Set Aside",
                               action: toggleSetAside)
                }
                .padding(.top, 5)
            }
            #endif
        }
        .padding(.horizontal, lifted ? 10 : 7)
        // A touch taller when lifted: the unfolded card gets air above
        // and below its words, so it reads as raised, not just wider.
        .padding(.vertical, lifted ? 14 : 7)
        .frame(width: cardWidth(abstract: abstract), alignment: .leading)
        // An opaque fill, not a material: sixty cards of live blur —
        // re-blurred each frame under a moving card — drag the drag.
        // In the dark the cards sit a shade above black, so they read
        // as cards on the plane rather than holes in it.
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(colorScheme == .dark
                  ? AnyShapeStyle(Color(white: 0.17))
                  : AnyShapeStyle(.background)))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    emphasis == .matched
                        ? Color.accentColor
                        : isGrouped
                            ? Color.accentColor.opacity(0.85)
                            : item.isPinned
                                ? Color.accentColor.opacity(0.7)
                                : Color.secondary.opacity(0.3),
                    lineWidth: emphasis == .matched || isGrouped ? 2 : 1))
        .overlay(alignment: .topTrailing) {
            if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor)
                    .padding(5)
            }
        }
        .opacity(emphasis == .dimmed ? 0.25 : item.isSetAside ? 0.45 : 1)
        // The whole pane answers the click — a faded or quiet card is
        // as clickable as a bright one.
        .contentShape(Rectangle())
        // One flattened layer, THEN the shadow — unflattened, every
        // text glyph casts its own, which reads wrong and costs a
        // shadow pass per element on every drag frame.
        .compositingGroup()
        .shadow(color: .black.opacity(lifted ? 0.3 : 0),
                radius: lifted ? 5 : 0,
                x: lifted ? 3 : 0, y: lifted ? 4 : 0)
        .offset(x: lifted ? -2 : 0, y: lifted ? -2 : 0)
        .animation(.easeOut(duration: 0.15), value: lifted)
        .position(livePosition ?? position)
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    if dragStart == nil { dragStart = position }
                    guard let start = dragStart else { return }
                    livePosition = CGPoint(
                        x: min(max(start.x + value.translation.width, 90),
                               bounds.width - 90),
                        y: min(max(start.y + value.translation.height, 40),
                               bounds.height - 40))
                    // A grouped card carries the rest of the selection.
                    if isGrouped { groupDragged?(value.translation) }
                }
                .onEnded { _ in
                    if let end = livePosition { position = end }
                    livePosition = nil
                    dragStart = nil
                    moved()
                })
        // Stacked taps: double to open, single to lift. Safe now that
        // the context menu is the Mac's alone — with a menu present,
        // this stack starved the iPad's touch delivery; without one,
        // the composed `exclusively` form starved the single tap.
        .onTapGesture(count: 2, perform: open)
        .onTapGesture(perform: select)
    }

    #if !os(macOS)
    /// A pile choice on the lifted card — small, quiet, gone when the
    /// card sets down.
    private func liftAction(_ title: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption2)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.secondary.opacity(0.15)))
                .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.3)))
        }
        .buttonStyle(.plain)
    }
    #endif
}
