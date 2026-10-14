import Foundation
import Combine

/// Lifecycle states of the local ONNX-to-Core ML model conversion pipeline.
public enum ONNXConversionStatus: Equatable, Sendable {
    case idle
    case checking(progress: Double, message: String)
    case preparing(progress: Double, message: String)
    case converting(progress: Double, message: String)
    case saving(progress: Double, message: String)
    case completed(outputURL: URL)
    case failed(reason: String)
    case cancelled

    public var isRunning: Bool {
        switch self {
        case .checking, .preparing, .converting, .saving:
            return true
        default:
            return false
        }
    }

    public var progressValue: Double {
        switch self {
        case .idle: return 0.0
        case .checking(let p, _): return p
        case .preparing(let p, _): return p
        case .converting(let p, _): return p
        case .saving(let p, _): return p
        case .completed: return 1.0
        case .failed, .cancelled: return 0.0
        }
    }

    public var displayMessage: String {
        switch self {
        case .idle: return "Ready to convert"
        case .checking(_, let msg): return msg
        case .preparing(_, let msg): return msg
        case .converting(_, let msg): return msg
        case .saving(_, let msg): return msg
        case .completed: return "Conversion completed successfully"
        case .failed(let reason): return "Conversion failed: \(reason)"
        case .cancelled: return "Conversion was cancelled"
        }
    }
}

/// Errors thrown by the ONNX conversion coordinator.
public enum ONNXConversionError: LocalizedError, Equatable {
    case sourceFileNotFound(URL)
    case invalidONNXFormat(String)
    case converterNotFound
    case conversionProcessFailed(exitCode: Int32, details: String)
    case outputNotFound(URL)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .sourceFileNotFound(let url):
            return "The selected ONNX model file could not be found at: \(url.lastPathComponent)"
        case .invalidONNXFormat(let reason):
            return "Invalid ONNX model: \(reason)"
        case .converterNotFound:
            return "The local ONNX converter helper could not be located in the application bundle or support path."
        case .conversionProcessFailed(let exitCode, let details):
            return "Local conversion failed (code \(exitCode)): \(details)"
        case .outputNotFound(let url):
            return "Converted Core ML package was not produced at: \(url.path)"
        case .cancelled:
            return "Conversion was cancelled by the user."
        }
    }
}

/// Service managing the execution of the local ONNX-to-Core ML converter.
/// Communicates with the standalone `keepsakemodelconverter` executable via structured pipes.
@MainActor
public final class ONNXConversionService: ObservableObject {
    public static let shared = ONNXConversionService()

    @Published public private(set) var status: ONNXConversionStatus = .idle
    @Published public private(set) var progress: Double = 0.0
    @Published public private(set) var currentMessage: String = ""

    private var activeProcess: Process?
    private var isCancelledFlag: Bool = false

    /// Optional test/mock override for the converter executable URL.
    public nonisolated(unsafe) static var converterExecutableOverride: URL?

    public init() {}

    /// Locates the converter executable across app bundle, application support, and workspace locations.
    public nonisolated static func resolveConverterExecutable(bundle: Bundle = .main) -> URL? {
        if let override = converterExecutableOverride, FileManager.default.isExecutableFile(atPath: override.path) {
            return override
        }

        // 1. App Bundle Contents/Helpers
        let bundleHelper = bundle.bundleURL
            .appendingPathComponent("Contents/Helpers/keepsakemodelconverter/keepsakemodelconverter")
        if FileManager.default.isExecutableFile(atPath: bundleHelper.path) {
            return bundleHelper
        }

        // 2. App Bundle Contents/Resources
        if let resURL = bundle.resourceURL {
            let bundleRes = resURL.appendingPathComponent("keepsakemodelconverter/keepsakemodelconverter")
            if FileManager.default.isExecutableFile(atPath: bundleRes.path) {
                return bundleRes
            }
        }

        // 3. Application Support directory
        if let appSupportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let appSupportHelper = appSupportDir
                .appendingPathComponent("KeepSake/Converter/keepsakemodelconverter/keepsakemodelconverter")
            if FileManager.default.isExecutableFile(atPath: appSupportHelper.path) {
                return appSupportHelper
            }
        }

        // 4. Workspace build directory fallback (for development and test execution)
        let devPath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Services
            .deletingLastPathComponent() // KeepSake
            .appendingPathComponent("build/converter/keepsakemodelconverter/keepsakemodelconverter")
        if FileManager.default.isExecutableFile(atPath: devPath.path) {
            return devPath
        }

        // 5. Temporary test distribution path
        let tmpDist = URL(fileURLWithPath: "/tmp/keepsake-onnx2coreml-test/dist/keepsakemodelconverter/keepsakemodelconverter")
        if FileManager.default.isExecutableFile(atPath: tmpDist.path) {
            return tmpDist
        }

