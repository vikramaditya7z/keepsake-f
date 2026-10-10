import Foundation
import CoreGraphics

/// Represents a detected face in an image with normalized coordinates.
struct DetectedFace: Identifiable, Hashable, Sendable {
    let id: UUID
    /// Normalized bounding box in Vision coordinate space:
    /// - (0, 0) is at bottom-left, (1, 1) is at top-right
    /// - origin.x, origin.y, size.width, size.height in range [0, 1]
    let boundingBox: CGRect
    let confidence: Float

    init(id: UUID = UUID(), boundingBox: CGRect, confidence: Float = 1.0) {
        self.id = id
        self.boundingBox = boundingBox
        self.confidence = confidence
    }
}
