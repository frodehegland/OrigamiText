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
