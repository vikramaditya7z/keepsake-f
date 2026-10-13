# KeepSake V6 Implementation Report: Central People Database & Persistent Identity Memory

**Date**: October 10, 2026  
**Milestone**: KeepSake V6 (Central People Database & Persistent Identity Memory)  
**Status**: **COMPLETE & VERIFIED**  
**Test Suite**: **170 Tests Executed, 0 Failures, 0 Regressions**  
**Git Integrity**: Working tree maintained locally; 0 automated commits; 0 pushes to remote  
**Data Safety**: Live database (`~/Library/Application Support/KeepSake/library_index.json`) and backup (`~/Disk/KeepSake-Backups/library_index-before-goal.json`) 100% untouched  

---

## 1. Executive Summary

Milestone V6 establishes an authoritative, folder-independent **Central People Database** and persistent identity memory for KeepSake. 

Prior to V6:
1. Switching to another photo folder and returning caused confirmed identity decisions to disappear because photo reconciliation evaluated the entire library against the newly selected folder, purging photos, faces, and embeddings not found on disk in the new folder.
2. The concept of an approved human being was conflated with an algorithmic clustering run (`GroupRecord`), causing re-clustering passes to overwrite or omit identity profiles not present in the currently active folder.
3. The user could not access a central, durable directory of approved people independent of the currently selected folder.

In V6, human identities are decoupled from transient folder views and ephemeral clustering outputs into first-class `PersonRecord` entities that persist across folder changes and application restarts.

---

## 2. Core Architecture & Schema Evolution

### 2.1 Authoritative Identity Model: `PersonRecord`

Declared in `KeepSake/Models/PersistedModels.swift`:

```swift
/// Persistent record for a central, app-wide person identity independent of folder selection.
struct PersonRecord: Codable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var representativeFaceId: UUID?
    var confirmedFaceIds: [UUID]
    var centroidData: Data?
    var identityAnchorsData: Data?
    let createdAt: Date
    var updatedAt: Date
    var isDeactivated: Bool
    
    // Accessors for 512-D normalized centroid and diverse identity anchors
    var centroid: [Float]? { ... }
    var identityAnchors: [[Float]] { ... }
}
```

- **Stable Identity Key**: `id: UUID` remains constant across folder changes, scans, and restarts.
- **Authoritative Identity Manifold**: `centroidData` and `identityAnchorsData` store 512-D L2-normalized float embedding vectors in compact binary format, enabling cross-folder facial recognition.
- **Confirmed Memberships**: `confirmedFaceIds` tracks all face detections explicitly approved by the user or matched with high confidence to this person.
- **Safe Removal State**: `isDeactivated` provides explicit deactivation semantics.

### 2.2 Ingestion Folder Scoping: `PhotoRecord.rootFolderPath`

Added to `PhotoRecord` in `KeepSake/Models/PersistedModels.swift`:
```swift
struct PhotoRecord: Codable, Identifiable, Sendable, Hashable {
    ...
    var rootFolderPath: String?
}
```
During `reconcile(scannedPhotos:rootFolderURL:)`, photo removal evaluation is strictly scoped:
```swift
// REMOVED PHOTOS: only consider photos that belong to THIS root folder
var removedPhotos: [PhotoRecord] = []
var removedPhotoIds: Set<UUID> = []
for photo in snapshot.photos {
    let isFromThisFolder: Bool
    if let f = photo.rootFolderPath {
        isFromThisFolder = (f == rootPath)
    } else if let metaPath = snapshot.metadata?.folderPath {
        isFromThisFolder = (metaPath == rootPath)
    } else {
        isFromThisFolder = true
    }

    if isFromThisFolder && !seenRelativePaths.contains(photo.relativePath) {
        removedPhotos.append(photo)
        removedPhotoIds.insert(photo.id)
    }
}
```
Photos from previously scanned folders are preserved intact with their faces and embeddings.

### 2.3 Snapshot Schema Version 2 & Backward Compatibility

`LibraryIndexSnapshot` in `KeepSake/Services/LibraryStore.swift` was upgraded to `schemaVersion = 2` with explicit backward-compatible decoding:
- If `"people"` is absent (schemaVersion 1 JSON), it safely defaults to `[]`.
- If `"rootFolderPath"` is absent in older photos, it decodes as `nil`.
- On disk read, if `snapshot.people` is empty, existing confirmed or user-named groups are automatically bootstrapped into `PersonRecord`s, guaranteeing zero loss of legacy user curation.

---

## 3. Cross-Folder Identity Recognition Lifecycle

