import Foundation

/// Represents an on-device facial feature embedding vector extracted from a detected face.
struct FaceEmbedding: Identifiable, Hashable, Sendable {
    let id: UUID
    let photoURL: URL
    let faceId: UUID
    let vector: [Float]
    let dimension: Int
    let modelName: String
    let inferenceTimeMs: Double
    let createdAt: Date

    init(
        id: UUID = UUID(),
        photoURL: URL,
        faceId: UUID,
        vector: [Float],
        modelName: String = "ArcFace",
        inferenceTimeMs: Double = 0.0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.photoURL = photoURL
        self.faceId = faceId
        self.vector = vector
        self.dimension = vector.count
        self.modelName = modelName
        self.inferenceTimeMs = inferenceTimeMs
        self.createdAt = createdAt
    }

    init(
        id: UUID = UUID(),
        faceId: UUID,
        photoURL: URL,
        vector: [Float],
        modelName: String = "ArcFace",
        inferenceTimeMs: Double = 0.0,
        createdAt: Date = Date()
    ) {
        self.init(id: id, photoURL: photoURL, faceId: faceId, vector: vector, modelName: modelName, inferenceTimeMs: inferenceTimeMs, createdAt: createdAt)
    }

    /// Computes the L2 Euclidean norm of the embedding vector.
    var l2Norm: Float {
        let sumSquares = vector.reduce(0.0) { $0 + ($1 * $1) }
        return sqrt(sumSquares)
    }

    /// Formatted inference latency string for diagnostics.
    var formattedInferenceTime: String {
        return String(format: "%.1f ms", inferenceTimeMs)
    }
}
