import Foundation
import CoreGraphics

/// Explicit lifecycle processing state of a photo in the local library index.
enum PhotoProcessingState: String, Codable, Sendable, CaseIterable {
    case discovered
    case processing
    case processed
    case failed
    case needsReprocessing
}

/// Lifecycle state for face detection and embedding extraction on a specific face.
enum FaceProcessingState: String, Codable, Sendable {
    case detected
    case embedded
    case failed
}

/// Persistent metadata representing the active local photo library and its security-scoped folder bookmark.
struct LibraryMetadataRecord: Codable, Identifiable, Sendable {
    let id: UUID
    var folderBookmarkData: Data?
    var folderPath: String
    var folderName: String
    let createdAt: Date
    var updatedAt: Date
    var lastScanDate: Date?

    init(
        id: UUID = UUID(),
        folderBookmarkData: Data? = nil,
        folderPath: String,
        folderName: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastScanDate: Date? = nil
    ) {
        self.id = id
        self.folderBookmarkData = folderBookmarkData
        self.folderPath = folderPath
        self.folderName = folderName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastScanDate = lastScanDate
    }
}

/// Persistent index record for a photo in the library.
struct PhotoRecord: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    var relativePath: String
    var filename: String
    var fileSize: Int64
    var modificationDate: Date
    var fileFingerprint: String
    var processingState: PhotoProcessingState
    var lastProcessedDate: Date?
    var failureReason: String?
    var detectedFacesCount: Int

    init(
        id: UUID = UUID(),
        relativePath: String,
        filename: String,
        fileSize: Int64,
        modificationDate: Date,
        fileFingerprint: String? = nil,
        processingState: PhotoProcessingState = .discovered,
        lastProcessedDate: Date? = nil,
        failureReason: String? = nil,
        detectedFacesCount: Int = 0
    ) {
        self.id = id
        self.relativePath = relativePath
        self.filename = filename
        self.fileSize = fileSize
        self.modificationDate = modificationDate
        self.fileFingerprint = fileFingerprint ?? Self.computeFingerprint(
            relativePath: relativePath,
            fileSize: fileSize,
            modificationDate: modificationDate
        )
        self.processingState = processingState
        self.lastProcessedDate = lastProcessedDate
        self.failureReason = failureReason
        self.detectedFacesCount = detectedFacesCount
    }

    /// Computes a stable lightweight filesystem fingerprint without hashing the entire multi-megabyte image.
    static func computeFingerprint(relativePath: String, fileSize: Int64, modificationDate: Date) -> String {
        let timestamp = Int64(modificationDate.timeIntervalSince1970 * 1000)
        return "\(relativePath):\(fileSize):\(timestamp)"
    }
}

/// Persistent record for a detected face within a photo.
struct FaceRecord: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    let photoId: UUID
    let boundingBox: CGRect
    let confidence: Float
    var processingState: FaceProcessingState

    init(
        id: UUID = UUID(),
        photoId: UUID,
        boundingBox: CGRect,
        confidence: Float = 1.0,
        processingState: FaceProcessingState = .detected
    ) {
        self.id = id
        self.photoId = photoId
        self.boundingBox = boundingBox
        self.confidence = confidence
        self.processingState = processingState
    }
}

/// Persistent record for an ArcFace or Vision face recognition embedding.
struct EmbeddingRecord: Codable, Identifiable, Sendable {
    let id: UUID
    let faceId: UUID
    let photoId: UUID
    let vectorData: Data
    let dimension: Int
    let modelName: String
    let modelVersion: String
    let inferenceTimeMs: Double
    let createdAt: Date

    init(
        id: UUID = UUID(),
        faceId: UUID,
        photoId: UUID,
        vector: [Float],
        modelName: String = "ArcFace",
        modelVersion: String = "MobileFaceNet-512D-v1",
        inferenceTimeMs: Double = 0.0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.faceId = faceId
        self.photoId = photoId
        self.dimension = vector.count
        var data = Data(count: vector.count * MemoryLayout<Float>.size)
        data.withUnsafeMutableBytes { rawBytes in
            if let base = rawBytes.bindMemory(to: Float.self).baseAddress {
                for i in 0..<vector.count {
                    base[i] = vector[i]
                }
            }
        }
        self.vectorData = data
        self.modelName = modelName
        self.modelVersion = modelVersion
        self.inferenceTimeMs = inferenceTimeMs
        self.createdAt = createdAt
    }

    /// Deserializes the binary vector data back into an array of Float values.
    var vector: [Float] {
        return vectorData.withUnsafeBytes { rawBuffer in
            guard let floatPtr = rawBuffer.bindMemory(to: Float.self).baseAddress else {
                return []
            }
            return Array(UnsafeBufferPointer(start: floatPtr, count: dimension))
        }
    }
}

