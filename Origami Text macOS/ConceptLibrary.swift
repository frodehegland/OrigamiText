import Foundation

// The Defined Concepts library: one folder of plain JSON files, readable
// and writable by any program on any system. Nothing here needs Apple's
// frameworks beyond Foundation — no archives, no CloudKit, no iCloud
// API. The folder may live anywhere; putting it in a synced folder
// (iCloud Drive, Dropbox, a git repository) is what shares it between
// devices and apps. The layout and record shape are Author's
// ConceptLibrary, so Author reads and writes the same files; Origami
// Text's additions live in a folder of their own beside them.
//
//   <library>/
//     library.json              who made the library, format version
//     concepts/<id>.json        the concept: an append-only event log (Author's shape)
//     extensions/<id>.json      Origami's additions: labels, sense, kind, relations,
//                               matches, flags, occurrences — another event log
//     index.json                a cache Author keeps; never the truth, ignored here
//     layouts/<space>.json      positions per space (see ORIGAMI-CONCEPTS-FORMAT.md)
//
// A concept is never edited in place: every change is an event appended
// to its log, and two copies of a log merge by the union of their
// events, so two devices working offline lose nothing. Ordering is by
// `sequence` (one past the highest the writer had seen), then date, then
// id — never by clock alone.

// MARK: - The concept record (Author's shape)

nonisolated enum ConceptEventKind: String, Codable, Sendable {
    /// A definition: the first, or a revision.
    case version
    /// Another document rests on this definition unchanged.
    case used
    case deleted
    case restored
    /// Folded into another concept; `mergedInto` names the survivor.
    case merged
}

nonisolated struct ConceptEvent: Codable, Identifiable, Sendable, Hashable {
    var id: String
    var kind: ConceptEventKind
    /// The revision this one was made from; nil for the first and for
    /// lifecycle events.
    var parentID: String?
    var created: Date
    /// The device that wrote it, for a readable history.
    var device: String
    /// The ordering key, immune to clock skew.
    var sequence: Int
    // `version` events only.
    var term: String?
    var definition: String?
    var tags: [String]?
    var urls: [String]?
    var citationIDs: [String]?
    /// The document the definition was written in.
    var originDocumentName: String?
    /// For `merged`.
    var mergedInto: String?

    init(id: String = UUID().uuidString, kind: ConceptEventKind, parentID: String? = nil,
         created: Date = Date(), device: String, sequence: Int,
         term: String? = nil, definition: String? = nil, tags: [String]? = nil,
         urls: [String]? = nil, citationIDs: [String]? = nil,
         originDocumentName: String? = nil, mergedInto: String? = nil) {
        self.id = id
        self.kind = kind
        self.parentID = parentID
        self.created = created
        self.device = device
        self.sequence = sequence
        self.term = term
        self.definition = definition
        self.tags = tags
        self.urls = urls
        self.citationIDs = citationIDs
        self.originDocumentName = originDocumentName
        self.mergedInto = mergedInto
    }
}

