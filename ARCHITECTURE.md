# Keepsake Architecture

Keepsake is a native macOS application for private, local photo organization and face-based indexing. This document outlines the system architecture, design principles, and component boundaries.

---

## 1. High-Level Architectural Vision

```
┌─────────────────────────────────────────────────────────┐
│                 User Interface (SwiftUI)                │
└────────────────────────────┬────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────┐
│               Photo Library / File Access               │
└────────────────────────────┬────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────┐
│                Photo Processing Pipeline                │
└────────────────────────────┬────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────┐
│                     Face Detection                      │
└────────────────────────────┬────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────┐
│               Face Recognition / Embeddings             │
└────────────────────────────┬────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────┐
│               Face Similarity / Clustering              │
└────────────────────────────┬────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────┐
│                 Local Metadata & Index                  │
└────────────────────────────┬────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────┐
│               People / Photo Gallery UI                 │
└─────────────────────────────────────────────────────────┘
```

---

## 2. Layer Responsibilities

1. **User Interface (SwiftUI)**
   - Provides a clean, modern macOS interface built with SwiftUI.
   - Manages user interactions: folder selection, import status, viewing photo grids, inspecting detected people clusters, naming/merging people.
   - Keeps UI responsive by delegating heavy processing to background actors/queues.

2. **Photo Library / File Access**
   - Handles macOS security-scoped bookmark access to user-selected folders and file URLs.
   - Discovers image files (`.jpg`, `.heic`, `.png`, etc.) safely and non-destructively without modifying original user files.
   - Employs file hashing / modification tracking to detect new, modified, or deleted files without rescanning unchanged photos.

3. **Photo Processing Pipeline**
   - Coordinates background processing stages using Swift Structured Concurrency.
   - Provides pause, resume, progress reporting, and batching to maintain responsiveness and avoid memory exhaustion on large photo libraries.

4. **Face Detection**
   - Scans image frames locally to identify face bounding boxes and landmarks.
   - Filters out low-confidence, blurry, or degenerate face crops.
   - Decoupled via protocols to allow evaluation of different detection backends.

5. **Face Recognition / Embeddings**
   - Generates high-dimensional numerical feature embeddings representing facial identities.
   - Decoupled from detection so different local models (e.g., Apple Vision feature prints, Core ML models, InsightFace / ArcFace models) can be evaluated and benchmarked without rewriting the rest of the application.

6. **Face Similarity / Clustering**
   - Computes distance metrics (e.g., cosine similarity) between face embeddings.
   - Clusters faces into unique person identities incrementally.
   - Supports user-driven manual overrides (reassigning false positives, merging duplicate clusters, naming people).

7. **Local Metadata & Index**
   - Persists photo metadata, face locations, embeddings, person associations, and scan state locally on the user's Mac.
   - Designed for fast retrieval and filtering without external database servers or cloud sync.

8. **People / Photo Gallery UI**
   - Presents a dedicated "People" view showing recognized face clusters with cover photos.
   - Allows drilling down into a person to view all matching photos, with fast zoom, metadata inspection, and clean layout.

---

## 3. Key Design Principles

- **Native macOS Experience**: Developed using Swift, SwiftUI, and native macOS design patterns for high performance, smooth window management, and native macOS feel.
- **Local-First & Private**: All image processing, embedding computation, indexing, and storage remain entirely local on the user's device. No cloud storage, no remote telemetry, and no remote AI endpoints.
- **Incremental & Resumable Processing**: Handles large photo collections through incremental indexing and dirty-checking, preventing unnecessary rescans of unchanged files.
- **Background Concurrency**: Compute-intensive CV/ML operations run off the main thread, maintaining a fluid 60/120fps UI.
- **Model Agility**: ML components are isolated behind clean Swift protocols to permit testing and swapping detection and recognition algorithms as Apple silicon and local ML models evolve.

---

## 4. Current Implementation vs. Future Components

To ensure orderly, disciplined development, Keepsake is built in discrete phases.

#### Current Implementation (Phase 7 — Background Library Processing)
- **Bounded-Concurrency Background Processing Queue (`LibraryProcessingQueue`)**:
  - Swift Concurrency `actor LibraryProcessingQueue` orchestrating a bounded worker pool (`min(max(coreCount / 2, 2), 4)` concurrent worker tasks).
  - Explicit queue lifecycle state machine: `.idle`, `.processing`, `.paused`, `.completed`, `.cancelled`.
  - Comprehensive live progress tracking via `QueueProgressMetrics` (total, completed, failed, remaining, active filename, detected faces, embeddings, throughput rate in photos/sec, and elapsed time).
