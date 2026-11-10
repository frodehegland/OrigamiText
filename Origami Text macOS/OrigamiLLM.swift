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
    case modelNotFound(String)
    case authRequired(String)
    case appleUnavailable
    case generationFailed(String)

    /// Only these send a request on to Apple's model: the chosen server
    /// or model is simply not there. Anything else — a missing key, a
    /// refusal, a malformed answer — is the user's to see (spec §2).
    var allowsFallback: Bool {
        switch self {
        case .serverUnreachable, .modelNotFound: true
        default: false
        }
    }

    var errorDescription: String? {
        switch self {
        case .serverUnreachable(let host):
            "Can\u{2019}t reach \(host). Is the server running?"
        case .modelNotFound(let model):
            "The model \(model) isn\u{2019}t on the server."
        case .authRequired(let host):
            "\(host) needs an API key. Add one in Settings."
        case .appleUnavailable:
            "The on-device model isn\u{2019}t available on \(OrigamiLLM.thisDevice)."
        case .generationFailed(let why):
            why
        }
    }
}

// MARK: - The Mac as the headset's AI (9 Nov 2026)

/// Where the Mac's Origami Text serves its AI to the other devices: written
/// by the Mac into the community folder when Settings ▸ AI ▸ Serve AI to
/// Vision Pro is on, read by the headset — so it finds its Mac with nothing
/// to type. The token keeps the service to devices that share the folder.
nonisolated struct MacAIHost: Codable, Equatable, Sendable {
    static let fileName = "origami-ai-host.json"
    var base: String
    /// The same service by the Mac's network addresses, tried if its name
    /// does not answer.
    var alternates: [String] = []
    var token: String
    /// What the Mac answers with, for the headset to name.
    var model: String
    var macName: String
    var modified: Date

    static func read(from community: URL) -> MacAIHost? {
        let scoped = community.startAccessingSecurityScopedResource()
        defer { if scoped { community.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: community.appendingPathComponent(fileName)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(MacAIHost.self, from: data)
    }

    static func write(_ host: MacAIHost?, to community: URL) {
        let scoped = community.startAccessingSecurityScopedResource()
        defer { if scoped { community.stopAccessingSecurityScopedResource() } }
        let url = community.appendingPathComponent(fileName)
        guard let host else { try? FileManager.default.removeItem(at: url); return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(host) else { return }
        try? data.write(to: url, options: .atomic)
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

    /// The Mac serving its AI, as the community folder names it — read by
    /// the headset (9 Nov 2026). Asked after a chosen server and before the
    /// headset's own model.
    var macHost: MacAIHost?

    /// The Mac's AI, asked by its name and then its addresses: the text,
    /// and the name to show — or nil when there is no Mac to ask.
    private func askMac(instructions: String?, prompt: String,
                        jsonSchema: (name: String, schema: [String: Any])? = nil,
                        temperature: Double? = nil,
                        onPartial: (@MainActor (String) -> Void)?) async throws -> (String, String)? {
        #if os(macOS)
        return nil
        #else
        guard let host = macHost else { return nil }
        var lastError: OrigamiLLMError?
        for base in [host.base] + host.alternates {
            do {
                let text = try await ChatCompletionsClient.respond(
                    base: base, model: host.model, key: host.token,
                    instructions: instructions, prompt: prompt, jsonSchema: jsonSchema,
                    temperature: temperature, onPartial: onPartial)
                return (text, "\(host.macName) \u{00B7} \(host.model)")
            } catch let error as OrigamiLLMError where error.allowsFallback {
                lastError = error
            }
        }
        throw lastError ?? OrigamiLLMError.serverUnreachable(host.macName)
        #endif
    }

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

    /// The embedding model, an Ollama model id ("qwen3-embedding:8b"):
    /// what turns a passage into numbers, so Similar and Themes can
    /// measure how near two articles stand. Persisted.
    var embeddingModel: String {
        didSet { UserDefaults.standard.set(embeddingModel, forKey: "embeddingModelID") }
    }

    /// A model being downloaded onto the Ollama server, and how far it is.
    private(set) var download: ModelDownload?

    struct ModelDownload: Equatable {
        var model: String
        var status: String
        var fraction: Double?
        var failure: String?
    }

    private init() {
        selectedID = UserDefaults.standard.string(forKey: "selectedModelID") ?? "apple"
        endpoints = Self.loadEndpoints()
        embeddingModel = UserDefaults.standard.string(forKey: "embeddingModelID")
            ?? EmbeddingModelCatalog.suggested.id
    }

    /// A model name that marks an embedding model ("qwen3-embedding:8b",
    /// "text-embedding-nomic-embed-text-v1.5", "bge-m3").
    nonisolated static func isEmbeddingOnly(_ model: String) -> Bool {
        let name = model.lowercased()
        return name.contains("embed") || name.hasPrefix("bge-") || name.contains("/bge-")
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
        #if os(macOS)
        if let choice = selectedLocalChoice { return choice.modelName + " \u{2014} on this Mac" }
        #endif
        return selectedEndpointModel().map { "\($0.endpoint.hostLabel) \u{00B7} \($0.model)" }
            ?? "Apple\u{2019}s built-in model"
    }

    #if os(macOS)
    /// A model Origami runs itself (`LocalModels`): "local|<choice id>".
    static let localPrefix = "local|"

    static func localID(_ choice: LocalModelChoice) -> String { localPrefix + choice.id }

    /// The selection as one of Origami's own models — nil when it names
    /// another, or names one not yet downloaded.
    var selectedLocalChoice: LocalModelChoice? {
        guard selectedID.hasPrefix(Self.localPrefix) else { return nil }
        let id = String(selectedID.dropFirst(Self.localPrefix.count))
        guard let choice = LocalModelChoice.ladder.first(where: { $0.id == id }) else { return nil }
        #if canImport(MLXLLM) && canImport(MLXEmbedders) && canImport(MLXHuggingFace)
        return LocalModels.shared.isReady(choice) ? choice : nil
        #else
        return nil
        #endif
    }
    #endif

    /// The embedding model in use, by name — Origami's own pair's when one
    /// is chosen, else the Ollama model. Vectors are cached under it, so
    /// two models' vectors are never compared.
    var activeEmbeddingModel: String {
        #if os(macOS)
        if let choice = selectedLocalChoice { return choice.embedRepo }
        #endif
        return embeddingModel
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
    /// `transformingContent` is for work on the reader's own material —
    /// summarizing, analysing — where Apple's default guardrails refuse
    /// far too easily; Apple's model then runs with its
    /// content-transformation guardrails. Servers ignore it.
    func respond(instructions: String?, to prompt: String,
                 transformingContent: Bool = false,
                 onPartial: (@MainActor (String) -> Void)? = nil)
        async throws -> (text: String, modelName: String) {
        #if os(macOS) && canImport(MLXLLM) && canImport(MLXEmbedders) && canImport(MLXHuggingFace)
        if let choice = selectedLocalChoice {
            let text = try await LocalModels.shared.respond(
                choice, instructions: instructions, prompt: prompt, onPartial: onPartial)
            return (text, choice.modelName)
        }
        #endif
        // Why a server could not answer — shown instead of the built-in
        // model's own excuse when that cannot answer either (9 Nov 2026).
        var unreached: OrigamiLLMError?
        if let (endpoint, model) = selectedEndpointModel() {
            do {
                let text = try await ChatCompletionsClient.respond(
                    base: endpoint.base, model: model,
                    key: apiKey(for: endpoint.base),
                    instructions: instructions, prompt: prompt,
                    onPartial: onPartial)
                return (text, "\(endpoint.hostLabel) \u{00B7} \(model)")
            } catch let error as OrigamiLLMError where error.allowsFallback {
                noteFallback(from: model)
                unreached = error
            }
        }
        do {
            if let answer = try await askMac(instructions: instructions, prompt: prompt,
                                             onPartial: onPartial) {
                return answer
            }
        } catch let error as OrigamiLLMError where error.allowsFallback {
            unreached = unreached ?? error
        }
        do {
            let text = try await appleRespond(instructions: instructions, to: prompt,
                                              transformingContent: transformingContent,
                                              onPartial: onPartial)
            return (text, "Apple\u{2019}s built-in model")
        } catch OrigamiLLMError.appleUnavailable where unreached != nil {
            throw unreached!
        }
    }

    private func noteFallback(from model: String) {
        fallbackNotice = """
            \(model) wasn\u{2019}t available \u{2014} used Apple\u{2019}s \
            built-in model instead.
            """
    }

    #if canImport(FoundationModels)
    /// A structured answer of type `T` from whichever model is chosen —
    /// the one door for every feature that needs more than prose. Apple's
    /// model fills `T` by guided generation. A server is sent `T`'s
    /// generation schema as a JSON Schema (`response_format`, which Ollama,
    /// LM Studio and MLX-LM honour), and its JSON reply is read back
    /// through `GeneratedContent`, so the feature sees the same `T` either
    /// way. The fallback rule is `respond`'s: only a missing server or
    /// model falls back.
    func generate<T: Generable>(_ type: T.Type, instructions: String?,
                                prompt: String,
                                options: GenerationOptions = GenerationOptions(),
                                transformingContent: Bool = false)
        async throws -> (content: T, modelName: String) {
        #if os(macOS) && canImport(MLXLLM) && canImport(MLXEmbedders) && canImport(MLXHuggingFace)
        // Origami's own model is asked for the same JSON a server is.
        if let choice = selectedLocalChoice {
            let schema = try Self.jsonSchema(for: T.self)
            let shape = "Reply with one JSON object only \u{2014} no prose, no code fence \u{2014} matching this JSON Schema:\n"
                + (String(data: try JSONSerialization.data(withJSONObject: schema), encoding: .utf8) ?? "")
            let text = try await LocalModels.shared.respond(
                choice, instructions: [instructions, shape].compactMap { $0 }.joined(separator: "\n\n"),
                prompt: prompt, temperature: options.temperature.map(Float.init), onPartial: nil)
            return (try Self.decode(T.self, from: text, host: choice.modelName), choice.modelName)
        }
        #endif
        var unreached: OrigamiLLMError?
        if let (endpoint, model) = selectedEndpointModel() {
            do {
                let schema = try Self.jsonSchema(for: T.self)
                let shape = "Reply with one JSON object only \u{2014} no prose, no code fence \u{2014} matching this JSON Schema:\n"
                    + (String(data: try JSONSerialization.data(withJSONObject: schema), encoding: .utf8) ?? "")
                let text = try await ChatCompletionsClient.respond(
                    base: endpoint.base, model: model,
                    key: apiKey(for: endpoint.base),
                    instructions: [instructions, shape].compactMap { $0 }.joined(separator: "\n\n"),
                    prompt: prompt,
                    jsonSchema: (name: String(describing: T.self), schema: schema),
                    temperature: options.temperature)
                return (try Self.decode(T.self, from: text, host: endpoint.hostLabel),
                        "\(endpoint.hostLabel) \u{00B7} \(model)")
            } catch let error as OrigamiLLMError where error.allowsFallback {
                noteFallback(from: model)
                unreached = error
            }
        }
        // The Mac's AI, asked for the same JSON a server is.
        do {
            let schema = try Self.jsonSchema(for: T.self)
            let shape = "Reply with one JSON object only \u{2014} no prose, no code fence \u{2014} matching this JSON Schema:\n"
                + (String(data: try JSONSerialization.data(withJSONObject: schema), encoding: .utf8) ?? "")
            if let (text, name) = try await askMac(
                instructions: [instructions, shape].compactMap { $0 }.joined(separator: "\n\n"),
                prompt: prompt, jsonSchema: (name: String(describing: T.self), schema: schema),
                temperature: options.temperature, onPartial: nil) {
                return (try Self.decode(T.self, from: text, host: name), name)
            }
        } catch let error as OrigamiLLMError where error.allowsFallback {
            unreached = unreached ?? error
        }
        guard case .available = SystemLanguageModel.default.availability else {
            throw unreached ?? OrigamiLLMError.appleUnavailable
        }
        let session = Self.appleSession(instructions: instructions,
                                        transformingContent: transformingContent)
        let response = try await session.respond(to: prompt, generating: T.self,
                                                 options: options)
        return (response.content, "Apple\u{2019}s built-in model")
    }

    /// `T`'s generation schema in JSON Schema form, as a JSON object.
    nonisolated static func jsonSchema<T: Generable>(for type: T.Type) throws -> [String: Any] {
        let data = try JSONEncoder().encode(T.generationSchema)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OrigamiLLMError.generationFailed("Could not describe the answer\u{2019}s shape.")
        }
        return object
    }

    /// Reads a server's reply as `T`: the outermost `{…}` (tolerating a
    /// stray fence or sentence around it), through `GeneratedContent`.
    nonisolated static func decode<T: Generable>(_ type: T.Type, from text: String,
                                                 host: String) throws -> T {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
              start < end else {
            throw OrigamiLLMError.generationFailed("\(host) did not answer in the form asked for.")
        }
        do {
            return try T(GeneratedContent(json: String(text[start...end])))
        } catch {
            throw OrigamiLLMError.generationFailed(
                "\(host) answered, but not in the form asked for: \(error.localizedDescription)")
        }
    }
    #endif

    /// Whether any model can answer now: a chosen server, or Apple's
    /// built-in model (which may still refuse — callers catch that).
    var canRespond: Bool {
        #if os(macOS)
        if selectedLocalChoice != nil { return true }
        #endif
        if selectedEndpointModel() != nil { return true }
        if macHost != nil { return true }
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
        var chosen = selectedEndpointModel() != nil || macHost != nil
        #if os(macOS)
        if selectedLocalChoice != nil { chosen = true }
        #endif
        guard chosen else { return nil }
        let (text, _) = try await respond(
            instructions: instructions + "\nReply with one JSON object only \u{2014} no prose, no code fence.",
            to: prompt)
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
              let data = String(text[start...end]).data(using: .utf8) else {
            throw OrigamiLLMError.generationFailed("The model did not answer in the form asked for.")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    #if canImport(FoundationModels)
    private static func appleSession(instructions: String?,
                                     transformingContent: Bool) -> LanguageModelSession {
        let model = transformingContent
            ? SystemLanguageModel(guardrails: .permissiveContentTransformations)
            : SystemLanguageModel.default
        return LanguageModelSession(model: model, instructions: instructions)
    }
    #endif

    private func appleRespond(instructions: String?, to prompt: String,
                              transformingContent: Bool,
                              onPartial: (@MainActor (String) -> Void)?)
        async throws -> String {
        #if canImport(FoundationModels)
        guard case .available = SystemLanguageModel.default.availability else {
            throw OrigamiLLMError.appleUnavailable
        }
        let session = Self.appleSession(instructions: instructions,
                                        transformingContent: transformingContent)
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
        /// An Ollama model by name (4 Nov 2026): "--model kimi-k3.1-pro:cloud",
        /// "ollama run qwen3:8b", "ollama pull gpt-oss:120b-cloud", or the
        /// bare name.
        case ollamaModel(name: String)
        case invalid(String)
    }

    /// The Ollama model a pasted line names, if it names one: the word after
    /// `--model` (or `--model=`), after `ollama run` / `ollama pull`, or the
    /// line itself when it is one model name with a tag ("qwen3:8b",
    /// "kimi-k3.1-pro:cloud").
    /// An Ollama model that runs on Ollama's servers rather than here.
    nonisolated static func isCloudModel(_ name: String) -> Bool {
        let tag = name.split(separator: ":").last.map(String.init) ?? ""
        return tag == "cloud" || tag.hasSuffix("-cloud")
    }

    nonisolated static func ollamaModelName(in pasted: String) -> String? {
        let words = pasted.split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`\u{201C}\u{201D}")) }
            .filter { !$0.isEmpty }
        func plausible(_ name: String) -> String? {
            name.range(of: #"^[A-Za-z0-9][\w.\-/]*(:[\w.\-]+)?$"#, options: .regularExpression) != nil ? name : nil
        }
        for (index, word) in words.enumerated() {
            if word == "--model", index + 1 < words.count { return plausible(words[index + 1]) }
            if word.hasPrefix("--model=") { return plausible(String(word.dropFirst("--model=".count))) }
        }
        if words.count >= 3, words[0].lowercased() == "ollama", ["run", "pull"].contains(words[1].lowercased()) {
            return plausible(words[2])
        }
        if words.count == 1, words[0].contains(":"), !words[0].contains("://") { return plausible(words[0]) }
        return nil
    }

    /// An Ollama model added by name (4 Nov 2026): Ollama on this Mac is
    /// added as a server if it is not yet, the model fetched through it —
    /// a `:cloud` model only registers, Ollama's own account then runs it —
    /// and made the model in use. Progress in `download`.
    func addOllamaModel(_ name: String) async throws {
        let base = ollamaBase
        let host = URL(string: base)?.host() ?? base
        let key = apiKey(for: base)
        guard (try? await ChatCompletionsClient.models(base: base, key: key, timeout: 2)) != nil else {
            throw OrigamiLLMError.generationFailed("Ollama isn\u{2019}t running on \(host). Open the Ollama app, then paste the model again.")
        }
        let installed = await OllamaClient.installedModels(base: base, key: key)
        if !installed.contains(where: { OllamaClient.sameModel($0, name) }) {
            download = ModelDownload(model: name, status: "Starting\u{2026}")
            do {
                try await OllamaClient.pull(base: base, model: name, key: key) { status, fraction in
                    self.download = ModelDownload(model: name, status: status, fraction: fraction)
                }
            } catch {
                var why = error.localizedDescription
                if Self.isCloudModel(name),
                   why.lowercased().contains("unauthorized") || why.lowercased().contains("sign") {
                    why = "\(name) runs on Ollama\u{2019}s cloud: sign in to Ollama first (its app, or \u{201C}ollama signin\u{201D}), then paste it again."
                }
                download = ModelDownload(model: name, status: "", failure: why)
                throw OrigamiLLMError.generationFailed(why)
            }
            download = nil
        }
        let models = (try? await ChatCompletionsClient.models(base: base, key: key)) ?? []
        let sizes = await ChatCompletionsClient.modelSizes(base: base, key: key)
        addOrUpdateEndpoint(base: base, models: models.contains(name) ? models : models + [name], sizes: sizes, key: nil)
        selectedID = Self.endpointID(base: ChatCompletionsClient.normalizedBase(base), model: name)
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
        if let name = ollamaModelName(in: trimmed) { return .ollamaModel(name: name) }
        if trimmed.range(of: #"^[\w.-]+/[\w.-]+$"#, options: .regularExpression) != nil {
            return .huggingFace(repo: trimmed)
        }
        return .invalid("""
            Paste a server address (like http://localhost:11434), an Ollama \
            model (like --model kimi-k3.1-pro:cloud, or qwen3:8b), or a \
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

    // MARK: Embeddings and downloads (Ollama)

    /// The Ollama server embeddings are asked of: the added endpoint on
    /// Ollama's port (on the headset, the Mac's .local address), else
    /// this machine's own.
    var ollamaBase: String {
        endpoints.first { $0.base.hasSuffix(":11434") }?.base ?? "http://localhost:11434"
    }

    /// The passages as vectors, by the chosen embedding model, in order.
    /// There is no fallback: vectors from two models cannot be compared,
    /// so a corpus is embedded by one model or not at all — a missing
    /// model or server is the caller's to report.
    func embed(_ texts: [String]) async throws -> (vectors: [[Float]], modelName: String) {
        #if os(macOS) && canImport(MLXLLM) && canImport(MLXEmbedders) && canImport(MLXHuggingFace)
        if let choice = selectedLocalChoice {
            return (try await LocalModels.shared.embed(choice, texts), choice.embedRepo)
        }
        #endif
        let model = embeddingModel
        let vectors = try await OllamaClient.embed(base: ollamaBase, model: model,
                                                   inputs: texts, key: apiKey(for: ollamaBase))
        return (vectors, model)
    }

    /// Whether the chosen embedding model stands on the server.
    func hasEmbeddingModel() async -> Bool {
        #if os(macOS)
        if selectedLocalChoice != nil { return true }
        #endif
        return await OllamaClient.installedModels(base: ollamaBase, key: apiKey(for: ollamaBase))
            .contains { OllamaClient.sameModel($0, embeddingModel) }
    }

    /// Downloads a model onto the Ollama server, its progress in
    /// `download` — Ollama's own pull, so nothing is typed in Terminal.
    func downloadModel(_ model: String) {
        guard download == nil || download?.failure != nil else { return }
        download = ModelDownload(model: model, status: "Starting\u{2026}")
        let base = ollamaBase
        let key = apiKey(for: base)
        Task { @MainActor in
            do {
                try await OllamaClient.pull(base: base, model: model, key: key) { status, fraction in
                    self.download = ModelDownload(model: model, status: status, fraction: fraction)
                }
                download = nil
                await refreshModels(for: base)
            } catch {
                download = ModelDownload(model: model, status: "", failure: error.localizedDescription)
            }
        }
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
    /// the text grow. Cancellation cancels the transport. With
    /// `jsonSchema`, the server is asked to constrain its answer to it
    /// (`response_format: json_schema`); a server that rejects the field
    /// is asked once more without it, the schema still being in the
    /// instructions.
    static func respond(base: String, model: String, key: String?,
                        instructions: String?, prompt: String,
                        jsonSchema: (name: String, schema: [String: Any])? = nil,
                        temperature: Double? = nil,
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
        var body: [String: Any] = ["model": model, "messages": messages, "stream": true]
        if let temperature { body["temperature"] = temperature }
        if let jsonSchema {
            body["response_format"] = [
                "type": "json_schema",
                "json_schema": ["name": jsonSchema.name, "schema": jsonSchema.schema],
            ] as [String: Any]
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let host = URL(string: base)?.host() ?? base
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 || status == 403 { throw OrigamiLLMError.authRequired(host) }
            if status == 404 { throw OrigamiLLMError.modelNotFound(model) }
            if status == 400 || status == 422, jsonSchema != nil {
                return try await respond(base: base, model: model, key: key,
                                         instructions: instructions, prompt: prompt,
                                         jsonSchema: nil, temperature: temperature,
                                         onPartial: onPartial)
            }
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
    /// An Ollama model being added from the paste box.
    @State private var addingModel: String?
    /// A cloud model awaiting the §11 confirmation.
    @State private var pendingCloudModel: String?

    var body: some View {
        // The one choice most readers need: a model Origami runs itself.
        #if os(macOS) && canImport(MLXLLM) && canImport(MLXEmbedders) && canImport(MLXHuggingFace)
        LocalModelsSettingsSection()
        #endif
        #if !os(macOS)
        // The Mac answering for this device (9 Nov 2026): found through the
        // community folder, asked after a chosen server, before Apple's.
        Section {
            if let host = llm.macHost {
                LabeledContent("Your Mac") {
                    Text("\(host.macName) \u{00B7} \(host.model)")
                        .foregroundStyle(.secondary)
                }
                Text(llm.selectedEndpointModel() == nil
                     ? "Answering for this device."
                     : "Answering whenever the server chosen below cannot.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("No Mac is serving its AI yet. On the Mac, turn on Settings \u{25B8} AI \u{25B8} Serve AI to Vision Pro; this device finds it through the community folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("AI from Your Mac")
        }
        #endif

        Section {
            Picker("Choose Model", selection: Binding(
                get: { llm.selectedID },
                set: { llm.selectedID = $0 })) {
                #if os(macOS) && canImport(MLXLLM) && canImport(MLXEmbedders) && canImport(MLXHuggingFace)
                ForEach(LocalModelChoice.ladder.filter { LocalModels.shared.isReady($0) }) { choice in
                    Text("\(choice.modelName) \u{2014} in Origami").tag(OrigamiLLM.localID(choice))
                }
                #endif
                Text("Apple\u{2019}s built-in \u{2014} on \(OrigamiLLM.thisDevice)").tag("apple")
                ForEach(llm.endpoints) { endpoint in
                    // A model that only measures meaning cannot answer:
                    // it is the Embedding Model's, not the picker's.
                    ForEach(endpoint.models.filter { !OrigamiLLM.isEmbeddingOnly($0) }, id: \.self) { model in
                        Text("\(endpoint.hostLabel) \u{00B7} \(model)")
                            .tag(OrigamiLLM.endpointID(base: endpoint.base, model: model))
                    }
                }
            }
        } header: {
            Text("Model in Use")
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

        EmbeddingModelSettingsSection()

        #if os(macOS)
        LibraryUpkeepSettingsSection()
        #endif

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
                TextField("A server address, or a model such as --model kimi-k3.1-pro:cloud",
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
            if let pendingCloudModel {
                Text("\(pendingCloudModel) runs on Ollama\u{2019}s servers, not on \(OrigamiLLM.thisDevice): the text it reads will be sent to Ollama.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Button("Add Anyway") {
                    let name = pendingCloudModel
                    self.pendingCloudModel = nil
                    Task { @MainActor in await addModel(name) }
                }
            }
            if let addingModel {
                HStack(spacing: 8) {
                    if let fraction = llm.download?.fraction {
                        ProgressView(value: fraction).frame(width: 120)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text("\(addingModel): \(llm.download?.status.isEmpty == false ? llm.download!.status : "asking Ollama\u{2026}")")
                        .foregroundStyle(.secondary)
                }
            } else if isClassifying {
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
                Paste an Ollama model \u{2014} \u{201C}--model kimi-k3.1-pro:cloud\u{201D}, \
                \u{201C}ollama run qwen3:8b\u{201D}, or just its name \u{2014} and it is \
                fetched through Ollama and chosen. A :cloud model runs on \
                Ollama\u{2019}s servers and needs you signed in to Ollama.
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
        pendingCloudModel = nil
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
            case .ollamaModel(let name):
                // §11: a cloud model reads on Ollama's servers — said, and
                // asked, before it is added.
                if OrigamiLLM.isCloudModel(name) {
                    pendingCloudModel = name
                } else {
                    await addModel(name)
                }
            case .invalid(let message):
                status = message
            }
        }
    }

    /// Fetched through Ollama and made the model in use; the pull's
    /// progress shows beneath the box meanwhile.
    private func addModel(_ name: String) async {
        addingModel = name
        do {
            try await llm.addOllamaModel(name)
            status = "Added \(name), now the model in use."
            pasted = ""
        } catch {
            status = error.localizedDescription
        }
        addingModel = nil
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

// MARK: - Ollama's own wire: downloads and embeddings

/// What the chat-completions dialect does not cover, in Ollama's own
/// API: the models on the server (/api/tags), a download (/api/pull,
/// streamed as lines of JSON), and embeddings (/api/embed).
nonisolated enum OllamaClient {
    /// "qwen3-embedding:8b" and "qwen3-embedding:8b" — or a bare name and
    /// its ":latest" — are one model.
    static func sameModel(_ a: String, _ b: String) -> Bool {
        func full(_ name: String) -> String { name.contains(":") ? name : name + ":latest" }
        return full(a) == full(b)
    }

    static func installedModels(base: String, key: String?) async -> [String] {
        guard let url = URL(string: base + "/api/tags") else { return [] }
        var request = URLRequest(url: url, timeoutInterval: 3)
        if let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["models"] as? [[String: Any]] else { return [] }
        return list.compactMap { $0["name"] as? String }
    }

    /// Pulls a model, reporting each status line and, while layers come
    /// down, the fraction done.
    static func pull(base: String, model: String, key: String?,
                     progress: @escaping @MainActor (String, Double?) -> Void) async throws {
        let host = URL(string: base)?.host() ?? base
        guard let url = URL(string: base + "/api/pull") else { throw OrigamiLLMError.serverUnreachable(host) }
        var request = URLRequest(url: url, timeoutInterval: 3600)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "stream": true])
        let bytes: URLSession.AsyncBytes
        do {
            let (stream, response) = try await URLSession.shared.bytes(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw OrigamiLLMError.generationFailed("\(host) would not download \(model).")
            }
            bytes = stream
        } catch let error as OrigamiLLMError {
            throw error
        } catch {
            throw OrigamiLLMError.serverUnreachable(host)
        }
        var lastReport = Date.distantPast
        for try await line in bytes.lines {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            else { continue }
            if let failure = object["error"] as? String {
                throw OrigamiLLMError.generationFailed(failure)
            }
            let status = object["status"] as? String ?? ""
            var fraction: Double?
            if let total = (object["total"] as? NSNumber)?.doubleValue, total > 0,
               let completed = (object["completed"] as? NSNumber)?.doubleValue {
                fraction = completed / total
            }
            // A line per chunk is far more than a progress bar needs.
            if status == "success" || Date().timeIntervalSince(lastReport) > 0.25 {
                lastReport = Date()
                await progress(status, fraction)
            }
        }
    }

    /// Embeds the inputs, in batches, keeping their order.
    static func embed(base: String, model: String, inputs: [String], key: String?,
                      batch: Int = 16) async throws -> [[Float]] {
        let host = URL(string: base)?.host() ?? base
        guard let url = URL(string: base + "/api/embed") else { throw OrigamiLLMError.serverUnreachable(host) }
        var vectors: [[Float]] = []
        var start = 0
        while start < inputs.count {
            try Task.checkCancellation()
            let slice = Array(inputs[start..<min(start + batch, inputs.count)])
            var request = URLRequest(url: url, timeoutInterval: 600)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "input": slice])
            let data: Data
            let status: Int
            do {
                let (body, response) = try await URLSession.shared.data(for: request)
                data = body
                status = (response as? HTTPURLResponse)?.statusCode ?? 0
            } catch {
                throw OrigamiLLMError.serverUnreachable(host)
            }
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            if status == 404 || ((object?["error"] as? String) ?? "").contains("not found") {
                throw OrigamiLLMError.modelNotFound(model)
            }
            guard status == 200, let rows = object?["embeddings"] as? [[NSNumber]], rows.count == slice.count else {
                throw OrigamiLLMError.generationFailed(object?["error"] as? String
                                                       ?? "\(host) returned no embeddings.")
            }
            vectors += rows.map { $0.map(\.floatValue) }
            start += slice.count
        }
        return vectors
    }
}

// MARK: - Embedding models (researched November 2026)

/// The embedding models offered in Settings ▸ AI, best first. All run on
/// Ollama; the suggestion follows this machine's memory.
nonisolated struct EmbeddingModelChoice: Identifiable, Hashable {
    let id: String
    let name: String
    let summary: String
    let downloadGB: Double
    let minRAMGB: Int
}

nonisolated enum EmbeddingModelCatalog {
    static let all: [EmbeddingModelChoice] = [
        EmbeddingModelChoice(
            id: "qwen3-embedding:8b", name: "Qwen3 Embedding 8B",
            summary: "Among the strongest open embedding models, in any language; reads a whole article (32K tokens) at once",
            downloadGB: 4.7, minRAMGB: 32),
        EmbeddingModelChoice(
            id: "qwen3-embedding:4b", name: "Qwen3 Embedding 4B",
            summary: "Nearly as good, half the size; the same long reach",
            downloadGB: 2.5, minRAMGB: 16),
        EmbeddingModelChoice(
            id: "qwen3-embedding:0.6b", name: "Qwen3 Embedding 0.6B",
            summary: "Small and quick, for any Mac",
            downloadGB: 0.6, minRAMGB: 8),
        EmbeddingModelChoice(
            id: "nomic-embed-text", name: "Nomic Embed Text",
            summary: "A long-standing small model, English first; a fallback when the Qwen models will not load",
            downloadGB: 0.3, minRAMGB: 8),
    ]

    /// The best model this machine's memory holds. On the headset the
    /// models run on the Mac, so the best is suggested there.
    static var suggested: EmbeddingModelChoice {
        #if os(macOS)
        let ram = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
        return all.first { $0.minRAMGB <= ram } ?? all[2]
        #else
        return all[0]
        #endif
    }
}

/// Settings ▸ AI's embedding section: which model measures likeness, whether
/// it is on the Ollama server, and a Download button that fetches it there.
struct EmbeddingModelSettingsSection: View {
    @State private var llm = OrigamiLLM.shared
    @State private var installed: [String] = []
    @State private var checked = false

    private func isInstalled(_ id: String) -> Bool {
        installed.contains { OllamaClient.sameModel($0, id) }
    }

    var body: some View {
        Section {
            Picker("Embedding Model", selection: Binding(
                get: { llm.embeddingModel },
                set: { llm.embeddingModel = $0 })) {
                ForEach(EmbeddingModelCatalog.all) { choice in
                    Text(choice.name + (isInstalled(choice.id) ? "" : " \u{2014} not downloaded"))
                        .tag(choice.id)
                }
                // A model chosen elsewhere keeps its place in the list.
                if !EmbeddingModelCatalog.all.contains(where: { $0.id == llm.embeddingModel }) {
                    Text(llm.embeddingModel).tag(llm.embeddingModel)
                }
            }
            if let choice = EmbeddingModelCatalog.all.first(where: { $0.id == llm.embeddingModel }) {
                Text("\(choice.summary). \(String(format: "%.1f", choice.downloadGB)) GB download; suits \(choice.minRAMGB) GB of memory or more.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                if let download = llm.download {
                    if let failure = download.failure {
                        Label(failure, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    } else {
                        ProgressView(value: download.fraction ?? 0) {
                            Text("Downloading \(download.model): \(download.status)")
                                .font(.caption)
                        }
                    }
                } else if isInstalled(llm.embeddingModel) {
                    Label("On \(URL(string: llm.ollamaBase)?.host() ?? llm.ollamaBase), ready", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                } else if checked {
                    Text(installed.isEmpty
                         ? "Ollama is not answering at \(llm.ollamaBase). Install it from ollama.com and open it, then download here."
                         : "Not on the Ollama server yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(llm.download?.failure != nil ? "Try Again" : "Download") {
                    llm.downloadModel(llm.embeddingModel)
                }
                .disabled(isInstalled(llm.embeddingModel)
                          || (llm.download != nil && llm.download?.failure == nil))
            }
        } header: {
            Text("Embedding Model")
        } footer: {
            Text("""
                Similar articles and Themes measure how near two pieces of \
                writing stand by turning each into numbers. That runs in \
                Ollama, on \(llm.ollamaBase.contains("localhost") ? OrigamiLLM.thisDevice : URL(string: llm.ollamaBase)?.host() ?? "the server") \
                \u{2014} no text leaves it. Download fetches the model into Ollama for you.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task(id: llm.download) {
            guard llm.download == nil else { return }
            installed = await OllamaClient.installedModels(base: llm.ollamaBase,
                                                           key: llm.apiKey(for: llm.ollamaBase))
            checked = true
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
