import Foundation
import CoreGraphics

/// Represents a member face inside an experimental face cluster group.
struct ClusteredFaceMember: Identifiable, Hashable, Sendable {
    let id: UUID
    let faceId: UUID
    let photoURL: URL
    let boundingBox: CGRect?
    let embedding: FaceEmbedding
    let similarityToCentroid: Float

    init(
        id: UUID = UUID(),
        faceId: UUID,
        photoURL: URL,
        boundingBox: CGRect? = nil,
        embedding: FaceEmbedding,
        similarityToCentroid: Float = 1.0
    ) {
        self.id = id
        self.faceId = faceId
        self.photoURL = photoURL
        self.boundingBox = boundingBox
        self.embedding = embedding
        self.similarityToCentroid = similarityToCentroid
    }
}

/// Represents an experimental group of face embeddings clustered by biometric similarity.
/// Note: Face groups represent statistical visual similarity and do not establish verified human identity.
struct FaceGroup: Identifiable, Hashable, Sendable {
    let id: UUID
    let groupIndex: Int
    let members: [ClusteredFaceMember]
    let representativeMember: ClusteredFaceMember?
    let centroid: [Float]
    let averageIntraClusterSimilarity: Float
    let minIntraClusterSimilarity: Float
    let thresholdUsed: Float

    init(
        id: UUID = UUID(),
        groupIndex: Int,
        members: [ClusteredFaceMember],
        representativeMember: ClusteredFaceMember?,
        centroid: [Float],
        averageIntraClusterSimilarity: Float,
        minIntraClusterSimilarity: Float,
        thresholdUsed: Float
    ) {
        self.id = id
        self.groupIndex = groupIndex
        self.members = members
        self.representativeMember = representativeMember
        self.centroid = centroid
        self.averageIntraClusterSimilarity = averageIntraClusterSimilarity
        self.minIntraClusterSimilarity = minIntraClusterSimilarity
        self.thresholdUsed = thresholdUsed
    }

    /// Total number of face instances in this cluster.
    var faceCount: Int {
        return members.count
    }

    /// Display title for the experimental cluster (e.g., "Group 1").
    var title: String {
        return "Group \(groupIndex)"
    }

    /// Formatted summary of member count.
    var formattedMemberCount: String {
        return faceCount == 1 ? "1 face" : "\(faceCount) faces"
    }

    /// Formatted intra-cluster similarity metrics for diagnostics.
    var formattedSimilarityStats: String {
        if faceCount <= 1 {
            return "Singleton (1.000)"
        }
        return String(format: "Avg: %.3f • Min: %.3f", averageIntraClusterSimilarity, minIntraClusterSimilarity)
    }
}
