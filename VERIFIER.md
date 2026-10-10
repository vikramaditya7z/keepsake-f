# VERIFIER.md — Evidence Required for Progress

This document establishes the mandatory verification protocol for every task in the KeepSake identity development loop. No task or iteration may be marked complete without providing concrete empirical evidence satisfying these requirements.

---

## 1. General Verification Standard

1. **Compiling is Not Verifying**: Code compilation and passing synthetic unit tests are necessary preconditions, not proof of product success.
2. **Behavioral Evidence Required**: You must observe and document actual runtime behavior (embeddings generated, similarity distributions, cluster assignments, identity persistence).
3. **Card Count Reduction is Not Success**: Merely reducing the count of People cards is invalid evidence unless accompanied by proof of zero cross-person contamination.
4. **Exact Commands and Outputs**: Every verification step must record the exact command executed, elapsed time, exit code, and key output snippets.
5. **Acknowledge Data Limitations**: If the available dataset cannot definitively prove a claim (e.g. edge case not represented in the 19 photos), explicitly state that limitation rather than assuming success.

---

## 2. Mandatory Verification Gates

### Gate 1: Build & Unit Test Suite
Before any experiment or check, the full test suite must pass without regressions:
```bash
xcodebuild -project KeepSake.xcodeproj -scheme KeepSakeTests -derivedDataPath ./build/DerivedData build-for-testing CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO && xcrun xctest ./build/DerivedData/Build/Products/Debug/KeepSake.app/Contents/PlugIns/KeepSakeTests.xctest
```
- **Passing Condition**: 150+ tests executed, 0 failures, 0 unexpected crashes.

### Gate 2: Genuine Model Asset & Inference Verification
Whenever face recognition, embeddings, or inference pipelines are modified:
1. **Asset Presence Check**: Verify that the actual `.mlmodelc` or `.mlpackage` file exists on disk and is bundled into the application bundle:
   ```bash
   ls -la KeepSake/Resources/*.mlmodel* 2>/dev/null || ls -la build/DerivedData/Build/Products/Debug/KeepSake.app/Contents/Resources/*.mlmodel*
   ```
2. **Inference Backend Verification**: Run an inference pass and verify that Core ML executes the compiled model rather than the fallback DCT projection.
3. **Embedding Vector Properties**:
   - Vector dimension must equal exactly 512 floats.
   - Euclidean norm $\|\mathbf{v}\|_2$ must equal $1.0 \pm 0.001$ (unit L2-normalized).
   - Vectors must be non-zero and deterministic for identical input crops.
4. **Separation Margin Check**:
   - Same-person cosine similarities must reliably exceed the separation boundary (target: $\mu \ge 0.65$, $\min \ge 0.48$).
   - Different-person cosine similarities must stay below the separation boundary (target: $\max \le 0.40$).
   - Separation margin: $\min(\text{same}) - \max(\text{diff}) > 0$.

### Gate 3: Cannot-Link & Invariant Verification
1. **Zero Same-Photo Co-occurrence**:
   - For every cluster, group, and person identity: query all member faces' source photo IDs.
   - `memberFaceIds.count == uniquePhotoIds.count`.
   - If `uniquePhotoIds.count < memberFaceIds.count`, the test **FAILS IMMEDIATELY**.
2. **Unique Assignment**:
   - Each detected face ID must belong to at most one person identity.
   - Set intersection of all identity member face IDs must be empty: $\bigcap \text{members}_k = \emptyset$.
3. **Multi-Person Photo Galleries**:
   - For any photo containing multiple detected faces ($P_A, P_B$), query `fetchPhotos(forGroupId:)` for Person A and Person B.
   - The photo must appear in both galleries, resolved without duplicate records.

### Gate 4: Persistence, Idempotency & User Curation Survival
1. **Cold Restart Simulation**:
   - Save library state to `library_index.json`.
   - Re-instantiate `LibraryStore` from disk URL.
   - Verify: all `GroupRecord`s, custom names, member face lists, and centroids load identically.
2. **Repeated Ingestion / Refresh Idempotence**:
   - Run `LibraryProcessingCoordinator` or `reconcile()` across the same folder twice.
   - Second pass must produce:
     - 0 duplicate photos.
     - 0 duplicate face records.
     - 0 duplicate person groups.
     - 0 modified custom names.
3. **User Curation Immutability**:
   - Set a custom name (e.g. "Alice") on a group.
   - Run automatic re-clustering / folder refresh.
   - Verify that the group's custom name, ID, and curated member faces are completely preserved.

### Gate 5: Production Dataset Diagnostic Audit (19 Photos, 53 Faces)
When evaluating the full pipeline against the 19-photo ground-truth dataset:
1. Run diagnostic audit tool/test against `/Users/vikramaditya/Library/Application Support/KeepSake/library_index.json` or live folder.
2. Report the following empirical metrics:
   - Total Photos: 19
   - Total Detected Faces: 53
   - Total People Cards in UI / Groups in Store
   - Number of Multi-Face Groups vs Singleton Groups
   - Confirmed Matches (True Positives)
   - False Merges (False Positives — must be 0)
   - Split Identities (False Negatives)
   - Unassigned / Ambiguous Faces
   - Cannot-Link Violations (must be 0)

---

## 3. Disallowed Evidence Claims

The following claims will be rejected as invalid:
- ❌ *"Clustering is now solved because groups decreased from 52 to 20."* (Without proving 0 false merges).
- ❌ *"ArcFace model is integrated."* (When no `.mlmodelc` file exists and the DCT projection is executing).
- ❌ *"Cannot-Link is verified."* (Without auditing all pairwise co-occurrences in the actual output).
- ❌ *"User names persist."* (Without simulating an actual reload or rescan pass).