/// Persistent record for a face group representing an identity or cluster.
struct GroupRecord: Codable, Identifiable, Sendable {
    let id: UUID
    var groupIndex: Int
    var customName: String?
    var representativeFaceId: UUID?
    var memberFaceIds: [UUID]
    var centroidData: Data?
    var identityAnchorsData: Data?
    var averageSimilarity: Float
    var minSimilarity: Float
    var thresholdUsed: Float
    var algorithmName: String
    var algorithmVersion: String
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        groupIndex: Int,
        customName: String? = nil,
        representativeFaceId: UUID? = nil,
        memberFaceIds: [UUID],
        centroid: [Float]? = nil,
        identityAnchors: [[Float]]? = nil,
        averageSimilarity: Float,
        minSimilarity: Float,
        thresholdUsed: Float,
        algorithmName: String = "Cosine Graph & Multi-Anchor Identity Reconciliation",
        algorithmVersion: String = "v2",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.groupIndex = groupIndex
        self.customName = customName
        self.representativeFaceId = representativeFaceId
        self.memberFaceIds = memberFaceIds
        if let c = centroid {
            var data = Data(count: c.count * MemoryLayout<Float>.size)
            data.withUnsafeMutableBytes { rawBytes in
                if let base = rawBytes.bindMemory(to: Float.self).baseAddress {
                    for i in 0..<c.count {
                        base[i] = c[i]
                    }
                }
            }
            self.centroidData = data
        } else {
            self.centroidData = nil
        }

        if let anchors = identityAnchors, !anchors.isEmpty {
            let totalFloats = anchors.reduce(0) { $0 + $1.count }
            var aData = Data(count: totalFloats * MemoryLayout<Float>.size)
            aData.withUnsafeMutableBytes { rawBytes in
                if let base = rawBytes.bindMemory(to: Float.self).baseAddress {
                    var offset = 0
                    for anchor in anchors {
                        for val in anchor {
                            base[offset] = val
                            offset += 1
                        }
                    }
                }
            }
            self.identityAnchorsData = aData
        } else if let c = centroid {
            var aData = Data(count: c.count * MemoryLayout<Float>.size)
            aData.withUnsafeMutableBytes { rawBytes in
                if let base = rawBytes.bindMemory(to: Float.self).baseAddress {
                    for i in 0..<c.count {
                        base[i] = c[i]
                    }
                }
            }
            self.identityAnchorsData = aData
        } else {
            self.identityAnchorsData = nil
        }

        self.averageSimilarity = averageSimilarity
        self.minSimilarity = minSimilarity
        self.thresholdUsed = thresholdUsed
        self.algorithmName = algorithmName
        self.algorithmVersion = algorithmVersion
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// User-facing display name. Prefers user-assigned customName, falling back to 'Person N'.
    var displayName: String {
        if let custom = customName?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            return custom
        }
        return "Person \(groupIndex)"
    }

    var centroid: [Float]? {
        guard let data = centroidData else { return nil }
        return data.withUnsafeBytes { rawBuffer in
            guard let floatPtr = rawBuffer.bindMemory(to: Float.self).baseAddress else { return nil }
            let count = data.count / MemoryLayout<Float>.size
            return Array(UnsafeBufferPointer(start: floatPtr, count: count))
        }
    }

    var identityAnchors: [[Float]] {
        guard let data = identityAnchorsData else {
            if let c = centroid { return [c] }
            return []
        }
        let dim = centroid?.count ?? 512
        guard dim > 0 else { return [] }
        return data.withUnsafeBytes { rawBuffer in
            guard let floatPtr = rawBuffer.bindMemory(to: Float.self).baseAddress else { return [] }
            let totalFloats = data.count / MemoryLayout<Float>.size
            guard totalFloats % dim == 0 else { return [] }
            let numAnchors = totalFloats / dim
            var result: [[Float]] = []
            for i in 0..<numAnchors {
                let slice = Array(UnsafeBufferPointer(start: floatPtr.advanced(by: i * dim), count: dim))
                result.append(slice)
            }
            return result
        }
    }
}

/// Result of reconciling a filesystem scan with the persistent library index.
struct LibraryReconciliationResult: Sendable {
    let newPhotos: [PhotoRecord]
    let changedPhotos: [PhotoRecord]
    let unchangedPhotos: [PhotoRecord]
    let removedPhotos: [PhotoRecord]

    var totalIndexed: Int {
        return newPhotos.count + changedPhotos.count + unchangedPhotos.count
    }

    var requiresProcessingCount: Int {
        return newPhotos.count + changedPhotos.count
    }
}

/// An identity profile representing an established person, their facial centroid manifold, diverse identity anchors, and member face IDs.
struct PersonIdentityProfile: Sendable, Identifiable {
    let id: UUID
    var groupIndex: Int
    var customName: String?
    var representativeFaceId: UUID?
    var memberFaceIds: Set<UUID>
    var centroid: [Float]
    var identityAnchors: [[Float]]
    var isManuallyConfirmed: Bool

    init(
        id: UUID,
        groupIndex: Int,
        customName: String? = nil,
        representativeFaceId: UUID? = nil,
        memberFaceIds: Set<UUID>,
        centroid: [Float],
        identityAnchors: [[Float]]? = nil,
        isManuallyConfirmed: Bool = false
    ) {
        self.id = id
        self.groupIndex = groupIndex
        self.customName = customName
        self.representativeFaceId = representativeFaceId
        self.memberFaceIds = memberFaceIds
        self.centroid = centroid
        self.identityAnchors = identityAnchors ?? [centroid]
        self.isManuallyConfirmed = isManuallyConfirmed
    }
}

