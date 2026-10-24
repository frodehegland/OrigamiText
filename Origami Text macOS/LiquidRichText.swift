import AppKit
import CryptoKit

/// The bridge between the two shapes a draft has: Author's attributed
/// string (what the editor edits and the `.liquid` package stores) and
/// the Origami document (`LiquidDoc`, what the library, the reader, the
/// EPUB export and the Visual-Meta publish consume). Both directions,
/// so a document reads into the editor and the editor's text becomes a
/// document again on every save.
///
/// The correspondence:
///
/// | Author attributed text                    | Origami paragraph                  |
/// |-------------------------------------------|------------------------------------|
/// | style `header1`–`3` (`4`–`6` read as 3)   | `heading` 1–3                      |
/// | style `bulletList` / `dashList`           | text opening "• " / "- "           |
/// | consecutive style `code` paragraphs       | one fenced ``` block               |
/// | bold / italic font traits                 | `**` / `*` markers                 |
/// | `.link`                                   | `[text](url)`                      |
/// | image attachment (+ caption paragraph)    | `Asset` + `![caption](asset:id)`   |
/// | `TableAttachment`                         | `Table` + paragraph with `tableID` |
/// | citation run (`LACitationIdentifier…`)    | `[cite:id]` + `Reference`          |
enum LiquidRichText {

    // MARK: - Document → attributed text

