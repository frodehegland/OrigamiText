import AppKit
import Compression

/// Imports Word documents (.docx, .doc) as drafts. AppKit reads the file
/// into rich text; headings are recovered from the paragraph outline level
/// when Word's heading styles survive, otherwise from font size relative to
/// the body text. Bold and italic runs become inline markdown, list items
/// become dashed lines, and a leading level-1 heading becomes the document
/// title. Inline images are recovered from the .docx zip (Apple's OOXML
/// reader drops them) and carried as document assets, referenced from the
/// body by `![alt](asset:<id>)` markers.
nonisolated enum WordImporter {

    struct ImportResult: Sendable {
        let title: String
        let author: String?
        let body: [LiquidDoc.Paragraph]
        var assets: [LiquidDoc.Asset] = []
        /// The works cited through a reference manager (Zotero,
        /// Mendeley), as cite-keyed BibTeX — the body carries matching
        /// `[cite:key]` tokens.
        var references: [LiquidDoc.Reference] = []
        /// Import diagnostics worth telling the user, warnings first.
        var notices: [String] = []
    }

    static func importFile(at url: URL) throws -> ImportResult {
        var documentAttributes: NSDictionary?
        let base = try NSAttributedString(url: url,
                                          options: [:],
                                          documentAttributes: &documentAttributes)
        // Recover inline images: the system OOXML reader keeps the text but
        // silently drops images, so read them from the .docx zip directly
        // and splice them back in as attachments on their own lines.
        let rich = NSMutableAttributedString(attributedString: base)
        let docxData: Data? = url.pathExtension.lowercased() == "docx" ? try? Data(contentsOf: url) : nil
        if let docxData {
            WordImageRecovery.insertImages(from: docxData, into: rich)
        }

        // The body point size — the most common size weighted by character
        // count — is the baseline against which headings are judged.
        var sizeWeights: [Int: Int] = [:]
        rich.enumerateAttribute(.font, in: NSRange(location: 0, length: rich.length)) { value, range, _ in
            guard let font = value as? NSFont else { return }
            sizeWeights[Int(font.pointSize.rounded()), default: 0] += range.length
        }
        let bodySize = sizeWeights.max { $0.value < $1.value }?.key ?? 12

        var blocks: [(heading: Int?, text: String)] = []
        var assets: [LiquidDoc.Asset] = []
        var assetCounter = 0
        let nsString = rich.string as NSString
        nsString.enumerateSubstrings(in: NSRange(location: 0, length: nsString.length),
                                     options: .byParagraphs) { _, range, _, _ in
            // Images in this paragraph, in order, recovered as assets.
            var paragraphImages: [String] = []   // asset ids
            rich.enumerateAttribute(.attachment, in: range) { value, _, _ in
                guard let attachment = value as? NSTextAttachment,
                      let data = attachment.fileWrapper?.regularFileContents,
                      !data.isEmpty else { return }
                assetCounter += 1
                let id = "img\(assetCounter)"
                let ext = fileExtension(of: attachment.fileWrapper?.preferredFilename, data: data)
                let filename = "\(id).\(ext)"
                assets.append(LiquidDoc.Asset(
                    id: id, filename: filename, mediaType: mediaType(forExtension: ext),
                    dataBase64: data.base64EncodedString(), alt: nil))
                paragraphImages.append(id)
            }

            let substring = nsString.substring(with: range)
            let attributes = rich.attributes(at: range.location, effectiveRange: nil)
            let style = attributes[.paragraphStyle] as? NSParagraphStyle
            let heading = headingLevel(for: range, attributes: attributes,
                                       bodySize: bodySize, in: rich)
            var text = heading == nil
                ? markdownText(for: range, in: rich)
                : plainText(for: range, in: rich)
            if let style, !style.textLists.isEmpty {
                text = "- " + strippingListMarker(text)
            }
            // The paragraph's words first (if any), then each image on its
            // own line, so the marker paragraphs export as <figure>.
            if !text.isEmpty, !(text == "-" && paragraphImages.isEmpty) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { blocks.append((heading, text)) }
            }
            _ = substring
            for id in paragraphImages {
                blocks.append((nil, "![](asset:\(id))"))
            }
        }

        // Pages exports hyperlinks as Word HYPERLINK fields, which AppKit's
        // .docx reader silently drops (only relationship-based links survive,
        // which is why a Word paste worked but a Pages one did not). Recover
        // our citation links straight from the OOXML and splice the address in
        // as `[address]`, exactly as the relationship links already are.
        if let docxData {
            let citations = WordFieldLinks.hyperlinkFields(inDocx: docxData)
                .compactMap { field -> (text: String, address: String)? in
                    guard let address = origamiAddress(fromURL: field.url) else { return nil }
                    return (field.text, address)
                }
            if !citations.isEmpty { blocks = injectingAddresses(citations, into: blocks) }
        }

        // Reference-manager citations: the CSL metadata harvested from
        // the field instructions becomes the references, the visible
        // "(Author, Year)" texts become [cite:key] tokens, and the
        // flattened bibliography (regenerated from the map) is dropped.
        var references: [LiquidDoc.Reference] = []
        var notices: [String] = []
        if let docxData {
            let harvest = WordCitationFields.harvest(fromDocx: docxData)
            references = harvest.references
            notices = harvest.notices
            if harvest.foundCitationFields {
                let applied = applyingCitations(harvest, to: blocks)
                blocks = applied.blocks
                if applied.unmatched > 0 {
                    notices.append("""
                        \(applied.unmatched) citation\(applied.unmatched == 1 ? "" : "s") \
                        could not be located in the text; the references were still imported.
                        """)
                }
            } else if WordCitationFields.looksFlattened(
                blocks.map(\.text).joined(separator: "\n")) {
                notices.insert("""
                    This document appears to contain citations, but the \
                    reference-manager data has been removed (unlinked). \
                    Citations import as plain text.
                    """, at: 0)
            }
        }

        // Word's Title property, else a leading level-1 heading, else the
        // filename — same order of preference as the Markdown importer.
        let metaTitle = (documentAttributes?[NSAttributedString.DocumentAttributeKey.title] as? String)?
            .trimmingCharacters(in: .whitespaces)
        var title = metaTitle?.isEmpty == false
            ? metaTitle!
            : url.deletingPathExtension().lastPathComponent
        if let first = blocks.first, first.heading == 1,
           metaTitle?.isEmpty != false || first.text == title {
            title = first.text
            blocks.removeFirst()
        }
        let author = (documentAttributes?[NSAttributedString.DocumentAttributeKey.author] as? String)?
            .trimmingCharacters(in: .whitespaces)

        var paragraphs: [LiquidDoc.Paragraph] = []
        for block in blocks {
            paragraphs.append(LiquidDoc.Paragraph(id: "p\(paragraphs.count + 1)",
                                                  heading: block.heading,
                                                  text: block.text))
        }
        return ImportResult(title: title,
                            author: author?.isEmpty == false ? author : nil,
                            body: paragraphs,
                            assets: assets,
                            references: references,
                            notices: notices)
    }

    /// Applies the harvest to the body: the flattened bibliography's
    /// lines drop, and each citation's visible text — consumed in
    /// document order, so repeats resolve one by one — becomes its
    /// `[cite:key]` tokens.
    private static func applyingCitations(_ harvest: WordCitationFields.Harvest,
                                          to blocks: [(heading: Int?, text: String)])
        -> (blocks: [(heading: Int?, text: String)], unmatched: Int) {
        var blocks = blocks
        if !harvest.bibliographyLines.isEmpty {
            func normalized(_ text: String) -> String {
                text.replacingOccurrences(of: "\u{00A0}", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let dropped = Set(harvest.bibliographyLines.map(normalized))
            blocks.removeAll { !dropped.isEmpty && dropped.contains(normalized($0.text)) }
        }
        var cursorBlock = 0
        var cursorLocation = 0
        var unmatched = 0
        for (display, replacement) in harvest.replacements {
            let target = sanitize(display).trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty else { continue }
            var found = false
            var index = cursorBlock
            while index < blocks.count {
                let text = blocks[index].text
                let from = index == cursorBlock
                    ? text.index(text.startIndex,
                                 offsetBy: min(cursorLocation, text.count))
                    : text.startIndex
                if let range = text.range(of: target, range: from..<text.endIndex) {
                    let location = text.distance(from: text.startIndex, to: range.lowerBound)
                    blocks[index].text.replaceSubrange(range, with: replacement)
                    cursorBlock = index
                    cursorLocation = location + replacement.count
                    found = true
                    break
                }
                index += 1
            }
            if !found {
                // Out-of-order fallback (a footnote's citation, an
                // unexpected walk): search the whole body once, without
                // moving the cursor.
                if let hit = blocks.indices.first(where: { blocks[$0].text.contains(target) }),
                   let range = blocks[hit].text.range(of: target) {
                    blocks[hit].text.replaceSubrange(range, with: replacement)
                } else {
                    unmatched += 1
                }
            }
        }
        return (blocks, unmatched)
    }

    /// Word heading styles usually arrive as an outline level; when they
    /// don't, a short paragraph notably larger than the body text is taken
    /// as a heading, ranked by how much larger.
    private static func headingLevel(for range: NSRange,
                                     attributes: [NSAttributedString.Key: Any],
                                     bodySize: Int,
                                     in rich: NSAttributedString) -> Int? {
        if let style = attributes[.paragraphStyle] as? NSParagraphStyle, style.headerLevel > 0 {
            return min(style.headerLevel, 3)
        }
        guard range.length <= 120, let font = attributes[.font] as? NSFont else { return nil }
        let size = Int(font.pointSize.rounded())
        guard size >= bodySize + 2 else { return nil }
        if size >= bodySize + 8 { return 1 }
        if size >= bodySize + 4 { return 2 }
        return 3
    }

    /// The paragraph's text with bold and italic runs wrapped in markdown
    /// markers. Runs are coalesced by trait first so a bold phrase split
    /// across several font runs gets one pair of markers.
    private static func markdownText(for range: NSRange, in rich: NSAttributedString) -> String {
        var pieces: [(text: String, bold: Bool, italic: Bool, link: String?)] = []
        rich.enumerateAttributes(in: range) { attributes, runRange, _ in
            let traits = (attributes[.font] as? NSFont)?.fontDescriptor.symbolicTraits ?? []
            let text = (rich.string as NSString).substring(with: runRange)
            let bold = traits.contains(.bold)
            let italic = traits.contains(.italic)
            let link = (attributes[.link] as? URL)?.absoluteString
                ?? (attributes[.link] as? String)
            if let last = pieces.last, last.bold == bold, last.italic == italic, last.link == link {
                pieces[pieces.count - 1].text += text
            } else {
                pieces.append((text, bold, italic, link))
            }
        }
        var result = ""
        for piece in pieces {
            let cleaned = sanitize(piece.text)
            let core = cleaned.trimmingCharacters(in: .whitespaces)
            guard !core.isEmpty else {
                result += cleaned
                continue
            }
            // A hyperlink: an Origami address comes back as a bracketed
            // citation (so it becomes a live cites link), any other URL as a
            // markdown link. This recovers "Copy as Quote" links pasted into
            // Word and saved back out.
            if let link = piece.link {
                if let address = origamiAddress(fromURL: link) {
                    result += "\(core) [\(address)]"
                } else {
                    result += "[\(core)](\(link))"
                }
                continue
            }
            let marker = piece.bold && piece.italic ? "***" : piece.bold ? "**" : piece.italic ? "*" : ""
            // Markers hug the words; surrounding whitespace stays outside.
            let leading = cleaned.prefix(while: { $0 == " " || $0 == "\t" })
            let trailing = cleaned.reversed().prefix(while: { $0 == " " || $0 == "\t" }).reversed()
            result += "\(leading)\(marker)\(core)\(marker)\(String(trailing))"
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The Origami address inside a citation hyperlink — either the in-app
    /// `origamitext://open/…` or the https identity carrier a Word/Pages paste
    /// leaves behind. Returns `to` plus any `#fragment`, with the `?q=` quote
    /// payload stripped (the body citation is just the address). Nil when the
    /// URL is not one of ours.
    private static func origamiAddress(fromURL url: String) -> String? {
        guard let link = CitationClipboard.parse(href: url) else { return nil }
        return link.to + (link.fragment.map { "#\($0)" } ?? "")
    }

    /// Splices `[address]` after the display text of each recovered field
    /// hyperlink, so the draft editor makes it a `cites` link — the same shape
    /// the relationship-based links already produce. Each link is applied to
    /// the first block that still carries its bare display text.
    private static func injectingAddresses(_ citations: [(text: String, address: String)],
                                           into blocks: [(heading: Int?, text: String)]) -> [(heading: Int?, text: String)] {
        var blocks = blocks
        for citation in citations {
            let display = citation.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !display.isEmpty else { continue }
            for index in blocks.indices {
                guard let range = blocks[index].text.range(of: display) else { continue }
                // Don't double up if an address already trails this occurrence.
                if blocks[index].text[range.upperBound...].hasPrefix(" [") { continue }
                blocks[index].text.replaceSubrange(range, with: "\(display) [\(citation.address)]")
                break
            }
        }
        return blocks
    }

    private static func plainText(for range: NSRange, in rich: NSAttributedString) -> String {
        sanitize((rich.string as NSString).substring(with: range))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Drops attachment placeholders (embedded images and the like) and
    /// normalizes the whitespace Word likes to leave behind.
    private static func sanitize(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{FFFC}", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    /// Cocoa's list import keeps the literal marker ("\t•\t1." etc.) in the
    /// text; remove it since the dash prefix carries the meaning.
    private static func strippingListMarker(_ text: String) -> String {
        var result = Substring(text).drop(while: { $0 == " " || $0 == "\t" })
        while let first = result.first, "•◦▪‣·–-".contains(first) {
            result = result.dropFirst().drop(while: { $0 == " " || $0 == "\t" })
        }
        if let dot = result.firstIndex(where: { $0 == "." || $0 == ")" }),
           result.startIndex < dot,
           result[result.startIndex..<dot].allSatisfy(\.isNumber) {
            result = result[result.index(after: dot)...].drop(while: { $0 == " " || $0 == "\t" })
        }
        return String(result)
    }

    // MARK: - Image media types

    /// The file extension for a recovered image: the attachment's own, or
    /// sniffed from the bytes' magic number, defaulting to png.
    private static func fileExtension(of preferredName: String?, data: Data) -> String {
        if let preferredName {
            let ext = (preferredName as NSString).pathExtension.lowercased()
            if !ext.isEmpty { return ext }
        }
        let bytes = [UInt8](data.prefix(4))
        if bytes.count >= 3, bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF { return "jpeg" }
        if bytes.count >= 4, bytes[0] == 0x89, bytes[1] == 0x50, bytes[2] == 0x4E, bytes[3] == 0x47 { return "png" }
        if bytes.count >= 3, bytes[0] == 0x47, bytes[1] == 0x49, bytes[2] == 0x46 { return "gif" }
        return "png"
    }

    /// The image media type by extension — now LiquidDoc's
    /// (LiquidDoc.swift, shared with the visionOS target); kept here as
    /// a passthrough for the importers that call through WordImporter.
    static func mediaType(forExtension ext: String) -> String {
        LiquidDoc.mediaType(forExtension: ext)
    }
}

// MARK: - ACM-template papers: the proceedings path

/// A paper written in the ACM Word template (Titledocument, Authors,
/// Affiliation, Abstract, Head1/Head2, FigureCaption, TableCaption,
/// Bibentry… styles), imported to the same paper shape the LaTeX
/// pipeline produces — so the odd proceedings paper that ships only as
/// .docx (ht26-3) exports through the same EPUB path as its TAPS-built
/// siblings. The template's named styles carry the structure the draft
/// importer must guess at, so this path reads the OOXML directly and
/// never goes through AppKit's lossy rich-text reader.
///
/// A TAPS-produced HTML rendering of the same paper, when given,
/// contributes what the .docx cannot carry faithfully: the paper's own
/// DOI, the verbatim ACM Reference Format block, the license block,
/// author ORCIDs, print-corrected author names, TeX for the OLE
/// equation objects (whose WMF previews no Apple platform renders),
/// and reference venues/links. Everything structural still comes from
/// the .docx; the HTML only fills print-side gaps.
nonisolated enum ACMWordPaper {

    struct Result: Sendable {
        var title: String = ""
        /// Print order, print-corrected names when the HTML knows better.
        var authors: [String] = []
        var publication: String?
        var body: [LiquidDoc.Paragraph] = []
        var references: [LiquidDoc.Reference] = []
        var tables: [LiquidDoc.Table] = []
        var assets: [LiquidDoc.Asset] = []
        var doi: String?
        var affiliations: [String] = []
        var acmReference: String?
        var authorORCIDs: [String: String] = [:]
        var authorEmails: [String: String] = [:]
        /// Each author's affiliation line, keyed by name — grouped
        /// under the name in the exported front matter.
        var authorAffiliations: [String: String] = [:]
        var license: String?
        var notices: [String] = []
    }

    enum ImportError: LocalizedError {
        case unreadable
        var errorDescription: String? { "The .docx could not be read." }
    }

    /// True when the .docx declares the ACM template's title style —
    /// the routing test between the paper path and the draft path.
    static func isPaper(at url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "docx",
              let data = try? Data(contentsOf: url),
              let zip = DocxZip(data: data),
              let document = zip.read("word/document.xml"),
              let xml = String(data: document, encoding: .utf8) else { return false }
        return xml.contains("w:val=\"Titledocument\"")
    }

    // MARK: The import

    static func importPaper(at url: URL, tapsHTML htmlURL: URL? = nil) throws -> Result {
        guard let data = try? Data(contentsOf: url),
              let archive = DocxZip(data: data),
              let documentXML = archive.read("word/document.xml") else {
            throw ImportError.unreadable
        }
        let items = DocxScanner.scan(documentXML)
        let footnotes = footnoteTexts(archive: archive)
        let mediaByRID = mediaRelationships(archive: archive)
        let taps = htmlURL.flatMap { TAPSHTML(url: $0) }

        var result = Result()
        var body: [LiquidDoc.Paragraph] = []
        var assets: [LiquidDoc.Asset] = []
        var tables: [LiquidDoc.Table] = []
        var paragraphCounter = 0
        func nextID() -> String { paragraphCounter += 1; return "p\(paragraphCounter)" }

        // Document-wide counters, exactly the printed paper's.
        var sectionNumber = 0
        var subsectionNumber = 0
        var noteCounter = 0
        var notes: [(id: String, text: String)] = []
        var usedEquations = 0
        var jumpTargets: [String: String] = [:]   // "fig1" → paragraph id
        var pendingImages: [(assetID: String, paragraphID: String)] = []
        var pendingTableCaption = false
        var tableCounter = 0
        var figureCounter = 0
        var docxAuthors: [String] = []
        var docxReferences: [String] = []

        /// Body text from the paragraph's runs: emphasis hugging its
        /// words, citation anchors as tokens, cross-reference anchors
        /// as jump tokens, footnote marks lifted to endnotes, OLE
        /// equation spots substituted with the HTML's TeX.
        func flowedText(_ paragraph: DocxScanner.Paragraph) -> String {
            // Word splits one emphasised phrase across many runs (often
            // mid-word); coalesce equal-trait neighbours first, or each
            // fragment gets its own marker pair and "*C**an…*" reads as
            // broken emphasis all the way into the exported XHTML.
            var runs: [DocxScanner.Run] = []
            for run in paragraph.runs {
                if case .text = run.kind, let last = runs.last, case .text = last.kind,
                   last.bold == run.bold, last.italic == run.italic,
                   last.anchor == run.anchor {
                    runs[runs.count - 1].text += run.text
                } else {
                    runs.append(run)
                }
            }
            var out = ""
            for run in runs {
                switch run.kind {
                case .text:
                    var text = run.text
                    guard !text.isEmpty else { continue }
                    if let anchor = run.anchor {
                        if anchor.hasPrefix("bib"), text.rangeOfCharacter(
                            from: CharacterSet.decimalDigits) != nil {
                            out += "[cite:\(anchor)]"
                            continue
                        }
                        if anchor.hasPrefix("fig") || anchor.hasPrefix("tb") {
                            out += "[\(text)](origami-jump:@\(anchor))"
                            continue
                        }
                    }
                    let core = text.trimmingCharacters(in: .whitespaces)
                    if !core.isEmpty, run.bold || run.italic {
                        let marker = run.bold && run.italic ? "***"
                            : run.bold ? "**" : "*"
                        let leading = text.prefix { $0 == " " || $0 == "\t" }
                        let trailing = text.reversed().prefix { $0 == " " || $0 == "\t" }
                        text = "\(leading)\(marker)\(core)\(marker)\(String(trailing.reversed()))"
                    }
                    out += text
                case .footnote(let id):
                    guard let noteText = footnotes[id] else { continue }
                    noteCounter += 1
                    notes.append(("fn\(noteCounter)", noteText))
                    out += "[note:fn\(noteCounter)]"
                case .equation:
                    usedEquations += 1
                    if let tex = taps?.equation(at: usedEquations - 1) {
                        out += tex
                    } else {
                        out += "⟨equation\(usedEquations)⟩"
                    }
                }
            }
            // The template brackets its citations outside the anchors —
            // "[", the linked number, "]" — while the exporter's [cite:]
            // rendering brings its own brackets: absorb the outer pair
            // (and the commas between adjacent citations in one group).
            return Self.absorbingCitationBrackets(out)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// One image paragraph per pending picture; the figure's printed
        /// caption rides the last as its alt text, so the export shows
        /// one figcaption under the group, as the template prints it.
        func flushFigure(caption: String) {
            guard !pendingImages.isEmpty else {
                if !caption.isEmpty { body.append(LiquidDoc.Paragraph(
                    id: nextID(), heading: nil, text: caption)) }
                return
            }
            figureCounter += 1
            jumpTargets["fig\(figureCounter)"] = pendingImages[0].paragraphID
            for (index, image) in pendingImages.enumerated() {
                let alt = index == pendingImages.count - 1 ? caption : ""
                body.append(LiquidDoc.Paragraph(
                    id: image.paragraphID, heading: nil,
                    text: "![\(alt)](asset:\(image.assetID))"))
            }
            pendingImages = []
        }

        for item in items {
            switch item {
            case .paragraph(let paragraph):
                let plain = paragraph.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
                switch paragraph.style {
                case "Titledocument":
                    if !plain.isEmpty { result.title = plain }
                case "Authors":
                    if !plain.isEmpty { docxAuthors.append(plain) }
                case "Affiliation":
                    guard !plain.isEmpty else { break }
                    // The template ends each affiliation with the
                    // author's email; the front matter shows emails
                    // under the names instead, as the siblings do.
                    var line = plain
                    if let match = line.range(
                        of: #",\s*[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\s*$"#,
                        options: .regularExpression) {
                        let email = line[match].dropFirst()
                            .trimmingCharacters(in: .whitespaces)
                        if let author = docxAuthors.last {
                            result.authorEmails[author] = email
                        }
                        line.removeSubrange(match)
                    }
                    if !result.affiliations.contains(line) {
                        result.affiliations.append(line)
                    }
                    if let author = docxAuthors.last {
                        result.authorAffiliations[author] = line
                    }
                case "Abstract":
                    body.append(LiquidDoc.Paragraph(id: nextID(), heading: 1,
                                                    text: "Abstract"))
                    body.append(LiquidDoc.Paragraph(id: nextID(), heading: nil,
                                                    text: flowedText(paragraph)))
                case "CCSDescription":
                    let ccs = taps?.ccsConcepts ?? plain
                    body.append(LiquidDoc.Paragraph(
                        id: nextID(), heading: nil,
                        text: "**CCS Concepts:** \(ccs)"))
                case "KeyWords":
                    body.append(LiquidDoc.Paragraph(
                        id: nextID(), heading: nil,
                        text: "**Keywords:** \(plain)"))
                case "Head1":
                    guard !plain.isEmpty else { break }
                    sectionNumber += 1
                    subsectionNumber = 0
                    body.append(LiquidDoc.Paragraph(
                        id: nextID(), heading: 1,
                        text: "\(sectionNumber) \(plain)"))
                case "Head2":
                    guard !plain.isEmpty else { break }
                    subsectionNumber += 1
                    body.append(LiquidDoc.Paragraph(
                        id: nextID(), heading: 2,
                        text: "\(sectionNumber).\(subsectionNumber) \(plain)"))
                case "Image":
                    for rid in paragraph.imageRIDs {
                        guard let asset = imageAsset(rid: rid, archive: archive,
                                                     media: mediaByRID,
                                                     count: assets.count) else { continue }
                        assets.append(asset)
                        pendingImages.append((asset.id, nextID()))
                    }
                case "FigureCaption":
                    flushFigure(caption: plain)
                case "TableCaption":
                    guard !plain.isEmpty else { break }
                    let id = nextID()
                    tableCounter += 1
                    jumpTargets["tb\(tableCounter)"] = id
                    body.append(LiquidDoc.Paragraph(id: id, heading: nil, text: plain))
                    pendingTableCaption = true
                case "Bibentry":
                    if !plain.isEmpty { docxReferences.append(plain) }
                case "CCSHead", "KeyWordHead", "ReferenceHead":
                    break   // structural labels; the shape is ours to write
                default:
                    guard !plain.isEmpty else { break }
                    // Stray pictures ride ordinary paragraphs too.
                    for rid in paragraph.imageRIDs {
                        guard let asset = imageAsset(rid: rid, archive: archive,
                                                     media: mediaByRID,
                                                     count: assets.count) else { continue }
                        assets.append(asset)
                        pendingImages.append((asset.id, nextID()))
                    }
                    let text = flowedText(paragraph)
                    if !text.isEmpty {
                        body.append(LiquidDoc.Paragraph(id: nextID(), heading: nil,
                                                        text: text))
                    }
                }
            case .table(let table):
                if !table.imageRIDs.isEmpty {
                    // A layout table holding a figure's pictures — the
                    // template's multi-part figures. Its cells carry no
                    // prose; the images join the pending figure.
                    for rid in table.imageRIDs {
                        guard let asset = imageAsset(rid: rid, archive: archive,
                                                     media: mediaByRID,
                                                     count: assets.count) else { continue }
                        assets.append(asset)
                        pendingImages.append((asset.id, nextID()))
                    }
                } else if pendingTableCaption, !table.rows.isEmpty {
                    pendingTableCaption = false
                    let identifier = "word-table-\(tables.count + 1)"
                    let columns = table.rows.map(\.count).max() ?? 0
                    let cells = table.rows.map { row -> [LiquidDoc.Table.Cell] in
                        var padded = row.map { LiquidDoc.Table.Cell(value: $0) }
                        while padded.count < columns {
                            padded.append(LiquidDoc.Table.Cell(value: ""))
                        }
                        return padded
                    }
                    tables.append(LiquidDoc.Table(identifier: identifier,
                                                  rowCount: cells.count,
                                                  columnCount: columns,
                                                  cells: cells))
                    let pipeText = table.rows
                        .map { $0.joined(separator: " | ") }
                        .joined(separator: "\n")
                    var paragraph = LiquidDoc.Paragraph(id: nextID(), heading: nil,
                                                        text: pipeText)
                    paragraph.tableID = identifier
                    body.append(paragraph)
                }
            }
        }
        flushFigure(caption: "")

        // Cross-reference tokens onto their real targets; a name nothing
        // answered keeps its printed words alone.
        for index in body.indices {
            var text = body[index].text
            guard text.contains("origami-jump:@") else { continue }
            for (name, target) in jumpTargets {
                text = text.replacingOccurrences(of: "(origami-jump:@\(name))",
                                                 with: "(origami-jump:\(target))")
            }
            while let range = text.range(
                of: #"\[([^\]]*)\]\(origami-jump:@[a-z0-9]+\)"#,
                options: .regularExpression) {
                let words = text[range].dropFirst()
                    .prefix { $0 != "]" }
                text.replaceSubrange(range, with: String(words))
            }
            var updated = LiquidDoc.Paragraph(id: body[index].id,
                                              heading: body[index].heading,
                                              text: text)
            updated.tableID = body[index].tableID
            body[index] = updated
        }

        if !notes.isEmpty {
            body.append(LiquidDoc.Paragraph(id: nextID(), heading: 1, text: "Notes"))
            for note in notes {
                body.append(LiquidDoc.Paragraph(id: note.id, heading: nil,
                                                text: note.text))
            }
        }

        // The byline: the print's names when the HTML's ACM reference
        // block agrees on the count, the manuscript's otherwise.
        var authors = docxAuthors
        if let printed = taps?.printedAuthors, printed.count == authors.count {
            for (manuscript, print) in zip(authors, printed) where manuscript != print {
                result.authorEmails[print] = result.authorEmails.removeValue(
                    forKey: manuscript) ?? result.authorEmails[print]
                result.authorAffiliations[print] = result.authorAffiliations.removeValue(
                    forKey: manuscript) ?? result.authorAffiliations[print]
            }
            authors = printed
        }
        result.authors = authors
        if let orcids = taps?.orcids, orcids.count == authors.count {
            for (author, orcid) in zip(authors, orcids) {
                result.authorORCIDs[author] = orcid
            }
        }

        result.body = body
        result.assets = assets
        result.tables = tables
        result.doi = taps?.doi
        result.acmReference = taps?.acmReference
        result.license = taps?.license
        result.publication = taps?.publication
        result.references = references(docxLines: docxReferences, taps: taps,
                                       notices: &result.notices)
        if taps == nil {
            result.notices.append("""
                No TAPS HTML was given: the paper imports without its DOI, \
                ACM reference block, license, ORCIDs, and equation TeX.
                """)
        }
        if footnotes.count > notes.count {
            result.notices.append("""
                \(footnotes.count - notes.count) footnote(s) outside the body \
                (author-block notes such as “Corresponding author”) were not carried.
                """)
        }
        if usedEquations > 0, taps?.equationCount ?? 0 < usedEquations {
            result.notices.append(
                "\(usedEquations) equation(s) had no TeX to substitute.")
        }
        return result
    }

    /// The exporter's [cite:] rendering brings its own brackets — absorb
    /// the manuscript's outer pair and the separators inside it:
    /// "[[cite:bib7], [cite:bib9]]" → "[cite:bib7][cite:bib9]".
    static func absorbingCitationBrackets(_ text: String) -> String {
        var out = text
        while let range = out.range(
            of: #"\[((?:\s*\[cite:[A-Za-z0-9_.:-]+\]\s*[,;–-]?)+\s*)\]"#,
            options: .regularExpression) {
            let inner = String(out[range].dropFirst().dropLast())
            var tokens: [String] = []
            var cursor = inner.startIndex
            while let hit = inner.range(of: #"\[cite:[A-Za-z0-9_.:-]+\]"#,
                                        options: .regularExpression,
                                        range: cursor..<inner.endIndex) {
                tokens.append(String(inner[hit]))
                cursor = hit.upperBound
            }
            out.replaceSubrange(range, with: tokens.joined())
        }
        return out
    }

    // MARK: Pieces

    private static func footnoteTexts(archive: DocxZip) -> [Int: String] {
        guard let data = archive.read("word/footnotes.xml"),
              let xml = String(data: data, encoding: .utf8) else { return [:] }
        var texts: [Int: String] = [:]
        guard let regex = try? NSRegularExpression(
            pattern: #"<w:footnote(?:\s[^>]*)?\sw:id="(-?\d+)"[^>]*>(.*?)</w:footnote>"#,
            options: .dotMatchesLineSeparators) else { return [:] }
        let range = NSRange(xml.startIndex..., in: xml)
        for match in regex.matches(in: xml, range: range) {
            guard let idRange = Range(match.range(at: 1), in: xml),
                  let bodyRange = Range(match.range(at: 2), in: xml),
                  let id = Int(xml[idRange]), id > 0 else { continue }
            let text = Self.concatenatedText(inRunXML: String(xml[bodyRange]))
            if !text.isEmpty { texts[id] = text }
        }
        return texts
    }

    private static func mediaRelationships(archive: DocxZip) -> [String: String] {
        guard let data = archive.read("word/_rels/document.xml.rels"),
              let xml = String(data: data, encoding: .utf8) else { return [:] }
        var map: [String: String] = [:]
        guard let regex = try? NSRegularExpression(
            pattern: #"<Relationship\b[^>]*\bId="([^"]+)"[^>]*\bTarget="([^"]+)"[^>]*/?>"#)
        else { return [:] }
        let range = NSRange(xml.startIndex..., in: xml)
        for match in regex.matches(in: xml, range: range) {
            guard let idRange = Range(match.range(at: 1), in: xml),
                  let targetRange = Range(match.range(at: 2), in: xml) else { continue }
            var target = String(xml[targetRange])
            guard target.contains("media/") else { continue }
            target = target.replacingOccurrences(of: "../", with: "")
            if !target.hasPrefix("word/") { target = "word/" + target }
            map[String(xml[idRange])] = target
        }
        return map
    }

    private static func imageAsset(rid: String, archive: DocxZip,
                                   media: [String: String],
                                   count: Int) -> LiquidDoc.Asset? {
        guard let target = media[rid], let bytes = archive.read(target) else { return nil }
        let ext = (target as NSString).pathExtension.lowercased()
        // WMF is Windows-only drawing — the OLE equations' previews;
        // the equations travel as TeX instead.
        guard ext != "wmf", ext != "emf", !bytes.isEmpty else { return nil }
        let id = "img\(count + 1)"
        return LiquidDoc.Asset(id: id, filename: "\(id).\(ext)",
                               mediaType: LiquidDoc.mediaType(forExtension: ext),
                               dataBase64: bytes.base64EncodedString(), alt: nil)
    }

    static func concatenatedText(inRunXML xml: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: "<w:t[^>]*>(.*?)</w:t>",
            options: .dotMatchesLineSeparators) else { return "" }
        var text = ""
        let range = NSRange(xml.startIndex..., in: xml)
        for match in regex.matches(in: xml, range: range) {
            if let piece = Range(match.range(at: 1), in: xml) {
                text += TAPSHTML.decodeEntities(String(xml[piece]))
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: The references

    /// The reference list, printed numbers and all. The TAPS HTML is the
    /// richer source — venue in <em>, DOI and URL as live links — with
    /// the manuscript's Bibentry lines as the fallback.
    private static func references(docxLines: [String], taps: TAPSHTML?,
                                   notices: inout [String]) -> [LiquidDoc.Reference] {
        if let taps, !taps.references.isEmpty {
            if !docxLines.isEmpty, docxLines.count != taps.references.count {
                notices.append("""
                    The manuscript lists \(docxLines.count) references but the \
                    TAPS HTML lists \(taps.references.count); the HTML's list \
                    (the print's) was used.
                    """)
            }
            return taps.references.enumerated().map { index, entry in
                LiquidDoc.Reference(
                    id: "bib\(index + 1)",
                    bibtex: bibtex(number: index + 1, display: entry.display,
                                   venue: entry.venue, doi: entry.doi, url: entry.url),
                    citedAs: nil, number: index + 1)
            }
        }
        return docxLines.enumerated().map { index, line in
            // TAPS-prepared manuscripts carry literal <bib>/<number>
            // markers inside the text; strip them to the printed words.
            let display = line
                .replacingOccurrences(of: #"<[^>]+>"#, with: "",
                                      options: .regularExpression)
                .replacingOccurrences(of: #"^\s*\[\d+\]\s*"#, with: "",
                                      options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            return LiquidDoc.Reference(
                id: "bib\(index + 1)",
                bibtex: bibtex(number: index + 1, display: display,
                               venue: nil, doi: nil, url: nil),
                citedAs: nil, number: index + 1)
        }
    }

    /// A BibTeX entry from the printed line — authors up to the year,
    /// the title sentence after it, the venue when the HTML italicised
    /// one. Parsed fields only; what cannot be told apart stays out
    /// rather than guessed wrong.
    private static func bibtex(number: Int, display: String, venue: String?,
                               doi: String?, url: String?) -> String {
        var authors: String?
        var year: String?
        var title: String?
        var rest = display
        if let regex = try? NSRegularExpression(
            pattern: #"^(.+?)[.,]?\s+((?:17|18|19|20)\d\d)[a-z]?\.\s+"#,
            options: .dotMatchesLineSeparators),
           let match = regex.firstMatch(in: rest,
                                        range: NSRange(rest.startIndex..., in: rest)),
           let authorsRange = Range(match.range(at: 1), in: rest),
           let yearRange = Range(match.range(at: 2), in: rest),
           let matchedRange = Range(match.range, in: rest) {
            authors = String(rest[authorsRange])
                .trimmingCharacters(in: CharacterSet(charactersIn: " .,"))
            year = String(rest[yearRange])
            rest = String(rest[matchedRange.upperBound...])
        }
        if let venue, let venueRange = rest.range(of: venue) {
            title = String(rest[rest.startIndex..<venueRange.lowerBound])
                .trimmingCharacters(in: CharacterSet(charactersIn: " .,"))
        } else if let sentence = rest.range(of: #"^(.+?[.?!])\s"#,
                                            options: .regularExpression) {
            title = String(rest[sentence])
                .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        } else if !rest.isEmpty {
            title = rest.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        }
        let cleanVenue = venue?.trimmingCharacters(in: CharacterSet(charactersIn: " .,"))
        let isProceedings = cleanVenue.map {
            $0.range(of: #"Proceedings|Conference|Workshop|Symposium|Adjunct|Companion"#,
                     options: .regularExpression) != nil
        } ?? false
        let type = cleanVenue == nil ? "misc" : (isProceedings ? "inproceedings" : "article")
        var fields: [(String, String)] = []
        if let authors, !authors.isEmpty {
            let names = authors
                .replacingOccurrences(of: ", and ", with: " and ")
                .replacingOccurrences(of: #",\s+"#, with: " and ",
                                      options: .regularExpression)
            fields.append(("author", names))
        }
        if let title, !title.isEmpty { fields.append(("title", title)) }
        if let year { fields.append(("year", year)) }
        if let cleanVenue {
            fields.append((isProceedings ? "booktitle" : "journaltitle", cleanVenue))
        }
        if let doi { fields.append(("doi", doi)) }
        if let url, doi == nil { fields.append(("url", url)) }
        let bodyText = fields.map { "  \($0.0) = {\($0.1)}" }.joined(separator: ",\n")
        return "@\(type){bib\(number),\n\(bodyText)\n}"
    }
}

// MARK: The OOXML walk

extension ACMWordPaper {

    /// Walks word/document.xml once, in order, into a flat stream of
    /// styled paragraphs and tables — a real XML parse, so entities,
    /// split runs and nested table paragraphs never fall to a regex.
    nonisolated final class DocxScanner: NSObject, XMLParserDelegate {

        struct Run {
            enum Kind { case text, footnote(Int), equation }
            var kind: Kind = .text
            var text = ""
            var bold = false
            var italic = false
            /// The enclosing w:hyperlink's in-document target, when any.
            var anchor: String?
        }

        struct Paragraph {
            var style = ""
            var runs: [Run] = []
            var imageRIDs: [String] = []
            var plainText: String {
                runs.map { run in
                    if case .text = run.kind { return run.text }
                    return ""
                }.joined()
            }
        }

        struct Table {
            var rows: [[String]] = []
            var imageRIDs: [String] = []
        }

        enum Item {
            case paragraph(Paragraph)
            case table(Table)
        }

        static func scan(_ xml: Data) -> [Item] {
            let scanner = DocxScanner()
            let parser = XMLParser(data: xml)
            parser.delegate = scanner
            parser.parse()
            return scanner.items
        }

        private var items: [Item] = []
        private var paragraph: Paragraph?
        private var run: Run?
        private var anchor: String?
        private var inRunProperties = false
        private var collectingText = false
        /// Table nesting: cell texts gather per row; images surface on
        /// the table itself. Only depth 1 is kept — the template nests
        /// no further.
        private var table: Table?
        private var tableDepth = 0
        private var currentRow: [String] = []
        private var currentCell = ""

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String]) {
            switch elementName {
            case "w:tbl":
                tableDepth += 1
                if tableDepth == 1 { table = Table() }
            case "w:tr" where tableDepth == 1:
                currentRow = []
            case "w:tc" where tableDepth == 1:
                currentCell = ""
            case "w:p":
                paragraph = Paragraph()
            case "w:pStyle":
                paragraph?.style = attributes["w:val"] ?? ""
            case "w:hyperlink":
                anchor = attributes["w:anchor"]
            case "w:r":
                run = Run(anchor: anchor)
            case "w:rPr":
                inRunProperties = true
            case "w:b", "w:bCs":
                if inRunProperties, isOn(attributes["w:val"]) { run?.bold = true }
            case "w:i", "w:iCs":
                if inRunProperties, isOn(attributes["w:val"]) { run?.italic = true }
            case "w:t":
                collectingText = true
            case "w:footnoteReference":
                if let id = attributes["w:id"].flatMap(Int.init) {
                    closeRun()
                    var mark = Run(anchor: nil)
                    mark.kind = .footnote(id)
                    paragraph?.runs.append(mark)
                }
            case "o:OLEObject":
                closeRun()
                var mark = Run(anchor: nil)
                mark.kind = .equation
                paragraph?.runs.append(mark)
            case "a:blip":
                if let rid = attributes["r:embed"] { paragraph?.imageRIDs.append(rid) }
            case "w:br", "w:tab":
                run?.text += " "
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName: String?) {
            switch elementName {
            case "w:tbl":
                if tableDepth == 1, let done = table {
                    items.append(.table(done))
                    table = nil
                }
                tableDepth = max(0, tableDepth - 1)
            case "w:tr" where tableDepth == 1:
                if !currentRow.isEmpty { table?.rows.append(currentRow) }
            case "w:tc" where tableDepth == 1:
                currentRow.append(currentCell.trimmingCharacters(in: .whitespacesAndNewlines))
            case "w:p":
                closeRun()
                guard let done = paragraph else { break }
                paragraph = nil
                if tableDepth > 0 {
                    // A cell's words gather into the grid; its pictures
                    // (the template's multi-part figures ride in layout
                    // tables) surface on the table.
                    let words = done.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !words.isEmpty {
                        currentCell += currentCell.isEmpty ? words : " " + words
                    }
                    table?.imageRIDs.append(contentsOf: done.imageRIDs)
                } else {
                    items.append(.paragraph(done))
                }
            case "w:hyperlink":
                anchor = nil
            case "w:r":
                closeRun()
            case "w:rPr":
                inRunProperties = false
            case "w:t":
                collectingText = false
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard collectingText else { return }
            if run == nil { run = Run(anchor: anchor) }
            // Word text smuggles field and object control characters
            // that are not legal XML — the export would refuse them.
            run?.text += String(string.unicodeScalars.filter {
                $0.value >= 0x20 || $0 == "\n" || $0 == "\t"
            }.map(Character.init))
        }

        private func closeRun() {
            guard let done = run else { return }
            run = nil
            guard !done.text.isEmpty else { return }
            paragraph?.runs.append(done)
        }

        private func isOn(_ value: String?) -> Bool {
            guard let value else { return true }
            return !["0", "false", "none"].contains(value.lowercased())
        }
    }
}

// MARK: The TAPS HTML

extension ACMWordPaper {

    /// What the TAPS-produced HTML rendering contributes: metadata the
    /// manuscript cannot carry and the print-side forms of what it can.
    /// All reads are lenient — a block the file lacks is simply nil.
    nonisolated struct TAPSHTML {
        var doi: String?
        var acmReference: String?
        var license: String?
        var publication: String?
        var printedAuthors: [String]?
        var orcids: [String]?
        var ccsConcepts: String?
        var references: [(display: String, venue: String?, doi: String?, url: String?)] = []
        private var equations: [String] = []

        var equationCount: Int { equations.count }
        func equation(at index: Int) -> String? {
            index < equations.count ? equations[index] : nil
        }

        init?(url: URL) {
            guard let rawFile = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            // The TAPS HTML spells its typography in numeric entities —
            // decode the whole file first so every pattern below sees
            // the characters the reader sees (© and ’, not &#x…;).
            let raw = Self.decodeEntities(rawFile)

            // The ACM Reference Format block — the paper's citation of
            // itself, verbatim, and the home of its own DOI.
            if let block = Self.first(#"ACM Reference [Ff]ormat:?\s*</[^>]+>(.{40,1200}?https://doi\.org/[^\s<"]+)"#,
                                      in: raw, group: 1) {
                let text = Self.plainText(block)
                acmReference = text
                if let doiRange = text.range(of: #"10\.\d{4,}/[^\s"<]+"#,
                                             options: .regularExpression) {
                    doi = String(text[doiRange])
                        .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                }
                // "In 37th ACM Conference on Hypertext (HT '26), …" — the
                // venue between "In" and its short name (whose opening
                // paren the odd production file drops).
                if let venue = Self.first(#"\bIn\s+(.{8,120}?)\s*\(?[A-Z]{2,}\s*['’]\d\d\)"#,
                                          in: text, group: 1) {
                    publication = venue.trimmingCharacters(
                        in: CharacterSet(charactersIn: " ,("))
                }
                // The authors ahead of the year — the names as printed.
                if let head = Self.first(#"^(.+?)\.\s+(?:19|20)\d\d\."#, in: text, group: 1) {
                    let names = head
                        .replacingOccurrences(of: ", and ", with: ", ")
                        .replacingOccurrences(of: " and ", with: ", ")
                        .components(separatedBy: ", ")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    if names.count > 1 { printedAuthors = names }
                }
            }

            // The license block, as the sibling EPUBs carry it: the CC
            // sentence, the venue line, the copyright line, the ISBN,
            // and the DOI link — one line each.
            if raw.contains("This work is licensed under")
                || raw.range(of: #"©\s*20\d\d Copyright held by"#,
                             options: .regularExpression) != nil {
                var lines: [String] = []
                if let cc = Self.first(
                    #"This work is licensed under a\s*(?:</?[^>]+>\s*)*([^<]{10,80}License)"#,
                    in: raw, group: 1) {
                    lines.append("This work is licensed under a "
                        + Self.plainText(cc).trimmingCharacters(in: .whitespaces) + ".")
                }
                if let venueLine = Self.first(
                    #"License\s*(?:</?[^>]+>\s*)*\.?\s*(?:</?[^>]+>\s*)*([A-Z]{2,}\s*['’]\d\d,[^<]{4,80})"#,
                    in: raw, group: 1) {
                    lines.append(Self.plainText(venueLine))
                }
                if let copyright = Self.first(#"(©\s*20\d\d Copyright held by[^<]{5,120})"#,
                                              in: raw, group: 1) {
                    lines.append(Self.plainText(copyright))
                }
                if let isbn = Self.first(#"(ACM ISBN [^<\s]{8,40})"#, in: raw, group: 1) {
                    lines.append(Self.plainText(isbn))
                }
                if let doi { lines.append("https://doi.org/\(doi)") }
                if !lines.isEmpty { license = lines.joined(separator: "\n") }
            }

            // ORCIDs, in the author blocks' order.
            var orcidList: [String] = []
            Self.forEach(#"orcid\.org/(\d{4}-\d{4}-\d{4}-\d{3}[\dX])"#, in: raw) {
                if !orcidList.contains($0[0]) { orcidList.append($0[0]) }
            }
            if !orcidList.isEmpty { self.orcids = orcidList }

            // The CCS line, arrow and all — the manuscript's own flattens
            // the hierarchy to bullets.
            if let ccs = Self.first(#"CCS Concepts:?\s*(?:</?[^>]+>\s*)*(.{10,300}?)(?:Additional Key|Keywords|</p)"#,
                                    in: raw, group: 1) {
                let text = Self.plainText(ccs)
                    .trimmingCharacters(in: CharacterSet(charactersIn: " ;•"))
                if !text.isEmpty { ccsConcepts = "• " + text }
            }

            // The equations, in document order, as TeX. A single-letter
            // equation reads better as its letter.
            var texList: [String] = []
            Self.forEach(#"<span class="tex">\$(.+?)\$</span>"#, in: raw) { groups in
                let tex = Self.plainText(groups[0])
                    .trimmingCharacters(in: .whitespaces)
                let bare = tex.replacingOccurrences(of: #"\ "#, with: "")
                    .trimmingCharacters(in: .whitespaces)
                texList.append(
                    bare.count <= 2 && bare.allSatisfy(\.isLetter) ? bare : "$\(tex)$")
            }
            self.equations = texList

            // The reference list: one <li id="bibN"> per entry, venue in
            // <em>, ways out as links.
            var entries: [(display: String, venue: String?, doi: String?, url: String?)] = []
            Self.forEach(#"<li id="bib\d+"[^>]*>(.*?)</li>"#, in: raw) { groups in
                let item = groups[0]
                let venue = Self.first(#"<em>(.*?)</em>"#, in: item, group: 1)
                    .map(Self.plainText)
                var doi: String?
                var url: String?
                Self.forEach(#"href="([^"]+)""#, in: item) { links in
                    let link = links[0]
                    if let range = link.range(of: #"10\.\d{4,}/[^\s"<]+"#,
                                              options: .regularExpression),
                       link.contains("doi.org") {
                        if doi == nil { doi = String(link[range]) }
                    } else if url == nil, link.hasPrefix("http") {
                        url = link
                    }
                }
                var display = Self.plainText(item)
                display = display.replacingOccurrences(of: #"^\s*\[\d+\]\s*"#, with: "",
                                                       options: .regularExpression)
                entries.append((display, venue, doi, url))
            }
            self.references = entries
        }

        // MARK: Lenient readers

        private static func first(_ pattern: String, in text: String,
                                  group: Int) -> String? {
            guard let regex = try? NSRegularExpression(
                pattern: pattern, options: [.dotMatchesLineSeparators]) else { return nil }
            let range = NSRange(text.startIndex..., in: text)
            guard let match = regex.firstMatch(in: text, range: range),
                  let hit = Range(match.range(at: group), in: text) else { return nil }
            return String(text[hit])
        }

        private static func forEach(_ pattern: String, in text: String,
                                    _ body: ([String]) -> Void) {
            guard let regex = try? NSRegularExpression(
                pattern: pattern, options: [.dotMatchesLineSeparators]) else { return }
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) {
                var groups: [String] = []
                for index in 1..<match.numberOfRanges {
                    guard let hit = Range(match.range(at: index), in: text) else { continue }
                    groups.append(String(text[hit]))
                }
                if !groups.isEmpty { body(groups) }
            }
        }

        /// Tags out, entities decoded, whitespace flowed.
        static func plainText(_ html: String) -> String {
            let untagged = html.replacingOccurrences(of: #"<[^>]+>"#, with: " ",
                                                     options: .regularExpression)
            return decodeEntities(untagged)
                .replacingOccurrences(of: #"\s+"#, with: " ",
                                      options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// Numeric character references and the common named few — the
        /// TAPS HTML spells its typography almost entirely in &#x…;.
        static func decodeEntities(_ text: String) -> String {
            var out = text
            let named: [String: String] = [
                "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
                "&apos;": "'", "&#39;": "'", "&nbsp;": "\u{00A0}",
                "&mdash;": "—", "&ndash;": "–", "&hellip;": "…",
                "&ldquo;": "\u{201C}", "&rdquo;": "\u{201D}",
                "&lsquo;": "\u{2018}", "&rsquo;": "\u{2019}",
            ]
            for (entity, character) in named {
                out = out.replacingOccurrences(of: entity, with: character)
            }
            while let range = out.range(of: #"&#x?[0-9A-Fa-f]+;"#,
                                        options: .regularExpression) {
                let body = out[range].dropFirst(2).dropLast()
                let scalar = body.hasPrefix("x") || body.hasPrefix("X")
                    ? UInt32(body.dropFirst(), radix: 16)
                    : UInt32(body)
                let replacement = scalar.flatMap(Unicode.Scalar.init).map(String.init) ?? ""
                out.replaceSubrange(range, with: replacement)
            }
            // Control characters are not legal XML content — the export
            // refuses them; production HTML smuggles the odd one.
            return String(out.unicodeScalars.filter {
                $0.value >= 0x20 || $0 == "\n" || $0 == "\t"
            }.map(Character.init))
        }
    }
}

// MARK: - Recovering inline images from the .docx

/// Apple's NSAttributedString OOXML reader imports Word text and formatting
/// but silently drops inline images. This recovers them: it reads the .docx
/// (a zip) directly, finds each inline image and the paragraph it belongs
/// to, and inserts the image into the already-imported attributed string.
/// Inline images only; floating/anchored art is intentionally not handled.
/// (Ported from Author's `WordImageImporter`.)
nonisolated enum WordImageRecovery {

    @discardableResult
    static func insertImages(from docxData: Data, into attributed: NSMutableAttributedString) -> Int {
        guard let zip = DocxZip(data: docxData),
              let documentData = zip.read("word/document.xml"),
              let documentXML = String(data: documentData, encoding: .utf8) else {
            return 0
        }
        let relationships = parseRelationships(zip: zip)
        guard !relationships.isEmpty else { return 0 }
        let placements = parseImagePlacements(documentXML: documentXML)
        guard !placements.isEmpty else { return 0 }
        let paragraphEnds = paragraphEndOffsets(in: attributed.string)
        guard !paragraphEnds.isEmpty else { return 0 }

        var inserted = 0
        // Insert from the last paragraph backwards so earlier offsets stay valid.
        for placement in placements.sorted(by: { $0.paragraphIndex > $1.paragraphIndex }) {
            guard let target = relationships[placement.embedID],
                  let imageData = zip.read(target),
                  NSBitmapImageRep(data: imageData) != nil else { continue }
            let attachment = NSTextAttachment()
            let fileWrapper = FileWrapper(regularFileWithContents: imageData)
            fileWrapper.preferredFilename = (target as NSString).lastPathComponent
            attachment.fileWrapper = fileWrapper
            attachment.image = NSImage(data: imageData)
            let piece = NSMutableAttributedString(attachment: attachment)
            piece.insert(NSAttributedString(string: "\n"), at: 0)   // its own line
            let clampedIndex = min(placement.paragraphIndex, paragraphEnds.count - 1)
            let insertionPoint = paragraphEnds[clampedIndex]
            attributed.insert(piece, at: min(insertionPoint, attributed.length))
            inserted += 1
        }
        return inserted
    }

    private struct ImagePlacement {
        let embedID: String
        let paragraphIndex: Int
    }

    private static func parseRelationships(zip: DocxZip) -> [String: String] {
        guard let relsData = zip.read("word/_rels/document.xml.rels"),
              let relsXML = String(data: relsData, encoding: .utf8) else { return [:] }
        var map: [String: String] = [:]
        let pattern = #"<Relationship\b[^>]*\bId="([^"]+)"[^>]*\bTarget="([^"]+)"[^>]*/?>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [:] }
        let range = NSRange(relsXML.startIndex..., in: relsXML)
        for match in regex.matches(in: relsXML, range: range) {
            guard let idRange = Range(match.range(at: 1), in: relsXML),
                  let targetRange = Range(match.range(at: 2), in: relsXML) else { continue }
            let id = String(relsXML[idRange])
            var target = String(relsXML[targetRange])
            guard target.contains("media/") else { continue }
            target = target.replacingOccurrences(of: "../", with: "")
            if !target.hasPrefix("word/") { target = "word/" + target }
            map[id] = target
        }
        return map
    }

    private static func parseImagePlacements(documentXML: String) -> [ImagePlacement] {
        let paragraphPattern = #"<w:p(?:\s[^>]*)?>.*?</w:p>|<w:p(?:\s[^>]*)?/>"#
        let embedPattern = #"r:embed="([^"]+)""#
        guard let paragraphRegex = try? NSRegularExpression(pattern: paragraphPattern, options: [.dotMatchesLineSeparators]),
              let embedRegex = try? NSRegularExpression(pattern: embedPattern) else { return [] }
        var placements: [ImagePlacement] = []
        let fullRange = NSRange(documentXML.startIndex..., in: documentXML)
        var paragraphIndex = 0
        for match in paragraphRegex.matches(in: documentXML, range: fullRange) {
            defer { paragraphIndex += 1 }
            guard let range = Range(match.range, in: documentXML) else { continue }
            let paragraph = String(documentXML[range])
            guard paragraph.contains("r:embed") else { continue }
            let paragraphNSRange = NSRange(paragraph.startIndex..., in: paragraph)
            for embed in embedRegex.matches(in: paragraph, range: paragraphNSRange) {
                if let idRange = Range(embed.range(at: 1), in: paragraph) {
                    placements.append(ImagePlacement(embedID: String(paragraph[idRange]), paragraphIndex: paragraphIndex))
                }
            }
        }
        return placements
    }

    private static func paragraphEndOffsets(in string: String) -> [Int] {
        let ns = string as NSString
        var ends: [Int] = []
        var lineStart = 0
        while lineStart <= ns.length {
            let searchRange = NSRange(location: lineStart, length: ns.length - lineStart)
            let newline = ns.range(of: "\n", options: [], range: searchRange)
            if newline.location == NSNotFound {
                ends.append(ns.length)
                break
            } else {
                ends.append(newline.location)
                lineStart = newline.location + 1
            }
        }
        return ends
    }
}

/// Recovers HYPERLINK fields from a `.docx`'s OOXML — the form Pages (and
/// Word, for some links) writes and which AppKit's reader drops. Handles both
/// complex fields (`fldChar` begin/separate/end with `instrText`) and simple
/// fields (`w:fldSimple`), returning each link's visible text and URL.
nonisolated enum WordFieldLinks {

    static func hyperlinkFields(inDocx data: Data) -> [(text: String, url: String)] {
        guard let zip = DocxZip(data: data),
              let xmlData = zip.read("word/document.xml"),
              let xml = String(data: xmlData, encoding: .utf8) else { return [] }
        return fields(in: xml, pattern: complexPattern) + fields(in: xml, pattern: simplePattern)
    }

    // Complex field: … fldCharType="begin" … instrText ` HYPERLINK "url" ` …
    // fldCharType="separate" <result runs> fldCharType="end". Quotes in the
    // instruction are usually escaped as &quot; but may be literal.
    private static let complexPattern =
        "fldCharType=\"begin\".*?HYPERLINK\\s+(?:&quot;|\")([^&\"]+)(?:&quot;|\").*?fldCharType=\"separate\"(.*?)fldCharType=\"end\""

    // Simple field: <w:fldSimple w:instr=' HYPERLINK &quot;url&quot; '> runs </w:fldSimple>
    private static let simplePattern =
        "<w:fldSimple[^>]*w:instr=\"[^\"]*HYPERLINK\\s+&quot;([^&]+)&quot;[^\"]*\"[^>]*>(.*?)</w:fldSimple>"

    private static func fields(in xml: String, pattern: String) -> [(text: String, url: String)] {
        guard let expression = try? NSRegularExpression(
            pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return [] }
        var out: [(text: String, url: String)] = []
        for match in expression.matches(in: xml, range: NSRange(xml.startIndex..., in: xml)) {
            guard let urlRange = Range(match.range(at: 1), in: xml),
                  let bodyRange = Range(match.range(at: 2), in: xml) else { continue }
            let url = xmlDecoded(String(xml[urlRange]))
            let text = displayText(inRunXML: String(xml[bodyRange]))
            if !url.isEmpty, !text.isEmpty { out.append((text, url)) }
        }
        return out
    }

    /// The concatenated `<w:t>` text within a field's result runs.
    private static func displayText(inRunXML runXML: String) -> String {
        guard let expression = try? NSRegularExpression(
            pattern: "<w:t[^>]*>(.*?)</w:t>", options: [.dotMatchesLineSeparators]) else { return "" }
        var text = ""
        for match in expression.matches(in: runXML, range: NSRange(runXML.startIndex..., in: runXML)) {
            if let range = Range(match.range(at: 1), in: runXML) { text += runXML[range] }
        }
        return xmlDecoded(text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func xmlDecoded(_ string: String) -> String {
        string.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
    }
}

/// Reference-manager citations from a `.docx` — Zotero and Mendeley
/// store each citation as a Word field whose instruction carries the
/// full CSL-JSON metadata, so the user's library is never needed. The
/// harvest walks document.xml, footnotes.xml, and endnotes.xml with a
/// real field state machine (instructions split across runs, nested
/// fields, `fldSimple`), builds a works map with stable cite keys, and
/// hands back BibTeX references plus the in-body replacements that
/// turn each visible citation into `[cite:key]` tokens.
nonisolated enum WordCitationFields {

    /// One completed field: its instruction and its visible result,
    /// paragraph breaks in the result kept as newlines.
    struct FieldCluster {
        var instruction = ""
        var result = ""
    }

    struct Harvest {
        /// The works map, in first-appearance order: cite key + BibTeX.
        var references: [LiquidDoc.Reference] = []
        /// Each citation cluster in document order: the visible text
        /// AppKit put in the body, and the token text replacing it.
        var replacements: [(display: String, replacement: String)] = []
        /// The flattened bibliography's lines, to drop from the body —
        /// the references section is regenerated from the works map.
        var bibliographyLines: [String] = []
        /// Import diagnostics, WARNINGs first.
        var notices: [String] = []
        /// Whether any reference-manager field was seen at all.
        var foundCitationFields = false
    }

    // MARK: The harvest

    static func harvest(fromDocx data: Data) -> Harvest {
        guard let zip = DocxZip(data: data) else { return Harvest() }
        var harvest = Harvest()
        var works = WorksMap()
        // All three parts carry fields; notes' citations still yield
        // their metadata even where the note text itself is dropped.
        for part in ["word/document.xml", "word/footnotes.xml", "word/endnotes.xml"] {
            guard let xml = zip.read(part) else { continue }
            for cluster in FieldScanner.fields(in: xml) {
                classify(cluster, into: &harvest, works: &works)
            }
        }
        harvest.references = works.orderedReferences()
        if let uncited = works.uncitedCount, uncited > 0 {
            harvest.notices.insert("""
                \(uncited) uncited bibliography \(uncited == 1 ? "entry" : "entries") \
                could not be imported (the metadata lives only in the reference \
                manager's library) — re-cite them or add them manually.
                """, at: 0)
        }
        return harvest
    }

    /// §8: with no recognised fields, a document full of author-year
    /// parentheses was probably flattened (Unlink Citations).
    static func looksFlattened(_ text: String) -> Bool {
        let pattern = #"\(\p{Lu}[\p{L}'-]+( et al\.)?,? (17|18|19|20)\d\d[a-z]?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let hits = regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
        if hits >= 3 { return true }
        return text.range(of: #"^(References|Bibliography|Works Cited)$"#,
                          options: [.regularExpression, .caseInsensitive]) != nil
    }

    // MARK: Classification (§2)

    private static func classify(_ cluster: FieldCluster, into harvest: inout Harvest,
                                 works: inout WorksMap) {
        let instruction = cluster.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard instruction.hasPrefix("ADDIN") else { return }
        if instruction.contains("CSL_CITATION") && !instruction.contains("CSL_BIBLIOGRAPHY") {
            // Zotero (ADDIN ZOTERO_ITEM CSL_CITATION) and Mendeley
            // Desktop (ADDIN CSL_CITATION) share the schema.
            harvest.foundCitationFields = true
            citation(instruction: instruction, result: cluster.result,
                     into: &harvest, works: &works)
        } else if instruction.contains("ZOTERO_BIBL")
                    || instruction.contains("CSL_BIBLIOGRAPHY") {
            harvest.foundCitationFields = true
            bibliography(instruction: instruction, result: cluster.result,
                         into: &harvest, works: &works)
        } else if instruction.contains("EN.CITE") {
            harvest.notices.append("""
                EndNote citations detected — metadata import for EndNote is not \
                yet supported; the citations are preserved as text.
                """)
        } else if instruction.contains("EN.REFLIST") {
            // The EndNote bibliography: its text stands as it is.
        } else if instruction.contains("CitaviPlaceholder") {
            harvest.notices.append(
                "Citavi citations detected — preserved as text (not yet supported).")
        }
        // Any other ADDIN (or plain Word field): its result already
        // stands in the body as text — current behaviour.
    }

    /// One citation cluster (§3, §6.1): every cited work joins the map,
    /// and the visible text is replaced by `[cite:key]` tokens with the
    /// author's prefix and locator kept as plain words around them.
    private static func citation(instruction: String, result: String,
                                 into harvest: inout Harvest, works: inout WorksMap) {
        guard let json = firstJSONObject(in: instruction) else {
            harvest.notices.append(
                "One citation field's data could not be read — it was imported as plain text.")
            return
        }
        let items = (json["citationItems"] as? [[String: Any]]) ?? []
        guard !items.isEmpty else { return }
        var pieces: [String] = []
        for item in items {
            guard let itemData = item["itemData"] as? [String: Any] else { continue }
            let uris = (item["uris"] as? [String]) ?? []
            let key = works.key(for: itemData, uris: uris)
            var piece = ""
            if let prefix = item["prefix"] as? String,
               !prefix.trimmingCharacters(in: .whitespaces).isEmpty {
                piece += prefix.trimmingCharacters(in: .whitespaces) + " "
            }
            piece += "[cite:\(key)]"
            if let locator = item["locator"] as? String, !locator.isEmpty {
                piece += " (\(locatorLabel(item["label"] as? String)) \(locator))"
            }
            if let suffix = item["suffix"] as? String,
               !suffix.trimmingCharacters(in: .whitespaces).isEmpty {
                piece += " " + suffix.trimmingCharacters(in: .whitespaces)
            }
            pieces.append(piece)
        }
        guard !pieces.isEmpty else { return }
        let display = result
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A field with no visible result has nothing to replace; the
        // references still land.
        if !display.isEmpty {
            harvest.replacements.append((display, pieces.joined(separator: " ")))
        }
    }

    private static func locatorLabel(_ label: String?) -> String {
        switch label {
        case nil, "page": "p."
        case "chapter": "ch."
        case "section": "§"
        case let other?: other
        }
    }

    /// The bibliography control field (§5): its formatted list is
    /// dropped (the references regenerate from the works map), and its
    /// `uncited` URIs become a warning — their metadata is not in the
    /// document.
    private static func bibliography(instruction: String, result: String,
                                     into harvest: inout Harvest, works: inout WorksMap) {
        harvest.bibliographyLines.append(contentsOf: result
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })
        if let json = firstJSONObject(in: instruction) {
            let uncited = (json["uncited"] as? [[String]])?.count
                ?? (json["uncited"] as? [Any])?.count ?? 0
            works.uncitedCount = uncited
        }
    }

    /// The first balanced JSON object after the field keyword — never
    /// regexed; the payload is full of nested braces (§2).
    private static func firstJSONObject(in instruction: String) -> [String: Any]? {
        guard let start = instruction.firstIndex(of: "{") else { return nil }
        let tail = String(instruction[start...])
        // The instruction may trail the JSON (ZOTERO_BIBL ends with
        // "CSL_BIBLIOGRAPHY"): JSONSerialization wants the object
        // alone, so scan to its balanced end first.
        var depth = 0
        var inString = false
        var escaped = false
        var end: String.Index?
        for index in tail.indices {
            let character = tail[index]
            if escaped { escaped = false; continue }
            switch character {
            case "\\" where inString: escaped = true
            case "\"": inString.toggle()
            case "{" where !inString: depth += 1
            case "}" where !inString:
                depth -= 1
                if depth == 0 { end = index }
            default: break
            }
            if end != nil { break }
        }
        guard let end,
              let objectData = String(tail[...end]).data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: objectData)) as? [String: Any]
    }

    // MARK: The works map (§4)

    struct WorksMap {
        private var keysByIdentity: [String: String] = [:]
        private var referencesByKey: [String: LiquidDoc.Reference] = [:]
        private var order: [String] = []
        var uncitedCount: Int?

        /// The work's cite key, minted on first sight: FamilyYYYYFirstword,
        /// ASCII-folded, collisions suffixed a, b, c…
        mutating func key(for itemData: [String: Any], uris: [String]) -> String {
            let identity = uris.isEmpty
                ? [CSLItem.firstFamily(of: itemData) ?? "",
                   CSLItem.year(of: itemData) ?? "",
                   (itemData["title"] as? String ?? "").lowercased()]
                    .joined(separator: "|")
                : uris.sorted().joined(separator: "|")
            if let existing = keysByIdentity[identity] { return existing }
            var base = (CSLItem.firstFamily(of: itemData) ?? "Anon")
                + (CSLItem.year(of: itemData) ?? "")
                + CSLItem.firstTitleWord(of: itemData)
            base = base.folding(options: .diacriticInsensitive, locale: nil)
                .components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
            if base.isEmpty { base = "Work" }
            var key = base
            var suffix = ""
            while referencesByKey[key] != nil {
                suffix = suffix.isEmpty ? "a" : String(UnicodeScalar(
                    suffix.unicodeScalars.first!.value + 1)!)
                key = base + suffix
            }
            keysByIdentity[identity] = key
            referencesByKey[key] = LiquidDoc.Reference(
                id: key,
                bibtex: CSLItem.bibtex(of: itemData, key: key),
                citedAs: CSLItem.citedAs(of: itemData))
            order.append(key)
            return key
        }

        func orderedReferences() -> [LiquidDoc.Reference] {
            order.compactMap { referencesByKey[$0] }
        }
    }

    // MARK: CSL-JSON accessors and the BibTeX mapping (§4.1)

    /// Lenient readers over the raw CSL-JSON dictionary — CSL in the
    /// wild carries string-or-number ids and parts, so nothing here
    /// assumes a rigid shape; a malformed item degrades, never aborts.
    enum CSLItem {

        static func firstFamily(of item: [String: Any]) -> String? {
            guard let authors = item["author"] as? [[String: Any]],
                  let first = authors.first else { return nil }
            return (first["family"] as? String)
                ?? (first["literal"] as? String)?
                    .components(separatedBy: " ").last
        }

        static func year(of item: [String: Any]) -> String? {
            guard let issued = item["issued"] as? [String: Any],
                  let parts = issued["date-parts"] as? [[Any]],
                  let year = parts.first?.first else { return nil }
            return "\(year)".components(separatedBy: ".").first
        }

        static func firstTitleWord(of item: [String: Any]) -> String {
            let skip: Set<String> = ["a", "an", "the", "on", "of", "in", "and",
                                     "for", "to", "at", "from", "with"]
            let words = (item["title"] as? String ?? "")
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
            let word = words.first { $0.count > 1 && !skip.contains($0.lowercased()) }
            return (word ?? "").capitalized
        }

        static func citedAs(of item: [String: Any]) -> String? {
            guard let family = firstFamily(of: item) else { return nil }
            let year = year(of: item)
            return "(\(family)\(year.map { ", \($0)" } ?? ""))"
        }

        /// CSL `type` → BibTeX entry type.
        private static func entryType(_ type: String?) -> String {
            switch type {
            case "article-journal", "article-magazine", "article-newspaper": "article"
            case "paper-conference": "inproceedings"
            case "chapter": "incollection"
            case "book": "book"
            case "thesis": "thesis"
            case "report": "report"
            case "webpage", "post", "post-weblog": "online"
            case "manuscript": "unpublished"
            case "dataset": "dataset"
            default: "misc"
            }
        }

        /// The derived BibTeX entry — raw UTF-8, the app's own `.bib`
        /// convention (this codebase parses its references with
        /// BibTeXParser; the export layers escape at their own edge).
        static func bibtex(of item: [String: Any], key: String) -> String {
            let type = entryType(item["type"] as? String)
            var fields: [(String, String)] = []
            func add(_ name: String, _ value: String?) {
                if let value, !value.isEmpty {
                    fields.append((name, value.replacingOccurrences(of: "\n", with: " ")))
                }
            }
            func names(_ csl: String) -> String? {
                guard let people = item[csl] as? [[String: Any]], !people.isEmpty
                else { return nil }
                return people.compactMap { person -> String? in
                    if let literal = person["literal"] as? String { return "{\(literal)}" }
                    guard let family = person["family"] as? String else { return nil }
                    let given = person["given"] as? String
                    return given.map { "\(family), \($0)" } ?? family
                }.joined(separator: " and ")
            }
            add("title", item["title"] as? String)
            add("author", names("author"))
            add("editor", names("editor"))
            add("year", year(of: item))
            let container = item["container-title"] as? String
            switch type {
            case "article": add("journaltitle", container)
            case "inproceedings", "incollection": add("booktitle", container)
            default: add("howpublished", container)
            }
            add("series", item["collection-title"] as? String)
            add("volume", (item["volume"] as? String) ?? (item["volume"] as? NSNumber)?.stringValue)
            add("number", (item["issue"] as? String) ?? (item["issue"] as? NSNumber)?.stringValue)
            add("pages", (item["page"] as? String)?
                .replacingOccurrences(of: "-", with: "--")
                .replacingOccurrences(of: "----", with: "--")
                .replacingOccurrences(of: "\u{2013}", with: "--"))
            add("publisher", item["publisher"] as? String)
            add("address", item["publisher-place"] as? String)
            add("doi", item["DOI"] as? String)
            add("url", item["URL"] as? String)
            add("isbn", item["ISBN"] as? String)
            add("issn", item["ISSN"] as? String)
            add("eventtitle", item["event-title"] as? String)
            if type == "thesis" { add("type", item["genre"] as? String) }
            if let accessed = item["accessed"] as? [String: Any],
               let parts = (accessed["date-parts"] as? [[Any]])?.first {
                let stamped = parts.prefix(3).map {
                    String(format: "%02d", Int("\($0)".components(separatedBy: ".").first ?? "") ?? 0)
                }.joined(separator: "-")
                if !stamped.isEmpty { add("urldate", stamped) }
            }
            let body = fields.map { "  \($0.0) = {\($0.1)}" }.joined(separator: ",\n")
            return "@\(type){\(key),\n\(body)\n}"
        }
    }

    // MARK: The field scanner (§1)

    /// Walks one OOXML part and returns every completed field, in
    /// document order: instructions concatenated across split
    /// `instrText` runs, a depth stack so nested fields never
    /// desynchronise, `fldSimple` handled alongside, and paragraph
    /// ends inside a field's result kept as newlines.
    private final class FieldScanner: NSObject, XMLParserDelegate {

        static func fields(in xmlData: Data) -> [FieldCluster] {
            let scanner = FieldScanner()
            let parser = XMLParser(data: xmlData)
            parser.delegate = scanner
            parser.parse()
            return scanner.completed
        }

        private var completed: [FieldCluster] = []
        /// The open complex fields, innermost last; `pastSeparate`
        /// rides along per level.
        private var stack: [(field: FieldCluster, pastSeparate: Bool)] = []
        private var collectingInstruction = false
        private var collectingText = false

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String]) {
            switch elementName {
            case "w:fldChar":
                switch attributes["w:fldCharType"] {
                case "begin":
                    stack.append((FieldCluster(), false))
                case "separate":
                    if !stack.isEmpty { stack[stack.count - 1].pastSeparate = true }
                case "end":
                    guard let done = stack.popLast() else { break }
                    completed.append(done.field)
                    // A nested field's visible words are part of its
                    // parent's result.
                    if !stack.isEmpty { stack[stack.count - 1].field.result += done.field.result }
                default: break
                }
            case "w:instrText":
                collectingInstruction = true
            case "w:t":
                collectingText = true
            case "w:fldSimple":
                // The instruction lives in the attribute (already
                // entity-decoded by the parser); children are result.
                var simple = FieldCluster()
                simple.instruction = attributes["w:instr"] ?? ""
                stack.append((simple, true))
            default: break
            }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName: String?) {
            switch elementName {
            case "w:instrText": collectingInstruction = false
            case "w:t": collectingText = false
            case "w:fldSimple":
                guard let done = stack.popLast() else { break }
                completed.append(done.field)
                if !stack.isEmpty { stack[stack.count - 1].field.result += done.field.result }
            case "w:p":
                // A paragraph break inside a field's result — the
                // flattened bibliography's line ends.
                if !stack.isEmpty, stack[stack.count - 1].pastSeparate {
                    stack[stack.count - 1].field.result += "\n"
                }
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard !stack.isEmpty else { return }
            let last = stack.count - 1
            if collectingInstruction, !stack[last].pastSeparate {
                stack[last].field.instruction += string
            } else if collectingText, stack[last].pastSeparate {
                stack[last].field.result += string
            }
        }
    }
}

/// A tiny read-only ZIP reader sufficient for .docx: parses the central
/// directory and inflates entries (stored or DEFLATE) via the Compression
/// framework. (Ported from Author's `MiniZip`.)
nonisolated private struct DocxZip {
    private struct Entry {
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    private let bytes: [UInt8]
    private let entries: [String: Entry]

    init?(data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 22 else { return nil }
        func u16(_ o: Int) -> Int { Int(bytes[o]) | (Int(bytes[o + 1]) << 8) }
        func u32(_ o: Int) -> Int {
            Int(bytes[o]) | (Int(bytes[o + 1]) << 8) | (Int(bytes[o + 2]) << 16) | (Int(bytes[o + 3]) << 24)
        }
        var eocd = -1
        var i = bytes.count - 22
        while i >= 0 {
            if bytes[i] == 0x50, bytes[i + 1] == 0x4b, bytes[i + 2] == 0x05, bytes[i + 3] == 0x06 {
                eocd = i
                break
            }
            i -= 1
        }
        guard eocd >= 0 else { return nil }
        let count = u16(eocd + 10)
        var pointer = u32(eocd + 16)
        var map: [String: Entry] = [:]
        for _ in 0..<count {
            guard pointer + 46 <= bytes.count, u32(pointer) == 0x02014b50 else { break }
            let method = UInt16(u16(pointer + 10))
            let compressedSize = u32(pointer + 20)
            let uncompressedSize = u32(pointer + 24)
            let nameLen = u16(pointer + 28)
            let extraLen = u16(pointer + 30)
            let commentLen = u16(pointer + 32)
            let localOffset = u32(pointer + 42)
            let nameStart = pointer + 46
            guard nameStart + nameLen <= bytes.count else { break }
            let name = String(bytes: bytes[nameStart..<nameStart + nameLen], encoding: .utf8) ?? ""
            map[name] = Entry(method: method, compressedSize: compressedSize,
                              uncompressedSize: uncompressedSize, localHeaderOffset: localOffset)
            pointer = nameStart + nameLen + extraLen + commentLen
        }
        guard !map.isEmpty else { return nil }
        self.bytes = bytes
        self.entries = map
    }

    func read(_ name: String) -> Data? {
        guard let entry = entries[name] else { return nil }
        let lo = entry.localHeaderOffset
        guard lo + 30 <= bytes.count else { return nil }
        func u16(_ o: Int) -> Int { Int(bytes[o]) | (Int(bytes[o + 1]) << 8) }
        guard Int(bytes[lo]) | (Int(bytes[lo + 1]) << 8) | (Int(bytes[lo + 2]) << 16) | (Int(bytes[lo + 3]) << 24) == 0x04034b50 else {
            return nil
        }
        let nameLen = u16(lo + 26)
        let extraLen = u16(lo + 28)
        let dataStart = lo + 30 + nameLen + extraLen
        guard dataStart + entry.compressedSize <= bytes.count else { return nil }
        let compressed = Array(bytes[dataStart..<dataStart + entry.compressedSize])
        switch entry.method {
        case 0: return Data(compressed)
        case 8: return DocxZip.inflate(compressed, expectedSize: entry.uncompressedSize)
        default: return nil
        }
    }

    private static func inflate(_ input: [UInt8], expectedSize: Int) -> Data? {
        guard expectedSize > 0 else { return Data() }
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: expectedSize)
        defer { destination.deallocate() }
        let written = input.withUnsafeBufferPointer { source -> Int in
            guard let base = source.baseAddress else { return 0 }
            return compression_decode_buffer(destination, expectedSize, base, input.count, nil, COMPRESSION_ZLIB)
        }
        guard written > 0 else { return nil }
        return Data(bytes: destination, count: written)
    }
}
