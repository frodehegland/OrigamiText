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
import ARKit
import QuartzCore
// A note's voice: the microphone's words, for SpatialNotePanel.
import Speech
import AVFoundation

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
    enum Kind { case article, cited, citedDeep, concept }

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
    /// How many raised articles cite this work — drives card depth.
    var citationCount: Int = 1
    /// The paper's abstract, printed very small on the card's FRONT
    /// face only — fine print the reader walks toward to read.
    var abstract: String = ""
    /// Stamped with the current visionTheme at build time so a theme
    /// switch makes all items visually unequal — forcing a full card rebuild.
    var visionTheme: String = ""
    /// The place-holder standing in for a snapped-off card: barely
    /// there, only the title's first line, immobile and untappable.
    var isGhost = false
    /// The card opened to its abstract — asked for with the selected
    /// card's Abstract button, not by selection itself.
    var showsAbstract = false
    /// Snapped off the map with Lift: the card reads as a slightly
    /// extruded object, apart from the flat wall.
    var isLifted = false

    var isAttachmentsEnabled: Bool {
        // Concepts carry Focus/Hide; documents and citations carry
        // Lift / Put Back. Ghosts carry nothing.
        isSelected && !isGhost
            && (kind == .concept || kind == .article
                || kind == .cited || kind == .citedDeep)
    }

    func isVisuallyEqual(to other: EPUBMapItem) -> Bool {
        // Selection is visual now — the selected card wears an ember
        // border — so a tap rebuilds the one card it touches (and the
        // one it left), never the room.
        id == other.id && title == other.title && author == other.author
            && kind == other.kind && isPinned == other.isPinned
            && isAside == other.isAside && isSelected == other.isSelected
            && isShared == other.isShared && citationCount == other.citationCount
            && abstract == other.abstract && visionTheme == other.visionTheme
            && isGhost == other.isGhost && showsAbstract == other.showsAbstract
            && isLifted == other.isLifted
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

    /// Lift, take two (15 Sep evening): the lifted card is billboarded
    /// and moves free — no surface pose fighting the hand — with the
    /// very transparent ghost holding its place. Off sends every
    /// lifted card home (reload() below).
    private static let liftEnabled = true

    /// A snapped-off card: the held home its ghost stands at, and the
    /// surface pose (a quaternion's vector) once it rests on a wall or
    /// desk — nil while it floats. Persisted, so a card left on the
    /// wall is still there tomorrow.
    struct LiftedCard: Codable {
        var home: SIMD3<Float>
        var stuck: SIMD4<Float>?
    }
    @State private var liftedCards: [String: LiftedCard] = EPUBMapView.loadLiftedCards()
    /// The cards opened to their abstracts by the Abstract button —
    /// selection alone shows the full title and authors now.
    @State private var abstractOpenIDs: Set<String> = []
    /// The desk the room offers as a landing surface, beside the wall.
    @State private var deskAnchor: AnchorEntity?

    private static let liftedCardsKey = "mapLiftedCards"

    private static func loadLiftedCards() -> [String: LiftedCard] {
        guard let data = UserDefaults.standard.data(forKey: liftedCardsKey),
              let cards = try? JSONDecoder().decode([String: LiftedCard].self, from: data)
        else { return [:] }
        return cards
    }

    private func saveLiftedCards() {
        guard let data = try? JSONEncoder().encode(liftedCards) else { return }
        UserDefaults.standard.set(data, forKey: Self.liftedCardsKey)
    }

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
    @State private var faceTurner = CardFaceTurner()
    /// The one per-frame card sweep feeding the turner and the lines.
    @State private var cardTick = MapCardTick()

    /// True while the topic magnets stand in the hallway — the same
    /// twelve the Mac's Map names for this venue, toggled from the
    /// arm's Topics chip. Selecting one threads to its articles.
    @State private var topicSpaceMode = false
    /// The named topics, kept against their inputs' hash — reload runs
    /// on every tap, and the greedy naming need not run with it.
    @State private var topicNamesCache: (key: Int, names: [String])?
    /// True while concept cards are shown in the hallway — concepts
    /// join the items array in front of the article wall.
    @State private var conceptSpaceMode = false

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
    @AppStorage("visionTheme") private var visionThemeRaw = VisionTheme.light.rawValue
    // Hidden means hidden: a set-aside card leaves the room entirely —
    // never a small slip low on the floor. The old floor row's stored
    // toggle ("mapShowsSetAside") is retired; the right arm's Set Aside
    // chip and the Mac's lists still bring a card back.
    @AppStorage("floorShow") private var floorShowRaw = FloorShow.world.rawValue
    /// The middle lane's timeline — centre of the corridor.
    @AppStorage("floorShowMiddle") private var floorShowMiddleRaw = FloorShow.nothing.rawValue
    /// The right lane's timeline — the right arm's Time Data sets it.
    @AppStorage("floorShowRight") private var floorShowRightRaw = FloorShow.nothing.rawValue

    /// The theme the floor returns to when its arm chip toggles it
    /// back on.
    @AppStorage("floorShowLast") private var floorShowLastRaw = FloorShow.world.rawValue
    /// What the middle and right lanes showed before Timelines was
    /// turned away, so all three come back as they stood.
    @AppStorage("floorShowMiddleLast") private var floorShowMiddleLastRaw = FloorShow.hypertext.rawValue
    @AppStorage("floorShowRightLast") private var floorShowRightLastRaw = FloorShow.computing.rawValue
    /// Whether the front EPUBs stand in the room — Show's Documents.
    /// The citation walls they raised are Citations' family, and keep
    /// standing without them.
    @AppStorage("mapDocumentsShown") private var documentsShown = true

    /// The floor's writing, laid flat on the real ground under the
    /// corridor, each event at its year's exact depth.
    /// Two timelines share the floor: one lane each side of the
    /// corridor's centre, each arm's Time Data choosing its own.
    @State private var floorBandLeft = FloorBand(sideOffset: -0.75)
    @State private var floorBandMiddle = FloorBand(sideOffset: 0)
    @State private var floorBandRight = FloorBand(sideOffset: 0.75)
    /// Decade rules across the floor, graph to graph.
    @State private var floorDecadeLines = FloorDecadeLines()

    /// Readers opened in-situ: the full reading standing where its
    /// card stood, dragged anywhere by its handle bar — free of the
    /// timeline; an open book is in the hand, not on the shelf.
    @State private var readerPanels = ReaderPanels()

    /// Faint purple lines from each open panel to the hallway cards it
    /// cites — visible in hallway mode, hidden on the Reading Desk.
    @State private var citationLines = CitationLineManager()
    /// Per-document colored lines to shared citations (3+ selected).
    @State private var selectedCitationLines = SelectedCitationLines()
    /// Blue lines from each concept card to the articles it was extracted from.
    @State private var conceptConnectionLines = ConceptConnectionLines()
    /// Amber lines from each selected citation card to the deep works it cites.
    @State private var citedToDeepLines = CitedToDeepLines()


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
    /// EXPERIMENT — journal cards hold their publication year's depth:
    /// each article's Z, newest nearest, oldest deepest, same convention
    /// as the cited works. Drags move a card freely on its year's plane
    /// but never off it. Remove this table (and its two uses) to return
    /// to free movement.
    @State private var articleYearZ: [String: Float] = [:]

    /// What the references told us about each citation beyond its face
    /// — the abstract and the DOI, for the double-tap card and its
    /// Acquire button.
    struct CitedFacts {
        var abstract: String?
        var doi: String?
    }
    @State private var citedFacts: [String: CitedFacts] = [:]

    /// Where the reader has placed each card — persisted to disk so
    /// positions survive app restarts.
    @State private var placed: [String: SIMD3<Float>] = EPUBMapLayoutStore.load()

    /// The last shared-layout write this room has adopted — the flat
    /// maps on the Mac and iPad key their X/Y by the book's
    /// community-file identity, overlaid here onto the room's own ids.
    @State private var sharedLayoutAdoptedAt: Date = .distantPast

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

    /// Align to Room's detected wall — read when the chip is tapped.
    @State private var roomWallAnchor: AnchorEntity?

    /// The chosen depth, kept across sessions.
    @AppStorage("citedSpaceDepth") private var citedDepthSetting = 1.0
    /// The pinch's final step: the spread pressed fully flat, every
    /// citation at the wall's own plane. Kept across sessions too.
    @AppStorage("citedSpaceFlat") private var citedSpaceFlat = false

    /// The open journal's records as nodes — arranged positions where
    /// the reader has made them, the grid for the rest — and, a level
    /// behind them, every work the articles cite. A citation that
    /// resolves to a fellow article in the journal connects to that
    /// card instead of raising a ghost. Articles open in a reader
    /// window stay off the Map until their window closes.
    /// Overlays the X and Y laid out on a Mac or iPad flat map onto this
    /// room's cards — matched by the book's community-file identity
    /// (EPUBRecord.folder), since internal ids differ between devices.
    /// Each card keeps its local Z; the year reclaims an article's depth
    /// regardless. Runs once per newer shared write.
    private func adoptSharedLayout(for records: [EPUBRecord]) {
        let state = EPUBMapSharedLayout.load(community: model.index.folderURL)
        guard state.modified > sharedLayoutAdoptedAt else { return }
        sharedLayoutAdoptedAt = state.modified
        for record in records {
            guard let point = state.positions[record.folder] else { continue }
            let z = placed[record.id]?.z ?? -1.2
            placed[record.id] = SIMD3<Float>(Float(point.x), Float(point.y), z)
        }
    }

    /// id → community-file identity, the shared layout's keys.
    private var sharedKeyByID: [String: String] {
        Dictionary(model.epubRecords.map { ($0.id, $0.folder) },
                   uniquingKeysWith: { first, _ in first })
    }

    private func journalItems(venue: String) -> [EPUBMapItem] {
        let records = model.records(inVenue: venue)
        adoptSharedLayout(for: records)
        // The floats travel in the same sidecars the highlights do.
        model.adoptFloats(for: records)
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
        // Each paper's own abstract, read from under its Abstract
        // heading — the fine print on the card's front face.
        var abstractByArticle: [String: String] = [:]
        for record in records {
            guard let doc = model.index.byID[record.id]?.doc else { continue }
            var collecting = false
            var abstractParts: [String] = []
            for paragraph in doc.body ?? [] {
                if paragraph.heading != nil {
                    if collecting { break }
                    collecting = paragraph.text
                        .trimmingCharacters(in: .whitespaces)
                        .lowercased() == "abstract"
                } else if collecting {
                    let text = paragraph.text
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    // The abstract ENDS at the paper's apparatus: an
                    // ACM paper prints CCS Concepts, its keywords and
                    // its reference format as plain paragraphs under
                    // the same heading, and a card that swept them in
                    // read as a form rather than an argument.
                    if Self.endsTheAbstract(text) { break }
                    if !text.isEmpty { abstractParts.append(text) }
                }
            }
            if !abstractParts.isEmpty {
                abstractByArticle[record.id] = abstractParts.joined(separator: "\n\n")
            }
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
        let standing = documentsShown
            ? model.pinnedFirstRecords(shown.filter { !model.setAsideIDs.contains($0.id) })
            : []
        let asides: [EPUBRecord] = []

        let columns = Self.wallColumns(standing.count)
        // The seeded rectangle IS the Wall: same columns, same 5 cm of
        // air, same height — so a room never touched and a room reset
        // stand alike, and only their order differs (pinned first here,
        // alphabetical there).
        let seedTop = Self.wallTop(rows: (standing.count + columns - 1)
            / max(columns, 1))
        // EXPERIMENT — the articles' own year scale: newest at the grid's
        // plane, each older year a step deeper. A single-year proceedings
        // stands flat as before, only held; a journal spanning years
        // spreads into time.
        func articleYear(_ record: EPUBRecord) -> Int? {
            record.dateISO.flatMap { Int($0.prefix(4)) }
        }
        let articleYears = standing.compactMap(articleYear)
        let newestArticleYear = articleYears.max()
        let articleSpan = max((newestArticleYear ?? 0) - (articleYears.min() ?? 0), 1)
        var yearZ: [String: Float] = [:]
        var result: [EPUBMapItem] = standing.enumerated().map { index, record in
            let column = index % columns
            let row = index / columns
            let agePlace: Float? = articleYear(record).flatMap { year in
                newestArticleYear.map { Float($0 - year) / Float(articleSpan) }
            }
            let depth: Float = -1.2 - (agePlace ?? 0) * min(1.2, Float(articleSpan) * 0.1)
            let seed = SIMD3<Float>(
                (Float(column) - Float(columns - 1) / 2) * Self.columnPitch,
                seedTop - Float(row) * Self.rowPitch,
                depth) + spaceShift
            yearZ[record.id] = seed.z
            // A card left elsewhere keeps its place on the plane — the
            // year reclaims only its depth. A lifted card escapes even
            // that: free in every axis until it is Put Back.
            var position = placed[record.id] ?? seed
            if liftedCards[record.id] == nil { position.z = seed.z }
            var item = EPUBMapItem(
                id: record.id,
                title: record.title,
                // The year on the face, so the alignment reads at a glance.
                author: articleYear(record).map { "\(record.author) · \($0)" }
                    ?? record.author,
                kind: .article,
                position: position,
                citedIDs: citedIDsByArticle[record.id] ?? [],
                isPinned: model.pinnedIDs.contains(record.id),
                abstract: abstractByArticle[record.id] ?? "")
            item.isLifted = liftedCards[record.id] != nil
            return item
        }
        articleYearZ = yearZ

        // The Set Aside row: title-only slips, half faded, resting ON
        // THE FLOOR — the room's quiet lowest shelf. A slip set aside
        // while standing high (chip or menu, not the floor drop) comes
        // down to the row; one already living low keeps its spot.
        let asideColumns = max(1, min(asides.count, 5))
        result.append(contentsOf: asides.enumerated().map { index, record in
            let column = index % asideColumns
            let row = index / asideColumns
            let seed = SIMD3<Float>(
                (Float(column) - Float(asideColumns - 1) / 2) * 0.24,
                0.15 + Float(row) * 0.07,
                -1.2) + spaceShift
            var position = placed[record.id] ?? seed
            if position.y > 0.85 { position = seed }
            return EPUBMapItem(
                id: record.id,
                title: record.title,
                author: record.author,
                kind: .article,
                position: position,
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
        // How many raised articles cite each paper — drives card depth.
        var citationCounts: [String: Int] = [:]
        for set in raisedSets {
            for id in set { citationCounts[id, default: 0] += 1 }
        }
        // The Only Overlap chip stands while common ground does; when
        // it is on, the wall narrows to the shared citations alone —
        // the green cards and their green lines, nothing else.
        sharedCitedStanding = !sharedIDs.isEmpty
        armMenu.setChipVisible(Self.onlyOverlapChipID,
                               showOpen && (!sharedIDs.isEmpty || onlyOverlap))
        // When 2+ articles are raised but share no common citations,
        // the wall goes quiet — nothing overlaps, so nothing to show.
        let noOverlap = raisedArticleIDs.count >= 2 && sharedIDs.isEmpty
        // A lifted citation stands regardless — snapped to its surface,
        // it must not vanish when its article's wall retires.
        let shownCited = citedWorks.filter { work in
            if liftedCards[work.id] != nil { return true }
            guard !noOverlap else { return false }
            return raisedIDs.contains(work.id)
                && (!onlyOverlap || sharedIDs.isEmpty || sharedIDs.contains(work.id))
        }
        let years = shownCited.compactMap(\.year)
        // The near plane is TODAY, not the newest cited work: this
        // year stands at the reader's plane and every citation lies
        // as deep as its age. Anchored to the calendar so the corridor
        // never re-anchors as selections change — the newest paper of
        // one wall would otherwise stand at the reader's nose and read
        // as now. Every companion (deep rank, Timeflow, floor bands,
        // decade lines) shares this range, so they all agree.
        let thisYear = Calendar.current.component(.year, from: Date())
        let newest = years.max().map { max($0, thisYear) }
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
            // A moved card keeps its place on the plane; the timeline
            // owns its depth — so a depth pinch re-spaces the years
            // without touching where the hand left anything.
            var position = placed[work.id] ?? seed
            if liftedCards[work.id] == nil { position.z = seed.z }
            var item = EPUBMapItem(
                id: work.id,
                title: work.title,
                // The year on the face, so the depth reads at a glance.
                author: work.year.map { "\(work.author) · \($0)" } ?? work.author,
                kind: .cited,
                position: position,
                isShared: sharedIDs.contains(work.id),
                citationCount: citationCounts[work.id] ?? 1,
                abstract: facts[work.id]?.abstract ?? "")
            item.isLifted = liftedCards[work.id] != nil
            return item
        })
        citedTimelineZ = timelineZ
        citedFacts = facts
        return result
    }

    /// Whether a paragraph standing under the Abstract heading is no
    /// longer the abstract but the paper's apparatus: its CCS
    /// concepts, its keywords, or its ACM Reference Format block.
    /// An ACM paper prints all three as paragraphs under that same
    /// heading, and a card is for the argument alone. The markers are
    /// read off the paragraph's opening, with any markdown emphasis
    /// the importers add stripped first.
    private static func endsTheAbstract(_ text: String) -> Bool {
        let opening = text
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "_", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let markers = ["ccs concepts", "ccs concept", "additional key words",
                       "additional keywords", "keywords", "key words",
                       "acm reference format", "reference format"]
        return markers.contains { opening.hasPrefix($0) }
    }

    /// The connection pool: every citation edge the Map could draw —
    /// the citedIDs plus the graph-read links of selected deep cards.
    private var connectionEdgeCount: Int {
        items.reduce(0) { $0 + $1.citedIDs.count }
            + deepLinks.values.reduce(0) { $0 + $1.inbound.count + $1.outbound.count }
    }

    private func reload() {
        // With Lift shelved, any card still lifted from an earlier run
        // comes home — nothing may stand stranded with no Put Back.
        if !Self.liftEnabled, !liftedCards.isEmpty {
            for (id, lifted) in liftedCards { placed[id] = lifted.home }
            liftedCards = [:]
            saveLiftedCards()
            savePlacedNow()
        }
        let selected = Set(items.filter(\.isSelected).map(\.id))
        if let venue = model.openJournalVenue {
            var built = journalItems(venue: venue)
            // Each lifted card's ghost: a transparent place-holder at
            // the held home, title's first line alone.
            built.append(contentsOf: ghostItems(among: built))
            for index in built.indices where selected.contains(built[index].id) {
                built[index].isSelected = true
                built[index].showsAbstract = abstractOpenIDs.contains(built[index].id)
                // A chosen card steps a centimetre toward the reader,
                // so its grown face and its opened abstract stand in
                // FRONT of the cards beside it rather than cutting
                // through them. Depth is reseeded from the year on
                // every sweep, so this never accumulates — except on a
                // lifted card, whose Z is its own and is kept, which
                // is why one is left where it stands.
                if !built[index].isGhost, liftedCards[built[index].id] == nil {
                    built[index].position?.z += Self.selectedStep
                }
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
        if conceptSpaceMode {
            // Concept cards keep their selection through the rebuild,
            // as the journal's cards do above.
            var concepts = buildConceptItems()
            for index in concepts.indices where selected.contains(concepts[index].id) {
                concepts[index].isSelected = true
            }
            items += concepts
        }
        // The floated passages: quotes lifted out of a reading with
        // Float — free of every year plane, billboarded, movable
        // anywhere by hand. They stand whatever else the room shows.
        items += model.floatingTexts.enumerated().map { index, float in
            let id = "float:" + float.id
            // The annotation's own place first — it travels with the
            // book — then this room's memory, then a fresh seed.
            let stored = float.position.map { $0 + spaceShift }
            let seed = SIMD3<Float>(
                -0.45 + 0.3 * Float(index % 4),
                1.35 + 0.12 * Float(index / 4),
                -0.9) + spaceShift
            var item = EPUBMapItem(
                id: id, title: float.text, author: "",
                kind: .concept, position: stored ?? placed[id] ?? seed)
            item.isSelected = selected.contains(id)
            item.visionTheme = visionThemeRaw
            return item
        }
        // The spatial notes: blank pads pulled off the wrist and
        // written in, each standing where it was dropped. They belong
        // to the journal, not to any book, and travel in the community
        // folder as JSON the Mac's flat map reads.
        spatialNotes = SpatialNotes.notes(venue: model.openJournalVenue ?? "",
                                          community: model.index.folderURL)
        items += spatialNotes.map { note in
            let id = Self.noteItemPrefix + note.id
            var item = EPUBMapItem(
                id: id, title: note.text, author: "", kind: .concept,
                position: SIMD3<Float>(Float(note.x), Float(note.y),
                                       Float(note.z)) + spaceShift)
            item.isSelected = selected.contains(id)
            item.visionTheme = visionThemeRaw
            return item
        }
        if topicSpaceMode {
            // Topic magnets hold their selection through the rebuild too,
            // so the threads stand while the room updates around them.
            var topics = buildTopicItems()
            for index in topics.indices where selected.contains(topics[index].id) {
                topics[index].isSelected = true
            }
            items += topics
        }
        // A Focus whose concept card no longer stands (hidden, filtered,
        // cut by the pool cap, or the concept row toggled away) would
        // trap the room — nothing left to tap to lift it. Self-heal.
        if let focused = focusedConceptID,
           !items.contains(where: { $0.id == focused }) {
            focusedConceptID = nil
            focusedConceptArticleIDs = []
        }
        // Stamp every item with the current theme so a theme switch makes
        // them visually unequal to their cached counterparts, triggering a
        // full card face rebuild rather than reusing stale light/dark textures.
        for i in items.indices { items[i].visionTheme = visionThemeRaw }
        updateSelectChips()
        rebuildDeepRank()
        updateSankey()
        // Suppress ALL connecting lines while any reading panel is open.
        let linesActive = model.openDocIDs.isEmpty
        citationLines.rebuild(
            docCitations: linesActive ? model.openDocCitations : [:],
            items: items,
            readerPanels: readerPanels,
            readingDeskDocID: model.readingDeskDocID)
        selectedCitationLines.rebuild(items: linesActive ? items : [])
        conceptConnectionLines.rebuild(items: linesActive ? items : [],
                                       edges: linesActive ? conceptEdges() : [])
        citedToDeepLines.rebuild(items: linesActive ? items : [])
    }

    /// Concept cards: a row of tiles in front of the article wall.
    /// Positioned at z = -0.85 (closer to viewer than articles at z = -1.2)
    /// using the same spaceShift so they move with the fist carry.
    private func buildConceptItems() -> [EPUBMapItem] {
        // The same concepts macOS shows: the reader's tracked list
        // (adopted through the standing file) leads, then the merged
        // set — every document's glossary entries plus the AI paper
        // topics — most shared first, capped so the hallway's rows stay
        // readable. (The AI set alone left the room empty whenever no
        // analysis had ever been run.)
        var pool: [MergedConcept] = []
        var seen = Set<String>()
        for name in model.concepts where !name.isEmpty {
            let key = MergedConcept.key(for: name)
            guard seen.insert(key).inserted else { continue }
            pool.append(MergedConcept(
                id: key, name: name, aiDescription: "",
                userDefinition: nil, category: "Tracked",
                citationIdentifiers: [], urls: [],
                sourceDocIDs: [], relatedConceptIDs: []))
        }
        let merged = model.allMergedConcepts
            .sorted { $0.sourceDocIDs.count > $1.sourceDocIDs.count }
            .prefix(60)
        for concept in merged {
            // Author's node pool carries heading and citation nodes so
            // layouts can reference them — a paper's own title arrives
            // tagged "heading". Those are documents, not concepts; the
            // Map's concept row keeps them out.
            let tag = concept.category?.lowercased() ?? ""
            guard tag != "heading", tag != "citation" else { continue }
            guard seen.insert(concept.id).inserted else { continue }
            pool.append(concept)
        }
        // A hidden concept stays away until Reveal All Concepts
        // (long-pinch the Concepts chip) brings the set back.
        let concepts = pool.filter {
            !hiddenConceptIDs.contains("concept:" + $0.id)
        }
        guard !concepts.isEmpty else { return [] }
        let cols = 8
        let spacingX: Float = 0.28
        let spacingY: Float = 0.20
        let totalW = Float(min(concepts.count, cols) - 1) * spacingX
        let startX = -totalW / 2
        let startY: Float = 1.75
        let conceptZ: Float = -0.85
        return concepts.enumerated().map { i, concept in
            let col = i % cols
            let row = i / cols
            let conceptID = "concept:" + concept.id
            let seed = SIMD3<Float>(
                startX + Float(col) * spacingX,
                startY - Float(row) * spacingY,
                conceptZ) + spaceShift
            return EPUBMapItem(
                id: conceptID,
                title: concept.name,
                author: concept.aiDescription,
                kind: .concept,
                position: placed[conceptID] ?? seed)
        }
    }

    /// The Mac Map's topic magnets, standing in the hallway: the same
    /// twelve labels the Mac names for this venue — the AI's paper
    /// topics and the titles, greedily covering the standing articles —
    /// in a row above the article wall. Selecting one threads down to
    /// every article it speaks for, as the Mac's bar does.
    private func buildTopicItems() -> [EPUBMapItem] {
        guard let venue = model.openJournalVenue else { return [] }
        let standing = topicStandingArticles(venue: venue)
        guard !standing.isEmpty else { return [] }
        // The reader's kept names on this device take their slots first,
        // through the same key the Mac's bar keeps its edits under.
        let kept = UserDefaults.standard.stringArray(forKey: "mapMagnets:\(venue)") ?? []
        var hasher = Hasher()
        hasher.combine(venue)
        hasher.combine(kept)
        for paper in standing {
            hasher.combine(paper.id)
            hasher.combine(paper.title)
            hasher.combine(paper.topics)
        }
        let key = hasher.finalize()
        let names: [String]
        if let cache = topicNamesCache, cache.key == key {
            names = cache.names
        } else {
            names = MapTopics.names(standing: standing, kept: kept)
            topicNamesCache = (key, names)
        }
        guard !names.isEmpty else { return [] }
        let spacingX: Float = 0.30
        let totalW = Float(names.count - 1) * spacingX
        // Above the article wall's top row, a touch before its plane.
        let topicY: Float = 2.05
        let topicZ: Float = -1.15
        return names.enumerated().map { i, name in
            let topicID = "topic:" + name.lowercased()
            let seed = SIMD3<Float>(
                -totalW / 2 + Float(i) * spacingX,
                topicY,
                topicZ) + spaceShift
            return EPUBMapItem(
                id: topicID,
                title: name,
                author: "",
                kind: .concept,
                position: placed[topicID] ?? seed)
        }
    }

    /// The venue's standing papers as the topic engine reads them —
    /// the AI topics the Mac's Analyse wrote to the shared analyses
    /// file (the headset reads, never writes), the titles carrying
    /// papers the AI hasn't reached yet.
    private func topicStandingArticles(venue: String) -> [MapTopics.Paper] {
        model.records(inVenue: venue)
            .filter { !model.setAsideIDs.contains($0.id) }
            .map { record in
                (record.id, record.title, model.allPaperTopics[record.id] ?? [])
            }
    }

    /// The Timeflows follow the corridor: rebuilt whenever the raised
    /// walls' year span, the pinch depth, the carried space, the data,
    /// or the chips change. With no wall raised they stand on the
    /// data's own year span — never hidden by a mere deselection; only
    /// their chips put them away.
    private func updateSankey() {
        // The Reading Desk and Concept Space empty the room: no Timeflows, no floor.
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
        // The floor's two lanes: each arm's Time Data chooses its own
        // timeline — a built-in theme, or one of the user's (raw
        // "user:<slug>", curated on the Mac).
        // Floor and decade lines only appear when citations are visible.
        let hasCitations = items.contains(where: { $0.kind == .cited || $0.kind == .citedDeep })
        let leftHistory = resolvedFloorHistory(floorShowRaw, desk: desk,
                                               fallback: .world)
        let middleHistory = resolvedFloorHistory(floorShowMiddleRaw, desk: desk,
                                                 fallback: .nothing)
        let rightHistory = resolvedFloorHistory(floorShowRightRaw, desk: desk,
                                                fallback: .nothing)
        floorBandLeft.update(history: (desk || !hasCitations) ? nil : leftHistory,
                             years: span ?? historyYearSpan(of: leftHistory),
                             citedSpace: citedSpace,
                             shift: spaceShift)
        floorBandMiddle.update(history: (desk || !hasCitations) ? nil : middleHistory,
                               years: span ?? historyYearSpan(of: middleHistory),
                               citedSpace: citedSpace,
                               shift: spaceShift)
        floorBandRight.update(history: (desk || !hasCitations) ? nil : rightHistory,
                              years: span ?? historyYearSpan(of: rightHistory),
                              citedSpace: citedSpace,
                              shift: spaceShift)
        // The decade rules tie graphs and floor lanes to one calendar.
        floorDecadeLines.update(
            years: (desk || !hasCitations) ? nil : (span ?? historyYearSpan(of: leftHistory)
                                                     ?? historyYearSpan(of: rightHistory)),
            citedSpace: citedSpace,
            shift: spaceShift)
    }

    /// One lane's choice resolved to its events — asking the model to
    /// fetch a missing built-in theme along the way.
    private func resolvedFloorHistory(_ raw: String, desk: Bool,
                                      fallback: FloorShow)
        -> SankeySpace.FloorHistory? {
        if raw.hasPrefix("user:") {
            return model.userFloorHistory(slug: String(raw.dropFirst("user:".count)))
        }
        let show = FloorShow(rawValue: raw) ?? fallback
        if let theme = show.theme, !desk {
            model.ensureFloorTheme(theme)
        }
        return show.theme.flatMap { model.floorHistory(for: $0) }
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
            case .concept: return nil
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

    /// The arm menu, Author's component: the room's shape rides the
    /// right forearm, the choosing rides the left. Nothing of the Map's
    /// own is in the air any more — the toolbar is gone, and both arms
    /// carry what it held.
    @State private var armMenu = ArmMenu(chips: [
        // Over the right forearm, the room's shape: Layout unfolds
        // Author's whole align-and-sort house, Gather draws the spread
        // in, and the three view verbs keep, recall and undo an
        // arrangement whole.
        // Layout left the arm on 17 Sep 2026: a chosen node carries it
        // now, where it acts on what is in hand. Its ladder is not
        // built at all, so no rung can strand at the wrist — the code
        // and the chip ids stand ready for the day it returns.
        ArmMenu.Chip(id: EPUBMapView.gatherChipID, title: "Gather", side: .right),
        ArmMenu.Chip(id: EPUBMapView.watchSavedChipID, title: "Saved View", side: .right),
        ArmMenu.Chip(id: EPUBMapView.watchSaveNowChipID, title: "Save View", side: .right),
        ArmMenu.Chip(id: EPUBMapView.watchUndoChipID, title: "Undo View", side: .right),
        // Beneath the right forearm, the room's own doors: the library,
        // the settings, and the book that explains the place.
        ArmMenu.Chip(id: EPUBMapView.documentsChipID, title: "Documents", side: .right,
                     underside: true),
        ArmMenu.Chip(id: EPUBMapView.settingsChipID, title: "Settings", side: .right,
                     underside: true),
        ArmMenu.Chip(id: EPUBMapView.introChipID, title: "Introduction", side: .right,
                     underside: true),
        // Graphs and Timelines are families of the room like any other,
        // so they stand inside Show rather than under the arm — and
        // each is one command: both walls, or all three lanes. Choosing
        // a single wall or lane is not a thing the arm offers.
        //
        // Beneath the left forearm, one verb: Focus keeps the selection
        // and its connections and clears the rest. Pin and Set Aside
        // have left the arm (17 Sep 2026) — they act on ONE card, and
        // a chosen card now carries them as its own buttons.
        ArmMenu.Chip(id: EPUBMapView.focusChipID, title: "Focus", side: .left,
                     underside: true),
        // The note pad worn at the left wrist — a blank pad pulled off
        // into the room as a standing note — is OUT for the demo
        // (17 Sep 2026): pulling a pad off unsettled the arm. Merely
        // hiding it was not enough, because a declared watch pushes
        // the whole word row 10 cm up the arm to clear a watch case
        // that no longer stands. So the chip is not declared at all;
        // its id, its pinch routing, ArmWatchView and SpatialNotes all
        // stand ready for the day it returns, tweaked.
        // The left arm's working row, from the wrist toward the elbow:
        //     Show [A] Select [D]
        // Each word unfolds its own list away from the arm, and the
        // bare letter beside it does that word for everything: A brings
        // every family into the room, D lets every selection go.
        ArmMenu.Chip(id: EPUBMapView.showChipID, title: "Show", side: .left),
        ArmMenu.Chip(id: EPUBMapView.showAllChipID, title: "A", side: .left),
        ArmMenu.Chip(id: EPUBMapView.selectChipID, title: "Select", side: .left),
        ArmMenu.Chip(id: EPUBMapView.deselectAllChipID, title: "D", side: .left),
        ArmMenu.Chip(id: EPUBMapView.selectCitationsChipID, title: "Citations",
                     side: .left, group: EPUBMapView.selectChipID),
        ArmMenu.Chip(id: EPUBMapView.selectDocumentsChipID, title: "Documents",
                     side: .left, group: EPUBMapView.selectChipID),
        ArmMenu.Chip(id: EPUBMapView.selectTopicsChipID, title: "Topics",
                     side: .left, group: EPUBMapView.selectChipID),
        ArmMenu.Chip(id: EPUBMapView.selectConceptsChipID, title: "Concepts",
                     side: .left, group: EPUBMapView.selectChipID),
        // Show's families: the front EPUBs, the citation walls, the
        // topic magnets, the floor's timelines, the graph walls, the
        // concept row — each one command in one place.
        ArmMenu.Chip(id: EPUBMapView.showCitationsChipID, title: "Citations",
                     side: .left, group: EPUBMapView.showChipID),
        ArmMenu.Chip(id: EPUBMapView.showDocumentsChipID, title: "Documents",
                     side: .left, group: EPUBMapView.showChipID),
        ArmMenu.Chip(id: EPUBMapView.topicsChipID, title: "Topics",
                     side: .left, group: EPUBMapView.showChipID),
        ArmMenu.Chip(id: EPUBMapView.timelinesChipID, title: "Timelines",
                     side: .left, group: EPUBMapView.showChipID),
        ArmMenu.Chip(id: EPUBMapView.graphsChipID, title: "Graphs",
                     side: .left, group: EPUBMapView.showChipID),
        ArmMenu.Chip(id: EPUBMapView.conceptsChipID, title: "Concepts",
                     side: .left, group: EPUBMapView.showChipID),
        ArmMenu.Chip(id: EPUBMapView.revealConceptsChipID, title: "Reveal All Concepts",
                     side: .left, group: EPUBMapView.conceptsChipID),
        // Only Overlap is a narrowing of what stands, so it belongs to
        // Show — and it only steps out while common ground does.
        ArmMenu.Chip(id: EPUBMapView.onlyOverlapChipID, title: "Only Overlap",
                     side: .left, group: EPUBMapView.showChipID),
        // The graphs' data moved off the arms: it lives in Settings'
        // Graph Data tab now.
    ] + EPUBMapView.savedViewChips,
       tracksPlanes: true,   // the flat pose finds the actual desk
       inverted: UserDefaults.standard.bool(forKey: "armMenuInverted"))

    /// The Settings' Swap Arms toggle — every chip on the opposite
    /// forearm. Read here as well so a change flips the menu live.
    @AppStorage("armMenuInverted") private var armMenuInverted = false

    /// Only Overlap: the cited wall narrowed to the shared citations.
    @State private var onlyOverlap = false
    /// Whether any shared citation stands — the chip's reason to show.
    @State private var sharedCitedStanding = false
    /// Focus: show only selected items and their direct connections.
    @State private var focusMode = false
    /// The Select chip's kinds, unfolded above it.
    @State private var selectOpen = false
    /// The Show chip's families, unfolded above it.
    @State private var showOpen = false
    /// The right arm's two fans: Layout's options and Saved View's
    /// slots. One at a time, or two long rows would ride the same
    /// forearm. Auto is a menu inside Layout's, so it opens only
    /// while Layout stands open.
    @State private var watchLayoutOpen = false
    @State private var openLayoutFan: LayoutFan?
    @State private var watchSavedOpen = false
    /// The saved arrangements, five slots per venue — positions in
    /// map space (the carried shift removed), persisted.
    @State private var savedViews: [String: [String: SIMD3<Float>]] = [:]
    /// Where every card stood the moment a Layout or Views option was
    /// chosen — the watch's Undo restores it whole.
    @State private var watchUndo: [String: SIMD3<Float>]?
    /// The card whose Layout options stand unfolded beneath it, while
    /// several papers are chosen. One at a time.
    @State private var layoutRowCardID: String?
    /// The spatial notes standing in this journal's room, as the
    /// community file holds them.
    @State private var spatialNotes: [SpatialNotes.Note] = []
    /// Concepts put away with their card's Hide button — back via the
    /// Concepts chip's long-pinch and Reveal All Concepts.
    @State private var hiddenConceptIDs: Set<String> = []
    /// A concept's own Focus: only that concept and the articles it
    /// touches stand. Cleared when the concept is deselected.
    @State private var focusedConceptID: String?
    /// The focused concept's articles, resolved once at the tap.
    @State private var focusedConceptArticleIDs: Set<String> = []

    private static let settingsChipID = "map.arm.settings"
    private static let documentsChipID = "map.arm.documents"
    private static let alignChipID = "map.arm.align"
    private static let pinChipID = "map.arm.pin"
    private static let setAsideChipID = "map.arm.setaside"
    private static let conceptsChipID = "map.arm.concepts"
    private static let topicsChipID = "map.arm.topics"
    private static let showChipID = "map.arm.show"
    private static let showCitationsChipID = "map.arm.show.citations"
    private static let revealConceptsChipID = "map.arm.concepts.reveal"
    private static let graphsChipID = "map.arm.graphs"
    private static let timelinesChipID = "map.arm.timelines"
    private static let onlyOverlapChipID = "map.arm.onlyoverlap"
    private static let focusChipID = "map.arm.focus"
    private static let selectChipID = "map.arm.select"
    private static let selectCitationsChipID = "map.arm.select.citations"
    /// The toolbar's two bare letters: D lets every selection go, A
    /// brings every family into the room.
    private static let deselectAllChipID = "map.arm.deselect.all"
    private static let showAllChipID = "map.arm.show.all"
    private static let selectTopicsChipID = "map.arm.select.topics"
    private static let showDocumentsChipID = "map.arm.show.documents"
    private static let selectDocumentsChipID = "map.arm.select.documents"
    private static let selectConceptsChipID = "map.arm.select.concepts"
    private static let watchLayoutChipID = "map.arm.watch.layout"
    private static let watchUndoChipID = "map.arm.watch.undo"
    private static let watchSavedChipID = "map.arm.watch.saved"
    private static let watchSaveNowChipID = "map.arm.watch.saved.save"
    private static let gatherChipID = "map.arm.gather"
    private static let notePadChipID = "map.arm.notepad"
    private static let introChipID = "map.arm.intro"
    private static let savedSlotCount = 5
    private static func savedViewSlotID(_ slot: Int) -> String {
        "map.arm.watch.saved.slot\(slot)"
    }

    /// Author Map's Layout options as chips, climbing away from the
    /// right forearm as one ladder from the folded Layout chip — the
    /// shape Interatlas's level rungs take. Auto stands at the top of
    /// the ladder and unfolds the whole-wall arrangements along the
    /// arm, a menu inside a menu.
    private static var layoutOptionChips: [ArmMenu.Chip] {
        // The ladder: four words climbing away from the arm.
        LayoutFan.allCases.map {
            ArmMenu.Chip(id: $0.chipID, title: $0.title,
                         side: .right, group: watchLayoutChipID)
        }
        // Each family's own commands, fanning along the arm from its
        // rung — a menu inside a menu inside the row.
        + WatchLayoutOption.allCases.map {
            ArmMenu.Chip(id: watchLayoutOptionID($0), title: $0.title,
                         side: .right, group: $0.family.chipID)
        }
        + offeredWatchViews.map {
            ArmMenu.Chip(id: watchViewOptionID($0), title: $0.title,
                         side: .right, group: LayoutFan.auto.chipID)
        }
    }

    /// The five saved slots, standing under Saved View — each one shows
    /// only once something has been kept in it.
    private static var savedViewChips: [ArmMenu.Chip] {
        (1...savedSlotCount).map {
            ArmMenu.Chip(id: savedViewSlotID($0), title: "View \($0)",
                         side: .right, group: watchSavedChipID)
        }
    }

    /// The four rungs of Layout's ladder, each unfolding its own fan
    /// along the arm. Three are ways of arranging the chosen cards by
    /// hand; Auto is the whole wall re-made.
    private enum LayoutFan: String, CaseIterable {
        case align, distribute, sort, auto

        var title: String {
            switch self {
            case .align: "Align"
            case .distribute: "Distribute"
            case .sort: "Sort"
            case .auto: "Auto"
            }
        }

        var chipID: String { "map.arm.layout." + rawValue }
    }

    /// Author Map's Layout commands, in three families — the cards
    /// chosen, or every standing card when none are.
    ///
    /// Two departures from Author, agreed 17 Sep 2026. Author's
    /// "Horizontal" is the vertical CENTRE align, which beside "Sort
    /// Horizontal" read as its opposite: it is Middle here, Center's
    /// counterpart. And Across is new — an even spread left to right
    /// in the order the cards already stand, which Author has no
    /// command for (its horizontal spreads all sort first).
    private enum WatchLayoutOption: String, CaseIterable {
        case left, center, right, middle
        case down, across
        case sortVertical, sortVerticalReverse
        case sortHorizontal, sortHorizontalReverse
        case time, timeReverse

        var title: String {
            switch self {
            case .left: "Left"
            case .center: "Center"
            case .right: "Right"
            case .middle: "Middle"
            case .down: "Down"
            case .across: "Across"
            // A sort names its key and its direction, and nothing
            // else: which way the cards run follows from the word.
            case .sortVertical: "A–Z Down"
            case .sortVerticalReverse: "Z–A Down"
            case .sortHorizontal: "A–Z Across"
            case .sortHorizontalReverse: "Z–A Across"
            case .time: "Oldest First"
            case .timeReverse: "Newest First"
            }
        }

        var family: LayoutFan {
            switch self {
            case .left, .center, .right, .middle: .align
            case .down, .across: .distribute
            case .sortVertical, .sortVerticalReverse, .sortHorizontal,
                 .sortHorizontalReverse, .time, .timeReverse: .sort
            }
        }
    }

    /// Author Map's Views menu — the whole wall re-arranged. Wall
    /// leads: it is the arrangement the room begins in, and the one to
    /// come back to.
    private enum WatchViewOption: String, CaseIterable {
        case wall
        case magneticCenter, islands, spine, orbits, timeline, neighborhoods

        var title: String {
            switch self {
            case .wall: "Wall"
            case .magneticCenter: "Magnetic Center"
            case .islands: "Islands"
            case .spine: "Spine"
            case .orbits: "Orbits"
            case .timeline: "Timeline"
            case .neighborhoods: "Neighborhoods"
            }
        }
    }

    // MARK: - The automatic arrangements' one measure

    /// How far a chosen card steps toward the reader — 1 cm, enough
    /// that a grown face and an open abstract pass in front of their
    /// neighbours instead of clipping into them.
    private static let selectedStep: Float = 0.01

    /// The air between two cards in every automatic arrangement: 5 cm
    /// (Frode's measure, 17 Sep 2026). Every spacing below is this gap
    /// plus the card it has to clear — no arrangement keeps a figure
    /// of its own any more.
    private static let autoGap: Float = 0.05
    /// A card's own size in metres. An article's face carries at most
    /// 100 points of text (`nodeMaxWidth`) with 8 points of padding a
    /// side, and the engine's raster measures 1000 points to the
    /// metre; its height is a wrapped title, a byline, and 6 points of
    /// padding above and below. A SELECTED card grows past this — it
    /// opens its full title and every author — so a chosen card leans
    /// over its neighbours, by design.
    private static let cardSize = SIMD2<Float>(0.116, 0.045)
    /// Card to card: left to right, and top to bottom.
    private static let columnPitch = cardSize.x + autoGap
    private static let rowPitch = cardSize.y + autoGap
    /// Rings and ellipses are squashed to the card's own proportion,
    /// so a step outward is a row's step down.
    private static let pitchAspect = rowPitch / columnPitch
    /// A ring wide enough that its `count` cards keep the gap between
    /// them — and never narrower than a single card's pitch.
    private static func ringRadius(_ count: Int) -> Float {
        max(columnPitch, Float(count) * columnPitch / (2 * .pi))
    }

    /// How many cards stand across the wall. Wider than tall, because
    /// the room gives a reader a whole wall's breadth and only the
    /// band from the chest to above the head. The seeded room and the
    /// Wall arrangement share this one rule, so a room never touched
    /// and a room reset stand the same.
    private static func wallColumns(_ count: Int) -> Int {
        max(1, Int((Double(count) * 7).squareRoot() / 2))
    }

    /// The wall's top row: 1.55 m, chest-to-brow, so the papers hang
    /// BENEATH the citation wall's band (whose rows run 1.39…1.95) and
    /// a raised wall is never hidden behind the papers that raised it.
    /// Centring the rectangle on eye height instead — as it did for a
    /// few hours on 17 Sep 2026 — put its top at 1.785 for a 61-paper
    /// journal and swallowed the citations whole.
    ///
    /// A journal with more rows than that band can hold still lowers
    /// its top no further than the floor of a card's reach (0.95), and
    /// nothing stands above 2.15.
    private static func wallTop(rows: Int) -> Float {
        let span = Float(max(rows - 1, 0)) * rowPitch
        return min(2.15, max(1.55, 0.95 + span))
    }

    private static func watchLayoutOptionID(_ option: WatchLayoutOption) -> String {
        "map.arm.watch.layout." + option.rawValue
    }

    private static func watchViewOptionID(_ option: WatchViewOption) -> String {
        LayoutFan.auto.chipID + "." + option.rawValue
    }

    /// The Views on offer — Timeline rests for now (the corridor's own
    /// depth already carries time). These are Auto's arrangements, at
    /// the top of Layout's ladder.
    private static let offeredWatchViews: [WatchViewOption] =
        WatchViewOption.allCases.filter { $0 != .timeline }


    var body: some View {
        engine
            // SwiftUI modifiers close the chain — the engine's fluent
            // modifiers inside `engine` return the engine view and must
            // run first.
            .onChange(of: model.openJournalVenue) {
                reload()
            }
            .onChange(of: armMenuInverted) {
                armMenu.setInverted(armMenuInverted)
            }
            .onChange(of: model.openDocIDs) {
                reload()
            }
            // A passage floated (or put away) from a reading panel.
            .onChange(of: model.floatingTexts) {
                reload()
            }
            .onChange(of: model.openDocCitations) {
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
            // The flat maps' beat, here in the room: while the space is
            // up, adopt the shared standing and layout every few
            // seconds, so a pin or a moved card on the Mac or iPad
            // arrives live. The onChanges above answer the standing;
            // a newer layout asks for the reload itself (journalItems
            // adopts the shared X/Y as it rebuilds).
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(4))
                    model.adoptStanding()
                    let folder = model.index.folderURL
                    let shared = await Task.detached(priority: .utility) {
                        EPUBMapSharedLayout.load(community: folder)
                    }.value
                    if shared.modified > sharedLayoutAdoptedAt {
                        reload()
                    }
                }
            }
            .onChange(of: visionThemeRaw) {
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
                citationLines.updatePositions(
                    docCitations: model.openDocCitations,
                    items: items,
                    readerPanels: readerPanels)
            }
            .onChange(of: model.readingDeskDocID) {
                // In or out of the Reading Desk: the panels sweep, the
                // ladder folds, and the reload re-evaluates every
                // card's standing through the engine's enable hook.
                readerPanels.hideAll(except: model.readingDeskDocID)
                if model.readingDeskDocID != nil {
                    conceptLadder.close()
                    if conceptSpaceMode {
                        conceptSpaceMode = false
                        updateSankey()
                    }
                }
                reload()
            }
            .onAppear {
                citedSpace.depth = min(
                    max(Float(citedDepthSetting), CitedSpace.depthRange.lowerBound),
                    CitedSpace.depthRange.upperBound)
                citedSpace.zMapping = citedSpaceFlat ? .flat : .date
                reload()
            }
            // The in-situ readers' handles: their own drag, beside the
            // engine's node drag — a panel goes anywhere, all three
            // axes, no timeline hold.
            .simultaneousGesture(
                DragGesture(coordinateSpace: .global)
                    .targetedToAnyEntity()
                    .onChanged { value in
                        if let (docID, root) = readerPanels.panel(for: value.entity) {
                            let start = readerPanels.dragStart[docID] ?? root.position
                            readerPanels.dragStart[docID] = start
                            root.position = start + value.convert(
                                value.gestureValue.translation3D, from: .local, to: .scene)
                        }
                    }
                    .onEnded { value in
                        readerPanels.dragStart = [:]
                        // A pad pulled off the wrist: where the hand
                        // let go, a note stands. A pinch that barely
                        // moved is a tap, and leaves the pad alone —
                        // 6 cm is a deliberate pull.
                        if armMenu.chipID(for: value.entity) == Self.notePadChipID {
                            let travel = value.convert(
                                value.gestureValue.translation3D,
                                from: .local, to: .scene)
                            guard simd_length(travel) > 0.06 else { return }
                            makeNote(at: value.entity.position(relativeTo: nil)
                                     + travel)
                        }
                    })
            // A long-pinch on the Concepts chip offers the way back for
            // hidden concepts: the Reveal All Concepts chip steps out
            // beside it.
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.6)
                    .targetedToAnyEntity()
                    .onEnded { value in
                        if armMenu.chipID(for: value.entity) == Self.conceptsChipID {
                            armMenu.setChipVisible(Self.revealConceptsChipID, true)
                        }
                    })
    }

    /// Everything the diagrams read, folded to one comparable value —
    /// any of it changing re-lays the Timeflows and the floor.
    private var sankeySettingsTick: String {
        [model.sankey?.modified.description ?? "",
         timeSpreadStyleRaw, timeSpreadLayoutRaw, floorShowRaw, floorShowMiddleRaw, floorShowRightRaw,
         graphSnapWallLeft.description, graphSnapWallRight.description]
            .joined(separator: "|")
    }

    /// One pinch, one step: deeper stretches the spread into the room
    /// (the rows squeezing toward walking height so the reader can walk
    /// the timeline); shallower gathers it back toward the wall — and
    /// one step past the shallowest presses it fully flat, every
    /// citation at the wall's own plane.
    private func stepCitedDepth(deeper: Bool) {
        if citedSpace.zMapping == .flat {
            // Flat is the floor of the staircase: deeper steps back
            // into the shallow corridor; shallower has nowhere to go.
            guard deeper else { return }
            citedSpace.zMapping = .date
            citedSpaceFlat = false
        } else if !deeper,
                  citedSpace.depth <= CitedSpace.depthRange.lowerBound + 0.001 {
            citedSpace.zMapping = .flat
            citedSpaceFlat = true
        } else {
            let next = citedSpace.depth
                * (deeper ? CitedSpace.depthStep : 1 / CitedSpace.depthStep)
            citedSpace.depth = min(
                max(next, CitedSpace.depthRange.lowerBound),
                CitedSpace.depthRange.upperBound)
            citedDepthSetting = Double(citedSpace.depth)
        }
        // The pinch re-spaces the years alone: every card keeps its
        // hand-given place on the plane, and the timeline re-maps
        // each one's depth in the rebuild.
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
            constructorAttachment: { _, item -> AnyView in
                // A floated passage: one verb, and it does not come
                // back — the annotation leaves the sidecar with the card.
                if item.id.hasPrefix("float:") {
                    guard item.isSelected else { return AnyView(EmptyView()) }
                    return AnyView(
                        Button("Delete") { model.removeFloat(item.id) }
                            .buttonStyle(.bordered)
                            .scaleEffect(0.5, anchor: .top)
                    )
                }
                // A note's own two verbs: the words, and the end of
                // them. Write is what the double tap does.
                if item.id.hasPrefix(EPUBMapView.noteItemPrefix), item.isSelected {
                    guard let note = note(for: item.id) else {
                        return AnyView(EmptyView())
                    }
                    return AnyView(
                        HStack(spacing: 8) {
                            Button("Write") { openNoteEditor(note) }
                            Button("Delete") {
                                SpatialNotes.delete(note,
                                                    community: model.index.folderURL)
                                spatialNotes.removeAll { $0.id == note.id }
                                reload()
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .font(.caption)
                        .scaleEffect(0.5, anchor: .top)
                    )
                }
                // Topic magnets carry no buttons: selection alone is
                // their whole voice — the threads to their articles.
                if item.kind == .concept && item.isSelected
                    && !item.id.hasPrefix("topic:")
                    && !item.id.hasPrefix(EPUBMapView.noteItemPrefix) {
                    return AnyView(
                        HStack(spacing: 8) {
                            Button(focusedConceptID == item.id ? "Un-Focus" : "Focus") {
                                focusConcept(item)
                            }
                            Button("Hide") { hideConcept(item.id) }
                        }
                        .buttonStyle(.bordered)
                        .scaleEffect(0.5, anchor: .top)
                    )
                }
                // A chosen paper in the front row carries its own verbs
                // underneath — and only while it is the one chosen.
                // With several in hand, every verb that acts on one
                // card gives way to the one that acts on many.
                if item.kind == .article, item.isSelected,
                   !item.isGhost, !item.isAside {
                    return AnyView(paperButtons(for: item))
                }
                // A citation keeps the row it had: Open, its abstract
                // when the reference carried one, and the snap-off verb.
                if item.kind == .cited || item.kind == .citedDeep,
                   item.isSelected, !item.isGhost, !item.isAside {
                    return AnyView(
                        HStack(spacing: 8) {
                            // Open: what the double tap does — the
                            // reading in-situ (a citation, its card).
                            Button("Open") { handleTap(count: 2, on: item) }
                            if !item.abstract.isEmpty {
                                Button(item.showsAbstract ? "Hide Abstract" : "Abstract") {
                                    toggleAbstract(item)
                                }
                            }
                            if EPUBMapView.liftEnabled {
                                Button(liftedCards[item.id] == nil ? "Lift" : "Put Back") {
                                    toggleLift(item)
                                }
                            }
                        }
                        .buttonStyle(.bordered)
                        // Quiet verbs under the card, not a toolbar —
                        // half life-size (attachments render full).
                        .controlSize(.small)
                        .font(.caption)
                        .scaleEffect(0.5, anchor: .top)
                    )
                }
                return AnyView(EmptyView())
            },
            constructorNodeModelEntity: { item, texturedPlane in
                cardEntity(for: item, texturedPlane: texturedPlane)
            }
        )
        view = view.nodeMaxWidth { item in
            nodeMaxWidth(for: item)
        }
        // No gaze glow on the cards: the hover effect lights the node's
        // holder — an invisible sharp-cornered box, not the rounded
        // glass face — so it reads as a ghost frame around every card.
        view = view.shouldUseHoverNode { _ in false }
        view = view.attachmentAnchorRule { _, item in
            // Centre horizontally, sit at the card's bottom edge, then
            // drop clear of it. A single paper's four verbs — Open,
            // Lift, Set Aside, Pin — hang 0.8 cm under the card: the
            // 2 cm every other row takes read as a gap with nothing in
            // it, the verbs adrift from the card they belong to.
            // (17 Sep 2026.)
            let gap: Float = item.kind == .article && selectedPaperCount == 1
                ? 0.008
                : 0.02
            return AnchorRule(
                anchor: SIMD3<Float>(0.5, 0, 0.5),
                offset: SIMD3<Float>(0, -gap, 0))
        }
        view = view.onEndMoveNode { allItems, _, newItems in
            // A lifted card's drag may have stuck it to (or freed it
            // from) a surface — keep that standing.
            if newItems.contains(where: { liftedCards[$0.id] != nil }) {
                saveLiftedCards()
            }
            // Gesture-based set-aside and pin: drag a document to the
            // floor to set it aside, or lift it above head height to pin
            // it first in the grid. A lifted card is exempt — low or
            // high, it is on its way to a surface, not the pile.
            for moved in newItems
            where moved.kind == .article && liftedCards[moved.id] == nil {
                guard let pos = moved.position else { continue }
                if pos.y < 0.15 && !moved.isAside {
                    // Floor drop → set aside.
                    model.toggleSetAside(moved.id)
                    placed[moved.id] = SIMD3<Float>(pos.x, 0.05, pos.z)
                    raisedArticleIDs.remove(moved.id)
                    if let idx = items.firstIndex(where: { $0.id == moved.id }) {
                        items[idx].isSelected = false
                    }
                    reload()
                    return
                } else if pos.y > 2.0 && !moved.isPinned {
                    // Overhead lift → pin.
                    model.togglePinned(moved.id)
                    placed[moved.id] = nil
                    reload()
                    return
                } else if moved.isAside && pos.y > 0.9 && pos.y <= 2.0 {
                    // Only a deliberate lift — chest height — brings a
                    // set-aside slip back; a nudge along the floor row
                    // (anything under 0.9 m) keeps the tag standing.
                    placed[moved.id] = pos
                    model.toggleSetAside(moved.id)
                    reload()
                    return
                }
            }
            keepPlacements(of: Array(newItems))
            selectedCitationLines.rebuild(items: Array(allItems))
            citedToDeepLines.rebuild(items: Array(allItems))
        }
        // Selected cards travel as one: dragging any selected card
        // carries the rest of its selected FAMILY by the same delta —
        // Select ▸ Documents then a drag moves every selected article
        // together, Select ▸ Citations the whole wall, each card
        // keeping its own year's Z. An unselected card still moves
        // alone, and the families never cross.
        view = view.shouldCheckMoveAnotherNodes { item in
            item.isSelected && (item.kind == .article || item.kind == .concept
                || item.kind == .cited || item.kind == .citedDeep)
        }
        view = view.shouldMoveAnotherNode { moving, item in
            guard item.isSelected else { return false }
            let citations: Set<EPUBMapItem.Kind> = [.cited, .citedDeep]
            if citations.contains(moving.kind) {
                return citations.contains(item.kind)
            }
            if moving.kind == .article {
                return item.kind == .article
            }
            return moving.kind == .concept && item.kind == .concept
        }
        view = view.constrainMovedNode { item, proposed, startPosition in
            // A ghost holds the lifted card's place — the slot is the
            // whole point of it.
            if item.isGhost { return startPosition }
            // A snapped-off card moves free in every axis and courts
            // the room's surfaces: within reach of one it lands on the
            // plane. State writes only ON CHANGE — a write per frame
            // invalidates the whole view and drags like mud.
            if let lifted = liftedCards[item.id] {
                if let pose = surfacePose(for: proposed) {
                    if lifted.stuck != pose.orientation.vector {
                        liftedCards[item.id]?.stuck = pose.orientation.vector
                    }
                    return pose.position
                }
                if lifted.stuck != nil {
                    liftedCards[item.id]?.stuck = nil
                }
                return proposed
            }
            // EXPERIMENT — a journal card stays on its publication
            // year's plane: free in X and Y, held in Z, like the
            // citations below. Asides (not in the table) still move free.
            if item.kind == .article, let z = articleYearZ[item.id] {
                var held = proposed
                held.z = z
                return held
            }
            // Concepts move freely in all axes.
            guard item.kind == .cited || item.kind == .citedDeep else { return proposed }
            // Citations stay on their year's Z no matter what. Prefer
            // the canonical timeline table; if that's missing for any
            // reason, pin to the item's own Z — or the drag's start Z
            // as a last resort. This way a citation can never escape its
            // time slot under any circumstance.
            let z = citedTimelineZ[item.id]
                ?? item.position?.z
                ?? startPosition.z
            var held = proposed
            held.z = z
            return held
        }
        view = view.constructorConnectionModelEntity {
            // The citation lines — Author's connection entity.
            ModelEntity.connection(
                size: 0.0022,
                // Mid-grey, barely there: visible only when two or more
                // papers stand selected. Lines to a shared citation wear
                // green instead (the tint the shared card asks for).
                color: Color(white: 0.5).opacity(0.02),
                connectionOptions: .none,
                materialMode: .none)
        }
        view = view.shouldEnableNode { item in
            guard model.readingDeskDocID == nil else { return false }
            // A concept's own Focus: only that concept and the articles
            // it touches stand; everything unconnected steps away.
            if let focusedConceptID {
                return item.id == focusedConceptID
                    || focusedConceptArticleIDs.contains(item.id)
            }
            // Focus: hide everything except selected items and anything
            // directly connected to them via the citation graph. The
            // explicit Focus outranks the two-selected overlap rule
            // below — it used to lose to it, so Focus with exactly two
            // articles selected appeared to do nothing.
            if focusMode {
                let selected = items.filter { $0.isSelected }
                guard !selected.isEmpty else { return true }
                if item.isSelected { return true }
                // A selected item references this one (e.g. article → citation).
                if selected.contains(where: { $0.citedIDs.contains(item.id) }) { return true }
                // This item references a selected item (e.g. citation → its citing article).
                if item.citedIDs.contains(where: { id in selected.contains(where: { $0.id == id }) }) {
                    return true
                }
                return false
            }
            // With exactly 2 articles raised: only articles and shared
            // citations are shown — the wall narrows to the overlap.
            let n = items.count(where: { $0.kind == .article && $0.isSelected })
            if n == 2 { return item.kind == .article || item.kind == .concept || item.isShared }
            return true
        }
        view = view.shouldDrawConnectionForNode { item in
            guard model.readingDeskDocID == nil else { return false }
            let n = items.count(where: { $0.kind == .article && $0.isSelected })
            // 2+ selected: custom colored lines (3+) or no lines (2).
            // Single selection keeps the default hallway weave.
            return item.isSelected && n < 2
        }
        view = view.connectedNodesToNode { item in
            // Lines appear only when two or more articles are selected —
            // a single selection raises citations silently, no weave.
            let selectedArticleCount = items.count(where: { $0.kind == .article && $0.isSelected })
            guard selectedArticleCount >= 2 else { return [] }

            switch item.kind {
            case .cited:
                // Forward only: the raised rank of what it cites.
                return items.filter { item.citedIDs.contains($0.id) }
            case .citedDeep:
                // A selected raised card weaves among citations alone:
                // the citations that raised it, the works whose
                // references name it, and the visible cards its own
                // references name — the documents stay out of it.
                let wallID = "cited:" + item.id.dropFirst("deep:".count)
                let links = deepLinks[item.id]
                return items.filter {
                    $0.kind != .article
                        && ($0.citedIDs.contains(item.id)
                            || $0.citedIDs.contains(wallID)
                            || links?.inbound.contains($0.id) == true
                            || links?.outbound.contains($0.id) == true)
                }
            case .article:
                return items.filter { $0.isShared && item.citedIDs.contains($0.id) }
            case .concept:
                return []
            }
        }
        view = view.onTapNode { tapCount, item in
            handleTap(count: tapCount, on: item)
        }
        // The Z control: a two-hand pinch anywhere on the Map. Out
        // stretches the time-spread deeper into the room; in gathers
        // it back. One pinch, one step.
        view = view.onPinchOut {
            stepCitedDepth(deeper: false)
        }
        view = view.onPinchIn {
            stepCitedDepth(deeper: true)
        }
        view = view.defaultMaxWidth(100.0)
        view = view.defaultNodePosition([0.0, 1.4, -1.2])
        view = view.onSetupContent { content in
            armMenu.install(in: content)
            // Only Overlap steps in only when common ground stands.
            armMenu.setChipVisible(Self.onlyOverlapChipID, false)
            armMenu.setChipVisible(Self.revealConceptsChipID, false)
            // Select's kinds wait folded until the parent pinch.
            armMenu.setChipVisible(Self.selectCitationsChipID, false)
            armMenu.setChipVisible(Self.selectDocumentsChipID, false)
            armMenu.setChipVisible(Self.selectTopicsChipID, false)
            armMenu.setChipVisible(Self.selectConceptsChipID, false)
            // (The note pad that rode the wrist is not declared at
            // all now — see the chips above.)
            // Show's families wait folded until the chip is pinched.
            updateShowChips()
            // And so do the right arm's two fans — Layout's options
            // and the saved slots.
            updateWatchChips()
            // Every family of Show — the lanes and graph walls among
            // them — wears its standing from the first frame, so a
            // timeline or wall left on last session reads active
            // straight away. updateShowChips above has done it.
            conceptLadder.install(in: content)
            faceTurner.install()
            sankeyWallLeft.install(in: content)
            sankeyWallRight.install(in: content)
            floorBandLeft.install(in: content)
            floorBandMiddle.install(in: content)
            floorBandRight.install(in: content)
            floorDecadeLines.install(in: content)
            readerPanels.install(in: content)
            citationLines.install(in: content)
            selectedCitationLines.install(in: content)
            conceptConnectionLines.install(in: content)
            citedToDeepLines.install(in: content)
            cardTick.install(in: content,
                             faceTurner: faceTurner,
                             lines: [selectedCitationLines,
                                     conceptConnectionLines,
                                     citedToDeepLines],
                             // Lifted cards billboard at the NODE — the
                             // tick yaws card AND collision toward the
                             // head, so gaze can take a lifted card
                             // from any side; everything else stands
                             // upright.
                             anyLifted: { !liftedCards.isEmpty },
                             liftedFacesHead: { liftedCards[$0] != nil })
            // Align to Room's wall: a wall-classified vertical plane on
            // the one tracking session, read when the chip is tapped.
            let roomWall = AnchorEntity(.plane(.vertical, classification: .wall,
                                               minimumBounds: SIMD2<Float>(1, 1)))
            content.add(roomWall)
            roomWallAnchor = roomWall
            // A landing desk for lifted cards, beside the wall.
            let desk = AnchorEntity(.plane(.horizontal, classification: .table,
                                           minimumBounds: SIMD2<Float>(0.4, 0.4)))
            content.add(desk)
            deskAnchor = desk
            fistGrab.install(
                in: content,
                move: { delta in
                    // Live: carry every card by the fist's motion. The
                    // lines follow on their own each frame. A card
                    // stuck to a real surface stays with the room, not
                    // the carried space.
                    for entity in content.entities
                    where entity.components.has(MapSpaceNodeComponent.self) {
                        if let id = entity.components[EPUBNodeIDComponent.self]?.id,
                           liftedCards[id]?.stuck != nil { continue }
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
    /// The supersample: faces lay out at four times their design size
    /// and the entity scales them back down by four, the way the chips
    /// render 22pt type at 0.32 scale — text rasterized large and
    /// shrunk stays sharp; text rasterized small and grown goes soft.
    /// Every point constant in cardFace and nodeMaxWidth wears it.
    private static let crisp: CGFloat = 4

    /// Half-size cards: the room holds more, the words still read at
    /// arm's length. One rule for the engine's raster ruler and the
    /// live attachment face alike, so they wrap identically.
    private func nodeMaxWidth(for item: EPUBMapItem) -> CGFloat {
        if item.isAside { return 85.0 * Self.crisp }
        // A chosen card is a tenth wider as well as taller: its full
        // title and every author have a little more room to run, and
        // the card reads as the one in hand from across the room.
        // (17 Sep 2026.)
        let chosen: CGFloat = item.isSelected && !item.isGhost ? 1.1 : 1.0
        switch item.kind {
        case .article: return 100.0 * chosen * Self.crisp
        case .cited: return 75.0 * chosen * Self.crisp
        case .citedDeep: return 60.0 * chosen * Self.crisp
        case .concept: return 240.0 * Self.crisp
        }
    }

    /// The title up to its colon — the working name, not the subtitle.
    private func shortTitle(_ title: String) -> String {
        title.components(separatedBy: ":")[0]
            .trimmingCharacters(in: .whitespaces)
    }

    /// The first author alone, an ellipsis standing for the rest; the
    /// byline's year suffix (" · 2023") rides along untouched.
    private func shortByline(_ byline: String) -> String {
        let parts = byline.components(separatedBy: " \u{00B7} ")
        let year = parts.count > 1 ? " \u{00B7} " + parts[1] : ""
        let names = parts[0]
            .replacingOccurrences(of: " and ", with: ",")
            .replacingOccurrences(of: " & ", with: ",")
            .replacingOccurrences(of: ";", with: ",")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let first = names.first else { return parts[0] + year }
        return (names.count > 1 ? first + "…" : first) + year
    }

    /// withAbstract: the fine print belongs to the default FRONT face
    /// alone — the turned back face carries only title and byline.
    @ViewBuilder private func cardFace(for item: EPUBMapItem,
                                       withAbstract: Bool = true) -> some View {
        let s = Self.crisp
        if item.isGhost {
            // The lifted card's held place: its title's first line
            // alone, very transparent — a slot, not a card. No frame:
            // the faint words themselves are the marker.
            Text(shortTitle(item.title))
                .font(AppFonts.body(6 * s, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.6))
                .lineLimit(1)
                .padding(.horizontal, 7 * s)
                .padding(.vertical, 5 * s)
                .opacity(0.35)
        } else if item.isAside {
            // The whole slip fades — the words too, not just the paper.
            Text(shortTitle(item.title))
                .font(AppFonts.body(5.5 * s, weight: .semibold))
                .foregroundStyle(Color.white)
                .lineLimit(1)
                .padding(.horizontal, 5 * s)
                .padding(.vertical, 3 * s)
                // The same chip glass as the standing cards, faint.
                // Shaped glass, not a material fill: in a live
                // attachment a material paints the whole backing
                // surface square — this API clips it to the corners.
                .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 5 * s))
                // The side rails are away for now: the glass alone
                // names the slip's edges (17 Sep 2026).
                .opacity(0.5)
        } else if item.id.hasPrefix(Self.noteItemPrefix) {
            // A note wears the shape of the pad it came off — the
            // watch's proportions — with the words written across it.
            // Empty, it is a blank pad and says only what it is.
            VStack(alignment: .leading, spacing: 0) {
                if item.title.isEmpty {
                    Text("Note")
                        .font(.system(size: 6 * s, weight: .semibold,
                                      design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.35))
                } else {
                    Text(item.title)
                        .font(.system(size: 6.5 * s, design: .rounded))
                        .foregroundStyle(Color.white)
                        .multilineTextAlignment(.leading)
                        .lineLimit(8)
                }
            }
            .padding(7 * s)
            // 80 × 98 points at the crisp factor — 8 cm of paper in the
            // room, in the pad's own proportions.
            .frame(width: 80 * s, height: 98 * s, alignment: .topLeading)
            .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 10 * s))
            .overlay(
                RoundedRectangle(cornerRadius: 10 * s)
                    .strokeBorder(Color.white.opacity(item.isSelected ? 0.75 : 0.25),
                                  lineWidth: (item.isSelected ? 1.6 : 0.6) * s)
            )
        } else if item.kind == .concept {
            // The arm chips' glass, in the concepts' own serif voice.
            // Real material — this face rides a live attachment now,
            // so the pane blurs the room behind it like the chips do.
            VStack(spacing: 4 * s) {
                Text(item.title)
                    .font(.system(size: 12 * s, weight: .semibold, design: .serif))
                    .foregroundStyle(Color.white)
                    .multilineTextAlignment(.center)
                if !item.author.isEmpty {
                    Text(item.author)
                        .font(.system(size: 9 * s, design: .serif))
                        .foregroundStyle(Color.white.opacity(0.65))
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 14 * s)
            .padding(.vertical, 10 * s)
            .frame(minWidth: 90 * s, maxWidth: 200 * s)
            // Selection sets the pane solid — glass no more. The glass
            // itself is shaped (not a material fill, which paints the
            // attachment's backing square past the corners).
            .background {
                if item.isSelected {
                    RoundedRectangle(cornerRadius: 14 * s)
                        .fill(Color(white: 0.12))
                }
            }
            .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 14 * s),
                                   displayMode: item.isSelected ? .never : .always)
            // No side rails: the concept pane wears one quiet rounded
            // border, brightening whole when selected.
            .overlay(
                RoundedRectangle(cornerRadius: 14 * s)
                    .strokeBorder(Color.white.opacity(item.isSelected ? 0.75 : 0.2),
                                  lineWidth: (item.isSelected ? 1.6 : 0.6) * s)
            )
        } else {
            // Half-size type for the half-size cards.
            let titleSize: CGFloat = switch item.kind {
            case .article: 7.5
            case .cited: 7
            case .citedDeep: 6
            case .concept: 6.5
            }
            // The arm chips themselves, verbatim: white ink on the
            // system's regular material with a hairline white edge.
            // Selection speaks exactly as an active chip does — the
            // border brightens and thickens, the card grows a touch
            // (the entity's scale, set in cardEntity).
            let selected = item.isSelected
            VStack(spacing: (item.kind == .citedDeep ? 1.5 : 2.5) * s) {
                HStack(alignment: .firstTextBaseline, spacing: 2 * s) {
                    if item.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 5 * s))
                            .foregroundStyle(Color(red: 0.95, green: 0.68, blue: 0.25))
                    }
                    // The working name and the first author carry the
                    // card; selection opens the FULL title and every
                    // author's name — and, on a paper, its abstract.
                    Text(selected ? item.title : shortTitle(item.title))
                        .font(AppFonts.body(titleSize * s, weight: .semibold))
                        .foregroundStyle(Color.white)
                }
                Text(selected ? item.author : shortByline(item.author))
                    .font(.system(size: 5.5 * s))
                    .foregroundStyle(Color.white.opacity(0.65))
                // A chosen PAPER opens its abstract with everything
                // else: it has no Abstract button to ask with, and the
                // front row is what one reads from. A citation still
                // waits to be asked — its own button does it.
                if withAbstract && selected && !item.abstract.isEmpty,
                   item.kind == .article || item.showsAbstract {
                    // The full abstract in fine print — readable
                    // without stepping right up to the card.
                    Text(item.abstract)
                        .font(.system(size: 5.6 * s))
                        .foregroundStyle(Color.white.opacity(0.8))
                        .multilineTextAlignment(.leading)
                        .padding(.top, 1.5 * s)
                }
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, (item.kind == .article ? 8 : 7) * s)
            .padding(.vertical, (item.kind == .article ? 6 : 5) * s)
            // Selection sets the pane solid — glass no more. The glass
            // itself is shaped (not a material fill, which paints the
            // attachment's backing square past the corners).
            .background {
                if selected && !item.isLifted {
                    RoundedRectangle(cornerRadius: 8 * s)
                        .fill(Color(white: 0.12))
                }
            }
            .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 8 * s),
                                   displayMode: (selected || item.isLifted)
                                       ? .never : .always)
            // The side rails are away for now (17 Sep 2026). What a
            // chosen card wears instead: the solid dark pane above,
            // and the fifth it grows by. A LIFTED card carries no pane
            // at all — its words print straight onto the extruded slab.
        }
    }

    private func cardEntity(for item: EPUBMapItem, texturedPlane: ModelEntity)
        -> (modelEntity: ModelEntity?, collisionShape: ShapeResource) {
        // The cards ARE the chits now: the visible face is a live
        // SwiftUI attachment — the same ViewAttachmentComponent the
        // arm chips ride — so its .regularMaterial is the system's
        // real blurred glass, not a raster imitation (an ImageRenderer
        // has no backdrop and bakes materials out black). The raster
        // plane the engine hands us serves only as the tape measure —
        // it measured the supersampled face, so divide the crisp factor
        // back out for the card's true size.
        let rawExtents = texturedPlane.visualBounds(relativeTo: nil).extents
        let extents = rawExtents / Float(Self.crisp)
        // The measured face in points (the raster's 1000 to the metre)
        // — the attachment surface is pinned to exactly this, so the
        // live layout can never outgrow it and clip the words.
        let facePoints = CGSize(width: CGFloat(rawExtents.x) * 1000,
                                height: CGFloat(rawExtents.y) * 1000)

        // An invisible body keeps visualBounds honest for the engine's
        // attachment anchoring — a live face can report zero until the
        // system lays it out.
        var ghost = UnlitMaterial()
        ghost.color = .init(tint: .clear)
        ghost.blending = .transparent(opacity: 0.0)
        // Selection grows the face, as an active chip grows — and a
        // chosen PAPER grows further than a citation does: the front
        // row is what the hand works with, and it now carries its own
        // verbs underneath.
        let grown: Float = if !item.isSelected {
            1.0
        } else if item.kind == .article {
            1.2
        } else {
            1.06
        }
        let holder = ModelEntity(
            mesh: .generateBox(width: extents.x * grown,
                               height: extents.y * grown, depth: 0.004),
            materials: [ghost])

        // Attachments lay out at 1360 points to the metre; the raster
        // ruler used 1000 — 1.36 keeps every card its familiar size,
        // divided by the crisp factor the supersampled face carries.
        let scale: Float = 1.36 / Float(Self.crisp) * grown
        func face(back: Bool) -> Entity {
            let entity = Entity()
            // Named so the face turner can find the pair each frame:
            // glass is see-through, so only the side toward the reader
            // may stand — both lit would read as text through text.
            entity.name = back ? CardFaceTurner.backName : CardFaceTurner.frontName
            entity.components.set(ViewAttachmentComponent(
                // The fine-print abstract stands on the front alone;
                // the back carries just the title and byline (shorter,
                // so it floats centred in the same pinned frame).
                rootView: cardFace(for: item, withAbstract: !back)
                    .frame(maxWidth: nodeMaxWidth(for: item))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: facePoints.width, height: facePoints.height)
                    // As the chips do: the face never takes the pinch —
                    // the holder's collision does, and the concept
                    // buttons beneath keep their own taps.
                    .allowsHitTesting(false)))
            entity.scale = SIMD3<Float>(repeating: scale)
            entity.position = SIMD3<Float>(0, 0, back ? -0.003 : 0.003)
            if back {
                // The same face on the card's back, turned to read — a
                // reader deep in the corridor looks back at standing text.
                entity.orientation = simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0))
                entity.isEnabled = false
            }
            return entity
        }
        let frontFace = face(back: false)
        let backFace = face(back: true)
        holder.addChild(frontFace)
        holder.addChild(backFace)
        holder.components.set(CardFacesComponent(front: frontFace, back: backFace))
        // A floated passage always faces the reader — billboarded on
        // its face. (Lifted CARDS turn at the node instead, in
        // MapCardTick, so their collision turns with them and the gaze
        // can take them from any side.)
        if item.id.hasPrefix("float:") {
            holder.components.set(BillboardComponent())
        }
        // A lifted card is an OBJECT now, not a leaf of the wall: a
        // slim dark extrusion behind the face sets it apart from the
        // flat cards still standing in the map.
        if item.isLifted {
            let depth = ModelEntity(
                mesh: .generateBox(size: SIMD3<Float>(extents.x * 0.98,
                                                      extents.y * 0.98, 0.012),
                                   cornerRadius: 0.004),
                materials: [SimpleMaterial(color: UIColor(white: 0.08, alpha: 0.85),
                                           roughness: 0.5, isMetallic: false)])
            depth.position = SIMD3<Float>(0, 0, -0.008)
            holder.addChild(depth)
        }

        // Set Aside slips fade whole — glass and words together.
        if item.isAside {
            holder.components.set(OpacityComponent(opacity: 0.4))
        }
        // The fist carries every card; the connection lines re-lay
        // themselves from the cards each frame.
        holder.components.set(MapSpaceNodeComponent())
        holder.components.set(EPUBNodeIDComponent(id: item.id))
        // The body and the pinch target grow with the face, so the
        // gaze frame still fits a chosen card and its verbs still hang
        // clear beneath it (the attachment anchors on these bounds).
        let shape = ShapeResource.generateBox(size: SIMD3<Float>(
            extents.x * grown + 0.008, extents.y * grown + 0.008, 0.012))
        return (holder, shape)
    }

    /// One edge per selected concept per article carrying it, resolved
    /// by text mention — the same source the concept picks select by.
    private func conceptEdges() -> [(from: String, to: String)] {
        var edges: [(from: String, to: String)] = []
        for item in items where item.kind == .concept && item.isSelected
            && !item.id.hasPrefix("topic:") {
            for docID in model.articleIDs(mentioning: item.title) {
                edges.append((from: item.id, to: docID))
            }
        }
        // A selected topic magnet threads to every article it speaks
        // for — the same pull as the Mac bar's threads.
        if let venue = model.openJournalVenue {
            var standing: [MapTopics.Paper]?
            for item in items where item.isSelected && item.id.hasPrefix("topic:") {
                let papers = standing ?? topicStandingArticles(venue: venue)
                standing = papers
                let pole = MapTopics.words(item.title)
                for paper in papers where MapTopics.pull(
                    pole: pole, topics: paper.topics, title: paper.title) > 0 {
                    edges.append((from: item.id, to: paper.id))
                }
            }
        }
        return edges
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

    /// Select's unfolded kinds: Citations stands only while cited
    /// cards do — there is nothing to select on a quiet wall. Called
    /// on the parent pinch and again on every reload, so a rising or
    /// falling wall corrects the open column live. Each kind chip
    /// wears its standing — bright with the active border while its
    /// whole family is selected — and Select itself stays lit while
    /// any menu-made selection stands, so the folded menu still says
    /// something is chosen.
    private func updateSelectChips() {
        let citationsStand = items.contains {
            $0.kind == .cited || $0.kind == .citedDeep
        }
        armMenu.setChipVisible(Self.selectCitationsChipID,
                               selectOpen && citationsStand)
        armMenu.setChipVisible(Self.selectDocumentsChipID, selectOpen)
        armMenu.setChipVisible(Self.selectTopicsChipID, selectOpen)
        armMenu.setChipVisible(Self.selectConceptsChipID, selectOpen)
        armMenu.setChipActive(Self.selectCitationsChipID, selectKindStands(.citations))
        armMenu.setChipActive(Self.selectDocumentsChipID, selectKindStands(.documents))
        armMenu.setChipActive(Self.selectTopicsChipID, selectKindStands(.topics))
        armMenu.setChipActive(Self.selectConceptsChipID, selectKindStands(.concepts))
        armMenu.setChipActive(Self.selectChipID,
                              selectOpen || SelectKind.allCases.contains(where: selectKindStands))
    }

    /// The Select menu's choice as a toggle: a kind whose whole family
    /// already stands selected — its chip bright when the menu reopens
    /// — lets them all go; any other choice selects that kind alone.
    /// Either way the chosen menu folds away.
    private func toggleSelect(_ kind: SelectKind) {
        if selectKindStands(kind) {
            deselectKind(kind)
        } else {
            selectOnly(kind)
        }
        selectOpen = false
        updateSelectChips()
    }

    /// Whether the kind's whole family is selected — the shape only
    /// the Select menu makes, and the state its chip wears.
    private func selectKindStands(_ kind: SelectKind) -> Bool {
        let family = items.filter { matchesSelectKind(kind, $0) }
        return !family.isEmpty && family.allSatisfy(\.isSelected)
    }

    /// The menu-made selection let go, with the same tap semantics as
    /// deselecting by hand: citations retire their deep rank, a
    /// focused concept lifts its Focus.
    private func deselectKind(_ kind: SelectKind) {
        for index in items.indices where matchesSelectKind(kind, items[index]) {
            items[index].isSelected = false
        }
        if kind == .citations { deepParentIDs = [] }
        if kind == .concepts {
            focusedConceptID = nil
            focusedConceptArticleIDs = []
        }
        updateStandingChips()
        reload()
    }

    private func matchesSelectKind(_ kind: SelectKind, _ item: EPUBMapItem) -> Bool {
        guard !item.isGhost else { return false }
        return switch kind {
        case .documents: item.kind == .article && !item.isAside
        case .citations: item.kind == .cited || item.kind == .citedDeep
        // The topic magnets and floated passages are their own families
        // — Select's Concepts leaves them as they stand.
        case .concepts: item.kind == .concept && !item.id.hasPrefix("topic:")
            && !item.id.hasPrefix("float:")
        // The magnets, which Concepts leaves alone, are a family of
        // their own — and now Select's own third kind.
        case .topics: item.kind == .concept && item.id.hasPrefix("topic:")
        }
    }

    // MARK: - Spatial notes

    /// A note's item id: the store's id behind this mark, the way
    /// floats and topics name themselves.
    private static let noteItemPrefix = "note:"

    /// The note a card stands for, if it stands for one.
    private func note(for itemID: String) -> SpatialNotes.Note? {
        guard itemID.hasPrefix(Self.noteItemPrefix) else { return nil }
        let id = String(itemID.dropFirst(Self.noteItemPrefix.count))
        return spatialNotes.first { $0.id == id }
    }

    /// A pad pulled off the wrist: a note comes into being where the
    /// hand let it go, and opens for writing at once.
    private func makeNote(at drop: SIMD3<Float>) {
        let place = drop - spaceShift
        let note = SpatialNotes.Note(
            venue: model.openJournalVenue ?? "",
            x: Double(place.x),
            // Never below the knee or above the reach — a note dropped
            // wildly still stands where it can be read.
            y: Double(min(max(place.y, 0.4), 2.2)),
            z: Double(place.z))
        SpatialNotes.save(note, community: model.index.folderURL)
        spatialNotes.append(note)
        reload()
        openNoteEditor(note)
    }

    /// The note's own panel, standing where the note stands: the words
    /// to type, the microphone to speak them, and the ways out.
    private func openNoteEditor(_ note: SpatialNotes.Note) {
        let panelID = "note-edit:" + note.id
        let at = SIMD3<Float>(Float(note.x), Float(note.y), Float(note.z))
            + spaceShift + SIMD3<Float>(0, 0, 0.08)
        readerPanels.open(
            docID: panelID,
            at: at,
            view: AnyView(
                SpatialNotePanel(
                    note: note,
                    write: { written in
                        var kept = note
                        kept.text = written
                        SpatialNotes.save(kept, community: model.index.folderURL)
                        if let index = spatialNotes.firstIndex(where: { $0.id == note.id }) {
                            spatialNotes[index] = kept
                        }
                        reload()
                    },
                    remove: {
                        SpatialNotes.delete(note, community: model.index.folderURL)
                        spatialNotes.removeAll { $0.id == note.id }
                        readerPanels.close(docID: panelID)
                        reload()
                    },
                    onClose: { readerPanels.close(docID: panelID) })),
            onClose: { readerPanels.close(docID: panelID) })
    }

    /// How many papers stand chosen — what decides whether a card
    /// offers its own verbs or the one verb that acts on many.
    private var selectedPaperCount: Int {
        items.filter {
            $0.kind == .article && $0.isSelected && !$0.isAside && !$0.isGhost
        }.count
    }

    /// The verbs under a chosen paper. One paper in hand: Open, Lift,
    /// Set Aside, Pin — each acting on this card alone. Several in
    /// hand: Layout, which acts on all of them, and unfolds Author's
    /// arrangements right there (nothing may present a menu on an
    /// attachment, so the options are buttons like everything else).
    @ViewBuilder private func paperButtons(for item: EPUBMapItem) -> some View {
        if selectedPaperCount > 1 {
            manyPaperButtons(for: item)
                .buttonStyle(.bordered)
                // Layout's own list stands HALF AGAIN the size of a
                // card's quiet verbs: eleven arrangements is a menu to
                // read across the room and pinch at, not a footnote.
                .controlSize(.regular)
                .scaleEffect(0.8, anchor: .top)
        } else {
            onePaperButtons(for: item)
                .buttonStyle(.bordered)
                // Quiet verbs under the card, not a toolbar — half
                // life-size (attachments render full).
                .controlSize(.small)
                .font(.caption)
                .scaleEffect(0.5, anchor: .top)
        }
    }

    /// Several papers chosen: the one verb that acts on many, and the
    /// arrangements it unfolds — four to a row, so eleven words do not
    /// run off into the room.
    @ViewBuilder private func manyPaperButtons(for item: EPUBMapItem) -> some View {
        VStack(spacing: 8) {
            Button("Layout") {
                layoutRowCardID = layoutRowCardID == item.id ? nil : item.id
            }
            if layoutRowCardID == item.id {
                let options = Array(WatchLayoutOption.allCases)
                let rows = stride(from: 0, to: options.count, by: 4).map {
                    Array(options[$0..<min($0 + 4, options.count)])
                }
                VStack(spacing: 8) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 8) {
                            ForEach(row, id: \.self) { option in
                                Button(option.title) {
                                    runWatchLayout(option)
                                    layoutRowCardID = nil
                                }
                            }
                        }
                    }
                    // Auto's whole-wall arrangements ride here too now
                    // the arm has no Layout: Wall among them, which is
                    // the room's way back from a mess.
                    HStack(spacing: 8) {
                        ForEach(Self.offeredWatchViews, id: \.self) { option in
                            Button(option.title) {
                                runWatchView(option)
                                layoutRowCardID = nil
                            }
                        }
                    }
                }
                // The list stands 3 cm below the button that opened it
                // — a centimetre and a half further down than it did
                // (17 Sep 2026), which is what reads right in the
                // room. Attachments lay out at 1360 points to the
                // metre and this whole block is drawn at 0.8, so 25.5
                // points is a centimetre and a half: two of them.
                .padding(.top, 51)
            }
        }
    }

    /// One paper chosen: its own four verbs.
    @ViewBuilder private func onePaperButtons(for item: EPUBMapItem) -> some View {
        HStack(spacing: 8) {
            Button("Open") { handleTap(count: 2, on: item) }
            if EPUBMapView.liftEnabled {
                Button(liftedCards[item.id] == nil ? "Lift" : "Put Back") {
                    toggleLift(item)
                }
            }
            Button("Set Aside") {
                model.toggleSetAside(item.id)
                reload()
                updateStandingChips()
            }
            // Pinned, the word names the way back out.
            Button(item.isPinned ? "Unpin" : "Pin") {
                model.togglePinned(item.id)
                reload()
                updateStandingChips()
            }
        }
    }

    private func toggleAbstract(_ item: EPUBMapItem) {
        if abstractOpenIDs.contains(item.id) {
            abstractOpenIDs.remove(item.id)
        } else {
            abstractOpenIDs.insert(item.id)
        }
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index].showsAbstract = abstractOpenIDs.contains(item.id)
        }
    }

    // MARK: - Lift — a card snapped off the map, stuck to a surface

    /// Lift: the card snaps off the map — a ghost holds its place —
    /// and rides the hand free of the year planes, courting the room's
    /// surfaces. Put Back: it returns whole to the held place.
    private func toggleLift(_ item: EPUBMapItem) {
        if liftedCards[item.id] != nil {
            putBack(item)
        } else {
            lift(item)
        }
    }

    private func lift(_ item: EPUBMapItem) {
        // The LIVE card, not the attachment's captured copy — a drag
        // or fist-carry since the button was built would otherwise
        // leave the ghost standing off the card's true place.
        let live = items.first { $0.id == item.id } ?? item
        guard let position = live.position else { return }
        liftedCards[item.id] = LiftedCard(home: position)
        // The card steps toward the reader, visibly off its slot.
        placed[item.id] = position + SIMD3<Float>(0, 0, 0.3)
        saveLiftedCards()
        savePlacedNow()
        reload()
    }

    private func putBack(_ item: EPUBMapItem) {
        guard let lifted = liftedCards[item.id] else { return }
        liftedCards[item.id] = nil
        placed[item.id] = lifted.home
        saveLiftedCards()
        savePlacedNow()
        reload()
    }

    private func savePlacedNow() {
        EPUBMapLayoutStore.save(placed, community: model.index.folderURL,
                                sharedKeys: sharedKeyByID)
        sharedLayoutAdoptedAt = Date()
    }

    /// The lifted cards' place-holders, one per lifted card still in
    /// the room — a card whose journal closed leaves no stray ghost.
    private func ghostItems(among built: [EPUBMapItem]) -> [EPUBMapItem] {
        liftedCards.compactMap { id, lifted in
            guard let original = built.first(where: { $0.id == id }) else { return nil }
            var ghost = EPUBMapItem(
                id: "ghost:" + id,
                title: String(original.title.split(separator: "\n").first ?? ""),
                author: "",
                kind: original.kind,
                position: lifted.home)
            ghost.isGhost = true
            ghost.visionTheme = original.visionTheme
            return ghost
        }
    }

    /// Where a floating lifted card would land: the nearest room
    /// surface within reach — the wall's plane, the desk's top — with
    /// the pose the card wears there. Nil in open air.
    private func surfacePose(for position: SIMD3<Float>)
        -> (position: SIMD3<Float>, orientation: simd_quatf)? {
        let reach: Float = 0.12
        var best: (position: SIMD3<Float>, orientation: simd_quatf, distance: Float)?
        if let wall = roomWallAnchor, wall.isAnchored {
            let point = wall.position(relativeTo: nil)
            // A plane anchor's local Y is its normal; flattened, and
            // pointed into the room (toward the viewer when known).
            var normal = wall.convert(direction: SIMD3<Float>(0, 1, 0), to: nil)
            normal.y = 0
            let length = simd_length(normal)
            if length > 1e-3 {
                normal /= length
                if let head = faceTurner.headPosition(),
                   simd_dot(normal, head - point) < 0 {
                    normal = -normal
                }
                let distance = simd_dot(position - point, normal)
                if abs(distance) < reach {
                    let landed = position - normal * distance + normal * 0.015
                    // The card's front (+Z) turned along the normal.
                    let turn = simd_quatf(angle: atan2(normal.x, normal.z),
                                          axis: SIMD3<Float>(0, 1, 0))
                    best = (landed, turn, abs(distance))
                }
            }
        }
        if let desk = deskAnchor, desk.isAnchored {
            let deskPlace = desk.position(relativeTo: nil)
            let gap = position.y - deskPlace.y
            let across = simd_length(SIMD2(position.x - deskPlace.x,
                                           position.z - deskPlace.z))
            if gap > -0.05, gap < reach, across < 1.2,
               best == nil || abs(gap) < best!.distance {
                var landed = position
                landed.y = deskPlace.y + 0.01
                // Lying flat, face up: the front turned to the ceiling.
                let flat = simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(1, 0, 0))
                best = (landed, flat, abs(gap))
            }
        }
        return best.map { ($0.position, $0.orientation) }
    }

    // MARK: - The watch's Layout — Author Map's align, distribute, sort

    /// The cards a Layout verb moves: the selected standing articles,
    /// or every standing article when nothing is chosen.
    private func watchLayoutTargets() -> [EPUBMapItem] {
        let standing = items.filter {
            $0.kind == .article && !$0.isAside && !$0.isGhost
                && $0.position != nil && liftedCards[$0.id] == nil
        }
        let selected = standing.filter(\.isSelected)
        return selected.isEmpty ? standing : selected
    }

    /// A record's own date, for the Time sorts — the undated sort last.
    private func watchDate(_ id: String) -> Date {
        model.epubRecords.first { $0.id == id }?.dateISO
            .flatMap(LiquidDoc.parseISO8601) ?? .distantFuture
    }

    private func runWatchLayout(_ option: WatchLayoutOption) {
        let targets = watchLayoutTargets()
        guard targets.count > 1 else { return }
        var xy: [String: SIMD2<Float>] = [:]
        for target in targets {
            guard let position = target.position else { continue }
            xy[target.id] = SIMD2(position.x, position.y)
        }
        let xs = xy.values.map(\.x), ys = xy.values.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return }
        let count = Float(targets.count)
        // A degenerate span (a stacked pile) opens to the wall's pitch.
        let spanX = max(maxX - minX, (count - 1) * Self.columnPitch)
        let spanY = max(maxY - minY, (count - 1) * Self.rowPitch)
        func spreadY(_ ordered: [EPUBMapItem]) {
            let top = (minY + maxY) / 2 + spanY / 2
            for (index, item) in ordered.enumerated() {
                xy[item.id]?.y = top - spanY * Float(index) / max(count - 1, 1)
            }
        }
        func spreadX(_ ordered: [EPUBMapItem]) {
            let leading = (minX + maxX) / 2 - spanX / 2
            for (index, item) in ordered.enumerated() {
                xy[item.id]?.x = leading + spanX * Float(index) / max(count - 1, 1)
            }
        }
        let byTitle: (EPUBMapItem, EPUBMapItem) -> Bool = {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        switch option {
        case .left:
            for id in xy.keys { xy[id]?.x = minX }
        case .center:
            let mid = xs.reduce(0, +) / count
            for id in xy.keys { xy[id]?.x = mid }
        case .right:
            for id in xy.keys { xy[id]?.x = maxX }
        case .middle:
            // One row: the cards keep their x and meet at the middle
            // height — Center's counterpart, Author's "Horizontal".
            let mid = ys.reduce(0, +) / count
            for id in xy.keys { xy[id]?.y = mid }
        case .down:
            // Spread down the wall in the standing top-to-bottom order.
            spreadY(targets.sorted { ($0.position?.y ?? 0) > ($1.position?.y ?? 0) })
        case .across:
            // And the same left to right, in the order they stand —
            // no sort, just even air between them.
            spreadX(targets.sorted { ($0.position?.x ?? 0) < ($1.position?.x ?? 0) })
        case .sortVertical:
            spreadY(targets.sorted(by: byTitle))
        case .sortVerticalReverse:
            spreadY(targets.sorted { byTitle($1, $0) })
        case .sortHorizontal:
            spreadX(targets.sorted(by: byTitle))
        case .sortHorizontalReverse:
            spreadX(targets.sorted { byTitle($1, $0) })
        case .time:
            spreadX(targets.sorted { watchDate($0.id) < watchDate($1.id) })
        case .timeReverse:
            spreadX(targets.sorted { watchDate($0.id) > watchDate($1.id) })
        }
        applyWatchPositions(xy)
    }

    /// Writes the arranged plane positions back to the cards — depth
    /// stays the year's own — into the placement memory, and rebuilds.
    /// The moment before is remembered whole, for the watch's Undo.
    private func applyWatchPositions(_ xy: [String: SIMD2<Float>]) {
        var snapshot: [String: SIMD3<Float>] = [:]
        var moved: [EPUBMapItem] = []
        for index in items.indices {
            guard let target = xy[items[index].id],
                  var position = items[index].position else { continue }
            snapshot[items[index].id] = position
            position.x = min(max(target.x, spaceShift.x - 3), spaceShift.x + 3)
            position.y = min(max(target.y, 0.95), 2.2)
            items[index].position = position
            moved.append(items[index])
        }
        if !snapshot.isEmpty { watchUndo = snapshot }
        keepPlacements(of: moved)
        reload()
        updateWatchChips()
    }

    /// The arrangement's way back: every card returns to where it stood
    /// the moment the option was chosen. One step — a second pinch has
    /// nothing further to restore until the next arrangement.
    private func undoWatchArrangement() {
        guard let snapshot = watchUndo else { return }
        watchUndo = nil
        var moved: [EPUBMapItem] = []
        for index in items.indices {
            guard let position = snapshot[items[index].id] else { continue }
            items[index].position = position
            moved.append(items[index])
        }
        keepPlacements(of: moved)
        reload()
        updateWatchChips()
    }

    // MARK: - The watch's Views — Author Map's arrangements

    private func runWatchView(_ option: WatchViewOption) {
        let articles = items.filter {
            $0.kind == .article && !$0.isAside && !$0.isGhost
                && $0.position != nil && liftedCards[$0.id] == nil
        }
        guard articles.count > 1 else { return }
        let xs = articles.compactMap { $0.position?.x }
        let ys = articles.compactMap { $0.position?.y }
        let center = SIMD2<Float>(
            xs.reduce(0, +) / Float(xs.count),
            min(max(ys.reduce(0, +) / Float(ys.count), 1.2), 1.6))
        let adjacency = inJournalAdjacency(articles)
        let xy: [String: SIMD2<Float>]
        switch option {
        case .wall:
            xy = wallPositions(articles)
        case .magneticCenter:
            xy = magneticCenterPositions(articles, adjacency: adjacency, center: center)
        case .spine:
            // Author's Spine walks the document's Section nodes; the
            // wall has none, so it falls back exactly as Author does.
            xy = magneticCenterPositions(articles, adjacency: adjacency, center: center)
        case .islands:
            xy = islandsPositions(articles, adjacency: adjacency, center: center)
        case .orbits:
            xy = orbitsPositions(articles, center: center)
                ?? magneticCenterPositions(articles, adjacency: adjacency, center: center)
        case .timeline:
            xy = timelinePositions(articles, center: center)
        case .neighborhoods:
            xy = neighborhoodsPositions(articles, adjacency: adjacency, center: center)
                ?? magneticCenterPositions(articles, adjacency: adjacency, center: center)
        }
        applyWatchPositions(xy)
    }

    /// The undirected in-journal citation links — which standing cards
    /// cite each other. The arrangements' one graph.
    private func inJournalAdjacency(_ articles: [EPUBMapItem]) -> [String: Set<String>] {
        let ids = Set(articles.map(\.id))
        var adjacency: [String: Set<String>] = [:]
        for article in articles {
            for cited in article.citedIDs where ids.contains(cited) && cited != article.id {
                adjacency[article.id, default: []].insert(cited)
                adjacency[cited, default: []].insert(article.id)
            }
        }
        return adjacency
    }

    /// Wall: every standing paper in a plain rectangle, alphabetical
    /// by title from the top left, the cards a hand's width of air
    /// apart. This is the room's starting arrangement and the one to
    /// come back to when the place has become a mess — so it stands
    /// where the room is, not wherever the cards have drifted to, and
    /// the same books always land in the same order.
    ///
    /// Depth is not ours to set: a paper's Z is its year, and reload
    /// reclaims it on every sweep. The rectangle is what the reader
    /// sees standing in front of the wall.
    private func wallPositions(_ articles: [EPUBMapItem]) -> [String: SIMD2<Float>] {
        let ordered = articles.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        guard !ordered.isEmpty else { return [:] }
        let count = ordered.count
        // Near enough square in the room's own measure, and never
        // taller than the band a card may stand in (0.95…2.2) — a
        // rectangle that runs off the top would only be clamped into
        // a pile at the ceiling.
        let rowsAvailable = max(1, Int((2.15 - 0.95) / Self.rowPitch) + 1)
        var columns = Self.wallColumns(count)
        while (count + columns - 1) / columns > rowsAvailable, columns < count {
            columns += 1
        }
        let rows = (count + columns - 1) / columns
        let leading = spaceShift.x - Self.columnPitch * Float(columns - 1) / 2
        let top = Self.wallTop(rows: rows)
        var xy: [String: SIMD2<Float>] = [:]
        for (index, item) in ordered.enumerated() {
            xy[item.id] = SIMD2(
                leading + Self.columnPitch * Float(index % columns),
                top - Self.rowPitch * Float(index / columns))
        }
        return xy
    }

    /// Author's Magnetic Center: the most-connected cards at the
    /// middle, each lower connection count a ring further out, the
    /// unconnected in the outermost band.
    private func magneticCenterPositions(_ articles: [EPUBMapItem],
                                         adjacency: [String: Set<String>],
                                         center: SIMD2<Float>) -> [String: SIMD2<Float>] {
        let buckets = Dictionary(grouping: articles) { adjacency[$0.id]?.count ?? 0 }
            .sorted { $0.key > $1.key }
            .map { $0.value.sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            } }
        var xy: [String: SIMD2<Float>] = [:]
        // Each ring is only as wide as its own cards need, and always
        // a card's pitch clear of the ring inside it.
        var inner: Float = 0
        for (ring, bucket) in buckets.enumerated() {
            if ring == 0, bucket.count == 1 {
                xy[bucket[0].id] = center
                inner = Self.columnPitch / 2
                continue
            }
            let radius = max(Self.ringRadius(bucket.count), inner + Self.columnPitch)
            inner = radius
            for (index, item) in bucket.enumerated() {
                let angle = Float(index) / Float(bucket.count) * 2 * .pi - .pi / 2
                xy[item.id] = SIMD2(
                    center.x + cosf(angle) * radius,
                    center.y + sinf(angle) * radius * Self.pitchAspect)
            }
        }
        return xy
    }

    /// Blocks side by side around the center — each a small grid sized
    /// from its count. The shape Islands and Neighborhoods share.
    private func layWatchBlocks(_ blocks: [[EPUBMapItem]],
                                center: SIMD2<Float>) -> [String: SIMD2<Float>] {
        let columnCounts = blocks.map {
            max(1, Int(Double($0.count).squareRoot().rounded(.up)))
        }
        let widths = columnCounts.map { Float($0 - 1) * Self.columnPitch }
        // Between blocks, one empty card slot — wider than the air
        // inside a block, so the grounds read apart without a chasm.
        let gap = Self.columnPitch + Self.autoGap
        let total = widths.reduce(0, +) + gap * Float(max(blocks.count - 1, 0))
        var x = center.x - total / 2
        var xy: [String: SIMD2<Float>] = [:]
        for (blockIndex, block) in blocks.enumerated() {
            let columns = columnCounts[blockIndex]
            let rows = (block.count + columns - 1) / columns
            let top = center.y + Self.rowPitch * Float(rows - 1) / 2
            for (index, item) in block.enumerated() {
                xy[item.id] = SIMD2(
                    x + Float(index % columns) * Self.columnPitch,
                    top - Float(index / columns) * Self.rowPitch)
            }
            x += widths[blockIndex] + gap
        }
        return xy
    }

    /// Author's Islands: each connected cluster on its own ground,
    /// side by side; the unconnected gather in a band beneath.
    private func islandsPositions(_ articles: [EPUBMapItem],
                                  adjacency: [String: Set<String>],
                                  center: SIMD2<Float>) -> [String: SIMD2<Float>] {
        let byID = Dictionary(uniqueKeysWithValues: articles.map { ($0.id, $0) })
        var claimed: Set<String> = []
        var components: [[EPUBMapItem]] = []
        for article in articles where !claimed.contains(article.id) {
            var queue = [article.id]
            var members: [EPUBMapItem] = []
            claimed.insert(article.id)
            while let id = queue.popLast() {
                if let item = byID[id] { members.append(item) }
                for next in adjacency[id] ?? [] where !claimed.contains(next) {
                    claimed.insert(next)
                    queue.append(next)
                }
            }
            components.append(members)
        }
        let islands = components.filter { $0.count > 1 }.sorted { $0.count > $1.count }
        let orphans = components.filter { $0.count == 1 }.flatMap { $0 }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        var xy = layWatchBlocks(islands, center: center)
        // The band hangs one row under the lowest island card — the
        // same gap as anywhere else, so the two read as one wall.
        let floor = (xy.values.map(\.y).min() ?? center.y) - Self.rowPitch * 2
        let leading = center.x - Self.columnPitch * Float(orphans.count - 1) / 2
        for (index, item) in orphans.enumerated() {
            xy[item.id] = SIMD2(leading + Self.columnPitch * Float(index), floor)
        }
        return xy
    }

    /// Author's Orbits: a card cited by two or more fellows becomes a
    /// hub with its citers circling it; cards citing no hub gather
    /// beneath. No hubs at all → nil, and Magnetic Center stands in.
    private func orbitsPositions(_ articles: [EPUBMapItem],
                                 center: SIMD2<Float>) -> [String: SIMD2<Float>]? {
        let ids = Set(articles.map(\.id))
        var citedBy: [String: Int] = [:]
        for article in articles {
            for cited in article.citedIDs where ids.contains(cited) && cited != article.id {
                citedBy[cited, default: 0] += 1
            }
        }
        let hubs = citedBy.filter { $0.value >= 2 }
            .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .map(\.key)
        guard !hubs.isEmpty else { return nil }
        // Who circles whom is settled first: an orbit's width follows
        // the count of its citers, and the hubs can then stand as
        // close as the widest orbit allows.
        let hubSet = Set(hubs)
        var orbiters: [String: [EPUBMapItem]] = [:]
        var leftovers: [EPUBMapItem] = []
        for article in articles where !hubSet.contains(article.id) {
            let hub = article.citedIDs.filter { hubSet.contains($0) }
                .max { citedBy[$0, default: 0] < citedBy[$1, default: 0] }
            if let hub {
                orbiters[hub, default: []].append(article)
            } else {
                leftovers.append(article)
            }
        }
        let radii = orbiters.mapValues { Self.ringRadius($0.count) }
        let spacing = 2 * (radii.values.max() ?? Self.columnPitch) + Self.columnPitch
        var xy: [String: SIMD2<Float>] = [:]
        let leading = center.x - spacing * Float(hubs.count - 1) / 2
        for (index, hub) in hubs.enumerated() {
            xy[hub] = SIMD2(leading + spacing * Float(index), center.y)
        }
        for (hub, members) in orbiters {
            guard let hubPlace = xy[hub], let radius = radii[hub] else { continue }
            let ordered = members.sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
            for (index, item) in ordered.enumerated() {
                let angle = Float(index) / Float(ordered.count) * 2 * .pi - .pi / 2
                xy[item.id] = SIMD2(
                    hubPlace.x + cosf(angle) * radius,
                    hubPlace.y + sinf(angle) * radius * Self.pitchAspect)
            }
        }
        let ordered = leftovers.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        let floor = (xy.values.map(\.y).min() ?? center.y) - Self.rowPitch * 2
        let orphanLeading = center.x - Self.columnPitch * Float(ordered.count - 1) / 2
        for (index, item) in ordered.enumerated() {
            xy[item.id] = SIMD2(orphanLeading + Self.columnPitch * Float(index), floor)
        }
        return xy
    }

    /// Author's Timeline: columns by year, oldest at the left, each
    /// column alphabetical; the dateless close the right.
    private func timelinePositions(_ articles: [EPUBMapItem],
                                   center: SIMD2<Float>) -> [String: SIMD2<Float>] {
        let dateByID = Dictionary(
            model.epubRecords.map { ($0.id, $0.dateISO) }) { first, _ in first }
        func year(_ id: String) -> Int? {
            dateByID[id]?.flatMap { Int($0.prefix(4)) }
        }
        let byTitle: (EPUBMapItem, EPUBMapItem) -> Bool = {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        let dated = Dictionary(grouping: articles.filter { year($0.id) != nil }) {
            year($0.id) ?? 0
        }
        var columns: [[EPUBMapItem]] = dated.keys.sorted().map {
            (dated[$0] ?? []).sorted(by: byTitle)
        }
        let dateless = articles.filter { year($0.id) == nil }.sorted(by: byTitle)
        if !dateless.isEmpty { columns.append(dateless) }
        let leading = center.x - Self.columnPitch * Float(columns.count - 1) / 2
        var xy: [String: SIMD2<Float>] = [:]
        for (columnIndex, column) in columns.enumerated() {
            let top = center.y + Self.rowPitch * Float(column.count - 1) / 2
            for (row, item) in column.enumerated() {
                xy[item.id] = SIMD2(leading + Self.columnPitch * Float(columnIndex),
                                    top - Self.rowPitch * Float(row))
            }
        }
        return xy
    }

    /// Author's Neighborhoods: one block per topic, side by side, the
    /// most-connected cards leading each block; the untopiced close
    /// the row. No topics to read → nil, and Magnetic Center stands in.
    private func neighborhoodsPositions(_ articles: [EPUBMapItem],
                                        adjacency: [String: Set<String>],
                                        center: SIMD2<Float>) -> [String: SIMD2<Float>]? {
        guard let venue = model.openJournalVenue else { return nil }
        let topicsByID = Dictionary(
            topicStandingArticles(venue: venue).map { ($0.id, $0.topics) }) { first, _ in first }
        var blocks: [String: [EPUBMapItem]] = [:]
        for article in articles {
            blocks[topicsByID[article.id]?.first ?? "", default: []].append(article)
        }
        guard blocks.keys.contains(where: { !$0.isEmpty }) else { return nil }
        let ordered = blocks.sorted {
            if $0.key.isEmpty != $1.key.isEmpty { return $1.key.isEmpty }
            return $0.value.count > $1.value.count
        }.map { block in
            block.value.sorted {
                let left = adjacency[$0.id]?.count ?? 0
                let right = adjacency[$1.id]?.count ?? 0
                if left != right { return left > right }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        }
        return layWatchBlocks(ordered, center: center)
    }

    /// The Select chip's kinds — one family selected whole, everything
    /// else deselected.
    private enum SelectKind: CaseIterable { case citations, documents, topics, concepts }

    /// The arm's Select pick: selection reduced to one kind alone.
    /// Documents raise every wall; Citations keep the standing walls
    /// (their cards only exist while raised) and select what stands;
    /// Concepts wake the concept row first if it was away.
    private func selectOnly(_ kind: SelectKind) {
        if kind == .topics && !topicSpaceMode {
            // Nothing to select while the magnets are away: they come
            // in first, as Concepts' row does.
            topicSpaceMode = true
            armMenu.setChipActive(Self.topicsChipID, true)
            reload()
        }
        if kind == .concepts && !conceptSpaceMode {
            conceptSpaceMode = true
            armMenu.setChipActive(Self.conceptsChipID, true)
            updateSankey()
            reload()
        }
        if kind == .documents {
            raisedArticleIDs = Set(items.filter {
                $0.kind == .article && !$0.isAside && !$0.isGhost
            }.map(\.id))
        }
        // The mass deselect keeps tap semantics: a deselected citation
        // retires its deep rank, a deselected focused concept lifts
        // its Focus.
        if kind != .citations { deepParentIDs = [] }
        if kind != .concepts {
            focusedConceptID = nil
            focusedConceptArticleIDs = []
        }
        for index in items.indices {
            items[index].isSelected = matchesSelectKind(kind, items[index])
        }
        updateStandingChips()
        reload()
    }

    /// Focus, on a selected concept's card: only this concept and the
    /// articles it touches stand — tapped again (or the concept
    /// deselected), the room fills back in.
    private func focusConcept(_ item: EPUBMapItem) {
        if focusedConceptID == item.id {
            focusedConceptID = nil
            focusedConceptArticleIDs = []
        } else {
            focusedConceptID = item.id
            focusedConceptArticleIDs = Set(model.articleIDs(mentioning: item.title))
        }
        reload()
    }

    /// Hide, on a selected concept's card: the card leaves the Map —
    /// back via the Concepts chip's long-pinch, Reveal All Concepts.
    private func hideConcept(_ id: String) {
        hiddenConceptIDs.insert(id)
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].isSelected = false
        }
        if focusedConceptID == id {
            focusedConceptID = nil
            focusedConceptArticleIDs = []
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
        articleYearZ = articleYearZ.mapValues { $0 + delta.z }
        for index in items.indices {
            // A surface-stuck card keeps its wall; everything else —
            // ghosts and floating lifted cards included — travels.
            if let position = items[index].position,
               liftedCards[items[index].id]?.stuck == nil {
                items[index].position = position + delta
            }
        }
        for (id, position) in placed where liftedCards[id]?.stuck == nil {
            placed[id] = position + delta
        }
        // The held homes travel with the space, so each ghost keeps
        // standing in its slot of the carried map.
        for id in liftedCards.keys {
            liftedCards[id]?.home += delta
        }
        saveLiftedCards()
        for item in items {
            if let position = item.position {
                placed[item.id] = position
            }
        }
        EPUBMapLayoutStore.save(placed, community: model.index.folderURL,
                                sharedKeys: sharedKeyByID)
        // Our own write is not news — the sync beat should not rebuild
        // the room over it.
        sharedLayoutAdoptedAt = Date()
    }

    /// Align to Room: the whole space slides (the fist-carry's own
    /// commit) until its right flank rests a hand's breadth off the
    /// wall standing nearest the right arm — the arm wearing the chip.
    /// Translation only: the engine's cards all face one way, so the
    /// space keeps its yaw; recentre (Digital Crown) to turn with it.
    private func alignSpaceToRoom() {
        guard let anchor = roomWallAnchor, anchor.isAnchored else {
            flashAlignChip("No Wall Found")
            return
        }
        let wallPoint = anchor.position(relativeTo: nil)
        // A plane anchor's local Y is its normal; flattened and pointed
        // into the room.
        var normal = anchor.convert(direction: SIMD3<Float>(0, 1, 0), to: nil)
        normal.y = 0
        let length = simd_length(normal)
        guard length > 1e-3 else {
            flashAlignChip("No Wall Found")
            return
        }
        normal /= length
        // Measured from the hand wearing the chip; the space's centre
        // stands in when the hand is briefly untracked.
        let hand = armMenu.wristPosition(armMenuInverted ? .left : .right)
            ?? (citedSpace.origin + spaceShift)
        if simd_dot(normal, hand - wallPoint) < 0 { normal = -normal }
        // A wall beyond a couple of metres of the hand is not "the
        // wall at the arm".
        guard abs(simd_dot(hand - wallPoint, normal)) < 2.5 else {
            flashAlignChip("No Wall Near")
            return
        }
        // The space's right flank — the right graph's plane, mid-
        // corridor (its sideOffset, walking height).
        let flank = SIMD3<Float>(
            citedSpace.origin.x + 1.15,
            CitedSpace.walkHeight,
            citedSpace.origin.z - citedSpace.depth / 2) + spaceShift
        let standing = simd_dot(flank - wallPoint, normal)
        commitSpaceShift(normal * (0.05 - standing))
        // Re-lay everything not driven by items — graphs, floor lanes,
        // lines — in the shifted space.
        reload()
    }

    /// The chip speaks its trouble for a moment, then takes its name back.
    private func flashAlignChip(_ message: String) {
        armMenu.setChipTitle(Self.alignChipID, message)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            armMenu.setChipTitle(Self.alignChipID, "Align to Room")
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
            if (item.kind == .cited || item.kind == .citedDeep)
                && liftedCards[item.id] == nil {
                let z = citedTimelineZ[item.id] ?? item.position?.z
                if let z { position?.z = z }
            }
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                items[index].position = position
            }
            if let position {
                placed[item.id] = position
                // A float's place travels IN its annotation — written
                // in map space, the carried shift removed.
                if item.id.hasPrefix("float:") {
                    model.setFloatPosition(position - spaceShift, id: item.id)
                }
                // A note's place travels in the journal's own file, in
                // the same map space — so the Mac's flat map finds it
                // where the hallway left it.
                if let note = note(for: item.id) {
                    var moved = note
                    let place = position - spaceShift
                    moved.x = Double(place.x)
                    moved.y = Double(place.y)
                    moved.z = Double(place.z)
                    SpatialNotes.save(moved, community: model.index.folderURL)
                    if let index = spatialNotes.firstIndex(where: { $0.id == note.id }) {
                        spatialNotes[index] = moved
                    }
                }
            }
        }
        EPUBMapLayoutStore.save(placed, community: model.index.folderURL,
                                sharedKeys: sharedKeyByID)
        // Our own write is not news — the sync beat should not rebuild
        // the room over it.
        sharedLayoutAdoptedAt = Date()
    }

    private func handleTap(count: Int, on item: EPUBMapItem) {
        // A ghost only holds a place — it answers nothing.
        guard !item.isGhost else { return }
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
                // Deselecting folds an opened abstract away with it.
                if !willSelect {
                    abstractOpenIDs.remove(item.id)
                    items[index].showsAbstract = false
                }
            }
            updateStandingChips()
            // Deselecting a focused concept lifts its Focus — the
            // room fills back in.
            if !willSelect, focusedConceptID == item.id {
                focusedConceptID = nil
                focusedConceptArticleIDs = []
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
                // A selected citation raises what IT cites behind it
                // and draws lines to those deep works.
                if willSelect {
                    deepParentIDs.insert(item.id)
                } else {
                    deepParentIDs.remove(item.id)
                }
                rebuildDeepRank()
                citedToDeepLines.rebuild(items: items)
            case .citedDeep:
                // The selected card shows every citation leading to it
                // and away from it, read from the graph.
                if willSelect {
                    computeDeepLinks(for: item)
                } else {
                    deepLinks[item.id] = nil
                }
            case .concept:
                // Selection triggers the concept's source-document lines.
                conceptConnectionLines.rebuild(items: items, edges: conceptEdges())
            }
        case 2:
            // The card steps off the Map and its reading opens in-situ
            // — the full reader standing where the card stood, movable
            // anywhere by its handle, free of the timeline. Closing
            // brings the card back. A citation opens its record card
            // instead: everything we hold on it, and Acquire.
            guard item.kind == .article else {
                // A note opens for writing — by hand or by voice.
                if let note = note(for: item.id) {
                    openNoteEditor(note)
                    return
                }
                // A topic magnet or floated passage has no record
                // behind it — nothing to open.
                if !item.id.hasPrefix("topic:"), !item.id.hasPrefix("float:") {
                    openCitationCard(for: item)
                }
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
        // The panel flies home first; the card returns as it lands,
        // and settles with a brief squeeze.
        readerPanels.closeAnimated(docID: docID) {
            model.openDocIDs.remove(docID)
        }
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
        // The graph key's Edit chip: the data dialog, preset to the
        // tapped graph's side.
        var editNode: Entity? = entity
        while let current = editNode {
            if current.name.hasPrefix("graph.edit.") {
                UserDefaults.standard.set(
                    String(current.name.dropFirst("graph.edit.".count)),
                    forKey: "graphDataWall")
                openWindow(id: "graphdata")
                return true
            }
            editNode = current.parent
        }
        switch armMenu.chipID(for: entity) {
        case Self.showChipID:
            // The families unfold above the chip, and fold away —
            // taking any other standing menu with them.
            openOnly(showOpen ? nil : .show)
            return true
        case Self.showCitationsChipID:
            toggleAllCitations()
            return true
        case Self.showDocumentsChipID:
            // The front EPUBs leave the room and come back; their
            // raised walls are Citations' business, not theirs.
            documentsShown.toggle()
            reload()
            updateShowChips()
            return true
        case Self.selectTopicsChipID:
            toggleSelect(.topics)
            return true
        case Self.deselectAllChipID:
            // Every selection let go, with the same semantics a hand
            // deselecting each would have.
            for kind in SelectKind.allCases where selectKindStands(kind) {
                deselectKind(kind)
            }
            for index in items.indices { items[index].isSelected = false }
            deepParentIDs = []
            focusedConceptID = nil
            focusedConceptArticleIDs = []
            selectOpen = false
            updateSelectChips()
            updateStandingChips()
            reload()
            return true
        case Self.showAllChipID:
            // Every family into the room at once.
            showEverything()
            return true
        case Self.conceptsChipID:
            toggleConcepts()
            return true
        case Self.topicsChipID:
            toggleTopics()
            return true
        // No chips stand for these since they left the arm (17 Sep
        // 2026) — a chosen card carries them itself. The acts keep
        // their place here, taking the whole selection, for the day a
        // word wants them back.
        case Self.pinChipID:
            let selected = items.filter { $0.kind == .article && $0.isSelected }
            guard !selected.isEmpty else { return true }
            for item in selected { model.togglePinned(item.id) }
            reload()
            updateStandingChips()
            return true
        case Self.setAsideChipID:
            let selected = items.filter { $0.kind == .article && $0.isSelected }
            guard !selected.isEmpty else { return true }
            for item in selected { model.toggleSetAside(item.id) }
            reload()
            updateStandingChips()
            return true
        case Self.graphsChipID:
            // Both walls together: the arm offers the family, not a side.
            setGraphsShown(!(timeflowLeftShown || timeflowRightShown))
            return true
        case Self.timelinesChipID:
            // All three lanes together, for the same reason.
            setTimelinesShown(!timelinesStand)
            return true
        case Self.onlyOverlapChipID:
            // The wall narrowed to the common ground, and back.
            onlyOverlap.toggle()
            armMenu.setChipActive(Self.onlyOverlapChipID, onlyOverlap)
            reload()
            return true
        case Self.focusChipID:
            // Show only selected items and their direct connections.
            focusMode.toggle()
            armMenu.setChipTitle(Self.focusChipID, focusMode ? "Un-Focus" : "Focus")
            armMenu.setChipActive(Self.focusChipID, focusMode)
            reload()
            return true
        case Self.selectChipID:
            // The kinds unfold above the chip, and fold away — taking
            // any other standing menu with them.
            openOnly(selectOpen ? nil : .select)
            return true
        case Self.selectCitationsChipID:
            // A choice acts and folds the menu; the chosen chip stands
            // bright, and choosing it again lets its selection go.
            toggleSelect(.citations)
            return true
        case Self.selectDocumentsChipID:
            toggleSelect(.documents)
            return true
        case Self.selectConceptsChipID:
            toggleSelect(.concepts)
            return true
        case Self.settingsChipID:
            openWindow(id: "settings")
            return true
        case Self.documentsChipID:
            openWindow(id: "library")
            return true
        case Self.introChipID:
            openIntroduction()
            return true
        case Self.alignChipID:
            // No chip stands for this at present — Frode had Align to
            // Room taken off the arm on 16 Sep. The act waits here.
            alignSpaceToRoom()
            closeWatchMenus()
            return true
        case Self.watchLayoutChipID:
            // Layout's options climb away from the arm, and fold away.
            openOnly(watchLayoutOpen ? nil : .layout)
            return true
        case LayoutFan.align.chipID, LayoutFan.distribute.chipID,
             LayoutFan.sort.chipID, LayoutFan.auto.chipID:
            // A rung of Layout's ladder: its own commands fan along
            // the arm, and opening one folds whichever stood open.
            let fan = LayoutFan.allCases.first {
                $0.chipID == armMenu.chipID(for: entity)
            }
            openLayoutFan = openLayoutFan == fan ? nil : fan
            updateWatchChips()
            return true
        case Self.gatherChipID:
            gatherNodes()
            return true
        case Self.watchSavedChipID:
            openOnly(watchSavedOpen ? nil : .saved)
            return true
        case Self.watchSaveNowChipID:
            // The arrangement kept in the first free slot; its chip
            // steps into Saved View's fan at once.
            saveCurrentView()
            return true
        case Self.watchUndoChipID:
            undoWatchArrangement()
            return true
        case Self.revealConceptsChipID:
            hiddenConceptIDs = []
            armMenu.setChipVisible(Self.revealConceptsChipID, false)
            reload()
            return true
        default:
            // The right arm's two fans: a choice acts and folds the
            // fan away, per the arm menus' convention.
            guard let id = armMenu.chipID(for: entity) else { return false }
            if id.hasPrefix(Self.watchLayoutChipID + "."),
               let option = WatchLayoutOption(
                   rawValue: String(id.dropFirst(Self.watchLayoutChipID.count + 1))) {
                runWatchLayout(option)
                closeWatchMenus()
                return true
            }
            let autoID = LayoutFan.auto.chipID
            if id.hasPrefix(autoID + "."),
               let option = WatchViewOption(
                   rawValue: String(id.dropFirst(autoID.count + 1))) {
                runWatchView(option)
                closeWatchMenus()
                return true
            }
            for slot in 1...Self.savedSlotCount where id == Self.savedViewSlotID(slot) {
                if let saved = loadSavedViews()["\(slot)"] {
                    recallSavedView(saved)
                }
                closeWatchMenus()
                return true
            }
            return false
        }
    }

    /// The guide's standing document id — `AppModel.introGuideID`,
    /// written out because IntroGuide.swift is not in this target.
    private static let introGuideDocID = "origami-text-intro"

    /// Introduction: the book that explains the place, opened in the
    /// room like any other reading — it needs no card on the wall. The
    /// guide is written by the Mac's own exporter and travels with the
    /// library; until the headset holds it, the shelf opens instead so
    /// it can be brought over.
    private func openIntroduction() {
        guard let record = model.epubRecords.first(where: {
            $0.id == Self.introGuideDocID || $0.title == "Introducing Origami Text"
        }) else {
            openWindow(id: "library")
            return
        }
        let docID = record.id
        guard !model.openDocIDs.contains(docID) else { return }
        readerPanels.open(
            docID: docID,
            at: SIMD3<Float>(0, 1.4, -1.0) + spaceShift,
            view: AnyView(
                MapReaderPanel(docID: docID, title: record.title) {
                    closeReader(docID)
                }
                .environment(model)),
            onClose: { closeReader(docID) })
        model.openDocIDs.insert(docID)
    }

    /// Every menu folded away — after a choice has acted.
    private func closeWatchMenus() {
        openOnly(nil)
    }

    /// The chits that unfold sub-items. Auto is not among them: it
    /// stands INSIDE Layout's ladder, so it folds with its parent
    /// rather than against it.
    private enum ArmFold { case select, show, layout, saved }

    /// One menu at a time, across both arms: opening a chit's
    /// sub-items folds whatever else stood open. Two lists standing at
    /// once crowded the room, and either could be a dozen chips long.
    private func openOnly(_ fold: ArmFold?) {
        selectOpen = fold == .select
        showOpen = fold == .show
        watchLayoutOpen = fold == .layout
        watchSavedOpen = fold == .saved
        // Auto lives in Layout's ladder: it cannot stand without it.
        if fold != .layout { openLayoutFan = nil }
        updateSelectChips()
        updateShowChips()
        updateWatchChips()
    }

    /// Gather: every standing card steps a fifth of the way toward the
    /// middle of the spread. Pinching again draws them in further, so
    /// the wall closes as far as the hand asks; Undo View restores the
    /// moment before the first pinch of a run.
    private func gatherNodes() {
        let cards = items.filter {
            $0.kind == .article && !$0.isAside && !$0.isGhost
                && $0.position != nil && liftedCards[$0.id] == nil
        }
        guard cards.count > 1 else { return }
        let xs = cards.compactMap { $0.position?.x }
        let ys = cards.compactMap { $0.position?.y }
        let center = SIMD2<Float>(xs.reduce(0, +) / Float(xs.count),
                                  ys.reduce(0, +) / Float(ys.count))
        // Never tighter than the Wall would stand them: 5 cm of air is
        // the floor for every automatic arrangement, this one too. A
        // spread already at that measure has nowhere left to go.
        let spanX = (xs.max() ?? 0) - (xs.min() ?? 0)
        let spanY = (ys.max() ?? 0) - (ys.min() ?? 0)
        let columns = max(1, Int((Float(cards.count) * Self.pitchAspect)
            .squareRoot().rounded()))
        let rows = (cards.count + columns - 1) / columns
        let tightest = max(
            spanX > 1e-4 ? Float(columns - 1) * Self.columnPitch / spanX : 0,
            spanY > 1e-4 ? Float(rows - 1) * Self.rowPitch / spanY : 0)
        let factor = max(0.8, tightest)
        guard factor < 1 else { return }
        var xy: [String: SIMD2<Float>] = [:]
        for card in cards {
            guard let position = card.position else { continue }
            xy[card.id] = center + (SIMD2(position.x, position.y) - center) * factor
        }
        applyWatchPositions(xy)
    }

    /// Every standing article's citation wall rises at once — or,
    /// standing, every wall retires. The arm's Show and the toolbar
    /// share this one toggle.
    private func toggleAllCitations() {
        if raisedArticleIDs.isEmpty {
            raisedArticleIDs = Set(items.filter {
                $0.kind == .article && !$0.isAside && !$0.isGhost
            }.map(\.id))
        } else {
            raisedArticleIDs = []
            deepParentIDs = []
        }
        reload()
        updateShowChips()
    }

    /// The concept space in and out; arriving concepts arrive SELECTED
    /// — one pinch-drag moves the whole family.
    private func toggleConcepts() {
        if conceptSpaceMode {
            conceptSpaceMode = false
            // The concepts leave, and any concept Focus with them.
            focusedConceptID = nil
            focusedConceptArticleIDs = []
            updateSankey()
            reload()
        } else {
            conceptLadder.close()
            conceptSpaceMode = true
            updateSankey()
            reload()
            for index in items.indices
            where items[index].kind == .concept
                && !items[index].id.hasPrefix("topic:")
                && !items[index].id.hasPrefix("float:") {
                items[index].isSelected = true
            }
        }
        armMenu.setChipActive(Self.conceptsChipID, conceptSpaceMode)
        updateShowChips()
    }

    /// The topic magnets stand or leave; arriving, they arrive
    /// selected, so one pinch-drag moves the whole row.
    private func toggleTopics() {
        topicSpaceMode.toggle()
        armMenu.setChipActive(Self.topicsChipID, topicSpaceMode)
        reload()
        if topicSpaceMode {
            for index in items.indices
            where items[index].id.hasPrefix("topic:") {
                items[index].isSelected = true
            }
        }
        updateShowChips()
    }

    /// Whether any of the floor's three lanes stands.
    private var timelinesStand: Bool {
        floorShowRaw != FloorShow.nothing.rawValue
            || floorShowMiddleRaw != FloorShow.nothing.rawValue
            || floorShowRightRaw != FloorShow.nothing.rawValue
    }

    /// Both graph walls at once — the family, not a side. Turning them
    /// away remembers nothing to restore: both come back together.
    private func setGraphsShown(_ shown: Bool) {
        timeflowLeftShown = shown
        timeflowRightShown = shown
        updateSankey()
        updateShowChips()
    }

    /// All three floor lanes at once. Going away, each lane's theme is
    /// remembered, so coming back restores what stood rather than
    /// imposing one history on all three.
    private func setTimelinesShown(_ shown: Bool) {
        if shown {
            if floorShowRaw == FloorShow.nothing.rawValue {
                floorShowRaw = floorShowLastRaw == FloorShow.nothing.rawValue
                    ? FloorShow.world.rawValue : floorShowLastRaw
            }
            if floorShowMiddleRaw == FloorShow.nothing.rawValue {
                floorShowMiddleRaw = floorShowMiddleLastRaw == FloorShow.nothing.rawValue
                    ? FloorShow.hypertext.rawValue : floorShowMiddleLastRaw
            }
            if floorShowRightRaw == FloorShow.nothing.rawValue {
                floorShowRightRaw = floorShowRightLastRaw == FloorShow.nothing.rawValue
                    ? FloorShow.computing.rawValue : floorShowRightLastRaw
            }
        } else {
            if floorShowRaw != FloorShow.nothing.rawValue { floorShowLastRaw = floorShowRaw }
            if floorShowMiddleRaw != FloorShow.nothing.rawValue {
                floorShowMiddleLastRaw = floorShowMiddleRaw
            }
            if floorShowRightRaw != FloorShow.nothing.rawValue {
                floorShowRightLastRaw = floorShowRightRaw
            }
            floorShowRaw = FloorShow.nothing.rawValue
            floorShowMiddleRaw = FloorShow.nothing.rawValue
            floorShowRightRaw = FloorShow.nothing.rawValue
        }
        updateShowChips()
    }

    /// A — every family into the room at once: the front EPUBs, their
    /// citation walls, the magnets, the floor's lanes, both graph
    /// walls, the concept row. The one command that makes the room
    /// whole again after any amount of hiding.
    private func showEverything() {
        documentsShown = true
        if !topicSpaceMode { toggleTopics() }
        if !conceptSpaceMode { toggleConcepts() }
        if raisedArticleIDs.isEmpty { toggleAllCitations() }
        setGraphsShown(true)
        setTimelinesShown(true)
        showOpen = false
        reload()
        updateShowChips()
    }

    /// Show's families shown while the chip stands open, each wearing
    /// its live standing — bright while its family is in the room.
    private func updateShowChips() {
        for id in [Self.showCitationsChipID, Self.showDocumentsChipID,
                   Self.topicsChipID, Self.timelinesChipID,
                   Self.graphsChipID, Self.conceptsChipID] {
            armMenu.setChipVisible(id, showOpen)
        }
        armMenu.setChipActive(Self.showChipID,
                              showOpen || !raisedArticleIDs.isEmpty
                                || topicSpaceMode || conceptSpaceMode
                                || !documentsShown || timelinesStand
                                || timeflowLeftShown || timeflowRightShown)
        armMenu.setChipActive(Self.showCitationsChipID, !raisedArticleIDs.isEmpty)
        armMenu.setChipActive(Self.showDocumentsChipID, documentsShown)
        armMenu.setChipActive(Self.timelinesChipID, timelinesStand)
        armMenu.setChipActive(Self.graphsChipID,
                              timeflowLeftShown || timeflowRightShown)
        // Only Overlap keeps its own reason to stand: common ground.
        armMenu.setChipVisible(Self.onlyOverlapChipID,
                               showOpen && (sharedCitedStanding || onlyOverlap))
        armMenu.setChipActive(Self.onlyOverlapChipID, onlyOverlap)
        // Reveal All Concepts hangs off Concepts, which hangs off
        // Show: folding Show takes it too, rather than leaving it
        // stranded in the air. A long-pinch asks for it again.
        if !showOpen { armMenu.setChipVisible(Self.revealConceptsChipID, false) }
    }


    // MARK: - Saved views: save and recall whole arrangements

    private var savedViewsKey: String {
        "mapSavedViews:\(model.openJournalVenue ?? "")"
    }

    private func loadSavedViews() -> [String: [String: SIMD3<Float>]] {
        guard let data = UserDefaults.standard.data(forKey: savedViewsKey),
              let views = try? JSONDecoder()
                  .decode([String: [String: SIMD3<Float>]].self, from: data)
        else { return [:] }
        return views
    }

    private func persistSavedViews() {
        guard let data = try? JSONEncoder().encode(savedViews) else { return }
        UserDefaults.standard.set(data, forKey: savedViewsKey)
    }

    /// Save View: the standing articles' places, space-relative, into
    /// the first free slot (the last slot rewrites once all are full).
    private func saveCurrentView() {
        savedViews = loadSavedViews()
        let positions = Dictionary(uniqueKeysWithValues: items.compactMap {
            item -> (String, SIMD3<Float>)? in
            guard item.kind == .article, !item.isAside, !item.isGhost,
                  let position = item.position else { return nil }
            return (item.id, position - spaceShift)
        })
        guard !positions.isEmpty else { return }
        let slot = (1...Self.savedSlotCount).first { savedViews["\($0)"] == nil }
            ?? Self.savedSlotCount
        savedViews["\(slot)"] = positions
        persistSavedViews()
        updateWatchChips()
    }

    /// A slot recalled: every remembered card returns to its saved
    /// place, and Undo View remembers the moment before.
    private func recallSavedView(_ saved: [String: SIMD3<Float>]) {
        var snapshot: [String: SIMD3<Float>] = [:]
        var moved: [EPUBMapItem] = []
        for index in items.indices {
            guard let stored = saved[items[index].id],
                  let current = items[index].position else { continue }
            snapshot[items[index].id] = current
            items[index].position = stored + spaceShift
            moved.append(items[index])
        }
        guard !moved.isEmpty else { return }
        watchUndo = snapshot
        keepPlacements(of: moved)
        reload()
        updateWatchChips()
    }

    /// The right arm's fans shown and lit to match what is open: the
    /// Layout ladder with Auto at its top, Auto's own arrangements,
    /// and the slots that actually hold a view. Undo View wears
    /// whether there is anything to undo.
    private func updateWatchChips() {
        for option in WatchLayoutOption.allCases {
            armMenu.setChipVisible(Self.watchLayoutOptionID(option),
                                   watchLayoutOpen && openLayoutFan == option.family)
        }
        for fan in LayoutFan.allCases {
            armMenu.setChipVisible(fan.chipID, watchLayoutOpen)
            armMenu.setChipActive(fan.chipID, openLayoutFan == fan)
        }
        for option in Self.offeredWatchViews {
            armMenu.setChipVisible(Self.watchViewOptionID(option),
                                   watchLayoutOpen && openLayoutFan == .auto)
        }
        let kept = Set(loadSavedViews().keys.compactMap(Int.init))
        for slot in 1...Self.savedSlotCount {
            armMenu.setChipVisible(Self.savedViewSlotID(slot),
                                   watchSavedOpen && kept.contains(slot))
        }
        armMenu.setChipActive(Self.watchLayoutChipID, watchLayoutOpen)
        armMenu.setChipActive(Self.watchSavedChipID, watchSavedOpen)
        armMenu.setChipActive(Self.watchUndoChipID, watchUndo != nil)
    }

    /// Pin and Set Aside have no chip to wear their standing since
    /// they left the arm — a chosen card carries them itself, and its
    /// own button says Pin or Unpin. What remains here: the Select
    /// kinds wear their live standing, because a hand-tapped card can
    /// complete or break a family.
    private func updateStandingChips() {
        updateSelectChips()
    }

    /// Folds and unfolds the left underside's two groups. The hidden
    /// sides take no place (the row packs over them); each parent
    /// stands active while any of its group is on, so a folded group
    /// still shows something is standing.
}

