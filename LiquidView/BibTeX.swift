import Foundation

/// A parsed BibTeX entry, pasted into a draft to become a citation line.
nonisolated struct BibTeXEntry {
    let type: String
    let key: String
    let fields: [String: String]
    /// The entry exactly as pasted, kept verbatim for the references block.
    let raw: String

    var title: String? { fields["title"] }
    var year: String? { fields["year"] }

    var hasMultipleAuthors: Bool {
        (fields["author"] ?? "").contains(" and ")
    }

    /// First author in "First Last" order (accepts "Last, First").
    var firstAuthor: String? {
        guard let raw = fields["author"] else { return nil }
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
