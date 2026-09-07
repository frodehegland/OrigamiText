import SwiftUI
import Foundation

// Reference datasets: bibliographies a user imports so that citation
// cards can say more than the citation itself carries — full metadata,
// abstract, keywords, in-conference citation counts, links out.
//
// The mechanism is generic (import → normalise → local index → lookup);
// each source format is one `ReferenceDatasetFormat` conformer that owns
// every format-specific string. v1 ships one format: Mark W. R. Anderson's
// ACM Hypertext dataset, two JSON files (nodes + edges).

// MARK: - Canonical models

/// One work in a reference dataset, normalised out of whatever shape
/// the source format delivered.
struct ReferenceRecord: Codable, Sendable, Identifiable {
    var id: String                    // dataset-local ID, opaque ("3154184292")
    var title: String
    var authors: [String]             // parsed full names
    var authorsShort: String?         // "Walker", "Lupi et al."
    var firstAuthor: String?
    var firstAuthorAlternate: String? // only when the file's First Author differs
    var year: Int?
    var venueName: String?            // full proceedings title
    var venueTheme: String?           // conference theme, when named
    var venueAbbreviation: String?    // normalised, e.g. "ECHT '94"
    var venueAbbreviationRaw: String? // as the file had it, e.g. "ECHT94"
    var type: String?                 // "Full paper", "Poster", …
    var isPaper: Bool
    var doi: String?                  // bare, lowercase
    var url: URL?                     // publisher page
    var pdfURL: URL?
    var keywords: [String]
    var abstract: String?
    var totalReferences: Int
    var cites: [String]               // record IDs (out-edges, cleaned)
    var citedBy: [String]             // record IDs (in-edges, recomputed)
    var unresolvedCites: Int          // out-edges whose target was not in the export
    var extra: [String: String]       // unrecognised source columns, verbatim
}

/// One imported dataset: identity, provenance, and its records.
struct ReferenceDataset: Codable, Sendable, Identifiable {
    var id: UUID
    var formatKey: String            // "acm-hypertext-anderson"
    var name: String
    var versionLabel: String         // "2026" from a filename token, else import date
    var importedAt: Date
    var sourceFilenames: [String]
    var attribution: String
    var licence: String
    var homeURL: URL?
    var recordURLTemplate: String?   // "{id}" is substituted with the record ID
    var isEnabled: Bool
    var records: [ReferenceRecord]
    var parserVersion: Int           // bumped when parsing rules change → re-normalise from raw
}

/// The light face of a dataset for Settings and cards — everything but
/// the records, safe to mirror onto the main actor.
struct ReferenceDatasetSummary: Sendable, Identifiable, Equatable {
    var id: UUID
    var formatKey: String
    var name: String
    var versionLabel: String
    var importedAt: Date
    var attribution: String
    var licence: String
    var homeURL: URL?
    var recordURLTemplate: String?
    var isEnabled: Bool
    var recordCount: Int
    var recordsWithDOI: Int
    var edgeCount: Int
}

/// What the import reports when it succeeds.
struct ReferenceDatasetImportSummary: Sendable {
    var datasetName: String
    var versionLabel: String
    var records: Int
    var recordsWithDOI: Int
    var validEdges: Int
    var unresolvedEdgesSkipped: Int
    var selfLoopsSkipped: Int

    var message: String {
        var text = "Imported \(datasetName) (\(versionLabel)) — "
            + "\(records.formatted()) records, \(recordsWithDOI.formatted()) with DOI, "
            + "\(validEdges.formatted()) citation links"
        var skipped: [String] = []
        if unresolvedEdgesSkipped > 0 {
            skipped.append("\(unresolvedEdgesSkipped) links to items not in this export were skipped")
        }
        if selfLoopsSkipped > 0 {
            skipped.append("\(selfLoopsSkipped) self-citation\(selfLoopsSkipped == 1 ? " was" : "s were") skipped")
        }
        if !skipped.isEmpty { text += " (" + skipped.joined(separator: "; ") + ")" }
        return text + "."
    }
}

enum ReferenceDatasetError: LocalizedError {
    case notRecognised
    case edgesAlone
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .notRecognised:
            return "Not a recognised reference dataset."
        case .edgesAlone:
            return "Import the nodes file together with the edges file."
        case .unreadable(let name):
            return "Could not read \u{201C}\(name)\u{201D} as JSON."
        }
    }
}

// MARK: - Matching types

/// What the reader knows about a citation when it asks the store.
/// Built from the reference the card already has (BibTeX fields).
struct CitationQuery: Sendable {
    var doi: String?
    var title: String?
    var year: Int?
    var firstAuthorFamily: String?
    var authorFamilies: [String] = []
}

enum ReferenceMatchConfidence: Sendable {
    case exact, strong, probable, possible
}

