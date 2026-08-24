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
                
                var cacheNodes = Set<Items.Element>()
                var storeNodes = [Items.Element: Entity]()
                
                var storeConnections = [Entity]()
                
                fetch(
                    content: content,
                    cacheNodes: &cacheNodes,
                    storeNodes: &storeNodes,
                    storeConnections: &storeConnections
                )
                
                guard let movingItem = value.entity.components[ItemComponent<Items.Element>.self]?.item else {
                    return
                }
                
                var movingItems = [Items.Element]()
                
                if shouldMoveNodeBlock?(movingItem) ?? true {
                    value.entity.position = movingEntityStartPosition + getDelta()
                    
                    movingItems.append(movingItem)
                }
                
                if shouldCheckMoveAnotherNodesBlock?(movingItem) ?? false {
                    for anotherItem in items {
                        if shouldMoveAnotherNodeBlock?(anotherItem) ?? false {
                            guard let startPosition = storeNodes[anotherItem]?.components[StartPositionComponent.self]?.position else {
                                continue
                            }
                            
                            let position = startPosition + getDelta()
                            
                            storeNodes[anotherItem]?.position = position
                            
                            movingItems.append(anotherItem)
                        }
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
                
                magnification = value.magnification
            }
            .onEnded { _ in
                magnification = 1.0
                
                hasPinchIn = false
                hasPinchOut = false
            }
    }
}
#endif
