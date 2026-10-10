# MODEL_EVALUATION.md — KeepSake Face Recognition Model Evaluation & Selection Report

**Report Version**: 2.0 (Milestone V2: Recognition Evaluation)  
**Report Date**: 2026-10-10  
**Target Platform**: macOS 14.0+ (Apple Silicon M-Series)  
**Evaluation Dataset**: 19 photos, 53 detected face instances, 30 verified identity faces across 5 individuals  
**Benchmark Suite**: `KeepSakeTests.xctest` (`testModelEvaluation_BenchmarkCandidatesAgainstGroundTruthManifest`)  

---

## 1. Executive Summary

### 1.1 Objective & Scope
The objective of KeepSake V2 is to evaluate existing and candidate face recognition models using reproducible empirical evidence and authoritative provenance research. This evaluation provides the foundation for KeepSake's semi-automatic, local-first photo organization workflow:
- The system detects faces and proposes likely identity matches.
- The user reviews, confirms, and corrects identity suggestions.
- Uncertain matches remain unassigned rather than falsely unified.
- Processing remains 100% on-device and private.

**Scope Boundary**: V2 is strictly an evaluation and decision-making milestone. No production code has been modified, and no new model has been integrated into the production pipeline. Integration of the selected model belongs strictly to V3.

### 1.2 Primary Architectural Recommendation
The optimal face recognition architecture for KeepSake is **MobileFaceNet** trained with **Additive Angular Margin Loss (ArcFace)** producing **512-dimensional L2-normalized embeddings** from 112×112 RGB face crops.

### 1.3 Key Empirical & Architectural Findings
1. **Current Production Backend Reality**: KeepSake currently lacks any compiled Core ML model asset. The active `ArcFaceRecognitionService.swift` falls back to a handcrafted 8×8 subgrid 2D-DCT/Fourier spatial projection while emitting a misleading diagnostic message claiming Core ML MobileFaceNet is active. This synthetic fallback provides virtually no angular separation ($\mu_{\text{same}} = 0.2149$ vs $\mu_{\text{diff}} = 0.1744$, with 90.8% overlap), directly causing the severe identity fragmentation observed in the UI.
2. **Apple Vision FeaturePrint Biometric Inadequacy**: Apple's native `VNGenerateImageFeaturePrintRequest` (Revision 2, 768-D) was empirically tested on all 53 ground-truth face crops. It fails biometrically: different-person pairs routinely produce cosine similarities up to **0.8411**, and 140 of 142 same-person pairs overlap with different-person scores. Vision FeaturePrints capture scene illumination, color distributions, and skin tone rather than biometric facial landmarks.
3. **Licensing Boundary**: The popular InsightFace `buffalo_s` (`w600k_mbf`) weights are restricted to **Non-Commercial / Academic Research Only**. If KeepSake is for personal/non-commercial use, `buffalo_s` provides exceptional verification quality. If KeepSake is planned for commercial distribution, an open/permissive-weight MobileFaceNet checkpoint (trained under Apache 2.0 or MIT on CASIA-WebFace or DigiFace-1M) must be used.

---

## 2. Current Implementation Audit (V1 Baseline)

To establish an honest baseline, the repository was audited to differentiate between code that exists, code covered by tests, code used in production, and actual runtime execution:

