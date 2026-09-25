import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#endif

// Serialization and editing-text conversions for authoring.
extension LiquidDoc {

    /// Serializes to canonical `.origamitext` JSON.
    nonisolated func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Output(self))
    }

    /// Suggested file name: a short title slug for human eyes, then the
    /// document id — "meeting-summary--f.hegla.093000k.origamitext". The id
    /// is the address citations use and never changes with the title; the
    /// slug is naming convenience only. Readers take the id from the file's
    /// contents, so a renamed file still resolves.
    nonisolated var suggestedExportFileName: String {
        let slug = Self.fileSlug(from: title)
        let ext = Self.fileExtension
        return slug.isEmpty ? "\(id).\(ext)" : "\(slug)--\(id).\(ext)"
    }

    /// The Visual-Meta ecosystem file name — the full title, then the
    /// identity key: "Title(Author-Name-2026-07-11T09_32_52Z).ext".
    /// Author, title, and moment are all present, so the name stays
    /// unique in practice and, as long as it is not renamed, the
    /// deterministic address derives straight from it
    /// (`identityKeyID(inFileName:)` is the inverse).
    nonisolated func identityFileName(extension ext: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let stamp = formatter.string(from: created)
            .replacingOccurrences(of: ":", with: "_")
        let authorKey = author.split(separator: " ").joined(separator: "-")
        // The title travels whole; only filesystem-hostile characters go.
        var cleanTitle = title.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        if cleanTitle.isEmpty { cleanTitle = "Untitled" }
        // Stay comfortably inside filename limits, identity key intact.
        let identity = "(\(authorKey)-\(stamp))"
        let room = 240 - identity.count - ext.count - 1
        if cleanTitle.count > room { cleanTitle = String(cleanTitle.prefix(room)) }
        return "\(cleanTitle)\(identity).\(ext)"
    }

    /// The deterministic address a Visual-Meta ecosystem file name
    /// carries — "Title(Author-Name-2026-07-11T09_32_52Z).ext" — or nil
    /// when the name has no identity key.
    nonisolated static func identityKeyID(inFileName name: String) -> String? {
        let pattern = "\\((.+?)-(\\d{4}-\\d{2}-\\d{2}T\\d{2}_\\d{2}_\\d{2}Z)\\)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              let slugRange = Range(match.range(at: 1), in: name),
              let stampRange = Range(match.range(at: 2), in: name),
              let created = parseISO8601(
                  name[stampRange].replacingOccurrences(of: "_", with: ":"))
        else { return nil }
        let author = name[slugRange].replacingOccurrences(of: "-", with: " ")
        return LiquidAddress.makeID(author: author, created: created)
    }

    /// Lowercased, hyphen-joined title words, whole words up to ~24
    /// characters. "Untitled" earns no slug.
    nonisolated static func fileSlug(from title: String) -> String {
        guard title.caseInsensitiveCompare("Untitled") != .orderedSame else { return "" }
        let words = title.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
        var slug = ""
        for word in words {
            let candidate = slug.isEmpty ? word : "\(slug)-\(word)"
            if candidate.count > 24 { break }
            slug = candidate
        }
        // A single over-long first word is still better than nothing.
        if slug.isEmpty, let first = words.first { slug = String(first.prefix(24)) }
        return slug
    }

    /// The body as editable text: one paragraph per line, with `#`, `##`,
    /// or `###` prefixes marking heading levels.
    nonisolated var bodyEditingText: String {
        guard let body else { return "" }
        return body.map { paragraph in
            let prefix: String = switch paragraph.heading {
            case 1: "# "
            case 2: "## "
            case 3: "### "
            default: ""
            }
            return prefix + paragraph.text
        }
        .joined(separator: "\n\n")
    }

    /// Inverse of `bodyEditingText`. Paragraph ids are assigned sequentially
    /// (p1, p2, …) on every parse.
    nonisolated static func parseBody(from text: String) -> [Paragraph] {
        var paragraphs: [Paragraph] = []
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let markdown = markdownHeading(in: trimmed)
            paragraphs.append(Paragraph(id: "p\(paragraphs.count + 1)",
                                        heading: markdown?.level,
                                        text: markdown?.text ?? trimmed))
        }
        return paragraphs
    }

    /// Finds document references (a UUID, optionally with #fragment) in body
    /// text, so a pasted citation becomes a structured `cites` link on save.
    nonisolated static func detectedLinks(in body: [Paragraph]) -> [Link] {
        var links: [Link] = []
        var seen: Set<String> = []
        for paragraph in body {
            for match in LiquidAddress.matches(in: paragraph.text) {
                // Person addresses are navigational, not document links.
                guard !LiquidAddress.isPersonAddress(match.id) else { continue }
                let key = "\(match.id)#\(match.fragment ?? "")"
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                // A paragraph-scoped citation preceded by a quotation takes
                // the quoted words as its span (§4 citation convention).
                let span = match.fragment == nil
                    ? nil
                    : precedingQuote(in: paragraph.text, before: match.range)
                links.append(Link(to: match.id, fragment: match.fragment,
                                  rel: match.rel ?? "cites", span: span))
            }
        }
        return links
    }

    /// The quoted words a citation cites: the nearest “…" quotation whose
    /// closing quote sits within 80 characters of the address — the shape
    /// the citation text convention produces (“Quote” (Author, Year)
    /// [address#p3]). The quote may be the cited passage or the work's
    /// title; readers treat the span as scope only where it occurs in the
    /// target paragraph, so a title-quote degrades to paragraph scope.
    private nonisolated static func precedingQuote(in text: String, before range: NSRange) -> String? {
        let nsText = text as NSString
        let prefix = nsText.substring(to: min(range.location, nsText.length))
        guard let closing = prefix.range(of: "”", options: .backwards) else { return nil }
        let between = prefix[closing.upperBound...]
        guard between.count <= 80, !between.contains("“"), !between.contains("”") else { return nil }
        guard let opening = prefix.range(of: "“", options: .backwards,
                                         range: prefix.startIndex..<closing.lowerBound) else { return nil }
        let quote = String(prefix[opening.upperBound..<closing.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        return quote.isEmpty ? nil : quote
    }

    /// Detects a markdown ATX heading prefix ("# ", "## ", "### ") and
    /// returns its level with the prefix stripped.
    nonisolated static func markdownHeading(in text: String) -> (level: Int, text: String)? {
        for level in (1...3).reversed() {
            let prefix = String(repeating: "#", count: level) + " "
            if text.hasPrefix(prefix) {
                return (level, String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    // Encodable mirror so the stored model can keep its non-JSON `fileURL`
    // and emit lowercase UUIDs and ISO 8601 dates.
    // (Display-side markdown handling lives on Paragraph below.)
    private nonisolated struct Output: Encodable {
        let doc: LiquidDoc
        init(_ doc: LiquidDoc) { self.doc = doc }

        enum CodingKeys: String, CodingKey { case format, id, title, author, created, date, body, links, wraps, attention, aiOnBehalf, onBehalfOf, documentType, location, sourceURL, publication, concepts, layouts, connections, references, tables, assets }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(doc.format, forKey: .format)
            try container.encode(doc.id, forKey: .id)
            try container.encode(doc.title, forKey: .title)
            try container.encode(doc.author, forKey: .author)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            try container.encode(formatter.string(from: doc.created), forKey: .created)
            if let date = doc.date {
                try container.encode(date.isoString, forKey: .date)
            }
            if let body = doc.body {
                try container.encode(body.map(OutputParagraph.init), forKey: .body)
            }
            if !doc.links.isEmpty {
                try container.encode(doc.links.map(OutputLink.init), forKey: .links)
            }
            if let wraps = doc.wraps {
                try container.encode(OutputWrapped(wraps), forKey: .wraps)
            }
            if !doc.attention.isEmpty {
                try container.encode(doc.attention, forKey: .attention)
            }
            if doc.aiOnBehalf {
                try container.encode(true, forKey: .aiOnBehalf)
            }
            if let onBehalfOf = doc.onBehalfOf {
                try container.encode(onBehalfOf, forKey: .onBehalfOf)
            }
            if let documentType = doc.documentType {
                try container.encode(documentType, forKey: .documentType)
            }
            if let location = doc.location {
                try container.encode(location, forKey: .location)
            }
            if let sourceURL = doc.sourceURL {
                try container.encode(sourceURL, forKey: .sourceURL)
            }
            if let publication = doc.publication {
                try container.encode(publication, forKey: .publication)
            }
            if !doc.concepts.isEmpty {
                try container.encode(doc.concepts.map(OutputConcept.init), forKey: .concepts)
            }
            if !doc.layouts.isEmpty {
                try container.encode(doc.layouts.map(OutputLayout.init), forKey: .layouts)
            }
            if !doc.mapConnections.isEmpty {
                try container.encode(doc.mapConnections.map(OutputConnection.init), forKey: .connections)
            }
            if !doc.references.isEmpty {
                try container.encode(doc.references.map(OutputReference.init), forKey: .references)
            }
            if !doc.tables.isEmpty {
                try container.encode(doc.tables.map(OutputTable.init), forKey: .tables)
            }
            if !doc.assets.isEmpty {
                try container.encode(doc.assets.map(OutputAsset.init), forKey: .assets)
            }
        }
    }

    private nonisolated struct OutputAsset: Encodable {
        let asset: Asset
        init(_ asset: Asset) { self.asset = asset }

        enum CodingKeys: String, CodingKey { case id, filename, mediaType, dataBase64, alt }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(asset.id, forKey: .id)
            try container.encode(asset.filename, forKey: .filename)
            try container.encode(asset.mediaType, forKey: .mediaType)
            try container.encode(asset.dataBase64, forKey: .dataBase64)
            try container.encodeIfPresent(asset.alt, forKey: .alt)
        }
    }

    private nonisolated struct OutputTable: Encodable {
        let table: Table
        init(_ table: Table) { self.table = table }

        enum CodingKeys: String, CodingKey { case identifier, rowCount, columnCount, cells }

        struct OutputCell: Encodable {
            let cell: Table.Cell
            init(_ cell: Table.Cell) { self.cell = cell }

            enum CodingKeys: String, CodingKey { case value, formula }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(cell.value, forKey: .value)
                try container.encodeIfPresent(cell.formula, forKey: .formula)
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(table.identifier, forKey: .identifier)
            try container.encode(table.rowCount, forKey: .rowCount)
            try container.encode(table.columnCount, forKey: .columnCount)
            try container.encode(table.cells.map { $0.map(OutputCell.init) }, forKey: .cells)
        }
    }

    private nonisolated struct OutputReference: Encodable {
        let reference: Reference
        init(_ reference: Reference) { self.reference = reference }

        enum CodingKeys: String, CodingKey { case id, bibtex }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(reference.id, forKey: .id)
            try container.encode(reference.bibtex, forKey: .bibtex)
        }
    }

    private nonisolated struct OutputConcept: Encodable {
        let concept: Concept
        init(_ concept: Concept) { self.concept = concept }

        enum CodingKeys: String, CodingKey { case id, name, description, tag, citationIdentifiers, urls }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(concept.id, forKey: .id)
            try container.encode(concept.name, forKey: .name)
            if !concept.description.isEmpty {
                try container.encode(concept.description, forKey: .description)
            }
            try container.encodeIfPresent(concept.tag, forKey: .tag)
            if !concept.citationIdentifiers.isEmpty {
                try container.encode(concept.citationIdentifiers, forKey: .citationIdentifiers)
            }
            if !concept.urls.isEmpty {
                try container.encode(concept.urls, forKey: .urls)
            }
        }
    }

    private nonisolated struct OutputConnection: Encodable {
        let connection: MapConnection
        init(_ connection: MapConnection) { self.connection = connection }

        enum CodingKeys: String, CodingKey { case from, to }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(connection.from, forKey: .from)
            try container.encode(connection.to, forKey: .to)
        }
    }

    private nonisolated struct OutputLayout: Encodable {
        let layout: Layout
        init(_ layout: Layout) { self.layout = layout }

        enum CodingKeys: String, CodingKey { case index, name, positions, id }

        struct OutputPosition: Encodable {
            let id: String
            let x: Double
            let y: Double
            let z: Double
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(layout.index, forKey: .index)
            try container.encode(layout.name, forKey: .name)
            try container.encode(layout.positions.map {
                OutputPosition(id: $0.id, x: $0.x, y: $0.y, z: $0.z)
            }, forKey: .positions)
            if let sourceID = layout.sourceID {
                try container.encode(sourceID, forKey: .id)
            }
        }
    }

    private nonisolated struct OutputParagraph: Encodable {
        let paragraph: Paragraph
        init(_ paragraph: Paragraph) { self.paragraph = paragraph }

        enum CodingKeys: String, CodingKey { case id, heading, text, speaker, tableID }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(paragraph.id, forKey: .id)
            try container.encodeIfPresent(paragraph.heading, forKey: .heading)
            try container.encode(paragraph.text, forKey: .text)
            try container.encodeIfPresent(paragraph.speaker, forKey: .speaker)
            try container.encodeIfPresent(paragraph.tableID, forKey: .tableID)
        }
    }

    private nonisolated struct OutputLink: Encodable {
        let link: Link
        init(_ link: Link) { self.link = link }

        enum CodingKeys: String, CodingKey { case to, fragment, rel, bibtex, span }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(link.to, forKey: .to)
            try container.encodeIfPresent(link.fragment, forKey: .fragment)
            try container.encodeIfPresent(link.rel, forKey: .rel)
            try container.encodeIfPresent(link.bibtex, forKey: .bibtex)
            try container.encodeIfPresent(link.span, forKey: .span)
        }
    }

    private nonisolated struct OutputWrapped: Encodable {
        let wrapped: Wrapped
        init(_ wrapped: Wrapped) { self.wrapped = wrapped }

        enum CodingKeys: String, CodingKey { case file, sha256, mediaType }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(wrapped.file, forKey: .file)
            try container.encode(wrapped.sha256, forKey: .sha256)
            try container.encodeIfPresent(wrapped.mediaType, forKey: .mediaType)
        }
    }
}

