// THE HALLWAY VIEW — the visionOS timeline corridor, named 2026-08-25.
// Author's NodeImmersiveView engine with EPUBs as the nodes: articles
// front and centre, citations welded to their publication years' Z on
// a walkable time axis, Timeflow data diagrams flanking the corridor
// on the same axis, themed history written on the physical floor,
// readings and citation records opening in-situ, and the arms carrying
// the commands. (See ORIGAMI-TEXT-OVERVIEW.md ▸ The Hallway View.)
#if os(visionOS)
import SwiftUI
import RealityKit

/// One node on the Map: a journal's article, a work it cites (standing
/// a level behind). Position mutates as the engine
/// moves the node, and selection gates the citation lines; visual
/// equality ignores both, so neither a drag nor a selection triggers
/// the rasterize-and-rebuild path.
struct EPUBMapItem: ItemProtocol {
    /// article: the journal's own EPUB. cited: a work an article cites,
    /// on the wall behind. citedDeep: the second rank — a work a
    /// selected citation itself cites, raised from the citation graph
    /// while the citation is selected and retired when it is not.
    enum Kind { case article, cited, citedDeep }

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
    /// A cited work every raised article cites (two or more raised):
    /// the common ground, and it reads green.
    var isShared = false
    /// Pinned articles stand first and wear the pin on their face.
    var isPinned = false
    /// Set Aside articles collapse to a half-faded title in the quiet
    /// row beneath the others.
    var isAside = false

    var isAttachmentsEnabled: Bool { false }

    func isVisuallyEqual(to other: EPUBMapItem) -> Bool {
        // Selection is visual now — the selected card wears an ember
        // border — so a tap rebuilds the one card it touches (and the
        // one it left), never the room.
        id == other.id && title == other.title && author == other.author
            && kind == other.kind && isPinned == other.isPinned
            && isAside == other.isAside && isSelected == other.isSelected
            && isShared == other.isShared
    }
}

