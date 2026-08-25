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
        /// Which Timeflow carries it — "left", "right", or nil for
        /// both. Absent from older mirrors, which read as nil.
        var wall: String? = nil
        /// The reader's chosen ink, "#RRGGBB" — nil paints from the
        /// palette by pair. Chosen on the Mac, worn everywhere.
        var colorHex: String? = nil

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
        case queryRejected(String)

        var errorDescription: String? {
            switch self {
            case .cityNotFound(let name):
                "No place called \u{201C}\(name)\u{201D} was found."
            case .noData(let name):
                "Open-Meteo has no temperature archive for \(name)."
            case .queryRejected(let why):
                "Wikidata rejected the query: \(why)"
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

    // MARK: - The sample shelf

    /// Curated long-run series — the last 150 years, ready to stand on
    /// the corridor with one tap. Every endpoint verified live before
    /// it was written here.
    struct SampleFlow: Identifiable, Sendable {
        enum Source: Sendable {
            /// Our World in Data's grapher CSV: the slug, the value
            /// column's header name, and how to scale the raw value.
            case owid(slug: String, column: String, scale: Double)
            /// SILSO's yearly sunspot record, 1700 onward.
            case silso
        }
        let id: String
        let name: String
        let unit: String
        let note: String
        let source: Source
    }

    static let sampleFlows: [SampleFlow] = [
        SampleFlow(id: "sample-temperature",
                   name: "Global temperature anomaly", unit: "\u{00B0}C",
                   note: "vs 1961\u{2013}90, HadCRUT via Our World in Data",
                   source: .owid(slug: "temperature-anomaly", column: "Average", scale: 1)),
        SampleFlow(id: "sample-co2",
                   name: "CO\u{2082} concentration", unit: "ppm",
                   note: "atmospheric, via Our World in Data",
                   source: .owid(slug: "co2-long-term-concentration",
                                 column: "Annual average", scale: 1)),
        SampleFlow(id: "sample-emissions",
                   name: "Global CO\u{2082} emissions", unit: "Gt",
                   note: "fossil and industry, via Our World in Data",
                   source: .owid(slug: "annual-co2-emissions-per-country",
                                 column: "Annual CO\u{2082} emissions", scale: 1e-9)),
        SampleFlow(id: "sample-life",
                   name: "World life expectancy", unit: "years",
                   note: "at birth, via Our World in Data",
                   source: .owid(slug: "life-expectancy",
                                 column: "Life expectancy", scale: 1)),
        SampleFlow(id: "sample-mortality",
                   name: "World child mortality", unit: "%",
                   note: "share dying before five, via Our World in Data",
                   source: .owid(slug: "child-mortality",
                                 column: "Under-five mortality rate (selected)", scale: 1)),
        SampleFlow(id: "sample-population",
                   name: "World population", unit: "bn",
                   note: "via Our World in Data",
                   source: .owid(slug: "population", column: "Population", scale: 1e-9)),
        SampleFlow(id: "sample-gdp",
                   name: "World GDP", unit: "tn $",
                   note: "constant international-$, via Our World in Data",
                   source: .owid(slug: "gdp-world-regions-stacked-area",
                                 column: "GDP", scale: 1e-12)),
        SampleFlow(id: "sample-sunspots",
                   name: "Sunspots", unit: "count",
                   note: "yearly mean, SILSO (Royal Observatory of Belgium)",
                   source: .silso),
        SampleFlow(id: "sample-transistors",
                   name: "Transistors per microprocessor", unit: "bn",
                   note: "Moore's law, via Our World in Data",
                   source: .owid(slug: "transistors-per-microprocessor",
                                 column: "Transistors per microprocessor",
                                 scale: 1e-9)),
        SampleFlow(id: "sample-supercomputer",
                   name: "Fastest supercomputer", unit: "PFLOPS",
                   note: "the TOP500 leader's capacity, via Our World in Data",
                   source: .owid(slug: "supercomputer-power-flops",
                                 column: "Computational capacity of the fastest supercomputer",
                                 scale: 1e-6)),
        SampleFlow(id: "sample-internet",
                   name: "Internet users", unit: "bn",
                   note: "people online, via Our World in Data",
                   source: .owid(slug: "number-of-internet-users",
                                 column: "Number of people using the Internet",
                                 scale: 1e-9)),
    ]

    /// The graphs' named inks — the corridor palette's own hues (Tol's
    /// muted scheme, darkened), offered by name wherever a graph's
    /// colour is chosen. Hex here, Color at the edges, so this file
    /// stays Foundation-clean.
    static let inkChoices: [(name: String, hex: String)] = [
        ("Ochre", "#967538"),
        ("Sienna", "#6B4533"),
        ("Wine", "#6E1A45"),
        ("Rose", "#A3525E"),
        ("Sand", "#B0A35E"),
        ("Slate", "#4A5E6B"),
        ("Olive", "#4C5736"),
        ("Teal", "#36877A"),
        ("Green", "#0D5E29"),
        ("Indigo", "#291C6E"),
    ]

    /// The corridor's own defaults (chosen 2026-08-25): Moore's law
    /// and the TOP500 leader on the left wall, internet users on the
    /// right.
    static func defaultWallSeries() async -> [Series] {
        let plan: [(sampleID: String, wall: String)] = [
            ("sample-transistors", "left"),
            ("sample-supercomputer", "left"),
            ("sample-internet", "right"),
        ]
        var out: [Series] = []
        for (id, wall) in plan {
            guard let sample = sampleFlows.first(where: { $0.id == id }),
                  var series = try? await fetchSample(sample) else { continue }
            series.wall = wall
            out.append(series)
        }
        return out
    }

    /// The earliest year a sample carries — the catalogue's promise is
    /// the last 150 years.
    private static var sampleFloorYear: Int {
        Calendar(identifier: .gregorian).component(.year, from: .now) - 150
    }

    static func fetchSample(_ sample: SampleFlow) async throws -> Series {
        let values: [Series.YearValue]
        switch sample.source {
        case .owid(let slug, let column, let scale):
            values = try await owidYearly(slug: slug, column: column, scale: scale)
        case .silso:
            values = try await silsoYearly()
        }
        let floor = sampleFloorYear
        let kept = values.filter { $0.year >= floor }
        guard kept.count >= 2 else { throw FetchError.noData(sample.name) }
        return Series(id: sample.id, pair: sample.id, name: sample.name,
                      role: .max, unit: sample.unit, values: kept)
    }

    /// One OWID grapher CSV, reduced to the World rows' yearly values.
    /// (The CSV lists every entity; the URL's country filter is not
    /// honoured, so the World is picked out here by its code.)
    private static func owidYearly(slug: String, column: String,
                                   scale: Double) async throws -> [Series.YearValue] {
        let url = URL(string: "https://ourworldindata.org/grapher/\(slug).csv")!
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue("OrigamiText/1.0 (mailto:frode@hegland.com)",
                         forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard !lines.isEmpty else { return [] }
        let header = lines.removeFirst().split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let codeIndex = header.firstIndex(of: "Code"),
              let yearIndex = header.firstIndex(of: "Year"),
              let valueIndex = header.firstIndex(of: column) else { return [] }
        var values: [Series.YearValue] = []
        for line in lines {
            let cells = line.split(separator: ",", omittingEmptySubsequences: false)
            guard cells.count > max(codeIndex, yearIndex, valueIndex),
                  cells[codeIndex] == "OWID_WRL",
                  let year = Int(cells[yearIndex]),
                  let value = Double(cells[valueIndex]) else { continue }
            values.append(Series.YearValue(year: year, value: value * scale))
        }
        return values.sorted { $0.year < $1.year }
    }

    /// SILSO's yearly means: "1700.5   8.3 ..." — the year, then the
    /// smoothed count.
    private static func silsoYearly() async throws -> [Series.YearValue] {
        let url = URL(string: "https://www.sidc.be/SILSO/DATA/SN_y_tot_V2.0.txt")!
        let (data, _) = try await URLSession.shared.data(from: url)
        let text = String(decoding: data, as: UTF8.self)
        var values: [Series.YearValue] = []
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 2,
                  let yearPoint = Double(fields[0]),
                  let value = Double(fields[1]), value >= 0 else { continue }
            values.append(Series.YearValue(year: Int(yearPoint), value: value))
        }
        return values
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
        /// A user timeline's shown name — the built-in themes name
        /// themselves. Absent from older mirrors.
        var name: String? = nil
        /// The user timeline's own SPARQL, kept so it can refresh; nil
        /// for imported files and the built-in themes.
        var query: String? = nil
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
        case discoveries

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .world: "World History"
            case .hypertext: "Hypertext History"
            case .hypertextPeople: "Hypertext People"
            case .environmental: "Environmental History"
            case .space: "Space History"
            case .computing: "Computing History"
            case .discoveries: "Discoveries & Inventions"
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
            case .discoveries: return """
                SELECT ?itemLabel (YEAR(?date) AS ?year) ?links WHERE {
                  ?item wdt:P575 ?date; wikibase:sitelinks ?links.
                  FILTER(YEAR(?date) >= 1850 && YEAR(?date) <= 2026)
                  FILTER(?links > 30)
                  SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
                } ORDER BY DESC(?links) LIMIT 300
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

    // MARK: - Drafting a floor query from plain words

    /// A timeline query drafted from plain words ("iphone",
    /// "telescopes"): the words resolve to Wikidata entities through
    /// the entity-search API, then the relations that gather a
    /// subject's members are tried in turn — instances (and their
    /// subclasses), series and parts, facets — and the first query
    /// that yields enough dated events wins. The drafted SPARQL is
    /// returned for the user to see, run, and adapt — never hidden.
    static func draftFloorQuery(about term: String) async throws
        -> (name: String, query: String, events: Int) {
        // The ask's framing words carry no entity — "history of the
        // iphone" must search as "iphone". The full phrase is tried
        // first (it may name an entity exactly), the stripped subject
        // after.
        let framing: Set<String> = ["history", "timeline", "evolution", "story",
                                    "of", "the", "a", "an", "about"]
        let stripped = term.split(separator: " ")
            .filter { !framing.contains($0.lowercased()) }
            .joined(separator: " ")
        var terms = [term]
        if !stripped.isEmpty, stripped.lowercased() != term.lowercased() {
            terms.append(stripped)
        }
        let patterns = [
            "?item wdt:P31/wdt:P279* wd:%@.",       // instances, subclasses deep
            "?item (wdt:P179|wdt:P361) wd:%@.",     // series members, parts
            "?item (wdt:P1269|wdt:P921) wd:%@.",    // facets, main subjects
        ]
        var best: (name: String, query: String, events: Int)?
        var foundAnyEntity = false
        for variant in terms {
            let candidates = (try? await searchEntities(variant)) ?? []
            foundAnyEntity = foundAnyEntity || !candidates.isEmpty
            for candidate in candidates.prefix(3) {
                for pattern in patterns {
                    let query = floorQueryTemplate(
                        pattern: String(format: pattern, candidate.id))
                    guard let events = try? await fetchFloorEvents(query: query),
                          !events.isEmpty else { continue }
                    let drafted = ("\(candidate.label) History", query, events.count)
                    if events.count >= 8 { return drafted }
                    if events.count > (best?.events ?? 0) { best = drafted }
                }
            }
        }
        if let best { return best }
        guard foundAnyEntity else {
            throw FetchError.queryRejected(
                "Wikidata knows no entity called \u{201C}\(term)\u{201D}.")
        }
        throw FetchError.queryRejected("""
            Wikidata holds too few dated items about \
            \u{201C}\(term)\u{201D} \u{2014} try a more concrete subject \
            (\u{201C}telescopes\u{201D} works where \u{201C}astronomy\u{201D} \
            would not).
            """)
    }

    /// The entity-search API: the words to their best-known entities.
    private static func searchEntities(_ term: String) async throws
        -> [(id: String, label: String)] {
        var components = URLComponents(string: "https://www.wikidata.org/w/api.php")!
        components.queryItems = [
            URLQueryItem(name: "action", value: "wbsearchentities"),
            URLQueryItem(name: "search", value: term),
            URLQueryItem(name: "language", value: "en"),
            URLQueryItem(name: "type", value: "item"),
            URLQueryItem(name: "limit", value: "5"),
            URLQueryItem(name: "format", value: "json"),
        ]
        var request = URLRequest(url: components.url!, timeoutInterval: 30)
        request.setValue("OrigamiText/1.0 (mailto:frode@hegland.com)",
                         forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let found = object["search"] as? [[String: Any]] else { return [] }
        return found.compactMap { entry in
            guard let id = entry["id"] as? String else { return nil }
            return (id, entry["label"] as? String ?? id)
        }
    }

    /// The drafted queries' shared shape: the subject pattern, then
    /// whichever date the item carries (publication, inception,
    /// discovery, the moment itself, launch, birth), ranked by
    /// Wikipedia carriage.
    private static func floorQueryTemplate(pattern: String) -> String {
        """
        SELECT ?itemLabel (YEAR(?date) AS ?year) ?links WHERE {
          \(pattern)
          ?item wikibase:sitelinks ?links.
          FILTER(?links > 10)
          OPTIONAL { ?item wdt:P577 ?d1 } OPTIONAL { ?item wdt:P571 ?d2 }
          OPTIONAL { ?item wdt:P575 ?d3 } OPTIONAL { ?item wdt:P585 ?d4 }
          OPTIONAL { ?item wdt:P619 ?d5 } OPTIONAL { ?item wdt:P569 ?d6 }
          BIND(COALESCE(?d1, ?d2, ?d3, ?d4, ?d5, ?d6) AS ?date)
          FILTER(BOUND(?date))
          SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
        } ORDER BY DESC(?links) LIMIT 200
        """
    }

    // MARK: - The user's own floor timelines

    /// A user timeline mirrors like a theme — one JSON per timeline,
    /// named by its slug — and carries its own name (and its query,
    /// when it came from one) inside the file.
    private static let userFloorPrefix = "origami-floor-user-"

    static func userFloorFileName(slug: String) -> String {
        userFloorPrefix + slug + ".json"
    }

    /// A shown name reduced to a file-safe slug.
    static func userFloorSlug(name: String) -> String {
        let slug = name.lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return slug.isEmpty ? "timeline" : slug
    }

    /// Every user timeline the folder carries, by slug and shown name.
    static func listUserFloorTimelines(in folder: URL) -> [(slug: String, name: String)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.compactMap { file in
            guard file.hasPrefix(userFloorPrefix), file.hasSuffix(".json") else { return nil }
            let slug = String(file.dropFirst(userFloorPrefix.count).dropLast(".json".count))
            guard !slug.isEmpty else { return nil }
            let history = readUserFloorHistory(slug: slug, from: folder)
            return (slug, history?.name ?? slug)
        }.sorted { $0.name < $1.name }
    }

    static func readUserFloorHistory(slug: String, from folder: URL) -> FloorHistory? {
        let url = folder.appendingPathComponent(userFloorFileName(slug: slug))
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(FloorHistory.self, from: data)
    }

    static func writeUserFloorHistory(_ history: FloorHistory, slug: String,
                                      to folder: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(history) {
            try? data.write(to: folder.appendingPathComponent(userFloorFileName(slug: slug)),
                            options: .atomic)
        }
    }

    /// A timeline from the user's own file: one event per line, the
    /// year then the words — comma or tab separated, an optional third
    /// column carrying the weight (the Wikipedia-carriage stand-in
    /// that decides floor space in tight years; 10 when absent).
    /// Header lines and anything without a leading year are skipped;
    /// negative years read as BCE.
    static func parseFloorEvents(text: String) -> [FloorEvent] {
        var events: [FloorEvent] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let separator: Character = line.contains("\t") ? "\t" : ","
            let cells = line.split(separator: separator, omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(
                    in: CharacterSet(charactersIn: "\"")) }
            guard cells.count >= 2, let year = Int(cells[0]), !cells[1].isEmpty
            else { continue }
            let links = cells.count >= 3 ? Int(cells[2]) ?? 10 : 10
            events.append(FloorEvent(year: year, title: cells[1], links: links))
        }
        return events
    }

    /// One theme's events from Wikidata, ranked by how many Wikipedias
    /// carry each — fetched once and mirrored, like the temperature
    /// lines. Unlabelled items (a bare Q-number) are left out.
    static func fetchFloorHistory(theme: FloorTheme) async throws -> [FloorEvent] {
        try await fetchFloorEvents(query: theme.query)
    }

    /// Any SPARQL against Wikidata that binds ?itemLabel, ?year, and
    /// ?links — the built-in themes and the user's own queries share
    /// this one wire.
    static func fetchFloorEvents(query: String) async throws -> [FloorEvent] {
        var components = URLComponents(string: "https://query.wikidata.org/sparql")!
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "format", value: "json"),
        ]
        var request = URLRequest(url: components.url!, timeoutInterval: 60)
        request.setValue("OrigamiText/1.0 (mailto:frode@hegland.com)",
                         forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        // A bad query comes back as a Java exception in plain text —
        // fish Wikidata's own words out rather than failing to parse
        // it as JSON.
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let body = String(decoding: data, as: UTF8.self)
            let reason = body.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first {
                    $0.localizedCaseInsensitiveContains("exception")
                        || $0.localizedCaseInsensitiveContains("error")
                }?
                .prefix(200)
            throw FetchError.queryRejected(
                reason.map(String.init) ?? "the server answered with status \(status).")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = object["results"] as? [String: Any],
              let bindings = results["bindings"] as? [[String: Any]] else {
            throw FetchError.queryRejected("""
                the answer was not JSON. The query must SELECT ?itemLabel, \
                (YEAR(?date) AS ?year), and ?links.
                """)
        }
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
