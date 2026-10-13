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

/// Concrete face detection service using Apple's Vision framework with 5-point facial landmark extraction.
struct VisionFaceDetectionService: FaceDetectionServiceProtocol {
    /// Extracts canonical 5-point facial landmarks from a VNFaceObservation.
    static func extract5PointLandmarks(from obs: VNFaceObservation) -> FaceLandmarks5Point? {
        guard let lm = obs.landmarks,
              let leftEyeReg = lm.leftEye,
              let rightEyeReg = lm.rightEye,
              let noseReg = lm.nose ?? lm.noseCrest,
              let lipsReg = lm.outerLips,
              leftEyeReg.pointCount > 0,
              rightEyeReg.pointCount > 0,
              noseReg.pointCount > 0,
              lipsReg.pointCount > 0 else {
            return nil
        }

        guard let minXPt = lipsReg.normalizedPoints.min(by: { $0.x < $1.x }),
              let maxXPt = lipsReg.normalizedPoints.max(by: { $0.x < $1.x }) else {
            return nil
        }

        let leftEyePt = CGPoint(
            x: leftEyeReg.normalizedPoints.map { $0.x }.reduce(0, +) / CGFloat(leftEyeReg.pointCount),
            y: leftEyeReg.normalizedPoints.map { $0.y }.reduce(0, +) / CGFloat(leftEyeReg.pointCount)
        )
        let rightEyePt = CGPoint(
            x: rightEyeReg.normalizedPoints.map { $0.x }.reduce(0, +) / CGFloat(rightEyeReg.pointCount),
            y: rightEyeReg.normalizedPoints.map { $0.y }.reduce(0, +) / CGFloat(rightEyeReg.pointCount)
        )
        let nosePt = CGPoint(
            x: noseReg.normalizedPoints.map { $0.x }.reduce(0, +) / CGFloat(noseReg.pointCount),
            y: noseReg.normalizedPoints.map { $0.y }.min() ?? 0.5
        )

        // Sanity checks on landmark geometry: left eye must be left of right eye, eyes above mouth
        guard leftEyePt.x < rightEyePt.x,
              leftEyePt.y > minXPt.y,
              rightEyePt.y > maxXPt.y else {
            return nil
        }

        return FaceLandmarks5Point(
            leftEye: leftEyePt,
            rightEye: rightEyePt,
            nose: nosePt,
            leftMouth: minXPt,
            rightMouth: maxXPt,
            confidence: obs.confidence
        )
    }

    /// Detects face rectangles and landmarks from an image file URL using Apple Vision.
    func detectFaces(in imageURL: URL) async throws -> [DetectedFace] {
        return try await Task.detached(priority: .userInitiated) {
            let handler = VNImageRequestHandler(url: imageURL, options: [:])
            let request = VNDetectFaceLandmarksRequest()

            do {
                try handler.perform([request])
            } catch {
                throw FaceDetectionError.visionRequestFailed(error.localizedDescription)
            }

            guard let observations = request.results else {
                return []
            }

            return observations.map { obs in
                let landmarks = Self.extract5PointLandmarks(from: obs)
                return DetectedFace(
                    boundingBox: obs.boundingBox,
                    confidence: obs.confidence,
                    landmarks: landmarks
                )
            }
        }.value
    }

    /// Detects face rectangles and landmarks from a CGImage using Apple Vision.
    func detectFaces(in cgImage: CGImage) async throws -> [DetectedFace] {
        return try await Task.detached(priority: .userInitiated) {
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            let request = VNDetectFaceLandmarksRequest()

            do {
                try handler.perform([request])
            } catch {
                throw FaceDetectionError.visionRequestFailed(error.localizedDescription)
            }

            guard let observations = request.results else {
                return []
            }

            return observations.map { obs in
                let landmarks = Self.extract5PointLandmarks(from: obs)
                return DetectedFace(
                    boundingBox: obs.boundingBox,
                    confidence: obs.confidence,
                    landmarks: landmarks
                )
            }
        }.value
    }
}
