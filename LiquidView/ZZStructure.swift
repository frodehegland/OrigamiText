import Foundation
import Observation

// zzStructure, after Ted Nelson, per Eric's brief (14 July 2026) and
// McGuffin & schraefel (HT'04): a directed multigraph with coloured edges
// under Restriction R — each cell at most one incoming and one outgoing
// edge per colour. Colours are dimensions; within one dimension cells form
// non-intersecting paths or cycles (ranks; cyclic ranks are ring ranks).
// Everything is a cell — dimensions and views included. This file is the
// engine and is platform-neutral: it compiles into the macOS and visionOS
// targets alike. The UIs live elsewhere.

// MARK: - Identifiers

/// UUIDv7: time-ordered identifiers for user-created cells and dimensions.
nonisolated enum UUIDv7 {
    static func generate(now: Date = .now) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        let ms = UInt64(max(0, now.timeIntervalSince1970) * 1000)
        for i in 0..<6 { bytes[i] = UInt8((ms >> (40 - 8 * UInt64(i))) & 0xFF) }
        for i in 6..<16 { bytes[i] = UInt8.random(in: 0...255) }
        bytes[6] = (bytes[6] & 0x0F) | 0x70   // version 7
        bytes[8] = (bytes[8] & 0x3F) | 0x80   // variant 10
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5],
                           bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

// MARK: - Core types

/// A cell. Wraps a library document, a dimension, a view, or a clone.
/// Content lives elsewhere; the cell is identity.
nonisolated struct ZZCell: Identifiable, Codable, Hashable {
    let id: UUID
    var kind: Kind

    enum Kind: Codable, Hashable {
        /// A document in the Origami library, by its address (the app's
        /// adaptation of the brief's concept-map node reference).
        case document(documentID: String)
        case dimension(dimensionID: UUID)
        case view(viewID: String)
        case namespaceHead(name: String)
        case clone(of: UUID)     // headcell (original) it clones
        case plain
    }
}

/// A dimension: a namespaced name plus its identity. Every dimension ALSO
/// has a cell, so dimensions can participate in ranks (d.dimensions).
nonisolated struct ZZDimension: Identifiable, Codable, Hashable {
    let id: UUID                 // the edge colour
    let namespace: String        // "d" (system) or "user"
    let name: String
    let dimensionCellID: UUID
    var qualifiedName: String { "\(namespace).\(name)" }
}

/// Per-cell, per-dimension neighbour record (Eric's tuple, verbatim).
nonisolated struct ZZConnection: Codable, Hashable {
    let cellID: UUID
    let dimensionID: UUID
    var negwardID: UUID?
    var poswardID: UUID?
}

nonisolated struct CellDimensionKey: Hashable, Codable {
    let cellID: UUID
    let dimensionID: UUID
}

nonisolated enum ZZError: Error, LocalizedError {
    case wouldViolateRestrictionR(occupiedSlot: String)
    case selfLinkForbidden
    case unknownCell
    case unknownDimension

    var errorDescription: String? {
        switch self {
        case .wouldViolateRestrictionR(let slot):
            "Restriction R: the \(slot) slot is already occupied in this dimension"
        case .selfLinkForbidden: "A cell cannot link to itself"
        case .unknownCell: "Unknown cell"
        case .unknownDimension: "Unknown dimension"
        }
    }
}

/// A rank: the path or ring through a cell along one dimension.
nonisolated struct Rank {
    let dimensionID: UUID
    let cells: [UUID]      // in posward order
    let isRing: Bool
    let anchorIndex: Int   // index of the cell the rank was requested through
}

// MARK: - The store

/// The zzStructure store. `link` and `unlink` are the ONLY methods that
/// mutate `connections` — every edge is stored twice (posward on one cell,
/// negward on the other), and these two methods keep the mirrors agreeing.
@MainActor @Observable
final class ZZStructure {
    private(set) var cells: [UUID: ZZCell] = [:]
    private(set) var dimensions: [UUID: ZZDimension] = [:]
    private(set) var connections: [CellDimensionKey: ZZConnection] = [:]
    /// Secondary index: which dimensions touch this cell.
    private(set) var dimensionsByCell: [UUID: Set<UUID>] = [:]
    /// Secondary index: document address → its cell.
    private(set) var cellsByDocument: [String: UUID] = [:]
    /// Set when a loaded file's mirrors disagreed and were repaired.
    private(set) var didRepairOnLoad = false

