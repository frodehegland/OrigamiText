import Foundation
import SwiftUI
import NaturalLanguage

// Ported verbatim from Knowledge Space's TextColoring.swift (itself from
// Augmented Library) — keep synced; a fix here should be carried back.

// Text colour coding — a viewspec in Doug Engelbart's sense: the same
// words, seen through their grammar or their meaning. Every word is
// tagged on this device (NaturalLanguage; nothing leaves the machine)
// and painted by its category, with the colours the reader's own to
// edit. The idea has a long lineage the defaults honour: Montessori's
// colour-coded grammar symbols (verb red, adjective dark blue, article
// light blue, pronoun purple, adverb orange), the Fitzgerald Key that
// has organized language boards by colour since 1926, colour-marked
// sentence work in language teaching, and colour cueing as a reading
// support for dyslexia.

/// What the colouring reads: nothing, the grammar (parts of speech),
/// or the meaning (who, where, what organization). Toggled from the
/// Aa menu; stored under "textColoringMode", shared across platforms.
public nonisolated enum TextColoringMode: String, CaseIterable, Identifiable, Sendable {
    case off
    case grammar
    case meaning

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .off: "Off"
        case .grammar: "Grammar"
        case .meaning: "Meaning"
        }
    }
}

/// One colourable category of words.
public nonisolated enum TextColorCategory: String, CaseIterable, Codable, Sendable {
    // Grammar — the parts of speech.
    case noun, verb, adjective, adverb, pronoun
    case determiner, preposition, conjunction, number, interjection
    // Meaning — the named entities, and what the text measures.
    case person, place, organization, time, quantity

    public var displayName: String {
        switch self {
        case .noun: "Nouns"
        case .verb: "Verbs"
        case .adjective: "Adjectives"
        case .adverb: "Adverbs"
        case .pronoun: "Pronouns"
        case .determiner: "Determiners"
        case .preposition: "Prepositions"
        case .conjunction: "Conjunctions"
        case .number: "Numbers"
        case .interjection: "Interjections"
        case .person: "People"
        case .place: "Places"
        case .organization: "Organizations"
        case .time: "Time"
        case .quantity: "Quantities"
        }
    }

    /// A word of its own kind, for the settings preview.
    public var exampleWord: String {
        switch self {
        case .noun: "library"
        case .verb: "reads"
        case .adjective: "luminous"
        case .adverb: "quickly"
        case .pronoun: "she"
        case .determiner: "the"
        case .preposition: "between"
        case .conjunction: "and"
        case .number: "1968"
        case .interjection: "aha"
        case .person: "Engelbart"
        case .place: "Menlo Park"
        case .organization: "SRI"
        case .time: "decade"
        case .quantity: "several"
        }
    }

    /// Which mode the category belongs to.
    public var mode: TextColoringMode {
        switch self {
        case .person, .place, .organization, .time, .quantity: .meaning
        default: .grammar
        }
    }

    /// The tagger's word class or name kind, as a category.
    init?(tag: NLTag) {
        switch tag {
        case .noun: self = .noun
        case .verb: self = .verb
        case .adjective: self = .adjective
        case .adverb: self = .adverb
        case .pronoun: self = .pronoun
        case .determiner: self = .determiner
        case .preposition: self = .preposition
        case .conjunction: self = .conjunction
        case .number: self = .number
        case .interjection: self = .interjection
        case .personalName: self = .person
        case .placeName: self = .place
        case .organizationName: self = .organization
        default: return nil
        }
    }
}

