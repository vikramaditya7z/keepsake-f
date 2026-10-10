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
    var representativeBoundingBox: CGRect?
    var representativePhotoURL: URL?
    var averageSimilarity: Float
    var minSimilarity: Float

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(displayName)
        hasher.combine(uniquePhotoCount)
        hasher.combine(faceCount)
        hasher.combine(representativeFaceId)
    }

    static func == (lhs: PersonDisplayModel, rhs: PersonDisplayModel) -> Bool {
        return lhs.id == rhs.id &&
               lhs.displayName == rhs.displayName &&
               lhs.uniquePhotoCount == rhs.uniquePhotoCount &&
               lhs.faceCount == rhs.faceCount &&
               lhs.representativeFaceId == rhs.representativeFaceId
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

/// Main-thread coordinator and view model for the People Gallery and Person Identity Workspace.
@MainActor
final class PeopleViewModel: ObservableObject {
    @Published var people: [PersonDisplayModel] = []
    @Published var unassignedFaces: [FaceDisplayModel] = []
    @Published var selectedPerson: PersonDisplayModel? = nil
    @Published var selectedPersonPhotos: [PhotoItem] = []
    @Published var selectedPersonFaces: [FaceDisplayModel] = []
    @Published var selectedPhotoForDetail: PhotoItem? = nil
    @Published var selectedDetailTab: PersonDetailTab = .photos

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

    private let identityService: IdentityServiceProtocol
    private let libraryStore: LibraryStore

    init(
        identityService: IdentityServiceProtocol? = nil,
        libraryStore: LibraryStore = LibraryStore.shared
    ) {
        let store = libraryStore
        self.libraryStore = store
        self.identityService = identityService ?? IdentityService(libraryStore: store)
    }

    // MARK: - Data Loading

    /// Loads all persisted people groups and unassigned faces.
    func loadData(rootFolderURL: URL?) async {
        isLoading = true
        defer { isLoading = false }

        let groups = await identityService.fetchGroups()
        var displayPeople: [PersonDisplayModel] = []

        for group in groups {
            // Only include groups with at least 1 face
            guard !group.memberFaceIds.isEmpty else { continue }

            let uniqueCount = await identityService.fetchUniquePhotoCount(forGroupId: group.id)
            let (repFace, repPhoto) = await identityService.fetchRepresentativeFace(forGroupId: group.id)

            var repURL: URL? = nil
            if let photo = repPhoto {
                if let root = rootFolderURL {
                    repURL = root.appendingPathComponent(photo.relativePath)
                } else {
                    repURL = URL(fileURLWithPath: photo.relativePath)
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
                representativeBoundingBox: repFace?.boundingBox,
                representativePhotoURL: repURL,
                averageSimilarity: group.averageSimilarity,
                minSimilarity: group.minSimilarity
            )
            displayPeople.append(model)
        }

        // Sort groups deterministically: custom named first alphabetically, then by photo count descending, then group index
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

        self.people = displayPeople

        // Load Unassigned faces
        let ungrouped = await identityService.fetchUngroupedFaces()
        var unassignedList: [FaceDisplayModel] = []

        for face in ungrouped {
            if let photo = await libraryStore.getPhoto(byId: face.photoId) {
                let url: URL
                if let root = rootFolderURL {
                    url = root.appendingPathComponent(photo.relativePath)
                } else {
                    url = URL(fileURLWithPath: photo.relativePath)
                }
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

        self.unassignedFaces = unassignedList

        // If a person is currently selected, refresh their detail data
        if let currentSelected = selectedPerson {
            if let refreshedPerson = self.people.first(where: { $0.id == currentSelected.id }) {
                await selectPerson(refreshedPerson, rootFolderURL: rootFolderURL)
            } else {
                self.selectedPerson = nil
                self.selectedPersonPhotos = []
                self.selectedPersonFaces = []
            }
        }
    }

    // MARK: - Person Selection & Details

    func selectPerson(_ person: PersonDisplayModel, rootFolderURL: URL?) async {
        self.selectedPerson = person
        self.selectedDetailTab = .photos

        // Load photos for this person
        let photos = await identityService.fetchPhotos(forGroupId: person.id, rootFolderURL: rootFolderURL)
        self.selectedPersonPhotos = photos

        // Load face details for this person
        var faces: [FaceDisplayModel] = []
        for faceId in person.groupRecord.memberFaceIds {
            if let face = await libraryStore.getFace(byId: faceId),
               let photo = await libraryStore.getPhoto(byId: face.photoId) {
                let url: URL
                if let root = rootFolderURL {
                    url = root.appendingPathComponent(photo.relativePath)
                } else {
                    url = URL(fileURLWithPath: photo.relativePath)
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
            try await identityService.mergeGroups(targetGroupId: target.id, sourceGroupId: source.id)
            self.showMergeSheet = false
            self.personToMerge = nil
            await loadData(rootFolderURL: rootFolderURL)
            if selectedPerson?.id == source.id {
                if let updatedTarget = people.first(where: { $0.id == target.id }) {
                    await selectPerson(updatedTarget, rootFolderURL: rootFolderURL)
                }
            }
        } catch {
            showError("Failed to merge people: \(error.localizedDescription)")
        }
    }

    func removeFaceFromSelectedPerson(faceId: UUID, rootFolderURL: URL?) async {
        guard let person = selectedPerson else { return }
        do {
            try await identityService.removeFaceFromGroup(faceId: faceId, groupId: person.id)
            await loadData(rootFolderURL: rootFolderURL)
        } catch {
            showError("Failed to remove face: \(error.localizedDescription)")
        }
    }

    func setRepresentativeFace(for person: PersonDisplayModel, faceId: UUID, rootFolderURL: URL?) async {
        do {
            try await identityService.setRepresentativeFace(groupId: person.id, faceId: faceId)
            await loadData(rootFolderURL: rootFolderURL)
        } catch {
            showError("Failed to set thumbnail: \(error.localizedDescription)")
        }
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

    func deleteSelectedPerson(rootFolderURL: URL?) async {
        guard let person = selectedPerson else { return }
        do {
            try await identityService.deleteGroup(id: person.id)
            self.selectedPerson = nil
            await loadData(rootFolderURL: rootFolderURL)
        } catch {
            showError("Failed to delete person: \(error.localizedDescription)")
        }
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

    // MARK: - Helper

    private func showError(_ message: String) {
        self.errorMessage = message
        self.showErrorAlert = true
    }
}