- **Incremental Reconciliation & Dirty-Checking**:
  - Scans filesystem and categorizes items into `NEW`, `CHANGED`, `UNCHANGED`, and `REMOVED`.
  - Only `NEW` and `CHANGED` items are enqueued for Vision face detection and ArcFace embedding generation. `UNCHANGED` items are skipped instantly. Stale records for `REMOVED` photos are pruned.
- **Pipeline Controls**:
  - Full user and programmatic control: `Start`, `Pause`, `Resume`, `Cancel`, and `Retry Failed Photos`.
  - Pausing halts dequeuing new items while letting in-flight tasks finish cleanly; resuming wakes suspended workers without losing progress.
  - Cancellation immediately halts processing tasks and marks the queue `.cancelled`.
  - `Retry Failed`: Automatically resets `.failed` photo records to `.needsReprocessing` and re-queues them.
- **App Restart & Crash Recovery**:
  - Cold start reconciliation detects any photo left in `.processing` state from an abnormal exit and resets them to `.needsReprocessing` with an explanatory failure tag.
  - Already `.processed` photos are preserved untouched.
- **Fault-Tolerant Single-Item Failure Isolation**:
  - Corrupt image files or decode failures capture `PhotoRecord.failureReason` and transition the photo to `.failed` without crashing or aborting the queue.
  - Photos with zero detectable faces transition to `.processed` with `detectedFacesCount = 0` (valid successful outcome).
- **Deferred Clustering Refresh**:
  - Clustering is deferred until queue completion or batch boundaries rather than re-running full graph clustering after every individual image, avoiding $O(N^2)$ quadratic slowdowns during large imports.
- **Memory Efficiency & Resource Management**:
  - Individual photos are decoded on demand and released immediately after embedding generation.
  - Bounded concurrency ensures peak memory usage remains stable regardless of total library size.
- **Testing & Verification**: 60 automated unit tests in `KeepSakeTests` covering bounded worker execution, pause/resume state retention, cancellation responsiveness, restart recovery of stuck `.processing` states, retry workflows, zero-face success, failure isolation on corrupted images, multi-face photos, deferred clustering execution, and deterministic performance benchmarks.

---

## 5. Persistence Technology Evaluation & Architecture

### Persistence Selection: Actor-Isolated Native Snapshot Store

| Consideration | Native Snapshot Store (Selected) | Core Data / SwiftData | SQLite / GRDB | Vector Database (Chroma/Milvus) |
| :--- | :--- | :--- | :--- | :--- |
| **Dependencies** | **Zero external dependencies**; standard Swift standard library & `Foundation`. | Built-in Apple framework, but prone to schema migration friction during rapid iterative development. | Requires C-bridge or third-party wrapper package. | Heavyweight, overkill for local single-user library $(< 50,000$ photos). |
| **Concurrency & Thread Safety** | Guaranteed by Swift Concurrency `actor LibraryStore`. | Requires context confinement (`NSManagedObjectContext` concurrency rules). | Requires SQLite lock handling and connection pooling. | Out-of-process daemon or server overhead. |
| **Binary Embedding Performance** | Exact contiguous byte arrays (2,048 bytes per 512-D float) decoded instantly into memory. | Stored as `BinaryData` with transformable overhead. | `BLOB` column storage. | Custom indexing format. |
| **Atomic Durability** | `Data.write(to:options: .atomic)` writes to temporary file before replacing destination. | WAL mode write-ahead log. | Journal / WAL file. | Proprietary storage format. |
| **Inspectability & Diagnostics** | Human-readable metadata/photo JSON combined with base64/binary payloads. | Binary database file. | Binary `.sqlite` file. | Proprietary storage directory. |

---

## 6. Conceptual Taxonomy & Architectural Boundaries

To preserve rigorous separation of concerns, Keepsake strictly distinguishes the following four layers:

```
┌─────────────────────────┐
│     FACE DETECTION      │  "There is a face here." (Vision VNDetectFaceRectanglesRequest → Bounding Box)
└────────────┬────────────┘
             │
             ▼
┌─────────────────────────┐
│     FACE EMBEDDING      │  "This face has a numerical representation." (ArcFace 512-D L2-normalized float vector)
└────────────┬────────────┘
             │
             ▼
┌─────────────────────────┐
│         CLUSTER         │  "These faces appear statistically similar." (Average-linkage cosine graph cluster)
└────────────┬────────────┘
             │
             ▼
┌─────────────────────────┐
│      USER IDENTITY      │  "The user has decided these faces represent this person." (Custom name, merged/reassigned groups)
└─────────────────────────┘
```

1. **Face Detection**: Geometric location of a face within an image frame.
2. **Face Embedding**: High-dimensional feature vector extracted from a normalized face crop.
3. **Cluster**: Mathematical group formed by cosine similarity thresholding.
4. **User Identity**: User-curated entity (`GroupRecord` with `customName`, curated `memberFaceIds`). User edits do not alter the underlying embeddings or face detection geometry.

