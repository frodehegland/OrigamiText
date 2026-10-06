import CryptoKit
import Foundation
import Synchronization

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

    /// The sidecar's bytes as they stand — a W3C AnnotationCollection,
    /// the heart of a Readium annotation set — for Export Annotations….
    public static func exportData(for address: String, in folder: URL) -> Data? {
        try? Data(contentsOf: fileURL(for: address, in: folder))
    }

    /// Writes the sidecar, or removes it when the last annotation is
    /// gone. False when the notes did not reach the disk — the caller
    /// owes the reader that truth.
    @discardableResult
    public static func save(_ annotations: [WebAnnotation], for address: String, in folder: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = fileURL(for: address, in: folder)
            guard !annotations.isEmpty else {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
                return true
            }
            // Every annotation in this sidecar is about this book, so each
            // is written naming it the shared way (DocumentIdentity) —
            // whatever an older version, an import or another app wrote.
            var annotations = annotations
            if let source = BookIdentities.source(forAddress: address) {
                for index in annotations.indices { annotations[index].target.source = source }
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(CollectionFile(items: annotations))
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
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

    /// The paragraph an address names when the address and the document
    /// disagree only in form: Scrolling mode files a bare id (`P-1`), the
    /// native modes a profile book's `content.xhtml#P-1`. Taken only when
    /// exactly one paragraph carries that id, so a bare id repeated in two
    /// documents falls through to the words instead of guessing.
    static func sameElement(_ address: String,
                            in paragraphs: [LiquidDoc.Paragraph]) -> LiquidDoc.Paragraph? {
        func fragment(_ value: String) -> Substring {
            value.split(separator: "#", omittingEmptySubsequences: false).last ?? Substring(value)
        }
        let wanted = fragment(address)
        guard !wanted.isEmpty else { return nil }
        // Two path#id forms that differ name different documents.
        let addressHasPath = address.contains("#")
        let matches = paragraphs.filter {
            fragment($0.id) == wanted && !(addressHasPath && $0.id.contains("#"))
        }
        return matches.count == 1 ? matches[0] : nil
    }

    /// Where an annotation lands in this document, or nil when nothing in
    /// it still matches (an orphan — kept and shown, never lost). The
    /// cascade, Hypothesis's way: the stable id and exact words; the
    /// words fuzzily inside their paragraph; the exact words anywhere
    /// (context-scored); the words fuzzily anywhere, searched outward
    /// from where the position and progression hints expect them.
    static func resolve(_ annotation: WebAnnotation, in doc: LiquidDoc) -> Resolution? {
        var fragmentID: String?
        var quote: (exact: String, prefix: String?, suffix: String?)?
        var positionHint: Int?
        var progressionHint: Double?
        for selector in annotation.target.selectors {
            switch selector {
            case .fragment(let value, _): fragmentID = fragmentID ?? value
            case .quote(let exact, let prefix, let suffix):
                if quote == nil, !exact.isEmpty { quote = (exact, prefix, suffix) }
            case .position(let start, _): positionHint = positionHint ?? start
            case .progression(let value): progressionHint = progressionHint ?? value
            }
        }
        let paragraphs = doc.body ?? []
        let anchored = fragmentID.flatMap { id in
            paragraphs.first { $0.id == id } ?? sameElement(id, in: paragraphs)
        }

        if let paragraph = anchored {
            if let quote {
                if paragraph.text.range(of: quote.exact, options: matching) != nil {
                    return Resolution(paragraphID: paragraph.id, exact: quote.exact,
                                      method: .quoteInParagraph)
                }
                // The words drifted (an edit, a re-export): find their
                // nearest reading inside the paragraph, and highlight
                // the document's own words there.
                if let fuzzy = fuzzyMatch(quote.exact, in: paragraph.text) {
                    return Resolution(paragraphID: paragraph.id, exact: fuzzy,
                                      method: .quoteInParagraph)
                }
                // The span is gone from its paragraph: paragraph scope
                // stands, per the ladder — never break.
                return Resolution(paragraphID: paragraph.id, exact: nil, method: .paragraph)
            }
            return Resolution(paragraphID: paragraph.id, exact: nil, method: .fragment)
        }

        guard let quote else { return nil }

        // Exact words anywhere, the prefix/suffix breaking ties.
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

        // Fuzzy anywhere — but hinted: paragraphs are tried outward
        // from where the position (or progression) says the words
        // were, so the search usually ends where it starts.
        let ordered = hintOrdered(paragraphs, positionHint: positionHint,
                                  progressionHint: progressionHint)
        for paragraph in ordered {
            if let fuzzy = fuzzyMatch(quote.exact, in: paragraph.text) {
                return Resolution(paragraphID: paragraph.id, exact: fuzzy,
                                  method: .quoteInDocument)
            }
        }

        return nil
    }

    /// The paragraphs ordered outward from the hinted place: the
    /// position selector's global offset when there is one, else the
    /// progression fraction, else document order.
    private static func hintOrdered(_ paragraphs: [LiquidDoc.Paragraph],
                                    positionHint: Int?,
                                    progressionHint: Double?) -> [LiquidDoc.Paragraph] {
        guard positionHint != nil || progressionHint != nil else { return paragraphs }
        var offsets: [Int] = []
        var running = 0
        for paragraph in paragraphs {
            offsets.append(running)
            running += paragraph.text.count + 2
        }
        let target: Int
        if let positionHint {
            target = positionHint
        } else {
            target = Int(Double(running) * min(max(progressionHint ?? 0, 0), 1))
        }
        return zip(paragraphs, offsets)
            .sorted { abs($0.1 - target) < abs($1.1 - target) }
            .map(\.0)
    }

    /// The document's own words nearest the quote, within an edit
    /// budget of a fifth of the quote (at least 2, at most 24 edits) —
    /// Sellers's approximate substring search. Returns the matched
    /// words as the document writes them, so the highlight paints what
    /// the page actually says. Short quotes stay exact-only: fuzziness
    /// on a few characters matches noise.
    static func fuzzyMatch(_ quote: String, in text: String) -> String? {
        let needle = Array(quote.lowercased())
        let haystack = Array(text.lowercased())
        guard needle.count >= 8, !haystack.isEmpty else { return nil }
        let budget = max(2, min(needle.count / 5, 24))

        // D[i] = fewest edits matching needle[0..<i] ending at the
        // current haystack position; start[i] = where that match began.
        var previousDistance = Array(0...needle.count)
        var previousStart = Array(repeating: 0, count: needle.count + 1)
        var best: (start: Int, end: Int, distance: Int)?

        for j in 1...haystack.count {
            var currentDistance = [0] + Array(repeating: 0, count: needle.count)
            var currentStart = Array(repeating: j, count: needle.count + 1)
            for i in 1...needle.count {
                let substitution = previousDistance[i - 1]
                    + (needle[i - 1] == haystack[j - 1] ? 0 : 1)
                let deletion = previousDistance[i] + 1
                let insertion = currentDistance[i - 1] + 1
                let smallest = min(substitution, min(deletion, insertion))
                currentDistance[i] = smallest
                if smallest == substitution {
                    currentStart[i] = previousStart[i - 1]
                } else if smallest == deletion {
                    currentStart[i] = previousStart[i]
                } else {
                    currentStart[i] = currentStart[i - 1]
                }
            }
            let distance = currentDistance[needle.count]
            if distance <= budget, best == nil || distance < best!.distance {
                best = (currentStart[needle.count], j, distance)
            }
            previousDistance = currentDistance
            previousStart = currentStart
        }

        guard let best else { return nil }
        let characters = Array(text)
        guard best.start < best.end, best.end <= characters.count else { return nil }
        let matched = String(characters[best.start..<best.end])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return matched.isEmpty ? nil : matched
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
        // The coarse fraction through the document — Readium's
        // ProgressionSelector: ordering, hinting, and last resort.
        if let body = doc.body, !body.isEmpty,
           let index = body.firstIndex(where: { $0.id == paragraphID }) {
            selectors.append(.progression(Double(index) / Double(body.count)))
        }
        return WebAnnotation.Target(source: "origamitext://open/" + doc.id,
                                    selectors: selectors)
    }

    private static let matching: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]

    private static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                     locale: Locale(identifier: "en_US_POSIX"))
    }
}

