// Ported verbatim from Author (visionOS) — Third Party/Extensions.swift
// (the engine's rasterizer and node-box builders). Keep in step with
// Author; only the platform guard and file name are ours.
#if os(visionOS)
//
// Tools.swift
//

import SwiftUI
import RealityKit

// MARK: -

extension UIView {
    
    // MARK: -
    
    static func sizeThatFits<T: View>(_ content: T, maxWidth: CGFloat) -> CGSize {
        let viewController = UIHostingController(rootView: content)
        
        let height = viewController.view.sizeThatFits(
            CGSize(
                width: maxWidth,
                height: .infinity
            )
        ).height
        
        let width = viewController.view.sizeThatFits(
            CGSize(
                width: .infinity,
                height: height
            )
        ).width
        
        return CGSize(
            width: width,
            height: height
        )
    }
}

extension UIImage {
    
    // MARK: -
    
    @MainActor static func image<T: View>(
        _ view: T,
        _ maxWidth: CGFloat
    ) -> UIImage? {
        let size = UIView.sizeThatFits(view, maxWidth: maxWidth)
        let renderer = ImageRenderer(content: view)
        
        renderer.scale = 4.0
        renderer.isOpaque = false
        renderer.proposedSize = ProposedViewSize(
            width: size.width,
            height: size.height
        )
        
        return renderer.uiImage
    }
}

// MARK: -

public extension ModelEntity {
    
    // MARK: -
    
    enum MaterialMode {
        
        // MARK: -
        
        case none
        case lighting
    }
    
    // MARK: -
    
    struct ConnectionOptions: OptionSet {
        
        // MARK: -
        
        public let rawValue: Int
        
        // MARK: -
        
        public static let lightweight = ConnectionOptions(rawValue: 1 << 1)
        
        // MARK: -
        
        public static let none: ConnectionOptions = []
        public static let standart: ConnectionOptions = [.lightweight]
        
        // MARK: -
        
        public init(rawValue: Int) {
            self.rawValue = rawValue
        }
    }
}

// MARK: -

extension ModelEntity {
    
    // MARK: -
    
    static func box(
        with plane: ModelEntity,
        backPlane: ModelEntity?,
        color: UIColor,
        depth: Float,
        margins: Float,
        opacity: Float,
        cornerRadius: Float,
        useBorder: Bool,
        borderColor: UIColor,
        materialMode: MaterialMode = .none
    ) -> (
        modelEntity: ModelEntity,
        collisionShape: ShapeResource
    ) {
        let extents = plane.visualBounds(relativeTo: nil).extents
        let delta = 2.0 * margins
        let width = extents.x + delta
        let height = extents.y + delta
        
        let mesh = MeshResource.generateBox(
            size: [
                width,
                height,
                depth
            ],
            majorCornerRadius: cornerRadius,
            minorCornerRadius: 0.0
        )
        
        let color = SimpleMaterial.BaseColor(tint: color)
        
        var materials = [any RealityKit.Material]()
        
        if materialMode == .lighting {
            var material = SimpleMaterial()
            
            material.color = color
            material.roughness = .float(1.0)
            material.metallic = .float(0.0)
            
            materials.append(material)
        } else {
            var material = UnlitMaterial()
            
            material.color = color
            
            materials.append(material)
        }
        
        let box = ModelEntity(
            mesh: mesh,
            materials: materials
        )
        
        plane.position = [0.0, 0.0, 0.5 * depth + 0.001]
        
        box.addChild(plane)
        
        if let backPlane {
            backPlane.position = [0.0, 0.0, -0.5 * depth - 0.001]
            backPlane.orientation = simd_quatf(angle: .pi, axis: [0.0, 1.0, 0.0])
            
            box.addChild(backPlane)
        }
        
        let collisionShape = ShapeResource.generateBox(
            width: width,
            height: height,
            depth: depth
        )
        
        if useBorder {
            let delta: Float = 0.002
            let deltaDepth: Float = 0.0006
            
            let mesh = MeshResource.generateBox(
                size: [
                    width + 2.0 * delta,
                    height + 2.0 * delta,
                    depth - 2.0 * deltaDepth,
                ],
                majorCornerRadius: cornerRadius + delta,
                minorCornerRadius: 0.0
            )
            
            let color = SimpleMaterial.BaseColor(tint: borderColor)
            
            var materials = [any RealityKit.Material]()
            
            if materialMode == .lighting {
                var material = SimpleMaterial()
                
                material.color = color
                material.roughness = .float(1.0)
                material.metallic = .float(0.0)
                
                materials.append(material)
            } else {
                var material = UnlitMaterial()
                
                material.color = color
                
                materials.append(material)
            }
            
            let border = ModelEntity(
                mesh: mesh,
                materials: materials
            )
            
            box.addChild(border)
        }
        
        box.components.set(OpacityComponent(opacity: opacity))
        
        return (box, collisionShape)
    }
    
    static func connection(
        size: Float,
        color: Color,
        connectionOptions: ConnectionOptions,
        materialMode: MaterialMode
    ) -> ModelEntity {
        let mesh = MeshResource.generateBox(size: [1.0, size, size])
        let color = SimpleMaterial.BaseColor(tint: UIColor(color))
        
        var materials = [any RealityKit.Material]()
        
        if materialMode == .lighting {
            var material = SimpleMaterial()
            
            material.color = color
            material.roughness = .float(0.8)
            material.metallic = .float(0.0)
            
            materials.append(material)
        } else {
            var material = UnlitMaterial()
            
            material.color = color
            
            materials.append(material)
        }
        
        let modelEntity = ModelEntity(
            mesh: mesh,
            materials: materials
        )
        
        modelEntity.components[OpacityComponent.self] = OpacityComponent(
            opacity: connectionOptions.contains(.lightweight) ? 0.2 : 0.4
        )
        
        return modelEntity
    }
}

// MARK: -

extension View {
    
    // MARK: -
    
    func onNotification(_ name: Notification.Name, perform action: @escaping (Notification) -> Void) -> some View {
        modifier(NotificationModifier(name: name, action: action))
    }
}

// MARK: -

struct NotificationModifier: ViewModifier {
    
    // MARK: -
    
    let name: Notification.Name
    
    let action: (Notification) -> Void
    
    // MARK: -
    
    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: name)) { notification in
                action(notification)
            }
    }
}

// MARK: -

extension Array {
    
    // MARK: -
    
    func indicesWhere(_ predicate: (Element) throws -> Bool) rethrows -> [Int] {
        if #available(visionOS 2.0, *) {
            let indices = try indices(where: predicate)
            
            return indices.ranges.flatMap { $0.indices }
        }
        
        var indices = [Int]()
        
        for i in 0..<count {
            if try predicate(self[i]) {
                indices.append(i)
            }
        }
        
        return indices
    }
}
#endif