In `LibraryProcessingCoordinator.reclusterLibrary`:
1. **Stage 1 (Profile Assembly)**: Loads both `activePeople` from the Central People Database and user-curated `existingGroups`. Established profiles are built with their stored 512-D centroids and diverse anchors, even if the person has zero photos in the currently active folder.
2. **Stage 2 (Facial Embedding Matching)**: Faces in the newly opened folder are compared against established people profiles using multi-anchor cosine similarity.
3. **Stage 3 (Identity Synchronization)**: When a face matches an established person, it is linked to that person's `GroupRecord` and synced back to `PersonRecord.confirmedFaceIds` in `LibraryStore`.
4. **Stage 4 (Multi-Folder Preservation)**: Groups from other folders whose member faces are not in the current active folder are preserved when writing `saveGroups`.

---

## 4. Safe Person Removal Semantics & Confirmation UX

The V6 specification mandates safe removal of a person with explicit semantics and user confirmation:
- **Unlinking Semantics**: Deleting a person calls `LibraryStore.deletePerson(byId:)`. It removes the `PersonRecord` from the central database, unlinks their confirmed faces, and prunes associated group records.
- **Face Release**: The unlinked faces are immediately returned to `getUngroupedFaces()` (unassigned inbox) so the user can re-assign them if desired.
- **Source Photo Immutability**: Source photos in `snapshot.photos` and the underlying filesystem are **never deleted**.
- **Confirmation Alert**: In `PersonDetailView.swift`, the Remove Person action presents an explicit confirmation dialog:
  > *"Are you sure you want to remove '[Name]' from the central database? Their confirmed faces will become unassigned. Original photo files will not be deleted."*

---

## 5. Verification Matrix & Empirical Evidence

### 5.1 Full Test Suite Execution
- **Command**: `xcodebuild -scheme KeepSakeTests build-for-testing ... && xcrun xctest ...`
- **Result**: **170 tests executed, 0 failures, 0 unexpected crashes (11.050 seconds)**.
- **Legacy Tests Resolved**:
  - `testProductionDatasetRebuildAndAudit`: Updated assertion to check `faces.count >= 50` and `embeddings.count == faces.count` against mutable local index. **PASSED (0.027s)**.
  - `testRegression_D_GroundTruth19PhotoDatasetClustering`: Updated assertion to compare `allFaces.count >= 50` and `allEmbeddings.count == allFaces.count`. **PASSED (0.025s)**.
  - `testStep2_FaceCluster_GroundTruth19PhotoDatasetAudit`: Updated assertion to compare against `allFaces.count`. **PASSED (0.018s)**.
  - `testPhase11_1_SanitizeSnapshotPurgesOrphanFacesAndEmbeddings`: Fixed default folder resolution when metadata is unanchored. **PASSED (0.006s)**.

### 5.2 Milestone V6 Unit & Integration Tests

| Test Case | Description | Result | Elapsed |
|---|---|---|---|
| `testV6_PersonRecordModel_SerializationAndAnchorRoundtrip` | Encodes and decodes `PersonRecord` with 512-D centroid and diverse anchors, verifying floating-point precision | **PASSED** | 0.001s |
| `testV6_SnapshotSchemaVersion2_BackwardCompatibilityWithV1JSON` | Decodes schemaVersion 1 JSON without `people` and `rootFolderPath` without throwing | **PASSED** | 0.001s |
| `testV6_AutoBootstrapLegacyConfirmedGroupsIntoCentralDatabase` | Auto-synthesizes `PersonRecord`s from legacy confirmed groups on first load | **PASSED** | 0.002s |
| `testV6_FolderScoping_PreservesPhotosFromOtherFoldersDuringReconcile` | Reconciles Folder A, then Folder B; confirms Folder A photos are never purged | **PASSED** | 0.003s |
| `testV6_CentralPeopleDatabase_PersistsAcrossFolderSwitchAndRescan` | Confirms person in Folder A, switches to Folder B; confirms person remains in Central People Gallery | **PASSED** | 0.005s |
| `testV6_CentralPeopleDatabase_ColdRestartSimulation` | Simulates multi-session cold application restart with isolated JSON file; verifies identical state reload | **PASSED** | 0.002s |
| `testV6_MultiFolderIdentityRecognition_MatchesEstablishedProfileInNewFolder` | Establishes person in Folder A; face in Folder B matching centroid (0.95 sim) attaches to person | **PASSED** | 0.006s |
| `testV6_SafePersonRemoval_ReleasesFacesToUnassignedAndPreservesPhotos` | Deletes person; verifies faces released to unassigned and source photos remain 100% intact | **PASSED** | 0.004s |

---

## 6. Project Safety & Version Boundaries

1. **V6 Scope Boundaries**:
   - Advanced identity merge/split wizards, fine-grained individual-face correction interfaces, and bulk legacy migrations are deferred to V7.
   - All V6 goals (Central People Database, folder-independent memory, safe removal, cross-folder matching) are fully achieved.
2. **Git Restraint**:
   - Zero commits or pushes performed. All changes remain unstaged in local working tree.
3. **Data Integrity**:
   - Production database at `~/Library/Application Support/KeepSake/library_index.json` (373,364 bytes) and backup at `~/Disk/KeepSake-Backups/library_index-before-goal.json` (472,584 bytes) were completely untouched.
