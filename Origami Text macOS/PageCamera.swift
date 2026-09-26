// Brought across from Knowledge Space (PageCamera.swift) — the sibling
// lab app. Keep the matcher and camera in step with it; only the
// openings differ: Origami Text opens the found document in the main
// window through AppModel.open.
#if os(macOS)
import SwiftUI
import AppKit
import AVFoundation
import CoreImage
import Vision

// Hold up a printed page — a booklet's page, or any print of a library
// document — and the camera reads it back to its source: Vision's OCR
// over the live frames, the words matched against the library, and the
// document opens at the very paragraph the page shows. The booklet
// footer's title helps the match along but is not required; the words
// themselves are usually identification enough.

// MARK: - The matcher

/// From OCR'd lines to (document, paragraph): plain word-sequence
/// overlap, no model. The page's words are normalized and cut into
/// short overlapping runs ("shingles"); the document containing the
/// most runs wins, and within it the paragraph holding the most runs
/// names the place. Deliberately tolerant of OCR noise — a run only
/// four words long survives a misread word either side of it.
enum PageMatch {

    struct Candidate {
        let id: String
        let title: String
        /// The whole text, normalized, for the document score.
        let text: String
        /// Each paragraph normalized, for the place within.
        let paragraphs: [(id: String, text: String)]
    }

    struct Hit {
        let docID: String
        let title: String
        let paragraphID: String?
    }

    /// Lowercased, letters and digits only, single spaces — the one
    /// spelling both sides of the comparison are held to.
    static func normalized(_ text: String) -> String {
        String(text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " })
            .split(separator: " ")
            .joined(separator: " ")
    }

    /// Overlapping four-word runs, every other word a new start.
    static func shingles(_ text: String, size: Int = 4, step: Int = 2) -> [String] {
        let words = text.split(separator: " ").map(String.init)
        guard words.count >= size else { return [] }
        return stride(from: 0, through: words.count - size, by: step).map {
            words[$0..<($0 + size)].joined(separator: " ")
        }
    }

    /// The library's documents, normalized once and kept for the
    /// window's lifetime — the scan is the slow part, not the match.
    static func candidates(docs: [(id: String, title: String,
                                   paragraphs: [(id: String, text: String)])]) -> [Candidate] {
        docs.map { doc in
            let paragraphs = doc.paragraphs.map { ($0.id, normalized($0.text)) }
            return Candidate(id: doc.id,
                             title: doc.title,
                             text: paragraphs.map(\.1).joined(separator: " "),
                             paragraphs: paragraphs)
        }
    }

    /// The page's best home, or nil while nothing stands clearly out:
    /// at least three runs found, and a lead of two over the runner-up
    /// so a stock phrase shared by many documents never opens the
    /// wrong one. A title seen on the page (the booklet's footer)
    /// counts heavily toward its document.
    static func find(lines: [String], in candidates: [Candidate]) -> Hit? {
        let page = normalized(lines.joined(separator: " "))
        let runs = shingles(page)
        guard runs.count >= 2 else { return nil }
        var best: (score: Int, candidate: Candidate)?
        var runnerUp = 0
        for candidate in candidates {
            guard !candidate.text.isEmpty else { continue }
            var score = runs.reduce(0) { tally, run in
                candidate.text.contains(run) ? tally + 1 : tally
            }
            // The footer names its source: a title read on the page
            // outweighs a few misread words.
            let title = normalized(candidate.title)
            if title.split(separator: " ").count >= 2, page.contains(title) {
                score += 5
            }
            if score > (best?.score ?? 0) {
                runnerUp = best?.score ?? 0
                best = (score, candidate)
            } else if score > runnerUp {
                runnerUp = score
            }
        }
        guard let best, best.score >= 3, best.score >= runnerUp + 2 else { return nil }
        // The place within is the page's own top: the first readable
        // line (lines arrive in top-to-bottom page order) that lands
        // in the document names the paragraph, so the window opens
        // showing what the page shows.
        var placeID: String?
        search: for line in lines {
            for run in placeRuns(line) {
                if let paragraph = best.candidate.paragraphs.first(
                    where: { $0.text.contains(run) }) {
                    placeID = paragraph.id
                    break search
                }
            }
        }
        // A page whose top lines are decoration falls back to the
        // paragraph holding the most runs.
        if placeID == nil {
            var bestParagraph: (hits: Int, id: String)?
            for paragraph in best.candidate.paragraphs {
                let hits = runs.reduce(0) { tally, run in
                    paragraph.text.contains(run) ? tally + 1 : tally
                }
                if hits > (bestParagraph?.hits ?? 0) {
                    bestParagraph = (hits, paragraph.id)
                }
            }
            placeID = bestParagraph?.id
        }
        return Hit(docID: best.candidate.id,
                   title: best.candidate.title,
                   paragraphID: placeID)
    }

    /// One OCR line's runs for placing within the found document —
    /// denser than the document runs (every word a start), and a short
    /// line (a heading, a caption) counts whole. Only ever looked up
    /// inside the already-won document, so short runs cost nothing.
    private static func placeRuns(_ line: String) -> [String] {
        let words = normalized(line).split(separator: " ").map(String.init)
        if words.count >= 4 {
            return stride(from: 0, through: words.count - 4, by: 1).map {
                words[$0..<($0 + 4)].joined(separator: " ")
            }
        }
        return words.count >= 2 ? [words.joined(separator: " ")] : []
    }
}

// MARK: - Captured underlines

extension AppModel {
    /// Hand underlines from a scanned page, kept as the reader's own
    /// highlights: proper W3C Web Annotations in the document's
    /// `.jsonld` sidecar, anchored through the selector ladder to the
    /// document's words — the paper's OCR only points at them — and
    /// deduplicated against what is already kept.
    func captureUnderlines(_ phrases: [String], in doc: LiquidDoc) -> Int {
        guard !phrases.isEmpty else { return 0 }
        let existing = annotations(for: doc)
        var added = 0
        for phrase in phrases {
            var anchored: (paragraphID: String, exact: String)?
            for paragraph in doc.body ?? [] {
                if let range = paragraph.text.range(
                    of: phrase,
                    options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) {
                    anchored = (paragraph.id, String(paragraph.text[range]))
                    break
                }
            }
            guard let anchored else { continue }
            let already = existing.contains { annotation in
                annotation.target.selectors.contains { selector in
                    if case .quote(let exact, _, _) = selector {
                        return exact.compare(
                            anchored.exact,
                            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive])
                            == .orderedSame
                    }
                    return false
                }
            }
            guard !already else { continue }
            addHighlight(to: doc, paragraphID: anchored.paragraphID,
                         exact: anchored.exact)
            added += 1
        }
        return added
    }
}

