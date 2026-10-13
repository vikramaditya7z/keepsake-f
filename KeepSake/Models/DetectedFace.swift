import Foundation
import CoreGraphics

/// Normalized 5-point facial landmark coordinates relative to the face bounding box [0, 1].
/// Coordinate system: (0, 0) bottom-left, (1, 1) top-right (matching Vision conventions).
struct FaceLandmarks5Point: Hashable, Sendable, Codable {
    let leftEye: CGPoint      // Viewer's left eye
    let rightEye: CGPoint     // Viewer's right eye
    let nose: CGPoint         // Nose tip
    let leftMouth: CGPoint    // Viewer's left mouth corner
    let rightMouth: CGPoint   // Viewer's right mouth corner
    let confidence: Float

    init(
        leftEye: CGPoint,
        rightEye: CGPoint,
        nose: CGPoint,
        leftMouth: CGPoint,
        rightMouth: CGPoint,
        confidence: Float = 1.0
    ) {
        self.leftEye = leftEye
        self.rightEye = rightEye
        self.nose = nose
        self.leftMouth = leftMouth
        self.rightMouth = rightMouth
        self.confidence = confidence
    }
}

/// Represents a detected face in an image with normalized coordinates.
struct DetectedFace: Identifiable, Hashable, Sendable {
    let id: UUID
    /// Normalized bounding box in Vision coordinate space:
    /// - (0, 0) is at bottom-left, (1, 1) is at top-right
    /// - origin.x, origin.y, size.width, size.height in range [0, 1]
    let boundingBox: CGRect
    let confidence: Float
    let landmarks: FaceLandmarks5Point?

    init(
        id: UUID = UUID(),
        boundingBox: CGRect,
        confidence: Float = 1.0,
        landmarks: FaceLandmarks5Point? = nil
    ) {
        self.id = id
        self.boundingBox = boundingBox
        self.confidence = confidence
        self.landmarks = landmarks
    }
}
