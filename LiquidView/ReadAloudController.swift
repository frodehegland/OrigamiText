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

    // MARK: - Private

    private let appleEngine = AppleSpeechEngine()
    private var eventTask: Task<Void, Never>?

    private var activeEngine: any SpeechEngine { appleEngine }

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
        // Cancel the old event loop synchronously — speak() will stop the
        // synthesiser and close the old continuation synchronously too,
        // so no deferred task can race and kill the new utterances.
        eventTask?.cancel()
        eventTask = nil
        isPlaying = false
        isPaused = false
        activeBlockID = nil

        let stream = activeEngine.speak(units, options: options)
        isPlaying = true
        isPaused = false

        eventTask = Task {
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
                    self.isPlaying = false
                    self.isPaused = false
                    self.activeBlockID = nil
                    NSLog("ReadAloud error: %@", msg)
                default:
                    break
                }
            }
        }
    }

    /// Pause if playing, resume if paused.
    func togglePlayPause() {
        guard isPlaying || isPaused else { return }
        if isPaused {
            Task { await activeEngine.resume() }
            isPaused = false
            isPlaying = true
        } else {
            Task { await activeEngine.pause() }
            isPaused = true
            isPlaying = false
        }
    }

    func stopReading() {
        eventTask?.cancel()
        eventTask = nil
        appleEngine.stopSync()
        isPlaying = false
        isPaused = false
        activeBlockID = nil
    }
}
