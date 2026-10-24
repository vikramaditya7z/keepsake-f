import SwiftUI
import AppKit

/// Sub-tabs within the Person Detail View.
enum PersonDetailTab: String, CaseIterable, Identifiable {
    case photos = "Photos"
    case faces = "Faces"

    var id: String { rawValue }
}

/// Presentation model representing an individual person or group in the People Gallery.
struct PersonDisplayModel: Identifiable, Sendable, Hashable {
    let id: UUID
    var groupRecord: GroupRecord
    var displayName: String
    var customName: String?
    var groupIndex: Int
    var uniquePhotoCount: Int
    var faceCount: Int
    var representativeFaceId: UUID?
    var coverFaceId: UUID?
    var representativeBoundingBox: CGRect?
    var representativePhotoURL: URL?
    var averageSimilarity: Float
    var minSimilarity: Float
    var reviewStatus: IdentityReviewStatus

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(displayName)
        hasher.combine(uniquePhotoCount)
        hasher.combine(faceCount)
        hasher.combine(representativeFaceId)
        hasher.combine(coverFaceId)
        hasher.combine(reviewStatus)
    }

    static func == (lhs: PersonDisplayModel, rhs: PersonDisplayModel) -> Bool {
        return lhs.id == rhs.id &&
               lhs.displayName == rhs.displayName &&
               lhs.uniquePhotoCount == rhs.uniquePhotoCount &&
               lhs.faceCount == rhs.faceCount &&
               lhs.representativeFaceId == rhs.representativeFaceId &&
               lhs.coverFaceId == rhs.coverFaceId &&
               lhs.reviewStatus == rhs.reviewStatus
    }
}

/// Presentation model representing a single detected face belonging to a person or unassigned.
struct FaceDisplayModel: Identifiable, Sendable, Hashable {
    let id: UUID
    let photoId: UUID
    let photoURL: URL
    let filename: String
    let boundingBox: CGRect
    let confidence: Float
    var assignedGroupId: UUID?
    var assignedGroupName: String?
}

/// Presentation model representing a face association removed from a confirmed person and kept in the Recycle Bin.
struct RemovedAssociationDisplayModel: Identifiable, Sendable, Hashable {
    let id: UUID
    let faceId: UUID
    let personId: UUID
    let personName: String
    let photoId: UUID
    let photoURL: URL?
    let filename: String
    let rootFolderPath: String?
    let boundingBox: CGRect
    let removedAt: Date
    let reason: String?
}

/// Main-thread coordinator and view model for the People Gallery and Person Identity Workspace.
@MainActor
final class PeopleViewModel: ObservableObject {
    @Published var people: [PersonDisplayModel] = []
    @Published var candidateGroups: [PersonDisplayModel] = []
    @Published var unassignedFaces: [FaceDisplayModel] = []
    @Published var selectedPerson: PersonDisplayModel? = nil
    @Published var selectedPersonPhotos: [PhotoItem] = []
    @Published var selectedPersonFaces: [FaceDisplayModel] = []
    @Published var selectedPhotoForDetail: PhotoItem? = nil
    @Published var selectedDetailTab: PersonDetailTab = .photos

    /// Number of distinct confirmed people who have assigned faces/photos in the currently selected folder.
    var activeFolderPeopleCount: Int {
        guard activeFolderPath != nil else { return 0 }
        return people.filter { $0.reviewStatus == .confirmed && ($0.faceCount > 0 || $0.uniquePhotoCount > 0) }.count
    }

    @Published var isLoading: Bool = false
    @Published var errorMessage: String? = nil
    @Published var showErrorAlert: Bool = false

    // Modals & Sheets State
    @Published var isRenaming: Bool = false
    @Published var renamingText: String = ""
    @Published var personToRename: PersonDisplayModel? = nil

    @Published var showMergeSheet: Bool = false
    @Published var personToMerge: PersonDisplayModel? = nil

    @Published var showAssignSheet: Bool = false
    @Published var faceToAssign: FaceDisplayModel? = nil

    // Candidate Group Direct Assignment State (V7 Follow-up)
    @Published var showAssignCandidateGroupSheet: Bool = false
    @Published var candidateGroupToAssign: PersonDisplayModel? = nil

    // Unassigned Multi-Selection State (V7)
    @Published var selectedUnassignedFaceIds: Set<UUID> = []
    @Published var isSelectingUnassigned: Bool = false
    @Published var showBulkAssignSheet: Bool = false
    @Published var showBulkCreateSheet: Bool = false
    @Published var bulkCreatePersonName: String = ""

    // Recycle Bin State (V7 Follow-up: Two Bins)
    @Published var recycleBinFaces: [FaceDisplayModel] = []
    @Published var removedAssociations: [RemovedAssociationDisplayModel] = []
    @Published var showRecycleBinSheet: Bool = false

    // Move Face State (V7)
    @Published var faceToMove: FaceDisplayModel? = nil
    @Published var showMoveFaceSheet: Bool = false

    // Candidate Confirmation Workflow State
    @Published var isConfirmingCandidate: Bool = false
    @Published var candidateToConfirm: PersonDisplayModel? = nil
    @Published var confirmCandidateName: String = ""

