// AI on this Mac (2 Nov 2026): models that run inside Origami itself, on
// Apple's MLX — no Ollama, no LM Studio, nothing to install or keep
// running. Three choices sized to the Mac's memory; one press downloads
// the pair (a model that writes, and one that measures meaning) from
// Hugging Face, and from then on every AI feature uses them: reading,
// summaries, Ask, abstracts, relations. Frode's wish: one button, and
// that's that.
//
// macOS only, and only where the MLX packages are linked (mlx-swift-lm's
// MLXLLM, MLXLMCommon, MLXEmbedders, MLXHuggingFace; swift-transformers'
// Tokenizers; swift-huggingface).
#if os(macOS)
import Foundation
import Observation

/// One rung of the ladder: a model that writes and a model that embeds,
/// downloaded and used together.
nonisolated struct LocalModelChoice: Identifiable, Hashable, Sendable {
    let id: String
    let chatRepo: String
    let embedRepo: String
    /// What the reader sees: "Qwen 3.5, 35B (3B active)".
    let modelName: String
    /// Both models together, as Hugging Face lists their weights.
    let downloadGB: Double
    /// The memory a Mac needs to run it comfortably beside everything else.
    let minRAMGB: Int
    let summary: String

    /// From smallest to largest. Each Mac is offered the three largest it
    /// can run; the Qwen 3.5 family throughout, so a step up or down keeps
    /// the same manner of answering.
    static let ladder: [LocalModelChoice] = [
        .init(id: "qwen3.5-0.8b", chatRepo: "mlx-community/Qwen3.5-0.8B-4bit",
              embedRepo: "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ",
              modelName: "Qwen 3.5, 0.8B", downloadGB: 1.0, minRAMGB: 4,
              summary: "Quick and small; short answers, plain summaries"),
        .init(id: "qwen3.5-4b", chatRepo: "mlx-community/Qwen3.5-4B-MLX-4bit",
              embedRepo: "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ",
              modelName: "Qwen 3.5, 4B", downloadGB: 3.3, minRAMGB: 8,
              summary: "Light on memory; good summaries and keywords"),
        .init(id: "qwen3.5-9b", chatRepo: "mlx-community/Qwen3.5-9B-MLX-4bit",
              embedRepo: "mlx-community/Qwen3-Embedding-4B-4bit-DWQ",
              modelName: "Qwen 3.5, 9B", downloadGB: 8.3, minRAMGB: 16,
              summary: "Careful reading at a steady pace"),
        .init(id: "qwen3.5-35b-a3b", chatRepo: "mlx-community/Qwen3.5-35B-A3B-4bit",
              embedRepo: "mlx-community/Qwen3-Embedding-4B-4bit-DWQ",
              modelName: "Qwen 3.5, 35B (3B active)", downloadGB: 22.7, minRAMGB: 32,
              summary: "Strong and fast: only 3B of its 35B work on each word"),
        .init(id: "qwen3.5-122b-a10b", chatRepo: "mlx-community/Qwen3.5-122B-A10B-4bit",
              embedRepo: "mlx-community/Qwen3-Embedding-8B-4bit-DWQ",
              modelName: "Qwen 3.5, 122B (10B active)", downloadGB: 73.9, minRAMGB: 96,
              summary: "The best this Mac can run: deep reading, careful argument"),
    ]

    /// This Mac's memory, in GB.
    static var macRAMGB: Int {
        Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
    }

    /// The three this Mac is offered: Light, Balanced, Best.
    static var offered: [LocalModelChoice] {
        let fitting = ladder.filter { $0.minRAMGB <= macRAMGB }
        return Array(fitting.suffix(3))
    }

    /// Light, Balanced or Best, by place among the three offered.
    var tier: String {
        let offered = Self.offered
        guard let index = offered.firstIndex(of: self) else { return "" }
        if offered.count < 3 { return index == offered.count - 1 ? "Best" : "Light" }
        return ["Light", "Balanced", "Best"][index]
    }
}

#if canImport(MLXLLM) && canImport(MLXLMCommon) && canImport(MLXEmbedders) && canImport(MLXHuggingFace) && canImport(Tokenizers) && canImport(HuggingFace)
import HuggingFace
import MLX
import MLXEmbedders
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// The models Origami runs itself: which pairs are on this Mac, the one
/// downloading, and the loaded models (kept while in use, let go when the
/// Mac has gone ten minutes without asking, so 70 GB is not held for
/// nothing).
@MainActor @Observable
final class LocalModels {
    static let shared = LocalModels()

