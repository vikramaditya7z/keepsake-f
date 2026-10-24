import Foundation
import CoreGraphics
import Accelerate

/// Coordinator orchestrating incremental library scanning, reconciliation, face detection, ArcFace embedding, and clustering.
actor LibraryProcessingCoordinator {
    private let libraryStore: LibraryStore
    private let scanner: PhotoScannerService
    private let faceDetector: any FaceDetectionServiceProtocol
    private let preprocessor: FacePreprocessingService
    private let recognitionService: any FaceRecognitionServiceProtocol
    private let clusteringService: any FaceClusteringServiceProtocol
    public let queue: LibraryProcessingQueue

    init(
        libraryStore: LibraryStore,
        scanner: PhotoScannerService = PhotoScannerService(),
        faceDetector: any FaceDetectionServiceProtocol = VisionFaceDetectionService(),
        preprocessor: FacePreprocessingService = FacePreprocessingService(),
        recognitionService: any FaceRecognitionServiceProtocol = ArcFaceRecognitionService(),
        clusteringService: any FaceClusteringServiceProtocol = CosineGraphClusteringService(),
        queue: LibraryProcessingQueue = LibraryProcessingQueue()
    ) {
        self.libraryStore = libraryStore
        self.scanner = scanner
        self.faceDetector = faceDetector
        self.preprocessor = preprocessor
        self.recognitionService = recognitionService
        self.clusteringService = clusteringService
        self.queue = queue
    }

    /// App restart recovery: resets any photos left stuck in `.processing` to `.needsReprocessing`.
    /// Already `.processed` photos are left untouched.
    func recoverInterruptedProcessing() async throws -> Int {
        let stuckPhotos = await libraryStore.getPhotos(byState: .processing)
        for photo in stuckPhotos {
            try await libraryStore.updatePhotoState(
                id: photo.id,
                state: .needsReprocessing,
                failureReason: "Interrupted during previous session"
            )
        }
        return stuckPhotos.count
    }

    /// Processes a single photo item through face detection and ArcFace embedding generation.
    func processSinglePhoto(
        photoRecord: PhotoRecord,
        rootFolderURL: URL
    ) async -> Result<(facesCount: Int, embeddingsCount: Int), Error> {
        let photoURL = rootFolderURL.appendingPathComponent(photoRecord.relativePath)

        do {
            try Task.checkCancellation()
            // In-memory update without full snapshot disk write
            try await libraryStore.updatePhotoState(id: photoRecord.id, state: .processing, persistImmediately: false)

            try Task.checkCancellation()

            // 1. Single decode of the source image respecting EXIF orientation
            let orientedImage = try autoreleasepool {
                try preprocessor.loadOrientedImage(from: photoURL)
            }

            try Task.checkCancellation()

            // 2. Detect faces using the decoded image in memory
            let detectedFaces = try await faceDetector.detectFaces(in: orientedImage)
            let existingExcluded = (await libraryStore.getExcludedFaces()).filter { $0.photoId == photoRecord.id }
            var faceRecords: [FaceRecord] = []
            var embeddingRecords: [EmbeddingRecord] = []

            for detected in detectedFaces {
                try Task.checkCancellation()

                let matchedExcluded = existingExcluded.first(where: {
                    let b1 = $0.boundingBox
                    let b2 = detected.boundingBox
                    return abs(b1.midX - b2.midX) < 0.05 && abs(b1.midY - b2.midY) < 0.05
                })
                let isExcluded = matchedExcluded != nil
                let faceId = matchedExcluded?.id ?? detected.id

                let faceRecord = FaceRecord(
                    id: faceId,
                    photoId: photoRecord.id,
                    boundingBox: detected.boundingBox,
                    confidence: detected.confidence,
                    processingState: .detected,
                    isExcluded: isExcluded,
                    excludedAt: matchedExcluded?.excludedAt,
                    exclusionReason: matchedExcluded?.exclusionReason
                )
                faceRecords.append(faceRecord)

                if isExcluded {
                    continue
                }

                // 3. Crop or align face directly from the already decoded in-memory image
                let crop: CGImage? = autoreleasepool {
                    try? preprocessor.cropOrAlignFace(from: orientedImage, normalizedBox: detected.boundingBox, landmarks: detected.landmarks)
                }

                if let validCrop = crop {
                    try Task.checkCancellation()
                    do {
                        let embedding = try await recognitionService.generateEmbedding(
                            from: validCrop,
                            photoURL: photoURL,
                            faceId: detected.id
                        )

                        let embRecord = EmbeddingRecord(
                            id: embedding.id,
                            faceId: detected.id,
                            photoId: photoRecord.id,
                            vector: embedding.vector,
                            modelName: embedding.modelName,
                            modelVersion: embedding.modelName.contains("Fallback") ? "Synthetic-2D-DCT" : "MobileFaceNet-512D-v1",
                            inferenceTimeMs: embedding.inferenceTimeMs
                        )
                        embeddingRecords.append(embRecord)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        print("Embedding extraction failed for face \(detected.id): \(error.localizedDescription)")
                    }
                }
            }

            try Task.checkCancellation()

            // Save updates to in-memory store without redundant intermediate disk writes
            try await libraryStore.saveFaces(faceRecords, forPhotoId: photoRecord.id, persistImmediately: false)
            try await libraryStore.saveEmbeddings(embeddingRecords, persistImmediately: false)
            try await libraryStore.updatePhotoState(
                id: photoRecord.id,
                state: .processed,
                failureReason: nil,
                detectedFacesCount: faceRecords.count,
                persistImmediately: false
            )

            return .success((facesCount: faceRecords.count, embeddingsCount: embeddingRecords.count))
        } catch is CancellationError {
            // Interrupted/cancelled by folder switch: reset to unindexed/needsProcessing so it's not stuck
            try? await libraryStore.updatePhotoState(
                id: photoRecord.id,
                state: .needsReprocessing,
                failureReason: "Cancelled due to folder switch",
                persistImmediately: false
            )
            return .failure(CancellationError())
        } catch {
            let reason = error.localizedDescription
            try? await libraryStore.updatePhotoState(
                id: photoRecord.id,
                state: .failed,
                failureReason: reason,
                persistImmediately: false
            )
            return .failure(error)
        }
    }

    /// Enqueues unindexed / needs-processing photos into the background queue and runs deferred clustering upon completion.
    func startBackgroundProcessing(
        photos: [PhotoRecord],
        rootFolderURL: URL,
        clusteringThreshold: Float = 0.54,
        onComplete: (@Sendable () async -> Void)? = nil
    ) async {
        await queue.enqueueAndStart(
            items: photos,
            rootFolderURL: rootFolderURL,
            processor: { [weak self] item, rootURL in
                guard let self = self else {
                    return .failure(NSError(domain: "KeepSake", code: -1, userInfo: [NSLocalizedDescriptionKey: "Coordinator deallocated"]))
                }
                return await self.processSinglePhoto(photoRecord: item, rootFolderURL: rootURL)
            },
            onBatchComplete: { [weak self] in
                guard let self = self else { return }
                try? await self.libraryStore.flushPendingSaves()
                try? await self.reclusterLibrary(rootFolderURL: rootFolderURL, threshold: clusteringThreshold)
                try? await self.libraryStore.flushPendingSaves()
                if let onComplete = onComplete {
                    await onComplete()
                }
            }
        )
    }

    /// Dynamically appends photos to the running background queue or starts a new queue run.
    func enqueueBackgroundPhotos(
        photos: [PhotoRecord],
        rootFolderURL: URL,
        clusteringThreshold: Float = 0.54,
        onComplete: (@Sendable () async -> Void)? = nil
    ) async {
        await queue.enqueueAdditional(
            items: photos,
            rootFolderURL: rootFolderURL,
            processor: { [weak self] item, rootURL in
                guard let self = self else {
                    return .failure(NSError(domain: "KeepSake", code: -1, userInfo: [NSLocalizedDescriptionKey: "Coordinator deallocated"]))
                }
                return await self.processSinglePhoto(photoRecord: item, rootFolderURL: rootURL)
            },
            onBatchComplete: { [weak self] in
                guard let self = self else { return }
                try? await self.libraryStore.flushPendingSaves()
                try? await self.reclusterLibrary(rootFolderURL: rootFolderURL, threshold: clusteringThreshold)
                try? await self.libraryStore.flushPendingSaves()
                if let onComplete = onComplete {
                    await onComplete()
                }
            }
        )
    }

    /// Synchronous/direct scan and process convenience method (used by tests and manual runs).
    func scanAndProcess(
        folderURL: URL,
        clusteringThreshold: Float = 0.54,
        progressHandler: (@Sendable (String, Double) -> Void)? = nil
    ) async throws -> LibraryReconciliationResult {
        progressHandler?("Scanning filesystem for photos…", 0.0)

        // 1. Scan photos from disk
        var scannedPhotos: [PhotoItem] = []
        for try await batch in scanner.scanStream(at: folderURL) {
            scannedPhotos.append(contentsOf: batch)
        }

        // 2. Reconcile with persistent library index
        progressHandler?("Reconciling library index…", 0.1)
        let reconciliation = try await libraryStore.reconcile(
            scannedPhotos: scannedPhotos,
            rootFolderURL: folderURL
        )

        let photosToProcess = reconciliation.newPhotos + reconciliation.changedPhotos
        let totalCount = photosToProcess.count

        guard totalCount > 0 else {
            progressHandler?("All photos up to date.", 1.0)
            return reconciliation
        }

        // 3. Process new and changed photos incrementally
        for (index, photoRecord) in photosToProcess.enumerated() {
            let fraction = 0.1 + (Double(index) / Double(totalCount)) * 0.8
            progressHandler?("Processing \(index + 1)/\(totalCount): \(photoRecord.filename)", fraction)

            _ = await processSinglePhoto(photoRecord: photoRecord, rootFolderURL: folderURL)
        }

        // 4. Update face groups across active embeddings
        progressHandler?("Clustering face groups…", 0.95)
        try await reclusterLibrary(rootFolderURL: folderURL, threshold: clusteringThreshold)
        try await libraryStore.flushPendingSaves()

        progressHandler?("Library processing complete.", 1.0)
        return reconciliation
    }

    /// Re-clusters all stored embeddings in the library with the specified threshold using PersonIdentityProfiles.
    func reclusterLibrary(rootFolderURL: URL, threshold: Float, enableDiagnostics: Bool = false) async throws {
        let activeRootPath = rootFolderURL.standardizedFileURL.path
        let allPhotos = await libraryStore.getAllPhotos()
        let validPhotoIdSet = Set(allPhotos.map(\.id))
        let photoById = Dictionary(uniqueKeysWithValues: allPhotos.map { ($0.id, $0) })

        let existingGroups = await libraryStore.getGroups()
        let activePeople = await libraryStore.getActivePeople()
        let excludedFaces = await libraryStore.getExcludedFaces()
        let excludedFaceIdSet = Set(excludedFaces.map(\.id))

        // 1. Filter photos belonging to THIS active root folder
        let activePhotos = allPhotos.filter { photo in
            if let pRoot = photo.rootFolderPath {
                return URL(fileURLWithPath: pRoot).standardizedFileURL.path == activeRootPath
            } else {
                let hasOtherFolders = allPhotos.contains { p in
                    if let oRoot = p.rootFolderPath {
                        return URL(fileURLWithPath: oRoot).standardizedFileURL.path != activeRootPath
                    }
                    return false
                }
                return !hasOtherFolders
            }
        }
        let activePhotoIdSet = Set(activePhotos.map(\.id))

        // If active folder has zero photos, prune candidate groups for this folder and preserve others
        guard !activePhotoIdSet.isEmpty else {
            let otherFolderGroups = existingGroups.filter { g in
                if let gRoot = g.rootFolderPath {
                    return URL(fileURLWithPath: gRoot).standardizedFileURL.path != activeRootPath
                }
                return true
            }
            try await libraryStore.saveGroups(otherFolderGroups)
            return
        }

        let removedAssociationFaceIds = Set((await libraryStore.getRemovedAssociations()).map(\.faceId))

        // 2. Filter active faces in this folder (excluding false detections and removed associations)
        let allFaces = (await libraryStore.getAllFaces()).filter {
            validPhotoIdSet.contains($0.photoId) &&
            !excludedFaceIdSet.contains($0.id) &&
            !removedAssociationFaceIds.contains($0.id) &&
            !$0.isExcluded
        }
        let activeFolderFaces = allFaces.filter { activePhotoIdSet.contains($0.photoId) }
        let activeFaceIdSet = Set(activeFolderFaces.map(\.id))
        let faceToPhotoId = Dictionary(uniqueKeysWithValues: allFaces.map { ($0.id, $0.photoId) })

        // 3. Filter active embeddings in this folder
        let rawFolderEmbeddings = (await libraryStore.getEmbeddings()).filter {
            activeFaceIdSet.contains($0.faceId) &&
            !excludedFaceIdSet.contains($0.faceId) &&
            !removedAssociationFaceIds.contains($0.faceId) &&
            activePhotoIdSet.contains($0.photoId)
        }
        // Incompatible model safety: filter to compatible 512-D vectors
        let allEmbeddings = rawFolderEmbeddings.filter { $0.dimension == 512 }
        guard !allEmbeddings.isEmpty else {
            let otherFolderGroups = existingGroups.filter { g in
                if let gRoot = g.rootFolderPath {
                    return URL(fileURLWithPath: gRoot).standardizedFileURL.path != activeRootPath
                }
                return true
            }
            try await libraryStore.saveGroups(otherFolderGroups)
            return
        }

        let faceLookup = Dictionary(uniqueKeysWithValues: activeFolderFaces.map { ($0.id, DetectedFace(id: $0.id, boundingBox: $0.boundingBox, confidence: $0.confidence)) })
        let embeddingByFaceId = Dictionary(uniqueKeysWithValues: allEmbeddings.map { ($0.faceId, $0) })

        // Convert EmbeddingRecords to domain FaceEmbedding objects with accurate photo URLs
        let domainEmbeddings = allEmbeddings.map { emb in
            let relPath = photoById[emb.photoId]?.relativePath ?? emb.photoId.uuidString
            return FaceEmbedding(
                id: emb.id,
                photoURL: rootFolderURL.appendingPathComponent(relPath),
                faceId: emb.faceId,
                vector: emb.vector,
                modelName: emb.modelName,
                inferenceTimeMs: emb.inferenceTimeMs,
                createdAt: emb.createdAt
            )
        }

        print("[DIAGNOSTIC] === RECLUSTER START ===")
        print("[DIAGNOSTIC] Step 1: Loaded \(existingGroups.count) existing GroupRecords and \(activePeople.count) active PersonRecords from LibraryStore.")

        // 1. Build Established PersonIdentityProfiles from:
        //    a) Central PersonRecords (authoritative persistent identity memory)
        //    b) Existing GroupRecords with user curation or confirmed status
        var establishedProfiles: [PersonIdentityProfile] = []
        var seenProfileIds = Set<UUID>()

        for person in activePeople {
            guard let centroid = person.centroid else { continue }
            let activeMembers = person.confirmedFaceIds.filter { activeFaceIdSet.contains($0) }
            let anchors = person.identityAnchors.isEmpty ? [centroid] : person.identityAnchors

            let profile = PersonIdentityProfile(
                id: person.id,
                groupIndex: establishedProfiles.count + 1,
                customName: person.name,
                representativeFaceId: person.representativeFaceId,
                memberFaceIds: Set(activeMembers),
                centroid: centroid,
                identityAnchors: anchors,
                isManuallyConfirmed: true
            )
            establishedProfiles.append(profile)
            seenProfileIds.insert(person.id)
        }

        for g in existingGroups {
            guard !seenProfileIds.contains(g.id) else { continue }
            let activeMembers = g.memberFaceIds.filter { activeFaceIdSet.contains($0) }
            guard !activeMembers.isEmpty else { continue }

            let isUserCurated = (g.customName != nil && !g.customName!.isEmpty) ||
                                g.reviewStatus == .confirmed ||
                                g.algorithmVersion.contains("manual")
            guard isUserCurated else { continue }

            let memberVectors = activeMembers.compactMap { embeddingByFaceId[$0]?.vector }
            guard !memberVectors.isEmpty else { continue }
            let dim = memberVectors[0].count

            var groupCentroid = g.centroid
            if groupCentroid == nil {
                var accum = [Float](repeating: 0.0, count: dim)
                for v in memberVectors {
                    vDSP_vadd(accum, 1, v, 1, &accum, 1, vDSP_Length(dim))
                }
                groupCentroid = EmbeddingSimilarityUtility.l2Normalize(accum)
            }
            guard let finalCentroid = groupCentroid else { continue }

            let anchors = (g.identityAnchors.isEmpty)
                ? EmbeddingSimilarityUtility.selectDiverseAnchors(from: memberVectors, centroid: finalCentroid, maxAnchors: 4)
                : g.identityAnchors

            let profile = PersonIdentityProfile(
                id: g.id,
                groupIndex: g.groupIndex,
                customName: g.customName,
                representativeFaceId: g.representativeFaceId,
                memberFaceIds: Set(activeMembers),
                centroid: finalCentroid,
                identityAnchors: anchors,
                isManuallyConfirmed: true
            )
            establishedProfiles.append(profile)
            seenProfileIds.insert(g.id)
        }
        print("[DIAGNOSTIC] Step 2: Constructed \(establishedProfiles.count) user-curated and persistent PersonIdentityProfiles.")

        // 2. Discover / Cluster all active domain embeddings using graph-based coherent clustering
        let clusteringResult = try await clusteringService.cluster(
            embeddings: domainEmbeddings,
            threshold: threshold,
            faceLookup: faceLookup
        )
        print("[DIAGNOSTIC] Step 3: Discovery Clustering produced \(clusteringResult.groups.count) candidate clusters from \(domainEmbeddings.count) active embeddings.")

        // 3. Stage 1: Match Discovered Clusters & Faces against Established User Profiles (Multi-Anchor Matching)
        var assignedFaceIds = Set<UUID>()
        var usedGroupIds = Set<UUID>()
        var profileAccumulators: [UUID: (profile: PersonIdentityProfile, memberFaceIds: [UUID])] = [:]

        for profile in establishedProfiles {
            let initialMembers = Array(profile.memberFaceIds).filter { assignedFaceIds.insert($0).inserted }
            profileAccumulators[profile.id] = (profile, initialMembers)
            usedGroupIds.insert(profile.id)
        }

        // Cross-Profile Reconciliation: Merge existing profiles if their embeddings meet the similarity threshold
        var accumulatorList = Array(profileAccumulators.values)
        var accumChanged = true
        while accumChanged && accumulatorList.count > 1 {
            accumChanged = false
            var mergePair: (Int, Int)? = nil
            var highestScore: Float = -1.0

            for i in 0..<accumulatorList.count {
                for j in (i + 1)..<accumulatorList.count {
                    let pA = accumulatorList[i].profile
                    let pB = accumulatorList[j].profile

                    // User intent safeguard: never automatically merge two distinct custom-named people
                    if pA.customName != nil && pB.customName != nil && pA.customName != pB.customName {
                        continue
                    }

                    // Cannot-Link constraint: profiles containing faces from the same photo cannot merge
                    let photosA = Set(accumulatorList[i].memberFaceIds.compactMap { faceToPhotoId[$0] })
                    let photosB = Set(accumulatorList[j].memberFaceIds.compactMap { faceToPhotoId[$0] })
                    if !photosA.isDisjoint(with: photosB) {
                        continue
                    }

                    let centroidSim = EmbeddingSimilarityUtility.cosineSimilarity(pA.centroid, pB.centroid)
                    var maxAnchorSim: Float = -2.0
                    for aA in pA.identityAnchors {
                        for aB in pB.identityAnchors {
                            let s = EmbeddingSimilarityUtility.cosineSimilarity(aA, aB)
                            if s > maxAnchorSim { maxAnchorSim = s }
                        }
                    }

                    let mCentroid = centroidSim >= threshold
                    let mAnchor = maxAnchorSim >= threshold && centroidSim >= 0.50
                    if mCentroid || mAnchor {
                        let score = max(centroidSim, maxAnchorSim)
                        if score > highestScore {
                            highestScore = score
                            mergePair = (i, j)
                        }
                    }
                }
            }

            if let (i, j) = mergePair {
                var target = accumulatorList[i]
                let source = accumulatorList[j]

                let targetHasName = target.profile.customName != nil
                let sourceHasName = source.profile.customName != nil
                if !targetHasName && sourceHasName {
                    target = accumulatorList[j]
                    let tempSource = accumulatorList[i]
                    target.memberFaceIds.append(contentsOf: tempSource.memberFaceIds)
                    accumulatorList[i] = target
                    accumulatorList.remove(at: j)
                } else {
                    target.memberFaceIds.append(contentsOf: source.memberFaceIds)
                    accumulatorList[i] = target
                    accumulatorList.remove(at: j)
                }
                accumChanged = true
            }
        }

        profileAccumulators = [:]
        for accum in accumulatorList {
            profileAccumulators[accum.profile.id] = accum
        }

        print("[DIAGNOSTIC] Step 4: Initialized Stage 1 profileAccumulators with \(profileAccumulators.count) reconciled profiles, pre-assigning \(assignedFaceIds.count) member face IDs.")

        // Fix 2: Evaluate discovered clusters and individual faces against ALL established profiles
        for (grpIdx, group) in clusteringResult.groups.enumerated() {
            let unassignedFaces = group.members.map(\.faceId).filter { !assignedFaceIds.contains($0) }
            if unassignedFaces.isEmpty {
                continue
            }

            let groupVectors = unassignedFaces.compactMap { embeddingByFaceId[$0]?.vector }
            guard !groupVectors.isEmpty else { continue }

            var bestMatchedProfileId: UUID? = nil
            var highestMatchScore: Float = -1.0
            var matchReason: String = "No match"

            // 1. Cluster-level matching against existing profiles
            for (profileId, accum) in profileAccumulators {
                let prof = accum.profile

                // Cannot-link check: profile cannot contain multiple faces from the same photo
                let profPhotos = Set(accum.memberFaceIds.compactMap { faceToPhotoId[$0] })
                let groupPhotos = Set(unassignedFaces.compactMap { faceToPhotoId[$0] })
                if !profPhotos.isDisjoint(with: groupPhotos) {
                    continue
                }

                let centroidSim = EmbeddingSimilarityUtility.cosineSimilarity(group.centroid, prof.centroid)

                var maxAnchorSim: Float = -2.0
                for anchor in prof.identityAnchors {
                    for gVec in groupVectors {
                        let sim = EmbeddingSimilarityUtility.cosineSimilarity(gVec, anchor)
                        if sim > maxAnchorSim {
                            maxAnchorSim = sim
                        }
                    }
                }

                let attachmentThreshold = max(0.48, threshold - 0.06)
                let matchesCentroid = centroidSim >= threshold
                let matchesAnchorWithCoherence = maxAnchorSim >= threshold && centroidSim >= 0.48
                let matchesMultiEvidence = centroidSim >= attachmentThreshold && maxAnchorSim >= attachmentThreshold

                if matchesCentroid || matchesAnchorWithCoherence || matchesMultiEvidence {
                    let score = max(centroidSim, maxAnchorSim)
                    if score > highestMatchScore {
                        highestMatchScore = score
                        bestMatchedProfileId = profileId
                        matchReason = matchesCentroid ? "Centroid similarity \(centroidSim) >= \(threshold)" : (matchesAnchorWithCoherence ? "Anchor similarity \(maxAnchorSim) >= \(threshold) (centroidSim \(centroidSim) >= 0.48)" : "Multi-evidence match (centSim: \(centroidSim), aSim: \(maxAnchorSim) >= \(attachmentThreshold))")
                    }
                }
            }

            if let matchedId = bestMatchedProfileId {
                for fId in unassignedFaces {
                    if assignedFaceIds.insert(fId).inserted {
                        profileAccumulators[matchedId]?.memberFaceIds.append(fId)
                        let profName = profileAccumulators[matchedId]?.profile.customName ?? "Person \(profileAccumulators[matchedId]?.profile.groupIndex ?? 0)"
                        print("[DIAGNOSTIC] New face \(fId) -> matched: \(profName) (ID: \(matchedId)) -> Target GroupRecord ID: \(matchedId) -> Stage 3: updated existing (cluster-match: \(matchReason))")
                    }
                }
            } else {
                // 2. Individual face-level matching for faces in non-monolith/mixed candidate clusters
                let attachmentThreshold = max(0.48, threshold - 0.06)
                for fId in unassignedFaces {
                    guard !assignedFaceIds.contains(fId), let fVec = embeddingByFaceId[fId]?.vector else { continue }
                    var faceBestProfileId: UUID? = nil
                    var faceHighestScore: Float = -1.0
                    var faceMatchReason: String = ""

                    for (profileId, accum) in profileAccumulators {
                        let prof = accum.profile

                        // Cannot-link check: profile cannot contain multiple faces from the same photo
                        if let photoId = faceToPhotoId[fId] {
                            let profPhotos = Set(accum.memberFaceIds.compactMap { faceToPhotoId[$0] })
                            if profPhotos.contains(photoId) {
                                continue
                            }
                        }

                        let cSim = EmbeddingSimilarityUtility.cosineSimilarity(fVec, prof.centroid)
                        var maxASim: Float = -2.0
                        for anchor in prof.identityAnchors {
                            let s = EmbeddingSimilarityUtility.cosineSimilarity(fVec, anchor)
                            if s > maxASim { maxASim = s }
                        }

                        let mCentroid = cSim >= threshold
                        let mAnchor = maxASim >= threshold && cSim >= 0.48
                        let mMultiEvidence = cSim >= attachmentThreshold && maxASim >= attachmentThreshold
                        if mCentroid || mAnchor || mMultiEvidence {
                            let score = max(cSim, maxASim)
                            if score > faceHighestScore {
                                faceHighestScore = score
                                faceBestProfileId = profileId
                                faceMatchReason = mCentroid ? "Face centroid similarity \(cSim) >= \(threshold)" : (mAnchor ? "Face anchor similarity \(maxASim) >= \(threshold)" : "Multi-evidence match (cSim: \(cSim), aSim: \(maxASim) >= \(attachmentThreshold))")
                            }
                        }
                    }

                    if let matchedId = faceBestProfileId {
                        if assignedFaceIds.insert(fId).inserted {
                            profileAccumulators[matchedId]?.memberFaceIds.append(fId)
                            let profName = profileAccumulators[matchedId]?.profile.customName ?? "Person \(profileAccumulators[matchedId]?.profile.groupIndex ?? 0)"
                            print("[DIAGNOSTIC] New face \(fId) -> matched: \(profName) (ID: \(matchedId)) -> Target GroupRecord ID: \(matchedId) -> Stage 3: updated existing (\(faceMatchReason))")
                        }
                    }
                }
            }
        }

        // Pass B: Stage 2 — Cross-Discovered-Group Reconciliation
        let rejectedGroups = existingGroups.filter { $0.reviewStatus == .rejected }
        let rejectedFaceIdSets = rejectedGroups.map { Set($0.memberFaceIds) }

        struct CandidateCluster {
            var faceIds: [UUID]
            var photoIds: Set<UUID>
            var vectors: [[Float]]
            var centroid: [Float]
            var anchors: [[Float]]
            var stableGroupId: UUID?
            var inheritedName: String?
            var isRejected: Bool
        }

        var candidateClusters: [CandidateCluster] = []

        for group in clusteringResult.groups {
            let unassignedFaces = group.members.map(\.faceId).filter { !assignedFaceIds.contains($0) }
            guard !unassignedFaces.isEmpty else { continue }

            let groupVectors = unassignedFaces.compactMap { embeddingByFaceId[$0]?.vector }
            guard !groupVectors.isEmpty else { continue }

            var stableGroupId: UUID? = nil
            var inheritedName: String? = nil
            var isRejected: Bool = false

            for fId in unassignedFaces {
                if let prevGroup = existingGroups.first(where: { $0.memberFaceIds.contains(fId) && !usedGroupIds.contains($0.id) }) {
                    if stableGroupId == nil {
                        stableGroupId = prevGroup.id
                    }
                    if inheritedName == nil {
                        inheritedName = prevGroup.customName
                    }
                    if prevGroup.reviewStatus == .rejected {
                        isRejected = true
                    }
                }
            }

            if rejectedFaceIdSets.contains(where: { $0 == Set(unassignedFaces) }) {
                isRejected = true
            }

            let clusterCentroid = group.centroid
            let clusterAnchors = EmbeddingSimilarityUtility.selectDiverseAnchors(
                from: groupVectors,
                centroid: clusterCentroid,
                maxAnchors: 4
            )

            let candPhotoIds = Set(unassignedFaces.compactMap { faceToPhotoId[$0] })
            candidateClusters.append(CandidateCluster(
                faceIds: unassignedFaces,
                photoIds: candPhotoIds,
                vectors: groupVectors,
                centroid: clusterCentroid,
                anchors: clusterAnchors,
                stableGroupId: stableGroupId,
                inheritedName: inheritedName,
                isRejected: isRejected
            ))
        }

        // Fix 2B: Candidate-to-Profile Cross-Reconciliation
        var remainingCandidates: [CandidateCluster] = []
        for var candidate in candidateClusters {
            candidate.faceIds = candidate.faceIds.filter { !assignedFaceIds.contains($0) }
            guard !candidate.faceIds.isEmpty else { continue }
            candidate.vectors = candidate.faceIds.compactMap { embeddingByFaceId[$0]?.vector }
            guard !candidate.vectors.isEmpty else { continue }

            var matchedProfileId: UUID? = nil
            var bestScore: Float = -1.0
            for (profileId, accum) in profileAccumulators {
                let prof = accum.profile

                // Cannot-link check: candidate cluster cannot merge into profile if they share any photo
                let profPhotos = Set(accum.memberFaceIds.compactMap { faceToPhotoId[$0] })
                let candPhotos = candidate.photoIds
                if !profPhotos.isDisjoint(with: candPhotos) {
                    continue
                }

                let centroidSim = EmbeddingSimilarityUtility.cosineSimilarity(candidate.centroid, prof.centroid)
                var maxAnchorSim: Float = -2.0
                for anchor in prof.identityAnchors {
                    for cVec in candidate.vectors {
                        let s = EmbeddingSimilarityUtility.cosineSimilarity(cVec, anchor)
                        if s > maxAnchorSim { maxAnchorSim = s }
                    }
                }
                let attachmentThreshold = max(0.48, threshold - 0.06)
                let matchesCentroid = centroidSim >= threshold
                let matchesAnchor = maxAnchorSim >= threshold && centroidSim >= 0.48
                let matchesMultiEvidence = centroidSim >= attachmentThreshold && maxAnchorSim >= attachmentThreshold
                if matchesCentroid || matchesAnchor || matchesMultiEvidence {
                    let score = max(centroidSim, maxAnchorSim)
                    if score > bestScore {
                        bestScore = score
                        matchedProfileId = profileId
                    }
                }
            }

            if let pId = matchedProfileId {
                for fId in candidate.faceIds {
                    if assignedFaceIds.insert(fId).inserted {
                        profileAccumulators[pId]?.memberFaceIds.append(fId)
                        let profName = profileAccumulators[pId]?.profile.customName ?? "Person \(profileAccumulators[pId]?.profile.groupIndex ?? 0)"
                        print("[DIAGNOSTIC] New face \(fId) -> matched: \(profName) (ID: \(pId)) -> Target GroupRecord ID: \(pId) -> Stage 3: updated existing (Stage 2 profile reconciliation)")
                    }
                }
            } else {
                remainingCandidates.append(candidate)
            }
        }
        candidateClusters = remainingCandidates

        print("[DIAGNOSTIC] Step 5: Formed \(candidateClusters.count) initial candidate clusters for Stage 2.")

        // Iterative agglomeration across candidate clusters
        var changed = true
        var agglomerationPass = 0
        while changed && candidateClusters.count > 1 {
            changed = false
            agglomerationPass += 1
            var bestPair: (Int, Int)? = nil
            var highestSim: Float = -1.0

            for i in 0..<candidateClusters.count {
                for j in (i + 1)..<candidateClusters.count {
                    let cA = candidateClusters[i]
                    let cB = candidateClusters[j]

                    // Cannot-link check: candidate clusters sharing a photo cannot merge
                    if !cA.photoIds.isDisjoint(with: cB.photoIds) {
                        continue
                    }

                    let centroidSim = EmbeddingSimilarityUtility.cosineSimilarity(cA.centroid, cB.centroid)

                    var maxCrossAnchorSim: Float = -2.0
                    for aA in cA.anchors {
                        for aB in cB.anchors {
                            let sim = EmbeddingSimilarityUtility.cosineSimilarity(aA, aB)
                            if sim > maxCrossAnchorSim {
                                maxCrossAnchorSim = sim
                            }
                        }
                    }

                    let nearThreshold = max(0.50, threshold - 0.04)
                    let attachmentThreshold = max(0.48, threshold - 0.06)
                    let matchesCentroid = centroidSim >= threshold
                    let matchesAnchorWithCoherence = maxCrossAnchorSim >= threshold && centroidSim >= 0.48
                    let matchesNearThreshold = (centroidSim >= nearThreshold || maxCrossAnchorSim >= nearThreshold) && centroidSim >= 0.48
                    let matchesMultiEvidence = (cA.faceIds.count >= 2 || cB.faceIds.count >= 2) && centroidSim >= attachmentThreshold && maxCrossAnchorSim >= attachmentThreshold

                    if matchesCentroid || matchesAnchorWithCoherence || matchesNearThreshold || matchesMultiEvidence {
                        // Transitive drift guard for small clusters (<= 3 faces)
                        if cA.faceIds.count + cB.faceIds.count <= 3 {
                            var minCrossSim: Float = 1.0
                            for vA in cA.vectors {
                                for vB in cB.vectors {
                                    let s = EmbeddingSimilarityUtility.cosineSimilarity(vA, vB)
                                    if s < minCrossSim { minCrossSim = s }
                                }
                            }
                            if minCrossSim < 0.48 {
                                continue
                            }
                        } else {
                            var minCrossSim: Float = 1.0
                            for vA in cA.vectors {
                                for vB in cB.vectors {
                                    let s = EmbeddingSimilarityUtility.cosineSimilarity(vA, vB)
                                    if s < minCrossSim { minCrossSim = s }
                                }
                            }
                            if minCrossSim < 0.35 {
                                continue
                            }
                        }

                        let score = max(centroidSim, maxCrossAnchorSim)
                        if score > highestSim {
                            highestSim = score
                            bestPair = (i, j)
                        }
                    }
                }
            }

            if let (i, j) = bestPair {
                var cA = candidateClusters[i]
                let cB = candidateClusters[j]
                print("[DIAGNOSTIC] Stage 2 Agglomeration: Merging candidate cluster \(i) (\(cA.faceIds.count) faces) and candidate cluster \(j) (\(cB.faceIds.count) faces). Score=\(highestSim)")

                cA.faceIds.append(contentsOf: cB.faceIds)
                cA.photoIds.formUnion(cB.photoIds)
                cA.vectors.append(contentsOf: cB.vectors)

                // Recompute centroid
                let dim = cA.vectors[0].count
                var accum = [Float](repeating: 0.0, count: dim)
                for v in cA.vectors {
                    vDSP_vadd(accum, 1, v, 1, &accum, 1, vDSP_Length(dim))
                }
                cA.centroid = EmbeddingSimilarityUtility.l2Normalize(accum)

                // Recompute diverse anchors
                cA.anchors = EmbeddingSimilarityUtility.selectDiverseAnchors(
                    from: cA.vectors,
                    centroid: cA.centroid,
                    maxAnchors: 4
                )

                if cA.stableGroupId == nil {
                    cA.stableGroupId = cB.stableGroupId
                }
                if cA.inheritedName == nil {
                    cA.inheritedName = cB.inheritedName
                }
                cA.isRejected = cA.isRejected || cB.isRejected

                candidateClusters[i] = cA
                candidateClusters.remove(at: j)
                changed = true
            }
        }
        print("[DIAGNOSTIC] Step 6: Stage 2 completed with \(candidateClusters.count) reconciled candidate clusters.")

        // Stage 3: Final GroupRecord Synthesis & Serialization
        var groupRecords: [GroupRecord] = []

        // 3A: Build groups from profile accumulators (sorted deterministically)
        let sortedAccumulators = profileAccumulators.values.sorted { (a, b) -> Bool in
            if a.profile.groupIndex != b.profile.groupIndex {
                return a.profile.groupIndex < b.profile.groupIndex
            }
            return a.profile.id.uuidString < b.profile.id.uuidString
        }

        for accum in sortedAccumulators {
            let memberFaceIds = accum.memberFaceIds
            guard !memberFaceIds.isEmpty else { continue }

            let prof = accum.profile
            usedGroupIds.insert(prof.id)
            for fId in memberFaceIds {
                assignedFaceIds.insert(fId)
            }

            let memberVectors = memberFaceIds.compactMap { embeddingByFaceId[$0]?.vector }
            var finalCentroid = prof.centroid
            if !memberVectors.isEmpty {
                let dim = memberVectors[0].count
                var accumV = [Float](repeating: 0.0, count: dim)
                for v in memberVectors {
                    vDSP_vadd(accumV, 1, v, 1, &accumV, 1, vDSP_Length(dim))
                }
                finalCentroid = EmbeddingSimilarityUtility.l2Normalize(accumV)
            }

            let finalAnchors = EmbeddingSimilarityUtility.selectDiverseAnchors(
                from: memberVectors,
                centroid: finalCentroid,
                maxAnchors: 4
            )

            // Representative face: closest to centroid
            var repFaceId = prof.representativeFaceId
            if repFaceId == nil || !memberFaceIds.contains(repFaceId!) {
                var bestSim: Float = -2.0
                for fId in memberFaceIds {
                    if let vec = embeddingByFaceId[fId]?.vector {
                        let sim = EmbeddingSimilarityUtility.cosineSimilarity(vec, finalCentroid)
                        if sim > bestSim {
                            bestSim = sim
                            repFaceId = fId
                        }
                    }
                }
            }

            // Intra-cluster stats
            var avgSim: Float = 1.0
            var minSim: Float = 1.0
            if memberVectors.count > 1 {
                var totalSim: Float = 0
                var count = 0
                var mSim: Float = 1.0
                for i in 0..<memberVectors.count {
                    for j in (i + 1)..<memberVectors.count {
                        let s = EmbeddingSimilarityUtility.cosineSimilarity(memberVectors[i], memberVectors[j])
                        totalSim += s
                        count += 1
                        if s < mSim { mSim = s }
                    }
                }
                avgSim = count > 0 ? totalSim / Float(count) : 1.0
                minSim = mSim
            }

            let record = GroupRecord(
                id: prof.id,
                groupIndex: groupRecords.count + 1,
                customName: prof.customName,
                representativeFaceId: repFaceId ?? memberFaceIds.first,
                memberFaceIds: memberFaceIds,
                centroid: finalCentroid,
                identityAnchors: finalAnchors,
                averageSimilarity: avgSim,
                minSimilarity: minSim,
                thresholdUsed: threshold,
                algorithmName: clusteringService.algorithmName,
                algorithmVersion: "v2",
                reviewStatus: .confirmed
            )
            groupRecords.append(record)
            print("[DIAGNOSTIC] Stage 3A: Preserved/Updated GroupRecord ID \(record.id) (\(record.displayName)) with \(record.memberFaceIds.count) faces (Status: \(record.reviewStatus)).")
        }

        // 3B: Build groups from reconciled candidate clusters (Fix 3: strictly verify unassigned faces)
        for candidate in candidateClusters {
            let unassignedFaces = candidate.faceIds.filter { assignedFaceIds.insert($0).inserted }
            guard !unassignedFaces.isEmpty else { continue }

            let finalGroupId: UUID
            if let sgId = candidate.stableGroupId, !usedGroupIds.contains(sgId) {
                finalGroupId = sgId
            } else {
                finalGroupId = UUID()
            }
            usedGroupIds.insert(finalGroupId)

            let candidateVectors = unassignedFaces.compactMap { embeddingByFaceId[$0]?.vector }

            var repFaceId = unassignedFaces.first
            var bestSim: Float = -2.0
            for fId in unassignedFaces {
                if let vec = embeddingByFaceId[fId]?.vector {
                    let sim = EmbeddingSimilarityUtility.cosineSimilarity(vec, candidate.centroid)
                    if sim > bestSim {
                        bestSim = sim
                        repFaceId = fId
                    }
                }
            }

            var avgSim: Float = 1.0
            var minSim: Float = 1.0
            if candidateVectors.count > 1 {
                var totalSim: Float = 0
                var count = 0
                var mSim: Float = 1.0
                for i in 0..<candidateVectors.count {
                    for j in (i + 1)..<candidateVectors.count {
                        let s = EmbeddingSimilarityUtility.cosineSimilarity(candidateVectors[i], candidateVectors[j])
                        totalSim += s
                        count += 1
                        if s < mSim { mSim = s }
                    }
                }
                avgSim = count > 0 ? totalSim / Float(count) : 1.0
                minSim = mSim
            }

            let isInheritedConfirmed = candidate.inheritedName != nil && !candidate.inheritedName!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let candidateReviewStatus: IdentityReviewStatus = isInheritedConfirmed ? .confirmed : (candidate.isRejected ? .rejected : .candidateSuggestion)

            let record = GroupRecord(
                id: finalGroupId,
                groupIndex: groupRecords.count + 1,
                customName: candidate.inheritedName,
                representativeFaceId: repFaceId,
                memberFaceIds: unassignedFaces,
                centroid: candidate.centroid,
                identityAnchors: candidate.anchors,
                averageSimilarity: avgSim,
                minSimilarity: minSim,
                thresholdUsed: threshold,
                algorithmName: clusteringService.algorithmName,
                algorithmVersion: "v2",
                reviewStatus: candidateReviewStatus,
                rootFolderPath: rootFolderURL.standardizedFileURL.path
            )
            groupRecords.append(record)
            for fId in unassignedFaces {
                print("[DIAGNOSTIC] New face \(fId) -> candidate cluster -> Target GroupRecord ID: \(finalGroupId) -> Stage 3: created new GroupRecord (\(record.displayName), Status: \(record.reviewStatus))")
            }
        }

        // Deterministically sort and re-index groupIndex consecutively
        groupRecords.sort { (a, b) -> Bool in
            if (a.customName != nil) != (b.customName != nil) {
                return a.customName != nil
            }
            if a.memberFaceIds.count != b.memberFaceIds.count {
                return a.memberFaceIds.count > b.memberFaceIds.count
            }
            return a.id.uuidString < b.id.uuidString
        }

        // Preserve groups from other folders whose member faces or rootFolderPath are not in the currently active folder
        let otherFolderGroups = existingGroups.filter { g in
            if let gRoot = g.rootFolderPath {
                return gRoot != activeRootPath
            }
            return g.memberFaceIds.allSatisfy { !activeFaceIdSet.contains($0) }
        }

        // Also preserve existing rejected groups from active folder whose faces were not re-assigned to confirmed profiles
        let existingRejectedPreserved = existingGroups.compactMap { g -> GroupRecord? in
            guard g.reviewStatus == .rejected && !usedGroupIds.contains(g.id) else { return nil }
            let remainingFaces = g.memberFaceIds.filter { activeFaceIdSet.contains($0) && !assignedFaceIds.contains($0) }
            guard !remainingFaces.isEmpty else { return nil }
            var updated = g
            updated.memberFaceIds = remainingFaces
            return updated
        }

        var allGroupsToSave = groupRecords + otherFolderGroups + existingRejectedPreserved

        for i in 0..<allGroupsToSave.count {
            allGroupsToSave[i].groupIndex = i + 1
        }

        try await libraryStore.saveGroups(allGroupsToSave)
        print("[DIAGNOSTIC] Step 7: Saved \(allGroupsToSave.count) final GroupRecords (\(groupRecords.count) active, \(otherFolderGroups.count) preserved from other folders) to LibraryStore.")

        // Sync matched faces and updated centroids/anchors back to central PersonRecords
        for record in groupRecords {
            if var person = await libraryStore.getPerson(byId: record.id) {
                var updatedFaces = Set(person.confirmedFaceIds)
                for fId in record.memberFaceIds {
                    updatedFaces.insert(fId)
                }
                person.confirmedFaceIds = Array(updatedFaces)
                if person.representativeFaceId == nil {
                    person.representativeFaceId = record.representativeFaceId
                }
                if let newCentroid = record.centroid {
                    person.centroidData = record.centroidData
                    person.identityAnchorsData = record.identityAnchorsData
                }
                person.updatedAt = Date()
                try? await libraryStore.savePerson(person)
            }
        }

        if enableDiagnostics {
            await logClusteringDiagnostics(
                embeddings: domainEmbeddings,
                groupRecords: groupRecords,
                allFaces: allFaces,
                threshold: threshold
            )
        }
    }

    /// Clean identity rebuild: re-clusters all valid active embeddings from scratch,
    /// preserving custom names, manual merges, and representative thumbnails while replacing stale unconfirmed groups.
    func rebuildAllIdentities(rootFolderURL: URL, threshold: Float = 0.54) async throws {
        try await reclusterLibrary(rootFolderURL: rootFolderURL, threshold: threshold, enableDiagnostics: true)
    }

    /// Logs diagnostic analysis of all face embeddings, pairwise similarities, and group assignments.
    private func logClusteringDiagnostics(
        embeddings: [FaceEmbedding],
        groupRecords: [GroupRecord],
        allFaces: [FaceRecord],
        threshold: Float
    ) async {
        let faceToGroup = Dictionary(uniqueKeysWithValues: groupRecords.flatMap { g in g.memberFaceIds.map { ($0, g.id) } })
        let faceToGroupIndex = Dictionary(uniqueKeysWithValues: groupRecords.flatMap { g in g.memberFaceIds.map { ($0, g.groupIndex) } })
        let faceToPhoto = Dictionary(uniqueKeysWithValues: allFaces.map { ($0.id, $0.photoId) })

        print("""
        ========================================================================
        KEEPSAKE FACE CLUSTERING & IDENTITY DIAGNOSTICS:
        ========================================================================
        """)

        for emb in embeddings {
            let norm = sqrt(emb.vector.reduce(0) { $0 + $1 * $1 })
            let gIdx = faceToGroupIndex[emb.faceId].map { "\($0)" } ?? "Unassigned"
            let gId = faceToGroup[emb.faceId]?.uuidString ?? "None"
            let photoId = faceToPhoto[emb.faceId]?.uuidString ?? "Unknown"
            print("FaceID: \(emb.faceId) | PhotoID: \(photoId) | Dim: \(emb.dimension) | Norm: \(String(format: "%.4f", norm)) | GroupIndex: \(gIdx) (ID: \(gId))")
        }

        print("\n--- PAIRWISE SIMILARITY MATRIX & EDGES (Threshold >= \(threshold)) ---")
        for i in 0..<embeddings.count {
            for j in (i + 1)..<embeddings.count {
                let e1 = embeddings[i]
                let e2 = embeddings[j]
                let sim = EmbeddingSimilarityUtility.cosineSimilarity(e1.vector, e2.vector)
                let passes = sim >= threshold
                let g1 = faceToGroupIndex[e1.faceId].map { "\($0)" } ?? "?"
                let g2 = faceToGroupIndex[e2.faceId].map { "\($0)" } ?? "?"
                let sameGroup = (g1 == g2)
                if passes || sameGroup || sim > 0.40 {
                    print("Pair [\(e1.faceId.uuidString.prefix(8))] <-> [\(e2.faceId.uuidString.prefix(8))] | Sim: \(String(format: "%.4f", sim)) | Passes: \(passes) | Edge: \(passes ? "YES" : "NO") | Group A: \(g1), Group B: \(g2) (Merged: \(sameGroup))")
                }
            }
        }

        let report = await libraryStore.validateIntegrity()
        print("""
        \n--- LIBRARY INTEGRITY REPORT ---
        Total Photos: \(report.totalPhotos)
        Total Detected Faces: \(report.totalDetectedFaces)
        Total Embeddings: \(report.totalEmbeddings)
        Total Unique Face IDs: \(report.totalUniqueFaceIds)
        Total Unique Group IDs: \(report.totalUniqueGroupIds)
        Faces Assigned to Multiple Groups: \(report.facesAssignedToMultipleGroupsCount)
        Duplicate Group Memberships: \(report.duplicateGroupMembershipsCount)
        Orphaned Embeddings: \(report.orphanedEmbeddingsCount)
        Integrity Valid: \(report.isValid)
        ========================================================================
        """)
    }
}
