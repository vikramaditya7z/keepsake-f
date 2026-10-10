import SwiftUI

/// Native macOS Preferences / Settings View.
struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var browserViewModel: PhotoBrowserViewModel

    var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
                .tag(0)

            processingTab
                .tabItem {
                    Label("Processing", systemImage: "cpu")
                }
                .tag(1)

            developerTab
                .tabItem {
                    Label("Developer", systemImage: "hammer")
                }
                .tag(2)
        }
        .padding(20)
        .frame(width: 500, height: 360)
    }

    // MARK: - General Tab

    private var generalTab: some View {
        Form {
            Section(header: Text("Photo Library").font(.headline)) {
                if let folderURL = browserViewModel.selectedFolderURL {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(.tint)
                            Text(folderURL.lastPathComponent)
                                .fontWeight(.semibold)
                        }

                        Text(folderURL.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)

                        HStack(spacing: 12) {
                            Button("Choose Different Folder…") {
                                browserViewModel.chooseFolder()
                            }

                            Button("Rescan Library") {
                                browserViewModel.triggerManualRescan()
                            }
                        }
                        .padding(.top, 4)
                    }
                } else {
                    HStack {
                        Text("No folder selected.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Choose Folder…") {
                            browserViewModel.chooseFolder()
                        }
                    }
                }
            }

            Divider()

            Section(header: Text("Folder Monitoring").font(.headline)) {
                Toggle("Automatically monitor library folder for changes", isOn: $settings.autoMonitoringEnabled)
                    .help("When enabled, Keepsake detects newly added, changed, or deleted photos in real time.")

                Text("Keepsake uses macOS kernel events to watch for folder updates with ~0% idle CPU.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Section(header: Text("Appearance & Grid").font(.headline)) {
                HStack {
                    Text("Thumbnail Size:")
                    Slider(value: $settings.gridThumbnailSize, in: 120...280, step: 10)
                        .accessibilityLabel("Thumbnail Size Slider")
                    Text("\(Int(settings.gridThumbnailSize)) px")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 45, alignment: .trailing)
                }

                Toggle("Show face bounding boxes by default in detail view", isOn: $settings.showFaceOverlaysByDefault)
            }
        }
    }

    // MARK: - Processing Tab

    private var processingTab: some View {
        Form {
            Section(header: Text("On-Device Indexing").font(.headline)) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Privacy & Storage:")
                        .fontWeight(.semibold)
                    Text("All face detection, ArcFace embeddings, and cluster identities are stored 100% locally on your Mac inside your Application Support folder.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if browserViewModel.failedPhotosCount > 0 {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(browserViewModel.failedPhotosCount) photos failed to process")
                                .font(.subheadline)
                                .foregroundStyle(.red)
                            Text("Retry processing corrupted or interrupted photos.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Retry Failed Photos") {
                            browserViewModel.retryFailedPhotos()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    .padding(.vertical, 4)
                }
            }

            Divider()

            Section(header: Text("Background Worker Pool").font(.headline)) {
                Text("Keepsake automatically allocates bounded concurrent workers based on your Mac's CPU cores (2–4 workers) to balance performance and battery life.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Developer Tab

    private var developerTab: some View {
        Form {
            Section(header: Text("Experimental & Diagnostic Tools").font(.headline)) {
                Toggle("Enable Developer Mode", isOn: $settings.developerModeEnabled)
                    .help("Enables access to Face Recognition Lab, Clustering Experiment Lab, and raw embedding telemetry.")

                Text("When enabled, experimental research tools and detailed ML performance telemetry become accessible in the toolbar and detail viewer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if settings.developerModeEnabled {
                Divider()

                Section(header: Text("Active Pipeline Diagnostics").font(.headline)) {
                    LabeledContent("Face Recognition Model", value: "ArcFace ResNet (512-D L2)")
                    LabeledContent("Benchmark Model", value: "Apple Vision FeaturePrint Rev 2 (768-D)")
                    LabeledContent("Default Clustering Threshold", value: "0.65 Cosine Similarity")
                    LabeledContent("Indexed Embeddings", value: "\(browserViewModel.totalStoredEmbeddings)")
                    LabeledContent("Indexed People Groups", value: "\(browserViewModel.totalStoredGroups)")
                }
            }
        }
    }
}
