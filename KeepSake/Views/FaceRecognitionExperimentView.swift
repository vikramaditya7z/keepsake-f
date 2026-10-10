import SwiftUI
import AppKit

/// Evaluation mode for the Face Recognition Benchmark Lab.
enum RecognitionBenchmarkMode: String, CaseIterable, Identifiable {
    case comparative = "Side-by-Side Benchmark"
    case visionFeaturePrint = "Vision FeaturePrint (768-D)"
    case arcFace = "ArcFace (512-D)"

    var id: String { rawValue }
}

/// Experimental developer UI for benchmarking local face embeddings (Vision FeaturePrint vs. ArcFace).
struct FaceRecognitionExperimentView: View {
    let photo: PhotoItem
    let detectedFaces: [DetectedFace]
    let onDismiss: () -> Void

    @State private var benchmarkMode: RecognitionBenchmarkMode = .comparative
    @State private var visionEmbeddings: [UUID: FaceEmbedding] = [:]
    @State private var arcfaceEmbeddings: [UUID: FaceEmbedding] = [:]
    @State private var faceCrops: [UUID: NSImage] = [:]
    @State private var isGenerating: [UUID: Bool] = [:]
    @State private var selectedFaceA: DetectedFace?
    @State private var selectedFaceB: DetectedFace?
    @State private var errorMessage: String?

    private let visionService = VisionFaceRecognitionService()
    private let arcFaceService = ArcFaceRecognitionService()
    private let preprocessor = FacePreprocessingService()

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerBar

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Mode Selector & Model Diagnostic Banner
                    modeSelectionSection
                    modelInfoSection

                    // Section 1: Detected Faces & Embeddings
                    facesSection

                    Divider()

                    // Section 2: Comparison Tool & Benchmark Metrics
                    comparisonSection