/// A dataset record resolved for a citation, with how sure the match is
/// and everything the card needs to present it.
struct ReferenceMatch: Sendable {
    var record: ReferenceRecord
    var datasetName: String
    var datasetVersionLabel: String
    var attribution: String
    var licence: String
    var confidence: ReferenceMatchConfidence
    var reason: String                 // "DOI", "Title + year", "Title (fuzzy 0.94)"
    var alternates: [ReferenceRecord]
    var datasetPageURL: URL?           // recordURLTemplate with {id} substituted
}

// MARK: - Normalisers

/// The keys every format and every query is folded through, so that
/// "The Design of AHA!" and "the design of aha" land on the same string.
enum ReferenceKeys {
    /// NFKD → drop combining marks → lowercase → every run of
    /// non-alphanumerics becomes a single space → trim.
    static func titleKey(_ s: String) -> String {
        alnumKey(s)
    }

    /// The same pipeline on a family name, with apostrophes and hyphens
    /// dropped outright (O'Neill → oneill) rather than spaced.
    static func nameKey(_ s: String) -> String {
        var t = s
        for mark in ["'", "\u{2019}", "\u{2018}", "-", "\u{2010}", "\u{2013}"] {
            t = t.replacingOccurrences(of: mark, with: "")
        }
        return alnumKey(t)
    }

    /// A DOI in any of its usual URL dressings → bare lowercase form
    /// ("10.1145/317426.317448"), or nil when nothing remains.
    static func doiKey(_ s: String) -> String? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["https://dl.acm.org/doi/abs/", "https://dl.acm.org/doi/pdf/",
                       "https://dl.acm.org/doi/", "https://doi.org/", "http://doi.org/",
                       "https://dx.doi.org/", "http://dx.doi.org/", "doi:"] {
            if t.hasPrefix(prefix) { t = String(t.dropFirst(prefix.count)); break }
        }
        while let last = t.last, ".,;)".contains(last) { t.removeLast() }
        t = t.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }

    private static func alnumKey(_ s: String) -> String {
        let base = s.decomposedStringWithCompatibilityMapping.lowercased()
        var out = ""
        var spacePending = false
        for scalar in base.unicodeScalars {
            // Combining marks vanish (café → cafe), everything that is
            // not a-z0-9 becomes at most one space.
            if scalar.properties.canonicalCombiningClass != .notReordered { continue }
            let v = scalar.value
            if (97...122).contains(v) || (48...57).contains(v) {
                if spacePending && !out.isEmpty { out.append(" ") }
                spacePending = false
                out.unicodeScalars.append(scalar)
            } else {
                spacePending = true
            }
        }
        return out
    }

    /// Normalised Levenshtein similarity in 0…1 over the two strings.
    static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        let x = Array(a), y = Array(b)
        if x.isEmpty || y.isEmpty { return 0 }
        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        let distance = previous[y.count]
        return 1 - Double(distance) / Double(max(x.count, y.count))
    }
}

// MARK: - Format protocol

/// One parsed source file: its name and the flat objects it contained.
struct ReferenceDatasetFile: Sendable {
    var filename: String
    var objects: [[String: String]]
}

/// One conformer per source format. Detection is by content — the keys
/// the first object carries — never by filename.
protocol ReferenceDatasetFormat: Sendable {
    var formatKey: String { get }
    var currentParserVersion: Int { get }
    func detects(_ files: [ReferenceDatasetFile]) -> Bool
    func parse(_ files: [ReferenceDatasetFile]) throws -> ReferenceDatasetParseResult
}

struct ReferenceDatasetParseResult: Sendable {
    var name: String
    var attribution: String
    var licence: String
    var homeURL: URL?
    var recordURLTemplate: String?
    var records: [ReferenceRecord]
    var unresolvedEdgesSkipped: Int
    var selfLoopsSkipped: Int
}

// MARK: - The ACM Hypertext format (Mark W. R. Anderson)

/// Two JSON arrays of flat string-valued objects: nodes (one per paper,
/// 1987 onwards) and edges (SOURCE cites TARGET). Every HT-specific
/// string in the pipeline lives here.
struct HypertextDatasetFormat: ReferenceDatasetFormat {
    let formatKey = "acm-hypertext-anderson"
    let currentParserVersion = 1

    static let datasetName = "ACM Hypertext dataset"
    static let attribution =
        "ACM Hypertext Proceedings 1987\u{2013}onwards: a dataset. "
        + "Mark W. R. Anderson, Shoantel Ltd. Licence: CC BY-NC-SA 4.0.\n"
        + "https://www.shoantel.com/proj/acm-ht/visualisations/index.html\n"
        + "Open data release: https://doi.org/10.5258/SOTON/D1870\n"
        + "Described in: Anderson & Millard, Hypertext\u{2019}s meta-history, HT '22, "
        + "https://doi.org/10.1145/3511095.3531271"
    static let licence = "CC BY-NC-SA 4.0"
    static let homeURL = URL(string: "https://www.shoantel.com/proj/acm-ht/visualisations/index.html")
    /// The page name carries Mark's release token and will change with
    /// each release — one constant here, user-editable per dataset in
    /// Settings.
    static let recordURLTemplate =
        "https://www.shoantel.com/proj/acm-ht/visualisations/demos/index-2026j.html?selectedPaper={id}"