    // MARK: System dimensions (fixed UUIDs so structures port across installs)

    enum System {
        static let dimensions = UUID(uuidString: "00000000-0000-7000-8000-00000000D001")!
        static let namespaces = UUID(uuidString: "00000000-0000-7000-8000-00000000D002")!
        static let namespaceMembers = UUID(uuidString: "00000000-0000-7000-8000-00000000D003")!
        static let namespaceSiblings = UUID(uuidString: "00000000-0000-7000-8000-00000000D004")!
        static let views = UUID(uuidString: "00000000-0000-7000-8000-00000000D005")!
        static let clones = UUID(uuidString: "00000000-0000-7000-8000-00000000D006")!
        static let userViews = UUID(uuidString: "00000000-0000-7000-8000-00000000D007")!
        /// Each system dimension's cell: same UUID with C in place of D.
        static func cellID(for dimensionID: UUID) -> UUID {
            UUID(uuidString: dimensionID.uuidString.replacingOccurrences(of: "D0", with: "C0"))!
        }
    }

    // MARK: Link and unlink (the sole mutators)

    /// Insert edge A --d--> B (A's posward, B's negward). Throws if a slot
    /// is occupied, unless `splice`: then A—B is spliced INTO the rank —
    /// if A already had posward C, the result is A→B→C.
    /// `allowSelfRing` exists only for bootstrap's one-cell ring.
    func link(_ a: UUID, poswardTo b: UUID, along d: UUID,
              splice: Bool = false, allowSelfRing: Bool = false) throws {
        guard cells[a] != nil, cells[b] != nil else { throw ZZError.unknownCell }
        guard dimensions[d] != nil else { throw ZZError.unknownDimension }

        if a == b {
            guard allowSelfRing else { throw ZZError.selfLinkForbidden }
            var record = connections[CellDimensionKey(cellID: a, dimensionID: d)]
                ?? ZZConnection(cellID: a, dimensionID: d)
            guard record.poswardID == nil else {
                throw ZZError.wouldViolateRestrictionR(occupiedSlot: "posward of the cell")
            }
            record.poswardID = a
            record.negwardID = a
            store(record)
            return
        }

        var recordA = connections[CellDimensionKey(cellID: a, dimensionID: d)]
            ?? ZZConnection(cellID: a, dimensionID: d)
        var recordB = connections[CellDimensionKey(cellID: b, dimensionID: d)]
            ?? ZZConnection(cellID: b, dimensionID: d)

        if let inherited = recordA.poswardID {
            // A already points somewhere: only splice may proceed.
            guard splice else {
                throw ZZError.wouldViolateRestrictionR(occupiedSlot: "posward of the first cell")
            }
            guard inherited != b else { return }   // A→B already holds
            guard recordB.poswardID == nil else {
                throw ZZError.wouldViolateRestrictionR(occupiedSlot: "posward of the spliced cell")
            }
            guard recordB.negwardID == nil else {
                throw ZZError.wouldViolateRestrictionR(occupiedSlot: "negward of the spliced cell")
            }
            if inherited == a {
                // Splicing into a one-cell ring: A→B→A.
                recordA.poswardID = b
                recordA.negwardID = b
                recordB.negwardID = a
                recordB.poswardID = a
                store(recordA)
                store(recordB)
            } else {
                var recordC = connections[CellDimensionKey(cellID: inherited, dimensionID: d)]
                    ?? ZZConnection(cellID: inherited, dimensionID: d)
                recordA.poswardID = b
                recordB.negwardID = a
                recordB.poswardID = inherited
                recordC.negwardID = b
                store(recordA)
                store(recordB)
                store(recordC)
            }
        } else {
            guard recordB.negwardID == nil else {
                throw ZZError.wouldViolateRestrictionR(occupiedSlot: "negward of the second cell")
            }
            recordA.poswardID = b
            recordB.negwardID = a
            store(recordA)
            store(recordB)
        }
    }

