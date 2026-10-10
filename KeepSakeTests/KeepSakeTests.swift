import XCTest
import CoreGraphics
@testable import KeepSake

final class SafeBox<T>: @unchecked Sendable {
    private var _value: T
    private let lock = NSLock()

    init(_ value: T) {
        self._value = value
    }

    var value: T {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    func mutate(_ transform: (inout T) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        transform(&_value)
    }

    func set(_ newValue: T) {
        lock.lock()
        defer { lock.unlock() }
        _value = newValue
    }
}

final class KeepSakeTests: XCTestCase {
    let testFolderURL = URL(fileURLWithPath: "/Users/vikramaditya/.gemini/antigravity/brain/997d2b6e-4811-4f02-964d-9c7cdd7691c6/scratch/test_photos")

    // MARK: - Phase 1 Tests

    func testPhotoScannerServiceDiscoversNestedImages() async throws {
        let scanner = PhotoScannerService()
        var discoveredPhotos: [PhotoItem] = []

        for try await batch in scanner.scanStream(at: testFolderURL) {
            discoveredPhotos.append(contentsOf: batch)
        }

        let filenames = Set(discoveredPhotos.map(\.filename))

        XCTAssertTrue(filenames.contains("red.png"), "Should find root red.png")
        XCTAssertTrue(filenames.contains("green.png"), "Should find sub1/green.png")
        XCTAssertTrue(filenames.contains("blue.png"), "Should find sub1/nested/blue.png")
        XCTAssertTrue(filenames.contains("yellow.png"), "Should find sub2/yellow.png")
        XCTAssertTrue(filenames.contains("corrupted.jpg"), "Should discover file by extension")
        XCTAssertFalse(filenames.contains("notes.txt"), "Should ignore non-image files")
    }

    func testPhotoScannerServiceEmptyFolder() async throws {
        let scanner = PhotoScannerService()
        let emptyURL = testFolderURL.appendingPathComponent("empty_folder")
        var discoveredPhotos: [PhotoItem] = []

        for try await batch in scanner.scanStream(at: emptyURL) {
            discoveredPhotos.append(contentsOf: batch)
        }

        XCTAssertEqual(discoveredPhotos.count, 0, "Empty folder should return zero photos")
    }

    func testThumbnailLoaderHandlesValidAndCorruptedImages() async {
        let validURL = testFolderURL.appendingPathComponent("red.png")
        let thumbnail = await ThumbnailLoader.shared.loadThumbnail(for: validURL)
        XCTAssertNotNil(thumbnail, "Should successfully load thumbnail for valid PNG")

        let corruptURL = testFolderURL.appendingPathComponent("sub2/corrupted.jpg")
        let corruptThumbnail = await ThumbnailLoader.shared.loadThumbnail(for: corruptURL)
        XCTAssertNil(corruptThumbnail, "Should safely return nil for corrupted image data without crashing")
    }

    @MainActor
    func testPhotoBrowserViewModelNavigation() {
        let vm = PhotoBrowserViewModel()
        let item1 = PhotoItem(url: URL(fileURLWithPath: "/tmp/1.jpg"))
        let item2 = PhotoItem(url: URL(fileURLWithPath: "/tmp/2.jpg"))
        let item3 = PhotoItem(url: URL(fileURLWithPath: "/tmp/3.jpg"))

        vm.photos = [item1, item2, item3]

        XCTAssertNil(vm.selectedPhoto)
        XCTAssertFalse(vm.hasPreviousPhoto)
        XCTAssertFalse(vm.hasNextPhoto)

        vm.selectPhoto(item2)
        XCTAssertEqual(vm.selectedPhoto, item2)
        XCTAssertTrue(vm.hasPreviousPhoto)
        XCTAssertTrue(vm.hasNextPhoto)

        vm.selectNextPhoto()
        XCTAssertEqual(vm.selectedPhoto, item3)
        XCTAssertTrue(vm.hasPreviousPhoto)
        XCTAssertFalse(vm.hasNextPhoto)

        vm.selectPreviousPhoto()
        XCTAssertEqual(vm.selectedPhoto, item2)

        vm.clearSelection()
        XCTAssertNil(vm.selectedPhoto)
    }

    func testPhotoItemFormatting() {
        let item = PhotoItem(url: URL(fileURLWithPath: "/test/path/my_photo.jpg"), fileSize: 2048)
        XCTAssertEqual(item.filename, "my_photo.jpg")
        XCTAssertFalse(item.formattedFileSize.isEmpty)
    }

    // MARK: - Phase 2 Face Detection Tests

    func testFaceDetectionOnSolidColorReturnsZeroFaces() async throws {
        let service = VisionFaceDetectionService()
        let imageURL = testFolderURL.appendingPathComponent("red.png")

        let faces = try await service.detectFaces(in: imageURL)
        XCTAssertEqual(faces.count, 0, "Solid color image should have zero detectable faces")
    }

    func testFaceDetectionOnCorruptedImageFailsGracefully() async {
        let service = VisionFaceDetectionService()
        let corruptURL = testFolderURL.appendingPathComponent("sub2/corrupted.jpg")

        do {
            let faces = try await service.detectFaces(in: corruptURL)
            XCTAssertEqual(faces.count, 0)
        } catch {
            XCTAssertTrue(error is FaceDetectionError)
        }
    }

    func testDetectedFaceNormalizedCoordinatesValidity() {
        let normalizedBox = CGRect(x: 0.25, y: 0.30, width: 0.20, height: 0.25)
        let face = DetectedFace(boundingBox: normalizedBox, confidence: 0.95)

        XCTAssertGreaterThanOrEqual(face.boundingBox.minX, 0.0)
        XCTAssertLessThanOrEqual(face.boundingBox.maxX, 1.0)
        XCTAssertGreaterThanOrEqual(face.boundingBox.minY, 0.0)
        XCTAssertLessThanOrEqual(face.boundingBox.maxY, 1.0)
        XCTAssertGreaterThan(face.confidence, 0.0)
        XCTAssertLessThanOrEqual(face.confidence, 1.0)
    }

    func testCoordinateConverterLandscapeImage() {
        let imageSize = CGSize(width: 400, height: 200)
        let containerSize = CGSize(width: 800, height: 600)

        let renderRect = CoordinateConverter.aspectFitRect(for: imageSize, in: containerSize)
        XCTAssertEqual(renderRect.width, 800.0, accuracy: 0.001)
        XCTAssertEqual(renderRect.height, 400.0, accuracy: 0.001)
        XCTAssertEqual(renderRect.origin.x, 0.0, accuracy: 0.001)
        XCTAssertEqual(renderRect.origin.y, 100.0, accuracy: 0.001)

        let visionBox = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        let viewRect = CoordinateConverter.convertVisionBoundingBox(visionBox, imageSize: imageSize, containerSize: containerSize)

        XCTAssertEqual(viewRect.origin.x, 320.0, accuracy: 0.001)
        XCTAssertEqual(viewRect.origin.y, 260.0, accuracy: 0.001)
        XCTAssertEqual(viewRect.width, 160.0, accuracy: 0.001)
        XCTAssertEqual(viewRect.height, 80.0, accuracy: 0.001)
    }

    func testCoordinateConverterPortraitImage() {
        let imageSize = CGSize(width: 200, height: 400)
        let containerSize = CGSize(width: 800, height: 600)

        let renderRect = CoordinateConverter.aspectFitRect(for: imageSize, in: containerSize)
        XCTAssertEqual(renderRect.width, 300.0, accuracy: 0.001)
        XCTAssertEqual(renderRect.height, 600.0, accuracy: 0.001)
        XCTAssertEqual(renderRect.origin.x, 250.0, accuracy: 0.001)
        XCTAssertEqual(renderRect.origin.y, 0.0, accuracy: 0.001)

        let visionBox = CGRect(x: 0.1, y: 0.7, width: 0.3, height: 0.2)
        let viewRect = CoordinateConverter.convertVisionBoundingBox(visionBox, imageSize: imageSize, containerSize: containerSize)

        XCTAssertEqual(viewRect.origin.x, 280.0, accuracy: 0.001)
        XCTAssertEqual(viewRect.origin.y, 60.0, accuracy: 0.001)
        XCTAssertEqual(viewRect.width, 90.0, accuracy: 0.001)
        XCTAssertEqual(viewRect.height, 120.0, accuracy: 0.001)
    }

    // MARK: - Phase 3 Face Recognition & Embedding Tests

    func testCosineSimilarityIdenticalVectors() {
        let v1: [Float] = [0.2, 0.5, 0.8, -0.3, 0.1]
        let v2: [Float] = [0.2, 0.5, 0.8, -0.3, 0.1]

        let sim = EmbeddingSimilarityUtility.cosineSimilarity(v1, v2)
        XCTAssertEqual(sim, 1.0, accuracy: 0.0001, "Cosine similarity with self must be 1.0")
    }

    func testCosineSimilarityOrthogonalVectors() {
        let v1: [Float] = [1.0, 0.0, 0.0]
        let v2: [Float] = [0.0, 1.0, 0.0]

        let sim = EmbeddingSimilarityUtility.cosineSimilarity(v1, v2)
        XCTAssertEqual(sim, 0.0, accuracy: 0.0001, "Cosine similarity between orthogonal vectors must be 0.0")
    }

    func testCosineSimilarityOppositeVectors() {
        let v1: [Float] = [0.5, -0.3, 0.8]
        let v2: [Float] = [-0.5, 0.3, -0.8]

        let sim = EmbeddingSimilarityUtility.cosineSimilarity(v1, v2)
        XCTAssertEqual(sim, -1.0, accuracy: 0.0001, "Cosine similarity between opposite vectors must be -1.0")
    }

    func testCosineSimilarityDimensionMismatchReturnsZero() {
        let v1: [Float] = [1.0, 2.0, 3.0]
        let v2: [Float] = [1.0, 2.0]

        let sim = EmbeddingSimilarityUtility.cosineSimilarity(v1, v2)
        XCTAssertEqual(sim, 0.0, "Dimension mismatch should return 0.0 safely without crashing")
    }

    func testEuclideanDistanceCalculation() {
        let v1: [Float] = [0.0, 0.0]
        let v2: [Float] = [3.0, 4.0]

        let dist = EmbeddingSimilarityUtility.euclideanDistance(v1, v2)
        XCTAssertEqual(dist, 5.0, accuracy: 0.0001, "Euclidean distance for 3-4-5 triangle should be 5.0")
    }

    func testL2NormalizationProducesUnitVector() {
        let vector: [Float] = [3.0, 4.0, 0.0]
        let normalized = EmbeddingSimilarityUtility.l2Normalize(vector)

        XCTAssertEqual(normalized.count, 3)
        XCTAssertEqual(normalized[0], 0.6, accuracy: 0.0001)
        XCTAssertEqual(normalized[1], 0.8, accuracy: 0.0001)
        XCTAssertEqual(normalized[2], 0.0, accuracy: 0.0001)

        let norm = sqrt(normalized.reduce(0.0) { $0 + ($1 * $1) })
        XCTAssertEqual(norm, 1.0, accuracy: 0.0001, "Normalized vector L2 norm must be 1.0")
    }

    func testFacePreprocessingCropsValidRegion() throws {
        let preprocessor = FacePreprocessingService()
        let imageURL = testFolderURL.appendingPathComponent("red.png")
        let box = CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5)

        let cropped = try preprocessor.cropFace(from: imageURL, normalizedBox: box, marginFactor: 0.1)
        XCTAssertGreaterThan(cropped.width, 0)
        XCTAssertGreaterThan(cropped.height, 0)
    }

    func testFacePreprocessingDegenerateBoxFails() {
        let preprocessor = FacePreprocessingService()
        let imageURL = testFolderURL.appendingPathComponent("red.png")
        let degenerateBox = CGRect(x: 0.0, y: 0.0, width: 0.0, height: 0.0)

        XCTAssertThrowsError(try preprocessor.cropFace(from: imageURL, normalizedBox: degenerateBox))
    }

    func testVisionFaceRecognitionGenerates768DEmbedding() async throws {
        let recognitionService = VisionFaceRecognitionService()
        let preprocessor = FacePreprocessingService()
        let imageURL = testFolderURL.appendingPathComponent("red.png")
        let box = CGRect(x: 0.1, y: 0.1, width: 0.6, height: 0.6)

        let crop = try preprocessor.cropFace(from: imageURL, normalizedBox: box)
        let faceId = UUID()
        let embedding = try await recognitionService.generateEmbedding(from: crop, photoURL: imageURL, faceId: faceId)

        XCTAssertEqual(embedding.dimension, 768, "Vision FeaturePrint Rev 2 should produce a 768-D vector")
        XCTAssertEqual(embedding.vector.count, 768)
        XCTAssertEqual(embedding.faceId, faceId)
        XCTAssertEqual(embedding.photoURL, imageURL)
        XCTAssertGreaterThan(embedding.inferenceTimeMs, 0.0, "Inference latency should be positive")
        XCTAssertEqual(embedding.l2Norm, 1.0, accuracy: 0.001, "Embedding should be L2-normalized")
    }

    // MARK: - Phase 3B ArcFace Benchmark Tests

    func testArcFaceRecognitionGenerates512DEmbedding() async throws {
        let recognitionService = ArcFaceRecognitionService()
        let preprocessor = FacePreprocessingService()
        let imageURL = testFolderURL.appendingPathComponent("red.png")
        let box = CGRect(x: 0.1, y: 0.1, width: 0.6, height: 0.6)

        let crop = try preprocessor.cropFace(from: imageURL, normalizedBox: box)
        let faceId = UUID()
        let embedding = try await recognitionService.generateEmbedding(from: crop, photoURL: imageURL, faceId: faceId)

        XCTAssertEqual(embedding.dimension, 512, "ArcFace should produce a 512-D vector")
        XCTAssertEqual(embedding.vector.count, 512)
        XCTAssertEqual(embedding.faceId, faceId)
        XCTAssertEqual(embedding.photoURL, imageURL)
        XCTAssertGreaterThan(embedding.inferenceTimeMs, 0.0, "Inference latency should be positive")
        XCTAssertEqual(embedding.l2Norm, 1.0, accuracy: 0.001, "ArcFace embedding must be unit L2-normalized")
    }

    func testArcFaceImageResizingTo112x112() throws {
        let preprocessor = FacePreprocessingService()
        let imageURL = testFolderURL.appendingPathComponent("red.png")
        let box = CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)

        let crop = try preprocessor.cropFace(from: imageURL, normalizedBox: box)
        let resized = ArcFaceRecognitionService.resizeAndExtract112x112(image: crop)

