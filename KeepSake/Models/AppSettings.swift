import SwiftUI
import Combine

/// Central user preferences and application settings for Keepsake.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    /// Detects whether code is executing inside an XCTest runner environment.
    public static let isRunningInTestEnvironment: Bool = {
        return ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ||
               ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil ||
               NSClassFromString("XCTestCase") != nil
    }()

    public static var testStoreOverride: UserDefaults?

    private static let testSuiteStore: UserDefaults? = {
        return UserDefaults(suiteName: "com.keepsake.tests.\(ProcessInfo.processInfo.globallyUniqueString)")
    }()

    public static var activeStore: UserDefaults {
        if let override = testStoreOverride {
            return override
        }
        if isRunningInTestEnvironment, let suite = testSuiteStore {
            return suite
        }
        return .standard
    }

    // MARK: - General & Library Settings

    /// Controls whether developer & experimental features (Clustering Lab, Recognition Lab, internal metrics) are exposed.
    @AppStorage("developerModeEnabled", store: activeStore) var developerModeEnabled: Bool = false {
        didSet { notifyChange() }
    }

    /// Controls whether automatic folder monitoring starts upon opening a library.
    @AppStorage("autoMonitoringEnabled", store: activeStore) var autoMonitoringEnabled: Bool = true {
        didSet { notifyChange() }
    }

    /// Preferred thumbnail size in the photo grid (range: 120 to 300).
    @AppStorage("gridThumbnailSize", store: activeStore) var gridThumbnailSize: Double = 170.0 {
        didSet { notifyChange() }
    }

    /// Sort order for the photo grid: "dateDescending", "dateAscending", "filename".
    @AppStorage("photoSortOrder", store: activeStore) var photoSortOrder: String = "dateDescending" {
        didSet { notifyChange() }
    }

    /// Controls whether face bounding box overlays are shown by default in the detail viewer.
    @AppStorage("showFaceOverlaysByDefault", store: activeStore) var showFaceOverlaysByDefault: Bool = true {
        didSet { notifyChange() }
    }

    // MARK: - Onboarding & Model Management Settings

    /// Tracks whether the user has seen, completed, or dismissed the first-launch onboarding flow.
    @AppStorage("hasCompletedOnboarding", store: activeStore) var hasCompletedOnboarding: Bool = false {
        didSet { notifyChange() }
    }

    /// Tracks whether the user has seen or dismissed the first-launch model setup flow.
    @AppStorage("hasCompletedModelSetup", store: activeStore) var hasCompletedModelSetup: Bool = false {
        didSet { notifyChange() }
    }

    /// Determines whether the first-launch onboarding modal should appear automatically.
    @MainActor
    public var shouldShowFirstLaunchOnboarding: Bool {
        return !hasCompletedOnboarding && !hasCompletedModelSetup && !ModelManager.shared.hasUserInstalledModel
    }

    /// User-visible display name of the currently active face-recognition model.
    @AppStorage("activeModelDisplayName", store: activeStore) var activeModelDisplayName: String = "" {
        didSet { notifyChange() }
    }

    /// Artifact format of the installed model (e.g., "Core ML Compiled (.mlmodelc)", "Core ML Package (.mlpackage)").
    @AppStorage("activeModelFormat", store: activeStore) var activeModelFormat: String = "" {
        didSet { notifyChange() }
    }

    /// Timestamp when the active model was validated and installed.
    @AppStorage("activeModelInstalledDate", store: activeStore) var activeModelInstalledDate: Double = 0.0 {
        didSet { notifyChange() }
    }

    private func notifyChange() {
        if Thread.isMainThread {
            objectWillChange.send()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.objectWillChange.send()
            }
        }
    }

    private init() {}
}