---

## 7. Identity & Group Management Behavior

### Group Membership Model & Multi-Face Photos
- A photo may contain multiple faces ($F_1, F_2, F_3$).
- Each face record references its parent photo (`FaceRecord.photoId`).
- A `GroupRecord` contains a list of member face IDs (`memberFaceIds: [UUID]`).
- When querying photos for a person, `IdentityService.fetchPhotos(forGroupId:)` resolves the unique `PhotoRecord`s for all member faces. If a photo contains multiple faces of the same person, the photo is counted and shown **exactly once**. If a photo contains faces from Person A and Person B, it appears in both galleries without duplicating the underlying photo record.

### Person Renaming
- Renaming modifies `GroupRecord.customName`.
- `GroupRecord.displayName` resolves to `customName` if present and non-empty, otherwise falling back to `"Person \(groupIndex)"`.
- Renaming is purely user-controlled; Keepsake never attempts automatic or contact-based name inferencing.

### Person Merging
- Merging Person B into Person A combines their `memberFaceIds` using a set union (preventing duplicate face references).
- Person B's `GroupRecord` is deleted from the persistent store, preserving referential integrity.
- Person A's centroid $\hat{c}$, average similarity, and representative face are recalculated from the stored embeddings.

### Face Removal & Reassignment
- Removing a face from a person removes its `UUID` from `GroupRecord.memberFaceIds`. The underlying `FaceRecord` and `EmbeddingRecord` remain intact in the library index.
- If a group becomes empty, it is automatically pruned.
- Unassigned faces are displayed in the "Unassigned Faces" area, allowing users to move them into an existing person or create a new person.

---

## 8. Background Processing Architecture (Phase 7)

```
┌────────────────────────────────────────────────────────────────────────┐
│                        LibraryProcessingQueue                          │
│                                                                        │
│   ┌───────────────┐     ┌───────────────┐     ┌───────────────┐        │
│   │   Worker 1    │     │   Worker 2    │     │   Worker 3    │  ...   │
│   └───────┬───────┘     └───────┬───────┘     └───────┬───────┘        │
│           │                     │                     │                │
│           ▼                     ▼                     ▼                │
│   ┌───────────────────────────────────────────────────────────┐        │
│   │            Coordinator: Decode → Vision → ArcFace         │        │
│   └─────────────────────────────┬─────────────────────────────┘        │
│                                 │ (Atomic Record Write)                │
│                                 ▼                                      │
│   ┌───────────────────────────────────────────────────────────┐        │
│   │                       LibraryStore                        │        │
│   └─────────────────────────────┬─────────────────────────────┘        │
│                                 │ (Deferred Refresh on Drain)          │
│                                 ▼                                      │
│   ┌───────────────────────────────────────────────────────────┐        │
│   │                 Cosine Graph Clustering                   │        │
│   └───────────────────────────────────────────────────────────┘        │
└────────────────────────────────────────────────────────────────────────┘
```

### Queue Operations & Threading Model
- **Actor Isolation**: All state mutations in `LibraryProcessingQueue` and `LibraryStore` are actor-isolated, preventing race conditions.
- **Worker Concurrency Limit**: 2–4 workers default, tuned to balance Apple Silicon performance cores and Neural Engine without saturating UI rendering.
- **Progress Reporting**: Continuous metrics broadcast to SwiftUI `@MainActor` via `QueueProgressMetrics` (progress fraction, photos/sec, faces detected, active file).

---

## 9. Continuous Local Folder Monitoring (Phase 8)

```
┌────────────────────────────────────────────────────────────────────────┐
│               Kernel / Filesystem Events (macOS FSEvents)              │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ (Recursive Directory Notifications)
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│                        FolderMonitorService                            │
│                 Conforming to FolderMonitorServiceProtocol             │
│        (Runs on dedicated serial dispatch queue: keepsakemonitor)      │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ (Raw change signal)
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│                        DebounceCoordinator                             │
│                  (Swift Actor - Isolated Serial Execution)             │
│       • Coalesces rapid burst events (500ms quiet window)              │
│       • Serializes manual rescan with automatic reconciliations        │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ (Debounced trigger)
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│                    Authoritative Reconciliation                        │
│             PhotoScannerService ──► LibraryStore.reconcile()           │
│       • New photos: Discovered & enqueued into background queue        │
│       • Modified photos: Fingerprint mismatch -> flagged for reprocess │
│       • Deleted photos: Pruned from store, cluster identities refreshed│
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ (Dynamic append)
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│               LibraryProcessingQueue (Dynamic Append)                  │
│       • enqueueAdditional: Reuses existing active/paused workers       │
│       • Zero duplicate tasks, zero worker thread churn                 │
└────────────────────────────────────────────────────────────────────────┘
```

