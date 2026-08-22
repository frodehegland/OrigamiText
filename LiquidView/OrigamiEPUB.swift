import CryptoKit
import Foundation

/// Export as an Origami Text EPUB — the format's EPUB 3 profile
/// (Origami Text EPUB — Implementation Specification v1.0, and
/// visual-meta.info/origami-text): a standard .epub constrained to one
/// semantic HTML content file, a navigation document, one optional
/// stylesheet, and Visual-Meta in two identical copies —
/// `visual-meta.json` in the package root and an embedded
/// `application/json` block in the HTML between human-readable
/// `@visual-meta-start` / `@visual-meta-end` markers.
///
/// Two identity systems, per the spec (§2): human-speakable addresses
/// (section 3's heading is `id="3"`, the elements beneath it `3B`,
/// `3C`, …) assigned at export, and stable ids carried in `data-id`,
/// which is how Map views keep pointing at the right things across
/// re-exports. Citations carry three mutually consistent encodings
/// generated from one internal model: the visible reference text,
/// `data-bibtex`, and `data-csl-json`.
nonisolated enum OrigamiEPUBExportError: LocalizedError {
    /// A generated XHTML document is not well-formed — export is refused so
    /// a broken EPUB (one that shows the reader an error page) never ships.
    case malformedContent(file: String, line: Int, column: Int, detail: String)

    var errorDescription: String? {
        switch self {
        case let .malformedContent(file, line, column, detail):
            "The exported \(file) was not valid XML (line \(line), column \(column): \(detail)). "
                + "This is a bug in Origami Text — please report it; the document was not exported."
        }
    }
}

