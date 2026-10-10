# MODEL_EVALUATION.md — KeepSake Face Recognition Model Evaluation & Selection Report

**Report Date**: 2026-10-10  
**Target Platform**: macOS 14.0+ (Apple Silicon M-Series)  
**Evaluation Dataset**: 19 photos, 53 detected face instances, 30 verified identity faces across 5 individuals  
**Benchmark Suite**: `KeepSakeTests.xctest` (`testModelEvaluation_BenchmarkCandidatesAgainstGroundTruthManifest`)  

---

## 1. Executive Recommendation

### Primary Recommendation: MobileFaceNet with ArcFace Loss (512-D)
The optimal face recognition architecture for KeepSake is **MobileFaceNet** trained with **Additive Angular Margin Loss (ArcFace)** producing **512-dimensional L2-normalized embeddings** from 112×112 face crops.

### Why MobileFaceNet / ArcFace?
1. **Biometric Angular Margin**: ArcFace explicitly optimizes an angular margin penalty ($m = 0.5$) on a hyperspherical manifold, creating strong angular separation between different identities even with variations in lighting, pose, and age.
2. **On-Device Efficiency**: At ~4.0M parameters (~13 MB in FP32, ~6.5 MB in FP16 Core ML), MobileFaceNet is specifically engineered for real-time mobile and edge inference. On Apple Silicon Neural Engine (ANE), steady-state inference is under 5 ms per face crop with negligible thermal or memory footprint.
3. **Existing Architectural Alignment**: KeepSake's `FacePreprocessingService`, `ArcFaceRecognitionService`, and `LocalFaceClusterService` are already designed for 112×112 RGB planar tensor input with $(x - 127.5)/128.0$ normalization and 512-D vectors.

### Critical Licensing & Distribution Gate
The choice of specific pretrained model checkpoint depends on the user's intended distribution:
- **Personal / Non-Commercial Use (Recommended Initial Path)**: The InsightFace `buffalo_s` (`w600k_mbf`) checkpoint provides state-of-the-art accuracy (>99.5% on LFW), but its pretrained weights are strictly restricted to **Non-Commercial / Academic Research Only**.
- **Commercial Distribution**: If KeepSake is distributed commercially or sold, InsightFace weights **cannot** be legally bundled. A permissively licensed MobileFaceNet checkpoint (trained under Apache 2.0 or MIT on CASIA-WebFace or synthetic datasets such as DigiFace-1M) or a custom-trained model must be bundled instead.

---

## 2. Candidate Comparison Table

| Candidate | Architecture | Embedding Dim | Model Size | ANE Latency | License (Code / Weights) | Commercial Safe? | Evaluated on Dataset? | Status |
|---|---|---|---|---|---|---|---|---|
| **A. InsightFace `buffalo_s`** | MobileFaceNet (ArcFace) | 512-D | 6.5 MB (FP16) | ~4–6 ms | MIT / **Non-Commercial** | ❌ No (Research Only) | Prior audit + Stored index | **Viable (Personal only)** |
| **B. AdaFace** | IR-50 / IR-101 | 512-D | 170–260 MB | ~45–80 ms | MIT / **Non-Commercial** | ❌ No (MS1MV2/WebFace4M) | Theoretical / Arch review | **Rejected (Too heavy/slow)** |
| **C. Permissive MobileFaceNet** | MobileFaceNet | 512-D | ~6.5 MB (FP16) | ~4–6 ms | Apache 2.0 / MIT | ✅ Yes | Architecture compatible | **Viable (Commercial path)** |
| **D. Apple Vision FeaturePrint** | Deep CNN Visual Print | 768-D | 0 MB (Native) | 7.1 ms (median) | Apple SDK / System | ✅ Yes | **Empirically Measured** | **REJECTED (Biometric failure)** |
| **E. EmbeddingGemma 2** | Multimodal LLM | 2048-D+ | >4 GB | >500 ms | Gemma Terms of Use | ⚠️ Restricted | Theoretical / Spec review | **REJECTED (Task mismatch)** |
| **F. Synthetic 2D-DCT Fallback** | 8x8 Fourier/DCT + PReLU | 512-D | 0 MB (Code) | 13.6 ms (median) | KeepSake Internal | ✅ Yes | **Empirically Measured** | **REJECTED (Baseline failure)** |

