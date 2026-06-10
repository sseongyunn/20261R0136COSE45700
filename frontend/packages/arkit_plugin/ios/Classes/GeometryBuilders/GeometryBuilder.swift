import ARKit
import Foundation

func createGeometry(_ arguments: [String: Any]?, withDevice device: MTLDevice?) -> SCNGeometry? {
    if let arguments = arguments {
        var geometry: SCNGeometry?
        let dartType = arguments["dartType"] as! String

        switch dartType {
        case "ARKitSphere":
            geometry = createSphere(arguments)
        case "ARKitPlane":
            geometry = createPlane(arguments)
        case "ARKitText":
            geometry = createText(arguments)
        case "ARKitBox":
            geometry = createBox(arguments)
        case "ARKitLine":
            geometry = createLine(arguments)
        case "ARKitCylinder":
            geometry = createCylinder(arguments)
        case "ARKitCone":
            geometry = createCone(arguments)
        case "ARKitPyramid":
            geometry = createPyramid(arguments)
        case "ARKitTube":
            geometry = createTube(arguments)
        case "ARKitTorus":
            geometry = createTorus(arguments)
        case "ARKitCapsule":
            geometry = createCapsule(arguments)
        case "ARKitFace":
            #if !DISABLE_TRUEDEPTH_API
                geometry = createFace(device)
            #else
                // error
            #endif
        default:
            // error
            break
        }

        if let materials = arguments["materials"] as? [[String: Any]] {
            geometry?.materials = parseMaterials(materials)
        }

        return geometry
    } else {
        return nil
    }
}

func parseMaterials(_ array: [[String: Any]]) -> [SCNMaterial] {
    return array.map { parseMaterial($0) }
}

private func parseMaterial(_ dict: [String: Any]) -> SCNMaterial {
    let material = SCNMaterial()

    material.shininess = CGFloat(dict["shininess"] as! Double)
    material.transparency = CGFloat(dict["transparency"] as! Double)
    material.lightingModel = parseLightingModel(dict["lightingModelName"] as? Int)
    material.fillMode = SCNFillMode(rawValue: UInt(dict["fillMode"] as! Int))!
    material.cullMode = SCNCullMode(rawValue: dict["cullMode"] as! Int)!
    material.transparencyMode = SCNTransparencyMode(rawValue: dict["transparencyMode"] as! Int)!
    material.locksAmbientWithDiffuse = dict["locksAmbientWithDiffuse"] as! Bool
    material.writesToDepthBuffer = dict["writesToDepthBuffer"] as! Bool
    material.colorBufferWriteMask = parseColorBufferWriteMask(dict["colorBufferWriteMask"] as? Int)
    material.blendMode = SCNBlendMode(rawValue: dict["blendMode"] as! Int)!
    material.isDoubleSided = dict["doubleSided"] as! Bool

    assignMaterialProperty(material.diffuse, from: dict["diffuse"])
    assignMaterialProperty(material.ambient, from: dict["ambient"])
    assignMaterialProperty(material.specular, from: dict["specular"])
    assignMaterialProperty(material.emission, from: dict["emission"])
    assignMaterialProperty(material.transparent, from: dict["transparent"])
    assignMaterialProperty(material.reflective, from: dict["reflective"])
    assignMaterialProperty(material.multiply, from: dict["multiply"])
    assignMaterialProperty(material.normal, from: dict["normal"])
    assignMaterialProperty(material.displacement, from: dict["displacement"])
    assignMaterialProperty(material.ambientOcclusion, from: dict["ambientOcclusion"])
    assignMaterialProperty(material.selfIllumination, from: dict["selfIllumination"])
    assignMaterialProperty(material.metalness, from: dict["metalness"])
    assignMaterialProperty(material.roughness, from: dict["roughness"])

    return material
}

private func parseLightingModel(_ mode: Int?) -> SCNMaterial.LightingModel {
    switch mode {
    case 0:
        return .phong
    case 1:
        return .blinn
    case 2:
        return .lambert
    case 3:
        return .constant
    case 4:
        return .physicallyBased
    case 5:
        if #available(iOS 13.0, *) {
            return .shadowOnly
        } else {
            // error
            return .blinn
        }
    default:
        return .blinn
    }
}

private func parseColorBufferWriteMask(_ mode: Int?) -> SCNColorMask {
    switch mode {
    case 0:
        return .init()
    case 8:
        return .red
    case 4:
        return .green
    case 2:
        return .blue
    case 1:
        return .alpha
    case 15:
        return .all
    default:
        return .all
    }
}

private func parsePropertyContents(_ dict: Any?) -> Any? {
    guard let dict = dict as? [String: Any] else {
        return nil
    }

    if let imageName = dict["image"] as? String {
        return getImageByName(imageName)
    }
    if let color = dict["color"] as? Int {
        return UIColor(rgb: UInt(color))
    }
    if let value = dict["value"] as? Double {
        return value
    }
    if let width = dict["width"] as? Int,
       let height = dict["height"] as? Int,
       let autoplay = dict["autoplay"] as? Bool,
       let id = dict["id"] as? String
    {
        var videoNode: SKVideoNode
        if let videoFilename = dict["filename"] as? String {
            videoNode = SKVideoNode(fileNamed: videoFilename)
        } else if let url = dict["url"] as? String,
                  let videoUrl = URL(string: url)
        {
            videoNode = SKVideoNode(url: videoUrl)
        } else {
            return nil
        }
        VideoArkitPlugin.nodes[id] = videoNode
        if autoplay {
            videoNode.play()
        }

        let skScene = SKScene(size: CGSize(width: width, height: height))
        skScene.addChild(videoNode)

        videoNode.position = CGPoint(x: skScene.size.width / 2, y: skScene.size.height / 2)
        videoNode.size = skScene.size
        return skScene
    }
    return nil
}

private func assignMaterialProperty(_ property: SCNMaterialProperty, from value: Any?) {
    guard let dict = value as? [String: Any] else {
        property.contents = nil
        return
    }

    if let imageName = dict["image"] as? String {
        if let image = getImageByName(imageName) {
            property.contents = image
            return
        }
        if let url = URL(string: imageName),
           url.scheme == "http" || url.scheme == "https"
        {
            fetchNetworkImageIfNeeded(url) { image in
                guard let image = image else { return }
                DispatchQueue.main.async {
                    property.contents = image
                }
            }
        }
        return
    }

    property.contents = parsePropertyContents(dict)
}
