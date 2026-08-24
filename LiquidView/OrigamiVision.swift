#if os(visionOS)
import SwiftUI
import RealityKit
import UniformTypeIdentifiers
import FoundationModels
import os

/// Origami Text for visionOS — the same app (one bundle id, one App Store
/// listing), the same library. The session is not a document but the
/// community folder on iCloud, so everything published from the Mac is
/// instantly present here; nothing is exported, nothing goes stale.
@main
struct OrigamiVisionApp: App {
    @State private var model = VisionModel()

    // SwiftUI.Scene spelled out: RealityKit (the arm menus) brings its
    // own Scene type into the file.
    var body: some SwiftUI.Scene {
        // The opening panel: Articles and Journals, nothing else — tap a
        // journal and its articles fill the space. The original documents
        // panel and Settings ride the arm menus.
        WindowGroup(id: "library") {
            VisionOpeningView()
                .environment(model)
        }
        .defaultSize(width: 560, height: 720)

        // The original documents panel — the letters timeline with the
        // volumes toolbar — opened from the right arm's Documents chip.
        WindowGroup(id: "documents") {
            VisionLibraryView()
                .environment(model)
        }
        .defaultSize(width: 560, height: 720)

        // Settings, opened from the right arm's Settings chip.
        WindowGroup(id: "settings") {
            VisionSettingsView()
                .environment(model)
        }
        .defaultSize(width: 460, height: 520)

        // The one immersive space (mixed, so windows and volumes share
        // the room): the Map — Author's engine with EPUBs as nodes —
        // which hosts the arm menus itself, Author's way. (The arm-only
        // OrigamiSpaceView remains below, one line to swap back if the
        // Map misbehaves on device.)
        ImmersiveSpace(id: "arms") {
            EPUBMapView()
                .environment(model)
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)

        // The Knowledge Space: a volume, Author-Map logic — an essentially
        // 2D arrangement whose cards the hand can pull and push in Z.
        WindowGroup(id: "space") {
            KnowledgeSpaceView()
                .environment(model)
        }
        .windowStyle(.volumetric)
        .defaultSize(width: 1.6, height: 1.1, depth: 0.7, in: .meters)

        // The authors of the library as cards in a volume — the circle,
        // spatialized, on the same Map mechanics as the Knowledge Space.
        WindowGroup(id: "authors") {
            AuthorsSpaceView()
                .environment(model)
        }
        .windowStyle(.volumetric)
        .defaultSize(width: 1.6, height: 1.1, depth: 0.7, in: .meters)

        // The Weave in a volume: knots on the wheel order, threads shading
        // between their authors' colors, every knot the hand's to move.
        WindowGroup(id: "weave") {
            VisionWeaveView()
                .environment(model)
        }
        .windowStyle(.volumetric)
        .defaultSize(width: 1.6, height: 1.1, depth: 0.7, in: .meters)

        // Bots: famous readers judging the library, their verdicts on the
        // document cards, the cards the hand's to move.
        WindowGroup(id: "bots") {
            VisionBotsView()
                .environment(model)
        }
        .windowStyle(.volumetric)
        .defaultSize(width: 1.6, height: 1.1, depth: 0.7, in: .meters)

        WindowGroup(id: "reader", for: String.self) { $docID in
            VisionReaderView(docID: docID ?? "")
                .environment(model)
        }
        .defaultSize(width: 660, height: 840)

        // The journal's articles live in the immersive space itself (see
        // JournalFieldSpace below) — the full room, not a volume.

        // zzStructure navigation in a volume: the bound Z dimension is
        // literal depth — posward recedes, negward approaches.
        WindowGroup(id: "zz") {
            VisionZZView()
                .environment(model)
        }
        .windowStyle(.volumetric)
        .defaultSize(width: 1.5, height: 1.0, depth: 0.7, in: .meters)
    }
}

/// visionOS session state: the same LibraryIndex the Mac uses, plus a
/// folder bookmark that survives relaunch. Rescans happen on demand and
/// when a scene returns to the foreground (no FSEvents here). The EPUB
/// shelf mirrors the Mac's: books found in the community folder are
/// unpacked once under Application Support/EPUBs, remembered as
/// EPUBRecords, and re-imported as structured documents into the index —
/// so the reader, the volumes, and the journals all see them.
@MainActor @Observable
final class VisionModel {
    let index = LibraryIndex()
    let bots = VisionBotStore()
    private static let bookmarkKey = "communityFolderBookmark"

    init() {
        restoreFolder()
        rebuildEPUBIndex()
    }

    func openFolder(_ url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        if let bookmark = try? url.bookmarkData() {
            UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
        }
        index.setFolder(url)
        scanFolderForEPUBs()
    }

    private func restoreFolder() {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale),
              url.startAccessingSecurityScopedResource() else { return }
        index.setFolder(url)
        scanFolderForEPUBs()
    }

    // MARK: - The EPUB shelf

    /// The remembered books, newest first — the Mac's manifest, kept here
    /// in this device's own defaults.
    private(set) var epubRecords: [EPUBRecord] = VisionModel.loadEPUBRecords()

    /// The journal whose articles stand on the Map right now — set by
    /// the opening panel, nil puts the Map back to rest. One journal at
    /// a time; opening another replaces the nodes.
    var openJournalVenue: String?

    /// The documents open in reader windows right now. A card leaves
    /// the Map while its article is being read, and returns when the
    /// reader closes — the book is in the hand, not on the table.
    var openDocIDs: Set<String> = []

    /// Pinned books stand first on the Map — the Mac's Pin, here. Kept
    /// in this device's own defaults, under the Mac's key names.
    private(set) var pinnedIDs: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: "epubTopOfPile") ?? [])

    /// Set Aside books collapse to a quiet title-row beneath the others.
    private(set) var setAsideIDs: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: "epubSetAside") ?? [])

    func togglePinned(_ id: String) {
        if pinnedIDs.remove(id) == nil { pinnedIDs.insert(id) }
        UserDefaults.standard.set(pinnedIDs.sorted(), forKey: "epubTopOfPile")
        publishStanding()
    }

    func toggleSetAside(_ id: String) {
        if setAsideIDs.remove(id) == nil { setAsideIDs.insert(id) }
        UserDefaults.standard.set(setAsideIDs.sorted(), forKey: "epubSetAside")
        publishStanding()
    }

    /// When this device last wrote the shared standing file — an older
    /// file read back never clobbers a newer local change.
    @ObservationIgnored private var standingWrittenAt: Date = .distantPast

    /// Pin and Set Aside travel through the community folder, so the
    /// Mac and this device agree on the pile.
    private func publishStanding() {
        guard let folder = index.folderURL else { return }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        standingWrittenAt = EPUBStanding.write(pinned: pinnedIDs,
                                               setAside: setAsideIDs,
                                               to: folder)
    }

    /// Adopts the shared standing when another device wrote it more
    /// recently than this one did.
    func adoptStanding() {
        guard let folder = index.folderURL else { return }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        guard let state = EPUBStanding.read(from: folder),
              state.modified > standingWrittenAt else { return }
        standingWrittenAt = state.modified
        pinnedIDs = Set(state.pinned)
        setAsideIDs = Set(state.setAside)
        UserDefaults.standard.set(pinnedIDs.sorted(), forKey: "epubTopOfPile")
        UserDefaults.standard.set(setAsideIDs.sorted(), forKey: "epubSetAside")
    }

    /// The pinned books simply first, order otherwise kept — the Mac's
    /// pinnedFirst.
    func pinnedFirstRecords(_ records: [EPUBRecord]) -> [EPUBRecord] {
        records.filter { pinnedIDs.contains($0.id) }
            + records.filter { !pinnedIDs.contains($0.id) }
    }


    /// Where books unpack: one folder per identity, reused forever.
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

    /// The venues the shelf's books declare, most-stocked first — the
    /// opening window's journals.
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

    /// Imports every EPUB in the community folder — new arrivals unpack
    /// and join the shelf; books already unpacked are left as they
    /// stand. The folder usually lives in iCloud, so files another
    /// device published may exist here only as placeholders: those are
    /// nudged to download first, and while any remain, the scan tries
    /// again shortly — there is no folder watcher on this platform.
    func scanFolderForEPUBs() {
        guard let folder = index.folderURL else { return }
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
        adoptStanding()
        if placeholdersRemain, scanRetries < 5 {
            scanRetries += 1
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(6))
                self.scanFolderForEPUBs()
            }
        } else if !placeholdersRemain {
            scanRetries = 0
        }
    }

    /// Downloads in flight are retried a few times, never forever.
    @ObservationIgnored private var scanRetries = 0

    /// Unpacks one EPUB into the shelf (once per identity) and remembers
    /// it. Returns whether the shelf changed. The Mac's importEPUB,
    /// without the reader-side niceties.
    @discardableResult
    func importEPUB(at url: URL) -> Bool {
        let name = url.deletingPathExtension().lastPathComponent
        let identity = LiquidDoc.identityKeyID(inFileName: name) ?? name
        let safe = identity.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let directory = Self.epubsRoot.appendingPathComponent(safe, isDirectory: true)

        if let existing = epubRecords.first(where: { $0.folder == safe }),
           FileManager.default.fileExists(atPath:
                directory.appendingPathComponent(existing.contentSubpath).path) {
            return false
        }

        do {
            let unpacked = try OrigamiEPUBImporter.unpack(at: url, into: directory)
            let meta = try? OrigamiEPUBImporter.importDocument(at: url)
            let bookID = meta?.origamiID ?? identity
            let contentSubpath = unpacked.content.path
                .replacingOccurrences(of: directory.path + "/", with: "")
            let authors = meta?.authors ?? []
            let record = EPUBRecord(id: bookID, title: unpacked.title,
                                    author: authors.count > 1
                                        ? authors.joined(separator: ", ")
                                        : (authors.first ?? meta?.author ?? "Unknown"),
                                    authors: authors.isEmpty ? nil : authors,
                                    dateISO: meta?.date, folder: safe,
                                    contentSubpath: contentSubpath, openedAt: .now,
                                    publication: meta?.publication ?? "")
            epubRecords.removeAll { $0.id == bookID || $0.folder == safe }
            epubRecords.insert(record, at: 0)
            persistEPUBRecords()
            return true
        } catch {
            return false
        }
    }

    /// Every shelf book re-imported as a structured document and merged
    /// into the index — the reader, the spaces, and the threads all read
    /// from there. A newer rebuild supersedes an older one mid-flight.
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

    /// The import result joined with the record's metadata — kept in
    /// step with AppModel.structuredDoc on the Mac.
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
        doc.layouts = result.layouts
        doc.mapConnections = result.mapConnections
        doc.references = result.references
        doc.tables = result.tables
        doc.assets = result.assets
        return doc
    }
}