/// One category's rule: on or off, and its colour — the reader's to
/// edit. Kept as JSON under `@AppStorage("textColorRules")`.
public nonisolated struct TextColorRule: Codable, Identifiable, Hashable, Sendable {
    public var category: TextColorCategory
    public var enabled: Bool
    /// "#RRGGBB".
    public var hex: String

    public var id: String { category.rawValue }

    public init(category: TextColorCategory, enabled: Bool, hex: String) {
        self.category = category
        self.enabled = enabled
        self.hex = hex
    }

    public var color: Color { Color(hexCode: hex) ?? .primary }

    /// What a fresh install shows, built on two researched principles.
    /// Montessori's family logic: related words share related colours —
    /// the noun family in blues (noun strong, adjective softer,
    /// determiner palest), the verb family in warm reds (verb red,
    /// adverb "a softened red" orange), the pronoun purple — the
    /// bridge of blue and red, standing for a noun while serving the
    /// verb. And colour-perception findings: hue carries category, so
    /// the meaning-carrying content words get the salient, nameable
    /// hues while the function words (scaffolding) recede in muted
    /// tones — keeping the truly distinct hues within the six-to-eight
    /// the eye can hold apart.
    public static let defaultRules: [TextColorRule] = [
        // Content words: salient, nameable hues.
        TextColorRule(category: .noun, enabled: true, hex: "#1F5FA8"),
        TextColorRule(category: .verb, enabled: true, hex: "#C4342B"),
        TextColorRule(category: .adjective, enabled: true, hex: "#4E86C6"),
        TextColorRule(category: .adverb, enabled: true, hex: "#E08A3C"),
        TextColorRule(category: .pronoun, enabled: true, hex: "#7B4FA6"),
        // Function words: the same families, muted — present, not loud.
        TextColorRule(category: .determiner, enabled: true, hex: "#8FB3D9"),
        TextColorRule(category: .preposition, enabled: true, hex: "#6E9B76"),
        TextColorRule(category: .conjunction, enabled: true, hex: "#B58A9B"),
        TextColorRule(category: .number, enabled: true, hex: "#A98600"),
        TextColorRule(category: .interjection, enabled: true, hex: "#C9A227"),
        // Meaning: three distinct hues of their own, with time in the
        // numbers' gold and quantities in the adverbs' orange.
        TextColorRule(category: .person, enabled: true, hex: "#B03A5B"),
        TextColorRule(category: .place, enabled: true, hex: "#2E7D5B"),
        TextColorRule(category: .organization, enabled: true, hex: "#4A5AB8"),
        TextColorRule(category: .time, enabled: true, hex: "#A98600"),
        TextColorRule(category: .quantity, enabled: true, hex: "#E08A3C"),
    ]

    /// The persisted form.
    public static func encodeList(_ rules: [TextColorRule]) -> String {
        (try? JSONEncoder().encode(rules))
            .map { String(decoding: $0, as: UTF8.self) } ?? "[]"
    }

    /// The stored string back into rules; categories a stored list
    /// does not know (an older version's) come back at their defaults.
    public static func decodeList(_ stored: String?) -> [TextColorRule] {
        guard let stored, let data = stored.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([TextColorRule].self, from: data)
        else { return defaultRules }
        var byCategory = Dictionary(uniqueKeysWithValues: decoded.map { ($0.category, $0) })
        return defaultRules.map { byCategory.removeValue(forKey: $0.category) ?? $0 }
    }
}

extension Color {
    /// "#RRGGBB" in, a colour out; nil for anything else.
    public nonisolated init?(hexCode: String) {
        let cleaned = hexCode.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "#", with: "")
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}

extension OrigamiReading {

    /// Words that read as spans of time, beyond what the date detector
    /// finds — periods, seasons, relative days.
    private static let timeLexicon: Set<String> = [
        "year", "years", "month", "months", "week", "weeks", "day", "days",
        "hour", "hours", "minute", "minutes", "second", "seconds",
        "decade", "decades", "century", "centuries", "millennium", "millennia",
        "era", "eras", "epoch", "epochs", "age", "ages", "season", "seasons",
        "today", "tonight", "yesterday", "tomorrow", "nowadays",
        "morning", "afternoon", "evening", "night", "midnight", "noon",
        "spring", "summer", "autumn", "fall", "winter",
        "annual", "annually", "daily", "weekly", "monthly", "yearly",
        "moment", "moments", "instant", "future", "past", "present",
    ]

