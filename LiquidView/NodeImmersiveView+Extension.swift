// Ported verbatim from Author (visionOS) — Third Party/NodeImmersiveView.
// Keep in step with Author; only the platform guard is ours.
#if os(visionOS)
//
// NodeImmersiveView+Extension.swift
//

import SwiftUI
import RealityKit

// MARK: -

extension ModelEntity {
    
    // MARK: -
    
    static func texturedPlane(
        with image: UIImage,
        ratio: Float,
        isDebug: Bool = false
    ) -> ModelEntity? {
        let options = TextureResource.CreateOptions(semantic: .color)
        
        guard let cgImage = image.cgImage else {
            return nil
        }
        
        var resource: TextureResource?
        
        if #available(visionOS 2.0, *) {
            resource = try? TextureResource(image: cgImage, options: options)
        } else {
            resource = try? TextureResource.generate(from: cgImage, withName: "texture", options: options)
        }
        
        guard let resource else {
            return nil
        }
        
        let mesh = MeshResource.generatePlane(
            width: ratio * Float(image.size.width),
            height: ratio * Float(image.size.height)
        )
        
        var materials = [any RealityKit.Material]()
        
        if isDebug {
            let texture = MaterialParameters.Texture(resource)
            let color = SimpleMaterial.BaseColor(texture: texture)
            
            var material = SimpleMaterial()
            
            material.color = color
            
            materials.append(material)
        } else {
            let texture = PhysicallyBasedMaterial.Texture(resource)
            let baseColor = PhysicallyBasedMaterial.BaseColor(texture: texture)
            
            var material = PhysicallyBasedMaterial()
            
            material.baseColor = baseColor
            material.opacityThreshold = 0.08
            material.blending = .transparent(opacity: 1.0)
            
            materials.append(material)
        }
        
        return ModelEntity(
            mesh: mesh,
            materials: materials
        )
    }
}
#endif
