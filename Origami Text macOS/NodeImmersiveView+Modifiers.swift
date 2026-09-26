// Ported verbatim from Author (visionOS) — Third Party/NodeImmersiveView.
// Keep in step with Author; only the platform guard is ours.
#if os(visionOS)
//
// NodeImmersiveView+Modifiers.swift
//

import SwiftUI
import RealityKit

// MARK: -

public extension NodeImmersiveView {
    
    // MARK: -
    
    func constructorConnectionModelEntity(_ block: @escaping ConstructorConnectionModelEntityBlock) -> Self {
        var copy = self
        
        copy.constructorConnectionModelEntityBlock = block
        
        return copy
    }
    
    func attachmentIdentifiers(_ block: @escaping AttachmentIdentifiersBlock) -> Self {
        var copy = self
        
        copy.attachmentIdentifiersBlock = block
        
        return copy
    }
    
    func attachmentAnchorRule(_ block: @escaping AttachmentAnchorRuleBlock) -> Self {
        var copy = self
        
        copy.attachmentAnchorRuleBlock = block
        
        return copy
    }
    
    func shouldEnableNode(_ block: @escaping ShouldEnableNodeBlock) -> Self {
        var copy = self
        
        copy.shouldEnableNodeBlock = block
        
        return copy
    }
    
    func shouldMoveNode(_ block: @escaping ShouldMoveNodeBlock) -> Self {
        var copy = self
        
        copy.shouldMoveNodeBlock = block
        
        return copy
    }
    
    func shouldCheckMoveAnotherNodes(_ block: @escaping ShouldCheckMoveAnotherNodesBlock) -> Self {
        var copy = self
        
        copy.shouldCheckMoveAnotherNodesBlock = block
        
        return copy
    }
    
    func shouldMoveAnotherNode(_ block: @escaping ShouldMoveAnotherNodeBlock) -> Self {
        var copy = self
        
        copy.shouldMoveAnotherNodeBlock = block
        
        return copy
    }
    
    func shouldDrawConnectionForNode(_ block: @escaping ShouldDrawConnectionForNodeBlock) -> Self {
        var copy = self
        
        copy.shouldDrawConnectionForNodeBlock = block
        
        return copy
    }
    
    func shouldUseHoverNode(_ block: @escaping ShouldUseHoverNodeBlock) -> Self {
        var copy = self
        
        copy.shouldUseHoverNodeBlock = block
        
        return copy
    }
    
    func connectedNodesToNode(_ block: @escaping ConnectedNodesToNodeBlock) -> Self {
        var copy = self
        
        copy.connectedNodesToNodeBlock = block
        
        return copy
    }
    
    func nodeMaxWidth(_ block: @escaping NodeMaxWidthBlock) -> Self {
        var copy = self
        
        copy.nodeMaxWidthBlock = block
        
        return copy
    }
    
    func onMoveNode(_ block: @escaping OnMoveNodeBlock) -> Self {
        var copy = self
        
        copy.onMoveNodeBlock = block
        
        return copy
    }
    
    func onEndMoveNode(_ block: @escaping OnEndMoveNodeBlock) -> Self {
        var copy = self
        
        copy.onEndMoveNodeBlock = block
        
        return copy
    }
    
    func onTapNode(_ block: @escaping OnTapNodeBlock) -> Self {
        var copy = self
        
        copy.onTapNodeBlock = block
        
        return copy
    }
    
    func onLongTapNode(_ block: @escaping OnLongTapNodeBlock) -> Self {
        var copy = self
        
        copy.onLongTapNodeBlock = block
        
        return copy
    }
    
    func onPinchIn(_ block: @escaping OnPinchInBlock) -> Self {
        var copy = self
        
        copy.onPinchInBlock = block
        
        return copy
    }
    
    func onPinchOut(_ block: @escaping OnPinchOutBlock) -> Self {
        var copy = self
        
        copy.onPinchOutBlock = block
        
        return copy
    }
    
    func onUpdateNodeSizes(_ block: @escaping OnUpdateNodeSizesBlock) -> Self {
        var copy = self

        copy.onUpdateNodeSizesBlock = block

        return copy
    }

    // Origami addition (carry back to Author): constrain where a drag
    // can take a node — e.g. holding a timeline axis.
    func constrainMovedNode(_ block: @escaping ConstrainMovedNodeBlock) -> Self {
        var copy = self

        copy.constrainMovedNodeBlock = block

        return copy
    }
    
    func defaultMaxWidth(_ value: CGFloat) -> Self {
        var copy = self
        
        copy.defaultMaxWidth = value
        
        return copy
    }
    
    func defaultNodePosition(_ value: SIMD3<Float>) -> Self {
        var copy = self
        
        copy.defaultNodePosition = value
        
        return copy
    }

    func onSetupContent(_ block: @escaping (RealityViewContent) -> Void) -> Self {
        var copy = self

        copy.onSetupContentBlock = block

        return copy
    }

    func onTapEntity(_ block: @escaping (Entity) -> Bool) -> Self {
        var copy = self

        copy.onTapEntityBlock = block

        return copy
    }
}
#endif
