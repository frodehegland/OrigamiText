import Foundation
import Observation
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// A remembered EPUB in the reader's library: enough to list it (title,
/// author, date) and to reopen its rendered page (the unpacked `folder`
/// under the app container's EPUBs directory, and the content document's
/// path within it). Persisted to an internal manifest — no JSON document
/// is written, per the EPUB-only direction.
///
/// In its own file (not EPUBReaderView.swift, which is WebKit/macOS)
/// so the visionOS target shares the shelf's record type.
struct EPUBRecord: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let author: String
    /// Every author of record, in order, when the book named more than
    /// one. Optional so manifests written before it decode unchanged.
    var authors: [String]? = nil
    /// ISO 8601, when the Visual-Meta carried a date.
    let dateISO: String?
    /// The unpack folder name under the EPUBs directory.
    let folder: String
    /// The content document's path within `folder`, e.g. "content/paper.html".
    let contentSubpath: String
    /// When it was opened, for ordering the library newest-first.
    let openedAt: Date
    /// The journal or proceedings the book is part of, when it declares
    /// one. "" means the package was checked and names none; nil means
    /// a record written before venues were kept (not yet checked).
    var publication: String? = nil

    /// The Digital Object Identifier the package declares, normalised to
    /// bare form (e.g. "10.1145/3290605.3300526"). nil for records written
    /// before DOI tracking was added or for books that carry none.
    var doi: String? = nil

    /// The original .epub filename (e.g. "My Paper.epub") — the value Author
    /// stores as `origami-source-file` in its BibTeX, used as a library
    /// fallback when UUID lookup fails. nil for records written before this
    /// field was added.
    var originalFilename: String? = nil

    /// The EPUB package's own publication identifier (the `dc:identifier`
    /// value from package.opf, typically a `urn:uuid:…`). Unlike the Origami
    /// address, this is embedded in the EPUB file itself and therefore
    /// identical across every installation that opens the same file — used
    /// as the fallback canonical URI for community annotation services when
    /// no DOI is available.
    var packageIdentifier: String? = nil

    /// The authors to list the book under: the full list when known,
    /// else the single author of record.
    var authorList: [String] { authors ?? [author] }

    /// The declared venue, empty-checked: nil when the book names none.
    var venue: String? {
        let name = publication?.trimmingCharacters(in: .whitespaces) ?? ""
        return name.isEmpty ? nil : name
    }
}

/// The reader's standing over the shelf — which books are pinned and
/// which set aside — as one small file in the community folder, so the
/// Mac and the Vision Pro agree. Whole-file, last-writer-wins: each
/// device writes on every change and adopts on every scan, skipping
/// files older than its own last write.
/// Books the reader asked for from the headset: cited works not yet in
/// the library, listed for the Mac to acquire — one small file in the
/// community folder, merged by key so a wish is never doubled.
nonisolated enum EPUBAcquisitions {

    struct Wanted: Codable, Sendable, Identifiable {
        /// The citation key — title|author, lowercased, spaceless.
        var id: String
        var title: String
        var author: String
        var year: Int?
        var doi: String?
        var added: Date
    }

    private struct State: Codable {
        var wanted: [Wanted]
        var modified: Date
    }

    private static let fileName = "origami-acquisitions.json"

    static func read(from folder: URL) -> [Wanted] {
        let url = folder.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(State.self, from: data)
        else { return [] }
        return state.wanted
    }

    static func add(_ item: Wanted, in folder: URL) {
        var wanted = read(from: folder)
        guard !wanted.contains(where: { $0.id == item.id }) else { return }
        wanted.append(item)
        write(wanted, to: folder)
    }

    static func remove(id: String, in folder: URL) {
        var wanted = read(from: folder)
        wanted.removeAll { $0.id == id }
        write(wanted, to: folder)
    }

    private static func write(_ wanted: [Wanted], to folder: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(State(wanted: wanted, modified: .now)) {
            try? data.write(to: folder.appendingPathComponent(fileName),
                            options: .atomic)
        }
    }
}

nonisolated enum EPUBStanding {

    struct State: Codable {
        var pinned: [String]
        var setAside: [String]
        /// The reader's tracked concepts (the macOS Concepts view),
        /// riding along so the Vision Pro's arm can offer them.
        /// Optional: files written before concepts travelled decode
        /// without them.
        var concepts: [String]?
        var modified: Date
    }

    private static let fileName = "origami-standing.json"

    static func read(from folder: URL) -> State? {
        let url = folder.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(State.self, from: data)
    }

    @discardableResult
    static func write(pinned: Set<String>, setAside: Set<String>,
                      concepts: [String], to folder: URL) -> Date {
        let state = State(pinned: pinned.sorted(), setAside: setAside.sorted(),
                          concepts: concepts,
                          modified: .now)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(state) {
            try? data.write(to: folder.appendingPathComponent(fileName), options: .atomic)
        }
        return state.modified
    }
}

