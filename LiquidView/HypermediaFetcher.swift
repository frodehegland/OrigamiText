import Foundation

// Hypermedia protocol reader.
//
// Reads public documents from any space that speaks the Hypermedia protocol
// (https://hyper.media) over its JSON REST API. Nothing here needs a key or
// an account: a space's documents are public, and reading them is one GET.
//
// Three calls carry the whole integration:
//   OPTIONS https://space/            → who the space is (x-hypermedia-id/-title)
//   GET  https://space/api/Query      → every document the space holds
//   GET  https://space/api/Resource   → one document, blocks and all
// Responses are SuperJSON-wrapped ({"json": …, "meta": …}); the "json"
// member is the payload.

// MARK: - Errors

enum HypermediaError: LocalizedError {
    case invalidAddress
    case notASpace(String)
    case httpError(Int)
    case notFound(address: String, spaces: [String])
    case isComment
    case isDeleted
    case serverError(String)
    case decodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidAddress:
            return "That is not a Hypermedia address."
        case .notASpace(let domain):
            return "\(domain) does not answer as a Hypermedia space."
        case .httpError(let code):
            return "The space returned HTTP \(code)."
        case .notFound(let address, let spaces):
            if spaces.isEmpty { return "No document at \(address)." }
            return "No document at \(address) on \(spaces.joined(separator: ", "))."
        case .isComment:
            return "That address is a comment, which Origami Text cannot open yet."
        case .isDeleted:
            return "That document has been deleted."
        case .serverError(let message):
            return "The space reported an error: \(message)"
        case .decodingFailed(let detail):
            return "Could not read the document: \(detail)"
        }
    }
}

// MARK: - Addresses

/// A parsed Hypermedia address. The wire forms are
///   hm://<uid>/<path>?v=<version>#<block>
///   https://<host>/hm/<uid>/<path>…        (a gateway's canonical URL)
/// The fragment may carry a range (`#id+`, `#id[3:9]`); only the block id
/// matters here, since a paragraph is the unit Origami lands on.
nonisolated struct HypermediaAddress: Hashable, Sendable {
    let uid: String
    let path: [String]
    let version: String?
    let blockRef: String?
    /// The space origin (`https://host`) when the address came as a gateway
    /// URL — the server that surely knows the document.
    let origin: URL?

    /// `hm://uid/path` — identity without version or fragment.
    var canonicalID: String {
        path.isEmpty ? "hm://\(uid)" : "hm://\(uid)/\(path.joined(separator: "/"))"
    }

    /// The id the Resource endpoint takes: canonical, pinned when a
    /// version was asked for.
    var resourceID: String {
        version.map { "\(canonicalID)?v=\($0)" } ?? canonicalID
    }

    /// Reserved first path segments on a gateway that are pages, not
    /// document uids.
    private static let staticGatewayPaths: Set<String> = ["download", "connect", "register", "profile", "contact", "api"]

    static func parse(_ string: String) -> HypermediaAddress? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let schemeRange = trimmed.range(of: "://") else { return nil }
        let scheme = trimmed[..<schemeRange.lowerBound].lowercased()
        var rest = String(trimmed[schemeRange.upperBound...])

        var fragment: String?
        if let hash = rest.firstIndex(of: "#") {
            fragment = String(rest[rest.index(after: hash)...])
            rest = String(rest[..<hash])
        }
        var query: [String: String] = [:]
        if let q = rest.firstIndex(of: "?") {
            let queryString = String(rest[rest.index(after: q)...])
            rest = String(rest[..<q])
            for pair in queryString.split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let key = String(parts[0])
                let value = parts.count > 1 ? String(parts[1]) : ""
                query[key] = value.removingPercentEncoding ?? value
            }
        }
        let segments = rest.split(separator: "/", omittingEmptySubsequences: false).map(String.init)

        let uid: String
        let path: [String]
        var origin: URL?
        switch scheme {
        case "hm":
            guard let first = segments.first, !first.isEmpty else { return nil }
            uid = first
            path = segments.dropFirst().filter { !$0.isEmpty }
        case "https", "http":
            guard segments.count >= 3, segments[1] == "hm" else { return nil }
            let host = segments[0]
            guard !host.isEmpty, !segments[2].isEmpty,
                  !staticGatewayPaths.contains(segments[2].lowercased()) else { return nil }
            uid = segments[2]
            path = segments.dropFirst(3).filter { !$0.isEmpty }
            origin = URL(string: "\(scheme)://\(host)")
        default:
            return nil
        }
        let version = query["v"].flatMap { $0.isEmpty ? nil : $0 }
        return HypermediaAddress(uid: uid, path: path, version: version,
                                 blockRef: blockID(fromFragment: fragment), origin: origin)
    }

    /// `id`, `id+`, `id[3:9]` → `id`.
    static func blockID(fromFragment fragment: String?) -> String? {
        guard var fragment, !fragment.isEmpty else { return nil }
        if let bracket = fragment.firstIndex(of: "[") { fragment = String(fragment[..<bracket]) }
        if fragment.hasSuffix("+") { fragment.removeLast() }
        return fragment.isEmpty ? nil : fragment
    }
}

