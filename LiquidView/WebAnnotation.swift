import Foundation

// Ported verbatim from Knowledge Space's WebAnnotation.swift (itself from
// Augmented Library) — keep synced; a fix here should be carried back.

/// One W3C Web Annotation (https://www.w3.org/TR/annotation-model/) — the
/// same model Hypothesis uses — targeting a book in this reader's library.
///
/// The Codable implementation is hand-written so the JSON is real JSON-LD:
/// `@context` on every annotation, `"type": "Annotation"`, and selectors
/// discriminated by their `type` (`FragmentSelector`, `TextQuoteSelector`,
/// `TextPositionSelector`). The FragmentSelector's value is the target
/// paragraph's stable id — the same `data-id` the Origami EPUB carries —
/// so an anchor survives re-export and revision; the TextQuoteSelector is
/// the Hypothesis-style fallback that re-anchors when ids change.
public nonisolated struct WebAnnotation: Identifiable, Hashable, Sendable {

    public static let context = "http://www.w3.org/ns/anno.jsonld"
    /// What FragmentSelector values conform to here: the Origami
    /// document's stable paragraph ids.
    public static let fragmentConformsTo = "https://origamitext.app/ns/data-id"

    /// The recommended motivations (the vocabulary is the W3C's, open).
    public enum Motivation {
        public static let highlighting = "highlighting"
        public static let commenting = "commenting"
        public static let tagging = "tagging"
        /// The whole-document annotation — no selectors; the reader's
        /// one note describing the document itself.
        public static let describing = "describing"
    }

    public var id: String
    public var motivation: String
    public var created: Date
    public var modified: Date?
    public var creator: Person?
    public var body: TextualBody?
    public var target: Target

    public init(id: String = "urn:uuid:" + UUID().uuidString.lowercased(),
                motivation: String,
                created: Date = .now,
                modified: Date? = nil,
                creator: Person? = nil,
                body: TextualBody? = nil,
                target: Target) {
        self.id = id
        self.motivation = motivation
        self.created = created
        self.modified = modified
        self.creator = creator
        self.body = body
        self.target = target
    }

    public struct Person: Hashable, Sendable {
        public var name: String

        public init(name: String) { self.name = name }
    }

    public struct TextualBody: Hashable, Sendable {
        public var value: String
        /// Why the body is attached, when it differs from the annotation's
        /// motivation — e.g. "describing".
        public var purpose: String?

        public init(value: String, purpose: String? = nil) {
            self.value = value
            self.purpose = purpose
        }
    }

    public struct Target: Hashable, Sendable {
        /// The annotated document's IRI — `origamitext://open/<address>`
        /// for library documents.
        public var source: String
        public var selectors: [Selector]

        public init(source: String, selectors: [Selector]) {
            self.source = source
            self.selectors = selectors
        }
    }

    /// The selector ladder, most robust first: the stable paragraph id,
    /// the exact words with disambiguating context, a position hint,
    /// and the coarse fraction through the document (the Readium
    /// ProgressionSelector) — for ordering, and the landing of last
    /// resort.
    public enum Selector: Hashable, Sendable {
        case fragment(value: String, conformsTo: String?)
        case quote(exact: String, prefix: String?, suffix: String?)
        case position(start: Int, end: Int)
        case progression(Double)
    }

    /// Where a page note stands on the rendering — an extension the
    /// sidecar carries (`origami:placement`), so slips travel with
    /// their annotations. Anchored to the nearest stable element with
    /// an offset from its top-left; with no anchor the offsets read as
    /// absolute page coordinates.
    public struct Placement: Hashable, Sendable {
        public var near: String?
        public var dx: Double
        public var dy: Double

        public init(near: String?, dx: Double, dy: Double) {
            self.near = near
            self.dx = dx
            self.dy = dy
        }
    }

    /// The page note's standing place, when it has one. Nil for
    /// annotations anchored to words.
    public var placement: Placement? = nil
}

/// The reader's annotation vocabulary — the judgments a reader stamps
/// on words, after Reader's Annotate menu. Each travels as a standard
/// W3C tagging body (purpose "tagging", the tag its value), so any Web
/// Annotation reader shows it; Highlight keeps the plain highlighting
/// motivation it always had.
public enum ReaderAnnotationKind: String, CaseIterable, Identifiable, Sendable {
    case important = "Important"
    case quotable = "Quotable"
    case great = "Great"
    case disagree = "Disagree"
    case languageIssue = "Language Issue"
    case problematic = "Problematic"
    case whatIsThis = "What is this?"
    case highlight = "Highlight"
    case strikethrough = "Strikethrough"

    public var id: String { rawValue }

    /// The bare key that fires the kind while the Annotate menu is
    /// open — Reader's own equivalents.
    public var keyEquivalent: String {
        switch self {
        case .important: "i"
        case .quotable: "q"
        case .great: "g"
        case .disagree: "d"
        case .languageIssue: "l"
        case .problematic: "p"
        case .whatIsThis: "/"
        case .highlight: "h"
        case .strikethrough: "x"
        }
    }

    public var systemImage: String {
        switch self {
        case .important: "exclamationmark.circle"
        case .quotable: "quote.opening"
        case .great: "star"
        case .disagree: "hand.thumbsdown"
        case .languageIssue: "character.cursor.ibeam"
        case .problematic: "exclamationmark.triangle"
        case .whatIsThis: "questionmark.circle"
        case .highlight: "highlighter"
        case .strikethrough: "strikethrough"
        }
    }

    /// The kind an annotation carries, when it carries one: its tagging
    /// body's value, or Highlight for a plain highlighting motivation.
    public static func kind(of annotation: WebAnnotation) -> ReaderAnnotationKind? {
        if annotation.body?.purpose == "tagging",
           let value = annotation.body?.value,
           let kind = ReaderAnnotationKind(rawValue: value) {
            return kind
        }
        if annotation.motivation == WebAnnotation.Motivation.highlighting {
            return .highlight
        }
        return nil
    }
}