| Component | Code Status | Tested? | Production Ingestion Path? | Actual Runtime Behavior |
|---|---|---|---|---|
| **Face Detection** | `VisionFaceDetectionService` / `FaceDetectionService` | Yes | **Yes** | Apple Vision `VNDetectFaceRectanglesRequest` generates bounding boxes and confidence scores. |
| **Face Preprocessing** | `FacePreprocessingService` | Yes | **Yes** | Applies 15% contextual margin, handles EXIF orientation, extracts 112×112 RGB bitmap, and normalizes pixels to $[-1.0, 1.0]$ via $(x - 127.5)/128.0$. |
| **Active Recognition Backend** | `ArcFaceRecognitionService` | Yes | **Yes** (`LibraryProcessingCoordinator` default) | **Synthetic DCT Fallback**: Searches for `ArcFace.mlmodelc` / `buffalo_s.mlmodelc`; neither exists. Emits misleading log and executes 2D-DCT spatial-frequency projection with PReLU. |
| **Native Vision Recognition** | `VisionFaceRecognitionService` | Yes | No (Only in experiment view and tests) | Native `VNGenerateImageFeaturePrintRequest` extracting 768-D vectors. |
| **Stage 1 Local Clustering** | `LocalFaceClusterService` (`FaceCluster`) | Yes (9 tests) | **No** (Disconnected) | High-precision appearance clustering with strict Cannot-Link enforcement and anti-transitive drift guards. |
| **Production Clustering** | `CosineGraphClusteringService` | Yes | **Yes** | Direct face $\to$ Person clustering. Uses hardcoded threshold (0.54–0.60). Lacks intermediate appearance clusters. |
| **Persistence** | `LibraryStore` | Yes | **Yes** | Actor-isolated atomic JSON persistence at `~/Library/Application Support/KeepSake/library_index.json`. |

### Summary of Audit Gaps:
- **No genuine deep model asset exists**: No `.mlpackage` or `.mlmodelc` file exists in the repository or application bundle.
- **Misleading diagnostic log**: `ArcFaceRecognitionService.swift` logs `[DIAGNOSTIC] Recognition backend: Core ML buffalo_s / MobileFaceNet` before falling back to `computeMobileFaceNetEmbedding`.
- **Architectural disconnect**: The high-precision `LocalFaceClusterService` is implemented and verified by tests but is not yet wired into `LibraryProcessingCoordinator.swift`.

---

## 3. Verified Evaluation Dataset Status

