import Foundation
import CryptoKit

// OrigamiMath — the headless core of the Origami Text mathematics profile
// (see origami-text-mathematics-spec.md). No UI dependencies, so it is
// testable headlessly and shareable between Author and Reader.
//
// This file implements the Reader-facing and shared pieces:
//   • the equation model (§3.6, Reader subset)
//   • the BibTeX-family escaper and its exact inverse (§6.3)
//   • the Visual-Meta @{visual-meta-equations} block reader and writer (§6)
//   • SHA-256 checksums and their verification (§6.3, §8.2)
//   • a body DOM-scan fallback for math[id] (§8.2 step 2)
//   • the equation index builder (§8.2)
//   • LaTeX→MathML for the EPUB export (`TeXMathML`, below): a native
//     converter for the mathematics papers are written in, which declines
//     — rather than guesses — anything it does not know
//
// Author-side ingestion, the export sanitiser and numbering are the next
// phase and are deliberately not built here; the spec's §3–§5 are the
// map for them.

// MARK: - Model (§3.6, Reader subset)

nonisolated enum EquationDisplay: String, Codable, Hashable, Sendable {
    case inline, block
}

nonisolated enum EquationSourceFormat: String, Codable, Hashable, Sendable {
    case mathml, latex
}

/// One mathematical expression, as the Reader knows it. Ids are the stable
/// `eq-<uuidv7>` used on the root `<math>` and as the Visual-Meta entry key,
/// so citations resolve through the id, never the printed number.
nonisolated struct EquationEntry: Identifiable, Codable, Hashable, Sendable {
    let id: String                    // "eq-" + lowercase UUID
    var display: EquationDisplay
    var format: EquationSourceFormat
    var label: String?                // printed number, e.g. "4.2"
    var tex: String?                  // unescaped LaTeX source-of-truth
    var texSHA256: String?
    var mathmlSHA256: String?
    var converter: String?            // pinned engine identifier
    var href: String?                 // relative path + fragment
    var section: String?
    var heading: String?

    /// Whether the Visual-Meta `tex` survived its round trip: its checksum
    /// matches the unescaped source. Nil when there is nothing to check.
    var texChecksumOK: Bool? {
        guard let tex, let texSHA256 else { return nil }
        return OrigamiMath.sha256Hex(tex) == texSHA256.lowercased()
    }
}

// MARK: - Shared helpers