/// Marks the entities the fist carries: every card on the Map. The
/// connection lines need no mark — the engine's MovableConnectionsSystem
/// re-lays them from the cards each frame.
struct MapSpaceNodeComponent: Component {}

/// Carries the EPUBMapItem ID on each hallway card entity so that
/// SelectedCitationLines can look up live world positions by item ID.
struct EPUBNodeIDComponent: Component {
    let id: String
}

/// The card's two faces, cached at build time so the per-frame turner
/// never walks a card's subtree hunting them by name.
struct CardFacesComponent: Component {
    let front: Entity
    let back: Entity
}

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
    /// A pinch is not a fist: when the thumb tip actually touches the
    /// index tip the system pinch owns the hand. Kept tight — a fist
    /// wraps the thumb across the curled fingers, and a wider bound
    /// read real fists as pinches and refused the grab.
    private static let pinchClearance: Float = 0.02
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
            // A closed fist hides its own fingers from the cameras, so
            // joints drop out (to the origin) or stray. Untracked tips
            // don't vote, two of three carry the day, and a held fist
            // takes two open fingers to let go — one noisy joint can
            // neither refuse the grab nor spill the carry.
            let tracked = tips.filter { $0 != .zero }
            let curled: Bool
            if hands[index].isFist {
                curled = tracked.filter { distance($0, palm) >= bound }.count < 2
            } else {
                let pinching = thumb != .zero && tips[0] != .zero
                    && distance(thumb, tips[0]) < Self.pinchClearance
                curled = tracked.filter { distance($0, palm) < bound }.count >= 2
                    && !pinching
            }

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
    /// The corridor-given place the graph stands at when no wall
    /// claims it — also the pivot everything turns about when one does.
    private var basePosition = SIMD3<Float>.zero
    /// The key card's corridor place, so it can ride the graph's turn.
    private var keyBasePosition = SIMD3<Float>.zero

    /// Which side's series this wall carries — an untagged series
    /// stands on both.
    private var side: String { sideOffset < 0 ? "left" : "right" }

    /// The room wall's pose, when one has anchored on this graph's own
    /// side within a room's reach: where the graph's centre lands
    /// (projected onto the plaster, then a hand's breadth off it) and
    /// the yaw that lays the graph's plane along the wall.
    private func wallPose() -> (position: SIMD3<Float>, yaw: Float)? {
        guard let wallAnchor, wallAnchor.isAnchored else { return nil }
        let wallPoint = wallAnchor.position(relativeTo: nil)
        // A plane anchor's local Y is the plane's normal; flattened to
        // horizontal it is the wall's facing, made to point into the
        // room (toward the graph's corridor place).
        var normal = wallAnchor.convert(direction: SIMD3<Float>(0, 1, 0), to: nil)
        normal.y = 0
        let length = simd_length(normal)
        guard length > 1e-3 else { return nil }
        normal /= length
        if simd_dot(normal, basePosition - wallPoint) < 0 { normal = -normal }
        // Only a wall on this graph's own side, within a room's reach.
        let toWall = -normal
        if sideOffset < 0, toWall.x > 0.3 { return nil }
        if sideOffset > 0, toWall.x < -0.3 { return nil }
        let distance = simd_dot(basePosition - wallPoint, normal)
        guard distance < 6 else { return nil }
        let position = basePosition - normal * distance + normal * 0.05
        // At rest the plot's front face reads down +X; on the wall it
        // should read along the plaster — the left graph's front into
        // the room, the right graph keeping its back face to the room
        // as it does in the corridor.
        let facing = sideOffset < 0 ? normal : -normal
        let yaw = atan2(-facing.z, facing.x)
        return (position, yaw)
    }

    /// Whether the graph currently stands on a wall — so leaving the
    /// snap (or losing the wall) restores the corridor place ONCE.
    /// Off the wall, the per-frame settle must leave the graph alone:
    /// between updates its position belongs to the fist-carry, and a
    /// frame-by-frame reset would pin the graph while the room moves.
    private var standsOnWall = false

    /// The graph keeps to the room's wall while the option is on —
    /// laid flat along the plaster, turned to its angle — and to its
    /// corridor place otherwise; the key and the cylinders step and
    /// turn with it, pivoting about the graph's centre.
    private func settleToWall() {
        guard let entity else { return }
        guard snapsToWall, let pose = wallPose() else {
            if standsOnWall {
                standsOnWall = false
                entity.position = basePosition
                entity.orientation = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
                keyEntity?.position = keyBasePosition
                if let cylinders {
                    cylinders.orientation = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
                    cylinders.position = .zero
                }
            }
            return
        }
        standsOnWall = true
        let goal = pose.position
        let turn = simd_quatf(angle: pose.yaw, axis: SIMD3<Float>(0, 1, 0))
        guard simd_length(entity.position - goal) > 0.005
                || abs(simd_dot(entity.orientation.vector, turn.vector)) < 0.99995 else { return }
        entity.position = goal
        entity.orientation = turn
        // The key swings with the graph's near end but keeps facing
        // the walker — a turned card would read edge-on.
        keyEntity?.position = goal + turn.act(keyBasePosition - basePosition)
        // The tubes' points live at world coordinates inside their
        // holder: orient the holder and place it so the whole run
        // pivots about the graph's centre.
        if let cylinders {
            cylinders.orientation = turn
            cylinders.position = goal - turn.act(basePosition)
        }
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
        // The rebuilt entities stand at the corridor place; the next
        // frame's settle walks them to the wall if one still claims it.
        standsOnWall = false
        basePosition = SIMD3<Float>(
            citedSpace.origin.x + sideOffset,
            Self.height,
            citedSpace.origin.z - citedSpace.depth / 2) + shift
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
        holder.position = basePosition
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
            // The key itself is the door to this graph's data dialog:
            // tap the legend to edit what the graph is based on. Named
            // for the tap handler; the collision box wears the card's
            // own size (image points × the 0.001 ratio).
            keyHolder.name = "graph.edit.\(side)"
            keyHolder.components.set(CollisionComponent(
                shapes: [.generateBox(size: SIMD3<Float>(
                    Float(keyImage.size.width) * 0.001,
                    Float(keyImage.size.height) * 0.001,
                    0.02))]))
            keyHolder.components.set(InputTargetComponent())
            keyHolder.components.set(HoverEffectComponent())
            keyBasePosition = SIMD3<Float>(
                citedSpace.origin.x + sideOffset,
                Self.height,
                citedSpace.origin.z + 0.06) + shift
            keyHolder.position = keyBasePosition
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
        // The system window bar's grammar, and ONLY the circle. Not a
        // Button: a plain-styled button still earns the system's glass
        // plate on visionOS — a tap gesture with its own hover effect
        // draws nothing but what we ask: a touch larger under the
        // gaze, a touch quieter when not.
        ZStack {
            Circle()
                .fill(.white.opacity(0.25))
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
        }
        .frame(width: 30, height: 30)
        .contentShape(.circle)
        .hoverEffect { effect, isActive, _ in
            effect
                .opacity(isActive ? 1 : 0.6)
                .scaleEffect(isActive ? 1.15 : 1)
        }
        .onTapGesture(perform: onClose)
        // Breathing room for the gaze growth: the attachment renders
        // exactly its bounds, so without this margin the grown circle
        // crops at the edges. Padding draws nothing — no plate.
        .padding(6)
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
        // Where the card stood — the close flies the reading home.
        origins[docID] = position
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
        origins[docID] = nil
        closing.remove(docID)
    }

    /// Where each reading opened — the card's place, and the close's
    /// destination.
    private var origins: [String: SIMD3<Float>] = [:]
    /// Panels mid-flight home, so a second ✕ doesn't double the close.
    private var closing: Set<String> = []

    /// The close with its story told: the panel shrinks and flies back
    /// to where its card stood, and the card settles with a brief squeeze.
    func closeAnimated(docID: String, onClosed: @escaping @MainActor () -> Void) {
        guard let root = roots[docID], !closing.contains(docID) else { return }
        closing.insert(docID)
        var transform = root.transform
        transform.translation = origins[docID] ?? root.position
        transform.scale = SIMD3<Float>(repeating: 0.03)
        root.move(to: transform, relativeTo: nil,
                  duration: 0.32, timingFunction: .easeIn)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(340))
            guard let self else { return }
            self.close(docID: docID)
            onClosed()   // the card returns with the reload
            // A beat for the card to stand again, then the settle.
            try? await Task.sleep(for: .milliseconds(80))
            self.shrink(self.cardEntity(for: docID))
        }
    }

    private typealias MapItemComponent =
        NodeImmersiveView<[EPUBMapItem], AnyView, AnyView>.ItemComponent<EPUBMapItem>

    /// The engine-owned card for a document, found by its item.
    private func cardEntity(for docID: String) -> Entity? {
        guard let content else { return nil }
        return content.entities.first {
            $0.components[MapItemComponent.self]?.item.id == docID
        }
    }

    /// The settle: the card squeezes down slightly then springs back to rest.
    private func shrink(_ entity: Entity?) {
        guard let entity else { return }
        let rest = entity.transform
        var small = rest
        small.scale = rest.scale * 0.88
        entity.move(to: small, relativeTo: entity.parent,
                    duration: 0.1, timingFunction: .easeOut)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(105))
            entity.move(to: rest, relativeTo: entity.parent,
                        duration: 0.18, timingFunction: .easeOut)
        }
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

    /// World-space centre of the panel root for the given document,
    /// or nil if the panel is not currently installed.
    func worldPosition(of docID: String) -> SIMD3<Float>? {
        roots[docID]?.position(relativeTo: nil)
    }

    /// World-space TOP edge of the panel — half the panel's real-world
    /// height (~0.30m) above its centre — for line attachments.
    func worldTopPosition(of docID: String) -> SIMD3<Float>? {
        guard let center = roots[docID]?.position(relativeTo: nil) else { return nil }
        return center + SIMD3<Float>(0, 0.30, 0)
    }
}

