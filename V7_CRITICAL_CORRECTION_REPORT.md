# KeepSake V7 Critical Correction Implementation Report
## Folder-Scoped Photos, Global Identity Memory, Legacy Fallback & UI De-duplication

**Date**: 2026-10-12  
**Milestone**: V7 Critical Correction  
**Status**: Verified & Complete  
**Automated Tests**: 184 / 184 Passed (0 Failures, 0 Crashes)  
**Live DB & Backup Status**: 100% Untouched  
**Git Working Tree**: Local changes preserved, strictly 0 commits, strictly 0 pushes  

---

### 1. Executive Summary

This critical correction resolves the architectural discrepancy between global person identity persistence and folder-scoped photo display, fixes the regression in legacy photo record compatibility, fixes the non-functional Remove Person operation, and cleans up redundant candidate review UI controls.

All 184 unit and integration tests execute to completion and pass cleanly in 12.110 seconds. The macOS application builds cleanly without warnings or errors. Original user photographs, the live index file, and backups remain completely untouched.

---

### 2. Architectural Diagnoses and Root Causes

#### A. Root Cause: Cross-Folder Photo Aggregation vs. Folder-Scoped Photos
* **Symptom**: Opening a person's card in the People gallery displayed photos containing that person from all indexed folders across the user's filesystem, rather than restricting the view to the currently selected folder.
* **Root Cause**: `LibraryStore.getPhotos(forGroup:)` previously returned all historical `PhotoRecord`s linked to the person's confirmed faces regardless of which folder was active.
* **Resolution**: Added optional `rootFolderPath` parameter to `LibraryStore.getPhotos(forGroup:rootFolderPath:)`, `getFaces(forGroup:rootFolderPath:)`, `getUniquePhotoCount`, and `getRepresentativeFace`. `PeopleViewModel.loadData` and `selectPerson` now pass the active folder URL down through `IdentityService`, ensuring that:
  - People cards display photo and face counts belonging strictly to the active folder.
  - People detail galleries render only photos and face crops from the active folder.
  - Established identities with 0 photos in the active folder remain visible in the global People database but show 0 photos/faces and nil thumbnails.
  - An empty folder (Folder C) displays zero photos and zero faces without deleting or unlinking global identities.

#### B. Root Cause: Legacy `rootFolderPath == nil` Query Regression
* **Symptom**: During the earlier test run, `testMissingSourcePhotosHandledSafely` crashed with `Signal 5 (SIGTRAP): Fatal error: Index out of range` at line 1114 because `photos[0]` was queried on an empty array.
* **Root Cause**: The newly introduced folder-scoping filter checked `if let pRoot = photo.rootFolderPath { return pRoot == normalizedRoot } else { return false }`. Because synthetic test photos and legacy library records created before folder-scoping had `photo.rootFolderPath == nil`, any query with a non-nil root folder dropped them indiscriminately.
* **Resolution**: Implemented a principled compatibility helper:
  `isPhoto(_:matchingNormalizedRoot:)` applied uniformly across `getPhotos`, `getFaces`, `getUngroupedFaces`, `getGroups`, `getExcludedFaces`, and `getRemovedAssociations`:
  1. **Explicit Root**: Strict path normalization and equality when `photo.rootFolderPath != nil`.
  2. **Relative Path Prefix**: Checks whether `photo.relativePath` starts with the query folder path.
  3. **Library Metadata Folder**: Checks if `snapshot.metadata?.folderPath` aligns with the query folder.
  4. **Single-Folder Fallback**: When the store contains no photos explicitly belonging to a different folder (`!hasOtherExplicitFolders`), legacy single-folder records safely match the active query.
  5. **Conservative Multi-Folder Isolation**: When multiple explicit folders are present, nil-root records without matching metadata are never leaked into foreign folders.

#### C. Root Cause: Broken "Remove Person" Action
* **Symptom**: Selecting "Remove Person…" from the person detail menu opened a confirmation dialog, but confirming removal did not remove the person from the database or release their faces.
* **Root Cause**:
  1. `LibraryStore.deletePerson(byId:)` began with `guard let person = snapshot.people.first(where: { $0.id == id }) else { return }`. If a person record existed in `snapshot.groups` (e.g. bootstrapped legacy groups) but not `snapshot.people`, the function bailed out on line 1.
  2. `IdentityService.deletePerson(id:)` only called `libraryStore.deletePerson` and omitted `libraryStore.deleteGroup`.
  3. `PersonDetailView`'s confirmation dialog did not capture the target person before dismissal.