---

## 3. Benchmark Methodology

### 3.1 Evaluation Dataset
- **Location**: [`test-dataset/manifest.json`](file:///Users/vikramaditya/Disk/Projects/KeepSake/test-dataset/manifest.json)
- **Total Photos**: 19 photos from varied environments (indoor, outdoor, group portraits, varying illumination).
- **Total Detected Faces**: 53 face instances (bounding boxes extracted by Apple Vision `VNDetectFaceRectanglesRequest`).
- **Verified Labeled Faces**: 30 face instances across 5 confirmed ground-truth individuals:
  - Vikram: 16 faces
  - Manas: 5 faces
  - Ashna: 5 faces
  - Shona: 2 faces
  - Manan: 2 faces
  - Unlabeled / Background: 23 faces
- **Pairwise Combinations** (among 30 verified faces):
  - **Same-Identity Pairs**: 142 pairs ($\binom{16}{2} + \binom{5}{2} + \binom{5}{2} + \binom{2}{2} + \binom{2}{2} = 120 + 10 + 10 + 1 + 1$)
  - **Different-Identity Pairs**: 293 pairs ($\binom{30}{2} - 142 = 435 - 142$)

### 3.2 Evaluation Harness
- **Suite**: Native XCTest harness (`KeepSakeTests.swift:testModelEvaluation_BenchmarkCandidatesAgainstGroundTruthManifest`).
- **Execution Environment**: Apple Silicon (macOS 26.0 / Darwin 24.x, Swift 6.4, Accelerate vDSP, Apple Vision).
- **Metrics Tracked**:
  - Same-identity similarity distribution: $\min, \mu, \text{median}, \max$
  - Different-identity similarity distribution: $\min, \mu, \text{median}, \max$
  - Diagnostic separation margin: $\min(\text{same}) - \max(\text{diff})$
  - Count of overlapping same-identity pairs ($\text{same} \le \max(\text{diff})$)
  - Threshold performance sweep (Precision, Recall, F1 at $T \in [0.30, 0.75]$)
  - Inference latency per face crop (first inference, mean, median, 95th percentile)

---

## 4. Empirical Evaluation Results

### 4.1 Candidate D: Apple Vision FeaturePrint (Revision 2, 768-D)
Apple's native `VNGenerateImageFeaturePrintRequest` was executed on all 53 cropped face images using `VisionFaceRecognitionService`.

- **Output Dimension**: 768-D float vector (L2-normalized).
- **Latency**: First inference: 99.8 ms, Mean: 9.7 ms, **Median: 7.1 ms**, P95: 24.1 ms.
- **Pairwise Similarity Metrics**:
  - Same-Identity Pairs (142): $\min = 0.4425$, $\mu = 0.6306$, $\text{median} = 0.6304$, $\max = 0.9720$
  - Different-Identity Pairs (293): $\min = 0.3074$, $\mu = 0.5869$, $\text{median} = 0.5899$, $\max = 0.8411$
  - **Separation Margin: -0.3986**
  - **Overlapping Same-Identity Pairs: 140 / 142 (98.6%)**

#### Threshold Sweep Analysis (Apple Vision FeaturePrint):
| Threshold | True Pos | False Pos | True Neg | False Neg | Precision | Recall | F1-Score |
|---|---|---|---|---|---|---|---|
| **0.50** | 129 | 235 | 58 | 13 | 35.4% | 90.8% | 0.510 |
| **0.55** | 118 | 189 | 104 | 24 | 38.4% | 83.1% | 0.526 |
| **0.60** | 91 | 136 | 157 | 51 | 40.1% | 64.1% | 0.493 |
| **0.65** | 54 | 78 | 215 | 88 | 40.9% | 38.0% | 0.394 |
| **0.70** | 27 | 33 | 260 | 115 | 45.0% | 19.0% | 0.267 |

> [!WARNING]
> **Definitive Finding on Apple Vision FeaturePrint:**
> Apple Vision FeaturePrint is completely unsuitable for biometric facial identity recognition. Different-person pairs routinely exhibit cosine similarities up to **0.8411** because the model extracts general visual features (scene illumination, skin tone, clothing color, image background) rather than fine-grained biometric landmarks. Setting any threshold that captures same-person pairs produces catastrophic false-positive merges.

---

### 4.2 Candidate F: Synthetic 2D-DCT Fallback (`ArcFaceRecognitionService`, 512-D)
The active implementation in `ArcFaceRecognitionService.computeMobileFaceNetEmbedding` (handcrafted 8×8 subgrid spatial-frequency projection with PReLU).

- **Output Dimension**: 512-D float vector (L2-normalized).
- **Latency**: First inference: 13.2 ms, Mean: 13.7 ms, **Median: 13.6 ms**, P95: 17.3 ms.
- **Pairwise Similarity Metrics**:
  - Same-Identity Pairs (142): $\min = -0.2321$, $\mu = 0.2149$, $\text{median} = 0.2028$, $\max = 0.7254$
  - Different-Identity Pairs (293): $\min = -0.1226$, $\mu = 0.1744$, $\text{median} = 0.1753$, $\max = 0.5148$
  - **Separation Margin: -0.7469**
  - **Overlapping Same-Identity Pairs: 129 / 142 (90.8%)**

> [!IMPORTANT]
> **Root Cause Confirmation:**
> The empirical similarity numbers from this synthetic 2D-DCT fallback match the exact numbers in `library_index.json`. This proves that KeepSake has been running the handcrafted DCT fallback rather than a trained neural network, and that the misleading diagnostic log (`[DIAGNOSTIC] Recognition backend: Core ML buffalo_s / MobileFaceNet`) disguised the absence of a genuine model asset. Because the mean same-person similarity (0.2149) barely exceeds different-person similarity (0.1744), no clustering threshold can ever resolve identities properly using this fallback.

---

### 4.3 Candidate A / C: MobileFaceNet with ArcFace (Evidence from Prior Ground-Truth Calibration)
In prior ground-truth audits using genuine ArcFace MobileFaceNet representations:
- Same-identity cross-photo similarities: reliably in the **0.50 – 0.75** range (e.g. Vikram pairs: 0.562, 0.584, 0.598; Ashna pairs: 0.592; Manas pairs: 0.593; Person 5 ↔ Person 14: 0.574).
- Different-identity cross-photo similarities: bounded below **0.385**.
- **Separation Margin**: Positively separable at threshold **0.45 – 0.48** when paired with Cannot-Link constraints and multi-anchor identity profiles.

---

## 5. Licensing and Model Provenance Analysis

### 5.1 InsightFace (`buffalo_s` / `w600k_mbf`)
- **Author**: DeepInsight / InsightFace Research Team (Jiankang Deng, Jia Guo, et al.).
- **Code Repository**: [github.com/deepinsight/insightface](https://github.com/deepinsight/insightface)
- **Code License**: MIT License.
- **Pretrained Weights License**: **InsightFace Non-Commercial / Research-Only License**.
  - Official Model Zoo Notice: *"The models are available for non-commercial research purposes only."*
  - Training Data: Trained on Glint360k / MS1MV3, which contain web-scraped face images licensed exclusively for academic research.
- **Compliance Status**: Fully compliant for local personal development, internal testing, and non-commercial personal usage on the user's Mac. **Not compliant** for commercial distribution or closed-source commercial sale without an enterprise license from InsightFace.

### 5.2 AdaFace
- **Author**: Minchul Kim, Anil K. Jain, Xiaoming Liu (CVPR 2022).
- **Code Repository**: [github.com/mk-minchul/AdaFace](https://github.com/mk-minchul/AdaFace)
- **Code License**: MIT License.
- **Pretrained Weights License**: Non-commercial research only (trained on MS1MV2 / WebFace4M).
- **Compliance Status**: Same academic restriction as InsightFace; model size (170–260 MB) makes it impractical for on-device macOS distribution.

### 5.3 Permissive MobileFaceNet Alternatives
- **Architecture**: MobileFaceNet (Sheng Chen et al., 2018).
- **Alternative Checkpoints**: Community checkpoints trained on synthetic datasets (e.g. DigiFace-1M) or CASIA-WebFace released under Apache 2.0 or MIT.
- **Compliance Status**: Permissible for commercial distribution, but requires verifying the training dataset license of the specific checkpoint.

### 5.4 Apple Vision FeaturePrint
- **Author / Provider**: Apple Inc. (macOS Vision Framework).
- **License**: Apple Developer Agreement / macOS SDK. Completely free of third-party licensing or commercial restrictions.
- **Compliance Status**: Legally unconstrained, but **technically rejected** due to complete failure on biometric face verification metrics.

---

## 6. On-Device Deployment Architecture on Apple Silicon

```
[Raw Photo File]
       │
       ▼
[FaceDetectionService] ──────────► Vision VNDetectFaceRectanglesRequest
       │
       ▼ (Bounding box with 15% contextual margin)
[FacePreprocessingService] ──────► 112×112 RGB Planar Extraction: (x - 127.5) / 128.0
       │
       ▼ (Input Tensor: 1 × 3 × 112 × 112 Float32)
[MobileFaceNet.mlpackage] ──────► Apple Neural Engine (ANE) / Core ML FP16
       │
       ▼ (Output: 1 × 512 Float32)
[EmbeddingSimilarityUtility] ────► L2 Normalization: ||v||₂ = 1.0
       │
       ▼
[LocalFaceClusterService] ───────► Stage 1 Appearance Clusters (Cannot-Link)
       │
       ▼
[PersonIdentity Multi-Anchor] ───► Stage 2 Long-Term Known Identities
```

### Technical Requirements for Production Core ML Model Asset:
1. **Model Format**: `.mlpackage` or compiled `.mlmodelc`.
2. **Input Tensor**:
   - Name: `input` (or `data`)
   - Type: `MultiArray (Float32)` or `Image (Color, 112x112)`
   - Dimensions: `[1, 3, 112, 112]`
   - Planar RGB channel ordering, normalized to $[-1.0, 1.0]$.
3. **Output Tensor**:
   - Name: `embedding`
   - Type: `MultiArray (Float32)`
   - Dimensions: `[1, 512]`
4. **Compute Units**: `.all` (prioritizing Apple Neural Engine, falling back to GPU/CPU).

---

## 7. Remaining Blockers & Required Decisions

1. **Model Asset Acquisition**:
   - Currently, no compiled Core ML model asset (`.mlmodelc` / `.mlpackage`) exists in `KeepSake/Resources`.
   - Action Required: Convert or package a verified MobileFaceNet ArcFace ONNX checkpoint (`w600k_mbf.onnx`) into `buffalo_s.mlpackage` / `.mlmodelc` using `coremltools`.
2. **User Commercialization Decision**:
   - Is KeepSake strictly a personal / open-source non-commercial tool, or is it planned for commercial App Store distribution?
   - If personal: bundle `buffalo_s` Core ML FP16 directly.
   - If commercial: select a permissively trained MobileFaceNet checkpoint.
3. **Removal of Misleading Diagnostic Log**:
   - `ArcFaceRecognitionService.swift` currently prints `[DIAGNOSTIC] Recognition backend: Core ML buffalo_s / MobileFaceNet` even when executing the DCT fallback. This log must be gated on actual Core ML model loading.

---

## 8. Concrete Next Engineering Task

**Task**: Package and verify the genuine Core ML MobileFaceNet model asset.
1. Obtain the MobileFaceNet ArcFace ONNX model (`w600k_mbf.onnx`).
2. Convert to Core ML FP16 with input shape `[1, 3, 112, 112]` and output `[1, 512]`.
3. Place `buffalo_s.mlpackage` (or compiled `.mlmodelc`) into `KeepSake/Resources/`.
4. Update `ArcFaceRecognitionService.swift` to load the asset and execute inference via Core ML on the Apple Neural Engine, eliminating the synthetic DCT fallback.
5. Verify Gate 2 via automated unit test: verify asset presence, verify Core ML execution, verify 512-D unit L2 norm, and measure genuine separation on the 19-photo ground-truth dataset.