    private let identityService: IdentityServiceProtocol
    private let libraryStore: LibraryStore
    private var activeFolderPath: String? = nil
    private var loadGeneration: UInt64 = 0

    init(
        identityService: IdentityServiceProtocol? = nil,
        libraryStore: LibraryStore = LibraryStore.shared
    ) {
        let store = libraryStore
        self.libraryStore = store
        self.identityService = identityService ?? IdentityService(libraryStore: store)
    }

    // MARK: - Data Loading

    /// Loads persisted people groups and candidate suggestions/unassigned faces scoped to the active folder.
    /// When `rootFolderURL` is `nil` (no folder selected in the current session), all folder-scoped collections
    /// (`candidateGroups`, `unassignedFaces`, `recycleBinFaces`, `removedAssociations`, `selectedPersonPhotos`,
    /// `selectedPersonFaces`, and folder-specific photo/face counts) are cleared to zero/empty while preserving
    /// global confirmed identities in `people`.
    func loadData(rootFolderURL: URL?) async {
        loadGeneration &+= 1
        let myGeneration = loadGeneration
        let targetFolderPath = rootFolderURL?.standardizedFileURL.path

        if targetFolderPath != activeFolderPath {
            activeFolderPath = targetFolderPath
            candidateGroups = []
            unassignedFaces = []
            selectedUnassignedFaceIds = []
            isSelectingUnassigned = false
            recycleBinFaces = []
            removedAssociations = []
            selectedPerson = nil
            selectedPersonPhotos = []
            selectedPersonFaces = []
            selectedPhotoForDetail = nil
        }

        isLoading = true
        defer {
            if self.loadGeneration == myGeneration {
                isLoading = false
            }
        }

        let persistedPeople = await identityService.fetchPeople()
        let allGroups = await identityService.fetchGroups()

        guard self.loadGeneration == myGeneration else { return }

        // If no folder is selected in the current session, clear all folder-scoped state and load only
        // global confirmed identities with zero active-folder counts.
        guard let activeRootFolderURL = rootFolderURL else {
            var displayPeople: [PersonDisplayModel] = []
            var handledPeopleIds = Set<UUID>()

            for person in persistedPeople {
                guard !person.isDeactivated else { continue }
                handledPeopleIds.insert(person.id)

                let group = allGroups.first(where: { $0.id == person.id })
                let groupRecord = group ?? GroupRecord(
                    id: person.id,
                    groupIndex: 0,
                    customName: person.name,
                    representativeFaceId: person.representativeFaceId,
                    memberFaceIds: person.confirmedFaceIds,
                    centroid: person.centroid,
                    identityAnchors: person.identityAnchors,
                    averageSimilarity: 1.0,
                    minSimilarity: 1.0,
                    thresholdUsed: 0.54,
                    reviewStatus: .confirmed
                )

                let explicitCoverId = person.coverFaceId ?? group?.coverFaceId
                var repFace: FaceRecord? = nil
                var repURL: URL? = nil
                if explicitCoverId != nil {
                    let (resolvedFace, resolvedPhoto) = await identityService.fetchRepresentativeFace(
                        forGroupId: person.id,
                        rootFolderURL: nil
                    )
                    repFace = resolvedFace
                    if let photo = resolvedPhoto {
                        if let photoRoot = photo.rootFolderPath {
                            repURL = URL(fileURLWithPath: photoRoot).appendingPathComponent(photo.relativePath)
                        } else {
                            repURL = URL(fileURLWithPath: photo.relativePath)
                        }
                    }
                }

                let model = PersonDisplayModel(
                    id: person.id,
                    groupRecord: groupRecord,
                    displayName: person.name,
                    customName: person.name,
                    groupIndex: group?.groupIndex ?? 0,
                    uniquePhotoCount: 0,
                    faceCount: 0,
                    representativeFaceId: repFace?.id,
                    coverFaceId: explicitCoverId,
                    representativeBoundingBox: repFace?.boundingBox,
                    representativePhotoURL: repURL,
                    averageSimilarity: group?.averageSimilarity ?? 1.0,
                    minSimilarity: group?.minSimilarity ?? 1.0,
                    reviewStatus: .confirmed
                )
                displayPeople.append(model)
            }

            for group in allGroups {
                guard !handledPeopleIds.contains(group.id) else { continue }
                guard !group.memberFaceIds.isEmpty else { continue }
                guard group.reviewStatus == .confirmed else { continue }
                handledPeopleIds.insert(group.id)

                var repFace: FaceRecord? = nil
                var repURL: URL? = nil
                if group.coverFaceId != nil {
                    let (resolvedFace, resolvedPhoto) = await identityService.fetchRepresentativeFace(
                        forGroupId: group.id,
                        rootFolderURL: nil
                    )
                    repFace = resolvedFace
                    if let photo = resolvedPhoto {
                        if let photoRoot = photo.rootFolderPath {
                            repURL = URL(fileURLWithPath: photoRoot).appendingPathComponent(photo.relativePath)
                        } else {
                            repURL = URL(fileURLWithPath: photo.relativePath)
                        }
                    }
                }

                let model = PersonDisplayModel(
                    id: group.id,
                    groupRecord: group,
                    displayName: group.displayName,
                    customName: group.customName,
                    groupIndex: group.groupIndex,
                    uniquePhotoCount: 0,
                    faceCount: 0,
                    representativeFaceId: repFace?.id,
                    coverFaceId: group.coverFaceId,
                    representativeBoundingBox: repFace?.boundingBox,
                    representativePhotoURL: repURL,
                    averageSimilarity: group.averageSimilarity,
                    minSimilarity: group.minSimilarity,
                    reviewStatus: group.reviewStatus
                )
                displayPeople.append(model)
            }

            displayPeople.sort { a, b in
                let aHasCustom = a.customName != nil && !a.customName!.isEmpty
                let bHasCustom = b.customName != nil && !b.customName!.isEmpty
                if aHasCustom && !bHasCustom { return true }
                if !aHasCustom && bHasCustom { return false }
                return a.groupIndex < b.groupIndex
            }

            guard self.loadGeneration == myGeneration else { return }

            self.people = displayPeople
            self.candidateGroups = []
            self.unassignedFaces = []
            self.selectedUnassignedFaceIds = []
            self.isSelectingUnassigned = false
            self.recycleBinFaces = []
            self.removedAssociations = []
            self.selectedPerson = nil
            self.selectedPersonPhotos = []
            self.selectedPersonFaces = []
            self.selectedPhotoForDetail = nil
            return
        }

        let candidateGroups = await identityService.fetchCandidateGroups(rootFolderURL: activeRootFolderURL)

        var displayPeople: [PersonDisplayModel] = []
        var displayCandidates: [PersonDisplayModel] = []
        var handledPeopleIds = Set<UUID>()

        // 1. Load Confirmed People from Central People Database (Library-wide)
        for person in persistedPeople {
            guard !person.isDeactivated else { continue }
            handledPeopleIds.insert(person.id)

            let group = allGroups.first(where: { $0.id == person.id })
            let groupRecord = group ?? GroupRecord(
                id: person.id,
                groupIndex: 0,
                customName: person.name,
                representativeFaceId: person.representativeFaceId,
                memberFaceIds: person.confirmedFaceIds,
                centroid: person.centroid,
                identityAnchors: person.identityAnchors,
                averageSimilarity: 1.0,
                minSimilarity: 1.0,
                thresholdUsed: 0.54,
                reviewStatus: .confirmed
            )

            let uniqueCount = await identityService.fetchUniquePhotoCount(forGroupId: person.id, rootFolderURL: activeRootFolderURL)
            let (repFace, repPhoto) = await identityService.fetchRepresentativeFace(forGroupId: person.id, rootFolderURL: activeRootFolderURL)
            let scopedFaces = await identityService.fetchFaces(forGroupId: person.id, rootFolderURL: activeRootFolderURL)

            var repURL: URL? = nil
            if let photo = repPhoto {
                if let photoRoot = photo.rootFolderPath {
                    repURL = URL(fileURLWithPath: photoRoot).appendingPathComponent(photo.relativePath)
                } else {
                    repURL = activeRootFolderURL.appendingPathComponent(photo.relativePath)
                }
            }

            let model = PersonDisplayModel(
                id: person.id,
                groupRecord: groupRecord,
                displayName: person.name,
                customName: person.name,
                groupIndex: group?.groupIndex ?? 0,
                uniquePhotoCount: uniqueCount,
                faceCount: scopedFaces.count,
                representativeFaceId: repFace?.id,
                coverFaceId: person.coverFaceId ?? group?.coverFaceId,
                representativeBoundingBox: repFace?.boundingBox,
                representativePhotoURL: repURL,
                averageSimilarity: group?.averageSimilarity ?? 1.0,
                minSimilarity: group?.minSimilarity ?? 1.0,
                reviewStatus: .confirmed
            )
            displayPeople.append(model)
        }

        // 2. Load Candidate Groups scoped to the active root folder
        for group in candidateGroups {
            guard !handledPeopleIds.contains(group.id) else { continue }
            guard !group.memberFaceIds.isEmpty else { continue }
            guard group.reviewStatus == .candidateSuggestion else { continue }

            let uniqueCount = await identityService.fetchUniquePhotoCount(forGroupId: group.id, rootFolderURL: activeRootFolderURL)
            let (repFace, repPhoto) = await identityService.fetchRepresentativeFace(forGroupId: group.id, rootFolderURL: activeRootFolderURL)

            var repURL: URL? = nil
            if let photo = repPhoto {
                if let photoRoot = photo.rootFolderPath {
                    repURL = URL(fileURLWithPath: photoRoot).appendingPathComponent(photo.relativePath)
                } else {
                    repURL = activeRootFolderURL.appendingPathComponent(photo.relativePath)
                }
            }

            let model = PersonDisplayModel(
                id: group.id,
                groupRecord: group,
                displayName: group.displayName,
                customName: group.customName,
                groupIndex: group.groupIndex,
                uniquePhotoCount: uniqueCount,
                faceCount: group.memberFaceIds.count,
                representativeFaceId: repFace?.id ?? group.representativeFaceId,
                coverFaceId: group.coverFaceId,
                representativeBoundingBox: repFace?.boundingBox,
                representativePhotoURL: repURL,
                averageSimilarity: group.averageSimilarity,
                minSimilarity: group.minSimilarity,
                reviewStatus: group.reviewStatus
            )

            displayCandidates.append(model)
        }

        // 3. Load any legacy confirmed groups not yet represented in central database
        for group in allGroups {
            guard !handledPeopleIds.contains(group.id) else { continue }
            guard !group.memberFaceIds.isEmpty else { continue }
            guard group.reviewStatus == .confirmed else { continue }
            handledPeopleIds.insert(group.id)

            let uniqueCount = await identityService.fetchUniquePhotoCount(forGroupId: group.id, rootFolderURL: activeRootFolderURL)
            let (repFace, repPhoto) = await identityService.fetchRepresentativeFace(forGroupId: group.id, rootFolderURL: activeRootFolderURL)
            let scopedFaces = await identityService.fetchFaces(forGroupId: group.id, rootFolderURL: activeRootFolderURL)

            var repURL: URL? = nil
            if let photo = repPhoto {
                if let photoRoot = photo.rootFolderPath {
                    repURL = URL(fileURLWithPath: photoRoot).appendingPathComponent(photo.relativePath)
                } else {
                    repURL = activeRootFolderURL.appendingPathComponent(photo.relativePath)
                }
            }

            let model = PersonDisplayModel(
                id: group.id,
                groupRecord: group,
                displayName: group.displayName,
                customName: group.customName,
                groupIndex: group.groupIndex,
                uniquePhotoCount: uniqueCount,
                faceCount: scopedFaces.count,
                representativeFaceId: repFace?.id ?? group.representativeFaceId,
                coverFaceId: group.coverFaceId,
                representativeBoundingBox: repFace?.boundingBox,
                representativePhotoURL: repURL,
                averageSimilarity: group.averageSimilarity,
                minSimilarity: group.minSimilarity,
                reviewStatus: group.reviewStatus
            )

            displayPeople.append(model)
        }

        // Sort confirmed groups deterministically
        displayPeople.sort { a, b in
            let aHasCustom = a.customName != nil && !a.customName!.isEmpty
            let bHasCustom = b.customName != nil && !b.customName!.isEmpty
            if aHasCustom && !bHasCustom { return true }
            if !aHasCustom && bHasCustom { return false }
            if a.uniquePhotoCount != b.uniquePhotoCount {
                return a.uniquePhotoCount > b.uniquePhotoCount
            }
            return a.groupIndex < b.groupIndex
        }

        // Sort candidate groups by face count descending
        displayCandidates.sort { a, b in
            if a.faceCount != b.faceCount {
                return a.faceCount > b.faceCount
            }
            return a.groupIndex < b.groupIndex
        }

        // Load Unassigned faces scoped to active folder
        let ungrouped = await identityService.fetchUngroupedFaces(rootFolderURL: activeRootFolderURL)

        var unassignedList: [FaceDisplayModel] = []
        for face in ungrouped {
            if let photo = await libraryStore.getPhoto(byId: face.photoId) {
                let url = activeRootFolderURL.appendingPathComponent(photo.relativePath)
                unassignedList.append(FaceDisplayModel(
                    id: face.id,
                    photoId: face.photoId,
                    photoURL: url,
                    filename: photo.filename,
                    boundingBox: face.boundingBox,
                    confidence: face.confidence,
                    assignedGroupId: nil,
                    assignedGroupName: nil
                ))
            }
        }

        guard self.loadGeneration == myGeneration else { return }

        self.people = displayPeople
        self.candidateGroups = displayCandidates
        self.unassignedFaces = unassignedList
        let validUnassignedIds = Set(unassignedList.map { $0.id })
        self.selectedUnassignedFaceIds.formIntersection(validUnassignedIds)

        // Load Recycle Bin faces scoped to active folder
        await loadRecycleBin(rootFolderURL: activeRootFolderURL)

        guard self.loadGeneration == myGeneration else { return }

        // If a person is currently selected, refresh their detail data
        if let currentSelected = selectedPerson {
            if let refreshedPerson = self.people.first(where: { $0.id == currentSelected.id }) {
                await selectPerson(refreshedPerson, rootFolderURL: activeRootFolderURL)
            } else if let refreshedCandidate = self.candidateGroups.first(where: { $0.id == currentSelected.id }) {
                await selectPerson(refreshedCandidate, rootFolderURL: activeRootFolderURL)
            } else {
                self.selectedPerson = nil
                self.selectedPersonPhotos = []
                self.selectedPersonFaces = []
            }
        }
    }