// MARK: - Document identity

/// What an annotation calls its book, said the way any other reader can
/// match — the OrigamiFormat package's rule, which this mirrors until
/// Origami Text links the package (rebuild guide, chapter 3 §4):
///
/// 1. **The DOI**, where the work has one — the name the world uses.
/// 2. **The publication's own identifier**, when it is globally unique
///    (`urn:uuid:`, `urn:isbn:`) — an Origami Profile 1.0 EPUB's
///    `dc:identifier`, which survives re-export where a hash would not.
/// 3. **A content hash** of the EPUB file, `urn:origami:sha256:<hex>`.
/// 4. **The local address**, `urn:origami:local:<address>`, last.
///
/// Reading is more generous than writing: `normalised` folds every form
/// either app has written — `origamitext://open/…`, `urn:x-reader:…` —
/// onto one comparable key, so notes already on disk keep matching.
public nonisolated enum DocumentIdentity {
    public static let hashScheme = "urn:origami:sha256:"
    public static let localScheme = "urn:origami:local:"
    public static let legacyReaderScheme = "urn:x-reader:"
    public static let legacyOrigamiScheme = "origamitext://open/"

    public static func canonical(doi: String? = nil, publicationID: String? = nil,
                                 contentHash: String? = nil,
                                 localName: String? = nil) -> String {
        if let bare = bareDOI(doi) { return "https://doi.org/" + bare }
        if let publicationID, let unique = globallyUnique(publicationID) { return unique }
        if let contentHash, isContentHash(contentHash) {
            return hashScheme + contentHash.lowercased()
        }
        if let localName, !localName.isEmpty {
            if isContentHash(localName) { return hashScheme + localName.lowercased() }
            return localScheme + localName
        }
        return ""
    }

    /// A comparable key: two IRIs name the same document exactly when
    /// their keys are equal.
    public static func normalised(_ iri: String) -> String {
        let trimmed = iri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let bare = doiPortion(of: trimmed) { return "doi:" + bare }
        if let unique = globallyUnique(trimmed) {
            return String(unique.dropFirst(4)).lowercased()   // "uuid:…" / "isbn:…"
        }
        if let hash = after(hashScheme, in: trimmed) { return "sha256:" + hash.lowercased() }
        if let name = after(localScheme, in: trimmed) { return "local:" + name }
        for legacy in [legacyReaderScheme, legacyOrigamiScheme] {
            if let name = after(legacy, in: trimmed) {
                return isContentHash(name) ? "sha256:" + name.lowercased() : "local:" + name
            }
        }
        return trimmed.lowercased()
    }

    public static func isSameDocument(_ one: String, _ other: String) -> Bool {
        let a = normalised(one)
        return !a.isEmpty && a == normalised(other)
    }

    /// `urn:uuid:` and `urn:isbn:` name one publication everywhere; any
    /// other package identifier (a bare "bookid", a database key) may
    /// not, and is passed over rather than trusted.
    static func globallyUnique(_ identifier: String) -> String? {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("urn:uuid:"),
           UUID(uuidString: String(trimmed.dropFirst(9))) != nil {
            return "urn:uuid:" + String(lowered.dropFirst(9))
        }
        if lowered.hasPrefix("urn:isbn:") {
            let digits = trimmed.dropFirst(9).filter { $0.isNumber || $0 == "X" || $0 == "x" }
            if digits.count == 10 || digits.count == 13 { return "urn:isbn:" + digits.uppercased() }
        }
        return nil
    }

    static func bareDOI(_ text: String?) -> String? {
        guard let text else { return nil }
        var stripped = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://doi.org/", "http://doi.org/", "https://dx.doi.org/",
                       "http://dx.doi.org/", "doi:"]
        where stripped.lowercased().hasPrefix(prefix) {
            stripped = String(stripped.dropFirst(prefix.count))
        }
        stripped = stripped.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return stripped.hasPrefix("10.") && stripped.contains("/") ? stripped : nil
    }

    static func doiPortion(of iri: String) -> String? {
        let lowered = iri.lowercased()
        if ["https://doi.org/", "http://doi.org/", "https://dx.doi.org/",
            "http://dx.doi.org/", "doi:", "10."].contains(where: lowered.hasPrefix) {
            return bareDOI(iri)
        }
        return nil
    }

    public static func isContentHash(_ text: String) -> Bool {
        text.count == 64 && text.allSatisfy(\.isHexDigit)
    }

    /// SHA-256 of a file, lowercase hex; nil when it can't be read.
    static func contentHash(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func after(_ prefix: String, in text: String) -> String? {
        guard text.lowercased().hasPrefix(prefix.lowercased()) else { return nil }
        let rest = String(text.dropFirst(prefix.count))
        return rest.isEmpty ? nil : rest
    }
}

