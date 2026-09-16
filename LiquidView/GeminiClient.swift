import Foundation
import Network
import Security
import CryptoKit

// The Gemini protocol, as a fetch-and-read client.
//
// The protocol is deliberately tiny and frozen: TLS over TCP on port 1965,
// one request line, a two-digit status with a ≤1024-byte META, then the body
// until the server closes. Network.framework only — no third-party TLS.
//
// Certificates are trust-on-first-use by convention: capsules serve
// self-signed certificates, so system validation is overridden and the leaf
// certificate's SHA-256 fingerprint is pinned per host:port instead. An
// unknown host is accepted and pinned; a known host must match, and a
// mismatch is a hard stop the reader answers for — the request is never
// sent to a server whose identity hasn't been settled.

// MARK: - Errors

nonisolated enum GeminiError: LocalizedError, Sendable {
    case notAGeminiURL
    case requestTooLong(Int)
    case connectionFailed(String)
    case timedOut
    case certificateUnavailable
    case certificateChanged(GeminiTrust.Mismatch)
    case malformedHeader
    case tooManyRedirects
    case redirectLoop(String)
    case crossSchemeRedirect(String)
    case temporaryFailure(status: Int, meta: String)
    case permanentFailure(status: Int, meta: String)
    case clientCertificateRequired(status: Int, meta: String)
    case bodyTooLarge

    var errorDescription: String? {
        switch self {
        case .notAGeminiURL:
            return "That is not a gemini:// address."
        case .requestTooLong(let bytes):
            return "That address is \(bytes) bytes; Gemini allows 1024."
        case .connectionFailed(let reason):
            return "Could not reach the capsule: \(reason)"
        case .timedOut:
            return "The capsule did not answer in time."
        case .certificateUnavailable:
            return "The capsule served no certificate to remember."
        case .certificateChanged(let mismatch):
            return "\(mismatch.host) is serving a different certificate than the one first seen."
        case .malformedHeader:
            return "The capsule's answer was not a Gemini response."
        case .tooManyRedirects:
            return "The capsule redirected more than five times."
        case .redirectLoop(let url):
            return "The redirects came back to \(url)."
        case .crossSchemeRedirect(let url):
            return "The capsule redirected off Gemini, to \(url)."
        case .temporaryFailure(let status, let meta):
            if status == 44 {
                return "The capsule asks you to slow down: \(meta.isEmpty ? "wait a little" : "wait \(meta) seconds")."
            }
            return meta.isEmpty ? "The capsule reported a temporary failure (\(status))." : meta
        case .permanentFailure(let status, let meta):
            if meta.isEmpty {
                return status == 51 ? "There is no page at that address."
                    : "The capsule reported a permanent failure (\(status))."
            }
            return meta
        case .clientCertificateRequired:
            return "That page wants a client certificate, which Origami Text does not support yet."
        case .bodyTooLarge:
            return "That page is larger than 10 MB."
        }
    }
}

// MARK: - Trust on first use

nonisolated enum GeminiTrust {

    /// One remembered certificate: the fingerprint a host answered with
    /// the first time, and the dates that frame it.
    struct Pin: Codable, Hashable, Sendable {
        let host: String
        let port: Int
        var fingerprint: String
        var firstSeen: Date
        var lastSeen: Date
        var notAfter: Date?

        var key: String { "\(host):\(port)" }
    }

    /// What the reader is asked to answer for: the certificate remembered,
    /// and the one now offered.
    struct Mismatch: Hashable, Sendable {
        let host: String
        let port: Int
        let stored: Pin
        let offered: String
        let offeredNotAfter: Date?
    }

    enum Decision: Sendable {
        /// First sight of this host — accepted and pinned.
        case pinned
        /// Known host, same certificate.
        case matched
        /// Known host, different certificate. Nothing is sent.
        case mismatch(Mismatch)
    }
}

