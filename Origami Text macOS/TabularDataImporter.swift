// Brought across from Liquid Information (Intelligence/TabularDataImporter.swift),
// the sibling lab app whose + dialog these serve. Keep in step;
// a fix here should be carried back.
import Foundation

/// Parses user-supplied tabular text (CSV, TSV, semicolon-delimited, and
/// similar) into series — entirely deterministic app code; no AI touches
/// the file. When the table is ambiguous the importer stops with a
/// question, surfaced in the Import dialog exactly like the AI flow's
/// follow-ups, and re-parses with the user's answer folded into `Choices`.
nonisolated enum TabularDataImporter {

    /// A decision the importer cannot make on its own.
    enum QuestionKind: Sendable {
        case dateColumn, dateOrder, valueColumns
    }

    struct Question: Sendable {
        var kind: QuestionKind
        var text: String
        var options: [String]
    }

    /// Answers accumulated from the user's replies, applied on re-parse.
    struct Choices: Sendable {
        var dateColumn: String?
        var dayFirst: Bool?
        /// Chosen value column names; `["*"]` means every numeric column.
        var valueColumns: [String]?

        init() {}
    }

    enum Outcome: Sendable {
        case series([FetchedSeries])
        case question(Question)
    }

    enum ImportError: Error, LocalizedError, Sendable {
        case empty
        case noDateColumn
        case noValueColumn
        case tooLittleData

        var errorDescription: String? {
            switch self {
            case .empty:
                return "No table was found in the file — at least two rows are needed."
            case .noDateColumn:
                return "No column of dates was found. One column needs dates (like 2026-08-19) or years."
            case .noValueColumn:
                return "No column of numbers was found to draw."
            case .tooLittleData:
                return "Fewer than two rows had both a readable date and a readable value."
            }
        }
    }

    static func parse(text: String, fileName: String, choices: Choices) throws -> Outcome {
        let rows = tableRows(from: text)
        guard rows.count >= 2 else { throw ImportError.empty }
        let columnCount = rows.map(\.count).max() ?? 0
        guard columnCount >= 1 else { throw ImportError.empty }
        let padded = rows.map { $0 + Array(repeating: "", count: columnCount - $0.count) }

        // A first row with any cell that is neither number nor date is a header.
        let hasHeader = padded[0].contains { cell in
            !cell.isEmpty && parseNumber(cell) == nil && parseDate(cell, dayFirst: true) == nil
        }
        let headers = hasHeader
            ? padded[0].enumerated().map { $0.element.isEmpty ? "Column \($0.offset + 1)" : $0.element }
            : (0..<columnCount).map { "Column \($0 + 1)" }
        let dataRows = hasHeader ? Array(padded.dropFirst()) : padded
        guard dataRows.count >= 2 else { throw ImportError.tooLittleData }

        // Profile every column: how often it reads as a date, as a number,
        // and what slashed dates reveal about day/month order.
        var dateHits = [Int](repeating: 0, count: columnCount)
        var numberHits = [Int](repeating: 0, count: columnCount)
        var textHits = [Int](repeating: 0, count: columnCount)
        var dayFirstEvidence = [Bool](repeating: false, count: columnCount)
        var monthFirstEvidence = [Bool](repeating: false, count: columnCount)
        var ambiguousSlash = [Bool](repeating: false, count: columnCount)
        for row in dataRows {
            for (index, cell) in row.enumerated() where !cell.isEmpty {
                let isDate = parseDate(cell, dayFirst: true) != nil
                let isNumber = parseNumber(cell) != nil
                if isDate { dateHits[index] += 1 }
                if isNumber { numberHits[index] += 1 }
                if !isDate && !isNumber { textHits[index] += 1 }
                if let pair = slashDayMonthPair(cell) {
                    if pair.first > 12 { dayFirstEvidence[index] = true }
                    else if pair.second > 12 { monthFirstEvidence[index] = true }
                    else if pair.first != pair.second { ambiguousSlash[index] = true }
                }
            }
        }

        // The date column: the user's answer wins; otherwise the columns
        // that read as dates, preferring textual dates over bare years.
        // A table with no date column at all is accepted — it imports as
        // timeless, in row order, and never joins a time lock.
        let dateThreshold = max(2, (dataRows.count * 4) / 5)
        let candidateIndices = (0..<columnCount).filter { dateHits[$0] >= dateThreshold }
        let dateIndex: Int?
        if let chosen = choices.dateColumn,
           let index = headers.firstIndex(where: { $0.compare(chosen, options: .caseInsensitive) == .orderedSame }) {
            dateIndex = index
        } else if candidateIndices.isEmpty {
            dateIndex = nil
        } else if candidateIndices.count == 1 {
            dateIndex = candidateIndices[0]
        } else {
            let textual = candidateIndices.filter { numberHits[$0] < dateHits[$0] / 2 }
            if textual.count == 1 {
                dateIndex = textual[0]
            } else {
                return .question(Question(kind: .dateColumn,
                                          text: "Which column holds the dates?",
                                          options: candidateIndices.map { headers[$0] }))
            }
        }

        // Day-first or month-first: the data itself decides when it can
        // (a 25 in either position settles it); otherwise the user does.
        let effectiveDayFirst: Bool
        if let chosen = choices.dayFirst {
            effectiveDayFirst = chosen
        } else if let dateIndex, ambiguousSlash[dateIndex],
                  !dayFirstEvidence[dateIndex], !monthFirstEvidence[dateIndex] {
            return .question(Question(kind: .dateOrder,
                                      text: "How should dates like 03/04/2026 be read?",
                                      options: ["Day first — 3 April 2026", "Month first — March 4, 2026"]))
        } else if let dateIndex, monthFirstEvidence[dateIndex] {
            effectiveDayFirst = false
        } else {
            effectiveDayFirst = true
        }

        // The value columns: everything numeric that isn't the date.
        let valueThreshold = max(2, (dataRows.count * 3) / 5)
        let valueCandidates = (0..<columnCount).filter { $0 != dateIndex && numberHits[$0] >= valueThreshold }
        guard !valueCandidates.isEmpty else { throw ImportError.noValueColumn }
        let valueIndices: [Int]
        if let chosen = choices.valueColumns {
            if chosen == ["*"] {
                valueIndices = valueCandidates
            } else {
                let lowered = chosen.map { $0.lowercased() }
                let matched = valueCandidates.filter { lowered.contains(headers[$0].lowercased()) }
                valueIndices = matched.isEmpty ? valueCandidates : matched
            }
        } else if valueCandidates.count == 1 {
            valueIndices = valueCandidates
        } else {
            return .question(Question(kind: .valueColumns,
                                      text: "Which columns should become lines?",
                                      options: ["All columns"] + valueCandidates.map { headers[$0] }))
        }

        // A timeless table's mostly-text column names its rows — "Norway,
        // Sweden, Denmark" — and those names travel onto the points.
        let textThreshold = max(2, (dataRows.count * 4) / 5)
        let labelIndex: Int? = dateIndex == nil
            ? (0..<columnCount).first(where: { textHits[$0] >= textThreshold })
            : nil

        var made: [FetchedSeries] = []
        for index in valueIndices {
            var points: [SeriesPoint] = []
            for (rowIndex, row) in dataRows.enumerated() {
                guard let value = parseNumber(row[index]) else { continue }
                if let dateIndex {
                    guard let date = parseDate(row[dateIndex], dayFirst: effectiveDayFirst) else { continue }
                    points.append(SeriesPoint(date: date, value: value))
                } else {
                    // Timeless: the date only encodes row order and is
                    // never shown or matched against real timelines.
                    let name = labelIndex.map { row[$0] }.flatMap { $0.isEmpty ? nil : $0 }
                    points.append(SeriesPoint(date: Date(timeIntervalSince1970: TimeInterval(rowIndex) * 86_400),
                                              value: value,
                                              label: name))
                }
            }
            points.sort { $0.date < $1.date }
            guard points.count >= 2 else { continue }
            let label = hasHeader ? headers[index] : fileName
            made.append(FetchedSeries(label: label,
                                      unit: "",
                                      points: DataSeriesFetcher.downsampled(points),
                                      sourceName: "Imported file",
                                      sourceURL: fileName,
                                      timeless: dateIndex == nil))
        }
        guard !made.isEmpty else { throw ImportError.tooLittleData }
        return .series(made)
    }

    // MARK: Cells

    /// Splits the text into rows of fields. The delimiter is whichever of
    /// comma, semicolon or tab the first line uses most; a line with none
    /// of them falls back to whitespace-separated fields.
    private static func tableRows(from text: String) -> [[String]] {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        guard let sample = lines.first else { return [] }
        let candidates: [Character] = [",", ";", "\t"]
        let delimiter = candidates
            .map { character in (character, sample.filter { $0 == character }.count) }
            .max { $0.1 < $1.1 }
            .flatMap { $0.1 > 0 ? $0.0 : nil }
        return lines.map { line in
            if let delimiter {
                return splitFields(line, on: delimiter)
            }
            return line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        }
    }

    /// Quote-aware field split: delimiters inside "quoted" fields don't count.
    private static func splitFields(_ line: String, on delimiter: Character) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        for character in line {
            if character == "\"" {
                inQuotes.toggle()
            } else if character == delimiter && !inQuotes {
                fields.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        fields.append(current.trimmingCharacters(in: .whitespaces))
        return fields
    }

    private static func parseNumber(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let value = Double(trimmed) { return value }
        // A European decimal comma, but only when the swap leaves one dot.
        let swapped = trimmed.replacingOccurrences(of: ",", with: ".")
        if swapped.filter({ $0 == "." }).count == 1, let value = Double(swapped) {
            return value
        }
        return nil
    }

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }()

    /// Reads a date cell: ISO forms (2026-08-19), slashed or dotted
    /// day/month/year forms (`dayFirst` resolves 03/04/2026), and bare
    /// four-digit years. Any time part after `T` or a space is ignored.
    private static func parseDate(_ raw: String, dayFirst: Bool) -> Date? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if let timeStart = s.firstIndex(where: { $0 == "T" || $0 == " " }) {
            s = String(s[..<timeStart])
        }
        guard !s.isEmpty else { return nil }
        let separators: Set<Character> = ["-", "/", "."]
        let parts = s.split(whereSeparator: { separators.contains($0) }).map(String.init)
        if parts.count >= 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) {
            let numbers = parts.compactMap { Int($0) }
            guard numbers.count == parts.count else { return nil }
            var year = 0
            var month = 1
            var day = 1
            if parts[0].count == 4 {                          // yyyy-MM(-dd)
                year = numbers[0]
                month = numbers[1]
                day = numbers.count >= 3 ? numbers[2] : 1
            } else if parts.count >= 3, parts[2].count == 4 { // dd/MM/yyyy or MM/dd/yyyy
                year = numbers[2]
                let first = numbers[0], second = numbers[1]
                if first > 12 { day = first; month = second }
                else if second > 12 { month = first; day = second }
                else if dayFirst { day = first; month = second }
                else { month = first; day = second }
            } else {
                return nil
            }
            guard (1...12).contains(month), (1...31).contains(day), (1000...2500).contains(year) else { return nil }
            return utcCalendar.date(from: DateComponents(year: year, month: month, day: day))
        }
        if parts.count == 1, s.count == 4, let year = Int(s), (1000...2500).contains(year) {
            return utcCalendar.date(from: DateComponents(year: year, month: 1, day: 1))
        }
        return nil
    }

    /// The first two numbers of a slashed/dotted three-part date with a
    /// four-digit year — the raw material for day/month-order evidence.
    private static func slashDayMonthPair(_ raw: String) -> (first: Int, second: Int)? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if let timeStart = s.firstIndex(where: { $0 == "T" || $0 == " " }) {
            s = String(s[..<timeStart])
        }
        let separators: Set<Character> = ["/", "."]
        let parts = s.split(whereSeparator: { separators.contains($0) }).map(String.init)
        guard parts.count == 3, parts[2].count == 4,
              let first = Int(parts[0]), let second = Int(parts[1]) else { return nil }
        return (first, second)
    }
}
