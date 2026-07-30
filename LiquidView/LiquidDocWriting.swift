import Foundation
import SwiftUI

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

        enum CodingKeys: String, CodingKey { case format, id, title, author, created, date, body, links, wraps, attention, aiOnBehalf, onBehalfOf, documentType, location, concepts, layouts, connections, references, tables, assets }

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