    /// The columns §2.1 names; anything else a future export adds goes
    /// to `extra` verbatim.
    private static let knownNodeKeys: Set<String> = [
        "ID", "Label", "Authors", "Author Names", "First Author",
        "Conference Proceedings", "Conference Title", "Conference Abbreviation",
        "Conference Year", "DOI URL", "DOI PDF URL", "Article Type", "Is Paper",
        "Keywords", "Abstract", "Total References", "In-Conference References",
        "In-Conference Cited By", "Has Citation Links",
    ]

    private static func isNodes(_ file: ReferenceDatasetFile) -> Bool {
        guard let first = file.objects.first else { return false }
        return first["ID"] != nil && first["Label"] != nil && first["DOI URL"] != nil
    }

    private static func isEdges(_ file: ReferenceDatasetFile) -> Bool {
        guard let first = file.objects.first else { return false }
        return first["SOURCE"] != nil && first["TARGET"] != nil && first["LINKTYPE"] != nil
    }

    func detects(_ files: [ReferenceDatasetFile]) -> Bool {
        files.contains(where: Self.isNodes) || files.contains(where: Self.isEdges)
    }

    func parse(_ files: [ReferenceDatasetFile]) throws -> ReferenceDatasetParseResult {
        guard let nodes = files.first(where: Self.isNodes) else {
            // Edges detected but no nodes — the one import mistake worth
            // a specific message.
            throw ReferenceDatasetError.edgesAlone
        }
        let edges = files.first(where: Self.isEdges)

        var records: [ReferenceRecord] = []
        records.reserveCapacity(nodes.objects.count)
        for object in nodes.objects {
            guard let record = Self.record(from: object) else { continue }
            records.append(record)
        }

        // The citation graph, recomputed from the cleaned edge list —
        // the file's own In-Conference counts are stale (§2.1) and are
        // never imported as facts.
        var unresolvedSkipped = 0
        var selfLoops = 0
        if let edges {
            var index: [String: Int] = [:]
            for (i, record) in records.enumerated() { index[record.id] = i }
            var cites: [[String]] = Array(repeating: [], count: records.count)
            var citedBy: [[String]] = Array(repeating: [], count: records.count)
            var unresolved: [Int] = Array(repeating: 0, count: records.count)
            for edge in edges.objects {
                guard edge["LINKTYPE", default: "cites"]
                    .trimmingCharacters(in: .whitespaces) == "cites" else { continue }
                let source = edge["SOURCE", default: ""].trimmingCharacters(in: .whitespaces)
                let target = edge["TARGET", default: ""].trimmingCharacters(in: .whitespaces)
                guard source != target else { selfLoops += 1; continue }
                guard let s = index[source] else { unresolvedSkipped += 1; continue }
                guard let t = index[target] else {
                    // The cited item exists in Mark's corpus but not in
                    // this export — dropped from the graph, counted so
                    // the card can say "+N not in this export".
                    unresolved[s] += 1
                    unresolvedSkipped += 1
                    continue
                }
                cites[s].append(target)
                citedBy[t].append(source)
            }
            for i in records.indices {
                records[i].cites = cites[i]
                records[i].citedBy = citedBy[i]
                records[i].unresolvedCites = unresolved[i]
            }
        }

        return ReferenceDatasetParseResult(
            name: Self.datasetName,
            attribution: Self.attribution,
            licence: Self.licence,
            homeURL: Self.homeURL,
            recordURLTemplate: Self.recordURLTemplate,
            records: records,
            unresolvedEdgesSkipped: unresolvedSkipped,
            selfLoopsSkipped: selfLoops)
    }

    // MARK: One node → one record (§4.3, applied exactly)