/// The library window: choose the community folder once, then the list.
struct VisionLibraryView: View {
    @Environment(VisionModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase
    @State private var choosingFolder = false
    @State private var showingTranscriptsOnly = false

    /// The same rule as the Mac's Transcripts view: declared `transcript`,
    /// or (for documents from before the type existed) at least two
    /// distinct speaker attributions.
    private func isTranscript(_ doc: LiquidDoc) -> Bool {
        if doc.documentType == LiquidDoc.DocumentType.transcript.rawValue { return true }
        return Set((doc.body ?? []).compactMap(\.speaker)).count >= 2
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.index.folderURL == nil {
                    ContentUnavailableView {
                        Label("No Community Folder", systemImage: "folder")
                    } description: {
                        Text("Choose the iCloud folder your community shares. Everything published from your Mac appears here instantly.")
                    } actions: {
                        Button("Choose Folder…") { choosingFolder = true }
                    }
                } else {
                    documentList(transcriptsOnly: showingTranscriptsOnly)
                        .safeAreaInset(edge: .top) {
                            Picker("Showing", selection: $showingTranscriptsOnly) {
                                Text("Library").tag(false)
                                Text("Transcripts").tag(true)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .padding(.horizontal)
                            .padding(.vertical, 6)
                        }
                }
            }
            .toolbar {
                ToolbarItemGroup {
                    Button {
                        choosingFolder = true
                    } label: {
                        Label("Choose Folder", systemImage: "folder")
                    }
                    Button {
                        openWindow(id: "space")
                    } label: {
                        Label("Documents", systemImage: "doc.text")
                    }
                    .disabled(model.index.folderURL == nil)
                    Button {
                        openWindow(id: "authors")
                    } label: {
                        Label("Authors", systemImage: "person.2")
                    }
                    .disabled(model.index.folderURL == nil)
                    Button {
                        openWindow(id: "weave")
                    } label: {
                        Label("The Weave", systemImage: "asterisk")
                    }
                    .disabled(model.index.folderURL == nil)
                    Button {
                        openWindow(id: "bots")
                    } label: {
                        Label("Bots", systemImage: "brain.head.profile")
                    }
                    .disabled(model.index.folderURL == nil)
                    Button {
                        openWindow(id: "zz")
                    } label: {
                        Label("zzStructure", systemImage: "circle.grid.cross")
                    }
                }
            }
        }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.openFolder(url) }
        }
        .onChange(of: scenePhase) {
            if scenePhase == .active {
                model.index.rescan()
                model.scanFolderForEPUBs()
            }
        }
    }

    /// The Library and Transcripts tabs: the timeline, newest first.
    private func documentList(transcriptsOnly: Bool) -> some View {
        let entries = model.index.timeline.reversed()
            .filter { !transcriptsOnly || isTranscript($0.doc) }
        return List(entries) { entry in
            Button {
                openWindow(id: "reader", value: entry.doc.id)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.doc.title)
                        .lineLimit(1)
                    Text("\(entry.doc.displayAuthor) · \(entry.doc.listedDateText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// The opening panel: two tabs and nothing else. Journals lists every
/// venue on the shelf — tap one and its articles fill the space.
/// Articles is every article, alphabetically. The original documents
/// panel and Settings ride the right arm's chips (ArmMenuSpace).
struct VisionOpeningView: View {
    @Environment(VisionModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.scenePhase) private var scenePhase
    @State private var choosingFolder = false
    @State private var shelf: Shelf = .journals

    private enum Shelf: Hashable { case articles, journals }

    var body: some View {
        Group {
            // Books already on the shelf show even before a community
            // folder is chosen — the folder feeds the shelf, it does not
            // gate it.
            if model.index.folderURL == nil, model.epubRecords.isEmpty {
                ContentUnavailableView {
                    Label("No Community Folder", systemImage: "folder")
                } description: {
                    Text("Choose the iCloud folder your community shares. Everything published from your Mac appears here instantly.")
                } actions: {
                    Button("Choose Folder…") { choosingFolder = true }
                }
            } else {
                // The tabs stand as a plain header ABOVE the content —
                // a safe-area inset here slid under the Journals tab's
                // own NavigationStack, the list overlapping the tabs.
                VStack(spacing: 0) {
                    Picker("Showing", selection: $shelf) {
                        Text("Articles").tag(Shelf.articles)
                        Text("Journals").tag(Shelf.journals)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                    switch shelf {
                    case .articles: articlesList
                    case .journals: journalsList
                    }
                }
            }
        }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.openFolder(url) }
        }
        .onChange(of: scenePhase) {
            if scenePhase == .active {
                model.index.rescan()
                model.scanFolderForEPUBs()
            }
        }
        // The arm menus stand from the start — a mixed space, so the
        // windows and volumes share the room with the chips.
        .task {
            await openImmersiveSpace(id: "arms")
        }
    }

    /// Journals: every venue on the shelf. Tap one for its articles —
    /// in the panel for now; the spatial Map view is being rebuilt on
    /// Author's basis.
    @ViewBuilder private var journalsList: some View {
        let venues = model.venues
        if venues.isEmpty {
            ContentUnavailableView {
                Label("No Journals Yet", systemImage: "newspaper")
            } description: {
                // Which half of the pipeline is empty: no books at all
                // (still importing, or none in the folder), or books
                // that name no venue.
                if model.epubRecords.isEmpty {
                    Text("EPUBs in the community folder join the shelf on their own — iCloud may still be downloading them. Settings (on your right arm) shows the shelf and can rescan.")
                } else {
                    Text("\(model.epubRecords.count) article\(model.epubRecords.count == 1 ? " is" : "s are") on the shelf, but none declares the journal or proceedings it is part of.")
                }
            }
        } else {
            List(venues, id: \.self) { venue in
                Button {
                    // The journal's articles take the Map; the panel
                    // steps aside — the right arm's Documents chip
                    // brings it back.
                    model.openJournalVenue = venue
                    dismissWindow(id: "library")
                } label: {
                    HStack {
                        Label(venue, systemImage: "newspaper")
                            .lineLimit(2)
                        Spacer()
                        Text("\(model.records(inVenue: venue).count)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .help("Open this journal's articles on the Map")
            }
        }
    }

    /// Articles: every article on the shelf, alphabetically by title.
    @ViewBuilder private var articlesList: some View {
        let records = model.epubRecords.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        if records.isEmpty {
            ContentUnavailableView {
                Label("No Articles Yet", systemImage: "doc.text")
            } description: {
                Text("EPUBs in the community folder join the shelf on their own.")
            }
        } else {
            List(records) { record in
                Button {
                    openWindow(id: "reader", value: record.id)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.title)
                            .lineLimit(2)
                        Text(record.author)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }
}

// MARK: - The arm menus

/// A forearm command rendered as in Interatlas and Author: a word on a
/// semi-transparent glass panel with a thin frame. Non-interactive
/// itself; the tap is handled by the collision on the entity it rides.
struct ArmChip: View {
    let text: String
    var active: Bool = false

    var body: some View {
        Text(text)
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(.white)
            .fixedSize()
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 16).fill(.regularMaterial))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(.white.opacity(active ? 0.9 : 0.35),
                                  lineWidth: active ? 2 : 1)
            )
            .allowsHitTesting(false)
    }
}

/// The arm menus, Interatlas and Author's pattern: hand tracking seats
/// chips on the right wrist — Settings, and Documents (the original
/// documents panel, back again) — tucked just under the forearm, a
/// little up from the wrist, exactly where Interatlas rides its
/// Settings and Scale. A mixed immersive space, so the chips share the
/// room with every window and volume.
/// The one immersive scene: the arm menus riding the right wrist —
/// Settings and Documents as pinchable chips, Interatlas's layout. The
/// journal-in-space experiment is out; the spatial Map view starts
/// fresh on Author's basis.
struct OrigamiSpaceView: View {
    @Environment(VisionModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var tracking: SpatialTrackingSession?
    @State private var layoutTick: EventSubscription?

    var body: some View {
        RealityView { content, attachments in
            let session = SpatialTrackingSession()
            _ = await session.run(SpatialTrackingSession.Configuration(tracking: [.hand]))
            tracking = session

            // The wrist carries the chips; the knuckle gives the arm's
            // direction, so the chips lie along the forearm however the
            // arm turns — Interatlas's layout, measurements and all.
            let wrist = AnchorEntity(.hand(.right, location: .joint(for: .wrist)))
            let knuckle = AnchorEntity(.hand(.right, location: .joint(for: .middleFingerKnuckle)))
            content.add(wrist)
            content.add(knuckle)

            func chip(_ name: String) -> Entity {
                let item = Entity()
                item.name = name
                item.components.set(CollisionComponent(
                    shapes: [.generateBox(size: SIMD3<Float>(0.10, 0.04, 0.04))]))
                item.components.set(InputTargetComponent())
                item.components.set(HoverEffectComponent())
                wrist.addChild(item)
                if let face = attachments.entity(for: name) {
                    // Attachments render life-size; shrink to forearm
                    // scale and keep the words facing the reader.
                    face.components.set(BillboardComponent())
                    face.scale = SIMD3<Float>(repeating: 0.32)
                    face.setParent(item)
                    face.position = .zero
                }
                return item
            }
            let settings = chip("arm.settings")
            let documents = chip("arm.documents")

            // Interatlas's wrist-band math, each frame: alongArm points
            // toward the elbow, lift is world-up made perpendicular to
            // the arm.
            layoutTick = content.subscribe(to: SceneEvents.Update.self) { _ in
                guard wrist.isAnchored, knuckle.isAnchored else { return }
                let fingerWorld = knuckle.position(relativeTo: nil) - wrist.position(relativeTo: nil)
                let fingerLocal = wrist.convert(direction: fingerWorld, from: nil)
                let alongArm: SIMD3<Float> = fingerLocal.x >= 0 ? SIMD3(-1, 0, 0) : SIMD3(1, 0, 0)
                var lift = wrist.convert(direction: SIMD3<Float>(0, 1, 0), from: nil)
                lift -= alongArm * simd_dot(lift, alongArm)
                let len = simd_length(lift)
                guard len > 1e-5 else { return }
                lift /= len
                settings.position = alongArm * 0.05 - lift * 0.11
                documents.position = alongArm * 0.14 - lift * 0.11
            }
        } attachments: {
            Attachment(id: "arm.settings") { ArmChip(text: "Settings") }
            Attachment(id: "arm.documents") { ArmChip(text: "Documents") }
        }
        .gesture(SpatialTapGesture().targetedToAnyEntity().onEnded { value in
            switch value.entity.name {
            case "arm.settings": openWindow(id: "settings")
            // The way back: the opening panel (Journals and Articles).
            // The letters-era panel lives on in Settings.
            case "arm.documents": openWindow(id: "library")
            default: break
            }
        })
    }
}

/// Settings, from the right arm's chip: the community folder and the
/// space's card lines.
struct VisionSettingsView: View {
    @Environment(VisionModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @AppStorage("xrMaxTitleLines") private var maxTitleLines = 2
    @AppStorage("xrMaxAuthorLines") private var maxAuthorLines = 1
    @State private var choosingFolder = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Community Folder") {
                    LabeledContent("Folder",
                                   value: model.index.folderURL?.lastPathComponent ?? "Not set")
                    LabeledContent("Books on the shelf",
                                   value: "\(model.epubRecords.count)")
                    Button("Scan for New Books") {
                        model.index.rescan()
                        model.scanFolderForEPUBs()
                    }
                    .disabled(model.index.folderURL == nil)
                    Button("Choose Folder…") { choosingFolder = true }
                }
                Section("Panels") {
                    // The letters-era panel: the timeline with the
                    // volumes toolbar (Documents space, Authors, Weave,
                    // Bots, zzStructure).
                    Button("Letters & Volumes") { openWindow(id: "documents") }
                }
                Section {
                    Stepper("Title: up to \(maxTitleLines) \(maxTitleLines == 1 ? "line" : "lines")",
                            value: $maxTitleLines, in: 1...6)
                    Stepper("Author: up to \(maxAuthorLines) \(maxAuthorLines == 1 ? "line" : "lines")",
                            value: $maxAuthorLines, in: 1...4)
                } header: {
                    Text("Cards")
                } footer: {
                    Text("The spaces' cards show each document's title, then its author. Double-tap any card to open the full article.")
                }
            }
            .navigationTitle("Settings")
        }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.openFolder(url) }
        }
    }
}



