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
        /// The paper's subtitle from Visual-Meta, apart from the title.
        var subtitle: String? = nil
        let author: String?
        /// Every author of record, in order: the Visual-Meta authors
        /// array when present, else all the package's dc:creator
        /// entries. Empty when the book names no one.
        var authors: [String] = []
        /// The journal or proceedings the book declares itself part of,
        /// when it does — Visual-Meta first, then the package's own
        /// collection declarations.
        var publication: String? = nil
        /// The printed affiliations from Visual-Meta — the exported
        /// front matter rebuilds from these.
        var affiliations: [String] = []
        /// The paper's ACM Reference Format, from Visual-Meta.
        var acmReference: String? = nil
        /// Each author's ORCID, keyed by name, from Visual-Meta.
        var authorORCIDs: [String: String] = [:]
        /// Each author's email, keyed by name, from Visual-Meta.
        var authorEmails: [String: String] = [:]
        /// Each author's affiliation line, keyed by name, from Visual-Meta.
        var authorAffiliations: [String: String] = [:]
        /// The license/copyright block, from Visual-Meta.
        var license: String? = nil
        /// YYYY-MM-DD from the package metadata.
        let date: String?
        /// The publication identifier (urn:uuid:…), for provenance.
        let identifier: String?
        /// The document's original origami address, when the EPUB
        /// carries one — the receiving library may keep it, so
        /// citations to the book resolve wherever it arrives.
        let origamiID: String?
        /// Bare DOI (e.g. "10.1145/3290605.3300526"), when the package
        /// declares one — used to match the book against acquisition wishes.
        var doi: String? = nil
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
        let zip = try ZipReader(url: url)
        return try importDocument(from: PackageSource(
            entry: { zip.entry($0) },
            entryWithSuffix: { suffix in
                zip.entryNames.first { $0.hasSuffix(suffix) }.flatMap { zip.entry($0) }
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

        // Both records are declared in the package as <link rel="record">
        // carrying a `properties` value that says which record it is. The
        // profile forbids finding them by filename, so the declaration is
        // asked first; the well-known name is the pre-1.0 fallback, and the
        // embedded copy is Visual-Meta's last resort.
        let declaredRecord: (String) -> Data? = { properties in
            recordHref(in: opf, properties: properties).flatMap { href in
                source.entry(joinedPath(opfDirectory, href)) ?? source.entry(href)
            }
        }
        let visualMetaData = declaredRecord("origami:visual-meta")
            ?? source.entry("visual-meta.json")
            ?? source.entryWithSuffix("visual-meta.json")
            ?? embeddedVisualMeta(in: html)
        let visualMeta = visualMetaData.flatMap {
            (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]
        }

        // The interaction record is read whether or not the semantic record
        // is there. The profile divides them — concepts, citations and
        // structure in Visual-Meta; tables, layouts and models here — but
        // every pre-1.0 export carries the semantic keys in both. So each
        // fact has one home and one fallback rather than being merged:
        // merging two copies of a reference list turned 32 references
        // into 63.
        let origamiJSON: [String: Any]? = (declaredRecord("origami:interaction")
            ?? source.entry("origami.json")
            ?? source.entryWithSuffix("origami.json"))
            .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }

        // The citation pool, split back into its two homes: internal
        // citations (an origamitext:// URL names their address) become
        // links again; external records become references. Visual-Meta is
        // authoritative for citations; the interaction record answers only
        // when Visual-Meta said nothing at all.
        var pool = citationPool(fromVisualMeta: visualMeta)
        if pool.references.isEmpty, pool.addressByCitationID.isEmpty,
           let origamiJSON {
            pool = citationPool(fromOrigamiJSON: origamiJSON)
        }
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

        // Authored layouts belong to the interaction record; pre-1.0
        // exports put them in Visual-Meta, so that is the fallback.
        let map = (origamiJSON?["map"] as? [String: Any])
            ?? (visualMeta?["map"] as? [String: Any])
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

        // Live tables: the `tables` array is the raw source (values and
        // formulas both); the body's <table> elements only supply placement
        // (their data-table-id links here). The interaction record owns it
        // in the profile, Visual-Meta held it before that.
        let tableSource = origamiJSON?["tables"] ?? visualMeta?["tables"]
        let tables: [LiquidDoc.Table] = dictionaries(tableSource).compactMap { raw in
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

        let equationHref = joinedPath(opfDirectory, contentHref)

        // Resolve an image `src` (relative to the content document) to its
        // bytes in the package, so figures import as assets.
        let contentDir = (equationHref as NSString).deletingLastPathComponent
        let resolveImage: (String) -> Data? = { src in
            let full = joinedPath(contentDir, src)
            return source.entry(full)
                ?? source.entry(src)
                ?? source.entryWithSuffix("/\((src as NSString).lastPathComponent)")
        }

        // Every spine document is read, in order. An element's address is
        // its document path plus its id, so nothing is renamed to keep ids
        // distinct across documents — the path does that. Ids are never
        // rewritten: a rewritten id is not the id the publication
        // published, and every citation, annotation and metadata reference
        // to it would silently fail to resolve.
        //
        // Two details earn their keep. A publication that carries records
        // skips its glossary, bibliography and endnote *sections*, because
        // the records supply those entries — reading them as body text as
        // well printed the reference list twice. The judgement is per
        // section rather than per document so that a colophon sitting
        // beside them still reaches the reader, which is the whole point
        // of a colophon. And a multi-document book keeps images within a
        // budget so a picture-heavy one does not balloon the document (the
        // markers stay visible regardless); a single document has no
        // budget, as before.
        var body: [LiquidDoc.Paragraph] = []
        var bodyAssets: [LiquidDoc.Asset] = []
        var capturedFootnotes: [(id: String, text: String)] = []
        let capture = CitationCapture()
        let hasRecords = visualMeta != nil || origamiJSON != nil
        // A publication that declares the profile has canonical addresses
        // of the form `path#id`, always — whether it holds one content
        // document or twenty (profile §5.1). Bare ids are the pre-1.0
        // form, kept only for publications that do not declare the
        // profile, so that annotations already written against them still
        // resolve. This is a property of the migration, not of the format.
        let declaresProfile = firstCapture(
            in: opf,
            pattern: "<meta[^>]*property=\"dcterms:conformsTo\"[^>]*>\\s*([^<]+)")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .hasPrefix("https://origamitext.org/profile/") ?? false
        let readable: [(href: String, xhtml: String)] = spineContentHrefs(in: opf)
            .compactMap { href in
                guard let data = source.entry(joinedPath(opfDirectory, href))
                        ?? source.entry(href) else { return nil }
                return (href, String(decoding: data, as: UTF8.self))
            }
        var imageBudget = readable.count > 1 ? 12_000_000 : Int.max
        typealias Read = (paragraphs: [LiquidDoc.Paragraph], assets: [LiquidDoc.Asset],
                          footnotes: [(id: String, text: String)], bodyBearing: Int)
        let read: (String, String, Bool, Int) -> Read? = { href, xhtml, qualifying, offset in
            let documentDir = (joinedPath(opfDirectory, href) as NSString)
                .deletingLastPathComponent
            let resolve: (String) -> Data? = { src in
                let full = joinedPath(documentDir, src)
                guard let bytes = source.entry(full)
                        ?? source.entry(src)
                        ?? source.entryWithSuffix("/\((src as NSString).lastPathComponent)"),
                      bytes.count <= imageBudget else { return nil }
                imageBudget -= bytes.count
                return bytes
            }
            return try? bodyParagraphs(
                fromXHTML: xhtml,
                addressByCitationID: addressByCitationID,
                resolveImage: resolve,
                contentDir: documentDir,
                documentPath: qualifying ? href : "",
                skippingRecordSections: hasRecords,
                ordinalOffset: offset,
                capture: capture)
        }

        // A first pass answers one question: how many documents carry the
        // work's own text? Not how many are in the spine — a publication
        // with records has a backmatter document whose glossary and
        // bibliography belong to the records, and whose colophon is about
        // the publication rather than part of it.
        var offset = 0
        var first: [(href: String, read: Read)] = []
        for document in readable {
            guard let outcome = read(document.href, document.xhtml, true, offset),
                  !outcome.paragraphs.isEmpty else { continue }
            offset += outcome.paragraphs.count
            first.append((document.href, outcome))
        }
        // A pre-1.0 publication with one body document keeps bare ids, so
        // the annotations already written against it still resolve. A
        // publication that declares the profile is addressed by path and
        // fragment unconditionally: an element's identity must not depend
        // on how many documents happen to sit beside it (§5.1). The
        // re-read costs one parse, and only in the legacy case.
        let bodyDocuments = first.filter { $0.read.bodyBearing > 0 }.count
        var parts = first
        if !declaresProfile, bodyDocuments <= 1, !first.isEmpty {
            imageBudget = Int.max
            offset = 0
            parts = []
            for document in readable {
                guard let outcome = read(document.href, document.xhtml, false, offset),
                      !outcome.paragraphs.isEmpty else { continue }
                offset += outcome.paragraphs.count
                parts.append((document.href, outcome))
            }
        }
        for part in parts {
            body += part.read.paragraphs
            bodyAssets += part.read.assets
            capturedFootnotes += part.read.footnotes
        }
        guard !body.isEmpty else { throw OrigamiEPUBImportError.missingContent }

        // Mathematics: prefer a Visual-Meta equations block, fall back to a
        // scan of the `math[id]` elements. MathML in the body renders
        // natively in the reader; this index powers citing and copying
        // equations. The block's entries carry their own hrefs and so
        // already span documents; a body scan is run per document, with
        // that document's href, or an equation in a later part would have
        // no address to be cited by.
        let fromBlock = EquationIndex.build(visualMetaText: html,
                                            contentHTML: html,
                                            contentHref: equationHref)
        let equations: [EquationEntry] = fromBlock.fromVisualMeta
            ? fromBlock.entries
            : readable.flatMap { document in
                EquationIndex.build(visualMetaText: nil,
                                    contentHTML: document.xhtml,
                                    contentHref: joinedPath(opfDirectory, document.href)).entries
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
                // The record's own href is the note's address, already
                // path-qualified, and it is what the dagger in the body
                // resolves to. Using the bare id instead left the two
                // forms apart in a profile publication, so the reveal
                // found nothing.
                let noteID = (node["href"] as? String)
                    .flatMap { $0.contains("#") ? $0 : nil }
                    ?? node["id"] as? String
                    ?? "en-\(offset + 1)"
                return LiquidDoc.Paragraph(id: noteID,
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
        // One boundary: the document's own reference keys and note ids
        // are internal — a [cite:key] token names the reference list,
        // not an outgoing link. Manufacturing links for them doubled
        // the reference list on the next export (32 came back as 63).
        // Our own exports' notes come back as body paragraphs (fn1…),
        // so the body's stable ids count as internal too.
        let internalIDs = Set(references.map(\.id))
            .union(notes.map(\.id))
            .union(body.map(\.id))
        var links = LiquidDoc.detectedLinks(in: body)
            .filter { !internalIDs.contains($0.to) }
            .map { link -> LiquidDoc.Link in
                guard link.bibtex == nil, let bibtex = bibtexByAddress[link.to] else { return link }
                var enriched = link
                enriched.bibtex = bibtex
                return enriched
            }
        for (address, bibtex) in bibtexByAddress.sorted(by: { $0.key < $1.key })
        where !internalIDs.contains(address) && !links.contains(where: { $0.to == address }) {
            links.append(LiquidDoc.Link(to: address, fragment: nil, rel: "cites", bibtex: bibtex))
        }
        for address in addressByCitationID.values.sorted()
        where bibtexByAddress[address] == nil && !internalIDs.contains(address)
            && !links.contains(where: { $0.to == address }) {
            links.append(LiquidDoc.Link(to: address, fragment: nil, rel: "cites", bibtex: nil))
        }

        let document = visualMeta?["document"] as? [String: Any]
        let origamiDoc = origamiJSON?["document"] as? [String: Any]
        // Visual-Meta authors are strings; origami.json authors are {name:} or
        // {family:, given:} objects (academic EPUB format).
        let metaAuthors: [String] = {
            if let vmAuthors = (document?["authors"] as? [String])?
                .map({ $0.trimmingCharacters(in: .whitespaces) })
                .filter({ !$0.isEmpty }), !vmAuthors.isEmpty { return vmAuthors }
            if let ojAuthors = origamiDoc?["authors"] as? [[String: Any]] {
                let names = ojAuthors.compactMap { author -> String? in
                    if let name = author["name"] as? String { return name }
                    if let family = author["family"] as? String {
                        let given = (author["given"] as? String ?? "")
                            .trimmingCharacters(in: .whitespaces)
                        return given.isEmpty ? family : "\(given) \(family)"
                    }
                    return nil
                }
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                if !names.isEmpty { return names }
            }
            return []
        }()
        let metaVenue = ["journal", "proceedings", "publication", "booktitle"]
            .compactMap { document?[$0] as? String }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        // Academic origami.json embeds venue under a "venue" sub-dict.
        let origamiVenue: String? = {
            guard let venue = origamiDoc?["venue"] as? [String: Any] else { return nil }
            return (venue["journal"] as? String)
                ?? (venue["booktitle"] as? String)
                ?? (venue["publisher"] as? String)
        }()
        let doiFromMeta = (document?["doi"] as? String).flatMap(normalizedDOI)
            ?? (origamiDoc?["doi"] as? String).flatMap(normalizedDOI)
        return ImportResult(
            title: document?["title"] as? String ?? origamiDoc?["title"] as? String ?? title ?? "Untitled",
            subtitle: (document?["subtitle"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            author: metaAuthors.first ?? creator,
            authors: metaAuthors.isEmpty ? creators : metaAuthors,
            publication: metaVenue ?? origamiVenue ?? opfVenue,
            affiliations: (document?["affiliations"] as? [String])?
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty } ?? [],
            acmReference: (document?["acm-reference"] as? String)
                .flatMap { $0.isEmpty ? nil : $0 },
            authorORCIDs: (document?["author-orcids"] as? [String: String]) ?? [:],
            authorEmails: (document?["author-emails"] as? [String: String]) ?? [:],
            authorAffiliations: (document?["author-affiliations"] as? [String: String]) ?? [:],
            license: (document?["license"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            date: document?["date"] as? String ?? date,
            identifier: document?["identifier"] as? String ?? identifier,
            origamiID: document?["origami-id"] as? String,
            doi: doiFromMeta ?? extractDOI(from: opf),
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
        let zip = try ZipReader(url: url)
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: directory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        for name in zip.entryNames {
            guard let data = zip.entry(name) else { continue }
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

    /// Lightweight metadata extracted from an already-unpacked package —
    /// reads only the OPF and (at most) the first spine document for a
    /// Visual-Meta check. Does NOT parse body paragraphs, so it stays
    /// fast even for large multi-chapter books.
    struct PackageMetadata: Sendable {
        let origamiID: String?
        let authors: [String]
        let author: String?
        let date: String?
        let publication: String?
        var doi: String? = nil
        var identifier: String? = nil
    }

    static func importMetadata(inUnpackedFolder folder: URL) -> PackageMetadata {
        let containerURL = folder.appendingPathComponent("META-INF/container.xml")
        let opfSubpath = (try? String(contentsOf: containerURL, encoding: .utf8))
            .flatMap { firstCapture(in: $0, pattern: "full-path=\"([^\"]+)\"") }
            ?? "package.opf"
        guard let opf = try? String(
            contentsOf: folder.appendingPathComponent(opfSubpath), encoding: .utf8)
        else { return PackageMetadata(origamiID: nil, authors: [], author: nil,
                                      date: nil, publication: nil) }
        let opfDirectory = (opfSubpath as NSString).deletingLastPathComponent
        let creators = allTagTexts(in: opf, tag: "dc:creator")
        let date = firstTagText(in: opf, tag: "dc:date")
        let packageID = firstTagText(in: opf, tag: "dc:identifier")
        let opfVenue = [
            firstCapture(in: opf, pattern: "<meta[^>]*property=\"belongs-to-collection\"[^>]*>([^<]*)</meta>"),
            firstCapture(in: opf, pattern: "<meta[^>]*property=\"dcterms:isPartOf\"[^>]*>([^<]*)</meta>"),
            firstCapture(in: opf, pattern: "<meta[^>]*name=\"calibre:series\"[^>]*content=\"([^\"]*)\"")
        ]
            .compactMap { $0 }
            .map(xmlUnescaped)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }

        // Visual-Meta: package file first, then the first spine document.
        // Only the metadata block is needed — body parsing is intentionally skipped.
        let packageVMURL = folder.appendingPathComponent("visual-meta.json")
        var visualMetaData: Data? = (try? Data(contentsOf: packageVMURL))
        if visualMetaData == nil, let href = spineContentHref(in: opf),
           let html = try? String(
               contentsOf: folder.appendingPathComponent(joinedPath(opfDirectory, href)),
               encoding: .utf8) {
            visualMetaData = embeddedVisualMeta(in: html)
        }
        let visualMeta = visualMetaData
            .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }

        // Author EPUB format: origami.json carries document metadata when
        // Visual-Meta is absent. Its authors are {name:} objects, not strings.
        if visualMeta == nil {
            let origamiURL = folder.appendingPathComponent(joinedPath(opfDirectory, "origami.json"))
            if let data = (try? Data(contentsOf: origamiURL)),
               let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let doc = json["document"] as? [String: Any] {
                // Authors may be {name:} objects (Author format) or
                // {family:, given:} objects (academic EPUB format).
                let ojAuthors = (doc["authors"] as? [[String: Any]])?
                    .compactMap { author -> String? in
                        if let name = author["name"] as? String { return name }
                        if let family = author["family"] as? String {
                            let given = (author["given"] as? String ?? "")
                                .trimmingCharacters(in: .whitespaces)
                            return given.isEmpty ? family : "\(given) \(family)"
                        }
                        return nil
                    }
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty } ?? []
                // Prefer the origami.json venue (academic EPUBs embed it)
                let ojVenue: String? = {
                    guard let venue = doc["venue"] as? [String: Any] else { return nil }
                    return (venue["journal"] as? String)
                        ?? (venue["booktitle"] as? String)
                        ?? (venue["publisher"] as? String)
                }()
                let doi = (doc["doi"] as? String).flatMap(normalizedDOI)
                    ?? extractDOI(from: opf)
                return PackageMetadata(
                    origamiID: nil,
                    authors: ojAuthors.isEmpty ? creators : ojAuthors,
                    author: ojAuthors.first ?? creators.first,
                    date: doc["date"] as? String ?? date,
                    publication: ojVenue ?? opfVenue,
                    doi: doi,
                    identifier: packageID)
            }
        }

        let document = visualMeta?["document"] as? [String: Any]
        let metaAuthors = (document?["authors"] as? [String])?
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty } ?? []
        let metaVenue = ["journal", "proceedings", "publication", "booktitle"]
            .compactMap { document?[$0] as? String }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        let doiFromMeta = (document?["doi"] as? String).flatMap(normalizedDOI)
        return PackageMetadata(
            origamiID: document?["origami-id"] as? String,
            authors: metaAuthors.isEmpty ? creators : metaAuthors,
            author: metaAuthors.first ?? creators.first,
            date: document?["date"] as? String ?? date,
            publication: metaVenue ?? opfVenue,
            doi: doiFromMeta ?? extractDOI(from: opf),
            identifier: packageID)
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

    /// Joins an OPF-relative directory and href — the one copy every
    /// importer shares (LaTeXImporter delegates here).
    static func joinedPath(_ directory: String, _ name: String) -> String {
        directory.isEmpty ? name : "\(directory)/\(name)"
    }

    /// Extracts the DOI from a package document, or nil when none is found.
    /// Recognises scheme="doi", prism:doi meta, and any dc:identifier whose
    /// value begins with "10." after stripping the common URL/prefix forms.
    static func extractDOI(from opf: String) -> String? {
        let candidates = [
            firstCapture(in: opf, pattern: "<dc:identifier[^>]*scheme=[\"']doi[\"'][^>]*>([^<]+)</dc:identifier>"),
            firstCapture(in: opf, pattern: "<dc:identifier[^>]*opf:scheme=[\"']doi[\"'][^>]*>([^<]+)</dc:identifier>"),
            firstCapture(in: opf, pattern: "<meta[^>]*property=[\"']prism:doi[\"'][^>]*>([^<]+)</meta>"),
            firstCapture(in: opf, pattern: "<meta[^>]*property=[\"']schema:doi[\"'][^>]*>([^<]+)</meta>"),
            firstCapture(in: opf, pattern: "<dc:identifier[^>]*>([^<]*10\\.[0-9]{4,}/[^<]+)</dc:identifier>"),
        ]
        return candidates.compactMap { $0 }.compactMap(normalizedDOI).first
    }

    private static func normalizedDOI(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = ["https://doi.org/", "http://doi.org/",
                        "https://dx.doi.org/", "http://dx.doi.org/",
                        "doi:", "DOI:"]
        for p in prefixes where s.lowercased().hasPrefix(p.lowercased()) {
            s = String(s.dropFirst(p.count))
            break
        }
        return s.hasPrefix("10.") ? s.lowercased() : nil
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

    /// The sections whose entries come from the records instead: the
    /// glossary, the bibliography, the endnotes. Named by EPUB's own
    /// structural semantics, so the judgement is the document's own rather
    /// than a guess from a filename.
    ///
    /// A colophon is deliberately absent. It is the one piece of
    /// backmatter written to be read — the human-readable statement of
    /// what metadata the publication carries and where — so it belongs in
    /// the flow.
    private static let recordSectionTypes: Set<String> =
        ["glossary", "bibliography", "endnotes"]

    /// Whether this element is such a section.
    private static func isRecordSection(_ element: XMLTree.Element) -> Bool {
        sectionKinds(of: element).contains(where: recordSectionTypes.contains)
    }

    /// Whether this element is the publication's colophon — the
    /// human-readable statement of what metadata it carries and where.
    private static func isColophonSection(_ element: XMLTree.Element) -> Bool {
        sectionKinds(of: element).contains("colophon")
    }

    private static func sectionKinds(of element: XMLTree.Element) -> [String] {
        let declared = element.attributes["epub:type"]
            ?? element.attributes["role"]
            ?? ""
        return declared.split(separator: " ")
            // DPUB-ARIA spells the same semantics `doc-bibliography`.
            .map { String($0.hasPrefix("doc-") ? $0.dropFirst(4) : $0) }
    }

    /// A package-declared metadata record's href. The profile declares each
    /// record as `<link rel="record" properties="origami:…">` in the package
    /// metadata, so a reader finds a record by what it says it is rather
    /// than by what it happens to be called.
    private static func recordHref(in opf: String, properties: String) -> String? {
        for link in captures(in: opf, pattern: "<link\\s[^>]*>") {
            guard let rel = firstCapture(in: link, pattern: "\\srel=\"([^\"]+)\""),
                  rel.split(separator: " ").contains("record"),
                  let declared = firstCapture(in: link, pattern: "\\sproperties=\"([^\"]+)\""),
                  declared.split(separator: " ").map(String.init).contains(properties),
                  let href = firstCapture(in: link, pattern: "\\shref=\"([^\"]+)\"")
            else { continue }
            return xmlUnescaped(href)
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
    /// Also accepts the https://origamitext.app/o/ carrier form so Author's
    /// web-safe URLs resolve the same way.
    private static func originalAddress(fromOpenURL url: String) -> String? {
        let origamiPrefix = "origamitext://open/"
        if url.hasPrefix(origamiPrefix) {
            let address = String(url.dropFirst(origamiPrefix.count))
            return address.isEmpty ? nil : address
        }
        let webPrefix = OrigamiCitation.webCarrierPrefix
        if url.hasPrefix(webPrefix) {
            var rest = String(url.dropFirst(webPrefix.count))
            if let q = rest.firstIndex(of: "?") { rest = String(rest[..<q]) }
            if let h = rest.firstIndex(of: "#") { rest = String(rest[..<h]) }
            return rest.isEmpty ? nil : rest
        }
        return nil
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
                                       contentDir: String = "",
                                       documentPath: String = "",
                                       skippingRecordSections: Bool = false,
                                       ordinalOffset: Int = 0,
                                       capture: CitationCapture? = nil)
        throws -> (paragraphs: [LiquidDoc.Paragraph], assets: [LiquidDoc.Asset],
                   footnotes: [(id: String, text: String)], bodyBearing: Int) {
        // Strip <script> elements before XML parsing: their JSON/JS content
        // may contain bare & characters (e.g. bibtex strings) that are valid
        // JSON but not valid XML, causing NSXMLParser to reject the file.
        // The visitor never uses script content — metadata is read separately
        // from origami.json.
        let sanitized = html.replacingOccurrences(
            of: #"<script\b[^>]*>[\s\S]*?</script>"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        let root = try XMLTree.parse(Data(sanitized.utf8))
        // The Origami profile wraps the flow in <main>; a plain EPUB's
        // chapters write their content straight into <body>.
        let documentBody = root.firstDescendant(named: "body")
        guard let main = root.firstDescendant(named: "main") ?? documentBody else {
            throw OrigamiEPUBImportError.missingContent
        }

        // An element's address is its document path and its id. With one
        // content document the path is dropped and the published id stands
        // alone; with many, the path is what keeps ids distinct. Either
        // way the id itself travels exactly as published.
        let address: (String) -> String = { id in
            documentPath.isEmpty ? id : "\(documentPath)#\(id)"
        }

        var paragraphs: [LiquidDoc.Paragraph] = []
        var assets: [LiquidDoc.Asset] = []
        var footnotes: [(id: String, text: String)] = []
        var assetOrdinal = 0
        // Synthesised ids (`p12` for a paragraph the publication left
        // unnamed) continue across documents rather than restarting, so
        // they stay distinct even where addresses carry no path.
        var fallbackOrdinal = ordinalOffset
        // How many paragraphs came from the work itself rather than from a
        // colophon. A colophon is *about* the publication, so a document
        // holding only one does not make the publication multi-document —
        // which matters, because that decision is what chooses between
        // bare ids and path-qualified addresses.
        var bodyBearing = 0
        var colophonDepth = 0

        var currentBoxID: String?
        var boxOrdinal = 0
        // Where each HTML id lands: the anchors a \label left behind —
        // on a section container, on an element that became a paragraph,
        // or on an inline <a id> inside one — each mapped to the
        // paragraph a jump should scroll to. Container ids wait in
        // pendingAnchors until the first paragraph under them appears.
        var anchorTargets: [String: String] = [:]
        var pendingAnchors: [String] = []
        // Which kind of list the walk is inside, and where an ordered one
        // has got to — so `<li>` items come back as the "• " or "1. "
        // paragraphs the author wrote.
        var listDepthOrdered: [Bool] = []
        var orderedItemNumber = 1
        func appendParagraph(_ paragraph: LiquidDoc.Paragraph,
                             anchors element: XMLTree.Element? = nil) {
            if let element { pendingAnchors.append(contentsOf: descendantIDs(of: element)) }
            for anchor in pendingAnchors where anchorTargets[anchor] == nil {
                anchorTargets[anchor] = paragraph.id
            }
            pendingAnchors.removeAll()
            if colophonDepth == 0 { bodyBearing += 1 }
            paragraphs.append(paragraph)
        }
        func visit(_ element: XMLTree.Element, stretchID: String? = nil) {
            // <h2> is the profile's top rank; a plain book's <h1>
            // chapter titles read at the same rank, its deeper ranks
            // one step finer each.
            let headingLevels = ["h1": 1, "h2": 1, "h3": 2, "h4": 3, "h5": 3, "h6": 3]
            let stableID: () -> String = {
                fallbackOrdinal += 1
                return address(element.attributes["data-id"]
                    ?? element.attributes["id"]
                    ?? "p\(fallbackOrdinal)")
            }
            switch element.name {
            case "section", "div", "article":
                // A glossary, bibliography or endnote section is the
                // records' business: they supply those entries, and
                // reading the section as well printed the reference list
                // twice. Skipped only where records exist — a plain EPUB's
                // bibliography is the only copy it has. A colophon is
                // never skipped: it is written to be read.
                if skippingRecordSections, isRecordSection(element) { return }
                // The container's id (a <section id> from \label after
                // \section) waits for its first paragraph.
                if let id = element.attributes["id"], !id.isEmpty {
                    pendingAnchors.append(id)
                }
                let colophon = isColophonSection(element)
                if colophon { colophonDepth += 1 }
                for child in element.elements { visit(child, stretchID: stretchID) }
                if colophon { colophonDepth -= 1 }
            case "aside":
                // The export's stretchtext detail: the toggled anchor in
                // the host paragraph is chrome, but the aside's content
                // stays foldable — its paragraphs carry the block's id.
                if (element.attributes["class"] ?? "").contains("ot-box") {
                    // A framed box (the print's tcolorbox/promptbox):
                    // its paragraphs keep the group id for re-export.
                    boxOrdinal += 1
                    let boxID = element.attributes["data-box-id"] ?? "box\(boxOrdinal)"
                    let saved = currentBoxID
                    currentBoxID = boxID
                    for child in element.elements { visit(child, stretchID: stretchID) }
                    currentBoxID = saved
                } else if (element.attributes["class"] ?? "").contains("ot-stretchtext-content") {
                    let blockID = element.attributes["id"].map(address) ?? stableID()
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
                        if !text.isEmpty { footnotes.append((address(id), text)) }
                    }
                } else {
                    if let id = element.attributes["id"], !id.isEmpty {
                        pendingAnchors.append(id)
                    }
                    for child in element.elements { visit(child, stretchID: stretchID) }
                }
            case "hr":
                appendParagraph(LiquidDoc.Paragraph(id: stableID(), heading: nil, text: "---"))
            case "pre":
                // A code block comes back as the fenced paragraph the
                // exporter wrote it from — whitespace exactly as is.
                let language = element.attributes["data-language"] ?? ""
                let code = element.plainText.trimmingCharacters(in: .newlines)
                if !code.isEmpty {
                    appendParagraph(LiquidDoc.Paragraph(
                        id: stableID(), heading: nil,
                        text: "```\(language)\n\(code)\n```"), anchors: element)
                }
            case "model":
                // A literal <model> element: the shape Author exported
                // before 22 September 2026 (§13). Packages written since
                // carry no such element — the element is not in EPUB's
                // content model, and EPUBCheck rejects any file holding
                // one — so this branch exists only for books already on
                // disk. It states the same facts, on the element itself
                // and on its <source> children.
                let sourceChild = element.firstDescendant(named: "source")
                guard let src = element.attributes["src"] ?? sourceChild?.attributes["src"],
                      !src.isEmpty else {
                    for child in element.elements { visit(child, stretchID: stretchID) }
                    return
                }
                let poster = element.firstDescendant(named: "img")
                // The fallback <img>'s alt is the description on this
                // shape; Author had no description field when it was
                // written, so it is often empty, and empty stands.
                let modelAlt = poster?.attributes["alt"]
                    ?? element.attributes["alt"] ?? ""
                var legacy = spatialFigureFacts(
                    from: element, path: joinedPath(contentDir, src), alt: modelAlt)
                if let type = sourceChild?.attributes["type"], !type.isEmpty {
                    legacy.mediaType = type
                }
                if let poster, let posterSrc = poster.attributes["src"], !posterSrc.isEmpty,
                   let data = resolveImage(posterSrc), !data.isEmpty {
                    assetOrdinal += 1
                    let assetID = address("img\(assetOrdinal)")
                    let name = (posterSrc as NSString).lastPathComponent
                    let ext = (name as NSString).pathExtension.lowercased()
                    assets.append(LiquidDoc.Asset(
                        id: assetID,
                        filename: name.isEmpty ? "\(assetID).png" : name,
                        mediaType: LiquidDoc.mediaType(forExtension: ext),
                        dataBase64: data.base64EncodedString(),
                        alt: modelAlt.isEmpty ? nil : modelAlt))
                    legacy.posterID = assetID
                }
                appendParagraph(LiquidDoc.Paragraph(
                    id: stableID(), heading: nil,
                    text: LiquidDoc.modelMarker(for: legacy)), anchors: element)
            case "figure", "img":
                // A spatial figure first. A 3D model is carried by
                // whichever element holds `data-model-src` — the <img>
                // poster in the normal case, an <a> where the writer
                // chose no poster — and it is found by that attribute
                // alone, never by the tag name and never by looking for
                // a <model> element, which current packages do not
                // contain (§3.3, §7). `model-upgrade.js` sits in the
                // package for Safari's sake; it is never run here, and
                // never needs to be.
                if let carrier = element.firstDescendant(carrying: "data-model-src"),
                   let modelSrc = carrier.attributes["data-model-src"], !modelSrc.isEmpty {
                    // The figure's words are its <figcaption>, which the
                    // poster's alt repeats. Where the writer wrote no
                    // description there is neither a figcaption nor an
                    // alt, and nothing is then what a reader shows: the
                    // file name is not a description, and presenting it
                    // as one would assert an accessibility the document
                    // does not have (§9). An <a> carrier's link text is
                    // the file name, so it is deliberately not read.
                    let caption = element.firstDescendant(named: "figcaption")?.plainText
                        .replacingOccurrences(of: #"\s+"#, with: " ",
                                              options: .regularExpression)
                        .trimmingCharacters(in: .whitespaces) ?? ""
                    let words = caption.isEmpty
                        ? (carrier.attributes["alt"] ?? "") : caption
                    var figure = spatialFigureFacts(
                        from: carrier, path: joinedPath(contentDir, modelSrc), alt: words)
                    // The poster is real content, not a placeholder: it
                    // becomes an asset like any figure's image, and it
                    // is what stands until a reader deliberately asks
                    // for the model (§6).
                    if let posterSrc = carrier.attributes["src"], !posterSrc.isEmpty,
                       let data = resolveImage(posterSrc), !data.isEmpty {
                        assetOrdinal += 1
                        let assetID = address("img\(assetOrdinal)")
                        let name = (posterSrc as NSString).lastPathComponent
                        let ext = (name as NSString).pathExtension.lowercased()
                        assets.append(LiquidDoc.Asset(
                            id: assetID,
                            filename: name.isEmpty ? "\(assetID).png" : name,
                            mediaType: LiquidDoc.mediaType(forExtension: ext),
                            dataBase64: data.base64EncodedString(),
                            alt: words.isEmpty ? nil : words))
                        figure.posterID = assetID
                    }
                    // The paragraph takes the <figure>'s own anchors, so
                    // the `P-<uuid>` id internal links and citations
                    // resolve to lands on this figure (§3.4).
                    appendParagraph(LiquidDoc.Paragraph(
                        id: stableID(), heading: nil,
                        text: LiquidDoc.modelMarker(for: figure)), anchors: element)
                    return
                }
                // A figure/image comes back as an asset plus an
                // `![alt](asset:id)` marker paragraph — the same form the
                // exporter reads, so authoring round-trips.
                let image = element.name == "img" ? element : element.firstDescendant(named: "img")
                guard let image, let src = image.attributes["src"], !src.isEmpty else {
                    for child in element.elements { visit(child, stretchID: stretchID) }
                    return
                }
                // The visible caption first — the <figcaption> IS the
                // caption; the img's alt repeats it (or, in a foreign
                // EPUB, may say something else). Either way one line of
                // words rides the marker, never two elements.
                let figcaption = element.name == "figure"
                    ? element.firstDescendant(named: "figcaption")?.plainText
                        .replacingOccurrences(of: #"\s+"#, with: " ",
                                              options: .regularExpression)
                        .trimmingCharacters(in: .whitespaces)
                    : nil
                let alt = figcaption.flatMap { $0.isEmpty ? nil : $0 }
                    ?? image.attributes["alt"] ?? ""
                let paragraphID = stableID()
                if let data = resolveImage(src), !data.isEmpty {
                    assetOrdinal += 1
                    let assetID = address("img\(assetOrdinal)")
                    let name = (src as NSString).lastPathComponent
                    let ext = (name as NSString).pathExtension.lowercased()
                    assets.append(LiquidDoc.Asset(
                        id: assetID,
                        filename: name.isEmpty ? "\(assetID).png" : name,
                        mediaType: LiquidDoc.mediaType(forExtension: ext),
                        dataBase64: data.base64EncodedString(),
                        alt: alt.isEmpty ? nil : alt))
                    appendParagraph(LiquidDoc.Paragraph(
                        id: paragraphID, heading: nil, text: "![\(alt)](asset:\(assetID))"),
                        anchors: element)
                } else {
                    // Bytes missing: keep the reference visible rather than
                    // dropping the image silently.
                    appendParagraph(LiquidDoc.Paragraph(
                        id: paragraphID, heading: nil, text: "![\(alt)](\(src))"),
                        anchors: element)
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
                appendParagraph(paragraph, anchors: element)
            case "h1", "h2", "h3", "h4", "h5", "h6":
                let text = inlineText(of: element, addressByCitationID: addressByCitationID, capture: capture)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                appendParagraph(LiquidDoc.Paragraph(
                    id: stableID(), heading: headingLevels[element.name], text: text),
                    anchors: element)
            case "li":
                // A list item returns as the paragraph it was written as,
                // its marker restored so the document round-trips to the
                // same words. The list's own <ul>/<ol> carries no text.
                let text = inlineText(of: element, addressByCitationID: addressByCitationID,
                                      capture: capture)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                let ordered = (listDepthOrdered.last ?? false)
                let marker = ordered ? "\(orderedItemNumber). " : "• "
                if ordered { orderedItemNumber += 1 }
                appendParagraph(LiquidDoc.Paragraph(
                    id: stableID(), heading: nil, text: marker + text), anchors: element)
            case "ul", "ol":
                listDepthOrdered.append(element.name == "ol")
                let resumeNumber = orderedItemNumber
                orderedItemNumber = 1
                for child in element.elements { visit(child, stretchID: stretchID) }
                listDepthOrdered.removeLast()
                orderedItemNumber = resumeNumber
            case "p", "blockquote":
                let raw = inlineText(of: element, addressByCitationID: addressByCitationID, capture: capture)
                // Split at double newlines so that Author-style exports (which pack
                // multiple logical paragraphs into one <p> separated by \n\n) produce
                // distinct LiquidDoc.Paragraph entries. Single-paragraph content is
                // unaffected — it produces exactly one part.
                let parts = raw.components(separatedBy: "\n\n")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                guard !parts.isEmpty else { return }
                // Speaker detection applies to the first logical paragraph only.
                let speaker: String? = {
                    guard let first = element.elements.first,
                          first.name == "strong",
                          first.attributes["class"] == "speaker" else { return nil }
                    let name = first.plainText.trimmingCharacters(in: .whitespaces)
                    return name.hasSuffix(":") ? String(name.dropLast()) : nil
                }()
                for (offset, text) in parts.enumerated() {
                    let id: String
                    if offset == 0 {
                        id = stableID()
                    } else {
                        fallbackOrdinal += 1
                        id = address("p\(fallbackOrdinal)")
                    }
                    var paragraph = LiquidDoc.Paragraph(id: id, heading: nil, text: text)
                    paragraph.stretchID = stretchID
                    paragraph.boxID = currentBoxID
                    if offset == 0 { paragraph.speaker = speaker }
                    appendParagraph(paragraph, anchors: offset == 0 ? element : nil)
                }
            case "li":
                // A plain book's list items read as bulleted paragraphs —
                // never dropped with their container.
                let text = inlineText(of: element, addressByCitationID: addressByCitationID, capture: capture)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                var paragraph = LiquidDoc.Paragraph(id: stableID(), heading: nil,
                                                    text: "\u{2022} " + text)
                paragraph.stretchID = stretchID
                appendParagraph(paragraph, anchors: element)
            default:
                for child in element.elements { visit(child, stretchID: stretchID) }
            }
        }
        for child in main.elements { visit(child) }

        // A writer may put the colophon after </main> — it is end matter,
        // and one content document holds the whole publication. It is
        // also the one piece of end matter written to be read (§7.4.5),
        // so a reader must not let the <main> boundary silently withhold
        // it. Anything else outside <main> stays outside: a running
        // header would only repeat the title, and the Visual-Meta
        // payload block is metadata rather than text.
        if let documentBody, main !== documentBody {
            func visitColophons(in element: XMLTree.Element) {
                for child in element.elements where child !== main {
                    if isColophonSection(child) {
                        visit(child)
                    } else {
                        visitColophons(in: child)
                    }
                }
            }
            visitColophons(in: documentBody)
        }
        // The in-document anchors' second pass: each token's raw
        // #target becomes the id of the paragraph its \label landed on
        // — the element's own id when it became a paragraph, else the
        // first paragraph inside its container or the one holding the
        // inline anchor. A target found nowhere unwraps to its words —
        // never a dead link.
        resolveJumpAnchors(&paragraphs, anchorTargets: anchorTargets, address: address)
        return (paragraphs, assets, footnotes, bodyBearing)
    }

    /// Every `id` in the element's subtree — the anchors a \label left
    /// behind, wherever the conversion hung them.
    private static func descendantIDs(of element: XMLTree.Element) -> [String] {
        var ids: [String] = []
        if let id = element.attributes["id"], !id.isEmpty { ids.append(id) }
        for child in element.elements {
            ids.append(contentsOf: descendantIDs(of: child))
        }
        return ids
    }

    /// Rewrites the `origami-jump:#raw` placeholders inlineText left:
    /// a raw target that is itself a paragraph id resolves directly;
    /// otherwise the anchor map says which paragraph the id landed on;
    /// what resolves nowhere loses its link and keeps its words.
    private static func resolveJumpAnchors(_ paragraphs: inout [LiquidDoc.Paragraph],
                                           anchorTargets: [String: String],
                                           address: (String) -> String) {
        guard let token = try? NSRegularExpression(
            pattern: #"\[([^\]\[]*)\]\(origami-jump:#([^)\s]+)\)"#) else { return }
        let knownIDs = Set(paragraphs.map(\.id))
        for index in paragraphs.indices {
            let text = paragraphs[index].text
            guard text.contains("(origami-jump:#") else { continue }
            let whole = text as NSString
            var rewritten = text
            let matches = token.matches(in: text,
                                        range: NSRange(location: 0, length: whole.length))
            for match in matches {
                let found = whole.substring(with: match.range)
                let label = whole.substring(with: match.range(at: 1))
                let raw = whole.substring(with: match.range(at: 2))
                let resolved = knownIDs.contains(address(raw))
                    ? address(raw)
                    : anchorTargets[raw]
                let replacement = resolved.map { "[\(label)](origami-jump:\($0))" } ?? label
                rewritten = rewritten.replacingOccurrences(of: found, with: replacement)
            }
            guard rewritten != text else { continue }
            var copy = paragraphs[index].replacing(text: rewritten)
            copy.boxID = paragraphs[index].boxID
            paragraphs[index] = copy
        }
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

    /// Citation pool from the Author EPUB `origami.json` format.
    /// Two layouts are handled:
    /// - `"references"` dict (UUID-keyed): the Author export format.
    /// - `"blocks"` array: the academic EPUB format, where blocks with
    ///   `"type": "reference"` carry BibTeX and `"key"`/`"number"`.
    static func citationPool(fromOrigamiJSON json: [String: Any])
        -> (references: [LiquidDoc.Reference],
            addressByCitationID: [String: String],
            bibtexByAddress: [String: String]) {
        var references: [LiquidDoc.Reference] = []
        // Author export format: top-level UUID-keyed references dict.
        let origamiRefs = json["references"] as? [String: [String: Any]] ?? [:]
        for (key, ref) in origamiRefs {
            let bibtex = (ref["bibtex"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? ""
            let citedAs = (ref["citedAs"] as? String)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { $0.isEmpty ? nil : $0 }
            let number = (ref["number"] as? NSNumber)?.intValue
            references.append(LiquidDoc.Reference(
                id: key, bibtex: bibtex, citedAs: citedAs, number: number))
        }
        // Academic EPUB format: "blocks" array with typed entries.
        if references.isEmpty, let blocks = json["blocks"] as? [[String: Any]] {
            for block in blocks where (block["type"] as? String) == "reference" {
                let key = block["key"] as? String ?? block["id"] as? String ?? UUID().uuidString
                let bibtex = (block["bibtex"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let number = (block["number"] as? NSNumber)?.intValue
                references.append(LiquidDoc.Reference(
                    id: key, bibtex: bibtex, citedAs: nil, number: number))
            }
        }
        references.sort { ($0.number ?? Int.max) < ($1.number ?? Int.max) }
        return (references: references, addressByCitationID: [:], bibtexByAddress: [:])
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
                case "rt", "rp":
                    // Ruby readings (furigana): annotation on the base
                    // text, never the words themselves.
                    break
                case "script", "style":
                    // Data scripts and stylesheets are never paragraph text.
                    break
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
                        // data-note-id carries the token's stable id;
                        // the href points at the exported purple number
                        // (what standard readers resolve). Older
                        // exports carried the id in the href itself.
                        if let id = inner.attributes["data-note-id"], !id.isEmpty {
                            out += "[inote:\(id)]"
                        } else if let href = inner.attributes["href"],
                                  let hash = href.firstIndex(of: "#") {
                            out += "[inote:\(href[href.index(after: hash)...])]"
                        }
                    } else if (inner.attributes["epub:type"] ?? "").contains("noteref")
                        || (inner.attributes["role"] ?? "").contains("doc-noteref") {
                        // The endnote's mark: a token carrying the
                        // note's id, rendered at reading time as a
                        // clickable dagger that reveals the note.
                        if let id = inner.attributes["data-note-id"], !id.isEmpty {
                            out += "[note:\(id)]"
                        } else if let href = inner.attributes["href"],
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
                    } else if let target = inner.attributes["data-target-id"],
                              !target.isEmpty,
                              (inner.attributes["class"] ?? "").contains("ot-jump") {
                        // An in-document jump comes back as its token,
                        // the stable id intact.
                        out += "[\(content)](origami-jump:\(target))"
                    } else if let href = inner.attributes["href"],
                              OrigamiEPUBLinks.isAnchored(href: href) {
                        out += "[\(content)](\(href))"
                    } else if let href = inner.attributes["href"], href.hasPrefix("#"),
                              href.count > 1, !content.isEmpty {
                        // A plain in-document anchor — a LaTeX
                        // conversion's \ref ("Sec 6", "Figure 2"): the
                        // raw #target rides the token until the whole
                        // body is built, when it resolves to the
                        // paragraph the \label's anchor landed on
                        // (bodyParagraphs' second pass).
                        out += "[\(content)](origami-jump:#\(href.dropFirst()))"
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

// MARK: - Spatial figures

/// The facts a `[data-model-src]` carrier states about its model, read
/// under exactly the names the reading spec gives them (§4). The caller
/// supplies the package-relative path, already joined, and the figure's
/// words — its caption, never its file name (§9).
///
/// `origami.json`'s `models` array repeats all of this and the two are
/// guaranteed to agree (§5), so the attributes alone are read: they are
/// on the element the paragraph is being built from, and a reader may
/// take either as its source of truth.
private func spatialFigureFacts(from carrier: XMLTree.Element,
                                path: String,
                                alt: String) -> LiquidDoc.SpatialFigure {
    let attributes = carrier.attributes
    // Units and extent are stated together or not at all, so one
    // without the other is dropped rather than guessed from (§4.2).
    let extent = attributes["data-model-extent"]?
        .split(whereSeparator: \.isWhitespace)
        .compactMap { Double($0) }
    let statesSize = attributes["data-model-units"] == "m" && extent?.count == 3
    return LiquidDoc.SpatialFigure(
        path: path,
        alt: alt,
        posterID: nil,
        modelID: attributes["data-model-id"],
        mediaType: attributes["data-model-media-type"]
            ?? LiquidDoc.modelMediaType(forExtension: (path as NSString).pathExtension),
        // Author's own spelling on the older `<model>` shape was
        // `data-filename`; both name the writer's file.
        filename: attributes["data-model-filename"] ?? attributes["data-filename"],
        bytes: attributes["data-model-bytes"].flatMap { Int($0) },
        upAxis: attributes["data-model-up"] == "Z" ? "Z" : "Y",
        units: statesSize ? "m" : nil,
        extent: statesSize ? extent : nil,
        reduced: attributes["data-model-reduced"],
        sourceBytes: attributes["data-model-source-bytes"].flatMap { Int($0) },
        source: attributes["data-model-source"])
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
                case .element(let element):
                    // Ruby readings (furigana) annotate the base text;
                    // joined inline they would double it — 東京 must
                    // never import as 東京とうきょう.
                    element.name == "rt" || element.name == "rp"
                        ? "" : element.plainText
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

        /// The first element in this subtree — this one included —
        /// carrying the named attribute. How a spatial figure's carrier
        /// is found: the reading spec's single normative selector is
        /// `[data-model-src]`, and a reader must not rely on the tag
        /// name, the file-name pattern or the `<figure>` wrapper, since
        /// the carrier is an `<img>` where a poster exists and an `<a>`
        /// where none does (§3.3).
        func firstDescendant(carrying attribute: String) -> Element? {
            if attributes[attribute] != nil { return self }
            for element in elements {
                if let found = element.firstDescendant(carrying: attribute) { return found }
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
// through the same minimal reader. Nonisolated: pure byte work, read
// from detached tasks (the conference-zip unpack, the importers).
nonisolated final class ZipReader {

    /// One central-directory record: where the bytes sit and how they
    /// unpack — nothing is inflated until someone asks for the entry.
    private struct Record {
        let method: Int
        let start: Int
        let compressedSize: Int
        let uncompressedSize: Int
    }

    private let data: Data
    private var records: [String: Record] = [:]
    private var inflatedCache: [String: Data] = [:]
    /// Every entry name in central-directory order. Callers that only
    /// browse (an archive scan for its PDF, the .tex census) read this
    /// and never pay for a single inflation.
    private(set) var entryNames: [String] = []

    /// Maps the file rather than loading it: an archive scanned for one
    /// entry never occupies memory for the rest.
    convenience init(url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    func entry(_ name: String) -> Data? {
        if let inflated = inflatedCache[name] { return inflated }
        guard let record = records[name] else { return nil }
        let raw = slice(data, record.start, record.compressedSize)
        let bytes: Data
        switch record.method {
        case 0: bytes = raw
        case 8:
            guard let inflated = try? Self.inflated(raw, size: record.uncompressedSize)
            else { return nil }
            bytes = inflated
        default: return nil
        }
        inflatedCache[name] = bytes
        return bytes
    }

    init(data: Data) throws {
        self.data = data
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
            guard method == 0 || method == 8 else {
                throw OrigamiEPUBImportError.unsupportedCompression(method)
            }
            if records[name] == nil { entryNames.append(name) }
            records[name] = Record(method: method, start: start,
                                   compressedSize: compressedSize,
                                   uncompressedSize: uncompressedSize)
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