/// A defined concept outside any one document: its id, every term it has
/// been called (normalised), and its log.
nonisolated struct ConceptRecord: Codable, Identifiable, Sendable, Hashable {
    let id: String
    private(set) var terms: [String]
    private(set) var events: [ConceptEvent]

    init(id: String = UUID().uuidString, events: [ConceptEvent]) {
        self.id = id
        self.events = Self.sorted(events)
        self.terms = Self.terms(in: self.events)
    }

    enum CodingKeys: String, CodingKey { case id, terms, events }

    /// Tolerant: `terms` is recomputed, `events` may be missing, and any
    /// unknown key is ignored.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        let events = try container.decodeIfPresent([ConceptEvent].self, forKey: .events) ?? []
        self.init(id: id, events: events)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(terms, forKey: .terms)
        try container.encode(events, forKey: .events)
    }

    static func sorted(_ events: [ConceptEvent]) -> [ConceptEvent] {
        events.sorted { left, right in
            if left.sequence != right.sequence { return left.sequence < right.sequence }
            if left.created != right.created { return left.created < right.created }
            return left.id < right.id
        }
    }

    private static func terms(in events: [ConceptEvent]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for event in events {
            guard let term = event.term else { continue }
            let normalised = ConceptTerm.normalise(term)
            guard !normalised.isEmpty, seen.insert(normalised).inserted else { continue }
            result.append(normalised)
        }
        return result
    }

    /// The definition in force: the newest `version`.
    var head: ConceptEvent? { events.last { $0.kind == .version } }
    var versions: [ConceptEvent] { events.filter { $0.kind == .version } }
    var headTerm: String { head?.term ?? "" }
    var headDefinition: String { head?.definition ?? "" }

    /// Every document this concept lives in, by Author's document name,
    /// in order of first appearance.
    var documents: [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for event in events where event.kind == .version || event.kind == .used {
            guard let document = event.originDocumentName, !document.isEmpty else { continue }
            if seen.insert(document).inserted { result.append(document) }
        }
        return result
    }

    private var lifecycle: ConceptEvent? { events.last { $0.kind != .version && $0.kind != .used } }

    /// Deleted or merged away, unless a definition came after.
    var isDeleted: Bool {
        guard let lifecycle, lifecycle.kind != .restored else { return false }
        guard let head else { return true }
        return head.sequence < lifecycle.sequence
    }

    var mergedInto: String? {
        guard let lifecycle, lifecycle.kind == .merged else { return nil }
        return lifecycle.mergedInto
    }

    var updated: Date { events.last?.created ?? Date(timeIntervalSince1970: 0) }
    var nextSequence: Int { (events.map(\.sequence).max() ?? 0) + 1 }

    func appending(_ event: ConceptEvent) -> ConceptRecord {
        ConceptRecord(id: id, events: events + [event])
    }

    /// The union of two copies, by event id — how a conflict resolves.
    func merging(_ other: ConceptRecord) -> ConceptRecord {
        var byID: [String: ConceptEvent] = [:]
        for event in events + other.events { byID[event.id] = event }
        return ConceptRecord(id: id, events: Array(byID.values))
    }
}

// MARK: - Origami's additions

/// What Origami Text records about a concept beyond Author's log, as its
/// own log beside it: labels with language, the sense, a kind, explicit
/// relations, matches to outside authorities, flags, and occurrences by
/// stable document identity. One flat event with optional fields, so a
/// reader that does not know a kind keeps and re-emits it.
nonisolated struct ConceptExtensionEvent: Codable, Identifiable, Sendable, Hashable {
    /// `label`, `sense`, `kind`, `relation`, `match`, `flag`, `occurrence`,
    /// `definitionSource`, `note` — open: unknown kinds are kept.
    var kind: String
    var id: String
    var created: Date
    var device: String
    /// The app that wrote it ("Origami Text", "Liquid"…).
    var app: String?
    var sequence: Int
    /// The text of a label, sense, kind, flag name, source or note.
    var value: String?
    /// BCP 47 language of a label or sense.
    var lang: String?
    /// For `label`: `pref`, `alt` or `hidden`.
    var labelKind: String?
    /// For `flag` (on/off) and for `label`/`relation`/`match` removals.
    var on: Bool?
    /// For `relation`: `broader`, `narrower`, `related`, `partOf`, `opposes`… and the target concept id.
    var relation: String?
    var to: String?
    /// For `match`: `exact`, `close`, `broad`; the scheme ("wikidata", "ccs", "orcid"); its identifier; a URL.
    var matchKind: String?
    var scheme: String?
    var identifier: String?
    var url: String?
    /// For `occurrence`: the document's stable id (Origami address, DOI,
    /// EPUB identifier), its title, the paragraph, the words used.
    var document: String?
    var title: String?
    var fragment: String?
    var form: String?

    init(kind: String, id: String = UUID().uuidString, created: Date = Date(), device: String,
         app: String? = "Origami Text", sequence: Int) {
        self.kind = kind
        self.id = id
        self.created = created
        self.device = device
        self.app = app
        self.sequence = sequence
    }
}

