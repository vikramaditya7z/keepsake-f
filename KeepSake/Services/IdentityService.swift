import Foundation
import CoreGraphics
import Accelerate

/// Errors that can occur during identity and group management operations.
enum IdentityServiceError: LocalizedError {
    case groupNotFound(UUID)
    case faceNotFound(UUID)
    case personNotFound(UUID)
    case invalidGroupName
    case cannotMergeGroupIntoItself
    case faceAlreadyInTargetGroup
    case cannotLinkViolation(String)

    var errorDescription: String? {
        switch self {
        case .groupNotFound(let id):
            return "Group with ID \(id) was not found."
        case .faceNotFound(let id):
            return "Face with ID \(id) was not found."
        case .personNotFound(let id):
            return "Person with ID \(id) was not found."
        case .invalidGroupName:
            return "Group name cannot be empty."
        case .cannotMergeGroupIntoItself:
            return "Cannot merge a person into themselves."
        case .faceAlreadyInTargetGroup:
            return "Face is already a member of the target group."
        case .cannotLinkViolation(let reason):
            return "Cannot-Link violation: \(reason)"
        }
    }
}

/// Protocol defining person identity and group management operations.
protocol IdentityServiceProtocol: Sendable {
    func fetchGroups() async -> [GroupRecord]
    func fetchCandidateGroups() async -> [GroupRecord]
    func fetchCandidateGroups(rootFolderURL: URL?) async -> [GroupRecord]
    func fetchConfirmedPeople() async -> [GroupRecord]
    func confirmGroup(id: UUID, name: String?) async throws -> GroupRecord
    func rejectCandidateGroup(id: UUID) async throws
    func restoreFaceToCandidateSuggestion(faceId: UUID, rootFolderURL: URL?) async throws -> GroupRecord
    func restoreFacesToCandidateSuggestion(faceIds: [UUID], rootFolderURL: URL?) async throws -> [GroupRecord]
    func fetchGroup(byId id: UUID) async -> GroupRecord?
    func renameGroup(id: UUID, newName: String) async throws
    func mergeGroups(targetGroupId: UUID, sourceGroupId: UUID) async throws
    func removeFaceFromGroup(faceId: UUID, groupId: UUID) async throws
    func assignFaceToGroup(faceId: UUID, targetGroupId: UUID) async throws
    func createNewGroup(withFaceId faceId: UUID, name: String?) async throws -> GroupRecord
    func deleteGroup(id: UUID) async throws
    func fetchUngroupedFaces() async -> [FaceRecord]
    func fetchUngroupedFaces(rootFolderURL: URL?) async -> [FaceRecord]
    func recalculateGroupMetadata(groupId: UUID) async throws
    func fetchPhotos(forGroupId groupId: UUID, rootFolderURL: URL?) async -> [PhotoItem]
    func fetchUniquePhotoCount(forGroupId groupId: UUID) async -> Int
    func fetchUniquePhotoCount(forGroupId groupId: UUID, rootFolderURL: URL?) async -> Int
    func fetchRepresentativeFace(forGroupId groupId: UUID) async -> (face: FaceRecord?, photo: PhotoRecord?)
    func fetchRepresentativeFace(forGroupId groupId: UUID, rootFolderURL: URL?) async -> (face: FaceRecord?, photo: PhotoRecord?)
    func fetchFaces(forGroupId groupId: UUID, rootFolderURL: URL?) async -> [FaceRecord]
    func setRepresentativeFace(groupId: UUID, faceId: UUID) async throws
    func setCoverFace(personId: UUID, faceId: UUID) async throws

    // Central People Database & V7 Identity Correction Operations
    func fetchPeople() async -> [PersonRecord]
    func fetchPerson(byId id: UUID) async -> PersonRecord?
    func savePerson(_ person: PersonRecord) async throws
    func deletePerson(id: UUID) async throws
    func renamePerson(id: UUID, newName: String) async throws
    func mergePeople(targetPersonId: UUID, sourcePersonId: UUID) async throws
    func removeFaceFromPerson(faceId: UUID, personId: UUID) async throws
    func moveFace(faceId: UUID, fromPersonId: UUID, toPersonId: UUID) async throws
    func bulkAssignFaces(faceIds: [UUID], targetPersonId: UUID) async throws
    func bulkCreatePerson(withFaceIds faceIds: [UUID], name: String?, rootFolderURL: URL?) async throws -> PersonRecord
    func removeFaceFromCandidateGroup(faceId: UUID, groupId: UUID) async throws