nonisolated enum OrigamiMath {
    /// Lowercase hex SHA-256 of a string's UTF-8 bytes (§6.3).
    static func sha256Hex(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

// MARK: - BibTeX escaping (§6.3)

/// The Visual-Meta escaper for `tex` and `heading`. Both `escape` and
/// `unescape` are single left-to-right passes so no emitted token is ever
/// re-processed — the backslash-first ordering the spec calls for is
/// satisfied structurally, and `unescape(escape(s)) == s` for every string.
nonisolated enum MathBibTeXEscaper {

    static func escape(_ string: String) -> String {
        var out = ""
        out.reserveCapacity(string.count)
        for character in string {
            switch character {
            case "\\": out += "\\textbackslash{}"
            case "{":  out += "\\{"
            case "}":  out += "\\}"
            case "$":  out += "\\$"
            case "&":  out += "\\&"
            case "%":  out += "\\%"
            case "#":  out += "\\#"
            case "_":  out += "\\_"
            case "~":  out += "\\textasciitilde{}"
            case "^":  out += "\\textasciicircum{}"
            default:   out.append(character)
            }
        }
        return out
    }

    /// Longest-token-first, so the multi-character forms are matched before
    /// the single-character ones.
    private static let tokens: [(escaped: String, plain: String)] = [
        ("\\textbackslash{}", "\\"),
        ("\\textasciitilde{}", "~"),
        ("\\textasciicircum{}", "^"),
        ("\\{", "{"), ("\\}", "}"), ("\\$", "$"), ("\\&", "&"),
        ("\\%", "%"), ("\\#", "#"), ("\\_", "_"),
    ]

    static func unescape(_ string: String) -> String {
        var out = ""
        out.reserveCapacity(string.count)
        var index = string.startIndex
        scan: while index < string.endIndex {
            if string[index] == "\\" {
                let rest = string[index...]
                for token in tokens where rest.hasPrefix(token.escaped) {
                    out += token.plain
                    index = string.index(index, offsetBy: token.escaped.count)
                    continue scan
                }
            }
            out.append(string[index])
            index = string.index(after: index)
        }
        return out
    }
}

// MARK: - Visual-Meta equations block (§6)

/// Writes the `@{visual-meta-equations-start} … @{…-end}` block. Used by
/// Author on export and by the Reader's round-trip tests. `tex` and
/// `heading` are escaped; everything else (ids, hashes, hrefs, labels) is
/// safe within braces and travels verbatim, matching the spec's example.
nonisolated enum EquationBlockWriter {
    static let startMarker = "@{visual-meta-equations-start}"
    static let endMarker = "@{visual-meta-equations-end}"

    static func write(_ entries: [EquationEntry]) -> String {
        var lines: [String] = [startMarker, ""]
        for entry in entries {
            var fields: [String] = ["display = {\(entry.display.rawValue)}"]
            if let label = entry.label { fields.append("label = {\(label)}") }
            fields.append("format = {\(entry.format.rawValue)}")
            if let tex = entry.tex { fields.append("tex = {\(MathBibTeXEscaper.escape(tex))}") }
            if let hash = entry.texSHA256 { fields.append("tex-sha256 = {\(hash)}") }
            if let hash = entry.mathmlSHA256 { fields.append("mathml-sha256 = {\(hash)}") }
            if let converter = entry.converter { fields.append("converter = {\(converter)}") }
            if let href = entry.href { fields.append("href = {\(href)}") }
            if let section = entry.section { fields.append("section = {\(section)}") }
            if let heading = entry.heading {
                fields.append("heading = {\(MathBibTeXEscaper.escape(heading))}")
            }
            lines.append("@equation{\(entry.id),")
            lines.append(fields.map { "    " + $0 }.joined(separator: ",\n"))
            lines.append("}")
            lines.append("")
        }
        lines.append(endMarker)
        return lines.joined(separator: "\n")
    }
}

/// Reads the equations block back into `EquationEntry` values, unescaping
/// `tex` and `heading`. Brace values are read by depth so the balanced `{}`
/// inside `\textbackslash{}` and friends don't end them early.
nonisolated enum EquationBlockReader {

    static func read(fromVisualMetaText text: String) -> [EquationEntry] {
        guard let start = text.range(of: EquationBlockWriter.startMarker),
              let end = text.range(of: EquationBlockWriter.endMarker,
                                   range: start.upperBound..<text.endIndex)
        else { return [] }
        return parseEntries(in: String(text[start.upperBound..<end.lowerBound]))
    }

    private static func parseEntries(in body: String) -> [EquationEntry] {
        var entries: [EquationEntry] = []
        var searchStart = body.startIndex
        while let marker = body.range(of: "@equation{", range: searchStart..<body.endIndex) {
            // The entry runs from just after "@equation{" to its matching
            // close brace, counted by depth.
            guard let close = matchingBrace(in: body, openAfter: marker.upperBound) else { break }
            let inner = String(body[marker.upperBound..<close])
            if let entry = parseEntry(inner) { entries.append(entry) }
            searchStart = body.index(after: close)
        }
        return entries
    }

    /// The index of the `}` closing the brace whose contents begin at
    /// `start` (depth starts at 1 for the already-consumed `{`).
    private static func matchingBrace(in string: String, openAfter start: String.Index) -> String.Index? {
        var depth = 1
        var index = start
        while index < string.endIndex {
            switch string[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return index }
            default: break
            }
            index = string.index(after: index)
        }
        return nil
    }

    private static func parseEntry(_ inner: String) -> EquationEntry? {
        guard let firstComma = inner.firstIndex(of: ",") else { return nil }
        let id = String(inner[inner.startIndex..<firstComma])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard id.hasPrefix("eq-") else { return nil }

        let fields = parseFields(in: String(inner[inner.index(after: firstComma)...]))
        func value(_ key: String) -> String? { fields[key] }

        let display = value("display").flatMap(EquationDisplay.init) ?? .block
        let format = value("format").flatMap(EquationSourceFormat.init) ?? .latex
        return EquationEntry(
            id: id,
            display: display,
            format: format,
            label: value("label"),
            tex: value("tex").map(MathBibTeXEscaper.unescape),
            texSHA256: value("tex-sha256"),
            mathmlSHA256: value("mathml-sha256"),
            converter: value("converter"),
            href: value("href"),
            section: value("section"),
            heading: value("heading").map(MathBibTeXEscaper.unescape))
    }

    /// `name = {value}` pairs, comma-separated, value read by brace depth.
    private static func parseFields(in text: String) -> [String: String] {
        var result: [String: String] = [:]
        var index = text.startIndex
        while index < text.endIndex {
            // Skip separators and whitespace to the next field name.
            while index < text.endIndex,
                  text[index] == "," || text[index].isWhitespace {
                index = text.index(after: index)
            }
            guard index < text.endIndex else { break }
            // Field name: up to '='.
            guard let equals = text[index...].firstIndex(of: "=") else { break }
            let name = String(text[index..<equals]).trimmingCharacters(in: .whitespaces)
            // Move past '=' and whitespace to the opening brace.
            var cursor = text.index(after: equals)
            while cursor < text.endIndex, text[cursor].isWhitespace {
                cursor = text.index(after: cursor)
            }
            guard cursor < text.endIndex, text[cursor] == "{",
                  let close = matchingBrace(in: text, openAfter: text.index(after: cursor))
            else { break }
            let value = String(text[text.index(after: cursor)..<close])
            if !name.isEmpty { result[name] = value }
            index = text.index(after: close)
        }
        return result
    }
}

// MARK: - Body DOM scan (§8.2 step 2)

/// Extracts equations directly from a content document's `<math id="eq-…">`
/// elements — the fallback for EPUBs whose Visual-Meta has no equations
/// block (third-party MathML), and the source of truth the Reader trusts
/// when a Visual-Meta checksum fails. Verbatim `tex` comes from the
/// `<annotation encoding="application/x-tex">`.
nonisolated enum MathMLBodyScanner {

    static func equations(inXHTML html: String, contentHref: String) -> [EquationEntry] {
        var entries: [EquationEntry] = []
        guard let mathExpr = try? NSRegularExpression(
            pattern: "<math\\b([^>]*)>(.*?)</math>",
            options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return entries }
        let range = NSRange(html.startIndex..., in: html)
        for match in mathExpr.matches(in: html, range: range) {
            guard let attrRange = Range(match.range(at: 1), in: html),
                  let innerRange = Range(match.range(at: 2), in: html) else { continue }
            let attributes = String(html[attrRange])
            let inner = String(html[innerRange])
            // Any `math` element carrying an id is an equation. Being
            // `<math>` is the semantic signal; the id only addresses it.
            // This used to require an `eq-` prefix, which made an equation
            // written to the profile's own example (`id="E-71B2…"`)
            // invisible — and inferring a kind from an id prefix is
            // exactly what the format forbids.
            guard let id = attribute("id", in: attributes), !id.isEmpty else { continue }
            let display = attribute("display", in: attributes)
                .flatMap(EquationDisplay.init) ?? .inline
            // The TeX annotation, else the derived `data-latex` a writer
            // MAY carry on the element (§7.7).
            let tex = texAnnotation(in: inner)
                ?? attribute("data-latex", in: attributes).map(xmlDecoded)
            entries.append(EquationEntry(
                id: id,
                display: display,
                format: tex == nil ? .mathml : .latex,
                label: nil,
                tex: tex,
                texSHA256: tex.map(OrigamiMath.sha256Hex),
                mathmlSHA256: nil,
                converter: nil,
                href: "\(contentHref)#\(id)",
                section: nil,
                heading: nil))
        }
        return entries
    }

    /// The `<math>` element carrying `id`, as written — what Copy MathML
    /// puts on the clipboard.
    static func mathMLSource(id: String, inXHTML html: String) -> String? {
        guard let expr = try? NSRegularExpression(
            pattern: "<math\\b[^>]*\\bid\\s*=\\s*\"\(NSRegularExpression.escapedPattern(for: id))\"[^>]*>.*?</math>",
            options: [.dotMatchesLineSeparators, .caseInsensitive]),
              let match = expr.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range, in: html) else { return nil }
        return String(html[range])
    }

    private static func attribute(_ name: String, in attributes: String) -> String? {
        guard let expr = try? NSRegularExpression(
            pattern: "\\b\(name)\\s*=\\s*\"([^\"]*)\"", options: [.caseInsensitive]),
              let match = expr.firstMatch(in: attributes,
                                          range: NSRange(attributes.startIndex..., in: attributes)),
              let range = Range(match.range(at: 1), in: attributes) else { return nil }
        return String(attributes[range])
    }

    /// The verbatim LaTeX from the TeX annotation, XML-entities decoded.
    private static func texAnnotation(in inner: String) -> String? {
        guard let expr = try? NSRegularExpression(
            pattern: "<annotation\\b[^>]*encoding=\"application/x-tex\"[^>]*>(.*?)</annotation>",
            options: [.dotMatchesLineSeparators, .caseInsensitive]),
              let match = expr.firstMatch(in: inner,
                                          range: NSRange(inner.startIndex..., in: inner)),
              let range = Range(match.range(at: 1), in: inner) else { return nil }
        return xmlDecoded(String(inner[range]))
    }

    private static func xmlDecoded(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

// MARK: - Equation index (§8.2)

/// The Reader's equation index for one publication. Built from the
/// Visual-Meta equations block when present, and otherwise (or where an
/// entry's MathML checksum fails on access) from the body itself.
nonisolated struct EquationIndex: Sendable {
    private(set) var entries: [EquationEntry]
    /// True when the index came from a Visual-Meta equations block rather
    /// than a bare body scan.
    let fromVisualMeta: Bool

    var isEmpty: Bool { entries.isEmpty }

    func entry(id: String) -> EquationEntry? { entries.first { $0.id == id } }

    /// Builds the index: prefer the Visual-Meta block, fall back to a DOM
    /// scan of the content document. When both exist, Visual-Meta entries
    /// missing an href are given one from the matching body element.
    static func build(visualMetaText: String?, contentHTML: String, contentHref: String) -> EquationIndex {
        let fromBlock = visualMetaText.map(EquationBlockReader.read(fromVisualMetaText:)) ?? []
        if !fromBlock.isEmpty {
            return EquationIndex(entries: fromBlock, fromVisualMeta: true)
        }
        let scanned = MathMLBodyScanner.equations(inXHTML: contentHTML, contentHref: contentHref)
        return EquationIndex(entries: scanned, fromVisualMeta: false)
    }
}

// MARK: - Display mathematics in the body

nonisolated extension OrigamiMath {
    /// The TeX of a display equation paragraph — the format writes one as
    /// `$$⏎tex⏎$$`, the way Markdown and LaTeX users already write it —
    /// or nil when the paragraph is anything else.
    static func displayTeX(in paragraphText: String) -> String? {
        let trimmed = paragraphText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("$$"), trimmed.hasSuffix("$$"), trimmed.count > 4 else { return nil }
        let tex = trimmed.dropFirst(2).dropLast(2).trimmingCharacters(in: .whitespacesAndNewlines)
        // "$$a$$ and $$b$$" is prose holding two equations, not one.
        guard !tex.isEmpty, !tex.contains("$$") else { return nil }
        return tex
    }

    /// Inline TeX spans — `$…$` by Pandoc's rule: no space just inside
    /// either dollar, no digit straight after the closing one, never an
    /// escaped `\$`, never inside a backtick code span, never `$$`. "It
    /// costs $5 and $10" holds none.
    static func inlineMath(in text: String) -> [(range: Range<String.Index>, tex: String)] {
        guard text.contains("$") else { return [] }
        var spans: [(range: Range<String.Index>, tex: String)] = []
        var inCode = false
        var index = text.startIndex
        func character(before position: String.Index) -> Character? {
            position > text.startIndex ? text[text.index(before: position)] : nil
        }
        while index < text.endIndex {
            let current = text[index]
            if current == "`" { inCode.toggle() }
            let next = text.index(after: index)
            guard current == "$", !inCode, character(before: index) != "\\",
                  character(before: index) != "$",
                  next < text.endIndex, text[next] != "$", !text[next].isWhitespace else {
                index = next
                continue
            }
            var close = next
            var found: String.Index?
            while close < text.endIndex {
                let candidate = text[close]
                if candidate == "`" { break }
                if candidate == "$", character(before: close) != "\\" {
                    let after = text.index(after: close)
                    let spaceBefore = character(before: close)?.isWhitespace ?? true
                    let digitAfter = after < text.endIndex && text[after].isNumber
                    if !spaceBefore, !digitAfter { found = close }
                    break
                }
                close = text.index(after: close)
            }
            guard let end = found else {
                index = next
                continue
            }
            spans.append((index..<text.index(after: end), String(text[next..<end])))
            index = text.index(after: end)
        }
        return spans
    }

    /// An equation as words, for a reader that sets no MathML (the
    /// native reading views, plain-text fallbacks): readable Unicode when
    /// the TeX is simple, its symbols as characters otherwise.
    static func readableTeX(_ tex: String) -> String {
        BibTeXParser.readableMath(tex) ?? BibTeXParser.convertingTeXSymbols(in: tex)
    }
}

// MARK: - LaTeX → MathML

/// TeX mathematics as Presentation MathML — the subset papers are written
/// in: identifiers and numbers, operators and relations, Greek and the
/// common symbols, scripts, fractions and roots, large operators with
/// limits, fences, accents, font commands, text, spacing, and the matrix,
/// cases and alignment environments.
///
/// It declines rather than guesses: one command it does not know and the
/// whole formula returns nil, so the caller keeps the TeX as words. A
/// wrong rendering of an equation is worse than a verbatim one.
nonisolated enum TeXMathML {

    /// The `<math>` element's contents (one `<mrow>`), or nil.
    static func mathML(for tex: String, display: Bool) -> String? {
        var parser = Parser(tex: tex, display: display)
        guard let body = try? parser.parseAll() else { return nil }
        return "<mrow>\(body)</mrow>"
    }

    /// A whole `<math>` element carrying the Profile's attributes (§7.7):
    /// its id, display mode, the TeX as `alttext` for every reader, and
    /// the TeX again as the derived `data-latex` for the round trip.
    static func mathElement(for tex: String, display: Bool, id: String?,
                            extraAttributes: String = "") -> String? {
        guard let body = mathML(for: tex, display: display) else { return nil }
        let escapedTeX = escaped(tex, attribute: true)
        let idAttribute = id.map { " id=\"\(escaped($0, attribute: true))\"" } ?? ""
        return "<math xmlns=\"http://www.w3.org/1998/Math/MathML\"\(idAttribute)\(extraAttributes)"
            + " display=\"\(display ? "block" : "inline")\" alttext=\"\(escapedTeX)\""
            + " data-latex=\"\(escapedTeX)\">\(body)</math>"
    }

    fileprivate static func escaped(_ text: String, attribute: Bool = false) -> String {
        var out = text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        if attribute {
            out = out.replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "\n", with: " ")
        }
        return out
    }

    struct Unsupported: Error { let what: String }

    // MARK: Vocabulary

    /// Letters and letter-like symbols: `<mi>`.
    fileprivate static let identifiers: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ϵ",
        "varepsilon": "ε", "zeta": "ζ", "eta": "η", "theta": "θ", "vartheta": "ϑ",
        "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ",
        "omicron": "ο", "pi": "π", "varpi": "ϖ", "rho": "ρ", "varrho": "ϱ",
        "sigma": "σ", "varsigma": "ς", "tau": "τ", "upsilon": "υ", "phi": "ϕ",
        "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ",
        "Pi": "Π", "Sigma": "Σ", "Upsilon": "Υ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
        "infty": "∞", "partial": "∂", "nabla": "∇", "emptyset": "∅", "varnothing": "∅",
        "hbar": "ℏ", "ell": "ℓ", "Re": "ℜ", "Im": "ℑ", "aleph": "ℵ", "wp": "℘",
        "imath": "ı", "jmath": "ȷ", "top": "⊤", "bot": "⊥", "angle": "∠",
        "triangle": "△", "Box": "□", "square": "□", "degree": "°",
    ]

    /// Operators, relations, arrows and punctuation: `<mo>`.
    fileprivate static let operators: [String: String] = [
        "pm": "±", "mp": "∓", "times": "×", "div": "÷", "cdot": "⋅", "ast": "∗",
        "star": "⋆", "circ": "∘", "bullet": "∙", "cap": "∩", "cup": "∪",
        "vee": "∨", "wedge": "∧", "land": "∧", "lor": "∨", "setminus": "∖",
        "oplus": "⊕", "ominus": "⊖", "otimes": "⊗", "oslash": "⊘", "odot": "⊙",
        "leq": "≤", "le": "≤", "geq": "≥", "ge": "≥", "neq": "≠", "ne": "≠",
        "leqslant": "⩽", "geqslant": "⩾", "approx": "≈", "equiv": "≡", "sim": "∼",
        "simeq": "≃", "cong": "≅", "propto": "∝", "ll": "≪", "gg": "≫",
        "prec": "≺", "succ": "≻", "preceq": "⪯", "succeq": "⪰",
        "subset": "⊂", "subseteq": "⊆", "supset": "⊃", "supseteq": "⊇",
        "subsetneq": "⊊", "supsetneq": "⊋", "in": "∈", "notin": "∉", "ni": "∋",
        "forall": "∀", "exists": "∃", "nexists": "∄", "neg": "¬", "lnot": "¬",
        "to": "→", "rightarrow": "→", "leftarrow": "←", "gets": "←",
        "Rightarrow": "⇒", "Leftarrow": "⇐", "leftrightarrow": "↔",
        "Leftrightarrow": "⇔", "longrightarrow": "⟶", "longleftarrow": "⟵",
        "Longrightarrow": "⟹", "Longleftarrow": "⟸", "longleftrightarrow": "⟷",
        "Longleftrightarrow": "⟺", "mapsto": "↦", "longmapsto": "⟼",
        "implies": "⟹", "impliedby": "⟸", "iff": "⟺", "uparrow": "↑",
        "downarrow": "↓", "Uparrow": "⇑", "Downarrow": "⇓", "hookrightarrow": "↪",
        "rightharpoonup": "⇀", "leftharpoonup": "↼",
        "ldots": "…", "cdots": "⋯", "vdots": "⋮", "ddots": "⋱", "dots": "…",
        "dotsc": "…", "dotsb": "⋯", "prime": "′", "perp": "⊥", "parallel": "∥",
        "mid": "∣", "nmid": "∤", "vdash": "⊢", "dashv": "⊣", "models": "⊨",
        "therefore": "∴", "because": "∵", "colon": ":", "coloneqq": "≔",
        "langle": "⟨", "rangle": "⟩", "lceil": "⌈", "rceil": "⌉",
        "lfloor": "⌊", "rfloor": "⌋", "lbrace": "{", "rbrace": "}",
        "lvert": "|", "rvert": "|", "vert": "|", "lVert": "‖", "rVert": "‖", "Vert": "‖",
        "backslash": "∖", "sqcup": "⊔", "sqcap": "⊓", "uplus": "⊎", "amalg": "⨿",
        "triangleq": "≜", "doteq": "≐", "asymp": "≍", "bowtie": "⋈", "wr": "≀",
        "dagger": "†", "ddagger": "‡",
    ]

    /// Large operators — their limits go under and over in display.
    fileprivate static let largeOperators: [String: String] = [
        "sum": "∑", "prod": "∏", "coprod": "∐", "int": "∫", "iint": "∬",
        "iiint": "∭", "oint": "∮", "bigcup": "⋃", "bigcap": "⋂",
        "bigoplus": "⨁", "bigotimes": "⨂", "bigodot": "⨀", "bigvee": "⋁",
        "bigwedge": "⋀", "bigsqcup": "⨆", "biguplus": "⨄",
    ]

    /// Integrals keep their limits beside them, as TeX sets them.
    fileprivate static let integrals: Set<String> = ["int", "iint", "iiint", "oint"]

    /// Named functions, set upright.
    fileprivate static let functions: Set<String> = [
        "sin", "cos", "tan", "cot", "sec", "csc", "arcsin", "arccos", "arctan",
        "sinh", "cosh", "tanh", "coth", "log", "ln", "lg", "exp", "det", "dim",
        "gcd", "deg", "arg", "ker", "hom", "Pr", "mod", "bmod",
    ]

    /// Functions whose subscript goes underneath in display.
    fileprivate static let limitFunctions: Set<String> = [
        "lim", "max", "min", "sup", "inf", "liminf", "limsup", "argmax", "argmin",
    ]

    fileprivate static let accents: [String: (mark: String, under: Bool, stretchy: Bool)] = [
        "hat": ("^", false, false), "widehat": ("^", false, true),
        "bar": ("¯", false, false), "overline": ("¯", false, true),
        "vec": ("→", false, false), "overrightarrow": ("→", false, true),
        "overleftarrow": ("←", false, true),
        "tilde": ("~", false, false), "widetilde": ("~", false, true),
        "dot": ("˙", false, false), "ddot": ("¨", false, false),
        "check": ("ˇ", false, false), "breve": ("˘", false, false),
        "acute": ("´", false, false), "grave": ("`", false, false),
        "underline": ("_", true, true), "overbrace": ("⏞", false, true),
        "underbrace": ("⏟", true, true),
    ]

    fileprivate static let fontVariants: [String: String] = [
        "mathbf": "bold", "boldsymbol": "bold-italic", "bm": "bold-italic",
        "mathit": "italic", "mathrm": "normal", "mathsf": "sans-serif",
        "mathtt": "monospace", "mathbb": "double-struck", "mathcal": "script",
        "mathscr": "script", "mathfrak": "fraktur", "operatorname": "normal",
    ]

    fileprivate static let spaces: [String: String] = [
        ",": "0.1667em", ":": "0.2222em", ">": "0.2222em", ";": "0.2778em",
        " ": "0.25em", "quad": "1em", "qquad": "2em", "enspace": "0.5em",
        "thinspace": "0.1667em", "medspace": "0.2222em", "thickspace": "0.2778em",
    ]

    /// Commands that change nothing a reader sees in MathML.
    fileprivate static let ignored: Set<String> = [
        "displaystyle", "textstyle", "scriptstyle", "scriptscriptstyle",
        "nonumber", "notag", "limits", "nolimits", "!", "left.", "right.",
        "big", "Big", "bigg", "Bigg", "bigl", "bigr", "Bigl", "Bigr", "biggl",
        "biggr", "Biggl", "Biggr", "bigm", "Bigm", "biggm", "Biggm",
        "strut", "mathstrut", "allowbreak", "nobreak", "relax",
    ]

    fileprivate static let delimiters: [String: String] = [
        "(": "(", ")": ")", "[": "[", "]": "]", "|": "|", "/": "/", ".": "",
        "\\{": "{", "\\}": "}", "\\lbrace": "{", "\\rbrace": "}", "\\langle": "⟨",
        "\\rangle": "⟩", "\\lceil": "⌈", "\\rceil": "⌉", "\\lfloor": "⌊",
        "\\rfloor": "⌋", "\\|": "‖", "\\vert": "|", "\\Vert": "‖", "\\lvert": "|",
        "\\rvert": "|", "\\lVert": "‖", "\\rVert": "‖", "<": "⟨", ">": "⟩",
        "\\uparrow": "↑", "\\downarrow": "↓", "\\backslash": "∖",
    ]

    // MARK: The parser

    fileprivate struct Parser {
        let chars: [Character]
        let display: Bool
        var index = 0

        init(tex: String, display: Bool) {
            // Comments are TeX's own; a label is plumbing.
            let cleaned = tex.components(separatedBy: "\n")
                .map { line -> String in
                    var out = ""
                    var previous: Character = " "
                    for character in line {
                        if character == "%", previous != "\\" { break }
                        out.append(character)
                        previous = character
                    }
                    return out
                }
                .joined(separator: " ")
                .replacingOccurrences(of: #"\\(label|tag\*?)\{[^}]*\}"#, with: "",
                                      options: .regularExpression)
            chars = Array(cleaned)
            self.display = display
        }

        var atEnd: Bool { index >= chars.count }

        mutating func skipSpaces() {
            while !atEnd, chars[index].isWhitespace { index += 1 }
        }

        mutating func parseAll() throws -> String {
            let out = try parseSequence(stopAt: [])
            guard atEnd else { throw Unsupported(what: String(chars[index])) }
            return out
        }

        /// A run of atoms until end, `}`, or one of the stop tokens
        /// (`&`, `\\`, `\right`, `\end`, `\middle`) — left unconsumed.
        mutating func parseSequence(stopAt stops: Set<String>) throws -> String {
            var out = ""
            while true {
                skipSpaces()
                if atEnd || chars[index] == "}" { return out }
                if chars[index] == "&", stops.contains("&") { return out }
                if chars[index] == "\\", let name = peekCommand(), stops.contains(name) {
                    return out
                }
                out += try parseScripted()
            }
        }

        func peekCommand() -> String? {
            guard index < chars.count, chars[index] == "\\" else { return nil }
            var cursor = index + 1
            guard cursor < chars.count else { return nil }
            if !chars[cursor].isLetter { return String(chars[cursor]) }
            var name = ""
            while cursor < chars.count, chars[cursor].isLetter {
                name.append(chars[cursor])
                cursor += 1
            }
            return name
        }

        mutating func readCommand() -> String {
            index += 1 // the backslash
            guard !atEnd else { return "" }
            if !chars[index].isLetter {
                let name = String(chars[index])
                index += 1
                return name
            }
            var name = ""
            while !atEnd, chars[index].isLetter {
                name.append(chars[index])
                index += 1
            }
            if name == "operatorname", !atEnd, chars[index] == "*" { index += 1 }
            return name
        }

        /// One atom and any sub/superscripts after it.
        mutating func parseScripted() throws -> String {
            let (base, kind) = try parseAtom()
            var sub: String?
            var sup: String?
            var primes = ""
            while true {
                skipSpaces()
                guard !atEnd else { break }
                if chars[index] == "'" {
                    primes += "′"
                    index += 1
                } else if chars[index] == "_", sub == nil {
                    index += 1
                    sub = try parseArgument()
                } else if chars[index] == "^", sup == nil {
                    index += 1
                    sup = try parseArgument()
                } else if chars[index] == "\\", let name = peekCommand(),
                          name == "limits" || name == "nolimits" {
                    _ = readCommand()
                } else {
                    break
                }
            }
            if !primes.isEmpty {
                let prime = "<mo>\(primes)</mo>"
                sup = sup.map { "<mrow>\(prime)\($0)</mrow>" } ?? prime
            }
            guard sub != nil || sup != nil else { return base }
            // Limits go under and over a large operator (not an
            // integral) or a limit function, in display.
            let underOver = display && (kind == .largeOperator || kind == .limitFunction)
            switch (sub, sup) {
            case let (sub?, sup?):
                return underOver ? "<munderover>\(base)\(sub)\(sup)</munderover>"
                    : "<msubsup>\(base)\(sub)\(sup)</msubsup>"
            case let (sub?, nil):
                return underOver ? "<munder>\(base)\(sub)</munder>" : "<msub>\(base)\(sub)</msub>"
            case let (nil, sup?):
                return underOver ? "<mover>\(base)\(sup)</mover>" : "<msup>\(base)\(sup)</msup>"
            default:
                return base
            }
        }

        enum AtomKind { case ordinary, largeOperator, limitFunction }

        /// A script's argument: a group, or a single atom.
        mutating func parseArgument() throws -> String {
            skipSpaces()
            guard !atEnd else { throw Unsupported(what: "missing argument") }
            if chars[index] == "{" { return try parseGroup() }
            return try parseAtom().0
        }

        mutating func parseGroup() throws -> String {
            guard !atEnd, chars[index] == "{" else { throw Unsupported(what: "expected {") }
            index += 1
            let inner = try parseSequence(stopAt: [])
            guard !atEnd, chars[index] == "}" else { throw Unsupported(what: "unbalanced {") }
            index += 1
            return "<mrow>\(inner)</mrow>"
        }

        /// The raw characters of a `{…}` argument — text, environment
        /// names, column specs.
        mutating func rawGroup() throws -> String {
            skipSpaces()
            guard !atEnd, chars[index] == "{" else { throw Unsupported(what: "expected {") }
            var depth = 0
            var out = ""
            while !atEnd {
                let character = chars[index]
                index += 1
                if character == "{" {
                    depth += 1
                    if depth == 1 { continue }
                } else if character == "}" {
                    depth -= 1
                    if depth == 0 { return out }
                }
                out.append(character)
            }
            throw Unsupported(what: "unbalanced {")
        }

        mutating func optionalBracket() -> String? {
            skipSpaces()
            guard !atEnd, chars[index] == "[" else { return nil }
            var depth = 0
            var out = ""
            var cursor = index
            while cursor < chars.count {
                let character = chars[cursor]
                cursor += 1
                if character == "[" { depth += 1; if depth == 1 { continue } }
                if character == "]" { depth -= 1; if depth == 0 { index = cursor; return out } }
                out.append(character)
            }
            return nil
        }

        mutating func parseAtom() throws -> (String, AtomKind) {
            skipSpaces()
            guard !atEnd else { throw Unsupported(what: "end") }
            let character = chars[index]
            if character == "{" { return (try parseGroup(), .ordinary) }
            if character == "\\" { return try parseCommand() }
            index += 1
            if character.isLetter { return ("<mi>\(escaped(String(character)))</mi>", .ordinary) }
            if character.isNumber {
                var number = String(character)
                while !atEnd, chars[index].isNumber
                        || (chars[index] == "." && index + 1 < chars.count && chars[index + 1].isNumber) {
                    number.append(chars[index])
                    index += 1
                }
                return ("<mn>\(number)</mn>", .ordinary)
            }
            switch character {
            case "-": return ("<mo>−</mo>", .ordinary)
            case "*": return ("<mo>∗</mo>", .ordinary)
            case "~": return ("<mspace width=\"0.25em\"/>", .ordinary)
            case "&", "#", "$", "%", "}": throw Unsupported(what: String(character))
            case "^", "_": throw Unsupported(what: "script without base")
            default:
                if "+=<>()[]|,;:!/.?@".contains(character) {
                    return ("<mo>\(escaped(String(character)))</mo>", .ordinary)
                }
                // Any other character — a Unicode symbol typed straight
                // in — as the identifier or operator it looks like.
                let text = escaped(String(character))
                return (character.isSymbol || character.isPunctuation
                        ? "<mo>\(text)</mo>" : "<mi>\(text)</mi>", .ordinary)
            }
        }

        mutating func parseCommand() throws -> (String, AtomKind) {
            let name = readCommand()
            if let symbol = TeXMathML.identifiers[name] { return ("<mi>\(symbol)</mi>", .ordinary) }
            if let symbol = TeXMathML.operators[name] { return ("<mo>\(escaped(symbol))</mo>", .ordinary) }
            if let symbol = TeXMathML.largeOperators[name] {
                let kind: AtomKind = TeXMathML.integrals.contains(name) ? .ordinary : .largeOperator
                return ("<mo largeop=\"true\">\(symbol)</mo>", kind)
            }
            if TeXMathML.functions.contains(name) {
                return ("<mi>\(name)</mi><mo>\u{2061}</mo>", .ordinary)
            }
            if TeXMathML.limitFunctions.contains(name) {
                let shown = ["liminf": "lim inf", "limsup": "lim sup",
                             "argmax": "arg max", "argmin": "arg min"][name] ?? name
                return ("<mo movablelimits=\"true\" form=\"prefix\">\(shown)</mo>", .limitFunction)
            }
            if let width = TeXMathML.spaces[name] { return ("<mspace width=\"\(width)\"/>", .ordinary) }
            if TeXMathML.ignored.contains(name) { return ("", .ordinary) }
            if let accent = TeXMathML.accents[name] {
                let body = try parseArgument()
                let mark = "<mo stretchy=\"\(accent.stretchy)\">\(escaped(accent.mark))</mo>"
                return (accent.under
                        ? "<munder accentunder=\"true\">\(body)\(mark)</munder>"
                        : "<mover accent=\"true\">\(body)\(mark)</mover>", .ordinary)
            }
            if let variant = TeXMathML.fontVariants[name] {
                if name == "operatorname" {
                    let text = try rawGroup()
                    return ("<mi mathvariant=\"normal\">\(escaped(text))</mi><mo>\u{2061}</mo>", .ordinary)
                }
                let body = try parseArgument()
                // The variant rides each identifier and number inside;
                // "mathrm{dx}" is two upright letters, not one word.
                let styled = body
                    .replacingOccurrences(of: "<mi>", with: "<mi mathvariant=\"\(variant)\">")
                    .replacingOccurrences(of: "<mn>", with: "<mn mathvariant=\"\(variant)\">")
                return (styled, .ordinary)
            }
            switch name {
            case "{", "}", "|", "#", "%", "&", "$", "_":
                let shown = name == "|" ? "‖" : name
                return ("<mo>\(escaped(shown))</mo>", .ordinary)
            case "text", "textrm", "textnormal", "mbox", "textup", "hbox":
                return ("<mtext>\(escaped(try rawGroup()))</mtext>", .ordinary)
            case "textit", "emph":
                return ("<mtext mathvariant=\"italic\">\(escaped(try rawGroup()))</mtext>", .ordinary)
            case "textbf":
                return ("<mtext mathvariant=\"bold\">\(escaped(try rawGroup()))</mtext>", .ordinary)
            case "frac", "dfrac", "tfrac", "cfrac":
                let numerator = try parseArgument()
                let denominator = try parseArgument()
                return ("<mfrac>\(numerator)\(denominator)</mfrac>", .ordinary)
            case "binom", "dbinom", "tbinom":
                let top = try parseArgument()
                let bottom = try parseArgument()
                return ("<mrow><mo>(</mo><mfrac linethickness=\"0\">\(top)\(bottom)</mfrac><mo>)</mo></mrow>", .ordinary)
            case "sqrt":
                if let index = optionalBracket() {
                    var inner = Parser(tex: index, display: false)
                    let degree = try inner.parseAll()
                    let body = try parseArgument()
                    return ("<mroot>\(body)<mrow>\(degree)</mrow></mroot>", .ordinary)
                }
                return ("<msqrt>\(try parseArgument())</msqrt>", .ordinary)
            case "overset", "stackrel":
                let over = try parseArgument()
                let base = try parseArgument()
                return ("<mover>\(base)\(over)</mover>", .ordinary)
            case "underset":
                let under = try parseArgument()
                let base = try parseArgument()
                return ("<munder>\(base)\(under)</munder>", .ordinary)
            case "mathop", "mathrel", "mathbin", "mathord", "mathopen", "mathclose", "mathpunct":
                return (try parseArgument(), .ordinary)
            case "not":
                skipSpaces()
                if !atEnd, chars[index] == "=" { index += 1; return ("<mo>≠</mo>", .ordinary) }
                if let next = peekCommand() {
                    let negated = ["in": "∉", "subset": "⊄", "subseteq": "⊈", "equiv": "≢",
                                   "sim": "≁", "approx": "≉", "mid": "∤", "exists": "∄"]
                    if let symbol = negated[next] {
                        _ = readCommand()
                        return ("<mo>\(symbol)</mo>", .ordinary)
                    }
                }
                throw Unsupported(what: "\\not")
            case "left":
                return (try parseFenced(), .ordinary)
            case "begin":
                return (try parseEnvironment(try rawGroup()), .ordinary)
            case "phantom", "hphantom", "vphantom":
                return ("<mphantom>\(try parseArgument())</mphantom>", .ordinary)
            case "boxed":
                return ("<menclose notation=\"box\">\(try parseArgument())</menclose>", .ordinary)
            case "pmod":
                let body = try parseArgument()
                return ("<mrow><mo>(</mo><mi>mod</mi><mspace width=\"0.2222em\"/>\(body)<mo>)</mo></mrow>", .ordinary)
            default:
                throw Unsupported(what: "\\\(name)")
            }
        }

        /// `\left( … \middle| … \right)` — one fenced row.
        mutating func parseFenced() throws -> String {
            let open = try readDelimiter()
            var out = "<mrow><mo fence=\"true\" stretchy=\"true\">\(escaped(open))</mo>"
            while true {
                out += try parseSequence(stopAt: ["right", "middle"])
                guard !atEnd, let command = peekCommand() else {
                    throw Unsupported(what: "\\left without \\right")
                }
                _ = readCommand()
                let delimiter = try readDelimiter()
                if command == "middle" {
                    out += "<mo stretchy=\"true\">\(escaped(delimiter))</mo>"
                    continue
                }
                out += "<mo fence=\"true\" stretchy=\"true\">\(escaped(delimiter))</mo></mrow>"
                return out
            }
        }

        mutating func readDelimiter() throws -> String {
            skipSpaces()
            guard !atEnd else { throw Unsupported(what: "delimiter") }
            if chars[index] == "\\" {
                let start = index
                let name = readCommand()
                let key = "\\" + name
                if let shown = TeXMathML.delimiters[key] { return shown }
                index = start
                throw Unsupported(what: "delimiter \(key)")
            }
            let key = String(chars[index])
            index += 1
            guard let shown = TeXMathML.delimiters[key] else {
                throw Unsupported(what: "delimiter \(key)")
            }
            return shown
        }

        /// Matrices, cases, arrays and the alignment environments, as
        /// an `<mtable>` — fenced where the environment is.
        mutating func parseEnvironment(_ environment: String) throws -> String {
            let name = environment.trimmingCharacters(in: .whitespaces)
            var columnAlign: [String] = []
            switch name {
            case "array":
                let spec = try rawGroup()
                columnAlign = spec.compactMap {
                    switch $0 { case "l": "left"; case "r": "right"; case "c": "center"; default: nil }
                }
            case "matrix", "pmatrix", "bmatrix", "Bmatrix", "vmatrix", "Vmatrix",
                 "smallmatrix", "cases", "dcases", "aligned", "align", "align*",
                 "alignat", "alignat*", "alignedat", "split", "gathered", "gather",
                 "gather*", "eqnarray", "eqnarray*", "equation", "equation*",
                 "multline", "multline*", "subarray":
                if name.hasPrefix("alignat") { _ = try rawGroup() }
                if name == "subarray" { _ = try rawGroup() }
            default:
                throw Unsupported(what: "environment \(name)")
            }
            if name.hasPrefix("equation") || name.hasPrefix("multline") {
                let body = try parseSequence(stopAt: ["end", "\\"])
                try consumeEnd(name)
                return "<mrow>\(body)</mrow>"
            }
            var rows: [[String]] = [[]]
            while true {
                let cell = try parseSequence(stopAt: ["&", "\\", "end", "hline"])
                rows[rows.count - 1].append(cell)
                skipSpaces()
                guard !atEnd else { throw Unsupported(what: "unclosed \(name)") }
                if chars[index] == "&" {
                    index += 1
                    continue
                }
                let command = readCommand()
                switch command {
                case "\\":
                    _ = optionalBracket() // \\[2pt]
                    rows.append([])
                case "hline":
                    continue
                case "end":
                    let closing = try rawGroup().trimmingCharacters(in: .whitespaces)
                    guard closing == name else { throw Unsupported(what: "\\end{\(closing)}") }
                    // A trailing \\ leaves an empty last row.
                    if let last = rows.last, last.count == 1, last[0].isEmpty, rows.count > 1 {
                        rows.removeLast()
                    }
                    return table(rows, environment: name, columnAlign: columnAlign)
                default:
                    throw Unsupported(what: "\\\(command)")
                }
            }
        }

        mutating func consumeEnd(_ name: String) throws {
            skipSpaces()
            guard peekCommand() == "end" else { throw Unsupported(what: "unclosed \(name)") }
            _ = readCommand()
            guard try rawGroup().trimmingCharacters(in: .whitespaces) == name else {
                throw Unsupported(what: "mismatched \\end")
            }
        }

        func table(_ rows: [[String]], environment name: String, columnAlign: [String]) -> String {
            let columns = rows.map(\.count).max() ?? 1
            var align = columnAlign
            let aligned = ["aligned", "align", "align*", "alignat", "alignat*", "alignedat",
                           "split", "eqnarray", "eqnarray*"].contains(name)
            if aligned {
                // Alignment pairs: right, then left, around each &.
                align = (0..<columns).map { name.hasPrefix("eqnarray")
                    ? ["right", "center", "left"][$0 % 3]
                    : ($0 % 2 == 0 ? "right" : "left") }
            } else if name == "cases" || name == "dcases" {
                align = ["left", "left"]
            }
            let alignAttribute = align.isEmpty ? "" : " columnalign=\"\(align.joined(separator: " "))\""
            let spacing = aligned ? " columnspacing=\"0em 1em\"" : ""
            let body = rows.map { row in
                "<mtr>" + row.map { "<mtd><mrow>\($0)</mrow></mtd>" }.joined() + "</mtr>"
            }.joined()
            let mtable = "<mtable\(alignAttribute)\(spacing)"
                + (aligned ? " displaystyle=\"true\"" : "") + ">\(body)</mtable>"
            let fences: (String, String)? = switch name {
            case "pmatrix": ("(", ")")
            case "bmatrix": ("[", "]")
            case "Bmatrix": ("{", "}")
            case "vmatrix": ("|", "|")
            case "Vmatrix": ("‖", "‖")
            case "cases", "dcases": ("{", "")
            default: nil
            }
            guard let fences else { return mtable }
            let close = fences.1.isEmpty ? "" : "<mo fence=\"true\">\(fences.1)</mo>"
            return "<mrow><mo fence=\"true\">\(fences.0)</mo>\(mtable)\(close)</mrow>"
        }
    }
}