// MARK: - The camera

/// The capture session and its latest frame — the loop in the view
/// takes a frame every beat and hands it to Vision; nothing is stored.
final class PageCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let lock = NSLock()
    private var latest: CVPixelBuffer?

    static func authorized() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    /// Configures on first call and starts running. Off the main
    /// thread — starting a session blocks.
    func start() throws {
        if session.inputs.isEmpty {
            guard let device = AVCaptureDevice.default(for: .video) else {
                throw CameraUnavailable()
            }
            let input = try AVCaptureDeviceInput(device: device)
            session.beginConfiguration()
            session.sessionPreset = .high
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                throw CameraUnavailable()
            }
            session.addInput(input)
            output.alwaysDiscardsLateVideoFrames = true
            // BGRA, explicitly: the camera's native YUV frames are not
            // a given for Vision, and a silently refused format looks
            // like a camera that never reads.
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ]
            output.setSampleBufferDelegate(
                self, queue: DispatchQueue(label: "page.camera.frames"))
            if session.canAddOutput(output) { session.addOutput(output) }
            session.commitConfiguration()
        }
        session.startRunning()
    }

    func stop() {
        if session.isRunning { session.stopRunning() }
    }

    func latestFrame() -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock()
        latest = buffer
        lock.unlock()
    }

    struct CameraUnavailable: LocalizedError {
        var errorDescription: String? { "No camera could be found on this Mac." }
    }
}

/// The live picture, mirrored like a mirror — holding a page up feels
/// wrong any other way; the OCR reads the unmirrored frames.
private struct PageCameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.connection?.automaticallyAdjustsVideoMirroring = false
        preview.connection?.isVideoMirrored = true
        view.layer = preview
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

// MARK: - The window

