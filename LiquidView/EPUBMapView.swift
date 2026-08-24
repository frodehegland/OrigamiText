// The Map view: Author's NodeImmersiveView engine with EPUBs as the
// nodes. Phase 2 of the port: ONE hard-coded card, rendered through
// Author's exact pipeline (SwiftUI face → rasterized textured plane →
// ModelEntity.box), with Author's ArmMenu carrying Settings and
// Documents. Nothing advances past this file's card until it has stood
// in the room on the device.
#if os(visionOS)
import SwiftUI
import RealityKit

/// One node on the Map: a journal's article, a work it cites (standing
/// a level behind). Position mutates as the engine
/// moves the node, and selection gates the citation lines; visual
/// equality ignores both, so neither a drag nor a selection triggers
/// the rasterize-and-rebuild path.
struct EPUBMapItem: ItemProtocol {
    enum Kind { case article, cited }

    let id: String
    var title: String
    var author: String
    var kind: Kind = .article
    var position: SIMD3<Float>?
    /// The ids of the works this article cites — cited cards behind it,
    /// or fellow articles when the citation resolves inside the journal.
    var citedIDs: [String] = []
    /// Selected articles draw their citation lines.
    var isSelected = false
    /// Pinned articles stand first and wear the pin on their face.
    var isPinned = false
    /// Set Aside articles collapse to a half-faded title in the quiet
    /// row beneath the others.
    var isAside = false

    var isAttachmentsEnabled: Bool { false }

    func isVisuallyEqual(to other: EPUBMapItem) -> Bool {
        id == other.id && title == other.title && author == other.author
            && kind == other.kind && isPinned == other.isPinned
            && isAside == other.isAside
    }
}

