// Local-LLM support (spec: local-llm-support-spec.md), endpoints-first:
// Apple's on-device model is the zero-setup default, and any
// OpenAI-compatible chat-completions endpoint the user points the app
// at (Ollama, LM Studio, MLX-LM server, remote) sits beside it in one
// picker. Feature code asks OrigamiLLM to respond and never touches a
// concrete provider; a missing model falls back to Apple's with a
// notice, never a failure. In-app MLX model downloads arrive when the
// mlx-swift-examples package joins the project.
//
// Shared with Vision Pro (5 Oct 2026): the headset routes its AI through
// the same store, so a reader's Ollama server on the Mac (added by its
// .local address in the headset's Settings ▸ AI) answers there too. The
// Mac's hardware-based model recommendations stay Mac-only.
#if os(macOS) || os(visionOS)
import Foundation
import NaturalLanguage
import Security
import SwiftUI
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Errors (spec §2, §9 — the canonical copy)

nonisolated enum OrigamiLLMError: LocalizedError {
    case serverUnreachable(String)
    case authRequired(String)
    case appleUnavailable
    case generationFailed(String)

    var errorDescription: String? {
        switch self {
        case .serverUnreachable(let host):
            "Can\u{2019}t reach \(host). Is the server running?"
        case .authRequired(let host):
            "\(host) needs an API key. Add one in Settings."
        case .appleUnavailable:
            "The on-device model isn\u{2019}t available on \(OrigamiLLM.thisDevice)."
        case .generationFailed(let why):
            why
        }
    }
}

// MARK: - An endpoint (spec §6)

/// One server the user added: its base URL and the models found on it.
/// The API key, when one is needed, lives in the Keychain — never here.
nonisolated struct OrigamiEndpoint: Codable, Identifiable, Hashable {
    /// Normalised: scheme://host[:port], no trailing slash, no /v1.
    var base: String
    var models: [String] = []
    /// Byte size keyed by model id — populated from Ollama's /api/tags;
    /// empty for servers that don't expose it (LM Studio, hosted APIs).
    var modelSizes: [String: Int64] = [:]
    var hasKey = false

    var id: String { base }

    var hostLabel: String { URL(string: base)?.host() ?? base }

    /// Loopback and .local hosts — content stays on the local network.
    var isLocal: Bool {
        let host = URL(string: base)?.host() ?? ""
        return host == "localhost" || host == "127.0.0.1"
            || host == "::1" || host.hasSuffix(".local")
    }
}

// MARK: - The store: selection, endpoints, fallback (spec §2)

@MainActor @Observable
final class OrigamiLLM {
    static let shared = OrigamiLLM()

    /// The device the built-in model runs on, for the settings' words.
    nonisolated static var thisDevice: String {
        #if os(visionOS)
        "this headset"
        #else
        "this Mac"
        #endif
    }

    /// The active model: "apple", or "endpoint|<base>|<model>".
    /// Persisted; the picker binds to it directly.
    var selectedID: String {
        didSet { UserDefaults.standard.set(selectedID, forKey: "selectedModelID") }
    }

    private(set) var endpoints: [OrigamiEndpoint] {
        didSet { persistEndpoints() }
    }

    /// The last automatic fallback, for a non-blocking notice — read
    /// and cleared by whoever shows it.
    var fallbackNotice: String?

    private init() {
        selectedID = UserDefaults.standard.string(forKey: "selectedModelID") ?? "apple"
        endpoints = Self.loadEndpoints()
    }

    static func endpointID(base: String, model: String) -> String {
        "endpoint|\(base)|\(model)"
    }