/// What the store knows of each shelved book, for naming it in its
/// annotations: refreshed by AppModel whenever the shelf changes, read
/// by every save — including sync's, off the main actor — hence the lock.
/// A content hash is worked out only when a book has neither DOI nor a
/// unique publication identifier, once per file.
public nonisolated enum BookIdentities {
    struct Book: Sendable {
        var doi: String?
        var publicationID: String?
        var epubFile: URL
        var address: String
    }

    private struct State: Sendable {
        var books: [String: Book] = [:]
        var hashes: [String: String] = [:]
    }

    private static let state = Mutex(State())

    /// Replaces the table; each book is reachable by its record id and
    /// its folder, the two addresses sidecars have been keyed by.
    static func update(_ records: [EPUBRecord], epubFile: (EPUBRecord) -> URL) {
        var books: [String: Book] = [:]
        for record in records {
            let book = Book(doi: record.doi, publicationID: record.packageIdentifier,
                            epubFile: epubFile(record), address: record.id)
            books[record.folder] = book
            books[record.id] = book
        }
        state.withLock { $0.books = books }
    }

    /// The name to write for the book at `address`; nil for an address
    /// that is no shelved book (a native document, a Gemini page), whose
    /// annotations keep the source they were written with.
    static func source(forAddress address: String) -> String? {
        guard let book = state.withLock({ $0.books[address] }) else { return nil }
        if DocumentIdentity.bareDOI(book.doi) != nil
            || book.publicationID.flatMap(DocumentIdentity.globallyUnique) != nil {
            return DocumentIdentity.canonical(doi: book.doi, publicationID: book.publicationID)
        }
        // Keyed by the file's size and date too: a replaced edition is a
        // different file, and gets its own hash.
        let attributes = try? FileManager.default.attributesOfItem(atPath: book.epubFile.path)
        let key = [book.epubFile.path,
                   "\((attributes?[.size] as? Int) ?? 0)",
                   "\((attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"]
            .joined(separator: "|")
        var hash = state.withLock { $0.hashes[key] }
        if hash == nil, let computed = DocumentIdentity.contentHash(of: book.epubFile) {
            hash = computed
            state.withLock { $0.hashes[key] = computed }
        }
        return DocumentIdentity.canonical(contentHash: hash, localName: book.address)
    }
}
