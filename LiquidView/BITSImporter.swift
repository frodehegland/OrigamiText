import Foundation

/// ACM Digital Library XML in, an Origami document out. The DL serves
/// papers as BITS (Book Interchange Tag Set — proceedings chapters,
/// `<book-part-wrapper>`) or its JATS sibling (journal articles,
/// `<article>`); the body model is the same. Recovers the document
/// model the EPUB exporter writes — the same one the LaTeX importer
/// produces: headings from nested `<sec>`, paragraphs, figures as
/// assets (`![alt](asset:id)`), tables as live grids with pipe-text
/// fallbacks, citations as `[cite:rid]` tokens backed by BibTeX
/// synthesised from `<mixed-citation>`, footnotes as endnotes, and
/// TeX math kept verbatim. Tolerant of unknown elements: their markup
/// drops, their words stay in the flow.
nonisolated enum BITSImportError: LocalizedError {
    case notBITS
    case unreadable

    var errorDescription: String? {
        switch self {
        case .notBITS: "The XML is not an ACM/JATS paper (no <book-part-wrapper> or <article> root)."
        case .unreadable: "The XML could not be parsed."
        }
    }
}

nonisolated enum BITSImporter {

    struct Result: Sendable {
        var title: String
        var author: String?
        /// The proceedings or journal the paper is part of, from
        /// `<book-title>` (BITS) or `<journal-title>` (JATS).
        var publication: String?
        var body: [LiquidDoc.Paragraph]
        var references: [LiquidDoc.Reference] = []
        var tables: [LiquidDoc.Table] = []
        var assets: [LiquidDoc.Asset] = []
    }

    // MARK: - Entry point

    /// A bare .xml file, its figures resolved beside it on disk (the
    /// DL's XML names graphics like `ht2025-3-fig1.jpg`; when the
    /// files aren't there, the caption stays as words).
    static func importFile(at url: URL) throws -> Result {
        guard let data = try? Data(contentsOf: url) else {
            throw BITSImportError.unreadable
        }
        let directory = url.deletingLastPathComponent()
        return try importXML(data, resources: { name in
            try? Data(contentsOf: directory.appendingPathComponent(name))
        }, fallbackTitle: url.deletingPathExtension().lastPathComponent)
    }

    // MARK: - The parse

    static func importXML(_ data: Data, resources: (String) -> Data?,
                          fallbackTitle: String) throws -> Result {
        guard let root = Node.parse(data) else { throw BITSImportError.unreadable }
        guard root.name == "book-part-wrapper" || root.name == "article" else {
            throw BITSImportError.notBITS
        }

        // Metadata: BITS nests the chapter's meta in book-part-meta,
        // JATS in front/article-meta; the venue lives one level up.
        let meta = root.first("book-part", "book-part-meta")
            ?? root.first("front", "article-meta")
        let titleGroup = meta?.child("title-group")
        let title = (titleGroup?.child("title") ?? titleGroup?.child("article-title"))
            .map { flattened($0) }
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? fallbackTitle
        let authors = (meta?.child("contrib-group")?.children(named: "contrib") ?? [])
            .filter { ($0.attributes["contrib-type"] ?? "author") == "author" }
            .compactMap { contrib -> String? in
                guard let name = contrib.child("name") else {
                    let literal = contrib.child("string-name").map { flattened($0) }
                    return literal?.isEmpty == false ? literal : nil
                }
                let given = name.child("given-names").map { flattened($0) } ?? ""
                let surname = name.child("surname").map { flattened($0) } ?? ""
                let full = [given, surname].filter { !$0.isEmpty }.joined(separator: " ")
                return full.isEmpty ? nil : full
            }
        let author = authors.isEmpty ? nil : authors.joined(separator: ", ")
        let publication = (root.first("book-meta", "book-title-group", "book-title")
            ?? root.first("front", "journal-meta", "journal-title-group", "journal-title")
            ?? root.first("front", "journal-meta", "journal-title"))
            .map { flattened($0) }
            .flatMap { $0.isEmpty ? nil : $0 }

        var paragraphs: [LiquidDoc.Paragraph] = []
        var assets: [LiquidDoc.Asset] = []
        var tables: [LiquidDoc.Table] = []
        var ordinal = 0
        var assetOrdinal = 0
        var tableOrdinal = 0

        func nextID() -> String {
            ordinal += 1
            return "p\(ordinal)"
        }
        func appendText(_ text: String) {
            let cleaned = tidyCitationBrackets(text)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return }
            paragraphs.append(LiquidDoc.Paragraph(id: nextID(), heading: nil, text: cleaned))
        }
        func appendHeading(_ text: String, level: Int) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            paragraphs.append(LiquidDoc.Paragraph(id: nextID(), heading: min(max(level, 1), 3),
                                                  text: trimmed))
        }
        func appendFigure(_ fig: Node) {
            // The caption becomes the marker's alt text: cite tokens and
            // brackets give way to plain words, so the `![alt](asset:id)`
            // form stays parseable everywhere — same rule as the LaTeX
            // importer's figures.
            let caption = fig.child("caption").map { flattened(inline(convert: $0)) }
                .map { text in
                    text.replacingOccurrences(of: #"\[cite:[^\]]+\]"#, with: "",
                                              options: .regularExpression)
                        .replacingOccurrences(of: "[", with: "(")
                        .replacingOccurrences(of: "]", with: ")")
                        .replacingOccurrences(of: #"\s+"#, with: " ",
                                              options: .regularExpression)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                } ?? ""
            guard let href = (fig.child("graphic") ?? fig.descendant("graphic"))?
                .attributes["xlink:href"], !href.isEmpty else {
                // A figure with no graphic: keep its caption as words.
                if !caption.isEmpty { appendText(caption) }
                return
            }
            var resolved = resources(href)
            var resolvedName = (href as NSString).lastPathComponent
            if resolved == nil, !resolvedName.contains(".") {
                for probe in ["jpg", "jpeg", "png", "gif", "tiff"] {
                    if let data = resources(href + "." + probe) {
                        resolved = data
                        resolvedName += "." + probe
                        break
                    }
                }
            }
            let paragraphID = nextID()
            if let data = resolved, !data.isEmpty {
                assetOrdinal += 1
                let assetID = "img\(assetOrdinal)"
                let ext = (resolvedName as NSString).pathExtension.lowercased()
                assets.append(LiquidDoc.Asset(
                    id: assetID,
                    filename: resolvedName.contains(".") ? resolvedName : resolvedName + ".jpg",
                    mediaType: WordImporter.mediaType(forExtension: ext.isEmpty ? "jpg" : ext),
                    dataBase64: data.base64EncodedString(),
                    alt: caption.isEmpty ? nil : caption))
                paragraphs.append(LiquidDoc.Paragraph(
                    id: paragraphID, heading: nil, text: "![\(caption)](asset:\(assetID))"))
            } else {
                paragraphs.append(LiquidDoc.Paragraph(
                    id: paragraphID, heading: nil, text: "![\(caption)](\(href))"))
            }
        }
        func appendTable(_ wrap: Node) {
            guard let table = wrap.descendant("table") else {
                if let caption = wrap.child("caption") {
                    appendText(flattened(inline(convert: caption)))
                }
                return
            }
            let rows = table.descendants("tr").map { row in
                row.children.filter { $0.name == "td" || $0.name == "th" }
                    .map { flattened($0) }
            }.filter { !$0.isEmpty }
            guard !rows.isEmpty else { return }
            tableOrdinal += 1
            let columns = rows.map(\.count).max() ?? 0
            let live = LiquidDoc.Table(
                identifier: "xml-table-\(tableOrdinal)",
                rowCount: rows.count, columnCount: columns,
                cells: rows.map { row in
                    (0..<columns).map {
                        LiquidDoc.Table.Cell(value: $0 < row.count ? row[$0] : "")
                    }
                })
            tables.append(live)
            var paragraph = LiquidDoc.Paragraph(
                id: nextID(), heading: nil,
                text: live.cells.map { row in
                    "| " + row.map(\.value).joined(separator: " | ") + " |"
                }.joined(separator: "\n"))
            paragraph.tableID = live.identifier
            paragraphs.append(paragraph)
            if let caption = wrap.child("caption") {
                appendText(flattened(inline(convert: caption)))
            }
        }
        func appendMath(_ formula: Node) {
            guard let tex = formula.descendant("tex-math") else {
                appendText(flattened(inline(convert: formula)))
                return
            }
            let math = strippedTeXDelimiters(flattened(tex, collapseWhitespace: false))
            if !math.isEmpty {
                paragraphs.append(LiquidDoc.Paragraph(id: nextID(), heading: nil, text: math))
            }
        }
        func appendList(_ list: Node) {
            let numbered = list.attributes["list-type"] == "order"
            var number = 0
            for item in list.children(named: "list-item") {
                number += 1
                let marker = numbered ? "\(number). " : "\u{2022} "
                let text = flattened(inline(convert: item))
                if !text.isEmpty {
                    appendText(marker + text)
                }
            }
        }

        /// Walks block content: `<sec>` recursion sets heading levels,
        /// known blocks convert, unknown containers keep their words.
        func walk(_ node: Node, depth: Int) {
            for child in node.children {
                switch child.name {
                case "sec":
                    if let heading = child.child("title") {
                        appendHeading(flattened(heading), level: depth)
                    }
                    walk(child, depth: depth + 1)
                case "title", "label":
                    continue   // handled by the sec/fig/table that owns it
                case "p":
                    // The DL nests figures, tables, and display formulas
                    // mid-paragraph; the flow model here is one block per
                    // paragraph, so they lift out to follow the words.
                    let blocks = extractBlocks(from: child)
                    appendText(flattened(inline(convert: child)))
                    for block in blocks {
                        switch block.name {
                        case "fig": appendFigure(block)
                        case "table-wrap": appendTable(block)
                        default: appendMath(block)
                        }
                    }
                case "fig":
                    appendFigure(child)
                case "table-wrap":
                    appendTable(child)
                case "disp-formula":
                    appendMath(child)
                case "list":
                    appendList(child)
                case "#text":
                    appendText(child.text)
                default:
                    // Unknown container: drop its markers, keep its words
                    // and any blocks inside it.
                    walk(child, depth: depth)
                }
            }
        }

        // Abstract first (the DL keeps it in the meta), then the body.
        if let abstract = meta?.child("abstract") {
            appendHeading("Abstract", level: 1)
            walk(abstract, depth: 1)
        }
        if let body = root.first("book-part", "body") ?? root.child("body") {
            walk(body, depth: 1)
        }

        // Footnotes read as endnotes under their own heading — the DL's
        // fn-group carries author notes and numbered notes alike.
        let back = root.first("book-part", "back") ?? root.child("back")
        let footnotes = (back?.descendants("fn") ?? [])
            .map { fn in flattened(inline(convert: fn)) }
            .filter { !$0.isEmpty }
        if !footnotes.isEmpty {
            appendHeading("Notes", level: 1)
            for note in footnotes { appendText(note) }
        }

        // The bibliography: every <ref> a reference on its own id — the
        // id the body's `[cite:rid]` tokens carry — its BibTeX
        // synthesised from the mixed-citation fields.
        let references = (back?.descendant("ref-list")?.children(named: "ref") ?? [])
            .enumerated()
            .compactMap { index, ref -> LiquidDoc.Reference? in
                guard let citation = ref.child("mixed-citation")
                    ?? ref.child("element-citation") else { return nil }
                let key = ref.attributes["id"] ?? "ref\(index + 1)"
                return LiquidDoc.Reference(id: key, bibtex: bibtex(from: citation, key: key))
            }

        return Result(title: title, author: author, publication: publication,
                      body: paragraphs, references: references,
                      tables: tables, assets: assets)
    }

    /// The block elements that may ride inside a `<p>`.
    private static let nestedBlockNames: Set<String> = ["fig", "table-wrap", "disp-formula"]

    /// Removes nested block elements from the node (recursively), returning
    /// them in document order so the caller can emit them after the
    /// paragraph's own words.
    private static func extractBlocks(from node: Node) -> [Node] {
        var blocks: [Node] = []
        var kept: [Node] = []
        for child in node.children {
            if nestedBlockNames.contains(child.name) {
                blocks.append(child)
            } else {
                blocks.append(contentsOf: extractBlocks(from: child))
                kept.append(child)
            }
        }
        node.children = kept
        return blocks
    }

    // MARK: - Inline conversion

    /// Rewrites a block's inline markup into the format's plain-text
    /// conventions, returning a copy whose element children are replaced
    /// by text: emphasis to markdown, `xref ref-type="bibr"` to
    /// `[cite:rid]`, external links restored, inline TeX kept verbatim
    /// as `$…$`. Nested blocks (a rare fig or formula inside a p) keep
    /// their words.
    private static func inline(convert node: Node) -> Node {
        let copy = Node(name: node.name, attributes: node.attributes)
        copy.text = node.text
        for child in node.children {
            let converted: String?
            switch child.name {
            case "#text":
                converted = nil   // kept structurally below
            case "bold":
                let inner = flattened(inline(convert: child))
                converted = inner.isEmpty ? "" : "**\(inner)**"
            case "italic":
                let inner = flattened(inline(convert: child))
                converted = inner.isEmpty ? "" : "*\(inner)*"
            case "monospace":
                let inner = flattened(inline(convert: child))
                converted = inner.isEmpty ? "" : "`\(inner)`"
            case "xref":
                if child.attributes["ref-type"] == "bibr",
                   let rid = child.attributes["rid"], !rid.isEmpty {
                    // A multi-cite xref carries space-separated ids.
                    converted = rid.split(separator: " ")
                        .map { "[cite:\($0)]" }.joined(separator: ", ")
                } else {
                    converted = flattened(inline(convert: child))
                }
            case "ext-link":
                let href = child.attributes["xlink:href"] ?? ""
                let text = flattened(inline(convert: child))
                if href.isEmpty || text == href || text.isEmpty {
                    converted = href.isEmpty ? text : href
                } else {
                    converted = "[\(text)](\(href))"
                }
            case "inline-formula":
                let tex = child.descendant("tex-math")
                    .map { strippedTeXDelimiters(flattened($0, collapseWhitespace: false)) } ?? ""
                converted = tex.isEmpty
                    ? flattened(inline(convert: child))
                    : "$\(tex)$"
            case "inline-graphic":
                converted = ""
            default:
                // sub/sup, underline, named-content, … — markup drops,
                // words stay.
                converted = flattened(inline(convert: child))
            }
            if let converted {
                let textNode = Node(name: "#text", attributes: [:])
                textNode.text = converted
                copy.children.append(textNode)
            } else {
                copy.children.append(child)
            }
        }
        return copy
    }

    /// The DL writes citation brackets as literal text around the xref —
    /// `[<xref>18</xref>, <xref>19</xref>]` — which would double up
    /// around the tokens: `[[cite:a], [cite:b]]`. Unwrap them.
    private static func tidyCitationBrackets(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"\[((?:\[cite:[^\]]+\])(?:,\s*\[cite:[^\]]+\])*)\]"#,
            with: "$1", options: .regularExpression)
    }

    /// TeX as the DL ships it: `\(…\)` (or `\[…\]`) around the formula,
    /// often an `equation` environment inside. The delimiters are
    /// chrome; the TeX itself is kept verbatim, as the LaTeX importer
    /// keeps environment bodies.
    private static func strippedTeXDelimiters(_ raw: String) -> String {
        var tex = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for (open, close) in [("\\(", "\\)"), ("\\[", "\\]")] {
            if tex.hasPrefix(open), tex.hasSuffix(close), tex.count > open.count + close.count {
                tex = String(tex.dropFirst(open.count).dropLast(close.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        for env in ["equation", "equation*", "displaymath"] {
            let open = "\\begin{\(env)}"
            let close = "\\end{\(env)}"
            if tex.hasPrefix(open), tex.hasSuffix(close), tex.count > open.count + close.count {
                tex = String(tex.dropFirst(open.count).dropLast(close.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return tex
    }

    // MARK: - BibTeX from a citation element

    /// One `<mixed-citation>` as a BibTeX record the rest of the app
    /// already understands (BibTeXParser, the exporter's References).
    /// Fields are taken structurally — authors from person-group,
    /// year, article-title, source, volume/issue/pages, DOI, URL.
    private static func bibtex(from citation: Node, key: String) -> String {
        func clean(_ text: String) -> String {
            text.replacingOccurrences(of: "{", with: "(")
                .replacingOccurrences(of: "}", with: ")")
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let type: String
        switch citation.attributes["publication-type"] {
        case "journal", "periodical": type = "article"
        case "confproc": type = "inproceedings"
        case "book": type = "book"
        default: type = "misc"
        }
        var fields: [(String, String)] = []
        let authorGroup = citation.children(named: "person-group")
            .first { $0.attributes["person-group-type"] == "author" }
            ?? citation.child("person-group")
        if let authorGroup {
            let names = (authorGroup.children(named: "string-name")
                         + authorGroup.children(named: "name"))
                .compactMap { name -> String? in
                    let given = name.child("given-names").map { flattened($0) } ?? ""
                    let surname = name.child("surname").map { flattened($0) } ?? ""
                    let full = [given, surname].filter { !$0.isEmpty }.joined(separator: " ")
                    if !full.isEmpty { return full }
                    let literal = flattened(name)
                    return literal.isEmpty ? nil : literal
                }
            if !names.isEmpty {
                fields.append(("author", clean(names.joined(separator: " and "))))
            }
        }
        let articleTitle = citation.descendant("article-title").map { flattened($0) }
        let source = citation.descendant("source").map { flattened($0) }
        if let articleTitle, !articleTitle.isEmpty {
            fields.append(("title", clean(articleTitle)))
            if let source, !source.isEmpty {
                fields.append((type == "article" ? "journal" : "booktitle", clean(source)))
            }
        } else if let source, !source.isEmpty {
            fields.append(("title", clean(source)))
        }
        if let year = citation.descendant("year").map({ flattened($0) }), !year.isEmpty {
            fields.append(("year", clean(year)))
        }
        if let volume = citation.descendant("volume").map({ flattened($0) }), !volume.isEmpty {
            fields.append(("volume", clean(volume)))
        }
        if let issue = citation.descendant("issue").map({ flattened($0) }), !issue.isEmpty {
            fields.append(("number", clean(issue)))
        }
        let fpage = citation.descendant("fpage").map { flattened($0) } ?? ""
        let lpage = citation.descendant("lpage").map { flattened($0) } ?? ""
        if !fpage.isEmpty {
            fields.append(("pages", clean(lpage.isEmpty ? fpage : "\(fpage)--\(lpage)")))
        }
        if let doi = citation.children(named: "pub-id")
            .first(where: { $0.attributes["pub-id-type"] == "doi" })
            .map({ flattened($0) }), !doi.isEmpty {
            fields.append(("doi", clean(doi)))
        }
        if let url = citation.descendant("ext-link")?.attributes["xlink:href"], !url.isEmpty {
            fields.append(("url", url))
        }
        let lines = fields.map { "  \($0.0) = {\($0.1)}," }
        return "@\(type){\(key),\n" + lines.joined(separator: "\n") + "\n}"
    }

    // MARK: - Text extraction

    /// Every text descendant joined, whitespace collapsed — how any
    /// element reads once its markup is gone.
    private static func flattened(_ node: Node, collapseWhitespace: Bool = true) -> String {
        var pieces: [String] = []
        func gather(_ node: Node) {
            if node.name == "#text" { pieces.append(node.text) }
            for child in node.children where child.name != "label" {
                gather(child)
            }
        }
        gather(node)
        let joined = pieces.joined()
        guard collapseWhitespace else {
            return joined.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return joined
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - A small DOM over XMLParser

    /// A lightweight element tree: XMLParser (SAX, every platform) in,
    /// nested Nodes out — text and CDATA as `#text` children. External
    /// DTDs are never fetched; the DL's numeric character references
    /// resolve without one.
    private final class Node {
        let name: String
        let attributes: [String: String]
        var children: [Node] = []
        var text: String = ""

        init(name: String, attributes: [String: String]) {
            self.name = name
            self.attributes = attributes
        }

        func child(_ name: String) -> Node? {
            children.first { $0.name == name }
        }
        func children(named name: String) -> [Node] {
            children.filter { $0.name == name }
        }
        /// The first descendant with the name, depth-first.
        func descendant(_ name: String) -> Node? {
            for child in children {
                if child.name == name { return child }
                if let found = child.descendant(name) { return found }
            }
            return nil
        }
        func descendants(_ name: String) -> [Node] {
            var found: [Node] = []
            for child in children {
                if child.name == name { found.append(child) }
                found.append(contentsOf: child.descendants(name))
            }
            return found
        }
        /// Descends by element names, one level per name.
        func first(_ path: String...) -> Node? {
            var node: Node? = self
            for name in path { node = node?.child(name) }
            return node
        }

        static func parse(_ data: Data) -> Node? {
            let builder = TreeBuilder()
            let parser = XMLParser(data: data)
            parser.delegate = builder
            parser.shouldResolveExternalEntities = false
            guard parser.parse() || builder.root != nil else { return nil }
            return builder.root
        }
    }

    private final class TreeBuilder: NSObject, XMLParserDelegate {
        var root: Node?
        private var stack: [Node] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String]) {
            let node = Node(name: elementName, attributes: attributeDict)
            if let parent = stack.last {
                parent.children.append(node)
            } else {
                root = node
            }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?) {
            if stack.last?.name == elementName { stack.removeLast() }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            appendText(string)
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            appendText(String(decoding: CDATABlock, as: UTF8.self))
        }

        private func appendText(_ string: String) {
            guard let parent = stack.last else { return }
            if let last = parent.children.last, last.name == "#text" {
                last.text += string
            } else {
                let node = Node(name: "#text", attributes: [:])
                node.text = string
                parent.children.append(node)
            }
        }
    }
}
