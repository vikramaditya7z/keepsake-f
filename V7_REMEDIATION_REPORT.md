# KeepSake V7 Remediation Implementation Report

**Date**: October 12, 2026  
**Scope**: V7 Remediation & Stabilization (False Face Detection, Recycle Bin, Folder Isolation & Review-State Persistence)  
**Status**: Completed & Verified  
**Target Target**: `KeepSake.app` (macOS 14.0+)  
**Test Suite**: 179 Tests Passing (100% Success Rate)

---

## 1. Executive Summary & Mission Fulfillment

Following the initial implementation of V7 (Identity Corrections, Bulk Assignment, and Cannot-Link constraints), manual testing identified six operational defects:
1. **Suggestion Leaks Across Folders**: Switching between folders (e.g. from `tester` with 19 photos to `RazorPay` with 1 photo, or to an empty folder) caused foreign candidate suggestions and unassigned faces to leak into the active view.
2. **Ambiguous Toolbar Refresh**: The toolbar refresh button did not clearly communicate its operational semantics (rescan vs reload) and risked unwanted reclustering side effects.
3. **Rejection State Loss Across Rescans**: Rejecting a candidate suggestion sent its faces to unassigned, but triggering a folder rescan or reload resurrected the suggestion in pending review.
4. **No False Face Detection Removal ("Not a Face")**: Non-face detections (e.g. shoes, clothing textures, artwork) could not be removed without attempting to assign them to a person or leaving them permanently in unassigned faces.
5. **No Recycle Bin Management**: Excluded detections had no recovery mechanism or permanent removal workflow.
6. **Redundant "Review" Button on Suggestion Cards**: Candidate cards had a redundant "Review" button alongside "Confirm" and "Reject", creating UI clutter.

This remediation pass resolves all six defects at the architectural and presentation layers. Crucially, **the non-destructive principle of KeepSake is preserved: original photo files on disk are never modified, deleted, or moved**. Removing a false detection or emptying the Recycle Bin operates strictly on metadata and vector embeddings within `LibraryStore`.

---

## 2. Root Cause Analysis & Architectural Remediation

### 2.1 Folder Scoping & Review Queue Isolation
- **Root Cause**: `LibraryProcessingCoordinator.reclusterLibrary` loaded all embeddings across the entire database without folder filtering and stamped all generated candidate clusters with the active folder path. Additionally, `LibraryStore.getUngroupedFaces` and `getCandidateGroups` were falling back to returning all records if photos lacked folder metadata.
- **Architectural Fix**:
  - `reclusterLibrary` now strictly filters input photos and embeddings to those belonging to `rootFolderURL.standardizedFileURL.path`.
  - When an active folder contains zero photos, `reclusterLibrary` removes candidate groups for that folder while preserving groups for other folders and all confirmed people.
  - `LibraryStore.getCandidateGroups(forRootFolderPath:)`, `getGroups(forRootFolderPath:)`, and `getUngroupedFaces(forRootFolderPath:)` strictly match `photo.rootFolderPath == activeFolder.path`.
  - For synthetic unit test compatibility (where photos are created in-memory without a `rootFolderPath`), a fallback is only activated if the store contains no photos from conflicting folders (`hasOtherFolders == false`).

### 2.2 Rejection State Persistence Across Rescans & Reloads
- **Root Cause**: In agglomerative clustering, rejected candidate clusters were reconstructed without tracking their rejection provenance, causing them to be saved with `reviewStatus = .candidateSuggestion`.
- **Architectural Fix**:
  - `CandidateCluster` now tracks `isRejected: Bool`. During cluster union, if any constituent cluster was rejected, the resulting cluster is marked `isRejected = true`.
  - During cluster conversion to `CandidateGroupRecord`, clusters with `isRejected == true` receive `reviewStatus = .rejected`.
  - In `reclusterLibrary`, existing unassigned rejected groups are preserved during snapshot updates and are never overwritten as pending suggestions.