/// Draws faint lines from each open reader panel to the hallway cards
/// it cites. Separate from the engine's connection system so the
/// panel-to-wall direction reads distinctly and needs no selection gate.
@MainActor
private final class CitationLineManager {
    private var root: Entity?
    private var lineEntities: [String: ModelEntity] = [:]

    func install(in content: RealityViewContent) {
        let r = Entity()
        content.add(r)
        root = r
    }

    /// Replaces the full line set for the current open docs × cited
    /// items, placing each line in the same pass as creation.
    func rebuild(docCitations: [String: Set<String>],
                 items: [EPUBMapItem],
                 readerPanels: ReaderPanels,
                 readingDeskDocID: String?) {
        guard let root else { return }
        for line in lineEntities.values { line.removeFromParent() }
        lineEntities = [:]
        guard readingDeskDocID == nil else { return }
        let itemPos = Dictionary(uniqueKeysWithValues: items.compactMap { item in
            item.position.map { (item.id, $0) }
        })
        for (docID, citedIDs) in docCitations {
            guard let panelPos = readerPanels.worldTopPosition(of: docID) else { continue }
            for hallwayID in citedIDs {
                guard let wallPos = itemPos[hallwayID] else { continue }
                let key = "\(docID)∥\(hallwayID)"
                let line = makeLineEntity()
                positionLine(line, from: panelPos, to: wallPos)
                root.addChild(line)
                lineEntities[key] = line
            }
        }
    }