    /// The pairs fully downloaded, by choice id.
    private(set) var ready: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: LocalModels.readyKey) ?? [])
    private static let readyKey = "localModelsReady"

    struct Download: Equatable {
        var choiceID: String
        var fraction: Double
        var status: String
        var failure: String?
    }
    private(set) var download: Download?

    private var downloadTask: Task<Void, Never>?
    @ObservationIgnored private var chat: (repo: String, container: ModelContainer)?
    @ObservationIgnored private var embedder: (repo: String, container: EmbedderModelContainer)?
    @ObservationIgnored private var lastUse = Date.distantPast
    @ObservationIgnored private var releaseTask: Task<Void, Never>?

    private static let patterns = ["*.safetensors", "*.json", "*.jinja", "*.txt", "*.model"]

    private nonisolated static var downloader: any Downloader { #hubDownloader() }
    private nonisolated static var tokenizerLoader: any TokenizerLoader { #huggingFaceTokenizerLoader() }

    func isReady(_ choice: LocalModelChoice) -> Bool { ready.contains(choice.id) }

    // MARK: Downloading

    /// Downloads a pair — the embedding model first (small), then the
    /// model that writes — and, once both are in, makes it the one used.
    func download(_ choice: LocalModelChoice, thenUse use: @escaping @MainActor () -> Void) {
        guard download == nil || download?.failure != nil else { return }
        download = Download(choiceID: choice.id, fraction: 0, status: "Starting\u{2026}")
        downloadTask = Task {
            do {
                let embedShare = 0.04
                download?.status = "Downloading the meaning model\u{2026}"
                _ = try await Self.downloader.download(
                    id: choice.embedRepo, revision: nil, matching: Self.patterns, useLatest: false
                ) { progress in
                    Task { @MainActor in
                        self.download?.fraction = progress.fractionCompleted * embedShare
                    }
                }
                download?.status = "Downloading \(choice.modelName) (\(String(format: "%.0f", choice.downloadGB)) GB)\u{2026}"
                _ = try await Self.downloader.download(
                    id: choice.chatRepo, revision: nil, matching: Self.patterns, useLatest: false
                ) { progress in
                    Task { @MainActor in
                        self.download?.fraction = embedShare + progress.fractionCompleted * (1 - embedShare)
                    }
                }
                ready.insert(choice.id)
                UserDefaults.standard.set(Array(ready), forKey: Self.readyKey)
                download = nil
                use()
            } catch is CancellationError {
                download = nil
            } catch {
                download?.failure = "The download stopped: \(error.localizedDescription) Press again to carry on where it left off."
            }
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
        download = nil
    }

    // MARK: Writing

    /// The chosen pair's model answers — streamed to `onPartial` as the
    /// words come. Qwen 3.5's thinking aloud is turned off, and any that
    /// slips through is cut, so the reader sees the answer alone.
    func respond(_ choice: LocalModelChoice, instructions: String?, prompt: String,
                 temperature: Float? = nil,
                 onPartial: (@MainActor (String) -> Void)?) async throws -> String {
        let container = try await chatContainer(choice)
        let session = ChatSession(
            container, instructions: instructions,
            generateParameters: GenerateParameters(maxTokens: 4096, temperature: temperature ?? 0.6, topP: 0.95),
            additionalContext: ["enable_thinking": false])
        var text = ""
        for try await chunk in session.streamResponse(to: prompt) {
            text += chunk
            if let onPartial { onPartial(Self.answer(in: text)) }
        }
        touch()
        return Self.answer(in: text)
    }

    /// The reply without any <think>…</think> passage.
    nonisolated static func answer(in text: String) -> String {
        var out = text
        if let end = out.range(of: "</think>") {
            out = String(out[end.upperBound...])
        } else if out.contains("<think>") {
            return ""
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Measuring meaning

    /// Each text as a unit vector, one at a time (no padding to get
    /// wrong), by the pair's embedding model.
    func embed(_ choice: LocalModelChoice, _ texts: [String]) async throws -> [[Float]] {
        let container = try await embedderContainer(choice)
        let vectors = try await container.perform { context -> [[Float]] in
            var out: [[Float]] = []
            for text in texts {
                try Task.checkCancellation()
                var tokens = context.tokenizer.encode(text: text, addSpecialTokens: true)
                if let limit = context.model.maxPositionEmbeddings, tokens.count > limit {
                    tokens = Array(tokens.prefix(limit))
                }
                let input = MLXArray(tokens).expandedDimensions(axis: 0)
                let output = context.model(input, positionIds: nil, tokenTypeIds: nil, attentionMask: nil)
                let pooled = context.pooling(output, normalize: true, applyLayerNorm: false)
                pooled.eval()
                out.append(pooled[0].asArray(Float.self))
            }
            return out
        }
        touch()
        return vectors
    }

    // MARK: Loading and letting go

    private func chatContainer(_ choice: LocalModelChoice) async throws -> ModelContainer {
        if let chat, chat.repo == choice.chatRepo { return chat.container }
        chat = nil
        let container = try await LLMModelFactory.shared.loadContainer(
            from: Self.downloader, using: Self.tokenizerLoader,
            configuration: ModelConfiguration(id: choice.chatRepo))
        chat = (choice.chatRepo, container)
        return container
    }

    private func embedderContainer(_ choice: LocalModelChoice) async throws -> EmbedderModelContainer {
        if let embedder, embedder.repo == choice.embedRepo { return embedder.container }
        embedder = nil
        let container = try await EmbedderModelFactory.shared.loadContainer(
            from: Self.downloader, using: Self.tokenizerLoader,
            configuration: ModelConfiguration(id: choice.embedRepo))
        embedder = (choice.embedRepo, container)
        return container
    }

    /// Used just now: the models stay; ten idle minutes and they go.
    private func touch() {
        lastUse = .now
        releaseTask?.cancel()
        releaseTask = Task {
            try? await Task.sleep(for: .seconds(600))
            guard !Task.isCancelled, Date.now.timeIntervalSince(lastUse) >= 590 else { return }
            chat = nil
            embedder = nil
            MLX.GPU.clearCache()
        }
    }
}

// MARK: - Settings ▸ AI ▸ AI on This Mac

import SwiftUI

/// The three choices, one press each: Use (downloaded), Download and Use,
/// or the download's progress. The one in use wears a checkmark. Every
/// other way of choosing a model stands below, under Model in Use.
struct LocalModelsSettingsSection: View {
    @State private var models = LocalModels.shared
    @State private var llm = OrigamiLLM.shared

    var body: some View {
        Section {
            ForEach(LocalModelChoice.offered) { choice in
                row(choice)
            }
            if let failure = models.download?.failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("AI on This Mac")
        } footer: {
            Text("""
                Origami runs the model itself \u{2014} nothing else to install, and no text \
                leaves this Mac. Each choice is a pair: a model that reads and writes, and \
                one that measures how near two passages are in meaning. Offered for this \
                Mac\u{2019}s \(LocalModelChoice.macRAMGB) GB of memory; downloaded once, \
                from Hugging Face.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func row(_ choice: LocalModelChoice) -> some View {
        let inUse = llm.selectedID == OrigamiLLM.localID(choice) && models.isReady(choice)
        let downloading = models.download?.choiceID == choice.id && models.download?.failure == nil
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(choice.tier).font(.headline)
                    Text(choice.modelName).foregroundStyle(.secondary)
                }
                Text("\(choice.summary). \(String(format: "%.1f", choice.downloadGB)) GB.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if downloading, let download = models.download {
                    ProgressView(value: download.fraction) {
                        Text(download.status).font(.caption)
                    }
                }
            }
            Spacer()
            if inUse {
                Label("In Use", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if downloading {
                Button("Stop") { models.cancelDownload() }
            } else if models.isReady(choice) {
                Button("Use") { llm.selectedID = OrigamiLLM.localID(choice) }
            } else {
                Button("Download and Use") {
                    models.download(choice) { llm.selectedID = OrigamiLLM.localID(choice) }
                }
                .disabled(models.download != nil && models.download?.failure == nil)
            }
        }
        .padding(.vertical, 2)
    }
}
#endif
#endif
