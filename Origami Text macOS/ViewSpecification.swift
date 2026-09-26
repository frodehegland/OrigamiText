import Foundation

// Ported verbatim from Knowledge Space's ViewSpecification.swift (itself
// from Augmented Library) — keep synced; a fix here should be carried
// back. One Origami Text adaptation: no excerptOf (whole books only).

// A View Specification is a citation for a *view*: a link to a location
// and every variable needed to re-create how that location was being
// seen. The location may be a paragraph in an EPUB, a place on a globe,
// a moment in a solar system — the format does not care. Any app can
// produce one (Copy View Specification) and any app that recognizes the
// kind can restore it. The written form is a small readable JSON
// document; a compact `address` line (location plus query) travels
// inside it for contexts that want one line.

/// Any JSON value — the view variables of different kinds of views
/// need strings, numbers, lists, and nested shapes alike.
public nonisolated indirect enum ViewSpecJSONValue: Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([ViewSpecJSONValue])
    case object([String: ViewSpecJSONValue])
    case null
}

extension ViewSpecJSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([ViewSpecJSONValue].self) {
            self = .array(array)
        } else {
            self = .object(try container.decode([String: ViewSpecJSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let string): try container.encode(string)
        case .number(let number): try container.encode(number)
        case .bool(let bool): try container.encode(bool)
        case .array(let array): try container.encode(array)
        case .object(let object): try container.encode(object)
        case .null: try container.encodeNil()
        }
    }
}

/// One View Specification: what is being viewed (`location`), what kind
/// of view it is (`kind`), and the variables that shape it (`view`).
public nonisolated struct ViewSpecification: Equatable, Sendable {
    /// The format name and version every specification declares.
    public static let format = "viewspec/0.1"

    /// What kind of view this is — the vocabulary an app needs to
    /// restore it. "origami-reading" for a document being read;
    /// others as apps define them.
    public var kind: String
    /// The app that produced the specification, human-readable.
    public var generator: String
    /// The address of the thing being viewed — a document address with
    /// a paragraph fragment, a dataset id, a scene name.
    public var location: String
    /// Every variable needed to re-create the view, by name.
    public var view: [String: ViewSpecJSONValue]

    public init(kind: String, generator: String, location: String,
                view: [String: ViewSpecJSONValue]) {
        self.kind = kind
        self.generator = generator
        self.location = location
        self.view = view
    }

    /// The one-line form: the location with the view's scalar variables
    /// as queries, keys sorted so the same view always writes the same
    /// line. Nested values ride only in the JSON.
    public var address: String {
        let queries = view.keys.sorted().compactMap { key -> String? in
            queryValue(view[key]).map { "\(Self.escape(key))=\($0)" }
        }
        return queries.isEmpty ? location : location + "?" + queries.joined(separator: "&")
    }

    /// The clipboard form: the readable JSON document, `address` line
    /// included, keys sorted.
    public func clipboardText() -> String {
        var object: [String: ViewSpecJSONValue] = [
            "format": .string(Self.format),
            "kind": .string(kind),
            "generator": .string(generator),
            "location": .string(location),
            "view": .object(view),
            "address": .string(address),
        ]
        if view.isEmpty { object["view"] = nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = (try? encoder.encode(object.mapValues { $0 })) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// A specification back from pasted text: the first JSON object in
    /// it, declaring the viewspec format. Nil for anything else.
    public static func parse(_ text: String) -> ViewSpecification? {
        guard let open = text.firstIndex(of: "{"),
              let close = text.lastIndex(of: "}") else { return nil }
        let data = Data(text[open...close].utf8)
        guard let raw = try? JSONDecoder().decode([String: ViewSpecJSONValue].self, from: data),
              case .string(let format)? = raw["format"],
              format.hasPrefix("viewspec/"),
              case .string(let kind)? = raw["kind"],
              case .string(let location)? = raw["location"] else { return nil }
        let generator: String = if case .string(let name)? = raw["generator"] { name } else { "" }
        let view: [String: ViewSpecJSONValue] = if case .object(let values)? = raw["view"] { values } else { [:] }
        return ViewSpecification(kind: kind, generator: generator,
                                 location: location, view: view)
    }

    /// A scalar (or scalar list) as it reads in the address query;
    /// nested shapes return nil and stay JSON-only.
    private func queryValue(_ value: ViewSpecJSONValue?) -> String? {
        switch value {
        case .string(let string):
            return Self.escape(string)
        case .number(let number):
            // Whole numbers read whole: zoom=3, not zoom=3.0.
            return number == number.rounded() && abs(number) < 1e15
                ? String(Int(number))
                : String(number)
        case .bool(let bool):
            return bool ? "true" : "false"
        case .array(let values):
            let scalars = values.compactMap { queryValue($0) }
            return scalars.count == values.count && !scalars.isEmpty
                ? scalars.joined(separator: ",")
                : nil
        case .object, .null, nil:
            return nil
        }
    }

    private static func escape(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"))
            ?? text
    }
}

extension OrigamiReading {

    /// The View Specification of a document being read: the paragraph's
    /// address as the location, the reading view's variables — style,
    /// folded sections, opened stretchtext, the focused section — as
    /// the view.
    public static func viewSpecification(for paragraph: LiquidDoc.Paragraph,
                                         in doc: LiquidDoc,
                                         view state: OrigamiViewState,
                                         generator: String) -> ViewSpecification {
        var view: [String: ViewSpecJSONValue] = ["style": .string(state.style.rawValue)]
        if !state.closedSections.isEmpty {
            view["closed"] = .array(state.closedSections.map(ViewSpecJSONValue.string))
        }
        if !state.openStretch.isEmpty {
            view["open"] = .array(state.openStretch.map(ViewSpecJSONValue.string))
        }
        if let focus = state.focusSectionID {
            view["focus"] = .string(focus)
        }
        return ViewSpecification(kind: "origami-reading",
                                 generator: generator,
                                 location: doc.id + "#" + paragraph.id,
                                 view: view)
    }
}
