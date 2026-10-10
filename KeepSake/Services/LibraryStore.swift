import Foundation

/// Data structure representing the serialized state of the library index on disk.
struct LibraryIndexSnapshot: Codable, Sendable {
    var schemaVersion: Int = 1
    var metadata: LibraryMetadataRecord?
    var photos: [PhotoRecord] = []
    var faces: [FaceRecord] = []
    var embeddings: [EmbeddingRecord] = []
    var groups: [GroupRecord] = []
}

/// Actor-isolated local persistent library store managing atomic reads, writes, and photo reconciliation.
actor LibraryStore {
    /// Shared singleton instance for unified application-wide state access.
    static let shared = LibraryStore()

    private var snapshot: LibraryIndexSnapshot
    private let storageURL: URL
    private let fileManager: FileManager

    /// Default production location in Application Support.
    static var defaultStorageURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = appSupport.appendingPathComponent("KeepSake", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("library_index.json")
    }

    init(storageURL: URL = LibraryStore.defaultStorageURL, fileManager: FileManager = .default) {
        self.storageURL = storageURL
        self.fileManager = fileManager
        let (snap, wasModified) = Self.readSnapshotFromDisk(url: storageURL, fileManager: fileManager)
        self.snapshot = snap
        if wasModified {
            try? persistToDisk()
        }
    }

    /// Explicitly reloads the in-memory snapshot from the backing storage file.
    func reloadFromDisk() {
        let (snap, wasModified) = Self.readSnapshotFromDisk(url: storageURL, fileManager: fileManager)
        self.snapshot = snap
        if wasModified {
            try? persistToDisk()
        }
    }

    // MARK: - Metadata Operations

    func getMetadata() -> LibraryMetadataRecord? {
        return snapshot.metadata
    }

    func saveMetadata(_ metadata: LibraryMetadataRecord) throws {
        snapshot.metadata = metadata
        try persistToDisk()
    }

    // MARK: - Photo Operations

    func getAllPhotos() -> [PhotoRecord] {
        return snapshot.photos
    }

    func getPhoto(byId id: UUID) -> PhotoRecord? {
        return snapshot.photos.first { $0.id == id }
    }

    func getPhoto(byRelativePath relativePath: String) -> PhotoRecord? {
        return snapshot.photos.first { $0.relativePath == relativePath }
    }

    func getPhotos(byState state: PhotoProcessingState) -> [PhotoRecord] {
        return snapshot.photos.filter { $0.processingState == state }
    }

    func savePhoto(_ photo: PhotoRecord) throws {
        if let idx = snapshot.photos.firstIndex(where: { $0.id == photo.id }) {
            snapshot.photos[idx] = photo
        } else {
            snapshot.photos.append(photo)
        }
        try persistToDisk()
    }

    func updatePhotoState(id: UUID, state: PhotoProcessingState, failureReason: String? = nil, detectedFacesCount: Int? = nil) throws {
        if let idx = snapshot.photos.firstIndex(where: { $0.id == id }) {
            snapshot.photos[idx].processingState = state
            snapshot.photos[idx].lastProcessedDate = Date()
            if let reason = failureReason {
                snapshot.photos[idx].failureReason = reason
            }
            if let count = detectedFacesCount {
                snapshot.photos[idx].detectedFacesCount = count
            }
            try persistToDisk()
        }
    }

    // MARK: - Face & Embedding Operations

    func getFaces(forPhotoId photoId: UUID) -> [FaceRecord] {
        return snapshot.faces.filter { $0.photoId == photoId }
    }

    func getAllFaces() -> [FaceRecord] {
        return snapshot.faces
    }

    func saveFaces(_ newFaces: [FaceRecord], forPhotoId photoId: UUID) throws {
        // Clear previous faces and their embeddings for this photo
        let oldFaceIds = Set(snapshot.faces.filter { $0.photoId == photoId }.map { $0.id })
        snapshot.faces.removeAll { $0.photoId == photoId }
        snapshot.embeddings.removeAll { oldFaceIds.contains($0.faceId) || $0.photoId == photoId }
        snapshot.faces.append(contentsOf: newFaces)
        try persistToDisk()
    }

    func getEmbeddings() -> [EmbeddingRecord] {
        return snapshot.embeddings
    }

    func getEmbedding(forFaceId faceId: UUID) -> EmbeddingRecord? {
        return snapshot.embeddings.first { $0.faceId == faceId }
    }

    func saveEmbedding(_ embedding: EmbeddingRecord) throws {
        if let idx = snapshot.embeddings.firstIndex(where: { $0.faceId == embedding.faceId }) {
            snapshot.embeddings[idx] = embedding
        } else {
            snapshot.embeddings.append(embedding)
        }
        try persistToDisk()
    }

    func saveEmbeddings(_ newEmbeddings: [EmbeddingRecord]) throws {
        for emb in newEmbeddings {
            if let idx = snapshot.embeddings.firstIndex(where: { $0.faceId == emb.faceId }) {
                snapshot.embeddings[idx] = emb
            } else {
                snapshot.embeddings.append(emb)
            }
        }
        try persistToDisk()
    }

    // MARK: - Face Group Operations

    func getGroups() -> [GroupRecord] {
        return snapshot.groups
    }

    func getGroup(byId id: UUID) -> GroupRecord? {
        return snapshot.groups.first { $0.id == id }
    }

    func saveGroup(_ group: GroupRecord) throws {
        var groupCopy = group
        let newMemberSet = Set(group.memberFaceIds)

        // Enforce invariant: remove these faces from all other groups
        for idx in snapshot.groups.indices {
            if snapshot.groups[idx].id != group.id {
                snapshot.groups[idx].memberFaceIds.removeAll { newMemberSet.contains($0) }
            }
        }
        // Prune any other groups that became empty
        snapshot.groups.removeAll { $0.id != group.id && $0.memberFaceIds.isEmpty }

        if let idx = snapshot.groups.firstIndex(where: { $0.id == group.id }) {
            snapshot.groups[idx] = groupCopy
        } else {
            snapshot.groups.append(groupCopy)
        }
        try persistToDisk()
    }

    func saveGroups(_ groups: [GroupRecord]) throws {
        var seenFaceIds = Set<UUID>()
        var sanitizedGroups: [GroupRecord] = []

        for group in groups {
            var groupCopy = group
            let uniqueMembers = group.memberFaceIds.filter { seenFaceIds.insert($0).inserted }
            groupCopy.memberFaceIds = uniqueMembers
            // Only keep non-empty groups
            if !uniqueMembers.isEmpty {
                // Ensure representative face is a member
                if let rep = groupCopy.representativeFaceId, !uniqueMembers.contains(rep) {
                    groupCopy.representativeFaceId = uniqueMembers.first
                }
                sanitizedGroups.append(groupCopy)
            }
        }

        snapshot.groups = sanitizedGroups
        try persistToDisk()
    }

    func deleteGroup(byId id: UUID) throws {
        snapshot.groups.removeAll { $0.id == id }
        try persistToDisk()
    }

    func getFace(byId id: UUID) -> FaceRecord? {
        return snapshot.faces.first { $0.id == id }
    }

    func getUngroupedFaces() -> [FaceRecord] {
        var assignedFaceIds = Set<UUID>()
        for group in snapshot.groups {
            for faceId in group.memberFaceIds {
                assignedFaceIds.insert(faceId)
            }
        }
        return snapshot.faces.filter { !assignedFaceIds.contains($0.id) }
    }

    func getPhotos(forGroup groupId: UUID) -> [PhotoRecord] {
        guard let group = snapshot.groups.first(where: { $0.id == groupId }) else { return [] }
        let faceIdSet = Set(group.memberFaceIds)
        let relevantFaces = snapshot.faces.filter { faceIdSet.contains($0.id) }
        let uniquePhotoIds = Set(relevantFaces.map { $0.photoId })
        return snapshot.photos.filter { uniquePhotoIds.contains($0.id) }
    }

    func getUniquePhotoCount(forGroup groupId: UUID) -> Int {
        guard let group = snapshot.groups.first(where: { $0.id == groupId }) else { return 0 }
        let faceIdSet = Set(group.memberFaceIds)
        let relevantFaces = snapshot.faces.filter { faceIdSet.contains($0.id) }
        let uniquePhotoIds = Set(relevantFaces.map { $0.photoId })
        return uniquePhotoIds.count
    }

    func getRepresentativeFace(forGroup groupId: UUID) -> FaceRecord? {
        guard let group = snapshot.groups.first(where: { $0.id == groupId }) else { return nil }
        if let repId = group.representativeFaceId, let face = snapshot.faces.first(where: { $0.id == repId }) {
            return face
        }
        if let firstId = group.memberFaceIds.first, let face = snapshot.faces.first(where: { $0.id == firstId }) {
            return face
        }
        return nil
    }

    func getGroup(forFaceId faceId: UUID) -> GroupRecord? {
        return snapshot.groups.first { $0.memberFaceIds.contains(faceId) }
    }

    func getGroups(forPhotoId photoId: UUID) -> [GroupRecord] {
        let photoFaceIds = Set(snapshot.faces.filter { $0.photoId == photoId }.map { $0.id })
        guard !photoFaceIds.isEmpty else { return [] }
        return snapshot.groups.filter { group in
            group.memberFaceIds.contains { photoFaceIds.contains($0) }
        }
    }

    // MARK: - Reconciliation

    /// Reconciles scanned files on disk against the persistent index.
    /// Identifies NEW, CHANGED, UNCHANGED, and REMOVED photos without running CV/ML.
    func reconcile(scannedPhotos: [PhotoItem], rootFolderURL: URL) throws -> LibraryReconciliationResult {
        let rootPath = rootFolderURL.standardizedFileURL.path
        var existingByPath: [String: PhotoRecord] = [:]
        for p in snapshot.photos {
            existingByPath[p.relativePath] = p
        }

        var newPhotos: [PhotoRecord] = []
        var changedPhotos: [PhotoRecord] = []
        var unchangedPhotos: [PhotoRecord] = []
        var seenRelativePaths = Set<String>()

        for item in scannedPhotos {
            let itemPath = item.url.standardizedFileURL.path
            let relativePath: String
            if itemPath.hasPrefix(rootPath) {
                let suffix = String(itemPath.dropFirst(rootPath.count))
                relativePath = suffix.hasPrefix("/") ? String(suffix.dropFirst()) : suffix
            } else {
                relativePath = item.filename
            }

            seenRelativePaths.insert(relativePath)
            let dateMod = item.dateModified ?? Date(timeIntervalSince1970: 0)

            if let existing = existingByPath[relativePath] {
                // Check if file modified or size changed
                let currentFingerprint = PhotoRecord.computeFingerprint(
                    relativePath: relativePath,
                    fileSize: item.fileSize,
                    modificationDate: dateMod
                )

                if existing.fileFingerprint != currentFingerprint || existing.fileSize != item.fileSize {
                    // CHANGED PHOTO
                    var updated = existing
                    updated.fileSize = item.fileSize
                    updated.modificationDate = dateMod
                    updated.fileFingerprint = currentFingerprint
                    updated.processingState = .needsReprocessing
                    updated.failureReason = nil

                    // Clear stale faces & embeddings for changed photo
                    snapshot.faces.removeAll { $0.photoId == updated.id }
                    snapshot.embeddings.removeAll { $0.photoId == updated.id }

                    if let idx = snapshot.photos.firstIndex(where: { $0.id == updated.id }) {
                        snapshot.photos[idx] = updated
                    }
                    changedPhotos.append(updated)
                } else {
                    // UNCHANGED PHOTO
                    unchangedPhotos.append(existing)
                }
            } else {
                // NEW PHOTO
                let newPhoto = PhotoRecord(
                    relativePath: relativePath,
                    filename: item.filename,
                    fileSize: item.fileSize,
                    modificationDate: dateMod,
                    processingState: .discovered
                )
                snapshot.photos.append(newPhoto)
                newPhotos.append(newPhoto)
            }
        }

        // REMOVED PHOTOS: in index but missing from disk
        var removedPhotos: [PhotoRecord] = []
        var removedPhotoIds: Set<UUID> = []
        for photo in snapshot.photos {
            if !seenRelativePaths.contains(photo.relativePath) {
                removedPhotos.append(photo)
                removedPhotoIds.insert(photo.id)
            }
        }

        if !removedPhotoIds.isEmpty {
            snapshot.photos.removeAll { removedPhotoIds.contains($0.id) }
            snapshot.faces.removeAll { removedPhotoIds.contains($0.photoId) }
            snapshot.embeddings.removeAll { removedPhotoIds.contains($0.photoId) }
        }

        Self.sanitizeSnapshot(&snapshot)
        try persistToDisk()

        return LibraryReconciliationResult(
            newPhotos: newPhotos,
            changedPhotos: changedPhotos,
            unchangedPhotos: unchangedPhotos,
            removedPhotos: removedPhotos
        )
    }

    // MARK: - Persistence & Serialization

    /// Enforces referential integrity across photos, faces, embeddings, and groups.
    @discardableResult
    static func sanitizeSnapshot(_ snapshot: inout LibraryIndexSnapshot) -> Bool {
        let initialFaces = snapshot.faces.count
        let initialEmbeddings = snapshot.embeddings.count
        let initialGroups = snapshot.groups.count
        let initialMemberships = snapshot.groups.reduce(0) { $0 + $1.memberFaceIds.count }

        if !snapshot.photos.isEmpty {
            let validPhotoIds = Set(snapshot.photos.map(\.id))
            snapshot.faces.removeAll { !validPhotoIds.contains($0.photoId) }

            let validFaceIds = Set(snapshot.faces.map(\.id))
            snapshot.embeddings.removeAll { !validFaceIds.contains($0.faceId) || !validPhotoIds.contains($0.photoId) }

            var seenFaceIds = Set<UUID>()
            var sanitizedGroups: [GroupRecord] = []
            for group in snapshot.groups {
                var groupCopy = group
                let activeMembers = group.memberFaceIds.filter { validFaceIds.contains($0) && seenFaceIds.insert($0).inserted }
                groupCopy.memberFaceIds = activeMembers
                if !activeMembers.isEmpty {
                    if let rep = groupCopy.representativeFaceId, !activeMembers.contains(rep) {
                        groupCopy.representativeFaceId = activeMembers.first
                    }
                    sanitizedGroups.append(groupCopy)
                }
            }
            snapshot.groups = sanitizedGroups
        } else {
            var seenFaceIds = Set<UUID>()
            var sanitizedGroups: [GroupRecord] = []
            for group in snapshot.groups {
                var groupCopy = group
                let uniqueMembers = group.memberFaceIds.filter { seenFaceIds.insert($0).inserted }
                groupCopy.memberFaceIds = uniqueMembers
                if !uniqueMembers.isEmpty {
                    sanitizedGroups.append(groupCopy)
                }
            }
            snapshot.groups = sanitizedGroups
        }

        let finalMemberships = snapshot.groups.reduce(0) { $0 + $1.memberFaceIds.count }
        return snapshot.faces.count != initialFaces ||
               snapshot.embeddings.count != initialEmbeddings ||
               snapshot.groups.count != initialGroups ||
               finalMemberships != initialMemberships
    }

    private static func readSnapshotFromDisk(url: URL, fileManager: FileManager) -> (snapshot: LibraryIndexSnapshot, wasModified: Bool) {
        guard fileManager.fileExists(atPath: url.path) else {
            return (LibraryIndexSnapshot(), false)
        }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var snap = try decoder.decode(LibraryIndexSnapshot.self, from: data)
            let wasModified = Self.sanitizeSnapshot(&snap)
            return (snap, wasModified)
        } catch {
            print("Failed to load library index from \(url.path): \(error.localizedDescription)")
            return (LibraryIndexSnapshot(), false)
        }
    }

    private func persistToDisk() throws {
        let parentDir = storageURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parentDir.path) {
            try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: storageURL, options: .atomic)
    }

    /// Clears the entire in-memory snapshot and deletes the file from disk (useful for tests/reset).
    func reset() throws {
        self.snapshot = LibraryIndexSnapshot()
        if fileManager.fileExists(atPath: storageURL.path) {
            try fileManager.removeItem(at: storageURL)
        }
    }

    // MARK: - Diagnostics & Integrity Validation

    /// Evaluates invariant correctness across all persistent records.
    func validateIntegrity() -> LibraryIntegrityReport {
        let validPhotoIds = Set(snapshot.photos.map(\.id))
        let activeFaceIds = Set(snapshot.faces.map(\.id))
        let totalUniqueFaceIds = activeFaceIds.count
        let totalUniqueGroupIds = Set(snapshot.groups.map(\.id)).count

        var faceGroupCounts: [UUID: Int] = [:]
        var duplicateMemberships = 0

        for group in snapshot.groups {
            var seenInGroup = Set<UUID>()
            for faceId in group.memberFaceIds {
                faceGroupCounts[faceId, default: 0] += 1
                if !seenInGroup.insert(faceId).inserted {
                    duplicateMemberships += 1
                }
            }
        }

        let facesInMultipleGroups = faceGroupCounts.values.filter { $0 > 1 }.count
        let orphanedEmbeddings = snapshot.embeddings.filter { !activeFaceIds.contains($0.faceId) || (!validPhotoIds.isEmpty && !validPhotoIds.contains($0.photoId)) }.count
        let orphanedFaces = validPhotoIds.isEmpty ? 0 : snapshot.faces.filter { !validPhotoIds.contains($0.photoId) }.count
        let emptyGroups = snapshot.groups.filter { $0.memberFaceIds.isEmpty }.count

        return LibraryIntegrityReport(
            totalPhotos: snapshot.photos.count,
            totalDetectedFaces: snapshot.faces.count,
            totalEmbeddings: snapshot.embeddings.count,
            totalUniqueFaceIds: totalUniqueFaceIds,
            totalUniqueGroupIds: totalUniqueGroupIds,
            facesAssignedToMultipleGroupsCount: facesInMultipleGroups,
            duplicateGroupMembershipsCount: duplicateMemberships,
            orphanedEmbeddingsCount: orphanedEmbeddings,
            orphanedFacesCount: orphanedFaces,
            emptyGroupsCount: emptyGroups
        )
    }

    /// Prunes any orphaned faces, orphaned embeddings, and duplicate group memberships.
    func pruneOrphanedRecords() throws {
        Self.sanitizeSnapshot(&snapshot)
        try persistToDisk()
    }
}

/// Diagnostic integrity report evaluating invariant correctness across all persistent records.
struct LibraryIntegrityReport: Sendable {
    let totalPhotos: Int
    let totalDetectedFaces: Int
    let totalEmbeddings: Int
    let totalUniqueFaceIds: Int
    let totalUniqueGroupIds: Int
    let facesAssignedToMultipleGroupsCount: Int
    let duplicateGroupMembershipsCount: Int
    let orphanedEmbeddingsCount: Int
    var orphanedFacesCount: Int = 0
    var emptyGroupsCount: Int = 0

    var isValid: Bool {
        return facesAssignedToMultipleGroupsCount == 0 &&
               duplicateGroupMembershipsCount == 0 &&
               orphanedEmbeddingsCount == 0 &&
               orphanedFacesCount == 0 &&
               emptyGroupsCount == 0
    }
}
