import Foundation

/// Data structure representing the serialized state of the library index on disk.
struct LibraryIndexSnapshot: Codable, Sendable {
    var schemaVersion: Int = 2
    var metadata: LibraryMetadataRecord?
    var photos: [PhotoRecord] = []
    var faces: [FaceRecord] = []
    var embeddings: [EmbeddingRecord] = []
    var groups: [GroupRecord] = []
    var people: [PersonRecord] = []
    var excludedFaceIds: [UUID] = []
    var removedAssociations: [RemovedFaceAssociationRecord] = []

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case metadata
        case photos
        case faces
        case embeddings
        case groups
        case people
        case excludedFaceIds
        case removedAssociations
    }

    init(
        schemaVersion: Int = 2,
        metadata: LibraryMetadataRecord? = nil,
        photos: [PhotoRecord] = [],
        faces: [FaceRecord] = [],
        embeddings: [EmbeddingRecord] = [],
        groups: [GroupRecord] = [],
        people: [PersonRecord] = [],
        excludedFaceIds: [UUID] = [],
        removedAssociations: [RemovedFaceAssociationRecord] = []
    ) {
        self.schemaVersion = schemaVersion
        self.metadata = metadata
        self.photos = photos
        self.faces = faces
        self.embeddings = embeddings
        self.groups = groups
        self.people = people
        self.excludedFaceIds = excludedFaceIds
        self.removedAssociations = removedAssociations
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        self.metadata = try container.decodeIfPresent(LibraryMetadataRecord.self, forKey: .metadata)
        self.photos = try container.decodeIfPresent([PhotoRecord].self, forKey: .photos) ?? []
        self.faces = try container.decodeIfPresent([FaceRecord].self, forKey: .faces) ?? []
        self.embeddings = try container.decodeIfPresent([EmbeddingRecord].self, forKey: .embeddings) ?? []
        self.groups = try container.decodeIfPresent([GroupRecord].self, forKey: .groups) ?? []
        self.people = try container.decodeIfPresent([PersonRecord].self, forKey: .people) ?? []
        self.excludedFaceIds = try container.decodeIfPresent([UUID].self, forKey: .excludedFaceIds) ?? []
        self.removedAssociations = try container.decodeIfPresent([RemovedFaceAssociationRecord].self, forKey: .removedAssociations) ?? []
    }
}

