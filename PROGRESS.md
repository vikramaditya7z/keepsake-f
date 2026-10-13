# PROGRESS.md — KeepSake Identity Loop Memory

## 1. Current Project State

- **Platform**: macOS 14+, Swift 5.9+, SwiftUI, Apple Vision, Core ML, Accelerate (`vDSP`).
- **Active Workspace**: `/Users/vikramaditya/Disk/Projects/KeepSake`.
- **Build Status**: Compiles cleanly with zero compiler warnings or errors (`xcodebuild` targeting macOS 14.0).
- **Test Suite Status**: **211 tests passing (0 failures)** in 11.940 seconds via `KeepSakeTests.xctest`.
- **Active Architecture Milestones**: 
  - **Milestone V3: Genuine On-Device Recognition (COMPLETE)**
  - **Milestone V4: Reliable Candidate Grouping (COMPLETE)**
  - **Milestone V5: Semi-Automatic Identity Review (COMPLETE)**
  - **Milestone V6: Central People Database & Persistent Identity Memory (COMPLETE)**
  - **Milestone V7: Identity Corrections & Bulk Assignment (COMPLETE)**
  - **Milestone V7 Remediation: False Face Detection, Recycle Bin, Folder Isolation & Review-State Persistence (COMPLETE)**
  - **Milestone V7 Follow-up: Global Identity Library, Cross-Folder Photos & Two-Category Recycle Bin (COMPLETE)**
  - **Milestone V7 Critical Correction: Folder-Scoped Photos & UI Action De-Duplication (COMPLETE)**
  - **UI/UX Polish & Persistent Person Cover Photos (COMPLETE)**
  - **Navigation Redesign, Settings Hub & Scrolling Performance (COMPLETE)**
- **Next Milestone**: V8 (Reliability, Performance, Recovery, and Release Readiness).

---

## 2. Verified Working Functionality

- **Photo Ingestion & Scanning**: Recursive filesystem discovery (`PhotoScannerService`), security-scoped bookmarks (`BookmarkManager`), and change classification (`NEW`, `CHANGED`, `UNCHANGED`, `REMOVED`).
- **Filesystem Monitoring**: Native macOS kernel `FSEvents` (`FolderMonitorService`) with actor-isolated debouncing (`DebounceCoordinator`).
- **Background Processing Queue**: Actor-isolated bounded worker pool (`LibraryProcessingQueue`, 2–4 workers) with pause, resume, cancel, retry, and progress metrics.
- **Atomic Local Persistence**: Actor-isolated `LibraryStore` persisting JSON indices with base64/binary float embedding payloads to `~/Library/Application Support/KeepSake/library_index.json`.
- **Vision Face Detection & Landmarks**: Apple Vision `VNDetectFaceRectanglesRequest` and `VNDetectFaceLandmarksRequest` generating normalized bounding boxes and 5-point facial landmarks (`leftEye`, `rightEye`, `nose`, `leftMouth`, `rightMouth`).
- **Isotropic Facial Landmark Alignment (V4)**: Closed-form 2D Umeyama similarity transform in `FacePreprocessingService` aligning faces to canonical InsightFace 112×112 coordinates, with graceful bounding-box fallback on missing/degenerate landmarks.
- **Genuine On-Device Face Recognition (Core ML, V3)**: Thread-safe loaded `buffalo_s.mlmodelc` (InsightFace MobileFaceNet, 512-D L2-normalized float embeddings) executing on Apple Silicon Neural Engine / GPU / CPU via `ArcFaceRecognitionService`.
- **Candidate Grouping Pipeline (V4)**: Ingestion coordinator tags newly discovered clusters as `reviewStatus = .candidateSuggestion` while preserving user-curated profiles as `.confirmed`.
- **Semi-Automatic Identity Review (V5)**:
  - `IdentityService`: provides `fetchCandidateGroups()`, `fetchConfirmedPeople()`, `confirmGroup(id:name:)`, and `rejectCandidateGroup(id:)`.
  - `LibraryStore`: `getUngroupedFaces()` automatically releases faces from rejected candidate suggestions back to the unassigned inbox without deleting photos or face records.
  - `PeopleViewModel`: maintains strict segregation between `candidateGroups` and confirmed `people`, handling confirmation and rejection workflows.
  - `PeopleGalleryView`: renders dedicated "Suggestions Awaiting Review" section with `CandidateReviewCardView` above confirmed people, with one-click "Confirm" (with optional name) and "Reject" controls.