nonisolated enum OrigamiEPUBExporter {

    // MARK: The Visual-Meta document (spec §4)

    /// The canonical payload. Encoded with JSONEncoder rather than
    /// JSONSerialization: floats keep their shortest round-trip form
    /// (-570.28, never -570.27999999999997), and slashes are escaped so
    /// "</script>" can never appear in the embedded copy.
    private struct VisualMetaDocument: Encodable {
        enum CodingKeys: String, CodingKey {
            case info = "visual-meta"
            case document, structure, concepts, citations, map, tables
        }

        struct Info: Encodable {
            let version = "1.0"
            let generator: String
            let introduction: String
        }

        struct DocumentInfo: Encodable {
            enum CodingKeys: String, CodingKey {
                case title, authors, date, identifier
                case origamiID = "origami-id"
                case abstract, keywords, isbn, doi, publication
            }

            let title: String
            let authors: [String]
            let date: String
            let identifier: String
            /// The journal or proceedings the document is part of, when
            /// it declares one — the reader's Journals view groups by it.
            var publication: String? = nil
            /// The document's library address, carried openly so a
            /// receiving Origami Text can keep the book's identity —
            /// citations to it then resolve wherever it arrives.
            let origamiID: String
            let abstract = ""
            let keywords: [String] = []
            let isbn = ""
            let doi = ""
        }

        struct Structure: Encodable {
            struct Heading: Encodable {
                let address: String
                let id: String
                let level: Int
                let text: String
            }
            let headings: [Heading]
        }

        struct ConceptNode: Encodable {
            let id: String
            let name: String
            let description: String
            let tag: String
            let urls: [String]
            let citationIdentifiers: [String]
            let address: String?
        }

        struct CitationNode: Encodable {
            let id: String
            let name: String
            let authors: [String]
            let year: String
            let publication: String
            let doi: String
            let urls: [String]
            /// The cited work's abstract, when the record carries one —
            /// the citation card's summary.
            let abstract: String
            let bibtex: String
            let csl: JSONValue
        }

        struct Map: Encodable {
            struct Node: Encodable {
                let id: String
                let label: String
                let kind: String
            }
            struct Connection: Encodable {
                let from: String
                let to: String
            }
            struct View: Encodable {
                struct Space: Encodable {
                    let units: String
                    let convention = "right-handed-y-up"
                }
                struct Position: Encodable {
                    let ref: String
                    let x: Double
                    let y: Double
                    let z: Double
                }
                let id: String
                let name: String
                let space: Space
                let nodes: [Position]
            }
            let nodes: [Node]
            let connections: [Connection]
            let views: [View]
        }

        /// One live table: values and formulas both, so the reader's
        /// grid recomputes — the same shape the importer reads back.
        struct TableNode: Encodable {
            struct Cell: Encodable {
                let value: String
                let formula: String?
            }
            let identifier: String
            let rowCount: Int
            let columnCount: Int
            let cells: [[Cell]]
        }

        let info: Info
        let document: DocumentInfo
        let structure: Structure
        let concepts: [ConceptNode]
        let citations: [CitationNode]
        let map: Map
        let tables: [TableNode]
    }

    /// A JSON fragment JSONEncoder can carry — used for the CSL object,
    /// which is assembled dynamically.
    private enum JSONValue: Encodable {
        case string(String)
        case number(Double)
        case bool(Bool)
        case array([JSONValue])
        case object([String: JSONValue])
        case null

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let value): try container.encode(value)
            case .number(let value): try container.encode(value)
            case .bool(let value): try container.encode(value)
            case .array(let value): try container.encode(value)
            case .object(let value): try container.encode(value)
            case .null: try container.encodeNil()
            }
        }

        static func from(_ any: Any) -> JSONValue {
            switch any {
            case let value as String: return .string(value)
            case let value as Bool: return .bool(value)
            case let value as NSNumber: return .number(value.doubleValue)
            case let value as [Any]: return .array(value.map(from))
            case let value as [String: Any]:
                return .object(value.mapValues(from))
            default: return .null
            }
        }
    }

    // MARK: The one citation model behind the three encodings

    private struct Citation {
        let number: Int          // [n] in body text
        let nodeID: String       // stable id in the Visual-Meta node pool
        let address: String?     // origami address, for internal citations
        let title: String
        let authors: [String]    // "Family, Given"
        let year: String
        let publication: String
        let doi: String
        let url: String?
        let bibtex: String?      // verbatim, when the link carried one

        var formatted: String {
            var parts: [String] = []
            if !authors.isEmpty { parts.append(authors.joined(separator: "; ")) }
            if !year.isEmpty { parts.append("(\(year)).") }
            if !title.isEmpty { parts.append("\(title).") }
            if !publication.isEmpty { parts.append("\(publication).") }
            if !doi.isEmpty { parts.append("https://doi.org/\(doi)") }
            else if let url { parts.append(url) }
            else if let address { parts.append("[\(address)]") }
            return parts.joined(separator: " ")
        }

        /// A BibTeX record even when the source link carried none, so
        /// `data-bibtex` and the JSON pool are never empty (spec R18).
        var bibtexRecord: String {
            if let bibtex { return bibtex }
            var fields = ["title = {\(title)}"]
            if !authors.isEmpty { fields.append("author = {\(authors.joined(separator: " and "))}") }
            if !year.isEmpty { fields.append("year = {\(year)}") }
            if !publication.isEmpty { fields.append("publisher = {\(publication)}") }
            if !doi.isEmpty { fields.append("doi = {\(doi)}") }
            if let url { fields.append("url = {\(url)}") }
            return "@misc{\(nodeID),\n\(fields.joined(separator: ",\n"))\n}"
        }

        /// The node for the Visual-Meta citations pool (spec §4.5).
        var node: VisualMetaDocument.CitationNode {
            var urls: [String] = []
            if let url { urls.append(url) }
            if let address { urls.append("origamitext://open/\(address)") }
            return VisualMetaDocument.CitationNode(
                id: nodeID, name: title, authors: authors, year: year,
                publication: publication, doi: doi, urls: urls,
                abstract: BibTeXParser.first(bibtexRecord)?.fields["abstract"] ?? "",
                bibtex: bibtexRecord, csl: JSONValue.from(cslJSON))
        }

        /// The CSL-JSON object for `data-csl-json` (spec C7).
        var cslJSON: [String: Any] {
            var object: [String: Any] = [
                "id": nodeID,
                "type": "article-journal",
                "title": title,
            ]
            if !authors.isEmpty {
                object["author"] = authors.map { name -> [String: String] in
                    let parts = name.split(separator: ",", maxSplits: 1)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                    if parts.count == 2 { return ["family": parts[0], "given": parts[1]] }
                    return ["family": name]
                }
            }
            if let yearNumber = Int(year) {
                object["issued"] = ["date-parts": [[yearNumber]]]
            }
            if !publication.isEmpty { object["container-title"] = publication }
            if !doi.isEmpty { object["DOI"] = doi }
            if let url { object["URL"] = url }
            return object
        }
    }

    // MARK: The addressed body (spec §2, §3.1)

    /// One body element with its assigned address: headings carry the
    /// bare section number, the elements beneath them letters — "3",
    /// then "3B", "3C", … The heading itself is implicitly "A".
    private struct AddressedElement {
        let paragraph: LiquidDoc.Paragraph
        let address: String
        let headingLevel: Int?   // resolved level, when this is a heading
        let text: String         // text with any markdown heading stripped
        let opensSection: Bool
    }

    private static func addressedBody(of doc: LiquidDoc) -> [AddressedElement] {
        var elements: [AddressedElement] = []
        var sectionNumber = 0
        var elementOrdinal = 1   // the heading is element "A"

        func letters(_ ordinal: Int) -> String {
            var n = ordinal
            var out = ""
            while n > 0 {
                out = String(UnicodeScalar(UInt8(65 + (n - 1) % 26))) + out
                n = (n - 1) / 26
            }
            return out
        }

        for paragraph in doc.body ?? [] {
            var text = paragraph.text
            var level = paragraph.heading
            if let markdown = LiquidDoc.markdownHeading(in: text) {
                level = level ?? markdown.level
                text = markdown.text
            }
            if let level, (1...3).contains(level) {
                sectionNumber += 1
                elementOrdinal = 1
                elements.append(AddressedElement(
                    paragraph: paragraph, address: "\(sectionNumber)",
                    headingLevel: level, text: text, opensSection: true))
            } else {
                let opens = sectionNumber == 0
                if opens { sectionNumber = 1; elementOrdinal = 1 }
                elementOrdinal += 1
                elements.append(AddressedElement(
                    paragraph: paragraph,
                    address: "\(sectionNumber)\(letters(elementOrdinal))",
                    headingLevel: nil, text: text, opensSection: opens))
            }
        }
        return elements
    }

    // MARK: Entry point

    /// Writes `doc` as a `.epub` at `url`. `resolve` answers an origami
    /// address with the library's document, so internal citations gain
    /// their titles and authors.
    static func write(doc: LiquidDoc, resolve: (String) -> LiquidDoc?, to url: URL) throws {
        let citations = gatherCitations(from: doc, resolve: resolve)
        let body = addressedBody(of: doc)

        // Headings resolve to their stable ids through the concept pool:
        // Author's heading-concepts reuse the headings' Map-node UUIDs.
        var headingID: [String: String] = [:]
        for concept in doc.concepts where concept.tag == "heading" {
            headingID[concept.name.trimmingCharacters(in: .whitespaces).lowercased()] = concept.id
        }
        func stableID(for element: AddressedElement) -> String {
            headingID[element.text.trimmingCharacters(in: .whitespaces).lowercased()]
                ?? element.paragraph.id
        }

        let headings = body.filter { $0.headingLevel != nil }.map { element in
            VisualMetaDocument.Structure.Heading(
                address: element.address, id: stableID(for: element),
                level: element.headingLevel ?? 1, text: element.text)
        }
        var addressByStableID: [String: String] = [:]
        for heading in headings {
            addressByStableID[heading.id] = heading.address
        }

        // The Map's node pool is the concepts and citations themselves —
        // same ids, so view positions resolve (spec J3–J4).
        var nodes: [VisualMetaDocument.Map.Node] = doc.concepts.map { concept in
            VisualMetaDocument.Map.Node(
                id: concept.id, label: concept.name,
                kind: concept.tag == "heading" ? "heading" : "concept")
        }
        nodes.append(contentsOf: citations.map {
            VisualMetaDocument.Map.Node(id: $0.nodeID, label: $0.title, kind: "citation")
        })

        let visualMeta = VisualMetaDocument(
            info: VisualMetaDocument.Info(
                generator: "Origami Text (LiquidView)",
                introduction: "This is Visual-Meta: the document's intellectual structure — its concepts, its citations, and any spatial layouts — carried with the document itself, readable by people and machines alike. See https://visual-meta.info."),
            document: VisualMetaDocument.DocumentInfo(
                title: doc.title,
                authors: [doc.displayAuthor],
                date: documentDate(of: doc),
                identifier: identifier(of: doc),
                publication: doc.publication,
                origamiID: doc.id),
            structure: VisualMetaDocument.Structure(headings: headings),
            concepts: doc.concepts.map { concept in
                VisualMetaDocument.ConceptNode(
                    id: concept.id, name: concept.name,
                    description: concept.description,
                    tag: concept.tag ?? "concept",
                    urls: concept.urls,
                    citationIdentifiers: concept.citationIdentifiers,
                    address: concept.tag == "heading" ? addressByStableID[concept.id] : nil)
            },
            citations: citations.map(\.node),
            map: VisualMetaDocument.Map(
                nodes: nodes,
                connections: doc.mapConnections.map {
                    VisualMetaDocument.Map.Connection(from: $0.from, to: $0.to)
                },
                views: doc.layouts.map { layout in
                    VisualMetaDocument.Map.View(
                        id: layout.sourceID ?? stableUUID(from: "\(doc.id):view:\(layout.index)"),
                        name: layout.name,
                        space: VisualMetaDocument.Map.View.Space(units: "points"),
                        nodes: layout.positions.map {
                            VisualMetaDocument.Map.View.Position(ref: $0.id, x: $0.x, y: $0.y, z: $0.z)
                        })
                }),
            tables: doc.tables.map { table in
                VisualMetaDocument.TableNode(
                    identifier: table.identifier,
                    rowCount: table.rowCount,
                    columnCount: table.columnCount,
                    cells: table.cells.map { row in
                        row.map { VisualMetaDocument.TableNode.Cell(value: $0.value,
                                                                    formula: $0.formula) }
                    })
            })

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let visualMetaData = try encoder.encode(visualMeta)
        let visualMetaText = String(decoding: visualMetaData, as: UTF8.self)

        // Images the body actually references become files in the package
        // and items in the manifest; the markers become <figure><img>.
        let assetsByID = Dictionary(doc.assets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var referencedAssets: [LiquidDoc.Asset] = []
        var seenAssetIDs: Set<String> = []
        for element in body {
            guard let reference = LiquidDoc.imageReference(in: element.paragraph.text),
                  let asset = assetsByID[reference.id],
                  seenAssetIDs.insert(asset.id).inserted else { continue }
            referencedAssets.append(asset)
        }

        let html = paperHTML(doc: doc, body: body, citations: citations,
                             stableID: stableID, visualMetaText: visualMetaText,
                             assetsByID: assetsByID)
        let nav = navHTML(doc: doc, headings: headings)

        // Self-check: the content documents are served as XHTML, so a stray
        // unescaped character would show the reader an error page. Refuse to
        // ship one — validate before writing anything.
        try assertWellFormed(html, file: "content/paper.html")
        try assertWellFormed(nav, file: "content/nav.html")

        var zip = ZipWriter()
        // The mimetype must be the first entry, uncompressed — every
        // entry here is stored, which is legal EPUB and keeps the
        // writer honest and small.
        zip.add("mimetype", Data("application/epub+zip".utf8))
        zip.add("META-INF/container.xml", Data(containerXML.utf8))
        zip.add("package.opf", Data(packageOPF(doc: doc, images: referencedAssets).utf8))
        zip.add("content/paper.html", Data(html.utf8))
        zip.add("content/nav.html", Data(nav.utf8))
        zip.add("content/style.css", Data(styleCSS.utf8))
        for asset in referencedAssets {
            if let data = asset.data { zip.add("content/images/\(asset.filename)", data) }
        }
        zip.add("visual-meta.json", visualMetaData)
        try zip.finished().write(to: url, options: .atomic)
    }

    /// The document's date as YYYY-MM-DD: the human-assigned date when
    /// there is one, the creation date otherwise.
    private static func documentDate(of doc: LiquidDoc) -> String {
        if let date = doc.date { return date.isoString }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return String(formatter.string(from: doc.created).prefix(10))
    }

    /// A stable urn:uuid identifier (spec P6), derived deterministically
    /// from the document's origami address so the same document exports
    /// to the same identifier every time.
    private static func identifier(of doc: LiquidDoc) -> String {
        "urn:uuid:\(stableUUID(from: doc.id))"
    }

    private static func stableUUID(from seed: String) -> String {
        var bytes = Array(SHA256.hash(data: Data("origami-text:\(seed)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50   // version 5-style
        bytes[8] = (bytes[8] & 0x3F) | 0x80   // RFC 4122 variant
        let hex = bytes.map { String(format: "%02X", $0) }.joined()
        func slice(_ from: Int, _ to: Int) -> Substring {
            hex[hex.index(hex.startIndex, offsetBy: from)..<hex.index(hex.startIndex, offsetBy: to)]
        }
        return "\(slice(0, 8))-\(slice(8, 12))-\(slice(12, 16))-\(slice(16, 20))-\(slice(20, 32))"
    }

    // MARK: Citations

    /// One citation per cited document, numbered by first appearance in
    /// the body; links the body never mentions follow after.
    private static func gatherCitations(from doc: LiquidDoc,
                                        resolve: (String) -> LiquidDoc?) -> [Citation] {
        var appearance: [String] = []
        for paragraph in doc.body ?? [] {
            for match in LiquidAddress.matches(in: paragraph.text)
            where !appearance.contains(match.id) {
                appearance.append(match.id)
            }
        }
        var targets: [String] = []
        for link in doc.links where !targets.contains(link.to) {
            targets.append(link.to)
        }
        targets.sort { lhs, rhs in
            let left = appearance.firstIndex(of: lhs) ?? .max
            let right = appearance.firstIndex(of: rhs) ?? .max
            return left == right ? lhs < rhs : left < right
        }

        var citations: [Citation] = targets.enumerated().map { position, target in
            let bibtex = doc.links.first { $0.to == target && $0.bibtex != nil }?.bibtex
            if let bibtex, let entry = BibTeXParser.parse(bibtex).first {
                // The address is the stable id — never a fresh UUID, so
                // re-exports keep their identities (spec §2).
                return citation(number: position + 1, nodeID: target,
                                address: target, entry: entry, bibtex: bibtex)
            }
            let resolved = resolve(target)
            return Citation(
                number: position + 1,
                nodeID: target,
                address: target,
                title: resolved?.title ?? target,
                authors: resolved.map { [familyFirst($0.author)] } ?? [],
                year: resolved.map { String(Calendar.current.component(.year, from: $0.created)) } ?? "",
                publication: "",
                doi: "",
                url: nil,
                bibtex: nil)
        }

        // The document's own citation records join the pool after the
        // linked ones, keeping their stable ids — concepts'
        // citationIdentifiers and Map view positions point at these.
        for reference in doc.references {
            guard let entry = BibTeXParser.parse(reference.bibtex).first else { continue }
            citations.append(citation(number: citations.count + 1,
                                      nodeID: reference.id,
                                      address: nil,
                                      entry: entry,
                                      bibtex: reference.bibtex))
        }
        return citations
    }

    private static func citation(number: Int, nodeID: String, address: String?,
                                 entry: BibTeXEntry, bibtex: String) -> Citation {
        let authors = (entry.fields["author"] ?? "")
            .components(separatedBy: " and ")
            .map { familyFirst($0) }
            .filter { !$0.isEmpty }
        return Citation(
            number: number,
            nodeID: nodeID,
            address: address,
            title: entry.title ?? nodeID,
            authors: authors,
            year: entry.year ?? "",
            publication: entry.fields["journal"] ?? entry.fields["booktitle"]
                ?? entry.fields["publisher"] ?? "",
            doi: entry.fields["doi"] ?? "",
            url: entry.fields["url"],
            bibtex: bibtex)
    }

    /// "Frode Hegland" → "Hegland, Frode"; "Hegland, Frode" stays.
    private static func familyFirst(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.contains(","), trimmed.contains(" ") else { return trimmed }
        let words = trimmed.split(separator: " ").map(String.init)
        guard let family = words.last else { return trimmed }
        return "\(family), \(words.dropLast().joined(separator: " "))"
    }

    // MARK: The content document (spec §3)

    private static func paperHTML(doc: LiquidDoc, body: [AddressedElement],
                                  citations: [Citation],
                                  stableID: (AddressedElement) -> String,
                                  visualMetaText: String,
                                  assetsByID: [String: LiquidDoc.Asset]) -> String {
        var lines: [String] = []
        lines.append("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en" lang="en">
        <head>
          <meta charset="utf-8" />
          <title>\(escaped(doc.title))</title>
          <link rel="stylesheet" type="text/css" href="style.css" />
        </head>
        <body>
        <header>
          <h1>\(escaped(doc.title))</h1>
          <p class="byline">\(escaped(byline(for: doc)))</p>
        </header>
        <main>
        """)

        // Defined concepts get their first occurrence wrapped in <dfn>
        // (spec C5) — the definition itself lives only in the JSON.
        var pendingConcepts = doc.concepts.filter { $0.tag != "heading" }.map(\.name)
        let tablesByID = Dictionary(doc.tables.map { ($0.identifier, $0) },
                                    uniquingKeysWith: { first, _ in first })
        var sectionOpen = false
        // Stretchtext ships as Author writes it: the contracted detail —
        // consecutive paragraphs sharing a stretchID — wrapped in a
        // hidden <aside class="ot-stretchtext-content">, with the »»
        // marker anchor riding at the end of the host paragraph before
        // it. Plain readers show just the marker; Origami readers (and
        // this app's own WebView script) make it a live fold.
        var openStretchID: String?
        func closeStretch() {
            if openStretchID != nil {
                lines.append("</aside>")
                openStretchID = nil
            }
        }
        for element in body {
            let stretchID = element.paragraph.stretchID
            if stretchID != openStretchID { closeStretch() }
            if element.opensSection {
                closeStretch()
                if sectionOpen { lines.append("</section>") }
                lines.append("<section>")
                sectionOpen = true
            }
            var html = self.element(for: element, citations: citations,
                                    stableID: stableID, assetsByID: assetsByID,
                                    tablesByID: tablesByID)
            for name in pendingConcepts {
                if let wrapped = wrappingFirstOccurrence(of: name, in: html) {
                    html = wrapped
                    pendingConcepts.removeAll { $0 == name }
                }
            }
            if let stretchID, stretchID != openStretchID {
                let escapedID = attributeEscaped(stretchID)
                let marker = "<a class=\"ot-stretchtext\" href=\"#\(escapedID)\""
                    + " role=\"button\" aria-controls=\"\(escapedID)\""
                    + " aria-expanded=\"false\">\u{00BB}\u{00BB}</a>"
                // The toggle rides inline at the end of the paragraph the
                // stretch follows — where Author writes it. A stretch with
                // no host paragraph carries the marker on a line of its own.
                if let lastIndex = lines.indices.last, lines[lastIndex].hasSuffix("</p>") {
                    lines[lastIndex] = String(lines[lastIndex].dropLast("</p>".count))
                        + " " + marker + "</p>"
                } else {
                    lines.append("<p>\(marker)</p>")
                }
                lines.append("<aside class=\"ot-stretchtext-content\" id=\"\(escapedID)\" hidden=\"hidden\">")
                openStretchID = stretchID
            }
            lines.append(html)
        }
        closeStretch()
        if sectionOpen { lines.append("</section>") }
        lines.append("</main>")

        if !citations.isEmpty {
            lines.append("<section id=\"references\">")
            lines.append("<h2>References</h2>")
            lines.append("<ol>")
            for citation in citations {
                let bibtexAttribute = attributeEscaped(citation.bibtexRecord)
                let cslData = (try? JSONSerialization.data(
                    withJSONObject: citation.cslJSON, options: [.sortedKeys])) ?? Data()
                let cslAttribute = attributeEscaped(String(decoding: cslData, as: UTF8.self))
                lines.append("<li id=\"ref-\(citation.number)\" data-bibtex=\"\(bibtexAttribute)\" data-csl-json=\"\(cslAttribute)\">\(escaped(citation.formatted))</li>")
            }
            lines.append("</ol>")
            lines.append("</section>")
        }

        // The JSON payload is wrapped in CDATA: paper.html is served as
        // XHTML, where <script> content is parsed, so a bare & or < in the
        // Visual-Meta (e.g. a heading "Further reading & resources") would
        // otherwise break well-formedness. Any literal "]]>" in the JSON is
        // split so it cannot close the section early.
        let safePayload = visualMetaText.replacingOccurrences(of: "]]>", with: "]]]]><![CDATA[>")
        lines.append("""
        <section id="visual-meta">
        <h2>Visual-Meta</h2>
        <p>The following is the metadata for this document, presented here for robust, long term preservation.</p>
        <p>@visual-meta-start</p>
        <script type="application/json" id="visual-meta-payload">
        <![CDATA[
        \(safePayload)
        ]]>
        </script>
        <p>@visual-meta-end</p>
        </section>
        </body>
        </html>
        """)
        return lines.joined(separator: "\n")
    }

    private static func byline(for doc: LiquidDoc) -> String {
        var parts = [doc.displayAuthor]
        parts.append(doc.date?.displayText
            ?? doc.created.formatted(date: .long, time: .omitted))
        if let location = doc.location { parts.append(location) }
        return parts.joined(separator: " · ")
    }

    /// One element, carrying its address as the anchor (spec A1) and its
    /// stable id in `data-id` (spec A2) — the paragraph's own id, or the
    /// heading's Map-node UUID when the concept pool knows it.
    private static func element(for element: AddressedElement,
                                citations: [Citation],
                                stableID: (AddressedElement) -> String,
                                assetsByID: [String: LiquidDoc.Asset],
                                tablesByID: [String: LiquidDoc.Table] = [:]) -> String {
        let paragraph = element.paragraph
        let trimmed = paragraph.text.trimmingCharacters(in: .whitespaces)
        let anchors = "id=\"\(element.address)\" data-id=\"\(escaped(stableID(element)))\""
        // An image marker `![alt](asset:id)` becomes a <figure><img>, its
        // bytes written alongside as content/images/<file>.
        if let reference = LiquidDoc.imageReference(in: paragraph.text),
           let asset = assetsByID[reference.id] {
            let alt = reference.alt.isEmpty ? (asset.alt ?? "") : reference.alt
            return "<figure \(anchors)><img src=\"images/\(attributeEscaped(asset.filename))\" alt=\"\(attributeEscaped(alt))\" /></figure>"
        }
        // A live table renders as a real grid, its `data-table-id` tying
        // the placement to the Visual-Meta tables entry (values and
        // formulas) so the import recovers it whole; the paragraph's
        // pipe-text stays behind only for readers without table support.
        if let tableID = paragraph.tableID, let table = tablesByID[tableID] {
            let rows = table.cells.enumerated().map { rowIndex, row -> String in
                let tag = rowIndex == 0 && table.cells.count > 1 ? "th" : "td"
                let cells = row.map { "<\(tag)>\(escaped($0.value))</\(tag)>" }.joined()
                return "<tr>\(cells)</tr>"
            }
            return "<table \(anchors) data-table-id=\"\(attributeEscaped(table.identifier))\">"
                + rows.joined() + "</table>"
        }
        if trimmed.count >= 3, trimmed.allSatisfy({ $0 == "-" }) {
            return "<hr \(anchors) />"
        }
        let inline = inlineHTML(from: element.text, citations: citations)
        if let level = element.headingLevel {
            return "<h\(level + 1) \(anchors)>\(inline)</h\(level + 1)>"
        }
        if let speaker = paragraph.speaker, element.text.hasPrefix("\(speaker):") {
            let rest = inlineHTML(from: String(element.text.dropFirst(speaker.count + 1)),
                                  citations: citations)
            return "<p \(anchors)><strong class=\"speaker\">\(escaped(speaker)):</strong>\(rest)</p>"
        }
        return "<p \(anchors)>\(inline)</p>"
    }

    /// Escapes the text, then layers the inline conventions: markdown
    /// code/bold/italic/links, and bracketed origami addresses as the
    /// profile's numbered citation markers, linked to References with
    /// their stable citation id (spec C6).
    private static func inlineHTML(from text: String, citations: [Citation]) -> String {
        var html = escaped(text)
        html = html.replacingOccurrences(of: "`([^`]+)`", with: "<code>$1</code>",
                                         options: .regularExpression)
        html = html.replacingOccurrences(of: "\\*\\*([^*]+)\\*\\*", with: "<strong>$1</strong>",
                                         options: .regularExpression)
        html = html.replacingOccurrences(of: "\\*([^*]+)\\*", with: "<em>$1</em>",
                                         options: .regularExpression)
        html = html.replacingOccurrences(
            of: "\\[([^\\]]+)\\]\\((https?://[^)\\s]+)\\)",
            with: "<a href=\"$2\">$1</a>", options: .regularExpression)
        // Note tokens become dagger anchors, their href carrying the
        // note's stable id: [inote:] the in-place stretchtext kind
        // (class ot-inline-note), [note:] the plain endnote mark. Both
        // point at the Notes paragraphs the body closes with; the
        // importer reads the fragment back into the same token.
        html = html.replacingOccurrences(
            of: "\\[inote:([A-Za-z0-9._:-]+)\\]",
            with: "<a class=\"ot-inline-note\" role=\"doc-noteref\" href=\"#$1\">\u{2021}</a>",
            options: .regularExpression)
        html = html.replacingOccurrences(
            of: "\\[note:([A-Za-z0-9._:-]+)\\]",
            with: "<a role=\"doc-noteref\" href=\"#$1\">\u{2021}</a>",
            options: .regularExpression)
        for citation in citations {
            guard let address = citation.address else {
                // An external reference, cited by its BibTeX key — the
                // LaTeX import's `[cite:key]` tokens. The anchor is the
                // profile's numbered marker, linked to the References
                // entry, its key carried in data-citation-id so a
                // re-import recovers the token.
                let pattern = "\\[cite:\(NSRegularExpression.escapedPattern(for: citation.nodeID))\\]"
                html = html.replacingOccurrences(
                    of: pattern,
                    with: "<a class=\"citation\" href=\"#ref-\(citation.number)\" data-citation-id=\"\(attributeEscaped(citation.nodeID))\">[\(citation.number)]</a>",
                    options: .regularExpression)
                continue
            }
            // The anchor keeps the reference exactly as written —
            // typed rel and #fragment included — in data-origami-ref,
            // so a reader restores the full-resolution address.
            let pattern = "\\[([a-z-]+:)?\(NSRegularExpression.escapedPattern(for: address))(#[A-Za-z0-9._-]+)?\\]"
            html = html.replacingOccurrences(
                of: pattern,
                with: "<a class=\"citation\" href=\"#ref-\(citation.number)\" data-citation-id=\"\(citation.nodeID)\" data-origami-ref=\"$1\(address)$2\">[\(citation.number)]</a>",
                options: [.regularExpression, .caseInsensitive])
        }
        // A cite token whose key the pool does not know degrades to the
        // bracketed key — legible, and honest about the gap.
        html = html.replacingOccurrences(of: "\\[cite:([^\\]]+)\\]", with: "[$1]",
                                         options: .regularExpression)
        return html
    }

    /// Wraps the first occurrence of `name` outside any tag in a
    /// `<dfn data-concept>` — nil when the text never mentions it.
    private static func wrappingFirstOccurrence(of name: String, in html: String) -> String? {
        let pattern = "\\b(\(NSRegularExpression.escapedPattern(for: name)))\\b(?![^<]*>)"
        guard let expression = try? NSRegularExpression(pattern: pattern,
                                                        options: [.caseInsensitive]),
              let match = expression.firstMatch(
                  in: html, options: [],
                  range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else { return nil }
        let occurrence = html[range]
        return html.replacingCharacters(
            in: range,
            with: "<dfn data-concept=\"\(escaped(name))\">\(occurrence)</dfn>")
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Throws unless `xhtml` is well-formed XML — the guarantee that an
    /// exported content document never shows the reader an XML error page.
    /// Uses `XMLParser` (Foundation, every platform), which reports the
    /// offending line and column on failure.
    private static func assertWellFormed(_ xhtml: String, file: String) throws {
        let parser = XMLParser(data: Data(xhtml.utf8))
        parser.shouldResolveExternalEntities = false
        if !parser.parse() {
            throw OrigamiEPUBExportError.malformedContent(
                file: file,
                line: parser.lineNumber,
                column: parser.columnNumber,
                detail: parser.parserError?.localizedDescription ?? "not well-formed")
        }
    }

    private static func attributeEscaped(_ text: String) -> String {
        escaped(text)
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "\n", with: "&#10;")
    }

    // MARK: Package scaffolding

    private static let containerXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
      <rootfiles>
        <rootfile full-path="package.opf" media-type="application/oebps-package+xml"/>
      </rootfiles>
    </container>
    """

    /// The EPUB 3 navigation document (spec §5), from the headings.
    private static func navHTML(doc: LiquidDoc,
                                headings: [VisualMetaDocument.Structure.Heading]) -> String {
        let items = headings.isEmpty
            ? "<li><a href=\"paper.html\">\(escaped(doc.title))</a></li>"
            : headings.map {
                "<li><a href=\"paper.html#\($0.address)\">\(escaped($0.text))</a></li>"
            }.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="en" lang="en">
        <head>
          <meta charset="utf-8" />
          <title>\(escaped(doc.title))</title>
        </head>
        <body>
        <nav epub:type="toc" role="doc-toc">
        <h1>Contents</h1>
        <ol>
        \(items)
        </ol>
        </nav>
        </body>
        </html>
        """
    }

    private static func packageOPF(doc: LiquidDoc, images: [LiquidDoc.Asset]) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let modified = formatter.string(from: Date())
        let imageItems = images.enumerated().map { index, asset in
            "        <item id=\"img\(index + 1)\" href=\"content/images/\(attributeEscaped(asset.filename))\" media-type=\"\(asset.mediaType)\"/>"
        }.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="pub-id" xml:lang="en">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="pub-id">\(escaped(identifier(of: doc)))</dc:identifier>
            <dc:title>\(escaped(doc.title))</dc:title>
            <dc:creator>\(escaped(doc.displayAuthor))</dc:creator>
            <dc:language>en</dc:language>
            <dc:date>\(documentDate(of: doc))</dc:date>
            <meta property="dcterms:modified">\(modified)</meta>
          </metadata>
          <manifest>
            <item id="paper" href="content/paper.html" media-type="application/xhtml+xml"/>
            <item id="nav" href="content/nav.html" media-type="application/xhtml+xml" properties="nav"/>
            <item id="css" href="content/style.css" media-type="text/css"/>
            <item id="visual-meta" href="visual-meta.json" media-type="application/json"/>
        \(imageItems)
          </manifest>
          <spine>
            <itemref idref="paper"/>
          </spine>
        </package>
        """
    }

    /// The optional presentation layer: relative units only, nothing
    /// the profile forbids.
    private static let styleCSS = """
    body { font-family: Georgia, serif; line-height: 1.5; margin: 6% 12%; }
    header h1 { font-size: 1.8em; margin-bottom: 0.2em; }
    .byline { color: #555555; font-style: italic; margin-top: 0; }
    h2 { font-size: 1.4em; margin-top: 1.6em; }
    h3 { font-size: 1.2em; }
    h4 { font-size: 1.05em; }
    .speaker { font-weight: bold; }
    figure { margin-left: 0; margin-right: 0; }
    figure img { max-width: 100%; height: auto; }
    a.citation { text-decoration: none; }
    dfn { font-style: normal; border-bottom: 0.08em dotted #999999; }
    #references li { margin-bottom: 0.6em; }
    #visual-meta { font-size: 0.8em; color: #777777; margin-top: 3em; }
    hr { border: 0; border-top: 0.1em solid #cccccc; margin: 2em 0; }
    """
}

// MARK: - The container

/// A minimal store-only ZIP writer — everything EPUB needs and nothing
/// more. Store-only is legal EPUB, keeps the writer verifiable, and the
/// profile's contents are small text files. The mimetype entry must be
/// added first.
private struct ZipWriter {

    private struct Entry {
        let name: Data
        let crc: UInt32
        let size: UInt32
        let offset: UInt32
    }

    private var body = Data()
    private var entries: [Entry] = []

    mutating func add(_ name: String, _ contents: Data) {
        let nameBytes = Data(name.utf8)
        let entry = Entry(name: nameBytes,
                          crc: Self.crc32(contents),
                          size: UInt32(contents.count),
                          offset: UInt32(body.count))
        entries.append(entry)
        body.appendLE32(0x0403_4b50)          // local file header
        body.appendLE16(20)                   // version needed
        body.appendLE16(0)                    // flags
        body.appendLE16(0)                    // method: store
        body.appendLE16(0)                    // DOS time
        body.appendLE16(0x21)                 // DOS date (1980-01-01)
        body.appendLE32(entry.crc)
        body.appendLE32(entry.size)           // compressed
        body.appendLE32(entry.size)           // uncompressed
        body.appendLE16(UInt16(nameBytes.count))
        body.appendLE16(0)                    // extra length
        body.append(nameBytes)
        body.append(contents)
    }

    func finished() -> Data {
        var out = body
        let directoryOffset = UInt32(out.count)
        for entry in entries {
            out.appendLE32(0x0201_4b50)       // central directory header
            out.appendLE16(20)                // version made by
            out.appendLE16(20)                // version needed
            out.appendLE16(0)                 // flags
            out.appendLE16(0)                 // method: store
            out.appendLE16(0)                 // DOS time
            out.appendLE16(0x21)              // DOS date
            out.appendLE32(entry.crc)
            out.appendLE32(entry.size)
            out.appendLE32(entry.size)
            out.appendLE16(UInt16(entry.name.count))
            out.appendLE16(0)                 // extra
            out.appendLE16(0)                 // comment
            out.appendLE16(0)                 // disk number
            out.appendLE16(0)                 // internal attributes
            out.appendLE32(0)                 // external attributes
            out.appendLE32(entry.offset)
            out.append(entry.name)
        }
        let directorySize = UInt32(out.count) - directoryOffset
        out.appendLE32(0x0605_4b50)           // end of central directory
        out.appendLE16(0)                     // this disk
        out.appendLE16(0)                     // directory disk
        out.appendLE16(UInt16(entries.count))
        out.appendLE16(UInt16(entries.count))
        out.appendLE32(directorySize)
        out.appendLE32(directoryOffset)
        out.appendLE16(0)                     // comment length
        return out
    }

    /// Standard CRC-32 (the ZIP/zlib polynomial), table-driven.
    private static let crcTable: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
        }
        return value
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func appendLE16(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8(value >> 8))
    }

    mutating func appendLE32(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
