import Foundation
import AppKit
import UniformTypeIdentifiers

/// Everything Import to Format can start from, read into one document.
///
/// Each kind goes through the richest reader the app already has — the
/// ACM paper paths for LaTeX, JATS and ACM Word, the plain importers for
/// the rest — so a paper arrives with as much of its front matter and
/// bibliography as its source states. Nothing here files the document
/// into the library; the Format sheet renders it and the library is
/// untouched.
@MainActor
enum FormatSources {

    /// The file extensions offered in the open panel.
    static let extensions: [String] = [
        "epub",
        "docx", "doc", "odt", "rtf", "rtfd",
        "tex", "zip", "gz", "tgz", "tar",
        "md", "markdown", "txt",
        "html", "htm", "xhtml",
        "xml",
        "pdf",
        "liquid",
        "bib", "json",
    ]

    static var contentTypes: [UTType] {
        extensions.compactMap { UTType(filenameExtension: $0) }
    }

    struct Loaded {
        var doc: LiquidDoc
        /// What the reader wants the person to know — a flattened
        /// citation field, a scanned PDF, an unreadable figure.
        var notices: [String] = []
    }

    enum SourceError: LocalizedError {
        case unsupported(String)
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .unsupported(let ext):
                "Import to Format cannot read .\(ext) files."
            case .unreadable(let why):
                why
            }
        }
    }

    static func load(_ url: URL, fallbackAuthor: String) throws -> Loaded {
        let name = url.lastPathComponent.lowercased()
        let ext = url.pathExtension.lowercased()
        if name.hasSuffix(".tar.gz") || ext == "tgz" || ext == "tar" || ext == "gz" {
            return try loadTarball(url, fallbackAuthor: fallbackAuthor)
        }
        switch ext {
        case "epub":
            let result = try OrigamiEPUBImporter.importDocument(at: url)
            return Loaded(doc: AppModel.structuredDoc(
                from: result, record: nil,
                fallbackID: url.deletingPathExtension().lastPathComponent, base: url))

        case "docx", "doc":
            if ACMWordPaper.isPaper(at: url) {
                let result = try ACMWordPaper.importPaper(at: url,
                                                          tapsHTML: AppModel.tapsHTMLBeside(url))
                var doc = make(title: result.title,
                               author: result.authors.joined(separator: ", "),
                               body: result.body, url: url)
                doc.authors = result.authors
                doc.publication = result.publication
                doc.doi = result.doi
                doc.references = result.references
                doc.tables = result.tables
                doc.assets = result.assets
                doc.affiliations = result.affiliations
                doc.acmReference = result.acmReference
                doc.authorORCIDs = result.authorORCIDs
                doc.authorEmails = result.authorEmails
                doc.authorAffiliations = result.authorAffiliations
                doc.license = result.license
                return Loaded(doc: doc, notices: result.notices)
            }
            return try loadRichText(url, fallbackAuthor: fallbackAuthor)

        case "odt", "rtf", "rtfd":
            // macOS reads OpenDocument and RTF the way it reads Word:
            // headings from type size, lists, links and images.
            return try loadRichText(url, fallbackAuthor: fallbackAuthor)

        case "html", "htm", "xhtml":
            var loaded = try loadRichText(url, fallbackAuthor: fallbackAuthor)
            let raw = (try? String(contentsOf: url, encoding: .utf8))
                ?? String(decoding: (try? Data(contentsOf: url)) ?? Data(), as: UTF8.self)
            applyScholarMeta(from: raw, to: &loaded.doc)
            return loaded

        case "tex":
            return Loaded(doc: doc(fromLaTeX: try LaTeXImporter.importTeXFile(at: url), url: url,
                                   fallbackAuthor: fallbackAuthor))

        case "zip":
            // A LaTeX project — Overleaf's download, a publisher's
            // source zip — whichever file declares the document.
            return Loaded(doc: doc(fromLaTeX: try LaTeXImporter.importArchive(at: url), url: url,
                                   fallbackAuthor: fallbackAuthor))

        case "xml":
            let result = try BITSImporter.importFile(at: url)
            var doc = make(title: result.title, author: result.author ?? fallbackAuthor,
                           body: result.body, url: url)
            doc.publication = result.publication
            doc.references = result.references
            doc.tables = result.tables
            doc.assets = result.assets
            return Loaded(doc: doc)

        case "md", "markdown", "txt":
            let result = try MarkdownImporter.importFile(at: url)
            return Loaded(doc: make(title: result.title, author: result.author ?? fallbackAuthor,
                                    body: result.body, url: url))

        case "pdf":
            let result = try PDFImporter.importFile(at: url)
            var doc = make(title: result.title, author: result.author ?? fallbackAuthor,
                           body: result.body, url: url)
            doc.date = result.date
            return Loaded(doc: doc)

        case "liquid":
            let result = try AuthorImporter.importDocument(at: url)
            var doc = make(title: result.title, author: result.author ?? fallbackAuthor,
                           body: result.body, url: url)
            doc.references = result.references
            doc.concepts = result.concepts
            return Loaded(doc: doc)

        case "bib":
            let text = try String(contentsOf: url, encoding: .utf8)
            return Loaded(doc: try referenceList(fromBibTeX: text, url: url,
                                                 fallbackAuthor: fallbackAuthor))

        case "json":
            let data = try Data(contentsOf: url)
            return Loaded(doc: try referenceList(fromCSLJSON: data, url: url,
                                                 fallbackAuthor: fallbackAuthor))

        default:
            throw SourceError.unsupported(ext)
        }
    }

    // MARK: Building the document

    private static func make(title: String, author: String,
                             body: [LiquidDoc.Paragraph], url: URL) -> LiquidDoc {
        var doc = LiquidDoc(format: LiquidDoc.knownFormat,
                            id: LiquidAddress.makeID(author: author, created: .now),
                            title: title, author: author, created: .now,
                            body: body, links: [], wraps: nil, fileURL: url)
        let names = splitNames(author)
        if names.count > 1 { doc.authors = names }
        return doc
    }

    /// "A, B and C" → ["A", "B", "C"].
    private static func splitNames(_ author: String) -> [String] {
        author.components(separatedBy: ",")
            .flatMap { $0.components(separatedBy: " and ") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func doc(fromLaTeX result: LaTeXImporter.Result, url: URL,
                            fallbackAuthor: String) -> LiquidDoc {
        var doc = make(title: result.title, author: result.author ?? fallbackAuthor,
                       body: result.body, url: url)
        doc.subtitle = result.subtitle
        doc.publication = result.publication
        doc.doi = result.doi
        doc.references = result.references
        doc.tables = result.tables
        doc.assets = result.assets
        doc.affiliations = result.affiliations
        doc.acmReference = result.acmReference
        doc.authorORCIDs = result.authorORCIDs
        doc.authorEmails = result.authorEmails
        doc.authorAffiliations = result.authorAffiliations
        return doc
    }

    private static func loadRichText(_ url: URL, fallbackAuthor: String) throws -> Loaded {
        let result = try WordImporter.importFile(at: url)
        var doc = make(title: result.title, author: result.author ?? fallbackAuthor,
                       body: result.body, url: url)
        doc.assets = result.assets
        doc.references = result.references
        return Loaded(doc: doc, notices: result.notices)
    }

    // MARK: arXiv source

    /// An arXiv source download: a gzipped tarball of the LaTeX project,
    /// or — for a single-file paper — the gzipped .tex alone. Unpacked
    /// with the system's own tar and gunzip into a temporary folder,
    /// then read as any LaTeX project is.
    private static func loadTarball(_ url: URL, fallbackAuthor: String) throws -> Loaded {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("origami-source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let tarred = run("/usr/bin/tar", ["-xf", url.path, "-C", work.path])
        let unpacked = FolderArchive(root: work).entryNames
        if !tarred || unpacked.isEmpty {
            // Not a tarball: a lone gzipped file (arXiv's single-.tex form).
            let tex = work.appendingPathComponent("main.tex")
            guard FileManager.default.createFile(atPath: tex.path, contents: nil),
                  let handle = try? FileHandle(forWritingTo: tex),
                  run("/usr/bin/gunzip", ["-c", url.path], output: handle),
                  (try? Data(contentsOf: tex))?.isEmpty == false else {
                throw SourceError.unreadable("\(url.lastPathComponent) is not a LaTeX source archive.")
            }
        }
        let result = try LaTeXImporter.importFolder(at: work)
        var doc = doc(fromLaTeX: result, url: url, fallbackAuthor: fallbackAuthor)
        if doc.title == work.lastPathComponent {
            doc.title = url.lastPathComponent
                .replacingOccurrences(of: ".tar.gz", with: "")
                .replacingOccurrences(of: ".tgz", with: "")
                .replacingOccurrences(of: ".gz", with: "")
        }
        return Loaded(doc: doc)
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String],
                            output: FileHandle? = nil) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = output ?? FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        try? output?.close()
        return process.terminationStatus == 0
    }

    // MARK: Web pages

    /// The citation metadata scholarly web pages carry for Google
    /// Scholar (`citation_title`, `citation_author`, `citation_doi` …)
    /// and Dublin Core (`DC.title`, `DC.creator`), laid over what the
    /// page's text gave. Every publisher's article page has them.
    static func applyScholarMeta(from html: String, to doc: inout LiquidDoc) {
        var meta: [String: [String]] = [:]
        let pattern = #"<meta\s+[^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return }
        for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let range = Range(match.range, in: html) else { continue }
            let tag = String(html[range])
            func attribute(_ name: String) -> String? {
                guard let found = tag.range(of: #"\#(name)\s*=\s*["']([^"']*)["']"#,
                                            options: [.regularExpression, .caseInsensitive]) else { return nil }
                let pair = String(tag[found])
                guard let quote = pair.firstIndex(where: { $0 == "\"" || $0 == "'" }) else { return nil }
                return String(pair[pair.index(after: quote)...].dropLast())
            }
            guard let key = (attribute("name") ?? attribute("property"))?.lowercased(),
                  let content = attribute("content")?.trimmingCharacters(in: .whitespaces),
                  !content.isEmpty else { continue }
            meta[key, default: []].append(decodeEntities(content))
        }
        func first(_ keys: String...) -> String? {
            keys.lazy.compactMap { meta[$0]?.first }.first
        }
        if let title = first("citation_title", "dc.title", "og:title") { doc.title = title }
        let authors = meta["citation_author"] ?? meta["dc.creator"] ?? []
        if !authors.isEmpty {
            // Scholar writes "Family, Given"; the document keeps
            // names as printed.
            doc.authors = authors.map { name in
                let parts = name.components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                return parts.count == 2 ? "\(parts[1]) \(parts[0])" : name
            }
            let affiliations = meta["citation_author_institution"] ?? []
            for (index, name) in doc.authors.enumerated() where index < affiliations.count {
                doc.authorAffiliations[name] = affiliations[index]
            }
        }
        if let venue = first("citation_journal_title", "citation_conference_title",
                             "citation_inbook_title", "dc.source") { doc.publication = venue }
        if let doi = first("citation_doi", "dc.identifier")?
            .replacingOccurrences(of: "https://doi.org/", with: "")
            .replacingOccurrences(of: "doi:", with: ""), doi.hasPrefix("10.") { doc.doi = doi }
        if let date = first("citation_publication_date", "citation_date", "dc.date") {
            let iso = date.replacingOccurrences(of: "/", with: "-")
            doc.date = LiquidDate(isoString: String(iso.prefix(10))) ?? LiquidDate(isoString: String(iso.prefix(4)))
        }
        if let abstract = first("citation_abstract", "dc.description", "description") {
            doc.abstract = abstract
        }
        let keywords = (meta["citation_keywords"] ?? meta["keywords"] ?? [])
            .flatMap { $0.components(separatedBy: CharacterSet(charactersIn: ";,")) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if !keywords.isEmpty { doc.keywords = keywords }
    }

    private static func decodeEntities(_ text: String) -> String {
        text.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }

    // MARK: Reference lists

    /// A bibliography on its own — a .bib file — as a document whose
    /// whole content is its reference list, so the Format sheet can set
    /// it in any publisher's reference style.
    static func referenceList(fromBibTeX text: String, url: URL,
                              fallbackAuthor: String) throws -> LiquidDoc {
        // Whole-line % comments go first: a template bibliography's header
        // says things like "see @String below", and a stray @ in a comment
        // derails the parse of everything after it.
        func uncommented(_ text: String) -> String {
            text.components(separatedBy: .newlines)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("%") }
                .joined(separator: "\n")
        }
        // Twice: once for the header, once for the "% …" tails an @String
        // line leaves behind when its block is removed — an apostrophe in
        // one ("didn't") reads to the parser as an opening quote.
        let repaired = uncommented(expandingStringMacros(in: uncommented(text)))
            .replacingOccurrences(of: #"@\s*\{"#, with: "@misc{", options: .regularExpression)
        let entries = BibTeXParser.parse(repaired)
        guard !entries.isEmpty else {
            throw SourceError.unreadable("\(url.lastPathComponent) holds no BibTeX entries.")
        }
        var used: Set<String> = []
        let references = entries.enumerated().map { index, entry -> LiquidDoc.Reference in
            var key = entry.key.isEmpty ? "ref\(index + 1)" : entry.key
            while used.contains(key) { key += "x" }
            used.insert(key)
            return LiquidDoc.Reference(id: key, bibtex: entry.raw, number: index + 1)
        }
        return referenceListDocument(references, url: url, fallbackAuthor: fallbackAuthor)
    }

    /// BibTeX's housekeeping blocks — `@String` abbreviations, `@Preamble`,
    /// `@Comment` — removed, and each abbreviation expanded where an entry
    /// uses it bare (`journal = CACM`), as BibTeX itself does. A template
    /// bibliography (ACM's sample-base.bib) opens with dozens of these.
    static func expandingStringMacros(in text: String) -> String {
        var macros: [String: String] = [:]
        var kept = ""
        var index = text.startIndex
        while let at = text[index...].firstIndex(of: "@") {
            kept += text[index..<at]
            let head = text[at...].prefix(12).lowercased()
            let kind = ["@string", "@preamble", "@comment"].first { head.hasPrefix($0) }
            guard let kind, let open = text[at...].firstIndex(where: { $0 == "{" || $0 == "(" }) else {
                kept.append("@")
                index = text.index(after: at)
                continue
            }
            // The block runs to its matching close.
            var depth = 0
            var end = open
            var cursor = open
            while cursor < text.endIndex {
                let character = text[cursor]
                if character == "{" || character == "(" { depth += 1 }
                if character == "}" || character == ")" {
                    depth -= 1
                    if depth == 0 { end = cursor; break }
                }
                cursor = text.index(after: cursor)
            }
            if kind == "@string" {
                let inner = text[text.index(after: open)..<end]
                if let equals = inner.firstIndex(of: "=") {
                    let name = inner[..<equals].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    var value = inner[inner.index(after: equals)...].trimmingCharacters(in: .whitespacesAndNewlines)
                    if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("{") && value.hasSuffix("}")) {
                        value = String(value.dropFirst().dropLast())
                    }
                    macros[name] = value   // a later definition overrides, as BibTeX's does
                }
            }
            index = end < text.endIndex ? text.index(after: end) : text.endIndex
        }
        kept += text[index...]
        guard !macros.isEmpty,
              let regex = try? NSRegularExpression(pattern: #"(=\s*)([A-Za-z][A-Za-z0-9_\-]*)(\s*[,}\n])"#)
        else { return kept }
        let source = kept as NSString
        let out = NSMutableString(string: source)
        // Back to front, so each replacement leaves the earlier ranges valid.
        for match in regex.matches(in: kept, range: NSRange(location: 0, length: source.length)).reversed() {
            let name = source.substring(with: match.range(at: 2)).lowercased()
            guard let value = macros[name] else { continue }
            out.replaceCharacters(in: match.range(at: 2), with: "{\(value)}")
        }
        return out as String
    }

    /// CSL-JSON — Zotero's and every citation processor's exchange
    /// format: an array of items, or `{"items": [...]}` — turned into
    /// BibTeX records and set as a reference list.
    static func referenceList(fromCSLJSON data: Data, url: URL,
                              fallbackAuthor: String) throws -> LiquidDoc {
        let json = try JSONSerialization.jsonObject(with: data)
        let items = (json as? [[String: Any]])
            ?? ((json as? [String: Any])?["items"] as? [[String: Any]])
            ?? []
        guard !items.isEmpty, items.contains(where: { $0["title"] != nil || $0["type"] != nil }) else {
            throw SourceError.unreadable("\(url.lastPathComponent) is not a CSL-JSON reference list.")
        }
        var used: Set<String> = []
        let references = items.enumerated().map { index, item -> LiquidDoc.Reference in
            var key = (item["id"] as? String) ?? (item["id"] as? NSNumber)?.stringValue ?? "ref\(index + 1)"
            key = key.replacingOccurrences(of: #"[^A-Za-z0-9:_\-./]"#, with: "",
                                           options: .regularExpression)
            if key.isEmpty { key = "ref\(index + 1)" }
            while used.contains(key) { key += "x" }
            used.insert(key)
            return LiquidDoc.Reference(id: key, bibtex: bibtex(fromCSL: item, key: key),
                                       number: index + 1)
        }
        return referenceListDocument(references, url: url, fallbackAuthor: fallbackAuthor)
    }

    private static func referenceListDocument(_ references: [LiquidDoc.Reference], url: URL,
                                              fallbackAuthor: String) -> LiquidDoc {
        let title = url.deletingPathExtension().lastPathComponent
        let body = [LiquidDoc.Paragraph(
            id: "p1", heading: nil,
            text: "This document is a reference list of \(references.count) works.")]
        var doc = make(title: title, author: fallbackAuthor, body: body, url: url)
        doc.references = references
        // Read by the LaTeX writers as "print every entry" (\nocite{*}):
        // a reference list cites nothing in its text.
        doc.documentType = ACMLaTeX.referenceListType
        return doc
    }

    /// One CSL-JSON item as a BibTeX record.
    static func bibtex(fromCSL item: [String: Any], key: String) -> String {
        let type: String = switch (item["type"] as? String) ?? "" {
        case "article-journal", "article-magazine", "article-newspaper", "article": "article"
        case "paper-conference": "inproceedings"
        case "book": "book"
        case "chapter": "incollection"
        case "report": "techreport"
        case "thesis": "phdthesis"
        default: "misc"
        }
        var fields: [String: String] = [:]
        func names(_ key: String) -> String? {
            let people = (item[key] as? [[String: Any]] ?? []).compactMap { person -> String? in
                if let literal = person["literal"] as? String { return "{\(literal)}" }
                let family = (person["family"] as? String) ?? ""
                let given = (person["given"] as? String) ?? ""
                if family.isEmpty { return given.isEmpty ? nil : given }
                return given.isEmpty ? family : "\(family), \(given)"
            }
            return people.isEmpty ? nil : people.joined(separator: " and ")
        }
        fields["author"] = names("author")
        fields["editor"] = names("editor")
        fields["title"] = item["title"] as? String
        if let container = item["container-title"] as? String {
            fields[type == "article" ? "journal" : "booktitle"] = container
        }
        if let parts = (item["issued"] as? [String: Any])?["date-parts"] as? [[Any]],
           let year = parts.first?.first {
            fields["year"] = "\(year)"
        }
        fields["volume"] = (item["volume"] as? String) ?? (item["volume"] as? NSNumber)?.stringValue
        fields["number"] = (item["issue"] as? String) ?? (item["issue"] as? NSNumber)?.stringValue
        fields["pages"] = (item["page"] as? String)?.replacingOccurrences(of: "-", with: "--")
        fields["publisher"] = item["publisher"] as? String
        fields["doi"] = item["DOI"] as? String
        fields["url"] = item["URL"] as? String
        fields["isbn"] = item["ISBN"] as? String
        fields["abstract"] = item["abstract"] as? String
        return BibTeXWriter.write(type: type, key: key, fields: fields.compactMapValues { $0 })
    }
}
