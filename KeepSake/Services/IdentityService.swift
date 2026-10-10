import Foundation
import CoreGraphics
import Accelerate

/// Errors that can occur during identity and group management operations.
enum IdentityServiceError: LocalizedError {
    case groupNotFound(UUID)
    case faceNotFound(UUID)
    case invalidGroupName
    case cannotMergeGroupIntoItself
    case faceAlreadyInTargetGroup

    var errorDescription: String? {
        switch self {
        case .groupNotFound(let id):
            return "Group with ID \(id) was not found."
        case .faceNotFound(let id):
            return "Face with ID \(id) was not found."
        case .invalidGroupName:
            return "Group name cannot be empty."
        case .cannotMergeGroupIntoItself:
            return "Cannot merge a person into themselves."
        case .faceAlreadyInTargetGroup:
            return "Face is already a member of the target group."
        }
    }
}

/// Protocol defining person identity and group management operations.
protocol IdentityServiceProtocol: Sendable {
    func fetchGroups() async -> [GroupRecord]
    func fetchGroup(byId id: UUID) async -> GroupRecord?
    func renameGroup(id: UUID, newName: String) async throws
    func mergeGroups(targetGroupId: UUID, sourceGroupId: UUID) async throws
    func removeFaceFromGroup(faceId: UUID, groupId: UUID) async throws
    func assignFaceToGroup(faceId: UUID, targetGroupId: UUID) async throws
    func createNewGroup(withFaceId faceId: UUID, name: String?) async throws -> GroupRecord
    func deleteGroup(id: UUID) async throws
    func fetchUngroupedFaces() async -> [FaceRecord]
    func recalculateGroupMetadata(groupId: UUID) async throws
    func fetchPhotos(forGroupId groupId: UUID, rootFolderURL: URL?) async -> [PhotoItem]
    func fetchUniquePhotoCount(forGroupId groupId: UUID) async -> Int
    func fetchRepresentativeFace(forGroupId groupId: UUID) async -> (face: FaceRecord?, photo: PhotoRecord?)
    func setRepresentativeFace(groupId: UUID, faceId: UUID) async throws
}

/// Concrete service orchestrating user-driven identity operations, referential integrity, and metadata maintenance.
final class IdentityService: IdentityServiceProtocol {
    private let libraryStore: LibraryStore

    init(libraryStore: LibraryStore = LibraryStore.shared) {
        self.libraryStore = libraryStore
    }

    func fetchGroups() async -> [GroupRecord] {
        return await libraryStore.getGroups()
    }

    func fetchGroup(byId id: UUID) async -> GroupRecord? {
        return await libraryStore.getGroup(byId: id)
    }

    func renameGroup(id: UUID, newName: String) async throws {
        guard let group = await libraryStore.getGroup(byId: id) else {
            throw IdentityServiceError.groupNotFound(id)
        }

        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        var updated = group
        updated.customName = trimmed.isEmpty ? nil : trimmed
        updated.updatedAt = Date()

        try await libraryStore.saveGroup(updated)
    }

    func mergeGroups(targetGroupId: UUID, sourceGroupId: UUID) async throws {
        guard targetGroupId != sourceGroupId else {
            throw IdentityServiceError.cannotMergeGroupIntoItself
        }

        guard let targetGroup = await libraryStore.getGroup(byId: targetGroupId) else {
            throw IdentityServiceError.groupNotFound(targetGroupId)
        }
        guard let sourceGroup = await libraryStore.getGroup(byId: sourceGroupId) else {
            throw IdentityServiceError.groupNotFound(sourceGroupId)
        }

        // Union of member face IDs without duplicates
        var mergedFaceIds = targetGroup.memberFaceIds
        for faceId in sourceGroup.memberFaceIds {
            if !mergedFaceIds.contains(faceId) {
                mergedFaceIds.append(faceId)
            }
        }

        var updatedTarget = targetGroup
        updatedTarget.memberFaceIds = mergedFaceIds
        // Preserve target's customName if set, otherwise adopt source's customName if present
        if updatedTarget.customName == nil || updatedTarget.customName?.isEmpty == true {
            updatedTarget.customName = sourceGroup.customName
        }
        updatedTarget.updatedAt = Date()

        // Atomically save target and remove source group
        try await libraryStore.saveGroup(updatedTarget)
        try await libraryStore.deleteGroup(byId: sourceGroupId)

        // Recalculate centroid and representative face
        try await recalculateGroupMetadata(groupId: targetGroupId)
    }

