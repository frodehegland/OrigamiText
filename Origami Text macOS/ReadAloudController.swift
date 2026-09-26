import Foundation
import AppKit
import Observation

/// Manages the active TTS engine, tracks the currently-spoken paragraph,
/// and drives the spacebar toggle. Create one per reading session and
/// keep it in @State inside OrigamiReadingView.
@Observable
@MainActor
final class ReadAloudController {

    // MARK: - Observable state

    /// True while the engine is producing audio (not paused, not stopped).
    var isPlaying = false
    /// True while playback is paused (engine holds position).
    var isPaused = false
    /// The `LiquidDoc.Paragraph.id` currently being spoken; drives highlight.
    var activeBlockID: String? = nil
    /// Non-nil while a fallback from Qwen3 → Apple is in progress.
    var fallbackBanner: String? = nil

    // MARK: - Engine selection (mirrors AppStorage in the settings view)

    private var engineID: String {
        UserDefaults.standard.string(forKey: AppSettings.readAloudEngineKey) ?? "apple"
    }

    // MARK: - Private

    private let appleEngine = AppleSpeechEngine()
    #if arch(arm64)
    private let qwen3Engine = Qwen3SpeechEngine()
    #endif
    private var eventTask: Task<Void, Never>?
    private var pendingUnits: [SpeechUnit] = []
    private var pendingOptions: SpeechOptions = .default

    private var preferredEngine: any SpeechEngine {
        #if arch(arm64)
        if engineID == "qwen3" { return qwen3Engine }
        #endif
        return appleEngine
    }

    // MARK: - Text extraction

    /// Build the speech queue from a LiquidDoc.
    ///
    /// - `currentSections`: nil → whole document, non-nil → just those sections
    ///   (used for focus/horizontal modes that display one page at a time).
    /// - `selection`: if non-empty, wrap it as a single unit and read only that.
    func makeUnits(from doc: LiquidDoc,
                   currentSections: [OrigamiSection]? = nil,
                   selection: String? = nil) -> [SpeechUnit] {
        if let sel = selection?.trimmingCharacters(in: .whitespacesAndNewlines), !sel.isEmpty {
            return [SpeechUnit(blockID: "selection", text: sel, kind: .paragraph)]
        }
        let sections = currentSections ?? OrigamiSection.build(from: doc)
        var units: [SpeechUnit] = []
        for section in sections {
            if let h = section.heading, !h.text.isEmpty {
                units.append(SpeechUnit(blockID: h.id, text: h.text, kind: .heading))
            }
            for para in section.paragraphs {
                let t = para.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty, t != "---" else { continue }
                units.append(SpeechUnit(blockID: para.id, text: t, kind: .paragraph))
            }
        }
        return units
    }

    /// Returns the selected text from the current key NSTextView, if any.
    func selectedText() -> String? {
        guard let tv = NSApp.keyWindow?.firstResponder as? NSTextView,
              !tv.isEditable,
              tv.selectedRange().length > 0 else { return nil }
        return (tv.string as NSString).substring(with: tv.selectedRange())
    }

    // MARK: - Playback

    func startReading(_ units: [SpeechUnit], options: SpeechOptions = .default) {
        guard !units.isEmpty else { return }
        pendingUnits = units
        pendingOptions = options
        fallbackBanner = nil

        // Cancel existing session synchronously — speak() also stops the
        // synthesiser synchronously, so no deferred task can race.
        eventTask?.cancel()
        eventTask = nil
        isPlaying = false
        isPaused = false
        activeBlockID = nil

        startStream(using: preferredEngine, units: units, options: options)
    }

    private func startStream(using engine: any SpeechEngine,
                              units: [SpeechUnit],
                              options: SpeechOptions) {
        let stream = engine.speak(units, options: options)
        isPlaying = true
        isPaused = false

        eventTask = Task { [weak self] in
            guard let self else { return }
            var didFail = false
            for await event in stream {
                switch event {
                case .started(let uid):
                    self.activeBlockID = units.first(where: { $0.id == uid })?.blockID
                case .finished:
                    break
                case .ended:
                    self.isPlaying = false
                    self.isPaused = false
                    self.activeBlockID = nil
                case .failed(let msg):
                    NSLog("ReadAloud engine failed (%@): %@",
                          engine.displayName, msg)
                    didFail = true
                    // Fall back to Apple TTS if the preferred engine failed.
                    if !(engine is AppleSpeechEngine) {
                        self.fallbackBanner = "Neural voice unavailable — using Apple voice"
                        self.startStream(using: self.appleEngine,
                                         units: units, options: options)
                    } else {
                        self.isPlaying = false
                        self.isPaused = false
                        self.activeBlockID = nil
                    }
                    return
                default:
                    break
                }
            }
            if !didFail {
                self.isPlaying = false
                self.isPaused = false
                self.activeBlockID = nil
            }
        }
    }

    /// Pause if playing, resume if paused.
    func togglePlayPause() {
        guard isPlaying || isPaused else { return }
        let engine = preferredEngine
        if isPaused {
            Task { await engine.resume() }
            isPaused = false
            isPlaying = true
        } else {
            Task { await engine.pause() }
            isPaused = true
            isPlaying = false
        }
    }

    func stopReading() {
        eventTask?.cancel()
        eventTask = nil
        appleEngine.stopSync()
        #if arch(arm64)
        Task { await qwen3Engine.stop() }
        #endif
        isPlaying = false
        isPaused = false
        activeBlockID = nil
        fallbackBanner = nil
    }
}
