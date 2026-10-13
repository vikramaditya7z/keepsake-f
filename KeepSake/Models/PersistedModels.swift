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
    var rootFolderPath: String?

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
        detectedFacesCount: Int = 0,
        rootFolderPath: String? = nil
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
        self.rootFolderPath = rootFolderPath
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
    var isExcluded: Bool
    var excludedAt: Date?
    var exclusionReason: String?

    init(
        id: UUID = UUID(),
        photoId: UUID,
        boundingBox: CGRect,
        confidence: Float = 1.0,
        processingState: FaceProcessingState = .detected,
        isExcluded: Bool = false,
        excludedAt: Date? = nil,
        exclusionReason: String? = nil
    ) {
        self.id = id
        self.photoId = photoId
        self.boundingBox = boundingBox
        self.confidence = confidence
        self.processingState = processingState
        self.isExcluded = isExcluded
        self.excludedAt = excludedAt
        self.exclusionReason = exclusionReason
    }

    enum CodingKeys: String, CodingKey {
        case id, photoId, boundingBox, confidence, processingState, isExcluded, excludedAt, exclusionReason
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.photoId = try container.decode(UUID.self, forKey: .photoId)
        self.boundingBox = try container.decode(CGRect.self, forKey: .boundingBox)
        self.confidence = try container.decode(Float.self, forKey: .confidence)
        self.processingState = try container.decode(FaceProcessingState.self, forKey: .processingState)
        self.isExcluded = try container.decodeIfPresent(Bool.self, forKey: .isExcluded) ?? false
        self.excludedAt = try container.decodeIfPresent(Date.self, forKey: .excludedAt)
        self.exclusionReason = try container.decodeIfPresent(String.self, forKey: .exclusionReason)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(photoId, forKey: .photoId)
        try container.encode(boundingBox, forKey: .boundingBox)
        try container.encode(confidence, forKey: .confidence)
        try container.encode(processingState, forKey: .processingState)
        if isExcluded {
            try container.encode(isExcluded, forKey: .isExcluded)
        }
        try container.encodeIfPresent(excludedAt, forKey: .excludedAt)
        try container.encodeIfPresent(exclusionReason, forKey: .exclusionReason)
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

/// Status of a face group in the semi-automatic identity review pipeline.
enum IdentityReviewStatus: String, Codable, Sendable {
    /// Candidate cluster suggested by clustering, awaiting user confirmation or rejection.
    case candidateSuggestion = "candidateSuggestion"
    /// User-confirmed person identity (or user-named identity).
    case confirmed = "confirmed"
    /// Rejected candidate suggestion.
    case rejected = "rejected"
}

/// Persistent record for a face group representing an identity or cluster.
struct GroupRecord: Codable, Identifiable, Sendable {
    let id: UUID
    var groupIndex: Int
    var customName: String?
    var coverFaceId: UUID?
    var representativeFaceId: UUID?
    var memberFaceIds: [UUID]
    var centroidData: Data?
    var identityAnchorsData: Data?
    var averageSimilarity: Float
    var minSimilarity: Float
    var thresholdUsed: Float
    var algorithmName: String
    var algorithmVersion: String
    var reviewStatus: IdentityReviewStatus
    var rootFolderPath: String?
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        groupIndex: Int,
        customName: String? = nil,
        coverFaceId: UUID? = nil,
        representativeFaceId: UUID? = nil,
        memberFaceIds: [UUID],
        centroid: [Float]? = nil,
        identityAnchors: [[Float]]? = nil,
        averageSimilarity: Float,
        minSimilarity: Float,
        thresholdUsed: Float,
        algorithmName: String = "Cosine Graph & Multi-Anchor Identity Reconciliation",
        algorithmVersion: String = "v2",
        reviewStatus: IdentityReviewStatus = .candidateSuggestion,
        rootFolderPath: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.groupIndex = groupIndex
        self.customName = customName
        self.coverFaceId = coverFaceId
        self.representativeFaceId = representativeFaceId
        self.memberFaceIds = memberFaceIds
        self.reviewStatus = reviewStatus
        self.rootFolderPath = rootFolderPath
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

    enum CodingKeys: String, CodingKey {
        case id
        case groupIndex
        case customName
        case coverFaceId
        case representativeFaceId
        case memberFaceIds
        case centroidData
        case identityAnchorsData
        case averageSimilarity
        case minSimilarity
        case thresholdUsed
        case algorithmName
        case algorithmVersion
        case reviewStatus
        case rootFolderPath
        case createdAt
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.groupIndex = try container.decode(Int.self, forKey: .groupIndex)
        self.customName = try container.decodeIfPresent(String.self, forKey: .customName)
        self.coverFaceId = try container.decodeIfPresent(UUID.self, forKey: .coverFaceId)
        self.representativeFaceId = try container.decodeIfPresent(UUID.self, forKey: .representativeFaceId)
        self.memberFaceIds = try container.decode([UUID].self, forKey: .memberFaceIds)
        self.centroidData = try container.decodeIfPresent(Data.self, forKey: .centroidData)
        self.identityAnchorsData = try container.decodeIfPresent(Data.self, forKey: .identityAnchorsData)
        self.averageSimilarity = try container.decode(Float.self, forKey: .averageSimilarity)
        self.minSimilarity = try container.decode(Float.self, forKey: .minSimilarity)
        self.thresholdUsed = try container.decode(Float.self, forKey: .thresholdUsed)
        self.algorithmName = try container.decode(String.self, forKey: .algorithmName)
        self.algorithmVersion = try container.decode(String.self, forKey: .algorithmVersion)
        self.rootFolderPath = try container.decodeIfPresent(String.self, forKey: .rootFolderPath)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)

        if let decodedStatus = try container.decodeIfPresent(IdentityReviewStatus.self, forKey: .reviewStatus) {
            self.reviewStatus = decodedStatus
        } else {
            if let custom = self.customName?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
                self.reviewStatus = .confirmed
            } else {
                self.reviewStatus = .candidateSuggestion
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(groupIndex, forKey: .groupIndex)
        try container.encodeIfPresent(customName, forKey: .customName)
        try container.encodeIfPresent(coverFaceId, forKey: .coverFaceId)
        try container.encodeIfPresent(representativeFaceId, forKey: .representativeFaceId)
        try container.encode(memberFaceIds, forKey: .memberFaceIds)
        try container.encodeIfPresent(centroidData, forKey: .centroidData)
        try container.encodeIfPresent(identityAnchorsData, forKey: .identityAnchorsData)
        try container.encode(averageSimilarity, forKey: .averageSimilarity)
        try container.encode(minSimilarity, forKey: .minSimilarity)
        try container.encode(thresholdUsed, forKey: .thresholdUsed)
        try container.encode(algorithmName, forKey: .algorithmName)
        try container.encode(algorithmVersion, forKey: .algorithmVersion)
        try container.encode(reviewStatus, forKey: .reviewStatus)
        try container.encodeIfPresent(rootFolderPath, forKey: .rootFolderPath)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
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

/// Persistent record for a central, app-wide person identity independent of folder selection.
struct PersonRecord: Codable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var coverFaceId: UUID?
    var representativeFaceId: UUID?
    var confirmedFaceIds: [UUID]
    var centroidData: Data?
    var identityAnchorsData: Data?
    let createdAt: Date
    var updatedAt: Date
    var isDeactivated: Bool

    init(
        id: UUID = UUID(),
        name: String,
        coverFaceId: UUID? = nil,
        representativeFaceId: UUID? = nil,
        confirmedFaceIds: [UUID] = [],
        centroid: [Float]? = nil,
        identityAnchors: [[Float]]? = nil,
        centroidData: Data? = nil,
        identityAnchorsData: Data? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        isDeactivated: Bool = false
    ) {
        self.id = id
        self.name = name
        self.coverFaceId = coverFaceId
        self.representativeFaceId = representativeFaceId
        self.confirmedFaceIds = confirmedFaceIds
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isDeactivated = isDeactivated

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
            self.centroidData = centroidData
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
            self.identityAnchorsData = identityAnchorsData
        }
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

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case coverFaceId
        case representativeFaceId
        case confirmedFaceIds
        case centroidData
        case identityAnchorsData
        case createdAt
        case updatedAt
        case isDeactivated
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.coverFaceId = try container.decodeIfPresent(UUID.self, forKey: .coverFaceId)
        self.representativeFaceId = try container.decodeIfPresent(UUID.self, forKey: .representativeFaceId)
        self.confirmedFaceIds = try container.decode([UUID].self, forKey: .confirmedFaceIds)
        self.centroidData = try container.decodeIfPresent(Data.self, forKey: .centroidData)
        self.identityAnchorsData = try container.decodeIfPresent(Data.self, forKey: .identityAnchorsData)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        self.isDeactivated = try container.decodeIfPresent(Bool.self, forKey: .isDeactivated) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(coverFaceId, forKey: .coverFaceId)
        try container.encodeIfPresent(representativeFaceId, forKey: .representativeFaceId)
        try container.encode(confirmedFaceIds, forKey: .confirmedFaceIds)
        try container.encodeIfPresent(centroidData, forKey: .centroidData)
        try container.encodeIfPresent(identityAnchorsData, forKey: .identityAnchorsData)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(isDeactivated, forKey: .isDeactivated)
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

/// Persistent record for a face association removed from a confirmed person and kept for recovery in the Recycle Bin.
struct RemovedFaceAssociationRecord: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    let faceId: UUID
    let personId: UUID
    let personName: String
    let photoId: UUID
    let removedAt: Date
    var reason: String?

    init(
        id: UUID = UUID(),
        faceId: UUID,
        personId: UUID,
        personName: String,
        photoId: UUID,
        removedAt: Date = Date(),
        reason: String? = nil
    ) {
        self.id = id
        self.faceId = faceId
        self.personId = personId
        self.personName = personName
        self.photoId = photoId
        self.removedAt = removedAt
        self.reason = reason
    }
}

