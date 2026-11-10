#if os(macOS)
import Foundation
import Network
import Observation

/// The Mac's AI, served to the headset (9 Nov 2026).
///
/// Vision Pro has no model of its own worth asking, so the Mac answers for
/// it — with whatever the Mac itself uses (Settings ▸ AI: a model Origami
/// downloaded and runs here, Apple Intelligence, or a server added there).
/// The headset already speaks the chat-completions dialect every server
/// does, so the Mac answers in it: `POST /v1/chat/completions`, streamed as
/// server-sent events, and `GET /v1/models`.
///
/// Off until Settings ▸ AI ▸ Serve AI to Vision Pro is turned on, so nothing
/// listens (or asks for the local network) unasked. While on, the Mac writes
/// where it answers and a private token into the community folder
/// (`MacAIHost`); the headset reads it there and asks with the token, so no
/// address is typed and no other device on the network is answered.
@MainActor @Observable
final class MacAIServer {
    static let shared = MacAIServer()

    static let enabledKey = "serveAIToVisionPro"
    static let port: UInt16 = 48_151

    private(set) var isListening = false
    private(set) var status = "Off."
    /// Requests answered since it started, for Settings to show.
    private(set) var answered = 0

    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var published: MacAIHost?
    @ObservationIgnored private let queue = DispatchQueue(label: "origami.ai-server")

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
    }

    /// The private token the headset must show — made once, kept.
    private var token: String {
        if let known = UserDefaults.standard.string(forKey: "serveAIToken") { return known }
        let made = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        UserDefaults.standard.set(made, forKey: "serveAIToken")
        return made
    }

    /// Library Upkeep's beat, and Settings' toggle: listening and published
    /// while on, silent and unpublished while off.
    func keepUp(community: URL?) {
        if isEnabled {
            if listener == nil { start() }
            publish(community: community)
        } else {
            if listener != nil { stop() }
            if published != nil, let community {
                MacAIHost.write(nil, to: community)
                published = nil
            }
            status = "Off."
        }
    }

    private func start() {
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: Self.port)!)
            // The one server: reached as such, never as a captured self.
            listener.stateUpdateHandler = { state in
                Task { @MainActor in MacAIServer.shared.listenerChanged(state) }
            }
            listener.newConnectionHandler = { connection in
                Task { @MainActor in MacAIServer.shared.accept(connection) }
            }
            listener.start(queue: queue)
            self.listener = listener
            status = "Starting\u{2026}"
        } catch {
            status = "Could not listen: \(error.localizedDescription)"
        }
    }

    private func stop() {
        listener?.cancel()
        listener = nil
        isListening = false
    }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            isListening = true
            status = "Serving Vision Pro with \(OrigamiLLM.shared.selectedDisplayName)."
        case .failed(let error):
            isListening = false
            status = "Stopped: \(error.localizedDescription)"
            listener = nil
        case .cancelled:
            isListening = false
        default:
            break
        }
    }

    /// Where it answers, written into the community folder — again only
    /// when it would change (the model chosen, the Mac's addresses).
    private func publish(community: URL?) {
        guard let community else { status = "No community folder chosen."; return }
        let name = Host.current().localizedName ?? "Mac"
        let local = ProcessInfo.processInfo.hostName.hasSuffix(".local")
            ? ProcessInfo.processInfo.hostName
            : (Self.localHostName() ?? ProcessInfo.processInfo.hostName) + ".local"
        var host = MacAIHost(
            base: "http://\(local):\(Self.port)",
            alternates: Self.addresses().map { "http://\($0):\(Self.port)" },
            token: token,
            model: OrigamiLLM.shared.selectedDisplayName,
            macName: name,
            modified: .now)
        if let published, published.base == host.base, published.alternates == host.alternates,
           published.token == host.token, published.model == host.model {
            return
        }
        host.modified = .now
        MacAIHost.write(host, to: community)
        published = host
        if isListening { status = "Serving Vision Pro with \(host.model)." }
    }

    /// The Mac's Bonjour name ("MacBook-Pro-8").
    private static func localHostName() -> String? {
        guard let name = SCDynamicStoreCopyLocalHostNameShim() else { return nil }
        return name
    }

    /// The Mac's IPv4 addresses on its networks (Wi-Fi, Ethernet).
    private static func addresses() -> [String] {
        var found: [String] = []
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return [] }
        defer { freeifaddrs(interfaces) }
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            let entry = current.pointee
            pointer = entry.ifa_next
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: entry.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var text = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &text, socklen_t(text.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: text)
                if !ip.hasPrefix("169.254.") { found.append(ip) }
            }
        }
        return found
    }

    // MARK: One request

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        Self.readRequest(connection, buffer: Data()) { request in
            Task { @MainActor in
                guard let request else { connection.cancel(); return }
                await MacAIServer.shared.answer(request, on: connection)
            }
        }
    }

    private struct Request {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    /// Reads until the headers are in and the body is as long as they say.
    private nonisolated static func readRequest(_ connection: NWConnection, buffer: Data,
                                                done: @escaping @Sendable (Request?) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = parse(buffer) {
                done(request)
            } else if error != nil || isComplete || buffer.count > 8 << 20 {
                done(nil)
            } else {
                readRequest(connection, buffer: buffer, done: done)
            }
        }
    }

    private nonisolated static func parse(_ buffer: Data) -> Request? {
        guard let split = buffer.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: buffer[..<split.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let first = lines.first?.split(separator: " ") ?? []
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = buffer[split.upperBound...]
        guard body.count >= length else { return nil }
        return Request(method: String(first[0]), path: String(first[1]), headers: headers,
                       body: Data(body.prefix(length)))
    }

    private func answer(_ request: Request, on connection: NWConnection) async {
        // Only a device that holds the community folder's token is answered.
        guard request.headers["authorization"] == "Bearer \(token)" else {
            Self.send(connection, status: "401 Unauthorized", json: ["error": "unauthorized"])
            return
        }
        switch (request.method, request.path) {
        case ("GET", "/v1/models"):
            Self.send(connection, status: "200 OK",
                      json: ["data": [["id": OrigamiLLM.shared.selectedDisplayName, "object": "model"]]])
        case ("POST", "/v1/chat/completions"):
            await chat(request, on: connection)
        default:
            Self.send(connection, status: "404 Not Found", json: ["error": "not found"])
        }
    }

    /// One chat, asked of the Mac's own choice and streamed back as it comes.
    private func chat(_ request: Request, on connection: NWConnection) async {
        guard let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let messages = object["messages"] as? [[String: Any]] else {
            Self.send(connection, status: "400 Bad Request", json: ["error": "no messages"])
            return
        }
        let system = messages.filter { $0["role"] as? String == "system" }
            .compactMap { $0["content"] as? String }.joined(separator: "\n\n")
        let prompt = messages.filter { $0["role"] as? String != "system" }
            .compactMap { $0["content"] as? String }.joined(separator: "\n\n")
        let header = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8), completion: .contentProcessed { _ in })
        var sent = ""
        func push(_ text: String) {
            guard text.count > sent.count, text.hasPrefix(sent) else { return }
            let piece = String(text.dropFirst(sent.count))
            sent = text
            Self.event(connection, ["choices": [["delta": ["content": piece], "index": 0]]])
        }
        do {
            let (text, _) = try await OrigamiLLM.shared.respond(
                instructions: system.isEmpty ? nil : system, to: prompt,
                transformingContent: true, onPartial: { partial in push(partial) })
            push(text)
            answered += 1
        } catch {
            // The headset shows what went wrong on the Mac.
            Self.event(connection, ["choices": [["delta": ["content": "\u{26A0}\u{FE0E} The Mac could not answer: \(error.localizedDescription)"], "index": 0]]])
        }
        connection.send(content: Data("data: [DONE]\n\n".utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private nonisolated static func event(_ connection: NWConnection, _ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let json = String(data: data, encoding: .utf8) else { return }
        connection.send(content: Data("data: \(json)\n\n".utf8), completion: .contentProcessed { _ in })
    }

    private nonisolated static func send(_ connection: NWConnection, status: String, json: [String: Any]) {
        let body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        let head = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

/// The Mac's Bonjour host name, without SystemConfiguration's Swift overlay.
private func SCDynamicStoreCopyLocalHostNameShim() -> String? {
    var name = [CChar](repeating: 0, count: 256)
    guard gethostname(&name, name.count) == 0 else { return nil }
    let full = String(cString: name)
    return full.components(separatedBy: ".").first
}
#endif