    /// Repositions existing lines without recreating entities — called
    /// when panel poses change or items update their positions.
    func updatePositions(docCitations: [String: Set<String>],
                         items: [EPUBMapItem],
                         readerPanels: ReaderPanels) {
        let itemPos = Dictionary(uniqueKeysWithValues: items.compactMap { item in
            item.position.map { (item.id, $0) }
        })
        for (key, line) in lineEntities {
            let parts = key.components(separatedBy: "∥")
            guard parts.count == 2,
                  let panelPos = readerPanels.worldTopPosition(of: parts[0]),
                  let wallPos = itemPos[parts[1]] else {
                line.isEnabled = false
                continue
            }
            positionLine(line, from: panelPos, to: wallPos)
        }
    }

    private func makeLineEntity() -> ModelEntity {
        var mat = UnlitMaterial()
        mat.color = .init(tint: UIColor(red: 0.55, green: 0.35, blue: 0.85, alpha: 0.22))
        return ModelEntity(
            mesh: .generateBox(size: SIMD3<Float>(1.0, 0.003, 0.003)),
            materials: [mat])
    }

    private func positionLine(_ entity: ModelEntity,
                              from a: SIMD3<Float>, to b: SIMD3<Float>) {
        let diff = b - a
        let dist = simd_length(diff)
        guard dist > 0.05 else { entity.isEnabled = false; return }
        entity.isEnabled = true
        entity.position = (a + b) / 2
        entity.scale = SIMD3<Float>(dist, 1, 1)
        let norm = diff / dist
        let dot = simd_dot(SIMD3<Float>(1, 0, 0), norm)
        let cross = simd_cross(SIMD3<Float>(1, 0, 0), norm)
        let crossLen = simd_length(cross)
        entity.orientation = crossLen < 1e-6
            ? simd_quatf(angle: dot < 0 ? Float.pi : 0, axis: SIMD3<Float>(0, 1, 0))
            : simd_quatf(angle: acos(max(-1, min(1, dot))),
                         axis: simd_normalize(cross))
    }
}

