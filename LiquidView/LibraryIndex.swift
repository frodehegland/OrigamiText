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
    /// Everything scanned — in Origami Text nothing is filtered from the
    /// index, so this is `byID` itself; kept under Knowledge Space's name
    /// so the travelling view modules compile unchanged.
    var allByID: [String: IndexEntry] { byID }
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

    /// The two feeds the index merges: the community folder's JSON
    /// documents (when one is chosen) and the EPUB shelf — every opened
    /// book as a structured document, re-imported from its unpacked
    /// package. The views and modules read the merged result.
    private var scannedDocs: [LiquidDoc] = []
    private var scannedDuplicates: Set<String> = []
    private var epubDocs: [LiquidDoc] = []

    /// Installs the EPUB shelf's documents (see
    /// `AppModel.rebuildEPUBIndex`) and re-derives the merged index.
    func setEPUBDocuments(_ docs: [LiquidDoc]) {
        epubDocs = docs
        rebuild()
    }

    /// Re-derives byID, backlinks, revisions, and the timeline over both
    /// feeds. The EPUB shelf comes last: on an id both feeds claim, the
    /// book wins.
    private func rebuild() {
        let result = LibraryScanner.derive(docs: scannedDocs + epubDocs,
                                           duplicateIDs: scannedDuplicates)
        byID = result.byID
        backlinks = result.backlinks
        revisionOf = result.revisionOf
        timeline = result.timeline
        supersededIDs = Set(result.revisionOf.keys)
        retractedIDs = result.retractedIDs
    }

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
                self.scannedDocs = result.docs
                self.scannedDuplicates = result.duplicateIDs
                self.unreadableFiles = result.unreadable
                self.rebuild()
                self.isScanning = false
            }
        }
    }

    /// Whether a candidate document id is already spoken for — by any
    /// indexed document or by an id-named file the scanner has not read
    /// yet. The writer's side of collision honesty. (Knowledge Space's
    /// definition, kept so the travelling view modules compile.)
    func isIDTaken(_ candidate: String) -> Bool {
        if allByID[candidate] != nil { return true }
        guard let folderURL else { return false }
        return FileManager.default.fileExists(
            atPath: folderURL.appendingPathComponent(candidate)
                .appendingPathExtension(LiquidDoc.fileExtension).path)
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
        var docs: [LiquidDoc] = []
        var duplicateIDs: Set<String> = []
        var byID: [String: IndexEntry] = [:]
        var backlinks: [String: [BacklinkRef]] = [:]
        var revisionOf: [String: String] = [:]
        var retractedIDs: Set<String> = []
        var timeline: [IndexEntry] = []
        var unreadable: [UnreadableFile] = []
    }

    /// The index derivations over a set of documents, whatever fed them:
    /// id lookup, backlinks, revision chains, retractions, and the
    /// listed-date timeline.
    static func derive(docs: [LiquidDoc], duplicateIDs: Set<String> = []) -> Result {
        var result = Result()
        result.docs = docs
        result.duplicateIDs = duplicateIDs
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
        requestICloudDownloads(in: folder)
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return Result() }

        var docs: [LiquidDoc] = []
        var modificationDates: [String: Date] = [:]
        var duplicateIDs: Set<String> = []
        var unreadable: [UnreadableFile] = []

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
                unreadable.append(UnreadableFile(fileURL: url, reason: error.localizedDescription))
            }
        }

        var result = derive(docs: docs, duplicateIDs: duplicateIDs)
        result.unreadable = unreadable
        return result
    }
}
