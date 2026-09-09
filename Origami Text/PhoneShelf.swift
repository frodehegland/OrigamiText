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
        // Self-healing: a record whose unpacked payload has vanished
        // (reinstall, cleared storage) would open as a silent blank
        // page — prune it instead; the book returns the next time its
        // EPUB is opened or the community folder is scanned.
        let alive = records.filter { record in
            FileManager.default.fileExists(
                atPath: epubsRoot.appendingPathComponent(record.folder, isDirectory: true)
                    .appendingPathComponent(record.contentSubpath).path)
        }
        if alive.count != records.count, let pruned = try? JSONEncoder().encode(alive) {
            UserDefaults.standard.set(pruned, forKey: epubRecordsKey)
        }
        return alive
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
        // Files often hands over an iCloud item that is not local yet:
        // a coordinated read forces the download and yields readable
        // bytes; the import then works from a local copy.
        let local = FileManager.default.temporaryDirectory
            .appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: local)
        var coordinationError: NSError?
        var copied = false
        NSFileCoordinator().coordinate(readingItemAt: url, options: [],
                                       error: &coordinationError) { readURL in
            copied = (try? FileManager.default.copyItem(at: readURL, to: local)) != nil
        }
        let source = copied ? local : url
        let changed = importEPUB(at: source)
        if copied { try? FileManager.default.removeItem(at: local) }
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
        // A book opened as a file starts on Scroll — the whole text,
        // one clean column — whatever reading view was last in use.
        // Shelf opens keep the reader's last view.
        UserDefaults.standard.set("scroll", forKey: "phoneReaderMode")
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
        for record in epubRecords where !isSetAside(record) {
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
        pinnedFirst(epubRecords.filter {
            $0.venue?.caseInsensitiveCompare(venue) == .orderedSame
                && !isSetAside($0)
        })
    }

    var alphabetical: [EPUBRecord] {
        pinnedFirst(epubRecords.filter { !isSetAside($0) }.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        })
    }

    // MARK: - Top of Pile and Set Aside

    /// The Mac's pile, here: pinned books lead every list; set-aside
    /// books wait out of them until brought back. Same UserDefaults
    /// keys, and the standing travels through the community folder's
    /// origami-standing.json — last writer wins, as on the Mac and the
    /// headset (AppModel's is the sibling copy; keep in step).
    private(set) var epubTopOfPile: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: "epubTopOfPile") ?? [])
    private(set) var epubSetAsideIDs: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: "epubSetAside") ?? [])
    /// Concepts ride the same shared file (a Mac feature); the phone
    /// carries them through untouched so a publish never clobbers them.
    @ObservationIgnored private var standingConcepts: [String]?
    /// When this device last wrote the shared standing — an older file
    /// read back never clobbers a newer local change.
    @ObservationIgnored private var standingWrittenAt: Date = .distantPast

    func isTopOfPile(_ record: EPUBRecord) -> Bool { epubTopOfPile.contains(record.id) }
    func isSetAside(_ record: EPUBRecord) -> Bool { epubSetAsideIDs.contains(record.id) }

    func toggleTopOfPile(_ record: EPUBRecord) {
        if !epubTopOfPile.insert(record.id).inserted { epubTopOfPile.remove(record.id) }
        UserDefaults.standard.set(epubTopOfPile.sorted(), forKey: "epubTopOfPile")
        publishStanding()
    }

    func setAside(_ record: EPUBRecord) {
        epubSetAsideIDs.insert(record.id)
        UserDefaults.standard.set(epubSetAsideIDs.sorted(), forKey: "epubSetAside")
        publishStanding()
    }

    func bringBack(_ record: EPUBRecord) {
        epubSetAsideIDs.remove(record.id)
        UserDefaults.standard.set(epubSetAsideIDs.sorted(), forKey: "epubSetAside")
        publishStanding()
    }

    /// Top of Pile first, otherwise keeping the given order — the Mac's.
    func pinnedFirst(_ records: [EPUBRecord]) -> [EPUBRecord] {
        records.filter { isTopOfPile($0) } + records.filter { !isTopOfPile($0) }
    }

    /// The Set Aside shelf's records, in library order.
    var setAsideRecords: [EPUBRecord] {
        epubRecords.filter { epubSetAsideIDs.contains($0.id) }
    }

    // MARK: - Annotations (the reader's highlights and notes)

    /// Sidecars live in one folder beside the unpacked books, keyed by
    /// book address, exactly the Mac's layout (AppModel's annotations
    /// section is the sibling copy; keep in step). The book itself is
    /// never modified — the book is the author's; the annotations are
    /// the reader's.
    static var annotationsRoot: URL {
        epubsRoot.appendingPathComponent("Annotations", isDirectory: true)
    }

    /// Bumped whenever a book's annotations change, so the reader
    /// repaints its highlights.
    private(set) var annotationsStamp = 0

    /// One live selection in the reader: the book, the paragraph, and
    /// the exact words with their disambiguating neighbours.
    struct ReaderSelection {
        let address: String
        let paragraphID: String?
        let text: String
        let prefix: String?
        let suffix: String?
    }

    /// Every annotation on the given book, oldest first.
    func annotations(forAddress address: String) -> [WebAnnotation] {
        AnnotationStore.load(for: address, in: Self.annotationsRoot)
    }

    /// Stamps one of the reader's judgments (Important, Disagree, …) on
    /// the selection — a W3C tagging annotation; plain Highlight carries
    /// no tag body.
    func addTag(_ kind: ReaderAnnotationKind, on selection: ReaderSelection) {
        if kind == .highlight {
            addAnnotation(motivation: WebAnnotation.Motivation.highlighting,
                          note: nil, on: selection)
        } else {
            addAnnotation(motivation: WebAnnotation.Motivation.tagging,
                          note: kind.rawValue, purpose: "tagging", on: selection)
        }
    }

    /// Attaches the reader's note to the selection.
    func addComment(_ note: String, on selection: ReaderSelection) {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        addAnnotation(motivation: WebAnnotation.Motivation.commenting,
                      note: trimmed, on: selection)
    }


    /// Clears the highlights and judgments on one paragraph whose quoted
    /// words satisfy `matches` — the Highlight submenu's eraser. Notes
    /// are left standing; they have words of their own to lose.
    func removeAnnotations(inParagraph paragraphID: String?, at address: String,
                           where matches: (String) -> Bool) {
        var all = AnnotationStore.load(for: address, in: Self.annotationsRoot)
        let before = all.count
        all.removeAll { annotation in
            guard annotation.motivation == WebAnnotation.Motivation.highlighting
                || annotation.motivation == WebAnnotation.Motivation.tagging
            else { return false }
            var fragment: String?
            var quote: String?
            for selector in annotation.target.selectors {
                switch selector {
                case .fragment(let value, _): fragment = fragment ?? value
                case .quote(let exact, _, _): quote = quote ?? exact
                default: break
                }
            }
            if let fragment, let paragraphID, fragment != paragraphID { return false }
            guard let quote else { return false }
            return matches(quote)
        }
        guard all.count != before else { return }
        AnnotationStore.save(all, for: address, in: Self.annotationsRoot)
        annotationsStamp += 1
    }

    /// The reader's one note describing the whole document — a
    /// "describing" annotation with no selectors, one per book. The
    /// Mac's documentAnnotation is the sibling; keep in step.
    func documentNote(forAddress address: String) -> WebAnnotation? {
        _ = annotationsStamp
        return AnnotationStore.load(for: address, in: Self.annotationsRoot).first {
            $0.motivation == WebAnnotation.Motivation.describing
                && $0.target.selectors.isEmpty
        }
    }

    /// Writes or rewrites the document note; empty text removes it.
    func setDocumentNote(_ text: String, forAddress address: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var all = AnnotationStore.load(for: address, in: Self.annotationsRoot)
        if let index = all.firstIndex(where: {
            $0.motivation == WebAnnotation.Motivation.describing
                && $0.target.selectors.isEmpty
        }) {
            if trimmed.isEmpty {
                all.remove(at: index)
            } else {
                all[index].body = WebAnnotation.TextualBody(value: trimmed,
                                                            purpose: "describing")
                all[index].modified = .now
            }
        } else {
            guard !trimmed.isEmpty else { return }
            let name = UserDefaults.standard.string(forKey: "authorName") ?? "Reader"
            all.append(WebAnnotation(
                motivation: WebAnnotation.Motivation.describing,
                creator: WebAnnotation.Person(name: name),
                body: WebAnnotation.TextualBody(value: trimmed, purpose: "describing"),
                target: WebAnnotation.Target(source: "origamitext://open/" + address,
                                             selectors: [])))
        }
        AnnotationStore.save(all, for: address, in: Self.annotationsRoot)
        annotationsStamp += 1
    }

    private func addAnnotation(motivation: String, note: String?,
                               purpose: String? = nil, on selection: ReaderSelection) {
        guard !selection.text.isEmpty else { return }
        // The anchoring ladder, most robust first: the paragraph's
        // stable id, then the exact words with disambiguating context.
        var selectors: [WebAnnotation.Selector] = []
        if let fragment = selection.paragraphID, !fragment.isEmpty {
            selectors.append(.fragment(value: fragment,
                                       conformsTo: WebAnnotation.fragmentConformsTo))
        }
        selectors.append(.quote(exact: selection.text,
                                prefix: selection.prefix?.isEmpty == false ? selection.prefix : nil,
                                suffix: selection.suffix?.isEmpty == false ? selection.suffix : nil))
        let name = UserDefaults.standard.string(forKey: "authorName") ?? "Reader"
        let annotation = WebAnnotation(
            motivation: motivation,
            creator: WebAnnotation.Person(name: name),
            body: note.map { WebAnnotation.TextualBody(value: $0, purpose: purpose) },
            target: WebAnnotation.Target(source: "origamitext://open/" + selection.address,
                                         selectors: selectors))
        var all = AnnotationStore.load(for: selection.address, in: Self.annotationsRoot)
        all.append(annotation)
        AnnotationStore.save(all, for: selection.address, in: Self.annotationsRoot)
        annotationsStamp += 1
    }

    /// Writes the pinned/set-aside standing into the community folder,
    /// so the Mac and the headset adopt it.
    private func publishStanding() {
        guard let folder = folderURL else { return }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        // Concepts are the Mac's; pass through what the file holds when
        // this phone has not read it yet.
        let concepts = standingConcepts ?? EPUBStanding.read(from: folder)?.concepts ?? []
        standingConcepts = concepts
        standingWrittenAt = EPUBStanding.write(pinned: epubTopOfPile,
                                               setAside: epubSetAsideIDs,
                                               concepts: concepts,
                                               to: folder)
    }

    /// Adopts the shared standing when another device wrote it more
    /// recently than this phone did. Callers hold the folder's scope.
    private func adoptStanding(from folder: URL) {
        guard let state = EPUBStanding.read(from: folder),
              state.modified > standingWrittenAt else { return }
        standingWrittenAt = state.modified
        if let concepts = state.concepts { standingConcepts = concepts }
        epubTopOfPile = Set(state.pinned)
        epubSetAsideIDs = Set(state.setAside)
        UserDefaults.standard.set(epubTopOfPile.sorted(), forKey: "epubTopOfPile")
        UserDefaults.standard.set(epubSetAsideIDs.sorted(), forKey: "epubSetAside")
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
        adoptStanding(from: folder)
        LibraryScanner.requestICloudDownloads(in: folder)
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsPackageDescendants]) else { return }
        var changed = false
        var placeholdersRemain = false
        var present: Set<String> = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if name.hasSuffix(".icloud"), name.contains(".epub") {
                placeholdersRemain = true
                // Undownloaded is not removed: a placeholder's book
                // counts as present, so nothing retires mid-sync.
                var trimmed = name
                if trimmed.hasPrefix(".") { trimmed.removeFirst() }
                trimmed = String(trimmed.dropLast(".icloud".count))
                if trimmed.lowercased().hasSuffix(".epub") {
                    present.insert(EPUBSupersession.folderName(
                        forFileName: String(trimmed.dropLast(".epub".count))))
                }
                continue
            }
            guard url.pathExtension.lowercased() == "epub" else { continue }
            present.insert(EPUBSupersession.folderName(
                forFileName: url.deletingPathExtension().lastPathComponent))
            if importEPUB(at: url) { changed = true }
        }
        retireSuperseded(presentFolders: present)
        if changed { rebuildEPUBIndex() }
        if placeholdersRemain {
            Task {
                try? await Task.sleep(for: .seconds(8))
                scanFolderForEPUBs()
            }
        }
    }

    /// A re-published edition supersedes the old copy (see
    /// EPUBSupersession): standing and annotations move to the
    /// successor; the old unpack and record leave the shelf.
    private func retireSuperseded(presentFolders: Set<String>) {
        let retirements = EPUBSupersession.retirements(
            records: epubRecords, presentFolders: presentFolders)
        guard !retirements.isEmpty else { return }
        for (old, successor) in retirements {
            let oldSidecar = Self.annotationsRoot
                .appendingPathComponent(old.id + ".annotations.jsonld")
            let newSidecar = Self.annotationsRoot
                .appendingPathComponent(successor.id + ".annotations.jsonld")
            if FileManager.default.fileExists(atPath: oldSidecar.path),
               !FileManager.default.fileExists(atPath: newSidecar.path) {
                try? FileManager.default.moveItem(at: oldSidecar, to: newSidecar)
            }
            if epubTopOfPile.remove(old.id) != nil { epubTopOfPile.insert(successor.id) }
            if epubSetAsideIDs.remove(old.id) != nil { epubSetAsideIDs.insert(successor.id) }
            try? FileManager.default.removeItem(
                at: Self.epubsRoot.appendingPathComponent(old.folder, isDirectory: true))
            epubRecords.removeAll { $0.id == old.id }
        }
        UserDefaults.standard.set(epubTopOfPile.sorted(), forKey: "epubTopOfPile")
        UserDefaults.standard.set(epubSetAsideIDs.sorted(), forKey: "epubSetAside")
        persistEPUBRecords()
        rebuildEPUBIndex()
    }
}