// MARK: - Spaces and listings

/// A Hypermedia space the reader follows: the domain they typed, and what
/// the space said about itself when asked.
nonisolated struct HypermediaSpace: Codable, Identifiable, Hashable, Sendable {
    let domain: String
    let uid: String
    let title: String

    var id: String { domain }
    var origin: URL { URL(string: "https://\(domain)")! }
}

/// One document in a space's listing — enough to show a row and to fetch
/// the document when it is chosen.
nonisolated struct HypermediaDocumentInfo: Identifiable, Hashable, Sendable {
    /// The canonical `hm://uid/path` address.
    let id: String
    let uid: String
    let path: [String]
    let title: String
    /// The parents' names, space root first.
    let breadcrumbs: [String]
    let authors: [String]
    let updated: Date?
    let version: String

    var address: HypermediaAddress {
        HypermediaAddress(uid: uid, path: path, version: nil, blockRef: nil, origin: nil)
    }
}


/// One comment on a document, with its replies nested — the thread as
/// the space keeps it, names resolved.
nonisolated struct HypermediaComment: Identifiable, Hashable, Sendable {
    let id: String
    /// The comment blob's CID — what a reply points at.
    let version: String
    /// The thread's first comment, by version; nil when this is it.
    let threadRootVersion: String?
    let authorUID: String
    let authorName: String
    let created: Date?
    /// The comment's text, paragraph by paragraph, in Origami's inline
    /// markdown — links live, embeds named.
    let paragraphs: [String]
    var replies: [HypermediaComment]

    /// This comment and every reply beneath it.
    var count: Int { 1 + replies.reduce(0) { $0 + $1.count } }
}

// MARK: - Wire-format models
// Decoding is tolerant throughout: a missing or oddly typed field never
// fails the document, in the spirit of the Origami format's own rule.

nonisolated private struct HMEnvelope<Payload: Decodable>: Decodable {
    let json: Payload?
}

nonisolated private struct HMResourceWrapper: Decodable {
    let type: String?
    let document: HMDocument?
    let redirectTarget: HMWireID?
    let message: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try? c.decode(String.self, forKey: .type)
        document = try? c.decode(HMDocument.self, forKey: .document)
        redirectTarget = try? c.decode(HMWireID.self, forKey: .redirectTarget)
        message = try? c.decode(String.self, forKey: .message)
    }

    private enum CodingKeys: String, CodingKey { case type, document, redirectTarget, message }
}

nonisolated private struct HMWireID: Decodable {
    let uid: String?
    let path: [String]?
}

nonisolated struct HMDocument: Decodable {
    let content: [HMBlockNode]
    let metadata: HMMetadata
    let account: String?
    let authors: [String]
    let path: String?
    let version: String?
    let createTime: String?
    let updateTime: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try? c.decode(String.self, forKey: .version)
        content = (try? c.decode([HMBlockNode].self, forKey: .content)) ?? []
        metadata = (try? c.decode(HMMetadata.self, forKey: .metadata)) ?? HMMetadata()
        account = try? c.decode(String.self, forKey: .account)
        authors = (try? c.decode([String].self, forKey: .authors)) ?? []
        path = try? c.decode(String.self, forKey: .path)
        createTime = try? c.decode(String.self, forKey: .createTime)
        updateTime = try? c.decode(String.self, forKey: .updateTime)
    }

    private enum CodingKeys: String, CodingKey {
        case content, metadata, account, authors, path, version, createTime, updateTime
    }
}

nonisolated struct HMMetadata: Decodable {
    let name: String?
    let summary: String?
    let displayAuthor: String?
    let displayPublishTime: String?

    init() { name = nil; summary = nil; displayAuthor = nil; displayPublishTime = nil }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try? c.decode(String.self, forKey: .name)
        summary = try? c.decode(String.self, forKey: .summary)
        displayAuthor = try? c.decode(String.self, forKey: .displayAuthor)
        displayPublishTime = try? c.decode(String.self, forKey: .displayPublishTime)
    }

    private enum CodingKeys: String, CodingKey {
        case name, summary, displayAuthor, displayPublishTime
    }
}