- **Central People Database & Persistent Identity Memory (V6)**:
  - Authoritative `PersonRecord` schema decoupling confirmed human identities from transient folder views.
  - Cross-folder recognition: newly scanned faces automatically match against established central profiles.
  - Folder-scoped photo reconciliation preserving records from previously scanned folders.
- **Identity Corrections & Bulk Assignment (V7)**:
  - Multi-select and bulk assignment/creation in `UnassignedFacesView`.
  - Authoritative merging of duplicate confirmed people (`mergePeople`) with Cannot-Link conflict validation.
  - Granular removal of outlier faces from candidate suggestions and confirmed people.
- **False Face Detection & Recycle Bin (V7 Remediation)**:
  - Dedicated `RecycleBinView`: manages excluded false detections with Restore (returns to unassigned) and Delete Permanently (deletes face record only; original photo files never modified or deleted).
  - "Not a Face" actions available across `UnassignedFacesView` (card button, context menu, bulk toolbar), `CandidateReviewCardView` detail, and `PersonDetailView`.
  - `LibraryProcessingCoordinator.processSinglePhoto`: checks previously excluded face bounding boxes on rescanned photos, preventing re-detection/embedding loops.
  - Rescan/Reclustering Rejection Persistence: rejected candidate groups maintain `reviewStatus = .rejected` and preserve unassigned faces across manual rescans and cold restarts.
  - Strict Folder Scoping: suggestions and unassigned faces are strictly isolated to the active folder; foreign suggestions never leak across folder switches.
  - Direct Candidate Card Interaction: clicking candidate cards directly opens review detail; redundant "Review" button removed.
- **Global Identity Library, Cross-Folder Photos & Two-Category Recycle Bin (V7 Follow-up)**:
  - Global Person Cards with Cross-Folder Photos: opening a person card displays all photos containing their confirmed faces across all indexed folders, with source folder path resolution. Photos screen remains strictly scoped to the active folder.
  - Direct Candidate Assignment: candidate suggestions or individual candidate faces can be assigned directly to an existing confirmed person via `AssignCandidateGroupSheet` without creating a temporary identity.
  - Pre-Confirmation Face Pruning: users can remove mismatched faces from candidate suggestions before confirming them.
  - Granular Post-Confirmation Actions: "Unassign Face" (returns to unassigned), "Move to Recycle Bin" (recorded in Removed from People), "Move to Another Person" (with Cannot-Link validation), and "Not a Face" (excluded false detection).
  - Two-Category Recycle Bin: dedicated tabs for "False Detections" and "Removed from People" with category-specific recovery (Restore to Person, Restore to Unassigned) and permanent deletion.
  - Non-Destructive Integrity: original photographs on disk are strictly immutable and never touched or deleted.
- **Persistent Person Cover Photos & UI/UX Polish (COMPLETE)**:
  - Persistent Cover-Face Selection: confirmed identities feature an explicit, user-selectable `coverFaceId` that persists across folder switches, rescans, reclusters, and application restarts.
  - Cross-Folder Cover Resolution with Strict Folder-Scoped Gallery: when a cover face is explicitly chosen, person cards prioritize it globally for identity presentation, falling back to folder-scoped faces when no cover is set. Browsing photos inside active folders remains strictly folder-scoped.
  - Streamlined Face-Card Actions: replaced clipped, 5-icon button rows in `PersonDetailView` with a primary visible "Cover" toggle button and an organized secondary `ellipsis.circle` Menu categorizing Identity and Removal actions. Full context menu preserved.
  - Cover Indicators: visual star badge overlay on avatar thumbnails in both `PersonCardView` and `PersonDetailView`.
  - Referential Sanitization: removing, unassigning, or excluding a face automatically resets `coverFaceId` if it referenced that face; merging people preserves primary cover selection.

---

## 3. Critical Architectural Discoveries & Resolved Gaps

### 3.1 Model Asset Status (V3 - Resolved)
- Genuine Core ML MobileFaceNet (`buffalo_s.mlmodelc`) converted from official InsightFace ONNX (`w600k_mbf.onnx`), achieving 0.999986 cosine similarity numerical parity.

