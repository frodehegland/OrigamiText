// Ported verbatim from Author (visionOS) — Views/KnowledgeSpace.
// Keep in step with Author; only the platform guard is ours.
#if os(visionOS)
//
// ArmMenu.swift
//

#if os(visionOS)
import SwiftUI
import RealityKit
import simd

// MARK: -

/// A forearm command menu, built the same way as Interatlas: a
/// `SpatialTrackingSession` tracks the hands, RealityKit hand anchors ride each
/// wrist, and small glass chips are laid out along the forearm each frame.
///
/// Each chip attaches its SwiftUI view directly with `ViewAttachmentComponent`,
/// so the menu is self-contained: a host view only needs to `install` it into
/// the RealityView content once and forward taps via `chipID(for:)`. Chips can
/// sit on the left arm, the right arm, or both.
@MainActor
final class ArmMenu {

    // MARK: - Configuration

    enum Side: Hashable {
        case left
        case right

        var chirality: AnchoringComponent.Target.Chirality {
            self == .left ? .left : .right
        }

        // Origami addition (carry back to Author): Swap Arms support.
        var opposite: Side {
            self == .left ? .right : .left
        }
    }

    /// One command on a forearm: an id (used for tap routing), its label, and
    /// which arm it rides.
    struct Chip {
        let id: String
        let title: String
        let side: Side
        /// An underside chip hangs beneath the forearm — the rarely
        /// touched commands (Settings) out of the working row.
        let underside: Bool

        init(id: String, title: String, side: Side, underside: Bool = false) {
            self.id = id
            self.title = title
            self.side = side
            self.underside = underside
        }
    }

    private let chips: [Chip]
    /// Whether the session also tracks planes — the Hallway asks for
    /// this so a reading laid flat can find the actual desk. One
    /// session carries both; a second session breaks the device.
    private let tracksPlanes: Bool
    /// Every chip on the opposite forearm from the one it declared —
    /// the Settings' Swap Arms toggle. Changed live via setInverted.
    /// Origami addition (carry back to Author), as are its init
    /// parameter, effectiveSide, and setInverted below.
    private var inverted: Bool

    init(chips: [Chip], tracksPlanes: Bool = false, inverted: Bool = false) {
        self.chips = chips
        self.tracksPlanes = tracksPlanes
        self.inverted = inverted
    }

    /// The arm a chip actually rides, the swap applied.
    private func effectiveSide(of chip: Chip) -> Side {
        inverted ? chip.side.opposite : chip.side
    }

    // MARK: -

    private var session: SpatialTrackingSession?
    private var updateSubscription: EventSubscription?

    // Per-side hand anchors — the wrist tracker. The wrist carries the
    // menu; the forearm joint names the true up-the-arm direction; the
    // index and little knuckles span the hand so the back of the arm
    // (where a watch face sits) can be derived per frame. Origami
    // addition (carry back to Author): forearm + dorsal anchoring per
    // the wrist-anchored-overlays notes; was a wrist X-axis heuristic
    // lifted toward world up.
    private var wrist: [Side: AnchorEntity] = [:]
    private var forearm: [Side: AnchorEntity] = [:]
    private var indexKnuckle: [Side: AnchorEntity] = [:]
    private var littleKnuckle: [Side: AnchorEntity] = [:]
    private var menus: [Side: Entity] = [:]
    private var items: [String: Entity] = [:]
    /// The menus' fade per side — tracking loss dims the chips out over
    /// a breath instead of snapping them away mid-air.
    private var menuOpacity: [Side: Float] = [:]

    // MARK: - Install