    // False Face Detection & Recycle Bin Operations
    func excludeFace(faceId: UUID, reason: String) async throws
    func restoreFace(faceId: UUID) async throws
    func permanentlyDeleteFace(faceId: UUID) async throws
    func fetchExcludedFaces(rootFolderURL: URL?) async -> [FaceRecord]

    // Removed from People (Recycle Bin Category B)
    func removeFaceToRecycleBin(faceId: UUID, personId: UUID, reason: String?) async throws
    func restoreRemovedAssociationToPerson(associationId: UUID) async throws
    func restoreRemovedAssociationToUnassigned(associationId: UUID) async throws
    func permanentlyDeleteRemovedAssociation(associationId: UUID) async throws
    func fetchRemovedAssociations(rootFolderURL: URL?) async -> [RemovedFaceAssociationRecord]
    func restoreAllRemovedAssociationsToUnassigned(rootFolderURL: URL?) async throws
    func emptyRemovedAssociationsBin(rootFolderURL: URL?) async throws
}

/// Concrete service orchestrating user-driven identity operations, referential integrity, and metadata maintenance.
final class IdentityService: IdentityServiceProtocol {
    private let libraryStore: LibraryStore

    init(libraryStore: LibraryStore = LibraryStore.shared) {
        self.libraryStore = libraryStore
    }

    // MARK: - Central People Database

    func fetchPeople() async -> [PersonRecord] {
        return await libraryStore.getAllPeople()
    }

    func fetchPerson(byId id: UUID) async -> PersonRecord? {
        return await libraryStore.getPerson(byId: id)
    }

    func savePerson(_ person: PersonRecord) async throws {
        try await libraryStore.savePerson(person)
    }

    func deletePerson(id: UUID) async throws {
        try await libraryStore.deletePerson(byId: id)
        try await libraryStore.deleteGroup(byId: id)
    }

    func renamePerson(id: UUID, newName: String) async throws {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if var person = await libraryStore.getPerson(byId: id) {
            person.name = trimmed.isEmpty ? "Person" : trimmed
            person.updatedAt = Date()
            try await libraryStore.savePerson(person)
        }
        if let group = await libraryStore.getGroup(byId: id) {
            var updatedGroup = group
            updatedGroup.customName = trimmed.isEmpty ? nil : trimmed
            updatedGroup.updatedAt = Date()
            try await libraryStore.saveGroup(updatedGroup)
        }
    }

    func fetchGroups() async -> [GroupRecord] {
        return await libraryStore.getGroups()
    }

    func fetchCandidateGroups() async -> [GroupRecord] {
        let all = await libraryStore.getGroups()
        return all.filter { $0.reviewStatus == .candidateSuggestion }
    }

    func fetchCandidateGroups(rootFolderURL: URL?) async -> [GroupRecord] {
        let rootPath = rootFolderURL?.standardizedFileURL.path
        return await libraryStore.getCandidateGroups(forRootFolderPath: rootPath)
    }

    func fetchConfirmedPeople() async -> [GroupRecord] {
        let all = await libraryStore.getGroups()
        return all.filter { $0.reviewStatus == .confirmed }
    }

    func confirmGroup(id: UUID, name: String? = nil) async throws -> GroupRecord {
        guard let group = await libraryStore.getGroup(byId: id) else {
            throw IdentityServiceError.groupNotFound(id)
        }
        var updated = group
        updated.reviewStatus = .confirmed
        if let newName = name?.trimmingCharacters(in: .whitespacesAndNewlines), !newName.isEmpty {
            updated.customName = newName
        }
        updated.updatedAt = Date()
        try await libraryStore.saveGroup(updated)

        // Sync to central PersonRecord database
        let person = PersonRecord(
            id: updated.id,
            name: updated.displayName,
            representativeFaceId: updated.representativeFaceId,
            confirmedFaceIds: updated.memberFaceIds,
            centroidData: updated.centroidData,
            identityAnchorsData: updated.identityAnchorsData,
            createdAt: updated.createdAt,
            updatedAt: Date(),
            isDeactivated: false
        )
        try await libraryStore.savePerson(person)

        return updated
    }