### 3.2 Preprocessing Landmark Alignment (V4 - Resolved)
- Ground-truth evaluation across 53 faces and 19 photos demonstrated:
  - 49/53 faces (92.5%) successfully aligned via 5-point Umeyama isotropic transform.
  - Mean separation margin between same-identity and different-identity pairs increased from **+0.0186 to +0.1769** (nearly 10× improvement!).
  - Different-identity mean similarity dropped from 0.3179 to **0.1022** (median 0.0589).
  - Maximum same-identity similarity increased from 0.8862 to **0.9349**.
  - **100% precision (0 false positives) achieved at threshold $\ge 0.70$**.

### 3.3 Uncertainty Preservation & User Authority (V5 - Resolved)
- Algorithmic clusters are strictly classified as `.candidateSuggestion` upon discovery.
- Only explicit user confirmation transitions a candidate group to `.confirmed`.
- Rejecting a candidate suggestion sets `reviewStatus = .rejected`, leaving underlying photo and face records intact and releasing member faces back to the unassigned pool.
- Cold-restart persistence verified across simulated multi-session application restarts with 100% fidelity.

### 3.4 Central People Database & Persistent Identity Memory (V6 - Resolved)
- Introduced authoritative `PersonRecord` schema (schemaVersion 2) decoupling user-approved human identities from transient folder views.
- Photo removal evaluation in reconciliation is strictly scoped to the active root folder, ensuring photos from previously indexed folders are never deleted upon switching folders.
- Automatic bootstrapping converts legacy confirmed groups to `PersonRecord` on first load.
- Cross-folder recognition matches newly discovered faces against central person centroids and anchors.

### 3.5 Identity Corrections & Bulk Assignment (V7 - Resolved)
- Added folder scoping on candidate groups and unassigned faces.
- Implemented multi-select, bulk assignment, and bulk creation of persons.
- Enforced Cannot-Link rule: multiple faces originating from the same photograph cannot be assigned to the same person.
- Added granular face removal from candidate groups before confirmation and from confirmed people after confirmation.
- Authoritative person merge with side-by-side preview and Cannot-Link verification.

### 3.6 Stabilization & Remediation (V7 Remediation - Resolved)
- **Folder Isolation**: Input photos and embeddings to `reclusterLibrary` are strictly scoped to the active folder; when an empty folder is selected, candidate groups for that folder are pruned while preserving groups from other folders.
- **Rejection Persistence**: Candidate clusters track `isRejected` state, preserving it through agglomeration and synthesis so rejected suggestions never reappear after rescan/reclustering.
- **False Face Detection Exclusion & Recycle Bin**: Non-face artifacts (e.g. shoe in photo 4) can be excluded to Recycle Bin. Excluded bounding boxes are remembered during future scans to prevent re-extraction loops.
- **Clean Suggestion Card UI**: Candidate cards open review detail directly upon click; redundant "Review" button removed.

### 3.7 Global Identity Library, Cross-Folder Photos & Two-Category Recycle Bin (V7 Follow-up - Resolved)
- **Cross-Folder Person Photo Retrieval**: `LibraryStore.getPhotos(forGroup:)` resolves face associations from `snapshot.people` first, ensuring that opening a person card displays all photos containing their confirmed faces across all indexed folders, while keeping the main Photos gallery strictly scoped to the active folder.
- **Cross-Folder URL Path Resolution**: `PeopleViewModel.selectPerson` dynamically resolves photo URLs using each photo's stored `photo.rootFolderPath`, preventing broken thumbnail rendering when displaying photos from inactive folders.
- **Direct Candidate Assignment**: Candidate suggestions can be assigned directly to an existing confirmed person via `AssignCandidateGroupSheet` and `bulkAssignFaces` without creating temporary or intermediate identities.
- **Candidate Pre-Confirmation Face Removal**: Outlier or mismatched faces can be removed from candidate suggestion groups prior to confirmation, returning to the unassigned queue.
- **Two Distinct Recycle Bin Workflows**: Dedicated two-tab `RecycleBinView` segregating "False Detections" (`isExcluded: true`) from "Removed from People" (`RemovedFaceAssociationRecord`), providing category-specific restore (Restore to Person, Restore to Unassigned) and permanent deletion.
- **Complete Photo Safety Guarantee**: All face association removal, recycling, and exclusion operations guarantee 100% immutability of original photograph files on disk.