### 2.3 False Face Detection Lifecycle ("Not a Face")
- **Root Cause**: There was no domain representation for a detected bounding box that does not correspond to a human face.
- **Architectural Fix**:
  - Extended `FaceRecord` with:
    - `isExcluded: Bool` (defaults to `false` for backward compatibility)
    - `excludedAt: Date?`
    - `exclusionReason: String?` (e.g., `"falseDetection"`)
  - Extended `LibraryIndexSnapshot` with `excludedFaceIds: Set<UUID>`.
  - Added authoritative operations to `LibraryStore` and `IdentityService`:
    - `excludeFace(faceId:reason:)`: Marks face as excluded and unassigns it from any groups or people.
    - `restoreFace(faceId:)`: Clears exclusion flags and returns the face to the unassigned pool.
    - `permanentlyDeleteFace(faceId:)`: Permanently removes the `FaceRecord` and its embedding from the index.
  - **Re-Detection Suppression**: During folder rescans in `LibraryProcessingCoordinator.processSinglePhoto`, newly detected bounding boxes are compared against previously excluded faces on that photo. If the bounding box center distance satisfies:
    $$\|(x_1, y_1) - (x_2, y_2)\|_2 < 0.05$$
    the face is immediately marked `isExcluded = true` and ArcFace embedding extraction is skipped.

### 2.4 Recycle Bin Interface & Inspection
- **Implementation**: Created `RecycleBinView.swift`, registered in `KeepSake.xcodeproj/project.pbxproj`.
- **Capabilities**:
  - Accessible via "Excluded (Recycle Bin)" button in the People gallery sub-header and empty state.
  - Displays photo thumbnail, cropped face preview, photo filename, relative folder path, exclusion timestamp, and reason.
  - Provides per-face "Restore" and "Delete Permanently" (with confirmation dialog).
  - Provides bulk "Restore All" and "Empty Bin" controls.
  - Emphasizes with explanatory text: *"Photographs on disk are never deleted or modified. Permanently deleting only removes the face detection from KeepSake's database."*

### 2.5 Suggestion Card UX Simplification
- In `CandidateReviewCardView` (`PeopleGalleryView.swift`):
  - Removed the redundant "Review" button.
  - Made the entire card body clickable via `.contentShape(Rectangle()).onTapGesture { onClick() }` to navigate directly to candidate detail review.
  - Retained "Confirm" and "Reject" as distinct, prominent, single-click buttons.

### 2.6 Toolbar Refresh Semantics
- In `ContentView.swift`:
  - Updated the refresh button (`arrow.clockwise`) tooltip and accessibility label to `"Rescan active folder for new photos (⌘R)"`.
  - Prevents user ambiguity regarding state reloads vs filesystem scanning.

---

## 3. Code Modifications Summary

