#if os(macOS)
import AVFoundation
import Foundation
import Observation

/// EPUB 3 Media Overlays (read-along audio): a chapter's SMIL pairs each
/// passage of the text with a clip of recorded narration. The reader plays
/// the clips in order and marks each passage as its audio plays.
nonisolated enum MediaOverlay {
    struct Clip: Hashable, Sendable {
        /// The element the clip reads (its id in the chapter).
        let fragment: String
        /// The audio file, absolute.
        let audio: URL
        let begin: Double
        let end: Double?
    }

    /// The clips for one chapter, in reading order; empty when the chapter
    /// has no media overlay.
    static func clips(inUnpackedFolder folder: URL, chapter: String) -> [Clip] {
        let container = (try? String(contentsOf: folder.appendingPathComponent("META-INF/container.xml"),
                                     encoding: .utf8)) ?? ""
        let opfSubpath = capture(container, #"full-path="([^"]+)""#) ?? "package.opf"
        guard let opf = try? String(contentsOf: folder.appendingPathComponent(opfSubpath), encoding: .utf8)
        else { return [] }
        let opfDirectory = (opfSubpath as NSString).deletingLastPathComponent
        func joined(_ base: String, _ href: String) -> String {
            let decoded = href.removingPercentEncoding ?? href
            let path = base.isEmpty ? decoded : base + "/" + decoded
            return (path as NSString).standardizingPath
        }
        let items = captures(opf, #"<item\s[^>]*>"#)
        guard let chapterItem = items.first(where: { item in
                  capture(item, #"href=["']([^"']+)"#).map { joined(opfDirectory, $0) } == (chapter as NSString).standardizingPath
              }),
              let overlayID = capture(chapterItem, #"media-overlay=["']([^"']+)"#),
              let smilItem = items.first(where: { capture($0, #"\sid=["']([^"']+)"#) == overlayID }),
              let smilHref = capture(smilItem, #"href=["']([^"']+)"#)
        else { return [] }
        let smilPath = joined(opfDirectory, smilHref)
        guard let smil = try? String(contentsOf: folder.appendingPathComponent(smilPath), encoding: .utf8)
        else { return [] }
        let smilDirectory = (smilPath as NSString).deletingLastPathComponent
        return captures(smil, #"(?s)<par\b.*?</par>"#).compactMap { par -> Clip? in
            guard let textSrc = capture(par, #"<text[^>]*src=["']([^"']+)"#),
                  let hash = textSrc.firstIndex(of: "#"),
                  let audioSrc = capture(par, #"<audio[^>]*src=["']([^"']+)"#) else { return nil }
            let audio = folder.appendingPathComponent(joined(smilDirectory, audioSrc))
            return Clip(fragment: String(textSrc[textSrc.index(after: hash)...]),
                        audio: audio,
                        begin: capture(par, #"clipBegin=["']([^"']+)"#).flatMap(seconds) ?? 0,
                        end: capture(par, #"clipEnd=["']([^"']+)"#).flatMap(seconds))
        }
    }

    /// A SMIL clock value in seconds: "0:01:02.5", "01:02.5", "12.5s",
    /// "1500ms", "2min", "1h", or bare "12.5".
    static func seconds(_ value: String) -> Double? {
        let v = value.trimmingCharacters(in: .whitespaces)
        if v.hasSuffix("ms") { return Double(v.dropLast(2)).map { $0 / 1000 } }
        if v.hasSuffix("min") { return Double(v.dropLast(3)).map { $0 * 60 } }
        if v.hasSuffix("h") { return Double(v.dropLast()).map { $0 * 3600 } }
        if v.hasSuffix("s") { return Double(v.dropLast()) }
        let parts = v.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    private static func capture(_ text: String, _ pattern: String) -> String? { first(text, pattern) }

    private static func first(_ text: String, _ pattern: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func captures(_ text: String, _ pattern: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }
}

/// Plays a chapter's read-along clips and says which passage is sounding.
@Observable
@MainActor
final class MediaOverlayPlayer {
    private(set) var isPlaying = false
    private(set) var isPaused = false
    /// The element being narrated, for the page to mark.
    private(set) var activeFragment: String?

    @ObservationIgnored private var clips: [MediaOverlay.Clip] = []
    @ObservationIgnored private var index = 0
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var loadedAudio: URL?
    @ObservationIgnored private var ticker: Task<Void, Never>?

    var isActive: Bool { isPlaying || isPaused }

    /// Starts at the clip for `fragment` when given, else the first.
    func play(_ clips: [MediaOverlay.Clip], from fragment: String? = nil) {
        stop()
        guard !clips.isEmpty else { return }
        self.clips = clips
        index = fragment.flatMap { f in clips.firstIndex { $0.fragment == f } } ?? 0
        startClip()
    }

    func togglePause() {
        guard let player else { return }
        if isPaused { player.play(); isPaused = false; isPlaying = true }
        else { player.pause(); isPaused = true; isPlaying = false }
    }

    func stop() {
        ticker?.cancel()
        ticker = nil
        player?.stop()
        player = nil
        loadedAudio = nil
        isPlaying = false
        isPaused = false
        activeFragment = nil
    }

    private func startClip() {
        guard clips.indices.contains(index) else { stop(); return }
        let clip = clips[index]
        if loadedAudio != clip.audio {
            player = try? AVAudioPlayer(contentsOf: clip.audio)
            player?.prepareToPlay()
            loadedAudio = clip.audio
        }
        guard let player else { stop(); return }
        // Contiguous clips in one file play straight through; a gap or a
        // jump seeks.
        if abs(player.currentTime - clip.begin) > 0.25 || !player.isPlaying {
            player.currentTime = clip.begin
        }
        player.play()
        isPlaying = true
        isPaused = false
        activeFragment = clip.fragment
        if ticker == nil {
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(50))
                    self?.tick()
                }
            }
        }
    }

    private func tick() {
        guard isPlaying, let player, clips.indices.contains(index) else { return }
        let clip = clips[index]
        let finished = clip.end.map { player.currentTime >= $0 } ?? !player.isPlaying
        guard finished else { return }
        index += 1
        startClip()
    }
}
#endif
