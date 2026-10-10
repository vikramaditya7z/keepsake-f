# PROGRESS.md — KeepSake Identity Loop Memory

## 1. Current Project State

- **Platform**: macOS 14+, Swift 5.9+, SwiftUI, Apple Vision, Core ML, Accelerate (`vDSP`).
- **Active Workspace**: `/Users/vikramaditya/Disk/Projects/KeepSake` (symlinked to `/Users/vikramaditya/Disk/Projects/F-KeepSake`).
- **Build Status**: Compiles cleanly with zero compiler warnings or errors (`xcodebuild` targeting macOS 14.0).
- **Test Suite Status**: **151 tests passing (0 failures)** in ~5.2 seconds via `KeepSakeTests.xctest`.
- **Active Architecture Milestone**: **Milestone V2: Recognition Evaluation (COMPLETE)**. Next: Milestone V3 (Genuine On-Device Recognition).


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

- **Model Evaluation Benchmark Execution (2026-10-10)**:
  - Command: `xcodebuild -scheme KeepSakeTests ... && xcrun xctest -XCTest KeepSakeTests/testModelEvaluation_BenchmarkCandidatesAgainstGroundTruthManifest ...`
  - Result: **151 tests passed, 0 failures** in 5.195 seconds.
  - Candidate D (Apple Vision FeaturePrint Rev 2, 768-D):
    - Same-identity pairs (142): min=0.4425, mean=0.6306, median=0.6304, max=0.9720
    - Diff-identity pairs (293): min=0.3074, mean=0.5869, median=0.5899, max=0.8411
    - Separation margin: **-0.3986** (140/142 same-identity pairs overlap with diff-identity similarities).
    - Latency: median 7.1 ms, first 99.8 ms.
    - Finding: Completely unsuitable for face biometrics; diff pairs reach 0.8411 due to scene/lighting similarity.
  - Candidate F (Synthetic 2D-DCT Fallback in `ArcFaceRecognitionService`, 512-D):
    - Same-identity pairs (142): min=-0.2321, mean=0.2149, median=0.2028, max=0.7254
    - Diff-identity pairs (293): min=-0.1226, mean=0.1744, median=0.1753, max=0.5148
    - Separation margin: **-0.7469** (129/142 same pairs overlap).
    - Latency: median 13.6 ms.
    - Finding: Matches the exact numbers stored in `library_index.json`. Confirms that the synthetic DCT fallback caused the identity fragmentation and false merges in KeepSake.

---

## 6. Files Changed in This Turn

- `test-dataset/manifest.json` (Created): Definitive manifest mapping all 19 photos, 53 detected faces, bounding boxes, checksums, and verified ground-truth labels.
- `.gitignore` (Updated): Excluded test-dataset image binaries from Git to protect personal photo privacy, while tracking `manifest.json`.
- `KeepSakeTests/KeepSakeTests.swift` (Updated): Added `testModelEvaluation_BenchmarkCandidatesAgainstGroundTruthManifest` benchmark test.
- `MODEL_EVALUATION.md` (Created): Comprehensive evaluation report comparing ArcFace, AdaFace, MobileFaceNet, Vision FeaturePrint, and EmbeddingGemma 2, with empirical measurements, licensing review, and Core ML deployment architecture.
- `PROGRESS.md` (Updated): Recorded empirical findings, baseline verification, and next engineering steps.

---

## 7. Most Recent Successful Checkpoint

- **Checkpoint**: Model evaluation milestone complete; 151/151 tests passing; `MODEL_EVALUATION.md` published; Git clean and synchronized with `origin/main` on commit `3f10dfb`.

---

## 8. Exact Proposed Next Action for Next Iteration

- **Proposed Task**: Package a genuine Core ML MobileFaceNet model asset (`buffalo_s.mlpackage` / `.mlmodelc`), bundle it in `KeepSake/Resources`, remove the misleading diagnostic fallback log in `ArcFaceRecognitionService.swift`, and verify on-device neural inference on the Apple Neural Engine.

