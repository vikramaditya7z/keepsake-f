import Foundation
import CoreGraphics
import ImageIO

/// Service responsible for cropping and preprocessing detected face regions for recognition inference.
/// Supports both contextual margin bounding-box cropping and 5-point facial landmark Umeyama alignment.
struct FacePreprocessingService: Sendable {
    enum PreprocessingError: LocalizedError {
        case unreadableImageSource(URL)
        case croppingFailed
        case emptyFaceRegion
        case degenerateLandmarks
        case alignmentFailed

        var errorDescription: String? {
            switch self {
            case .unreadableImageSource(let url):
                return "Failed to open image at \(url.path) for face cropping."
            case .croppingFailed:
                return "Failed to crop face region from the source image."
            case .emptyFaceRegion:
                return "The detected face bounding box is empty or degenerate."
            case .degenerateLandmarks:
                return "The facial landmarks are degenerate or collinear for affine alignment."
            case .alignmentFailed:
                return "Failed to render landmark-aligned face image."
            }
        }
    }

    // Standard 5-point template coordinates for ArcFace/InsightFace (112x112 canvas, bottom-left origin)
    // Converted from canonical top-down: (x, 112 - y)
    // Left eye (38.2946, 51.6963) -> (38.2946, 60.3037)
    // Right eye (73.5318, 51.6963) -> (73.5318, 60.3037)
    // Nose (56.0252, 71.7366) -> (56.0252, 40.2634)
    // Left mouth (41.5493, 92.3655) -> (41.5493, 19.6345)
    // Right mouth (70.7299, 92.3655) -> (70.7299, 19.6345)
    static let targetTemplatePoints: [CGPoint] = [
        CGPoint(x: 38.2946, y: 112.0 - 51.6963),
        CGPoint(x: 73.5318, y: 112.0 - 51.6963),
        CGPoint(x: 56.0252, y: 112.0 - 71.7366),
        CGPoint(x: 41.5493, y: 112.0 - 92.3655),
        CGPoint(x: 70.7299, y: 112.0 - 92.3655)
    ]

