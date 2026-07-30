import Compression
import Foundation

nonisolated enum OrigamiEPUBImportError: LocalizedError {
    case notAnEPUB
    case unsupportedCompression(Int)
    case corruptContainer
    case missingContent

    var errorDescription: String? {
        switch self {
        case .notAnEPUB:
            "This does not look like an EPUB (no readable ZIP structure)."
        case .unsupportedCompression(let method):
            "The EPUB uses an unsupported compression method (\(method))."
        case .corruptContainer:
            "The EPUB's container is damaged."
        case .missingContent:
            "No content document was found inside the EPUB."
        }
    }
}

/// Reading an Origami Text EPUB back: everything the exporter wrote is
/// recovered — the body with its stable paragraph ids (`data-id`, the
/// hook for high-resolution addressing), heading levels, speakers, the
/// inline conventions, and the whole Visual-Meta payload: concepts,
/// citations (internal ones back to links, external ones back to
/// references, verbatim BibTeX and all), Map views, and connections.
/// `visual-meta.json` in the package is the source of truth; when only
/// the HTML survives, the embedded copy between the
/// `@visual-meta-start`/`@visual-meta-end` markers serves instead.
nonisolated enum OrigamiEPUBImporter {

    struct ImportResult: Sendable {
        let title: String
        let author: String?
        /// YYYY-MM-DD from the package metadata.
        let date: String?
        /// The publication identifier (urn:uuid:…), for provenance.
        let identifier: String?
        /// The document's original origami address, when the EPUB
        /// carries one — the receiving library may keep it, so
        /// citations to the book resolve wherever it arrives.
        let origamiID: String?
        let body: [LiquidDoc.Paragraph]
        var links: [LiquidDoc.Link] = []
        var concepts: [LiquidDoc.Concept] = []
        var layouts: [LiquidDoc.Layout] = []
        var mapConnections: [LiquidDoc.MapConnection] = []
        var references: [LiquidDoc.Reference] = []
        /// Live tables, keyed by identifier to the body's table paragraphs.
        var tables: [LiquidDoc.Table] = []
        /// Mathematics in the document (§8.2): from the Visual-Meta
        /// equations block when present, else a body scan of `math[id]`.
        var equations: [EquationEntry] = []
        /// Images recovered from the body's `<figure>/<img>`, referenced by
        /// `![alt](asset:id)` markers in the body.
        var assets: [LiquidDoc.Asset] = []
    }

    static func importDocument(at url: URL) throws -> ImportResult {
        let zip = try ZipReader(data: try Data(contentsOf: url))

        // container.xml names the package document; be tolerant when
        // the container is odd but the profile's layout holds.
        let opfPath = containerRootFile(in: zip) ?? "package.opf"
        guard let opfData = zip.entry(opfPath) else { throw OrigamiEPUBImportError.corruptContainer }
        let opf = String(decoding: opfData, as: UTF8.self)
        let opfDirectory = (opfPath as NSString).deletingLastPathComponent

        let title = firstTagText(in: opf, tag: "dc:title")
        let creator = firstTagText(in: opf, tag: "dc:creator")
        let date = firstTagText(in: opf, tag: "dc:date")
        let identifier = firstTagText(in: opf, tag: "dc:identifier")

        // The spine's first itemref names the content document.
        guard let contentHref = spineContentHref(in: opf),
              let contentData = zip.entry(joinedPath(opfDirectory, contentHref))
                  ?? zip.entry(contentHref)
        else { throw OrigamiEPUBImportError.missingContent }
        let html = String(decoding: contentData, as: UTF8.self)

        // Visual-Meta: the package file first, the embedded copy second.
        let visualMetaData = zip.entry("visual-meta.json")
            ?? zip.entries.first { $0.key.hasSuffix("visual-meta.json") }?.value
            ?? embeddedVisualMeta(in: html)
        let visualMeta = visualMetaData.flatMap {
            (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]
        }

        // The citation pool, split back into its two homes: internal
        // citations (an origamitext:// URL names their address) become
        // links again; external records become references.
        var addressByCitationID: [String: String] = [:]
        var bibtexByAddress: [String: String] = [:]
        var references: [LiquidDoc.Reference] = []
        for citation in dictionaries(visualMeta?["citations"]) {
            guard let citationID = citation["id"] as? String else { continue }
            let urls = citation["urls"] as? [String] ?? []
            let bibtex = (citation["bibtex"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let address = urls.lazy.compactMap(originalAddress(fromOpenURL:)).first {
                addressByCitationID[citationID] = address
                if let bibtex, !bibtex.isEmpty { bibtexByAddress[address] = bibtex }
            } else if let bibtex, !bibtex.isEmpty {
                references.append(LiquidDoc.Reference(id: citationID, bibtex: bibtex))
            }
        }

        let concepts: [LiquidDoc.Concept] = dictionaries(visualMeta?["concepts"]).compactMap { node in
            guard let conceptID = node["id"] as? String,
                  let name = node["name"] as? String else { return nil }
            return LiquidDoc.Concept(
                id: conceptID,
                name: name,
                description: node["description"] as? String ?? "",
                tag: (node["tag"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                citationIdentifiers: node["citationIdentifiers"] as? [String] ?? [],
                urls: node["urls"] as? [String] ?? [])
        }

        let map = visualMeta?["map"] as? [String: Any]
        let layouts: [LiquidDoc.Layout] = dictionaries(map?["views"]).enumerated().map { position, view in
            let positions = dictionaries(view["nodes"]).compactMap { node -> LiquidDoc.Layout.Position? in
                guard let ref = node["ref"] as? String else { return nil }
                return LiquidDoc.Layout.Position(
                    id: ref,
                    x: (node["x"] as? NSNumber)?.doubleValue ?? 0,
                    y: (node["y"] as? NSNumber)?.doubleValue ?? 0,
                    z: (node["z"] as? NSNumber)?.doubleValue ?? 0)
            }
            return LiquidDoc.Layout(index: position + 1,
                                    name: view["name"] as? String ?? "View \(position + 1)",
                                    positions: positions,
                                    sourceID: view["id"] as? String)
        }
        let mapConnections: [LiquidDoc.MapConnection] = dictionaries(map?["connections"]).compactMap {
            guard let from = $0["from"] as? String, let to = $0["to"] as? String else { return nil }
            return LiquidDoc.MapConnection(from: from, to: to)
        }

        // Live tables: the Visual-Meta `tables` array is the raw source
        // (values and formulas both). The body's <table> elements only
        // supply placement (their data-table-id links here).
        let tables: [LiquidDoc.Table] = dictionaries(visualMeta?["tables"]).compactMap { raw in
            guard let identifier = raw["identifier"] as? String, !identifier.isEmpty else { return nil }
            let cellRows = raw["cells"] as? [[[String: Any]]] ?? []
            let cells: [[LiquidDoc.Table.Cell]] = cellRows.map { row in
                row.map { cell in
                    LiquidDoc.Table.Cell(value: cell["value"] as? String ?? "",
                                         formula: cell["formula"] as? String)
                }
            }
            return LiquidDoc.Table(
                identifier: identifier,
                rowCount: (raw["rowCount"] as? NSNumber)?.intValue ?? cells.count,
                columnCount: (raw["columnCount"] as? NSNumber)?.intValue ?? (cells.first?.count ?? 0),
                cells: cells)
        }

        // Mathematics: prefer a Visual-Meta equations block, fall back to a
        // scan of the content document's `math[id]` elements. MathML in the
        // body renders natively in the reader; this index powers citing and
        // copying equations.
        let equationHref = joinedPath(opfDirectory, contentHref)
        let equations = EquationIndex.build(visualMetaText: html,
                                            contentHTML: html,
                                            contentHref: equationHref).entries

        // Resolve an image `src` (relative to the content document) to its
        // bytes in the package, so figures import as assets.
        let contentDir = (equationHref as NSString).deletingLastPathComponent
        let resolveImage: (String) -> Data? = { src in
            let full = joinedPath(contentDir, src)
            return zip.entry(full)
                ?? zip.entry(src)
                ?? zip.entries.first { $0.key.hasSuffix("/\((src as NSString).lastPathComponent)") }?.value
        }

        let (body, bodyAssets) = try bodyParagraphs(fromXHTML: html,
                                                    addressByCitationID: addressByCitationID,
                                                    resolveImage: resolveImage)

        // Links come back the way they were made: derived from the
        // restored body text — rels, fragments, and quoted spans
        // included — then given their BibTeX from the citation pool.
        // Pool citations the body never mentions still count.
        var links = LiquidDoc.detectedLinks(in: body).map { link -> LiquidDoc.Link in
            guard link.bibtex == nil, let bibtex = bibtexByAddress[link.to] else { return link }
            var enriched = link
            enriched.bibtex = bibtex
            return enriched
        }
        for (address, bibtex) in bibtexByAddress.sorted(by: { $0.key < $1.key })
        where !links.contains(where: { $0.to == address }) {
            links.append(LiquidDoc.Link(to: address, fragment: nil, rel: "cites", bibtex: bibtex))
        }
        for address in addressByCitationID.values.sorted()
        where bibtexByAddress[address] == nil && !links.contains(where: { $0.to == address }) {
            links.append(LiquidDoc.Link(to: address, fragment: nil, rel: "cites", bibtex: nil))
        }

        let document = visualMeta?["document"] as? [String: Any]
        return ImportResult(
            title: document?["title"] as? String ?? title ?? "Untitled",
            author: (document?["authors"] as? [String])?.first ?? creator,
            date: document?["date"] as? String ?? date,
            identifier: document?["identifier"] as? String ?? identifier,
            origamiID: document?["origami-id"] as? String,
            body: body,
            links: links,
            concepts: concepts,
            layouts: layouts,
            mapConnections: mapConnections,
            references: references,
            tables: tables,
            equations: equations,
            assets: bodyAssets)
    }

    /// Unpacks the EPUB to `directory` (replacing whatever is there) and
    /// returns the content document (paper.html) on disk, the package base
    /// a WebView may read from, and the document title. This is the
    /// faithful-render path: the reader loads paper.html directly, so its
    /// relative images and style.css resolve from the base.
    struct Unpacked: Sendable {
        let content: URL
        let base: URL
        let title: String
    }

    static func unpack(at url: URL, into directory: URL) throws -> Unpacked {
        let zip = try ZipReader(data: try Data(contentsOf: url))
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: directory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        for (name, data) in zip.entries {
            // Directory placeholders carry no bytes; refuse any name that
            // would escape the unpack directory.
            guard !name.isEmpty, !name.hasSuffix("/"),
                  !name.split(separator: "/").contains("..") else { continue }
            let destination = directory.appendingPathComponent(name)
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            try data.write(to: destination)
        }

        let opfPath = containerRootFile(in: zip) ?? "package.opf"
        let opfDirectory = (opfPath as NSString).deletingLastPathComponent
        guard let opfData = zip.entry(opfPath) else { throw OrigamiEPUBImportError.corruptContainer }
        let opf = String(decoding: opfData, as: UTF8.self)
        guard let href = spineContentHref(in: opf) else { throw OrigamiEPUBImportError.missingContent }

        let content = directory.appendingPathComponent(joinedPath(opfDirectory, href))
        let title = firstTagText(in: opf, tag: "dc:title")
            ?? url.deletingPathExtension().lastPathComponent
        return Unpacked(content: content, base: directory, title: title)
    }

    // MARK: Package plumbing

    private static func containerRootFile(in zip: ZipReader) -> String? {
        guard let data = zip.entry("META-INF/container.xml") else { return nil }
        let xml = String(decoding: data, as: UTF8.self)
        return firstCapture(in: xml, pattern: "full-path=\"([^\"]+)\"")
    }

    private static func spineContentHref(in opf: String) -> String? {
        guard let idref = firstCapture(in: opf, pattern: "<itemref[^>]*idref=\"([^\"]+)\"")
        else { return nil }
        let item = firstCapture(
            in: opf,
            pattern: "<item[^>]*id=\"\(NSRegularExpression.escapedPattern(for: idref))\"[^>]*>")
        return item.flatMap { firstCapture(in: $0, pattern: "href=\"([^\"]+)\"") }
    }

    private static func joinedPath(_ directory: String, _ name: String) -> String {
        directory.isEmpty ? name : "\(directory)/\(name)"
    }

    /// The embedded Visual-Meta copy, when the package file is gone: the
    /// JSON between the payload script's tags, with the CDATA wrapper (and
    /// any split guard) stripped so it decodes.
    private static func embeddedVisualMeta(in html: String) -> Data? {
        guard let open = html.range(of: "id=\"visual-meta-payload\">"),
              let close = html.range(of: "</script>", range: open.upperBound..<html.endIndex)
        else { return nil }
        // Undo the export's CDATA wrapping. Removing both markers also
        // reconstitutes any "]]>" the exporter split across sections.
        let payload = String(html[open.upperBound..<close.lowerBound])
            .replacingOccurrences(of: "<![CDATA[", with: "")
            .replacingOccurrences(of: "]]>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Data(payload.utf8)
    }

    /// "origamitext://open/f.hegla.093252x" → "f.hegla.093252x".
    private static func originalAddress(fromOpenURL url: String) -> String? {
        let prefix = "origamitext://open/"
        guard url.hasPrefix(prefix) else { return nil }
        let address = String(url.dropFirst(prefix.count))
        return address.isEmpty ? nil : address
    }

    private static func dictionaries(_ value: Any?) -> [[String: Any]] {
        value as? [[String: Any]] ?? []
    }

    private static func firstCapture(in text: String, pattern: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: []),
              let match = expression.firstMatch(in: text, options: [],
                                                range: NSRange(text.startIndex..., in: text))
        else { return nil }
        let index = match.numberOfRanges > 1 ? 1 : 0
        return Range(match.range(at: index), in: text).map { String(text[$0]) }
    }

    private static func firstTagText(in xml: String, tag: String) -> String? {
        firstCapture(in: xml, pattern: "<\(tag)[^>]*>([^<]*)</\(tag)>")
            .map(xmlUnescaped)
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func xmlUnescaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#10;", with: "\n")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    // MARK: The body

    /// Rebuilds paragraphs from the content document: `<main>`'s
    /// headings, paragraphs, and rules, each keeping its **stable id**
    /// (`data-id` — the original paragraph id or heading node UUID),
    /// with the export's inline forms folded back into the format's
    /// text conventions.
    private static func bodyParagraphs(fromXHTML html: String,
                                       addressByCitationID: [String: String],
                                       resolveImage: (String) -> Data?)
        throws -> (paragraphs: [LiquidDoc.Paragraph], assets: [LiquidDoc.Asset]) {
        let root = try XMLTree.parse(Data(html.utf8))
        guard let main = root.firstDescendant(named: "main") else {
            throw OrigamiEPUBImportError.missingContent
        }

        var paragraphs: [LiquidDoc.Paragraph] = []
        var assets: [LiquidDoc.Asset] = []
        var assetOrdinal = 0
        var fallbackOrdinal = 0

        func visit(_ element: XMLTree.Element) {
            let headingLevels = ["h2": 1, "h3": 2, "h4": 3]
            let stableID: () -> String = {
                fallbackOrdinal += 1
                return element.attributes["data-id"]
                    ?? element.attributes["id"]
                    ?? "p\(fallbackOrdinal)"
            }
            switch element.name {
            case "section", "div", "article":
                for child in element.elements { visit(child) }
            case "hr":
                paragraphs.append(LiquidDoc.Paragraph(id: stableID(), heading: nil, text: "---"))
            case "figure", "img":
                // A figure/image comes back as an asset plus an
                // `![alt](asset:id)` marker paragraph — the same form the
                // exporter reads, so authoring round-trips.
                let image = element.name == "img" ? element : element.firstDescendant(named: "img")
                guard let image, let src = image.attributes["src"], !src.isEmpty else {
                    for child in element.elements { visit(child) }
                    return
                }
                let alt = image.attributes["alt"] ?? ""
                let paragraphID = stableID()
                if let data = resolveImage(src), !data.isEmpty {
                    assetOrdinal += 1
                    let assetID = "img\(assetOrdinal)"
                    let name = (src as NSString).lastPathComponent
                    let ext = (name as NSString).pathExtension.lowercased()
                    assets.append(LiquidDoc.Asset(
                        id: assetID,
                        filename: name.isEmpty ? "\(assetID).png" : name,
                        mediaType: WordImporter.mediaType(forExtension: ext),
                        dataBase64: data.base64EncodedString(),
                        alt: alt.isEmpty ? nil : alt))
                    paragraphs.append(LiquidDoc.Paragraph(
                        id: paragraphID, heading: nil, text: "![\(alt)](asset:\(assetID))"))
                } else {
                    // Bytes missing: keep the reference visible rather than
                    // dropping the image silently.
                    paragraphs.append(LiquidDoc.Paragraph(
                        id: paragraphID, heading: nil, text: "![\(alt)](\(src))"))
                }
            case "table":
                // The table stands in the flow as its own element: the
                // paragraph keeps the position address (its `id`), points
                // at the Table pool by `data-table-id`, and carries a
                // pipe-table rendering of the computed cell values so a
                // reader without table support loses nothing.
                var paragraph = LiquidDoc.Paragraph(
                    id: stableID(), heading: nil,
                    text: tableFallbackText(of: element))
                paragraph.tableID = element.attributes["data-table-id"]
                    ?? element.attributes["id"]
                paragraphs.append(paragraph)
            case "h2", "h3", "h4":
                let text = inlineText(of: element, addressByCitationID: addressByCitationID)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                paragraphs.append(LiquidDoc.Paragraph(
                    id: stableID(), heading: headingLevels[element.name], text: text))
            case "p":
                let text = inlineText(of: element, addressByCitationID: addressByCitationID)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                var paragraph = LiquidDoc.Paragraph(id: stableID(), heading: nil, text: text)
                // The exporter marks attribution with a speaker strong;
                // the name also leads the text, per the format.
                if let first = element.elements.first,
                   first.name == "strong", first.attributes["class"] == "speaker" {
                    let name = first.plainText.trimmingCharacters(in: .whitespaces)
                    if name.hasSuffix(":") {
                        paragraph.speaker = String(name.dropLast())
                    }
                }
                paragraphs.append(paragraph)
            default:
                for child in element.elements { visit(child) }
            }
        }
        for child in main.elements { visit(child) }
        return (paragraphs, assets)
    }

    /// One element's text with the inline conventions restored: strong
    /// back to `**`, em to `*`, code to backticks, plain hyperlinks to
    /// `[label](url)`, citation anchors back to their bracketed origami
    /// address (or their visible `[n]` when the citation is external),
    /// `<dfn>` wrappers unwrapped, the speaker's strong left plain.
    private static func inlineText(of element: XMLTree.Element,
                                   addressByCitationID: [String: String]) -> String {
        var out = ""
        for child in element.children {
            switch child {
            case .text(let text):
                out += text
            case .element(let inner):
                let content = inlineText(of: inner, addressByCitationID: addressByCitationID)
                switch inner.name {
                case "strong", "b":
                    out += inner.attributes["class"] == "speaker"
                        ? content
                        : "**\(content)**"
                case "em", "i":
                    out += "*\(content)*"
                case "code":
                    out += "`\(content)`"
                case "dfn":
                    out += content
                case "a":
                    if inner.attributes["class"] == "citation" {
                        if let reference = inner.attributes["data-origami-ref"],
                           !reference.isEmpty {
                            // Full resolution: rel and #fragment intact.
                            out += "[\(reference)]"
                        } else if let citationID = inner.attributes["data-citation-id"],
                                  let address = addressByCitationID[citationID] {
                            out += "[\(address)]"
                        } else {
                            out += content
                        }
                    } else if let href = inner.attributes["href"], href.hasPrefix("http") {
                        out += "[\(content)](\(href))"
                    } else {
                        out += content
                    }
                default:
                    out += content
                }
            }
        }
        return out
    }

    /// A GFM pipe-table rendering of a `<table>`'s computed cell values —
    /// leading and trailing pipes on every row — used as the plain-text
    /// fallback carried on the table's placeholder paragraph.
    private static func tableFallbackText(of table: XMLTree.Element) -> String {
        var rows: [String] = []
        func collectRows(_ element: XMLTree.Element) {
            for child in element.elements {
                if child.name == "tr" {
                    let cells = child.elements
                        .filter { $0.name == "td" || $0.name == "th" }
                        .map { $0.plainText.trimmingCharacters(in: .whitespacesAndNewlines) }
                    rows.append("| " + cells.joined(separator: " | ") + " |")
                } else {
                    collectRows(child)
                }
            }
        }
        collectRows(table)
        return rows.joined(separator: "\n")
    }
}

// MARK: - A small XML tree

/// The content document as a walkable tree — XMLParser underneath, so
/// entities arrive decoded and the profile's XHTML parses exactly.
private final class XMLTree: NSObject, XMLParserDelegate {

    final class Element {
        let name: String
        let attributes: [String: String]
        var children: [Child] = []

        init(name: String, attributes: [String: String]) {
            self.name = name
            self.attributes = attributes
        }

        var elements: [Element] {
            children.compactMap {
                if case .element(let element) = $0 { return element }
                return nil
            }
        }

        var plainText: String {
            children.map {
                switch $0 {
                case .text(let text): text
                case .element(let element): element.plainText
                }
            }.joined()
        }

        func firstDescendant(named name: String) -> Element? {
            for element in elements {
                if element.name == name { return element }
                if let found = element.firstDescendant(named: name) { return found }
            }
            return nil
        }
    }

    enum Child {
        case element(Element)
        case text(String)
    }

    private let root = Element(name: "#root", attributes: [:])
    private var stack: [Element] = []
    private var failure: Error?

    static func parse(_ data: Data) throws -> Element {
        let tree = XMLTree()
        let parser = XMLParser(data: data)
        parser.delegate = tree
        parser.shouldResolveExternalEntities = false
        tree.stack = [tree.root]
        guard parser.parse(), tree.failure == nil else {
            throw tree.failure ?? parser.parserError ?? OrigamiEPUBImportError.corruptContainer
        }
        return tree.root
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        let element = Element(name: elementName.lowercased(), attributes: attributeDict)
        stack.last?.children.append(.element(element))
        stack.append(element)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        if stack.count > 1 { stack.removeLast() }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.children.append(.text(string))
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        failure = parseError
    }
}

// MARK: - Reading the container

/// A minimal ZIP reader: the central directory drives extraction, and
/// stored and deflated entries both open — our own EPUBs are stored,
/// but EPUBs from other writers usually deflate.
private struct ZipReader {

    private(set) var entriesByName: [String: Data] = [:]

    var entries: [String: Data] { entriesByName }

    func entry(_ name: String) -> Data? { entriesByName[name] }

    init(data: Data) throws {
        // Find the end-of-central-directory record from the back.
        let minimumEOCD = 22
        guard data.count >= minimumEOCD else { throw OrigamiEPUBImportError.notAnEPUB }
        var eocd: Int?
        var probe = data.count - minimumEOCD
        let lowest = max(0, data.count - 66_000)
        while probe >= lowest {
            if le32(data, probe) == 0x0605_4b50 { eocd = probe; break }
            probe -= 1
        }
        guard let eocd else { throw OrigamiEPUBImportError.notAnEPUB }

        let count = Int(le16(data, eocd + 10))
        var offset = Int(le32(data, eocd + 16))
        for _ in 0..<count {
            guard offset + 46 <= data.count,
                  le32(data, offset) == 0x0201_4b50 else {
                throw OrigamiEPUBImportError.corruptContainer
            }
            let method = Int(le16(data, offset + 10))
            let compressedSize = Int(le32(data, offset + 20))
            let uncompressedSize = Int(le32(data, offset + 24))
            let nameLength = Int(le16(data, offset + 28))
            let extraLength = Int(le16(data, offset + 30))
            let commentLength = Int(le16(data, offset + 32))
            let localOffset = Int(le32(data, offset + 42))
            let name = String(decoding: slice(data, offset + 46, nameLength), as: UTF8.self)

            // The local header's name/extra lengths can differ from the
            // central directory's; the data follows the local header.
            guard localOffset + 30 <= data.count,
                  le32(data, localOffset) == 0x0403_4b50 else {
                throw OrigamiEPUBImportError.corruptContainer
            }
            let localName = Int(le16(data, localOffset + 26))
            let localExtra = Int(le16(data, localOffset + 28))
            let start = localOffset + 30 + localName + localExtra
            guard start + compressedSize <= data.count else {
                throw OrigamiEPUBImportError.corruptContainer
            }
            let raw = slice(data, start, compressedSize)

            switch method {
            case 0:
                entriesByName[name] = raw
            case 8:
                entriesByName[name] = try Self.inflated(raw, size: uncompressedSize)
            default:
                throw OrigamiEPUBImportError.unsupportedCompression(method)
            }
            offset += 46 + nameLength + extraLength + commentLength
        }
    }

    /// Raw DEFLATE, which is what Compression's ZLIB algorithm speaks.
    private static func inflated(_ data: Data, size: Int) throws -> Data {
        guard size > 0 else { return Data() }
        var output = Data(count: size)
        let written = output.withUnsafeMutableBytes { out -> Int in
            data.withUnsafeBytes { input -> Int in
                guard let outBase = out.bindMemory(to: UInt8.self).baseAddress,
                      let inBase = input.bindMemory(to: UInt8.self).baseAddress
                else { return 0 }
                return compression_decode_buffer(outBase, size, inBase, data.count,
                                                 nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { throw OrigamiEPUBImportError.corruptContainer }
        return output
    }

    private func le16(_ data: Data, _ offset: Int) -> UInt16 {
        let base = data.startIndex + offset
        return UInt16(data[base]) | (UInt16(data[base + 1]) << 8)
    }

    private func le32(_ data: Data, _ offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return UInt32(data[base])
            | (UInt32(data[base + 1]) << 8)
            | (UInt32(data[base + 2]) << 16)
            | (UInt32(data[base + 3]) << 24)
    }

    private func slice(_ data: Data, _ offset: Int, _ length: Int) -> Data {
        let base = data.startIndex + offset
        return Data(data[base..<base + length])
    }
}