/// The pinned fingerprints, kept as one small JSON file beside the app's
/// other stores.
actor GeminiTrustStore {

    static let shared = GeminiTrustStore()

    private var pins: [String: GeminiTrust.Pin]
    private let fileURL: URL

    init(fileURL: URL = GeminiTrustStore.defaultFileURL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let stored = try? JSONDecoder().decode([String: GeminiTrust.Pin].self, from: data) {
            pins = stored
        } else {
            pins = [:]
        }
    }

    static var defaultFileURL: URL {
        GemtextStore.root.appendingPathComponent("gemini-trust.json")
    }

    var all: [GeminiTrust.Pin] {
        pins.values.sorted { $0.host < $1.host }
    }

    func pin(forHost host: String, port: Int) -> GeminiTrust.Pin? {
        pins["\(host):\(port)"]
    }

    /// The TOFU rule, in one place: unknown hosts are pinned, known hosts
    /// must match, and a mismatch decides nothing on its own — the reader
    /// does, and says so with both fingerprints in front of them.
    func evaluate(host: String, port: Int, fingerprint: String,
                  notAfter: Date?) -> GeminiTrust.Decision {
        let key = "\(host):\(port)"
        guard var existing = pins[key] else {
            pins[key] = GeminiTrust.Pin(host: host, port: port, fingerprint: fingerprint,
                                        firstSeen: .now, lastSeen: .now, notAfter: notAfter)
            persist()
            return .pinned
        }
        guard existing.fingerprint == fingerprint else {
            return .mismatch(GeminiTrust.Mismatch(host: host, port: port, stored: existing,
                                                  offered: fingerprint,
                                                  offeredNotAfter: notAfter))
        }
        existing.lastSeen = .now
        existing.notAfter = notAfter ?? existing.notAfter
        pins[key] = existing
        persist()
        return .matched
    }

    /// The reader chose to trust the new certificate: it replaces the old
    /// one, and first-seen starts again — this is a new identity.
    func trust(host: String, port: Int, fingerprint: String, notAfter: Date?) {
        pins["\(host):\(port)"] = GeminiTrust.Pin(host: host, port: port,
                                                  fingerprint: fingerprint,
                                                  firstSeen: .now, lastSeen: .now,
                                                  notAfter: notAfter)
        persist()
    }

    func forget(host: String, port: Int) {
        pins["\(host):\(port)"] = nil
        persist()
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(pins).write(to: fileURL, options: .atomic)
        } catch {
            // A lost pin costs a re-prompt, never a wrong trust decision:
            // the in-memory store still holds this session's answers.
        }
    }
}

// MARK: - Responses

