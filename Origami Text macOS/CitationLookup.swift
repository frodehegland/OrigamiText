import Foundation

/// Gathering what the package does not carry about a cited work — the
/// abstract above all — from the scholarly metadata services, for the
/// citation card. Three providers, tried in order of abstract coverage
/// and cost (verified August 2026):
///
///  - OpenAlex (~99% abstract coverage, keyed since February 2026 —
///    used only when the reader has pasted their free API key),
///  - Crossref (keyless, the polite pool via mailto — the app's
///    existing etiquette; ~75% coverage, JATS markup stripped),
///  - Semantic Scholar (keyless shared pool, throttled — fine for
///    one-card-at-a-time; abstracts plus AI TL;DRs).
///
/// Lookups go DOI-first, falling back to a title search sanity-checked
/// against the record's own title. Results — misses included — cache to
/// disk beside the unpacked books, so a card never asks twice.
@MainActor
enum CitationLookup {

    /// Settings: the master switch and the optional OpenAlex key.
    static let enabledKey = "lookupCitedWorks"
    static let openAlexKeyKey = "openAlexAPIKey"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    private static var openAlexKey: String {
        (UserDefaults.standard.string(forKey: openAlexKeyKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What a lookup gathered, cached verbatim. `found` false is the
    /// remembered miss — retried only after `missRetryDays`.
    struct Enrichment: Codable, Sendable {
        var abstract: String?
        /// Semantic Scholar's AI summary, when the work has one.
        var tldr: String?
        var venue: String?
        var year: String?
        var doi: String?
        var openAccessURL: String?
        /// Which service answered — the card says so.
        var source: String
        var fetched: Date
        var found: Bool
    }

    private static let missRetryDays = 7.0

    // MARK: The cache (one JSON beside the unpacked books)

    private static var cacheURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        // "2": matching grew a year check — the earlier file could hold
        // same-titled OTHER works' abstracts, remembered forever.
        return base.appendingPathComponent("EPUBs", isDirectory: true)
            .appendingPathComponent("CitationLookups2.json")
    }

    private static var cache: [String: Enrichment] = {
        guard let data = try? Data(contentsOf: cacheURL),
              let stored = try? JSONDecoder().decode([String: Enrichment].self, from: data)
        else { return [:] }
        return stored
    }()

    private static func persist() {
        try? FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(cache) {
            try? data.write(to: cacheURL, options: .atomic)
        }
    }

    /// The record's cache key: its DOI when it has one, its normalized
    /// title otherwise.
    private static func cacheKey(for record: BibTeXRecord) -> String? {
        if let doi = normalizedDOI(record) { return "doi:" + doi }
        let title = OrigamiReading.normalize(record.title)
        return title.isEmpty ? nil : "title:" + title
    }

    private static func normalizedDOI(_ record: BibTeXRecord) -> String? {
        guard var doi = record.fields["doi"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !doi.isEmpty else { return nil }
        for prefix in ["https://doi.org/", "http://doi.org/", "doi.org/", "doi:"] {
            if doi.lowercased().hasPrefix(prefix) { doi = String(doi.dropFirst(prefix.count)) }
        }
        return doi.isEmpty ? nil : doi.lowercased()
    }

    /// What the cache already knows, hits and remembered misses alike.
    static func cached(for record: BibTeXRecord) -> Enrichment? {
        guard let key = cacheKey(for: record) else { return nil }
        return cache[key].map(tidied)
    }

    /// The enrichment with its prose repaired for display — entries
    /// cached before the repair existed read clean too.
    private static func tidied(_ enrichment: Enrichment) -> Enrichment {
        var out = enrichment
        out.abstract = out.abstract.map(tidiedAbstract)
        out.tldr = out.tldr.map(tidiedAbstract)
        return out
    }

    // MARK: The lookup

    /// Gathers what the services know about the record — from the cache
    /// when it answers, from the network once otherwise. Nil when
    /// lookups are off or the record offers nothing to search by.
    static func enrich(_ record: BibTeXRecord) async -> Enrichment? {
        guard isEnabled, let key = cacheKey(for: record) else { return nil }
        if let known = cache[key] {
            if known.found { return known }
            // A remembered miss retries only after a rest.
            if Date.now.timeIntervalSince(known.fetched) < missRetryDays * 86_400 {
                return known
            }
        }

        var enrichment: Enrichment?
        let doi = normalizedDOI(record)
        // OpenAlex first when the reader holds a key — the best
        // abstract coverage of the three.
        if !openAlexKey.isEmpty {
            enrichment = await openAlex(doi: doi, record: record)
        }
        if enrichment?.abstract == nil {
            if let better = await crossref(doi: doi, record: record) {
                enrichment = merged(enrichment, better)
            }
        }
        if enrichment?.abstract == nil {
            if let better = await semanticScholar(doi: doi ?? enrichment?.doi,
                                                  record: record) {
                enrichment = merged(enrichment, better)
            }
        }

        let result = enrichment.map(tidied)
            ?? Enrichment(source: "", fetched: .now, found: false)
        var stored = result
        stored.fetched = .now
        cache[key] = stored
        persist()
        return stored
    }

    /// Two answers folded: the earlier keeps its claim on every field
    /// it filled; the later supplies the rest. The abstract's source
    /// names whoever provided it.
    private static func merged(_ first: Enrichment?, _ second: Enrichment) -> Enrichment {
        guard var out = first else { return second }
        if out.abstract == nil, let abstract = second.abstract {
            out.abstract = abstract
            out.source = second.source
        }
        if out.tldr == nil { out.tldr = second.tldr }
        if out.venue == nil { out.venue = second.venue }
        if out.year == nil { out.year = second.year }
        if out.doi == nil { out.doi = second.doi }
        if out.openAccessURL == nil { out.openAccessURL = second.openAccessURL }
        out.found = out.found || second.found
        return out
    }

    // MARK: Providers

    /// Crossref: keyless, the polite pool via the mailto'd User-Agent —
    /// the same etiquette the reference verifier practices. Abstracts
    /// arrive in JATS markup, stripped here.
    private static func crossref(doi: String?, record: BibTeXRecord) async -> Enrichment? {
        var work: [String: Any]?
        if let doi,
           let encoded = doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
           let url = URL(string: "https://api.crossref.org/works/\(encoded)") {
            work = (await json(from: url))?["message"] as? [String: Any]
        }
        if work == nil, !record.title.isEmpty {
            var components = URLComponents(string: "https://api.crossref.org/works")
            components?.queryItems = [
                URLQueryItem(name: "query.bibliographic",
                             value: [record.title, record.author]
                                 .filter { !$0.isEmpty }.joined(separator: " ")),
                URLQueryItem(name: "rows", value: "3"),
            ]
            if let url = components?.url,
               let message = (await json(from: url))?["message"] as? [String: Any],
               let items = message["items"] as? [[String: Any]] {
                work = items.first { item in
                    let titles = item["title"] as? [String] ?? []
                    guard titles.contains(where: { titleMatches($0, record.title) })
                    else { return false }
                    let year = ((item["issued"] as? [String: Any])?["date-parts"]
                        as? [[Int]])?.first?.first
                    return yearAgrees(year, with: record)
                }
            }
        }
        guard let work else { return nil }
        let abstract = (work["abstract"] as? String).map(strippedJATS)
            .flatMap { $0.isEmpty ? nil : $0 }
        let venue = (work["container-title"] as? [String])?.first
        let year = ((work["issued"] as? [String: Any])?["date-parts"] as? [[Int]])?
            .first?.first.map(String.init)
        return Enrichment(abstract: abstract, tldr: nil, venue: venue, year: year,
                          doi: (work["DOI"] as? String)?.lowercased(),
                          openAccessURL: nil,
                          source: "Crossref", fetched: .now, found: true)
    }

    /// Semantic Scholar: keyless on the shared public pool — throttled,
    /// so one polite try and a graceful nil on refusal. Abstracts plus
    /// the AI TL;DR where the domain has one.
    private static func semanticScholar(doi: String?, record: BibTeXRecord) async -> Enrichment? {
        let title = record.title
        let fields = "title,abstract,tldr,venue,year,externalIds,openAccessPdf"
        var paper: [String: Any]?
        if let doi,
           let encoded = doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
           let url = URL(string:
                "https://api.semanticscholar.org/graph/v1/paper/DOI:\(encoded)?fields=\(fields)") {
            paper = await json(from: url)
        }
        if paper == nil, !title.isEmpty {
            var components = URLComponents(
                string: "https://api.semanticscholar.org/graph/v1/paper/search")
            components?.queryItems = [
                URLQueryItem(name: "query", value: title),
                URLQueryItem(name: "limit", value: "5"),
                URLQueryItem(name: "fields", value: fields),
            ]
            if let url = components?.url,
               let data = (await json(from: url))?["data"] as? [[String: Any]] {
                paper = data.first {
                    titleMatches(($0["title"] as? String) ?? "", title)
                        && yearAgrees(($0["year"] as? NSNumber)?.intValue, with: record)
                }
            }
        }
        guard let paper else { return nil }
        let abstract = (paper["abstract"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let tldr = ((paper["tldr"] as? [String: Any])?["text"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Enrichment(
            abstract: abstract?.isEmpty == false ? abstract : nil,
            tldr: tldr?.isEmpty == false ? tldr : nil,
            venue: (paper["venue"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            year: (paper["year"] as? NSNumber)?.stringValue,
            doi: ((paper["externalIds"] as? [String: Any])?["DOI"] as? String)?.lowercased(),
            openAccessURL: (paper["openAccessPdf"] as? [String: Any])?["url"] as? String,
            source: "Semantic Scholar", fetched: .now, found: true)
    }

    /// OpenAlex: the widest abstract coverage, key-required since
    /// February 2026 — used only with the reader's own free key
    /// (Settings ▸ Reading). Abstracts arrive as an inverted index,
    /// rebuilt into words here.
    private static func openAlex(doi: String?, record: BibTeXRecord) async -> Enrichment? {
        let title = record.title
        let key = openAlexKey
        guard !key.isEmpty else { return nil }
        var work: [String: Any]?
        if let doi,
           let encoded = doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
           let url = URL(string: "https://api.openalex.org/works/doi:\(encoded)?api_key=\(key)") {
            work = await json(from: url)
        }
        if work == nil, !title.isEmpty {
            var components = URLComponents(string: "https://api.openalex.org/works")
            components?.queryItems = [
                URLQueryItem(name: "filter", value: "title.search:\(title)"),
                URLQueryItem(name: "per-page", value: "5"),
                URLQueryItem(name: "api_key", value: key),
            ]
            if let url = components?.url,
               let results = (await json(from: url))?["results"] as? [[String: Any]] {
                work = results.first {
                    titleMatches(($0["title"] as? String) ?? "", title)
                        && yearAgrees(($0["publication_year"] as? NSNumber)?.intValue,
                                      with: record)
                }
            }
        }
        guard let work else { return nil }
        let abstract = (work["abstract_inverted_index"] as? [String: [Int]])
            .map(reconstructedAbstract)
            .flatMap { $0.isEmpty ? nil : $0 }
        let venue = (((work["primary_location"] as? [String: Any])?["source"]
            as? [String: Any])?["display_name"] as? String)
        let openAccess = ((work["open_access"] as? [String: Any])?["oa_url"] as? String)
        let doiOut = (work["doi"] as? String)?
            .replacingOccurrences(of: "https://doi.org/", with: "").lowercased()
        return Enrichment(abstract: abstract, tldr: nil, venue: venue,
                          year: (work["publication_year"] as? NSNumber)?.stringValue,
                          doi: doiOut, openAccessURL: openAccess,
                          source: "OpenAlex", fetched: .now, found: true)
    }

    // MARK: Plumbing

    /// One GET, the polite way: identified, brief, and silent about
    /// failures — a card is never worth an error dialog.
    private static func json(from url: URL) async -> [String: Any]? {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("OrigamiText/1.0 (mailto:frode@hegland.com)",
                         forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Whether a service's title names the record's work — normalized
    /// equality, or one containing the other (subtitles come and go).
    private static func titleMatches(_ candidate: String, _ wanted: String) -> Bool {
        let a = OrigamiReading.normalize(candidate)
        let b = OrigamiReading.normalize(wanted)
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a == b || a.hasPrefix(b) || b.hasPrefix(a)
    }

    /// Whether a title-searched candidate's year agrees with the
    /// record's (±1, for early-online editions). Same-titled works
    /// abound — chapters, poems, reissues — and a year mismatch means
    /// someone else's abstract lands on the card. When either side has
    /// no year, the title match must carry it.
    private static func yearAgrees(_ candidate: Int?, with record: BibTeXRecord) -> Bool {
        guard let candidate,
              let recorded = record.fields["year"]
                  .map({ $0.trimmingCharacters(in: .whitespaces) })
                  .flatMap({ Int($0.prefix(4)) })
        else { return true }
        return abs(candidate - recorded) <= 1
    }

    /// Publisher abstracts often arrive with the spaces eaten at the
    /// original line breaks ("Ranch.Hal", "Warners,but"). Repairs the
    /// recoverable cases — sentence punctuation running straight into a
    /// capital, a comma straight into a letter — and leaves acronyms
    /// ("U.S.") and numbers ("1,000", "10.1145") alone.
    static func tidiedAbstract(_ text: String) -> String {
        text.replacingOccurrences(of: #"([a-z0-9])([.!?])([A-Z])"#,
                                  with: "$1$2 $3", options: .regularExpression)
            .replacingOccurrences(of: #"([A-Za-z])([,;:])([A-Za-z])"#,
                                  with: "$1$2 $3", options: .regularExpression)
    }

    /// Crossref's JATS markup down to the words: tags gone, entities
    /// decoded, the leading "Abstract" label dropped, whitespace calm.
    static func strippedJATS(_ jats: String) -> String {
        var text = jats.replacingOccurrences(of: "<[^>]+>", with: " ",
                                             options: .regularExpression)
        for (entity, character) in [("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&"),
                                    ("&quot;", "\""), ("&#38;", "&"), ("&apos;", "'")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        text = text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }.joined(separator: " ")
        for label in ["Abstract ", "Summary "] where text.hasPrefix(label) {
            text = String(text.dropFirst(label.count))
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// OpenAlex's inverted index back into running text: every word at
    /// its positions, joined in order.
    static func reconstructedAbstract(_ inverted: [String: [Int]]) -> String {
        var slots: [(Int, String)] = []
        for (word, positions) in inverted {
            for position in positions { slots.append((position, word)) }
        }
        return slots.sorted { $0.0 < $1.0 }.map(\.1).joined(separator: " ")
    }
}
