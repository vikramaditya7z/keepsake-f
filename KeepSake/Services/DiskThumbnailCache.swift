import Foundation
import AppKit
import CryptoKit

/// Service responsible for managing the persistent on-disk thumbnail cache for fast scrolling and instant browsing.
///
/// Thumbnails are stored in `~/Library/Caches/com.keepsake.KeepSake/Thumbnails/` as downsampled JPEGs.
/// This cache is strictly disposable and separate from persistent identity database and user photographs.
public final class DiskThumbnailCache: @unchecked Sendable {
    public static let shared = DiskThumbnailCache()

    private let fileManager = FileManager.default
    private let cacheDirectoryURL: URL
    private let ioQueue = DispatchQueue(label: "com.keepsake.DiskThumbnailCache", qos: .utility)

    public init(customCacheDirectoryURL: URL? = nil) {
        if let custom = customCacheDirectoryURL {
            self.cacheDirectoryURL = custom
        } else {
            let baseCaches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
            self.cacheDirectoryURL = baseCaches.appendingPathComponent("com.keepsake.KeepSake/Thumbnails", isDirectory: true)
        }
        createDirectoryIfNeeded()
    }

    private func createDirectoryIfNeeded() {
        if !fileManager.fileExists(atPath: cacheDirectoryURL.path) {
            try? fileManager.createDirectory(at: cacheDirectoryURL, withIntermediateDirectories: true, attributes: nil)
        }
    }

    /// Returns the absolute directory URL of the on-disk thumbnail cache.
    public var directoryURL: URL {
        return cacheDirectoryURL
    }

    /// Computes a deterministic cache file path for an original photo file URL.
    public func cacheFileURL(for photoURL: URL) -> URL {
        let hash = SHA256.hash(data: Data(photoURL.path.utf8))
        let hexString = hash.compactMap { String(format: "%02x", $0) }.joined()
        return cacheDirectoryURL.appendingPathComponent("\(hexString).jpg", isDirectory: false)
    }

    /// Loads a cached thumbnail image from disk if available.
    public func getThumbnail(for photoURL: URL) -> NSImage? {
        let fileURL = cacheFileURL(for: photoURL)
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
              let image = NSImage(data: data) else {
            return nil
        }
        return image
    }

    /// Saves a downsampled thumbnail image to disk.
    public func saveThumbnail(_ image: NSImage, for photoURL: URL) {
        let fileURL = cacheFileURL(for: photoURL)
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.82]) else {
            return
        }

        ioQueue.async { [fileManager, cacheDirectoryURL] in
            if !fileManager.fileExists(atPath: cacheDirectoryURL.path) {
                try? fileManager.createDirectory(at: cacheDirectoryURL, withIntermediateDirectories: true, attributes: nil)
            }
            try? jpegData.write(to: fileURL, options: .atomic)
        }
    }

    /// Measures the total size in bytes consumed by thumbnail cache files on disk.
    public func calculateCacheSize() -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: cacheDirectoryURL,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var totalSize: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  resourceValues.isRegularFile == true,
                  let size = resourceValues.fileSize else {
                continue
            }
            totalSize += Int64(size)
        }
        return totalSize
    }

    /// Formats the current disk cache size in human-readable units (e.g. "14.2 MB").
    public func formattedCacheSize() -> String {
        let bytes = calculateCacheSize()
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: bytes)
    }

    /// Safely purges only thumbnail cache files.
    ///
    /// GUARANTEE: Does not touch ~/Library/Application Support/KeepSake/library_index.json
    /// or any original user images.
    public func clearDiskCache() throws {
        // Enforce guard that we are strictly targeting the designated Thumbnails cache directory
        let path = cacheDirectoryURL.path
        guard (path.localizedCaseInsensitiveContains("caches") || path.localizedCaseInsensitiveContains("thumb"))
                && !path.contains("Application Support") else {
            throw NSError(domain: "DiskThumbnailCache", code: 1, userInfo: [NSLocalizedDescriptionKey: "Refusing to delete unsafe directory: \(path)"])
        }

        guard fileManager.fileExists(atPath: path) else { return }

        let contents = try fileManager.contentsOfDirectory(at: cacheDirectoryURL, includingPropertiesForKeys: nil)
        for item in contents {
            try? fileManager.removeItem(at: item)
        }
    }

    /// Reveals the thumbnail cache folder in Finder.
    public func revealInFinder() {
        createDirectoryIfNeeded()
        NSWorkspace.shared.activateFileViewerSelecting([cacheDirectoryURL])
    }
}