/// Persists user-written definitions and category overrides for merged
/// concepts. Stored in Application Support (personal, not community folder)
/// so the user's annotations are never overwritten by shared library state.
@Observable
final class ConceptOverrideStore {
    private struct Entry: Codable {
        var definition: String?
        var category: String?
    }
    private var entries: [String: Entry] = [:]
    private static let fileName = "origami-concept-overrides.json"

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(fileName)
    }

    init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let loaded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = loaded
        }
    }

    func definition(for id: String) -> String? { entries[id]?.definition }
    func category(for id: String) -> String? { entries[id]?.category }

    func set(definition: String?, for id: String) {
        entries[id, default: Entry()].definition = definition?.isEmpty == true ? nil : definition
        persist()
    }

    func set(category: String?, for id: String) {
        entries[id, default: Entry()].category = category?.isEmpty == true ? nil : category
        persist()
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(entries) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }
}

/// Community supersession: when a shelf book's own file has left the
/// community folder while a same-titled sibling's file is present, the
/// absent one has been re-published — a corrected conversion, a
/// DOI-named replacement — and the old copy retires in the successor's
/// favour. Decision logic only, shared by the phone and the headset;
/// each model carries out its own retirements (standing and
/// annotations move to the successor first). The Mac needs none of
/// this: its mirror republishes anything the folder lacks, so absence
/// cannot arise there.
nonisolated enum EPUBSupersession {

    /// Case-, diacritic- and punctuation-blind title identity.
    static func titleKey(_ title: String) -> String {
        title.folding(options: [.diacriticInsensitive, .caseInsensitive],
                      locale: nil)
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    /// The unpack-folder name a file would import under — the same
    /// derivation `importEPUB` uses, so presence in the community
    /// folder can be matched against `EPUBRecord.folder`.
    static func folderName(forFileName name: String) -> String {
        let identity = LiquidDoc.identityKeyID(inFileName: name) ?? name
        return identity.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
    }

    /// The records to retire, each with its successor: the record's own
    /// file is absent from the folder while a same-titled sibling's is
    /// present. An iCloud placeholder counts as present — undownloaded
    /// is not removed, and no book retires mid-sync.
    static func retirements(records: [EPUBRecord], presentFolders: Set<String>)
        -> [(old: EPUBRecord, successor: EPUBRecord)] {
        var presentByTitle: [String: EPUBRecord] = [:]
        for record in records where presentFolders.contains(record.folder) {
            let key = titleKey(record.title)
            if !key.isEmpty, presentByTitle[key] == nil {
                presentByTitle[key] = record
            }
        }
        var retirements: [(EPUBRecord, EPUBRecord)] = []
        for record in records where !presentFolders.contains(record.folder) {
            guard let successor = presentByTitle[titleKey(record.title)],
                  successor.id != record.id else { continue }
            retirements.append((record, successor))
        }
        return retirements
    }
}

// MARK: - The proceedings map

/// The map's node positions, shared across every device the community
/// folder reaches: lay the venue out on the iPad and the same X and Y
/// stand on the Mac and in the Vision Pro's hallway (which keeps its
/// own Z). Units are the hallway's meters — x right of its center,
/// y up from the floor; the flat map scales them to points. One file,
/// last writer wins, exactly as the standing file resolves. A mirror
/// in Application Support serves when no community folder is chosen,
/// and lets the Vision Pro's map (which loads before any model is in
/// reach) read state refreshed during the shelf scan.
nonisolated enum EPUBMapSharedLayout {

    struct Point: Codable {
        var x: Double
        var y: Double
    }

    struct State: Codable {
        var positions: [String: Point]
        var modified: Date
    }

    private static let fileName = "origami-map-layout.json"

    private static var mirrorURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(
            at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent(fileName)
    }

    /// The freshest state visible from here: the community file or the
    /// local mirror, whichever was written last.
    static func load(community folder: URL?) -> State {
        let mirror = read(at: mirrorURL)
        let shared = folder.flatMap { url in
            withScope(url) { read(at: $0.appendingPathComponent(fileName)) }
        }
        switch (mirror, shared) {
        case let (m?, s?): return s.modified > m.modified ? s : m
        case let (m?, nil): return m
        case let (nil, s?): return s
        default: return State(positions: [:], modified: .distantPast)
        }
    }

    /// Merges the given positions into the freshest state and writes it
    /// to both homes. Only the given ids move; every other entry — the
    /// other venues', the hallway's extras — stands.
    static func save(updating updates: [String: Point], community folder: URL?) {
        var state = load(community: folder)
        for (id, point) in updates { state.positions[id] = point }
        state.modified = .now
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(state) else { return }
        try? data.write(to: mirrorURL, options: .atomic)
        if let folder {
            withScope(folder) {
                try? data.write(to: $0.appendingPathComponent(fileName),
                                options: .atomic)
            }
        }
    }

    /// Pulls a newer community file into the local mirror — called
    /// beside the standing adoption on each shelf scan.
    static func refreshMirror(community folder: URL) {
        guard let shared = withScope(folder, {
                  read(at: $0.appendingPathComponent(fileName)) }),
              shared.modified > (read(at: mirrorURL)?.modified ?? .distantPast),
              let data = try? JSONEncoder().encode(shared) else { return }
        try? data.write(to: mirrorURL, options: .atomic)
    }

    private static func read(at url: URL) -> State? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(State.self, from: data)
    }

    private static func withScope<T>(_ url: URL, _ body: (URL) -> T) -> T {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return body(url)
    }
}

