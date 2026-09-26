// Brought across from Knowledge Space (OrigamiText/InteratlasCitation.swift),
// itself ported from Augmented Library. Keep in step with both; a fix
// here should be carried back.
import Foundation
import Compression

// Ported from Augmented Library's InteratlasCitation.swift — access
// levels dropped, and the real link host added to the placeholder
// (worth carrying back). A fix here should be carried across.
//
// Updated to the Liquid Information link rules of 2026-08-19
// (LiquidInformationFormat.md v2): links may carry the complete scene
// in a `scene` query parameter, so the href is opaque — scheme swaps
// are string surgery, never a URL-components round-trip that could
// re-encode, re-sort, or case-fold the payload. The citable PNG's
// `liquid-scene` chunk is read as an equal carrier.

/// The URL with only its scheme swapped, by string surgery: everything
/// after the first colon travels untouched. A `scene` payload dies of
/// re-encoding; treating the link as text is the format's rule.
private nonisolated func swappingScheme(_ url: URL, to scheme: String) -> URL? {
    let text = url.absoluteString
    guard let colon = text.firstIndex(of: ":") else { return nil }
    return URL(string: scheme + text[colon...])
}

/// The Interatlas Link: a plain https URL on the Interatlas link domain,
/// path `/v1/<realm>`, whose query captures a complete view state (layers,
/// time, camera, selection, marks). Recognition is by host alone — the
/// format's rule is never to parse deeper just to recognise one — and
/// opening is plain `openURL`; universal-link routing does the rest.
nonisolated enum InteratlasLink {

    /// The hosts recognised as Interatlas link domains: the live one,
    /// and the spec's placeholder kept for documents written to it.
    static let hosts: Set<String> = [
        "link.augmentedtext.com",
        "link.interatlas.example",
    ]

    /// Whether a URL is an Interatlas Link — a match on the known link
    /// host, nothing more.
    static func isInteratlasLink(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return hosts.contains(host)
    }

    /// Convenience for link fields kept as text on records.
    static func isInteratlasLink(_ text: String) -> Bool {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespaces)) else { return false }
        return isInteratlasLink(url)
    }

    /// The link in its scheme form: the https URL with only its scheme
    /// swapped to `interatlas://` — the convention Interatlas's receiver
    /// reads, one parser serving both forms. Nil when the URL cannot be
    /// recomposed.
    static func schemed(_ url: URL) -> URL? {
        swappingScheme(url, to: "interatlas")
    }
}

