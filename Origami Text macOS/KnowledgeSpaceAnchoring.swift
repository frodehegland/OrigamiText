// Ported verbatim from Author (visionOS) — Views/KnowledgeSpace.
// Keep in step with Author; only the platform guard is ours.
#if os(visionOS)
//
// KnowledgeSpaceAnchoring.swift
//

import ARKit
import RealityKit
import simd
import QuartzCore

// MARK: -

/// Persists Knowledge Space node placement using ARKit world anchors and snaps
/// nodes onto detected real surfaces.
///
/// World anchors survive across launches AND only re-localise in the physical
/// space where they were created, so nodes return to the same spot each time
/// and each room (home, work, a coffee shop) keeps its own arrangement
/// automatically — no explicit room identification needed. Plane detection lets
/// a dropped node rest flat against the nearest wall or table.
@MainActor
final class KnowledgeSpaceAnchoring {

    // MARK: -

    private let session = ARKitSession()
    private let worldTracking = WorldTrackingProvider()
    private let planeDetection = PlaneDetectionProvider(alignments: [.horizontal, .vertical])

    // Persisted: concept id <-> world anchor UUID.
    private var conceptToAnchor: [String: UUID]
    private var anchorToConcept: [UUID: String] = [:]

    // Live detected surfaces.
    private var planes: [UUID: PlaneAnchor] = [:]

    /// World transforms of currently-localised anchors, keyed by concept id.
    private(set) var localizedTransforms: [String: simd_float4x4] = [:]

    /// Called when a concept's saved anchor localises so an already-placed
    /// node can jump to its remembered spot.
    var onLocalize: ((String, simd_float4x4) -> Void)?

    private static let defaultsKey = "knowledgeSpace.anchors"

    /// Snap only when the drop is within this distance of a surface.
    private static let snapDistance: Float = 0.5
    /// Rest the node just off the surface so it doesn't z-fight with it.
    private static let surfaceOffset: Float = 0.005

    // MARK: -

    init() {
        let stored = UserDefaults.standard.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]

