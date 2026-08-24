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
                            assets: assets)
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

/// A tiny read-only ZIP reader sufficient for .docx: parses the central
/// directory and inflates entries (stored or DEFLATE) via the Compression
/// framework. (Ported from Author's `MiniZip`.)
private struct DocxZip {
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