    private static func record(from object: [String: String]) -> ReferenceRecord? {
        func field(_ key: String) -> String {
            object[key, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func optional(_ key: String) -> String? {
            let v = field(key)
            return v.isEmpty ? nil : v
        }
        let id = field("ID")
        guard !id.isEmpty else { return nil }

        let authors = parseAuthors(field("Author Names"))
        let firstAuthor = authors.first
        let fileFirst = optional("First Author")
        let doiURL = optional("DOI URL")
        let url = doiURL.flatMap(URL.init(string:))
        let pdfURL = doiURL
            .map { $0.replacingOccurrences(of: "/doi/", with: "/doi/pdf/") }
            .flatMap(URL.init(string:))
        let abbreviationRaw = optional("Conference Abbreviation")

        var extra: [String: String] = [:]
        for (key, value) in object where !knownNodeKeys.contains(key) {
            extra[key] = value
        }

        return ReferenceRecord(
            id: id,
            title: decodingHTMLEntities(field("Label")),
            authors: authors,
            authorsShort: optional("Authors"),
            firstAuthor: firstAuthor,
            firstAuthorAlternate: (fileFirst != nil && fileFirst != firstAuthor) ? fileFirst : nil,
            year: Int(field("Conference Year")),
            venueName: optional("Conference Proceedings"),
            venueTheme: optional("Conference Title"),
            venueAbbreviation: abbreviationRaw.map(normalisedVenueAbbreviation),
            venueAbbreviationRaw: abbreviationRaw,
            type: optional("Article Type"),
            isPaper: field("Is Paper") == "true",
            doi: doiURL.flatMap(ReferenceKeys.doiKey),
            url: url,
            pdfURL: pdfURL,
            keywords: field("Keywords").split(separator: ";")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty },
            abstract: optional("Abstract").map(decodingHTMLEntities),
            totalReferences: Int(field("Total References")) ?? 0,
            cites: [],
            citedBy: [],
            unresolvedCites: 0,
            extra: extra)
    }

    /// "Frank M. Shipman, III, Richard Furuta" → the suffix rejoins its
    /// name instead of becoming an author of its own.
    static func parseAuthors(_ raw: String) -> [String] {
        let suffixes: Set<String> = ["Jr.", "Jr", "Sr.", "Sr", "II", "III", "IV"]
        var out: [String] = []
        for piece in raw.split(separator: ",") {
            let token = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { continue }
            if suffixes.contains(token), !out.isEmpty {
                out[out.count - 1] += ", " + token
            } else {
                out.append(token)
            }
        }
        return out
    }

    /// The family name a full name matches under: the last word, once
    /// any ", Jr."-style suffix is set aside.
    static func familyName(of full: String) -> String {
        var name = full
        if let comma = name.lastIndex(of: ",") {
            let tail = name[name.index(after: comma)...].trimmingCharacters(in: .whitespaces)
            if ["Jr.", "Jr", "Sr.", "Sr", "II", "III", "IV"].contains(tail) {
                name = String(name[..<comma])
            }
        }
        return name.split(separator: " ").last.map(String.init) ?? name
    }

    /// `^([A-Z]+)\s?'?(\d{2})$` → "$1 '$2": ECHT94 → ECHT '94;
    /// "HT '25 Adjunct" passes through untouched.
    static func normalisedVenueAbbreviation(_ raw: String) -> String {
        var rest = Substring(raw)
        var letters = ""
        while let c = rest.first, c.isLetter, c.isUppercase, c.isASCII {
            letters.append(c)
            rest = rest.dropFirst()
        }
        guard !letters.isEmpty else { return raw }
        if rest.first == " " { rest = rest.dropFirst() }
        if rest.first == "'" { rest = rest.dropFirst() }
        guard rest.count == 2, rest.allSatisfy({ $0.isNumber }) else { return raw }
        return "\(letters) '\(rest)"
    }

    /// Named and numeric HTML entities, defensively — including the
    /// malformed `&153;` (a bare Windows-1252 code) the 2026 export
    /// carries, which reads as ™.
    static func decodingHTMLEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        out.reserveCapacity(s.count)
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "&" {
                let limit = s.index(i, offsetBy: 10, limitedBy: s.endIndex) ?? s.endIndex
                if let semi = s[i..<limit].firstIndex(of: ";"),
                   let decoded = entity(String(s[s.index(after: i)..<semi])) {
                    out += decoded
                    i = s.index(after: semi)
                    continue
                }
            }
            out.append(c)
            i = s.index(after: i)
        }
        return out
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "nbsp": "\u{00A0}", "ndash": "\u{2013}", "mdash": "\u{2014}",
        "lsquo": "\u{2018}", "rsquo": "\u{2019}",
        "ldquo": "\u{201C}", "rdquo": "\u{201D}",
        "hellip": "\u{2026}", "trade": "\u{2122}", "copy": "\u{00A9}",
        "reg": "\u{00AE}", "deg": "\u{00B0}", "times": "\u{00D7}",
        "minus": "\u{2212}",
    ]

    /// 0x80–0x9F as Windows-1252 renders them — where `&153;` lands.
    private static let cp1252: [UInt32] = [
        0x20AC, 0x81, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
        0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x8D, 0x017D, 0x8F,
        0x90, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
        0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x9D, 0x017E, 0x0178,
    ]

    private static func entity(_ body: String) -> String? {
        if let named = namedEntities[body] { return named }
        var digits = body
        if digits.hasPrefix("#x") || digits.hasPrefix("#X") {
            guard let v = UInt32(digits.dropFirst(2), radix: 16),
                  let scalar = Unicode.Scalar(v) else { return nil }
            return String(Character(scalar))
        }
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard let v = UInt32(digits) else { return nil }
        let code = (128...159).contains(v) ? cp1252[Int(v) - 128] : v
        guard let scalar = Unicode.Scalar(code) else { return nil }
        return String(Character(scalar))
    }
}

