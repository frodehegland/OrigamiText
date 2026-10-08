import Compression
import CryptoKit
import Foundation

nonisolated enum OrigamiEPUBImportError: LocalizedError {
    case notAnEPUB
    case unsupportedCompression(Int)
    case corruptContainer
    case missingContent
    /// The book is locked by a DRM scheme, named when it can be told.
    case protected(String)

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
        case .protected(let scheme):
            "This book is copy-protected (\(scheme)). Origami Text can open only books without DRM — open it in the app it was bought for, or ask the publisher for a DRM-free copy."
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
        /// Content documents the reading styles could not read.
        var unreadableDocuments: [String] = []
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
        /// The journal, when Visual-Meta states one apart from the
        /// proceedings — `document.journal` beside `document.publication`.
        var journal: String? = nil
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
        /// The abstract, the keywords, the ISBN and the CCS concepts —
        /// front matter a renderer places, rather than body text it has
        /// to recognise.
        var abstract: String? = nil
        var keywords: [String] = []
        var isbn: String? = nil
        var ccsConcepts: [String] = []
        /// The license/copyright block as a person reads it — `dc:rights`
        /// in the package, `document.rights` in the record (profile §4.8).
        var license: String? = nil
        /// The licence as a URI — `dcterms:license`. The actionable half:
        /// comparable and resolvable, where the prose above is neither.
        var licenseURI: String? = nil
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
        /// The BCP 47 tag of the document's own values — the record's
        /// `document.language`, else the package's `dc:language` (§5.5).
        var language: String? = nil
        /// Front-matter values' languages and alternate forms, by
        /// invariant property name; and each author name's.
        var forms: [String: LiquidDoc.LanguageForms] = [:]
        var authorForms: [String: LiquidDoc.LanguageForms] = [:]
        /// How the publication says its BibTeX is written (§11.1), when
        /// its semantic record declares it.
        var bibliographyConventions: BibTeXConventions? = nil
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
        let html = decodedText(contentData)

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
        // A newer MAJOR profile than this reader knows is read as an
        // ordinary EPUB (§16.2): its records may mean what 1.0 does not.
        // The reader says so in the book's notice strip.
        let newerProfile = (profileMajor(in: opf) ?? 1) > 1
        let visualMetaData = newerProfile ? nil
            : declaredRecord("origami:visual-meta")
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
        let origamiJSON: [String: Any]? = (newerProfile ? nil
            : declaredRecord("origami:interaction")
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
        var addressByCitationID = pool.addressByCitationID
        var bibtexByAddress = pool.bibtexByAddress
        var references = pool.references
        // Profile 1.0 §11: the bibliography record is canonical, and the
        // citations carry no BibTeX of their own. Read it when the
        // metadata's citations brought none — Author's EPUBs, and any
        // conforming 1.0 publication.
        if references.isEmpty, !newerProfile {
            let recordPath = bibliographyHref(in: opf)
            let data = recordPath.flatMap {
                source.entry(joinedPath(opfDirectory, $0)) ?? source.entry($0)
            } ?? source.entry("references.bib") ?? source.entryWithSuffix("references.bib")
            if let data {
                references = referencesFromBibliography(
                    String(decoding: data, as: UTF8.self),
                    citations: dictionaries(visualMeta?["citations"]),
                    listText: bibliographyListText(in: html))

                // Internal citations, found in the record itself. Under 1.0
                // the Visual-Meta citations carry no URLs, so the route above
                // that turns an origamitext:// address back into a live link
                // never sees one: a citation copied with Copy to Cite, pasted
                // into Author and exported came back as a plain reference.
                // The address is in the BibTeX, so it is read from there.
                let split = internalCitations(in: references)
                references = split.references
                addressByCitationID.merge(split.addressByCitationID) { existing, _ in existing }
                bibtexByAddress.merge(split.bibtexByAddress) { existing, _ in existing }
            }
        }

        var concepts: [LiquidDoc.Concept] = dictionaries(visualMeta?["concepts"]).compactMap { node in
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
        var tables: [LiquidDoc.Table] = dictionaries(tableSource).compactMap { raw in
            guard let identifier = raw["identifier"] as? String, !identifier.isEmpty else { return nil }
            let cellRows = raw["cells"] as? [[[String: Any]]] ?? []
            let cells: [[LiquidDoc.Table.Cell]] = cellRows.map { row in
                row.map { cell in
                    LiquidDoc.Table.Cell(value: cell["value"] as? String ?? "",
                                         formula: cell["formula"] as? String,
                                         columnSpan: (cell["columnSpan"] as? NSNumber)?.intValue)
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
            pattern: "<meta[^>]*property=\"dcterms:conformsTo\"[^>]*>\\s*([^<]+)")
            .map { OrigamiEPUBExporter.namesProfile($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? false
            && !newerProfile
        let readable: [(href: String, xhtml: String)] = spineContentHrefs(in: opf)
            .compactMap { href in
                guard let data = source.entry(joinedPath(opfDirectory, href))
                        ?? source.entry(href) else { return nil }
                return (href, decodedText(data))
            }
        // Chapters the reading styles could not read at all — reported,
        // never dropped silently (the Scrolling page still shows them).
        var unreadable: [String] = []
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
            do {
                return try bodyParagraphs(
                    fromXHTML: xhtml,
                    addressByCitationID: addressByCitationID,
                    resolveImage: resolve,
                    contentDir: documentDir,
                    documentPath: qualifying ? href : "",
                    skippingRecordSections: hasRecords,
                    preferringID: declaresProfile,
                    ordinalOffset: offset,
                    capture: capture)
            } catch {
                if !unreadable.contains(href) { unreadable.append(href) }
                return nil
            }
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
        body = applyingQuoteLinks(dictionaries(visualMeta?["links"]), to: body)
        // A plain book's tables, drawn as grids rather than pipe text —
        // wherever the records did not already describe the table.
        for table in capture.staticTables where !tables.contains(where: { $0.identifier == table.identifier }) {
            tables.append(table)
        }
        concepts = conceptsFollowingGlossaryLinks(
            concepts,
            glossary: readable.flatMap { glossaryEntries(inXHTML: $0.xhtml) },
            uses: capture.glossaryUses)

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
        // Compared lowercased: the address scan lowercases what it finds,
        // and a paper's own UUID keys are upper-case — compared as they
        // stand, every citation key, concept id and the paper's own
        // identifier came back as a "cited document" of its own.
        var ownIDs = Set(references.map(\.id))
            .union(notes.map(\.id))
            .union(body.map(\.id))
            .union(concepts.map(\.id))
        for paragraph in body {
            for match in paragraph.text.matches(of: /\[(?:i?note|cites?):([^\]]+)\]/) {
                ownIDs.insert(String(match.1))
            }
        }
        let record = visualMeta?["document"] as? [String: Any]
        for own in [identifier, record?["identifier"] as? String,
                    record?["work"] as? String, record?["origami-id"] as? String] {
            if let own { ownIDs.insert(own.replacingOccurrences(of: "urn:uuid:", with: "")) }
        }
        let internalIDs = Set(ownIDs.map { $0.lowercased() })
        var links = LiquidDoc.detectedLinks(in: body)
            .filter { !internalIDs.contains($0.to.lowercased()) }
            .map { link -> LiquidDoc.Link in
                guard link.bibtex == nil, let bibtex = bibtexByAddress[link.to] else { return link }
                var enriched = link
                enriched.bibtex = bibtex
                return enriched
            }
        for (address, bibtex) in bibtexByAddress.sorted(by: { $0.key < $1.key })
        where !internalIDs.contains(address.lowercased()) && !links.contains(where: { $0.to == address }) {
            links.append(LiquidDoc.Link(to: address, fragment: nil, rel: "cites", bibtex: bibtex))
        }
        for address in addressByCitationID.values.sorted()
        where bibtexByAddress[address] == nil && !internalIDs.contains(address.lowercased())
            && !links.contains(where: { $0.to == address }) {
            links.append(LiquidDoc.Link(to: address, fragment: nil, rel: "cites", bibtex: nil))
        }

        let document = visualMeta?["document"] as? [String: Any]
        let origamiDoc = origamiJSON?["document"] as? [String: Any]
        // Visual-Meta authors are strings; origami.json authors are {name:} or
        // {family:, given:} objects (academic EPUB format).
        let vmDetails = authorDetails(in: document?["authors"])
        let metaAuthors: [String] = {
            if let vmAuthors = (document?["authors"] as? [String])?
                .map({ $0.trimmingCharacters(in: .whitespaces) })
                .filter({ !$0.isEmpty }), !vmAuthors.isEmpty { return vmAuthors }
            if !vmDetails.names.isEmpty { return vmDetails.names }
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
        // The venue is what the paper states itself part of; a journal
        // stated beside a publication is kept apart as the journal, and
        // one stated alone (older writers) is the venue as well.
        let metaVenue = ["publication", "proceedings", "booktitle", "journal"]
            .compactMap { multilingualText(document?[$0]) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        let metaJournal = multilingualText(document?["journal"])
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : $0 }
        // Academic origami.json embeds venue under a "venue" sub-dict.
        let origamiVenue: String? = {
            guard let venue = origamiDoc?["venue"] as? [String: Any] else { return nil }
            return (venue["journal"] as? String)
                ?? (venue["booktitle"] as? String)
                ?? (venue["publisher"] as? String)
        }()
        let doiFromMeta = (document?["doi"] as? String).flatMap(normalizedDOI)
            ?? (origamiDoc?["doi"] as? String).flatMap(normalizedDOI)

        // Languages and alternate forms (§5.5). Each value stays in its
        // own field in its own script; these only say what it is written
        // in and what else it may be read as.
        var forms: [String: LiquidDoc.LanguageForms] = [:]
        for property in LiquidDoc.multilingualProperties {
            if let found = languageForms(value: document?[property], forms: nil) {
                forms[property] = found
            }
        }
        let language = ((document?["language"] as? String) ?? firstTagText(in: opf, tag: "dc:language"))
            .flatMap(LanguageTag.normalized)
        // A cited work's language and title forms ride on its citation
        // entry; its BibTeX keeps the title in its own script.
        var citationForms: [String: LiquidDoc.LanguageForms] = [:]
        for citation in dictionaries(visualMeta?["citations"]) {
            guard let id = citation["id"] as? String,
                  let found = languageForms(value: nil, forms: citation) else { continue }
            citationForms[id] = found
        }
        if !citationForms.isEmpty {
            references = references.map { reference in
                var enriched = reference
                if enriched.forms == nil { enriched.forms = citationForms[reference.id] }
                return enriched
            }
        }

        return ImportResult(unreadableDocuments: unreadable,
            title: multilingualText(document?["title"]) ?? origamiDoc?["title"] as? String ?? title ?? "Untitled",
            subtitle: multilingualText(document?["subtitle"]).flatMap { $0.isEmpty ? nil : $0 },
            author: metaAuthors.first ?? creator,
            authors: metaAuthors.isEmpty ? creators : metaAuthors,
            publication: metaVenue ?? origamiVenue ?? opfVenue,
            journal: metaJournal,
            affiliations: (document?["affiliations"] as? [String])?
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty } ?? [],
            // Profile 1.0 §5.4 names it acmReference; earlier exports wrote
            // acm-reference.
            acmReference: (document?["acmReference"] as? String
                ?? document?["acm-reference"] as? String)
                .flatMap { $0.isEmpty ? nil : $0 },
            // Both shapes: the name-keyed tables older exports wrote, and
            // the per-author objects Author writes now ({name,
            // affiliation, email, orcid}). A table entry wins a tie.
            authorORCIDs: vmDetails.orcids.merging(
                (document?["author-orcids"] as? [String: String]) ?? [:]) { $1 },
            authorEmails: vmDetails.emails.merging(
                (document?["author-emails"] as? [String: String]) ?? [:]) { $1 },
            authorAffiliations: vmDetails.affiliations.merging(
                (document?["author-affiliations"] as? [String: String]) ?? [:]) { $1 },
            abstract: multilingualText(document?["abstract"])
                .flatMap { $0.isEmpty ? nil : $0 },
            keywords: (document?["keywords"] as? [String])?
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                ?? subjects(in: opf),
            isbn: (document?["isbn"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            ccsConcepts: (document?["ccsConcepts"] as? [String])?
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty } ?? [],
            license: rightsStatement(in: document, opf: opf),
            licenseURI: licenceURI(in: document, opf: opf),
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
            assets: bodyAssets,
            language: language,
            forms: forms,
            authorForms: vmDetails.forms,
            bibliographyConventions: BibTeXConventions(
                record: (visualMeta?["bibliography"] as? [String: Any])?["conventions"]))
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

        // A locked book is said to be locked, before anything is written:
        // unpacked, its pages would read as garbage with no explanation.
        let opfPathEarly = containerRootFile(in: zip) ?? "package.opf"
        let opfEarly = zip.entry(opfPathEarly).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let obfuscated = try obfuscatedFonts(in: zip, opf: opfEarly)

        try? fileManager.removeItem(at: directory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        for name in zip.entryNames {
            guard var data = zip.entry(name) else { continue }
            // An obfuscated font (EPUB 3 §4.4, or Adobe's older scheme)
            // is written back as the font it is.
            if let method = obfuscated[name] {
                data = deobfuscated(data, method: method)
            }
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

    // MARK: Text encoding and entities

    /// A content document's text in the encoding it declares: a byte-order
    /// mark, else the XML declaration's encoding, else UTF-8. Forcing UTF-8
    /// garbled Latin-1 and UTF-16 chapters.
    static func decodedText(_ data: Data) -> String {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16) ?? String(decoding: data, as: UTF8.self)
        }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(decoding: data.dropFirst(3), as: UTF8.self)
        }
        let head = String(decoding: data.prefix(200), as: UTF8.self)
        if let name = firstCapture(in: head, pattern: "<\\?xml[^>]*encoding=[\"']([^\"']+)"),
           name.lowercased() != "utf-8" {
            let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if cf != kCFStringEncodingInvalidId {
                let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
                if let text = String(data: data, encoding: encoding) { return text }
            }
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// HTML's named entities rewritten as numeric references, which an XML
    /// parser reads without a DTD; a bare `&` becomes `&amp;`.
    static func xmlSafeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        guard let expression = try? NSRegularExpression(pattern: "&([A-Za-z][A-Za-z0-9]*|#[0-9]+|#[xX][0-9A-Fa-f]+)?;?")
        else { return text }
        let ns = text as NSString
        var out = ""
        var last = 0
        for match in expression.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let whole = ns.substring(with: match.range)
            let name = match.range(at: 1).location == NSNotFound ? "" : ns.substring(with: match.range(at: 1))
            let closed = whole.hasSuffix(";")
            if closed, ["amp", "lt", "gt", "quot", "apos"].contains(name) || name.hasPrefix("#") {
                out += whole
            } else if closed, let code = htmlEntities[name] {
                out += "&#\(code);"
            } else {
                // A bare ampersand, or an entity no table knows.
                out += "&amp;" + whole.dropFirst()
            }
            last = match.range.location + match.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    /// HTML's named character entities (HTML 4's set), which an XML parser
    /// without the XHTML DTD refuses — `&nbsp;` stopped whole chapters.
    static let htmlEntities: [String: UInt32] = [
        "AElig": 198, "Aacute": 193, "Acirc": 194, "Agrave": 192, "Alpha": 913, "Aring": 197,
        "Atilde": 195, "Auml": 196, "Beta": 914, "Ccedil": 199, "Chi": 935, "Dagger": 8225,
        "Delta": 916, "ETH": 208, "Eacute": 201, "Ecirc": 202, "Egrave": 200, "Epsilon": 917,
        "Eta": 919, "Euml": 203, "Gamma": 915, "Iacute": 205, "Icirc": 206, "Igrave": 204,
        "Iota": 921, "Iuml": 207, "Kappa": 922, "Lambda": 923, "Mu": 924, "Ntilde": 209,
        "Nu": 925, "OElig": 338, "Oacute": 211, "Ocirc": 212, "Ograve": 210, "Omega": 937,
        "Omicron": 927, "Oslash": 216, "Otilde": 213, "Ouml": 214, "Phi": 934, "Pi": 928,
        "Prime": 8243, "Psi": 936, "Rho": 929, "Scaron": 352, "Sigma": 931, "THORN": 222,
        "Tau": 932, "Theta": 920, "Uacute": 218, "Ucirc": 219, "Ugrave": 217, "Upsilon": 933,
        "Uuml": 220, "Xi": 926, "Yacute": 221, "Yuml": 376, "Zeta": 918, "aacute": 225,
        "acirc": 226, "acute": 180, "aelig": 230, "agrave": 224, "alefsym": 8501, "alpha": 945,
        "and": 8743, "ang": 8736, "aring": 229, "asymp": 8776, "atilde": 227, "auml": 228,
        "bdquo": 8222, "beta": 946, "brvbar": 166, "bull": 8226, "cap": 8745, "ccedil": 231,
        "cedil": 184, "cent": 162, "chi": 967, "circ": 710, "clubs": 9827, "cong": 8773,
        "copy": 169, "crarr": 8629, "cup": 8746, "curren": 164, "dArr": 8659, "dagger": 8224,
        "darr": 8595, "deg": 176, "delta": 948, "diams": 9830, "divide": 247, "eacute": 233,
        "ecirc": 234, "egrave": 232, "empty": 8709, "emsp": 8195, "ensp": 8194, "epsilon": 949,
        "equiv": 8801, "eta": 951, "eth": 240, "euml": 235, "euro": 8364, "exist": 8707,
        "fnof": 402, "forall": 8704, "frac12": 189, "frac14": 188, "frac34": 190, "frasl": 8260,
        "gamma": 947, "ge": 8805, "hArr": 8660, "harr": 8596, "hearts": 9829, "hellip": 8230,
        "iacute": 237, "icirc": 238, "iexcl": 161, "igrave": 236, "image": 8465, "infin": 8734,
        "int": 8747, "iota": 953, "iquest": 191, "isin": 8712, "iuml": 239, "kappa": 954,
        "lArr": 8656, "lambda": 955, "lang": 9001, "laquo": 171, "larr": 8592, "lceil": 8968,
        "ldquo": 8220, "le": 8804, "lfloor": 8970, "lowast": 8727, "loz": 9674, "lrm": 8206,
        "lsaquo": 8249, "lsquo": 8216, "macr": 175, "mdash": 8212, "micro": 181, "middot": 183,
        "minus": 8722, "mu": 956, "nabla": 8711, "nbsp": 160, "ndash": 8211, "ne": 8800,
        "ni": 8715, "not": 172, "notin": 8713, "nsub": 8836, "ntilde": 241, "nu": 957,
        "oacute": 243, "ocirc": 244, "oelig": 339, "ograve": 242, "oline": 8254, "omega": 969,
        "omicron": 959, "oplus": 8853, "or": 8744, "ordf": 170, "ordm": 186, "oslash": 248,
        "otilde": 245, "otimes": 8855, "ouml": 246, "para": 182, "part": 8706, "permil": 8240,
        "perp": 8869, "phi": 966, "pi": 960, "piv": 982, "plusmn": 177, "pound": 163,
        "prime": 8242, "prod": 8719, "prop": 8733, "psi": 968, "rArr": 8658, "radic": 8730,
        "rang": 9002, "raquo": 187, "rarr": 8594, "rceil": 8969, "rdquo": 8221, "real": 8476,
        "reg": 174, "rfloor": 8971, "rho": 961, "rlm": 8207, "rsaquo": 8250, "rsquo": 8217,
        "sbquo": 8218, "scaron": 353, "sdot": 8901, "sect": 167, "shy": 173, "sigma": 963,
        "sigmaf": 962, "sim": 8764, "spades": 9824, "sub": 8834, "sube": 8838, "sum": 8721,
        "sup": 8835, "sup1": 185, "sup2": 178, "sup3": 179, "supe": 8839, "szlig": 223,
        "tau": 964, "there4": 8756, "theta": 952, "thetasym": 977, "thinsp": 8201, "thorn": 254,
        "tilde": 732, "times": 215, "trade": 8482, "uArr": 8657, "uacute": 250, "uarr": 8593,
        "ucirc": 251, "ugrave": 249, "uml": 168, "upsih": 978, "upsilon": 965, "uuml": 252,
        "weierp": 8472, "xi": 958, "yacute": 253, "yen": 165, "yuml": 255, "zeta": 950,
        "zwj": 8205, "zwnj": 8204,
    ]

    // MARK: Font obfuscation and DRM

    enum FontObfuscation { case idpf(key: [UInt8]), adobe(key: [UInt8]) }

    /// The fonts META-INF/encryption.xml says are obfuscated, by their path
    /// in the container, with the key each needs. Throws `.protected` when
    /// the book is locked: an Adobe ADEPT rights file, a Readium LCP
    /// licence, Apple FairPlay, or any resource encrypted by something
    /// other than the two font-obfuscation algorithms.
    static func obfuscatedFonts(in zip: ZipReader, opf: String) throws -> [String: FontObfuscation] {
        if zip.entry("META-INF/license.lcpl") != nil { throw OrigamiEPUBImportError.protected("Readium LCP") }
        if zip.entry("META-INF/sinf.xml") != nil { throw OrigamiEPUBImportError.protected("Apple FairPlay") }
        if zip.entry("META-INF/rights.xml") != nil { throw OrigamiEPUBImportError.protected("Adobe DRM") }
        guard let encryption = zip.entry("META-INF/encryption.xml")
            .map({ String(decoding: $0, as: UTF8.self) }) else { return [:] }

        let identifier = uniqueIdentifier(in: opf)
        var fonts: [String: FontObfuscation] = [:]
        for block in captures(in: encryption, pattern: "(?s)<(?:enc:)?EncryptedData\\b.*?</(?:enc:)?EncryptedData>") {
            guard let algorithm = firstCapture(in: block, pattern: "EncryptionMethod[^>]*Algorithm=[\"']([^\"']+)"),
                  let uri = firstCapture(in: block, pattern: "CipherReference[^>]*URI=[\"']([^\"']+)")
            else { continue }
            let path = xmlUnescaped(uri).removingPercentEncoding ?? xmlUnescaped(uri)
            switch algorithm {
            case "http://www.idpf.org/2008/embedding":
                // SHA-1 of the unique identifier, whitespace removed.
                let cleaned = identifier.filter { !" \t\r\n".contains($0) }
                fonts[path] = .idpf(key: Array(Insecure.SHA1.hash(data: Data(cleaned.utf8))))
            case "http://ns.adobe.com/pdf/enc#RC":
                // The 16 bytes of the book's UUID.
                let hex = (identifier.lowercased().hasPrefix("urn:uuid:") ? identifier
                           : uuidIdentifier(in: opf) ?? identifier)
                    .lowercased().replacingOccurrences(of: "urn:uuid:", with: "")
                    .filter(\.isHexDigit)
                var key: [UInt8] = []
                var index = hex.startIndex
                while index < hex.endIndex, let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) {
                    if let byte = UInt8(hex[index..<next], radix: 16) { key.append(byte) }
                    index = next
                }
                if key.count == 16 { fonts[path] = .adobe(key: key) }
            default:
                throw OrigamiEPUBImportError.protected("encrypted content")
            }
        }
        return fonts
    }

    /// The first 1040 (IDPF) or 1024 (Adobe) bytes, XORed with the key.
    static func deobfuscated(_ data: Data, method: FontObfuscation) -> Data {
        var bytes = [UInt8](data)
        let (key, length): ([UInt8], Int) = switch method {
        case .idpf(let key): (key, 1040)
        case .adobe(let key): (key, 1024)
        }
        guard !key.isEmpty else { return data }
        for i in 0..<min(length, bytes.count) { bytes[i] ^= key[i % key.count] }
        return Data(bytes)
    }

    /// The package's unique identifier: the dc:identifier the package
    /// element's unique-identifier attribute names.
    static func uniqueIdentifier(in opf: String) -> String {
        if let id = firstCapture(in: opf, pattern: "<package[^>]*unique-identifier=[\"']([^\"']+)"),
           let value = firstCapture(
            in: opf,
            pattern: "<dc:identifier[^>]*id=[\"']\(NSRegularExpression.escapedPattern(for: id))[\"'][^>]*>([^<]+)<") {
            return xmlUnescaped(value).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return firstTagText(in: opf, tag: "dc:identifier")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Any urn:uuid identifier — Adobe's key when the unique one is not.
    private static func uuidIdentifier(in opf: String) -> String? {
        firstCapture(in: opf, pattern: "<dc:identifier[^>]*>\\s*(urn:uuid:[0-9A-Fa-f-]+)")
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
        /// The work this edition belongs to (`dcterms:isVersionOf`, §4.3).
        var work: String? = nil
    }

    /// Where a publication stands among the editions of its work (§4.3):
    /// the work it is a version of, its own edition identifier, this
    /// release's date and label, and the editions it names as replaced
    /// or replacing it.
    struct EditionInfo: Sendable, Hashable {
        var work: String?
        var identifier: String?
        var modified: String?
        var versionLabel: String?
        var replaces: [String] = []
        var isReplacedBy: [String] = []
    }

    static func editionInfo(inOPF opf: String) -> EditionInfo {
        func meta(_ property: String) -> String? {
            firstCapture(in: opf, pattern: "<meta[^>]*property=\"\(property)\"[^>]*>([^<]*)</meta>")
                .map(xmlUnescaped)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { $0.isEmpty ? nil : $0 }
        }
        // A relation may be a <link rel href> (the profile's form) or a
        // <meta property> (EPUB 2 habits); both are read.
        func relation(_ name: String) -> [String] {
            let links = captures(in: opf, pattern: "<link\\s[^>]*>").compactMap { link -> String? in
                guard let rel = firstCapture(in: link, pattern: "\\srel=\"([^\"]+)\""),
                      rel.split(separator: " ").contains(Substring(name)) else { return nil }
                return firstCapture(in: link, pattern: "\\shref=\"([^\"]+)\"").map(xmlUnescaped)
            }
            return links + (meta(name).map { [$0] } ?? [])
        }
        return EditionInfo(work: meta("dcterms:isVersionOf"),
                           identifier: firstTagText(in: opf, tag: "dc:identifier"),
                           modified: meta("dcterms:modified"),
                           versionLabel: meta("schema:version"),
                           replaces: relation("dcterms:replaces"),
                           isReplacedBy: relation("dcterms:isReplacedBy"))
    }

    static func editionInfo(inUnpackedFolder folder: URL) -> EditionInfo? {
        let opfSubpath = (try? String(
            contentsOf: folder.appendingPathComponent("META-INF/container.xml"),
            encoding: .utf8))
            .flatMap { firstCapture(in: $0, pattern: "full-path=\"([^\"]+)\"") }
            ?? "package.opf"
        guard let opf = try? String(contentsOf: folder.appendingPathComponent(opfSubpath),
                                    encoding: .utf8) else { return nil }
        return editionInfo(inOPF: opf)
    }

    /// The per-author objects a Visual-Meta `document.authors` may hold
    /// — `{name, affiliation, email, orcid}`, as Author writes them —
    /// unpacked into the name-keyed tables the document model keeps. A
    /// plain list of names yields names alone. ORCIDs are kept bare (the
    /// 16-digit id), whether written bare or as an orcid.org URL.
    nonisolated struct AuthorDetails: Sendable {
        var names: [String] = []
        var orcids: [String: String] = [:]
        var emails: [String: String] = [:]
        var affiliations: [String: String] = [:]
        /// Each name's language and other forms (§5.5), keyed by name.
        var forms: [String: LiquidDoc.LanguageForms] = [:]
    }

    /// A human-language value as a string (§5.5): the structured
    /// `{ "value": …, "lang": … }` the profile writes — also nested as
    /// `{ "original": {…} }` — or the plain string earlier exports wrote.
    nonisolated static func multilingualText(_ raw: Any?) -> String? {
        if let text = raw as? String { return text }
        guard let object = raw as? [String: Any] else { return nil }
        if let value = object["value"] as? String { return value }
        return multilingualText(object["original"])
    }

    /// A value's language and alternates (§5.5), from the structured value
    /// itself — and, for an author or a citation entry, from the entry
    /// (`forms`) where earlier drafts put them. Nil when neither says
    /// anything.
    nonisolated static func languageForms(value raw: Any?, forms entry: Any?) -> LiquidDoc.LanguageForms? {
        var out = LiquidDoc.LanguageForms()
        func absorb(_ object: [String: Any]?) {
            guard let object else { return }
            if (out.lang ?? "").isEmpty, let lang = object["lang"] as? String, !lang.isEmpty {
                out.lang = lang
            }
            for alternate in dictionaries(object["alternate"]) {
                guard let value = (alternate["value"] as? String)?
                          .trimmingCharacters(in: .whitespacesAndNewlines),
                      !value.isEmpty else { continue }
                let form = LiquidDoc.LanguageForms.Alternate(
                    value: value,
                    lang: (alternate["lang"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                    relation: (alternate["relation"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                        ?? "alternate")
                if !out.alternate.contains(form) { out.alternate.append(form) }
            }
        }
        absorb(entry as? [String: Any])
        if let object = raw as? [String: Any] {
            absorb(object["original"] as? [String: Any])
            absorb(object)
        }
        return out.isEmpty ? nil : out
    }

    nonisolated static func authorDetails(in raw: Any?) -> AuthorDetails {
        var out = AuthorDetails()
        guard let entries = raw as? [[String: Any]] else { return out }
        func text(_ value: Any?) -> String? {
            let trimmed = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed?.isEmpty ?? true) ? nil : trimmed
        }
        for entry in entries {
            let name: String? = text(multilingualText(entry["name"])) ?? {
                guard let family = text(entry["family"]) else { return nil }
                return text(entry["given"]).map { "\($0) \(family)" } ?? family
            }()
            guard let name else { continue }
            out.names.append(name)
            // The name's forms: on the author entry itself (§5.5), or on
            // a structured name.
            if let forms = languageForms(value: entry["name"], forms: entry) {
                out.forms[name] = forms
            }
            if let orcid = text(entry["orcid"]) {
                out.orcids[name] = orcid
                    .replacingOccurrences(of: "https://orcid.org/", with: "")
                    .replacingOccurrences(of: "http://orcid.org/", with: "")
            }
            if let email = text(entry["email"]) {
                out.emails[name] = email.replacingOccurrences(of: "mailto:", with: "")
            }
            if let affiliation = text(entry["affiliation"]) {
                out.affiliations[name] = affiliation
            } else if let list = entry["affiliations"] as? [String],
                      let first = list.first(where: { !$0.isEmpty }) {
                out.affiliations[name] = first
            }
        }
        return out
    }

    /// An unpacked book's defined terms, by lowercased name, from either
    /// carrier: the Visual-Meta `concepts` (this app's exports — the
    /// package's `visual-meta.json`, else the copy embedded in the content
    /// document) and Author's `origami.json` `glossary` (phrase/entry
    /// pairs). Shared by the Mac's Show Definition and Vision Pro's
    /// context panel.
    static func glossary(content: URL, base: URL) -> [String: (name: String, description: String)] {
        var byName: [String: (name: String, description: String)] = [:]
        func add(_ name: String?, _ description: String?) {
            guard let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
                  let description = description?
                      .trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty
            else { return }
            byName[name.lowercased()] = (name, description)
        }
        let visualMeta = recordData(inUnpackedFolder: base, properties: "origami:visual-meta",
                                    fileName: "visual-meta.json")
            ?? (try? String(contentsOf: content, encoding: .utf8)).flatMap(embeddedVisualMeta(in:))
        if let visualMeta,
           let object = (try? JSONSerialization.jsonObject(with: visualMeta)) as? [String: Any],
           let concepts = object["concepts"] as? [[String: Any]] {
            for concept in concepts where (concept["tag"] as? String) != "heading" {
                add(concept["name"] as? String, concept["description"] as? String)
            }
        }
        let origamiURL = content.deletingLastPathComponent().appendingPathComponent("origami.json")
        if let data = recordData(inUnpackedFolder: base, properties: "origami:interaction",
                                 fileName: "origami.json")
            ?? (try? Data(contentsOf: origamiURL)),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let glossary = object["glossary"] as? [String: [String: Any]] {
            for node in glossary.values {
                add(node["phrase"] as? String, node["entry"] as? String)
            }
        }
        return byName
    }

    /// A metadata record in an unpacked book, found the way `import` finds
    /// it: the package's `<link rel="record">` declaration first, then the
    /// pre-1.0 well-known name at the root or beside the package document.
    /// A 1.0 book keeps its records beside the package (§4.8), so looking
    /// only at the root missed them.
    static func recordData(inUnpackedFolder folder: URL, properties: String,
                           fileName: String) -> Data? {
        let opfSubpath = (try? String(
            contentsOf: folder.appendingPathComponent("META-INF/container.xml"),
            encoding: .utf8))
            .flatMap { firstCapture(in: $0, pattern: "full-path=\"([^\"]+)\"") }
            ?? "package.opf"
        let opfDirectory = (opfSubpath as NSString).deletingLastPathComponent
        var candidates: [String] = []
        if let opf = try? String(contentsOf: folder.appendingPathComponent(opfSubpath),
                                 encoding: .utf8),
           let href = recordHref(in: opf, properties: properties) {
            candidates.append(joinedPath(opfDirectory, href.removingPercentEncoding ?? href))
        }
        candidates += [fileName, joinedPath(opfDirectory, fileName)]
        for path in candidates {
            if let data = try? Data(contentsOf: folder.appendingPathComponent(path)) {
                return data
            }
        }
        return nil
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
        var visualMetaData = recordData(inUnpackedFolder: folder,
                                        properties: "origami:visual-meta",
                                        fileName: "visual-meta.json")
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
            if let data = recordData(inUnpackedFolder: folder,
                                     properties: "origami:interaction",
                                     fileName: "origami.json"),
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
                    identifier: packageID,
                    work: editionInfo(inOPF: opf).work)
            }
        }

        let document = visualMeta?["document"] as? [String: Any]
        let stringAuthors = (document?["authors"] as? [String])?
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty } ?? []
        let metaAuthors = stringAuthors.isEmpty
            ? authorDetails(in: document?["authors"]).names : stringAuthors
        let metaVenue = ["journal", "proceedings", "publication", "booktitle"]
            .compactMap { multilingualText(document?[$0]) }
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
            identifier: packageID,
            work: editionInfo(inOPF: opf).work)
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
        // linear="no" items (a pop-up answer page, a notes file) stand
        // after the reading order — still reachable by links — so the
        // book reads through without them (EPUB 3.3 §3.4.8).
        var linear: [String] = [], auxiliary: [String] = []
        for itemref in captures(in: opf, pattern: "<itemref\\b[^>]*>") {
            guard let idref = firstCapture(in: itemref, pattern: "idref=[\"']([^\"']+)"),
                  let href = hrefByID[idref] else { continue }
            if firstCapture(in: itemref, pattern: "linear=[\"']([^\"']+)") == "no" {
                auxiliary.append(href)
            } else {
                linear.append(href)
            }
        }
        return linear + auxiliary
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

    /// The publication's rights as a person reads them (profile §4.8).
    ///
    /// `document.rights` is the profile's home for the prose. Pre-1.0
    /// files put the whole block in `document.license` instead, so a
    /// `license` value that is not a URI is read here rather than being
    /// presented as a licence identifier. The package's `dc:rights` is
    /// authoritative and answers first (§11.4).
    private static func rightsStatement(in document: [String: Any]?,
                                        opf: String) -> String? {
        let candidates = [
            firstTagText(in: opf, tag: "dc:rights"),
            document?["rights"] as? String,
            (document?["license"] as? String).flatMap { isLicenceURI($0) ? nil : $0 }
        ]
        return candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    /// The licence as a URI — the form that can be compared and resolved
    /// rather than merely pattern-matched (profile §4.8). A licence
    /// *name* is never returned here: a reader must not infer a licence
    /// from prose, so prose stays prose.
    private static func licenceURI(in document: [String: Any]?,
                                   opf: String) -> String? {
        let candidates = [
            firstCapture(in: opf,
                         pattern: "<meta[^>]*property=\"dcterms:license\"[^>]*>\\s*([^<]+)"),
            document?["license"] as? String
        ]
        return candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { isLicenceURI($0) }
            .map(xmlUnescaped)
    }

    private static func isLicenceURI(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isNewline),
              !trimmed.contains(" ") else { return false }
        return trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")
            || trimmed.hasPrefix("urn:")
    }

    /// Keywords from the package's `dc:subject` elements, which is where
    /// EPUB puts them — the fallback when the record names none.
    private static func subjects(in opf: String) -> [String] {
        captures(in: opf, pattern: "<dc:subject[^>]*>([^<]+)</dc:subject>")
            .map { xmlUnescaped($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
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
        /// Nesting depth in the book's own contents: 0 for a top entry.
        var level: Int = 0
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
            // Walked in document order, so each entry knows how many lists
            // it stands inside — the contents keep their nesting.
            var depth = 0
            for token in captures(in: scope, pattern: "(?s)(<ol\\b[^>]*>|</ol>|<a\\s[^>]*href=\"[^\"]+\"[^>]*>.*?</a>)") {
                if token.hasPrefix("</ol") { depth = max(0, depth - 1); continue }
                if token.hasPrefix("<ol") { depth += 1; continue }
                let anchor = token
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
                entries.append(TOCEntry(label: label, subpath: subpath, fragment: fragment,
                                        level: max(0, depth - 1)))
            }
            if !entries.isEmpty { return entries }
        }
        // An EPUB 2 book (or one whose nav is missing): its NCX.
        let fromNCX = ncxEntries(inUnpackedFolder: folder, spine: spine)
        if !fromNCX.isEmpty { return fromNCX }
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

    /// How a book asks to be laid out (EPUB 3.3 §4.2): fixed-layout pages
    /// (`rendition:layout` pre-paginated, for the whole book or any spine
    /// item) and right-to-left page progression.
    struct Rendition: Sendable, Hashable {
        var fixedLayout = false
        var rightToLeft = false
        /// Content documents the package marks `properties="scripted"`,
        /// folder-relative — the only pages whose own JavaScript runs.
        var scriptedDocuments: Set<String> = []
    }

    static func rendition(inUnpackedFolder folder: URL) -> Rendition {
        let opfSubpath = (try? String(
            contentsOf: folder.appendingPathComponent("META-INF/container.xml"), encoding: .utf8))
            .flatMap { firstCapture(in: $0, pattern: "full-path=\"([^\"]+)\"") } ?? "package.opf"
        guard let opf = try? String(contentsOf: folder.appendingPathComponent(opfSubpath),
                                    encoding: .utf8) else { return Rendition() }
        let global = firstCapture(in: opf, pattern: "<meta[^>]*property=[\"']rendition:layout[\"'][^>]*>\\s*([^<]+)")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let anyItem = opf.contains("rendition:layout-pre-paginated")
        // Apple's older display-options file said the same for iBooks.
        let apple = (try? String(contentsOf: folder.appendingPathComponent(
            "META-INF/com.apple.ibooks.display-options.xml"), encoding: .utf8))?
            .contains("fixed-layout\">true") ?? false
        let direction = firstCapture(in: opf, pattern: "<spine[^>]*page-progression-direction=[\"']([^\"']+)")
        let opfDirectory = (opfSubpath as NSString).deletingLastPathComponent
        let scripted = Set(captures(in: opf, pattern: "<item\\s[^>]*>").compactMap { tag -> String? in
            guard let properties = firstCapture(in: tag, pattern: "properties=[\"']([^\"']+)"),
                  properties.split(separator: " ").contains("scripted"),
                  let href = firstCapture(in: tag, pattern: "href=[\"']([^\"']+)") else { return nil }
            let decoded = xmlUnescaped(href)
            return joinedPath(opfDirectory, decoded.removingPercentEncoding ?? decoded)
        })
        return Rendition(fixedLayout: global == "pre-paginated" || anyItem || apple,
                         rightToLeft: direction == "rtl", scriptedDocuments: scripted)
    }

    /// The cover image the package declares, folder-relative: EPUB 3's
    /// `properties="cover-image"`, else EPUB 2's `<meta name="cover">`,
    /// else an image item named for a cover.
    static func coverImagePath(inUnpackedFolder folder: URL) -> String? {
        let opfSubpath = (try? String(
            contentsOf: folder.appendingPathComponent("META-INF/container.xml"), encoding: .utf8))
            .flatMap { firstCapture(in: $0, pattern: "full-path=\"([^\"]+)\"") } ?? "package.opf"
        guard let opf = try? String(contentsOf: folder.appendingPathComponent(opfSubpath),
                                    encoding: .utf8) else { return nil }
        let opfDirectory = (opfSubpath as NSString).deletingLastPathComponent
        struct Item { let id: String; let href: String; let type: String; let properties: String }
        let items: [Item] = captures(in: opf, pattern: "<item\\s[^>]*>").compactMap { tag in
            guard let href = firstCapture(in: tag, pattern: "href=[\"']([^\"']+)") else { return nil }
            return Item(id: firstCapture(in: tag, pattern: "\\sid=[\"']([^\"']+)") ?? "",
                        href: xmlUnescaped(href),
                        type: firstCapture(in: tag, pattern: "media-type=[\"']([^\"']+)") ?? "",
                        properties: firstCapture(in: tag, pattern: "properties=[\"']([^\"']+)") ?? "")
        }
        let images = items.filter { $0.type.hasPrefix("image/") }
        let metaID = firstCapture(in: opf, pattern: "<meta[^>]*name=[\"']cover[\"'][^>]*content=[\"']([^\"']+)")
            ?? firstCapture(in: opf, pattern: "<meta[^>]*content=[\"']([^\"']+)[\"'][^>]*name=[\"']cover[\"']")
        let chosen = images.first { $0.properties.split(separator: " ").contains("cover-image") }
            ?? metaID.flatMap { id in images.first { $0.id == id } }
            ?? images.first { $0.id.localizedCaseInsensitiveContains("cover")
                || $0.href.localizedCaseInsensitiveContains("cover") }
        guard let chosen else { return nil }
        return joinedPath(opfDirectory, chosen.href.removingPercentEncoding ?? chosen.href)
    }

    /// A print page the book records: its label (as printed — "12",
    /// "xiv") and where it begins.
    struct PageTarget: Hashable, Sendable {
        let label: String
        let subpath: String
        let fragment: String?
    }

    /// The book's print pages (EPUB 3.3 page-list): the navigation
    /// document's `page-list`, else the NCX `pageList`, else the page-break
    /// markers in the text itself.
    static func pageList(inUnpackedFolder folder: URL, spine: BookSpine) -> [PageTarget] {
        func target(_ href: String, relativeTo directory: String, label: String) -> PageTarget {
            let parts = href.split(separator: "#", maxSplits: 1)
            let file = parts.first.map(String.init) ?? ""
            return PageTarget(label: label,
                              subpath: file.isEmpty ? (spine.chapters.first ?? "")
                                  : joinedPath(directory, file.removingPercentEncoding ?? file),
                              fragment: parts.count > 1 ? String(parts[1]) : nil)
        }
        func text(_ markup: String) -> String {
            xmlUnescaped(markup.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let nav = spine.nav,
           let html = try? String(contentsOf: folder.appendingPathComponent(nav), encoding: .utf8),
           let scope = firstCapture(in: html, pattern: "(?s)<nav[^>]*epub:type=[\"'][^\"']*page-list[^\"']*[\"'][^>]*>(.*?)</nav>") {
            let directory = (nav as NSString).deletingLastPathComponent
            let pages = captures(in: scope, pattern: "(?s)<a\\s[^>]*href=[\"'][^\"']+[\"'][^>]*>.*?</a>").compactMap { anchor -> PageTarget? in
                guard let href = firstCapture(in: anchor, pattern: "href=[\"']([^\"']+)"),
                      let inner = firstCapture(in: anchor, pattern: "(?s)<a[^>]*>(.*?)</a>") else { return nil }
                let label = text(inner)
                return label.isEmpty ? nil : target(href, relativeTo: directory, label: label)
            }
            if !pages.isEmpty { return pages }
        }
        // The NCX pageList.
        let opfSubpath = (try? String(
            contentsOf: folder.appendingPathComponent("META-INF/container.xml"), encoding: .utf8))
            .flatMap { firstCapture(in: $0, pattern: "full-path=\"([^\"]+)\"") } ?? "package.opf"
        if let opf = try? String(contentsOf: folder.appendingPathComponent(opfSubpath), encoding: .utf8),
           let ncxHref = captures(in: opf, pattern: "<item\\s[^>]*>")
            .first(where: { $0.contains("application/x-dtbncx+xml") })
            .flatMap({ firstCapture(in: $0, pattern: "href=[\"']([^\"']+)") }) {
            let ncxPath = joinedPath((opfSubpath as NSString).deletingLastPathComponent, ncxHref)
            if let data = try? Data(contentsOf: folder.appendingPathComponent(ncxPath)),
               let list = firstCapture(in: decodedText(data), pattern: "(?s)<pageList\\b.*?</pageList>") {
                let directory = (ncxPath as NSString).deletingLastPathComponent
                let pages = captures(in: list, pattern: "(?s)<pageTarget\\b.*?</pageTarget>").compactMap { entry -> PageTarget? in
                    guard let label = firstCapture(in: entry, pattern: "(?s)<text>(.*?)</text>").map(text),
                          !label.isEmpty,
                          let src = firstCapture(in: entry, pattern: "src=[\"']([^\"']+)") else { return nil }
                    return target(src, relativeTo: directory, label: label)
                }
                if !pages.isEmpty { return pages }
            }
        }
        // The page breaks marked in the text.
        var pages: [PageTarget] = []
        for chapter in spine.chapters {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(chapter)) else { continue }
            let html = decodedText(data)
            for tag in captures(in: html, pattern: "<[a-zA-Z]+\\b[^>]*(?:epub:type=[\"'][^\"']*pagebreak|role=[\"']doc-pagebreak)[^>]*>") {
                guard let id = firstCapture(in: tag, pattern: "\\sid=[\"']([^\"']+)") else { continue }
                let label = firstCapture(in: tag, pattern: "(?:title|aria-label)=[\"']([^\"']+)").map(xmlUnescaped) ?? id
                pages.append(PageTarget(label: label, subpath: chapter, fragment: id))
            }
        }
        return pages
    }

    /// Finds the print page each paragraph stands on: the last page-break
    /// marker before it in its chapter, else the last page an earlier
    /// chapter began. Built once per export.
    final class PrintPageLocator {
        private let chapters: [(path: String, html: String)]
        private let hasPages: Bool

        init(folder: URL) {
            let spine = OrigamiEPUBImporter.spine(inUnpackedFolder: folder)
            chapters = (spine?.chapters ?? []).compactMap { path in
                (try? Data(contentsOf: folder.appendingPathComponent(path)))
                    .map { (path, OrigamiEPUBImporter.decodedText($0)) }
            }
            hasPages = chapters.contains { $0.html.contains("pagebreak") }
        }

        private static let marker = try? NSRegularExpression(
            pattern: "<[a-zA-Z]+\\b[^>]*(?:epub:type=[\"'][^\"']*pagebreak|role=[\"']doc-pagebreak)[^>]*>")

        private static func label(of tag: String) -> String? {
            for attribute in ["title", "aria-label"] {
                if let range = tag.range(of: attribute + "=[\"']([^\"']+)", options: .regularExpression) {
                    return String(tag[range].dropFirst(attribute.count + 2))
                }
            }
            if let range = tag.range(of: "\\sid=[\"']([^\"']+)", options: .regularExpression) {
                return String(tag[range]).components(separatedBy: CharacterSet(charactersIn: "\"'")).dropFirst().first
            }
            return nil
        }

        /// The print page of an element address (`path#id` or a bare id).
        func page(for address: String) -> String? {
            guard hasPages, let marker = Self.marker else { return nil }
            let id = address.split(separator: "#").last.map(String.init) ?? address
            // A path#id address looks only in its own chapter.
            let path = address.contains("#") ? String(address[..<address.lastIndex(of: "#")!]) : nil
            var lastBefore: String?
            for chapter in chapters {
                let html = chapter.html
                if let path, !chapter.path.hasSuffix(path) {
                    let range = NSRange(html.startIndex..., in: html)
                    if let last = marker.matches(in: html, range: range).last,
                       let r = Range(last.range, in: html), let label = Self.label(of: String(html[r])) {
                        lastBefore = label
                    }
                    continue
                }
                let range = NSRange(html.startIndex..., in: html)
                let markers = marker.matches(in: html, range: range).compactMap { match -> (Int, String)? in
                    guard let r = Range(match.range, in: html), let label = Self.label(of: String(html[r])) else { return nil }
                    return (match.range.location, label)
                }
                if let target = html.range(of: "id=\"\(id)\"") ?? html.range(of: "id='\(id)'") {
                    let offset = NSRange(target, in: html).location
                    return markers.last(where: { $0.0 < offset })?.1 ?? lastBefore
                }
                if let last = markers.last?.1 { lastBefore = last }
            }
            return nil
        }
    }

    /// The EPUB 2 contents, from toc.ncx: each navPoint's label and
    /// target, nested as the NCX nests them.
    static func ncxEntries(inUnpackedFolder folder: URL, spine: BookSpine) -> [TOCEntry] {
        let opfSubpath = (try? String(
            contentsOf: folder.appendingPathComponent("META-INF/container.xml"), encoding: .utf8))
            .flatMap { firstCapture(in: $0, pattern: "full-path=\"([^\"]+)\"") } ?? "package.opf"
        guard let opf = try? String(contentsOf: folder.appendingPathComponent(opfSubpath),
                                    encoding: .utf8) else { return [] }
        let opfDirectory = (opfSubpath as NSString).deletingLastPathComponent
        // The spine's toc attribute names it; else any NCX in the manifest.
        let tocID = firstCapture(in: opf, pattern: "<spine[^>]*\\btoc=[\"']([^\"']+)")
        var ncxHref: String?
        for item in captures(in: opf, pattern: "<item\\s[^>]*>") {
            let id = firstCapture(in: item, pattern: "\\sid=[\"']([^\"']+)")
            let type = firstCapture(in: item, pattern: "media-type=[\"']([^\"']+)")
            if id == tocID || type == "application/x-dtbncx+xml" {
                ncxHref = firstCapture(in: item, pattern: "href=[\"']([^\"']+)")
                if id == tocID { break }
            }
        }
        guard let ncxHref else { return [] }
        let ncxPath = joinedPath(opfDirectory, ncxHref.removingPercentEncoding ?? ncxHref)
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(ncxPath)) else { return [] }
        let ncx = decodedText(data)
        let ncxDirectory = (ncxPath as NSString).deletingLastPathComponent
        var entries: [TOCEntry] = []
        var depth = 0
        var label: String?
        for token in captures(in: ncx, pattern: "(?s)(<navPoint\\b[^>]*>|</navPoint>|<text>.*?</text>|<content\\s[^>]*>)") {
            if token.hasPrefix("<navPoint") { depth += 1; label = nil; continue }
            if token.hasPrefix("</navPoint") { depth = max(0, depth - 1); continue }
            if token.hasPrefix("<text") {
                if label == nil, let inner = firstCapture(in: token, pattern: "(?s)<text>(.*?)</text>") {
                    label = xmlUnescaped(inner).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                continue
            }
            guard let src = firstCapture(in: token, pattern: "src=[\"']([^\"']+)"),
                  let name = label, !name.isEmpty else { continue }
            let parts = src.split(separator: "#", maxSplits: 1)
            let file = parts.first.map(String.init) ?? ""
            entries.append(TOCEntry(
                label: name,
                subpath: file.isEmpty ? (spine.chapters.first ?? "")
                    : joinedPath(ncxDirectory, file.removingPercentEncoding ?? file),
                fragment: parts.count > 1 ? String(parts[1]) : nil,
                level: max(0, depth - 1)))
            label = nil
        }
        return entries
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

    /// The publication's equations, for citing and copying (§7.7.1): the
    /// semantic record's `equations[]` first; for a book that does not
    /// declare the profile, the older delimited block in its content
    /// document; failing both, a scan of every content document's
    /// `math[id]`. Where an entry's TeX fails its checksum, the MathML in
    /// the body governs (§12.4) and the TeX comes from the body instead.
    static func equationIndex(inUnpackedFolder folder: URL) -> [EquationEntry] {
        let opfSubpath = (try? String(
            contentsOf: folder.appendingPathComponent("META-INF/container.xml"),
            encoding: .utf8))
            .flatMap { firstCapture(in: $0, pattern: "full-path=\"([^\"]+)\"") }
            ?? "package.opf"
        guard let opf = try? String(contentsOf: folder.appendingPathComponent(opfSubpath),
                                    encoding: .utf8) else { return [] }
        let opfDirectory = (opfSubpath as NSString).deletingLastPathComponent
        let declaresProfile = firstCapture(
            in: opf, pattern: "<meta[^>]*property=\"dcterms:conformsTo\"[^>]*>([^<]*)</meta>")
            .map { OrigamiEPUBExporter.namesProfile($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? false
        let documents: [(href: String, xhtml: String)] = spineContentHrefs(in: opf).compactMap { href in
            let path = joinedPath(opfDirectory, href.removingPercentEncoding ?? href)
            guard let xhtml = try? String(contentsOf: folder.appendingPathComponent(path),
                                          encoding: .utf8) else { return nil }
            return (path, xhtml)
        }
        let scanned = documents.flatMap { document in
            MathMLBodyScanner.equations(inXHTML: document.xhtml, contentHref: document.href)
        }
        let record = recordData(inUnpackedFolder: folder, properties: "origami:visual-meta",
                                fileName: "visual-meta.json")
            .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        let fromRecord: [EquationEntry] = dictionaries(record?["equations"]).compactMap { node in
            guard let id = node["id"] as? String, !id.isEmpty else { return nil }
            let body = scanned.first { $0.id == id }
            var entry = EquationEntry(
                id: id,
                display: (node["display"] as? String).flatMap(EquationDisplay.init) ?? .block,
                format: (node["format"] as? String).flatMap(EquationSourceFormat.init) ?? .mathml,
                label: node["label"] as? String,
                tex: node["tex"] as? String,
                texSHA256: node["tex-sha256"] as? String,
                mathmlSHA256: node["mathml-sha256"] as? String,
                converter: node["converter"] as? String,
                href: (node["href"] as? String) ?? body?.href,
                section: node["section"] as? String,
                heading: node["heading"] as? String)
            if entry.texChecksumOK == false || entry.tex == nil {
                entry.tex = body?.tex
                entry.texSHA256 = body?.texSHA256
            }
            return entry
        }
        if !fromRecord.isEmpty { return fromRecord }
        if !declaresProfile, let first = documents.first {
            let block = EquationIndex.build(visualMetaText: first.xhtml, contentHTML: first.xhtml,
                                            contentHref: first.href)
            if block.fromVisualMeta { return block.entries }
        }
        return scanned
    }

    /// The `<math>` markup an equation entry points at, read from its
    /// content document.
    static func mathMLSource(for entry: EquationEntry, inUnpackedFolder folder: URL) -> String? {
        let opfSubpath = (try? String(
            contentsOf: folder.appendingPathComponent("META-INF/container.xml"),
            encoding: .utf8))
            .flatMap { firstCapture(in: $0, pattern: "full-path=\"([^\"]+)\"") }
            ?? "package.opf"
        let opfDirectory = (opfSubpath as NSString).deletingLastPathComponent
        let path = entry.href.flatMap { $0.split(separator: "#").first.map(String.init) }
        let candidates = [path, path.map { joinedPath(opfDirectory, $0) }].compactMap { $0 }
        for candidate in candidates {
            if let xhtml = try? String(contentsOf: folder.appendingPathComponent(candidate),
                                       encoding: .utf8),
               let source = MathMLBodyScanner.mathMLSource(id: entry.id, inXHTML: xhtml) {
                return source
            }
        }
        return nil
    }

    /// What the rendered Visual-Meta colophon says of the publication,
    /// set against what its package and records say (§8.4.6): the
    /// colophon is for people and never authoritative, so a
    /// disagreement is reported, not believed.
    struct ColophonCheck: Sendable, Hashable {
        /// The colophon's self-citation, as printed.
        var bibtex: String
        /// What disagrees: "title", "DOI", "year", "authors", "record paths".
        var disagreements: [String]
        var verified: Bool { disagreements.isEmpty }
    }

    /// Nil when the publication has no colophon with a BibTeX block.
    static func colophonCheck(inUnpackedFolder folder: URL) -> ColophonCheck? {
        let opfSubpath = (try? String(
            contentsOf: folder.appendingPathComponent("META-INF/container.xml"),
            encoding: .utf8))
            .flatMap { firstCapture(in: $0, pattern: "full-path=\"([^\"]+)\"") }
            ?? "package.opf"
        guard let opf = try? String(contentsOf: folder.appendingPathComponent(opfSubpath),
                                    encoding: .utf8) else { return nil }
        let opfDirectory = (opfSubpath as NSString).deletingLastPathComponent
        // The colophon section, in whichever content document holds it.
        var colophon: String?
        for href in spineContentHrefs(in: opf) {
            let path = joinedPath(opfDirectory, href.removingPercentEncoding ?? href)
            guard let xhtml = try? String(contentsOf: folder.appendingPathComponent(path),
                                          encoding: .utf8) else { continue }
            if let section = firstCapture(
                in: xhtml,
                pattern: "(?s)<section[^>]*epub:type=\"[^\"]*colophon[^\"]*\"[^>]*>(.*?)</section>") {
                colophon = section
                break
            }
        }
        guard let colophon,
              let pre = firstCapture(in: colophon, pattern: "(?s)<pre[^>]*>(.*?)</pre>")
        else { return nil }
        let bibtex = xmlUnescaped(pre.replacingOccurrences(
            of: "<[^>]+>", with: "", options: .regularExpression))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let entry = BibTeXParser.first(bibtex) else { return nil }

        let document = recordData(inUnpackedFolder: folder, properties: "origami:visual-meta",
                                  fileName: "visual-meta.json")
            .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }?["document"]
            as? [String: Any]
        func squeezed(_ text: String) -> String {
            BibTeXParser.displayText(text).lowercased()
                .filter { $0.isLetter || $0.isNumber }
        }
        var disagreements: [String] = []
        if let title = entry.fields["title"],
           let packageTitle = firstTagText(in: opf, tag: "dc:title").map(xmlUnescaped),
           squeezed(title) != squeezed(packageTitle) {
            disagreements.append("title")
        }
        let packageDOI = (document?["doi"] as? String).flatMap(normalizedDOI) ?? extractDOI(from: opf)
        if let doi = entry.fields["doi"].flatMap(normalizedDOI), let packageDOI,
           doi.lowercased() != packageDOI.lowercased() {
            disagreements.append("DOI")
        }
        let packageYear = ((document?["date"] as? String) ?? firstTagText(in: opf, tag: "dc:date"))
            .map { String($0.prefix(4)) }
        if let year = entry.fields["year"].map(BibTeXParser.displayText), let packageYear,
           year != packageYear {
            disagreements.append("year")
        }
        // Authors by surname: the printed "Last, First and …" against the
        // package's creators, order aside.
        func surname(_ name: String) -> String {
            let name = BibTeXParser.displayText(name).trimmingCharacters(in: .whitespaces)
            let last = name.contains(",")
                ? String(name.split(separator: ",").first ?? "")
                : String(name.split(separator: " ").last ?? "")
            return last.lowercased().filter(\.isLetter)
        }
        let creators = allTagTexts(in: opf, tag: "dc:creator").map(xmlUnescaped)
        if let authors = entry.fields["author"], !creators.isEmpty {
            let printed = Set(authors.components(separatedBy: " and ").map(surname))
            if printed != Set(creators.map(surname)) { disagreements.append("authors") }
        }
        // The access map's paths must be where the records are (§8.4.3).
        let declared = Set(["origami:visual-meta", "origami:interaction", "origami:bibliography"]
            .compactMap { recordHref(in: opf, properties: $0) })
        let stated = captures(in: colophon, pattern: "<code>([^<]+\\.(?:json|bib))</code>")
            .map(xmlUnescaped)
        if !declared.isEmpty, stated.contains(where: { !declared.contains($0) }) {
            disagreements.append("record paths")
        }
        return ColophonCheck(bibtex: bibtex, disagreements: disagreements)
    }

    /// The glossary's entries as the book prints them (§8.1, EPUB 3's
    /// `glossary`): each `<dt id>` term with the `<dd>` after it.
    static func glossaryEntries(inXHTML html: String) -> [(id: String, term: String, definition: String)] {
        guard let expr = try? NSRegularExpression(
            pattern: "<dt\\b[^>]*\\bid=\"([^\"]+)\"[^>]*>(.*?)</dt>\\s*<dd\\b[^>]*>(.*?)</dd>",
            options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return [] }
        func text(_ markup: String) -> String {
            xmlUnescaped(markup.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return expr.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { match in
            guard let id = Range(match.range(at: 1), in: html),
                  let term = Range(match.range(at: 2), in: html),
                  let definition = Range(match.range(at: 3), in: html) else { return nil }
            let entry = (id: String(html[id]), term: text(String(html[term])),
                         definition: text(String(html[definition])))
            return entry.term.isEmpty ? nil : entry
        }
    }

    /// The concepts, with each glossary link followed to the entry it
    /// names (§7.4): the link's words join that concept's marked forms.
    /// A plain EPUB 3 whose records carry no concepts gets its own
    /// printed glossary as its definitions.
    static func conceptsFollowingGlossaryLinks(
        _ concepts: [LiquidDoc.Concept],
        glossary: [(id: String, term: String, definition: String)],
        uses: [(target: String, words: String)]) -> [LiquidDoc.Concept] {
        var concepts = concepts
        if concepts.isEmpty {
            concepts = glossary.filter { !$0.definition.isEmpty }.map {
                LiquidDoc.Concept(id: $0.id, name: $0.term, description: $0.definition, tag: "concept")
            }
        }
        let terms = Dictionary(glossary.map { ($0.id, $0.term) }, uniquingKeysWith: { first, _ in first })
        func same(_ a: String, _ b: String) -> Bool {
            a.compare(b, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        for use in uses {
            let words = collapsedLineBreaks(use.words).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !words.isEmpty else { continue }
            let term = terms[use.target]
            guard let index = concepts.firstIndex(where: { $0.id == use.target })
                    ?? term.flatMap({ term in concepts.firstIndex { same($0.name, term) } })
            else { continue }
            if !same(words, concepts[index].name),
               !concepts[index].markedForms.contains(where: { same($0, words) }) {
                concepts[index].markedForms.append(words)
            }
        }
        return concepts
    }

    /// The profile version a package declares (`dcterms:conformsTo`, whose
    /// last path segment is MAJOR.MINOR — §16.1), as written.
    static func declaredProfileVersion(in opf: String) -> String? {
        guard let value = firstCapture(
            in: opf, pattern: "<meta[^>]*property=\"dcterms:conformsTo\"[^>]*>\\s*([^<]+)")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              OrigamiEPUBExporter.namesProfile(value) else { return nil }
        return value.split(separator: "/").last.map(String.init)
    }

    static func profileMajor(in opf: String) -> Int? {
        declaredProfileVersion(in: opf)?.split(separator: ".").first.flatMap { Int($0) }
    }

    /// What a book's declarations say about how far it can be trusted
    /// (§16.2, §17.1): a profile newer than this reader, and records
    /// whose `describes` names another publication.
    struct ProfileCheck: Sendable, Hashable {
        var declaredVersion: String?
        var newerThanReader: Bool
        /// "semantic record", "interaction record".
        var untrustedRecords: [String]
    }

    static func profileCheck(inUnpackedFolder folder: URL) -> ProfileCheck? {
        let opfSubpath = (try? String(
            contentsOf: folder.appendingPathComponent("META-INF/container.xml"),
            encoding: .utf8))
            .flatMap { firstCapture(in: $0, pattern: "full-path=\"([^\"]+)\"") }
            ?? "package.opf"
        guard let opf = try? String(contentsOf: folder.appendingPathComponent(opfSubpath),
                                    encoding: .utf8) else { return nil }
        let identifier = firstTagText(in: opf, tag: "dc:identifier")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var untrusted: [String] = []
        for (properties, name, key, label) in [
            ("origami:visual-meta", "visual-meta.json", "visual-meta", "semantic record"),
            ("origami:interaction", "origami.json", "origami", "interaction record")] {
            guard let identifier,
                  let object = recordData(inUnpackedFolder: folder, properties: properties,
                                          fileName: name)
                      .flatMap({ (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }),
                  let describes = ((object[key] as? [String: Any])?["describes"] as? String)?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !describes.isEmpty else { continue }
            if describes != identifier { untrusted.append(label) }
        }
        return ProfileCheck(declaredVersion: declaredProfileVersion(in: opf),
                            newerThanReader: (profileMajor(in: opf) ?? 1) > 1,
                            untrustedRecords: untrusted)
    }

    /// A quote link's origamitext:// action, when the anchor carries one.
    private static func quoteLinkAction(of attributes: [String: String]) -> String? {
        [attributes["data-origami-action"], attributes["href"]]
            .compactMap { $0 }
            .first { $0.lowercased().hasPrefix("origamitext://") }
    }

    /// The semantic record's `links` (§9.6), the durable form of a quote
    /// link, made readable: each one's quoted words, where they stand in
    /// the linking paragraph outside any other link, become a link to
    /// `toEdition` at `toAddress`; a link whose words cannot be found
    /// closes its paragraph with an arrow instead. The link opens the
    /// passage when the edition is in the library — the record names it by
    /// identity, never by location.
    static func applyingQuoteLinks(_ links: [[String: Any]],
                                   to body: [LiquidDoc.Paragraph]) -> [LiquidDoc.Paragraph] {
        guard !links.isEmpty else { return body }
        func fragment(_ value: String) -> Substring {
            value.split(separator: "#", omittingEmptySubsequences: false).last ?? Substring(value)
        }
        var body = body
        for link in links {
            guard let from = link["fromAddress"] as? String, !from.isEmpty,
                  let edition = link["toEdition"] as? String,
                  let target = link["toAddress"] as? String,
                  let url = OrigamiCitation.openURL(edition: edition, address: target)
            else { continue }
            // The linking paragraph: its address exactly, else the one
            // paragraph carrying the same id in the other form.
            let index = body.firstIndex { $0.id == from } ?? {
                let matches = body.indices.filter { fragment(body[$0].id) == fragment(from) }
                return matches.count == 1 ? matches[0] : nil
            }()
            guard let index else { continue }
            let text = body[index].text
            let quoted = ((link["quotedText"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !quoted.isEmpty, !quoted.contains("]"),
               let range = text.range(of: quoted),
               text[..<range.lowerBound].filter({ $0 == "[" }).count
                   == text[..<range.lowerBound].filter({ $0 == "]" }).count {
                body[index].text = text.replacingCharacters(in: range, with: "[\(quoted)](\(url))")
            } else {
                body[index].text = text + " [\u{2197}](\(url))"
            }
        }
        return body
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
                                       preferringID: Bool = false,
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
        // The text is already decoded (decodedText) and goes to the parser
        // as UTF-8, so the XML declaration — which may name another
        // encoding — is dropped; kept, a Latin-1 chapter read as mojibake.
        let prepared = xmlSafeEntities(sanitized).replacingOccurrences(
            of: #"^\s*<\?xml[^>]*\?>"#, with: "", options: .regularExpression)
        let root: XMLTree.Element
        do {
            root = try XMLTree.parse(Data(prepared.utf8))
        } catch {
            // Tag soup (unclosed <p>, stray <br>) — the kind of chapter
            // browsers forgive — is tidied into XHTML and read again.
            #if os(macOS)
            guard let tidied = try? XMLDocument(data: Data(prepared.utf8),
                                                options: [.documentTidyHTML]).xmlData
            else { throw error }
            root = try XMLTree.parse(tidied)
            #else
            throw error
            #endif
        }
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
        // A flow with its own <h1> (a plain book's chapter title) ranks
        // h1, h2, h3 as levels 1, 2, 3; without one, <h2> is the top rank —
        // the profile's shape, whose <h1> title stands in the header.
        let flowHasH1 = main.firstDescendant(named: "h1") != nil
        let headingLevels = flowHasH1
            ? ["h1": 1, "h2": 2, "h3": 3, "h4": 3, "h5": 3, "h6": 3]
            : ["h1": 1, "h2": 1, "h3": 2, "h4": 3, "h5": 3, "h6": 3]
        func visit(_ element: XMLTree.Element, stretchID: String? = nil) {
            // §6.2: a profile publication is addressed by `id`, which wins
            // where both exist. `data-id` stays first for pre-1.0 books —
            // this app's own exports put the positional number in `id` and
            // the stable id in `data-id`, and annotations already use it.
            let stableID: () -> String = {
                fallbackOrdinal += 1
                let id = element.attributes["id"], dataID = element.attributes["data-id"]
                return address((preferringID ? id ?? dataID : dataID ?? id)
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
            case "math":
                // A display equation standing on its own (§7.7): its
                // alttext — the words the book gives every reader — kept
                // under the equation's id, so the Equations sheet's Go
                // lands on it. It used to vanish from the native readings.
                // An equation carrying its TeX (data-latex, which this
                // app's exports write) comes back as the display block it
                // was written from, so a re-export sets it as MathML again.
                if let tex = element.attributes["data-latex"]?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !tex.isEmpty {
                    var paragraph = LiquidDoc.Paragraph(id: stableID(), heading: nil,
                                                        text: "$$\n\(tex)\n$$")
                    paragraph.stretchID = stretchID
                    appendParagraph(paragraph, anchors: element)
                    break
                }
                let words = (element.attributes["alttext"] ?? element.attributes["data-latex"]
                    ?? element.plainText).trimmingCharacters(in: .whitespacesAndNewlines)
                if !words.isEmpty {
                    var paragraph = LiquidDoc.Paragraph(id: stableID(), heading: nil,
                                                        text: "`\(words)`")
                    paragraph.stretchID = stretchID
                    appendParagraph(paragraph, anchors: element)
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
                // A figure made from a view wraps its <img> in a plain
                // <a href> — the address that opens the view again — with
                // the figure's bibliography key on it (ORIGAMI-FIGURE-
                // LINKS-SPEC §1). The href is kept opaque: XMLParser has
                // already decoded `&amp;`, and nothing else is touched.
                let wrapper = element.name == "figure" ? element.parent(of: image) : nil
                let link = wrapper?.name == "a"
                    ? wrapper?.attributes["href"].flatMap { $0.isEmpty ? nil : $0 } : nil
                let figureKey = link == nil ? nil
                    : wrapper?.attributes["data-citation-key"].flatMap { $0.isEmpty ? nil : $0 }
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
                        alt: alt.isEmpty ? nil : alt,
                        link: link,
                        citationKey: figureKey))
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
                let tableID = element.attributes["data-table-id"]
                    ?? element.attributes["id"] ?? "table-\(fallbackOrdinal)"
                paragraph.tableID = tableID
                // A table the records do not describe (a plain book's)
                // still reads as a grid: its cells, as printed.
                if element.attributes["data-table-id"] == nil {
                    var rows: [[LiquidDoc.Table.Cell]] = []
                    func collectRows(_ node: XMLTree.Element) {
                        for child in node.elements {
                            if child.name == "tr" {
                                // colspan: the spanning cell, then empty
                                // cells for the columns it covers.
                                var row: [LiquidDoc.Table.Cell] = []
                                for cell in child.elements where cell.name == "td" || cell.name == "th" {
                                    let span = max(Int(cell.attributes["colspan"] ?? "") ?? 1, 1)
                                    row.append(.init(value: cell.plainText
                                        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                                        .trimmingCharacters(in: .whitespacesAndNewlines),
                                                     columnSpan: span > 1 ? span : nil))
                                    for _ in 1..<span { row.append(.init(value: "")) }
                                }
                                rows.append(row)
                            } else if child.name != "table" {
                                collectRows(child)
                            }
                        }
                    }
                    collectRows(element)
                    let columns = rows.map(\.count).max() ?? 0
                    if !rows.isEmpty, columns > 0 {
                        let padded = rows.map { $0 + Array(repeating: LiquidDoc.Table.Cell(value: ""),
                                                           count: columns - $0.count) }
                        capture?.staticTables.append(LiquidDoc.Table(
                            identifier: tableID, rowCount: padded.count,
                            columnCount: columns, cells: padded))
                    }
                }
                appendParagraph(paragraph, anchors: element)
            case "audio", "video":
                // Sound and film: a Play link that opens the file, with
                // the element's fallback words when it has any.
                let src = element.attributes["src"]
                    ?? element.firstDescendant(named: "source")?.attributes["src"]
                let label = element.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
                if let src, !src.isEmpty {
                    let kind = element.name == "audio" ? "audio" : "video"
                    let path = joinedPath(contentDir, src)
                        .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? src
                    appendParagraph(LiquidDoc.Paragraph(
                        id: stableID(), heading: nil,
                        text: "[\u{25B6} Play \(kind)\(label.isEmpty ? "" : ": " + label)](origami-media:\(path))"),
                        anchors: element)
                }
            case "svg":
                // An SVG wrapping one picture — the usual cover — shows
                // that picture; drawn artwork keeps its words.
                if let picture = element.firstDescendant(named: "image"),
                   let href = picture.attributes["xlink:href"] ?? picture.attributes["href"],
                   let data = resolveImage(href), !data.isEmpty {
                    assetOrdinal += 1
                    let assetID = address("img\(assetOrdinal)")
                    let name = (href as NSString).lastPathComponent
                    assets.append(LiquidDoc.Asset(
                        id: assetID, filename: name.isEmpty ? "\(assetID).png" : name,
                        mediaType: LiquidDoc.mediaType(forExtension: (name as NSString).pathExtension.lowercased()),
                        dataBase64: data.base64EncodedString(), alt: nil))
                    appendParagraph(LiquidDoc.Paragraph(
                        id: stableID(), heading: nil, text: "![](asset:\(assetID))"), anchors: element)
                } else {
                    let words = element.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !words.isEmpty {
                        appendParagraph(LiquidDoc.Paragraph(id: stableID(), heading: nil, text: words),
                                        anchors: element)
                    }
                }
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
        /// Each glossary link met: the entry it leads to, and its words.
        var glossaryUses: [(target: String, words: String)] = []
        /// Plain HTML tables, as grids the native styles can draw.
        var staticTables: [LiquidDoc.Table] = []
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

    /// References from the bibliography record that point at an Origami
    /// document, split out as internal citations — which the reader shows as
    /// live links — the same way `citationPool(fromVisualMeta:)` splits them
    /// when the address travels in the Visual-Meta URLs.
    ///
    /// The address is taken, in order, from the entry's `url` or `weburl`
    /// when either is an Origami address, from `origami-source-id`, and from
    /// `vm-id` — but only a vm-id that is an address: older Visual-Meta put
    /// a creation date there, which names no document. Everything else stays
    /// a reference.
    static func internalCitations(in references: [LiquidDoc.Reference])
        -> (references: [LiquidDoc.Reference],
            addressByCitationID: [String: String],
            bibtexByAddress: [String: String]) {
        var remaining: [LiquidDoc.Reference] = []
        var addressByCitationID: [String: String] = [:]
        var bibtexByAddress: [String: String] = [:]

        func field(_ name: String, in fields: [String: String]) -> String? {
            let value = fields[name]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? nil : value
        }

        for reference in references {
            let fields = BibTeXParser.first(reference.bibtex)?.fields ?? [:]
            let fromURL = ["url", "weburl"]
                .compactMap { field($0, in: fields) }
                .lazy.compactMap(originalAddress(fromOpenURL:)).first
            let fromVMID = field("vm-id", in: fields)
                .flatMap { LiquidDoc.parseISO8601($0) == nil ? $0 : nil }
            let address = fromURL ?? field("origami-source-id", in: fields) ?? fromVMID

            if let address {
                addressByCitationID[reference.id] = address
                bibtexByAddress[address] = reference.bibtex
            } else {
                remaining.append(reference)
            }
        }
        return (remaining, addressByCitationID, bibtexByAddress)
    }

    /// The citation a biblioref anchor names: our own exports' explicit
    /// `data-citation-key`, or — as Profile 1.0 §7 requires of every
    /// writer — the target of an `epub:type="biblioref"` link,
    /// `#bib-<id>`, whose id is the citation's.
    static func citationKey(of attributes: [String: String]) -> String? {
        if let key = attributes["data-citation-key"], !key.isEmpty { return key }
        let type = (attributes["epub:type"] ?? "") + " " + (attributes["role"] ?? "")
        guard type.contains("biblioref"),
              let href = attributes["href"], let hash = href.firstIndex(of: "#") else { return nil }
        var target = String(href[href.index(after: hash)...])
        if target.hasPrefix("bib-") { target.removeFirst(4) }
        else if target.hasPrefix("ref-") { return nil }  // numbered lists resolve by number
        return target.isEmpty ? nil : target
    }

    /// The visible reference lines, by citation id: `<li id="bib-…">`.
    static func bibliographyListText(in xhtml: String) -> [String: String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"<li[^>]*\bid="bib-([^"]+)"[^>]*>(.*?)</li>"#,
            options: [.dotMatchesLineSeparators]) else { return [:] }
        var out: [String: String] = [:]
        for match in regex.matches(in: xhtml, range: NSRange(xhtml.startIndex..., in: xhtml)) {
            guard let idRange = Range(match.range(at: 1), in: xhtml),
                  let textRange = Range(match.range(at: 2), in: xhtml) else { continue }
            out[String(xhtml[idRange])] = String(xhtml[textRange])
                .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        }
        return out
    }

    /// The href of the package's bibliography record — the `<link
    /// rel="record">` whose properties name `origami:bibliography`.
    static func bibliographyHref(in opf: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"<link\b[^>]*>"#) else { return nil }
        let range = NSRange(opf.startIndex..., in: opf)
        for match in regex.matches(in: opf, range: range) {
            guard let tagRange = Range(match.range, in: opf) else { continue }
            let tag = String(opf[tagRange])
            guard tag.range(of: #"properties="[^"]*\borigami:bibliography\b(?!-)"#,
                            options: .regularExpression) != nil else { continue }
            return firstCapture(in: tag, pattern: #"href="([^"]+)""#)
        }
        return nil
    }

    /// References from the bibliography record, matched to the
    /// metadata's citations. Profile 1.0 makes each BibTeX key the
    /// citation's id; a record written before that rule (keys of its
    /// own, as Author's are) is matched by order instead — the record
    /// lists the entries in citation-number order. Each entry's key is
    /// set to the citation's id, so the body's anchors and \cite keys
    /// agree with it.
    static func referencesFromBibliography(_ text: String,
                                           citations: [[String: Any]],
                                           listText: [String: String] = [:]) -> [LiquidDoc.Reference] {
        // "@{key," — an entry written without its type — is read as
        // @misc rather than dropped.
        let repaired = text.replacingOccurrences(of: #"@\s*\{"#, with: "@misc{",
                                                 options: .regularExpression)
        let entries = BibTeXParser.parse(repaired)
        guard !entries.isEmpty else { return [] }
        let cited = citations
            .compactMap { citation -> (id: String, number: Int)? in
                guard let id = citation["id"] as? String else { return nil }
                return (id, (citation["number"] as? NSNumber)?.intValue ?? Int.max)
            }
            .sorted { $0.number < $1.number }
        let byKey = Dictionary(entries.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let keyed = cited.contains { byKey[$0.id] != nil }
        func rekeyed(_ entry: BibTeXEntry, as id: String) -> String {
            // Whatever stands between the entry's "{" and its first comma
            // is the key — replaced whole, and any doubled comma a
            // writer left after it collapsed, so no field is misread.
            guard let open = entry.raw.firstIndex(of: "{") else { return entry.raw }
            let rest = entry.raw[entry.raw.index(after: open)...]
            guard let comma = rest.firstIndex(of: ",") else { return entry.raw }
            let tail = String(rest[rest.index(after: comma)...])
                .replacingOccurrences(of: #"^[\s,]*,"#, with: "\n ", options: .regularExpression)
            return String(entry.raw[...open]) + id + "," + tail
        }
        if cited.isEmpty {
            return entries.enumerated().map { index, entry in
                LiquidDoc.Reference(id: entry.key, bibtex: entry.raw, number: index + 1)
            }
        }
        // Without matching keys, each citation is matched by what its
        // visible reference line says — the entry whose title (or, for
        // a title-less one, first author) that line contains. Never by
        // position: a record that skips an empty entry would shift every
        // reference after it onto the wrong citation.
        func normalised(_ text: String) -> String {
            BibTeXParser.displayText(text).lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }.joined(separator: " ")
        }
        var unclaimed = entries
        func claim(for id: String) -> BibTeXEntry? {
            guard let line = listText[id].map(normalised), !line.isEmpty else { return nil }
            let match = unclaimed.firstIndex { entry in
                if let title = entry.fields["title"].map(normalised), title.count >= 8 {
                    return line.contains(title)
                }
                if let author = entry.fields["author"].map(normalised), !author.isEmpty {
                    return line.contains(author.components(separatedBy: " ").first ?? author)
                }
                return false
            }
            return match.map { unclaimed.remove(at: $0) }
        }
        return cited.enumerated().compactMap { index, citation in
            let entry = keyed ? byKey[citation.id]
                : (listText.isEmpty ? (index < entries.count ? entries[index] : nil)
                                    : claim(for: citation.id))
            guard let entry else { return nil }
            return LiquidDoc.Reference(
                id: citation.id, bibtex: rekeyed(entry, as: citation.id),
                number: citation.number == Int.max ? index + 1 : citation.number)
        }
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

    /// Emphasis as the readers parse it: the marker hugging the words,
    /// its spaces outside ("*Origami *" never opens a run — the stray
    /// star then pairs with the next and bolds a word), nothing for a run
    /// of spaces alone, and a run straight after one of its own kind
    /// joined to it ("*Origami Text**XR*" read its "**" as bold). Author
    /// splits one italic phrase wherever a glossary link falls inside it.
    static func appendEmphasis(_ content: String, marker: String, to out: inout String) {
        let core = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !core.isEmpty else {
            out += content
            return
        }
        let leading = String(content.prefix { $0.isWhitespace })
        let trailing = String(content.reversed().prefix { $0.isWhitespace }.reversed())
        // A run of the same kind just closed, with nothing between: one run.
        let longer = marker + "*"
        if leading.isEmpty, out.hasSuffix(marker), !out.hasSuffix(longer) {
            out.removeLast(marker.count)
            out += core + marker + trailing
            return
        }
        out += leading + marker + core + marker + trailing
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
                case "br":
                    // A line break inside a paragraph — verse, addresses —
                    // stays a break, never words run together.
                    out += "\n"
                case "math":
                    // Inline MathML reads as its alttext; its pieces run
                    // together ("E=mc2") lose the superscript.
                    // One carrying its TeX comes back as `$tex$`, which
                    // the export sets as MathML again.
                    if let tex = inner.attributes["data-latex"], !tex.isEmpty {
                        out += "$\(tex)$"
                    } else {
                        out += inner.attributes["alttext"] ?? content
                    }
                case "strong", "b":
                    if inner.attributes["class"] == "speaker" {
                        out += content
                    } else {
                        appendEmphasis(content, marker: "**", to: &out)
                    }
                case "em", "i":
                    appendEmphasis(content, marker: "*", to: &out)
                case "mark":
                    // Author's Marked text arrives as <mark>; the reader's
                    // convention for it is ==…== (OrigamiReading.inlineAttributed).
                    // It fell through to plain words before, so no view
                    // could show what the author had Marked.
                    out += "==\(content)=="
                case "code":
                    out += "`\(content)`"
                case "dfn":
                    out += content
                case "rt", "rp":
                    // Readings are gathered by their <ruby> (below).
                    break
                case "ruby":
                    // Ruby (furigana): the base text, its reading after it
                    // in brackets — kept, where it used to be dropped.
                    let reading = inner.elements.filter { $0.name == "rt" }
                        .map { $0.plainText.trimmingCharacters(in: .whitespaces) }
                        .joined()
                    if reading.isEmpty {
                        out += content
                    } else {
                        let wide = reading.unicodeScalars.contains { $0.value >= 0x3000 }
                        out += content + (wide ? "\u{FF08}\(reading)\u{FF09}" : " (\(reading))")
                    }
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
                    if (inner.attributes["class"] ?? "").contains("ot-note-back") {
                        // An endnote's back link to its first mark: its
                        // number stays as words (the exporter wraps it
                        // again), never a jump token — whose target text
                        // read as a citation of the paragraph's own id.
                        out += content
                        break
                    }
                    // A citation of another Origami document carries its
                    // full-resolution address in data-origami-ref; it is
                    // restored as that address below, never as a [cite:]
                    // key, even though its href names #bib-<key> (1.0).
                    if (inner.attributes["data-origami-ref"] ?? "").isEmpty,
                       let key = citationKey(of: inner.attributes) {
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
                    } else if (inner.attributes["epub:type"] ?? "").contains("glossref")
                                || (inner.attributes["role"] ?? "").contains("doc-glossref") {
                        // A glossary link: its words stay plain text (terms
                        // are not links in this reader); where it leads is
                        // noted, so the definition attaches to the words
                        // the author marked, not only to the term's name.
                        if let href = inner.attributes["href"],
                           let hash = href.lastIndex(of: "#") {
                            capture?.glossaryUses.append(
                                (String(href[href.index(after: hash)...]), content))
                        }
                        out += content
                    } else if let action = quoteLinkAction(of: inner.attributes),
                              !content.isEmpty {
                        // A cross-document quote link (§7.11): the
                        // origamitext:// action, in data-origami-action or
                        // the href itself, which the readers follow into
                        // the library.
                        out += "[\(content)](\(action))"
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

        /// The element in this subtree whose direct child is `target`,
        /// this one included — how a figure's `<img>` finds the `<a>`
        /// wrapping it.
        func parent(of target: Element) -> Element? {
            for element in elements {
                if element === target { return self }
                if let found = element.parent(of: target) { return found }
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
