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
/// a level behind), or the probe card. Position mutates as the engine
/// moves the node, and selection gates the citation lines; visual
/// equality ignores both, so neither a drag nor a selection triggers
/// the rasterize-and-rebuild path.
struct EPUBMapItem: ItemProtocol {
    enum Kind { case article, cited, probe }

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

    var isAttachmentsEnabled: Bool { false }

    func isVisuallyEqual(to other: EPUBMapItem) -> Bool {
        id == other.id && title == other.title && author == other.author
            && kind == other.kind
    }
}

/// The Map space: Author's engine, Origami's items.
struct EPUBMapView: View {
    @Environment(VisionModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    /// The Map's nodes: the open journal's records, seeded on a grid —
    /// or, while no journal is open, the probe card (proof of life,
    /// phase 2's gate).
    @State private var items: [EPUBMapItem] = EPUBMapView.probeItems

    private static let probeItems = [
        EPUBMapItem(id: "probe",
                    title: "Author's Map engine, in Origami Text",
                    author: "Open a journal from the panel — its articles land here",
                    position: SIMD3<Float>(0.0, 1.4, -1.2)),
    ]

    /// Where the reader has placed each card — kept across reloads, so
    /// a card returning from its reader window (or a returning journal)
    /// stands where it was left.
    @State private var placed: [String: SIMD3<Float>] = [:]

    /// The open journal's records as nodes — arranged positions where
    /// the reader has made them, the grid for the rest — and, a level
    /// behind them, every work the articles cite. A citation that
    /// resolves to a fellow article in the journal connects to that
    /// card instead of raising a ghost. Articles open in a reader
    /// window stay off the Map until their window closes.
    private func journalItems(venue: String) -> [EPUBMapItem] {
        let records = model.records(inVenue: venue)
        let inJournal = Set(records.map(\.id))

        // The cited works, deduplicated across the whole journal.
        struct CitedWork {
            let id: String
            let title: String
            let author: String
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
                let key = (title + "|" + author).lowercased()
                    .replacingOccurrences(of: " ", with: "")
                let citedID: String
                if let known = citedIDByKey[key] {
                    citedID = known
                } else {
                    citedID = "cited:" + key
                    citedIDByKey[key] = citedID
                    citedWorks.append(CitedWork(id: citedID, title: title, author: author))
                }
                cited.append(citedID)
            }
            citedIDsByArticle[record.id] = cited
        }

        // The journal's articles, front and centre.
        let columns = max(1, Int(Double(records.count * 7).squareRoot() / 2))
        var result: [EPUBMapItem] = records.enumerated().compactMap { index, record in
            guard !model.openDocIDs.contains(record.id) else { return nil }
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
                citedIDs: citedIDsByArticle[record.id] ?? [])
        }

        // The cited works, a level behind — deeper into the room, a
        // wider and taller wall for the bigger population.
        let citedColumns = max(1, Int(Double(citedWorks.count * 7).squareRoot() / 2))
        result.append(contentsOf: citedWorks.enumerated().map { index, work in
            let column = index % citedColumns
            let row = index / citedColumns
            let seed = SIMD3<Float>(
                (Float(column) - Float(citedColumns - 1) / 2) * 0.24,
                1.95 - Float(row) * 0.14,
                -1.9)
            return EPUBMapItem(
                id: work.id,
                title: work.title,
                author: work.author,
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
            items = Self.probeItems
        }
    }

    /// The arm menu, Author's component: Settings and Documents ride
    /// the right forearm, exactly as in Author's Map.
    @State private var armMenu = ArmMenu(chips: [
        ArmMenu.Chip(id: EPUBMapView.settingsChipID, title: "Settings", side: .right),
        ArmMenu.Chip(id: EPUBMapView.documentsChipID, title: "Documents", side: .right),
    ])

    private static let settingsChipID = "map.arm.settings"
    private static let documentsChipID = "map.arm.documents"

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
            item.kind == .cited ? 150.0 : 200.0
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
            items.filter { item.citedIDs.contains($0.id) }
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
    /// quieter than the journal's own.
    private func cardFace(for item: EPUBMapItem) -> some View {
        VStack(spacing: 5) {
            Text(item.title)
                .font(AppFonts.body(item.kind == .cited ? 12 : 15, weight: .semibold))
                .lineLimit(3)
            Text(item.author)
                .font(.system(size: item.kind == .cited ? 9 : 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .multilineTextAlignment(.center)
        .padding(item.kind == .cited ? 8 : 10)
    }

    private func cardEntity(for item: EPUBMapItem, texturedPlane: ModelEntity)
        -> (modelEntity: ModelEntity?, collisionShape: ShapeResource) {
        ModelEntity.box(
            with: texturedPlane,
            backPlane: nil,
            color: item.kind == .cited ? UIColor(white: 0.82, alpha: 1) : .white,
            depth: 0.01,
            margins: 0.006,
            opacity: item.kind == .cited ? 0.92 : 1.0,
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
        guard item.kind == .article else { return }
        switch count {
        case 1:
            // Selecting an article draws its citation lines — to the
            // cited wall behind, and to fellow articles it cites. One
            // at a time; tapping again puts the lines away.
            let wasSelected = item.isSelected
            for index in items.indices {
                items[index].isSelected = !wasSelected && items[index].id == item.id
            }
        case 2:
            // The card steps off the Map while its article is read; the
            // reader window's close brings it back.
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
        default:
            return false
        }
    }
}
#endif
