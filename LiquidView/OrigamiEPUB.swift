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
    /// An internal anchor points at an id no element carries — export is
    /// refused so a dead link (a footnote dagger that goes nowhere in a
    /// standard reader, the HT '26 lesson) never ships.
    case danglingAnchor(file: String, target: String)

    var errorDescription: String? {
        switch self {
        case let .malformedContent(file, line, column, detail):
            "The exported \(file) was not valid XML (line \(line), column \(column): \(detail)). "
                + "This is a bug in Origami Text — please report it; the document was not exported."
        case let .danglingAnchor(file, target):
            "The exported \(file) links to #\(target), but no element carries that id. "
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
                case title, subtitle, authors, date, identifier
                case origamiID = "origami-id"
                case abstract, keywords, isbn, doi, publication
                case affiliations
                case acmReference = "acm-reference"
                case authorORCIDs = "author-orcids"
                case authorEmails = "author-emails"
                case authorAffiliations = "author-affiliations"
                case license
            }

            let title: String
            /// The paper's subtitle, apart from the title.
            var subtitle: String? = nil
            let authors: [String]
            let date: String
            let identifier: String
            /// The printed affiliations, for the front matter a
            /// receiving reader may rebuild.
            var affiliations: [String] = []
            /// The paper's ACM Reference Format, verbatim.
            var acmReference: String? = nil
            /// Each author's ORCID, keyed by name.
            var authorORCIDs: [String: String] = [:]
            /// Each author's email, keyed by name.
            var authorEmails: [String: String] = [:]
            /// Each author's affiliation line, keyed by name.
            var authorAffiliations: [String: String] = [:]
            /// The license/copyright block, verbatim.
            var license: String? = nil
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
            var doi = ""
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
                subtitle: doc.subtitle,
                authors: [doc.displayAuthor],
                date: documentDate(of: doc),
                identifier: identifier(of: doc),
                affiliations: doc.affiliations,
                acmReference: doc.acmReference,
                authorORCIDs: doc.authorORCIDs,
                authorEmails: doc.authorEmails,
                authorAffiliations: doc.authorAffiliations,
                license: doc.license,
                publication: doc.publication,
                origamiID: doc.id,
                doi: doc.doi ?? ""),
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
        // Drives the schema:alternativeText / accessModeSufficient=textual
        // claims: one rendered <img> without a non-empty alt withdraws both.
        var allImagesHaveAltText = true
        for element in body {
            guard let reference = LiquidDoc.imageReference(in: element.paragraph.text),
                  let asset = assetsByID[reference.id] else { continue }
            // The same alt the <figure><img> will carry — see element(for:).
            let alt = reference.alt.isEmpty ? (asset.alt ?? "") : reference.alt
            if alt.trimmingCharacters(in: .whitespaces).isEmpty { allImagesHaveAltText = false }
            guard seenAssetIDs.insert(asset.id).inserted else { continue }
            referencedAssets.append(asset)
        }

        let html = paperHTML(doc: doc, body: body, citations: citations,
                             stableID: stableID, visualMetaText: visualMetaText,
                             assetsByID: assetsByID)
        let nav = navHTML(doc: doc, headings: headings)

        // Self-check: the content documents are served as XHTML, so a stray
        // unescaped character would show the reader an error page. Refuse to
        // ship one — validate before writing anything. The same bar for
        // anchors: every internal href must land on a real id, in this
        // document and from the navigation document into it.
        try assertWellFormed(html, file: "content/paper.html")
        try assertWellFormed(nav, file: "content/nav.html")
        try assertAnchorsResolve(in: html, file: "content/paper.html")
        try assertAnchorsResolve(in: nav, file: "content/nav.html", targetsIn: html)

        // Derived from the actual output, never boilerplate: escaped text
        // renders "<math" as "&lt;math", so the substring only matches a
        // real MathML element.
        let accessibility = AccessibilityFacts(
            hasImages: !referencedAssets.isEmpty,
            allImagesHaveAltText: allImagesHaveAltText,
            contentHasMathML: html.contains("<math"),
            hasSectionHeadings: !headings.isEmpty)

        var zip = ZipWriter()
        // The mimetype must be the first entry, uncompressed — every
        // entry here is stored, which is legal EPUB and keeps the
        // writer honest and small.
        zip.add("mimetype", Data("application/epub+zip".utf8))
        zip.add("META-INF/container.xml", Data(containerXML.utf8))
        zip.add("package.opf", Data(packageOPF(doc: doc, images: referencedAssets,
                                               facts: accessibility).utf8))
        zip.add("content/paper.html", Data(html.utf8))
        zip.add("content/nav.html", Data(nav.utf8))
        zip.add("content/style.css", Data(styleCSS.utf8))
        for asset in referencedAssets {
            if let data = asset.data { zip.add("content/images/\(asset.filename)", data) }
        }
        if doc.license?.contains("Creative Commons") == true,
           let badge = Data(base64Encoded: ccBadgePNGBase64) {
            zip.add("content/images/cc-by.png", badge)
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
        // A linked work that already stands in the reference list is one
        // work — the reference keeps its printed number. Minting a second
        // citation for the link doubled a round-tripped reference list
        // (32 entries came back as 63): the import rebuilds links from
        // resolvable citation anchors, and each carried the same BibTeX
        // its reference already holds.
        let referenceBibs = Set(doc.references.map { normalizedBibTeX($0.bibtex) })
        var targets: [String] = []
        for link in doc.links where !targets.contains(link.to) {
            if let bibtex = link.bibtex,
               referenceBibs.contains(normalizedBibTeX(bibtex)) { continue }
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
        // Display fields are TeX-cleaned here, at the source: the visible
        // reference line, the Visual-Meta pool, and the CSL-JSON all read
        // "Luís Borges" while data-bibtex keeps the raw record verbatim.
        // A braced literal name ({Resemble AI}) prints whole, as the
        // paper does — inverting it misnames the organisation.
        func displayNames(field: String) -> [String] {
            let literalAware = BibTeXParser.authorNames(inRaw: bibtex, field: field)
            let names = literalAware.isEmpty
                ? (entry.fields[field] ?? "")
                    .components(separatedBy: " and ")
                    .map { familyFirst(BibTeXParser.displayText($0)) }
                    .filter { !$0.isEmpty }
                : literalAware
                    .map { name in
                        let display = BibTeXParser.displayText(name.name)
                        return name.isLiteral ? display : familyFirst(display)
                    }
                    .filter { !$0.isEmpty }
            return names
        }
        var authors = displayNames(field: "author")
        // An edited volume has no authors — the editors stand in, marked
        // as print marks them ("Jessica Rubart and Claus Atzenbeck
        // (Eds.)"); without this the line opened bare at the year.
        if authors.isEmpty {
            authors = displayNames(field: "editor")
            if !authors.isEmpty {
                authors[authors.count - 1] += " (Eds.)"
            }
        }
        return Citation(
            number: number,
            nodeID: nodeID,
            address: address,
            title: BibTeXParser.displayText(entry.title ?? nodeID),
            authors: authors,
            year: BibTeXParser.displayText(entry.year ?? ""),
            publication: BibTeXParser.displayText(
                entry.fields["journal"] ?? entry.fields["booktitle"]
                    ?? entry.fields["publisher"] ?? ""),
            doi: entry.fields["doi"]?.trimmingCharacters(in: .whitespaces) ?? "",
            url: entry.fields["url"]?.trimmingCharacters(in: .whitespaces),
            bibtex: bibtex)
    }

    /// One work, one identity: BibTeX compared with its whitespace
    /// flowed, so a re-wrapped copy of the same record still matches.
    private static func normalizedBibTeX(_ bibtex: String) -> String {
        bibtex.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// "Frode Hegland" → "Hegland, Frode"; "Hegland, Frode" stays.
    /// "Deutsche Forschungsgemeinschaft (DFG)" stays too — a
    /// parenthesized last word is an acronym, not a family name, and
    /// inverting once printed "(DFG), Deutsche Forschungsgemeinschaft".
    private static func familyFirst(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.contains(","), trimmed.contains(" ") else { return trimmed }
        let words = trimmed.split(separator: " ").map(String.init)
        guard let family = words.last, !family.hasPrefix("(") else { return trimmed }
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
        \(headerHTML(for: doc))
        <main>
        """)

        // Every element's exported anchor, by its stable id: a note
        // dagger must point at the id a standard reader resolves — the
        // purple number — never the data-id only this app's own readers
        // consult ("#fn1" finds nothing out there; "#60B" is the note).
        let addressByStableID = Dictionary(
            body.map { (stableID($0), $0.address) },
            uniquingKeysWith: { first, _ in first })

        // Every endnote's printed number, in the order the body first
        // cites it: the trailing digits of its stable id (fn24 → 24,
        // en-3 → 3) — the number the PDF printed — else its position
        // in citation order. The mark shows this number, never a
        // generic ‡; the note paragraph opens with it as a back link
        // to the first citing mark (a note can be cited many times;
        // the first instance is the one that carries the fnref id).
        var noteNumbers: [String: String] = [:]
        for element in body {
            var rest = element.text[...]
            while let range = rest.range(of: #"\[note:([A-Za-z0-9._:-]+)\]"#,
                                         options: .regularExpression) {
                let id = String(rest[range].dropFirst("[note:".count).dropLast())
                if noteNumbers[id] == nil {
                    let digits = id.reversed().prefix { $0.isNumber }.reversed()
                    noteNumbers[id] = digits.isEmpty
                        ? String(noteNumbers.count + 1) : String(digits)
                }
                rest = rest[range.upperBound...]
            }
        }
        let anchoredNoteRefs = NoteRefAnchors()

        // Defined concepts get their first occurrence wrapped in <dfn>
        // (spec C5) — the definition itself lives only in the JSON.
        var pendingConcepts = doc.concepts.filter { $0.tag != "heading" }.map(\.name)
        let tablesByID = Dictionary(doc.tables.map { ($0.identifier, $0) },
                                    uniquingKeysWith: { first, _ in first })
        var sectionOpen = false
        // The ACM Reference Format block rides the front matter's tail:
        // right after the Keywords paragraph, as the printed column reads
        // — or, keywordless, at the first section's end before the body.
        var pendingACMReference = acmReferenceHTML(for: doc)
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
        var openBoxID: String?
        func closeBox() {
            if openBoxID != nil {
                lines.append("</aside>")
                openBoxID = nil
            }
        }
        for element in body {
            let stretchID = element.paragraph.stretchID
            if stretchID != openStretchID { closeStretch() }
            if element.paragraph.boxID != openBoxID { closeBox() }
            if element.opensSection {
                closeBox()
                closeStretch()
                if sectionOpen {
                    if let pending = pendingACMReference {
                        lines.append(pending)
                        pendingACMReference = nil
                    }
                    lines.append("</section>")
                }
                lines.append("<section>")
                sectionOpen = true
            }
            var html = self.element(for: element, citations: citations,
                                    stableID: stableID, assetsByID: assetsByID,
                                    tablesByID: tablesByID,
                                    noteAddresses: addressByStableID,
                                    noteNumbers: noteNumbers,
                                    anchoredNoteRefs: anchoredNoteRefs)
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
            if let boxID = element.paragraph.boxID, boxID != openBoxID {
                lines.append("<aside class=\"ot-box\" data-box-id=\"\(attributeEscaped(boxID))\">")
                openBoxID = boxID
            }
            lines.append(html)
            if let pending = pendingACMReference,
               element.text.drop(while: { !$0.isLetter })
                   .lowercased().hasPrefix("keywords") {
                lines.append(pending)
                pendingACMReference = nil
            }
        }
        closeBox()
        closeStretch()
        if let pending = pendingACMReference { lines.append(pending) }
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
                lines.append("<li id=\"ref-\(citation.number)\" data-bibtex=\"\(bibtexAttribute)\" data-csl-json=\"\(cslAttribute)\">\(referenceHTML(for: citation))</li>")
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
        <section id="visual-meta" hidden="hidden">
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

    /// The front matter as the paper prints it: the title, each author
    /// on a line, the affiliations, then venue and date — centered by
    /// the stylesheet, as LaTeX centers the title block. The names
    /// split from the joined author string only when every chunk reads
    /// as a full name — "Doe, John" stays one line.
    private static func headerHTML(for doc: LiquidDoc) -> String {
        var lines = ["<header>", "<h1>\(escaped(doc.title))</h1>"]
        // The subtitle stands under the title, as the paper prints it —
        // never in the body's flow.
        if let subtitle = doc.subtitle, !subtitle.isEmpty {
            lines.append("<p class=\"subtitle\">\(escaped(subtitle))</p>")
        }
        let display = doc.displayAuthor
        var authors = [display]
        if !display.contains(" on behalf of ") {
            let chunks = display.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if chunks.count > 1, chunks.allSatisfy({ $0.contains(" ") }) {
                authors = chunks
            }
        }
        // The affiliations the per-author lines place; whatever no
        // author claims still prints in the shared block below.
        var unplaced = doc.affiliations
        // The byline columns as the paper prints them: one author full
        // width, two side by side, three or more in three columns that
        // wrap. A reader without grid stacks the blocks — today's look.
        let columns = min(max(authors.count, 1), 3)
        lines.append("<div class=\"authors authors-\(columns)\">")
        for author in authors {
            lines.append("<div class=\"author-block\">")
            lines.append("<p class=\"author\">\(escaped(author))</p>")
            // The affiliation directly under the name, as the paper
            // groups its byline columns — then the contact line.
            if let affiliation = doc.authorAffiliations[author], !affiliation.isEmpty {
                lines.append("<p class=\"affiliation\">\(escaped(affiliation))</p>")
                unplaced.removeAll { $0 == affiliation }
            }
            // The email and the ORCID, written out and live, on a quiet
            // line under the name — as the page prints them.
            var details: [String] = []
            if let email = doc.authorEmails[author], !email.isEmpty {
                details.append("<a href=\"mailto:\(attributeEscaped(email))\">\(escaped(email))</a>")
            }
            if let orcid = doc.authorORCIDs[author], !orcid.isEmpty {
                details.append("<a class=\"orcid\" href=\"https://orcid.org/\(attributeEscaped(orcid))\">\(escaped(orcid))</a>")
            }
            if !details.isEmpty {
                lines.append("<p class=\"author-detail\">\(details.joined(separator: " \u{00B7} "))</p>")
            }
            lines.append("</div>")
        }
        lines.append("</div>")
        for affiliation in unplaced {
            lines.append("<p class=\"affiliation\">\(escaped(affiliation))</p>")
        }
        var parts: [String] = []
        if let publication = doc.publication, !publication.isEmpty {
            parts.append(publication)
        }
        // A paper with an ACM Reference Format block already states its
        // dates there (and in the license block) — a byline date here
        // read as the publication day when it was only the conversion's.
        if doc.acmReference == nil {
            parts.append(doc.date?.displayText
                ?? doc.created.formatted(date: .long, time: .omitted))
        }
        if let location = doc.location { parts.append(location) }
        if !parts.isEmpty {
            lines.append("<p class=\"byline\">\(escaped(parts.joined(separator: " · ")))</p>")
        }
        // The license and copyright, as page 1 prints them lower left:
        // the CC badge, the boilerplate lines, the paper's DOI live.
        if let license = doc.license, !license.isEmpty {
            var lines2: [String] = []
            if license.contains("Creative Commons") {
                lines2.append("<img class=\"cc-badge\" src=\"images/cc-by.png\" alt=\"Creative Commons Attribution 4.0\" />")
            }
            let body = license
                .components(separatedBy: "\n")
                .map { line -> String in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("https://doi.org/") {
                        return "<a href=\"\(attributeEscaped(trimmed))\">\(escaped(trimmed))</a>"
                    }
                    return escaped(trimmed)
                }
                .joined(separator: "<br/>")
            lines2.append(body)
            lines.append("<p class=\"license\">\(lines2.joined(separator: "<br/>"))</p>")
        }
        lines.append("</header>")
        return lines.joined(separator: "\n")
    }

    /// The publisher's self-citation, exactly as page 1 prints it — the
    /// reference this paper asks to be cited by. It stands where the
    /// column reads it: after the Keywords, before the Introduction.
    private static func acmReferenceHTML(for doc: LiquidDoc) -> String? {
        guard let reference = doc.acmReference, !reference.isEmpty else { return nil }
        // The DOI at the block's end is a live link.
        var block = escaped(reference)
        if let range = reference.range(of: "https://doi.org/") {
            let url = String(reference[range.lowerBound...])
            block = escaped(String(reference[..<range.lowerBound]))
                + "<a href=\"\(attributeEscaped(url))\">\(escaped(url))</a>"
        }
        return "<p class=\"acm-reference\"><strong>ACM Reference Format:</strong><br/>\(block)</p>"
    }

    /// The note ids whose citing mark already carries the `fnref-` id —
    /// only the first mark does (ids are unique), and the note's back
    /// link points there.
    private final class NoteRefAnchors {
        var seen: Set<String> = []
    }

    /// One element, carrying its address as the anchor (spec A1) and its
    /// stable id in `data-id` (spec A2) — the paragraph's own id, or the
    /// heading's Map-node UUID when the concept pool knows it.
    private static func element(for element: AddressedElement,
                                citations: [Citation],
                                stableID: (AddressedElement) -> String,
                                assetsByID: [String: LiquidDoc.Asset],
                                tablesByID: [String: LiquidDoc.Table] = [:],
                                noteAddresses: [String: String] = [:],
                                noteNumbers: [String: String] = [:],
                                anchoredNoteRefs: NoteRefAnchors? = nil) -> String {
        let paragraph = element.paragraph
        let trimmed = paragraph.text.trimmingCharacters(in: .whitespaces)
        let anchors = "id=\"\(element.address)\" data-id=\"\(escaped(stableID(element)))\""
        // An image marker `![alt](asset:id)` becomes a <figure><img>, its
        // bytes written alongside as content/images/<file>.
        if let reference = LiquidDoc.imageReference(in: paragraph.text),
           let asset = assetsByID[reference.id] {
            let alt = reference.alt.isEmpty ? (asset.alt ?? "") : reference.alt
            // The caption is visible words, not only an alt attribute —
            // a browser never shows alt; a <figcaption> every reader does.
            let caption = alt.isEmpty ? "" : "<figcaption>\(escaped(alt))</figcaption>"
            return "<figure \(anchors)><img src=\"images/\(attributeEscaped(asset.filename))\" alt=\"\(attributeEscaped(alt))\" />\(caption)</figure>"
        }
        // A live table renders as a real grid, its `data-table-id` tying
        // the placement to the Visual-Meta tables entry (values and
        // formulas) so the import recovers it whole; the paragraph's
        // pipe-text stays behind only for readers without table support.
        if let tableID = paragraph.tableID, let table = tablesByID[tableID] {
            let rows = table.cells.enumerated().map { rowIndex, row -> String in
                let tag = rowIndex == 0 && table.cells.count > 1 ? "th" : "td"
                let cells = row.map {
                    "<\(tag)>\(citedCellHTML($0.value, citations: citations))</\(tag)>"
                }.joined()
                return "<tr>\(cells)</tr>"
            }
            return "<table \(anchors) data-table-id=\"\(attributeEscaped(table.identifier))\">"
                + rows.joined() + "</table>"
        }
        if trimmed.count >= 3, trimmed.allSatisfy({ $0 == "-" }) {
            return "<hr \(anchors) />"
        }
        // A fenced code block (```lang⏎…⏎```) is a real <pre> — words
        // exactly as written, monospace, never markdown-converted (code
        // is full of asterisks and brackets that mean nothing here).
        // The fence's language rides in data-language for the round trip.
        if trimmed.hasPrefix("```"), trimmed.hasSuffix("```"), trimmed.count > 6,
           let fenceEnd = trimmed.firstIndex(of: "\n") {
            let language = trimmed[trimmed.index(trimmed.startIndex, offsetBy: 3)..<fenceEnd]
                .trimmingCharacters(in: .whitespaces)
            let code = trimmed[trimmed.index(after: fenceEnd)...].dropLast(3)
                .trimmingCharacters(in: .newlines)
            let languageAttribute = language.isEmpty
                ? "" : " data-language=\"\(attributeEscaped(language))\""
            return "<pre \(anchors)\(languageAttribute)><code>\(escaped(code))</code></pre>"
        }
        let inline = inlineHTML(from: element.text, citations: citations,
                                noteAddresses: noteAddresses,
                                noteNumbers: noteNumbers,
                                anchoredNoteRefs: anchoredNoteRefs)
        if let level = element.headingLevel {
            return "<h\(level + 1) \(anchors)>\(inline)</h\(level + 1)>"
        }
        // An endnote opens with its printed number as a back link to
        // the first mark that cites it. The number may already lead the
        // text (a re-imported export keeps it as words) — then it is
        // wrapped, never doubled.
        let stable = stableID(element)
        if element.headingLevel == nil, let number = noteNumbers[stable] {
            let back = "<a class=\"ot-note-back\" role=\"doc-backlink\""
                + " href=\"#fnref-\(attributeEscaped(stable))\">\(number).</a>"
            var words = inline
            if words.hasPrefix("\(number).") {
                words = String(words.dropFirst("\(number).".count))
                    .trimmingCharacters(in: .whitespaces)
            }
            return "<p \(anchors) role=\"doc-endnote\">\(back) \(words)</p>"
        }
        if let speaker = paragraph.speaker, element.text.hasPrefix("\(speaker):") {
            let rest = inlineHTML(from: String(element.text.dropFirst(speaker.count + 1)),
                                  citations: citations, noteAddresses: noteAddresses,
                                  noteNumbers: noteNumbers,
                                  anchoredNoteRefs: anchoredNoteRefs)
            return "<p \(anchors)><strong class=\"speaker\">\(escaped(speaker)):</strong>\(rest)</p>"
        }
        return "<p \(anchors)>\(inline)</p>"
    }

    /// Escapes the text, then layers the inline conventions: markdown
    /// code/bold/italic/links, and bracketed origami addresses as the
    /// profile's numbered citation markers, linked to References with
    /// their stable citation id (spec C6).
    private static func inlineHTML(from text: String, citations: [Citation],
                                   noteAddresses: [String: String] = [:],
                                   noteNumbers: [String: String] = [:],
                                   anchoredNoteRefs: NoteRefAnchors? = nil) -> String {
        var html = escaped(text)
        html = html.replacingOccurrences(of: "`([^`]+)`", with: "<code>$1</code>",
                                         options: .regularExpression)
        // A strong run may hold italic ones (***i1* Illegal Hate
        // Speech.**, **designing *experiences*** — ht26-34): the
        // content is plain words or COMPLETE *em* pairs, so the em
        // converted next always nests inside, never across. The atomic
        // group is load-bearing: without it, a paragraph full of stars
        // with no closing ** backtracks exponentially.
        html = html.replacingOccurrences(of: "\\*\\*((?>[^*]+|\\*[^*]+\\*)+)\\*\\*",
                                         with: "<strong>$1</strong>",
                                         options: .regularExpression)
        html = html.replacingOccurrences(of: "\\*([^*]+)\\*", with: "<em>$1</em>",
                                         options: .regularExpression)
        html = html.replacingOccurrences(
            of: "\\[([^\\]]+)\\]\\((https?://[^)\\s]+)\\)",
            with: "<a href=\"$2\">$1</a>", options: .regularExpression)
        // In-document jumps — the import's resolved \\ref links: a real
        // anchor to the target's exported address (what any reader
        // follows), the stable id in data-target-id for the round trip
        // and the reading views' figure popover. A target the address
        // map does not know degrades to its words.
        while let range = html.range(of: #"\[([^\]\[]+)\]\(origami-jump:([A-Za-z0-9:._-]+)\)"#,
                                     options: .regularExpression) {
            let match = String(html[range])
            let words = String(match.dropFirst().prefix { $0 != "]" })
            let id = match.range(of: "origami-jump:").map {
                String(match[$0.upperBound...].dropLast())
            } ?? ""
            let replacement: String
            if let address = noteAddresses[id] {
                replacement = "<a class=\"ot-jump\" data-target-id=\"\(attributeEscaped(id))\""
                    + " href=\"#\(attributeEscaped(address))\">\(words)</a>"
            } else {
                replacement = words
            }
            html.replaceSubrange(range, with: replacement)
        }
        // Note tokens become dagger anchors, their href carrying the
        // note's stable id: [inote:] the in-place stretchtext kind
        // (class ot-inline-note), [note:] the plain endnote mark. Both
        // point at the Notes paragraphs the body closes with; the
        // importer reads the fragment back into the same token.
        // The href must carry the note element's EXPORTED id — its
        // purple number — because standard readers resolve ids, not
        // data-ids; the token's own id rides in data-note-id so a
        // re-import recovers the token exactly (fn1, never 60B).
        func resolveNoteTokens(_ token: String, extraClass: String) {
            let pattern = "\\[\(token):([A-Za-z0-9._:-]+)\\]"
            while let range = html.range(of: pattern, options: .regularExpression) {
                let id = String(html[range].dropFirst(token.count + 2).dropLast())
                let target = noteAddresses[id] ?? id
                // An endnote mark shows the note's printed number, as
                // the PDF did — ‡ only when no number is known (inline
                // stretchtext notes, which fold in place). The first
                // mark citing a note carries the fnref- id the note's
                // back link returns to.
                var mark = "\u{2021}"
                var anchorID = ""
                if token == "note", let number = noteNumbers[id] {
                    mark = "<sup>\(number)</sup>"
                    if let anchored = anchoredNoteRefs, !anchored.seen.contains(id) {
                        anchored.seen.insert(id)
                        anchorID = " id=\"fnref-\(attributeEscaped(id))\""
                    }
                }
                html.replaceSubrange(range, with:
                    "<a\(extraClass)\(anchorID) role=\"doc-noteref\""
                    + " data-note-id=\"\(attributeEscaped(id))\""
                    + " href=\"#\(attributeEscaped(target))\">\(mark)</a>")
            }
        }
        resolveNoteTokens("inote", extraClass: " class=\"ot-inline-note\"")
        resolveNoteTokens("note", extraClass: "")
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

    /// A table cell's text with its citation tokens resolved to the
    /// visible [n] links — the grid path never went through the
    /// paragraph's inline conversion, so "[cite:sora2024]" printed
    /// literally in six papers' tables where the PDF shows "[58]".
    /// The Visual-Meta tables entry keeps the raw value, so a round
    /// trip still recovers the token.
    private static func citedCellHTML(_ value: String, citations: [Citation]) -> String {
        var html = escaped(value)
        guard html.contains("[cite:") else { return html }
        for citation in citations where citation.address == nil {
            let pattern = "\\[cite:\(NSRegularExpression.escapedPattern(for: citation.nodeID))\\]"
            html = html.replacingOccurrences(
                of: pattern,
                with: "<a class=\"citation\" href=\"#ref-\(citation.number)\""
                    + " data-citation-id=\"\(attributeEscaped(citation.nodeID))\">[\(citation.number)]</a>",
                options: .regularExpression)
        }
        // A key the pool does not know degrades to the bracketed key.
        return html.replacingOccurrences(of: "\\[cite:([^\\]]+)\\]", with: "[$1]",
                                         options: .regularExpression)
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

    /// The visible reference line, ACM-shaped: authors, year, title
    /// roman, the venue in italic, and the way out — DOI, else URL —
    /// live as a link, never inert text.
    private static func referenceHTML(for citation: Citation) -> String {
        var parts: [String] = []
        if !citation.authors.isEmpty {
            parts.append(escaped(citation.authors.joined(separator: "; ")))
        }
        if !citation.year.isEmpty { parts.append("(\(escaped(citation.year))).") }
        if !citation.title.isEmpty { parts.append("\(escaped(citation.title)).") }
        if !citation.publication.isEmpty {
            parts.append("<em>\(escaped(citation.publication))</em>.")
        }
        if !citation.doi.isEmpty {
            // ACM's 10.5555 prefix is a Digital Library identifier, not
            // a registered DOI — doi.org answers 404; the DL answers.
            let link = citation.doi.hasPrefix("10.5555/")
                ? "https://dl.acm.org/doi/\(citation.doi)"
                : "https://doi.org/\(citation.doi)"
            parts.append("<a href=\"\(attributeEscaped(link))\">\(escaped(link))</a>")
        } else if let url = citation.url, !url.isEmpty {
            parts.append("<a href=\"\(attributeEscaped(url))\">\(escaped(url))</a>")
        } else if let address = citation.address {
            parts.append(escaped("[\(address)]"))
        }
        return parts.joined(separator: " ")
    }

    /// Throws unless every internal anchor resolves — an `href` fragment
    /// whose id no element carries is a dead link in every standard
    /// reader (the HT '26 footnote lesson: daggers pointed at data-ids
    /// only this app's readers consult). Same-document fragments check
    /// against the document itself; the navigation document's
    /// `paper.html#…` links check against the content document.
    private static func assertAnchorsResolve(in xhtml: String, file: String,
                                             targetsIn idSource: String? = nil) throws {
        let source = idSource ?? xhtml
        var ids = Set<String>()
        var rest = source[...]
        // The attribute must stand alone: `data-note-id="fn9"` contains
        // the characters `id="fn9"`, and matching those would let a dead
        // anchor mask itself behind the very attribute that names it.
        while let range = rest.range(of: ##"(?<=[\s<])id="([^"]+)""##,
                                     options: .regularExpression) {
            ids.insert(String(source[range].dropFirst(4).dropLast()))
            rest = rest[range.upperBound...]
        }
        for prefix in ["href=\"#", "href=\"paper.html#"] {
            var rest = xhtml[...]
            while let open = rest.range(of: prefix) {
                rest = rest[open.upperBound...]
                guard let close = rest.firstIndex(of: "\"") else { break }
                let target = String(rest[..<close])
                guard ids.contains(target) else {
                    throw OrigamiEPUBExportError.danglingAnchor(file: file,
                                                                target: target)
                }
                rest = rest[rest.index(after: close)...]
            }
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
        var entries = headings.isEmpty
            ? ["<li><a href=\"paper.html\">\(escaped(doc.title))</a></li>"]
            : headings.map {
                // Emphasis markers are body notation — a contents label
                // printed "**Networks with no central gravity**" raw.
                let label = $0.text.replacingOccurrences(of: "*", with: "")
                return "<li><a href=\"paper.html#\($0.address)\">\(escaped(label))</a></li>"
            }
        // The reference list is the exporter's own section — the body's
        // headings never carry it, so the contents must add it.
        if !doc.references.isEmpty {
            entries.append("<li><a href=\"paper.html#references\">References</a></li>")
        }
        let items = entries.joined(separator: "\n")
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

    /// What the export actually contains, tracked so the accessibility
    /// claims in the OPF stay truthful per-document rather than
    /// boilerplate. One shared helper for every conversion path — mirrors
    /// Author's `OrigamiTextExporter.buildOPF`.
    struct AccessibilityFacts {
        var hasImages = false
        /// One `<img>` without a non-empty alt withdraws both the
        /// `alternativeText` feature and `accessModeSufficient=textual`.
        var allImagesHaveAltText = true
        var contentHasMathML = false
        /// Body headings mapped to `<h2>`… in nested `<section>`s —
        /// required before claiming `structuralNavigation`.
        var hasSectionHeadings = false
        /// True of this exporter's output: nav.html is a real
        /// `nav epub:type="toc"`. A conversion path that skips the nav
        /// must set this false to withdraw the `tableOfContents` claim.
        var hasTocNav = true
        /// True of this exporter's output: the nav carries
        /// `role="doc-toc"` and note marks carry `role="doc-noteref"`.
        var hasDPUBARIARoles = true
    }

    /// EPUB Accessibility 1.1 discovery metadata (schema.org vocabulary —
    /// the `schema:` prefix is reserved in EPUB 3, no declaration needed),
    /// one `<meta>` per line, indented for the OPF `<metadata>` block.
    /// Thorium ≥ 2.2 and the W3C display guide surface these; every claim
    /// is derived from `facts`, what this export really contains.
    static func accessibilityMetadataXML(_ facts: AccessibilityFacts) -> String {
        var lines = ["<meta property=\"schema:accessMode\">textual</meta>"]
        if facts.hasImages {
            lines.append("<meta property=\"schema:accessMode\">visual</meta>")
        }
        // "textual" alone is sufficient only when nothing visual is left
        // undescribed — no images, or every image carries alt text.
        if !facts.hasImages || facts.allImagesHaveAltText {
            lines.append("<meta property=\"schema:accessModeSufficient\">textual</meta>")
        }
        if facts.hasImages {
            lines.append("<meta property=\"schema:accessModeSufficient\">textual,visual</meta>")
        }
        var features: [String] = []
        if facts.hasTocNav { features.append("tableOfContents") }
        features.append("readingOrder")
        if facts.hasSectionHeadings { features.append("structuralNavigation") }
        if facts.hasDPUBARIARoles { features.append("ARIA") }
        if facts.hasImages && facts.allImagesHaveAltText { features.append("alternativeText") }
        if facts.contentHasMathML { features.append("MathML") }
        for feature in features {
            lines.append("<meta property=\"schema:accessibilityFeature\">\(feature)</meta>")
        }
        // Static text output — revisit if a conversion ever embeds
        // video, audio, or animation.
        lines.append("<meta property=\"schema:accessibilityHazard\">none</meta>")
        var summary: String
        if facts.hasSectionHeadings {
            summary = "Reflowable text with full structural navigation: "
                + "a table of contents, nested section headings, and ARIA landmarks."
        } else if facts.hasTocNav {
            summary = "Reflowable text with a table of contents in a single reading order."
        } else {
            summary = "Reflowable text in a single reading order."
        }
        if facts.contentHasMathML { summary += " Mathematics is expressed in MathML." }
        if facts.hasImages {
            summary += facts.allImagesHaveAltText
                ? " All images have alternative text."
                : " Some images lack alternative text."
        }
        lines.append("<meta property=\"schema:accessibilitySummary\">\(escaped(summary))</meta>")
        return lines.map { "    " + $0 }.joined(separator: "\n")
    }

    private static func packageOPF(doc: LiquidDoc, images: [LiquidDoc.Asset],
                                   facts: AccessibilityFacts) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let modified = formatter.string(from: Date())
        var imageItems = images.enumerated().map { index, asset in
            "        <item id=\"img\(index + 1)\" href=\"content/images/\(attributeEscaped(asset.filename))\" media-type=\"\(asset.mediaType)\"/>"
        }.joined(separator: "\n")
        if doc.license?.contains("Creative Commons") == true {
            imageItems += (imageItems.isEmpty ? "" : "\n")
                + "        <item id=\"ccby\" href=\"content/images/cc-by.png\" media-type=\"image/png\"/>"
        }
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
        \(accessibilityMetadataXML(facts))
          </metadata>
          <manifest>
            <item id="paper" href="content/paper.html" media-type="application/xhtml+xml"\(facts.contentHasMathML ? " properties=\"mathml\"" : "")/>
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
    header { text-align: center; margin-bottom: 2.5em; }
    header h1 { font-size: 1.7em; margin-bottom: 0.6em; }
    .subtitle { font-size: 1.2em; color: #555555; margin: -0.3em 0 0.8em; }
    .authors { display: flex; flex-wrap: wrap; justify-content: center; margin: 0.4em 0; }
    .author-block { margin: 0.3em 0; }
    .authors-1 .author-block { width: 100%; }
    .authors-2 .author-block { width: 46%; }
    .authors-3 .author-block { width: 31%; }
    @media (max-width: 30em) { .authors-2 .author-block, .authors-3 .author-block { width: 100%; } }
    .author { font-size: 1.1em; margin: 0.1em 0; }
    .affiliation { color: #555555; margin: 0.1em 0; }
    .byline { color: #555555; font-style: italic; margin-top: 0.5em; margin-bottom: 0; }
    .license { text-align: left; font-size: 0.85em; color: #555555; max-width: 34em; margin: 1.4em auto 0; }
    .cc-badge { width: 88px; height: auto; }
    .acm-reference { text-align: left; font-size: 0.85em; color: #555555; max-width: 34em; margin: 1.4em auto 0; }
    .author-detail { font-size: 0.8em; color: #555555; margin: 0 0 0.3em; }
    .ot-box { border: 1.5px solid #444444; border-radius: 4px; padding: 0.2em 1em 0.7em; margin: 1.2em 0; }
    .author-detail a { color: inherit; }
    h2 { font-size: 1.4em; margin-top: 1.6em; }
    h3 { font-size: 1.2em; }
    h4 { font-size: 1.05em; }
    .speaker { font-weight: bold; }
    figure { margin-left: 0; margin-right: 0; }
    figure img { max-width: 100%; height: auto; }
    figcaption { font-size: 0.9em; color: #555555; margin-top: 0.4em; }
    table { border-collapse: collapse; margin: 1.2em auto; border-top: 1px solid; border-bottom: 1px solid; }
    th { text-align: left; border-bottom: 0.5px solid; padding: 0.3em 1.2em 0.3em 0; }
    td { text-align: left; vertical-align: top; padding: 0.25em 1.2em 0.25em 0; }
    th:last-child, td:last-child { padding-right: 0; }
    pre { background: rgba(127, 127, 127, 0.12); padding: 0.8em 1em; border-radius: 4px; overflow-x: auto; }
    pre code { font-size: 0.85em; white-space: pre-wrap; }
    a.citation { text-decoration: none; }
    dfn { font-style: normal; border-bottom: 0.08em dotted #999999; }
    #references li { margin-bottom: 0.6em; }
    #visual-meta { font-size: 0.8em; color: #777777; margin-top: 3em; }
    hr { border: 0; border-top: 0.1em solid #cccccc; margin: 2em 0; }
    """
}

extension OrigamiEPUBExporter {
    /// The Creative Commons BY badge (375×131 PNG, from ACM's page 1),
    /// shipped into content/images/cc-by.png whenever a document's
    /// license names Creative Commons — embedded here so the exporter
    /// needs no bundle resource.
    static let ccBadgePNGBase64 = "iVBORw0KGgoAAAANSUhEUgAAAXcAAACDCAYAAAB2tFtFAAAAGXRFWHRTb2Z0d2FyZQBBZG9iZSBJbWFnZVJlYWR5ccllPAAAAydpVFh0WE1MOmNvbS5hZG9iZS54bXAAAAAAADw/eHBhY2tldCBiZWdpbj0i77u/IiBpZD0iVzVNME1wQ2VoaUh6cmVTek5UY3prYzlkIj8+IDx4OnhtcG1ldGEgeG1sbnM6eD0iYWRvYmU6bnM6bWV0YS8iIHg6eG1wdGs9IkFkb2JlIFhNUCBDb3JlIDEwLjAtYzAwMCA3OS5kMjBlNDY2MzAsIDIwMjUvMTIvMDktMDI6MTE6MjMgICAgICAgICI+IDxyZGY6UkRGIHhtbG5zOnJkZj0iaHR0cDovL3d3dy53My5vcmcvMTk5OS8wMi8yMi1yZGYtc3ludGF4LW5zIyI+IDxyZGY6RGVzY3JpcHRpb24gcmRmOmFib3V0PSIiIHhtbG5zOnhtcD0iaHR0cDovL25zLmFkb2JlLmNvbS94YXAvMS4wLyIgeG1sbnM6eG1wTU09Imh0dHA6Ly9ucy5hZG9iZS5jb20veGFwLzEuMC9tbS8iIHhtbG5zOnN0UmVmPSJodHRwOi8vbnMuYWRvYmUuY29tL3hhcC8xLjAvc1R5cGUvUmVzb3VyY2VSZWYjIiB4bXA6Q3JlYXRvclRvb2w9IkFkb2JlIFBob3Rvc2hvcCAyMDI2IE1hY2ludG9zaCIgeG1wTU06SW5zdGFuY2VJRD0ieG1wLmlpZDo2NzdDQTEwM0E1MDAxMUYxOTgyNkNBQTRFOEFFODEzOSIgeG1wTU06RG9jdW1lbnRJRD0ieG1wLmRpZDo2NzdDQTEwNEE1MDAxMUYxOTgyNkNBQTRFOEFFODEzOSI+IDx4bXBNTTpEZXJpdmVkRnJvbSBzdFJlZjppbnN0YW5jZUlEPSJ4bXAuaWlkOjY3N0NBMTAxQTUwMDExRjE5ODI2Q0FBNEU4QUU4MTM5IiBzdFJlZjpkb2N1bWVudElEPSJ4bXAuZGlkOjY3N0NBMTAyQTUwMDExRjE5ODI2Q0FBNEU4QUU4MTM5Ii8+IDwvcmRmOkRlc2NyaXB0aW9uPiA8L3JkZjpSREY+IDwveDp4bXBtZXRhPiA8P3hwYWNrZXQgZW5kPSJyIj8+cgzWUwAAJvpJREFUeNrs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"
}

// MARK: - Repacking an unpacked book

extension OrigamiEPUBExporter {
    /// Packs an unpacked EPUB folder back into one `.epub`: the mimetype
    /// first (stored, per the spec), then every file under the folder at
    /// its relative path. The inverse of the importer's unpack — how the
    /// Mac publishes its shelf into the community folder, so every
    /// device reading that folder shows the same books.
    static func pack(unpackedFolder folder: URL) throws -> Data {
        var zip = ZipWriter()
        zip.add("mimetype", Data("application/epub+zip".utf8))
        var files: [(relative: String, url: URL)] = []
        if let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?
                    .isRegularFile == true else { continue }
                let relative = url.path.replacingOccurrences(of: folder.path + "/", with: "")
                guard relative != "mimetype" else { continue }
                files.append((relative, url))
            }
        }
        for file in files.sorted(by: { $0.relative < $1.relative }) {
            guard let data = try? Data(contentsOf: file.url) else { continue }
            zip.add(file.relative, data)
        }
        return zip.finished()
    }
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