/// The Liquid view link: the same link domain, path `/liquid/…`, minted
/// by Author's 3D view export ("View: …" citations). The URL carries the
/// whole view state; the receiving app is Liquid, not Interatlas —
/// recognition is the known host plus the /liquid/ path, still never
/// parsing deeper than needed to recognise.
nonisolated enum LiquidViewLink {

    /// Whether a URL is a Liquid view link — the shared link domain
    /// carrying the /liquid/ path.
    static func isLiquidViewLink(_ url: URL) -> Bool {
        guard InteratlasLink.isInteratlasLink(url) else { return false }
        return url.path.lowercased().hasPrefix("/liquid/")
    }

    /// Convenience for link fields kept as text on records.
    static func isLiquidViewLink(_ text: String) -> Bool {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespaces)) else { return false }
        return isLiquidViewLink(url)
    }

    /// The link in its scheme forms, newest first: `liquidinfo://` —
    /// the scheme Liquid Information declares — then the older
    /// `liquid://` that LiquidView claimed, so a receiver is offered
    /// whichever door it actually has.
    static func schemedForms(_ url: URL) -> [URL] {
        ["liquidinfo", "liquid"].compactMap { swappingScheme(url, to: $0) }
    }

    /// The primary scheme form (`liquidinfo://`), for the platforms
    /// that try one scheme and fall back to the https link.
    static func schemed(_ url: URL) -> URL? {
        schemedForms(url).first
    }

    /// The link's `scene` payload decoded to its JSON text — the
    /// complete `.liquidinfo` document the URL itself carries
    /// (2026-08-19 links): base64url → zlib (RFC 1950) → UTF-8 JSON.
    /// The query is read as plain text, never through a re-encoding
    /// URL library; any failure at any stage reads as "no scene
    /// present", never an error.
    static func sceneJSON(from url: URL) -> String? {
        guard let query = url.absoluteString
            .split(separator: "?", maxSplits: 1).dropFirst().first else { return nil }
        guard let raw = query.split(separator: "&")
            .first(where: { $0.hasPrefix("scene=") })?
            .dropFirst("scene=".count), !raw.isEmpty else { return nil }
        var base64 = String(raw)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let compressed = Data(base64Encoded: base64), compressed.count > 6
        else { return nil }
        // Liquid Information's PNGs of 2026-08-19 write the payload as
        // a raw DEFLATE stream; the spec's earlier wording said zlib
        // (RFC 1950) — the same stream inside a 2-byte header and an
        // Adler-32. Both read: raw first, then the header stepped over
        // and the trailer left unread. The scene is a JSON object, so
        // an opening brace tells a true reading from a false one.
        for candidate in [compressed, Data(compressed.dropFirst(2))] {
            if let text = inflated(candidate),
               text.drop(while: { $0 == " " || $0 == "\n" }).first == "{" {
                return text
            }
        }
        return nil
    }

    /// Whether a link already carries its scene — a `scene` query read
    /// as plain text, by the format's never-reparse rule.
    static func carriesScene(_ url: URL) -> Bool {
        guard let query = url.absoluteString
            .split(separator: "?", maxSplits: 1).dropFirst().first else { return false }
        return query.split(separator: "&").contains { $0.hasPrefix("scene=") && $0.count > "scene=".count }
    }

    /// The most a link is asked to carry: payloads above this many
    /// characters travel as a `.liquidinfo` file hand-off instead —
    /// the shared threshold of SCENE-DATA-IN-EPUB.md, kept well inside
    /// what schemes, Mail, and pasteboards move intact.
    static let scenePayloadCeiling = 8_000

    /// Whether a scene fits in a link at all — its compressed payload
    /// within the ceiling.
    static func sceneTravelsInLink(_ sceneJSON: String) -> Bool {
        guard let payload = scenePayload(sceneJSON) else { return false }
        return payload.count <= scenePayloadCeiling
    }

    /// The link with the complete scene aboard: the given `.liquidinfo`
    /// JSON compressed (raw DEFLATE, as Liquid Information writes it)
    /// and base64url-encoded into a `scene` query, appended by string
    /// surgery. A link already carrying a scene, a payload that will
    /// not write, or one over the ceiling returns the URL untouched.
    static func carryingScene(_ url: URL, sceneJSON: String) -> URL {
        guard !carriesScene(url), let payload = scenePayload(sceneJSON),
              payload.count <= scenePayloadCeiling else { return url }
        let text = url.absoluteString
        let joined = text + (text.contains("?") ? "&" : "?") + "scene=" + payload
        return URL(string: joined) ?? url
    }

    /// The scene JSON as the link's payload: raw DEFLATE, base64url,
    /// no padding.
    private static func scenePayload(_ json: String) -> String? {
        let source = Data(json.utf8)
        guard !source.isEmpty else { return nil }
        // DEFLATE can expand incompressible input a little; the margin
        // covers it, so a too-small buffer never reads as failure.
        let capacity = source.count + 1024
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { destination -> Int in
            guard let destBase = destination.bindMemory(to: UInt8.self).baseAddress
            else { return 0 }
            return source.withUnsafeBytes { input -> Int in
                guard let sourceBase = input.bindMemory(to: UInt8.self).baseAddress
                else { return 0 }
                return compression_encode_buffer(destBase, capacity,
                                                 sourceBase, source.count,
                                                 nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        return out.prefix(written).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// A raw DEFLATE stream inflated to its UTF-8 text, the buffer
    /// widened until the stream fits with room to spare. Nil for a
    /// stream that does not read.
    private static func inflated(_ deflate: Data) -> String? {
        var capacity = max(deflate.count * 8, 64_000)
        while capacity <= 16_000_000 {
            var out = Data(count: capacity)
            let written = out.withUnsafeMutableBytes { destination -> Int in
                guard let destBase = destination.bindMemory(to: UInt8.self).baseAddress
                else { return 0 }
                return deflate.withUnsafeBytes { source -> Int in
                    guard let sourceBase = source.bindMemory(to: UInt8.self).baseAddress
                    else { return 0 }
                    return compression_decode_buffer(destBase, capacity,
                                                     sourceBase, deflate.count,
                                                     nil, COMPRESSION_ZLIB)
                }
            }
            guard written > 0 else { return nil }
            // Filling the buffer exactly may mean truncation: widen
            // and read again until the stream fits with room to spare.
            if written < capacity {
                return String(data: out.prefix(written), encoding: .utf8)
            }
            capacity *= 4
        }
        return nil
    }
}

/// Reads the citation Interatlas embeds in its screenshots: the BibTeX
/// entry carried in a PNG iTXt chunk under the keyword `visual-meta`,
/// mirrored in XMP. Walks the PNG's chunk structure directly — ImageIO
/// does not surface arbitrary iTXt keywords — and is tolerant by design:
/// a PNG without the chunk, or with one that does not read, is simply an
/// ordinary image (nil), never an error.
nonisolated enum PNGCitation {

    private static let pngSignature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
    private static let visualMetaKeyword = "visual-meta"
    private static let liquidSceneKeyword = "liquid-scene"
    private static let xmpKeyword = "XML:com.adobe.xmp"

    /// The embedded citation text: the `visual-meta` iTXt (or tEXt) chunk's
    /// value if present, else the XMP packet mirroring it — the caller runs
    /// a BibTeX scan over whichever comes back. Nil for an ordinary PNG,
    /// a non-PNG, or a file too damaged to walk.
    static func citationText(inPNGData data: Data) -> String? {
        text(forKeyword: visualMetaKeyword, inPNGData: data, takingXMPFallback: true)
    }

    /// The complete `.liquidinfo` scene the citable PNG carries — the
    /// `liquid-scene` iTXt chunk (2026-08-19 format), uncompressed
    /// JSON: the image as an equal source of truth to the link. Nil
    /// for an ordinary PNG.
    static func sceneText(inPNGData data: Data) -> String? {
        text(forKeyword: liquidSceneKeyword, inPNGData: data, takingXMPFallback: false)
    }

    /// The chunk walk both readings share.
    private static func text(forKeyword wanted: String, inPNGData data: Data,
                             takingXMPFallback: Bool) -> String? {
        let bytes = [UInt8](data)
        guard bytes.count > pngSignature.count,
              Array(bytes[0..<pngSignature.count]) == pngSignature else { return nil }

        var xmpFallback: String?
        var offset = pngSignature.count
        // Each chunk: 4-byte big-endian length, 4-byte type, payload, CRC.
        while offset + 12 <= bytes.count {
            let length = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16
                       | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            guard length >= 0, offset + 12 + length <= bytes.count else { break }
            let type = String(bytes: bytes[(offset + 4)..<(offset + 8)], encoding: .ascii) ?? ""
            if type == "IEND" { break }
            let body = Array(bytes[(offset + 8)..<(offset + 8 + length)])
            switch type {
            case "iTXt":
                if let (keyword, text) = iTXtEntry(body) {
                    if keyword == wanted { return text }
                    if takingXMPFallback, keyword == xmpKeyword, xmpFallback == nil {
                        xmpFallback = text
                    }
                }
            case "tEXt":
                if let (keyword, text) = tEXtEntry(body), keyword == wanted {
                    return text
                }
            default:
                break
            }
            offset += 12 + length
        }
        return xmpFallback
    }

    /// One iTXt payload: keyword NUL, compression flag and method,
    /// language tag NUL, translated keyword NUL, UTF-8 text. Compressed
    /// entries are skipped — Interatlas writes its citation uncompressed.
    private static func iTXtEntry(_ body: [UInt8]) -> (keyword: String, text: String)? {
        guard let keywordEnd = body.firstIndex(of: 0),
              let keyword = String(bytes: body[0..<keywordEnd], encoding: .isoLatin1)
        else { return nil }
        var index = keywordEnd + 1
        guard index + 2 <= body.count else { return nil }
        let compressed = body[index] != 0
        index += 2
        guard !compressed else { return nil }
        // Skip the language tag, then the translated keyword.
        for _ in 0..<2 {
            while index < body.count, body[index] != 0 { index += 1 }
            guard index < body.count else { return nil }
            index += 1
        }
        guard let text = String(bytes: body[index...], encoding: .utf8) else { return nil }
        return (keyword, text)
    }

    /// One tEXt payload: keyword NUL, Latin-1 text.
    private static func tEXtEntry(_ body: [UInt8]) -> (keyword: String, text: String)? {
        guard let keywordEnd = body.firstIndex(of: 0),
              let keyword = String(bytes: body[0..<keywordEnd], encoding: .isoLatin1),
              let text = String(bytes: body[(keywordEnd + 1)...], encoding: .isoLatin1)
        else { return nil }
        return (keyword, text)
    }
}
