import Foundation

// Seed Hypermedia document fetcher.
//
// Converts any Seed URL form into an Origami document:
//   hm://uid/path            — needs a signed-in server from HypermediaSession
//   https://host/hm/uid/path — explicit canonical form
//   https://host/path        — discovers the uid from the page HTML

// MARK: - Errors

enum SeedFetchError: LocalizedError {
    case invalidURL
    case noServerForHmURL
    case httpError(Int)
    case notADocument
    case uidNotFoundInPage
    case decodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The URL could not be parsed as a Seed address."
        case .noServerForHmURL:
            return "A server URL is required to open hm:// links. Sign in to a Seed server in Settings → Hypermedia."
        case .httpError(let code):
            return "The server returned HTTP \(code)."
        case .notADocument:
            return "The URL does not point to a Seed document."
        case .uidNotFoundInPage:
            return "Could not find a Seed document identifier on the page. Try pasting the canonical https://host/hm/uid/path URL instead."
        case .decodingFailed(let detail):
            return "Could not read the document: \(detail)"
        }
    }
}

// MARK: - Wire-format models
// The Seed HTTP API at /api/Resource returns SuperJSON:
//   {"json": {"type": "document", "document": {...}}, "meta": {...}}
// The client.ts library wraps ALL query responses this way.

private struct SeedSuperJSON: Decodable {
    let json: SeedResourceWrapper?
}

private struct SeedResourceWrapper: Decodable {
    let type: String?
    let document: SeedDocument?
}

struct SeedDocument: Decodable {
    let content: [SeedBlockNode]
    let metadata: SeedMetadata
    let account: String?
    let path: String?
    let createTime: String?
    let updateTime: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        content  = (try? c.decode([SeedBlockNode].self, forKey: .content)) ?? []
        metadata = (try? c.decode(SeedMetadata.self,    forKey: .metadata)) ?? SeedMetadata()
        account  = try? c.decode(String.self, forKey: .account)
        path     = try? c.decode(String.self, forKey: .path)
        createTime  = try? c.decode(String.self, forKey: .createTime)
        updateTime  = try? c.decode(String.self, forKey: .updateTime)
    }

    private enum CodingKeys: String, CodingKey {
        case content, metadata, account, path, createTime, updateTime
    }
}

struct SeedMetadata: Decodable {
    let name: String?
    let summary: String?
    let displayAuthor: String?
    let displayPublishTime: String?

    init() { name = nil; summary = nil; displayAuthor = nil; displayPublishTime = nil }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name                = try? c.decode(String.self, forKey: .name)
        summary             = try? c.decode(String.self, forKey: .summary)
        displayAuthor       = try? c.decode(String.self, forKey: .displayAuthor)
        displayPublishTime  = try? c.decode(String.self, forKey: .displayPublishTime)
    }

    private enum CodingKeys: String, CodingKey {
        case name, summary, displayAuthor, displayPublishTime
    }
}

struct SeedBlockNode: Decodable {
    let block: SeedBlock
    let children: [SeedBlockNode]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        block    = try  c.decode(SeedBlock.self,     forKey: .block)
        children = (try? c.decode([SeedBlockNode].self, forKey: .children)) ?? []
    }

    private enum CodingKeys: String, CodingKey { case block, children }
}

struct SeedBlock: Decodable {
    let id: String
    let type: String
    let text: String?
    let link: String?
    let attributes: [String: SeedJSONValue]?
    let annotations: [SeedAnnotation]?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id          = (try? c.decode(String.self, forKey: .id))   ?? UUID().uuidString
        type        = (try? c.decode(String.self, forKey: .type)) ?? "Paragraph"
        text        = try? c.decode(String.self, forKey: .text)
        link        = try? c.decode(String.self, forKey: .link)
        attributes  = try? c.decode([String: SeedJSONValue].self, forKey: .attributes)
        annotations = try? c.decode([SeedAnnotation].self, forKey: .annotations)
    }

    private enum CodingKeys: String, CodingKey {
        case id, type, text, link, attributes, annotations
    }
}

struct SeedAnnotation: Decodable {
    let type: String
    let starts: [Int]
    let ends: [Int]
    let link: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type   = (try? c.decode(String.self, forKey: .type))  ?? ""
        starts = (try? c.decode([Int].self,  forKey: .starts)) ?? []
        ends   = (try? c.decode([Int].self,  forKey: .ends))   ?? []
        link   = try? c.decode(String.self,  forKey: .link)
    }

    private enum CodingKeys: String, CodingKey { case type, starts, ends, link }
}

