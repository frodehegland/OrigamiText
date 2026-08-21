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
    /// the exact words with disambiguating context, a position hint.
    public enum Selector: Hashable, Sendable {
        case fragment(value: String, conformsTo: String?)
        case quote(exact: String, prefix: String?, suffix: String?)
        case position(start: Int, end: Int)
    }
}

// MARK: - JSON-LD coding

nonisolated extension WebAnnotation: Codable {

    private enum CodingKeys: String, CodingKey {
        case context = "@context"
        case id, type, motivation, created, modified, creator, body, target
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
    }
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
        default:
            throw SelectorError.unknownType(type)
        }
    }
}