/// Per-document colored lines drawn from each selected article to every
/// shared citation (3+ selected). Lines follow cards live each frame
/// by querying EPUBNodeIDComponent world positions.
@MainActor
private final class SelectedCitationLines: MapLineLayer {
    private var root: Entity?

    private struct LineData {
        let line: ModelEntity
        let fromID: String
        let toID: String
    }
    private var lineData: [LineData] = []

    static let palette: [UIColor] = [
        UIColor(red: 0.20, green: 0.75, blue: 0.30, alpha: 0.45),
        UIColor(red: 0.20, green: 0.45, blue: 0.90, alpha: 0.45),
        UIColor(red: 0.90, green: 0.80, blue: 0.10, alpha: 0.45),
        UIColor(red: 0.55, green: 0.55, blue: 0.55, alpha: 0.45),
        UIColor(red: 0.88, green: 0.20, blue: 0.20, alpha: 0.45),
    ]

    func install(in content: RealityViewContent) {
        EPUBNodeIDComponent.registerComponent()
        let r = Entity()
        content.add(r)
        root = r
    }

    func rebuild(items: [EPUBMapItem]) {
        guard let root else { return }
        for data in lineData { data.line.removeFromParent() }
        lineData = []

        let articles = items.filter { $0.kind == .article && $0.isSelected }
        guard articles.count >= 2 else { return }
        let shared = items.filter { $0.isShared }
        guard !shared.isEmpty else { return }

        for (idx, article) in articles.enumerated() {
            guard let fromPos = article.position else { continue }
            let color = Self.palette[idx % Self.palette.count]
            for citation in shared {
                guard article.citedIDs.contains(citation.id),
                      let toPos = citation.position else { continue }
                let line = makeLine(from: fromPos, to: toPos, color: color)
                root.addChild(line)
                lineData.append(LineData(line: line, fromID: article.id, toID: citation.id))
            }
        }
    }

