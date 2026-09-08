import Foundation
import CoreGraphics
import ImageIO

/// LaTeX in, an Origami document out — the reverse of Author's LaTeX
/// export. Reads a zipped LaTeX project (Author's export: `main.tex`,
/// `references.bib`, `figures/`) or a bare `.tex` file, and recovers the
/// document model the EPUB exporter writes: headings, paragraphs, lists,
/// quotes, figures as assets, live tables (Author's VISUALMETA:TABLES
/// comment block, formulas included), citations as `[cite:key]` tokens
/// backed by the BibTeX references, and footnotes as `[note:id]` endnotes.
/// Tolerant of generic LaTeX: unknown commands unwrap to their argument
/// or drop; nothing readable is lost.
nonisolated enum LaTeXImportError: LocalizedError {
    case noTeX
    case unreadable

    var errorDescription: String? {
        switch self {
        case .noTeX: "No .tex file was found in the archive."
        case .unreadable: "The LaTeX source could not be read as text."
        }
    }
}

nonisolated enum LaTeXImporter {

    struct Result: Sendable {
        var title: String
        var author: String?
        /// The journal or proceedings the paper is part of, from the
        /// preamble: \acmJournal, the conference name in \acmConference,
        /// or \acmBooktitle's full proceedings title, in that order.
        var publication: String?
        var body: [LiquidDoc.Paragraph]
        var references: [LiquidDoc.Reference] = []
        var tables: [LiquidDoc.Table] = []
        var assets: [LiquidDoc.Asset] = []
        /// The paper's own DOI, from `\acmDOI` — carried into the
        /// EPUB's Visual-Meta so citations to the paper resolve and a
        /// DOI-named export needs no lookup.
        var doi: String? = nil
    }

    // MARK: - Entry points

    /// A zipped LaTeX project — Author's export, or any archive with a
    /// .tex inside. `main.tex` is preferred; else the file that declares
    /// `\documentclass` and `\begin{document}`; else the largest .tex.
    static func importArchive(at url: URL) throws -> Result {
        let zip = try ZipReader(data: try Data(contentsOf: url))
        // Sorted: zip.entries is a Dictionary, and every selection rule
        // below must pick the same file on every run.
        let texNames = zip.entries.keys.filter {
            $0.lowercased().hasSuffix(".tex") && !$0.contains("__MACOSX")
        }.sorted()
        guard !texNames.isEmpty else { throw LaTeXImportError.noTeX }
        func text(_ name: String) -> String? {
            zip.entry(name).map { String(decoding: $0, as: UTF8.self) }
        }
        // The manuscript: main.tex by name; else, among the files that
        // declare a document, the shallowest path (a stray draft often
        // hides in a subfolder — ht26-17 ships an old arXiv copy under
        // Images/), the larger file on a tie; else the largest .tex.
        let candidates = texNames.filter {
            let source = text($0) ?? ""
            return source.contains("\\documentclass") && source.contains("\\begin{document}")
        }
        let main = texNames.first { ($0 as NSString).lastPathComponent == "main.tex" }
            ?? candidates.min { lhs, rhs in
                let leftDepth = lhs.filter { $0 == "/" }.count
                let rightDepth = rhs.filter { $0 == "/" }.count
                if leftDepth != rightDepth { return leftDepth < rightDepth }
                return (zip.entry(lhs)?.count ?? 0) > (zip.entry(rhs)?.count ?? 0)
            }
            ?? texNames.max { (zip.entry($0)?.count ?? 0) < (zip.entry($1)?.count ?? 0) }!
        let mainDir = (main as NSString).deletingLastPathComponent
        guard var tex = text(main) else { throw LaTeXImportError.unreadable }

        func joined(_ directory: String, _ name: String) -> String {
            directory.isEmpty ? name : "\(directory)/\(name)"
        }
        // \input/\include pull sibling files into the flow, one level of
        // nesting at a time (a modest cap guards against cycles).
        tex = inlinedInputs(tex) { name in
            let candidates = [name, name + ".tex"]
                .flatMap { [joined(mainDir, $0), $0] }
            return candidates.lazy.compactMap(text).first
        }

        let bibliography = zip.entries
            .filter { $0.key.lowercased().hasSuffix(".bib") && !$0.key.contains("__MACOSX") }
            .sorted { $0.key < $1.key }
            .map { String(decoding: $0.value, as: UTF8.self) }
            .joined(separator: "\n")

        // Some sources nest another zip beside the manuscript (ht26-2
        // ships its preview bundle, holding images the outer archive
        // lacks) — those entries answer as a last resort, opened once.
        var nestedEntries: [String: Data]?
        let resources: (String) -> Data? = { path in
            let name = (path as NSString).lastPathComponent
            if let direct = zip.entry(joined(mainDir, path))
                ?? zip.entry(path)
                ?? zip.entries.first(where: { $0.key.hasSuffix("/" + name) || $0.key == name })?.value {
                return direct
            }
            if nestedEntries == nil {
                nestedEntries = [:]
                for (entryName, data) in zip.entries
                where entryName.lowercased().hasSuffix(".zip") && !entryName.contains("__MACOSX") {
                    guard let inner = try? ZipReader(data: data) else { continue }
                    for (innerName, innerData) in inner.entries {
                        nestedEntries?[innerName] = innerData
                    }
                }
            }
            return nestedEntries?[path]
                ?? nestedEntries?.first { $0.key.hasSuffix("/" + name) || $0.key == name }?.value
        }
        return importTeX(tex, bibliography: bibliography, resources: resources,
                         fallbackTitle: url.deletingPathExtension().lastPathComponent)
    }

    /// A bare .tex file, its figures and .bib resolved beside it on disk.
    static func importTeXFile(at url: URL) throws -> Result {
        guard let tex = try? String(contentsOf: url, encoding: .utf8) else {
            throw LaTeXImportError.unreadable
        }
        let directory = url.deletingLastPathComponent()
        let inlined = inlinedInputs(tex) { name in
            let candidates = [name, name + ".tex"]
            return candidates.lazy
                .compactMap { try? String(contentsOf: directory.appendingPathComponent($0),
                                          encoding: .utf8) }
                .first
        }
        // The .bib files the source names, else every one beside it.
        var bibNames = captures(in: inlined, pattern: #"\\bibliography\{([^}]+)\}"#)
            .flatMap { $0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) } }
            .map { $0.hasSuffix(".bib") ? $0 : $0 + ".bib" }
        if bibNames.isEmpty {
            bibNames = (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?
                .filter { $0.lowercased().hasSuffix(".bib") } ?? []
        }
        let bibliography = bibNames
            .compactMap { try? String(contentsOf: directory.appendingPathComponent($0),
                                      encoding: .utf8) }
            .joined(separator: "\n")
        return importTeX(inlined, bibliography: bibliography,
                         resources: { path in
                             try? Data(contentsOf: directory.appendingPathComponent(path))
                         },
                         fallbackTitle: url.deletingPathExtension().lastPathComponent)
    }

    // MARK: - The parse

    static func importTeX(_ source: String, bibliography: String,
                          resources: @escaping (String) -> Data?,
                          fallbackTitle: String) -> Result {
        // Author's live tables ride in a machine-readable comment block —
        // read them before the comments are stripped.
        var pendingTables = visualMetaTables(in: source)
        var namedTables: [LiquidDoc.Table] = []

        let stripped = expandingSimpleMacros(in: strippingComments(from: source))

        // Metadata from the preamble (and Author's in-document topmatter).
        // \title takes an optional short form in brackets first.
        let title = firstBalancedArgument(of: "title", in: stripped,
                                          skippingBracketOption: true)
            .map { inline(convert: $0.value).text }
            // A print line-break inside the title is one line here —
            // the title travels into citations and shelf rows.
            .map { $0.replacingOccurrences(of: "\n", with: " ") }
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? fallbackTitle
        let authors = balancedArguments(of: "author", in: stripped,
                                        skippingBracketOption: true)
            .map { inline(convert: $0).text }
            .filter { !$0.isEmpty }
        let author = authors.isEmpty ? nil : authors.joined(separator: ", ")

        // The venue: a journal's name, else the conference name from
        // \acmConference[HT '26]{37th ACM Conference on Hypertext}{…}{…},
        // else the full proceedings title. Comments are already
        // stripped, so a commented-out template line cannot mislead.
        let publication = ["acmJournal", "acmConference", "acmBooktitle"].lazy
            .compactMap { command in
                firstBalancedArgument(of: command, in: stripped,
                                      skippingBracketOption: true)
                    .map { inline(convert: $0.value).text }
            }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }

        // The paper's own DOI, from the preamble.
        let doi = firstBalancedArgument(of: "acmDOI", in: stripped)
            .map { $0.value.trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.contains("/") ? $0 : nil }

        // The words live between \begin{document} and \end{document};
        // a fragment with neither reads whole.
        var body = stripped
        if let begin = body.range(of: "\\begin{document}") {
            body = String(body[begin.upperBound...])
        }
        if let end = body.range(of: "\\end{document}") {
            body = String(body[..<end.lowerBound])
        }

        // LaTeX's printed numbers, recovered before the scan: headings
        // gain them, and \ref/\autoref/\cref become the words the PDF
        // prints — "3.2", "Figure 4", "Appendix A".
        body = resolvingCrossReferences(in: body)

        var paragraphs: [LiquidDoc.Paragraph] = []
        var assets: [LiquidDoc.Asset] = []
        var notes: [(id: String, text: String)] = []
        var ordinal = 0
        var assetOrdinal = 0
        var tableOrdinal = 0
        var noteOrdinal = 0

        func nextID() -> String {
            ordinal += 1
            return "p\(ordinal)"
        }
        func appendText(_ raw: String) {
            let converted = inline(convert: raw, noteCounter: &noteOrdinal)
            for (id, note) in converted.notes { notes.append((id, note)) }
            let text = converted.text
            guard !text.isEmpty else { return }
            paragraphs.append(LiquidDoc.Paragraph(id: nextID(), heading: nil, text: text))
        }
        func appendHeading(_ raw: String, level: Int) {
            let text = inline(convert: raw).text
            guard !text.isEmpty else { return }
            paragraphs.append(LiquidDoc.Paragraph(id: nextID(), heading: level, text: text))
        }
        func appendFigure(body figureBody: String) {
            // \includegraphics[options]{path} + \caption{...}
            guard let path = balancedArguments(
                of: "includegraphics", in: figureBody, skippingBracketOption: true).first
            else {
                // A figure with no image: keep its caption as words.
                if let caption = balancedArguments(of: "caption", in: figureBody).first {
                    appendText(caption)
                }
                return
            }
            // The caption becomes the marker's alt text: cite tokens and
            // brackets give way to plain words, so the `![alt](asset:id)`
            // form stays parseable everywhere.
            let caption = balancedArguments(of: "caption", in: figureBody).first
                .map { inline(convert: $0).text }
                .map { text in
                    text.replacingOccurrences(of: #"\[cite:[^\]]+\]"#, with: "",
                                              options: .regularExpression)
                        .replacingOccurrences(of: "[", with: "(")
                        .replacingOccurrences(of: "]", with: ")")
                        .replacingOccurrences(of: #"\s+"#, with: " ",
                                              options: .regularExpression)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                } ?? ""
            // An extensionless \includegraphics resolves by probing; the
            // extension that answered names the asset, so bytes, file
            // name, and media type always agree.
            var resolved = resources(path)
            var resolvedName = (path as NSString).lastPathComponent
            if resolved == nil {
                for probe in ["jpg", "jpeg", "png", "pdf", "tiff",
                              "JPG", "JPEG", "PNG", "PDF"] {
                    if let data = resources(path + "." + probe) {
                        resolved = data
                        resolvedName += "." + probe
                        break
                    }
                }
            }
            // A PDF figure becomes pixels: WebKit would show it, the
            // native readers would not.
            if let data = resolved,
               resolvedName.lowercased().hasSuffix(".pdf")
                || data.starts(with: Array("%PDF".utf8)) {
                if let png = rasterizedPDF(data) {
                    resolved = png
                    resolvedName = ((resolvedName as NSString)
                        .deletingPathExtension) + ".png"
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
                // The archive does not carry the file (ht26-2 ships
                // without seven of its images): the caption stands,
                // with a quiet note where the picture would be.
                let words = caption.isEmpty
                    ? "(A figure the source archive does not include.)"
                    : caption + " (The source archive does not include this figure's image.)"
                paragraphs.append(LiquidDoc.Paragraph(
                    id: paragraphID, heading: nil, text: words))
            }
        }
        func appendTable(body tableBody: String) {
            // Author's VISUALMETA block carries the same tables live
            // (values + formulas), in order — those win over re-parsing
            // the printed tabular.
            tableOrdinal += 1
            let table: LiquidDoc.Table
            if !pendingTables.isEmpty {
                table = pendingTables.removeFirst()
            } else if let inner = environmentBody(named: "tabular", in: tableBody)
                        ?? environmentBody(named: "tabularx", in: tableBody) {
                let rows = tabularRows(inner)
                guard !rows.isEmpty else { return }
                let columns = rows.map(\.count).max() ?? 0
                table = LiquidDoc.Table(
                    identifier: "tex-table-\(tableOrdinal)",
                    rowCount: rows.count, columnCount: columns,
                    cells: rows.map { row in
                        (0..<columns).map {
                            LiquidDoc.Table.Cell(value: $0 < row.count ? row[$0] : "")
                        }
                    })
            } else {
                if let caption = balancedArguments(of: "caption", in: tableBody).first {
                    appendText(caption)
                }
                return
            }
            namedTables.append(table)
            var paragraph = LiquidDoc.Paragraph(
                id: nextID(), heading: nil,
                text: table.cells.map { row in
                    "| " + row.map(\.value).joined(separator: " | ") + " |"
                }.joined(separator: "\n"))
            paragraph.tableID = table.identifier
            paragraphs.append(paragraph)
            if let caption = balancedArguments(of: "caption", in: tableBody).first {
                appendText(caption)
            }
        }
        func appendList(body listBody: String, numbered: Bool) {
            var number = 0
            for item in listItems(listBody) {
                // A nested list inside the item flattens under it.
                var rest = item
                var nested: [String] = []
                for env in ["itemize", "enumerate"] {
                    while let range = environmentRange(named: env, in: rest) {
                        nested.append(String(rest[range.body]))
                        rest.removeSubrange(range.whole)
                    }
                }
                number += 1
                let marker = numbered ? "\(number). " : "\u{2022} "
                let converted = inline(convert: rest, noteCounter: &noteOrdinal)
                for (id, note) in converted.notes { notes.append((id, note)) }
                if !converted.text.isEmpty {
                    paragraphs.append(LiquidDoc.Paragraph(
                        id: nextID(), heading: nil, text: marker + converted.text))
                }
                for inner in nested {
                    appendList(body: inner, numbered: false)
                }
            }
        }

        // The environments the scanner knows; anything else unwraps and
        // its content reads on.
        let sectioning: [(command: String, level: Int)] = [
            ("chapter", 1), ("section", 1), ("subsection", 2),
            ("subsubsection", 3), ("paragraph", 3),
        ]

        func scan(_ text: String) {
            var rest = text[...]
            var plain = ""
            func flushPlain() {
                for run in plain.components(separatedBy: "\n\n") {
                    let trimmed = run.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { appendText(trimmed) }
                }
                plain = ""
            }
            while let backslash = rest.firstIndex(of: "\\") {
                plain += rest[..<backslash]
                rest = rest[backslash...]

                // \begin{env}: the block environments the scanner handles.
                if rest.hasPrefix("\\begin{"),
                   let name = environmentName(at: rest),
                   let range = environmentRange(named: name, in: String(rest)) {
                    let handled: Bool
                    switch name {
                    case "abstract":
                        flushPlain()
                        appendHeading("Abstract", level: 1)
                        scan(String(rest[range.bodySub(rest)]))
                        handled = true
                    case "acks":
                        // acmart's acknowledgments: the PDF prints the
                        // heading; the words follow.
                        flushPlain()
                        appendHeading("Acknowledgments", level: 1)
                        scan(String(rest[range.bodySub(rest)]))
                        handled = true
                    case "figure", "figure*":
                        flushPlain()
                        appendFigure(body: String(rest[range.bodySub(rest)]))
                        handled = true
                    case "table", "table*", "tabular", "tabularx":
                        flushPlain()
                        appendTable(body: name.hasPrefix("tab")
                                    ? String(rest[range.wholeSub(rest)])
                                    : String(rest[range.bodySub(rest)]))
                        handled = true
                    case "itemize", "enumerate":
                        flushPlain()
                        appendList(body: String(rest[range.bodySub(rest)]),
                                   numbered: name == "enumerate")
                        handled = true
                    case "quote", "quotation", "center":
                        flushPlain()
                        scan(String(rest[range.bodySub(rest)]))
                        handled = true
                    case "verbatim", "lstlisting", "minted":
                        flushPlain()
                        var code = String(rest[range.bodySub(rest)])
                        var caption: String?
                        // lstlisting/minted options sit inside the
                        // environment body ([style=…, caption={…}]) —
                        // chrome, not code. The caption's words stay,
                        // following the listing like a figure's. Only a
                        // bracket adjacent to \begin{…} counts: code
                        // itself may open with [ on a later line.
                        if name != "verbatim" {
                            let spaces = code.prefix(while: { $0 == " " })
                            if code.dropFirst(spaces.count).first == "[" {
                                var depth = 0
                                var index = code.index(code.startIndex, offsetBy: spaces.count)
                                var optionsEnd: String.Index?
                                while index < code.endIndex {
                                    let character = code[index]
                                    if character == "{" { depth += 1 }
                                    if character == "}" { depth -= 1 }
                                    if character == "]", depth == 0 { optionsEnd = index; break }
                                    index = code.index(after: index)
                                }
                                if let optionsEnd {
                                    let options = String(code[..<optionsEnd])
                                    if let found = options.range(of: "caption=") {
                                        let offset = options.distance(from: options.startIndex,
                                                                      to: found.upperBound)
                                        caption = balancedArgument(in: options,
                                                                   afterPrefixLength: offset)?.value
                                    }
                                    code = String(code[code.index(after: optionsEnd)...])
                                }
                            }
                        }
                        let cleanCode = code.trimmingCharacters(in: .newlines)
                        if !cleanCode.isEmpty {
                            paragraphs.append(LiquidDoc.Paragraph(
                                id: nextID(), heading: nil, text: cleanCode))
                        }
                        if let caption { appendText(caption) }
                        handled = true
                    case "equation", "equation*", "align", "align*",
                         "displaymath", "math", "eqnarray":
                        flushPlain()
                        // \label is LaTeX plumbing, not mathematics.
                        let math = String(rest[range.bodySub(rest)])
                            .replacingOccurrences(of: #"\\label\{[^}]*\}"#,
                                                  with: "", options: .regularExpression)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if !math.isEmpty {
                            paragraphs.append(LiquidDoc.Paragraph(
                                id: nextID(), heading: nil, text: math))
                        }
                        handled = true
                    case "CCSXML", "thebibliography", "titlepage":
                        // Metadata and the printed bibliography: the .bib
                        // is the real record.
                        flushPlain()
                        handled = true
                    default:
                        // An unknown environment: drop its markers, keep
                        // its words in the flow.
                        plain += " "
                        let bodyText = String(rest[range.bodySub(rest)])
                        rest = (bodyText + String(rest[range.wholeSub(rest).upperBound...]))[...]
                        continue
                    }
                    if handled {
                        rest = rest[range.wholeSub(rest).upperBound...]
                        continue
                    }
                }

                // Sectioning commands split the flow.
                var sectioned = false
                for (command, level) in sectioning {
                    for form in ["\\\(command)*{", "\\\(command){"] {
                        if rest.hasPrefix(form),
                           let argument = balancedArgument(
                                in: String(rest), afterPrefixLength: form.count - 1) {
                            flushPlain()
                            appendHeading(argument.value, level: level)
                            rest = rest[rest.index(rest.startIndex,
                                                   offsetBy: argument.consumed)...]
                            sectioned = true
                            break
                        }
                    }
                    if sectioned { break }
                }
                if sectioned { continue }

                // Display math \[ ... \]
                if rest.hasPrefix("\\["), let close = rest.range(of: "\\]") {
                    flushPlain()
                    let math = String(rest[rest.index(rest.startIndex, offsetBy: 2)..<close.lowerBound])
                        .replacingOccurrences(of: #"\\label\{[^}]*\}"#,
                                              with: "", options: .regularExpression)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !math.isEmpty {
                        paragraphs.append(LiquidDoc.Paragraph(
                            id: nextID(), heading: nil, text: math))
                    }
                    rest = rest[close.upperBound...]
                    continue
                }

                // A lone figure outside a figure environment.
                if rest.hasPrefix("\\includegraphics"),
                   let range = commandRange(of: "includegraphics", at: rest) {
                    flushPlain()
                    appendFigure(body: String(rest[..<range.upperBound]))
                    rest = rest[range.upperBound...]
                    continue
                }

                // Commands the flow is better off without, arguments and
                // all — including every braced group that trails the
                // first (\acmConference[X]{a}{b}{c}). The metadata already
                // read from the preamble (\title, \author) drops here too:
                // Author writes it inside the document, before \maketitle.
                var dropped = false
                for command in ["maketitle", "tableofcontents", "newpage", "clearpage",
                                "bibliographystyle", "bibliography", "label", "vspace",
                                "hspace", "centering", "noindent", "settopmatter",
                                "keywords", "ccsdesc", "acmConference", "acmYear",
                                "acmDOI", "acmISBN", "copyrightyear", "setcopyright",
                                "orcid", "affiliation", "email", "institution",
                                "city", "country", "printbibliography", "pagebreak",
                                "date", "thanks", "title", "author",
                                "renewcommand", "newcommand", "providecommand",
                                "authornote", "authornotemark", "graphicspath",
                                "Description", "teaserfigure"] {
                    for form in ["\\\(command){", "\\\(command)[", "\\\(command)"] {
                        guard rest.hasPrefix(form) else { continue }
                        // The bare form must not eat a longer command's name.
                        if form == "\\\(command)" {
                            let nextIndex = rest.index(rest.startIndex, offsetBy: form.count)
                            if nextIndex < rest.endIndex, rest[nextIndex].isLetter { continue }
                            rest = rest[nextIndex...]
                        } else if let argument = balancedArgument(
                            in: String(rest), afterPrefixLength: form.count - 1,
                            opener: form.hasSuffix("[") ? "[" : "{",
                            closer: form.hasSuffix("[") ? "]" : "}") {
                            var consumed = argument.consumed
                            // Trailing braced groups on the same line
                            // belong to the same command
                            // (\acmConference[X]{a}{b}{c}) — a group
                            // after a line break is new content.
                            while true {
                                let after = rest.dropFirst(consumed)
                                let spaces = after.prefix { $0 == " " || $0 == "\t" }
                                guard after.dropFirst(spaces.count).first == "{",
                                      let brace = balancedArgument(
                                          in: String(after), afterPrefixLength: 0)
                                else { break }
                                consumed += brace.consumed
                            }
                            rest = rest[rest.index(rest.startIndex, offsetBy: consumed)...]
                        } else {
                            rest = rest[rest.index(rest.startIndex, offsetBy: form.count)...]
                        }
                        dropped = true
                        break
                    }
                    if dropped { break }
                }
                if dropped { continue }

                // Anything else is inline: keep the backslash for the
                // inline converter and move on.
                plain += "\\"
                rest = rest.dropFirst()
            }
            plain += rest
            flushPlain()
        }

        scan(body)

        // Footnotes read as endnotes: daggers in the flow, the notes
        // under their own heading, each on its token's id.
        if !notes.isEmpty {
            paragraphs.append(LiquidDoc.Paragraph(id: nextID(), heading: 1, text: "Notes"))
            for (id, note) in notes {
                paragraphs.append(LiquidDoc.Paragraph(id: id, heading: nil, text: note))
            }
        }

        // The bibliography: only the works the text cites make the
        // record — a source archive often carries whole personal .bib
        // libraries beside the paper's own (ht26-17 ships 399 entries;
        // the paper cites 31). A document with no cite tokens at all
        // keeps every entry: there is nothing to filter by.
        // A .bib often opens with % comment lines (five of the HT '26
        // packages do), which BibTeXParser's paste guard reads as
        // not-BibTeX; a BOM defeats it the same way (ht26-14). Whole
        // comment lines drop; inline % stays — it is literal inside
        // entries (URLs carry %20).
        let commentFree = bibliography.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("%") }
            .joined(separator: "\n")
        // …and the parse starts at the first entry: a BOM (ht26-14) or a
        // decorative "===== Section =====" banner (ht26-60) before it
        // defeats the guard the same way. The parser itself skips junk
        // between entries; only the start is strict.
        let bibSource = commentFree.range(of: "@")
            .map { String(commentFree[$0.lowerBound...]) } ?? ""
        let entries = BibTeXParser.parse(bibSource)

        // BibTeX matches keys case-insensitively — \cite{docling} finds
        // @techreport{Docling}. The format's [cite:] tokens are exact,
        // so body tokens take the bib's canonical casing. A second,
        // punctuation-blind index catches a body and bibliography that
        // drifted apart in the separators alone — ht26-54 cites
        // ca-nurnberg-99 while its .bib says ca-nurnberg+99.
        let canonicalKey = Dictionary(entries.map { ($0.key.lowercased(), $0.key) },
                                      uniquingKeysWith: { first, _ in first })
        func folded(_ key: String) -> String {
            key.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        let foldedKey = Dictionary(entries.map { (folded($0.key), $0.key) },
                                   uniquingKeysWith: { first, _ in first })
        for index in paragraphs.indices {
            let paragraph = paragraphs[index]
            guard paragraph.text.contains("[cite:") else { continue }
            var text = paragraph.text
            for key in captures(in: text, pattern: #"\[cite:([^\]]+)\]"#) {
                let proper = canonicalKey[key.lowercased()] ?? foldedKey[folded(key)]
                if let proper, proper != key {
                    text = text.replacingOccurrences(of: "[cite:\(key)]",
                                                     with: "[cite:\(proper)]")
                }
            }
            if text != paragraph.text {
                var replacement = LiquidDoc.Paragraph(
                    id: paragraph.id, heading: paragraph.heading, text: text)
                replacement.speaker = paragraph.speaker
                replacement.tableID = paragraph.tableID
                replacement.stretchID = paragraph.stretchID
                replacement.provenance = paragraph.provenance
                paragraphs[index] = replacement
            }
        }

        let citedKeys = Set(paragraphs.flatMap {
            captures(in: $0.text, pattern: #"\[cite:([^\]]+)\]"#)
        })
        let references = entries
            .filter { citedKeys.isEmpty || citedKeys.contains($0.key) }
            .map { LiquidDoc.Reference(id: $0.key, bibtex: $0.raw) }

        return Result(title: title, author: author, publication: publication,
                      body: paragraphs, references: references,
                      tables: namedTables, assets: assets, doi: doi)
    }

    // MARK: - Cross-references

    /// LaTeX's printed numbers, recovered: sections, figures, tables
    /// and equations counted in document order (`\appendix` switching
    /// sections to letters), every `\label` bound to the number it
    /// stands beside, and every `\ref`/`\autoref`/`\cref`/`\Cref`
    /// replaced by the words the PDF prints. Section headings gain
    /// their numbers too, so the words a reference names are the words
    /// the outline shows. A label nothing defines renders as "?", as
    /// LaTeX itself would.
    private static func resolvingCrossReferences(in body: String) -> String {
        struct Target { let phrase: String; let number: String }
        var targets: [String: Target] = [:]
        var edits: [(range: Range<String.Index>, replacement: String)] = []

        let eventPattern = #"\\(section|subsection|subsubsection)(\*)?\s*(?=[\[{])|\\begin\{(figure\*?|teaserfigure|table\*?|equation|align|eqnarray|gather|lstlisting|minted)\}|\\appendix\b|\\label\{([^}]*)\}"#
        guard let events = try? NSRegularExpression(pattern: eventPattern) else { return body }
        let ns = body as NSString
        var c1 = 0, c2 = 0, c3 = 0
        var appendixMode = false
        var figureCount = 0, tableCount = 0, equationCount = 0, listingCount = 0
        struct EnvSpan { let range: NSRange; let phrase: String; let number: String }
        var envSpans: [EnvSpan] = []
        var currentSection: Target?

        func sectionNumber() -> String {
            let first = appendixMode
                ? String(UnicodeScalar(64 + min(max(c1, 1), 26))!)
                : String(c1)
            // LaTeX keeps the zero: a \subsubsection straight under a
            // \section prints as 6.0.1, never 6.1.
            var parts = [first]
            if c3 > 0 { parts.append(String(c2)); parts.append(String(c3)) }
            else if c2 > 0 { parts.append(String(c2)) }
            return parts.joined(separator: ".")
        }

        let wholeRange = NSRange(location: 0, length: ns.length)
        for match in events.matches(in: body, range: wholeRange) {
            if match.range(at: 1).location != NSNotFound {
                let command = ns.substring(with: match.range(at: 1))
                let starred = match.range(at: 2).location != NSNotFound
                if starred {
                    // Unnumbered: labels beside it have nothing to print.
                    currentSection = nil
                    continue
                }
                switch command {
                case "section": c1 += 1; c2 = 0; c3 = 0
                case "subsection": c2 += 1; c3 = 0
                default: c3 += 1
                }
                let number = sectionNumber()
                currentSection = Target(
                    phrase: appendixMode ? "Appendix \(number)" : "Section \(number)",
                    number: number)
                // The heading's printed number, inserted into its title
                // argument. The brace may follow an optional [short].
                var probe = match.range.upperBound
                if probe < ns.length, ns.character(at: probe) == UInt16(UnicodeScalar("[").value) {
                    let close = ns.range(of: "]", options: [],
                                         range: NSRange(location: probe,
                                                        length: ns.length - probe))
                    if close.location != NSNotFound { probe = close.upperBound }
                }
                let braceSearch = NSRange(location: probe,
                                          length: min(4, ns.length - probe))
                let brace = ns.range(of: "{", options: [], range: braceSearch)
                if brace.location != NSNotFound,
                   let insertAt = Range(NSRange(location: brace.location + 1, length: 0),
                                        in: body) {
                    edits.append((insertAt, "\(number) "))
                }
            } else if match.range(at: 3).location != NSNotFound {
                let env = ns.substring(with: match.range(at: 3))
                let phrase: String
                let number: String
                if env.hasPrefix("fig") || env == "teaserfigure" {
                    figureCount += 1; number = String(figureCount); phrase = "Figure \(number)"
                } else if env.hasPrefix("table") {
                    tableCount += 1; number = String(tableCount); phrase = "Table \(number)"
                } else if env == "lstlisting" || env == "minted" {
                    listingCount += 1; number = String(listingCount); phrase = "Listing \(number)"
                } else {
                    equationCount += 1; number = String(equationCount); phrase = "Equation \(number)"
                }
                guard let start = Range(match.range, in: body) else { continue }
                let tail = String(body[start.lowerBound...])
                if let range = environmentRange(named: env, in: tail) {
                    let whole = NSRange(range.whole, in: tail)
                    envSpans.append(EnvSpan(
                        range: NSRange(location: match.range.location,
                                       length: whole.location + whole.length),
                        phrase: phrase, number: number))
                }
                // Listings name their label in the options, not with
                // \label: [caption=…, label={lst:hidden}].
                if env == "lstlisting" || env == "minted" {
                    let optionSearch = NSRange(
                        location: match.range.upperBound,
                        length: min(400, ns.length - match.range.upperBound))
                    if let optionMatch = try? NSRegularExpression(
                        pattern: #"^\s*\[[^\]]*label\s*=\s*\{?([^,\]\}]+)"#)
                        .firstMatch(in: body, range: optionSearch),
                       optionMatch.range(at: 1).location != NSNotFound {
                        let key = ns.substring(with: optionMatch.range(at: 1))
                            .trimmingCharacters(in: .whitespaces)
                        if targets[key] == nil {
                            targets[key] = Target(phrase: phrase, number: number)
                        }
                    }
                }
            } else if match.range(at: 4).location != NSNotFound {
                let key = ns.substring(with: match.range(at: 4))
                    .trimmingCharacters(in: .whitespaces)
                guard targets[key] == nil else { continue }
                let offset = match.range.location
                if let enclosing = envSpans.last(where: { NSLocationInRange(offset, $0.range) }) {
                    targets[key] = Target(phrase: enclosing.phrase, number: enclosing.number)
                } else if let currentSection {
                    targets[key] = currentSection
                }
            } else {
                // \appendix: sections restart as letters.
                appendixMode = true
                c1 = 0; c2 = 0; c3 = 0
            }
        }

        // Pass 2: the references become printed words.
        guard let refs = try? NSRegularExpression(
            pattern: #"\\(autoref|cref|Cref|ref|pageref)\{([^}]*)\}"#) else { return body }
        for match in refs.matches(in: body, range: wholeRange) {
            let kind = ns.substring(with: match.range(at: 1))
            let keys = ns.substring(with: match.range(at: 2))
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let words = keys.map { key -> String in
                guard let target = targets[key] else { return "?" }
                switch kind {
                case "ref", "pageref": return target.number
                case "cref":
                    return target.phrase.prefix(1).lowercased() + target.phrase.dropFirst()
                default: return target.phrase
                }
            }.joined(separator: " and ")
            if let range = Range(match.range, in: body) {
                edits.append((range, words))
            }
        }

        var text = body
        for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            text.replaceSubrange(edit.range, with: edit.replacement)
        }
        return text
    }

    /// A PDF figure rasterised to PNG: WebKit shows a one-page PDF in
    /// an `<img>`, but the native readers — and the phone — cannot, so
    /// the EPUB carries pixels. Twice the media box, white-backed.
    private static func rasterizedPDF(_ data: Data) -> Data? {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider),
              let page = document.page(at: 1) else { return nil }
        let box = page.getBoxRect(.mediaBox)
        guard box.width > 1, box.height > 1 else { return nil }
        let scale = min(2, 2200 / max(box.width, box.height))
        let width = Int(box.width * scale)
        let height = Int(box.height * scale)
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -box.minX, y: -box.minY)
        context.drawPDFPage(page)
        guard let image = context.makeImage() else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            out, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }

    // MARK: - Inline conversion

    /// One paragraph's LaTeX as the format's plain-text conventions:
    /// emphasis to markdown, `\cite` to `[cite:key]`, `\footnote` to a
    /// `[note:id]` dagger (the note returned alongside), links restored,
    /// escapes and accents resolved, leftover commands unwrapped, inline
    /// math kept verbatim.
    static func inline(convert raw: String) -> (text: String, notes: [(String, String)]) {
        var counter = 0
        return inline(convert: raw, noteCounter: &counter)
    }

    /// The counter threads through every call converting one document's
    /// body, so note ids stay unique across paragraphs — `fn1` twice
    /// would give two endnotes the same address.
    static func inline(convert raw: String,
                       noteCounter: inout Int) -> (text: String, notes: [(String, String)]) {
        var text = raw
        var notes: [(String, String)] = []

        // TeX's other inline form, \( … \), normalises to $ … $ first.
        while let range = text.range(of: #"\\\((.+?)\\\)"#, options: .regularExpression) {
            let inner = String(text[range]).dropFirst(2).dropLast(2)
            text.replaceSubrange(range, with: "$\(inner)$")
        }

        // Inline math is TeX's own and stays verbatim — shield it.
        var mathSpans: [String] = []
        while let range = text.range(of: #"\$[^$\n]+\$"#, options: .regularExpression) {
            mathSpans.append(String(text[range]))
            text.replaceSubrange(range, with: "\u{FFFC}MATH\(mathSpans.count - 1)\u{FFFC}")
        }

        // \texorpdfstring{tex}{plain}: the second argument is the
        // plain-text form — exactly what a plain-text document wants.
        // Before the escapes pass: the tex argument may hold \\, which
        // the escapes would otherwise split mid-group.
        while let tex = firstBalancedArgument(of: "texorpdfstring", in: text) {
            var replacement = ""
            var end = tex.range.upperBound
            let after = String(text[tex.range.upperBound...])
            if let plain = balancedArgument(in: after, afterPrefixLength: 0) {
                replacement = plain.value
                end = text.index(tex.range.upperBound, offsetBy: plain.consumed)
            }
            text.replaceSubrange(tex.range.lowerBound..<end, with: replacement)
        }

        // Escaped specials become placeholders so the generic cleanup
        // never mistakes them for syntax.
        let escapes: [(String, String)] = [
            ("\\textbackslash{}", "\u{FFFC}BS\u{FFFC}"), ("\\textbackslash", "\u{FFFC}BS\u{FFFC}"),
            ("\\{", "\u{FFFC}LB\u{FFFC}"), ("\\}", "\u{FFFC}RB\u{FFFC}"),
            ("\\%", "%"), ("\\&", "&"), ("\\#", "#"), ("\\$", "$"), ("\\_", "_"),
            ("\\textasciitilde{}", "~\u{FFFC}T\u{FFFC}"), ("\\textasciicircum{}", "^"),
            ("\\textless{}", "<"), ("\\textgreater{}", ">"), ("\\textbar{}", "|"),
            ("\\ldots{}", "\u{2026}"), ("\\ldots", "\u{2026}"), ("\\dots", "\u{2026}"),
            ("\\LaTeX{}", "LaTeX"), ("\\LaTeX", "LaTeX"), ("\\TeX{}", "TeX"),
            ("\\ ", " "), ("\\,", " "), ("\\\\", "\n"),
            ("\\-", ""),   // a discretionary hyphen marks nothing here
        ]
        for (from, to) in escapes {
            text = text.replacingOccurrences(of: from, with: to)
        }

        // An environment opened mid-sentence (a CJK span, say): its
        // markers and font arguments are chrome; the words between
        // them stay in the flow.
        text = text.replacingOccurrences(
            of: #"\\begin\{[^}]*\}(\{[^}]*\})*"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(
            of: #"\\end\{[^}]*\}"#, with: "", options: .regularExpression)

        // Footnotes out first — their words go to the endnotes, a
        // dagger token stays.
        while let argument = firstBalancedArgument(of: "footnote", in: text) {
            noteCounter += 1
            let id = "fn\(noteCounter)"
            let note = inline(convert: argument.value, noteCounter: &noteCounter)
            notes.append((id, note.text))
            notes.append(contentsOf: note.notes)
            text.replaceSubrange(argument.range, with: "[note:\(id)]")
        }

        // Citations: every key its own [cite:key] token, Author's own
        // convention on the way back in.
        for command in ["cite", "citep", "citet", "parencite", "autocite", "textcite"] {
            while let argument = firstBalancedArgument(of: command, in: text,
                                                       skippingBracketOption: true) {
                let tokens = argument.value.split(separator: ",")
                    .map { "[cite:\($0.trimmingCharacters(in: .whitespacesAndNewlines))]" }
                    .joined()
                text.replaceSubrange(argument.range, with: tokens)
            }
        }

        // A label is an address, never words — inside a heading's own
        // braces the scanner cannot strip it, so it goes here.
        text = text.replacingOccurrences(of: #"\\label\{[^}]*\}"#, with: "",
                                         options: .regularExpression)

        // In-document hyperlink plumbing: \hypertarget{key}{} drops
        // whole; \hyperlink{key}{words} keeps its words.
        while let target = firstBalancedArgument(of: "hypertarget", in: text) {
            var end = target.range.upperBound
            let after = String(text[target.range.upperBound...])
            if let words = balancedArgument(in: after, afterPrefixLength: 0) {
                end = text.index(target.range.upperBound, offsetBy: words.consumed)
            }
            text.replaceSubrange(target.range.lowerBound..<end, with: "")
        }
        while let link = firstBalancedArgument(of: "hyperlink", in: text) {
            let after = String(text[link.range.upperBound...])
            if let words = balancedArgument(in: after, afterPrefixLength: 0) {
                let end = text.index(link.range.upperBound, offsetBy: words.consumed)
                text.replaceSubrange(link.range.lowerBound..<end, with: words.value)
            } else {
                text.replaceSubrange(link.range, with: "")
            }
        }

        // Links.
        while let href = firstBalancedArgument(of: "href", in: text) {
            let url = href.value
            let after = String(text[href.range.upperBound...])
            if let label = balancedArgument(in: after, afterPrefixLength: 0) {
                let display = inline(convert: label.value).text
                let end = text.index(href.range.upperBound, offsetBy: label.consumed)
                text.replaceSubrange(href.range.lowerBound..<end,
                                     with: display.isEmpty || display == url
                                         ? url : "[\(display)](\(url))")
            } else {
                text.replaceSubrange(href.range, with: url)
            }
        }
        while let url = firstBalancedArgument(of: "url", in: text) {
            text.replaceSubrange(url.range, with: url.value)
        }

        // Emphasis, innermost first through recursion.
        for (command, opener, closer) in [("textbf", "**", "**"), ("emph", "*", "*"),
                                          ("textit", "*", "*"), ("texttt", "`", "`"),
                                          ("textsc", "", ""), ("underline", "", "")] {
            while let argument = firstBalancedArgument(of: command, in: text) {
                let innerResult = inline(convert: argument.value,
                                         noteCounter: &noteCounter)
                notes.append(contentsOf: innerResult.notes)
                text.replaceSubrange(argument.range,
                                     with: opener + innerResult.text + closer)
            }
        }

        // Accents compose onto their letter: \'{e} and \'e alike for the
        // symbol marks; the letter marks (\c, \v) only in their braced
        // form — a bare \c would swallow \centering's opening letters.
        let symbolMarks: [Character: String] = [
            "'": "\u{0301}", "`": "\u{0300}", "^": "\u{0302}",
            "\"": "\u{0308}", "~": "\u{0303}", "=": "\u{0304}", ".": "\u{0307}",
        ]
        for (mark, accent) in symbolMarks {
            let pattern = "\\\\\(NSRegularExpression.escapedPattern(for: String(mark)))\\{?([a-zA-Z])\\}?"
            while let range = text.range(of: pattern, options: .regularExpression) {
                // The accented letter is the match's last LETTER — its
                // last character may be the closing brace of {\'e}.
                let letter = text[range].last { $0.isLetter }.map(String.init) ?? ""
                text.replaceSubrange(range,
                                     with: (letter + accent).precomposedStringWithCanonicalMapping)
            }
        }
        let letterMarks: [Character: String] = ["c": "\u{0327}", "v": "\u{030C}"]
        for (mark, accent) in letterMarks {
            let pattern = "\\\\\(mark)\\{([a-zA-Z])\\}"
            while let range = text.range(of: pattern, options: .regularExpression) {
                let letter = text[range].dropLast().last.map(String.init) ?? ""
                text.replaceSubrange(range,
                                     with: (letter + accent).precomposedStringWithCanonicalMapping)
            }
        }
        for (from, to) in [("\\ss{}", "\u{00DF}"), ("\\ss", "\u{00DF}"),
                           ("\\o{}", "\u{00F8}"), ("\\O{}", "\u{00D8}"),
                           ("\\ae{}", "\u{00E6}"), ("\\AE{}", "\u{00C6}"),
                           ("\\oe{}", "\u{0153}"), ("\\OE{}", "\u{0152}"),
                           ("\\aa{}", "\u{00E5}"), ("\\AA{}", "\u{00C5}"),
                           ("\\l{}", "\u{0142}"), ("\\L{}", "\u{0141}")] {
            text = text.replacingOccurrences(of: from, with: to)
        }

        // Whatever command remains unwraps to its argument (twice, for
        // nesting), then bare commands drop.
        for _ in 0..<2 {
            while let range = text.range(of: #"\\[a-zA-Z]+\*?\{"#, options: .regularExpression) {
                let prefixLength = text.distance(from: text.startIndex, to: range.upperBound) - 1
                guard let argument = balancedArgument(in: text, afterPrefixLength: prefixLength)
                else { break }
                let end = text.index(text.startIndex, offsetBy: argument.consumed)
                text.replaceSubrange(range.lowerBound..<end, with: argument.value)
            }
        }
        text = text.replacingOccurrences(of: #"\\[a-zA-Z]+\*?(\[[^\]]*\])?"#,
                                         with: "", options: .regularExpression)

        // TeX's typography back to the words: quotes, dashes, ties.
        text = text.replacingOccurrences(of: "``", with: "\u{201C}")
            .replacingOccurrences(of: "''", with: "\u{201D}")
            .replacingOccurrences(of: "---", with: "\u{2014}")
            .replacingOccurrences(of: "--", with: "\u{2013}")
            .replacingOccurrences(of: "`", with: "\u{2018}")
            .replacingOccurrences(of: "~\u{FFFC}T\u{FFFC}", with: "~")
            .replacingOccurrences(of: "~", with: "\u{00A0}")

        // Stray braces (Author's braced capitals in titles) vanish.
        text = text.replacingOccurrences(of: "{", with: "")
            .replacingOccurrences(of: "}", with: "")

        // The shielded pieces return.
        for (index, span) in mathSpans.enumerated() {
            text = text.replacingOccurrences(of: "\u{FFFC}MATH\(index)\u{FFFC}", with: span)
        }
        text = text.replacingOccurrences(of: "\u{FFFC}BS\u{FFFC}", with: "\\")
            .replacingOccurrences(of: "\u{FFFC}LB\u{FFFC}", with: "{")
            .replacingOccurrences(of: "\u{FFFC}RB\u{FFFC}", with: "}")

        // One paragraph, one line (the \\ newlines stay as breaks).
        let lines = text.components(separatedBy: "\n").map { line in
            line.components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }.joined(separator: " ")
        }
        text = lines.filter { !$0.isEmpty }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (text, notes)
    }

    // MARK: - LaTeX plumbing

    /// The source with its `\input{...}` and `\include{...}` pulled
    /// inline — up to a few levels, so cycles cannot spin.
    private static func inlinedInputs(_ source: String,
                                      read: (String) -> String?) -> String {
        var text = source
        for _ in 0..<4 {
            var replaced = false
            for command in ["input", "include"] {
                while let argument = firstBalancedArgument(of: command, in: text) {
                    let inserted = read(argument.value.trimmingCharacters(in: .whitespaces)) ?? ""
                    text.replaceSubrange(argument.range, with: "\n" + inserted + "\n")
                    replaced = true
                }
            }
            if !replaced { break }
        }
        return text
    }

    /// Expands no-argument macros — `\newcommand{\ts}{TrainShield\xspace}`
    /// makes `\title{\ts: Targeted Awareness…}` readable (ht26-38); the
    /// unknown-command cleanup would otherwise drop the name and leave
    /// ": Targeted Awareness…". Macros with parameters ([1]) are left
    /// alone. Substitution runs twice so a macro used inside another
    /// macro's value still resolves; a self-referential value is skipped.
    private static func expandingSimpleMacros(in source: String) -> String {
        var definitions: [(name: String, value: String)] = []
        // Macros WITH parameters expand too, by substitution — ht26-8's
        // \secLink{sec:x}{words} becomes \hyperref[sec:x]{words}, which
        // the link handling then reads properly.
        var parameterized: [(name: String, count: Int, body: String)] = []
        let patterns = [
            #"\\(?:newcommand|renewcommand|providecommand)\s*\{?\\([a-zA-Z]+)\}?\s*(\[[0-9]+\])?\s*\{"#,
            #"\\def\s*\\([a-zA-Z]+)\s*()\{"#,
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = source as NSString
            for match in expression.matches(in: source,
                                            range: NSRange(location: 0, length: ns.length)) {
                guard let whole = Range(match.range, in: source),
                      let nameRange = Range(match.range(at: 1), in: source) else { continue }
                let name = String(source[nameRange])
                let bracePosition = source.distance(from: source.startIndex, to: whole.upperBound) - 1
                guard let argument = balancedArgument(in: source, afterPrefixLength: bracePosition),
                      !argument.value.contains("\\\(name)")
                else { continue }
                if match.range(at: 2).location != NSNotFound, match.range(at: 2).length > 0 {
                    let digits = ns.substring(with: match.range(at: 2))
                        .filter(\.isNumber)
                    if let count = Int(digits), (1...3).contains(count),
                       !argument.value.contains("#\(count + 1)") {
                        parameterized.append((name, count, argument.value))
                    }
                    continue
                }
                definitions.append((name, argument.value))
            }
        }
        guard !definitions.isEmpty || !parameterized.isEmpty else { return source }
        var text = source
        for _ in 0..<2 {
            for (name, value) in definitions {
                let cleaned = value.replacingOccurrences(of: "\\xspace", with: "")
                text = text.replacingOccurrences(
                    of: "\\\\\(name)(?![a-zA-Z])",
                    with: NSRegularExpression.escapedTemplate(for: cleaned),
                    options: .regularExpression)
            }
        }
        for (name, count, body) in parameterized {
            // A plain scan, not firstBalancedArgument: the macro's own
            // definition site (\providecommand{\secLink}…) is a match
            // without arguments and must be stepped over, not stop the
            // search.
            var cursor = text.startIndex
            var guarded = 0
            while guarded < 400,
                  let hit = text.range(of: "\\\(name)",
                                       range: cursor..<text.endIndex) {
                guarded += 1
                guard hit.upperBound < text.endIndex,
                      text[hit.upperBound] == "{" else {
                    cursor = hit.upperBound
                    continue
                }
                var arguments: [String] = []
                var end = hit.upperBound
                var complete = true
                for _ in 0..<count {
                    let after = String(text[end...])
                    guard after.first == "{",
                          let next = balancedArgument(in: after, afterPrefixLength: 0)
                    else { complete = false; break }
                    arguments.append(next.value)
                    end = text.index(end, offsetBy: next.consumed)
                }
                guard complete else { cursor = hit.upperBound; continue }
                var expanded = body.replacingOccurrences(of: "\\xspace", with: "")
                for (position, value) in arguments.enumerated() {
                    expanded = expanded.replacingOccurrences(of: "#\(position + 1)",
                                                             with: value)
                }
                guard !expanded.contains("\\\(name)") else { cursor = hit.upperBound; continue }
                text.replaceSubrange(hit.lowerBound..<end, with: expanded)
                cursor = text.startIndex
            }
        }
        return text
    }

    /// Comment stripping: an unescaped `%` silences its line's rest.
    private static func strippingComments(from source: String) -> String {
        source.components(separatedBy: "\n").map { line -> String in
            var previous: Character = " "
            for (offset, character) in line.enumerated() {
                if character == "%", previous != "\\" {
                    return String(line.prefix(offset))
                }
                previous = character
            }
            return line
        }.joined(separator: "\n")
    }

    /// Author's live tables, read from the VISUALMETA:TABLES comment
    /// block: values and formulas both, in document order.
    private static func visualMetaTables(in source: String) -> [LiquidDoc.Table] {
        let marker = "<<<VISUALMETA:TABLES>>>"
        let lines = source.components(separatedBy: "\n")
        guard let open = lines.firstIndex(where: { $0.contains(marker) }),
              let close = lines[(open + 1)...].firstIndex(where: { $0.contains(marker) })
        else { return [] }
        let json = lines[(open + 1)..<close]
            .map { line -> String in
                var trimmed = line.trimmingCharacters(in: .whitespaces)
                while trimmed.hasPrefix("%") { trimmed.removeFirst() }
                return trimmed.trimmingCharacters(in: .whitespaces)
            }
            .joined()
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data)
        else { return [] }
        let raw = (parsed as? [[String: Any]])
            ?? ((parsed as? [String: Any])?["tables"] as? [[String: Any]])
            ?? []
        return raw.compactMap { table in
            guard let identifier = table["identifier"] as? String else { return nil }
            let cellRows = table["cells"] as? [[[String: Any]]] ?? []
            let cells: [[LiquidDoc.Table.Cell]] = cellRows.map { row in
                row.map { cell in
                    LiquidDoc.Table.Cell(value: cell["value"] as? String ?? "",
                                         formula: cell["formula"] as? String)
                }
            }
            guard !cells.isEmpty else { return nil }
            return LiquidDoc.Table(
                identifier: identifier,
                rowCount: (table["rowCount"] as? NSNumber)?.intValue ?? cells.count,
                columnCount: (table["columnCount"] as? NSNumber)?.intValue
                    ?? (cells.first?.count ?? 0),
                cells: cells)
        }
    }

    /// A tabular body's rows: split at `\\`, rules dropped, cells at
    /// unescaped `&`, each cell inline-converted.
    private static func tabularRows(_ body: String) -> [[String]] {
        // The column spec is the leading braced group — two of them for
        // tabularx ({width}{spec}), with an optional [t] between. A
        // leading group is chrome, not a cell, whenever it holds no
        // cell separators; a real first cell is never braced alone.
        var content = body
        for _ in 0..<3 {
            let trimmed = content.drop { $0 == " " || $0 == "\n" || $0 == "\t" }
            if trimmed.first == "[", let close = trimmed.firstIndex(of: "]") {
                content = String(trimmed[trimmed.index(after: close)...])
                continue
            }
            guard trimmed.first == "{",
                  let spec = balancedArgument(in: String(trimmed), afterPrefixLength: 0),
                  !spec.value.contains("&"), !spec.value.contains("\\\\"),
                  spec.value.count < 160
            else { break }
            content = String(trimmed.dropFirst(spec.consumed))
        }
        for rule in ["\\toprule", "\\midrule", "\\bottomrule", "\\hline", "\\centering"] {
            content = content.replacingOccurrences(of: rule, with: "")
        }
        // \cmidrule(lr){2-3} is rule geometry, not words.
        content = content.replacingOccurrences(
            of: #"\\cmidrule\s*(\([^)]*\))?\s*\{[^}]*\}"#, with: "",
            options: .regularExpression)
        return content.components(separatedBy: "\\\\")
            .map { row -> String in
                // \\[.5ex] leaves its spacing option at the head of the
                // next row — geometry, not words.
                let trimmed = row.drop { $0 == " " || $0 == "\n" || $0 == "\t" }
                if trimmed.first == "[", let close = trimmed.firstIndex(of: "]") {
                    return String(trimmed[trimmed.index(after: close)...])
                }
                return row
            }
            .map { row -> [String] in
                splitUnescaped(expandingSpans(in: row), on: "&").map { cell in
                    // A grid cell is a value, not prose: emphasis unwraps
                    // to bare words — markdown markers would show
                    // literally in the exported grid and the reader's
                    // table view, which render cells verbatim.
                    let plain = strippingCellDecorations(cell).replacingOccurrences(
                        of: #"\\(textbf|textit|emph|texttt)\b"#,
                        with: #"\\otplain"#, options: .regularExpression)
                    return inline(convert: plain).text
                }
            }
            .filter { row in row.contains { !$0.isEmpty } }
    }

    /// `\rotatebox[origin=c]{90}{words}` and kin decorate a cell's words
    /// with geometry the grid cannot keep — the words stay, the geometry
    /// goes (ht26-38 rotates its header cells). Two passes, because
    /// decorations nest: `\multirow{19}{*}{{\rotatebox{90}{\parbox{4em}{…}}}}`.
    private static func strippingCellDecorations(_ cell: String) -> String {
        var text = cell
        for _ in 0..<2 {
            // Two braced groups: geometry first, then the words.
            for command in ["rotatebox", "scalebox", "raisebox", "parbox"] {
                while let first = firstBalancedArgument(of: command, in: text,
                                                        skippingBracketOption: true) {
                    let offset = text.distance(from: text.startIndex, to: first.range.upperBound)
                    if let group = balancedArgument(in: text, afterPrefixLength: offset) {
                        let end = text.index(text.startIndex, offsetBy: group.consumed)
                        text.replaceSubrange(first.range.lowerBound..<end, with: group.value)
                    } else {
                        text.replaceSubrange(first.range, with: first.value)
                    }
                }
            }
            // One braced group whose \\ line breaks read as spaces.
            for command in ["makecell", "shortstack"] {
                while let argument = firstBalancedArgument(of: command, in: text,
                                                           skippingBracketOption: true) {
                    text.replaceSubrange(
                        argument.range,
                        with: argument.value.replacingOccurrences(of: "\\\\", with: " "))
                }
            }
        }
        return text
    }

    /// `\multicolumn{3}{c}{words}` spans columns: its words take the
    /// first cell and empty cells hold the remaining columns, so header
    /// rows stay aligned with the grid. `\multirow{2}{*}{words}` is just
    /// its words here — the grid has no row spans.
    private static func expandingSpans(in row: String) -> String {
        var text = row
        for command in ["multicolumn", "multirow"] {
            while let first = firstBalancedArgument(of: command, in: text) {
                var end = first.range.upperBound
                var words = first.value
                // Two more braced groups follow: alignment (or width),
                // then the words themselves.
                for _ in 0..<2 {
                    let offset = text.distance(from: text.startIndex, to: end)
                    guard let group = balancedArgument(in: text, afterPrefixLength: offset)
                    else { break }
                    words = group.value
                    end = text.index(text.startIndex, offsetBy: group.consumed)
                }
                let span = command == "multicolumn" ? (Int(first.value) ?? 1) : 1
                let padding = String(repeating: " & ", count: max(0, span - 1))
                text.replaceSubrange(first.range.lowerBound..<end, with: words + padding)
            }
        }
        return text
    }

    /// A list body's `\item` entries (bracket options dropped).
    private static func listItems(_ body: String) -> [String] {
        var items: [String] = []
        var rest = body[...]
        guard let first = rest.range(of: "\\item") else { return [] }
        rest = rest[first.upperBound...]
        while let next = rest.range(of: "\\item") {
            items.append(String(rest[..<next.lowerBound]))
            rest = rest[next.upperBound...]
        }
        items.append(String(rest))
        return items.map { item in
            var trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") {
                trimmed = String(trimmed[trimmed.index(after: close)...])
                    .trimmingCharacters(in: .whitespaces)
            }
            return trimmed
        }
    }

    private static func splitUnescaped(_ text: String, on separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var previous: Character = " "
        for character in text {
            if character == separator, previous != "\\" {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
            previous = character
        }
        parts.append(current)
        return parts
    }

    // MARK: Balanced-brace plumbing

    /// The environment name at a `\begin{...}` the text starts with.
    private static func environmentName(at text: Substring) -> String? {
        guard text.hasPrefix("\\begin{"),
              let close = text.firstIndex(of: "}") else { return nil }
        let start = text.index(text.startIndex, offsetBy: "\\begin{".count)
        return String(text[start..<close])
    }

    /// `\begin{name} … \end{name}` with same-name nesting counted.
    /// Returns character offsets into `text`.
    private static func environmentOffsets(named name: String, in text: String)
        -> (wholeStart: Int, bodyStart: Int, bodyEnd: Int, wholeEnd: Int)? {
        let begin = "\\begin{\(name)}"
        let end = "\\end{\(name)}"
        guard let start = text.range(of: begin) else { return nil }
        var depth = 1
        var search = start.upperBound
        while depth > 0 {
            let nextBegin = text.range(of: begin, range: search..<text.endIndex)
            guard let nextEnd = text.range(of: end, range: search..<text.endIndex)
            else { return nil }
            if let nextBegin, nextBegin.lowerBound < nextEnd.lowerBound {
                depth += 1
                search = nextBegin.upperBound
            } else {
                depth -= 1
                if depth == 0 {
                    return (text.distance(from: text.startIndex, to: start.lowerBound),
                            text.distance(from: text.startIndex, to: start.upperBound),
                            text.distance(from: text.startIndex, to: nextEnd.lowerBound),
                            text.distance(from: text.startIndex, to: nextEnd.upperBound))
                }
                search = nextEnd.upperBound
            }
        }
        return nil
    }

    private static func environmentRange(named name: String, in text: String)
        -> (whole: Range<String.Index>, body: Range<String.Index>,
            wholeSub: (Substring) -> Range<Substring.Index>,
            bodySub: (Substring) -> Range<Substring.Index>)? {
        guard let offsets = environmentOffsets(named: name, in: text) else { return nil }
        let whole = text.index(text.startIndex, offsetBy: offsets.wholeStart)
            ..< text.index(text.startIndex, offsetBy: offsets.wholeEnd)
        let body = text.index(text.startIndex, offsetBy: offsets.bodyStart)
            ..< text.index(text.startIndex, offsetBy: offsets.bodyEnd)
        return (whole, body,
                { sub in sub.index(sub.startIndex, offsetBy: offsets.wholeStart)
                    ..< sub.index(sub.startIndex, offsetBy: offsets.wholeEnd) },
                { sub in sub.index(sub.startIndex, offsetBy: offsets.bodyStart)
                    ..< sub.index(sub.startIndex, offsetBy: offsets.bodyEnd) })
    }

    /// The inner text of the first `\begin{name}…\end{name}`.
    private static func environmentBody(named name: String, in text: String) -> String? {
        guard let range = environmentRange(named: name, in: text) else { return nil }
        return String(text[range.body])
    }

    /// A balanced `{…}` starting at `afterPrefixLength` (the position of
    /// the opener). Returns the inner value and how many characters the
    /// whole group consumed from the string's start.
    private static func balancedArgument(in text: String, afterPrefixLength: Int,
                                         opener: Character = "{",
                                         closer: Character = "}")
        -> (value: String, consumed: Int)? {
        let characters = Array(text)
        var index = afterPrefixLength
        // Skip whitespace to the opener.
        while index < characters.count, characters[index].isWhitespace { index += 1 }
        guard index < characters.count, characters[index] == opener else { return nil }
        var depth = 0
        var value = ""
        var cursor = index
        while cursor < characters.count {
            let character = characters[cursor]
            if character == opener { depth += 1; if depth == 1 { cursor += 1; continue } }
            if character == closer {
                depth -= 1
                if depth == 0 { return (value, cursor + 1) }
            }
            value.append(character)
            cursor += 1
        }
        return nil
    }

    /// Every `\command{…}` argument in the text, in order (balanced).
    private static func balancedArguments(of command: String, in text: String,
                                          skippingBracketOption: Bool = false) -> [String] {
        var results: [String] = []
        var search = text[...]
        while let found = firstBalancedArgument(of: command, in: String(search),
                                                skippingBracketOption: skippingBracketOption) {
            results.append(found.value)
            search = search[search.index(search.startIndex,
                                         offsetBy: found.consumedFromStart)...]
        }
        return results
    }

    /// The first `\command{…}` (optionally `\command[opt]{…}`), with the
    /// range covering the whole command in `text` and the inner value.
    private static func firstBalancedArgument(of command: String, in text: String,
                                              skippingBracketOption: Bool = false)
        -> (value: String, range: Range<String.Index>, consumedFromStart: Int)? {
        guard let start = text.range(of: "\\" + command) else { return nil }
        // Never match a longer command's prefix (\cite vs \citep).
        if start.upperBound < text.endIndex, text[start.upperBound].isLetter {
            // Try again past this false match.
            let after = String(text[start.upperBound...])
            guard let inner = firstBalancedArgument(of: command, in: after,
                                                    skippingBracketOption: skippingBracketOption)
            else { return nil }
            let offset = text.distance(from: text.startIndex, to: start.upperBound)
            let lower = text.index(text.startIndex,
                                   offsetBy: offset + after.distance(from: after.startIndex,
                                                                     to: inner.range.lowerBound))
            let upper = text.index(text.startIndex,
                                   offsetBy: offset + after.distance(from: after.startIndex,
                                                                     to: inner.range.upperBound))
            return (inner.value, lower..<upper, offset + inner.consumedFromStart)
        }
        var prefixLength = text.distance(from: text.startIndex, to: start.upperBound)
        // An optional [..] between name and brace.
        if skippingBracketOption {
            let characters = Array(text)
            var index = prefixLength
            while index < characters.count, characters[index].isWhitespace { index += 1 }
            if index < characters.count, characters[index] == "[" {
                while index < characters.count, characters[index] != "]" { index += 1 }
                prefixLength = min(index + 1, characters.count)
            }
        }
        guard let argument = balancedArgument(in: text, afterPrefixLength: prefixLength)
        else { return nil }
        let upper = text.index(text.startIndex, offsetBy: argument.consumed)
        return (argument.value, start.lowerBound..<upper, argument.consumed)
    }

    /// The range of `\command[..]{..}` starting where the text begins.
    private static func commandRange(of command: String, at text: Substring)
        -> Range<Substring.Index>? {
        guard let found = firstBalancedArgument(of: command, in: String(text),
                                                skippingBracketOption: true) else { return nil }
        let length = found.consumedFromStart
        return text.startIndex..<text.index(text.startIndex, offsetBy: length)
    }

    /// Every regex capture, in order.
    private static func captures(in text: String, pattern: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return expression.matches(in: text,
                                  range: NSRange(location: 0, length: ns.length)).map { match in
            let index = match.numberOfRanges > 1 ? 1 : 0
            return ns.substring(with: match.range(at: index))
        }
    }
}
