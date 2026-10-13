import SwiftUI
import AppKit

@MainActor
final class PhotoBrowserViewModel: ObservableObject {
    @Published var selectedFolderURL: URL?
    @Published var photos: [PhotoItem] = []
    @Published var isScanning: Bool = false
    @Published var scannedCount: Int = 0
    @Published var selectedPhoto: PhotoItem?
    @Published var errorMessage: String?
    @Published var showErrorAlert: Bool = false
    @Published var activeUserError: UserFacingError?

    // Library Index & Status
    @Published var libraryMetadata: LibraryMetadataRecord?
    @Published var totalIndexedPhotos: Int = 0
    @Published var newPhotosCount: Int = 0
    @Published var changedPhotosCount: Int = 0
    @Published var processedPhotosCount: Int = 0
    @Published var failedPhotosCount: Int = 0
    @Published var totalDetectedFaces: Int = 0
    @Published var totalStoredEmbeddings: Int = 0
    @Published var totalStoredGroups: Int = 0
    @Published var activeFolderPeopleCount: Int = 0
    @Published var isRestoringBookmark: Bool = false

    // Background Processing Queue State
    @Published var queueMetrics: QueueProgressMetrics = QueueProgressMetrics()
    @Published var isBackgroundProcessingActive: Bool = false

    // Continuous Filesystem Monitoring State (Phase 8)
    @Published var monitoringState: MonitoringState = .idle
    @Published var isReconciling: Bool = false

    private var scanTask: Task<Void, Never>?
    private(set) var activeFolderGeneration: UInt64 = 0
    private let scanner = PhotoScannerService()
    let libraryStore: LibraryStore
    let coordinator: LibraryProcessingCoordinator
    private let bookmarkManager = BookmarkManager.shared
    private let folderMonitor: FolderMonitorServiceProtocol
    private let debouncer = DebounceCoordinator(interval: 0.5)

    /// Callback invoked when background queue finishes processing and clustering face identities.
    var onProcessingCompleted: (() -> Void)?

    var sortedPhotos: [PhotoItem] {
        let order = AppSettings.shared.photoSortOrder
        switch order {
        case "dateAscending":
            return photos.sorted { ($0.dateModified ?? .distantPast) < ($1.dateModified ?? .distantPast) }
        case "filename":
            return photos.sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
        default: // "dateDescending"
            return photos.sorted { ($0.dateModified ?? .distantPast) > ($1.dateModified ?? .distantPast) }
        }
    }