// MARK: - The store

/// Holds every imported dataset, keeps the lookup indexes, answers
/// citation queries. Never touches UI; the card asks, the store answers.
actor ReferenceDatasetStore {
    private let formats: [any ReferenceDatasetFormat] = [HypertextDatasetFormat()]
    private var datasets: [ReferenceDataset] = []
    private var loaded = false

    /// Where datasets live: beside the unpacked library, one folder per
    /// dataset with the raw files and the normalised JSON side by side.
    /// Raw copies let a parser fix re-normalise without asking the user
    /// to find the files again.
    private static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("EPUBs", isDirectory: true)
            .appendingPathComponent("ReferenceDatasets", isDirectory: true)
    }

    // MARK: Indexes (§5) — enabled datasets only, rebuilt on any change

    private struct Slot: Hashable { let dataset: Int; let record: Int }
    private var byDOI: [String: Slot] = [:]
    private var byTitleKey: [String: [Slot]] = [:]
    private var byShortTitleKey: [String: [Slot]] = [:]
    private var bySurnameYear: [String: [Slot]] = [:]
    private var byYear: [Int: [Slot]] = [:]

    // MARK: Loading and persistence

    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(
            at: Self.root, includingPropertiesForKeys: nil) else { return }
        var found: [ReferenceDataset] = []
        for folder in folders {
            let manifest = folder.appendingPathComponent("dataset.json")
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let data = try? Data(contentsOf: manifest),
                  var dataset = try? decoder.decode(ReferenceDataset.self, from: data)
            else { continue }
            // A parser fix re-normalises from the raw copies on the next
            // launch — identity, name, toggle and template edits survive.
            if let format = formats.first(where: { $0.formatKey == dataset.formatKey }),
               dataset.parserVersion < format.currentParserVersion,
               let reparsed = try? reparse(dataset, in: folder, with: format) {
                dataset = reparsed
            }
            found.append(dataset)
        }
        datasets = found.sorted { $0.importedAt < $1.importedAt }
        rebuildIndexes()
    }

    private func reparse(_ old: ReferenceDataset, in folder: URL,
                         with format: any ReferenceDatasetFormat) throws -> ReferenceDataset {
        let rawFolder = folder.appendingPathComponent("raw", isDirectory: true)
        let rawURLs = try FileManager.default.contentsOfDirectory(
            at: rawFolder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "json" }
        let files = try rawURLs.map { try Self.readFile(at: $0) }
        let parsed = try format.parse(files)
        var dataset = old
        dataset.records = parsed.records
        dataset.parserVersion = format.currentParserVersion
        try save(dataset)
        return dataset
    }

    private func folderURL(for dataset: ReferenceDataset) -> URL {
        Self.root.appendingPathComponent(dataset.id.uuidString, isDirectory: true)
    }

    private func save(_ dataset: ReferenceDataset) throws {
        let folder = folderURL(for: dataset)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Decoding must match:
        let data = try encoder.encode(dataset)
        try data.write(to: folder.appendingPathComponent("dataset.json"), options: .atomic)
    }

    // MARK: Import

    /// Reads, sniffs and parses the given JSON files; on success the
    /// dataset replaces any earlier import of the same format (parse
    /// first, discard after — a failed re-import keeps the old data).
    func importDataset(from urls: [URL]) throws -> ReferenceDatasetImportSummary {
        loadIfNeeded()
        var files: [ReferenceDatasetFile] = []
        var rawData: [(name: String, data: Data)] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                throw ReferenceDatasetError.unreadable(url.lastPathComponent)
            }
            files.append(try Self.readFile(named: url.lastPathComponent, data: data))
            rawData.append((url.lastPathComponent, data))
        }
        guard let format = formats.first(where: { $0.detects(files) }) else {
            throw ReferenceDatasetError.notRecognised
        }
        let parsed = try format.parse(files)

        let previous = datasets.first { $0.formatKey == format.formatKey }
        var dataset = ReferenceDataset(
            id: UUID(),
            formatKey: format.formatKey,
            name: parsed.name,
            versionLabel: Self.versionLabel(fromFilenames: files.map(\.filename)),
            importedAt: .now,
            sourceFilenames: files.map(\.filename),
            attribution: parsed.attribution,
            licence: parsed.licence,
            homeURL: parsed.homeURL,
            recordURLTemplate: parsed.recordURLTemplate,
            isEnabled: true,
            records: parsed.records,
            parserVersion: format.currentParserVersion)
        // A re-import keeps the user's edits and toggle.
        if let previous {
            if previous.name != parsed.name { dataset.name = previous.name }
            if previous.recordURLTemplate != parsed.recordURLTemplate {
                dataset.recordURLTemplate = previous.recordURLTemplate
            }
            dataset.isEnabled = previous.isEnabled
        }

        // Persist the new dataset fully before removing the old one.
        let folder = folderURL(for: dataset)
        let raw = folder.appendingPathComponent("raw", isDirectory: true)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        for file in rawData {
            try file.data.write(to: raw.appendingPathComponent(file.name), options: .atomic)
        }
        try save(dataset)
        if let previous {
            datasets.removeAll { $0.id == previous.id }
            try? FileManager.default.removeItem(at: folderURL(for: previous))
        }
        datasets.append(dataset)
        datasets.sort { $0.importedAt < $1.importedAt }
        rebuildIndexes()

        return ReferenceDatasetImportSummary(
            datasetName: dataset.name,
            versionLabel: dataset.versionLabel,
            records: dataset.records.count,
            recordsWithDOI: dataset.records.count(where: { $0.doi != nil }),
            validEdges: dataset.records.reduce(0) { $0 + $1.cites.count },
            unresolvedEdgesSkipped: parsed.unresolvedEdgesSkipped,
            selfLoopsSkipped: parsed.selfLoopsSkipped)
    }

    private static func readFile(at url: URL) throws -> ReferenceDatasetFile {
        guard let data = try? Data(contentsOf: url) else {
            throw ReferenceDatasetError.unreadable(url.lastPathComponent)
        }
        return try readFile(named: url.lastPathComponent, data: data)
    }

    /// A top-level JSON array of flat objects, every value coerced to a
    /// string (the source promises strings; numbers are tolerated).
    private static func readFile(named name: String, data: Data) throws -> ReferenceDatasetFile {
        guard let parsed = try? JSONSerialization.jsonObject(with: data),
              let array = parsed as? [Any] else {
            throw ReferenceDatasetError.unreadable(name)
        }
        var objects: [[String: String]] = []
        objects.reserveCapacity(array.count)
        for element in array {
            guard let object = element as? [String: Any] else { continue }
            var flat: [String: String] = [:]
            for (key, value) in object {
                if let s = value as? String { flat[key] = s }
                else if let n = value as? NSNumber { flat[key] = n.stringValue }
            }
            objects.append(flat)
        }
        guard !objects.isEmpty else { throw ReferenceDatasetError.notRecognised }
        return ReferenceDatasetFile(filename: name, objects: objects)
    }

    /// "ht-nodes-2026.json" → "2026"; otherwise the import year.
    private static func versionLabel(fromFilenames names: [String]) -> String {
        for name in names {
            var digits = ""
            for c in name {
                if c.isNumber { digits.append(c) } else { digits = "" }
                if digits.count == 4, digits.hasPrefix("19") || digits.hasPrefix("20") {
                    return digits
                }
            }
        }
        return Calendar.current.component(.year, from: .now).description
    }

    // MARK: Settings-facing API

    func summaries() -> [ReferenceDatasetSummary] {
        loadIfNeeded()
        return datasets.map { d in
            ReferenceDatasetSummary(
                id: d.id, formatKey: d.formatKey, name: d.name,
                versionLabel: d.versionLabel, importedAt: d.importedAt,
                attribution: d.attribution, licence: d.licence,
                homeURL: d.homeURL, recordURLTemplate: d.recordURLTemplate,
                isEnabled: d.isEnabled,
                recordCount: d.records.count,
                recordsWithDOI: d.records.count(where: { $0.doi != nil }),
                edgeCount: d.records.reduce(0) { $0 + $1.cites.count })
        }
    }

    func setEnabled(_ id: UUID, _ enabled: Bool) {
        update(id) { $0.isEnabled = enabled }
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        update(id) { $0.name = trimmed }
    }

    func setRecordURLTemplate(_ id: UUID, to template: String) {
        let trimmed = template.trimmingCharacters(in: .whitespaces)
        update(id) { $0.recordURLTemplate = trimmed.isEmpty ? nil : trimmed }
    }

    func remove(_ id: UUID) {
        loadIfNeeded()
        guard let dataset = datasets.first(where: { $0.id == id }) else { return }
        try? FileManager.default.removeItem(at: folderURL(for: dataset))
        datasets.removeAll { $0.id == id }
        rebuildIndexes()
    }

    private func update(_ id: UUID, _ change: (inout ReferenceDataset) -> Void) {
        loadIfNeeded()
        guard let i = datasets.firstIndex(where: { $0.id == id }) else { return }
        change(&datasets[i])
        try? save(datasets[i])
        rebuildIndexes()
    }

    // MARK: Index building

    private func rebuildIndexes() {
        byDOI = [:]; byTitleKey = [:]; byShortTitleKey = [:]
        bySurnameYear = [:]; byYear = [:]
        // Datasets are kept sorted by import date, so the earlier import
        // wins a shared DOI.
        for (d, dataset) in datasets.enumerated() where dataset.isEnabled {
            for (r, record) in dataset.records.enumerated() {
                let slot = Slot(dataset: d, record: r)
                if let doi = record.doi, byDOI[doi] == nil { byDOI[doi] = slot }
                let titleKey = ReferenceKeys.titleKey(record.title)
                if !titleKey.isEmpty { byTitleKey[titleKey, default: []].append(slot) }
                if let colon = record.title.firstIndex(of: ":") {
                    let short = ReferenceKeys.titleKey(String(record.title[..<colon]))
                    if !short.isEmpty, short != titleKey {
                        byShortTitleKey[short, default: []].append(slot)
                    }
                }
                if let year = record.year {
                    byYear[year, default: []].append(slot)
                    var surnames: [String] = []
                    if let first = record.firstAuthor {
                        surnames.append(ReferenceKeys.nameKey(
                            HypertextDatasetFormat.familyName(of: first)))
                    }
                    if let alternate = record.firstAuthorAlternate {
                        surnames.append(ReferenceKeys.nameKey(
                            HypertextDatasetFormat.familyName(of: alternate)))
                    }
                    for surname in Set(surnames) where !surname.isEmpty {
                        bySurnameYear["\(surname)|\(year)", default: []].append(slot)
                    }
                }
            }
        }
    }

    // MARK: Lookup (§6.3) — stop at the first tier that answers

    func lookup(_ query: CitationQuery) -> ReferenceMatch? {
        loadIfNeeded()
        // Never on author or year alone; never with neither DOI nor title.
        // Tier 1: DOI.
        if let doi = query.doi.flatMap(ReferenceKeys.doiKey), let slot = byDOI[doi] {
            return match([slot], confidence: .exact, reason: "DOI")
        }
        guard let title = query.title else { return nil }
        let titleKey = ReferenceKeys.titleKey(title)
        guard !titleKey.isEmpty else { return nil }
        let surname = query.firstAuthorFamily.map(ReferenceKeys.nameKey)

        func yearOK(_ slot: Slot) -> Bool {
            guard let q = query.year, let r = record(slot).year else { return true }
            return abs(q - r) <= 1
        }
        func surnameOK(_ slot: Slot) -> Bool {
            guard let surname, !surname.isEmpty else { return true }
            return record(slot).authors.contains {
                ReferenceKeys.nameKey(HypertextDatasetFormat.familyName(of: $0)) == surname
            }
        }

        // Tiers 2 and 4: full title key.
        if let slots = byTitleKey[titleKey], !slots.isEmpty {
            let compatible = slots.filter { yearOK($0) && surnameOK($0) }
            if !compatible.isEmpty {
                return match(compatible, confidence: .strong, reason: "Title + year")
            }
            return match(slots, confidence: .probable, reason: "Title (year or author differs)")
        }
        // Tier 3: the citation dropped the record's subtitle — year and
        // surname must both hold.
        if let slots = byShortTitleKey[titleKey], !slots.isEmpty,
           query.year != nil, surname?.isEmpty == false {
            let compatible = slots.filter { yearOK($0) && surnameOK($0) }
            if !compatible.isEmpty {
                return match(compatible, confidence: .strong, reason: "Short title + year")
            }
        }
        // Tiers 5–6: fuzzy over a surname/year candidate pool. No year →
        // do not attempt.
        guard let year = query.year else { return nil }
        var pool: Set<Slot> = []
        if let surname, !surname.isEmpty {
            for y in (year - 1)...(year + 1) {
                for slot in bySurnameYear["\(surname)|\(y)"] ?? [] { pool.insert(slot) }
            }
        } else {
            for y in (year - 1)...(year + 1) {
                for slot in byYear[y] ?? [] { pool.insert(slot) }
            }
        }
        guard !pool.isEmpty else { return nil }
        let scored = pool
            .map { (slot: $0, score: ReferenceKeys.similarity(
                titleKey, ReferenceKeys.titleKey(record($0).title))) }
            .sorted { $0.score > $1.score }
        let best = scored[0]
        let unique = scored.count == 1 || scored[1].score <= best.score - 0.05
        guard unique else { return nil }
        let rounded = (best.score * 100).rounded() / 100
        if best.score >= 0.92 {
            return match([best.slot], confidence: .probable, reason: "Title (fuzzy \(rounded))")
        }
        if best.score >= 0.85 {
            return match([best.slot], confidence: .possible, reason: "Title (fuzzy \(rounded))")
        }
        return nil
    }

    private func record(_ slot: Slot) -> ReferenceRecord {
        datasets[slot.dataset].records[slot.record]
    }

    /// A record by its dataset-local ID, across enabled datasets — for
    /// the document-info view and tests.
    func record(withID id: String) -> ReferenceRecord? {
        loadIfNeeded()
        for dataset in datasets where dataset.isEnabled {
            if let record = dataset.records.first(where: { $0.id == id }) { return record }
        }
        return nil
    }

    /// Ties break toward the real paper: `isPaper`, then a DOI, then the
    /// earliest year; the rest ride along as alternates for the card.
    private func match(_ slots: [Slot], confidence: ReferenceMatchConfidence,
                       reason: String) -> ReferenceMatch? {
        guard !slots.isEmpty else { return nil }
        let ordered = slots.sorted { a, b in
            let x = record(a), y = record(b)
            if x.isPaper != y.isPaper { return x.isPaper }
            if (x.doi != nil) != (y.doi != nil) { return x.doi != nil }
            return (x.year ?? .max) < (y.year ?? .max)
        }
        let winner = ordered[0]
        let dataset = datasets[winner.dataset]
        let rec = record(winner)
        let pageURL = dataset.recordURLTemplate
            .map { $0.replacingOccurrences(of: "{id}", with: rec.id) }
            .flatMap(URL.init(string:))
        return ReferenceMatch(
            record: rec,
            datasetName: dataset.name,
            datasetVersionLabel: dataset.versionLabel,
            attribution: dataset.attribution,
            licence: dataset.licence,
            confidence: confidence,
            reason: reason,
            alternates: ordered.dropFirst().map(record),
            datasetPageURL: pageURL)
    }
}