    /// Remove edge A --d--> B if present. Heals nothing: no auto-rejoin.
    func unlink(_ a: UUID, poswardFrom b: UUID, along d: UUID) {
        let keyA = CellDimensionKey(cellID: a, dimensionID: d)
        guard var recordA = connections[keyA], recordA.poswardID == b else { return }
        if a == b {
            recordA.poswardID = nil
            recordA.negwardID = recordA.negwardID == a ? nil : recordA.negwardID
            store(recordA)
            return
        }
        recordA.poswardID = nil
        store(recordA)
        let keyB = CellDimensionKey(cellID: b, dimensionID: d)
        if var recordB = connections[keyB], recordB.negwardID == a {
            recordB.negwardID = nil
            store(recordB)
        }
    }

    /// Writes a record back, dropping empty records and maintaining the
    /// dimensions-by-cell index. Private: all mutation flows through here.
    private func store(_ record: ZZConnection) {
        let key = CellDimensionKey(cellID: record.cellID, dimensionID: record.dimensionID)
        if record.poswardID == nil && record.negwardID == nil {
            connections[key] = nil
            dimensionsByCell[record.cellID]?.remove(record.dimensionID)
            if dimensionsByCell[record.cellID]?.isEmpty == true {
                dimensionsByCell[record.cellID] = nil
            }
        } else {
            connections[key] = record
            dimensionsByCell[record.cellID, default: []].insert(record.dimensionID)
        }
    }

    // MARK: Reading

    func posward(of cellID: UUID, along d: UUID) -> UUID? {
        connections[CellDimensionKey(cellID: cellID, dimensionID: d)]?.poswardID
    }

    func negward(of cellID: UUID, along d: UUID) -> UUID? {
        connections[CellDimensionKey(cellID: cellID, dimensionID: d)]?.negwardID
    }

    /// All dimensions with at least one connection at this cell — the
    /// navigation assist from the accursed cell.
    func dimensions(at cellID: UUID) -> [ZZDimension] {
        (dimensionsByCell[cellID] ?? [])
            .compactMap { dimensions[$0] }
            .sorted { $0.qualifiedName < $1.qualifiedName }
    }

    /// Walk negward from `cell` to the rank head (or all the way around a
    /// ring), then collect posward. Cycle-safe: ring ranks are legal and
    /// common — d.dimensions is one.
    func rank(through cell: UUID, along d: UUID, limit: Int = 512) -> Rank {
        guard cells[cell] != nil else {
            return Rank(dimensionID: d, cells: [], isRing: false, anchorIndex: 0)
        }
        var head = cell
        var isRing = false
        var visited: Set<UUID> = [cell]
        while let previous = negward(of: head, along: d) {
            if previous == cell || visited.contains(previous) {
                isRing = true
                head = cell    // a ring has no head; collect from the anchor
                break
            }
            visited.insert(previous)
            head = previous
            if visited.count >= limit { break }
        }
        var ordered: [UUID] = [head]
        visited = [head]
        var cursor = head
        while let next = posward(of: cursor, along: d) {
            if visited.contains(next) { break }   // ring closed
            ordered.append(next)
            visited.insert(next)
            cursor = next
            if ordered.count >= limit { break }
        }
        return Rank(dimensionID: d,
                    cells: ordered,
                    isRing: isRing,
                    anchorIndex: ordered.firstIndex(of: cell) ?? 0)
    }

    /// The d.dimensions ring in order, starting from d.dimensions itself.
    func allDimensions() -> [ZZDimension] {
        rank(through: System.cellID(for: System.dimensions), along: System.dimensions)
            .cells
            .compactMap { cellID in
                if case .dimension(let dimensionID)? = cells[cellID]?.kind {
                    return dimensions[dimensionID]
                }
                return nil
            }
    }

    // MARK: Cells for documents, clones, dimensions

