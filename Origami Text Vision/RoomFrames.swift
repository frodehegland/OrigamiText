//
//  RoomFrames.swift
//  Origami Text (visionOS)
//
//  Frames in the room (16 Nov 2026, Frode): Knowledge Space's side panels
//  (Liquid XR Space: LiquidWallPicture's container walls, ConceptWallView's
//  columns, WallEditPanel, ContainerTopBar) brought to the Hallway. A frame
//  is put up anywhere — a corner of the room, flat on a wall — and holds
//  every concept of one kind standing in the room: the Authors (their
//  cards), or the room's concepts, people, artifacts, events, locations or
//  institutions. Its picture, frame colour (woods with their grain),
//  thickness, transparency and Offset Frame are its own; it can be moved
//  and resized by its handles, turned, snapped to a real wall, folded to
//  its title, and its members pulled out into the room or put back.
//
//  Frames are kept per room (by journal or volume venue) in the community
//  folder's origami-room-frames.json, each frame newest-wins with
//  tombstones, mirrored in Application Support — so they follow the room
//  to any headset and the Mac can read them. A photo chosen from Photos is
//  kept in the community folder's Frame Pictures too.
//
//  Panels (18 Nov 2026, Frode): a frame of no kind — it gathers nothing by
//  itself. The reader names it (and renames it), and any article or
//  concept let go on it sticks to it, in the order stuck, until carried
//  off. The room's real walls and tables are the context's — frames,
//  panels, labels — and the knowledge objects themselves float; a panel is
//  where they are put up for a mind palace.
//
//  Physical rooms (18 Nov 2026, Frode): each room the headset is used in is
//  remembered by a world anchor (PhysicalRooms), and every frame keeps its
//  place in each room relative to that room's anchor — this headset's own,
//  kept in Application Support, as world anchors are — so a panel snapped
//  to the study's wall is on the study's wall again, and the kitchen's
//  panels on the kitchen's. Room layouts (RoomLayouts) save which frames
//  and panels stand, with what and where, to be brought back at once.
//
//  Keep in step with Knowledge Space's LiquidWallPicture where they share
//  ideas; the frame's looks are its, the members are Origami's own cards.
//

#if os(visionOS)
import SwiftUI
import RealityKit
import UIKit
import ImageIO
import PhotosUI

/// One frame in a room.
struct RoomFrame: Codable, Identifiable, Equatable {
    let id: String
    /// The room it stands in: the journal's or volume's venue.
    var venue: String
    /// What it holds: "authors", a ConceptKind's raw value, or "panel" —
    /// a panel holds only what was stuck to it.
    var kind: String
    var width: Float
    var height: Float
    /// Column-major world matrix: right, up, normal (out of the frame,
    /// toward the reader), middle.
    var transform: [Float]
    /// "grey", "builtin:<name>", "default:<name>" or "photo:<file name>".
    var picture: String
    /// A Style raw value; nil, unframed.
    var frame: String?
    var frameThickness: String?
    /// A Transparency raw value; nil, opaque.
    var transparency: String?
    /// The border standing out from the wall, the picture set back in it
    /// (Knowledge Space's default); false, the border just behind the
    /// picture.
    var offsetFrame: Bool?
    /// Folded: tiny, only its title showing — and here its full size and
    /// place, to unfold to.
    var unfolded: Unfolded?
    /// Members standing loose in the room, pulled out of it.
    var pulled: [String] = []
    /// A panel's own name, given and changed by the reader.
    var name: String?
    /// A panel's members: the articles and concepts stuck to it, in the
    /// order they were stuck. A frame of a kind's: the concepts filed into
    /// it by hand, whatever their own kind (18 Nov 2026) — they stand in
    /// it beside those it gathers.
    var members: [String]?
    /// Put away from the bar's Frames: kept where it stands, out of sight.
    var hidden: Bool?
    /// A tombstone: deleted, kept so another device's copy does not bring
    /// it back.
    var deleted: Bool?
    var modified: Date

    struct Unfolded: Codable, Equatable {
        var width: Float
        var height: Float
        var transform: [Float]
    }

    var isFolded: Bool { unfolded != nil }
    var isShown: Bool { hidden != true && deleted != true }

    /// Authors and the six concept kinds, as the bar offers them.
    static let authorsKind = "authors"
    /// A panel: no kind of its own (18 Nov 2026, Frode).
    static let panelKind = "panel"
    /// What an unnamed panel is called.
    static let unnamedPanel = "Untitled Panel"
    static let kinds: [String] = [authorsKind] + ConceptKind.allCases.map(\.rawValue)

    static func title(of kind: String) -> String {
        switch kind {
        case authorsKind: "Authors"
        case ConceptKind.concept.rawValue: "Concepts"
        case ConceptKind.person.rawValue: "People"
        case ConceptKind.artifact.rawValue: "Artifacts"
        case ConceptKind.event.rawValue: "Events"
        case ConceptKind.location.rawValue: "Locations"
        case ConceptKind.institution.rawValue: "Institutions"
        default: kind.capitalized
        }
    }

    var isPanel: Bool { kind == Self.panelKind }

    var title: String {
        // A panel made a category frame keeps the name it was given.
        let given = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !given.isEmpty { return given }
        return isPanel ? Self.unnamedPanel : Self.title(of: kind)
    }
}

/// What a frame's body or one of its handles is, for the room's gestures.
/// A room layout (18 Nov 2026, Frode): the frames and panels standing in a
/// room — the context of its concepts — saved to be brought back at once:
/// each frame as it was (its kind, a panel's name and what is stuck to it,
/// its looks) and its places in this headset's physical rooms. Not the
/// sculpture: the articles' and loose concepts' places are a View's.
struct RoomLayout: Codable, Identifiable, Equatable {
    let id: String
    var venue: String
    var name: String
    var frames: [RoomFrame]
    /// Physical room (its anchor's id) → frame → place there.
    var poses: [String: [String: RoomPose]]
    var modified: Date
    var deleted: Bool?
}

struct RoomFrameHitComponent: Component {
    let frameID: String
    /// −1, 0 or 1 along the frame's right and up: a resize handle's side
    /// or corner. Both 0: the frame itself.
    var x: Float = 0
    var y: Float = 0
    var isRotate = false
}

@MainActor
@Observable
final class RoomFrames {
    static let shared = RoomFrames()

    // MARK: Looks (Knowledge Space's, as it has them)

    enum Style: String, CaseIterable, Identifiable {
        case blackMatte = "Black Matte"
        case blackShiny = "Black Shiny"
        case darkWood = "Dark Brown Wood"
        case midWood = "Mid-Brown Wood"
        case lightWood = "Light Brown Wood"
        case lightGrey = "Light Grey"
        case midGrey = "Mid Grey"
        case darkGrey = "Dark Grey"
        var id: String { rawValue }

        var colour: UIColor {
            switch self {
            case .blackMatte: UIColor(white: 0.05, alpha: 1)
            case .blackShiny: UIColor(white: 0.02, alpha: 1)
            case .darkWood: UIColor(red: 0.24, green: 0.14, blue: 0.08, alpha: 1)
            case .midWood: UIColor(red: 0.46, green: 0.29, blue: 0.16, alpha: 1)
            case .lightWood: UIColor(red: 0.74, green: 0.57, blue: 0.38, alpha: 1)
            case .lightGrey: UIColor(white: 0.78, alpha: 1)
            case .midGrey: UIColor(white: 0.5, alpha: 1)
            case .darkGrey: UIColor(white: 0.24, alpha: 1)
            }
        }

        var isWood: Bool { self == .darkWood || self == .midWood || self == .lightWood }
    }

    enum Thickness: String, CaseIterable, Identifiable {
        case veryThin = "Very Thin"
        case thin = "Thin"
        case medium = "Medium"
        case wide = "Wide"
        case substantial = "Substantial"
        var id: String { rawValue }

        var width: Float {
            switch self {
            case .veryThin: 0.012
            case .thin: 0.025
            case .medium: 0.045
            case .wide: 0.075
            case .substantial: 0.12
            }
        }
    }

    nonisolated enum BuiltIn: String, CaseIterable, Identifiable {
        case slate = "Slate"
        case dusk = "Dusk"
        case nightSky = "Night Sky"
        case warmPaper = "Warm Paper"
        var id: String { rawValue }
    }

    nonisolated enum DefaultPhoto: String, CaseIterable, Identifiable {
        case forest1 = "Forest 1"
        case forest2 = "Forest 2"
        case forest3 = "Forest 3"
        case forest4 = "Forest 4"
        case romanRuin1 = "Roman Ruin 1"
        case romanRuin2 = "Roman Ruin 2"
        var id: String { rawValue }

        var resourceName: String {
            switch self {
            case .forest1: "frame_forest_1"
            case .forest2: "frame_forest_2"
            case .forest3: "frame_forest_3"
            case .forest4: "frame_forest_4"
            case .romanRuin1: "frame_roman_ruin_1"
            case .romanRuin2: "frame_roman_ruin_2"
            }
        }
    }

    enum Transparency: String, CaseIterable, Identifiable {
        case opaque = "Opaque"
        case barely = "Barely Transparent"
        case slightly = "Slightly Transparent"
        case mid = "Mid Transparent"
        case very = "Very Transparent"
        var id: String { rawValue }
        var opacity: Float {
            switch self {
            case .opaque: 1
            case .barely: 0.93
            case .slightly: 0.75
            case .mid: 0.5
            case .very: 0.25
            }
        }
    }

    /// Every new frame: Slate, in a very thin black matte frame, offset.
    static let defaultPicture = "builtin:" + BuiltIn.slate.rawValue
    static let defaultStyle = Style.blackMatte
    static let defaultThickness = Thickness.veryThin
    /// A new frame's size, in metres.
    static let newSize = SIMD2<Float>(1.2, 0.8)
    /// Folded: about a third of a metre across.
    static let foldedWidth: Float = 0.34
    /// The members stand this far before the picture.
    static let frontOffset: Float = 0.02
    /// A member let go within this of its frame's face, over it, goes back.
    static let stickDistance: Float = 0.12
    /// The most members one frame lays out; the rest wait (alphabetical).
    static let memberLimit = 150

    // MARK: State

    /// Every frame of every room, tombstones and all.
    private(set) var frames: [RoomFrame] = []
    /// The room open now.
    var venue: String? {
        didSet {
            if venue != oldValue {
                carryCurrentRoom()
                placeForRoom()
                showAll()
            }
        }
    }
    /// The frames being moved and resized — one from its own menu, or every
    /// frame in the room from the bar's Frames ▸ Edit & Move.
    private(set) var arrangingIDs: Set<String> = []
    /// The frame whose title menu is open, and its page.
    var menuOpenFor: String?
    /// Where that menu stands: above the corner's Edit, or under the title.
    var menuAtCorner = false
    /// Asked for a picture from Photos: the map, which can open windows,
    /// watches this.
    private(set) var chooserRequests = 0
    @ObservationIgnored private(set) var chooserTargetID: String?

    /// Members as last laid: frame by member id, their places in the room,
    /// their scale and the frame's facing.
    @ObservationIgnored private(set) var memberFrame: [String: String] = [:]
    @ObservationIgnored private(set) var slots: [String: SIMD3<Float>] = [:]
    @ObservationIgnored private(set) var slotScale: [String: Float] = [:]

    // MARK: Hooks the room sets

    /// The community folder, where frames are shared.
    @ObservationIgnored var community: () -> URL? = { nil }
    /// The reader's head: its place and its heading.
    @ObservationIgnored var headPose: () -> (position: SIMD3<Float>, forward: SIMD3<Float>)? = { nil }
    /// The nearest real wall to a place within reach: where a card lands
    /// on it and its turn.
    @ObservationIgnored var wallNear: (SIMD3<Float>, Float) -> (position: SIMD3<Float>, orientation: simd_quatf)? = { _, _ in nil }
    /// Something about who stands in a frame changed: the room rebuilds.
    @ObservationIgnored var membersChanged: () -> Void = {}
    /// Members taken out to stand loose at these places.
    @ObservationIgnored var placeLoose: ([String: SIMD3<Float>]) -> Void = { _ in }
    /// Members put back: their loose places forgotten.
    @ObservationIgnored var forgetLoose: (Set<String>) -> Void = { _ in }

    @ObservationIgnored let root = Entity()
    @ObservationIgnored private var entities: [String: ModelEntity] = [:]
    @ObservationIgnored private var frameKeys: [String: String] = [:]
    @ObservationIgnored private var textures: [String: (picture: String, texture: TextureResource, aspect: Float)] = [:]
    @ObservationIgnored private var pictureTextures: [String: (texture: TextureResource, aspect: Float)] = [:]
    @ObservationIgnored private var loading: [String: String] = [:]
    @ObservationIgnored private var dragStart: (id: String, middle: SIMD3<Float>, grab: SIMD3<Float>)?
    @ObservationIgnored private var resizeStart: (id: String, width: Float, height: Float)?
    @ObservationIgnored private var rotateStart: String?
    @ObservationIgnored private var installed = false

    private init() {
        frames = Self.read(community: nil)
        layouts = Self.readLayouts(community: nil)
    }

    /// Every frame of every room, for the physical rooms' first record.
    var allFrames: [RoomFrame] { frames }

    /// The room's frames, in sight or put away — not the deleted.
    var here: [RoomFrame] {
        guard let venue else { return [] }
        return frames.filter { $0.venue == venue && $0.deleted != true }
    }

    /// The room's frames in sight.
    var shownHere: [RoomFrame] { here.filter(\.isShown) }

    func frame(_ id: String) -> RoomFrame? { frames.first { $0.id == id } }

    /// Whether a frame of this kind stands in sight in the room.
    func isShown(kind: String) -> Bool { shownHere.contains { $0.kind == kind } }

    /// Whether a frame's members stand laid in it: in sight, not folded,
    /// not being moved and resized.
    func laysMembers(_ frame: RoomFrame) -> Bool {
        frame.isShown && !frame.isFolded && !arrangingIDs.contains(frame.id)
            // Not before its place in this physical room is known.
            && PhysicalRooms.shared.shouldShow(frame.id)
    }

    /// The frame a member belongs to, while it stands in it.
    func standsInFrame(_ id: String) -> Bool { memberFrame[id] != nil }

    /// Whether a member has been pulled out of one of the room's frames.
    func isPulled(_ id: String) -> Bool { here.contains { $0.isShown && $0.pulled.contains(id) } }

    /// The kind of frame a member stands in, if it stands in one.
    func kind(ofMember id: String) -> String? {
        memberFrame[id].flatMap { frame($0)?.kind }
    }

    /// The kind of frame a member came out of, while it stands loose.
    func kind(ofPulled id: String) -> String? {
        here.first { $0.isShown && $0.pulled.contains(id) }?.kind
    }

    /// Whether a card is a person by its frame: standing in, or pulled out
    /// of, an Authors or People frame (16 Nov 2026, Frode) — so it keeps
    /// the person's card when lifted out, whatever else is known of it.
    func isPersonMember(_ id: String) -> Bool {
        guard let kind = kind(ofMember: id) ?? kind(ofPulled: id) else { return false }
        return kind == RoomFrame.authorsKind || kind == ConceptKind.person.rawValue
    }

    /// The frame in this room a member was pulled out of, if any.
    func frameID(pulling memberID: String) -> String? {
        here.first { $0.isShown && $0.pulled.contains(memberID) }?.id
    }

    /// The turn a member wears in its frame: the frame's own.
    func orientation(of memberID: String) -> simd_quatf? {
        guard let frameID = memberFrame[memberID], let frame = frame(frameID) else { return nil }
        return Self.rotation(Self.matrix(frame.transform))
    }

    var hasMembers: Bool { !memberFrame.isEmpty }

    // MARK: Installing