    func removeFaceFromGroup(faceId: UUID, groupId: UUID) async throws {
        guard let group = await libraryStore.getGroup(byId: groupId) else {
            throw IdentityServiceError.groupNotFound(groupId)
        }

        var updatedFaceIds = group.memberFaceIds
        updatedFaceIds.removeAll { $0 == faceId }

        if updatedFaceIds.isEmpty {
            // Group is now empty, delete it
            try await libraryStore.deleteGroup(byId: groupId)
        } else {
            var updated = group
            updated.memberFaceIds = updatedFaceIds
            updated.updatedAt = Date()
            try await libraryStore.saveGroup(updated)
            try await recalculateGroupMetadata(groupId: groupId)
        }
    }

    func assignFaceToGroup(faceId: UUID, targetGroupId: UUID) async throws {
        guard let targetGroup = await libraryStore.getGroup(byId: targetGroupId) else {
            throw IdentityServiceError.groupNotFound(targetGroupId)
        }

        // 1. If face belongs to another existing group, remove it from that group first
        if let currentGroup = await libraryStore.getGroup(forFaceId: faceId) {
            if currentGroup.id == targetGroupId {
                return // Already assigned
            }
            try await removeFaceFromGroup(faceId: faceId, groupId: currentGroup.id)
        }

        // 2. Add to target group
        var updated = (await libraryStore.getGroup(byId: targetGroupId)) ?? targetGroup
        if !updated.memberFaceIds.contains(faceId) {
            updated.memberFaceIds.append(faceId)
        }
        updated.updatedAt = Date()
        try await libraryStore.saveGroup(updated)

        // 3. Recalculate target group stats
        try await recalculateGroupMetadata(groupId: targetGroupId)
    }

    func createNewGroup(withFaceId faceId: UUID, name: String? = nil) async throws -> GroupRecord {
        // If face is currently in another group, remove it
        if let currentGroup = await libraryStore.getGroup(forFaceId: faceId) {
            try await removeFaceFromGroup(faceId: faceId, groupId: currentGroup.id)
        }

        let allGroups = await libraryStore.getGroups()
        let maxIndex = allGroups.map { $0.groupIndex }.max() ?? 0
        let nextIndex = maxIndex + 1

        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let newGroup = GroupRecord(
            groupIndex: nextIndex,
            customName: (trimmedName?.isEmpty == false) ? trimmedName : nil,
            representativeFaceId: faceId,
            memberFaceIds: [faceId],
            centroid: nil,
            averageSimilarity: 1.0,
            minSimilarity: 1.0,
            thresholdUsed: 0.65
        )

        try await libraryStore.saveGroup(newGroup)
        try await recalculateGroupMetadata(groupId: newGroup.id)

        return (await libraryStore.getGroup(byId: newGroup.id)) ?? newGroup
    }

    func deleteGroup(id: UUID) async throws {
        // Deleting a group disassociates its faces back to unassigned state
        try await libraryStore.deleteGroup(byId: id)
    }

    func fetchUngroupedFaces() async -> [FaceRecord] {
        return await libraryStore.getUngroupedFaces()
    }

    func fetchUniquePhotoCount(forGroupId groupId: UUID) async -> Int {
        return await libraryStore.getUniquePhotoCount(forGroup: groupId)
    }

    func fetchPhotos(forGroupId groupId: UUID, rootFolderURL: URL?) async -> [PhotoItem] {
        let photoRecords = await libraryStore.getPhotos(forGroup: groupId)
        guard let rootURL = rootFolderURL else {
            return photoRecords.map { rec in
                let url = URL(fileURLWithPath: rec.relativePath)
                return PhotoItem(url: url, fileSize: rec.fileSize, dateModified: rec.modificationDate)
            }
        }

        return photoRecords.map { rec in
            let fullURL = rootURL.appendingPathComponent(rec.relativePath)
            return PhotoItem(url: fullURL, fileSize: rec.fileSize, dateModified: rec.modificationDate)
        }
    }

    func fetchRepresentativeFace(forGroupId groupId: UUID) async -> (face: FaceRecord?, photo: PhotoRecord?) {
        guard let face = await libraryStore.getRepresentativeFace(forGroup: groupId) else {
            return (nil, nil)
        }
        let photo = await libraryStore.getPhoto(byId: face.photoId)
        return (face, photo)
    }

    func setRepresentativeFace(groupId: UUID, faceId: UUID) async throws {
        guard var group = await libraryStore.getGroup(byId: groupId) else {
            throw IdentityServiceError.groupNotFound(groupId)
        }
        guard group.memberFaceIds.contains(faceId) else {
            throw IdentityServiceError.faceNotFound(faceId)
        }
        group.representativeFaceId = faceId
        group.updatedAt = Date()
        try await libraryStore.saveGroup(group)
    }