nonisolated struct HMBlockNode: Decodable {
    let block: HMBlock
    let children: [HMBlockNode]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        block = try c.decode(HMBlock.self, forKey: .block)
        children = (try? c.decode([HMBlockNode].self, forKey: .children)) ?? []
    }

    private enum CodingKeys: String, CodingKey { case block, children }
}

nonisolated struct HMBlock: Decodable {
    let id: String
    let type: String
    let text: String?
    let link: String?
    let attributes: [String: HMJSONValue]?
    let annotations: [HMAnnotation]?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        type = (try? c.decode(String.self, forKey: .type)) ?? "Paragraph"
        text = try? c.decode(String.self, forKey: .text)
        link = try? c.decode(String.self, forKey: .link)
        attributes = try? c.decode([String: HMJSONValue].self, forKey: .attributes)
        annotations = try? c.decode([HMAnnotation].self, forKey: .annotations)
    }

    private enum CodingKeys: String, CodingKey {
        case id, type, text, link, attributes, annotations
    }
}

nonisolated struct HMAnnotation: Decodable {
    let type: String
    let starts: [Int]
    let ends: [Int]
    let link: String?

    init(type: String, starts: [Int], ends: [Int], link: String?) {
        self.type = type; self.starts = starts; self.ends = ends; self.link = link
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = (try? c.decode(String.self, forKey: .type)) ?? ""
        starts = (try? c.decode([Int].self, forKey: .starts)) ?? []
        ends = (try? c.decode([Int].self, forKey: .ends)) ?? []
        link = try? c.decode(String.self, forKey: .link)
    }

    private enum CodingKeys: String, CodingKey { case type, starts, ends, link }
}

/// Minimal JSON value for block attributes (heading level, code language).
nonisolated enum HMJSONValue: Decodable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Int.self) { self = .int(v); return }
        if let v = try? c.decode(Double.self) { self = .double(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        self = .null
    }

    func asString() -> String? { if case .string(let s) = self { return s }; return nil }
    func asInt() -> Int? {
        switch self {
        case .int(let i): return i
        case .string(let s): return Int(s)
        default: return nil
        }
    }
}

// The Query endpoint's listing entries.

nonisolated private struct HMQueryPayload: Decodable {
    let results: [HMDocumentInfoWire]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        results = (try? c.decode([HMDocumentInfoWire].self, forKey: .results)) ?? []
    }

    private enum CodingKeys: String, CodingKey { case results }
}

nonisolated private struct HMDocumentInfoWire: Decodable {
    let id: HMWireID?
    let path: [String]
    let authors: [String]
    let sortTime: String?
    let updateTime: HMTimestamp?
    let createTime: HMTimestamp?
    let version: String?
    let breadcrumbs: [HMBreadcrumb]
    let metadata: HMMetadata
    let isRedirect: Bool

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try? c.decode(HMWireID.self, forKey: .id)
        path = (try? c.decode([String].self, forKey: .path)) ?? []
        authors = (try? c.decode([String].self, forKey: .authors)) ?? []
        sortTime = try? c.decode(String.self, forKey: .sortTime)
        updateTime = try? c.decode(HMTimestamp.self, forKey: .updateTime)
        createTime = try? c.decode(HMTimestamp.self, forKey: .createTime)
        version = try? c.decode(String.self, forKey: .version)
        breadcrumbs = (try? c.decode([HMBreadcrumb].self, forKey: .breadcrumbs)) ?? []
        metadata = (try? c.decode(HMMetadata.self, forKey: .metadata)) ?? HMMetadata()
        // A redirect stub has redirectInfo set; presence is all that matters.
        isRedirect = c.contains(.redirectInfo) && !((try? c.decodeNil(forKey: .redirectInfo)) ?? true)
    }

    private enum CodingKeys: String, CodingKey {
        case id, path, authors, sortTime, updateTime, createTime, version, breadcrumbs, metadata, redirectInfo
    }
}

nonisolated private struct HMBreadcrumb: Decodable {
    let name: String?
    let path: String?
}

/// A protobuf-style timestamp; `seconds` arrives as a string or a number.
nonisolated private struct HMTimestamp: Decodable {
    let seconds: Int64
    let nanos: Int

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let s = try? c.decode(String.self, forKey: .seconds) {
            seconds = Int64(s) ?? 0
        } else {
            seconds = (try? c.decode(Int64.self, forKey: .seconds)) ?? 0
        }
        nanos = (try? c.decode(Int.self, forKey: .nanos)) ?? 0
    }

    var date: Date? {
        guard seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds) + TimeInterval(nanos) / 1_000_000_000)
    }

    private enum CodingKeys: String, CodingKey { case seconds, nanos }
}


// The ListComments endpoint's payload.