    func install(in content: RealityViewContent) {
        if root.parent == nil { content.add(root) }
        // The shadows' lines follow their concepts each frame.
        shadowTick = content.subscribe(to: SceneEvents.Update.self) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.layShadowLines()
                self?.layQuestion()
            }
        }
        PhysicalRooms.shared.spaceOpened()
        guard !installed else { return }
        installed = true
        refresh()
    }

    // MARK: A shadow's line to its concept (18 Nov 2026, Frode)

    /// Where a member stands in the room now — set by the room.
    @ObservationIgnored var positionOf: (String) -> SIMD3<Float>? = { _ in nil }
    /// The concepts of a kind standing loose in the room — in no frame or
    /// panel — set by the room (18 Nov 2026).
    @ObservationIgnored var looseConcepts: (String) -> [String] = { _ in [] }

    /// Whether Move All Back has anything to bring: what was carried out,
    /// or, for a frame of a kind, any concept of its kind loose in the room.
    func canMoveAllBack(_ frameID: String) -> Bool {
        guard let frame = frame(frameID) else { return false }
        if !frame.pulled.isEmpty { return true }
        return !frame.isPanel && !looseConcepts(frame.kind).isEmpty
    }

    /// A shadow double-tapped (18 Nov 2026, Frode): its concept back in its
    /// slot — stuck to its panel again, or put back in its frame.
    func bringBack(_ memberID: String, to frameID: String) {
        guard let frame = frame(frameID) else { return }
        linkedShadows.remove(memberID)
        if frame.isPanel { stick(memberID, to: frameID) } else { putBack(memberID, in: frameID) }
    }
    /// The shadows whose line to their concept is drawn.
    @ObservationIgnored private var linkedShadows: Set<String> = []
    @ObservationIgnored private var shadowLines: [String: ModelEntity] = [:]
    @ObservationIgnored private var shadowTick: EventSubscription?

    /// A shadow pinched: a line from it to where its concept stands loose
    /// in the room; pinched again, the line goes.
    func toggleShadowLine(_ memberID: String) {
        if linkedShadows.remove(memberID) == nil { linkedShadows.insert(memberID) }
        layShadowLines()
    }

    private func shadowEntity(_ memberID: String) -> Entity? {
        for frame in shownHere where frame.pulled.contains(memberID) {
            if let shadow = entities[frame.id]?.findEntity(named: "shadows")?.findEntity(named: memberID) {
                return shadow
            }
        }
        return nil
    }

    /// Each linked shadow's line laid from the shadow to its concept; one
    /// whose concept is back in its frame, or gone, lets its line go.
    private func layShadowLines() {
        for id in linkedShadows {
            guard let shadow = shadowEntity(id), shadow.isEnabledInHierarchy,
                  let to = positionOf(id) else {
                linkedShadows.remove(id)
                continue
            }
            let from = shadow.position(relativeTo: nil)
            let span = to - from
            let length = simd_length(span)
            let line = shadowLines[id] ?? {
                var ink = UnlitMaterial(color: .white)
                ink.blending = .transparent(opacity: 0.7)
                let made = ModelEntity(mesh: .generateCylinder(height: 1, radius: 0.0012), materials: [ink])
                root.addChild(made)
                shadowLines[id] = made
                return made
            }()
            guard length > 0.01 else { line.isEnabled = false; continue }
            line.isEnabled = true
            line.setPosition((from + to) / 2, relativeTo: nil)
            line.setOrientation(simd_quatf(from: SIMD3<Float>(0, 1, 0), to: span / length), relativeTo: nil)
            line.scale = SIMD3<Float>(1, length, 1)
        }
        for (id, line) in shadowLines where !linkedShadows.contains(id) {
            line.removeFromParent()
            shadowLines[id] = nil
        }
    }

    /// Read again from both homes, merged, and shown.
    func refresh() {
        let merged = Self.read(community: community())
        if merged != frames {
            frames = merged
            // The file keeps where each last moved, in whichever room:
            // here, each stands at this room's place again.
            placeForRoom()
        }
        refreshLayouts()
        showAll()
    }

    private func showAll() {
        for frame in frames { show(frame) }
        for (id, entity) in entities where !frames.contains(where: { $0.id == id && $0.deleted != true }) {
            entity.removeFromParent()
            entities[id] = nil
            frameKeys[id] = nil
        }
    }

    // MARK: Putting up, hiding, deleting

    /// The bar's Frames ▸ a kind: a frame of it shown if hidden, hidden if
    /// shown; none in the room, one put up before the reader, Move & Resize
    /// on so it can be carried where it is wanted.
    func toggle(kind: String) {
        if let frame = here.first(where: { $0.kind == kind }) {
            update(frame.id) { $0.hidden = $0.isShown ? true : nil }
            if !(self.frame(frame.id)?.isShown ?? false) { arrangingIDs.remove(frame.id) }
            membersChanged()
            return
        }
        putUp(kind: kind)
    }

    /// Another frame of a kind, before the reader.
    func putUp(kind: String) {
        guard let venue else { return }
        let head = headPose() ?? (SIMD3<Float>(0, 1.5, 0), SIMD3<Float>(0, 0, -1))
        var forward = SIMD3<Float>(head.forward.x, 0, head.forward.z)
        forward = simd_length(forward) > 1e-4 ? simd_normalize(forward) : SIMD3<Float>(0, 0, -1)
        let middle = SIMD3<Float>(head.position.x, head.position.y, head.position.z) + forward * 1.5
        let normal = -forward
        let up = SIMD3<Float>(0, 1, 0)
        let right = simd_normalize(simd_cross(up, normal))
        let m = simd_float4x4(SIMD4<Float>(right, 0), SIMD4<Float>(up, 0), SIMD4<Float>(normal, 0),
                              SIMD4<Float>(middle, 1))
        let frame = RoomFrame(id: UUID().uuidString, venue: venue, kind: kind,
                              width: Self.newSize.x, height: Self.newSize.y, transform: Self.columns(m),
                              picture: Self.defaultPicture, frame: Self.defaultStyle.rawValue,
                              frameThickness: Self.defaultThickness.rawValue, modified: Date())
        frames.append(frame)
        PhysicalRooms.shared.madeNow(frame.id)
        PhysicalRooms.shared.record(frame)
        arrangingIDs.insert(frame.id)
        show(frame)
        save()
        membersChanged()
    }

    // MARK: Room layouts (18 Nov 2026, Frode)

    /// Every layout of every room, tombstones and all.
    private(set) var layouts: [RoomLayout] = []

    /// Every saved room, newest first — for any journal or volume
    /// (18 Nov 2026, Frode: rooms are universal, not a volume's).
    var layoutsHere: [RoomLayout] {
        layouts.filter { $0.deleted != true }.sorted { $0.modified > $1.modified }
    }

    // The room's name (18 Nov 2026, Frode): the layout it was last saved
    // as or chosen from — a project — shown on every frame's foot, "Room"
    // until one is.

    /// The frame whose room menu is open.
    var roomMenuOpenFor: String?

    /// The room stood in now, whatever journal or volume is open.
    private var currentLayoutKey: String { "roomLayout.current" }

    /// The layout the room stands as now, if any.
    var currentLayoutID: String? {
        get { _ = layouts.count; return UserDefaults.standard.string(forKey: currentLayoutKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: currentLayoutKey)
            layoutsTick += 1
            // The room stood in keeps it as its own (19 Nov 2026, Frode).
            PhysicalRooms.shared.rememberLayout(newValue)
        }
    }
    /// Bumped when the current layout changes, so the feet show it.
    private(set) var layoutsTick = 0

    /// The layout's name (19 Nov 2026, Frode: a layout is the panels, a
    /// room the physical space).
    var currentRoomName: String {
        _ = layoutsTick
        return layoutsHere.first { $0.id == currentLayoutID }?.name ?? "Layout"
    }

    /// Every frame's foot: the room, then the layout — "Study · Hypertext".
    var footLabel: String {
        "\(PhysicalRooms.shared.currentName ?? "Room") · \(currentRoomName)"
    }

    /// The frames standing now saved under a name the reader gave — the
    /// same name again saves over it — and the room stands as that.
    func saveLayout(named given: String) {
        guard let venue else { return }
        let name = given.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let standing = shownHere
        let poses = PhysicalRooms.shared.poses(for: Set(standing.map(\.id)))
        if let index = layouts.firstIndex(where: { $0.deleted != true && $0.name == name }) {
            layouts[index].frames = standing
            layouts[index].poses = poses
            layouts[index].modified = Date()
            currentLayoutID = layouts[index].id
        } else {
            let layout = RoomLayout(id: UUID().uuidString, venue: venue, name: name, frames: standing,
                                    poses: poses, modified: Date())
            layouts.append(layout)
            currentLayoutID = layout.id
        }
        Self.writeLayouts(layouts, community: community())
    }

    /// The frames standing now, saved as a layout named for what they are.
    func saveLayout() {
        guard let venue else { return }
        let standing = shownHere
        guard !standing.isEmpty else { return }
        let titles = standing.map(\.title)
        var name = titles.prefix(3).joined(separator: ", ")
        if titles.count > 3 { name += " +\(titles.count - 3)" }
        // Two of the same name are told apart by when.
        if layoutsHere.contains(where: { $0.name == name }) {
            name += " · " + Date().formatted(date: .abbreviated, time: .shortened)
        }
        let layout = RoomLayout(id: UUID().uuidString, venue: venue, name: name, frames: standing,
                                poses: PhysicalRooms.shared.poses(for: Set(standing.map(\.id))),
                                modified: Date())
        layouts.append(layout)
        currentLayoutID = layout.id
        Self.writeLayouts(layouts, community: community())
    }

    /// A layout brought back: its frames stand as saved — un-hidden, and
    /// back from deletion if need be — at their places in this physical
    /// room; every other frame of the room is put away (kept, hidden).
    func loadLayout(_ id: String) {
        guard let venue, let layout = layouts.first(where: { $0.id == id }) else { return }
        menuOpenFor = nil
        roomMenuOpenFor = nil
        currentLayoutID = layout.id
        arrangingIDs = []
        let keep = Set(layout.frames.map(\.id))
        for frame in here where !keep.contains(frame.id) && frame.isShown {
            update(frame.id) { $0.hidden = true }
        }
        PhysicalRooms.shared.adopt(layout.poses)
        for saved in layout.frames {
            var restored = saved
            // Into whichever journal or volume is open: the room is universal.
            restored.venue = venue
            restored.hidden = nil
            restored.deleted = nil
            restored.modified = Date()
            if let index = frames.firstIndex(where: { $0.id == saved.id }) {
                frames[index] = restored
            } else {
                frames.append(restored)
            }
        }
        save()
        placeForRoom()
        showAll()
        membersChanged()
    }

    /// A layout's name changed (18 Nov 2026); empty keeps the old one.
    func renameLayout(_ id: String, to given: String) {
        let name = given.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = layouts.firstIndex(where: { $0.id == id }) else { return }
        layouts[index].name = name
        layouts[index].modified = Date()
        layoutsTick += 1
        Self.writeLayouts(layouts, community: community())
    }

    /// Another journal or volume opened (18 Nov 2026, Frode): the room stood
    /// in comes along — its frames as they stand now, changes and all, or
    /// as saved where one is gone — and the open one's other frames are put
    /// away.
    private func carryCurrentRoom() {
        guard let venue, let layout = layouts.first(where: { $0.id == currentLayoutID && $0.deleted != true })
        else { return }
        let ids = Set(layout.frames.map(\.id))
        var changed = false
        for index in frames.indices where frames[index].deleted != true {
            if ids.contains(frames[index].id) {
                if frames[index].venue != venue || frames[index].hidden == true {
                    frames[index].venue = venue
                    frames[index].hidden = nil
                    frames[index].modified = Date()
                    changed = true
                }
            } else if frames[index].venue == venue, frames[index].isShown {
                frames[index].hidden = true
                frames[index].modified = Date()
                changed = true
            }
        }
        for saved in layout.frames where !frames.contains(where: { $0.id == saved.id && $0.deleted != true }) {
            var restored = saved
            restored.venue = venue
            restored.hidden = nil
            restored.deleted = nil
            restored.modified = Date()
            frames.removeAll { $0.id == saved.id }
            frames.append(restored)
            changed = true
        }
        if changed { save() }
    }

    /// A layout let go, on every device.
    func deleteLayout(_ id: String) {
        guard let index = layouts.firstIndex(where: { $0.id == id }) else { return }
        layouts[index].deleted = true
        layouts[index].modified = Date()
        if currentLayoutID == id { currentLayoutID = nil }
        Self.writeLayouts(layouts, community: community())
    }

    /// Read again from both homes, merged.
    func refreshLayouts() {
        let merged = Self.readLayouts(community: community())
        if merged != layouts { layouts = merged }
    }

    nonisolated private static let layoutsName = "origami-room-layouts.json"

    nonisolated private struct LayoutFile: Codable {
        var layouts: [String: RoomLayout] = [:]
    }

    nonisolated private static var layoutsMirrorURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent(layoutsName)
    }

    nonisolated private static func readLayoutFile(at url: URL) -> LayoutFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(LayoutFile.self, from: data)
    }

    private static func readLayouts(community folder: URL?) -> [RoomLayout] {
        let mirror = readLayoutFile(at: layoutsMirrorURL)
        let shared = folder.flatMap { url in withScope(url) { readLayoutFile(at: $0.appendingPathComponent(layoutsName)) } }
        var merged = mirror?.layouts ?? [:]
        for (id, layout) in shared?.layouts ?? [:] {
            if let held = merged[id], held.modified >= layout.modified { continue }
            merged[id] = layout
        }
        return merged.values.sorted { $0.id < $1.id }
    }

    private static func writeLayouts(_ layouts: [RoomLayout], community folder: URL?) {
        // Merged with what is there, so another headset's layouts stand.
        var file = LayoutFile(layouts: Dictionary(uniqueKeysWithValues: readLayouts(community: folder).map { ($0.id, $0) }))
        for layout in layouts {
            if let held = file.layouts[layout.id], held.modified > layout.modified { continue }
            file.layouts[layout.id] = layout
        }
        guard let data = try? encoder.encode(file) else { return }
        try? data.write(to: layoutsMirrorURL, options: .atomic)
        if let folder {
            withScope(folder) { try? data.write(to: $0.appendingPathComponent(layoutsName), options: .atomic) }
        }
    }

    // MARK: The physical room (18 Nov 2026, Frode)

    /// The room's frames where they stand in the physical room the reader
    /// is in: each at its place remembered for this room. One never placed
    /// here stays exactly where it stands, and that is remembered as its
    /// place here (18 Nov 2026, Frode: frames had swung out before the
    /// reader, facing them, when a room was found). Only in memory — the
    /// shared file keeps where each last moved.
    func placeForRoom() {
        let rooms = PhysicalRooms.shared
        guard rooms.isSettled else { return }
        for index in frames.indices where frames[index].venue == venue && frames[index].deleted != true {
            if let pose = rooms.pose(of: frames[index].id) {
                frames[index].transform = Self.columns(pose.transform)
                frames[index].width = pose.width
                frames[index].height = pose.height
            } else if rooms.isNewHere(frames[index].id) {
                // Never stood in this room: anchored where it stands.
                rooms.record(frames[index])
            }
        }
    }

    /// A frame's own anchor found or refined (19 Nov 2026): it stands
    /// there — unless the reader holds it.
    func anchorMoved(_ frameID: String, firstTime: Bool) {
        // Not while it is being moved and resized, nor while its new anchor
        // is being made — the old one's word would pull it back.
        guard !arrangingIDs.contains(frameID), !PhysicalRooms.shared.isAnchoring(frameID),
              dragStart?.id != frameID, resizeStart?.id != frameID, rotateStart != frameID,
              let index = frames.firstIndex(where: { $0.id == frameID }),
              let pose = PhysicalRooms.shared.pose(of: frameID) else { return }
        let before = frames[index].transform.count == 16
            ? Self.translation(Self.matrix(frames[index].transform)) : nil
        frames[index].transform = Self.columns(pose.transform)
        frames[index].width = pose.width
        frames[index].height = pose.height
        show(frames[index])
        // Its concepts are laid again when it first appears or has moved
        // more than a few centimetres — not for every small refinement.
        if !firstTime, let before, simd_distance(before, Self.translation(pose.transform)) < 0.005,
           frames[index].width == pose.width { return }
        let shift = before.map { simd_distance($0, Self.translation(pose.transform)) } ?? 1
        if firstTime || shift > 0.05 { membersChanged() }
    }

    /// Shown again as it stands — its visibility asked afresh.
    func reshow(_ frameID: String) {
        if let frame = frame(frameID) { show(frame) }
    }

    /// An old room's place for a frame, carried over: it stands there and
    /// is anchored (19 Nov 2026).
    func place(_ frameID: String, at world: simd_float4x4, width: Float, height: Float) {
        guard let index = frames.firstIndex(where: { $0.id == frameID }) else { return }
        frames[index].transform = Self.columns(world)
        frames[index].width = width
        frames[index].height = height
        PhysicalRooms.shared.record(frames[index])
        show(frames[index])
        membersChanged()
    }

    /// Frames whose places here were not found, stood in a row before the
    /// reader to be carried where they belong (19 Nov 2026).
    func standBeforeReader(_ ids: Set<String>) {
        let head = headPose() ?? (SIMD3<Float>(0, 1.5, 0), SIMD3<Float>(0, 0, -1))
        var forward = SIMD3<Float>(head.forward.x, 0, head.forward.z)
        forward = simd_length(forward) > 1e-4 ? simd_normalize(forward) : SIMD3<Float>(0, 0, -1)
        let up = SIMD3<Float>(0, 1, 0)
        let ordered = frames.filter { ids.contains($0.id) }
        for (n, frame) in ordered.enumerated() {
            // Spread round the reader, 2 m away, 25° apart.
            let angle = (Float(n) - Float(ordered.count - 1) / 2) * (.pi / 7.2)
            let facing = simd_act(simd_quatf(angle: angle, axis: up), forward)
            let middle = head.position + facing * 2
            let normal = -facing
            let right = simd_normalize(simd_cross(up, normal))
            let m = simd_float4x4(SIMD4<Float>(right, 0), SIMD4<Float>(up, 0), SIMD4<Float>(normal, 0),
                                  SIMD4<Float>(middle, 1))
            guard let index = frames.firstIndex(where: { $0.id == frame.id }) else { continue }
            frames[index].transform = Self.columns(m)
            show(frames[index])
        }
        membersChanged()
    }

    // MARK: The room question (19 Nov 2026, Frode)

    @ObservationIgnored private var question: Entity?
    @ObservationIgnored private var questionShown = false

    /// The question floats before the reader while the room is not known,
    /// and goes when it is.
    private func layQuestion() {
        let asking = !PhysicalRooms.shared.isSettled || PhysicalRooms.shared.scanning
        // Kept in view while it waits: turned away from, or walked away
        // from, it comes round again before the reader.
        if asking, questionShown, let entity = question, let head = headPose() {
            let toQuestion = entity.position - head.position
            var forward = SIMD3<Float>(head.forward.x, 0, head.forward.z)
            forward = simd_length(forward) > 1e-4 ? simd_normalize(forward) : SIMD3<Float>(0, 0, -1)
            let flat = SIMD3<Float>(toQuestion.x, 0, toQuestion.z)
            let distance = simd_length(flat)
            let inView = distance > 0.3 && simd_dot(flat / max(distance, 1e-4), forward) > 0.5
            if !inView || distance > 2.5 { questionShown = false }
        }
        guard asking != questionShown else { return }
        let entity = question ?? {
            let made = Entity()
            made.name = "roomQuestion"
            made.components.set(ViewAttachmentComponent(rootView: RoomQuestionView()))
            root.addChild(made)
            question = made
            return made
        }()
        guard asking else {
            questionShown = false
            entity.isEnabled = false
            return
        }
        // Laid once the head is known, so it stands before the reader.
        guard let head = headPose() else { return }
        questionShown = true
        entity.isEnabled = true
        var forward = SIMD3<Float>(head.forward.x, 0, head.forward.z)
        forward = simd_length(forward) > 1e-4 ? simd_normalize(forward) : SIMD3<Float>(0, 0, -1)
        entity.position = head.position + forward * 1.1 - SIMD3<Float>(0, 0.15, 0)
        entity.orientation = simd_quatf(from: SIMD3<Float>(0, 0, 1), to: -forward)
    }

    /// The frames of the room open now, for choosing which physical room
    /// knows them best.
    var frameIDsHere: Set<String> { Set(here.map(\.id)) }

    /// The physical room changed — found, or made: every frame to its place.
    func roomChanged() {
        placeForRoom()
        showAll()
        membersChanged()
    }

    // MARK: Filed by hand (18 Nov 2026, Frode)

    /// The frame (of a kind, in sight, open) a place is over, within
    /// `stickDistance` of its face, whatever its kind.
    func kindFrameID(near position: SIMD3<Float>) -> String? {
        shownHere.first { !$0.isPanel && frameID(near: position, kind: $0.kind) == $0.id }?.id
    }

    /// The frame a concept was filed into by hand, and its kind.
    func filedFrame(of memberID: String) -> String? {
        here.first { !$0.isPanel && ($0.members ?? []).contains(memberID) }?.id
    }

    func filedKind(of memberID: String) -> String? {
        filedFrame(of: memberID).flatMap { frame($0)?.kind }
    }

    /// The frame a member stands in now, as last laid.
    func owner(of memberID: String) -> String? { memberFrame[memberID] }

    /// Pushed into a frame of a kind: it is that frame's from now on — off
    /// any panel, out of every other frame's hand and pulled lists — and
    /// stands in it.
    func file(_ memberID: String, into frameID: String) {
        for other in here where other.id != frameID
            && ((other.members ?? []).contains(memberID) || other.pulled.contains(memberID)) {
            update(other.id) {
                $0.members?.removeAll { $0 == memberID }
                $0.pulled.removeAll { $0 == memberID }
            }
        }
        update(frameID) {
            var members = $0.members ?? []
            if !members.contains(memberID) { members.append(memberID) }
            $0.members = members
            $0.pulled.removeAll { $0 == memberID }
        }
        forgetLoose([memberID])
        membersChanged()
    }

    // MARK: Panels (18 Nov 2026, Frode)

    /// The room's panels, in sight or put away.
    var panelsHere: [RoomFrame] { here.filter(\.isPanel) }

    /// A new panel before the reader, unnamed, Move & Resize on.
    func putUpPanel() { putUp(kind: RoomFrame.panelKind) }

    /// A panel's name given or changed; empty, it is unnamed again.
    func rename(_ id: String, to name: String) {
        let given = name.trimmingCharacters(in: .whitespacesAndNewlines)
        update(id) { $0.name = given.isEmpty ? nil : given }
    }

    /// A panel made a frame of a category, or back into a plain panel
    /// (19 Nov 2026, Frode: chosen beside its name). A category frame
    /// holds concepts only: the articles stuck to the panel are let go
    /// where they stand, and the concepts stay, filed into it.
    func setKind(_ id: String, to kind: String) {
        guard let frame = frame(id), frame.kind != kind else { return }
        if kind != RoomFrame.panelKind {
            // Concepts are "person:" and "keyword:" items (EPUBMapView's
            // personItemPrefix and keywordItemPrefix).
            func isConcept(_ member: String) -> Bool {
                member.hasPrefix("person:") || member.hasPrefix("keyword:")
            }
            var places: [String: SIMD3<Float>] = [:]
            for (member, owner) in memberFrame where owner == id && !isConcept(member) {
                if let slot = slots[member] { places[member] = slot }
            }
            update(id) {
                $0.kind = kind
                $0.members = ($0.members ?? []).filter(isConcept)
                $0.pulled = []
            }
            if !places.isEmpty { placeLoose(places) }
        } else {
            update(id) { $0.kind = kind; $0.pulled = [] }
        }
        membersChanged()
    }

    /// A frame or panel put away shown again, or one in sight put away.
    func toggleShown(_ id: String) {
        guard let frame = frame(id) else { return }
        if frame.isShown { hide(id) } else { update(id) { $0.hidden = nil }; membersChanged() }
    }

    /// The panel an article or concept is stuck to, if any.
    func panelHolding(_ memberID: String) -> String? {
        here.first { $0.isPanel && ($0.members ?? []).contains(memberID) }?.id
    }

    /// Every member of the room's panels in sight.
    var panelMembers: Set<String> {
        Set(shownHere.filter(\.isPanel).flatMap { $0.members ?? [] })
    }

    /// Stuck to a panel: off any other panel, and out of any frame it was
    /// pulled from, so it stands in one place only.
    func stick(_ memberID: String, to panelID: String) {
        for other in here where other.id != panelID
            && (other.members?.contains(memberID) == true || other.pulled.contains(memberID)) {
            update(other.id) {
                $0.members?.removeAll { $0 == memberID }
                $0.pulled.removeAll { $0 == memberID }
            }
        }
        update(panelID) {
            var members = $0.members ?? []
            if !members.contains(memberID) { members.append(memberID) }
            $0.members = members
            $0.pulled.removeAll { $0 == memberID }
        }
        membersChanged()
    }

    /// Carried off its panel: it stands loose in the room, kept as pulled
    /// from the panel — so no frame of its kind gathers it, it stands
    /// whatever the room hides, and Put All Back brings it home.
    func unstick(_ memberID: String) {
        for panel in here where panel.isPanel && (panel.members ?? []).contains(memberID) {
            update(panel.id) {
                $0.members?.removeAll { $0 == memberID }
                if !$0.pulled.contains(memberID) { $0.pulled.append(memberID) }
            }
        }
        membersChanged()
    }

    /// Off the panel for good: no longer its member nor pulled from it — an
    /// article sent home by Put Back.
    func release(_ memberID: String) {
        for panel in here where panel.isPanel
            && ((panel.members ?? []).contains(memberID) || panel.pulled.contains(memberID)) {
            update(panel.id) {
                $0.members?.removeAll { $0 == memberID }
                $0.pulled.removeAll { $0 == memberID }
            }
        }
        membersChanged()
    }

    /// What has been carried off the room's panels in sight, standing loose.
    var panelLoose: Set<String> {
        Set(shownHere.filter(\.isPanel).flatMap(\.pulled))
    }

    /// Deleted: gone from the room on every device; its loose members stay.
    /// A panel's members stay too, standing where they were stuck.
    func remove(_ id: String) {
        if frame(id)?.isPanel == true {
            var places: [String: SIMD3<Float>] = [:]
            for (member, owner) in memberFrame where owner == id {
                if let slot = slots[member] { places[member] = slot }
            }
            if !places.isEmpty { placeLoose(places) }
        }
        arrangingIDs.remove(id)
        if menuOpenFor == id { menuOpenFor = nil }
        update(id) { $0.deleted = true; $0.pulled = [] }
        entities[id]?.removeFromParent()
        entities[id] = nil
        frameKeys[id] = nil
        membersChanged()
    }

    func hide(_ id: String) {
        arrangingIDs.remove(id)
        if menuOpenFor == id { menuOpenFor = nil }
        update(id) { $0.hidden = true }
        membersChanged()
    }

    // MARK: Looks, chosen

    func choose(picture: String, for id: String) { update(id) { $0.picture = picture } }

    func setStyle(_ style: Style?, for id: String) {
        update(id) {
            $0.frame = style?.rawValue
            if style != nil, $0.frameThickness == nil { $0.frameThickness = Thickness.medium.rawValue }
        }
    }

    func setThickness(_ thickness: Thickness, for id: String) {
        update(id) {
            if $0.frame == nil { $0.frame = Style.blackMatte.rawValue }
            $0.frameThickness = thickness.rawValue
        }
    }

    func setTransparency(_ level: Transparency, for id: String) {
        update(id) { $0.transparency = level == .opaque ? nil : level.rawValue }
    }

    func setOffsetFrame(_ on: Bool, for id: String) { update(id) { $0.offsetFrame = on } }

    func requestChooser(for id: String) {
        chooserTargetID = id
        chooserRequests += 1
    }

    /// A photo from Photos for the frame the chooser was asked for: kept,
    /// at most 4096 px on its longest side, in the community folder's
    /// Frame Pictures (and this headset's own copy).
    func choosePhoto(_ data: Data) {
        guard let id = chooserTargetID,
              let image = Self.downsampled(data, longestSide: 4096),
              let jpeg = image.jpegData(compressionQuality: 0.88) else { return }
        let name = UUID().uuidString + ".jpg"
        let local = Self.localPictures
        try? FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try? jpeg.write(to: local.appendingPathComponent(name))
        if let folder = community() {
            Self.withScope(folder) { url in
                let shared = url.appendingPathComponent(Self.sharedPictures, isDirectory: true)
                try? FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
                try? jpeg.write(to: shared.appendingPathComponent(name))
            }
        }
        choose(picture: "photo:" + name, for: id)
    }

    // MARK: Move & Resize

    func isArranging(_ id: String) -> Bool { arrangingIDs.contains(id) }

    func toggleArranging(_ id: String) {
        if arrangingIDs.contains(id) {
            finishArranging(id)
        } else {
            // One frame at a time from its own menu (18 Nov 2026, Frode):
            // any other being moved is done and kept first. (The bar's
            // Edit & Move takes every frame at once.)
            for other in arrangingIDs where other != id {
                arrangingIDs.remove(other)
                alignToWall(other)
            }
            save()
            arrangingIDs.insert(id)
            menuOpenFor = nil
            showAll()
            membersChanged()
        }
    }

    /// Done on one frame: kept where it stands, flat on a wall near it.
    func finishArranging(_ id: String) {
        guard arrangingIDs.remove(id) != nil else { return }
        alignToWall(id)
        showAll()
        save()
        membersChanged()
    }

    /// Whether every frame in sight in the room is being moved and resized.
    var isEditingAll: Bool {
        let open = shownHere.filter { !$0.isFolded }
        return !open.isEmpty && open.allSatisfy { arrangingIDs.contains($0.id) }
    }

    /// The bar's Frames ▸ Edit & Move (16 Nov 2026, Frode): every frame in
    /// sight into Move & Resize at once — its handles, its buttons — or,
    /// all of them already, every one done and kept.
    /// Redo Layout: the panels standing all made movable at once, so they
    /// can be put where they belong in this room — each kept as it is let
    /// go (its anchor here made afresh). Done from the bar's Edit & Move,
    /// or each panel's own Done.
    func redoPlacesHere() {
        roomMenuOpenFor = nil
        RoomLog.write("redo layout in \(PhysicalRooms.shared.currentName ?? "the room")")
        if !isEditingAll { toggleEditAll() }
    }

    func toggleEditAll() {
        if isEditingAll {
            let ids = arrangingIDs
            arrangingIDs = []
            for id in ids { alignToWall(id) }
        } else {
            menuOpenFor = nil
            for frame in shownHere where !frame.isFolded { arrangingIDs.insert(frame.id) }
        }
        showAll()
        save()
        membersChanged()
    }

    /// Pinched and carried: follows the hand, upright, facing as it faced.
    /// Folded, it moves so at any time and turns to the reader as it goes.
    func drag(_ entity: Entity, to world: SIMD3<Float>) {
        guard let hit = entity.components[RoomFrameHitComponent.self] else { return }
        if hit.isRotate { rotate(hit, to: world); return }
        if hit.x != 0 || hit.y != 0 { pull(hit, to: world); return }
        guard let index = frames.firstIndex(where: { $0.id == hit.frameID }),
              arrangingIDs.contains(hit.frameID) || frames[index].isFolded,
              let entity = entities[hit.frameID] else { return }
        var m = Self.matrix(frames[index].transform)
        let middle = Self.translation(m)
        if dragStart?.id != hit.frameID { dragStart = (hit.frameID, middle, world) }
        guard let start = dragStart else { return }
        let moved = start.middle + (world - start.grab)
        if frames[index].isFolded, let eye = headPose()?.position {
            var toward = SIMD3<Float>(eye.x - moved.x, 0, eye.z - moved.z)
            if simd_length(toward) > 0.05 {
                toward = simd_normalize(toward)
                let up = SIMD3<Float>(0, 1, 0)
                let right = simd_normalize(simd_cross(up, toward))
                m.columns.0 = SIMD4<Float>(right, 0)
                m.columns.1 = SIMD4<Float>(up, 0)
                m.columns.2 = SIMD4<Float>(toward, 0)
            }
        }
        m.columns.3 = SIMD4<Float>(moved, 1)
        frames[index].transform = Self.columns(m)
        entity.transform = Transform(matrix: m)
    }

    /// Both hands: larger or smaller, its shape kept.
    func resize(_ entity: Entity, by magnification: Double) {
        guard let id = entity.components[RoomFrameHitComponent.self]?.frameID, arrangingIDs.contains(id),
              let index = frames.firstIndex(where: { $0.id == id }) else { return }
        if resizeStart?.id != id { resizeStart = (id, frames[index].width, frames[index].height) }
        guard let start = resizeStart else { return }
        let width = min(max(start.width * Float(magnification), 0.3), 15)
        frames[index].width = width
        frames[index].height = width * start.height / max(start.width, 0.01)
        show(frames[index])
    }

    /// A handle pulled: its side, or both at a corner, follows the hand
    /// along the frame; the opposite side stays.
    private func pull(_ grip: RoomFrameHitComponent, to world: SIMD3<Float>) {
        guard arrangingIDs.contains(grip.frameID),
              let index = frames.firstIndex(where: { $0.id == grip.frameID }) else { return }
        var m = Self.matrix(frames[index].transform)
        let right = SIMD3<Float>(m.columns.0.x, m.columns.0.y, m.columns.0.z)
        let up = SIMD3<Float>(m.columns.1.x, m.columns.1.y, m.columns.1.z)
        let normal = SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        let middle = Self.translation(m)
        let onFrame = world - simd_dot(world - middle, normal) * normal
        if resizeStart?.id != grip.frameID {
            resizeStart = (grip.frameID, frames[index].width, frames[index].height)
            dragStart = (grip.frameID, middle, onFrame)
        }
        guard let size = resizeStart, let start = dragStart else { return }
        let moved = onFrame - start.grab
        let width = grip.x == 0 ? size.width : min(max(size.width + grip.x * simd_dot(moved, right), 0.3), 20)
        let height = grip.y == 0 ? size.height : min(max(size.height + grip.y * simd_dot(moved, up), 0.3), 10)
        let newMiddle = start.middle + right * (grip.x * (width - size.width) / 2)
            + up * (grip.y * (height - size.height) / 2)
        m.columns.3 = SIMD4<Float>(newMiddle, 1)
        frames[index].width = width
        frames[index].height = height
        frames[index].transform = Self.columns(m)
        show(frames[index])
    }

    /// A rotate handle pulled: the frame turns about its centre to face
    /// where the hand carried that side, upright.
    private func rotate(_ grip: RoomFrameHitComponent, to world: SIMD3<Float>) {
        guard arrangingIDs.contains(grip.frameID),
              let index = frames.firstIndex(where: { $0.id == grip.frameID }) else { return }
        var m = Self.matrix(frames[index].transform)
        let middle = Self.translation(m)
        let flat = SIMD3<Float>(world.x - middle.x, 0, world.z - middle.z)
        guard simd_length(flat) > 0.05 else { return }
        let direction = simd_normalize(flat)
        let right = grip.x >= 0 ? direction : -direction
        let up = SIMD3<Float>(0, 1, 0)
        let normal = simd_normalize(simd_cross(right, up))
        m.columns.0 = SIMD4<Float>(right, 0)
        m.columns.1 = SIMD4<Float>(up, 0)
        m.columns.2 = SIMD4<Float>(normal, 0)
        frames[index].transform = Self.columns(m)
        rotateStart = grip.frameID
        show(frames[index])
    }

    /// Let go: flat on a real wall within 15 cm, and kept. A folded frame
    /// carried somewhere new keeps its turn.
    func endGesture() {
        let moved = resizeStart?.id ?? dragStart?.id ?? rotateStart
        dragStart = nil
        resizeStart = nil
        rotateStart = nil
        guard let moved else { return }
        if frame(moved)?.isFolded != true { alignToWall(moved) }
        if let frame = frame(moved) { show(frame) }
        update(moved) { _ in }
        if !arrangingIDs.contains(moved) { membersChanged() }
    }

    /// Flat on the wall nearest it, where it is — only when brought within
    /// 15 cm of one: a frame left out in the room stays.
    private func alignToWall(_ id: String, reach: Float = 0.15) {
        guard let index = frames.firstIndex(where: { $0.id == id }) else { return }
        let m = Self.matrix(frames[index].transform)
        guard let pose = wallNear(Self.translation(m), reach) else { return }
        frames[index].transform = Self.columns(Self.matrix(pose.orientation, at: pose.position))
        // Remembered for this physical room, as every move is.
        PhysicalRooms.shared.record(frames[index])
        show(frames[index])
    }

    /// Snap to Wall: flat on the nearest wall found, however far.
    func snapToWall(_ id: String) {
        alignToWall(id, reach: 50)
        update(id) { _ in }
    }

    /// Turn 90° right or left about the room's up.
    func turn(_ id: String, clockwise: Bool) {
        guard let index = frames.firstIndex(where: { $0.id == id }) else { return }
        var m = Self.matrix(frames[index].transform)
        let right = SIMD3<Float>(m.columns.0.x, m.columns.0.y, m.columns.0.z)
        let normal = SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        m.columns.0 = SIMD4<Float>(clockwise ? normal : -normal, 0)
        m.columns.2 = SIMD4<Float>(clockwise ? -right : right, 0)
        frames[index].transform = Self.columns(m)
        update(id) { _ in }
    }

    /// Lift from Wall: 20 cm out toward the reader, so it can be taken hold
    /// of again.
    func liftFromWall(_ id: String) {
        guard let index = frames.firstIndex(where: { $0.id == id }) else { return }
        var m = Self.matrix(frames[index].transform)
        let normal = SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        m.columns.3 = SIMD4<Float>(Self.translation(m) + normal * 0.2, 1)
        frames[index].transform = Self.columns(m)
        update(id) { _ in }
        membersChanged()
    }

    // MARK: Folding

    func fold(_ id: String) {
        guard let frame = frame(id), !frame.isFolded else { return }
        arrangingIDs.remove(id)
        menuOpenFor = nil
        update(id) {
            $0.unfolded = .init(width: $0.width, height: $0.height, transform: $0.transform)
            let width = min(Self.foldedWidth, $0.width)
            $0.height = min(max(width * $0.height / max($0.width, 0.01), 0.12), width)
            $0.width = width
        }
        membersChanged()
    }

    func unfold(_ id: String) {
        guard let full = frame(id)?.unfolded else { return }
        menuOpenFor = nil
        update(id) {
            $0.width = full.width
            $0.height = full.height
            $0.transform = full.transform
            $0.unfolded = nil
        }
        membersChanged()
    }

    // MARK: Members

    /// A member pulled out to stand loose in the room.
    func pullOut(_ memberID: String) {
        guard let frameID = memberFrame[memberID] else { return }
        update(frameID) { if !$0.pulled.contains(memberID) { $0.pulled.append(memberID) } }
    }

    /// A member put back in its frame — out of whichever frame it was
    /// pulled from, so put back into another of its kind it stands there.
    func putBack(_ memberID: String, in frameID: String) {
        for other in here where other.id != frameID && other.pulled.contains(memberID) {
            update(other.id) { $0.pulled.removeAll { $0 == memberID } }
        }
        update(frameID) { $0.pulled.removeAll { $0 == memberID } }
        forgetLoose([memberID])
        membersChanged()
    }

    /// Move All Out: every member lifted 10 cm out of the frame, keeping
    /// the frame's arrangement, loose in the room from then on.
    func moveAllOut(_ frameID: String) {
        guard let frame = frame(frameID) else { return }
        menuOpenFor = nil
        let normal = Self.normal(Self.matrix(frame.transform))
        var places: [String: SIMD3<Float>] = [:]
        for (id, owner) in memberFrame where owner == frameID {
            if let slot = slots[id] { places[id] = slot + normal * 0.1 }
        }
        guard !places.isEmpty else { return }
        if frame.isPanel {
            // Moved out, a panel's members stand loose, pulled from it.
            update(frameID) {
                $0.members = ($0.members ?? []).filter { places[$0] == nil }
                $0.pulled = Array(Set($0.pulled).union(places.keys)).sorted()
            }
        } else {
            update(frameID) { $0.pulled = Array(Set($0.pulled).union(places.keys)).sorted() }
        }
        placeLoose(places)
        membersChanged()
    }

    /// Put All Back: every pulled member home again.
    func putAllBack(_ frameID: String) {
        guard let frame = frame(frameID) else { return }
        menuOpenFor = nil
        let ids = Set(frame.pulled)
        if frame.isPanel {
            // Back on the panel, after what stands on it now.
            update(frameID) {
                var members = $0.members ?? []
                members += $0.pulled.filter { !members.contains($0) }
                $0.members = members
                $0.pulled = []
            }
        } else {
            update(frameID) { $0.pulled = [] }
            // And every concept of its kind loose in the room, filed here
            // (18 Nov 2026, Frode): Move All Back gathers them all.
            for id in looseConcepts(frame.kind) where !ids.contains(id) {
                file(id, into: frameID)
            }
        }
        forgetLoose(ids)
        membersChanged()
    }

    /// The frame of this kind a place is over, within `stickDistance` of
    /// its face — where a member let go goes back. Nil: none.
    func frameID(near position: SIMD3<Float>, kind: String) -> String? {
        for frame in shownHere where frame.kind == kind && !frame.isFolded {
            let m = Self.matrix(frame.transform)
            let offset = position - Self.translation(m)
            let out = simd_dot(offset, Self.normal(m))
            guard out > -0.3, out - Self.frontOffset <= Self.stickDistance,
                  abs(simd_dot(offset, Self.right(m))) <= frame.width / 2 + 0.05,
                  abs(simd_dot(offset, Self.up(m))) <= frame.height / 2 + 0.05 else { continue }
            return frame.id
        }
        return nil
    }

    /// Members of a frame in sight that is folded or being arranged: they
    /// wait, out of sight, until it is laid again.
    @ObservationIgnored private var waiting: Set<String> = []
    func isWaiting(_ id: String) -> Bool { waiting.contains(id) }

    /// The members of frames no longer laid, let go.
    func forgetMembers(except laid: Set<String>) {
        for (id, owner) in memberFrame where !laid.contains(owner) {
            memberFrame[id] = nil
            slots[id] = nil
            slotScale[id] = nil
        }
        let shownIDs = Set(shownHere.map(\.id))
        waitingOwner = waitingOwner.filter { shownIDs.contains($0.value) && laid.contains($0.value) }
        waiting = Set(waitingOwner.keys)
    }
    @ObservationIgnored private var waitingOwner: [String: String] = [:]

    /// Lays one frame's members in its columns (Knowledge Space's): top to
    /// bottom then left to right, alphabetical as given, each column as
    /// wide as its widest, the block centred within 92% of the frame,
    /// everything smaller together (never below a third) until it fits.
    /// The pulled stand loose; their places stay as shadows.
    func lay(frameID: String, members: [(id: String, size: SIMD2<Float>)]) -> [String: (position: SIMD3<Float>, scale: Float)] {
        for (id, owner) in memberFrame where owner == frameID { memberFrame[id] = nil; slots[id] = nil; slotScale[id] = nil }
        for (id, owner) in waitingOwner where owner == frameID { waitingOwner[id] = nil }
        guard let frame = frame(frameID), laysMembers(frame), !members.isEmpty else {
            if let frame = frame(frameID), frame.isShown {
                for member in members where !frame.pulled.contains(member.id) { waitingOwner[member.id] = frameID }
            }
            waiting = Set(waitingOwner.keys)
            placeShadows(for: frameID, names: [:])
            return [:]
        }
        waiting = Set(waitingOwner.keys)
        let m = Self.matrix(frame.transform)
        let widths = members.map(\.size.x)
        let height = min(members.map(\.size.y).max() ?? 0.04, 0.12)
        let placed = Self.columns(widths: widths, height: height,
                                  frameWidth: frame.width, frameHeight: frame.height)
        var result: [String: (position: SIMD3<Float>, scale: Float)] = [:]
        var shadows: [String: SIMD3<Float>] = [:]
        for (index, member) in members.enumerated() {
            let local = SIMD3<Float>(placed.places[index].x, placed.places[index].y, Self.frontOffset)
            let world = Self.translation(m) + Self.right(m) * local.x + Self.up(m) * local.y + Self.normal(m) * local.z
            if frame.pulled.contains(member.id) {
                shadows[member.id] = SIMD3<Float>(local.x, local.y, 0.004)
                continue
            }
            memberFrame[member.id] = frameID
            slots[member.id] = world
            slotScale[member.id] = placed.scale
            result[member.id] = (world, placed.scale)
        }
        placeShadows(for: frameID, names: shadows, scale: placed.scale)
        return result
    }

    /// Knowledge Space's columns: each member's middle in the frame's own
    /// plane, and the scale all share.
    nonisolated static func columns(widths: [Float], height: Float, frameWidth: Float, frameHeight: Float)
        -> (places: [SIMD2<Float>], scale: Float) {
        let usableWidth = frameWidth * 0.92, usableHeight = frameHeight * 0.92
        let gap: Float = 0.02
        let columnGap = gap / 2
        func plan(_ scale: Float) -> (rows: Int, columnWidths: [Float], width: Float) {
            let rowHeight = (height + gap) * scale
            let rows = max(1, Int((usableHeight + gap * scale) / rowHeight))
            var columnWidths: [Float] = []
            var start = 0
            while start < widths.count {
                let end = min(start + rows, widths.count)
                columnWidths.append((widths[start..<end].max() ?? 0) * scale)
                start = end
            }
            let width = columnWidths.reduce(0, +) + columnGap * scale * Float(max(columnWidths.count - 1, 0))
            return (rows, columnWidths, width)
        }
        var scale: Float = 1
        while scale > 0.34, plan(scale).width > usableWidth { scale -= 0.04 }
        scale = max(scale, 0.34)
        let layout = plan(scale)
        let usedRows = min(layout.rows, widths.count)
        let blockHeight = Float(usedRows) * (height + gap) * scale - gap * scale
        var lefts: [Float] = []
        var x = -layout.width / 2
        for width in layout.columnWidths {
            lefts.append(x)
            x += width + columnGap * scale
        }
        var places: [SIMD2<Float>] = []
        for index in widths.indices {
            let column = index / layout.rows, row = index % layout.rows
            let px = lefts[column] + widths[index] * scale / 2
            let py = blockHeight / 2 - Float(row) * (height + gap) * scale - height * scale / 2
            places.append(SIMD2(px, py))
        }
        return (places, scale)
    }

    // MARK: Drawing

    /// A frame's entity made or remade: its picture on a plane drawn behind
    /// everything, its border, its title, and its handles while arranging.
    private func show(_ frame: RoomFrame) {
        guard frame.deleted != true else { return }
        let entity = entities[frame.id] ?? {
            let made = ModelEntity()
            made.name = "roomFrame:" + frame.id
            root.addChild(made)
            entities[frame.id] = made
            return made
        }()
        let previous = entity.model?.materials
        entity.model = ModelComponent(mesh: .generatePlane(width: frame.width, height: frame.height),
                                      materials: previous ?? [Self.greyMaterial])
        if frame.transform.count == 16 { entity.transform = Transform(matrix: Self.matrix(frame.transform)) }
        entity.components.set(RoomFrameHitComponent(frameID: frame.id))
        entity.components.set(ModelSortGroupComponent(group: .planarUIAlwaysBehind, order: 0))
        // A frame the reader is moving is never hidden, whatever its anchor
        // says (19 Nov 2026, Frode: they disappeared when moved).
        let shown = frame.venue == venue && frame.isShown && frame.transform.count == 16
            && (PhysicalRooms.shared.shouldShow(frame.id) || arrangingIDs.contains(frame.id))
        if entity.isEnabled != shown { entity.isEnabled = shown }
        if shown { PhysicalRooms.shared.noteShown(frame.id) }
        decorate(entity, for: frame)
        border(entity, for: frame)
        placeTitle(on: entity, for: frame)
        placeCornerEdit(on: entity, for: frame)
        let level = frame.transparency.flatMap(Transparency.init(rawValue:)) ?? .opaque
        if level == .opaque {
            entity.components.remove(OpacityComponent.self)
        } else {
            entity.components.set(OpacityComponent(opacity: level.opacity))
        }
        showPicture(frame, on: entity, shown: shown)
    }

    private func showPicture(_ frame: RoomFrame, on entity: ModelEntity, shown: Bool) {
        if frame.picture == "grey" {
            entity.model?.materials = [Self.greyMaterial]
            textures[frame.id] = nil
            return
        }
        let aspect = frame.width / max(frame.height, 0.01)
        if let made = textures[frame.id], made.picture == frame.picture {
            Self.show(made.texture, imageAspect: made.aspect, frameAspect: aspect, on: entity)
            return
        }
        if let made = pictureTextures[frame.picture] {
            textures[frame.id] = (frame.picture, made.texture, made.aspect)
            Self.show(made.texture, imageAspect: made.aspect, frameAspect: aspect, on: entity)
            return
        }
        guard shown else { return }
        let picture = frame.picture, id = frame.id
        guard loading[id] != picture else { return }
        loading[id] = picture
        let folder = community()
        Task { @MainActor in
            defer { if self.loading[id] == picture { self.loading[id] = nil } }
            let drawn = await Task.detached(priority: .userInitiated) {
                Self.wholeImage(for: picture, community: folder)?.cgImage
            }.value
            guard let image = drawn,
                  let texture = try? await TextureResource(image: image, options: .init(semantic: .color,
                                                                                        mipmapsMode: .allocateAndGenerateAll)),
                  let current = self.frame(id), current.picture == picture,
                  let entity = self.entities[id] else { return }
            let imageAspect = Float(image.width) / Float(max(image.height, 1))
            self.pictureTextures[picture] = (texture, imageAspect)
            self.textures[id] = (picture, texture, imageAspect)
            Self.show(texture, imageAspect: imageAspect, frameAspect: current.width / max(current.height, 0.01), on: entity)
        }
    }

    private static var greyMaterial: UnlitMaterial { UnlitMaterial(color: UIColor(white: 0.16, alpha: 1)) }

    private static let sharpSampler: MaterialParameters.Texture.Sampler = {
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        descriptor.mipFilter = .linear
        descriptor.maxAnisotropy = 16
        descriptor.sAddressMode = .clampToEdge
        descriptor.tAddressMode = .clampToEdge
        return .init(descriptor)
    }()

    /// The image filling the frame, its middle kept: cropped, never squashed.
    private static func show(_ texture: TextureResource, imageAspect: Float, frameAspect: Float, on entity: ModelEntity) {
        var material = UnlitMaterial()
        material.color = .init(tint: .white, texture: .init(texture, sampler: sharpSampler))
        let scale: SIMD2<Float> = frameAspect > imageAspect ? [1, imageAspect / frameAspect] : [frameAspect / imageAspect, 1]
        material.textureCoordinateTransform = .init(offset: (SIMD2<Float>(1, 1) - scale) / 2, scale: scale)
        entity.model?.materials = [material]
    }

    /// How far a frame's border stands past its edge; nothing, unframed.
    func borderWidth(of frame: RoomFrame) -> Float {
        guard frame.frame != nil else { return 0 }
        return (frame.frameThickness.flatMap(Thickness.init(rawValue:)) ?? Self.defaultThickness).width
    }

    /// The border: four bars round the edge, remade only when its style,
    /// thickness, offset or the frame's size change. Wood wears its grain.
    private func border(_ entity: ModelEntity, for frame: RoomFrame) {
        let style = frame.frame.flatMap(Style.init(rawValue:))
        let thickness = frame.frameThickness.flatMap(Thickness.init(rawValue:)) ?? .medium
        let offset = frame.offsetFrame ?? true
        let key = style.map { "\($0.rawValue)|\(thickness.rawValue)|\(frame.width)|\(frame.height)|\(offset)" } ?? "none"
        guard frameKeys[frame.id] != key else { return }
        frameKeys[frame.id] = key
        entity.findEntity(named: "border")?.removeFromParent()
        guard let style else { return }
        let holder = Entity()
        holder.name = "border"
        let bar = thickness.width
        let depth = max(0.015, bar * 0.6)
        let material = Self.material(style)
        let w = frame.width, h = frame.height
        // Offset: from the wall out, the picture set into it; else from
        // just behind the picture.
        let z = depth / 2 - (offset ? 0.03 : 0.01)
        for (size, at) in [(SIMD3<Float>(w + 2 * bar, bar, depth), SIMD3<Float>(0, h / 2 + bar / 2, z)),
                           (SIMD3<Float>(w + 2 * bar, bar, depth), SIMD3<Float>(0, -h / 2 - bar / 2, z)),
                           (SIMD3<Float>(bar, h, depth), SIMD3<Float>(-w / 2 - bar / 2, 0, z)),
                           (SIMD3<Float>(bar, h, depth), SIMD3<Float>(w / 2 + bar / 2, 0, z))] {
            let piece = ModelEntity(mesh: .generateBox(size: size, cornerRadius: min(bar, depth) * 0.12),
                                    materials: [material])
            piece.components.set(ModelSortGroupComponent(group: .planarUIAlwaysBehind, order: 1))
            piece.position = at
            holder.addChild(piece)
        }
        entity.addChild(holder)
        if style.isWood {
            Task { @MainActor in
                guard let grained = await Self.woodMaterial(style), self.frameKeys[frame.id] == key else { return }
                for case let piece as ModelEntity in holder.children { piece.model?.materials = [grained] }
            }
        }
    }

    private static func material(_ style: Style) -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: style.colour)
        material.metallic = .init(floatLiteral: 0)
        switch style {
        case .blackMatte:
            material.baseColor = .init(tint: .black)
            material.roughness = .init(floatLiteral: 1)
            material.specular = .init(floatLiteral: 0)
        case .blackShiny:
            material.roughness = .init(floatLiteral: 0.12)
            material.clearcoat = .init(floatLiteral: 1)
            material.clearcoatRoughness = .init(floatLiteral: 0.03)
        case .lightGrey, .midGrey, .darkGrey:
            material.roughness = .init(floatLiteral: 0.5)
            material.clearcoat = .init(floatLiteral: 0.2)
        default:
            material.roughness = .init(floatLiteral: 0.55)
        }
        return material
    }

    private static var woodMaterials: [Style: PhysicallyBasedMaterial] = [:]

    /// Wood: its colour streaked with grain along the bar, a little sheen.
    private static func woodMaterial(_ style: Style) async -> PhysicallyBasedMaterial? {
        if let made = woodMaterials[style] { return made }
        let size = CGSize(width: 1024, height: 128)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            style.colour.setFill()
            cg.fill(CGRect(origin: .zero, size: size))
            var seed: UInt64 = 0xBEEF &+ UInt64(style.rawValue.count)
            func next() -> CGFloat {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return CGFloat(seed >> 33) / CGFloat(1 << 31)
            }
            for _ in 0..<140 {
                let y = next() * size.height
                let dark = next() > 0.35
                UIColor(white: dark ? 0 : 1, alpha: 0.05 + next() * 0.12).setStroke()
                cg.setLineWidth(0.6 + next() * 2.2)
                cg.move(to: CGPoint(x: 0, y: y))
                var x: CGFloat = 0
                var yy = y
                while x < size.width {
                    x += 40 + next() * 60
                    yy += (next() - 0.5) * 3
                    cg.addLine(to: CGPoint(x: x, y: yy))
                }
                cg.strokePath()
            }
        }
        guard let cgImage = image.cgImage,
              let texture = try? await TextureResource(image: cgImage, options: .init(semantic: .color)) else { return nil }
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: .white, texture: .init(texture))
        material.roughness = .init(floatLiteral: 0.5)
        material.metallic = .init(floatLiteral: 0)
        material.clearcoat = .init(floatLiteral: 0.3)
        woodMaterials[style] = material
        return material
    }

    /// Points in an attachment to the metre.
    static let pointsPerMetre: Float = 1360
    /// The corner Edit's least height in metres; its width is twice that.
    /// Half Knowledge Space's (18 Nov 2026, Frode).
    static let editTargetHeight: Float = 0.0325
    @ObservationIgnored private var cornerKeys: [String: String] = [:]

    /// Edit at the bottom left (18 Nov 2026, Frode — Knowledge Space's):
    /// the word alone on its glass capsule at the frame's corner — no block
    /// behind it — very faint until looked at; above it the menu it opens.
    /// Folded, the title alone stands, and opens the menu.
    private func placeCornerEdit(on entity: ModelEntity, for frame: RoomFrame) {
        guard !frame.isFolded else {
            for name in ["cornerEditBlock", "cornerEdit", "cornerMenu", "cornerMoveBack", "roomName", "roomMenu"] {
                entity.findEntity(named: name)?.removeFromParent()
            }
            cornerKeys[frame.id] = nil
            return
        }
        let bar = borderWidth(of: frame)
        let side = max(bar * 1.2, Self.editTargetHeight)
        let wide = side * 2
        // Mostly over the panel's own corner (18 Nov 2026, Frode): three
        // quarters of it on the picture, a quarter out past the edge.
        // A little further in from the corner (18 Nov 2026, Frode): 3 cm.
        let corner = SIMD2<Float>(-frame.width / 2 + wide / 4 + 0.03, -frame.height / 2 + side / 4)
        // No block any more (18 Nov 2026, Frode): one made before goes.
        entity.findEntity(named: "cornerEditBlock")?.removeFromParent()
        let key = "\(side)"
        if cornerKeys[frame.id] != key {
            cornerKeys[frame.id] = key
            // The word made again, the place its new size.
            entity.findEntity(named: "cornerEdit")?.removeFromParent()
        }
        let button = entity.findEntity(named: "cornerEdit") ?? {
            let made = Entity()
            made.name = "cornerEdit"
            made.components.set(ViewAttachmentComponent(
                rootView: RoomFrameCornerEdit(frameID: frame.id, width: wide, height: side)))
            entity.addChild(made)
            return made
        }()
        // On the corner, a little before the frame, so the eyes reach it.
        button.position = [corner.x, corner.y, 0.012]
        // Move All Back at the bottom right (18 Nov 2026, Frode): Edit's
        // size and manner, three quarters of it on the picture.
        let back = entity.findEntity(named: "cornerMoveBack") ?? {
            let made = Entity()
            made.name = "cornerMoveBack"
            made.components.set(ViewAttachmentComponent(rootView: RoomFrameCornerMoveBack(frameID: frame.id)))
            entity.addChild(made)
            return made
        }()
        let backWidth = RoomFrameCornerMoveBack.estimatedWidth
        // A little further in from its corner too (18 Nov 2026, Frode).
        back.position = [frame.width / 2 - backWidth / 4 - 0.03, corner.y, 0.012]
        // The room's name at the foot's middle, and its menu above it.
        let name = entity.findEntity(named: "roomName") ?? {
            let made = Entity()
            made.name = "roomName"
            made.components.set(ViewAttachmentComponent(rootView: RoomFrameRoomName(frameID: frame.id)))
            entity.addChild(made)
            return made
        }()
        name.position = [0, corner.y, 0.012]
        let roomMenu = entity.findEntity(named: "roomMenu") ?? {
            let made = Entity()
            made.name = "roomMenu"
            made.components.set(ViewAttachmentComponent(rootView: RoomFrameRoomMenu(frameID: frame.id)))
            entity.addChild(made)
            return made
        }()
        roomMenu.position = [0, corner.y + side / 2 + 0.02 + RoomFrameCornerMenu.height / 2, 0.05]
        let menu = entity.findEntity(named: "cornerMenu") ?? {
            let made = Entity()
            made.name = "cornerMenu"
            made.components.set(ViewAttachmentComponent(rootView: RoomFrameCornerMenu(frameID: frame.id)))
            entity.addChild(made)
            return made
        }()
        // The menu's box: its foot just above the word, its left edge at
        // the word's, standing before the frame's members.
        menu.position = [corner.x - wide / 2 + RoomFrameCornerMenu.width / 2,
                         corner.y + side / 2 + 0.02 + RoomFrameCornerMenu.height / 2,
                         0.05]
    }

    /// The title over the frame — or, folded, in its middle — and its menu.
    private func placeTitle(on entity: ModelEntity, for frame: RoomFrame) {
        let title = entity.findEntity(named: "title") ?? {
            let made = Entity()
            made.name = "title"
            made.components.set(ViewAttachmentComponent(rootView: RoomFrameTitle(frameID: frame.id)))
            entity.addChild(made)
            return made
        }()
        // Down onto the top of the frame, before its border (18 Nov 2026,
        // Frode; it stood 2 cm above the border, 7 cm forward).
        title.position = frame.isFolded
            ? [0, 0, Self.frontOffset + 0.02]
            : [0, frame.height / 2 + borderWidth(of: frame) / 2, 0.03]
    }

    /// While arranging: a thin light edge, a handle at each corner and side,
    /// a blue rotate handle beside each upright side, and the frame's own
    /// buttons. Folded: taken hold of anywhere. Otherwise nothing takes the
    /// pinch but the title.
    private func decorate(_ entity: ModelEntity, for frame: RoomFrame) {
        entity.findEntity(named: "edge")?.removeFromParent()
        let arranging = arrangingIDs.contains(frame.id)
        guard arranging else {
            entity.children.filter {
                $0.name.hasPrefix("handle") || $0.name.hasPrefix("rotate") || $0.name == "buttons"
            }.forEach { $0.removeFromParent() }
            if frame.isFolded {
                entity.components.set(InputTargetComponent())
                entity.components.set(CollisionComponent(shapes: [.generateBox(size: [frame.width, frame.height, 0.03])]))
                entity.components.set(HoverEffectComponent())
            } else {
                entity.components.remove(InputTargetComponent.self)
                entity.components.remove(CollisionComponent.self)
                entity.components.remove(HoverEffectComponent.self)
            }
            return
        }
        entity.components.set(InputTargetComponent())
        entity.components.set(CollisionComponent(shapes: [.generateBox(size: [frame.width, frame.height, 0.02])]))
        entity.components.remove(HoverEffectComponent.self)
        entity.addChild(Self.edge(width: frame.width, height: frame.height))
        let halfWidth = frame.width / 2, halfHeight = frame.height / 2
        for x in [-1, 0, 1] {
            for y in [-1, 0, 1] where x != 0 || y != 0 {
                let name = "handle.\(x).\(y)"
                let handle = entity.findEntity(named: name) ?? {
                    let made = ModelEntity(mesh: .generateSphere(radius: x != 0 && y != 0 ? 0.035 : 0.028),
                                           materials: [UnlitMaterial(color: UIColor(white: 0.95, alpha: 1))])
                    made.name = name
                    made.components.set(RoomFrameHitComponent(frameID: frame.id, x: Float(x), y: Float(y)))
                    made.components.set(InputTargetComponent())
                    made.components.set(CollisionComponent(shapes: [.generateSphere(radius: 0.07)]))
                    made.components.set(HoverEffectComponent())
                    entity.addChild(made)
                    return made
                }()
                handle.position = [Float(x) * halfWidth, Float(y) * halfHeight, 0.05]
            }
        }
        for x in [-1, 1] {
            let name = "rotate.\(x)"
            let handle = entity.findEntity(named: name) ?? {
                let made = ModelEntity(mesh: .generateSphere(radius: 0.032),
                                       materials: [UnlitMaterial(color: UIColor(red: 0.25, green: 0.56, blue: 1.0, alpha: 1.0))])
                made.name = name
                made.components.set(RoomFrameHitComponent(frameID: frame.id, x: Float(x), isRotate: true))
                made.components.set(InputTargetComponent())
                made.components.set(CollisionComponent(shapes: [.generateSphere(radius: 0.07)]))
                made.components.set(HoverEffectComponent())
                let icon = Entity()
                icon.components.set(ViewAttachmentComponent(rootView:
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)))
                icon.position = [0, 0, 0.033]
                made.addChild(icon)
                entity.addChild(made)
                return made
            }()
            handle.position = [Float(x) * (halfWidth + 0.09), 0, 0.05]
        }
        let buttons = entity.findEntity(named: "buttons") ?? {
            let made = Entity()
            made.name = "buttons"
            made.components.set(ViewAttachmentComponent(rootView: RoomFrameArrangeButtons(frameID: frame.id)))
            entity.addChild(made)
            return made
        }()
        buttons.position = [0, -halfHeight - 0.09, 0.06]
    }

    private static func edge(width: Float, height: Float) -> Entity {
        let frame = Entity()
        frame.name = "edge"
        let material = UnlitMaterial(color: UIColor(white: 0.9, alpha: 1))
        let line: Float = 0.006
        for (size, at) in [(SIMD3<Float>(width, line, line), SIMD3<Float>(0, height / 2, 0.003)),
                           (SIMD3<Float>(width, line, line), SIMD3<Float>(0, -height / 2, 0.003)),
                           (SIMD3<Float>(line, height, line), SIMD3<Float>(width / 2, 0, 0.003)),
                           (SIMD3<Float>(line, height, line), SIMD3<Float>(-width / 2, 0, 0.003))] {
            let bar = ModelEntity(mesh: .generateBox(size: size), materials: [material])
            bar.components.set(ModelSortGroupComponent(group: .planarUIAlwaysBehind, order: 2))
            bar.position = at
            frame.addChild(bar)
        }
        return frame
    }

    /// The pulled members' places, kept as faint names in the frame — half
    /// seen, set back a little, so the frame still reads whole.
    private func placeShadows(for frameID: String, names: [String: SIMD3<Float>], scale: Float = 1) {
        guard let entity = entities[frameID] else { return }
        let holder = entity.findEntity(named: "shadows") ?? {
            let made = Entity()
            made.name = "shadows"
            entity.addChild(made)
            return made
        }()
        let key = names.keys.sorted().joined(separator: "|") + "\(scale)"
        guard holder.components[ShadowKeyComponent.self]?.key != key else {
            for child in holder.children { if let at = names[child.name] { child.position = at } }
            return
        }
        holder.components.set(ShadowKeyComponent(key: key))
        holder.children.removeAll()
        for (id, at) in names {
            let shadow = Entity()
            shadow.name = id
            // Pinched, a line to where its concept stands; pinched twice, the
            // concept back in its slot (18 Nov 2026).
            shadow.components.set(ViewAttachmentComponent(rootView:
                Text(Self.shadowTitle(id))
                    .font(.system(size: 22 * CGFloat(scale), weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().strokeBorder(Color.white.opacity(0.6), lineWidth: 1))
                    .opacity(0.5)
                    .contentShape(.hoverEffect, Capsule())
                    .hoverEffect(.highlight)
                    .contentShape(Capsule())
                    .onTapGesture(count: 2) { RoomFrames.shared.bringBack(id, to: frameID) }
                    .onTapGesture { RoomFrames.shared.toggleShadowLine(id) }))
            shadow.position = at
            holder.addChild(shadow)
        }
    }

    /// A member id's name, for its shadow: keyword:/person: prefixes away.
    @ObservationIgnored var titleOf: (String) -> String = { id in
        id.split(separator: ":", maxSplits: 1).last.map(String.init) ?? id
    }
    private static func shadowTitle(_ id: String) -> String { RoomFrames.shared.titleOf(id) }

    // MARK: Keeping

    private func update(_ id: String, _ change: (inout RoomFrame) -> Void) {
        guard let index = frames.firstIndex(where: { $0.id == id }) else { return }
        change(&frames[index])
        frames[index].modified = Date()
        // Its place in the room the reader stands in, remembered for that
        // room alone (18 Nov 2026).
        PhysicalRooms.shared.record(frames[index])
        show(frames[index])
        save()
    }

    private func save() {
        let folder = community()
        Self.write(frames, community: folder)
    }

    nonisolated private static let sharedName = "origami-room-frames.json"
    nonisolated private static let sharedPictures = "Frame Pictures"

    nonisolated private struct File: Codable {
        var frames: [String: RoomFrame] = [:]
    }

    nonisolated private static var mirrorURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent(sharedName)
    }

    nonisolated private static var localPictures: URL {
        URL.applicationSupportDirectory.appendingPathComponent(sharedPictures, isDirectory: true)
    }

    nonisolated private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    nonisolated private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    private static func read(community folder: URL?) -> [RoomFrame] {
        let mirror = readFile(at: mirrorURL)
        let shared = folder.flatMap { url in withScope(url) { readFile(at: $0.appendingPathComponent(sharedName)) } }
        var merged = mirror?.frames ?? [:]
        for (id, frame) in shared?.frames ?? [:] {
            if let held = merged[id], held.modified >= frame.modified { continue }
            merged[id] = frame
        }
        return merged.values.sorted { $0.id < $1.id }
    }

    private static func write(_ frames: [RoomFrame], community folder: URL?) {
        // Merged with what is there, so another headset's frames stand.
        var file = File(frames: Dictionary(uniqueKeysWithValues: read(community: folder).map { ($0.id, $0) }))
        for frame in frames {
            if let held = file.frames[frame.id], held.modified > frame.modified { continue }
            file.frames[frame.id] = frame
        }
        guard let data = try? encoder.encode(file) else { return }
        try? data.write(to: mirrorURL, options: .atomic)
        if let folder {
            withScope(folder) { try? data.write(to: $0.appendingPathComponent(sharedName), options: .atomic) }
        }
    }

    nonisolated private static func readFile(at url: URL) -> File? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(File.self, from: data)
    }

    nonisolated private static func withScope<T>(_ url: URL, _ body: (URL) -> T) -> T {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return body(url)
    }

    // MARK: Pictures

    nonisolated private static func wholeImage(for picture: String, community folder: URL?) -> UIImage? {
        if picture.hasPrefix("photo:") {
            let name = String(picture.dropFirst("photo:".count))
            let local = localPictures.appendingPathComponent(name)
            if let image = UIImage(contentsOfFile: local.path) { return image }
            guard let folder else { return nil }
            return withScope(folder) { url in
                let shared = url.appendingPathComponent(sharedPictures, isDirectory: true).appendingPathComponent(name)
                guard let data = try? Data(contentsOf: shared) else { return nil }
                // Kept here too, so the next room needs no folder.
                try? FileManager.default.createDirectory(at: localPictures, withIntermediateDirectories: true)
                try? data.write(to: local)
                return UIImage(data: data)
            }
        }
        if picture.hasPrefix("builtin:"), let builtIn = BuiltIn(rawValue: String(picture.dropFirst("builtin:".count))) {
            return drawn(builtIn, aspect: 2)
        }
        if picture.hasPrefix("default:"), let photo = DefaultPhoto(rawValue: String(picture.dropFirst("default:".count))),
           let url = photoURL(photo) {
            return UIImage(contentsOfFile: url.path)
        }
        return nil
    }

    nonisolated static func photoURL(_ photo: DefaultPhoto) -> URL? {
        Bundle.main.url(forResource: photo.resourceName, withExtension: "jpg")
            ?? Bundle.main.url(forResource: photo.resourceName, withExtension: "jpg", subdirectory: sharedPictures)
    }

    static func thumbnail(_ builtIn: BuiltIn) -> UIImage { drawn(builtIn, aspect: 1.6) }

    static func thumbnail(_ photo: DefaultPhoto) -> UIImage? {
        guard let url = photoURL(photo), let data = try? Data(contentsOf: url) else { return nil }
        return downsampled(data, longestSide: 240)
    }

    nonisolated private static func downsampled(_ data: Data, longestSide: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(longestSide),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    /// Knowledge Space's own pictures, drawn — no files to ship.
    nonisolated private static func drawn(_ builtIn: BuiltIn, aspect: CGFloat) -> UIImage {
        let width: CGFloat = 2048
        let size = CGSize(width: width, height: max(256, width / max(aspect, 0.1)))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            func gradient(_ top: UIColor, _ bottom: UIColor) {
                let colours = [top.cgColor, bottom.cgColor] as CFArray
                if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colours, locations: [0, 1]) {
                    cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
                }
            }
            switch builtIn {
            case .slate:
                gradient(UIColor(red: 0.22, green: 0.26, blue: 0.31, alpha: 1), UIColor(red: 0.12, green: 0.14, blue: 0.17, alpha: 1))
            case .dusk:
                gradient(UIColor(red: 0.16, green: 0.12, blue: 0.30, alpha: 1), UIColor(red: 0.78, green: 0.42, blue: 0.30, alpha: 1))
            case .warmPaper:
                gradient(UIColor(red: 0.86, green: 0.82, blue: 0.74, alpha: 1), UIColor(red: 0.76, green: 0.71, blue: 0.62, alpha: 1))
            case .nightSky:
                gradient(UIColor(red: 0.03, green: 0.04, blue: 0.10, alpha: 1), UIColor(red: 0.07, green: 0.10, blue: 0.20, alpha: 1))
                var seed: UInt64 = 0x5EED
                func next() -> CGFloat {
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    return CGFloat(seed >> 33) / CGFloat(1 << 31)
                }
                for _ in 0..<900 {
                    let radius = 0.6 + next() * next() * 2.4
                    UIColor(white: 1, alpha: 0.35 + next() * 0.65).setFill()
                    cg.fillEllipse(in: CGRect(x: next() * size.width, y: next() * size.height, width: radius, height: radius))
                }
            }
        }
    }

    // MARK: Matrices

    nonisolated static func matrix(_ values: [Float]) -> simd_float4x4 {
        guard values.count == 16 else { return matrix_identity_float4x4 }
        return simd_float4x4(SIMD4(values[0], values[1], values[2], values[3]),
                             SIMD4(values[4], values[5], values[6], values[7]),
                             SIMD4(values[8], values[9], values[10], values[11]),
                             SIMD4(values[12], values[13], values[14], values[15]))
    }

    nonisolated static func matrix(_ rotation: simd_quatf, at position: SIMD3<Float>) -> simd_float4x4 {
        var m = simd_float4x4(rotation)
        m.columns.3 = SIMD4<Float>(position, 1)
        return m
    }

    nonisolated static func columns(_ m: simd_float4x4) -> [Float] {
        [m.columns.0, m.columns.1, m.columns.2, m.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }
    }

    nonisolated static func translation(_ m: simd_float4x4) -> SIMD3<Float> { SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z) }
    nonisolated static func right(_ m: simd_float4x4) -> SIMD3<Float> { simd_normalize(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z)) }
    nonisolated static func up(_ m: simd_float4x4) -> SIMD3<Float> { simd_normalize(SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z)) }
    nonisolated static func normal(_ m: simd_float4x4) -> SIMD3<Float> { simd_normalize(SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)) }

    nonisolated static func rotation(_ m: simd_float4x4) -> simd_quatf {
        simd_quatf(simd_float3x3(right(m), up(m), normal(m)))
    }
}