/// The Map space: Author's engine, Origami's items.
struct EPUBMapView: View {
    @Environment(VisionModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    /// The Map's nodes: the open journal's records, seeded on a grid.
    /// The room is quiet by default — citations rise only for the
    /// raised article. Empty until a journal is opened from the panel.
    @State private var items: [EPUBMapItem] = []

    /// The articles whose citations stand on the wall — selection is
    /// additive and sticky, so several articles can hold their walls
    /// up at once. Deselecting an article retires its share.
    @State private var raisedArticleIDs: Set<String> = []

    /// The citations whose second ranks are raised — each rank's
    /// owner, kept while the selection walks into the ranks.
    @State private var deepParentIDs: Set<String> = []

    /// Per selected second-rank card: the visible cards whose works
    /// cite it, and the visible cards it cites — read from the
    /// citation graph at selection time.
    struct DeepLinks {
        var inbound: Set<String>
        var outbound: Set<String>
    }
    @State private var deepLinks: [String: DeepLinks] = [:]

    /// The Concepts ladder off the left forearm — Interatlas's levels,
    /// carrying the reader's macOS concepts.
    @State private var conceptLadder = ConceptLadder()

    /// Where the fist has carried the whole space — applied to every
    /// seed so newly raised cards land in the moved space.
    @State private var spaceShift = SIMD3<Float>.zero

    /// The fist: close either hand to grab the whole space and carry
    /// it; open the hand to set it down.
    @State private var fistGrab = FistGrab()

    /// The Timeflows standing along the corridor's own Z axis — every
    /// year's data point at the same depth as that year's citations.
    /// One to the walker's left, one to the right of the nodes, each
    /// answering its own arm chip.
    @State private var sankeyWallLeft = SankeyWall(sideOffset: -1.15)
    @State private var sankeyWallRight = SankeyWall(sideOffset: 1.15)

    /// Which Timeflows stand — toggled by the arm chips, remembered.
    @AppStorage("timeflowLeftShown") private var timeflowLeftShown = true
    @AppStorage("timeflowRightShown") private var timeflowRightShown = false
    /// The snap-to-wall option, per graph — set in each side's Time
    /// Data dialog.
    @AppStorage("graphSnapWallLeft") private var graphSnapWallLeft = false
    @AppStorage("graphSnapWallRight") private var graphSnapWallRight = false

    /// The physical floor put to work: what lies written along it —
    /// world history by default, or nothing. Chosen in Time Data.
    @AppStorage("floorShow") private var floorShowRaw = FloorShow.world.rawValue

    /// The theme the floor returns to when its arm chip toggles it
    /// back on.
    @AppStorage("floorShowLast") private var floorShowLastRaw = FloorShow.world.rawValue

    /// The floor's writing, laid flat on the real ground under the
    /// corridor, each event at its year's exact depth.
    @State private var floorBand = FloorBand()

    /// Readers opened in-situ: the full reading standing where its
    /// card stood, dragged anywhere by its handle bar — free of the
    /// timeline; an open book is in the hand, not on the shelf.
    @State private var readerPanels = ReaderPanels()


    /// Sankey widths or a traditional line graph — the reader's
    /// choice, offered in the Time Data window.
    @AppStorage("timeSpreadStyle") private var timeSpreadStyleRaw =
        TimeSpreadStyle.sankey.rawValue

    /// Lanes apart, or every data set overlaid in one field.
    @AppStorage("timeSpreadLayout") private var timeSpreadLayoutRaw =
        TimeSpreadLayout.lanes.rawValue

    /// The raised wall's year span, kept when the wall builds — the
    /// Sankey shares it, so the diagram and the citations agree on
    /// where every year stands.
    @State private var citedYearRange: (newest: Int, oldest: Int)?

    /// Each citation's timeline depth — the Z its year earns. A drag
    /// slides a citation in X and Y, but its Z settles back here, so
    /// the corridor stays a truthful timeline.
    @State private var citedTimelineZ: [String: Float] = [:]

    /// What the references told us about each citation beyond its face
    /// — the abstract and the DOI, for the double-tap card and its
    /// Acquire button.
    struct CitedFacts {
        var abstract: String?
        var doi: String?
    }
    @State private var citedFacts: [String: CitedFacts] = [:]

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
        /// How far behind the newest the oldest citation stands. Pinch
        /// out on the Map to stretch it, pinch in to gather it back.
        var depth: Float = 1.0
        var zMapping: ZMapping = .date

        /// What the pinch steps through: one pinch, one step of the
        /// factor, held inside walking range. A pinch out stretches to
        /// twice the depth the step used to give, and the corridor runs
        /// twice as deep.
        static let depthRange: ClosedRange<Float> = 0.4...12.0
        static let depthStep: Float = 2.8
        /// At this depth (the default) the wall stands at full height;
        /// past it the rows squeeze toward walking height.
        static let referenceDepth: Float = 1.0
        /// Where the squeezed rows gather — the band the reader walks
        /// through when the spread becomes a corridor.
        static let walkHeight: Float = 1.5

        /// How much of the wall's height survives at this depth: all
        /// of it while the wall is near, squeezing as the spread
        /// stretches — the bottom rows lift, the top rows lower, and Z
        /// keeps them apart where Y no longer does.
        var heightSqueeze: Float {
            max(0.22, min(1.0, Self.referenceDepth / depth))
        }

        /// The y for a row: the full wall when near, gathered toward
        /// walking height as the spread deepens into the room.
        func y(row: Int, rowCount: Int) -> Float {
            let mid = Float(max(rowCount, 1) - 1) / 2
            let fullCenter = origin.y - mid * rowSpacing
            let squeeze = heightSqueeze
            let center = fullCenter + (Self.walkHeight - fullCenter) * (1 - squeeze)
            return center + (mid - Float(row)) * rowSpacing * squeeze
        }

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

    /// The cited wall's configuration. The Z distance is the reader's:
    /// pinch out on the Map to stretch the time-spread deeper into the
    /// room, pinch in to gather it back to a wall.
    @State private var citedSpace = CitedSpace()

    /// The chosen depth, kept across sessions.
    @AppStorage("citedSpaceDepth") private var citedDepthSetting = 1.0

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
        var facts: [String: CitedFacts] = [:]
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
                    // What the double-tap card shows beyond the face.
                    facts[citedID] = CitedFacts(
                        abstract: fields["abstract"],
                        doi: fields["doi"]?.lowercased())
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
                -1.2) + spaceShift
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
                    -1.2) + spaceShift,
                citedIDs: citedIDsByArticle[record.id] ?? [],
                isAside: true)
        })

        // The cited works rise only for the raised article — no
        // citations stand by default. The rectangle carries the grid,
        // and Z carries the date: newest nearest, the oldest deepest
        // into the room, dateless works at the far plane.
        let raisedIDs = Set(raisedArticleIDs.flatMap { citedIDsByArticle[$0] ?? [] })
        // The common ground: with two or more articles raised, the
        // works EVERY one of them cites read green on the wall.
        let raisedSets = raisedArticleIDs.map { Set(citedIDsByArticle[$0] ?? []) }
        let sharedIDs: Set<String> = raisedSets.count >= 2
            ? raisedSets.dropFirst().reduce(raisedSets[0]) { $0.intersection($1) }
            : []
        let shownCited = citedWorks.filter { raisedIDs.contains($0.id) }
        let years = shownCited.compactMap(\.year)
        let newest = years.max()
        let oldest = years.min()
        let span = Float(max((newest ?? 0) - (oldest ?? 0), 1))
        // The Sankey shares this span: its years stand at these Zs.
        citedYearRange = (newest != nil && oldest != nil && newest! > oldest!)
            ? (newest!, oldest!) : nil
        let citedColumns = max(1, Int(Double(shownCited.count * 7).squareRoot() / 2))
        let citedRows = shownCited.isEmpty ? 0 : (shownCited.count - 1) / citedColumns + 1
        var timelineZ: [String: Float] = [:]
        result.append(contentsOf: shownCited.enumerated().map { index, work in
            let column = index % citedColumns
            let row = index / citedColumns
            // 0 = the newest (nearest), 1 = the oldest (deepest).
            let agePlace: Float? = work.year.flatMap { year in
                newest.map { Float($0 - year) / span }
            }
            let seed = SIMD3<Float>(
                citedSpace.origin.x
                    + (Float(column) - Float(citedColumns - 1) / 2) * citedSpace.columnSpacing,
                citedSpace.y(row: row, rowCount: citedRows),
                citedSpace.z(agePlace: agePlace)) + spaceShift
            timelineZ[work.id] = seed.z
            return EPUBMapItem(
                id: work.id,
                title: work.title,
                // The year on the face, so the depth reads at a glance.
                author: work.year.map { "\(work.author) · \($0)" } ?? work.author,
                kind: .cited,
                position: placed[work.id] ?? seed,
                isShared: sharedIDs.contains(work.id))
        })
        citedTimelineZ = timelineZ
        citedFacts = facts
        return result
    }

    /// The connection pool: every citation edge the Map could draw —
    /// the citedIDs plus the graph-read links of selected deep cards.
    private var connectionEdgeCount: Int {
        items.reduce(0) { $0 + $1.citedIDs.count }
            + deepLinks.values.reduce(0) { $0 + $1.inbound.count + $1.outbound.count }
    }

    private func reload() {
        let selected = Set(items.filter(\.isSelected).map(\.id))
        if let venue = model.openJournalVenue {
            var built = journalItems(venue: venue)
            for index in built.indices where selected.contains(built[index].id) {
                built[index].isSelected = true
            }
            items = built
            // A changed journal leaves stale raises behind — keep only
            // the articles actually standing.
            let standing = Set(items.filter { $0.kind == .article }.map(\.id))
            raisedArticleIDs.formIntersection(standing)
        } else {
            items = []
            raisedArticleIDs = []
            deepParentIDs = []
            citedYearRange = nil
        }
        rebuildDeepRank()
        updateSankey()
    }

    /// The Timeflows follow the corridor: rebuilt whenever the raised
    /// walls' year span, the pinch depth, the carried space, the data,
    /// or the chips change. With no wall raised they stand on the
    /// data's own year span — never hidden by a mere deselection; only
    /// their chips put them away.
    private func updateSankey() {
        // The Reading Desk empties the room: no Timeflows, no floor.
        let desk = model.readingDeskDocID != nil
        let style = TimeSpreadStyle(rawValue: timeSpreadStyleRaw) ?? .sankey
        let layout = TimeSpreadLayout(rawValue: timeSpreadLayoutRaw) ?? .lanes
        let span = citedYearRange ?? dataYearSpan()
        sankeyWallLeft.update(dataset: (timeflowLeftShown && !desk) ? model.sankey : nil,
                              years: span,
                              citedSpace: citedSpace,
                              shift: spaceShift,
                              style: style,
                              layout: layout,
                              snapToWall: graphSnapWallLeft)
        sankeyWallRight.update(dataset: (timeflowRightShown && !desk) ? model.sankey : nil,
                               years: span,
                               citedSpace: citedSpace,
                               shift: spaceShift,
                               style: style,
                               layout: layout,
                               snapToWall: graphSnapWallRight)
        let floorShow = FloorShow(rawValue: floorShowRaw) ?? .world
        let floorHistory = floorShow.theme.flatMap { model.floorHistory(for: $0) }
        floorBand.update(history: desk ? nil : floorHistory,
                         years: span ?? historyYearSpan(of: floorHistory),
                         citedSpace: citedSpace,
                         shift: spaceShift)
        if let theme = floorShow.theme, !desk {
            model.ensureFloorTheme(theme)
        }
    }

    /// The data's own year span — the Timeflow's frame while no
    /// citation wall lends it one.
    private func dataYearSpan() -> (newest: Int, oldest: Int)? {
        let years = (model.sankey?.series ?? []).flatMap { $0.values.map(\.year) }
        guard let newest = years.max(), let oldest = years.min(),
              newest > oldest else { return nil }
        return (newest, oldest)
    }

    /// The history's own span — the floor's last resort for a frame.
    private func historyYearSpan(of history: SankeySpace.FloorHistory?)
        -> (newest: Int, oldest: Int)? {
        let years = (history?.events ?? []).map(\.year)
        guard let newest = years.max(), let oldest = years.min(),
              newest > oldest else { return nil }
        return (newest, oldest)
    }

    /// The second rank: the works a selected citation itself cites,
    /// from the graph the Mac researched. Raised behind the selected
    /// card — spread in X and Y, but each at its own publication
    /// year's Z on the corridor timeline — and retired when the
    /// citation is deselected. A reference already standing on the
    /// cited wall gets a line to its real card instead of a ghost.
    private static let deepRankLimit = 48

    private func rebuildDeepRank() {
        let selectedDeep = Set(items.filter {
            $0.kind == .citedDeep && $0.isSelected
        }.map(\.id))
        items.removeAll { $0.kind == .citedDeep }
        for index in items.indices where items[index].kind == .cited {
            items[index].citedIDs = []
        }
        // Owners whose citation left the wall lose their rank.
        deepParentIDs = deepParentIDs.filter { id in
            items.contains { $0.id == id && $0.kind == .cited }
        }

        var raisedAll: [EPUBMapItem] = []
        for parentID in deepParentIDs.sorted() {
            guard let parent = items.firstIndex(where: { $0.id == parentID }),
                  let anchor = items[parent].position,
                  let entry = CitationGraph.cached(
                      forKey: String(parentID.dropFirst("cited:".count))),
                  entry.found
            else { continue }

            // Newest first, capped — raising hundreds of cards at once
            // would stall the rasterizer mid-room.
            let references = entry.references
                .sorted { ($0.year ?? Int.min, $0.title) > ($1.year ?? Int.min, $1.title) }
                .prefix(Self.deepRankLimit)

            var children: [String] = []
            var raised: [EPUBMapItem] = []
            var raisedYear: [String: Int] = [:]
            var seen = Set<String>()
            for reference in references {
                let childKey = CitationGraph.key(title: reference.title,
                                                 author: reference.authors)
                guard childKey != "|", seen.insert(childKey).inserted else { continue }
                let wallID = "cited:" + childKey
                guard wallID != parentID else { continue }
                if items.contains(where: { $0.id == wallID }) {
                    children.append(wallID)
                    continue
                }
                let deepID = "deep:" + childKey
                children.append(deepID)
                // Another rank may have raised the same work already —
                // one card, lines from both parents.
                guard !raisedAll.contains(where: { $0.id == deepID }) else { continue }
                if let year = reference.year { raisedYear[deepID] = year }
                citedFacts[deepID] = CitedFacts(abstract: nil,
                                                doi: reference.doi?.lowercased())
                raised.append(EPUBMapItem(
                    id: deepID,
                    title: reference.title,
                    author: reference.year.map { "\(reference.authors) · \($0)" }
                        ?? reference.authors,
                    kind: .citedDeep,
                    isSelected: selectedDeep.contains(deepID)))
            }

            // The rank spreads in X and Y behind its citation, but
            // every raised card's Z is its own publication year on the
            // corridor's timeline — a citation shown is a citation
            // placed in time; the dateless stand at the far plane.
            let columns = max(1, Int(Double(raised.count * 7).squareRoot() / 2))
            let rows = raised.isEmpty ? 0 : (raised.count - 1) / columns + 1
            for index in raised.indices {
                let column = index % columns
                let row = index / columns
                let z: Float
                if let range = citedYearRange, range.newest > range.oldest,
                   let year = raisedYear[raised[index].id] {
                    // Held inside the corridor: a year beyond the
                    // wall's span stands at its nearest edge.
                    let place = min(max(
                        Float(range.newest - year) / Float(range.newest - range.oldest),
                        0), 1)
                    z = citedSpace.z(agePlace: place) + spaceShift.z
                } else {
                    z = citedSpace.z(agePlace: 1.0) + spaceShift.z
                }
                raised[index].position = SIMD3<Float>(
                    anchor.x + (Float(column) - Float(columns - 1) / 2) * 0.19,
                    anchor.y + (Float(rows - 1) / 2 - Float(row)) * 0.11,
                    z)
                citedTimelineZ[raised[index].id] = z
            }

            items[parent].citedIDs = children
            raisedAll.append(contentsOf: raised)
        }
        items.append(contentsOf: raisedAll)

        // The links of the deep cards still selected, refreshed against
        // the rebuilt room; the vanished are forgotten.
        deepLinks = [:]
        for item in items where item.kind == .citedDeep && item.isSelected {
            computeDeepLinks(for: item)
        }
    }

    /// What the graph knows about a selected second-rank card: every
    /// visible cited work whose reference list names it (leading to
    /// it), and every visible card its own reference list names
    /// (leading from it — including siblings in its own rank). Stored
    /// per card, so several can hold their lines at once.
    private func computeDeepLinks(for item: EPUBMapItem) {
        let key = String(item.id.dropFirst("deep:".count))
        var inbound: Set<String> = []
        var outbound: Set<String> = []

        func keyOf(_ other: EPUBMapItem) -> String? {
            switch other.kind {
            case .article: return nil
            case .cited: return String(other.id.dropFirst("cited:".count))
            case .citedDeep: return String(other.id.dropFirst("deep:".count))
            }
        }

        for other in items {
            guard let otherKey = keyOf(other), otherKey != key,
                  let entry = CitationGraph.cached(forKey: otherKey), entry.found
            else { continue }
            if entry.references.contains(where: {
                CitationGraph.key(title: $0.title, author: $0.authors) == key
            }) {
                inbound.insert(other.id)
            }
        }

        if let entry = CitationGraph.cached(forKey: key), entry.found {
            let citedKeys = Set(entry.references.map {
                CitationGraph.key(title: $0.title, author: $0.authors)
            })
            for other in items {
                if let otherKey = keyOf(other), otherKey != key,
                   citedKeys.contains(otherKey) {
                    outbound.insert(other.id)
                }
            }
        }

        deepLinks[item.id] = DeepLinks(inbound: inbound, outbound: outbound)
    }

    /// The arm menu, Author's component: Settings and Documents ride
    /// the right forearm, exactly as in Author's Map; Pin and Set Aside
    /// ride the left, acting on the selected card.
    @State private var armMenu = ArmMenu(chips: [
        ArmMenu.Chip(id: EPUBMapView.settingsChipID, title: "Settings", side: .right),
        ArmMenu.Chip(id: EPUBMapView.documentsChipID, title: "Documents", side: .right),
        ArmMenu.Chip(id: EPUBMapView.timeflowRightChipID, title: "Graph", side: .right),
        ArmMenu.Chip(id: EPUBMapView.dataRightChipID, title: "Time Data", side: .right),
        ArmMenu.Chip(id: EPUBMapView.floorChipID, title: "Floor Timeline", side: .right),
        ArmMenu.Chip(id: EPUBMapView.pinChipID, title: "Pin", side: .left),
        ArmMenu.Chip(id: EPUBMapView.asideChipID, title: "Set Aside", side: .left),
        ArmMenu.Chip(id: EPUBMapView.conceptsChipID, title: "Concepts", side: .left),
        // Graph stands above Time Data on the arm.
        ArmMenu.Chip(id: EPUBMapView.timeflowLeftChipID, title: "Graph", side: .left),
        ArmMenu.Chip(id: EPUBMapView.dataChipID, title: "Time Data", side: .left),
    ], tracksPlanes: true)   // the flat pose finds the actual desk

    private static let settingsChipID = "map.arm.settings"
    private static let documentsChipID = "map.arm.documents"
    private static let pinChipID = "map.arm.pin"
    private static let asideChipID = "map.arm.aside"
    private static let conceptsChipID = "map.arm.concepts"
    private static let dataChipID = "map.arm.data"
    private static let dataRightChipID = "map.arm.data.right"
    private static let timeflowLeftChipID = "map.arm.timeflow.left"
    private static let timeflowRightChipID = "map.arm.timeflow.right"
    private static let floorChipID = "map.arm.floor"

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
            // One tick for every setting the diagrams read — a single
            // observed value keeps the modifier chain type-checkable.
            .onChange(of: sankeySettingsTick) {
                updateSankey()
            }
            .onChange(of: model.floorRevision) {
                updateSankey()
            }
            .onChange(of: model.panelPoses) {
                readerPanels.applyPoses(model.panelPoses)
            }
            .onChange(of: model.readingDeskDocID) {
                // In or out of the Reading Desk: the panels sweep, the
                // ladder folds, and the reload re-evaluates every
                // card's standing through the engine's enable hook.
                readerPanels.hideAll(except: model.readingDeskDocID)
                if model.readingDeskDocID != nil {
                    conceptLadder.close()
                }
                reload()
            }
            .onAppear {
                citedSpace.depth = min(
                    max(Float(citedDepthSetting), CitedSpace.depthRange.lowerBound),
                    CitedSpace.depthRange.upperBound)
                reload()
            }
            // The in-situ readers' handles: their own drag, beside the
            // engine's node drag — a panel goes anywhere, all three
            // axes, no timeline hold.
            .simultaneousGesture(
                DragGesture(coordinateSpace: .global)
                    .targetedToAnyEntity()
                    .onChanged { value in
                        guard let (docID, root) = readerPanels.panel(for: value.entity)
                        else { return }
                        let start = readerPanels.dragStart[docID] ?? root.position
                        readerPanels.dragStart[docID] = start
                        root.position = start + value.convert(
                            value.gestureValue.translation3D, from: .local, to: .scene)
                    }
                    .onEnded { _ in
                        readerPanels.dragStart = [:]
                    })
    }

    /// Everything the diagrams read, folded to one comparable value —
    /// any of it changing re-lays the Timeflows and the floor.
    private var sankeySettingsTick: String {
        [model.sankey?.modified.description ?? "",
         timeSpreadStyleRaw, timeSpreadLayoutRaw, floorShowRaw,
         graphSnapWallLeft.description, graphSnapWallRight.description]
            .joined(separator: "|")
    }

    /// One pinch, one step: deeper stretches the spread into the room
    /// (the rows squeezing toward walking height so the reader can walk
    /// the timeline); shallower gathers it back toward the wall.
    private func stepCitedDepth(deeper: Bool) {
        let next = citedSpace.depth
            * (deeper ? CitedSpace.depthStep : 1 / CitedSpace.depthStep)
        citedSpace.depth = min(
            max(next, CitedSpace.depthRange.lowerBound),
            CitedSpace.depthRange.upperBound)
        citedDepthSetting = Double(citedSpace.depth)
        // The pinch re-lays the whole spread — wandering cited cards
        // rejoin the mapping. The reader's article placements hold.
        placed = placed.filter { !$0.key.hasPrefix("cited:") }
        reload()
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
            // Half-size cards: the room holds more, the words still
            // read at arm's length.
            if item.isAside { return 85.0 }
            switch item.kind {
            case .article: return 100.0
            case .cited: return 75.0
            case .citedDeep: return 60.0
            }
        }
        view = view.onEndMoveNode { _, _, newItems in
            keepPlacements(of: Array(newItems))
        }
        view = view.constrainMovedNode { item, proposed, _ in
            // A citation lives on the timeline: the hand slides it in
            // X and Y, but its Z stays its year's — even mid-drag, so
            // it can never be pulled onto another time.
            guard item.kind != .article, let z = citedTimelineZ[item.id] else {
                return proposed
            }
            var held = proposed
            held.z = z
            return held
        }
        view = view.constructorConnectionModelEntity {
            // The citation lines — Author's connection entity.
            ModelEntity.connection(
                size: 0.0022,
                // A whisper of light grey: found when looked for,
                // never in the way. (Grey carries less pop than the
                // old ember, so it stands a step less transparent.)
                color: Color(white: 0.85).opacity(0.06),
                connectionOptions: .none,
                materialMode: .none)
        }
        view = view.shouldEnableNode { _ in
            // The Reading Desk: while one document is being read
            // alone, every card steps away.
            model.readingDeskDocID == nil
        }
        view = view.shouldDrawConnectionForNode { item in
            model.readingDeskDocID == nil && item.isSelected
        }
        view = view.connectedNodesToNode { item in
            switch item.kind {
            case .cited:
                // A selected citation shows both directions: back to
                // every article naming it, and forward into the raised
                // rank of what it cites itself.
                return items.filter {
                    $0.citedIDs.contains(item.id) || item.citedIDs.contains($0.id)
                }
            case .citedDeep:
                // A selected raised card shows everything leading to
                // it and from it: the citations that raised it, any
                // article citing the same work directly, the works
                // whose references name it, and the visible cards its
                // own references name.
                let wallID = "cited:" + item.id.dropFirst("deep:".count)
                let links = deepLinks[item.id]
                return items.filter {
                    $0.citedIDs.contains(item.id)
                        || $0.citedIDs.contains(wallID)
                        || links?.inbound.contains($0.id) == true
                        || links?.outbound.contains($0.id) == true
                }
            case .article:
                return items.filter { item.citedIDs.contains($0.id) }
            }
        }
        view = view.onTapNode { tapCount, item in
            handleTap(count: tapCount, on: item)
        }
        // The Z control: a two-hand pinch anywhere on the Map. Out
        // stretches the time-spread deeper into the room; in gathers
        // it back. One pinch, one step.
        view = view.onPinchOut {
            stepCitedDepth(deeper: true)
        }
        view = view.onPinchIn {
            stepCitedDepth(deeper: false)
        }
        view = view.defaultMaxWidth(100.0)
        view = view.defaultNodePosition([0.0, 1.4, -1.2])
        view = view.onSetupContent { content in
            armMenu.install(in: content)
            conceptLadder.install(in: content)
            sankeyWallLeft.install(in: content)
            sankeyWallRight.install(in: content)
            floorBand.install(in: content)
            readerPanels.install(in: content)
            fistGrab.install(
                in: content,
                move: { delta in
                    // Live: carry every card by the fist's motion. The
                    // lines follow on their own each frame.
                    for entity in content.entities
                    where entity.components.has(MapSpaceNodeComponent.self) {
                        entity.position += delta
                    }
                },
                release: { carried in
                    commitSpaceShift(carried)
                })
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
                .font(AppFonts.body(5.5, weight: .semibold))
                .lineLimit(1)
                .padding(.horizontal, 4)
                .padding(.vertical, 2.5)
                .opacity(0.5)
        } else {
            // Half-size type for the half-size cards.
            let titleSize: CGFloat = switch item.kind {
            case .article: 7.5
            case .cited: 6
            case .citedDeep: 5
            }
            VStack(spacing: item.kind == .citedDeep ? 1.5 : 2.5) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    if item.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 5))
                            .foregroundStyle(Color(red: 0.72, green: 0.42, blue: 0.06))
                    }
                    Text(item.title)
                        .font(AppFonts.body(titleSize, weight: .semibold))
                        .lineLimit(item.kind == .citedDeep ? 2 : 3)
                }
                Text(item.author)
                    .font(.system(size: item.kind == .article ? 5.5 : 4.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(item.kind == .citedDeep ? 1 : 2)
            }
            .multilineTextAlignment(.center)
            .padding(item.kind == .article ? 5 : (item.kind == .cited ? 4 : 3))
        }
    }

    private func cardEntity(for item: EPUBMapItem, texturedPlane: ModelEntity)
        -> (modelEntity: ModelEntity?, collisionShape: ShapeResource) {
        // Set Aside slips stand at half presence — paper and words
        // both; each rank behind the articles reads a step quieter.
        let opacity: Float = item.isAside ? 0.4
            : (item.kind == .article ? 1.0 : (item.kind == .cited ? 0.92 : 0.85))
        let paper: UIColor = switch item.kind {
        case .article: .white
        // The common ground reads green: a work every raised article
        // cites, when two or more stand raised together.
        case .cited: item.isShared
            ? UIColor(red: 0.63, green: 0.84, blue: 0.63, alpha: 1)
            : UIColor(white: 0.82, alpha: 1)
        case .citedDeep: UIColor(white: 0.72, alpha: 1)
        }
        let box = ModelEntity.box(
            with: texturedPlane,
            // The same face on the card's back, turned to read — a
            // reader deep in the corridor looks back at standing text.
            backPlane: texturedPlane.clone(recursive: true),
            color: paper,
            depth: 0.01,
            margins: item.isAside ? 0.004 : 0.006,
            opacity: opacity,
            cornerRadius: 0.01,
            // The selected card wears the lab's ember — the highlight
            // that anchors the citation lines.
            useBorder: item.isSelected,
            borderColor: item.isSelected
                ? UIColor(red: 0.72, green: 0.42, blue: 0.06, alpha: 1) : .clear,
            materialMode: .none
        )
        // The fist carries every card; the connection lines re-lay
        // themselves from the cards each frame.
        box.modelEntity.components.set(MapSpaceNodeComponent())
        return box
    }

    /// The arm's concept pick: select every article whose text carries
    /// the concept — additive, exactly as if each had been tapped, so
    /// their citation walls rise together and each card deselects
    /// individually.
    private func selectConcept(_ name: String) {
        let matches = model.articleIDs(mentioning: name)
        guard !matches.isEmpty else { return }
        for index in items.indices
        where items[index].kind == .article && matches.contains(items[index].id) {
            items[index].isSelected = true
            raisedArticleIDs.insert(items[index].id)
        }
        reload()
    }

    /// The fist set the space down: fold the carry into every item,
    /// every placement, and the seed shift — so reloads, new raises
    /// and the engine's own bookkeeping all live in the moved space.
    private func commitSpaceShift(_ delta: SIMD3<Float>) {
        guard delta != .zero else { return }
        spaceShift += delta
        // The timeline travels with the carried space.
        citedTimelineZ = citedTimelineZ.mapValues { $0 + delta.z }
        for index in items.indices {
            if let position = items[index].position {
                items[index].position = position + delta
            }
        }
        for (id, position) in placed {
            placed[id] = position + delta
        }
        for item in items {
            if let position = item.position {
                placed[item.id] = position
            }
        }
    }

    /// Keep the moved positions in the items (so the engine's equality
    /// checks see them where they stand) and in the placement memory
    /// (so they survive reloads). Every citation — wall or raised rank
    /// — keeps its year's Z: the drag slides it in X and Y, and on
    /// release the timeline holds.
    private func keepPlacements(of moved: [EPUBMapItem]) {
        for item in moved {
            var position = item.position
            if item.kind != .article, let z = citedTimelineZ[item.id] {
                position?.z = z
            }
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                items[index].position = position
            }
            if let position {
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
            // Selection is additive and sticky: each tap toggles its
            // own card, and every selected card keeps its lines and
            // its raise until deselected.
            let willSelect = !item.isSelected
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                items[index].isSelected = willSelect
            }
            switch item.kind {
            case .article:
                // A selected article holds its citations up; several
                // articles can hold their walls at once.
                if willSelect {
                    raisedArticleIDs.insert(item.id)
                } else {
                    raisedArticleIDs.remove(item.id)
                }
                reload()
            case .cited:
                // A selected citation raises what IT cites behind it.
                if willSelect {
                    deepParentIDs.insert(item.id)
                } else {
                    deepParentIDs.remove(item.id)
                }
                rebuildDeepRank()
            case .citedDeep:
                // The selected card shows every citation leading to it
                // and away from it, read from the graph.
                if willSelect {
                    computeDeepLinks(for: item)
                } else {
                    deepLinks[item.id] = nil
                }
            }
        case 2:
            // The card steps off the Map and its reading opens in-situ
            // — the full reader standing where the card stood, movable
            // anywhere by its handle, free of the timeline. Closing
            // brings the card back. A citation opens its record card
            // instead: everything we hold on it, and Acquire.
            guard item.kind == .article else {
                openCitationCard(for: item)
                return
            }
            let docID = item.id
            let position = (item.position ?? SIMD3<Float>(0, 1.4, -1.0))
                + SIMD3<Float>(0, 0, 0.06)
            readerPanels.open(
                docID: docID,
                at: position,
                view: AnyView(
                    MapReaderPanel(docID: docID, title: item.title) {
                        closeReader(docID)
                    }
                    .environment(model)),
                onClose: { closeReader(docID) })
            model.openDocIDs.insert(docID)
        default:
            break
        }
    }

    /// One close for every door a panel offers — the title bar's ✕ and
    /// the spatial ✕ beside the pill: the desk ends if it was this
    /// document's, the panel goes, the card returns.
    private func closeReader(_ docID: String) {
        if model.readingDeskDocID == docID {
            model.readingDeskDocID = nil
        }
        readerPanels.close(docID: docID)
        model.openDocIDs.remove(docID)
    }

    /// A citation's record, opened in-situ where the card stands: the
    /// title, the authors and year, the abstract when the reference
    /// carried one — and Acquire, bottom centre, listing the work in
    /// the Mac's library as a book to download.
    private func openCitationCard(for item: EPUBMapItem) {
        let cardID = "cite-card:" + item.id
        let key = item.id.hasPrefix("cited:")
            ? String(item.id.dropFirst("cited:".count))
            : String(item.id.dropFirst("deep:".count))
        // The face's byline is "authors · year"; split them back.
        let parts = item.author.components(separatedBy: " \u{00B7} ")
        let author = parts.first ?? item.author
        let year = parts.count > 1 ? Int(parts.last ?? "") : nil
        let facts = citedFacts[item.id]
        let position = (item.position ?? SIMD3<Float>(0, 1.4, -1.0))
            + SIMD3<Float>(0, 0, 0.06)
        readerPanels.open(
            docID: cardID,
            at: position,
            view: AnyView(
                CitationCardPanel(citationKey: key,
                                  title: item.title,
                                  author: author,
                                  year: year,
                                  abstract: facts?.abstract,
                                  doi: facts?.doi) {
                    readerPanels.close(docID: cardID)
                }
                .environment(model)),
            onClose: { readerPanels.close(docID: cardID) })
    }

    private func handleArmTap(on entity: Entity) -> Bool {
        // A rung of the open Concepts ladder: picking one folds the
        // ladder and highlights every article carrying the concept.
        if let concept = conceptLadder.concept(for: entity) {
            conceptLadder.close()
            selectConcept(concept)
            return true
        }
        switch armMenu.chipID(for: entity) {
        case Self.conceptsChipID:
            // Interatlas's levels: tap Concepts and the reader's
            // concepts unfold up the forearm; tap again to fold.
            conceptLadder.toggle(concepts: model.concepts)
            return true
        // Each arm's Time Data curates its own side's graph.
        case Self.dataChipID:
            openWindow(id: "data", value: "left")
            return true
        case Self.dataRightChipID:
            openWindow(id: "data", value: "right")
            return true
        case Self.timeflowLeftChipID:
            timeflowLeftShown.toggle()
            updateSankey()
            return true
        case Self.timeflowRightChipID:
            timeflowRightShown.toggle()
            updateSankey()
            return true
        case Self.floorChipID:
            // The floor timeline, on and off: off remembers the theme,
            // on brings it back.
            if floorShowRaw == FloorShow.nothing.rawValue {
                floorShowRaw = floorShowLastRaw
            } else {
                floorShowLastRaw = floorShowRaw
                floorShowRaw = FloorShow.nothing.rawValue
            }
            return true
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

/// Marks the entities the fist carries: every card on the Map. The
/// connection lines need no mark — the engine's MovableConnectionsSystem
/// re-lays them from the cards each frame.
struct MapSpaceNodeComponent: Component {}

/// The whole-space grab: close either hand into a fist and the space
/// follows it; open the hand and the space sets down. Fist detection
/// rides RealityKit hand anchors — the same SpatialTrackingSession the
/// arm menu already runs — read once a frame off the scene's update.
@MainActor
final class FistGrab {
    private struct Hand {
        let palm: AnchorEntity
        let thumbTip: AnchorEntity
        let curlTips: [AnchorEntity]
        var isFist = false
        var lastPalm: SIMD3<Float>?
    }

    private var hands: [Hand] = []
    /// Which hand is carrying — the first fist wins; the other hand
    /// is ignored until the carry ends.
    private var driving: Int?
    /// The carry so far, handed to `release` when the fist opens.
    private var carried = SIMD3<Float>.zero
    private var subscription: EventSubscription?
    private var move: ((SIMD3<Float>) -> Void)?
    private var release: ((SIMD3<Float>) -> Void)?

    /// A fist closes when the finger tips draw within this of the palm
    /// — and re-opens past the wider bound, so the grip cannot flicker.
    private static let closeWithin: Float = 0.055
    private static let openBeyond: Float = 0.075
    /// A pinch is not a fist: when the thumb tip touches the index tip
    /// the system pinch owns the hand.
    private static let pinchClearance: Float = 0.035
    /// The carry is geared up — the space moves further than the hand,
    /// so a large room crosses the floor without long reaches.
    private static let carryGain: Float = 2.5

    func install(in content: RealityViewContent,
                 move: @escaping (SIMD3<Float>) -> Void,
                 release: @escaping (SIMD3<Float>) -> Void) {
        MapSpaceNodeComponent.registerComponent()
        self.move = move
        self.release = release

        hands = [AnchoringComponent.Target.Chirality.left, .right].map { side in
            let palm = AnchorEntity(.hand(side, location: .palm))
            let thumb = AnchorEntity(.hand(side, location: .joint(for: .thumbTip)))
            let tips = [AnchoringComponent.Target.HandLocation.HandJoint.indexFingerTip,
                        .middleFingerTip, .ringFingerTip].map {
                AnchorEntity(.hand(side, location: .joint(for: $0)))
            }
            ([palm, thumb] + tips).forEach { content.add($0) }
            return Hand(palm: palm, thumbTip: thumb, curlTips: tips)
        }

        subscription = content.subscribe(to: SceneEvents.Update.self) { _ in
            MainActor.assumeIsolated {
                self.tick()
            }
        }
    }

    private func tick() {
        for index in hands.indices {
            let palm = hands[index].palm.position(relativeTo: nil)
            // An untracked hand's anchors all sit at the origin — which
            // would read as a perfect fist. Skip it.
            guard palm != .zero else { continue }

            let bound = hands[index].isFist ? Self.openBeyond : Self.closeWithin
            let tips = hands[index].curlTips.map { $0.position(relativeTo: nil) }
            let thumb = hands[index].thumbTip.position(relativeTo: nil)
            let curled = tips.allSatisfy { distance($0, palm) < bound }
                && distance(thumb, tips[0]) > Self.pinchClearance

            if curled {
                if !hands[index].isFist {
                    hands[index].isFist = true
                    hands[index].lastPalm = palm
                    if driving == nil {
                        driving = index
                        carried = .zero
                    }
                } else if driving == index, let last = hands[index].lastPalm {
                    let delta = (palm - last) * Self.carryGain
                    hands[index].lastPalm = palm
                    if delta != .zero {
                        carried += delta
                        move?(delta)
                    }
                }
            } else if hands[index].isFist {
                hands[index].isFist = false
                hands[index].lastPalm = nil
                if driving == index {
                    driving = nil
                    release?(carried)
                    carried = .zero
                }
            }
        }
    }
}

/// The Concepts ladder: Interatlas's levels on Origami's left arm.
/// Tapping the Concepts chip unfolds one glass rung per tracked
/// concept, climbing off the forearm above the chips; picking a rung
/// (or tapping Concepts again) folds the ladder away. Built with the
/// same anchors and per-frame layout as the ArmMenu it stands over.
@MainActor
final class ConceptLadder {
    private var wrist: AnchorEntity?
    private var knuckle: AnchorEntity?
    private var holder: Entity?
    private var rungs: [(concept: String, entity: Entity)] = []
    private var subscription: EventSubscription?
    private(set) var isOpen = false

    private static let namePrefix = "map.concept."

    func install(in content: RealityViewContent) {
        guard holder == nil else { return }
        let wristAnchor = AnchorEntity(.hand(.left, location: .joint(for: .wrist)))
        let knuckleAnchor = AnchorEntity(.hand(.left, location: .joint(for: .middleFingerKnuckle)))
        let holder = Entity()
        holder.name = "map.concepts.ladder"
        holder.isEnabled = false
        wristAnchor.addChild(holder)
        content.add(wristAnchor)
        content.add(knuckleAnchor)
        self.wrist = wristAnchor
        self.knuckle = knuckleAnchor
        self.holder = holder
        subscription = content.subscribe(to: SceneEvents.Update.self) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// Unfolds with the given concepts, rebuilt fresh each opening so
    /// the ladder always carries the current list — or folds away.
    func toggle(concepts: [String]) {
        if isOpen {
            close()
            return
        }
        guard let holder else { return }
        for (_, entity) in rungs {
            entity.removeFromParent()
        }
        rungs = []
        // An empty list still answers — a single quiet rung says so.
        let names = concepts.isEmpty ? [] : concepts
        for name in names {
            let rung = Entity()
            rung.name = Self.namePrefix + name
            rung.components.set(CollisionComponent(
                shapes: [.generateBox(size: SIMD3<Float>(0.07, 0.035, 0.03))]))
            rung.components.set(InputTargetComponent())
            rung.components.set(HoverEffectComponent())
            let label = Entity()
            label.components.set(ViewAttachmentComponent(rootView: ArmChipView(text: name)))
            label.components.set(BillboardComponent())
            label.scale = SIMD3<Float>(repeating: 0.32)
            rung.addChild(label)
            holder.addChild(rung)
            rungs.append((name, rung))
        }
        if names.isEmpty {
            let rung = Entity()
            rung.name = "map.concepts.empty"
            let label = Entity()
            label.components.set(ViewAttachmentComponent(
                rootView: ArmChipView(text: "No concepts yet")))
            label.components.set(BillboardComponent())
            label.scale = SIMD3<Float>(repeating: 0.32)
            rung.addChild(label)
            holder.addChild(rung)
            rungs.append(("", rung))
        }
        isOpen = true
        holder.isEnabled = true
    }

    func close() {
        isOpen = false
        holder?.isEnabled = false
    }

    /// The concept under a tapped entity, walking up parents — nil for
    /// anything not a live rung.
    func concept(for entity: Entity) -> String? {
        guard isOpen else { return nil }
        var node: Entity? = entity
        while let current = node {
            if current.name.hasPrefix(Self.namePrefix) {
                return String(current.name.dropFirst(Self.namePrefix.count))
            }
            node = current.parent
        }
        return nil
    }

    /// ArmMenu's forearm frame, one ladder-width higher: the rungs
    /// climb the lift axis, clear of the chips beneath.
    private func tick() {
        guard isOpen, let wrist, let knuckle, let holder else { return }
        guard wrist.isAnchored, knuckle.isAnchored else {
            holder.isEnabled = false
            return
        }
        holder.isEnabled = true

        let fingerWorld = knuckle.position(relativeTo: nil) - wrist.position(relativeTo: nil)
        let fingerLocal = wrist.convert(direction: fingerWorld, from: nil)
        let alongArm: SIMD3<Float> = fingerLocal.x >= 0 ? SIMD3(-1, 0, 0) : SIMD3(1, 0, 0)

        var lift = wrist.convert(direction: SIMD3<Float>(0, 1, 0), from: nil)
        lift -= alongArm * simd_dot(lift, alongArm)
        let liftLength = simd_length(lift)
        guard liftLength > 1e-5 else { return }
        lift /= liftLength

        for (index, rung) in rungs.enumerated() {
            rung.entity.position = alongArm * 0.09
                + lift * (0.16 + 0.055 * Float(index))
        }
    }
}

/// The Sankey along the corridor: one textured plane standing beside
/// the cited time-spread, turned to run along Z, its image drawn so
/// every year's x lands at exactly that year's citation depth — the
/// nearest edge is the newest year, as the corridor is. Width encodes
/// the value, the true Sankey way. Rendered through the engine's own
/// device-proven texture pipeline.
@MainActor
final class SankeyWall {
    private var content: RealityViewContent?
    private var entity: ModelEntity?

    /// The face's logical size: 1400pt maps to 1.4m at the engine's
    /// ratio, then the length is scaled to the corridor's exact depth.
    /// Tall enough that the key band leaves the plot its room.
    private static let faceSize = CGSize(width: 1400, height: 560)
    /// How far from the wall's centre it stands — negative to the
    /// walker's left, positive to the right of the nodes.
    private let sideOffset: Float
    /// The band's centre height — chest-to-eye, the corridor's walking
    /// band.
    private static let height: Float = 1.35

    init(sideOffset: Float) {
        self.sideOffset = sideOffset
    }

    func install(in content: RealityViewContent) {
        self.content = content
        // The room's own wall, for the snap option: a wall-classified
        // vertical plane on the arm menu's one tracking session —
        // never a second session.
        let wall = AnchorEntity(.plane(.vertical, classification: .wall,
                                       minimumBounds: SIMD2<Float>(1, 1)))
        content.add(wall)
        wallAnchor = wall
        snapTick = content.subscribe(to: SceneEvents.Update.self) { [weak self] _ in
            MainActor.assumeIsolated { self?.settleToWall() }
        }
    }

    /// The graph style's series, standing as real tubes in the room.
    private var cylinders: Entity?
    /// The key's card, standing in front of the plot.
    private var keyEntity: Entity?
    /// The snap-to-wall option's anchor and settle.
    private var wallAnchor: AnchorEntity?
    private var snapTick: EventSubscription?
    private var snapsToWall = false
    /// The corridor-given x the graph stands at when no wall claims it.
    private var baseX: Float = 0

    /// Which side's series this wall carries — an untagged series
    /// stands on both.
    private var side: String { sideOffset < 0 ? "left" : "right" }

    /// The room wall's x, when one has anchored on this graph's own
    /// side within a room's reach — pulled a hand's breadth off the
    /// plaster.
    private func wallX() -> Float? {
        guard let wallAnchor, wallAnchor.isAnchored else { return nil }
        let x = wallAnchor.position(relativeTo: nil).x
        if sideOffset < 0 {
            guard x < baseX, x > baseX - 6 else { return nil }
            return x + 0.05
        } else {
            guard x > baseX, x < baseX + 6 else { return nil }
            return x - 0.05
        }
    }

    /// The graph keeps to the room's wall while the option is on, and
    /// to its corridor place otherwise — the key and the cylinders
    /// stepping with it.
    private func settleToWall() {
        guard let entity else { return }
        let targetX = snapsToWall ? (wallX() ?? baseX) : baseX
        guard abs(entity.position.x - targetX) > 0.005 else { return }
        entity.position.x = targetX
        keyEntity?.position.x = targetX
        cylinders?.position.x = targetX - baseX
    }

    func update(dataset: SankeySpace.Dataset?,
                years: (newest: Int, oldest: Int)?,
                citedSpace: EPUBMapView.CitedSpace,
                shift: SIMD3<Float>,
                style: TimeSpreadStyle,
                layout: TimeSpreadLayout,
                snapToWall: Bool = false) {
        entity?.removeFromParent()
        entity = nil
        cylinders?.removeFromParent()
        cylinders = nil
        keyEntity?.removeFromParent()
        keyEntity = nil
        snapsToWall = snapToWall
        baseX = citedSpace.origin.x + sideOffset + shift.x
        let dataset = dataset.map { whole in
            var mine = whole
            mine.series = whole.series.filter { $0.wall == nil || $0.wall == side }
            return mine
        }
        guard let content, let dataset, !dataset.series.isEmpty,
              let years, years.newest > years.oldest else { return }
        if style == .graph {
            addCylinders(dataset: dataset, years: years,
                         citedSpace: citedSpace, shift: shift, layout: layout)
        }

        // Two faces, each drawn for its own side — the mirrored one
        // keeps every year at the same Z with its words still reading
        // left to right — so the diagram is legible from the corridor
        // and from beyond it alike.
        func plane(mirrored: Bool) -> ModelEntity? {
            let face = SankeyRibbonView(dataset: dataset,
                                        newest: years.newest, oldest: years.oldest,
                                        mirrored: mirrored,
                                        style: style,
                                        layout: layout)
                .frame(width: Self.faceSize.width, height: Self.faceSize.height)
            let renderer = ImageRenderer(content: face)
            renderer.scale = 2
            renderer.isOpaque = false
            guard let image = renderer.uiImage else { return nil }
            return ModelEntity.texturedPlane(with: image, ratio: 0.001)
        }
        guard let front = plane(mirrored: false) else { return }

        let holder = ModelEntity()
        holder.components.set(MapSpaceNodeComponent())
        // The near face toward the corridor: +π/2 about Y points its
        // normal at +X, its image left edge at the near (newest) end.
        front.orientation = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 1, 0))
        front.position = SIMD3<Float>(0.002, 0, 0)
        holder.addChild(front)
        if let back = plane(mirrored: true) {
            back.orientation = simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(0, 1, 0))
            back.position = SIMD3<Float>(-0.002, 0, 0)
            holder.addChild(back)
        }

        let baseLength = Float(Self.faceSize.width) * 0.001
        let along = citedSpace.depth / baseLength
        holder.scale = SIMD3<Float>(1, min(along, 2.4), along)
        holder.position = SIMD3<Float>(
            citedSpace.origin.x + sideOffset,
            Self.height,
            citedSpace.origin.z - citedSpace.depth / 2) + shift
        content.add(holder)
        entity = holder

        // The key: a plate at the graph's near (newest) end, standing
        // across the X axis and facing the walker — where the graph
        // starts, closest to the reader. Unscaled, so the words keep
        // their size however the corridor stretches.
        let keyRenderer = ImageRenderer(content: GraphKeyView(dataset: dataset))
        keyRenderer.scale = 2
        keyRenderer.isOpaque = false
        if let keyImage = keyRenderer.uiImage,
           let face = ModelEntity.texturedPlane(with: keyImage, ratio: 0.001) {
            let keyHolder = ModelEntity()
            keyHolder.components.set(MapSpaceNodeComponent())
            keyHolder.addChild(face)   // unrotated: its face reads down +Z, at the walker
            keyHolder.position = SIMD3<Float>(
                citedSpace.origin.x + sideOffset,
                Self.height,
                citedSpace.origin.z + 0.06) + shift
            content.add(keyHolder)
            keyEntity = keyHolder
        }
    }

    /// The value band the tubes stand in — chest to eye, matching the
    /// face's plot area near enough that the ticks frame them.
    private static let tubeBottom: Float = 1.02
    private static let tubeTop: Float = 1.68
    /// One tube segment per year-step, thinned when a long span would
    /// crowd the room with geometry.
    private static let segmentTarget = 120

    /// The graph as the room's own geometry: every series a run of
    /// cylinders through the years, at exactly the citations' depths —
    /// unit cylinders scaled and turned between the points, one mesh
    /// and one material per series.
    private func addCylinders(dataset: SankeySpace.Dataset,
                              years: (newest: Int, oldest: Int),
                              citedSpace: EPUBMapView.CitedSpace,
                              shift: SIMD3<Float>,
                              layout: TimeSpreadLayout) {
        guard let content,
              let norm = TimeSpreadInk.normalizer(for: dataset, layout: layout)
        else { return }
        let pairIndices = TimeSpreadInk.pairIndices(of: dataset)
        let span = Float(years.newest - years.oldest)
        let x = citedSpace.origin.x + sideOffset + shift.x
        func z(_ year: Int) -> Float {
            citedSpace.z(agePlace: Float(years.newest - year) / span) + shift.z
        }
        func y(_ value: Double, in series: SankeySpace.Series) -> Float {
            Self.tubeBottom + Float(norm(value, series)) * (Self.tubeTop - Self.tubeBottom)
        }

        let holder = Entity()
        holder.components.set(MapSpaceNodeComponent())
        let unit = MeshResource.generateCylinder(height: 1, radius: 0.007)

        for series in dataset.series {
            let points = series.values
                .filter { $0.year >= years.oldest && $0.year <= years.newest }
                .sorted { $0.year < $1.year }
            guard points.count >= 2 else { continue }
            let stride = max(1, points.count / Self.segmentTarget)
            let kept = points.enumerated().compactMap { index, point in
                index % stride == 0 || index == points.count - 1 ? point : nil
            }
            var material = UnlitMaterial()
            material.color = .init(tint: UIColor(
                TimeSpreadInk.color(of: series, pairIndices: pairIndices)))
            for (from, to) in zip(kept, kept.dropFirst()) {
                let start = SIMD3<Float>(x, y(from.value, in: series), z(from.year))
                let end = SIMD3<Float>(x, y(to.value, in: series), z(to.year))
                let run = end - start
                let length = simd_length(run)
                guard length > 0.0005 else { continue }
                let segment = ModelEntity(mesh: unit, materials: [material])
                segment.scale = SIMD3<Float>(1, length, 1)
                segment.orientation = simd_quatf(
                    from: SIMD3<Float>(0, 1, 0), to: run / length)
                segment.position = (start + end) / 2
                holder.addChild(segment)
            }
        }
        content.add(holder)
        cylinders = holder
    }
}

