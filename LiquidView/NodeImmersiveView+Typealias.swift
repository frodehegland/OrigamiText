// Ported verbatim from Author (visionOS) — Third Party/NodeImmersiveView.
// Keep in step with Author; only the platform guard is ours.
#if os(visionOS)
//
// NodeImmersiveView+Typealias.swift
//

import SwiftUI
import RealityKit

// MARK: -

public extension NodeImmersiveView {
    
    // MARK: -
    
    typealias ConstructorViewBlock = (_ item: Items.Element) -> C
    
    typealias ConstructorAttachmentBlock = (
        _ identifier: AnyHashable,
        _ item: Items.Element
    ) -> A
    
    typealias ConstructorNodeModelEntityBlock = (
        _ item: Items.Element,
        _ texturedPlane: ModelEntity
    ) -> (
        modelEntity: ModelEntity?,
        collisionShape: ShapeResource
    )
    
    typealias ConstructorConnectionModelEntityBlock = () -> ModelEntity
    
    typealias AttachmentIdentifiersBlock = (_ item: Items.Element) -> [AnyHashable]
    
    typealias AttachmentAnchorRuleBlock = (
        _ identifier: AnyHashable,
        _ item: Items.Element
    ) -> AnchorRule
    
    typealias ShouldEnableNodeBlock = (_ item: Items.Element) -> Bool
    
    typealias ShouldMoveNodeBlock = (_ movingItem: Items.Element) -> Bool
    
    typealias ShouldCheckMoveAnotherNodesBlock = (_ movingItem: Items.Element) -> Bool
    
    typealias ShouldMoveAnotherNodeBlock = (_ anotherItem: Items.Element) -> Bool
    
    typealias ShouldDrawConnectionForNodeBlock = (_ item: Items.Element) -> Bool
    
    typealias ShouldUseHoverNodeBlock = (_ item: Items.Element) -> Bool
    
    typealias ConnectedNodesToNodeBlock = (_ item: Items.Element) -> [Items.Element]
    
    typealias NodeMaxWidthBlock = (_ item: Items.Element) -> CGFloat
    
    typealias OnMoveNodeBlock = (_ movedItems: [Items.Element]) -> Void
    
    typealias OnEndMoveNodeBlock = (
        _ items: [Items.Element],
        _ oldItems: Set<Items.Element>,
        _ newItems: Set<Items.Element>,
    ) -> Void
    
    typealias OnTapNodeBlock = (
        _ tapCount: Int,
        _ item: Items.Element
    ) -> Void
    
    typealias OnLongTapNodeBlock = (_ item: Items.Element) -> Void
    
    typealias OnPinchInBlock = () -> Void
    
    typealias OnPinchOutBlock = () -> Void
    
    typealias OnUpdateNodeSizesBlock = (_ sizes: [AnyHashable: SIMD3<Float>]) -> Void

    // Origami addition (carry back to Author): constrains a dragged
    // node — (item, proposed position, drag start) → allowed position.
    typealias ConstrainMovedNodeBlock = (
        _ item: Items.Element,
        _ proposed: SIMD3<Float>,
        _ start: SIMD3<Float>
    ) -> SIMD3<Float>
}
#endif