    var needsPositions: Bool { !lineData.isEmpty }

    func relayout(positions: [String: SIMD3<Float>]) {
        for data in lineData {
            guard let from = positions[data.fromID],
                  let to = positions[data.toID] else { continue }
            positionLine(data.line, from: from, to: to)
        }
    }

    private func positionLine(_ line: ModelEntity,
                               from: SIMD3<Float>, to: SIMD3<Float>) {
        let diff = to - from
        let dist = simd_length(diff)
        guard dist > 0.01 else { line.isEnabled = false; return }
        line.isEnabled = true
        line.position = (from + to) / 2
        line.scale = SIMD3<Float>(dist, 1, 1)
        let norm = diff / dist
        let dot = simd_dot(SIMD3<Float>(1, 0, 0), norm)
        let cross = simd_cross(SIMD3<Float>(1, 0, 0), norm)
        let crossLen = simd_length(cross)
        line.orientation = crossLen < 1e-6
            ? simd_quatf(angle: dot < 0 ? Float.pi : 0, axis: SIMD3<Float>(0, 1, 0))
            : simd_quatf(angle: acos(max(-1, min(1, dot))), axis: simd_normalize(cross))
    }

    private func makeLine(from: SIMD3<Float>, to: SIMD3<Float>,
                          color: UIColor) -> ModelEntity {
        var mat = UnlitMaterial()
        mat.color = .init(tint: color)
        mat.blending = .transparent(opacity: 1.0)
        let line = ModelEntity(
            mesh: .generateBox(size: SIMD3<Float>(1.0, 0.003, 0.003)),
            materials: [mat])
        positionLine(line, from: from, to: to)
        return line
    }
}

