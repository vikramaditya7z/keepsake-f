import AppKit
import ImageIO

/// Service responsible for generating, managing, and caching downsampled photo thumbnails.
///
/// Features:
/// - Fast synchronous in-memory NSCache check (0ms display for visible items).
/// - Second-level persistent on-disk thumbnail cache (DiskThumbnailCache).
/// - Concurrent background decoding utilizing multi-core Apple Silicon without blocking the UI.
public final class ThumbnailLoader: @unchecked Sendable {
    public static let shared = ThumbnailLoader()

    private let memoryCache = NSCache<NSURL, NSImage>()
    private let diskCache: DiskThumbnailCache

    public init(diskCache: DiskThumbnailCache = .shared) {
        self.diskCache = diskCache
        memoryCache.countLimit = 1500
        memoryCache.totalCostLimit = 512 * 1024 * 1024 // 512 MB memory limit
    }

    /// Fast synchronous check for an in-memory cached thumbnail.
    /// Used by SwiftUI views to immediately show images on the first render frame without flashing placeholders.
    public func cachedImage(for url: URL) -> NSImage? {
        return memoryCache.object(forKey: url as NSURL)
    }

    /// Loads a downsampled thumbnail for a given file URL.
    ///
    /// Pipeline:
    /// 1. In-memory NSCache hit -> returns immediately.
    /// 2. DiskThumbnailCache hit -> reads downsampled JPEG from disk, caches in memory, returns immediately.
    /// 3. Disk & Memory miss -> decodes downsampled image from source file using CoreGraphics, saves to disk cache & memory cache.
    public func loadThumbnail(for url: URL, targetSize: CGSize = CGSize(width: 320, height: 320)) async -> NSImage? {
        if let memoryCached = cachedImage(for: url) {
            return memoryCached
        }

        // Check on-disk cache
        if let diskCached = diskCache.getThumbnail(for: url) {
            let cost = Int(diskCached.size.width * diskCached.size.height * 4)
            memoryCache.setObject(diskCached, forKey: url as NSURL, cost: cost)
            return diskCached
        }

        // Concurrent background decoding
        return await Task.detached(priority: .userInitiated) { [weak self, memoryCache = self.memoryCache, diskCache = self.diskCache] () -> NSImage? in
            // Retina display sharpness: 2x scale factor, with a minimum dimension of 640px
            let maxPixelSize = max(Int(max(targetSize.width, targetSize.height) * 2), 640)

            // Always decode thumbnail from full image data with orientation transform applied.
            // This prevents blurry and sideways thumbnails caused by unrotated embedded EXIF previews.
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
            ]

            guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let finalCGImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
                return nil
            }

            let nsImage = NSImage(cgImage: finalCGImage, size: NSSize(width: finalCGImage.width, height: finalCGImage.height))
            let cost = finalCGImage.bytesPerRow * finalCGImage.height
            memoryCache.setObject(nsImage, forKey: url as NSURL, cost: cost)
            diskCache.saveThumbnail(nsImage, for: url)

            return nsImage
        }.value
    }

    /// Loads full image for the detail viewer.
    public func loadFullImage(for url: URL, maxDimension: CGFloat = 2560) async -> NSImage? {
        return await Task.detached(priority: .userInitiated) { () -> NSImage? in
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
        }.value
    }

    /// Clears the in-memory cache.
    public func clearMemoryCache() {
        memoryCache.removeAllObjects()
    }

    /// Clears both in-memory cache and on-disk thumbnail cache.
    public func clearAllCaches() throws {
        clearMemoryCache()
        try diskCache.clearDiskCache()
    }
}
