# KeepSake UI/UX Polish & Persistent Person Cover Photos Implementation Report

**Date**: 2026-10-12  
**Milestone**: UI/UX Polish & Persistent Person Cover Photos  
**Status**: Verified & Complete  
**Automated Tests**: 194 / 194 Passed (0 Failures, 0 Crashes)  
**Live DB & Backup Status**: 100% Untouched  
**Git Working Tree**: Local changes preserved, strictly 0 commits, strictly 0 pushes  

---

### 1. Executive Summary

This milestone successfully implements persistent cover-face selection for confirmed identities and refines the face-card action interface in `PersonDetailView`, achieving a clean, native macOS experience without altering core recognition models or violating folder-scoping boundaries.

Key outcomes:
1. **Persistent Cover-Face Selection**: Confirmed persons (`PersonRecord` and `GroupRecord`) now store an explicit, user-selected `coverFaceId: UUID?`. The chosen cover face persists across folder switches, rescans, reclusters, and application restarts.
2. **Cross-Folder Cover Resolution with Strict Folder-Scoped Galleries**: Gallery cards in `PeopleGalleryView` dynamically prioritize the selected cover face globally across indexed folders so the user's preferred avatar is always displayed, while falling back to folder-scoped representative faces when no cover is set. Photo browsing and face counts inside the active folder remain strictly folder-scoped.
3. **Streamlined Face-Card Actions**: Replaced the cramped 5-icon button row on each face card in `PersonDetailView` with a primary visible "Cover" toggle button (highlighted with gold tint when active) and an organized secondary `ellipsis.circle` Menu categorizing Identity and Removal actions. The full context menu is preserved for power users.
4. **Visual Avatar Badges**: Added a gold star badge indicator on the person's avatar in `PersonCardView` and `PersonDetailView` to indicate an explicit cover photo selection.
5. **Referential Integrity & Backward Compatibility**: Comprehensive lifecycle handling automatically resets `coverFaceId` if the referenced face is unassigned, removed to the Recycle Bin, excluded as a false detection, or deleted. Legacy JSON indices lacking `coverFaceId` decode seamlessly with nil defaults.
6. **Verification**: 10 dedicated automated tests were added, bringing the test suite to **194 passed tests with 0 failures**. The macOS application bundle compiles and signs cleanly.

---

### 2. Architectural Design and Changes

#### A. Data Model (`PersistedModels.swift`)
- Extended `GroupRecord` and `PersonRecord` with `var coverFaceId: UUID? = nil`.
- Updated memberwise initializers, `CodingKeys`, `init(from decoder:)`, and `encode(to encoder:)`.
- Guaranteed 100% backward compatibility: when decoding legacy snapshots without `coverFaceId`, the field decodes safely as `nil` without failing or throwing.

#### B. Storage & Lifecycle Layer (`LibraryStore.swift`)
- Added `setCoverFace(personId: UUID, faceId: UUID?) async throws`:
  - Validates that `faceId` belongs to the specified person and is active (not excluded, not in the cannot-link/removed table).
  - Atomically updates both `snapshot.people` and `snapshot.groups`, persisting to disk.
- Updated `getRepresentativeFace(forGroup: UUID, rootFolderPath: String? = nil)`:
  - If a valid `coverFaceId` exists on the person/group, it is fetched globally and returned as the representative face for avatar presentation.
  - If no `coverFaceId` is set, the method retains strict folder scoping: it returns the representative face belonging to `rootFolderPath`, or `nil` if the person has no faces in the active folder.
- Integrated `coverFaceId` referential sanitization:
  - `removeFaceFromPerson`: resets `coverFaceId = nil` if the removed face was the cover.
  - `removeFaceToRecycleBin` & `excludeFace`: resets `coverFaceId = nil` if the affected face was the cover.
  - `permanentlyDeleteFace`: clears `coverFaceId` referencing the deleted face across all people and groups.
  - `mergePeople`: preserves the target person's cover face, or falls back to the source person's cover face if the target had none.
  - `sanitizeSnapshot`: validates that `coverFaceId` points to an existing, non-excluded, active face belonging to the person; clears orphaned references.
  - Bootstrapping: preserves `coverFaceId` when synthesizing `PersonRecord` from legacy groups.