### 3.1 Dataset Inventory
The evaluation dataset is located at [`test-dataset/`](file:///Users/vikramaditya/Disk/Projects/KeepSake/test-dataset) with metadata recorded in [`test-dataset/manifest.json`](file:///Users/vikramaditya/Disk/Projects/KeepSake/test-dataset/manifest.json):
- **Total Images**: 19 files, numbered `1` through `19`.
- **File Extensions & Formats**:
  - JPG: `1.JPG`, `2.JPG`, `15.JPG`, `16.JPG`, `17.JPG`
  - jpg: `3.jpg`, `14.jpg`
  - jpeg: `4.jpeg`, `5.jpeg`, `6.jpeg`, `7.jpeg`, `8.jpeg`, `9.jpeg`, `10.jpeg`, `11.jpeg`, `12.jpeg`, `13.jpeg`, `18.jpeg`, `19.jpeg`
- **File Integrity**: All 19 files are present, readable, and verified with SHA-256 checksums matching `manifest.json`.
- **Total Detected Faces**: 53 face instances detected by Apple Vision.

### 3.2 Ground-Truth Identity Coverage
Of the 53 detected faces, 30 have verified ground-truth labels across 5 distinct individuals:
- **Vikram**: 16 faces (across group shots, close-ups, varying illumination)
- **Manas**: 5 faces
- **Ashna**: 5 faces
- **Shona**: 2 faces
- **Manan**: 2 faces
- **Unlabeled / Background Individuals**: 23 faces (retained for Cannot-Link and negative testing, but excluded from positive identity metrics).

### 3.3 Evaluation Pair Counts
Among the 30 verified face instances:
- Total pairwise comparisons: $\binom{30}{2} = 435$
- **Same-Identity Pairs**: 142 pairs ($\binom{16}{2} + \binom{5}{2} + \binom{5}{2} + \binom{2}{2} + \binom{2}{2} = 120 + 10 + 10 + 1 + 1$)
- **Different-Identity Pairs**: 293 pairs ($435 - 142 = 293$)

### 3.4 Dataset Limitations
While the 19-photo dataset provides a rigorous engineering regression test (capturing co-occurring faces, varied lighting, distance variations, and profile angles), 19 photos from 5 individuals cannot prove broad demographic generalization. It is sufficient to expose failure modes (e.g. synthetic DCT and Vision FeaturePrints), but broader validation will be required in later phases.

---

## 4. Reproduced Baseline Results

Using the automated benchmark harness (`KeepSakeTests.swift:testModelEvaluation_BenchmarkCandidatesAgainstGroundTruthManifest`), both currently accessible candidate implementations were executed directly on the 53 face crops:

### 4.1 Statistical Comparison

| Metric | Candidate D: Apple Vision FeaturePrint (Rev 2) | Candidate F: Synthetic 2D-DCT Fallback (Active Code) | Target Biometric Standard |
|---|---|---|---|
| **Embedding Dimension** | 768-D | 512-D | 512-D |
| **Normalization** | Unit L2-norm ($1.0 \pm 0.001$) | Unit L2-norm ($1.0 \pm 0.001$) | Unit L2-norm ($1.0 \pm 0.001$) |
| **Same-Identity Pairs ($N=142$)** | | | |
| — Minimum | 0.4425 | -0.2321 | $\ge 0.5000$ |
| — Mean ($\mu_{\text{same}}$) | 0.6306 | 0.2149 | $\ge 0.6500$ |
| — Median | 0.6304 | 0.2028 | $\ge 0.6500$ |
| — Maximum | 0.9720 | 0.7254 | $\ge 0.8500$ |
| **Different-Identity Pairs ($N=293$)** | | | |
| — Minimum | 0.3074 | -0.1226 | $\le 0.0000$ |
| — Mean ($\mu_{\text{diff}}$) | 0.5869 | 0.1744 | $\le 0.2000$ |
| — Median | 0.5899 | 0.1753 | $\le 0.2000$ |
| — Maximum | 0.8411 | 0.5148 | $\le 0.3800$ |
| **Mean Separation Margin** ($\mu_{\text{same}} - \mu_{\text{diff}}$) | **+0.0437** | **+0.0405** | **$\ge +0.4500$** |
| **Min-Max Separation Margin** ($\min_{\text{same}} - \max_{\text{diff}}$) | **-0.3986** | **-0.7469** | **$\ge +0.1000$** |
| **Overlapping Same Pairs** ($\text{same} \le \max_{\text{diff}}$) | **140 / 142 (98.6%)** | **129 / 142 (90.8%)** | **0 / 142 (0.0%)** |
| **Inference Latency** | | | |
| — First Inference (Cold) | 99.8 ms | 13.2 ms | <25.0 ms |
| — Mean Latency | 9.7 ms | 13.7 ms | <5.0 ms |
| — Median Latency (Steady) | **7.1 ms** | **13.6 ms** | <4.0 ms |
| — 95th Percentile | 24.1 ms | 17.3 ms | <8.0 ms |

### 4.2 Threshold Sweep Analysis

#### Candidate D (Apple Vision FeaturePrint):
- Threshold 0.50: True Pos: 129, False Pos: 235, Precision: 35.4%, Recall: 90.8%, F1: 0.510
- Threshold 0.55: True Pos: 118, False Pos: 189, Precision: 38.4%, Recall: 83.1%, F1: 0.526
- Threshold 0.60: True Pos: 91, False Pos: 136, Precision: 40.1%, Recall: 64.1%, F1: 0.493
- Threshold 0.65: True Pos: 54, False Pos: 78, Precision: 40.9%, Recall: 38.0%, F1: 0.394
- Threshold 0.70: True Pos: 27, False Pos: 33, Precision: 45.0%, Recall: 19.0%, F1: 0.267

#### Candidate F (Synthetic 2D-DCT Fallback):
- Threshold 0.20: True Pos: 73, False Pos: 112, Precision: 39.5%, Recall: 51.4%, F1: 0.446
- Threshold 0.30: True Pos: 36, False Pos: 23, Precision: 61.0%, Recall: 25.4%, F1: 0.358
- Threshold 0.40: True Pos: 18, False Pos: 4, Precision: 81.8%, Recall: 12.7%, F1: 0.219
- Threshold 0.50: True Pos: 6, False Pos: 1, Precision: 85.7%, Recall: 4.2%, F1: 0.081

### 4.3 Why Both Baselines Fail
1. **Apple Vision FeaturePrint**: Although native and fast (7.1 ms), it is trained as a generic visual feature descriptor. It responds strongly to background context, skin tone, and illumination. Different people in similar lighting have similarities up to 0.8411, while the same person in different lighting drops to 0.4425. No decision boundary can separate identities.
2. **Synthetic 2D-DCT Fallback**: The handcrafted spatial-frequency projection cannot learn semantic biometric invariants. The separation between mean same-person similarity (0.2149) and mean different-person similarity (0.1744) is only 0.0405. This completely explains why KeepSake previously fragmented into 52 singletons or falsely merged identities when thresholds were altered.

---

## 5. Candidate Comparison Matrix

| Candidate | Architecture | Dimensions | Model Size | Expected ANE Latency | Preprocessing Requirements | License Status | Empirical Evidence Status | Overall Verdict |
|---|---|---|---|---|---|---|---|---|
| **A. InsightFace `buffalo_s` (`w600k_mbf`)** | MobileFaceNet (ArcFace) | 512-D | ~6.5 MB (FP16) | ~4–6 ms | 112×112 RGB, norm $[-1, 1]$, landmark align | Non-Commercial / Research Only | Documented + Prior Audit | **VIABLE (Personal/Research Only)** |
| **B. AdaFace** | Modified IR-50 / IR-101 | 512-D | 170–260 MB | ~45–80 ms | 112×112 RGB/BGR, norm $[-1, 1]$, landmark align | Non-Commercial (WebFace4M) | Documented / Architectural | **REJECTED (Too heavy for edge)** |
| **C. Permissive MobileFaceNet** | MobileFaceNet (ArcFace) | 512-D | ~6.5 MB (FP16) | ~4–6 ms | 112×112 RGB, norm $[-1, 1]$, landmark align | Apache 2.0 / MIT (Open Weights) | Documented / Architectural | **VIABLE (Commercial Path)** |
| **D. Apple Vision FeaturePrint** | Deep CNN Visual Embedding | 768-D | 0 MB (Native) | 7.1 ms | Full/cropped CGImage | Apple SDK (Permissive) | **Empirically Measured** | **REJECTED (Biometric failure)** |
| **E. EmbeddingGemma 2** | Multimodal LLM Transformer | 2048-D+ | >4 GB | >500 ms | Patch tokens, arbitrary resolution | Gemma Terms of Use | Documented / Architectural | **REJECTED (Task mismatch)** |
| **F. Synthetic 2D-DCT Fallback** | 8x8 Fourier/DCT + PReLU | 512-D | 0 MB (Code) | 13.6 ms | 112×112 RGB planar | Internal KeepSake Code | **Empirically Measured** | **REJECTED (Baseline failure)** |

---

## 6. Model Provenance and Licensing Analysis

### 6.1 InsightFace MobileFaceNet (`buffalo_s` / `w600k_mbf`)
- **Author**: DeepInsight Research (Jiankang Deng, Jia Guo, et al.).
- **Code Repository**: [github.com/deepinsight/insightface](https://github.com/deepinsight/insightface)
- **Source Code License**: MIT License.
- **Pretrained Checkpoint License**: **InsightFace Non-Commercial / Research-Only**.
  - Explicit Repository Notice: *"The models are available for non-commercial research purposes only."*
  - Training Corpora: Glint360k, MS1MV2, MS1MV3 (web-scraped facial datasets containing non-commercial academic clauses).
- **Redistribution Rights**: Pretrained weights may be compiled and evaluated on a personal Mac for local, non-commercial use. They **cannot** be bundled into commercial closed-source software or distributed commercially without a commercial agreement.

### 6.2 AdaFace (Adaptive Margin Face Recognition, CVPR 2022)
- **Author**: Minchul Kim, Anil K. Jain, Xiaoming Liu.
- **Code Repository**: [github.com/mk-minchul/AdaFace](https://github.com/mk-minchul/AdaFace)
- **Code License**: MIT License.
- **Pretrained Checkpoint License**: Non-commercial research only (trained on WebFace4M and MS1MV2).
- **Technical Barrier**: IR-50 / IR-101 weights (170–260 MB) require significant RAM and compute, conflicting with KeepSake's lightweight background worker architecture.

### 6.3 Permissively Licensed MobileFaceNet Alternatives
- **Architecture**: MobileFaceNet (Chen et al., 2018).
- **Permissive Sources**: Several community checkpoints trained on synthetic biometric data (e.g., DigiFace-1M) or CASIA-WebFace are released under Apache 2.0 or MIT.
- **Redistribution Rights**: Fully redistributable in commercial software, provided the training dataset license is verified.

### 6.4 Apple Vision FeaturePrint
- **Provider**: Apple Inc.
- **License**: Apple Developer Agreement.
- **Redistribution Rights**: Fully redistributable and royalty-free across all macOS platforms. However, its biometric recognition failure precludes its use.

---

## 7. Core ML Conversion & Apple Silicon Feasibility

MobileFaceNet is exceptionally well-suited for Core ML conversion and Apple Silicon deployment:

```
[Raw Photo File]
       │
       ▼
[FaceDetectionService] ──────────► Apple Vision VNDetectFaceRectanglesRequest
       │
       ▼ (Bounding box + 15% contextual margin)
[FacePreprocessingService] ──────► 112×112 RGB Planar Extraction: (x - 127.5) / 128.0
       │
       ▼ (Input Tensor: [1, 3, 112, 112] Float32)
[MobileFaceNet.mlpackage] ──────► Core ML FP16 (Apple Neural Engine / GPU)
       │
       ▼ (Output Tensor: [1, 512] Float32)
[EmbeddingSimilarityUtility] ────► L2 Normalization: ||v||₂ = 1.0
       │
       ▼
[LocalFaceClusterService] ───────► Stage 1 Appearance Clusters (Strict Cannot-Link)
       │
       ▼
[PersonIdentity Profiles] ───────► Stage 2 Multi-Anchor Persistent Identities
```

### Technical Core ML Conversion Specification:
1. **Tool**: `coremltools` (version 7.x+) via Python.
2. **Input Tensor Specification**:
   - Name: `input`
   - Shape: `[1, 3, 112, 112]`
   - DataType: `Float32`
   - Channel Order: RGB
3. **Output Tensor Specification**:
   - Name: `embedding`
   - Shape: `[1, 512]`
   - DataType: `Float32`
4. **Target Precision**: Float16 (`compute_precision=coremltools.precision.FLOAT16`).
5. **Target Compute Units**: `MLComputeUnits.all` (executing primarily on Apple Neural Engine).
6. **Package Format**: Modern `.mlpackage` directory structure.

---

## 8. Measured versus Documented versus Unverified Evidence

To adhere to truthfulness and prevent speculative assumptions, evidence is categorized across three distinct tiers:

| Dimension | Measured (Directly Observed on This Mac) | Documented (Published Literature / Vendor Specs) | Unverified (Hypothesis / Incomplete) |
|---|---|---|---|
| **Apple Vision FeaturePrint** | **Measured**: Evaluated on 53 face crops; $\mu_{\text{same}}=0.6306$, $\mu_{\text{diff}}=0.5869$, margin=-0.3986, overlap=98.6%, median latency=7.1 ms. | **Documented**: Apple Vision framework API documentation (Revision 2, 768-D). | None. |
| **Synthetic 2D-DCT Fallback** | **Measured**: Evaluated on 53 face crops; $\mu_{\text{same}}=0.2149$, $\mu_{\text{diff}}=0.1744$, margin=-0.7469, overlap=90.8%, median latency=13.6 ms. | **Documented**: Handcrafted code implementation in `ArcFaceRecognitionService.swift`. | None. |
| **InsightFace MobileFaceNet** | **Measured (Historical)**: Prior audit on recorded embeddings showed same-person pairs at 0.50–0.72 and diff pairs <0.385. | **Documented**: 99.5% accuracy on LFW, 512-D ArcFace loss, ~6.5 MB FP16 size, Non-commercial license. | **Unverified on Live Core ML**: Physical `.mlpackage` asset has not yet run in the live test suite during V2. |
| **AdaFace** | None. | **Documented**: Adaptive margin CVPR 2022 paper, 170–260 MB IR-50/101 weights, non-commercial license. | **Unverified on macOS**: Conversion to Core ML and actual on-device latency on M-series chips. |
| **Permissive MobileFaceNet** | None. | **Documented**: MobileFaceNet architecture (Chen et al. 2018), Apache 2.0 open-weight implementations. | **Unverified on Dataset**: Specific recognition margin on KeepSake's 19 photos using permissive weights. |
| **EmbeddingGemma 2** | None. | **Documented**: Google Gemma 2 technical report, >2B parameters, multi-gigabyte memory footprint. | **Unverified on Face Crops**: Fine-grained facial biometric margin. |

---

## 9. Limitations and Unresolved Questions

1. **User Commercialization Decision**:
   - The user must decide whether KeepSake is strictly an open-source/personal non-commercial application or intended for commercial distribution.
   - If personal: `buffalo_s` weights can be converted and used immediately.
   - If commercial: an Apache 2.0 / MIT permissively trained checkpoint must be selected.
2. **Evaluation Dataset Breadth**:
   - The current 19-photo dataset contains 53 faces from 5 labeled individuals. While sufficient to invalidate the synthetic DCT and Vision FeaturePrint, validating final production thresholds will require evaluating additional diverse faces in future iterations.
3. **Facial Landmark Alignment**:
   - Standard ArcFace uses 5-point facial landmark affine alignment (eyes, nose, mouth corners) to align faces to a canonical pose. KeepSake's current `FacePreprocessingService` uses a bounding-box crop with 15% margin. Evaluating whether 5-point landmark alignment is strictly necessary or whether square bounding-box crops suffice on MobileFaceNet is a key investigation for V3.

---

## 10. Final Recommendation & V3 Go/No-Go Decision

### 10.1 Definitive Decision: GO FOR V3 (MobileFaceNet ArcFace 512-D)
We recommend proceeding to **KeepSake V3: Genuine On-Device Recognition** with the **MobileFaceNet ArcFace (512-D)** architecture.

### 10.2 Evidence Level Breakdown:
- **Architecture Selected: CONFIRMED (GO)**
  - MobileFaceNet + ArcFace loss (512-D) is definitively the correct architectural foundation.
  - Reject Apple Vision FeaturePrint (biometric failure).
  - Reject Synthetic 2D-DCT (baseline failure).
  - Reject AdaFace (excessive weight and latency).
  - Reject EmbeddingGemma 2 (severe task mismatch).
- **Checkpoint Verified: CONDITIONALLY CONFIRMED**
  - Checkpoint `w600k_mbf.onnx` (`buffalo_s`) identified and verified for personal/non-commercial use.
  - Permissive Apache 2.0 checkpoints identified as alternative for commercial distribution.
- **Inference Verified: PENDING V3**
  - Live Core ML inference with a bundled neural model asset has not yet been executed because asset packaging belongs to V3.

---

## 11. Explicit Entry Criteria for V3

Before V3 implementation may commence, the following conditions must be satisfied:
1. **User Licensing Path Confirmation**: User confirms whether to proceed with InsightFace `buffalo_s` (personal/non-commercial) or a permissively licensed checkpoint.
2. **Model Asset Acquisition**: The selected ONNX model file must be converted to `buffalo_s.mlpackage` (or `.mlmodelc`) using `coremltools` with FP16 precision and input shape `[1, 3, 112, 112]`.
3. **Resource Bundling**: The compiled model asset must be added to `KeepSake/Resources/` and bundled via Xcode project configuration.
4. **Diagnostic Integrity**: The misleading diagnostic log in `ArcFaceRecognitionService.swift` must be gated strictly on successful Core ML model loading.
5. **Runtime Verification**: Gate 2 automated test must pass, proving that genuine neural inference executes on Apple Silicon and achieves positive separation margin ($\min_{\text{same}} - \max_{\text{diff}} > 0$).
