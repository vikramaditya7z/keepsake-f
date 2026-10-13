# KeepSake V7 Implementation Report: Identity Corrections, Bulk Assignment & Folder-Scoped Review

**Milestone**: KeepSake V7  
**Date**: October 11, 2026  
**Status**: COMPLETE & VERIFIED  
**Automated Tests**: 176 passing (0 failures), 11.25s execution time  
**App Build Status**: Clean Build (`KeepSake.app`, exit code 0)  
**Live Data Integrity**: Preserved (Live: 408,586 bytes, Backup: 472,584 bytes, 0 bytes mutated)  
**Git Integrity**: Zero commits, zero pushes; all changes unstaged for user review  

---

## 1. Executive Summary

Milestone V7 completes the identity correction and curation workflow in KeepSake. Building directly upon the central People Database established in V6, V7 resolves four critical user friction points:

1. **Folder-Scoped Review Queues**: Suggestions and unassigned faces from previously indexed folders no longer leak into newly opened or empty folders.
2. **Multi-Select & Bulk Assignment**: Users can enter a multi-selection mode in `UnassignedFacesView`, select multiple unassigned faces at once, and assign them in bulk to an existing confirmed person or create a new person.
3. **Cannot-Link Safety Enforcement**: The system strictly prevents assigning or merging faces originating from the same photo into the same identity (which is an ontological impossibility in real photography). This is verified at both the UI layer (warning banners and disabled buttons) and service layer (`IdentityServiceError.cannotLinkViolation`).
4. **Granular Face Removal**: Users can remove an individual mismatched face from a candidate suggestion before confirming it, or remove/move an individual face from a confirmed person, without losing the rest of the group.
5. **Authoritative Identity Merging**: Duplicate confirmed people can be merged safely with side-by-side preview and Cannot-Link validation.

All changes are backed by automated regression tests in `KeepSakeTests.swift` (176 tests passing, 0 failures), compile cleanly, and leave existing user databases completely untouched.

---

## 2. Problem Analysis & Architectural Solutions

### 2.1 Problem 1: Pending Suggestions & Unassigned Faces Leaking Across Folders

#### Root Cause
In V6, `GroupRecord` lacked folder scoping metadata, and `LibraryStore.getUngroupedFaces()` scanned the entire library snapshot without filtering by the active folder. Consequently, opening an empty folder or a different folder still rendered suggestions and unassigned faces belonging to photos from previously opened directories.

#### Solution
1. **Schema Augmentation (`GroupRecord.rootFolderPath`)**:
   Added an optional `var rootFolderPath: String? = nil` to `GroupRecord` in `PersistedModels.swift`, with backward-compatible `decodeIfPresent` decoding.
2. **Tagging in Coordinator**:
   When `LibraryProcessingCoordinator` generates candidate groups, it attaches `rootFolderPath: rootFolderURL.standardizedFileURL.path`. Existing candidate groups belonging to other folders are preserved untouched during re-clustering (`g.rootFolderPath != activeRootPath`).
3. **Folder-Scoped Queries (`LibraryStore`)**:
   Added `getCandidateGroups(forRootFolderPath:)`, `getGroups(forRootFolderPath:)`, and `getUngroupedFaces(forRootFolderPath:)`.
4. **View Model Scoping (`PeopleViewModel`)**:
   `loadData(rootFolderURL:)` now passes the active folder's standardized path to `LibraryStore`, scoping candidate suggestions and unassigned faces strictly to the currently loaded folder, while confirmed people from the Central People Database remain accessible library-wide.

---

### 2.2 Problem 2: Unassigned Friction & Multi-Select Bulk Assignment

#### Root Cause
Rejecting candidate suggestions or detecting unassigned faces forced users to click and assign each face one by one through an individual sheet. With dozens of unassigned faces, this was slow and tedious.

#### Solution
1. **Interactive Multi-Select Mode (`UnassignedFacesView`)**:
   - Added `isSelectingUnassigned: Bool` toggle ("Select" / "Done") in the toolbar.
   - Added "Select All" and "Deselect All" controls with real-time selection count indicators ("N faces selected").
   - Added tap-to-select checkboxes on thumbnail cards when in selection mode.
