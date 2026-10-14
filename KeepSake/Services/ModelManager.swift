import Foundation
import CoreML
import AppKit
import UniformTypeIdentifiers

/// Represents the operational state of the face recognition model in KeepSake.
public enum ModelStatus: Equatable {
    /// No user-provided or external recognition model is installed.
    case notInstalled
    /// An artifact was chosen but compatibility validation is pending.
    case selected(URL)
    /// An ONNX model is being locally converted into Core ML.
    case converting(progress: Double, message: String)
    /// Compatibility checks and test inference are running.
    case validating
    /// The model is being initialized into memory.
    case loading
    /// The model has passed all checks and is actively loaded by the recognition service.
    case ready(name: String, format: String, url: URL)
    /// Selection, validation, compilation, or loading encountered an error.
    case error(String)
    /// Fallback (e.g. synthetic 2D-DCT) is actively operating because no neural model is loaded.
    case fallbackActive

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    public var isConverting: Bool {
        if case .converting = self { return true }
        return false
    }

    public var displayText: String {
        switch self {
        case .notInstalled: return "Not Installed"
        case .selected: return "Selected"
        case .converting: return "Converting…"
        case .validating: return "Validating…"
        case .loading: return "Loading Model…"
        case .ready: return "Ready"
        case .error: return "Error"
        case .fallbackActive: return "Fallback Active"
        }
    }
}

/// Metadata describing a successfully validated model artifact.
public struct ModelValidationResult: Equatable {
    public let name: String
    public let format: String
    public let inputShape: [Int]
    public let outputDimension: Int
    public let compiledURL: URL
}

/// Structured errors encountered during model validation and installation.
public enum ModelValidationError: LocalizedError, Equatable {
    case fileNotFound(URL)
    case unsupportedFormat(String)
    case compilationFailed(String)
    case initializationFailed(String)
    case invalidInputShape(String)
    case invalidOutputDimension(expected: Int, actual: Int)
    case inferenceTestFailed(String)
    case securityScopedAccessFailed

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let url):
            return "The specified model file was not found at: \(url.lastPathComponent)"
        case .unsupportedFormat(let ext):
            return "Unsupported model format (\(ext)). KeepSake supports Core ML models (.mlmodelc, .mlpackage, or .mlmodel)."
        case .compilationFailed(let reason):
            return "Core ML compilation failed: \(reason)"
        case .initializationFailed(let reason):
            return "Core ML model initialization failed: \(reason)"
        case .invalidInputShape(let shape):
            return "Incompatible model input shape (\(shape)). Model must accept a 112×112 RGB face tensor [1, 3, 112, 112]."
        case .invalidOutputDimension(let expected, let actual):
            return "Incompatible embedding dimension. Expected \(expected)-dimensional vector, but model produced \(actual) dimensions."
        case .inferenceTestFailed(let reason):
            return "Validation inference test failed: \(reason)"
        case .securityScopedAccessFailed:
            return "Failed to establish security-scoped access to the selected model file."
        }
    }
}

/// Describes the origin and storage nature of the active face-recognition model.
public enum ModelSource: Equatable {
    case userInstalled(URL)
    case developmentBundle(URL)
    case none

    public var isUserInstalled: Bool {
        if case .userInstalled = self { return true }
        return false
    }

    public var displayText: String {
        switch self {
        case .userInstalled:
            return "User Installed (Application Support)"
        case .developmentBundle:
            return "Development / Test Bundle"
        case .none:
            return "None (Fallback Mode)"
        }
    }

    public static func == (lhs: ModelSource, rhs: ModelSource) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none):
            return true
        case (.userInstalled(let u1), .userInstalled(let u2)):
            return u1.standardizedFileURL.path == u2.standardizedFileURL.path
        case (.developmentBundle(let u1), .developmentBundle(let u2)):
            return u1.standardizedFileURL.path == u2.standardizedFileURL.path
        default:
            return false
        }
    }
}

/// Central manager coordinating face-recognition model selection, validation, installation,
/// persistence, and integration with `ArcFaceRecognitionService`.
@MainActor
public final class ModelManager: ObservableObject {
    public static let shared = ModelManager()

