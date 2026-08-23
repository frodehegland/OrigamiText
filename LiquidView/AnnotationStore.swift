import Foundation

// Ported from Knowledge Space's AnnotationStore.swift (itself from
// Augmented Library) — keep synced; a fix here should be carried back.
// In Origami Text the sidecars live in an Annotations folder beside the
// unpacked books, keyed by the book's address, so they survive a book
// being re-unpacked. Anchoring (the id → quote → document ladder) is
// resolved in the reader's page script, where the rendered words live —
// see the annotation script in EPUBReaderView.

/// A reader's web annotations live beside the unpacked books: one JSON-LD
/// sidecar per annotated book, `<address>.annotations.jsonld`, holding a
/// W3C AnnotationCollection. They are never written into the book or its
/// EPUB — the book is the author's; the annotations are the reader's.
public nonisolated enum AnnotationStore {

    public static func fileName(for address: String) -> String {
        // Addresses are filename-safe by construction (no whitespace, #, /).
        address + ".annotations.jsonld"
    }

    public static func fileURL(for address: String, in folder: URL) -> URL {
        folder.appendingPathComponent(fileName(for: address))
    }

    /// Every annotation in the book's sidecar, oldest first. A missing
    /// or unreadable sidecar is an empty list, never an error.
    public static func load(for address: String, in folder: URL) -> [WebAnnotation] {
        let url = fileURL(for: address, in: folder)
        guard let data = try? Data(contentsOf: url) else { return [] }
        guard let collection = try? JSONDecoder().decode(CollectionFile.self, from: data) else { return [] }
        return collection.items.sorted { $0.created < $1.created }
    }

    /// Every sidecar in the folder, keyed by the annotated book's
    /// address — the cross-document view of a reader's annotations.
    /// One folder scan; unreadable sidecars simply contribute nothing.
    public static func loadAll(in folder: URL) -> [String: [WebAnnotation]] {
        let suffix = ".annotations.jsonld"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path)
        else { return [:] }
        var all: [String: [WebAnnotation]] = [:]
        for name in names where name.hasSuffix(suffix) {
            let address = String(name.dropLast(suffix.count))
            let annotations = load(for: address, in: folder)
            if !annotations.isEmpty { all[address] = annotations }
        }
        return all
    }

    /// Writes the sidecar, or removes it when the last annotation is gone.
    public static func save(_ annotations: [WebAnnotation], for address: String, in folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = fileURL(for: address, in: folder)
        guard !annotations.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(CollectionFile(items: annotations)) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// The sidecar's shape: a W3C AnnotationCollection with its items
    /// inline (no paging — a reader's notes on one book stay small).
    private nonisolated struct CollectionFile: Codable {
        var items: [WebAnnotation]

        enum CodingKeys: String, CodingKey {
            case context = "@context"
            case type, total, items
        }

        init(items: [WebAnnotation]) { self.items = items }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(WebAnnotation.context, forKey: .context)
            try container.encode("AnnotationCollection", forKey: .type)
            try container.encode(items.count, forKey: .total)
            try container.encode(items, forKey: .items)
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            items = try container.decodeIfPresent([Lossy].self, forKey: .items)?
                .compactMap(\.annotation) ?? []
        }

        /// One unreadable annotation never sinks the sidecar.
        private nonisolated struct Lossy: Decodable {
            let annotation: WebAnnotation?
            init(from decoder: Decoder) throws {
                annotation = try? WebAnnotation(from: decoder)
            }
        }
    }
}

