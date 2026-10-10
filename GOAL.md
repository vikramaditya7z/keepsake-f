# GOAL.md — Keepsake Identity & Face Recognition System

## 1. Project Objective

Build a reliable, local-first macOS photo organizer that detects faces, extracts authentic deep recognition embeddings, and learns person identities through user confirmation.

The system must solve the face-to-identity assignment problem safely and accurately:
1. When a user imports a photo collection, KeepSake detects all faces and extracts genuine deep recognition embeddings.
2. The user can select multiple face crops belonging to the same human and assign that person a name.
3. KeepSake stores a persistent, local identity profile containing multiple confirmed reference embeddings (appearance modes / anchors).
4. When additional photos are imported or the library is refreshed, KeepSake compares new face instances against known, confirmed identities.
5. High-confidence matches are assigned automatically to existing identities.
6. Ambiguous matches are flagged for user review rather than falsely unified.
7. Unknown faces remain unassigned in an "Unassigned Faces" inbox.
8. User-confirmed identities, custom names, manual corrections, and stable IDs persist across rescans, imports, and application restarts.

---

## 2. Core Product & Architectural Rules

1. **100% On-Device & Private**: All photos, crops, bounding boxes, embeddings, and identity metadata remain strictly on the user's Mac. Zero network calls, zero external API dependencies, zero cloud sync.
2. **One Real Human = One Person Identity**: The end-state People section must display one People card per real human. Faces belonging to the same human across different photos, lighting conditions, angles, and cameras should unify under that person.
3. **Zero False-Positive Merges**: Different people must never be merged into the same identity. False positive merges severely degrade trust and corrupt user galleries.
4. **Strict Cannot-Link Constraint**: Two different faces detected in the same photograph can **never** belong to the same Person identity or FaceCluster.
5. **Multi-Person Photos**: A group photograph containing multiple recognized individuals must appear in the gallery of **every** person present in that photo. A photo belongs to multiple people; each face belongs to exactly one person.
6. **Preservation of User Curation**: User-assigned names, manual face reassignments, manual merges, and confirmed identities are authoritative ground truth. Automatic re-clustering or scanning must never overwrite, rename, or dismantle user-confirmed identities.
7. **Idempotent Rescan & Reconciliation**: Refreshing or rescanning the same folder must rerun necessary reconciliation, detect modified/new files, and update the UI without creating duplicate identities or corrupting existing library state.
8. **Genuine Model Verification**: **Never** claim a machine learning model is integrated unless its actual assets (`.mlmodelc` / `.mlpackage`) are physically present, loaded by Core ML, and verified via real inference. Fake or synthetic feature projections (such as 2D-DCT fallbacks) must never masquerade as deep neural networks.
9. **Accuracy Over Card Count**: The objective is reliable, ground-truth identity recognition, not arbitrarily driving down the People card count by lowering thresholds.

---

## 3. End-to-End User & Data Workflow

```
[User Selects Folder]
         │
         ▼
[Local Scanning & Change Detection] ──► (Prune deleted, detect new/modified)
         │
         ▼
[Vision Face Detection] ──────────────► (Bounding boxes & landmark filtering)
         │
         ▼
[Face Crop & Preprocessing] ──────────► (112x112 RGB planar tensor extraction)
         │
         ▼
[Deep Neural Embedding] ──────────────► (Authentic 512-D Core ML embeddings)
         │
         ▼
[Stage 1: Local FaceCluster Formation]► (Tight, high-precision appearance clusters; strict Cannot-Link)
         │
         ▼
[Stage 2: Known Identity Matching] ───► (Compare against confirmed user profiles via anchor/centroid similarity)
         ├── High-confidence match ──► Auto-assign to Person Identity
         ├── Ambiguous match ────────► Flag for user review
         └── Unmatched / New ────────► Stage 3 Discovery / Unassigned Faces
         │
         ▼
[Stage 3: User Confirmation & Naming] ─► (User names person, confirms suggested clusters, resolves ambiguous faces)
         │
         ▼
[Persistent Storage (LibraryStore)] ──► (Atomic durability, stable UUIDs, restart recovery)
```

---

## 4. Acceptance Criteria & Definition of Done

- [ ] **Verified Model Asset**: A genuine, licensed, on-device face recognition model (e.g. InsightFace MobileFaceNet / buffalo_s or equivalent Core ML network) is bundled, loaded by Core ML, and producing verified discriminative embeddings (distinct separation between same-person and different-person distributions).
- [ ] **Zero Cannot-Link Violations**: No cluster, group, or person identity ever contains two faces from the same photo.
- [ ] **Persistent Identity Profiles**: Identity profiles store multiple verified anchor embeddings, maintaining stable recognition across varied appearance modes (close-up, profile, glasses, distant).
- [ ] **Safe Incremental Ingestion**: Importing new photos correctly routes faces to: (a) existing confirmed identity, (b) suggested match for review, or (c) unassigned inbox.
- [ ] **Curated Data Immutability**: All custom names and manual merges persist across restarts and re-scans with 100% fidelity.
- [ ] **Production Dataset Validation**: Evaluated against the 19-photo ground-truth dataset (53 faces, 17 real individuals) with zero cross-person contamination, verified photo gallery listings, and documented metrics.