### Native API Selection & Rationale
Keepsake evaluates native macOS filesystem observation mechanisms:
1. **macOS `FSEvents` (`FSEventStreamCreate`, `kFSEventStreamCreateFlagFileEvents`)** — **Selected**:
   - Native recursive directory subtree monitoring provided by macOS kernel.
   - Requires only 1 stream reference regardless of directory depth or photo count (0 file descriptors consumed).
   - Zero polling, ~0% idle CPU overhead, and hardware-accelerated event delivery.
2. **`DispatchSourceFileSystemObject`**:
   - Requires opening a file descriptor for every single directory and subdirectory. For large photo libraries with hundreds of subfolders, this risks running out of file descriptors and fails to observe newly created subdirectories automatically without manual subtree re-traversal.
3. **Periodic Polling Timer**:
   - Degrades battery life and wastes CPU/disk I/O continuously scanning idle trees.

### "Events Are Hints, Store Is Truth" Philosophy
Filesystem events on macOS can occasionally deliver coarse directory-level flags. Keepsake treats every event as an advisory hint. When an event fires:
1. It is debounced through `DebounceCoordinator`.
2. The authoritative `PhotoScannerService` walks the monitored path to obtain current disk state.
3. `LibraryStore.reconcile(scannedPhotos:rootFolderURL:)` computes the precise diff (new, changed, unchanged, removed).
4. No database records are touched without definitive verification.

### Burst Debounce & Dynamic Queue Integration
- **Burst Coalescing**: Copying 100 or 1,000 photos in Finder triggers dozens of rapid events. `DebounceCoordinator` holds back execution until a quiet window (e.g. 500ms in UI, 50ms in benchmarks) elapses, coalescing >99% of events into a single scan.
- **Dynamic Enqueue**: Newly discovered items are routed via `LibraryProcessingCoordinator.enqueueBackgroundPhotos(...)` into `LibraryProcessingQueue.enqueueAdditional(...)`. Existing background workers seamlessly pick up the newly queued photos without resetting progress or interrupting in-flight face detection/ArcFace embeddings.
- **Manual Rescan Serialization**: Clicking the "Rescan" button calls `debouncer.executeImmediate(...)`, canceling pending timers and safely serializing manual scans with running reconciliations.

---

## 11. Production UX & macOS Native Integration (Phase 9)

```
┌────────────────────────────────────────────────────────────────────────┐
│                          KeepSakeApp (macOS App)                       │
│  • WindowGroup (Main Window with MenuBar Commands: ⌘O, ⌘R, ⌥⌘D)        │
│  • Settings Scene (Native Tabbed Settings Window: ⌘,)                  │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│                     AppSettings (@AppStorage Single Source)            │
│  • developerModeEnabled (Hides/reveals experimental labs & telemetry)  │
│  • autoMonitoringEnabled (Controls FSEvents folder monitoring)         │
│  • gridThumbnailSize (Smooth grid scaling from 120pt to 300pt)         │
│  • photoSortOrder (dateDescending, dateAscending, filename)            │
│  • showFaceOverlaysByDefault (Face bounding boxes in detail view)      │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │
           ┌────────────────────────┴────────────────────────┐
           ▼                                                 ▼
┌───────────────────────────────────────┐ ┌───────────────────────────────────────┐
│              Standard User UX         │ │             Developer Mode            │
│  • Photos Grid (Sort & Scale)         │ │  • Recognition Lab (Vision vs ArcFace)│
│  • People Gallery (Names & Avatars)   │ │  • Clustering Lab (Live Threshold)   │
│  • Welcome / Drop Target on Launch    │ │  • Raw Embeddings & Similarity Logs   │
│  • Confirmation Sheets on Destructive │ │  • Worker Queue & Task Telemetry      │
└───────────────────────────────────────┘ └───────────────────────────────────────┘
```

### Clean Separation of User UX vs Developer Tooling
To present a clean, calm user experience for standard photo browsing while preserving all experimental and diagnostic capabilities built in earlier phases:
1. **User Mode (Default)**: Normal users see only the high-level **Photos** grid and **People** gallery. Status bars show friendly progress indicators ("Scanning...", "Finding faces..."). Destructive actions (ungrouping a person, removing a face crop) present native confirmation sheets.
2. **Developer Mode**: Toggled via `AppSettings` or `⌥⌘D` (`Option + Command + D`). Exposes the experimental **Recognition Lab**, **Clustering Lab**, raw float vectors, pairwise similarity matrices, and internal worker thread performance counters.