/// The Map space: Author's engine, Origami's items.
struct EPUBMapView: View {
    @Environment(VisionModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    /// The Map's nodes: the open journal's records, seeded on a grid,
    /// with the works they cite a level behind. Empty until a journal
    /// is opened from the panel.
    @State private var items: [EPUBMapItem] = []

    /// Where the reader has placed each card — kept across reloads, so
    /// a card returning from its reader window (or a returning journal)
    /// stands where it was left.
    @State private var placed: [String: SIMD3<Float>] = [:]

    /// How the cited papers occupy their space. Each axis is a mapping,
    /// built to become user-configurable (the controls are coming): XY
    /// is the virtual rectangle for now, and Z carries meaning — by
    /// default the date, the newest citations standing nearest.
    struct CitedSpace {
        enum ZMapping { case flat, date }

        /// Top-centre of the wall, at its NEAREST plane.
        var origin = SIMD3<Float>(0.0, 1.95, -1.6)
        var columnSpacing: Float = 0.24
        var rowSpacing: Float = 0.14
        /// How far behind the newest the oldest citation stands.
        var depth: Float = 1.0
        var zMapping: ZMapping = .date

        /// The z for a work, given where its date falls in the span —
        /// 0 is the newest (nearest), 1 the oldest (deepest). Works
        /// without a date stand at the far plane.
        func z(agePlace: Float?) -> Float {
            switch zMapping {
            case .flat:
                return origin.z
            case .date:
                return origin.z - (agePlace ?? 1.0) * depth
            }
        }
    }

    /// The cited wall's configuration — a constant until the XY and Z
    /// controls arrive.
    @State private var citedSpace = CitedSpace()

    /// The open journal's records as nodes — arranged positions where
    /// the reader has made them, the grid for the rest — and, a level
    /// behind them, every work the articles cite. A citation that
    /// resolves to a fellow article in the journal connects to that
    /// card instead of raising a ghost. Articles open in a reader
    /// window stay off the Map until their window closes.
    private func journalItems(venue: String) -> [EPUBMapItem] {
        let records = model.records(inVenue: venue)
        let inJournal = Set(records.map(\.id))

        // The cited works, deduplicated across the whole journal, each
        // with its year — the Z axis reads it.
        struct CitedWork {
            let id: String
            let title: String
            let author: String
            let year: Int?
        }
        var citedWorks: [CitedWork] = []
        var citedIDByKey: [String: String] = [:]
        var citedIDsByArticle: [String: [String]] = [:]
        for record in records {
            guard let doc = model.index.byID[record.id]?.doc else { continue }
            var cited: [String] = []
            for reference in doc.references {
                let fields = BibTeXParser.first(reference.bibtex)?.fields ?? [:]
                // A citation naming a fellow article by address connects
                // to the real card.
                if let address = fields["vm-id"] ?? fields["origami-id"] {
                    let target = String(address.split(separator: "#").first ?? "")
                    if inJournal.contains(target), target != record.id {
                        cited.append(target)
                        continue
                    }
                }
                let title = fields["title"] ?? reference.citedAs ?? ""
                guard !title.isEmpty else { continue }
                let author = fields["author"] ?? ""
                let year = fields["year"].flatMap {
                    Int($0.filter(\.isNumber).prefix(4))
                }
                let key = (title + "|" + author).lowercased()
                    .replacingOccurrences(of: " ", with: "")
                let citedID: String
                if let known = citedIDByKey[key] {
                    citedID = known
                } else {
                    citedID = "cited:" + key
                    citedIDByKey[key] = citedID
                    citedWorks.append(CitedWork(id: citedID, title: title,
                                                author: author, year: year))
                }
                cited.append(citedID)
            }
            citedIDsByArticle[record.id] = cited
        }
        // Newest first — the rectangle reads chronologically, and the
        // depth mapping walks the same order.
        citedWorks.sort {
            ($0.year ?? Int.min, $0.title) > ($1.year ?? Int.min, $1.title)
        }

        // The journal's articles, front and centre: pinned first, then
        // the rest; the Set Aside collapse into a quiet row beneath.
        let shown = records.filter { !model.openDocIDs.contains($0.id) }
        let standing = model.pinnedFirstRecords(shown.filter { !model.setAsideIDs.contains($0.id) })
        let asides = shown.filter { model.setAsideIDs.contains($0.id) }

        let columns = max(1, Int(Double(standing.count * 7).squareRoot() / 2))
        var result: [EPUBMapItem] = standing.enumerated().map { index, record in
            let column = index % columns
            let row = index / columns
            let seed = SIMD3<Float>(
                (Float(column) - Float(columns - 1) / 2) * 0.28,
                1.55 - Float(row) * 0.18,
                -1.2)
            return EPUBMapItem(
                id: record.id,
                title: record.title,
                author: record.author,
                kind: .article,
                position: placed[record.id] ?? seed,
                citedIDs: citedIDsByArticle[record.id] ?? [],
                isPinned: model.pinnedIDs.contains(record.id))
        }

        // The Set Aside row: title-only slips, half faded, in their own
        // row under the grid — the Mac's journal list, spatialized. A
        // set-aside card always sits in the row (its wandering position
        // is kept for its return).
        let gridRows = standing.isEmpty ? 0 : (standing.count - 1) / columns + 1
        let asideTop = 1.55 - Float(gridRows) * 0.18 - 0.10
        let asideColumns = max(1, min(asides.count, 5))
        result.append(contentsOf: asides.enumerated().map { index, record in
            let column = index % asideColumns
            let row = index / asideColumns
            return EPUBMapItem(
                id: record.id,
                title: record.title,
                author: record.author,
                kind: .article,
                position: SIMD3<Float>(
                    (Float(column) - Float(asideColumns - 1) / 2) * 0.24,
                    asideTop - Float(row) * 0.08,
                    -1.2),
                citedIDs: citedIDsByArticle[record.id] ?? [],
                isAside: true)
        })

        // The cited works, a level behind — the rectangle carries the
        // grid, and Z carries the date: newest nearest, the oldest
        // deepest into the room, dateless works at the far plane.
        let years = citedWorks.compactMap(\.year)
        let newest = years.max()
        let oldest = years.min()
        let span = Float(max((newest ?? 0) - (oldest ?? 0), 1))
        let citedColumns = max(1, Int(Double(citedWorks.count * 7).squareRoot() / 2))
        result.append(contentsOf: citedWorks.enumerated().map { index, work in
            let column = index % citedColumns
            let row = index / citedColumns
            // 0 = the newest (nearest), 1 = the oldest (deepest).
            let agePlace: Float? = work.year.flatMap { year in
                newest.map { Float($0 - year) / span }
            }
            let seed = SIMD3<Float>(
                citedSpace.origin.x
                    + (Float(column) - Float(citedColumns - 1) / 2) * citedSpace.columnSpacing,
                citedSpace.origin.y - Float(row) * citedSpace.rowSpacing,
                citedSpace.z(agePlace: agePlace))
            return EPUBMapItem(
                id: work.id,
                title: work.title,
                // The year on the face, so the depth reads at a glance.
                author: work.year.map { "\(work.author) · \($0)" } ?? work.author,
                kind: .cited,
                position: placed[work.id] ?? seed)
        })
        return result
    }

    /// The connection pool: every citation edge the Map could draw.
    private var connectionEdgeCount: Int {
        items.reduce(0) { $0 + $1.citedIDs.count }
    }

    private func reload() {
        let selected = Set(items.filter(\.isSelected).map(\.id))
        if let venue = model.openJournalVenue {
            var built = journalItems(venue: venue)
            for index in built.indices where selected.contains(built[index].id) {
                built[index].isSelected = true
            }
            items = built
        } else {
            items = []
        }
    }

    /// The arm menu, Author's component: Settings and Documents ride
    /// the right forearm, exactly as in Author's Map; Pin and Set Aside
    /// ride the left, acting on the selected card.
    @State private var armMenu = ArmMenu(chips: [
        ArmMenu.Chip(id: EPUBMapView.settingsChipID, title: "Settings", side: .right),
        ArmMenu.Chip(id: EPUBMapView.documentsChipID, title: "Documents", side: .right),
        ArmMenu.Chip(id: EPUBMapView.pinChipID, title: "Pin", side: .left),
        ArmMenu.Chip(id: EPUBMapView.asideChipID, title: "Set Aside", side: .left),
    ])

    private static let settingsChipID = "map.arm.settings"
    private static let documentsChipID = "map.arm.documents"
    private static let pinChipID = "map.arm.pin"
    private static let asideChipID = "map.arm.aside"

    var body: some View {
        engine
            // SwiftUI modifiers close the chain — the engine's fluent
            // modifiers inside `engine` return the engine view and must
            // run first.
            .onChange(of: model.openJournalVenue) {
                reload()
            }
            .onChange(of: model.openDocIDs) {
                reload()
            }
            // The pile can change from the Mac (the standing file in
            // the community folder) as well as the arm chips.
            .onChange(of: model.pinnedIDs) {
                reload()
            }
            .onChange(of: model.setAsideIDs) {
                reload()
            }
            .onAppear {
                reload()
            }
    }

    private typealias Engine = NodeImmersiveView<[EPUBMapItem], AnyView, AnyView>

    /// The engine and its behavior, one statement per modifier — a long
    /// inline chain of generic closures stalls the type-checker.
    private var engine: some View {
        var view = Engine(
            items,
            connectionEdgeCount,
            constructorView: { item in
                AnyView(cardFace(for: item))
            },
            constructorAttachment: { _, _ in
                AnyView(EmptyView())
            },
            constructorNodeModelEntity: { item, texturedPlane in
                cardEntity(for: item, texturedPlane: texturedPlane)
            }
        )
        view = view.nodeMaxWidth { item in
            if item.isAside { return 170.0 }
            return item.kind == .cited ? 150.0 : 200.0
        }
        view = view.onEndMoveNode { _, _, newItems in
            keepPlacements(of: Array(newItems))
        }
        view = view.constructorConnectionModelEntity {
            // The citation lines — the lab's ember, Author's connection
            // entity.
            ModelEntity.connection(
                size: 0.0022,
                color: Color(red: 0.72, green: 0.42, blue: 0.06).opacity(0.85),
                connectionOptions: .none,
                materialMode: .none)
        }
        view = view.shouldDrawConnectionForNode { item in
            item.isSelected
        }
        view = view.connectedNodesToNode { item in
            if item.kind == .cited {
                // A selected citation shows who cites it: the lines run
                // back to every article naming it.
                return items.filter { $0.citedIDs.contains(item.id) }
            }
            return items.filter { item.citedIDs.contains($0.id) }
        }
        view = view.onTapNode { tapCount, item in
            handleTap(count: tapCount, on: item)
        }
        view = view.defaultMaxWidth(200.0)
        view = view.defaultNodePosition([0.0, 1.4, -1.2])
        view = view.onSetupContent { content in
            armMenu.install(in: content)
        }
        view = view.onTapEntity { entity in
            handleArmTap(on: entity)
        }
        return view
    }

    /// The card's face — rasterized by the engine onto the node plane;
    /// the box beneath provides the paper. Cited works read a step
    /// quieter than the journal's own; a Set Aside card collapses to
    /// its title alone; a pinned card wears the pin.
    @ViewBuilder private func cardFace(for item: EPUBMapItem) -> some View {
        if item.isAside {
            // The whole slip fades — the words too, not just the paper.
            Text(item.title)
                .font(AppFonts.body(11, weight: .semibold))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .opacity(0.5)
        } else {
            VStack(spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if item.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Color(red: 0.72, green: 0.42, blue: 0.06))
                    }
                    Text(item.title)
                        .font(AppFonts.body(item.kind == .cited ? 12 : 15, weight: .semibold))
                        .lineLimit(3)
                }
                Text(item.author)
                    .font(.system(size: item.kind == .cited ? 9 : 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .multilineTextAlignment(.center)
            .padding(item.kind == .cited ? 8 : 10)
        }
    }

    private func cardEntity(for item: EPUBMapItem, texturedPlane: ModelEntity)
        -> (modelEntity: ModelEntity?, collisionShape: ShapeResource) {
        // Set Aside slips stand at half presence — paper and words both.
        let opacity: Float = item.isAside ? 0.4
            : (item.kind == .cited ? 0.92 : 1.0)
        return ModelEntity.box(
            with: texturedPlane,
            backPlane: nil,
            color: item.kind == .cited ? UIColor(white: 0.82, alpha: 1) : .white,
            depth: 0.01,
            margins: item.isAside ? 0.004 : 0.006,
            opacity: opacity,
            cornerRadius: 0.01,
            useBorder: false,
            borderColor: .clear,
            materialMode: .none
        )
    }

    /// Keep the moved positions in the items (so the engine's equality
    /// checks see them where they stand) and in the placement memory
    /// (so they survive reloads).
    private func keepPlacements(of moved: [EPUBMapItem]) {
        for item in moved {
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                items[index].position = item.position
            }
            if let position = item.position {
                placed[item.id] = position
            }
        }
    }