    // MARK: - Person Selection & Details

    func selectPerson(_ person: PersonDisplayModel, rootFolderURL: URL?) async {
        let myGeneration = self.loadGeneration
        self.selectedPerson = person
        self.selectedDetailTab = .photos
        self.selectedPhotoForDetail = nil

        guard let activeRootFolderURL = rootFolderURL else {
            self.selectedPersonPhotos = []
            self.selectedPersonFaces = []
            return
        }

        // Load photos for this person scoped to the active folder
        let photos = await identityService.fetchPhotos(forGroupId: person.id, rootFolderURL: activeRootFolderURL)

        // Load face details for this person scoped to the active folder
        let scopedFaces = await identityService.fetchFaces(forGroupId: person.id, rootFolderURL: activeRootFolderURL)
        var faces: [FaceDisplayModel] = []
        for face in scopedFaces {
            if let photo = await libraryStore.getPhoto(byId: face.photoId) {
                let url: URL
                if let photoRoot = photo.rootFolderPath {
                    url = URL(fileURLWithPath: photoRoot).appendingPathComponent(photo.relativePath)
                } else {
                    url = activeRootFolderURL.appendingPathComponent(photo.relativePath)
                }
                faces.append(FaceDisplayModel(
                    id: face.id,
                    photoId: face.photoId,
                    photoURL: url,
                    filename: photo.filename,
                    boundingBox: face.boundingBox,
                    confidence: face.confidence,
                    assignedGroupId: person.id,
                    assignedGroupName: person.displayName
                ))
            }
        }

        guard self.loadGeneration == myGeneration, self.selectedPerson?.id == person.id else { return }
        self.selectedPersonPhotos = photos
        self.selectedPersonFaces = faces
    }

