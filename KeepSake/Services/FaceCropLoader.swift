import Foundation
import AppKit

/// In-memory caching loader for cropped face thumbnails.
final class FaceCropLoader: @unchecked Sendable {
    static let shared = FaceCropLoader()

    private let cache = NSCache<NSString, NSImage>()
    private let preprocessor = FacePreprocessingService()

    init() {
        cache.countLimit = 1000
        cache.totalCostLimit = 100 * 1024 * 1024 // 100 MB
    }

    /// Loads and crops a face image using normalized bounding box and context padding.
    func loadFaceCrop(faceId: UUID, photoURL: URL, boundingBox: CGRect) async -> NSImage? {
        let key = "face_\(faceId.uuidString)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }

        return await Task.detached(priority: .userInitiated) { [preprocessor = self.preprocessor, cache = self.cache] () -> NSImage? in
            guard let croppedCG = try? preprocessor.cropFace(
                from: photoURL,
                normalizedBox: boundingBox,
                marginFactor: 0.15
            ) else {
                return nil
            }

            let nsImage = NSImage(cgImage: croppedCG, size: NSSize(width: croppedCG.width, height: croppedCG.height))
            let cost = croppedCG.width * croppedCG.height * 4
            cache.setObject(nsImage, forKey: key, cost: cost)
            return nsImage
        }.value
    }

    /// Clears the memory cache.
    func clearCache() {
        cache.removeAllObjects()
    }
}