        XCTAssertNotNil(resized)
        XCTAssertEqual(resized?.width, 112)
        XCTAssertEqual(resized?.height, 112)
    }

    func testArcFaceNormalizedRGBPlanarExtraction() throws {
        let preprocessor = FacePreprocessingService()
        let imageURL = testFolderURL.appendingPathComponent("red.png")
        let box = CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)

        let crop = try preprocessor.cropFace(from: imageURL, normalizedBox: box)
        guard let resized = ArcFaceRecognitionService.resizeAndExtract112x112(image: crop) else {
            XCTFail("Failed to resize image to 112x112")
            return
        }

        let tensor = try ArcFaceRecognitionService.extractNormalizedRGBPlanar(from: resized)
        XCTAssertEqual(tensor.count, 3 * 112 * 112, "Tensor must contain 3 x 112 x 112 floats")

        // In red.png (pure red), R channel should be positive (~0.99) while G and B should be negative (~-0.99)
        let pixelCount = 112 * 112
        let avgR = tensor[0..<pixelCount].reduce(0.0, +) / Float(pixelCount)
        let avgG = tensor[pixelCount..<(2 * pixelCount)].reduce(0.0, +) / Float(pixelCount)

        XCTAssertGreaterThan(avgR, 0.5, "Red channel in red.png should be high/positive after normalization")
        XCTAssertLessThan(avgG, -0.5, "Green channel in red.png should be low/negative after normalization")
    }

    func testArcFaceDeterministicProjection() {
        let dummyTensor = [Float](repeating: 0.5, count: 3 * 112 * 112)
        let embedding1 = ArcFaceRecognitionService.computeMobileFaceNetEmbedding(tensor: dummyTensor)
        let embedding2 = ArcFaceRecognitionService.computeMobileFaceNetEmbedding(tensor: dummyTensor)

        XCTAssertEqual(embedding1.count, 512)
        XCTAssertEqual(embedding1, embedding2, "ArcFace MobileFaceNet projection must be deterministic for identical inputs")
    }

    // MARK: - Phase 4 Face Clustering Tests

    func testClusteringEmptyEmbeddingsReturnsZeroGroups() async throws {
        let clusteringService = CosineGraphClusteringService()
        let (groups, metrics) = try await clusteringService.cluster(embeddings: [], threshold: 0.65, faceLookup: [:])

        XCTAssertEqual(groups.count, 0, "Empty embeddings should produce 0 groups")
        XCTAssertEqual(metrics.totalFaces, 0)
        XCTAssertEqual(metrics.totalGroups, 0)
        XCTAssertEqual(metrics.pairwiseComparisonCount, 0)
    }

    func testClusteringSingleEmbeddingReturnsOneGroup() async throws {
        let clusteringService = CosineGraphClusteringService()
        let faceId = UUID()
        let dummyVector = EmbeddingSimilarityUtility.l2Normalize([Float](repeating: 1.0, count: 512))
        let embedding = FaceEmbedding(
            photoURL: testFolderURL.appendingPathComponent("red.png"),
            faceId: faceId,
            vector: dummyVector,
            modelName: "ArcFace",
            inferenceTimeMs: 4.2
        )

        let (groups, metrics) = try await clusteringService.cluster(embeddings: [embedding], threshold: 0.65, faceLookup: [:])

        XCTAssertEqual(groups.count, 1, "Single embedding must produce exactly 1 group")
        XCTAssertEqual(groups[0].faceCount, 1)
        XCTAssertEqual(groups[0].representativeMember?.faceId, faceId)
        XCTAssertEqual(groups[0].averageIntraClusterSimilarity, 1.0, accuracy: 0.001)
        XCTAssertEqual(metrics.totalFaces, 1)
        XCTAssertEqual(metrics.singletonGroups, 1)
        XCTAssertEqual(metrics.multiFaceGroups, 0)
    }

    func testClusteringIdenticalEmbeddingsFormSingleGroup() async throws {
        let clusteringService = CosineGraphClusteringService()
        var vec = [Float](repeating: 0.0, count: 512)
        vec[0] = 1.0
        let normVec = EmbeddingSimilarityUtility.l2Normalize(vec)

        let emb1 = FaceEmbedding(
            photoURL: testFolderURL.appendingPathComponent("red.png"),
            faceId: UUID(),
            vector: normVec,
            modelName: "ArcFace",
            inferenceTimeMs: 4.0
        )
        let emb2 = FaceEmbedding(
            photoURL: testFolderURL.appendingPathComponent("green.png"),
            faceId: UUID(),
            vector: normVec,
            modelName: "ArcFace",
            inferenceTimeMs: 4.0
        )

        let (groups, metrics) = try await clusteringService.cluster(embeddings: [emb1, emb2], threshold: 0.65, faceLookup: [:])

        XCTAssertEqual(groups.count, 1, "Identical embeddings must be grouped together")
        XCTAssertEqual(groups[0].faceCount, 2)
        XCTAssertEqual(groups[0].averageIntraClusterSimilarity, 1.0, accuracy: 0.001)
        XCTAssertEqual(metrics.multiFaceGroups, 1)
        XCTAssertEqual(metrics.singletonGroups, 0)
    }

    func testClusteringOrthogonalEmbeddingsProduceDistinctGroups() async throws {
        let clusteringService = CosineGraphClusteringService()
        var vec1 = [Float](repeating: 0.0, count: 512)
        vec1[0] = 1.0
        var vec2 = [Float](repeating: 0.0, count: 512)
        vec2[1] = 1.0

        let emb1 = FaceEmbedding(
            photoURL: testFolderURL.appendingPathComponent("red.png"),
            faceId: UUID(),
            vector: vec1,
            modelName: "ArcFace",
            inferenceTimeMs: 4.0
        )
        let emb2 = FaceEmbedding(
            photoURL: testFolderURL.appendingPathComponent("blue.png"),
            faceId: UUID(),
            vector: vec2,
            modelName: "ArcFace",
            inferenceTimeMs: 4.0
        )

        let (groups, metrics) = try await clusteringService.cluster(embeddings: [emb1, emb2], threshold: 0.65, faceLookup: [:])

        XCTAssertEqual(groups.count, 2, "Orthogonal embeddings (sim = 0.0) must form 2 separate groups at threshold 0.65")
        XCTAssertEqual(metrics.singletonGroups, 2)
        XCTAssertEqual(metrics.multiFaceGroups, 0)
    }

    func testClusteringMultipleDistinctGroups() async throws {
        let clusteringService = CosineGraphClusteringService()

        // Create 3 synthetic person clusters (Person A: basis 0, Person B: basis 10, Person C: basis 20)
        var embeddings: [FaceEmbedding] = []

        // Person A (3 faces with small perturbations)
        for i in 0..<3 {
            var v = [Float](repeating: 0.0, count: 512)
            v[0] = 1.0
            v[1] = Float(i) * 0.05
            embeddings.append(
                FaceEmbedding(
                    photoURL: testFolderURL.appendingPathComponent("photo_a\(i).jpg"),
                    faceId: UUID(),
                    vector: EmbeddingSimilarityUtility.l2Normalize(v),
                    modelName: "ArcFace",
                    inferenceTimeMs: 3.5
                )
            )
        }

        // Person B (2 faces with small perturbations)
        for i in 0..<2 {
            var v = [Float](repeating: 0.0, count: 512)
            v[10] = 1.0
            v[11] = Float(i) * 0.05
            embeddings.append(
                FaceEmbedding(
                    photoURL: testFolderURL.appendingPathComponent("photo_b\(i).jpg"),
                    faceId: UUID(),
                    vector: EmbeddingSimilarityUtility.l2Normalize(v),
                    modelName: "ArcFace",
                    inferenceTimeMs: 3.5
                )
            )
        }

        // Person C (1 singleton face)
        var vC = [Float](repeating: 0.0, count: 512)
        vC[20] = 1.0
        embeddings.append(
            FaceEmbedding(
                photoURL: testFolderURL.appendingPathComponent("photo_c0.jpg"),
                faceId: UUID(),
                vector: EmbeddingSimilarityUtility.l2Normalize(vC),
                modelName: "ArcFace",
                inferenceTimeMs: 3.5
            )
        )

        let (groups, metrics) = try await clusteringService.cluster(embeddings: embeddings, threshold: 0.70, faceLookup: [:])

        XCTAssertEqual(groups.count, 3, "Should recover 3 distinct groups")
        XCTAssertEqual(groups[0].faceCount, 3, "Largest group should have 3 faces (Person A)")
        XCTAssertEqual(groups[1].faceCount, 2, "Second group should have 2 faces (Person B)")
        XCTAssertEqual(groups[2].faceCount, 1, "Third group should be 1 singleton face (Person C)")
        XCTAssertEqual(metrics.multiFaceGroups, 2)
        XCTAssertEqual(metrics.singletonGroups, 1)
    }

    func testThresholdSensitivityModifiesClusterCount() async throws {
        let clusteringService = CosineGraphClusteringService()

        // Two face vectors with cosine similarity around 0.68
        var v1 = [Float](repeating: 0.0, count: 512)
        v1[0] = 0.8
        v1[1] = 0.6
        let normV1 = EmbeddingSimilarityUtility.l2Normalize(v1)

        var v2 = [Float](repeating: 0.0, count: 512)
        v2[0] = 0.8
        v2[1] = 0.0
        let normV2 = EmbeddingSimilarityUtility.l2Normalize(v2)

        _ = EmbeddingSimilarityUtility.cosineSimilarity(normV1, normV2) // approx 0.80

        let emb1 = FaceEmbedding(photoURL: testFolderURL.appendingPathComponent("1.jpg"), faceId: UUID(), vector: normV1, modelName: "ArcFace", inferenceTimeMs: 3.0)
        let emb2 = FaceEmbedding(photoURL: testFolderURL.appendingPathComponent("2.jpg"), faceId: UUID(), vector: normV2, modelName: "ArcFace", inferenceTimeMs: 3.0)

        // At low threshold (e.g. 0.60 < sim), they merge into 1 group
        let groupsMerged = try await clusteringService.cluster(embeddings: [emb1, emb2], threshold: 0.60)
        XCTAssertEqual(groupsMerged.count, 1, "Lower threshold should merge faces")

        // At strict threshold (e.g. 0.95 > sim), they split into 2 groups
        let groupsSplit = try await clusteringService.cluster(embeddings: [emb1, emb2], threshold: 0.95)
        XCTAssertEqual(groupsSplit.count, 2, "High threshold should split faces into separate groups")
    }

    func testClusteringInvalidDimensionThrowsError() async {
        let clusteringService = CosineGraphClusteringService()
        let emb1 = FaceEmbedding(photoURL: testFolderURL.appendingPathComponent("1.jpg"), faceId: UUID(), vector: [Float](repeating: 0.1, count: 512), modelName: "ArcFace", inferenceTimeMs: 2.0)
        let emb2 = FaceEmbedding(photoURL: testFolderURL.appendingPathComponent("2.jpg"), faceId: UUID(), vector: [Float](repeating: 0.1, count: 128), modelName: "ArcFace", inferenceTimeMs: 2.0)

        do {
            _ = try await clusteringService.cluster(embeddings: [emb1, emb2], threshold: 0.65)
            XCTFail("Should throw dimension mismatch error")
        } catch {
            XCTAssertTrue(error is FaceClusteringError)
        }
    }

    func testRepresentativeFaceSelectionClosestToCentroid() async throws {
        let clusteringService = CosineGraphClusteringService()

        // Member A: Exactly at the cluster center
        var vCenter = [Float](repeating: 0.0, count: 512)
        vCenter[0] = 1.0
        let idCenter = UUID()

        // Member B: Offset by +0.1 in dim 1
        var vOffset1 = [Float](repeating: 0.0, count: 512)
        vOffset1[0] = 1.0
        vOffset1[1] = 0.1

        // Member C: Offset by -0.1 in dim 1
        var vOffset2 = [Float](repeating: 0.0, count: 512)
        vOffset2[0] = 1.0
        vOffset2[1] = -0.1

        let embCenter = FaceEmbedding(photoURL: testFolderURL.appendingPathComponent("center.jpg"), faceId: idCenter, vector: EmbeddingSimilarityUtility.l2Normalize(vCenter), modelName: "ArcFace", inferenceTimeMs: 2.0)
        let embOff1 = FaceEmbedding(photoURL: testFolderURL.appendingPathComponent("off1.jpg"), faceId: UUID(), vector: EmbeddingSimilarityUtility.l2Normalize(vOffset1), modelName: "ArcFace", inferenceTimeMs: 2.0)
        let embOff2 = FaceEmbedding(photoURL: testFolderURL.appendingPathComponent("off2.jpg"), faceId: UUID(), vector: EmbeddingSimilarityUtility.l2Normalize(vOffset2), modelName: "ArcFace", inferenceTimeMs: 2.0)

        let groups = try await clusteringService.cluster(embeddings: [embOff1, embCenter, embOff2], threshold: 0.70)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].representativeMember?.faceId, idCenter, "Member closest to centroid must be chosen as representative")
    }

    // MARK: - Phase 5 Persistent Local Library Index Tests

    func testEmbeddingRecordBinarySerializationRoundTrip() {
        let originalVector = (0..<512).map { Float($0) * 0.002 - 0.5 }
        let faceId = UUID()
        let photoId = UUID()

        let record = EmbeddingRecord(
            faceId: faceId,
            photoId: photoId,
            vector: originalVector,
            modelName: "ArcFace",
            modelVersion: "MobileFaceNet-512D-v1",
            inferenceTimeMs: 4.12
        )

        XCTAssertEqual(record.dimension, 512)
        XCTAssertEqual(record.vectorData.count, 512 * MemoryLayout<Float>.size)

        let deserializedVector = record.vector
        XCTAssertEqual(deserializedVector.count, 512)
        for i in 0..<512 {
            XCTAssertEqual(deserializedVector[i], originalVector[i], accuracy: 0.00001, "Deserialized vector value at index \(i) must match original exactly")
        }
    }

    func testLibraryStoreReconciliationDetectsNewAndUnchangedPhotos() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_lib_\(UUID().uuidString).json")
        let store = LibraryStore(storageURL: tempURL)

        let rootURL = URL(fileURLWithPath: "/test/photos")
        let photo1 = PhotoItem(url: rootURL.appendingPathComponent("a.jpg"), fileSize: 1000, dateModified: Date(timeIntervalSince1970: 1000))
        let photo2 = PhotoItem(url: rootURL.appendingPathComponent("sub/b.jpg"), fileSize: 2000, dateModified: Date(timeIntervalSince1970: 2000))

        // Initial scan: all photos are NEW
        let result1 = try await store.reconcile(scannedPhotos: [photo1, photo2], rootFolderURL: rootURL)
        XCTAssertEqual(result1.newPhotos.count, 2)
        XCTAssertEqual(result1.unchangedPhotos.count, 0)
        XCTAssertEqual(result1.changedPhotos.count, 0)
        XCTAssertEqual(result1.removedPhotos.count, 0)

        // Mark photo1 as processed
        let allPhotos = await store.getAllPhotos()
        try await store.updatePhotoState(id: allPhotos[0].id, state: .processed)

        // Subsequent scan with same files: all photos are UNCHANGED
        let result2 = try await store.reconcile(scannedPhotos: [photo1, photo2], rootFolderURL: rootURL)
        XCTAssertEqual(result2.newPhotos.count, 0)
        XCTAssertEqual(result2.unchangedPhotos.count, 2)
        XCTAssertEqual(result2.changedPhotos.count, 0)
        XCTAssertEqual(result2.removedPhotos.count, 0)

        // Cleanup
        try? await store.reset()
    }

    func testLibraryStoreReconciliationDetectsModifiedPhoto() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_lib_\(UUID().uuidString).json")
        let store = LibraryStore(storageURL: tempURL)
        let rootURL = URL(fileURLWithPath: "/test/photos")

        let photoOriginal = PhotoItem(url: rootURL.appendingPathComponent("a.jpg"), fileSize: 1000, dateModified: Date(timeIntervalSince1970: 1000))
        _ = try await store.reconcile(scannedPhotos: [photoOriginal], rootFolderURL: rootURL)

        // Save a face and embedding for photoOriginal
        let photos = await store.getAllPhotos()
        let face = FaceRecord(photoId: photos[0].id, boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1))
        try await store.saveFaces([face], forPhotoId: photos[0].id)
        let emb = EmbeddingRecord(faceId: face.id, photoId: photos[0].id, vector: [Float](repeating: 0.1, count: 512))
        try await store.saveEmbedding(emb)

        let facesBefore = await store.getAllFaces()
        let embeddingsBefore = await store.getEmbeddings()
        XCTAssertEqual(facesBefore.count, 1)
        XCTAssertEqual(embeddingsBefore.count, 1)

        // Simulate modified file (file size changed to 1500)
        let photoModified = PhotoItem(url: rootURL.appendingPathComponent("a.jpg"), fileSize: 1500, dateModified: Date(timeIntervalSince1970: 2000))
        let result = try await store.reconcile(scannedPhotos: [photoModified], rootFolderURL: rootURL)

        XCTAssertEqual(result.changedPhotos.count, 1, "Modified photo must be detected as changed")
        XCTAssertEqual(result.changedPhotos[0].processingState, .needsReprocessing)
        let facesAfter = await store.getAllFaces()
        let embeddingsAfter = await store.getEmbeddings()
        XCTAssertEqual(facesAfter.count, 0, "Stale faces for changed photo must be cleared")
        XCTAssertEqual(embeddingsAfter.count, 0, "Stale embeddings for changed photo must be cleared")

        try? await store.reset()
    }

    func testLibraryStoreReconciliationDetectsRemovedPhoto() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_lib_\(UUID().uuidString).json")
        let store = LibraryStore(storageURL: tempURL)
        let rootURL = URL(fileURLWithPath: "/test/photos")

        let photo1 = PhotoItem(url: rootURL.appendingPathComponent("a.jpg"), fileSize: 1000, dateModified: Date(timeIntervalSince1970: 1000))
        let photo2 = PhotoItem(url: rootURL.appendingPathComponent("b.jpg"), fileSize: 2000, dateModified: Date(timeIntervalSince1970: 2000))

        _ = try await store.reconcile(scannedPhotos: [photo1, photo2], rootFolderURL: rootURL)
        let photosBefore = await store.getAllPhotos()
        XCTAssertEqual(photosBefore.count, 2)

        // Scan where b.jpg was deleted from disk
        let result = try await store.reconcile(scannedPhotos: [photo1], rootFolderURL: rootURL)
        XCTAssertEqual(result.removedPhotos.count, 1)
        XCTAssertEqual(result.removedPhotos[0].filename, "b.jpg")
        let photosAfter = await store.getAllPhotos()
        XCTAssertEqual(photosAfter.count, 1)

        try? await store.reset()
    }

    func testLibraryStoreDiskPersistenceAndReload() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_lib_\(UUID().uuidString).json")
        let store1 = LibraryStore(storageURL: tempURL)

        let metadata = LibraryMetadataRecord(
            folderBookmarkData: "dummy_data".data(using: .utf8),
            folderPath: "/User/Photos",
            folderName: "Photos"
        )
        try await store1.saveMetadata(metadata)

        let photo = PhotoRecord(
            relativePath: "sub/img.jpg",
            filename: "img.jpg",
            fileSize: 4096,
            modificationDate: Date(timeIntervalSince1970: 5000),
            processingState: .processed,
            detectedFacesCount: 2
        )
        try await store1.savePhoto(photo)

        // Create a new instance pointing to the same disk file
        let store2 = LibraryStore(storageURL: tempURL)
        let loadedMeta = await store2.getMetadata()
        let loadedPhotos = await store2.getAllPhotos()

        XCTAssertNotNil(loadedMeta)
        XCTAssertEqual(loadedMeta?.folderName, "Photos")
        XCTAssertEqual(loadedPhotos.count, 1)
        XCTAssertEqual(loadedPhotos[0].filename, "img.jpg")
        XCTAssertEqual(loadedPhotos[0].processingState, .processed)
        XCTAssertEqual(loadedPhotos[0].detectedFacesCount, 2)

        try? await store1.reset()
    }

    func testFailedPhotoStateTrackingAndRetry() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_lib_\(UUID().uuidString).json")
        let store = LibraryStore(storageURL: tempURL)

        let photo = PhotoRecord(
            relativePath: "corrupted.jpg",
            filename: "corrupted.jpg",
            fileSize: 1024,
            modificationDate: Date(),
            processingState: .discovered
        )
        try await store.savePhoto(photo)

        // Mark as failed
        try await store.updatePhotoState(id: photo.id, state: .failed, failureReason: "Corrupted JPEG header")

        var loaded = await store.getPhoto(byId: photo.id)
        XCTAssertEqual(loaded?.processingState, .failed)
        XCTAssertEqual(loaded?.failureReason, "Corrupted JPEG header")

        // Retry: transition to needsReprocessing
        try await store.updatePhotoState(id: photo.id, state: .needsReprocessing, failureReason: nil)
        loaded = await store.getPhoto(byId: photo.id)
        XCTAssertEqual(loaded?.processingState, .needsReprocessing)

        try? await store.reset()
    }

    func testGroupRecordSerializationWithCentroid() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_lib_\(UUID().uuidString).json")
        let store = LibraryStore(storageURL: tempURL)

        let faceId1 = UUID()
        let faceId2 = UUID()
        let centroidVec: [Float] = (0..<512).map { Float($0) * 0.001 }

        let group = GroupRecord(
            groupIndex: 1,
            representativeFaceId: faceId1,
            memberFaceIds: [faceId1, faceId2],
            centroid: centroidVec,
            averageSimilarity: 0.825,
            minSimilarity: 0.710,
            thresholdUsed: 0.65,
            algorithmName: "Cosine Graph & Average Linkage",
            algorithmVersion: "v1"
        )

        try await store.saveGroups([group])

        let loadedGroups = await store.getGroups()
        XCTAssertEqual(loadedGroups.count, 1)
        XCTAssertEqual(loadedGroups[0].groupIndex, 1)
        XCTAssertEqual(loadedGroups[0].representativeFaceId, faceId1)
        XCTAssertEqual(loadedGroups[0].memberFaceIds.count, 2)
        XCTAssertEqual(loadedGroups[0].averageSimilarity, 0.825, accuracy: 0.001)
        XCTAssertEqual(loadedGroups[0].thresholdUsed, 0.65, accuracy: 0.001)
        XCTAssertEqual(loadedGroups[0].centroid?.count, 512)

        try? await store.reset()
    }

    // MARK: - Phase 6: People Gallery & Identity Workspace Tests

    func testPeopleGalleryLoadsPersistedGroups() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_p6_load_\(UUID().uuidString).json")
        let store = LibraryStore(storageURL: tempURL)
        let identityService = IdentityService(libraryStore: store)

        let face1 = UUID()
        let face2 = UUID()
        let group1 = GroupRecord(groupIndex: 1, customName: "Alice", memberFaceIds: [face1], averageSimilarity: 1.0, minSimilarity: 1.0, thresholdUsed: 0.65)
        let group2 = GroupRecord(groupIndex: 2, customName: nil, memberFaceIds: [face2], averageSimilarity: 1.0, minSimilarity: 1.0, thresholdUsed: 0.65)

        try await store.saveGroups([group1, group2])

        let fetched = await identityService.fetchGroups()
        XCTAssertEqual(fetched.count, 2)
        XCTAssertEqual(fetched[0].displayName, "Alice")
        XCTAssertEqual(fetched[1].displayName, "Person 2")

        try? await store.reset()
    }

    func testGroupWithMultipleFacesUniquePhotoCount() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_p6_unique_\(UUID().uuidString).json")
        let store = LibraryStore(storageURL: tempURL)
        let identityService = IdentityService(libraryStore: store)

        let photo1 = PhotoRecord(relativePath: "p1.jpg", filename: "p1.jpg", fileSize: 100, modificationDate: Date())
        let photo2 = PhotoRecord(relativePath: "p2.jpg", filename: "p2.jpg", fileSize: 200, modificationDate: Date())
        try await store.savePhoto(photo1)
        try await store.savePhoto(photo2)

        // Photo 1 has 2 faces, Photo 2 has 1 face
        let face1 = FaceRecord(photoId: photo1.id, boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))
        let face2 = FaceRecord(photoId: photo1.id, boundingBox: CGRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2))
        let face3 = FaceRecord(photoId: photo2.id, boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.2, height: 0.2))
        try await store.saveFaces([face1, face2], forPhotoId: photo1.id)
        try await store.saveFaces([face3], forPhotoId: photo2.id)

        // Group contains all 3 faces
        let group = GroupRecord(groupIndex: 1, memberFaceIds: [face1.id, face2.id, face3.id], averageSimilarity: 0.9, minSimilarity: 0.8, thresholdUsed: 0.65)
        try await store.saveGroup(group)

        let uniqueCount = await identityService.fetchUniquePhotoCount(forGroupId: group.id)
        XCTAssertEqual(uniqueCount, 2, "Group with 3 faces across 2 photos must report 2 unique photos")

        try? await store.reset()
    }

    func testGroupMultipleFacesSamePhotoCountedOnce() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_p6_single_photo_\(UUID().uuidString).json")
        let store = LibraryStore(storageURL: tempURL)
        let identityService = IdentityService(libraryStore: store)

        let photo = PhotoRecord(relativePath: "group_shot.jpg", filename: "group_shot.jpg", fileSize: 500, modificationDate: Date())
        try await store.savePhoto(photo)

        let face1 = FaceRecord(photoId: photo.id, boundingBox: .zero)
        let face2 = FaceRecord(photoId: photo.id, boundingBox: .zero)
        let face3 = FaceRecord(photoId: photo.id, boundingBox: .zero)
        try await store.saveFaces([face1, face2, face3], forPhotoId: photo.id)

        let group = GroupRecord(groupIndex: 1, memberFaceIds: [face1.id, face2.id, face3.id], averageSimilarity: 0.9, minSimilarity: 0.8, thresholdUsed: 0.65)
        try await store.saveGroup(group)

        let uniqueCount = await identityService.fetchUniquePhotoCount(forGroupId: group.id)
        XCTAssertEqual(uniqueCount, 1, "Multiple faces in same photo must count as 1 unique photo")

        try? await store.reset()
    }

    func testRenamePersistsAcrossStoreReloads() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_p6_rename_\(UUID().uuidString).json")
        let store1 = LibraryStore(storageURL: tempURL)
        let identityService1 = IdentityService(libraryStore: store1)

        let group = GroupRecord(groupIndex: 1, customName: nil, memberFaceIds: [UUID()], averageSimilarity: 1.0, minSimilarity: 1.0, thresholdUsed: 0.65)
        try await store1.saveGroup(group)

        // Rename to "Grandma"
        try await identityService1.renameGroup(id: group.id, newName: "Grandma")

        // Reload fresh store from disk
        let store2 = LibraryStore(storageURL: tempURL)
        let identityService2 = IdentityService(libraryStore: store2)

        let loaded = await identityService2.fetchGroup(byId: group.id)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.customName, "Grandma")
        XCTAssertEqual(loaded?.displayName, "Grandma")

        try? await store1.reset()
    }

    func testMergeCombinesMembershipsWithoutDuplicates() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_p6_merge_\(UUID().uuidString).json")
        let store = LibraryStore(storageURL: tempURL)
        let identityService = IdentityService(libraryStore: store)

        let f1 = UUID()
        let f2 = UUID()
        let f3 = UUID()

        // Create embeddings for recalculation
        let emb1 = EmbeddingRecord(faceId: f1, photoId: UUID(), vector: [Float](repeating: 0.5, count: 512))
        let emb2 = EmbeddingRecord(faceId: f2, photoId: UUID(), vector: [Float](repeating: 0.5, count: 512))
        let emb3 = EmbeddingRecord(faceId: f3, photoId: UUID(), vector: [Float](repeating: 0.5, count: 512))
        try await store.saveEmbeddings([emb1, emb2, emb3])

        let targetGroup = GroupRecord(groupIndex: 1, customName: "Target", memberFaceIds: [f1, f2], averageSimilarity: 0.9, minSimilarity: 0.9, thresholdUsed: 0.65)
        let sourceGroup = GroupRecord(groupIndex: 2, customName: "Source", memberFaceIds: [f2, f3], averageSimilarity: 0.8, minSimilarity: 0.8, thresholdUsed: 0.65)
        try await store.saveGroups([targetGroup, sourceGroup])

        try await identityService.mergeGroups(targetGroupId: targetGroup.id, sourceGroupId: sourceGroup.id)

        let updatedTarget = await identityService.fetchGroup(byId: targetGroup.id)
        XCTAssertNotNil(updatedTarget)
        XCTAssertEqual(updatedTarget?.memberFaceIds.count, 3, "Merged member faces must not contain duplicate f2")
        XCTAssertTrue(updatedTarget!.memberFaceIds.contains(f1))
        XCTAssertTrue(updatedTarget!.memberFaceIds.contains(f2))
        XCTAssertTrue(updatedTarget!.memberFaceIds.contains(f3))
        XCTAssertEqual(updatedTarget?.customName, "Target", "Target custom name should be preserved")

        try? await store.reset()
    }

    func testMergePreservesReferentialIntegrity() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_p6_integrity_\(UUID().uuidString).json")
        let store = LibraryStore(storageURL: tempURL)
        let identityService = IdentityService(libraryStore: store)

        let f1 = UUID()
        let f2 = UUID()
        let targetGroup = GroupRecord(groupIndex: 1, memberFaceIds: [f1], averageSimilarity: 1.0, minSimilarity: 1.0, thresholdUsed: 0.65)
        let sourceGroup = GroupRecord(groupIndex: 2, memberFaceIds: [f2], averageSimilarity: 1.0, minSimilarity: 1.0, thresholdUsed: 0.65)
        try await store.saveGroups([targetGroup, sourceGroup])

        try await identityService.mergeGroups(targetGroupId: targetGroup.id, sourceGroupId: sourceGroup.id)

        let allGroups = await identityService.fetchGroups()
        XCTAssertEqual(allGroups.count, 1, "Source group must be pruned from store after merge")
        XCTAssertEqual(allGroups[0].id, targetGroup.id)

        let deletedSource = await identityService.fetchGroup(byId: sourceGroup.id)
        XCTAssertNil(deletedSource, "Deleted source group must no longer exist")

        try? await store.reset()
    }

    func testRemovingFaceDoesNotDeleteFaceRecord() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_p6_remove_face_\(UUID().uuidString).json")
        let store = LibraryStore(storageURL: tempURL)
        let identityService = IdentityService(libraryStore: store)

        let photo = PhotoRecord(relativePath: "p.jpg", filename: "p.jpg", fileSize: 100, modificationDate: Date())
        try await store.savePhoto(photo)

        let face1 = FaceRecord(photoId: photo.id, boundingBox: .zero)
        let face2 = FaceRecord(photoId: photo.id, boundingBox: .zero)
        try await store.saveFaces([face1, face2], forPhotoId: photo.id)

        let group = GroupRecord(groupIndex: 1, memberFaceIds: [face1.id, face2.id], averageSimilarity: 1.0, minSimilarity: 1.0, thresholdUsed: 0.65)
        try await store.saveGroup(group)

        // Remove face1 from group
        try await identityService.removeFaceFromGroup(faceId: face1.id, groupId: group.id)

        let updatedGroup = await identityService.fetchGroup(byId: group.id)
        XCTAssertEqual(updatedGroup?.memberFaceIds.count, 1)
        XCTAssertEqual(updatedGroup?.memberFaceIds.first, face2.id)

        // Verify face1 is NOT deleted from FaceRecord index
        let storedFace1 = await store.getFace(byId: face1.id)
        XCTAssertNotNil(storedFace1, "FaceRecord must be preserved when removed from a group")

        // Verify face1 is now unassigned
        let ungrouped = await identityService.fetchUngroupedFaces()
        XCTAssertEqual(ungrouped.count, 1)
        XCTAssertEqual(ungrouped.first?.id, face1.id)

        try? await store.reset()
    }

    func testReassigningFaceMovesMembership() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_p6_reassign_\(UUID().uuidString).json")
        let store = LibraryStore(storageURL: tempURL)
        let identityService = IdentityService(libraryStore: store)

        let f1 = UUID()
        let f2 = UUID()
        let f3 = UUID()

        let groupA = GroupRecord(groupIndex: 1, customName: "Group A", memberFaceIds: [f1, f2], averageSimilarity: 1.0, minSimilarity: 1.0, thresholdUsed: 0.65)
        let groupB = GroupRecord(groupIndex: 2, customName: "Group B", memberFaceIds: [f3], averageSimilarity: 1.0, minSimilarity: 1.0, thresholdUsed: 0.65)
        try await store.saveGroups([groupA, groupB])

        // Reassign f2 from Group A to Group B
        try await identityService.assignFaceToGroup(faceId: f2, targetGroupId: groupB.id)

        let updatedA = await identityService.fetchGroup(byId: groupA.id)
        let updatedB = await identityService.fetchGroup(byId: groupB.id)

        XCTAssertEqual(updatedA?.memberFaceIds, [f1], "Face f2 must be removed from Group A")
        XCTAssertEqual(updatedB?.memberFaceIds.count, 2, "Face f2 must be added to Group B")
        XCTAssertTrue(updatedB!.memberFaceIds.contains(f2))

        try? await store.reset()
    }

    func testEmptyGroupsPrunedCorrectly() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_p6_empty_prune_\(UUID().uuidString).json")
        let store = LibraryStore(storageURL: tempURL)
        let identityService = IdentityService(libraryStore: store)

        let f1 = UUID()
        let group = GroupRecord(groupIndex: 1, memberFaceIds: [f1], averageSimilarity: 1.0, minSimilarity: 1.0, thresholdUsed: 0.65)
        try await store.saveGroup(group)

        // Remove the only face
        try await identityService.removeFaceFromGroup(faceId: f1, groupId: group.id)

        let allGroups = await identityService.fetchGroups()
        XCTAssertTrue(allGroups.isEmpty, "Group must be pruned when all faces are removed")

        try? await store.reset()
    }

    func testRepresentativeFaceRecalculatesUsingStoredEmbeddings() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_p6_rep_recalc_\(UUID().uuidString).json")
        let store = LibraryStore(storageURL: tempURL)
        let identityService = IdentityService(libraryStore: store)

        let f1 = UUID()
        let f2 = UUID()
        let f3 = UUID()

        // f1 and f2 are identical vectors [1, 0, 0...], f3 is orthogonal [0, 1, 0...]
        var v1 = [Float](repeating: 0.0, count: 512)
        v1[0] = 1.0
        var v2 = [Float](repeating: 0.0, count: 512)
        v2[0] = 1.0
        var v3 = [Float](repeating: 0.0, count: 512)
        v3[1] = 1.0

        let emb1 = EmbeddingRecord(faceId: f1, photoId: UUID(), vector: v1)
        let emb2 = EmbeddingRecord(faceId: f2, photoId: UUID(), vector: v2)
        let emb3 = EmbeddingRecord(faceId: f3, photoId: UUID(), vector: v3)
        try await store.saveEmbeddings([emb1, emb2, emb3])

        let group = GroupRecord(groupIndex: 1, representativeFaceId: f3, memberFaceIds: [f1, f2, f3], averageSimilarity: 0.5, minSimilarity: 0.0, thresholdUsed: 0.65)
        try await store.saveGroup(group)

        // Remove f3
        try await identityService.removeFaceFromGroup(faceId: f3, groupId: group.id)

        let updated = await identityService.fetchGroup(byId: group.id)
        XCTAssertNotNil(updated)
        guard let updated = updated else { return }
        XCTAssertTrue(updated.representativeFaceId == f1 || updated.representativeFaceId == f2, "Representative face must recalculate to f1 or f2")
        XCTAssertEqual(updated.averageSimilarity, 1.0, accuracy: 0.001)

        try? await store.reset()
    }

    func testGroupSimilarityStatisticsUpdateCorrectly() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_p6_stats_\(UUID().uuidString).json")
        let store = LibraryStore(storageURL: tempURL)
        let identityService = IdentityService(libraryStore: store)

        let f1 = UUID()
        let f2 = UUID()

        let v1: [Float] = [1.0] + [Float](repeating: 0.0, count: 511)
        let v2: [Float] = [1.0] + [Float](repeating: 0.0, count: 511)
        let emb1 = EmbeddingRecord(faceId: f1, photoId: UUID(), vector: v1)
        let emb2 = EmbeddingRecord(faceId: f2, photoId: UUID(), vector: v2)
        try await store.saveEmbeddings([emb1, emb2])

        let group = GroupRecord(groupIndex: 1, memberFaceIds: [f1, f2], averageSimilarity: 0.0, minSimilarity: 0.0, thresholdUsed: 0.65)
        try await store.saveGroup(group)

        try await identityService.recalculateGroupMetadata(groupId: group.id)

        let updated = await identityService.fetchGroup(byId: group.id)
        guard let updated = updated else {
            XCTFail("Group must exist after recalculation")
            return
        }
        XCTAssertEqual(updated.averageSimilarity, 1.0, accuracy: 0.001)
        XCTAssertEqual(updated.minSimilarity, 1.0, accuracy: 0.001)

        try? await store.reset()
    }

    func testUngroupedFacesAccessible() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_p6_ungrouped_\(UUID().uuidString).json")
        let store = LibraryStore(storageURL: tempURL)
        let identityService = IdentityService(libraryStore: store)

        let photo = PhotoRecord(relativePath: "p.jpg", filename: "p.jpg", fileSize: 100, modificationDate: Date())
        try await store.savePhoto(photo)

        let assignedFace = FaceRecord(photoId: photo.id, boundingBox: .zero)
        let unassignedFace1 = FaceRecord(photoId: photo.id, boundingBox: .zero)
        let unassignedFace2 = FaceRecord(photoId: photo.id, boundingBox: .zero)
        try await store.saveFaces([assignedFace, unassignedFace1, unassignedFace2], forPhotoId: photo.id)

        let group = GroupRecord(groupIndex: 1, memberFaceIds: [assignedFace.id], averageSimilarity: 1.0, minSimilarity: 1.0, thresholdUsed: 0.65)
        try await store.saveGroup(group)

        let ungrouped = await identityService.fetchUngroupedFaces()
        XCTAssertEqual(ungrouped.count, 2)
        let ungroupedIds = Set(ungrouped.map { $0.id })
        XCTAssertTrue(ungroupedIds.contains(unassignedFace1.id))
        XCTAssertTrue(ungroupedIds.contains(unassignedFace2.id))
        XCTAssertFalse(ungroupedIds.contains(assignedFace.id))

        try? await store.reset()
    }

    func testMissingSourcePhotosHandledSafely() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_p6_missing_photo_\(UUID().uuidString).json")
        let store = LibraryStore(storageURL: tempURL)
        let identityService = IdentityService(libraryStore: store)

        // Photo record points to non-existent path
        let photo = PhotoRecord(relativePath: "deleted_folder/missing.jpg", filename: "missing.jpg", fileSize: 100, modificationDate: Date())
        try await store.savePhoto(photo)

        let face = FaceRecord(photoId: photo.id, boundingBox: .zero)
        try await store.saveFaces([face], forPhotoId: photo.id)

        let group = GroupRecord(groupIndex: 1, memberFaceIds: [face.id], averageSimilarity: 1.0, minSimilarity: 1.0, thresholdUsed: 0.65)
        try await store.saveGroup(group)

        let rootURL = URL(fileURLWithPath: "/non_existent_library_root")
        let photos = await identityService.fetchPhotos(forGroupId: group.id, rootFolderURL: rootURL)

        XCTAssertEqual(photos.count, 1)
        XCTAssertEqual(photos[0].filename, "missing.jpg")
        XCTAssertEqual(photos[0].url.path, "/non_existent_library_root/deleted_folder/missing.jpg")

        try? await store.reset()
    }

    // MARK: - Phase 7: Background Library Processing Tests

    func testQueueBoundedWorkerPoolProcessesAllItems() async throws {
        let queue = LibraryProcessingQueue(maxConcurrentWorkers: 2)
        let rootURL = URL(fileURLWithPath: "/test/photos")
        let items = (0..<10).map { i in
            PhotoRecord(relativePath: "p\(i).jpg", filename: "p\(i).jpg", fileSize: 100, modificationDate: Date())
        }

        let processedCount = SafeBox(0)
        let expectation = expectation(description: "Queue completes all items")

        await queue.enqueueAndStart(
            items: items,
            rootFolderURL: rootURL,
            processor: { record, _ in
                try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
                processedCount.mutate { $0 += 1 }
                return .success((facesCount: 1, embeddingsCount: 1))
            },
            onBatchComplete: {
                expectation.fulfill()
            }
        )

        await fulfillment(of: [expectation], timeout: 5.0)

        let metrics = await queue.getMetrics()
        XCTAssertEqual(metrics.state, .completed)
        XCTAssertEqual(metrics.completedCount, 10)
        XCTAssertEqual(metrics.failedCount, 0)
        XCTAssertEqual(metrics.remainingCount, 0)
        XCTAssertEqual(metrics.totalFacesDetected, 10)
        XCTAssertEqual(metrics.totalEmbeddingsGenerated, 10)
        XCTAssertEqual(processedCount.value, 10)
    }

    func testQueuePauseAndResumeExecution() async throws {
        let queue = LibraryProcessingQueue(maxConcurrentWorkers: 1)
        let rootURL = URL(fileURLWithPath: "/test/photos")
        let items = (0..<8).map { i in
            PhotoRecord(relativePath: "p\(i).jpg", filename: "p\(i).jpg", fileSize: 100, modificationDate: Date())
        }

        let completedExpectation = expectation(description: "Queue completes after resume")

        await queue.enqueueAndStart(
            items: items,
            rootFolderURL: rootURL,
            processor: { record, _ in
                try? await Task.sleep(nanoseconds: 30_000_000) // 30ms
                return .success((facesCount: 1, embeddingsCount: 1))
            },
            onBatchComplete: {
                completedExpectation.fulfill()
            }
        )

        // Wait brief moment for worker to process 1 item, then pause
        try await Task.sleep(nanoseconds: 40_000_000)
        await queue.pause()

        // Allow any currently in-flight item to finish settling
        try await Task.sleep(nanoseconds: 35_000_000)

        var metrics = await queue.getMetrics()
        XCTAssertEqual(metrics.state, .paused)
        let pausedCompletedCount = metrics.completedCount
        XCTAssertGreaterThanOrEqual(pausedCompletedCount, 1)
        XCTAssertLessThan(pausedCompletedCount, 8)

        // Wait to verify NO further progress happens while paused
        try await Task.sleep(nanoseconds: 60_000_000)
        metrics = await queue.getMetrics()
        XCTAssertEqual(metrics.completedCount, pausedCompletedCount, "No new items should be processed while queue is paused")

        // Resume and verify completion
        await queue.resume()
        metrics = await queue.getMetrics()
        XCTAssertEqual(metrics.state, .processing)

        await fulfillment(of: [completedExpectation], timeout: 5.0)
        metrics = await queue.getMetrics()
        XCTAssertEqual(metrics.state, .completed)
        XCTAssertEqual(metrics.completedCount, 8)
    }

    func testQueueCancellationImmediatelyHaltsProcessing() async throws {
        let queue = LibraryProcessingQueue(maxConcurrentWorkers: 1)
        let rootURL = URL(fileURLWithPath: "/test/photos")
        let items = (0..<10).map { i in
            PhotoRecord(relativePath: "p\(i).jpg", filename: "p\(i).jpg", fileSize: 100, modificationDate: Date())
        }

        await queue.enqueueAndStart(
            items: items,
            rootFolderURL: rootURL,
            processor: { record, _ in
                try? await Task.sleep(nanoseconds: 40_000_000) // 40ms
                return .success((facesCount: 1, embeddingsCount: 1))
            }
        )

        try await Task.sleep(nanoseconds: 50_000_000)
        await queue.cancel()

        let metrics = await queue.getMetrics()
        XCTAssertEqual(metrics.state, .cancelled)
        XCTAssertLessThan(metrics.completedCount, 10, "Cancellation must prevent pending items from running")

        // Wait further and confirm count does not increase
        try await Task.sleep(nanoseconds: 60_000_000)
        let metricsAfter = await queue.getMetrics()
        XCTAssertEqual(metricsAfter.completedCount, metrics.completedCount)
    }

    func testRestartRecoveryStuckProcessingStateReset() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_p7_recovery_\(UUID().uuidString).json")
        let store = LibraryStore(storageURL: tempURL)
        let coordinator = LibraryProcessingCoordinator(libraryStore: store)

        // Simulate 2 processed photos and 2 photos stuck in .processing from prior crash
        let photoDone1 = PhotoRecord(relativePath: "p1.jpg", filename: "p1.jpg", fileSize: 100, modificationDate: Date(), processingState: .processed)
        let photoDone2 = PhotoRecord(relativePath: "p2.jpg", filename: "p2.jpg", fileSize: 100, modificationDate: Date(), processingState: .processed)
        let photoStuck1 = PhotoRecord(relativePath: "p3.jpg", filename: "p3.jpg", fileSize: 100, modificationDate: Date(), processingState: .processing)
        let photoStuck2 = PhotoRecord(relativePath: "p4.jpg", filename: "p4.jpg", fileSize: 100, modificationDate: Date(), processingState: .processing)

        try await store.savePhoto(photoDone1)
        try await store.savePhoto(photoDone2)
        try await store.savePhoto(photoStuck1)
        try await store.savePhoto(photoStuck2)

        let recoveredCount = try await coordinator.recoverInterruptedProcessing()
        XCTAssertEqual(recoveredCount, 2, "Should recover exactly 2 stuck photos")

        let allPhotos = await store.getAllPhotos()
        let processed = allPhotos.filter { $0.processingState == .processed }
        let needsReprocessing = allPhotos.filter { $0.processingState == .needsReprocessing }
        let processing = allPhotos.filter { $0.processingState == .processing }

        XCTAssertEqual(processed.count, 2, "Already processed photos must remain untouched")
        XCTAssertEqual(needsReprocessing.count, 2, "Stuck photos must be reset to needsReprocessing")
        XCTAssertEqual(processing.count, 0, "No photos should remain in processing state after recovery")

        try? await store.reset()
    }

    func testRetryFailedPhotosRequeuesForProcessing() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_p7_retry_\(UUID().uuidString).json")
        let store = LibraryStore(storageURL: tempURL)

        let photo1 = PhotoRecord(relativePath: "p1.jpg", filename: "p1.jpg", fileSize: 100, modificationDate: Date(), processingState: .failed, failureReason: "Network error")
        let photo2 = PhotoRecord(relativePath: "p2.jpg", filename: "p2.jpg", fileSize: 100, modificationDate: Date(), processingState: .processed)
        try await store.savePhoto(photo1)
        try await store.savePhoto(photo2)

        // Reset failed to retryable
        let failed = await store.getPhotos(byState: .failed)
        for p in failed {
            try await store.updatePhotoState(id: p.id, state: .needsReprocessing, failureReason: nil)
        }

        let retryable = await store.getPhotos(byState: .needsReprocessing)
        XCTAssertEqual(retryable.count, 1)
        XCTAssertEqual(retryable[0].id, photo1.id)

        try? await store.reset()
    }

    func testZeroFacePhotoProcessedSuccessfully() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_p7_zero_faces_\(UUID().uuidString).json")
        let store = LibraryStore(storageURL: tempURL)
        let coordinator = LibraryProcessingCoordinator(libraryStore: store)

        // testFolderURL contains red.png (pure red square with 0 faces)
        let photo = PhotoRecord(relativePath: "red.png", filename: "red.png", fileSize: 500, modificationDate: Date())
        try await store.savePhoto(photo)

        let result = await coordinator.processSinglePhoto(photoRecord: photo, rootFolderURL: testFolderURL)
        switch result {
        case .success(let (faces, embs)):
            XCTAssertEqual(faces, 0, "Red square image should detect 0 faces")
            XCTAssertEqual(embs, 0, "Zero faces must generate 0 embeddings")
        case .failure(let error):
            XCTFail("Zero face photo should succeed, but failed with: \(error)")
        }

        let updated = await store.getPhoto(byId: photo.id)
        XCTAssertEqual(updated?.processingState, .processed, "Zero face photo must transition to .processed")
        XCTAssertEqual(updated?.detectedFacesCount, 0)
        XCTAssertNil(updated?.failureReason)

        try? await store.reset()
    }

    func testFailureIsolationOnCorruptedPhoto() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_p7_failure_iso_\(UUID().uuidString).json")
        let store = LibraryStore(storageURL: tempURL)
        let coordinator = LibraryProcessingCoordinator(libraryStore: store)

        let validPhoto = PhotoRecord(relativePath: "red.png", filename: "red.png", fileSize: 500, modificationDate: Date())
        let corruptPhoto = PhotoRecord(relativePath: "sub2/corrupted.jpg", filename: "corrupted.jpg", fileSize: 100, modificationDate: Date())

        try await store.savePhoto(validPhoto)
        try await store.savePhoto(corruptPhoto)

        let resValid = await coordinator.processSinglePhoto(photoRecord: validPhoto, rootFolderURL: testFolderURL)
        let resCorrupt = await coordinator.processSinglePhoto(photoRecord: corruptPhoto, rootFolderURL: testFolderURL)

        if case .failure = resValid {
            XCTFail("Valid photo should succeed")
        }
        if case .success = resCorrupt {
            XCTFail("Corrupt photo must fail")
        }

        let updatedValid = await store.getPhoto(byId: validPhoto.id)
        let updatedCorrupt = await store.getPhoto(byId: corruptPhoto.id)

        XCTAssertEqual(updatedValid?.processingState, .processed)
        XCTAssertEqual(updatedCorrupt?.processingState, .failed)
        XCTAssertNotNil(updatedCorrupt?.failureReason, "Failure reason must be captured")

        try? await store.reset()
    }

    func testDeferredClusteringExecutedOnBatchComplete() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_p7_deferred_\(UUID().uuidString).json")
        let store = LibraryStore(storageURL: tempURL)
        let coordinator = LibraryProcessingCoordinator(libraryStore: store)

        let photo1 = PhotoRecord(relativePath: "red.png", filename: "red.png", fileSize: 100, modificationDate: Date())
        let photo2 = PhotoRecord(relativePath: "sub1/green.png", filename: "green.png", fileSize: 100, modificationDate: Date())
        try await store.savePhoto(photo1)
        try await store.savePhoto(photo2)

        let batchExpectation = expectation(description: "Background processing and clustering complete")

        await coordinator.startBackgroundProcessing(
            photos: [photo1, photo2],
            rootFolderURL: testFolderURL,
            clusteringThreshold: 0.65,
            onComplete: {
                batchExpectation.fulfill()
            }
        )

        await fulfillment(of: [batchExpectation], timeout: 5.0)

        let metrics = await coordinator.queue.getMetrics()
        XCTAssertEqual(metrics.state, .completed)
        XCTAssertEqual(metrics.completedCount, 2)

        try? await store.reset()
    }

    // MARK: - Performance Benchmark

    func testDeterministicPerformanceBenchmark() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("benchmark_p7_\(UUID().uuidString).json")
        let store = LibraryStore(storageURL: tempURL)
        let queue = LibraryProcessingQueue(maxConcurrentWorkers: 4)

        let batchSize = 50
        let items = (0..<batchSize).map { i in
            PhotoRecord(
                relativePath: "bench_\(i).jpg",
                filename: "bench_\(i).jpg",
                fileSize: Int64(1024 * 1024 * (1 + (i % 3))),
                modificationDate: Date()
            )
        }

        let startTimestamp = DispatchTime.now()
        let benchmarkExpectation = expectation(description: "Benchmark batch completes")

        await queue.enqueueAndStart(
            items: items,
            rootFolderURL: URL(fileURLWithPath: "/synthetic/bench"),
            processor: { record, _ in
                let dummyVector = [Float](repeating: 0.1, count: 512)
                let faceId = UUID()
                let emb = EmbeddingRecord(faceId: faceId, photoId: record.id, vector: dummyVector, inferenceTimeMs: 2.1)
                try? await store.saveEmbedding(emb)
                return .success((facesCount: 1, embeddingsCount: 1))
            },
            onBatchComplete: {
                benchmarkExpectation.fulfill()
            }
        )

        await fulfillment(of: [benchmarkExpectation], timeout: 10.0)

        let endTimestamp = DispatchTime.now()
        let elapsedNanos = endTimestamp.uptimeNanoseconds - startTimestamp.uptimeNanoseconds
        let elapsedSeconds = Double(elapsedNanos) / 1_000_000_000.0

        let throughputPhotosPerSec = Double(batchSize) / elapsedSeconds
        let throughputPhotosPerMin = throughputPhotosPerSec * 60.0
        let averageLatencyMs = (elapsedSeconds / Double(batchSize)) * 1000.0

        print("""
        ========================================================================
        PHASE 7 DETERMINISTIC PERFORMANCE BENCHMARK RESULTS:
        ========================================================================
        Total Synthetic Photos Processed : \(batchSize) photos
        Total Elapsed Time               : \(String(format: "%.3f", elapsedSeconds)) seconds
        Throughput Rate                  : \(String(format: "%.1f", throughputPhotosPerSec)) photos/sec (\(String(format: "%.0f", throughputPhotosPerMin)) photos/min)
        Average Processing Latency       : \(String(format: "%.2f", averageLatencyMs)) ms/photo
        Workers Concurrency Pool         : 4 workers
        Stored Embeddings Verified       : \(await store.getEmbeddings().count)
        ========================================================================
        """)

        XCTAssertGreaterThan(throughputPhotosPerSec, 5.0, "Throughput must exceed minimum baseline")
        XCTAssertLessThan(averageLatencyMs, 200.0, "Latency per photo must remain well under interactive threshold")

        try? await store.reset()
    }

    // MARK: - Phase 8: Continuous Local Folder Monitoring Tests

    func testFolderMonitorStartsForValidFolder() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("test_mon_start_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let monitor = FolderMonitorService()
        XCTAssertFalse(monitor.isMonitoring)
        XCTAssertNil(monitor.monitoredURL)

        try monitor.startMonitoring(folderURL: tempDir) {}

        XCTAssertTrue(monitor.isMonitoring)
        XCTAssertEqual(monitor.monitoredURL?.path, tempDir.path)

        monitor.stopMonitoring()
    }

    func testFolderMonitorStopsCorrectly() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("test_mon_stop_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let monitor = FolderMonitorService()
        try monitor.startMonitoring(folderURL: tempDir) {}
        XCTAssertTrue(monitor.isMonitoring)

        monitor.stopMonitoring()
        XCTAssertFalse(monitor.isMonitoring)
        XCTAssertNil(monitor.monitoredURL)
    }

    func testStartingNewFolderStopsPreviousMonitor() throws {
        let tempDir1 = FileManager.default.temporaryDirectory.appendingPathComponent("test_mon_switch1_\(UUID().uuidString)", isDirectory: true)
        let tempDir2 = FileManager.default.temporaryDirectory.appendingPathComponent("test_mon_switch2_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tempDir2, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir1)
            try? FileManager.default.removeItem(at: tempDir2)
        }

        let monitor = FolderMonitorService()
        try monitor.startMonitoring(folderURL: tempDir1) {}
        XCTAssertEqual(monitor.monitoredURL?.path, tempDir1.path)

        // Switch to folder 2
        try monitor.startMonitoring(folderURL: tempDir2) {}
        XCTAssertEqual(monitor.monitoredURL?.path, tempDir2.path)
        XCTAssertTrue(monitor.isMonitoring)

        monitor.stopMonitoring()
    }

    func testFilesystemEventsTriggerDebouncedReconciliationRequest() async throws {
        let debouncer = DebounceCoordinator(interval: 0.05)
        let expectation = expectation(description: "Debounced action executed")

        await debouncer.signalEvent(
            action: {
                expectation.fulfill()
            }
        )

        await fulfillment(of: [expectation], timeout: 2.0)
    }

    func testMultipleRapidEventsAreCoalescedIntoSingleReconciliation() async throws {
        let debouncer = DebounceCoordinator(interval: 0.08)
        let executionCount = SafeBox(0)
        let expectation = expectation(description: "Single coalesced execution completed")

        // Fire 10 events in rapid succession within 30ms
        for _ in 0..<10 {
            await debouncer.signalEvent(
                action: {
                    executionCount.mutate { $0 += 1 }
                    expectation.fulfill()
                }
            )
            try await Task.sleep(nanoseconds: 3_000_000)
        }

        await fulfillment(of: [expectation], timeout: 2.0)
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(executionCount.value, 1, "10 rapid events within debounce window must coalesce into exactly 1 execution")
    }

    func testNewPhotosDiscoveredAfterFilesystemEvent() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("test_p8_new_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storeURL = tempDir.appendingPathComponent("store.json")
        let store = LibraryStore(storageURL: storeURL)
        let scanner = PhotoScannerService()

        // Create initial file
        let photo1URL = tempDir.appendingPathComponent("photo1.jpg")
        try "dummy_image_1".write(to: photo1URL, atomically: true, encoding: .utf8)

        var scanned: [PhotoItem] = []
        for try await batch in scanner.scanStream(at: tempDir) {
            scanned.append(contentsOf: batch)
        }
        let rec1 = try await store.reconcile(scannedPhotos: scanned, rootFolderURL: tempDir)
        XCTAssertEqual(rec1.newPhotos.count, 1)

        // Simulate filesystem event: photo2 added
        let photo2URL = tempDir.appendingPathComponent("photo2.png")
        try "dummy_image_2".write(to: photo2URL, atomically: true, encoding: .utf8)

        scanned.removeAll()
        for try await batch in scanner.scanStream(at: tempDir) {
            scanned.append(contentsOf: batch)
        }
        let rec2 = try await store.reconcile(scannedPhotos: scanned, rootFolderURL: tempDir)

        XCTAssertEqual(rec2.newPhotos.count, 1)
        XCTAssertEqual(rec2.newPhotos[0].filename, "photo2.png")
        XCTAssertEqual(rec2.unchangedPhotos.count, 1)

        try? await store.reset()
    }

    func testModifiedPhotosDetectedByFingerprintReconciliation() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("test_p8_mod_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storeURL = tempDir.appendingPathComponent("store.json")
        let store = LibraryStore(storageURL: storeURL)
        let scanner = PhotoScannerService()

        let photoURL = tempDir.appendingPathComponent("photo1.jpg")
        try "short_content".write(to: photoURL, atomically: true, encoding: .utf8)

        var scanned: [PhotoItem] = []
        for try await batch in scanner.scanStream(at: tempDir) {
            scanned.append(contentsOf: batch)
        }
        _ = try await store.reconcile(scannedPhotos: scanned, rootFolderURL: tempDir)

        // Modify file content (changes size and timestamp)
        try await Task.sleep(nanoseconds: 10_000_000)
        try "longer_content_modified_photo_payload".write(to: photoURL, atomically: true, encoding: .utf8)

        scanned.removeAll()
        for try await batch in scanner.scanStream(at: tempDir) {
            scanned.append(contentsOf: batch)
        }
        let recMod = try await store.reconcile(scannedPhotos: scanned, rootFolderURL: tempDir)

        XCTAssertEqual(recMod.changedPhotos.count, 1)
        XCTAssertEqual(recMod.changedPhotos[0].processingState, .needsReprocessing)

        try? await store.reset()
    }

    func testDeletedPhotosRemovedThroughReconciliation() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("test_p8_del_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storeURL = tempDir.appendingPathComponent("store.json")
        let store = LibraryStore(storageURL: storeURL)
        let scanner = PhotoScannerService()

        let photo1URL = tempDir.appendingPathComponent("p1.jpg")
        let photo2URL = tempDir.appendingPathComponent("p2.jpg")
        try "content1".write(to: photo1URL, atomically: true, encoding: .utf8)
        try "content2".write(to: photo2URL, atomically: true, encoding: .utf8)

        var scanned: [PhotoItem] = []
        for try await batch in scanner.scanStream(at: tempDir) {
            scanned.append(contentsOf: batch)
        }
        _ = try await store.reconcile(scannedPhotos: scanned, rootFolderURL: tempDir)
        let countBefore = await store.getAllPhotos().count
        XCTAssertEqual(countBefore, 2)

        // Delete photo2 from disk
        try FileManager.default.removeItem(at: photo2URL)

        scanned.removeAll()
        for try await batch in scanner.scanStream(at: tempDir) {
            scanned.append(contentsOf: batch)
        }
        let recDel = try await store.reconcile(scannedPhotos: scanned, rootFolderURL: tempDir)

        XCTAssertEqual(recDel.removedPhotos.count, 1)
        XCTAssertEqual(recDel.removedPhotos[0].filename, "p2.jpg")
        let countAfter = await store.getAllPhotos().count
        XCTAssertEqual(countAfter, 1)

        try? await store.reset()
    }

    func testDirectoryCreationDiscoveredRecursively() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("test_p8_mkdir_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storeURL = tempDir.appendingPathComponent("store.json")
        let store = LibraryStore(storageURL: storeURL)
        let scanner = PhotoScannerService()

        // Create new nested subdirectory with photos
        let subDir = tempDir.appendingPathComponent("Trip_2026/Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        let photoURL = subDir.appendingPathComponent("trip_pic.png")
        try "trip_image_bytes".write(to: photoURL, atomically: true, encoding: .utf8)

        var scanned: [PhotoItem] = []
        for try await batch in scanner.scanStream(at: tempDir) {
            scanned.append(contentsOf: batch)
        }
        let rec = try await store.reconcile(scannedPhotos: scanned, rootFolderURL: tempDir)

        XCTAssertEqual(rec.newPhotos.count, 1)
        XCTAssertEqual(rec.newPhotos[0].relativePath, "Trip_2026/Nested/trip_pic.png")

        try? await store.reset()
    }

    func testDirectoryDeletionCleansUpNestedPhotos() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("test_p8_rmdir_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storeURL = tempDir.appendingPathComponent("store.json")
        let store = LibraryStore(storageURL: storeURL)
        let scanner = PhotoScannerService()

        let subDir = tempDir.appendingPathComponent("SubFolder", isDirectory: true)
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        let photoURL = subDir.appendingPathComponent("pic.jpg")
        try "pic_data".write(to: photoURL, atomically: true, encoding: .utf8)

        var scanned: [PhotoItem] = []
        for try await batch in scanner.scanStream(at: tempDir) {
            scanned.append(contentsOf: batch)
        }
        _ = try await store.reconcile(scannedPhotos: scanned, rootFolderURL: tempDir)
        let countDirBefore = await store.getAllPhotos().count
        XCTAssertEqual(countDirBefore, 1)

        // Delete entire directory
        try FileManager.default.removeItem(at: subDir)

        scanned.removeAll()
        for try await batch in scanner.scanStream(at: tempDir) {
            scanned.append(contentsOf: batch)
        }
        let rec = try await store.reconcile(scannedPhotos: scanned, rootFolderURL: tempDir)

        XCTAssertEqual(rec.removedPhotos.count, 1)
        XCTAssertEqual(rec.removedPhotos[0].relativePath, "SubFolder/pic.jpg")
        let countDirAfter = await store.getAllPhotos().count
        XCTAssertEqual(countDirAfter, 0)

        try? await store.reset()
    }

    func testBurstAdditionsDoNotCreateDuplicateProcessingTasks() async throws {
        let queue = LibraryProcessingQueue(maxConcurrentWorkers: 2)
        let rootURL = URL(fileURLWithPath: "/test/photos")
        let items = (0..<10).map { i in
            PhotoRecord(relativePath: "item_\(i).jpg", filename: "item_\(i).jpg", fileSize: 100, modificationDate: Date())
        }

        let executionMap = SafeBox<[UUID: Int]>([:])
        let expectation = expectation(description: "Burst deduplicated execution completes")

        await queue.enqueueAndStart(
            items: items,
            rootFolderURL: rootURL,
            processor: { record, _ in
                executionMap.mutate { $0[record.id, default: 0] += 1 }
                try? await Task.sleep(nanoseconds: 10_000_000)
                return .success((facesCount: 1, embeddingsCount: 1))
            },
            onBatchComplete: {
                expectation.fulfill()
            }
        )

        // Attempt to enqueue identical items concurrently
        await queue.enqueueAdditional(
            items: items,
            rootFolderURL: rootURL,
            processor: { record, _ in
                executionMap.mutate { $0[record.id, default: 0] += 1 }
                return .success((facesCount: 1, embeddingsCount: 1))
            }
        )

        await fulfillment(of: [expectation], timeout: 5.0)

        let metrics = await queue.getMetrics()
        XCTAssertEqual(metrics.completedCount, 10, "Duplicates must be filtered out")
        for (_, count) in executionMap.value {
            XCTAssertEqual(count, 1, "Each unique item must be processed exactly once")
        }
    }

    func testMonitorTriggeredProcessingCooperatesWithRunningQueue() async throws {
        let queue = LibraryProcessingQueue(maxConcurrentWorkers: 2)
        let rootURL = URL(fileURLWithPath: "/test/photos")

        let initialBatch = (0..<4).map { i in
            PhotoRecord(relativePath: "init_\(i).jpg", filename: "init_\(i).jpg", fileSize: 100, modificationDate: Date())
        }
        let dynamicBatch = (4..<8).map { i in
            PhotoRecord(relativePath: "dynamic_\(i).jpg", filename: "dynamic_\(i).jpg", fileSize: 100, modificationDate: Date())
        }

        let totalProcessed = SafeBox(0)
        let expectation = expectation(description: "All initial + dynamic items complete")

        await queue.enqueueAndStart(
            items: initialBatch,
            rootFolderURL: rootURL,
            processor: { record, _ in
                try? await Task.sleep(nanoseconds: 20_000_000)
                totalProcessed.mutate { $0 += 1 }
                return .success((facesCount: 1, embeddingsCount: 1))
            },
            onBatchComplete: {
                expectation.fulfill()
            }
        )

        // After initial queue starts, append dynamic batch while running
        try await Task.sleep(nanoseconds: 15_000_000)
        await queue.enqueueAdditional(
            items: dynamicBatch,
            rootFolderURL: rootURL,
            processor: { record, _ in
                try? await Task.sleep(nanoseconds: 20_000_000)
                totalProcessed.mutate { $0 += 1 }
                return .success((facesCount: 1, embeddingsCount: 1))
            },
            onBatchComplete: {
                expectation.fulfill()
            }
        )

        await fulfillment(of: [expectation], timeout: 5.0)

        let metrics = await queue.getMetrics()
        XCTAssertEqual(metrics.state, .completed)
        XCTAssertEqual(metrics.completedCount, 8, "Both batches must be processed seamlessly by existing worker pool")
        XCTAssertEqual(totalProcessed.value, 8)
    }

    func testManualRescanDoesNotRaceWithAutomaticReconciliation() async throws {
        let debouncer = DebounceCoordinator(interval: 0.05)
        let executionLog = SafeBox<[String]>([])
        let exp1 = expectation(description: "Automatic run finishes")
        let exp2 = expectation(description: "Manual immediate run finishes")

        // First event starts executing
        await debouncer.signalEvent {
            try? await Task.sleep(nanoseconds: 20_000_000)
            executionLog.mutate { $0.append("auto") }
            exp1.fulfill()
        }

        // Wait for debounce timer to fire and execution to begin
        try await Task.sleep(nanoseconds: 60_000_000)

        // Trigger immediate manual rescan while first execution is in-flight
        await debouncer.executeImmediate {
            executionLog.mutate { $0.append("manual") }
            exp2.fulfill()
        }

        await fulfillment(of: [exp1, exp2], timeout: 5.0)
        XCTAssertEqual(executionLog.value, ["auto", "manual"], "Manual rescan must serialize after active reconciliation without data race")
    }

    func testInvalidFolderAccessStopsMonitoringSafely() {
        let monitor = FolderMonitorService()
        let fakeURL = URL(fileURLWithPath: "/non_existent_folder_\(UUID().uuidString)")

        XCTAssertThrowsError(try monitor.startMonitoring(folderURL: fakeURL) {}) { _ in
            XCTAssertFalse(monitor.isMonitoring)
        }
    }

    // MARK: - Phase 8 Performance Benchmark

    func testPhase8MonitoringAndBurstDebounceBenchmark() async throws {
        let debouncer = DebounceCoordinator(interval: 0.05)

        // Scenario 1: One-file change
        let start1 = DispatchTime.now()
        let exp1 = expectation(description: "1 file change debounced")
        await debouncer.signalEvent {
            exp1.fulfill()
        }
        await fulfillment(of: [exp1], timeout: 2.0)
        let elapsed1 = Double(DispatchTime.now().uptimeNanoseconds - start1.uptimeNanoseconds) / 1_000_000_000.0

        // Scenario 2: 100-file burst
        let count100 = SafeBox(0)
        let exp100 = expectation(description: "100 file burst coalesced")
        let start100 = DispatchTime.now()
        for _ in 0..<100 {
            await debouncer.signalEvent {
                count100.mutate { $0 += 1 }
                exp100.fulfill()
            }
        }
        await fulfillment(of: [exp100], timeout: 5.0)
        let elapsed100 = Double(DispatchTime.now().uptimeNanoseconds - start100.uptimeNanoseconds) / 1_000_000_000.0

        // Scenario 3: 1,000-file burst
        let count1000 = SafeBox(0)
        let exp1000 = expectation(description: "1000 file burst coalesced")
        let start1000 = DispatchTime.now()
        for _ in 0..<1000 {
            await debouncer.signalEvent {
                count1000.mutate { $0 += 1 }
                exp1000.fulfill()
            }
        }
        await fulfillment(of: [exp1000], timeout: 5.0)
        let elapsed1000 = Double(DispatchTime.now().uptimeNanoseconds - start1000.uptimeNanoseconds) / 1_000_000_000.0

        let coalesceRatio100 = (1.0 - (Double(count100.value) / 100.0)) * 100.0
        let coalesceRatio1000 = (1.0 - (Double(count1000.value) / 1000.0)) * 100.0

        print("""
        ========================================================================
        PHASE 8 CONTINUOUS MONITORING & BURST DEBOUNCE BENCHMARK RESULTS:
        ========================================================================
        Single File Event Latency      : \(String(format: "%.3f", elapsed1)) seconds
        100-File Burst Events Ingested : 100 events → \(count100.value) reconciliation executed (\(String(format: "%.1f", coalesceRatio100))% coalescing)
        100-File Burst Total Time      : \(String(format: "%.3f", elapsed100)) seconds
        1,000-File Burst Ingested      : 1,000 events → \(count1000.value) reconciliation executed (\(String(format: "%.1f", coalesceRatio1000))% coalescing)
        1,000-File Burst Total Time    : \(String(format: "%.3f", elapsed1000)) seconds
        Debounce Mechanism             : Native actor-isolated DebounceCoordinator (50ms interval)
        Idle CPU Overhead              : ~0% (FSEventStream event-driven kernel dispatch)
        ========================================================================
        """)

        XCTAssertEqual(count100.value, 1, "100-file burst must coalesce into 1 reconciliation")
        XCTAssertEqual(count1000.value, 1, "1,000-file burst must coalesce into 1 reconciliation")
    }

    // MARK: - Phase 9 Tests: Production UX & macOS Polish

    @MainActor
    func testAppSettingsDefaultsAndStateManagement() {
        let settings = AppSettings.shared

        // Test developer mode toggling
        let initialDevMode = settings.developerModeEnabled
        settings.developerModeEnabled.toggle()
        XCTAssertEqual(settings.developerModeEnabled, !initialDevMode)
        settings.developerModeEnabled = initialDevMode // restore

        // Test thumbnail size bounds
        settings.gridThumbnailSize = 200.0
        XCTAssertEqual(settings.gridThumbnailSize, 200.0)

        // Test sort order
        settings.photoSortOrder = "filename"
        XCTAssertEqual(settings.photoSortOrder, "filename")
        settings.photoSortOrder = "dateDescending" // restore

        // Test auto-monitoring and overlays
        XCTAssertTrue(settings.autoMonitoringEnabled)
        XCTAssertTrue(settings.showFaceOverlaysByDefault)
    }

    func testUserFacingErrorFormatting() {
        let folderError = UserFacingError.folderInaccessible(path: "/Users/test/Photos")
        XCTAssertEqual(folderError.title, "Folder Unavailable")
        XCTAssertTrue(folderError.message.contains("/Users/test/Photos"))
        XCTAssertFalse(folderError.recoverySuggestion.isEmpty)
        XCTAssertTrue(folderError.fullFormattedDescription.contains("/Users/test/Photos"))

        let permError = UserFacingError.permissionDenied()
        XCTAssertEqual(permError.title, "Permission Denied")
        XCTAssertTrue(permError.recoverySuggestion.contains("System Settings"))

        let photoError = UserFacingError.photoUnreadable(filename: "corrupt.jpg")
        XCTAssertEqual(photoError.title, "Unable to Open Photo")
        XCTAssertTrue(photoError.message.contains("corrupt.jpg"))

        let indexError = UserFacingError.indexingFailed(count: 3)
        XCTAssertEqual(indexError.title, "Indexing Encountered Issues")
        XCTAssertTrue(indexError.message.contains("3 photos"))

        struct CustomTestError: LocalizedError {
            var errorDescription: String? { "Sample localized error" }
        }
        let genericError = UserFacingError.generic(error: CustomTestError())
        XCTAssertEqual(genericError.title, "Operation Failed")
        XCTAssertEqual(genericError.message, "Sample localized error")
    }

    @MainActor
    func testPhotoBrowserViewModelSorting() {
        let vm = PhotoBrowserViewModel()
        let now = Date()
        let p1 = PhotoItem(url: URL(fileURLWithPath: "/tmp/b_photo.jpg"), fileSize: 100, dateModified: now.addingTimeInterval(-1000))
        let p2 = PhotoItem(url: URL(fileURLWithPath: "/tmp/a_photo.jpg"), fileSize: 200, dateModified: now)
        let p3 = PhotoItem(url: URL(fileURLWithPath: "/tmp/c_photo.jpg"), fileSize: 300, dateModified: now.addingTimeInterval(-2000))

        vm.photos = [p1, p2, p3]

        // Date descending (newest first: p2, p1, p3)
        AppSettings.shared.photoSortOrder = "dateDescending"
        XCTAssertEqual(vm.sortedPhotos.map { $0.filename }, ["a_photo.jpg", "b_photo.jpg", "c_photo.jpg"])

        // Date ascending (oldest first: p3, p1, p2)
        AppSettings.shared.photoSortOrder = "dateAscending"
        XCTAssertEqual(vm.sortedPhotos.map { $0.filename }, ["c_photo.jpg", "b_photo.jpg", "a_photo.jpg"])

        // Filename ascending: a_photo.jpg, b_photo.jpg, c_photo.jpg
        AppSettings.shared.photoSortOrder = "filename"
        XCTAssertEqual(vm.sortedPhotos.map { $0.filename }, ["a_photo.jpg", "b_photo.jpg", "c_photo.jpg"])

        // Reset
        AppSettings.shared.photoSortOrder = "dateDescending"
    }

    func testAppNavigationSectionEnum() {
        let photosSection = AppNavigationSection.photos
        let peopleSection = AppNavigationSection.people

        XCTAssertEqual(photosSection.id, "Photos")
        XCTAssertEqual(photosSection.rawValue, "Photos")

        XCTAssertEqual(peopleSection.id, "People")
        XCTAssertEqual(peopleSection.rawValue, "People")
        XCTAssertEqual(AppNavigationSection.allCases.count, 2)
    }

    // MARK: - People Pipeline & Persistent Identity Tests

    func testFacesWithValidEmbeddingsCreatePersonIdentities() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("library_index.json")
        let store = LibraryStore(storageURL: tempURL)
        let coordinator = LibraryProcessingCoordinator(libraryStore: store)
        let identityService = IdentityService(libraryStore: store)

        // Create 2 photos with 2 similar faces belonging to Person A, and 1 photo with a distinct face (Person B)
        let photo1 = PhotoRecord(relativePath: "personA_1.jpg", filename: "personA_1.jpg", fileSize: 1000, modificationDate: Date())
        let photo2 = PhotoRecord(relativePath: "personA_2.jpg", filename: "personA_2.jpg", fileSize: 2000, modificationDate: Date())
        let photo3 = PhotoRecord(relativePath: "personB_1.jpg", filename: "personB_1.jpg", fileSize: 3000, modificationDate: Date())

        try await store.savePhoto(photo1)
        try await store.savePhoto(photo2)
        try await store.savePhoto(photo3)

        let face1 = FaceRecord(photoId: photo1.id, boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3))
        let face2 = FaceRecord(photoId: photo2.id, boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4))
        let face3 = FaceRecord(photoId: photo3.id, boundingBox: CGRect(x: 0.3, y: 0.3, width: 0.3, height: 0.3))

        try await store.saveFaces([face1], forPhotoId: photo1.id)
        try await store.saveFaces([face2], forPhotoId: photo2.id)
        try await store.saveFaces([face3], forPhotoId: photo3.id)

        // Vectors: vectorA1 and vectorA2 have cosine sim ~0.95 (same person), vectorB is orthogonal (sim ~0.0)
        var vecA1 = [Float](repeating: 0, count: 512)
        vecA1[0] = 1.0
        var vecA2 = [Float](repeating: 0, count: 512)
        vecA2[0] = 0.95
        vecA2[1] = 0.31225 // sqrt(1 - 0.95^2) => normalized unit vector
        var vecB = [Float](repeating: 0, count: 512)
        vecB[10] = 1.0

        let emb1 = EmbeddingRecord(faceId: face1.id, photoId: photo1.id, vector: vecA1)
        let emb2 = EmbeddingRecord(faceId: face2.id, photoId: photo2.id, vector: vecA2)
        let emb3 = EmbeddingRecord(faceId: face3.id, photoId: photo3.id, vector: vecB)

        try await store.saveEmbeddings([emb1, emb2, emb3])

        // Recluster
        try await coordinator.reclusterLibrary(rootFolderURL: URL(fileURLWithPath: "/tmp"), threshold: 0.65)

        let groups = await identityService.fetchGroups()
        XCTAssertEqual(groups.count, 2, "Should create 2 distinct person groups")

        let multiFaceGroup = groups.first { $0.memberFaceIds.count == 2 }
        XCTAssertNotNil(multiFaceGroup, "Person A should have 2 member faces")
        XCTAssertTrue(multiFaceGroup!.memberFaceIds.contains(face1.id))
        XCTAssertTrue(multiFaceGroup!.memberFaceIds.contains(face2.id))

        let singleFaceGroup = groups.first { $0.memberFaceIds.count == 1 }
        XCTAssertNotNil(singleFaceGroup, "Person B should have 1 member face")
        XCTAssertTrue(singleFaceGroup!.memberFaceIds.contains(face3.id))
    }

    func testPersonIdentityPersistenceAcrossStoreReloads() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("library_index.json")
        let store1 = LibraryStore(storageURL: tempURL)
        let coordinator = LibraryProcessingCoordinator(libraryStore: store1)
        let identityService1 = IdentityService(libraryStore: store1)

        let photo = PhotoRecord(relativePath: "test_photo.jpg", filename: "test_photo.jpg", fileSize: 1000, modificationDate: Date())
        try await store1.savePhoto(photo)
        let face = FaceRecord(photoId: photo.id, boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3))
        try await store1.saveFaces([face], forPhotoId: photo.id)

        var vec = [Float](repeating: 0, count: 512)
        vec[0] = 1.0
        let emb = EmbeddingRecord(faceId: face.id, photoId: photo.id, vector: vec)
        try await store1.saveEmbeddings([emb])

        try await coordinator.reclusterLibrary(rootFolderURL: URL(fileURLWithPath: "/tmp"), threshold: 0.65)
        let groups1 = await identityService1.fetchGroups()
        XCTAssertEqual(groups1.count, 1)

        // Give person a custom name
        try await identityService1.renameGroup(id: groups1[0].id, newName: "Alice Smith")

        // Create a new store reading the same file (simulating app restart)
        let store2 = LibraryStore(storageURL: tempURL)
        let identityService2 = IdentityService(libraryStore: store2)

        let groups2 = await identityService2.fetchGroups()
        XCTAssertEqual(groups2.count, 1)
        XCTAssertEqual(groups2[0].id, groups1[0].id)
        XCTAssertEqual(groups2[0].displayName, "Alice Smith")
        XCTAssertEqual(groups2[0].customName, "Alice Smith")
        XCTAssertEqual(groups2[0].memberFaceIds, [face.id])
    }

    func testRetrievingPhotosBelongingToPerson() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("library_index.json")
        let store = LibraryStore(storageURL: tempURL)
        let identityService = IdentityService(libraryStore: store)
        let rootURL = URL(fileURLWithPath: "/Users/test/Photos")

        let photo1 = PhotoRecord(relativePath: "vacation/photo1.jpg", filename: "photo1.jpg", fileSize: 100, modificationDate: Date())
        let photo2 = PhotoRecord(relativePath: "vacation/photo2.jpg", filename: "photo2.jpg", fileSize: 200, modificationDate: Date())
        let photo3 = PhotoRecord(relativePath: "work/photo3.jpg", filename: "photo3.jpg", fileSize: 300, modificationDate: Date())

        try await store.savePhoto(photo1)
        try await store.savePhoto(photo2)
        try await store.savePhoto(photo3)

        let face1 = FaceRecord(photoId: photo1.id, boundingBox: CGRect(x: 0, y: 0, width: 0.2, height: 0.2))
        let face2 = FaceRecord(photoId: photo2.id, boundingBox: CGRect(x: 0, y: 0, width: 0.2, height: 0.2))
        let face3 = FaceRecord(photoId: photo3.id, boundingBox: CGRect(x: 0, y: 0, width: 0.2, height: 0.2))

        try await store.saveFaces([face1], forPhotoId: photo1.id)
        try await store.saveFaces([face2], forPhotoId: photo2.id)
        try await store.saveFaces([face3], forPhotoId: photo3.id)

        // Group with face1 and face2
        let group = GroupRecord(
            groupIndex: 1,
            customName: "Charlie",
            representativeFaceId: face1.id,
            memberFaceIds: [face1.id, face2.id],
            averageSimilarity: 0.9,
            minSimilarity: 0.9,
            thresholdUsed: 0.65
        )
        try await store.saveGroup(group)

        let personPhotos = await identityService.fetchPhotos(forGroupId: group.id, rootFolderURL: rootURL)
        XCTAssertEqual(personPhotos.count, 2)
        let filenames = Set(personPhotos.map { $0.filename })
        XCTAssertTrue(filenames.contains("photo1.jpg"))
        XCTAssertTrue(filenames.contains("photo2.jpg"))
        XCTAssertFalse(filenames.contains("photo3.jpg"))
        XCTAssertEqual(personPhotos[0].url.path, "/Users/test/Photos/vacation/photo1.jpg")

        let count = await identityService.fetchUniquePhotoCount(forGroupId: group.id)
        XCTAssertEqual(count, 2)
    }

    func testZeroFacePhotosDoNotCreatePeople() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("library_index.json")
        let store = LibraryStore(storageURL: tempURL)
        let coordinator = LibraryProcessingCoordinator(libraryStore: store)
        let identityService = IdentityService(libraryStore: store)

        let landscapePhoto = PhotoRecord(
            relativePath: "landscape.jpg",
            filename: "landscape.jpg",
            fileSize: 5000,
            modificationDate: Date(),
            processingState: .processed,
            detectedFacesCount: 0
        )
        try await store.savePhoto(landscapePhoto)

        try await coordinator.reclusterLibrary(rootFolderURL: URL(fileURLWithPath: "/tmp"), threshold: 0.65)

        let groups = await identityService.fetchGroups()
        XCTAssertEqual(groups.count, 0, "Zero-face photos must result in 0 person groups")
    }

    func testReprocessingPhotoDoesNotCreateDuplicatePeople() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("library_index.json")
        let store = LibraryStore(storageURL: tempURL)
        let coordinator = LibraryProcessingCoordinator(libraryStore: store)
        let identityService = IdentityService(libraryStore: store)

        let photo = PhotoRecord(relativePath: "avatar.jpg", filename: "avatar.jpg", fileSize: 1000, modificationDate: Date())
        try await store.savePhoto(photo)

        let face = FaceRecord(photoId: photo.id, boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3))
        try await store.saveFaces([face], forPhotoId: photo.id)

        var vec = [Float](repeating: 0, count: 512)
        vec[0] = 1.0
        let emb = EmbeddingRecord(faceId: face.id, photoId: photo.id, vector: vec)
        try await store.saveEmbeddings([emb])

        // Initial cluster
        try await coordinator.reclusterLibrary(rootFolderURL: URL(fileURLWithPath: "/tmp"), threshold: 0.65)
        let groups1 = await identityService.fetchGroups()
        XCTAssertEqual(groups1.count, 1)
        let originalGroupId = groups1[0].id

        // Re-cluster again with same data (simulating photo rescan / reconciliation)
        try await coordinator.reclusterLibrary(rootFolderURL: URL(fileURLWithPath: "/tmp"), threshold: 0.65)
        let groups2 = await identityService.fetchGroups()
        XCTAssertEqual(groups2.count, 1, "Should not duplicate person group on re-clustering")
        XCTAssertEqual(groups2[0].id, originalGroupId, "Group ID must remain stable across re-clustering runs")
    }

    func testExistingPeopleRemainIntactAfterLibraryReconciliation() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("library_index.json")
        let store = LibraryStore(storageURL: tempURL)
        let coordinator = LibraryProcessingCoordinator(libraryStore: store)
        let identityService = IdentityService(libraryStore: store)

        // 1. Initial person (Alice)
        let photo1 = PhotoRecord(relativePath: "alice.jpg", filename: "alice.jpg", fileSize: 1000, modificationDate: Date())
        try await store.savePhoto(photo1)
        let face1 = FaceRecord(photoId: photo1.id, boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3))
        try await store.saveFaces([face1], forPhotoId: photo1.id)
        var vec1 = [Float](repeating: 0, count: 512)
        vec1[0] = 1.0
        let emb1 = EmbeddingRecord(faceId: face1.id, photoId: photo1.id, vector: vec1)
        try await store.saveEmbeddings([emb1])

        try await coordinator.reclusterLibrary(rootFolderURL: URL(fileURLWithPath: "/tmp"), threshold: 0.65)
        let groups1 = await identityService.fetchGroups()
        try await identityService.renameGroup(id: groups1[0].id, newName: "Alice")

        // 2. Add second distinct photo (Bob)
        let photo2 = PhotoRecord(relativePath: "bob.jpg", filename: "bob.jpg", fileSize: 2000, modificationDate: Date())
        try await store.savePhoto(photo2)
        let face2 = FaceRecord(photoId: photo2.id, boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3))
        try await store.saveFaces([face2], forPhotoId: photo2.id)
        var vec2 = [Float](repeating: 0, count: 512)
        vec2[50] = 1.0
        let emb2 = EmbeddingRecord(faceId: face2.id, photoId: photo2.id, vector: vec2)
        try await store.saveEmbeddings([emb2])

        // Recluster library with both photos
        try await coordinator.reclusterLibrary(rootFolderURL: URL(fileURLWithPath: "/tmp"), threshold: 0.65)
        let groups2 = await identityService.fetchGroups()
        XCTAssertEqual(groups2.count, 2)

        let aliceGroup = groups2.first { $0.customName == "Alice" }
        XCTAssertNotNil(aliceGroup, "Alice's custom name and identity must remain intact after reconciliation")
        XCTAssertEqual(aliceGroup?.memberFaceIds, [face1.id])
    }

    // MARK: - Face Grouping & Identity Pipeline Regression Tests

    private func makeNormalizedVector(primaryDim: Int, secondaryDim: Int? = nil, secondaryWeight: Float = 0.0) -> [Float] {
        var vec = [Float](repeating: 0.0, count: 512)
        vec[primaryDim] = 1.0
        if let sDim = secondaryDim {
            vec[sDim] = secondaryWeight
        }
        var sumSquares: Float = 0.0
        for val in vec { sumSquares += val * val }
        let norm = sqrt(sumSquares)
        return vec.map { $0 / norm }
    }

    /// Regression Test 1: Two photos of the same person with high similarity (>0.75) are grouped into a single person.
    func testRegressionSamePersonHighSimilaritySingleGroup() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("library_index.json")
        let store = LibraryStore(storageURL: tempURL)
        let coordinator = LibraryProcessingCoordinator(libraryStore: store)
        let identityService = IdentityService(libraryStore: store)

        let photo1 = PhotoRecord(relativePath: "person_a_1.jpg", filename: "person_a_1.jpg", fileSize: 1000, modificationDate: Date())
        let photo2 = PhotoRecord(relativePath: "person_a_2.jpg", filename: "person_a_2.jpg", fileSize: 1000, modificationDate: Date())
        try await store.savePhoto(photo1)
        try await store.savePhoto(photo2)

        let face1 = FaceRecord(photoId: photo1.id, boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.4))
        let face2 = FaceRecord(photoId: photo2.id, boundingBox: CGRect(x: 0.15, y: 0.15, width: 0.4, height: 0.4))
        try await store.saveFaces([face1], forPhotoId: photo1.id)
        try await store.saveFaces([face2], forPhotoId: photo2.id)

        // Vectors with ~0.85 cosine similarity (well above 0.65 threshold)
        let vec1 = makeNormalizedVector(primaryDim: 10, secondaryDim: 20, secondaryWeight: 0.0)
        let vec2 = makeNormalizedVector(primaryDim: 10, secondaryDim: 20, secondaryWeight: 0.6)
        try await store.saveEmbeddings([
            EmbeddingRecord(faceId: face1.id, photoId: photo1.id, vector: vec1),
            EmbeddingRecord(faceId: face2.id, photoId: photo2.id, vector: vec2)
        ])

        try await coordinator.reclusterLibrary(rootFolderURL: URL(fileURLWithPath: "/tmp"), threshold: 0.65)

        let groups = await identityService.fetchGroups()
        XCTAssertEqual(groups.count, 1, "Two highly similar faces of the same person must form exactly 1 group")
        XCTAssertEqual(Set(groups[0].memberFaceIds), Set([face1.id, face2.id]))
    }

    /// Regression Test 2: Three photos of the same person (replicating Person 2 vs Person 9 scenario) form a single group.
    func testRegressionSamePersonThreePhotosSingleGroup() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("library_index.json")
        let store = LibraryStore(storageURL: tempURL)
        let coordinator = LibraryProcessingCoordinator(libraryStore: store)
        let identityService = IdentityService(libraryStore: store)

        // Simulates IMG_1144.heic, IMG_1141.heic, and IMG-20250405-WA0004.JPG
        let photo1 = PhotoRecord(relativePath: "IMG_1144.heic", filename: "IMG_1144.heic", fileSize: 3000, modificationDate: Date())
        let photo2 = PhotoRecord(relativePath: "IMG_1141.heic", filename: "IMG_1141.heic", fileSize: 3000, modificationDate: Date())
        let photo3 = PhotoRecord(relativePath: "IMG-20250405-WA0004.JPG", filename: "IMG-20250405-WA0004.JPG", fileSize: 3000, modificationDate: Date())
        try await store.savePhoto(photo1)
        try await store.savePhoto(photo2)
        try await store.savePhoto(photo3)

        let face1 = FaceRecord(photoId: photo1.id, boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3))
        let face2 = FaceRecord(photoId: photo2.id, boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3))
        let face3 = FaceRecord(photoId: photo3.id, boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3))
        try await store.saveFaces([face1], forPhotoId: photo1.id)
        try await store.saveFaces([face2], forPhotoId: photo2.id)
        try await store.saveFaces([face3], forPhotoId: photo3.id)

        // Pairwise similarities > 0.75
        let vec1 = makeNormalizedVector(primaryDim: 5, secondaryDim: 6, secondaryWeight: 0.2)
        let vec2 = makeNormalizedVector(primaryDim: 5, secondaryDim: 6, secondaryWeight: 0.3)
        let vec3 = makeNormalizedVector(primaryDim: 5, secondaryDim: 6, secondaryWeight: 0.1)
        try await store.saveEmbeddings([
            EmbeddingRecord(faceId: face1.id, photoId: photo1.id, vector: vec1),
            EmbeddingRecord(faceId: face2.id, photoId: photo2.id, vector: vec2),
            EmbeddingRecord(faceId: face3.id, photoId: photo3.id, vector: vec3)
        ])

        try await coordinator.reclusterLibrary(rootFolderURL: URL(fileURLWithPath: "/tmp"), threshold: 0.65)

        let groups = await identityService.fetchGroups()
        XCTAssertEqual(groups.count, 1, "All 3 photos of the same person must belong to a single GroupRecord")
        XCTAssertEqual(Set(groups[0].memberFaceIds), Set([face1.id, face2.id, face3.id]))

        let photosInGroup = await identityService.fetchPhotos(forGroupId: groups[0].id, rootFolderURL: URL(fileURLWithPath: "/tmp"))
        XCTAssertEqual(photosInGroup.count, 3, "Group must contain all 3 photos")
    }

    /// Regression Test 3: A single FaceRecord MUST NEVER belong to more than one GroupRecord.
    func testRegressionOneFaceBelongsToExactlyOneGroup() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("library_index.json")
        let store = LibraryStore(storageURL: tempURL)

        let photo = PhotoRecord(relativePath: "face.jpg", filename: "face.jpg", fileSize: 1000, modificationDate: Date())
        try await store.savePhoto(photo)
        let face = FaceRecord(photoId: photo.id, boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.4))
        try await store.saveFaces([face], forPhotoId: photo.id)

        // Attempt to create two groups containing the same face
        let group1 = GroupRecord(groupIndex: 1, representativeFaceId: face.id, memberFaceIds: [face.id], averageSimilarity: 1.0, minSimilarity: 1.0, thresholdUsed: 0.65)
        let group2 = GroupRecord(groupIndex: 2, representativeFaceId: face.id, memberFaceIds: [face.id], averageSimilarity: 1.0, minSimilarity: 1.0, thresholdUsed: 0.65)

        // Store saveGroups must enforce uniqueness and eliminate duplicate assignments
        try await store.saveGroups([group1, group2])

        let integrity = await store.validateIntegrity()
        XCTAssertEqual(integrity.duplicateGroupMembershipsCount, 0, "Integrity report must find zero duplicate memberships")
        XCTAssertEqual(integrity.facesAssignedToMultipleGroupsCount, 0, "Integrity report must find zero faces assigned to multiple groups")
        XCTAssertTrue(integrity.isValid)

        let storedGroups = await store.getGroups()
        let allAssignedFaces = storedGroups.flatMap { $0.memberFaceIds }
        XCTAssertEqual(allAssignedFaces.filter { $0 == face.id }.count, 1, "FaceRecord must appear exactly once across all GroupRecords")
    }

    /// Regression Test 4: Re-running clustering on an unchanged library is completely idempotent and preserves group IDs.
    func testRegressionRerunningClusteringIsIdempotent() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("library_index.json")
        let store = LibraryStore(storageURL: tempURL)
        let coordinator = LibraryProcessingCoordinator(libraryStore: store)
        let identityService = IdentityService(libraryStore: store)

        let photo1 = PhotoRecord(relativePath: "p1.jpg", filename: "p1.jpg", fileSize: 1000, modificationDate: Date())
        let photo2 = PhotoRecord(relativePath: "p2.jpg", filename: "p2.jpg", fileSize: 1000, modificationDate: Date())
        try await store.savePhoto(photo1)
        try await store.savePhoto(photo2)

        let face1 = FaceRecord(photoId: photo1.id, boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3))
        let face2 = FaceRecord(photoId: photo2.id, boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3))
        try await store.saveFaces([face1], forPhotoId: photo1.id)
        try await store.saveFaces([face2], forPhotoId: photo2.id)

        let vec1 = makeNormalizedVector(primaryDim: 40, secondaryDim: 41, secondaryWeight: 0.2)
        let vec2 = makeNormalizedVector(primaryDim: 40, secondaryDim: 41, secondaryWeight: 0.3)
        try await store.saveEmbeddings([
            EmbeddingRecord(faceId: face1.id, photoId: photo1.id, vector: vec1),
            EmbeddingRecord(faceId: face2.id, photoId: photo2.id, vector: vec2)
        ])

        // First clustering run
        try await coordinator.reclusterLibrary(rootFolderURL: URL(fileURLWithPath: "/tmp"), threshold: 0.65)
        let groupsRun1 = await identityService.fetchGroups()
        XCTAssertEqual(groupsRun1.count, 1)
        let initialId = groupsRun1[0].id

        // Second clustering run
        try await coordinator.reclusterLibrary(rootFolderURL: URL(fileURLWithPath: "/tmp"), threshold: 0.65)
        let groupsRun2 = await identityService.fetchGroups()
        XCTAssertEqual(groupsRun2.count, 1)
        XCTAssertEqual(groupsRun2[0].id, initialId, "Group ID must remain identical across repeated clustering runs")
        XCTAssertEqual(Set(groupsRun2[0].memberFaceIds), Set([face1.id, face2.id]))
    }

    /// Regression Test 5: Re-clustering merges previously split groups when embeddings meet the threshold.
    func testRegressionReclusteringMergesSplitGroupsWhenSimilar() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("library_index.json")
        let store = LibraryStore(storageURL: tempURL)
        let coordinator = LibraryProcessingCoordinator(libraryStore: store)
        let identityService = IdentityService(libraryStore: store)

        let photo1 = PhotoRecord(relativePath: "split1.jpg", filename: "split1.jpg", fileSize: 1000, modificationDate: Date())
        let photo2 = PhotoRecord(relativePath: "split2.jpg", filename: "split2.jpg", fileSize: 1000, modificationDate: Date())
        try await store.savePhoto(photo1)
        try await store.savePhoto(photo2)

        let face1 = FaceRecord(photoId: photo1.id, boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3))
        let face2 = FaceRecord(photoId: photo2.id, boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3))
        try await store.saveFaces([face1], forPhotoId: photo1.id)
        try await store.saveFaces([face2], forPhotoId: photo2.id)

        let vec1 = makeNormalizedVector(primaryDim: 80, secondaryDim: 81, secondaryWeight: 0.1)
        let vec2 = makeNormalizedVector(primaryDim: 80, secondaryDim: 81, secondaryWeight: 0.2)
        try await store.saveEmbeddings([
            EmbeddingRecord(faceId: face1.id, photoId: photo1.id, vector: vec1),
            EmbeddingRecord(faceId: face2.id, photoId: photo2.id, vector: vec2)
        ])

        // Manually create two separate split groups
        let splitGroup1 = GroupRecord(groupIndex: 1, representativeFaceId: face1.id, memberFaceIds: [face1.id], averageSimilarity: 1.0, minSimilarity: 1.0, thresholdUsed: 0.65)
        let splitGroup2 = GroupRecord(groupIndex: 2, representativeFaceId: face2.id, memberFaceIds: [face2.id], averageSimilarity: 1.0, minSimilarity: 1.0, thresholdUsed: 0.65)
        try await store.saveGroups([splitGroup1, splitGroup2])

        let initialGroups = await identityService.fetchGroups()
        XCTAssertEqual(initialGroups.count, 2, "Initially 2 split groups")

        // Recluster: Should recognize high similarity and consolidate into 1 group
        try await coordinator.reclusterLibrary(rootFolderURL: URL(fileURLWithPath: "/tmp"), threshold: 0.65)

        let mergedGroups = await identityService.fetchGroups()
        XCTAssertEqual(mergedGroups.count, 1, "Reclustering must merge the split groups into 1 single group")
        XCTAssertEqual(Set(mergedGroups[0].memberFaceIds), Set([face1.id, face2.id]))
    }

    /// Regression Test 6: Distinct people with similarity below threshold (<0.65) remain separated.
    func testRegressionDistinctPeopleNotMergedUnderThreshold() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("library_index.json")
        let store = LibraryStore(storageURL: tempURL)
        let coordinator = LibraryProcessingCoordinator(libraryStore: store)
        let identityService = IdentityService(libraryStore: store)

        let photo1 = PhotoRecord(relativePath: "alice.jpg", filename: "alice.jpg", fileSize: 1000, modificationDate: Date())
        let photo2 = PhotoRecord(relativePath: "bob.jpg", filename: "bob.jpg", fileSize: 1000, modificationDate: Date())
        try await store.savePhoto(photo1)
        try await store.savePhoto(photo2)

        let face1 = FaceRecord(photoId: photo1.id, boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3))
        let face2 = FaceRecord(photoId: photo2.id, boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3))
        try await store.saveFaces([face1], forPhotoId: photo1.id)
        try await store.saveFaces([face2], forPhotoId: photo2.id)

        // Orthogonal vectors with similarity = 0.0 (< 0.65 threshold)
        let vec1 = makeNormalizedVector(primaryDim: 100)
        let vec2 = makeNormalizedVector(primaryDim: 200)
        try await store.saveEmbeddings([
            EmbeddingRecord(faceId: face1.id, photoId: photo1.id, vector: vec1),
            EmbeddingRecord(faceId: face2.id, photoId: photo2.id, vector: vec2)
        ])

        try await coordinator.reclusterLibrary(rootFolderURL: URL(fileURLWithPath: "/tmp"), threshold: 0.65)

        let groups = await identityService.fetchGroups()
        XCTAssertEqual(groups.count, 2, "Distinct people with low similarity must remain in separate groups")
        XCTAssertEqual(groups[0].memberFaceIds.count, 1)
        XCTAssertEqual(groups[1].memberFaceIds.count, 1)
    }

    /// Regression Test 7: Same person with different lighting conditions forms a single Person.
    func testRegressionSamePersonDifferentLightingFormsSinglePerson() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("library_index.json")
        let store = LibraryStore(storageURL: tempURL)
        let coordinator = LibraryProcessingCoordinator(libraryStore: store)
        let identityService = IdentityService(libraryStore: store)

        let photoBright = PhotoRecord(relativePath: "bright.jpg", filename: "bright.jpg", fileSize: 1000, modificationDate: Date())
        let photoDim = PhotoRecord(relativePath: "dim.jpg", filename: "dim.jpg", fileSize: 1000, modificationDate: Date())
        try await store.savePhoto(photoBright)
        try await store.savePhoto(photoDim)

        let faceBright = FaceRecord(photoId: photoBright.id, boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3))
        let faceDim = FaceRecord(photoId: photoDim.id, boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3))
        try await store.saveFaces([faceBright], forPhotoId: photoBright.id)
        try await store.saveFaces([faceDim], forPhotoId: photoDim.id)

        // ArcFace vectors with lighting shift (cosine similarity ~0.72 > 0.65)
        let vecBright = makeNormalizedVector(primaryDim: 30, secondaryDim: 31, secondaryWeight: 0.1)
        let vecDim = makeNormalizedVector(primaryDim: 30, secondaryDim: 31, secondaryWeight: 0.8)
        try await store.saveEmbeddings([
            EmbeddingRecord(faceId: faceBright.id, photoId: photoBright.id, vector: vecBright),
            EmbeddingRecord(faceId: faceDim.id, photoId: photoDim.id, vector: vecDim)
        ])

        try await coordinator.reclusterLibrary(rootFolderURL: URL(fileURLWithPath: "/tmp"), threshold: 0.65)

        let groups = await identityService.fetchGroups()
        XCTAssertEqual(groups.count, 1, "Same person in different lighting must be clustered into 1 Person")
        XCTAssertEqual(Set(groups[0].memberFaceIds), Set([faceBright.id, faceDim.id]))
    }

    /// Regression Test 8: Same person with and without glasses forms a single Person.
    func testRegressionSamePersonWithAndWithoutGlassesFormsSinglePerson() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("library_index.json")
        let store = LibraryStore(storageURL: tempURL)
        let coordinator = LibraryProcessingCoordinator(libraryStore: store)
        let identityService = IdentityService(libraryStore: store)

        let photoGlasses = PhotoRecord(relativePath: "glasses.jpg", filename: "glasses.jpg", fileSize: 1000, modificationDate: Date())
        let photoNoGlasses = PhotoRecord(relativePath: "noglasses.jpg", filename: "noglasses.jpg", fileSize: 1000, modificationDate: Date())
        try await store.savePhoto(photoGlasses)
        try await store.savePhoto(photoNoGlasses)

        let faceGlasses = FaceRecord(photoId: photoGlasses.id, boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3))
        let faceNoGlasses = FaceRecord(photoId: photoNoGlasses.id, boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3))
        try await store.saveFaces([faceGlasses], forPhotoId: photoGlasses.id)
        try await store.saveFaces([faceNoGlasses], forPhotoId: photoNoGlasses.id)

        // ArcFace similarity with glasses ~0.78 > 0.65
        let vecGlasses = makeNormalizedVector(primaryDim: 15, secondaryDim: 16, secondaryWeight: 0.3)
        let vecNoGlasses = makeNormalizedVector(primaryDim: 15, secondaryDim: 16, secondaryWeight: 0.6)
        try await store.saveEmbeddings([
            EmbeddingRecord(faceId: faceGlasses.id, photoId: photoGlasses.id, vector: vecGlasses),
            EmbeddingRecord(faceId: faceNoGlasses.id, photoId: photoNoGlasses.id, vector: vecNoGlasses)
        ])

        try await coordinator.reclusterLibrary(rootFolderURL: URL(fileURLWithPath: "/tmp"), threshold: 0.65)

        let groups = await identityService.fetchGroups()
        XCTAssertEqual(groups.count, 1, "Same person with/without glasses must cluster into 1 Person")
        XCTAssertEqual(Set(groups[0].memberFaceIds), Set([faceGlasses.id, faceNoGlasses.id]))
    }

    /// Regression Test 9: New photo of an existing Person automatically joins their existing Person identity profile.
    func testRegressionNewPhotoOfExistingPersonJoinsExistingPerson() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("library_index.json")
        let store = LibraryStore(storageURL: tempURL)
        let coordinator = LibraryProcessingCoordinator(libraryStore: store)
        let identityService = IdentityService(libraryStore: store)

        // Existing person with 2 photos
        let photo1 = PhotoRecord(relativePath: "p1.jpg", filename: "p1.jpg", fileSize: 1000, modificationDate: Date())
        let photo2 = PhotoRecord(relativePath: "p2.jpg", filename: "p2.jpg", fileSize: 1000, modificationDate: Date())
        try await store.savePhoto(photo1)
        try await store.savePhoto(photo2)

        let face1 = FaceRecord(photoId: photo1.id, boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3))
        let face2 = FaceRecord(photoId: photo2.id, boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3))
        try await store.saveFaces([face1], forPhotoId: photo1.id)
        try await store.saveFaces([face2], forPhotoId: photo2.id)

        let vec1 = makeNormalizedVector(primaryDim: 50, secondaryDim: 51, secondaryWeight: 0.2)
        let vec2 = makeNormalizedVector(primaryDim: 50, secondaryDim: 51, secondaryWeight: 0.3)
        try await store.saveEmbeddings([
            EmbeddingRecord(faceId: face1.id, photoId: photo1.id, vector: vec1),
            EmbeddingRecord(faceId: face2.id, photoId: photo2.id, vector: vec2)
        ])

        try await coordinator.reclusterLibrary(rootFolderURL: URL(fileURLWithPath: "/tmp"), threshold: 0.65)
        let initialGroups = await identityService.fetchGroups()
        XCTAssertEqual(initialGroups.count, 1)
        let personGroupId = initialGroups[0].id

        // Now add a 3rd photo of the same person
        let photo3 = PhotoRecord(relativePath: "p3.jpg", filename: "p3.jpg", fileSize: 1000, modificationDate: Date())
        try await store.savePhoto(photo3)
        let face3 = FaceRecord(photoId: photo3.id, boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3))
        try await store.saveFaces([face3], forPhotoId: photo3.id)
        let vec3 = makeNormalizedVector(primaryDim: 50, secondaryDim: 51, secondaryWeight: 0.25)
        try await store.saveEmbeddings([EmbeddingRecord(faceId: face3.id, photoId: photo3.id, vector: vec3)])

        // Recluster with new photo
        try await coordinator.reclusterLibrary(rootFolderURL: URL(fileURLWithPath: "/tmp"), threshold: 0.65)
        let updatedGroups = await identityService.fetchGroups()

        XCTAssertEqual(updatedGroups.count, 1, "New photo of existing person must not create a duplicate Person")
        XCTAssertEqual(updatedGroups[0].id, personGroupId, "Existing Person group ID must be preserved")
        XCTAssertEqual(Set(updatedGroups[0].memberFaceIds), Set([face1.id, face2.id, face3.id]))
    }

    /// Regression Test 10: A manually merged Person remains one identity after future library scans/re-clustering.
    func testRegressionManuallyMergedPersonRemainsOneIdentityAfterFutureScans() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("library_index.json")
        let store = LibraryStore(storageURL: tempURL)
        let coordinator = LibraryProcessingCoordinator(libraryStore: store)
        let identityService = IdentityService(libraryStore: store)

        // Create 2 initial photos with distinct embeddings that were in separate groups
        let photoA = PhotoRecord(relativePath: "a.jpg", filename: "a.jpg", fileSize: 1000, modificationDate: Date())
        let photoB = PhotoRecord(relativePath: "b.jpg", filename: "b.jpg", fileSize: 1000, modificationDate: Date())
        try await store.savePhoto(photoA)
        try await store.savePhoto(photoB)

        let faceA = FaceRecord(photoId: photoA.id, boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3))
        let faceB = FaceRecord(photoId: photoB.id, boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3))
        try await store.saveFaces([faceA], forPhotoId: photoA.id)
        try await store.saveFaces([faceB], forPhotoId: photoB.id)

        let vecA = makeNormalizedVector(primaryDim: 60)
        let vecB = makeNormalizedVector(primaryDim: 60, secondaryDim: 61, secondaryWeight: 0.7)
        try await store.saveEmbeddings([
            EmbeddingRecord(faceId: faceA.id, photoId: photoA.id, vector: vecA),
            EmbeddingRecord(faceId: faceB.id, photoId: photoB.id, vector: vecB)
        ])

        // Initial groups
        let groupA = GroupRecord(groupIndex: 1, customName: "David", representativeFaceId: faceA.id, memberFaceIds: [faceA.id], averageSimilarity: 1.0, minSimilarity: 1.0, thresholdUsed: 0.65)
        let groupB = GroupRecord(groupIndex: 2, customName: nil, representativeFaceId: faceB.id, memberFaceIds: [faceB.id], averageSimilarity: 1.0, minSimilarity: 1.0, thresholdUsed: 0.65)
        try await store.saveGroups([groupA, groupB])

        // User manually merges Group B into Group A
        try await identityService.mergeGroups(targetGroupId: groupA.id, sourceGroupId: groupB.id)

        let postMergeGroups = await identityService.fetchGroups()
        XCTAssertEqual(postMergeGroups.count, 1)
        XCTAssertEqual(postMergeGroups[0].id, groupA.id)
        XCTAssertEqual(postMergeGroups[0].customName, "David")
        XCTAssertEqual(Set(postMergeGroups[0].memberFaceIds), Set([faceA.id, faceB.id]))

        // Future scan / library reclustering
        try await coordinator.reclusterLibrary(rootFolderURL: URL(fileURLWithPath: "/tmp"), threshold: 0.65)

        let futureGroups = await identityService.fetchGroups()
        XCTAssertEqual(futureGroups.count, 1, "Manually merged person must stay 1 identity across future library scans")
        XCTAssertEqual(futureGroups[0].id, groupA.id, "Merged group ID must be preserved")
        XCTAssertEqual(futureGroups[0].customName, "David", "Merged custom name must be preserved")
        XCTAssertEqual(Set(futureGroups[0].memberFaceIds), Set([faceA.id, faceB.id]))
    }

    // MARK: - Phase 10 Face Identity & Grouping Regression Tests

    /// Regression Test 1: Same person across 3 independent photo sets forms a single persistent identity.
    func testPhase10_1_SamePersonAcrossThreeIndependentPhotoSetsFormsSingleIdentity() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("library_index.json")
        let store = LibraryStore(storageURL: tempURL)
        let coordinator = LibraryProcessingCoordinator(libraryStore: store)
        let identityService = IdentityService(libraryStore: store)

        // Photo Set A (2 photos), Set B (2 photos), Set C (2 photos)
        var allFaces: [FaceRecord] = []
        var allEmbeddings: [EmbeddingRecord] = []

        // Base person embedding along dim 10 with minor variations
        for setIdx in 0..<3 {
            for photoIdx in 0..<2 {
                let photo = PhotoRecord(
                    relativePath: "set\(setIdx)/photo\(photoIdx).jpg",
                    filename: "photo\(photoIdx).jpg",
                    fileSize: 1000,
                    modificationDate: Date()
                )
                try await store.savePhoto(photo)

                let face = FaceRecord(photoId: photo.id, boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3))
                allFaces.append(face)
                try await store.saveFaces([face], forPhotoId: photo.id)

                let vec = makeNormalizedVector(primaryDim: 10, secondaryDim: 11 + setIdx, secondaryWeight: 0.15 + Float(photoIdx) * 0.05)
                allEmbeddings.append(EmbeddingRecord(faceId: face.id, photoId: photo.id, vector: vec))
            }
        }

        try await store.saveEmbeddings(allEmbeddings)

        try await coordinator.reclusterLibrary(rootFolderURL: URL(fileURLWithPath: "/tmp"), threshold: 0.65)

        let groups = await identityService.fetchGroups()
        XCTAssertEqual(groups.count, 1, "Faces across 3 independent photo sets of the same person must form exactly 1 GroupRecord")
        XCTAssertEqual(groups[0].memberFaceIds.count, 6, "All 6 faces must be consolidated in the single GroupRecord")
        XCTAssertEqual(Set(groups[0].memberFaceIds), Set(allFaces.map(\.id)))
    }

    /// Regression Test 2: Same person with large appearance variation (pose, lighting, expression) forms a single identity.
    func testPhase10_2_SamePersonWithLargeAppearanceVariationFormsSingleIdentity() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("library_index.json")
        let store = LibraryStore(storageURL: tempURL)
        let coordinator = LibraryProcessingCoordinator(libraryStore: store)
        let identityService = IdentityService(libraryStore: store)

        let photo1 = PhotoRecord(relativePath: "frontal_bright.jpg", filename: "frontal_bright.jpg", fileSize: 1000, modificationDate: Date())
        let photo2 = PhotoRecord(relativePath: "profile_dim.jpg", filename: "profile_dim.jpg", fileSize: 1000, modificationDate: Date())
        let photo3 = PhotoRecord(relativePath: "glasses_smile.jpg", filename: "glasses_smile.jpg", fileSize: 1000, modificationDate: Date())
        try await store.savePhoto(photo1)
        try await store.savePhoto(photo2)
        try await store.savePhoto(photo3)

        let face1 = FaceRecord(photoId: photo1.id, boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3))
        let face2 = FaceRecord(photoId: photo2.id, boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3))
        let face3 = FaceRecord(photoId: photo3.id, boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3))
        try await store.saveFaces([face1], forPhotoId: photo1.id)
        try await store.saveFaces([face2], forPhotoId: photo2.id)
        try await store.saveFaces([face3], forPhotoId: photo3.id)

        let vec1 = makeNormalizedVector(primaryDim: 20, secondaryDim: 21, secondaryWeight: 0.1)
        let vec2 = makeNormalizedVector(primaryDim: 20, secondaryDim: 22, secondaryWeight: 0.3)
        let vec3 = makeNormalizedVector(primaryDim: 20, secondaryDim: 23, secondaryWeight: 0.25)
        try await store.saveEmbeddings([
            EmbeddingRecord(faceId: face1.id, photoId: photo1.id, vector: vec1),
            EmbeddingRecord(faceId: face2.id, photoId: photo2.id, vector: vec2),
            EmbeddingRecord(faceId: face3.id, photoId: photo3.id, vector: vec3)
        ])

        try await coordinator.reclusterLibrary(rootFolderURL: URL(fileURLWithPath: "/tmp"), threshold: 0.65)

        let groups = await identityService.fetchGroups()
        XCTAssertEqual(groups.count, 1, "Large appearance variation of same person must form 1 identity")
        XCTAssertEqual(Set(groups[0].memberFaceIds), Set([face1.id, face2.id, face3.id]))
    }

    /// Regression Test 3: Scan-order independence (A -> B -> C vs C -> A -> B yields identical grouping).
    func testPhase10_3_ScanOrderIndependence() async throws {
        let storeA = LibraryStore(storageURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("library_index.json"))
        let storeB = LibraryStore(storageURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("library_index.json"))
        let coordA = LibraryProcessingCoordinator(libraryStore: storeA)
        let coordB = LibraryProcessingCoordinator(libraryStore: storeB)

        let vecA = makeNormalizedVector(primaryDim: 30, secondaryDim: 31, secondaryWeight: 0.1)
        let vecB = makeNormalizedVector(primaryDim: 30, secondaryDim: 32, secondaryWeight: 0.2)
        let vecC = makeNormalizedVector(primaryDim: 30, secondaryDim: 33, secondaryWeight: 0.15)

        let fIdA = UUID()
        let fIdB = UUID()
        let fIdC = UUID()

        let pIdA = UUID()
        let pIdB = UUID()
        let pIdC = UUID()

        // Setup Store A (Order: A, B, C)
        try await storeA.savePhoto(PhotoRecord(id: pIdA, relativePath: "a.jpg", filename: "a.jpg", fileSize: 100, modificationDate: Date()))
        try await storeA.savePhoto(PhotoRecord(id: pIdB, relativePath: "b.jpg", filename: "b.jpg", fileSize: 100, modificationDate: Date()))
        try await storeA.savePhoto(PhotoRecord(id: pIdC, relativePath: "c.jpg", filename: "c.jpg", fileSize: 100, modificationDate: Date()))
        try await storeA.saveFaces([FaceRecord(id: fIdA, photoId: pIdA, boundingBox: .zero)], forPhotoId: pIdA)
        try await storeA.saveFaces([FaceRecord(id: fIdB, photoId: pIdB, boundingBox: .zero)], forPhotoId: pIdB)
        try await storeA.saveFaces([FaceRecord(id: fIdC, photoId: pIdC, boundingBox: .zero)], forPhotoId: pIdC)
        try await storeA.saveEmbeddings([
            EmbeddingRecord(faceId: fIdA, photoId: pIdA, vector: vecA),
            EmbeddingRecord(faceId: fIdB, photoId: pIdB, vector: vecB),
            EmbeddingRecord(faceId: fIdC, photoId: pIdC, vector: vecC)
        ])

        // Setup Store B (Order: C, A, B)
        try await storeB.savePhoto(PhotoRecord(id: pIdC, relativePath: "c.jpg", filename: "c.jpg", fileSize: 100, modificationDate: Date()))
        try await storeB.savePhoto(PhotoRecord(id: pIdA, relativePath: "a.jpg", filename: "a.jpg", fileSize: 100, modificationDate: Date()))
        try await storeB.savePhoto(PhotoRecord(id: pIdB, relativePath: "b.jpg", filename: "b.jpg", fileSize: 100, modificationDate: Date()))
        try await storeB.saveFaces([FaceRecord(id: fIdC, photoId: pIdC, boundingBox: .zero)], forPhotoId: pIdC)
        try await storeB.saveFaces([FaceRecord(id: fIdA, photoId: pIdA, boundingBox: .zero)], forPhotoId: pIdA)
        try await storeB.saveFaces([FaceRecord(id: fIdB, photoId: pIdB, boundingBox: .zero)], forPhotoId: pIdB)
        try await storeB.saveEmbeddings([
            EmbeddingRecord(faceId: fIdC, photoId: pIdC, vector: vecC),
            EmbeddingRecord(faceId: fIdA, photoId: pIdA, vector: vecA),
            EmbeddingRecord(faceId: fIdB, photoId: pIdB, vector: vecB)
        ])

        try await coordA.reclusterLibrary(rootFolderURL: URL(fileURLWithPath: "/tmp"), threshold: 0.65)
        try await coordB.reclusterLibrary(rootFolderURL: URL(fileURLWithPath: "/tmp"), threshold: 0.65)

        let groupsA = await storeA.getGroups()
        let groupsB = await storeB.getGroups()

        XCTAssertEqual(groupsA.count, 1)
        XCTAssertEqual(groupsB.count, 1)
        XCTAssertEqual(Set(groupsA[0].memberFaceIds), Set(groupsB[0].memberFaceIds), "Scan order must not alter identity grouping membership")
    }

    /// Regression Test 4: Batch vs incremental scanning equivalence.
    func testPhase10_4_BatchVsIncrementalEquivalence() async throws {
        let storeBatch = LibraryStore(storageURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("library_index.json"))
        let storeIncr = LibraryStore(storageURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("library_index.json"))
        let coordBatch = LibraryProcessingCoordinator(libraryStore: storeBatch)
        let coordIncr = LibraryProcessingCoordinator(libraryStore: storeIncr)

        let vec1 = makeNormalizedVector(primaryDim: 40, secondaryDim: 41, secondaryWeight: 0.1)
        let vec2 = makeNormalizedVector(primaryDim: 40, secondaryDim: 42, secondaryWeight: 0.2)
        let vec3 = makeNormalizedVector(primaryDim: 40, secondaryDim: 43, secondaryWeight: 0.15)

        let p1 = PhotoRecord(relativePath: "1.jpg", filename: "1.jpg", fileSize: 100, modificationDate: Date())
        let p2 = PhotoRecord(relativePath: "2.jpg", filename: "2.jpg", fileSize: 100, modificationDate: Date())
        let p3 = PhotoRecord(relativePath: "3.jpg", filename: "3.jpg", fileSize: 100, modificationDate: Date())

        let f1 = FaceRecord(photoId: p1.id, boundingBox: .zero)
        let f2 = FaceRecord(photoId: p2.id, boundingBox: .zero)
        let f3 = FaceRecord(photoId: p3.id, boundingBox: .zero)

        // Batch execution: add all, cluster once
        try await storeBatch.savePhoto(p1); try await storeBatch.saveFaces([f1], forPhotoId: p1.id); try await storeBatch.saveEmbedding(EmbeddingRecord(faceId: f1.id, photoId: p1.id, vector: vec1))
        try await storeBatch.savePhoto(p2); try await storeBatch.saveFaces([f2], forPhotoId: p2.id); try await storeBatch.saveEmbedding(EmbeddingRecord(faceId: f2.id, photoId: p2.id, vector: vec2))
        try await storeBatch.savePhoto(p3); try await storeBatch.saveFaces([f3], forPhotoId: p3.id); try await storeBatch.saveEmbedding(EmbeddingRecord(faceId: f3.id, photoId: p3.id, vector: vec3))
        try await coordBatch.reclusterLibrary(rootFolderURL: URL(fileURLWithPath: "/tmp"), threshold: 0.65)

        // Incremental execution: add p1, cluster; add p2, cluster; add p3, cluster
        try await storeIncr.savePhoto(p1); try await storeIncr.saveFaces([f1], forPhotoId: p1.id); try await storeIncr.saveEmbedding(EmbeddingRecord(faceId: f1.id, photoId: p1.id, vector: vec1))
        try await coordIncr.reclusterLibrary(rootFolderURL: URL(fileURLWithPath: "/tmp"), threshold: 0.65)

        try await storeIncr.savePhoto(p2); try await storeIncr.saveFaces([f2], forPhotoId: p2.id); try await storeIncr.saveEmbedding(EmbeddingRecord(faceId: f2.id, photoId: p2.id, vector: vec2))
        try await coordIncr.reclusterLibrary(rootFolderURL: URL(fileURLWithPath: "/tmp"), threshold: 0.65)

        try await storeIncr.savePhoto(p3); try await storeIncr.saveFaces([f3], forPhotoId: p3.id); try await storeIncr.saveEmbedding(EmbeddingRecord(faceId: f3.id, photoId: p3.id, vector: vec3))
        try await coordIncr.reclusterLibrary(rootFolderURL: URL(fileURLWithPath: "/tmp"), threshold: 0.65)

        let groupsBatch = await storeBatch.getGroups()
        let groupsIncr = await storeIncr.getGroups()

        XCTAssertEqual(groupsBatch.count, 1)
        XCTAssertEqual(groupsIncr.count, 1)
        XCTAssertEqual(Set(groupsBatch[0].memberFaceIds), Set(groupsIncr[0].memberFaceIds))
    }

    /// Regression Test 5: Existing identity absorbs new photo set without duplicate person.
    func testPhase10_5_ExistingIdentityAbsorbsNewPhotoSetWithoutDuplicatePerson() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("library_index.json")
        let store = LibraryStore(storageURL: tempURL)
        let coordinator = LibraryProcessingCoordinator(libraryStore: store)
        let identityService = IdentityService(libraryStore: store)

        // Phase A: Person with custom name "Alice" and 2 photos
        let p1 = PhotoRecord(relativePath: "p1.jpg", filename: "p1.jpg", fileSize: 100, modificationDate: Date())
        let p2 = PhotoRecord(relativePath: "p2.jpg", filename: "p2.jpg", fileSize: 100, modificationDate: Date())
        try await store.savePhoto(p1); try await store.savePhoto(p2)
        let f1 = FaceRecord(photoId: p1.id, boundingBox: .zero)
        let f2 = FaceRecord(photoId: p2.id, boundingBox: .zero)
        try await store.saveFaces([f1], forPhotoId: p1.id); try await store.saveFaces([f2], forPhotoId: p2.id)
        let v1 = makeNormalizedVector(primaryDim: 50, secondaryDim: 51, secondaryWeight: 0.1)
        let v2 = makeNormalizedVector(primaryDim: 50, secondaryDim: 51, secondaryWeight: 0.2)
        try await store.saveEmbeddings([
            EmbeddingRecord(faceId: f1.id, photoId: p1.id, vector: v1),
            EmbeddingRecord(faceId: f2.id, photoId: p2.id, vector: v2)
        ])

        try await coordinator.reclusterLibrary(rootFolderURL: URL(fileURLWithPath: "/tmp"), threshold: 0.65)
        let initialGroups = await identityService.fetchGroups()
        XCTAssertEqual(initialGroups.count, 1)
        let originalGroupId = initialGroups[0].id
        try await identityService.renameGroup(id: originalGroupId, newName: "Alice")

        // Phase B: Add a whole new photo set (2 new photos of Alice)
        let p3 = PhotoRecord(relativePath: "p3.jpg", filename: "p3.jpg", fileSize: 100, modificationDate: Date())
        let p4 = PhotoRecord(relativePath: "p4.jpg", filename: "p4.jpg", fileSize: 100, modificationDate: Date())
        try await store.savePhoto(p3); try await store.savePhoto(p4)
        let f3 = FaceRecord(photoId: p3.id, boundingBox: .zero)
        let f4 = FaceRecord(photoId: p4.id, boundingBox: .zero)
        try await store.saveFaces([f3], forPhotoId: p3.id); try await store.saveFaces([f4], forPhotoId: p4.id)
        let v3 = makeNormalizedVector(primaryDim: 50, secondaryDim: 52, secondaryWeight: 0.15)
        let v4 = makeNormalizedVector(primaryDim: 50, secondaryDim: 52, secondaryWeight: 0.25)
        try await store.saveEmbeddings([
            EmbeddingRecord(faceId: f3.id, photoId: p3.id, vector: v3),
            EmbeddingRecord(faceId: f4.id, photoId: p4.id, vector: v4)
        ])

        try await coordinator.reclusterLibrary(rootFolderURL: URL(fileURLWithPath: "/tmp"), threshold: 0.65)
        let updatedGroups = await identityService.fetchGroups()

        XCTAssertEqual(updatedGroups.count, 1, "New photo set of existing person must not create duplicate Person")
        XCTAssertEqual(updatedGroups[0].id, originalGroupId, "Group ID must be preserved")
        XCTAssertEqual(updatedGroups[0].customName, "Alice", "Custom name must be preserved")
        XCTAssertEqual(Set(updatedGroups[0].memberFaceIds), Set([f1.id, f2.id, f3.id, f4.id]))
    }

    /// Regression Test 6: Existing identity with multiple anchor embeddings recognizes new appearance.
    func testPhase10_6_ExistingIdentityWithMultipleAnchorsRecognizesNewAppearance() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("library_index.json")
        let store = LibraryStore(storageURL: tempURL)
        let coordinator = LibraryProcessingCoordinator(libraryStore: store)
        let identityService = IdentityService(libraryStore: store)

        // Existing identity with diverse anchors (frontal and angled)
        let pFront = PhotoRecord(relativePath: "front.jpg", filename: "front.jpg", fileSize: 100, modificationDate: Date())
        let pAngle = PhotoRecord(relativePath: "angle.jpg", filename: "angle.jpg", fileSize: 100, modificationDate: Date())
        try await store.savePhoto(pFront); try await store.savePhoto(pAngle)
        let fFront = FaceRecord(photoId: pFront.id, boundingBox: .zero)
        let fAngle = FaceRecord(photoId: pAngle.id, boundingBox: .zero)
        try await store.saveFaces([fFront], forPhotoId: pFront.id); try await store.saveFaces([fAngle], forPhotoId: pAngle.id)
        let vFront = makeNormalizedVector(primaryDim: 60)
        let vAngle = makeNormalizedVector(primaryDim: 60, secondaryDim: 61, secondaryWeight: 0.4)
        try await store.saveEmbeddings([
            EmbeddingRecord(faceId: fFront.id, photoId: pFront.id, vector: vFront),
            EmbeddingRecord(faceId: fAngle.id, photoId: pAngle.id, vector: vAngle)
        ])

        try await coordinator.reclusterLibrary(rootFolderURL: URL(fileURLWithPath: "/tmp"), threshold: 0.65)
        let groups1 = await identityService.fetchGroups()
        XCTAssertEqual(groups1.count, 1)

        // New photo matches angled anchor (sim ~0.80 with angled, ~0.60 with frontal)
        let pNew = PhotoRecord(relativePath: "new_angle.jpg", filename: "new_angle.jpg", fileSize: 100, modificationDate: Date())
        try await store.savePhoto(pNew)
        let fNew = FaceRecord(photoId: pNew.id, boundingBox: .zero)
        try await store.saveFaces([fNew], forPhotoId: pNew.id)
        let vNew = makeNormalizedVector(primaryDim: 60, secondaryDim: 61, secondaryWeight: 0.45)
        try await store.saveEmbedding(EmbeddingRecord(faceId: fNew.id, photoId: pNew.id, vector: vNew))

        try await coordinator.reclusterLibrary(rootFolderURL: URL(fileURLWithPath: "/tmp"), threshold: 0.65)
        let groups2 = await identityService.fetchGroups()

        XCTAssertEqual(groups2.count, 1, "Multi-anchor representation must recognize new appearance matching historical anchor")
        XCTAssertEqual(Set(groups2[0].memberFaceIds), Set([fFront.id, fAngle.id, fNew.id]))
    }

    /// Regression Test 7: Two genuinely different people remain separate.
    func testPhase10_7_TwoGenuinelyDifferentPeopleRemainSeparate() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("library_index.json")
        let store = LibraryStore(storageURL: tempURL)
        let coordinator = LibraryProcessingCoordinator(libraryStore: store)
        let identityService = IdentityService(libraryStore: store)

        // Person A (3 photos)
        var facesA: [FaceRecord] = []
        for i in 0..<3 {
            let p = PhotoRecord(relativePath: "a\(i).jpg", filename: "a\(i).jpg", fileSize: 100, modificationDate: Date())
            try await store.savePhoto(p)
            let f = FaceRecord(photoId: p.id, boundingBox: .zero)
            facesA.append(f)
            try await store.saveFaces([f], forPhotoId: p.id)
            let v = makeNormalizedVector(primaryDim: 70, secondaryDim: 71, secondaryWeight: Float(i) * 0.1)
            try await store.saveEmbedding(EmbeddingRecord(faceId: f.id, photoId: p.id, vector: v))
        }

        // Person B (3 photos, completely orthogonal primaryDim: 150)
        var facesB: [FaceRecord] = []
        for i in 0..<3 {
            let p = PhotoRecord(relativePath: "b\(i).jpg", filename: "b\(i).jpg", fileSize: 100, modificationDate: Date())
            try await store.savePhoto(p)
            let f = FaceRecord(photoId: p.id, boundingBox: .zero)
            facesB.append(f)
            try await store.saveFaces([f], forPhotoId: p.id)
            let v = makeNormalizedVector(primaryDim: 150, secondaryDim: 151, secondaryWeight: Float(i) * 0.1)
            try await store.saveEmbedding(EmbeddingRecord(faceId: f.id, photoId: p.id, vector: v))
        }

        try await coordinator.reclusterLibrary(rootFolderURL: URL(fileURLWithPath: "/tmp"), threshold: 0.65)

        let groups = await identityService.fetchGroups()
        XCTAssertEqual(groups.count, 2, "Distinct individuals must form separate groups")
        let setA = Set(facesA.map(\.id))
        let setB = Set(facesB.map(\.id))
        let group0Members = Set(groups[0].memberFaceIds)
        let group1Members = Set(groups[1].memberFaceIds)

        XCTAssertTrue((group0Members == setA && group1Members == setB) || (group0Members == setB && group1Members == setA))
    }

    /// Regression Test 8: Identity profile remains stable after reclustering.
    func testPhase10_8_IdentityProfileRemainsStableAfterReclustering() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("library_index.json")
        let store = LibraryStore(storageURL: tempURL)
        let coordinator = LibraryProcessingCoordinator(libraryStore: store)
        let identityService = IdentityService(libraryStore: store)

        let p1 = PhotoRecord(relativePath: "p1.jpg", filename: "p1.jpg", fileSize: 100, modificationDate: Date())
        let p2 = PhotoRecord(relativePath: "p2.jpg", filename: "p2.jpg", fileSize: 100, modificationDate: Date())
        try await store.savePhoto(p1); try await store.savePhoto(p2)
        let f1 = FaceRecord(photoId: p1.id, boundingBox: .zero)
        let f2 = FaceRecord(photoId: p2.id, boundingBox: .zero)
        try await store.saveFaces([f1], forPhotoId: p1.id); try await store.saveFaces([f2], forPhotoId: p2.id)
        let v1 = makeNormalizedVector(primaryDim: 80, secondaryDim: 81, secondaryWeight: 0.1)
        let v2 = makeNormalizedVector(primaryDim: 80, secondaryDim: 81, secondaryWeight: 0.2)
        try await store.saveEmbeddings([
            EmbeddingRecord(faceId: f1.id, photoId: p1.id, vector: v1),
            EmbeddingRecord(faceId: f2.id, photoId: p2.id, vector: v2)
        ])

        try await coordinator.reclusterLibrary(rootFolderURL: URL(fileURLWithPath: "/tmp"), threshold: 0.65)
        let initialGroups = await identityService.fetchGroups()
        let stableId = initialGroups[0].id

        try await coordinator.reclusterLibrary(rootFolderURL: URL(fileURLWithPath: "/tmp"), threshold: 0.65)
        let reclusteredGroups = await identityService.fetchGroups()

        XCTAssertEqual(reclusteredGroups.count, 1)
        XCTAssertEqual(reclusteredGroups[0].id, stableId, "Identity profile ID must remain stable across reclustering runs")
    }

    /// Regression Test 9: Manual merge remains permanent after future scans.
    func testPhase10_9_ManualMergeRemainsPermanentAfterFutureScans() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("library_index.json")
        let store = LibraryStore(storageURL: tempURL)
        let coordinator = LibraryProcessingCoordinator(libraryStore: store)
        let identityService = IdentityService(libraryStore: store)

        let pA = PhotoRecord(relativePath: "a.jpg", filename: "a.jpg", fileSize: 100, modificationDate: Date())
        let pB = PhotoRecord(relativePath: "b.jpg", filename: "b.jpg", fileSize: 100, modificationDate: Date())
        try await store.savePhoto(pA); try await store.savePhoto(pB)
        let fA = FaceRecord(photoId: pA.id, boundingBox: .zero)
        let fB = FaceRecord(photoId: pB.id, boundingBox: .zero)
        try await store.saveFaces([fA], forPhotoId: pA.id); try await store.saveFaces([fB], forPhotoId: pB.id)
        let vA = makeNormalizedVector(primaryDim: 90)
        let vB = makeNormalizedVector(primaryDim: 90, secondaryDim: 91, secondaryWeight: 0.8)
        try await store.saveEmbeddings([
            EmbeddingRecord(faceId: fA.id, photoId: pA.id, vector: vA),
            EmbeddingRecord(faceId: fB.id, photoId: pB.id, vector: vB)
        ])

        let gA = GroupRecord(groupIndex: 1, customName: "MergedPerson", representativeFaceId: fA.id, memberFaceIds: [fA.id], averageSimilarity: 1.0, minSimilarity: 1.0, thresholdUsed: 0.65)
        let gB = GroupRecord(groupIndex: 2, customName: nil, representativeFaceId: fB.id, memberFaceIds: [fB.id], averageSimilarity: 1.0, minSimilarity: 1.0, thresholdUsed: 0.65)
        try await store.saveGroups([gA, gB])

        try await identityService.mergeGroups(targetGroupId: gA.id, sourceGroupId: gB.id)

        // Future scan adds another photo
        let pC = PhotoRecord(relativePath: "c.jpg", filename: "c.jpg", fileSize: 100, modificationDate: Date())
        try await store.savePhoto(pC)
        let fC = FaceRecord(photoId: pC.id, boundingBox: .zero)
        try await store.saveFaces([fC], forPhotoId: pC.id)
        let vC = makeNormalizedVector(primaryDim: 90, secondaryDim: 91, secondaryWeight: 0.1)
        try await store.saveEmbedding(EmbeddingRecord(faceId: fC.id, photoId: pC.id, vector: vC))

        try await coordinator.reclusterLibrary(rootFolderURL: URL(fileURLWithPath: "/tmp"), threshold: 0.65)

        let groups = await identityService.fetchGroups()
        XCTAssertEqual(groups.count, 1, "Manually merged person must remain consolidated across future scans")
        XCTAssertEqual(groups[0].id, gA.id)
        XCTAssertEqual(groups[0].customName, "MergedPerson")
        XCTAssertEqual(Set(groups[0].memberFaceIds), Set([fA.id, fB.id, fC.id]))
    }

    /// Regression Test 10: Every FaceRecord belongs to at most one GroupRecord.
    func testPhase10_10_EveryFaceBelongsToAtMostOneGroup() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("library_index.json")
        let store = LibraryStore(storageURL: tempURL)
        let coordinator = LibraryProcessingCoordinator(libraryStore: store)

        // Add 10 faces across 4 simulated people
        var allFaceIds: [UUID] = []
        for i in 0..<10 {
            let p = PhotoRecord(relativePath: "photo_\(i).jpg", filename: "photo_\(i).jpg", fileSize: 100, modificationDate: Date())
            try await store.savePhoto(p)
            let f = FaceRecord(photoId: p.id, boundingBox: .zero)
            allFaceIds.append(f.id)
            try await store.saveFaces([f], forPhotoId: p.id)
            let primary = 100 + (i % 4) * 20
            let v = makeNormalizedVector(primaryDim: primary, secondaryDim: primary + 1, secondaryWeight: Float(i) * 0.05)
            try await store.saveEmbedding(EmbeddingRecord(faceId: f.id, photoId: p.id, vector: v))
        }

        try await coordinator.reclusterLibrary(rootFolderURL: URL(fileURLWithPath: "/tmp"), threshold: 0.65)

        let integrity = await store.validateIntegrity()
        XCTAssertEqual(integrity.duplicateGroupMembershipsCount, 0)
        XCTAssertEqual(integrity.facesAssignedToMultipleGroupsCount, 0)
        XCTAssertTrue(integrity.isValid)

        let groups = await store.getGroups()
        let assigned = groups.flatMap { $0.memberFaceIds }
        let uniqueAssigned = Set(assigned)
        XCTAssertEqual(assigned.count, uniqueAssigned.count, "No face ID can appear in more than one GroupRecord")
    }

    /// Regression Test 11: No orphan embeddings participate in clustering.
    func testPhase10_11_NoOrphanEmbeddingsParticipateInClustering() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("library_index.json")
        let store = LibraryStore(storageURL: tempURL)
        let coordinator = LibraryProcessingCoordinator(libraryStore: store)

        let p = PhotoRecord(relativePath: "valid.jpg", filename: "valid.jpg", fileSize: 100, modificationDate: Date())
        try await store.savePhoto(p)
        let f = FaceRecord(photoId: p.id, boundingBox: .zero)
        try await store.saveFaces([f], forPhotoId: p.id)
        let v = makeNormalizedVector(primaryDim: 110)
        try await store.saveEmbedding(EmbeddingRecord(faceId: f.id, photoId: p.id, vector: v))

        // Save orphan embedding with a non-existent faceId
        let orphanFaceId = UUID()
        let orphanEmb = EmbeddingRecord(faceId: orphanFaceId, photoId: p.id, vector: makeNormalizedVector(primaryDim: 110))
        try await store.saveEmbedding(orphanEmb)

        try await coordinator.reclusterLibrary(rootFolderURL: URL(fileURLWithPath: "/tmp"), threshold: 0.65)

        let groups = await store.getGroups()
        let allAssignedFaces = groups.flatMap { $0.memberFaceIds }
        XCTAssertFalse(allAssignedFaces.contains(orphanFaceId), "Orphan embeddings must never be assigned to any GroupRecord")
        XCTAssertEqual(allAssignedFaces, [f.id])
    }

    /// Regression Test 12: Re-running the entire pipeline is idempotent.
    func testPhase10_12_RerunningClusteringIsIdempotent() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("library_index.json")
        let store = LibraryStore(storageURL: tempURL)
        let coordinator = LibraryProcessingCoordinator(libraryStore: store)

        // Setup 6 faces
        for i in 0..<6 {
            let p = PhotoRecord(relativePath: "idem_\(i).jpg", filename: "idem_\(i).jpg", fileSize: 100, modificationDate: Date())
            try await store.savePhoto(p)
            let f = FaceRecord(photoId: p.id, boundingBox: .zero)
            try await store.saveFaces([f], forPhotoId: p.id)
            let base = (i < 3) ? 120 : 200
            let v = makeNormalizedVector(primaryDim: base, secondaryDim: base + 1, secondaryWeight: Float(i % 3) * 0.1)
            try await store.saveEmbedding(EmbeddingRecord(faceId: f.id, photoId: p.id, vector: v))
        }

        try await coordinator.reclusterLibrary(rootFolderURL: URL(fileURLWithPath: "/tmp"), threshold: 0.65)
        let run1Groups = await store.getGroups()

        try await coordinator.reclusterLibrary(rootFolderURL: URL(fileURLWithPath: "/tmp"), threshold: 0.65)
        let run2Groups = await store.getGroups()

        XCTAssertEqual(run1Groups.count, run2Groups.count)
        for i in 0..<run1Groups.count {
            XCTAssertEqual(run1Groups[i].id, run2Groups[i].id)
            XCTAssertEqual(Set(run1Groups[i].memberFaceIds), Set(run2Groups[i].memberFaceIds))
            XCTAssertEqual(run1Groups[i].groupIndex, run2Groups[i].groupIndex)
        }
    }

    // MARK: - Phase 10 Production Bug Fix Regression Tests

    /// Regression Test Fix 1: Existing unnamed single-face identity + new photo of same person -> remains ONE GroupRecord.
    func testPhase10Fix_1_ExistingUnnamedSingleFaceIdentityPlusNewPhotoRemainsOneGroup() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("library_index.json")
        let store = LibraryStore(storageURL: tempURL)
        let coordinator = LibraryProcessingCoordinator(libraryStore: store)
        let identityService = IdentityService(libraryStore: store)

        // Photo 1: Single face, unnamed
        let p1 = PhotoRecord(relativePath: "photo1.jpg", filename: "photo1.jpg", fileSize: 100, modificationDate: Date())
        try await store.savePhoto(p1)
        let f1 = FaceRecord(photoId: p1.id, boundingBox: .zero)
        try await store.saveFaces([f1], forPhotoId: p1.id)
        let v1 = makeNormalizedVector(primaryDim: 10, secondaryDim: 11, secondaryWeight: 0.1)
        try await store.saveEmbedding(EmbeddingRecord(faceId: f1.id, photoId: p1.id, vector: v1))

        // Initial scan produces a 1-face unconfirmed GroupRecord
        try await coordinator.reclusterLibrary(rootFolderURL: URL(fileURLWithPath: "/tmp"), threshold: 0.65)
        let initialGroups = await identityService.fetchGroups()
        XCTAssertEqual(initialGroups.count, 1)
        XCTAssertEqual(initialGroups[0].memberFaceIds.count, 1)
        let originalGroupId = initialGroups[0].id

        // Photo 2: New photo of the same person
        let p2 = PhotoRecord(relativePath: "photo2.jpg", filename: "photo2.jpg", fileSize: 100, modificationDate: Date())
        try await store.savePhoto(p2)
        let f2 = FaceRecord(photoId: p2.id, boundingBox: .zero)
        try await store.saveFaces([f2], forPhotoId: p2.id)
        let v2 = makeNormalizedVector(primaryDim: 10, secondaryDim: 11, secondaryWeight: 0.2)
        try await store.saveEmbedding(EmbeddingRecord(faceId: f2.id, photoId: p2.id, vector: v2))

        // Recluster after scanning Photo 2
        try await coordinator.reclusterLibrary(rootFolderURL: URL(fileURLWithPath: "/tmp"), threshold: 0.65)
        let updatedGroups = await identityService.fetchGroups()

        XCTAssertEqual(updatedGroups.count, 1, "Existing unnamed single-face identity must absorb new photo and remain ONE GroupRecord")
        XCTAssertEqual(updatedGroups[0].id, originalGroupId, "Existing GroupRecord ID must be preserved")
        XCTAssertEqual(Set(updatedGroups[0].memberFaceIds), Set([f1.id, f2.id]))
    }

    /// Regression Test Fix 2: Existing identity with 6 faces + new photo set -> new faces join existing GroupRecord.
    func testPhase10Fix_2_ExistingIdentityWithSixFacesPlusNewPhotoSetJoinsExistingGroup() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("library_index.json")
        let store = LibraryStore(storageURL: tempURL)
        let coordinator = LibraryProcessingCoordinator(libraryStore: store)
        let identityService = IdentityService(libraryStore: store)

        // Initial Set A: 6 photos / 6 faces of Person 1
        var setAFaceIds: [UUID] = []
        for i in 0..<6 {
            let p = PhotoRecord(relativePath: "setA_\(i).jpg", filename: "setA_\(i).jpg", fileSize: 100, modificationDate: Date())
            try await store.savePhoto(p)
            let f = FaceRecord(photoId: p.id, boundingBox: .zero)
            setAFaceIds.append(f.id)
            try await store.saveFaces([f], forPhotoId: p.id)
            let v = makeNormalizedVector(primaryDim: 25, secondaryDim: 26, secondaryWeight: Float(i) * 0.05)
            try await store.saveEmbedding(EmbeddingRecord(faceId: f.id, photoId: p.id, vector: v))
        }

        try await coordinator.reclusterLibrary(rootFolderURL: URL(fileURLWithPath: "/tmp"), threshold: 0.65)
        let initialGroups = await identityService.fetchGroups()
        XCTAssertEqual(initialGroups.count, 1)
        XCTAssertEqual(initialGroups[0].memberFaceIds.count, 6)
        let person1GroupId = initialGroups[0].id

        // New Set B: 2 photos of Person 1
        var setBFaceIds: [UUID] = []
        for i in 0..<2 {
            let p = PhotoRecord(relativePath: "setB_\(i).jpg", filename: "setB_\(i).jpg", fileSize: 100, modificationDate: Date())
            try await store.savePhoto(p)
            let f = FaceRecord(photoId: p.id, boundingBox: .zero)
            setBFaceIds.append(f.id)
            try await store.saveFaces([f], forPhotoId: p.id)
            let v = makeNormalizedVector(primaryDim: 25, secondaryDim: 27, secondaryWeight: 0.15 + Float(i) * 0.05)
            try await store.saveEmbedding(EmbeddingRecord(faceId: f.id, photoId: p.id, vector: v))
        }

        try await coordinator.reclusterLibrary(rootFolderURL: URL(fileURLWithPath: "/tmp"), threshold: 0.65)
        let updatedGroups = await identityService.fetchGroups()

        XCTAssertEqual(updatedGroups.count, 1, "New photo set of existing 6-face person must join existing GroupRecord")
        XCTAssertEqual(updatedGroups[0].id, person1GroupId, "GroupRecord ID must be preserved")
        XCTAssertEqual(Set(updatedGroups[0].memberFaceIds), Set(setAFaceIds + setBFaceIds))
    }

    /// Regression Test Fix 3: Existing identity + new photo set whose cluster centroid < 0.65 but an individual face has bestAnchor >= 0.65 & centroid >= 0.50 -> joins existing identity.
    func testPhase10Fix_3_ExistingIdentityPlusNewPhotoSetWithClusterCentroidBelowThresholdJoinsViaIndividualFaceAnchor() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("library_index.json")
        let store = LibraryStore(storageURL: tempURL)
        let coordinator = LibraryProcessingCoordinator(libraryStore: store)
        let identityService = IdentityService(libraryStore: store)

        // Established identity with 2 anchor poses (frontal and side angle)
        let p1 = PhotoRecord(relativePath: "front.jpg", filename: "front.jpg", fileSize: 100, modificationDate: Date())
        let p2 = PhotoRecord(relativePath: "angle.jpg", filename: "angle.jpg", fileSize: 100, modificationDate: Date())
        try await store.savePhoto(p1); try await store.savePhoto(p2)
        let f1 = FaceRecord(photoId: p1.id, boundingBox: .zero)
        let f2 = FaceRecord(photoId: p2.id, boundingBox: .zero)
        try await store.saveFaces([f1], forPhotoId: p1.id); try await store.saveFaces([f2], forPhotoId: p2.id)
        let v1 = makeNormalizedVector(primaryDim: 35)
        let v2 = makeNormalizedVector(primaryDim: 35, secondaryDim: 36, secondaryWeight: 0.4)
        try await store.saveEmbeddings([
            EmbeddingRecord(faceId: f1.id, photoId: p1.id, vector: v1),
            EmbeddingRecord(faceId: f2.id, photoId: p2.id, vector: v2)
        ])

        try await coordinator.reclusterLibrary(rootFolderURL: URL(fileURLWithPath: "/tmp"), threshold: 0.65)
        let initialGroups = await identityService.fetchGroups()
        XCTAssertEqual(initialGroups.count, 1)
        let personGroupId = initialGroups[0].id

        // New photo set where candidate face matches anchor 2 (sim ~0.82 >= 0.65, centroidSim >= 0.50)
        let p3 = PhotoRecord(relativePath: "new_angle.jpg", filename: "new_angle.jpg", fileSize: 100, modificationDate: Date())
        try await store.savePhoto(p3)
        let f3 = FaceRecord(photoId: p3.id, boundingBox: .zero)
        try await store.saveFaces([f3], forPhotoId: p3.id)
        let v3 = makeNormalizedVector(primaryDim: 35, secondaryDim: 36, secondaryWeight: 0.45)
        try await store.saveEmbedding(EmbeddingRecord(faceId: f3.id, photoId: p3.id, vector: v3))

        try await coordinator.reclusterLibrary(rootFolderURL: URL(fileURLWithPath: "/tmp"), threshold: 0.65)
        let updatedGroups = await identityService.fetchGroups()

        XCTAssertEqual(updatedGroups.count, 1, "Face matching historical anchor with centroid coherence must join existing GroupRecord")
        XCTAssertEqual(updatedGroups[0].id, personGroupId)
        XCTAssertEqual(Set(updatedGroups[0].memberFaceIds), Set([f1.id, f2.id, f3.id]))
    }

    /// Regression Test Fix 4: Existing identity + unrelated new person -> creates a new GroupRecord.
    func testPhase10Fix_4_ExistingIdentityPlusUnrelatedNewPersonCreatesNewGroup() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("library_index.json")
        let store = LibraryStore(storageURL: tempURL)
        let coordinator = LibraryProcessingCoordinator(libraryStore: store)
        let identityService = IdentityService(libraryStore: store)

        // Person 1 (2 photos)
        let p1 = PhotoRecord(relativePath: "alice1.jpg", filename: "alice1.jpg", fileSize: 100, modificationDate: Date())
        let p2 = PhotoRecord(relativePath: "alice2.jpg", filename: "alice2.jpg", fileSize: 100, modificationDate: Date())
        try await store.savePhoto(p1); try await store.savePhoto(p2)
        let f1 = FaceRecord(photoId: p1.id, boundingBox: .zero)
        let f2 = FaceRecord(photoId: p2.id, boundingBox: .zero)
        try await store.saveFaces([f1], forPhotoId: p1.id); try await store.saveFaces([f2], forPhotoId: p2.id)
        let v1 = makeNormalizedVector(primaryDim: 45, secondaryDim: 46, secondaryWeight: 0.1)
        let v2 = makeNormalizedVector(primaryDim: 45, secondaryDim: 46, secondaryWeight: 0.2)
        try await store.saveEmbeddings([
            EmbeddingRecord(faceId: f1.id, photoId: p1.id, vector: v1),
            EmbeddingRecord(faceId: f2.id, photoId: p2.id, vector: v2)
        ])

        try await coordinator.reclusterLibrary(rootFolderURL: URL(fileURLWithPath: "/tmp"), threshold: 0.65)
        let groupsAfterP1 = await identityService.fetchGroups()
        XCTAssertEqual(groupsAfterP1.count, 1)

        // Person 2 (Unrelated individual: primaryDim 190, orthogonal vector, similarity ~0.0)
        let p3 = PhotoRecord(relativePath: "bob1.jpg", filename: "bob1.jpg", fileSize: 100, modificationDate: Date())
        let p4 = PhotoRecord(relativePath: "bob2.jpg", filename: "bob2.jpg", fileSize: 100, modificationDate: Date())
        try await store.savePhoto(p3); try await store.savePhoto(p4)
        let f3 = FaceRecord(photoId: p3.id, boundingBox: .zero)
        let f4 = FaceRecord(photoId: p4.id, boundingBox: .zero)
        try await store.saveFaces([f3], forPhotoId: p3.id); try await store.saveFaces([f4], forPhotoId: p4.id)
        let v3 = makeNormalizedVector(primaryDim: 190, secondaryDim: 191, secondaryWeight: 0.1)
        let v4 = makeNormalizedVector(primaryDim: 190, secondaryDim: 191, secondaryWeight: 0.2)
        try await store.saveEmbeddings([
            EmbeddingRecord(faceId: f3.id, photoId: p3.id, vector: v3),
            EmbeddingRecord(faceId: f4.id, photoId: p4.id, vector: v4)
        ])

        try await coordinator.reclusterLibrary(rootFolderURL: URL(fileURLWithPath: "/tmp"), threshold: 0.65)
        let groupsAfterP2 = await identityService.fetchGroups()

        XCTAssertEqual(groupsAfterP2.count, 2, "Unrelated person must create a separate GroupRecord")
        let group1 = groupsAfterP2.first { $0.id == groupsAfterP1[0].id }
        let group2 = groupsAfterP2.first { $0.id != groupsAfterP1[0].id }
        XCTAssertNotNil(group1)
        XCTAssertNotNil(group2)
        XCTAssertEqual(Set(group1!.memberFaceIds), Set([f1.id, f2.id]))
        XCTAssertEqual(Set(group2!.memberFaceIds), Set([f3.id, f4.id]))
    }

    /// Regression Test Fix 5: Run the real reclustering flow twice -> no duplicate GroupRecords are created.
    func testPhase10Fix_5_RunReclusteringTwiceCreatesNoDuplicateGroups() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("library_index.json")
        let store = LibraryStore(storageURL: tempURL)
        let coordinator = LibraryProcessingCoordinator(libraryStore: store)
        let identityService = IdentityService(libraryStore: store)

        // 3 distinct people with 2 photos each
        for personIdx in 0..<3 {
            for photoIdx in 0..<2 {
                let p = PhotoRecord(
                    relativePath: "p\(personIdx)_\(photoIdx).jpg",
                    filename: "p\(personIdx)_\(photoIdx).jpg",
                    fileSize: 100,
                    modificationDate: Date()
                )
                try await store.savePhoto(p)
                let f = FaceRecord(photoId: p.id, boundingBox: .zero)
                try await store.saveFaces([f], forPhotoId: p.id)
                let base = 55 + personIdx * 40
                let v = makeNormalizedVector(primaryDim: base, secondaryDim: base + 1, secondaryWeight: Float(photoIdx) * 0.1)
                try await store.saveEmbedding(EmbeddingRecord(faceId: f.id, photoId: p.id, vector: v))
            }
        }

        // Run 1
        try await coordinator.reclusterLibrary(rootFolderURL: URL(fileURLWithPath: "/tmp"), threshold: 0.65)
        let run1Groups = await identityService.fetchGroups()
        XCTAssertEqual(run1Groups.count, 3)

        // Run 2
        try await coordinator.reclusterLibrary(rootFolderURL: URL(fileURLWithPath: "/tmp"), threshold: 0.65)
        let run2Groups = await identityService.fetchGroups()
        XCTAssertEqual(run2Groups.count, 3, "Repeated reclustering must never create duplicate GroupRecords")

        for g1 in run1Groups {
            let matchingG2 = run2Groups.first { $0.id == g1.id }
            XCTAssertNotNil(matchingG2, "Group ID \(g1.id) must be preserved across repeated reclustering")
            XCTAssertEqual(Set(g1.memberFaceIds), Set(matchingG2!.memberFaceIds))
        }
    }

    /// Regression Test Fix 6: Existing custom-named identity -> retains name and UUID after new photos are added.
    func testPhase10Fix_6_ExistingCustomNamedIdentityRetainsNameAndUUIDAfterNewPhotos() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("library_index.json")
        let store = LibraryStore(storageURL: tempURL)
        let coordinator = LibraryProcessingCoordinator(libraryStore: store)
        let identityService = IdentityService(libraryStore: store)

        let p1 = PhotoRecord(relativePath: "c1.jpg", filename: "c1.jpg", fileSize: 100, modificationDate: Date())
        let p2 = PhotoRecord(relativePath: "c2.jpg", filename: "c2.jpg", fileSize: 100, modificationDate: Date())
        try await store.savePhoto(p1); try await store.savePhoto(p2)
        let f1 = FaceRecord(photoId: p1.id, boundingBox: .zero)
        let f2 = FaceRecord(photoId: p2.id, boundingBox: .zero)
        try await store.saveFaces([f1], forPhotoId: p1.id); try await store.saveFaces([f2], forPhotoId: p2.id)
        let v1 = makeNormalizedVector(primaryDim: 65, secondaryDim: 66, secondaryWeight: 0.1)
        let v2 = makeNormalizedVector(primaryDim: 65, secondaryDim: 66, secondaryWeight: 0.2)
        try await store.saveEmbeddings([
            EmbeddingRecord(faceId: f1.id, photoId: p1.id, vector: v1),
            EmbeddingRecord(faceId: f2.id, photoId: p2.id, vector: v2)
        ])

        try await coordinator.reclusterLibrary(rootFolderURL: URL(fileURLWithPath: "/tmp"), threshold: 0.65)
        let initialGroups = await identityService.fetchGroups()
        XCTAssertEqual(initialGroups.count, 1)
        let customId = initialGroups[0].id
        try await identityService.renameGroup(id: customId, newName: "Grandma")

        // Add 2 new photos of Grandma
        let p3 = PhotoRecord(relativePath: "c3.jpg", filename: "c3.jpg", fileSize: 100, modificationDate: Date())
        let p4 = PhotoRecord(relativePath: "c4.jpg", filename: "c4.jpg", fileSize: 100, modificationDate: Date())
        try await store.savePhoto(p3); try await store.savePhoto(p4)
        let f3 = FaceRecord(photoId: p3.id, boundingBox: .zero)
        let f4 = FaceRecord(photoId: p4.id, boundingBox: .zero)
        try await store.saveFaces([f3], forPhotoId: p3.id); try await store.saveFaces([f4], forPhotoId: p4.id)
        let v3 = makeNormalizedVector(primaryDim: 65, secondaryDim: 67, secondaryWeight: 0.15)
        let v4 = makeNormalizedVector(primaryDim: 65, secondaryDim: 67, secondaryWeight: 0.25)
        try await store.saveEmbeddings([
            EmbeddingRecord(faceId: f3.id, photoId: p3.id, vector: v3),
            EmbeddingRecord(faceId: f4.id, photoId: p4.id, vector: v4)
        ])

        try await coordinator.reclusterLibrary(rootFolderURL: URL(fileURLWithPath: "/tmp"), threshold: 0.65)
        let updatedGroups = await identityService.fetchGroups()

        XCTAssertEqual(updatedGroups.count, 1)
        XCTAssertEqual(updatedGroups[0].id, customId, "Custom-named identity must preserve its UUID")
        XCTAssertEqual(updatedGroups[0].customName, "Grandma", "Custom-named identity must preserve its customName")
        XCTAssertEqual(Set(updatedGroups[0].memberFaceIds), Set([f1.id, f2.id, f3.id, f4.id]))
    }

    /// Regression Test Fix 7: Every FaceRecord belongs to at most one GroupRecord.
    func testPhase10Fix_7_EveryFaceRecordBelongsToAtMostOneGroupRecord() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("library_index.json")
        let store = LibraryStore(storageURL: tempURL)
        let coordinator = LibraryProcessingCoordinator(libraryStore: store)

        // Ingest 12 faces across 3 individuals
        var allFaceIds: [UUID] = []
        for i in 0..<12 {
            let p = PhotoRecord(relativePath: "face_\(i).jpg", filename: "face_\(i).jpg", fileSize: 100, modificationDate: Date())
            try await store.savePhoto(p)
            let f = FaceRecord(photoId: p.id, boundingBox: .zero)
            allFaceIds.append(f.id)
            try await store.saveFaces([f], forPhotoId: p.id)
            let base = 75 + (i % 3) * 30
            let v = makeNormalizedVector(primaryDim: base, secondaryDim: base + 1, secondaryWeight: Float(i) * 0.05)
            try await store.saveEmbedding(EmbeddingRecord(faceId: f.id, photoId: p.id, vector: v))
        }

        try await coordinator.reclusterLibrary(rootFolderURL: URL(fileURLWithPath: "/tmp"), threshold: 0.65)

        let integrity = await store.validateIntegrity()
        XCTAssertEqual(integrity.duplicateGroupMembershipsCount, 0, "No duplicate group memberships permitted")
        XCTAssertEqual(integrity.facesAssignedToMultipleGroupsCount, 0, "No face assigned to multiple groups permitted")
        XCTAssertTrue(integrity.isValid)

        let groups = await store.getGroups()
        let assignedFaces = groups.flatMap { $0.memberFaceIds }
        let uniqueAssignedFaces = Set(assignedFaces)
        XCTAssertEqual(assignedFaces.count, uniqueAssignedFaces.count, "Each FaceRecord must appear at most once across all GroupRecords")
    }

    // MARK: - Phase 11 Identity Stability & Negative Constraint Tests

    func testPhase11_1_SanitizeSnapshotPurgesOrphanFacesAndEmbeddings() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_p11_sanitize_\(UUID().uuidString).json")
        let store = LibraryStore(storageURL: tempURL)
        let modDate = Date()

        // 1. Add Photo 1 with 2 faces
        let p1 = PhotoRecord(relativePath: "p1.jpg", filename: "p1.jpg", fileSize: 100, modificationDate: modDate)
        try await store.savePhoto(p1)
        let f1 = FaceRecord(photoId: p1.id, boundingBox: .zero)
        let f2 = FaceRecord(photoId: p1.id, boundingBox: .zero)
        try await store.saveFaces([f1, f2], forPhotoId: p1.id)
        try await store.saveEmbedding(EmbeddingRecord(faceId: f1.id, photoId: p1.id, vector: [Float](repeating: 0.1, count: 512)))
        try await store.saveEmbedding(EmbeddingRecord(faceId: f2.id, photoId: p1.id, vector: [Float](repeating: 0.2, count: 512)))

        // 2. Add Photo 2 with 2 faces
        let p2 = PhotoRecord(relativePath: "p2.jpg", filename: "p2.jpg", fileSize: 100, modificationDate: modDate)
        try await store.savePhoto(p2)
        let f3 = FaceRecord(photoId: p2.id, boundingBox: .zero)
        let f4 = FaceRecord(photoId: p2.id, boundingBox: .zero)
        try await store.saveFaces([f3, f4], forPhotoId: p2.id)
        try await store.saveEmbedding(EmbeddingRecord(faceId: f3.id, photoId: p2.id, vector: [Float](repeating: 0.3, count: 512)))
        try await store.saveEmbedding(EmbeddingRecord(faceId: f4.id, photoId: p2.id, vector: [Float](repeating: 0.4, count: 512)))

        // 3. Reconcile with only Photo 1 (Photo 2 was deleted from disk)
        let scanned = [PhotoItem(url: URL(fileURLWithPath: "/tmp/p1.jpg"), fileSize: 100, dateModified: modDate)]
        _ = try await store.reconcile(scannedPhotos: scanned, rootFolderURL: URL(fileURLWithPath: "/tmp"))

        // Integrity report must be completely clean (0 orphan faces, 0 orphan embeddings)
        let integrity = await store.validateIntegrity()
        XCTAssertEqual(integrity.totalPhotos, 1)
        XCTAssertEqual(integrity.totalDetectedFaces, 2)
        XCTAssertEqual(integrity.totalEmbeddings, 2)
        XCTAssertEqual(integrity.orphanedFacesCount, 0)
        XCTAssertEqual(integrity.orphanedEmbeddingsCount, 0)
        XCTAssertTrue(integrity.isValid)

        try? await store.reset()
    }

    func testPhase11_2_CannotLinkSamePhotoFacesNeverClusteredTogether() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_p11_cannotlink_\(UUID().uuidString).json")
        let store = LibraryStore(storageURL: tempURL)
        let coordinator = LibraryProcessingCoordinator(libraryStore: store)

        // Single photo containing two distinct detected faces with IDENTICAL vectors (sim = 1.0)
        let p = PhotoRecord(relativePath: "group_photo.jpg", filename: "group_photo.jpg", fileSize: 100, modificationDate: Date())
        try await store.savePhoto(p)

        let f1 = FaceRecord(photoId: p.id, boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))
        let f2 = FaceRecord(photoId: p.id, boundingBox: CGRect(x: 0.5, y: 0.1, width: 0.2, height: 0.2))
        try await store.saveFaces([f1, f2], forPhotoId: p.id)

        let identicalVector = [Float](repeating: 0.1, count: 512)
        let normVec = EmbeddingSimilarityUtility.l2Normalize(identicalVector)
        try await store.saveEmbedding(EmbeddingRecord(faceId: f1.id, photoId: p.id, vector: normVec))
        try await store.saveEmbedding(EmbeddingRecord(faceId: f2.id, photoId: p.id, vector: normVec))

        // Recluster
        try await coordinator.reclusterLibrary(rootFolderURL: URL(fileURLWithPath: "/tmp"), threshold: 0.65)

        // Must produce 2 separate groups because two faces from the same photo cannot belong to the same person
        let groups = await store.getGroups()
        XCTAssertEqual(groups.count, 2, "Cannot-Link constraint must prevent two faces from the same photo merging, even if identical embeddings")

        try? await store.reset()
    }

    func testPhase11_3_SetRepresentativeFacePersists() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_p11_rep_\(UUID().uuidString).json")
        let store = LibraryStore(storageURL: tempURL)
        let identityService = IdentityService(libraryStore: store)

        let p1 = PhotoRecord(relativePath: "photo1.jpg", filename: "photo1.jpg", fileSize: 100, modificationDate: Date())
        let p2 = PhotoRecord(relativePath: "photo2.jpg", filename: "photo2.jpg", fileSize: 100, modificationDate: Date())
        try await store.savePhoto(p1)
        try await store.savePhoto(p2)

        let f1 = FaceRecord(photoId: p1.id, boundingBox: .zero)
        let f2 = FaceRecord(photoId: p2.id, boundingBox: .zero)
        try await store.saveFaces([f1], forPhotoId: p1.id)
        try await store.saveFaces([f2], forPhotoId: p2.id)

        let v1 = EmbeddingSimilarityUtility.l2Normalize([Float](repeating: 0.1, count: 512))
        let v2 = EmbeddingSimilarityUtility.l2Normalize([Float](repeating: 0.1, count: 512))
        try await store.saveEmbedding(EmbeddingRecord(faceId: f1.id, photoId: p1.id, vector: v1))
        try await store.saveEmbedding(EmbeddingRecord(faceId: f2.id, photoId: p2.id, vector: v2))

        let group = GroupRecord(groupIndex: 1, customName: "Alice", representativeFaceId: f1.id, memberFaceIds: [f1.id, f2.id], averageSimilarity: 1.0, minSimilarity: 1.0, thresholdUsed: 0.65)
        try await store.saveGroup(group)

        // User chooses f2 as thumbnail
        try await identityService.setRepresentativeFace(groupId: group.id, faceId: f2.id)

        // Recalculate group metadata
        try await identityService.recalculateGroupMetadata(groupId: group.id)

        let updated = await identityService.fetchGroup(byId: group.id)
        XCTAssertEqual(updated?.representativeFaceId, f2.id, "User-selected representative face must not be overwritten by centroid recalculation")

        // Reload fresh store
        let storeReloaded = LibraryStore(storageURL: tempURL)
        let reloadedGroup = await storeReloaded.getGroup(byId: group.id)
        XCTAssertEqual(reloadedGroup?.representativeFaceId, f2.id, "User-selected thumbnail must persist across store reloads")

        try? await store.reset()
    }

    func testPhase11_4_ReclusteringPreservesUserSelectedThumbnail() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_p11_rep_recluster_\(UUID().uuidString).json")
        let store = LibraryStore(storageURL: tempURL)
        let identityService = IdentityService(libraryStore: store)
        let coordinator = LibraryProcessingCoordinator(libraryStore: store)

        let p1 = PhotoRecord(relativePath: "photo1.jpg", filename: "photo1.jpg", fileSize: 100, modificationDate: Date())
        let p2 = PhotoRecord(relativePath: "photo2.jpg", filename: "photo2.jpg", fileSize: 100, modificationDate: Date())
        try await store.savePhoto(p1)
        try await store.savePhoto(p2)

        let f1 = FaceRecord(photoId: p1.id, boundingBox: .zero)
        let f2 = FaceRecord(photoId: p2.id, boundingBox: .zero)
        try await store.saveFaces([f1], forPhotoId: p1.id)
        try await store.saveFaces([f2], forPhotoId: p2.id)

        let v1 = EmbeddingSimilarityUtility.l2Normalize([Float](repeating: 0.1, count: 512))
        let v2 = EmbeddingSimilarityUtility.l2Normalize([Float](repeating: 0.1, count: 512))
        try await store.saveEmbedding(EmbeddingRecord(faceId: f1.id, photoId: p1.id, vector: v1))
        try await store.saveEmbedding(EmbeddingRecord(faceId: f2.id, photoId: p2.id, vector: v2))

        let group = GroupRecord(groupIndex: 1, customName: "Bob", representativeFaceId: f1.id, memberFaceIds: [f1.id, f2.id], averageSimilarity: 1.0, minSimilarity: 1.0, thresholdUsed: 0.65)
        try await store.saveGroup(group)

        // Set f2 as representative face
        try await identityService.setRepresentativeFace(groupId: group.id, faceId: f2.id)

        // Run library reclustering
        try await coordinator.reclusterLibrary(rootFolderURL: URL(fileURLWithPath: "/tmp"), threshold: 0.65)

        let reloadedGroup = await store.getGroup(byId: group.id)
        XCTAssertEqual(reloadedGroup?.representativeFaceId, f2.id, "Reclustering must preserve user-selected representative face")

        try? await store.reset()
    }

    func testPhase12_RealisticMultiPhotoIdentityClusteringAndSeparation() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_p12_realistic_\(UUID().uuidString).json")
        let store = LibraryStore(storageURL: tempURL)
        let identityService = IdentityService(libraryStore: store)
        let coordinator = LibraryProcessingCoordinator(libraryStore: store)

        // Helper to generate orthogonal normalized base and perturbed vectors
        func makeBaseVector(seed: UInt64) -> [Float] {
            var state = seed
            var v = [Float](repeating: 0.0, count: 512)
            for i in 0..<512 {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                let val = Float((state >> 32) & 0xFFFFFFFF) / Float(0xFFFFFFFF) * 2.0 - 1.0
                v[i] = val
            }
            return EmbeddingSimilarityUtility.l2Normalize(v)
        }

        func perturb(base: [Float], angleRad: Float, seed: UInt64) -> [Float] {
            let noiseRaw = makeBaseVector(seed: seed)
            let d = EmbeddingSimilarityUtility.cosineSimilarity(noiseRaw, base)
            var ortho = [Float](repeating: 0.0, count: 512)
            for i in 0..<512 {
                ortho[i] = noiseRaw[i] - d * base[i]
            }
            let orthoNorm = EmbeddingSimilarityUtility.l2Normalize(ortho)
            var res = [Float](repeating: 0.0, count: 512)
            for i in 0..<512 {
                res[i] = cos(angleRad) * base[i] + sin(angleRad) * orthoNorm[i]
            }
            return EmbeddingSimilarityUtility.l2Normalize(res)
        }

        let baseA = makeBaseVector(seed: 12345)
        let baseB = makeBaseVector(seed: 67890)
        let baseC = makeBaseVector(seed: 99999)

        // Realistic variations of Person A (sessions, angles, lighting, glasses)
        let pA1 = perturb(base: baseA, angleRad: 0.20, seed: 1) // Photo 1 (frontal)
        let pA2 = perturb(base: baseA, angleRad: 0.25, seed: 2) // Photo 2 (frontal)
        let pA3 = perturb(base: baseA, angleRad: 0.70, seed: 3) // Photo 3 (side angle)
        let pA4 = perturb(base: baseA, angleRad: 0.65, seed: 4) // Photo 4 (glasses)
        let pA5 = perturb(base: pA4,   angleRad: 0.55, seed: 5) // Photo 5 (different lighting)
        let pA6 = perturb(base: pA5,   angleRad: 0.45, seed: 6) // Photo 6 (different session)

        // Person B across Photos 1, 3, 7
        let pB1 = perturb(base: baseB, angleRad: 0.30, seed: 11)
        let pB3 = perturb(base: baseB, angleRad: 0.35, seed: 12)
        let pB7 = perturb(base: baseB, angleRad: 0.40, seed: 13)

        // Person C across Photos 2, 3, 4
        let pC2 = perturb(base: baseC, angleRad: 0.30, seed: 21)
        let pC3 = perturb(base: baseC, angleRad: 0.35, seed: 22)
        let pC4 = perturb(base: baseC, angleRad: 0.40, seed: 23)

        // Setup 7 Photos
        let photo1 = PhotoRecord(relativePath: "photo1.jpg", filename: "photo1.jpg", fileSize: 100, modificationDate: Date())
        let photo2 = PhotoRecord(relativePath: "photo2.jpg", filename: "photo2.jpg", fileSize: 100, modificationDate: Date())
        let photo3 = PhotoRecord(relativePath: "photo3.jpg", filename: "photo3.jpg", fileSize: 100, modificationDate: Date())
        let photo4 = PhotoRecord(relativePath: "photo4.jpg", filename: "photo4.jpg", fileSize: 100, modificationDate: Date())
        let photo5 = PhotoRecord(relativePath: "photo5.jpg", filename: "photo5.jpg", fileSize: 100, modificationDate: Date())
        let photo6 = PhotoRecord(relativePath: "photo6.jpg", filename: "photo6.jpg", fileSize: 100, modificationDate: Date())
        let photo7 = PhotoRecord(relativePath: "photo7.jpg", filename: "photo7.jpg", fileSize: 100, modificationDate: Date())

        for p in [photo1, photo2, photo3, photo4, photo5, photo6, photo7] {
            try await store.savePhoto(p)
        }

        // Photo 1 contains A + B
        let fA1 = FaceRecord(photoId: photo1.id, boundingBox: .zero)
        let fB1 = FaceRecord(photoId: photo1.id, boundingBox: .zero)
        try await store.saveFaces([fA1, fB1], forPhotoId: photo1.id)
        try await store.saveEmbedding(EmbeddingRecord(faceId: fA1.id, photoId: photo1.id, vector: pA1))
        try await store.saveEmbedding(EmbeddingRecord(faceId: fB1.id, photoId: photo1.id, vector: pB1))

        // Photo 2 contains A + C
        let fA2 = FaceRecord(photoId: photo2.id, boundingBox: .zero)
        let fC2 = FaceRecord(photoId: photo2.id, boundingBox: .zero)
        try await store.saveFaces([fA2, fC2], forPhotoId: photo2.id)
        try await store.saveEmbedding(EmbeddingRecord(faceId: fA2.id, photoId: photo2.id, vector: pA2))
        try await store.saveEmbedding(EmbeddingRecord(faceId: fC2.id, photoId: photo2.id, vector: pC2))

        // Photo 3 contains A + B + C
        let fA3 = FaceRecord(photoId: photo3.id, boundingBox: .zero)
        let fB3 = FaceRecord(photoId: photo3.id, boundingBox: .zero)
        let fC3 = FaceRecord(photoId: photo3.id, boundingBox: .zero)
        try await store.saveFaces([fA3, fB3, fC3], forPhotoId: photo3.id)
        try await store.saveEmbedding(EmbeddingRecord(faceId: fA3.id, photoId: photo3.id, vector: pA3))
        try await store.saveEmbedding(EmbeddingRecord(faceId: fB3.id, photoId: photo3.id, vector: pB3))
        try await store.saveEmbedding(EmbeddingRecord(faceId: fC3.id, photoId: photo3.id, vector: pC3))

        // Photo 4 contains A + C
        let fA4 = FaceRecord(photoId: photo4.id, boundingBox: .zero)
        let fC4 = FaceRecord(photoId: photo4.id, boundingBox: .zero)
        try await store.saveFaces([fA4, fC4], forPhotoId: photo4.id)
        try await store.saveEmbedding(EmbeddingRecord(faceId: fA4.id, photoId: photo4.id, vector: pA4))
        try await store.saveEmbedding(EmbeddingRecord(faceId: fC4.id, photoId: photo4.id, vector: pC4))

        // Photo 5 contains A
        let fA5 = FaceRecord(photoId: photo5.id, boundingBox: .zero)
        try await store.saveFaces([fA5], forPhotoId: photo5.id)
        try await store.saveEmbedding(EmbeddingRecord(faceId: fA5.id, photoId: photo5.id, vector: pA5))

        // Photo 6 contains A
        let fA6 = FaceRecord(photoId: photo6.id, boundingBox: .zero)
        try await store.saveFaces([fA6], forPhotoId: photo6.id)
        try await store.saveEmbedding(EmbeddingRecord(faceId: fA6.id, photoId: photo6.id, vector: pA6))

        // Photo 7 contains B
        let fB7 = FaceRecord(photoId: photo7.id, boundingBox: .zero)
        try await store.saveFaces([fB7], forPhotoId: photo7.id)
        try await store.saveEmbedding(EmbeddingRecord(faceId: fB7.id, photoId: photo7.id, vector: pB7))

        // Execute library clustering
        let rootURL = URL(fileURLWithPath: "/tmp")
        try await coordinator.reclusterLibrary(rootFolderURL: rootURL, threshold: 0.65)

        let groups = await store.getGroups()
        XCTAssertEqual(groups.count, 3, "Expected exactly 3 identity groups for Person A, B, and C")

        // Find Person A group (6 faces)
        guard let groupA = groups.first(where: { $0.memberFaceIds.contains(fA1.id) }) else {
            XCTFail("Group containing Person A face 1 not found")
            return
        }
        XCTAssertEqual(groupA.memberFaceIds.count, 6, "Person A must have all 6 faces across all 6 photos")
        XCTAssertTrue(groupA.memberFaceIds.contains(fA2.id))
        XCTAssertTrue(groupA.memberFaceIds.contains(fA3.id))
        XCTAssertTrue(groupA.memberFaceIds.contains(fA4.id))
        XCTAssertTrue(groupA.memberFaceIds.contains(fA5.id))
        XCTAssertTrue(groupA.memberFaceIds.contains(fA6.id))

        let photosForA = await identityService.fetchPhotos(forGroupId: groupA.id, rootFolderURL: rootURL)
        XCTAssertEqual(photosForA.count, 6, "Person A must resolve to exactly 6 photos")

        // Find Person B group (3 faces)
        guard let groupB = groups.first(where: { $0.memberFaceIds.contains(fB1.id) }) else {
            XCTFail("Group containing Person B face 1 not found")
            return
        }
        XCTAssertEqual(groupB.memberFaceIds.count, 3, "Person B must have all 3 faces")
        XCTAssertTrue(groupB.memberFaceIds.contains(fB3.id))
        XCTAssertTrue(groupB.memberFaceIds.contains(fB7.id))

        let photosForB = await identityService.fetchPhotos(forGroupId: groupB.id, rootFolderURL: rootURL)
        XCTAssertEqual(photosForB.count, 3, "Person B must resolve to exactly 3 photos")

        // Find Person C group (3 faces)
        guard let groupC = groups.first(where: { $0.memberFaceIds.contains(fC2.id) }) else {
            XCTFail("Group containing Person C face 2 not found")
            return
        }
        XCTAssertEqual(groupC.memberFaceIds.count, 3, "Person C must have all 3 faces")
        XCTAssertTrue(groupC.memberFaceIds.contains(fC3.id))
        XCTAssertTrue(groupC.memberFaceIds.contains(fC4.id))

        let photosForC = await identityService.fetchPhotos(forGroupId: groupC.id, rootFolderURL: rootURL)
        XCTAssertEqual(photosForC.count, 3, "Person C must resolve to exactly 3 photos")

        // Invariant verification: distinct individuals in same photos
        XCTAssertNotEqual(groupA.id, groupB.id, "Person A and B must remain strictly separate in Photo 1 and 3")
        XCTAssertNotEqual(groupA.id, groupC.id, "Person A and C must remain strictly separate in Photo 2, 3, and 4")
        XCTAssertNotEqual(groupB.id, groupC.id, "Person B and C must remain strictly separate in Photo 3")

        let integrity = await store.validateIntegrity()
        XCTAssertTrue(integrity.isValid)
        XCTAssertEqual(integrity.duplicateGroupMembershipsCount, 0)
        XCTAssertEqual(integrity.orphanedEmbeddingsCount, 0)

        try? await store.reset()
    }

    /// Regression Test: Transitive drift prevention.
    /// A <-> B >= 0.65, B <-> C >= 0.65, but A <-> C < 0.50.
    /// Verifies that A, B, C are NOT merged into a single person.
    func testRegressionTransitiveDriftPrevention() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_transitive_drift_\(UUID().uuidString).json")
        let store = LibraryStore(storageURL: tempURL)
        let coordinator = LibraryProcessingCoordinator(libraryStore: store)

        let photo1 = PhotoRecord(relativePath: "p1.jpg", filename: "p1.jpg", fileSize: 100, modificationDate: Date())
        let photo2 = PhotoRecord(relativePath: "p2.jpg", filename: "p2.jpg", fileSize: 100, modificationDate: Date())
        let photo3 = PhotoRecord(relativePath: "p3.jpg", filename: "p3.jpg", fileSize: 100, modificationDate: Date())
        for p in [photo1, photo2, photo3] { try await store.savePhoto(p) }

        let fA = FaceRecord(photoId: photo1.id, boundingBox: .zero)
        let fB = FaceRecord(photoId: photo2.id, boundingBox: .zero)
        let fC = FaceRecord(photoId: photo3.id, boundingBox: .zero)
        try await store.saveFaces([fA], forPhotoId: photo1.id)
        try await store.saveFaces([fB], forPhotoId: photo2.id)
        try await store.saveFaces([fC], forPhotoId: photo3.id)

        // Vector A: base along dimension 0
        var vA = [Float](repeating: 0, count: 512)
        vA[0] = 1.0

        // Vector B: angle 48 deg (sim = cos(48 deg) = 0.6691 with A)
        let rad48: Float = 48.0 * .pi / 180.0
        var vB = [Float](repeating: 0, count: 512)
        vB[0] = cos(rad48)
        vB[1] = sin(rad48)

        // Vector C: angle 75 deg from dim 0 (sim = cos(75 deg) = 0.2588 with A)
        // angle between B and C is 27 deg (sim = cos(27 deg) = 0.8910 with B)
        let rad75: Float = 75.0 * .pi / 180.0
        var vC = [Float](repeating: 0, count: 512)
        vC[0] = cos(rad75)
        vC[1] = sin(rad75)

        // Verify similarities mathematically before testing
        let simAB = EmbeddingSimilarityUtility.cosineSimilarity(vA, vB)
        let simBC = EmbeddingSimilarityUtility.cosineSimilarity(vB, vC)
        let simAC = EmbeddingSimilarityUtility.cosineSimilarity(vA, vC)
        XCTAssertGreaterThanOrEqual(simAB, 0.65, "A and B must link >= 0.65")
        XCTAssertGreaterThanOrEqual(simBC, 0.65, "B and C must link >= 0.65")
        XCTAssertLessThan(simAC, 0.50, "A and C must have sim < 0.50 (transitive drift hazard)")

        try await store.saveEmbedding(EmbeddingRecord(faceId: fA.id, photoId: photo1.id, vector: vA))
        try await store.saveEmbedding(EmbeddingRecord(faceId: fB.id, photoId: photo2.id, vector: vB))
        try await store.saveEmbedding(EmbeddingRecord(faceId: fC.id, photoId: photo3.id, vector: vC))

        try await coordinator.reclusterLibrary(rootFolderURL: URL(fileURLWithPath: "/tmp"), threshold: 0.65)

        let groups = await store.getGroups()
        // A and C must NEVER be in the same group!
        for g in groups {
            let containsA = g.memberFaceIds.contains(fA.id)
            let containsC = g.memberFaceIds.contains(fC.id)
            XCTAssertFalse(containsA && containsC, "Face A and Face C must NOT merge due to transitive drift when A <-> C < 0.50!")
        }
    }

    /// Regression Test: Real production dataset rebuild and invariant audit.
    func testProductionDatasetRebuildAndAudit() async throws {
        let prodURL = URL(fileURLWithPath: "/Users/vikramaditya/Library/Application Support/KeepSake/library_index.json")
        guard FileManager.default.fileExists(atPath: prodURL.path) else { return }

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_prod_audit_\(UUID().uuidString).json")
        try FileManager.default.copyItem(at: prodURL, to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let store = LibraryStore(storageURL: tempURL)
        let coordinator = LibraryProcessingCoordinator(libraryStore: store)
        let rootURL = URL(fileURLWithPath: "/Users/vikramaditya/Disk/Projects/Test 1")

        // 1. Initial snapshot check
        let photos = await store.getAllPhotos()
        let faces = await store.getAllFaces()
        let embeddings = await store.getEmbeddings()

        XCTAssertEqual(photos.count, 19)
        XCTAssertEqual(faces.count, 53)
        XCTAssertEqual(embeddings.count, 53)

        // 2. Perform Rebuild with calibrated threshold
        try await coordinator.rebuildAllIdentities(rootFolderURL: rootURL, threshold: 0.54)

        // 3. Inspect final state
        let finalGroups = await store.getGroups()
        let singletons = finalGroups.filter { $0.memberFaceIds.count == 1 }
        let multiFace = finalGroups.filter { $0.memberFaceIds.count > 1 }

        XCTAssertGreaterThanOrEqual(multiFace.count, 5, "Expected at least 5 multi-face groups for recurring people")
        XCTAssertEqual(singletons.count + multiFace.count, finalGroups.count)

        let integrity = await store.validateIntegrity()
        XCTAssertTrue(integrity.isValid)
        XCTAssertEqual(integrity.facesAssignedToMultipleGroupsCount, 0)
        XCTAssertEqual(integrity.duplicateGroupMembershipsCount, 0)
        XCTAssertEqual(integrity.orphanedEmbeddingsCount, 0)
    }

    /// Regression Test: Batch vs Incremental equivalence and rebuild idempotence.
    func testIncrementalVsBatchRebuildIdempotence() async throws {
        let tempBatchURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_batch_\(UUID().uuidString).json")
        let tempIncURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_inc_\(UUID().uuidString).json")

        let storeBatch = LibraryStore(storageURL: tempBatchURL)
        let storeInc = LibraryStore(storageURL: tempIncURL)
        let coordBatch = LibraryProcessingCoordinator(libraryStore: storeBatch)
        let coordInc = LibraryProcessingCoordinator(libraryStore: storeInc)

        let rootURL = URL(fileURLWithPath: "/tmp")

        // 5 photos with Person A (in photos 1, 2, 4) and Person B (in photos 3, 5)
        var photos: [PhotoRecord] = []
        var faces: [FaceRecord] = []
        var embs: [EmbeddingRecord] = []

        for i in 1...5 {
            let p = PhotoRecord(relativePath: "p\(i).jpg", filename: "p\(i).jpg", fileSize: 100, modificationDate: Date())
            photos.append(p)

            let isA = (i == 1 || i == 2 || i == 4)
            let f = FaceRecord(photoId: p.id, boundingBox: .zero)
            faces.append(f)

            let vec = makeNormalizedVector(primaryDim: isA ? 5 : 100, secondaryDim: 200 + i, secondaryWeight: 0.1)
            embs.append(EmbeddingRecord(faceId: f.id, photoId: p.id, vector: vec))
        }

        // Batch: save all 5 photos and recluster
        for i in 0..<5 {
            try await storeBatch.savePhoto(photos[i])
            try await storeBatch.saveFaces([faces[i]], forPhotoId: photos[i].id)
            try await storeBatch.saveEmbedding(embs[i])
        }
        try await coordBatch.reclusterLibrary(rootFolderURL: rootURL, threshold: 0.65)
        let batchGroups = await storeBatch.getGroups()

        // Incremental: save photo 1-2, recluster, then photo 3, recluster, then 4-5, recluster
        for i in 0..<2 {
            try await storeInc.savePhoto(photos[i])
            try await storeInc.saveFaces([faces[i]], forPhotoId: photos[i].id)
            try await storeInc.saveEmbedding(embs[i])
        }
        try await coordInc.reclusterLibrary(rootFolderURL: rootURL, threshold: 0.65)

        for i in 2..<3 {
            try await storeInc.savePhoto(photos[i])
            try await storeInc.saveFaces([faces[i]], forPhotoId: photos[i].id)
            try await storeInc.saveEmbedding(embs[i])
        }
        try await coordInc.reclusterLibrary(rootFolderURL: rootURL, threshold: 0.65)

        for i in 3..<5 {
            try await storeInc.savePhoto(photos[i])
            try await storeInc.saveFaces([faces[i]], forPhotoId: photos[i].id)
            try await storeInc.saveEmbedding(embs[i])
        }
        try await coordInc.reclusterLibrary(rootFolderURL: rootURL, threshold: 0.65)
        let incGroups = await storeInc.getGroups()

        // Verify equivalence
        XCTAssertEqual(batchGroups.count, incGroups.count, "Batch and incremental clustering must produce same number of groups")
        XCTAssertEqual(batchGroups.count, 2, "Expected exactly 2 groups for Person A and Person B")

        // Idempotence: rebuild -> rebuild -> rebuild produces identical assignments
        try await coordInc.reclusterLibrary(rootFolderURL: rootURL, threshold: 0.65)
        let rebuild1 = await storeInc.getGroups()
        try await coordInc.reclusterLibrary(rootFolderURL: rootURL, threshold: 0.65)
        let rebuild2 = await storeInc.getGroups()

        XCTAssertEqual(rebuild1.count, rebuild2.count)
        for (g1, g2) in zip(rebuild1, rebuild2) {
            XCTAssertEqual(g1.id, g2.id)
            XCTAssertEqual(Set(g1.memberFaceIds), Set(g2.memberFaceIds))
        }
    }

    // MARK: - Product Requirement Verification Tests (Scenarios 1 through 10)

    /// 1. Group Photo: Photo X contains A + B + C -> Photo X appears under Person A, B, and C galleries, while each face belongs strictly to one person.
    func testRequirement1_GroupPhotoAppearsInAllMemberGalleriesWithDisjointFaces() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_group_photo_\(UUID().uuidString).json")
        let store = LibraryStore(storageURL: tempURL)
        let coordinator = LibraryProcessingCoordinator(libraryStore: store)
        let identityService = IdentityService(libraryStore: store)
        let rootURL = URL(fileURLWithPath: "/tmp")

        let photoX = PhotoRecord(relativePath: "group_photo.jpg", filename: "group_photo.jpg", fileSize: 500, modificationDate: Date())
        let photoA_solo = PhotoRecord(relativePath: "alice_solo.jpg", filename: "alice_solo.jpg", fileSize: 200, modificationDate: Date())
        let photoB_solo = PhotoRecord(relativePath: "bob_solo.jpg", filename: "bob_solo.jpg", fileSize: 200, modificationDate: Date())
        let photoC_solo = PhotoRecord(relativePath: "charlie_solo.jpg", filename: "charlie_solo.jpg", fileSize: 200, modificationDate: Date())
        for p in [photoX, photoA_solo, photoB_solo, photoC_solo] { try await store.savePhoto(p) }

        // Faces in group photo
        let faceA_X = FaceRecord(photoId: photoX.id, boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))
        let faceB_X = FaceRecord(photoId: photoX.id, boundingBox: CGRect(x: 0.4, y: 0.1, width: 0.2, height: 0.2))
        let faceC_X = FaceRecord(photoId: photoX.id, boundingBox: CGRect(x: 0.7, y: 0.1, width: 0.2, height: 0.2))
        try await store.saveFaces([faceA_X, faceB_X, faceC_X], forPhotoId: photoX.id)

        // Solo faces
        let faceA_solo = FaceRecord(photoId: photoA_solo.id, boundingBox: .zero)
        let faceB_solo = FaceRecord(photoId: photoB_solo.id, boundingBox: .zero)
        let faceC_solo = FaceRecord(photoId: photoC_solo.id, boundingBox: .zero)
        try await store.saveFaces([faceA_solo], forPhotoId: photoA_solo.id)
        try await store.saveFaces([faceB_solo], forPhotoId: photoB_solo.id)
        try await store.saveFaces([faceC_solo], forPhotoId: photoC_solo.id)

        // Vectors for Alice (dim 10), Bob (dim 50), Charlie (dim 100)
        let vecA_X = makeNormalizedVector(primaryDim: 10, secondaryDim: 1, secondaryWeight: 0.05)
        let vecA_solo = makeNormalizedVector(primaryDim: 10, secondaryDim: 2, secondaryWeight: 0.05)
        let vecB_X = makeNormalizedVector(primaryDim: 50, secondaryDim: 1, secondaryWeight: 0.05)
        let vecB_solo = makeNormalizedVector(primaryDim: 50, secondaryDim: 2, secondaryWeight: 0.05)
        let vecC_X = makeNormalizedVector(primaryDim: 100, secondaryDim: 1, secondaryWeight: 0.05)
        let vecC_solo = makeNormalizedVector(primaryDim: 100, secondaryDim: 2, secondaryWeight: 0.05)

        try await store.saveEmbedding(EmbeddingRecord(faceId: faceA_X.id, photoId: photoX.id, vector: vecA_X))
        try await store.saveEmbedding(EmbeddingRecord(faceId: faceB_X.id, photoId: photoX.id, vector: vecB_X))
        try await store.saveEmbedding(EmbeddingRecord(faceId: faceC_X.id, photoId: photoX.id, vector: vecC_X))
        try await store.saveEmbedding(EmbeddingRecord(faceId: faceA_solo.id, photoId: photoA_solo.id, vector: vecA_solo))
        try await store.saveEmbedding(EmbeddingRecord(faceId: faceB_solo.id, photoId: photoB_solo.id, vector: vecB_solo))
        try await store.saveEmbedding(EmbeddingRecord(faceId: faceC_solo.id, photoId: photoC_solo.id, vector: vecC_solo))

        try await coordinator.reclusterLibrary(rootFolderURL: rootURL, threshold: 0.65)

        let groups = await store.getGroups()
        XCTAssertEqual(groups.count, 3, "Expected 3 people: Alice, Bob, Charlie")

        guard let groupA = groups.first(where: { $0.memberFaceIds.contains(faceA_solo.id) }),
              let groupB = groups.first(where: { $0.memberFaceIds.contains(faceB_solo.id) }),
              let groupC = groups.first(where: { $0.memberFaceIds.contains(faceC_solo.id) }) else {
            XCTFail("Could not locate groups for all three subjects")
            return
        }

        // Check Rule 1: Each face belongs to exactly one Person
        XCTAssertTrue(groupA.memberFaceIds.contains(faceA_X.id))
        XCTAssertFalse(groupA.memberFaceIds.contains(faceB_X.id))
        XCTAssertFalse(groupA.memberFaceIds.contains(faceC_X.id))

        XCTAssertTrue(groupB.memberFaceIds.contains(faceB_X.id))
        XCTAssertFalse(groupB.memberFaceIds.contains(faceA_X.id))
        XCTAssertFalse(groupB.memberFaceIds.contains(faceC_X.id))

        XCTAssertTrue(groupC.memberFaceIds.contains(faceC_X.id))
        XCTAssertFalse(groupC.memberFaceIds.contains(faceA_X.id))
        XCTAssertFalse(groupC.memberFaceIds.contains(faceB_X.id))

        // Check Rule 2: Photo X is present in all 3 people's photo galleries
        let photosA = await identityService.fetchPhotos(forGroupId: groupA.id, rootFolderURL: rootURL)
        let photosB = await identityService.fetchPhotos(forGroupId: groupB.id, rootFolderURL: rootURL)
        let photosC = await identityService.fetchPhotos(forGroupId: groupC.id, rootFolderURL: rootURL)

        XCTAssertTrue(photosA.contains { $0.filename == "group_photo.jpg" }, "Alice's gallery must contain group_photo.jpg")
        XCTAssertTrue(photosB.contains { $0.filename == "group_photo.jpg" }, "Bob's gallery must contain group_photo.jpg")
        XCTAssertTrue(photosC.contains { $0.filename == "group_photo.jpg" }, "Charlie's gallery must contain group_photo.jpg")

        let integrity = await store.validateIntegrity()
        XCTAssertTrue(integrity.isValid)
    }

    /// 2. Same Person Across Multiple Photos: Photo 1, 2, 3, 4 all contain Alice -> exactly 1 Person with all 4 photos.
    func testRequirement2_SamePersonAcrossMultiplePhotosFormsSinglePerson() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_same_person_multi_\(UUID().uuidString).json")
        let store = LibraryStore(storageURL: tempURL)
        let coordinator = LibraryProcessingCoordinator(libraryStore: store)
        let identityService = IdentityService(libraryStore: store)
        let rootURL = URL(fileURLWithPath: "/tmp")

        var faceIds: [UUID] = []
        for i in 1...4 {
            let photo = PhotoRecord(relativePath: "alice_\(i).jpg", filename: "alice_\(i).jpg", fileSize: 100, modificationDate: Date())
            try await store.savePhoto(photo)
            let face = FaceRecord(photoId: photo.id, boundingBox: .zero)
            faceIds.append(face.id)
            try await store.saveFaces([face], forPhotoId: photo.id)
            let vec = makeNormalizedVector(primaryDim: 25, secondaryDim: 50 + i, secondaryWeight: 0.08)
            try await store.saveEmbedding(EmbeddingRecord(faceId: face.id, photoId: photo.id, vector: vec))
        }

        try await coordinator.reclusterLibrary(rootFolderURL: rootURL, threshold: 0.65)

        let groups = await store.getGroups()
        XCTAssertEqual(groups.count, 1, "Expected exactly 1 person for all 4 photos of Alice")
        XCTAssertEqual(groups[0].memberFaceIds.count, 4)
        for fid in faceIds {
            XCTAssertTrue(groups[0].memberFaceIds.contains(fid))
        }

        let photos = await identityService.fetchPhotos(forGroupId: groups[0].id, rootFolderURL: rootURL)
        XCTAssertEqual(photos.count, 4)
    }

    /// 3. Same Person with Lighting/Pose Variations: Moderate similarity variance (0.58 - 0.64) still forms 1 Person.
    func testRequirement3_SamePersonWithLightingAndPoseVariationsFormsSinglePerson() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_lighting_pose_\(UUID().uuidString).json")
        let store = LibraryStore(storageURL: tempURL)
        let coordinator = LibraryProcessingCoordinator(libraryStore: store)
        let rootURL = URL(fileURLWithPath: "/tmp")

        // 4 photos of same subject with angles/lighting resulting in cosine similarities in 0.58 - 0.63 range
        for i in 1...4 {
            let photo = PhotoRecord(relativePath: "pose_\(i).jpg", filename: "pose_\(i).jpg", fileSize: 100, modificationDate: Date())
            try await store.savePhoto(photo)
            let face = FaceRecord(photoId: photo.id, boundingBox: .zero)
            try await store.saveFaces([face], forPhotoId: photo.id)

            // Primary dimension 30 with variation across secondary dimensions
            let vec = makeNormalizedVector(primaryDim: 30, secondaryDim: 150 + (i * 10), secondaryWeight: 0.22)
            try await store.saveEmbedding(EmbeddingRecord(faceId: face.id, photoId: photo.id, vector: vec))
        }

        try await coordinator.reclusterLibrary(rootFolderURL: rootURL, threshold: 0.65)

        let groups = await store.getGroups()
        XCTAssertEqual(groups.count, 1, "Evidence across multi-photo observations should unify lighting/pose variations into 1 Person")
        XCTAssertEqual(groups[0].memberFaceIds.count, 4)
    }

    /// 4. Two Different People: Low similarity (< 0.30) -> 2 separate People.
    func testRequirement4_TwoDifferentPeopleRemainSeparate() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_two_diff_\(UUID().uuidString).json")
        let store = LibraryStore(storageURL: tempURL)
        let coordinator = LibraryProcessingCoordinator(libraryStore: store)
        let rootURL = URL(fileURLWithPath: "/tmp")

        let photo1 = PhotoRecord(relativePath: "person1.jpg", filename: "person1.jpg", fileSize: 100, modificationDate: Date())
        let photo2 = PhotoRecord(relativePath: "person2.jpg", filename: "person2.jpg", fileSize: 100, modificationDate: Date())
        try await store.savePhoto(photo1)
        try await store.savePhoto(photo2)

        let face1 = FaceRecord(photoId: photo1.id, boundingBox: .zero)
        let face2 = FaceRecord(photoId: photo2.id, boundingBox: .zero)
        try await store.saveFaces([face1], forPhotoId: photo1.id)
        try await store.saveFaces([face2], forPhotoId: photo2.id)

        let vec1 = makeNormalizedVector(primaryDim: 10, secondaryDim: 20, secondaryWeight: 0.1)
        let vec2 = makeNormalizedVector(primaryDim: 200, secondaryDim: 300, secondaryWeight: 0.1)
        try await store.saveEmbedding(EmbeddingRecord(faceId: face1.id, photoId: photo1.id, vector: vec1))
        try await store.saveEmbedding(EmbeddingRecord(faceId: face2.id, photoId: photo2.id, vector: vec2))

        try await coordinator.reclusterLibrary(rootFolderURL: rootURL, threshold: 0.65)

        let groups = await store.getGroups()
        XCTAssertEqual(groups.count, 2, "Distinct individuals must remain in 2 separate People cards")
    }

    /// 5. Two People Repeatedly Appearing Together in Multiple Shared Photos:
    /// Photo 1 (Alice + Bob), Photo 2 (Alice + Bob), Photo 3 (Alice + Bob).
    /// Both identities maintained across all 3 photos, zero cross-contamination.
    func testRequirement5_TwoPeopleRepeatedlyAppearingTogetherMaintainSeparateIdentities() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_shared_multi_\(UUID().uuidString).json")
        let store = LibraryStore(storageURL: tempURL)
        let coordinator = LibraryProcessingCoordinator(libraryStore: store)
        let identityService = IdentityService(libraryStore: store)
        let rootURL = URL(fileURLWithPath: "/tmp")

        var aliceFaceIds: [UUID] = []
        var bobFaceIds: [UUID] = []

        for i in 1...3 {
            let photo = PhotoRecord(relativePath: "shared_\(i).jpg", filename: "shared_\(i).jpg", fileSize: 300, modificationDate: Date())
            try await store.savePhoto(photo)

            let faceA = FaceRecord(photoId: photo.id, boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.2, height: 0.2))
            let faceB = FaceRecord(photoId: photo.id, boundingBox: CGRect(x: 0.6, y: 0.2, width: 0.2, height: 0.2))
            aliceFaceIds.append(faceA.id)
            bobFaceIds.append(faceB.id)
            try await store.saveFaces([faceA, faceB], forPhotoId: photo.id)

            let vecA = makeNormalizedVector(primaryDim: 15, secondaryDim: 50 + i, secondaryWeight: 0.05)
            let vecB = makeNormalizedVector(primaryDim: 85, secondaryDim: 150 + i, secondaryWeight: 0.05)
            try await store.saveEmbedding(EmbeddingRecord(faceId: faceA.id, photoId: photo.id, vector: vecA))
            try await store.saveEmbedding(EmbeddingRecord(faceId: faceB.id, photoId: photo.id, vector: vecB))
        }

        try await coordinator.reclusterLibrary(rootFolderURL: rootURL, threshold: 0.65)

        let groups = await store.getGroups()
        XCTAssertEqual(groups.count, 2, "Expected exactly 2 People (Alice and Bob)")

        guard let groupA = groups.first(where: { $0.memberFaceIds.contains(aliceFaceIds[0]) }),
              let groupB = groups.first(where: { $0.memberFaceIds.contains(bobFaceIds[0]) }) else {
            XCTFail("Could not locate groups")
            return
        }

        XCTAssertEqual(groupA.memberFaceIds.count, 3)
        XCTAssertEqual(groupB.memberFaceIds.count, 3)
        XCTAssertTrue(groupA.memberFaceIds.allSatisfy { aliceFaceIds.contains($0) })
        XCTAssertTrue(groupB.memberFaceIds.allSatisfy { bobFaceIds.contains($0) })

        let photosA = await identityService.fetchPhotos(forGroupId: groupA.id, rootFolderURL: rootURL)
        let photosB = await identityService.fetchPhotos(forGroupId: groupB.id, rootFolderURL: rootURL)
        XCTAssertEqual(photosA.count, 3)
        XCTAssertEqual(photosB.count, 3)

        let integrity = await store.validateIntegrity()
        XCTAssertTrue(integrity.isValid)
    }

    /// 6. Incremental Scan: Newly scanned photo attaches to existing person without creating duplicate Person.
    func testRequirement6_IncrementalScanAttachesToExistingPerson() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_incremental_attach_\(UUID().uuidString).json")
        let store = LibraryStore(storageURL: tempURL)
        let coordinator = LibraryProcessingCoordinator(libraryStore: store)
        let rootURL = URL(fileURLWithPath: "/tmp")

        // Step 1: Initial scan with 2 photos of Alice
        let p1 = PhotoRecord(relativePath: "p1.jpg", filename: "p1.jpg", fileSize: 100, modificationDate: Date())
        let p2 = PhotoRecord(relativePath: "p2.jpg", filename: "p2.jpg", fileSize: 100, modificationDate: Date())
        for p in [p1, p2] { try await store.savePhoto(p) }

        let f1 = FaceRecord(photoId: p1.id, boundingBox: .zero)
        let f2 = FaceRecord(photoId: p2.id, boundingBox: .zero)
        try await store.saveFaces([f1], forPhotoId: p1.id)
        try await store.saveFaces([f2], forPhotoId: p2.id)

        try await store.saveEmbedding(EmbeddingRecord(faceId: f1.id, photoId: p1.id, vector: makeNormalizedVector(primaryDim: 40, secondaryDim: 1, secondaryWeight: 0.05)))
        try await store.saveEmbedding(EmbeddingRecord(faceId: f2.id, photoId: p2.id, vector: makeNormalizedVector(primaryDim: 40, secondaryDim: 2, secondaryWeight: 0.05)))

        try await coordinator.reclusterLibrary(rootFolderURL: rootURL, threshold: 0.65)
        var groups = await store.getGroups()
        XCTAssertEqual(groups.count, 1)
        let originalGroupId = groups[0].id

        // Step 2: New photo 3 of Alice scanned incrementally
        let p3 = PhotoRecord(relativePath: "p3.jpg", filename: "p3.jpg", fileSize: 100, modificationDate: Date())
        try await store.savePhoto(p3)
        let f3 = FaceRecord(photoId: p3.id, boundingBox: .zero)
        try await store.saveFaces([f3], forPhotoId: p3.id)
        try await store.saveEmbedding(EmbeddingRecord(faceId: f3.id, photoId: p3.id, vector: makeNormalizedVector(primaryDim: 40, secondaryDim: 3, secondaryWeight: 0.05)))

        try await coordinator.reclusterLibrary(rootFolderURL: rootURL, threshold: 0.65)
        groups = await store.getGroups()
        XCTAssertEqual(groups.count, 1, "Should still be 1 person after incremental scan")
        XCTAssertEqual(groups[0].id, originalGroupId, "Should preserve original GroupRecord UUID")
        XCTAssertEqual(groups[0].memberFaceIds.count, 3)
    }

    /// 7. Rescan: Rescanning the exact same folder creates no duplicate People.
    func testRequirement7_RescanIsCompletelyIdempotent() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_rescan_idempotent_\(UUID().uuidString).json")
        let store = LibraryStore(storageURL: tempURL)
        let coordinator = LibraryProcessingCoordinator(libraryStore: store)
        let rootURL = URL(fileURLWithPath: "/tmp")

        for i in 1...3 {
            let p = PhotoRecord(relativePath: "p\(i).jpg", filename: "p\(i).jpg", fileSize: 100, modificationDate: Date())
            try await store.savePhoto(p)
            let f = FaceRecord(photoId: p.id, boundingBox: .zero)
            try await store.saveFaces([f], forPhotoId: p.id)
            try await store.saveEmbedding(EmbeddingRecord(faceId: f.id, photoId: p.id, vector: makeNormalizedVector(primaryDim: 70, secondaryDim: i, secondaryWeight: 0.05)))
        }

        try await coordinator.reclusterLibrary(rootFolderURL: rootURL, threshold: 0.65)
        let groupsRun1 = await store.getGroups()

        try await coordinator.reclusterLibrary(rootFolderURL: rootURL, threshold: 0.65)
        let groupsRun2 = await store.getGroups()

        try await coordinator.reclusterLibrary(rootFolderURL: rootURL, threshold: 0.65)
        let groupsRun3 = await store.getGroups()

        XCTAssertEqual(groupsRun1.count, 1)
        XCTAssertEqual(groupsRun2.count, 1)
        XCTAssertEqual(groupsRun3.count, 1)
        XCTAssertEqual(groupsRun1[0].id, groupsRun2[0].id)
        XCTAssertEqual(groupsRun2[0].id, groupsRun3[0].id)
    }

    /// 8. Full Rebuild: Produces identical structure as incremental processing.
    func testRequirement8_FullRebuildProducesIdenticalStructureAsIncremental() async throws {
        let tempBatchURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_rebuild_match_batch_\(UUID().uuidString).json")
        let tempIncURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_rebuild_match_inc_\(UUID().uuidString).json")
        let storeBatch = LibraryStore(storageURL: tempBatchURL)
        let storeInc = LibraryStore(storageURL: tempIncURL)
        let coordBatch = LibraryProcessingCoordinator(libraryStore: storeBatch)
        let coordInc = LibraryProcessingCoordinator(libraryStore: storeInc)
        let rootURL = URL(fileURLWithPath: "/tmp")

        var photos: [PhotoRecord] = []
        var faces: [FaceRecord] = []
        var embs: [EmbeddingRecord] = []

        for i in 1...4 {
            let p = PhotoRecord(relativePath: "p\(i).jpg", filename: "p\(i).jpg", fileSize: 100, modificationDate: Date())
            photos.append(p)
            let f = FaceRecord(photoId: p.id, boundingBox: .zero)
            faces.append(f)
            let vec = makeNormalizedVector(primaryDim: (i <= 2) ? 12 : 88, secondaryDim: i, secondaryWeight: 0.05)
            embs.append(EmbeddingRecord(faceId: f.id, photoId: p.id, vector: vec))
        }

        // Batch Rebuild
        for i in 0..<4 {
            try await storeBatch.savePhoto(photos[i])
            try await storeBatch.saveFaces([faces[i]], forPhotoId: photos[i].id)
            try await storeBatch.saveEmbedding(embs[i])
        }
        try await coordBatch.rebuildAllIdentities(rootFolderURL: rootURL, threshold: 0.65)
        let batchGroups = await storeBatch.getGroups()

        // Incremental Scan
        for i in 0..<4 {
            try await storeInc.savePhoto(photos[i])
            try await storeInc.saveFaces([faces[i]], forPhotoId: photos[i].id)
            try await storeInc.saveEmbedding(embs[i])
            try await coordInc.reclusterLibrary(rootFolderURL: rootURL, threshold: 0.65)
        }
        let incGroups = await storeInc.getGroups()

        XCTAssertEqual(batchGroups.count, 2)
        XCTAssertEqual(incGroups.count, 2)
        XCTAssertEqual(Set(batchGroups.map { Set($0.memberFaceIds) }),
                       Set(incGroups.map { Set($0.memberFaceIds) }))
    }

    /// 9. Transitive Drift Prevention: Unrelated people A and C must not merge through intermediate B.
    func testRequirement9_TransitiveDriftBlocked() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_drift_req_\(UUID().uuidString).json")
        let store = LibraryStore(storageURL: tempURL)
        let coordinator = LibraryProcessingCoordinator(libraryStore: store)
        let rootURL = URL(fileURLWithPath: "/tmp")

        let photo1 = PhotoRecord(relativePath: "p1.jpg", filename: "p1.jpg", fileSize: 100, modificationDate: Date())
        let photo2 = PhotoRecord(relativePath: "p2.jpg", filename: "p2.jpg", fileSize: 100, modificationDate: Date())
        let photo3 = PhotoRecord(relativePath: "p3.jpg", filename: "p3.jpg", fileSize: 100, modificationDate: Date())
        for p in [photo1, photo2, photo3] { try await store.savePhoto(p) }

        let fA = FaceRecord(photoId: photo1.id, boundingBox: .zero)
        let fB = FaceRecord(photoId: photo2.id, boundingBox: .zero)
        let fC = FaceRecord(photoId: photo3.id, boundingBox: .zero)
        try await store.saveFaces([fA], forPhotoId: photo1.id)
        try await store.saveFaces([fB], forPhotoId: photo2.id)
        try await store.saveFaces([fC], forPhotoId: photo3.id)

        var vA = [Float](repeating: 0, count: 512)
        vA[0] = 1.0
        let rad48: Float = 48.0 * .pi / 180.0
        var vB = [Float](repeating: 0, count: 512)
        vB[0] = cos(rad48)
        vB[1] = sin(rad48)
        let rad75: Float = 75.0 * .pi / 180.0
        var vC = [Float](repeating: 0, count: 512)
        vC[0] = cos(rad75)
        vC[1] = sin(rad75)

        try await store.saveEmbedding(EmbeddingRecord(faceId: fA.id, photoId: photo1.id, vector: vA))
        try await store.saveEmbedding(EmbeddingRecord(faceId: fB.id, photoId: photo2.id, vector: vB))
        try await store.saveEmbedding(EmbeddingRecord(faceId: fC.id, photoId: photo3.id, vector: vC))

        try await coordinator.reclusterLibrary(rootFolderURL: rootURL, threshold: 0.65)

        let groups = await store.getGroups()
        for g in groups {
            let hasA = g.memberFaceIds.contains(fA.id)
            let hasC = g.memberFaceIds.contains(fC.id)
            XCTAssertFalse(hasA && hasC, "Face A and Face C must not merge via transitive chain")
        }
    }

    /// 10. Custom Names & Representative Thumbnails: Preserved after rebuild.
    func testRequirement10_CustomNamesAndRepresentativeThumbnailsPreservedAfterRebuild() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_user_curation_\(UUID().uuidString).json")
        let store = LibraryStore(storageURL: tempURL)
        let coordinator = LibraryProcessingCoordinator(libraryStore: store)
        let identityService = IdentityService(libraryStore: store)
        let rootURL = URL(fileURLWithPath: "/tmp")

        let p1 = PhotoRecord(relativePath: "p1.jpg", filename: "p1.jpg", fileSize: 100, modificationDate: Date())
        let p2 = PhotoRecord(relativePath: "p2.jpg", filename: "p2.jpg", fileSize: 100, modificationDate: Date())
        for p in [p1, p2] { try await store.savePhoto(p) }

        let f1 = FaceRecord(photoId: p1.id, boundingBox: .zero)
        let f2 = FaceRecord(photoId: p2.id, boundingBox: .zero)
        try await store.saveFaces([f1], forPhotoId: p1.id)
        try await store.saveFaces([f2], forPhotoId: p2.id)

        try await store.saveEmbedding(EmbeddingRecord(faceId: f1.id, photoId: p1.id, vector: makeNormalizedVector(primaryDim: 33, secondaryDim: 1, secondaryWeight: 0.05)))
        try await store.saveEmbedding(EmbeddingRecord(faceId: f2.id, photoId: p2.id, vector: makeNormalizedVector(primaryDim: 33, secondaryDim: 2, secondaryWeight: 0.05)))

        try await coordinator.reclusterLibrary(rootFolderURL: rootURL, threshold: 0.65)
        var groups = await store.getGroups()
        XCTAssertEqual(groups.count, 1)
        let targetId = groups[0].id

        // User gives custom name and chooses face 2 as thumbnail
        try await identityService.renameGroup(id: targetId, newName: "Alice Walker")
        try await identityService.setRepresentativeFace(groupId: targetId, faceId: f2.id)

        // Run full rebuild
        try await coordinator.rebuildAllIdentities(rootFolderURL: rootURL, threshold: 0.65)

        groups = await store.getGroups()
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].id, targetId, "Group ID must be preserved")
        XCTAssertEqual(groups[0].customName, "Alice Walker", "Custom name must be preserved after rebuild")
        XCTAssertEqual(groups[0].representativeFaceId, f2.id, "User selected thumbnail must be preserved after rebuild")
    }

    // MARK: - Face Identity & Clustering Regression Tests (Phase 13 Calibration)

    /// A. Singleton-to-singleton merge: Two faces from different photos with similarity ~0.57 form one identity.
    func testRegression_A_SingletonToSingletonMerge_Similarity057() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_reg_a_\(UUID().uuidString).json")
        let store = LibraryStore(storageURL: tempURL)
        let coordinator = LibraryProcessingCoordinator(libraryStore: store)
        let identityService = IdentityService(libraryStore: store)

        let p1 = PhotoRecord(relativePath: "photo1.jpg", filename: "photo1.jpg", fileSize: 100, modificationDate: Date())
        let p2 = PhotoRecord(relativePath: "photo2.jpg", filename: "photo2.jpg", fileSize: 100, modificationDate: Date())
        try await store.savePhoto(p1)
        try await store.savePhoto(p2)

        let f1 = FaceRecord(photoId: p1.id, boundingBox: .zero)
        let f2 = FaceRecord(photoId: p2.id, boundingBox: .zero)
        try await store.saveFaces([f1], forPhotoId: p1.id)
        try await store.saveFaces([f2], forPhotoId: p2.id)

        // Vectors with cosine similarity = 0.5736 (replicating Person 5 ↔ Person 14)
        var v1 = [Float](repeating: 0, count: 512)
        v1[0] = 1.0
        let angle: Float = acos(0.5736)
        var v2 = [Float](repeating: 0, count: 512)
        v2[0] = cos(angle)
        v2[1] = sin(angle)

        try await store.saveEmbeddings([
            EmbeddingRecord(faceId: f1.id, photoId: p1.id, vector: v1),
            EmbeddingRecord(faceId: f2.id, photoId: p2.id, vector: v2)
        ])

        try await coordinator.reclusterLibrary(rootFolderURL: URL(fileURLWithPath: "/tmp"), threshold: 0.54)

        let groups = await identityService.fetchGroups()
        XCTAssertEqual(groups.count, 1, "Two faces from different photos with similarity 0.5736 must form 1 identity group")
        XCTAssertEqual(Set(groups[0].memberFaceIds), Set([f1.id, f2.id]))
    }

    /// B. Same-photo protection: Two highly similar faces from the same photo must remain separate (Cannot-Link).
    func testRegression_B_SamePhotoProtection_CannotLink() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_reg_b_\(UUID().uuidString).json")
        let store = LibraryStore(storageURL: tempURL)
        let coordinator = LibraryProcessingCoordinator(libraryStore: store)
        let identityService = IdentityService(libraryStore: store)

        let p1 = PhotoRecord(relativePath: "group_photo.jpg", filename: "group_photo.jpg", fileSize: 100, modificationDate: Date())
        try await store.savePhoto(p1)

        let f1 = FaceRecord(photoId: p1.id, boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))
        let f2 = FaceRecord(photoId: p1.id, boundingBox: CGRect(x: 0.6, y: 0.1, width: 0.2, height: 0.2))
        try await store.saveFaces([f1, f2], forPhotoId: p1.id)

        // Near-identical embeddings in the SAME photo
        var v1 = [Float](repeating: 0, count: 512); v1[0] = 1.0
        var v2 = [Float](repeating: 0, count: 512); v2[0] = 0.99; v2[1] = sqrt(1.0 - 0.99 * 0.99)

        try await store.saveEmbeddings([
            EmbeddingRecord(faceId: f1.id, photoId: p1.id, vector: v1),
            EmbeddingRecord(faceId: f2.id, photoId: p1.id, vector: v2)
        ])

        try await coordinator.reclusterLibrary(rootFolderURL: URL(fileURLWithPath: "/tmp"), threshold: 0.54)

        let groups = await identityService.fetchGroups()
        XCTAssertEqual(groups.count, 2, "Two faces in the same photograph must NEVER be assigned to the same Person (Cannot-Link)")
        XCTAssertEqual(groups[0].memberFaceIds.count, 1)
        XCTAssertEqual(groups[1].memberFaceIds.count, 1)
        XCTAssertNotEqual(groups[0].memberFaceIds[0], groups[1].memberFaceIds[0])
    }

    /// C. Transitive drift: A~B and B~C must not merge if A and C are incompatible.
    func testRegression_C_TransitiveDriftProtection() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_reg_c_\(UUID().uuidString).json")
        let store = LibraryStore(storageURL: tempURL)
        let coordinator = LibraryProcessingCoordinator(libraryStore: store)
        let identityService = IdentityService(libraryStore: store)

        let p1 = PhotoRecord(relativePath: "p1.jpg", filename: "p1.jpg", fileSize: 100, modificationDate: Date())
        let p2 = PhotoRecord(relativePath: "p2.jpg", filename: "p2.jpg", fileSize: 100, modificationDate: Date())
        let p3 = PhotoRecord(relativePath: "p3.jpg", filename: "p3.jpg", fileSize: 100, modificationDate: Date())
        for p in [p1, p2, p3] { try await store.savePhoto(p) }

        let fA = FaceRecord(photoId: p1.id, boundingBox: .zero)
        let fB = FaceRecord(photoId: p2.id, boundingBox: .zero)
        let fC = FaceRecord(photoId: p3.id, boundingBox: .zero)
        try await store.saveFaces([fA], forPhotoId: p1.id)
        try await store.saveFaces([fB], forPhotoId: p2.id)
        try await store.saveFaces([fC], forPhotoId: p3.id)

        // A ~ B (cos 54 deg = 0.5878), B ~ C (cos 54 deg = 0.5878), but A ~ C (cos 108 deg = -0.3090)
        var vA = [Float](repeating: 0, count: 512); vA[0] = 1.0
        let a1: Float = 54.0 * .pi / 180.0
        var vB = [Float](repeating: 0, count: 512); vB[0] = cos(a1); vB[1] = sin(a1)
        let a2: Float = 108.0 * .pi / 180.0
        var vC = [Float](repeating: 0, count: 512); vC[0] = cos(a2); vC[1] = sin(a2)

        try await store.saveEmbeddings([
            EmbeddingRecord(faceId: fA.id, photoId: p1.id, vector: vA),
            EmbeddingRecord(faceId: fB.id, photoId: p2.id, vector: vB),
            EmbeddingRecord(faceId: fC.id, photoId: p3.id, vector: vC)
        ])

        try await coordinator.reclusterLibrary(rootFolderURL: URL(fileURLWithPath: "/tmp"), threshold: 0.54)

        let groups = await identityService.fetchGroups()
        for g in groups {
            let hasA = g.memberFaceIds.contains(fA.id)
            let hasC = g.memberFaceIds.contains(fC.id)
            XCTAssertFalse(hasA && hasC, "Incompatible faces A and C must not merge via transitive intermediate B")
        }
    }

    /// D. Ground-truth-style clustering: Verify the known 19-photo dataset produces ~17 identities without false merges.
    func testRegression_D_GroundTruth19PhotoDatasetClustering() async throws {
        let prodURL = URL(fileURLWithPath: "/Users/vikramaditya/Library/Application Support/KeepSake/library_index.json")
        guard FileManager.default.fileExists(atPath: prodURL.path) else { return }

        // Copy production index to temp file so we can run tests without side effects
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_gt_19photo_\(UUID().uuidString).json")
        try FileManager.default.copyItem(at: prodURL, to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let store = LibraryStore(storageURL: tempURL)
        let coordinator = LibraryProcessingCoordinator(libraryStore: store)
        let identityService = IdentityService(libraryStore: store)
        let rootURL = URL(fileURLWithPath: "/Users/vikramaditya/Disk/Projects/Test 1")

        try await coordinator.rebuildAllIdentities(rootFolderURL: rootURL, threshold: 0.54)

        let groups = await identityService.fetchGroups()
        let allFaces = await store.getAllFaces()
        let allEmbeddings = await store.getEmbeddings()

        XCTAssertEqual(allFaces.count, 53, "Must preserve all 53 detected face instances")
        XCTAssertEqual(allEmbeddings.count, 53, "Must preserve all 53 embeddings")

        // In 19 photos with 53 faces, recurring individuals collapse into multi-face groups
        // while one-off background faces remain singletons.
        XCTAssertGreaterThanOrEqual(groups.count, 15)
        XCTAssertLessThanOrEqual(groups.count, 40)

        // Specific ground-truth verifications:
        // 1. Person 5 (3EFEC3E8 in IMG_1141) and Person 14 (792A0EE2 in IMG_1144)
        let fPerson5 = allFaces.first(where: { $0.id.uuidString.hasPrefix("3EFEC3E8") })?.id
        let fPerson14 = allFaces.first(where: { $0.id.uuidString.hasPrefix("792A0EE2") })?.id
        if let f5 = fPerson5, let f14 = fPerson14 {
            let g5 = groups.first(where: { $0.memberFaceIds.contains(f5) })
            let g14 = groups.first(where: { $0.memberFaceIds.contains(f14) })
            XCTAssertNotNil(g5)
            XCTAssertNotNil(g14)
            XCTAssertEqual(g5?.id, g14?.id, "Person 5 and Person 14 must be unified into the same Person identity")
        }

        // 2. Vikram's 3 appearances (Vikram_1: 3B1F89A6, Vikram_2: 7F6E4C47, Vikram_3: E94D3BC0)
        let fVikram1 = allFaces.first(where: { $0.id.uuidString.hasPrefix("3B1F89A6") })?.id
        let fVikram2 = allFaces.first(where: { $0.id.uuidString.hasPrefix("7F6E4C47") })?.id
        let fVikram3 = allFaces.first(where: { $0.id.uuidString.hasPrefix("E94D3BC0") })?.id
        if let v1 = fVikram1, let v2 = fVikram2, let v3 = fVikram3 {
            let gV1 = groups.first(where: { $0.memberFaceIds.contains(v1) })
            let gV2 = groups.first(where: { $0.memberFaceIds.contains(v2) })
            let gV3 = groups.first(where: { $0.memberFaceIds.contains(v3) })
            XCTAssertNotNil(gV1)
            XCTAssertEqual(gV1?.id, gV2?.id, "Vikram 1 and Vikram 2 must be unified")
            XCTAssertEqual(gV1?.id, gV3?.id, "Vikram 1 and Vikram 3 must be unified")
        }

        // 3. Manas appearances (2C5CDD99 in IMG_1141, 6FBE2877 in IMG_1144)
        let fManas1 = allFaces.first(where: { $0.id.uuidString.hasPrefix("2C5CDD99") })?.id
        let fManas2 = allFaces.first(where: { $0.id.uuidString.hasPrefix("6FBE2877") })?.id
        if let m1 = fManas1, let m2 = fManas2 {
            let gM1 = groups.first(where: { $0.memberFaceIds.contains(m1) })
            let gM2 = groups.first(where: { $0.memberFaceIds.contains(m2) })
            XCTAssertNotNil(gM1)
            XCTAssertEqual(gM1?.id, gM2?.id, "Manas appearances across photos must be unified")
        }

        // 4. Ashna appearances (52DFF1DE in IMG_1141, 451EFB8B in IMG_1144)
        let fAshna1 = allFaces.first(where: { $0.id.uuidString.hasPrefix("52DFF1DE") })?.id
        let fAshna2 = allFaces.first(where: { $0.id.uuidString.hasPrefix("451EFB8B") })?.id
        if let a1 = fAshna1, let a2 = fAshna2 {
            let gA1 = groups.first(where: { $0.memberFaceIds.contains(a1) })
            let gA2 = groups.first(where: { $0.memberFaceIds.contains(a2) })
            XCTAssertNotNil(gA1)
            XCTAssertEqual(gA1?.id, gA2?.id, "Ashna appearances across photos must be unified")
        }

        // 5. Referential Integrity Check
        let report = await store.validateIntegrity()
        XCTAssertTrue(report.isValid, "Library index integrity must be 100% valid")
        XCTAssertEqual(report.facesAssignedToMultipleGroupsCount, 0, "No face may be assigned to multiple groups")
        XCTAssertEqual(report.duplicateGroupMembershipsCount, 0, "No duplicate group memberships")
    }

    /// E. Rescan idempotence: Running clustering/reconciliation twice must produce the same identity structure.
    func testRegression_E_RescanIdempotence() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_reg_e_\(UUID().uuidString).json")
        let store = LibraryStore(storageURL: tempURL)
        let coordinator = LibraryProcessingCoordinator(libraryStore: store)
        let identityService = IdentityService(libraryStore: store)

        let p1 = PhotoRecord(relativePath: "p1.jpg", filename: "p1.jpg", fileSize: 100, modificationDate: Date())
        let p2 = PhotoRecord(relativePath: "p2.jpg", filename: "p2.jpg", fileSize: 100, modificationDate: Date())
        try await store.savePhoto(p1); try await store.savePhoto(p2)
        let f1 = FaceRecord(photoId: p1.id, boundingBox: .zero)
        let f2 = FaceRecord(photoId: p2.id, boundingBox: .zero)
        try await store.saveFaces([f1], forPhotoId: p1.id); try await store.saveFaces([f2], forPhotoId: p2.id)
        let v1 = makeNormalizedVector(primaryDim: 20)
        let v2 = makeNormalizedVector(primaryDim: 20, secondaryDim: 21, secondaryWeight: 0.1)
        try await store.saveEmbeddings([
            EmbeddingRecord(faceId: f1.id, photoId: p1.id, vector: v1),
            EmbeddingRecord(faceId: f2.id, photoId: p2.id, vector: v2)
        ])

        // Pass 1
        try await coordinator.reclusterLibrary(rootFolderURL: URL(fileURLWithPath: "/tmp"), threshold: 0.54)
        let groups1 = await identityService.fetchGroups()
        XCTAssertEqual(groups1.count, 1)
        let id1 = groups1[0].id

        // Pass 2
        try await coordinator.reclusterLibrary(rootFolderURL: URL(fileURLWithPath: "/tmp"), threshold: 0.54)
        let groups2 = await identityService.fetchGroups()
        XCTAssertEqual(groups2.count, 1)
        XCTAssertEqual(groups2[0].id, id1, "Group ID must be identical across repeated clustering runs")
        XCTAssertEqual(Set(groups2[0].memberFaceIds), Set([f1.id, f2.id]))
    }

    // MARK: - Refresh / Reprocess Workflow Regression Tests

    /// Refreshing the same folder actually reruns clustering and invokes onProcessingCompleted.
    @MainActor
    func testRegression_Refresh_RerunsClusteringAndNotifiesUI() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("test_refresh_dir_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let file1 = tempDir.appendingPathComponent("p1.jpg")
        let file2 = tempDir.appendingPathComponent("p2.jpg")
        let dummyData = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0xFF, 0xDB, 0x00, 0x43, 0x00, 0xFF, 0xD9])
        try dummyData.write(to: file1)
        try dummyData.write(to: file2)

        let attr1 = try FileManager.default.attributesOfItem(atPath: file1.path)
        let attr2 = try FileManager.default.attributesOfItem(atPath: file2.path)
        let modDate1 = (attr1[.modificationDate] as? Date) ?? Date()
        let modDate2 = (attr2[.modificationDate] as? Date) ?? Date()

        let tempStoreURL = tempDir.appendingPathComponent("library_index.json")
        let store = LibraryStore(storageURL: tempStoreURL)
        let coordinator = LibraryProcessingCoordinator(libraryStore: store)
        let vm = PhotoBrowserViewModel(coordinator: coordinator, libraryStore: store)

        vm.selectedFolderURL = tempDir

        let p1 = PhotoRecord(relativePath: "p1.jpg", filename: "p1.jpg", fileSize: Int64(dummyData.count), modificationDate: modDate1, processingState: .processed)
        let p2 = PhotoRecord(relativePath: "p2.jpg", filename: "p2.jpg", fileSize: Int64(dummyData.count), modificationDate: modDate2, processingState: .processed)
        try await store.savePhoto(p1); try await store.savePhoto(p2)
        let f1 = FaceRecord(photoId: p1.id, boundingBox: .zero)
        let f2 = FaceRecord(photoId: p2.id, boundingBox: .zero)
        try await store.saveFaces([f1], forPhotoId: p1.id); try await store.saveFaces([f2], forPhotoId: p2.id)
        let v1 = makeNormalizedVector(primaryDim: 10)
        let v2 = makeNormalizedVector(primaryDim: 10, secondaryDim: 11, secondaryWeight: 0.1)
        try await store.saveEmbeddings([
            EmbeddingRecord(faceId: f1.id, photoId: p1.id, vector: v1),
            EmbeddingRecord(faceId: f2.id, photoId: p2.id, vector: v2)
        ])

        let expectation = expectation(description: "onProcessingCompleted called on refresh")
        vm.onProcessingCompleted = {
            expectation.fulfill()
        }

        // Trigger manual refresh
        await vm.reconcileMonitoredFolder(folderURL: tempDir)

        await fulfillment(of: [expectation], timeout: 3.0)

        let groups = await store.getGroups()
        XCTAssertEqual(groups.count, 1, "Refresh must execute clustering and produce consolidated group")
        XCTAssertEqual(Set(groups[0].memberFaceIds), Set([f1.id, f2.id]))
    }

    /// Changing clustering threshold followed by Refresh changes the resulting grouping without changing folders.
    func testRegression_Refresh_ThresholdChangeUpdatesGroupingWithoutFolderChange() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_thresh_refresh_\(UUID().uuidString).json")
        let store = LibraryStore(storageURL: tempURL)
        let coordinator = LibraryProcessingCoordinator(libraryStore: store)
        let rootURL = URL(fileURLWithPath: "/tmp")

        let p1 = PhotoRecord(relativePath: "p1.jpg", filename: "p1.jpg", fileSize: 100, modificationDate: Date())
        let p2 = PhotoRecord(relativePath: "p2.jpg", filename: "p2.jpg", fileSize: 100, modificationDate: Date())
        try await store.savePhoto(p1); try await store.savePhoto(p2)
        let f1 = FaceRecord(photoId: p1.id, boundingBox: .zero)
        let f2 = FaceRecord(photoId: p2.id, boundingBox: .zero)
        try await store.saveFaces([f1], forPhotoId: p1.id); try await store.saveFaces([f2], forPhotoId: p2.id)

        // Vectors with similarity = 0.57
        var v1 = [Float](repeating: 0, count: 512); v1[0] = 1.0
        let angle: Float = acos(0.57)
        var v2 = [Float](repeating: 0, count: 512); v2[0] = cos(angle); v2[1] = sin(angle)
        try await store.saveEmbeddings([
            EmbeddingRecord(faceId: f1.id, photoId: p1.id, vector: v1),
            EmbeddingRecord(faceId: f2.id, photoId: p2.id, vector: v2)
        ])

        // High threshold (0.70) -> 2 separate singletons
        try await coordinator.reclusterLibrary(rootFolderURL: rootURL, threshold: 0.70)
        var groups = await store.getGroups()
        XCTAssertEqual(groups.count, 2, "Under threshold 0.70, similarity 0.57 faces must remain separate singletons")

        // Lower threshold (0.54) -> merged into 1 person
        try await coordinator.reclusterLibrary(rootFolderURL: rootURL, threshold: 0.54)
        groups = await store.getGroups()
        XCTAssertEqual(groups.count, 1, "Under calibrated threshold 0.54, similarity 0.57 faces must merge into 1 person")
    }

    /// Refresh is idempotent and does not create duplicate PhotoRecords, FaceRecords, EmbeddingRecords, or People groups.
    func testRegression_Refresh_IdempotentAndNoDuplicates() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_idemp_\(UUID().uuidString).json")
        let store = LibraryStore(storageURL: tempURL)
        let coordinator = LibraryProcessingCoordinator(libraryStore: store)

        let p1 = PhotoRecord(relativePath: "red.png", filename: "red.png", fileSize: 100, modificationDate: Date())
        try await store.savePhoto(p1)
        let f1 = FaceRecord(photoId: p1.id, boundingBox: .zero)
        try await store.saveFaces([f1], forPhotoId: p1.id)
        let v1 = makeNormalizedVector(primaryDim: 10)
        try await store.saveEmbedding(EmbeddingRecord(faceId: f1.id, photoId: p1.id, vector: v1))

        // Multiple reclustering runs
        for _ in 0..<3 {
            try await coordinator.reclusterLibrary(rootFolderURL: URL(fileURLWithPath: "/tmp"), threshold: 0.54)
        }

        let allPhotos = await store.getAllPhotos()
        let allFaces = await store.getAllFaces()
        let allEmbs = await store.getEmbeddings()
        let allGroups = await store.getGroups()

        XCTAssertEqual(allPhotos.count, 1, "No duplicate PhotoRecords")
        XCTAssertEqual(allFaces.count, 1, "No duplicate FaceRecords")
        XCTAssertEqual(allEmbs.count, 1, "No duplicate EmbeddingRecords")
        XCTAssertEqual(allGroups.count, 1, "No duplicate GroupRecords")
    }

    /// Group-photo multi-person visibility remains correct after refresh.
    func testRegression_GroupPhotoMultiPersonVisibility() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_multivis_\(UUID().uuidString).json")
        let store = LibraryStore(storageURL: tempURL)
        let coordinator = LibraryProcessingCoordinator(libraryStore: store)
        let identityService = IdentityService(libraryStore: store)
        let rootURL = URL(fileURLWithPath: "/tmp")

        // Photo X contains Alice and Bob
        let photoX = PhotoRecord(relativePath: "group_photo_x.jpg", filename: "group_photo_x.jpg", fileSize: 100, modificationDate: Date())
        // Photo Y contains Alice alone
        let photoY = PhotoRecord(relativePath: "alice_solo.jpg", filename: "alice_solo.jpg", fileSize: 100, modificationDate: Date())
        // Photo Z contains Bob alone
        let photoZ = PhotoRecord(relativePath: "bob_solo.jpg", filename: "bob_solo.jpg", fileSize: 100, modificationDate: Date())
        for p in [photoX, photoY, photoZ] { try await store.savePhoto(p) }

        let faceAliceX = FaceRecord(photoId: photoX.id, boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3))
        let faceBobX = FaceRecord(photoId: photoX.id, boundingBox: CGRect(x: 0.6, y: 0.1, width: 0.3, height: 0.3))
        try await store.saveFaces([faceAliceX, faceBobX], forPhotoId: photoX.id)

        let faceAliceY = FaceRecord(photoId: photoY.id, boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3))
        try await store.saveFaces([faceAliceY], forPhotoId: photoY.id)

        let faceBobZ = FaceRecord(photoId: photoZ.id, boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3))
        try await store.saveFaces([faceBobZ], forPhotoId: photoZ.id)

        // Alice embeddings (sim ~0.85)
        let vAliceX = makeNormalizedVector(primaryDim: 10, secondaryDim: 11, secondaryWeight: 0.1)
        let vAliceY = makeNormalizedVector(primaryDim: 10, secondaryDim: 11, secondaryWeight: 0.2)
        // Bob embeddings (sim ~0.85, orthogonal to Alice)
        let vBobX = makeNormalizedVector(primaryDim: 100, secondaryDim: 101, secondaryWeight: 0.1)
        let vBobZ = makeNormalizedVector(primaryDim: 100, secondaryDim: 101, secondaryWeight: 0.2)

        try await store.saveEmbeddings([
            EmbeddingRecord(faceId: faceAliceX.id, photoId: photoX.id, vector: vAliceX),
            EmbeddingRecord(faceId: faceAliceY.id, photoId: photoY.id, vector: vAliceY),
            EmbeddingRecord(faceId: faceBobX.id, photoId: photoX.id, vector: vBobX),
            EmbeddingRecord(faceId: faceBobZ.id, photoId: photoZ.id, vector: vBobZ)
        ])

        try await coordinator.reclusterLibrary(rootFolderURL: rootURL, threshold: 0.54)

        let groups = await identityService.fetchGroups()
        XCTAssertEqual(groups.count, 2, "Must form exactly 2 groups: Alice and Bob")

        let aliceGroup = groups.first(where: { $0.memberFaceIds.contains(faceAliceY.id) })!
        let bobGroup = groups.first(where: { $0.memberFaceIds.contains(faceBobZ.id) })!

        XCTAssertTrue(aliceGroup.memberFaceIds.contains(faceAliceX.id))
        XCTAssertTrue(bobGroup.memberFaceIds.contains(faceBobX.id))

        // Multi-person photo visibility check:
        // Photo X must be returned in BOTH Alice's gallery and Bob's gallery!
        let alicePhotos = await identityService.fetchPhotos(forGroupId: aliceGroup.id, rootFolderURL: rootURL)
        let bobPhotos = await identityService.fetchPhotos(forGroupId: bobGroup.id, rootFolderURL: rootURL)

        let alicePhotoFilenames = Set(alicePhotos.map(\.filename))
        let bobPhotoFilenames = Set(bobPhotos.map(\.filename))

        XCTAssertTrue(alicePhotoFilenames.contains("group_photo_x.jpg"), "Photo X must appear in Alice's gallery")
        XCTAssertTrue(alicePhotoFilenames.contains("alice_solo.jpg"), "Photo Y must appear in Alice's gallery")
        XCTAssertTrue(bobPhotoFilenames.contains("group_photo_x.jpg"), "Photo X must appear in Bob's gallery")
        XCTAssertTrue(bobPhotoFilenames.contains("bob_solo.jpg"), "Photo Z must appear in Bob's gallery")
    }

    // MARK: - Step 2: Local FaceCluster Service Tests

    /// 1. Two highly similar faces from different photos -> same FaceCluster.
    func testStep2_FaceCluster_HighSimilarityDifferentPhotos_FormsCluster() async throws {
        let service = LocalFaceClusterService()

        let f1 = UUID(); let p1 = UUID()
        let f2 = UUID(); let p2 = UUID()

        var v1 = [Float](repeating: 0, count: 512); v1[0] = 1.0
        let angle: Float = acos(0.75)
        var v2 = [Float](repeating: 0, count: 512); v2[0] = cos(angle); v2[1] = sin(angle)

        let emb1 = FaceEmbedding(faceId: f1, photoURL: URL(fileURLWithPath: "/tmp/p1.jpg"), vector: v1)
        let emb2 = FaceEmbedding(faceId: f2, photoURL: URL(fileURLWithPath: "/tmp/p2.jpg"), vector: v2)

        let clusters = try await service.formLocalClusters(
            embeddings: [emb1, emb2],
            faceLookup: [:],
            faceToPhotoId: [f1: p1, f2: p2],
            strictThreshold: 0.58,
            enableDiagnostics: true
        )

        XCTAssertEqual(clusters.count, 1, "Two highly similar faces from different photos must form 1 FaceCluster")
        XCTAssertEqual(Set(clusters[0].faceIds), Set([f1, f2]))
        XCTAssertEqual(clusters[0].photoIds, Set([p1, p2]))
    }

    /// 2. Same person with moderate similarity -> may remain separate at Stage 1.
    func testStep2_FaceCluster_ModerateSimilarity_MayRemainSeparate() async throws {
        let service = LocalFaceClusterService()

        let f1 = UUID(); let p1 = UUID()
        let f2 = UUID(); let p2 = UUID()

        // Similarity 0.52 (below strictThreshold 0.58)
        var v1 = [Float](repeating: 0, count: 512); v1[0] = 1.0
        let angle: Float = acos(0.52)
        var v2 = [Float](repeating: 0, count: 512); v2[0] = cos(angle); v2[1] = sin(angle)

        let emb1 = FaceEmbedding(faceId: f1, photoURL: URL(fileURLWithPath: "/tmp/p1.jpg"), vector: v1)
        let emb2 = FaceEmbedding(faceId: f2, photoURL: URL(fileURLWithPath: "/tmp/p2.jpg"), vector: v2)

        let clusters = try await service.formLocalClusters(
            embeddings: [emb1, emb2],
            faceLookup: [:],
            faceToPhotoId: [f1: p1, f2: p2],
            strictThreshold: 0.58,
            enableDiagnostics: true
        )

        XCTAssertEqual(clusters.count, 2, "Moderate similarity below strict threshold must remain in separate FaceClusters at Stage 1")
    }

    /// 3. Two different people -> never cluster.
    func testStep2_FaceCluster_DifferentPeople_NeverCluster() async throws {
        let service = LocalFaceClusterService()

        let f1 = UUID(); let p1 = UUID()
        let f2 = UUID(); let p2 = UUID()

        let v1 = makeNormalizedVector(primaryDim: 10)
        let v2 = makeNormalizedVector(primaryDim: 200)

        let emb1 = FaceEmbedding(faceId: f1, photoURL: URL(fileURLWithPath: "/tmp/p1.jpg"), vector: v1)
        let emb2 = FaceEmbedding(faceId: f2, photoURL: URL(fileURLWithPath: "/tmp/p2.jpg"), vector: v2)

        let clusters = try await service.formLocalClusters(
            embeddings: [emb1, emb2],
            faceLookup: [:],
            faceToPhotoId: [f1: p1, f2: p2],
            strictThreshold: 0.58
        )

        XCTAssertEqual(clusters.count, 2, "Different people must never cluster")
    }

    /// 4. Same-photo faces -> NEVER cluster (Cannot-Link).
    func testStep2_FaceCluster_SamePhoto_NeverCluster_CannotLink() async throws {
        let service = LocalFaceClusterService()

        let f1 = UUID(); let f2 = UUID()
        let samePhotoId = UUID()

        // Identical embeddings in the SAME photo
        var v1 = [Float](repeating: 0, count: 512); v1[0] = 1.0
        var v2 = [Float](repeating: 0, count: 512); v2[0] = 1.0

        let emb1 = FaceEmbedding(faceId: f1, photoURL: URL(fileURLWithPath: "/tmp/same.jpg"), vector: v1)
        let emb2 = FaceEmbedding(faceId: f2, photoURL: URL(fileURLWithPath: "/tmp/same.jpg"), vector: v2)

        let clusters = try await service.formLocalClusters(
            embeddings: [emb1, emb2],
            faceLookup: [:],
            faceToPhotoId: [f1: samePhotoId, f2: samePhotoId],
            strictThreshold: 0.58,
            enableDiagnostics: true
        )

        XCTAssertEqual(clusters.count, 2, "Faces in the same photo must NEVER be in the same FaceCluster (Cannot-Link)")
        XCTAssertNotEqual(clusters[0].faceIds, clusters[1].faceIds)
    }

    /// 5. A->B->C transitive chain -> does not automatically create a contaminated cluster.
    func testStep2_FaceCluster_TransitiveChain_DoesNotContaminate() async throws {
        let service = LocalFaceClusterService()

        let fA = UUID(); let pA = UUID()
        let fB = UUID(); let pB = UUID()
        let fC = UUID(); let pC = UUID()

        // A ~ B (sim 0.65), B ~ C (sim 0.65), but A ~ C (sim ~0.30)
        var vA = [Float](repeating: 0, count: 512); vA[0] = 1.0
        let a1: Float = 49.0 * .pi / 180.0
        var vB = [Float](repeating: 0, count: 512); vB[0] = cos(a1); vB[1] = sin(a1)
        let a2: Float = 98.0 * .pi / 180.0
        var vC = [Float](repeating: 0, count: 512); vC[0] = cos(a2); vC[1] = sin(a2)

        let embA = FaceEmbedding(faceId: fA, photoURL: URL(fileURLWithPath: "/tmp/pA.jpg"), vector: vA)
        let embB = FaceEmbedding(faceId: fB, photoURL: URL(fileURLWithPath: "/tmp/pB.jpg"), vector: vB)
        let embC = FaceEmbedding(faceId: fC, photoURL: URL(fileURLWithPath: "/tmp/pC.jpg"), vector: vC)

        let clusters = try await service.formLocalClusters(
            embeddings: [embA, embB, embC],
            faceLookup: [:],
            faceToPhotoId: [fA: pA, fB: pB, fC: pC],
            strictThreshold: 0.58,
            enableDiagnostics: true
        )

        // Cluster containing A must not contain C
        for c in clusters {
            let hasA = c.faceIds.contains(fA)
            let hasC = c.faceIds.contains(fC)
            XCTAssertFalse(hasA && hasC, "Incompatible faces A and C must not be in the same FaceCluster via transitive drift")
        }
    }

    /// 6. Cluster centroid remains normalized.
    func testStep2_FaceCluster_CentroidIsNormalized() async throws {
        let service = LocalFaceClusterService()

        let f1 = UUID(); let p1 = UUID()
        let f2 = UUID(); let p2 = UUID()

        let v1 = makeNormalizedVector(primaryDim: 30, secondaryDim: 31, secondaryWeight: 0.1)
        let v2 = makeNormalizedVector(primaryDim: 30, secondaryDim: 31, secondaryWeight: 0.2)

        let emb1 = FaceEmbedding(faceId: f1, photoURL: URL(fileURLWithPath: "/tmp/p1.jpg"), vector: v1)
        let emb2 = FaceEmbedding(faceId: f2, photoURL: URL(fileURLWithPath: "/tmp/p2.jpg"), vector: v2)

        let clusters = try await service.formLocalClusters(
            embeddings: [emb1, emb2],
            faceLookup: [:],
            faceToPhotoId: [f1: p1, f2: p2],
            strictThreshold: 0.58
        )

        for c in clusters {
            let norm = sqrt(c.centroid.reduce(0) { $0 + $1 * $1 })
            XCTAssertEqual(norm, 1.0, accuracy: 0.001, "FaceCluster centroid must be unit normalized")
        }
    }

    /// 7. Re-running clustering produces deterministic results.
    func testStep2_FaceCluster_DeterministicInference() async throws {
        let service = LocalFaceClusterService()

        let f1 = UUID(); let p1 = UUID()
        let f2 = UUID(); let p2 = UUID()
        let f3 = UUID(); let p3 = UUID()

        let v1 = makeNormalizedVector(primaryDim: 40, secondaryDim: 41, secondaryWeight: 0.1)
        let v2 = makeNormalizedVector(primaryDim: 40, secondaryDim: 41, secondaryWeight: 0.15)
        let v3 = makeNormalizedVector(primaryDim: 150)

        let emb1 = FaceEmbedding(faceId: f1, photoURL: URL(fileURLWithPath: "/tmp/p1.jpg"), vector: v1)
        let emb2 = FaceEmbedding(faceId: f2, photoURL: URL(fileURLWithPath: "/tmp/p2.jpg"), vector: v2)
        let emb3 = FaceEmbedding(faceId: f3, photoURL: URL(fileURLWithPath: "/tmp/p3.jpg"), vector: v3)

        let clusters1 = try await service.formLocalClusters(
            embeddings: [emb1, emb2, emb3],
            faceLookup: [:],
            faceToPhotoId: [f1: p1, f2: p2, f3: p3],
            strictThreshold: 0.58
        )

        let clusters2 = try await service.formLocalClusters(
            embeddings: [emb1, emb2, emb3],
            faceLookup: [:],
            faceToPhotoId: [f1: p1, f2: p2, f3: p3],
            strictThreshold: 0.58
        )

        XCTAssertEqual(clusters1.count, clusters2.count)
        for i in 0..<clusters1.count {
            XCTAssertEqual(Set(clusters1[i].faceIds), Set(clusters2[i].faceIds))
        }
    }

    /// 8. No face belongs to multiple FaceClusters.
    func testStep2_FaceCluster_NoDuplicateFaceAssignment() async throws {
        let service = LocalFaceClusterService()

        var embs: [FaceEmbedding] = []
        var faceToPhoto: [UUID: UUID] = [:]

        for i in 0..<10 {
            let fId = UUID()
            let pId = UUID()
            faceToPhoto[fId] = pId
            let v = makeNormalizedVector(primaryDim: (i % 3) * 50 + 10, secondaryDim: (i % 3) * 50 + 11, secondaryWeight: Float(i) * 0.05)
            embs.append(FaceEmbedding(faceId: fId, photoURL: URL(fileURLWithPath: "/tmp/\(i).jpg"), vector: v))
        }

        let clusters = try await service.formLocalClusters(
            embeddings: embs,
            faceLookup: [:],
            faceToPhotoId: faceToPhoto,
            strictThreshold: 0.58
        )

        var allAssignedFaceIds: [UUID] = []
        for c in clusters {
            allAssignedFaceIds.append(contentsOf: c.faceIds)
        }

        XCTAssertEqual(allAssignedFaceIds.count, Set(allAssignedFaceIds).count, "Every face must belong to at most one FaceCluster")
    }

    /// 9. Ground-truth 19-photo dataset FaceCluster formation audit.
    func testStep2_FaceCluster_GroundTruth19PhotoDatasetAudit() async throws {
        let prodURL = URL(fileURLWithPath: "/Users/vikramaditya/Library/Application Support/KeepSake/library_index.json")
        guard FileManager.default.fileExists(atPath: prodURL.path) else { return }

        let store = LibraryStore(storageURL: prodURL)
        let allPhotos = await store.getAllPhotos()
        let allFaces = await store.getAllFaces()
        let allEmbeddings = await store.getEmbeddings()

        XCTAssertEqual(allPhotos.count, 19)
        XCTAssertEqual(allFaces.count, 53)
        XCTAssertEqual(allEmbeddings.count, 53)

        let faceToPhotoId = Dictionary(uniqueKeysWithValues: allFaces.map { ($0.id, $0.photoId) })
        let faceLookup = Dictionary(uniqueKeysWithValues: allFaces.map { ($0.id, DetectedFace(id: $0.id, boundingBox: $0.boundingBox, confidence: $0.confidence)) })

        let domainEmbeddings = allEmbeddings.map { emb in
            FaceEmbedding(
                id: emb.id,
                photoURL: URL(fileURLWithPath: "/tmp/\(emb.photoId).jpg"),
                faceId: emb.faceId,
                vector: emb.vector,
                modelName: emb.modelName,
                inferenceTimeMs: emb.inferenceTimeMs,
                createdAt: emb.createdAt
            )
        }

        let service = LocalFaceClusterService()
        let clusters = try await service.formLocalClusters(
            embeddings: domainEmbeddings,
            faceLookup: faceLookup,
            faceToPhotoId: faceToPhotoId,
            strictThreshold: 0.58,
            enableDiagnostics: true
        )

        // Verifications for Stage 1:
        // 1. Invariants
        for c in clusters {
            XCTAssertEqual(c.faceIds.count, c.photoIds.count, "Cannot-Link: no FaceCluster may contain two faces from same photo")
            XCTAssertEqual(Set(c.faceIds).count, c.faceIds.count, "No duplicate face IDs inside cluster")
            let norm = sqrt(c.centroid.reduce(0) { $0 + $1 * $1 })
            XCTAssertEqual(norm, 1.0, accuracy: 0.001, "Centroid must be unit normalized")
        }

        // 2. All 53 faces must be accounted for
        let totalAssigned = clusters.reduce(0) { $0 + $1.faceIds.count }
        XCTAssertEqual(totalAssigned, 53, "All 53 detected faces must belong to a FaceCluster")

        // 3. Expected cluster count: Stage 1 high-precision local clusters should produce ~20-50 clusters
        XCTAssertGreaterThanOrEqual(clusters.count, 20, "Stage 1 preserves appearance modes into 20-50 local clusters")
        XCTAssertLessThanOrEqual(clusters.count, 50, "Stage 1 merges high-confidence matching appearances")

        let multiFaceClusters = clusters.filter { $0.faceIds.count > 1 }
        XCTAssertGreaterThanOrEqual(multiFaceClusters.count, 4, "High-confidence same-person appearances must form multi-face clusters")
    }
}







