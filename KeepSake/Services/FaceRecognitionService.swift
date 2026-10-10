import Foundation
import Vision
import CoreGraphics

/// Protocol defining face recognition and feature embedding operations.
protocol FaceRecognitionServiceProtocol: Sendable {
    var modelName: String { get }
    var modelArchitecture: String { get }
    var embeddingDimension: Int { get }

    /// Generates a feature embedding vector from a cropped face image.
    func generateEmbedding(
        from faceCrop: CGImage,
        photoURL: URL,
        faceId: UUID
    ) async throws -> FaceEmbedding

    /// Preprocesses and generates a feature embedding for a detected face in a photo file.
    func generateEmbedding(
        for face: DetectedFace,
        in photoURL: URL
    ) async throws -> FaceEmbedding
}

/// Face recognition errors.
enum FaceRecognitionError: LocalizedError {
    case featurePrintGenerationFailed(String)
    case unreadableCropData
    case invalidEmbeddingDimension(expected: Int, actual: Int)

    var errorDescription: String? {
        switch self {
        case .featurePrintGenerationFailed(let message):
            return "Face embedding generation failed: \(message)"
        case .unreadableCropData:
            return "Could not extract numerical feature print data from observation."
        case .invalidEmbeddingDimension(let expected, let actual):
            return "Unexpected embedding dimension: expected \(expected), got \(actual)."
        }
    }
}

/// Concrete face recognition service using Apple's on-device Vision FeaturePrint engine.
struct VisionFaceRecognitionService: FaceRecognitionServiceProtocol {
    let modelName: String = "Apple Vision FeaturePrint (Revision 2)"
    let modelArchitecture: String = "Deep CNN Visual Embedding"
    let embeddingDimension: Int = 768

    private let preprocessor = FacePreprocessingService()

    /// Generates a normalized 512-D embedding from a cropped face CGImage.
    func generateEmbedding(
        from faceCrop: CGImage,
        photoURL: URL,
        faceId: UUID
    ) async throws -> FaceEmbedding {
        return try await Task.detached(priority: .userInitiated) {
            let startTime = ContinuousClock.now

            let request = VNGenerateImageFeaturePrintRequest()
            request.revision = VNGenerateImageFeaturePrintRequestRevision2
            request.imageCropAndScaleOption = .scaleFit

            let handler = VNImageRequestHandler(cgImage: faceCrop, options: [:])

            do {
                try handler.perform([request])
            } catch {
                throw FaceRecognitionError.featurePrintGenerationFailed(error.localizedDescription)
            }

            guard let observation = request.results?.first as? VNFeaturePrintObservation else {
                throw FaceRecognitionError.featurePrintGenerationFailed("No feature print observation returned.")
            }

            let elementCount = observation.elementCount
            guard elementCount > 0 else {
                throw FaceRecognitionError.unreadableCropData
            }

            var rawVector = [Float](repeating: 0.0, count: elementCount)
            observation.data.withUnsafeBytes { rawBuffer in
                if let floatBuffer = rawBuffer.bindMemory(to: Float.self).baseAddress {
                    for i in 0..<elementCount {
                        rawVector[i] = floatBuffer[i]
                    }
                }
            }

            // Ensure unit L2 normalization for reliable cosine similarity
            let normalizedVector = EmbeddingSimilarityUtility.l2Normalize(rawVector)

            let duration = ContinuousClock.now - startTime
            let milliseconds = Double(duration.components.attoseconds) / 1_000_000_000_000_000.0 + Double(duration.components.seconds) * 1000.0

            return FaceEmbedding(
                photoURL: photoURL,
                faceId: faceId,
                vector: normalizedVector,
                modelName: self.modelName,
                inferenceTimeMs: milliseconds
            )
        }.value
    }

    /// Preprocesses a detected face from a photo file and generates its embedding.
    func generateEmbedding(
        for face: DetectedFace,
        in photoURL: URL
    ) async throws -> FaceEmbedding {
        let crop = try preprocessor.cropFace(from: photoURL, normalizedBox: face.boundingBox)
        return try await generateEmbedding(from: crop, photoURL: photoURL, faceId: face.id)
    }
}