                    // Section 3: Benchmark Summary & Separation Analysis
                    benchmarkAnalysisSection
                }
                .padding(24)
            }
        }
        .frame(minWidth: 760, minHeight: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            await loadInitialCrops()
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Image(systemName: "bolt.badge.clock.fill")
                        .foregroundStyle(.purple)
                        .font(.title3)
                    Text("Face Recognition Benchmark Lab")
                        .font(.headline)
                    Text("PHASE 3B BENCHMARK")
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.purple.opacity(0.2)))
                        .foregroundStyle(.purple)
                }

                Text("Evaluating Apple Vision FeaturePrint (768-D) vs. ArcFace (512-D) on-device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Done") {
                onDismiss()
            }
            .keyboardShortcut(.cancelAction)
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Mode Selection

    private var modeSelectionSection: some View {
        HStack {
            Text("Benchmark Pipeline Mode:")
                .font(.subheadline)
                .fontWeight(.medium)

            Picker("Pipeline Mode", selection: $benchmarkMode) {
                ForEach(RecognitionBenchmarkMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 460)

            Spacer()
        }
    }

    // MARK: - Model Info Banner

    private var modelInfoSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("EVALUATED BACKENDS")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                // Backend A: Vision
                backendSummaryCard(
                    title: "Pipeline A: Apple Vision",
                    modelName: visionService.modelName,
                    architecture: "Deep CNN FeaturePrint",
                    dim: "\(visionService.embeddingDimension) Float32",
                    accentColor: .blue,
                    isActive: benchmarkMode == .comparative || benchmarkMode == .visionFeaturePrint
                )

                // Backend B: ArcFace
                backendSummaryCard(
                    title: "Pipeline B: ArcFace",
                    modelName: arcFaceService.modelName,
                    architecture: "Additive Angular Margin",
                    dim: "\(arcFaceService.embeddingDimension) Float32",
                    accentColor: .purple,
                    isActive: benchmarkMode == .comparative || benchmarkMode == .arcFace
                )
            }
        }
    }

    private func backendSummaryCard(
        title: String,
        modelName: String,
        architecture: String,
        dim: String,
        accentColor: Color,
        isActive: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundStyle(accentColor)
                Spacer()
                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(accentColor)
                        .font(.caption)
                }
            }

            Text(modelName)
                .font(.subheadline)
                .fontWeight(.medium)
                .lineLimit(1)

            HStack(spacing: 12) {
                Text("Arch: \(architecture)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("Dim: \(dim)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isActive ? accentColor.opacity(0.4) : Color(nsColor: .separatorColor), lineWidth: isActive ? 1.5 : 0.5)
        )
        .opacity(isActive ? 1.0 : 0.6)
    }

    // MARK: - Faces Section

    private var facesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Detected Faces in Current Photo (\(detectedFaces.count))")
                    .font(.headline)

                Spacer()

                if !detectedFaces.isEmpty {
                    Button(action: {
                        Task { await generateAllEmbeddings() }
                    }) {
                        Label("Extract All Vectors (Both Models)", systemImage: "bolt.fill")
                    }
                }
            }

            if detectedFaces.isEmpty {
                Text("No faces were detected in this photo. Open a photo containing faces to run the recognition benchmark.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 16)], spacing: 16) {
                    ForEach(Array(detectedFaces.enumerated()), id: \.element.id) { index, face in
                        faceCard(index: index + 1, face: face)
                    }
                }
            }
        }
    }

    private func faceCard(index: Int, face: DetectedFace) -> some View {
        let visionEmb = visionEmbeddings[face.id]
        let arcfaceEmb = arcfaceEmbeddings[face.id]
        let isWorking = isGenerating[face.id] ?? false

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                // Face Crop Thumbnail
                ZStack {
                    if let crop = faceCrops[face.id] {
                        Image(nsImage: crop)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .frame(width: 76, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )

                // Face Metadata & Status
                VStack(alignment: .leading, spacing: 3) {
                    Text("Face #\(index)")
                        .font(.headline)

                    if let vEmb = visionEmb, let aEmb = arcfaceEmb {
                        HStack(spacing: 4) {
                            Circle().fill(Color.green).frame(width: 6, height: 6)
                            Text("Vision: \(vEmb.dimension)D (\(vEmb.formattedInferenceTime))")
                                .font(.caption2)
                                .foregroundStyle(.blue)
                        }
                        HStack(spacing: 4) {
                            Circle().fill(Color.purple).frame(width: 6, height: 6)
                            Text("ArcFace: \(aEmb.dimension)D (\(aEmb.formattedInferenceTime))")
                                .font(.caption2)
                                .foregroundStyle(.purple)
                        }
                    } else if let vEmb = visionEmb {
                        Text("Vision: \(vEmb.dimension)D (\(vEmb.formattedInferenceTime))")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                    } else if let aEmb = arcfaceEmb {
                        Text("ArcFace: \(aEmb.dimension)D (\(aEmb.formattedInferenceTime))")
                            .font(.caption2)
                            .foregroundStyle(.purple)
                    } else if isWorking {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Extracting embeddings…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Vectors not extracted")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()
            }

            // Action Buttons
            HStack(spacing: 8) {
                if visionEmb == nil || arcfaceEmb == nil {
                    Button("Extract Vectors") {
                        Task { await generateEmbedding(for: face) }
                    }
                    .disabled(isWorking)
                } else {
                    Button(selectedFaceA?.id == face.id ? "✓ Face A" : "Set as Face A") {
                        selectedFaceA = face
                    }
                    .buttonStyle(.bordered)
                    .tint(selectedFaceA?.id == face.id ? .blue : .primary)

                    Button(selectedFaceB?.id == face.id ? "✓ Face B" : "Set as Face B") {
                        selectedFaceB = face
                    }
                    .buttonStyle(.bordered)
                    .tint(selectedFaceB?.id == face.id ? .purple : .primary)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }

    // MARK: - Comparison Section

    private var comparisonSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Face Embedding Benchmark Comparison")
                .font(.headline)

            HStack(alignment: .top, spacing: 16) {
                // Face A Slot
                faceComparisonSlot(
                    label: "Face A",
                    face: selectedFaceA,
                    color: .blue
                )

                // Comparison Results Box
                comparisonResultsView

                // Face B Slot
                faceComparisonSlot(
                    label: "Face B",
                    face: selectedFaceB,
                    color: .purple
                )
            }
        }
    }

    private func faceComparisonSlot(label: String, face: DetectedFace?, color: Color) -> some View {
        VStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .fontWeight(.bold)
                .foregroundStyle(color)

            if let face = face, let crop = faceCrops[face.id] {
                Image(nsImage: crop)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                if let vEmb = visionEmbeddings[face.id], let aEmb = arcfaceEmbeddings[face.id] {
                    Text("Vision: \(vEmb.dimension)D • ArcFace: \(aEmb.dimension)D")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(spacing: 4) {
                    Image(systemName: "person.crop.square")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("Select a face")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(width: 80, height: 80)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            }
        }
        .frame(width: 140)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private var comparisonResultsView: some View {
        VStack(spacing: 12) {
            if let faceA = selectedFaceA, let faceB = selectedFaceB {
                let vA = visionEmbeddings[faceA.id]
                let vB = visionEmbeddings[faceB.id]
                let aA = arcfaceEmbeddings[faceA.id]
                let aB = arcfaceEmbeddings[faceB.id]

                if benchmarkMode == .comparative {
                    // Side-by-Side Dual Benchmark Metrics
                    HStack(spacing: 12) {
                        // Vision Metrics
                        if let vA = vA, let vB = vB {
                            let simV = EmbeddingSimilarityUtility.cosineSimilarity(vA.vector, vB.vector)
                            let distV = EmbeddingSimilarityUtility.euclideanDistance(vA.vector, vB.vector)
                            benchmarkCard(
                                title: "Vision (768-D)",
                                similarity: simV,
                                l2Distance: distV,
                                latency: (vA.inferenceTimeMs + vB.inferenceTimeMs) / 2.0,
                                accentColor: .blue
                            )
                        } else {
                            Text("Extract Vision vectors to compare").font(.caption2).foregroundStyle(.secondary)
                        }

                        // ArcFace Metrics
                        if let aA = aA, let aB = aB {
                            let simA = EmbeddingSimilarityUtility.cosineSimilarity(aA.vector, aB.vector)
                            let distA = EmbeddingSimilarityUtility.euclideanDistance(aA.vector, aB.vector)
                            benchmarkCard(
                                title: "ArcFace (512-D)",
                                similarity: simA,
                                l2Distance: distA,
                                latency: (aA.inferenceTimeMs + aB.inferenceTimeMs) / 2.0,
                                accentColor: .purple
                            )
                        } else {
                            Text("Extract ArcFace vectors to compare").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                } else if benchmarkMode == .visionFeaturePrint, let vA = vA, let vB = vB {
                    let sim = EmbeddingSimilarityUtility.cosineSimilarity(vA.vector, vB.vector)
                    let dist = EmbeddingSimilarityUtility.euclideanDistance(vA.vector, vB.vector)
                    singleModelComparisonView(
                        modelName: "Apple Vision FeaturePrint (Revision 2)",
                        dim: 768,
                        similarity: sim,
                        dist: dist,
                        color: .blue
                    )
                } else if benchmarkMode == .arcFace, let aA = aA, let aB = aB {
                    let sim = EmbeddingSimilarityUtility.cosineSimilarity(aA.vector, aB.vector)
                    let dist = EmbeddingSimilarityUtility.euclideanDistance(aA.vector, aB.vector)
                    singleModelComparisonView(
                        modelName: "ArcFace (MobileFaceNet 512-D)",
                        dim: 512,
                        similarity: sim,
                        dist: dist,
                        color: .purple
                    )
                } else {
                    Text("Generating embeddings for selected faces…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(spacing: 6) {
                    Text("—")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                    Text("Select Face A & B to compare cosine similarity")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 16)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }

    private func benchmarkCard(
        title: String,
        similarity: Float,
        l2Distance: Float,
        latency: Double,
        accentColor: Color
    ) -> some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(accentColor)

            Text(String(format: "%.4f", similarity))
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(similarityColor(for: similarity))

            ProgressView(value: Double(max(0, similarity)), total: 1.0)
                .tint(similarityColor(for: similarity))
                .padding(.horizontal, 8)

            HStack(spacing: 8) {
                Text("L2: \(String(format: "%.3f", l2Distance))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("Avg Latency: \(String(format: "%.1f ms", latency))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(similarityInterpretation(for: similarity))
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(accentColor.opacity(0.3), lineWidth: 1)
        )
    }

    private func singleModelComparisonView(
        modelName: String,
        dim: Int,
        similarity: Float,
        dist: Float,
        color: Color
    ) -> some View {
        VStack(spacing: 8) {
            Text("\(modelName) • \(dim)-D")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)

            Text(String(format: "%.4f", similarity))
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(similarityColor(for: similarity))

            Text("L2 Euclidean Distance: \(String(format: "%.3f", dist))")
                .font(.caption)
                .foregroundStyle(.secondary)

            ProgressView(value: Double(max(0, similarity)), total: 1.0)
                .tint(similarityColor(for: similarity))
                .padding(.horizontal, 16)

            Text(similarityInterpretation(for: similarity))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Benchmark Analysis Section

    private var benchmarkAnalysisSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("BENCHMARK SEPARATION & ARCHITECTURAL SUMMARY")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Angular Margin Separation", systemImage: "chart.bar.xaxis")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.purple)
                        Text("ArcFace uses additive angular margin loss (\(Image(systemName: "plus.forwardslash.minus"))m), enforcing tight hyperspherical geodesic clustering for same identities and high angular divergence for distinct faces.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Label("Vector Memory Efficiency", systemImage: "internaldrive")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.blue)
                        Text("ArcFace produces 512-D Float32 vectors (2,048 bytes/face), saving 33.3% memory compared to Vision FeaturePrint's 768-D vectors (3,072 bytes/face).")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
        }
    }

    private func similarityColor(for score: Float) -> Color {
        if score >= 0.75 { return .green }
        if score >= 0.50 { return .orange }
        return .blue
    }

    private func similarityInterpretation(for score: Float) -> String {
        if score >= 0.80 { return "Very High (Likely Same Person)" }
        if score >= 0.65 { return "Moderate (Possible Match)" }
        return "Low (Distinct Individuals)"
    }

    // MARK: - Logic & Operations

    private func loadInitialCrops() async {
        for face in detectedFaces {
            if let crop = try? preprocessor.cropFace(from: photo.url, normalizedBox: face.boundingBox) {
                let nsImage = NSImage(cgImage: crop, size: NSSize(width: crop.width, height: crop.height))
                faceCrops[face.id] = nsImage
            }
        }

        // Auto-select first two faces if available
        if detectedFaces.count >= 1 {
            selectedFaceA = detectedFaces[0]
        }
        if detectedFaces.count >= 2 {
            selectedFaceB = detectedFaces[1]
        }
    }

    private func generateEmbedding(for face: DetectedFace) async {
        isGenerating[face.id] = true
        do {
            // Generate both Vision FeaturePrint and ArcFace embeddings for benchmark comparison
            async let visionTask = visionService.generateEmbedding(for: face, in: photo.url)
            async let arcfaceTask = arcFaceService.generateEmbedding(for: face, in: photo.url)

            let (vEmb, aEmb) = try await (visionTask, arcfaceTask)
            visionEmbeddings[face.id] = vEmb
            arcfaceEmbeddings[face.id] = aEmb
        } catch {
            print("Failed to generate embeddings: \(error.localizedDescription)")
        }
        isGenerating[face.id] = false
    }

    private func generateAllEmbeddings() async {
        for face in detectedFaces {
            await generateEmbedding(for: face)
        }
    }
}
