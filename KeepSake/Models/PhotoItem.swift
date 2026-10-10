import Foundation

/// Represents a discovered photo on the local filesystem.
struct PhotoItem: Identifiable, Hashable, Sendable {
    let id: UUID
    let url: URL
    let filename: String
    let fileSize: Int64
    let dateModified: Date?

    init(id: UUID = UUID(), url: URL, fileSize: Int64 = 0, dateModified: Date? = nil) {
        self.id = id
        self.url = url
        self.filename = url.lastPathComponent
        self.fileSize = fileSize
        self.dateModified = dateModified
    }

    var formattedFileSize: String {
        guard fileSize > 0 else { return "Unknown size" }
        return ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    var formattedDate: String {
        guard let date = dateModified else { return "Unknown date" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
