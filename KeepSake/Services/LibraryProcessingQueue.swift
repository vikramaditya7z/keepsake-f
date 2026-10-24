import Foundation
import CoreGraphics

/// Represents the overall execution state of the background processing queue.
enum QueueExecutionState: String, Sendable, Equatable {
    case idle
    case processing
    case paused
    case completed
    case cancelled
}

/// Real-time progress snapshot of the background processing queue.
struct QueueProgressMetrics: Sendable, Equatable {
    var state: QueueExecutionState
    var totalCount: Int
    var completedCount: Int
    var failedCount: Int
    var remainingCount: Int
    var currentFilename: String?
    var totalFacesDetected: Int
    var totalEmbeddingsGenerated: Int
    var throughputPhotosPerSec: Double
    var elapsedSeconds: Double

    init(
        state: QueueExecutionState = .idle,
        totalCount: Int = 0,
        completedCount: Int = 0,
        failedCount: Int = 0,
        remainingCount: Int = 0,
        currentFilename: String? = nil,
        totalFacesDetected: Int = 0,
        totalEmbeddingsGenerated: Int = 0,
        throughputPhotosPerSec: Double = 0.0,
        elapsedSeconds: Double = 0.0
    ) {
        self.state = state
        self.totalCount = totalCount
        self.completedCount = completedCount
        self.failedCount = failedCount
        self.remainingCount = remainingCount
        self.currentFilename = currentFilename
        self.totalFacesDetected = totalFacesDetected
        self.totalEmbeddingsGenerated = totalEmbeddingsGenerated
        self.throughputPhotosPerSec = throughputPhotosPerSec
        self.elapsedSeconds = elapsedSeconds
    }

    var progressFraction: Double {
        guard totalCount > 0 else { return 0.0 }
        return Double(completedCount + failedCount) / Double(totalCount)
    }
}

