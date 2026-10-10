import AppKit
import ImageIO

/// Actor responsible for generating and caching downsampled photo thumbnails.
actor ThumbnailLoader {
    static let shared = ThumbnailLoader()

    private let cache = NSCache<NSURL, NSImage>()

    init() {
        cache.countLimit = 600
        cache.totalCostLimit = 128 * 1024 * 1024 // ~128 MB max memory
    }

    /// Loads a downsampled thumbnail for a given file URL.
    func loadThumbnail(for url: URL, targetSize: CGSize = CGSize(width: 320, height: 320)) -> NSImage? {
        if let cached = cache.object(forKey: url as NSURL) {
            return cached
        }

        let maxPixelSize = max(targetSize.width, targetSize.height) * 2 // 2x for Retina display sharpness
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixelSize)
        ]

        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
            return nil
        }

        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        let cost = cgImage.bytesPerRow * cgImage.height
        cache.setObject(nsImage, forKey: url as NSURL, cost: cost)
        return nsImage
    }

    /// Loads full image for the detail viewer.
    func loadFullImage(for url: URL, maxDimension: CGFloat = 2560) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxDimension)
        ]

        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
            return nil
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