    func rejectCandidateGroup(id: UUID) async throws {
        guard let group = await libraryStore.getGroup(byId: id) else {
            throw IdentityServiceError.groupNotFound(id)
        }
        var updated = group
        updated.reviewStatus = .rejected
        updated.updatedAt = Date()
        try await libraryStore.saveGroup(updated)
    }

    func restoreFaceToCandidateSuggestion(faceId: UUID, rootFolderURL: URL?) async throws -> GroupRecord {
        let groups = try await restoreFacesToCandidateSuggestion(faceIds: [faceId], rootFolderURL: rootFolderURL)
        guard let first = groups.first else {
            throw IdentityServiceError.faceNotFound(faceId)
        }
        return first
    }

    func restoreFacesToCandidateSuggestion(faceIds: [UUID], rootFolderURL: URL?) async throws -> [GroupRecord] {
        guard !faceIds.isEmpty else {
            throw IdentityServiceError.invalidGroupName
        }

        let allFaces = await libraryStore.getAllFaces()
        let faceMap = Dictionary(uniqueKeysWithValues: allFaces.map { ($0.id, $0) })

        // Verify all faceIds exist
        for fId in faceIds {
            guard faceMap[fId] != nil else {
                throw IdentityServiceError.faceNotFound(fId)
            }
        }

        // 1. Clean up exclusions and removed associations for all selected faces (reuse existing restoration logic)
        for fId in faceIds {
            try await libraryStore.restoreFace(faceId: fId)
        }
        let existingAssocs = await libraryStore.getRemovedAssociations()
        for assoc in existingAssocs where faceIds.contains(assoc.faceId) {
            try await libraryStore.restoreRemovedAssociationToUnassigned(associationId: assoc.id)
        }

        // 2. Determine root folder path for folder scoping
        var effectiveRootPath: String? = rootFolderURL?.standardizedFileURL.path
        if effectiveRootPath == nil {
            if let firstFace = faceMap[faceIds[0]],
               let photo = await libraryStore.getPhoto(byId: firstFace.photoId) {
                effectiveRootPath = photo.rootFolderPath
            }
        }

        // 3. Partition faces into separate valid candidate groups preserving Cannot-Link:
        // Never place multiple faces from the same photograph into the same candidate group.
        var facesByPhoto: [UUID: [UUID]] = [:]
        for fId in faceIds {
            if let face = faceMap[fId] {
                facesByPhoto[face.photoId, default: []].append(fId)
            }
        }

        // Sort photo groups descending by face count for balanced bin distribution
        let sortedPhotoGroups = facesByPhoto.values.sorted { $0.count > $1.count }

        var candidateBuckets: [[UUID]] = []
        var bucketPhotoSets: [Set<UUID>] = []

        for photoFaceList in sortedPhotoGroups {
            for fId in photoFaceList {
                guard let face = faceMap[fId] else { continue }
                let photoId = face.photoId

                var placed = false
                for idx in candidateBuckets.indices {
                    if !bucketPhotoSets[idx].contains(photoId) {
                        candidateBuckets[idx].append(fId)
                        bucketPhotoSets[idx].insert(photoId)
                        placed = true
                        break
                    }
                }

                if !placed {
                    candidateBuckets.append([fId])
                    bucketPhotoSets.append([photoId])
                }
            }
        }

        // 4. Create or reuse candidate groups for each partitioned bucket
        var resultGroups: [GroupRecord] = []
        var existingGroups = await libraryStore.getGroups()

        for bucket in candidateBuckets {
            // Check if there is already an existing candidate suggestion containing solely these exact faces
            if let existing = existingGroups.first(where: {
                $0.reviewStatus == .candidateSuggestion &&
                Set($0.memberFaceIds) == Set(bucket)
            }) {
                resultGroups.append(existing)
                continue
            }

            let maxIndex = existingGroups.map(\.groupIndex).max() ?? 0
            let nextIndex = maxIndex + 1

            let newId = UUID()
            let candidateGroup = GroupRecord(
                id: newId,
                groupIndex: nextIndex,
                customName: nil,
                coverFaceId: bucket.first,
                representativeFaceId: bucket.first,
                memberFaceIds: bucket,
                averageSimilarity: 1.0,
                minSimilarity: 1.0,
                thresholdUsed: 0.54,
                algorithmName: "User Restore to Suggestions",
                algorithmVersion: "v2",
                reviewStatus: .candidateSuggestion,
                rootFolderPath: effectiveRootPath,
                createdAt: Date(),
                updatedAt: Date()
            )

            try await libraryStore.saveGroup(candidateGroup)
            try await recalculateGroupMetadata(groupId: newId)

            let savedGroup = (await libraryStore.getGroup(byId: newId)) ?? candidateGroup
            resultGroups.append(savedGroup)

            existingGroups = await libraryStore.getGroups()
        }

        return resultGroups
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

        // Sync name to central PersonRecord if present
        if var person = await libraryStore.getPerson(byId: id) {
            person.name = updated.displayName
            person.updatedAt = Date()
            try await libraryStore.savePerson(person)
        }
    }

