#if os(macOS)
import Foundation

/// Annotations and reading positions shared through the community folder,
/// so a highlight made on one Mac (or iPad) is there on the next.
///
/// Per book, `_annotations/<book folder>.json` holds the annotations and
/// the ids deleted, each with when. Keyed by the book's folder — its
/// community identity — never its local id, which differs by device.
/// Every merge is per annotation, newest wins, and a deletion newer than
/// an annotation removes it: a device writing from a stale copy can
/// neither roll others back nor bring a deleted note back to life.
nonisolated enum AnnotationSync {
    struct File: Codable {
        var annotations: [WebAnnotation]
        var deleted: [String: Date]
    }

    static func directory(in community: URL) -> URL {
        community.appendingPathComponent("_annotations", isDirectory: true)
    }

    static func url(forBookFolder folder: String, in community: URL) -> URL {
        let safe = folder.replacingOccurrences(of: "/", with: "_")
        return directory(in: community).appendingPathComponent(safe + ".json")
    }

    static func read(_ url: URL) -> File? {
        var coordinated: File?
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { readURL in
            guard let data = try? Data(contentsOf: readURL) else { return }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            coordinated = try? decoder.decode(File.self, from: data)
        }
        return coordinated
    }

    static func write(_ file: File, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(file) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        var error: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &error) { writeURL in
            try? data.write(to: writeURL, options: .atomic)
        }
    }

    /// One book's annotations from two copies: per id the newer, minus
    /// any deleted after it was last changed.
    static func merge(_ a: [WebAnnotation], _ aDeleted: [String: Date],
                      _ b: [WebAnnotation], _ bDeleted: [String: Date])
        -> (annotations: [WebAnnotation], deleted: [String: Date]) {
        var deleted = aDeleted
        for (id, date) in bDeleted where date > (deleted[id] ?? .distantPast) { deleted[id] = date }
        func stamp(_ annotation: WebAnnotation) -> Date { annotation.modified ?? annotation.created }
        var byID: [String: WebAnnotation] = [:]
        for annotation in a + b {
            if let known = byID[annotation.id], stamp(known) >= stamp(annotation) { continue }
            byID[annotation.id] = annotation
        }
        let kept = byID.values
            .filter { annotation in (deleted[annotation.id].map { $0 < stamp(annotation) }) ?? true }
            .sorted { $0.created < $1.created }
        return (kept, deleted)
    }

    // MARK: Reading positions

    struct Position: Codable {
        var chapter: String?
        var fraction: Double
        var t: Date
    }

    static func positionsURL(in community: URL) -> URL {
        community.appendingPathComponent("_reading-positions.json")
    }

    static func readPositions(_ url: URL) -> [String: Position] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: Position].self, from: data)) ?? [:]
    }

    static func writePositions(_ positions: [String: Position], to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(positions) else { return }
        var error: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &error) { writeURL in
            try? data.write(to: writeURL, options: .atomic)
        }
    }
}

extension AppModel {

    /// The ids deleted from a book's annotations on this Mac, with when —
    /// so the next merge does not bring them back.
    func annotationTombstones(for address: String) -> [String: Date] {
        let raw = UserDefaults.standard.dictionary(forKey: "annotationTombstones:" + address) as? [String: Double] ?? [:]
        return raw.mapValues { Date(timeIntervalSince1970: $0) }
    }

    func setAnnotationTombstones(_ tombstones: [String: Date], for address: String) {
        UserDefaults.standard.set(tombstones.mapValues { $0.timeIntervalSince1970 },
                                  forKey: "annotationTombstones:" + address)
    }