/// The proceedings as a flat map — Author's Map for one venue: every
/// article a card on the plane, dragged where the reader wants it,
/// opened with a double click. Positions persist through EPUBMapSharedLayout in
/// the hallway's meters; Pin and Set Aside ride the standing file as
/// they do everywhere. Closure-driven so the Mac's and the phone's
/// models plug in without this shared file knowing either.
struct ProceedingsMapView: View {

    struct Item: Identifiable {
        let id: String
        let title: String
        let author: String
        var isPinned = false
        var isSetAside = false
    }

    let items: [Item]
    /// The community folder carrying the shared layout; nil reads and
    /// writes the local mirror alone.
    let folder: URL?
    let open: (String) -> Void
    let togglePin: (String) -> Void
    let toggleSetAside: (String) -> Void
    /// Back to the venue's list face. The Map hides the tabs and fills
    /// the room, so it carries its own way home.
    var back: (() -> Void)? = nil

    /// Canvas positions in points, by book id — the shared meters
    /// drawn onto the plane.
    @State private var positions: [String: CGPoint] = [:]

    /// One hallway meter drawn at this many points; the canvas center
    /// is the hallway's (0, 1.2) — mid-height of its article grid.
    private static let pointsPerMeter: CGFloat = 620
    private static let canvasSize = CGSize(width: 2600, height: 1800)

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                canvasBase
                ForEach(items) { item in
                    ProceedingsMapNode(
                        item: item,
                        position: binding(for: item),
                        bounds: Self.canvasSize,
                        open: { open(item.id) },
                        togglePin: { togglePin(item.id) },
                        toggleSetAside: { toggleSetAside(item.id) },
                        moved: persist)
                }
            }
        }
        .defaultScrollAnchor(.center)
        .background(Color.secondary.opacity(0.06))
        .overlay(alignment: .topLeading) {
            if let back {
                Button(action: back) {
                    Label("Articles", systemImage: "chevron.left")
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(.regularMaterial))
                        .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.3)))
                }
                .buttonStyle(.plain)
                .padding(10)
            }
        }
        .onAppear(perform: reload)
    }

    /// The plane itself. On the iPad it carries the two-finger probe:
    /// panning the map takes two fingers, leaving one free for the cards.
    private var canvasBase: some View {
        let base = Color.clear
            .frame(width: Self.canvasSize.width,
                   height: Self.canvasSize.height)
        #if os(iOS)
        return base.background(TwoFingerScrollConfigurator())
        #else
        return base
        #endif
    }

    private func binding(for item: Item) -> Binding<CGPoint> {
        Binding(
            get: { positions[item.id] ?? Self.seeds(for: items)[item.id]
                ?? Self.canvasCenter },
            set: { positions[item.id] = $0 })
    }

    private static var canvasCenter: CGPoint {
        CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
    }

    /// Meters to canvas points: x right stays right, y up flips down.
    private static func canvasPoint(_ point: EPUBMapSharedLayout.Point) -> CGPoint {
        CGPoint(x: canvasCenter.x + point.x * pointsPerMeter,
                y: canvasCenter.y + (1.2 - point.y) * pointsPerMeter)
    }

    private static func sharedPoint(_ point: CGPoint) -> EPUBMapSharedLayout.Point {
        EPUBMapSharedLayout.Point(
            x: Double((point.x - canvasCenter.x) / pointsPerMeter),
            y: Double(1.2 - (point.y - canvasCenter.y) / pointsPerMeter))
    }

    /// The hallway's own seeding — the same wide grid the Vision Pro
    /// lays out, the Set Aside books in their quiet row beneath — so an
    /// untouched venue looks the same here and there. Keep the numbers
    /// in step with EPUBMapView's article grid.
    private static func seeds(for items: [Item]) -> [String: CGPoint] {
        let standing = items.filter { !$0.isSetAside }
        let asides = items.filter { $0.isSetAside }
        let columns = max(1, Int((Double(standing.count) * 7).squareRoot() / 2))
        var result: [String: CGPoint] = [:]
        for (index, item) in standing.enumerated() {
            let column = index % columns
            let row = index / columns
            result[item.id] = canvasPoint(EPUBMapSharedLayout.Point(
                x: (Double(column) - Double(columns - 1) / 2) * 0.28,
                y: 1.55 - Double(row) * 0.18))
        }
        let gridRows = standing.isEmpty ? 0 : (standing.count - 1) / columns + 1
        let asideTop = 1.55 - Double(gridRows) * 0.18 - 0.10
        let asideColumns = max(1, min(asides.count, 5))
        for (index, item) in asides.enumerated() {
            let column = index % asideColumns
            let row = index / asideColumns
            result[item.id] = canvasPoint(EPUBMapSharedLayout.Point(
                x: (Double(column) - Double(asideColumns - 1) / 2) * 0.24,
                y: asideTop - Double(row) * 0.08))
        }
        return result
    }

    private func reload() {
        let shared = EPUBMapSharedLayout.load(community: folder).positions
        let seeds = Self.seeds(for: items)
        var next: [String: CGPoint] = [:]
        for item in items {
            next[item.id] = shared[item.id].map { Self.canvasPoint($0) }
                ?? seeds[item.id] ?? Self.canvasCenter
        }
        positions = next
    }

    /// Every card's place, written on drag end — the merge keeps other
    /// venues' entries untouched.
    private func persist() {
        var updates: [String: EPUBMapSharedLayout.Point] = [:]
        for item in items {
            if let position = positions[item.id] {
                updates[item.id] = Self.sharedPoint(position)
            }
        }
        EPUBMapSharedLayout.save(updating: updates, community: folder)
    }
}