/// File ▸ Hold Up a Page… — the camera watching for a printed page,
/// telling the reader what it is doing in one quiet line, and opening
/// the found document at the page's own paragraph.
struct PageCaptureView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var camera = PageCamera()
    @State private var status = "Hold a printed page up to the camera."
    @State private var candidates: [PageMatch.Candidate]?
    /// The captured page, shown frozen and grey while the library is
    /// searched — the sign that the paper can come down. It clears by
    /// itself a few seconds later, ready for the next page.
    @State private var stillFrame: NSImage?
    /// The last find, so a page still held up does not reopen its
    /// document every few seconds.
    @State private var lastHit: (doc: String, place: String?, at: Date)?
    /// A found page ends the scan: the picture stays frozen and grey
    /// until the reader asks for another. (Knowledge Space resumes by
    /// itself; here the rest state is the sign the scan is done.)
    @State private var finished = false
    /// Set when macOS has the camera switched off for this app — the
    /// one state a button can mend, so one appears beside the status.
    @State private var cameraDenied = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                PageCameraPreview(session: camera.session)
                if let stillFrame {
                    Image(nsImage: stillFrame)
                        .resizable()
                        .scaledToFill()
                        .grayscale(1)
                        // As mirrored as the live picture it replaces.
                        .scaleEffect(x: -1)
                }
            }
            .frame(minWidth: 520, minHeight: 360)
            .clipped()
            Divider()
            HStack {
                Text(status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                if cameraDenied {
                    Button("Open Camera Settings") { openCameraSettings() }
                        .help("System Settings ▸ Privacy & Security ▸ Camera — turn Origami Text on there, then reopen this window")
                }
                if finished {
                    Button("Scan Another Page") {
                        finished = false
                        stillFrame = nil
                        status = "Hold a printed page up to the camera."
                        let camera = camera
                        Task.detached { try? camera.start() }
                    }
                }
                Button(finished ? "Done" : "Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            .background(AppGreys.page)
        }
        .task { await watch() }
        .onDisappear { camera.stop() }
    }

    /// System Settings ▸ Privacy & Security ▸ Camera — the pane where
    /// this app's own camera switch lives. (macOS asks the app to
    /// quit and reopen when the switch flips; the window is fresh on
    /// the next Hold Up a Page.)
    private func openCameraSettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")
        else { return }
        NSWorkspace.shared.open(url)
    }

    /// The loop: a frame every beat, OCR, then the match — each stage
    /// off the main thread; the first clear find opens and closes. The
    /// status line beats with it, so a quiet window is never a mystery.
    private func watch() async {
        guard await PageCamera.authorized() else {
            cameraDenied = true
            status = "The camera is not permitted for Origami Text."
            return
        }
        let camera = self.camera
        do {
            try await Task.detached { try camera.start() }.value
        } catch {
            status = error.localizedDescription
            return
        }
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(800))
            await attempt()
        }
    }

    /// One pass: the current frame through OCR and the matcher — the
    /// moment a read is good enough and one document clearly wins, it
    /// captures and goes; no button. A page still being moved into
    /// view reads garbled and low-confidence, and simply waits its
    /// turn. The window stays for the next page; every outcome says
    /// so in the status line, and nothing fails silently.
    private func attempt() async {
        guard !finished else { return }           // resting on a find
        guard stillFrame == nil else { return }   // a search is showing
        guard let frame = camera.latestFrame() else {
            status = "Waiting for the camera\u{2026}"
            return
        }
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        let lines: [String]
        let lineBoxes: [(string: String, x: CGFloat, y: CGFloat,
                         width: CGFloat, height: CGFloat)]
        let meanConfidence: Float
        do {
            let observations = try await request.perform(on: frame)
            // Top of the page first — the place within the found
            // document is named by the first readable line. (Vision's
            // normalized coordinates put y's origin at the bottom.)
            let ordered = observations.sorted {
                $0.boundingBox.origin.y > $1.boundingBox.origin.y
            }
            let candidates = ordered.compactMap { $0.topCandidates(1).first }
            lines = candidates.map(\.string)
            lineBoxes = ordered.compactMap { observation in
                guard let string = observation.topCandidates(1).first?.string
                else { return nil }
                let box = observation.boundingBox
                return (string, box.origin.x, box.origin.y,
                        box.width, box.height)
            }
            meanConfidence = candidates.isEmpty ? 0
                : candidates.map(\.confidence).reduce(0, +) / Float(candidates.count)
        } catch {
            status = "The frame could not be read: \(error.localizedDescription)"
            NSLog("PageCamera OCR failed: %@", String(describing: error))
            return
        }
        let wordCount = lines.joined(separator: " ")
            .split(whereSeparator: \.isWhitespace).count
        guard wordCount >= 10 else {
            status = wordCount == 0
                ? "No words in view yet — bring the page closer."
                : "Only \(wordCount) words readable — bring the page closer or steady it."
            return
        }
        // A page mid-movement reads blurred and uncertain; wait for a
        // steady frame rather than match against noise.
        guard meanConfidence >= 0.45 else {
            status = "Read \(wordCount) words, still settling — hold the page steady."
            return
        }
        // A good read: freeze the picture and grey it — the page can
        // come down, the searching is the system's now.
        stillFrame = Self.still(from: frame)
        camera.stop()
        status = "Read \(wordCount) words — looking in the library\u{2026}"
        let library = await libraryCandidates()
        let hit = await Task.detached {
            PageMatch.find(lines: lines, in: library)
        }.value
        guard let hit else {
            status = "No library document matches that page — hold it up again to retry."
            await resumeScanning(after: .seconds(1.5))
            return
        }
        // A page still held up must not reopen its document every few
        // seconds; the same find within a short while passes quietly.
        if let last = lastHit, last.doc == hit.docID,
           last.place == hit.paragraphID,
           Date.now.timeIntervalSince(last.at) < 12 {
            status = "Still the same page."
            await resumeScanning(after: .seconds(2))
            return
        }
        lastHit = (hit.docID, hit.paragraphID, Date.now)
        // The found document opens in the main window at the page's
        // own paragraph — Scroll mode so the landing is a flow to the
        // very line. (Paragraph ids are only trustworthy in the
        // revision they were matched against.)
        UserDefaults.standard.set(EPUBReaderMode.scroll.rawValue,
                                  forKey: "readerMode")
        let target = model.index.latestRevision(of: hit.docID)
        guard let entry = model.index.allByID[target] else {
            status = "Found \u{201C}\(hit.title)\u{201D} but its document could not be loaded."
            await resumeScanning(after: .seconds(2))
            return
        }
        model.open(entry.doc,
                   fragment: target == hit.docID ? hit.paragraphID : nil)
        // The pen comes along: hand underlines on the page become the
        // reader's own highlights — W3C Web Annotations in the
        // document's .jsonld sidecar — visible at once in the opened
        // reading.
        let phrases = Self.underlinedPhrases(in: frame, lines: lineBoxes)
        NSLog("PageCamera underlines detected: %@",
              phrases.isEmpty ? "none" : phrases.joined(separator: " | "))
        let captured = model.captureUnderlines(phrases, in: entry.doc)
        let kept = captured == 0 ? "" :
            " — \(captured) underlined \(captured == 1 ? "passage" : "passages") kept"
        model.showNote("Opened \u{201C}\(hit.title)\u{201D} at the page\u{2019}s place\(kept).")
        status = "Opened \u{201C}\(hit.title)\u{201D}\(kept)."
        // The scan is done: the picture rests frozen and grey — the
        // paper can come down for good. Scan Another Page wakes it.
        finished = true
    }

    /// Back to the living picture — the frozen grey clears and the
    /// camera runs again, ready for another page.
    private func resumeScanning(after delay: Duration) async {
        try? await Task.sleep(for: delay)
        stillFrame = nil
        let camera = self.camera
        Task.detached { try? camera.start() }
    }

    /// Hand underlines, read from the page: in the strip just beneath
    /// a recognized line, a long dark horizontal run is a pen's
    /// stroke, and the words above it come back as phrases. The run's
    /// span maps to the line's characters proportionally — rough, but
    /// a phrase only ever anchors to the document's own words
    /// afterwards, so a misjudged edge misses rather than mismarks.
    static func underlinedPhrases(
        in buffer: CVPixelBuffer,
        lines: [(string: String, x: CGFloat, y: CGFloat,
                 width: CGFloat, height: CGFloat)]
    ) -> [String] {
        guard let gray = grayBitmap(from: buffer) else { return [] }
        var phrases: [String] = []
        for line in lines {
            let words = line.string.split(separator: " ").map(String.init)
            guard !words.isEmpty, line.width > 0, line.height > 0 else { continue }
            let minX = max(Int(line.x * CGFloat(gray.width)), 0)
            let maxX = min(Int((line.x + line.width) * CGFloat(gray.width)),
                           gray.width - 1)
            guard maxX > minX + 8 else { continue }
            // The strip under the words — reaching a little INTO the
            // box, since Vision's line box often includes descenders
            // and a close-drawn underline with them. Vision's y runs
            // bottom-up; the bitmap's rows run top-down.
            let bottomUp = line.y * CGFloat(gray.height)
            let boxHeight = line.height * CGFloat(gray.height)
            let rowFrom = max(gray.height - 1 - Int(bottomUp + boxHeight * 0.2), 0)
            let rowTo = min(gray.height - 1 - Int(bottomUp - boxHeight * 0.8),
                            gray.height - 1)
            guard rowFrom <= rowTo else { continue }
            // The stroke, seen as the strip's horizontal projection: a
            // column is inked when two or more of its strip rows read
            // dark — a pen line blurs to at least that; speckle does
            // not — and a hand line's slight slope only shifts WHICH
            // rows are dark, never the column's count, so the
            // projection reads a slanted stroke as the flat line the
            // hand meant.
            let columns = maxX - minX + 1
            var columnHits = [Int](repeating: 0, count: columns)
            for row in rowFrom...rowTo {
                let rowStart = row * gray.width
                var sum = 0
                for x in minX...maxX { sum += Int(gray.data[rowStart + x]) }
                let mean = sum / columns
                // Gentle: a webcam blurs a pen stroke well above ink-black.
                let threshold = UInt8(clamping: mean * 72 / 100)
                for x in minX...maxX where gray.data[rowStart + x] < threshold {
                    columnHits[x - minX] += 1
                }
            }
            let inked = columnHits.map { $0 >= 2 }
            // A strip mostly dark is a figure or a shadow, not a line.
            guard inked.count(where: { $0 }) < columns * 6 / 10 else { continue }
            // The longest inked run, small gaps forgiven — a pen's
            // texture is not a printer's.
            var bestFrom = 0, bestLength = 0, from = -1, gap = 0
            let gapAllowance = max(columns / 40, 2)
            for index in 0...columns {
                let dark = index < columns && inked[index]
                if dark {
                    if from < 0 { from = index }
                    gap = 0
                } else if from >= 0 {
                    gap += 1
                    if gap > gapAllowance || index >= columns {
                        let length = index - gap - from + 1
                        if length > bestLength {
                            bestLength = length
                            bestFrom = from
                        }
                        from = -1
                        gap = 0
                    }
                }
            }
            // The mark this reads for is a line under MORE THAN TWO
            // WORDS — the deliberate annotation, not a dash or a
            // descender. The reach asked for is about three words'
            // worth of this line's own type.
            let perCharacterPx = CGFloat(maxX - minX)
                / CGFloat(max(line.string.count, 1))
            let averageWordLength = max(line.string.count / max(words.count, 1), 4)
            let minRun = Int(perCharacterPx * CGFloat(averageWordLength * 2 + 3))
            guard bestLength >= minRun else { continue }
            let run = (from: minX + bestFrom, to: minX + bestFrom + bestLength)
            // The run's span back to words, by character position.
            let perCharacter = CGFloat(maxX - minX)
                / CGFloat(max(line.string.count, 1))
            var underlined: [String] = []
            var phrase: [String] = []
            var cursor = 0
            for word in words {
                let start = CGFloat(minX) + CGFloat(cursor) * perCharacter
                let middle = start + CGFloat(word.count) * perCharacter / 2
                if middle >= CGFloat(run.from), middle <= CGFloat(run.to) {
                    phrase.append(word)
                } else if !phrase.isEmpty {
                    underlined.append(phrase.joined(separator: " "))
                    phrase = []
                }
                cursor += word.count + 1
            }
            if !phrase.isEmpty { underlined.append(phrase.joined(separator: " ")) }
            // The deliberate mark runs under more than two words;
            // anything shorter is noise here.
            phrases.append(contentsOf: underlined.filter {
                $0.split(separator: " ").count >= 3
            })
        }
        return phrases
    }

    /// The frame as one grey byte per pixel, rows top-down.
    private static func grayBitmap(from buffer: CVPixelBuffer)
        -> (data: [UInt8], width: Int, height: Int)? {
        let image = CIImage(cvPixelBuffer: buffer)
        guard let cg = CIContext().createCGImage(image, from: image.extent) else {
            return nil
        }
        let width = cg.width
        let height = cg.height
        var data = [UInt8](repeating: 0, count: width * height)
        let drawn = data.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? (data, width, height) : nil
    }

    /// The captured frame as a picture, for the frozen grey moment.
    private static func still(from buffer: CVPixelBuffer) -> NSImage? {
        let image = CIImage(cvPixelBuffer: buffer)
        guard let cg = CIContext().createCGImage(image, from: image.extent) else {
            return nil
        }
        return NSImage(cgImage: cg,
                       size: NSSize(width: image.extent.width,
                                    height: image.extent.height))
    }

    /// The library, normalized once per window: the titles and every
    /// paragraph's words, ready for the runs to be looked up in.
    private func libraryCandidates() async -> [PageMatch.Candidate] {
        if let candidates { return candidates }
        let docs = model.index.allByID.values.map { entry in
            (id: entry.doc.id,
             title: entry.doc.title,
             paragraphs: (entry.doc.body ?? []).map { ($0.id, $0.text) })
        }
        let built = await Task.detached { PageMatch.candidates(docs: docs) }.value
        candidates = built
        return built
    }
}
#endif
