import Foundation
import CryptoKit
import Observation

// MARK: - State

enum VoiceInstallState: Equatable {
    case notInstalled
    case downloading(fraction: Double, bytesPerSecond: Double)
    case verifying
    case installed(sizeOnDisk: Int64)
    case failed(message: String)

    var isActive: Bool {
        switch self {
        case .downloading, .verifying: return true
        default: return false
        }
    }
}

// MARK: - File list types

private struct HFTreeEntry: Decodable {
    let type: String
    let path: String
    let size: Int64?
    let lfs: LFSInfo?
    struct LFSInfo: Decodable { let oid: String?; let size: Int64? }
}

private struct ManifestFile: Codable {
    let name: String
    let path: String
    let size: Int64
    let sha256: String?
}

private struct Manifest: Codable {
    let repo: String
    let revision: String
    let files: [ManifestFile]
    let installedAt: Date
    let schema: Int
}

// MARK: - VoiceInstaller

/// Downloads and verifies Qwen3-TTS-0.6B model weights into
///   ~/Library/Application Support/Origami Text/Voices/…
/// Two repos are required:
///   1. aufklarer/Qwen3-TTS-12Hz-0.6B-CustomVoice-MLX-bf16  (talker + code predictor)
///   2. Qwen/Qwen3-TTS-Tokenizer-12Hz                        (speech tokenizer decoder)
/// Observable so SwiftUI views track progress directly.
@Observable
@MainActor
final class VoiceInstaller {

    static let shared = VoiceInstaller()

    private let repo = "aufklarer/Qwen3-TTS-12Hz-0.6B-CustomVoice-MLX-bf16"
    private let tokenizerRepo = "Qwen/Qwen3-TTS-Tokenizer-12Hz"
    private let bundleID = "qwen3-tts-0.6b-customvoice-bf16"

    // MARK: Observable state

    private(set) var state: VoiceInstallState = .notInstalled

    // MARK: Hardware gate

    static var isHardwareSupported: Bool {
        #if arch(arm64)
        return ProcessInfo.processInfo.physicalMemory >= 16 * 1024 * 1024 * 1024
        #else
        return false
        #endif
    }

    // MARK: Paths