private struct ShadowKeyComponent: Component {
    let key: String
}

// MARK: - The frame's title and menu

/// The title over a frame: its kind's name — a panel's own — in a capsule
/// on the border's colour. Pinched, its menu opens beneath it — Edit's
/// pages, Move & Resize, Move All Out, Put All Back, Fold, Hide, Delete.
/// The corner's Edit opens the same menu above the frame's bottom left.
struct RoomFrameTitle: View {
    let frameID: String

    var body: some View {
        let frames = RoomFrames.shared
        let frame = frames.frame(frameID)
        let open = frames.menuOpenFor == frameID && !frames.menuAtCorner
        VStack(spacing: 14) {
            Button {
                frames.roomMenuOpenFor = nil
                frames.menuAtCorner = false
                frames.menuOpenFor = open ? nil : frameID
            } label: {
                Text(frame?.title ?? "")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(titleInk(frame))
                    .padding(.horizontal, 26)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(titleGround(frame)))
                    .contentShape(.hoverEffect, Capsule())
                    .hoverEffect(.highlight)
            }
            .buttonStyle(.plain)
            if open {
                RoomFrameMenu(frameID: frameID)
            }
        }
    }

    /// The title's ground: the border's colour, dark grey unframed.
    private func titleGround(_ frame: RoomFrame?) -> Color {
        guard let style = frame?.frame.flatMap(RoomFrames.Style.init(rawValue:)) else { return Color(white: 0.16) }
        return Color(uiColor: style.colour)
    }

    private func titleInk(_ frame: RoomFrame?) -> Color {
        guard let style = frame?.frame.flatMap(RoomFrames.Style.init(rawValue:)) else { return .white }
        var white: CGFloat = 0
        style.colour.getWhite(&white, alpha: nil)
        return white > 0.6 ? .black : .white
    }
}