2. **Bulk Assignment Action Bar**:
   - Floating action bar appears at the bottom of the unassigned view with:
     - **"Assign to Person…"**: Opens a searchable picker of confirmed identities.
     - **"Create New Person…"**: Prompts for a person's name and creates a new `PersonRecord` populated with all selected faces.
3. **Cannot-Link Live Conflict Banner**:
   - If a user selects two faces originating from the same photograph, `UnassignedFacesView` displays an inline warning banner:
     *"Selection Conflict: Cannot assign multiple faces from the same photo to one person."*
   - Bulk assign and bulk create buttons are automatically disabled until the conflict is resolved.

---

### 2.3 Problem 3: Inaccurate Groupings & Granular Face Removal

#### Root Cause
Candidate suggestions could contain an outlier face belonging to a different person. Previously, the user had to either accept the whole cluster (contaminating the person) or reject the entire cluster (losing the valid matches). Furthermore, once confirmed, there was no granular removal of individual faces from candidate suggestions.

#### Solution
1. **Removal from Candidate Suggestions (`removeFaceFromCandidateGroup`)**:
   - Users can drill down into a candidate suggestion card to view its member faces.
   - Each face card features a "Remove from Suggestion" button.
   - Triggering removal deletes the face UUID from `candidateGroup.memberFaceIds` and saves the updated group. The removed face immediately returns to the unassigned pool for independent assignment.
   - If the group drops to $\le 1$ face, the remaining faces are gracefully transitioned to unassigned or singletons without orphan records.
2. **Removal & Moving on Confirmed Identities (`removeFaceFromPerson`, `moveFace`)**:
   - In `PersonDetailView`, each face card in the "Faces" tab provides "Remove from Person" and "Move to Another Person".
   - Removing a face unlinks it from `PersonRecord.memberFaceIds` and updates the person's anchor embeddings.
   - Moving a face to another person validates Cannot-Link constraints before transferring the face ID and recalculating embeddings.

---

### 2.4 Problem 4: Authoritative Merging of Duplicate Confirmed People

#### Root Cause
Merging duplicate identities in earlier iterations relied on transient `GroupRecord`s instead of operating authoritatively on central `PersonRecord` entities, and did not check whether the two identities ever appeared in the same photo.

#### Solution
1. **Atomic Store Operation (`LibraryStore.mergePeople`)**:
   - Takes `targetPersonId` and `sourcePersonId`.
   - Combines member face IDs using a set union: `target.memberFaceIds = Array(Set(target.memberFaceIds + source.memberFaceIds))`.
   - Copies anchor embeddings and updates the centroid.
   - Deactivates the source person (`isActive = false`) and removes source group records.
2. **Service Validation (`IdentityService.mergePeople`)**:
   - Queries photo IDs for all faces in both source and target people.
   - If $\text{photoIds}_{\text{source}} \cap \text{photoIds}_{\text{target}} \neq \emptyset$, the operation throws `IdentityServiceError.cannotLinkViolation("Cannot merge: Both people appear in the same photo.")`.
3. **Preview & Safety UI (`MergePeopleSheet`)**:
   - Shows a side-by-side comparison of Source Person vs Target Person, displaying current face counts, photo counts, and predicted merged totals.
   - Displays an explicit confirmation dialog explaining that the source person will be archived into the target person.

---

## 3. Data Flow & State Architecture

