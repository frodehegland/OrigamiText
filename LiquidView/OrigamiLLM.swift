// Local-LLM support (spec: local-llm-support-spec.md), endpoints-first:
// Apple's on-device model is the zero-setup default, and any
// OpenAI-compatible chat-completions endpoint the user points the app
// at (Ollama, LM Studio, MLX-LM server, remote) sits beside it in one
// picker. Feature code asks OrigamiLLM to respond and never touches a
// concrete provider; a missing model falls back to Apple's with a
// notice, never a failure. In-app MLX model downloads arrive when the
// mlx-swift-examples package joins the project.
#if os(macOS)
import Foundation
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
            "The on-device model isn\u{2019}t available on this Mac."
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

    func addOrUpdateEndpoint(base: String, models: [String], key: String?) {
        let base = ChatCompletionsClient.normalizedBase(base)
        var entry = endpoints.first { $0.base == base }
            ?? OrigamiEndpoint(base: base)
        entry.models = models
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
        addOrUpdateEndpoint(base: base, models: models, key: nil)
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

    var body: some View {
        Section {
            Picker("Model", selection: Binding(
                get: { llm.selectedID },
                set: { llm.selectedID = $0 })) {
                Text("Apple\u{2019}s built-in \u{2014} on this Mac").tag("apple")
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
                Apple\u{2019}s built-in model runs on this Mac \u{2014} no text \
                leaves it. A server model sends the text it reads to that \
                server. The reading\u{2019}s AI (Summary, Proposals, Issues, and \
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
                TextField("A server address, or a Hugging Face model id",
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
                Text("\(pendingRemote.base) is not on this Mac: document text will be sent to that server.")
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
        } header: {
            Text("Add a Model or Server")
        } footer: {
            Text("""
                Ollama and LM Studio are found automatically while they run. \
                Model downloads inside the app arrive with the MLX runtime; \
                until then a Hugging Face id is remembered but not fetched.
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
#endif
