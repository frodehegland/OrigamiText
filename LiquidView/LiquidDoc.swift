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
    /// Where the document was made, when the producing device or app
    /// recorded it — a place name, free-form. Notes captured on the move
    /// (some by voice, outside Origami Text) carry one.
    var location: String? = nil
    /// Defined Concepts — the document's glossary: a shared pool of
    /// nodes (id, name, definition) that spatial layouts arrange and
    /// citations attach to. Books and papers carry them; the EPUB
    /// export writes them into Visual-Meta.
    var concepts: [Concept] = []
    /// Named spatial arrangements of the concept/citation pool —
    /// positions only, x/y/z (z from XR sessions). How a node renders
    /// belongs to the reader, never the document.
    var layouts: [Layout] = []
    /// Connections between nodes of the concept/citation pool, as drawn
    /// on the source Map. Without them a layout is dots without lines.
    var mapConnections: [MapConnection] = []
    /// External citation records — see `Reference`.
    var references: [Reference] = []
    /// Live tables the body refers to by `Paragraph.tableID`. Values are
    /// pre-computed by the producer, so a read-only reader shows them
    /// as-is; formulas travel too, for the interactive path (see
    /// `Table.laTable()` → `LATable.recalculate()`).
    var tables: [Table] = []
    /// Binary assets (images) the body refers to by a markdown image marker
    /// `![alt](asset:<id>)`. Held with the document so authoring survives
    /// the text editor; the EPUB export writes each into `content/images/`
    /// and turns the marker into a `<figure><img>`.
    var assets: [Asset] = []
    let fileURL: URL          // where it was loaded from (not part of JSON)

    /// The instant the document is listed, sorted, and filtered by.
    var listedDate: Date { date?.sortDate ?? created }

    /// The date shown in bylines and rows.
    var listedDateText: String {
        date?.displayText ?? created.formatted(date: .abbreviated, time: .omitted)
    }

    /// Who the document files under wherever documents are grouped by
    /// person — author lists, circles, weaves, profiles. A letter posted
    /// on someone's behalf belongs to that someone; the poster stays the
    /// `author` of record, and identity logic (matching, muting, unread)
    /// keeps using the plain `author`.
    var creditedAuthor: String {
        if let onBehalfOf, !onBehalfOf.trimmingCharacters(in: .whitespaces).isEmpty,
           onBehalfOf.caseInsensitiveCompare(author) != .orderedSame {
            return onBehalfOf
        }
        return author
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
        // External is text from outside the community — an article, a
        // pasted email — declared when the document is created, optionally
        // on the original author's behalf.
        // A note is the desk's quickest kind: the author's own, often
        // captured in the moment — sometimes by voice, outside the app —
        // carrying a location where the capture had one.
        // A book is the long form: authored like a letter but living a
        // longer life, with its own place in the sidebar.
        case letter, note, book, rfc, personal, project, meeting, transcript, extract, article, external

        var displayName: String {
            switch self {
            case .letter: "Letter"
            case .note: "Note"
            case .book: "Book"
            case .rfc: "RFC"
            case .personal: "Personal"
            case .project: "Project"
            case .meeting: "Meeting"
            case .transcript: "Transcript"
            case .extract: "Extract"
            case .article: "Article"
            case .external: "External"
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
        /// When this element is a table, the identifier of the `Table` in
        /// the document's `tables` pool it stands for. The paragraph's
        /// `text` holds a pipe-table rendering as a plain-text fallback,
        /// so a reader without table support (or the raw editor) still
        /// shows the values; a reader with support renders the grid.
        var tableID: String? = nil
    }

    /// One live table: a row-major grid of cells, each a pre-computed
    /// `value` and an optional spreadsheet `formula`. Mirrors the
    /// Visual-Meta `tables` entry and Author's `LATable`, but as a value
    /// type so `LiquidDoc` stays `Hashable`/`Sendable`. Bridge to the
    /// shared evaluator with `laTable()` when a cell is edited.
    struct Table: Identifiable, Hashable, Sendable {
        struct Cell: Hashable, Sendable {
            var value: String
            var formula: String? = nil
        }
        /// Matches `Paragraph.tableID` and the body `<table data-table-id>`.
        let identifier: String
        var rowCount: Int
        var columnCount: Int
        /// Row-major: `cells[row][column]`.
        var cells: [[Cell]]
        var id: String { identifier }
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

    /// A binary asset (an image) carried with the document. The body refers
    /// to it by `![alt](asset:<id>)`; the id is stable so the reference and
    /// the exported file line up.
    struct Asset: Identifiable, Hashable, Sendable {
        let id: String
        /// The file name used inside the EPUB's `content/images/`.
        var filename: String
        /// e.g. "image/jpeg".
        var mediaType: String
        /// The bytes, base64-encoded so the asset lives in the JSON draft.
        var dataBase64: String
        /// Alt text, when known.
        var alt: String?

        var data: Data? { Data(base64Encoded: dataBase64) }
    }

    /// The asset id a body paragraph's text points at, when the paragraph is
    /// a lone image marker `![alt](asset:<id>)`. Returns the alt text too.
    static func imageReference(in text: String) -> (id: String, alt: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let regex = try? NSRegularExpression(
            pattern: "^!\\[([^\\]]*)\\]\\(asset:([^)]+)\\)$"),
              let match = regex.firstMatch(
                in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
              let altRange = Range(match.range(at: 1), in: trimmed),
              let idRange = Range(match.range(at: 2), in: trimmed) else { return nil }
        return (String(trimmed[idRange]), String(trimmed[altRange]))
    }

    /// A citation record: one work this document rests on, carried as
    /// verbatim BibTeX under a stable id that concepts'
    /// `citationIdentifiers`, spatial layouts, and the EPUB's citation
    /// pool all reference. Citations of *library* documents ride on
    /// `links` (which know their address); these are the external ones
    /// — books, papers, web pages.
    struct Reference: Identifiable, Hashable, Sendable {
        let id: String
        var bibtex: String
    }

    /// A Defined Concept: one node in the document's glossary. Ids are
    /// stable UUID strings — layouts and citations reference them.
    struct Concept: Identifiable, Hashable, Sendable {
        let id: String
        var name: String
        var description: String = ""
        var tag: String? = nil
        /// Citation identifiers this concept rests on — citation node
        /// ids or origami addresses.
        var citationIdentifiers: [String] = []
        var urls: [String] = []
    }

    /// One named spatial arrangement of the shared node pool:
    /// featherweight, ids paired with coordinates and nothing else.
    struct Layout: Hashable, Sendable {
        struct Position: Hashable, Sendable {
            let id: String
            var x: Double
            var y: Double
            var z: Double
        }
        /// Referenced by inline `<n>` markers in body text.
        var index: Int
        var name: String
        var positions: [Position] = []
        /// The saved View's own identity in the source document, when it
        /// has one — exporters keep it rather than substituting indices.
        var sourceID: String? = nil
    }

    /// One drawn connection between two nodes of the shared pool.
    struct MapConnection: Hashable, Sendable {
        let from: String
        let to: String
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

extension LiquidDoc.Table {

    /// The shared, mutable `LATable` for this grid — the interactive path:
    /// edit a cell, `recalculate()`, then map back with `init(_:)`.
    func laTable() -> LATable {
        let table = LATable(identifier: identifier,
                            rows: max(1, rowCount),
                            columns: max(1, columnCount))
        for (rowIndex, row) in cells.enumerated() {
            for (columnIndex, cell) in row.enumerated() {
                table.setValue(cell.value, row: rowIndex, column: columnIndex)
                table.setFormula(cell.formula, row: rowIndex, column: columnIndex)
            }
        }
        return table
    }

    /// Snapshots a (possibly recomputed) `LATable` back into the value model.
    init(_ table: LATable) {
        self.init(identifier: table.identifier,
                  rowCount: table.rowCount,
                  columnCount: table.columnCount,
                  cells: table.cells.map { row in
                      row.map { Cell(value: $0.value, formula: $0.formula) }
                  })
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
                let tableID = rawParagraph.tableID.flatMap { $0.isEmpty ? nil : $0 }
                return Paragraph(id: paragraphID, heading: heading, text: text,
                                 speaker: (speaker?.isEmpty ?? true) ? nil : speaker,
                                 tableID: tableID)
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

        let location = raw.location
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : $0 }

        // Tolerant, like links: a concept or position missing its
        // essentials is skipped, never fatal.
        let concepts: [Concept] = (raw.concepts ?? []).compactMap { rawConcept in
            guard let conceptID = rawConcept.id, let name = rawConcept.name else { return nil }
            return Concept(id: conceptID, name: name,
                           description: rawConcept.description ?? "",
                           tag: rawConcept.tag,
                           citationIdentifiers: rawConcept.citationIdentifiers ?? [],
                           urls: rawConcept.urls ?? [])
        }
        let layouts: [Layout] = (raw.layouts ?? []).enumerated().map { position, rawLayout in
            let positions = (rawLayout.positions ?? []).compactMap { rawPosition -> Layout.Position? in
                guard let positionID = rawPosition.id else { return nil }
                return Layout.Position(id: positionID, x: rawPosition.x ?? 0,
                                       y: rawPosition.y ?? 0, z: rawPosition.z ?? 0)
            }
            return Layout(index: rawLayout.index ?? position + 1,
                          name: rawLayout.name ?? "Layout \(position + 1)",
                          positions: positions,
                          sourceID: rawLayout.id)
        }

        let mapConnections: [MapConnection] = (raw.connections ?? []).compactMap { rawConnection in
            guard let from = rawConnection.from, let to = rawConnection.to else { return nil }
            return MapConnection(from: from, to: to)
        }

        let references: [Reference] = (raw.references ?? []).compactMap { rawReference in
            guard let referenceID = rawReference.id,
                  let bibtex = rawReference.bibtex?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !bibtex.isEmpty else { return nil }
            return Reference(id: referenceID, bibtex: bibtex)
        }

        let tables: [Table] = (raw.tables ?? []).compactMap { rawTable in
            guard let identifier = rawTable.identifier, !identifier.isEmpty else { return nil }
            let cells = (rawTable.cells ?? []).map { row in
                row.map { Table.Cell(value: $0.value ?? "", formula: $0.formula) }
            }
            return Table(identifier: identifier,
                         rowCount: rawTable.rowCount ?? cells.count,
                         columnCount: rawTable.columnCount ?? (cells.first?.count ?? 0),
                         cells: cells)
        }

        let assets: [Asset] = (raw.assets ?? []).compactMap { rawAsset in
            guard let assetID = rawAsset.id, !assetID.isEmpty,
                  let dataBase64 = rawAsset.dataBase64, !dataBase64.isEmpty else { return nil }
            return Asset(id: assetID,
                         filename: rawAsset.filename ?? "\(assetID)",
                         mediaType: rawAsset.mediaType ?? "application/octet-stream",
                         dataBase64: dataBase64,
                         alt: rawAsset.alt)
        }

        return LiquidDoc(format: format, id: id, title: title, author: author,
                         created: created, body: body, links: links, wraps: wraps,
                         attention: attention, date: date,
                         aiOnBehalf: raw.aiOnBehalf ?? false,
                         onBehalfOf: onBehalfOf,
                         documentType: documentType,
                         location: location,
                         concepts: concepts,
                         layouts: layouts,
                         mapConnections: mapConnections,
                         references: references,
                         tables: tables,
                         assets: assets,
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
        var location: String?
        var concepts: [RawConcept]?
        var layouts: [RawLayout]?
        var connections: [RawConnection]?
        var references: [RawReference]?
        var tables: [RawTable]?
        var assets: [RawAsset]?
    }

    private nonisolated struct RawTable: Decodable {
        var identifier: String?
        var rowCount: Int?
        var columnCount: Int?
        var cells: [[RawTableCell]]?
    }

    private nonisolated struct RawTableCell: Decodable {
        var value: String?
        var formula: String?
    }

    private nonisolated struct RawAsset: Decodable {
        var id: String?
        var filename: String?
        var mediaType: String?
        var dataBase64: String?
        var alt: String?
    }

    private nonisolated struct RawConnection: Decodable {
        var from: String?
        var to: String?
    }

    private nonisolated struct RawReference: Decodable {
        var id: String?
        var bibtex: String?
    }

    private nonisolated struct RawParagraph: Decodable {
        var id: String?
        var heading: Int?
        var text: String?
        var speaker: String?
        var tableID: String?
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

    private nonisolated struct RawConcept: Decodable {
        var id: String?
        var name: String?
        var description: String?
        var tag: String?
        var citationIdentifiers: [String]?
        var urls: [String]?
    }

    private nonisolated struct RawLayout: Decodable {
        struct RawPosition: Decodable {
            var id: String?
            var x: Double?
            var y: Double?
            var z: Double?
        }
        var index: Int?
        var name: String?
        var positions: [RawPosition]?
        var id: String?
    }
}

nonisolated enum FileHasher {
    static func sha256Hex(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
