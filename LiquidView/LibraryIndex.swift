import Foundation
import Observation

nonisolated struct IndexEntry: Identifiable, Hashable, Sendable {
    let doc: LiquidDoc
    var hasDuplicate = false
    var id: String { doc.id }
}

nonisolated struct BacklinkRef: Hashable, Sendable {
    let fromID: String
    let rel: String?
    let fragment: String?
}

nonisolated struct UnreadableFile: Identifiable, Hashable, Sendable {
    let fileURL: URL
    let reason: String
    var id: URL { fileURL }
}

/// The community-folder index: id lookup, backlinks, revision chains, and a
/// created-date timeline. Scans on a background task, publishes on the main actor.
@MainActor @Observable
final class LibraryIndex {
    private(set) var folderURL: URL?
    private(set) var byID: [String: IndexEntry] = [:]
    private(set) var backlinks: [String: [BacklinkRef]] = [:]
    /// Keyed by the superseded (older) document; the value is the newer
    /// document whose `revises` link points at it.
    private(set) var revisionOf: [String: String] = [:]
    private(set) var timeline: [IndexEntry] = []
    private(set) var unreadableFiles: [UnreadableFile] = []
    private(set) var supersededIDs: Set<String> = []
    /// Documents targeted by a `retracts` link: withdrawn by their author.
    private(set) var retractedIDs: Set<String> = []
    private(set) var isScanning = false

    // FSEvents watching is macOS-only; visionOS rescans on demand and on
    // scene activation instead.
    #if os(macOS)
    private var watcher: FolderWatcher?
    #endif
    private var scanGeneration = 0

    func setFolder(_ url: URL) {
        folderURL = url
        #if os(macOS)
        watcher?.stop()
        watcher = FolderWatcher(url: url) { [weak self] in
            guard let self else { return }
            Task { @MainActor in self.rescan() }
        }
        #endif
        rescan()
    }

    func rescan() {
        guard let folderURL else { return }
        scanGeneration += 1
        let generation = scanGeneration
        isScanning = true
        Task.detached(priority: .userInitiated) {
            let result = LibraryScanner.scan(folder: folderURL)
            await MainActor.run {
                guard generation == self.scanGeneration else { return }
                self.byID = result.byID
                self.backlinks = result.backlinks
                self.revisionOf = result.revisionOf
                self.timeline = result.timeline
                self.unreadableFiles = result.unreadable
                self.supersededIDs = Set(result.revisionOf.keys)
                self.retractedIDs = result.retractedIDs
                self.isScanning = false
            }
        }
    }

    /// Follows `revises` chains forward to the newest revision.
    /// On a cycle, returns the input unchanged.
    func latestRevision(of id: String) -> String {
        var visited: Set<String> = [id]
        var current = id
        while let newer = revisionOf[current] {
            guard !visited.contains(newer) else { return id }
            visited.insert(newer)
            current = newer
        }
        return current
    }
}

nonisolated enum LibraryScanner {
    struct Result: Sendable {
        var byID: [String: IndexEntry] = [:]
        var backlinks: [String: [BacklinkRef]] = [:]
        var revisionOf: [String: String] = [:]
        var retractedIDs: Set<String> = []
        var timeline: [IndexEntry] = []
        var unreadable: [UnreadableFile] = []
    }

    /// The folder often lives in iCloud Drive: a file another device
    /// wrote may exist here only as a hidden ".<name>.icloud"
    /// placeholder, which the content scan (skipping hidden files)
    /// never sees — and asking iCloud for the folder alone does not
    /// reliably fetch its contents. So ask for every placeholder by
    /// its real name; as files land, the folder watcher fires and the
    /// next rescan reads them.
    static func requestICloudDownloads(in folder: URL) {
        try? FileManager.default.startDownloadingUbiquitousItem(at: folder)
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: nil,
            options: [.skipsPackageDescendants]) else { return }
        for case let url as URL in enumerator
        where url.pathExtension.lowercased() == "icloud" {
            // ".<name>.icloud" → "<name>", the item's logical URL.
            var name = url.lastPathComponent
            if name.hasPrefix(".") { name.removeFirst() }
            name = String(name.dropLast(".icloud".count))
            guard !name.isEmpty else { continue }
            let real = url.deletingLastPathComponent().appendingPathComponent(name)
            try? FileManager.default.startDownloadingUbiquitousItem(at: real)
        }
    }

    static func scan(folder: URL) -> Result {
        var result = Result()
        requestICloudDownloads(in: folder)
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return result }

        var docs: [LiquidDoc] = []
        var modificationDates: [String: Date] = [:]
        var duplicateIDs: Set<String> = []

        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == LiquidDoc.fileExtension else { continue }
            do {
                let data = try Data(contentsOf: url)
                let doc = try LiquidDoc.decode(data: data, fileURL: url)
                let modDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                if let existingDate = modificationDates[doc.id] {
                    // Two files claim the same id: keep the newer one, flag both.
                    duplicateIDs.insert(doc.id)
                    if modDate > existingDate {
                        modificationDates[doc.id] = modDate
                        docs.removeAll { $0.id == doc.id }
                        docs.append(doc)
                    }
                } else {
                    modificationDates[doc.id] = modDate
                    docs.append(doc)
                }
            } catch {
                result.unreadable.append(UnreadableFile(fileURL: url, reason: error.localizedDescription))
            }
        }

        for doc in docs {
            result.byID[doc.id] = IndexEntry(doc: doc, hasDuplicate: duplicateIDs.contains(doc.id))
            for link in doc.links {
                result.backlinks[link.to, default: []]
                    .append(BacklinkRef(fromID: doc.id, rel: link.rel, fragment: link.fragment))
                if link.rel == "revises" {
                    result.revisionOf[link.to] = doc.id
                }
                if link.rel == "retracts" {
                    result.retractedIDs.insert(link.to)
                }
            }
        }

        result.timeline = result.byID.values.sorted { $0.doc.listedDate < $1.doc.listedDate }
        return result
    }
}
