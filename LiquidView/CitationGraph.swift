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

    private static let mirrorName = "origami-citation-graph.json"

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

    /// Folds the community folder's graph into this device's — entries
    /// it lacks, and fresher answers for ones it holds. How a device
    /// that never fetches (the Vision Pro) still knows the graph.
    static func adoptMirror(from folder: URL) {
        let url = folder.appendingPathComponent(mirrorName)
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return }
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
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                  locale: Locale(identifier: "en_US_POSIX"))
        let kept = folded.map { $0.isLetter || $0.isNumber ? $0 : " " }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    private static func yearAgrees(_ candidate: Int?, _ wanted: Int?) -> Bool {
        guard let candidate, let wanted else { return true }
        return abs(candidate - wanted) <= 1
    }
}