    /// Find-or-create the cell wrapping a library document.
    func cell(forDocument documentID: String) -> UUID {
        if let existing = cellsByDocument[documentID] { return existing }
        let cell = ZZCell(id: UUIDv7.generate(), kind: .document(documentID: documentID))
        cells[cell.id] = cell
        cellsByDocument[documentID] = cell.id
        return cell.id
    }

    /// Content resolution: a clone reads its rank head's content — walk
    /// negward along d.clones to the original.
    func contentHead(of cellID: UUID) -> UUID {
        guard case .clone? = cells[cellID]?.kind else { return cellID }
        return rank(through: cellID, along: System.clones).cells.first ?? cellID
    }

    /// Clone a cell: the new clone chains posward from the family's tail.
    /// Cloning is the sanctioned workaround for user-level one-to-many.
    @discardableResult
    func makeClone(of cellID: UUID) throws -> UUID {
        let head = contentHead(of: cellID)
        let clone = ZZCell(id: UUIDv7.generate(), kind: .clone(of: head))
        cells[clone.id] = clone
        let family = rank(through: head, along: System.clones)
        let tail = family.cells.last ?? head
        try link(tail, poswardTo: clone.id, along: System.clones)
        return clone.id
    }

    /// A new user dimension: created, given its cell, spliced into the
    /// d.dimensions ring, and filed under its namespace (first-child /
    /// next-sibling encoding — one-to-many is forbidden in one colour).
    @discardableResult
    func addDimension(name: String, namespace: String = "user") throws -> ZZDimension {
        let cell = ZZCell(id: UUIDv7.generate(), kind: .plain)
        let dimension = ZZDimension(id: UUIDv7.generate(), namespace: namespace,
                                    name: name, dimensionCellID: cell.id)
        cells[cell.id] = ZZCell(id: cell.id, kind: .dimension(dimensionID: dimension.id))
        dimensions[dimension.id] = dimension
        try link(System.cellID(for: System.dimensions), poswardTo: cell.id,
                 along: System.dimensions, splice: true)
        try file(dimensionCell: cell.id, underNamespace: namespace)
        return dimension
    }

    private func namespaceHeadCell(_ namespace: String) throws -> UUID {
        for (id, cell) in cells {
            if case .namespaceHead(let name) = cell.kind, name == namespace { return id }
        }
        let head = ZZCell(id: UUIDv7.generate(), kind: .namespaceHead(name: namespace))
        cells[head.id] = head
        // Chain onto the tail of the d.namespaces rank.
        for (id, cell) in cells where id != head.id {
            guard case .namespaceHead = cell.kind else { continue }
            let tail = rank(through: id, along: System.namespaces).cells.last ?? id
            if tail != head.id {
                try link(tail, poswardTo: head.id, along: System.namespaces)
            }
            break
        }
        return head.id
    }

    private func file(dimensionCell: UUID, underNamespace namespace: String) throws {
        let head = try namespaceHeadCell(namespace)
        if let firstChild = posward(of: head, along: System.namespaceMembers) {
            let siblingTail = rank(through: firstChild, along: System.namespaceSiblings).cells.last ?? firstChild
            guard siblingTail != dimensionCell else { return }
            try link(siblingTail, poswardTo: dimensionCell, along: System.namespaceSiblings)
        } else {
            try link(head, poswardTo: dimensionCell, along: System.namespaceMembers)
        }
    }

    // MARK: Bootstrap

