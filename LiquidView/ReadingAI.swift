import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

// Ported from Knowledge Space's ReadingAI.swift (itself from Augmented
// Library) — keep synced; a fix here should be carried back.
// Availability asks the system model directly.

/// An editable AI verb for the reading view: the name the menu shows
/// and the prompt sent to the on-device model, the selected text
/// appended beneath it. The reader's set is kept as JSON in
/// `@AppStorage("readingAIPrompts")`.
public nonisolated struct AIPromptPreset: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var prompt: String

    public init(id: String = UUID().uuidString, name: String, prompt: String) {
        self.id = id
        self.name = name
        self.prompt = prompt
    }

    /// What a fresh install offers.
    public static let defaultPresets: [AIPromptPreset] = [
        AIPromptPreset(
            id: "simplify",
            name: "Simplify Text",
            prompt: "Rewrite the following text in simpler, clearer language. Keep every fact and the original meaning; prefer short sentences and common words. Return only the rewritten text, nothing else."),
    ]

    /// The persisted form.
    public static func encodeList(_ presets: [AIPromptPreset]) -> String {
        (try? JSONEncoder().encode(presets))
            .map { String(decoding: $0, as: UTF8.self) } ?? "[]"
    }

    /// The stored string back into presets. nil (never stored) falls
    /// back to the defaults; a stored empty list is an explicit "none".
    public static func decodeList(_ stored: String?) -> [AIPromptPreset] {
        guard let stored, let data = stored.data(using: .utf8) else { return defaultPresets }
        return (try? JSONDecoder().decode([AIPromptPreset].self, from: data)) ?? defaultPresets
    }
}

