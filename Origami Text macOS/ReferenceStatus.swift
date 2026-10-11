import Foundation

/// The standing of each cited work — retracted, under an expression of
/// concern, corrected, open to read, how often cited — for the quiet
/// keywords under every entry in the References view. Sources (verified
/// live, October 2026):
///
///  - The Retraction Watch database, downloaded whole and kept on this
///    Mac (Crossref's open copy on GitLab, CC0, refreshed daily, ~67 MB
///    of CSV folded to a compact index). Checked offline against every
///    reference — by DOI, and by title and year for references without
///    one. The subscription refreshes when References opens and the copy
///    is over a week old; never at launch.
///  - Crossref's `updated-by` on each DOI — notices publishers register
///    themselves, which can reach Crossref before the database.
///  - Unpaywall — whether a legal free copy exists, and where.
///  - OpenCitations — how many works cite this one.
///  - scite — how later papers cite it: statements supporting it,
///    disputing it, or only mentioning it; and its editorial notices.
///  - OpenAlex, one keyless lookup per DOI — its retracted flag, topics,
///    authors with ORCID iDs, citations by year, a free copy, abstract.
///
/// All are free and keyless. Live answers cache beside the unpacked
/// books and refresh after a month; nothing is asked twice in a reading.
@MainActor
enum ReferenceStatus {

    // MARK: Settings

    static let retractionWatchKey = "referencesRetractionWatch"
    static let crossrefNoticesKey = "referencesCrossrefNotices"
    static let openAccessKey = "referencesOpenAccess"
    static let citationCountsKey = "referencesCitationCounts"
    static let replicationsKey = "referencesReplications"
    static let sciteKey = "referencesScite"
    static let openAlexKey = "referencesOpenAlex"

    /// Who is asking — the polite pools want an address to write to.
    nonisolated static let contactEmail = "frode@hegland.com"
    nonisolated static let userAgent = "OrigamiText/1.0 (mailto:\(contactEmail))"

    private static func isOn(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    // MARK: What a reference's standing holds

    /// A notice attached to a work: retraction, expression of concern,
    /// correction, withdrawal, reinstatement.
    nonisolated struct Notice: Codable, Hashable, Sendable {
        nonisolated enum Kind: String, Codable, Sendable {
            case retraction, expressionOfConcern, correction, withdrawal, reinstatement
            /// A newer version of the work has been registered.
            case newVersion
        }
        var kind: Kind
        /// The notice's date, ISO yyyy-MM-dd when known.
        var date: String?
        /// Retraction Watch's reasons, semicolon-joined as recorded.
        var reason: String?
        var noticeDOI: String?
        /// "Retraction Watch", "Crossref", "scite" or "OpenAlex".
        var source: String
    }

    /// A small keyword under an entry — what the reader sees.
    nonisolated struct Mark: Hashable, Sendable {
        /// alarm red, caution orange, info blue, good green, positive
        /// the accent, quiet grey.
        nonisolated enum Tone: Sendable { case alarm, caution, quiet, positive, info, good }
        var text: String
        var tone: Tone
        /// The longer account, for the help tag.
        var detail: String = ""
        /// Drawn as a pill — the trust keywords (retractions, preprints,
        /// replications); everything else is plain text.
        var pill: Bool = false
        /// What the keyword means, in a sentence — the citation card
        /// shows it beside the keyword; `detail` is the evidence.
        var meaning: String = ""
    }

    /// The live per-DOI answers, cached verbatim.
    nonisolated struct Live: Codable, Sendable {
        var notices: [Notice] = []
        var openAccessURL: String?
        var isOpenAccess: Bool?
        var citedBy: Int?
        var fetched: Date
        /// Crossref's type and subtype ("posted-content" / "preprint",
        /// "dataset", "book-chapter"…).
        var workType: String?
        var workSubtype: String?
        /// A preprint whose reviewed version Crossref links to.
        var hasPublishedVersion: Bool?
        /// Whether the DOI exists at all (the DOI system's own answer) —
        /// false is an invented or mistyped reference.
        var doiResolves: Bool?
        /// OpenAlex's field-and-year citation percentile, with a key.
        var inTop1Percent: Bool?
        var inTop10Percent: Bool?
        var openAlexType: String?
        /// DataCite's general type for DOIs it registers (Zenodo, arXiv,
        /// figshare…): "Dataset", "Software", "Preprint"…
        var dataCiteType: String?
        /// Which questions this answer asked; older answers are asked again.
        var version: Int?

        /// How later papers cite it, per scite's citation statements.
        var sciteSupporting: Int?
        var sciteContradicting: Int?
        var sciteMentioning: Int?
        /// OpenAlex's view of the work, asked by DOI without a key.
        var openAlexRetracted: Bool?
        var topics: [String]?
        var authors: [Author]?
        /// Citations per year, newest first, as OpenAlex counts them.
        var citationsByYear: [YearCount]?
        var abstract: String?
        var abstractSource: String?
        /// The work as its registry describes it — Crossref first, then
        /// OpenAlex — not as one citing paper happened to write it.
        var canonicalTitle: String?
        var canonicalAuthors: [String]?
        var canonicalYear: Int?
        var canonicalVenue: String?

        nonisolated struct Author: Codable, Hashable, Sendable {
            var name: String
            var orcid: String?
        }
        nonisolated struct YearCount: Codable, Hashable, Sendable {
            var year: Int
            var count: Int
        }
    }

    /// The questions a live answer asks now — raised when a new one joins.
    private static let liveVersion = 5

    // MARK: The Retraction Watch index

    /// The database folded for lookup: original-paper DOI → notices, and
    /// normalized title → notices with the paper's year, for references
    /// that carry no DOI.
    nonisolated struct RetractionIndex: Codable, Sendable {
        nonisolated struct TitledNotice: Codable, Sendable {
            var year: Int?
            var notice: Notice
        }
        var updated: Date
        var records: Int
        var byDOI: [String: [Notice]]
        var byTitle: [String: [TitledNotice]]
    }

    private static var supportFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("EPUBs", isDirectory: true)
    }