    @Published public private(set) var status: ModelStatus = .notInstalled
    @Published public private(set) var modelSource: ModelSource = .none
    @Published public private(set) var activeModelURL: URL?
    @Published public private(set) var activeModelName: String?
    @Published public private(set) var activeModelFormat: String?
    @Published public private(set) var installedDate: Date?
    @Published public private(set) var lastErrorMessage: String?
    @Published public private(set) var isValidating: Bool = false
    @Published public private(set) var conversionProgress: Double = 0.0
    @Published public private(set) var conversionMessage: String = ""

    /// Standard Application Support directory where KeepSake manages user-installed models.
    public nonisolated(unsafe) static var managedModelsDirectoryOverride: URL?

    public nonisolated static var managedModelsDirectoryURL: URL {
        if let override = managedModelsDirectoryOverride {
            return override
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("KeepSake/Models", isDirectory: true)
    }

    /// Permanent location of the active managed compiled Core ML model.
    public nonisolated static var managedActiveModelURL: URL {
        managedModelsDirectoryURL.appendingPathComponent("active_model.mlmodelc")
    }

    public var isModelReady: Bool {
        status.isReady
    }

    /// Indicates whether a valid model has been installed by the user into managed storage.
    public var hasUserInstalledModel: Bool {
        if case .userInstalled = modelSource {
            return status.isReady
        }
        return false
    }

    public init() {
        loadInitialState()
    }

    /// Loads the initial model state on application launch.
    public func loadInitialState() {
        let managedURL = Self.managedActiveModelURL
        if FileManager.default.fileExists(atPath: managedURL.path) {
            // Attempt to load and validate the user-installed managed model
            do {
                let validation = try Self.validateCompiledModel(at: managedURL)
                let savedName = AppSettings.shared.activeModelDisplayName
                let displayName = savedName.isEmpty ? validation.name : savedName
                let savedFormat = AppSettings.shared.activeModelFormat
                let format = savedFormat.isEmpty ? validation.format : savedFormat

                if AppSettings.shared.activeModelInstalledDate > 0 {
                    self.installedDate = Date(timeIntervalSince1970: AppSettings.shared.activeModelInstalledDate)
                } else {
                    self.installedDate = Date()
                }

                self.activeModelURL = managedURL
                self.activeModelName = displayName
                self.activeModelFormat = format
                self.modelSource = .userInstalled(managedURL)
                self.status = .ready(name: displayName, format: format, url: managedURL)
                self.lastErrorMessage = nil

                // Register with ArcFaceRecognitionService
                ArcFaceRecognitionService.setExternalModel(url: managedURL, name: displayName)
                print("[ModelManager] Successfully restored user-installed model: \(displayName) from \(managedURL.path)")
            } catch {
                print("[ModelManager] Failed to restore managed model: \(error.localizedDescription)")
                self.status = .error("Installed model failed to load: \(error.localizedDescription)")
                self.lastErrorMessage = error.localizedDescription
                self.modelSource = .none
                self.activeModelURL = nil
                self.activeModelName = nil
                self.activeModelFormat = nil
                ArcFaceRecognitionService.setExternalModel(url: nil, name: nil)
            }
        } else {
            // Check if ArcFaceRecognitionService has a bundled model (e.g. in development/tests)
            if let bundleModelURL = ArcFaceRecognitionService.findCompiledModelURL(),
               FileManager.default.fileExists(atPath: bundleModelURL.path) {
                let displayName = "InsightFace buffalo_s (512-D MobileFaceNet)"
                let format = "Core ML Compiled (.mlmodelc)"
                self.activeModelURL = bundleModelURL
                self.activeModelName = displayName
                self.activeModelFormat = format
                self.installedDate = nil
                self.modelSource = .developmentBundle(bundleModelURL)
                self.status = .ready(name: displayName, format: format, url: bundleModelURL)
                self.lastErrorMessage = nil
                ArcFaceRecognitionService.setExternalModel(url: bundleModelURL, name: displayName)
            } else {
                self.status = .notInstalled
                self.modelSource = .none
                self.activeModelURL = nil
                self.activeModelName = nil
                self.activeModelFormat = nil
                self.installedDate = nil
                self.lastErrorMessage = nil
                ArcFaceRecognitionService.setExternalModel(url: nil, name: nil)
            }
        }
    }

    /// Opens the native macOS file picker specifically for choosing a Buffalo S ONNX model file.
    public func chooseONNXModel(presentingWindow: NSWindow? = nil) {
        let panel = NSOpenPanel()
        panel.title = "Select Buffalo S ONNX Model"
        panel.message = "Choose your Buffalo S recognition model (w600k_mbf.onnx). KeepSake will convert and install it locally."
        panel.prompt = "Convert & Install"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        let allowedTypes: [UTType] = [
            UTType(filenameExtension: "onnx") ?? .data
        ]
        panel.allowedContentTypes = allowedTypes

        let response: NSApplication.ModalResponse = panel.runModal()

        guard response == .OK, let selectedURL = panel.url else {
            return
        }

        Task {
            do {
                try await convertAndInstallONNXModel(from: selectedURL)
            } catch {
                print("[ModelManager] ONNX conversion and installation failed: \(error.localizedDescription)")
            }
        }
    }

    /// Opens the native macOS file picker to allow the user to select an ONNX or Core ML model.
    public func chooseModel(presentingWindow: NSWindow? = nil) {
        let panel = NSOpenPanel()
        panel.title = "Select Face Recognition Model"
        panel.message = "Choose an ONNX model (w600k_mbf.onnx) or compatible Core ML model (.mlpackage, .mlmodelc, .mlmodel)"
        panel.prompt = "Choose Model"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true // .mlmodelc and .mlpackage are packages/directories
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        let allowedTypes: [UTType] = [
            UTType(filenameExtension: "onnx") ?? .data,
            UTType(filenameExtension: "mlpackage") ?? .package,
            UTType(filenameExtension: "mlmodelc") ?? .package,
            UTType(filenameExtension: "mlmodel") ?? .data
        ]
        panel.allowedContentTypes = allowedTypes

        let response: NSApplication.ModalResponse = panel.runModal()

        guard response == .OK, let selectedURL = panel.url else {
            // User cancelled; preserve existing state completely
            return
        }

        Task {
            do {
                if selectedURL.pathExtension.lowercased() == "onnx" {
                    try await convertAndInstallONNXModel(from: selectedURL)
                } else {
                    try await installModel(from: selectedURL)
                }
            } catch {
                print("[ModelManager] Model installation failed: \(error.localizedDescription)")
            }
        }
    }

    /// Converts a user-provided ONNX model locally into Core ML, validates it, and activates it.
    public func convertAndInstallONNXModel(from sourceURL: URL) async throws {
        let isAccessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if isAccessing {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let previousStatus = status
        let previousURL = activeModelURL
        let previousName = activeModelName
        let previousFormat = activeModelFormat
        let previousDate = installedDate
        let previousSource = modelSource

        isValidating = true
        lastErrorMessage = nil
        conversionProgress = 0.05
        conversionMessage = "Validating ONNX model..."
        status = .converting(progress: 0.05, message: "Validating ONNX model...")

        do {
            let conversionService = ONNXConversionService.shared
            let convertedPackageURL = try await conversionService.convertBuffaloSONNX(from: sourceURL) { [weak self] convStatus in
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    switch convStatus {
                    case .checking(let p, let msg),
                         .preparing(let p, let msg),
                         .converting(let p, let msg),
                         .saving(let p, let msg):
                        self.conversionProgress = p
                        self.conversionMessage = msg
                        self.status = .converting(progress: p, message: msg)
                    default:
                        break
                    }
                }
            }

            self.status = .validating
            self.conversionMessage = "Validating converted Core ML package..."
            let validation = try await Task.detached(priority: .userInitiated) {
                try Self.validateModelSynchronous(at: convertedPackageURL)
            }.value

            // Stage installation atomically in Application Support
            let targetDirectory = Self.managedModelsDirectoryURL
            try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)

            let stagingURL = targetDirectory.appendingPathComponent("staging_model.mlmodelc")
            if FileManager.default.fileExists(atPath: stagingURL.path) {
                try FileManager.default.removeItem(at: stagingURL)
            }

            // Copy compiled model to staging location
            try FileManager.default.copyItem(at: validation.compiledURL, to: stagingURL)

            // Test loading from staged location to verify integrity
            _ = try Self.validateCompiledModel(at: stagingURL)

            // Atomically swap into permanent managed path
            let activeURL = Self.managedActiveModelURL
            if FileManager.default.fileExists(atPath: activeURL.path) {
                try FileManager.default.removeItem(at: activeURL)
            }
            try FileManager.default.moveItem(at: stagingURL, to: activeURL)

            // Cleanup temporary conversion files
            let parentDir = convertedPackageURL.deletingLastPathComponent()
            if parentDir.path.contains("ONNXConversion_") {
                try? FileManager.default.removeItem(at: parentDir)
            }

            let displayName = "Buffalo S MobileFaceNet (Converted ONNX)"
            let formatName = "Core ML Package (.mlpackage)"
            let now = Date()

            AppSettings.shared.activeModelDisplayName = displayName
            AppSettings.shared.activeModelFormat = formatName
            AppSettings.shared.activeModelInstalledDate = now.timeIntervalSince1970
            AppSettings.shared.hasCompletedModelSetup = true

            ArcFaceRecognitionService.setExternalModel(url: activeURL, name: displayName)

            self.activeModelURL = activeURL
            self.activeModelName = displayName
            self.activeModelFormat = formatName
            self.installedDate = now
            self.modelSource = .userInstalled(activeURL)
            self.status = .ready(name: displayName, format: formatName, url: activeURL)
            self.isValidating = false
            self.lastErrorMessage = nil
            self.conversionProgress = 1.0
            self.conversionMessage = "Ready"

            print("[ModelManager] Successfully converted and installed Buffalo S model.")
        } catch {
            self.isValidating = false
            self.lastErrorMessage = error.localizedDescription
            self.conversionProgress = 0.0

            if case .ready(let name, let format, let url) = previousStatus {
                self.status = .ready(name: name, format: format, url: url)
                self.activeModelURL = previousURL
                self.activeModelName = previousName
                self.activeModelFormat = previousFormat
                self.installedDate = previousDate
                self.modelSource = previousSource
                ArcFaceRecognitionService.setExternalModel(url: url, name: name)
            } else {
                self.status = .error(error.localizedDescription)
                self.modelSource = .none
                ArcFaceRecognitionService.setExternalModel(url: nil, name: nil)
            }

            throw error
        }
    }