#if os(iOS)
/// Raises the enclosing scroll view's pan gesture to two touches — the
/// Map's convention on the iPad: two fingers move the plane, one finger
/// moves a card. Sits invisibly in the scroll content and walks up to
/// the UIScrollView once it joins the window.
private struct TwoFingerScrollConfigurator: UIViewRepresentable {
    private final class Probe: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            var parent = superview
            while let current = parent {
                if let scroll = current as? UIScrollView {
                    scroll.panGestureRecognizer.minimumNumberOfTouches = 2
                    break
                }
                parent = current.superview
            }
        }
    }

    func makeUIView(context: Context) -> UIView {
        let view = Probe()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
#endif

/// One article on the map: a card that drags, opens on a double
/// click or tap, and carries the pile choices in its context menu.
private struct ProceedingsMapNode: View {
    let item: ProceedingsMapView.Item
    @Binding var position: CGPoint
    let bounds: CGSize
    let open: () -> Void
    let togglePin: () -> Void
    let toggleSetAside: () -> Void
    let moved: () -> Void

    @State private var dragStart: CGPoint?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.title)
                .font(.callout.weight(.semibold))
                .lineLimit(3)
            Text(item.author)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(10)
        .frame(width: 168, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.regularMaterial))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(item.isPinned
                    ? Color.accentColor.opacity(0.7)
                    : Color.secondary.opacity(0.3)))
        .overlay(alignment: .topTrailing) {
            if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor)
                    .padding(5)
            }
        }
        .opacity(item.isSetAside ? 0.45 : 1)
        .position(position)
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    if dragStart == nil { dragStart = position }
                    guard let start = dragStart else { return }
                    position = CGPoint(
                        x: min(max(start.x + value.translation.width, 90),
                               bounds.width - 90),
                        y: min(max(start.y + value.translation.height, 40),
                               bounds.height - 40))
                }
                .onEnded { _ in
                    dragStart = nil
                    moved()
                })
        .onTapGesture(count: 2, perform: open)
        .contextMenu {
            Button(item.isPinned ? "Unpin" : "Pin", action: togglePin)
            Button(item.isSetAside ? "Bring Back" : "Set Aside",
                   action: toggleSetAside)
        }
    }
}