    /// Performs 5-point facial landmark alignment via least-squares Umeyama similarity transform to 112x112 canvas.
    /// - Parameters:
    ///   - cgImage: Source image (assumed properly oriented).
    ///   - normalizedBox: Vision face bounding box in normalized [0, 1] coordinates.
    ///   - landmarks: 5 canonical facial landmark points in normalized box coordinates.
    /// - Returns: Aligned 112x112 CGImage ready for MobileFaceNet/ArcFace inference.
    func alignFace(
        from cgImage: CGImage,
        normalizedBox: CGRect,
        landmarks: FaceLandmarks5Point
    ) throws -> CGImage {
        guard normalizedBox.width > 0, normalizedBox.height > 0 else {
            throw PreprocessingError.emptyFaceRegion
        }

        let imgW = CGFloat(cgImage.width)
        let imgH = CGFloat(cgImage.height)
        let box = normalizedBox

        // Convert 5 normalized box points to image pixel coordinates (bottom-left origin)
        let srcPts: [CGPoint] = [
            landmarks.leftEye,
            landmarks.rightEye,
            landmarks.nose,
            landmarks.leftMouth,
            landmarks.rightMouth
        ].map { pt in
            CGPoint(
                x: (box.origin.x + pt.x * box.width) * imgW,
                y: (box.origin.y + pt.y * box.height) * imgH
            )
        }

        let dstPts = Self.targetTemplatePoints
        let n = CGFloat(srcPts.count)
        let srcMean = CGPoint(x: srcPts.map(\.x).reduce(0, +) / n, y: srcPts.map(\.y).reduce(0, +) / n)
        let dstMean = CGPoint(x: dstPts.map(\.x).reduce(0, +) / n, y: dstPts.map(\.y).reduce(0, +) / n)

        var varSrc: CGFloat = 0
        var sumA: CGFloat = 0
        var sumB: CGFloat = 0
        for k in 0..<srcPts.count {
            let dxSrc = srcPts[k].x - srcMean.x
            let dySrc = srcPts[k].y - srcMean.y
            let dxDst = dstPts[k].x - dstMean.x
            let dyDst = dstPts[k].y - dstMean.y
            varSrc += dxSrc * dxSrc + dySrc * dySrc
            sumA += dxSrc * dxDst + dySrc * dyDst
            sumB += dxSrc * dyDst - dySrc * dxDst
        }

        guard varSrc > 1e-4 else {
            throw PreprocessingError.degenerateLandmarks
        }

        let a = sumA / varSrc
        let b = sumB / varSrc
        let tx = dstMean.x - (a * srcMean.x - b * srcMean.y)
        let ty = dstMean.y - (b * srcMean.x + a * srcMean.y)

        // Validate scale is positive and reasonable (reject extreme scale collapses)
        let scale = sqrt(a * a + b * b)
        guard scale > 1e-4 && scale < 100.0 else {
            throw PreprocessingError.alignmentFailed
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: 112,
            height: 112,
            bitsPerComponent: 8,
            bytesPerRow: 112 * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw PreprocessingError.alignmentFailed
        }

        ctx.interpolationQuality = .high
        let transform = CGAffineTransform(a: a, b: b, c: -b, d: a, tx: tx, ty: ty)
        ctx.concatenate(transform)
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: imgW, height: imgH))

        guard let alignedImage = ctx.makeImage() else {
            throw PreprocessingError.alignmentFailed
        }
        return alignedImage
    }

    /// Crops a face region from a CGImage given a normalized Vision bounding box with contextual padding.
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

    /// Primary entry point: Attempts landmark alignment first; gracefully falls back to bounding-box crop.
    func cropOrAlignFace(
        from cgImage: CGImage,
        normalizedBox: CGRect,
        landmarks: FaceLandmarks5Point?,
        marginFactor: CGFloat = 0.15
    ) throws -> CGImage {
        if let lm = landmarks, let aligned = try? alignFace(from: cgImage, normalizedBox: normalizedBox, landmarks: lm) {
            return aligned
        }
        return try cropFace(from: cgImage, normalizedBox: normalizedBox, marginFactor: marginFactor)
    }

    /// Loads an image from disk respecting EXIF orientation.
    /// Can be decoded once and reused for detecting faces and extracting multiple face crops.
    /// - Parameter maxDimension: Optional max pixel size to bound decoding dimensions and reduce RAM usage.
    func loadOrientedImage(from imageURL: URL, maxDimension: Int? = nil) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil) else {
            throw PreprocessingError.unreadableImageSource(imageURL)
        }

        var maxDim = 4096
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 4096
            let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 4096
            maxDim = max(width, height)
        }

        let effectiveMaxDim: Int
        if let targetMax = maxDimension, targetMax > 0 {
            effectiveMaxDim = min(maxDim, targetMax)
        } else {
            effectiveMaxDim = maxDim
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: effectiveMaxDim
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw PreprocessingError.unreadableImageSource(imageURL)
        }

        return cgImage
    }

    /// Loads an image downsampled appropriately for face crop thumbnail display, avoiding full-resolution decodes.
    /// - Parameters:
    ///   - imageURL: Path to source photo on disk.
    ///   - normalizedBox: Vision normalized bounding box [0, 1].
    ///   - targetDisplaySize: Desired thumbnail display pixel dimension (e.g. 220 for a 110pt Retina avatar).
    ///   - marginFactor: Contextual padding around face box.
    func cropThumbnailFace(
        from imageURL: URL,
        normalizedBox: CGRect,
        targetDisplaySize: CGFloat = 220,
        marginFactor: CGFloat = 0.15
    ) throws -> CGImage {
        guard normalizedBox.width > 0, normalizedBox.height > 0 else {
            throw PreprocessingError.emptyFaceRegion
        }

        // Calculate appropriate source decode dimension:
        // A face with relative dimension max(w, h) needs targetDisplaySize pixels.
        // Clamp to safe range [640, 1920] to guarantee crisp Retina rendering while never decoding 4000-8000px originals.
        let faceBoxMax = max(normalizedBox.width, normalizedBox.height)
        let estimatedDim = Int(ceil(targetDisplaySize / max(faceBoxMax, 0.08)))
        let downsampleMaxDim = min(max(estimatedDim, 640), 1920)

        let cgImage = try autoreleasepool {
            try loadOrientedImage(from: imageURL, maxDimension: downsampleMaxDim)
        }
        return try cropFace(from: cgImage, normalizedBox: normalizedBox, marginFactor: marginFactor)
    }

    /// Loads an image from disk respecting EXIF orientation and crops or aligns the specified detected face.
    func cropOrAlignFace(
        from imageURL: URL,
        normalizedBox: CGRect,
        landmarks: FaceLandmarks5Point?,
        marginFactor: CGFloat = 0.15
    ) throws -> CGImage {
        let cgImage = try loadOrientedImage(from: imageURL)
        return try cropOrAlignFace(from: cgImage, normalizedBox: normalizedBox, landmarks: landmarks, marginFactor: marginFactor)
    }

    /// Backward-compatible overload loading an image from disk and cropping the specified face bounding box.
    func cropFace(
        from imageURL: URL,
        normalizedBox: CGRect,
        marginFactor: CGFloat = 0.15
    ) throws -> CGImage {
        return try cropOrAlignFace(from: imageURL, normalizedBox: normalizedBox, landmarks: nil, marginFactor: marginFactor)
    }
}
