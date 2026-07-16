import Foundation
import CryptoKit

/// An in-memory Origami Document (`.origamitext`), either a text document
/// (`body`) or a sidecar wrapping an external file (`wraps`).
///
/// Document ids are short human-readable strings (see LiquidAddress) that
/// double as the file name; legacy UUID ids are accepted as opaque strings.
nonisolated struct LiquidDoc: Identifiable, Hashable, Sendable {
    let format: String
    let id: String
    let title: String
    let author: String
    let created: Date
    let body: [Paragraph]?
    let links: [Link]
    let wraps: Wrapped?
    /// People this document is addressed to — "for the attention of".
    /// Plain names, readable by any person or system.
    var attention: [String] = []
    /// Human-assigned date (meeting date, historical date). When present it
    /// is what the document is listed, sorted, and filtered by; `created`
    /// remains the immutable timestamp the id derives from.
    var date: LiquidDate? = nil
    /// Produced by an AI on behalf of the author, who reviewed it and
    /// stands by it. `author` stays the human name — the one to cite and
    /// the one accountable.
    var aiOnBehalf: Bool = false
    /// Whose words these are, when they are not the author's own — the
    /// speaker a statement was lifted from a transcript for. `author`
    /// stays the person who made and exported the document; the named
    /// person is the one to credit for the content ("Exported by
    /// *author* on behalf of *name*").
    var onBehalfOf: String? = nil
    /// What kind of document this is, declared by the author at export so
    /// readers can triage without opening it. A lowercase token with an
    /// open vocabulary, like link rels: `DocumentType` names the
    /// recommended values, but unknown tokens are preserved verbatim,
    /// never dropped. Absent means unspecified.
    var documentType: String? = nil
    let fileURL: URL          // where it was loaded from (not part of JSON)

    /// The instant the document is listed, sorted, and filtered by.
    var listedDate: Date { date?.sortDate ?? created }

    /// The date shown in bylines and rows.
    var listedDateText: String {
        date?.displayText ?? created.formatted(date: .abbreviated, time: .omitted)
    }

    /// The byline as a reader should see it: AI production is never
    /// silent. Identity logic (matching, muting, attention) keeps using
    /// the plain `author`.
    var displayAuthor: String {
        if aiOnBehalf { return "AI on behalf of \(author)" }
        // One's own words need no declaration: a self-referential name
        // (the author lifted their own statement) stays silent.
        if let onBehalfOf, onBehalfOf.caseInsensitiveCompare(author) != .orderedSame {
            return "\(author) on behalf of \(onBehalfOf)"
        }
        return author
    }

    /// The recommended `documentType` vocabulary. Raw values are the
    /// lowercase tokens written to JSON and Visual-Meta; the vocabulary
    /// is open, so tokens beyond these are valid and kept as-is.
    enum DocumentType: String, CaseIterable, Hashable, Sendable {
        // Letters are the core kind: authored pieces in the community's
        // correspondence. A transcript is letters between people in a
        // meeting, assigned at import; an extract is a statement lifted
        // out of a transcript, assigned at lift; a letter is assigned at
        // export. The acts name the kinds — the author never files.
        case letter, rfc, personal, project, meeting, transcript, extract, article

        var displayName: String {
            switch self {
            case .letter: "Letter"
            case .rfc: "RFC"
            case .personal: "Personal"
            case .project: "Project"
            case .meeting: "Meeting"
            case .transcript: "Transcript"
            case .extract: "Extract"
            case .article: "Article"
            }
        }
    }

    struct Paragraph: Identifiable, Hashable, Sendable {
        let id: String
        let heading: Int?
        let text: String
        /// Who said this — transcript attribution. The name also leads the
        /// text ("Name: …"), so a plain-text reader loses nothing; a reader
        /// with this field styles the name and hides the prefix, exactly as
        /// heading levels pair with # prefixes.
        var speaker: String? = nil
    }

    struct Link: Hashable, Sendable {
        let to: String
        let fragment: String?
        let rel: String?
        /// The citation's full BibTeX record — the link carries its own
        /// provenance (emitted into the Visual-Meta @{references} block).
        var bibtex: String? = nil
        /// Span scope, after Ted Nelson: the exact words within the target
        /// paragraph this link points at — the finest rung of the scope
        /// ladder (document, paragraph, span). Readers highlight the span
        /// where it occurs; where it doesn't, the paragraph scope stands.
        var span: String? = nil
    }

    struct Wrapped: Hashable, Sendable {
        let file: String
        let sha256: String
        let mediaType: String?
    }

    static let knownFormat = "origami/0.1"
    /// The document file extension; also appears in user-facing text, so
    /// change the spots the compiler can't see when changing this.
    static let fileExtension = "origamitext"

    var isSidecar: Bool { wraps != nil }

    /// An `origami/0.x` version other than the one this app was written
    /// against. Still opened, but flagged with a warning badge.
    var hasUnfamiliarFormatVersion: Bool { format != Self.knownFormat }
}

