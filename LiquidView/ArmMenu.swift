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

    // Per-side hand anchors: the wrist carries the menu, the middle-finger
    // knuckle tells which way the fingers point so the chips climb the arm.
    private var wrist: [Side: AnchorEntity] = [:]
    private var knuckle: [Side: AnchorEntity] = [:]
    private var menus: [Side: Entity] = [:]
    private var items: [String: Entity] = [:]

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
        }

        for (side, menu) in menus {
            let wristAnchor = AnchorEntity(.hand(side.chirality, location: .joint(for: .wrist)))
            let knuckleAnchor = AnchorEntity(.hand(side.chirality, location: .joint(for: .middleFingerKnuckle)))
            content.add(wristAnchor)
            content.add(knuckleAnchor)
            wristAnchor.addChild(menu)
            wrist[side] = wristAnchor
            knuckle[side] = knuckleAnchor
        }

        updateSubscription = content.subscribe(to: SceneEvents.Update.self) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
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

    private func tick() {
        for side in menus.keys {
            layout(side: side)
        }
    }

    /// Lays the side's chips along the forearm — the wrist joint's local axis
    /// runs along the arm, the knuckle tells which sign points at the fingers
    /// (so the opposite climbs toward the elbow), and each chip is lifted
    /// perpendicular toward world up so it hovers just above the skin.
    private func layout(side: Side) {
        guard let wrist = wrist[side], let knuckle = knuckle[side], let menu = menus[side] else {
            return
        }

        guard wrist.isAnchored, knuckle.isAnchored else {
            menu.isEnabled = false
            return
        }

        menu.isEnabled = true

        let fingerWorld = knuckle.position(relativeTo: nil) - wrist.position(relativeTo: nil)
        let fingerLocal = wrist.convert(direction: fingerWorld, from: nil)
        let alongArm: SIMD3<Float> = fingerLocal.x >= 0 ? SIMD3(-1, 0, 0) : SIMD3(1, 0, 0)

        var lift = wrist.convert(direction: SIMD3<Float>(0, 1, 0), from: nil)
        lift -= alongArm * simd_dot(lift, alongArm)
        let liftLength = simd_length(lift)
        guard liftLength > 1e-5 else { return }
        lift /= liftLength

        // ~7 cm of air between skin and the working row; the underside
        // chips hang lower, 12 cm beneath, so the two rows read apart
        // at a glance. (Origami tuning — Interatlas used 9 cm both ways.)
        let sideChips = chips.filter { effectiveSide(of: $0) == side }
        var topIndex = 0
        var underIndex = 0
        for chip in sideChips {
            guard let item = items[chip.id] else { continue }
            if chip.underside {
                item.position = alongArm * (0.04 + 0.05 * Float(underIndex)) - lift * 0.12
                underIndex += 1
            } else {
                item.position = alongArm * (0.04 + 0.05 * Float(topIndex)) + lift * 0.07
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

    /// Relabels a chip in place — the label child carries the
    /// ViewAttachmentComponent, so we replace it there.
    func setChipTitle(_ id: String, _ title: String) {
        guard let label = items[id]?.children.first else { return }
        label.components.set(ViewAttachmentComponent(rootView: ArmChipView(text: title)))
    }
}

// MARK: -

/// A forearm command rendered like the Knowledge Space nodes: a word on a
/// semi-transparent glass panel with a thin frame. Non-interactive itself; the
/// tap is handled by the collision on the entity it rides.
struct ArmChipView: View {
    let text: String

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
                    .strokeBorder(.white.opacity(0.35), lineWidth: 1)
            )
            .allowsHitTesting(false)
    }
}
#endif
#endif
