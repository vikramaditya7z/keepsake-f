import Foundation
import CoreGraphics

/// Helper for converting between Apple Vision normalized coordinates (bottom-left origin)
/// and SwiftUI / AppKit view coordinates (top-left origin).
enum CoordinateConverter {
    /// Computes the centered aspect-fit destination rectangle of an image within a container.
    static func aspectFitRect(for imageSize: CGSize, in containerSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              containerSize.width > 0, containerSize.height > 0 else {
            return .zero
        }

        let imageAspect = imageSize.width / imageSize.height
        let containerAspect = containerSize.width / containerSize.height

        let renderSize: CGSize
        if imageAspect > containerAspect {
            // Limited by container width
            renderSize = CGSize(
                width: containerSize.width,
                height: containerSize.width / imageAspect
            )
        } else {
            // Limited by container height
            renderSize = CGSize(
                width: containerSize.height * imageAspect,
                height: containerSize.height
            )
        }

        let originX = (containerSize.width - renderSize.width) / 2.0
        let originY = (containerSize.height - renderSize.height) / 2.0

        return CGRect(origin: CGPoint(x: originX, y: originY), size: renderSize)
    }

    /// Converts a Vision normalized bounding box to view coordinates within a fitted image container.
    /// - Parameters:
    ///   - visionBox: Normalized CGRect from Vision ([0, 1], bottom-left origin).
    ///   - imageSize: Original image pixel or point dimensions.
    ///   - containerSize: Display view bounds dimensions.
    /// - Returns: CGRect in view coordinates (top-left origin).
    static func convertVisionBoundingBox(
        _ visionBox: CGRect,
        imageSize: CGSize,
        containerSize: CGSize
    ) -> CGRect {
        let renderRect = aspectFitRect(for: imageSize, in: containerSize)
        guard renderRect != .zero else { return .zero }

        let rectX = renderRect.minX + (visionBox.minX * renderRect.width)
        // Vision y origin is bottom-left, so top of box is 1.0 - (y + height)
        let rectY = renderRect.minY + ((1.0 - visionBox.minY - visionBox.height) * renderRect.height)
        let rectWidth = visionBox.width * renderRect.width
        let rectHeight = visionBox.height * renderRect.height

        return CGRect(x: rectX, y: rectY, width: rectWidth, height: rectHeight)
    }
}