nonisolated struct ConceptExtensionRecord: Codable, Identifiable, Sendable, Hashable {
    let id: String
    private(set) var events: [ConceptExtensionEvent]

    init(id: String, events: [ConceptExtensionEvent] = []) {
        self.id = id
        self.events = events.sorted { left, right in
            if left.sequence != right.sequence { return left.sequence < right.sequence }
            if left.created != right.created { return left.created < right.created }
            return left.id < right.id
        }
    }

    enum CodingKeys: String, CodingKey { case id, events }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try container.decode(String.self, forKey: .id),
                  events: try container.decodeIfPresent([ConceptExtensionEvent].self, forKey: .events) ?? [])
    }

    var nextSequence: Int { (events.map(\.sequence).max() ?? 0) + 1 }

    func appending(_ event: ConceptExtensionEvent) -> ConceptExtensionRecord {
        ConceptExtensionRecord(id: id, events: events + [event])
    }

    func merging(_ other: ConceptExtensionRecord) -> ConceptExtensionRecord {
        var byID: [String: ConceptExtensionEvent] = [:]
        for event in events + other.events { byID[event.id] = event }
        return ConceptExtensionRecord(id: id, events: Array(byID.values))
    }

    // Derived state — the latest word on each thing.

    struct Label: Hashable, Sendable { var value: String; var lang: String?; var kind: String }
    struct Relation: Hashable, Sendable { var kind: String; var to: String }
    struct Match: Hashable, Sendable { var kind: String; var scheme: String; var identifier: String; var url: String? }
    struct Occurrence: Hashable, Sendable {
        var document: String; var title: String?; var fragment: String?; var form: String?; var created: Date
    }

    /// Labels in force: each added once, removed by a later event with `on == false`.
    var labels: [Label] {
        var result: [Label] = []
        for event in events where event.kind == "label" {
            guard let value = event.value, !value.isEmpty else { continue }
            let label = Label(value: value, lang: event.lang, kind: event.labelKind ?? "alt")
            if event.on == false { result.removeAll { $0.value == label.value && $0.lang == label.lang } }
            else if !result.contains(label) { result.append(label) }
        }
        return result
    }

    var sense: String? { events.last { $0.kind == "sense" }?.value.flatMap { $0.isEmpty ? nil : $0 } }
    var conceptKind: String? { events.last { $0.kind == "kind" }?.value.flatMap { $0.isEmpty ? nil : $0 } }
    var definitionSource: String? { events.last { $0.kind == "definitionSource" }?.value }

    var relations: [Relation] {
        var result: [Relation] = []
        for event in events where event.kind == "relation" {
            guard let relation = event.relation, let to = event.to else { continue }
            let item = Relation(kind: relation, to: to)
            if event.on == false { result.removeAll { $0 == item } }
            else if !result.contains(item) { result.append(item) }
        }
        return result
    }

    var matches: [Match] {
        var result: [Match] = []
        for event in events where event.kind == "match" {
            guard let scheme = event.scheme, let identifier = event.identifier else { continue }
            let item = Match(kind: event.matchKind ?? "exact", scheme: scheme, identifier: identifier, url: event.url)
            if event.on == false { result.removeAll { $0.scheme == item.scheme && $0.identifier == item.identifier } }
            else if !result.contains(where: { $0.scheme == item.scheme && $0.identifier == item.identifier }) {
                result.append(item)
            }
        }
        return result
    }

    /// Flags in force, by name ("tracked", "liked", "hidden").
    var flags: Set<String> {
        var result: Set<String> = []
        for event in events where event.kind == "flag" {
            guard let name = event.value else { continue }
            if event.on == false { result.remove(name) } else { result.insert(name) }
        }
        return result
    }

    /// Where the concept appears, one entry per document and fragment.
    var occurrences: [Occurrence] {
        var result: [Occurrence] = []
        for event in events where event.kind == "occurrence" {
            guard let document = event.document, !document.isEmpty else { continue }
            if result.contains(where: { $0.document == document && $0.fragment == event.fragment }) { continue }
            result.append(Occurrence(document: document, title: event.title, fragment: event.fragment,
                                     form: event.form, created: event.created))
        }
        return result
    }
}

// MARK: - Terms