nonisolated private struct HMCommentsPayload: Decodable {
    let comments: [HMCommentWire]
    let authors: [String: HMAuthorWire]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        comments = (try? c.decode([HMCommentWire].self, forKey: .comments)) ?? []
        authors = (try? c.decode([String: HMAuthorWire].self, forKey: .authors)) ?? [:]
    }

    private enum CodingKeys: String, CodingKey { case comments, authors }
}

nonisolated private struct HMAuthorWire: Decodable {
    let metadata: HMMetadata?
}

nonisolated private struct HMCommentWire: Decodable {
    let id: String
    let version: String
    let author: String
    let replyParent: String?
    let threadRootVersion: String?
    let content: [HMBlockNode]
    let created: Date?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        version = (try? c.decode(String.self, forKey: .version)) ?? ""
        author = (try? c.decode(String.self, forKey: .author)) ?? ""
        replyParent = (try? c.decode(String.self, forKey: .replyParent)).flatMap { $0.isEmpty ? nil : $0 }
        threadRootVersion = (try? c.decode(String.self, forKey: .threadRootVersion)).flatMap { $0.isEmpty ? nil : $0 }
        content = (try? c.decode([HMBlockNode].self, forKey: .content)) ?? []
        // Comments carry ISO strings here; documents elsewhere carry
        // {seconds, nanos}. Take either.
        if let iso = try? c.decode(String.self, forKey: .createTime) {
            created = LiquidDoc.parseISO8601(iso)
        } else {
            created = (try? c.decode(HMTimestamp.self, forKey: .createTime))?.date
        }
    }

    private enum CodingKeys: String, CodingKey { case id, version, author, replyParent, threadRootVersion, content, createTime }
}

nonisolated private struct HMAccountPayload: Decodable {
    let metadata: HMMetadata?
}

// MARK: - Fetcher