    init(
        folderMonitor: FolderMonitorServiceProtocol = FolderMonitorService(),
        coordinator: LibraryProcessingCoordinator? = nil,
        libraryStore: LibraryStore = LibraryStore.shared
    ) {
        self.libraryStore = libraryStore
        self.coordinator = coordinator ?? LibraryProcessingCoordinator(libraryStore: libraryStore)
        self.folderMonitor = folderMonitor

        Task { [weak self] in
            guard let self = self else { return }
            // Register queue listener
            await self.coordinator.queue.setProgressListener { [weak self] metrics in
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    guard self.selectedFolderURL != nil else { return }
                    self.queueMetrics = metrics
                    self.isBackgroundProcessingActive = (metrics.state == .processing || metrics.state == .paused)
                    if metrics.state == .completed || metrics.state == .cancelled {
                        await self.refreshLibraryStats()
                        if metrics.state == .completed {
                            self.onProcessingCompleted?()
                        }
                    }
                }
            }

            // Recover any interrupted processing on startup without automatically restoring or scanning old folders
            _ = try? await self.coordinator.recoverInterruptedProcessing()
        }
    }

    deinit {
        folderMonitor.stopMonitoring()
    }

    var folderDisplayName: String {
        guard let url = selectedFolderURL else { return "" }
        return url.lastPathComponent
    }

    var folderPath: String {
        guard let url = selectedFolderURL else { return "" }
        return url.path
    }

    // MARK: - Folder Persistence & Restoration

    /// Attempts to restore the previously selected folder using a stored security-scoped bookmark.
    /// Note: Not called automatically on fresh launch so that startup begins with no active folder selected.
    func restorePersistedFolder() async {
        isRestoringBookmark = true
        defer { isRestoringBookmark = false }

        guard let meta = await libraryStore.getMetadata() else {
            return
        }
        self.libraryMetadata = meta

        guard let bookmarkData = meta.folderBookmarkData else {
            return
        }

        do {
            let (url, isStale) = try bookmarkManager.resolveBookmark(from: bookmarkData)
            let hasAccess = bookmarkManager.startAccessing(url: url)

            guard hasAccess else {
                print("Could not obtain security-scoped access to restored folder: \(url.path)")
                self.monitoringState = .unavailable
                return
            }

            if isStale {
                // Refresh stale bookmark data
                if let refreshed = try? bookmarkManager.createBookmark(for: url) {
                    var updatedMeta = meta
                    updatedMeta.folderBookmarkData = refreshed
                    updatedMeta.updatedAt = Date()
                    try? await libraryStore.saveMetadata(updatedMeta)
                    self.libraryMetadata = updatedMeta
                }
            }

            self.selectedFolderURL = url
            startMonitoring(folderURL: url)
            startScanning(folderURL: url)
        } catch {
            print("Failed to restore folder bookmark: \(error.localizedDescription)")
            self.monitoringState = .unavailable
        }
    }

    /// Clears the active folder selection and invalidates all folder-scoped visible state.
    func clearActiveFolder() {
        activeFolderGeneration &+= 1
        scanTask?.cancel()
        scanTask = nil
        if let oldURL = selectedFolderURL {
            folderMonitor.stopMonitoring()
            bookmarkManager.stopAccessing(url: oldURL)
        }
        selectedFolderURL = nil
        selectedPhoto = nil
        photos = []
        scannedCount = 0
        isScanning = false
        isReconciling = false
        isBackgroundProcessingActive = false
        monitoringState = .idle
        totalIndexedPhotos = 0
        newPhotosCount = 0
        changedPhotosCount = 0
        processedPhotosCount = 0
        failedPhotosCount = 0
        totalDetectedFaces = 0
        Task { [weak self] in
            await self?.coordinator.queue.cancel()
        }
    }

    /// Opens the native macOS folder selection dialog and persists the bookmark.
    func chooseFolder() {
        let openPanel = NSOpenPanel()
        openPanel.title = "Choose Photo Folder"
        openPanel.prompt = "Choose Folder"
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.canCreateDirectories = false
        openPanel.resolvesAliases = true

        if openPanel.runModal() == .OK, let url = openPanel.url {
            openFolderDirectly(url: url)
        }
    }

    /// Directly opens and indexes a directory (e.g. from drag & drop or bookmarks).
    func openFolderDirectly(url: URL) {
        // Stop previous security scoped access & monitor
        if let oldURL = selectedFolderURL {
            folderMonitor.stopMonitoring()
            bookmarkManager.stopAccessing(url: oldURL)
        }

        // Invalidate previous folder state immediately
        selectedPhoto = nil
        photos = []
        scannedCount = 0
        totalIndexedPhotos = 0
        newPhotosCount = 0
        changedPhotosCount = 0
        processedPhotosCount = 0
        failedPhotosCount = 0
        totalDetectedFaces = 0

        // Start new access and create persistent bookmark
        _ = bookmarkManager.startAccessing(url: url)

        let bookmarkData = try? bookmarkManager.createBookmark(for: url)
        let metadata = LibraryMetadataRecord(
            folderBookmarkData: bookmarkData,
            folderPath: url.path,
            folderName: url.lastPathComponent,
            lastScanDate: Date()
        )

        Task {
            try? await libraryStore.saveMetadata(metadata)
            self.libraryMetadata = metadata
        }

        self.selectedFolderURL = url
        if AppSettings.shared.autoMonitoringEnabled {
            startMonitoring(folderURL: url)
        }
        startScanning(folderURL: url)
    }

    // MARK: - Continuous Folder Monitoring (Phase 8)

    /// Starts active filesystem monitoring on the selected root folder with debounced change reconciliation.
    func startMonitoring(folderURL: URL) {
        folderMonitor.stopMonitoring()

        do {
            try folderMonitor.startMonitoring(folderURL: folderURL) { [weak self] in
                Task { @MainActor [weak self] in
                    self?.handleFilesystemChangeNotification()
                }
            }
            self.monitoringState = .monitoring
        } catch {
            print("Failed to start filesystem monitor for \(folderURL.path): \(error.localizedDescription)")
            self.monitoringState = .unavailable
        }
    }

    /// Handles change signal from FSEvents by setting status and queueing debounced reconciliation.
    private func handleFilesystemChangeNotification() {
        guard let folderURL = selectedFolderURL else { return }
        self.monitoringState = .changesDetected

        Task { [weak self] in
            guard let self = self else { return }
            await self.debouncer.signalEvent(
                onDebounceStart: { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.monitoringState = .changesDetected
                    }
                },
                action: { [weak self] in
                    await self?.reconcileMonitoredFolder(folderURL: folderURL)
                }
            )
        }
    }

    /// Reconciles filesystem state against persistent library index and appends new work to processing queue.
    func reconcileMonitoredFolder(folderURL: URL) async {
        let generation = self.activeFolderGeneration
        let targetFolderPath = folderURL.standardizedFileURL.path
        guard self.selectedFolderURL?.standardizedFileURL.path == targetFolderPath else {
            return
        }
        guard FileManager.default.fileExists(atPath: folderURL.path) else {
            self.monitoringState = .unavailable
            return
        }

        self.monitoringState = .reconciling
        self.isReconciling = true
        defer {
            if self.activeFolderGeneration == generation {
                self.isReconciling = false
                self.monitoringState = folderMonitor.isMonitoring ? .monitoring : .idle
            }
        }

        do {
            // 1. Scan filesystem photos
            var accumulated: [PhotoItem] = []
            for try await batch in scanner.scanStream(at: folderURL) {
                guard !Task.isCancelled,
                      self.activeFolderGeneration == generation,
                      self.selectedFolderURL?.standardizedFileURL.path == targetFolderPath else {
                    return
                }
                accumulated.append(contentsOf: batch)
            }
            guard !Task.isCancelled,
                  self.activeFolderGeneration == generation,
                  self.selectedFolderURL?.standardizedFileURL.path == targetFolderPath else {
                return
            }
            self.photos = accumulated
            self.scannedCount = accumulated.count

            // 2. Reconcile with LibraryStore
            let reconciliation = try await self.libraryStore.reconcile(
                scannedPhotos: accumulated,
                rootFolderURL: folderURL
            )

            guard !Task.isCancelled,
                  self.activeFolderGeneration == generation,
                  self.selectedFolderURL?.standardizedFileURL.path == targetFolderPath else {
                return
            }

            await self.refreshLibraryStats(reconciliation: reconciliation)

            // 3. Dynamically enqueue new / changed photos into existing processing pipeline
            let pendingPhotos = reconciliation.newPhotos + reconciliation.changedPhotos
            if !pendingPhotos.isEmpty {
                await self.coordinator.enqueueBackgroundPhotos(
                    photos: pendingPhotos,
                    rootFolderURL: folderURL,
                    clusteringThreshold: 0.54
                )
            } else if !reconciliation.removedPhotos.isEmpty || !accumulated.isEmpty {
                // If there are no pending photos, ensure clustering is fresh using current calibrated thresholds
                try? await self.coordinator.reclusterLibrary(rootFolderURL: folderURL, threshold: 0.54)
                guard !Task.isCancelled,
                      self.activeFolderGeneration == generation,
                      self.selectedFolderURL?.standardizedFileURL.path == targetFolderPath else {
                    return
                }
                await self.refreshLibraryStats()
                self.onProcessingCompleted?()
            }
        } catch {
            print("Reconciliation failed: \(error.localizedDescription)")
        }
    }

    /// User-triggered manual rescan of the selected folder.
    func triggerManualRescan() {
        guard let folderURL = selectedFolderURL else { return }
        Task { [weak self] in
            guard let self = self else { return }
            await self.debouncer.executeImmediate { [weak self] in
                await self?.reconcileMonitoredFolder(folderURL: folderURL)
            }
        }
    }

    /// Explicitly rebuilds all people identities from active faces and embeddings.
    func rebuildIdentities() async {
        guard let folderURL = selectedFolderURL else { return }
        let generation = self.activeFolderGeneration
        self.isReconciling = true
        defer {
            if self.activeFolderGeneration == generation {
                self.isReconciling = false
            }
        }
        try? await self.coordinator.rebuildAllIdentities(rootFolderURL: folderURL, threshold: 0.54)
        guard self.activeFolderGeneration == generation else { return }
        await self.refreshLibraryStats()
        self.onProcessingCompleted?()
    }

    /// Starts initial scanning of the specified folder and kicks off background processing.
    func startScanning(folderURL: URL) {
        activeFolderGeneration &+= 1
        let generation = activeFolderGeneration
        let targetFolderPath = folderURL.standardizedFileURL.path

        scanTask?.cancel()

        selectedFolderURL = folderURL
        selectedPhoto = nil
        photos = []
        scannedCount = 0
        isScanning = true
        errorMessage = nil

        let stream = scanner.scanStream(at: folderURL)

        scanTask = Task { [weak self] in
            guard let self = self else { return }
            // Cancel any in-flight background queue work from a previous folder
            await self.coordinator.queue.cancel()

            guard !Task.isCancelled,
                  self.activeFolderGeneration == generation,
                  self.selectedFolderURL?.standardizedFileURL.path == targetFolderPath else {
                return
            }

            do {
                var accumulated: [PhotoItem] = []
                for try await batch in stream {
                    guard !Task.isCancelled,
                          self.activeFolderGeneration == generation,
                          self.selectedFolderURL?.standardizedFileURL.path == targetFolderPath else {
                        return
                    }
                    accumulated.append(contentsOf: batch)
                    self.photos = accumulated
                    self.scannedCount = accumulated.count
                }

                guard !Task.isCancelled,
                      self.activeFolderGeneration == generation,
                      self.selectedFolderURL?.standardizedFileURL.path == targetFolderPath else {
                    return
                }

                // Reconcile with local library store
                let reconciliation = try await self.libraryStore.reconcile(
                    scannedPhotos: accumulated,
                    rootFolderURL: folderURL
                )

                guard !Task.isCancelled,
                      self.activeFolderGeneration == generation,
                      self.selectedFolderURL?.standardizedFileURL.path == targetFolderPath else {
                    return
                }

                await self.refreshLibraryStats(reconciliation: reconciliation)

                // Auto-start background processing for new/changed photos
                let pendingPhotos = reconciliation.newPhotos + reconciliation.changedPhotos
                if !pendingPhotos.isEmpty {
                    await self.coordinator.startBackgroundProcessing(
                        photos: pendingPhotos,
                        rootFolderURL: folderURL,
                        clusteringThreshold: 0.54
                    )
                } else {
                    // All photos already scanned (or folder is empty); ensure library groups are fresh for this folder
                    if !accumulated.isEmpty {
                        try? await self.coordinator.reclusterLibrary(rootFolderURL: folderURL, threshold: 0.54)
                    }
                    guard !Task.isCancelled,
                          self.activeFolderGeneration == generation,
                          self.selectedFolderURL?.standardizedFileURL.path == targetFolderPath else {
                        return
                    }
                    await self.refreshLibraryStats()
                    self.onProcessingCompleted?()
                }

                if self.activeFolderGeneration == generation {
                    self.isScanning = false
                }
            } catch {
                if !Task.isCancelled, self.activeFolderGeneration == generation {
                    self.isScanning = false
                    self.errorMessage = "Failed to scan folder: \(error.localizedDescription)"
                    self.showErrorAlert = true
                }
            }
        }
    }

    /// Updates observable library statistics from the persistent store, scoped to the active folder when selected.
    func refreshLibraryStats(reconciliation: LibraryReconciliationResult? = nil) async {
        let allEmbeddings = await libraryStore.getEmbeddings()
        let allGroups = await libraryStore.getGroups()
        let metadata = await libraryStore.getMetadata()

        self.libraryMetadata = metadata
        self.totalStoredEmbeddings = allEmbeddings.count
        self.totalStoredGroups = allGroups.count

        guard let activeFolderURL = selectedFolderURL else {
            self.totalIndexedPhotos = 0
            self.processedPhotosCount = 0
            self.failedPhotosCount = 0
            self.totalDetectedFaces = 0
            self.newPhotosCount = 0
            self.changedPhotosCount = 0
            self.activeFolderPeopleCount = 0
            return
        }

        let targetRoot = activeFolderURL.standardizedFileURL.path
        let allPhotos = await libraryStore.getAllPhotos()
        let folderPhotos = allPhotos.filter { photo in
            guard let root = photo.rootFolderPath else { return true }
            return URL(fileURLWithPath: root).standardizedFileURL.path == targetRoot
        }
        let folderPhotoIds = Set(folderPhotos.map { $0.id })
        let allFaces = await libraryStore.getAllFaces()
        let folderFaces = allFaces.filter { folderPhotoIds.contains($0.photoId) }

        self.totalIndexedPhotos = folderPhotos.count
        self.processedPhotosCount = folderPhotos.filter { $0.processingState == .processed }.count
        self.failedPhotosCount = folderPhotos.filter { $0.processingState == .failed }.count
        self.totalDetectedFaces = folderFaces.count

        let folderFaceIds = Set(folderFaces.map { $0.id })
        let confirmedPeople = await libraryStore.getAllPeople().filter { !$0.isDeactivated }
        self.activeFolderPeopleCount = confirmedPeople.filter { person in
            person.confirmedFaceIds.contains { folderFaceIds.contains($0) }
        }.count

        if let rec = reconciliation {
            self.newPhotosCount = rec.newPhotos.count
            self.changedPhotosCount = rec.changedPhotos.count
        } else {
            self.newPhotosCount = folderPhotos.filter { $0.processingState == .discovered }.count
            self.changedPhotosCount = folderPhotos.filter { $0.processingState == .needsReprocessing }.count
        }
    }

    // MARK: - Queue Controls

    func pauseProcessing() {
        Task {
            await coordinator.queue.pause()
        }
    }

    func resumeProcessing() {
        Task {
            await coordinator.queue.resume()
        }
    }

    func cancelProcessing() {
        Task {
            await coordinator.queue.cancel()
        }
    }

    func retryFailedPhotos() {
        guard let folderURL = selectedFolderURL else { return }
        Task {
            let failedPhotos = await libraryStore.getPhotos(byState: .failed)
            for photo in failedPhotos {
                try? await libraryStore.updatePhotoState(id: photo.id, state: .needsReprocessing, failureReason: nil)
            }
            let retryable = await libraryStore.getPhotos(byState: .needsReprocessing)
            if !retryable.isEmpty {
                await coordinator.startBackgroundProcessing(photos: retryable, rootFolderURL: folderURL)
            }
        }
    }

    func cancelScan() {
        activeFolderGeneration &+= 1
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
    }

    func selectPhoto(_ photo: PhotoItem) {
        selectedPhoto = photo
    }

    func clearSelection() {
        selectedPhoto = nil
    }

    func selectNextPhoto() {
        guard let current = selectedPhoto,
              let currentIndex = photos.firstIndex(of: current),
              currentIndex + 1 < photos.count else { return }
        selectedPhoto = photos[currentIndex + 1]
    }

    func selectPreviousPhoto() {
        guard let current = selectedPhoto,
              let currentIndex = photos.firstIndex(of: current),
              currentIndex > 0 else { return }
        selectedPhoto = photos[currentIndex - 1]
    }

    var hasNextPhoto: Bool {
        guard let current = selectedPhoto,
              let currentIndex = photos.firstIndex(of: current) else { return false }
        return currentIndex + 1 < photos.count
    }

    var hasPreviousPhoto: Bool {
        guard let current = selectedPhoto,
              let currentIndex = photos.firstIndex(of: current) else { return false }
        return currentIndex > 0
    }
}
