// Ported verbatim from Author (visionOS) — Third Party/NodeImmersiveView.
// Keep in step with Author; only the platform guard is ours.
#if os(visionOS)
//
// NodeImmersiveView+Components.swift
//

import RealityKit

// MARK: -

public extension NodeImmersiveView {
    
    // MARK: -
    
    struct ItemComponent<T: Hashable>: Component {
        
        // MARK: -
        
        let item: T
    }
    
    struct ConnectionComponent<T: Hashable>: Component {
        
        // MARK: -
        
        let connection: T
    }
    
    struct MovableConnectionComponent: Component {
        // Empty.
    }
    
    struct StartPositionComponent: Component {

        // MARK: -

        let position: SIMD3<Float>
    }

    /// Caches the node's visual bounds, which only change when the entity is
    /// rebuilt; visualBounds(relativeTo:) walks the whole subtree, too slow
    /// to query for every node on every update.
    struct ExtentsComponent: Component {

        // MARK: -

        let extents: SIMD3<Float>
    }
    
    struct PinchComponent: Component {
        // Empty.
    }
    
    struct ShouldDrawConnectionComponent: Component {
        
        // MARK: -
        
        var id: Int
    }
    
    struct ConnectedNodeComponent: Component {
        
        // MARK: -
        
        var owners: [Int]
    }
    
    /*
    struct AttachmentComponent: Component {
        
        // MARK: -
        
        var owner: Entity
    }
    
    struct AnchorRuleComponent: Component {
        
        // MARK: -
        
        var anchorRule: AnchorRule
    }
     */
}
#endif
