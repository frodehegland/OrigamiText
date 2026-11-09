// Ported verbatim from Author (visionOS) — Third Party/NodeImmersiveView.
// Keep in step with Author; only the platform guard is ours.
#if os(visionOS)
//
// NodeImmersiveView+Gestures.swift
//

import SwiftUI
import RealityKit

// MARK: -

extension NodeImmersiveView {
    
    // MARK: -
    
    func tapGesture() -> some Gesture {
        SpatialTapGesture(count: 1)
            .targetedToAnyEntity()
            .onEnded { value in
                // Let a caller claim the tap first (e.g. an arm-menu chip).
                if onTapEntityBlock?(value.entity) == true {
                    return
                }

                guard let item = value.entity.components[ItemComponent<Items.Element>.self]?.item else {
                    return
                }
                
                onTapNodeBlock?(1, item)
            }
    }
    
    func doubleTapGesture() -> some Gesture {
        SpatialTapGesture(count: 2)
            .targetedToAnyEntity()
            .onEnded { value in
                guard let item = value.entity.components[ItemComponent<Items.Element>.self]?.item else {
                    return
                }
                
                onTapNodeBlock?(2, item)
            }
    }
    
    func tripleTapGesture() -> some Gesture {
        SpatialTapGesture(count: 3)
            .targetedToAnyEntity()
            .onEnded { value in
                guard let item = value.entity.components[ItemComponent<Items.Element>.self]?.item else {
                    return
                }
                
                onTapNodeBlock?(3, item)
            }
    }
    
    func longTapGesture() -> some Gesture {
        LongPressGesture(minimumDuration: 0.8)
            .targetedToAnyEntity()
            .onEnded { value in
                guard let item = value.entity.components[ItemComponent<Items.Element>.self]?.item else {
                    return
                }
                
                onLongTapNodeBlock?(item)
            }
    }
    
    func dragGesture() -> some Gesture {
        DragGesture(coordinateSpace: .global)
            .targetedToAnyEntity()
            .onChanged { value in
                guard
                    let content,
                    let movingEntityStartPosition = value.entity.components[StartPositionComponent.self]?.position
                else {
                    return
                }
                
                let getDelta = {
                    return value.convert(
                        value.gestureValue.translation3D,
                        from: .local,
                        to: .scene
                    )
                }
                
                guard let movingItem = value.entity.components[ItemComponent<Items.Element>.self]?.item else {
                    return
                }
                
                var movingItems = [Items.Element]()

                if shouldMoveNodeBlock?(movingItem) ?? true {
                    // Origami addition (carry back to Author): a caller
                    // may constrain where the drag can take a node —
                    // e.g. holding a timeline axis — given the item,
                    // the proposed position, and where the drag began.
                    var position = movingEntityStartPosition + getDelta()
                    if let constrain = constrainMovedNodeBlock {
                        position = constrain(movingItem, position, movingEntityStartPosition)
                    }
                    value.entity.position = position

                    movingItems.append(movingItem)
                }
                
                if shouldCheckMoveAnotherNodesBlock?(movingItem) ?? false {
                    // Origami change (8 Nov 2026, carry back to Author):
                    // walk the node entities themselves, each carrying its
                    // item, rather than keying a dictionary by item — the
                    // items hash every field (a paper's whole abstract),
                    // and this ran for every node on every drag event.
                    let delta = getDelta()
                    for entity in content.entities {
                        guard let anotherItem = entity.components[ItemComponent<Items.Element>.self]?.item,
                              shouldMoveAnotherNodeBlock?(movingItem, anotherItem) ?? false,
                              let startPosition = entity.components[StartPositionComponent.self]?.position
                        else {
                            continue
                        }

                        var position = startPosition + delta
                        // Origami addition (carry back to Author):
                        // the riders obey the same constraint as
                        // the dragged node — a citation carried
                        // with its family keeps its year's Z.
                        if let constrain = constrainMovedNodeBlock {
                            position = constrain(anotherItem, position, startPosition)
                        }

                        if entity.position != position { entity.position = position }

                        movingItems.append(anotherItem)
                    }
                }
                
                onMoveNodeBlock?(movingItems)
            }
            .onEnded { value in
                guard let content else {
                    return
                }
                
                var cacheNodes = Set<Items.Element>()
                var storeNodes = [Items.Element: Entity]()
                
                var storeConnections = [Entity]()
                
                var items = [Items.Element]()
                
                fetch(
                    content: content,
                    cacheNodes: &cacheNodes,
                    storeNodes: &storeNodes,
                    storeConnections: &storeConnections
                )
                
                for (_, entity) in storeNodes {
                    guard var item = entity.components[ItemComponent<Items.Element>.self]?.item else {
                        continue
                    }
                    
                    entity.components.set(StartPositionComponent(position: entity.position))
                    
                    item.position = entity.position
                    
                    items.append(item)
                }
                
                let setNewItems = Set(items)
                let setOldItems = Set(self.items)
                
                let newItems = setNewItems.subtracting(setOldItems)
                let oldItems = setOldItems.subtracting(setNewItems)
                
                onEndMoveNodeBlock?(items, oldItems, newItems)
            }
    }
    
    func pinchGesture() -> some Gesture {
        MagnifyGesture()
            .targetedToAnyEntity()
            .onChanged { value in
                guard value.entity.components[PinchComponent.self] != nil else {
                    return
                }
                
                let pinchInMagnification: CGFloat = 0.8
                let pinchOutMagnification: CGFloat = 1.2
                
                if !hasPinchIn && value.magnification <= pinchInMagnification {
                    hasPinchIn = true
                    
                    onPinchInBlock?()
                }
                
                if !hasPinchOut && value.magnification >= pinchOutMagnification {
                    hasPinchOut = true
                    
                    onPinchOutBlock?()
                }
                // Origami change (8 Nov 2026): `magnification` is no
                // longer written each frame of a pinch — nothing reads it,
                // and every write asked SwiftUI to look at the whole room.
            }
            .onEnded { _ in
                hasPinchIn = false
                hasPinchOut = false
            }
    }
}
#endif