nonisolated enum LiquidDocError: LocalizedError {
    case invalidJSON(String)
    case missingField(String)
    case unsupportedFormat(String)
    case invalidID(String)
    case invalidDate(String)
    case bothBodyAndWraps
    case missingBodyOrWraps
    case malformedParagraph(Int)

    var errorDescription: String? {
        switch self {
        case .invalidJSON(let detail): "Not valid JSON: \(detail)"
        case .missingField(let name): "Missing required field “\(name)”"
        case .unsupportedFormat(let format): "Unsupported format “\(format)”"
        case .invalidID(let value): "“\(value)” is not a valid document id"
        case .invalidDate(let value): "“\(value)” is not a valid ISO 8601 date"
        case .bothBodyAndWraps: "A document may have “body” or “wraps”, not both"
        case .missingBodyOrWraps: "A document needs either “body” or “wraps”"
        case .malformedParagraph(let index): "Paragraph \(index + 1) is missing its “id” or “text”"
        }
    }
}

extension LiquidDoc {

    /// Tolerant decoding: unknown keys anywhere are ignored, `links` defaults
    /// to empty, and links whose `to` is not a usable id are skipped.
    nonisolated static func decode(data: Data, fileURL: URL) throws -> LiquidDoc {
        let raw: RawDoc
        do {
            raw = try JSONDecoder().decode(RawDoc.self, from: data)
        } catch {
            throw LiquidDocError.invalidJSON(error.localizedDescription)
        }

        guard let format = raw.format else { throw LiquidDocError.missingField("format") }
        guard format.hasPrefix("origami/0") else { throw LiquidDocError.unsupportedFormat(format) }
        guard let rawID = raw.id else { throw LiquidDocError.missingField("id") }
        let id = LiquidAddress.canonical(rawID)
        guard LiquidAddress.isValid(id) else { throw LiquidDocError.invalidID(rawID) }
        guard let title = raw.title else { throw LiquidDocError.missingField("title") }
        guard let author = raw.author else { throw LiquidDocError.missingField("author") }
        guard let createdString = raw.created else { throw LiquidDocError.missingField("created") }
        guard let created = parseISO8601(createdString) else { throw LiquidDocError.invalidDate(createdString) }

        switch (raw.body, raw.wraps) {
        case (.some, .some): throw LiquidDocError.bothBodyAndWraps
        case (nil, nil): throw LiquidDocError.missingBodyOrWraps
        default: break
        }

        let body: [Paragraph]? = try raw.body.map { rawParagraphs in
            try rawParagraphs.enumerated().map { index, rawParagraph in
                guard let paragraphID = rawParagraph.id, let text = rawParagraph.text else {
                    throw LiquidDocError.malformedParagraph(index)
                }
                let heading = rawParagraph.heading.map { min(max($0, 1), 3) }
                let speaker = rawParagraph.speaker?.trimmingCharacters(in: .whitespaces)
                return Paragraph(id: paragraphID, heading: heading, text: text,
                                 speaker: (speaker?.isEmpty ?? true) ? nil : speaker)
            }
        }

        let links: [Link] = (raw.links ?? []).compactMap { rawLink in
            guard let toString = rawLink.to else { return nil }
            let to = LiquidAddress.canonical(toString)
            guard LiquidAddress.isValid(to) else { return nil }
            return Link(to: to, fragment: rawLink.fragment, rel: rawLink.rel,
                        bibtex: rawLink.bibtex, span: rawLink.span)
        }

        var wraps: Wrapped?
        if let rawWraps = raw.wraps {
            guard let file = rawWraps.file else { throw LiquidDocError.missingField("wraps.file") }
            guard let sha256 = rawWraps.sha256 else { throw LiquidDocError.missingField("wraps.sha256") }
            wraps = Wrapped(file: file, sha256: sha256, mediaType: rawWraps.mediaType)
        }

        let attention = (raw.attention ?? [])
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // Tolerant: an unparseable date is dropped, not fatal.
        let date = raw.date.flatMap(LiquidDate.init(isoString:))

        let onBehalfOf = raw.onBehalfOf
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : $0 }

        // Open vocabulary: any token is kept, so a type this app has
        // never heard of survives a round trip through it.
        let documentType = raw.documentType
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .flatMap { $0.isEmpty ? nil : $0 }

        return LiquidDoc(format: format, id: id, title: title, author: author,
                         created: created, body: body, links: links, wraps: wraps,
                         attention: attention, date: date,
                         aiOnBehalf: raw.aiOnBehalf ?? false,
                         onBehalfOf: onBehalfOf,
                         documentType: documentType,
                         fileURL: fileURL)
    }

    /// Some producers emit fractional seconds; try both.
    nonisolated static func parseISO8601(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string)
    }

    // Raw shapes with every field optional so unknown keys and missing
    // fields surface as our own errors rather than DecodingError noise.
    private nonisolated struct RawDoc: Decodable {
        var format: String?
        var id: String?
        var title: String?
        var author: String?
        var created: String?
        var body: [RawParagraph]?
        var links: [RawLink]?
        var wraps: RawWrapped?
        var attention: [String]?
        var date: String?
        var aiOnBehalf: Bool?
        var onBehalfOf: String?
        var documentType: String?
    }

    private nonisolated struct RawParagraph: Decodable {
        var id: String?
        var heading: Int?
        var text: String?
        var speaker: String?
    }

    private nonisolated struct RawLink: Decodable {
        var to: String?
        var fragment: String?
        var rel: String?
        var bibtex: String?
        var span: String?
    }

    private nonisolated struct RawWrapped: Decodable {
        var file: String?
        var sha256: String?
        var mediaType: String?
    }
}

nonisolated enum FileHasher {
    static func sha256Hex(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