    /// Builds the chips, adds the hand anchors, and starts hand tracking. Call
    /// once from the RealityView's make closure (or an equivalent setup hook):
    /// `content` is only valid to mutate there, so the anchors must be added now.
    func install(in content: RealityViewContent) {
        guard items.isEmpty, !chips.isEmpty else { return }

        // Both orientations' arms get a menu and anchors, so a Swap
        // Arms flip mid-session only re-parents chips — even when the
        // chips all declared one side.
        for side in Set(chips.flatMap { [$0.side, $0.side.opposite] }) {
            let menu = Entity()
            menu.name = "arm.menu.\(side)"
            menu.isEnabled = false
            menus[side] = menu
        }

        for chip in chips {
            let item = Entity()
            item.name = chip.id
            // A watch-button-sized target: small, but read at wrist distance
            // where gaze is precise.
            item.components.set(CollisionComponent(shapes: [.generateBox(size: SIMD3<Float>(0.06, 0.035, 0.03))]))
            item.components.set(InputTargetComponent())
            item.components.set(HoverEffectComponent())

            // The glass label rides the item, billboarded and shrunk to
            // forearm scale (attachments render life-size).
            let label = Entity()
            label.components.set(ViewAttachmentComponent(rootView: ArmChipView(text: chip.title)))
            label.components.set(BillboardComponent())
            label.scale = SIMD3<Float>(repeating: 0.32)
            item.addChild(label)

            menus[effectiveSide(of: chip)]?.addChild(item)
            items[chip.id] = item
            titles[chip.id] = chip.title
        }

        // Predicted tracking keeps the chips glued to a moving wrist —
        // the render-time pose, not the last delivered one.
        for (side, menu) in menus {
            let wristAnchor = AnchorEntity(
                .hand(side.chirality, location: .joint(for: .wrist)),
                trackingMode: .predicted)
            let forearmAnchor = AnchorEntity(
                .hand(side.chirality, location: .joint(for: .forearmArm)),
                trackingMode: .predicted)
            let indexAnchor = AnchorEntity(
                .hand(side.chirality, location: .joint(for: .indexFingerKnuckle)),
                trackingMode: .predicted)
            let littleAnchor = AnchorEntity(
                .hand(side.chirality, location: .joint(for: .littleFingerKnuckle)),
                trackingMode: .predicted)
            content.add(wristAnchor)
            content.add(forearmAnchor)
            content.add(indexAnchor)
            content.add(littleAnchor)
            wristAnchor.addChild(menu)
            wrist[side] = wristAnchor
            forearm[side] = forearmAnchor
            indexKnuckle[side] = indexAnchor
            littleKnuckle[side] = littleAnchor
        }

        updateSubscription = content.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            MainActor.assumeIsolated { self?.tick(deltaTime: Float(event.deltaTime)) }
        }