/// The anchoring ladder, mirroring the Origami format's own scope rules:
/// resolve the stable paragraph id first (it survives re-export and
/// revision), find the exact words within that paragraph, fall back to a
/// document-wide search disambiguated by the quote's prefix/suffix (the
/// Hypothesis re-anchoring move), and degrade to paragraph scope rather
/// than break. All text matching is case- and diacritic-insensitive, the
/// format's span rule. (Ported from Knowledge Space; the WebView reader
/// runs the same ladder in its page script instead.)
public nonisolated enum AnnotationAnchor {

    public struct Resolution: Hashable, Sendable {
        public enum Method: Hashable, Sendable {
            /// The stable id matched.
            case fragment
            /// The stable id matched and the exact words were found in it.
            case quoteInParagraph
            /// The id was gone; the words were found elsewhere.
            case quoteInDocument
            /// The id matched but the words are gone — paragraph scope stands.
            case paragraph
        }

        public let paragraphID: String
        /// The words to highlight, when they were found.
        public let exact: String?
        public let method: Method
    }

    /// Where an annotation lands in this document, or nil when nothing in
    /// it still matches (the document changed beyond re-anchoring).
    static func resolve(_ annotation: WebAnnotation, in doc: LiquidDoc) -> Resolution? {
        var fragmentID: String?
        var quote: (exact: String, prefix: String?, suffix: String?)?
        for selector in annotation.target.selectors {
            switch selector {
            case .fragment(let value, _): fragmentID = fragmentID ?? value
            case .quote(let exact, let prefix, let suffix):
                if quote == nil, !exact.isEmpty { quote = (exact, prefix, suffix) }
            case .position: break   // a hint only; positions shift too easily
            }
        }
        let paragraphs = doc.body ?? []

        if let fragmentID,
           let paragraph = paragraphs.first(where: { $0.id == fragmentID }) {
            if let quote {
                if paragraph.text.range(of: quote.exact, options: matching) != nil {
                    return Resolution(paragraphID: paragraph.id, exact: quote.exact,
                                      method: .quoteInParagraph)
                }
                // The span is gone from its paragraph: paragraph scope
                // stands, per the ladder — never break.
                return Resolution(paragraphID: paragraph.id, exact: nil, method: .paragraph)
            }
            return Resolution(paragraphID: paragraph.id, exact: nil, method: .fragment)
        }

        if let quote {
            var best: (id: String, score: Int)?
            for paragraph in paragraphs {
                let text = paragraph.text
                var search = text.startIndex..<text.endIndex
                while let found = text.range(of: quote.exact, options: matching, range: search) {
                    var score = 0
                    if let prefix = quote.prefix, !prefix.isEmpty {
                        let preceding = String(text[..<found.lowerBound].suffix(prefix.count + 8))
                        if folded(preceding).hasSuffix(folded(prefix)) { score += 1 }
                    }
                    if let suffix = quote.suffix, !suffix.isEmpty {
                        let following = String(text[found.upperBound...].prefix(suffix.count + 8))
                        if folded(following).hasPrefix(folded(suffix)) { score += 1 }
                    }
                    if best == nil || score > best!.score {
                        best = (paragraph.id, score)
                    }
                    guard found.upperBound < text.endIndex else { break }
                    search = found.upperBound..<text.endIndex
                }
            }
            if let best {
                return Resolution(paragraphID: best.id, exact: quote.exact,
                                  method: .quoteInDocument)
            }
        }

        return nil
    }

    /// The target for a new annotation on `paragraphID`, carrying the whole
    /// ladder: the stable id, and — when `exact` names words that occur in
    /// the paragraph — the quote with up to 32 characters of context and a
    /// position hint (character offsets within the paragraph's text).
    static func target(in doc: LiquidDoc, paragraphID: String,
                       exact: String? = nil) -> WebAnnotation.Target {
        var selectors: [WebAnnotation.Selector] = [
            .fragment(value: paragraphID, conformsTo: WebAnnotation.fragmentConformsTo),
        ]
        let paragraph = doc.body?.first { $0.id == paragraphID }
        if let exact, !exact.isEmpty {
            if let text = paragraph?.text,
               let range = text.range(of: exact, options: matching) {
                let prefix = String(text[..<range.lowerBound].suffix(32))
                let suffix = String(text[range.upperBound...].prefix(32))
                selectors.append(.quote(exact: String(text[range]),
                                        prefix: prefix.isEmpty ? nil : prefix,
                                        suffix: suffix.isEmpty ? nil : suffix))
                let start = text.distance(from: text.startIndex, to: range.lowerBound)
                let length = text.distance(from: range.lowerBound, to: range.upperBound)
                selectors.append(.position(start: start, end: start + length))
            } else {
                selectors.append(.quote(exact: exact, prefix: nil, suffix: nil))
            }
        }
        return WebAnnotation.Target(source: "origamitext://open/" + doc.id,
                                    selectors: selectors)
    }

    private static let matching: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    private static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive],
                     locale: Locale(identifier: "en_US_POSIX"))
    }
}