/// Actor-isolated local persistent library store managing atomic reads, writes, and photo reconciliation.
actor LibraryStore {
    /// Shared singleton instance for unified application-wide state access.
    static let shared = LibraryStore()

    private var snapshot: LibraryIndexSnapshot
    private let storageURL: URL
    private let fileManager: FileManager
    private var hasUnpersistedChanges: Bool = false

    private static let isRunningInTestEnvironment: Bool = {
        return ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ||
               ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil ||
               NSClassFromString("XCTestCase") != nil
    }()

    public static var defaultStorageURLOverride: URL?

    private static let testIsolatedStorageURL: URL = {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeepSakeTests_\(ProcessInfo.processInfo.globallyUniqueString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        return temp.appendingPathComponent("library_index.json")
    }()

    /// Default production location in Application Support (or isolated directory in test environment).
    static var defaultStorageURL: URL {
        if let override = defaultStorageURLOverride {
            return override
        }
        if isRunningInTestEnvironment {
            return testIsolatedStorageURL
        }
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

    func getPhoto(byRelativePath relativePath: String, rootFolderPath: String? = nil) -> PhotoRecord? {
        if let root = rootFolderPath {
            let normalizedRoot = URL(fileURLWithPath: root).standardizedFileURL.path
            return snapshot.photos.first { p in
                p.relativePath == relativePath && isPhoto(p, matchingNormalizedRoot: normalizedRoot)
            }
        }
        return snapshot.photos.first { $0.relativePath == relativePath }
    }

    func getPhotos(byState state: PhotoProcessingState, rootFolderPath: String? = nil) -> [PhotoRecord] {
        if let root = rootFolderPath {
            let normalizedRoot = URL(fileURLWithPath: root).standardizedFileURL.path
            return snapshot.photos.filter { p in
                p.processingState == state && isPhoto(p, matchingNormalizedRoot: normalizedRoot)
            }
        }
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

    func updatePhotoState(
        id: UUID,
        state: PhotoProcessingState,
        failureReason: String? = nil,
        detectedFacesCount: Int? = nil,
        persistImmediately: Bool = true
    ) throws {
        if let idx = snapshot.photos.firstIndex(where: { $0.id == id }) {
            snapshot.photos[idx].processingState = state
            snapshot.photos[idx].lastProcessedDate = Date()
            if let reason = failureReason {
                snapshot.photos[idx].failureReason = reason
            }
            if let count = detectedFacesCount {
                snapshot.photos[idx].detectedFacesCount = count
            }
            if persistImmediately {
                try persistToDisk()
            } else {
                hasUnpersistedChanges = true
            }
        }
    }

    // MARK: - Face & Embedding Operations

    func getFaces(forPhotoId photoId: UUID) -> [FaceRecord] {
        return snapshot.faces.filter { $0.photoId == photoId }
    }

    func getAllFaces() -> [FaceRecord] {
        return snapshot.faces
    }

    func saveFaces(_ newFaces: [FaceRecord], forPhotoId photoId: UUID, persistImmediately: Bool = true) throws {
        // Clear previous faces and their embeddings for this photo
        let oldFaceIds = Set(snapshot.faces.filter { $0.photoId == photoId }.map { $0.id })
        snapshot.faces.removeAll { $0.photoId == photoId }
        snapshot.embeddings.removeAll { oldFaceIds.contains($0.faceId) || $0.photoId == photoId }
        snapshot.faces.append(contentsOf: newFaces)
        if persistImmediately {
            try persistToDisk()
        } else {
            hasUnpersistedChanges = true
        }
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

    func saveEmbeddings(_ newEmbeddings: [EmbeddingRecord], persistImmediately: Bool = true) throws {
        for emb in newEmbeddings {
            if let idx = snapshot.embeddings.firstIndex(where: { $0.faceId == emb.faceId }) {
                snapshot.embeddings[idx] = emb
            } else {
                snapshot.embeddings.append(emb)
            }
        }
        if persistImmediately {
            try persistToDisk()
        } else {
            hasUnpersistedChanges = true
        }
    }

    /// Explicitly flushes any pending in-memory mutations to disk if unpersisted changes exist.
    func flushPendingSaves() throws {
        if hasUnpersistedChanges {
            try persistToDisk()
        }
    }

    // MARK: - Face Group Operations

    /// Determines whether a photo record belongs to the specified normalized root folder path,
    /// respecting explicit ownership when set and using principled fallback for legacy records.
    private func isPhoto(_ photo: PhotoRecord, matchingNormalizedRoot normalizedRoot: String) -> Bool {
        if let pRoot = photo.rootFolderPath {
            return URL(fileURLWithPath: pRoot).standardizedFileURL.path == normalizedRoot
        }
        // If relativePath is prefixed with or matches the normalized root
        if photo.relativePath.hasPrefix(normalizedRoot) {
            return true
        }
        // Legacy fallback 1: Check active library metadata folder
        if let metaPath = snapshot.metadata?.folderPath {
            return URL(fileURLWithPath: metaPath).standardizedFileURL.path == normalizedRoot
        }
        // Legacy fallback 2: If the snapshot has no other photos explicitly belonging to a different folder,
        // associate with this single active query folder.
        let hasOtherExplicitFolders = snapshot.photos.contains { p in
            if let oRoot = p.rootFolderPath {
                return URL(fileURLWithPath: oRoot).standardizedFileURL.path != normalizedRoot
            }
            return false
        }
        return !hasOtherExplicitFolders
    }

    func getGroups() -> [GroupRecord] {
        return snapshot.groups
    }

    /// Returns groups scoped to a specific root folder path.
    /// A group belongs to rootPath if its member faces belong to photos in rootPath, or explicit rootFolderPath matches.
    func getGroups(forRootFolderPath rootPath: String?) -> [GroupRecord] {
        guard let rootPath = rootPath else {
            return snapshot.groups
        }
        let normalizedRoot = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        let photoById = Dictionary(uniqueKeysWithValues: snapshot.photos.map { ($0.id, $0) })
        let faceById = Dictionary(uniqueKeysWithValues: snapshot.faces.map { ($0.id, $0) })

        return snapshot.groups.filter { group in
            // If group has member faces, verify via member faces' source photos
            let memberPhotos = group.memberFaceIds.compactMap { faceId -> PhotoRecord? in
                guard let face = faceById[faceId] else { return nil }
                return photoById[face.photoId]
            }
            if !memberPhotos.isEmpty {
                return memberPhotos.contains { photo in
                    isPhoto(photo, matchingNormalizedRoot: normalizedRoot)
                }
            }

            // Fallback: check explicit rootFolderPath
            if let groupRoot = group.rootFolderPath {
                return URL(fileURLWithPath: groupRoot).standardizedFileURL.path == normalizedRoot
            } else {
                let hasOtherFolders = snapshot.photos.contains { p in
                    if let oRoot = p.rootFolderPath {
                        return URL(fileURLWithPath: oRoot).standardizedFileURL.path != normalizedRoot
                    }
                    return false
                }
                return !hasOtherFolders && !snapshot.photos.isEmpty
            }
        }
    }

    /// Returns candidate suggestions scoped to a specific root folder path.
    func getCandidateGroups(forRootFolderPath rootPath: String? = nil) -> [GroupRecord] {
        return getGroups(forRootFolderPath: rootPath).filter { $0.reviewStatus == .candidateSuggestion }
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

        // Enforce invariant: if candidate suggestion, remove faces from confirmed people
        if group.reviewStatus == .candidateSuggestion {
            for pIdx in snapshot.people.indices {
                snapshot.people[pIdx].confirmedFaceIds.removeAll { newMemberSet.contains($0) }
            }
        }

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
                if let cov = groupCopy.coverFaceId, !uniqueMembers.contains(cov) {
                    groupCopy.coverFaceId = nil
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

    func getUngroupedFaces(forRootFolderPath rootPath: String? = nil) -> [FaceRecord] {
        var assignedFaceIds = Set<UUID>()
        for group in snapshot.groups {
            if group.reviewStatus != .rejected {
                for faceId in group.memberFaceIds {
                    assignedFaceIds.insert(faceId)
                }
            }
        }
        for person in snapshot.people {
            if !person.isDeactivated {
                for faceId in person.confirmedFaceIds {
                    assignedFaceIds.insert(faceId)
                }
            }
        }

        let excludedSet = Set(snapshot.excludedFaceIds + snapshot.faces.filter { $0.isExcluded }.map(\.id))
        let removedAssocSet = Set(snapshot.removedAssociations.map(\.faceId))
        let unassigned = snapshot.faces.filter { !assignedFaceIds.contains($0.id) && !excludedSet.contains($0.id) && !removedAssocSet.contains($0.id) }
        guard let rootPath = rootPath else {
            return unassigned
        }
        let normalizedRoot = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        let photoById = Dictionary(uniqueKeysWithValues: snapshot.photos.map { ($0.id, $0) })
        return unassigned.filter { face in
            guard let photo = photoById[face.photoId] else { return false }
            return isPhoto(photo, matchingNormalizedRoot: normalizedRoot)
        }
    }

    // MARK: - Excluded Faces & Recycle Bin (V7 Remediation)

    /// Marks a detected face as an excluded false detection (Recycle Bin).
    /// Removes it from any groups (candidate or confirmed) and people identities while preserving the photo.
    func excludeFace(faceId: UUID, reason: String = "falseDetection") throws {
        guard let faceIdx = snapshot.faces.firstIndex(where: { $0.id == faceId }) else { return }
        var face = snapshot.faces[faceIdx]
        face.isExcluded = true
        face.excludedAt = Date()
        face.exclusionReason = reason
        snapshot.faces[faceIdx] = face

        if !snapshot.excludedFaceIds.contains(faceId) {
            snapshot.excludedFaceIds.append(faceId)
        }

        // Remove from all groups
        for gIdx in snapshot.groups.indices {
            snapshot.groups[gIdx].memberFaceIds.removeAll { $0 == faceId }
            if snapshot.groups[gIdx].representativeFaceId == faceId {
                snapshot.groups[gIdx].representativeFaceId = snapshot.groups[gIdx].memberFaceIds.first
            }
            if snapshot.groups[gIdx].coverFaceId == faceId {
                snapshot.groups[gIdx].coverFaceId = nil
            }
            snapshot.groups[gIdx].updatedAt = Date()
        }
        snapshot.groups.removeAll { $0.memberFaceIds.isEmpty }

        // Remove from all people
        for pIdx in snapshot.people.indices {
            snapshot.people[pIdx].confirmedFaceIds.removeAll { $0 == faceId }
            if snapshot.people[pIdx].representativeFaceId == faceId {
                snapshot.people[pIdx].representativeFaceId = snapshot.people[pIdx].confirmedFaceIds.first
            }
            if snapshot.people[pIdx].coverFaceId == faceId {
                snapshot.people[pIdx].coverFaceId = nil
            }
            snapshot.people[pIdx].updatedAt = Date()
        }

        Self.sanitizeSnapshot(&snapshot)
        try persistToDisk()
    }

    /// Restores an excluded face from the Recycle Bin back to the unassigned pool.
    /// Does not automatically assign it to any group or person.
    func restoreFace(faceId: UUID) throws {
        guard let faceIdx = snapshot.faces.firstIndex(where: { $0.id == faceId }) else { return }
        var face = snapshot.faces[faceIdx]
        face.isExcluded = false
        face.excludedAt = nil
        face.exclusionReason = nil
        snapshot.faces[faceIdx] = face

        snapshot.excludedFaceIds.removeAll { $0 == faceId }

        try persistToDisk()
    }

    /// Permanently deletes an excluded face detection and its embedding record from the index.
    /// The original photograph on disk and photo record remain completely intact.
    func permanentlyDeleteFace(faceId: UUID) throws {
        guard let face = snapshot.faces.first(where: { $0.id == faceId }) else { return }
        let photoId = face.photoId

        // Remove from groups and people just in case
        for gIdx in snapshot.groups.indices {
            snapshot.groups[gIdx].memberFaceIds.removeAll { $0 == faceId }
            if snapshot.groups[gIdx].representativeFaceId == faceId {
                snapshot.groups[gIdx].representativeFaceId = snapshot.groups[gIdx].memberFaceIds.first
            }
            if snapshot.groups[gIdx].coverFaceId == faceId {
                snapshot.groups[gIdx].coverFaceId = nil
            }
        }
        snapshot.groups.removeAll { $0.memberFaceIds.isEmpty }

        for pIdx in snapshot.people.indices {
            snapshot.people[pIdx].confirmedFaceIds.removeAll { $0 == faceId }
            if snapshot.people[pIdx].representativeFaceId == faceId {
                snapshot.people[pIdx].representativeFaceId = snapshot.people[pIdx].confirmedFaceIds.first
            }
            if snapshot.people[pIdx].coverFaceId == faceId {
                snapshot.people[pIdx].coverFaceId = nil
            }
        }

        snapshot.faces.removeAll { $0.id == faceId }
        snapshot.embeddings.removeAll { $0.faceId == faceId }
        snapshot.excludedFaceIds.removeAll { $0 == faceId }

        // Update photo's detectedFacesCount
        if let pIdx = snapshot.photos.firstIndex(where: { $0.id == photoId }) {
            let remainingFaces = snapshot.faces.filter { $0.photoId == photoId }.count
            snapshot.photos[pIdx].detectedFacesCount = remainingFaces
        }

        Self.sanitizeSnapshot(&snapshot)
        try persistToDisk()
    }

    /// Returns excluded face detections (Recycle Bin), optionally scoped to a root folder.
    func getExcludedFaces(forRootFolderPath rootPath: String? = nil) -> [FaceRecord] {
        let excludedSet = Set(snapshot.excludedFaceIds + snapshot.faces.filter { $0.isExcluded }.map(\.id))
        let excludedFaces = snapshot.faces.filter { excludedSet.contains($0.id) }
        guard let rootPath = rootPath else {
            return excludedFaces
        }
        let normalizedRoot = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        let photoById = Dictionary(uniqueKeysWithValues: snapshot.photos.map { ($0.id, $0) })
        return excludedFaces.filter { face in
            guard let photo = photoById[face.photoId] else { return false }
            return isPhoto(photo, matchingNormalizedRoot: normalizedRoot)
        }
    }

    // MARK: - Removed from People (Recycle Bin Category B)

    /// Returns removed face associations (Recycle Bin Category B), optionally scoped to a root folder.
    func getRemovedAssociations(forRootFolderPath rootPath: String? = nil) -> [RemovedFaceAssociationRecord] {
        guard let rootPath = rootPath else {
            return snapshot.removedAssociations
        }
        let normalizedRoot = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        let photoById = Dictionary(uniqueKeysWithValues: snapshot.photos.map { ($0.id, $0) })
        return snapshot.removedAssociations.filter { assoc in
            guard let photo = photoById[assoc.photoId] else { return false }
            return isPhoto(photo, matchingNormalizedRoot: normalizedRoot)
        }
    }

    /// Moves a confirmed face association into the Removed from People recovery bin.
    func removeFaceToRecycleBin(faceId: UUID, personId: UUID, reason: String? = nil) throws {
        guard let personIdx = snapshot.people.firstIndex(where: { $0.id == personId }) else { return }
        var person = snapshot.people[personIdx]
        guard person.confirmedFaceIds.contains(faceId) else { return }
        guard let face = snapshot.faces.first(where: { $0.id == faceId }) else { return }

        // Remove from person's confirmedFaceIds
        person.confirmedFaceIds.removeAll { $0 == faceId }
        if person.representativeFaceId == faceId {
            person.representativeFaceId = person.confirmedFaceIds.first
        }
        if person.coverFaceId == faceId {
            person.coverFaceId = nil
        }
        person.updatedAt = Date()
        snapshot.people[personIdx] = person

        // Also update corresponding GroupRecord if exists
        if let gIdx = snapshot.groups.firstIndex(where: { $0.id == personId }) {
            snapshot.groups[gIdx].memberFaceIds.removeAll { $0 == faceId }
            if snapshot.groups[gIdx].representativeFaceId == faceId {
                snapshot.groups[gIdx].representativeFaceId = snapshot.groups[gIdx].memberFaceIds.first
            }
            if snapshot.groups[gIdx].coverFaceId == faceId {
                snapshot.groups[gIdx].coverFaceId = nil
            }
            snapshot.groups[gIdx].updatedAt = Date()
        }

        // Add to removedAssociations
        let record = RemovedFaceAssociationRecord(
            faceId: faceId,
            personId: personId,
            personName: person.name,
            photoId: face.photoId,
            removedAt: Date(),
            reason: reason ?? "Removed from \(person.name)"
        )
        snapshot.removedAssociations.removeAll { $0.faceId == faceId }
        snapshot.removedAssociations.append(record)

        Self.sanitizeSnapshot(&snapshot)
        try persistToDisk()
    }

    /// Restores a removed association back to its original person.
    func restoreRemovedAssociationToPerson(associationId: UUID) throws {
        guard let assocIdx = snapshot.removedAssociations.firstIndex(where: { $0.id == associationId }) else { return }
        let assoc = snapshot.removedAssociations[assocIdx]

        guard let personIdx = snapshot.people.firstIndex(where: { $0.id == assoc.personId && !$0.isDeactivated }) else {
            // Person no longer exists, restore to unassigned instead
            snapshot.removedAssociations.remove(at: assocIdx)
            try persistToDisk()
            return
        }

        var person = snapshot.people[personIdx]
        guard let face = snapshot.faces.first(where: { $0.id == assoc.faceId }) else {
            snapshot.removedAssociations.remove(at: assocIdx)
            try persistToDisk()
            return
        }

        // Check Cannot-Link: person cannot contain another face from the same photo
        let existingPhotos = Set(snapshot.faces.filter { person.confirmedFaceIds.contains($0.id) }.map(\.photoId))
        if existingPhotos.contains(face.photoId) {
            throw IdentityServiceError.cannotLinkViolation("Person '\(person.name)' already has another confirmed face in this photograph.")
        }

        if !person.confirmedFaceIds.contains(assoc.faceId) {
            person.confirmedFaceIds.append(assoc.faceId)
        }
        if person.representativeFaceId == nil {
            person.representativeFaceId = assoc.faceId
        }
        person.updatedAt = Date()
        snapshot.people[personIdx] = person

        if let gIdx = snapshot.groups.firstIndex(where: { $0.id == person.id }) {
            if !snapshot.groups[gIdx].memberFaceIds.contains(assoc.faceId) {
                snapshot.groups[gIdx].memberFaceIds.append(assoc.faceId)
            }
            if snapshot.groups[gIdx].representativeFaceId == nil {
                snapshot.groups[gIdx].representativeFaceId = assoc.faceId
            }
            snapshot.groups[gIdx].updatedAt = Date()
        }

        snapshot.removedAssociations.remove(at: assocIdx)
        Self.sanitizeSnapshot(&snapshot)
        try persistToDisk()
    }

    /// Restores a removed association back to Unassigned faces.
    func restoreRemovedAssociationToUnassigned(associationId: UUID) throws {
        snapshot.removedAssociations.removeAll { $0.id == associationId }
        try persistToDisk()
    }

    /// Permanently deletes a removed association record without deleting source photos.
    func permanentlyDeleteRemovedAssociation(associationId: UUID) throws {
        snapshot.removedAssociations.removeAll { $0.id == associationId }
        try persistToDisk()
    }

    /// Restores all removed associations (matching folder) to unassigned.
    func restoreAllRemovedAssociationsToUnassigned(forRootFolderPath rootPath: String? = nil) throws {
        let toRestore = getRemovedAssociations(forRootFolderPath: rootPath)
        let idsToRestore = Set(toRestore.map(\.id))
        snapshot.removedAssociations.removeAll { idsToRestore.contains($0.id) }
        try persistToDisk()
    }

    /// Permanently empties removed associations (matching folder) without deleting source photos.
    func emptyRemovedAssociationsBin(forRootFolderPath rootPath: String? = nil) throws {
        let toDelete = getRemovedAssociations(forRootFolderPath: rootPath)
        let idsToDelete = Set(toDelete.map(\.id))
        snapshot.removedAssociations.removeAll { idsToDelete.contains($0.id) }
        try persistToDisk()
    }

    /// Returns photos containing faces of a person/group, optionally scoped to a root folder.
    func getPhotos(forGroup groupId: UUID, rootFolderPath: String? = nil) -> [PhotoRecord] {
        let faceIdSet: Set<UUID>
        if let person = snapshot.people.first(where: { $0.id == groupId && !$0.isDeactivated }) {
            faceIdSet = Set(person.confirmedFaceIds)
        } else if let group = snapshot.groups.first(where: { $0.id == groupId }) {
            faceIdSet = Set(group.memberFaceIds)
        } else {
            return []
        }
        let relevantFaces = snapshot.faces.filter { faceIdSet.contains($0.id) }
        let uniquePhotoIds = Set(relevantFaces.map { $0.photoId })
        let allPhotosForGroup = snapshot.photos.filter { uniquePhotoIds.contains($0.id) }
        guard let rootFolderPath = rootFolderPath else {
            return allPhotosForGroup
        }
        let normalizedRoot = URL(fileURLWithPath: rootFolderPath).standardizedFileURL.path
        return allPhotosForGroup.filter { photo in
            isPhoto(photo, matchingNormalizedRoot: normalizedRoot)
        }
    }

    /// Returns the unique photo count for a person/group, optionally scoped to a root folder.
    func getUniquePhotoCount(forGroup groupId: UUID, rootFolderPath: String? = nil) -> Int {
        return getPhotos(forGroup: groupId, rootFolderPath: rootFolderPath).count
    }

    /// Returns faces belonging to a person/group, optionally scoped to a root folder.
    func getFaces(forGroup groupId: UUID, rootFolderPath: String? = nil) -> [FaceRecord] {
        let faceIdSet: Set<UUID>
        if let person = snapshot.people.first(where: { $0.id == groupId && !$0.isDeactivated }) {
            faceIdSet = Set(person.confirmedFaceIds)
        } else if let group = snapshot.groups.first(where: { $0.id == groupId }) {
            faceIdSet = Set(group.memberFaceIds)
        } else {
            return []
        }
        let relevantFaces = snapshot.faces.filter { faceIdSet.contains($0.id) }
        guard let rootFolderPath = rootFolderPath else {
            return relevantFaces
        }
        let normalizedRoot = URL(fileURLWithPath: rootFolderPath).standardizedFileURL.path
        let photoById = Dictionary(uniqueKeysWithValues: snapshot.photos.map { ($0.id, $0) })
        return relevantFaces.filter { face in
            guard let photo = photoById[face.photoId] else { return false }
            return isPhoto(photo, matchingNormalizedRoot: normalizedRoot)
        }
    }

    /// Returns the representative or persistent cover face for a person/group, optionally scoped to a root folder.
    func getRepresentativeFace(forGroup groupId: UUID, rootFolderPath: String? = nil) -> FaceRecord? {
        let person = snapshot.people.first(where: { $0.id == groupId && !$0.isDeactivated })
        let group = snapshot.groups.first(where: { $0.id == groupId })

        // 1. Prioritize persistent cover face globally (if valid and active)
        let coverId = person?.coverFaceId ?? group?.coverFaceId
        if let coverId = coverId {
            let isMember = (person?.confirmedFaceIds.contains(coverId) == true) || (group?.memberFaceIds.contains(coverId) == true)
            if isMember,
               let face = snapshot.faces.first(where: { $0.id == coverId && !$0.isExcluded }),
               !snapshot.excludedFaceIds.contains(coverId),
               !snapshot.removedAssociations.contains(where: { $0.faceId == coverId }) {
                return face
            }
        }

        // 2. Folder-scoped faces fallback
        let scopedFaces = getFaces(forGroup: groupId, rootFolderPath: rootFolderPath)
        let repId = person?.representativeFaceId ?? group?.representativeFaceId

        if !scopedFaces.isEmpty {
            if let repId = repId, let face = scopedFaces.first(where: { $0.id == repId }) {
                return face
            }
            return scopedFaces.first
        }

        return nil
    }

    /// Sets an explicit, persistent cover face for a person (and their corresponding group).
    /// Validates that the face exists, is not excluded or removed, and belongs to the person.
    func setCoverFace(personId: UUID, faceId: UUID) throws {
        guard let face = snapshot.faces.first(where: { $0.id == faceId }) else {
            throw IdentityServiceError.faceNotFound(faceId)
        }
        guard !face.isExcluded, !snapshot.excludedFaceIds.contains(faceId) else {
            throw IdentityServiceError.faceNotFound(faceId)
        }
        guard !snapshot.removedAssociations.contains(where: { $0.faceId == faceId }) else {
            throw IdentityServiceError.faceNotFound(faceId)
        }

        var foundPerson = false
        if let personIdx = snapshot.people.firstIndex(where: { $0.id == personId && !$0.isDeactivated }) {
            guard snapshot.people[personIdx].confirmedFaceIds.contains(faceId) else {
                throw IdentityServiceError.faceNotFound(faceId)
            }
            snapshot.people[personIdx].coverFaceId = faceId
            snapshot.people[personIdx].representativeFaceId = faceId
            snapshot.people[personIdx].updatedAt = Date()
            foundPerson = true
        }

        if let groupIdx = snapshot.groups.firstIndex(where: { $0.id == personId }) {
            guard snapshot.groups[groupIdx].memberFaceIds.contains(faceId) || foundPerson else {
                throw IdentityServiceError.faceNotFound(faceId)
            }
            snapshot.groups[groupIdx].coverFaceId = faceId
            snapshot.groups[groupIdx].representativeFaceId = faceId
            snapshot.groups[groupIdx].updatedAt = Date()
            foundPerson = true
        }

        guard foundPerson else {
            throw IdentityServiceError.groupNotFound(personId)
        }

        try persistToDisk()
    }

    /// Updates representative face, also setting coverFaceId for backward-compatibility and persistence.
    func setRepresentativeFace(groupId: UUID, faceId: UUID) throws {
        try setCoverFace(personId: groupId, faceId: faceId)
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

    // MARK: - Central People Database Operations

    func getAllPeople() -> [PersonRecord] {
        return snapshot.people
    }

    func getActivePeople() -> [PersonRecord] {
        return snapshot.people.filter { !$0.isDeactivated }
    }

    func getPerson(byId id: UUID) -> PersonRecord? {
        return snapshot.people.first { $0.id == id }
    }

    func savePerson(_ person: PersonRecord) throws {
        if let idx = snapshot.people.firstIndex(where: { $0.id == person.id }) {
            snapshot.people[idx] = person
        } else {
            snapshot.people.append(person)
        }
        try persistToDisk()
    }

    func savePeople(_ people: [PersonRecord]) throws {
        for person in people {
            if let idx = snapshot.people.firstIndex(where: { $0.id == person.id }) {
                snapshot.people[idx] = person
            } else {
                snapshot.people.append(person)
            }
        }
        try persistToDisk()
    }

    /// Safely deletes or removes a person from the central database.
    /// Unlinks confirmed faces and releases them back to unassigned. Never deletes source photos.
    func deletePerson(byId id: UUID) throws {
        var faceIdsToRelease = Set<UUID>()

        // 1. Collect faces from PersonRecord
        if let person = snapshot.people.first(where: { $0.id == id }) {
            faceIdsToRelease.formUnion(person.confirmedFaceIds)
        }

        // 2. Collect faces from any associated GroupRecord
        for group in snapshot.groups where group.id == id {
            faceIdsToRelease.formUnion(group.memberFaceIds)
        }

        // 3. Remove PersonRecord from central people database
        snapshot.people.removeAll { $0.id == id }

        // 4. Remove all groups associated with this person
        snapshot.groups.removeAll { $0.id == id }

        // 5. Remove released faces from any remaining groups
        if !faceIdsToRelease.isEmpty {
            for idx in snapshot.groups.indices {
                snapshot.groups[idx].memberFaceIds.removeAll { faceIdsToRelease.contains($0) }
                if let rep = snapshot.groups[idx].representativeFaceId, faceIdsToRelease.contains(rep) {
                    snapshot.groups[idx].representativeFaceId = snapshot.groups[idx].memberFaceIds.first
                }
            }
            snapshot.groups.removeAll { $0.memberFaceIds.isEmpty }
        }

        // 6. Clean up any removed associations belonging to this person
        snapshot.removedAssociations.removeAll { $0.personId == id }

        Self.sanitizeSnapshot(&snapshot)
        try persistToDisk()
    }

    /// Merges source person into target person atomically in the authoritative store.
    func mergePeople(targetPersonId: UUID, sourcePersonId: UUID) throws {
        guard targetPersonId != sourcePersonId else { return }
        guard let targetIdx = snapshot.people.firstIndex(where: { $0.id == targetPersonId }) else { return }
        guard let sourceIdx = snapshot.people.firstIndex(where: { $0.id == sourcePersonId }) else { return }

        let sourcePerson = snapshot.people[sourceIdx]
        var targetPerson = snapshot.people[targetIdx]

        // 1. Merge confirmed faces without duplicates
        var combinedFaces = targetPerson.confirmedFaceIds
        for fId in sourcePerson.confirmedFaceIds {
            if !combinedFaces.contains(fId) {
                combinedFaces.append(fId)
            }
        }
        targetPerson.confirmedFaceIds = combinedFaces

        // 2. Reconcile representative face and cover face
        if targetPerson.representativeFaceId == nil || !combinedFaces.contains(targetPerson.representativeFaceId!) {
            targetPerson.representativeFaceId = sourcePerson.representativeFaceId ?? combinedFaces.first
        }
        if targetPerson.coverFaceId == nil || !combinedFaces.contains(targetPerson.coverFaceId!) {
            if let sourceCover = sourcePerson.coverFaceId, combinedFaces.contains(sourceCover) {
                targetPerson.coverFaceId = sourceCover
            } else {
                targetPerson.coverFaceId = nil
            }
        }
        targetPerson.updatedAt = Date()
        snapshot.people[targetIdx] = targetPerson

        // 3. Remove source person
        snapshot.people.remove(at: sourceIdx)

        // 4. Merge associated GroupRecords if present
        if let targetGroupIdx = snapshot.groups.firstIndex(where: { $0.id == targetPersonId }) {
            var targetGroup = snapshot.groups[targetGroupIdx]
            var groupFaces = targetGroup.memberFaceIds
            if let sourceGroup = snapshot.groups.first(where: { $0.id == sourcePersonId }) {
                for fId in sourceGroup.memberFaceIds {
                    if !groupFaces.contains(fId) {
                        groupFaces.append(fId)
                    }
                }
            }
            targetGroup.memberFaceIds = groupFaces
            if targetGroup.representativeFaceId == nil || !groupFaces.contains(targetGroup.representativeFaceId!) {
                targetGroup.representativeFaceId = targetPerson.representativeFaceId
            }
            targetGroup.coverFaceId = targetPerson.coverFaceId
            targetGroup.updatedAt = Date()
            snapshot.groups[targetGroupIdx] = targetGroup
        }
        // Remove source group
        snapshot.groups.removeAll { $0.id == sourcePersonId }

        Self.sanitizeSnapshot(&snapshot)
        try persistToDisk()
    }

    /// Removes an individual face association from a person. Releases face to unassigned.
    func removeFaceFromPerson(personId: UUID, faceId: UUID) throws {
        if let personIdx = snapshot.people.firstIndex(where: { $0.id == personId }) {
            var person = snapshot.people[personIdx]
            person.confirmedFaceIds.removeAll { $0 == faceId }
            if person.representativeFaceId == faceId {
                person.representativeFaceId = person.confirmedFaceIds.first
            }
            if person.coverFaceId == faceId {
                person.coverFaceId = nil
            }
            person.updatedAt = Date()

            if person.confirmedFaceIds.isEmpty {
                // Empty identity: mark deactivated and prune group
                person.isDeactivated = true
                snapshot.people[personIdx] = person
                snapshot.groups.removeAll { $0.id == personId }
            } else {
                snapshot.people[personIdx] = person
                if let groupIdx = snapshot.groups.firstIndex(where: { $0.id == personId }) {
                    snapshot.groups[groupIdx].memberFaceIds.removeAll { $0 == faceId }
                    if snapshot.groups[groupIdx].representativeFaceId == faceId {
                        snapshot.groups[groupIdx].representativeFaceId = person.representativeFaceId
                    }
                    if snapshot.groups[groupIdx].coverFaceId == faceId {
                        snapshot.groups[groupIdx].coverFaceId = nil
                    }
                    snapshot.groups[groupIdx].updatedAt = Date()
                }
            }
        }

        // Also check if face was in any GroupRecord directly (e.g. candidate suggestion)
        for idx in snapshot.groups.indices {
            if snapshot.groups[idx].memberFaceIds.contains(faceId) {
                snapshot.groups[idx].memberFaceIds.removeAll { $0 == faceId }
                if snapshot.groups[idx].representativeFaceId == faceId {
                    snapshot.groups[idx].representativeFaceId = snapshot.groups[idx].memberFaceIds.first
                }
                if snapshot.groups[idx].coverFaceId == faceId {
                    snapshot.groups[idx].coverFaceId = nil
                }
                snapshot.groups[idx].updatedAt = Date()
            }
        }
        // Prune empty groups
        snapshot.groups.removeAll { $0.memberFaceIds.isEmpty }

        Self.sanitizeSnapshot(&snapshot)
        try persistToDisk()
    }

    /// Assigns multiple faces to a person in the authoritative store.
    func assignFacesToPerson(personId: UUID, faceIds: [UUID]) throws {
        guard let personIdx = snapshot.people.firstIndex(where: { $0.id == personId }) else { return }
        var person = snapshot.people[personIdx]
        let newFaceSet = Set(faceIds)

        // Enforce invariant: remove these faces from all other people & groups
        for pIdx in snapshot.people.indices {
            if snapshot.people[pIdx].id != personId {
                snapshot.people[pIdx].confirmedFaceIds.removeAll { newFaceSet.contains($0) }
                if let rep = snapshot.people[pIdx].representativeFaceId, newFaceSet.contains(rep) {
                    snapshot.people[pIdx].representativeFaceId = snapshot.people[pIdx].confirmedFaceIds.first
                }
                if let cov = snapshot.people[pIdx].coverFaceId, newFaceSet.contains(cov) {
                    snapshot.people[pIdx].coverFaceId = nil
                }
            }
        }
        for gIdx in snapshot.groups.indices {
            if snapshot.groups[gIdx].id != personId {
                snapshot.groups[gIdx].memberFaceIds.removeAll { newFaceSet.contains($0) }
                if let rep = snapshot.groups[gIdx].representativeFaceId, newFaceSet.contains(rep) {
                    snapshot.groups[gIdx].representativeFaceId = snapshot.groups[gIdx].memberFaceIds.first
                }
                if let cov = snapshot.groups[gIdx].coverFaceId, newFaceSet.contains(cov) {
                    snapshot.groups[gIdx].coverFaceId = nil
                }
            }
        }
        snapshot.groups.removeAll { $0.id != personId && $0.memberFaceIds.isEmpty }

        // Add to target person
        var updatedFaces = person.confirmedFaceIds
        for fId in faceIds {
            if !updatedFaces.contains(fId) {
                updatedFaces.append(fId)
            }
        }
        person.confirmedFaceIds = updatedFaces
        if person.representativeFaceId == nil || !updatedFaces.contains(person.representativeFaceId!) {
            person.representativeFaceId = updatedFaces.first
        }
        person.isDeactivated = false
        person.updatedAt = Date()
        snapshot.people[personIdx] = person

        // Update or create target GroupRecord
        if let gIdx = snapshot.groups.firstIndex(where: { $0.id == personId }) {
            snapshot.groups[gIdx].memberFaceIds = updatedFaces
            snapshot.groups[gIdx].representativeFaceId = person.representativeFaceId
            snapshot.groups[gIdx].coverFaceId = person.coverFaceId
            snapshot.groups[gIdx].updatedAt = Date()
        } else {
            let maxIndex = snapshot.groups.map(\.groupIndex).max() ?? 0
            let newGroup = GroupRecord(
                id: personId,
                groupIndex: maxIndex + 1,
                customName: person.name,
                coverFaceId: person.coverFaceId,
                representativeFaceId: person.representativeFaceId,
                memberFaceIds: updatedFaces,
                centroid: person.centroid,
                identityAnchors: person.identityAnchors,
                averageSimilarity: 1.0,
                minSimilarity: 1.0,
                thresholdUsed: 0.54,
                reviewStatus: .confirmed
            )
            snapshot.groups.append(newGroup)
        }

        Self.sanitizeSnapshot(&snapshot)
        try persistToDisk()
    }

    // MARK: - Reconciliation

    /// Reconciles scanned files on disk against the persistent index.
    /// Scopes photo changes and removals strictly to the folder being reconciled,
    /// ensuring photos and identities from other folders are never deleted.
    func reconcile(scannedPhotos: [PhotoItem], rootFolderURL: URL) throws -> LibraryReconciliationResult {
        let rootPath = rootFolderURL.standardizedFileURL.path
        var existingByPath: [String: PhotoRecord] = [:]
        for p in snapshot.photos {
            if isPhoto(p, matchingNormalizedRoot: rootPath) {
                existingByPath[p.relativePath] = p
            }
        }

        var newPhotos: [PhotoRecord] = []
        var changedPhotos: [PhotoRecord] = []
        var unchangedPhotos: [PhotoRecord] = []
        var unindexedPhotos: [PhotoRecord] = []
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

                let sizeChanged = existing.fileSize != item.fileSize
                let dateChanged = abs(existing.modificationDate.timeIntervalSince(dateMod)) >= 1.0
                let fingerprintChanged = existing.fileFingerprint != currentFingerprint
                let fileContentChanged = sizeChanged || (dateChanged && fingerprintChanged)

                if fileContentChanged {
                    // CHANGED PHOTO: contents modified on disk
                    var updated = existing
                    updated.fileSize = item.fileSize
                    updated.modificationDate = dateMod
                    updated.fileFingerprint = currentFingerprint
                    updated.processingState = .needsReprocessing
                    updated.failureReason = nil
                    updated.rootFolderPath = rootPath

                    // Clear stale faces & embeddings for changed photo
                    snapshot.faces.removeAll { $0.photoId == updated.id }
                    snapshot.embeddings.removeAll { $0.photoId == updated.id }

                    if let idx = snapshot.photos.firstIndex(where: { $0.id == updated.id }) {
                        snapshot.photos[idx] = updated
                    }
                    changedPhotos.append(updated)
                } else {
                    // UNCHANGED PHOTO on disk - ensure rootFolderPath is recorded
                    var updated = existing
                    if updated.rootFolderPath != rootPath {
                        updated.rootFolderPath = rootPath
                        if let idx = snapshot.photos.firstIndex(where: { $0.id == updated.id }) {
                            snapshot.photos[idx] = updated
                        }
                    }

                    switch updated.processingState {
                    case .discovered, .needsReprocessing:
                        // Photo was never processed, or was interrupted/cancelled during earlier session
                        unindexedPhotos.append(updated)
                        unchangedPhotos.append(updated)

                    case .processing:
                        // Left in .processing from interrupted crash or unexpected exit
                        updated.processingState = .needsReprocessing
                        updated.failureReason = "Interrupted during previous session"
                        if let idx = snapshot.photos.firstIndex(where: { $0.id == updated.id }) {
                            snapshot.photos[idx] = updated
                        }
                        unindexedPhotos.append(updated)
                        unchangedPhotos.append(updated)

                    case .processed:
                        // Check validity of stored results
                        if updated.detectedFacesCount > 0 {
                            let photoFaces = snapshot.faces.filter { $0.photoId == updated.id }
                            let photoEmbeddings = snapshot.embeddings.filter { $0.photoId == updated.id }
                            let hasIncompatibleEmbedding = photoEmbeddings.contains { $0.dimension != 512 }

                            if photoFaces.isEmpty || photoEmbeddings.isEmpty || hasIncompatibleEmbedding {
                                // Incomplete or incompatible results: mark for reprocessing
                                updated.processingState = .needsReprocessing
                                updated.failureReason = hasIncompatibleEmbedding ? "Incompatible embedding model" : "Missing face embeddings"
                                snapshot.faces.removeAll { $0.photoId == updated.id }
                                snapshot.embeddings.removeAll { $0.photoId == updated.id }
                                if let idx = snapshot.photos.firstIndex(where: { $0.id == updated.id }) {
                                    snapshot.photos[idx] = updated
                                }
                                changedPhotos.append(updated)
                            } else {
                                unchangedPhotos.append(updated)
                            }
                        } else {
                            // Valid zero-face photo
                            unchangedPhotos.append(updated)
                        }

                    case .failed:
                        // Remains failed on disk, eligible for retry button
                        unchangedPhotos.append(updated)
                    }
                }
            } else {
                // NEW PHOTO
                let newPhoto = PhotoRecord(
                    relativePath: relativePath,
                    filename: item.filename,
                    fileSize: item.fileSize,
                    modificationDate: dateMod,
                    processingState: .discovered,
                    rootFolderPath: rootPath
                )
                snapshot.photos.append(newPhoto)
                newPhotos.append(newPhoto)
            }
        }

        // REMOVED PHOTOS: only consider photos that belong to THIS root folder
        var removedPhotos: [PhotoRecord] = []
        var removedPhotoIds: Set<UUID> = []
        for photo in snapshot.photos {
            let isFromThisFolder = isPhoto(photo, matchingNormalizedRoot: rootPath)
            if isFromThisFolder && !seenRelativePaths.contains(photo.relativePath) {
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
            removedPhotos: removedPhotos,
            unindexedPhotos: unindexedPhotos
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
            var seenFaceIdsForEmb = Set<UUID>()
            snapshot.embeddings = snapshot.embeddings.filter { emb in
                validFaceIds.contains(emb.faceId) &&
                validPhotoIds.contains(emb.photoId) &&
                seenFaceIdsForEmb.insert(emb.faceId).inserted
            }

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
                    if let cov = groupCopy.coverFaceId, !activeMembers.contains(cov) {
                        groupCopy.coverFaceId = nil
                    }
                    sanitizedGroups.append(groupCopy)
                }
            }
            snapshot.groups = sanitizedGroups

            // Sanitize People records: retain active faces, update representative and cover face if needed
            for i in snapshot.people.indices {
                snapshot.people[i].confirmedFaceIds = snapshot.people[i].confirmedFaceIds.filter { validFaceIds.contains($0) }
                if let rep = snapshot.people[i].representativeFaceId, !validFaceIds.contains(rep) {
                    snapshot.people[i].representativeFaceId = snapshot.people[i].confirmedFaceIds.first
                }
                if let cov = snapshot.people[i].coverFaceId, !validFaceIds.contains(cov) {
                    snapshot.people[i].coverFaceId = nil
                }
            }

            snapshot.excludedFaceIds.removeAll { !validFaceIds.contains($0) }
            snapshot.removedAssociations.removeAll { !validFaceIds.contains($0.faceId) }
        } else {
            var seenFaceIds = Set<UUID>()
            var sanitizedGroups: [GroupRecord] = []
            for group in snapshot.groups {
                var groupCopy = group
                let uniqueMembers = group.memberFaceIds.filter { seenFaceIds.insert($0).inserted }
                groupCopy.memberFaceIds = uniqueMembers
                if !uniqueMembers.isEmpty {
                    if let cov = groupCopy.coverFaceId, !uniqueMembers.contains(cov) {
                        groupCopy.coverFaceId = nil
                    }
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
            var wasModified = Self.sanitizeSnapshot(&snap)

            // Auto-bootstrap legacy confirmed groups into central PersonRecord collection if empty
            if snap.people.isEmpty && !snap.groups.isEmpty {
                var bootstrapped: [PersonRecord] = []
                for group in snap.groups {
                    if group.reviewStatus == .confirmed || (group.customName != nil && !group.customName!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                        let name = group.customName?.trimmingCharacters(in: .whitespacesAndNewlines)
                        let personName = (name != nil && !name!.isEmpty) ? name! : "Person \(group.groupIndex)"
                        let person = PersonRecord(
                            id: group.id,
                            name: personName,
                            coverFaceId: group.coverFaceId,
                            representativeFaceId: group.representativeFaceId,
                            confirmedFaceIds: group.memberFaceIds,
                            centroidData: group.centroidData,
                            identityAnchorsData: group.identityAnchorsData,
                            createdAt: group.createdAt,
                            updatedAt: group.updatedAt,
                            isDeactivated: false
                        )
                        bootstrapped.append(person)
                    }
                }
                if !bootstrapped.isEmpty {
                    snap.people = bootstrapped
                    wasModified = true
                }
            }

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
        self.hasUnpersistedChanges = false
    }

    /// Clears the entire in-memory snapshot and deletes the file from disk (useful for tests/reset).
    func reset() throws {
        self.snapshot = LibraryIndexSnapshot()
        self.hasUnpersistedChanges = false
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