/// The diagram's face: each series a ribbon flowing left (newest) to
/// right (oldest), its WIDTH at every year the value — the Sankey
/// encoding — over decade tick lines that land exactly where those
/// years' citations stand. Drawn edge to edge so the year-to-x mapping
/// is the corridor's year-to-z mapping, unpadded.
/// Marks an in-situ reader's handle bar, carrying its document.
struct ReaderHandleComponent: Component {
    var docID: String
}

/// The ✕ in its circle: always there but very faded, brightening to
/// full under the gaze — the fade rides a custom hover effect,
/// composited by the system, so the app never learns the gaze.
private struct ReaderCloseGlyph: View {
    let onClose: () -> Void

    var body: some View {
        Button(action: onClose) {
            ZStack {
                Circle()
                    .fill(.white.opacity(0.22))
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .frame(width: 30, height: 30)
            .padding(10)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .hoverEffect { effect, isActive, _ in
            effect.opacity(isActive ? 1 : 0.22)
        }
    }
}

/// The in-situ readers: each a full reading standing in the room where
/// its card stood — hosted the arm-chip way, a live SwiftUI view on an
/// entity — with a slim handle bar above the page for dragging it
/// anywhere, and no timeline hold. One panel per document.
@MainActor
final class ReaderPanels {
    private var content: RealityViewContent?
    private var roots: [String: Entity] = [:]
    /// Where each drag began, by document — cleared when it ends.
    var dragStart: [String: SIMD3<Float>] = [:]
    /// The desk found in the room: a table-classified horizontal
    /// plane, anchored by RealityKit on the arm menu's own tracking
    /// session — never a second session (the Hallway's hard lesson).
    private var deskAnchor: AnchorEntity?
    private var snapTick: EventSubscription?

    func install(in content: RealityViewContent) {
        ReaderHandleComponent.registerComponent()
        self.content = content
        let desk = AnchorEntity(.plane(.horizontal, classification: .table,
                                       minimumBounds: SIMD2<Float>(0.4, 0.4)))
        content.add(desk)
        deskAnchor = desk
        // The snap: a flat panel keeps to the desk's surface as the
        // anchor resolves or refines — X and Z stay the reader's, so a
        // drag slides the page across the desk, never off it.
        snapTick = content.subscribe(to: SceneEvents.Update.self) { [weak self] _ in
            MainActor.assumeIsolated { self?.snapFlatPanels() }
        }
    }

    /// The desk surface's world height, when the room has offered one.
    private func deskSurfaceY() -> Float? {
        guard let deskAnchor, deskAnchor.isAnchored else { return nil }
        let y = deskAnchor.position(relativeTo: nil).y
        // A believable desk: knee to chest height.
        return (0.3...1.2).contains(y) ? y : nil
    }

    /// The world height a flat page lies at: the desk itself when the
    /// room has shown one, a table's usual height until then.
    private var flatY: Float {
        (deskSurfaceY() ?? Self.tableHeight) + Self.flatClearance
    }
    // A whisper above the wood — enough to never z-fight the
    // passthrough surface, never a visible hover.
    private static let flatClearance: Float = 0.002

    private func snapFlatPanels() {
        let target = flatY
        for (id, root) in roots where appliedPoses[id] == .flat {
            if abs(root.position.y - target) > 0.005 {
                root.position.y = target
            }
        }
    }

    func open(docID: String, at position: SIMD3<Float>, view: AnyView,
              onClose: @escaping () -> Void) {
        guard let content else { return }
        // Already open: bring it to the asked place instead.
        if let standing = roots[docID] {
            standing.position = position
            return
        }
        let root = Entity()
        root.position = position

        let page = Entity()
        page.components.set(ViewAttachmentComponent(rootView: view))
        root.addChild(page)

        // The handle: the system's own kind of grab bar — a small
        // white pill just under the page. Only it drags, so the page
        // keeps every touch for reading. (Attachments render at
        // ~1360pt/m; an 800pt page is ~0.59m tall.)
        var material = UnlitMaterial()
        material.color = .init(tint: UIColor(white: 1, alpha: 0.5))
        let bar = ModelEntity(
            mesh: .generateBox(size: SIMD3<Float>(0.10, 0.006, 0.006),
                               cornerRadius: 0.003),
            materials: [material])
        bar.position = SIMD3<Float>(0, -0.32, 0)
        bar.components.set(CollisionComponent(
            shapes: [.generateBox(size: SIMD3<Float>(0.14, 0.035, 0.03))]))
        bar.components.set(InputTargetComponent())
        bar.components.set(HoverEffectComponent())
        bar.components.set(ReaderHandleComponent(docID: docID))
        root.addChild(bar)

        // The ✕ in its circle, left of the pill — the system window
        // bar's grammar: there when looked at, gone when not.
        let close = Entity()
        close.components.set(ViewAttachmentComponent(
            rootView: ReaderCloseGlyph(onClose: onClose)))
        close.position = SIMD3<Float>(-0.095, -0.32, 0)
        root.addChild(close)

        content.add(root)
        roots[docID] = root
    }

    func close(docID: String) {
        roots[docID]?.removeFromParent()
        roots[docID] = nil
        dragStart[docID] = nil
    }

    /// The Reading Desk's sweep: every panel steps away except the one
    /// being read; nil brings them all back.
    func hideAll(except docID: String?) {
        for (id, root) in roots {
            root.isEnabled = docID == nil || id == docID
        }
    }

    /// The standing height a posed panel returns to, by document.
    private var uprightY: [String: Float] = [:]
    /// Each panel's applied pose, so a repeat apply is a no-op.
    private var appliedPoses: [String: PanelPose] = [:]
    /// The reading surface — a table's height.
    private static let tableHeight: Float = 0.75
    /// The drafting board's height and lean.
    private static let tiltedHeight: Float = 0.95
    private static let tiltedAngle: Float = -.pi / 4

    /// Poses the panels: standing where they were, tilted like a
    /// drafting board at 45°, or flat on the table — the page's top
    /// away from the reader either way.
    func applyPoses(_ poses: [String: PanelPose]) {
        for (id, root) in roots {
            let pose = poses[id] ?? .upright
            guard pose != (appliedPoses[id] ?? .upright) else { continue }
            // Leaving upright remembers the standing height once.
            if appliedPoses[id] ?? .upright == .upright {
                uprightY[id] = root.position.y
            }
            switch pose {
            case .upright:
                root.orientation = simd_quatf()
                root.position.y = uprightY.removeValue(forKey: id) ?? 1.35
            case .tilted:
                root.orientation = simd_quatf(angle: Self.tiltedAngle,
                                              axis: SIMD3<Float>(1, 0, 0))
                root.position.y = Self.tiltedHeight
            case .flat:
                root.orientation = simd_quatf(angle: -.pi / 2,
                                              axis: SIMD3<Float>(1, 0, 0))
                root.position.y = flatY
            }
            appliedPoses[id] = pose
        }
    }

    /// The panel a touched entity belongs to — the handle bar answers,
    /// walking up parents.
    func panel(for entity: Entity) -> (docID: String, root: Entity)? {
        var node: Entity? = entity
        while let current = node {
            if let handle = current.components[ReaderHandleComponent.self],
               let root = roots[handle.docID] {
                return (handle.docID, root)
            }
            node = current.parent
        }
        return nil
    }
}

/// The Reading Desk's dress — chosen in Settings, worn by the panel
/// only while the desk stands. Light and dark to begin with.
enum ReadingDeskTheme: String, CaseIterable, Identifiable {
    case light
    case dark

    var id: String { rawValue }
    var displayName: String { self == .light ? "Light" : "Dark" }

    var scheme: ColorScheme { self == .light ? .light : .dark }

    /// The page behind the words — warm paper, or a quiet near-black.
    var page: Color {
        self == .light
            ? Color(red: 0.98, green: 0.97, blue: 0.94)
            : Color(red: 0.11, green: 0.11, blue: 0.12)
    }
}

/// The in-situ reader's dress: a title bar with the Reading Desk
/// toggle on its left and close on its right, the full reading
/// beneath — the reader itself manages the card's leave and return
/// through its own appear and disappear. On the desk, the panel wears
/// the chosen theme's page instead of glass.
struct MapReaderPanel: View {
    @Environment(VisionModel.self) private var model
    let docID: String
    let title: String
    let onClose: () -> Void

    /// The desk's theme — Settings ▸ Reading Desk.
    @AppStorage("readingDeskTheme") private var deskThemeRaw =
        ReadingDeskTheme.light.rawValue
    /// The reading view inside, shared with VisionReaderView — the
    /// Horizontal view earns a panel wide enough for whole pages.
    @AppStorage("visionReaderMode") private var readerModeRaw = "scroll"

    private var isDesk: Bool { model.readingDeskDocID == docID }
    private var theme: ReadingDeskTheme {
        ReadingDeskTheme(rawValue: deskThemeRaw) ?? .light
    }

    private var poseIcon: String {
        switch model.pose(of: docID) {
        case .upright: "arrow.down.to.line.compact"
        case .tilted: "arrow.down.to.line"
        case .flat: "arrow.up.to.line.compact"
        }
    }

    private var poseHelp: String {
        switch model.pose(of: docID) {
        case .upright: "Tilt the page like a drafting board"
        case .tilted: "Lay the page flat on the table"
        case .flat: "Stand the page back up"
        }
    }
    /// Horizontal hugs its columns' full breadth (the reader sizes
    /// itself); every other view keeps the page width.
    private var panelWidth: CGFloat? {
        isHorizontal ? nil : 640
    }

    private var isHorizontal: Bool { readerModeRaw == "horizontal" }

    var body: some View {
        if isHorizontal {
            // Horizontal curves its columns, and each wears its own
            // background inside the reader — the panel adds no flat
            // slab for the text to stick out of. The desk theme still
            // sets the words' light or dark.
            if isDesk {
                panel.environment(\.colorScheme, theme.scheme)
            } else {
                panel
            }
        } else if isDesk {
            // On the desk the panel wears the chosen theme: the
            // theme's page instead of the room's glass, its light or
            // dark throughout the words.
            panel
                .background(RoundedRectangle(cornerRadius: 24).fill(theme.page))
                .environment(\.colorScheme, theme.scheme)
        } else {
            panel
                .glassBackgroundEffect()
        }
    }

    private var panel: some View {
        VStack(spacing: isHorizontal ? 12 : 0) {
            headerBar
            if !isHorizontal {
                Divider()
            }
            VisionReaderView(docID: docID)
        }
        .frame(width: panelWidth, height: 800)
    }

    /// The title bar. In Horizontal it floats on a glass (or themed
    /// paper) strip of its own above the curved columns; elsewhere it
    /// sits in the panel's chrome.
    @ViewBuilder private var headerBar: some View {
        let bar = HStack {
                // The Reading Desk toggle: one document (this alone in
                // the room), or many (the Hallway back around it). The
                // panel never moves — everything else steps away.
                Button {
                    model.readingDeskDocID = isDesk ? nil : docID
                } label: {
                    Image(systemName: isDesk ? "doc.on.doc" : "doc")
                }
                .buttonBorderShape(.circle)
                .help(isDesk ? "Back to the Hallway" : "Reading Desk — just this document")
                // The pose cycle: standing → the 45° drafting board →
                // flat on the table → standing again.
                Button {
                    switch model.pose(of: docID) {
                    case .upright: model.panelPoses[docID] = .tilted
                    case .tilted: model.panelPoses[docID] = .flat
                    case .flat: model.panelPoses[docID] = nil
                    }
                } label: {
                    Image(systemName: poseIcon)
                }
                .buttonBorderShape(.circle)
                .help(poseHelp)
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonBorderShape(.circle)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        if !isHorizontal {
            bar
        } else if isDesk {
            bar
                .frame(maxWidth: 900)
                .background(RoundedRectangle(cornerRadius: 18).fill(theme.page))
        } else {
            bar
                .frame(maxWidth: 900)
                .glassBackgroundEffect(in: .rect(cornerRadius: 18))
        }
    }
}

/// A citation's record card, opened in-situ by a double-tap: all the
/// data we hold — title, author, year, abstract — with Acquire at the
/// bottom centre for a work the library does not yet have. Acquiring
/// lists it in the Mac's Time view with an ember dot and its DOI.
struct CitationCardPanel: View {
    @Environment(VisionModel.self) private var model
    let citationKey: String
    let title: String
    let author: String
    let year: Int?
    let abstract: String?
    let doi: String?
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.headline)
                    .lineLimit(2)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonBorderShape(.circle)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text([author, year.map(String.init)]
                        .compactMap { $0 }
                        .filter { !$0.isEmpty }
                        .joined(separator: ", "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let abstract, !abstract.isEmpty {
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
                if model.acquisitionIDs.contains(citationKey) {
                    Label("Listed to acquire", systemImage: "checkmark")
                        .foregroundStyle(.secondary)
                } else {
                    Button("Acquire") {
                        model.requestAcquisition(key: citationKey, title: title,
                                                 author: author, year: year, doi: doi)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(.vertical, 12)
        }
        .frame(width: 460, height: 400)
        .glassBackgroundEffect()
    }
}

/// What lies written on the physical floor — a themed history, or
/// nothing. Chosen in Time Data. The world theme keeps the raw value
/// "history", so the setting from before themes still reads.
enum FloorShow: String, CaseIterable, Identifiable {
    case world = "history"
    case hypertext
    case hypertextPeople
    case environmental
    case space
    case computing
    case discoveries
    case nothing

    var id: String { rawValue }

    var theme: SankeySpace.FloorTheme? {
        switch self {
        case .world: .world
        case .hypertext: .hypertext
        case .hypertextPeople: .hypertextPeople
        case .environmental: .environmental
        case .space: .space
        case .computing: .computing
        case .discoveries: .discoveries
        case .nothing: nil
        }
    }

    var displayName: String { theme?.displayName ?? "Nothing" }
}

/// The floor put to work: a flat band on the real ground beneath the
/// corridor, world history written along it — each event lying at its
/// year's exact depth, the words running along X so the walker reads
/// them like tiles underfoot. Wikidata's most widely carried events
/// win the floor space when years crowd.
@MainActor
final class FloorBand {
    private var content: RealityViewContent?
    private var entity: ModelEntity?

    /// The band's width across the corridor, in points (0.001 ratio:
    /// 1400pt = 1.4m).
    private static let faceWidth: CGFloat = 1400
    /// A whisper above the real floor, so the letters never z-fight
    /// the carpet.
    private static let height: Float = 0.01
    /// The room's actual floor: a floor-classified plane on the arm
    /// menu's own tracking session — never a second session.
    private var floorAnchor: AnchorEntity?
    private var snapTick: EventSubscription?

    func install(in content: RealityViewContent) {
        self.content = content
        let floor = AnchorEntity(.plane(.horizontal, classification: .floor,
                                        minimumBounds: SIMD2<Float>(1, 1)))
        content.add(floor)
        floorAnchor = floor
        // The snap: the band keeps to the real floor as the anchor
        // resolves or refines; until then the world origin stands in.
        snapTick = content.subscribe(to: SceneEvents.Update.self) { [weak self] _ in
            MainActor.assumeIsolated { self?.snapToFloor() }
        }
    }

    /// The real floor's world height, when the room has offered one —
    /// trusted only near the world origin's own level.
    private func floorY() -> Float? {
        guard let floorAnchor, floorAnchor.isAnchored else { return nil }
        let y = floorAnchor.position(relativeTo: nil).y
        return (-0.6...0.6).contains(y) ? y : nil
    }

    private func snapToFloor() {
        guard let entity, let y = floorY() else { return }
        let target = y + Self.height
        if abs(entity.position.y - target) > 0.005 {
            entity.position.y = target
        }
    }

    func update(history: SankeySpace.FloorHistory?,
                years: (newest: Int, oldest: Int)?,
                citedSpace: EPUBMapView.CitedSpace,
                shift: SIMD3<Float>) {
        entity?.removeFromParent()
        entity = nil
        guard let content, let history, !history.events.isEmpty,
              let years, years.newest > years.oldest else { return }

        // The image's height is the timeline: drawn near 1000pt per
        // metre so a year's row lands at its exact depth, capped so
        // the texture stays sane — beyond the cap the glyphs stretch
        // with the corridor rather than the texture growing.
        let faceHeight = min(max(CGFloat(citedSpace.depth) * 1000, 800), 3000)
        let face = FloorHistoryView(history: history,
                                    newest: years.newest, oldest: years.oldest)
            .frame(width: Self.faceWidth, height: faceHeight)
        let renderer = ImageRenderer(content: face)
        renderer.scale = 2
        renderer.isOpaque = false
        guard let image = renderer.uiImage,
              let plane = ModelEntity.texturedPlane(with: image, ratio: 0.001)
        else { return }

        plane.components.set(MapSpaceNodeComponent())
        // Laid flat, face up: the device showed this single turn reads
        // toward the walker facing into the corridor — the image's top
        // lands at the deep (oldest) end, which the drawing matches.
        plane.orientation = simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(1, 0, 0))
        let baseLength = Float(faceHeight) * 0.001
        let holder = ModelEntity()
        holder.components.set(MapSpaceNodeComponent())
        holder.addChild(plane)
        holder.scale = SIMD3<Float>(1, 1, citedSpace.depth / baseLength)
        // The fist carries the band sideways and along the corridor
        // only — its height is the floor's, never the carry's.
        holder.position = SIMD3<Float>(
            citedSpace.origin.x + shift.x,
            floorY().map { $0 + Self.height } ?? Self.height,
            citedSpace.origin.z - citedSpace.depth / 2 + shift.z)
        content.add(holder)
        entity = holder
    }
}

/// The floor's face: decade rules across the band, and one event line
/// per free year-slot — the widest-carried first, each at its year's
/// exact place on the timeline (the image's vertical axis), its words
/// horizontal. The image's top is the DEEP (oldest) end, matching the
/// flat plane's landing.
struct FloorHistoryView: View {
    let history: SankeySpace.FloorHistory
    let newest: Int
    let oldest: Int

    var body: some View {
        Canvas { context, size in
            let span = CGFloat(newest - oldest)
            guard span > 0 else { return }
            // Top of the image = the OLDEST year — the deep end, the
            // way the flat plane lands.
            func y(_ year: Int) -> CGFloat {
                size.height * CGFloat(year - oldest) / span
            }

            // Decade rules, on the corridor's very depths.
            let firstDecade = (oldest / 10 + 1) * 10
            for year in stride(from: firstDecade, through: newest, by: 10) {
                let rule = y(year)
                var line = Path()
                line.move(to: CGPoint(x: 0, y: rule))
                line.addLine(to: CGPoint(x: size.width, y: rule))
                context.stroke(line, with: .color(.white.opacity(0.18)), lineWidth: 1)
                context.draw(
                    Text(String(year)).font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55)),
                    at: CGPoint(x: size.width - 12, y: rule - 14),
                    anchor: .trailing)
            }

            // The events: most widely carried first; a year-row only
            // holds one line, and crowded years yield to bigger events.
            let lineHeight: CGFloat = 44
            var taken: [CGFloat] = []
            let ordered = history.events
                .filter { $0.year >= oldest && $0.year <= newest }
                .sorted { $0.links > $1.links }
            for event in ordered {
                let row = y(event.year)
                guard row > 20, row < size.height - 20,
                      !taken.contains(where: { abs($0 - row) < lineHeight }) else { continue }
                taken.append(row)
                let words = "\(event.year)  \(event.title)"
                // A quiet dark bed under the words, so they read on any
                // carpet.
                let text = Text(words)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                let resolved = context.resolve(text)
                let measured = resolved.measure(in: CGSize(width: size.width - 80,
                                                           height: lineHeight))
                let bed = CGRect(x: 28, y: row - measured.height / 2 - 5,
                                 width: measured.width + 24,
                                 height: measured.height + 10)
                context.fill(Path(roundedRect: bed, cornerRadius: 8),
                             with: .color(.black.opacity(0.38)))
                context.draw(resolved,
                             at: CGPoint(x: 40, y: row), anchor: .leading)
            }
        }
    }
}

/// How the time-spread's data draws — the reader's choice, kept in
/// "timeSpreadStyle" and offered in the Data window.
enum TimeSpreadStyle: String, CaseIterable, Identifiable {
    /// Width carries the value — the Sankey encoding.
    case sankey
    /// Position carries the value — the traditional line graph.
    case graph

    var id: String { rawValue }
    var displayName: String { self == .sankey ? "Sankey" : "Graph" }
}

/// Whether the data lines stand apart or on top of one another —
/// "timeSpreadLayout", offered in Time Data. Overlaid draws every
/// series in one shared field: same-unit series share their true
/// scale; mixed units each fill their own range, so the shapes
/// compare and the labels carry the numbers.
enum TimeSpreadLayout: String, CaseIterable, Identifiable {
    case lanes
    case overlaid

    var id: String { rawValue }
    var displayName: String { self == .lanes ? "Lanes" : "Overlaid" }
}

/// The Timeflows' shared ink: the palettes, each series' colour, and
/// the value normalization — one truth for the flat ribbons and the
/// graph's cylinders alike.
enum TimeSpreadInk {
    /// Frode's chosen graph colours (2026-08-25), darkened a step —
    /// slate, olive, sienna, ochre — extended (2026-08-25) with more
    /// of Tol's muted scheme, darkened the same step: the warm run
    /// reads max, the cool run min.
    static let maxColors: [Color] = [
        Color(red: 0.59, green: 0.46, blue: 0.22),   // ochre, darkened
        Color(red: 0.42, green: 0.27, blue: 0.20),   // sienna, darkened
        Color(red: 0.43, green: 0.10, blue: 0.27),   // wine, darkened
        Color(red: 0.64, green: 0.32, blue: 0.37),   // rose, darkened
        Color(red: 0.69, green: 0.64, blue: 0.37),   // sand, darkened
    ]
    static let minColors: [Color] = [
        Color(red: 0.29, green: 0.37, blue: 0.42),   // slate, darkened
        Color(red: 0.30, green: 0.34, blue: 0.21),   // olive, darkened
        Color(red: 0.21, green: 0.53, blue: 0.48),   // teal, darkened
        Color(red: 0.05, green: 0.37, blue: 0.16),   // green, darkened
        Color(red: 0.16, green: 0.11, blue: 0.43),   // indigo, darkened
    ]

    static func pairIndices(of dataset: SankeySpace.Dataset) -> [String: Int] {
        var indices: [String: Int] = [:]
        for series in dataset.series where indices[series.pair] == nil {
            indices[series.pair] = indices.count
        }
        return indices
    }

    static func color(of series: SankeySpace.Series,
                      pairIndices: [String: Int]) -> Color {
        // The reader's chosen ink first — picked on the Mac, carried
        // by the mirror — the palette by pair otherwise.
        if let hex = series.colorHex, let chosen = color(fromHex: hex) {
            return chosen
        }
        let palette = series.role == .max ? maxColors : minColors
        return palette[(pairIndices[series.pair] ?? 0) % palette.count]
    }

    /// "#RRGGBB" in, a colour out — nil for anything else.
    static func color(fromHex hex: String) -> Color? {
        let cleaned = hex.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "#", with: "")
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else { return nil }
        return Color(red: Double((value >> 16) & 0xFF) / 255,
                     green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255)
    }

    /// The value scale. Lanes share one absolute scale, so magnitudes
    /// compare across series. Overlaid same-unit series keep that
    /// shared truth; overlaid mixed units each fill their own range —
    /// the shapes compare, the key carries the numbers. Nil when the
    /// data is flat.
    static func normalizer(for dataset: SankeySpace.Dataset,
                           layout: TimeSpreadLayout)
        -> ((Double, SankeySpace.Series) -> CGFloat)? {
        let all = dataset.series.flatMap { $0.values.map(\.value) }
        guard let low = all.min(), let high = all.max(), high > low else { return nil }
        let mixedUnits = Set(dataset.series.map(\.unit)).count > 1
        return { value, series in
            if layout == .overlaid && mixedUnits {
                let own = series.values.map(\.value)
                guard let ownLow = own.min(), let ownHigh = own.max(),
                      ownHigh > ownLow else { return 0.5 }
                return CGFloat((value - ownLow) / (ownHigh - ownLow))
            }
            return CGFloat((value - low) / (high - low))
        }
    }
}

/// The graph's key, a card of its own standing in front of the plot:
/// every series' swatch, name, and latest value — one row each.
struct GraphKeyView: View {
    let dataset: SankeySpace.Dataset