    nonisolated private static var indexURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("EPUBs", isDirectory: true)
            .appendingPathComponent("RetractionWatch.json")
    }

    private static let csvURL = URL(string:
        "https://gitlab.com/crossref/retraction-watch-data/-/raw/main/retraction_watch.csv")!

    /// The index in memory, once read from disk.
    private(set) static var retractionIndex: RetractionIndex?
    private static var indexLoaded = false
    /// A download or rebuild under way.
    private(set) static var isRefreshingIndex = false
    /// The last refresh's failure, for Settings and the view's line.
    private(set) static var indexError: String?

    /// Reads the stored index off the main actor, once.
    static func loadIndexIfNeeded() async {
        guard !indexLoaded else { return }
        indexLoaded = true
        let url = indexURL
        let loaded = await Task.detached(priority: .utility) { () -> RetractionIndex? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(RetractionIndex.self, from: data)
        }.value
        if retractionIndex == nil { retractionIndex = loaded }
    }

    /// The subscription's beat: a fresh copy when there is none, or the
    /// one held is over a week old. `force` is Settings' Update Now.
    static func refreshIndexIfStale(force: Bool = false) async {
        guard isOn(retractionWatchKey), !isRefreshingIndex else { return }
        await loadIndexIfNeeded()
        if !force, let held = retractionIndex,
           Date.now.timeIntervalSince(held.updated) < 7 * 86_400 { return }
        isRefreshingIndex = true
        indexError = nil
        defer { isRefreshingIndex = false }
        var request = URLRequest(url: csvURL, timeoutInterval: 120)
        request.setValue(Self.userAgent,
                         forHTTPHeaderField: "User-Agent")
        do {
            let (file, response) = try await URLSession.shared.download(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                indexError = "The Retraction Watch database could not be fetched."
                return
            }
            // Read at once: the download's temporary file is the system's
            // to remove.
            let data = try Data(contentsOf: file)
            try? FileManager.default.removeItem(at: file)
            let url = indexURL
            let built = await Task.detached(priority: .utility) { () -> RetractionIndex? in
                let index = buildIndex(fromCSV: data)
                try? FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if let encoded = try? JSONEncoder().encode(index) {
                    try? encoded.write(to: url, options: .atomic)
                }
                return index
            }.value
            if let built, built.records > 0 {
                retractionIndex = built
            } else {
                indexError = "The Retraction Watch database could not be read."
            }
        } catch {
            indexError = error.localizedDescription
        }
    }

    /// The CSV folded into the index. Columns by header name, so a
    /// reordered file still reads.
    nonisolated static func buildIndex(fromCSV data: Data) -> RetractionIndex {
        let rows = parseCSV(data)
        guard let header = rows.first else {
            return RetractionIndex(updated: .now, records: 0, byDOI: [:], byTitle: [:])
        }
        func column(_ name: String) -> Int? {
            header.firstIndex { $0.trimmingCharacters(in: .whitespaces) == name }
        }
        guard let titleCol = column("Title"),
              let doiCol = column("OriginalPaperDOI"),
              let natureCol = column("RetractionNature") else {
            return RetractionIndex(updated: .now, records: 0, byDOI: [:], byTitle: [:])
        }
        let dateCol = column("RetractionDate")
        let noticeCol = column("RetractionDOI")
        let reasonCol = column("Reason")
        let paperDateCol = column("OriginalPaperDate")

        var byDOI: [String: [Notice]] = [:]
        var byTitle: [String: [RetractionIndex.TitledNotice]] = [:]
        var count = 0
        for row in rows.dropFirst() {
            func field(_ index: Int?) -> String {
                guard let index, index < row.count else { return "" }
                return row[index].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard let kind = noticeKind(field(natureCol)) else { continue }
            let reason = field(reasonCol)
                .split(separator: ";")
                .map { $0.trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "+")) }
                .filter { !$0.isEmpty }
                .joined(separator: "; ")
            let noticeDOI = cleanDOI(field(noticeCol))
            let notice = Notice(kind: kind,
                                date: isoDate(field(dateCol)),
                                reason: reason.isEmpty ? nil : reason,
                                noticeDOI: noticeDOI,
                                source: "Retraction Watch")
            count += 1
            if let doi = cleanDOI(field(doiCol)) {
                byDOI[doi, default: []].append(notice)
            }
            let title = normalizedTitle(field(titleCol))
            // Short titles ("Editorial", "Reply") would match anything.
            if title.count >= 24 {
                let year = isoDate(field(paperDateCol)).flatMap { Int($0.prefix(4)) }
                byTitle[title, default: []].append(.init(year: year, notice: notice))
            }
        }
        return RetractionIndex(updated: .now, records: count, byDOI: byDOI, byTitle: byTitle)
    }

    nonisolated private static func noticeKind(_ nature: String) -> Notice.Kind? {
        switch nature.lowercased() {
        case "retraction": .retraction
        case "expression of concern": .expressionOfConcern
        case "correction": .correction
        case "reinstatement": .reinstatement
        case "withdrawal", "withdrawn": .withdrawal
        default: nil
        }
    }

    /// "5/11/2026 0:00" → "2026-05-11".
    nonisolated private static func isoDate(_ raw: String) -> String? {
        let day = raw.split(separator: " ").first.map(String.init) ?? raw
        let parts = day.split(separator: "/").compactMap { Int($0) }
        guard parts.count == 3, parts[2] > 1000 else { return nil }
        return String(format: "%04d-%02d-%02d", parts[2], parts[0], parts[1])
    }

    nonisolated static func cleanDOI(_ raw: String?) -> String? {
        guard var doi = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !doi.isEmpty else { return nil }
        for prefix in ["https://doi.org/", "http://doi.org/", "https://dx.doi.org/",
                       "http://dx.doi.org/", "doi.org/", "doi:"] where doi.hasPrefix(prefix) {
            doi = String(doi.dropFirst(prefix.count))
        }
        // The database writes "unavailable" and the like where it has none.
        return doi.hasPrefix("10.") ? doi : nil
    }

    nonisolated static func normalizedTitle(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                  locale: Locale(identifier: "en_US_POSIX"))
        let kept = folded.map { $0.isLetter || $0.isNumber ? $0 : " " }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    /// RFC 4180: quoted fields may hold commas, doubled quotes and line
    /// breaks. Bytes, not Characters — 67 MB reads in a moment this way.
    nonisolated static func parseCSV(_ data: Data) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field: [UInt8] = []
        var inQuotes = false
        var index = data.startIndex
        let quote = UInt8(ascii: "\""), comma = UInt8(ascii: ","),
            newline = UInt8(ascii: "\n"), cr = UInt8(ascii: "\r")
        func endField() {
            row.append(String(decoding: field, as: UTF8.self))
            field.removeAll(keepingCapacity: true)
        }
        while index < data.endIndex {
            let byte = data[index]
            if inQuotes {
                if byte == quote {
                    let next = data.index(after: index)
                    if next < data.endIndex, data[next] == quote {
                        field.append(quote)
                        index = next
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(byte)
                }
            } else if byte == quote {
                inQuotes = true
            } else if byte == comma {
                endField()
            } else if byte == newline {
                endField()
                rows.append(row)
                row.removeAll(keepingCapacity: true)
            } else if byte != cr {
                field.append(byte)
            }
            index = data.index(after: index)
        }
        if !field.isEmpty || !row.isEmpty {
            endField()
            rows.append(row)
        }
        return rows
    }

    /// The database's notices for a work: by DOI, else by title with a
    /// year that agrees (within one) when both are known.
    static func indexNotices(doi: String?, title: String, year: Int?) -> [Notice] {
        guard isOn(retractionWatchKey) else { return [] }
        // A device without the database (the headset) reads the notices
        // the Mac found for the work.
        guard let index = retractionIndex else {
            return sharedKey(doi: doi, title: title).flatMap { shared[$0]?.notices } ?? []
        }
        if let doi = cleanDOI(doi), let hits = index.byDOI[doi] { return hits }
        let key = normalizedTitle(title)
        guard key.count >= 24, let hits = index.byTitle[key] else { return [] }
        return hits.filter { hit in
            guard let year, let paperYear = hit.year else { return true }
            return abs(year - paperYear) <= 1
        }.map(\.notice)
    }

    // MARK: The replication database (FORRT)

    /// FORRT's Library of Replication Attempts (FLoRA): original-paper DOI
    /// → how its replications came out. Mostly psychology and the social
    /// sciences; ~3,000 attempts, CC BY, refreshed with the same weekly
    /// beat as the retraction database.
    nonisolated struct ReplicationIndex: Codable, Sendable {
        nonisolated struct Tally: Codable, Sendable {
            var successful = 0
            var failed = 0
            var mixed = 0
        }
        var updated: Date
        var records: Int
        var byDOI: [String: Tally]
    }

    private static let replicationsURL = URL(string:
        "https://raw.githubusercontent.com/forrtproject/FReD-data/main/output/flora.csv")!

    nonisolated private static var replicationsIndexURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("EPUBs", isDirectory: true)
            .appendingPathComponent("Replications.json")
    }

    private(set) static var replicationIndex: ReplicationIndex?
    private static var replicationsLoaded = false
    private(set) static var isRefreshingReplications = false

    static func loadReplicationsIfNeeded() async {
        guard !replicationsLoaded else { return }
        replicationsLoaded = true
        let url = replicationsIndexURL
        let loaded = await Task.detached(priority: .utility) { () -> ReplicationIndex? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(ReplicationIndex.self, from: data)
        }.value
        if replicationIndex == nil { replicationIndex = loaded }
    }

    static func refreshReplicationsIfStale(force: Bool = false) async {
        guard isOn(replicationsKey), !isRefreshingReplications else { return }
        await loadReplicationsIfNeeded()
        if !force, let held = replicationIndex,
           Date.now.timeIntervalSince(held.updated) < 7 * 86_400 { return }
        isRefreshingReplications = true
        defer { isRefreshingReplications = false }
        var request = URLRequest(url: replicationsURL, timeoutInterval: 60)
        request.setValue(Self.userAgent,
                         forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return }
        let url = replicationsIndexURL
        let built = await Task.detached(priority: .utility) { () -> ReplicationIndex in
            let index = buildReplications(fromCSV: data)
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if index.records > 0, let encoded = try? JSONEncoder().encode(index) {
                try? encoded.write(to: url, options: .atomic)
            }
            return index
        }.value
        if built.records > 0 { replicationIndex = built }
    }

    nonisolated static func buildReplications(fromCSV data: Data) -> ReplicationIndex {
        let rows = parseCSV(data)
        guard let header = rows.first else {
            return ReplicationIndex(updated: .now, records: 0, byDOI: [:])
        }
        func column(_ name: String) -> Int? {
            header.firstIndex {
                $0.replacingOccurrences(of: "\u{FEFF}", with: "")
                    .trimmingCharacters(in: .whitespaces) == name
            }
        }
        guard let doiCol = column("doi_o"), let outcomeCol = column("outcome") else {
            return ReplicationIndex(updated: .now, records: 0, byDOI: [:])
        }
        let typeCol = column("type")
        var byDOI: [String: ReplicationIndex.Tally] = [:]
        var count = 0
        for row in rows.dropFirst() {
            guard doiCol < row.count, outcomeCol < row.count,
                  let doi = cleanDOI(row[doiCol]) else { continue }
            // Replications only — reproductions (re-running the original
            // data) answer a different question.
            if let typeCol, typeCol < row.count,
               row[typeCol].lowercased() != "replication" { continue }
            var tally = byDOI[doi] ?? ReplicationIndex.Tally()
            switch row[outcomeCol].lowercased() {
            case "successful": tally.successful += 1
            case "failed": tally.failed += 1
            case "mixed": tally.mixed += 1
            default: continue
            }
            byDOI[doi] = tally
            count += 1
        }
        return ReplicationIndex(updated: .now, records: count, byDOI: byDOI)
    }

    // MARK: Live answers per DOI

    private static var liveCacheURL: URL {
        supportFolder.appendingPathComponent("ReferenceStatus.json")
    }

    private static var liveCache: [String: Live] = {
        guard let data = try? Data(contentsOf: liveCacheURL),
              let stored = try? JSONDecoder().decode([String: Live].self, from: data)
        else { return [:] }
        return stored
    }()

    private static func persistLive() {
        try? FileManager.default.createDirectory(
            at: supportFolder, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(liveCache) {
            try? data.write(to: liveCacheURL, options: .atomic)
        }
    }

    static func cachedLive(doi: String?) -> Live? {
        guard let doi = cleanDOI(doi) else { return nil }
        return liveCache[doi] ?? shared[doi]?.live
    }

    /// Whether a DOI's live answers are missing or over a month old.
    static func needsLive(doi: String?) -> Bool {
        guard let doi = cleanDOI(doi),
              isOn(crossrefNoticesKey) || isOn(openAccessKey) || isOn(citationCountsKey)
        else { return false }
        guard let known = liveCache[doi] else { return true }
        return known.version != liveVersion
            || Date.now.timeIntervalSince(known.fetched) > 30 * 86_400
    }

    /// Asks the three live services about one DOI, together, and keeps
    /// the answer. Services switched off are skipped.
    @discardableResult
    static func checkLive(doi rawDOI: String?) async -> Live? {
        guard let doi = cleanDOI(rawDOI) else { return nil }
        async let work = isOn(crossrefNoticesKey) ? crossrefWork(doi) : nil
        async let access = isOn(openAccessKey) ? unpaywall(doi) : nil
        async let count = isOn(citationCountsKey) ? openCitationsCount(doi) : nil
        async let openAlex = isOn(openAlexKey) ? openAlexWork(doi) : nil
        async let tallies = isOn(sciteKey) ? sciteTallies(doi) : nil
        async let sciteNotes = isOn(sciteKey) ? sciteNotices(doi) : nil
        let (w, a, c, p) = await (work, access, count, openAlex)
        let (t, n) = await (tallies, sciteNotes)
        var live = liveCache[doi] ?? Live(fetched: .now)
        var notices: [Notice] = []
        if let w {
            notices = w.notices
            live.canonicalTitle = w.title.map(BibTeXParser.displayText)
            live.canonicalAuthors = w.authors.isEmpty ? nil : w.authors
            live.canonicalYear = w.year
            live.canonicalVenue = w.venue
            live.workType = w.type
            live.workSubtype = w.subtype
            live.hasPublishedVersion = w.hasPublishedVersion
            live.doiResolves = true
        } else if isOn(crossrefNoticesKey) {
            // Not a Crossref DOI (arXiv, Zenodo and DataCite DOIs are
            // not) — or no DOI at all: the DOI system itself answers.
            live.doiResolves = await doiExists(doi)
            if live.doiResolves == true {
                live.dataCiteType = await dataCiteType(doi)
            }
        }
        if let a {
            live.isOpenAccess = a.isOpen
            live.openAccessURL = a.url
        }
        if let c { live.citedBy = c }
        if let p {
            live.inTop1Percent = p.top1
            live.inTop10Percent = p.top10
            live.openAlexType = p.type
            live.openAlexRetracted = p.retracted
            live.topics = p.topics
            live.authors = p.authors
            live.citationsByYear = p.byYear
            if live.citedBy == nil { live.citedBy = p.citedBy }
            if live.openAccessURL == nil, let free = p.openAccessURL {
                live.openAccessURL = free
                live.isOpenAccess = true
            }
            if let abstract = p.abstract {
                live.abstract = abstract
                live.abstractSource = "OpenAlex"
            }
            if live.canonicalTitle == nil { live.canonicalTitle = p.title }
            if live.canonicalAuthors == nil, !p.authors.isEmpty {
                live.canonicalAuthors = p.authors.map(\.name)
            }
            if live.canonicalYear == nil { live.canonicalYear = p.year }
            if live.canonicalVenue == nil { live.canonicalVenue = p.venue }
            if p.retracted, !notices.contains(where: { $0.kind == .retraction }) {
                notices.append(Notice(kind: .retraction, date: nil, reason: nil,
                                      noticeDOI: nil, source: "OpenAlex"))
            }
        }
        if let t {
            live.sciteSupporting = t.supporting
            live.sciteContradicting = t.contradicting
            live.sciteMentioning = t.mentioning
        }
        for notice in n ?? [] where !notices.contains(where: {
            $0.kind == notice.kind
                && ($0.noticeDOI == nil || notice.noticeDOI == nil || $0.noticeDOI == notice.noticeDOI)
        }) {
            notices.append(notice)
        }
        if w != nil || p != nil || n != nil { live.notices = notices }
        live.version = liveVersion
        live.fetched = .now
        liveCache[doi] = live
        persistLive()
        return live
    }

    /// What Crossref's record says of the work: its `updated-by` notices
    /// (Retraction Watch's among them since January 2025), its type, and
    /// for a preprint whether a published version is linked.
    private struct CrossrefWork {
        var notices: [Notice]
        var type: String?
        var subtype: String?
        var hasPublishedVersion: Bool
        var title: String?
        var authors: [String] = []
        var year: Int?
        var venue: String?
    }

    private static func crossrefWork(_ doi: String) async -> CrossrefWork? {
        guard let encoded = doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://api.crossref.org/works/\(encoded)"),
              let message = (await json(from: url) as? [String: Any])?["message"] as? [String: Any]
        else { return nil }
        let relation = message["relation"] as? [String: Any] ?? [:]
        let published = (relation["is-preprint-of"] as? [Any])?.isEmpty == false
        let authors = (message["author"] as? [[String: Any]] ?? []).compactMap { author -> String? in
            let family = (author["family"] as? String) ?? (author["name"] as? String)
            guard let family, !family.isEmpty else { return nil }
            let given = (author["given"] as? String) ?? ""
            return given.isEmpty ? family : "\(given) \(family)"
        }
        let issued = ((message["issued"] as? [String: Any])?["date-parts"] as? [[Int]])?.first?.first
            ?? ((message["published"] as? [String: Any])?["date-parts"] as? [[Int]])?.first?.first
        return CrossrefWork(notices: crossrefNotices(in: message),
                            type: message["type"] as? String,
                            subtype: message["subtype"] as? String,
                            hasPublishedVersion: published,
                            title: (message["title"] as? [String])?.first,
                            authors: authors,
                            year: issued,
                            venue: (message["container-title"] as? [String])?.first)
    }

    /// The DOI system's own answer: does this DOI exist at all?
    private static func doiExists(_ doi: String) async -> Bool? {
        guard let encoded = doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://doi.org/api/handles/\(encoded)") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(Self.userAgent,
                         forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let code = object["responseCode"] as? Int else { return nil }
        // 1 found; 100 not found; anything else says nothing either way.
        switch code {
        case 1: return true
        case 100: return false
        default: return nil
        }
    }

    /// DataCite's general resource type, for the DOIs it registers.
    private static func dataCiteType(_ doi: String) async -> String? {
        guard let encoded = doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://api.datacite.org/dois/\(encoded)"),
              let object = await json(from: url) as? [String: Any],
              let attributes = (object["data"] as? [String: Any])?["attributes"] as? [String: Any],
              let types = attributes["types"] as? [String: Any]
        else { return nil }
        return types["resourceTypeGeneral"] as? String
    }

    /// What OpenAlex knows of the work, asked by DOI. A single work by
    /// DOI costs nothing on its 2026 pricing, so no key is needed; the
    /// reader's key, when set (Settings ▸ Cited Works), rides along.
    private struct OpenAlexWork {
        var top1: Bool
        var top10: Bool
        var type: String?
        var retracted: Bool
        var topics: [String]
        var authors: [Live.Author]
        var byYear: [Live.YearCount]
        var citedBy: Int?
        var openAccessURL: String?
        var abstract: String?
        var title: String?
        var year: Int?
        var venue: String?
    }

    private static func openAlexWork(_ doi: String) async -> OpenAlexWork? {
        let key = (UserDefaults.standard.string(forKey: "openAlexAPIKey") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fields = "type,is_retracted,citation_normalized_percentile,cited_by_count,"
            + "counts_by_year,primary_topic,topics,authorships,open_access,abstract_inverted_index,"
            + "display_name,publication_year,primary_location"
        guard let encoded = doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://api.openalex.org/works/doi:\(encoded)?select=\(fields)"
                            + (key.isEmpty ? "" : "&api_key=\(key)")),
              let object = await json(from: url) as? [String: Any]
        else { return nil }
        let percentile = object["citation_normalized_percentile"] as? [String: Any]
        var topics: [String] = []
        if let primary = (object["primary_topic"] as? [String: Any])?["display_name"] as? String {
            topics.append(primary)
        }
        for topic in object["topics"] as? [[String: Any]] ?? [] {
            if let name = topic["display_name"] as? String, !topics.contains(name) {
                topics.append(name)
            }
        }
        let authors = (object["authorships"] as? [[String: Any]] ?? []).compactMap { authorship -> Live.Author? in
            guard let author = authorship["author"] as? [String: Any],
                  let name = author["display_name"] as? String else { return nil }
            let orcid = (author["orcid"] as? String)?
                .replacingOccurrences(of: "https://orcid.org/", with: "")
            return Live.Author(name: name, orcid: orcid)
        }
        let byYear = (object["counts_by_year"] as? [[String: Any]] ?? []).compactMap { entry -> Live.YearCount? in
            guard let year = entry["year"] as? Int, let count = entry["cited_by_count"] as? Int
            else { return nil }
            return Live.YearCount(year: year, count: count)
        }.sorted { $0.year > $1.year }
        let access = object["open_access"] as? [String: Any]
        return OpenAlexWork(
            top1: percentile?["is_in_top_1_percent"] as? Bool ?? false,
            top10: percentile?["is_in_top_10_percent"] as? Bool ?? false,
            type: object["type"] as? String,
            retracted: object["is_retracted"] as? Bool ?? false,
            topics: Array(topics.prefix(4)),
            authors: authors,
            byYear: byYear,
            citedBy: object["cited_by_count"] as? Int,
            openAccessURL: (access?["is_oa"] as? Bool) == true ? access?["oa_url"] as? String : nil,
            abstract: (object["abstract_inverted_index"] as? [String: [Int]]).flatMap(abstractText),
            title: object["display_name"] as? String,
            year: object["publication_year"] as? Int,
            venue: ((object["primary_location"] as? [String: Any])?["source"] as? [String: Any])?["display_name"] as? String)
    }

    /// OpenAlex keeps abstracts as word → positions; laid back in order.
    nonisolated static func abstractText(_ inverted: [String: [Int]]) -> String? {
        var words: [(Int, String)] = []
        for (word, places) in inverted {
            for place in places { words.append((place, word)) }
        }
        guard !words.isEmpty else { return nil }
        return words.sorted { $0.0 < $1.0 }.map(\.1).joined(separator: " ")
    }

    /// scite's tally of how later papers cite the work.
    private static func sciteTallies(_ doi: String) async -> (supporting: Int, contradicting: Int, mentioning: Int)? {
        guard let encoded = doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://api.scite.ai/tallies/\(encoded)"),
              let object = await json(from: url) as? [String: Any]
        else { return nil }
        func count(_ key: String) -> Int { (object[key] as? Int) ?? 0 }
        return (count("supporting"), count("contradicting"), count("mentioning"))
    }

    /// scite's editorial notices for the work — retractions, corrections,
    /// expressions of concern — gathered from publishers and PubMed.
    private static func sciteNotices(_ doi: String) async -> [Notice]? {
        guard let encoded = doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://api.scite.ai/papers/\(encoded)"),
              let object = await json(from: url) as? [String: Any]
        else { return nil }
        var notices = (object["editorialNotices"] as? [[String: Any]] ?? []).compactMap { entry -> Notice? in
            let status = (entry["status"] as? String ?? "").lowercased()
            let kind: Notice.Kind
            if status.contains("retract") { kind = .retraction }
            else if status.contains("withdraw") { kind = .withdrawal }
            else if status.contains("concern") { kind = .expressionOfConcern }
            else if status.contains("correct") || status.contains("erratum") { kind = .correction }
            else { return nil }
            let date = (entry["date"] as? String).map { String($0.prefix(10)) }
            return Notice(kind: kind, date: date, reason: nil,
                          noticeDOI: cleanDOI(entry["noticeDoi"] as? String), source: "scite")
        }
        if (object["retracted"] as? Bool) == true, !notices.contains(where: { $0.kind == .retraction }) {
            notices.append(Notice(kind: .retraction, date: nil, reason: nil,
                                  noticeDOI: nil, source: "scite"))
        }
        return notices
    }

    private static func crossrefNotices(in message: [String: Any]) -> [Notice] {
        // `updated-by` carries the notices registered against the work.
        // Some publishers instead mark the original itself, in its own
        // `update-to`, pointing at its own DOI — read those too. (An
        // `update-to` naming ANOTHER DOI means this record is itself a
        // notice, and says nothing of this work's standing.)
        let own = cleanDOI(message["DOI"] as? String)
        let selfMarked = (message["update-to"] as? [[String: Any]] ?? []).filter {
            own != nil && cleanDOI($0["DOI"] as? String) == own
        }
        let updates = (message["updated-by"] as? [[String: Any]] ?? []) + selfMarked
        var seen = Set<String>()
        return updates.compactMap { update -> Notice? in
            let type = (update["type"] as? String ?? "").lowercased()
            let kind: Notice.Kind
            switch type {
            case "retraction", "partial_retraction", "removal": kind = .retraction
            case "expression_of_concern": kind = .expressionOfConcern
            case "withdrawal": kind = .withdrawal
            case "correction", "erratum", "corrigendum", "addendum": kind = .correction
            case "reinstatement": kind = .reinstatement
            case "new_version", "new_edition": kind = .newVersion
            default: return nil
            }
            let parts = ((update["updated"] as? [String: Any])?["date-parts"] as? [[Int]])?.first ?? []
            let date = parts.count == 3
                ? String(format: "%04d-%02d-%02d", parts[0], parts[1], parts[2])
                : parts.first.map { String($0) }
            let source = (update["source"] as? String) == "retraction-watch"
                ? "Retraction Watch via Crossref" : "Crossref"
            let noticeDOI = cleanDOI(update["DOI"] as? String)
            // The same notice, registered twice, is one notice.
            guard seen.insert("\(kind.rawValue)|\(noticeDOI ?? date ?? "")").inserted else { return nil }
            return Notice(kind: kind, date: date, reason: nil,
                          noticeDOI: noticeDOI == own ? nil : noticeDOI, source: source)
        }
    }

    private static func unpaywall(_ doi: String) async -> (isOpen: Bool, url: String?)? {
        guard let encoded = doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://api.unpaywall.org/v2/\(encoded)?email=\(contactEmail)"),
              let object = await json(from: url) as? [String: Any],
              let isOpen = object["is_oa"] as? Bool
        else { return nil }
        let best = object["best_oa_location"] as? [String: Any]
        let link = (best?["url_for_pdf"] as? String) ?? (best?["url"] as? String)
        return (isOpen, link)
    }

    private static func openCitationsCount(_ doi: String) async -> Int? {
        guard let encoded = doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://api.opencitations.net/index/v2/citation-count/doi:\(encoded)"),
              let rows = await json(from: url) as? [[String: Any]],
              let count = rows.first?["count"] as? String
        else { return nil }
        return Int(count)
    }

    private static func json(from url: URL) async -> Any? {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(Self.userAgent,
                         forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    // MARK: Cited works, shared with the other devices

    /// Everything known of one cited work, gathered on the Mac and read
    /// by every device: its live answers, every notice (the database's
    /// and the services' together), its replications, and its abstract.
    /// The headset asks no service itself — it reads this.
    nonisolated struct CitedWork: Codable, Sendable {
        var live: Live?
        var notices: [Notice] = []
        var replication: ReplicationIndex.Tally?
        var abstract: String?
        var abstractSource: String?
        /// Semantic Scholar's one-line summary, when it has one.
        var summary: String?
        var venue: String?
        var checked: Date
        /// The master list: the work's DOI (found by its title when the
        /// citing paper gave none), its authoritative title, authors and
        /// year, and the library papers that cite it.
        var doi: String?
        var title: String?
        var authors: [String]?
        var year: Int?
        var citedBy: [String]?
    }

    /// The community folder's copy: `origami-cited-works.json`.
    nonisolated struct CitedWorks: Codable, Sendable {
        var modified: Date
        var works: [String: CitedWork]
    }

    nonisolated static let sharedFileName = "origami-cited-works.json"

    /// The records read from the community folder, by work key.
    private(set) static var shared: [String: CitedWork] = [:]
    private(set) static var sharedModified: Date?

    /// A work's key in the shared record: its DOI, or its folded title
    /// for a reference that carries none.
    nonisolated static func sharedKey(doi: String?, title: String) -> String? {
        if let doi = cleanDOI(doi) { return doi }
        let folded = normalizedTitle(title)
        return folded.count >= 12 ? "title:" + folded : nil
    }

    /// The shared record of one work, when the Mac has written one.
    static func sharedWork(doi: String?, title: String) -> CitedWork? {
        sharedKey(doi: doi, title: title).flatMap { shared[$0] }
    }

    /// What this device knows of a work, folded into one record — the
    /// Mac's side of the shared file.
    static func record(doi: String?, title: String, year: Int?,
                       abstract: String?, abstractSource: String?,
                       summary: String?, venue: String?) -> CitedWork {
        let live = cachedLive(doi: doi)
        var work = CitedWork(live: live,
                             notices: notices(doi: doi, title: title, year: year),
                             replication: cleanDOI(doi).flatMap { replicationIndex?.byDOI[$0] },
                             abstract: abstract ?? live?.abstract,
                             abstractSource: abstract != nil ? abstractSource : live?.abstractSource,
                             summary: summary, venue: venue, checked: .now)
        // The abstract rides once, in the record, not twice.
        work.live?.abstract = nil
        work.doi = cleanDOI(doi)
        // The registry's title when there is one; the citing paper's
        // otherwise, so every entry in the master list has a name.
        work.title = live?.canonicalTitle
            ?? (title.isEmpty ? nil : BibTeXParser.displayText(title))
        work.authors = live?.canonicalAuthors
        work.year = live?.canonicalYear ?? year
        if work.venue == nil { work.venue = live?.canonicalVenue }
        return work
    }

    /// The file's own date when last read, so an unchanged file is not
    /// decoded again on every beat.
    private static var sharedFileDate: Date?

    /// Reads the community folder's record, coordinated with iCloud —
    /// only when the file has changed since it was last read.
    static func adoptShared(from folder: URL?) async {
        guard let folder else { return }
        let url = folder.appendingPathComponent(sharedFileName)
        let known = sharedFileDate
        let read = await Task.detached(priority: .utility) { () -> (CitedWorks, Date?)? in
            let scoped = folder.startAccessingSecurityScopedResource()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let date, date == known { return nil }
            var data: Data?
            var failure: NSError?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &failure) { at in
                data = try? Data(contentsOf: at)
            }
            guard let data else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return (try? decoder.decode(CitedWorks.self, from: data)).map { ($0, date) }
        }.value
        guard let (works, date) = read else { return }
        sharedFileDate = date
        guard works.modified != sharedModified else { return }
        shared = works.works
        sharedModified = works.modified
    }

    /// Writes the record to the community folder, coordinated. The Mac
    /// is its only writer; the whole set is written each time.
    nonisolated static func publish(_ works: [String: CitedWork], to folder: URL) async {
        let url = folder.appendingPathComponent(sharedFileName)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(CitedWorks(modified: .now, works: works)) else { return }
        await Task.detached(priority: .utility) {
            let scoped = folder.startAccessingSecurityScopedResource()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            var failure: NSError?
            NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing,
                                           error: &failure) { at in
                try? data.write(to: at, options: .atomic)
            }
        }.value
    }

    /// The Mac's own copy of what it last published, so a pass adds to
    /// it rather than starting again.
    static func adoptOwn(_ works: [String: CitedWork]) {
        shared = works
        sharedModified = .now
    }

    /// The one warning a small card in the room carries: its gravest
    /// trust keyword (Retracted, Withdrawn, Not Replicated…), then its
    /// gravest caution (Expression of Concern…). Nil for a sound work.
    static func standingWarning(doi: String?, title: String, year: Int?) -> Mark? {
        let pills = marks(for: MarkInput(doi: doi, title: title, year: year)).filter(\.pill)
        return pills.first { $0.tone == .alarm } ?? pills.first { $0.tone == .caution }
    }

    // MARK: The keywords

    /// Every notice the database and Crossref hold for the work, the
    /// same notice from both sources counted once.
    static func notices(doi: String?, title: String, year: Int?) -> [Notice] {
        var all = indexNotices(doi: doi, title: title, year: year)
        if isOn(crossrefNoticesKey) {
            for notice in cachedLive(doi: doi)?.notices ?? [] {
                let duplicate = all.contains { held in
                    held.kind == notice.kind
                        && (held.noticeDOI == nil || notice.noticeDOI == nil
                            || held.noticeDOI == notice.noticeDOI)
                }
                if !duplicate { all.append(notice) }
            }
        }
        return all
    }

    /// What the page knows of one entry beyond its DOI — the paper's own
    /// facts, worked out by the References page.
    struct MarkInput {
        var doi: String?
        var title: String
        var year: Int?
        var inLibrary = false
        /// The BibTeX entry type and fields (journal, eprint, url…).
        var entryType = ""
        var fields: [String: String] = [:]
        /// How many of the paper's OTHER references cite this one.
        var citedByNeighbours = 0
        /// Whether the list is small, so two neighbours already count.
        var smallList = false
        /// How often the paper cites it in its text.
        var citedInText = 0
        /// Shares an author with the paper.
        var isSelfCitation = false
        /// No service could find a work that should be findable.
        var notFound = false
    }

    /// The keywords under an entry, in five groups: trust (pills), then
    /// importance, kind, use, and access as plain text.
    static func marks(for input: MarkInput) -> [Mark] {
        var marks: [Mark] = []
        let notices = notices(doi: input.doi, title: input.title, year: input.year)
        let live = cachedLive(doi: input.doi)
        func detail(_ notice: Notice) -> String {
            var parts = [notice.source]
            if let date = notice.date { parts.append(date) }
            if let reason = notice.reason { parts.append(reason) }
            return parts.joined(separator: " · ")
        }

        // 1. Trust — pills.
        let reinstated = notices.contains { $0.kind == .reinstatement }
        if let retraction = notices.first(where: { $0.kind == .retraction }) {
            marks.append(Mark(text: reinstated ? "Retracted, Reinstated" : "Retracted",
                              tone: reinstated ? .caution : .alarm,
                              detail: detail(retraction), pill: true))
        }
        if let withdrawal = notices.first(where: { $0.kind == .withdrawal }) {
            marks.append(Mark(text: "Withdrawn", tone: .alarm, detail: detail(withdrawal), pill: true))
        }
        if let concern = notices.first(where: { $0.kind == .expressionOfConcern }) {
            marks.append(Mark(text: "Expression of Concern", tone: .caution,
                              detail: detail(concern), pill: true))
        }
        let corrections = notices.filter { $0.kind == .correction }
        if let first = corrections.first {
            marks.append(Mark(text: corrections.count > 1 ? "Corrected \(corrections.count)×" : "Corrected",
                              tone: .quiet, detail: detail(first), pill: true))
        }
        if isOn(replicationsKey), let doi = cleanDOI(input.doi),
           let tally = replicationIndex?.byDOI[doi] ?? shared[doi]?.replication {
            let attempts = tally.successful + tally.failed + tally.mixed
            let account = "\(attempts) replication attempt\(attempts == 1 ? "" : "s"): \(tally.successful) successful, \(tally.failed) failed, \(tally.mixed) mixed (FORRT)"
            if tally.failed == 0 && tally.mixed == 0 {
                marks.append(Mark(text: "Replicated", tone: .good, detail: account, pill: true))
            } else if tally.successful == 0 && tally.mixed == 0 {
                marks.append(Mark(text: "Not Replicated", tone: .alarm, detail: account, pill: true))
            } else {
                marks.append(Mark(text: "Replication Mixed", tone: .caution, detail: account, pill: true))
            }
        }
        if let version = notices.first(where: { $0.kind == .newVersion }) {
            marks.append(Mark(text: "New Version", tone: .info,
                              detail: detail(version), pill: true))
        }
        // A preprint shows as one — unless its reviewed version exists,
        // and then nothing shows.
        if isPreprint(input, live: live), live?.hasPublishedVersion != true {
            marks.append(Mark(text: "Preprint", tone: .info,
                              detail: "Not yet peer reviewed", pill: true))
        }
        if live?.doiResolves == false {
            // Grey: most often a typo or a gap in the indexes, rarely
            // a concern — it should not shout.
            marks.append(Mark(text: "Unverified", tone: .quiet,
                              detail: "This DOI does not exist — the reference may be mistyped or invented",
                              pill: true))
        } else if input.notFound {
            marks.append(Mark(text: "Unverified", tone: .quiet,
                              detail: "No scholarly service could find this work", pill: true))
        }

        // 2. Importance — what it is, in words. A retracted or withdrawn
        // work earns none of these: its fame is not a recommendation.
        let discredited = marks.contains { $0.tone == .alarm }
        let neighbours = input.citedByNeighbours
        if !discredited, neighbours >= 3 || (input.smallList && neighbours >= 2) {
            marks.append(Mark(text: "Foundational", tone: .positive,
                              detail: "Cited by \(neighbours) of this paper's other references"))
        }
        if discredited {
            // Counted below, plainly; no rank.
        } else if live?.inTop1Percent == true {
            marks.append(Mark(text: "Top 1% Cited", tone: .positive,
                              detail: "Among the most cited 1% of its field and year (OpenAlex)"))
        } else if live?.inTop10Percent == true {
            marks.append(Mark(text: "Top 10% Cited", tone: .quiet,
                              detail: "Among the most cited 10% of its field and year (OpenAlex)"))
        }
        let age = input.year.map { Calendar.current.component(.year, from: .now) - $0 } ?? 0
        if !discredited, age >= 25,
           live?.inTop10Percent == true || (live?.citedBy ?? 0) >= 1000 {
            marks.append(Mark(text: "Classic", tone: .quiet,
                              detail: "\(age) years old and still widely cited"))
        }
        if isOn(citationCountsKey), let cited = live?.citedBy, cited > 0 {
            marks.append(Mark(text: "Cited \(cited.formatted())×", tone: .quiet,
                              detail: "Works citing it, per OpenCitations"))
        }
        // How it is cited: later papers' statements that support it or
        // dispute it. Disputed more than supported reads as a caution.
        if isOn(sciteKey), let supporting = live?.sciteSupporting,
           let contradicting = live?.sciteContradicting, supporting + contradicting > 0 {
            let mentioning = live?.sciteMentioning ?? 0
            marks.append(Mark(
                text: "Supported \(supporting) · Disputed \(contradicting)",
                tone: contradicting > supporting && contradicting >= 3 ? .caution : .quiet,
                detail: "Citing statements, per scite: \(supporting) supporting, \(contradicting) contradicting, \(mentioning) mentioning"))
        }

        // 3. Kind — a word.
        if let kind = kind(input, live: live) {
            marks.append(Mark(text: kind, tone: .quiet))
        }

        // 4. Use in this paper.
        if input.citedInText >= 3 {
            marks.append(Mark(text: "Key", tone: .quiet,
                              detail: "Cited \(input.citedInText) times in this paper"))
        }
        if input.isSelfCitation {
            marks.append(Mark(text: "Self", tone: .quiet,
                              detail: "Shares an author with this paper"))
        }

        // 5. Access.
        if input.inLibrary {
            marks.append(Mark(text: "In Library", tone: .positive,
                              detail: "This work is on your shelf"))
        }
        if isOn(openAccessKey), live?.isOpenAccess == true {
            marks.append(Mark(text: "Open Access", tone: .quiet,
                              detail: live?.openAccessURL ?? "A free legal copy exists (Unpaywall)"))
        }
        return marks.map { mark in
            var explained = mark
            explained.meaning = meaning(of: mark, input: input)
            return explained
        }
    }

    /// Why a keyword stands under the work, for the reader who asks.
    private static func meaning(of mark: Mark, input: MarkInput) -> String {
        switch mark.text {
        case "Retracted":
            return "The paper has been formally retracted: its findings should not be relied on or built upon."
        case "Retracted, Reinstated":
            return "The paper was retracted and later reinstated; read the notices before relying on it."
        case "Withdrawn":
            return "The paper was withdrawn by its authors or publisher and is no longer part of the record."
        case "Expression of Concern":
            return "The publisher has warned that the paper's reliability is in question; an investigation may be under way."
        case "Replicated":
            return "Later studies repeated this work and found the same result."
        case "Not Replicated":
            return "Later studies repeated this work and did not find the same result."
        case "Replication Mixed":
            return "Later attempts to repeat this work disagree: some found the result, some did not."
        case "Preprint":
            return "Shared before peer review, and not yet published in a reviewed version."
        case "New Version":
            return "A newer version of this work has been registered; the one cited may be out of date."
        case "Unverified":
            return "This reference could not be confirmed to exist. It may be mistyped, or invented; check it before relying on it."
        case "Foundational":
            return "\(input.citedByNeighbours) of this paper's other references cite it: the work this area grew from."
        case "Top 1% Cited":
            return "Among the most cited 1% of works in its field and year."
        case "Top 10% Cited":
            return "Among the most cited 10% of works in its field and year."
        case "Classic":
            return "Decades old and still widely cited."
        case "Key":
            return "This paper cites it \(input.citedInText) times: central to its argument."
        case "Self":
            return "It shares an author with this paper: a self-citation."
        case "In Library":
            return "It is on your shelf."
        case "Open Access":
            return "A free, legal copy can be read online."
        case "Data": return "A dataset rather than a paper."
        case "Software": return "Software rather than a paper."
        case "Review": return "A review: it summarises other work rather than reporting new findings."
        case "Meta-analysis": return "A meta-analysis: it pools the results of many studies."
        case "Book": return "A book."
        case "Chapter": return "A chapter in a book."
        case "Thesis": return "A thesis or dissertation."
        case "Report": return "A report, not a peer-reviewed paper."
        case "Standard": return "A published standard."
        case "Web": return "A web page."
        case "Video": return "A video or other audiovisual work."
        default:
            if mark.text.hasPrefix("Corrected") {
                return "The publisher has issued a correction to this paper."
            }
            if mark.text.hasPrefix("Cited ") {
                return "How many works cite it."
            }
            if mark.text.hasPrefix("Supported ") {
                return "How later papers cite it: statements that support its findings, and statements that dispute them (scite)."
            }
            return ""
        }
    }

    // MARK: The reader's own word

    /// Marks the reader has removed, by work — they may know better than
    /// the indexes (an Unverified reference they hold in their hands).
    /// Kept on this Mac: work key → mark ids.
    private static let removedKey = "referenceMarksRemoved"

    /// A work's keys for removals: its DOI and its folded title, both —
    /// so a removal holds in every document that cites the work, whether
    /// that document's entry carries the DOI or only the title, and after
    /// a lookup finds the DOI later.
    static func workKeys(doi: String?, title: String) -> [String] {
        var keys: [String] = []
        if let doi = cleanDOI(doi) { keys.append(doi) }
        let folded = normalizedTitle(title)
        if folded.count >= 12 { keys.append("title:" + folded) }
        return keys
    }

    /// A mark's id for removals — "Corrected 2×" and "Corrected" are one.
    static func markID(_ mark: Mark) -> String {
        mark.text.hasPrefix("Corrected") ? "Corrected" : mark.text
    }

    private static var removedStore: [String: [String]] {
        get { UserDefaults.standard.dictionary(forKey: removedKey) as? [String: [String]] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: removedKey) }
    }

    /// What the reader removed for the work, under any of its keys.
    static func removedMarks(for keys: [String]) -> Set<String> {
        let all = removedStore
        return keys.reduce(into: Set<String>()) { $0.formUnion(all[$1] ?? []) }
    }

    static func removeMark(_ mark: Mark, for keys: [String]) {
        var all = removedStore
        for key in keys {
            var marks = Set(all[key] ?? [])
            marks.insert(markID(mark))
            all[key] = marks.sorted()
        }
        removedStore = all
    }

    static func restoreMarks(for keys: [String]) {
        var all = removedStore
        for key in keys { all[key] = nil }
        removedStore = all
    }

    /// The marks less those the reader removed.
    static func visible(_ marks: [Mark], for keys: [String]) -> [Mark] {
        let removed = removedMarks(for: keys)
        return removed.isEmpty ? marks : marks.filter { !removed.contains(markID($0)) }
    }

    /// Preprint servers' DOI prefixes: arXiv, bioRxiv/medRxiv, PsyArXiv
    /// and the OSF family, Research Square, Preprints.org, SSRN.
    private static let preprintPrefixes = ["10.48550/", "10.1101/", "10.31234/", "10.31219/",
                                           "10.31235/", "10.21203/", "10.20944/", "10.2139/ssrn"]

    private static func isPreprint(_ input: MarkInput, live: Live?) -> Bool {
        if live?.workSubtype == "preprint" || live?.openAlexType == "preprint"
            || live?.dataCiteType == "Preprint" { return true }
        if let doi = cleanDOI(input.doi), preprintPrefixes.contains(where: doi.hasPrefix) {
            return true
        }
        let journal = (input.fields["journal"] ?? "").lowercased()
        if journal.contains("arxiv") || journal.contains("preprint") { return true }
        return (input.fields["archiveprefix"] ?? input.fields["eprinttype"] ?? "")
            .lowercased() == "arxiv"
    }

    /// The work's kind in a word, when it is not a plain paper.
    private static func kind(_ input: MarkInput, live: Live?) -> String? {
        let title = input.title.lowercased()
        if title.contains("meta-analysis") || title.contains("meta analysis") { return "Meta-analysis" }
        if live?.openAlexType == "review" || title.contains("systematic review")
            || title.contains("literature review") || title.hasPrefix("a review of")
            || title.hasPrefix("a survey of") || title.contains("a survey on") {
            return "Review"
        }
        switch live?.workType {
        case "dataset": return "Data"
        case "book", "monograph", "edited-book", "reference-book": return "Book"
        case "book-chapter", "book-part", "book-section": return "Chapter"
        case "dissertation": return "Thesis"
        case "report": return "Report"
        case "standard": return "Standard"
        default: break
        }
        if live?.openAlexType == "dataset" { return "Data" }
        switch live?.dataCiteType {
        case "Dataset": return "Data"
        case "Software", "ComputationalNotebook": return "Software"
        case "Book": return "Book"
        case "BookChapter": return "Chapter"
        case "Dissertation": return "Thesis"
        case "Report": return "Report"
        case "Audiovisual": return "Video"
        default: break
        }
        switch input.entryType.lowercased() {
        case "dataset", "data": return "Data"
        case "software": return "Software"
        case "book", "mvbook": return "Book"
        case "inbook", "incollection", "bookinbook": return "Chapter"
        case "phdthesis", "mastersthesis", "thesis": return "Thesis"
        case "techreport", "report": return "Report"
        case "online", "electronic", "www": return "Web"
        case "misc":
            let hasVenue = ["journal", "booktitle", "publisher", "howpublished"]
                .contains { !(input.fields[$0] ?? "").isEmpty }
            return input.fields["url"] != nil && !hasVenue ? "Web" : nil
        default: return nil
        }
    }
}