    /// The selection resolved to an endpoint model — nil means Apple's.
    func selectedEndpointModel() -> (endpoint: OrigamiEndpoint, model: String)? {
        let parts = selectedID.split(separator: "|", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[0] == "endpoint",
              let endpoint = endpoints.first(where: { $0.base == parts[1] })
        else { return nil }
        return (endpoint, parts[2])
    }

    var selectedDisplayName: String {
        selectedEndpointModel().map { "\($0.endpoint.hostLabel) \u{00B7} \($0.model)" }
            ?? "Apple\u{2019}s built-in model"
    }

    // MARK: Endpoints

    func addOrUpdateEndpoint(base: String, models: [String],
                              sizes: [String: Int64] = [:], key: String?) {
        let base = ChatCompletionsClient.normalizedBase(base)
        var entry = endpoints.first { $0.base == base }
            ?? OrigamiEndpoint(base: base)
        entry.models = models
        if !sizes.isEmpty { entry.modelSizes = sizes }
        if let key {
            LLMKeychain.write(key.isEmpty ? nil : key, account: base)
            entry.hasKey = !key.isEmpty
        }
        endpoints.removeAll { $0.base == base }
        endpoints.append(entry)
        endpoints.sort { $0.base < $1.base }
    }

    /// Removing an endpoint clears its key; a selection pointing at it
    /// reverts to Apple's model.
    func removeEndpoint(_ base: String) {
        endpoints.removeAll { $0.base == base }
        LLMKeychain.write(nil, account: base)
        if selectedEndpointModel() == nil, selectedID != "apple" {
            selectedID = "apple"
        }
    }

    func apiKey(for base: String) -> String? {
        LLMKeychain.read(account: base)
    }

    /// Refreshes one endpoint's model list (settings-open, and after a
    /// generation-time "model not found").
    func refreshModels(for base: String) async {
        guard let models = try? await ChatCompletionsClient.models(
            base: base, key: apiKey(for: base)) else { return }
        let sizes = await ChatCompletionsClient.modelSizes(base: base, key: apiKey(for: base))
        addOrUpdateEndpoint(base: base, models: models, sizes: sizes, key: nil)
    }

    // MARK: Generation, with the fallback (spec §2)

    /// The selected model answers; when it cannot, Apple's built-in
    /// model does, and `fallbackNotice` says so — a user action never
    /// fails solely because the preferred model is missing. Streaming
    /// lands on `onPartial` as the words arrive.
    func respond(instructions: String?, to prompt: String,
                 onPartial: (@MainActor (String) -> Void)? = nil)
        async throws -> (text: String, modelName: String) {
        if let (endpoint, model) = selectedEndpointModel() {
            do {
                let text = try await ChatCompletionsClient.respond(
                    base: endpoint.base, model: model,
                    key: apiKey(for: endpoint.base),
                    instructions: instructions, prompt: prompt,
                    onPartial: onPartial)
                return (text, "\(endpoint.hostLabel) \u{00B7} \(model)")
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                fallbackNotice = """
                    \(model) wasn\u{2019}t available \u{2014} used Apple\u{2019}s \
                    built-in model instead.
                    """
            }
        }
        let text = try await appleRespond(instructions: instructions,
                                          to: prompt, onPartial: onPartial)
        return (text, "Apple\u{2019}s built-in model")
    }

    /// Whether any model can answer now: a chosen server, or Apple's
    /// built-in model (which may still refuse — callers catch that).
    var canRespond: Bool {
        if selectedEndpointModel() != nil { return true }
        #if canImport(FoundationModels)
        if case .available = SystemLanguageModel.default.availability { return true }
        #endif
        return false
    }

    /// A structured answer from the chosen server: the model is asked for
    /// one JSON object, which is decoded. Nil when no server is chosen —
    /// the caller then uses Apple's guided generation. Throws when the
    /// reply is not the JSON asked for.
    func respondJSON<T: Decodable>(_ type: T.Type, instructions: String,
                                   prompt: String) async throws -> T? {
        guard selectedEndpointModel() != nil else { return nil }
        let (text, _) = try await respond(
            instructions: instructions + "\nReply with one JSON object only \u{2014} no prose, no code fence.",
            to: prompt)
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
              let data = String(text[start...end]).data(using: .utf8) else {
            throw OrigamiLLMError.generationFailed("The model did not answer in the form asked for.")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func appleRespond(instructions: String?, to prompt: String,
                              onPartial: (@MainActor (String) -> Void)?)
        async throws -> String {
        #if canImport(FoundationModels)
        guard case .available = SystemLanguageModel.default.availability else {
            throw OrigamiLLMError.appleUnavailable
        }
        let session = instructions.map { LanguageModelSession(instructions: $0) }
            ?? LanguageModelSession()
        if let onPartial {
            var text = ""
            for try await partial in session.streamResponse(to: prompt) {
                text = partial.content
                onPartial(text)
            }
            return text
        }
        return try await session.respond(to: prompt).content
        #else
        throw OrigamiLLMError.appleUnavailable
        #endif
    }

    // MARK: The paste box (spec §7)

    enum PasteOutcome {
        case endpoint(base: String, models: [String])
        case needsKey(base: String)
        case huggingFace(repo: String)
        case invalid(String)
    }

    /// Classifies one pasted string: a server URL (tried live), a
    /// Hugging Face repo (the MLX runtime's slot, not yet installed),
    /// or neither — with the two accepted forms spelled out.
    nonisolated static func classify(_ pasted: String) async -> PasteOutcome {
        let trimmed = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
            if let repo = huggingFaceRepo(in: trimmed) { return .huggingFace(repo: repo) }
            let base = ChatCompletionsClient.normalizedBase(trimmed)
            do {
                let models = try await ChatCompletionsClient.models(base: base, key: nil)
                return .endpoint(base: base, models: models)
            } catch OrigamiLLMError.authRequired {
                return .needsKey(base: base)
            } catch {
                return .invalid("Can\u{2019}t reach \(base). Is the server running?")
            }
        }
        if trimmed.range(of: #"^[\w.-]+/[\w.-]+$"#, options: .regularExpression) != nil {
            return .huggingFace(repo: trimmed)
        }
        return .invalid("""
            Paste a server address (like http://localhost:11434) or a \
            Hugging Face model id (like mlx-community/Qwen3-8B-4bit).
            """)
    }

    private nonisolated static func huggingFaceRepo(in url: String) -> String? {
        guard let components = URL(string: url), components.host()?.contains("huggingface.co") == true
        else { return nil }
        let parts = components.path().split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        return "\(parts[0])/\(parts[1])"
    }

    // MARK: Local-server detection (spec §6.1)

    /// Probes the well-known local servers — Ollama and LM Studio — on
    /// settings-open only, never in the background. Already-added
    /// bases are left out.
    func detectLocalServers() async -> [(base: String, models: [String])] {
        let candidates = ["http://localhost:11434", "http://localhost:1234"]
        var found: [(String, [String])] = []
        for base in candidates where !endpoints.contains(where: { $0.base == base }) {
            if let models = try? await ChatCompletionsClient.models(
                base: base, key: nil, timeout: 0.8), !models.isEmpty {
                found.append((base, models))
            }
        }
        return found
    }

    // MARK: Persistence

    private static func loadEndpoints() -> [OrigamiEndpoint] {
        guard let data = UserDefaults.standard.data(forKey: "llmEndpoints"),
              let decoded = try? JSONDecoder().decode([OrigamiEndpoint].self, from: data)
        else { return [] }
        return decoded
    }

    private func persistEndpoints() {
        if let data = try? JSONEncoder().encode(endpoints) {
            UserDefaults.standard.set(data, forKey: "llmEndpoints")
        }
    }
}

// MARK: - The chat-completions client (spec §6)

/// The OpenAI-compatible wire: GET /v1/models to discover, POST
/// /v1/chat/completions with stream:true to generate — the dialect
/// Ollama, LM Studio, MLX-LM's server, and the hosted providers all
/// speak.
nonisolated enum ChatCompletionsClient {

    /// scheme://host[:port] with trailing slashes and a trailing /v1
    /// stripped — users paste http://localhost:11434, not .../v1.
    static func normalizedBase(_ raw: String) -> String {
        var base = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        if base.lowercased().hasSuffix("/v1") { base.removeLast(3) }
        while base.hasSuffix("/") { base.removeLast() }
        return base
    }

    static func models(base: String, key: String?,
                       timeout: TimeInterval = 2) async throws -> [String] {
        guard let url = URL(string: base + "/v1/models") else {
            throw OrigamiLLMError.serverUnreachable(base)
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        if let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 || status == 403 {
                throw OrigamiLLMError.authRequired(URL(string: base)?.host() ?? base)
            }
            guard status == 200,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = object["data"] as? [[String: Any]] else {
                throw OrigamiLLMError.serverUnreachable(URL(string: base)?.host() ?? base)
            }
            return list.compactMap { $0["id"] as? String }.sorted()
        } catch let error as OrigamiLLMError {
            throw error
        } catch {
            throw OrigamiLLMError.serverUnreachable(URL(string: base)?.host() ?? base)
        }
    }

    /// Tries Ollama's /api/tags to get byte sizes for each model.
    /// Returns an empty dict silently for servers that don't support it.
    static func modelSizes(base: String, key: String?,
                           timeout: TimeInterval = 2) async -> [String: Int64] {
        guard let url = URL(string: base + "/api/tags") else { return [:] }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        if let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["models"] as? [[String: Any]] else { return [:] }
        var sizes: [String: Int64] = [:]
        for entry in list {
            if let name = entry["name"] as? String,
               let size = entry["size"] as? Int64 {
                sizes[name] = size
            }
        }
        return sizes
    }

    /// One generation, streamed (SSE) and gathered; `onPartial` sees
    /// the text grow. Cancellation cancels the transport.
    static func respond(base: String, model: String, key: String?,
                        instructions: String?, prompt: String,
                        onPartial: (@MainActor (String) -> Void)? = nil)
        async throws -> String {
        guard let url = URL(string: base + "/v1/chat/completions") else {
            throw OrigamiLLMError.serverUnreachable(base)
        }
        var messages: [[String: String]] = []
        if let instructions, !instructions.isEmpty {
            messages.append(["role": "system", "content": instructions])
        }
        messages.append(["role": "user", "content": prompt])
        var request = URLRequest(url: url, timeoutInterval: 300)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model, "messages": messages, "stream": true,
        ] as [String: Any])

        let host = URL(string: base)?.host() ?? base
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 || status == 403 { throw OrigamiLLMError.authRequired(host) }
            guard status == 200 else {
                throw OrigamiLLMError.generationFailed(
                    "\(host) answered with status \(status).")
            }
            var text = ""
            for try await line in bytes.lines {
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { break }
                guard let data = payload.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = object["choices"] as? [[String: Any]],
                      let delta = choices.first?["delta"] as? [String: Any],
                      let piece = delta["content"] as? String else { continue }
                text += piece
                if let onPartial {
                    let sofar = text
                    await MainActor.run { onPartial(sofar) }
                }
            }
            guard !text.isEmpty else {
                throw OrigamiLLMError.generationFailed("\(host) sent an empty reply.")
            }
            return text
        } catch let error as OrigamiLLMError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw OrigamiLLMError.serverUnreachable(host)
        }
    }
}