* **Resolution**:
  - Rewrote `LibraryStore.deletePerson(byId:)` to collect confirmed face IDs across both `snapshot.people` and `snapshot.groups`, remove the record from both tables, unlink and release all member faces back to the unassigned face pool, prune any empty groups, clean up removed associations, and atomically persist changes to disk.
  - Updated `IdentityService.deletePerson` to delete from both `snapshot.people` and `snapshot.groups`.
  - Updated `PersonDetailView` to invoke `viewModel.removePerson(person, rootFolderURL:)` and navigate back to the gallery upon completion.
  - Cancellation simply dismisses the dialog with zero state mutations.

#### D. Root Cause: Duplicate Candidate Review Actions
* **Symptom**: Candidate review detail displayed duplicate sets of "Confirm", "Assign to Person", and "Reject" actions in both the top navigation bar and the banner below it.
* **Resolution**: Removed the redundant buttons from `PersonDetailView.topNavBar`. The single authoritative candidate action row resides exclusively in `candidateReviewBanner` (`Confirm Suggestion…`, `Assign to Person…`, `Reject`). Face-level corrections remain accessible on individual face thumbnails.

---

### 3. Verification & Test Evidence

#### A. Isolated Test Runs
1. **Formerly Failing Test**:
   - Command: `xcrun xctest -XCTest KeepSakeTests/testMissingSourcePhotosHandledSafely build/DerivedData/Build/Products/Debug/KeepSake.app/Contents/PlugIns/KeepSakeTests.xctest`
   - Result: **1 test executed, 1 passed, 0 failures in 0.004 seconds**.
2. **Critical Correction Integration Tests**:
   - Command: `xcrun xctest -XCTest KeepSakeTests/testV7_CriticalCorrection_FolderScopedPhotosAndGlobalIdentityMemory,KeepSakeTests/testV7_CriticalCorrection_RemovePerson_ComprehensiveLifecycle build/DerivedData/Build/Products/Debug/KeepSake.app/Contents/PlugIns/KeepSakeTests.xctest`
   - Result: **2 tests executed, 2 passed, 0 failures in 0.031 seconds**.

#### B. Full Test Suite Execution
- **Command**: `xcrun xctest build/DerivedData/Build/Products/Debug/KeepSake.app/Contents/PlugIns/KeepSakeTests.xctest`
- **Elapsed Time**: 12.110 seconds
- **Exit Status**: Code 0 (Success)
- **Results**: **184 tests executed, 184 passed, 0 failures (0 unexpected), 0 crashes**.

#### C. macOS Application Build
- **Command**: `xcodebuild build -scheme KeepSake -destination "platform=macOS" -derivedDataPath build/DerivedData`
- **Result**: **BUILD SUCCEEDED**. Binary produced at `build/DerivedData/Build/Products/Debug/KeepSake.app/Contents/MacOS/KeepSake`.

---

### 4. Non-Negotiable Safety Checklist

- [x] **Live Database Untouched**: `/Users/vikramaditya/Library/Application Support/KeepSake/library_index.json` (752,935 bytes) preserved without modification.
- [x] **Backup Untouched**: `/Users/vikramaditya/Disk/KeepSake-Backups/library_index-before-goal.json` (472,584 bytes) preserved without modification.
- [x] **Original Photographs Untouched**: Zero user photo files deleted, moved, or altered.
- [x] **Git Hygiene**: Strictly 0 commits, 0 pushes, 0 resets. All 27 working-tree files preserved locally for user review.

---

### 5. Remaining Limitations

- **Cross-Folder Identity Aggregation Search**: Person cards are scoped to the active folder. Searching or filtering global people who have 0 photos in the current folder is supported via the database, but their photo thumbnails in the active folder intentionally show placeholder icons until a folder containing their photos is selected.
- **Milestone Scope**: This concludes V7 Critical Correction and Stabilization. Milestone V8 (Hardening, Performance Profiling & Release Readiness) remains a separate upcoming phase.