### Native macOS Settings Scene
Keepsake provides a multi-pane `Settings` scene accessible via standard `⌘,` (`Command + Comma`):
- **General Tab**: Thumbnail size slider, default sort order, detail view bounding box overlay toggles.
- **Processing Tab**: Background thread concurrency limits, automated folder monitoring toggles, indexing preferences.
- **Developer Tab**: Developer mode switch, recognition benchmark selection (ArcFace vs Vision FeaturePrint), clustering threshold slider, and library database reset tools.

### First-Launch & Drag-and-Drop Ingestion
When no folder is loaded, `WelcomeView` guides the user with a focused empty state explaining Keepsake's offline, privacy-first design. Folders can be opened via the primary "Open Photo Folder..." button, native menu (`⌘O`), or by dragging and dropping any folder directly onto the window.

### Actionable, Human-Centered Error Architecture (`UserFacingError`)
In accordance with Apple Human Interface Guidelines (HIG), raw system errors (`CocoaError`, `NSError`, POSIX file codes) are translated into structured three-part presentations:
1. **What happened**: Clear, non-technical title and message.
2. **Why it matters**: Explanation of the impact on the user's library or action.
3. **What to do**: Actionable recovery steps (e.g. checking drive connectivity, re-selecting folder permissions).

---

## 12. Architectural Constraints & Non-Goals

- **No Filesystem Daemons**: Keepsake does not run persistent background daemons (e.g. `launchd` daemons) outside active app execution. Folder monitoring starts when a folder is active and stops cleanly when closed or when the app terminates.
- **Identity Curation is User-Driven**: Keepsake does not automatically name people or sync identities with macOS Contacts or external cloud databases.
- **No Vector Database**: In-memory pairwise cosine distance via Apple Accelerate `vDSP` executes in $< 1 \text{ ms}$ for hundreds of faces.
- **No Cloud Services or Network Calls**: 100% local persistence in `Application Support/KeepSake`; zero telemetry, zero analytics, zero external API calls.
- **Non-Destructive Filesystem Operations**: Original user photo files are never modified, moved, renamed, or tagged on disk.

---

## 13. Identity Corrections, Bulk Assignment & Cannot-Link Architecture (Milestone V7)

### Folder Scoping of Pending Review Queues
- **Candidate Suggestions**: Candidate groups produced by `LibraryProcessingCoordinator` are tagged with `rootFolderPath: rootFolderURL.standardizedFileURL.path`. Only suggestions belonging to the currently selected folder are displayed for review. Switching to a different folder preserves suggestions from other folders in the snapshot without surfacing them in the active UI.
- **Unassigned Faces**: `LibraryStore.getUngroupedFaces(forRootFolderPath:)` filters detected faces by matching `photo.rootFolderPath` against the active folder path. Faces belonging to confirmed people (`PersonRecord`) or active groups are excluded. This guarantees that empty folders show 0 unassigned faces and 0 pending suggestions.

### Multi-Select & Bulk Assignment State Machine
- `UnassignedFacesView` provides a multi-select mode (`isSelectingUnassigned`) with "Select All" and "Deselect All" controls.
- Users can assign selected faces in bulk to an existing confirmed person (`bulkAssignFaces`) or create a new person (`bulkCreatePerson`).
- Selection count and conflict status are updated reactively on the main actor.

### Cannot-Link Constraint Enforcement
- **Ontological Ground Rule**: A single physical human cannot appear multiple times as distinct faces in the same photograph.
- **Service Enforcement**: `IdentityService` checks that:
  $$\text{count}(\text{selectedFaceIds}) == \text{count}(\text{distinctPhotoIds})$$
  and that none of the candidate photos already have confirmed faces associated with the target person.
- **Violation Handling**: If violated, `IdentityService` throws `IdentityServiceError.cannotLinkViolation`. In the UI, an inline warning banner appears and disables the assignment action buttons, preventing invalid assignments proactively.

### Granular Pre- and Post-Confirmation Face Removal
- **Pre-Confirmation**: Users can remove an individual face from a candidate suggestion card before confirming it (`removeFaceFromCandidateGroup`). The removed face is released back to the unassigned queue without rejecting the remaining suggestion.
- **Post-Confirmation**: Users can remove an individual face from a confirmed person (`removeFaceFromPerson`) or move it to another person (`moveFace`), which recalculates anchor embeddings and updates centroids while enforcing Cannot-Link constraints.

### Authoritative Person Merging
- Merging duplicate people (`mergePeople`) merges face memberships into the target person record, invalidates conflicting co-occurring merges via Cannot-Link validation, and deactivates the source person record in the central store.
- `MergePeopleSheet` presents a side-by-side comparison of source vs target face counts and photo counts before user confirmation.