/// Knowledge Space's Edit at a frame's bottom left (18 Nov 2026, Frode):
/// the word on its glass capsule, both very faint until looked at, then
/// whole; pinched, the frame's menu opens above the corner. Open, "Close".
struct RoomFrameCornerEdit: View {
    let frameID: String
    var width: Float
    var height: Float

    var body: some View {
        let frames = RoomFrames.shared
        let open = frames.menuOpenFor == frameID && frames.menuAtCorner
        Text(open ? "Close" : "Edit")
            .font(.system(size: 20, weight: .semibold))
            // The capsule fits the word (18 Nov 2026, Frode).
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .fixedSize()
            .hoverEffect(isEnabled: !open) { effect, isActive, _ in
                effect.animation(.easeInOut(duration: 0.2)) { $0.opacity(isActive || open ? 1 : 0.25) }
            }
            // No system button (18 Nov 2026, Frode): nothing drawn
            // behind the words, looked at or not — they only come up to
            // full white.
            .foregroundStyle(.white)
            .contentShape(.hoverEffect, Rectangle())
            .contentShape(Rectangle())
            .onTapGesture {
                if open {
                    frames.menuOpenFor = nil
                } else {
                    frames.roomMenuOpenFor = nil
                    frames.menuAtCorner = true
                    frames.menuOpenFor = frameID
                }
            }
    }
}

