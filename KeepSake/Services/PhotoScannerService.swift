import Foundation

/// Service responsible for recursively scanning local directories for supported photo files.
struct PhotoScannerService: Sendable {
    static let supportedExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "webp"
    ]

    enum ScanError: LocalizedError {
        case inaccessibleDirectory(URL)
        case unreadableFile(URL)

        var errorDescription: String? {
            switch self {
            case .inaccessibleDirectory(let url):
                return "The directory at \(url.path) could not be accessed."
            case .unreadableFile(let url):
                return "The file at \(url.path) could not be read."
            }
        }
    }

    /// Recursively scans a root URL and yields discovered photos in batches.
    /// Batching prevents flooding the UI thread with thousands of individual updates.
    func scanStream(at rootURL: URL, batchSize: Int = 40) -> AsyncThrowingStream<[PhotoItem], Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory),
                      isDirectory.boolValue else {
                    continuation.finish(throwing: ScanError.inaccessibleDirectory(rootURL))
                    return
                }

                let resourceKeys: Set<URLResourceKey> = [
                    .isRegularFileKey,
                    .fileSizeKey,
                    .contentModificationDateKey,
                    .isDirectoryKey
                ]

                guard let enumerator = FileManager.default.enumerator(
                    at: rootURL,
                    includingPropertiesForKeys: Array(resourceKeys),
                    options: [.skipsHiddenFiles, .skipsPackageDescendants],
                    errorHandler: { (url, error) -> Bool in
                        // Do not abort whole scan on a single inaccessible item
                        print("Warning: Skipping inaccessible item at \(url.path): \(error.localizedDescription)")
                        return true
                    }
                ) else {
                    continuation.finish(throwing: ScanError.inaccessibleDirectory(rootURL))
                    return
                }

                var currentBatch: [PhotoItem] = []
                currentBatch.reserveCapacity(batchSize)

                for case let fileURL as URL in enumerator {
                    if Task.isCancelled {
                        break
                    }

                    let ext = fileURL.pathExtension.lowercased()
                    guard Self.supportedExtensions.contains(ext) else {
                        continue
                    }

                    do {
                        let values = try fileURL.resourceValues(forKeys: resourceKeys)
                        guard values.isRegularFile == true else { continue }

                        let fileSize = Int64(values.fileSize ?? 0)
                        let modDate = values.contentModificationDate
                        let item = PhotoItem(url: fileURL, fileSize: fileSize, dateModified: modDate)
                        currentBatch.append(item)

                        if currentBatch.count >= batchSize {
                            continuation.yield(currentBatch)
                            currentBatch.removeAll(keepingCapacity: true)
                        }
                    } catch {
                        // Skip unreadable file metadata without stopping scan
                        continue
                    }
                }

                // Yield any remaining items
                if !currentBatch.isEmpty && !Task.isCancelled {
                    continuation.yield(currentBatch)
                }

                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