    private func handleTap(count: Int, on item: EPUBMapItem) {
        switch count {
        case 1:
            // Selecting draws the citation lines — an article's run to
            // everything it cites; a cited work's run back to every
            // article citing it. One selection at a time; tapping again
            // puts the lines away.
            let wasSelected = item.isSelected
            for index in items.indices {
                items[index].isSelected = !wasSelected && items[index].id == item.id
            }
        case 2:
            // The card steps off the Map while its article is read; the
            // reader window's close brings it back. Cited works have no
            // local book to open.
            guard item.kind == .article else { return }
            model.openDocIDs.insert(item.id)
            openWindow(id: "reader", value: item.id)
        default:
            break
        }
    }

    private func handleArmTap(on entity: Entity) -> Bool {
        switch armMenu.chipID(for: entity) {
        case Self.settingsChipID:
            openWindow(id: "settings")
            return true
        case Self.documentsChipID:
            openWindow(id: "library")
            return true
        case Self.pinChipID:
            // Pin the selected card first in the grid (or unpin it).
            // Its wandering position clears so the new order shows.
            if let selected = items.first(where: { $0.isSelected && $0.kind == .article }) {
                model.togglePinned(selected.id)
                placed[selected.id] = nil
                reload()
            }
            return true
        case Self.asideChipID:
            // Collapse the selected card into the Set Aside row — or
            // bring it back to the grid.
            if let selected = items.first(where: { $0.isSelected && $0.kind == .article }) {
                model.toggleSetAside(selected.id)
                placed[selected.id] = nil
                reload()
            }
            return true
        default:
            return false
        }
    }
}
#endif
