import Foundation

/// Structured, user-friendly error model adhering to macOS HIG guidelines (What happened, Why it matters, What to do).
struct UserFacingError: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
    let recoverySuggestion: String

    var fullFormattedDescription: String {
        "\(message)\n\n\(recoverySuggestion)"
    }

    static func folderInaccessible(path: String) -> UserFacingError {
        UserFacingError(
            title: "Folder Unavailable",
            message: "Keepsake could not access the selected folder at \"\(path)\".",
            recoverySuggestion: "Check if the drive or network share is connected, or choose a different folder."
        )
    }

    static func photoUnreadable(filename: String) -> UserFacingError {
        UserFacingError(
            title: "Unable to Open Photo",
            message: "Keepsake could not read image data for \"\(filename)\".",
            recoverySuggestion: "The file might be corrupted, unsupported, or removed from disk."
        )
    }

    static func permissionDenied() -> UserFacingError {
        UserFacingError(
            title: "Permission Denied",
            message: "Keepsake does not have permission to read the selected directory.",
            recoverySuggestion: "Grant file access in System Settings > Privacy & Security > Files and Folders."
        )
    }

    static func indexingFailed(count: Int) -> UserFacingError {
        UserFacingError(
            title: "Indexing Encountered Issues",
            message: "\(count) \(count == 1 ? "photo" : "photos") could not be processed completely.",
            recoverySuggestion: "You can click 'Retry' in the status bar to attempt re-indexing these items."
        )
    }

    static func generic(error: Error) -> UserFacingError {
        UserFacingError(
            title: "Operation Failed",
            message: error.localizedDescription,
            recoverySuggestion: "Please try again or select another photo folder if the issue persists."
        )
    }
}
