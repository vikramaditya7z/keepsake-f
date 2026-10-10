import Foundation
import CoreGraphics
import Accelerate

/// Diagnostic performance and distribution metrics from a clustering run.
struct ClusteringExecutionMetrics: Sendable {
    let executionTimeMs: Double
    let totalFaces: Int
    let totalGroups: Int
    let singletonGroups: Int
    let multiFaceGroups: Int
    let pairwiseComparisonCount: Int
    let threshold: Float
}

/// Errors that can occur during face embedding clustering.
enum FaceClusteringError: LocalizedError {
    case invalidEmbeddingDimension(expected: Int, actual: Int)
    case emptyEmbeddingVector
    case invalidThreshold(Float)

    var errorDescription: String? {
        switch self {
        case .invalidEmbeddingDimension(let expected, let actual):
            return "Dimension mismatch in clustering: expected \(expected), got \(actual)."
        case .emptyEmbeddingVector:
            return "Encountered an empty embedding vector during clustering."
        case .invalidThreshold(let val):
            return "Threshold must be between 0.0 and 1.0, got \(val)."
        }
    }
}

/// Protocol defining face embedding clustering operations for person grouping experiments.
protocol FaceClusteringServiceProtocol: Sendable {
    var algorithmName: String { get }
    var defaultThreshold: Float { get }
    var candidateThresholds: [Float] { get }

    /// Clusters a collection of face embeddings given a similarity threshold.
    func cluster(
        embeddings: [FaceEmbedding],
        threshold: Float,
        faceLookup: [UUID: DetectedFace]
    ) async throws -> (groups: [FaceGroup], metrics: ClusteringExecutionMetrics)
}

extension FaceClusteringServiceProtocol {
    /// Convenience method without bounding box lookups.
    func cluster(
        embeddings: [FaceEmbedding],
        threshold: Float
    ) async throws -> [FaceGroup] {
        let result = try await cluster(embeddings: embeddings, threshold: threshold, faceLookup: [:])
        return result.groups
    }
}

/// Concrete face clustering service implementing deterministic cosine-graph clustering with average linkage.
struct CosineGraphClusteringService: FaceClusteringServiceProtocol {
    let algorithmName: String = "Cosine Graph & Average Linkage Clustering"
    let defaultThreshold: Float = 0.54
    let candidateThresholds: [Float] = [0.45, 0.48, 0.50, 0.52, 0.54, 0.56, 0.60, 0.65]