    /// Cancels any in-flight conversion process.
    public func cancelConversion() {
        ONNXConversionService.shared.cancel()
    }

    /// Validates and installs a model from an external URL into the application support directory.
    public func installModel(from sourceURL: URL) async throws {
        let isAccessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if isAccessing {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let previousStatus = status
        let previousURL = activeModelURL
        let previousName = activeModelName
        let previousFormat = activeModelFormat
        let previousDate = installedDate
        let previousSource = modelSource

        isValidating = true
        status = .validating
        lastErrorMessage = nil

        do {
            let validation = try await Task.detached(priority: .userInitiated) {
                try Self.validateModelSynchronous(at: sourceURL)
            }.value

            // Stage installation atomically in Application Support
            let targetDirectory = Self.managedModelsDirectoryURL
            try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)

            let stagingURL = targetDirectory.appendingPathComponent("staging_model.mlmodelc")
            if FileManager.default.fileExists(atPath: stagingURL.path) {
                try FileManager.default.removeItem(at: stagingURL)
            }

            // Copy compiled model to staging location
            try FileManager.default.copyItem(at: validation.compiledURL, to: stagingURL)

            // Test loading from staged location to verify integrity
            _ = try Self.validateCompiledModel(at: stagingURL)

            // Atomically swap into permanent managed path
            let activeURL = Self.managedActiveModelURL
            if FileManager.default.fileExists(atPath: activeURL.path) {
                try FileManager.default.removeItem(at: activeURL)
            }
            try FileManager.default.moveItem(at: stagingURL, to: activeURL)

            // If source was a temporary compilation from .mlpackage / .mlmodel, clean it up safely
            let tempPath = FileManager.default.temporaryDirectory.path
            let nsTempPath = NSTemporaryDirectory()
            if validation.compiledURL != sourceURL && (validation.compiledURL.path.hasPrefix(tempPath) || validation.compiledURL.path.hasPrefix(nsTempPath)) {
                try? FileManager.default.removeItem(at: validation.compiledURL)
            }

            // Persist model metadata in user settings
            let now = Date()
            AppSettings.shared.activeModelDisplayName = validation.name
            AppSettings.shared.activeModelFormat = validation.format
            AppSettings.shared.activeModelInstalledDate = now.timeIntervalSince1970
            AppSettings.shared.hasCompletedModelSetup = true

            // Register with recognition engine
            ArcFaceRecognitionService.setExternalModel(url: activeURL, name: validation.name)

            self.activeModelURL = activeURL
            self.activeModelName = validation.name
            self.activeModelFormat = validation.format
            self.installedDate = now
            self.modelSource = .userInstalled(activeURL)
            self.status = .ready(name: validation.name, format: validation.format, url: activeURL)
            self.isValidating = false
            self.lastErrorMessage = nil

            print("[ModelManager] Successfully installed and activated model: \(validation.name)")
        } catch {
            self.isValidating = false
            self.lastErrorMessage = error.localizedDescription

            // If a previous model was functioning, safely keep it active
            if case .ready(let name, let format, let url) = previousStatus {
                self.status = .ready(name: name, format: format, url: url)
                self.activeModelURL = previousURL
                self.activeModelName = previousName
                self.activeModelFormat = previousFormat
                self.installedDate = previousDate
                self.modelSource = previousSource
                ArcFaceRecognitionService.setExternalModel(url: url, name: name)
            } else {
                self.status = .error(error.localizedDescription)
                self.modelSource = .none
                ArcFaceRecognitionService.setExternalModel(url: nil, name: nil)
            }

            throw error
        }
    }

