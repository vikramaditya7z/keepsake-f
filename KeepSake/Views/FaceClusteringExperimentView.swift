import SwiftUI
import AppKit

/// Developer UI for the Phase 4 Face Embedding Clustering Experiment.
struct FaceClusteringExperimentView: View {
    let photos: [PhotoItem]
    let onDismiss: () -> Void

    @StateObject private var viewModel = FaceClusteringViewModel()

    var body: some View {
        VStack(spacing: 0) {
            // Header Bar
            headerBar

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Diagnostic Banner & Threshold Controller
                    thresholdControlSection
                    metricsDashboardSection

                    // Threshold Sensitivity Matrix
                    if !viewModel.thresholdSensitivity.isEmpty {
                        sensitivityMatrixSection
                    }

                    Divider()

                    // Clustered Groups Section
                    groupsSection
                }
                .padding(24)
            }
        }
        .frame(minWidth: 840, minHeight: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            await viewModel.runPipeline(on: photos)
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Image(systemName: "person.3.sequence.fill")
                        .foregroundStyle(.indigo)
                        .font(.title3)
                    Text("Face Clustering Experiment Lab")
                        .font(.headline)
                    Text("PHASE 4 EXPERIMENTAL")
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.indigo.opacity(0.2)))
                        .foregroundStyle(.indigo)
                }

                Text("Evaluating ArcFace cosine-similarity graph clustering into preliminary person groups.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if viewModel.isProcessing {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(viewModel.progressMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button(action: {
                    Task { await viewModel.runPipeline(on: photos) }
                }) {
                    Label("Re-scan Photos", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }

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

    // MARK: - Threshold Controller

    private var thresholdControlSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("SIMILARITY THRESHOLD EXPERIMENT")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Text("Current: \(String(format: "%.2f", viewModel.currentThreshold))")
                    .font(.headline)
                    .foregroundStyle(.indigo)
            }

            HStack(spacing: 16) {
                Slider(
                    value: Binding(
                        get: { Double(viewModel.currentThreshold) },
                        set: { newVal in
                            Task { await viewModel.setThreshold(Float(newVal)) }
                        }
                    ),
                    in: 0.40...0.90,
                    step: 0.05
                )

                HStack(spacing: 6) {
                    ForEach([0.50, 0.55, 0.60, 0.65, 0.70, 0.75, 0.80], id: \.self) { val in
                        let isSelected = abs(viewModel.currentThreshold - Float(val)) < 0.01
                        Button(String(format: "%.2f", val)) {
                            Task { await viewModel.setThreshold(Float(val)) }
                        }
                        .buttonStyle(.bordered)
                        .tint(isSelected ? .indigo : .primary)
                        .controlSize(.small)
                    }
                }
            }

            Text("Notice: Lower thresholds merge looser face matches (risking false merges). Higher thresholds enforce tighter facial identity constraints (risking singleton fragmentation).")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }

    // MARK: - Metrics Dashboard

    private var metricsDashboardSection: some View {
        HStack(spacing: 12) {
            metricTile(
                title: "Photos Scanned",
                value: "\(viewModel.processedPhotosCount)",
                subtitle: "\(viewModel.totalPhotosCount) total in folder",
                icon: "photo.stack",
                accentColor: .blue
            )

            metricTile(
                title: "Faces & Embeddings",
                value: "\(viewModel.extractedEmbeddings.count)",
                subtitle: "512-D ArcFace vectors",
                icon: "face.smiling",
                accentColor: .purple
            )

            metricTile(
                title: "Person Groups",
                value: "\(viewModel.faceGroups.count)",
                subtitle: "\(viewModel.executionMetrics?.multiFaceGroups ?? 0) multi • \(viewModel.executionMetrics?.singletonGroups ?? 0) singletons",
                icon: "person.3.sequence",
                accentColor: .indigo
            )

            metricTile(
                title: "Clustering Latency",
                value: String(format: "%.2f ms", viewModel.executionMetrics?.executionTimeMs ?? 0.0),
                subtitle: "\(viewModel.executionMetrics?.pairwiseComparisonCount ?? 0) comparisons",
                icon: "bolt.stopwatch",
                accentColor: .green
            )
        }
    }

    private func metricTile(
        title: String,
        value: String,
        subtitle: String,
        icon: String,
        accentColor: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(accentColor)
            }

            Text(value)
                .font(.title2)
                .fontWeight(.bold)
                .foregroundStyle(.primary)

            Text(subtitle)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }

    // MARK: - Sensitivity Matrix

    private var sensitivityMatrixSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CANDIDATE THRESHOLD SENSITIVITY MATRIX")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                ForEach(viewModel.thresholdSensitivity) { entry in
                    let isCurrent = abs(viewModel.currentThreshold - entry.threshold) < 0.01
                    VStack(spacing: 4) {
                        Text(String(format: "%.2f", entry.threshold))
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(isCurrent ? .indigo : .primary)

                        Text("\(entry.groupCount) groups")
                            .font(.caption2)
                            .fontWeight(.medium)

                        Text("\(entry.singletonCount) singletons")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)

                        Text("Max: \(entry.maxGroupSize)")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(isCurrent ? Color.indigo.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(isCurrent ? Color.indigo : Color(nsColor: .separatorColor), lineWidth: isCurrent ? 1.5 : 0.5)
                    )
                    .onTapGesture {
                        Task { await viewModel.setThreshold(entry.threshold) }
                    }
                }
            }
        }
    }

    // MARK: - Groups Section

    private var groupsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Resulting Face Groups (\(viewModel.faceGroups.count))")
                    .font(.headline)

                Spacer()

                Text("Experimental grouping • No permanent identity established")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if viewModel.faceGroups.isEmpty {
                if viewModel.isProcessing {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Extracting face embeddings and clustering…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 24)
                } else {
                    Text("No face groups discovered. Select a folder containing photos with detected faces.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 24)
                }
            } else {
                ForEach(viewModel.faceGroups) { group in
                    groupCard(group: group)
                }
            }
        }
    }

    private func groupCard(group: FaceGroup) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Group Header
            HStack(spacing: 12) {
                // Representative Face Thumbnail
                if let rep = group.representativeMember, let crop = viewModel.faceCrops[rep.faceId] {
                    ZStack(alignment: .bottomTrailing) {
                        Image(nsImage: crop)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                        Image(systemName: "star.circle.fill")
                            .foregroundStyle(.yellow)
                            .font(.caption)
                            .background(Circle().fill(Color.black))
                            .offset(x: 2, y: 2)
                    }
                } else {
                    Image(systemName: "person.crop.square")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                        .frame(width: 56, height: 56)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(group.title)
                            .font(.headline)

                        Text(group.formattedMemberCount)
                            .font(.caption)
                            .fontWeight(.medium)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(group.faceCount > 1 ? Color.indigo.opacity(0.15) : Color.gray.opacity(0.15)))
                            .foregroundStyle(group.faceCount > 1 ? Color.indigo : Color.secondary)
                    }

                    Text("Intra-Cluster Similarity: \(group.formattedSimilarityStats)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            Divider()

            // Member Face Thumbnails
            VStack(alignment: .leading, spacing: 6) {
                Text("Member Faces (\(group.faceCount)):")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(group.members) { member in
                            memberFaceThumbnail(member: member, isRepresentative: member.id == group.representativeMember?.id)
                        }
                    }
                    .padding(.vertical, 2)
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

    private func memberFaceThumbnail(member: ClusteredFaceMember, isRepresentative: Bool) -> some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                if let crop = viewModel.faceCrops[member.faceId] {
                    Image(nsImage: crop)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                } else {
                    ProgressView()
                        .frame(width: 64, height: 64)
                }

                if isRepresentative {
                    Text("REP")
                        .font(.system(size: 8, weight: .bold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.yellow)
                        .foregroundStyle(.black)
                        .clipShape(Capsule())
                        .padding(3)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(isRepresentative ? Color.yellow : Color(nsColor: .separatorColor), lineWidth: isRepresentative ? 1.5 : 0.5)
            )

            Text(member.photoURL.lastPathComponent)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 64)

            Text(String(format: "sim: %.2f", member.similarityToCentroid))
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
        }
    }
}
