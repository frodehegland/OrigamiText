import CryptoKit
import Foundation
import NaturalLanguage
import Observation
#if canImport(KnowledgeIndex)
import KnowledgeIndex
#endif
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

    /// A letter sent from Author: the conversation it belongs to — the
    /// package identifier its Author document keeps across every letter.
    /// Letters with the same thread are the conversation's letters, each
    /// kept, never one replacing another. nil for every book.
    var letterThread: String? = nil
    /// A fingerprint of the letter's content (everything but the package
    /// record, which Author restamps at every send), so a letter sent
    /// twice arrives once.
    var letterHash: String? = nil

    /// Whether this is a letter from Author rather than a book.
    var isLetter: Bool { letterThread != nil }

    /// A meeting transcript or a letter written to the dialogue profile
    /// (ORIGAMI-DIALOGUE-PROFILE.md): its own date, its series and its
    /// participants. nil for every other book.
    var dialogue: DialogueInfo? = nil

    /// The authors to list the book under: the full list when known,
    /// else the single author of record.
    var authorList: [String] { authors ?? [author] }

    /// The declared venue, empty-checked: nil when the book names none.
    var venue: String? {
        let name = publication?.trimmingCharacters(in: .whitespaces) ?? ""
        return name.isEmpty ? nil : name
    }
}

/// A dialogue publication's own facts (ORIGAMI-DIALOGUE-PROFILE.md §2–3):
/// what it is, when the meeting took place (not when it was exported),
/// the series it belongs to, and who took part.
struct DialogueInfo: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case transcript, letter }

    struct Participant: Codable, Hashable, Sendable {
        /// Local to the publication: what each turn's data-speaker names.
        var id: String
        var name: String
        var role: String?
        var orcid: String?
        var aliases: [String]?

        /// Every name this person goes by here, the full one first.
        var names: [String] { [name] + (aliases ?? []) }
    }

    var kind: Kind
    /// The meeting's (or letter's) date and time, ISO 8601.
    var date: String?
    /// ISO 8601 duration, e.g. "PT1H32M".
    var duration: String?
    var place: String?
    var series: String?
    var number: Int?
    var participants: [Participant] = []

    /// The date as a Date, for ordering a timeline; nil when unreadable.
    var eventDate: Date? {
        guard let date else { return nil }
        if let full = try? Date(date, strategy: .iso8601) { return full }
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = .gmt
        day.dateFormat = "yyyy-MM-dd"
        return day.date(from: String(date.prefix(10)))
    }
}

/// What the Mac found in one meeting, without any model
/// (ORIGAMI-DIALOGUE-PROFILE.md §7): who spoke how much, who answered and
/// mentioned whom, what was linked and cited, the terms used. Every item
/// points at turn ids — the paragraph ids of the transcript — as its
/// evidence. Written beside the EPUBs as
/// `Dialogue/<series>/<meeting>.analysis.json`; every device reads it.
struct MeetingAnalysis: Codable, Sendable {
    /// Raised when the analysis asks something new; older files are
    /// analysed again.
    static let currentVersion = 1

    struct Speaker: Codable, Hashable, Sendable {
        /// The person across meetings (DialoguePeople.key).
        var person: String
        var name: String
        var turns: Int
        var words: Int
        /// Of the meeting's words, 0…1.
        var share: Double
        var firstTurn: String?
    }
    struct Turn: Codable, Hashable, Sendable {
        var id: String
        var person: String
        var words: Int
        /// The section (heading id) the turn falls in.
        var section: String?
    }
    /// `from` answered `to` — the turn after another speaker's — `count` times.
    struct Exchange: Codable, Hashable, Sendable {
        var from: String
        var to: String
        var count: Int
    }
    struct Mention: Codable, Hashable, Sendable {
        var by: String
        var of: String
        var turns: [String]
    }
    struct Link: Codable, Hashable, Sendable {
        /// A web address, a citation key, or an Origami address.
        var target: String
        var kind: String
        var person: String
        var turn: String
    }
    struct Term: Codable, Hashable, Sendable {
        var term: String
        var count: Int
        var people: [String]
        var turns: [String]
    }
    struct Section: Codable, Hashable, Sendable {
        var id: String
        var title: String
        var firstTurn: String?
        var turns: Int
    }

    var version: Int
    /// The record's unpack folder — the meeting's name in the files.
    var meeting: String
    var recordID: String
    var title: String
    var date: String?
    var number: Int?
    var contentHash: String
    var analysed: Date
    var speakers: [Speaker]
    var turns: [Turn]
    var exchanges: [Exchange]
    var mentions: [Mention]
    var links: [Link]
    var terms: [Term]
    var sections: [Section]
}

/// A series as a whole: its meetings in date order, the people across
/// them, how they answer one another, and the terms that recur.
/// `Dialogue/<series>/series.json`.
struct SeriesAnalysis: Codable, Sendable {
    struct Meeting: Codable, Hashable, Sendable {
        var meeting: String
        var recordID: String
        var title: String
        var date: String?
        var number: Int?
        var turns: Int
        var words: Int
        var people: [String]
    }
    struct Person: Codable, Hashable, Sendable {
        var person: String
        var name: String
        var orcid: String?
        var aliases: [String]
        /// The meetings they spoke in, by meeting name.
        var meetings: [String]
        var turns: Int
        var words: Int
        /// Of the series' words, 0…1.
        var share: Double
    }
    struct Term: Codable, Hashable, Sendable {
        var term: String
        var count: Int
        var meetings: [String]
        var people: [String]
    }

    var version: Int
    var series: String
    var kind: DialogueInfo.Kind
    var analysed: Date
    var meetings: [Meeting]
    var people: [Person]
    var exchanges: [MeetingAnalysis.Exchange]
    var terms: [Term]
}

/// Where the dialogue analyses live in the community folder, and how
/// any device reads them.
enum DialogueFiles {
    static let folderName = "Dialogue"

    /// A series' folder name: its name, made safe for a path.
    static func seriesFolder(_ series: String) -> String {
        let safe = series.map { "/:\\?%*|\"<>".contains($0) ? "_" : $0 }
        return String(safe).trimmingCharacters(in: .whitespaces)
    }

    static func seriesURL(_ series: String, in community: URL) -> URL {
        community.appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent(seriesFolder(series), isDirectory: true)
    }

    static func readSeries(_ series: String, in community: URL) -> SeriesAnalysis? {
        read(seriesURL(series, in: community).appendingPathComponent("series.json"))
    }

    static func readMeeting(_ meeting: String, series: String, in community: URL) -> MeetingAnalysis? {
        read(seriesURL(series, in: community).appendingPathComponent(meeting + ".analysis.json"))
    }

    static func read<T: Decodable>(_ url: URL) -> T? {
        var data: Data?
        var failure: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &failure) { at in
            data = try? Data(contentsOf: at)
        }
        guard let data else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(T.self, from: data)
    }

    static func write<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        var failure: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing,
                                       error: &failure) { at in
            try? data.write(to: at, options: .atomic)
        }
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

/// The reader's name ("authorName", Settings on every device) kept the
/// same on all of one person's devices through iCloud's key-value store —
/// the person's own iCloud, never the community folder, which other
/// people may share. Newest change wins: each side carries the time it
/// was set. Lives here because this file is compiled into all three apps.
///
/// Needs the iCloud Key-Value Storage capability on each app target; all
/// three share one bundle identifier, so they share one store. Without the
/// capability the store simply stays local and nothing breaks.
@MainActor
enum ReaderNameSync {
    static let key = "authorName"
    private static let modifiedKey = "authorNameModified"
    private static var lastSeen: String?
    private static var observers: [NSObjectProtocol] = []

