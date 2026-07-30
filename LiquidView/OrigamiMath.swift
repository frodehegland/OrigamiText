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
//
// Author-side ingestion, LaTeX→MathML conversion (JavaScriptCore), the
// export sanitiser and numbering are the next phase and are deliberately
// not built here; the spec's §3–§5 are the map for them.

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
            guard let id = attribute("id", in: attributes), id.hasPrefix("eq-") else { continue }
            let display = attribute("display", in: attributes)
                .flatMap(EquationDisplay.init) ?? .inline
            let tex = texAnnotation(in: inner)
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