### 3.8 Folder-Scoped Photos, Global Identity Memory & UI De-duplication (V7 Critical Correction - Resolved)
- **Folder-Scoped Photo & Face Filtering**: `LibraryStore.getPhotos(forGroup:rootFolderPath:)`, `getFaces`, `getUniquePhotoCount`, and `getRepresentativeFace` strictly scope query results to the active folder. Person cards and detail views show photo counts, face counts, and thumbnails from the active folder only, preventing cross-folder photo contamination while maintaining global identity profiles.
- **Principled Legacy Fallback via `isPhoto`**: Implemented a unified `isPhoto(_:matchingNormalizedRoot:)` helper across photo queries, unassigned face queries, and recycle bins. Enforces strict root equality for explicit roots while safely supporting legacy records without `rootFolderPath` when safe ownership is provable.
- **Authoritative Remove Person Lifecycle**: `LibraryStore.deletePerson(byId:)` purges person records and matching group records, unlinks member faces back to the unassigned pool, cleans up removed associations, and atomically persists to disk. Cancellation in `PersonDetailView` leaves identities untouched.
- **UI Action De-Duplication**: Eliminated duplicate `Confirm…`, `Assign to Person…`, and `Reject` buttons from `PersonDetailView.topNavBar`, leaving the single authoritative candidate action row in `candidateReviewBanner`.

### 3.9 UI/UX Polish & Persistent Person Cover Photos (Resolved)
- **Identity-Level Persistent Cover Selection**: Added `coverFaceId: UUID?` to `PersonRecord` and `GroupRecord` with full backward compatibility in `PersistedModels.swift`. Users can explicitly pin any active face associated with an identity as their cover photo.
- **Cross-Folder Cover Resolution**: `LibraryStore.getRepresentativeFace(forGroup:rootFolderPath:)` prioritizes a valid persistent cover face globally so gallery cards display the chosen avatar across folders, while strictly respecting folder scoping when no cover photo is configured.
- **Redesigned Face-Card Actions**: Replaced the cramped, 5-icon button rows in `PersonDetailView` with a primary visible "Cover" button (with star badge) and a clean secondary `ellipsis.circle` Menu categorizing Identity and Removal actions. Preserved complete context-menu support.
- **Visual Avatar Indicators**: Added subtle gold star badges on cover photo thumbnails in `PersonCardView` and `PersonDetailView`.
- **Referential Sanitization & Lifecycle Safety**: `LibraryStore` automatically resets `coverFaceId` if the referenced face is removed, excluded as a false detection, or deleted; person merges preserve cover selections; decoding legacy JSON snapshots defaults gracefully without errors.

### 3.10 Navigation Redesign, Settings Hub & Scrolling Performance (Resolved)
- **Primary Navigation Redesign**: Structured top-level navigation into three distinct, independently navigable sections: **Photos | People | Suggestions**.
  - **Photos**: Primary browsing gallery scoped strictly to the active folder, showing folder metadata, photo counts, sorting menu, rescan controls, and photo detail viewer.
  - **People**: Dedicated exclusively to confirmed human identities (`viewModel.people`). Search, grid, cover photos with gold star badges, and person detail drill-down. Completely eliminated candidate review queue clutter from the People gallery.
  - **Suggestions**: Dedicated review workspace for candidate face groups proposed by identity clustering (`viewModel.candidateGroups`). Features candidate review cards, confirm dialog, direct assignment to existing people (`AssignCandidateGroupSheet`), rejection, and pending review count badge in navigation.
- **Unified Settings Hub**: Introduced gear icon button (`gearshape`, ⌘,) in the top toolbar presenting a native macOS 4-category Settings Hub:
  - **General**: Photo sort order, automatic folder monitoring toggle, thumbnail grid size slider, and developer mode toggle.
  - **Library & Cache**: Measures disposable on-disk thumbnail cache size, displays cache path, provides "Show in Finder" and safe "Clear Cache" with confirmation alert, and reports persistent library database metrics (`library_index.json`).
  - **Recycle Bin**: Centralizes False Detections and Removed from People recovery and permanent deletion workflows.
  - **Unassigned Faces**: Centralizes unassigned face browsing, multi-select, and bulk assignment/creation workflows.
  - Removed redundant Recycle Bin and Unassigned Faces buttons from main browsing subheaders.
