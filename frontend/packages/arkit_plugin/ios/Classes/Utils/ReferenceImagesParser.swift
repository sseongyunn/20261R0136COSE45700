import ARKit
import Foundation

func parseReferenceImagesSet(_ images: [[String: Any]]) -> Set<ARReferenceImage> {
    let conv = images.compactMap { parseReferenceImage($0) }
    return Set(conv)
}

func parseReferenceImage(_ dict: [String: Any]) -> ARReferenceImage? {
    guard let physicalWidth = dict["physicalWidth"] as? Double else {
        debugPrint("ARKitReferenceImage: missing or invalid physicalWidth: \(dict)")
        return nil
    }
    guard let name = dict["name"] as? String else {
        debugPrint("ARKitReferenceImage: missing or invalid name: \(dict)")
        return nil
    }
    guard let image = getImageByName(name) else {
        debugPrint("ARKitReferenceImage: failed to load image for name: \(name)")
        return nil
    }
    guard let cgImage = image.cgImage else {
        debugPrint("ARKitReferenceImage: loaded image has no CGImage for name: \(name)")
        return nil
    }

    let referenceImage = ARReferenceImage(cgImage, orientation: CGImagePropertyOrientation.up, physicalWidth: CGFloat(physicalWidth))
    referenceImage.name = name
    return referenceImage
}
