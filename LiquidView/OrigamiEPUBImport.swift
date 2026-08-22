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
        /// Every author of record, in order: the Visual-Meta authors
        /// array when present, else all the package's dc:creator
        /// entries. Empty when the book names no one.
        var authors: [String] = []
        /// The journal or proceedings the book declares itself part of,
        /// when it does — Visual-Meta first, then the package's own
        /// collection declarations.
        var publication: String? = nil
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

    /// One package, readable either way: the EPUB's ZIP, or its files
    /// already unpacked on disk. The structured import reads through
    /// this so a remembered book can be re-read without its .epub.
    struct PackageSource {
        /// The named entry's bytes, or nil.
        let entry: (String) -> Data?
        /// The first entry whose name ends with the suffix.
        let entryWithSuffix: (String) -> Data?
    }

    static func importDocument(at url: URL) throws -> ImportResult {
        let zip = try ZipReader(data: try Data(contentsOf: url))
        return try importDocument(from: PackageSource(
            entry: { zip.entry($0) },
            entryWithSuffix: { suffix in
                zip.entries.first { $0.key.hasSuffix(suffix) }?.value
            }))
    }

    /// The structured import over an already-unpacked package folder —
    /// how the native reading styles get their document without the
    /// original .epub file.
    static func importDocument(inUnpackedFolder folder: URL) throws -> ImportResult {
        let fileManager = FileManager.default
        var names: [String] = []
        if let enumerator = fileManager.enumerator(at: folder,
                                                   includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let file as URL in enumerator
            where (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                names.append(file.path.replacingOccurrences(of: folder.path + "/", with: ""))
            }
        }
        return try importDocument(from: PackageSource(
            entry: { name in try? Data(contentsOf: folder.appendingPathComponent(name)) },
            entryWithSuffix: { suffix in
                names.first { $0.hasSuffix(suffix) }
                    .flatMap { try? Data(contentsOf: folder.appendingPathComponent($0)) }
            }))
    }

    private static func importDocument(from source: PackageSource) throws -> ImportResult {
        // container.xml names the package document; be tolerant when
        // the container is odd but the profile's layout holds.
        let opfPath = source.entry("META-INF/container.xml")
            .map { String(decoding: $0, as: UTF8.self) }
            .flatMap { firstCapture(in: $0, pattern: "full-path=\"([^\"]+)\"") }
            ?? "package.opf"
        guard let opfData = source.entry(opfPath) else { throw OrigamiEPUBImportError.corruptContainer }
        let opf = String(decoding: opfData, as: UTF8.self)
        let opfDirectory = (opfPath as NSString).deletingLastPathComponent

        let title = firstTagText(in: opf, tag: "dc:title")
        // A book can name several creators; keep them all — the Authors
        // view lists each, not just the first.
        let creators = allTagTexts(in: opf, tag: "dc:creator")
        let creator = creators.first
        // The venue the package itself declares: the EPUB 3 collection,
        // Dublin Core's isPartOf, or calibre's series — the Journals
        // view groups books by it.
        let opfVenue = [
            firstCapture(in: opf, pattern: "<meta[^>]*property=\"belongs-to-collection\"[^>]*>([^<]*)</meta>"),
            firstCapture(in: opf, pattern: "<meta[^>]*property=\"dcterms:isPartOf\"[^>]*>([^<]*)</meta>"),
            firstCapture(in: opf, pattern: "<meta[^>]*name=\"calibre:series\"[^>]*content=\"([^\"]*)\"")
        ]
            .compactMap { $0 }
            .map(xmlUnescaped)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        let date = firstTagText(in: opf, tag: "dc:date")
        let identifier = firstTagText(in: opf, tag: "dc:identifier")

        // The spine's first itemref names the content document.
        guard let contentHref = spineContentHref(in: opf),
              let contentData = source.entry(joinedPath(opfDirectory, contentHref))
                  ?? source.entry(contentHref)
        else { throw OrigamiEPUBImportError.missingContent }
        let html = String(decoding: contentData, as: UTF8.self)

        // Visual-Meta: the package file first, the embedded copy second.
        let visualMetaData = source.entry("visual-meta.json")
            ?? source.entryWithSuffix("visual-meta.json")
            ?? embeddedVisualMeta(in: html)
        let visualMeta = visualMetaData.flatMap {
            (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]
        }

        // The citation pool, split back into its two homes: internal
        // citations (an origamitext:// URL names their address) become
        // links again; external records become references.
        let pool = citationPool(fromVisualMeta: visualMeta)
        let addressByCitationID = pool.addressByCitationID
        let bibtexByAddress = pool.bibtexByAddress
        var references = pool.references

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
            return source.entry(full)
                ?? source.entry(src)
                ?? source.entryWithSuffix("/\((src as NSString).lastPathComponent)")
        }

        // The Origami profile is one semantic content document; a plain
        // EPUB (no Origami metadata) is often many — one per chapter —
        // so those read whole: every spine document in order, paragraph
        // and asset ids prefixed per chapter so they stay unique, and
        // images kept within a budget so a picture-heavy book does not
        // balloon the document (the markers stay visible regardless).
        var body: [LiquidDoc.Paragraph]
        var bodyAssets: [LiquidDoc.Asset]
        var capturedFootnotes: [(id: String, text: String)] = []
        let capture = CitationCapture()
        let spineHrefs = spineContentHrefs(in: opf)
        if visualMeta == nil, spineHrefs.count > 1 {
            body = []
            bodyAssets = []
            var imageBudget = 12_000_000
            for (index, href) in spineHrefs.enumerated() {
                guard let data = source.entry(joinedPath(opfDirectory, href))
                        ?? source.entry(href) else { continue }
                let chapterDir = (joinedPath(opfDirectory, href) as NSString)
                    .deletingLastPathComponent
                let resolve: (String) -> Data? = { src in
                    let full = joinedPath(chapterDir, src)
                    guard let bytes = source.entry(full)
                            ?? source.entry(src)
                            ?? source.entryWithSuffix("/\((src as NSString).lastPathComponent)"),
                          bytes.count <= imageBudget else { return nil }
                    imageBudget -= bytes.count
                    return bytes
                }
                guard let (part, partAssets, partFootnotes) = try? bodyParagraphs(
                    fromXHTML: String(decoding: data, as: UTF8.self),
                    addressByCitationID: [:],
                    resolveImage: resolve,
                    idPrefix: "s\(index + 1)-",
                    capture: capture) else { continue }
                body += part
                bodyAssets += partAssets
                capturedFootnotes += partFootnotes
            }
            guard !body.isEmpty else { throw OrigamiEPUBImportError.missingContent }
        } else {
            let (part, partAssets, partFootnotes) = try bodyParagraphs(
                fromXHTML: html,
                addressByCitationID: addressByCitationID,
                resolveImage: resolveImage,
                capture: capture)
            body = part
            bodyAssets = partAssets
            capturedFootnotes = partFootnotes
        }

        // What the anchors carried joins the pool: the citation's display
        // text as the author wrote it, and the number tying it to the
        // source's References list.
        references = references.map { reference in
            var enriched = reference
            if enriched.citedAs == nil, let raw = capture.citedAs[reference.id] {
                let text = collapsedLineBreaks(raw)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { enriched.citedAs = text }
            }
            if enriched.number == nil {
                enriched.number = capture.numbers[reference.id]
            }
            return enriched
        }
        // A package whose pool does not know a cited key — an export
        // without its bibliography, say — still carried the author's own
        // rendering in every anchor. Those become records here:
        // "(Engelbart, Kay, Nelson 1995)" parses to author and year, a
        // short text is the work's title, and a long one (a pasted
        // passage) is kept as the record's note. Without this, such
        // citations read as raw keys and no citation style has anything
        // to say.
        let pooledIDs = Set(references.map(\.id))
        for (key, raw) in capture.citedAs where !pooledIDs.contains(key) {
            let text = collapsedLineBreaks(raw)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            // An internal citation's key maps to its address: the pool
            // record keeps the link's own BibTeX (vm-id and all), so
            // the card can still open the original.
            let bibtex = addressByCitationID[key].flatMap { bibtexByAddress[$0] }
                ?? anchorBibTeX(from: text, key: key)
            references.append(LiquidDoc.Reference(
                id: key,
                bibtex: bibtex,
                citedAs: text.count <= 80 ? text : nil,
                number: capture.numbers[key]))
        }

        // Endnotes travel in the metadata (the body only carries their
        // daggers); they return as a Notes section closing the body,
        // each note under its stable id. Inline notes (footnote asides)
        // join them: their metadata rides in `footnotes`, their words
        // were captured from the body's asides — either way each files
        // under the id its dagger points at, so the reveal works the
        // same for both kinds.
        var notes = dictionaries(visualMeta?["endnotes"]).enumerated()
            .compactMap { offset, node -> LiquidDoc.Paragraph? in
                guard let text = (node["text"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty else { return nil }
                return LiquidDoc.Paragraph(id: node["id"] as? String ?? "en-\(offset + 1)",
                                           heading: nil, text: text)
            }
        var notedIDs = Set(notes.map(\.id))
        for node in dictionaries(visualMeta?["footnotes"]) {
            guard let id = node["id"] as? String,
                  let text = (node["text"] as? String)?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty, notedIDs.insert(id).inserted else { continue }
            notes.append(LiquidDoc.Paragraph(id: id, heading: nil, text: text))
        }
        for footnote in capturedFootnotes where notedIDs.insert(footnote.id).inserted {
            notes.append(LiquidDoc.Paragraph(id: footnote.id, heading: nil,
                                             text: footnote.text))
        }
        if !notes.isEmpty {
            body.append(LiquidDoc.Paragraph(id: "notes", heading: 1, text: "Notes"))
            body.append(contentsOf: notes)
        }

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
        let metaAuthors = (document?["authors"] as? [String])?
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty } ?? []
        let metaVenue = ["journal", "proceedings", "publication", "booktitle"]
            .compactMap { document?[$0] as? String }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        return ImportResult(
            title: document?["title"] as? String ?? title ?? "Untitled",
            author: metaAuthors.first ?? creator,
            authors: metaAuthors.isEmpty ? creators : metaAuthors,
            publication: metaVenue ?? opfVenue,
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

    // MARK: The whole spine (carried over from Knowledge Space)

    /// Every spine itemref's content document, in reading order — the
    /// chapters of a plain, multi-document EPUB. Origami-profile books have
    /// one; a chaptered book has many, and the reader pages through them.
    private static func spineContentHrefs(in opf: String) -> [String] {
        var hrefByID: [String: String] = [:]
        for item in captures(in: opf, pattern: "<item\\s[^>]*>") {
            guard let id = firstCapture(in: item, pattern: "\\sid=\"([^\"]+)\""),
                  let href = firstCapture(in: item, pattern: "href=\"([^\"]+)\"")
            else { continue }
            hrefByID[id] = href
        }
        return captures(in: opf, pattern: "<itemref[^>]*idref=\"([^\"]+)\"")
            .compactMap { hrefByID[$0] }
    }

    /// The EPUB 3 navigation document's href, when the manifest names one
    /// (`properties="nav"`).
    private static func navHref(in opf: String) -> String? {
        for item in captures(in: opf, pattern: "<item\\s[^>]*>") {
            guard let properties = firstCapture(in: item, pattern: "properties=\"([^\"]+)\""),
                  properties.split(separator: " ").contains("nav")
            else { continue }
            return firstCapture(in: item, pattern: "href=\"([^\"]+)\"")
        }
        return nil
    }

    /// Every match's first capture group (the whole match when the
    /// pattern has none), in order.
    private static func captures(in text: String, pattern: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return expression.matches(in: text,
                                  range: NSRange(location: 0, length: ns.length)).map { match in
            let index = match.numberOfRanges > 1 ? 1 : 0
            return ns.substring(with: match.range(at: index))
        }
    }

    /// A book's reading order and navigation, re-derived from its unpacked
    /// folder — so remembered books gain chapters without a manifest
    /// migration. `chapters` are folder-relative subpaths in spine order;
    /// `nav` is the EPUB navigation document's subpath, when the book has one.
    struct BookSpine: Sendable {
        let chapters: [String]
        let nav: String?
    }

    static func spine(inUnpackedFolder folder: URL) -> BookSpine? {
        let containerURL = folder.appendingPathComponent("META-INF/container.xml")
        let opfSubpath = (try? String(contentsOf: containerURL, encoding: .utf8))
            .flatMap { firstCapture(in: $0, pattern: "full-path=\"([^\"]+)\"") }
            ?? "package.opf"
        let opfURL = folder.appendingPathComponent(opfSubpath)
        guard let opf = try? String(contentsOf: opfURL, encoding: .utf8) else { return nil }
        let opfDirectory = (opfSubpath as NSString).deletingLastPathComponent
        let chapters = spineContentHrefs(in: opf).map { joinedPath(opfDirectory, $0) }
        let nav = navHref(in: opf).map { joinedPath(opfDirectory, $0) }
        guard !chapters.isEmpty else { return nil }
        return BookSpine(chapters: chapters, nav: nav)
    }

    // MARK: Table of contents

    /// One table-of-contents entry: the label to show, the chapter it lives
    /// in (folder-relative subpath), and the fragment within it, if any.
    struct TOCEntry: Identifiable, Hashable, Sendable {
        let label: String
        let subpath: String
        let fragment: String?
        var id: String { subpath + "#" + (fragment ?? "") + "·" + label }
    }

    /// The book's table of contents: the EPUB navigation document's `toc`
    /// list when the book carries one; otherwise the content documents'
    /// own headings (single-document books), or one entry per chapter
    /// titled by its first heading or `<title>` (plain chaptered books).
    static func tocEntries(inUnpackedFolder folder: URL, spine: BookSpine) -> [TOCEntry] {
        if let nav = spine.nav,
           let html = try? String(contentsOf: folder.appendingPathComponent(nav), encoding: .utf8) {
            let navDirectory = (nav as NSString).deletingLastPathComponent
            // Prefer the toc <nav>; fall back to every anchor in the file.
            let scope = firstCapture(
                in: html,
                pattern: "(?s)<nav[^>]*epub:type=\"toc\"[^>]*>(.*?)</nav>") ?? html
            var entries: [TOCEntry] = []
            for anchor in captures(in: scope, pattern: "(?s)<a\\s[^>]*href=\"[^\"]+\"[^>]*>.*?</a>") {
                guard let href = firstCapture(in: anchor, pattern: "href=\"([^\"]+)\""),
                      let inner = firstCapture(in: anchor, pattern: "(?s)<a[^>]*>(.*?)</a>")
                else { continue }
                let label = xmlUnescaped(inner
                    .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !label.isEmpty, !href.hasPrefix("http") else { continue }
                let parts = href.split(separator: "#", maxSplits: 1)
                let file = parts.first.map(String.init) ?? ""
                let fragment = parts.count > 1 ? String(parts[1]) : nil
                let subpath = file.isEmpty
                    ? (spine.chapters.first ?? "")
                    : joinedPath(navDirectory, file.removingPercentEncoding ?? file)
                entries.append(TOCEntry(label: label, subpath: subpath, fragment: fragment))
            }
            if !entries.isEmpty { return entries }
        }
        // No navigation document: build the contents from the words.
        if spine.chapters.count == 1, let only = spine.chapters.first {
            guard let html = try? String(contentsOf: folder.appendingPathComponent(only),
                                         encoding: .utf8) else { return [] }
            return captures(in: html, pattern: "(?s)<h[1-3]\\b[^>]*\\bid=\"[^\"]+\"[^>]*>.*?</h[1-3]>")
                .compactMap { heading in
                    guard let id = firstCapture(in: heading, pattern: "id=\"([^\"]+)\""),
                          let inner = firstCapture(in: heading, pattern: "(?s)>(.*)<") else { return nil }
                    let label = xmlUnescaped(inner
                        .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return label.isEmpty ? nil : TOCEntry(label: label, subpath: only, fragment: id)
                }
        }
        return spine.chapters.enumerated().map { index, subpath in
            let html = try? String(contentsOf: folder.appendingPathComponent(subpath),
                                   encoding: .utf8)
            let label = html.flatMap { text in
                (firstCapture(in: text, pattern: "(?s)<h[1-2]\\b[^>]*>(.*?)</h[1-2]>")
                    ?? firstCapture(in: text, pattern: "(?s)<title[^>]*>(.*?)</title>"))
                    .map { xmlUnescaped($0.replacingOccurrences(of: "<[^>]+>", with: "",
                                                                options: .regularExpression)) }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .flatMap { $0.isEmpty ? nil : $0 }
            }
            return TOCEntry(label: label ?? "Chapter \(index + 1)", subpath: subpath, fragment: nil)
        }
    }

    /// The embedded Visual-Meta copy, when the package file is gone: the
    /// JSON between the payload script's tags, with the CDATA wrapper (and
    /// any split guard) stripped so it decodes. (Internal: the reader's
    /// glossary lookup reads the same payload from an unpacked book.)
    static func embeddedVisualMeta(in html: String) -> Data? {
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

    /// Every occurrence of the tag's text, in document order — how all
    /// of a book's dc:creator entries are gathered.
    private static func allTagTexts(in xml: String, tag: String) -> [String] {
        guard let expression = try? NSRegularExpression(
            pattern: "<\(tag)[^>]*>([^<]*)</\(tag)>", options: []) else { return [] }
        let range = NSRange(xml.startIndex..., in: xml)
        return expression.matches(in: xml, options: [], range: range)
            .compactMap { match in
                let index = match.numberOfRanges > 1 ? 1 : 0
                return Range(match.range(at: index), in: xml).map { String(xml[$0]) }
            }
            .map(xmlUnescaped)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
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
                                       resolveImage: (String) -> Data?,
                                       idPrefix: String = "",
                                       capture: CitationCapture? = nil)
        throws -> (paragraphs: [LiquidDoc.Paragraph], assets: [LiquidDoc.Asset],
                   footnotes: [(id: String, text: String)]) {
        let root = try XMLTree.parse(Data(html.utf8))
        // The Origami profile wraps the flow in <main>; a plain EPUB's
        // chapters write their content straight into <body>.
        guard let main = root.firstDescendant(named: "main")
                ?? root.firstDescendant(named: "body") else {
            throw OrigamiEPUBImportError.missingContent
        }

        var paragraphs: [LiquidDoc.Paragraph] = []
        var assets: [LiquidDoc.Asset] = []
        var footnotes: [(id: String, text: String)] = []
        var assetOrdinal = 0
        var fallbackOrdinal = 0

        func visit(_ element: XMLTree.Element, stretchID: String? = nil) {
            // <h2> is the profile's top rank; a plain book's <h1>
            // chapter titles read at the same rank, its deeper ranks
            // one step finer each.
            let headingLevels = ["h1": 1, "h2": 1, "h3": 2, "h4": 3, "h5": 3, "h6": 3]
            let stableID: () -> String = {
                fallbackOrdinal += 1
                return idPrefix + (element.attributes["data-id"]
                    ?? element.attributes["id"]
                    ?? "p\(fallbackOrdinal)")
            }
            switch element.name {
            case "section", "div", "article":
                for child in element.elements { visit(child, stretchID: stretchID) }
            case "aside":
                // The export's stretchtext detail: the toggled anchor in
                // the host paragraph is chrome, but the aside's content
                // stays foldable — its paragraphs carry the block's id.
                if (element.attributes["class"] ?? "").contains("ot-stretchtext-content") {
                    let blockID = element.attributes["id"].map { idPrefix + $0 } ?? stableID()
                    for child in element.elements { visit(child, stretchID: blockID) }
                } else if (element.attributes["epub:type"] ?? "").contains("footnote")
                    || (element.attributes["role"] ?? "").contains("doc-footnote") {
                    // An inline note (Author's footnote aside): its
                    // words are the note's, not the flow's. Kept under
                    // the aside's own id, where the host paragraph's
                    // noteref dagger points — filed with the endnotes
                    // after the body, never inlined as a stray
                    // paragraph.
                    if let id = element.attributes["id"] {
                        let text = element.elements
                            .map {
                                collapsedLineBreaks(inlineText(
                                    of: $0, addressByCitationID: addressByCitationID))
                            }
                            .joined(separator: " ")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty { footnotes.append((idPrefix + id, text)) }
                    }
                } else {
                    for child in element.elements { visit(child, stretchID: stretchID) }
                }
            case "hr":
                paragraphs.append(LiquidDoc.Paragraph(id: stableID(), heading: nil, text: "---"))
            case "figure", "img":
                // A figure/image comes back as an asset plus an
                // `![alt](asset:id)` marker paragraph — the same form the
                // exporter reads, so authoring round-trips.
                let image = element.name == "img" ? element : element.firstDescendant(named: "img")
                guard let image, let src = image.attributes["src"], !src.isEmpty else {
                    for child in element.elements { visit(child, stretchID: stretchID) }
                    return
                }
                let alt = image.attributes["alt"] ?? ""
                let paragraphID = stableID()
                if let data = resolveImage(src), !data.isEmpty {
                    assetOrdinal += 1
                    let assetID = "\(idPrefix)img\(assetOrdinal)"
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
            case "h1", "h2", "h3", "h4", "h5", "h6":
                let text = inlineText(of: element, addressByCitationID: addressByCitationID, capture: capture)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                paragraphs.append(LiquidDoc.Paragraph(
                    id: stableID(), heading: headingLevels[element.name], text: text))
            case "p", "blockquote":
                let text = inlineText(of: element, addressByCitationID: addressByCitationID, capture: capture)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                var paragraph = LiquidDoc.Paragraph(id: stableID(), heading: nil, text: text)
                paragraph.stretchID = stretchID
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
            case "li":
                // A plain book's list items read as bulleted paragraphs —
                // never dropped with their container.
                let text = inlineText(of: element, addressByCitationID: addressByCitationID, capture: capture)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                var paragraph = LiquidDoc.Paragraph(id: stableID(), heading: nil,
                                                    text: "\u{2022} " + text)
                paragraph.stretchID = stretchID
                paragraphs.append(paragraph)
            default:
                for child in element.elements { visit(child, stretchID: stretchID) }
            }
        }
        for child in main.elements { visit(child) }
        return (paragraphs, assets, footnotes)
    }

    /// The current export writes one paragraph across several source
    /// lines; the line breaks fold back into single spaces. The older
    /// export's single-line text passes through untouched.
    private static func collapsedLineBreaks(_ text: String) -> String {
        guard text.contains("\n") || text.contains("\r") else { return text }
        return text.replacingOccurrences(of: #"\s*[\r\n]+\s*"#, with: " ",
                                         options: .regularExpression)
    }

    /// What the body's citation anchors carry besides their key: the
    /// display text the author wrote (adjacent same-key fragments of
    /// one citation accumulate into it; the first complete occurrence
    /// is kept) and the `data-citation-number` tying the citation to
    /// the source's References list. Gathered while the body parses,
    /// then written onto the reference pool. (Ported from Knowledge
    /// Space — keep synced.)
    private nonisolated final class CitationCapture {
        var citedAs: [String: String] = [:]
        var numbers: [String: Int] = [:]
        /// The key whose first occurrence is still accumulating
        /// fragments — nil once anything else interrupts.
        var openKey: String?
    }

    /// The Visual-Meta citation pool alone, split back into its two
    /// homes: internal citations (an origamitext:// URL names their
    /// address) map to addresses; external records become references,
    /// each abstract folded into its BibTeX. Shared by the full import
    /// and the citation card's fallback for books whose content
    /// document will not parse.
    static func citationPool(fromVisualMeta visualMeta: [String: Any]?)
        -> (references: [LiquidDoc.Reference],
            addressByCitationID: [String: String],
            bibtexByAddress: [String: String]) {
        var addressByCitationID: [String: String] = [:]
        var bibtexByAddress: [String: String] = [:]
        var references: [LiquidDoc.Reference] = []
        for citation in dictionaries(visualMeta?["citations"]) {
            guard let citationID = citation["id"] as? String else { continue }
            let urls = citation["urls"] as? [String] ?? []
            var bibtex = (citation["bibtex"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Author carries the cited work's abstract beside the BibTeX,
            // not inside it: fold it in, so the citation card (and any
            // re-export) reads it from the one carrier every consumer
            // shares.
            if let record = bibtex, !record.isEmpty,
               let abstract = (citation["abstract"] as? String)?
                   .trimmingCharacters(in: .whitespacesAndNewlines),
               !abstract.isEmpty,
               BibTeXParser.first(record)?.fields["abstract"] == nil {
                bibtex = withAbstractField(record, abstract)
            }
            if let address = urls.lazy.compactMap(originalAddress(fromOpenURL:)).first {
                addressByCitationID[citationID] = address
                if let bibtex, !bibtex.isEmpty { bibtexByAddress[address] = bibtex }
            } else if let bibtex, !bibtex.isEmpty {
                // Our own export writes citedAs and number onto the
                // entries; the body's anchors fill them in otherwise.
                references.append(LiquidDoc.Reference(
                    id: citationID, bibtex: bibtex,
                    citedAs: (citation["citedAs"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                    number: (citation["number"] as? NSNumber)?.intValue))
            }
        }
        return (references, addressByCitationID, bibtexByAddress)
    }

    /// The abstract folded into a BibTeX record as its own field —
    /// where the citation card (and any re-export) reads it.
    static func withAbstractField(_ bibtex: String, _ abstract: String) -> String {
        guard let closing = bibtex.lastIndex(of: "}") else { return bibtex }
        let safe = abstract
            .replacingOccurrences(of: "{", with: "(")
            .replacingOccurrences(of: "}", with: ")")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        var head = String(bibtex[..<closing])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !head.hasSuffix(",") { head += "," }
        return head + "\n  abstract = {\(safe)},\n}"
    }

    /// An anchor's display text as a BibTeX record, best effort:
    /// "Names 1995" (parentheses shed) parses to author and year, a
    /// short text is a title, a long one is kept whole as the note.
    static func anchorBibTeX(from text: String, key: String) -> String {
        func clean(_ value: String) -> String {
            value.replacingOccurrences(of: "{", with: "(")
                .replacingOccurrences(of: "}", with: ")")
        }
        var inner = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if inner.hasPrefix("("), inner.hasSuffix(")") {
            inner = String(inner.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var fields: [String] = []
        let ns = inner as NSString
        if inner.count <= 120,
           let regex = try? NSRegularExpression(
               pattern: #"^(.{2,100}?)[,;\s]+\(?((?:19|20)\d\d)\)?$"#),
           let match = regex.firstMatch(
               in: inner, range: NSRange(location: 0, length: ns.length)),
           match.numberOfRanges >= 3 {
            // Names then a year: the names, comma- or &-separated,
            // become BibTeX authors.
            let names = ns.substring(with: match.range(at: 1))
                .replacingOccurrences(of: " & ", with: ", ")
                .components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if !names.isEmpty {
                fields.append("  author = {\(clean(names.joined(separator: " and ")))}")
            }
            fields.append("  year = {\(ns.substring(with: match.range(at: 2)))}")
        } else if inner.count <= 120 {
            fields.append("  title = {\(clean(inner))}")
        } else {
            fields.append("  note = {\(clean(inner))}")
        }
        return "@misc{\(key),\n" + fields.joined(separator: ",\n") + ",\n}"
    }

    /// One element's text with the inline conventions restored: strong
    /// back to `**`, em to `*`, code to backticks, plain hyperlinks to
    /// `[label](url)`, citation anchors back to their bracketed origami
    /// address (or their visible `[n]` when the citation is external),
    /// `<dfn>` wrappers unwrapped, the speaker's strong left plain.
    private static func inlineText(of element: XMLTree.Element,
                                   addressByCitationID: [String: String],
                                   capture: CitationCapture? = nil) -> String {
        var out = ""
        for child in element.children {
            switch child {
            case .text(let text):
                out += text
            case .element(let inner):
                let content = inlineText(of: inner, addressByCitationID: addressByCitationID, capture: capture)
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
                    if (inner.attributes["class"] ?? "").contains("ot-stretchtext") {
                        // The stretchtext marker (»/‹‹) is the export's
                        // chrome, never the words — the readers draw
                        // their own toggle from the aside's stretchID.
                        break
                    }
                    if let key = inner.attributes["data-citation-key"], !key.isEmpty {
                        // Author's biblioref anchors. Older exports split
                        // one citation across adjacent anchors (the
                        // parenthesis, then the label), all carrying the
                        // same key: one token, however many anchors. The
                        // anchor's text — the author's own rendering —
                        // and its number are kept on the reference
                        // record, so the reader shows the citation as
                        // written and numbers it as the source's
                        // References list does.
                        let token = "[cite:\(key)]"
                        if let number = inner.attributes["data-citation-number"]
                            .flatMap(Int.init) {
                            capture?.numbers[key] = number
                        }
                        if out.hasSuffix(token) {
                            // A continuation fragment of the citation
                            // just opened joins its display text.
                            if let capture, capture.openKey == key {
                                capture.citedAs[key, default: ""] += content
                            }
                        } else {
                            out += token
                            if let capture {
                                if capture.citedAs[key] == nil {
                                    capture.citedAs[key] = content
                                    capture.openKey = key
                                } else {
                                    capture.openKey = nil
                                }
                            }
                        }
                    } else if (inner.attributes["class"] ?? "").contains("ot-inline-note") {
                        // An inline note travelling as stretchtext
                        // (Author's Stretchtext export): the mark folds
                        // the note's words open in place — [] — while
                        // the words themselves are filed with the
                        // endnotes, where the token's id finds them.
                        // The ‡ the anchor shows plain readers is
                        // chrome here, not content.
                        if let href = inner.attributes["href"],
                           let hash = href.firstIndex(of: "#") {
                            out += "[inote:\(href[href.index(after: hash)...])]"
                        }
                    } else if (inner.attributes["epub:type"] ?? "").contains("noteref")
                        || (inner.attributes["role"] ?? "").contains("doc-noteref") {
                        // The endnote's mark: a token carrying the
                        // note's id, rendered at reading time as a
                        // clickable dagger that reveals the note.
                        if let href = inner.attributes["href"],
                           let hash = href.firstIndex(of: "#") {
                            out += "[note:\(href[href.index(after: hash)...])]"
                        } else {
                            out += content
                        }
                    } else if inner.attributes["class"] == "citation" {
                        if let reference = inner.attributes["data-origami-ref"],
                           !reference.isEmpty {
                            // Full resolution: rel and #fragment intact.
                            out += "[\(reference)]"
                        } else if let citationID = inner.attributes["data-citation-id"],
                                  let address = addressByCitationID[citationID] {
                            out += "[\(address)]"
                        } else if let citationID = inner.attributes["data-citation-id"],
                                  !citationID.isEmpty {
                            // An external reference, cited by key: the
                            // token the readers resolve to the reader's
                            // citation style, backed by the reference
                            // pool — never the export's frozen [n].
                            out += "[cite:\(citationID)]"
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
// Internal, not private: the LaTeX importer reads its zipped project
// through the same minimal reader.
struct ZipReader {

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