/// The room's name at a frame's foot (18 Nov 2026, Frode) — the project
/// it stands as, "Room" until named — in Edit's size and manner. Pinched,
/// the rooms open above it: choose one and every frame changes to it, or
/// name the room as it stands and save it.
struct RoomFrameRoomName: View {
    let frameID: String

    var body: some View {
        let frames = RoomFrames.shared
        let open = frames.roomMenuOpenFor == frameID
        Text(open ? "Close" : frames.footLabel)
            .font(.system(size: 20, weight: .semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .fixedSize()
            .hoverEffect(isEnabled: !open) { effect, isActive, _ in
                effect.animation(.easeInOut(duration: 0.2)) { $0.opacity(isActive || open ? 1 : 0.25) }
            }
            // No system button (18 Nov 2026, Frode): nothing drawn
            // behind the words, looked at or not — they only come up to
            // full white.
            .foregroundStyle(.white)
            .contentShape(.hoverEffect, Rectangle())
            .contentShape(Rectangle())
            .onTapGesture {
                frames.menuOpenFor = nil
                frames.roomMenuOpenFor = open ? nil : frameID
            }
    }
}

/// The rooms, above a frame's foot: each saved one to change to, the one
/// standing ticked; and a name to save the room as it stands under.
struct RoomFrameRoomMenu: View {
    /// The attachment's width in metres: the 900-point menu and a margin.
    static let width: Float = 0.7
    let frameID: String
    @State private var name = ""
    /// Rename's field for the current room, and Delete's second press.
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmingDelete = false
    /// The physical room's rename, and a new room's name.
    @State private var renamingRoom = false
    @State private var roomName = ""
    @State private var newLayoutName = ""

    var body: some View {
        let frames = RoomFrames.shared
        let rooms = PhysicalRooms.shared
        let open = frames.roomMenuOpenFor == frameID
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            if open {
                VStack(alignment: .leading, spacing: 6) {
                    // The room — the physical space (19 Nov 2026, Frode).
                    Text("Room")
                        .font(.system(size: 24, weight: .bold))
                        .padding(.bottom, 4)
                    if renamingRoom, let current = rooms.current {
                        HStack(spacing: 10) {
                            TextField(rooms.currentName ?? "Room", text: $roomName)
                                .font(.system(size: 24))
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { rooms.renameRoom(current, to: roomName); renamingRoom = false }
                            Button("Done") { rooms.renameRoom(current, to: roomName); renamingRoom = false }
                                .font(.system(size: 22, weight: .semibold))
                        }
                    } else {
                        HStack(spacing: 10) {
                            Text(rooms.currentName ?? "Not found yet")
                                .font(.system(size: 24, weight: .medium))
                                .lineLimit(1).layoutPriority(1)
                                .padding(.horizontal, 12)
                            Spacer(minLength: 12)
                            // Redo Layout (19 Nov 2026, Frode): every panel into
                            // Move & Resize, each new place kept for this room.
                            Button("Redo Layout") { frames.redoPlacesHere() }
                                .font(.system(size: 22, weight: .semibold))
                                .disabled(frames.shownHere.isEmpty || rooms.current == nil)
                            Button("Rename") {
                                roomName = rooms.currentName ?? ""
                                renamingRoom = true
                            }
                            .font(.system(size: 22, weight: .semibold))
                            .disabled(rooms.current == nil)
                            Button {
                                frames.roomMenuOpenFor = nil
                                rooms.scanForRoom()
                            } label: {
                                Label("Scan for Room", systemImage: "viewfinder")
                            }
                            .font(.system(size: 22, weight: .semibold))
                        }
                    }
                    HStack {
                        TextField("A new room's name", text: $name)
                            .font(.system(size: 22))
                            .textFieldStyle(.roundedBorder)
                        Button("New Room Here") {
                            rooms.startNewRoom(named: name)
                            name = ""
                            frames.roomMenuOpenFor = nil
                        }
                        .font(.system(size: 22, weight: .semibold))
                    }
                    Divider().padding(.vertical, 8)
                    // The layout — which panels stand, and what they hold.
                    Text("Layout")
                        .font(.system(size: 24, weight: .bold))
                        .padding(.bottom, 4)
                    if frames.layoutsHere.isEmpty {
                        Text("None saved yet")
                            .font(.system(size: 22))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(frames.layoutsHere) { layout in
                        if renaming, layout.id == frames.currentLayoutID {
                            HStack(spacing: 10) {
                                TextField(layout.name, text: $newName)
                                    .font(.system(size: 24))
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit { finishRename(layout.id) }
                                Button("Done") { finishRename(layout.id) }
                                    .font(.system(size: 22, weight: .semibold))
                            }
                        } else {
                        HStack(spacing: 10) {
                            Button {
                                frames.loadLayout(layout.id)
                            } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: "checkmark")
                                        .opacity(layout.id == frames.currentLayoutID ? 1 : 0)
                                        .frame(width: 30)
                                    Text(layout.name).lineLimit(1).layoutPriority(1)
                                    Spacer(minLength: 12)
                                }
                                .font(.system(size: 24, weight: .medium))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 12))
                                .hoverEffect(.highlight)
                            }
                            .buttonStyle(.plain)
                            // Update (18 Nov 2026, Frode): the room standing
                            // now saved over the current one.
                            if layout.id == frames.currentLayoutID {
                                Button("Update") {
                                    frames.saveLayout(named: layout.name)
                                    frames.roomMenuOpenFor = nil
                                }
                                .font(.system(size: 22, weight: .semibold))
                                // Rename and Delete beside it (18 Nov 2026, Frode).
                                Button("Rename") {
                                    newName = layout.name
                                    confirmingDelete = false
                                    renaming = true
                                }
                                .font(.system(size: 22, weight: .semibold))
                                Button(confirmingDelete ? "Delete?" : "Delete", role: .destructive) {
                                    guard confirmingDelete else { confirmingDelete = true; return }
                                    confirmingDelete = false
                                    frames.deleteLayout(layout.id)
                                }
                                .font(.system(size: 22, weight: .semibold))
                            }
                        }
                        }
                    }
                    HStack {
                        TextField("Save the panels as a layout named…", text: $newLayoutName)
                            .font(.system(size: 22))
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(save)
                        Button("Save Layout", action: save)
                            .font(.system(size: 22, weight: .semibold))
                            .disabled(newLayoutName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .padding(.top, 6)
                }
                .padding(24)
                // Wide enough that a room's name stands whole beside
                // Update, Rename and Delete (19 Nov 2026, Frode).
                .frame(width: 900, alignment: .leading)
                .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 32))
            }
        }
        .frame(width: CGFloat(Self.width * RoomFrames.pointsPerMetre),
               height: CGFloat(RoomFrameCornerMenu.height * RoomFrames.pointsPerMetre),
               alignment: .bottom)
        .allowsHitTesting(open)
        .onChange(of: open) { _, now in
            if !now {
                name = ""; newLayoutName = ""; renaming = false; confirmingDelete = false
                renamingRoom = false
            }
        }
    }

    private func finishRename(_ id: String) {
        RoomFrames.shared.renameLayout(id, to: newName)
        renaming = false
    }

    private func save() {
        RoomFrames.shared.saveLayout(named: newLayoutName)
        newLayoutName = ""
        RoomFrames.shared.roomMenuOpenFor = nil
    }
}

