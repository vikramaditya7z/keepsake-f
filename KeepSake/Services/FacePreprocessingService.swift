import Foundation
import CoreGraphics
import ImageIO

/// Service responsible for cropping and preprocessing detected face regions for recognition inference.
struct FacePreprocessingService: Sendable {
    enum PreprocessingError: LocalizedError {
        case unreadableImageSource(URL)
        case croppingFailed
        case emptyFaceRegion

        var errorDescription: String? {
            switch self {
            case .unreadableImageSource(let url):
                return "Failed to open image at \(url.path) for face cropping."
            case .croppingFailed:
                return "Failed to crop face region from the source image."
            case .emptyFaceRegion:
                return "The detected face bounding box is empty or degenerate."
            }
        }
    }

    /// Crops a face region from a CGImage given a normalized Vision bounding box.
    /// - Parameters:
    ///   - cgImage: Source full-resolution or display CGImage.
    ///   - normalizedBox: Vision bounding box in [0, 1] coordinate space (bottom-left origin).
    ///   - marginFactor: Additional padding around the face (default 0.15 for 15% contextual margin).
    /// - Returns: Cropped CGImage containing the face.
    func cropFace(
        from cgImage: CGImage,
        normalizedBox: CGRect,
        marginFactor: CGFloat = 0.15
    ) throws -> CGImage {
        guard normalizedBox.width > 0, normalizedBox.height > 0 else {
            throw PreprocessingError.emptyFaceRegion
        }

        let imgWidth = CGFloat(cgImage.width)
        let imgHeight = CGFloat(cgImage.height)

        // Convert Vision normalized coordinates (bottom-left) to pixel coordinates (top-left)
        let rawX = normalizedBox.minX * imgWidth
        let rawY = (1.0 - normalizedBox.minY - normalizedBox.height) * imgHeight
        let rawW = normalizedBox.width * imgWidth
        let rawH = normalizedBox.height * imgHeight

        // Apply contextual margin
        let marginX = rawW * marginFactor
        let marginY = rawH * marginFactor

        let cropX = max(0, rawX - marginX)
        let cropY = max(0, rawY - marginY)
        let cropW = min(imgWidth - cropX, rawW + (marginX * 2))
        let cropH = min(imgHeight - cropY, rawH + (marginY * 2))

        let pixelCropRect = CGRect(x: cropX, y: cropY, width: cropW, height: cropH).integral

        guard let cropped = cgImage.cropping(to: pixelCropRect) else {
            throw PreprocessingError.croppingFailed
        }

        return cropped
    }

    /// Loads an image from disk and crops the specified detected face respecting EXIF orientation.
    func cropFace(
        from imageURL: URL,
        normalizedBox: CGRect,
        marginFactor: CGFloat = 0.15
    ) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil) else {
            throw PreprocessingError.unreadableImageSource(imageURL)
        }

        var maxDim = 4096
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 4096
            let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 4096
            maxDim = max(width, height)
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDim
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw PreprocessingError.unreadableImageSource(imageURL)
        }

        return try cropFace(from: cgImage, normalizedBox: normalizedBox, marginFactor: marginFactor)
    }
}
