import Foundation

// Typst, AsciiDoc and reStructuredText in, by way of Markdown.
//
// Each bridge rewrites its markup as the Pandoc-flavoured Markdown the
// Markdown importer reads — YAML front matter, `#` headings, `[@key]`
// citations, `^[…]` notes, pipe tables, fenced code, `$…$` / `$$…$$`
// TeX, `![caption](path)` figures, `> ` quotations — so one importer
// does the reading for all four: bibliography files (named, beside the
// file, or chosen with it), figures, folder access, and the choice
// between an EPUB on the shelf and a draft. What a bridge cannot carry
// keeps its words.

nonisolated enum MarkupImport {

    /// The markup kinds read through the Markdown importer.
    static let extensions: Set<String> = ["md", "markdown", "txt", "typ", "adoc", "asciidoc", "rst"]

    /// `companions`: bibliography files chosen or dropped with the document.
    static func importFile(at url: URL, companions: [URL] = []) throws -> MarkdownImporter.ImportResult {
        let ext = url.pathExtension.lowercased()
        guard ["typ", "adoc", "asciidoc", "rst"].contains(ext) else {
            return try MarkdownImporter.importFile(at: url, companions: companions)
        }
        let raw = try String(contentsOf: url, encoding: .utf8)
        let bridged: Bridged = switch ext {
        case "typ": TypstBridge.markdown(from: raw)
        case "rst": RSTBridge.markdown(from: raw)
        default: AsciiDocBridge.markdown(from: raw)
        }
        return MarkdownImporter.importText(
            bridged.markdown, directory: url.deletingLastPathComponent(),
            stem: url.deletingPathExtension().lastPathComponent,
            extraBibliography: MarkdownImporter.companionEntries(companions) + bridged.bibliography)
    }
}

/// A bridge's output: the Markdown, and any references the markup
/// defined in its own text (reStructuredText's citations).
nonisolated struct Bridged {
    var markdown: String
    var bibliography: [BibTeXEntry] = []
}

// MARK: - Shared pieces

/// The YAML front matter the Markdown importer reads.
nonisolated struct BridgeFrontMatter {
    var title: String?
    var subtitle: String?
    var authors: [String] = []
    var date: String?
    var abstract: String?
    var keywords: [String] = []
    var bibliography: [String] = []

    var yaml: String {
        func quoted(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\"", with: "'")
                .replacingOccurrences(of: "\n", with: " ") + "\""
        }
        var lines = ["---"]
        if let title, !title.isEmpty { lines.append("title: \(quoted(title))") }
        if let subtitle, !subtitle.isEmpty { lines.append("subtitle: \(quoted(subtitle))") }
        if !authors.isEmpty {
            lines.append("author:")
            lines += authors.map { "  - \(quoted($0))" }
        }
        if let date, !date.isEmpty { lines.append("date: \(quoted(date))") }
        if let abstract, !abstract.isEmpty {
            lines.append("abstract: |")
            lines += abstract.components(separatedBy: "\n").map { "  " + $0 }
        }
        if !keywords.isEmpty {
            lines.append("keywords:")
            lines += keywords.map { "  - \(quoted($0))" }
        }
        if !bibliography.isEmpty {
            lines.append("bibliography:")
            lines += bibliography.map { "  - \(quoted($0))" }
        }
        lines.append("---")
        return lines.count > 2 ? lines.joined(separator: "\n") + "\n\n" : ""
    }
}

/// Text held out of the later rewriting passes — code, maths, finished
/// links — behind private-use placeholders, and put back at the end.
nonisolated final class BridgeStash {
    private var items: [String] = []

    func hold(_ text: String) -> String {
        items.append(text)
        return "\u{E100}\(items.count - 1)\u{E101}"
    }

    /// Latest first, so a held piece that itself holds placeholders
    /// comes back whole.
    func restore(_ text: String) -> String {
        var out = text
        for (index, item) in items.enumerated().reversed() {
            out = out.replacingOccurrences(of: "\u{E100}\(index)\u{E101}", with: item)
        }
        return out
    }
}

nonisolated extension String {
    /// Every match of `pattern` replaced by what `body` makes of its
    /// groups — `[0]` the whole match, then each capture ("" if absent).
    func bridgeReplacing(_ pattern: String, options: NSRegularExpression.Options = [],
                         _ body: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return self }
        let source = self as NSString
        var out = self
        for match in regex.matches(in: self, range: NSRange(location: 0, length: source.length)).reversed() {
            var groups: [String] = []
            for index in 0..<match.numberOfRanges {
                let range = match.range(at: index)
                groups.append(range.location == NSNotFound ? "" : source.substring(with: range))
            }
            out = (out as NSString).replacingCharacters(in: match.range, with: body(groups))
        }
        return out
    }

    var bridgeTrimmed: String { trimmingCharacters(in: .whitespaces) }

    var bridgeIndent: Int { prefix { $0 == " " }.count }
}

nonisolated enum BridgeText {
    /// The index just past the bracket closing the one at `open`,
    /// strings and nesting respected; nil when it never closes.
    static func closing(in characters: [Character], from open: Int) -> Int? {
        let pairs: [Character: Character] = ["(": ")", "[": "]", "{": "}"]
        guard open < characters.count, let first = pairs[characters[open]] else { return nil }
        var stack: [Character] = [first]
        var index = open + 1
        var inString = false
        while index < characters.count {
            let character = characters[index]
            if inString {
                if character == "\\" { index += 2; continue }
                if character == "\"" { inString = false }
            } else if character == "\"", stack.last == ")" {
                inString = true
            } else if let close = pairs[character] {
                stack.append(close)
            } else if character == stack.last {
                stack.removeLast()
                if stack.isEmpty { return index + 1 }
            }
            index += 1
        }
        return nil
    }

    /// Top-level comma-separated arguments of a call's inside.
    static func arguments(_ inside: String) -> [String] {
        let characters = Array(inside)
        var out: [String] = []
        var current = ""
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if "([{".contains(character), let end = closing(in: characters, from: index) {
                current += String(characters[index..<end])
                index = end
                continue
            }
            if character == "\"" {
                var end = index + 1
                while end < characters.count, characters[end] != "\"" {
                    if characters[end] == "\\" { end += 1 }
                    end += 1
                }
                current += String(characters[index..<min(end + 1, characters.count)])
                index = end + 1
                continue
            }
            if character == "," {
                out.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
            } else {
                current.append(character)
            }
            index += 1
        }
        let last = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !last.isEmpty { out.append(last) }
        return out
    }

    /// `name: value` arguments by name; positional ones keep their order.
    static func namedArguments(_ inside: String) -> (named: [String: String], positional: [String]) {
        var named: [String: String] = [:]
        var positional: [String] = []
        for argument in arguments(inside) {
            if let match = argument.firstMatch(of: #/^([A-Za-z][\w-]*)\s*:\s*(.*)$/#.dotMatchesNewlines()),
               !argument.hasPrefix("\"") {
                named[String(match.1)] = String(match.2).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                positional.append(argument)
            }
        }
        return (named, positional)
    }

    static func unquoted(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") {
            return String(trimmed.dropFirst().dropLast())
                .replacingOccurrences(of: "\\\"", with: "\"")
        }
        return trimmed
    }

    /// A pipe table from rows, the first the header.
    static func pipeTable(_ rows: [[String]], caption: String?) -> [String] {
        let columns = rows.map(\.count).max() ?? 0
        guard columns > 0, let header = rows.first else { return [] }
        func line(_ cells: [String]) -> String {
            "| " + (0..<columns).map { column in
                (column < cells.count ? cells[column] : "")
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "|", with: "\\|")
            }.joined(separator: " | ") + " |"
        }
        var out = ["", line(header), "|" + Array(repeating: "---|", count: columns).joined()]
        out += rows.dropFirst().map(line)
        if let caption, !caption.isEmpty { out += ["", "Table: \(caption)"] }
        out.append("")
        return out
    }
}

// MARK: - Typst