/// Move All Back at a frame's bottom right (18 Nov 2026, Frode): Edit's
/// size and manner — the words on their glass capsule, very faint until
/// looked at. Pinched, every concept carried out of this frame into the
/// room comes home to it (Put All Back).
struct RoomFrameCornerMoveBack: View {
    let frameID: String
    /// About as wide as the capsule draws, in metres — for its place.
    static let estimatedWidth: Float = 0.125

    var body: some View {
        let frames = RoomFrames.shared
        let loose = frames.canMoveAllBack(frameID)
        Text("Move All Back")
            .font(.system(size: 20, weight: .semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .fixedSize()
            .hoverEffect { effect, isActive, _ in
                effect.animation(.easeInOut(duration: 0.2)) { $0.opacity(isActive ? 1 : 0.25) }
            }
            // No system button (18 Nov 2026, Frode): nothing drawn
            // behind the words, looked at or not — they only come up to
            // full white.
            .foregroundStyle(.white)
            .contentShape(.hoverEffect, Rectangle())
            .contentShape(Rectangle())
            .onTapGesture {
                frames.putAllBack(frameID)
            }
        // Nothing out in the room: nothing to bring back.
        .disabled(!loose)
    }
}

/// The menu opened from the corner's Edit, rising from just above the
/// frame's bottom left: a fixed box, the menu at its foot, so the menu
/// grows upward and the box itself takes no pinch.
struct RoomFrameCornerMenu: View {
    let frameID: String
    /// The box, in metres.
    static let width: Float = 0.5
    static let height: Float = 1.0

    var body: some View {
        let frames = RoomFrames.shared
        let open = frames.menuOpenFor == frameID && frames.menuAtCorner
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            if open {
                RoomFrameMenu(frameID: frameID)
            }
        }
        .frame(width: CGFloat(Self.width * RoomFrames.pointsPerMetre),
               height: CGFloat(Self.height * RoomFrames.pointsPerMetre),
               alignment: .bottomLeading)
        .allowsHitTesting(open)
    }
}

/// A frame's menu, wherever it is opened: Edit's pages, Move & Resize,
/// Move All Out, Put All Back, Fold, Hide, Delete — and a panel's Rename.
struct RoomFrameMenu: View {
    let frameID: String