/// The reading view's AI: one preset run over the reader's selected
/// words, on this device's model only — nothing leaves the machine.
public nonisolated enum ReadingAI {

    /// Whether the on-device model can run here.
    public static var isAvailable: Bool {
        #if canImport(FoundationModels)
        SystemLanguageModel.default.availability == .available
        #else
        false
        #endif
    }

    /// A human-readable reason it cannot, for the UI.
    public static var unavailableReason: String {
        "The on-device model isn\u{2019}t available on this Mac."
    }

    public struct Unavailable: LocalizedError {
        public var errorDescription: String? { ReadingAI.unavailableReason }
    }

    /// The preset's prompt over the text, answered by the on-device
    /// model. Throws `Unavailable` where the model cannot run.
    public static func rewrite(_ text: String,
                               with preset: AIPromptPreset) async throws -> String {
        #if canImport(FoundationModels)
        guard isAvailable else { throw Unavailable() }
        let session = LanguageModelSession()
        let response = try await session.respond(to: preset.prompt + "\n\n" + text)
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        #else
        throw Unavailable()
        #endif
    }

    /// Where the meaning shifts inside one long paragraph, as the
    /// on-device model reads it. The model only chooses BETWEEN which
    /// sentences the breaks fall — the words themselves are split from
    /// the original, so nothing can change. Paragraphs stay substantial:
    /// a break that would leave fewer than three sentences on either
    /// side is dropped.
    @MainActor
    public static func paragraphBreaks(_ text: String) async throws -> [String] {
        #if canImport(FoundationModels)
        guard isAvailable else { throw Unavailable() }
        let sentences = OrigamiReading.flowLines(text, breakOnComma: false)
        guard sentences.count >= minimumRun * 2 else { return [text] }
        let numbered = sentences.enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")
        let session = LanguageModelSession()
        let prompt = """
        The numbered lines below are the consecutive sentences of one \
        long paragraph. To help reading, decide where new paragraphs \
        should start: only at substantial shifts of topic or meaning. \
        Prefer fewer, fuller paragraphs of roughly four to eight \
        sentences each. Answer with only the numbers of the sentences \
        that START a new paragraph, separated by commas — for example: \
        5, 11. Never include 1. If no break is warranted, answer: none.

        \(numbered)
        """
        let response = try await session.respond(to: prompt)
        let starts = breakStarts(from: response.content, count: sentences.count)
        guard !starts.isEmpty else { return [text] }
        var segments: [String] = []
        var begin = 0
        for start in starts + [sentences.count + 1] {
            segments.append(sentences[begin..<(start - 1)].joined(separator: " "))
            begin = start - 1
        }
        return segments
        #else
        throw Unavailable()
        #endif
    }

    /// The one sentence in a paragraph with the most to say, as the
    /// on-device model reads it — the key claim, not the filler around
    /// it. The model only CHOOSES a sentence: the words returned are
    /// split from the original, so nothing can change. nil where the
    /// paragraph is too short for the choice to mean anything, or the
    /// answer names no sentence.
    @MainActor
    public static func keySentence(_ text: String) async throws -> String? {
        #if canImport(FoundationModels)
        guard isAvailable else { throw Unavailable() }
        let sentences = OrigamiReading.flowLines(text, breakOnComma: false)
        guard sentences.count >= minimumRun else { return nil }
        let numbered = sentences.enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")
        let session = LanguageModelSession()
        let prompt = """
        The numbered lines below are the consecutive sentences of one \
        paragraph. Choose the single sentence with the most to say — \
        the paragraph's key claim or insight, never a transition or \
        filler sentence. Answer with only that sentence's number — \
        for example: 3.

        \(numbered)
        """
        let response = try await session.respond(to: prompt)
        guard let regex = try? NSRegularExpression(pattern: #"\d+"#) else { return nil }
        let answer = response.content as NSString
        guard let match = regex.firstMatch(
                  in: response.content,
                  range: NSRange(location: 0, length: answer.length)),
              let number = Int(answer.substring(with: match.range)),
              (1...sentences.count).contains(number)
        else { return nil }
        return sentences[number - 1]
        #else
        throw Unavailable()
        #endif
    }

    /// No paragraph reads shorter than this many sentences.
    public static let minimumRun = 3

    /// The sentence numbers in the model's answer, kept only where the
    /// paragraph on each side stays at least `minimumRun` sentences.
    static func breakStarts(from answer: String, count: Int) -> [Int] {
        guard let regex = try? NSRegularExpression(pattern: #"\d+"#) else { return [] }
        let ns = answer as NSString
        let numbers = regex.matches(in: answer,
                                    range: NSRange(location: 0, length: ns.length))
            .compactMap { Int(ns.substring(with: $0.range)) }
        var kept: [Int] = []
        var previous = 1
        for number in numbers.sorted() where number > previous {
            guard number > 1, number <= count else { continue }
            if number - previous >= minimumRun, count - number + 1 >= minimumRun {
                kept.append(number)
                previous = number
            }
        }
        return kept
    }
}

extension OrigamiReading {

    /// The Flow view of a span: the text broken into its reading lines
    /// at sentence and clause marks — `.` and `,` close a line, as in
    /// Liquid's and Reader's flow. A mark inside a number (3.14),
    /// followed by more of its word, or ending an abbreviation
    /// ("Dr.", "e.g.", an initial) does not break. The reader's two
    /// choices: whether commas break at all, and whether a period's
    /// break doubles — a blank line (an empty entry) after each
    /// sentence.
    public static func flowLines(_ text: String,
                                 breakOnComma: Bool = true,
                                 doubleBreakOnPeriod: Bool = false) -> [String] {
        var lines: [String] = []
        var current = ""
        var iterator = text.makeIterator()
        var pending = iterator.next()
        while let character = pending {
            let next = iterator.next()
            current.append(character)
            // A line ends only where the mark does: before a space or
            // the end, not mid-number or mid-word — and a sentence's
            // period, never an abbreviation's.
            if character == "." || (character == "," && breakOnComma) {
                if next == nil || next?.isWhitespace == true,
                   character == "," || !endsInAbbreviation(current) {
                    let line = current.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !line.isEmpty {
                        lines.append(line)
                        if character == ".", doubleBreakOnPeriod, next != nil {
                            lines.append("")
                        }
                    }
                    current = ""
                }
            }
            pending = next
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { lines.append(tail) }
        return lines
    }

    /// The Flow transform over whole text: the flow lines joined with
    /// line breaks — a double break's empty entry reads as a blank
    /// line — ready to render in place of the original words.
    public static func flowText(_ text: String,
                                breakOnComma: Bool = true,
                                doubleBreakOnPeriod: Bool = false) -> String {
        flowLines(text, breakOnComma: breakOnComma,
                  doubleBreakOnPeriod: doubleBreakOnPeriod)
            .joined(separator: "\n")
    }

    /// Whether the line so far ends in an abbreviation's period rather
    /// than a sentence's: an initial ("J."), a dotted form ("e.g.",
    /// "U.S."), or a common short title ("Dr.", "vs.", "et al.").
    private static func endsInAbbreviation(_ text: String) -> Bool {
        guard let word = text.split(whereSeparator: \.isWhitespace).last,
              word.hasSuffix(".") else { return false }
        let stem = String(word.dropLast())
            .trimmingCharacters(in: CharacterSet.alphanumerics.inverted
                .subtracting(CharacterSet(charactersIn: ".")))
        // An initial: a single letter before the period.
        if stem.count == 1, stem.first?.isLetter == true { return true }
        // A dotted abbreviation: periods inside the word itself.
        if stem.contains(".") { return true }
        return Self.abbreviations.contains(stem.lowercased())
    }

    /// Short forms whose period never ends a flow line.
    private static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "mt",
        "vs", "etc", "al", "cf", "ca", "fig", "figs", "vol", "vols",
        "ed", "eds", "pp", "ch", "sec", "dept", "univ", "inc", "ltd",
        "co", "corp", "approx", "est", "resp", "min", "max", "misc",
    ]
}