    var body: some View {
        let pairIndex = TimeSpreadInk.pairIndices(of: dataset)
        VStack(alignment: .leading, spacing: 7) {
            ForEach(dataset.series) { series in
                HStack(spacing: 9) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(TimeSpreadInk.color(of: series, pairIndices: pairIndex))
                        .frame(width: 16, height: 10)
                    Text(label(for: series))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14).fill(.black.opacity(0.55)))
    }

    private func label(for series: SankeySpace.Series) -> String {
        guard let latest = series.values.max(by: { $0.year < $1.year }) else {
            return series.name
        }
        let words = series.role == .min || dataset.series.contains(where: {
            $0.pair == series.pair && $0.id != series.id
        })
            ? "\(series.name) \(series.role.rawValue) "
            : "\(series.name) "
        return words + String(format: "%.1f", latest.value) + " " + series.unit
    }
}

struct SankeyRibbonView: View {
    let dataset: SankeySpace.Dataset
    let newest: Int
    let oldest: Int
    /// The far side's drawing: the year axis runs the other way (so a
    /// year keeps its Z through the plane) while the words still read
    /// left to right.
    var mirrored = false
    var style: TimeSpreadStyle = .sankey
    var layout: TimeSpreadLayout = .lanes

    var body: some View {
        Canvas { context, size in
            let span = CGFloat(newest - oldest)
            guard span > 0 else { return }
            func x(_ year: Int) -> CGFloat {
                let toward = size.width * CGFloat(newest - year) / span
                return mirrored ? size.width - toward : toward
            }

            // The value scale and the colours — the shared ink, so the
            // cylinders and these ribbons can never disagree.
            guard let norm = TimeSpreadInk.normalizer(for: dataset, layout: layout)
            else { return }
            func halfWidth(_ value: Double, in series: SankeySpace.Series) -> CGFloat {
                3 + (layout == .overlaid ? 44 : 30) * norm(value, series)
            }
            let pairIndex = TimeSpreadInk.pairIndices(of: dataset)
            func seriesColor(_ series: SankeySpace.Series) -> Color {
                TimeSpreadInk.color(of: series, pairIndices: pairIndex)
            }

            // The key lives on its own card IN FRONT of the graph
            // (GraphKeyView) — the plot here carries only the data.
            let contentTop: CGFloat = 16

            // Decade ticks, on the corridor's very Zs.
            let firstDecade = (oldest / 10 + 1) * 10
            for year in stride(from: firstDecade, through: newest, by: 10) {
                let tick = x(year)
                var line = Path()
                line.move(to: CGPoint(x: tick, y: contentTop))
                line.addLine(to: CGPoint(x: tick, y: size.height - 16))
                context.stroke(line, with: .color(.white.opacity(0.25)), lineWidth: 1)
                context.draw(
                    Text(String(year)).font(.system(size: 9)).foregroundStyle(.white.opacity(0.7)),
                    at: CGPoint(x: tick, y: size.height - 8))
            }

            // The graph style's series are CYLINDERS in the room, not
            // ink on this plane — the face then carries only the key
            // and the ticks.
            guard style == .sankey else { return }

            let plotBottom = size.height - 40
            let lanes = dataset.series.count
            let laneHeight = (size.height - contentTop - 36) / CGFloat(max(lanes, 1))
            // Overlaid ribbons draw the widest first, so smaller ones
            // stay visible on top of them.
            let drawOrder: [(Int, SankeySpace.Series)]
            if layout == .overlaid {
                drawOrder = dataset.series.enumerated().sorted { left, right in
                    let mean = { (entry: SankeySpace.Series) -> CGFloat in
                        let widths = entry.values.map { norm($0.value, entry) }
                        return widths.reduce(0, +) / CGFloat(max(widths.count, 1))
                    }
                    return mean(left.element) > mean(right.element)
                }.map { ($0.offset, $0.element) }
            } else {
                drawOrder = Array(dataset.series.enumerated()).map { ($0.offset, $0.element) }
            }
            for (index, series) in drawOrder {
                let color = seriesColor(series)

                let points = series.values
                    .filter { $0.year >= oldest && $0.year <= newest }
                    .sorted { $0.year > $1.year }   // newest (left) first
                guard points.count >= 2 else { continue }

                // The ribbon: its own lane, or the shared middle when
                // overlaid.
                let center = layout == .overlaid
                    ? contentTop + (plotBottom - contentTop) / 2
                    : contentTop + laneHeight * (CGFloat(index) + 0.5)
                var ribbon = Path()
                ribbon.move(to: CGPoint(x: x(points[0].year),
                                        y: center - halfWidth(points[0].value, in: series)))
                for point in points.dropFirst() {
                    ribbon.addLine(to: CGPoint(x: x(point.year),
                                               y: center - halfWidth(point.value, in: series)))
                }
                for point in points.reversed() {
                    ribbon.addLine(to: CGPoint(x: x(point.year),
                                               y: center + halfWidth(point.value, in: series)))
                }
                ribbon.closeSubpath()
                context.fill(ribbon, with: .color(
                    color.opacity(layout == .overlaid ? 0.5 : 0.82)))
            }
        }
    }
}
#endif
