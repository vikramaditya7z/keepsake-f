import Foundation
import AppKit

/// In-memory and on-disk caching loader for cropped face thumbnails.
///
/// Features:
/// - Fast synchronous in-memory NSCache check (0ms for visible items).
/// - Persistent on-disk face-crop cache via DiskThumbnailCache to eliminate redundant source-image decodes.
/// - Downsampled decoding via ImageIO (bounds source image decode to avoid multi-gigabyte RAM spikes).
/// - Responds to macOS system memory pressure notifications by clearing memory cache.
/// - Cooperative task cancellation support.
final class FaceCropLoader: @unchecked Sendable {
    static let shared = FaceCropLoader()

    private let cache = NSCache<NSString, NSImage>()
    private let diskCache: DiskThumbnailCache
    private let preprocessor = FacePreprocessingService()
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    init(diskCache: DiskThumbnailCache = .shared) {
        self.diskCache = diskCache
        cache.countLimit = 500
        cache.totalCostLimit = 64 * 1024 * 1024 // 64 MB memory limit

        setupMemoryPressureListener()
    }

    deinit {
        memoryPressureSource?.cancel()
    }

    private func setupMemoryPressureListener() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: DispatchQueue.global(qos: .utility))
        source.setEventHandler { [weak self] in
            self?.clearCache()
        }
        source.resume()
        self.memoryPressureSource = source
    }

    /// Fast synchronous check for an in-memory cached face crop.
    func cachedImage(for faceId: UUID) -> NSImage? {
        let key = "face_\(faceId.uuidString)" as NSString
        return cache.object(forKey: key)
    }

    /// Loads and crops a face image using normalized bounding box and context padding.
    ///
    /// Pipeline:
    /// 1. In-memory NSCache hit -> returns immediately.
    /// 2. Disk cache hit -> returns downsampled JPEG, caches in memory.
    /// 3. Disk & Memory miss -> decodes downsampled image via ImageIO, crops face, saves to disk & memory.
    func loadFaceCrop(
        faceId: UUID,
        photoURL: URL,
        boundingBox: CGRect,
        targetSize: CGFloat = 220
    ) async -> NSImage? {
        let key = "face_\(faceId.uuidString)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }

        // Check persistent on-disk face crop cache
        if let diskCached = diskCache.getFaceCrop(forFaceId: faceId) {
            let cost = Int(diskCached.size.width * diskCached.size.height * 4)
            cache.setObject(diskCached, forKey: key, cost: cost)
            return diskCached
        }

        guard !Task.isCancelled else { return nil }

        // Perform downsampled crop extraction
        let croppedCG: CGImage? = autoreleasepool {
            try? preprocessor.cropThumbnailFace(
                from: photoURL,
                normalizedBox: boundingBox,
                targetDisplaySize: targetSize,
                marginFactor: 0.15
            )
        }

        guard let validCG = croppedCG else { return nil }
        guard !Task.isCancelled else { return nil }

        let nsImage = NSImage(cgImage: validCG, size: NSSize(width: validCG.width, height: validCG.height))
        let cost = validCG.width * validCG.height * 4
        cache.setObject(nsImage, forKey: key, cost: cost)
        diskCache.saveFaceCrop(nsImage, forFaceId: faceId)

        return nsImage
    }

    /// Clears the memory cache.
    func clearCache() {
        cache.removeAllObjects()
    }
}
