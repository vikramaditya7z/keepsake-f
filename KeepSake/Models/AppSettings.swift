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

    private init() {}
}
