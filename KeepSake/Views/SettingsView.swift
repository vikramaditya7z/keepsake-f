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
    @ObservedObject var modelManager = ModelManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var diskCacheSizeText: String = "Calculating…"
    @State private var showConfirmClearCache: Bool = false
    @State private var showConfirmClearModel: Bool = false
    @State private var showConfirmDeleteDatabase: Bool = false
    @State private var showModelInstructions: Bool = false
    @State private var showOnboardingGuide: Bool = false
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

                modelManagementTab
                    .tabItem {
                        Label("Model", systemImage: "cpu")
                    }
                    .tag(4)
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
        .confirmationDialog(
            "Clear Active Face Recognition Model?",
            isPresented: $showConfirmClearModel
        ) {
            Button("Clear Model", role: .destructive) {
                modelManager.clearModel()
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete Library Database?",
            isPresented: $showConfirmDeleteDatabase
        ) {
            Button("Delete Library Database", role: .destructive) {
                Task {
                    await browserViewModel.deleteLibraryDatabase(peopleViewModel: peopleViewModel)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently remove all indexed photo records, detected faces, embeddings, and saved people from KeepSake. Your original photo files and installed recognition models will NOT be deleted. The library must be indexed again.")
        }
        .sheet(isPresented: $showModelInstructions) {
            ModelInstructionsSheet()
        }
        .sheet(isPresented: $showOnboardingGuide) {
            ModelSetupSheet(
                selectedFolderURL: browserViewModel.selectedFolderURL,
                onChooseFolder: {
                    browserViewModel.chooseFolder()
                },
                onSetupCompleted: {
                    showOnboardingGuide = false
                }
            )
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

            Section(header: Text("First-Launch Setup Guide").font(.headline)) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Onboarding & Setup Guide")
                            .font(.subheadline)
                        Text("Reopen the first-launch setup guide to select a photo folder or configure face recognition.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open Setup Guide…") {
                        showOnboardingGuide = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
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

                if browserViewModel.selectedFolderURL != nil {
                    LabeledContent("Active Folder Photos", value: "\(browserViewModel.totalIndexedPhotos)")
                    LabeledContent("Active Folder Faces", value: "\(browserViewModel.totalDetectedFaces)")
                    LabeledContent("Active Folder Embeddings", value: "\(browserViewModel.activeFolderEmbeddingsCount)")
                }

                LabeledContent("Total Stored Photos", value: "\(browserViewModel.totalStoredPhotos)")
                LabeledContent("Total Stored Embeddings", value: "\(browserViewModel.totalStoredEmbeddings)")
                LabeledContent("Indexed People Profiles", value: "\(browserViewModel.totalStoredGroups)")

                if browserViewModel.failedPhotosCount > 0 {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(browserViewModel.failedPhotosCount) photos failed processing")
                                .font(.subheadline)
                                .foregroundStyle(.red)
                            Text("Retry corrupted or interrupted photos in active folder.")
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

                VStack(alignment: .leading, spacing: 6) {
                    Button("Delete Library Database…") {
                        showConfirmDeleteDatabase = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Text("Remove all indexed photo records, detected faces, embeddings, and saved people from KeepSake. Your original photos and installed recognition models will not be deleted. The library must be indexed again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
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

    // MARK: - Tab 5: Model Management

    private var modelManagementTab: some View {
        Form {
            Section(header: Text("Face Recognition Model Status").font(.headline)) {
                HStack(spacing: 12) {
                    statusIcon(for: modelManager.status)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(modelManager.status.displayText)
                            .font(.headline)
                        Text(statusSubtitle(for: modelManager.status))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if modelManager.isValidating {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .padding(.vertical, 4)

                if case .ready(let name, let format, let url) = modelManager.status {
                    LabeledContent("Active Model", value: name)
                    LabeledContent("Format", value: format)
                    LabeledContent("Architecture", value: "ArcFace / MobileFaceNet (512-D)")
                    LabeledContent("Tensor Resolution", value: "112×112 RGB Planar")
                    if let date = modelManager.installedDate {
                        LabeledContent("Installed Date", value: date.formatted(date: .abbreviated, time: .shortened))
                    }

                    LabeledContent("Model Source", value: modelManager.modelSource.displayText)

                    if case .userInstalled = modelManager.modelSource {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Storage Location:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(url.path)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                        .padding(.vertical, 2)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Development / Test Location:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(url.path)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                            Text("Note: This model is loaded from your development environment. It is not stored in user application support.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        .padding(.vertical, 2)
                    }
                }

                if case .error(let message) = modelManager.status {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    .padding(.vertical, 4)
                }

                if !modelManager.isModelReady {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("KeepSake is currently running in deterministic fallback mode (Legacy Synthetic 2D-DCT). Face clustering operates with lower discrimination until a compatible Core ML model is installed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }

            Divider()

            if modelManager.status.isConverting {
                Section(header: Text("Model Conversion Progress").font(.headline)) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(modelManager.conversionMessage.isEmpty ? "Processing..." : modelManager.conversionMessage)
                                .font(.subheadline)
                            Spacer()
                            Text("\(Int(modelManager.conversionProgress * 100))%")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }

                        ProgressView(value: modelManager.conversionProgress, total: 1.0)
                            .progressViewStyle(.linear)

                        Button("Cancel Conversion") {
                            modelManager.cancelConversion()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .padding(.top, 4)
                    }
                    .padding(.vertical, 4)
                }
                Divider()
            }

            Section(header: Text("Model Management Controls").font(.headline)) {
                HStack(spacing: 12) {
                    Button(modelManager.hasUserInstalledModel ? "Replace with ONNX…" : "Choose ONNX Model…") {
                        modelManager.chooseONNXModel()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(modelManager.isValidating || modelManager.status.isConverting)

                    Button("Import Core ML…") {
                        modelManager.chooseModel()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(modelManager.isValidating || modelManager.status.isConverting)

                    if modelManager.isModelReady {
                        Button("Validate & Reload") {
                            Task {
                                await modelManager.reloadActiveModel()
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(modelManager.isValidating || modelManager.status.isConverting)

                        Button("Clear Model…") {
                            showConfirmClearModel = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(modelManager.isValidating || modelManager.status.isConverting)
                    }

                    Spacer()

                    Button("Setup Guide…") {
                        showOnboardingGuide = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Model Instructions…") {
                        showModelInstructions = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.vertical, 4)

                Text("Choose your Buffalo S ONNX model (w600k_mbf.onnx). KeepSake converts it locally on your Mac into a native Core ML package without requiring external tools.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Section(header: Text("Embedding Compatibility Notice").font(.headline)) {
                Text("Each face embedding generated during photo scanning permanently records the active model name and version. If you switch models, existing confirmed people, names, and photo associations are kept completely intact. Newly scanned photos will be assigned embeddings using the new model.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private func statusIcon(for status: ModelStatus) -> some View {
        switch status {
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.green)
        case .notInstalled, .fallbackActive:
            Image(systemName: "info.circle.fill")
                .font(.title2)
                .foregroundStyle(.orange)
        case .validating, .loading, .selected, .converting:
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .font(.title2)
                .foregroundStyle(.blue)
        case .error:
            Image(systemName: "exclamationmark.octagon.fill")
                .font(.title2)
                .foregroundStyle(.red)
        }
    }

    private func statusSubtitle(for status: ModelStatus) -> String {
        switch status {
        case .ready(let name, _, _):
            if case .developmentBundle = modelManager.modelSource {
                return "Development Bundle (Not User-Installed): \(name)"
            }
            return "Active and validated: \(name)"
        case .notInstalled:
            return "No external model configured. Running in Fallback Mode."
        case .selected:
            return "Artifact chosen; running validation checks."
        case .converting(_, let message):
            return message.isEmpty ? "Converting ONNX model to Core ML..." : message
        case .validating:
            return "Checking model inputs, output dimensions, and inference stability."
        case .loading:
            return "Initializing neural network into memory."
        case .error:
            return "Model validation or initialization failed."
        case .fallbackActive:
            return "Deterministic spatial fallback is actively handling recognition."
        }
    }
}