    func mergePeople(targetPersonId: UUID, sourcePersonId: UUID) async throws {
        guard targetPersonId != sourcePersonId else {
            throw IdentityServiceError.cannotMergeGroupIntoItself
        }
        guard let targetPerson = await libraryStore.getPerson(byId: targetPersonId) else {
            throw IdentityServiceError.personNotFound(targetPersonId)
        }
        guard let sourcePerson = await libraryStore.getPerson(byId: sourcePersonId) else {
            throw IdentityServiceError.personNotFound(sourcePersonId)
        }

        // Cannot-Link check: verify no photo contains faces from both target and source
        let allFaces = await libraryStore.getAllFaces()
        let faceMap = Dictionary(uniqueKeysWithValues: allFaces.map { ($0.id, $0) })
        let targetPhotos = Set(targetPerson.confirmedFaceIds.compactMap { faceMap[$0]?.photoId })
        let sourcePhotos = Set(sourcePerson.confirmedFaceIds.compactMap { faceMap[$0]?.photoId })
        let conflictingPhotos = targetPhotos.intersection(sourcePhotos)
        if !conflictingPhotos.isEmpty {
            throw IdentityServiceError.cannotLinkViolation("Cannot merge \"\(sourcePerson.name)\" into \"\(targetPerson.name)\" because both appear in the same photograph.")
        }

        try await libraryStore.mergePeople(targetPersonId: targetPersonId, sourcePersonId: sourcePersonId)
        try await recalculateGroupMetadata(groupId: targetPersonId)
    }