        return nil
    }

    /// Converts a user-provided Buffalo S ONNX model into a Core ML `.mlpackage`.
    public func convertBuffaloSONNX(
        from sourceURL: URL,
        onProgress: ((ONNXConversionStatus) -> Void)? = nil
    ) async throws -> URL {
        let isAccessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if isAccessing {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            let error = ONNXConversionError.sourceFileNotFound(sourceURL)
            updateStatus(.failed(reason: error.localizedDescription), callback: onProgress)
            throw error
        }

        // Verify valid ONNX extension
        guard sourceURL.pathExtension.lowercased() == "onnx" else {
            let error = ONNXConversionError.invalidONNXFormat("Expected a .onnx file, but found: .\(sourceURL.pathExtension)")
            updateStatus(.failed(reason: error.localizedDescription), callback: onProgress)
            throw error
        }

        guard let executableURL = Self.resolveConverterExecutable() else {
            let error = ONNXConversionError.converterNotFound
            updateStatus(.failed(reason: error.localizedDescription), callback: onProgress)
            throw error
        }

        isCancelledFlag = false
        updateStatus(.checking(progress: 0.1, message: "Validating ONNX model..."), callback: onProgress)

        let uniqueId = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("ONNXConversion_\(uniqueId)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let targetMLPackageURL = tempDir.appendingPathComponent("buffalo_s_converted.mlpackage")

        let process = Process()
        process.executableURL = executableURL
        process.arguments = [sourceURL.path, targetMLPackageURL.path]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        self.activeProcess = process

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                // Read stdout lines asynchronously for structured JSON progress
                stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                    let data = handle.availableData
                    guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }

                    let lines = text.components(separatedBy: .newlines)
                    for line in lines {
                        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard trimmed.hasPrefix("{") && trimmed.hasSuffix("}") else { continue }
                        guard let lineData = trimmed.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                              let statusStr = json["status"] as? String else {
                            continue
                        }

                        let progressVal = (json["progress"] as? Double) ?? 0.0
                        let message = (json["message"] as? String) ?? ""

                        Task { @MainActor [weak self] in
                            guard let self = self, !self.isCancelledFlag else { return }
                            switch statusStr {
                            case "checking":
                                self.updateStatus(.checking(progress: progressVal, message: message), callback: onProgress)
                            case "preparing":
                                self.updateStatus(.preparing(progress: progressVal, message: message), callback: onProgress)
                            case "converting":
                                self.updateStatus(.converting(progress: progressVal, message: message), callback: onProgress)
                            case "saving":
                                self.updateStatus(.saving(progress: progressVal, message: message), callback: onProgress)
                            case "completed":
                                self.updateStatus(.saving(progress: 0.95, message: "Finalizing package..."), callback: onProgress)
                            case "error":
                                self.updateStatus(.failed(reason: message), callback: onProgress)
                            default:
                                break
                            }
                        }
                    }
                }

                process.terminationHandler = { [weak self] proc in
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil

                    Task { @MainActor [weak self] in
                        guard let self = self else { return }
                        self.activeProcess = nil

                        if self.isCancelledFlag {
                            self.updateStatus(.cancelled, callback: onProgress)
                            try? FileManager.default.removeItem(at: tempDir)
                            continuation.resume(throwing: ONNXConversionError.cancelled)
                            return
                        }

                        if proc.terminationStatus == 0 {
                            if FileManager.default.fileExists(atPath: targetMLPackageURL.path) {
                                self.updateStatus(.completed(outputURL: targetMLPackageURL), callback: onProgress)
                                continuation.resume(returning: targetMLPackageURL)
                            } else {
                                let err = ONNXConversionError.outputNotFound(targetMLPackageURL)
                                self.updateStatus(.failed(reason: err.localizedDescription), callback: onProgress)
                                continuation.resume(throwing: err)
                            }
                        } else {
                            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                            let errStr = String(data: errData, encoding: .utf8) ?? "Unknown error"
                            let failMsg = self.currentMessage.isEmpty ? errStr : self.currentMessage
                            let err = ONNXConversionError.conversionProcessFailed(exitCode: proc.terminationStatus, details: failMsg)
                            self.updateStatus(.failed(reason: err.localizedDescription), callback: onProgress)
                            continuation.resume(throwing: err)
                        }
                    }
                }

                do {
                    try process.run()
                } catch {
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    self.activeProcess = nil
                    self.updateStatus(.failed(reason: error.localizedDescription), callback: onProgress)
                    continuation.resume(throwing: error)
                }
            }
        }, onCancel: {
            Task { @MainActor in
                self.cancel()
            }
        })
    }

    /// Cancels any in-flight conversion process immediately.
    public func cancel() {
        guard let process = activeProcess, process.isRunning else { return }
        isCancelledFlag = true
        process.terminate()
        activeProcess = nil
        updateStatus(.cancelled, callback: nil)
    }

    private func updateStatus(_ newStatus: ONNXConversionStatus, callback: ((ONNXConversionStatus) -> Void)?) {
        self.status = newStatus
        self.progress = newStatus.progressValue
        self.currentMessage = newStatus.displayMessage
        callback?(newStatus)
    }
}