    /// Starts keeping the name in step. Call once at launch.
    static func start() {
        guard observers.isEmpty else { return }
        let cloud = NSUbiquitousKeyValueStore.default
        cloud.synchronize()
        lastSeen = UserDefaults.standard.string(forKey: key)
        reconcile()
        observers.append(NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud, queue: .main) { _ in
                MainActor.assumeIsolated { reconcile() }
            })
        // A local edit (Settings writes UserDefaults): stamp it and send it.
        observers.append(NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    let now = UserDefaults.standard.string(forKey: key)
                    guard now != lastSeen else { return }
                    lastSeen = now
                    let stamp = Date().timeIntervalSince1970
                    UserDefaults.standard.set(stamp, forKey: modifiedKey)
                    cloud.set(now ?? "", forKey: key)
                    cloud.set(stamp, forKey: modifiedKey)
                }
            })
    }

    /// Takes iCloud's name when it is newer than this device's, and sends
    /// this device's when it is newer than iCloud's.
    private static func reconcile() {
        let cloud = NSUbiquitousKeyValueStore.default
        let defaults = UserDefaults.standard
        let cloudName = cloud.string(forKey: key)
        let cloudStamp = cloud.double(forKey: modifiedKey)
        let localName = defaults.string(forKey: key)
        let localStamp = defaults.double(forKey: modifiedKey)
        if let cloudName, !cloudName.isEmpty,
           cloudStamp > localStamp || (localName ?? "").isEmpty {
            guard cloudName != localName else { return }
            lastSeen = cloudName
            defaults.set(cloudName, forKey: key)
            defaults.set(cloudStamp, forKey: modifiedKey)
        } else if let localName, !localName.isEmpty, localStamp >= cloudStamp {
            cloud.set(localName, forKey: key)
            cloud.set(max(localStamp, 1), forKey: modifiedKey)
        }
    }
}

