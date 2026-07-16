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

        enum CodingKeys: String, CodingKey { case format, id, title, author, created, date, body, links, wraps, attention, aiOnBehalf, onBehalfOf, documentType }

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
        }
    }

    private nonisolated struct OutputParagraph: Encodable {
        let paragraph: Paragraph
        init(_ paragraph: Paragraph) { self.paragraph = paragraph }

        enum CodingKeys: String, CodingKey { case id, heading, text, speaker }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(paragraph.id, forKey: .id)
            try container.encodeIfPresent(paragraph.heading, forKey: .heading)
            try container.encode(paragraph.text, forKey: .text)
            try container.encodeIfPresent(paragraph.speaker, forKey: .speaker)
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