---

## 14. False Face Detection, Exclusion Lifecycle & Review-State Preservation (Milestone V7 Remediation)

### False Face Detection Lifecycle ("Not a Face")
- **Ontological Reality**: Computer-vision face detectors occasionally hallucinate face bounding boxes on shoes, clothing patterns, tree branches, or artwork. KeepSake treats false face detection as a primary domain state rather than an error or photo deletion.
- **Data Model Schema**:
  - `FaceRecord` contains `isExcluded: Bool`, `excludedAt: Date?`, and `exclusionReason: String?`.
  - `LibraryIndexSnapshot` maintains an authoritative index `excludedFaceIds: Set<UUID>`.
  - Backward compatibility: previous library snapshots missing these fields default safely to `isExcluded = false`, `excludedAt = nil`, `exclusionReason = nil`.
- **Absolute Preservation of User Photos**:
  - Marking a face detection as "Not a Face" or permanently deleting it from the Recycle Bin **never modifies or deletes the original photograph** on disk.
  - Only the metadata reference (`FaceRecord`) and associated embedding in the index are altered or pruned.
- **Rescan Re-detection Suppression**:
  - During folder rescans, `LibraryProcessingCoordinator.processSinglePhoto` matches newly detected bounding boxes against previously excluded face records on the same photo.
  - If a bounding box center distance satisfies $\|(x_1, y_1) - (x_2, y_2)\|_2 < 0.05$, the face record is immediately marked `isExcluded = true`, and ArcFace embedding extraction is skipped entirely. This prevents hallucinated bounding boxes from reappearing after folder re-indexing.

### Recycle Bin Management
- **Dedicated Inspection Surface (`RecycleBinView`)**:
  - Accessible via the "Excluded (Recycle Bin)" button in the People gallery sub-header and empty-state views.
  - Displays photo thumbnails, filenames, relative paths, and exclusion reasons.
- **Action Semantics**:
  - **Restore**: Clears `isExcluded`, resets `exclusionReason`, and immediately returns the face to the Unassigned Faces queue for identification or assignment.
  - **Delete Permanently**: Removes the `FaceRecord` and its vector embedding from `LibraryStore` completely with an explicit confirmation dialog.
  - **Bulk Actions**: Provides "Restore All" and "Empty Bin" capabilities.

### Strict Folder Isolation for Review Queues
- **Scoping Invariant**:
  - When switching folders, candidate suggestions and unassigned faces displayed in the UI must strictly originate from photographs within the active folder hierarchy.
  - `LibraryStore.getCandidateGroups(forRootFolderPath:)`, `getGroups(forRootFolderPath:)`, and `getUngroupedFaces(forRootFolderPath:)` filter records by matching `photo.rootFolderPath == activeFolder.path`.
  - If the active folder contains zero photos, the review queue displays zero suggestions and zero unassigned faces, without leaking detections from previous folders.
- **Scoped Reclustering**:
  - `LibraryProcessingCoordinator.reclusterLibrary` scopes clustering inputs strictly to photos and embeddings belonging to the active folder.
  - Reclustering an active folder preserves candidate groups belonging to other folders in the persistent snapshot.
  - If an active folder is empty or contains zero valid embeddings, candidate groups for that specific folder are cleaned up while preserving all confirmed identities and cross-folder data.

### Rejection State Persistence & Clustering Idempotence
- **Persistence Across Rescans**:
  - Rejecting a candidate suggestion marks its cluster with `reviewStatus = .rejected`.
  - Agglomerative clustering in `reclusterLibrary` tracks `isRejected` state across cluster unions and assigns `reviewStatus = .rejected` to candidate groups containing rejected clusters.
  - Existing unassigned rejected groups are preserved during snapshot updates and are never reincarnated as `.candidateSuggestion`.
  - Faces from rejected suggestions remain in the Unassigned Face pool, allowing user-driven assignment or "Not a Face" exclusion without recurring review banner clutter.

### Streamlined Candidate Card Interaction
- Redundant "Review" buttons have been removed from candidate suggestion cards in `CandidateReviewCardView`.
- Clicking anywhere on the suggestion card body directly navigates to the candidate detail view.
- "Confirm" and "Reject" buttons remain independent, prominent single-click actions for high-efficiency review workflows.

---

## 15. Global Identity Library, Cross-Folder Photos & Two-Category Recycle Bin (Milestone V7 Follow-up)

### Global Identity Library & Cross-Folder Aggregation
- **Global Person Identity vs. Scoped Photos**:
  - The central People Database (`PersonRecord`) represents real-world physical humans whose identities exist globally across all indexed folders.
  - The main Photos gallery remains strictly scoped to the currently active folder.
  - In contrast, opening a person card in the People Gallery displays all photographs featuring that person across **all indexed folders**, with individual source folder metadata.
