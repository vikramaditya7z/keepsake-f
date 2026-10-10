import Foundation
import CoreServices

/// Lifecycle state of the folder monitoring service.
enum MonitoringState: String, Sendable, Equatable {
    case idle
    case monitoring
    case changesDetected
    case reconciling
    case paused
    case unavailable
}

/// Protocol defining the interface for folder change monitoring.
protocol FolderMonitorServiceProtocol: AnyObject, Sendable {
    func startMonitoring(folderURL: URL, onChange: @escaping @Sendable () -> Void) throws
    func stopMonitoring()
    var isMonitoring: Bool { get }
    var monitoredURL: URL? { get }
}

/// Native macOS filesystem monitor leveraging FSEvents to track recursive folder changes with zero polling overhead.
final class FolderMonitorService: FolderMonitorServiceProtocol, @unchecked Sendable {
    private var eventStream: FSEventStreamRef?
    private let monitorQueue = DispatchQueue(label: "com.keepsake.folderMonitor", qos: .utility)
    private var changeHandler: (@Sendable () -> Void)?
    private let lock = NSLock()
    private(set) var monitoredURL: URL?

    init() {}

    deinit {
        stopMonitoring()
    }

    var isMonitoring: Bool {
        lock.lock()
        defer { lock.unlock() }
        return eventStream != nil
    }

    /// Starts monitoring the specified folder URL for recursive filesystem changes.
    func startMonitoring(folderURL: URL, onChange: @escaping @Sendable () -> Void) throws {
        lock.lock()
        defer { lock.unlock() }

        // Stop existing stream if running
        stopMonitoringLocked()

        guard FileManager.default.fileExists(atPath: folderURL.path) else {
            throw NSError(
                domain: "KeepSake.FolderMonitor",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Monitored folder path does not exist: \(folderURL.path)"]
            )
        }

        self.monitoredURL = folderURL
        self.changeHandler = onChange

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let pathsToWatch = [folderURL.standardizedFileURL.path] as CFArray
        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer |
            kFSEventStreamCreateFlagWatchRoot
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            fsEventsCallback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.1, // 100ms FSEvents coalescing latency
            flags
        ) else {
            throw NSError(
                domain: "KeepSake.FolderMonitor",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create FSEventStream for path: \(folderURL.path)"]
            )
        }

        self.eventStream = stream
        FSEventStreamSetDispatchQueue(stream, monitorQueue)
        guard FSEventStreamStart(stream) else {
            stopMonitoringLocked()
            throw NSError(
                domain: "KeepSake.FolderMonitor",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to start FSEventStream"]
            )
        }
    }

    /// Stops the active FSEventStream and cleans up resources.
    func stopMonitoring() {
        lock.lock()
        defer { lock.unlock() }
        stopMonitoringLocked()
    }

    private func stopMonitoringLocked() {
        if let stream = eventStream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.eventStream = nil
        }
        self.monitoredURL = nil
        self.changeHandler = nil
    }

    /// Triggers the change notification (used by FSEvents callback and unit tests).
    func notifyChange() {
        lock.lock()
        let handler = self.changeHandler
        lock.unlock()

        handler?()
    }
}

/// C-style FSEventStream callback forwarding notifications to FolderMonitorService.
private func fsEventsCallback(
    streamRef: ConstFSEventStreamRef,
    clientCallBackInfo: UnsafeMutableRawPointer?,
    numEvents: Int,
    eventPaths: UnsafeMutableRawPointer,
    eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let info = clientCallBackInfo else { return }
    let monitor = Unmanaged<FolderMonitorService>.fromOpaque(info).takeUnretainedValue()
    monitor.notifyChange()
}

/// Actor managing debounced reconciliation execution to coalesce event bursts into a single coordinated scan.
actor DebounceCoordinator {
    private let debounceInterval: TimeInterval
    private var debounceTask: Task<Void, Never>?
    private var isReconciling: Bool = false
    private var nextAction: (@Sendable () async -> Void)?

    init(interval: TimeInterval = 0.5) {
        self.debounceInterval = interval
    }

    /// Signals that a filesystem event occurred. Resets debounce timer and triggers action after quiet window.
    func signalEvent(
        onDebounceStart: (@Sendable () -> Void)? = nil,
        action: @escaping @Sendable () async -> Void
    ) {
        onDebounceStart?()
        debounceTask?.cancel()
        debounceTask = Task { [weak self, debounceInterval] in
            try? await Task.sleep(nanoseconds: UInt64(debounceInterval * 1_000_000_000))
            if !Task.isCancelled {
                await self?.execute(action: action)
            }
        }
    }

    /// Executes an action immediately (e.g. for user-triggered manual rescan), coordinating with any active execution.
    func executeImmediate(action: @escaping @Sendable () async -> Void) async {
        debounceTask?.cancel()
        debounceTask = nil
        await execute(action: action)
    }

    /// Executes reconciliation atomically, ensuring concurrent requests are coalesced.
    private func execute(action: @escaping @Sendable () async -> Void) async {
        if isReconciling {
            nextAction = action
            return
        }

        isReconciling = true
        defer { isReconciling = false }

        await action()

        while let next = nextAction {
            nextAction = nil
            await next()
        }
    }

    /// Cancels any pending debounced tasks.
    func cancel() {
        debounceTask?.cancel()
        debounceTask = nil
        nextAction = nil
    }
}
