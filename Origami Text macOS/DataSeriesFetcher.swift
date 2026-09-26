// Brought across from Liquid Information (Intelligence/DataSeriesFetcher.swift),
// the sibling lab app whose + dialog these serve. Keep in step;
// a fix here should be carried back.
import Foundation

/// A fetched, render-ready data series before it is given an identity and
/// color inside a document.
nonisolated struct FetchedSeries: Sendable {
    var label: String
    var unit: String
    var points: [SeriesPoint]
    var sourceName: String
    var sourceURL: String
    /// True when the data has no time dimension (a loaded table without
    /// a date column); the point dates then only encode row order.
    var timeless: Bool = false
}

nonisolated enum DataFetchError: Error, LocalizedError, Sendable {
    case badURL
    case badResponse(String)
    case placeNotFound(String)
    case noData(String)

    var errorDescription: String? {
        switch self {
        case .badURL:
            return "Could not build a request URL."
        case .badResponse(let host):
            return "\(host) did not return a usable response."
        case .placeNotFound(let place):
            return "No location named “\(place)” was found."
        case .noData(let subject):
            return "No data came back for “\(subject)”."
        }
    }
}

/// Fetches real-world time series from free, key-less public endpoints:
/// Open-Meteo for weather history, Stooq for market data. Fetching is
/// deterministic app code — the on-device model only plans what to fetch
/// and never handles the data itself.
nonisolated enum DataSeriesFetcher {
    /// Series are thinned to at most this many points before they are
    /// stored, keeping documents small and the polyline entity count low.
    static let maximumStoredPoints = 90

    // MARK: Weather (Open-Meteo)

    /// The daily weather variables the fetcher can ask the archive for.
    nonisolated enum WeatherMetric: String, CaseIterable, Sendable {
        case temperature, temperatureMax, temperatureMin, rainfall, snowfall, wind

        var apiParameter: String {
            switch self {
            case .temperature: return "temperature_2m_mean"
            case .temperatureMax: return "temperature_2m_max"
            case .temperatureMin: return "temperature_2m_min"
            case .rainfall: return "precipitation_sum"
            case .snowfall: return "snowfall_sum"
            case .wind: return "wind_speed_10m_max"
            }
        }

        var unit: String {
            switch self {
            case .temperature, .temperatureMax, .temperatureMin: return "°C"
            case .rainfall: return "mm"
            case .snowfall: return "cm"
            case .wind: return "km/h"
            }
        }

        var noun: String {
            switch self {
            case .temperature: return "mean temperature"
            case .temperatureMax: return "max temperature"
            case .temperatureMin: return "min temperature"
            case .rainfall: return "daily precipitation"
            case .snowfall: return "daily snowfall"
            case .wind: return "max wind speed"
            }
        }

        /// Lenient keyword resolution from whatever the planner produced.
        static func resolve(_ text: String) -> WeatherMetric {
            let lowered = text.lowercased()
            if lowered.contains("rain") || lowered.contains("precip") { return .rainfall }
            if lowered.contains("snow") { return .snowfall }
            if lowered.contains("wind") { return .wind }
            if lowered.contains("max") || lowered.contains("high") { return .temperatureMax }
            if lowered.contains("min") || lowered.contains("low") { return .temperatureMin }
            return .temperature
        }
    }

    static func dailyWeather(place: String, metric: WeatherMetric, startDate: String, endDate: String) async throws -> FetchedSeries {
        let located = try await geocode(place)

        var components = URLComponents(string: "https://archive-api.open-meteo.com/v1/archive")
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(located.latitude)),
            URLQueryItem(name: "longitude", value: String(located.longitude)),
            URLQueryItem(name: "start_date", value: startDate),
            URLQueryItem(name: "end_date", value: clampedToArchiveWindow(endDate)),
            URLQueryItem(name: "daily", value: metric.apiParameter),
            URLQueryItem(name: "timezone", value: "auto")
        ]
        guard let url = components?.url else { throw DataFetchError.badURL }

        /// The value array arrives under the requested variable's name, so
        /// the key is looked up dynamically: whatever sibling `time` has.
        struct ArchiveDaily: Decodable {
            let time: [String]
            let values: [Double?]

            struct DynamicKey: CodingKey {
                var stringValue: String
                var intValue: Int? { nil }
                init?(stringValue: String) { self.stringValue = stringValue }
                init?(intValue: Int) { return nil }
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: DynamicKey.self)
                time = try container.decode([String].self, forKey: DynamicKey(stringValue: "time")!)
                if let valueKey = container.allKeys.first(where: { $0.stringValue != "time" }) {
                    values = try container.decode([Double?].self, forKey: valueKey)
                } else {
                    values = []
                }
            }
        }
        struct ArchiveResponse: Decodable { let daily: ArchiveDaily? }

        let response = try JSONDecoder().decode(ArchiveResponse.self, from: try await fetchData(from: url))
        guard let daily = response.daily else { throw DataFetchError.noData(place) }

        let formatter = isoDayFormatter()
        var points: [SeriesPoint] = []
        for (day, value) in zip(daily.time, daily.values) {
            guard let value, let date = formatter.date(from: day) else { continue }
            points.append(SeriesPoint(date: date, value: value))
        }
        guard !points.isEmpty else { throw DataFetchError.noData(place) }

        return FetchedSeries(label: "\(located.name) \(metric.noun)",
                             unit: metric.unit,
                             points: downsampled(points),
                             sourceName: "Open-Meteo",
                             sourceURL: url.absoluteString)
    }

    private struct GeocodedPlace: Decodable {
        let name: String
        let latitude: Double
        let longitude: Double
    }

    private static func geocode(_ place: String) async throws -> GeocodedPlace {
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")
        components?.queryItems = [
            URLQueryItem(name: "name", value: place),
            URLQueryItem(name: "count", value: "1"),
            URLQueryItem(name: "language", value: "en"),
            URLQueryItem(name: "format", value: "json")
        ]
        guard let url = components?.url else { throw DataFetchError.badURL }

        struct GeocodeResponse: Decodable { let results: [GeocodedPlace]? }
        let response = try JSONDecoder().decode(GeocodeResponse.self, from: try await fetchData(from: url))
        guard let first = response.results?.first else { throw DataFetchError.placeNotFound(place) }
        return first
    }

    /// The Open-Meteo archive lags a few days behind live weather; asking
    /// past its window yields trailing nulls, so the end date is clamped.
    private static func clampedToArchiveWindow(_ endDate: String) -> String {
        let formatter = isoDayFormatter()
        let latest = Date().addingTimeInterval(-6 * 86_400)
        guard let requested = formatter.date(from: endDate), requested > latest else { return endDate }
        return formatter.string(from: latest)
    }

    // MARK: Markets (Yahoo Finance chart API)

    static func marketClosingValues(subject: String, startDate: String, endDate: String) async throws -> FetchedSeries {
        let symbol = marketSymbol(for: subject)
        let formatter = isoDayFormatter()
        guard let start = formatter.date(from: startDate), let end = formatter.date(from: endDate),
              let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(encoded)"
                            + "?period1=\(Int(start.timeIntervalSince1970))"
                            + "&period2=\(Int(end.timeIntervalSince1970) + 86_400)"
                            + "&interval=1d") else {
            throw DataFetchError.badURL
        }

        struct ChartResponse: Decodable {
            struct Chart: Decodable { let result: [Result]? }
            struct Result: Decodable {
                let meta: Meta?
                let timestamp: [Int]?
                let indicators: Indicators
            }
            struct Meta: Decodable { let currency: String? }
            struct Indicators: Decodable { let quote: [Quote] }
            struct Quote: Decodable { let close: [Double?]? }
            let chart: Chart
        }
        let response = try JSONDecoder().decode(ChartResponse.self, from: try await fetchData(from: url))
        guard let result = response.chart.result?.first,
              let timestamps = result.timestamp,
              let closes = result.indicators.quote.first?.close else {
            throw DataFetchError.noData(subject)
        }

        var points: [SeriesPoint] = []
        for (timestamp, close) in zip(timestamps, closes) {
            guard let close else { continue }
            points.append(SeriesPoint(date: Date(timeIntervalSince1970: TimeInterval(timestamp)), value: close))
        }
        guard !points.isEmpty else { throw DataFetchError.noData(subject) }

        let isIndex = symbol.hasPrefix("^")
        return FetchedSeries(label: "\(displayName(for: symbol, subject: subject)) close",
                             unit: isIndex ? "points" : (result.meta?.currency ?? ""),
                             points: downsampled(points),
                             sourceName: "Yahoo Finance",
                             sourceURL: url.absoluteString)
    }

    /// Maps a spoken subject ("the NASDAQ", "bitcoin", "gold", "Apple
    /// stock") to a Yahoo symbol: indices, crypto, currencies, and
    /// commodities by name; anything else treated as a ticker.
    private static func marketSymbol(for subject: String) -> String {
        let lowered = subject.lowercased()
        // Indices
        if lowered.contains("nasdaq") {
            return lowered.contains("100") ? "^NDX" : "^IXIC"
        }
        if lowered.contains("s&p") || lowered.contains("sp 500") || lowered.contains("sp500") { return "^GSPC" }
        if lowered.contains("dow") { return "^DJI" }
        if lowered.contains("dax") { return "^GDAXI" }
        if lowered.contains("nikkei") { return "^N225" }
        if lowered.contains("ftse") { return "^FTSE" }
        // Crypto
        if lowered.contains("bitcoin") || lowered == "btc" { return "BTC-USD" }
        if lowered.contains("ethereum") || lowered == "eth" { return "ETH-USD" }
        // Commodities (front-month futures)
        if lowered.contains("gold") { return "GC=F" }
        if lowered.contains("silver") { return "SI=F" }
        if lowered.contains("brent") { return "BZ=F" }
        if lowered.contains("oil") || lowered.contains("crude") || lowered.contains("wti") { return "CL=F" }
        // Currencies (rate against the US dollar)
        if lowered.contains("euro") || lowered.contains("eur") { return "EURUSD=X" }
        if lowered.contains("pound") || lowered.contains("sterling") || lowered.contains("gbp") { return "GBPUSD=X" }
        if lowered.contains("yen") || lowered.contains("jpy") { return "USDJPY=X" }
        if lowered.contains("krone") || lowered.contains("nok") { return "USDNOK=X" }
        if lowered.contains("franc") || lowered.contains("chf") { return "USDCHF=X" }
        // Company names the model tends to leave unresolved
        if lowered.contains("apple") { return "AAPL" }
        if lowered.contains("microsoft") { return "MSFT" }
        if lowered.contains("tesla") { return "TSLA" }
        if lowered.contains("nvidia") { return "NVDA" }
        return subject.uppercased().filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "^" || $0 == "-" || $0 == "=" }
    }

    private static func displayName(for symbol: String, subject: String) -> String {
        switch symbol {
        case "^IXIC": return "NASDAQ Composite"
        case "^NDX": return "NASDAQ 100"
        case "^GSPC": return "S&P 500"
        case "^DJI": return "Dow Jones"
        case "^GDAXI": return "DAX"
        case "^N225": return "Nikkei 225"
        case "^FTSE": return "FTSE 100"
        case "BTC-USD": return "Bitcoin"
        case "ETH-USD": return "Ethereum"
        case "GC=F": return "Gold"
        case "SI=F": return "Silver"
        case "CL=F": return "Crude oil (WTI)"
        case "BZ=F": return "Brent crude"
        case "EURUSD=X": return "EUR/USD"
        case "GBPUSD=X": return "GBP/USD"
        case "USDJPY=X": return "USD/JPY"
        case "USDNOK=X": return "USD/NOK"
        case "USDCHF=X": return "USD/CHF"
        default: return symbol
        }
    }

    // MARK: Country statistics (World Bank)

    /// The yearly country indicators the fetcher can ask the World Bank for.
    nonisolated enum StatisticMetric: String, CaseIterable, Sendable {
        case population, gdp, lifeExpectancy, inflation

        var indicator: String {
            switch self {
            case .population: return "SP.POP.TOTL"
            case .gdp: return "NY.GDP.MKTP.CD"
            case .lifeExpectancy: return "SP.DYN.LE00.IN"
            case .inflation: return "FP.CPI.TOTL.ZG"
            }
        }

        var unit: String {
            switch self {
            case .population: return "people"
            case .gdp: return "US$"
            case .lifeExpectancy: return "years"
            case .inflation: return "%"
            }
        }

        var noun: String {
            switch self {
            case .population: return "population"
            case .gdp: return "GDP"
            case .lifeExpectancy: return "life expectancy"
            case .inflation: return "inflation"
            }
        }

        /// Lenient keyword resolution from whatever the planner produced.
        static func resolve(_ text: String) -> StatisticMetric {
            let lowered = text.lowercased()
            if lowered.contains("gdp") || lowered.contains("economy") || lowered.contains("economic") { return .gdp }
            if lowered.contains("life") || lowered.contains("expectancy") { return .lifeExpectancy }
            if lowered.contains("inflation") || lowered.contains("price") { return .inflation }
            return .population
        }
    }

    /// Yearly values from the World Bank open data API. `countryCode` is
    /// ISO 3166-1 alpha-2 (the planner supplies it; the model knows these
    /// far more reliably than it does API-specific identifiers).
    static func statistic(countryCode: String, metric: StatisticMetric, startDate: String, endDate: String) async throws -> FetchedSeries {
        let code = countryCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard code.count == 2 || code.count == 3, code.allSatisfy(\.isLetter) else {
            throw DataFetchError.placeNotFound(countryCode)
        }
        let startYear = String(startDate.prefix(4))
        let endYear = String(endDate.prefix(4))
        guard let url = URL(string: "https://api.worldbank.org/v2/country/\(code)/indicator/\(metric.indicator)"
                            + "?format=json&per_page=400&date=\(startYear):\(endYear)") else {
            throw DataFetchError.badURL
        }

        // The response is a two-element array: [paging metadata, rows].
        struct Row: Decodable {
            struct Country: Decodable { let value: String }
            let country: Country
            let date: String
            let value: Double?
        }
        struct WorldBankResponse: Decodable {
            let rows: [Row]
            private struct Metadata: Decodable {}
            init(from decoder: Decoder) throws {
                var container = try decoder.unkeyedContainer()
                _ = try? container.decode(Metadata.self)
                rows = (try? container.decode([Row].self)) ?? []
            }
        }
        let response = try JSONDecoder().decode(WorldBankResponse.self, from: try await fetchData(from: url))

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        var points: [SeriesPoint] = []
        for row in response.rows {
            guard let value = row.value, let year = Int(row.date),
                  let date = calendar.date(from: DateComponents(year: year, month: 1, day: 1)) else { continue }
            points.append(SeriesPoint(date: date, value: value))
        }
        points.sort { $0.date < $1.date }
        guard !points.isEmpty else { throw DataFetchError.noData("\(countryCode) \(metric.noun)") }

        let countryName = response.rows.first?.country.value ?? code
        return FetchedSeries(label: "\(countryName) \(metric.noun)",
                             unit: metric.unit,
                             points: downsampled(points),
                             sourceName: "World Bank",
                             sourceURL: url.absoluteString)
    }

    // MARK: Space weather (NOAA SWPC)

    /// Solar-activity measures from NOAA's observed solar-cycle indices,
    /// monthly since 1749.
    nonisolated enum SpaceMetric: String, CaseIterable, Sendable {
        case sunspots, radioFlux

        var noun: String {
            switch self {
            case .sunspots: return "sunspot number"
            case .radioFlux: return "solar radio flux (F10.7)"
            }
        }

        var unit: String {
            switch self {
            case .sunspots: return "sunspots"
            case .radioFlux: return "sfu"
            }
        }

        /// Lenient keyword resolution from whatever the planner produced.
        static func resolve(_ text: String) -> SpaceMetric {
            let lowered = text.lowercased()
            if lowered.contains("flux") || lowered.contains("radio") || lowered.contains("f10") { return .radioFlux }
            return .sunspots
        }
    }

    static func solarActivity(metric: SpaceMetric, startDate: String, endDate: String) async throws -> FetchedSeries {
        guard let url = URL(string: "https://services.swpc.noaa.gov/json/solar-cycle/observed-solar-cycle-indices.json") else {
            throw DataFetchError.badURL
        }

        struct Entry: Decodable {
            let timeTag: String
            let ssn: Double?
            let f107: Double?
            enum CodingKeys: String, CodingKey {
                case timeTag = "time-tag"
                case ssn
                case f107 = "f10.7"
            }
        }
        let entries = try JSONDecoder().decode([Entry].self, from: try await fetchData(from: url))

        let dayFormatter = isoDayFormatter()
        guard let start = dayFormatter.date(from: startDate), let end = dayFormatter.date(from: endDate) else {
            throw DataFetchError.badURL
        }
        let monthFormatter = isoDayFormatter()
        monthFormatter.dateFormat = "yyyy-MM"

        // NOAA uses -1 as a missing-value sentinel; real values are >= 0.
        var points: [SeriesPoint] = []
        for entry in entries {
            guard let date = monthFormatter.date(from: entry.timeTag), date >= start, date <= end,
                  let value = (metric == .sunspots ? entry.ssn : entry.f107), value >= 0 else { continue }
            points.append(SeriesPoint(date: date, value: value))
        }
        guard !points.isEmpty else { throw DataFetchError.noData("solar activity") }

        return FetchedSeries(label: "Solar \(metric.noun)",
                             unit: metric.unit,
                             points: downsampled(points),
                             sourceName: "NOAA SWPC",
                             sourceURL: url.absoluteString)
    }

    // MARK: Shared

    private static func fetchData(from url: URL) async throws -> Data {
        // Yahoo rejects requests without a browser-ish user agent.
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw DataFetchError.badResponse(url.host() ?? "server")
        }
        return data
    }

    private static func isoDayFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    /// Averages runs of consecutive points so the stored series never
    /// exceeds `maximumStoredPoints`, keeping the middle date of each run.
    /// Shared with the file importer, which faces the same size concern.
    static func downsampled(_ points: [SeriesPoint]) -> [SeriesPoint] {
        guard points.count > maximumStoredPoints else { return points }
        let bucketSize = Int((Double(points.count) / Double(maximumStoredPoints)).rounded(.up))
        var result: [SeriesPoint] = []
        var index = 0
        while index < points.count {
            let bucket = points[index..<min(index + bucketSize, points.count)]
            let mean = bucket.reduce(0) { $0 + $1.value } / Double(bucket.count)
            let middle = bucket[bucket.startIndex + bucket.count / 2]
            result.append(SeriesPoint(date: middle.date, value: mean, label: middle.label))
            index += bucketSize
        }
        return result
    }
}
