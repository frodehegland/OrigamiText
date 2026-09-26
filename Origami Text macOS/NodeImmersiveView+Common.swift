// Ported verbatim from Author (visionOS) — Third Party/NodeImmersiveView.
// Keep in step with Author; only the platform guard is ours.
#if os(visionOS)
//
// NodeImmersiveView+Common.swift
//

import SwiftUI
import RealityKit

// MARK: -

extension NodeImmersiveView {
    
    // MARK: -
    
    func fetch(
        content: RealityViewContent,
        cacheNodes: inout Set<Items.Element>,
        storeNodes: inout [Items.Element: Entity],
        storeConnections: inout [Entity]
    ) {
        for entity in content.entities {
            if let item = entity.components[ItemComponent<Items.Element>.self]?.item {
                cacheNodes.insert(item)
                storeNodes[item] = entity
                
                continue
            }
            
            if entity.components.has(MovableConnectionComponent.self) {
                storeConnections.append(entity)
                
                continue
            }
        }
    }
    
    func setupPinchArea() {
        guard let content else {
            return
        }
        
        let size: Float = 10.0
        
        let positions: [SIMD3<Float>] = [
            [-size, 0.0, 0.0],
            [+size, 0.0, 0.0],
            [0.0, -size, 0.0],
            [0.0, +size, 0.0],
            [0.0, 0.0, -size],
            [0.0, 0.0, +size],
        ]
        
        let shape = ShapeResource.generateBox(
            width: size,
            height: size,
            depth: size
        )
        
        let collisionComponent = CollisionComponent(
            shapes: [shape],
            mode: .default
        )
        
        for position in positions {
            let entity = Entity()
            
            entity.components.set(collisionComponent)
            entity.components.set(PinchComponent())
            entity.components.set(InputTargetComponent())
            
            entity.position = position
            
            content.add(entity)
        }
    }
    