    func clearSelection() {
        self.selectedPerson = nil
        self.selectedPersonPhotos = []
        self.selectedPersonFaces = []
        self.selectedPhotoForDetail = nil
    }

    // MARK: - Identity Operations

    func renamePerson(_ person: PersonDisplayModel, newName: String, rootFolderURL: URL?) async {
        do {
            try await identityService.renameGroup(id: person.id, newName: newName)
            await loadData(rootFolderURL: rootFolderURL)
        } catch {
            showError("Failed to rename person: \(error.localizedDescription)")
        }
    }

    func promptRename(for person: PersonDisplayModel) {
        self.personToRename = person
        self.renamingText = person.customName ?? ""
        self.isRenaming = true
    }

    func confirmRename(rootFolderURL: URL?) async {
        guard let person = personToRename else { return }
        await renamePerson(person, newName: renamingText, rootFolderURL: rootFolderURL)
        self.isRenaming = false
        self.personToRename = nil
    }

    func promptMerge(for person: PersonDisplayModel) {
        self.personToMerge = person
        self.showMergeSheet = true
    }

    func mergePerson(source: PersonDisplayModel, into target: PersonDisplayModel, rootFolderURL: URL?) async {
        do {
            try await identityService.mergePeople(targetPersonId: target.id, sourcePersonId: source.id)
            self.showMergeSheet = false
            self.personToMerge = nil
            await loadData(rootFolderURL: rootFolderURL)
            if selectedPerson?.id == source.id {
                if let updatedTarget = people.first(where: { $0.id == target.id }) {
                    await selectPerson(updatedTarget, rootFolderURL: rootFolderURL)
                } else {
                    clearSelection()
                }
            }
        } catch {
            showError("Failed to merge people: \(error.localizedDescription)")
        }
    }

