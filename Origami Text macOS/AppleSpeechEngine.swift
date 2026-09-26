import AVFoundation
import NaturalLanguage
import AppKit

/// Text-to-speech using AVSpeechSynthesizer — the system voices built into macOS.
/// Works on every Mac with no download.
@MainActor
final class AppleSpeechEngine: NSObject, SpeechEngine {
    let id = "apple"
    let displayName = "Apple Voice"
    static var isSupported: Bool { true }

    private let synth = AVSpeechSynthesizer()
    private var continuation: AsyncStream<SpeechEvent>.Continuation?

    // Maps each AVSpeechUtterance → the SpeechUnit.id it belongs to
    private var utteranceUnit: [ObjectIdentifier: UUID] = [:]
    // Whether this utterance is the first sentence in its unit (triggers .started)
    private var utteranceIsFirst: [ObjectIdentifier: Bool] = [:]
    // The identity of the last utterance in each unit (triggers .finished)
    private var lastUtteranceOfUnit: [UUID: ObjectIdentifier] = [:]
    private var scheduledCount = 0
    private var completedCount = 0

    override init() {
        super.init()
        synth.delegate = self
    }

    var isReady: Bool { get async { true } }
    func prepare() async throws {}

    func speak(_ units: [SpeechUnit], options: SpeechOptions) -> AsyncStream<SpeechEvent> {
        // Stop any in-flight speech and close the previous stream synchronously
        // so no deferred task can cancel utterances we're about to schedule.
        synth.stopSpeaking(at: .immediate)
        continuation?.finish()
        continuation = nil
        utteranceUnit.removeAll()
        utteranceIsFirst.removeAll()
        lastUtteranceOfUnit.removeAll()
        scheduledCount = 0
        completedCount = 0

        return AsyncStream { [weak self] cont in
            guard let self else { cont.finish(); return }
            self.continuation = cont

            let voice: AVSpeechSynthesisVoice? = options.voiceID.isEmpty
                ? nil
                : AVSpeechSynthesisVoice(identifier: options.voiceID)
            let rate = AVSpeechUtteranceDefaultSpeechRate * options.rate

            for unit in units {
                let sentences = Self.sentences(from: unit.text)
                var isFirst = true
                var lastOID: ObjectIdentifier?

                for sentence in sentences {
                    let utt = AVSpeechUtterance(string: sentence)
                    utt.rate = rate
                    utt.voice = voice
                    if unit.kind == .heading { utt.postUtteranceDelay = 0.25 }

                    let oid = ObjectIdentifier(utt)
                    self.utteranceUnit[oid] = unit.id
                    self.utteranceIsFirst[oid] = isFirst
                    isFirst = false
                    lastOID = oid
                    self.scheduledCount += 1
                    self.synth.speak(utt)
                }
                if let last = lastOID {
                    self.lastUtteranceOfUnit[unit.id] = last
                }
            }
        }
    }

    func pause() async { synth.pauseSpeaking(at: .word) }
    func resume() async { synth.continueSpeaking() }

    func stop() async { stopSync() }

    /// Synchronous stop — safe to call without awaiting, avoids task-scheduling races.
    func stopSync() {
        synth.stopSpeaking(at: .immediate)
        continuation?.finish()
        continuation = nil
    }

    // MARK: - Helpers

    static func availableVoices(language: String = "en") -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(language) }
            .sorted { $0.name < $1.name }
    }

    private static func sentences(from text: String) -> [String] {
        var result: [String] = []
        let tok = NLTokenizer(unit: .sentence)
        tok.string = text
        tok.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let s = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { result.append(s) }
            return true
        }
        return result.isEmpty ? [text] : result
    }
}

// MARK: - Delegate

extension AppleSpeechEngine: @preconcurrency AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didStart utterance: AVSpeechUtterance) {
        let oid = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self,
                  let uid = utteranceUnit[oid],
                  utteranceIsFirst[oid] == true else { return }
            continuation?.yield(.started(uid))
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       willSpeakRangeOfSpeechString range: NSRange,
                                       utterance: AVSpeechUtterance) {
        let oid = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self, let uid = utteranceUnit[oid] else { return }
            continuation?.yield(.wordRange(uid, range))
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        let oid = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let uid = utteranceUnit[oid], lastUtteranceOfUnit[uid] == oid {
                continuation?.yield(.finished(uid))
            }
            completedCount += 1
            if completedCount >= scheduledCount {
                continuation?.yield(.ended)
                continuation?.finish()
                continuation = nil
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            completedCount += 1
            if completedCount >= scheduledCount {
                // Emit .ended so the controller resets isPlaying correctly.
                continuation?.yield(.ended)
                continuation?.finish()
                continuation = nil
            }
        }
    }
}
