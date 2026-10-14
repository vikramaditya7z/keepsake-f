import SwiftUI
import Combine

/// Central user preferences and application settings for Keepsake.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    // MARK: - General & Library Settings

    /// Controls whether developer & experimental features (Clustering Lab, Recognition Lab, internal metrics) are exposed.
    @AppStorage("developerModeEnabled") var developerModeEnabled: Bool = false {
        didSet { objectWillChange.send() }
    }

    /// Controls whether automatic folder monitoring starts upon opening a library.
    @AppStorage("autoMonitoringEnabled") var autoMonitoringEnabled: Bool = true {
        didSet { objectWillChange.send() }
    }

    /// Preferred thumbnail size in the photo grid (range: 120 to 300).
    @AppStorage("gridThumbnailSize") var gridThumbnailSize: Double = 170.0 {
        didSet { objectWillChange.send() }
    }

    /// Sort order for the photo grid: "dateDescending", "dateAscending", "filename".
    @AppStorage("photoSortOrder") var photoSortOrder: String = "dateDescending" {
        didSet { objectWillChange.send() }
    }

    /// Controls whether face bounding box overlays are shown by default in the detail viewer.
    @AppStorage("showFaceOverlaysByDefault") var showFaceOverlaysByDefault: Bool = true {
        didSet { objectWillChange.send() }
    }

    // MARK: - Onboarding & Model Management Settings

    /// Tracks whether the user has seen, completed, or dismissed the first-launch onboarding flow.
    @AppStorage("hasCompletedOnboarding") var hasCompletedOnboarding: Bool = false {
        didSet { objectWillChange.send() }
    }

    /// Tracks whether the user has seen or dismissed the first-launch model setup flow.
    @AppStorage("hasCompletedModelSetup") var hasCompletedModelSetup: Bool = false {
        didSet { objectWillChange.send() }
    }

    /// Determines whether the first-launch onboarding modal should appear automatically.
    @MainActor
    public var shouldShowFirstLaunchOnboarding: Bool {
        return !hasCompletedOnboarding && !hasCompletedModelSetup && !ModelManager.shared.hasUserInstalledModel
    }

    /// User-visible display name of the currently active face-recognition model.
    @AppStorage("activeModelDisplayName") var activeModelDisplayName: String = "" {
        didSet { objectWillChange.send() }
    }

    /// Artifact format of the installed model (e.g., "Core ML Compiled (.mlmodelc)", "Core ML Package (.mlpackage)").
    @AppStorage("activeModelFormat") var activeModelFormat: String = "" {
        didSet { objectWillChange.send() }
    }

    /// Timestamp when the active model was validated and installed.
    @AppStorage("activeModelInstalledDate") var activeModelInstalledDate: Double = 0.0 {
        didSet { objectWillChange.send() }
    }

    private init() {}
}