/// Minimal JSON value used for Seed block attributes (e.g. heading level).
enum SeedJSONValue: Decodable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil()                        { self = .null;   return }
        if let v = try? c.decode(Bool.self)     { self = .bool(v); return }
        if let v = try? c.decode(Int.self)      { self = .int(v);  return }
        if let v = try? c.decode(Double.self)   { self = .double(v); return }
        if let v = try? c.decode(String.self)   { self = .string(v); return }
        self = .null
    }

    func asString() -> String? { if case .string(let s) = self { return s }; return nil }
    func asInt() -> Int? {
        switch self {
        case .int(let i):    return i
        case .string(let s): return Int(s)
        default:             return nil
        }
    }
}

// MARK: - Fetcher

nonisolated enum SeedFetcher {

    struct FetchResult {
        let title: String
        let author: String
        let body: [LiquidDoc.Paragraph]
        let sourceURL: String
        let created: Date
    }

    // MARK: Main entry point

    static func fetch(urlString: String) async throws -> FetchResult {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SeedFetchError.invalidURL }
        let (baseURL, hmID) = try await resolveAPIEndpoint(from: trimmed)
        let document = try await fetchDocument(baseURL: baseURL, hmID: hmID)
        return convert(document: document, sourceURL: trimmed)
    }

    // MARK: URL resolution

    private static func resolveAPIEndpoint(
        from urlString: String
    ) async throws -> (baseURL: URL, hmID: String) {

        // ── Case 1: hm://uid/path ─────────────────────────────────────────────
        if urlString.hasPrefix("hm://") {
            let rest = String(urlString.dropFirst(5))
            let parts = rest.split(separator: "/", maxSplits: 1,
                                   omittingEmptySubsequences: false)
            guard let uid = parts.first.map(String.init), !uid.isEmpty else {
                throw SeedFetchError.invalidURL
            }
            let docPath = parts.count > 1 ? "/\(parts[1])" : "/"
            let serverURLString = UserDefaults.standard.string(forKey: "hypermedia.seed.serverURL") ?? ""
            guard !serverURLString.isEmpty,
                  let baseURL = URL(string: serverURLString) else {
                throw SeedFetchError.noServerForHmURL
            }
            return (baseURL, "hm://\(uid)\(docPath)")
        }

        guard let url = URL(string: urlString), let host = url.host else {
            throw SeedFetchError.invalidURL
        }
        let scheme = url.scheme ?? "https"
        guard let baseURL = URL(string: "\(scheme)://\(host)") else {
            throw SeedFetchError.invalidURL
        }

        // ── Case 2: https://host/hm/uid/path ─────────────────────────────────
        let parts = url.pathComponents.filter { $0 != "/" }
        if parts.count >= 2, parts[0] == "hm" {
            let uid     = parts[1]
            let docPath = parts.count > 2
                ? "/" + parts[2...].joined(separator: "/") : "/"
            return (baseURL, "hm://\(uid)\(docPath)")
        }

        // ── Case 3: https://host/path — discover uid from page HTML ───────────
        return try await (baseURL, discoverHmID(from: url, baseURL: baseURL))
    }

    /// Fetches the page HTML and scans for an `hm://uid` pattern.
    private static func discoverHmID(from pageURL: URL, baseURL: URL) async throws -> String {
        let (data, _) = try await URLSession.shared.data(from: pageURL)
        let html = String(data: data, encoding: .utf8) ?? ""
        // UIDs are at least 20 chars (in practice 44+ for z6Mk… Ed25519 keys)
        let pattern = #"hm://([A-Za-z0-9]{20,})"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let uidRange = Range(match.range(at: 1), in: html) else {
            throw SeedFetchError.uidNotFoundInPage
        }
        let uid     = String(html[uidRange])
        let docPath = (pageURL.path.isEmpty || pageURL.path == "/") ? "/" : pageURL.path
        return "hm://\(uid)\(docPath)"
    }

    // MARK: HTTP fetch

    private static func fetchDocument(baseURL: URL, hmID: String) async throws -> SeedDocument {
        var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        comps?.path = "/api/Resource"
        comps?.queryItems = [URLQueryItem(name: "id", value: hmID)]
        guard let url = comps?.url else { throw SeedFetchError.invalidURL }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            throw SeedFetchError.httpError(http.statusCode)
        }

        // Try SuperJSON wrapper first; then bare wrapper
        if let wrapped = try? JSONDecoder().decode(SeedSuperJSON.self, from: data),
           let doc = wrapped.json?.document {
            return doc
        }
        if let direct = try? JSONDecoder().decode(SeedResourceWrapper.self, from: data),
           let doc = direct.document {
            return doc
        }
        // Surface a decode error to help debugging
        do {
            _ = try JSONDecoder().decode(SeedSuperJSON.self, from: data)
        } catch {
            throw SeedFetchError.decodingFailed(error.localizedDescription)
        }
        throw SeedFetchError.notADocument
    }

    // MARK: Block → Origami conversion

    static func convert(document: SeedDocument, sourceURL: String) -> FetchResult {
        let title   = document.metadata.name ?? "Seed Document"
        let author  = document.metadata.displayAuthor ?? "Unknown"
        let created = document.createTime.flatMap { LiquidDoc.parseISO8601($0) } ?? .now

        var paragraphs: [LiquidDoc.Paragraph] = []
        var counter = 0

        func add(heading: Int?, text: String) {
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            counter += 1
            paragraphs.append(LiquidDoc.Paragraph(id: "p\(counter)", heading: heading, text: text))
        }

        func process(_ node: SeedBlockNode) {
            let b = node.block
            let text = renderText(b)

            switch b.type {
            case "Heading":
                let raw: Int
                switch b.attributes?["level"] {
                case .some(.int(let i)):    raw = i
                case .some(.string(let s)): raw = Int(s) ?? 1
                default:                   raw = 1
                }
                let level = min(max(raw, 1), 3)
                add(heading: level, text: text)

            case "Paragraph":
                add(heading: nil, text: text)

            case "Code":
                let raw  = b.text ?? ""
                let lang: String
                switch b.attributes?["language"] {
                case .some(.string(let s)): lang = s
                default:                   lang = ""
                }
                if !raw.isEmpty { add(heading: nil, text: "```\(lang)\n\(raw)\n```") }

            case "Math":
                let raw = b.text ?? ""
                if !raw.isEmpty { add(heading: nil, text: "$$\n\(raw)\n$$") }

            case "Image":
                if let link = b.link, !link.isEmpty {
                    let caption = text.isEmpty ? link : text
                    add(heading: nil, text: "[\(caption)](\(link))")
                }

            default:
                // Embed, Button, WebEmbed, Query, Table, Nostr, …
                if !text.isEmpty {
                    add(heading: nil, text: text)
                } else if let link = b.link, !link.isEmpty {
                    add(heading: nil, text: "[\(b.type): \(link)]")
                }
            }

            for child in node.children { process(child) }
        }

        for node in document.content { process(node) }

        return FetchResult(title: title, author: author, body: paragraphs,
                           sourceURL: sourceURL, created: created)
    }

    // MARK: Inline annotation rendering

    /// Applies Bold, Italic, Strike, Code, and Link annotations.
    /// Annotation positions are UTF-16 character offsets (JavaScript convention).
    private static func renderText(_ block: SeedBlock) -> String {
        guard let text = block.text, !text.isEmpty else { return "" }
        guard let annotations = block.annotations, !annotations.isEmpty else { return text }

        struct Span { let start: Int; let end: Int; let type: String; let link: String? }
        var spans: [Span] = []
        for ann in annotations {
            for (s, e) in zip(ann.starts, ann.ends) where s >= 0 && s < e {
                spans.append(Span(start: s, end: e, type: ann.type, link: ann.link))
            }
        }
        guard !spans.isEmpty else { return text }

        let sorted = spans.sorted { $0.start < $1.start }
        let ns     = text as NSString
        var result = ""
        var pos    = 0

        for span in sorted {
            let s = span.start; let e = min(span.end, ns.length)
            guard s >= pos, s < e else { continue }
            if s > pos {
                result += ns.substring(with: NSRange(location: pos, length: s - pos))
            }
            let piece = ns.substring(with: NSRange(location: s, length: e - s))
            switch span.type {
            case "Bold":   result += "**\(piece)**"
            case "Italic": result += "_\(piece)_"
            case "Strike": result += "~~\(piece)~~"
            case "Code":   result += "`\(piece)`"
            case "Link":
                if let href = span.link, !href.isEmpty {
                    result += "[\(piece)](\(href))"
                } else { result += piece }
            default: result += piece
            }
            pos = e
        }
        if pos < ns.length { result += ns.substring(from: pos) }
        return result.isEmpty ? text : result
    }
}