    func removeFaceFromSelectedPerson(faceId: UUID, rootFolderURL: URL?) async {
        guard let person = selectedPerson else { return }
        do {
            if person.reviewStatus == .candidateSuggestion {
                try await identityService.removeFaceFromCandidateGroup(faceId: faceId, groupId: person.id)
            } else {
                try await identityService.removeFaceFromPerson(faceId: faceId, personId: person.id)
            }
            await loadData(rootFolderURL: rootFolderURL)
        } catch {
            showError("Failed to remove face: \(error.localizedDescription)")
        }
    }

    func removeFaceFromSelectedCandidate(faceId: UUID, rootFolderURL: URL?) async {
        guard let candidate = selectedPerson, candidate.reviewStatus == .candidateSuggestion else { return }
        do {
            try await identityService.removeFaceFromCandidateGroup(faceId: faceId, groupId: candidate.id)
            await loadData(rootFolderURL: rootFolderURL)
        } catch {
            showError("Failed to remove face from suggestion: \(error.localizedDescription)")
        }
    }

    func promptMoveFace(_ face: FaceDisplayModel) {
        self.faceToMove = face
        self.showMoveFaceSheet = true
    }

    func moveFace(faceId: UUID, fromPersonId: UUID, toTargetPersonId: UUID, rootFolderURL: URL?) async {
        do {
            try await identityService.moveFace(faceId: faceId, fromPersonId: fromPersonId, toPersonId: toTargetPersonId)
            self.showMoveFaceSheet = false
            self.faceToMove = nil
            await loadData(rootFolderURL: rootFolderURL)
            if let current = selectedPerson, let refreshed = people.first(where: { $0.id == current.id }) {
                await selectPerson(refreshed, rootFolderURL: rootFolderURL)
            }
        } catch {
            showError("Failed to move face: \(error.localizedDescription)")
        }
    }

    // MARK: - Unassigned Faces Multi-Selection & Bulk Actions

    func toggleSelectUnassignedFace(_ id: UUID) {
        if selectedUnassignedFaceIds.contains(id) {
            selectedUnassignedFaceIds.remove(id)
        } else {
            selectedUnassignedFaceIds.insert(id)
        }
    }

    func selectAllUnassignedFaces() {
        selectedUnassignedFaceIds = Set(unassignedFaces.map { $0.id })
    }

    func clearUnassignedSelection() {
        selectedUnassignedFaceIds.removeAll()
    }

    func isUnassignedFaceSelected(_ id: UUID) -> Bool {
        selectedUnassignedFaceIds.contains(id)
    }

