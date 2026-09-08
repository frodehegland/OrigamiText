#if os(visionOS)
import SwiftUI
import RealityKit
import UniformTypeIdentifiers
import FoundationModels
import WebKit
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

        // Lineage — the shelf's citation web: every book and every
        // work their references name, years as columns, citations as
        // arcs. Opened from the shelf panel's web button.
        WindowGroup(id: "lineage") {
            VisionLineageWindow()
                .environment(model)
        }
        .defaultSize(width: 1280, height: 820)

        // Settings, opened from the right arm's Settings chip. Its
        // Graph Data tab carries the graphs' Ask-for-Data dialog,
        // which used to be its own window off the arm chips.
        WindowGroup(id: "settings") {
            VisionSettingsView()
                .environment(model)
        }
        .defaultSize(width: 480, height: 560)

        // The graph's data dialog alone, opened from the Edit chip on
        // the graph's own key — preset to that graph's side. Settings'
        // Graph Data tab holds the same dialog for when no graph (and
        // so no key) stands in the room yet.
        WindowGroup(id: "graphdata") {
            VisionDataView()
                .environment(model)
        }
        .defaultSize(width: 480, height: 560)

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

        // The Concept Space: library-wide concepts as draggable 3D cards —
        // connections on tap, full detail on double-tap, layout per room.
        WindowGroup(id: "concepts") {
            ConceptSpatialView()
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
        loadAnalyses(from: url)
        scanFolderForEPUBs()
    }

    private func restoreFolder() {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale),
              url.startAccessingSecurityScopedResource() else { return }
        index.setFolder(url)
        loadAnalyses(from: url)
        scanFolderForEPUBs()
    }

    private func loadAnalyses(from folder: URL) {
        let file = VisionAnalysesFile.read(from: folder)
        allPaperTopics = file.analyses.values.reduce(into: [:]) { result, pub in
            result.merge(pub.paperTopics) { existing, _ in existing }
        }
    }

    private struct VisionAnalysesFile: Codable {
        var analyses: [String: VisionPubAnalysis] = [:]
        static let filename = "_publication-analyses.json"

        struct VisionPubAnalysis: Codable {
            var paperTopics: [String: [String]] = [:]
        }

        static func read(from folder: URL) -> VisionAnalysesFile {
            let url = folder.appendingPathComponent(filename)
            guard let data = try? Data(contentsOf: url),
                  let file = try? JSONDecoder().decode(VisionAnalysesFile.self, from: data)
            else { return VisionAnalysesFile() }
            return file
        }
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

    /// The reader's tracked concepts, adopted from the Mac through the
    /// standing file — the Map's left arm offers them.
    private(set) var concepts: [String] =
        UserDefaults.standard.stringArray(forKey: "viewConcepts") ?? []

    /// The books already asked for — the citation card's Acquire
    /// button rests once its wish is listed.
    private(set) var acquisitionIDs: Set<String> = []

    /// The Reading Desk: the one document whose panel stands alone —
    /// everything else in the Hallway steps away while this is set.
    /// Toggled from the reader panel's own toolbar.
    var readingDeskDocID: String?

    /// Each panel's pose: standing, tilted like a drafting board, or
    /// flat on the reading surface — cycled from the panel's toolbar.
    var panelPoses: [String: PanelPose] = [:]

    /// Maps each open document to the set of hallway item IDs it cites —
    /// populated as each reader panel opens, cleared when it closes.
    var openDocCitations: [String: Set<String>] = [:]

    /// Flat map from EPUB record id → AI-generated topic keywords, read from
    /// `_publication-analyses.json` when the folder is set. Populated by macOS
    /// AI Analyse; visionOS reads but never writes it.
    private(set) var allPaperTopics: [String: [String]] = [:]

    /// All concept names for the Concepts ladder: manually tracked concepts
    /// plus unique topic keywords from macOS AI Analyse, sorted alphabetically.
    var allConceptNames: [String] {
        var names = Set(concepts)
        for topics in allPaperTopics.values {
            names.formUnion(topics.filter { !$0.isEmpty })
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// All merged concepts: glossary entries from every indexed document
    /// plus AI paper topics from macOS Analyse, sorted alphabetically.
    /// Used by the Concept Space on visionOS.
    @MainActor
    var allMergedConcepts: [MergedConcept] {
        var merged = ConceptAggregator.aggregate(from: Array(index.byID.values))
        var byKey: [String: Int] = Dictionary(uniqueKeysWithValues: merged.enumerated().map { ($1.id, $0) })
        for (recordID, topics) in allPaperTopics {
            guard let entry = index.byID[recordID] else { continue }
            for topic in topics where !topic.isEmpty {
                let key = MergedConcept.key(for: topic)
                if let idx = byKey[key] {
                    if !merged[idx].sourceDocIDs.contains(entry.doc.id) {
                        merged[idx].sourceDocIDs.append(entry.doc.id)
                    }
                } else {
                    let concept = MergedConcept(
                        id: key,
                        name: MergedConcept.displayName(forKey: key),
                        aiDescription: "", userDefinition: nil, category: "AI Topics",
                        citationIdentifiers: [], urls: [],
                        sourceDocIDs: [entry.doc.id], relatedConceptIDs: [])
                    byKey[key] = merged.count
                    merged.append(concept)
                }
            }
        }
        return merged.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Concepts built purely from macOS AI Analyse — no glossary entries, no
    /// manually defined concepts. Used by the room-scale Concept Space on
    /// visionOS. Related concepts are those sharing at least one source
    /// document (co-occurrence).
    @MainActor
    var aiPaperConcepts: [MergedConcept] {
        var merged: [MergedConcept] = []
        var byKey: [String: Int] = [:]
        var docConceptKeys: [String: Set<String>] = [:]
        for (recordID, topics) in allPaperTopics {
            // allPaperTopics is keyed by EPUB record IDs which are not in
            // the liquid-doc index. Use recordID directly as sourceDocID so
            // topics always surface even when no IndexEntry exists.
            let docID = index.byID[recordID]?.doc.id ?? recordID
            var keys: Set<String> = []
            for topic in topics where !topic.isEmpty {
                let key = MergedConcept.key(for: topic)
                keys.insert(key)
                if let idx = byKey[key] {
                    if !merged[idx].sourceDocIDs.contains(docID) {
                        merged[idx].sourceDocIDs.append(docID)
                    }
                } else {
                    byKey[key] = merged.count
                    merged.append(MergedConcept(
                        id: key,
                        name: MergedConcept.displayName(forKey: key),
                        aiDescription: "", userDefinition: nil, category: "AI Topics",
                        citationIdentifiers: [], urls: [],
                        sourceDocIDs: [docID], relatedConceptIDs: []))
                }
            }
            if !keys.isEmpty { docConceptKeys[docID] = keys }
        }
        // Related = co-occurrence in the same document.
        for keys in docConceptKeys.values {
            let keyArray = Array(keys)
            for key in keyArray {
                guard let idx = byKey[key] else { continue }
                for other in keyArray where other != key {
                    if !merged[idx].relatedConceptIDs.contains(other) {
                        merged[idx].relatedConceptIDs.append(other)
                    }
                }
            }
        }
        return merged.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Resolves an open document's reference list to the "cited:key"
    /// hallway IDs that should receive a citation line. The key formula
    /// mirrors CitationGraph.key so IDs match across the hallway build.
    func populateCitations(forDocID docID: String) {
        guard let doc = index.byID[docID]?.doc else { return }
        var ids: Set<String> = []
        for reference in doc.references {
            guard let record = BibTeXRecord.records(in: reference.bibtex).first else { continue }
            let title = !record.title.isEmpty ? record.title : (reference.citedAs ?? "")
            guard !title.isEmpty else { continue }
            let author = record.fields["author"] ?? ""
            let key = (title + "|" + author).lowercased()
                .replacingOccurrences(of: " ", with: "")
            ids.insert("cited:" + key)
        }
        openDocCitations[docID] = ids
    }

    func pose(of docID: String) -> PanelPose {
        panelPoses[docID] ?? .upright
    }

    /// A cited work the reader wants as a book: listed in the shared
    /// acquisitions file for the Mac's library to show and download.
    func requestAcquisition(key: String, title: String, author: String,
                            year: Int?, doi: String?) {
        guard let folder = index.folderURL else { return }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        EPUBAcquisitions.add(
            EPUBAcquisitions.Wanted(id: key, title: title, author: author,
                                    year: year, doi: doi, added: .now),
            in: folder)
        acquisitionIDs.insert(key)
    }

    /// Pin and Set Aside travel through the community folder, so the
    /// Mac and this device agree on the pile. The adopted concepts
    /// ride along so this device's writes never strip them.
    private func publishStanding() {
        guard let folder = index.folderURL else { return }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        standingWrittenAt = EPUBStanding.write(pinned: pinnedIDs,
                                               setAside: setAsideIDs,
                                               concepts: concepts,
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
        if let shared = state.concepts {
            concepts = shared
            UserDefaults.standard.set(concepts, forKey: "viewConcepts")
        }
    }

    /// The articles whose text carries a concept — the Map's concept
    /// pick highlights them.
    func articleIDs(mentioning concept: String) -> Set<String> {
        let needle = concept.lowercased()
        guard !needle.isEmpty else { return [] }
        var matches: Set<String> = []
        for record in epubRecords {
            if record.title.lowercased().contains(needle) {
                matches.insert(record.id)
                continue
            }
            guard let doc = index.byID[record.id]?.doc else { continue }
            if (doc.body ?? []).contains(where: {
                $0.text.lowercased().contains(needle)
            }) {
                matches.insert(record.id)
            }
        }
        return matches
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
        adoptStanding()
        // The citation graph the Mac researched — what the cited works
        // themselves cite — reads in from the same folder; this device
        // never crawls.
        CitationGraph.adoptMirror(from: folder)
        adoptSankeyData(from: folder)
        adoptFloorHistory(from: folder)
        acquisitionIDs = Set(EPUBAcquisitions.read(from: folder).map(\.id))
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
            if pinnedIDs.remove(old.id) != nil { pinnedIDs.insert(successor.id) }
            if setAsideIDs.remove(old.id) != nil { setAsideIDs.insert(successor.id) }
            try? FileManager.default.removeItem(
                at: Self.epubsRoot.appendingPathComponent(old.folder, isDirectory: true))
            epubRecords.removeAll { $0.id == old.id }
        }
        UserDefaults.standard.set(pinnedIDs.sorted(), forKey: "epubTopOfPile")
        UserDefaults.standard.set(setAsideIDs.sorted(), forKey: "epubSetAside")
        persistEPUBRecords()
        rebuildEPUBIndex()
    }

    // MARK: - Annotations (the reader's highlights and notes)

    /// Sidecars live in one folder beside the unpacked books, keyed by
    /// book address — the Mac's and the phone's layout exactly
    /// (AppModel and PhoneModel hold the sibling copies; keep in step).
    /// The book itself is never modified.
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

    // MARK: - The time-spread's data lines

    /// The Sankey's series — yearly values standing on the corridor's
    /// own Z axis. Adopted from the community folder (the Mac fetches
    /// New York's first pair); this device fetches only what the user
    /// asks for here, and never re-fetches what the mirror holds.
    private(set) var sankey: SankeySpace.Dataset?

    private func adoptSankeyData(from folder: URL) {
        if let dataset = SankeySpace.read(from: folder), !dataset.series.isEmpty {
            sankey = dataset
        }
        seedDefaultTimeflows()
    }

    /// The corridor's default Timeflows, seeded once per device:
    /// computing on the left wall, the world on the right. They join
    /// whatever the mirror already carries, and a removal afterwards
    /// is respected — the seed never returns on its own.
    private func seedDefaultTimeflows() {
        let key = "seededDefaultTimeflows"
        guard !UserDefaults.standard.bool(forKey: key), !isFetchingSankey else { return }
        isFetchingSankey = true
        Task { @MainActor in
            defer { isFetchingSankey = false }
            let series = await SankeySpace.defaultWallSeries()
            guard !series.isEmpty else { return }
            UserDefaults.standard.set(true, forKey: key)
            adoptSankeySeries(series)
        }
    }

    @ObservationIgnored private var isFetchingSankey = false

    /// The floor's themed histories, adopted from the mirror — a theme
    /// no Mac has filled yet is fetched here when the reader picks it.
    /// The revision ticks whenever any theme lands, so the floor
    /// redraws.
    private(set) var floorHistories: [SankeySpace.FloorTheme: SankeySpace.FloorHistory] = [:]
    private(set) var floorRevision = 0

    @ObservationIgnored private var fetchingFloorThemes: Set<SankeySpace.FloorTheme> = []

    func floorHistory(for theme: SankeySpace.FloorTheme) -> SankeySpace.FloorHistory? {
        floorHistories[theme]
    }

    private func adoptFloorHistory(from folder: URL) {
        for theme in SankeySpace.FloorTheme.allCases {
            if let history = SankeySpace.readFloorHistory(theme: theme, from: folder),
               !history.events.isEmpty {
                floorHistories[theme] = history
            }
        }
        // The user's own timelines — curated on the Mac (a Wikidata
        // query or an imported file), read whole from the mirror; a
        // removed one leaves the floor here too.
        var adopted: [String: SankeySpace.FloorHistory] = [:]
        for entry in SankeySpace.listUserFloorTimelines(in: folder) {
            if let history = SankeySpace.readUserFloorHistory(slug: entry.slug,
                                                              from: folder),
               !history.events.isEmpty {
                adopted[entry.slug] = history
            }
        }
        userFloorHistories = adopted
        floorRevision += 1
    }

    /// The user timelines by slug, and the floor picker's entries.
    private(set) var userFloorHistories: [String: SankeySpace.FloorHistory] = [:]

    struct UserFloorEntry: Identifiable {
        let slug: String
        let name: String
        var id: String { slug }
    }

    var userFloorEntries: [UserFloorEntry] {
        userFloorHistories
            .map { UserFloorEntry(slug: $0.key, name: $0.value.name ?? $0.key) }
            .sorted { $0.name < $1.name }
    }

    func userFloorHistory(slug: String) -> SankeySpace.FloorHistory? {
        userFloorHistories[slug]
    }

    /// The picked theme must answer: absent from the mirror, it is
    /// fetched here and mirrored back.
    func ensureFloorTheme(_ theme: SankeySpace.FloorTheme) {
        guard floorHistories[theme] == nil,
              !fetchingFloorThemes.contains(theme) else { return }
        fetchingFloorThemes.insert(theme)
        Task { @MainActor in
            defer { fetchingFloorThemes.remove(theme) }
            guard let events = try? await SankeySpace.fetchFloorHistory(theme: theme),
                  !events.isEmpty else { return }
            let history = SankeySpace.FloorHistory(events: events, modified: .now)
            floorHistories[theme] = history
            floorRevision += 1
            guard let folder = index.folderURL else { return }
            let scoped = folder.startAccessingSecurityScopedResource()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            SankeySpace.writeFloorHistory(history, theme: theme, to: folder)
        }
    }

    /// The user's Ask-for-Data: a city's yearly min/max temperatures
    /// join the diagram and the mirror — on the asking arm's graph.
    /// Throws the fetch's own words.
    func addSankeyCity(_ city: String, wall: String? = nil) async throws {
        var series = try await SankeySpace.temperatureSeries(city: city)
        for index in series.indices { series[index].wall = wall }
        adoptSankeySeries(series)
    }

    /// One of the sample shelf's long-run series joins the corridor —
    /// on the asking arm's graph.
    func addSampleFlow(_ sample: SankeySpace.SampleFlow,
                       wall: String? = nil) async throws {
        var series = try await SankeySpace.fetchSample(sample)
        series.wall = wall
        adoptSankeySeries([series])
    }

    /// New series replace their pair, land in the dataset, and travel
    /// through the mirror.
    private func adoptSankeySeries(_ series: [SankeySpace.Series]) {
        guard !series.isEmpty else { return }
        var dataset = sankey ?? SankeySpace.Dataset(series: [], modified: .now)
        for pair in Set(series.map(\.pair)) {
            dataset.series.removeAll { $0.pair == pair }
        }
        dataset.series.append(contentsOf: series)
        dataset.modified = .now
        sankey = dataset
        writeSankeyMirror(dataset)
    }

    func removeSankeyPair(_ pair: String) {
        guard var dataset = sankey else { return }
        dataset.series.removeAll { $0.pair == pair }
        dataset.modified = .now
        sankey = dataset
        writeSankeyMirror(dataset)
    }

    private func writeSankeyMirror(_ dataset: SankeySpace.Dataset) {
        guard let folder = index.folderURL else { return }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        SankeySpace.write(dataset, to: folder)
    }

    /// Opens one EPUB handed to the app directly — Files' Open In, a
    /// share, or the panel's own Open EPUB… importer. Imported (or
    /// recognised as already on the shelf) and answered with its record,
    /// entirely on this device: no Mac, no community folder required.
    func openEPUBFile(at url: URL) async -> EPUBRecord? {
        let scoped = url.startAccessingSecurityScopedResource()
        let changed = importEPUB(at: url)
        if scoped { url.stopAccessingSecurityScopedResource() }
        let name = url.deletingPathExtension().lastPathComponent
        let identity = LiquidDoc.identityKeyID(inFileName: name) ?? name
        let safe = identity.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        guard let record = epubRecords.first(where: { $0.folder == safe }) else { return nil }
        // This one book parses now, off the main thread, and joins the
        // index alone — the reader opens at once instead of waiting for
        // the whole shelf to re-parse behind it.
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
        // page — and stands selected as the desk, on solid paper,
        // whatever reading view was last in use.
        UserDefaults.standard.set("faithful", forKey: "visionReaderMode")
        readingDeskDocID = record.id
        return record
    }

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

        // Keep the existing unpack — unless the source file is newer:
        // a re-export of the same document (an added figure) must show.
        if let existing = epubRecords.first(where: { $0.folder == safe }) {
            let content = directory.appendingPathComponent(existing.contentSubpath)
            let sourceStamp = (try? url.resourceValues(
                forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let unpackedStamp = (try? content.resourceValues(
                forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if FileManager.default.fileExists(atPath: content.path),
               let sourceStamp, let unpackedStamp, sourceStamp <= unpackedStamp {
                // A shelf book from before the canonical store gets its
                // .epub back-filled from the file being scanned.
                let stored = Self.epubsRoot.appendingPathComponent(safe + ".epub")
                if !FileManager.default.fileExists(atPath: stored.path),
                   stored.path != url.path {
                    try? FileManager.default.copyItem(at: url, to: stored)
                }
                return false
            }
        }

        do {
            let unpacked = try OrigamiEPUBImporter.unpack(at: url, into: directory)
            // The .epub itself is the canonical store, kept beside the
            // unpacked cache — same layout as the Mac's shelf.
            let stored = Self.epubsRoot.appendingPathComponent(safe + ".epub")
            if stored.path != url.path {
                try? FileManager.default.removeItem(at: stored)
                try? FileManager.default.copyItem(at: url, to: stored)
            }
            // Metadata only — the Mac's discipline: no body parsing here,
            // so a large book never stalls the import. The index parses
            // bodies later, off the main thread.
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
                        openWindow(id: "concepts")
                    } label: {
                        Label("Concepts", systemImage: "sparkles.rectangle.stack")
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
    @State private var choosingEPUB = false
    @State private var shelf: Shelf = .journals

    private enum Shelf: Hashable { case articles, journals }

    var body: some View {
        Group {
            // Books already on the shelf show even before a community
            // folder is chosen — the folder feeds the shelf, it does not
            // gate it.
            if model.index.folderURL == nil, model.epubRecords.isEmpty {
                ContentUnavailableView {
                    Label("Nothing to Read Yet", systemImage: "books.vertical")
                } description: {
                    Text("Open an EPUB from Files or iCloud Drive, or choose the iCloud folder your community shares — everything published from a Mac appears here instantly.")
                } actions: {
                    Button("Open EPUB…") { choosingEPUB = true }
                    Button("Choose Folder…") { choosingFolder = true }
                }
            } else {
                // The tabs stand as a plain header ABOVE the content —
                // a safe-area inset here slid under the Journals tab's
                // own NavigationStack, the list overlapping the tabs.
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Picker("Showing", selection: $shelf) {
                            Text("Articles").tag(Shelf.articles)
                            Text("Journals").tag(Shelf.journals)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        Button {
                            choosingEPUB = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .help("Open an EPUB from Files")
                        Button {
                            openWindow(id: "lineage")
                        } label: {
                            Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                        }
                        .help("Lineage — the shelf's citation web")
                    }
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
        // An EPUB opened directly — no community folder, no Mac: the
        // book imports on this device and opens at once. The reviewer's
        // path, and anyone's first minute with the app.
        .fileImporter(isPresented: $choosingEPUB,
                      allowedContentTypes: [.epub],
                      allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task {
                var lastRecord: EPUBRecord?
                for url in urls {
                    if let record = await model.openEPUBFile(at: url) { lastRecord = record }
                }
                if let lastRecord { openWindow(id: "reader", value: lastRecord.id) }
            }
        }
        // Files' Open In / a shared EPUB lands here (the Info.plist
        // declares the type): same import, same immediate reading.
        .onOpenURL { url in
            guard url.isFileURL, url.pathExtension.lowercased() == "epub" else { return }
            Task {
                if let record = await model.openEPUBFile(at: url) {
                    openWindow(id: "reader", value: record.id)
                }
            }
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
                VisionShelfRow(record: record) {
                    openWindow(id: "reader", value: record.id)
                }
            }
        }
    }
}

/// One shelf row: title and author, the reader's whole-document note
/// beneath, and — on a long pinch — Note… to write or rewrite it: a
/// comment on the book itself, no words selected, none needed. The
/// phone's PhoneShelfRow is the sibling; keep in step.
private struct VisionShelfRow: View {
    @Environment(VisionModel.self) private var model
    let record: EPUBRecord
    let open: () -> Void
    @State private var editingNote = false
    @State private var noteDraft = ""

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.title)
                    .lineLimit(2)
                Text(record.author)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let note = model.documentNote(forAddress: record.id)?.body?.value {
                    Text(note)
                        .font(.caption)
                        .italic()
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
        }
        .contextMenu {
            Button(model.documentNote(forAddress: record.id) == nil
                   ? "Note\u{2026}" : "Edit Note\u{2026}") {
                noteDraft = model.documentNote(forAddress: record.id)?.body?.value ?? ""
                editingNote = true
            }
        }
        .sheet(isPresented: $editingNote) {
            NavigationStack {
                VStack(alignment: .leading, spacing: 10) {
                    Text(record.title)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    TextEditor(text: $noteDraft)
                        .font(.body)
                }
                .padding()
                .navigationTitle("Note")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { editingNote = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        // Save with emptied text removes the note.
                        Button("Save") {
                            model.setDocumentNote(noteDraft, forAddress: record.id)
                            editingNote = false
                        }
                    }
                }
            }
            .frame(minWidth: 460, minHeight: 320)
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
/// The Sankey's data dialog — Liquid Information's Ask-for-Data, here:
/// the series pairs standing on the corridor, each removable, and a
/// field that fetches a new city's yearly min/max temperatures from
/// Open-Meteo. One pair to begin with; the diagram takes as many as
/// the reader asks for. Lives in the Settings window's Graph Data tab.
struct VisionDataView: View {
    @Environment(VisionModel.self) private var model
    /// Which graph the dialog curates — "left" or "right", chosen by
    /// the picker atop the list (the arm chips that used to decide are
    /// gone). Untagged series stand on both graphs and so appear under
    /// either choice.
    @AppStorage("graphDataWall") private var wall = "left"

    @State private var city = ""
    @State private var isFetching = false
    @State private var status: String?
    /// The sample being fetched right now, by id — one at a time.
    @State private var fetchingSample: String?
    /// Sankey widths or a traditional line graph — read by the Map's
    /// diagram, redrawn the moment it changes.
    @AppStorage("timeSpreadStyle") private var timeSpreadStyleRaw =
        TimeSpreadStyle.sankey.rawValue
    /// Lanes apart, or every data set overlaid in one field.
    @AppStorage("timeSpreadLayout") private var timeSpreadLayoutRaw =
        TimeSpreadLayout.lanes.rawValue
    @AppStorage("visionTheme") private var visionThemeRaw = VisionTheme.light.rawValue
    /// What lies written on the physical floor beneath the corridor —
    /// three bands: left, middle, right.
    @AppStorage("floorShow") private var floorShowRaw = FloorShow.world.rawValue
    @AppStorage("floorShowMiddle") private var floorShowMiddleRaw = FloorShow.nothing.rawValue
    @AppStorage("floorShowRight") private var floorShowRightRaw = FloorShow.nothing.rawValue
    /// The snap-to-wall option, one per graph — this dialog offers its
    /// own side's.
    @AppStorage("graphSnapWallLeft") private var snapWallLeft = false
    @AppStorage("graphSnapWallRight") private var snapWallRight = false

    var body: some View {
        NavigationStack {
            List {
                Section("Graph") {
                    Picker("Graph", selection: $wall) {
                        Text("Left Graph").tag("left")
                        Text("Right Graph").tag("right")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                Section("Presentation") {
                    Picker("Style", selection: $timeSpreadStyleRaw) {
                        ForEach(TimeSpreadStyle.allCases) { style in
                            Text(style.displayName).tag(style.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    Picker("Layout", selection: $timeSpreadLayoutRaw) {
                        ForEach(TimeSpreadLayout.allCases) { layout in
                            Text(layout.displayName).tag(layout.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    Picker("Theme", selection: $visionThemeRaw) {
                        ForEach(VisionTheme.allCases) { theme in
                            Text(theme.displayName).tag(theme.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    Picker("Left Timeline", selection: $floorShowRaw) {
                        ForEach(FloorShow.allCases) { show in
                            Text(show.displayName).tag(show.rawValue)
                        }
                        ForEach(model.userFloorEntries) { entry in
                            Text(entry.name).tag("user:" + entry.slug)
                        }
                    }
                    Picker("Middle Timeline", selection: $floorShowMiddleRaw) {
                        ForEach(FloorShow.allCases) { show in
                            Text(show.displayName).tag(show.rawValue)
                        }
                        ForEach(model.userFloorEntries) { entry in
                            Text(entry.name).tag("user:" + entry.slug)
                        }
                    }
                    Picker("Right Timeline", selection: $floorShowRightRaw) {
                        ForEach(FloorShow.allCases) { show in
                            Text(show.displayName).tag(show.rawValue)
                        }
                        ForEach(model.userFloorEntries) { entry in
                            Text(entry.name).tag("user:" + entry.slug)
                        }
                    }
                    Toggle("Snap to wall",
                           isOn: wall == "left" ? $snapWallLeft : $snapWallRight)
                }
                Section("Data lines — each year a point on the corridor") {
                    let mine = (model.sankey?.pairs ?? []).filter { entry in
                        entry.series.contains { $0.wall == nil || $0.wall == wall }
                    }
                    if !mine.isEmpty {
                        ForEach(mine, id: \.pair) { entry in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.name)
                                    Text(span(of: entry.series))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(role: .destructive) {
                                    model.removeSankeyPair(entry.pair)
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    } else {
                        Text("No data lines on this graph yet — add a sample below, or ask for a city's temperatures.")
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Samples — the last 150 years") {
                    ForEach(SankeySpace.sampleFlows) { sample in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(sample.name)
                                Text(sample.note)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if model.sankey?.series.contains(where: {
                                $0.pair == sample.id && ($0.wall == nil || $0.wall == wall)
                            }) == true {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.secondary)
                            } else if fetchingSample == sample.id {
                                ProgressView().controlSize(.small)
                            } else {
                                Button("Add") { addSample(sample) }
                                    .buttonStyle(.borderless)
                                    .disabled(fetchingSample != nil)
                            }
                        }
                    }
                }
                Section("Ask for data") {
                    HStack {
                        TextField("A city — yearly min/max temperatures", text: $city)
                            .onSubmit { ask() }
                        Button("Add") { ask() }
                            .disabled(city.trimmingCharacters(in: .whitespaces).isEmpty
                                      || isFetching)
                    }
                    if isFetching {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Fetching the archive\u{2026}")
                                .foregroundStyle(.secondary)
                        }
                    } else if let status {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("Weather data by Open-Meteo.com")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .navigationTitle("Graph Data")
        }
    }

    private func span(of series: [SankeySpace.Series]) -> String {
        let years = series.flatMap { $0.values.map(\.year) }
        guard let first = years.min(), let last = years.max() else { return "" }
        let unit = series.first?.unit ?? ""
        return "min and max \(unit), \(first)\u{2013}\(last)"
    }

    private func ask() {
        let name = city.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !isFetching else { return }
        isFetching = true
        status = nil
        Task { @MainActor in
            defer { isFetching = false }
            do {
                try await model.addSankeyCity(name, wall: wall)
                status = "Added \(name)."
                city = ""
            } catch {
                status = error.localizedDescription
            }
        }
    }

    private func addSample(_ sample: SankeySpace.SampleFlow) {
        guard fetchingSample == nil else { return }
        fetchingSample = sample.id
        status = nil
        Task { @MainActor in
            defer { fetchingSample = nil }
            do {
                try await model.addSampleFlow(sample, wall: wall)
                status = "Added \(sample.name)."
            } catch {
                status = error.localizedDescription
            }
        }
    }
}

struct VisionSettingsView: View {
    @Environment(VisionModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @AppStorage("xrMaxTitleLines") private var maxTitleLines = 2
    @AppStorage("xrMaxAuthorLines") private var maxAuthorLines = 1
    /// The Reading Desk's dress — worn while a document is read alone.
    @AppStorage("readingDeskTheme") private var deskThemeRaw =
        ReadingDeskTheme.light.rawValue
    /// Swap Arms: every wrist chip on the opposite forearm. The Map's
    /// ArmMenu watches this key and flips live.
    @AppStorage("armMenuInverted") private var armMenuInverted = false
    @State private var choosingFolder = false

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                generalTab
            }
            // The graphs' data dialog — its arm chips are gone; this
            // tab is the one door.
            Tab("Graph Data", systemImage: "chart.line.uptrend.xyaxis") {
                VisionDataView()
            }
        }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.openFolder(url) }
        }
    }

    private var generalTab: some View {
        NavigationStack {
            Form {
                Section("Reading Desk") {
                    Picker("Theme", selection: $deskThemeRaw) {
                        ForEach(ReadingDeskTheme.allCases) { theme in
                            Text(theme.displayName).tag(theme.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text("Worn by the document while it is read alone on the Reading Desk — the Hallway's panels keep their glass.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Toggle("Swap Arms", isOn: $armMenuInverted)
                } header: {
                    Text("Arm Menus")
                } footer: {
                    Text("Moves every wrist chip to the opposite forearm — for wearing the working row on the other arm.")
                }
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
    }
}



/// A reader panel's pose in the room: standing, the drafting-board
/// tilt, or flat on the table.
enum PanelPose: String {
    case upright
    case tilted
    case flat
}

/// The EPUB's own pages for the Default reading: local files only, no
/// navigation away.
private struct FaithfulWebView: UIViewRepresentable {
    let page: URL
    let base: URL

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.loadFileURL(page, allowingReadAccessTo: base)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}
}

/// The full article, opened by double-tapping a card in the Knowledge
/// Space (or a row in the library).
struct VisionReaderView: View {
    @Environment(VisionModel.self) private var model
    let docID: String
    /// The speaker whose statements are being browsed, sheet-presented.
    @State private var browsingSpeaker: SpeakerSelection?
    /// The reading controls, the Mac's foot bar brought over whole:
    /// every reading view macOS has, plus the on-device AI reading.
    /// Persisted, and read by the hosting panel so Horizontal earns
    /// its width.
    @AppStorage("visionReaderMode") private var modeRaw = Mode.faithful.rawValue
    /// Outline: the sections clicked open, by heading id.
    @State private var expanded: Set<String> = []
    @State private var showsContents = false
    /// Focus: the one paragraph being read.
    @State private var focusIndex = 0
    /// The AI reading: the summary once made, and its making.
    @State private var aiSummary: String?
    @State private var aiWorking = false
    @State private var aiError: String?
    /// One point either way for every reading, remembered — the Aa menu.
    @AppStorage("visionReaderFontDelta") private var fontDelta = 0.0
    /// The desk theme — when this reading IS the desk, the Horizontal
    /// columns wear its paper instead of the room's glass.
    @AppStorage("readingDeskTheme") private var deskThemeRaw =
        ReadingDeskTheme.light.rawValue
    /// The document's own interactions, the Mac's brought over whole:
    /// the stretchtext blocks clicked open, the tapped citation's card,
    /// the dagger's endnote.
    @State private var openStretch: Set<String> = []
    @State private var citationTarget: CitationTarget?
    @State private var noteTarget: NoteTarget?
    /// The selection a Note… is being written for, and the words typed.
    @State private var annotating: VisionModel.ReaderSelection?
    @State private var noteDraft = ""
    @Environment(\.colorScheme) private var colorScheme

    private var mode: Mode { Mode(rawValue: modeRaw) ?? .scroll }

    private var isDesk: Bool { model.readingDeskDocID == docID }
    private var deskTheme: ReadingDeskTheme {
        ReadingDeskTheme(rawValue: deskThemeRaw) ?? .light
    }

    /// The scheme the reading actually wears: the desk theme's when it
    /// stands on paper, the room's otherwise. Everything that colours
    /// ink — the environment AND the attributed text, whose colours are
    /// baked at build time — must read this, never `colorScheme` raw.
    private var readingScheme: ColorScheme {
        isDesk ? deskTheme.scheme : colorScheme
    }

    /// A page lying flat on the table is read from above at arm's
    /// length — its type steps down to suit; the drafting tilt takes
    /// the middle way.
    private var typeScale: CGFloat {
        switch model.pose(of: docID) {
        case .upright: 1.0
        case .tilted: 0.75
        case .flat: 0.55
        }
    }

    /// The Mac's reading views, here: Default (the EPUB's own pages),
    /// Scroll, Horizontal, Focus, Outline, and AI.
    private enum Mode: String, CaseIterable {
        case faithful, scroll, horizontal, focus, outline, ai

        var word: String {
            switch self {
            case .faithful: "Default"
            case .scroll: "Scroll"
            case .horizontal: "Horizontal"
            case .focus: "Focus"
            case .outline: "Outline"
            case .ai: "AI"
            }
        }
    }

    private struct SpeakerSelection: Identifiable {
        let name: String
        var id: String { name }
    }

    private struct CitationTarget: Identifiable {
        let key: String
        var id: String { key }
    }

    private struct NoteTarget: Identifiable {
        let noteID: String
        var id: String { noteID }
    }

    var body: some View {
        if let doc = model.index.byID[docID]?.doc {
            Group {
                switch mode {
                case .faithful:
                    faithfulView(doc)
                case .horizontal:
                    horizontalView(doc)
                case .focus:
                    focusView(doc)
                case .ai:
                    aiView(doc)
                case .scroll, .outline:
                    scrollBody(doc)
                }
            }
            // The selected reading — the desk — stands on solid paper,
            // not the room's glass, whatever the reading view. The
            // theme's colour scheme rides with its page: light paper
            // reads in dark ink, never visionOS's default white.
            .background {
                if isDesk { deskTheme.page.ignoresSafeArea() }
            }
            .environment(\.colorScheme, readingScheme)
            // Opening a reading selects it: the newest reading is the
            // desk, and earlier ones return to glass.
            .onAppear { model.readingDeskDocID = docID }
            .sheet(item: $browsingSpeaker) { selection in
                VisionSpeakerStatementsView(name: selection.name)
            }
            // A tapped citation opens the source's card; a dagger its
            // endnote — as on the Mac. Overlaid, not sheeted: this
            // view lives on a RealityKit attachment, where a sheet has
            // no window to present in.
            .overlay {
                if let target = citationTarget {
                    VisionCitationSheet(doc: doc, key: target.key) {
                        citationTarget = nil
                    }
                    // Lifted toward the reader: Horizontal's glass
                    // columns render with real depth in front of the
                    // attachment plane, and a flat overlay would sit
                    // behind them.
                    .offset(z: 40)
                } else if let selection = annotating {
                    VisionNotePanel(quote: selection.text, draft: $noteDraft,
                                    onCancel: { annotating = nil },
                                    onSave: {
                        model.addComment(noteDraft, on: selection)
                        annotating = nil
                    })
                    .offset(z: 40)
                } else if let target = noteTarget {
                    VisionEndnoteSheet(
                        text: OrigamiReading.endnote(withID: target.noteID, in: doc)
                            .map { inline($0, doc: doc) }
                            ?? AttributedString("The document carries no note \(target.noteID).")) {
                        noteTarget = nil
                    }
                }
            }
            // The reading's own links: origami-cite to the card,
            // origami-note to the endnote, origami-stretch folds and
            // unfolds; everything else opens as links do.
            .environment(\.openURL, OpenURLAction { url in
                handle(url, doc: doc) ? .handled : .systemAction
            })
            // While this article is open, its card leaves the Map; the
            // card returns the moment the window closes.
            .onAppear {
                model.openDocIDs.insert(docID)
                model.populateCitations(forDocID: docID)
            }
            .onDisappear {
                model.openDocIDs.remove(docID)
                model.openDocCitations.removeValue(forKey: docID)
            }
        } else {
            ContentUnavailableView("Document Not Available", systemImage: "doc",
                                   description: Text("This document is not in the library folder."))
        }
    }

    /// Scroll, Outline and Transcript share the flowing page.
    private func scrollBody(_ doc: LiquidDoc) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(doc.title)
                        .font(AppFonts.heading((32 + fontDelta) * typeScale))
                        .padding(.bottom, 4)
                    Text("\(doc.displayAuthor) · \(doc.listedDateText)")
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 20)
                    if mode == .scroll {
                        // Scroll reads the whole flow, stretch folds
                        // and all.
                        flowView(readable(of: doc), doc: doc)
                    } else {
                        ForEach(shownParagraphs(of: doc)) { paragraph in
                            paragraphView(paragraph, doc: doc)
                        }
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
    }

    // MARK: Default — the EPUB's own pages

    /// The book as its publisher shaped it: the unpacked package's own
    /// XHTML in a web view, styles and all.
    @ViewBuilder private func faithfulView(_ doc: LiquidDoc) -> some View {
        if let record = model.epubRecords.first(where: { $0.id == docID }) {
            let folder = VisionModel.epubsRoot
                .appendingPathComponent(record.folder, isDirectory: true)
            FaithfulWebView(
                page: folder.appendingPathComponent(record.contentSubpath),
                base: folder)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    footBar(doc, proxy: nil)
                }
        } else {
            // Not a shelf book (a letter, a note): the flow stands in.
            scrollBody(doc)
        }
    }

    // MARK: Horizontal — pages side by side

    /// The reading cut into columns, ALL of them standing side by side
    /// — the document's whole breadth at once. (A very long reading is
    /// capped at a room-sized width and walks the rest by swipe; the
    /// attachment's render texture cannot be endless.)
    private func horizontalView(_ doc: LiquidDoc) -> some View {
        let pages = horizontalPages(of: doc)
        let pose = model.pose(of: docID)
        let columnWidth: CGFloat = pose == .flat ? 280 : 560
        let gap: CGFloat = isDesk ? 0 : 12
        let fullWidth = CGFloat(pages.count) * (columnWidth + gap)
        return ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: gap) {
                ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            if index == 0 {
                                Text(doc.title)
                                    .font(AppFonts.heading((28 + fontDelta) * typeScale))
                                    .padding(.bottom, 4)
                                Text("\(doc.displayAuthor) · \(doc.listedDateText)")
                                    .foregroundStyle(.secondary)
                                    .padding(.bottom, 16)
                            }
                            flowView(page, doc: doc)
                            // The references close the last column, as
                            // on the Mac.
                            if index == pages.count - 1 {
                                referencesSection(doc)
                            }
                        }
                        .padding(24)
                    }
                    .frame(width: columnWidth)
                    .containerRelativeFrame(.vertical)
                    .glassBackgroundEffect(in: .rect(cornerRadius: 18),
                                           displayMode: isDesk ? .never : .always)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        // The reader takes the columns' whole width, so the hosting
        // panel grows to show every one of them — capped under the
        // GPU's texture ceiling: attachments render at 2x, and a
        // texture past 8192px simply fails to draw (the body goes
        // missing). 3900pt keeps a margin; the rest walks by swipe.
        .frame(width: min(fullWidth, 3900))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            footBar(doc, proxy: nil)
        }
    }

    /// The Mac's Horizontal rule: one SECTION per column — a heading
    /// with no body of its own never breaks to a column alone; it
    /// rides atop the section that follows. A long section scrolls
    /// within its column.
    private func horizontalPages(of doc: LiquidDoc) -> [[LiquidDoc.Paragraph]] {
        var pages: [[LiquidDoc.Paragraph]] = []
        var current: [LiquidDoc.Paragraph] = []
        var currentHasBody = false
        for paragraph in readable(of: doc) {
            if paragraph.effectiveHeading != nil {
                if currentHasBody {
                    pages.append(current)
                    current = []
                    currentHasBody = false
                }
                current.append(paragraph)
            } else {
                current.append(paragraph)
                currentHasBody = true
            }
        }
        if !current.isEmpty {
            // Bare headings at the very end stay with the last column.
            if currentHasBody || pages.isEmpty {
                pages.append(current)
            } else {
                pages[pages.count - 1] += current
            }
        }
        return pages
    }

    // MARK: Focus — one paragraph at a time

    /// The Mac's Focus: one paragraph large and alone, the rest of the
    /// world quiet; arrows or a tap walk the reading.
    private func focusView(_ doc: LiquidDoc) -> some View {
        let readable = readable(of: doc)
        let index = min(focusIndex, max(readable.count - 1, 0))
        return VStack(spacing: 0) {
            Spacer()
            if readable.indices.contains(index) {
                let paragraph = readable[index]
                VStack(alignment: .leading, spacing: 10) {
                    if let speaker = paragraph.speaker {
                        Text(speaker)
                            .font(.system(size: 13, weight: .semibold))
                            .kerning(0.8)
                            .textCase(.uppercase)
                            .foregroundStyle(.secondary)
                    }
                    Text(inline(paragraph, doc: doc))
                        .font(paragraph.effectiveHeading != nil
                            ? AppFonts.heading((30 + fontDelta) * typeScale)
                            : AppFonts.body((22 + fontDelta) * typeScale))
                        .tint(.primary)
                }
                .frame(maxWidth: 560, alignment: .leading)
                .padding(28)
                .contentShape(Rectangle())
                .onTapGesture {
                    if index < readable.count - 1 { focusIndex = index + 1 }
                }
            }
            Spacer()
            HStack(spacing: 18) {
                Button {
                    focusIndex = max(index - 1, 0)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(index == 0)
                Text("\(index + 1) of \(readable.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button {
                    focusIndex = min(index + 1, readable.count - 1)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(index >= readable.count - 1)
            }
            .padding(.bottom, 8)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            footBar(doc, proxy: nil)
        }
    }

    // MARK: AI — the on-device reading

    /// The reading read for you, on this device: Apple Intelligence
    /// summarizes the document; nothing leaves the headset.
    private func aiView(_ doc: LiquidDoc) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(doc.title)
                    .font(AppFonts.heading((26 + fontDelta) * typeScale))
                Text("\(doc.displayAuthor) · \(doc.listedDateText)")
                    .foregroundStyle(.secondary)
                Divider()
                if case .available = SystemLanguageModel.default.availability {
                    if let aiSummary {
                        Text("Summary")
                            .font(.headline)
                        Text(aiSummary)
                            .font(AppFonts.body((16 + fontDelta) * typeScale))
                            .textSelection(.enabled)
                        Button("Summarize Again") { summarize(doc) }
                            .disabled(aiWorking)
                    } else if aiWorking {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Reading on this device\u{2026}")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Button("Summarize This Reading") { summarize(doc) }
                            .buttonStyle(.borderedProminent)
                        Text("The summary is made on this device by Apple Intelligence — the document never leaves the headset.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let aiError {
                        Label(aiError, systemImage: "xmark.octagon")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } else {
                    let macTopics = model.allPaperTopics[doc.id] ?? []
                    if !macTopics.isEmpty {
                        Text("Topics from macOS Analysis")
                            .font(.headline)
                        Text(macTopics.joined(separator: " · "))
                            .font(.body)
                        Text("Summarization requires Apple Intelligence, which is not available on this device. These topics were extracted on macOS.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Label("Apple Intelligence is not available on this device.",
                              systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text("Run AI Analyse on macOS to generate topics that sync here automatically.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(28)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            footBar(doc, proxy: nil)
        }
    }

    private func summarize(_ doc: LiquidDoc) {
        guard !aiWorking else { return }
        aiWorking = true
        aiError = nil
        let text = readable(of: doc).map(\.text).joined(separator: "\n")
        let title = doc.title
        Task { @MainActor in
            defer { aiWorking = false }
            do {
                let session = LanguageModelSession(instructions: """
                    You summarize academic and literary documents faithfully \
                    and plainly, in a few short paragraphs, never inventing \
                    what the text does not say.
                    """)
                let response = try await session.respond(
                    to: "Summarize \u{201C}\(title)\u{201D}:\n\n"
                        + String(text.prefix(12_000)))
                aiSummary = response.content
            } catch {
                aiError = error.localizedDescription
            }
        }
    }

    // MARK: The flow

    /// The readable body: everything in Scroll; in Outline, the headings
    /// with only the opened sections' paragraphs beneath them.
    /// The readable body, the appendix machinery left out.
    private func readable(of doc: LiquidDoc) -> [LiquidDoc.Paragraph] {
        let appendixIDs = doc.visualMetaParagraphIDs
        return (doc.body ?? []).filter { !appendixIDs.contains($0.id) }
    }

    private func shownParagraphs(of doc: LiquidDoc) -> [LiquidDoc.Paragraph] {
        let readable = readable(of: doc)
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

    /// The flow as the Mac reads it: plain paragraphs interleaved with
    /// stretch blocks — the `»` toggle riding inline at the end of the
    /// paragraph the stretch follows, the opened detail a callout.
    @ViewBuilder private func flowView(_ paragraphs: [LiquidDoc.Paragraph],
                                       doc: LiquidDoc) -> some View {
        let items = OrigamiFlowItem.build(paragraphs)
        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
            switch item {
            case .paragraph(let paragraph):
                let trailing: (id: String, run: [LiquidDoc.Paragraph])? = {
                    guard isPlainText(paragraph), index + 1 < items.count,
                          case .stretch(let id, let run) = items[index + 1]
                    else { return nil }
                    return (id, run)
                }()
                paragraphView(paragraph, doc: doc, trailingStretch: trailing)
            case .stretch(let id, let run):
                let hosted: Bool = {
                    guard index > 0, case .paragraph(let host) = items[index - 1]
                    else { return false }
                    return isPlainText(host)
                }()
                stretchBlock(id: id, run: run, doc: doc, hosted: hosted)
            }
        }
    }

    /// Whether a paragraph is running text — something an inline
    /// stretch toggle can end. Images, tables, and rules are not.
    private func isPlainText(_ paragraph: LiquidDoc.Paragraph) -> Bool {
        paragraph.tableID == nil && paragraph.text != "---"
            && LiquidDoc.imageReference(in: paragraph.text) == nil
    }

    /// One stretchtext block's detail, a callout under its host; the
    /// revealed words themselves fold it back.
    @ViewBuilder private func stretchBlock(id: String, run: [LiquidDoc.Paragraph],
                                           doc: LiquidDoc, hosted: Bool) -> some View {
        let isOpen = openStretch.contains(id)
        if !hosted {
            // A stretch with no text before it (rare) gets a toggle of
            // its own; a hosted one lives at its host's line end.
            Button {
                toggleStretch(id)
            } label: {
                Text(isOpen ? "\u{2039}" : "\u{00BB}")
                    .font(.callout.bold())
            }
            .buttonStyle(.plain)
            .help(isOpen ? "Close the stretchtext" : "Open the stretchtext")
            .padding(.bottom, 12)
        }
        if isOpen {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(run) { paragraph in
                    Text(OrigamiReading.stretchRevealed(
                            inline(paragraph, doc: doc),
                            id: id, closing: paragraph.id == run.last?.id))
                        .font(font(for: paragraph))
                        .tint(.primary)
                }
            }
            .padding(.leading, 14)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(.tertiary)
                    .frame(width: 3)
            }
            .padding(.bottom, 12)
        }
    }

    private func toggleStretch(_ id: String) {
        withAnimation(.easeInOut(duration: 0.15)) {
            if openStretch.contains(id) {
                openStretch.remove(id)
            } else {
                openStretch.insert(id)
            }
        }
    }

    /// A paragraph's words with their conventions live: citations as
    /// links on the origami-cite scheme, endnote daggers on
    /// origami-note, and — when a stretch follows — its `»`/`‹` toggle
    /// at the line's end.
    private func inline(_ paragraph: LiquidDoc.Paragraph, doc: LiquidDoc,
                        trailingStretch: (id: String, run: [LiquidDoc.Paragraph])? = nil)
        -> AttributedString {
        var out = OrigamiReading.inlineAttributed(paragraph.text, in: doc,
                                                  citations: .authorDate,
                                                  appearance: readingScheme)
        out = painted(out, paragraphID: paragraph.id)
        if let trailing = trailingStretch,
           let url = URL(string: OrigamiReading.stretchScheme + ":" + trailing.id) {
            var mark = AttributedString(
                openStretch.contains(trailing.id) ? " \u{2039}" : " \u{00BB}")
            mark.link = url
            out += mark
        }
        return out
    }

    /// The reading's own schemes, caught; true consumes the tap.
    private func handle(_ url: URL, doc: LiquidDoc) -> Bool {
        if let key = OrigamiReading.citationKey(from: url) {
            citationTarget = CitationTarget(key: key)
            return true
        }
        if let noteID = OrigamiReading.noteID(from: url) {
            noteTarget = NoteTarget(noteID: noteID)
            return true
        }
        if url.scheme == OrigamiReading.stretchScheme {
            let raw = String(url.absoluteString
                .dropFirst(OrigamiReading.stretchScheme.count + 1))
            toggleStretch(raw.removingPercentEncoding ?? raw)
            return true
        }
        return false
    }

    @ViewBuilder private func paragraphView(_ paragraph: LiquidDoc.Paragraph,
                                            doc: LiquidDoc,
                                            trailingStretch: (id: String, run: [LiquidDoc.Paragraph])? = nil)
        -> some View {
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
                // Links wear the body's own ink, and the words select:
                // the selection carries the reader's verbs — Copy, Copy
                // Citation, Highlight, Note — as on the phone.
                VisionSelectableParagraph(
                    attributed: inline(paragraph, doc: doc, trailingStretch: trailingStretch),
                    baseSize: max((paragraphBaseSize(paragraph) + fontDelta) * typeScale, 6),
                    baseBold: paragraph.effectiveHeading != nil,
                    onLink: { handle($0, doc: doc) },
                    onCopyCitation: { selected in
                        copySelectionCitation(doc, paragraph: paragraph, selected: selected)
                    },
                    onHighlight: { kind, selected, prefix, suffix in
                        model.addTag(kind, on: VisionModel.ReaderSelection(
                            address: docID, paragraphID: paragraph.id,
                            text: selected, prefix: prefix, suffix: suffix))
                    },
                    onNote: { selected, prefix, suffix in
                        noteDraft = ""
                        annotating = VisionModel.ReaderSelection(
                            address: docID, paragraphID: paragraph.id,
                            text: selected, prefix: prefix, suffix: suffix)
                    },
                    onRemoveHighlights: { selected in
                        removeHighlights(doc: doc, paragraph: paragraph, selected: selected)
                    })
            }
        }
        .padding(.bottom, 12)
        .id(paragraph.id)   // the contents land here
    }

    /// The reference list closing the reading, as on the Mac.
    @ViewBuilder private func referencesSection(_ doc: LiquidDoc) -> some View {
        if !doc.references.isEmpty, mode == .scroll || mode == .horizontal {
            Divider()
                .padding(.vertical, 12)
            Text("References")
                .font(AppFonts.heading((23 + fontDelta) * typeScale))
                .padding(.bottom, 8)
            ForEach(Array(doc.references.enumerated()), id: \.element.id) { index, reference in
                Text(referenceLine(reference, number: index + 1))
                    .font(AppFonts.body(max((14 + fontDelta) * typeScale, 6)))
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

    private func footBar(_ doc: LiquidDoc, proxy: ScrollViewProxy?) -> some View {
        let headings = (doc.body ?? []).filter { $0.effectiveHeading != nil }
        let modes: [Mode] = [.faithful, .scroll, .horizontal, .focus, .outline, .ai]
        return HStack(spacing: 12) {
            Spacer()
            ForEach(Array(modes.enumerated()), id: \.offset) { index, word in
                if index > 0 { separator }
                modeWord(word.word, chosen: mode == word) {
                    modeRaw = word.rawValue
                    if word == .outline { expanded = [] }
                    if word == .focus { focusIndex = 0 }
                }
            }
            separator
            Button {
                showsContents = true
            } label: {
                Image(systemName: "list.bullet")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(headings.isEmpty || proxy == nil)
            .help("Contents — every section, one click away")
            .popover(isPresented: $showsContents) {
                List(headings) { heading in
                    Button {
                        showsContents = false
                        withAnimation { proxy?.scrollTo(heading.id, anchor: .top) }
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
        AppFonts.body(max((paragraphBaseSize(paragraph) + fontDelta) * typeScale, 6),
                      weight: paragraph.effectiveHeading == nil ? .regular : .bold)
    }

    private func paragraphBaseSize(_ paragraph: LiquidDoc.Paragraph) -> CGFloat {
        switch paragraph.effectiveHeading {
        case 1: 28
        case 2: 23
        case 3: 19
        default: 17
        }
    }


    /// Clears any highlight or judgment the selection touches — quotes
    /// and selection are compared as ranges over the rendered words,
    /// the same text they were captured from.
    private func removeHighlights(doc: LiquidDoc, paragraph: LiquidDoc.Paragraph,
                                  selected: String) {
        let plain = String(inline(paragraph, doc: doc).characters)
        let selectedRange = plain.range(of: selected)
        model.removeAnnotations(inParagraph: paragraph.id, at: docID) { quote in
            if let selectedRange, let quoteRange = plain.range(of: quote) {
                return selectedRange.overlaps(quoteRange)
            }
            return quote.contains(selected) || selected.contains(quote)
        }
    }

    /// Paints the reader's annotations over the paragraph's words — the
    /// kind's colour behind the exact quote. The phone's sibling.
    private func painted(_ attributed: AttributedString,
                         paragraphID: String) -> AttributedString {
        _ = model.annotationsStamp   // repaint when the sidecar changes
        let annotations = model.annotations(forAddress: docID)
        guard !annotations.isEmpty else { return attributed }
        var out = attributed
        let plain = String(out.characters)
        for annotation in annotations {
            var fragment: String?
            var quote: String?
            for selector in annotation.target.selectors {
                switch selector {
                case .fragment(let value, _): fragment = fragment ?? value
                case .quote(let exact, _, _): quote = quote ?? exact
                default: break
                }
            }
            guard let quote else { continue }
            if let fragment, fragment != paragraphID { continue }
            guard let range = plain.range(of: quote),
                  let attrRange = Range(range, in: out) else { continue }
            let kind = ReaderAnnotationKind.kind(of: annotation) ?? .highlight
            out[attrRange].backgroundColor =
                VisionAnnotationInk.color(of: kind).opacity(0.35)
        }
        return out
    }

    /// The Mac's citation clipboard, headset-sized: the private JSON for
    /// Author and Origami Text, the quoted words for everyone else.
    /// Cross-app contract: the type string matches CitationClipboard.
    private func copySelectionCitation(_ doc: LiquidDoc,
                                       paragraph: LiquidDoc.Paragraph,
                                       selected: String) {
        let record = model.epubRecords.first { $0.id == docID }
        let payload = OrigamiReading.authorCitationPayload(
            for: paragraph, in: doc, quote: selected,
            sourceFile: record?.originalFilename, doi: record?.doi)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let year = doc.date?.yearText
            ?? String(calendar.component(.year, from: doc.created))
        let citation = OrigamiCitation(
            to: doc.id, fragment: paragraph.id, rel: "cites",
            quotedText: payload.content,
            author: doc.displayAuthor, year: year,
            bibtex: payload.bibtex,
            documentTitle: doc.title,
            documentFilename: record?.originalFilename)
        var item: [String: Any] = ["public.utf8-plain-text": payload.content]
        if let data = try? JSONEncoder().encode(citation) {
            item["info.futuretextlab.origami-citation"] = data
        }
        UIPasteboard.general.items = [item]
    }
}

/// A tapped citation's card, overlaid on the reading: all the record
/// the document carries — with Acquire at the bottom centre when the
/// library lacks the work, listing it in the Mac's Time view.
private struct VisionCitationSheet: View {
    @Environment(VisionModel.self) private var model
    let doc: LiquidDoc
    let key: String
    let onClose: () -> Void

    var body: some View {
        // An internal citation's key is the cited document's address —
        // the link to it carries its own BibTeX, as on the Mac.
        let reference = doc.references.first { $0.id == key }
            ?? doc.links.first { $0.to == key }?.bibtex
                .map { LiquidDoc.Reference(id: key, bibtex: $0) }
        let fields = reference.flatMap { BibTeXParser.first($0.bibtex)?.fields } ?? [:]
        let title = fields["title"] ?? reference?.citedAs ?? key
        let author = fields["author"] ?? ""
        let year = fields["year"].flatMap { Int($0.prefix(4)) }
        let doi = fields["doi"] ?? fields["url"]
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.headline)
                    .lineLimit(3)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonBorderShape(.circle)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text([author, year.map(String.init), fields["journal"]]
                        .compactMap { $0 }
                        .filter { !$0.isEmpty }
                        .joined(separator: ", "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let abstract = fields["abstract"], !abstract.isEmpty {
                        Text(abstract)
                            .font(.callout)
                    } else {
                        Text("No abstract on record.")
                            .font(.callout)
                            .italic()
                            .foregroundStyle(.secondary)
                    }
                    if let doi, !doi.isEmpty {
                        Text("doi: \(doi)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            Group {
                if model.acquisitionIDs.contains(key) {
                    Label("Listed to acquire", systemImage: "checkmark")
                        .foregroundStyle(.secondary)
                } else {
                    Button("Acquire") {
                        model.requestAcquisition(key: key, title: title,
                                                 author: author, year: year, doi: doi)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(.vertical, 12)
        }
        .frame(width: 460, height: 400)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
        .shadow(radius: 12)
    }
}

/// An endnote, opened from its dagger — the note's own links live.
private struct VisionEndnoteSheet: View {
    let text: AttributedString
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Note")
                    .font(.headline)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonBorderShape(.circle)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            ScrollView {
                Text(text)
                    .font(AppFonts.body(17))
                    .tint(.primary)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 420, height: 280)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
        .shadow(radius: 12)
    }
}

/// The annotation kinds' inks — the Mac's AnnotationKindStyle, headset-
/// sized: the same UserDefaults keys and default colours, so a kind
/// renamed or recoloured on the Mac reads the same here. Keep in step
/// (AnnotationsListView.swift holds the original; PhoneReadView's
/// PhoneAnnotationInk is the phone sibling).
enum VisionAnnotationInk {
    static func displayName(of kind: ReaderAnnotationKind) -> String {
        let names = UserDefaults.standard.dictionary(forKey: "annotationKindNames")
            as? [String: String]
        let custom = names?[kind.rawValue]?.trimmingCharacters(in: .whitespaces)
        return custom?.isEmpty == false ? custom! : kind.rawValue
    }

    static func defaultHex(of kind: ReaderAnnotationKind) -> String {
        switch kind {
        case .important: "E4572E"
        case .quotable: "2E8B8B"
        case .great: "3A9B35"
        case .disagree: "C93C3C"
        case .languageIssue: "8E5BC0"
        case .problematic: "D98E1B"
        case .whatIsThis: "3B6FD4"
        case .highlight: "E8C51D"
        case .strikethrough: "8A8A8A"
        }
    }

    static func color(of kind: ReaderAnnotationKind) -> Color {
        let colors = UserDefaults.standard.dictionary(forKey: "annotationKindColors")
            as? [String: String]
        let hex = colors?[kind.rawValue] ?? defaultHex(of: kind)
        return Color(hexCode: hex) ?? .yellow
    }
}

/// One paragraph as a real text view: live selection with the reader's
/// verbs on it — Copy, Copy Citation, Highlight, Note — the phone's
/// PhoneSelectableParagraph, headset-sized; keep the two in step. Links
/// route to the reading's cards and wear the body's ink.
private struct VisionSelectableParagraph: UIViewRepresentable {
    let attributed: AttributedString
    let baseSize: CGFloat
    let baseBold: Bool
    /// A link was tapped; true means the reading handled it.
    let onLink: (URL) -> Bool
    let onCopyCitation: (String) -> Void
    /// The judgment, the exact words, and their neighbours for the anchor.
    let onHighlight: (ReaderAnnotationKind, String, String?, String?) -> Void
    let onNote: (String, String?, String?) -> Void
    /// The selection whose touching highlights should be cleared.
    let onRemoveHighlights: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: VisionSelectableParagraph
        init(_ parent: VisionSelectableParagraph) { self.parent = parent }

        func textView(_ textView: UITextView, shouldInteractWith url: URL,
                      in characterRange: NSRange,
                      interaction: UITextItemInteraction) -> Bool {
            !parent.onLink(url)
        }

        /// The selection and its neighbours (32 characters each side),
        /// the annotation's disambiguating context.
        private func pieces(of textView: UITextView, in range: NSRange)
            -> (selected: String, prefix: String?, suffix: String?)? {
            let full = textView.text ?? ""
            guard range.length > 0, let swiftRange = Range(range, in: full) else { return nil }
            let selected = String(full[swiftRange])
            guard !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            let prefix = String(full[..<swiftRange.lowerBound].suffix(32))
            let suffix = String(full[swiftRange.upperBound...].prefix(32))
            return (selected, prefix.isEmpty ? nil : prefix, suffix.isEmpty ? nil : suffix)
        }

        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange,
                      suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard let pieces = pieces(of: textView, in: range) else { return nil }
            let parent = parent
            let copy = UIAction(title: "Copy",
                                image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.string = pieces.selected
            }
            let cite = UIAction(title: "Copy Citation",
                                image: UIImage(systemName: "quote.opening")) { _ in
                parent.onCopyCitation(pieces.selected)
            }
            var kinds: [UIMenuElement] = ReaderAnnotationKind.allCases.map { kind in
                UIAction(title: VisionAnnotationInk.displayName(of: kind),
                         image: UIImage(systemName: kind.systemImage)) { _ in
                    parent.onHighlight(kind, pieces.selected, pieces.prefix, pieces.suffix)
                }
            }
            // The eraser closes the list: any highlight the selection
            // touches, gone — the Mac's Remove Annotations.
            kinds.append(UIAction(title: "Remove",
                                  image: UIImage(systemName: "eraser"),
                                  attributes: .destructive) { _ in
                parent.onRemoveHighlights(pieces.selected)
            })
            let highlight = UIMenu(title: "Highlight",
                                   image: UIImage(systemName: "highlighter"),
                                   children: kinds)
            let note = UIAction(title: "Note\u{2026}",
                                image: UIImage(systemName: "square.and.pencil")) { _ in
                parent.onNote(pieces.selected, pieces.prefix, pieces.suffix)
            }
            // Copy stands last — the reader's own verbs lead.
            return UIMenu(children: [cite, highlight, note, copy])
        }
    }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = false
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        view.linkTextAttributes = [.foregroundColor: UIColor.label]
        let converted = converted()
        // Replacing the text drops any live selection; only real
        // content changes are worth that.
        if view.attributedText?.isEqual(to: converted) != true {
            view.attributedText = converted
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView,
                      context: Context) -> CGSize? {
        // Measure at the proposed width; when none is proposed, at the
        // width the view actually has, so every pass agrees.
        let width = proposal.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            ?? (uiView.bounds.width > 0 ? uiView.bounds.width : 560)
        let size = uiView.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(size.height))
    }

    /// The reading's own family at this size — AppFonts.body as UIKit
    /// sees it, the serif system face standing in for unknown names.
    private func baseUIFont() -> UIFont {
        if let named = UIFont(name: AppFonts.bodyFamily, size: baseSize) {
            return baseBold
                ? UIFont(descriptor: named.fontDescriptor.withSymbolicTraits(.traitBold)
                    ?? named.fontDescriptor, size: baseSize)
                : named
        }
        let plain = UIFont.systemFont(ofSize: baseSize,
                                      weight: baseBold ? .bold : .regular)
        return plain.fontDescriptor.withDesign(.serif)
            .map { UIFont(descriptor: $0, size: baseSize) } ?? plain
    }

    /// The AttributedString with its semantic runs resolved into UIKit
    /// attributes — presentation intents to bold/italic/monospace on the
    /// reading face, colours and links carried across. The Mac's
    /// SelectableParagraph.converted() is the original; keep in step.
    private func converted() -> NSAttributedString {
        let base = baseUIFont()
        let out = NSMutableAttributedString()
        for run in attributed.runs {
            let text = String(attributed.characters[run.range])
            var font = base
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) {
                    font = .monospacedSystemFont(ofSize: baseSize * 0.92, weight: .regular)
                }
                var traits: UIFontDescriptor.SymbolicTraits = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
                if intent.contains(.emphasized) { traits.insert(.traitItalic) }
                if !traits.isEmpty,
                   let descriptor = font.fontDescriptor.withSymbolicTraits(
                       font.fontDescriptor.symbolicTraits.union(traits)) {
                    font = UIFont(descriptor: descriptor, size: baseSize)
                }
            }
            let ink = run.foregroundColor.map(UIColor.init) ?? .label
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineSpacing = 3
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: ink,
                .paragraphStyle: paragraphStyle,
            ]
            if let background = run.backgroundColor {
                attributes[.backgroundColor] = UIColor(background)
            }
            if let link = run.link {
                attributes[.link] = link
            }
            out.append(NSAttributedString(string: text, attributes: attributes))
        }
        return out
    }
}

/// The Note being written over a selection: a glass card in the reading's
/// overlay plane (sheets have no window to present in here), the quoted
/// words above the editor, Save filing the note into the sidecar.
private struct VisionNotePanel: View {
    let quote: String
    @Binding var draft: String
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Note")
                    .font(.headline)
                Spacer()
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                }
                .buttonBorderShape(.circle)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("\u{201C}\(quote)\u{201D}")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                TextEditor(text: $draft)
                    .font(AppFonts.body(17))
                    .scrollContentBackground(.hidden)
                    .background(.quaternary.opacity(0.5),
                                in: RoundedRectangle(cornerRadius: 12))
                Button("Save", action: onSave)
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(16)
        }
        .frame(width: 460, height: 340)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
        .shadow(radius: 12)
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