/// Term normalisation — the one rule for "is this the same concept?" and
/// for finding a term in text: case- and diacritic-folded, quotes and
/// dashes straightened, whitespace collapsed, never stemmed, matched on
/// whole words.
nonisolated enum ConceptTerm {
    static func normalise(_ term: String) -> String {
        let flattened = term
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
            .replacingOccurrences(of: "\u{2013}", with: "-")
            .replacingOccurrences(of: "\u{2014}", with: "-")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return flattened
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// The text as comparable words: folded, split on anything that is not
    /// a letter or digit.
    static func words(in text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        return normalise(text)
            .split { character in !character.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) } }
            .map(String.init)
    }

    /// Whether `term` appears in `text` as whole words.
    static func text(_ text: String, contains term: String) -> Bool {
        let needle = normalise(term)
        guard !needle.isEmpty, !text.isEmpty else { return false }
        var start = text.startIndex
        while start < text.endIndex,
              let found = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive],
                                     range: start..<text.endIndex) {
            if isWholeWord(found, in: text) { return true }
            start = found.upperBound
        }
        return false
    }

    private static func isWholeWord(_ range: Range<String.Index>, in text: String) -> Bool {
        if range.lowerBound > text.startIndex {
            let before = text[text.index(before: range.lowerBound)]
            if before.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) { return false }
        }
        if range.upperBound < text.endIndex {
            let after = text[range.upperBound]
            if after.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) { return false }
        }
        return true
    }
}

// MARK: - Layouts: where concepts stand in one space

/// `layouts/<space>.json` — positions and connections of concepts in one
/// space: a document's Map in Author, a room in Origami Text, a scene in
/// Liquid. Positions never live on the concept itself. Units are the
/// space's own; `z` may be absent. Unknown concept ids are tolerated.
nonisolated struct ConceptLayout: Codable, Sendable, Equatable {
    struct Space: Codable, Sendable, Equatable {
        var id: String
        var name: String?
        /// `authorMap`, `conceptSpace`, `liquid`…
        var kind: String?
        var app: String?
    }
    struct Position: Codable, Sendable, Equatable {
        var id: String
        var x: Double
        var y: Double
        var z: Double?
    }
    struct Connection: Codable, Sendable, Equatable {
        var from: String
        var to: String
    }

    var space: Space
    var modified: Date?
    var positions: [Position]
    var connections: [Connection]

    init(space: Space, positions: [Position] = [], connections: [Connection] = []) {
        self.space = space
        self.modified = Date()
        self.positions = positions
        self.connections = connections
    }

    enum CodingKeys: String, CodingKey { case space, modified, positions, connections }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        space = try container.decode(Space.self, forKey: .space)
        modified = try container.decodeIfPresent(Date.self, forKey: .modified)
        positions = try container.decodeIfPresent([Position].self, forKey: .positions) ?? []
        connections = try container.decodeIfPresent([Connection].self, forKey: .connections) ?? []
    }
}

// MARK: - A concept as handed in

/// What a caller gives the library when defining or importing: the
/// content of one definition, from any source.
nonisolated struct ConceptDraft: Sendable, Equatable {
    var term: String
    var definition = ""
    var tags: [String] = []
    var urls: [String] = []
    var citationIDs: [String] = []
    var date = Date()
    /// Author's document name, when it came from a document.
    var originDocumentName: String?
    /// The document's stable id (Origami address, DOI, EPUB identifier) and
    /// title, for an occurrence Origami can open.
    var documentID: String?
    var documentTitle: String?
    /// The id the source gave the concept (a glossary entry's UUID, an
    /// EPUB's `concepts[].id`) — matched first, before the term.
    var sourceID: String?
    /// Where the definition came from: "user", "document", "ai".
    var definitionSource: String?

    var normalisedTerm: String { ConceptTerm.normalise(term) }

    /// Author's categories that are machinery, not concepts — never
    /// published to a library.
    static let unpublishedTags: Set<String> = ["section", "citation", "heading", "reference", "lens"]

    var isPublishable: Bool {
        !normalisedTerm.isEmpty && !tags.contains { Self.unpublishedTags.contains($0.lowercased()) }
    }
}