    func bulkAssignSelectedFaces(toTargetPersonId: UUID, rootFolderURL: URL?) async {
        self.errorMessage = nil
        self.showErrorAlert = false
        do {
            try await identityService.bulkAssignFaces(
                faceIds: Array(selectedUnassignedFaceIds),
                targetPersonId: toTargetPersonId
            )
            clearUnassignedSelection()
            showBulkAssignSheet = false
            await loadData(rootFolderURL: rootFolderURL)
        } catch {
            showError("Failed to bulk assign faces: \(error.localizedDescription)")
        }
    }

    func bulkCreatePersonFromSelectedFaces(name: String?, rootFolderURL: URL?) async {
        self.errorMessage = nil
        self.showErrorAlert = false
        do {
            _ = try await identityService.bulkCreatePerson(
                withFaceIds: Array(selectedUnassignedFaceIds),
                name: name,
                rootFolderURL: rootFolderURL
            )
            clearUnassignedSelection()
            showBulkCreateSheet = false
            bulkCreatePersonName = ""
            await loadData(rootFolderURL: rootFolderURL)
        } catch {
            showError("Failed to create person: \(error.localizedDescription)")
        }
    }

    func restoreFaceToSuggestions(faceId: UUID, rootFolderURL: URL?) async {
        do {
            _ = try await identityService.restoreFaceToCandidateSuggestion(faceId: faceId, rootFolderURL: rootFolderURL)
            selectedUnassignedFaceIds.remove(faceId)
            await loadData(rootFolderURL: rootFolderURL)
        } catch {
            showError("Failed to restore face to suggestions: \(error.localizedDescription)")
        }
    }

    func bulkRestoreSelectedFacesToSuggestions(rootFolderURL: URL?) async {
        guard !selectedUnassignedFaceIds.isEmpty else { return }
        do {
            _ = try await identityService.restoreFacesToCandidateSuggestion(
                faceIds: Array(selectedUnassignedFaceIds),
                rootFolderURL: rootFolderURL
            )
            selectedUnassignedFaceIds.removeAll()
            isSelectingUnassigned = false
            await loadData(rootFolderURL: rootFolderURL)
        } catch {
            showError("Failed to restore selected faces to suggestions: \(error.localizedDescription)")
        }
    }

    func setCoverFace(for person: PersonDisplayModel, faceId: UUID, rootFolderURL: URL?) async {
        do {
            try await identityService.setCoverFace(personId: person.id, faceId: faceId)
            if var current = selectedPerson, current.id == person.id {
                current.coverFaceId = faceId
                current.representativeFaceId = faceId
                self.selectedPerson = current
            }
            await loadData(rootFolderURL: rootFolderURL)
            if let updated = people.first(where: { $0.id == person.id }) {
                self.selectedPerson = updated
            }
        } catch {
            showError("Failed to set cover photo: \(error.localizedDescription)")
        }
    }

    func setRepresentativeFace(for person: PersonDisplayModel, faceId: UUID, rootFolderURL: URL?) async {
        await setCoverFace(for: person, faceId: faceId, rootFolderURL: rootFolderURL)
    }

    func promptAssign(for face: FaceDisplayModel) {
        self.faceToAssign = face
        self.showAssignSheet = true
    }

    func assignFace(faceId: UUID, toTargetGroupId targetGroupId: UUID, rootFolderURL: URL?) async {
        do {
            try await identityService.assignFaceToGroup(faceId: faceId, targetGroupId: targetGroupId)
            self.showAssignSheet = false
            self.faceToAssign = nil
            await loadData(rootFolderURL: rootFolderURL)
        } catch {
            showError("Failed to assign face: \(error.localizedDescription)")
        }
    }

    func createPersonFromFace(faceId: UUID, name: String?, rootFolderURL: URL?) async {
        do {
            _ = try await identityService.createNewGroup(withFaceId: faceId, name: name)
            self.showAssignSheet = false
            self.faceToAssign = nil
            await loadData(rootFolderURL: rootFolderURL)
        } catch {
            showError("Failed to create person: \(error.localizedDescription)")
        }
    }

    /// Safely removes a person from the central database, unlinking their faces without deleting photos.
    func removePerson(_ person: PersonDisplayModel, rootFolderURL: URL?) async {
        do {
            try await identityService.deletePerson(id: person.id)
            if selectedPerson?.id == person.id {
                self.selectedPerson = nil
            }
            await loadData(rootFolderURL: rootFolderURL)
        } catch {
            showError("Failed to remove person: \(error.localizedDescription)")
        }
    }

    func deleteSelectedPerson(rootFolderURL: URL?) async {
        guard let person = selectedPerson else { return }
        await removePerson(person, rootFolderURL: rootFolderURL)
    }

    // MARK: - Navigation within Selected Person Photos

    var hasPreviousPhoto: Bool {
        guard let current = selectedPhotoForDetail,
              let idx = selectedPersonPhotos.firstIndex(of: current) else { return false }
        return idx > 0
    }

    var hasNextPhoto: Bool {
        guard let current = selectedPhotoForDetail,
              let idx = selectedPersonPhotos.firstIndex(of: current) else { return false }
        return idx < selectedPersonPhotos.count - 1
    }