- **Cross-Folder URL Resolution**:
  - `LibraryStore.getPhotos(forGroup:)` resolves face associations from `snapshot.people` first to ensure multi-folder member faces are included.
  - Image paths resolve against each photo's respective `photo.rootFolderPath`, ensuring cross-folder thumbnail rendering remains fully intact even when viewing people from an inactive folder.

### Direct Candidate Group Assignment to Existing People
- **Elimination of Temporary Identities**:
  - Users can assign an entire candidate suggestion group or individual candidate face directly to an existing confirmed person without creating a temporary identity.
  - Accessible via "Assign to Person…" on `CandidateReviewCardView` and the candidate detail review banner.
  - `AssignCandidateGroupSheet` provides searchable selection of confirmed people with avatars, face counts, and photo counts.
- **Pre-Confirmation Face Pruning**:
  - Candidate groups containing faces of different people can be edited before confirmation: users can remove mismatched faces (returning them to unassigned) or mark them as "Not a Face".
  - Candidate suggestions update dynamically; once approved or assigned, the suggestion is atomically removed from the review queue.

### Distinct Post-Confirmation Face Actions
- In `PersonDetailView`, face cards provide explicit, differentiated operations:
  1. **Unassign Face**: Removes the association, returning the face to the Unassigned Faces queue.
  2. **Move to Recycle Bin**: Moves the association to the "Removed from People" recovery tab with a saved `RemovedFaceAssociationRecord`.
  3. **Move to Another Person**: Reassigns the face to a different confirmed person, enforcing Cannot-Link constraints.
  4. **Not a Face**: Marks the face as a false detection (`isExcluded = true`), moving it to the "False Detections" tab.

### Two-Category Recycle Bin Architecture
- **Categorical Separation (`RecycleBinView`)**:
  - **Tab 1: False Detections**: Manages hallucinated non-face detections (`isExcluded: true`). Actions: Restore (to Unassigned Faces), Delete Permanently (prunes face record from index).
  - **Tab 2: Removed from People**: Manages removed person-face associations (`RemovedFaceAssociationRecord`). Actions: Restore to Person (restores association if person exists and Cannot-Link is satisfied), Restore to Unassigned (releases to unassigned pool), Delete Permanently.
- **Immutability of Photos on Disk**:
  - Both tabs enforce the core guarantee: original photographs on the user's filesystem are never deleted, renamed, or modified.

---

## 16. Folder-Scoped Photos, Global Identity Memory & UI De-duplication (V7 Critical Correction)

### Global Identity Database vs. Folder-Scoped Photo Experience
- **Architectural Separation**:
  - **Global Identity Memory**: Physical human identities (`PersonRecord`) persist globally with their stable UUIDs, names, 512-D centroids, and anchor embeddings across all indexed folders. When a new folder is scanned, faces are compared against these global identities, allowing recognized individuals to be auto-matched or proposed as candidate matches without re-creating identity profiles.
  - **Folder-Scoped Photo Presentation**: All visual displays of photos, photo counts, face counts, and key thumbnails are strictly scoped to the active folder (`rootFolderURL`).
  - **Card Metrics & Empty Folders**: In People Gallery, a person with 0 photos in the active folder displays `0 photos` and `0 faces`, with a nil current-folder thumbnail. In an empty folder (Folder C), no photos from Folder A or B are displayed, while global identities remain safe in the persistent store.
  - **Detail View Scoping**: When opening a person card, the gallery and face list are scoped to photos from the active folder. Cross-folder photos are not aggregated into the active gallery.

### Principled Legacy `rootFolderPath == nil` Fallback Semantics
- Centralized `isPhoto(_:matchingNormalizedRoot:)` helper resolves photo ownership:
  1. **Explicit Root**: If `photo.rootFolderPath` is non-nil, strict path equality against `normalizedRoot` is enforced. Photos with explicit root folders never leak across folder boundaries.
  2. **Relative Path Prefix**: If `photo.relativePath` has a prefix matching `normalizedRoot`, ownership is attributed to that folder.
  3. **Metadata Alignment**: If `snapshot.metadata?.folderPath` matches `normalizedRoot`, legacy records indexed under that folder are preserved.
  4. **Single-Folder Fallback**: If the store contains no photos with explicit roots for other folders (`!hasOtherExplicitFolders`), legacy/synthetic test records without `rootFolderPath` safely match the query.
  5. **Conservative Multi-Folder Isolation**: If multiple folders exist in the store and a record has `rootFolderPath == nil` with no metadata alignment, it is treated conservatively and not leaked into foreign folders.