    // MARK: - Metadata & Centroid Recalculation

    func recalculateGroupMetadata(groupId: UUID) async throws {
        guard var group = await libraryStore.getGroup(byId: groupId) else {
            return
        }

        if group.memberFaceIds.isEmpty {
            try await libraryStore.deleteGroup(byId: groupId)
            return
        }

        // Fetch stored embeddings for all members
        var memberEmbeddings: [EmbeddingRecord] = []
        for faceId in group.memberFaceIds {
            if let emb = await libraryStore.getEmbedding(forFaceId: faceId) {
                memberEmbeddings.append(emb)
            }
        }

        guard !memberEmbeddings.isEmpty else {
            // No embeddings available; pick first face as representative if not already set
            if group.representativeFaceId == nil || !group.memberFaceIds.contains(group.representativeFaceId!) {
                group.representativeFaceId = group.memberFaceIds.first
            }
            group.averageSimilarity = 1.0
            group.minSimilarity = 1.0
            group.updatedAt = Date()
            try await libraryStore.saveGroup(group)
            return
        }

        let dim = memberEmbeddings[0].dimension
        let vectors = memberEmbeddings.map { $0.vector }

        if vectors.count == 1 {
            let singleVector = vectors[0]
            if group.representativeFaceId == nil || !group.memberFaceIds.contains(group.representativeFaceId!) {
                group.representativeFaceId = memberEmbeddings[0].faceId
            }
            group.centroidData = memberEmbeddings[0].vectorData
            group.averageSimilarity = 1.0
            group.minSimilarity = 1.0
            group.updatedAt = Date()
            try await libraryStore.saveGroup(group)
            return
        }

        // 1. Calculate centroid: element-wise vector sum followed by L2 normalization
        var accumulator = [Float](repeating: 0.0, count: dim)
        for vec in vectors {
            guard vec.count == dim else { continue }
            vDSP_vadd(accumulator, 1, vec, 1, &accumulator, 1, vDSP_Length(dim))
        }
        let centroid = EmbeddingSimilarityUtility.l2Normalize(accumulator)

        // 2. Select representative face: preserve existing representative face if still valid, otherwise pick closest to centroid
        if let currentRep = group.representativeFaceId, group.memberFaceIds.contains(currentRep) {
            // Preserved user selection
        } else {
            var bestFaceId = memberEmbeddings[0].faceId
            var bestSim: Float = -2.0
            for emb in memberEmbeddings {
                let sim = EmbeddingSimilarityUtility.cosineSimilarity(emb.vector, centroid)
                if sim > bestSim {
                    bestSim = sim
                    bestFaceId = emb.faceId
                }
            }
            group.representativeFaceId = bestFaceId
        }

        // 3. Calculate intra-cluster similarity statistics
        var sumSim: Float = 0.0
        var minSim: Float = 1.0
        var pairCount = 0

        for i in 0..<vectors.count {
            for j in (i + 1)..<vectors.count {
                let sim = EmbeddingSimilarityUtility.cosineSimilarity(vectors[i], vectors[j])
                sumSim += sim
                minSim = min(minSim, sim)
                pairCount += 1
            }
        }

        let avgSim = pairCount > 0 ? (sumSim / Float(pairCount)) : 1.0

        var centroidBytes = Data(count: centroid.count * MemoryLayout<Float>.size)
        centroidBytes.withUnsafeMutableBytes { rawBytes in
            if let base = rawBytes.bindMemory(to: Float.self).baseAddress {
                for i in 0..<centroid.count {
                    base[i] = centroid[i]
                }
            }
        }
        group.centroidData = centroidBytes

        // Select and store diverse identity anchors
        let anchors = EmbeddingSimilarityUtility.selectDiverseAnchors(from: vectors, centroid: centroid, maxAnchors: 4)
        let totalAnchorFloats = anchors.reduce(0) { $0 + $1.count }
        var anchorBytes = Data(count: totalAnchorFloats * MemoryLayout<Float>.size)
        anchorBytes.withUnsafeMutableBytes { rawBytes in
            if let base = rawBytes.bindMemory(to: Float.self).baseAddress {
                var offset = 0
                for a in anchors {
                    for val in a {
                        base[offset] = val
                        offset += 1
                    }
                }
            }
        }
        group.identityAnchorsData = anchorBytes

        group.averageSimilarity = avgSim
        group.minSimilarity = minSim
        group.updatedAt = Date()

        try await libraryStore.saveGroup(group)
    }
}