    func selectPreviousPhoto() {
        guard let current = selectedPhotoForDetail,
              let idx = selectedPersonPhotos.firstIndex(of: current),
              idx > 0 else { return }
        selectedPhotoForDetail = selectedPersonPhotos[idx - 1]
    }

    func selectNextPhoto() {
        guard let current = selectedPhotoForDetail,
              let idx = selectedPersonPhotos.firstIndex(of: current),
              idx < selectedPersonPhotos.count - 1 else { return }
        selectedPhotoForDetail = selectedPersonPhotos[idx + 1]
    }

    // MARK: - Candidate Review Actions

    func promptConfirmCandidate(for candidate: PersonDisplayModel) {
        self.candidateToConfirm = candidate
        self.confirmCandidateName = candidate.customName ?? ""
        self.isConfirmingCandidate = true
    }

    func confirmCandidate(candidate: PersonDisplayModel, name: String? = nil, rootFolderURL: URL?) async {
        do {
            _ = try await identityService.confirmGroup(id: candidate.id, name: name)
            self.isConfirmingCandidate = false
            self.candidateToConfirm = nil
            await loadData(rootFolderURL: rootFolderURL)
        } catch {
            showError("Failed to confirm suggestion: \(error.localizedDescription)")
        }
    }

    func rejectCandidate(candidate: PersonDisplayModel, rootFolderURL: URL?) async {
        do {
            try await identityService.rejectCandidateGroup(id: candidate.id)
            if selectedPerson?.id == candidate.id {
                selectedPerson = nil
            }
            await loadData(rootFolderURL: rootFolderURL)
        } catch {
            showError("Failed to reject suggestion: \(error.localizedDescription)")
        }
    }

    // MARK: - Candidate Group Direct Assignment (V7 Follow-up)

    func promptAssignCandidateGroup(_ candidate: PersonDisplayModel) {
        self.candidateGroupToAssign = candidate
        self.showAssignCandidateGroupSheet = true
    }

    func assignCandidateGroup(_ candidate: PersonDisplayModel, toTargetPersonId targetPersonId: UUID, rootFolderURL: URL?) async {
        do {
            try await identityService.bulkAssignFaces(faceIds: candidate.groupRecord.memberFaceIds, targetPersonId: targetPersonId)
            self.showAssignCandidateGroupSheet = false
            self.candidateGroupToAssign = nil
            if selectedPerson?.id == candidate.id {
                self.selectedPerson = nil
            }
            await loadData(rootFolderURL: rootFolderURL)
        } catch {
            showError("Failed to assign candidate group: \(error.localizedDescription)")
        }
    }

    // MARK: - Excluded Faces & Recycle Bin (V7 Follow-up: Two Distinct Bins)

    func loadRecycleBin(rootFolderURL: URL?) async {
        let myGeneration = self.loadGeneration
        guard let activeRootFolderURL = rootFolderURL else {
            self.recycleBinFaces = []
            self.removedAssociations = []
            return
        }

        // 1. False Detections (Category A)
        let excluded = await identityService.fetchExcludedFaces(rootFolderURL: activeRootFolderURL)
        var binList: [FaceDisplayModel] = []
        for face in excluded {
            if let photo = await libraryStore.getPhoto(byId: face.photoId) {
                let url: URL
                if let photoRoot = photo.rootFolderPath {
                    url = URL(fileURLWithPath: photoRoot).appendingPathComponent(photo.relativePath)
                } else {
                    url = activeRootFolderURL.appendingPathComponent(photo.relativePath)
                }
                binList.append(FaceDisplayModel(
                    id: face.id,
                    photoId: face.photoId,
                    photoURL: url,
                    filename: photo.filename,
                    boundingBox: face.boundingBox,
                    confidence: face.confidence,
                    assignedGroupId: nil,
                    assignedGroupName: nil
                ))
            }
        }

        // 2. Removed from People Associations (Category B)
        let removedRecords = await identityService.fetchRemovedAssociations(rootFolderURL: activeRootFolderURL)
        var assocList: [RemovedAssociationDisplayModel] = []
        for assoc in removedRecords {
            if let face = await libraryStore.getFace(byId: assoc.faceId),
               let photo = await libraryStore.getPhoto(byId: assoc.photoId) {
                let url: URL
                if let photoRoot = photo.rootFolderPath {
                    url = URL(fileURLWithPath: photoRoot).appendingPathComponent(photo.relativePath)
                } else {
                    url = activeRootFolderURL.appendingPathComponent(photo.relativePath)
                }
                assocList.append(RemovedAssociationDisplayModel(
                    id: assoc.id,
                    faceId: assoc.faceId,
                    personId: assoc.personId,
                    personName: assoc.personName,
                    photoId: assoc.photoId,
                    photoURL: url,
                    filename: photo.filename,
                    rootFolderPath: photo.rootFolderPath,
                    boundingBox: face.boundingBox,
                    removedAt: assoc.removedAt,
                    reason: assoc.reason
                ))
            }
        }

        guard self.loadGeneration == myGeneration else { return }
        self.recycleBinFaces = binList
        self.removedAssociations = assocList
    }

    // False Detections Actions
    func excludeFaceFromSelectedPerson(faceId: UUID, rootFolderURL: URL?) async {
        do {
            try await identityService.excludeFace(faceId: faceId, reason: "falseDetection")
            await loadData(rootFolderURL: rootFolderURL)
        } catch {
            showError("Failed to mark face as false detection: \(error.localizedDescription)")
        }
    }

