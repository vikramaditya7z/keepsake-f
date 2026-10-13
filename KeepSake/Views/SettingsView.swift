import SwiftUI

/// Unified native macOS Settings & Management Hub.
///
/// Organized into 4 categories:
/// 1. General: Browsing, appearance, monitoring, and developer diagnostics.
/// 2. Library & Cache: Disposable disk thumbnail cache management and persistent library stats.
/// 3. Recycle Bin: Manage false detections and removed person associations.
/// 4. Unassigned Faces: Browse, select, and bulk-assign unassigned faces.
struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var browserViewModel: PhotoBrowserViewModel
    @ObservedObject var peopleViewModel: PeopleViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var diskCacheSizeText: String = "Calculating…"
    @State private var showConfirmClearCache: Bool = false
    @State private var selectedTab: Int = 0

    @MainActor
    init(browserViewModel: PhotoBrowserViewModel, peopleViewModel: PeopleViewModel? = nil) {
        self.browserViewModel = browserViewModel
        self.peopleViewModel = peopleViewModel ?? PeopleViewModel()
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header Bar
            HStack {
                Text("KeepSake Settings & Management")
                    .font(.headline)

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.regular)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 10)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            TabView(selection: $selectedTab) {
                generalTab
                    .tabItem {
                        Label("General", systemImage: "gearshape")
                    }
                    .tag(0)

                libraryAndCacheTab
                    .tabItem {
                        Label("Library & Cache", systemImage: "internaldrive")
                    }
                    .tag(1)

                recycleBinTab
                    .tabItem {
                        Label("Recycle Bin", systemImage: "trash")
                    }
                    .tag(2)

                unassignedFacesTab
                    .tabItem {
                        Label("Unassigned Faces", systemImage: "person.crop.circle.badge.questionmark")
                    }
                    .tag(3)
            }
            .padding(16)
        }
        .frame(minWidth: 740, idealWidth: 780, maxWidth: 880, minHeight: 560, idealHeight: 620, maxHeight: 760)
        .onAppear {
            refreshCacheSize()
            Task {
                await peopleViewModel.loadData(rootFolderURL: browserViewModel.selectedFolderURL)
            }
        }
        .confirmationDialog(
            "Clear Disposable Thumbnail Cache?",
            isPresented: $showConfirmClearCache
        ) {
            Button("Clear Cache", role: .destructive) {
                do {
                    try ThumbnailLoader.shared.clearAllCaches()
                    FaceCropLoader.shared.clearCache()
                    refreshCacheSize()
                } catch {
                    // Safe fallback
                    refreshCacheSize()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will purge only temporary downsampled thumbnails from disk to free up space. Original photo files, library index data, face detections, ArcFace embeddings, and confirmed people are NOT deleted or affected. Thumbnails will be regenerated automatically when photos are viewed.")
        }
    }

    private func refreshCacheSize() {
        diskCacheSizeText = DiskThumbnailCache.shared.formattedCacheSize()
    }

    // MARK: - Tab 1: General

    private var generalTab: some View {
        Form {
            Section(header: Text("Browsing & Appearance").font(.headline)) {
                Picker("Photo Sort Order:", selection: $settings.photoSortOrder) {
                    Text("Newest First").tag("dateDescending")
                    Text("Oldest First").tag("dateAscending")
                    Text("Filename").tag("filename")
                }
                .pickerStyle(.menu)

                HStack {
                    Text("Thumbnail Grid Size:")
                    Slider(value: $settings.gridThumbnailSize, in: 120...280, step: 10)
                        .accessibilityLabel("Thumbnail Size Slider")
                    Text("\(Int(settings.gridThumbnailSize)) px")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 45, alignment: .trailing)
                }

                Toggle("Show face bounding boxes by default in photo viewer", isOn: $settings.showFaceOverlaysByDefault)
            }

            Divider()

            Section(header: Text("Library Monitoring").font(.headline)) {
                Toggle("Automatically monitor active library folder for changes", isOn: $settings.autoMonitoringEnabled)
                    .help("When enabled, KeepSake detects newly added, changed, or deleted photos in real time.")

                Text("Keepsake uses macOS kernel file-system events to watch for folder updates with ~0% idle CPU.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Section(header: Text("Developer Tools").font(.headline)) {
                Toggle("Enable Developer Mode", isOn: $settings.developerModeEnabled)
                    .help("Enables access to Face Recognition Lab, Clustering Experiment Lab, and raw embedding telemetry.")

                if settings.developerModeEnabled {
                    LabeledContent("Face Recognition Model", value: "ArcFace ResNet (512-D L2)")
                    LabeledContent("Benchmark Model", value: "Apple Vision FeaturePrint Rev 2 (768-D)")
                    LabeledContent("Clustering Threshold", value: "0.65 Cosine Similarity")
                }
            }
        }
        .padding(16)
    }

    // MARK: - Tab 2: Library & Cache

    private var libraryAndCacheTab: some View {
        Form {
            Section(header: Text("Disposable Thumbnail Cache").font(.headline)) {
                LabeledContent("Current Cache Size:", value: diskCacheSizeText)
                    .font(.body.weight(.medium))

                VStack(alignment: .leading, spacing: 4) {
                    Text("Cache Directory:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(DiskThumbnailCache.shared.directoryURL.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                .padding(.vertical, 4)

                HStack(spacing: 12) {
                    Button("Show in Finder") {
                        DiskThumbnailCache.shared.revealInFinder()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Clear Cache…") {
                        showConfirmClearCache = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Text("Clearing the thumbnail cache safely removes downsampled preview files to reclaim disk space. Original photos and face identities remain untouched.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Section(header: Text("Persistent Library Database").font(.headline)) {
                LabeledContent("Persistent Storage", value: "Application Support/KeepSake/library_index.json")
                LabeledContent("Indexed Embeddings", value: "\(browserViewModel.totalStoredEmbeddings)")
                LabeledContent("Indexed People Profiles", value: "\(browserViewModel.totalStoredGroups)")

                if browserViewModel.failedPhotosCount > 0 {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(browserViewModel.failedPhotosCount) photos failed processing")
                                .font(.subheadline)
                                .foregroundStyle(.red)
                            Text("Retry corrupted or interrupted photos.")
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

            Section(header: Text("Active Folder").font(.headline)) {
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

                        HStack(spacing: 12) {
                            Button("Choose Different Folder…") {
                                browserViewModel.chooseFolder()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button("Rescan Active Folder") {
                                browserViewModel.triggerManualRescan()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                } else {
                    HStack {
                        Text("No active folder selected.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Choose Folder…") {
                            browserViewModel.chooseFolder()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
            }
        }
        .padding(16)
    }

    // MARK: - Tab 3: Recycle Bin

    private var recycleBinTab: some View {
        RecycleBinView(viewModel: peopleViewModel, rootFolderURL: browserViewModel.selectedFolderURL)
    }

    // MARK: - Tab 4: Unassigned Faces

    private var unassignedFacesTab: some View {
        UnassignedFacesView(
            viewModel: peopleViewModel,
            rootFolderURL: browserViewModel.selectedFolderURL,
            onDismiss: {
                selectedTab = 0
            }
        )
    }
}