// MARK: - Card faces

/// Turns each card's readable side to the reader. Every card carries a
/// front and a back face, and both are live glass — see-through, so
/// with the pair lit the far text ghosts through the near, mirrored.
/// Head pose from world tracking picks the side facing the viewer each
/// frame; the other goes dark. Without a head pose (simulator, tracking
/// not yet running) the fronts stand alone — cardEntity wakes every
/// back face disabled.
@MainActor
final class CardFaceTurner {
    static let frontName = "card.face.front"
    static let backName = "card.face.back"

    private let session = ARKitSession()
    private let worldTracking = WorldTrackingProvider()
    private var started = false

    func install() {
        // One session per instance: a second install (the space
        // remade around the same @State) must not run ARKit twice.
        guard !started else { return }
        started = true
        CardFacesComponent.registerComponent()
        guard WorldTrackingProvider.isSupported else {
            print("Map/faces: world tracking unsupported — back faces stay dark")
            return
        }
        Task { [session, worldTracking] in
            do {
                try await session.run([worldTracking])
            } catch {
                print("Map/faces: world tracking failed to run: \(error)")
            }
        }
    }

    /// The viewer's place, when world tracking offers one — without it
    /// (simulator, tracking not yet running) the fronts stand alone.
    func headPosition() -> SIMD3<Float>? {
        guard worldTracking.state == .running,
              let device = worldTracking.queryDeviceAnchor(
                atTimestamp: CACurrentMediaTime())
        else { return nil }
        let column = device.originFromAnchorTransform.columns.3
        return SIMD3<Float>(column.x, column.y, column.z)
    }

    /// One card's turn, its world position handed in by the shared
    /// sweep; the faces come from the component cached at build.
    func turn(card: Entity, at position: SIMD3<Float>, head: SIMD3<Float>) {
        guard let faces = card.components[CardFacesComponent.self] else { return }
        let forward = card.orientation(relativeTo: nil)
            .act(SIMD3<Float>(0, 0, 1))
        let d = simd_dot(forward, head - position)
        // A dead band about the card's plane: standing edge-on, the
        // lit side holds rather than flickering with every sway.
        let facing: Bool
        if d > 0.05 { facing = true }
        else if d < -0.05 { facing = false }
        else { return }
        if faces.front.isEnabled != facing { faces.front.isEnabled = facing }
        if faces.back.isEnabled == facing { faces.back.isEnabled = !facing }
    }
}

/// One face of the shared per-frame sweep: a line layer that wants the
/// cards' world positions whenever it has lines to lay.
@MainActor
private protocol MapLineLayer: AnyObject {
    var needsPositions: Bool { get }
    func relayout(positions: [String: SIMD3<Float>])
}

/// The single per-frame sweep over the cards. The face turner and the
/// three line layers each used to run their own full-scene query every
/// frame — folded here into one query whose one pass feeds them all.
@MainActor
private final class MapCardTick {
    private var subscription: EventSubscription?
    private var faceTurner: CardFaceTurner?
    private var lines: [MapLineLayer] = []
    private var anyLifted: (@MainActor () -> Bool)?
    private var liftedFacesHead: (@MainActor (String) -> Bool)?
    private let cardQuery = EntityQuery(where: .has(EPUBNodeIDComponent.self))

    func install(in content: RealityViewContent,
                 faceTurner: CardFaceTurner,
                 lines: [MapLineLayer],
                 anyLifted: @escaping @MainActor () -> Bool,
                 liftedFacesHead: @escaping @MainActor (String) -> Bool) {
        self.faceTurner = faceTurner
        self.lines = lines
        self.anyLifted = anyLifted
        self.liftedFacesHead = liftedFacesHead
        subscription = content.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            MainActor.assumeIsolated { self?.tick(scene: event.scene) }
        }
    }

    private func tick(scene: RealityKit.Scene) {
        let head = faceTurner?.headPosition()
        let liveLines = lines.filter { $0.needsPositions }
        let lifted = anyLifted?() ?? false
        guard head != nil || !liveLines.isEmpty || lifted else { return }
        var positions: [String: SIMD3<Float>] = [:]
        let upright = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        for card in scene.performQuery(cardQuery) {
            let place = card.position(relativeTo: nil)
            if let head { faceTurner?.turn(card: card, at: place, head: head) }
            guard let id = card.components[EPUBNodeIDComponent.self]?.id
            else { continue }
            if !liveLines.isEmpty { positions[id] = place }
            // The lifted cards billboard at the node — collision and
            // face together — while every other card stands upright
            // (which also rights a card just put back).
            if lifted, liftedFacesHead?(id) == true, let head {
                let toHead = head - place
                if simd_length(SIMD2(toHead.x, toHead.z)) > 1e-4 {
                    let turn = simd_quatf(angle: atan2(toHead.x, toHead.z),
                                          axis: SIMD3<Float>(0, 1, 0))
                    if abs(simd_dot(card.orientation.vector, turn.vector)) < 0.99995 {
                        card.orientation = turn
                    }
                }
            } else if abs(simd_dot(card.orientation.vector, upright.vector)) < 0.99995 {
                card.orientation = upright
            }
        }
        for layer in liveLines { layer.relayout(positions: positions) }
    }
}

// MARK: - Layout persistence

/// Saves and loads every card's 3D position across app restarts.
/// Stored in Application Support alongside the Knowledge Space layout.
nonisolated enum EPUBMapLayoutStore {
    private struct LayoutFile: Codable {
        struct Node: Codable {
            var id: String
            var x: Float; var y: Float; var z: Float
        }
        var nodes: [Node]
    }

    private static var fileURL: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(
            at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("EPUBMapLayout.json")
    }

    static func load() -> [String: SIMD3<Float>] {
        guard let data = try? Data(contentsOf: fileURL),
              let file = try? JSONDecoder().decode(LayoutFile.self, from: data)
        else { return [:] }
        return Dictionary(uniqueKeysWithValues:
            file.nodes.map { ($0.id, SIMD3<Float>($0.x, $0.y, $0.z)) })
    }

    static func save(_ positions: [String: SIMD3<Float>],
                     community folder: URL? = nil,
                     sharedKeys: [String: String] = [:]) {
        let nodes = positions.sorted { $0.key < $1.key }.map {
            LayoutFile.Node(id: $0.key, x: $0.value.x, y: $0.value.y, z: $0.value.z)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(LayoutFile(nodes: nodes)) else { return }
        try? data.write(to: fileURL, options: .atomic)
        // The plane's X and Y travel to the flat maps on the Mac and
        // the iPad, keyed by the book's community-file identity —
        // internal record ids differ between devices' import histories.
        // Cards without a key (citations, concepts) stay the room's own;
        // Z stays the room's own throughout.
        var updates: [String: EPUBMapSharedLayout.Point] = [:]
        for (id, position) in positions {
            if let key = sharedKeys[id] {
                updates[key] = EPUBMapSharedLayout.Point(
                    x: Double(position.x), y: Double(position.y))
            }
        }
        guard !updates.isEmpty else { return }
        EPUBMapSharedLayout.save(updating: updates, community: folder)
    }
}

// MARK: - Concept connection lines

/// Thin lines from each visible concept card to the article(s) it was
/// extracted from. Rebuilt whenever the items array changes; positions
/// track live each frame via EPUBNodeIDComponent.
@MainActor
private final class ConceptConnectionLines: MapLineLayer {
    private var root: Entity?
    private struct LineData { let line: ModelEntity; let fromID: String; let toID: String }
    private var lineData: [LineData] = []

    private static let lineColor = UIColor(red: 0.55, green: 0.60, blue: 1.0, alpha: 0.35)

    func install(in content: RealityViewContent) {
        let r = Entity(); content.add(r); root = r
    }

    /// Draws one line per edge — the caller resolves which nodes a
    /// selected concept touches (by text mention, since the AI
    /// analyses' sourceDocIDs stand empty on this corpus).
    func rebuild(items: [EPUBMapItem], edges: [(from: String, to: String)]) {
        guard let root else { return }
        for data in lineData { data.line.removeFromParent() }
        lineData = []

        var positions: [String: SIMD3<Float>] = [:]
        for item in items {
            if let pos = item.position { positions[item.id] = pos }
        }
        for edge in edges {
            guard let fromPos = positions[edge.from],
                  let toPos = positions[edge.to] else { continue }
            let line = makeLine(from: fromPos, to: toPos)
            root.addChild(line)
            lineData.append(LineData(line: line, fromID: edge.from, toID: edge.to))
        }
    }

    var needsPositions: Bool { !lineData.isEmpty }

    func relayout(positions: [String: SIMD3<Float>]) {
        for data in lineData {
            guard let from = positions[data.fromID],
                  let to = positions[data.toID] else { continue }
            positionLine(data.line, from: from, to: to)
        }
    }

    private func positionLine(_ line: ModelEntity,
                              from: SIMD3<Float>, to: SIMD3<Float>) {
        let diff = to - from
        let dist = simd_length(diff)
        guard dist > 0.01 else { line.isEnabled = false; return }
        line.isEnabled = true
        line.position = (from + to) / 2
        line.scale = SIMD3<Float>(dist, 1, 1)
        let norm = diff / dist
        let dot = simd_dot(SIMD3<Float>(1, 0, 0), norm)
        let cross = simd_cross(SIMD3<Float>(1, 0, 0), norm)
        let crossLen = simd_length(cross)
        line.orientation = crossLen < 1e-6
            ? simd_quatf(angle: dot < 0 ? Float.pi : 0, axis: SIMD3<Float>(0, 1, 0))
            : simd_quatf(angle: acos(max(-1, min(1, dot))), axis: simd_normalize(cross))
    }

    private func makeLine(from: SIMD3<Float>, to: SIMD3<Float>) -> ModelEntity {
        var mat = UnlitMaterial()
        mat.color = .init(tint: Self.lineColor)
        mat.blending = .transparent(opacity: 1.0)
        let line = ModelEntity(
            mesh: .generateBox(size: SIMD3<Float>(1.0, 0.002, 0.002)),
            materials: [mat])
        positionLine(line, from: from, to: to)
        return line
    }
}

/// Amber lines from a selected citation card to the deep works it cites.
/// Mirrors ConceptConnectionLines — same EPUBNodeIDComponent live-tracking.
@MainActor
private final class CitedToDeepLines: MapLineLayer {
    private var root: Entity?
    private struct LineData { let line: ModelEntity; let fromID: String; let toID: String }
    private var lineData: [LineData] = []

    private static let lineColor = UIColor(red: 1.0, green: 0.72, blue: 0.3, alpha: 0.08)

    func install(in content: RealityViewContent) {
        let r = Entity(); content.add(r); root = r
    }

    func rebuild(items: [EPUBMapItem]) {
        guard let root else { return }
        for data in lineData { data.line.removeFromParent() }
        lineData = []

        // Index all item positions by ID for O(1) lookup.
        var posMap: [String: SIMD3<Float>] = [:]
        for item in items {
            if let pos = item.position { posMap[item.id] = pos }
        }

        // For each selected citation, draw a line to each deep work it cites.
        for item in items where item.kind == .cited && item.isSelected {
            guard let fromPos = posMap[item.id] else { continue }
            for deepID in item.citedIDs {
                guard let toPos = posMap[deepID] else { continue }
                let line = makeLine(from: fromPos, to: toPos)
                root.addChild(line)
                lineData.append(LineData(line: line, fromID: item.id, toID: deepID))
            }
        }
    }

    var needsPositions: Bool { !lineData.isEmpty }

    func relayout(positions: [String: SIMD3<Float>]) {
        for data in lineData {
            guard let from = positions[data.fromID],
                  let to = positions[data.toID] else { continue }
            positionLine(data.line, from: from, to: to)
        }
    }

    private func positionLine(_ line: ModelEntity,
                              from: SIMD3<Float>, to: SIMD3<Float>) {
        let diff = to - from
        let dist = simd_length(diff)
        guard dist > 0.01 else { line.isEnabled = false; return }
        line.isEnabled = true
        line.position = (from + to) / 2
        line.scale = SIMD3<Float>(dist, 1, 1)
        let norm = diff / dist
        let dot = simd_dot(SIMD3<Float>(1, 0, 0), norm)
        let cross = simd_cross(SIMD3<Float>(1, 0, 0), norm)
        let crossLen = simd_length(cross)
        line.orientation = crossLen < 1e-6
            ? simd_quatf(angle: dot < 0 ? Float.pi : 0, axis: SIMD3<Float>(0, 1, 0))
            : simd_quatf(angle: acos(max(-1, min(1, dot))), axis: simd_normalize(cross))
    }

    private func makeLine(from: SIMD3<Float>, to: SIMD3<Float>) -> ModelEntity {
        var mat = UnlitMaterial()
        mat.color = .init(tint: Self.lineColor)
        mat.blending = .transparent(opacity: 1.0)
        let line = ModelEntity(
            mesh: .generateBox(size: SIMD3<Float>(1.0, 0.002, 0.002)),
            materials: [mat])
        positionLine(line, from: from, to: to)
        return line
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
/// A spatial note opened for writing, standing where the note stands:
/// the words to type, and the microphone to speak them instead. The
/// system keyboard carries its own dictation key; Dictate is here as
/// well because a note in a room is often made with both hands full.
///
/// Nothing is kept until Done — except a deletion, which is at once.
struct SpatialNotePanel: View {
    let note: SpatialNotes.Note
    let write: (String) -> Void
    let remove: () -> Void
    let onClose: () -> Void

    @State private var draft: String = ""
    @State private var dictation = SpatialNoteDictation()
    @State private var started = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Note")
                    .font(.headline)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonBorderShape(.circle)
            }
            TextEditor(text: $draft)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.08)))
                .frame(minHeight: 180)
            if let trouble = dictation.trouble {
                Text(trouble)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button {
                    if dictation.isListening {
                        dictation.stop()
                    } else {
                        // The words arrive as they are heard, appended
                        // to whatever is already written.
                        dictation.start(appendingTo: draft) { draft = $0 }
                    }
                } label: {
                    Label(dictation.isListening ? "Stop" : "Dictate",
                          systemImage: dictation.isListening
                              ? "stop.circle" : "mic")
                }
                .buttonStyle(.bordered)
                .tint(dictation.isListening ? .red : nil)
                Spacer()
                Button("Delete", role: .destructive) {
                    dictation.stop()
                    remove()
                }
                Button("Done") {
                    dictation.stop()
                    write(draft)
                    onClose()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(width: 440)
        .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 24))
        .onAppear {
            // The panel may be rebuilt as the room refreshes; the words
            // already typed must not be thrown away by that.
            guard !started else { return }
            started = true
            draft = note.text
        }
        .onDisappear { dictation.stop() }
    }
}