nonisolated enum HypermediaFetcher {

    /// The public gateway: where an `hm://` address is looked up when no
    /// followed space answers for it.
    static let gatewayDomain = "hyper.media"

    struct FetchResult: Sendable {
        let title: String
        let author: String
        let body: [LiquidDoc.Paragraph]
        /// `hm://uid/path` — the document's identity on the network.
        let canonicalID: String
        /// The space the document was read from.
        let origin: URL
        let created: Date
        /// The version read — what a comment on it refers to.
        let version: String
    }

    // MARK: Space identity

    /// Asks a domain who it is. A Hypermedia space answers an OPTIONS request
    /// with `x-hypermedia-id` (its home document, `hm://uid`) and
    /// `x-hypermedia-title`.
    static func resolveSpace(domain rawDomain: String) async throws -> HypermediaSpace {
        let domain = normalizeDomain(rawDomain)
        guard !domain.isEmpty, let url = URL(string: "https://\(domain)/") else {
            throw HypermediaError.invalidAddress
        }
        let headers = try await hypermediaHeaders(for: url)
        guard let id = headers["x-hypermedia-id"],
              let address = HypermediaAddress.parse(id) else {
            throw HypermediaError.notASpace(domain)
        }
        let title = headers["x-hypermedia-title"].flatMap { $0.isEmpty ? nil : $0 } ?? domain
        return HypermediaSpace(domain: domain, uid: address.uid, title: title)
    }

    /// `hyper.media`, `https://hyper.media/`, `HYPER.MEDIA/some/page` all
    /// name the same space.
    static func normalizeDomain(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
        return s
    }

    /// The Hypermedia headers of any page on a space (lower-cased keys,
    /// percent-decoded values). Empty when the page has none.
    private static func hypermediaHeaders(for url: URL) async throws -> [String: String] {
        var request = URLRequest(url: url)
        request.httpMethod = "OPTIONS"
        request.timeoutInterval = 20
        let (_, response) = try await URLSession.shared.data(for: request)
        // A space that is not Hypermedia answers OPTIONS with 405 or a
        // plain page; either way, no headers — the caller says so.
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else { return [:] }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            guard let name = (key as? String)?.lowercased(), name.hasPrefix("x-hypermedia-"),
                  let raw = value as? String else { continue }
            headers[name] = raw.removingPercentEncoding ?? raw
        }
        return headers
    }

    // MARK: Listing

    /// Every document on a space, newest first. Redirect stubs (a path that
    /// now points elsewhere) are left out: they have no content to read.
    static func listDocuments(space: HypermediaSpace) async throws -> [HypermediaDocumentInfo] {
        let includes = "[{\"space\":\"\(space.uid)\",\"path\":\"\",\"mode\":\"AllDescendants\"}]"
        let sort = "[{\"term\":\"updated\",\"reverse\":true}]"
        var comps = URLComponents(url: space.origin, resolvingAgainstBaseURL: false)
        comps?.path = "/api/Query"
        comps?.queryItems = [URLQueryItem(name: "includes", value: includes),
                             URLQueryItem(name: "sort", value: sort)]
        guard let url = comps?.url else { throw HypermediaError.invalidAddress }
        let data = try await get(url)
        let payload: HMQueryPayload
        do {
            guard let decoded = try JSONDecoder().decode(HMEnvelope<HMQueryPayload>.self, from: data).json else {
                throw HypermediaError.decodingFailed("empty listing")
            }
            payload = decoded
        } catch let error as HypermediaError {
            throw error
        } catch {
            throw HypermediaError.decodingFailed(error.localizedDescription)
        }
        return payload.results.compactMap { wire in
            guard !wire.isRedirect else { return nil }
            let uid = wire.id?.uid ?? space.uid
            let path = wire.id?.path ?? wire.path
            let address = HypermediaAddress(uid: uid, path: path, version: nil, blockRef: nil, origin: nil)
            let title = wire.metadata.name.flatMap { $0.isEmpty ? nil : $0 }
                ?? (path.isEmpty ? space.title : humanize(path.last ?? ""))
            let updated = wire.sortTime.flatMap { LiquidDoc.parseISO8601($0) }.flatMap { $0.timeIntervalSince1970 > 0 ? $0 : nil }
                ?? wire.updateTime?.date
                ?? wire.createTime?.date
            return HypermediaDocumentInfo(
                id: address.canonicalID, uid: uid, path: path, title: title,
                breadcrumbs: wire.breadcrumbs.compactMap { $0.name }.filter { !$0.isEmpty },
                authors: wire.authors, updated: updated, version: wire.version ?? "")
        }
    }

    /// `json-rest-api` → `Json rest api`: a readable stand-in for a
    /// document with no name of its own.
    static func humanize(_ segment: String) -> String {
        let words = segment.replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard let first = words.first else { return segment }
        return first.uppercased() + words.dropFirst()
    }


    // MARK: Comments

    /// The comments on a document, threaded: top-level comments newest
    /// first, replies beneath their parent oldest first. Names come with
    /// the payload; an unnamed author shows the start of their id.
    static func listComments(address: HypermediaAddress, origin: URL) async throws -> [HypermediaComment] {
        // The endpoint takes the address as the client library's unpacked
        // form — every key present, absent ones null.
        let pathJSON = address.path.map { "\"\($0.replacingOccurrences(of: "\"", with: "\\\""))\"" }.joined(separator: ",")
        let targetID = "{\"id\":\"\(address.canonicalID)\",\"uid\":\"\(address.uid)\",\"path\":[\(pathJSON)],"
            + "\"version\":null,\"blockRef\":null,\"blockRange\":null,\"hostname\":null,\"scheme\":\"hm\",\"latest\":true}"
        var comps = URLComponents(url: origin, resolvingAgainstBaseURL: false)
        comps?.path = "/api/ListComments"
        comps?.queryItems = [URLQueryItem(name: "targetId", value: targetID)]
        guard let url = comps?.url else { throw HypermediaError.invalidAddress }
        let data = try await get(url)
        let payload: HMCommentsPayload
        do {
            guard let decoded = try JSONDecoder().decode(HMEnvelope<HMCommentsPayload>.self, from: data).json else {
                throw HypermediaError.decodingFailed("empty comments")
            }
            payload = decoded
        } catch let error as HypermediaError {
            throw error
        } catch {
            throw HypermediaError.decodingFailed(error.localizedDescription)
        }

        func name(_ uid: String) -> String {
            if let n = payload.authors[uid]?.metadata?.name?.trimmingCharacters(in: .whitespaces), !n.isEmpty { return n }
            return String(uid.prefix(8))
        }
        var flat: [String: HypermediaComment] = [:]
        var order: [String] = []
        var parentOf: [String: String] = [:]
        for wire in payload.comments {
            let text = paragraphs(from: wire.content, origin: origin).map(\.text)
            flat[wire.id] = HypermediaComment(id: wire.id, version: wire.version,
                                              threadRootVersion: wire.threadRootVersion,
                                              authorUID: wire.author, authorName: name(wire.author),
                                              created: wire.created, paragraphs: text, replies: [])
            order.append(wire.id)
            if let parent = wire.replyParent { parentOf[wire.id] = parent }
        }
        // Children attach to parents deepest-first so a reply's own replies
        // are in place before it moves under its parent.
        func depth(_ id: String) -> Int {
            var d = 0; var cur = id; var seen: Set<String> = []
            while let p = parentOf[cur], flat[p] != nil, seen.insert(cur).inserted { d += 1; cur = p }
            return d
        }
        let byCreated: (HypermediaComment, HypermediaComment) -> Bool = {
            ($0.created ?? .distantPast) < ($1.created ?? .distantPast)
        }
        for id in order.sorted(by: { depth($0) > depth($1) }) {
            guard let parent = parentOf[id], flat[parent] != nil, let child = flat[id] else { continue }
            flat[parent]!.replies.append(child)
            flat[parent]!.replies.sort(by: byCreated)
            flat[id] = nil
        }
        return flat.values.sorted { byCreated($1, $0) }
    }

    // MARK: Fetching a document

    /// Opens anything a person might paste: an `hm://` address, a gateway
    /// URL, or a page on a Hypermedia space. `spaces` are the followed
    /// spaces, asked in order for bare `hm://` addresses before the
    /// public gateway.
    static func fetch(urlString: String, spaces: [HypermediaSpace]) async throws -> FetchResult {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw HypermediaError.invalidAddress }

        if let address = HypermediaAddress.parse(trimmed) {
            if let origin = address.origin {
                return try await fetch(address: address, origin: origin)
            }
            // A space that already lists this uid is the one to ask first.
            var origins = spaces.filter { $0.uid == address.uid }.map(\.origin)
            origins += spaces.filter { $0.uid != address.uid }.map(\.origin)
            if !origins.contains(where: { $0.host == gatewayDomain }) {
                origins.append(URL(string: "https://\(gatewayDomain)")!)
            }
            var lastError: Error = HypermediaError.notFound(address: address.canonicalID,
                                                            spaces: origins.compactMap(\.host))
            for origin in origins {
                do {
                    return try await fetch(address: address, origin: origin)
                } catch HypermediaError.notFound {
                    continue
                } catch {
                    lastError = error
                }
            }
            if case HypermediaError.notFound = lastError { throw lastError }
            throw HypermediaError.notFound(address: address.canonicalID, spaces: origins.compactMap(\.host))
        }

        // A page on a space: the space says which document it is.
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", let host = url.host else {
            throw HypermediaError.invalidAddress
        }
        let headers = try await hypermediaHeaders(for: url)
        guard let id = headers["x-hypermedia-id"], var address = HypermediaAddress.parse(id) else {
            throw HypermediaError.notASpace(host)
        }
        // The page URL's own version and fragment still apply.
        if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            let version = comps.queryItems?.first(where: { $0.name == "v" })?.value
            address = HypermediaAddress(uid: address.uid, path: address.path,
                                        version: version ?? address.version,
                                        blockRef: HypermediaAddress.blockID(fromFragment: comps.fragment),
                                        origin: URL(string: "\(scheme)://\(host)"))
        }
        return try await fetch(address: address, origin: address.origin ?? URL(string: "https://\(host)")!)
    }

    /// One document from one space.
    static func fetch(address: HypermediaAddress, origin: URL) async throws -> FetchResult {
        var comps = URLComponents(url: origin, resolvingAgainstBaseURL: false)
        comps?.path = "/api/Resource"
        comps?.queryItems = [URLQueryItem(name: "id", value: address.resourceID)]
        guard let url = comps?.url else { throw HypermediaError.invalidAddress }
        let data = try await get(url)

        let wrapper: HMResourceWrapper
        do {
            guard let decoded = try JSONDecoder().decode(HMEnvelope<HMResourceWrapper>.self, from: data).json else {
                throw HypermediaError.decodingFailed("empty response")
            }
            wrapper = decoded
        } catch let error as HypermediaError {
            throw error
        } catch {
            throw HypermediaError.decodingFailed(error.localizedDescription)
        }

        let siteName = origin.host ?? origin.absoluteString
        switch wrapper.type ?? "" {
        case "document":
            guard let document = wrapper.document else {
                throw HypermediaError.decodingFailed("document missing")
            }
            let author = await authorName(for: document, origin: origin)
            return convert(document: document, address: address, origin: origin, author: author)
        case "redirect":
            // Follow once: a path that moved. A redirect to a redirect is
            // left alone rather than chased.
            guard let target = wrapper.redirectTarget, let uid = target.uid, !uid.isEmpty else {
                throw HypermediaError.notFound(address: address.canonicalID, spaces: [siteName])
            }
            let next = HypermediaAddress(uid: uid, path: target.path ?? [], version: nil,
                                         blockRef: address.blockRef, origin: origin)
            return try await fetchWithoutRedirect(address: next, origin: origin)
        case "not-found":
            throw HypermediaError.notFound(address: address.canonicalID, spaces: [siteName])
        case "comment":
            throw HypermediaError.isComment
        case "tombstone":
            throw HypermediaError.isDeleted
        case "error":
            throw HypermediaError.serverError(wrapper.message ?? "unknown error")
        default:
            throw HypermediaError.decodingFailed("unexpected resource type “\(wrapper.type ?? "")”")
        }
    }

    private static func fetchWithoutRedirect(address: HypermediaAddress, origin: URL) async throws -> FetchResult {
        var comps = URLComponents(url: origin, resolvingAgainstBaseURL: false)
        comps?.path = "/api/Resource"
        comps?.queryItems = [URLQueryItem(name: "id", value: address.resourceID)]
        guard let url = comps?.url else { throw HypermediaError.invalidAddress }
        let data = try await get(url)
        guard let wrapper = try? JSONDecoder().decode(HMEnvelope<HMResourceWrapper>.self, from: data).json,
              wrapper.type == "document", let document = wrapper.document else {
            throw HypermediaError.notFound(address: address.canonicalID, spaces: [origin.host ?? ""])
        }
        let author = await authorName(for: document, origin: origin)
        return convert(document: document, address: address, origin: origin, author: author)
    }

    private static func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw HypermediaError.httpError(http.statusCode)
        }
        return data
    }

    // MARK: Author names

    /// A document names its authors by account uid; the account's own
    /// metadata carries the name people know. Looked up once per space.
    private static let nameCache = HypermediaNameCache()

    private static func authorName(for document: HMDocument, origin: URL) async -> String {
        if let byline = document.metadata.displayAuthor?.trimmingCharacters(in: .whitespaces), !byline.isEmpty {
            return byline
        }
        var uids = document.authors.filter { !$0.isEmpty }
        if uids.isEmpty, let account = document.account, !account.isEmpty { uids = [account] }
        guard !uids.isEmpty else { return "Unknown" }
        // Every author, as the space names them — "A, B and C".
        var names: [String] = []
        for uid in uids.prefix(4) {
            names.append(await accountName(uid: uid, origin: origin) ?? String(uid.prefix(8)))
        }
        if uids.count > 4 { names.append("others") }
        return joinNames(names)
    }

    static func joinNames(_ names: [String]) -> String {
        switch names.count {
        case 0: return "Unknown"
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }

    static func accountName(uid: String, origin: URL) async -> String? {
        let key = "\(origin.absoluteString)|\(uid)"
        if let cached = await nameCache.name(for: key) { return cached }
        var comps = URLComponents(url: origin, resolvingAgainstBaseURL: false)
        comps?.path = "/api/Account"
        comps?.queryItems = [URLQueryItem(name: "id", value: uid)]
        guard let url = comps?.url, let data = try? await get(url),
              let payload = try? JSONDecoder().decode(HMEnvelope<HMAccountPayload>.self, from: data).json,
              let name = payload.metadata?.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            return nil
        }
        await nameCache.remember(name, for: key)
        return name
    }

    // MARK: Block → Origami conversion

    static func convert(document: HMDocument, address: HypermediaAddress,
                        origin: URL, author: String) -> FetchResult {
        let title = document.metadata.name.flatMap { $0.isEmpty ? nil : $0 }
            ?? (address.path.last.map(humanize) ?? "Untitled Document")
        let created = document.createTime.flatMap { LiquidDoc.parseISO8601($0) } ?? .now

        let paragraphs = paragraphs(from: document.content, origin: origin)

        return FetchResult(title: title, author: author, body: paragraphs,
                           canonicalID: address.canonicalID, origin: origin, created: created,
                           version: document.version ?? "")
    }

    /// Blocks → paragraphs: the walk shared by documents and comments.
    static func paragraphs(from content: [HMBlockNode], origin: URL) -> [LiquidDoc.Paragraph] {
    var paragraphs: [LiquidDoc.Paragraph] = []
    var counter = 0

    // The block ID becomes the paragraph ID, so a block reference and
    // an Origami paragraph address are the same string — hm://uid/path#block
    // and origamiDocID#block map onto each other mechanically, in both
    // directions. The counter stands in only for a block that arrived
    // without an ID.
    func add(heading: Int?, text: String, blockID: String? = nil) {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        counter += 1
        let id = blockID.flatMap { $0.isEmpty ? nil : $0 } ?? "p\(counter)"
        paragraphs.append(LiquidDoc.Paragraph(id: id, heading: heading, text: text))
    }

    func process(_ node: HMBlockNode) {
        let b = node.block
        let text = renderText(b, origin: origin)

        switch b.type {
        case "Heading":
            let raw: Int
            switch b.attributes?["level"] {
            case .some(.int(let i)): raw = i
            case .some(.string(let s)): raw = Int(s) ?? 1
            default: raw = 1
            }
            add(heading: min(max(raw, 1), 3), text: text, blockID: b.id)

        case "Paragraph":
            add(heading: nil, text: text, blockID: b.id)

        case "Code":
            let raw = b.text ?? ""
            let lang = b.attributes?["language"]?.asString() ?? ""
            if !raw.isEmpty { add(heading: nil, text: "```\(lang)\n\(raw)\n```", blockID: b.id) }

        case "Math":
            let raw = b.text ?? ""
            if !raw.isEmpty { add(heading: nil, text: "$$\n\(raw)\n$$", blockID: b.id) }

        case "Image", "Video", "File":
            if let link = b.link, !link.isEmpty {
                let href = fileURL(for: link, origin: origin)
                let caption = text.isEmpty ? (b.attributes?["name"]?.asString() ?? b.type) : text
                add(heading: nil, text: "[\(caption)](\(href))", blockID: b.id)
            }

        case "Embed":
            // Another document, shown in place on the space. Here it is
            // a live link that opens through the same path.
            if let link = b.link, !link.isEmpty {
                let label = text.isEmpty ? "Embedded document" : text
                add(heading: nil, text: "[\(label)](\(link))", blockID: b.id)
            }

        default:
            // Button, WebEmbed, Query, Table, Nostr, …
            if !text.isEmpty {
                add(heading: nil, text: text, blockID: b.id)
            } else if let link = b.link, !link.isEmpty {
                add(heading: nil, text: "[\(b.type): \(link)]", blockID: b.id)
            }
        }

        for child in node.children { process(child) }
    }

        for node in content { process(node) }
        return paragraphs
    }

    /// `ipfs://cid` → the space's file endpoint; anything else passes through.
    static func fileURL(for link: String, origin: URL) -> String {
        guard link.hasPrefix("ipfs://") else { return link }
        let cid = link.dropFirst("ipfs://".count)
        return origin.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/hm/api/file/" + cid
    }

    // MARK: Inline annotation rendering

    /// Applies Bold, Italic, Strike, Code, and Link annotations as markdown.
    /// Offsets count Unicode code points (the protocol's convention), so
    /// the text is walked as scalars — an emoji is one, not two.
    static func renderText(_ block: HMBlock, origin: URL) -> String {
        guard let text = block.text, !text.isEmpty else { return "" }
        guard let annotations = block.annotations, !annotations.isEmpty else { return text }
        return renderText(text, annotations: annotations, origin: origin)
    }

    static func renderText(_ text: String, annotations: [HMAnnotation], origin: URL) -> String {
        struct Span { let start: Int; let end: Int; let type: String; let link: String? }
        var spans: [Span] = []
        for ann in annotations {
            for (s, e) in zip(ann.starts, ann.ends) where s >= 0 && s < e {
                spans.append(Span(start: s, end: e, type: ann.type, link: ann.link))
            }
        }
        guard !spans.isEmpty else { return text }

        let scalars = Array(text.unicodeScalars)
        func slice(_ from: Int, _ to: Int) -> String {
            var s = String.UnicodeScalarView()
            s.append(contentsOf: scalars[from..<to])
            return String(s)
        }

        var result = ""
        var pos = 0
        for span in spans.sorted(by: { $0.start < $1.start }) {
            let s = span.start
            let e = min(span.end, scalars.count)
            guard s >= pos, s < e else { continue }
            if s > pos { result += slice(pos, s) }
            let piece = slice(s, e)
            switch span.type {
            case "Bold": result += "**\(piece)**"
            case "Italic": result += "_\(piece)_"
            case "Strike": result += "~~\(piece)~~"
            case "Code": result += "`\(piece)`"
            case "Link", "Embed":
                if let href = span.link, !href.isEmpty {
                    // An inline embed marks its place with U+FFFC and no
                    // words; the link needs some.
                    let label = piece.replacingOccurrences(of: "\u{FFFC}", with: "")
                        .trimmingCharacters(in: .whitespaces)
                    result += "[\(label.isEmpty ? "embedded document" : label)](\(fileURL(for: href, origin: origin)))"
                } else { result += piece.replacingOccurrences(of: "\u{FFFC}", with: "") }
            default: result += piece   // Underline, Highlight, Range…
            }
            pos = e
        }
        if pos < scalars.count { result += slice(pos, scalars.count) }
        return result.isEmpty ? text : result
    }
}

/// Account names already looked up this session.
private actor HypermediaNameCache {
    private var names: [String: String] = [:]
    func name(for key: String) -> String? { names[key] }
    func remember(_ name: String, for key: String) { names[key] = name }
}