    private enum Page { case main, picture, style, thickness, transparency, rename }
    @State private var page = Page.main
    @State private var confirmingDelete = false
    @State private var nameDraft = ""


    var body: some View {
        let frames = RoomFrames.shared
        if let frame = frames.frame(frameID) {
            menu(frame, frames)
                .padding(24)
                .frame(width: 620, alignment: .leading)
                .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 36))
        }
    }

    @ViewBuilder private func menu(_ frame: RoomFrame, _ frames: RoomFrames) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            switch page {
            case .main:
                // A panel's name is the reader's (18 Nov 2026, Frode) — and
                // stays so once it is given a category.
                if frame.isPanel || frame.name != nil {
                    row("Rename…", systemImage: "character.cursor.ibeam", more: true) {
                        nameDraft = frame.name ?? ""
                        page = .rename
                    }
                    Divider().padding(.vertical, 6)
                }
                row("Picture", systemImage: "photo", more: true) { page = .picture }
                row("Frame Color", systemImage: "square.dashed", more: true) { page = .style }
                row("Frame Thickness", systemImage: "line.3.horizontal", more: true) { page = .thickness }
                row("Transparency", systemImage: "square.dashed.inset.filled", more: true) { page = .transparency }
                Divider().padding(.vertical, 6)
                row("Move & Resize", systemImage: "arrow.up.and.down.and.arrow.left.and.right") {
                    frames.toggleArranging(frameID)
                }
                row("Lift from Wall", systemImage: "arrow.up.square") { frames.liftFromWall(frameID) }
                row("Snap to Wall", systemImage: "rectangle.portrait.and.arrow.forward") { frames.snapToWall(frameID) }
                Divider().padding(.vertical, 6)
                row("Move All Out", systemImage: "arrow.up.right.square") { frames.moveAllOut(frameID) }
                row("Put All Back", systemImage: "arrow.down.left.square") { frames.putAllBack(frameID) }
                    .disabled(frame.pulled.isEmpty)
                row(frame.isFolded ? "Unfold Frame" : "Fold Frame",
                    systemImage: frame.isFolded ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left") {
                    if frame.isFolded { frames.unfold(frameID) } else { frames.fold(frameID) }
                }
                row("Hide", systemImage: "eye.slash") { frames.hide(frameID) }
                Divider().padding(.vertical, 6)
                row(confirmingDelete ? (frame.isPanel ? "Delete This Panel?" : "Delete This Frame?") : "Delete",
                    systemImage: "trash", destructive: true) {
                    guard confirmingDelete else { confirmingDelete = true; return }
                    frames.remove(frameID)
                }
            case .picture:
                back
                pick("Dark Grey", on: frame.picture == "grey") { frames.choose(picture: "grey", for: frameID) }
                ForEach(RoomFrames.BuiltIn.allCases) { builtIn in
                    pick(builtIn.rawValue, thumbnail: RoomFrames.thumbnail(builtIn),
                         on: frame.picture == "builtin:" + builtIn.rawValue) {
                        frames.choose(picture: "builtin:" + builtIn.rawValue, for: frameID)
                    }
                }
                ForEach(RoomFrames.DefaultPhoto.allCases) { photo in
                    pick(photo.rawValue, thumbnail: RoomFrames.thumbnail(photo),
                         on: frame.picture == "default:" + photo.rawValue) {
                        frames.choose(picture: "default:" + photo.rawValue, for: frameID)
                    }
                }
                Divider().padding(.vertical, 6)
                row("Choose from Photos…", systemImage: "photo.on.rectangle") {
                    frames.menuOpenFor = nil
                    frames.requestChooser(for: frameID)
                }
            case .style:
                back
                pick("No Frame", on: frame.frame == nil) { frames.setStyle(nil, for: frameID) }
                ForEach(RoomFrames.Style.allCases) { style in
                    pick(style.rawValue, on: frame.frame == style.rawValue) { frames.setStyle(style, for: frameID) }
                }
                Divider().padding(.vertical, 6)
                pick("Offset Frame", on: frame.offsetFrame ?? true) {
                    frames.setOffsetFrame(!(frame.offsetFrame ?? true), for: frameID)
                }
            case .thickness:
                back
                ForEach(RoomFrames.Thickness.allCases) { thickness in
                    pick(thickness.rawValue, on: frame.frame != nil && frame.frameThickness == thickness.rawValue) {
                        frames.setThickness(thickness, for: frameID)
                    }
                }
            case .rename:
                back
                TextField(RoomFrame.unnamedPanel, text: $nameDraft)
                    .font(.system(size: 28, weight: .medium))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        frames.rename(frameID, to: nameDraft)
                        page = .main
                    }
                HStack {
                    // A category for it (19 Nov 2026, Frode): the panel
                    // becomes a frame of that kind, showing its concepts.
                    Menu {
                        Picker("Category", selection: Binding(
                            get: { frame.kind },
                            set: { frames.setKind(frameID, to: $0) })) {
                            Text("No Category").tag(RoomFrame.panelKind)
                            ForEach(RoomFrame.kinds, id: \.self) { kind in
                                Text(RoomFrame.title(of: kind)).tag(kind)
                            }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Label(frame.isPanel ? "Category" : RoomFrame.title(of: frame.kind),
                              systemImage: "square.grid.2x2")
                    }
                    .font(.system(size: 26, weight: .medium))
                    Spacer()
                    Button("Done") {
                        frames.rename(frameID, to: nameDraft)
                        page = .main
                    }
                    .font(.system(size: 26, weight: .semibold))
                }
                .padding(.top, 8)
            case .transparency:
                back
                let current = frame.transparency ?? RoomFrames.Transparency.opaque.rawValue
                ForEach(RoomFrames.Transparency.allCases) { level in
                    pick(level.rawValue, on: current == level.rawValue) { frames.setTransparency(level, for: frameID) }
                }
            }
        }
    }

    private var back: some View {
        row("Back", systemImage: "chevron.left") { page = .main }
            .padding(.bottom, 6)
    }

    private func row(_ title: String, systemImage: String, more: Bool = false, destructive: Bool = false,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: systemImage).frame(width: 34)
                Text(title)
                Spacer(minLength: 12)
                if more { Image(systemName: "chevron.right").foregroundStyle(.secondary) }
            }
            .font(.system(size: 26, weight: .medium))
            .foregroundStyle(destructive ? Color.red : Color.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 14))
            .contentShape(Rectangle())
            .hoverEffect(.highlight)
        }
        .buttonStyle(.plain)
    }

    private func pick(_ title: String, thumbnail: UIImage? = nil, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: "checkmark").opacity(on ? 1 : 0).frame(width: 34)
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 64, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                Text(title)
                Spacer(minLength: 12)
            }
            .font(.system(size: 26, weight: .medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 14))
            .contentShape(Rectangle())
            .hoverEffect(.highlight)
        }
        .buttonStyle(.plain)
    }
}

/// While a frame is being moved and resized: Done, Snap to Wall, the two
/// turns and Delete, in a row under it.
struct RoomFrameArrangeButtons: View {
    let frameID: String

    var body: some View {
        let frames = RoomFrames.shared
        HStack(spacing: 18) {
            Button("Done") { frames.finishArranging(frameID) }
                .font(.system(size: 34, weight: .bold))
            Button("Snap to Wall") { frames.snapToWall(frameID) }
            Button("Turn Left", systemImage: "rotate.left") { frames.turn(frameID, clockwise: false) }
            Button("Turn Right", systemImage: "rotate.right") { frames.turn(frameID, clockwise: true) }
            Button("Delete", systemImage: "trash", role: .destructive) { frames.remove(frameID) }
        }
        .font(.system(size: 28, weight: .semibold))
        .padding(22)
        .glassBackgroundEffect()
    }
}

/// The picture chooser's window: Photos cannot open from the room itself.
struct RoomFramePictureChooser: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var photo: PhotosPickerItem?

    static let windowID = "frame-picture"

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 14)]

    var body: some View {
        let frames = RoomFrames.shared
        VStack(alignment: .leading, spacing: 16) {
            Text("Frame Picture")
                .font(.title2.weight(.semibold))
            LazyVGrid(columns: columns, spacing: 14) {
                PhotosPicker(selection: $photo, matching: .images) {
                    VStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(.thinMaterial)
                            .overlay(Image(systemName: "photo.on.rectangle").font(.largeTitle))
                            .frame(height: 94)
                        Text("From Photos…").font(.callout)
                    }
                }
                .buttonStyle(.plain)
            }
            HStack {
                Spacer()
                Button("Done") { dismissWindow(id: Self.windowID) }
            }
        }
        .padding(24)
        .frame(width: 420)
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task { @MainActor in
                if let data = try? await item.loadTransferable(type: Data.self) {
                    frames.choosePhoto(data)
                    dismissWindow(id: Self.windowID)
                }
                photo = nil
            }
        }
    }
}

// MARK: - The room's hold on its frames

/// The gestures a frame takes in the room — carried, its handles pulled,
/// resized with both hands — and the chooser's window when Photos is
/// asked for. A modifier, so the room's long chain stays type-checkable.
struct RoomFrameGestures: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content
            .simultaneousGesture(
                DragGesture()
                    .targetedToEntity(where: .has(RoomFrameHitComponent.self))
                    .onChanged { value in
                        let world = value.convert(value.location3D, from: .local, to: .scene)
                        RoomFrames.shared.drag(value.entity, to: world)
                    }
                    .onEnded { _ in RoomFrames.shared.endGesture() })
            .simultaneousGesture(
                MagnifyGesture()
                    .targetedToEntity(where: .has(RoomFrameHitComponent.self))
                    .onChanged { value in RoomFrames.shared.resize(value.entity, by: value.magnification) }
                    .onEnded { _ in RoomFrames.shared.endGesture() })
            .onChange(of: RoomFrames.shared.chooserRequests) {
                openWindow(id: RoomFramePictureChooser.windowID)
            }
    }
}

// MARK: - Physical rooms (18 Nov 2026, Frode; anchors per frame 19 Nov)

/// A frame's place in one physical room under the old single-anchor scheme:
/// its matrix relative to the room's anchor, and its size there. Kept to
/// read old files (and in layouts, which no longer carry places).
struct RoomPose: Codable, Equatable {
    var transform: [Float]
    var width: Float
    var height: Float
}

/// The physical rooms this headset is used in (19 Nov 2026, Frode: "rooms
/// really are not mapped — open in a different part of the room and the
/// panels go somewhere else").
///
/// Every frame has its OWN world anchor in each room it has stood in, made
/// on the frame itself — Apple's way (one anchor per placed object) and
/// Knowledge Space's. ARKit finds an anchor again only in the room where it
/// was made, so a tracked anchor both says which room this is and where its
/// frame stands, with no long lever from one anchor on the floor.
///
/// Until the room is known, frames that have a place somewhere are kept out
/// of sight — never shown at the coordinates of another session. If nothing
/// is recognised in a few seconds the reader is asked which room this is;
/// a known room is then looked for while the reader looks around, and a new
/// one starts here.
@MainActor
@Observable
final class PhysicalRooms {
    static let shared = PhysicalRooms()

    struct Room: Codable, Identifiable, Equatable {
        let id: UUID
        var name: String
        var created: Date
        /// When the reader last stood in it (19 Nov 2026).
        var used: Date?
        /// The layout last used in it, brought back on entering (19 Nov 2026).
        var layoutID: String?
    }

    /// The layout now in use, kept as this room's.
    func rememberLayout(_ id: String?) {
        guard let room = settledRoom, let index = rooms.firstIndex(where: { $0.id == room }),
              rooms[index].layoutID != id else { return }
        rooms[index].layoutID = id
        save()
    }

    /// A room's name changed; empty keeps the old one.
    func renameRoom(_ id: UUID, to given: String) {
        let name = given.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = rooms.firstIndex(where: { $0.id == id }) else { return }
        rooms[index].name = name
        save()
    }

    /// The rooms to offer, most recently stood in first — a few only.
    var recentRooms: [Room] {
        Array(rooms.sorted { ($0.used ?? $0.created) > ($1.used ?? $1.created) }.prefix(5))
    }

    /// The room the reader most likely stands in while it is being found:
    /// the one last stood in (19 Nov 2026, Frode: shown lit).
    var likelyRoom: UUID? {
        if case .looking(let room) = phase { return room }
        return recentRooms.first?.id
    }

    /// A frame's anchor in one room, and its size there.
    struct Placement: Codable, Equatable {
        var anchor: UUID
        var width: Float
        var height: Float
    }

    enum Phase: Equatable {
        /// World tracking just started: looking for any known anchor.
        case finding
        /// Nothing recognised: the reader is asked which room this is.
        case asking
        /// The reader named a known room: waiting for its anchors.
        case looking(UUID)
        /// The room is known.
        case settled(UUID)
    }

    private(set) var rooms: [Room] = []
    private(set) var phase: Phase = .finding
    /// Scanning (19 Nov 2026, Frode: "let the user know what is
    /// happening"): the room's panels are being looked for — shown with
    /// how many are in place — until every one is found or the reader is
    /// done.
    private(set) var scanning = false
    private(set) var foundHere = 0
    private(set) var expectedHere = 0

    /// The room the reader stands in, once known or named.
    var current: UUID? {
        switch phase {
        case .looking(let room), .settled(let room): room
        case .finding, .asking: nil
        }
    }
    var currentName: String? { rooms.first { $0.id == current }?.name }
    var isSettled: Bool { if case .settled = phase { true } else { false } }
    var settledRoom: UUID? { if case .settled(let room) = phase { room } else { nil } }

    /// Frame → room → its anchor there.
    @ObservationIgnored private var placements: [String: [UUID: Placement]] = [:]
    /// Anchor → its frame and room, from `placements`.
    @ObservationIgnored private var owners: [UUID: (frame: String, room: UUID)] = [:]
    /// Anchors found this session, where. Cleared each time tracking starts:
    /// a transform from an earlier session is in that session's coordinates.
    @ObservationIgnored private var tracked: [UUID: simd_float4x4] = [:]
    /// Old rooms' single anchors and their frames' places, carried over to
    /// per-frame anchors the first time each is found.
    @ObservationIgnored private var legacy: [UUID: [String: RoomPose]] = [:]
    /// Frames shown although their anchor here is not found: the reader
    /// asked, or it was not found in time. Each stands before the reader
    /// until its anchor is found, or until it is moved and anchored afresh.
    @ObservationIgnored private var revealed: Set<String> = []
    /// Frames whose new anchor is being added.
    @ObservationIgnored private var adding: Set<String> = []
    /// Frames put up while the room is still being found: seen at once,
    /// anchored when it is.
    @ObservationIgnored private var madeThisRun: Set<String> = []
    func madeNow(_ frameID: String) { madeThisRun.insert(frameID) }
    /// Frames shown since the room was opened.
    @ObservationIgnored private var seenThisOpening: Set<String> = []
    func noteShown(_ frameID: String) { seenThisOpening.insert(frameID) }
    /// The room opened: its frames' last places belong to the space just
    /// closed, so none counts as seen.
    func spaceOpened() { seenThisOpening = [] }
    /// Whether a frame's new anchor is being made now.
    func isAnchoring(_ frameID: String) -> Bool { adding.contains(frameID) }
    /// Anchors of the rooms given up at the fresh start, removed when
    /// tracking runs.
    @ObservationIgnored private var retiring: [UUID] = []
    /// Which tracking run this is, so a late timer from an old one is dropped.
    @ObservationIgnored private var run = 0

    /// Set by the room's surfaces: a world anchor added where asked, its id.
    @ObservationIgnored var addAnchor: (simd_float4x4) async -> UUID? = { _ in nil }
    @ObservationIgnored var removeAnchor: (UUID) async -> Void = { _ in }
    /// The reader's head.
    @ObservationIgnored var headPosition: () -> SIMD3<Float>? = { nil }

    /// How long to look for a known anchor before asking.
    static let askAfter: Duration = .seconds(5)
    /// How long a known room's missing frames are waited for once it is
    /// found, before they stand before the reader.
    static let revealAfter: Duration = .seconds(30)

    private init() { load() }

    // MARK: Found, asked, made

    /// World tracking is running — freshly, each time the room is opened.
    func trackingStarted() {
        run += 1
        let thisRun = run
        tracked = [:]
        revealed = []
        adding = []
        madeThisRun = []
        scanning = true
        RoomLog.write("tracking started (run \(thisRun)); \(rooms.count) rooms, \(owners.count) frame anchors, \(legacy.count) old room anchors")
        // Old anchors let go after the fresh start: removed once the session
        // can take them.
        for anchor in retiring { Task { @MainActor in await removeAnchor(anchor) } }
        retiring = []
        if rooms.isEmpty {
            // No room known: nothing to find — the reader names this one.
            phase = .asking
            RoomFrames.shared.roomChanged()
            return
        }
        phase = .finding
        RoomFrames.shared.roomChanged()
        Task { @MainActor in
            try? await Task.sleep(for: Self.askAfter)
            guard self.run == thisRun, self.phase == .finding else { return }
            RoomLog.write("nothing recognised in \(Self.askAfter) — asking")
            self.phase = .asking
        }
    }