    func mergeGroups(targetGroupId: UUID, sourceGroupId: UUID) async throws {
        guard targetGroupId != sourceGroupId else {
            throw IdentityServiceError.cannotMergeGroupIntoItself
        }

        // If these correspond to central PersonRecords, merge through authoritative Person store
        let hasTargetPerson = (await libraryStore.getPerson(byId: targetGroupId)) != nil
        let hasSourcePerson = (await libraryStore.getPerson(byId: sourceGroupId)) != nil
        if hasTargetPerson && hasSourcePerson {
            try await mergePeople(targetPersonId: targetGroupId, sourcePersonId: sourceGroupId)
            return
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

    func removeFaceFromPerson(faceId: UUID, personId: UUID) async throws {
        try await libraryStore.removeFaceFromPerson(personId: personId, faceId: faceId)
        if let remainingPerson = await libraryStore.getPerson(byId: personId), !remainingPerson.confirmedFaceIds.isEmpty {
            try await recalculateGroupMetadata(groupId: personId)
        }
    }

    func moveFace(faceId: UUID, fromPersonId: UUID, toPersonId: UUID) async throws {
        guard fromPersonId != toPersonId else { return }
        guard (await libraryStore.getPerson(byId: fromPersonId)) != nil else {
            throw IdentityServiceError.personNotFound(fromPersonId)
        }
        guard let targetPerson = await libraryStore.getPerson(byId: toPersonId) else {
            throw IdentityServiceError.personNotFound(toPersonId)
        }

        // Cannot-Link check: verify target person does not already have a face from the same photo
        if let face = await libraryStore.getFace(byId: faceId) {
            let targetFaces = (await libraryStore.getAllFaces()).filter { targetPerson.confirmedFaceIds.contains($0.id) }
            if targetFaces.contains(where: { $0.photoId == face.photoId }) {
                throw IdentityServiceError.cannotLinkViolation("Target person already has a face detected in photo \(face.photoId)")
            }
        }

        try await libraryStore.removeFaceFromPerson(personId: fromPersonId, faceId: faceId)
        try await libraryStore.assignFacesToPerson(personId: toPersonId, faceIds: [faceId])
        try await recalculateGroupMetadata(groupId: fromPersonId)
        try await recalculateGroupMetadata(groupId: toPersonId)
    }

    func bulkAssignFaces(faceIds: [UUID], targetPersonId: UUID) async throws {
        guard let targetPerson = await libraryStore.getPerson(byId: targetPersonId), !targetPerson.isDeactivated else {
            throw IdentityServiceError.personNotFound(targetPersonId)
        }

        let newFaceIds = faceIds.filter { !targetPerson.confirmedFaceIds.contains($0) }
        guard !newFaceIds.isEmpty else { return }

        let allFaces = await libraryStore.getAllFaces()
        let faceMap = Dictionary(uniqueKeysWithValues: allFaces.map { ($0.id, $0) })

        // 1. Check Cannot-Link among selected faceIds (no two faces from same photo)
        var seenPhotoIds = Set<UUID>()
        for fId in newFaceIds {
            guard let face = faceMap[fId] else {
                throw IdentityServiceError.faceNotFound(fId)
            }
            if !seenPhotoIds.insert(face.photoId).inserted {
                throw IdentityServiceError.cannotLinkViolation("Two or more selected faces belong to the same photograph")
            }
        }

        // 2. Check Cannot-Link against target person's existing faces
        let existingFacePhotos = Set(targetPerson.confirmedFaceIds.compactMap { faceMap[$0]?.photoId })
        for fId in newFaceIds {
            if let face = faceMap[fId], existingFacePhotos.contains(face.photoId) {
                throw IdentityServiceError.cannotLinkViolation("Selected face belongs to a photo already containing a face of \(targetPerson.name)")
            }
        }

        try await libraryStore.assignFacesToPerson(personId: targetPersonId, faceIds: newFaceIds)
        try await recalculateGroupMetadata(groupId: targetPersonId)
    }

    func bulkCreatePerson(withFaceIds faceIds: [UUID], name: String?, rootFolderURL: URL?) async throws -> PersonRecord {
        guard !faceIds.isEmpty else {
            throw IdentityServiceError.invalidGroupName
        }

        let allFaces = await libraryStore.getAllFaces()
        let faceMap = Dictionary(uniqueKeysWithValues: allFaces.map { ($0.id, $0) })

        // Check Cannot-Link among selected faceIds
        var seenPhotoIds = Set<UUID>()
        for fId in faceIds {
            guard let face = faceMap[fId] else {
                throw IdentityServiceError.faceNotFound(fId)
            }
            if !seenPhotoIds.insert(face.photoId).inserted {
                throw IdentityServiceError.cannotLinkViolation("Two or more selected faces belong to the same photograph")
            }
        }

        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let personName = (trimmedName?.isEmpty == false) ? trimmedName! : "Person"

        let newId = UUID()
        let newPerson = PersonRecord(
            id: newId,
            name: personName,
            representativeFaceId: faceIds.first,
            confirmedFaceIds: faceIds,
            createdAt: Date(),
            updatedAt: Date(),
            isDeactivated: false
        )

        try await libraryStore.savePerson(newPerson)
        try await libraryStore.assignFacesToPerson(personId: newId, faceIds: faceIds)
        try await recalculateGroupMetadata(groupId: newId)

        return (await libraryStore.getPerson(byId: newId)) ?? newPerson
    }

    func removeFaceFromCandidateGroup(faceId: UUID, groupId: UUID) async throws {
        guard let group = await libraryStore.getGroup(byId: groupId) else {
            throw IdentityServiceError.groupNotFound(groupId)
        }

        var updatedMembers = group.memberFaceIds
        updatedMembers.removeAll { $0 == faceId }

        if updatedMembers.isEmpty {
            try await libraryStore.deleteGroup(byId: groupId)
        } else {
            var updated = group
            updated.memberFaceIds = updatedMembers
            if updated.representativeFaceId == faceId {
                updated.representativeFaceId = updatedMembers.first
            }
            updated.updatedAt = Date()
            try await libraryStore.saveGroup(updated)
            try await recalculateGroupMetadata(groupId: groupId)
        }
    }

    func removeFaceFromGroup(faceId: UUID, groupId: UUID) async throws {
        // If this group is associated with a central PersonRecord, remove from person
        if (await libraryStore.getPerson(byId: groupId)) != nil {
            try await removeFaceFromPerson(faceId: faceId, personId: groupId)
            return
        }

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
        // If targetGroupId is a PersonRecord in central database, route through authoritative person assign
        if (await libraryStore.getPerson(byId: targetGroupId)) != nil {
            try await bulkAssignFaces(faceIds: [faceId], targetPersonId: targetGroupId)
            return
        }

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
            thresholdUsed: 0.65,
            reviewStatus: .confirmed
        )

        try await libraryStore.saveGroup(newGroup)
        try await recalculateGroupMetadata(groupId: newGroup.id)

        let refreshedGroup = (await libraryStore.getGroup(byId: newGroup.id)) ?? newGroup
        let person = PersonRecord(
            id: refreshedGroup.id,
            name: refreshedGroup.displayName,
            representativeFaceId: refreshedGroup.representativeFaceId,
            confirmedFaceIds: refreshedGroup.memberFaceIds,
            centroidData: refreshedGroup.centroidData,
            identityAnchorsData: refreshedGroup.identityAnchorsData,
            createdAt: refreshedGroup.createdAt,
            updatedAt: Date(),
            isDeactivated: false
        )
        try await libraryStore.savePerson(person)

        return refreshedGroup
    }

    func deleteGroup(id: UUID) async throws {
        // Deleting a group disassociates its faces back to unassigned state
        // and safely removes the person from the central database.
        try await libraryStore.deletePerson(byId: id)
        try await libraryStore.deleteGroup(byId: id)
    }

    func fetchUngroupedFaces() async -> [FaceRecord] {
        return await libraryStore.getUngroupedFaces()
    }

    func fetchUngroupedFaces(rootFolderURL: URL?) async -> [FaceRecord] {
        let rootPath = rootFolderURL?.standardizedFileURL.path
        return await libraryStore.getUngroupedFaces(forRootFolderPath: rootPath)
    }

    func fetchUniquePhotoCount(forGroupId groupId: UUID) async -> Int {
        return await libraryStore.getUniquePhotoCount(forGroup: groupId, rootFolderPath: nil)
    }

    func fetchUniquePhotoCount(forGroupId groupId: UUID, rootFolderURL: URL?) async -> Int {
        let rootPath = rootFolderURL?.standardizedFileURL.path
        return await libraryStore.getUniquePhotoCount(forGroup: groupId, rootFolderPath: rootPath)
    }

    func fetchPhotos(forGroupId groupId: UUID, rootFolderURL: URL?) async -> [PhotoItem] {
        let rootPath = rootFolderURL?.standardizedFileURL.path
        let photoRecords = await libraryStore.getPhotos(forGroup: groupId, rootFolderPath: rootPath)
        return photoRecords.map { rec in
            let fullURL: URL
            if let photoRoot = rec.rootFolderPath {
                fullURL = URL(fileURLWithPath: photoRoot).appendingPathComponent(rec.relativePath)
            } else if let rootURL = rootFolderURL {
                fullURL = rootURL.appendingPathComponent(rec.relativePath)
            } else {
                fullURL = URL(fileURLWithPath: rec.relativePath)
            }
            return PhotoItem(id: rec.id, url: fullURL, fileSize: rec.fileSize, dateModified: rec.modificationDate)
        }
    }

    func fetchRepresentativeFace(forGroupId groupId: UUID) async -> (face: FaceRecord?, photo: PhotoRecord?) {
        return await fetchRepresentativeFace(forGroupId: groupId, rootFolderURL: nil)
    }

    func fetchRepresentativeFace(forGroupId groupId: UUID, rootFolderURL: URL?) async -> (face: FaceRecord?, photo: PhotoRecord?) {
        let rootPath = rootFolderURL?.standardizedFileURL.path
        guard let face = await libraryStore.getRepresentativeFace(forGroup: groupId, rootFolderPath: rootPath) else {
            return (nil, nil)
        }
        let photo = await libraryStore.getPhoto(byId: face.photoId)
        return (face, photo)
    }

    func fetchFaces(forGroupId groupId: UUID, rootFolderURL: URL?) async -> [FaceRecord] {
        let rootPath = rootFolderURL?.standardizedFileURL.path
        return await libraryStore.getFaces(forGroup: groupId, rootFolderPath: rootPath)
    }

    func setCoverFace(personId: UUID, faceId: UUID) async throws {
        try await libraryStore.setCoverFace(personId: personId, faceId: faceId)
    }

    func setRepresentativeFace(groupId: UUID, faceId: UUID) async throws {
        try await libraryStore.setCoverFace(personId: groupId, faceId: faceId)
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

        // Sync updated centroid, anchors, representative face and confirmed face IDs back to PersonRecord if present
        if var person = await libraryStore.getPerson(byId: groupId) {
            person.centroidData = group.centroidData
            person.identityAnchorsData = group.identityAnchorsData
            person.representativeFaceId = group.representativeFaceId
            person.confirmedFaceIds = group.memberFaceIds
            person.updatedAt = Date()
            try? await libraryStore.savePerson(person)
        }
    }

    // MARK: - False Face Detection & Recycle Bin

    func excludeFace(faceId: UUID, reason: String = "falseDetection") async throws {
        try await libraryStore.excludeFace(faceId: faceId, reason: reason)
    }

    func restoreFace(faceId: UUID) async throws {
        try await libraryStore.restoreFace(faceId: faceId)
    }

    func permanentlyDeleteFace(faceId: UUID) async throws {
        try await libraryStore.permanentlyDeleteFace(faceId: faceId)
    }

    func fetchExcludedFaces(rootFolderURL: URL? = nil) async -> [FaceRecord] {
        let rootPath = rootFolderURL?.standardizedFileURL.path
        return await libraryStore.getExcludedFaces(forRootFolderPath: rootPath)
    }

    // MARK: - Removed from People (Recycle Bin Category B)

    func removeFaceToRecycleBin(faceId: UUID, personId: UUID, reason: String? = nil) async throws {
        try await libraryStore.removeFaceToRecycleBin(faceId: faceId, personId: personId, reason: reason)
        try await recalculateGroupMetadata(groupId: personId)
    }

    func restoreRemovedAssociationToPerson(associationId: UUID) async throws {
        try await libraryStore.restoreRemovedAssociationToPerson(associationId: associationId)
    }

    func restoreRemovedAssociationToUnassigned(associationId: UUID) async throws {
        try await libraryStore.restoreRemovedAssociationToUnassigned(associationId: associationId)
    }

    func permanentlyDeleteRemovedAssociation(associationId: UUID) async throws {
        try await libraryStore.permanentlyDeleteRemovedAssociation(associationId: associationId)
    }

    func fetchRemovedAssociations(rootFolderURL: URL? = nil) async -> [RemovedFaceAssociationRecord] {
        let rootPath = rootFolderURL?.standardizedFileURL.path
        return await libraryStore.getRemovedAssociations(forRootFolderPath: rootPath)
    }

    func restoreAllRemovedAssociationsToUnassigned(rootFolderURL: URL? = nil) async throws {
        let rootPath = rootFolderURL?.standardizedFileURL.path
        try await libraryStore.restoreAllRemovedAssociationsToUnassigned(forRootFolderPath: rootPath)
    }

    func emptyRemovedAssociationsBin(rootFolderURL: URL? = nil) async throws {
        let rootPath = rootFolderURL?.standardizedFileURL.path
        try await libraryStore.emptyRemovedAssociationsBin(forRootFolderPath: rootPath)
    }
}