    /// Clears the currently installed model without touching user photos or library indexes.
    public func clearModel() {
        let activeURL = Self.managedActiveModelURL
        if FileManager.default.fileExists(atPath: activeURL.path) {
            try? FileManager.default.removeItem(at: activeURL)
        }

        AppSettings.shared.activeModelDisplayName = ""
        AppSettings.shared.activeModelFormat = ""
        AppSettings.shared.activeModelInstalledDate = 0.0

        ArcFaceRecognitionService.setExternalModel(url: nil, name: nil)

        self.activeModelURL = nil
        self.activeModelName = nil
        self.activeModelFormat = nil
        self.installedDate = nil
        self.status = .notInstalled
        self.modelSource = .none
        self.lastErrorMessage = nil
        print("[ModelManager] Active model cleared.")
    }

    /// Re-validates the currently configured model.
    public func reloadActiveModel() async {
        guard let url = activeModelURL else {
            status = .notInstalled
            modelSource = .none
            return
        }

        isValidating = true
        status = .validating

        do {
            let validation = try await Task.detached(priority: .userInitiated) {
                try Self.validateModelSynchronous(at: url)
            }.value

            ArcFaceRecognitionService.setExternalModel(url: url, name: validation.name)
            self.status = .ready(name: validation.name, format: validation.format, url: url)
            self.isValidating = false
            self.lastErrorMessage = nil
        } catch {
            self.status = .error(error.localizedDescription)
            self.modelSource = .none
            self.isValidating = false
            self.lastErrorMessage = error.localizedDescription
            ArcFaceRecognitionService.setExternalModel(url: nil, name: nil)
        }
    }

