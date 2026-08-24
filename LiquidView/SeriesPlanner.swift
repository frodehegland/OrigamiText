// Brought across from Liquid Information (Intelligence/SeriesPlanner.swift),
// the sibling lab app whose + dialog these serve. Keep in step;
// a fix here should be carried back.
import Foundation
import FoundationModels

// MARK: - Plan types (what the model generates)

/// The kind of real-world data a line represents. Fetching is routed by
/// kind: weather goes to Open-Meteo, market to Yahoo Finance, statistic
/// to the World Bank.
@Generable
nonisolated enum PlannedSeriesKind: String, Sendable {
    case weather
    case market
    case statistic
    case space
    /// The model's escape hatch: a request that fits no supported domain
    /// fails with a clear message instead of being shoehorned into one.
    case unknown
}

/// A user-selectable domain hint. `any` leaves routing to the model;
/// picking a category pins every planned request to that kind.
enum DataCategory: String, CaseIterable, Identifiable {
    case any = "Any"
    case weather = "Weather"
    case markets = "Finance"
    case statistics = "Statistics"
    case space = "Space"

    var id: String { rawValue }

    var pinnedKind: String? {
        switch self {
        case .any: return nil
        case .weather: return "weather"
        case .markets: return "market"
        case .statistics: return "statistic"
        case .space: return "space"
        }
    }
}

/// An editing command the user can phrase in natural language alongside
/// (or instead of) a fetch request — e.g. "align all on the time axis".
@Generable
nonisolated enum PlannedCommand: String, Sendable {
    case none
    case lockTime
    case unlockTime
    case arrange
}

/// A structured fetch plan produced by the on-device model via guided
/// generation. The model never sees the fetched data — a year of daily
/// values would not fit its context window — it only routes the request.
@Generable
nonisolated struct SeriesPlan: Sendable {
    @Generable
    nonisolated struct Request: Sendable {
        @Guide(description: "weather for historical weather at a place; market for stock indices, tickers, crypto, currencies or commodities; statistic for yearly country figures; space for solar and space-weather activity; unknown when the request fits none of these")
        var kind: PlannedSeriesKind

        @Guide(description: "City or place for weather; index, ticker, crypto, currency or commodity name for market; country name for statistic; the sun for space")
        var subject: String

        @Guide(description: "What to measure. Weather: temperature, max temperature, min temperature, rainfall, snowfall, or wind. Statistic: population, gdp, life expectancy, or inflation. Space: sunspots or radio flux. Market: leave empty")
        var metric: String

        @Guide(description: "For statistic only: the subject country's ISO 3166-1 alpha-2 code, e.g. NO for Norway. Otherwise empty")
        var region: String

        @Guide(description: "Inclusive start date, format YYYY-MM-DD")
        var startDate: String

        @Guide(description: "Inclusive end date, format YYYY-MM-DD")
        var endDate: String

        @Guide(description: "true only when the user stated a time range or duration; false when you filled in a default")
        var rangeWasStated: Bool

        @Guide(description: "Short display label for the line, e.g. London temperature")
        var label: String
    }

    @Guide(description: "One entry per data line the user asked for; empty when the user only gave a command")
    var requests: [Request]

    @Guide(description: "lockTime when the user asks to align or lock lines on the time axis; unlockTime to detach or unlock them; none when they are asking for data")
    var command: PlannedCommand

    @Guide(description: "For a command: which lines it applies to — all, selected, or the line labels separated by commas. Empty when command is none")
    var commandTarget: String
}

// MARK: - Planner

enum SeriesPlannerError: Error, LocalizedError {
    case unavailable(String)
    case emptyPlan
    case unsupported(String)
    case tooLittleData(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason):
            return reason
        case .emptyPlan:
            return "The request did not describe any data to fetch. Try naming a place or a market index and a time range."
        case .unsupported(let subject):
            return "“\(subject)” is outside what can be fetched right now: weather, markets, country statistics, and solar activity."
        case .tooLittleData(let label):
            return "Only a single data point came back for “\(label)”. Try a longer time range."
        }
    }
}

/// One short follow-up question, generated when a request can't be
/// routed to fetchable data.
@Generable
nonisolated struct FollowUpQuestion: Sendable {
    @Guide(description: "One short, concrete question to the user that would identify fetchable data or offer the closest supported alternative")
    var question: String
}