#### C. Service & ViewModel Coordination (`IdentityService.swift` & `PeopleViewModel.swift`)
- Added `setCoverFace(personId:faceId:)` to `IdentityServiceProtocol` and `IdentityService`.
- Added `coverFaceId: UUID?` to `PersonDisplayModel` in `PeopleViewModel`, updating `hash(into:)` and `==`.
- Populated `coverFaceId` during `loadData` for confirmed people and candidate suggestions.
- Implemented `PeopleViewModel.setCoverFace(for person: PersonDisplayModel, faceId: UUID?, rootFolderURL: URL?)`:
  - Instantly updates local UI state on `selectedPerson` and `people`.
  - Authoritatively invokes `identityService.setCoverFace(personId:faceId:)`.

#### D. User Interface Refinements (`PersonDetailView.swift` & `PersonCardView.swift`)
- **Redesigned Face-Card Actions**: Replaced cramped mini-buttons with:
  - **Primary Action**: "Cover" / "Set Cover" toggle button with `star.fill` / `star` icon, tinted in warm gold when active.
  - **Secondary Action Menu (`ellipsis.circle`)**:
    - Section "Identity": "Move to Another Person…" (`arrow.right.arrow.left`), "Unassign Face" (`person.crop.circle.badge.minus`).
    - Section "Removal": "Move Association to Recycle Bin" (`trash`), "Not a Face" (`eye.slash`).
  - **Context Menu**: Full right-click context menu retained with matching options.
- **Visual Star Badges**:
  - `PersonDetailView`: Hero header and face card display a gold star badge (`star.fill`) in the top-right corner of the cover face thumbnail.
  - `PersonCardView`: Subtle gold star badge in the bottom-right corner of the person avatar when an explicit cover photo is configured.

---

### 3. Test Coverage & Verification

Added 10 comprehensive unit and integration tests in `KeepSakeTests.swift`:

1. `testCoverFace_FallbackToRepresentativeFaceWhenCoverFaceNil`: Verifies default representative face fallback when no cover face is explicitly set.
2. `testCoverFace_ExplicitSelectionPersistsAndOverridesFallback`: Confirms setting a specific cover face overrides default sorting and persists in the store.
3. `testCoverFace_ToggleOrReplaceCoverFace`: Verifies changing or unsetting the cover face updates both `PersonRecord` and `GroupRecord`.
4. `testCoverFace_PersistsAcrossColdRestart`: Verifies full serialization and deserialization across simulated cold app restarts.
5. `testCoverFace_PersistsAcrossFoldersWhilePhotoScopingRemainsStrict`: Proves that a cover face from Folder A remains visible as the person's avatar when viewing Folder B, while photo queries in Folder B remain strictly folder-scoped.
6. `testCoverFace_InvalidOrForeignFaceIdRejected`: Validates that attempting to set a non-existent face or a face belonging to a different person throws an error and does not mutate state.
7. `testCoverFace_RemovedFaceResetsCoverFaceToNil`: Verifies that unassigning or moving the cover face to the recycle bin automatically resets `coverFaceId` to `nil`.
8. `testCoverFace_BackwardCompatibleLegacyDecodingWithoutCoverFaceId`: Verifies seamless JSON decoding of legacy snapshots without `coverFaceId`.
9. `testCoverFace_MergePeoplePreservesCoverFace`: Verifies cover face preservation during person merge operations.
10. `testCoverFace_SanitizeSnapshotRemovesInvalidCoverFaceId`: Confirms referential repair in `sanitizeSnapshot` cleans up orphaned cover face IDs.

#### Full Test Suite Execution
- **Command**: `xcrun xctest ./build/DerivedData/Build/Products/Debug/KeepSake.app/Contents/PlugIns/KeepSakeTests.xctest`
- **Result**: **194 tests passed, 0 failures (0 unexpected) in 11.443 seconds**.
- **macOS App Bundle**: Built and signed cleanly targeting macOS 14.0.

---

### 4. Non-Negotiable Safety Checklist

- [x] Live database (`~/Library/Application Support/KeepSake/library_index.json`) untouched.
- [x] External backup (`~/Disk/KeepSake-Backups/library_index-before-goal.json`) untouched.
- [x] Zero user photos modified or deleted on disk.
- [x] Zero Git commits, pushes, or resets performed; all 27 working tree files preserved.
- [x] Folder-scoped photo isolation strictly maintained.