nonisolated struct GeminiResponse: Sendable {
    /// The URL actually fetched — after redirects, this is the last hop.
    let url: URL
    let status: Int
    let meta: String
    let body: Data
    /// The leaf certificate's SHA-256 fingerprint, as served.
    let fingerprint: String
    /// The connection ended without a clean TLS close: the body may be
    /// short. Recorded, never fatal.
    let truncated: Bool

    /// `20 text/gemini; charset=utf-8` → `text/gemini`. An empty META on a
    /// success means gemtext, per spec.
    var mimeType: String {
        let raw = meta.split(separator: ";").first.map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        } ?? ""
        return raw.isEmpty ? Gemtext.mimeType : raw
    }

    var isGemtext: Bool { mimeType == Gemtext.mimeType }

    var charset: String {
        parameter("charset")?.lowercased() ?? "utf-8"
    }

    /// The `lang` MIME parameter, which maps to the document's language.
    var language: String? { parameter("lang") }

    private func parameter(_ name: String) -> String? {
        for piece in meta.split(separator: ";").dropFirst() {
            let parts = piece.split(separator: "=", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces).lowercased() == name
            else { continue }
            let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// The body as text, honouring the charset the capsule declared — the
    /// one decoder, shared with the source store.
    var text: String? {
        GemtextStore.text(from: body, charset: charset)
    }

    /// `10`/`11`: the page wants a line of input, echoed or not.
    var inputPrompt: (prompt: String, secure: Bool)? {
        guard status == 10 || status == 11 else { return nil }
        return (meta.isEmpty ? "This page asks for input." : meta, status == 11)
    }
}

// MARK: - The client

nonisolated enum GeminiClient {

    static let defaultPort = 1965
    /// The request line, CRLF included, must fit this.
    static let maxRequestBytes = 1024
    /// Read defensively: a header longer than this is not a header.
    static let maxHeaderBytes = 1030
    static let maxBodyBytes = 10 * 1024 * 1024
    static let maxRedirects = 5
    static let connectTimeout = Duration.seconds(10)
    static let totalTimeout = Duration.seconds(30)

    /// Fetches a page, following same-scheme redirects up to five hops with
    /// loop detection. A cross-scheme redirect stops and says where it
    /// wanted to go, so the reader can decide.
    ///
    /// `trustingNewCertificateFor` carries the reader's answer to a
    /// fingerprint mismatch — the host they chose to trust anew.
    static func fetch(_ url: URL,
                      store: GeminiTrustStore = .shared,
                      trustingNewCertificateFor host: String? = nil,
                      followingCrossScheme: Bool = false) async throws -> GeminiResponse {
        var current = url
        var visited: Set<String> = []
        for _ in 0...maxRedirects {
            guard visited.insert(current.absoluteString).inserted else {
                throw GeminiError.redirectLoop(current.absoluteString)
            }
            let target = current
            let response = try await withTimeout(totalTimeout) {
                try await request(target, store: store,
                                  acceptNewCertificate: host != nil && host == target.host)
            }
            switch response.status / 10 {
            case 1:
                return response          // input wanted; the caller prompts
            case 2:
                return response
            case 3:
                guard !response.meta.isEmpty,
                      let next = URL(string: response.meta, relativeTo: current)?.absoluteURL
                else { throw GeminiError.malformedHeader }
                if next.scheme?.lowercased() != "gemini", !followingCrossScheme {
                    throw GeminiError.crossSchemeRedirect(next.absoluteString)
                }
                current = next
            case 4:
                throw GeminiError.temporaryFailure(status: response.status, meta: response.meta)
            case 5:
                throw GeminiError.permanentFailure(status: response.status, meta: response.meta)
            case 6:
                throw GeminiError.clientCertificateRequired(status: response.status,
                                                            meta: response.meta)
            default:
                throw GeminiError.malformedHeader
            }
        }
        throw GeminiError.tooManyRedirects
    }

    /// The same URL asked again with a query — the answer to a 10/11 input
    /// prompt, percent-encoded as the protocol requires.
    static func url(_ url: URL, answering input: String) -> URL? {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        components?.percentEncodedQuery = input.addingPercentEncoding(
            withAllowedCharacters: .geminiQueryAllowed) ?? input
        return components?.url
    }

    // MARK: One request

    private static func request(_ url: URL, store: GeminiTrustStore,
                                acceptNewCertificate: Bool) async throws -> GeminiResponse {
        guard url.scheme?.lowercased() == "gemini",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil      // Gemini URLs carry no userinfo
        else { throw GeminiError.notAGeminiURL }
        let port = url.port ?? defaultPort
        guard let portNumber = NWEndpoint.Port(rawValue: UInt16(truncatingIfNeeded: port)),
              port > 0, port <= 65_535 else { throw GeminiError.notAGeminiURL }

        // One line: the absolute URL, no fragment, CRLF.
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        if components?.port == defaultPort { components?.port = nil }
        let requestLine = (components?.url?.absoluteString ?? url.absoluteString) + "\r\n"
        let requestData = Data(requestLine.utf8)
        guard requestData.count <= maxRequestBytes else {
            throw GeminiError.requestTooLong(requestData.count)
        }

        let observer = GeminiCertificateObserver()
        let parameters = NWParameters(tls: tlsOptions(host: host, observer: observer),
                                      tcp: NWProtocolTCP.Options())
        let channel = GeminiChannel(NWConnection(host: NWEndpoint.Host(host),
                                                 port: portNumber, using: parameters))
        defer { channel.cancel() }
        try await withTimeout(connectTimeout) { try await channel.start() }

        guard let fingerprint = observer.fingerprint else {
            throw GeminiError.certificateUnavailable
        }
        switch await store.evaluate(host: host, port: port, fingerprint: fingerprint,
                                    notAfter: observer.notAfter) {
        case .pinned, .matched:
            break
        case .mismatch(let mismatch):
            guard acceptNewCertificate else { throw GeminiError.certificateChanged(mismatch) }
            await store.trust(host: host, port: port, fingerprint: fingerprint,
                              notAfter: observer.notAfter)
        }

        // Only now: nothing is said to a server whose identity is unsettled.
        try await channel.send(requestData)
        let received = try await channel.receiveAll(cap: maxBodyBytes)

        let (status, meta, bodyStart) = try parseHeader(received.data)
        let body = received.data.count > bodyStart
            ? received.data.subdata(in: bodyStart..<received.data.count)
            : Data()
        return GeminiResponse(url: url, status: status, meta: meta, body: body,
                              fingerprint: fingerprint, truncated: !received.clean)
    }

    /// `<STATUS><SPACE><META><CRLF>` — two digits, META ≤ 1024 bytes.
    private static func parseHeader(_ data: Data) throws -> (status: Int, meta: String, bodyStart: Int) {
        let window = min(data.count, maxHeaderBytes)
        guard window >= 3 else { throw GeminiError.malformedHeader }
        let head = data.subdata(in: 0..<window)
        var terminator = 2
        var lineEnd = head.range(of: Data("\r\n".utf8))?.lowerBound
        if lineEnd == nil {
            // Lenient on the way in: a bare LF still names a header.
            lineEnd = head.range(of: Data("\n".utf8))?.lowerBound
            terminator = 1
        }
        guard let end = lineEnd else { throw GeminiError.malformedHeader }
        guard let line = String(data: head.subdata(in: 0..<end), encoding: .utf8) else {
            throw GeminiError.malformedHeader
        }
        let digits = line.prefix(2)
        guard digits.count == 2, let status = Int(digits), status >= 10, status <= 69 else {
            throw GeminiError.malformedHeader
        }
        var meta = String(line.dropFirst(2))
        if meta.hasPrefix(" ") { meta.removeFirst() }
        meta = meta.trimmingCharacters(in: .whitespaces)
        guard meta.utf8.count <= maxRequestBytes else { throw GeminiError.malformedHeader }
        return (status, meta, end + terminator)
    }

    // MARK: TLS

    /// System validation is replaced, not relaxed: the verify block accepts
    /// the handshake and records the leaf certificate's fingerprint, and the
    /// trust decision is made against the pin store before a single byte of
    /// request is sent.
    private static func tlsOptions(host: String,
                                   observer: GeminiCertificateObserver) -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        let security = options.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(security, .TLSv12)
        // SNI is required by the protocol — a capsule may serve many hosts.
        sec_protocol_options_set_tls_server_name(security, host)
        sec_protocol_options_set_verify_block(security, { _, trust, complete in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            if let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate],
               let leaf = chain.first {
                let der = SecCertificateCopyData(leaf) as Data
                observer.record(fingerprint: hex(SHA256.hash(data: der)),
                                notAfter: expiry(of: leaf))
            }
            complete(true)
        }, DispatchQueue(label: "info.futuretextlab.gemini.tls"))
        return options
    }

    private static func hex(_ digest: SHA256Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// The certificate's notAfter date, for the trust dialog's dates.
    private static func expiry(of certificate: SecCertificate) -> Date? {
        #if os(macOS)
        guard let values = SecCertificateCopyValues(
            certificate, [kSecOIDX509V1ValidityNotAfter] as CFArray, nil) as? [String: Any],
              let entry = values[kSecOIDX509V1ValidityNotAfter as String] as? [String: Any],
              let seconds = entry[kSecPropertyKeyValue as String] as? Double
        else { return nil }
        return Date(timeIntervalSinceReferenceDate: seconds)
        #else
        return nil
        #endif
    }

    // MARK: Deadlines

    private static func withTimeout<T: Sendable>(
        _ duration: Duration,
        _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: duration)
                throw GeminiError.timedOut
            }
            guard let result = try await group.next() else { throw GeminiError.timedOut }
            group.cancelAll()
            return result
        }
    }
}