    /// Clusters face embeddings using pairwise cosine similarity and average-linkage connected components.
    func cluster(
        embeddings: [FaceEmbedding],
        threshold: Float,
        faceLookup: [UUID: DetectedFace]
    ) async throws -> (groups: [FaceGroup], metrics: ClusteringExecutionMetrics) {
        guard threshold >= 0.0 && threshold <= 1.0 else {
            throw FaceClusteringError.invalidThreshold(threshold)
        }

        return try await Task.detached(priority: .userInitiated) {
            let startTime = ContinuousClock.now

            // Filter valid embeddings and validate dimensions
            guard !embeddings.isEmpty else {
                let metrics = ClusteringExecutionMetrics(
                    executionTimeMs: 0.0,
                    totalFaces: 0,
                    totalGroups: 0,
                    singletonGroups: 0,
                    multiFaceGroups: 0,
                    pairwiseComparisonCount: 0,
                    threshold: threshold
                )
                return ([], metrics)
            }

            let expectedDim = embeddings[0].dimension
            for emb in embeddings {
                if emb.vector.isEmpty {
                    throw FaceClusteringError.emptyEmbeddingVector
                }
                if emb.dimension != expectedDim {
                    throw FaceClusteringError.invalidEmbeddingDimension(
                        expected: expectedDim,
                        actual: emb.dimension
                    )
                }
            }

            let count = embeddings.count
            var comparisonCount = 0

            // 1. Compute pairwise similarity matrix (symmetric, diagonal = 1.0)
            var similarityMatrix = [Float](repeating: 1.0, count: count * count)

            for i in 0..<count {
                for j in (i + 1)..<count {
                    comparisonCount += 1
                    let sim = EmbeddingSimilarityUtility.cosineSimilarity(
                        embeddings[i].vector,
                        embeddings[j].vector
                    )
                    similarityMatrix[i * count + j] = sim
                    similarityMatrix[j * count + i] = sim
                }
            }

            // 2. Perform Multi-Tier Cannot-Link Graph Agglomerative Clustering with Identity Manifold Safeguards
            // Candidate edges connecting faces from DIFFERENT photos with similarity >= seedThreshold
            struct CandidateEdge {
                let sim: Float
                let indexA: Int
                let indexB: Int
            }

            let seedThreshold = max(0.48, threshold - 0.04)
            var candidateEdges: [CandidateEdge] = []
            for i in 0..<count {
                for j in (i + 1)..<count {
                    let photoA = embeddings[i].photoURL.standardizedFileURL.path
                    let photoB = embeddings[j].photoURL.standardizedFileURL.path
                    // Cannot-Link constraint: faces from the same photo cannot have an edge
                    if !photoA.isEmpty && !photoB.isEmpty && photoA == photoB {
                        continue
                    }
                    let sim = similarityMatrix[i * count + j]
                    if sim >= seedThreshold {
                        candidateEdges.append(CandidateEdge(sim: sim, indexA: i, indexB: j))
                    }
                }
            }

            // Sort edges by descending similarity for greedy maximum-similarity agglomeration
            candidateEdges.sort { $0.sim > $1.sim }

            var clusters: [[Int]] = (0..<count).map { [$0] }
            var faceToClusterIndex: [Int] = Array(0..<count)

            func computeCentroid(indices: [Int]) -> [Float] {
                var accum = [Float](repeating: 0.0, count: expectedDim)
                for idx in indices {
                    let v = embeddings[idx].vector
                    vDSP_vadd(accum, 1, v, 1, &accum, 1, vDSP_Length(expectedDim))
                }
                return EmbeddingSimilarityUtility.l2Normalize(accum)
            }

            for edge in candidateEdges {
                let cIdxA = faceToClusterIndex[edge.indexA]
                let cIdxB = faceToClusterIndex[edge.indexB]
                if cIdxA == cIdxB {
                    continue
                }

                let clusterA = clusters[cIdxA]
                let clusterB = clusters[cIdxB]

                // Cannot-Link Constraint:
                // Faces detected in the same photograph represent distinct physical individuals.
                // Clusters containing faces from the same photo cannot merge.
                let photosA = Set(clusterA.compactMap { idx -> String? in
                    let p = embeddings[idx].photoURL.standardizedFileURL.path
                    return p.isEmpty ? nil : p
                })
                let photosB = Set(clusterB.compactMap { idx -> String? in
                    let p = embeddings[idx].photoURL.standardizedFileURL.path
                    return p.isEmpty ? nil : p
                })
                if !photosA.isEmpty && !photosB.isEmpty && !photosA.isDisjoint(with: photosB) {
                    continue
                }

                // Identity Manifold Coherence & Transitive Drift Prevention:
                // Verify that merging cluster B into cluster A maintains identity neighborhood coherence
                let centA = computeCentroid(indices: clusterA)
                let centB = computeCentroid(indices: clusterB)
                let centSim = EmbeddingSimilarityUtility.cosineSimilarity(centA, centB)

                // 1. Centroid coherence: clusters representing the same person must have close centroids
                guard centSim >= 0.48 else {
                    continue
                }

                // 2. Member-to-centroid coherence: merged centroid must hold all members tightly
                let mergedIndices = clusterA + clusterB
                let mergedCent = computeCentroid(indices: mergedIndices)
                var memberCoherent = true
                for idx in mergedIndices {
                    let toCent = EmbeddingSimilarityUtility.cosineSimilarity(embeddings[idx].vector, mergedCent)
                    if toCent < 0.42 {
                        memberCoherent = false
                        break
                    }
                }
                guard memberCoherent else {
                    continue
                }

                // 3. Transitive chain guard: for small clusters (<= 3 members), reject unreinforced chains where any pair < 0.48
                if mergedIndices.count <= 3 {
                    var minPairSim: Float = 1.0
                    for a in 0..<mergedIndices.count {
                        for b in (a + 1)..<mergedIndices.count {
                            let s = similarityMatrix[mergedIndices[a] * count + mergedIndices[b]]
                            if s < minPairSim { minPairSim = s }
                        }
                    }
                    if minPairSim < 0.48 {
                        continue
                    }
                } else {
                    // For larger clusters, prevent extreme outliers (< 0.35)
                    var minPairSim: Float = 1.0
                    for a in 0..<mergedIndices.count {
                        for b in (a + 1)..<mergedIndices.count {
                            let s = similarityMatrix[mergedIndices[a] * count + mergedIndices[b]]
                            if s < minPairSim { minPairSim = s }
                        }
                    }
                    if minPairSim < 0.35 {
                        continue
                    }
                }

                // Merge cluster B into cluster A
                for idx in clusterB {
                    faceToClusterIndex[idx] = cIdxA
                }
                clusters[cIdxA].append(contentsOf: clusterB)
                clusters[cIdxB] = []
            }

            // Remove emptied clusters
            clusters.removeAll { $0.isEmpty }

            // Tier 3: Multi-Evidence Identity Expansion
            // For any established multi-face identity (2+ faces across distinct photos),
            // iteratively attach unassigned singleton faces that have strong centroid and anchor agreement
            let attachmentThreshold = max(0.48, threshold - 0.06)
            var expansionChanged = true
            while expansionChanged {
                expansionChanged = false
                for cIdx in 0..<clusters.count {
                    guard clusters[cIdx].count >= 2 else { continue }

                    let cCentroid = computeCentroid(indices: clusters[cIdx])
                    let cPhotos = Set(clusters[cIdx].compactMap { idx -> String? in
                        let p = embeddings[idx].photoURL.standardizedFileURL.path
                        return p.isEmpty ? nil : p
                    })

                    var bestCandIdx: Int? = nil
                    var bestScore: Float = -1.0

                    for candIdx in 0..<clusters.count {
                        if candIdx == cIdx { continue }
                        guard clusters[candIdx].count == 1 else { continue }

                        let candFaceIdx = clusters[candIdx][0]
                        let candPhoto = embeddings[candFaceIdx].photoURL.standardizedFileURL.path
                        if !candPhoto.isEmpty && cPhotos.contains(candPhoto) {
                            continue // Cannot-Link
                        }

                        let candVec = embeddings[candFaceIdx].vector
                        let toCent = EmbeddingSimilarityUtility.cosineSimilarity(candVec, cCentroid)

                        var maxAnchor: Float = -2.0
                        var minMember: Float = 2.0
                        for mIdx in clusters[cIdx] {
                            let s = similarityMatrix[candFaceIdx * count + mIdx]
                            if s > maxAnchor { maxAnchor = s }
                            if s < minMember { minMember = s }
                        }

                        if toCent >= attachmentThreshold && maxAnchor >= attachmentThreshold && minMember >= 0.38 {
                            if toCent > bestScore {
                                bestScore = toCent
                                bestCandIdx = candIdx
                            }
                        }
                    }

                    if let candToMerge = bestCandIdx {
                        clusters[cIdx].append(contentsOf: clusters[candToMerge])
                        clusters.remove(at: candToMerge)
                        expansionChanged = true
                        break
                    }
                }
            }

            // 3. Sort clusters by size (largest first) for consistent developer inspection
            clusters.sort { $0.count > $1.count }

            // 4. Build FaceGroup representations with centroids and representative faces
            var faceGroups: [FaceGroup] = []
            var singletonCount = 0
            var multiFaceCount = 0

            for (groupIndex, clusterIndices) in clusters.enumerated() {
                let memberEmbeddings = clusterIndices.map { embeddings[$0] }
                let groupSize = memberEmbeddings.count

                if groupSize == 1 {
                    singletonCount += 1
                } else {
                    multiFaceCount += 1
                }

                // Calculate group centroid: element-wise sum followed by L2 normalization
                var centroidAccumulator = [Float](repeating: 0.0, count: expectedDim)
                for emb in memberEmbeddings {
                    vDSP_vadd(centroidAccumulator, 1, emb.vector, 1, &centroidAccumulator, 1, vDSP_Length(expectedDim))
                }
                let centroid = EmbeddingSimilarityUtility.l2Normalize(centroidAccumulator)

                // Compute intra-cluster similarity statistics
                var totalIntraSim: Float = 0.0
                var minIntraSim: Float = 1.0
                var pairwiseIntraCount = 0

                if groupSize == 1 {
                    totalIntraSim = 1.0
                    minIntraSim = 1.0
                    pairwiseIntraCount = 1
                } else {
                    for i in 0..<groupSize {
                        for j in (i + 1)..<groupSize {
                            let idxA = clusterIndices[i]
                            let idxB = clusterIndices[j]
                            let sim = similarityMatrix[idxA * count + idxB]
                            totalIntraSim += sim
                            minIntraSim = min(minIntraSim, sim)
                            pairwiseIntraCount += 1
                        }
                    }
                }

                let avgIntraSim = pairwiseIntraCount > 0 ? (totalIntraSim / Float(pairwiseIntraCount)) : 1.0

                // Map members with similarity to centroid and select representative face
                var clusteredMembers: [ClusteredFaceMember] = []
                var bestRepresentativeMember: ClusteredFaceMember? = nil
                var bestCentroidSim: Float = -2.0

                for emb in memberEmbeddings {
                    let simToCentroid = EmbeddingSimilarityUtility.cosineSimilarity(emb.vector, centroid)
                    let detectedFace = faceLookup[emb.faceId]
                    let member = ClusteredFaceMember(
                        faceId: emb.faceId,
                        photoURL: emb.photoURL,
                        boundingBox: detectedFace?.boundingBox,
                        embedding: emb,
                        similarityToCentroid: simToCentroid
                    )
                    clusteredMembers.append(member)

                    if simToCentroid > bestCentroidSim {
                        bestCentroidSim = simToCentroid
                        bestRepresentativeMember = member
                    }
                }

                let group = FaceGroup(
                    groupIndex: groupIndex + 1,
                    members: clusteredMembers,
                    representativeMember: bestRepresentativeMember ?? clusteredMembers.first,
                    centroid: centroid,
                    averageIntraClusterSimilarity: avgIntraSim,
                    minIntraClusterSimilarity: minIntraSim,
                    thresholdUsed: threshold
                )
                faceGroups.append(group)
            }

            let duration = ContinuousClock.now - startTime
            let milliseconds = Double(duration.components.attoseconds) / 1_000_000_000_000_000.0 + Double(duration.components.seconds) * 1000.0

            let metrics = ClusteringExecutionMetrics(
                executionTimeMs: milliseconds,
                totalFaces: count,
                totalGroups: faceGroups.count,
                singletonGroups: singletonCount,
                multiFaceGroups: multiFaceCount,
                pairwiseComparisonCount: comparisonCount,
                threshold: threshold
            )

            return (faceGroups, metrics)
        }.value
    }
}