// Display-side markdown interpretation: documents whose text carries literal
// markdown ("# Heading", **bold**, …) render correctly even when the
// structured `heading` field wasn't set by the producer.
extension LiquidDoc.Paragraph {

    /// The structured heading level, or one implied by a markdown prefix.
    nonisolated var effectiveHeading: Int? {
        heading ?? LiquidDoc.markdownHeading(in: text)?.level
    }

    /// The text to display: a markdown heading prefix is stripped because
    /// the level is conveyed by `effectiveHeading` instead, and a speaker
    /// prefix is stripped because the name is conveyed by `speaker`.
    nonisolated var displayText: String {
        if heading == nil, let markdown = LiquidDoc.markdownHeading(in: text) {
            return markdown.text
        }
        if let speaker, text.hasPrefix("\(speaker):") {
            return String(text.dropFirst(speaker.count + 1)).trimmingCharacters(in: .whitespaces)
        }
        return text
    }

    /// Inline markdown rendered, plus live links: bare web URLs, and Origami
    /// paragraph links ("<uuid>#<paragraphID>" or origamitext://open/… URLs),
    /// which route back into the app via the `origamitext` scheme.
    nonisolated var renderedText: AttributedString {
        var attributed = (try? AttributedString(
            markdown: displayText,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(displayText)
        Self.addDetectedLinks(&attributed)
        return attributed
    }

    private nonisolated static func addDetectedLinks(_ attributed: inout AttributedString) {
        let plain = String(attributed.characters)
        let fullRange = NSRange(plain.startIndex..., in: plain)

        // Bare web URLs and similar, unless markdown already linked them.
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            for match in detector.matches(in: plain, options: [], range: fullRange) {
                guard let url = match.url,
                      let range = Range(match.range, in: attributed),
                      attributed[range].link == nil else { continue }
                attributed[range].link = url
            }
        }

        // Origami document addresses: [id#fragment] citations, origamitext://
        // URLs, and legacy bare UUIDs all become live origamitext:// links.
        for match in LiquidAddress.matches(in: plain) {
            guard let range = Range(match.range, in: attributed),
                  attributed[range].link == nil else { continue }
            var urlString = "origamitext://open/\(match.id)"
            if let fragment = match.fragment { urlString += "#\(fragment)" }
            if let url = URL(string: urlString) {
                attributed[range].link = url
            }
        }

        // Links read as body text with a quiet underline, not browser blue.
        let linkRanges = attributed.runs.compactMap { $0.link != nil ? $0.range : nil }
        for range in linkRanges {
            attributed[range].foregroundColor = .primary
            attributed[range].underlineStyle = .single
        }
    }
}

extension LiquidDoc {
    /// Ids of paragraphs belonging to the Visual-Meta appendix (from its
    /// heading onward), so the reader can render it unobtrusively.
    nonisolated var visualMetaParagraphIDs: Set<String> {
        guard let body,
              let start = body.firstIndex(where: {
                  $0.displayText.hasPrefix("Visual-Meta Appendix")
                      || $0.text.contains(VisualMeta.startMarker)
              })
        else { return [] }
        return Set(body[start...].map(\.id))
    }
}
// MARK: - Bot documents

/// A bot as an Origami document: the shelf lives in the community folder
/// itself, one `.origamitext` document per bot, self-describing and
/// readable by any Origami app — or person, or AI — that finds it. The
/// document records who the bot stands in for and its judgements, one
/// paragraph per judged document, each citing the document judged with a
/// discourse link (supports, disagrees-with, cites) — so the bot takes
/// its place in the document web, and syncs wherever the folder syncs.
nonisolated enum BotDocument {

    /// The `documentType` token; explained in the Visual-Meta field key.
    static let documentType = "bot"

    /// What a bot document declares about its bot. The document id is the
    /// bot's identity — one bot, one address.
    struct Identity: Sendable {
        let id: String
        let name: String
        let years: String
        let summary: String
        let created: Date
    }

    /// One judgement, as read from or written to a bot document.
    struct Judgement: Sendable {
        let docID: String
        let verdict: String   // agree | disagree | neutral
        let reason: String
    }

    /// Verdict spelling on the page, and the discourse rel its link
    /// carries — agreement supports, disagreement disagrees-with, and a
    /// neutral reading is still a citation.
    private static let verdicts: [(verdict: String, prefix: String, rel: String)] = [
        ("agree", "Would agree — ", "supports"),
        ("disagree", "Would disagree — ", "disagrees-with"),
        ("neutral", "Neutral — ", "cites"),
    ]

    /// The bot document's file name — the standard slug--id convention.
    static func fileName(title: String, id: String) -> String {
        let slug = LiquidDoc.fileSlug(from: title)
        let ext = LiquidDoc.fileExtension
        return slug.isEmpty ? "\(id).\(ext)" : "\(slug)--\(id).\(ext)"
    }

    /// Builds the bot's document, ready for the Visual-Meta appendix and
    /// serialization. Judgements are ordered by the judged document's id,
    /// so the same shelf state always writes the same document.
    static func build(identity: Identity, judgements: [Judgement], in folder: URL) -> LiquidDoc {
        var paragraphs: [LiquidDoc.Paragraph] = []
        var links: [LiquidDoc.Link] = []
        var counter = 0
        func add(_ text: String, heading: Int? = nil) {
            counter += 1
            paragraphs.append(LiquidDoc.Paragraph(id: "p\(counter)", heading: heading, text: text))
        }
        add(identity.years.isEmpty
            ? "An AI stand-in for \(identity.name)."
            : "An AI stand-in for \(identity.name) (\(identity.years)).")
        if !identity.summary.isEmpty {
            add(identity.summary)
        }
        add("This document is machine-written. It defines a bot — an AI stand-in bearing a well-known person's name, never mistaken for the person — and records the bot's judgements of this library's documents, one paragraph each, linking to the document judged. Every judgement is produced on-device from what is publicly known of the person's work and views; nothing here is the person's own words.")
        if !judgements.isEmpty {
            add("Judgements", heading: 2)
            for judgement in judgements.sorted(by: { $0.docID < $1.docID }) {
                guard let entry = verdicts.first(where: { $0.verdict == judgement.verdict })
                else { continue }
                add("\(entry.prefix)\(judgement.reason) [\(judgement.docID)]")
                links.append(LiquidDoc.Link(to: judgement.docID, fragment: nil, rel: entry.rel))
            }
        }
        let title = "\(identity.name) bot"
        return LiquidDoc(format: LiquidDoc.knownFormat,
                         id: identity.id,
                         title: title,
                         author: title,
                         created: identity.created,
                         body: paragraphs,
                         links: links,
                         wraps: nil,
                         documentType: documentType,
                         fileURL: folder.appendingPathComponent(fileName(title: title, id: identity.id)))
    }

    /// Reads a bot back from its document; nil when the document is not a
    /// bot document. Tolerant of hand edits: identity comes from the
    /// title and the stand-in line, judgements from their prefixes and
    /// the address each paragraph cites.
    static func parse(_ doc: LiquidDoc) -> (identity: Identity, judgements: [Judgement])? {
        guard doc.documentType == documentType else { return nil }
        let name = doc.title.hasSuffix(" bot") ? String(doc.title.dropLast(4)) : doc.title
        let appendixIDs = doc.visualMetaParagraphIDs
        var years = ""
        var summary = ""
        var judgements: [Judgement] = []
        for paragraph in (doc.body ?? []) where !appendixIDs.contains(paragraph.id) {
            let text = paragraph.displayText
            if let entry = verdicts.first(where: { text.hasPrefix($0.prefix) }) {
                guard let address = LiquidAddress.matches(in: text).last else { continue }
                var reason = String(text.dropFirst(entry.prefix.count))
                if let bracket = reason.range(of: " [", options: .backwards) {
                    reason = String(reason[..<bracket.lowerBound])
                }
                judgements.append(Judgement(docID: address.id, verdict: entry.verdict, reason: reason))
            } else if text.hasPrefix("An AI stand-in for ") {
                if let open = text.range(of: "("),
                   let close = text.range(of: ")", options: .backwards),
                   open.upperBound < close.lowerBound {
                    years = String(text[open.upperBound..<close.lowerBound])
                }
            } else if paragraph.heading == nil, summary.isEmpty, text != "---",
                      !text.hasPrefix("This document is machine-written") {
                summary = text
            }
        }
        let identity = Identity(id: doc.id, name: name, years: years,
                                summary: summary, created: doc.created)
        return (identity, judgements)
    }
}


// MARK: - The ACM two-column paper (acmart)

/// Writes a document as a LaTeX bundle for ACM's own `acmart` class, so
/// the two-column PDF is typeset by the class the publisher wrote rather
/// than approximated by us.
///
/// This is deliberately not a layout engine. Matching acmart by hand —
/// its column widths, its float placement, its reference format, the
/// copyright block on page one — is work without end, and the result
/// would always be nearly right. Emitting LaTeX makes the output exact
/// by construction, and it costs us a translator instead of a
/// typesetter.
///
/// The references are the reason this is cheap: every `LiquidDoc`
/// reference already carries its BibTeX verbatim, so `refs.bib` is
/// almost a copy and `ACM-Reference-Format.bst` does the formatting.
nonisolated enum ACMLaTeX {

    /// The bundle: everything needed to compile, with nothing outside it.
    struct Bundle: Sendable {
        /// `paper.tex`
        var latex: String
        /// `refs.bib` — empty when the document cites nothing.
        var bibtex: String
        /// Image bytes by the file name the LaTeX refers to.
        var images: [String: Data]
        /// How to compile it, for the README we leave beside it.
        static let recipe = """
        pdflatex paper && bibtex paper && pdflatex paper && pdflatex paper
        """

        /// A note left in the bundle, because the person who opens this
        /// folder in six months will not be the person who exported it.
        static func readme(for style: Style) -> String {
            """
            \(style.label) — \(style.columns)

            Generated by Origami Text from an Origami EPUB. This folder is
            everything needed to typeset the paper and nothing else:

              paper.tex    the paper, for ACM's acmart class
              refs.bib     the works it cites, as BibTeX
              images/      the figures, unmodified

            To compile:

              \(recipe)

            That needs a TeX installation with acmart — TeX Live or MacTeX
            will do, and both include it. The four passes are not
            superstition: the first finds the citations, bibtex resolves
            them, and the last two settle the cross-references and the
            page numbers they move.

            The bibliography is set by ACM's own ACM-Reference-Format
            style, so the references will look as the publisher intends
            without being edited here.

            Editing paper.tex by hand is fine, but it is generated: a
            later export will overwrite it. Anything worth keeping belongs
            in the document this came from.
            """
        }
    }

    /// The usual places a TeX installation puts its binaries. A GUI
    /// application rarely inherits a PATH that includes any of them.
    private static let texCandidates = [
        "/Library/TeX/texbin/pdflatex",
        "/usr/local/texlive/bin/pdflatex",
        "/opt/homebrew/bin/pdflatex",
        "/usr/bin/pdflatex"
    ]

    /// What can be said about TeX on this machine. The three cases read
    /// very differently to a person, and conflating them produces the
    /// worst possible message: telling someone to install TeX when they
    /// already have it.
    ///
    /// Inside the App Sandbox a TeX installation is visible but not
    /// readable — `fileExists` says yes and `isExecutableFile` says no —
    /// so the distinction is not hypothetical. It is the normal case for
    /// a distributed build.
    enum TeX: Sendable {
        /// Reachable and runnable: the PDF can be produced here.
        case runnable(String)
        /// Installed, but behind the sandbox. The bundle is the answer,
        /// with the command to run by hand.
        case unreachable
        /// Not installed at all.
        case absent
    }

    static var tex: TeX {
        let fm = FileManager.default
        if let runnable = texCandidates.first(where: { fm.isExecutableFile(atPath: $0) }) {
            return .runnable(runnable)
        }
        if texCandidates.contains(where: { fm.fileExists(atPath: $0) }) {
            return .unreachable
        }
        return .absent
    }

    /// Whether the PDF can be produced here, rather than whether TeX
    /// exists somewhere on the machine: TeX runnable directly, or
    /// installed and reachable through the compile helper.
    static var isTeXAvailable: Bool {
        switch tex {
        case .runnable: return true
        case .unreachable:
            #if os(macOS)
            return isHelperInstalled
            #else
            return false
            #endif
        case .absent: return false
        }
    }

    #if os(macOS)
    // MARK: The compile helper — TeX from inside the sandbox

    /// The sandbox's one sanctioned way out: a script in the app's
    /// Application Scripts folder runs *outside* the sandbox through
    /// NSUserUnixTask. The app may not put it there itself — the person
    /// places it once, through a save panel aimed at that folder — and
    /// from then on the PDF is made in the same step as the bundle.
    static let helperName = "compile-acm-paper.sh"

    static var scriptsDirectory: URL? {
        try? FileManager.default.url(for: .applicationScriptsDirectory,
                                     in: .userDomainMask,
                                     appropriateFor: nil, create: true)
    }

    static var isHelperInstalled: Bool {
        guard let dir = scriptsDirectory else { return false }
        return FileManager.default.fileExists(
            atPath: dir.appendingPathComponent(helperName).path)
    }

    /// Four passes, as `compile(in:)` runs them, with the usual TeX
    /// locations on PATH since a GUI app's PATH carries none of them.
    static let helperScript = """
    #!/bin/sh
    # Installed by Origami Text. Compiles an exported ACM LaTeX bundle
    # (paper.tex, refs.bib) into paper.pdf. Runs outside the app's
    # sandbox, which is why it lives here. Safe to delete; the app will
    # offer to install it again.
    cd "$1" || exit 1
    PATH="/Library/TeX/texbin:/usr/local/texlive/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
    export PATH
    pdflatex -interaction=nonstopmode paper >/dev/null 2>&1
    bibtex paper >/dev/null 2>&1
    pdflatex -interaction=nonstopmode paper >/dev/null 2>&1
    pdflatex -interaction=nonstopmode paper >/dev/null 2>&1
    test -f paper.pdf
    """

    /// Places the helper: a save panel opened on the Application Scripts
    /// folder, which is what grants the write. Returns whether it landed.
    @MainActor
    static func installHelper() -> Bool {
        guard let dir = scriptsDirectory else { return false }
        let panel = NSSavePanel()
        panel.directoryURL = dir
        panel.nameFieldStringValue = helperName
        panel.message = "Save the compile helper here, so Origami Text can "
            + "make the PDF with your TeX installation. Keep the folder and "
            + "name as they are."
        panel.prompt = "Save"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            try helperScript.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                  ofItemAtPath: url.path)
        } catch {
            return false
        }
        return isHelperInstalled
    }

    /// Runs the helper on a bundle folder; the PDF where it succeeded.
    static func compileWithHelper(in folder: URL) async -> URL? {
        guard let dir = scriptsDirectory,
              let task = try? NSUserUnixTask(
                url: dir.appendingPathComponent(helperName)) else { return nil }
        let ok: Bool = await withCheckedContinuation { continuation in
            task.execute(withArguments: [folder.path]) { error in
                continuation.resume(returning: error == nil)
            }
        }
        let pdf = folder.appendingPathComponent("paper.pdf")
        return ok && FileManager.default.fileExists(atPath: pdf.path) ? pdf : nil
    }

    /// The PDF by whichever route this machine allows.
    static func makePDF(in folder: URL) async -> URL? {
        if case .runnable = tex {
            return await Task.detached(priority: .userInitiated) {
                compile(in: folder)
            }.value
        }
        return await compileWithHelper(in: folder)
    }
    #endif

    /// Compiles a bundle in place, returning the PDF where TeX is
    /// reachable and nil where it is not.
    ///
    /// A sandboxed build cannot run a TeX installation it does not own,
    /// so this is a convenience rather than the deliverable: the bundle
    /// is what the export produces, and the README says how to build it
    /// by hand. The usual locations are searched because a TeX install
    /// is rarely on a GUI application's PATH.
    static func compile(in folder: URL) -> URL? {
        #if os(macOS)
        guard case .runnable(let latex) = tex else { return nil }
        let bin = (latex as NSString).deletingLastPathComponent
        let bibtex = "\(bin)/bibtex"

        func run(_ tool: String, _ arguments: [String]) -> Bool {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            process.currentDirectoryURL = folder
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return false }
            process.waitUntilExit()
            return true
        }

        // Four passes: find the citations, resolve them, then settle the
        // cross-references and the pages they moved.
        guard run(latex, ["-interaction=nonstopmode", "paper"]) else { return nil }
        _ = run(bibtex, ["paper"])
        _ = run(latex, ["-interaction=nonstopmode", "paper"])
        _ = run(latex, ["-interaction=nonstopmode", "paper"])

        let pdf = folder.appendingPathComponent("paper.pdf")
        return FileManager.default.fileExists(atPath: pdf.path) ? pdf : nil
        #else
        return nil
        #endif
    }

    static func bundle(for doc: LiquidDoc, style: Style = .sigconf,
                       rights: Rights? = nil, event: Conference? = nil) -> Bundle {
        var images: [String: Data] = [:]
        for asset in doc.assets {
            images[imageFileName(for: asset)] = asset.data
        }
        return Bundle(latex: latex(for: doc, style: style,
                                   rights: rights ?? Rights.stated(by: doc) ?? .ccBy,
                                   event: event),
                      bibtex: bibliography(for: doc),
                      images: images)
    }

    /// What may be done with the rendered paper — chosen in Origami Text
    /// when a paper is put into a publisher's format, because rights are
    /// the publisher's statement about an edition, not something the
    /// writing tool should decide. The cases are acmart's own
    /// `acmcopyrightmode` values that an author or small venue would
    /// plausibly pick; the government variants stay out of the chooser.
    enum Rights: String, Sendable, CaseIterable, Identifiable {
        case ccBy, ccBySA, ccByNC, ccByND, rightsRetained, acmLicensed, acmCopyright, none

        var id: String { rawValue }

        var label: String {
            switch self {
            case .ccBy: "Creative Commons Attribution 4.0 (CC BY)"
            case .ccBySA: "CC BY-SA 4.0 (share alike)"
            case .ccByNC: "CC BY-NC 4.0 (non-commercial)"
            case .ccByND: "CC BY-ND 4.0 (no derivatives)"
            case .rightsRetained: "Rights retained by the authors"
            case .acmLicensed: "Licensed to ACM (authors keep copyright)"
            case .acmCopyright: "Copyright transferred to ACM"
            case .none: "No rights statement"
            }
        }

        /// The value `\setcopyright` takes.
        var acmartMode: String {
            switch self {
            case .ccBy, .ccBySA, .ccByNC, .ccByND: "cc"
            case .rightsRetained: "rightsretained"
            case .acmLicensed: "acmlicensed"
            case .acmCopyright: "acmcopyright"
            case .none: "none"
            }
        }

        /// The `\setcctype` argument for the Creative Commons cases.
        var ccType: String? {
            switch self {
            case .ccBy: "by"
            case .ccBySA: "by-sa"
            case .ccByNC: "by-nc"
            case .ccByND: "by-nd"
            default: nil
            }
        }

        /// What the publication already says about itself, when it says
        /// anything recognisable — the chooser starts there, so a paper
        /// published under CC BY is rendered under CC BY unless someone
        /// deliberately changes it.
        static func stated(by doc: LiquidDoc) -> Rights? {
            let said = [doc.licenseURI, doc.license]
                .compactMap { $0?.lowercased() }
                .joined(separator: " ")
            guard !said.isEmpty else { return nil }
            if said.contains("by-nc") || said.contains("noncommercial") { return .ccByNC }
            if said.contains("by-nd") || said.contains("noderivatives") { return .ccByND }
            if said.contains("by-sa") || said.contains("sharealike") { return .ccBySA }
            if said.contains("creativecommons.org/licenses/by")
                || said.contains("creative commons attribution") { return .ccBy }
            if said.contains("licensed to acm") || said.contains("publication rights licensed") {
                return .acmLicensed
            }
            if said.contains("copyright held by the owner") || said.contains("rights retained") {
                return .rightsRetained
            }
            return nil
        }
    }

    /// acmart's own format names. All eleven that the class declares, so
    /// the list is the publisher's rather than ours — see the `format`
    /// choicekey in acmart.cls.
    ///
    /// Only `sigconf` is exercised end to end so far; the rest are
    /// declared because the class accepts them and a paper written once
    /// should be submittable anywhere. `supported` says which have been
    /// compiled and looked at, so the interface can be honest about the
    /// difference instead of offering eleven and meaning one.
    enum Style: String, Sendable, CaseIterable, Identifiable {
        case sigconf, sigplan, sigchi, siggraph, acmtog
        case acmsmall, acmlarge, manuscript
        case sigchiA = "sigchi-a"
        case acmengage, acmcp

        var id: String { rawValue }

        /// What a person choosing it would call it.
        var label: String {
            switch self {
            case .sigconf: "ACM conference proceedings"
            case .sigplan: "ACM SIGPLAN proceedings"
            case .sigchi: "ACM SIGCHI proceedings"
            case .siggraph: "ACM SIGGRAPH proceedings"
            case .acmtog: "ACM Transactions on Graphics"
            case .acmsmall: "ACM journal (small trim)"
            case .acmlarge: "ACM journal (large trim)"
            case .manuscript: "Manuscript, for submission and review"
            case .sigchiA: "SIGCHI extended abstract"
            case .acmengage: "ACM EngageCSEdu"
            case .acmcp: "ACM Computing Surveys article"
            }
        }

        /// Which formats acmart sets in two columns. Taken from the class
        /// itself: these are the ones whose `\@printtopmatter` emits the
        /// title block with `\twocolumn[...]`.
        var isTwoColumn: Bool {
            switch self {
            case .sigconf, .sigplan, .sigchi, .siggraph, .acmtog, .acmengage:
                true
            case .acmsmall, .acmlarge, .manuscript, .sigchiA, .acmcp:
                false
            }
        }

        var columns: String { isTwoColumn ? "two column" : "one column" }

        /// Verified by compiling and reading the result. The others are
        /// offered on the class's word rather than ours.
        var supported: Bool { self == .sigconf }

        /// A sentence for the chooser, so a person picks by what they are
        /// submitting to rather than by an acmart keyword.
        var note: String {
            switch self {
            case .sigconf: "The usual conference format — CHI, HT, CSCW and most others."
            case .sigplan: "PLDI, ICFP, OOPSLA and the other SIGPLAN venues."
            case .sigchi: "An older SIGCHI proceedings format; most CHI venues now use the conference format."
            case .siggraph: "SIGGRAPH and SIGGRAPH Asia proceedings."
            case .acmtog: "TOG, including the SIGGRAPH journal track."
            case .acmsmall: "Most ACM journals: TOCHI, TOIS, TODS and the like."
            case .acmlarge: "The larger journal trim, used by JACM among others."
            case .manuscript: "What a journal wants for review: one column, wide margins, line numbers available."
            case .sigchiA: "Extended abstracts, with a wide margin for notes and figures."
            case .acmengage: "The EngageCSEdu computing-education collection."
            case .acmcp: "Computing Surveys, whose articles carry a type — survey, review or tutorial."
            }
        }
    }

    // MARK: The document

    /// The ids of paragraphs that are notes rather than running text.
    /// The reader files endnotes into the body under a "Notes" heading,
    /// which is right for a screen and wrong for a printed page: on
    /// paper they become footnotes where they are referred to, so they
    /// must not also appear at the end.
    private static func noteIDs(in doc: LiquidDoc) -> Set<String> {
        var out: Set<String> = []
        var inNotes = false
        for paragraph in doc.body ?? [] {
            if let level = paragraph.heading {
                inNotes = level == 1 && paragraph.text
                    .trimmingCharacters(in: .whitespaces)
                    .caseInsensitiveCompare("Notes") == .orderedSame
                if inNotes { out.insert(paragraph.id) }
                continue
            }
            let bare = paragraph.id.components(separatedBy: "#").last ?? paragraph.id
            if inNotes || bare.hasPrefix("en-") || bare.hasPrefix("fn") {
                out.insert(paragraph.id)
            }
        }
        return out
    }

    static func latex(for source: LiquidDoc, style: Style = .sigconf,
                      rights: Rights = .ccBy, event: Conference? = nil) -> String {
        let doc = withFrontMatterFromBody(source)
        var out: [String] = [
            "% Generated by Origami Text from \(doc.title).",
            "% Compile: \(Bundle.recipe)",
            "\\documentclass[\(style.rawValue)]{acmart}",
            ""
        ]
        out.append(contentsOf: preamble(for: doc, rights: rights, event: event))
        out.append("\\begin{document}")
        out.append(contentsOf: frontMatter(for: doc))
        out.append("\\maketitle")
        out.append("")
        out.append(contentsOf: body(of: doc))
        if !doc.references.isEmpty {
            out.append("")
            out.append("\\bibliographystyle{ACM-Reference-Format}")
            out.append("\\bibliography{refs}")
        }
        out.append("")
        out.append("\\end{document}")
        return out.joined(separator: "\n") + "\n"
    }

    private static func preamble(for doc: LiquidDoc, rights: Rights,
                                 event given: Conference? = nil) -> [String] {
        var out: [String] = []
        // acmart loads hyperref, graphicx, booktabs and amsmath itself;
        // adding them again is how a template starts fighting its class.
        out.append("\\AtBeginDocument{%")
        out.append("  \\providecommand\\BibTeX{{Bib\\TeX}}}")
        out.append("")
        // A rule closing the title block, spanning the full text width so
        // it sits under *both* columns rather than inside one. acmart
        // builds the title, authors and teasers into \mktitle@bx and
        // emits it with \twocolumn[...], so the rule has to be appended
        // to that box before it is printed — patching \@maketitle does
        // nothing, because the class does not use it. This follows the
        // class's own idiom in \@mkteasers.
        let titleRule: [String] = [
            "\\makeatletter",
            "\\let\\origamiPrintTopMatter\\@printtopmatter",
            "\\renewcommand{\\@printtopmatter}{%",
            "  \\global\\setbox\\mktitle@bx=\\vbox{%",
            "    \\noindent\\unvbox\\mktitle@bx",
            "    \\par\\vspace{5pt}%",
            "    \\noindent\\rule{\\textwidth}{0.5pt}%",
            "    \\par}%",
            "  \\origamiPrintTopMatter}",
            "\\makeatother",
            ""
        ]
        out.append(contentsOf: titleRule)
        // The rights are the publisher's decision, made in Origami Text
        // at the moment of rendering (the Format sheet's Rights choice),
        // not written by the authoring tool. They drive \\setcopyright,
        // which is what puts the permission block on page one.
        out.append("\\setcopyright{\(rights.acmartMode)}")
        if let cc = rights.ccType {
            out.append("\\setcctype[4.0]{\(cc)}")
        }
        if rights != .none {
            out.append("\\copyrightyear{\(year(of: doc))}")
            out.append("\\acmYear{\(year(of: doc))}")
        }
        if let doi = doc.doi, !doi.isEmpty {
            out.append("\\acmDOI{\(escaped(doi))}")
        }
        if let isbn = doc.isbn ?? isbnFromLicence(doc), !isbn.isEmpty {
            out.append("\\acmISBN{\(escaped(isbn))}")
        }
        // An event stated in the export sheet wins; otherwise it is read
        // from the paper's own ACM Reference Format.
        if let event = given ?? conferenceFromReference(doc) {
            // The paper's own ACM Reference Format names the event in
            // full — "37th ACM Conference on Hypertext (HT ’26),
            // September 14–18, 2026, London, United Kingdom" — which is
            // exactly what acmart's four fields and its booktitle want.
            // Read from there, the running head, the rights block and
            // the reference line all match what ACM printed.
            out.append("\\acmConference[\(escaped(event.short))]{\(escaped(event.name))}"
                       + "{\(escaped(event.date))}{\(escaped(event.place))}")
            out.append("\\acmBooktitle{\(escaped(event.booktitle))}")
        } else if let venue = doc.publication, !venue.isEmpty {
            // acmart wants a short name, the full name, the date and the
            // place. We have the full name; the rest is left to the
            // class's defaults rather than invented.
            out.append("\\acmConference[\(escaped(shortVenue(venue)))]{\(escaped(venue))}{}{}")
        }
        out.append("")
        return out
    }

    private static func frontMatter(for doc: LiquidDoc) -> [String] {
        var out: [String] = ["\\title{\(inline(doc.title, in: doc))}"]
        if let subtitle = doc.subtitle, !subtitle.isEmpty {
            out.append("\\subtitle{\(inline(subtitle, in: doc))}")
        }
        out.append("")
        for author in authorLines(of: doc) {
            out.append(contentsOf: author)
            out.append("")
        }
        if let abstract = doc.abstract, !abstract.isEmpty {
            out.append("\\begin{abstract}")
            out.append(inline(abstract, in: doc))
            out.append("\\end{abstract}")
            out.append("")
        }
        for concept in doc.ccsConcepts where !concept.isEmpty {
            // acmart spells a concept path with a literal ~; the document
            // spells it with an arrow, which is what a person reads. Each
            // segment is escaped, the separator is not — escaping the
            // whole path would turn the separator into
            // \textasciitilde{} and acmart would see one long segment.
            let path = concept
                .replacingOccurrences(of: "•", with: "")
                .replacingOccurrences(of: "→", with: "\u{1}")
                .split(separator: "\u{1}")
                .map { escaped($0.trimmingCharacters(in: .whitespaces)) }
                .joined(separator: "~")
            guard !path.isEmpty else { continue }
            out.append("\\ccsdesc[500]{\(path)}")
        }
        if !doc.keywords.isEmpty {
            out.append("\\keywords{\(doc.keywords.map(escaped).joined(separator: ", "))}")
        }
        out.append("")
        return out
    }

    /// One `\author` block per person. Affiliation, email and ORCID come
    /// from the structured author list where the document has one, and
    /// from the legacy name-keyed dictionaries where it does not.
    private static func authorLines(of doc: LiquidDoc) -> [[String]] {
        let names = doc.authors.isEmpty
            ? doc.displayAuthor
                .components(separatedBy: CharacterSet(charactersIn: ","))
                .flatMap { $0.components(separatedBy: " and ") }
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            : doc.authors
        return names.map { name -> [String] in
            var block = ["\\author{\(escaped(name))}"]
            if let orcid = doc.authorORCIDs[name], !orcid.isEmpty {
                block.append("\\orcid{\(escaped(orcid))}")
            }
            // ACM's own proceedings print the email under the name,
            // above the affiliation.
            if let email = doc.authorEmails[name], !email.isEmpty {
                block.append("\\email{\(escaped(email))}")
            }
            let affiliation = doc.authorAffiliations[name]
                ?? (doc.authors.count == 1 ? doc.affiliations.first : nil)
            if let affiliation, !affiliation.isEmpty {
                block.append(contentsOf: affiliationLines(affiliation))
            }
            return block
        }
    }

    /// An affiliation line as acmart wants it. The class **requires** a
    /// country and errors without one, which is not a formality: it is
    /// how ACM builds the author index.
    ///
    /// Real affiliation lines are written "University of Southampton,
    /// Southampton, UK" — institution, city, country — so they are read
    /// from the end, which is the only part whose position is reliable.
    /// Where the line names no country the field is left empty on
    /// purpose, so acmart says so rather than us inventing a country the
    /// document never claimed.
    static func affiliationLines(_ affiliation: String) -> [String] {
        let parts = affiliation
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var institution = affiliation
        var city: String?
        var country: String?
        switch parts.count {
        case 0, 1:
            break
        case 2:
            institution = parts[0]
            country = parts[1]
        default:
            institution = parts[0..<(parts.count - 2)].joined(separator: ", ")
            city = parts[parts.count - 2]
            country = parts[parts.count - 1]
        }
        var out = ["\\affiliation{%", "  \\institution{\(escaped(institution))}"]
        if let city { out.append("  \\city{\(escaped(city))}") }
        out.append("  \\country{\(escaped(country ?? ""))}")
        out.append("}")
        return out
    }

    // MARK: The body

    private static func body(of doc: LiquidDoc) -> [String] {
        var out: [String] = []
        var listOpen: String?
        let notes = noteIDs(in: doc)

        func closeList() {
            if let listOpen { out.append("\\end{\(listOpen)}") }
            listOpen = nil
        }

        var acksOpen = false
        func closeAcks() {
            if acksOpen { out.append("\\end{acks}") }
            acksOpen = false
        }

        for paragraph in doc.body ?? [] {
            let text = paragraph.text.trimmingCharacters(in: .whitespacesAndNewlines)

            // The abstract, the CCS line, the keywords and the ACM
            // reference are front matter, and acmart sets them itself.
            // Left in the body they would print twice.
            if isFrontMatter(paragraph, in: doc) { continue }
            if notes.contains(paragraph.id) { continue }

            if let level = paragraph.heading {
                closeList()
                closeAcks()
                // A heading converted from a printed paper keeps its
                // printed number ("2.1 Background"); acmart numbers
                // sections itself, so the number would print twice.
                let title = text.replacingOccurrences(
                    of: #"^\d+(\.\d+)*\.?\s+"#, with: "", options: .regularExpression)
                // ACM sets acknowledgments unnumbered, in its own
                // environment, which also keeps them out of anonymised
                // review copies.
                if ["acknowledgments", "acknowledgements", "acknowledgment",
                    "acknowledgement"].contains(title.lowercased()) {
                    out.append("")
                    out.append("\\begin{acks}")
                    acksOpen = true
                    continue
                }
                let command = ["section", "section", "subsection", "subsubsection"][
                    min(max(level, 1), 3)]
                out.append("")
                out.append("\\\(command){\(inline(title, in: doc))}")
                out.append("\\label{\(label(for: paragraph.id))}")
                continue
            }

            if let identifier = paragraph.tableID,
               let table = doc.tables.first(where: { $0.identifier == identifier }) {
                closeList()
                out.append(contentsOf: tableLines(table, id: paragraph.id, in: doc))
                continue
            }

            if let figure = figureLines(paragraph, in: doc) {
                closeList()
                out.append(contentsOf: figure)
                continue
            }

            if let code = OrigamiReading.fencedCode(in: text) {
                closeList()
                out.append("\\begin{verbatim}")
                out.append(code)
                out.append("\\end{verbatim}")
                continue
            }

            // "• item" and "1. item" are the format's list conventions.
            if let (kind, item) = listItem(in: text) {
                if listOpen != kind {
                    closeList()
                    out.append("\\begin{\(kind)}")
                    listOpen = kind
                }
                out.append("  \\item \(inline(item, in: doc))")
                continue
            }
            closeList()

            guard !text.isEmpty else { continue }
            out.append("")
            out.append(inline(text, in: doc))
        }
        closeList()
        closeAcks()
        return out
    }

    /// Whether this paragraph is front matter acmart will set itself.
    private static func isFrontMatter(_ paragraph: LiquidDoc.Paragraph,
                                      in doc: LiquidDoc) -> Bool {
        let text = paragraph.text.trimmingCharacters(in: .whitespaces)
        // The abstract may be several paragraphs, gathered from the body.
        if let abstract = doc.abstract, !abstract.isEmpty, !text.isEmpty,
           paragraph.heading == nil, abstract.contains(text) { return true }
        if let reference = doc.acmReference, !reference.isEmpty,
           text.contains(reference.prefix(40)) { return true }
        for marker in ["CCS Concepts:", "**CCS Concepts:**", "Keywords:", "**Keywords:**"]
        where text.hasPrefix(marker) { return true }
        if paragraph.heading != nil,
           text.caseInsensitiveCompare("Abstract") == .orderedSame { return true }
        return false
    }

    private static func listItem(in text: String) -> (kind: String, item: String)? {
        if text.hasPrefix("• ") {
            return ("itemize", String(text.dropFirst(2)))
        }
        guard let match = text.range(of: #"^\d+\.\s"#, options: .regularExpression)
        else { return nil }
        return ("enumerate", String(text[match.upperBound...]))
    }

    private static func figureLines(_ paragraph: LiquidDoc.Paragraph,
                                    in doc: LiquidDoc) -> [String]? {
        // ![caption](asset:id) — the format's figure marker. A 3D model's
        // poster is what a printed page can show, so a model figure
        // prints its poster and says where the model is.
        guard let match = paragraph.text.range(
            of: #"!\[([^\]]*)\]\((asset|model):([^)?]+)"#, options: .regularExpression)
        else { return nil }
        let marker = String(paragraph.text[match])
        let caption = marker
            .components(separatedBy: "](").first?
            .replacingOccurrences(of: "![", with: "") ?? ""
        let reference = marker.components(separatedBy: ":").last ?? ""
        guard let asset = doc.assets.first(where: {
            $0.id == reference || imageFileName(for: $0).contains(reference)
        }) else { return nil }

        return ["",
                "\\begin{figure}[htbp]",
                "  \\centering",
                "  \\includegraphics[width=\\columnwidth]{images/\(imageFileName(for: asset))}",
                caption.isEmpty ? "" : "  \\caption{\(inline(caption, in: doc))}",
                "  \\Description{\(inline(caption.isEmpty ? "Figure" : caption, in: doc))}",
                "  \\label{\(label(for: paragraph.id))}",
                "\\end{figure}"].filter { !$0.isEmpty || $0 == "" }
    }

    private static func tableLines(_ table: LiquidDoc.Table, id: String,
                                   in doc: LiquidDoc) -> [String] {
        let columns = String(repeating: "l", count: max(table.columnCount, 1))
        var out = ["",
                   "\\begin{table}[htbp]",
                   "  \\centering",
                   "  \\begin{tabular}{\(columns)}",
                   "    \\toprule"]
        for (index, row) in table.cells.enumerated() {
            let cells = row.map { escaped($0.value) }.joined(separator: " & ")
            out.append("    \(cells) \\\\")
            if index == 0 { out.append("    \\midrule") }
        }
        out.append("    \\bottomrule")
        out.append("  \\end{tabular}")
        out.append("  \\label{\(label(for: id))}")
        out.append("\\end{table}")
        return out
    }

    // MARK: Inline

    /// The format's inline conventions as LaTeX. Citations become
    /// `\cite`, so the reference list is set by ACM's own style rather
    /// than by the text the document happens to carry.
    static func inline(_ text: String, in doc: LiquidDoc) -> String {
        var out = escaped(text)

        // [cite:key] → \cite{key}. The escaper has turned nothing in a
        // key into anything else, since keys are UUIDs or slugs.
        out = replacing(#"\[cite:([^\]]+)\]"#, in: out) { "\\cite{\($0[0])}" }
        // A typed address citation has no BibTeX key to cite, so it
        // prints as what the author wrote.
        out = replacing(#"\[cites:([^\]]+)\]"#, in: out) { _ in "" }
        // [note:id] → \footnote{…}, the note's own words inlined. A
        // printed page has no pop-up to open.
        out = replacing(#"\[i?note:([^\]]+)\]"#, in: out) { groups in
            let id = groups[0]
            let note = (doc.body ?? []).first {
                $0.id == id || $0.id.hasSuffix("#" + id) || $0.id.hasSuffix("-" + id)
            }
            guard let note else { return "" }
            // A reader's note begins with its own number and a link back
            // to where it was called ("[1.](origami-jump:p19) …"). On
            // paper the footnote mark is that link, so both go.
            let words = note.text
                .replacingOccurrences(of: #"^\s*\[\d+\.?\]\(origami-jump:[^)]*\)\s*"#,
                                      with: "", options: .regularExpression)
                .replacingOccurrences(of: #"^\s*\d+\.\s+"#, with: "",
                                      options: .regularExpression)
            return "\\footnote{\(inline(words, in: doc))}"
        }
        // [text](origami-jump:target) → a cross-reference where the
        // target is a labelled element, and the words alone otherwise.
        out = replacing(#"\[([^\]]*)\]\(origami-jump:([^)]+)\)"#, in: out) { groups in
            "\(groups[0])~\\ref{\(label(for: groups[1]))}"
        }
        out = replacing(#"\[([^\]]*)\]\((https?://[^)]+)\)"#, in: out) { groups in
            "\\href{\(groups[1])}{\(groups[0])}"
        }
        // The remaining markers are the emphasis conventions.
        out = replacing(#"\*\*([^*]+)\*\*"#, in: out) { "\\textbf{\($0[0])}" }
        out = replacing(#"(?<![\*\w])\*([^*]+)\*(?!\w)"#, in: out) { "\\emph{\($0[0])}" }
        out = replacing("`([^`]+)`", in: out) { "\\texttt{\($0[0])}" }
        return out
    }

    private static func replacing(_ pattern: String, in text: String,
                                  _ body: ([String]) -> String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
        var out = text
        let whole = out as NSString
        for match in expression.matches(
            in: out, range: NSRange(location: 0, length: whole.length)).reversed() {
            var groups: [String] = []
            for index in 1..<match.numberOfRanges where match.range(at: index).location != NSNotFound {
                groups.append(whole.substring(with: match.range(at: index)))
            }
            out = (out as NSString).replacingCharacters(in: match.range, with: body(groups))
        }
        return out
    }

    /// LaTeX's ten special characters. Missed escaping is the single
    /// most common way a generated document fails to compile, so this
    /// runs over every piece of text that is not already LaTeX.
    static func escaped(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "\\": out += "\\textbackslash{}"
            case "{": out += "\\{"
            case "}": out += "\\}"
            case "$": out += "\\$"
            case "&": out += "\\&"
            case "#": out += "\\#"
            case "^": out += "\\textasciicircum{}"
            case "_": out += "\\_"
            case "~": out += "\\textasciitilde{}"
            case "%": out += "\\%"
            default: out.append(character)
            }
        }
        return out
    }

    // MARK: The bibliography

    /// Every cited work as BibTeX. The document already carries each
    /// record verbatim, so this is a copy with the keys made safe for
    /// LaTeX rather than a reformatting.
    static func bibliography(for doc: LiquidDoc) -> String {
        doc.references
            .map { reference in
                var record = reference.bibtex.trimmingCharacters(in: .whitespacesAndNewlines)
                if record.isEmpty {
                    record = "@misc{\(reference.id),\n  title = {\(reference.citedAs ?? reference.id)}\n}"
                }
                return record
            }
            .joined(separator: "\n\n") + "\n"
    }

    // MARK: Odds and ends

    private static func imageFileName(for asset: LiquidDoc.Asset) -> String {
        let safe = asset.id.replacingOccurrences(
            of: "[^A-Za-z0-9._-]", with: "-", options: .regularExpression)
        return safe.contains(".") ? safe : "\(safe).png"
    }

    /// A LaTeX label from an element address: `\label` and `\ref` accept
    /// far less than an address contains.
    static func label(for id: String) -> String {
        "ot:" + id.replacingOccurrences(
            of: "[^A-Za-z0-9]", with: "-", options: .regularExpression)
    }

    private static func year(of doc: LiquidDoc) -> String {
        Calendar.current.component(.year, from: doc.listedDate).description
    }

    private static func shortVenue(_ venue: String) -> String {
        // "37th ACM Conference on Hypertext and Social Media" → "HT". A
        // venue that states its own short name in brackets keeps it.
        if let open = venue.firstIndex(of: "("), let close = venue.firstIndex(of: ")"),
           open < close {
            return String(venue[venue.index(after: open)..<close])
        }
        let words = venue.split(separator: " ").filter { $0.first?.isUppercase == true }
        return words.count >= 2 ? words.prefix(2).joined(separator: " ") : venue
    }

    /// A paper converted from a printed proceedings carries its abstract,
    /// CCS concepts and keywords as body paragraphs — an "Abstract"
    /// heading, then "**CCS Concepts:** …" and "**Keywords:** …" — rather
    /// than as metadata. acmart sets all three itself, so where the
    /// metadata is empty they are read from the body; `isFrontMatter`
    /// then keeps them from printing twice.
    static func withFrontMatterFromBody(_ source: LiquidDoc) -> LiquidDoc {
        var doc = source
        let body = doc.body ?? []
        func strip(_ text: String, _ marker: String) -> String? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            for form in ["**\(marker):**", "\(marker):"] where trimmed.hasPrefix(form) {
                return String(trimmed.dropFirst(form.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return nil
        }
        func isMarker(_ text: String) -> Bool {
            ["CCS Concepts", "Keywords", "ACM Reference Format"].contains { strip(text, $0) != nil }
        }
        if doc.abstract?.isEmpty ?? true,
           let start = body.firstIndex(where: {
               $0.heading != nil
                   && $0.text.trimmingCharacters(in: .whitespaces)
                       .caseInsensitiveCompare("Abstract") == .orderedSame }) {
            let run = body[(start + 1)...]
                .prefix { $0.heading == nil && !isMarker($0.text) }
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !run.isEmpty { doc.abstract = run.joined(separator: "\n\n") }
        }
        if doc.ccsConcepts.isEmpty,
           let line = body.lazy.compactMap({ strip($0.text, "CCS Concepts") }).first {
            // "• Root → Leaf; • Root2 → Leaf2; Leaf3." — a leaf without
            // its own root belongs to the root before it.
            var root: String?
            var paths: [String] = []
            for raw in line.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
                .components(separatedBy: ";") {
                let item = raw.replacingOccurrences(of: "•", with: "")
                    .trimmingCharacters(in: .whitespaces)
                guard !item.isEmpty else { continue }
                if let arrow = item.range(of: "→") {
                    root = item[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
                    paths.append(item)
                } else if let root {
                    paths.append("\(root) → \(item)")
                } else {
                    paths.append(item)
                }
            }
            doc.ccsConcepts = paths
        }
        if doc.keywords.isEmpty,
           let line = body.lazy.compactMap({ strip($0.text, "Keywords") }).first {
            doc.keywords = line.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
                .components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        return doc
    }

    /// The event as the paper's own ACM Reference Format names it:
    /// "… In 37th ACM Conference on Hypertext (HT ’26), September 14–18,
    /// 2026, London, United Kingdom. ACM, New York, NY, USA, …".
    struct Conference: Sendable, Equatable {
        let name, short, date, place, booktitle: String

        /// An event entered by hand. The booktitle is built the way ACM
        /// prints it: "Name (SHORT), Dates, Place".
        init(name: String, short: String, date: String, place: String,
             booktitle: String? = nil) {
            self.name = name
            self.short = short
            self.date = date
            self.place = place
            self.booktitle = booktitle ?? {
                var out = name
                if !short.isEmpty { out += " (\(short))" }
                for part in [date, place] where !part.isEmpty { out += ", " + part }
                return out
            }()
        }
    }

    static func conferenceFromReference(_ doc: LiquidDoc) -> Conference? {
        guard let reference = doc.acmReference,
              let inRange = reference.range(of: ". In "),
              let end = reference.range(of: ". ACM, ", range: inRange.upperBound..<reference.endIndex)
        else { return nil }
        let booktitle = String(reference[inRange.upperBound..<end.lowerBound])
        // "Name (SHORT), Month d–d, yyyy, Place"
        guard let open = booktitle.range(of: " ("),
              let close = booktitle.range(of: ")", range: open.upperBound..<booktitle.endIndex)
        else { return nil }
        let name = String(booktitle[..<open.lowerBound])
        let short = String(booktitle[open.upperBound..<close.lowerBound])
        let rest = booktitle[close.upperBound...]
            .trimmingCharacters(in: CharacterSet(charactersIn: ", "))
        // The date runs to the four-digit year; the place is what follows.
        guard let year = rest.range(of: #"\b(19|20)\d\d\b"#, options: .regularExpression)
        else { return Conference(name: name, short: short, date: "", place: rest,
                                 booktitle: booktitle) }
        let date = String(rest[..<year.upperBound])
        let place = rest[year.upperBound...]
            .trimmingCharacters(in: CharacterSet(charactersIn: ", "))
        return Conference(name: name, short: short, date: date, place: place,
                          booktitle: booktitle)
    }

    /// "ACM ISBN 979-8-4007-2564-7/26/09" in the paper's licence block.
    static func isbnFromLicence(_ doc: LiquidDoc) -> String? {
        guard let licence = doc.license,
              let match = licence.range(of: #"ISBN\s+([0-9Xx\-/]+)"#, options: .regularExpression)
        else { return nil }
        return licence[match].replacingOccurrences(of: #"ISBN\s+"#, with: "",
                                                   options: .regularExpression)
    }

    private static func creativeCommonsCode(for uri: String) -> String? {
        guard uri.contains("creativecommons.org") else { return nil }
        if uri.contains("/by/") { return "CC BY" }
        if uri.contains("/by-sa/") { return "CC BY-SA" }
        if uri.contains("/by-nc/") { return "CC BY-NC" }
        if uri.contains("/by-nc-sa/") { return "CC BY-NC-SA" }
        if uri.contains("/zero/") { return "CC0" }
        return "Creative Commons"
    }
}
