#if arch(arm64)
import Foundation
import Qwen3TTS
import AudioCommon

// MARK: - Hardware gate

struct Qwen3Support {
    static var isSupported: Bool {
        ProcessInfo.processInfo.physicalMemory >= 16 * 1024 * 1024 * 1024
    }
}

// MARK: - Model actor
// Runs synthesis on a background executor so the main thread is never blocked.
// Qwen3TTSModel is not thread-safe; actor isolation guarantees serial access.

private actor Qwen3ModelActor {
    private var model: Qwen3TTSModel?
    private let player = StreamingAudioPlayer()

    var isLoaded: Bool { model != nil }

    /// Load weights from disk. Synchronous inside the actor (background thread).
    func load(modelDirectory: URL, tokenizerDirectory: URL) throws {
        guard model == nil else { return }
        let m = try Qwen3TTSModel.fromLocal(
            modelDirectory: modelDirectory,
            tokenizerDirectory: tokenizerDirectory)
        model = m
        try player.start(sampleRate: 24000)
    }

    /// Stream-synthesise `text` and play it via the ring-buffer player.
    /// Splits into short chunks so each synthesis starts with a fresh KV cache,
    /// preventing RTF from degrading as context grows on long paragraphs.
    /// Resolves when the last audio sample has played out.
    func synthesizeAndPlay(text: String, language: String,
                           speaker: String?, instruct: String?) async throws {
        guard let model else { throw EngineError.notLoaded }
        player.resetGeneration()
        for textChunk in TextChunker.chunk(text) {
            try Task.checkCancellation()
            let stream = model.synthesizeStream(text: textChunk, language: language,
                                                speaker: speaker, instruct: instruct)
            for try await chunk in stream {
                try Task.checkCancellation()
                player.scheduleChunk(chunk.samples)
            }
        }
        player.markGenerationComplete()
        await player.waitForCompletion()
    }

    func stopPlayback() {
        player.fadeOutAndStop()
    }

    enum EngineError: Error { case notLoaded }
}

// MARK: - Engine

/// Neural TTS using Qwen3-TTS-0.6B via the speech-swift package.
/// Model weights are downloaded separately by VoiceInstaller.
@MainActor
final class Qwen3SpeechEngine: SpeechEngine {
    let id = "qwen3"
    let displayName = "Neural Voice (Qwen3-TTS)"
    static var isSupported: Bool { Qwen3Support.isSupported }

    private let modelActor = Qwen3ModelActor()
    private var continuation: AsyncStream<SpeechEvent>.Continuation?
    private var synthesisTask: Task<Void, Never>?

    var isReady: Bool { get async { await modelActor.isLoaded } }

    func prepare() async throws {
        let installer = VoiceInstaller.shared
        guard let modelDir = installer.modelDir,
              let tokenizerDir = installer.tokenizerDir else {
            throw PrepareError.modelNotInstalled
        }
        try await modelActor.load(
            modelDirectory: modelDir,
            tokenizerDirectory: tokenizerDir)
    }

    func speak(_ units: [SpeechUnit], options: SpeechOptions) -> AsyncStream<SpeechEvent> {
        synthesisTask?.cancel()
        synthesisTask = nil
        continuation?.finish()
        continuation = nil

        let (stream, cont) = AsyncStream<SpeechEvent>.makeStream()
        continuation = cont

        let speakerName = (UserDefaults.standard.string(forKey: "readAloud.qwen3.speaker") ?? "Ryan").lowercased()
        let instructText = UserDefaults.standard.string(forKey: "readAloud.qwen3.instruct") ?? "Speak naturally."
        synthesisTask = Task { [weak self] in
            guard let self else { cont.finish(); return }
            do {
                if !(await self.modelActor.isLoaded) {
                    try await self.prepare()
                }
                let lang = self.qwen3Language(from: options.language)
                for unit in units {
                    try Task.checkCancellation()
                    cont.yield(.started(unit.id))
                    try await self.modelActor.synthesizeAndPlay(
                        text: unit.text, language: lang,
                        speaker: speakerName, instruct: instructText)
                    try Task.checkCancellation()
                    cont.yield(.finished(unit.id))
                }
                cont.yield(.ended)
                cont.finish()
            } catch is CancellationError {
                cont.yield(.ended)
                cont.finish()
            } catch {
                cont.yield(.failed(error.localizedDescription))
                cont.finish()
            }
        }
        return stream
    }

    /// Pause stops synthesis; the stream emits .ended so the controller resets.
    /// Neural TTS cannot cheaply resume mid-word — the next spacebar press restarts.
    func pause() async {
        synthesisTask?.cancel()
        synthesisTask = nil
        continuation?.finish()
        continuation = nil
        await modelActor.stopPlayback()
    }

    /// No-op: after pause the stream has ended; the controller's state is already
    /// reset, so the next spacebar press starts fresh via startReading().
    func resume() async {}

    func stop() async {
        synthesisTask?.cancel()
        synthesisTask = nil
        continuation?.finish()
        continuation = nil
        await modelActor.stopPlayback()
    }

    private func qwen3Language(from bcp47: String) -> String {
        let map: [String: String] = [
            "de": "german", "es": "spanish", "zh": "chinese",
            "ja": "japanese", "fr": "french", "ko": "korean",
            "ru": "russian", "it": "italian", "pt": "portuguese",
        ]
        return map[String(bcp47.prefix(2))] ?? "english"
    }

    enum PrepareError: LocalizedError {
        case modelNotInstalled
        var errorDescription: String? {
            "Neural voice not installed. Open Assistive settings to download it."
        }
    }
}

#endif  // arch(arm64)
