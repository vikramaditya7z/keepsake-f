import SwiftUI
import AppKit

/// View model coordinating the developer face clustering experiment across a collection of photos.
@MainActor
final class FaceClusteringViewModel: ObservableObject {
    @Published var isProcessing: Bool = false
    @Published var progressMessage: String = ""
    @Published var progressFraction: Double = 0.0
    @Published var processedPhotosCount: Int = 0
    @Published var totalPhotosCount: Int = 0

    @Published var extractedEmbeddings: [FaceEmbedding] = []
    @Published var faceLookup: [UUID: DetectedFace] = [:]
    @Published var faceCrops: [UUID: NSImage] = [:]
    @Published var faceToPhoto: [UUID: PhotoItem] = [:]

    @Published var currentThreshold: Float = 0.65
    @Published var faceGroups: [FaceGroup] = []
    @Published var executionMetrics: ClusteringExecutionMetrics?
    @Published var thresholdSensitivity: [ThresholdSensitivityEntry] = []
    @Published var errorMessage: String?

    struct ThresholdSensitivityEntry: Identifiable, Sendable {
        let id = UUID()
        let threshold: Float
        let groupCount: Int
        let singletonCount: Int
        let maxGroupSize: Int
    }

    private let faceDetector: any FaceDetectionServiceProtocol = VisionFaceDetectionService()
    private let preprocessor = FacePreprocessingService()
    private let recognitionService: any FaceRecognitionServiceProtocol = ArcFaceRecognitionService()
    private let clusteringService: any FaceClusteringServiceProtocol = CosineGraphClusteringService()
    private let libraryStore = LibraryStore()

    /// Runs the complete end-to-end extraction and clustering pipeline on the provided photos.
    func runPipeline(on photos: [PhotoItem]) async {
        guard !photos.isEmpty else { return }

        isProcessing = true
        progressFraction = 0.0
        processedPhotosCount = 0
        totalPhotosCount = photos.count
        progressMessage = "Starting face discovery on \(photos.count) photos…"

        var newEmbeddings: [FaceEmbedding] = []
        var newFaceLookup: [UUID: DetectedFace] = [:]
        var newFaceCrops: [UUID: NSImage] = [:]
        var newFaceToPhoto: [UUID: PhotoItem] = [:]

        for (index, photo) in photos.enumerated() {
            progressMessage = "Scanning photo \(index + 1) of \(photos.count): \(photo.filename)"
            progressFraction = Double(index) / Double(photos.count)

            do {
                let faces = try await faceDetector.detectFaces(in: photo.url)
                var faceRecords: [FaceRecord] = []
                var embeddingRecords: [EmbeddingRecord] = []

                for face in faces {
                    newFaceLookup[face.id] = face
                    newFaceToPhoto[face.id] = photo

                    let faceRecord = FaceRecord(
                        id: face.id,
                        photoId: face.id, // linked photo
                        boundingBox: face.boundingBox,
                        confidence: face.confidence,
                        processingState: .detected
                    )
                    faceRecords.append(faceRecord)

                    if let crop = try? preprocessor.cropFace(from: photo.url, normalizedBox: face.boundingBox) {
                        let nsImage = NSImage(cgImage: crop, size: NSSize(width: crop.width, height: crop.height))
                        newFaceCrops[face.id] = nsImage

                        let embedding = try await recognitionService.generateEmbedding(
                            from: crop,
                            photoURL: photo.url,
                            faceId: face.id
                        )
                        newEmbeddings.append(embedding)

                        let embRecord = EmbeddingRecord(
                            id: embedding.id,
                            faceId: face.id,
                            photoId: face.id,
                            vector: embedding.vector,
                            modelName: recognitionService.modelName,
                            modelVersion: "v1",
                            inferenceTimeMs: embedding.inferenceTimeMs
                        )
                        embeddingRecords.append(embRecord)
                    }
                }

                if let existingPhoto = await libraryStore.getPhoto(byRelativePath: photo.filename) {
                    try? await libraryStore.saveFaces(faceRecords.map { FaceRecord(id: $0.id, photoId: existingPhoto.id, boundingBox: $0.boundingBox, confidence: $0.confidence) }, forPhotoId: existingPhoto.id)
                    try? await libraryStore.saveEmbeddings(embeddingRecords.map { EmbeddingRecord(id: $0.id, faceId: $0.faceId, photoId: existingPhoto.id, vector: $0.vector) })
                }
            } catch {
                print("Failed face extraction on \(photo.filename): \(error.localizedDescription)")
            }

            processedPhotosCount = index + 1
        }

        self.extractedEmbeddings = newEmbeddings
        self.faceLookup = newFaceLookup
        self.faceCrops = newFaceCrops
        self.faceToPhoto = newFaceToPhoto
        self.progressFraction = 1.0
        self.progressMessage = "Face extraction complete. Performing clustering…"

        await recluster()
        await computeSensitivityMatrix()

        isProcessing = false
    }

    /// Re-clusters the already-extracted in-memory embeddings with the current threshold.
    func recluster() async {
        guard !extractedEmbeddings.isEmpty else {
            self.faceGroups = []
            self.executionMetrics = nil
            return
        }

        do {
            let result = try await clusteringService.cluster(
                embeddings: extractedEmbeddings,
                threshold: currentThreshold,
                faceLookup: faceLookup
            )
            self.faceGroups = result.groups
            self.executionMetrics = result.metrics

            // Persist groups to LibraryStore
            let existingGroups = await libraryStore.getGroups()
            var existingNamesByFaceId: [UUID: String] = [:]
            for g in existingGroups {
                if let custom = g.customName {
                    for fId in g.memberFaceIds {
                        existingNamesByFaceId[fId] = custom
                    }
                }
            }

            let groupRecords = result.groups.map { group in
                var inheritedName: String? = nil
                for m in group.members {
                    if let name = existingNamesByFaceId[m.faceId] {
                        inheritedName = name
                        break
                    }
                }

                return GroupRecord(
                    id: group.id,
                    groupIndex: group.groupIndex,
                    customName: inheritedName,
                    representativeFaceId: group.representativeMember?.faceId,
                    memberFaceIds: group.members.map(\.faceId),
                    centroid: group.centroid,
                    averageSimilarity: group.averageIntraClusterSimilarity,
                    minSimilarity: group.minIntraClusterSimilarity,
                    thresholdUsed: group.thresholdUsed,
                    algorithmName: clusteringService.algorithmName,
                    algorithmVersion: "v1"
                )
            }

            try? await libraryStore.saveGroups(groupRecords)
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    /// Changes the clustering similarity threshold and updates groups instantaneously.
    func setThreshold(_ threshold: Float) async {
        self.currentThreshold = threshold
        await recluster()
    }

    /// Computes candidate threshold sensitivity distribution across [0.50, 0.55, 0.60, 0.65, 0.70, 0.75, 0.80].
    private func computeSensitivityMatrix() async {
        var entries: [ThresholdSensitivityEntry] = []
        for t in clusteringService.candidateThresholds {
            if let result = try? await clusteringService.cluster(embeddings: extractedEmbeddings, threshold: t, faceLookup: faceLookup) {
                let singletons = result.groups.filter { $0.faceCount == 1 }.count
                let maxSize = result.groups.map(\.faceCount).max() ?? 0
                entries.append(
                    ThresholdSensitivityEntry(
                        threshold: t,
                        groupCount: result.groups.count,
                        singletonCount: singletons,
                        maxGroupSize: maxSize
                    )
                )
            }
        }
        self.thresholdSensitivity = entries
    }
}