    func update(
        _ content: RealityViewContent,
        _ attachments: RealityViewAttachments
    ) {
        // Ids are not guaranteed unique (two flow nodes can reference the
        // same glossary entry), so keep every entity per id and pair them
        // off one to one below - a plain [id: entity] dictionary would remap
        // one entity to the other item's value and cross-wire gestures.
        var storedNodes = [Items.Element.ID: [(item: Items.Element, entity: Entity)]]()
        var storeConnections = [Entity]()

        for entity in content.entities {
            if let item = entity.components[ItemComponent<Items.Element>.self]?.item {
                storedNodes[item.id, default: []].append((item, entity))

                continue
            }

            if entity.components.has(MovableConnectionComponent.self) {
                storeConnections.append(entity)

                continue
            }
        }

        defer {
            var sizes = [AnyHashable: SIMD3<Float>]()

            for entity in content.entities {
                if let item = entity.components[ItemComponent<Items.Element>.self]?.item {
                    entity.position = item.position ?? defaultNodePosition
                    entity.components.set(StartPositionComponent(position: entity.position))

                    let extents: SIMD3<Float>

                    if let cached = entity.components[ExtentsComponent.self]?.extents {
                        extents = cached
                    } else {
                        extents = entity.visualBounds(relativeTo: nil).extents
                        entity.components.set(ExtentsComponent(extents: extents))
                    }

                    sizes[item.hashValue] = extents

                    continue
                }
            }

            updateShouldDrawConnectionComponents()

            onUpdateNodeSizesBlock?(sizes)
        }

        // Diff by identity: a node entity is only rebuilt (rasterized on the
        // main thread) when its visual content changed. Position and other
        // in-place state are applied to the existing entity in the defer
        // block above; its stored item is refreshed so gesture callbacks and
        // size keys always carry current values.
        var newNodes = [Items.Element]()

        for item in items {
            guard var group = storedNodes[item.id], !group.isEmpty else {
                newNodes.append(item)

                continue
            }

            // Each item claims exactly one stored entity, preferring one it
            // still matches visually so unchanged duplicates keep theirs.
            if let index = group.firstIndex(where: { $0.item.isVisuallyEqual(to: item) }) {
                let stored = group.remove(at: index)

                stored.entity.components.set(ItemComponent(item: item))
                stored.entity.isEnabled = shouldEnableNodeBlock?(item) ?? true
            } else {
                let stored = group.removeFirst()

                content.remove(stored.entity)
                newNodes.append(item)
            }

            storedNodes[item.id] = group
        }

        // Whatever no item claimed - vanished ids or surplus duplicates -
        // goes away.
        for group in storedNodes.values {
            for stored in group {
                content.remove(stored.entity)
            }
        }

        if !newNodes.isEmpty {
            for item in newNodes {

                let view = constructorViewBlock(item)
                let maxWidth = nodeMaxWidthBlock?(item) ?? defaultMaxWidth
                
                let framedView = view
                    .frame(maxWidth: maxWidth)
                    .fixedSize(horizontal: false, vertical: true)
                
                guard
                    let image = UIImage.image(framedView, maxWidth),
                    let texturedPlane = ModelEntity.texturedPlane(with: image, ratio: 0.001)
                else {
                    continue
                }
                
                let tuple = constructorNodeModelEntityBlock(item, texturedPlane)
                let collisionShape = tuple.collisionShape
                
                var modelEntity = tuple.modelEntity
                
                if modelEntity == nil {
                    modelEntity = texturedPlane
                }
                
                guard let modelEntity else {
                    continue
                }
                
                let collisionComponent = CollisionComponent(
                    shapes: [collisionShape],
                    mode: .default
                )
                
                var identifiers: [AnyHashable]
                
                if let result = attachmentIdentifiersBlock?(item), !result.isEmpty {
                    identifiers = result
                } else {
                    identifiers = [item.id]
                }
                
                for id in identifiers {
                    if let attachmentEntity = attachments.entity(for: id) {
                        let anchorRule = attachmentAnchorRuleBlock?(id, item) ?? .empty
                        
                        let extents = modelEntity.visualBounds(relativeTo: nil).extents
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
                        attachmentEntity.position = startPoint + additional
                        
                        modelEntity.addChild(attachmentEntity)
                    }
                }
                
                modelEntity.components.set(collisionComponent)
                modelEntity.components.set(InputTargetComponent())
                modelEntity.components.set(PinchComponent())
                modelEntity.components.set(ItemComponent(item: item))
                
                if shouldUseHoverNodeBlock?(item) ?? true {
                    modelEntity.components.set(HoverEffectComponent())
                }
                
                modelEntity.isEnabled = shouldEnableNodeBlock?(item) ?? true
                
                content.add(modelEntity)
            }
        }
        
        if connectionsCount < storeConnections.count {
            let diff = storeConnections.count - connectionsCount
            
            for _ in 0..<diff {
                let entity = storeConnections.removeLast()
                
                content.remove(entity)
            }
        } else if connectionsCount > storeConnections.count {
            let diff = connectionsCount - storeConnections.count
            
            for _ in 0..<diff {
                if let modelEntity = constructorConnectionModelEntityBlock?() {
                    modelEntity.components.set(PinchComponent())
                    modelEntity.components.set(MovableConnectionComponent())
                    
                    modelEntity.isEnabled = false
                    
                    content.add(modelEntity)
                }
            }
        }
    }
    
    func updateShouldDrawConnectionComponents() {
        guard let content else {
            return
        }
        
        var cacheNodes = Set<Items.Element>()
        var storeNodes = [Items.Element: Entity]()
        
        var storeConnections = [Entity]()
        
        fetch(
            content: content,
            cacheNodes: &cacheNodes,
            storeNodes: &storeNodes,
            storeConnections: &storeConnections
        )
        
        for item in cacheNodes {
            storeNodes[item]?.components.remove(ShouldDrawConnectionComponent.self)
            storeNodes[item]?.components.remove(ConnectedNodeComponent.self)
        }
        
        for item in cacheNodes {
            let shouldDrawConnection = shouldDrawConnectionForNodeBlock?(item) ?? false
            
            if shouldDrawConnection {
                storeNodes[item]?.components.set(ShouldDrawConnectionComponent(id: item.id.hashValue))
            }
            
            guard let connectedItems = connectedNodesToNodeBlock?(item) else {
                return
            }
            
            for connectedItem in connectedItems {
                guard let entity = storeNodes[connectedItem] else {
                    continue
                }
                
                if shouldDrawConnection {
                    guard var component = entity.components[ConnectedNodeComponent.self] else {
                        entity.components.set(ConnectedNodeComponent(owners: [item.id.hashValue]))
                        
                        continue
                    }
                    
                    component.owners.append(item.id.hashValue)
                    
                    entity.components.set(component)
                }
            }
        }
    }
    
    func clear() {
        guard let content else {
            return
        }
        
        for entity in content.entities {
            content.remove(entity)
        }
    }
}
#endif