    /// Creates the system dimensions. Order matters: d.dimensions must
    /// exist before it can contain itself — its cell links to itself as a
    /// one-cell ring, then every later dimension is spliced in.
    func bootstrap() throws {
        func register(_ id: UUID, _ name: String) throws -> ZZDimension {
            let cellID = System.cellID(for: id)
            let dimension = ZZDimension(id: id, namespace: "d", name: name, dimensionCellID: cellID)
            dimensions[id] = dimension
            cells[cellID] = ZZCell(id: cellID, kind: .dimension(dimensionID: id))
            return dimension
        }
        let dims = try register(System.dimensions, "dimensions")
        _ = try register(System.namespaces, "namespaces")
        _ = try register(System.namespaceMembers, "namespace-members")
        _ = try register(System.namespaceSiblings, "namespace-siblings")
        _ = try register(System.views, "views")
        _ = try register(System.clones, "clones")
        _ = try register(System.userViews, "user-views")

        // The ring of one, then thread the rest in.
        try link(dims.dimensionCellID, poswardTo: dims.dimensionCellID,
                 along: System.dimensions, allowSelfRing: true)
        for id in [System.namespaces, System.namespaceMembers, System.namespaceSiblings,
                   System.views, System.clones, System.userViews] {
            try link(dims.dimensionCellID, poswardTo: System.cellID(for: id),
                     along: System.dimensions, splice: true)
        }

        // The "d" namespace and its members.
        for id in [System.dimensions, System.namespaces, System.namespaceMembers,
                   System.namespaceSiblings, System.views, System.clones, System.userViews] {
            try file(dimensionCell: System.cellID(for: id), underNamespace: "d")
        }

        // View cells from the registry, on the d.views rank; each cloned
        // into d.user-views (all views enabled by default).
        var previousView: UUID?
        var previousUserView: UUID?
        for viewType in ZZViewRegistry.all {
            let cell = ZZCell(id: UUIDv7.generate(), kind: .view(viewID: viewType.key))
            cells[cell.id] = cell
            if let previousView { try link(previousView, poswardTo: cell.id, along: System.views) }
            previousView = cell.id
            let enabled = try makeClone(of: cell.id)
            if let previousUserView {
                try link(previousUserView, poswardTo: enabled, along: System.userViews)
            }
            previousUserView = enabled
        }
    }

    // MARK: Persistence (plain JSON; human-inspectable)

    nonisolated private struct Snapshot: Codable {
        var cells: [ZZCell]
        var dimensions: [ZZDimension]
        var connections: [ZZConnection]
    }

    nonisolated static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("ZZStructure.json")
    }

    func save(to url: URL = ZZStructure.defaultFileURL) {
        let snapshot = Snapshot(cells: Array(cells.values),
                                dimensions: Array(dimensions.values),
                                connections: Array(connections.values))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(snapshot) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Loads from disk, re-deriving the secondary indexes and verifying
    /// the mirror invariant; disagreeing mirrors are repaired (posward is
    /// authoritative) and the repair is flagged. A missing or unreadable
    /// file yields a freshly bootstrapped structure.
    static func loadOrBootstrap(from url: URL = ZZStructure.defaultFileURL) -> ZZStructure {
        let structure = ZZStructure()
        if let data = try? Data(contentsOf: url),
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
           !snapshot.dimensions.isEmpty {
            for cell in snapshot.cells {
                structure.cells[cell.id] = cell
                if case .document(let documentID) = cell.kind {
                    structure.cellsByDocument[documentID] = cell.id
                }
            }
            for dimension in snapshot.dimensions {
                structure.dimensions[dimension.id] = dimension
            }
            for connection in snapshot.connections {
                let key = CellDimensionKey(cellID: connection.cellID,
                                           dimensionID: connection.dimensionID)
                structure.connections[key] = connection
                structure.dimensionsByCell[connection.cellID, default: []]
                    .insert(connection.dimensionID)
            }
            structure.verifyAndRepairMirrors()
        } else {
            try? structure.bootstrap()
            structure.save(to: url)
        }
        return structure
    }

    /// Invariant 2: if A's posward along d is B, B's negward along d is A.
    private func verifyAndRepairMirrors() {
        for (key, record) in connections {
            guard let posward = record.poswardID else { continue }
            let mirrorKey = CellDimensionKey(cellID: posward, dimensionID: key.dimensionID)
            if connections[mirrorKey]?.negwardID != record.cellID {
                var mirror = connections[mirrorKey]
                    ?? ZZConnection(cellID: posward, dimensionID: key.dimensionID)
                mirror.negwardID = record.cellID
                connections[mirrorKey] = mirror
                dimensionsByCell[posward, default: []].insert(key.dimensionID)
                didRepairOnLoad = true
            }
        }
    }
}