| File | Changes Made |
|---|---|
| `KeepSake/Models/PersistedModels.swift` | Added `isExcluded`, `excludedAt`, `exclusionReason` to `FaceRecord` with backward-compatible decoding. Added `excludedFaceIds` to `LibraryIndexSnapshot`. |
| `KeepSake/Services/LibraryStore.swift` | Implemented `excludeFace`, `restoreFace`, `permanentlyDeleteFace`, `getExcludedFaces`, strict folder filtering across all query methods, and sanitization of `excludedFaceIds`. |
| `KeepSake/Services/IdentityService.swift` | Added `excludeFace`, `restoreFace`, `permanentlyDeleteFace`, and `fetchExcludedFaces` forwarding to `LibraryStore`. |
| `KeepSake/Services/LibraryProcessingCoordinator.swift` | Folder-scoped reclustering; exclusion suppression during single photo processing; `isRejected` state propagation during agglomerative clustering; rejected group persistence. |
| `KeepSake/ViewModels/PeopleViewModel.swift` | Added `@Published var recycleBinFaces`, `@Published var showRecycleBinSheet`, exclusion/restoration methods, and bulk exclusion actions. |
| `KeepSake/Views/People/RecycleBinView.swift` | New dedicated SwiftUI view for inspecting, restoring, and permanently deleting false detections. |
| `KeepSake/Views/People/PeopleGalleryView.swift` | Added Recycle Bin entry button and badge count; removed redundant "Review" button on candidate cards; added card body tap gesture. |
| `KeepSake/Views/People/UnassignedFacesView.swift` | Added "Not a Face" button and context menu per face card; added bulk "Not a Face" action to selection toolbar. |
| `KeepSake/Views/People/PersonDetailView.swift` | Added "Not a Face" action button and context menu on candidate and confirmed face cards with confirmation dialog. |
| `KeepSake/Views/ContentView.swift` | Updated toolbar refresh button tooltip and accessibility label to clarify rescan semantics. |
| `KeepSake.xcodeproj/project.pbxproj` | Registered `RecycleBinView.swift` in build files, file references, People group, and sources build phase. |
| `KeepSakeTests/KeepSakeTests.swift` | Added 3 comprehensive remediation test cases covering folder isolation, rejection persistence, and false face exclusion/restoration/deletion. |
| `ARCHITECTURE.md` | Documented Section 14 covering False Face Detection, Exclusion Lifecycle, and Review-State Preservation. |
| `PROGRESS.md` | Updated status and verification log. |

---

## 4. Empirical Verification & Test Results

### 4.1 Unit & Integration Test Suite
Executed the entire project test suite using `xcrun xctest`:

```bash
xcrun xctest /Users/vikramaditya/Disk/Projects/KeepSake/build/DerivedData/Build/Products/Debug/KeepSakeTests.xctest
```

**Results**:
- **Total Test Suites**: 4
- **Total Tests Executed**: 179
- **Failures**: 0
- **Execution Time**: 11.067 seconds

**New Remediation Tests Verified**:
1. `testV7_Remediation_FolderIsolation_EmptyAndDifferentFolders`: Verified that switching between folders (folder A with photos, folder B with photos, folder C empty) strictly isolates suggestions and unassigned faces with 0 cross-folder leakage.
2. `testV7_Remediation_RejectionPersistenceAcrossRescanAndReload`: Verified that rejecting a candidate suggestion marks it rejected and that subsequent re-clustering and store reloads never re-surface the rejected suggestion.
3. `testV7_Remediation_FalseFaceDetection_ExcludeRestorePermanentDelete`: Verified excluding a face, verifying its absence from unassigned faces, restoring it from the Recycle Bin, and permanently deleting it from the index.

### 4.2 Application Build Verification
Compiled the `KeepSake.app` target:

```bash
xcodebuild build -scheme KeepSake -destination 'platform=macOS' -derivedDataPath build/DerivedData
```

**Result**: `** BUILD SUCCEEDED **` (Zero errors, zero warnings).

### 4.3 Database & Backup Safety Verification
Verified that real user library data and backups remain completely untouched:

- Live Database: `/Users/vikramaditya/Library/Application Support/KeepSake/library_index.json` (406 KB, untouched since Oct 12 12:05)
- Baseline Backup: `/Users/vikramaditya/Disk/KeepSake-Backups/library_index-before-goal.json` (462 KB, untouched since Oct 10 11:40)

### 4.4 Git Repository Hygiene
- **Branch**: `main`
- **Commits Created**: 0 (all changes remain uncommitted and local for user review)
- **Pushes Executed**: 0
- **History**: Intact and unmodified.

---

## 5. Conclusion

KeepSake V7 Remediation is complete and thoroughly validated. The application now provides a reliable identity correction pipeline with strict folder isolation, persistent rejection states, safe false face detection removal, and a full-featured Recycle Bin, all while upholding the local-first, non-destructive foundation of KeepSake.
