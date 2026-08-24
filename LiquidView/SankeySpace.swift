// The time-spread's data lines: yearly series standing along the same
// Z axis as the citations — a 1974 data point at a 1974 citation's
// depth. The user adds series through a dialog in the spirit of Liquid
// Information's Ask-for-Data; the first pair is a city's yearly
// min/max temperatures from Open-Meteo's free archive (no key, daily
// records from 1940), fetched once and mirrored through the community
// folder so the Mac and the Vision Pro share one dataset.
import Foundation

nonisolated enum SankeySpace {

    // MARK: - The data

    struct Series: Codable, Sendable, Identifiable {
        /// "new-york-max" — pair plus role.
        var id: String
        /// The pair both roles of one subject share — "new-york".
        var pair: String
        /// The subject as shown — "New York".
        var name: String
        var role: Role
        var unit: String
        var values: [YearValue]

        enum Role: String, Codable, Sendable { case max, min }

        struct YearValue: Codable, Sendable {
            var year: Int
            var value: Double
        }

        var valueByYear: [Int: Double] {
            Dictionary(uniqueKeysWithValues: values.map { ($0.year, $0.value) })
        }
    }

    struct Dataset: Codable, Sendable {
        var series: [Series]
        var modified: Date

        /// The pairs in the order they were added, each with its series.
        var pairs: [(pair: String, name: String, series: [Series])] {
            var order: [String] = []
            var byPair: [String: [Series]] = [:]
            for entry in series {
                if byPair[entry.pair] == nil { order.append(entry.pair) }
                byPair[entry.pair, default: []].append(entry)
            }
            return order.map { ($0, byPair[$0]?.first?.name ?? $0, byPair[$0] ?? []) }
        }
    }

    // MARK: - The mirror

    static let fileName = "origami-sankey.json"

    static func read(from folder: URL) -> Dataset? {
        let url = folder.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Dataset.self, from: data)
    }

    static func write(_ dataset: Dataset, to folder: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(dataset) {
            try? data.write(to: folder.appendingPathComponent(fileName),
                            options: .atomic)
        }
    }

    // MARK: - Open-Meteo

    enum FetchError: LocalizedError {
        case cityNotFound(String)
        case noData(String)

        var errorDescription: String? {
            switch self {
            case .cityNotFound(let name):
                "No place called \u{201C}\(name)\u{201D} was found."
            case .noData(let name):
                "Open-Meteo has no temperature archive for \(name)."
            }
        }
    }

    /// A city's yearly min/max temperature pair, real data end to end:
    /// Open-Meteo's geocoder names the place, its archive gives every
    /// day since 1940, and each year keeps its highest high and lowest
    /// low.
    static func temperatureSeries(city: String) async throws -> [Series] {
        let place = try await geocode(city: city)
        let daily = try await dailyTemperatures(latitude: place.latitude,
                                                longitude: place.longitude)
        var maxByYear: [Int: Double] = [:]
        var minByYear: [Int: Double] = [:]
        for (date, high, low) in daily {
            guard let year = Int(date.prefix(4)) else { continue }
            if let high { maxByYear[year] = Swift.max(maxByYear[year] ?? -.infinity, high) }
            if let low { minByYear[year] = Swift.min(minByYear[year] ?? .infinity, low) }
        }
        guard !maxByYear.isEmpty, !minByYear.isEmpty else {
            throw FetchError.noData(place.name)
        }
        let pair = place.name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
        func series(_ role: Series.Role, _ byYear: [Int: Double]) -> Series {
            Series(id: "\(pair)-\(role.rawValue)", pair: pair, name: place.name,
                   role: role, unit: "\u{00B0}C",
                   values: byYear.keys.sorted().map {
                       Series.YearValue(year: $0, value: byYear[$0]!)
                   })
        }
        return [series(.max, maxByYear), series(.min, minByYear)]
    }

    private struct GeocodeReply: Codable {
        struct Place: Codable {
            var name: String
            var latitude: Double
            var longitude: Double
        }
        var results: [Place]?
    }

    static func geocode(city: String) async throws
        -> (name: String, latitude: Double, longitude: Double) {
        var components = URLComponents(
            string: "https://geocoding-api.open-meteo.com/v1/search")!
        components.queryItems = [
            URLQueryItem(name: "name", value: city),
            URLQueryItem(name: "count", value: "1"),
        ]
        let (data, _) = try await URLSession.shared.data(from: components.url!)
        guard let place = try JSONDecoder().decode(GeocodeReply.self, from: data)
            .results?.first else {
            throw FetchError.cityNotFound(city)
        }
        return (place.name, place.latitude, place.longitude)
    }

    private struct ArchiveReply: Codable {
        struct Daily: Codable {
            var time: [String]
            var temperature_2m_max: [Double?]
            var temperature_2m_min: [Double?]
        }
        var daily: Daily
    }

    // MARK: - The floor's world history

    /// One event on the floor: its year, its words, and how widely the
    /// world's Wikipedias carry it — the notability that decides who
    /// gets floor space when years are tight.
    struct FloorEvent: Codable, Sendable {
        var year: Int
        var title: String
        var links: Int
    }

    struct FloorHistory: Codable, Sendable {
        var events: [FloorEvent]
        var modified: Date
    }

    /// The floor's histories — each a themed Wikidata sweep, verified
    /// live before it was written here, fetched once and mirrored per
    /// theme.
    enum FloorTheme: String, CaseIterable, Sendable, Identifiable {
        case world
        case hypertext
        case hypertextPeople
        case environmental
        case space
        case computing

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .world: "World History"
            case .hypertext: "Hypertext History"
            case .hypertextPeople: "Hypertext People"
            case .environmental: "Environmental History"
            case .space: "Space History"
            case .computing: "Computing History"
            }
        }

        /// The world theme keeps the original file name, so mirrors
        /// written before themes arrived stay valid.
        var fileName: String {
            self == .world ? "origami-floor-history.json"
                : "origami-floor-\(rawValue).json"
        }

        /// The theme's SPARQL: what stands for an event, and which
        /// date places it — inception for systems, birth for people,
        /// the moment itself for happenings.
        var query: String {
            switch self {
            case .world: return """
                SELECT ?itemLabel (YEAR(?date) AS ?year) ?links WHERE {
                  VALUES ?type { wd:Q198 wd:Q8065 wd:Q3839081 wd:Q124734 wd:Q625298 \
                wd:Q2380335 wd:Q175331 wd:Q131569 wd:Q1072326 wd:Q2133344 wd:Q1174599 \
                wd:Q45382 wd:Q3199915 wd:Q217327 wd:Q750215 wd:Q1520311 }
                  ?item wdt:P31 ?type; wdt:P585 ?date; wikibase:sitelinks ?links.
                  FILTER(YEAR(?date) >= 1900 && YEAR(?date) <= 2026)
                  FILTER(?links > 25)
                  SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
                } ORDER BY DESC(?links) LIMIT 400
                """
            case .hypertext: return """
                SELECT ?itemLabel (YEAR(?date) AS ?year) ?links WHERE {
                  { ?item wdt:P31/wdt:P279* wd:Q1570119. } UNION { ?item wdt:P31 wd:Q6368. } \
                UNION { ?item wdt:P31 wd:Q212805. }
                  ?item wdt:P571 ?date; wikibase:sitelinks ?links.
                  FILTER(?links > 3)
                  SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
                } ORDER BY DESC(?links) LIMIT 200
                """
            case .hypertextPeople: return """
                SELECT DISTINCT ?itemLabel (YEAR(?date) AS ?year) ?links WHERE {
                  { ?item wdt:P101 wd:Q121182. } UNION { ?item wdt:P101 wd:Q466. } \
                UNION { ?item wdt:P61 ?inv. ?inv wdt:P31/wdt:P279* wd:Q1570119. }
                  ?item wdt:P31 wd:Q5; wdt:P569 ?date; wikibase:sitelinks ?links.
                  SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
                } ORDER BY DESC(?links) LIMIT 150
                """
            case .environmental: return """
                SELECT ?itemLabel (YEAR(?date) AS ?year) ?links WHERE {
                  VALUES ?type { wd:Q2620513 wd:Q220898 wd:Q1620824 wd:Q3839081 wd:Q8065 wd:Q167903 }
                  ?item wdt:P31 ?type; wdt:P585 ?date; wikibase:sitelinks ?links.
                  FILTER(?links > 15)
                  SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
                } ORDER BY DESC(?links) LIMIT 250
                """
            case .space: return """
                SELECT ?itemLabel (YEAR(?date) AS ?year) ?links WHERE {
                  VALUES ?type { wd:Q26529 wd:Q209363 wd:Q5346693 wd:Q209419 }
                  ?item wdt:P31 ?type; wdt:P619 ?date; wikibase:sitelinks ?links.
                  FILTER(?links > 12)
                  SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
                } ORDER BY DESC(?links) LIMIT 250
                """
            case .computing: return """
                SELECT ?itemLabel (YEAR(?date) AS ?year) ?links WHERE {
                  VALUES ?type { wd:Q7397 wd:Q9135 wd:Q11019 wd:Q1418 }
                  ?item wdt:P31 ?type; wdt:P571 ?date; wikibase:sitelinks ?links.
                  FILTER(?links > 25)
                  SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
                } ORDER BY DESC(?links) LIMIT 250
                """
            }
        }
    }

    static func readFloorHistory(theme: FloorTheme, from folder: URL) -> FloorHistory? {
        let url = folder.appendingPathComponent(theme.fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(FloorHistory.self, from: data)
    }

    static func writeFloorHistory(_ history: FloorHistory, theme: FloorTheme,
                                  to folder: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(history) {
            try? data.write(to: folder.appendingPathComponent(theme.fileName),
                            options: .atomic)
        }
    }

    /// One theme's events from Wikidata, ranked by how many Wikipedias
    /// carry each — fetched once and mirrored, like the temperature
    /// lines. Unlabelled items (a bare Q-number) are left out.
    static func fetchFloorHistory(theme: FloorTheme) async throws -> [FloorEvent] {
        var components = URLComponents(string: "https://query.wikidata.org/sparql")!
        components.queryItems = [
            URLQueryItem(name: "query", value: theme.query),
            URLQueryItem(name: "format", value: "json"),
        ]
        var request = URLRequest(url: components.url!, timeoutInterval: 60)
        request.setValue("OrigamiText/1.0 (mailto:frode@hegland.com)",
                         forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = object["results"] as? [String: Any],
              let bindings = results["bindings"] as? [[String: Any]] else { return [] }
        var seen = Set<String>()
        var events: [FloorEvent] = []
        for row in bindings {
            guard let title = ((row["itemLabel"] as? [String: Any])?["value"]) as? String,
                  let yearText = ((row["year"] as? [String: Any])?["value"]) as? String,
                  let year = Int(yearText),
                  let linksText = ((row["links"] as? [String: Any])?["value"]) as? String,
                  let links = Int(linksText),
                  seen.insert(title).inserted,
                  title.range(of: #"^Q\d+$"#, options: .regularExpression) == nil
            else { continue }
            events.append(FloorEvent(year: year, title: title, links: links))
        }
        return events
    }

    private static func dailyTemperatures(latitude: Double, longitude: Double)
        async throws -> [(date: String, high: Double?, low: Double?)] {
        // Through last year: the archive's recent days lag, and a
        // partial current year would draw a false extreme.
        let lastYear = Calendar(identifier: .gregorian)
            .component(.year, from: .now) - 1
        var components = URLComponents(
            string: "https://archive-api.open-meteo.com/v1/archive")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "start_date", value: "1940-01-01"),
            URLQueryItem(name: "end_date", value: "\(lastYear)-12-31"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "timezone", value: "auto"),
        ]
        let (data, _) = try await URLSession.shared.data(from: components.url!)
        let daily = try JSONDecoder().decode(ArchiveReply.self, from: data).daily
        return daily.time.indices.map { index in
            (daily.time[index],
             index < daily.temperature_2m_max.count ? daily.temperature_2m_max[index] : nil,
             index < daily.temperature_2m_min.count ? daily.temperature_2m_min[index] : nil)
        }
    }
}