### Complete Remove Person Lifecycle
- **Authoritative Unlinking**:
  - `LibraryStore.deletePerson(byId:)` safely handles identities existing in `snapshot.people`, `snapshot.groups`, or both.
  - All confirmed member faces are collected and released back to the unassigned face pool.
  - The person is deleted from `snapshot.people` and `snapshot.groups`.
  - Empty groups are pruned, removed associations belonging to the person are purged, and the index is persisted atomically to disk.
  - Removal is permanent and does not resurrect on reload, rescan, or application restart.
- **Cancellation**:
  - Dismissing or canceling the confirmation dialog performs zero modifications to the store or view model.

### UI Action De-Duplication
- **Single Authoritative Candidate Action Bar**:
  - Duplicate `Confirm…`, `Assign to Person…`, and `Reject` buttons were removed from `PersonDetailView.topNavBar`.
  - The single authoritative set of candidate actions resides exclusively in `candidateReviewBanner`.
  - Individual face-level corrections ("Remove from Suggestion", "Assign to Person…", "Not a Face") remain on individual face cards.

---

## 17. Navigation Redesign, Unified Settings Hub & Two-Level Thumbnail Caching

### Three-Pillar Primary Navigation
- **Workspace Separation**:
  - Top-level navigation is organized into three primary, independent sections: `Photos`, `People`, and `Suggestions`.
  - **Photos**: Focused entirely on photo browsing within the active folder. Displays active folder name/path, total photo count, scanning/syncing state, sort order selector, rescan button, folder picker, and the modal full-screen photo detail viewer with "Show in Finder".
  - **People**: Dedicated exclusively to confirmed people identities (`viewModel.people`). Features live search filtering, grid layout, customizable cover images with gold star indicators, and person detail drill-down. The candidate suggestion queue has been completely extracted out of People to prevent scrolling past suggestions to reach confirmed people.
  - **Suggestions**: Dedicated review workspace for candidate face clusters (`viewModel.candidateGroups`). Features candidate review cards, one-click confirmation (with name entry dialog), direct assignment to existing people (`AssignCandidateGroupSheet`), and rejection. Navigation picker dynamically reflects pending suggestion count with a high-visibility badge.

### Unified Native macOS Settings Hub
- **Centralized Architecture (`SettingsView`)**:
  - Invoked via a gear button (`gearshape`, ⌘,) in the top toolbar right beside folder selection, replacing scattered secondary toolbar buttons.
  - Divided into 4 focused categories:
    1. **General**: Photo sorting options, background folder monitoring toggle, thumbnail grid size slider, and developer mode diagnostics.
    2. **Library & Cache**: Disposable thumbnail cache metrics, cache path display, "Show in Finder" button, and safe "Clear Cache" button with confirmation alert. Also reports persistent database metrics from `~/Library/Application Support/KeepSake/library_index.json` and failed photo retry controls.
    3. **Recycle Bin**: Embeds `RecycleBinView` with both tabs (False Detections & Removed from People) for restoration and permanent deletion.
    4. **Unassigned Faces**: Embeds `UnassignedFacesView` with multi-select, bulk assign, bulk create, and folder scoping.

### Two-Level Thumbnail Caching & High-Performance Scrolling
- **Two-Level Cache Hierarchy**:
  - **Level 1 (In-Memory `NSCache`)**: Fast synchronous memory cache holding up to 1,500 downsampled images (512 MB cost limit). `PhotoThumbnailView` checks `ThumbnailLoader.shared.cachedImage(for:)` synchronously during view instantiation, rendering instantly on the first frame with zero placeholder flashing.
  - **Level 2 (Persistent On-Disk Cache `DiskThumbnailCache`)**: Downsampled JPEGs (Retina 2x resolution, max 640px) stored in `~/Library/Caches/com.keepsake.KeepSake/Thumbnails/` using SHA256 hashes of original photo file paths.
- **Concurrent Decoding Pipeline**:
  - Replaced actor-serialized decoding with thread-safe `ThumbnailLoader`, dispatching decodes to detached background tasks at `.userInitiated` priority across Apple Silicon multi-core CPUs.
  - Leverages CoreGraphics `kCGImageSourceCreateThumbnailFromImageIfAbsent: true` to prioritize embedded EXIF thumbnail previews when available, avoiding expensive full-image decodes.
- **Cache Purging Safety**:
  - "Clear Cache" operates strictly on `~/Library/Caches/com.keepsake.KeepSake/Thumbnails/` and clears in-memory caches.
  - The persistent identity database (`~/Library/Application Support/KeepSake/library_index.json`), embeddings, face records, confirmed people, and original photo files on disk are completely isolated and never affected.