// MARK: - JSON-LD coding

nonisolated extension WebAnnotation: Codable {

    private enum CodingKeys: String, CodingKey {
        case context = "@context"
        case id, type, motivation, created, modified, creator, body, target
        case placement = "origami:placement"
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.context, forKey: .context)
        try container.encode(id, forKey: .id)
        try container.encode("Annotation", forKey: .type)
        try container.encode(motivation, forKey: .motivation)
        try container.encode(Self.iso8601(created), forKey: .created)
        if let modified {
            try container.encode(Self.iso8601(modified), forKey: .modified)
        }
        try container.encodeIfPresent(creator, forKey: .creator)
        try container.encodeIfPresent(body, forKey: .body)
        try container.encode(target, forKey: .target)
        try container.encodeIfPresent(placement, forKey: .placement)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
            ?? "urn:uuid:" + UUID().uuidString.lowercased()
        motivation = try container.decodeIfPresent(String.self, forKey: .motivation)
            ?? Motivation.highlighting
        let createdString = try container.decodeIfPresent(String.self, forKey: .created)
        created = createdString.flatMap(LiquidDoc.parseISO8601) ?? .now
        let modifiedString = try container.decodeIfPresent(String.self, forKey: .modified)
        modified = modifiedString.flatMap(LiquidDoc.parseISO8601)
        creator = try? container.decodeIfPresent(Person.self, forKey: .creator)
        body = try? container.decodeIfPresent(TextualBody.self, forKey: .body)
        target = try container.decode(Target.self, forKey: .target)
        placement = try? container.decodeIfPresent(Placement.self, forKey: .placement)
    }
}

nonisolated extension WebAnnotation.Placement: Codable {
    private enum CodingKeys: String, CodingKey { case near, dx, dy }
}

nonisolated extension WebAnnotation.Person: Codable {
    private enum CodingKeys: String, CodingKey { case type, name }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("Person", forKey: .type)
        try container.encode(name, forKey: .name)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
    }
}

nonisolated extension WebAnnotation.TextualBody: Codable {
    private enum CodingKeys: String, CodingKey { case type, value, format, purpose }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("TextualBody", forKey: .type)
        try container.encode(value, forKey: .value)
        try container.encode("text/plain", forKey: .format)
        try container.encodeIfPresent(purpose, forKey: .purpose)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        value = try container.decodeIfPresent(String.self, forKey: .value) ?? ""
        purpose = try container.decodeIfPresent(String.self, forKey: .purpose)
    }
}

nonisolated extension WebAnnotation.Target: Codable {
    private enum CodingKeys: String, CodingKey { case source, selector }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(source, forKey: .source)
        if !selectors.isEmpty {
            try container.encode(selectors, forKey: .selector)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = try container.decodeIfPresent(String.self, forKey: .source) ?? ""
        // The spec allows a single selector or an array; a selector of an
        // unknown type is skipped, never fatal.
        if let list = try? container.decode([Lossy].self, forKey: .selector) {
            selectors = list.compactMap(\.selector)
        } else if let one = try? container.decode(Lossy.self, forKey: .selector) {
            selectors = [one.selector].compactMap { $0 }
        } else {
            selectors = []
        }
    }

    private struct Lossy: Decodable {
        let selector: WebAnnotation.Selector?
        init(from decoder: Decoder) throws {
            selector = try? WebAnnotation.Selector(from: decoder)
        }
    }
}

nonisolated extension WebAnnotation.Selector: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, value, conformsTo, exact, prefix, suffix, start, end
    }

    private enum SelectorError: Error { case unknownType(String) }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .fragment(let value, let conformsTo):
            try container.encode("FragmentSelector", forKey: .type)
            try container.encode(value, forKey: .value)
            try container.encodeIfPresent(conformsTo, forKey: .conformsTo)
        case .quote(let exact, let prefix, let suffix):
            try container.encode("TextQuoteSelector", forKey: .type)
            try container.encode(exact, forKey: .exact)
            try container.encodeIfPresent(prefix, forKey: .prefix)
            try container.encodeIfPresent(suffix, forKey: .suffix)
        case .position(let start, let end):
            try container.encode("TextPositionSelector", forKey: .type)
            try container.encode(start, forKey: .start)
            try container.encode(end, forKey: .end)
        case .progression(let value):
            // Readium's ProgressionSelector: the fraction through the
            // resource — ordering, and the landing of last resort.
            try container.encode("ProgressionSelector", forKey: .type)
            try container.encode(value, forKey: .value)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decodeIfPresent(String.self, forKey: .type) ?? ""
        switch type {
        case "FragmentSelector":
            self = .fragment(value: try container.decodeIfPresent(String.self, forKey: .value) ?? "",
                             conformsTo: try container.decodeIfPresent(String.self, forKey: .conformsTo))
        case "TextQuoteSelector":
            self = .quote(exact: try container.decodeIfPresent(String.self, forKey: .exact) ?? "",
                          prefix: try container.decodeIfPresent(String.self, forKey: .prefix),
                          suffix: try container.decodeIfPresent(String.self, forKey: .suffix))
        case "TextPositionSelector":
            self = .position(start: try container.decodeIfPresent(Int.self, forKey: .start) ?? 0,
                             end: try container.decodeIfPresent(Int.self, forKey: .end) ?? 0)
        case "ProgressionSelector":
            self = .progression(try container.decodeIfPresent(Double.self, forKey: .value) ?? 0)
        default:
            throw SelectorError.unknownType(type)
        }
    }
}