    private var voicesDir: URL {
        get throws {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil, create: true)
            return support.appending(path: "Origami Text/Voices", directoryHint: .isDirectory)
        }
    }

    var bundleDir: URL? { try? voicesDir.appending(path: bundleID) }
    var modelDir: URL? { bundleDir }
    var tokenizerDir: URL? { bundleDir?.appendingPathComponent("speech_tokenizer") }

    // MARK: Init

    init() {
        Task { await checkInstalledState() }
    }

    // MARK: - Public API

    func install() async {
        guard case .notInstalled = state else { return }

        guard let voices = try? voicesDir else {
            state = .failed(message: "Cannot access Application Support.")
            return
        }
        try? FileManager.default.createDirectory(at: voices, withIntermediateDirectories: true)

        let mainDir = voices.appending(path: bundleID)
        let mainPresent = hasSafetensors(at: mainDir)

        // Download main model only if not already present
        if !mainPresent {
            guard await checkDiskSpace() else { return }
            let end = 0.55
            guard await downloadRepo(repo, to: mainDir, progressStart: 0.0, progressEnd: end) else { return }

            // Write manifest for main model
            if let files = await resolveFileList(for: repo) {
                let manifest = Manifest(repo: repo, revision: "main", files: files,
                                        installedAt: Date(), schema: 1)
                if let data = try? JSONEncoder().encode(manifest) {
                    try? data.write(to: mainDir.appendingPathComponent("manifest.json"))
                }
            }
        }

        // Download speech tokenizer decoder into bundleDir/speech_tokenizer/
        let tokDir = mainDir.appendingPathComponent("speech_tokenizer")
        if !hasSafetensors(at: tokDir) {
            let progressStart = mainPresent ? 0.0 : 0.55
            guard await downloadRepo(tokenizerRepo, to: tokDir,
                                     progressStart: progressStart, progressEnd: 1.0) else { return }
        }

        await checkInstalledState()
    }

    func cancel() {
        if case .downloading = state {
            state = .notInstalled
        }
    }

    func uninstall() {
        if let dir = bundleDir { try? FileManager.default.removeItem(at: dir) }
        state = .notInstalled
    }

    // MARK: - Private helpers

    private func checkInstalledState() async {
        guard let dir = bundleDir, FileManager.default.fileExists(atPath: dir.path),
              let tokDir = tokenizerDir, hasSafetensors(at: tokDir) else {
            state = .notInstalled
            return
        }
        let size = directorySize(at: dir)
        state = .installed(sizeOnDisk: size)
    }

    private func hasSafetensors(at dir: URL) -> Bool {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return false
        }
        return contents.contains { $0.hasSuffix(".safetensors") }
    }

    private func checkDiskSpace() async -> Bool {
        guard let dir = try? voicesDir,
              let vals = try? dir.resourceValues(
                  forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let available = vals.volumeAvailableCapacityForImportantUsage else { return true }
        if available < 4_000_000_000 {
            state = .failed(message: "Need about 4 GB free. Please clear some space.")
            return false
        }
        return true
    }

    /// Download all files from a HuggingFace repo into `destDir`.
    /// `progressStart`/`progressEnd` map the download onto a slice of the 0–1 progress range.
    @discardableResult
    private func downloadRepo(
        _ repoID: String,
        to destDir: URL,
        progressStart: Double,
        progressEnd: Double
    ) async -> Bool {
        guard let files = await resolveFileList(for: repoID) else {
            state = .failed(message: "Could not retrieve file list from Hugging Face.")
            return false
        }

        let parent = destDir.deletingLastPathComponent()
        let partial = parent.appendingPathComponent(".partial-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)

        let totalBytes = files.reduce(0) { $0 + $1.size }
        var receivedBytes: Int64 = 0
        state = .downloading(fraction: progressStart, bytesPerSecond: 0)

        for file in files {
            guard case .downloading = state else {
                cleanup(partial)
                return false
            }
            let dest = partial.appendingPathComponent(file.name)
            try? FileManager.default.createDirectory(
                at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)

            let ok = await downloadFile(remotePath: file.path, from: repoID, to: dest)
            if !ok { cleanup(partial); return false }

            receivedBytes += file.size
            let fileFraction = totalBytes > 0 ? Double(receivedBytes) / Double(totalBytes) : 1.0
            let globalFraction = progressStart + fileFraction * (progressEnd - progressStart)
            state = .downloading(fraction: globalFraction, bytesPerSecond: 0)
        }

        state = .verifying
        guard await verifyFiles(in: partial, against: files) else {
            cleanup(partial)
            state = .failed(message: "File verification failed. Try again.")
            return false
        }

        try? FileManager.default.removeItem(at: destDir)
        do {
            try FileManager.default.moveItem(at: partial, to: destDir)
        } catch {
            cleanup(partial)
            state = .failed(message: "Could not move files: \(error.localizedDescription)")
            return false
        }

        return true
    }

    private func resolveFileList(for repoID: String) async -> [ManifestFile]? {
        let apiStr = "https://huggingface.co/api/models/\(repoID)/tree/main?recursive=true"
        if let url = URL(string: apiStr),
           let (data, _) = try? await URLSession.shared.data(from: url),
           let entries = try? JSONDecoder().decode([HFTreeEntry].self, from: data) {
            let excluded: Set<String> = [".gitattributes", "README.md"]
            return entries
                .filter { $0.type == "file"
                    && !excluded.contains(URL(fileURLWithPath: $0.path).lastPathComponent)
                    && !$0.path.hasPrefix(".cache/") }
                .map { e -> ManifestFile in
                    let size = e.lfs?.size ?? e.size ?? 0
                    let sha256 = e.lfs?.oid
                    return ManifestFile(name: e.path, path: e.path, size: size, sha256: sha256)
                }
        }
        // Fallback: bundled static manifest (main model only)
        if repoID == repo,
           let url = Bundle.main.url(forResource: "qwen3-tts-manifest", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let manifest = try? JSONDecoder().decode(Manifest.self, from: data) {
            return manifest.files
        }
        return nil
    }

    private func downloadFile(remotePath: String, from repoID: String, to dest: URL) async -> Bool {
        let encoded = remotePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? remotePath
        let urlStr = "https://huggingface.co/\(repoID)/resolve/main/\(encoded)"
        guard let url = URL(string: urlStr) else { return false }
        do {
            let (tmp, _) = try await URLSession.shared.download(from: url)
            try FileManager.default.moveItem(at: tmp, to: dest)
            return true
        } catch {
            if (error as NSError).code == NSURLErrorCancelled { return false }
            state = .failed(message: "Download failed: \(error.localizedDescription)")
            return false
        }
    }

    private func verifyFiles(in dir: URL, against files: [ManifestFile]) async -> Bool {
        for file in files {
            let path = dir.appendingPathComponent(file.name)
            guard FileManager.default.fileExists(atPath: path.path) else { return false }
            if let expected = file.sha256,
               let actual = sha256(of: path),
               actual != expected { return false }
        }
        return true
    }

    private func sha256(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func directorySize(at url: URL) -> Int64 {
        guard let enum_ = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return (enum_.allObjects as? [URL] ?? [])
            .compactMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }
            .reduce(0) { $0 + Int64($1) }
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }
}
