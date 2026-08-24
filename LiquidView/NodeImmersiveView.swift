// Ported verbatim from Author (visionOS) — Third Party/NodeImmersiveView.
// Keep in step with Author; only the platform guard is ours.
#if os(visionOS)
//
// NodeImmersiveView.swift
//

import SwiftUI
import RealityKit

// MARK: -

public protocol ItemProtocol: Hashable, Identifiable {

    // MARK: -

    var isAttachmentsEnabled: Bool { get }

    var position: SIMD3<Float>? { get set }

    /// True when both values render the same node image, ignoring state the
    /// canvas can apply in place (like position). Gates the expensive
    /// rasterize-and-rebuild path when a node changes.
    func isVisuallyEqual(to other: Self) -> Bool
}

// MARK: -

public extension ItemProtocol {

    // MARK: -

    func isVisuallyEqual(to other: Self) -> Bool {
        return self == other
    }
}

// MARK: -

public struct AnchorRule {
    
    // MARK: -
    
    public static var empty: AnchorRule {
        return AnchorRule(
            anchor: .zero,
            offset: .zero
        )
    }
    
    // MARK: -
    
    public var anchor: SIMD3<Float>
    public var offset: SIMD3<Float>
}

// MARK: -

public struct NodeImmersiveView<
    Items: RandomAccessCollection,
    C: View,
    A: View
>: View where Items.Element: ItemProtocol {
    
    // MARK: -
    
    let items: Items
    
    let connectionsCount: Int
    
    let constructorViewBlock: ConstructorViewBlock
    
    let constructorAttachmentBlock: ConstructorAttachmentBlock
    
    let constructorNodeModelEntityBlock: ConstructorNodeModelEntityBlock
    
    // MARK: -
    
    @State var content: RealityViewContent?
    
    @State var attachments: RealityViewAttachments?
    
    // MARK: -
    
    @State var magnification: CGFloat = 1.0
    
    @State var hasPinchIn = false
    @State var hasPinchOut = false
    
    // MARK: -
    
    var constructorConnectionModelEntityBlock: ConstructorConnectionModelEntityBlock?
    
    var attachmentIdentifiersBlock: AttachmentIdentifiersBlock?
    
    var attachmentAnchorRuleBlock: AttachmentAnchorRuleBlock?
    
    var shouldEnableNodeBlock: ShouldEnableNodeBlock?
    
    var shouldMoveNodeBlock: ShouldMoveNodeBlock?
    
    var shouldCheckMoveAnotherNodesBlock: ShouldCheckMoveAnotherNodesBlock?
    
    var shouldMoveAnotherNodeBlock: ShouldMoveAnotherNodeBlock?
    
    var shouldDrawConnectionForNodeBlock: ShouldDrawConnectionForNodeBlock?
    
    var shouldUseHoverNodeBlock: ShouldUseHoverNodeBlock?
    
    var connectedNodesToNodeBlock: ConnectedNodesToNodeBlock?
    
    var nodeMaxWidthBlock: NodeMaxWidthBlock?
    
    var onMoveNodeBlock: OnMoveNodeBlock?
    
    var onEndMoveNodeBlock: OnEndMoveNodeBlock?
    
    var onTapNodeBlock: OnTapNodeBlock?
    
    var onLongTapNodeBlock: OnLongTapNodeBlock?
    
    var onPinchInBlock: OnPinchInBlock?
    
    var onPinchOutBlock: OnPinchOutBlock?
    
    var onUpdateNodeSizesBlock: OnUpdateNodeSizesBlock?

    /// Handed the RealityView content once, in the make closure, so a caller
    /// can add its own entities (e.g. the forearm arm menu).
    var onSetupContentBlock: ((RealityViewContent) -> Void)?

    /// Called first on a single tap; returning true means the caller handled
    /// the tapped entity (e.g. an arm-menu chip) and node handling is skipped.
    var onTapEntityBlock: ((Entity) -> Bool)?

    var defaultMaxWidth: CGFloat = 200.0
    
    var defaultNodePosition: SIMD3<Float> = [0.0, 1.0, -1.0]
    
    // MARK: -
    
    public init(
        _ items: Items,
        _ connectionsCount: Int,
        @ViewBuilder constructorView: @escaping ConstructorViewBlock,
        @ViewBuilder constructorAttachment: @escaping ConstructorAttachmentBlock,
        constructorNodeModelEntity: @escaping ConstructorNodeModelEntityBlock
    ) {
        self.items = items
        self.connectionsCount = connectionsCount
        self.constructorViewBlock = constructorView
        self.constructorAttachmentBlock = constructorAttachment
        self.constructorNodeModelEntityBlock = constructorNodeModelEntity
    }
    
    // MARK: -
    
    public var body: some View {
        RealityView { content, attachments in
            self.content = content
            self.attachments = attachments
            
            setupPinchArea()

            onSetupContentBlock?(content)

            update(content, attachments)
        } update: { content, attachments in
            update(content, attachments)
        } attachments: {
            ForEach(items) { item in
                let identifiers = {
                    if let result = attachmentIdentifiersBlock?(item), !result.isEmpty {
                        return result
                    }
                    
                    return [item.id]
                }()
                
                ForEach(identifiers, id: \.self) { identifier in
                    Attachment(id: identifier) {
                        constructorAttachmentBlock(identifier, item)
                    }
                }
            }
        }
        .gesture(tapGesture())
        .gesture(doubleTapGesture())
        .gesture(tripleTapGesture())
        .gesture(longTapGesture())
        .gesture(dragGesture())
        .gesture(pinchGesture())
        .onAppear {
            ShouldDrawConnectionComponent.registerComponent()
            ConnectedNodeComponent.registerComponent()
            MovableConnectionComponent.registerComponent()
            ExtentsComponent.registerComponent()
            
            MovableConnectionsSystem.registerSystem()
        }
    }
}
#endif
