// MARK: - Qwen3 neural speech engine
//
// To activate: add the speech-swift package in Xcode via
//   File › Add Package Dependencies
//   URL: https://github.com/soniqo/speech-swift   branch: main
// Link only Qwen3TTS and AudioCommon to the macOS target.
//
// After adding the package, read Sources/Qwen3TTS/ to get the real
// synthesize(…) and streaming signatures, then replace the stub below.
//
// The VoiceInstaller actor handles downloading the model weights independently
// of this file — those weights are ready whether or not the package is linked.

#if arch(arm64)
import Foundation

// MARK: - Hardware gate

struct Qwen3Support {
    static var isSupported: Bool {
        ProcessInfo.processInfo.physicalMemory >= 16 * 1024 * 1024 * 1024
    }
}

// MARK: - Synthesis actor (fill in after package is linked)

// actor Qwen3Synth {
//     private var model: Qwen3TTSModel?
//
//     func prepare(modelDir: URL, tokenizerDir: URL) async throws {
//         model = try Qwen3TTSModel.fromLocal(
//             modelDirectory: modelDir,
//             tokenizerDirectory: tokenizerDir)
//         // Warm-up: synthesise a short sentence and discard audio
//         _ = try await model!.synthesize("Hello.", speaker: "Ryan", language: "english")
//     }
//
//     func synthesize(_ text: String, options: SpeechOptions) async throws -> [Float] {
//         guard let model else { throw SynthError.notLoaded }
//         let speaker = options.voiceID.isEmpty ? "Ryan" : options.voiceID
//         let instruct = options.instruct
//         let lang = qwen3Language(from: options.language)
//         return try await model.synthesize(text, speaker: speaker,
//                                           instruct: instruct, language: lang)
//     }
//
//     private func qwen3Language(from bcp47: String) -> String {
//         let map = ["de": "german", "es": "spanish", "zh": "chinese",
//                    "ja": "japanese", "fr": "french", "ko": "korean",
//                    "ru": "russian", "it": "italian"]
//         let prefix = String(bcp47.prefix(2))
//         return map[prefix] ?? "english"
//     }
//
//     enum SynthError: Error { case notLoaded }
// }

// MARK: - Engine stub

/// Qwen3SpeechEngine — wired up once speech-swift is linked.
/// Until then it reports unsupported and fails gracefully.
final class Qwen3SpeechEngine: SpeechEngine {
    let id = "qwen3"
    let displayName = "Neural Voice (Qwen3-TTS)"

    static var isSupported: Bool { Qwen3Support.isSupported }

    var isReady: Bool {
        get async {
            // Will check model load status once package is integrated
            return false
        }
    }

    func prepare() async throws {
        throw EngineError.packageNotLinked
    }

    func speak(_ units: [SpeechUnit], options: SpeechOptions) -> AsyncStream<SpeechEvent> {
        AsyncStream { cont in
            cont.yield(.failed("Qwen3TTS package not linked. Add speech-swift via Xcode."))
            cont.finish()
        }
    }

    func pause() async {}
    func resume() async {}
    func stop() async {}

    enum EngineError: LocalizedError {
        case packageNotLinked
        var errorDescription: String? {
            "Add the speech-swift package to use the neural voice."
        }
    }
}

#endif  // arch(arm64)
