import Foundation

/// A human-assigned document date: the optional `date` field of the format.
/// Meeting notes written the morning after carry the meeting's date; a
/// transcription of an ancient text can carry the text's own date.
///
/// Stored as an ISO-style string with three precisions — "2026-07-07",
/// "2026-07", "2026" — and BCE as a non-positive year per ISO 8601
/// (year 0 is 1 BCE, so 329 BCE is stored as "-0328"). The UI speaks
/// plain "329 BCE"; only the wire format uses the astronomical year.
nonisolated struct LiquidDate: Hashable, Sendable {
    /// ISO astronomical year: 2026 CE = 2026, 1 BCE = 0, 329 BCE = -328.
    var year: Int
    var month: Int?   // 1–12
    var day: Int?     // 1–31, only meaningful when month is present

    var isBCE: Bool { year <= 0 }

    /// The year as people say it: "-328" displays as 329 (BCE).
    var displayYear: Int { isBCE ? 1 - year : year }

    init(year: Int, month: Int? = nil, day: Int? = nil) {
        self.year = year
        self.month = month.flatMap { (1...12).contains($0) ? $0 : nil }
        self.day = (self.month != nil) ? day.flatMap { (1...31).contains($0) ? $0 : nil } : nil
    }

    /// From what people say: displayYear 329 + bce → ISO year -328.
    init(displayYear: Int, isBCE: Bool, month: Int? = nil, day: Int? = nil) {
        self.init(year: isBCE ? 1 - displayYear : displayYear, month: month, day: day)
    }

    // MARK: - Wire format

    /// Parses "2026-07-07", "2026-07", "2026", "-0328", "-0328-05".
    init?(isoString: String) {
        let pattern = /^(-?\d{1,6})(?:-(\d{1,2}))?(?:-(\d{1,2}))?$/
        guard let match = isoString.trimmingCharacters(in: .whitespaces).wholeMatch(of: pattern),
              let year = Int(match.1) else { return nil }
        let month = match.2.flatMap { Int($0) }
        let day = match.3.flatMap { Int($0) }
        if let month, !(1...12).contains(month) { return nil }
        if let day, !(1...31).contains(day) { return nil }
        self.init(year: year, month: month, day: day)
    }

    var isoString: String {
        var text = year < 0
            ? "-" + String(format: "%04d", -year)
            : String(format: "%04d", year)
        if let month {
            text += String(format: "-%02d", month)
            if let day {
                text += String(format: "-%02d", day)
            }
        }
        return text
    }

    // MARK: - Sorting

    /// A concrete instant for sorting and filtering alongside `created`
    /// timestamps. Missing precision resolves to the start of the period.
    var sortDate: Date {
        var components = DateComponents()
        components.era = isBCE ? 0 : 1
        components.year = displayYear
        components.month = month ?? 1
        components.day = day ?? 1
        components.hour = 12
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar.date(from: components) ?? .distantPast
    }

    // MARK: - Display

    private static let monthNames = [
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December",
    ]

    /// "2026" or "329 BCE" — also the year of a citation.
    var yearText: String { isBCE ? "\(displayYear) BCE" : "\(displayYear)" }

    /// "July 2026", or just the year when month is unknown — timeline labels.
    var monthYearText: String {
        guard let month else { return yearText }
        return "\(Self.monthNames[month - 1]) \(yearText)"
    }

    /// "7 July 2026", "July 2026", "2026", "15 March 44 BCE".
    var displayText: String {
        guard let month, let day else { return monthYearText }
        return "\(day) \(Self.monthNames[month - 1]) \(yearText)"
    }
}