    // MARK: - Validation Logic

    /// Synchronous validation pipeline executed on background thread.
    public nonisolated static func validateModelSynchronous(at sourceURL: URL) throws -> ModelValidationResult {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw ModelValidationError.fileNotFound(sourceURL)
        }

        let ext = sourceURL.pathExtension.lowercased()
        let compiledURL: URL
        let formatString: String

        if ext == "mlmodelc" {
            compiledURL = sourceURL
            formatString = "Core ML Compiled (.mlmodelc)"
        } else if ext == "mlpackage" || ext == "mlmodel" {
            do {
                compiledURL = try MLModel.compileModel(at: sourceURL)
                formatString = ext == "mlpackage" ? "Core ML Package (.mlpackage)" : "Core ML Model (.mlmodel)"
            } catch {
                throw ModelValidationError.compilationFailed(error.localizedDescription)
            }
        } else {
            throw ModelValidationError.unsupportedFormat(ext.isEmpty ? "Directory/No Extension" : ext)
        }

        let validation = try validateCompiledModel(at: compiledURL, originalFormat: formatString)
        return validation
    }

    /// Validates an already-compiled .mlmodelc directory.
    public nonisolated static func validateCompiledModel(at compiledURL: URL, originalFormat: String? = nil) throws -> ModelValidationResult {
        guard FileManager.default.fileExists(atPath: compiledURL.path) else {
            throw ModelValidationError.fileNotFound(compiledURL)
        }

        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndGPU

        let model: MLModel
        do {
            model = try MLModel(contentsOf: compiledURL, configuration: config)
        } catch {
            throw ModelValidationError.initializationFailed(error.localizedDescription)
        }

        let desc = model.modelDescription

        // 1. Validate Input feature
        // ArcFace requires a 112x112 RGB planar tensor: [1, 3, 112, 112] or [3, 112, 112]
        var foundValidInput = false
        var detectedInputShape: [Int] = []

        if let inputDesc = desc.inputDescriptionsByName["input"] ?? desc.inputDescriptionsByName.values.first(where: { $0.type == .multiArray }),
           let constraint = inputDesc.multiArrayConstraint {
            let shape = constraint.shape.map { $0.intValue }
            detectedInputShape = shape

            // Check if shape is [1, 3, 112, 112] or [3, 112, 112]
            if shape == [1, 3, 112, 112] || shape == [3, 112, 112] {
                foundValidInput = true
            }
        }

        guard foundValidInput else {
            let shapeDesc = detectedInputShape.isEmpty ? "Unknown" : detectedInputShape.description
            throw ModelValidationError.invalidInputShape(shapeDesc)
        }

        // 2. Validate Output feature
        // ArcFace requires a 512-D float embedding
        var foundValidOutput = false
        var detectedOutputDim = 0

        if let outputDesc = desc.outputDescriptionsByName["embedding"] ?? desc.outputDescriptionsByName.values.first(where: { $0.type == .multiArray }),
           let constraint = outputDesc.multiArrayConstraint {
            let shape = constraint.shape.map { $0.intValue }
            let totalElements = shape.reduce(1, *)
            detectedOutputDim = totalElements

            if totalElements == 512 {
                foundValidOutput = true
            }
        }

        guard foundValidOutput else {
            throw ModelValidationError.invalidOutputDimension(expected: 512, actual: detectedOutputDim)
        }

        // 3. Smoke Test Inference
        let dummyTensor = [Float](repeating: 0.1, count: 3 * 112 * 112)
        do {
            guard let result = try ArcFaceRecognitionService.runCoreMLInference(model: model, inputTensor: dummyTensor) else {
                throw ModelValidationError.inferenceTestFailed("Inference returned null or degenerate vector")
            }
            guard result.count == 512 else {
                throw ModelValidationError.invalidOutputDimension(expected: 512, actual: result.count)
            }
        } catch {
            throw ModelValidationError.inferenceTestFailed(error.localizedDescription)
        }

        let baseName = compiledURL.deletingPathExtension().lastPathComponent
        let displayName = baseName.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .capitalized

        return ModelValidationResult(
            name: displayName.isEmpty ? "Face Recognition Model" : displayName,
            format: originalFormat ?? "Core ML Compiled (.mlmodelc)",
            inputShape: detectedInputShape,
            outputDimension: 512,
            compiledURL: compiledURL
        )
    }
}