/// Typst (typst.app) as Markdown: `=` headings, `*strong*`, `_emph_`,
/// lists and term lists, raw blocks, `$…$` maths translated to TeX,
/// `@key` and `#cite(<key>)` citations, `#footnote[…]`, `#link`,
/// `#figure(image(…))`, `#table(…)`, `#quote`, and the front matter of
/// `#set document(…)` or a template's `#show: x.with(…)`, including its
/// `bibliography(…)`.
nonisolated enum TypstBridge {

    static func markdown(from source: String) -> Bridged {
        var front = BridgeFrontMatter()
        let text = strippingComments(source.replacingOccurrences(of: "\r\n", with: "\n"))
        let labels = Set(text.matches(of: #/<([A-Za-z0-9_:.\-]+)>/#).map { String($0.1) })
        var out: [String] = []
        let lines = text.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.bridgeTrimmed
            index += 1

            // Raw blocks pass through as they are.
            if trimmed.hasPrefix("```") {
                out.append(trimmed)
                while index < lines.count {
                    let raw = lines[index]
                    index += 1
                    out.append(raw)
                    if raw.bridgeTrimmed.hasPrefix("```") { break }
                }
                continue
            }

            // A code-mode call at the head of a line may run over many:
            // gather it whole before reading it.
            if trimmed.hasPrefix("#") {
                var call = trimmed
                while !balanced(call), index < lines.count {
                    call += "\n" + lines[index]
                    index += 1
                }
                out.append(contentsOf: block(call, front: &front, labels: labels))
                continue
            }

            if let heading = trimmed.firstMatch(of: #/^(=+)\s+(.*)$/#) {
                let words = String(heading.2).bridgeReplacing(#"\s*<[A-Za-z0-9_:.\-]+>\s*$"#) { _ in "" }
                out.append(String(repeating: "#", count: heading.1.count) + " " + inline(words, labels: labels))
                continue
            }
            if let term = trimmed.firstMatch(of: #/^/\s+([^:]+):\s*(.*)$/#) {
                out.append("- **\(inline(String(term.1), labels: labels))**: \(inline(String(term.2), labels: labels))")
                continue
            }
            if trimmed.hasPrefix("+ ") {
                out.append("1. " + inline(String(trimmed.dropFirst(2)), labels: labels))
                continue
            }
            // A line break `\` ends the line; the words run on.
            let words = trimmed.hasSuffix(" \\") ? String(trimmed.dropLast(2)) : trimmed
            out.append(words.isEmpty ? "" : inline(words, labels: labels))
        }
        let body = out.joined(separator: "\n")
        return Bridged(markdown: front.yaml + displayMathBlocks(body))
    }

    /// `/* … */` and `// …` comments — never inside a string or a URL.
    static func strippingComments(_ text: String) -> String {
        text.bridgeReplacing(#"/\*[\s\S]*?\*/"#) { _ in "" }
            .components(separatedBy: "\n")
            .map { line in
                line.bridgeReplacing(#"(^|[^:"\\])//.*$"#) { $0[1] }
            }
            .joined(separator: "\n")
    }

    private static func balanced(_ text: String) -> Bool {
        var depth = 0
        var inString = false
        var previous: Character = " "
        for character in text {
            if inString {
                if character == "\"", previous != "\\" { inString = false }
            } else if character == "\"" {
                inString = true
            } else if "([{".contains(character) {
                depth += 1
            } else if ")]}".contains(character) {
                depth -= 1
            }
            previous = character
        }
        return depth <= 0
    }

    // MARK: Block calls

    private static func block(_ call: String, front: inout BridgeFrontMatter,
                              labels: Set<String>) -> [String] {
        let name = call.firstMatch(of: #/^#([A-Za-z][\w.]*)/#).map { String($0.1) } ?? ""
        switch name {
        case "set":
            if call.hasPrefix("#set document"), let args = callArguments(call, after: "document") {
                applyFrontMatter(args, to: &front)
            }
            return []
        case "show":
            // A template's `#show: name.with(title: …, authors: …)`.
            if let range = call.range(of: ".with(") {
                let characters = Array(call)
                let open = call.distance(from: call.startIndex, to: range.upperBound) - 1
                if let end = BridgeText.closing(in: characters, from: open) {
                    applyFrontMatter(String(characters[(open + 1)..<(end - 1)]), to: &front)
                }
            }
            return []
        case "import", "include", "let", "pagebreak", "v", "h", "outline", "counter",
             "state", "context", "colbreak", "place", "metadata":
            return []
        case "bibliography":
            if let args = callArguments(call, after: "bibliography") {
                front.bibliography += bibliographyFiles(args)
            }
            return []
        case "title":
            if let content = trailingContent(call) {
                front.title = front.title ?? inline(content, labels: labels)
            }
            return []
        case "figure":
            return figure(call, labels: labels)
        case "image":
            if let args = callArguments(call, after: "image") {
                let parsed = BridgeText.namedArguments(args)
                if let path = parsed.positional.first.map(BridgeText.unquoted) {
                    return ["", "![\(parsed.named["alt"].map(BridgeText.unquoted) ?? "")](\(path))", ""]
                }
            }
            return []
        case "table":
            return table(call, caption: nil, labels: labels)
        case "quote":
            guard let content = trailingContent(call) else { return [] }
            var lines = ["", "> " + inline(content, labels: labels)]
            if let args = callArguments(call, after: "quote"),
               let attribution = BridgeText.namedArguments(args).named["attribution"] {
                lines.append("> — " + inline(strippedContent(attribution), labels: labels))
            }
            return lines + [""]
        default:
            // Anything else keeps its words.
            return [inline(call, labels: labels)]
        }
    }

    /// The inside of `#name(…)`.
    private static func callArguments(_ call: String, after name: String) -> String? {
        guard let range = call.range(of: name + "(") else { return nil }
        let characters = Array(call)
        let open = call.distance(from: call.startIndex, to: range.upperBound) - 1
        guard let end = BridgeText.closing(in: characters, from: open) else { return nil }
        return String(characters[(open + 1)..<(end - 1)])
    }

    /// The `[…]` content block closing a call.
    private static func trailingContent(_ call: String) -> String? {
        let characters = Array(call)
        guard let open = characters.firstIndex(of: "[") else { return nil }
        // Skip past a (…) argument list first.
        var start = open
        if let paren = characters.firstIndex(of: "("), paren < open,
           let end = BridgeText.closing(in: characters, from: paren) {
            guard let next = characters[end...].firstIndex(of: "[") else { return nil }
            start = next
        }
        guard let end = BridgeText.closing(in: characters, from: start) else { return nil }
        return String(characters[(start + 1)..<(end - 1)])
    }

    /// A content value: `[words]` or `"words"`, as its words.
    private static func strippedContent(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
            return String(trimmed.dropFirst().dropLast())
        }
        return BridgeText.unquoted(trimmed)
    }

    private static func applyFrontMatter(_ args: String, to front: inout BridgeFrontMatter) {
        let parsed = BridgeText.namedArguments(args).named
        if let title = parsed["title"] { front.title = strippedContent(title) }
        if let subtitle = parsed["subtitle"] { front.subtitle = strippedContent(subtitle) }
        if let abstract = parsed["abstract"] { front.abstract = strippedContent(abstract) }
        for key in ["author", "authors"] {
            guard let value = parsed[key] else { continue }
            front.authors = people(value)
        }
        for key in ["keywords", "index-terms"] {
            guard let value = parsed[key] else { continue }
            let inside = value.hasPrefix("(") ? String(value.dropFirst().dropLast()) : value
            front.keywords = BridgeText.arguments(inside).map(strippedContent).filter { !$0.isEmpty }
        }
        if let date = parsed["date"] {
            if let year = date.firstMatch(of: #/year:\s*(\d{4})/#) {
                let month = date.firstMatch(of: #/month:\s*(\d{1,2})/#).map { Int($0.1) ?? 1 }
                let day = date.firstMatch(of: #/day:\s*(\d{1,2})/#).map { Int($0.1) ?? 1 }
                front.date = String(year.1)
                    + (month.map { String(format: "-%02d", $0) } ?? "")
                    + (day.map { String(format: "-%02d", $0) } ?? "")
            } else {
                front.date = strippedContent(date)
            }
        }
        if let bibliography = parsed["bibliography"] {
            front.bibliography += bibliographyFiles(bibliography)
        }
    }

    /// "Name", ("A", "B"), or ((name: "A", …), …) as names.
    private static func people(_ value: String) -> [String] {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("(") else { return [strippedContent(trimmed)].filter { !$0.isEmpty } }
        return BridgeText.arguments(String(trimmed.dropFirst().dropLast())).compactMap { item in
            if item.hasPrefix("("), let name = BridgeText.namedArguments(
                String(item.dropFirst().dropLast())).named["name"] {
                return strippedContent(name)
            }
            let name = strippedContent(item)
            return name.isEmpty ? nil : name
        }
    }

    /// `"a.bib"`, `("a.bib", "b.bib")`, or `bibliography("a.bib", …)`.
    private static func bibliographyFiles(_ value: String) -> [String] {
        value.matches(of: #/"([^"]+\.(?:bib|json|ris|yml|yaml))"/#).map { String($0.1) }
            .filter { !$0.hasSuffix(".yml") && !$0.hasSuffix(".yaml") }
    }

    private static func figure(_ call: String, labels: Set<String>) -> [String] {
        guard let args = callArguments(call, after: "figure") else { return [] }
        let parsed = BridgeText.namedArguments(args)
        let caption = parsed.named["caption"].map { inline(strippedContent($0), labels: labels) }
        guard let body = parsed.positional.first else { return [] }
        if body.hasPrefix("image("), let inside = callArguments(body, after: "image") {
            let path = BridgeText.namedArguments(inside).positional.first.map(BridgeText.unquoted) ?? ""
            return ["", "![\(caption ?? "")](\(path))", ""]
        }
        if body.hasPrefix("table(") {
            return table("#" + body, caption: caption, labels: labels)
        }
        return [inline(strippedContent(body), labels: labels)] + (caption.map { ["", $0] } ?? [])
    }

    private static func table(_ call: String, caption: String?, labels: Set<String>) -> [String] {
        guard let args = callArguments(call, after: "table") else { return [] }
        let parsed = BridgeText.namedArguments(args)
        var columns = 1
        if let spec = parsed.named["columns"] {
            if let count = Int(spec) {
                columns = count
            } else if spec.hasPrefix("(") {
                columns = max(1, BridgeText.arguments(String(spec.dropFirst().dropLast())).count)
            }
        }
        var cells: [String] = []
        for argument in parsed.positional {
            if argument.hasPrefix("table.header("),
               let inside = callArguments(argument, after: "table.header") {
                cells += BridgeText.arguments(inside).map { inline(strippedContent($0), labels: labels) }
            } else if argument.hasPrefix("table.") {
                continue
            } else {
                cells.append(inline(strippedContent(argument), labels: labels))
            }
        }
        guard !cells.isEmpty else { return [] }
        let rows = stride(from: 0, to: cells.count, by: columns).map {
            Array(cells[$0..<min($0 + columns, cells.count)])
        }
        return BridgeText.pipeTable(rows, caption: caption)
    }

    // MARK: Inline

    static func inline(_ text: String, labels: Set<String>) -> String {
        let stash = BridgeStash()
        // Raw and maths first, held out of every later pass.
        var out = text.bridgeReplacing("`([^`]+)`") { stash.hold($0[0]) }
        out = maths(in: out, stash: stash)
        // Calls with content: footnotes, links, citations, markup.
        out = rewritingCalls(out, labels: labels, stash: stash)
        // @key[supplement] and @key — a reference to a label the
        // document defines keeps its words; anything else is a citation.
        out = out.bridgeReplacing(#"(?<![\w@.])@([A-Za-z0-9_:\-]+(?:\.[A-Za-z0-9_\-]+)*)(\[([^\]]*)\])?"#) { groups in
            let key = groups[1]
            if labels.contains(key) { return key.replacingOccurrences(of: "-", with: " ") }
            return stash.hold(groups[3].isEmpty ? "[@\(key)]" : "[@\(key), \(groups[3])]")
        }
        out = out.bridgeReplacing(#"\s*<[A-Za-z0-9_:.\-]+>"#) { _ in "" }
        out = out.bridgeReplacing(#"(?<![\w*\\])\*(?=\S)([^*\n]+?)(?<=\S)\*(?![\w*])"#) { "**\($0[1])**" }
        out = out.bridgeReplacing(#"(?<![\w_\\])_(?=\S)([^_\n]+?)(?<=\S)_(?![\w_])"#) { "*\($0[1])*" }
        out = out.bridgeReplacing(#"\\([#@$<>~])"#) { $0[1] }
            .replacingOccurrences(of: "~", with: "\u{00A0}")
        return stash.restore(out)
    }

    /// `#footnote[…]`, `#link("…")[…]`, `#cite(<key>)`, and the markup
    /// calls whose content is simply their words.
    private static func rewritingCalls(_ text: String, labels: Set<String>, stash: BridgeStash) -> String {
        let characters = Array(text)
        var index = 0
        var out = ""
        while index < characters.count {
            guard characters[index] == "#",
                  let match = String(characters[index...]).firstMatch(of: #/^#([A-Za-z][\w.]*)/#) else {
                out.append(characters[index])
                index += 1
                continue
            }
            let name = String(match.1)
            var cursor = index + 1 + name.count
            var args: String?
            if cursor < characters.count, characters[cursor] == "(",
               let end = BridgeText.closing(in: characters, from: cursor) {
                args = String(characters[(cursor + 1)..<(end - 1)])
                cursor = end
            }
            var content: String?
            if cursor < characters.count, characters[cursor] == "[",
               let end = BridgeText.closing(in: characters, from: cursor) {
                content = String(characters[(cursor + 1)..<(end - 1)])
                cursor = end
            }
            let words = content.map { inline($0, labels: labels) } ?? ""
            let replacement: String
            switch name {
            case "footnote":
                replacement = stash.hold("^[\(words)]")
            case "link":
                let url = args.map { BridgeText.unquoted(BridgeText.arguments($0).first ?? "") } ?? ""
                replacement = stash.hold(content == nil ? url : "[\(words)](\(url))")
            case "cite":
                let parsed = BridgeText.namedArguments(args ?? "")
                let keys = parsed.positional.compactMap { argument -> String? in
                    if let key = argument.firstMatch(of: #/<([^>]+)>/#) { return String(key.1) }
                    if let key = argument.firstMatch(of: #/label\("([^"]+)"\)/#) { return String(key.1) }
                    return nil
                }
                let supplement = parsed.named["supplement"].map(strippedContent)
                replacement = keys.isEmpty ? "" : stash.hold(
                    "[" + keys.map { "@\($0)" }.joined(separator: "; ")
                        + (supplement.map { ", \($0)" } ?? "") + "]")
            case "strong":
                replacement = "**\(words)**"
            case "emph":
                replacement = "*\(words)*"
            case "h", "v", "linebreak", "pagebreak", "colbreak":
                replacement = name == "linebreak" ? " " : ""
            case "image":
                replacement = ""
            default:
                // #text(…)[…], #underline[…], #smallcaps[…], #box[…] …
                replacement = content == nil ? "" : words
            }
            out += replacement
            index = cursor
        }
        return out
    }

    /// `$…$` spans as TeX: a span with space inside both dollars is
    /// display maths, standing as its own block; one without is inline.
    /// Typst's maths the translator does not know stays as raw words.
    private static func maths(in text: String, stash: BridgeStash) -> String {
        guard text.contains("$") else { return text }
        let characters = Array(text)
        var out = ""
        var index = 0
        while index < characters.count {
            guard characters[index] == "$", index == 0 || characters[index - 1] != "\\",
                  let end = characters[(index + 1)...].firstIndex(where: { $0 == "$" }) else {
                out.append(characters[index])
                index += 1
                continue
            }
            let inner = String(characters[(index + 1)..<end])
            let display = inner.first?.isWhitespace == true && inner.last?.isWhitespace == true
            if let tex = TypstMath.tex(from: inner) {
                out += stash.hold(display ? "\u{E102}\(tex)\u{E103}" : "$\(tex)$")
            } else {
                out += stash.hold("`\(inner.trimmingCharacters(in: .whitespaces))`")
            }
            index = end + 1
        }
        return out
    }

    /// Display maths lifted into `$$` blocks of their own lines.
    private static func displayMathBlocks(_ text: String) -> String {
        text.bridgeReplacing("\u{E102}([\\s\\S]*?)\u{E103}") { "\n\n$$\n\($0[1])\n$$\n\n" }
    }
}

/// Typst's maths notation as TeX — letters and numbers, `_`/`^` scripts
/// with `( )` groups, `a/b` fractions, named symbols (`alpha`, `sum`,
/// `arrow.r`, `RR`), the common functions (`sqrt`, `frac`, `abs`, `vec`,
/// `mat`, `cases`, accents, font variants), strings as text, and `&` /
/// `\` alignment. Nil for anything else, so the words stay as written.
nonisolated enum TypstMath {

    static func tex(from source: String) -> String? {
        var parser = Parser(Array(source))
        guard let grouped = try? parser.sequence(until: []), parser.atEnd else { return nil }
        // Parentheses the flow kept lose their group marks.
        let body = grouped.replacingOccurrences(of: "\u{E110}", with: "")
            .replacingOccurrences(of: "\u{E111}", with: "")
        if parser.aligned {
            return "\\begin{aligned}\(body)\\end{aligned}"
        }
        return body
    }

    struct Failure: Error {}

    static let symbols: [String: String] = [
        "alpha": "\\alpha", "beta": "\\beta", "gamma": "\\gamma", "delta": "\\delta",
        "epsilon": "\\varepsilon", "epsilon.alt": "\\epsilon", "zeta": "\\zeta", "eta": "\\eta",
        "theta": "\\theta", "theta.alt": "\\vartheta", "iota": "\\iota", "kappa": "\\kappa",
        "lambda": "\\lambda", "mu": "\\mu", "nu": "\\nu", "xi": "\\xi", "pi": "\\pi",
        "rho": "\\rho", "sigma": "\\sigma", "tau": "\\tau", "upsilon": "\\upsilon",
        "phi": "\\varphi", "phi.alt": "\\phi", "chi": "\\chi", "psi": "\\psi", "omega": "\\omega",
        "Gamma": "\\Gamma", "Delta": "\\Delta", "Theta": "\\Theta", "Lambda": "\\Lambda",
        "Xi": "\\Xi", "Pi": "\\Pi", "Sigma": "\\Sigma", "Phi": "\\Phi", "Psi": "\\Psi",
        "Omega": "\\Omega",
        "infinity": "\\infty", "oo": "\\infty", "sum": "\\sum", "product": "\\prod",
        "integral": "\\int", "integral.double": "\\iint", "integral.triple": "\\iiint",
        "integral.cont": "\\oint", "partial": "\\partial", "nabla": "\\nabla",
        "dot.c": "\\cdot", "dot.op": "\\cdot", "times": "\\times", "div": "\\div",
        "plus.minus": "\\pm", "minus.plus": "\\mp", "approx": "\\approx", "prop": "\\propto",
        "equiv": "\\equiv", "tilde.op": "\\sim", "eq.not": "\\neq", "lt.eq": "\\leq",
        "gt.eq": "\\geq", "lt": "<", "gt": ">", "lt.double": "\\ll", "gt.double": "\\gg",
        "in": "\\in", "in.not": "\\notin", "subset": "\\subset", "subset.eq": "\\subseteq",
        "supset": "\\supset", "supset.eq": "\\supseteq", "union": "\\cup", "sect": "\\cap",
        "union.big": "\\bigcup", "sect.big": "\\bigcap", "forall": "\\forall",
        "exists": "\\exists", "emptyset": "\\emptyset", "and": "\\wedge", "or": "\\vee",
        "not": "\\neg", "arrow.r": "\\rightarrow", "arrow.l": "\\leftarrow",
        "arrow.l.r": "\\leftrightarrow", "arrow.r.double": "\\Rightarrow",
        "arrow.l.double": "\\Leftarrow", "arrow.l.r.double": "\\Leftrightarrow",
        "arrow.r.bar": "\\mapsto", "arrow.t": "\\uparrow", "arrow.b": "\\downarrow",
        "dots": "\\ldots", "dots.h": "\\ldots", "dots.c": "\\cdots", "dots.v": "\\vdots",
        "dots.down": "\\ddots", "ell": "\\ell", "planck.reduce": "\\hbar", "hbar": "\\hbar",
        "angle": "\\angle", "perp": "\\perp", "parallel": "\\parallel", "divides": "\\mid",
        "prime": "'", "degree": "^\\circ", "circle.small": "\\circ", "star.op": "\\star",
        "ast.op": "\\ast", "quad": "\\quad", "wide": "\\qquad", "thin": "\\,", "med": "\\:",
        "thick": "\\;", "space": "\\ ", "RR": "\\mathbb{R}", "NN": "\\mathbb{N}",
        "ZZ": "\\mathbb{Z}", "QQ": "\\mathbb{Q}", "CC": "\\mathbb{C}", "aleph": "\\aleph",
        "top": "\\top", "bot": "\\bot", "tack.r": "\\vdash", "models": "\\models",
        "colon.eq": "\\coloneqq", "eq.def": "\\triangleq",
    ]

    static let operatorNames: Set<String> = [
        "sin", "cos", "tan", "cot", "sec", "csc", "arcsin", "arccos", "arctan", "sinh",
        "cosh", "tanh", "log", "ln", "lg", "exp", "lim", "max", "min", "sup", "inf", "det",
        "gcd", "deg", "dim", "ker", "arg", "mod", "liminf", "limsup",
    ]

    static let accents: [String: String] = [
        "hat": "\\hat", "tilde": "\\tilde", "overline": "\\overline", "macron": "\\bar",
        "arrow": "\\vec", "dot": "\\dot", "dot.double": "\\ddot", "breve": "\\breve",
        "acute": "\\acute", "grave": "\\grave", "caron": "\\check", "underline": "\\underline",
        "bold": "\\mathbf", "italic": "\\mathit", "upright": "\\mathrm", "cal": "\\mathcal",
        "bb": "\\mathbb", "frak": "\\mathfrak", "sans": "\\mathsf", "mono": "\\mathtt",
        "sqrt": "\\sqrt", "floor": "", "ceil": "", "abs": "", "norm": "", "limits": "",
        "upright.bold": "\\mathbf",
    ]

    struct Parser {
        let characters: [Character]
        var index = 0
        var aligned = false

        init(_ characters: [Character]) { self.characters = characters }

        var atEnd: Bool { index >= characters.count }

        mutating func skipSpaces() {
            while !atEnd, characters[index] == " " || characters[index] == "\n" || characters[index] == "\t" {
                index += 1
            }
        }

        /// Atoms until one of the stop characters (unconsumed) or the end.
        mutating func sequence(until stops: Set<Character>) throws -> String {
            var atoms: [String] = []
            while true {
                skipSpaces()
                guard !atEnd, !stops.contains(characters[index]) else { break }
                let character = characters[index]
                if character == "/" {
                    // a/b — the atoms either side, their parentheses gone.
                    index += 1
                    guard let numerator = atoms.popLast() else { throw Failure() }
                    let denominator = try scripted()
                    atoms.append("\\frac{\(Self.ungrouped(numerator))}{\(Self.ungrouped(denominator))}")
                    continue
                }
                if character == "&" {
                    index += 1
                    aligned = true
                    atoms.append("&")
                    continue
                }
                if character == "\\" {
                    index += 1
                    if !atEnd, characters[index] == " " || characters[index] == "\n" {
                        aligned = true
                        atoms.append("\\\\")
                        continue
                    }
                    guard !atEnd else { throw Failure() }
                    atoms.append(String(characters[index]))
                    index += 1
                    continue
                }
                atoms.append(try scripted())
            }
            return atoms.joined(separator: " ")
        }

        /// A parenthesised group as TeX: kept with its parentheses in the
        /// flow, which `ungrouped` removes where Typst drops them.
        static func ungrouped(_ atom: String) -> String {
            if atom.hasPrefix("\u{E110}("), atom.hasSuffix(")\u{E111}") {
                return String(atom.dropFirst(2).dropLast(2))
            }
            return atom.replacingOccurrences(of: "\u{E110}", with: "")
                .replacingOccurrences(of: "\u{E111}", with: "")
        }

        mutating func scripted() throws -> String {
            var base = try atom()
            while true {
                guard !atEnd, characters[index] == "_" || characters[index] == "^" else { break }
                let mark = characters[index]
                index += 1
                let script = try atom()
                base += "\(mark){\(Self.ungrouped(script))}"
            }
            return base
        }

        mutating func atom() throws -> String {
            skipSpaces()
            guard !atEnd else { throw Failure() }
            let character = characters[index]
            if character == "(" || character == "[" {
                let close: Character = character == "(" ? ")" : "]"
                index += 1
                let inner = try sequence(until: [close])
                guard !atEnd, characters[index] == close else { throw Failure() }
                index += 1
                return "\u{E110}\(character)\(inner)\(close)\u{E111}"
            }
            if character == "{" {
                index += 1
                let inner = try sequence(until: ["}"])
                guard !atEnd else { throw Failure() }
                index += 1
                return "\\{\(inner)\\}"
            }
            if character == "\"" {
                index += 1
                var text = ""
                while !atEnd, characters[index] != "\"" { text.append(characters[index]); index += 1 }
                guard !atEnd else { throw Failure() }
                index += 1
                return "\\text{\(text)}"
            }
            if character.isNumber {
                var number = ""
                while !atEnd, characters[index].isNumber
                        || (characters[index] == "." && index + 1 < characters.count
                            && characters[index + 1].isNumber) {
                    number.append(characters[index])
                    index += 1
                }
                return number
            }
            if character.isLetter {
                var word = ""
                while !atEnd, characters[index].isLetter
                        || (characters[index] == "." && index + 1 < characters.count
                            && characters[index + 1].isLetter) {
                    word.append(characters[index])
                    index += 1
                }
                return try named(word)
            }
            // Operators, the multi-character ones first.
            for (typed, tex) in [("->", "\\to"), ("=>", "\\Rightarrow"), ("<=", "\\leq"),
                                 (">=", "\\geq"), ("!=", "\\neq"), ("<-", "\\leftarrow"),
                                 ("...", "\\ldots"), (":=", "\\coloneqq"), ("<<", "\\ll"),
                                 (">>", "\\gg"), ("||", "\\|")] {
                let run = Array(typed)
                if index + run.count <= characters.count,
                   Array(characters[index..<(index + run.count)]) == run {
                    index += run.count
                    return tex
                }
            }
            index += 1
            switch character {
            case "*": return "\\ast"
            case "'": return "'"
            case "+", "-", "=", "<", ">", "|", "!", ",", ";", ":", ".", "?": return String(character)
            default:
                // A Unicode symbol typed straight in.
                if character.isSymbol || character.isMathSymbol || character.isPunctuation {
                    return String(character)
                }
                throw Failure()
            }
        }

        /// A named symbol, function or call.
        mutating func named(_ word: String) throws -> String {
            let calls = !atEnd && characters[index] == "("
            if calls {
                switch word {
                case "frac", "binom", "root":
                    let args = try callArguments()
                    guard args.count == 2 else { throw Failure() }
                    return word == "root" ? "\\sqrt[\(args[0])]{\(args[1])}"
                        : "\\\(word){\(args[0])}{\(args[1])}"
                case "abs":
                    let args = try callArguments()
                    return "\\left|\(args.joined(separator: ", "))\\right|"
                case "norm":
                    let args = try callArguments()
                    return "\\left\\|\(args.joined(separator: ", "))\\right\\|"
                case "floor":
                    return "\\lfloor \(try callArguments().joined(separator: ", ")) \\rfloor"
                case "ceil":
                    return "\\lceil \(try callArguments().joined(separator: ", ")) \\rceil"
                case "lr":
                    return try callArguments().joined(separator: ", ")
                case "op":
                    let args = try callArguments()
                    return "\\operatorname{\(args.first?.replacingOccurrences(of: "\\text{", with: "").replacingOccurrences(of: "}", with: "") ?? "")}"
                case "vec":
                    let args = try callArguments()
                    return "\\begin{pmatrix}\(args.joined(separator: " \\\\ "))\\end{pmatrix}"
                case "mat":
                    let rows = try matrixRows()
                    return "\\begin{pmatrix}\(rows.map { $0.joined(separator: " & ") }.joined(separator: " \\\\ "))\\end{pmatrix}"
                case "cases":
                    let args = try callArguments()
                    return "\\begin{cases}\(args.joined(separator: " \\\\ "))\\end{cases}"
                case "underbrace", "overbrace":
                    let args = try callArguments()
                    guard let first = args.first else { throw Failure() }
                    let note = args.count > 1 ? (word == "underbrace" ? "_{\(args[1])}" : "^{\(args[1])}") : ""
                    return "\\\(word){\(first)}\(note)"
                default:
                    if let command = TypstMath.accents[word], !command.isEmpty {
                        let args = try callArguments()
                        guard args.count == 1 else { throw Failure() }
                        return "\(command){\(args[0])}"
                    }
                }
            }
            if word.count == 1 { return word }
            if let symbol = TypstMath.symbols[word] { return symbol }
            if TypstMath.operatorNames.contains(word) { return "\\\(word)" }
            throw Failure()
        }

        mutating func callArguments() throws -> [String] {
            guard !atEnd, characters[index] == "(",
                  let end = BridgeText.closing(in: characters, from: index) else { throw Failure() }
            let inside = String(characters[(index + 1)..<(end - 1)])
            index = end
            return try BridgeText.arguments(inside).map { argument in
                var inner = Parser(Array(argument))
                let body = try inner.sequence(until: [])
                guard inner.atEnd else { throw Failure() }
                return Parser.ungrouped(body)
            }
        }

        /// `mat(1, 2; 3, 4)`: rows by `;`, cells by `,`.
        mutating func matrixRows() throws -> [[String]] {
            guard !atEnd, characters[index] == "(",
                  let end = BridgeText.closing(in: characters, from: index) else { throw Failure() }
            let inside = String(characters[(index + 1)..<(end - 1)])
            index = end
            return try inside.components(separatedBy: ";").map { row in
                try BridgeText.arguments(row).map { cell in
                    var inner = Parser(Array(cell))
                    let body = try inner.sequence(until: [])
                    guard inner.atEnd else { throw Failure() }
                    return Parser.ungrouped(body)
                }
            }
        }
    }
}

nonisolated private extension Character {
    var isMathSymbol: Bool { unicodeScalars.allSatisfy { $0.properties.isMath } }
}

// MARK: - AsciiDoc

/// AsciiDoc (Asciidoctor) as Markdown: the document header (title,
/// author line, revision, attributes), `==` sections, delimited blocks
/// (listing, literal, quote, example, sidebar, passthrough maths),
/// admonitions, lists, `image::`, `|===` tables, and the inline forms —
/// `footnote:[…]`, `cite:[…]` (asciidoctor-bibtex, its `:bibtex-file:`
/// the bibliography), cross-references, links, `stem:[…]` and emphasis.
nonisolated enum AsciiDocBridge {

    static func markdown(from source: String) -> Bridged {
        var front = BridgeFrontMatter()
        var attributes: [String: String] = [:]
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var out: [String] = []
        var index = 0
        var pendingAttributes: [String] = []
        var pendingTitle: String?

        // The header: `= Title`, then author and revision lines and
        // attributes, up to the first blank line.
        while index < lines.count, lines[index].bridgeTrimmed.isEmpty
                || lines[index].hasPrefix("//") && !lines[index].hasPrefix("////") {
            index += 1
        }
        if index < lines.count, lines[index].hasPrefix("= ") {
            front.title = String(lines[index].dropFirst(2)).bridgeTrimmed
            index += 1
            var headerLine = 0
            while index < lines.count, !lines[index].bridgeTrimmed.isEmpty {
                let line = lines[index]
                index += 1
                if let attribute = line.firstMatch(of: #/^:([\w-]+!?):\s*(.*)$/#) {
                    attributes[String(attribute.1)] = String(attribute.2)
                    continue
                }
                if line.hasPrefix("//") { continue }
                headerLine += 1
                if headerLine == 1 {
                    front.authors = line.components(separatedBy: ";")
                        .map { $0.bridgeReplacing(#"<[^>]*>"#) { _ in "" }.bridgeTrimmed }
                        .filter { !$0.isEmpty }
                } else if headerLine == 2 {
                    // "v1.0, 2024-05-01: remark"
                    if let date = line.firstMatch(of: #/\d{4}-\d{2}-\d{2}/#) { front.date = String(date.0) }
                }
            }
        }

        func substituted(_ text: String) -> String {
            text.bridgeReplacing(#"\{([\w-]+)\}"#) { groups in attributes[groups[1]] ?? groups[0] }
        }
        func inline(_ text: String) -> String { AsciiDocBridge.inline(substituted(text)) }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.bridgeTrimmed
            index += 1

            if trimmed.hasPrefix("////") {
                while index < lines.count, !lines[index].bridgeTrimmed.hasPrefix("////") { index += 1 }
                index += 1
                continue
            }
            if trimmed.hasPrefix("//") { continue }
            if let attribute = trimmed.firstMatch(of: #/^:([\w-]+!?):\s*(.*)$/#) {
                attributes[String(attribute.1)] = String(attribute.2)
                continue
            }
            if trimmed.isEmpty {
                out.append("")
                continue
            }
            // Anchors carry no words; attribute lists wait for their block.
            if trimmed.hasPrefix("[["), trimmed.hasSuffix("]]") { continue }
            if trimmed.hasPrefix("["), trimmed.hasSuffix("]"), !trimmed.hasPrefix("[[") {
                if !trimmed.hasPrefix("[#") || trimmed.contains(",") { pendingAttributes.append(String(trimmed.dropFirst().dropLast())) }
                continue
            }
            if trimmed.firstMatch(of: #/^\.[^\s.]/#) != nil {
                pendingTitle = String(trimmed.dropFirst())
                continue
            }
            let style = pendingAttributes.last?.components(separatedBy: ",").first?.bridgeTrimmed ?? ""

            // Delimited blocks.
            if let fence = trimmed.firstMatch(of: #/^(-{4,}|\.{4,}|_{4,}|={4,}|\*{4,}|\+{4,}|`{3,})$/#) {
                let marker = String(fence.1)
                var body: [String] = []
                while index < lines.count, lines[index].bridgeTrimmed != marker {
                    body.append(lines[index])
                    index += 1
                }
                index += 1
                defer { pendingAttributes = []; pendingTitle = nil }
                switch marker.first {
                case "-", "`", ".":
                    // [source,python] names the language.
                    let parts = pendingAttributes.last?.components(separatedBy: ",").map(\.bridgeTrimmed) ?? []
                    let language = parts.first == "source" && parts.count > 1 ? parts[1] : ""
                    if let title = pendingTitle { out += ["", "**\(inline(title))**"] }
                    out += ["", "```\(language)"] + body + ["```", ""]
                case "_":
                    out.append("")
                    out += body.map { $0.bridgeTrimmed.isEmpty ? ">" : "> " + inline($0.bridgeTrimmed) }
                    let parts = pendingAttributes.last?.components(separatedBy: ",").map(\.bridgeTrimmed) ?? []
                    if parts.first == "quote", parts.count > 1 {
                        out.append("> — " + parts.dropFirst().joined(separator: ", "))
                    }
                    out.append("")
                case "+":
                    if ["latexmath", "stem"].contains(style) {
                        out += ["", "$$", body.joined(separator: "\n")
                            .replacingOccurrences(of: "\\[", with: "").replacingOccurrences(of: "\\]", with: ""),
                                "$$", ""]
                    }
                default:
                    // Example, sidebar, admonition: their contents are
                    // AsciiDoc again — read in place.
                    let admonitions = ["NOTE", "TIP", "IMPORTANT", "WARNING", "CAUTION"]
                    var lead = pendingTitle.map { "**\(inline($0))**" }
                    if admonitions.contains(style) { lead = "**\(style.capitalized):**" }
                    let inner = markdown(from: "\n" + body.joined(separator: "\n"))
                    out.append("")
                    if let lead { out.append(lead) }
                    out.append(inner.markdown)
                }
                continue
            }

            // Tables.
            if trimmed.hasPrefix("|===") {
                var body: [String] = []
                while index < lines.count, !lines[index].bridgeTrimmed.hasPrefix("|===") {
                    body.append(lines[index])
                    index += 1
                }
                index += 1
                out += table(body, attributes: pendingAttributes, caption: pendingTitle.map(inline),
                             inline: inline)
                pendingAttributes = []
                pendingTitle = nil
                continue
            }

            if let image = trimmed.firstMatch(of: #/^image::([^\[]+)\[([^\]]*)\]$/#) {
                let alt = String(image.2).components(separatedBy: ",").first?.bridgeTrimmed ?? ""
                out += ["", "![\(inline(pendingTitle ?? alt))](\(image.1))", ""]
                pendingAttributes = []
                pendingTitle = nil
                continue
            }
            if trimmed.hasPrefix("include::") || trimmed.hasPrefix("toc::")
                || trimmed.hasPrefix("bibliography::") { continue }

            pendingAttributes = []
            pendingTitle = nil

            if let heading = trimmed.firstMatch(of: #/^(={1,6})\s+(.*)$/#) {
                out += ["", String(repeating: "#", count: heading.1.count) + " " + inline(String(heading.2)), ""]
                continue
            }
            if let admonition = trimmed.firstMatch(of: #/^(NOTE|TIP|IMPORTANT|WARNING|CAUTION):\s+(.*)$/#) {
                out.append("**\(String(admonition.1).capitalized):** " + inline(String(admonition.2)))
                continue
            }
            if let item = trimmed.firstMatch(of: #/^(\*+|-)\s+(.*)$/#) {
                out.append("- " + inline(String(item.2)))
                continue
            }
            if let item = trimmed.firstMatch(of: #/^(\.+|\d+\.)\s+(.*)$/#) {
                out.append("1. " + inline(String(item.2)))
                continue
            }
            if let term = trimmed.firstMatch(of: #/^(.+?)::(?:\s+(.*))?$/#), !trimmed.contains("://") {
                out.append("- **\(inline(String(term.1)))**: " + inline(term.2.map(String.init) ?? ""))
                continue
            }
            if trimmed == "+" { continue }
            let words = trimmed.hasSuffix(" +") ? String(trimmed.dropLast(2)) : trimmed
            out.append(inline(words))
        }

        if let file = attributes["bibtex-file"] { front.bibliography.append(file) }
        if let description = attributes["description"], front.abstract == nil { front.abstract = description }
        if let keywords = attributes["keywords"] {
            front.keywords = keywords.components(separatedBy: ",").map(\.bridgeTrimmed).filter { !$0.isEmpty }
        }
        if front.authors.isEmpty, let author = attributes["author"] { front.authors = [author] }
        if front.date == nil, let date = attributes["revdate"] { front.date = date }
        return Bridged(markdown: front.yaml + out.joined(separator: "\n"))
    }

    private static func table(_ body: [String], attributes: [String], caption: String?,
                              inline: (String) -> String) -> [String] {
        var columns = 0
        for attribute in attributes {
            if let spec = attribute.firstMatch(of: #/cols="?([^"\]]+)"?/#) {
                let value = String(spec.1)
                if let count = value.firstMatch(of: #/^(\d+)\*/#) {
                    columns = Int(count.1) ?? 0
                } else {
                    columns = value.components(separatedBy: ",").count
                }
            }
        }
        let headerOption = attributes.contains { $0.contains("header") }
        var cells: [String] = []
        var firstLineCells = 0
        var headerByBlank = false
        var sawFirstRow = false
        for (position, line) in body.enumerated() {
            let trimmed = line.bridgeTrimmed
            if trimmed.isEmpty {
                if sawFirstRow, position > 0, cells.count == firstLineCells { headerByBlank = true }
                continue
            }
            if trimmed.hasPrefix("|") {
                let parts = trimmed.dropFirst().components(separatedBy: "|").map(\.bridgeTrimmed)
                if !sawFirstRow { firstLineCells = parts.count; sawFirstRow = true }
                cells += parts.map(inline)
            } else if let last = cells.indices.last {
                cells[last] += " " + inline(trimmed)
            }
        }
        if columns == 0 { columns = max(firstLineCells, 1) }
        var rows = stride(from: 0, to: cells.count, by: columns).map {
            Array(cells[$0..<min($0 + columns, cells.count)])
        }
        // A table without a header row gets an empty one: pipe tables
        // always have one, and inventing words would be worse.
        if !(headerOption || headerByBlank) {
            rows.insert(Array(repeating: " ", count: columns), at: 0)
        }
        return BridgeText.pipeTable(rows, caption: caption)
    }

    static func inline(_ text: String) -> String {
        let stash = BridgeStash()
        var out = text.bridgeReplacing("`([^`]+)`") { stash.hold("`\($0[1])`") }
        out = out.bridgeReplacing(#"(?:stem|latexmath):\[((?:[^\]\\]|\\.)*)\]"#) {
            stash.hold("$\($0[1].replacingOccurrences(of: "\\]", with: "]"))$")
        }
        out = out.bridgeReplacing(#"footnote(?::[\w-]+)?:\[((?:[^\]\\]|\\.)*)\]"#) {
            stash.hold("^[\(inline($0[1]))]")
        }
        out = out.bridgeReplacing(#"cite(?:np)?:\[([^\]]+)\]"#) { groups in
            let keys = groups[1].components(separatedBy: ",")
                .map { $0.bridgeTrimmed.bridgeReplacing(#"\(.*\)"#) { _ in "" }.bridgeTrimmed }
                .filter { !$0.isEmpty }
            return stash.hold("[" + keys.map { "@\($0)" }.joined(separator: "; ") + "]")
        }
        out = out.bridgeReplacing(#"<<([^,>]+),\s*([^>]+)>>"#) { $0[2] }
        out = out.bridgeReplacing(#"<<([^>]+)>>"#) {
            $0[1].replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        }
        out = out.bridgeReplacing(#"(?:link:)?((?:https?|mailto|ftp):[^\s\[]+)\[([^\]]*)\]"#) { groups in
            stash.hold(groups[2].isEmpty ? groups[1] : "[\(groups[2])](\(groups[1]))")
        }
        out = out.bridgeReplacing(#"link:([^\s\[]+)\[([^\]]*)\]"#) { groups in
            groups[2].isEmpty ? groups[1] : groups[2]
        }
        out = out.bridgeReplacing(#"(?:kbd|btn|pass):\[([^\]]*)\]"#) { $0[1] }
        out = out.bridgeReplacing(#"image:([^\s\[]+)\[([^\]]*)\]"#) { $0[2] }
        out = out.bridgeReplacing(#"\[\[[^\]]*\]\]|anchor:[\w-]+\[[^\]]*\]"#) { _ in "" }
        out = out.bridgeReplacing(#"\+\+([^+]+)\+\+|(?<![\w+])\+([^+\s][^+]*)\+(?![\w+])"#) {
            $0[1].isEmpty ? $0[2] : $0[1]
        }
        // Emphasis: constrained *bold* and _italic_ in Markdown's forms.
        out = out.bridgeReplacing(#"(?<![\w*])\*(?=[^\s*])([^*\n]+?)(?<=\S)\*(?![\w*])"#) { "**\($0[1])**" }
        out = out.bridgeReplacing(#"__([^_]+)__"#) { "*\($0[1])*" }
        out = out.bridgeReplacing(#"(?<![\w_])_(?=[^\s_])([^_\n]+?)(?<=\S)_(?![\w_])"#) { "*\($0[1])*" }
        out = out.bridgeReplacing(#"(?<![\w#])#([^#\n]+)#(?![\w#])"#) { $0[1] }
        return stash.restore(out)
    }
}

// MARK: - reStructuredText

/// reStructuredText (Docutils, Sphinx) as Markdown: adorned titles and
/// sections, the docinfo field list, paragraphs and literal blocks,
/// lists and definition lists, block quotes, grid and simple tables,
/// the common directives (code, math, image, figure, admonitions,
/// list-table, csv-table, bibliography), footnotes, citations — their
/// `.. [KEY]` texts become references — hyperlink targets,
/// substitutions, and the roles `:math:`, `:cite:`, `:ref:` and friends.
nonisolated enum RSTBridge {

    static func markdown(from source: String) -> Bridged {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\t", with: "        ")
            .components(separatedBy: "\n")
        var context = Context()
        context.collectDefinitions(lines)
        var front = BridgeFrontMatter()
        let body = context.convert(lines, front: &front, topLevel: true)
        let bibliography = context.citations.map { key, text in
            BibTeXParser.parse(BibTeXWriter.write(type: "misc", key: key,
                                                  fields: ["title": text]))
        }.flatMap { $0 }
        var markdown = front.yaml + body.joined(separator: "\n")
        if !context.footnoteDefinitions.isEmpty {
            markdown += "\n\n" + context.footnoteDefinitions
                .map { "[^\($0.label)]: \(context.inline($0.text))" }
                .joined(separator: "\n\n")
        }
        return Bridged(markdown: markdown, bibliography: bibliography)
    }

    static let adornment = #/^([=\-`:'"~^_*+#<>.])\1{2,}\s*$/#

    struct Context {
        var links: [String: String] = [:]
        var substitutions: [String: String] = [:]
        var citations: [(String, String)] = []
        var footnoteDefinitions: [(label: String, text: String)] = []
        var anonymousFootnotes: [String] = []
        var sectionStyles: [String] = []
        /// Anonymous footnote marks are numbered by order of use across
        /// the whole document, however many paragraphs read them.
        final class Counter { var used = 0 }
        let anonymousUsed = Counter()

        /// Targets, substitutions, footnotes and citations are defined
        /// anywhere and used anywhere: read them all first.
        mutating func collectDefinitions(_ lines: [String]) {
            var index = 0
            var anonymousCount = 0
            while index < lines.count {
                let line = lines[index].bridgeTrimmed
                index += 1
                if let target = line.firstMatch(of: #/^\.\. _([^:]+):\s*(\S+)$/#) {
                    links[String(target.1).lowercased()] = String(target.2)
                } else if let sub = line.firstMatch(of: #/^\.\. \|([^|]+)\|\s+replace::\s*(.*)$/#) {
                    substitutions[String(sub.1)] = String(sub.2)
                } else if let note = line.firstMatch(of: #/^\.\. \[([^\]]+)\]\s*(.*)$/#) {
                    var text = String(note.2)
                    while index < lines.count, lines[index].bridgeIndent > 0
                            || (lines[index].bridgeTrimmed.isEmpty && index + 1 < lines.count
                                && lines[index + 1].bridgeIndent > 0) {
                        if !lines[index].bridgeTrimmed.isEmpty { text += " " + lines[index].bridgeTrimmed }
                        index += 1
                    }
                    let label = String(note.1)
                    if label == "#" || label == "*" {
                        anonymousCount += 1
                        let name = "auto\(anonymousCount)"
                        anonymousFootnotes.append(name)
                        footnoteDefinitions.append((name, text))
                    } else if label.first?.isNumber == true || label.hasPrefix("#") {
                        footnoteDefinitions.append((footnoteLabel(label), text))
                    } else {
                        citations.append((label, text))
                    }
                }
            }
        }

        func footnoteLabel(_ label: String) -> String {
            label.hasPrefix("#") ? "n-" + label.dropFirst() : label
        }

        mutating func convert(_ lines: [String], front: inout BridgeFrontMatter,
                              topLevel: Bool) -> [String] {
            var out: [String] = []
            var index = 0
            var sawBody = false
            var titleTaken = !topLevel

            // A lone top-level section is the document's title, as
            // Docutils promotes it; the next unique one its subtitle.
            let sections = topLevel ? sectionList(lines) : []
            let titleStyle = sections.first.flatMap { first in
                sections.filter { $0.style == first.style }.count == 1 ? first : nil
            }

            func isAdornment(_ line: String) -> Bool { line.firstMatch(of: RSTBridge.adornment) != nil }

            while index < lines.count {
                let line = lines[index]
                let trimmed = line.bridgeTrimmed

                if trimmed.isEmpty { out.append(""); index += 1; continue }

                // Section titles: text over an adornment, optionally under one.
                if line.bridgeIndent == 0 {
                    var title: String?
                    var style = ""
                    var consumed = 0
                    if isAdornment(line), index + 2 < lines.count, !lines[index + 1].bridgeTrimmed.isEmpty,
                       isAdornment(lines[index + 2]), lines[index + 2].first == line.first {
                        title = lines[index + 1].bridgeTrimmed
                        style = "o" + String(line.first!)
                        consumed = 3
                    } else if !isAdornment(line), index + 1 < lines.count, isAdornment(lines[index + 1]),
                              lines[index + 1].bridgeTrimmed.count >= min(trimmed.count, 3) {
                        title = trimmed
                        style = "u" + String(lines[index + 1].first!)
                        consumed = 2
                    }
                    if let title {
                        index += consumed
                        if !titleTaken, let titleStyle, titleStyle.style == style {
                            front.title = inline(title)
                            titleTaken = true
                            continue
                        }
                        if !sectionStyles.contains(style) { sectionStyles.append(style) }
                        let level = (sectionStyles.firstIndex(of: style) ?? 0) + 1
                        out += ["", String(repeating: "#", count: min(level, 6)) + " " + inline(title), ""]
                        sawBody = true
                        continue
                    }
                    if isAdornment(line), trimmed.count >= 4 {
                        out += ["", "---", ""]
                        index += 1
                        continue
                    }
                }

                // The docinfo field list, before any body text.
                if topLevel, !sawBody, let field = trimmed.firstMatch(of: #/^:([^:]+):\s*(.*)$/#) {
                    var value = String(field.2)
                    index += 1
                    while index < lines.count, lines[index].bridgeIndent > 0 {
                        value += "\n" + lines[index].bridgeTrimmed
                        index += 1
                    }
                    switch String(field.1).lowercased() {
                    case "author": front.authors.append(value.bridgeTrimmed)
                    case "authors":
                        front.authors += value.components(separatedBy: CharacterSet(charactersIn: ";\n"))
                            .flatMap { $0.contains(",") && !$0.contains(" and ") ? $0.components(separatedBy: ",") : [$0] }
                            .map(\.bridgeTrimmed).filter { !$0.isEmpty }
                    case "date": front.date = value.bridgeTrimmed
                    case "abstract": front.abstract = inline(value.replacingOccurrences(of: "\n", with: " "))
                    case "keywords":
                        front.keywords = value.components(separatedBy: CharacterSet(charactersIn: ",;"))
                            .map(\.bridgeTrimmed).filter { !$0.isEmpty }
                    default:
                        out.append("**\(field.1):** " + inline(value.replacingOccurrences(of: "\n", with: " ")))
                    }
                    continue
                }

                // Directives, footnotes, targets, comments.
                if trimmed.hasPrefix("..") && line.bridgeIndent == 0 {
                    let (block, next) = indentedBlock(lines, after: index)
                    out += directive(trimmed, body: block, front: &front)
                    index = next
                    sawBody = true
                    continue
                }

                // Tables.
                if trimmed.hasPrefix("+-"), trimmed.hasSuffix("+") {
                    var block: [String] = []
                    while index < lines.count, lines[index].bridgeTrimmed.hasPrefix("+")
                            || lines[index].bridgeTrimmed.hasPrefix("|") {
                        block.append(lines[index].bridgeTrimmed)
                        index += 1
                    }
                    out += BridgeText.pipeTable(gridTable(block), caption: nil)
                    sawBody = true
                    continue
                }
                if trimmed.firstMatch(of: #/^=+(\s+=+)+$/#) != nil {
                    var block: [String] = [line]
                    index += 1
                    var borders = 1
                    while index < lines.count {
                        let next = lines[index]
                        if next.bridgeTrimmed.firstMatch(of: #/^=+(\s+=+)+$/#) != nil {
                            borders += 1
                            block.append(next)
                            index += 1
                            // Header border, then the closing one.
                            if borders == 3 || (index < lines.count && lines[index].bridgeTrimmed.isEmpty && borders >= 2) { break }
                            continue
                        }
                        if next.bridgeTrimmed.isEmpty, borders >= 2 { break }
                        block.append(next)
                        index += 1
                    }
                    out += BridgeText.pipeTable(simpleTable(block), caption: nil)
                    sawBody = true
                    continue
                }

                // Lists.
                if let item = trimmed.firstMatch(of: #/^([-*+•])\s+(.*)$/#) {
                    var text = String(item.2)
                    index += 1
                    while index < lines.count, lines[index].bridgeIndent > line.bridgeIndent,
                          !lines[index].bridgeTrimmed.isEmpty,
                          lines[index].bridgeTrimmed.firstMatch(of: #/^([-*+•]|\d+[.)]|#\.)\s/#) == nil {
                        text += " " + lines[index].bridgeTrimmed
                        index += 1
                    }
                    out.append("- " + inline(text))
                    sawBody = true
                    continue
                }
                if let item = trimmed.firstMatch(of: #/^(?:\d+|#|[a-zA-Z]|[ivxIVX]+)[.)]\s+(.*)$|^\((?:\d+|[a-z])\)\s+(.*)$/#) {
                    var text = String(item.1 ?? item.2 ?? "")
                    index += 1
                    while index < lines.count, lines[index].bridgeIndent > line.bridgeIndent,
                          !lines[index].bridgeTrimmed.isEmpty {
                        text += " " + lines[index].bridgeTrimmed
                        index += 1
                    }
                    out.append("1. " + inline(text))
                    sawBody = true
                    continue
                }

                // A block quote: an indented paragraph standing alone.
                if line.bridgeIndent > 0 {
                    let (block, next) = indentedBlock(lines, from: index)
                    var inner = BridgeFrontMatter()
                    let converted = convert(block, front: &inner, topLevel: false)
                    out.append("")
                    out += converted.map { $0.isEmpty ? ">" : "> " + $0 }
                    out.append("")
                    index = next
                    sawBody = true
                    continue
                }

                // A paragraph, perhaps introducing a literal block, or a
                // definition-list term with its definition indented under it.
                var paragraph: [String] = [trimmed]
                index += 1
                if index < lines.count, lines[index].bridgeIndent > 0, !lines[index].bridgeTrimmed.isEmpty,
                   !trimmed.hasSuffix("::") {
                    let (definition, next) = indentedBlock(lines, from: index)
                    var inner = BridgeFrontMatter()
                    let converted = convert(definition, front: &inner, topLevel: false)
                        .filter { !$0.isEmpty }.joined(separator: " ")
                    out.append("- **\(inline(trimmed))**: \(converted)")
                    index = next
                    sawBody = true
                    continue
                }
                while index < lines.count, !lines[index].bridgeTrimmed.isEmpty,
                      lines[index].bridgeIndent == 0,
                      !(index + 1 < lines.count && isAdornment(lines[index + 1])),
                      !lines[index].hasPrefix("..") {
                    paragraph.append(lines[index].bridgeTrimmed)
                    index += 1
                }
                var text = paragraph.joined(separator: " ")
                if text.hasSuffix("::") {
                    // "Text::" introduces a literal block and prints "Text:".
                    text = text == "::" ? "" : (text.hasSuffix(" ::") ? String(text.dropLast(3)) : String(text.dropLast()))
                    if !text.isEmpty { out.append(inline(text)) }
                    let (block, next) = indentedBlock(lines, after: index - 1)
                    if !block.isEmpty { out += ["", "```"] + dedented(block) + ["```", ""] }
                    index = next
                } else {
                    out.append(inline(text))
                }
                sawBody = true
            }
            return out
        }

        /// Each section title's style, in document order.
        func sectionList(_ lines: [String]) -> [(style: String, title: String)] {
            var out: [(String, String)] = []
            var index = 0
            func isAdornment(_ line: String) -> Bool { line.firstMatch(of: RSTBridge.adornment) != nil }
            while index + 1 < lines.count {
                let line = lines[index]
                if line.bridgeIndent == 0, isAdornment(line), index + 2 < lines.count,
                   !lines[index + 1].bridgeTrimmed.isEmpty, isAdornment(lines[index + 2]) {
                    out.append(("o" + String(line.first!), lines[index + 1].bridgeTrimmed))
                    index += 3
                    continue
                }
                if line.bridgeIndent == 0, !line.bridgeTrimmed.isEmpty, !isAdornment(line),
                   isAdornment(lines[index + 1]),
                   lines[index + 1].bridgeTrimmed.count >= min(line.bridgeTrimmed.count, 3) {
                    out.append(("u" + String(lines[index + 1].first!), line.bridgeTrimmed))
                    index += 2
                    continue
                }
                index += 1
            }
            return out
        }

        /// The lines indented under line `after` (blank lines inside
        /// kept), and the index after them.
        func indentedBlock(_ lines: [String], after start: Int) -> ([String], Int) {
            indentedBlock(lines, from: start + 1)
        }

        func indentedBlock(_ lines: [String], from start: Int) -> ([String], Int) {
            var index = start
            var block: [String] = []
            while index < lines.count {
                let line = lines[index]
                if line.bridgeTrimmed.isEmpty {
                    // A blank line continues the block only if indented
                    // text follows.
                    var probe = index + 1
                    while probe < lines.count, lines[probe].bridgeTrimmed.isEmpty { probe += 1 }
                    guard probe < lines.count, lines[probe].bridgeIndent > 0 else { break }
                    block.append("")
                    index += 1
                    continue
                }
                guard line.bridgeIndent > 0 else { break }
                block.append(line)
                index += 1
            }
            return (dedented(block), index)
        }

        func dedented(_ block: [String]) -> [String] {
            let indent = block.filter { !$0.bridgeTrimmed.isEmpty }.map(\.bridgeIndent).min() ?? 0
            return block.map { $0.count >= indent ? String($0.dropFirst(indent)) : $0.bridgeTrimmed }
        }

        mutating func directive(_ head: String, body: [String], front: inout BridgeFrontMatter) -> [String] {
            guard let match = head.firstMatch(of: #/^\.\.\s+([\w:-]+)::\s*(.*)$/#) else {
                // Footnotes, citations, targets and substitutions were
                // read up front; anything else is a comment.
                return []
            }
            let name = String(match.1).lowercased()
            let argument = String(match.2).bridgeTrimmed
            // Options (`:alt: …`) open the body; the content follows.
            var options: [String: String] = [:]
            var content = body
            while let first = content.first, let option = first.bridgeTrimmed.firstMatch(of: #/^:([\w-]+):\s*(.*)$/#) {
                options[String(option.1)] = String(option.2)
                content.removeFirst()
            }
            while content.first?.bridgeTrimmed.isEmpty == true { content.removeFirst() }
            var inner = BridgeFrontMatter()
            switch name {
            case "code-block", "code", "sourcecode":
                return ["", "```\(argument)"] + content + ["```", ""]
            case "math":
                let equations = content.split(separator: "", omittingEmptySubsequences: true)
                    .map { $0.joined(separator: "\n") }
                let all = argument.isEmpty ? equations : [argument] + equations
                return all.flatMap { ["", "$$", $0, "$$", ""] }
            case "image":
                return ["", "![\(options["alt"] ?? "")](\(argument))", ""]
            case "figure":
                let paragraphs = content.split(separator: "", omittingEmptySubsequences: true)
                let caption = paragraphs.first.map { inline($0.map(\.bridgeTrimmed).joined(separator: " ")) }
                    ?? options["alt"] ?? ""
                var out = ["", "![\(caption)](\(argument))", ""]
                for legend in paragraphs.dropFirst() {
                    out.append(inline(legend.map(\.bridgeTrimmed).joined(separator: " ")))
                    out.append("")
                }
                return out
            case "note", "tip", "warning", "important", "attention", "caution",
                 "danger", "error", "hint", "seealso", "admonition", "topic", "sidebar", "rubric":
                let titled = name == "admonition" || name == "topic" || name == "sidebar" || name == "rubric"
                let label = titled ? argument : name.capitalized
                // `.. note:: Words` — an admonition's words may start on
                // the directive's own line.
                let words = !titled && !argument.isEmpty ? [argument] + content : content
                let converted = convert(words, front: &inner, topLevel: false)
                return ["", "**\(inline(label))\(name == "rubric" ? "" : ":")**"] + converted + [""]
            case "epigraph", "highlights", "pull-quote":
                let converted = convert(content, front: &inner, topLevel: false)
                return [""] + converted.map { $0.isEmpty ? ">" : "> " + $0 } + [""]
            case "bibliography":
                front.bibliography += argument.components(separatedBy: " ").filter { !$0.isEmpty }
                return []
            case "list-table":
                return BridgeText.pipeTable(listTable(content, headerRows: Int(options["header-rows"] ?? "0") ?? 0),
                                            caption: argument.isEmpty ? nil : inline(argument))
            case "csv-table":
                var rows: [[String]] = []
                if let header = options["header"] { rows.append(csvCells(header)) }
                rows += content.filter { !$0.bridgeTrimmed.isEmpty }.map(csvCells)
                if options["header"] == nil { rows.insert(Array(repeating: " ", count: rows.first?.count ?? 1), at: 0) }
                return BridgeText.pipeTable(rows.map { $0.map { inline($0) } },
                                            caption: argument.isEmpty ? nil : inline(argument))
            case "table":
                let converted = convert(content, front: &inner, topLevel: false)
                guard !argument.isEmpty else { return converted }
                // The caption rides the pipe table.
                if let last = converted.lastIndex(where: { $0.hasPrefix("|") }) {
                    var out = converted
                    out.insert(contentsOf: ["", "Table: \(inline(argument))"], at: last + 1)
                    return out
                }
                return converted
            case "toctree", "contents", "index", "raw", "only", "include", "meta", "sectnum",
                 "header", "footer", "tabularcolumns", "highlight", "default-role", "role",
                 "autosummary", "automodule", "autoclass", "autofunction", "literalinclude":
                return []
            default:
                return convert(content, front: &inner, topLevel: false)
            }
        }

        func csvCells(_ line: String) -> [String] {
            var cells: [String] = []
            var current = ""
            var quoted = false
            for character in line.bridgeTrimmed {
                if character == "\"" { quoted.toggle(); continue }
                if character == ",", !quoted { cells.append(current.bridgeTrimmed); current = ""; continue }
                current.append(character)
            }
            cells.append(current.bridgeTrimmed)
            return cells
        }

        func listTable(_ content: [String], headerRows: Int) -> [[String]] {
            var rows: [[String]] = []
            for line in content {
                let trimmed = line.bridgeTrimmed
                if let cell = trimmed.firstMatch(of: #/^\*\s+-\s+(.*)$/#) {
                    rows.append([inline(String(cell.1))])
                } else if let cell = trimmed.firstMatch(of: #/^-\s+(.*)$/#), !rows.isEmpty {
                    rows[rows.count - 1].append(inline(String(cell.1)))
                } else if !trimmed.isEmpty, !rows.isEmpty, let last = rows[rows.count - 1].indices.last {
                    rows[rows.count - 1][last] += " " + inline(trimmed)
                }
            }
            if headerRows == 0 { rows.insert(Array(repeating: " ", count: rows.first?.count ?? 1), at: 0) }
            return rows
        }

        func gridTable(_ block: [String]) -> [[String]] {
            guard let border = block.first else { return [] }
            let edges = border.enumerated().filter { $0.element == "+" }.map(\.offset)
            var rows: [[String]] = []
            var current: [String] = Array(repeating: "", count: max(edges.count - 1, 0))
            var hasContent = false
            var headerSeen = false
            for line in block.dropFirst() {
                if line.hasPrefix("+") {
                    if hasContent { rows.append(current.map(\.bridgeTrimmed)) }
                    if line.contains("=") { headerSeen = true }
                    current = Array(repeating: "", count: max(edges.count - 1, 0))
                    hasContent = false
                    continue
                }
                let characters = Array(line)
                for column in 0..<(edges.count - 1) {
                    let start = edges[column] + 1
                    let end = min(edges[column + 1], characters.count)
                    guard start < end else { continue }
                    let text = String(characters[start..<end]).bridgeTrimmed
                    if !text.isEmpty {
                        current[column] += (current[column].isEmpty ? "" : " ") + text
                        hasContent = true
                    }
                }
            }
            if hasContent { rows.append(current.map(\.bridgeTrimmed)) }
            let styled = rows.map { $0.map { inline($0) } }
            return headerSeen ? styled : [Array(repeating: " ", count: edges.count - 1)] + styled
        }

        func simpleTable(_ block: [String]) -> [[String]] {
            guard let border = block.first else { return [] }
            var starts: [Int] = []
            var previous: Character = " "
            for (offset, character) in border.enumerated() {
                if character == "=", previous == " " { starts.append(offset) }
                previous = character
            }
            var rows: [[String]] = []
            var borders = 0
            var headerRows = 0
            for line in block.dropFirst() {
                if line.bridgeTrimmed.firstMatch(of: #/^=+(\s+=+)+$/#) != nil {
                    borders += 1
                    if borders == 1 { headerRows = rows.count }
                    continue
                }
                let characters = Array(line)
                var cells: [String] = []
                for (column, start) in starts.enumerated() {
                    let end = column + 1 < starts.count ? starts[column + 1] : characters.count
                    cells.append(start < characters.count
                                 ? String(characters[start..<min(end, characters.count)]).bridgeTrimmed : "")
                }
                // A row whose first cell is blank continues the one above.
                if cells.first?.isEmpty == true, !rows.isEmpty {
                    for (column, cell) in cells.enumerated() where !cell.isEmpty {
                        rows[rows.count - 1][column] += " " + cell
                    }
                } else {
                    rows.append(cells)
                }
            }
            let styled = rows.map { $0.map { inline($0) } }
            // With two borders only, the table has no header.
            return borders >= 2 && headerRows > 0
                ? styled : [Array(repeating: " ", count: starts.count)] + styled
        }

        func inline(_ text: String) -> String {
            let stash = BridgeStash()
            var out = text.bridgeReplacing("``(.+?)``") { stash.hold("`\($0[1])`") }
            out = out.bridgeReplacing(#":math:`([^`]+)`"#) { stash.hold("$\($0[1])$") }
            out = out.bridgeReplacing(#":(?:foot)?cite(?::[a-z]+)?:`([^`]+)`"#) { groups in
                let keys = groups[1].components(separatedBy: ",").map(\.bridgeTrimmed).filter { !$0.isEmpty }
                return stash.hold("[" + keys.map { "@\($0)" }.joined(separator: "; ") + "]")
            }
            out = out.bridgeReplacing(#":(?:ref|doc|term|numref|any|abbr):`([^`<]*?)\s*(?:<[^>]*>)?`"#) { groups in
                groups[1].bridgeReplacing(#"\s*\(.*\)$"#) { _ in "" }
            }
            out = out.bridgeReplacing(#":emphasis:`([^`]+)`"#) { "*\($0[1])*" }
            out = out.bridgeReplacing(#":strong:`([^`]+)`"#) { "**\($0[1])**" }
            out = out.bridgeReplacing(#":[\w:-]+:`([^`]+)`"#) { $0[1] }
            // Hyperlinks: `text <url>`_, `name`_ and name_ via targets.
            out = out.bridgeReplacing(#"`([^`<]+?)\s*<([^>]+)>`__?"#) { groups in
                var url = groups[2]
                if url.hasSuffix("_") { url = links[String(url.dropLast()).lowercased()] ?? "" }
                return url.isEmpty ? groups[1] : stash.hold("[\(groups[1])](\(url))")
            }
            out = out.bridgeReplacing(#"`([^`]+)`__?"#) { groups in
                links[groups[1].lowercased()].map { stash.hold("[\(groups[1])](\($0))") } ?? groups[1]
            }
            // Footnote and citation references.
            out = out.bridgeReplacing(#"\[([^\]\s]+)\]_"#) { groups in
                let label = groups[1]
                if label == "#" || label == "*" {
                    // A mark numbered below, in reading order (these
                    // replacements run back to front).
                    return "\u{E120}"
                }
                if label.first?.isNumber == true || label.hasPrefix("#") {
                    return stash.hold("[^\(footnoteLabel(label))]")
                }
                return stash.hold("[@\(label)]")
            }
            while let range = out.range(of: "\u{E120}") {
                let used = anonymousUsed.used
                let name = used < anonymousFootnotes.count ? anonymousFootnotes[used] : "auto\(used + 1)"
                anonymousUsed.used += 1
                out.replaceSubrange(range, with: stash.hold("[^\(name)]"))
            }
            out = out.bridgeReplacing(#"(?<![\w`])([A-Za-z][\w-]*)_(?![\w])"#) { groups in
                links[groups[1].lowercased()].map { stash.hold("[\(groups[1])](\($0))") } ?? groups[0]
            }
            out = out.bridgeReplacing(#"\|([^|\s][^|]*)\|"#) { groups in substitutions[groups[1]] ?? groups[0] }
            // The default role, `text`, is emphasis.
            out = out.bridgeReplacing(#"(?<!`)`([^`]+)`(?!`)"#) { "*\($0[1])*" }
            return stash.restore(out)
        }
    }
}