        Task { await startTracking() }
    }

    private func startTracking() async {
        let session = SpatialTrackingSession()
        let unavailable = await session.run(SpatialTrackingSession.Configuration(
            tracking: tracksPlanes ? [.hand, .plane] : [.hand]))
        self.session = session

        if let unavailable, !unavailable.anchor.isEmpty {
            print("ArmMenu: hand tracking unavailable \(unavailable)")
        }
    }

    // MARK: - Hit test

    /// The chip id under a tapped entity (walking up parents), or nil.
    func chipID(for entity: Entity) -> String? {
        var node: Entity? = entity
        while let current = node {
            if items[current.name] != nil { return current.name }
            node = current.parent
        }
        return nil
    }

    // MARK: - Per-frame layout

    private func tick(deltaTime: Float) {
        for side in menus.keys {
            layout(side: side, deltaTime: deltaTime)
        }
    }

    /// Fades a side's menu toward shown or hidden — reacquisition eases
    /// the chips back in where a snap would pop them mid-air.
    private func fade(_ menu: Entity, side: Side, toward target: Float,
                      deltaTime: Float) {
        let current = menuOpacity[side] ?? 0
        // ~0.2 s edge to edge, per the anchoring notes.
        let step = deltaTime * 5
        let next = target > current
            ? min(target, current + step) : max(target, current - step)
        menuOpacity[side] = next
        menu.components.set(OpacityComponent(opacity: next))
        menu.isEnabled = next > 0.01
    }

    /// Lays the side's chips along the forearm. The forearm joint names
    /// the true up-the-arm direction, and the knuckles span the hand so
    /// the lift is the back of the arm — where a watch face sits — not
    /// world up; the row rides the arm through a roll. The old wrist
    /// X-axis and world-up answers remain as fallbacks for frames the
    /// forearm or knuckles go unseen.
    private func layout(side: Side, deltaTime: Float) {
        guard let wrist = wrist[side], let menu = menus[side] else {
            return
        }

        guard wrist.isAnchored else {
            fade(menu, side: side, toward: 0, deltaTime: deltaTime)
            return
        }

        fade(menu, side: side, toward: 1, deltaTime: deltaTime)

        let wristWorld = wrist.position(relativeTo: nil)

        // Up the arm, away from the fingers — from the forearm joint
        // itself when tracked, else the wrist's local X by the old
        // finger-side sign trick.
        var alongArm: SIMD3<Float>?
        if let forearm = forearm[side], forearm.isAnchored {
            let toElbow = forearm.position(relativeTo: nil) - wristWorld
            if simd_length(toElbow) > 1e-4 {
                alongArm = simd_normalize(
                    wrist.convert(direction: simd_normalize(toElbow), from: nil))
            }
        }
        if alongArm == nil, let index = indexKnuckle[side], index.isAnchored {
            let fingerWorld = index.position(relativeTo: nil) - wristWorld
            let fingerLocal = wrist.convert(direction: fingerWorld, from: nil)
            alongArm = fingerLocal.x >= 0 ? SIMD3(-1, 0, 0) : SIMD3(1, 0, 0)
        }
        guard let alongArm else { return }

        // The lift: dorsal — out of the back of the wrist, derived from
        // the hand's own span — so the chips sit off the skin the way a
        // watch does. World up when the knuckles go unseen.
        var lift: SIMD3<Float>?
        if let index = indexKnuckle[side], index.isAnchored,
           let little = littleKnuckle[side], little.isAnchored {
            let acrossToIndex = index.position(relativeTo: nil) - wristWorld
            let acrossToLittle = little.position(relativeTo: nil) - wristWorld
            var dorsal = simd_cross(acrossToIndex, acrossToLittle)
            if simd_length(dorsal) > 1e-6 {
                dorsal = simd_normalize(dorsal)
                // The cross flips with the hand's mirror — one sign per
                // chirality. Verified on device 13 Sep: palm-down, the
                // index→little cross exits the RIGHT palm and the LEFT
                // back-of-hand, so the right negates.
                if side == .right { dorsal = -dorsal }
                lift = wrist.convert(direction: dorsal, from: nil)
            }
        }
        if lift == nil {
            lift = wrist.convert(direction: SIMD3<Float>(0, 1, 0), from: nil)
        }
        guard var lift else { return }
        lift -= alongArm * simd_dot(lift, alongArm)
        let liftLength = simd_length(lift)
        guard liftLength > 1e-5 else { return }
        lift /= liftLength

        // ~5 cm of air between skin and the working row — worn, not
        // floating, with room to read (3.5 was too low once the lift
        // truly followed the arm); the underside chips hang 12 cm
        // beneath, so the two rows read apart at a glance. (Origami
        // tuning — Interatlas used 9 cm both ways.)
        // Hidden chips give up their place: the row packs, so a chip
        // beyond a hidden one (Graph past Reveal All Concepts) stands
        // beside its neighbour, not a slot away. Origami addition
        // (carry back to Author).
        let sideChips = chips.filter { effectiveSide(of: $0) == side }
        var topIndex = 0
        var underIndex = 0
        for chip in sideChips {
            guard let item = items[chip.id], item.isEnabled else { continue }
            if chip.underside {
                item.position = alongArm * (0.04 + 0.05 * Float(underIndex)) - lift * 0.12
                underIndex += 1
            } else {
                item.position = alongArm * (0.04 + 0.05 * Float(topIndex)) + lift * 0.05
                topIndex += 1
            }
        }
    }

    // MARK: - Visibility

    /// Moves every chip to the opposite forearm and back — the
    /// Settings' Swap Arms toggle, honored without reinstalling.
    func setInverted(_ flag: Bool) {
        guard flag != inverted else { return }
        inverted = flag
        for chip in chips {
            guard let item = items[chip.id],
                  let menu = menus[effectiveSide(of: chip)] else { continue }
            item.setParent(menu)
        }
    }

    /// The wrist's place in the room, when that hand is tracked —
    /// Origami addition (carry back to Author): Align to Room measures
    /// from the asking arm.
    func wristPosition(_ side: Side) -> SIMD3<Float>? {
        guard let anchor = wrist[side], anchor.isAnchored else { return nil }
        return anchor.position(relativeTo: nil)
    }

    /// Shows or hides one chip — a command that only means something
    /// sometimes steps away otherwise.
    func setChipVisible(_ id: String, _ visible: Bool) {
        items[id]?.isEnabled = visible
    }

    /// Every chip's current title, for redrawing the label when its
    /// active state changes. Origami addition (carry back to Author),
    /// as are activeIDs, setChipActive, and refreshChipLabel below.
    private var titles: [String: String] = [:]
    /// The chips whose function stands ON — drawn slightly larger,
    /// with a thicker border.
    private var activeIDs: Set<String> = []

    /// Relabels a chip in place — the label child carries the
    /// ViewAttachmentComponent, so we replace it there.
    func setChipTitle(_ id: String, _ title: String) {
        titles[id] = title
        refreshChipLabel(id)
    }

    /// Marks a chip's function as standing on: the chip grows a little
    /// and its border thickens, so the arm shows what is engaged.
    func setChipActive(_ id: String, _ active: Bool) {
        guard activeIDs.contains(id) != active else { return }
        if active { activeIDs.insert(id) } else { activeIDs.remove(id) }
        refreshChipLabel(id)
    }

    private func refreshChipLabel(_ id: String) {
        guard let label = items[id]?.children.first else { return }
        let active = activeIDs.contains(id)
        label.components.set(ViewAttachmentComponent(
            rootView: ArmChipView(text: titles[id] ?? id, active: active)))
        label.scale = SIMD3<Float>(repeating: active ? 0.37 : 0.32)
    }
}

// MARK: -

/// A forearm command rendered like the Knowledge Space nodes: a word on a
/// semi-transparent glass panel with a thin frame. Non-interactive itself; the
/// tap is handled by the collision on the entity it rides.
struct ArmChipView: View {
    let text: String
    /// The chip's function stands on: a thicker, brighter border (the
    /// slight growth is the label entity's scale, set by the menu).
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
                    .strokeBorder(.white.opacity(active ? 0.85 : 0.35),
                                  lineWidth: active ? 2.5 : 1)
            )
            .allowsHitTesting(false)
    }
}
#endif
#endif