// MARK: - The store: a folder of files

nonisolated struct ConceptLibraryStore: Sendable {
    static let formatIdentifier = "origami-concepts/1.0"

    let root: URL
    var conceptsFolder: URL { root.appendingPathComponent("concepts", isDirectory: true) }
    var extensionsFolder: URL { root.appendingPathComponent("extensions", isDirectory: true) }
    var layoutsFolder: URL { root.appendingPathComponent("layouts", isDirectory: true) }
    var libraryFile: URL { root.appendingPathComponent("library.json") }

    init(root: URL) { self.root = root }

    // Coding — readable on purpose, dates as ISO 8601, keys sorted, as
    // Author writes them.
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// Tolerant of every date form a concept file may carry: ISO 8601 with
    /// or without fractions, or seconds since 2001 (Author's glossary files).
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let seconds = try? container.decode(Double.self) {
                return Date(timeIntervalSinceReferenceDate: seconds)
            }
            let text = try container.decode(String.self)
            if let date = Self.isoFractional.date(from: text) ?? Self.isoPlain.date(from: text) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a date: \(text)")
        }
        return decoder
    }

    private static let isoPlain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    func conceptURL(_ id: String) -> URL { conceptsFolder.appendingPathComponent("\(id).json") }
    func extensionURL(_ id: String) -> URL { extensionsFolder.appendingPathComponent("\(id).json") }

    // MARK: Coordination (optional)

    /// File coordination keeps two apps writing one file at the same time
    /// honest on Apple systems, where iCloud Drive relies on it. It is a
    /// courtesy to the sync layer, not part of the format: on another
    /// system the body simply runs.
    private func coordinatedRead<T>(_ url: URL, _ body: (URL) -> T?) -> T? {
        #if canImport(Darwin)
        var result: T?
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { url in
            result = body(url)
        }
        return result
        #else
        return body(url)
        #endif
    }

    private func coordinatedWrite(_ url: URL, _ body: (URL) throws -> Void) throws {
        #if canImport(Darwin)
        var thrown: Error?
        var error: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &error) { url in
            do { try body(url) } catch { thrown = error }
        }
        if let error { throw error }
        if let thrown { throw thrown }
        #else
        try body(url)
        #endif
    }

    // MARK: Reading

    /// Every concept file, deleted ones included; the extensions beside them.
    func readAll() -> (records: [ConceptRecord], extensions: [String: ConceptExtensionRecord]) {
        let decoder = Self.decoder()
        var records: [ConceptRecord] = []
        var extensions: [String: ConceptExtensionRecord] = [:]
        _ = coordinatedRead(conceptsFolder) { folder -> Bool in
            for url in Self.jsonFiles(in: folder) {
                guard let data = try? Data(contentsOf: url),
                      let record = try? decoder.decode(ConceptRecord.self, from: data) else { continue }
                records.append(record)
            }
            return true
        }
        _ = coordinatedRead(extensionsFolder) { folder -> Bool in
            for url in Self.jsonFiles(in: folder) {
                guard let data = try? Data(contentsOf: url),
                      let record = try? decoder.decode(ConceptExtensionRecord.self, from: data) else { continue }
                extensions[record.id] = record
            }
            return true
        }
        return (records, extensions)
    }

    private static func jsonFiles(in folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                       options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.pathExtension == "json" }
    }

    func record(_ id: String) -> ConceptRecord? {
        coordinatedRead(conceptURL(id)) { url in
            (try? Data(contentsOf: url)).flatMap { try? Self.decoder().decode(ConceptRecord.self, from: $0) }
        }
    }

    func extensionRecord(_ id: String) -> ConceptExtensionRecord? {
        coordinatedRead(extensionURL(id)) { url in
            (try? Data(contentsOf: url)).flatMap { try? Self.decoder().decode(ConceptExtensionRecord.self, from: $0) }
        }
    }

    // MARK: Writing

    /// Appends one event to a concept, creating it when new. The read, the
    /// append and the write happen under one coordination, so the sequence
    /// is computed from what is on disk at that moment.
    @discardableResult
    func append(to id: String, event: (_ sequence: Int) -> ConceptEvent) throws -> ConceptRecord {
        try FileManager.default.createDirectory(at: conceptsFolder, withIntermediateDirectories: true)
        var result: ConceptRecord?
        try coordinatedWrite(conceptURL(id)) { url in
            let existing = (try? Data(contentsOf: url)).flatMap { try? Self.decoder().decode(ConceptRecord.self, from: $0) }
            let base = existing ?? ConceptRecord(id: id, events: [])
            let updated = base.appending(event(base.nextSequence))
            try Self.encoder().encode(updated).write(to: url, options: .atomic)
            result = updated
        }
        guard let result else { throw CocoaError(.fileWriteUnknown) }
        return result
    }

    @discardableResult
    func appendExtension(to id: String, event: (_ sequence: Int) -> ConceptExtensionEvent) throws -> ConceptExtensionRecord {
        try FileManager.default.createDirectory(at: extensionsFolder, withIntermediateDirectories: true)
        var result: ConceptExtensionRecord?
        try coordinatedWrite(extensionURL(id)) { url in
            let existing = (try? Data(contentsOf: url))
                .flatMap { try? Self.decoder().decode(ConceptExtensionRecord.self, from: $0) }
            let base = existing ?? ConceptExtensionRecord(id: id)
            let updated = base.appending(event(base.nextSequence))
            try Self.encoder().encode(updated).write(to: url, options: .atomic)
            result = updated
        }
        guard let result else { throw CocoaError(.fileWriteUnknown) }
        return result
    }

    /// Writes a whole concept, merged with whatever is already there — a
    /// copy from another library never discards this one's later events.
    func write(_ record: ConceptRecord) throws {
        try FileManager.default.createDirectory(at: conceptsFolder, withIntermediateDirectories: true)
        try coordinatedWrite(conceptURL(record.id)) { url in
            let existing = (try? Data(contentsOf: url)).flatMap { try? Self.decoder().decode(ConceptRecord.self, from: $0) }
            let merged = existing.map { record.merging($0) } ?? record
            try Self.encoder().encode(merged).write(to: url, options: .atomic)
        }
    }

    func write(_ record: ConceptExtensionRecord) throws {
        try FileManager.default.createDirectory(at: extensionsFolder, withIntermediateDirectories: true)
        try coordinatedWrite(extensionURL(record.id)) { url in
            let existing = (try? Data(contentsOf: url))
                .flatMap { try? Self.decoder().decode(ConceptExtensionRecord.self, from: $0) }
            let merged = existing.map { record.merging($0) } ?? record
            try Self.encoder().encode(merged).write(to: url, options: .atomic)
        }
    }

    /// `library.json`: the format's name, when the library began, and the
    /// apps that have written to it — so a stranger to the folder knows
    /// what it is.
    func noteLibrary(app: String) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var library = (try? Data(contentsOf: libraryFile))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        if library["format"] == nil { library["format"] = Self.formatIdentifier }
        if library["created"] == nil { library["created"] = Self.isoPlain.string(from: Date()) }
        var apps = library["apps"] as? [String] ?? []
        if !apps.contains(app) { apps.append(app) }
        library["apps"] = apps
        library["specification"] = "ORIGAMI-CONCEPTS-FORMAT.md — https://github.com/frodehegland/OrigamiText"
        if let data = try? JSONSerialization.data(withJSONObject: library, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: libraryFile, options: .atomic)
        }
    }

    // MARK: Layouts

    func layoutURL(_ spaceID: String) -> URL {
        let safe = spaceID.map { character -> Character in
            character.isLetter || character.isNumber || character == "-" || character == "_" || character == "." ? character : "_"
        }
        return layoutsFolder.appendingPathComponent("\(String(safe)).json")
    }

    /// Every layout in the library, a space each.
    func layouts() -> [ConceptLayout] {
        let decoder = Self.decoder()
        return coordinatedRead(layoutsFolder) { folder -> [ConceptLayout] in
            Self.jsonFiles(in: folder).compactMap { url in
                (try? Data(contentsOf: url)).flatMap { try? decoder.decode(ConceptLayout.self, from: $0) }
            }
        } ?? []
    }

    func layout(space spaceID: String) -> ConceptLayout? {
        coordinatedRead(layoutURL(spaceID)) { url in
            (try? Data(contentsOf: url)).flatMap { try? Self.decoder().decode(ConceptLayout.self, from: $0) }
        }
    }

    /// Writes a space's arrangement whole: a layout is one app's current
    /// picture of one space, so the newest write wins (§5 of the format).
    func write(_ layout: ConceptLayout) throws {
        try FileManager.default.createDirectory(at: layoutsFolder, withIntermediateDirectories: true)
        var stamped = layout
        stamped.modified = Date()
        try coordinatedWrite(layoutURL(layout.space.id)) { url in
            try Self.encoder().encode(stamped).write(to: url, options: .atomic)
        }
    }

    // MARK: Conflicts

    /// On Apple systems iCloud Drive keeps the other side of a conflict as
    /// a file version. A concept's log merges by union, so every conflict
    /// resolves itself: both logs are read, united, written, and the
    /// versions marked resolved. Elsewhere there is nothing to do; a sync
    /// tool's "conflicted copy" file can be imported like any library.
    func resolveConflicts() {
        #if canImport(Darwin)
        for folder in [conceptsFolder, extensionsFolder] {
            for url in Self.jsonFiles(in: folder) {
                let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []
                guard !conflicts.isEmpty else { continue }
                if folder == conceptsFolder {
                    var merged = record(url.deletingPathExtension().lastPathComponent)
                    for version in conflicts {
                        if let data = try? Data(contentsOf: version.url),
                           let other = try? Self.decoder().decode(ConceptRecord.self, from: data) {
                            merged = merged.map { $0.merging(other) } ?? other
                        }
                    }
                    if let merged { try? write(merged) }
                } else {
                    var merged = extensionRecord(url.deletingPathExtension().lastPathComponent)
                    for version in conflicts {
                        if let data = try? Data(contentsOf: version.url),
                           let other = try? Self.decoder().decode(ConceptExtensionRecord.self, from: data) {
                            merged = merged.map { $0.merging(other) } ?? other
                        }
                    }
                    if let merged { try? write(merged) }
                }
                for version in conflicts { version.isResolved = true }
                try? NSFileVersion.removeOtherVersionsOfItem(at: url)
            }
        }
        #endif
    }
}

