import Foundation

/// Errors that can occur during security-scoped bookmark operations.
enum BookmarkError: LocalizedError {
    case bookmarkCreationFailed(String)
    case bookmarkResolutionFailed(String)
    case securityScopedAccessDenied(URL)

    var errorDescription: String? {
        switch self {
        case .bookmarkCreationFailed(let msg):
            return "Failed to create security-scoped folder bookmark: \(msg)"
        case .bookmarkResolutionFailed(let msg):
            return "Failed to resolve security-scoped folder bookmark: \(msg)"
        case .securityScopedAccessDenied(let url):
            return "Access to folder at \(url.path) was denied by macOS security."
        }
    }
}

/// Service managing macOS security-scoped bookmarks for persistent folder access across app launches.
final class BookmarkManager: @unchecked Sendable {
    static let shared = BookmarkManager()

    private let lock = NSLock()
    private var currentlyAccessedURLs = Set<URL>()

    private init() {}

    /// Creates security-scoped bookmark data for a folder URL selected by the user.
    func createBookmark(for url: URL) throws -> Data {
        do {
            let bookmarkData = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            return bookmarkData
        } catch {
            throw BookmarkError.bookmarkCreationFailed(error.localizedDescription)
        }
    }

    /// Resolves security-scoped bookmark data back into a valid file URL.
    /// - Returns: Tuple of resolved URL and a boolean indicating if the bookmark data is stale and should be regenerated.
    func resolveBookmark(from data: Data) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            return (url, isStale)
        } catch {
            throw BookmarkError.bookmarkResolutionFailed(error.localizedDescription)
        }
    }

    /// Starts accessing a security-scoped resource URL.
    @discardableResult
    func startAccessing(url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if currentlyAccessedURLs.contains(url) {
            return true
        }

        let didStart = url.startAccessingSecurityScopedResource()
        if didStart {
            currentlyAccessedURLs.insert(url)
        }
        return didStart
    }

    /// Stops accessing a security-scoped resource URL.
    func stopAccessing(url: URL) {
        lock.lock()
        defer { lock.unlock() }

        if currentlyAccessedURLs.contains(url) {
            url.stopAccessingSecurityScopedResource()
            currentlyAccessedURLs.remove(url)
        }
    }

    /// Stops accessing all active security-scoped resource URLs.
    func stopAccessingAll() {
        lock.lock()
        defer { lock.unlock() }

        for url in currentlyAccessedURLs {
            url.stopAccessingSecurityScopedResource()
        }
        currentlyAccessedURLs.removeAll()
    }
}