/// Speech to text for a note: the microphone's words, on device when
/// the hardware allows it. Nothing is recorded or kept — the audio
/// goes straight to the recogniser and the words to the draft.
@MainActor @Observable final class SpatialNoteDictation {
    private(set) var isListening = false
    /// What to tell the reader when the microphone cannot be had.
    private(set) var trouble: String?

    private var recogniser: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let engine = AVAudioEngine()

    func start(appendingTo existing: String,
               onWords: @escaping (String) -> Void) {
        guard !isListening else { return }
        trouble = nil
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                guard status == .authorized else {
                    self.trouble = "Speech recognition is not allowed. "
                        + "The keyboard's own microphone key still dictates."
                    return
                }
                self.listen(appendingTo: existing, onWords: onWords)
            }
        }
    }

    private func listen(appendingTo existing: String,
                        onWords: @escaping (String) -> Void) {
        let recogniser = SFSpeechRecognizer()
        guard let recogniser, recogniser.isAvailable else {
            trouble = "No speech recogniser is available for this language."
            return
        }
        self.recogniser = recogniser
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // On device when the hardware can: the words never leave.
        request.requiresOnDeviceRecognition = recogniser.supportsOnDeviceRecognition
        self.request = request

        let stem = existing.isEmpty ? "" : existing + "\n"
        task = recogniser.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                if let result {
                    onWords(stem + result.bestTranscription.formattedString)
                }
                if error != nil || result?.isFinal == true { self?.stop() }
            }
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
            isListening = true
        } catch {
            trouble = "The microphone could not be started."
            stop()
        }
    }

    func stop() {
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isListening = false
    }
}

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
        if isDesk {
            // On the desk the panel wears the chosen theme, whole —
            // one continuous sheet of the theme's page, its light or
            // dark throughout the words. (The Horizontal curve, with
            // its per-column glass, belongs to the room.)
            panel
                .background(RoundedRectangle(cornerRadius: 24).fill(theme.page))
                .environment(\.colorScheme, theme.scheme)
        } else if isHorizontal {
            // Horizontal in the room curves its columns, each wearing
            // its own glass inside the reader — the panel adds no flat
            // slab for the text to stick out of.
            panel
        } else {
            panel
                .glassBackgroundEffect()
        }
    }

    /// Whether the panel stands as separate floating pieces (the
    /// room's curved Horizontal) rather than one dressed sheet.
    private var isLoose: Bool { isHorizontal && !isDesk }

    private var panel: some View {
        VStack(spacing: isLoose ? 12 : 0) {
            headerBar
            if !isLoose {
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
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        if isLoose {
            bar
                .frame(maxWidth: 900)
                .glassBackgroundEffect(in: .rect(cornerRadius: 18))
        } else {
            bar
        }
    }
}

// No #Preview for this card: Xcode's preview agent cannot launch this
// app — the JIT executor times out after 15 s and the blank executor
// stub traps (PreviewsInjection/JITExecutorWaiter.swift:83), which only
// fills the crash reporter. Checked 17 Sep 2026.

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
        // Paper, and paper alone: white, wholly opaque, black ink. A
        // record has to read over any room standing behind it, at any
        // brightness — glass and white-on-dark both gave way to the
        // corridor. The light scheme carries the ink: the secondary
        // and tertiary greys resolve against it, so the byline and the
        // DOI stay quiet without going pale.
        .foregroundStyle(.black)
        .environment(\.colorScheme, .light)
        .background(RoundedRectangle(cornerRadius: 24).fill(Color.white))
        .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 24),
                               displayMode: .never)
    }
}

/// What lies written on the physical floor — a themed history, or
/// nothing. Chosen in Time Data. The world theme keeps the raw value
/// "history", so the setting from before themes still reads.
/// Light paper or dark paper — chosen in Graph Data.
enum VisionTheme: String, CaseIterable, Identifiable {
    case light
    case dark
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

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
    /// Which side of the corridor the band lies on — two timelines
    /// can share the floor, one per arm.
    private let sideOffset: Float
    /// The room's actual floor: a floor-classified plane on the arm
    /// menu's own tracking session — never a second session.
    private var floorAnchor: AnchorEntity?
    private var snapTick: EventSubscription?

    init(sideOffset: Float = 0) {
        self.sideOffset = sideOffset
    }

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
        guard let entity else { return }
        // Pinned every frame: the fist may carry the space, but the
        // band never leaves the floor — the world origin's level
        // standing in until the real floor resolves.
        let target = (floorY() ?? 0) + Self.height
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

        // 1000pt per metre so every year maps to its exact world depth,
        // at 1x scale so the texture height stays within Metal limits
        // (max depth 12m → 12 000 px, comfortably below the 16 384 cap).
        // No Z-scaling on the holder keeps the text crisp and square.
        let faceHeight = CGFloat(citedSpace.depth) * 1000
        let face = FloorHistoryView(history: history,
                                    newest: years.newest, oldest: years.oldest,
                                    sideOffset: sideOffset)
            .frame(width: Self.faceWidth, height: faceHeight)
        let renderer = ImageRenderer(content: face)
        renderer.scale = 1
        renderer.isOpaque = false
        guard let image = renderer.uiImage,
              let plane = ModelEntity.texturedPlane(with: image, ratio: 0.001)
        else { return }

        plane.components.set(MapSpaceNodeComponent())
        // Laid flat, face up; image top = oldest year = far end.
        plane.orientation = simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(1, 0, 0))
        let holder = ModelEntity()
        holder.components.set(MapSpaceNodeComponent())
        holder.addChild(plane)
        // The fist carries the band sideways and along the corridor
        // only — its height is the floor's, never the carry's.
        holder.position = SIMD3<Float>(
            citedSpace.origin.x + sideOffset + shift.x,
            floorY().map { $0 + Self.height } ?? Self.height,
            citedSpace.origin.z - citedSpace.depth / 2 + shift.z)
        content.add(holder)
        entity = holder
    }
}

/// Decade rules spanning the floor from graph to graph: one line
/// across the corridor at every tenth year's depth, tying the two
/// Timeflows and the floor timelines to one calendar. Floor-pinned
/// like the bands — the fist slides them, never lifts them.
@MainActor
final class FloorDecadeLines {
    private var content: RealityViewContent?
    private var holder: Entity?
    private var floorAnchor: AnchorEntity?
    private var snapTick: EventSubscription?
    /// Full width: past the outer band edges (bands reach ±1.45 from centre).
    private static let halfSpan: Float = 1.55
    /// A whisper above the carpet — beneath the bands and their
    /// words, which lie at 0.01.
    private static let height: Float = 0.003

    func install(in content: RealityViewContent) {
        self.content = content
        let floor = AnchorEntity(.plane(.horizontal, classification: .floor,
                                        minimumBounds: SIMD2<Float>(1, 1)))
        content.add(floor)
        floorAnchor = floor
        snapTick = content.subscribe(to: SceneEvents.Update.self) { [weak self] _ in
            MainActor.assumeIsolated { self?.snapToFloor() }
        }
    }

    private func floorY() -> Float? {
        guard let floorAnchor, floorAnchor.isAnchored else { return nil }
        let y = floorAnchor.position(relativeTo: nil).y
        return (-0.6...0.6).contains(y) ? y : nil
    }

    private func snapToFloor() {
        guard let holder else { return }
        let target = (floorY() ?? 0) + Self.height
        if abs(holder.position.y - target) > 0.005 {
            holder.position.y = target
        }
    }

    func update(years: (newest: Int, oldest: Int)?,
                citedSpace: EPUBMapView.CitedSpace,
                shift: SIMD3<Float>) {
        holder?.removeFromParent()
        holder = nil
        guard let content, let years, years.newest > years.oldest else { return }
        let span = Float(years.newest - years.oldest)
        // Every decade — thinned to whole tens when a long span would
        // rule the floor into a grate.
        let step = max(10, Int((Double(span) / 400).rounded(.up)) * 10)
        let root = Entity()
        root.components.set(MapSpaceNodeComponent())
        var material = UnlitMaterial()
        material.color = .init(tint: UIColor(white: 0.25, alpha: 0.02))
        let mesh = MeshResource.generateBox(
            size: SIMD3<Float>(Self.halfSpan * 2, 0.001, 0.004))
        let firstDecade = (years.oldest / 10 + 1) * 10
        for year in stride(from: firstDecade, through: years.newest, by: step) {
            let line = ModelEntity(mesh: mesh, materials: [material])
            let agePlace = Float(years.newest - year) / span
            line.position = SIMD3<Float>(
                0, 0, citedSpace.z(agePlace: agePlace) + shift.z)
            root.addChild(line)
        }
        root.position = SIMD3<Float>(
            citedSpace.origin.x + shift.x, Self.height, 0)
        content.add(root)
        holder = root
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
    // Negative = left band, 0 = centre band, positive = right band.
    var sideOffset: Float = -1

    var body: some View {
        Canvas { context, size in
            let span = CGFloat(newest - oldest)
            guard span > 0 else { return }
            func y(_ year: Int) -> CGFloat {
                size.height * CGFloat(year - oldest) / span
            }

            // Decade rule lines.
            let firstDecade = (oldest / 10 + 1) * 10
            // Year labels sit on the OUTSIDE edge of each band (away from
            // the corridor centre). The centre band carries no year labels.
            let yearX: CGFloat
            let yearAnchor: UnitPoint
            if sideOffset < 0 {
                yearX = 12             // left edge = outside of the left band
                yearAnchor = .leading
            } else if sideOffset > 0 {
                yearX = size.width - 12  // right edge = outside of the right band
                yearAnchor = .trailing
            } else {
                yearX = size.width / 2
                yearAnchor = .center
            }
            for year in stride(from: firstDecade, through: newest, by: 10) {
                let rule = y(year)
                // Only draw year numbers for the left and right bands.
                // (The decade rule lines come from FloorDecadeLines, not here.)
                if sideOffset != 0 {
                    // A black bed under every year, so the number reads
                    // on any carpet.
                    let yearText = Text(String(year))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                    let resolvedYear = context.resolve(yearText)
                    let yearSize = resolvedYear.measure(
                        in: CGSize(width: 100, height: 30))
                    let bedX = yearAnchor == .leading
                        ? yearX - 6
                        : yearX - yearSize.width - 6
                    context.fill(
                        Path(roundedRect: CGRect(
                            x: bedX, y: rule - 14 - yearSize.height / 2 - 3,
                            width: yearSize.width + 12,
                            height: yearSize.height + 6), cornerRadius: 6),
                        with: .color(.black))
                    context.draw(resolvedYear,
                                 at: CGPoint(x: yearX, y: rule - 14),
                                 anchor: yearAnchor)
                }
            }

            // Events: most widely carried first.
            let lineHeight: CGFloat = 30
            var taken: [CGFloat] = []
            let ordered = history.events
                .filter { $0.year >= oldest && $0.year <= newest }
                .sorted { $0.links > $1.links }
            for event in ordered {
                let row = y(event.year)
                guard row > 20, row < size.height - 20,
                      !taken.contains(where: { abs($0 - row) < lineHeight }) else { continue }
                taken.append(row)
                let words = event.title
                let text = Text(words)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                let resolved = context.resolve(text)
                let measured = resolved.measure(in: CGSize(width: size.width - 80,
                                                           height: lineHeight))
                let textX: CGFloat
                let textAnchor: UnitPoint
                let bedX: CGFloat
                if sideOffset < 0 {
                    textX = 40; textAnchor = .leading
                    bedX = 28
                } else if sideOffset > 0 {
                    textX = size.width - 40; textAnchor = .trailing
                    bedX = size.width - 28 - measured.width - 24
                } else {
                    textX = size.width / 2; textAnchor = .center
                    bedX = (size.width - measured.width - 24) / 2
                }
                let bed = CGRect(x: bedX, y: row - measured.height / 2 - 5,
                                 width: measured.width + 24,
                                 height: measured.height + 10)
                // Solid black: the words must read on any floor — pale
                // carpet, wood, the void of a dark rug alike.
                context.fill(Path(roundedRect: bed, cornerRadius: 8),
                             with: .color(.black))
                context.draw(resolved, at: CGPoint(x: textX, y: row), anchor: textAnchor)
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

// MARK: - Room-scale Concept Space

/// Manages AI-generated paper concepts as free-floating 3-D cards spread at
/// head height across the ImmersiveSpace. A single tap shows connection lines
/// Renders concept cards as rasterized texture planes (same approach as hallway
/// nodes) so they appear alongside the existing space without hiding anything.
@MainActor
final class ConceptSpaceManager {
    private var content: RealityViewContent?
    private var conceptEntities: [String: ModelEntity] = [:]
    private var connectionEntities: [Entity] = []
    private var orbitEntities: [Entity] = []
    private var detailEntity: Entity?
    private var highlightEntities: [String: Entity] = [:]

    private(set) var isOpen = false
    private(set) var selectedConceptID: String? = nil

    static let cardPrefix  = "cs2.card."
    static let orbitPrefix = "cs2.orbit."

    func install(in content: RealityViewContent) {
        self.content = content
    }

    func open(concepts: [MergedConcept], room: String) {
        guard let content else { return }
        for (_, e) in conceptEntities { e.removeFromParent() }
        conceptEntities = [:]
        highlightEntities = [:]
        clearConnections()
        clearOrbit()
        hideDetail()
        selectedConceptID = nil

        let saved = SpatialLayoutStore.load("ConceptSpace-\(room)")
        let cols = 10
        let spacingX: Float = 0.50
        let spacingY: Float = 0.32
        let totalW = Float(min(concepts.count, cols) - 1) * spacingX
        let startX = -totalW / 2
        let startY: Float = 1.70
        let baseZ: Float = -1.8

        for (i, concept) in concepts.enumerated() {
            let col = i % cols
            let row = i / cols
            let defaultPos = SIMD3<Float>(
                startX + Float(col) * spacingX,
                startY - Float(row) * spacingY,
                baseZ)
            let pos: SIMD3<Float>
            if let sv = saved["c_" + concept.id] {
                pos = SIMD3<Float>(Float(sv.x), Float(sv.y), Float(sv.z))
            } else {
                pos = defaultPos
            }

            guard let plane = makeCardPlane(concept: concept) else { continue }
            plane.name = Self.cardPrefix + concept.id
            plane.position = pos
            content.add(plane)
            conceptEntities[concept.id] = plane
        }

        isOpen = true
    }

    func close() {
        for (_, e) in conceptEntities { e.removeFromParent() }
        conceptEntities = [:]
        highlightEntities = [:]
        clearConnections()
        clearOrbit()
        hideDetail()
        selectedConceptID = nil
        isOpen = false
    }

    func saveLayout(room: String) {
        var positions: [String: SIMD3<Double>] = [:]
        for (id, entity) in conceptEntities {
            let p = entity.position
            positions["c_" + id] = SIMD3<Double>(Double(p.x), Double(p.y), Double(p.z))
        }
        SpatialLayoutStore.save("ConceptSpace-\(room)", positions)
    }

    func selectOrDeselect(_ conceptID: String, concept: MergedConcept,
                          model: VisionModel) {
        for (_, h) in highlightEntities { h.removeFromParent() }
        highlightEntities = [:]
        clearConnections()
        clearOrbit()
        hideDetail()

        if selectedConceptID == conceptID {
            selectedConceptID = nil
            return
        }
        selectedConceptID = conceptID

        guard let content,
              let selectedEntity = conceptEntities[conceptID] else { return }

        addHighlight(to: selectedEntity, id: conceptID)

        let fromPos = selectedEntity.position
        for relatedID in concept.relatedConceptIDs {
            guard let toEntity = conceptEntities[relatedID] else { continue }
            let line = makeLine(from: fromPos, to: toEntity.position)
            content.add(line)
            connectionEntities.append(line)
        }

        let docIDs = concept.sourceDocIDs
        for (i, docID) in docIDs.enumerated() {
            guard let entry = model.index.byID[docID] else { continue }
            let angle = 2 * Float.pi * Float(i) / Float(max(docIDs.count, 1))
            let radius: Float = 0.50
            let orbitPos = fromPos + SIMD3<Float>(
                radius * cos(angle), 0, radius * sin(angle))

            let cardView = RoomDocOrbitCardView(entry: entry)
                .frame(maxWidth: 150)
                .fixedSize(horizontal: false, vertical: true)
            guard let image = UIImage.image(cardView, 150),
                  let orbitPlane = ModelEntity.texturedPlane(with: image, ratio: 0.001)
            else { continue }

            let orbitResult = ModelEntity.box(
                with: orbitPlane,
                backPlane: nil,
                color: .white,
                depth: 0.005,
                margins: 0.004,
                opacity: 0.40,
                cornerRadius: 0.007,
                useBorder: true,
                borderColor: UIColor.systemBlue.withAlphaComponent(0.50)
            )
            orbitResult.modelEntity.components.set(CollisionComponent(
                shapes: [orbitResult.collisionShape], mode: .default))
            orbitResult.modelEntity.components.set(InputTargetComponent())
            orbitResult.modelEntity.name = Self.orbitPrefix + docID
            orbitResult.modelEntity.position = orbitPos
            content.add(orbitResult.modelEntity)
            orbitEntities.append(orbitResult.modelEntity)
        }
    }

    func showDetail(for concept: MergedConcept, model: VisionModel) {
        hideDetail()
        guard let content,
              let cardEntity = conceptEntities[concept.id] else { return }
        let sourceEntries = concept.sourceDocIDs.compactMap { model.index.byID[$0] }

        let detailView = RoomConceptDetailView(concept: concept, sourceEntries: sourceEntries)
            .frame(maxWidth: 260)
            .fixedSize(horizontal: false, vertical: true)
        guard let image = UIImage.image(detailView, 260),
              let plane = ModelEntity.texturedPlane(with: image, ratio: 0.001)
        else { return }

        let detailResult = ModelEntity.box(
            with: plane,
            backPlane: nil,
            color: .white,
            depth: 0.007,
            margins: 0.006,
            opacity: 0.50,
            cornerRadius: 0.010,
            useBorder: false,
            borderColor: .clear
        )
        detailResult.modelEntity.name = "cs2.detail." + concept.id
        detailResult.modelEntity.position = cardEntity.position + SIMD3<Float>(0, 0.22, 0)
        content.add(detailResult.modelEntity)
        detailEntity = detailResult.modelEntity
    }

    func hideDetail() {
        detailEntity?.removeFromParent()
        detailEntity = nil
    }

    /// Returns the draggable entity that contains the given entity, or nil.
    func rootDragEntity(for entity: Entity) -> Entity? {
        guard isOpen else { return nil }
        var node: Entity? = entity
        while let n = node {
            if n.name.hasPrefix(Self.cardPrefix) || n.name.hasPrefix(Self.orbitPrefix) {
                return n
            }
            node = n.parent
        }
        return nil
    }

    /// Returns the concept ID for the tapped entity, or nil.
    func conceptID(for entity: Entity) -> String? {
        guard isOpen else { return nil }
        var node: Entity? = entity
        while let n = node {
            if n.name.hasPrefix(Self.cardPrefix) {
                return String(n.name.dropFirst(Self.cardPrefix.count))
            }
            node = n.parent
        }
        return nil
    }

    private func makeCardPlane(concept: MergedConcept) -> ModelEntity? {
        let cardView = RoomConceptCardView(concept: concept)
            .frame(maxWidth: 180)
            .fixedSize(horizontal: false, vertical: true)
        let plane: ModelEntity
        if let img = UIImage.image(cardView, 180),
           let textured = ModelEntity.texturedPlane(with: img, ratio: 0.001) {
            plane = textured
        } else {
            // Image renderer unavailable — bare white slab so cards are
            // at least tappable and visible.
            var mat = UnlitMaterial()
            mat.color = .init(tint: UIColor.white.withAlphaComponent(0.50))
            plane = ModelEntity(
                mesh: .generateBox(size: SIMD3<Float>(0.18, 0.10, 0.004)),
                materials: [mat])
            plane.components.set(CollisionComponent(
                shapes: [.generateBox(size: SIMD3<Float>(0.18, 0.10, 0.004))], mode: .default))
            plane.components.set(InputTargetComponent())
            plane.components.set(HoverEffectComponent())
            return plane
        }
        let result = ModelEntity.box(
            with: plane,
            backPlane: nil,
            color: .white,
            depth: 0.006,
            margins: 0.005,
            opacity: 0.35,
            cornerRadius: 0.008,
            useBorder: false,
            borderColor: .clear
        )
        result.modelEntity.components.set(CollisionComponent(
            shapes: [result.collisionShape], mode: .default))
        result.modelEntity.components.set(InputTargetComponent())
        result.modelEntity.components.set(HoverEffectComponent())
        return result.modelEntity
    }

    private func clearConnections() {
        connectionEntities.forEach { $0.removeFromParent() }
        connectionEntities = []
    }

    private func clearOrbit() {
        orbitEntities.forEach { $0.removeFromParent() }
        orbitEntities = []
    }

    private func addHighlight(to card: Entity, id: String) {
        var mat = UnlitMaterial()
        mat.color = .init(tint: UIColor.systemPurple.withAlphaComponent(0.18))
        let highlight = ModelEntity(
            mesh: .generateBox(size: SIMD3<Float>(0.240, 0.130, 0.005)),
            materials: [mat])
        highlight.name = "cs2.highlight." + id
        highlight.position = SIMD3<Float>(0, 0, -0.010)
        card.addChild(highlight)
        highlightEntities[id] = highlight
    }

    private func makeLine(from: SIMD3<Float>, to: SIMD3<Float>) -> Entity {
        let diff = to - from
        let length = simd_length(diff)
        guard length > 0.01 else { return Entity() }
        var mat = UnlitMaterial()
        mat.color = .init(tint: UIColor.systemPurple.withAlphaComponent(0.28))
        let entity = ModelEntity(
            mesh: .generateBox(size: SIMD3<Float>(0.004, length, 0.004)),
            materials: [mat])
        entity.position = (from + to) / 2
        let dir = simd_normalize(diff)
        let up = SIMD3<Float>(0, 1, 0)
        let dot = simd_dot(up, dir)
        if abs(dot) < 0.9999 {
            let axis = simd_normalize(simd_cross(up, dir))
            entity.orientation = simd_quatf(angle: acos(max(-1, min(1, dot))), axis: axis)
        } else if dot < 0 {
            entity.orientation = simd_quatf(angle: Float.pi, axis: SIMD3<Float>(1, 0, 0))
        }
        return entity
    }
}

// MARK: - Concept Space SwiftUI card views

struct RoomConceptCardView: View {
    let concept: MergedConcept
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(concept.name)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(2)
            if !concept.aiDescription.isEmpty {
                Text(concept.aiDescription)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 4) {
                Image(systemName: "doc.text").font(.system(size: 9))
                Text("\(concept.sourceDocIDs.count)").font(.system(size: 9))
            }
            .foregroundStyle(.secondary)
        }
        .padding(10)
    }
}

struct RoomDocOrbitCardView: View {
    let entry: IndexEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entry.doc.title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(2)
            Text(entry.doc.displayAuthor)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(8)
    }
}

struct RoomConceptDetailView: View {
    let concept: MergedConcept
    let sourceEntries: [IndexEntry]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(concept.name)
                .font(.title3.weight(.semibold))
            let description = concept.userDefinition ?? (concept.aiDescription.isEmpty ? nil : concept.aiDescription)
            if let description {
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if !sourceEntries.isEmpty {
                Divider()
                Text("Documents (\(sourceEntries.count))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(sourceEntries.prefix(8)) { entry in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.doc.title)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                        Text(entry.doc.displayAuthor)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                if sourceEntries.count > 8 {
                    Text("+\(sourceEntries.count - 8) more")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
    }
}
#endif
