# PROGRESS.md — KeepSake Identity Loop Memory

## 1. Current Project State

- **Platform**: macOS 14+, Swift 5.9+, SwiftUI, Apple Vision, Core ML, Accelerate (`vDSP`).
- **Active Workspace**: `/Users/vikramaditya/Disk/Projects/KeepSake` (symlinked to `/Users/vikramaditya/Disk/Projects/F-KeepSake`).
- **Build Status**: Compiles cleanly with zero compiler warnings or errors (`xcodebuild` targeting macOS 14.0).
- **Test Suite Status**: **150 tests passing (0 failures)** in ~2.0 seconds via `KeepSakeTests.xctest`.
- **Active Architecture Phase**: Phase 9 (macOS Native UX & App Settings) + Step 2 of the Hierarchical Face Identity System (`FaceCluster` model and `LocalFaceClusterService`).

---

## 2. Verified Working Functionality

- **Photo Ingestion & Scanning**: Recursive filesystem discovery (`PhotoScannerService`), security-scoped bookmarks (`BookmarkManager`), and change classification (`NEW`, `CHANGED`, `UNCHANGED`, `REMOVED`).
- **Filesystem Monitoring**: Native macOS kernel `FSEvents` (`FolderMonitorService`) with actor-isolated debouncing (`DebounceCoordinator`).
- **Background Processing Queue**: Actor-isolated bounded worker pool (`LibraryProcessingQueue`, 2–4 workers) with pause, resume, cancel, retry, and progress metrics.
- **Atomic Local Persistence**: Actor-isolated `LibraryStore` persisting JSON indices with base64/binary float embedding payloads to `~/Library/Application Support/KeepSake/library_index.json`.
- **Vision Face Detection**: Apple Vision `VNDetectFaceRectanglesRequest` generating normalized bounding boxes and detection confidence.
- **Face Preprocessing**: Contextual margin cropping with EXIF orientation correction and 112x112 RGB planar tensor extraction (`FacePreprocessingService`).
- **Stage 1 Local Face Clustering (`FaceCluster`)**: `LocalFaceClusterService` groups embeddings into high-precision local appearance clusters (strict threshold 0.58) with strict Cannot-Link enforcement and anti-transitive drift guards.
- **Identity & Curation Services**: `IdentityService` providing custom naming, manual merges, face removal, representative face selection, and multi-face photo gallery resolution.

---

## 3. Critical Architectural Discoveries & Known Gaps

### 3.1 Model Asset Status: Synthetic DCT Fallback in Active Use
- **Reality Check**: `ArcFaceRecognitionService.swift` attempts to load `"ArcFace.mlmodelc"` or `"buffalo_s.mlmodelc"`. However, **no compiled Core ML model asset exists in the bundle or repository**.
- **Misleading Log**: `ArcFaceRecognitionService.inferArcFaceEmbedding` logs `[DIAGNOSTIC] Recognition backend: Core ML buffalo_s / MobileFaceNet` before falling back to `computeMobileFaceNetEmbedding(tensor:)`.
- **Fallback Reality**: `computeMobileFaceNetEmbedding` is a handcrafted 8x8 subgrid 2D-DCT/Fourier spatial-frequency projection with PReLU. It is **not** a neural network.
- **Consequence**: The synthetic projection lacks the angular separation of genuine deep ArcFace embeddings. Embeddings for distant/small faces in group shots compress into low cosine similarities (0.45–0.58), causing identity fragmentation or false merges when thresholds are relaxed.

### 3.2 Pipeline Integration Gap
- While `LocalFaceClusterService` and `FaceCluster` were implemented and verified with 9 unit tests in `KeepSakeTests.swift`, they have **not yet been integrated** into the production ingestion pipeline (`LibraryProcessingCoordinator.swift` still uses `CosineGraphClusteringService`).

---

## 4. Failed Approaches & Lessons Learned

| Approach | What Was Attempted | Why It Failed | Lesson Learned |
|---|---|---|---|
| **Global Cosine Threshold Lowering (to 0.48)** | Lowered clustering threshold from 0.60 to 0.48 in `CosineGraphClusteringService` to reduce singleton groups from 52 to 38. | Caused severe cross-person contamination in the UI (e.g. Rishita's person card was contaminated with faces of other people). | Angular margin on synthetic/weak embeddings cannot be fixed by lowering a global threshold. Cannot-Link and multi-anchor models are mandatory. |
| **Synthetic 2D-DCT Feature Projection** | Handcrafted spatial-frequency Fourier/DCT projection over 112x112 pixel tensor with anatomical center weighting. | Inadequate facial discriminability across variations in lighting, pose, distance, and expression. | Genuine deep neural representations (e.g. MobileFaceNet / buffalo_s weights) are required for human-grade recognition. |
| **Single Centroid Identity Representation** | Representing each person by a single global mean vector $\mathbf{c} = \frac{1}{N}\sum \mathbf{v}_i$. | A person's appearance has distinct modes (close-up portrait vs group shot vs profile with glasses). Averaging distant modes washes out feature distinctiveness. | Person identities must support multiple anchor exemplars / appearance clusters. |
| **Single-Stage Flat Clustering** | Grouping all faces directly into final Person cards in one global pass. | Lacks intermediate representation for local confidence, forcing a compromise between over-fragmentation and false merges. | Two-stage hierarchy required: Stage 1 = local high-precision `FaceCluster`, Stage 2 = multi-anchor `PersonIdentity`. |

---

## 5. Recent Experiments & Verified Results

- **Test Suite Execution (2026-10-10)**:
  - Command: `xcodebuild -project KeepSake.xcodeproj -scheme KeepSakeTests -derivedDataPath ./build/DerivedData build-for-testing ... && xcrun xctest ...`
  - Result: **150 tests passed, 0 failures** in 2.085 seconds.
- **Stage 1 `FaceCluster` Audit on Ground-Truth Dataset (19 photos, 53 faces)**:
  - Result: 46 clusters formed (7 multi-face pairs, 39 singletons).
  - Cannot-Link Violations: **0** (all co-occurring face pairs in group shots rejected).
  - Cross-Person Merges: **0**.

---

## 6. Files Changed in This Turn

- `GOAL.md` (Created): Definitive project objectives, workflow, core rules, and acceptance criteria.
- `PROGRESS.md` (Created): Persistent loop memory, verified features, known gaps, and failure log.
- `VERIFIER.md` (Created): Specific verification gates and required empirical evidence.
- `STOP_CONDITIONS.md` (Created): Safe loop boundaries, circuit breakers, and halt conditions.

---

## 7. Most Recent Successful Checkpoint

- **Checkpoint**: Step 2 Local `FaceCluster` model and unit test suite verified; 150/150 tests passing.
- **Commit/State**: Workspace restored via symlink, builds cleanly, tests pass.

---

## 8. Exact Proposed Next Action for Next Iteration

- **Proposed Task**: Inspect the actual model asset requirements for `buffalo_s` (MobileFaceNet Core ML FP16) and design the genuine model asset integration strategy (or obtain user authorization for the model asset conversion/packaging), replacing the synthetic DCT fallback with verified neural inference before advancing the identity clustering pipeline.