    /// The document's body as Author-shaped attributed text. Citations
    /// the body tokens name are looked up in `citations` (the package's
    /// store) and, failing that, made from the document's references;
    /// every one used is left in `citations`.
    static func attributedString(from doc: LiquidDoc,
                                 citations: inout [String: AuthorCitation]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let paragraphs = doc.body ?? []
        let assetsByID = Dictionary(doc.assets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let tablesByID = Dictionary(doc.tables.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })

        var pieces: [NSAttributedString] = []
        for paragraph in paragraphs {
            let text = paragraph.text
            if let reference = LiquidDoc.imageReference(in: text) {
                if let asset = assetsByID[reference.id], let data = asset.data {
                    pieces.append(attachmentParagraph(
                        imageAttachment(data: data, filename: asset.filename)))
                    let caption = reference.alt.trimmingCharacters(in: .whitespaces)
                    if !caption.isEmpty {
                        pieces.append(inlineAttributed(caption, style: .attachmentDetails,
                                                       citations: &citations, references: doc.references))
                    }
                } else {
                    pieces.append(inlineAttributed(text, style: .body, citations: &citations,
                                                   references: doc.references))
                }
                continue
            }
            if let tableID = paragraph.tableID, let table = tablesByID[tableID] {
                pieces.append(attachmentParagraph(TableAttachment(table: table.laTable())))
                continue
            }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                // A fenced block: its lines, each a code paragraph.
                var lines = trimmed.components(separatedBy: "\n")
                lines.removeFirst()
                if lines.last?.trimmingCharacters(in: .whitespaces) == "```" { lines.removeLast() }
                if lines.isEmpty { lines = [""] }
                for line in lines {
                    pieces.append(NSAttributedString(string: line, attributes: AuthorStyle.code.attributes))
                }
                continue
            }
            if let heading = paragraph.heading {
                pieces.append(inlineAttributed(trimmed, style: .heading(heading),
                                               citations: &citations, references: doc.references))
                continue
            }
            if let (style, rest) = listItem(in: trimmed) {
                pieces.append(listParagraph(style: style, text: rest,
                                            citations: &citations, references: doc.references))
                continue
            }
            pieces.append(inlineAttributed(text, style: .body, citations: &citations,
                                           references: doc.references))
        }
        for (index, piece) in pieces.enumerated() {
            result.append(piece)
            if index < pieces.count - 1 {
                // The paragraph break wears the paragraph's own attributes.
                let attributes = piece.length > 0
                    ? piece.attributes(at: piece.length - 1, effectiveRange: nil)
                    : AuthorStyle.body.attributes
                result.append(NSAttributedString(string: "\n", attributes: attributes))
            }
        }
        return result
    }

    /// A list line's kind and words, when the text opens like one.
    private static func listItem(in text: String) -> (AuthorStyle, String)? {
        for (marker, style) in [("• ", AuthorStyle.bulletList), ("* ", .bulletList),
                                ("- ", AuthorStyle.dashList), ("– ", .dashList)] {
            if text.hasPrefix(marker) {
                return (style, String(text.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    /// A list item as Author writes it: the stub, marked as such, then
    /// the words; the list style on every run.
    static func listParagraph(style: AuthorStyle, text: String,
                              citations: inout [String: AuthorCitation],
                              references: [LiquidDoc.Reference]) -> NSAttributedString {
        let item = NSMutableAttributedString(attributedString: listStub(for: style))
        item.append(inlineAttributed(text, style: style, citations: &citations, references: references))
        item.addAttribute(AuthorAttributes.styleSecondaryIdentifier, value: style.rawValue,
                          range: NSRange(location: 0, length: item.length))
        return item
    }

    /// The "• " or "- " a list item opens with.
    static func listStub(for style: AuthorStyle) -> NSAttributedString {
        var attributes = style.attributes
        attributes[AuthorAttributes.structureIdentifiers] = AuthorAttributes.listStubValue
        return NSAttributedString(string: style.listStub ?? "• ", attributes: attributes)
    }

    /// One attachment standing alone in its paragraph, centred.
    static func attachmentParagraph(_ attachment: NSTextAttachment) -> NSAttributedString {
        let piece = NSMutableAttributedString(attachment: attachment)
        piece.addAttributes(AuthorStyle.attachment.attributes, range: NSRange(location: 0, length: 1))
        return piece
    }

    /// A picture as the editor holds it: bytes in the file wrapper (what
    /// the archive and the RTFD save), the image decoded for drawing,
    /// drawn to fit the column.
    static func imageAttachment(data: Data, filename: String) -> NSTextAttachment {
        let wrapper = FileWrapper(regularFileWithContents: data)
        wrapper.preferredFilename = filename
        let attachment = NSTextAttachment(fileWrapper: wrapper)
        if let image = NSImage(data: data) {
            attachment.image = image
            attachment.attachmentCell = ScaledImageAttachmentCell(imageCell: image)
        }
        return attachment
    }

    // MARK: Inline markdown → attributes

    private static let citeTokenPattern = try! NSRegularExpression(pattern: #"\[cite:([^\]]+)\]"#)
    private static let linkPattern = try! NSRegularExpression(pattern: #"\[([^\]]+)\]\(([a-zA-Z][a-zA-Z0-9+.-]*:[^)\s]+)\)"#)
    /// Both markdown spellings, 1–3 markers hugging the words.
    private static let emphasisPatterns: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"(?<!\*)(\*{1,3})(?![\s*])(.+?)(?<!\s)\1(?!\*)"#),
        try! NSRegularExpression(pattern: #"(?<![\w_])(_{1,3})(?![\s_])(.+?)(?<!\s)\1(?![\w_])"#),
    ]

    /// One paragraph's words with their inline markdown rendered as
    /// attributes: `[cite:id]` tokens become citation runs, `[t](url)`
    /// links, `**` and `*` emphasis. Library addresses (`[f.hegla.…]`)
    /// stay as written — the Origami convention, text in either app.
    static func inlineAttributed(_ text: String, style: AuthorStyle,
                                 citations: inout [String: AuthorCitation],
                                 references: [LiquidDoc.Reference]) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: style.attributes)

        // Citations first: the tokens carry no markdown of their own.
        let tokenMatches = citeTokenPattern.matches(in: result.string,
                                                    range: NSRange(location: 0, length: result.length))
        for match in tokenMatches.reversed() {
            let id = (result.string as NSString).substring(with: match.range(at: 1))
            let citation = citations[id]
                ?? references.first { $0.id == id }.flatMap { AuthorCitation(bibtexString: $0.bibtex, identifier: id) }
                ?? AuthorCitation(identifier: id)
            citations[id] = citation
            result.replaceCharacters(in: match.range,
                                     with: citationRun(citation, format: .nameAndDate, base: style.attributes))
        }

        let linkMatches = linkPattern.matches(in: result.string, range: NSRange(location: 0, length: result.length))
        for match in linkMatches.reversed() {
            let label = (result.string as NSString).substring(with: match.range(at: 1))
            let target = (result.string as NSString).substring(with: match.range(at: 2))
            guard let url = URL(string: target) else { continue }
            var attributes = result.attributes(at: match.range.location, effectiveRange: nil)
            attributes[.link] = url
            result.replaceCharacters(in: match.range, with: NSAttributedString(string: label, attributes: attributes))
        }

        for pattern in emphasisPatterns {
            let matches = pattern.matches(in: result.string, range: NSRange(location: 0, length: result.length))
            for match in matches.reversed() {
                let marker = match.range(at: 1)
                let content = match.range(at: 2)
                let bold = marker.length >= 2
                let italic = marker.length == 1 || marker.length == 3
                let words = NSMutableAttributedString(attributedString: result.attributedSubstring(from: content))
                words.enumerateAttribute(.font, in: NSRange(location: 0, length: words.length)) { value, range, _ in
                    let font = (value as? NSFont) ?? style.font
                    words.addAttribute(.font, value: font.withTraits(bold: bold ? true : nil,
                                                                     italic: italic ? true : nil), range: range)
                }
                result.replaceCharacters(in: match.range, with: words)
            }
        }
        return result
    }

    /// A citation as Author lays one out: an opening run carrying the
    /// start marker, the cited words (if any), a closing run carrying the
    /// end marker with the "Name Year" label; every run tagged with the
    /// record's identifier and the format.
    static func citationRun(_ citation: AuthorCitation, format: AuthorCitationFormat,
                            content: NSAttributedString? = nil,
                            base: [NSAttributedString.Key: Any]) -> NSAttributedString {
        var common = base
        common[AuthorAttributes.citationIdentifier] = citation.identifier
        common[AuthorAttributes.citationFormat] = format.rawValue
        var opening = common
        opening[AuthorAttributes.citationStartMarker] = AuthorAttributes.citationStartMarkerValue
        var closing = common
        closing[AuthorAttributes.citationEndMarker] = AuthorAttributes.citationEndMarkerValue

        let label = citation.attributionLabel
        let run = NSMutableAttributedString()
        switch format {
        case .quotesWithNameAndYear:
            run.append(NSAttributedString(string: "“", attributes: opening))
            if let content {
                let words = NSMutableAttributedString(attributedString: content)
                words.addAttributes(common, range: NSRange(location: 0, length: words.length))
                run.append(words)
            }
            run.append(NSAttributedString(string: "” (\(label))", attributes: closing))
        case .textWithNameAndYear:
            if let content {
                let words = NSMutableAttributedString(attributedString: content)
                words.addAttributes(common, range: NSRange(location: 0, length: words.length))
                run.append(words)
            }
            run.append(NSAttributedString(string: " (\(label))", attributes: closing))
        default:
            run.append(NSAttributedString(string: "(", attributes: opening))
            run.append(NSAttributedString(string: "\(label))", attributes: closing))
        }
        return run
    }

    // MARK: - Attributed text → document

    struct Extracted {
        var body: [LiquidDoc.Paragraph] = []
        var tables: [LiquidDoc.Table] = []
        var assets: [LiquidDoc.Asset] = []
        /// Citation identifiers in order of first appearance.
        var citedIDs: [String] = []
    }

    /// The document pieces the text holds: paragraphs with heading
    /// levels, list and code conventions and inline markdown; tables;
    /// image assets; the citations placed.
    static func extract(from text: NSAttributedString) -> Extracted {
        var extracted = Extracted()
        let string = text.string as NSString
        var location = 0
        var pendingCode: [String] = []
        var assetIDs: Set<String> = []
        var lastImageAssetIndex: Int?

        func flushCode() {
            guard !pendingCode.isEmpty else { return }
            append("```\n" + pendingCode.joined(separator: "\n") + "\n```", heading: nil)
            pendingCode = []
        }
        func append(_ paragraphText: String, heading: Int?, tableID: String? = nil) {
            var paragraph = LiquidDoc.Paragraph(id: "p\(extracted.body.count + 1)",
                                                heading: heading, text: paragraphText)
            paragraph.tableID = tableID
            extracted.body.append(paragraph)
        }

        while location < string.length {
            let paragraphRange = string.paragraphRange(for: NSRange(location: location, length: 0))
            defer { location = NSMaxRange(paragraphRange) }
            var content = paragraphRange
            // Trailing paragraph separator, if any.
            if content.length > 0 {
                let last = string.character(at: NSMaxRange(content) - 1)
                if last == 0x0A || last == 0x0D || last == 0x2029 { content.length -= 1 }
            }
            guard content.length > 0 else { continue }
            let attributes = text.attributes(at: content.location, effectiveRange: nil)
            let style = AuthorStyle.from(identifier: attributes[AuthorAttributes.styleIdentifier] as? String)

            // An attachment paragraph: a table or a picture.
            if let attachmentInfo = firstAttachment(in: content, of: text) {
                flushCode()
                lastImageAssetIndex = nil
                if let table = attachmentInfo.attachment as? TableAttachment {
                    table.updateFileWrapper()
                    extracted.tables.append(LiquidDoc.Table(table.table))
                    append(table.pipeText, heading: nil, tableID: table.table.identifier)
                } else if let asset = asset(for: attachmentInfo.attachment, taken: &assetIDs) {
                    extracted.assets.append(asset)
                    append("![](asset:\(asset.id))", heading: nil)
                    lastImageAssetIndex = extracted.body.count - 1
                }
                continue
            }

            // A caption right under a picture rides as its alt text.
            let isCaption = style == .attachmentDetails
                || (attributes[AuthorAttributes.citationFormat] as? String) == AuthorCitationFormat.attachment.rawValue
            if isCaption, let imageIndex = lastImageAssetIndex, imageIndex == extracted.body.count - 1 {
                let caption = string.substring(with: content).trimmingCharacters(in: .whitespaces)
                if !caption.isEmpty, let assetIndex = extracted.assets.indices.last {
                    extracted.assets[assetIndex].alt = caption
                    extracted.body[imageIndex].text = "![\(caption)](asset:\(extracted.assets[assetIndex].id))"
                }
                lastImageAssetIndex = nil
                continue
            }
            lastImageAssetIndex = nil

            if style == .code {
                pendingCode.append(string.substring(with: content))
                continue
            }
            flushCode()

            var inlineRange = content
            if style.isList {
                // The stub is structure, not words.
                inlineRange = rangeAfterListStub(in: content, of: text)
            }
            var words = inlineMarkdown(in: inlineRange, of: text, baseFont: style.font,
                                       citedIDs: &extracted.citedIDs)
                .trimmingCharacters(in: .whitespaces)
            if words.isEmpty, !style.isList { continue }
            if let stub = style.listStub { words = stub + words }
            append(words, heading: style.headingLevel)
        }
        flushCode()
        return extracted
    }

    private static func firstAttachment(in range: NSRange, of text: NSAttributedString)
        -> (attachment: NSTextAttachment, range: NSRange)? {
        var found: (NSTextAttachment, NSRange)?
        text.enumerateAttribute(.attachment, in: range) { value, attachmentRange, stop in
            if let attachment = value as? NSTextAttachment {
                found = (attachment, attachmentRange)
                stop.pointee = true
            }
        }
        return found
    }

    /// The words of a list item: past the stub Author marks, else past a
    /// leading bullet or dash.
    private static func rangeAfterListStub(in content: NSRange, of text: NSAttributedString) -> NSRange {
        var stubEnd = content.location
        text.enumerateAttribute(AuthorAttributes.structureIdentifiers, in: content) { value, range, stop in
            if (value as? String) == AuthorAttributes.listStubValue, range.location == stubEnd {
                stubEnd = NSMaxRange(range)
            } else {
                stop.pointee = true
            }
        }
        if stubEnd == content.location {
            let string = text.string as NSString
            var cursor = content.location
            while cursor < NSMaxRange(content) {
                let character = string.character(at: cursor)
                if character == 0x09 || character == 0x20 || character == 0x2022 /* • */
                    || character == 0x2D || character == 0x2013 || character == 0x2A {
                    cursor += 1
                } else { break }
            }
            stubEnd = cursor
        }
        return NSRange(location: stubEnd, length: NSMaxRange(content) - stubEnd)
    }

    /// An image attachment as a document asset: bytes from the wrapper
    /// (else the image's TIFF), a stable id from the bytes themselves so
    /// the same picture keeps the same id save after save.
    private static func asset(for attachment: NSTextAttachment, taken: inout Set<String>) -> LiquidDoc.Asset? {
        var data = attachment.fileWrapper?.regularFileContents
        var filename = attachment.fileWrapper?.preferredFilename ?? attachment.fileWrapper?.filename ?? ""
        if data == nil, let tiff = attachment.image?.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            data = png
            filename = "image.png"
        }
        guard let data, !data.isEmpty else { return nil }
        var ext = (filename as NSString).pathExtension.lowercased()
        if ext.isEmpty || ext == "tiff" || ext == "tif" {
            ext = data.starts(with: [0xFF, 0xD8]) ? "jpeg" : "png"
        }
        let digest = SHA256.hash(data: data).prefix(4).map { String(format: "%02x", $0) }.joined()
        var id = "img-\(digest)"
        var suffix = 1
        while taken.contains(id) {
            suffix += 1
            id = "img-\(digest)-\(suffix)"
        }
        taken.insert(id)
        return LiquidDoc.Asset(id: id, filename: "\(id).\(ext)",
                               mediaType: WordImporter.mediaType(forExtension: ext),
                               dataBase64: data.base64EncodedString(), alt: nil)
    }

    // MARK: Attributes → inline markdown

    private enum Segment {
        case words(text: String, bold: Bool, italic: Bool, link: String?)
        case citation(id: String, format: AuthorCitationFormat, prefix: String, content: String, suffix: String)
    }

    /// One paragraph's runs as markdown: emphasis markers around bold
    /// and italic words (beyond what the paragraph's own face already
    /// is — a heading's bold is the heading, not emphasis), `[text](url)`
    /// for links, each citation as its `[cite:id]` token (the cited
    /// words kept, the "(Name Year)" label given way — the number
    /// stands in for it at export).
    static func inlineMarkdown(in range: NSRange, of text: NSAttributedString,
                               baseFont: NSFont, citedIDs: inout [String]) -> String {
        let string = text.string as NSString
        var segments: [Segment] = []
        func traits(_ font: NSFont?) -> (bold: Bool, italic: Bool) {
            guard let font else { return (false, false) }
            return (font.isBold && !baseFont.isBold, font.isItalic && !baseFont.isItalic)
        }
        text.enumerateAttributes(in: range) { attributes, runRange, _ in
            let runText = string.substring(with: runRange).replacingOccurrences(of: "\u{FFFC}", with: "")
            if let id = attributes[AuthorAttributes.citationIdentifier] as? String {
                let format = AuthorCitationFormat(rawValue: attributes[AuthorAttributes.citationFormat] as? String ?? "")
                    ?? .nameAndDate
                let isPrefix = attributes[AuthorAttributes.citationStartMarker] != nil
                let isSuffix = attributes[AuthorAttributes.citationEndMarker] != nil
                let emphasis = traits(attributes[.font] as? NSFont)
                let marked = emphasised(runText, bold: emphasis.bold, italic: emphasis.italic)
                if case .citation(let lastID, let lastFormat, var prefix, var content, var suffix) = segments.last,
                   lastID == id {
                    if isPrefix { prefix += runText } else if isSuffix { suffix += runText } else { content += marked }
                    segments[segments.count - 1] = .citation(id: id, format: lastFormat, prefix: prefix,
                                                             content: content, suffix: suffix)
                } else {
                    segments.append(.citation(id: id, format: format,
                                              prefix: isPrefix ? runText : "",
                                              content: (isPrefix || isSuffix) ? "" : marked,
                                              suffix: isSuffix ? runText : ""))
                }
                return
            }
            let (bold, italic) = traits(attributes[.font] as? NSFont)
            let link = (attributes[.link] as? URL)?.absoluteString ?? (attributes[.link] as? String)
            if case .words(let lastText, let lastBold, let lastItalic, let lastLink) = segments.last,
               lastBold == bold, lastItalic == italic, lastLink == link {
                segments[segments.count - 1] = .words(text: lastText + runText, bold: bold, italic: italic, link: link)
            } else {
                segments.append(.words(text: runText, bold: bold, italic: italic, link: link))
            }
        }

        var result = ""
        for segment in segments {
            switch segment {
            case .words(let words, let bold, let italic, let link):
                if let link, !words.trimmingCharacters(in: .whitespaces).isEmpty {
                    let core = words.trimmingCharacters(in: .whitespaces)
                    let leading = words.prefix(while: { $0 == " " })
                    let trailing = words.reversed().prefix(while: { $0 == " " })
                    result += "\(leading)[\(core)](\(link))\(String(trailing))"
                } else {
                    result += emphasised(words, bold: bold, italic: italic)
                }
            case .citation(let id, let format, let prefix, let content, let suffix):
                if format == .attachment { continue }
                if !citedIDs.contains(id) { citedIDs.append(id) }
                let token = "[cite:\(id)]"
                let words = content.trimmingCharacters(in: .whitespaces)
                if words.isEmpty {
                    // All label — the token takes the citation's place.
                    if !result.isEmpty, !result.hasSuffix(" "), !result.hasSuffix("\n") { result += " " }
                    result += token
                } else {
                    let openQuote = prefix.contains("“") ? "“" : ""
                    let closeQuote = suffix.hasPrefix("”") ? "”" : ""
                    result += "\(openQuote)\(words)\(closeQuote) \(token)"
                }
            }
        }
        return result
    }

    /// Words wrapped in markdown emphasis, the markers hugging the words.
    private static func emphasised(_ words: String, bold: Bool, italic: Bool) -> String {
        let core = words.trimmingCharacters(in: .whitespaces)
        guard !core.isEmpty, bold || italic else { return words }
        let marker = bold && italic ? "***" : bold ? "**" : "*"
        let leading = words.prefix(while: { $0 == " " })
        let trailing = words.reversed().prefix(while: { $0 == " " })
        return "\(leading)\(marker)\(core)\(marker)\(String(trailing))"
    }

    // MARK: - Package ⇄ document

    /// The Origami fields that have no home in Author's package, as one
    /// JSON document kept under `Author.plist["origami"]`: everything but
    /// the body, tables, assets and references, which the text and the
    /// citation store carry.
    static func origamiRecord(for doc: LiquidDoc) -> String? {
        var record = doc.replacingBody([])
        record.tables = []
        record.assets = []
        record.references = []
        // Concepts live in Author's glossary.json, not here.
        record.concepts = []
        guard let data = try? record.jsonData() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// The document a package holds: its Origami record (when it has one)
    /// with the body, tables, assets and references read from the text
    /// and the citation store. A package without a record — one made in
    /// Author — gets an identity from its name and dates.
    static func document(from package: LiquidPackage, fileURL: URL,
                         fallbackAuthor: String) -> LiquidDoc {
        let extracted = extract(from: package.text)
        let citationsByID = Dictionary(package.citations.map { ($0.identifier, $0) },
                                       uniquingKeysWith: { first, _ in first })
        let base: LiquidDoc? = package.origamiJSON
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? LiquidDoc.decode(data: $0, fileURL: fileURL) }

        var references: [LiquidDoc.Reference] = []
        for id in extracted.citedIDs {
            if let citation = citationsByID[id] {
                references.append(citation.reference)
            } else if let kept = base?.references.first(where: { $0.id == id }) {
                references.append(kept)
            }
        }
        for reference in base?.references ?? [] where citationsByID[reference.id] == nil
            && !references.contains(where: { $0.id == reference.id }) {
            references.append(reference)
        }

        var doc: LiquidDoc
        if let base {
            doc = base.replacingBody(extracted.body, title: package.title)
        } else {
            let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
            let created = (attributes?[.creationDate] as? Date) ?? Date()
            let author = (package.authorPlist["Author"] as? String)
                ?? (package.authorPlist["author"] as? String) ?? fallbackAuthor
            let id = fileURL.deletingPathExtension().lastPathComponent
            doc = LiquidDoc(format: LiquidDoc.knownFormat,
                            id: LiquidAddress.isValid(id) ? LiquidAddress.canonical(id)
                                : LiquidAddress.makeID(author: author, created: created),
                            title: package.title, author: author, created: created,
                            body: extracted.body, links: [], wraps: nil, fileURL: fileURL)
        }
        doc.tables = extracted.tables
        doc.assets = extracted.assets
        doc.references = references
        // The Defined Concepts: Author's glossary is the record of them —
        // what Author wrote there, and what Origami wrote there for Author.
        let fromGlossary = concepts(fromGlossaryEntries: package.glossaryEntries)
        if !fromGlossary.isEmpty || !package.glossaryEntries.isEmpty {
            doc.concepts = fromGlossary
        }
        // The export's front matter — abstract, keywords, authors'
        // details, venue, DOI — as the package states it.
        package.exportSettings.apply(to: &doc)
        return doc
    }

    // MARK: - Author's glossary ⇄ concepts

    /// The document's Defined Concepts from Author's `glossary.json`
    /// entries: every entry that is a concept (Author's headings,
    /// citations and other machinery are not), with the phrase's first
    /// name as the name and the rest as the forms the text marks.
    static func concepts(fromGlossaryEntries entries: [String: Any]) -> [LiquidDoc.Concept] {
        guard !entries.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: ["entries": entries]),
              let drafts = AuthorGlossaryReader.drafts(fromGlossaryData: data, documentName: "") else { return [] }
        return drafts.filter(\.isPublishable).map { draft in
            let entry = entries[draft.sourceID ?? ""] as? [String: Any]
            let phrase = (entry?["phrase"] as? String) ?? draft.term
            var concept = LiquidDoc.Concept(id: draft.sourceID ?? UUID().uuidString, name: draft.term)
            concept.description = draft.definition
            concept.userDefinition = draft.definition.isEmpty ? nil : draft.definition
            concept.tag = draft.tags.first
            concept.citationIdentifiers = draft.citationIDs
            concept.urls = draft.urls
            concept.markedForms = AuthorGlossaryReader.alternatives(inPhrase: phrase)
            return concept
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Author's glossary entries with the document's concepts written in,
    /// in Author's `GlossaryEntry` shape: each concept an entry under its
    /// id (an entry already there keeps whatever else it holds — its Map
    /// position, its flags); entries that are not concepts (Author's
    /// sections and the like) stay as they are. A concept the document
    /// no longer carries is removed only when it was a concept entry.
    static func glossaryEntries(updating existing: [String: Any],
                                with concepts: [LiquidDoc.Concept], date: Date) -> [String: Any] {
        var entries = existing
        let kept = Set(concepts.map(\.id))
        for (key, value) in existing {
            guard let entry = value as? [String: Any] else { continue }
            let tag = ((entry["tag"] as? String) ?? "").lowercased()
            let isMachinery = ConceptDraft.unpublishedTags.contains(tag)
            if !isMachinery, !kept.contains(key) { entries.removeValue(forKey: key) }
        }
        for concept in concepts {
            var entry = (existing[concept.id] as? [String: Any]) ?? [:]
            entry["identifier"] = concept.id
            let names = [concept.name] + concept.markedForms.filter {
                ConceptTerm.normalise($0) != ConceptTerm.normalise(concept.name)
            }
            entry["phrase"] = names.joined(separator: ", ")
            entry["description"] = concept.userDefinition?.isEmpty == false ? concept.userDefinition! : concept.description
            entry["tag"] = concept.tag ?? "concept"
            entry["urls"] = concept.urls.map { ["url": $0] }
            entry["citationIdentifiers"] = concept.citationIdentifiers
            if entry["date"] == nil { entry["date"] = date.timeIntervalSinceReferenceDate }
            if entry["isLiked"] == nil { entry["isLiked"] = false }
            if entry["isContext"] == nil { entry["isContext"] = false }
            if entry["isHidden"] == nil { entry["isHidden"] = false }
            entries[concept.id] = entry
        }
        return entries
    }

    /// A package for a document: its body as attributed text, its
    /// references in the citation store, its fields in the record — the
    /// shape a draft takes on disk when it was made from a document
    /// (an import, a lift, a transcript) rather than typed.
    static func package(for doc: LiquidDoc, preserving existing: LiquidPackage? = nil) -> LiquidPackage {
        var citations: [String: AuthorCitation] = [:]
        for citation in existing?.citations ?? [] { citations[citation.identifier] = citation }
        for reference in doc.references where citations[reference.id] == nil {
            if let citation = AuthorCitation(bibtexString: reference.bibtex, identifier: reference.id) {
                citations[reference.id] = citation
            }
        }
        let text = attributedString(from: doc, citations: &citations)
        var package = existing ?? LiquidPackage(text: text, title: doc.title)
        package.text = text
        package.title = doc.title
        package.citations = citations.values.sorted { $0.identifier < $1.identifier }
        package.glossaryEntries = glossaryEntries(updating: package.glossaryEntries, with: doc.concepts,
                                                  date: doc.listedDate)
        package.origamiJSON = origamiRecord(for: doc)
        return package
    }

    // MARK: - After reading

    /// Text as read from an archive, made the editor's: every run's font
    /// becomes this app's face for its style (traits kept), paragraph
    /// styles and colours follow, a plain attachment holding table JSON
    /// becomes a `TableAttachment`, pictures get their drawing cell.
    static func normalizedForEditing(_ text: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        let string = result.string as NSString
        let full = NSRange(location: 0, length: result.length)

        result.enumerateAttribute(.attachment, in: full) { value, range, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            if attachment is TableAttachment { return }
            if let wrapper = attachment.fileWrapper, let table = TableAttachment.table(from: wrapper) {
                result.addAttribute(.attachment, value: TableAttachment(table: table), range: range)
                return
            }
            if attachment.image == nil, let data = attachment.fileWrapper?.regularFileContents,
               let image = NSImage(data: data) {
                attachment.image = image
            }
            if let image = attachment.image {
                attachment.attachmentCell = ScaledImageAttachmentCell(imageCell: image)
            }
        }

        var location = 0
        while location < string.length {
            let paragraphRange = string.paragraphRange(for: NSRange(location: location, length: 0))
            defer { location = NSMaxRange(paragraphRange) }
            guard paragraphRange.length > 0 else { continue }
            let attributes = result.attributes(at: paragraphRange.location, effectiveRange: nil)
            var style = AuthorStyle.from(identifier: attributes[AuthorAttributes.styleIdentifier] as? String)
            if attributes[.attachment] != nil { style = .attachment }
            let wanted = style.attributes
            result.enumerateAttribute(.font, in: paragraphRange) { value, range, _ in
                let existing = value as? NSFont
                result.addAttribute(.font, value: style.font.withTraits(bold: existing?.isBold ?? false,
                                                                        italic: existing?.isItalic ?? false),
                                    range: range)
            }
            result.addAttributes([
                .paragraphStyle: wanted[.paragraphStyle] as Any,
                .foregroundColor: NSColor.labelColor,
                AuthorAttributes.styleIdentifier: style.rawValue,
            ], range: paragraphRange)
            result.removeAttribute(.backgroundColor, range: paragraphRange)
        }
        return result
    }
}
