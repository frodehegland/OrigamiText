import Foundation

/// What the cited works themselves cite — the second-order references
/// that let the Maps grow longer chains: an EPUB, the papers it cites,
/// and the papers THOSE cite. Fetched politely from the scholarly
/// services (verified live, August 2026):
///
///  - Semantic Scholar `/paper/…/references` — the cited papers with
///    their metadata inline, one call;
///  - OpenAlex `referenced_works` + a batch resolve, 50 ids a call —
///    used when the reader holds their free key;
///  - Crossref's publisher-deposited `reference` arrays — broad but
///    patchy, the last resort.
///
/// Results — misses included — cache to one JSON beside the unpacked
/// books, and mirror into the community folder so the Vision Pro (and
/// any other Mac) reads the same graph without crawling: the Mac is
/// the research assistant, the headset the reading room.
@MainActor
enum CitationGraph {

    /// The same master switch and key as the citation card's lookups
    /// (CitationLookup, macOS) — the keys spelled out so this file
    /// compiles on targets without it.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "lookupCitedWorks") as? Bool ?? true
    }

    private static var openAlexAPIKey: String {
        (UserDefaults.standard.string(forKey: "openAlexAPIKey") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One work a cited paper itself cites.
    struct CitedRef: Codable, Sendable, Hashable {
        var title: String
        var authors: String
        var year: Int?
        var doi: String?
    }

    /// A cited work's own reference list, cached verbatim. `found`
    /// false is the remembered miss — retried only after a rest.
    struct Entry: Codable, Sendable {
        var doi: String?
        var references: [CitedRef]
        var source: String
        var fetched: Date
        var found: Bool
        /// Every service was asked and their lists folded together
        /// (`completeReferences`) — not just the first that answered.
        /// Absent in entries written before it existed.
        var complete: Bool? = nil
        /// Cited works known only by DOI (OpenCitations) — kept apart from
        /// `references`, whose readers expect a title on every entry.
        var citedDOIs: [String]? = nil
    }

    private static let missRetryDays = 7.0

    /// The node key for a cited work — EXACTLY the Map's cited-card
    /// key, so the graph and the space name the same node.
    nonisolated static func key(title: String, author: String) -> String {
        (title + "|" + author).lowercased().replacingOccurrences(of: " ", with: "")
    }

    // MARK: The cache, and its mirror in the community folder

    private static var cacheURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("EPUBs", isDirectory: true)
            .appendingPathComponent("CitationGraph.json")
    }

    nonisolated private static let mirrorName = "origami-citation-graph.json"

    /// The community folder, when one is chosen — the cache mirrors
    /// there after fetches, and unknown entries are adopted from there
    /// on scans. Callers must hold the folder's security scope.
    static var mirrorFolder: URL?

    private static var cache: [String: Entry] = {
        guard let data = try? Data(contentsOf: cacheURL),
              let stored = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return [:] }
        return stored
    }()

    private static func persist() {
        try? FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(cache) else { return }
        try? data.write(to: cacheURL, options: .atomic)
        if let folder = mirrorFolder {
            try? data.write(to: folder.appendingPathComponent(mirrorName),
                            options: .atomic)
        }
    }

    /// The mirror file read and decoded — the file half of adoptMirror,
    /// nonisolated so a startup scan can read it off the main actor
    /// (the folder lives in iCloud; the read may wait on a download).
    nonisolated static func mirrorEntries(from folder: URL) -> [String: Entry]? {
        let url = folder.appendingPathComponent(mirrorName)
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return nil }
        return stored
    }

    /// Folds the community folder's graph into this device's — entries
    /// it lacks, and fresher answers for ones it holds. How a device
    /// that never fetches (the Vision Pro) still knows the graph.
    static func adoptMirror(from folder: URL) {
        guard let stored = mirrorEntries(from: folder) else { return }
        adopt(stored)
    }

    /// The fold half, on the main actor — for callers that already
    /// read the mirror elsewhere.
    static func adopt(_ stored: [String: Entry]) {
        var changed = false
        for (key, entry) in stored {
            if let known = cache[key] {
                if entry.fetched > known.fetched, entry.found || !known.found {
                    cache[key] = entry
                    changed = true
                }
            } else {
                cache[key] = entry
                changed = true
            }
        }
        if changed {
            // Persist locally only — writing the mirror back here would
            // ping-pong timestamps between devices.
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if let data = try? encoder.encode(cache) {
                try? FileManager.default.createDirectory(
                    at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: cacheURL, options: .atomic)
            }
        }
    }

    /// What the cache already knows — hits and remembered misses alike.
    static func cached(forKey key: String) -> Entry? {
        cache[key]
    }

    /// How many works the graph holds answers for.
    static var knownCount: Int {
        cache.values.filter(\.found).count
    }

    // MARK: The fetch

    /// One request a second, whoever is asking — the services' shared
    /// pools are a commons.
    private static var lastRequest = Date.distantPast

    private static func politePause() async {
        let elapsed = Date.now.timeIntervalSince(lastRequest)
        if elapsed < 1.0 {
            try? await Task.sleep(for: .seconds(1.0 - elapsed))
        }
        lastRequest = .now
    }

    /// The work's own references — from the cache when it answers,
    /// from the services once otherwise. Nil when lookups are off.
    @discardableResult
    static func references(title: String, author: String, year: Int?,
                           doi: String?) async -> Entry? {
        guard isEnabled else { return nil }
        let key = key(title: title, author: author)
        if let known = cache[key] {
            if known.found { return known }
            if Date.now.timeIntervalSince(known.fetched) < missRetryDays * 86_400 {
                return known
            }
        }

        var entry: Entry?
        entry = await semanticScholar(doi: doi, title: title, year: year)
        if entry == nil {
            entry = await openAlex(doi: doi, title: title, year: year)
        }
        if entry == nil, let doi {
            entry = await crossref(doi: doi)
        }

        let stored = entry ?? Entry(doi: doi, references: [], source: "",
                                    fetched: .now, found: false)
        cache[key] = stored
        persist()
        return stored
    }

    /// Whether the work's list was gathered from every service, recently.
    static func isComplete(key: String) -> Bool {
        guard let known = cache[key], known.complete == true else { return false }
        // A work no service could answer is asked again sooner.
        let days: Double = known.found ? 30 : 3
        return Date.now.timeIntervalSince(known.fetched) < days * 86_400
    }

    /// The work's references from EVERY service, folded into one list —
    /// for the References map, which must see all of a work's
    /// references to tell which of its neighbours it cites. Each service
    /// alone misses some: Semantic Scholar drops unresolved entries,
    /// Crossref holds only what the publisher deposited, OpenAlex (with
    /// the reader's key) resolves others again. Misses are asked again
    /// here, whatever their age — the reader asked.
    @discardableResult
    static func completeReferences(title: String, author: String, year: Int?,
                                   doi: String?) async -> Entry? {
        guard isEnabled else { return nil }
        let key = key(title: title, author: author)
        if isComplete(key: key) { return cache[key] }

        var parts: [Entry] = []
        if let answer = await semanticScholar(doi: doi, title: title, year: year) {
            parts.append(answer)
        }
        if let answer = await openAlex(doi: doi, title: title, year: year) {
            parts.append(answer)
        }
        let resolvedDOI = doi ?? parts.compactMap(\.doi).first
        if let resolvedDOI, let answer = await crossref(doi: resolvedDOI) {
            parts.append(answer)
        }

        // Folded across services, never within one: a single list may
        // hold distinct works under one name (Crossref's "Proc. …"
        // volume titles), and those must all stand.
        var references: [CitedRef] = []
        var seenDOIs = Set<String>()
        var seenTitles = Set<String>()
        for part in parts {
            var partTitles = Set<String>()
            for reference in part.references {
                let folded = normalize(reference.title) + "|" + (reference.year.map(String.init) ?? "")
                if let doi = reference.doi?.lowercased(), !doi.isEmpty {
                    guard seenDOIs.insert(doi).inserted else { continue }
                } else if folded.count >= 24, seenTitles.contains(folded) {
                    continue
                }
                partTitles.insert(folded)
                references.append(reference)
            }
            seenTitles.formUnion(partTitles)
        }
        // OpenCitations: the cited works by DOI — keyless, and present
        // where the publisher deposited open references.
        var citedDOIs: [String] = []
        if let resolvedDOI, let dois = await openCitationsReferences(doi: resolvedDOI) {
            citedDOIs = dois.filter { !seenDOIs.contains($0) }
        }
        let sources = parts.map(\.source) + (citedDOIs.isEmpty ? [] : ["OpenCitations"])
        let stored = Entry(doi: resolvedDOI, references: references,
                           source: sources.joined(separator: " + "),
                           fetched: .now, found: !references.isEmpty || !citedDOIs.isEmpty,
                           complete: true,
                           citedDOIs: citedDOIs.isEmpty ? nil : citedDOIs)
        cache[key] = stored
        persist()
        return stored
    }

    // MARK: Providers

    /// Semantic Scholar: the cited papers with their metadata inline —
    /// one call, paginated; a title search finds the paper id when the
    /// work carries no DOI.
    private static func semanticScholar(doi: String?, title: String,
                                        year: Int?) async -> Entry? {
        var paperPath: String?
        if let doi, let encoded = doi.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed) {
            paperPath = "DOI:" + encoded
        } else if !title.isEmpty {
            var components = URLComponents(
                string: "https://api.semanticscholar.org/graph/v1/paper/search")
            components?.queryItems = [
                URLQueryItem(name: "query", value: title),
                URLQueryItem(name: "limit", value: "5"),
                URLQueryItem(name: "fields", value: "title,year"),
            ]
            await politePause()
            if let url = components?.url,
               let data = (await json(from: url))?["data"] as? [[String: Any]],
               let match = data.first(where: {
                   titleMatches(($0["title"] as? String) ?? "", title)
                       && yearAgrees(($0["year"] as? NSNumber)?.intValue, year)
               }) {
                paperPath = match["paperId"] as? String
            }
        }
        guard let paperPath else { return nil }

        var references: [CitedRef] = []
        var offset = 0
        var resolvedDOI = doi
        // Up to 500 references, 100 a page — beyond that is a survey's
        // bibliography, and the far tail serves no map.
        while offset < 500 {
            var components = URLComponents(
                string: "https://api.semanticscholar.org/graph/v1/paper/\(paperPath)/references")
            components?.queryItems = [
                URLQueryItem(name: "fields", value: "title,authors,year,externalIds"),
                URLQueryItem(name: "limit", value: "100"),
                URLQueryItem(name: "offset", value: String(offset)),
            ]
            guard let url = components?.url else { break }
            await politePause()
            guard let page = await json(from: url),
                  let data = page["data"] as? [[String: Any]] else { break }
            if resolvedDOI == nil {
                resolvedDOI = (((page["citingPaperInfo"] as? [String: Any])?["externalIds"]
                    as? [String: Any])?["DOI"] as? String)?.lowercased()
            }
            for item in data {
                guard let cited = item["citedPaper"] as? [String: Any],
                      let citedTitle = cited["title"] as? String,
                      !citedTitle.isEmpty else { continue }
                let authors = ((cited["authors"] as? [[String: Any]]) ?? [])
                    .compactMap { $0["name"] as? String }
                references.append(CitedRef(
                    title: citedTitle,
                    authors: joinedAuthors(authors),
                    year: (cited["year"] as? NSNumber)?.intValue,
                    doi: (((cited["externalIds"] as? [String: Any])?["DOI"])
                        as? String)?.lowercased()))
            }
            guard let next = page["next"] as? NSNumber else { break }
            offset = next.intValue
        }
        guard !references.isEmpty else { return nil }
        return Entry(doi: resolvedDOI, references: references,
                     source: "Semantic Scholar", fetched: .now, found: true)
    }

    /// OpenAlex: `referenced_works` ids, resolved to works 50 a call —
    /// with the reader's key, as the card lookups use it.
    private static func openAlex(doi: String?, title: String,
                                 year: Int?) async -> Entry? {
        let apiKey = openAlexAPIKey
        guard !apiKey.isEmpty else { return nil }

        var work: [String: Any]?
        if let doi, let encoded = doi.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed),
           let url = URL(string:
                "https://api.openalex.org/works/doi:\(encoded)?select=referenced_works,doi&api_key=\(apiKey)") {
            await politePause()
            work = await json(from: url)
        }
        if work == nil, !title.isEmpty {
            var components = URLComponents(string: "https://api.openalex.org/works")
            components?.queryItems = [
                URLQueryItem(name: "filter", value: "title.search:\(title)"),
                URLQueryItem(name: "per-page", value: "5"),
                URLQueryItem(name: "select", value: "title,publication_year,referenced_works,doi"),
                URLQueryItem(name: "api_key", value: apiKey),
            ]
            await politePause()
            if let url = components?.url,
               let results = (await json(from: url))?["results"] as? [[String: Any]] {
                work = results.first {
                    titleMatches(($0["title"] as? String) ?? "", title)
                        && yearAgrees(($0["publication_year"] as? NSNumber)?.intValue, year)
                }
            }
        }
        guard let work,
              let ids = (work["referenced_works"] as? [String])?.prefix(500),
              !ids.isEmpty else { return nil }

        var references: [CitedRef] = []
        for batch in stride(from: 0, to: ids.count, by: 50) {
            let slice = Array(ids)[batch..<min(batch + 50, ids.count)]
                .map { $0.replacingOccurrences(of: "https://openalex.org/", with: "") }
            var components = URLComponents(string: "https://api.openalex.org/works")
            components?.queryItems = [
                URLQueryItem(name: "filter", value: "openalex:" + slice.joined(separator: "|")),
                URLQueryItem(name: "per-page", value: "50"),
                URLQueryItem(name: "select", value: "title,publication_year,doi,authorships"),
                URLQueryItem(name: "api_key", value: apiKey),
            ]
            guard let url = components?.url else { continue }
            await politePause()
            guard let results = (await json(from: url))?["results"] as? [[String: Any]]
            else { continue }
            for resolved in results {
                guard let citedTitle = resolved["title"] as? String,
                      !citedTitle.isEmpty else { continue }
                let authors = ((resolved["authorships"] as? [[String: Any]]) ?? [])
                    .compactMap { ($0["author"] as? [String: Any])?["display_name"] as? String }
                references.append(CitedRef(
                    title: citedTitle,
                    authors: joinedAuthors(authors),
                    year: (resolved["publication_year"] as? NSNumber)?.intValue,
                    doi: (resolved["doi"] as? String)?
                        .replacingOccurrences(of: "https://doi.org/", with: "")
                        .lowercased()))
            }
        }
        guard !references.isEmpty else { return nil }
        let resolvedDOI = (work["doi"] as? String)?
            .replacingOccurrences(of: "https://doi.org/", with: "").lowercased()
        return Entry(doi: doi ?? resolvedDOI, references: references,
                     source: "OpenAlex", fetched: .now, found: true)
    }

    /// Crossref: the publisher-deposited reference array — present for
    /// most recent works, thinner and sometimes unstructured.
    private static func crossref(doi: String) async -> Entry? {
        guard let encoded = doi.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://api.crossref.org/works/\(encoded)")
        else { return nil }
        await politePause()
        guard let message = (await json(from: url))?["message"] as? [String: Any],
              let raw = message["reference"] as? [[String: Any]], !raw.isEmpty
        else { return nil }
        let references: [CitedRef] = raw.compactMap { item in
            let title = (item["article-title"] as? String)
                ?? (item["volume-title"] as? String)
                ?? (item["unstructured"] as? String)
            guard let title, !title.isEmpty else { return nil }
            return CitedRef(
                title: title,
                authors: (item["author"] as? String) ?? "",
                year: (item["year"] as? String).flatMap { Int($0.prefix(4)) },
                doi: (item["DOI"] as? String)?.lowercased())
        }
        guard !references.isEmpty else { return nil }
        return Entry(doi: doi, references: references,
                     source: "Crossref", fetched: .now, found: true)
    }

    /// OpenCitations' index: the DOIs a work cites, from the open
    /// reference deposits — no titles, but a DOI is the surest match.
    private static func openCitationsReferences(doi: String) async -> [String]? {
        guard let encoded = doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://api.opencitations.net/index/v2/references/doi:\(encoded)")
        else { return nil }
        await politePause()
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("OrigamiText/1.0 (mailto:frode@hegland.com)",
                         forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        else { return nil }
        // "cited" holds space-separated ids: "omid:… doi:10.… openalex:…".
        return rows.compactMap { row in
            (row["cited"] as? String)?
                .split(separator: " ")
                .first { $0.hasPrefix("doi:") }
                .map { String($0.dropFirst(4)).lowercased() }
        }
    }

    // MARK: Plumbing (the card lookups' etiquette)

    private static func json(from url: URL) async -> [String: Any]? {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("OrigamiText/1.0 (mailto:frode@hegland.com)",
                         forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func joinedAuthors(_ names: [String]) -> String {
        if names.count > 4 {
            return names.prefix(3).joined(separator: ", ") + " et al."
        }
        return names.joined(separator: ", ")
    }

    private static func titleMatches(_ candidate: String, _ wanted: String) -> Bool {
        let a = normalize(candidate)
        let b = normalize(wanted)
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a == b || a.hasPrefix(b) || b.hasPrefix(a)
    }

    /// Same folding as OrigamiReading.normalize, inlined so the vision
    /// target needs only this file.
    private static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                  locale: Locale(identifier: "en_US_POSIX"))
        let kept = folded.map { $0.isLetter || $0.isNumber ? $0 : " " }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    private static func yearAgrees(_ candidate: Int?, _ wanted: Int?) -> Bool {
        guard let candidate, let wanted else { return true }
        return abs(candidate - wanted) <= 1
    }
}

// MARK: - Transpoint

/// One work a document cites, as Transpoint stands it beside the page:
/// what it is, whether the library holds it, its sections when it does,
/// and every passage of the citing document that points at it — each
/// landing on a section where the citation says which, or on the whole
/// work where it does not.
///
/// In honour of Ted Nelson's transpointing windows — with the one thing
/// academia adds to them: a citation runs back in time. The cited stand
/// behind the citing page, as the Hallway's older works stand deeper.
nonisolated struct TranspointWork: Identifiable, Hashable, Sendable {
    struct Section: Identifiable, Hashable, Sendable {
        let id: String
        let title: String
        let level: Int
    }
    /// A passage of the citing document that cites the work, and the
    /// section of the work it lands on, when that is known.
    struct Origin: Hashable, Sendable {
        let paragraphID: String
        let sectionID: String?
    }

    let id: String
    let title: String
    let authors: String
    let year: Int?
    /// The library book, when the work is one.
    let recordID: String?
    /// The citing document's reference key — Acquire's handle.
    let citationKey: String?
    let doi: String?
    let abstract: String?
    var sections: [Section]
    var origins: [Origin]

    var isInLibrary: Bool { recordID != nil }
}

/// One citation between two documents on a Transpoint stage: the
/// citing document and its passage (nil when it is cited only in the
/// references), and the cited document and its section when known.
nonisolated struct TranspointLink: Hashable, Sendable {
    let from: String
    let paragraphID: String?
    let to: String
    let sectionID: String?
}

nonisolated enum Transpoint {

    /// How far behind the citing page the cited works stand, in metres:
    /// a citation looks back in time, and back is the Hallway's past.
    static let behind: Float = 0.05

    /// Every work `doc` cites, oldest first, with the passages citing it.
    ///
    /// A work is resolved to a library book by the citation's own
    /// address (`vm-id` / `origami-id`), its DOI, or its title. The
    /// section is known when the citation names a passage — the address's
    /// `#fragment`, an `[address#paragraph]` token, an `origamitext://`
    /// link — or when words the citing paragraph quotes are found in the
    /// book. Otherwise the line goes to the work as a whole.
    static func works(citedBy doc: LiquidDoc, records: [EPUBRecord],
                      document: (String) -> LiquidDoc?) -> [TranspointWork] {
        let shelf = Shelf(records: records)
        let selfIDs: Set<String> = [doc.id, LiquidAddress.canonical(doc.id)]
        var works: [String: TranspointWork] = [:]
        var order: [String] = []
        var workByKey: [String: String] = [:]
        var fragmentByKey: [String: String] = [:]
        var targetDocs: [String: LiquidDoc] = [:]

        func targetDoc(_ recordID: String) -> LiquidDoc? {
            if let known = targetDocs[recordID] { return known }
            let found = document(recordID)
            if let found { targetDocs[recordID] = found }
            return found
        }

        func add(_ work: TranspointWork) {
            guard works[work.id] == nil else { return }
            works[work.id] = work
            order.append(work.id)
        }

        func bookWork(_ record: EPUBRecord, key: String?, fields: [String: String]) -> TranspointWork {
            let target = targetDoc(record.id)
            return TranspointWork(
                id: record.id,
                title: record.title,
                authors: record.author,
                year: record.dateISO.flatMap { Int($0.prefix(4)) }
                    ?? fields["year"].flatMap { Int($0.filter(\.isNumber).prefix(4)) },
                recordID: record.id,
                citationKey: key,
                doi: record.doi ?? fields["doi"],
                abstract: target?.abstract ?? fields["abstract"],
                sections: target.map(sections(of:)) ?? [],
                origins: [])
        }

        // The reference list: one work per entry, a book where the
        // library holds it.
        for reference in doc.references {
            let bib = BibTeXRecord.records(in: reference.bibtex).first
            let fields = bib?.fields ?? [:]
            let address = fields["vm-id"] ?? fields["origami-id"]
            let parts = address.map { $0.split(separator: "#", maxSplits: 1).map(String.init) } ?? []
            if parts.count == 2 { fragmentByKey[reference.id] = parts[1] }
            let title = bib?.title.isEmpty == false ? bib!.title : (reference.citedAs ?? "")
            let record = parts.first.flatMap(shelf.record(forAddress:))
                ?? shelf.record(forDOI: fields["doi"])
                ?? shelf.record(forTitle: title)
            if let record {
                guard !selfIDs.contains(record.id) else { continue }
                add(bookWork(record, key: reference.id, fields: fields))
                workByKey[reference.id] = record.id
            } else {
                guard !title.isEmpty else { continue }
                let id = "cite:" + reference.id
                add(TranspointWork(
                    id: id, title: title,
                    authors: bib?.displayAuthors ?? "",
                    year: Int((bib?.year ?? "").filter(\.isNumber).prefix(4)),
                    recordID: nil, citationKey: reference.id,
                    doi: fields["doi"], abstract: fields["abstract"],
                    sections: [], origins: []))
                workByKey[reference.id] = id
            }
        }

        // The text: every paragraph that cites, and where each citation lands.
        var originSeen = Set<String>()
        func cite(_ workID: String, from paragraphID: String, section: String?) {
            guard works[workID] != nil,
                  originSeen.insert("\(workID)|\(paragraphID)|\(section ?? "")").inserted
            else { return }
            works[workID]?.origins.append(
                TranspointWork.Origin(paragraphID: paragraphID, sectionID: section))
        }
        for paragraph in doc.body ?? [] where paragraph.effectiveHeading == nil {
            let text = paragraph.text
            guard text.contains("[") || text.contains("origamitext") else { continue }
            let quotes = quotations(in: text)

            for key in citationKeys(in: text) {
                guard let workID = workByKey[key] else { continue }
                var section: String?
                if let recordID = works[workID]?.recordID, let target = targetDoc(recordID) {
                    if let fragment = fragmentByKey[key] {
                        section = sectionID(containing: fragment, in: target)
                    }
                    if section == nil {
                        section = quotes.lazy
                            .compactMap { quoteSection($0, in: target) }.first
                    }
                }
                cite(workID, from: paragraph.id, section: section)
            }

            for passage in passageLinks(in: text) {
                guard let record = shelf.record(forAddress: passage.address),
                      !selfIDs.contains(record.id) else { continue }
                add(bookWork(record, key: nil, fields: [:]))
                let section = targetDoc(record.id).flatMap {
                    sectionID(containing: passage.fragment, in: $0)
                }
                cite(record.id, from: paragraph.id, section: section)
            }
        }

        return order.compactMap { works[$0] }.sorted {
            ($0.year ?? Int.max, $0.title) < ($1.year ?? Int.max, $1.title)
        }
    }

    /// Every citation among the documents on stage: the page's to each
    /// work it cites, and — where those works are library books — theirs
    /// to one another and back to the page. Documents cite each other;
    /// every such citation is a line.
    static func links(page pageID: String, works: [TranspointWork],
                      records: [EPUBRecord],
                      document: (String) -> LiquidDoc?) -> [TranspointLink] {
        var links: [TranspointLink] = []
        for work in works {
            for origin in work.origins {
                links.append(TranspointLink(from: pageID, paragraphID: origin.paragraphID,
                                            to: work.id, sectionID: origin.sectionID))
            }
        }
        let stage = Set(works.map(\.id)).union([pageID])
        for work in works {
            guard let recordID = work.recordID, let doc = document(recordID) else { continue }
            for cited in Transpoint.works(citedBy: doc, records: records, document: document)
            where cited.id != work.id && stage.contains(cited.id) {
                if cited.origins.isEmpty {
                    links.append(TranspointLink(from: work.id, paragraphID: nil,
                                                to: cited.id, sectionID: nil))
                }
                for origin in cited.origins {
                    links.append(TranspointLink(from: work.id, paragraphID: origin.paragraphID,
                                                to: cited.id, sectionID: origin.sectionID))
                }
            }
        }
        return links
    }

    /// The passages each document must report its place for: the citing
    /// passages, and the cited sections, by document.
    static func reporting(_ links: [TranspointLink]) -> [String: Set<String>] {
        var report: [String: Set<String>] = [:]
        for link in links {
            if let paragraph = link.paragraphID { report[link.from, default: []].insert(paragraph) }
            if let section = link.sectionID { report[link.to, default: []].insert(section) }
        }
        return report
    }

    // MARK: Sections

    /// The headings a work's card lists: its top two levels — enough to
    /// land on, few enough to read across a room.
    static func sections(of doc: LiquidDoc) -> [TranspointWork.Section] {
        let headings = (doc.body ?? []).compactMap { paragraph -> TranspointWork.Section? in
            guard let level = paragraph.effectiveHeading else { return nil }
            let title = paragraph.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            return TranspointWork.Section(id: paragraph.id, title: title, level: level)
        }
        let top = headings.map(\.level).min() ?? 1
        return Array(headings.filter { $0.level <= top + 1 }.prefix(maxSections))
    }

    static let maxSections = 18

    /// The listed section a passage of `doc` falls in: the last listed
    /// heading at or before it. Nil before the first heading, or when the
    /// passage is not in the document.
    static func sectionID(containing fragment: String, in doc: LiquidDoc) -> String? {
        let bare = fragment.split(separator: "#").last.map(String.init) ?? fragment
        let listed = Set(sections(of: doc).map(\.id))
        var current: String?
        for paragraph in doc.body ?? [] {
            if listed.contains(paragraph.id) { current = paragraph.id }
            if paragraph.id == bare { return current }
        }
        return nil
    }

    // MARK: Reading the citing text

    /// The keys of every `[cite:…]` / `[cites:…]` in a paragraph, in order.
    static func citationKeys(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\[cites?:([^\]]+)\]"#) else { return [] }
        let ns = text as NSString
        var keys: [String] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            for raw in ns.substring(with: match.range(at: 1)).split(separator: ",") {
                let key = raw.trimmingCharacters(in: .whitespaces)
                if !key.isEmpty, !keys.contains(key) { keys.append(key) }
            }
        }
        return keys
    }

    /// Links into a passage of another document: `[address#paragraph]`
    /// tokens (a relation may lead, `[supports:address#p]`) and
    /// `origamitext://open/address#paragraph` links or their web carrier.
    static func passageLinks(in text: String) -> [(address: String, fragment: String)] {
        let range = NSRange(text.startIndex..., in: text)
        var out: [(String, String)] = []
        if let tokens = try? NSRegularExpression(pattern: #"\[([^\[\]\s#]+)#([^\[\]\s]+)\]"#) {
            for match in tokens.matches(in: text, range: range) {
                guard let a = Range(match.range(at: 1), in: text),
                      let f = Range(match.range(at: 2), in: text) else { continue }
                var address = String(text[a])
                if let colon = address.firstIndex(of: ":"),
                   DocumentRelation(rawValue: String(address[..<colon])) != nil {
                    address = String(address[address.index(after: colon)...])
                }
                out.append((address, String(text[f])))
            }
        }
        if let links = try? NSRegularExpression(
            pattern: #"(?:origamitext://open/|https://origamitext\.app/o/)([^)\s#]+)#([^)\s]+)"#) {
            for match in links.matches(in: text, range: range) {
                guard let a = Range(match.range(at: 1), in: text),
                      let f = Range(match.range(at: 2), in: text) else { continue }
                let address = String(text[a]).removingPercentEncoding ?? String(text[a])
                out.append((address, String(text[f])))
            }
        }
        return out
    }

    /// Words a paragraph quotes — long enough to be worth finding.
    static func quotations(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"[“"]([^”"]{24,600})[”"]"#) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { normalized(ns.substring(with: $0.range(at: 1))) }
            .filter { $0.split(separator: " ").count >= 5 }
    }

    /// The listed section of `doc` whose passage holds the quoted words.
    static func quoteSection(_ quote: String, in doc: LiquidDoc) -> String? {
        for paragraph in doc.body ?? [] where paragraph.effectiveHeading == nil {
            if normalized(paragraph.text).contains(quote) {
                return sectionID(containing: paragraph.id, in: doc)
            }
        }
        return nil
    }

    /// Letters and figures only, single-spaced, lower case — so a quote
    /// survives the citing text's tokens, emphasis and curly punctuation.
    static func normalized(_ text: String) -> String {
        var cleaned = text.replacingOccurrences(of: #"\[[^\]]*\]"#, with: " ",
                                                options: .regularExpression)
        cleaned = cleaned.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " }
            .reduce(into: "") { $0.append($1) }
        return cleaned.split(separator: " ").joined(separator: " ")
    }

    // MARK: The shelf

    /// The library, looked up the three ways a citation names a book.
    struct Shelf {
        private var byAddress: [String: EPUBRecord] = [:]
        private var byDOI: [String: EPUBRecord] = [:]
        private var byTitle: [String: EPUBRecord] = [:]

        init(records: [EPUBRecord]) {
            for record in records {
                for address in [record.id, LiquidAddress.canonical(record.id), record.folder,
                                record.packageIdentifier ?? ""] where !address.isEmpty {
                    byAddress[address.lowercased()] = byAddress[address.lowercased()] ?? record
                }
                if let doi = Self.cleanDOI(record.doi) { byDOI[doi] = byDOI[doi] ?? record }
                let title = Transpoint.normalized(record.title)
                if title.count >= 12 { byTitle[title] = byTitle[title] ?? record }
            }
        }

        func record(forAddress address: String) -> EPUBRecord? {
            let trimmed = address.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            return byAddress[trimmed.lowercased()]
                ?? byAddress[LiquidAddress.canonical(trimmed).lowercased()]
        }

        func record(forDOI doi: String?) -> EPUBRecord? {
            Self.cleanDOI(doi).flatMap { byDOI[$0] }
        }

        func record(forTitle title: String) -> EPUBRecord? {
            let key = Transpoint.normalized(BibTeXParser.displayText(title))
            return key.count >= 12 ? byTitle[key] : nil
        }

        static func cleanDOI(_ doi: String?) -> String? {
            guard var value = doi?.trimmingCharacters(in: .whitespaces).lowercased(),
                  !value.isEmpty else { return nil }
            for prefix in ["https://doi.org/", "http://doi.org/", "https://dx.doi.org/", "doi:"]
            where value.hasPrefix(prefix) {
                value = String(value.dropFirst(prefix.count))
            }
            return value.isEmpty ? nil : value
        }
    }
}
