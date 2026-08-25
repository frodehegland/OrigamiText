// Ported verbatim from Author (visionOS) — Third Party/NodeImmersiveView.
// Keep in step with Author; only the platform guard is ours.
#if os(visionOS)
//
// NodeImmersiveView+System.swift
//

import RealityKit
import UIKit   // Origami addition (carry back to Author): the tint colours.

// MARK: - Origami additions (carry back to Author)

/// A node may ask the lines drawn TO it to wear a tint — Origami's
/// shared-citation green. Set on the node's model entity; the
/// connections system dresses a line in the tint while it serves that
/// node, and restores the constructor's own material when it moves on.
struct NodeConnectionTintComponent: Component {
    var tint: UIColor
}

/// The system's bookkeeping: the tint a line wears right now.
struct NodeConnectionAppliedTintComponent: Component {
    var tint: UIColor
}

/// The material the line was born with, kept for the way back.
struct NodeConnectionOriginalMaterialComponent: Component {
    var material: any RealityKit.Material
}

// MARK: -

extension NodeImmersiveView {
    
    // MARK: -
    
    class MovableConnectionsSystem: System {
        
        // MARK: -
        
        private let shouldDrawConnectionQuery = EntityQuery(where: .has(ShouldDrawConnectionComponent.self))
        private let connectedNodeQuery = EntityQuery(where: .has(ConnectedNodeComponent.self))
        private let movableConnectionQuery = EntityQuery(where: .has(MovableConnectionComponent.self))
        
        // MARK: -
        
        public required init(scene: Scene) {
            // Origami addition (carry back to Author): the connection
            // tint components register with the system that reads them.
            NodeConnectionTintComponent.registerComponent()
            NodeConnectionAppliedTintComponent.registerComponent()
            NodeConnectionOriginalMaterialComponent.registerComponent()
        }

        // Origami addition (carry back to Author): the line wears the
        // connected node's tint when it asks for one, the constructor's
        // own material otherwise — swapped only when the assignment
        // changes, never per frame.
        private func applyTint(of node: Entity, to line: Entity) {
            guard let model = line as? ModelEntity else { return }
            let wanted = node.components[NodeConnectionTintComponent.self]?.tint
            let applied = model.components[NodeConnectionAppliedTintComponent.self]?.tint
            guard wanted != applied else { return }
            if model.components[NodeConnectionOriginalMaterialComponent.self] == nil,
               let original = model.model?.materials.first {
                model.components.set(NodeConnectionOriginalMaterialComponent(material: original))
            }
            if let wanted {
                var material = UnlitMaterial()
                material.color = .init(tint: wanted)
                model.model?.materials = [material]
                model.components.set(NodeConnectionAppliedTintComponent(tint: wanted))
            } else {
                if let original = model.components[NodeConnectionOriginalMaterialComponent.self]?.material {
                    model.model?.materials = [original]
                }
                model.components.remove(NodeConnectionAppliedTintComponent.self)
            }
        }
        
        // MARK: -
        
        public func update(context: SceneUpdateContext) {
            let shouldDrawConnectionEntities = context.scene.performQuery(shouldDrawConnectionQuery)
            let connectedNodeEntities = context.scene.performQuery(connectedNodeQuery)
            let movableConnectionEntities = context.scene.performQuery(movableConnectionQuery)
            
            var pairs = [(Entity?, Entity?)]()
            
            for shouldDrawConnectionEntity in shouldDrawConnectionEntities {
                guard let shouldDrawConnectionComponent = shouldDrawConnectionEntity.components[ShouldDrawConnectionComponent.self] else {
                    continue
                }
                
                for connectedNodeEntity in connectedNodeEntities {
                    guard let connectedNodeComponent = connectedNodeEntity.components[ConnectedNodeComponent.self] else {
                        continue
                    }
                    
                    if connectedNodeComponent.owners.contains(shouldDrawConnectionComponent.id) {
                        pairs.append((shouldDrawConnectionEntity, connectedNodeEntity))
                        
                        continue
                    }
                }
            }
            
            var i = 0
            
            for movableConnectionEntity in movableConnectionEntities {
                let hide = {
                    movableConnectionEntity.isEnabled = false
                    movableConnectionEntity.transform = .identity
                }
                
                guard 0 <= i && i < pairs.count else {
                    hide()
                    
                    continue
                }
                
                let (a, b) = pairs[i]
                
                i += 1
                
                guard let a, let b else {
                    hide()
                    
                    continue
                }
                
                let vector = b.position - a.position
                let length = length(vector)
                
                guard length > 0.01 else {
                    hide()
                    
                    continue
                }
                
                let rotation = simd_quatf(from: [1.0, 0.0, 0.0], to: normalize(vector))
                let translation = 0.5 * (a.position + b.position)

                movableConnectionEntity.isEnabled = true
                movableConnectionEntity.transform = Transform(
                    scale: [length, 1.0, 1.0],
                    rotation: rotation,
                    translation: translation
                )

                // Origami addition (carry back to Author).
                applyTint(of: b, to: movableConnectionEntity)
            }
        }
    }
    
    /*
    class InteractiveButtonsSystem: System {
        
        // MARK: -
        
        private let attachmentQuery = EntityQuery(where: .has(AttachmentComponent.self))
        
        // MARK: -
        
        required init(scene: Scene) {
            // Empty.
        }
        
        // MARK: -
        
        public func update(context: SceneUpdateContext) {
            let attachmentEntities = context.scene.performQuery(attachmentQuery)
            
            for attachmentEntity in attachmentEntities {
                guard
                    let owner = attachmentEntity.components[AttachmentComponent.self]?.owner,
                    let item = owner.components[ItemComponent<Items.Element>.self]?.item,
                    let anchorRule = attachmentEntity.components[AnchorRuleComponent.self]?.anchorRule
                else {
                    continue
                }
                
                let extents = owner.visualBounds(relativeTo: nil).extents
                let attachmentExtends = attachmentEntity.visualBounds(relativeTo: nil).extents
                
                let startPoint: SIMD3<Float> = [
                    extents.x * (anchorRule.anchor.x - 0.5),
                    extents.y * (anchorRule.anchor.y - 0.5),
                    extents.z * (anchorRule.anchor.z - 0.5)
                ]
                
                let additional: SIMD3<Float> = [
                    {
                        if anchorRule.offset.x == 0.0 {
                            return 0.0
                        }
                        
                        return (anchorRule.offset.x < 0.0 ? -1.0 : +1.0) * 0.5 * attachmentExtends.x + anchorRule.offset.x
                    }(),
                    {
                        if anchorRule.offset.y == 0.0 {
                            return 0.0
                        }
                        
                        return (anchorRule.offset.y < 0.0 ? -1.0 : +1.0) * 0.5 * attachmentExtends.y + anchorRule.offset.y
                    }(),
                    {
                        if anchorRule.offset.z == 0.0 {
                            return 0.0
                        }
                        
                        return (anchorRule.offset.z < 0.0 ? -1.0 : +1.0) * 0.5 * attachmentExtends.z + anchorRule.offset.z
                    }()
                ]
                
                attachmentEntity.isEnabled = item.isAttachmentsEnabled
                attachmentEntity.position = owner.position + startPoint + additional
            }
        }
    }
     */
}
#endif