// MARK: - Step 2: Local High-Precision FaceCluster Model & Service

/// An internal high-precision face cluster representing a cohesive facial appearance manifold.
/// Invariants:
/// 1. A FaceCluster must NEVER contain two faces from the same photo (Cannot-Link).
/// 2. Centroid must be unit L2-normalized.
/// 3. All member faces are mutually coherent above the Stage-1 safety threshold.
struct FaceCluster: Identifiable, Sendable, Hashable {
    let id: UUID
    var faceIds: [UUID]
    var photoIds: Set<UUID>
    var centroid: [Float]
    var representativeFaceId: UUID
    var coherenceScore: Float

    init(
        id: UUID = UUID(),
        faceIds: [UUID],
        photoIds: Set<UUID>,
        centroid: [Float],
        representativeFaceId: UUID,
        coherenceScore: Float = 1.0
    ) {
        self.id = id
        self.faceIds = faceIds
        self.photoIds = photoIds
        self.centroid = centroid
        self.representativeFaceId = representativeFaceId
        self.coherenceScore = coherenceScore
    }
}

/// Service protocol for Stage 1 Local Face Cluster formation.
protocol LocalFaceClusterServiceProtocol: Sendable {
    func formLocalClusters(
        embeddings: [FaceEmbedding],
        faceLookup: [UUID: DetectedFace],
        faceToPhotoId: [UUID: UUID],
        strictThreshold: Float,
        enableDiagnostics: Bool
    ) async throws -> [FaceCluster]
}

