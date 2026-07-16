import Foundation

/// Imports meeting transcripts as drafts: plain text where each statement
/// is "Speaker Name: what they said". Zoom-style timestamps are tolerated —
/// "Name (00:12:34): …" and "[00:12:34] Name: …" — and dropped. Each
/// statement becomes one paragraph whose text keeps the "Name: " prefix
/// (plain-text readers lose nothing) and whose `speaker` field carries the
/// attribution structurally, so every statement is addressable and every
/// speaker ascribable. Lines that name no speaker continue the statement
/// above them.
nonisolated enum TranscriptImporter {

    struct Result {
        let title: String
        /// The meeting's day, when the transcript opens with a date line
        /// ("6 July 26") or the file is named by date ("6 July 2026.rtf").
        let date: LiquidDate?
        let speakers: [String]           // in order of first appearance
        let body: [LiquidDoc.Paragraph]
    }

    /// The date forms meeting transcripts actually open with:
    /// "6 July 26", "6 July 2026", "July 6, 2026", "2026-07-06".
    static func parseDate(_ string: String) -> LiquidDate? {
        let trimmed = string.trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        for format in ["d MMMM yyyy", "d MMMM yy", "MMMM d, yyyy", "MMMM d yyyy",
                       "d MMM yyyy", "d MMM yy", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            guard let date = formatter.date(from: trimmed) else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            guard var year = parts.year, let month = parts.month, let day = parts.day else { continue }
            // "6 July 26" means 2026 here: these are meeting dates, and a
            // bare two-digit year takes the standard century pivot.
            if year < 100 { year += year <= 49 ? 2000 : 1900 }
            return LiquidDate(isoString: String(format: "%04d-%02d-%02d", year, month, day))
        }
        return nil
    }

    /// A line "Name: text" names a speaker when the part before the colon
    /// is one to four words, each starting with a letter, containing no
    /// sentence punctuation — "Mark Anderson:" yes, "Note:" is also
    /// accepted alone but rejected by the sniffer's two-speaker minimum.
    private static let speakerLinePattern =
        /^(?:\[[0-9:.\-–— ]+\]\s*)?(?<name>\p{L}[\p{L}'’.\-]*(?:\s+\p{L}[\p{L}'’.\-]*){0,3})\s*(?:\([0-9:.\-–— ]+\))?\s*:\s*(?<statement>.*)$/

    private static func speakerMatch(in line: String) -> (name: String, statement: String)? {
        guard let match = line.wholeMatch(of: speakerLinePattern) else { return nil }
        let name = String(match.name).trimmingCharacters(in: .whitespaces)
        // A colon deep into a sentence is prose, not attribution.
        guard name.count <= 40 else { return nil }
        return (name, String(match.statement).trimmingCharacters(in: .whitespaces))
    }

    /// Whether text reads as a transcript: most non-empty lines are
    /// attributed statements, and at least two speakers *recur* — real
    /// conversation alternates, while prose colon-prefixes ("Note:",
    /// "Warning:") appear once each.
    static func looksLikeTranscript(_ text: String) -> Bool {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count >= 4 else { return false }
        let matches = lines.compactMap { speakerMatch(in: $0) }
        var counts: [String: Int] = [:]
        for match in matches { counts[match.name, default: 0] += 1 }
        let recurringSpeakers = counts.values.count { $0 >= 2 }
        return recurringSpeakers >= 2 && matches.count * 10 >= lines.count * 6
    }

    static func importFile(at url: URL) throws -> Result {
        let text = try String(contentsOf: url, encoding: .utf8)
        return importText(text, fallbackTitle: url.deletingPathExtension().lastPathComponent)
    }

    static func importText(_ text: String, fallbackTitle: String) -> Result {
        var speakers: [String] = []
        var statements: [(speaker: String?, text: String)] = []
        var date: LiquidDate?

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if let (name, statement) = speakerMatch(in: line) {
                if !speakers.contains(name) { speakers.append(name) }
                statements.append((name, statement))
            } else if !statements.isEmpty, statements[statements.count - 1].speaker != nil {
                // Continuation of the statement above.
                statements[statements.count - 1].text += " " + line
            } else {
                // Preamble before the first speaker: a plain paragraph.
                statements.append((nil, line))
            }
        }

        // A transcript that opens with just a date ("6 July 26") is telling
        // us the meeting's day: it becomes the document's human date rather
        // than a body paragraph. The filename is the fallback teller.
        if let first = statements.first, first.speaker == nil,
           let opening = parseDate(first.text) {
            date = opening
            statements.removeFirst()
        } else {
            date = parseDate(fallbackTitle)
        }

        let body = statements.enumerated().map { index, statement in
            LiquidDoc.Paragraph(id: "p\(index + 1)",
                                heading: nil,
                                text: statement.speaker.map { "\($0): \(statement.text)" } ?? statement.text,
                                speaker: statement.speaker)
        }
        return Result(title: fallbackTitle, date: date, speakers: speakers, body: body)
    }
}