    /// After a local save: note what was deleted, then merge with the
    /// community copy and write both — never overwriting another device's
    /// newer work.
    func shareAnnotations(_ all: [WebAnnotation], previous: [WebAnnotation], for address: String) {
        let now = Date()
        var tombstones = annotationTombstones(for: address)
        for removed in Set(previous.map(\.id)).subtracting(all.map(\.id)) { tombstones[removed] = now }
        setAnnotationTombstones(tombstones, for: address)
        guard let community = index.folderURL, let record = epubRecord(forAddress: address) else { return }
        let url = AnnotationSync.url(forBookFolder: record.folder, in: community)
        let localRoot = Self.annotationsRootURL
        Task.detached(priority: .utility) {
            let scoped = community.startAccessingSecurityScopedResource()
            defer { if scoped { community.stopAccessingSecurityScopedResource() } }
            let remote = AnnotationSync.read(url) ?? .init(annotations: [], deleted: [:])
            let merged = AnnotationSync.merge(all, tombstones, remote.annotations, remote.deleted)
            AnnotationSync.write(.init(annotations: merged.annotations, deleted: merged.deleted), to: url)
            let changedLocally = Set(merged.annotations.map(\.id)) != Set(all.map(\.id))
            if changedLocally {
                AnnotationStore.save(merged.annotations, for: address, in: localRoot)
            }
            await MainActor.run {
                self.setAnnotationTombstones(merged.deleted, for: address)
                if changedLocally { self.bumpAnnotationsStamp() }
            }
        }
    }

    /// The tick's half: community annotation files changed since last
    /// seen are merged into this Mac's sidecars.
    func adoptSyncedAnnotations() {
        guard let community = index.folderURL else { return }
        let records = epubRecords.map { (folder: $0.folder, address: $0.id) }
        let seen = syncedAnnotationDates
        let localRoot = Self.annotationsRootURL
        let tombstones = Dictionary(uniqueKeysWithValues: records.map { ($0.address, annotationTombstones(for: $0.address)) })
        Task.detached(priority: .utility) {
            let scoped = community.startAccessingSecurityScopedResource()
            defer { if scoped { community.stopAccessingSecurityScopedResource() } }
            var dates = seen
            var changed: [(address: String, deleted: [String: Date])] = []
            for record in records {
                let url = AnnotationSync.url(forBookFolder: record.folder, in: community)
                guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate,
                      modified > (seen[record.folder] ?? .distantPast),
                      let remote = AnnotationSync.read(url) else { continue }
                dates[record.folder] = modified
                let local = AnnotationStore.load(for: record.address, in: localRoot)
                let merged = AnnotationSync.merge(local, tombstones[record.address] ?? [:],
                                                  remote.annotations, remote.deleted)
                if merged.annotations != local {
                    AnnotationStore.save(merged.annotations, for: record.address, in: localRoot)
                }
                changed.append((record.address, merged.deleted))
            }
            // Reading positions ride the same beat.
            let positions = AnnotationSync.readPositions(AnnotationSync.positionsURL(in: community))
            await MainActor.run {
                self.syncedAnnotationDates = dates
                for entry in changed { self.setAnnotationTombstones(entry.deleted, for: entry.address) }
                if !changed.isEmpty { self.bumpAnnotationsStamp() }
                self.sharedReadingPositions = positions
            }
        }
    }

    /// Queues this Mac's reading positions for the community file — at
    /// most one write every eight seconds, however fast the page scrolls.
    func scheduleSharedPositionWrite() {
        guard let community = index.folderURL, positionWriteTask == nil else { return }
        positionWriteTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self else { return }
            let local = self.localReadingPositions()
            self.positionWriteTask = nil
            Task.detached(priority: .utility) {
                let scoped = community.startAccessingSecurityScopedResource()
                defer { if scoped { community.stopAccessingSecurityScopedResource() } }
                let url = AnnotationSync.positionsURL(in: community)
                var merged = AnnotationSync.readPositions(url)
                for (folder, position) in local where position.t > (merged[folder]?.t ?? .distantPast) {
                    merged[folder] = position
                }
                AnnotationSync.writePositions(merged, to: url)
            }
        }
    }
}
#endif