// MARK: - Keychain (spec §6 — keys never in defaults)

private nonisolated enum LLMKeychain {
    private static let service = "info.futuretextlab.origamitext.llm"

    static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String?, account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, let data = value.data(using: .utf8) else { return }
        var add = base
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }
}

// MARK: - Context panel: Explain in context and Claim Check

/// The context panel's AI layer (CONTEXT-PANEL-PLAN.md §4–5), through
/// OrigamiLLM so the reader's chosen model answers. The rule is the AI
/// summary's: the model may only say what the material it is handed
/// says, every claim carries a quote, each quote is checked verbatim
/// against the material, and whatever fails the check is dropped.
@MainActor
enum ContextAI {
    /// One passage the model may draw on, and where it is from.
    struct Source: Hashable {
        var text: String
        var name: String
        var url: URL?
    }

    struct Explanation {
        var sentences: [String]
        var dropped: Int
        var modelName: String
    }

    struct Verdict: Hashable, Identifiable {
        enum Stance: String { case supports, contradicts, refines }
        var stance: Stance
        var quote: String
        var source: Source
        var id: String { source.name + quote }
    }

    /// Lowercased, quotes straightened, spaces single — for verbatim checks.
    static func folded(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "[\u{2018}\u{2019}]", with: "'", options: .regularExpression)
            .replacingOccurrences(of: "[\u{201C}\u{201D}]", with: "\"", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    static func verifies(_ quote: String, in material: [Source]) -> Bool {
        let needle = folded(quote)
        guard needle.count >= 8 else { return false }
        return material.contains { folded($0.text).contains(needle) }
    }

    /// What the words mean here, from the material alone: sentences
    /// whose quotes all check out are kept, the rest dropped and counted.
    static func explain(_ words: String, sentence: String?, material: [Source]) async throws -> Explanation {
        let numbered = material.enumerated().map { "[\($0.offset + 1)] \($0.element.name): \($0.element.text)" }
            .joined(separator: "\n\n")
        let answer = try await OrigamiLLM.shared.respond(
            instructions: """
                You explain what selected words mean in the passage they come from, \
                using ONLY the numbered material given. Write two to four short sentences. \
                Every sentence must contain at least one exact quotation from the material \
                in double quotation marks, copied word for word. Say nothing the material \
                does not say. If the material is not enough, say so in one sentence.
                """,
            to: """
                SELECTED WORDS: \(words)
                \(sentence.map { "THE SENTENCE THEY ARE IN: \($0)" } ?? "")

                MATERIAL:
                \(numbered)
                """)
        var kept: [String] = []
        var dropped = 0
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = answer.text
        for range in tokenizer.tokens(for: answer.text.startIndex..<answer.text.endIndex) {
            let line = String(answer.text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let quotes = quotations(in: line)
            if !quotes.isEmpty, quotes.allSatisfy({ verifies($0, in: material) }) {
                kept.append(line)
            } else {
                dropped += 1
            }
        }
        return Explanation(sentences: kept, dropped: dropped, modelName: answer.modelName)
    }

    /// Each passage sorted against the claim — supports, contradicts or
    /// refines — with the words that decide it, checked verbatim against
    /// the passage. Unrelated passages and failed quotes are dropped.
    static func checkClaim(_ claim: String, passages: [Source]) async throws -> [Verdict] {
        struct Reply: Decodable { var stance: String; var quote: String }
        var verdicts: [Verdict] = []
        for passage in passages.prefix(8) {
            if Task.isCancelled { break }
            let answer = try await OrigamiLLM.shared.respond(
                instructions: """
                    You compare a passage with a claim. Answer with one JSON object only, \
                    no prose: {"stance": "supports" | "contradicts" | "refines" | "unrelated", \
                    "quote": "the exact words from the passage that decide it, copied word for word"}.
                    """,
                to: "CLAIM: \(claim)\n\nPASSAGE (\(passage.name)): \(passage.text)")
            guard let start = answer.text.firstIndex(of: "{"), let end = answer.text.lastIndex(of: "}"),
                  let data = String(answer.text[start...end]).data(using: .utf8),
                  let reply = try? JSONDecoder().decode(Reply.self, from: data),
                  let stance = Verdict.Stance(rawValue: reply.stance.lowercased()),
                  verifies(reply.quote, in: [passage]) else { continue }
            verdicts.append(Verdict(stance: stance, quote: reply.quote, source: passage))
        }
        return verdicts
    }

    private static func quotations(in line: String) -> [String] {
        let pattern = #"[\"\u{201C}]([^\"\u{201C}\u{201D}]{4,})[\"\u{201D}]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let text = line as NSString
        return regex.matches(in: line, range: NSRange(location: 0, length: text.length))
            .map { text.substring(with: $0.range(at: 1)) }
    }
}

/// The AI rows of a context panel, shared by the Mac and Vision Pro:
/// Explain in Context always; Check This Claim for a claim or passage.
struct ContextAISection: View {
    let query: ContextQuery
    /// The sentence the words are in, when known.
    let sentence: String?
    /// What the panel found — ring 1 and ring 2 — as quotable material.
    let material: [ContextAI.Source]
    var excerptSize: CGFloat = 15

    @State private var explanation: ContextAI.Explanation?
    @State private var verdicts: [ContextAI.Verdict]?
    @State private var working: String?
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("AI").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("Explain in Context", action: explain)
                    .disabled(working != nil || material.isEmpty)
                if query.kind == .claim || query.kind == .passage {
                    Button("Check This Claim", action: check)
                        .disabled(working != nil)
                }
            }
            .controlSize(.small)
            if let working {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(working).font(.callout).foregroundStyle(.secondary)
                }
            }
            if let failure {
                Text(failure).font(.callout).foregroundStyle(.orange)
            }
            if let explanation {
                ForEach(explanation.sentences, id: \.self) { line in
                    Text(line).font(.system(size: excerptSize))
                }
                Text(explanation.sentences.isEmpty
                     ? "Nothing the model said could be checked against the material, so nothing is shown."
                     : "\(explanation.modelName)\(explanation.dropped > 0 ? " \u{00B7} \(explanation.dropped) unverified sentence\(explanation.dropped == 1 ? "" : "s") dropped" : "")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let verdicts {
                if verdicts.isEmpty {
                    Text("No passage clearly bears on this claim.").font(.callout).foregroundStyle(.tertiary)
                }
                ForEach([ContextAI.Verdict.Stance.supports, .contradicts, .refines], id: \.self) { stance in
                    let group = verdicts.filter { $0.stance == stance }
                    if !group.isEmpty {
                        Text(stance.rawValue.capitalized).font(.callout.weight(.semibold))
                            .foregroundStyle(stance == .supports ? .green : stance == .contradicts ? .red : .orange)
                        ForEach(group) { verdict in
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\u{201C}\(verdict.quote)\u{201D}").font(.system(size: excerptSize))
                                if let url = verdict.source.url {
                                    Link(verdict.source.name, destination: url).font(.caption)
                                } else {
                                    Text(verdict.source.name).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .onChange(of: query) {
            explanation = nil; verdicts = nil; failure = nil
        }
    }

    private func explain() {
        working = "Reading the material\u{2026}"
        failure = nil
        Task {
            defer { working = nil }
            do {
                explanation = try await ContextAI.explain(query.text, sentence: sentence, material: material)
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    /// Gathers the library's passages and, when allowed, Semantic
    /// Scholar's, then sorts each against the claim.
    private func check() {
        working = "Gathering passages\u{2026}"
        failure = nil
        Task {
            defer { working = nil }
            var passages = material.filter { $0.name != "This paper" }
            if ContextOnline.isOn(ContextOnline.passagesKey),
               let online = await ContextOnline.passages(for: query.text) {
                passages += online.map { ContextAI.Source(text: $0.text, name: $0.title, url: $0.url) }
            }
            guard !passages.isEmpty else {
                failure = "No passages to check against \u{2014} nothing in your library, and nothing online."
                return
            }
            working = "Checking \(min(passages.count, 8)) passages\u{2026}"
            do {
                verdicts = try await ContextAI.checkClaim(query.text, passages: passages)
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

// MARK: - The settings sections (spec §8, hosted by Settings ▸ AI)

/// The model picker, the paste box, and the endpoint list — dropped
/// into the AI settings tab's Form.
struct LLMModelSettingsSections: View {
    @State private var llm = OrigamiLLM.shared
    @State private var pasted = ""
    @State private var isClassifying = false
    @State private var status: String?
    /// A base waiting on its API key (the paste box's auth branch).
    @State private var keyBase: String?
    @State private var keyText = ""
    /// A reachable non-local server awaiting the §11 confirmation.
    @State private var pendingRemote: (base: String, models: [String])?
    /// The one-tap banner for a detected local server (§6.1).
    @State private var detected: (base: String, models: [String])?
    @State private var showingRecommendations = false

    var body: some View {
        Section {
            Picker("Choose Model", selection: Binding(
                get: { llm.selectedID },
                set: { llm.selectedID = $0 })) {
                Text("Apple\u{2019}s built-in \u{2014} on \(OrigamiLLM.thisDevice)").tag("apple")
                ForEach(llm.endpoints) { endpoint in
                    ForEach(endpoint.models, id: \.self) { model in
                        Text("\(endpoint.hostLabel) \u{00B7} \(model)")
                            .tag(OrigamiLLM.endpointID(base: endpoint.base, model: model))
                    }
                }
            }
        } header: {
            Text("Language Model")
        } footer: {
            Text("""
                Apple\u{2019}s built-in model runs on \(OrigamiLLM.thisDevice) \u{2014} no text \
                leaves it. A server model sends the text it reads to that \
                server. The reading\u{2019}s AI (Summary, Issues, and \
                the selection presets) uses the chosen model; when it isn\u{2019}t \
                reachable, Apple\u{2019}s model answers and says so.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section {
            if let detected {
                HStack {
                    let name = detected.base.contains("11434") ? "Ollama" : "LM Studio"
                    Text("\(name) is running with \(detected.models.count) model\(detected.models.count == 1 ? "" : "s").")
                    Spacer()
                    Button("Add") {
                        llm.addOrUpdateEndpoint(base: detected.base,
                                                models: detected.models, key: nil)
                        self.detected = nil
                        status = "Added."
                    }
                }
            }
            HStack {
                TextField("A server address, such as http://localhost:11434",
                          text: $pasted)
                    .onSubmit { classifyPasted() }
                Button("Add") { classifyPasted() }
                    .disabled(isClassifying
                              || pasted.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let keyBase {
                SecureField("API key for \(keyBase)", text: $keyText)
                Button("Add with Key") { retryWithKey(keyBase) }
                    .disabled(keyText.isEmpty || isClassifying)
            }
            if let pendingRemote {
                // §11: a non-local server sees the reader's text — said
                // before it is added, not after.
                Text("\(pendingRemote.base) is not on \(OrigamiLLM.thisDevice): document text will be sent to that server.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Button("Add Anyway") {
                    llm.addOrUpdateEndpoint(base: pendingRemote.base,
                                            models: pendingRemote.models,
                                            key: keyText.isEmpty ? nil : keyText)
                    self.pendingRemote = nil
                    keyText = ""
                    status = "Added."
                }
            }
            if isClassifying {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Asking the server\u{2026}").foregroundStyle(.secondary)
                }
            } else if let status {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            #if os(macOS)
            Button("Find a model for this Mac\u{2026}") {
                showingRecommendations = true
            }
            .popover(isPresented: $showingRecommendations, arrowEdge: .trailing) {
                ModelRecommendationsView(specs: .current)
            }
            #endif
        } header: {
            Text("Add a Model or Server")
        } footer: {
            Text("""
                Ollama and LM Studio are found automatically while they run. \
                To use a model from Hugging Face, run it in one of them \
                (\u{201C}ollama pull\u{201D}) and it appears here.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if !llm.endpoints.isEmpty {
            Section("Servers") {
                ForEach(llm.endpoints) { endpoint in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(endpoint.base)
                            Text("\(endpoint.models.count) model\(endpoint.models.count == 1 ? "" : "s")\(endpoint.hasKey ? " \u{00B7} key in Keychain" : "")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Refresh") {
                            Task { await llm.refreshModels(for: endpoint.base) }
                        }
                        .buttonStyle(.borderless)
                        Button(role: .destructive) {
                            llm.removeEndpoint(endpoint.base)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }

        // The detection probe runs when the pane opens — never in the
        // background (§6.1).
        Section {
            EmptyView()
        }
        .task {
            for endpoint in llm.endpoints {
                await llm.refreshModels(for: endpoint.base)
            }
            detected = await llm.detectLocalServers().first
        }

    }

    private func classifyPasted() {
        let text = pasted
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isClassifying = true
        status = nil
        keyBase = nil
        pendingRemote = nil
        Task { @MainActor in
            defer { isClassifying = false }
            switch await OrigamiLLM.classify(text) {
            case .endpoint(let base, let models):
                let entry = OrigamiEndpoint(base: base)
                if entry.isLocal {
                    llm.addOrUpdateEndpoint(base: base, models: models, key: nil)
                    status = "Added \(models.count) model\(models.count == 1 ? "" : "s")."
                    pasted = ""
                } else {
                    pendingRemote = (base, models)
                }
            case .needsKey(let base):
                keyBase = base
                status = nil
            case .huggingFace(let repo):
                status = """
                    \(repo) is a Hugging Face model \u{2014} in-app downloads \
                    arrive with the MLX runtime. For now, point the app at a \
                    server (Ollama can run it: \u{201C}ollama pull\u{201D}).
                    """
            case .invalid(let message):
                status = message
            }
        }
    }

    private func retryWithKey(_ base: String) {
        isClassifying = true
        Task { @MainActor in
            defer { isClassifying = false }
            do {
                let models = try await ChatCompletionsClient.models(base: base, key: keyText)
                let entry = OrigamiEndpoint(base: base)
                if entry.isLocal {
                    llm.addOrUpdateEndpoint(base: base, models: models, key: keyText)
                    status = "Added \(models.count) model\(models.count == 1 ? "" : "s")."
                    keyBase = nil
                    keyText = ""
                    pasted = ""
                } else {
                    pendingRemote = (base, models)
                    keyBase = nil
                }
            } catch {
                status = error.localizedDescription
            }
        }
    }
}

#if os(macOS)
// MARK: - Mac hardware snapshot

fileprivate struct MacSpecs {
    let ramGB: Int
    let isAppleSilicon: Bool

    static var current: MacSpecs {
        let ram = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
        var flag: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctlbyname("hw.optional.arm64", &flag, &size, nil, 0)
        return MacSpecs(ramGB: ram, isAppleSilicon: flag == 1)
    }
}

// MARK: - Curated model catalogue (researched August 2026)

fileprivate struct OllamaRecommendation: Identifiable {
    let id: String          // Ollama pull ID, e.g. "qwen3:14b"
    let displayName: String
    let summary: String
    let diskGB: Double
    let minRAMGB: Int
}

fileprivate enum OllamaModelCatalog {
    static let all: [OllamaRecommendation] = [
        // ── 8 GB ─────────────────────────────────────────────────────────
        OllamaRecommendation(
            id: "phi4-mini", displayName: "Phi-4-mini 3.8B",
            summary: "Remarkable 128K context for a 3.8B model; fast on any Mac; best choice for long EPUB passages on 8 GB",
            diskGB: 2.5, minRAMGB: 8),
        OllamaRecommendation(
            id: "llama3.2:3b", displayName: "Llama 3.2 3B",
            summary: "Lightweight and quick; good for short summaries when speed matters most",
            diskGB: 2.0, minRAMGB: 8),
        OllamaRecommendation(
            id: "qwen3:4b", displayName: "Qwen 3 4B",
            summary: "Outperforms older 7B models; thinking mode for step-by-step reasoning; fits any Mac",
            diskGB: 2.7, minRAMGB: 8),
        OllamaRecommendation(
            id: "qwen3:8b", displayName: "Qwen 3 8B",
            summary: "Best accuracy on 8 GB Macs; stronger reasoning than Llama 3.1 8B; built-in thinking mode",
            diskGB: 5.2, minRAMGB: 8),
        // ── 16 GB ────────────────────────────────────────────────────────
        OllamaRecommendation(
            id: "qwen3:14b", displayName: "Qwen 3 14B",
            summary: "128K\u{2013}1M context; strongest multilingual; standout accuracy for 16 GB Macs",
            diskGB: 9.0, minRAMGB: 16),
        // ── 24 GB ────────────────────────────────────────────────────────
        OllamaRecommendation(
            id: "mistral-small:22b", displayName: "Mistral Small 22B",
            summary: "High summarisation accuracy in benchmarks; fast inference; good all-rounder for 24 GB",
            diskGB: 14.0, minRAMGB: 24),
        // ── 32 GB ────────────────────────────────────────────────────────
        OllamaRecommendation(
            id: "qwen3:27b", displayName: "Qwen 3 27B",
            summary: "Near-frontier quality; best dense model for 32 GB Macs",
            diskGB: 17.0, minRAMGB: 32),
        OllamaRecommendation(
            id: "qwen3:30b-a3b", displayName: "Qwen 3 30B-A3B (MoE)",
            summary: "MoE: 3B active params, 30B total \u{2014} faster than the dense 27B and often smarter; the best value at 32 GB",
            diskGB: 19.0, minRAMGB: 32),
        // ── 64 GB ────────────────────────────────────────────────────────
        OllamaRecommendation(
            id: "llama3.3:70b", displayName: "Llama 3.3 70B",
            summary: "Deep document analysis and RAG; one of the strongest dense 70B models available",
            diskGB: 43.0, minRAMGB: 64),
        OllamaRecommendation(
            id: "qwen3:70b", displayName: "Qwen 3 70B",
            summary: "Frontier-class reasoning and multilingual; trades blows with hosted models on most benchmarks",
            diskGB: 47.0, minRAMGB: 64),
        // ── 80 GB ────────────────────────────────────────────────────────
        OllamaRecommendation(
            id: "llama4:scout", displayName: "Llama 4 Scout (MoE)",
            summary: "10M-token context \u{2014} an entire EPUB library in one pass; MoE (17B active of 109B total); needs \u{2265}80 GB RAM",
            diskGB: 69.0, minRAMGB: 80),
    ]

    static func recommendations(for specs: MacSpecs) -> [OllamaRecommendation] {
        all.filter { $0.minRAMGB <= specs.ramGB }
    }
}

// MARK: - Recommendations sheet

fileprivate struct ModelRecommendationsView: View {
    let specs: MacSpecs
    @Environment(\.dismiss) private var dismiss
    @State private var copiedID: String?
    @State private var llm = OrigamiLLM.shared

    private var installedModelIDs: Set<String> {
        Set(llm.endpoints.flatMap { $0.models })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Title row
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Models for your Mac")
                        .font(.headline)
                    HStack(spacing: 10) {
                        Label("\(specs.ramGB)\u{00A0}GB memory", systemImage: "memorychip")
                        if specs.isAppleSilicon {
                            Label("Apple Silicon", systemImage: "cpu")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            Text("All models run on Ollama. Click \u{201C}Copy command\u{201D} on any row, then paste it in Terminal after installing Ollama.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal)
                .padding(.bottom, 10)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(OllamaModelCatalog.all) { model in
                        RecommendationRow(
                            model: model,
                            isCompatible: model.minRAMGB <= specs.ramGB,
                            isInstalled: installedModelIDs.contains(model.id),
                            copiedID: $copiedID)
                        Divider().padding(.leading)
                    }
                }
            }

            Divider()

            HStack {
                Text("Researched August 2026.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Link("Browse all at ollama.com", destination: URL(string: "https://ollama.com/library")!)
                    .font(.caption)
            }
            .padding()
        }
        .frame(width: 520, height: 480)
    }
}

private struct RecommendationRow: View {
    let model: OllamaRecommendation
    let isCompatible: Bool
    let isInstalled: Bool
    @Binding var copiedID: String?

    private var pullCommand: String { "ollama pull \(model.id)" }
    private var isCopied: Bool { copiedID == model.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {

            // Name + size badges
            HStack(spacing: 6) {
                Text(model.displayName)
                    .fontWeight(.semibold)
                Spacer()
                Label(String(format: "%.0f\u{00A0}GB RAM", Double(model.minRAMGB)),
                      systemImage: "memorychip")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(String(format: "%.0f\u{00A0}GB download", model.diskGB))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.secondary.opacity(0.12), in: Capsule())
            }

            // Description
            Text(model.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Status pills
            if isCompatible || isInstalled {
                HStack(spacing: 6) {
                    if isCompatible {
                        Text("Compatible with this Mac")
                            .font(.caption2)
                            .foregroundStyle(.green)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.green.opacity(0.12), in: Capsule())
                    }
                    if isInstalled {
                        Text("Installed")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.blue.opacity(0.12), in: Capsule())
                    }
                }
            }

            // Pull command + copy button
            HStack(spacing: 8) {
                Text(pullCommand)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(pullCommand, forType: .string)
                    copiedID = model.id
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        if copiedID == model.id { copiedID = nil }
                    }
                } label: {
                    Label(isCopied ? "Copied" : "Copy command",
                          systemImage: isCopied ? "checkmark" : "doc.on.doc")
                        .animation(.default, value: isCopied)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(isCopied ? .green : nil)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }
}
#endif // os(macOS) — recommendations
#endif