extension LocalFaceClusterServiceProtocol {
    func formLocalClusters(
        embeddings: [FaceEmbedding],
        faceLookup: [UUID: DetectedFace] = [:],
        faceToPhotoId: [UUID: UUID] = [:],
        strictThreshold: Float = 0.58,
        enableDiagnostics: Bool = false
    ) async throws -> [FaceCluster] {
        return try await formLocalClusters(
            embeddings: embeddings,
            faceLookup: faceLookup,
            faceToPhotoId: faceToPhotoId,
            strictThreshold: strictThreshold,
            enableDiagnostics: enableDiagnostics
        )
    }
}

/// Concrete implementation of Stage 1 Local High-Precision FaceCluster formation.
struct LocalFaceClusterService: LocalFaceClusterServiceProtocol {
    let defaultStrictThreshold: Float = 0.58

    func formLocalClusters(
        embeddings: [FaceEmbedding],
        faceLookup: [UUID: DetectedFace] = [:],
        faceToPhotoId: [UUID: UUID] = [:],
        strictThreshold: Float = 0.58,
        enableDiagnostics: Bool = false
    ) async throws -> [FaceCluster] {
        guard !embeddings.isEmpty else {
            return []
        }

        let expectedDim = embeddings[0].dimension
        for emb in embeddings {
            if emb.vector.isEmpty {
                throw FaceClusteringError.emptyEmbeddingVector
            }
            if emb.dimension != expectedDim {
                throw FaceClusteringError.invalidEmbeddingDimension(expected: expectedDim, actual: emb.dimension)
            }
        }

        let count = embeddings.count

        // 1. Resolve photoId for each embedding
        var photoIdForIndex: [UUID] = []
        for emb in embeddings {
            if let pId = faceToPhotoId[emb.faceId] {
                photoIdForIndex.append(pId)
            } else {
                // Fall back to deterministic UUID derived from photoURL path
                let path = emb.photoURL.standardizedFileURL.path
                if path.isEmpty {
                    photoIdForIndex.append(UUID())
                } else {
                    let deterministicUUID = UUID(uuidString: "00000000-0000-0000-0000-" + String(format: "%012x", abs(path.hashValue))) ?? UUID()
                    photoIdForIndex.append(deterministicUUID)
                }
            }
        }

        // 2. Compute pairwise cosine similarity matrix
        var similarityMatrix = [Float](repeating: 1.0, count: count * count)
        for i in 0..<count {
            for j in (i + 1)..<count {
                let sim = EmbeddingSimilarityUtility.cosineSimilarity(embeddings[i].vector, embeddings[j].vector)
                similarityMatrix[i * count + j] = sim
                similarityMatrix[j * count + i] = sim
            }
        }

        // 3. Build candidate edges connecting faces from DIFFERENT photos with similarity >= strictThreshold
        struct CandidateEdge {
            let sim: Float
            let indexA: Int
            let indexB: Int
        }

        var candidateEdges: [CandidateEdge] = []
        for i in 0..<count {
            for j in (i + 1)..<count {
                let photoA = photoIdForIndex[i]
                let photoB = photoIdForIndex[j]

                // Cannot-Link: faces from the same photo cannot have an edge
                if photoA == photoB {
                    if enableDiagnostics && similarityMatrix[i * count + j] >= strictThreshold {
                        print("[FACE CLUSTER REJECTED] Same Photo: Face [\(embeddings[i].faceId.uuidString.prefix(8))] <-> Face [\(embeddings[j].faceId.uuidString.prefix(8))] | Sim: \(String(format: "%.4f", similarityMatrix[i * count + j]))")
                    }
                    continue
                }

                let sim = similarityMatrix[i * count + j]
                if sim >= strictThreshold {
                    candidateEdges.append(CandidateEdge(sim: sim, indexA: i, indexB: j))
                }
            }
        }

        // Sort edges by descending similarity for greedy maximum-similarity agglomeration
        candidateEdges.sort { $0.sim > $1.sim }

        // 4. Initialize singleton clusters
        var clusters: [[Int]] = (0..<count).map { [$0] }
        var faceToClusterIndex: [Int] = Array(0..<count)

        func computeCentroid(indices: [Int]) -> [Float] {
            var accum = [Float](repeating: 0.0, count: expectedDim)
            for idx in indices {
                let v = embeddings[idx].vector
                vDSP_vadd(accum, 1, v, 1, &accum, 1, vDSP_Length(expectedDim))
            }
            return EmbeddingSimilarityUtility.l2Normalize(accum)
        }

        // 5. Agglomeration with multi-evidence validation
        for edge in candidateEdges {
            let cIdxA = faceToClusterIndex[edge.indexA]
            let cIdxB = faceToClusterIndex[edge.indexB]
            if cIdxA == cIdxB {
                continue
            }

            let clusterA = clusters[cIdxA]
            let clusterB = clusters[cIdxB]

            // Check 1: Cannot-Link constraint across entire clusters
            let photosA = Set(clusterA.map { photoIdForIndex[$0] })
            let photosB = Set(clusterB.map { photoIdForIndex[$0] })
            if !photosA.isDisjoint(with: photosB) {
                if enableDiagnostics {
                    print("[FACE CLUSTER REJECTED] Cannot-Link Photo Conflict: Cluster A (\(clusterA.count) faces) <-> Cluster B (\(clusterB.count) faces)")
                }
                continue
            }

            // Check 2: Centroid similarity between clusters
            let centA = computeCentroid(indices: clusterA)
            let centB = computeCentroid(indices: clusterB)
            let centSim = EmbeddingSimilarityUtility.cosineSimilarity(centA, centB)
            guard centSim >= (strictThreshold - 0.04) else {
                if enableDiagnostics {
                    print("[FACE CLUSTER REJECTED] Low Centroid Coherence (\(String(format: "%.4f", centSim)) < \(strictThreshold - 0.04)): Cluster A <-> Cluster B")
                }
                continue
            }

            // Check 3: Anti-Transitive Drift Guard
            // For small clusters (<= 3 faces), require all pairwise cross-similarities >= 0.50
            // For larger clusters, require all pairwise cross-similarities >= 0.40
            let mergedIndices = clusterA + clusterB
            var minPairSim: Float = 1.0
            for a in 0..<mergedIndices.count {
                for b in (a + 1)..<mergedIndices.count {
                    let s = similarityMatrix[mergedIndices[a] * count + mergedIndices[b]]
                    if s < minPairSim { minPairSim = s }
                }
            }

            let pairSafetyFloor: Float = (mergedIndices.count <= 3) ? 0.50 : 0.40
            guard minPairSim >= pairSafetyFloor else {
                if enableDiagnostics {
                    print("[FACE CLUSTER REJECTED] Transitive Drift Guard (minPairSim \(String(format: "%.4f", minPairSim)) < \(pairSafetyFloor)): Cluster A <-> Cluster B")
                }
                continue
            }

            // Check 4: Member-to-Centroid Coherence
            let mergedCent = computeCentroid(indices: mergedIndices)
            var memberCoherent = true
            for idx in mergedIndices {
                let toCent = EmbeddingSimilarityUtility.cosineSimilarity(embeddings[idx].vector, mergedCent)
                if toCent < 0.48 {
                    memberCoherent = false
                    break
                }
            }
            guard memberCoherent else {
                if enableDiagnostics {
                    print("[FACE CLUSTER REJECTED] Member-to-Centroid Coherence Failed: Cluster A <-> Cluster B")
                }
                continue
            }

            // Merge cluster B into cluster A
            for idx in clusterB {
                faceToClusterIndex[idx] = cIdxA
            }
            clusters[cIdxA].append(contentsOf: clusterB)
            clusters[cIdxB] = []
        }

        // 6. Build and Validate FaceCluster instances
        clusters.removeAll { $0.isEmpty }
        // Sort clusters descending by member count
        clusters.sort { $0.count > $1.count }

        var resultClusters: [FaceCluster] = []
        var assignedFaces = Set<UUID>()

        for memberIndices in clusters {
            let memberFaceIds = memberIndices.map { embeddings[$0].faceId }
            let memberPhotoIds = Set(memberIndices.map { photoIdForIndex[$0] })

            // Invariant 1: No duplicate photos (Cannot-Link)
            precondition(memberFaceIds.count == memberPhotoIds.count, "Cannot-Link violation in FaceCluster")

            // Invariant 2: No face in multiple clusters
            for fId in memberFaceIds {
                let inserted = assignedFaces.insert(fId).inserted
                precondition(inserted, "Duplicate face assignment across FaceClusters")
            }

            let centroid = computeCentroid(indices: memberIndices)

            // Invariant 3: Normalized centroid
            let norm = sqrt(centroid.reduce(0) { $0 + $1 * $1 })
            precondition(abs(norm - 1.0) < 1e-3, "Centroid must be unit L2-normalized")

            // Representative face selection (closest to centroid & highest detection confidence)
            var bestRepId = memberFaceIds[0]
            var bestScore: Float = -2.0
            var totalIntraSim: Float = 0.0
            var intraPairCount = 0

            for idx in memberIndices {
                let fId = embeddings[idx].faceId
                let simToCent = EmbeddingSimilarityUtility.cosineSimilarity(embeddings[idx].vector, centroid)
                let conf = faceLookup[fId]?.confidence ?? 1.0
                let score = simToCent * 0.8 + conf * 0.2
                if score > bestScore {
                    bestScore = score
                    bestRepId = fId
                }
            }

            if memberIndices.count == 1 {
                totalIntraSim = 1.0
                intraPairCount = 1
            } else {
                for a in 0..<memberIndices.count {
                    for b in (a + 1)..<memberIndices.count {
                        totalIntraSim += similarityMatrix[memberIndices[a] * count + memberIndices[b]]
                        intraPairCount += 1
                    }
                }
            }

            let coherence = intraPairCount > 0 ? (totalIntraSim / Float(intraPairCount)) : 1.0

            let cluster = FaceCluster(
                id: UUID(),
                faceIds: memberFaceIds,
                photoIds: memberPhotoIds,
                centroid: centroid,
                representativeFaceId: bestRepId,
                coherenceScore: coherence
            )
            resultClusters.append(cluster)
        }

        // 7. Detailed Diagnostics
        if enableDiagnostics {
            let multiFaceCount = resultClusters.filter { $0.faceIds.count > 1 }.count
            let singletonCount = resultClusters.filter { $0.faceIds.count == 1 }.count

            print("""
            ========================================================================
            [FACE CLUSTER AUDIT]
            Total Faces: \(count)
            Total FaceClusters: \(resultClusters.count)
            Multi-Face Clusters: \(multiFaceCount)
            Singleton Clusters: \(singletonCount)
            ========================================================================
            """)

            for (i, c) in resultClusters.enumerated() {
                let repPrefix = c.representativeFaceId.uuidString.prefix(8)
                let membersStr = c.faceIds.map { "\($0.uuidString.prefix(8))" }.joined(separator: ", ")
                print("Cluster \(i + 1) [ID: \(c.id.uuidString.prefix(8))]: \(c.faceIds.count) faces, \(c.photoIds.count) photos | Rep: [\(repPrefix)] | Coherence: \(String(format: "%.4f", c.coherenceScore)) | Members: [\(membersStr)]")
            }
            print("========================================================================\n")
        }

        return resultClusters
    }
}
