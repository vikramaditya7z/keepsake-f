import SwiftUI

enum AppNavigationSection: String, CaseIterable, Identifiable {
    case photos = "Photos"
    case people = "People"

    var id: String { rawValue }
}

struct ContentView: View {
    @ObservedObject var viewModel: PhotoBrowserViewModel
    @StateObject private var peopleViewModel = PeopleViewModel()
    @ObservedObject private var settings = AppSettings.shared

    @State private var selectedSection: AppNavigationSection = .photos
    @State private var showClusteringLab: Bool = false

    init(viewModel: PhotoBrowserViewModel? = nil) {
        self.viewModel = viewModel ?? PhotoBrowserViewModel()
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header Bar
            headerBar

            // Continuous Monitoring & Library Status Strip (Phases 7 & 8)
            if viewModel.selectedFolderURL != nil {
                libraryProcessingStatusBar
            }

            Divider()

            // Main Content Area
            ZStack {
                if viewModel.selectedFolderURL == nil {
                    WelcomeView(
                        onChooseFolder: {
                            viewModel.chooseFolder()
                        },
                        onDropFolderURL: { url in
                            viewModel.openFolderDirectly(url: url)
                        }
                    )
                } else if selectedSection == .people {
                    PeopleGalleryView(
                        viewModel: peopleViewModel,
                        rootFolderURL: viewModel.selectedFolderURL,
                        onOpenClusteringLab: {
                            showClusteringLab = true
                        }
                    )
                } else if viewModel.photos.isEmpty && viewModel.isScanning {
                    scanningView
                } else if viewModel.photos.isEmpty && !viewModel.isScanning {
                    emptyFolderView
                } else {
                    PhotoGridView(photos: viewModel.sortedPhotos) { photo in
                        viewModel.selectPhoto(photo)
                    }
                }

                // Modal Photo Detail Viewer (Photos tab)
                if selectedSection == .photos, let selectedPhoto = viewModel.selectedPhoto {
                    PhotoDetailView(
                        photo: selectedPhoto,
                        onDismiss: {
                            viewModel.clearSelection()
                        },
                        onPrevious: {
                            viewModel.selectPreviousPhoto()
                        },
                        onNext: {
                            viewModel.selectNextPhoto()
                        },
                        hasPrevious: viewModel.hasPreviousPhoto,
                        hasNext: viewModel.hasNextPhoto
                    )
                    .transition(.opacity)
                }
            }
        }
        .frame(minWidth: 720, minHeight: 520)
        .sheet(isPresented: $showClusteringLab, onDismiss: {
            Task {
                await peopleViewModel.loadData(rootFolderURL: viewModel.selectedFolderURL)
            }
        }) {
            FaceClusteringExperimentView(
                photos: viewModel.photos,
                onDismiss: {
                    showClusteringLab = false
                }
            )
        }
        .onAppear {
            viewModel.onProcessingCompleted = {
                Task { @MainActor in
                    await peopleViewModel.loadData(rootFolderURL: viewModel.selectedFolderURL)
                }
            }
        }
        .onChange(of: selectedSection) { _, newSection in
            if newSection == .people {
                Task {
                    await peopleViewModel.loadData(rootFolderURL: viewModel.selectedFolderURL)
                }
            }
        }
        .onChange(of: viewModel.selectedFolderURL) { _, newURL in
            Task {
                await peopleViewModel.loadData(rootFolderURL: newURL)
            }
        }
        .alert(isPresented: $viewModel.showErrorAlert) {
            if let userError = viewModel.activeUserError {
                return Alert(
                    title: Text(userError.title),
                    message: Text(userError.fullFormattedDescription),
                    dismissButton: .default(Text("OK"))
                )
            } else {
                return Alert(
                    title: Text("Error"),
                    message: Text(viewModel.errorMessage ?? "An unknown error occurred."),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(spacing: 12) {
            if let folderURL = viewModel.selectedFolderURL {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.tint)
                    .font(.title3)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(folderURL.lastPathComponent)
                        .font(.headline)
                        .lineLimit(1)

                    Text(folderURL.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .help(folderURL.path)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Selected folder: \(folderURL.lastPathComponent)")

                Spacer()

                // Section Switcher (Photos / People)
                Picker("Section", selection: $selectedSection) {
                    Label("Photos", systemImage: "photo.stack").tag(AppNavigationSection.photos)
                    Label("People", systemImage: "person.2.fill").tag(AppNavigationSection.people)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                .accessibilityLabel("Navigation section")

                Spacer()

                if viewModel.isScanning || viewModel.isReconciling {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(viewModel.isScanning ? "Scanning… (\(viewModel.scannedCount))" : "Syncing…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Library scanning in progress")
                } else {
                    Text("\(viewModel.photos.count) \(viewModel.photos.count == 1 ? "photo" : "photos")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                // Sort Options Menu
                Menu {
                    Button(action: { settings.photoSortOrder = "dateDescending" }) {
                        Label("Newest First", systemImage: settings.photoSortOrder == "dateDescending" ? "checkmark" : "")
                    }
                    Button(action: { settings.photoSortOrder = "dateAscending" }) {
                        Label("Oldest First", systemImage: settings.photoSortOrder == "dateAscending" ? "checkmark" : "")
                    }
                    Button(action: { settings.photoSortOrder = "filename" }) {
                        Label("Filename", systemImage: settings.photoSortOrder == "filename" ? "checkmark" : "")
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
                .help("Sort photos")
                .accessibilityLabel("Sort photos menu")

                // Clustering Lab button (Developer Mode only)
                if settings.developerModeEnabled && !viewModel.photos.isEmpty {
                    Button(action: {
                        showClusteringLab = true
                    }) {
                        Label("Clustering Lab", systemImage: "person.3.sequence.fill")
                    }
                    .buttonStyle(.bordered)
                    .tint(.indigo)
                    .help("Open Face Clustering Experiment Lab (Developer)")
                }

                Button(action: {
                    viewModel.triggerManualRescan()
                }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .keyboardShortcut("r", modifiers: .command)
                .help("Rescan library now (⌘R)")
                .accessibilityLabel("Rescan library")

                Button(action: {
                    viewModel.chooseFolder()
                }) {
                    Label("Choose Folder…", systemImage: "folder.badge.plus")
                }
                .keyboardShortcut("o", modifiers: .command)
                .accessibilityLabel("Choose another folder")
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "photo.stack.fill")
                        .foregroundStyle(.tint)
                    Text("Keepsake")
                        .font(.headline)
                }

                Spacer()

                Button(action: {
                    viewModel.chooseFolder()
                }) {
                    Label("Choose Folder…", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("o", modifiers: .command)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Monitoring & Library Status Bar (Phases 7, 8 & 9)

    private var libraryProcessingStatusBar: some View {
        VStack(spacing: 4) {
            HStack(spacing: 12) {
                // Continuous Monitoring Indicator
                monitoringIndicator

                Divider()
                    .frame(height: 10)

                // Background Queue Status & Controls
                if viewModel.queueMetrics.state == .processing {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("Indexing:")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundStyle(.blue)

                        let completed = viewModel.queueMetrics.completedCount + viewModel.queueMetrics.failedCount
                        let total = viewModel.queueMetrics.totalCount
                        Text("\(completed)/\(total)")
                            .font(.caption2)
                            .monospacedDigit()

                        if let currentName = viewModel.queueMetrics.currentFilename {
                            Text("• \(currentName)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: 140, alignment: .leading)
                        }

                        // Developer Mode Extended Metric
                        if settings.developerModeEnabled && viewModel.queueMetrics.throughputPhotosPerSec > 0 {
                            Text(String(format: "(%.1f/s)", viewModel.queueMetrics.throughputPhotosPerSec))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }

                        Button(action: { viewModel.pauseProcessing() }) {
                            Image(systemName: "pause.fill")
                                .font(.caption2)
                        }
                        .buttonStyle(.borderless)
                        .help("Pause indexing")
                        .accessibilityLabel("Pause indexing")

                        Button(action: { viewModel.cancelProcessing() }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Cancel indexing")
                        .accessibilityLabel("Cancel indexing")
                    }
                } else if viewModel.queueMetrics.state == .paused {
                    HStack(spacing: 6) {
                        Image(systemName: "pause.circle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption2)
                        Text("Paused (\(viewModel.queueMetrics.completedCount)/\(viewModel.queueMetrics.totalCount))")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundStyle(.orange)

                        Button(action: { viewModel.resumeProcessing() }) {
                            Image(systemName: "play.fill")
                                .font(.caption2)
                        }
                        .buttonStyle(.borderless)
                        .help("Resume indexing")
                        .accessibilityLabel("Resume indexing")

                        Button(action: { viewModel.cancelProcessing() }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Cancel indexing")
                        .accessibilityLabel("Cancel indexing")
                    }
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "photo.stack")
                            .foregroundStyle(.secondary)
                            .font(.caption2)
                        Text("\(viewModel.photos.count) \(viewModel.photos.count == 1 ? "photo" : "photos")")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("•")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text("\(viewModel.totalStoredGroups) \(viewModel.totalStoredGroups == 1 ? "person" : "people")")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                // Failures & Diagnostics
                HStack(spacing: 8) {
                    if viewModel.failedPhotosCount > 0 {
                        HStack(spacing: 4) {
                            Text("\(viewModel.failedPhotosCount) failed")
                                .font(.caption2)
                                .foregroundStyle(.red)

                            if !viewModel.isBackgroundProcessingActive {
                                Button(action: { viewModel.retryFailedPhotos() }) {
                                    Text("Retry")
                                        .font(.caption2)
                                        .underline()
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.red)
                                .accessibilityLabel("Retry failed photo indexing")
                            }
                        }
                    }

                    // Developer Diagnostics
                    if settings.developerModeEnabled {
                        Divider()
                            .frame(height: 10)

                        Label("\(viewModel.totalDetectedFaces) faces", systemImage: "face.smiling")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        Label("\(viewModel.totalStoredEmbeddings) embeddings", systemImage: "bolt.fill")
                            .font(.caption2)
                            .foregroundStyle(.purple)
                    }
                }
            }

            // Linear Progress Bar during active background processing
            if viewModel.isBackgroundProcessingActive {
                ProgressView(value: viewModel.queueMetrics.progressFraction)
                    .progressViewStyle(.linear)
                    .controlSize(.mini)
                    .tint(.blue)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
    }

    private var monitoringIndicator: some View {
        HStack(spacing: 5) {
            switch viewModel.monitoringState {
            case .monitoring:
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
                Text("Monitoring")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            case .changesDetected:
                Circle()
                    .fill(Color.orange)
                    .frame(width: 6, height: 6)
                Text("Changes detected…")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            case .reconciling:
                ProgressView()
                    .controlSize(.mini)
                Text("Syncing…")
                    .font(.caption2)
                    .foregroundStyle(.blue)
            case .paused:
                Circle()
                    .fill(Color.yellow)
                    .frame(width: 6, height: 6)
                Text("Paused")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            case .unavailable:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.red)
                Text("Unavailable")
                    .font(.caption2)
                    .foregroundStyle(.red)
            case .idle:
                EmptyView()
            }
        }
        .accessibilityLabel("Folder monitoring status: \(viewModel.monitoringState.rawValue)")
    }

    // MARK: - Scanning View

    private var scanningView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)

            Text("Scanning folder for photos…")
                .font(.headline)

            Text("Discovered \(viewModel.scannedCount) photos so far")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty Folder View

    private var emptyFolderView: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text("No photos found in this folder.")
                .font(.headline)

            Text("Supported formats: JPG, PNG, HEIC, HEIF, WEBP")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button(action: {
                viewModel.chooseFolder()
            }) {
                Label("Choose Another Folder…", systemImage: "folder")
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
