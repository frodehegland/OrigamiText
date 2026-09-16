import Foundation

// Where gemtext documents come from, and how they keep the same identity
// when they arrive again.
//
// A capsule page is not a file the user filed: it is a fetch, and the same
// page fetched tomorrow must be the same document — same id, same element
// ids, annotations still resolving — with only its digest moved on. So the
// identity of a gemtext source lives here, beside the unmodified bytes
// that arrived, and never in the reader's state.

/// One gemtext source Origami has read: the address it came from, the
/// document it became, and the digests that pin this exact version.
nonisolated struct GemtextSource: Codable, Identifiable, Hashable, Sendable {
    /// The Origami document id this source became — stable per source,
    /// derived once and then remembered here.
    let documentID: String
    /// The canonical address, for a fetched page. A local file import has
    /// none: its identity is its `sourceDigest`.
    var sourceURL: String?
    /// SHA-256 of the raw source bytes, for exact-version provenance.
    var sourceDigest: String
    /// The digest over the assembled blocks — what tells an unmodified
    /// import (re-export the bytes verbatim) from an edited one.
    var contentDigest: String
    var title: String
    /// When these bytes were read. A refetch moves it; the document's own
    /// `created` stays at `firstReadAt`, so its address never shifts.
    var readAt: Date
    var firstReadAt: Date
    /// MIME parameters the server sent with `text/gemini`.
    var charset: String?
    /// The `lang` parameter, mapped to the document's language metadata.
    var language: String?
    /// SHA-256 of the leaf certificate that served it (Gemini is
    /// trust-on-first-use, so the fingerprint IS the server's identity).
    var tlsFingerprint: String?
    /// The fetch ended without a clean TLS close, so these bytes may be
    /// short of what the capsule meant to send. Recorded, never fatal.
    var truncated: Bool = false

    var id: String { documentID }

    /// Whether the document's blocks still say what the stored bytes say.
    func matches(body: [LiquidDoc.Paragraph]) -> Bool {
        contentDigest == Gemtext.contentDigest(of: body)
    }
}

/// The store of gemtext sources: a small registry beside the retained
/// originals, both under the app container.
nonisolated enum GemtextStore {

    /// `…/Application Support/Gemtext/` — `gemini-sources.json` and one
    /// `<document id>.gmi` per source.
    static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Gemtext", isDirectory: true)
    }

    private static var registryURL: URL {
        root.appendingPathComponent("gemini-sources.json")
    }

    static func sources() -> [GemtextSource] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601   // as `remember` writes them
        guard let data = try? Data(contentsOf: registryURL),
              let sources = try? decoder.decode([GemtextSource].self, from: data)
        else { return [] }
        return sources
    }

    static func source(forDocument id: String) -> GemtextSource? {
        sources().first { $0.documentID == id }
    }

    /// The document a page already became, if this capsule page has been
    /// read before — addresses compare canonically (no fragment, no
    /// default port, case-folded host).
    static func source(forURL url: String) -> GemtextSource? {
        let wanted = canonical(url)
        return sources().first { $0.sourceURL.map(canonical) == wanted }
    }

    /// The document identical bytes already became — how a local file
    /// re-imported keeps its id without an address to key on.
    static func source(forDigest digest: String) -> GemtextSource? {
        sources().first { $0.sourceDigest == digest && $0.sourceURL == nil }
    }

    /// The id a source becomes: derived from the address (or, for a local
    /// file, from its bytes), so the derivation is deterministic and the
    /// registry is a record rather than the only copy of the truth.
    ///
    /// Three segments, like every other Origami address — a two-segment id
    /// is what a *person* address looks like (LiquidAddress), and the link
    /// views filter those out of a document's connections.
    static func documentID(forKey key: String) -> String {
        "g.gmi." + String(OrigamiMath.sha256Hex(key).prefix(10))
    }

    /// Records the source and keeps the unmodified original beside it.
    /// The bytes are never touched again — the exporter hands them back
    /// verbatim when the document has not been edited.
    static func remember(_ source: GemtextSource, raw: Data) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? raw.write(to: rawURL(forDocument: source.documentID), options: .atomic)
        var all = sources().filter { $0.documentID != source.documentID }
        all.append(source)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(all) {
            try? data.write(to: registryURL, options: .atomic)
        }
    }

    static func forget(documentID: String) {
        try? FileManager.default.removeItem(at: rawURL(forDocument: documentID))
        let remaining = sources().filter { $0.documentID != documentID }
        guard !remaining.isEmpty else {
            try? FileManager.default.removeItem(at: registryURL)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(remaining) {
            try? data.write(to: registryURL, options: .atomic)
        }
    }

    /// The retained original, `source.gmi` under the document's id.
    static func rawURL(forDocument id: String) -> URL {
        root.appendingPathComponent(id + ".gmi")
    }

    static func rawSource(forDocument id: String) -> String? {
        guard let data = try? Data(contentsOf: rawURL(forDocument: id)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Addresses that name the same page read as the same key: the scheme
    /// and host case-folded, the default port dropped, the fragment gone.
    static func canonical(_ url: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var comps = URLComponents(string: trimmed) else { return trimmed.lowercased() }
        comps.scheme = comps.scheme?.lowercased()
        comps.host = comps.host?.lowercased()
        if comps.scheme == "gemini", comps.port == 1965 { comps.port = nil }
        comps.fragment = nil
        return comps.url?.absoluteString ?? trimmed.lowercased()
    }

    /// The decoder for a fetched body: the charset the server named, with
    /// gemtext's own default (UTF-8) when it named none or named one we
    /// cannot honour.
    static func text(from data: Data, charset: String?) -> String? {
        if let charset = charset?.lowercased().trimmingCharacters(in: .whitespaces),
           !charset.isEmpty, charset != "utf-8", charset != "utf8" {
            let encoding: String.Encoding? = switch charset {
            case "us-ascii", "ascii": .ascii
            case "iso-8859-1", "latin1", "latin-1": .isoLatin1
            case "iso-8859-2", "latin2", "latin-2": .isoLatin2
            case "utf-16": .utf16
            case "windows-1252", "cp1252": .windowsCP1252
            default: nil
            }
            if let encoding, let text = String(data: data, encoding: encoding) { return text }
        }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
    }
}
