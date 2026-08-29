import Foundation

// MARK: - Protocol

/// Contract every text-to-speech engine must satisfy.
protocol SpeechEngine: AnyObject {
    var id: String { get }
    var displayName: String { get }
    static var isSupported: Bool { get }
    var isReady: Bool { get async }
    func prepare() async throws
    func speak(_ units: [SpeechUnit], options: SpeechOptions) -> AsyncStream<SpeechEvent>
    func pause() async
    func resume() async
    func stop() async
}

// MARK: - Domain types

struct SpeechUnit: Identifiable, Sendable {
    let id: UUID
    /// The paragraph or heading `LiquidDoc.Paragraph.id` this text came from.
    let blockID: String
    let text: String
    let kind: Kind

    enum Kind: Sendable {
        case heading, paragraph, listItem, other
    }

    init(blockID: String, text: String, kind: Kind = .paragraph) {
        self.id = UUID()
        self.blockID = blockID
        self.text = text
        self.kind = kind
    }
}

struct SpeechOptions: Sendable {
    /// Playback speed multiplier (1.0 = normal).
    var rate: Float = 1.0
    /// Apple voice identifier, or empty for the system default.
    var voiceID: String = ""
    /// Qwen3-TTS instruct string; unused by AppleSpeechEngine.
    var instruct: String? = nil
    /// BCP-47 language tag passed to Qwen3 engine.
    var language: String = "en-US"

    static let `default` = SpeechOptions()
}

enum SpeechEvent: Sendable {
    case loading
    case started(UUID)
    case wordRange(UUID, NSRange)
    case finished(UUID)
    case ended
    case failed(String)
}
