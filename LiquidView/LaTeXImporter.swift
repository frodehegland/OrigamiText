import Foundation

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
        var body: [LiquidDoc.Paragraph]
        var references: [LiquidDoc.Reference] = []
        var tables: [LiquidDoc.Table] = []
        var assets: [LiquidDoc.Asset] = []
    }

    // MARK: - Entry points

    /// A zipped LaTeX project — Author's export, or any archive with a
    /// .tex inside. `main.tex` is preferred; else the file that declares
    /// `\documentclass` and `\begin{document}`; else the largest .tex.
    static func importArchive(at url: URL) throws -> Result {
        let zip = try ZipReader(data: try Data(contentsOf: url))
        let texNames = zip.entries.keys.filter {
            $0.lowercased().hasSuffix(".tex") && !$0.contains("__MACOSX")
        }
        guard !texNames.isEmpty else { throw LaTeXImportError.noTeX }
        func text(_ name: String) -> String? {
            zip.entry(name).map { String(decoding: $0, as: UTF8.self) }
        }
        let main = texNames.first { ($0 as NSString).lastPathComponent == "main.tex" }
            ?? texNames.first {
                let source = text($0) ?? ""
                return source.contains("\\documentclass") && source.contains("\\begin{document}")
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

        let resources: (String) -> Data? = { path in
            let name = (path as NSString).lastPathComponent
            return zip.entry(joined(mainDir, path))
                ?? zip.entry(path)
                ?? zip.entries.first { $0.key.hasSuffix("/" + name) || $0.key == name }?.value
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

        let stripped = strippingComments(from: source)

        // Metadata from the preamble (and Author's in-document topmatter).
        let title = balancedArguments(of: "title", in: stripped).first
            .map { inline(convert: $0).text }
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? fallbackTitle
        let authors = balancedArguments(of: "author", in: stripped)
            .map { inline(convert: $0).text }
            .filter { !$0.isEmpty }
        let author = authors.isEmpty ? nil : authors.joined(separator: ", ")

        // The words live between \begin{document} and \end{document};
        // a fragment with neither reads whole.
        var body = stripped
        if let begin = body.range(of: "\\begin{document}") {
            body = String(body[begin.upperBound...])
        }
        if let end = body.range(of: "\\end{document}") {
            body = String(body[..<end.lowerBound])
        }

        var paragraphs: [LiquidDoc.Paragraph] = []
        var assets: [LiquidDoc.Asset] = []
        var notes: [(id: String, text: String)] = []
        var ordinal = 0
        var assetOrdinal = 0
        var tableOrdinal = 0

        func nextID() -> String {
            ordinal += 1
            return "p\(ordinal)"
        }
        func appendText(_ raw: String) {
            let converted = inline(convert: raw)
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
            let caption = balancedArguments(of: "caption", in: figureBody).first
                .map { inline(convert: $0).text } ?? ""
            let resolved = resources(path)
                ?? ["jpg", "jpeg", "png", "pdf", "tiff"].lazy
                    .compactMap { resources(path + "." + $0) }.first
            let paragraphID = nextID()
            if let data = resolved, !data.isEmpty {
                assetOrdinal += 1
                let assetID = "img\(assetOrdinal)"
                let name = (path as NSString).lastPathComponent
                let ext = (name as NSString).pathExtension.lowercased()
                assets.append(LiquidDoc.Asset(
                    id: assetID,
                    filename: name.contains(".") ? name : name + ".jpg",
                    mediaType: WordImporter.mediaType(forExtension: ext.isEmpty ? "jpg" : ext),
                    dataBase64: data.base64EncodedString(),
                    alt: caption.isEmpty ? nil : caption))
                paragraphs.append(LiquidDoc.Paragraph(
                    id: paragraphID, heading: nil, text: "![\(caption)](asset:\(assetID))"))
            } else {
                paragraphs.append(LiquidDoc.Paragraph(
                    id: paragraphID, heading: nil, text: "![\(caption)](\(path))"))
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
                let converted = inline(convert: rest)
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
                        let code = String(rest[range.bodySub(rest)])
                            .trimmingCharacters(in: .newlines)
                        if !code.isEmpty {
                            paragraphs.append(LiquidDoc.Paragraph(
                                id: nextID(), heading: nil, text: code))
                        }
                        handled = true
                    case "equation", "equation*", "align", "align*",
                         "displaymath", "math", "eqnarray":
                        flushPlain()
                        let math = String(rest[range.bodySub(rest)])
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
                                "date", "thanks", "title", "author"] {
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

        // The bibliography: every entry a reference, keys as cited.
        let references = BibTeXParser.parse(
            bibliography.trimmingCharacters(in: .whitespacesAndNewlines))
            .map { LiquidDoc.Reference(id: $0.key, bibtex: $0.raw) }

        return Result(title: title, author: author, body: paragraphs,
                      references: references,
                      tables: namedTables, assets: assets)
    }

    // MARK: - Inline conversion

    /// One paragraph's LaTeX as the format's plain-text conventions:
    /// emphasis to markdown, `\cite` to `[cite:key]`, `\footnote` to a
    /// `[note:id]` dagger (the note returned alongside), links restored,
    /// escapes and accents resolved, leftover commands unwrapped, inline
    /// math kept verbatim.
    static func inline(convert raw: String) -> (text: String, notes: [(String, String)]) {
        var text = raw
        var notes: [(String, String)] = []

        // Inline math is TeX's own and stays verbatim — shield it.
        var mathSpans: [String] = []
        while let range = text.range(of: #"\$[^$\n]+\$"#, options: .regularExpression) {
            mathSpans.append(String(text[range]))
            text.replaceSubrange(range, with: "\u{FFFC}MATH\(mathSpans.count - 1)\u{FFFC}")
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
        ]
        for (from, to) in escapes {
            text = text.replacingOccurrences(of: from, with: to)
        }

        // Footnotes out first — their words go to the endnotes, a
        // dagger token stays.
        while let argument = firstBalancedArgument(of: "footnote", in: text) {
            let id = "fn\(notes.count + 1)"
            let note = inline(convert: argument.value)
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
                    .map { "[cite:\($0.trimmingCharacters(in: .whitespaces))]" }
                    .joined()
                text.replaceSubrange(argument.range, with: tokens)
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
                let innerResult = inline(convert: argument.value)
                notes.append(contentsOf: innerResult.notes)
                text.replaceSubrange(argument.range,
                                     with: opener + innerResult.text + closer)
            }
        }

        // Accents compose onto their letter: \'{e} and \'e alike.
        let combining: [Character: String] = [
            "'": "\u{0301}", "`": "\u{0300}", "^": "\u{0302}",
            "\"": "\u{0308}", "~": "\u{0303}", "c": "\u{0327}",
        ]
        for (mark, accent) in combining {
            let pattern = "\\\\\(NSRegularExpression.escapedPattern(for: String(mark)))\\{?([a-zA-Z])\\}?"
            while let range = text.range(of: pattern, options: .regularExpression) {
                let letter = text[range].last.map(String.init) ?? ""
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
        // The column spec is the first braced group.
        var content = body
        if let spec = balancedArgument(in: content, afterPrefixLength: 0) {
            content = String(content.dropFirst(spec.consumed))
        }
        for rule in ["\\toprule", "\\midrule", "\\bottomrule", "\\hline", "\\centering"] {
            content = content.replacingOccurrences(of: rule, with: "")
        }
        return content.components(separatedBy: "\\\\")
            .map { row -> [String] in
                splitUnescaped(row, on: "&").map { inline(convert: $0).text }
            }
            .filter { row in row.contains { !$0.isEmpty } }
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