// MARK: - The citation card's dataset section (§8)

/// Shown only when a dataset match exists; absence is silence. One view
/// for every platform — nothing hover-only.
struct ReferenceDatasetCardSection: View {
    let match: ReferenceMatch
    /// The matched work is also in the local library — worth an Open
    /// button with visual priority.
    var libraryDocumentTitle: String? = nil
    var onOpenLibraryDocument: (() -> Void)? = nil
    var onCopyCitation: (() -> Void)? = nil

    @Environment(\.openURL) private var openURL
    @State private var abstractExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            provenanceLine
            Text(match.record.title)
                .font(.callout).bold()
                .textSelection(.enabled)
            if !match.record.authors.isEmpty {
                Text(match.record.authors.joined(separator: ", "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            venueLines
            abstractBlock
            if !match.record.keywords.isEmpty {
                Text(match.record.keywords.joined(separator: " \u{00B7} "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            inConferenceLine
            actions
            Text("Data: Mark W. R. Anderson, ACM HT Proceedings dataset \u{00B7} \(match.licence)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var provenanceLine: some View {
        HStack(spacing: 6) {
            Text("\(match.datasetName) \u{00B7} \(match.datasetVersionLabel)")
                .font(.caption2)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.tint.opacity(0.12), in: Capsule())
            switch match.confidence {
            case .exact:
                EmptyView()
            case .strong:
                Text("Matched by title")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .probable:
                Text("Probable match \u{2014} check")
                    .font(.caption)
                    .foregroundStyle(.orange)
            case .possible:
                Text("Possible match \u{2014} check")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if !match.alternates.isEmpty {
                Text("\u{00B7} \(match.alternates.count + 1) records")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var venueLines: some View {
        let parts = [match.record.venueAbbreviation,
                     match.record.year.map(String.init),
                     match.record.type].compactMap { $0 }
        if !parts.isEmpty {
            Text(parts.joined(separator: " \u{00B7} "))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        if let theme = match.record.venueTheme {
            Text(theme)
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder private var abstractBlock: some View {
        if let abstract = match.record.abstract {
            VStack(alignment: .leading, spacing: 4) {
                if abstractExpanded {
                    ScrollView {
                        Text(abstract)
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 220)
                } else {
                    Text(abstract)
                        .font(.body)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                Button(abstractExpanded ? "Less" : "More") {
                    withAnimation { abstractExpanded.toggle() }
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.tint)
            }
        }
    }

    private var inConferenceLine: some View {
        var text = "Cited by \(match.record.citedBy.count) Hypertext "
            + "paper\(match.record.citedBy.count == 1 ? "" : "s")"
            + " \u{00B7} Cites \(match.record.cites.count)"
        if match.record.unresolvedCites > 0 {
            text += " (+\(match.record.unresolvedCites) not in this export)"
        }
        return Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if let onOpenLibraryDocument {
                Button("Open", action: onOpenLibraryDocument)
                    .buttonStyle(.borderedProminent)
                    .help(libraryDocumentTitle.map { "Open \u{201C}\($0)\u{201D} from the library" }
                          ?? "Open the cited document from the library")
            }
            if let url = match.record.url {
                Button("ACM Digital Library") { openURL(url) }
            }
            if let pdf = match.record.pdfURL {
                Button("PDF") { openURL(pdf) }
            }
            if let page = match.datasetPageURL {
                Button("Dataset page") { openURL(page) }
            }
            if let onCopyCitation {
                Button("Copy Citation", action: onCopyCitation)
                    .help("The citation with the dataset's fields filling what it lacks")
            }
        }
        .controlSize(.small)
    }
}
