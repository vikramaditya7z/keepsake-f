import Foundation
import Accelerate

/// Utility for computing deterministic mathematical similarity and distance metrics between embedding vectors.
enum EmbeddingSimilarityUtility {
    /// Computes the Cosine Similarity between two numerical vectors.
    /// Returns a score in the range [-1.0, 1.0], where 1.0 indicates identical directional orientation.
    static func cosineSimilarity(_ vectorA: [Float], _ vectorB: [Float]) -> Float {
        guard vectorA.count == vectorB.count, !vectorA.isEmpty else {
            return 0.0
        }

        var dotProduct: Float = 0.0
        var normA: Float = 0.0
        var normB: Float = 0.0

        vDSP_dotpr(vectorA, 1, vectorB, 1, &dotProduct, vDSP_Length(vectorA.count))
        vDSP_svesq(vectorA, 1, &normA, vDSP_Length(vectorA.count))
        vDSP_svesq(vectorB, 1, &normB, vDSP_Length(vectorB.count))

        let denominator = sqrt(normA) * sqrt(normB)
        guard denominator > 1e-7 else {
            return 0.0
        }

        let similarity = dotProduct / denominator
        return min(max(similarity, -1.0), 1.0)
    }

    /// Computes the Euclidean (L2) distance between two numerical vectors.
    static func euclideanDistance(_ vectorA: [Float], _ vectorB: [Float]) -> Float {
        guard vectorA.count == vectorB.count, !vectorA.isEmpty else {
            return Float.infinity
        }

        var distanceSq: Float = 0.0
        vDSP_distancesq(vectorA, 1, vectorB, 1, &distanceSq, vDSP_Length(vectorA.count))
        return sqrt(distanceSq)
    }

    /// Returns the L2 unit-normalized copy of a vector.
    static func l2Normalize(_ vector: [Float]) -> [Float] {
        guard !vector.isEmpty else { return [] }

        var normSq: Float = 0.0
        vDSP_svesq(vector, 1, &normSq, vDSP_Length(vector.count))
        let norm = sqrt(normSq)

        guard norm > 1e-7 else {
            return vector
        }

        var normalized = [Float](repeating: 0.0, count: vector.count)
        var divisor = norm
        vDSP_vsdiv(vector, 1, &divisor, &normalized, 1, vDSP_Length(vector.count))
        return normalized
    }

    /// Selects up to `maxAnchors` diverse representative embeddings from candidate vectors using furthest-point sampling (k-medoids).
    static func selectDiverseAnchors(from vectors: [[Float]], centroid: [Float], maxAnchors: Int = 4) -> [[Float]] {
        guard !vectors.isEmpty else { return [centroid] }
        if vectors.count <= maxAnchors { return vectors }

        var selected: [[Float]] = []

        // 1. First anchor: closest to centroid (canonical frontal/representative)
        var bestCentroidSim: Float = -2.0
        var canonicalAnchor = vectors[0]
        for v in vectors {
            let sim = cosineSimilarity(v, centroid)
            if sim > bestCentroidSim {
                bestCentroidSim = sim
                canonicalAnchor = v
            }
        }
        selected.append(canonicalAnchor)

        // 2. Subsequent anchors: pick vector that is furthest from existing selected anchors (furthest point sampling)
        while selected.count < maxAnchors {
            var furthestVector: [Float]? = nil
            var maxMinDist: Float = -1.0

            for v in vectors {
                // Minimum distance (or 1 - max similarity) to already selected anchors
                var maxSimToSelected: Float = -2.0
                for a in selected {
                    let sim = cosineSimilarity(v, a)
                    if sim > maxSimToSelected {
                        maxSimToSelected = sim
                    }
                }
                let dist = 1.0 - maxSimToSelected
                if dist > maxMinDist {
                    maxMinDist = dist
                    furthestVector = v
                }
            }

            if let next = furthestVector, maxMinDist > 0.03 {
                selected.append(next)
            } else {
                break
            }
        }

        return selected
    }
}