/// Actor managing the bounded-concurrency background processing queue.
actor LibraryProcessingQueue {
    private(set) var state: QueueExecutionState = .idle
    private var pendingItems: [PhotoRecord] = []
    private var inflightItemIds: Set<UUID> = []
    private var totalInBatch: Int = 0
    private var completedInBatch: Int = 0
    private var failedInBatch: Int = 0
    private var totalFacesInBatch: Int = 0
    private var totalEmbeddingsInBatch: Int = 0
    private var currentItemName: String?
    private var startTime: Date?
    private var pausedTime: Date?
    private var accumulatedElapsedSeconds: Double = 0.0

    private let maxConcurrentWorkers: Int
    private var activeWorkerTasks: [Task<Void, Never>] = []
    private var pauseContinuations: [CheckedContinuation<Void, Never>] = []
    private var progressListener: (@Sendable (QueueProgressMetrics) -> Void)?

    init(maxConcurrentWorkers: Int? = nil) {
        if let workers = maxConcurrentWorkers {
            self.maxConcurrentWorkers = max(1, workers)
        } else {
            let coreCount = ProcessInfo.processInfo.activeProcessorCount
            // Bounded pool: default min 2, max 4 workers to balance CPU/Neural Engine without UI lag
            self.maxConcurrentWorkers = min(max(coreCount / 2, 2), 4)
        }
    }

    /// Sets the progress listener callback.
    func setProgressListener(_ listener: (@Sendable (QueueProgressMetrics) -> Void)?) {
        self.progressListener = listener
    }

    /// Returns current progress metrics.
    func getMetrics() -> QueueProgressMetrics {
        let elapsed = calculateElapsedTime()
        let processedTotal = completedInBatch + failedInBatch
        let throughput = elapsed > 0 ? Double(processedTotal) / elapsed : 0.0

        return QueueProgressMetrics(
            state: state,
            totalCount: totalInBatch,
            completedCount: completedInBatch,
            failedCount: failedInBatch,
            remainingCount: pendingItems.count + inflightItemIds.count,
            currentFilename: currentItemName,
            totalFacesDetected: totalFacesInBatch,
            totalEmbeddingsGenerated: totalEmbeddingsInBatch,
            throughputPhotosPerSec: throughput,
            elapsedSeconds: elapsed
        )
    }

    private func notifyProgress() {
        let metrics = getMetrics()
        progressListener?(metrics)
    }

    private func calculateElapsedTime() -> Double {
        guard let start = startTime else { return accumulatedElapsedSeconds }
        if state == .paused {
            return accumulatedElapsedSeconds
        }
        return accumulatedElapsedSeconds + Date().timeIntervalSince(start)
    }

    /// Starts or resumes processing the given items using the provided processor closure.
    func enqueueAndStart(
        items: [PhotoRecord],
        rootFolderURL: URL,
        processor: @escaping @Sendable (PhotoRecord, URL) async -> Result<(facesCount: Int, embeddingsCount: Int), Error>,
        onBatchComplete: (@Sendable () async -> Void)? = nil
    ) {
        guard !items.isEmpty else {
            self.state = .completed
            notifyProgress()
            return
        }

        self.pendingItems = items
        self.inflightItemIds.removeAll()
        self.totalInBatch = items.count
        self.completedInBatch = 0
        self.failedInBatch = 0
        self.totalFacesInBatch = 0
        self.totalEmbeddingsInBatch = 0
        self.accumulatedElapsedSeconds = 0
        self.startTime = Date()
        self.state = .processing

        notifyProgress()
        spawnWorkers(rootFolderURL: rootFolderURL, processor: processor, onBatchComplete: onBatchComplete)
    }

    /// Spawns worker tasks up to the concurrency limit.
    private func spawnWorkers(
        rootFolderURL: URL,
        processor: @escaping @Sendable (PhotoRecord, URL) async -> Result<(facesCount: Int, embeddingsCount: Int), Error>,
        onBatchComplete: (@Sendable () async -> Void)?
    ) {
        for _ in 0..<maxConcurrentWorkers {
            let task = Task { [weak self] in
                guard let self = self else { return }
                await self.workerLoop(rootFolderURL: rootFolderURL, processor: processor, onBatchComplete: onBatchComplete)
            }
            activeWorkerTasks.append(task)
        }
    }

    /// Worker loop that continuously dequeues and processes items until queue is drained or cancelled.
    private func workerLoop(
        rootFolderURL: URL,
        processor: @escaping @Sendable (PhotoRecord, URL) async -> Result<(facesCount: Int, embeddingsCount: Int), Error>,
        onBatchComplete: (@Sendable () async -> Void)?
    ) async {
        while true {
            // Check for pause state
            if self.state == .paused {
                await withCheckedContinuation { continuation in
                    self.pauseContinuations.append(continuation)
                }
            }

            // Check for cancellation
            if self.state == .cancelled || Task.isCancelled {
                break
            }

            // Dequeue next item
            guard let item = self.dequeueNextItem() else {
                // No more items in pending queue
                break
            }

            self.currentItemName = item.filename
            self.notifyProgress()

            // Process photo independently
            let result = await processor(item, rootFolderURL)

            // Check state again after processing
            if self.state == .cancelled {
                self.inflightItemIds.remove(item.id)
                break
            }

            switch result {
            case .success(let (facesCount, embeddingsCount)):
                self.completedInBatch += 1
                self.totalFacesInBatch += facesCount
                self.totalEmbeddingsInBatch += embeddingsCount
            case .failure:
                self.failedInBatch += 1
            }

            self.inflightItemIds.remove(item.id)
            self.notifyProgress()
        }

        // Check if all workers finished and queue is empty
        if self.pendingItems.isEmpty && self.inflightItemIds.isEmpty && self.state == .processing {
            if let onComplete = onBatchComplete {
                await onComplete()
            }
            self.state = .completed
            self.currentItemName = nil
            self.notifyProgress()
        }
    }

    private func dequeueNextItem() -> PhotoRecord? {
        guard !pendingItems.isEmpty else { return nil }
        let item = pendingItems.removeFirst()
        inflightItemIds.insert(item.id)
        return item
    }

    /// Dynamically enqueues additional items to the queue.
    /// If the queue is actively processing or paused, the items are appended to pending queue without cancelling workers.
    /// If the queue is idle/completed/cancelled, a new batch is initiated.
    func enqueueAdditional(
        items: [PhotoRecord],
        rootFolderURL: URL,
        processor: @escaping @Sendable (PhotoRecord, URL) async -> Result<(facesCount: Int, embeddingsCount: Int), Error>,
        onBatchComplete: (@Sendable () async -> Void)? = nil
    ) {
        guard !items.isEmpty else { return }

        // Deduplicate against already pending or in-flight items
        let existingIds = Set(pendingItems.map(\.id)).union(inflightItemIds)
        let uniqueItems = items.filter { !existingIds.contains($0.id) }
        guard !uniqueItems.isEmpty else { return }

        if state == .processing || state == .paused {
            pendingItems.append(contentsOf: uniqueItems)
            totalInBatch += uniqueItems.count
            notifyProgress()
        } else {
            enqueueAndStart(items: uniqueItems, rootFolderURL: rootFolderURL, processor: processor, onBatchComplete: onBatchComplete)
        }
    }

    /// Pauses taking new work items from the queue. In-flight items complete cleanly.
    func pause() {
        guard state == .processing else { return }
        state = .paused
        if let start = startTime {
            accumulatedElapsedSeconds += Date().timeIntervalSince(start)
            startTime = nil
        }
        notifyProgress()
    }

    /// Resumes processing queued items.
    func resume() {
        guard state == .paused else { return }
        state = .processing
        startTime = Date()

        let continuations = self.pauseContinuations
        self.pauseContinuations.removeAll()
        for cont in continuations {
            cont.resume()
        }
        notifyProgress()
    }

    /// Cancels active processing and clears pending items.
    func cancel() {
        guard state == .processing || state == .paused else { return }
        state = .cancelled
        pendingItems.removeAll()
        for task in activeWorkerTasks {
            task.cancel()
        }
        activeWorkerTasks.removeAll()

        let continuations = self.pauseContinuations
        self.pauseContinuations.removeAll()
        for cont in continuations {
            cont.resume()
        }
        notifyProgress()
    }

    /// Cancels active processing, clears pending items, and cooperatively awaits completion of all active worker tasks.
    func cancelAndAwait() async {
        guard state == .processing || state == .paused else { return }
        state = .cancelled
        pendingItems.removeAll()
        let tasks = activeWorkerTasks
        activeWorkerTasks.removeAll()
        for task in tasks {
            task.cancel()
        }

        let continuations = self.pauseContinuations
        self.pauseContinuations.removeAll()
        for cont in continuations {
            cont.resume()
        }

        for task in tasks {
            _ = await task.result
        }
        notifyProgress()
    }

    /// Resets the queue state to idle.
    func reset() {
        cancel()
        state = .idle
        pendingItems.removeAll()
        inflightItemIds.removeAll()
        totalInBatch = 0
        completedInBatch = 0
        failedInBatch = 0
        totalFacesInBatch = 0
        totalEmbeddingsInBatch = 0
        currentItemName = nil
        startTime = nil
        accumulatedElapsedSeconds = 0
        notifyProgress()
    }
}