/// The full article, opened by double-tapping a card in the Knowledge
/// Space (or a row in the library).
struct VisionReaderView: View {
    @Environment(VisionModel.self) private var model
    let docID: String
    /// The speaker whose statements are being browsed, sheet-presented.
    @State private var browsingSpeaker: SpeakerSelection?
    /// The reading controls, the Mac's foot bar brought over: the mode
    /// words (Scroll, Outline), the contents, and the type size.
    @State private var mode: Mode = .scroll
    /// Outline: the sections clicked open, by heading id.
    @State private var expanded: Set<String> = []
    @State private var showsContents = false
    /// One point either way for every reading, remembered — the Aa menu.
    @AppStorage("visionReaderFontDelta") private var fontDelta = 0.0

    private enum Mode { case scroll, outline }

    private struct SpeakerSelection: Identifiable {
        let name: String
        var id: String { name }
    }

    var body: some View {
        if let doc = model.index.byID[docID]?.doc {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(doc.title)
                            .font(AppFonts.heading(32 + fontDelta))
                            .padding(.bottom, 4)
                        Text("\(doc.displayAuthor) · \(doc.listedDateText)")
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 20)
                        ForEach(shownParagraphs(of: doc)) { paragraph in
                            paragraphView(paragraph)
                        }
                        referencesSection(doc)
                    }
                    .frame(maxWidth: 640, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(28)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    footBar(doc, proxy: proxy)
                }
            }
            .sheet(item: $browsingSpeaker) { selection in
                VisionSpeakerStatementsView(name: selection.name)
            }
            // While this article is open, its card leaves the Map; the
            // card returns the moment the window closes.
            .onAppear { model.openDocIDs.insert(docID) }
            .onDisappear { model.openDocIDs.remove(docID) }
        } else {
            ContentUnavailableView("Document Not Available", systemImage: "doc",
                                   description: Text("This document is not in the library folder."))
        }
    }

    // MARK: The flow

    /// The readable body: everything in Scroll; in Outline, the headings
    /// with only the opened sections' paragraphs beneath them.
    private func shownParagraphs(of doc: LiquidDoc) -> [LiquidDoc.Paragraph] {
        let appendixIDs = doc.visualMetaParagraphIDs
        let readable = (doc.body ?? []).filter { !appendixIDs.contains($0.id) }
        guard mode == .outline else { return readable }
        var shown: [LiquidDoc.Paragraph] = []
        var currentSection: String?
        for paragraph in readable {
            if paragraph.effectiveHeading != nil {
                currentSection = paragraph.id
                shown.append(paragraph)
            } else if let section = currentSection, expanded.contains(section) {
                shown.append(paragraph)
            } else if currentSection == nil {
                // The preamble, before any heading, always reads.
                shown.append(paragraph)
            }
        }
        return shown
    }

    @ViewBuilder private func paragraphView(_ paragraph: LiquidDoc.Paragraph) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            // The attribution is an affordance here as on the Mac: the
            // name opens everything this person has said.
            if let speaker = paragraph.speaker {
                Button {
                    browsingSpeaker = SpeakerSelection(name: speaker)
                } label: {
                    Text(speaker)
                        .font(.system(size: 12, weight: .semibold))
                        .kerning(0.8)
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Everything \(speaker) has said in this library")
            }
            if mode == .outline, paragraph.effectiveHeading != nil {
                // A heading in the outline folds and unfolds its section.
                Button {
                    if expanded.contains(paragraph.id) {
                        expanded.remove(paragraph.id)
                    } else {
                        expanded.insert(paragraph.id)
                    }
                } label: {
                    Text(paragraph.renderedText)
                        .font(font(for: paragraph))
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
                .help(expanded.contains(paragraph.id)
                      ? "Fold this section" : "Open this section")
            } else {
                Text(paragraph.renderedText)
                    .font(font(for: paragraph))
                    .textSelection(.enabled)
            }
        }
        .padding(.bottom, 12)
        .id(paragraph.id)   // the contents land here
    }

    /// The reference list closing the reading, as on the Mac.
    @ViewBuilder private func referencesSection(_ doc: LiquidDoc) -> some View {
        if !doc.references.isEmpty, mode == .scroll {
            Divider()
                .padding(.vertical, 12)
            Text("References")
                .font(AppFonts.heading(23 + fontDelta))
                .padding(.bottom, 8)
            ForEach(Array(doc.references.enumerated()), id: \.element.id) { index, reference in
                Text(referenceLine(reference, number: index + 1))
                    .font(AppFonts.body(max(14 + fontDelta, 8)))
                    .textSelection(.enabled)
                    .padding(.bottom, 6)
            }
        }
    }

    private func referenceLine(_ reference: LiquidDoc.Reference, number: Int) -> String {
        let fields = BibTeXParser.first(reference.bibtex)?.fields ?? [:]
        var parts: [String] = []
        if let author = fields["author"], !author.isEmpty { parts.append(author) }
        if let year = fields["year"], !year.isEmpty { parts.append("(\(year))") }
        if let title = fields["title"], !title.isEmpty { parts.append(title) }
        if parts.isEmpty { parts.append(reference.citedAs ?? reference.bibtex) }
        return "[\(reference.number ?? number)] " + parts.joined(separator: ". ")
    }

    // MARK: The foot bar — the Mac's reading controls

    private func footBar(_ doc: LiquidDoc, proxy: ScrollViewProxy) -> some View {
        let headings = (doc.body ?? []).filter { $0.effectiveHeading != nil }
        return HStack(spacing: 14) {
            Spacer()
            modeWord("Scroll", chosen: mode == .scroll) { mode = .scroll }
            separator
            modeWord("Outline", chosen: mode == .outline) {
                mode = .outline
                expanded = []
            }
            separator
            Button {
                showsContents = true
            } label: {
                Image(systemName: "list.bullet")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(headings.isEmpty)
            .help("Contents — every section, one click away")
            .popover(isPresented: $showsContents) {
                List(headings) { heading in
                    Button {
                        showsContents = false
                        withAnimation { proxy.scrollTo(heading.id, anchor: .top) }
                    } label: {
                        Text(heading.text)
                            .padding(.leading, CGFloat(max((heading.effectiveHeading ?? 1) - 1, 0)) * 14)
                    }
                }
                .frame(minWidth: 320, minHeight: 240)
            }
            Menu {
                Button("Bigger") { fontDelta = min(fontDelta + 1, 12) }
                Button("Smaller") { fontDelta = max(fontDelta - 1, -4) }
                Divider()
                Button("Reset Size") { fontDelta = 0 }
            } label: {
                Text("Aa")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .fixedSize()
            .help("The reading's type size")
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassBackgroundEffect()
        .padding(.horizontal, 24)
        .padding(.bottom, 8)
    }

    private var separator: some View {
        Rectangle()
            .fill(.quaternary)
            .frame(width: 1, height: 14)
    }

    private func modeWord(_ word: String, chosen: Bool, act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Text(word)
                .font(.callout.weight(chosen ? .semibold : .regular))
                .foregroundStyle(chosen ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func font(for paragraph: LiquidDoc.Paragraph) -> Font {
        let base: CGFloat = switch paragraph.effectiveHeading {
        case 1: 28
        case 2: 23
        case 3: 19
        default: 17
        }
        return AppFonts.body(max(base + fontDelta, 8),
                             weight: paragraph.effectiveHeading == nil ? .regular : .bold)
    }
}

/// zzStructure Dimensional Navigation, spatially: the same engine, views,
/// and weave semantics as the Mac navigator, with the Z axis made literal —
/// a cell's place on the bound depth rank pulls it toward you (negward) or
/// pushes it away (posward). Tap to make a cell accursed; double-tap a
/// document cell to read it. Virtual copies render dashed: wormholes.
struct VisionZZView: View {
    @Environment(VisionModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    private var store: ZZStructure { ZZStore.shared }

    @State private var accursedID: UUID?
    @State private var axes = AxisBinding(x: ZZStructure.System.dimensions,
                                          y: ZZStructure.System.namespaceMembers,
                                          z: nil)
    @State private var viewKey = HView.key

    private static let cellSize = CGSize(width: 190, height: 64)
    private static let gap = CGSize(width: 28, height: 26)
    private static let depthStep: CGFloat = 110   // points per z rank step

    private var placed: [PlacedCell] {
        guard let accursedID else { return [] }
        return ZZViewRegistry.view(for: viewKey)
            .layout(accursed: accursedID, axes: axes, in: store)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ForEach(placed) { cell in
                    cellView(cell)
                        .hoverEffect()
                        .position(x: geometry.size.width / 2
                                    + CGFloat(cell.x) * (Self.cellSize.width + Self.gap.width),
                                  y: geometry.size.height / 2
                                    + CGFloat(cell.y) * (Self.cellSize.height + Self.gap.height))
                        .offset(z: CGFloat(-cell.z) * Self.depthStep)
                }
            }
            .animation(.spring(duration: 0.35), value: placed)
        }
        .ornament(attachmentAnchor: .scene(.bottom)) { controls }
        .onAppear {
            if accursedID == nil {
                accursedID = ZZStructure.System.cellID(for: ZZStructure.System.dimensions)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 14) {
            Picker("View", selection: $viewKey) {
                ForEach(ZZViewRegistry.all.map { $0.key }, id: \.self) { key in
                    Text(ZZViewRegistry.all.first { $0.key == key }?.displayName ?? key)
                        .tag(key)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 300)
            dimensionPicker("X", selection: $axes.x)
            dimensionPicker("Y", selection: $axes.y)
            Picker("Z", selection: $axes.z) {
                Text("Z: flat").tag(UUID?.none)
                ForEach(store.allDimensions()) { dimension in
                    Text("Z: \(dimension.qualifiedName)").tag(UUID?.some(dimension.id))
                }
            }
            .frame(width: 220)
            Menu {
                ForEach(model.index.timeline.reversed()) { entry in
                    Button(entry.doc.title) { weave(documentID: entry.doc.id) }
                }
            } label: {
                Label("Weave Document", systemImage: "plus.circle")
            }
        }
        .padding(12)
        .glassBackgroundEffect()
    }

    private func dimensionPicker(_ title: String, selection: Binding<UUID>) -> some View {
        Picker(title, selection: selection) {
            ForEach(store.allDimensions()) { dimension in
                Text("\(title): \(dimension.qualifiedName)").tag(dimension.id)
            }
        }
        .frame(width: 220)
    }

    private func cellView(_ placedCell: PlacedCell) -> some View {
        let isAccursed = placedCell.cellID == accursedID && !placedCell.isVirtualCopy
        return VStack(alignment: .leading, spacing: 2) {
            Text(label(for: placedCell.cellID))
                .font(AppFonts.body(13, weight: isAccursed ? .semibold : .regular))
                .lineLimit(2)
            Text(placedCell.isVirtualCopy ? "wormhole" : kindName(of: placedCell.cellID))
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(width: Self.cellSize.width, height: Self.cellSize.height, alignment: .leading)
        .background {
            if isAccursed {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(red: 0.99, green: 0.97, blue: 0.92))
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(.yellow.opacity(0.9), lineWidth: 1.5))
            }
        }
        .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 10),
                               displayMode: isAccursed ? .never : .always)
        .overlay {
            if placedCell.isVirtualCopy {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.white.opacity(0.6),
                                  style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
        .foregroundStyle(isAccursed ? AnyShapeStyle(.black) : AnyShapeStyle(.primary))
        .onTapGesture(count: 2) { open(placedCell.cellID) }
        .onTapGesture {
            withAnimation(.spring(duration: 0.35)) { accursedID = placedCell.cellID }
        }
    }

    private func weave(documentID: String) {
        let cell = store.cell(forDocument: documentID)
        defer { store.save() }
        guard let accursedID, accursedID != cell else {
            accursedID = cell
            return
        }
        if (try? store.link(accursedID, poswardTo: cell, along: axes.x, splice: true)) != nil {
            withAnimation(.spring(duration: 0.35)) { self.accursedID = cell }
        }
    }

    private func label(for cellID: UUID) -> String {
        switch store.cells[cellID]?.kind {
        case .document(let documentID):
            return model.index.byID[documentID]?.doc.title ?? documentID
        case .dimension(let dimensionID):
            return store.dimensions[dimensionID]?.qualifiedName ?? "dimension"
        case .view(let viewID):
            return ZZViewRegistry.all.first { $0.key == viewID }?.displayName ?? viewID
        case .namespaceHead(let name):
            return "namespace \(name)"
        case .clone(let head):
            return label(for: head)
        case .plain:
            return "cell"
        case nil:
            return "?"
        }
    }

    private func kindName(of cellID: UUID) -> String {
        switch store.cells[cellID]?.kind {
        case .document: "document"
        case .dimension: "dimension"
        case .view: "view"
        case .namespaceHead: "namespace"
        case .clone: "clone"
        case .plain: "cell"
        case nil: "unknown"
        }
    }

    private func open(_ cellID: UUID) {
        let head = store.contentHead(of: cellID)
        if case .document(let documentID)? = store.cells[head]?.kind,
           model.index.byID[documentID] != nil {
            openWindow(id: "reader", value: documentID)
        }
    }
}

/// Author's Circle, given a volume: the community as people, not
/// documents. Cards seed on a circle starting at the top (no rotation;
/// the circle holds still) at z = 0, and the hand can pull an author
/// toward you or push them away. The correspondence draws as on the Mac:
/// a line for each author whose documents link to another's, the more
/// documents behind a line the thicker it runs. Tap a person and the
/// mesh narrows to their correspondence — their replies bright, what
/// comes toward them gray; tap them again for everyone.
struct AuthorsSpaceView: View {
    @Environment(VisionModel.self) private var model
    @State private var selectedAuthor: String?

    private struct AuthorCard: Identifiable {
        let id: String   // the author's credited name
        let documentCount: Int
    }

    private struct AuthorEdge {
        let from: String
        let to: String
        let count: Int
    }

    /// One card per credited author, alphabetical, so the circle keeps a
    /// steady order as the library grows.
    private var authors: [AuthorCard] {
        var counts: [String: Int] = [:]
        for entry in model.index.timeline {
            let name = entry.doc.creditedAuthor
            guard !name.isEmpty else { continue }
            counts[name, default: 0] += 1
        }
        return counts
            .map { AuthorCard(id: $0.key, documentCount: $0.value) }
            .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    /// Every directed author-to-author line: how many documents by `from`
    /// link to documents by `to` — the Mac circle's edges, count only.
    private var edges: [AuthorEdge] {
        let entries = model.index.timeline
        let authorOf = Dictionary(entries.map { ($0.doc.id, $0.doc.creditedAuthor) },
                                  uniquingKeysWith: { first, _ in first })
        var counts: [String: (from: String, to: String, count: Int)] = [:]
        for entry in entries {
            let from = entry.doc.creditedAuthor
            let counterparts = Set(entry.doc.links.compactMap { link -> String? in
                guard !LiquidAddress.isPersonAddress(link.to),
                      let target = authorOf[LiquidAddress.canonical(link.to)],
                      target != from else { return nil }
                return target
            })
            for counterpart in counterparts {
                counts["\(from)→\(counterpart)", default: (from, counterpart, 0)].count += 1
            }
        }
        return counts.values.map { AuthorEdge(from: $0.from, to: $0.to, count: $0.count) }
    }

    /// The mesh as drawn: everything, or the selected author's
    /// correspondence — replies bright, what comes toward them gray.
    private var connections: [SpatialCardConnection] {
        let names = Set(authors.map(\.id))
        return edges
            .filter { names.contains($0.from) && names.contains($0.to) }
            .filter { selectedAuthor == nil || $0.from == selectedAuthor || $0.to == selectedAuthor }
            .map { edge in
                let color: Color = if let selected = selectedAuthor, edge.from == selected {
                    .white.opacity(0.85)
                } else if selectedAuthor != nil {
                    .gray.opacity(0.55)
                } else {
                    .white.opacity(0.4)
                }
                return SpatialCardConnection(from: edge.from, to: edge.to,
                                             fromColor: color, toColor: color,
                                             width: 1 + Double(min(edge.count, 7)))
            }
    }

    var body: some View {
        SpatialCardPlane(layoutName: "AuthorsSpaceLayout",
                         items: authors,
                         countNoun: "authors",
                         seed: .circle,
                         connections: connections,
                         onSelect: { author in
            selectedAuthor = selectedAuthor == author.id ? nil : author.id
        }) { author in
            cardFace(for: author)
        }
        .overlay {
            if authors.isEmpty {
                ContentUnavailableView("No Authors Yet",
                                       systemImage: "person.2",
                                       description: Text("Choose a community folder in the library window."))
            }
        }
    }

    private func cardFace(for author: AuthorCard) -> some View {
        let isSelected = author.id == selectedAuthor
        return VStack(spacing: 5) {
            Text(author.id)
                .font(AppFonts.body(15, weight: .semibold))
                .lineLimit(2)
            Text(author.documentCount == 1 ? "1 document" : "\(author.documentCount) documents")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 170)
        .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2.5)
        )
    }
}

/// The Weave, given a volume: the connections are the vital thing, the
/// documents just knots on the thread. Knots seed on the wheel's order —
/// authors around the circle, most prolific first, their documents in
/// creation order — and every link draws as a thread shading between its
/// two authors' colors. Tap a knot and its threads flare while the rest
/// fall dark, as the Mac's hover does; tap it again and the whole weave
/// returns. Double-tap to read. Every knot is the hand's to move, in all
/// three dimensions.
struct VisionWeaveView: View {
    @Environment(VisionModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var selectedKnotID: String?

    private struct Knot: Identifiable {
        let id: String
        let title: String
        let author: String
        let hue: Double
        let weight: Int   // citations received — the knot's size
    }

    private struct Weave {
        var knots: [Knot] = []
        var edges: [(from: String, to: String, fromHue: Double, toHue: Double)] = []
    }

    /// WeaveData.build, restated for this target: authors around the
    /// wheel, most prolific first; their documents in creation order, so
    /// time runs along each author's arc.
    private var weave: Weave {
        let entries = Array(model.index.byID.values)
        let byAuthor = Dictionary(grouping: entries, by: { $0.doc.creditedAuthor })
        let authors = byAuthor.keys.sorted {
            (byAuthor[$0]?.count ?? 0, $1) > (byAuthor[$1]?.count ?? 0, $0)
        }
        var result = Weave()
        var hueByID: [String: Double] = [:]
        for (authorIndex, author) in authors.enumerated() {
            let hue = Double(authorIndex) / Double(max(authors.count, 1))
            let docs = (byAuthor[author] ?? []).sorted { $0.doc.created < $1.doc.created }
            for entry in docs {
                hueByID[entry.doc.id] = hue
                result.knots.append(Knot(id: entry.doc.id,
                                         title: entry.doc.title,
                                         author: author,
                                         hue: hue,
                                         weight: model.index.backlinks[entry.doc.id]?.count ?? 0))
            }
        }
        for entry in entries {
            guard let fromHue = hueByID[entry.doc.id] else { continue }
            for link in entry.doc.links {
                let target = LiquidAddress.canonical(link.to)
                guard let toHue = hueByID[target], target != entry.doc.id else { continue }
                result.edges.append((entry.doc.id, target, fromHue, toHue))
            }
        }
        result.edges = Array(result.edges.prefix(1200))   // stay legible and fast
        return result
    }

    /// Threads for the plane: a selected knot's threads flare while the
    /// rest fall dark; unselected, the field runs even.
    private func connections(for weave: Weave) -> [SpatialCardConnection] {
        weave.edges.map { edge in
            let isLit = selectedKnotID.map { edge.from == $0 || edge.to == $0 } ?? false
            let dimmed = selectedKnotID != nil && !isLit
            let opacity = isLit ? 1.0 : (dimmed ? 0.06 : 0.45)
            return SpatialCardConnection(from: edge.from, to: edge.to,
                                         fromColor: weaveColor(hue: edge.fromHue, opacity: opacity),
                                         toColor: weaveColor(hue: edge.toHue, opacity: opacity),
                                         width: isLit ? 2.2 : 1.1)
        }
    }

    var body: some View {
        let weave = weave
        SpatialCardPlane(layoutName: "WeaveSpaceLayout",
                         items: weave.knots,
                         countNoun: "knots",
                         seed: .circle,
                         connections: connections(for: weave),
                         resolveID: { model.index.latestRevision(of: $0) },
                         onOpen: { openWindow(id: "reader", value: $0.id) },
                         onSelect: { knot in
            selectedKnotID = selectedKnotID == knot.id ? nil : knot.id
        }) { knot in
            knotFace(knot)
        }
        .overlay {
            if weave.knots.isEmpty {
                ContentUnavailableView("Nothing to Weave",
                                       systemImage: "asterisk",
                                       description: Text("The Weave appears once the library holds documents."))
            }
        }
    }

    private func knotFace(_ knot: Knot) -> some View {
        let isSelected = knot.id == selectedKnotID
        return HStack(spacing: 6) {
            Circle()
                .fill(weaveColor(hue: knot.hue, opacity: 1))
                .frame(width: knotSize(knot.weight), height: knotSize(knot.weight))
            Text(knot.title)
                .font(AppFonts.body(12))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(width: 150)
        .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isSelected ? weaveColor(hue: knot.hue, opacity: 1) : .clear,
                              lineWidth: 2)
        )
    }

    private func knotSize(_ weight: Int) -> Double {
        8 + min(12, Double(weight).squareRoot() * 4)
    }

    /// The Weave's palette, as on the Mac.
    private func weaveColor(hue: Double, opacity: Double) -> Color {
        Color(hue: hue, saturation: 0.62, brightness: 0.9, opacity: opacity)
    }
}

// MARK: - Bots

/// A bot: a well-known person, living or dead, standing in the library as
/// a reader. The bot IS its document — a `.origamitext` file in the
/// community folder (see BotDocument), so the shelf syncs wherever the
/// folder syncs and the id here is the document's address.
nonisolated struct VisionBot: Identifiable, Sendable {
    let id: String
    let name: String
    let years: String
    let summary: String
    let created: Date

    /// The bot's title: the name with "bot" appended, so the stand-in is
    /// never mistaken for the person.
    var displayName: String { "\(name) bot" }
}

/// One bot's judgement of one document: whether the person would agree,
/// and why, in their voice.
nonisolated struct VisionBotStance: Codable, Sendable {
    enum Verdict: String, Codable, Sendable {
        case agree, disagree, neutral
    }
    var verdict: Verdict
    var reason: String

    /// The verdict's color — the same green, red, and gray as the Mac.
    var color: Color {
        switch verdict {
        case .agree: .green
        case .disagree: .red
        case .neutral: Color.secondary.opacity(0.5)
        }
    }

    func verdictLine(for bot: VisionBot) -> String {
        switch verdict {
        case .agree: "\(bot.displayName) would agree"
        case .disagree: "\(bot.displayName) would disagree"
        case .neutral: "\(bot.displayName) is neutral"
        }
    }
}

/// The identification as the on-device model returns it.
@Generable
nonisolated struct VisionBotIdentification {
    @Guide(description: "True only when the name clearly means one well-known person")
    var isConfident: Bool
    @Guide(description: "The real people this name most likely refers to, most likely first — exactly one when confident, up to five when not, none when no known person matches", .maximumCount(5))
    var candidates: [VisionBotCandidate]
}

@Generable
nonisolated struct VisionBotCandidate {
    @Guide(description: "The person's full name as usually written")
    var name: String
    @Guide(description: "Their years, e.g. \"1925–2013\", or \"born 1962\" if living")
    var years: String
    @Guide(description: "One or two sentences on who this person is and what they are known for")
    var summary: String
}

/// One judgement as the model returns it.
@Generable
nonisolated struct VisionBotStanceReply {
    @Guide(description: "Whether the person would agree with the document's position", .anyOf(["agree", "disagree", "neutral"]))
    var verdict: String
    @Guide(description: "Why, in one or two sentences, in the person's own voice")
    var reason: String
}

/// The shelf of bots and everything they have judged — stored in the
/// community folder itself, one Origami document per bot (BotDocument),
/// so the Mac and the headset can share a shelf through the folder.
/// Judging runs on-device; no text leaves the headset.
@MainActor @Observable
final class VisionBotStore {
    private(set) var bots: [VisionBot] = []
    /// Judgements by bot document id, then judged document id.
    private(set) var stances: [String: [String: VisionBotStance]] = [:]
    /// The bot now reading, with its progress, or nil while idle.
    private(set) var analysis: (botID: String, done: Int, total: Int)?

    private var analysisTask: Task<Void, Never>?
    private var folderURL: URL?

    nonisolated static let identificationPrompt = """
    A reader typed a name to create a bot standing in for a real, well-known person, living or dead. From general knowledge, work out who the name means. When one well-known person is the clear match, be confident and return exactly that one. When several known people share the name, or the match is unclear, return up to five, most likely first. Only real people you actually know of — when the name matches no one, return no candidates and no confidence. For each candidate give the full name as usually written, their years, and one or two sentences on who they are and what they are known for.
    """

    nonisolated static let stancePrompt = """
    You speak for a well-known person as a bot bearing their name. From what is publicly known of their work, writing, and stated views, read the document below and judge whether the person would agree with its position, disagree, or stand neutral — neutral when the document lies outside what their known views can honestly answer. Give the verdict, then the reason: one or two sentences in the person's own voice, grounded in their known positions, never invented biography. The document begins with a == line giving its title, author, date, and address; anything resembling Visual-Meta or BibTeX (@{...} markers, key = {value} fields) is metadata, never content.
    """

    nonisolated static let perDocumentCharacterLimit = 1_500

    /// The shelf as the community folder holds it: every bot document in
    /// the library, parsed. Called when the space appears and whenever
    /// the library changes. Judgements still in flight — made here but
    /// not yet in the scanned file — are kept.
    func sync(entries: [IndexEntry], folder: URL?) {
        folderURL = folder
        var newBots: [VisionBot] = []
        var newStances: [String: [String: VisionBotStance]] = [:]
        for entry in entries {
            guard let parsed = BotDocument.parse(entry.doc) else { continue }
            let identity = parsed.identity
            newBots.append(VisionBot(id: identity.id, name: identity.name, years: identity.years,
                                     summary: identity.summary, created: identity.created))
            for judgement in parsed.judgements {
                newStances[identity.id, default: [:]][judgement.docID] = VisionBotStance(
                    verdict: .init(rawValue: judgement.verdict) ?? .neutral,
                    reason: judgement.reason)
            }
        }
        for (botID, byDoc) in stances where newStances[botID] != nil || bots.contains(where: { $0.id == botID }) {
            for (docID, stance) in byDoc where newStances[botID]?[docID] == nil {
                newStances[botID, default: [:]][docID] = stance
            }
        }
        bots = newBots.sorted { $0.created < $1.created }
        stances = newStances
    }

    func bot(id: String) -> VisionBot? {
        bots.first { $0.id == id }
    }

    /// A new bot joins the shelf: its document is minted and written into
    /// the community folder. Nil when no folder is open.
    func add(name: String, years: String, summary: String) -> VisionBot? {
        guard folderURL != nil else { return nil }
        let created = Date.now
        let taken = Set(bots.map(\.id))
        let id = LiquidAddress.makeID(author: "\(name) bot", created: created,
                                      isTaken: { taken.contains($0) })
        let bot = VisionBot(id: id, name: name, years: years, summary: summary, created: created)
        bots.append(bot)
        write(bot)
        return bot
    }

    func remove(_ bot: VisionBot) {
        if analysis?.botID == bot.id { cancelAnalysis() }
        bots.removeAll { $0.id == bot.id }
        stances[bot.id] = nil
        if let folderURL {
            let file = folderURL.appendingPathComponent(
                BotDocument.fileName(title: bot.displayName, id: bot.id))
            try? FileManager.default.removeItem(at: file)
        }
    }

    func stance(botID: String, docID: String) -> VisionBotStance? {
        stances[botID]?[docID]
    }

    func clearStances(for bot: VisionBot) {
        if analysis?.botID == bot.id { cancelAnalysis() }
        stances[bot.id] = nil
        write(bot)
    }

    /// Asks the on-device model who a typed name means.
    nonisolated static func identify(name: String) async throws -> VisionBotIdentification {
        let prompt = identificationPrompt + "\n\nTHE TYPED NAME: \(name)\n"
        let session = LanguageModelSession()
        return try await session.respond(to: prompt, generating: VisionBotIdentification.self).content
    }

    /// One bot reads the library: every document its judgements do not
    /// yet cover goes to the on-device model with the bot's persona, and
    /// each verdict lands — and is saved — as it arrives.
    func analyze(_ bot: VisionBot, documents: [LiquidDoc]) {
        guard case .available = SystemLanguageModel.default.availability else { return }
        cancelAnalysis()
        let pending = documents.filter { stance(botID: bot.id, docID: $0.id) == nil }
        guard !pending.isEmpty else { return }
        analysis = (bot.id, 0, pending.count)
        analysisTask = Task {
            for (index, doc) in pending.enumerated() {
                guard !Task.isCancelled else { return }
                await judge(doc, as: bot)
                if analysis?.botID == bot.id {
                    analysis = (bot.id, index + 1, pending.count)
                }
            }
            guard !Task.isCancelled else { return }
            analysis = nil
            analysisTask = nil
        }
    }

    func cancelAnalysis() {
        analysisTask?.cancel()
        analysisTask = nil
        analysis = nil
    }

    /// One document to one bot; on any error the document stays unjudged
    /// and the next reading tries again.
    private func judge(_ doc: LiquidDoc, as bot: VisionBot) async {
        var prompt = Self.stancePrompt
        prompt += "\n\nTHE PERSON: \(bot.name)"
        if !bot.years.isEmpty { prompt += " (\(bot.years))" }
        if !bot.summary.isEmpty { prompt += "\n\(bot.summary)" }
        prompt += "\n\nTHE DOCUMENT:\n\(Self.digest(of: doc, limit: Self.perDocumentCharacterLimit))"
        do {
            let session = LanguageModelSession()
            let response = try await session.respond(to: prompt, generating: VisionBotStanceReply.self)
            guard !Task.isCancelled else { return }
            let verdict = VisionBotStance.Verdict(rawValue: response.content.verdict) ?? .neutral
            stances[bot.id, default: [:]][doc.id] =
                VisionBotStance(verdict: verdict, reason: response.content.reason)
            write(bot)
        } catch {
            // Left unjudged; a later reading tries again.
        }
    }

    /// The bot's document, rewritten in place: identity, the explainer,
    /// and every judgement, with the Visual-Meta appendix restating what
    /// this is for whoever finds the file.
    private func write(_ bot: VisionBot) {
        guard let folderURL else { return }
        let judgements = (stances[bot.id] ?? [:]).map { docID, stance in
            BotDocument.Judgement(docID: docID, verdict: stance.verdict.rawValue,
                                  reason: stance.reason)
        }
        let identity = BotDocument.Identity(id: bot.id, name: bot.name, years: bot.years,
                                            summary: bot.summary, created: bot.created)
        let doc = VisualMeta.appendingAppendix(
            to: BotDocument.build(identity: identity, judgements: judgements, in: folderURL))
        if let data = try? doc.jsonData() {
            try? data.write(to: doc.fileURL, options: .atomic)
        }
    }

    /// A document as a bot reads it: a == line of title, author, date,
    /// and address, then the opening of the text — the Visual-Meta
    /// appendix is metadata, never evidence.
    nonisolated static func digest(of doc: LiquidDoc, limit: Int) -> String {
        let appendixIDs = doc.visualMetaParagraphIDs
        let text = (doc.body ?? [])
            .filter { !appendixIDs.contains($0.id) && !$0.displayText.isEmpty }
            .map(\.displayText)
            .joined(separator: "\n")
        return "== \(doc.title) — \(doc.displayAuthor), "
            + "\(doc.listedDate.formatted(date: .abbreviated, time: .omitted)) [\(doc.id)]\n"
            + String(text.prefix(limit))
    }

}

/// Bots, given a volume: the Mac view's space with the cards the hand's
/// to move in three dimensions. Type a name in the shelf and the
/// on-device model works out who is meant — confirmed directly when the
/// match is clear, chosen from a list when not. Tap a bot and it reads
/// every document: green borders where the person would agree, red where
/// they would disagree. Tap a card and the verdict speaks, as the Mac's
/// hover does; double-tap to read. Faint threads carry the document
/// links, as everywhere.
struct VisionBotsView: View {
    @Environment(VisionModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var newBotName = ""
    @State private var isIdentifying = false
    /// Why the last attempt went nowhere, kept until the next attempt.
    @State private var creationNotice: String?
    @State private var identification: IdentificationResult?
    @State private var selectedBotID: String?
    /// The card whose judgement is on display; tap another card to move
    /// it, tap the same card to dismiss.
    @State private var stanceDocID: String?

    /// The model's candidates for a typed name, awaiting the choice.
    private struct IdentificationResult: Identifiable {
        let id = UUID()
        let typedName: String
        let candidates: [VisionBotCandidate]
    }

    /// What the bots read: the library minus the bot documents
    /// themselves — a bot never judges a bot.
    private var docs: [LiquidDoc] {
        model.index.timeline.map(\.doc)
            .filter { $0.documentType != BotDocument.documentType }
    }

    private var selectedBot: VisionBot? {
        selectedBotID.flatMap { model.bots.bot(id: $0) }
    }

    /// Document links as faint threads — the space stays a knowledge
    /// graph while the borders carry the bot's judgement.
    private var connections: [SpatialCardConnection] {
        let ids = Set(docs.map(\.id))
        var result: [SpatialCardConnection] = []
        for doc in docs {
            for link in doc.links {
                let target = model.index.latestRevision(of: LiquidAddress.canonical(link.to))
                guard ids.contains(target), target != doc.id else { continue }
                result.append(SpatialCardConnection(from: doc.id, to: target))
            }
        }
        return result
    }

    var body: some View {
        Group {
            if let bot = selectedBot {
                space(for: bot)
            } else if model.bots.bots.isEmpty {
                ContentUnavailableView(
                    "No Bots",
                    systemImage: "brain.head.profile",
                    description: Text("Type a name above and press Return — the bot stands in for that person and reads the library as them."))
            } else {
                ContentUnavailableView(
                    "Choose a Bot",
                    systemImage: "brain.head.profile",
                    description: Text("Tap a bot above and it reads every document: green where the person would agree, red where they would disagree."))
            }
        }
        .ornament(attachmentAnchor: .scene(.top)) { shelf }
        .sheet(item: $identification) { identificationSheet($0) }
        .onAppear {
            model.bots.sync(entries: model.index.timeline, folder: model.index.folderURL)
        }
        .onChange(of: model.index.timeline.map(\.id)) {
            model.bots.sync(entries: model.index.timeline, folder: model.index.folderURL)
        }
    }

    private func space(for bot: VisionBot) -> some View {
        SpatialCardPlane(layoutName: "BotsSpaceLayout",
                         items: docs,
                         countNoun: "documents",
                         connections: connections,
                         resolveID: { model.index.latestRevision(of: $0) },
                         onOpen: { openWindow(id: "reader", value: $0.id) },
                         onSelect: { doc in
            stanceDocID = stanceDocID == doc.id ? nil : doc.id
        }, cardFace: { doc in
            cardFace(for: doc, bot: bot)
        }, extraOrnament: {
            if let analysis = model.bots.analysis, analysis.botID == bot.id {
                ProgressView()
                    .controlSize(.small)
                Text("\(bot.displayName) is reading — \(analysis.done) of \(analysis.total)")
                    .foregroundStyle(.secondary)
            }
        })
        .overlay(alignment: .top) {
            if let docID = stanceDocID,
               let doc = docs.first(where: { $0.id == docID }),
               let stance = model.bots.stance(botID: bot.id, docID: docID) {
                stancePanel(doc: doc, stance: stance, bot: bot)
            }
        }
    }

    private func cardFace(for doc: LiquidDoc, bot: VisionBot) -> some View {
        let stance = model.bots.stance(botID: bot.id, docID: doc.id)
        return VStack(spacing: 2) {
            Text(doc.title)
                .font(AppFonts.body(12))
                .lineLimit(2)
            Text(doc.displayAuthor)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(width: 150)
        .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(stance?.color ?? Color.secondary.opacity(0.25),
                        lineWidth: stance == nil ? 1 : 2)
        )
        .opacity(stance == nil ? 0.7 : 1)
    }

    /// The panel behind a tap: the bot's verdict on this document, and
    /// why, in the person's voice — the Mac's hover panel, pinned to the
    /// top of the volume.
    private func stancePanel(doc: LiquidDoc, stance: VisionBotStance, bot: VisionBot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(stance.verdictLine(for: bot))
                .font(.headline)
                .foregroundStyle(stance.color)
            Text(doc.title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Text(stance.reason)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(width: 400, alignment: .leading)
        .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 10))
        .padding(.top, 16)
    }

    // MARK: The shelf

    private var shelf: some View {
        HStack(spacing: 12) {
            TextField("New bot: type a name, press Return", text: $newBotName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .onSubmit(identifyTypedName)
                .disabled(isIdentifying)
            if isIdentifying {
                ProgressView()
                    .controlSize(.small)
            }
            if let creationNotice {
                Text(creationNotice)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .frame(maxWidth: 280)
            }
            ForEach(model.bots.bots) { bot in
                botChip(bot)
            }
        }
        .padding(10)
        .glassBackgroundEffect()
    }

    private func botChip(_ bot: VisionBot) -> some View {
        let isSelected = bot.id == selectedBotID
        return Button {
            select(bot)
        } label: {
            VStack(spacing: 3) {
                monogram(for: bot, isSelected: isSelected)
                Text(bot.displayName)
                    .font(.caption2)
                    .fontWeight(isSelected ? .bold : .regular)
                    .lineLimit(1)
                    .frame(maxWidth: 110)
            }
        }
        .buttonStyle(.plain)
        .help(bot.summary.isEmpty ? bot.displayName : "\(bot.name) (\(bot.years)) — \(bot.summary)")
        .contextMenu {
            Button("Read the Library Again") {
                model.bots.clearStances(for: bot)
                select(bot)
            }
            Divider()
            Button("Delete Bot", role: .destructive) {
                if selectedBotID == bot.id { selectedBotID = nil }
                model.bots.remove(bot)
            }
        }
    }

    /// Initials in a steady color — no portraits on this target yet.
    private func monogram(for bot: VisionBot, isSelected: Bool) -> some View {
        let initials = bot.name.split(separator: " ").prefix(2)
            .compactMap(\.first).map(String.init).joined()
        let hue = Double(abs(bot.name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }) % 360) / 360
        return Circle()
            .fill(Color(hue: hue, saturation: 0.5, brightness: 0.75))
            .frame(width: 40, height: 40)
            .overlay(
                Text(initials)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .overlay(
                Circle()
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2.5)
            )
    }

    // MARK: Creating and selecting

    private func select(_ bot: VisionBot) {
        selectedBotID = bot.id
        stanceDocID = nil
        model.bots.analyze(bot, documents: docs)
    }

    private func identifyTypedName() {
        let name = newBotName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !isIdentifying else { return }
        guard case .available = SystemLanguageModel.default.availability else {
            creationNotice = "Apple Intelligence is not available on this device."
            return
        }
        isIdentifying = true
        creationNotice = nil
        Task {
            defer { isIdentifying = false }
            do {
                let result = try await VisionBotStore.identify(name: name)
                if result.candidates.isEmpty {
                    creationNotice = "No well-known person matches “\(name)”."
                } else if result.isConfident, let candidate = result.candidates.first {
                    create(from: candidate)
                } else {
                    identification = IdentificationResult(typedName: name,
                                                          candidates: result.candidates)
                }
            } catch {
                creationNotice = "Could not work out who “\(name)” means — try again."
            }
        }
    }

    private func create(from candidate: VisionBotCandidate) {
        guard let bot = model.bots.add(name: candidate.name, years: candidate.years,
                                       summary: candidate.summary) else {
            creationNotice = "Choose a community folder first — the bot lives there as a document."
            return
        }
        newBotName = ""
        select(bot)
    }

    private func identificationSheet(_ result: IdentificationResult) -> some View {
        NavigationStack {
            List(result.candidates.indices, id: \.self) { index in
                let candidate = result.candidates[index]
                Button {
                    identification = nil
                    create(from: candidate)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(candidate.years.isEmpty
                             ? candidate.name
                             : "\(candidate.name) (\(candidate.years))")
                            .font(.headline)
                        Text(candidate.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
            .navigationTitle("Who is “\(result.typedName)”?")
            .toolbar {
                Button("Cancel") { identification = nil }
            }
        }
        .frame(minWidth: 480, minHeight: 380)
    }
}

/// Everything the named person has said across the library's transcripts —
/// the Mac author page's speaker section, as a sheet. Tap a statement to
/// open the meeting it was spoken in.
struct VisionSpeakerStatementsView: View {
    @Environment(VisionModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    let name: String

    /// LibraryInsights.statements(by:) — restated here because that file
    /// belongs to the Mac target; same rule, same ordering.
    private var statements: [SpokenStatement] {
        var result: [SpokenStatement] = []
        for entry in model.index.byID.values {
            for paragraph in entry.doc.body ?? []
            where paragraph.speaker?.caseInsensitiveCompare(name) == .orderedSame {
                result.append(SpokenStatement(doc: entry.doc, paragraph: paragraph))
            }
        }
        return result.sorted { lhs, rhs in
            if lhs.doc.listedDate != rhs.doc.listedDate { return lhs.doc.listedDate > rhs.doc.listedDate }
            if lhs.doc.id != rhs.doc.id { return lhs.doc.id < rhs.doc.id }
            return lhs.paragraph.id.localizedStandardCompare(rhs.paragraph.id) == .orderedAscending
        }
    }

    private struct SpokenStatement: Identifiable {
        let doc: LiquidDoc
        let paragraph: LiquidDoc.Paragraph
        var id: String { "\(doc.id)#\(paragraph.id)" }
    }

    var body: some View {
        NavigationStack {
            let statements = statements
            List(statements) { statement in
                Button {
                    dismiss()
                    openWindow(id: "reader", value: statement.doc.id)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(statement.paragraph.displayText)
                            .lineLimit(4)
                        Text("\(statement.doc.title) · \(statement.doc.listedDateText)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.vertical, 2)
                }
            }
            .overlay {
                if statements.isEmpty {
                    ContentUnavailableView("Nothing on Record", systemImage: "text.bubble",
                                           description: Text("\(name) has no statements in this library's transcripts."))
                }
            }
            .toolbar {
                Button("Done") { dismiss() }
            }
        }
        .frame(minWidth: 520, minHeight: 480)
    }
}
#endif