- **Measured Scrolling Performance Improvement**:
  - Implemented `DiskThumbnailCache` storing downsampled JPEGs in `~/Library/Caches/com.keepsake.KeepSake/Thumbnails/` using SHA256 hashed filenames.
  - Refactored `ThumbnailLoader` from a serialized actor into a high-concurrency loader using detached user-initiated tasks, fast synchronous in-memory NSCache checks, and CoreGraphics downsampling with metadata preview prioritization (`kCGImageSourceCreateThumbnailFromImageIfAbsent`).
  - Optimized `PhotoThumbnailView` with synchronous in-memory cache pre-population on view initialization, eliminating `ProgressView` loading flicker during scrolling.
- **Verification**: Built cleanly with zero warnings/errors; verified across 211 tests with 0 failures in `KeepSakeTests.xctest`.

---

## 4. Failed Approaches & Lessons Learned

| Approach | What Was Attempted | Why It Failed | Lesson Learned |
|---|---|---|---|
| **Global Cosine Threshold Lowering (to 0.48)** | Lowered clustering threshold from 0.60 to 0.48 in `CosineGraphClusteringService` to reduce singleton groups from 52 to 38. | Caused severe cross-person contamination in the UI (e.g. Rishita's person card was contaminated with faces of other people). | Angular margin on synthetic/weak embeddings cannot be fixed by lowering a global threshold. Cannot-Link and multi-anchor models are mandatory. |
| **Synthetic 2D-DCT Feature Projection** | Handcrafted spatial-frequency Fourier/DCT projection over 112x112 pixel tensor with anatomical center weighting. | Inadequate facial discriminability across variations in lighting, pose, distance, and expression. | Genuine deep neural representations (e.g. MobileFaceNet / buffalo_s weights) are required for human-grade recognition. |
| **Direct Bounding-Box Aspect Squishing** | Direct anisotropic resizing of wide bounding-box crops to 112×112. | Squished faces horizontally, degrading ArcFace cosine similarity to ~0.33. | Isotropic Umeyama similarity transform using 5 facial landmarks is essential to preserve face geometry and orientation. |
| **Silent Auto-Confirmation of Algorithmic Clusters** | Treating every newly formed cluster as a confirmed person in `GroupRecord`. | Users lose control over identity ground truth; ambiguous clusters corrupt galleries. | Two-phase identity lifecycle: algorithmic groups are candidates awaiting human confirmation or rejection. |
| **Unscoped Library Reclustering** | Feeding all library embeddings across all folders into `reclusterLibrary` during folder refresh. | Re-stamped all candidate suggestions with the active folder path, leaking suggestions into unrelated or empty folders. | Clustering input must be scoped strictly to active folder photos while preserving existing groups from other folders. |
| **Naïve Nil-Root Filtering in Folder Scoping** | Discarding any `PhotoRecord` with `rootFolderPath == nil` when a non-nil `rootFolderPath` query was supplied. | Caused legacy photo records and synthetic mock fixtures without explicit roots to disappear, crashing tests on index lookups. | Principled compatibility via `isPhoto` checking explicit roots, relative path prefixes, metadata folder, and single-folder fallback is required. |

---

## 5. Recent Experiments & Verified Results

- **Full Test Suite Execution (2026-10-12)**:
  - Command: `xcodebuild -scheme KeepSakeTests ... && xcrun xctest ...`
  - Result: **194 tests passed, 0 failures (0 unexpected)** in 11.443 seconds.
  - 10 Dedicated Persistent Cover Photo Tests passed:
    - `testCoverFace_FallbackToRepresentativeFaceWhenCoverFaceNil` (PASSED - 0.003s)
    - `testCoverFace_ExplicitSelectionPersistsAndOverridesFallback` (PASSED - 0.005s)
    - `testCoverFace_ToggleOrReplaceCoverFace` (PASSED - 0.004s)
    - `testCoverFace_PersistsAcrossColdRestart` (PASSED - 0.007s)
    - `testCoverFace_PersistsAcrossFoldersWhilePhotoScopingRemainsStrict` (PASSED - 0.004s)
    - `testCoverFace_InvalidOrForeignFaceIdRejected` (PASSED - 0.003s)
    - `testCoverFace_RemovedFaceResetsCoverFaceToNil` (PASSED - 0.006s)
    - `testCoverFace_BackwardCompatibleLegacyDecodingWithoutCoverFaceId` (PASSED - 0.001s)
    - `testCoverFace_MergePeoplePreservesCoverFace` (PASSED - 0.004s)
    - `testCoverFace_SanitizeSnapshotRemovesInvalidCoverFaceId` (PASSED - 0.003s)
  - Key Integration & Regression Tests passed:
    - `testV7_CriticalCorrection_FolderScopedPhotosAndGlobalIdentityMemory` (PASSED - 0.015s)
    - `testV7_CriticalCorrection_RemovePerson_ComprehensiveLifecycle` (PASSED - 0.007s)
    - `testMissingSourcePhotosHandledSafely` (PASSED - 0.004s)
    - `testV7_FollowUp_CrossFolderPersonPhotosAndFaces` (PASSED - 0.003s)
    - `testV7_FollowUp_DirectCandidateAssignmentToExistingPerson` (PASSED - 0.005s)
    - `testV7_FollowUp_CandidatePreConfirmationFaceRemoval` (PASSED - 0.005s)
    - `testV7_FollowUp_TwoDistinctRecycleBins_FalseDetectionsAndRemovedFromPeople` (PASSED - 0.009s)
    - `testV7_Remediation_FolderIsolation_EmptyAndDifferentFolders` (PASSED - 0.003s)
    - `testV7_Remediation_RejectionPersistenceAcrossRescanAndReload` (PASSED - 0.005s)
    - `testV7_Remediation_FalseFaceDetection_ExcludeRestorePermanentDelete` (PASSED - 0.004s)

---

## 9. Startup-State Bug Fix & Folder Switching Verification

- **Current State**: COMPLETED & VERIFIED
- **Changes Implemented**:
  1. `KeepSake/ViewModels/PhotoBrowserViewModel.swift`:
     - Removed automatic `restorePersistedFolder()` on app initialization so KeepSake starts cleanly with `selectedFolderURL == nil` and zero displayed photos.
     - Added `activeFolderGeneration: UInt64` and `clearActiveFolder()` to track active folder lifecycle and invalidate in-flight async operations.
     - Scoped `refreshLibraryStats()` to `selectedFolderURL` (returning 0 indexed/detected counts when no folder is active).
     - Guarded all asynchronous scanning and reconciliation callbacks with generation and path checks (`guard !Task.isCancelled, self.activeFolderGeneration == generation, self.selectedFolderURL?.standardizedFileURL.path == targetFolderPath`).
  2. `KeepSake/ViewModels/PeopleViewModel.swift`:
     - Added `activeFolderPath: String?` and `loadGeneration: UInt64`.
     - Enforced that when `rootFolderURL == nil`: `candidateGroups = []`, `unassignedFaces = []`, `selectedUnassignedFaceIds = []`, `recycleBinFaces = []`, `removedAssociations = []`, `selectedPersonPhotos = []`, `selectedPersonFaces = []`, while global confirmed `PersonRecord`s remain in memory with `uniquePhotoCount = 0` and `faceCount = 0`.
     - Implemented immediate folder-state invalidation when switching folders before any `await`.
     - Guarded `loadData`, `selectPerson`, and `loadRecycleBin` with generation checks so delayed async completions cannot leak old folder data.
  3. `KeepSake/Views/People/PeopleGalleryView.swift`:
     - Added distinct "No Folder Selected" banner with "Choose Folder…" button when `rootFolderURL == nil` and confirmed people exist in the global identity memory, distinguishing it from the "All Candidate Suggestions Reviewed" state.
  4. `KeepSakeTests/KeepSakeTests.swift`:
     - Added 8 dedicated regression tests covering: fresh startup with populated index, global confirmed identity preservation, folder selection, folder switching, empty folder switching, in-flight scan cancellation, cold restart, and post-launch matching/discovery.
     - Aligned legacy V5/V7 tests with folder-scoped active operations and isolated ground-truth 19-photo audit tests.
- **Verification Results**:
  - Test Suite: 206/206 tests passing (0 failures).
  - Build: Clean compile and link of both `KeepSake` app and `KeepSakeTests` test bundle.
  - Live Library Safety: `~/Library/Application Support/KeepSake/library_index.json` and backup directories preserved without modification.