```
┌────────────────────────────────────────────────────────────────────────┐
│                        PeopleViewModel (Active Folder)                 │
├────────────────────────────────┬───────────────────────────────────────┤
│ Active Folder Filtered State:  │ Central People Database State:        │
│ • candidateGroups (scoped)     │ • people: [PersonRecord] (library-wide│
│ • unassignedFaces (scoped)     │ • activePersonProfiles                │
└───────────────┬────────────────┴───────────────────┬───────────────────┘
                │                                    │
                ▼                                    ▼
┌────────────────────────────────┐  ┌────────────────────────────────────┐
│      UnassignedFacesView       │  │          PersonDetailView          │
│ • Multi-select mode            │  │ • Candidate review banner          │
│ • Cannot-Link conflict banner  │  │ • "Remove from Suggestion" button  │
│ • Bulk Assign / Bulk Create    │  │ • "Move to Another Person" button  │
└───────────────┬────────────────┘  └────────────────┬───────────────────┘
                │                                    │
                ▼                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│                   IdentityService (Business Logic)                     │
│ • bulkAssignFaces(faceIds:targetPersonId:)                             │
│ • bulkCreatePerson(withFaceIds:name:rootFolderURL:)                    │
│ • removeFaceFromCandidateGroup(faceId:groupId:)                        │
│ • removeFaceFromPerson(personId:faceId:)                               │
│ • moveFace(faceId:fromPersonId:toPersonId:)                            │
│ • mergePeople(targetPersonId:sourcePersonId:)                          │
│                                                                        │
│ Invariant Gate: photoIds.count == faceIds.count (Cannot-Link check)    │
└───────────────────────────────┬────────────────────────────────────────┘
                                │
                                ▼
┌────────────────────────────────────────────────────────────────────────┐
│                LibraryStore (Actor-Isolated Persistence)               │
│ • Atomic snapshot read/write                                           │
│ • Folder-scoped queries (rootFolderPath filtering)                    │
│ • Atomic person mutations & index sanitization                         │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 4. Verification & Test Evidence

### 4.1 Automated Test Execution
The complete test suite was executed against the built testing bundle using `xcrun xctest`:

```bash
xcodebuild -project KeepSake.xcodeproj -scheme KeepSakeTests -derivedDataPath ./build/DerivedData build-for-testing CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO && xcrun xctest ./build/DerivedData/Build/Products/Debug/KeepSake.app/Contents/PlugIns/KeepSakeTests.xctest
```

**Results**:
- **Total Test Cases**: 176
- **Failures**: 0
- **Unexpected Failures**: 0
- **Execution Time**: 11.252 seconds
- **Status**: PASSED

### 4.2 Dedicated V7 Test Coverage

| Test Case | Area Tested | Empirical Result |
|---|---|---|
| `testV7_FolderScopedReviewQueues_EmptyFolderHidesForeignSuggestionsAndUnassigned` | Folder Scoping | **PASSED** (0.003s). Verified that an empty folder returns 0 candidate suggestions and 0 unassigned faces even when other folders have data. |
| `testV7_MultiSelectUnassignedFaces_BulkAssignAndCannotLink` | Bulk Assignment & Cannot-Link | **PASSED** (0.004s). Verified multi-face assignment to person, and verified that assigning two faces from the same photo throws `cannotLinkViolation`. |
| `testV7_MultiSelectUnassignedFaces_BulkCreatePerson` | Bulk Person Creation | **PASSED** (0.003s). Verified creating a new central `PersonRecord` from selected unassigned faces. |
| `testV7_CandidateSuggestion_RemoveFaceBeforeConfirmation` | Pre-Confirm Removal | **PASSED** (0.006s). Verified removing an outlier face releases it to unassigned while preserving the remaining candidate group. |
| `testV7_ConfirmedPerson_RemoveFaceAndMoveFace` | Post-Confirm Removal & Move | **PASSED** (0.005s). Verified removing and moving confirmed faces between people with Cannot-Link protection. |
| `testV7_MergeDuplicateConfirmedPeople_AuthoritativeAndCannotLinkEnforced` | Identity Merging | **PASSED** (0.004s). Verified merging source person into target, combining faces, updating centroids, and rejecting merges with co-occurring photos. |

---

## 5. Live File & Database Safety Audit

In accordance with strict project rules:
- **No Git Commits / Pushes**: Zero commits created; zero pushes performed.
- **Live User Database**: `/Users/vikramaditya/Library/Application Support/KeepSake/library_index.json` remains exactly **408,586 bytes** (unmodified).
- **Reference Backup**: `/Users/vikramaditya/Disk/KeepSake-Backups/library_index-before-goal.json` remains exactly **472,584 bytes** (unmodified).
- **App Bundle**: Rebuilt cleanly at `./build/DerivedData/Build/Products/Debug/KeepSake.app`.

---

## 6. Conclusion

Milestone V7 completes the user curation and error-correction loop for KeepSake. Users have full control to inspect, multi-select, bulk-assign, trim outliers, and merge identities, with algorithmic invariants enforcing photographic integrity at every step.