/// The app's one zzStructure, loaded once per launch (each platform keeps
/// its own weave in its own container for now).
@MainActor
enum ZZStore {
    static let shared = ZZStructure.loadOrBootstrap()
}

// MARK: - Views (algorithms)

/// The axes a view maps dimensions onto. `z` is live on visionOS, where
/// depth is real; on macOS it is navigated (⌥ arrows) and badged.
nonisolated struct AxisBinding: Hashable {
    var x: UUID
    var y: UUID
    var z: UUID?
}

nonisolated struct PlacedCell: Identifiable, Hashable {
    let cellID: UUID
    let x: Int, y: Int, z: Int      // integer grid, accursed cell at origin
    let isVirtualCopy: Bool          // same cell already placed elsewhere
    var id: String { "\(cellID)-\(x)-\(y)-\(z)" }
}

@MainActor
protocol ZZView {
    static var key: String { get }
    static var displayName: String { get }
    init()
    func layout(accursed: UUID, axes: AxisBinding, in structure: ZZStructure) -> [PlacedCell]
}

@MainActor
enum ZZViewRegistry {
    static let all: [any ZZView.Type] = [HView.self, IView.self]

    static func view(for key: String) -> any ZZView {
        (all.first { $0.key == key } ?? HView.self).init()
    }
}

/// The shared core: one rank is the spine, and through each of its cells
/// the full cross rank is laid. H and I are transposes of each other. The
/// space is non-Euclidean: a cell may appear at two coordinates — such
/// virtual copies are marked, never suppressed; they are how the user
/// perceives wormholes.
@MainActor
private func gridLayout(accursed: UUID, spineDimension: UUID, rungDimension: UUID,
                        zDimension: UUID?, transposed: Bool,
                        in structure: ZZStructure) -> [PlacedCell] {
    var zOffsets: [UUID: Int] = [:]
    if let zDimension {
        let zRank = structure.rank(through: accursed, along: zDimension)
        for (index, cell) in zRank.cells.enumerated() {
            zOffsets[cell] = index - zRank.anchorIndex
        }
    }
    let spine = structure.rank(through: accursed, along: spineDimension)
    var placedAt: [UUID: (Int, Int)] = [:]
    var placed: [PlacedCell] = []
    for (spineIndex, spineCell) in spine.cells.enumerated() {
        let along = spineIndex - spine.anchorIndex
        let rung = structure.rank(through: spineCell, along: rungDimension)
        for (rungIndex, cell) in rung.cells.enumerated() {
            let across = rungIndex - rung.anchorIndex
            let x = transposed ? across : along
            let y = transposed ? along : across
            let isVirtual = placedAt[cell].map { $0 != (x, y) } ?? false
            if placedAt[cell] == nil { placedAt[cell] = (x, y) }
            else if !isVirtual { continue }   // exact same spot: place once
            placed.append(PlacedCell(cellID: cell, x: x, y: y,
                                     z: zOffsets[cell] ?? 0,
                                     isVirtualCopy: isVirtual))
        }
    }
    return placed
}

/// H-view: the x rank through the accursed cell is the crossbar; each of
/// its cells drops its full y rank as a column.
@MainActor
struct HView: ZZView {
    static let key = "h-view"
    static let displayName = "H-view (columns)"
    func layout(accursed: UUID, axes: AxisBinding, in structure: ZZStructure) -> [PlacedCell] {
        gridLayout(accursed: accursed, spineDimension: axes.x, rungDimension: axes.y,
                   zDimension: axes.z, transposed: false, in: structure)
    }
}

/// I-view: the transpose — the y rank through the accursed cell is the
/// spine; each of its cells lays its full x rank as a row.
@MainActor
struct IView: ZZView {
    static let key = "i-view"
    static let displayName = "I-view (rows)"
    func layout(accursed: UUID, axes: AxisBinding, in structure: ZZStructure) -> [PlacedCell] {
        gridLayout(accursed: accursed, spineDimension: axes.y, rungDimension: axes.x,
                   zDimension: axes.z, transposed: true, in: structure)
    }
}