/// Turns a natural-language request ("temperature in London for the last
/// year, and the NASDAQ") into a `SeriesPlan` using the on-device model.
enum SeriesPlanner {
    /// nil when the on-device model can be used; otherwise a user-facing reason.
    static var unavailabilityReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return "This device does not support Apple Intelligence, which is needed to interpret data requests."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence in Settings to interpret data requests."
        case .unavailable(.modelNotReady):
            return "The on-device model is still downloading. Try again in a little while."
        case .unavailable:
            return "The on-device model is not available right now."
        }
    }

    static func plan(for request: String, category: DataCategory = .any) async throws -> SeriesPlan {
        if let reason = unavailabilityReason {
            throw SeriesPlannerError.unavailable(reason)
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let now = Date()
        let today = formatter.string(from: now)
        let yearAgo = formatter.string(from: now.addingTimeInterval(-365 * 86_400))
        let sixMonthsAgo = formatter.string(from: now.addingTimeInterval(-183 * 86_400))
        let monthAgo = formatter.string(from: now.addingTimeInterval(-30 * 86_400))

        // The small model is unreliable at date arithmetic, so the common
        // relative ranges are precomputed and given verbatim.
        let session = LanguageModelSession(instructions: """
            You translate a user's natural-language request for data lines into a structured fetch plan.
            You do not produce data values yourself; you only decide what to fetch.
            Today's date is \(today). Use these exact ranges: \
            "the last year" or no stated range: startDate \(yearAgo), endDate \(today). \
            "the last six months": startDate \(sixMonthsAgo), endDate \(today). \
            "the last month": startDate \(monthAgo), endDate \(today). \
            Exceptions: statistic requests are yearly figures — when no range is stated, \
            use startDate 1960-01-01, endDate \(today); "since <year>" means startDate <year>-01-01. \
            space requests (solar activity, sunspots, radio flux) are monthly — when no range \
            is stated, use startDate 1960-01-01, endDate \(today).
            Every line in one request shares the same range unless the user says otherwise.
            Set rangeWasStated true only when the user actually expressed a range or duration \
            (a year, "last month", "since 2000", a clarified range); false when you used a default. \
            Remember: a statistic or space request with no stated range MUST use startDate 1960-01-01, \
            endDate \(today), with rangeWasStated false.
            Create one request per distinct data line the user asks for.
            The user can also give commands about existing lines instead of (or as well as) \
            requesting data: "align …" or "lock …" on the time axis means command lockTime; \
            "unlock …" or "detach …" means command unlockTime; "arrange", "tidy", or \
            "lay out" the nodes/structure means command arrange. Set commandTarget to all, \
            selected, or — when the user names lines — those labels, comma-separated. \
            A pure command has no requests; lines named only as command targets are not requests. \
            When the user asks for new data AND for alignment ("… aligned in time"), set both \
            the requests and command lockTime.
            If a request fits none of the supported kinds, use kind unknown — never force it into another kind.
            \(category.pinnedKind.map { "The user selected a category: every request must use kind \($0)." } ?? "")
            """)
        let plan = try await session.respond(to: request, generating: SeriesPlan.self).content
        guard !plan.requests.isEmpty || plan.command != .none else { throw SeriesPlannerError.emptyPlan }
        return plan
    }

    /// Requests whose time range the app should ask about rather than
    /// assume: the user stated none, and the kind has no natural default.
    /// Statistics and solar activity default to full history — a canonical
    /// choice — so they are exempt; a defaulted weather or market range
    /// ("bergen rain" — since when?) is an invented decision. The model's
    /// own `rangeWasStated` is unreliable on terse prompts, so a lexical
    /// check of the user's actual words backs it up: if the text contains
    /// nothing time-like, the range was not stated, whatever the model says.
    static func requestsNeedingRange(in plan: SeriesPlan, userText: String) -> [SeriesPlan.Request] {
        let textHasRange = textMentionsRange(userText)
        return plan.requests.filter { request in
            guard request.kind == .weather || request.kind == .market else { return false }
            return !textHasRange || !request.rangeWasStated
        }
    }

    // (Origami adaptation: adoptingExistingRange stayed behind in
    // Liquid Information — the Time Flows have no shared scene span
    // to adopt.)

    /// True when the text contains anything time-like: a digit (years,
    /// counts of units) or a temporal word.
    static func textMentionsRange(_ text: String) -> Bool {
        if text.contains(where: \.isNumber) { return true }
        let lowered = text.lowercased()
        let temporalWords = [
            "last", "past", "since", "year", "month", "week", "day", "today",
            "decade", "century", "recent", "so far", "to date", "until", "ago",
            "current", "latest", "all time", "history",
            "january", "february", "march", "april", "may", "june", "july",
            "august", "september", "october", "november", "december",
            "spring", "summer", "autumn", "fall", "winter"
        ]
        return temporalWords.contains { lowered.contains($0) }
    }

    /// The small model sometimes hallucinates a command on a plain data
    /// request ("add a third graph" → lockTime), which surfaces as a
    /// baffling alignment question. A command only counts when the user's
    /// own words contain a trigger for it — the same lexical backup that
    /// `requestsNeedingRange` applies to time ranges.
    static func commandWasStated(_ command: PlannedCommand, in text: String) -> Bool {
        let triggers: [String]
        switch command {
        case .none:
            return true
        case .lockTime:
            triggers = ["align", "lock", "sync", "time axis", "same axis"]
        case .unlockTime:
            triggers = ["unlock", "unalign", "unsync", "detach", "release", "separate"]
        case .arrange:
            triggers = ["arrange", "tidy", "lay out", "layout", "organise", "organize", "group", "sort"]
        }
        let lowered = text.lowercased()
        return triggers.contains { lowered.contains($0) }
    }

    /// True for failures a user's answer could fix — the AI not knowing
    /// what data was meant, an unresolvable place or subject, a range too
    /// thin to draw. Network faults are not clarifiable.
    static func isClarifiable(_ error: Error) -> Bool {
        switch error {
        case SeriesPlannerError.unsupported, SeriesPlannerError.emptyPlan, SeriesPlannerError.tooLittleData:
            return true
        case DataFetchError.placeNotFound, DataFetchError.noData:
            return true
        default:
            return false
        }
    }

    /// Asks the on-device model to formulate one follow-up question that
    /// would help map an unfulfillable request onto fetchable data.
    static func clarifyingQuestion(for request: String, problem: String) async throws -> String {
        if let reason = unavailabilityReason {
            throw SeriesPlannerError.unavailable(reason)
        }
        let session = LanguageModelSession(instructions: """
            You help a user whose data request could not be fulfilled. The app can fetch \
            time-series lines in exactly these domains: weather (temperature, max/min \
            temperature, rainfall, snowfall, wind — for a named place), markets (stock \
            indices, tickers, crypto, currencies, commodities), yearly country statistics \
            (population, GDP, life expectancy, inflation), and solar activity (sunspots, \
            radio flux). Ask exactly one short, concrete question that helps the user \
            restate their request as fetchable data — for example by suggesting the \
            nearest supported alternative, or asking which place, market, or country \
            they meant. Refer to what the user actually asked for; do not apologize; just ask.
            """)
        let response = try await session.respond(to: "Request: \(request)\nProblem: \(problem)",
                                                 generating: FollowUpQuestion.self)
        return response.content.question
    }

    /// Line colors, cycled by document order so new lines don't repeat
    /// the colors already in the space. Shared with the file importer.
    static let palette = ["4A90D9", "E2984A", "50B86C", "D95757", "7B61FF", "39B8C4"]

    /// Semantic default colors: anything to do with the sun is yellow;
    /// finance lines are green (the renderer shades negative values red);
    /// everything else cycles the palette.
    private static func defaultColor(for kind: PlannedSeriesKind, index: Int) -> String {
        switch kind {
        case .space: return "FFD60A"
        case .market: return "34C759"
        default: return palette[index % palette.count]
        }
    }

    /// Executes a plan: fetches each requested series. (Origami
    /// adaptation: returns the fetched series themselves — the Time
    /// Flows carry no scene identity, color, or form.)
    static func makeFetched(for plan: SeriesPlan) async throws -> [FetchedSeries] {
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let today = dayFormatter.string(from: Date())

        var made: [FetchedSeries] = []
        for planned in plan.requests {
            var request = planned
            // The full-history default for yearly statistics and solar
            // activity is enforced here — the small model applies it
            // inconsistently when left to instructions alone.
            if !request.rangeWasStated, request.kind == .statistic || request.kind == .space {
                request.startDate = "1960-01-01"
                request.endDate = today
            }
            // Metrics resolve from the metric field plus the label as
            // fallback context — the small model sometimes puts "rainfall"
            // in one and not the other.
            let metricText = "\(request.metric) \(request.label)"
            let fetched: FetchedSeries
            switch request.kind {
            case .weather:
                fetched = try await DataSeriesFetcher.dailyWeather(place: request.subject,
                                                                   metric: .resolve(metricText),
                                                                   startDate: request.startDate,
                                                                   endDate: request.endDate)
            case .market:
                fetched = try await DataSeriesFetcher.marketClosingValues(subject: request.subject,
                                                                          startDate: request.startDate,
                                                                          endDate: request.endDate)
            case .statistic:
                fetched = try await DataSeriesFetcher.statistic(countryCode: request.region.isEmpty ? request.subject : request.region,
                                                                metric: .resolve(metricText),
                                                                startDate: request.startDate,
                                                                endDate: request.endDate)
            case .space:
                fetched = try await DataSeriesFetcher.solarActivity(metric: .resolve(metricText),
                                                                    startDate: request.startDate,
                                                                    endDate: request.endDate)
            case .unknown:
                throw SeriesPlannerError.unsupported(request.subject)
            }
            // One point cannot make a line — the renderer would draw it
            // flat and imply data that isn't there.
            guard fetched.points.count >= 2 else {
                throw SeriesPlannerError.tooLittleData(fetched.label)
            }
            let label = request.label.trimmingCharacters(in: .whitespacesAndNewlines)
            var named = fetched
            if !label.isEmpty { named.label = label }
            made.append(named)
        }
        return made
    }
}