    /// The reader says which room this is: its frames are looked for.
    func choose(_ room: UUID) {
        guard rooms.contains(where: { $0.id == room }) else { return }
        RoomLog.write("reader chose \(name(room))")
        scanning = true
        // One of its frames already found: it is here.
        if owners.contains(where: { $0.value.room == room && tracked[$0.key] != nil }) {
            settle(room, why: "chosen, already found")
            return
        }
        phase = .looking(room)
        countFound()
        RoomFrames.shared.roomChanged()
    }

    /// The reader says this is a room not yet known: it starts here, every
    /// frame standing where it is now and anchored there.
    func startNewRoom(named given: String) {
        let trimmed = given.trimmingCharacters(in: .whitespacesAndNewlines)
        let room = Room(id: UUID(), name: trimmed.isEmpty ? "Room \(rooms.count + 1)" : trimmed, created: Date())
        rooms.append(room)
        save()
        RoomLog.write("new room \(room.name)")
        settle(room.id, why: "new room")
    }

    /// Bar ▸ Panels ▸ New Room Here.
    func startNewRoomHere() { startNewRoom(named: "") }

    /// The room looked for is taken as found although none of its frames
    /// has been: they stand before the reader, to be put where they belong.
    func placeHereAnyway() {
        guard case .looking(let room) = phase else { return }
        settle(room, why: "placed here anyway")
        stopScanning()
    }

    /// Back to the question.
    func askAgain() {
        RoomLog.write("asked again")
        scanning = true
        phase = .asking
        RoomFrames.shared.roomChanged()
    }

    /// How many of this room's panels have a place in it, and how many
    /// of those are found; the scan ends by itself when all are.
    private func countFound() {
        guard let room = current else { foundHere = 0; expectedHere = 0; return }
        let ids = RoomFrames.shared.frameIDsHere
        let placed = ids.compactMap { placements[$0]?[room] }
        expectedHere = placed.count
        foundHere = placed.filter { tracked[$0.anchor] != nil }.count
        if isSettled, scanning, foundHere >= expectedHere {
            scanning = false
            RoomLog.write("scan done: all \(expectedHere) panels found")
        }
    }

    /// Scan for Room (19 Nov 2026, Frode): look for the room again — the
    /// one whose panels the headset has found, or, none found, ask.
    func scanForRoom() {
        RoomLog.write("scan for room asked")
        run += 1
        let thisRun = run
        scanning = true
        // Already found this session: the room with most of them.
        var counts: [UUID: Int] = [:]
        for (anchor, owner) in owners where tracked[anchor] != nil { counts[owner.room, default: 0] += 1 }
        if let best = counts.max(by: { $0.value < $1.value })?.key {
            settle(best, why: "scan: already found")
            return
        }
        phase = rooms.isEmpty ? .asking : .finding
        countFound()
        Task { @MainActor in
            try? await Task.sleep(for: Self.askAfter)
            guard self.run == thisRun, self.phase == .finding else { return }
            self.phase = .asking
        }
    }

    /// Done scanning: what is not found stands before the reader, and is
    /// still put in its place should it be found later.
    func stopScanning() {
        guard scanning else { return }
        scanning = false
        RoomLog.write("scan stopped: \(foundHere) of \(expectedHere) found")
        revealMissing()
    }

    private func settle(_ room: UUID, why: String) {
        RoomLog.write("settled in \(name(room)) — \(why)")
        if let index = rooms.firstIndex(where: { $0.id == room }) {
            rooms[index].used = Date()
            save()
        }
        phase = .settled(room)
        // Entering a room brings back the layout last used in it (19 Nov
        // 2026, Frode) — unless it is the one standing already.
        let frames = RoomFrames.shared
        if let layout = rooms.first(where: { $0.id == room })?.layoutID,
           layout != frames.currentLayoutID, frames.layoutsHere.contains(where: { $0.id == layout }) {
            RoomLog.write("bringing back \(name(room))'s layout")
            frames.loadLayout(layout)
        } else {
            // A room with none yet takes the one standing.
            rememberLayout(frames.currentLayoutID)
        }
        frames.roomChanged()
        // Scanning on while any of its panels is still to be found.
        scanning = true
        countFound()
        let thisRun = run
        Task { @MainActor in
            try? await Task.sleep(for: Self.revealAfter)
            guard self.run == thisRun, self.settledRoom == room, self.scanning else { return }
            self.stopScanning()
        }
    }

    /// Frames with a place in this room whose anchors were not found: shown
    /// before the reader, their anchors kept in case they are found later.
    func revealMissing() {
        guard let room = settledRoom else { return }
        let missing = RoomFrames.shared.frameIDsHere.filter { id in
            guard let placement = placements[id]?[room] else { return false }
            return tracked[placement.anchor] == nil && !revealed.contains(id)
        }
        guard !missing.isEmpty else { return }
        RoomLog.write("not found, shown before the reader: \(missing.sorted().joined(separator: ", "))")
        revealed.formUnion(missing)
        RoomFrames.shared.standBeforeReader(missing)
    }

    /// A world anchor found, moved or lost.
    func anchorUpdated(id: UUID, transform: simd_float4x4, tracked isTracked: Bool) {
        if let poses = legacy[id] {
            guard isTracked else { return }
            migrate(id, poses: poses, anchor: transform)
            return
        }
        guard let owner = owners[id] else { return }
        let wasTracked = tracked[id] != nil
        // Once found this session an anchor's last place is kept, tracked
        // or not (19 Nov 2026: a new anchor's first word is "not tracked",
        // and taking that as lost hid every panel snapped to a wall).
        guard isTracked else {
            if wasTracked { RoomLog.write("tracking paused for \(owner.frame)") }
            return
        }
        tracked[id] = transform
        if !wasTracked {
            RoomLog.write("found \(owner.frame) in \(name(owner.room))")
            defer { countFound() }
        }
        switch phase {
        case .finding, .asking:
            settle(owner.room, why: "recognised by \(owner.frame)")
        case .looking(let room):
            // ARKit knows better than the answer: an anchor it finds is here.
            settle(owner.room, why: room == owner.room ? "found as chosen" : "recognised, not the room chosen")
        case .settled(let room):
            // Never another room mid-session — its anchors would not be
            // tracked unless they were here, but one room's word is kept.
            guard room == owner.room else { return }
            revealed.remove(owner.frame)
            RoomFrames.shared.anchorMoved(owner.frame, firstTime: !wasTracked)
        }
    }

    func anchorRemoved(id: UUID) {
        guard tracked[id] != nil else { return }
        tracked[id] = nil
        if let owner = owners[id] { RoomLog.write("anchor removed for \(owner.frame)") }
    }

    /// An old room's single anchor found: each of its frames' places made
    /// into the frame's own anchor here, and the old anchor let go.
    private func migrate(_ roomAnchor: UUID, poses: [String: RoomPose], anchor: simd_float4x4) {
        legacy[roomAnchor] = nil
        // The old room's id was its anchor's.
        let room = roomAnchor
        RoomLog.write("old room \(name(room)) found: \(poses.count) places carried to frame anchors")
        if !isSettled { settle(room, why: "old room anchor found") }
        guard settledRoom == room else { save(); return }
        for (frameID, pose) in poses where pose.transform.count == 16 && placements[frameID]?[room] == nil {
            let world = anchor * RoomFrames.matrix(pose.transform)
            RoomFrames.shared.place(frameID, at: world, width: pose.width, height: pose.height)
        }
        save()
        Task { @MainActor in await removeAnchor(roomAnchor) }
    }

    // MARK: Places

    /// Whether a frame may be seen now: only once its place is known here,
    /// or it has no place here yet (new to this room), or it was revealed.
    func shouldShow(_ frameID: String) -> Bool {
        // Seen once since the room opened, never hidden again (19 Nov 2026,
        // Frode: panels vanished on Done) — hiding is only for the first
        // moments, before a frame's place is known.
        if seenThisOpening.contains(frameID) { return true }
        guard let room = settledRoom else { return madeThisRun.contains(frameID) }
        guard let placement = placements[frameID]?[room] else { return true }
        return tracked[placement.anchor] != nil || revealed.contains(frameID)
    }

    /// Whether a frame has never stood in this room.
    func isNewHere(_ frameID: String) -> Bool {
        guard let room = settledRoom else { return false }
        return placements[frameID]?[room] == nil
    }

    /// A frame's place in the room the reader stands in, in the world —
    /// only once its anchor is found this session.
    func pose(of frameID: String) -> (transform: simd_float4x4, width: Float, height: Float)? {
        guard let room = settledRoom, let placement = placements[frameID]?[room],
              let transform = tracked[placement.anchor] else { return nil }
        return (transform, placement.width, placement.height)
    }

    /// A frame's place now, kept for this room: a new anchor on the frame,
    /// the old one let go — only when it has really moved, and never for a
    /// frame whose place here is not yet found.
    func record(_ frame: RoomFrame) {
        guard let room = settledRoom, frame.transform.count == 16, frame.deleted != true else { return }
        let m = RoomFrames.matrix(frame.transform)
        let old = placements[frame.id]?[room]
        if let old {
            if let at = tracked[old.anchor] {
                if Self.close(at, m), old.width == frame.width, old.height == frame.height { return }
            } else if !revealed.contains(frame.id) {
                // Hidden, waiting for its anchor: where it stands means nothing.
                return
            }
        }
        guard !adding.contains(frame.id) else { return }
        adding.insert(frame.id)
        let width = frame.width, height = frame.height
        Task { @MainActor in
            defer { self.adding.remove(frame.id) }
            guard let anchor = await self.addAnchor(m) else {
                RoomLog.write("anchor NOT added for \(frame.id)")
                return
            }
            guard self.settledRoom == room else {
                await self.removeAnchor(anchor)
                return
            }
            // The new place first, so the frame is never without one —
            // shown in between, it would be hidden (19 Nov 2026).
            let previous = self.placements[frame.id]?[room]?.anchor
            self.placements[frame.id, default: [:]][room] = Placement(anchor: anchor, width: width, height: height)
            self.owners[anchor] = (frame.id, room)
            self.tracked[anchor] = m
            self.revealed.remove(frame.id)
            self.save()
            RoomLog.write("anchored \(frame.id) in \(self.name(room))")
            RoomFrames.shared.reshow(frame.id)
            if let previous {
                self.owners[previous] = nil
                self.tracked[previous] = nil
                await self.removeAnchor(previous)
            }
            // Moved again while the anchor was being made: anchored again.
            if let now = RoomFrames.shared.frame(frame.id), now.transform.count == 16,
               !Self.close(RoomFrames.matrix(now.transform), m) {
                self.record(now)
            }
        }
    }

    /// A frame deleted: its anchors let go in every room.
    func forget(_ frameID: String) {
        guard let rooms = placements.removeValue(forKey: frameID) else { return }
        for placement in rooms.values {
            owners[placement.anchor] = nil
            tracked[placement.anchor] = nil
            Task { @MainActor in await removeAnchor(placement.anchor) }
        }
        save()
    }

    /// Layouts no longer carry places: each frame's anchors are this
    /// headset's own, found again wherever the frame has stood.
    func poses(for frameIDs: Set<String>) -> [String: [String: RoomPose]] { [:] }
    func adopt(_ layoutPoses: [String: [String: RoomPose]]) {}

    /// Within a centimetre and a degree.
    private static func close(_ a: simd_float4x4, _ b: simd_float4x4) -> Bool {
        let da = SIMD3<Float>(a.columns.3.x, a.columns.3.y, a.columns.3.z)
        let db = SIMD3<Float>(b.columns.3.x, b.columns.3.y, b.columns.3.z)
        guard simd_distance(da, db) < 0.01 else { return false }
        let za = simd_normalize(SIMD3<Float>(a.columns.2.x, a.columns.2.y, a.columns.2.z))
        let zb = simd_normalize(SIMD3<Float>(b.columns.2.x, b.columns.2.y, b.columns.2.z))
        return simd_dot(za, zb) > 0.99985
    }

    private func name(_ room: UUID) -> String { rooms.first { $0.id == room }?.name ?? "an unknown room" }

    // MARK: Keeping

    private struct Stored: Codable {
        var rooms: [Room]
        /// The old scheme's: room (its anchor's id) → frame → place.
        var poses: [String: [String: RoomPose]]?
        /// Frame → room → its anchor.
        var placements: [String: [String: Placement]]?
    }

    nonisolated private static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("origami-physical-rooms.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.url),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        // A fresh start (19 Nov 2026, Frode: "we start from scratch today"):
        // every room known before forgotten, its anchors let go.
        let fresh = "physicalRooms.freshStart.v3"
        if !UserDefaults.standard.bool(forKey: fresh) {
            UserDefaults.standard.set(true, forKey: fresh)
            retiring = stored.rooms.map(\.id)
                + (stored.placements ?? [:]).values.flatMap { $0.values.map(\.anchor) }
            RoomLog.write("fresh start: \(stored.rooms.count) rooms and their anchors forgotten")
            save()
            return
        }
        rooms = stored.rooms
        for (key, places) in stored.poses ?? [:] where !places.isEmpty {
            if let id = UUID(uuidString: key) { legacy[id] = places }
        }
        for (frame, byRoom) in stored.placements ?? [:] {
            for (key, placement) in byRoom {
                guard let room = UUID(uuidString: key) else { continue }
                placements[frame, default: [:]][room] = placement
                owners[placement.anchor] = (frame, room)
            }
        }
    }

    private func save() {
        let stored = Stored(
            rooms: rooms,
            poses: legacy.isEmpty ? nil
                : Dictionary(uniqueKeysWithValues: legacy.map { ($0.key.uuidString, $0.value) }),
            placements: placements.mapValues { byRoom in
                Dictionary(uniqueKeysWithValues: byRoom.map { ($0.key.uuidString, $0.value) })
            })
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: Self.url, options: .atomic)
    }
}

/// What the rooms did, kept on the headset to be read back after a session
/// (19 Nov 2026): Application Support/origami-room-log.txt, the last 2000
/// lines.
enum RoomLog {
    nonisolated static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("origami-room-log.txt")
    }

    @MainActor private static var lines: [String] = {
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }()

    @MainActor static func write(_ line: String) {
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
        lines.append("\(stamp)  \(line)")
        if lines.count > 2000 { lines.removeFirst(lines.count - 2000) }
        print("Map/rooms: \(line)")
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    @MainActor static var text: String { lines.joined(separator: "\n") }
}

/// The question asked when the room is not recognised (19 Nov 2026, Frode):
/// which room this is — a known one to look for, or a new one to start —
/// and while a known one is looked for, what to do: look around.
struct RoomQuestionView: View {
    @State private var newName = ""

    var body: some View {
        let rooms = PhysicalRooms.shared
        VStack(alignment: .leading, spacing: 16) {
            switch rooms.phase {
            case .finding, .asking:
                if rooms.rooms.isEmpty {
                    Text("Name this room")
                        .font(.system(size: 34, weight: .semibold))
                    Text("Panels you place here will be found in it again.")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                } else {
                    // While finding, the room it is most likely lit; pinch
                    // any to say which it is.
                    Label(rooms.phase == .finding ? "Finding this room…" : "Which room are you in?",
                          systemImage: "viewfinder")
                        .font(.system(size: 30, weight: .semibold))
                    ForEach(rooms.recentRooms) { room in
                        let likely = room.id == rooms.likelyRoom
                        Button {
                            rooms.choose(room.id)
                        } label: {
                            HStack {
                                Text(room.name)
                                Spacer()
                                if likely, rooms.phase == .finding { ProgressView().controlSize(.small) }
                            }
                            .font(.system(size: 26, weight: likely ? .semibold : .regular))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 14)
                                .fill(Color.accentColor.opacity(likely ? 0.45 : 0)))
                            .overlay(RoundedRectangle(cornerRadius: 14)
                                .strokeBorder(.white.opacity(likely ? 0.8 : 0), lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                    }
                    Divider().padding(.vertical, 4)
                    Text("Or a new room, starting here")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                }
                HStack {
                    TextField("Room \(rooms.rooms.count + 1)", text: $newName)
                        .font(.system(size: 24))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { rooms.startNewRoom(named: newName) }
                    Button("Start Here") { rooms.startNewRoom(named: newName) }
                        .font(.system(size: 22, weight: .semibold))
                }
            case .looking, .settled:
                // Scanning (19 Nov 2026, Frode): what is happening, and how
                // far it has got.
                HStack(spacing: 14) {
                    ProgressView()
                    Text("Scanning \(rooms.currentName ?? "the room")…")
                        .font(.system(size: 32, weight: .semibold))
                }
                Text(rooms.expectedHere == 0
                     ? "Looking for the room."
                     : "\(rooms.foundHere) of \(rooms.expectedHere) panels in their places.")
                    .font(.system(size: 24, weight: .medium))
                Text("Look slowly around the walls where the panels stand — each appears in its place as the headset recognises it.")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Another Room") { rooms.askAgain() }
                    Spacer()
                    if rooms.isSettled {
                        Button("Done") { rooms.stopScanning() }
                    } else {
                        Button("Place Panels Here") { rooms.placeHereAnyway() }
                    }
                }
                .font(.system(size: 22, weight: .semibold))
                Text("Panels not found yet come before you; they still move to their places if found later.")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(32)
        .frame(width: 640, alignment: .leading)
        .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 36))
    }
}
#endif
