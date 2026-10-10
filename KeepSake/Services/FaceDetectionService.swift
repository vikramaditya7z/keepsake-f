import Foundation
import Vision
import CoreGraphics
import ImageIO

/// Protocol defining face detection service operations to ensure detector replaceability.
protocol FaceDetectionServiceProtocol: Sendable {
    func detectFaces(in imageURL: URL) async throws -> [DetectedFace]
    func detectFaces(in cgImage: CGImage) async throws -> [DetectedFace]
}

/// Face detection errors.
enum FaceDetectionError: LocalizedError {
    case unreadableImage(URL)
    case visionRequestFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreadableImage(let url):
            return "Could not load image for face detection at \(url.path)."
        case .visionRequestFailed(let message):
            return "Vision face detection failed: \(message)"
        }
    }
}

/// Concrete face detection service using Apple's Vision framework.
struct VisionFaceDetectionService: FaceDetectionServiceProtocol {
    /// Detects face rectangles from an image file URL using Apple Vision.
    func detectFaces(in imageURL: URL) async throws -> [DetectedFace] {
        return try await Task.detached(priority: .userInitiated) {
            let handler = VNImageRequestHandler(url: imageURL, options: [:])
            let request = VNDetectFaceRectanglesRequest()

            do {
                try handler.perform([request])
            } catch {
                throw FaceDetectionError.visionRequestFailed(error.localizedDescription)
            }

            guard let observations = request.results as? [VNFaceObservation] else {
                return []
            }

            return observations.map { obs in
                DetectedFace(
                    boundingBox: obs.boundingBox,
                    confidence: obs.confidence
                )
            }
        }.value
    }

    /// Detects face rectangles from a CGImage using Apple Vision.
    func detectFaces(in cgImage: CGImage) async throws -> [DetectedFace] {
        return try await Task.detached(priority: .userInitiated) {
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            let request = VNDetectFaceRectanglesRequest()

            do {
                try handler.perform([request])
            } catch {
                throw FaceDetectionError.visionRequestFailed(error.localizedDescription)
            }

            guard let observations = request.results as? [VNFaceObservation] else {
                return []
            }

            return observations.map { obs in
                DetectedFace(
                    boundingBox: obs.boundingBox,
                    confidence: obs.confidence
                )
            }
        }.value
    }
}
