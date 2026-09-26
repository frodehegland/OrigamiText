import Foundation

nonisolated struct AddressMatch: Sendable {
    let id: String
    let fragment: String?
    /// Link type written in the address, e.g. "[responds-to:f.hegla.093000k]".
    let rel: String?
    let range: NSRange
}

/// Document and person addressing. Document ids are short, human-readable,
/// and double as the file name (id + ".origamitext"): initial, surname (max 5),
/// creation time HHmmss (UTC), and a day-derived character —
/// "f.hegla.093000k". A person is the prefix of their documents: "f.hegla".
/// Legacy UUID ids remain valid as opaque strings.
nonisolated enum LiquidAddress {

    // MARK: - Identity

    static func nameComponents(author: String) -> (initial: String, surname: String) {
        let parts = author.split(separator: " ").map(String.init)
        let initialSource = sanitize(parts.first ?? "")
        let lastSource = sanitize(parts.count > 1 ? (parts.last ?? "") : (parts.first ?? ""))
        let initial = initialSource.isEmpty ? "x" : String(initialSource.prefix(1))
        let surname = lastSource.isEmpty ? "doc" : String(lastSource.prefix(5))
        return (initial, surname)
    }

    /// The person address: "f.hegla" — the shared prefix of an author's
    /// document addresses.
    static func personPrefix(author: String) -> String {
        let name = nameComponents(author: author)
        return "\(name.initial).\(name.surname)"
    }

    /// Person addresses have exactly two segments and no time part.
    static func isPersonAddress(_ id: String) -> Bool {
        id.range(of: "^[a-z0-9]+\\.[a-z0-9]+$", options: .regularExpression) != nil
    }

    /// Generates a new document id. Falls back to random suffixes on collision.
    static func makeID(author: String, created: Date = .now,
                       isTaken: (String) -> Bool = { _ in false }) -> String {
        let name = nameComponents(author: author)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "HHmmss"
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")

        // One base-36 character from the calendar day disambiguates the
        // "same second on another day" case deterministically.
        let daysSinceEpoch = Int(created.timeIntervalSince1970 / 86_400)
        let dayCharacter = alphabet[((daysSinceEpoch % 36) + 36) % 36]

        let preferred = "\(name.initial).\(name.surname).\(formatter.string(from: created))\(dayCharacter)"
        if !isTaken(preferred) { return preferred }

        for _ in 0..<64 {
            let suffix = String((0..<6).map { _ in alphabet.randomElement() ?? "x" })
            let candidate = "\(name.initial).\(name.surname).\(suffix)"
            if !isTaken(candidate) { return candidate }
        }
        return "\(name.initial).\(name.surname).\(UUID().uuidString.prefix(8).lowercased())"
    }

    /// Whether a string can serve as a document id.
    static func isValid(_ id: String) -> Bool {
        !id.isEmpty
            && !id.contains("#")
            && !id.contains("/")
            && id.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
    }

    /// Canonical form used for storage and comparison.
    static func canonical(_ id: String) -> String {
        id.trimmingCharacters(in: .whitespaces).lowercased()
    }

    // MARK: - Recognizing addresses in text

    private struct PatternSpec {
        let pattern: String
        let relGroup: Int?
        let idGroup: Int
        let fragmentGroup: Int
    }

    // Most specific first:
    //   origamitext://open/<id>[#fragment]
    //   [rel:<id>#fragment], [<id>#fragment], [<id>]   (the citation forms)
    //   bare legacy UUID [#fragment]
    private static let specs = [
        PatternSpec(pattern: "origamitext://open/([A-Za-z0-9][A-Za-z0-9.-]{0,80})(?:#([A-Za-z0-9_.-]+))?",
                    relGroup: nil, idGroup: 1, fragmentGroup: 2),
        PatternSpec(pattern: "\\[(?:([a-z][a-z-]{1,24}):)?([A-Za-z0-9][A-Za-z0-9.-]{2,80})(?:#([A-Za-z0-9_.-]+))?\\]",
                    relGroup: 1, idGroup: 2, fragmentGroup: 3),
        PatternSpec(pattern: "([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})(?:#([A-Za-z0-9_.-]+))?",
                    relGroup: nil, idGroup: 1, fragmentGroup: 2),
    ]

    /// Finds document (and person) addresses in text.
    static func matches(in text: String) -> [AddressMatch] {
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        var results: [AddressMatch] = []
        var covered: [NSRange] = []
        for spec in specs {
            guard let regex = try? NSRegularExpression(pattern: spec.pattern) else { continue }
            for match in regex.matches(in: text, range: fullRange) {
                guard !covered.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { continue }
                let id = canonical(nsText.substring(with: match.range(at: spec.idGroup)))
                let fragment = match.range(at: spec.fragmentGroup).location == NSNotFound
                    ? nil
                    : nsText.substring(with: match.range(at: spec.fragmentGroup))
                var rel: String?
                if let relGroup = spec.relGroup, match.range(at: relGroup).location != NSNotFound {
                    rel = nsText.substring(with: match.range(at: relGroup))
                }
                results.append(AddressMatch(id: id, fragment: fragment, rel: rel, range: match.range))
                covered.append(match.range)
            }
        }
        return results
    }

    /// Addresses are always a–z0–9: they must survive filenames, URLs, and
    /// the ASCII citation patterns above, so names are transliterated to
    /// Latin first (王 → wang, ö → o) rather than filtered to emptiness.
    private static func sanitize(_ string: String) -> String {
        let latin = string.applyingTransform(.toLatin, reverse: false) ?? string
        let folded = latin.folding(options: .diacriticInsensitive,
                                   locale: Locale(identifier: "en_US_POSIX"))
        return folded.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
}