    /// Words that read as amounts.
    private static let quantityLexicon: Set<String> = [
        "few", "several", "many", "most", "all", "some", "none", "any",
        "half", "halves", "quarter", "quarters", "third", "thirds",
        "dozen", "dozens", "hundreds", "thousands", "millions", "billions",
        "percent", "percentage", "majority", "minority", "fraction",
        "both", "every", "each", "twice", "thrice", "single", "double", "triple",
        "more", "less", "fewer", "much", "little", "plenty", "numerous",
        "amount", "amounts", "count", "total", "totals", "sum", "sums",
    ]

    /// The paragraph coloured by its words: each tagged on-device and
    /// painted with its category's colour. Grammar paints by part of
    /// speech; Meaning paints named entities, then spans of time (the
    /// date detector plus the period lexicon), then quantities (number
    /// words and amount words). Words that already carry a colour or a
    /// link (marks, glossary, citations, the stretch controls) keep
    /// their own — and earlier passes win over later ones.
    public static func colorCoded(_ attributed: AttributedString,
                                  mode: TextColoringMode,
                                  rules: [TextColorRule]) -> AttributedString {
        guard mode != .off else { return attributed }
        let plain = String(attributed.characters)
        guard !plain.isEmpty else { return attributed }
        let colors = Dictionary(uniqueKeysWithValues:
            rules.filter { $0.enabled && $0.category.mode == mode }
                .map { ($0.category, $0.color) })
        guard !colors.isEmpty else { return attributed }

        var out = attributed
        func paint(_ range: Range<String.Index>, _ color: Color) {
            guard let attributedRange = Range(range, in: out) else { return }
            let paintable = out[attributedRange].runs.compactMap { run in
                run.foregroundColor == nil && run.link == nil ? run.range : nil
            }
            for runRange in paintable {
                out[runRange].foregroundColor = color
            }
        }

        switch mode {
        case .off:
            break
        case .grammar:
            let tagger = NLTagger(tagSchemes: [.lexicalClass])
            tagger.string = plain
            tagger.enumerateTags(in: plain.startIndex..<plain.endIndex,
                                 unit: .word, scheme: .lexicalClass,
                                 options: [.omitWhitespace, .omitPunctuation, .omitOther]) { tag, range in
                if let tag, let category = TextColorCategory(tag: tag),
                   let color = colors[category] {
                    paint(range, color)
                }
                return true
            }
        case .meaning:
            // The named entities first — a person called May is a
            // person before she is a month.
            let names = NLTagger(tagSchemes: [.nameType])
            names.string = plain
            names.enumerateTags(in: plain.startIndex..<plain.endIndex,
                                unit: .word, scheme: .nameType,
                                options: [.omitWhitespace, .omitPunctuation,
                                          .omitOther, .joinNames]) { tag, range in
                if let tag, let category = TextColorCategory(tag: tag),
                   let color = colors[category] {
                    paint(range, color)
                }
                return true
            }
            // Time: whole date expressions, then the period words.
            if let timeColor = colors[.time],
               let detector = try? NSDataDetector(
                   types: NSTextCheckingResult.CheckingType.date.rawValue) {
                let whole = NSRange(plain.startIndex..<plain.endIndex, in: plain)
                for match in detector.matches(in: plain, range: whole) {
                    if let range = Range(match.range, in: plain) {
                        paint(range, timeColor)
                    }
                }
            }
            // Period and amount words, and standalone numbers as
            // quantities — one walk over the words.
            let words = NLTagger(tagSchemes: [.lexicalClass])
            words.string = plain
            words.enumerateTags(in: plain.startIndex..<plain.endIndex,
                                unit: .word, scheme: .lexicalClass,
                                options: [.omitWhitespace, .omitPunctuation,
                                          .omitOther]) { tag, range in
                let word = plain[range].lowercased()
                if let timeColor = colors[.time], timeLexicon.contains(word) {
                    paint(range, timeColor)
                } else if let quantityColor = colors[.quantity],
                          quantityLexicon.contains(word) || tag == .number {
                    paint(range, quantityColor)
                }
                return true
            }
        }
        return out
    }
}