        var mapping: [String: UUID] = [:]
        for (concept, uuidString) in stored {
            if let uuid = UUID(uuidString: uuidString) {
                mapping[concept] = uuid
                anchorToConcept[uuid] = concept
            }
        }
        conceptToAnchor = mapping
    }

    // MARK: - Session

    /// Runs world tracking + plane detection and streams their updates.
    /// Requires an open immersive space; returns if unsupported/denied.
    func run() async {
        guard WorldTrackingProvider.isSupported else {
            print("KS/anchor: world tracking unsupported")
            return
        }

        var providers: [DataProvider] = [worldTracking]
        if PlaneDetectionProvider.isSupported {
            providers.append(planeDetection)
        }

        do {
            try await session.run(providers)
        } catch {
            print("KS/anchor: session.run failed \(error)")
            return
        }

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.consumeWorldAnchors() }
            group.addTask { await self.consumePlanes() }
        }
    }

    private func consumeWorldAnchors() async {
        for await update in worldTracking.anchorUpdates {
            let anchor = update.anchor

            switch update.event {
            case .added, .updated:
                guard let concept = anchorToConcept[anchor.id], anchor.isTracked else {
                    continue
                }

                let transform = anchor.originFromAnchorTransform
                localizedTransforms[concept] = transform
                onLocalize?(concept, transform)

            case .removed:
                if let concept = anchorToConcept[anchor.id] {
                    localizedTransforms[concept] = nil
                }
            }
        }
    }

    private func consumePlanes() async {
        for await update in planeDetection.anchorUpdates {
            switch update.event {
            case .added, .updated:
                planes[update.anchor.id] = update.anchor
            case .removed:
                planes[update.anchor.id] = nil
            }
        }
    }

    // MARK: - Placement

    /// The remembered world transform for a concept, if its anchor localised.
    func transform(for conceptID: String) -> simd_float4x4? {
        return localizedTransforms[conceptID]
    }

    /// If `dropTransform` is near a detected surface, returns a transform that
    /// rests the node flat against it (facing out along the surface normal);
    /// otherwise returns `dropTransform` unchanged.
    func snappedTransform(near dropTransform: simd_float4x4) -> simd_float4x4 {
        let dropPosition = translation(dropTransform)

        var best: (score: Float, transform: simd_float4x4)?

        for plane in planes.values {
            let planeTransform = plane.originFromAnchorTransform
            let normal = normalize(axis(planeTransform, 1))          // plane local +Y
            let center = translation(planeTransform)

            let toDrop = dropPosition - center
            let perpendicular = dot(toDrop, normal)
            let projected = dropPosition - perpendicular * normal
            let lateral = distance(projected, center)

            guard abs(perpendicular) < Self.snapDistance, lateral < 3.0 else {
                continue
            }

            let score = abs(perpendicular) + 0.3 * lateral

            if best == nil || score < best!.score {
                let position = projected + normal * Self.surfaceOffset
                let reference = orientationReference(normal: normal, at: position)
                best = (score, Self.surfaceTransform(at: position, normal: normal, reference: reference))
            }
        }

        return best?.transform ?? dropTransform
    }

    /// The "up" hint for a snapped card: upright for a wall, but for a
    /// horizontal surface the text top points away from the viewer so the card
    /// reads toward them.
    private func orientationReference(normal: SIMD3<Float>, at position: SIMD3<Float>) -> SIMD3<Float> {
        let worldUp = SIMD3<Float>(0, 1, 0)

        guard abs(dot(normal, worldUp)) > 0.85 else {
            return worldUp
        }

        guard let head = devicePosition() else {
            return SIMD3<Float>(0, 0, 1)
        }

        var away = position - head
        away.y = 0
        return length(away) > 0.001 ? normalize(away) : SIMD3<Float>(0, 0, 1)
    }

    /// The viewer's current head position in world space.
    private func devicePosition() -> SIMD3<Float>? {
        guard let anchor = worldTracking.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()) else {
            return nil
        }

        return translation(anchor.originFromAnchorTransform)
    }

    // MARK: - Anchoring

    /// Persists a concept's node at a world transform, replacing any prior
    /// anchor for it.
    func anchor(conceptID: String, worldTransform: simd_float4x4) async {
        if let old = conceptToAnchor[conceptID] {
            try? await worldTracking.removeAnchor(forID: old)
            anchorToConcept[old] = nil
        }

        let worldAnchor = WorldAnchor(originFromAnchorTransform: worldTransform)

        do {
            try await worldTracking.addAnchor(worldAnchor)

            conceptToAnchor[conceptID] = worldAnchor.id
            anchorToConcept[worldAnchor.id] = conceptID
            localizedTransforms[conceptID] = worldTransform
            save()
        } catch {
            print("KS/anchor: addAnchor failed \(error)")
        }
    }

    private func save() {
        let dictionary = conceptToAnchor.mapValues { $0.uuidString }
        UserDefaults.standard.set(dictionary, forKey: Self.defaultsKey)
    }

    // MARK: - Matrix helpers

    private func translation(_ m: simd_float4x4) -> SIMD3<Float> {
        return SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
    }

    private func axis(_ m: simd_float4x4, _ index: Int) -> SIMD3<Float> {
        let c = m[index]
        return SIMD3<Float>(c.x, c.y, c.z)
    }

    /// A transform whose +Z faces `normal` and +Y aligns to `reference`,
    /// positioned at `position` — orients a card flat against a surface.
    private static func surfaceTransform(at position: SIMD3<Float>, normal: SIMD3<Float>, reference: SIMD3<Float>) -> simd_float4x4 {
        let right = normalize(cross(reference, normal))
        let up = normalize(cross(normal, right))

        var m = matrix_identity_float4x4
        m.columns.0 = SIMD4<Float>(right, 0)
        m.columns.1 = SIMD4<Float>(up, 0)
        m.columns.2 = SIMD4<Float>(normal, 0)
        m.columns.3 = SIMD4<Float>(position, 1)
        return m
    }
}

// MARK: -

/// Holds live references to placed node entities by concept id, so anchor
/// callbacks can reposition them without churning SwiftUI state.
final class KnowledgeSpaceNodeRegistry {
    var entities: [String: Entity] = [:]
}
#endif