// MARK: - Connection plumbing

/// What the TLS verify block saw, read once the handshake is done.
nonisolated private final class GeminiCertificateObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var storedFingerprint: String?
    private var storedNotAfter: Date?

    func record(fingerprint: String, notAfter: Date?) {
        lock.lock()
        storedFingerprint = fingerprint
        storedNotAfter = notAfter
        lock.unlock()
    }

    var fingerprint: String? {
        lock.lock(); defer { lock.unlock() }
        return storedFingerprint
    }

    var notAfter: Date? {
        lock.lock(); defer { lock.unlock() }
        return storedNotAfter
    }
}

/// An `NWConnection` as three awaitable steps: connect, send, read to the
/// server's close.
nonisolated private final class GeminiChannel: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "info.futuretextlab.gemini")

    init(_ connection: NWConnection) { self.connection = connection }

    func cancel() { connection.cancel() }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = GeminiOnce(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.resume(returning: ())
                case .failed(let error):
                    once.resume(throwing: GeminiError.connectionFailed(error.localizedDescription))
                case .waiting(let error):
                    // Waiting means the path cannot carry this connection
                    // (no route, name unknown). A reader would rather hear
                    // the reason than watch a spinner to its timeout.
                    once.resume(throwing: GeminiError.connectionFailed(error.localizedDescription))
                case .cancelled:
                    once.resume(throwing: GeminiError.connectionFailed("the connection closed"))
                case .setup, .preparing:
                    break
                @unknown default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = GeminiOnce(continuation)
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    once.resume(throwing: GeminiError.connectionFailed(error.localizedDescription))
                } else {
                    once.resume(returning: ())
                }
            })
        }
    }

    /// Everything the server sends until it closes. A stream that ends
    /// without a clean close is reported as such — the body may be short —
    /// but the bytes already read are kept.
    func receiveAll(cap: Int) async throws -> (data: Data, clean: Bool) {
        var buffer = Data()
        while true {
            let chunk = try await receive()
            if let content = chunk.content, !content.isEmpty { buffer.append(content) }
            guard buffer.count <= cap else { throw GeminiError.bodyTooLarge }
            if let error = chunk.error {
                guard !buffer.isEmpty else {
                    throw GeminiError.connectionFailed(error.localizedDescription)
                }
                return (buffer, false)
            }
            if chunk.isComplete { return (buffer, true) }
        }
    }

    private struct Chunk: Sendable {
        let content: Data?
        let isComplete: Bool
        let error: NWError?
    }

    private func receive() async throws -> Chunk {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Chunk, Error>) in
            let once = GeminiOnce(continuation)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
                content, _, isComplete, error in
                once.resume(returning: Chunk(content: content, isComplete: isComplete, error: error))
            }
        }
    }
}

/// A continuation that can only be resumed once, however many times a
/// connection handler fires.
nonisolated private final class GeminiOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: T) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(throwing: error)
    }
}

extension CharacterSet {
    /// RFC 3986 unreserved plus the sub-delims a Gemini query keeps: the
    /// answer to a 10/11 prompt travels percent-encoded.
    nonisolated fileprivate static let geminiQueryAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}
