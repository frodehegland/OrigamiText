import Foundation

/// A parsed BibTeX entry, pasted into a draft to become a citation line.
nonisolated struct BibTeXEntry {
    let type: String
    let key: String
    let fields: [String: String]
    /// The entry exactly as pasted, kept verbatim for the references block.
    let raw: String

    var title: String? { fields["title"].map(BibTeXParser.displayText) }
    var year: String? { fields["year"].map(BibTeXParser.displayText) }

    var hasMultipleAuthors: Bool {
        (fields["author"] ?? "").contains(" and ")
    }

    /// First author in "First Last" order (accepts "Last, First").
    var firstAuthor: String? {
        guard let raw = fields["author"].map(BibTeXParser.displayText) else { return nil }
        let first = raw.components(separatedBy: " and ").first ?? raw
        if first.contains(",") {
            let parts = first.split(separator: ",", maxSplits: 1)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 { return "\(parts[1]) \(parts[0])" }
        }
        let trimmed = first.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    var created: Date? {
        fields["vm-id"].flatMap { LiquidDoc.parseISO8601($0) }
    }

    /// The deterministic library address, when the entry carries Visual-Meta
    /// identity (vm-id + author) — resolves now or when the document arrives.
    var derivedID: String? {
        guard let created, let firstAuthor else { return nil }
        return LiquidAddress.makeID(author: firstAuthor, created: created)
    }

    var externalURL: String? {
        if let doi = fields["doi"], !doi.isEmpty {
            return doi.hasPrefix("http") ? doi : "https://doi.org/\(doi)"
        }
        return fields["url"]
    }

    /// The citation as a readable sentence: “Title” (Author, Year) [address]
    /// — the same form used by Copy to Cite, so citations look alike
    /// wherever they come from.
    var citationText: String {
        var parts: [String] = []
        if let title { parts.append("“\(title)”") }
        var credit: [String] = []
        if let firstAuthor { credit.append(hasMultipleAuthors ? "\(firstAuthor) et al." : firstAuthor) }
        if let year { credit.append(year) }
        if !credit.isEmpty { parts.append("(\(credit.joined(separator: ", ")))") }
        if let derivedID {
            parts.append("[\(derivedID)]")
        } else if let externalURL {
            parts.append(externalURL)
        }
        return parts.joined(separator: " ")
    }
}

nonisolated enum BibTeXParser {

    /// Parses one or more BibTeX entries. Returns [] for anything that
    /// isn't BibTeX, so ordinary pasting is never hijacked.
    static func parse(_ text: String) -> [BibTeXEntry] {
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("@") else { return [] }
        var entries: [BibTeXEntry] = []
        let characters = Array(text)
        var index = 0

        while index < characters.count {
            guard characters[index] == "@" else { index += 1; continue }
            let entryStart = index
            var cursor = index + 1
            var type = ""
            while cursor < characters.count, characters[cursor].isLetter {
                type.append(characters[cursor])
                cursor += 1
            }
            while cursor < characters.count, characters[cursor].isWhitespace { cursor += 1 }
            guard !type.isEmpty, cursor < characters.count, characters[cursor] == "{" else {
                index += 1
                continue
            }
            cursor += 1
            var depth = 1
            var body = ""
            while cursor < characters.count {
                let character = characters[cursor]
                if character == "{" { depth += 1 }
                if character == "}" {
                    depth -= 1
                    if depth == 0 { break }
                }
                body.append(character)
                cursor += 1
            }
            let entryEnd = min(cursor, characters.count - 1)
            let raw = String(characters[entryStart...entryEnd])
            if let entry = makeEntry(type: type.lowercased(), body: body, raw: raw) {
                entries.append(entry)
            }
            index = cursor + 1
        }
        return entries
    }

    private static func makeEntry(type: String, body: String, raw: String) -> BibTeXEntry? {
        let characters = Array(body)
        var cursor = 0

        func skipSeparators() {
            while cursor < characters.count,
                  characters[cursor].isWhitespace || characters[cursor] == "," {
                cursor += 1
            }
        }

        // Citation key runs up to the first comma.
        var key = ""
        while cursor < characters.count, characters[cursor] != "," {
            key.append(characters[cursor])
            cursor += 1
        }
        key = key.trimmingCharacters(in: .whitespacesAndNewlines)

        var fields: [String: String] = [:]
        while cursor < characters.count {
            skipSeparators()
            var name = ""
            while cursor < characters.count, characters[cursor] != "=" {
                name.append(characters[cursor])
                cursor += 1
            }
            guard cursor < characters.count else { break }
            cursor += 1   // consume "="
            while cursor < characters.count, characters[cursor].isWhitespace { cursor += 1 }
            guard cursor < characters.count else { break }

            var value = ""
            if characters[cursor] == "{" {
                cursor += 1
                var depth = 1
                while cursor < characters.count {
                    let character = characters[cursor]
                    if character == "{" { depth += 1 }
                    if character == "}" {
                        depth -= 1
                        if depth == 0 { break }
                    }
                    value.append(character)
                    cursor += 1
                }
                cursor += 1
            } else if characters[cursor] == "\"" {
                cursor += 1
                while cursor < characters.count, characters[cursor] != "\"" {
                    value.append(characters[cursor])
                    cursor += 1
                }
                cursor += 1
            } else {
                while cursor < characters.count, characters[cursor] != "," {
                    value.append(characters[cursor])
                    cursor += 1
                }
            }

            let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !cleanName.isEmpty {
                fields[cleanName] = cleaned(value)
            }
        }

        guard fields["title"] != nil || fields["author"] != nil else { return nil }
        return BibTeXEntry(type: type, key: key, fields: fields, raw: raw)
    }

    /// Parses the first entry, or nil.
    static func first(_ text: String) -> BibTeXEntry? { parse(text).first }

    /// Strips residual braces and LaTeX-isms, and heals line wraps.
    private static func cleaned(_ value: String) -> String {
        value
            .replacingOccurrences(of: "{", with: "")
            .replacingOccurrences(of: "}", with: "")
            .replacingOccurrences(of: "\\&", with: "&")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

// MARK: - Reference verification (Preflight)

/// Serializes a field dictionary back into a BibTeX entry, preserving the
/// entry's type and key. The common fields lead, in a stable order, then any
/// others alphabetically, so a verified reference reads cleanly.
nonisolated enum BibTeXWriter {
    private static let leading = ["title", "author", "year", "journal", "booktitle",
                                  "container-title", "publisher", "volume", "number",
                                  "pages", "doi", "url"]

    static func write(type: String, key: String, fields: [String: String]) -> String {
        let type = type.isEmpty ? "article" : type
        let key = key.isEmpty ? "ref" : key
        let present = fields.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
        let ordered = leading.filter { present[$0] != nil }
            + present.keys.filter { !leading.contains($0) }.sorted()
        let lines = ordered.map { name in
            "  \(name) = {\(escape(present[name] ?? ""))}"
        }
        return "@\(type){\(key),\n\(lines.joined(separator: ",\n"))\n}"
    }

    private static func escape(_ value: String) -> String {
        // The BibTeX specials, backslash first, matching the house rule.
        var out = value.replacingOccurrences(of: "\\", with: "\\textbackslash{}")
        for (character, escaped) in [("&", "\\&"), ("%", "\\%"), ("#", "\\#"),
                                     ("$", "\\$"), ("_", "\\_")] {
            out = out.replacingOccurrences(of: character, with: escaped)
        }
        return out
    }
}

/// A reference verification service. Given the reference's own fields, it
/// returns the fields it finds, or nil when it can't match.
protocol ReferenceVerifier: Sendable {
    var id: String { get }
    var name: String { get }
    func lookup(fields: [String: String]) async -> [String: String]?
}

/// Crossref (api.crossref.org): free scholarly metadata, no key. Matches by
/// DOI when present, otherwise by a bibliographic query of title + authors.
nonisolated struct CrossrefVerifier: ReferenceVerifier {
    let id = "crossref"
    let name = "Crossref"

    func lookup(fields: [String: String]) async -> [String: String]? {
        let doi = (fields["doi"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "https://doi.org/", with: "")
        if !doi.isEmpty, let work = await fetchByDOI(doi) { return work }
        let title = fields["title"] ?? ""
        guard !title.isEmpty else { return nil }
        return await queryBibliographic(title: title, authors: fields["author"] ?? "")
    }

    private func fetchByDOI(_ doi: String) async -> [String: String]? {
        guard let encoded = doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://api.crossref.org/works/\(encoded)") else { return nil }
        guard let message = await message(from: url) else { return nil }
        return Self.fields(fromWork: message)
    }

    private func queryBibliographic(title: String, authors: String) async -> [String: String]? {
        var components = URLComponents(string: "https://api.crossref.org/works")
        let query = ([title, authors].filter { !$0.isEmpty }).joined(separator: " ")
        components?.queryItems = [
            URLQueryItem(name: "query.bibliographic", value: query),
            URLQueryItem(name: "rows", value: "1"),
        ]
        guard let url = components?.url,
              let message = await message(from: url),
              let items = message["items"] as? [[String: Any]],
              let first = items.first else { return nil }
        return Self.fields(fromWork: first)
    }

    /// GETs a Crossref URL and returns the `message` object.
    private func message(from url: URL) async -> [String: Any]? {
        var request = URLRequest(url: url, timeoutInterval: 20)
        // Crossref's "polite pool" asks callers to identify themselves.
        request.setValue("OrigamiText/1.0 (mailto:frode@hegland.com)",
                         forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json["message"] as? [String: Any]
    }

    /// Maps a Crossref work object to comparable BibTeX-style fields.
    private static func fields(fromWork work: [String: Any]) -> [String: String] {
        var result: [String: String] = [:]
        if let titles = work["title"] as? [String], let title = titles.first, !title.isEmpty {
            result["title"] = title
        }
        if let authors = work["author"] as? [[String: Any]] {
            let names = authors.compactMap { person -> String? in
                let given = (person["given"] as? String) ?? ""
                let family = (person["family"] as? String) ?? (person["name"] as? String) ?? ""
                let name = "\(given) \(family)".trimmingCharacters(in: .whitespaces)
                return name.isEmpty ? nil : name
            }
            if !names.isEmpty { result["author"] = names.joined(separator: " and ") }
        }
        if let issued = work["issued"] as? [String: Any],
           let parts = issued["date-parts"] as? [[Int]], let year = parts.first?.first {
            result["year"] = String(year)
        }
        if let containers = work["container-title"] as? [String], let journal = containers.first, !journal.isEmpty {
            result["journal"] = journal
        }
        if let publisher = work["publisher"] as? String, !publisher.isEmpty {
            result["publisher"] = publisher
        }
        if let doi = work["DOI"] as? String, !doi.isEmpty { result["doi"] = doi }
        if let urlString = work["URL"] as? String, !urlString.isEmpty { result["url"] = urlString }
        return result
    }
}

/// The verifiers the user has enabled in Settings. (The key is
/// AppSettings.verifyCrossrefKey's, spelled out so this file compiles
/// on targets without SettingsView.)
@MainActor
enum ReferenceVerification {
    static var enabledVerifiers: [any ReferenceVerifier] {
        var verifiers: [any ReferenceVerifier] = []
        if UserDefaults.standard.object(forKey: "verifyReferencesCrossref") as? Bool ?? true {
            verifiers.append(CrossrefVerifier())
        }
        return verifiers
    }
}

extension BibTeXParser {

    /// A BibTeX field as display text: TeX accents composed onto their
    /// letters, escapes resolved, emphasis unwrapped to its words,
    /// braces shed, dashes and quotes typographic. The raw record stays
    /// raw — this is only for the words a reader sees (the HT '26
    /// conversion shipped "Lu\'\is Borges" into a reference list; the
    /// PDF prints "Luís Borges").
    nonisolated static func displayText(_ raw: String) -> String {
        var text = raw

        // Inline math in a field ($\lambda$-calculus): readable when
        // simple; its characters, sans dollars, either way.
        while let range = text.range(of: #"\$([^$\n]+)\$"#, options: .regularExpression) {
            let inner = String(text[range].dropFirst().dropLast())
            text.replaceSubrange(range, with: readableMath(inner)
                ?? convertingTeXSymbols(in: inner))
        }

        // Escaped specials first, shielded so later cleanup cannot
        // mistake them for syntax.
        for (from, to) in [("\\&", "&"), ("\\%", "%"), ("\\#", "#"),
                           ("\\$", "$"), ("\\_", "_"),
                           ("\\textbackslash{}", "\\"), ("\\ ", " "),
                           ("\\,", " "), ("\\-", "")] {
            text = text.replacingOccurrences(of: from, with: to)
        }

        // An accent over TeX's dotless \i or \j with its braces already
        // shed upstream (Lu\'\is): drop the inner backslash so the mark
        // composes onto a plain letter.
        text = text.replacingOccurrences(of: #"\\(['`^"~=.])\\([ij])"#,
                                         with: #"\\$1$2"#,
                                         options: .regularExpression)

        // TeX's dotless \i and \j exist only so an accent can sit
        // cleanly; the plain letter composes correctly ("Luís").
        text = text.replacingOccurrences(of: #"\\i(?![a-zA-Z])\s*"#, with: "i",
                                         options: .regularExpression)
        text = text.replacingOccurrences(of: #"\\j(?![a-zA-Z])\s*"#, with: "j",
                                         options: .regularExpression)

        // Accents compose onto their letter — \'{e}, \'e, {\'e} alike.
        let symbolMarks: [Character: String] = [
            "'": "\u{0301}", "`": "\u{0300}", "^": "\u{0302}",
            "\"": "\u{0308}", "~": "\u{0303}", "=": "\u{0304}", ".": "\u{0307}",
        ]
        for (mark, accent) in symbolMarks {
            // Either a braced letter or a bare one — never a bare letter
            // plus someone else's closing brace (\textnormal{Kenk\=o}
            // must keep its wrapper's brace; eating it mangled the rest).
            let pattern = "\\\\\(NSRegularExpression.escapedPattern(for: String(mark)))(?:\\{([a-zA-Z])\\}|([a-zA-Z]))"
            while let range = text.range(of: pattern, options: .regularExpression) {
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

        // An accent mark that never found its letter — the authors'
        // typo, which LaTeX prints as a floating accent — degrades to
        // the spacing accent character, never a raw backslash.
        for (mark, spacing) in [("'", "\u{00B4}"), ("`", "\u{02CB}"),
                                ("^", "\u{02C6}"), ("\"", "\u{00A8}"),
                                ("~", "\u{02DC}"), ("=", "\u{00AF}"),
                                (".", "\u{02D9}")] {
            text = text.replacingOccurrences(of: "\\" + mark, with: spacing)
        }

        // Whatever command remains unwraps to its argument (twice, for
        // nesting) — \emph{words} keeps its words — then bare commands drop.
        for _ in 0..<2 {
            while let range = text.range(of: #"\\[a-zA-Z]+\*?\{"#, options: .regularExpression) {
                let start = text.distance(from: text.startIndex, to: range.lowerBound)
                guard let open = text[range.lowerBound...].firstIndex(of: "{") else { break }
                var depth = 0
                var end: String.Index?
                var cursor = open
                while cursor < text.endIndex {
                    if text[cursor] == "{" { depth += 1 }
                    if text[cursor] == "}" { depth -= 1; if depth == 0 { end = cursor; break } }
                    cursor = text.index(after: cursor)
                }
                guard let end else { break }
                let inner = String(text[text.index(after: open)..<end])
                text.replaceSubrange(range.lowerBound...end, with: inner)
                _ = start
            }
        }
        text = text.replacingOccurrences(of: #"\\[a-zA-Z]+\*?"#,
                                         with: "", options: .regularExpression)

        // Typography, then the braces vanish.
        text = text.replacingOccurrences(of: "``", with: "\u{201C}")
            .replacingOccurrences(of: "''", with: "\u{201D}")
            .replacingOccurrences(of: "---", with: "\u{2014}")
            .replacingOccurrences(of: "--", with: "\u{2013}")
            .replacingOccurrences(of: "~", with: "\u{00A0}")
            .replacingOccurrences(of: "{", with: "")
            .replacingOccurrences(of: "}", with: "")
        text = typographicQuotes(text)

        return text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

extension BibTeXParser {

    /// Straight quotes become their typographic forms, the way the
    /// audience reads them: a bare ' is an apostrophe or a closing
    /// quote (\u{2019}) unless it opens a quoted word — after a space
    /// or an opener, before a letter (so Tinderbox's and the '90s both
    /// come out right); a bare " opens (\u{201C}) after a space or an
    /// opener and closes (\u{201D}) everywhere else. TeX's own forms
    /// (`` '' ` ') are mapped before this runs; these are the strays
    /// authors typed straight.
    nonisolated static func typographicQuotes(_ text: String) -> String {
        guard text.contains("'") || text.contains("\"") else { return text }
        let characters = Array(text)
        var out = ""
        out.reserveCapacity(characters.count)
        for index in characters.indices {
            let character = characters[index]
            guard character == "'" || character == "\"" else {
                out.append(character)
                continue
            }
            let previous = out.last ?? "\n"
            let next = index + 1 < characters.count ? characters[index + 1] : " "
            let afterOpener = previous.isWhitespace || previous.isNewline
                || "([{\u{201C}\u{2018}\u{2014}\u{2013}/".contains(previous)
            if character == "'" {
                out.append(afterOpener && next.isLetter ? "\u{2018}" : "\u{2019}")
            } else {
                out.append(afterOpener && !next.isWhitespace ? "\u{201C}" : "\u{201D}")
            }
        }
        return out
    }

    /// TeX's symbol commands as the characters they mean — Greek,
    /// operators, arrows. Whole-command matches only (maximal munch:
    /// \intro never reads as \int + ro).
    nonisolated static let texSymbols: [String: String] = [
        // Greek, lower
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ",
        "epsilon": "ε", "varepsilon": "ε", "zeta": "ζ", "eta": "η",
        "theta": "θ", "vartheta": "ϑ", "iota": "ι", "kappa": "κ",
        "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "pi": "π",
        "varpi": "ϖ", "rho": "ρ", "varrho": "ϱ", "sigma": "σ",
        "varsigma": "ς", "tau": "τ", "upsilon": "υ", "phi": "ϕ",
        "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
        // Greek, upper
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ",
        "Xi": "Ξ", "Pi": "Π", "Sigma": "Σ", "Upsilon": "Υ",
        "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
        // Operators and relations
        "pm": "±", "mp": "∓", "times": "×", "cdot": "·", "div": "÷",
        "leq": "≤", "le": "≤", "geq": "≥", "ge": "≥", "neq": "≠",
        "ne": "≠", "approx": "≈", "sim": "∼", "simeq": "≃",
        "equiv": "≡", "propto": "∝", "infty": "∞", "partial": "∂",
        "nabla": "∇", "forall": "∀", "exists": "∃", "neg": "¬",
        "land": "∧", "lor": "∨", "cup": "∪", "cap": "∩",
        "subset": "⊂", "supset": "⊃", "subseteq": "⊆", "supseteq": "⊇",
        "in": "∈", "notin": "∉", "ni": "∋", "emptyset": "∅",
        "oplus": "⊕", "otimes": "⊗", "perp": "⊥", "parallel": "∥",
        "angle": "∠", "circ": "∘", "bullet": "•", "star": "⋆",
        "dagger": "†", "ddagger": "‡", "ell": "ℓ", "hbar": "ℏ",
        "Re": "ℜ", "Im": "ℑ", "aleph": "ℵ", "prime": "′",
        "sum": "∑", "prod": "∏", "int": "∫", "sqrt": "√",
        "cdots": "⋯", "ldots": "…", "dots": "…", "vdots": "⋮",
        // Arrows
        "rightarrow": "→", "to": "→", "leftarrow": "←", "gets": "←",
        "Rightarrow": "⇒", "Leftarrow": "⇐", "leftrightarrow": "↔",
        "Leftrightarrow": "⇔", "mapsto": "↦", "uparrow": "↑",
        "downarrow": "↓", "longrightarrow": "⟶", "implies": "⟹",
        // Named operators stay their names
        "log": "log", "ln": "ln", "exp": "exp", "sin": "sin",
        "cos": "cos", "tan": "tan", "min": "min", "max": "max",
        "arg": "arg", "det": "det", "dim": "dim", "mod": "mod",
        // Delimiter and spacing chrome
        "lvert": "|", "rvert": "|", "lVert": "‖", "rVert": "‖",
        "left": "", "right": "", "quad": " ", "qquad": "  ",
        "langle": "⟨", "rangle": "⟩", "lfloor": "⌊", "rfloor": "⌋",
        "lceil": "⌈", "rceil": "⌉", "mid": "|", "setminus": "∖",
    ]

    /// Every `\command` the table knows becomes its character; unknown
    /// commands stay for the caller's own rules. Prose and math alike —
    /// a `\lambda` means λ wherever it stands.
    nonisolated static func convertingTeXSymbols(in text: String) -> String {
        guard text.contains("\\") else { return text }
        var out = ""
        out.reserveCapacity(text.count)
        var rest = text[...]
        while let backslash = rest.firstIndex(of: "\\") {
            out += rest[..<backslash]
            let after = rest[rest.index(after: backslash)...]
            let letters = after.prefix { $0.isLetter }
            if !letters.isEmpty, let symbol = texSymbols[String(letters)] {
                out += symbol
                rest = after[after.index(after.startIndex, offsetBy: letters.count)...]
                // TeX eats the space after a command name; so do we.
                if rest.first == " ", symbol.last?.isLetter == false {
                    // keep the space — symbols read better spaced
                }
            } else {
                out += "\\"
                rest = after
            }
        }
        out += rest
        return out
    }

    private nonisolated static let subscriptForms: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅",
        "6": "₆", "7": "₇", "8": "₈", "9": "₉", "+": "₊", "-": "₋",
        "=": "₌", "(": "₍", ")": "₎", "a": "ₐ", "e": "ₑ", "h": "ₕ",
        "i": "ᵢ", "j": "ⱼ", "k": "ₖ", "l": "ₗ", "m": "ₘ", "n": "ₙ",
        "o": "ₒ", "p": "ₚ", "r": "ᵣ", "s": "ₛ", "t": "ₜ", "u": "ᵤ",
        "v": "ᵥ", "x": "ₓ", "β": "ᵦ", "γ": "ᵧ", "ρ": "ᵨ", "φ": "ᵩ",
        "χ": "ᵪ",
    ]
    private nonisolated static let superscriptForms: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵",
        "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹", "+": "⁺", "-": "⁻",
        "=": "⁼", "(": "⁽", ")": "⁾", "n": "ⁿ", "i": "ⁱ", "a": "ᵃ",
        "b": "ᵇ", "c": "ᶜ", "d": "ᵈ", "e": "ᵉ", "f": "ᶠ", "g": "ᵍ",
        "h": "ʰ", "j": "ʲ", "k": "ᵏ", "l": "ˡ", "m": "ᵐ", "o": "ᵒ",
        "p": "ᵖ", "r": "ʳ", "s": "ˢ", "t": "ᵗ", "u": "ᵘ", "v": "ᵛ",
        "w": "ʷ", "x": "ˣ", "y": "ʸ", "z": "ᶻ", "T": "ᵀ", "*": "*",
    ]

    /// A math span's inside made readable, or nil when structure the
    /// table cannot speak for remains (a fraction, a matrix — those
    /// stay verbatim TeX). Wrappers unwrap to their words (\text,
    /// \mathrm, \operatorname), letter styles restyle (\mathcal,
    /// \mathbf), accents compose (\hat, \bar, \tilde, \vec), then
    /// sub- and superscripts take their Unicode forms where every
    /// character has one — else they keep a plain _ or ^, honest and
    /// legible ("λ_δ").
    nonisolated static func readableMath(_ inner: String) -> String? {
        var text = convertingTeXSymbols(in: inner)

        // Wrappers: the argument's words stay.
        for wrapper in ["text", "textrm", "textit", "textbf", "texttt",
                        "mathrm", "mathit", "mathsf", "mathtt",
                        "operatorname", "mathop", "boldsymbol"] {
            while let range = text.range(of: "\\\(wrapper){") {
                guard let (value, whole) = bracedArgument(in: text, from: range) else { break }
                // Braces stay for now, so a following _ or ^ still sees
                // its group; they shed at the end.
                text.replaceSubrange(whole, with: "{" + value + "}")
            }
        }
        // Letter styles.
        let calligraphic: [Character: String] = [
            "A": "𝒜", "B": "ℬ", "C": "𝒞", "D": "𝒟", "E": "ℰ", "F": "ℱ",
            "G": "𝒢", "H": "ℋ", "I": "ℐ", "J": "𝒥", "K": "𝒦", "L": "ℒ",
            "M": "ℳ", "N": "𝒩", "O": "𝒪", "P": "𝒫", "Q": "𝒬", "R": "ℛ",
            "S": "𝒮", "T": "𝒯", "U": "𝒰", "V": "𝒱", "W": "𝒲", "X": "𝒳",
            "Y": "𝒴", "Z": "𝒵",
        ]
        while let range = text.range(of: "\\mathcal{") {
            guard let (value, whole) = bracedArgument(in: text, from: range) else { break }
            let styled = value.map { character -> String in
                calligraphic[character] ?? String(character)
            }.joined()
            text.replaceSubrange(whole, with: "{" + styled + "}")
        }
        while let range = text.range(of: "\\mathbf{") {
            guard let (value, whole) = bracedArgument(in: text, from: range) else { break }
            text.replaceSubrange(whole, with: value)
        }
        // Accents.
        for (accent, mark) in [("hat", "\u{0302}"), ("bar", "\u{0304}"),
                               ("tilde", "\u{0303}"), ("vec", "\u{20D7}"),
                               ("dot", "\u{0307}"), ("overline", "\u{0304}")] {
            while let range = text.range(of: "\\\(accent){") {
                guard let (value, whole) = bracedArgument(in: text, from: range) else { break }
                let composed = value.count == 1
                    ? (value + mark).precomposedStringWithCanonicalMapping
                    : value
                text.replaceSubrange(whole, with: composed)
            }
        }
        // Spacing commands.
        for (from, to) in [("\\,", " "), ("\\;", " "), ("\\:", " "),
                           ("\\!", ""), ("\\ ", " ")] {
            text = text.replacingOccurrences(of: from, with: to)
        }

        guard !text.contains("\\") else { return nil }

        // Sub- and superscripts.
        for (marker, forms) in [("_", subscriptForms), ("^", superscriptForms)] {
            var out = ""
            var rest = text[...]
            while let mark = rest.firstIndex(of: Character(marker)) {
                out += rest[..<mark]
                var group = ""
                var next = rest.index(after: mark)
                if next < rest.endIndex, rest[next] == "{" {
                    var depth = 0
                    var cursor = next
                    var closing: String.Index?
                    while cursor < rest.endIndex {
                        if rest[cursor] == "{" { depth += 1 }
                        if rest[cursor] == "}" { depth -= 1; if depth == 0 { closing = cursor; break } }
                        cursor = rest.index(after: cursor)
                    }
                    if let closing {
                        group = String(rest[rest.index(after: next)..<closing])
                        next = rest.index(after: closing)
                    }
                } else if next < rest.endIndex {
                    group = String(rest[next])
                    next = rest.index(after: next)
                }
                let mapped = group.map { forms[$0].map(String.init) }
                if !group.isEmpty, mapped.allSatisfy({ $0 != nil }) {
                    out += mapped.compactMap { $0 }.joined()
                } else {
                    out += marker + group
                }
                rest = rest[next...]
            }
            out += rest
            text = out
        }

        // Stray braces shed; whitespace settles.
        text = text.replacingOccurrences(of: "{", with: "")
            .replacingOccurrences(of: "}", with: "")
        return text.components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// The braced argument starting at `range`'s trailing "{": its value
    /// and the whole command's range, or nil when unbalanced.
    private nonisolated static func bracedArgument(
        in text: String, from range: Range<String.Index>)
        -> (value: String, whole: Range<String.Index>)? {
        let open = text.index(before: range.upperBound)
        var depth = 0
        var cursor = open
        while cursor < text.endIndex {
            if text[cursor] == "{" { depth += 1 }
            if text[cursor] == "}" {
                depth -= 1
                if depth == 0 {
                    let value = String(text[text.index(after: open)..<cursor])
                    return (value, range.lowerBound..<text.index(after: cursor))
                }
            }
            cursor = text.index(after: cursor)
        }
        return nil
    }
}