    func excludeUnassignedFace(faceId: UUID, rootFolderURL: URL?) async {
        do {
            try await identityService.excludeFace(faceId: faceId, reason: "falseDetection")
            selectedUnassignedFaceIds.remove(faceId)
            await loadData(rootFolderURL: rootFolderURL)
        } catch {
            showError("Failed to mark face as false detection: \(error.localizedDescription)")
        }
    }

    func bulkExcludeSelectedFaces(rootFolderURL: URL?) async {
        guard !selectedUnassignedFaceIds.isEmpty else { return }
        do {
            for faceId in selectedUnassignedFaceIds {
                try await identityService.excludeFace(faceId: faceId, reason: "falseDetection")
            }
            selectedUnassignedFaceIds.removeAll()
            isSelectingUnassigned = false
            await loadData(rootFolderURL: rootFolderURL)
        } catch {
            showError("Failed to exclude selected faces: \(error.localizedDescription)")
        }
    }

    func restoreFaceFromRecycleBin(faceId: UUID, rootFolderURL: URL?) async {
        do {
            try await identityService.restoreFace(faceId: faceId)
            await loadData(rootFolderURL: rootFolderURL)
        } catch {
            showError("Failed to restore face: \(error.localizedDescription)")
        }
    }

    func permanentlyDeleteFace(faceId: UUID, rootFolderURL: URL?) async {
        do {
            try await identityService.permanentlyDeleteFace(faceId: faceId)
            await loadData(rootFolderURL: rootFolderURL)
        } catch {
            showError("Failed to delete face record: \(error.localizedDescription)")
        }
    }

    func restoreAllRecycleBinFaces(rootFolderURL: URL?) async {
        do {
            for face in recycleBinFaces {
                try await identityService.restoreFace(faceId: face.id)
            }
            await loadData(rootFolderURL: rootFolderURL)
        } catch {
            showError("Failed to restore faces: \(error.localizedDescription)")
        }
    }

    func emptyRecycleBin(rootFolderURL: URL?) async {
        do {
            for face in recycleBinFaces {
                try await identityService.permanentlyDeleteFace(faceId: face.id)
            }
            await loadData(rootFolderURL: rootFolderURL)
        } catch {
            showError("Failed to empty recycle bin: \(error.localizedDescription)")
        }
    }

    // Removed from People Actions (Category B)
    func removeFaceToRecycleBinFromSelectedPerson(faceId: UUID, rootFolderURL: URL?) async {
        guard let person = selectedPerson else { return }
        do {
            try await identityService.removeFaceToRecycleBin(faceId: faceId, personId: person.id, reason: "Removed from \(person.displayName)")
            await loadData(rootFolderURL: rootFolderURL)
        } catch {
            showError("Failed to send face to recycle bin: \(error.localizedDescription)")
        }
    }

    func restoreRemovedAssociationToPerson(_ associationId: UUID, rootFolderURL: URL?) async {
        do {
            try await identityService.restoreRemovedAssociationToPerson(associationId: associationId)
            await loadData(rootFolderURL: rootFolderURL)
        } catch {
            showError("Failed to restore face to person: \(error.localizedDescription)")
        }
    }

    func restoreRemovedAssociationToUnassigned(_ associationId: UUID, rootFolderURL: URL?) async {
        do {
            try await identityService.restoreRemovedAssociationToUnassigned(associationId: associationId)
            await loadData(rootFolderURL: rootFolderURL)
        } catch {
            showError("Failed to restore face to unassigned: \(error.localizedDescription)")
        }
    }

    func permanentlyDeleteRemovedAssociation(_ associationId: UUID, rootFolderURL: URL?) async {
        do {
            try await identityService.permanentlyDeleteRemovedAssociation(associationId: associationId)
            await loadData(rootFolderURL: rootFolderURL)
        } catch {
            showError("Failed to delete association record: \(error.localizedDescription)")
        }
    }

    func restoreAllRemovedAssociations(rootFolderURL: URL?) async {
        do {
            try await identityService.restoreAllRemovedAssociationsToUnassigned(rootFolderURL: rootFolderURL)
            await loadData(rootFolderURL: rootFolderURL)
        } catch {
            showError("Failed to restore associations: \(error.localizedDescription)")
        }
    }

    func emptyRemovedAssociations(rootFolderURL: URL?) async {
        do {
            try await identityService.emptyRemovedAssociationsBin(rootFolderURL: rootFolderURL)
            await loadData(rootFolderURL: rootFolderURL)
        } catch {
            showError("Failed to empty removed associations: \(error.localizedDescription)")
        }
    }

    /// Clears all in-memory people, candidate groups, and unassigned faces.
    func resetAllData() {
        self.people = []
        self.candidateGroups = []
        self.unassignedFaces = []
        self.selectedPerson = nil
        self.selectedPersonPhotos = []
        self.selectedPersonFaces = []
        self.selectedPhotoForDetail = nil
        self.errorMessage = nil
        self.showErrorAlert = false
    }

    private func showError(_ message: String) {
        self.errorMessage = message
        self.showErrorAlert = true
    }
}
