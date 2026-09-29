import Foundation

/// Imports Markdown (.md) files — CommonMark with the Pandoc scholarly
/// extensions — into the document model the EPUB exporter writes.
///
/// - Headings (ATX `#`–`######` and setext) map to the three heading
///   levels; a leading level-1 heading becomes the title when the front
///   matter names none, and the rest shift up so sections start at 1.
/// - YAML front matter: title, subtitle, author (a name, a list, or
///   `- name:` objects), date, abstract, keywords, bibliography, nocite.
/// - Fenced (``` and ~~~) and indented code become the format's fenced
///   blocks; `$$…$$` display maths stays verbatim TeX between `$$`.
/// - Standalone images become figures (`![alt](asset:id)`), their bytes
///   read beside the file; PDF figures are rasterised as LaTeX's are.
/// - Pipe tables become live grids with a pipe-text fallback, and a
///   `Table: caption` line becomes the "Table N:" caption.
/// - Footnotes (`[^label]` with `[^label]: text`, and inline `^[text]`)
///   become numbered endnotes under "Notes".
/// - Pandoc citations (`[@key]`, `[see @a, p. 3; @b]`, narrative `@key`)
///   become `[cite:key]` tokens, backed by the BibTeX (or CSL-JSON) file
///   the front matter names — or one beside the file with its name, or
///   `references.bib` — so every citation links to the reference list.
/// - Lists (bulleted and numbered, without blank lines between items),
///   block quotes, rules, autolinks, reference-style links, and `_em_`
///   / `__strong__` are carried in the format's own conventions.
nonisolated enum MarkdownImporter {

    struct ImportResult: Sendable {
        let title: String
        let author: String?
        let body: [LiquidDoc.Paragraph]
        var authors: [String] = []
        var subtitle: String? = nil
        var date: LiquidDate? = nil
        var abstract: String? = nil
        var keywords: [String] = []
        var references: [LiquidDoc.Reference] = []
        var tables: [LiquidDoc.Table] = []
        var assets: [LiquidDoc.Asset] = []
        /// What the person should know — unknown citation keys, figures
        /// that could not be read.
        var notices: [String] = []
        /// Files the document names beside itself (figures, its
        /// bibliography) that could not be read — in the sandbox, because
        /// only the Markdown file itself was granted. Reading them needs
        /// the folder.
        var unreadableCompanions: [String] = []
        /// Citations were written but no bibliography was found to back
        /// them — possibly one beside the file the sandbox hides.
        var citesWithoutBibliography = false
        var hasNotes = false

        /// A paper's apparatus — a resolved reference list or endnotes —
        /// which a draft would carry but an EPUB shows as live links.
        var isPaper: Bool { !references.isEmpty || hasNotes }

        /// Whether access to the file's folder would let more be read.
        var needsFolderAccess: Bool {
            !unreadableCompanions.isEmpty || citesWithoutBibliography
        }
    }

    /// `companions`: bibliography files chosen or dropped together with
    /// the document, read before any the document names or keeps beside it.
    static func importFile(at url: URL, companions: [URL] = []) throws -> ImportResult {
        let raw = try String(contentsOf: url, encoding: .utf8)
        return importText(raw, directory: url.deletingLastPathComponent(),
                          stem: url.deletingPathExtension().lastPathComponent,
                          extraBibliography: companionEntries(companions))
    }

    /// The entries of bibliography files given alongside a document.
    static func companionEntries(_ urls: [URL]) -> [BibTeXEntry] {
        urls.flatMap { url -> [BibTeXEntry] in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            return ReferenceFormats.bibtexText(at: url).map(bibliographyEntries(fromBibTeX:)) ?? []
        }
    }

    // MARK: - Blocks

    private enum Block {
        case paragraph(String)
        case heading(Int, String)
        case code(language: String, code: String)
        case math(String)
        case table(rows: [[String]], caption: String?)
        case image(alt: String, source: String)
        case rule
        case item(marker: String, text: String)
        case quote(String)
    }

    static func importText(_ raw: String, directory: URL, stem: String,
                           extraBibliography: [BibTeXEntry] = []) -> ImportResult {
        var lines = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        let front = frontMatter(&lines)
        var notices: [String] = []
        var unreadable: [String] = []

        // MARK: Pass 1 — lines into blocks

        var blocks: [Block] = []
        var footnoteDefinitions: [String: String] = [:]
        var linkDefinitions: [String: String] = [:]

        enum Open { case none, paragraph, item(String), quote }
        var open = Open.none
        var pending: [String] = []
        func flush() {
            let text = pending.joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            pending = []
            defer { open = .none }
            guard !text.isEmpty else { return }
            switch open {
            case .none, .paragraph: blocks.append(.paragraph(text))
            case .item(let marker): blocks.append(.item(marker: marker, text: text))
            case .quote: blocks.append(.quote(text))
            }
        }

        var index = 0
        var lastLineBlank = true
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            defer { index += 1 }

            if trimmed.isEmpty {
                flush()
                lastLineBlank = true
                continue
            }
            let wasBlank = lastLineBlank
            lastLineBlank = false

            // An HTML comment is the author's note to self.
            if trimmed.hasPrefix("<!--") {
                flush()
                while index < lines.count, !lines[index].contains("-->") { index += 1 }
                continue
            }

            // Fenced code: ``` or ~~~, three or more, to the matching fence.
            if let fence = codeFence(in: line) {
                flush()
                var code: [String] = []
                index += 1
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    if candidate.hasPrefix(fence.marker),
                       candidate.allSatisfy({ $0 == fence.marker.first }) { break }
                    code.append(lines[index])
                    index += 1
                }
                let body = code.joined(separator: "\n").trimmingCharacters(in: .newlines)
                if !body.isEmpty { blocks.append(.code(language: fence.language, code: body)) }
                continue
            }

            // Display maths: $$ … $$, on one line or across several.
            if trimmed.hasPrefix("$$") {
                flush()
                var tex = String(trimmed.dropFirst(2))
                if tex.hasSuffix("$$") {
                    tex = String(tex.dropLast(2))
                } else {
                    index += 1
                    var gathered: [String] = tex.isEmpty ? [] : [tex]
                    while index < lines.count {
                        let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                        if candidate.hasSuffix("$$") {
                            let last = String(candidate.dropLast(2))
                            if !last.isEmpty { gathered.append(last) }
                            break
                        }
                        gathered.append(lines[index])
                        index += 1
                    }
                    tex = gathered.joined(separator: "\n")
                }
                tex = tex.replacingOccurrences(of: #"\s*\{#[^}]*\}\s*$"#, with: "",
                                               options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !tex.isEmpty { blocks.append(.math(tex)) }
                continue
            }

            // Indented code — four spaces after a blank line, not a list's
            // continuation.
            if wasBlank, isIndentedCode(line), !lastBlockIsItem(blocks) {
                flush()
                var code: [String] = []
                while index < lines.count,
                      isIndentedCode(lines[index])
                        || lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    code.append(lines[index])
                    index += 1
                }
                index -= 1
                let rebuilt = code.map { dedented($0) }
                    .joined(separator: "\n").trimmingCharacters(in: .newlines)
                if !rebuilt.isEmpty { blocks.append(.code(language: "", code: rebuilt)) }
                lastLineBlank = false
                continue
            }

            // Footnote definitions, with their indented continuations.
            if let definition = footnoteDefinition(in: trimmed) {
                flush()
                var text = [definition.text]
                while index + 1 < lines.count {
                    let next = lines[index + 1]
                    let nextTrimmed = next.trimmingCharacters(in: .whitespaces)
                    if nextTrimmed.isEmpty {
                        // A blank line continues the note only when the
                        // line after it is indented.
                        if index + 2 < lines.count, lines[index + 2].hasPrefix("    ")
                            || lines[index + 2].hasPrefix("\t") {
                            index += 1
                            continue
                        }
                        break
                    }
                    if next.hasPrefix(" ") || next.hasPrefix("\t") {
                        text.append(nextTrimmed)
                        index += 1
                    } else {
                        break
                    }
                }
                footnoteDefinitions[definition.label] = text.joined(separator: " ")
                continue
            }

            // Reference-style link definitions: [label]: url "title".
            if let definition = linkDefinition(in: trimmed) {
                flush()
                linkDefinitions[definition.label.lowercased()] = definition.url
                continue
            }

            // Pipe tables: a header row, then the |---| separator row.
            if trimmed.contains("|"), index + 1 < lines.count,
               isTableSeparator(lines[index + 1]) {
                flush()
                var rows = [tableCells(of: trimmed)]
                index += 2
                while index < lines.count {
                    let row = lines[index].trimmingCharacters(in: .whitespaces)
                    guard !row.isEmpty, row.contains("|") else { break }
                    rows.append(tableCells(of: row))
                    index += 1
                }
                // A caption follows: "Table: …" or ": …", after at most
                // one blank line.
                var caption: String?
                var probe = index
                if probe < lines.count, lines[probe].trimmingCharacters(in: .whitespaces).isEmpty {
                    probe += 1
                }
                if probe < lines.count {
                    let candidate = lines[probe].trimmingCharacters(in: .whitespaces)
                    if candidate.hasPrefix("Table:") {
                        caption = String(candidate.dropFirst("Table:".count))
                    } else if candidate.hasPrefix(": ") {
                        caption = String(candidate.dropFirst(2))
                    }
                    if caption != nil { index = probe + 1 }
                }
                blocks.append(.table(rows: rows,
                                     caption: caption?.trimmingCharacters(in: .whitespaces)))
                index -= 1
                lastLineBlank = true
                continue
            }

            // ATX headings.
            if let heading = atxHeading(in: trimmed) {
                flush()
                blocks.append(.heading(heading.level, heading.text))
                continue
            }

            // Setext headings underline the paragraph just written.
            if case .paragraph = open, !pending.isEmpty {
                if trimmed.allSatisfy({ $0 == "=" }) {
                    let text = pending.joined(separator: " ")
                    pending = []
                    open = .none
                    blocks.append(.heading(1, text))
                    continue
                }
                if trimmed.allSatisfy({ $0 == "-" }), trimmed.count >= 2 {
                    let text = pending.joined(separator: " ")
                    pending = []
                    open = .none
                    blocks.append(.heading(2, text))
                    continue
                }
            }

            // Thematic breaks: ---, ***, ___ (spaces allowed).
            let compact = trimmed.replacingOccurrences(of: " ", with: "")
            if compact.count >= 3, let first = compact.first, "-*_".contains(first),
               compact.allSatisfy({ $0 == first }) {
                flush()
                blocks.append(.rule)
                continue
            }

            // A standalone image is a figure.
            if let image = standaloneImage(in: trimmed) {
                flush()
                blocks.append(.image(alt: image.alt, source: image.source))
                continue
            }

            // Block quotes: consecutive > lines are one quotation;
            // a bare > separates its paragraphs.
            if trimmed.hasPrefix(">") {
                let inner = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                if case .quote = open {} else { flush() }
                if inner.isEmpty {
                    flush()
                } else {
                    open = .quote
                    pending.append(inner)
                }
                continue
            }

            // List items. A numbered item interrupts a paragraph only
            // when it starts at 1, as CommonMark has it — "2020. was a
            // year" mid-paragraph is words.
            if let item = listItem(in: trimmed) {
                let interrupts: Bool
                switch open {
                case .paragraph: interrupts = !item.ordered || item.number == 1
                default: interrupts = true
                }
                if interrupts {
                    flush()
                    open = .item(item.marker)
                    pending = [item.text]
                    continue
                }
            }

            // Anything else continues what is open, or opens a paragraph.
            if case .none = open { open = .paragraph }
            pending.append(trimmed)
        }
        flush()

        // MARK: Title and heading levels

        var title = front.scalar("title") ?? stem
        if front.scalar("title") == nil, case .heading(1, let text)? = blocks.first {
            title = text
            blocks.removeFirst()
        }
        // Sections start at level 1: a document whose first level is ##
        // (its # was the title) shifts up, so the contents nest properly.
        let levels = blocks.compactMap { block -> Int? in
            if case .heading(let level, _) = block { return level }
            return nil
        }
        let shift = max(0, (levels.min() ?? 1) - 1)

        // MARK: Bibliography

        var bibliography = loadBibliography(front: front, directory: directory, stem: stem)
        // Files given alongside take precedence; a named file the sandbox
        // hid is no loss when the same work arrived with the document.
        if !extraBibliography.isEmpty {
            let given = Set(extraBibliography.map(\.key))
            bibliography.entries = extraBibliography
                + bibliography.entries.filter { !given.contains($0.key) }
            bibliography.unreadable = []
        }
        unreadable.append(contentsOf: bibliography.unreadable)
        let entriesByKey = Dictionary(bibliography.entries.map { ($0.key, $0) },
                                      uniquingKeysWith: { first, _ in first })

        // MARK: Pass 2 — inline conversion, in document order

        var citedOrder: [String] = []
        var citedAnything = false
        var unknownKeys: [String] = []
        var noteOrder: [String] = []            // labels, by first reference
        var inlineNotes: [String: String] = [:] // synthetic label → text

        func noteID(forLabel label: String) -> String {
            if let position = noteOrder.firstIndex(of: label) { return "fn\(position + 1)" }
            noteOrder.append(label)
            return "fn\(noteOrder.count)"
        }
        func cite(_ key: String) -> String {
            citedAnything = true
            if entriesByKey[key] != nil {
                if !citedOrder.contains(key) { citedOrder.append(key) }
            } else if !unknownKeys.contains(key) {
                unknownKeys.append(key)
            }
            return "[cite:\(key)]"
        }
        func inline(_ text: String) -> String {
            outsideCode(text) { segment in
                var out = segment
                out = convertAutolinks(out)
                out = convertReferenceLinks(out, definitions: linkDefinitions)
                out = convertInlineNotes(out) { noteText in
                    let label = "^inline\(inlineNotes.count + 1)"
                    inlineNotes[label] = noteText
                    return "[note:\(noteID(forLabel: label))]"
                }
                out = convertFootnoteReferences(out) { label in
                    footnoteDefinitions[label] == nil ? nil : "[note:\(noteID(forLabel: label))]"
                }
                out = convertBracketCitations(out, cite: cite)
                out = convertNarrativeCitations(out, known: entriesByKey) { key in
                    let entry = entriesByKey[key]
                    let names = entry.map(narrativeName) ?? ""
                    return names.isEmpty ? cite(key) : "\(names) \(cite(key))"
                }
                out = convertUnderscoreEmphasis(out)
                return out
            }
        }

        var paragraphs: [LiquidDoc.Paragraph] = []
        var tables: [LiquidDoc.Table] = []
        var assets: [LiquidDoc.Asset] = []
        func nextID() -> String { "p\(paragraphs.count + 1)" }
        func append(_ text: String, heading: Int? = nil) {
            paragraphs.append(LiquidDoc.Paragraph(id: nextID(), heading: heading, text: text))
        }

        for block in blocks {
            switch block {
            case .paragraph(let text):
                append(inline(text))
            case .heading(let level, let text):
                append(inline(text), heading: min(max(level - shift, 1), 3))
            case .code(let language, let code):
                append("```\(language)\n\(code)\n```")
            case .math(let tex):
                append("$$\n\(tex)\n$$")
            case .rule:
                append("---")
            case .item(let marker, let text):
                append(marker + inline(text))
            case .quote(let text):
                append("> " + inline(text))
            case .table(let rows, let caption):
                let columns = rows.map(\.count).max() ?? 0
                guard columns > 0 else { continue }
                let identifier = "md-table-\(tables.count + 1)"
                let cells = rows.map { row in
                    (0..<columns).map { column in
                        LiquidDoc.Table.Cell(value: column < row.count
                            ? plainCell(inline(row[column])) : "")
                    }
                }
                let table = LiquidDoc.Table(identifier: identifier, rowCount: cells.count,
                                            columnCount: columns, cells: cells)
                if let caption, !caption.isEmpty {
                    append("Table \(tables.count + 1): \(inline(caption))")
                }
                tables.append(table)
                var paragraph = LiquidDoc.Paragraph(
                    id: nextID(), heading: nil,
                    text: cells.map { "| " + $0.map(\.value).joined(separator: " | ") + " |" }
                        .joined(separator: "\n"))
                paragraph.tableID = identifier
                paragraphs.append(paragraph)
            case .image(let alt, let source):
                // The caption is words: citation tokens and brackets give
                // way so the marker stays parseable (as the LaTeX and XML
                // importers' figures do).
                let caption = inline(alt)
                    .replacingOccurrences(of: #"\[cite:[^\]]+\]|\[note:[^\]]+\]"#, with: "",
                                          options: .regularExpression)
                    .replacingOccurrences(of: "[", with: "(")
                    .replacingOccurrences(of: "]", with: ")")
                    .trimmingCharacters(in: .whitespaces)
                if source.hasPrefix("http://") || source.hasPrefix("https://") {
                    // Never fetched at import: a link to the picture.
                    append("[\(caption.isEmpty ? source : caption)](\(source))")
                    continue
                }
                let path = source.removingPercentEncoding ?? source
                let fileURL = path.hasPrefix("/")
                    ? URL(fileURLWithPath: path)
                    : directory.appendingPathComponent(path)
                guard var data = try? Data(contentsOf: fileURL), !data.isEmpty else {
                    unreadable.append(path)
                    if !caption.isEmpty { append(caption) }
                    continue
                }
                var ext = fileURL.pathExtension.lowercased()
                if ext == "pdf" {
                    guard let png = LaTeXImporter.rasterizedPDF(data) else {
                        notices.append("The figure \(path) is a PDF that could not be drawn.")
                        if !caption.isEmpty { append(caption) }
                        continue
                    }
                    data = png
                    ext = "png"
                }
                let assetID = "img\(assets.count + 1)"
                assets.append(LiquidDoc.Asset(
                    id: assetID,
                    filename: "\(assetID).\(ext.isEmpty ? "png" : ext)",
                    mediaType: LiquidDoc.mediaType(forExtension: ext),
                    dataBase64: data.base64EncodedString(),
                    alt: caption.isEmpty ? nil : caption))
                append("![\(caption)](asset:\(assetID))")
            }
        }

        // MARK: Endnotes

        // Notes print in the order the text first cites them; a note may
        // itself cite a note, so the list grows while it is written.
        var notes: [LiquidDoc.Paragraph] = []
        var written = 0
        while written < noteOrder.count {
            let label = noteOrder[written]
            written += 1
            let source = footnoteDefinitions[label] ?? inlineNotes[label] ?? ""
            notes.append(LiquidDoc.Paragraph(id: "fn\(written)", heading: nil,
                                             text: inline(source)))
        }
        if !notes.isEmpty {
            append("Notes", heading: 1)
            paragraphs.append(contentsOf: notes)
        }

        // MARK: References

        let nocite = front.list("nocite").joined(separator: " ")
        var keys = citedOrder
        if nocite.contains("@*") {
            keys += bibliography.entries.map(\.key).filter { !keys.contains($0) }
        } else {
            for match in nocite.matches(of: /@([A-Za-z0-9_][A-Za-z0-9_:.\-\/]*)/) {
                let key = String(match.1)
                if entriesByKey[key] != nil, !keys.contains(key) { keys.append(key) }
            }
        }
        let references = keys.enumerated().compactMap { position, key -> LiquidDoc.Reference? in
            entriesByKey[key].map {
                LiquidDoc.Reference(id: key, bibtex: $0.raw, number: position + 1)
            }
        }
        if !unknownKeys.isEmpty, !bibliography.entries.isEmpty {
            let shown = unknownKeys.prefix(3).joined(separator: ", ")
            notices.append("\(unknownKeys.count) citation key\(unknownKeys.count == 1 ? "" : "s") not in the bibliography: \(shown)\(unknownKeys.count > 3 ? "…" : "")")
        }
        if citedAnything, bibliography.entries.isEmpty {
            notices.append("The citations have no bibliography — name one in the front matter (bibliography: refs.bib) or put \(stem).bib beside the file.")
        }
        if !unreadable.isEmpty {
            notices.append("Could not read \(unreadable.count) file\(unreadable.count == 1 ? "" : "s") beside the Markdown: \(unreadable.prefix(3).joined(separator: ", "))")
        }

        // MARK: Front matter

        let authors = front.list("author")
        var result = ImportResult(title: title,
                                  author: authors.isEmpty ? nil : authors.joined(separator: ", "),
                                  body: paragraphs)
        result.authors = authors.count > 1 ? authors : []
        result.subtitle = front.scalar("subtitle")
        result.date = front.scalar("date").flatMap { LiquidDate(isoString: String($0.prefix(10))) }
        result.abstract = front.scalar("abstract")
        result.keywords = front.list("keywords")
            .flatMap { $0.components(separatedBy: CharacterSet(charactersIn: ",;")) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        result.references = references
        result.tables = tables
        result.assets = assets
        result.notices = notices
        result.unreadableCompanions = unreadable
        result.citesWithoutBibliography = citedAnything && bibliography.entries.isEmpty
        result.hasNotes = !notes.isEmpty
        return result
    }

    // MARK: - Front matter

    struct FrontMatter {
        var values: [String: [String]] = [:]

        func scalar(_ key: String) -> String? {
            guard let value = values[key], !value.isEmpty else { return nil }
            let joined = value.joined(separator: value.count > 1 ? ", " : "")
            return joined.isEmpty ? nil : joined
        }

        func list(_ key: String) -> [String] { values[key] ?? [] }
    }

    /// The YAML subset scholarly Markdown front matter uses: scalars,
    /// quoted or not; `[a, b]` flow lists; `- item` block lists (an item
    /// that is a mapping gives its `name:`); `|` and `>` block scalars.
    /// The block is removed from `lines`.
    static func frontMatter(_ lines: inout [String]) -> FrontMatter {
        var front = FrontMatter()
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: {
                  let marker = $0.trimmingCharacters(in: .whitespaces)
                  return marker == "---" || marker == "..."
              }) else { return front }
        func unquoted(_ value: String) -> String {
            var text = value.trimmingCharacters(in: .whitespaces)
            if text.count >= 2, let first = text.first, first == "\"" || first == "'",
               text.last == first {
                text = String(text.dropFirst().dropLast())
            }
            return text
        }
        let block = Array(lines[1..<end])
        var index = 0
        while index < block.count {
            let line = block[index]
            index += 1
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), !line.hasPrefix("-"),
                  let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value == "|" || value == ">" || value.hasPrefix("|") || value.hasPrefix(">-") {
                var gathered: [String] = []
                while index < block.count,
                      block[index].hasPrefix(" ") || block[index].hasPrefix("\t")
                        || block[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    gathered.append(block[index].trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                let separator = value.hasPrefix("|") ? "\n" : " "
                front.values[key] = [gathered.joined(separator: separator)
                    .trimmingCharacters(in: .whitespacesAndNewlines)]
            } else if value.isEmpty {
                // A block list, whose items may be mappings.
                var items: [String] = []
                while index < block.count,
                      block[index].hasPrefix(" ") || block[index].hasPrefix("\t")
                        || block[index].hasPrefix("-") {
                    let item = block[index].trimmingCharacters(in: .whitespaces)
                    index += 1
                    guard item.hasPrefix("- ") || item == "-" else { continue }
                    var text = String(item.dropFirst(1)).trimmingCharacters(in: .whitespaces)
                    if text.lowercased().hasPrefix("name:") {
                        text = String(text.dropFirst("name:".count))
                    } else if let colon = text.firstIndex(of: ":"),
                              !text[..<colon].contains(" "),
                              text[..<colon].lowercased() != "http",
                              text[..<colon].lowercased() != "https" {
                        // Some other mapping key first (`- affiliation:`)
                        // — the name may follow on the next line.
                        if index < block.count {
                            let next = block[index].trimmingCharacters(in: .whitespaces)
                            if next.lowercased().hasPrefix("name:") {
                                text = String(next.dropFirst("name:".count))
                                index += 1
                            } else { continue }
                        }
                    }
                    let name = unquoted(text)
                    if !name.isEmpty { items.append(name) }
                }
                if !items.isEmpty { front.values[key] = items }
            } else if value.hasPrefix("["), value.hasSuffix("]") {
                front.values[key] = value.dropFirst().dropLast()
                    .components(separatedBy: ",")
                    .map(unquoted)
                    .filter { !$0.isEmpty }
            } else {
                front.values[key] = [unquoted(value)]
            }
        }
        lines.removeSubrange(0...end)
        return front
    }

    // MARK: - Bibliography

    private static func loadBibliography(front: FrontMatter, directory: URL,
                                         stem: String) -> (entries: [BibTeXEntry], unreadable: [String]) {
        let named = front.list("bibliography")
        let candidates = named.isEmpty
            ? ["\(stem).bib", "\(stem).json", "\(stem).ris", "references.bib",
               "bibliography.bib", "refs.bib", "references.ris"]
            : named
        var entries: [BibTeXEntry] = []
        var unreadable: [String] = []
        var seen: Set<String> = []
        for name in candidates {
            let url = name.hasPrefix("/")
                ? URL(fileURLWithPath: name) : directory.appendingPathComponent(name)
            // BibTeX, CSL-JSON, RIS, EndNote — whatever the paper keeps.
            guard let text = ReferenceFormats.bibtexText(at: url) else {
                if !named.isEmpty { unreadable.append(name) }
                continue
            }
            let found = bibliographyEntries(fromBibTeX: text)
            for entry in found where !entry.key.isEmpty && !seen.contains(entry.key) {
                seen.insert(entry.key)
                entries.append(entry)
            }
            // Without a named file, the first one found is the paper's.
            if named.isEmpty, !entries.isEmpty { break }
        }
        return (entries, unreadable)
    }

    /// BibTeX text as entries: whole-line `%` comments and `@String`
    /// abbreviations dealt with first, as BibTeX itself would.
    static func bibliographyEntries(fromBibTeX text: String) -> [BibTeXEntry] {
        func uncommented(_ text: String) -> String {
            text.components(separatedBy: .newlines)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("%") }
                .joined(separator: "\n")
        }
        return BibTeXParser.parse(
            uncommented(FormatSources.expandingStringMacros(in: uncommented(text))))
    }

    /// The names a narrative citation prints before its number:
    /// "Nelson", "Nelson and Engelbart", "Nelson et al.".
    private static func narrativeName(_ entry: BibTeXEntry) -> String {
        let field = entry.fields["author"] ?? entry.fields["editor"] ?? ""
        let families = field.components(separatedBy: " and ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { name -> String in
                let family = name.contains(",")
                    ? String(name.prefix { $0 != "," })
                    : String(name.split(separator: " ").last ?? "")
                return BibTeXParser.displayText(family)
            }
        switch families.count {
        case 0: return ""
        case 1: return families[0]
        case 2: return "\(families[0]) and \(families[1])"
        default: return "\(families[0]) et al."
        }
    }

    // MARK: - Line recognisers

    private static func codeFence(in line: String) -> (marker: String, language: String)? {
        let leading = line.prefix { $0 == " " }
        guard leading.count <= 3 else { return nil }
        let rest = line.dropFirst(leading.count)
        guard let first = rest.first, first == "`" || first == "~" else { return nil }
        let marker = rest.prefix { $0 == first }
        guard marker.count >= 3 else { return nil }
        let info = rest.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
        if first == "`", info.contains("`") { return nil }
        // "{.python}" and "python title=…" both name the language first.
        let language = info.trimmingCharacters(in: CharacterSet(charactersIn: "{}."))
            .split(separator: " ").first.map(String.init) ?? ""
        return (String(marker), language)
    }

    private static func isIndentedCode(_ line: String) -> Bool {
        line.hasPrefix("    ") || line.hasPrefix("\t")
    }

    private static func dedented(_ line: String) -> String {
        if line.hasPrefix("\t") { return String(line.dropFirst()) }
        return String(line.dropFirst(min(4, line.prefix { $0 == " " }.count)))
    }

    private static func lastBlockIsItem(_ blocks: [Block]) -> Bool {
        if case .item? = blocks.last { return true }
        return false
    }

    private static func footnoteDefinition(in line: String) -> (label: String, text: String)? {
        guard let match = line.firstMatch(of: /^\[\^([^\]\s]+)\]:\s?(.*)$/) else { return nil }
        return (String(match.1), String(match.2))
    }

    private static func linkDefinition(in line: String) -> (label: String, url: String)? {
        guard !line.hasPrefix("[^"),
              let match = line.firstMatch(of: /^\[([^\]]+)\]:\s*<?([^\s>]+)>?(?:\s+["'(].*["')])?$/)
        else { return nil }
        return (String(match.1), String(match.2))
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-"), trimmed.contains("|") || trimmed.contains(":") else { return false }
        return trimmed.wholeMatch(of: /\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?/) != nil
    }

    /// A row's cells, split on unescaped pipes, outer pipes dropped.
    private static func tableCells(of row: String) -> [String] {
        var trimmed = row
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|"), !trimmed.hasSuffix("\\|") { trimmed.removeLast() }
        var cells: [String] = []
        var current = ""
        var escaped = false
        var inCode = false
        for character in trimmed {
            if escaped {
                // Only an escaped pipe loses its backslash; TeX's stay.
                if character != "|" { current.append("\\") }
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "`" {
                inCode.toggle()
                current.append(character)
            } else if character == "|", !inCode {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    /// A table cell prints its words: the grid carries no inline
    /// markup, so emphasis and code marks give way (citations stay —
    /// the exporter links them in cells too).
    private static func plainCell(_ text: String) -> String {
        text.replacingOccurrences(of: #"\*\*(.+?)\*\*"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\*(.+?)\*"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "`", with: "")
    }

    /// An ATX heading of any depth, trailing #s and `{#id}` attributes gone.
    private static func atxHeading(in line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = line.dropFirst(hashes.count)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        let text = rest
            .replacingOccurrences(of: #"\s*\{[#.][^}]*\}\s*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+#+\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (hashes.count, text)
    }

    private static func standaloneImage(in line: String) -> (alt: String, source: String)? {
        guard let match = line.wholeMatch(
            of: /!\[(.*)\]\(\s*<?([^\s)>]+)>?(?:\s+["'(][^)]*["')])?\s*\)(?:\{[^}]*\})?/)
        else { return nil }
        return (String(match.1), String(match.2))
    }

    private static func listItem(in line: String) -> (marker: String, text: String,
                                                      ordered: Bool, number: Int)? {
        if let match = line.wholeMatch(of: /([-*+])\s+(.+)/) {
            // "+" is Markdown's own bullet; the format's lists read "- ".
            let text = String(match.2)
            // A task-list box reads as its words.
            let words = text.replacingOccurrences(of: #"^\[[ xX]\]\s+"#, with: "",
                                                  options: .regularExpression)
            return ("- ", words, false, 0)
        }
        if let match = line.wholeMatch(of: /(\d{1,3})[.)]\s+(.+)/) {
            let number = Int(match.1) ?? 1
            return ("\(number). ", String(match.2), true, number)
        }
        return nil
    }

    // MARK: - Inline conversions

    /// Applies `transform` to the text outside backtick code spans, which
    /// keep their contents verbatim — code is full of @ and brackets.
    static func outsideCode(_ text: String, _ transform: (String) -> String) -> String {
        var out = ""
        var rest = Substring(text)
        var plain = ""
        while let open = rest.firstIndex(of: "`") {
            plain += rest[..<open]
            let run = rest[open...].prefix { $0 == "`" }
            let afterRun = rest.index(open, offsetBy: run.count)
            if let close = rest[afterRun...].range(of: String(run)) {
                out += transform(plain)
                plain = ""
                out += rest[open..<close.upperBound]
                rest = rest[close.upperBound...]
            } else {
                plain += run
                rest = rest[afterRun...]
            }
        }
        plain += rest
        out += transform(plain)
        return out
    }

    private static func convertAutolinks(_ text: String) -> String {
        text.replacingOccurrences(of: #"<((?:https?|mailto|gemini|origamitext):[^>\s]+)>"#,
                                  with: "$1", options: .regularExpression)
    }

    /// `[text][label]` and `[label][]` against the definitions.
    private static func convertReferenceLinks(_ text: String,
                                              definitions: [String: String]) -> String {
        guard !definitions.isEmpty else { return text }
        var out = text
        for match in text.matches(of: /\[([^\]]+)\]\[([^\]]*)\]/).reversed() {
            let words = String(match.1)
            let label = (match.2.isEmpty ? words : String(match.2)).lowercased()
            guard let url = definitions[label] else { continue }
            out.replaceSubrange(match.range, with: "[\(words)](\(url))")
        }
        return out
    }

    /// Pandoc's inline notes, `^[words]`, one level of brackets inside.
    private static func convertInlineNotes(_ text: String,
                                           note: (String) -> String) -> String {
        var out = text
        for match in text.matches(of: /\^\[((?:[^\[\]]|\[[^\[\]]*\])+)\]/).reversed() {
            out.replaceSubrange(match.range, with: note(String(match.1)))
        }
        return out
    }

    private static func convertFootnoteReferences(_ text: String,
                                                  token: (String) -> String?) -> String {
        var out = text
        for match in text.matches(of: /\[\^([^\]\s]+)\]/).reversed() {
            if let replacement = token(String(match.1)) {
                out.replaceSubrange(match.range, with: replacement)
            }
        }
        return out
    }

    /// The citation key Pandoc accepts: `@key`, `-@key` (author
    /// suppressed), or `@{key with odd characters}`. Trailing punctuation
    /// is the sentence's, not the key's.
    private static let keyPattern = #"-?@(\{[^}]+\}|[A-Za-z0-9_][A-Za-z0-9_:.#$%&+?<>~/-]*)"#

    private static func bareKey(_ raw: String) -> String {
        var key = raw
        if key.hasPrefix("{"), key.hasSuffix("}") { return String(key.dropFirst().dropLast()) }
        while let last = key.last, ".:,;?!-/".contains(last) { key.removeLast() }
        return key
    }

    /// `[@a]`, `[@a; @b]`, `[see @a, pp. 3–4; also @b]` — every key a
    /// token, the prefixes and locators kept as words.
    private static func convertBracketCitations(_ text: String,
                                                cite: (String) -> String) -> String {
        guard text.contains("@"), let keyRegex = try? NSRegularExpression(
            pattern: "(?:^|(?<=[\\s;\\[(]))" + keyPattern) else { return text }
        var out = text
        // A bracket group holding an @, not a link's words (no "(" after)
        // and not one of the format's own tokens.
        for match in text.matches(of: /\[([^\[\]]*@[^\[\]]*)\](?!\()/).reversed() {
            let inner = String(match.1)
            if inner.hasPrefix("cite:") || inner.hasPrefix("note:") { continue }
            var parts: [String] = []
            var foundKey = false
            for part in inner.components(separatedBy: ";") {
                let piece = part.trimmingCharacters(in: .whitespaces)
                let ns = piece as NSString
                var converted = piece
                for keyMatch in keyRegex.matches(in: piece, range: NSRange(location: 0, length: ns.length)).reversed() {
                    let raw = ns.substring(with: keyMatch.range(at: 1))
                    let key = bareKey(raw)
                    guard !key.isEmpty, let whole = Range(keyMatch.range, in: converted) else { continue }
                    // Trailing punctuation the key shed goes back to the words.
                    let shed = raw.hasPrefix("{") ? "" : String(raw.dropFirst(key.count))
                    converted.replaceSubrange(whole, with: cite(key) + shed)
                    foundKey = true
                }
                parts.append(converted)
            }
            guard foundKey else { continue }
            let allBare = parts.allSatisfy { $0.wholeMatch(of: /\[cite:[^\]]+\]/) != nil }
            out.replaceSubrange(match.range, with: parts.joined(separator: allBare ? ", " : "; "))
        }
        return out
    }

    /// A bare `@key` in running text — "as @nelson1965 argues" — for keys
    /// the bibliography holds. Anything else (an email, a handle) stays.
    private static func convertNarrativeCitations(_ text: String, known: [String: BibTeXEntry],
                                                  cite: (String) -> String) -> String {
        guard !known.isEmpty, text.contains("@"),
              let regex = try? NSRegularExpression(
                pattern: "(?<![\\w@.\\[])" + keyPattern) else { return text }
        var out = text
        let ns = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let raw = ns.substring(with: match.range(at: 1))
            let key = bareKey(raw)
            guard known[key] != nil, let whole = Range(match.range, in: out) else { continue }
            let shed = raw.hasPrefix("{") ? "" : String(raw.dropFirst(key.count))
            out.replaceSubrange(whole, with: cite(key) + shed)
        }
        return out
    }

    /// `__strong__` and `_em_` in the format's asterisk forms. Intraword
    /// underscores (snake_case) are left alone, as CommonMark leaves them.
    private static func convertUnderscoreEmphasis(_ text: String) -> String {
        guard text.contains("_") else { return text }
        return text
            .replacingOccurrences(of: #"(?<![\w_])__(?=\S)(.+?)(?<=\S)__(?![\w_])"#,
                                  with: "**$1**", options: .regularExpression)
            .replacingOccurrences(of: #"(?<![\w_])_(?=[^\s_])(.+?)(?<=[^\s_])_(?![\w_])"#,
                                  with: "*$1*", options: .regularExpression)
    }
}