/// To Read: a book marked to come back to, and the place to come back
/// to — marked on the phone in a spare minute, read on the Mac, the iPad
/// or the headset later, or the other way round. Not a pin: a pin says
/// "this matters", To Read says "I am not finished here". To Read books
/// lead every list, newest mark first, ahead of the pinned.
///
/// It travels in its own file in the community folder,
/// `origami-to-read.json`, rather than in `origami-standing.json`: builds
/// that predate To Read rewrite the standing file whole whenever they pin,
/// and would drop a member they do not know. Like the standing it is
/// whole-file, last writer wins, keyed by community file name
/// (EPUBRecord.folder) and read coordinated.
nonisolated struct EPUBToRead: Equatable, Sendable {

    struct Item: Codable, Hashable, Sendable {
        /// Locally the record id; in the shared file the community file name.
        var name: String
        /// The paragraph (element id) the reader marked, to land on.
        var at: String?
        /// The paragraph's opening words, so the place can be found again
        /// when an edition renumbers its paragraphs.
        var quote: String?
        var marked: Date
    }

    private struct State: Codable {
        var items: [Item]
        var modified: Date
    }

    static let fileName = "origami-to-read.json"
    private static let defaultsKey = "epubToRead"

    private(set) var items: [Item]
    /// When this device last wrote the shared file — an older file read
    /// back never clobbers a newer local change.
    private(set) var writtenAt: Date = .distantPast

    /// The device's own copy, from UserDefaults.
    static func loadLocal() -> EPUBToRead {
        let data = UserDefaults.standard.data(forKey: defaultsKey)
        let items = data.flatMap { try? JSONDecoder().decode([Item].self, from: $0) } ?? []
        return EPUBToRead(items: items)
    }

    private func saveLocal() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    // MARK: Asking

    func contains(_ id: String) -> Bool { items.contains { $0.name == id } }

    func item(for id: String) -> Item? { items.first { $0.name == id } }

    /// To Read first, newest mark first; then the given order unchanged.
    func first(_ records: [EPUBRecord]) -> [EPUBRecord] {
        let marked = Dictionary(items.map { ($0.name, $0.marked) }, uniquingKeysWith: max)
        let reading = records.filter { marked[$0.id] != nil }
            .sorted { (marked[$0.id] ?? .distantPast) > (marked[$1.id] ?? .distantPast) }
        return reading + records.filter { marked[$0.id] == nil }
    }

    // MARK: Changing — each saves locally; the model then publishes

    mutating func mark(_ id: String, at paragraph: String?, quote: String?) {
        items.removeAll { $0.name == id }
        let opening = quote.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)) }
        items.append(Item(name: id, at: paragraph, quote: opening, marked: .now))
        saveLocal()
    }

    mutating func remove(_ id: String) {
        items.removeAll { $0.name == id }
        saveLocal()
    }

    /// A re-published edition takes over the old copy's mark.
    mutating func move(from old: String, to successor: String) {
        guard let index = items.firstIndex(where: { $0.name == old }) else { return }
        items[index].name = successor
        saveLocal()
    }

    /// Names that arrived before their book become local ids once it has.
    mutating func translate(records: [EPUBRecord]) {
        var idByFolder: [String: String] = [:]
        for record in records { idByFolder[record.folder] = record.id }
        let translated = items.map { item -> Item in
            var item = item
            item.name = idByFolder[item.name] ?? item.name
            return item
        }
        guard translated != items else { return }
        items = translated
        saveLocal()
    }

    // MARK: The shared file

    /// Writes the list to the community folder in community file names.
    /// A name with no record here passes through, so a book this device
    /// does not hold keeps its mark everywhere else.
    mutating func publish(to folder: URL, records: [EPUBRecord]) {
        var folderByID: [String: String] = [:]
        for record in records { folderByID[record.id] = record.folder }
        let shared = items.map { item -> Item in
            var item = item
            item.name = folderByID[item.name] ?? item.name
            return item
        }
        let state = State(items: shared.sorted { $0.marked > $1.marked }, modified: .now)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Fractional seconds: two devices writing within one second must
        // still tell which wrote last.
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(.iso8601.year().month().day()
                .time(includingFractionalSeconds: true).timeZone(separator: .omitted)))
        }
        if let data = try? encoder.encode(state) {
            try? data.write(to: folder.appendingPathComponent(Self.fileName), options: .atomic)
            writtenAt = state.modified
        }
    }

    /// The shared file's items and date, read coordinated — an iCloud
    /// item read plainly serves stale bytes. Call off the main actor.
    static func readShared(from folder: URL) -> (items: [Item], modified: Date)? {
        let url = folder.appendingPathComponent(fileName)
        var data: Data?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [],
                                       error: &coordinationError) { readURL in
            data = try? Data(contentsOf: readURL)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date(text, strategy: .iso8601.year().month().day()
                .time(includingFractionalSeconds: true).timeZone(separator: .omitted)) { return date }
            if let date = try? Date(text, strategy: .iso8601) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Not an ISO 8601 date: \(text)"))
        }
        guard let data, let state = try? decoder.decode(State.self, from: data) else { return nil }
        return (state.items, state.modified)
    }

    /// Adopts a shared list another device wrote more recently than this
    /// one did. Returns whether anything changed.
    @discardableResult
    mutating func adopt(_ shared: (items: [Item], modified: Date), records: [EPUBRecord]) -> Bool {
        guard shared.modified > writtenAt else { return false }
        writtenAt = shared.modified
        let before = items
        items = shared.items
        translate(records: records)
        saveLocal()
        return items != before
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

// MARK: - Spatial notes

/// A spatial note: words a reader left standing in the room, in a place
/// of their own choosing. Made in the Vision Pro's hallway — a blank
/// pad pulled off the wrist and dropped where it belongs — and read on
/// the Mac's flat map at the same place, because both speak the
/// hallway's meters: x right of the room's centre, y up from the floor.
/// Z is the hallway's own depth, which the flat map has no use for and
/// keeps untouched.
///
/// One file per community folder, mirrored locally so a reader with no
/// folder chosen still keeps their notes, and merged per note — the
/// newest writing of a note wins, whichever home holds it. A deleted
/// note leaves a tombstone, so merging with a stale copy from another
/// device cannot bring it back.
nonisolated enum SpatialNotes {

    struct Note: Codable, Identifiable, Hashable {
        var id: String
        /// The journal this note stands with. A note belongs to its
        /// proceedings, not to every room.
        var venue: String
        var text: String
        var x: Double
        var y: Double
        var z: Double
        var created: Date
        var modified: Date
        var deleted: Bool

        init(id: String = UUID().uuidString, venue: String, text: String = "",
             x: Double, y: Double, z: Double,
             created: Date = Date(), modified: Date = Date(),
             deleted: Bool = false) {
            self.id = id
            self.venue = venue
            self.text = text
            self.x = x
            self.y = y
            self.z = z
            self.created = created
            self.modified = modified
            self.deleted = deleted
        }

        /// The first line, for a card that must name itself in a word
        /// or two — an empty note names itself by its blankness.
        var firstLine: String {
            text.split(separator: "\n").first.map(String.init) ?? ""
        }
    }

    struct File: Codable {
        var notes: [String: Note] = [:]
        var modified: Date = .distantPast
    }

    private static let sharedName = "origami-spatial-notes.json"

    /// Stamps to the millisecond. Plain ISO8601 keeps whole seconds
    /// only, and merging is decided by which writing is newer — two
    /// edits in one second must not become a coin toss.
    private static var stamp: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let formatter = stamp
        encoder.dateEncodingStrategy = .custom { date, coder in
            var container = coder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        let fractional = stamp
        let whole = ISO8601DateFormatter()
        decoder.dateDecodingStrategy = .custom { coder in
            let text = try coder.singleValueContainer().decode(String.self)
            // A file written before the millisecond stamp still reads.
            if let date = fractional.date(from: text) { return date }
            if let date = whole.date(from: text) { return date }
            throw DecodingError.dataCorruptedError(
                in: try coder.singleValueContainer(),
                debugDescription: "not a date: \(text)")
        }
        return decoder
    }

    private static var mirrorURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(
            at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent(sharedName)
    }

    /// Every note either home holds, tombstones and all.
    static func all(community folder: URL?) -> [String: Note] {
        let mirror = read(at: mirrorURL)
        let shared = folder.flatMap { url in
            withScope(url) { read(at: $0.appendingPathComponent(sharedName)) }
        }
        return merged(mirror, shared).notes
    }

    /// The notes standing in one journal's room, oldest first — the
    /// order a reader wrote them in. Ties break on the id, so the order
    /// is the same on every device rather than the dictionary's whim.
    static func notes(venue: String, community folder: URL?) -> [Note] {
        all(community: folder).values
            .filter { !$0.deleted && $0.venue == venue }
            .sorted {
                $0.created == $1.created ? $0.id < $1.id : $0.created < $1.created
            }
    }

    /// Writes one note to both homes, stamped now. Every other note
    /// stands — the other journals', the other devices'.
    static func save(_ note: Note, community folder: URL?) {
        var stamped = note
        stamped.modified = Date()
        write(stamped, community: folder)
    }

    /// The note goes, and says so: a tombstone keeps its id with the
    /// deletion's own stamp, which merging respects.
    static func delete(_ note: Note, community folder: URL?) {
        var stone = note
        stone.deleted = true
        stone.text = ""
        stone.modified = Date()
        write(stone, community: folder)
    }

    private static func write(_ note: Note, community folder: URL?) {
        var file = File(notes: all(community: folder))
        file.notes[note.id] = note
        file.modified = note.modified
        guard let data = try? encoder.encode(file) else { return }
        try? data.write(to: mirrorURL, options: .atomic)
        if let folder {
            withScope(folder) {
                try? data.write(to: $0.appendingPathComponent(sharedName),
                                options: .atomic)
            }
        }
    }

    private static func merged(_ a: File?, _ b: File?) -> File {
        switch (a, b) {
        case (nil, nil): return File()
        case let (one?, nil): return one
        case let (nil, one?): return one
        case let (l?, r?):
            var notes = l.notes
            for (id, note) in r.notes {
                if let held = notes[id], held.modified >= note.modified { continue }
                notes[id] = note
            }
            return File(notes: notes, modified: max(l.modified, r.modified))
        }
    }

    private static func read(at url: URL) -> File? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(File.self, from: data)
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

    /// The shared views through a COORDINATED read — a plain read of an
    /// iCloud item serves stale bytes forever on iOS and visionOS. It may
    /// wait on the provider, so call it off the main actor (the hallway
    /// does). (29 Sep 2026.)
    static func sharedCoordinated(community folder: URL?) -> File {
        guard let folder else { return File() }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        var file: File?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(
            readingItemAt: folder.appendingPathComponent(sharedName),
            options: [], error: &coordinationError) { readURL in
            file = read(at: readURL)
        }
        return file ?? File()
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

/// One spatial note on the flat map: the hallway's paper, drawn where
/// the headset left it. Drag it and the place travels back; double-click
/// to read and write the words. Deliberately unlike an article card —
/// a note is a reader's own hand, not a published thing.
struct SpatialNoteCard: View {
    let note: SpatialNotes.Note
    let at: CGPoint
    let open: () -> Void
    let moved: (CGPoint) -> Void

    @State private var drag: CGSize = .zero

    private var place: CGPoint {
        CGPoint(x: at.x + drag.width, y: at.y + drag.height)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if note.text.isEmpty {
                Text("Note")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            } else {
                Text(note.text)
                    .font(.callout)
                    .lineLimit(6)
                    .multilineTextAlignment(.leading)
            }
        }
        .padding(10)
        .frame(width: 150, height: 184, alignment: .topLeading)
        .background {
            // Paper, in the ember the app keeps for a reader's own
            // marks — it must never be mistaken for a paper's card.
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(red: 0.98, green: 0.92, blue: 0.70))
                .shadow(radius: drag == .zero ? 2 : 8)
        }
        .overlay(alignment: .bottomLeading) {
            Text(note.created, format: .dateTime.year().month(.abbreviated).day())
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(10)
        }
        .foregroundStyle(.black)
        .position(place)
        .gesture(
            DragGesture()
                .onChanged { drag = $0.translation }
                .onEnded { value in
                    drag = .zero
                    moved(CGPoint(x: at.x + value.translation.width,
                                  y: at.y + value.translation.height))
                })
        .onTapGesture(count: 2, perform: open)
        .accessibilityLabel(note.text.isEmpty ? "Empty note" : note.text)
        .accessibilityHint("Double-click to write; drag to move")
    }
}

/// A spatial note's words, on the Mac: the same note the headset made,
/// written with a keyboard instead of a voice.
struct SpatialNoteEditor: View {
    let note: SpatialNotes.Note
    let write: (String) -> Void
    let remove: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Spatial Note")
                .font(.headline)
            Text("Made \(note.created, format: .dateTime.year().month().day().hour().minute()) — standing in the room at \(note.x, specifier: "%.2f") m across, \(note.y, specifier: "%.2f") m up.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $draft)
                .font(.body)
                .frame(minWidth: 380, minHeight: 200)
            HStack {
                Button("Delete", role: .destructive) {
                    remove()
                    dismiss()
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Done") {
                    write(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .onAppear { draft = note.text }
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

    /// The spatial notes standing in this venue's room — made in the
    /// Vision Pro's hallway, carried here by the community file. Drawn
    /// at the same meters the cards are, so a note left beside a paper
    /// is beside that paper here too.
    @State private var notes: [SpatialNotes.Note] = []
    /// The note opened for reading and writing.
    @State private var editingNote: SpatialNotes.Note?

    /// The clicked card, lifted off the plane until clicked again or
    /// another takes its place. Views are only layouts: switching one
    /// never touches this, so the selection survives the crossing.
    @State private var liftedID: String?
    /// The card in hand and where it is this frame — read only by the
    /// threads, so a drag redraws the lines, not the whole plane.
    @State private var liveDrag = MapLiveDrag()

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
                        moved: { nodeMoved(item) },
                        liveMoved: { point in
                            liveDrag.id = point == nil ? nil : item.id
                            if let point { liveDrag.point = point }
                        })
                    // While threads stand, the cards they touch are the
                    // subject — everything unthreaded steps back.
                    .opacity(connected == nil || connected!.contains(item.id)
                             ? 1 : 0.25)
                    // The lifted card rises above its neighbours — its
                    // grown frame must never swallow a click meant for
                    // the card visually beside it.
                    .zIndex(liftedID == item.id ? 1 : 0)
                }
                // The hallway's spatial notes, standing on the same
                // plane: read them, move them, write in them. A note
                // made here reaches the headset the same way.
                ForEach(notes) { note in
                    SpatialNoteCard(
                        note: note,
                        at: Self.canvasPoint(
                            EPUBMapSharedLayout.Point(x: note.x, y: note.y)),
                        open: { editingNote = note },
                        moved: { point in
                            let place = Self.sharedPoint(point)
                            var moved = note
                            moved.x = place.x
                            moved.y = place.y
                            SpatialNotes.save(moved, community: folder)
                            reload()
                        })
                    .zIndex(2)
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
        .sheet(item: $editingNote) { note in
            SpatialNoteEditor(note: note) { written in
                var kept = note
                kept.text = written
                SpatialNotes.save(kept, community: folder)
                reload()
            } remove: {
                SpatialNotes.delete(note, community: folder)
                reload()
            }
        }
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
        notes = SpatialNotes.notes(venue: venue, community: folder)
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
        MapLiveThreads(liveDrag: liveDrag) { context, size, live in
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
                        let at = live(item.id) ?? overlayPositions[item.id] ?? positions[item.id]
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
                let at = live(item.id) ?? overlayPositions[item.id] ?? positions[item.id]
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

/// A small keyword under a map card's title — a cited work's standing
/// on the References map (Retracted, Corrected, Open Access…).
struct MapCardMark: Hashable {
    enum Tone: Hashable { case alarm, caution, quiet, positive, info, good }
    var text: String
    var tone: Tone
    /// The longer account, for the help tag.
    var detail: String = ""
    /// Drawn as a pill (the trust keywords), else plain text.
    var pill: Bool = false
}

/// One article on the map: a card that drags and opens on a double
/// click or tap. The pile choices ride the Mac's context menu; on
/// touch they appear on the lifted card, since a long press there
/// must stay free for hold-and-drag.
struct ProceedingsMapNode: View {
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
    /// The card's place while in hand, each frame; nil on release.
    var liveMoved: (CGPoint?) -> Void = { _ in }
    /// Keywords standing under the title, lifted or not — the References
    /// map's retractions and the like. Empty on the journal Map.
    var marks: [MapCardMark] = []
    /// The Mac's context menu in place of the pile choices, when the
    /// plane is not a shelf (the References map).
    var menu: (() -> AnyView)? = nil
    /// Title lines on a standing (closed) card — one on the journal Map,
    /// two on the References map, where titles are the whole story.
    var standingTitleLines = 1
    /// A lifted card reads larger, with air between its lines — the
    /// References map, where the opened card is read, not scanned.
    var roomyWhenLifted = false
    /// The card moves up and down only — its place across the plane is
    /// its year on the References map, not the reader's to change.
    var verticalOnly = false

    /// How much larger a roomy lifted card's type stands.
    private var liftBoost: CGFloat { roomyWhenLifted && lifted ? 2 : 0 }
    private var liftLineSpacing: CGFloat { roomyWhenLifted && lifted ? 3 : 0 }

    @Environment(\.colorScheme) private var colorScheme

    @State private var dragStart: CGPoint?
    /// When the card was last dragged: a press that moved the card is a
    /// move, never the second click of an open.
    @State private var lastDragged: Date?
    /// The previous click, for telling a double-click from two singles.
    @State private var lastTap: Date?
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
            if let menu {
                menu()
            } else {
                Button(item.isPinned ? "Unpin" : "Pin", action: togglePin)
                Button(item.isSetAside ? "Bring Back" : "Set Aside",
                       action: toggleSetAside)
            }
        }
        #else
        card
        #endif
    }

    /// The card's type, two points under the callout/caption pair it
    /// grew up with — sixty cards on the plane read better smaller.
    private var titleFont: Font {
        #if os(macOS)
        .system(size: 10 + liftBoost, weight: .semibold)
        #else
        .system(size: 14 + liftBoost, weight: .semibold)
        #endif
    }

    private var authorFont: Font {
        #if os(macOS)
        .system(size: 8 + liftBoost)
        #else
        .system(size: 10 + liftBoost)
        #endif
    }

    /// The abstract reads as text, not chrome: the app's serif body
    /// face, full black on the light card. The iOS target does not
    /// carry AppFonts; the system serif stands in there.
    private var abstractFont: Font {
        #if os(macOS)
        AppFonts.body(10 + liftBoost)
        #else
        .system(size: 12 + liftBoost, design: .serif)
        #endif
    }

    /// Standing cards stay small; a lifted card grows to carry its
    /// full title and byline — wider still when it carries the
    /// abstract, so the fine print reads as a paragraph, not a ribbon.
    private func cardWidth(abstract: String) -> CGFloat {
        #if os(macOS)
        lifted ? (abstract.isEmpty ? (roomyWhenLifted ? 210 : 168)
                                   : (roomyWhenLifted ? 330 : 260)) : 159
        #else
        lifted ? (abstract.isEmpty ? 168 : 260) : 195
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
                .lineSpacing(liftLineSpacing)
                .lineLimit(lifted && !item.isSetAside ? nil : standingTitleLines)
            if !marks.isEmpty {
                markLine
            }
            if lifted, !item.isSetAside {
                Text(item.author)
                    .font(authorFont)
                    .lineSpacing(liftLineSpacing)
                    .foregroundStyle(.secondary)
                // The abstract unfolds beneath the byline — capped, so
                // a long one lifts a card, not a wall.
                if !abstract.isEmpty {
                    Text(abstract)
                        .font(abstractFont)
                        .lineSpacing(liftLineSpacing)
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
                        x: verticalOnly ? start.x
                            : min(max(start.x + value.translation.width, 90),
                                  bounds.width - 90),
                        y: min(max(start.y + value.translation.height, 40),
                               bounds.height - 40))
                    liveMoved(livePosition)
                    // A grouped card carries the rest of the selection.
                    if isGrouped { groupDragged?(value.translation) }
                }
                .onEnded { _ in
                    if let end = livePosition { position = end }
                    livePosition = nil
                    dragStart = nil
                    lastDragged = .now
                    liveMoved(nil)
                    moved()
                })
        // Stacked taps: double to open, single to lift. Safe now that
        // the context menu is the Mac's alone — with a menu present,
        // this stack starved the iPad's touch delivery; without one,
        // the composed `exclusively` form starved the single tap.
        // One tap recogniser, counting clicks itself: a tap fires only on
        // a release that did not move the card, so pressing, holding and
        // dragging can never open it — the double-tap recogniser fired on
        // the second press going down, before any drag could begin.
        .onTapGesture {
            let now = Date.now
            let recentlyDragged = lastDragged.map { now.timeIntervalSince($0) < 0.5 } ?? false
            if let last = lastTap, now.timeIntervalSince(last) < Self.doubleClickInterval,
               dragStart == nil, !recentlyDragged {
                lastTap = nil
                open()
            } else {
                lastTap = now
                select()
            }
        }
    }

    /// The keywords in a row, the grave ones in colour.
    private var markLine: some View {
        HStack(spacing: 5) {
            ForEach(marks, id: \.self) { mark in
                let color = Self.color(for: mark.tone)
                Text(mark.text)
                    .font(.system(size: 8, weight: mark.pill ? .semibold : .medium))
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .padding(.horizontal, mark.pill ? 5 : 0)
                    .padding(.vertical, mark.pill ? 1 : 0)
                    .background {
                        if mark.pill { Capsule().fill(color.opacity(0.12)) }
                    }
                    .overlay {
                        if mark.pill { Capsule().strokeBorder(color.opacity(0.45), lineWidth: 0.6) }
                    }
                    .help(mark.detail)
            }
        }
    }

    static func color(for tone: MapCardMark.Tone) -> Color {
        switch tone {
        case .alarm: .red
        case .caution: .orange
        case .positive: .accentColor
        case .info: .blue
        case .good: .green
        case .quiet: .secondary
        }
    }

    private static var doubleClickInterval: TimeInterval {
        #if os(macOS)
        NSEvent.doubleClickInterval
        #else
        0.35
        #endif
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

/// The card in hand on the proceedings map and its place this frame.
@Observable
final class MapLiveDrag {
    var id: String?
    var point: CGPoint = .zero
}

/// The map's threads as their own view: it alone reads the card in
/// hand, so a drag redraws the lines each frame and nothing else.
struct MapLiveThreads: View {
    let liveDrag: MapLiveDrag
    let draw: (inout GraphicsContext, CGSize, (String) -> CGPoint?) -> Void

    var body: some View {
        let id = liveDrag.id
        let point = liveDrag.point
        Canvas { context, size in
            draw(&context, size) { $0 == id ? point : nil }
        }
    }
}

// MARK: - Bound volumes, read as their articles

/// A journal, proceedings or collection bound into one EPUB, read as its
/// pieces: the binding record's works and its front and back matter
/// (visual-meta.json `document.binding`), each one a reading of its own.
/// `read` answers nil for a book that declares no binding — it is read
/// whole, as before.
nonisolated struct BoundVolume: Hashable, Sendable {
    enum Role: String, Hashable, Sendable { case front, work, back }

    /// What a piece is to its reader. Declared by the book where it says
    /// (the binding's `role`, or the section's `epub:type`), else read off
    /// the piece itself (`classify`), and always open to the reader's own
    /// correction.
    enum Kind: String, Codable, CaseIterable, Hashable, Sendable {
        /// A contribution: what the volume is for.
        case article
        /// Opening pages: title page, dedication, acknowledgements,
        /// foreword, preface, introduction, welcome, how to read.
        case front
        /// A part's own title page — a heading, not a reading.
        case part
        /// Many voices in one piece: a graffiti wall, competition entries.
        case collection
        /// Closing pages: afterword, postscript, contributors, timeline,
        /// symposium records, gallery, colophon.
        case back
        case appendix

        var zone: Zone {
            switch self {
            case .front: .opening
            case .back, .appendix: .appendices
            case .article, .part, .collection: .articles
            }
        }

        /// The word a reader chooses it by.
        var title: String {
            switch self {
            case .article: "Article"
            case .front: "Opening"
            case .part: "Part Title"
            case .collection: "Collection"
            case .back: "Closing"
            case .appendix: "Appendix"
            }
        }
    }

    /// Where a piece stands: the opening pages, the articles, or the
    /// appendices and records after them.
    enum Zone: String, CaseIterable, Hashable, Sendable {
        case opening, articles, appendices

        var title: String {
            switch self {
            case .opening: "Opening"
            case .articles: "Articles"
            case .appendices: "Appendices & Records"
            }
        }
    }

    struct Article: Identifiable, Hashable, Sendable {
        /// The work's permanent id (`urn:uuid:…`); a matter piece's href.
        let id: String
        let title: String
        /// Its authors — the binding's, or the name standing on the line
        /// under its title when the binding gave none.
        var authors: [String]
        /// Where the binding put it: a work, or front or back matter.
        let role: Role
        /// What it is (see `Kind`), and the small word its card wears —
        /// FOREWORD, TIMELINE, APPENDIX — when there is one.
        var kind: Kind = .article
        var label: String?
        /// Whether the book itself said what it is.
        var declared = false
        /// A collection's number of voices.
        var voices = 0
        /// Its content document, folder-relative — "content/work-4-preface.html".
        let file: String
        /// The heading it begins at in `file`; nil when it is the whole file.
        let anchor: String?
        /// The concept, reference and note ids its pages use, as the
        /// binding lists them — empty when it lists none.
        let concepts: [String]
        let references: [String]
        let abstract: String?
        let keywords: [String]

        var isWork: Bool { kind == .article || kind == .collection }
        var zone: Zone { kind.zone }
        var byline: String { authors.joined(separator: ", ") }
    }

    /// The series a volume belongs to (binding `series`).
    struct Series: Hashable, Sendable {
        let id: String
        let name: String
        let volume: Int?
    }

    /// "book", "journal", "proceedings" — as the binding names it.
    let kind: String
    /// Every piece in reading order: front matter, the works, back matter
    /// as the spine has them.
    var articles: [Article]
    var series: Series? = nil

    /// The articles proper — contributions and collections.
    var works: [Article] { articles.filter(\.isWork) }

    /// The pieces standing in one zone, in reading order.
    func pieces(in zone: Zone) -> [Article] { articles.filter { $0.zone == zone } }

    /// The volume with the reader's corrections laid over the book's own
    /// reading of itself (`[article id: kind]`).
    func correcting(_ kinds: [String: Kind]) -> BoundVolume {
        guard !kinds.isEmpty else { return self }
        var copy = self
        for index in copy.articles.indices {
            if let kind = kinds[copy.articles[index].id], kind != copy.articles[index].kind {
                copy.articles[index].kind = kind
                copy.articles[index].label = nil
            }
        }
        return copy
    }

    /// The volume's binding, from its unpacked package.
    static func read(inUnpackedFolder folder: URL) -> BoundVolume? {
        guard let data = OrigamiEPUBImporter.recordData(
                inUnpackedFolder: folder, properties: "origami:visual-meta",
                fileName: "visual-meta.json"),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let document = root["document"] as? [String: Any],
              let binding = document["binding"] as? [String: Any],
              let works = binding["works"] as? [[String: Any]], !works.isEmpty
        else { return nil }

        // Hrefs in the record are relative to the package document.
        let container = (try? String(contentsOf: folder.appendingPathComponent("META-INF/container.xml"),
                                     encoding: .utf8)) ?? ""
        let opfPath = container.range(of: #"full-path="([^"]+)""#, options: .regularExpression)
            .map { String(container[$0].dropFirst("full-path=\"".count).dropLast()) } ?? "package.opf"
        let opfDirectory = (opfPath as NSString).deletingLastPathComponent
        let opf = (try? String(contentsOf: folder.appendingPathComponent(opfPath), encoding: .utf8)) ?? ""
        let volumeTitle = opf.range(of: #"<dc:title[^>]*>[^<]*"#, options: .regularExpression)
            .map { String(opf[$0]).replacingOccurrences(of: #"<dc:title[^>]*>"#, with: "",
                                                        options: .regularExpression) } ?? ""

        func text(_ raw: Any?) -> String? {
            let value = OrigamiEPUBImporter.multilingualText(raw)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (value?.isEmpty ?? true) ? nil : value
        }
        func place(_ href: String) -> (file: String, anchor: String?) {
            let parts = href.split(separator: "#", maxSplits: 1).map(String.init)
            let file = OrigamiEPUBImporter.joinedPath(opfDirectory, parts.first ?? "")
            return (file, parts.count > 1 ? parts[1] : nil)
        }
        func ids(_ resources: [String: Any]?, _ key: String) -> [String] {
            resources?[key] as? [String] ?? []
        }
        /// A declared role, as EPUB's structural vocabulary names it.
        func declaredKind(_ raw: Any?) -> (Kind, String?)? {
            guard let role = (raw as? String)?.lowercased(), !role.isEmpty else { return nil }
            return Self.declaredKinds[role].map { ($0, role == "chapter" || role == "article" ? nil : role) }
        }

        var pieces: [Article] = []
        for work in works {
            guard let href = work["href"] as? String else { continue }
            let at = place(href)
            let resources = work["resources"] as? [String: Any]
            let authors = (work["authors"] as? [[String: Any]] ?? []).compactMap { text($0["name"]) }
            var piece = Article(
                id: work["id"] as? String ?? href,
                title: text(work["title"]) ?? "Untitled",
                authors: authors, role: .work, file: at.file, anchor: at.anchor,
                concepts: ids(resources, "concepts"), references: ids(resources, "references"),
                abstract: text(work["abstract"]),
                keywords: (work["keywords"] as? [Any] ?? []).compactMap { text($0) })
            if let (kind, label) = declaredKind(work["role"]) {
                piece.kind = kind; piece.label = label; piece.declared = true
            }
            pieces.append(piece)
        }
        for matter in binding["matter"] as? [[String: Any]] ?? [] {
            guard let href = matter["href"] as? String else { continue }
            let at = place(href)
            let given = matter["role"] as? String
            var piece = Article(
                id: href, title: text(matter["title"]) ?? "Untitled", authors: [],
                role: given == "front" ? .front : .back,
                file: at.file, anchor: at.anchor, concepts: [], references: [],
                abstract: nil, keywords: [])
            // "front" and "back" say only where it stands; a richer role
            // ("foreword", "appendix") says what it is.
            if let given, given != "front", given != "back", let (kind, label) = declaredKind(given) {
                piece.kind = kind; piece.label = label; piece.declared = true
            }
            pieces.append(piece)
        }

        // Reading order is the spine's.
        let spine = OrigamiEPUBImporter.spine(inUnpackedFolder: folder)?.chapters ?? []
        let position = Dictionary(spine.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        var ordered = pieces.enumerated().sorted {
            let a = position[$0.element.file] ?? Int.max, b = position[$1.element.file] ?? Int.max
            return a != b ? a < b : $0.offset < $1.offset
        }.map(\.element)

        // What each piece is, where the book did not say.
        var shapes: [String: PieceShape] = [:]
        for piece in ordered where shapes[piece.file] == nil {
            let html = (try? String(contentsOf: folder.appendingPathComponent(piece.file), encoding: .utf8)) ?? ""
            shapes[piece.file] = PieceShape(html: html)
        }
        var series: Series?
        if let raw = binding["series"] as? [String: Any], let id = raw["id"] as? String {
            series = Series(id: id, name: text(raw["name"]) ?? "",
                            volume: (raw["volume"] as? Int) ?? Int(raw["volume"] as? String ?? ""))
        }
        classify(&ordered, shapes: shapes, volumeTitle: volumeTitle, seriesName: series?.name)
        return BoundVolume(kind: binding["kind"] as? String ?? "book", articles: ordered, series: series)
    }

    /// EPUB's structural vocabulary (and the binding's own words), as kinds.
    static let declaredKinds: [String: Kind] = [
        "article": .article, "chapter": .article, "work": .article,
        "titlepage": .front, "halftitlepage": .front, "dedication": .front, "epigraph": .front,
        "acknowledgments": .front, "acknowledgements": .front, "foreword": .front,
        "preface": .front, "introduction": .front, "prologue": .front, "frontmatter": .front,
        "part": .part, "collection": .collection,
        "afterword": .back, "epilogue": .back, "conclusion": .back, "contributors": .back,
        "colophon": .back, "backmatter": .back, "timeline": .back, "transcript": .back,
        "appendix": .appendix,
    ]

    /// What can be read off a piece's own pages: its length, its headings,
    /// and the first line under its title (where a byline stands).
    struct PieceShape: Sendable {
        let words: Int
        let headings: [String]
        let paragraphs: [String]

        init(html: String) {
            func plain(_ fragment: String) -> String {
                // Tags go without a space: a word split by an inline link
                // ("W<a>asi</a>lko") reads whole again.
                fragment.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                    .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&nbsp;", with: " ")
                    .replacingOccurrences(of: "&#160;", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            func matches(_ pattern: String) -> [String] {
                guard let expression = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
                else { return [] }
                let ns = html as NSString
                return expression.matches(in: html, range: NSRange(location: 0, length: ns.length))
                    .map { plain(ns.substring(with: $0.range(at: 1))) }
            }
            let body = html.replacingOccurrences(of: "(?s)<head\\b.*?</head>", with: "", options: .regularExpression)
            words = body.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                .split(whereSeparator: \.isWhitespace).count
            headings = matches("<h[1-6]\\b[^>]*>(.*?)</h[1-6]>")
            paragraphs = Array(matches("<p\\b[^>]*>(.*?)</p>").filter { !$0.isEmpty }.prefix(6))
        }
    }

    /// Opening and closing pages, by the words their titles begin with.
    private static let openingWords = [
        "foreword", "preface", "introduction", "welcome", "dedication", "acknowledg",
        "how to read", "a symposium in writing", "article summaries", "editor’s note", "editor's note",
    ]
    private static let closingWords = [
        "afterword", "postscript", "in closing", "colophon", "contributor", "gallery",
        "graffiti wall", "conversations from", "open monday", "history of text timeline", "timeline",
    ]
    /// Words that mark a record of an event when nobody signs it.
    private static let recordWords = ["symposium", "transcript", "proceedings of"]

    /// Reads each piece the book did not describe: appendices by name,
    /// part titles by their brevity, opening and closing pages by the words
    /// their titles begin with, a byline found on the line under a title,
    /// many voices by their many named headings — and once the closing
    /// pages have begun after the articles, whatever follows is closing too.
    static func classify(_ pieces: inout [Article], shapes: [String: PieceShape],
                         volumeTitle: String, seriesName: String?) {
        let volume = volumeTitle.lowercased().trimmingCharacters(in: .whitespaces)
        let series = (seriesName ?? "").lowercased().trimmingCharacters(in: .whitespaces)
        var articleSeen = false
        var closingBegun = false
        for index in pieces.indices {
            var piece = pieces[index]
            defer {
                if piece.kind == .article || piece.kind == .collection { articleSeen = true }
                if articleSeen, piece.kind.zone == .appendices { closingBegun = true }
                pieces[index] = piece
            }
            if piece.declared { continue }
            let title = piece.title.lowercased()
                .trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
            let shape = shapes[piece.file]
            let signed = !piece.authors.isEmpty
            func set(_ kind: Kind, _ label: String? = nil) { piece.kind = kind; piece.label = label }

            if title.hasPrefix("appendix") { set(.appendix, "appendix"); continue }
            if !signed, (shape?.words ?? 0) <= 15 { set(.part); continue }
            // The volume's own title page: its title, the series' name, or
            // the series' name and its number ("… Vol IV", "… |||").
            let numbered = !series.isEmpty && title.hasPrefix(series)
                && ["vol", "|", "volume"].contains(where: {
                    title.dropFirst(series.count).trimmingCharacters(in: .whitespaces).hasPrefix($0) })
            if !signed, !title.isEmpty, title == volume || title == series || numbered {
                set(closingBegun ? .back : .front, "title page"); continue
            }
            if let word = openingWords.first(where: { title.hasPrefix($0) }) {
                set(closingBegun ? .back : .front, Self.labelWord(word)); continue
            }
            if let word = closingWords.first(where: { title.hasPrefix($0) }) {
                set(.back, Self.labelWord(word)); continue
            }
            if !signed, recordWords.contains(where: { title.contains($0) }) { set(.back, "record"); continue }
            if !signed, let shape {
                // The name under the title the binding missed.
                let firstLine = shape.paragraphs.first { $0.lowercased() != piece.title.lowercased() } ?? ""
                if let names = Self.byline(firstLine) {
                    piece.authors = names
                    set(closingBegun ? .back : .article); continue
                }
                if shape.headings.count >= 8 {
                    piece.voices = shape.headings.count - 1
                    set(closingBegun ? .back : .collection, "collection"); continue
                }
            }
            if closingBegun { set(.back); continue }
            if !signed, !articleSeen { set(.front); continue }
            set(.article)
        }
    }

    private static func labelWord(_ word: String) -> String {
        switch word {
        case "acknowledg": "acknowledgements"
        case "contributor": "contributors"
        case "graffiti wall", "conversations from", "open monday": "record"
        case "history of text timeline": "timeline"
        case "editor’s note", "editor's note": "editor’s note"
        case "a symposium in writing", "how to read", "article summaries": "opening"
        default: word
        }
    }

    /// A line that is nothing but names — "Peter J. Wasilko", "Ann Bessemans
    /// & María Pérez Mena" — split into them; nil for a line of prose.
    static func byline(_ line: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (4...90).contains(trimmed.count), !trimmed.hasSuffix(":") else { return nil }
        // A sentence ends in a full stop; a name may only end in an initial's.
        if trimmed.hasSuffix("."), (trimmed.split(separator: " ").last?.count ?? 0) > 2 { return nil }
        let connectors: Set<String> = ["and", "&", "de", "van", "von", "der", "da", "del", "di", "la", "le", "with"]
        let tokens = trimmed.replacingOccurrences(of: ",", with: " , ").split(separator: " ").map(String.init)
        let words = tokens.filter { $0 != "," }
        guard (2...14).contains(words.count) else { return nil }
        for token in words where !connectors.contains(token.lowercased()) {
            guard let first = token.first, first.isUppercase else { return nil }
        }
        let names = trimmed
            .replacingOccurrences(of: " and ", with: ",").replacingOccurrences(of: "&", with: ",")
            .replacingOccurrences(of: " with ", with: ",")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        // Every name at least two words: "Peter J. Wasilko", not "Notes".
        guard !names.isEmpty, names.allSatisfy({ $0.split(separator: " ").count >= 2 }) else { return nil }
        return names
    }

    // MARK: An article as a document of its own

    /// The id an article reads under: its volume's, then the article's.
    static func articleDocID(volume: String, article: String) -> String {
        volume + articleMarker + article
    }

    /// The volume and article an article id names; nil for any other id.
    static func split(articleDocID id: String) -> (volume: String, article: String)? {
        guard let range = id.range(of: articleMarker) else { return nil }
        return (String(id[..<range.lowerBound]), String(id[range.upperBound...]))
    }

    private static let articleMarker = "#article="

    /// The article cut out of the volume's structured document: its own
    /// paragraphs (its file's, from its heading up to the next piece's),
    /// its title and authors, and the concepts and references its pages
    /// use. Everything else rides along from the volume.
    func document(for article: Article, in volume: LiquidDoc) -> LiquidDoc {
        let body = volume.body ?? []
        let prefix = article.file + "#"
        let inFile = body.indices.filter { body[$0].id.hasPrefix(prefix) }
        let start = article.anchor.flatMap { anchor in
            inFile.first { body[$0].id == prefix + anchor }
        } ?? inFile.first
        // The next piece beginning in the same file ends this one.
        let otherStarts = Set(articles.filter { $0.id != article.id && $0.file == article.file }
            .compactMap { $0.anchor.map { prefix + $0 } })
        var slice: [LiquidDoc.Paragraph] = []
        if let start {
            for index in inFile where index >= start {
                if index > start, otherStarts.contains(body[index].id) { break }
                slice.append(body[index])
            }
        }

        var doc = LiquidDoc(format: volume.format,
                            id: Self.articleDocID(volume: volume.id, article: article.id),
                            title: article.title,
                            author: article.authors.isEmpty ? volume.author : article.byline,
                            created: volume.created, body: slice,
                            links: [], wraps: nil, fileURL: volume.fileURL)
        doc.authors = article.authors
        doc.documentType = volume.documentType
        doc.date = volume.date
        doc.language = volume.language
        doc.publication = volume.title
        doc.journal = volume.journal
        doc.abstract = article.abstract
        doc.keywords = article.keywords
        doc.assets = volume.assets
        doc.tables = volume.tables
        doc.concepts = article.concepts.isEmpty ? volume.concepts
            : volume.concepts.filter { Set(article.concepts).contains($0.id) }
        // The works it cites, as the binding lists them — or, where the
        // binding lists none, as its own paragraphs cite them.
        var cited = Set(article.references)
        if cited.isEmpty {
            for paragraph in slice {
                var rest = paragraph.text[...]
                while let open = rest.range(of: "[cite:") {
                    rest = rest[open.upperBound...]
                    guard let close = rest.firstIndex(of: "]") else { break }
                    cited.insert(String(rest[..<close]))
                    rest = rest[close...]
                }
            }
        }
        doc.references = volume.references.filter { cited.contains($0.id) }
        return doc
    }
}


// MARK: - A series' articles, ready for the assistant

/// Every article of every volume in one series (binding `series.id`), each
/// with what an assistant needs to talk about it at once: its title,
/// authors and volume, a gist (its abstract, else its opening), the names
/// of its concepts, and a sentence embedding of its opening made on the
/// device (NaturalLanguage) — so "which articles are like this one?" is
/// answered from the whole series, in an instant, before any model speaks.
nonisolated struct SeriesIndex: Codable, Sendable {
    struct Entry: Identifiable, Hashable, Codable, Sendable {
        /// The id the article reads under in its volume's room.
        let id: String
        let volumeID: String
        let volumeTitle: String
        let volumeNumber: Int?
        let title: String
        let authors: [String]
        let kind: BoundVolume.Kind
        let gist: String
        var concepts: Set<String>
        var vector: [Double]

        var byline: String { authors.joined(separator: ", ") }
        /// "Vol 4" — or the volume's title where it has no number.
        var volumeName: String { volumeNumber.map { "Vol \($0)" } ?? volumeTitle }
    }

    /// One volume of the series, as the index is built from it.
    struct Volume: Sendable {
        let recordID: String
        let title: String
        let bound: BoundVolume
        let document: LiquidDoc
    }

    let seriesID: String
    let name: String
    /// Which volumes, with how many articles each — an index made from
    /// other volumes is made again.
    let signature: String
    let entries: [Entry]
    /// What every article of the series shares — in a series about the
    /// future of text, that it is about the future of text. Taken off each
    /// vector before comparing, so an article is matched by what is its
    /// own rather than by the theme they all have.
    var mean: [Double] = []
    /// Which embedding made the vectors ("bge-small" or "apple"), so a
    /// question is embedded the same way.
    var model = "apple"

    /// Which volumes, and every one of their pieces as the reader now sees
    /// it — id, title, authors, kind, abstract and length — so a
    /// re-exported volume or a corrected piece is indexed again.
    static func signature(of volumes: [Volume]) -> String {
        let described = volumes.map { volume in
            volume.recordID + "{" + volume.bound.articles.map { piece in
                [piece.id, piece.title, piece.byline, piece.kind.rawValue, piece.abstract ?? ""]
                    .joined(separator: "\u{1F}")
            }.joined(separator: "\u{1E}") + "#\((volume.document.body ?? []).count)}"
        }.sorted().joined(separator: "|")
        return SHA256.hash(data: Data(described.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Indexes the articles (and collections) of every volume given:
    /// Knowledge Space's own embedding model (bge-small) where the build
    /// carries it, Apple's sentence embedding otherwise.
    static func build(seriesID: String, name: String, volumes: [Volume]) async -> SeriesIndex {
        struct Draft { var entry: Entry; let text: String }
        var drafts: [Draft] = []
        for volume in volumes {
            for article in volume.bound.works {
                let doc = volume.bound.document(for: article, in: volume.document)
                let body = (doc.body ?? []).filter { $0.heading == nil }.map(\.text)
                    .filter { $0.count > 40 && $0 != article.byline }
                let opening = body.joined(separator: " ")
                    .replacingOccurrences(of: #"\[cite:[^\]]*\]"#, with: "", options: .regularExpression)
                let gist: String
                if let abstract = article.abstract, !abstract.isEmpty {
                    gist = abstract
                } else {
                    gist = opening.split(separator: " ").prefix(70).joined(separator: " ")
                }
                let entry = Entry(
                    id: BoundVolume.articleDocID(volume: volume.recordID, article: article.id),
                    volumeID: volume.recordID, volumeTitle: volume.title,
                    volumeNumber: volume.bound.series?.volume,
                    title: article.title, authors: article.authors, kind: article.kind,
                    gist: gist, concepts: Set(doc.concepts.map { $0.name.lowercased() }), vector: [])
                drafts.append(Draft(entry: entry,
                                    text: article.title + ". " + String(opening.prefix(2400))))
            }
        }

        // The vectors.
        var model = "apple"
        var vectors: [[Double]]? = nil
        #if canImport(KnowledgeIndex)
        if let bge = try? BGEEmbedder() {
            var made: [[Double]] = []
            let texts = drafts.map(\.text)
            for start in stride(from: 0, to: texts.count, by: BGEEmbedder.batchSize) {
                let batch = Array(texts[start..<min(start + BGEEmbedder.batchSize, texts.count)])
                guard let embedded = try? await bge.embed(batch) else { made = []; break }
                made += embedded.map { $0.map(Double.init) }
            }
            if made.count == drafts.count { vectors = made; model = "bge-small" }
        }
        #endif
        if vectors == nil {
            let embedding = NLEmbedding.sentenceEmbedding(for: .english)
            vectors = drafts.map { Self.appleVector($0.text, embedding: embedding) }
        }
        for index in drafts.indices { drafts[index].entry.vector = vectors?[index] ?? [] }

        // A concept most articles share says nothing about any one of them.
        var counts: [String: Int] = [:]
        for draft in drafts { for concept in draft.entry.concepts { counts[concept, default: 0] += 1 } }
        let common = Set(counts.filter { Double($0.value) > Double(drafts.count) * 0.15 }.keys)

        // Centre the vectors on the series' own mean.
        let width = drafts.first(where: { !$0.entry.vector.isEmpty })?.entry.vector.count ?? 0
        var mean = [Double](repeating: 0, count: width)
        let vectored = drafts.filter { $0.entry.vector.count == width && width > 0 }
        for draft in vectored { for i in 0..<width { mean[i] += draft.entry.vector[i] } }
        if !vectored.isEmpty { mean = mean.map { $0 / Double(vectored.count) } }
        let entries = drafts.map { draft -> Entry in
            var entry = draft.entry
            entry.vector = Self.centre(entry.vector, on: mean)
            entry.concepts.subtract(common)
            return entry
        }
        return SeriesIndex(seriesID: seriesID, name: name, signature: signature(of: volumes),
                           entries: entries, mean: mean, model: model)
    }

    /// Apple's sentence embedding of a text: the mean of the vectors of its
    /// first dozen sentences, normalised.
    static func appleVector(_ text: String, embedding: NLEmbedding?) -> [Double] {
        guard let embedding else { return [] }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var sentences: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if sentence.count > 8 { sentences.append(sentence) }
            return sentences.count < 12
        }
        var sum = [Double](repeating: 0, count: embedding.dimension)
        var counted = 0
        for sentence in sentences {
            guard let v = embedding.vector(for: sentence) else { continue }
            for i in v.indices { sum[i] += v[i] }
            counted += 1
        }
        guard counted > 0 else { return [] }
        let length = sqrt(sum.reduce(0) { $0 + $1 * $1 })
        return length > 0 ? sum.map { $0 / length } : []
    }

    /// A question as the index's own model embeds it, centred like the
    /// articles. bge reads a search better with its retrieval instruction.
    func questionVector(_ question: String) async -> [Double] {
        var vector: [Double] = []
        #if canImport(KnowledgeIndex)
        if model == "bge-small", let bge = try? BGEEmbedder(),
           let embedded = try? await bge.embed(["Represent this sentence for searching relevant passages: " + question]),
           let first = embedded.first {
            vector = first.map(Double.init)
        }
        #endif
        if vector.isEmpty {
            vector = Self.appleVector(question, embedding: NLEmbedding.sentenceEmbedding(for: .english))
        }
        return Self.centre(vector, on: mean)
    }

    /// A vector less the series' mean, normalised again.
    static func centre(_ vector: [Double], on mean: [Double]) -> [Double] {
        guard vector.count == mean.count, !vector.isEmpty else { return vector }
        let moved = zip(vector, mean).map { $0 - $1 }
        let length = sqrt(moved.reduce(0) { $0 + $1 * $1 })
        return length > 0 ? moved.map { $0 / length } : moved
    }

    // MARK: Kept between visits

    /// Where a series' index is kept on this device.
    static func cacheURL(seriesID: String) -> URL {
        let safe = seriesID.replacingOccurrences(of: "[^A-Za-z0-9-]", with: "_", options: .regularExpression)
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SeriesIndex", isDirectory: true)
            .appendingPathComponent(safe + ".json")
    }

    static func cached(seriesID: String, signature: String) -> SeriesIndex? {
        guard let data = try? Data(contentsOf: cacheURL(seriesID: seriesID)),
              let index = try? JSONDecoder().decode(SeriesIndex.self, from: data),
              index.signature == signature else { return nil }
        return index
    }

    func save() {
        let url = Self.cacheURL(seriesID: seriesID)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: url, options: .atomic) }
    }

    /// Whether Knowledge Space's own embedding model (bge-small, through
    /// LiquidKit's KnowledgeIndex) is in this build.
    static var bgeLinked: Bool {
        #if canImport(KnowledgeIndex)
        return true
        #else
        return false
        #endif
    }

    private static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        return zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }

    /// How alike two articles are: mostly what their openings say, partly
    /// the concepts they share by name.
    func likeness(_ a: Entry, _ b: Entry) -> Double {
        let shared = a.concepts.intersection(b.concepts).count
        let union = a.concepts.union(b.concepts).count
        let concepts = union == 0 ? 0 : Double(shared) / Double(union)
        return 0.85 * Self.cosine(a.vector, b.vector) + 0.15 * concepts
    }

    func entry(_ id: String) -> Entry? { entries.first { $0.id == id } }

    /// The articles most like this one, across every volume of the series.
    func similar(to id: String, limit: Int = 8) -> [Entry] {
        guard let anchor = entry(id) else { return [] }
        return entries.filter { $0.id != id }
            .map { ($0, likeness(anchor, $0)) }
            .sorted { $0.1 > $1.1 }
            .prefix(limit).map(\.0)
    }

    /// The articles a question is most about: an article it names by title
    /// first, then the nearest by meaning.
    func search(_ question: String, limit: Int = 10) async -> [Entry] {
        let asked = question.lowercased()
        let named = entries.filter { $0.title.count >= 12 && asked.contains($0.title.lowercased()) }
        let probe = Entry(id: "", volumeID: "", volumeTitle: "", volumeNumber: nil, title: question,
                          authors: [], kind: .article, gist: "",
                          concepts: Set(entries.flatMap(\.concepts).filter { asked.contains($0) }),
                          vector: await questionVector(question))
        let near = entries.map { ($0, likeness(probe, $0)) }.sorted { $0.1 > $1.1 }.map(\.0)
        var seen = Set<String>()
        return (named + near).filter { seen.insert($0.id).inserted }.prefix(limit).map { $0 }
    }

    /// The articles as a model reads them: numbered, so its answer can
    /// name them back ("[3]").
    static func briefing(_ entries: [Entry]) -> String {
        entries.enumerated().map { index, entry in
            let by = entry.byline.isEmpty ? "" : " — \(entry.byline)"
            return "[\(index + 1)] \(entry.title)\(by) (\(entry.volumeName)): \(entry.gist)"
        }.joined(separator: "\n")
    }
}
