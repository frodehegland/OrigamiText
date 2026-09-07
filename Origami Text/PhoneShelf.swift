import SwiftUI

// The phone's EPUB shelf: the visionOS shelf core brought over whole —
// keep the two in step (OrigamiVision.swift, VisionModel's shelf
// section, is the sibling copy). Books arrive three ways, all
// on-device: opened from Files, picked with Open EPUB…, or scanned
// from the community folder the Letters tab already knows. Each book
// keeps its canonical .epub beside its unpacked cache, the same layout
// as the Mac and the headset.

@MainActor @Observable
final class PhoneModel {

    private(set) var epubRecords: [EPUBRecord] = PhoneModel.loadEPUBRecords()
    let index = LibraryIndex()
    /// The book the reader shows, pushed by the shelf or a file open.
    var readerRecordID: String?
    private(set) var folderURL: URL?

    init() {
        restoreFolder()
        rebuildEPUBIndex()
    }

    // MARK: The store

    /// Where books unpack: one folder per identity, reused forever —
    /// the canonical `<identity>.epub` beside each.
    static var epubsRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let root = base.appendingPathComponent("EPUBs", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static let epubRecordsKey = "epubRecords"

    private static func loadEPUBRecords() -> [EPUBRecord] {
        guard let data = UserDefaults.standard.data(forKey: epubRecordsKey),
              let records = try? JSONDecoder().decode([EPUBRecord].self, from: data)
        else { return [] }
        return records
    }

    private func persistEPUBRecords() {
        guard let data = try? JSONEncoder().encode(epubRecords) else { return }
        UserDefaults.standard.set(data, forKey: Self.epubRecordsKey)
    }

    // MARK: Import

    /// Unpacks one EPUB into the shelf (once per identity) and remembers
    /// it. Metadata only — no body parsing, so a large book never stalls
    /// the import; the index parses bodies later, off the main thread.
    @discardableResult
    func importEPUB(at url: URL) -> Bool {
        let name = url.deletingPathExtension().lastPathComponent
        let identity = LiquidDoc.identityKeyID(inFileName: name) ?? name
        let safe = identity.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let directory = Self.epubsRoot.appendingPathComponent(safe, isDirectory: true)

        if let existing = epubRecords.first(where: { $0.folder == safe }) {
            let content = directory.appendingPathComponent(existing.contentSubpath)
            let sourceStamp = (try? url.resourceValues(
                forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let unpackedStamp = (try? content.resourceValues(
                forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if FileManager.default.fileExists(atPath: content.path),
               let sourceStamp, let unpackedStamp, sourceStamp <= unpackedStamp {
                return false
            }
        }

        do {
            let unpacked = try OrigamiEPUBImporter.unpack(at: url, into: directory)
            // The .epub itself is the canonical store, kept beside the
            // unpacked cache — same layout as the Mac and the headset.
            let stored = Self.epubsRoot.appendingPathComponent(safe + ".epub")
            if stored.path != url.path {
                try? FileManager.default.removeItem(at: stored)
                try? FileManager.default.copyItem(at: url, to: stored)
            }
            let meta = OrigamiEPUBImporter.importMetadata(inUnpackedFolder: directory)
            let bookID = meta.origamiID ?? identity
            let contentSubpath = unpacked.content.path
                .replacingOccurrences(of: directory.path + "/", with: "")
            let authors = meta.authors
            let record = EPUBRecord(id: bookID, title: unpacked.title,
                                    author: authors.count > 1
                                        ? authors.joined(separator: ", ")
                                        : (authors.first ?? meta.author ?? "Unknown"),
                                    authors: authors.isEmpty ? nil : authors,
                                    dateISO: meta.date, folder: safe,
                                    contentSubpath: contentSubpath, openedAt: .now,
                                    publication: meta.publication ?? "")
            epubRecords.removeAll { $0.id == bookID || $0.folder == safe }
            epubRecords.insert(record, at: 0)
            persistEPUBRecords()
            return true
        } catch {
            return false
        }
    }

    /// Opens one EPUB handed to the app — Files' Open In, a share, or
    /// Open EPUB…. Imported (or recognised), parsed alone off the main
    /// thread so the reader opens at once, and answered with its record.
    func openEPUBFile(at url: URL) async -> EPUBRecord? {
        let scoped = url.startAccessingSecurityScopedResource()
        let changed = importEPUB(at: url)
        if scoped { url.stopAccessingSecurityScopedResource() }
        let name = url.deletingPathExtension().lastPathComponent
        let identity = LiquidDoc.identityKeyID(inFileName: name) ?? name
        let safe = identity.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        guard let record = epubRecords.first(where: { $0.folder == safe }) else { return nil }
        let base = Self.epubsRoot.appendingPathComponent(record.folder, isDirectory: true)
        let staged = record
        let doc: LiquidDoc? = await Task.detached(priority: .userInitiated) {
            guard let result = try? OrigamiEPUBImporter.importDocument(
                inUnpackedFolder: base) else { return nil }
            return Self.structuredDoc(from: result, record: staged, base: base)
        }.value
        if let doc { index.upsertEPUBDocument(doc) }
        if changed { rebuildEPUBIndex() }
        // A book opened as a file starts on Default — the EPUB's own
        // page — whatever reading view was last in use, as on the
        // headset. Shelf opens keep the reader's last view.
        UserDefaults.standard.set("faithful", forKey: "phoneReaderMode")
        return record
    }

    // MARK: The index

    /// Every shelf book re-imported as a structured document and merged
    /// into the index — the reader reads from there. A newer rebuild
    /// supersedes an older one mid-flight.
    private var epubIndexGeneration = 0
    func rebuildEPUBIndex() {
        epubIndexGeneration += 1
        let generation = epubIndexGeneration
        let records = epubRecords
        let root = Self.epubsRoot
        Task.detached(priority: .utility) {
            var docs: [LiquidDoc] = []
            for record in records {
                let base = root.appendingPathComponent(record.folder, isDirectory: true)
                guard let result = try? OrigamiEPUBImporter.importDocument(
                    inUnpackedFolder: base) else { continue }
                docs.append(Self.structuredDoc(from: result, record: record, base: base))
            }
            let built = docs
            await MainActor.run {
                guard generation == self.epubIndexGeneration else { return }
                self.index.setEPUBDocuments(built)
            }
        }
    }

    /// One imported package as the index's document — the Mac's
    /// structuredDoc, kept in step.
    nonisolated private static func structuredDoc(
        from result: OrigamiEPUBImporter.ImportResult,
        record: EPUBRecord, base: URL) -> LiquidDoc {
        let address = record.id
        let created = (record.dateISO ?? result.date).flatMap(LiquidDoc.parseISO8601)
            ?? record.openedAt
        var doc = LiquidDoc(format: LiquidDoc.knownFormat,
                            id: address,
                            title: result.title,
                            author: result.author ?? record.author,
                            created: created,
                            body: result.body,
                            links: result.links,
                            wraps: nil,
                            fileURL: base)
        doc.date = (record.dateISO ?? result.date).flatMap(LiquidDate.init(isoString:))
        doc.documentType = LiquidDoc.DocumentType.book.rawValue
        doc.publication = result.publication ?? record.publication
        doc.concepts = result.concepts
        doc.references = result.references
        doc.tables = result.tables
        doc.assets = result.assets
        return doc
    }

    // MARK: Shelves

    /// The venues the shelf's books declare, most-stocked first.
    var venues: [String] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for record in epubRecords {
            guard let venue = record.venue else { continue }
            if counts[venue] == nil { order.append(venue) }
            counts[venue, default: 0] += 1
        }
        return order.sorted {
            let a = counts[$0] ?? 0
            let b = counts[$1] ?? 0
            if a != b { return a > b }
            return $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    func records(inVenue venue: String) -> [EPUBRecord] {
        epubRecords.filter {
            $0.venue?.caseInsensitiveCompare(venue) == .orderedSame
        }
    }

    var alphabetical: [EPUBRecord] {
        epubRecords.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    // MARK: The community folder

    /// The Letters tab's folder choice, shared: one bookmark key, so
    /// choosing the community folder anywhere serves both shelves.
    private static let bookmarkKey = "communityFolderBookmark"

    func openFolder(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let bookmark = try? url.bookmarkData() {
            UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
        }
        folderURL = url
        scanFolderForEPUBs()
    }

    private func restoreFolder() {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale)
        else { return }
        folderURL = url
    }

    /// Imports every EPUB in the community folder — new arrivals unpack
    /// and join the shelf. iCloud placeholders are nudged to download;
    /// while any remain, the scan tries again shortly.
    func scanFolderForEPUBs() {
        guard let folder = folderURL else { return }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        LibraryScanner.requestICloudDownloads(in: folder)
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsPackageDescendants]) else { return }
        var changed = false
        var placeholdersRemain = false
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if name.hasSuffix(".icloud"), name.contains(".epub") {
                placeholdersRemain = true
                continue
            }
            guard url.pathExtension.lowercased() == "epub" else { continue }
            if importEPUB(at: url) { changed = true }
        }
        if changed { rebuildEPUBIndex() }
        if placeholdersRemain {
            Task {
                try? await Task.sleep(for: .seconds(8))
                scanFolderForEPUBs()
            }
        }
    }
}