// MARK: - Reading Author's documents

/// `Contents/glossary.json` inside a `.liquid` package, read leniently:
/// only the phrase is required, unknown fields are ignored, and dates may
/// be Author's seconds-since-2001 or ISO 8601.
nonisolated enum AuthorGlossaryReader {
    private struct Entry: Decodable {
        let identifier: String?
        let phrase: String?
        let description: String?
        let entry: String?
        let tag: String?
        let date: Date?
        let urls: [GlossaryURL]?
        let citationIdentifiers: [String]?
        let documentName: String?
        struct GlossaryURL: Decodable { let url: String? }
    }
    private struct File: Decodable { let entries: [String: Entry]? }

    static func drafts(inDocumentAt documentURL: URL) -> [ConceptDraft]? {
        let url = documentURL.appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("glossary.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return drafts(fromGlossaryData: data,
                      documentName: documentURL.deletingPathExtension().lastPathComponent)
    }

    static func drafts(fromGlossaryData data: Data, documentName: String) -> [ConceptDraft]? {
        guard let file = try? ConceptLibraryStore.decoder().decode(File.self, from: data),
              let entries = file.entries else { return nil }
        return entries.map { key, entry in
            // Author's phrase is "Name, other name, third name".
            let parts = (entry.phrase ?? "").components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            var draft = ConceptDraft(term: parts.first ?? "")
            draft.definition = (entry.description ?? entry.entry ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            draft.tags = (entry.tag?.isEmpty == false) ? [entry.tag!] : []
            draft.urls = (entry.urls ?? []).compactMap { $0.url }.filter { !$0.isEmpty }
            draft.citationIDs = entry.citationIdentifiers ?? []
            draft.date = entry.date ?? Date(timeIntervalSince1970: 0)
            draft.originDocumentName = entry.documentName ?? documentName
            draft.documentTitle = documentName
            draft.sourceID = entry.identifier ?? key
            draft.definitionSource = "document"
            return draft
        }
    }

    /// The alternative names in an Author phrase, after the first.
    static func alternatives(inPhrase phrase: String) -> [String] {
        Array(phrase.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .dropFirst())
    }
}

// MARK: - SKOS export

/// The library (or part of it) as a SKOS concept scheme in JSON-LD — the
/// lingua franca of vocabularies, for anyone else's tools.
nonisolated enum ConceptLibrarySKOS {
    static func jsonLD(records: [ConceptRecord], extensions: [String: ConceptExtensionRecord],
                       schemeURI: String = "urn:origami:concepts", title: String = "Defined Concepts") -> Data? {
        var graph: [[String: Any]] = [[
            "@id": schemeURI,
            "@type": "skos:ConceptScheme",
            "dcterms:title": title,
            "dcterms:created": ISO8601DateFormatter().string(from: Date()),
        ]]
        for record in records where !record.isDeleted {
            let extensionRecord = extensions[record.id]
            var node: [String: Any] = [
                "@id": "\(schemeURI):\(record.id)",
                "@type": "skos:Concept",
                "skos:inScheme": ["@id": schemeURI],
            ]
            let term = record.headTerm
            let labels = extensionRecord?.labels ?? []
            let pref = labels.first { $0.kind == "pref" }
            node["skos:prefLabel"] = labelValue(pref?.value ?? term, lang: pref?.lang)
            let alt = labels.filter { $0.kind == "alt" }.map { labelValue($0.value, lang: $0.lang) }
            if !alt.isEmpty { node["skos:altLabel"] = alt }
            let hidden = labels.filter { $0.kind == "hidden" }.map { labelValue($0.value, lang: $0.lang) }
            if !hidden.isEmpty { node["skos:hiddenLabel"] = hidden }
            if !record.headDefinition.isEmpty { node["skos:definition"] = record.headDefinition }
            if let sense = extensionRecord?.sense { node["skos:scopeNote"] = sense }
            if let kind = extensionRecord?.conceptKind ?? record.head?.tags?.first { node["dcterms:type"] = kind }
            if let urls = record.head?.urls, !urls.isEmpty { node["rdfs:seeAlso"] = urls.map { ["@id": $0] } }
            for relation in extensionRecord?.relations ?? [] {
                let property: String
                switch relation.kind {
                case "broader": property = "skos:broader"
                case "narrower": property = "skos:narrower"
                default: property = "skos:related"
                }
                var existing = node[property] as? [[String: Any]] ?? []
                existing.append(["@id": "\(schemeURI):\(relation.to)"])
                node[property] = existing
            }
            for match in extensionRecord?.matches ?? [] {
                let property = match.kind == "close" ? "skos:closeMatch"
                    : match.kind == "broad" ? "skos:broadMatch" : "skos:exactMatch"
                var existing = node[property] as? [[String: Any]] ?? []
                existing.append(["@id": match.url ?? "\(match.scheme):\(match.identifier)"])
                node[property] = existing
            }
            let occurrences = extensionRecord?.occurrences ?? []
            if !occurrences.isEmpty {
                node["dcterms:isReferencedBy"] = occurrences.map { occurrence -> [String: Any] in
                    var item: [String: Any] = ["@id": occurrence.document]
                    if let title = occurrence.title { item["dcterms:title"] = title }
                    return item
                }
            }
            node["dcterms:modified"] = ISO8601DateFormatter().string(from: record.updated)
            graph.append(node)
        }
        let document: [String: Any] = [
            "@context": [
                "skos": "http://www.w3.org/2004/02/skos/core#",
                "dcterms": "http://purl.org/dc/terms/",
                "rdfs": "http://www.w3.org/2000/01/rdf-schema#",
            ],
            "@graph": graph,
        ]
        return try? JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
    }

    private static func labelValue(_ value: String, lang: String?) -> Any {
        if let lang, !lang.isEmpty { return ["@value": value, "@language": lang] }
        return value
    }
}
