import SwiftUI

struct PhotoThumbnailView: View {
    let photo: PhotoItem
    let onSelect: () -> Void

    @State private var thumbnail: NSImage?
    @State private var isLoading: Bool
    @State private var isHovered: Bool = false

    init(photo: PhotoItem, onSelect: @escaping () -> Void) {
        self.photo = photo
        self.onSelect = onSelect
        let cached = ThumbnailLoader.shared.cachedImage(for: photo.url)
        _thumbnail = State(initialValue: cached)
        _isLoading = State(initialValue: cached == nil)
    }

    var body: some View {
        Button(action: onSelect) {
            ZStack {
                Color(nsColor: .controlBackgroundColor)

                if let thumbnail = thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                }

                if isHovered {
                    Color.black.opacity(0.15)
                }
            }
            .frame(minWidth: 120, maxWidth: .infinity)
            .aspectRatio(1, contentMode: .fit)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isHovered ? Color.accentColor : Color(nsColor: .separatorColor).opacity(0.3), lineWidth: isHovered ? 2 : 1)
            )
            .shadow(color: .black.opacity(isHovered ? 0.15 : 0.04), radius: isHovered ? 6 : 2, y: isHovered ? 3 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(photo.filename), \(photo.formattedFileSize), \(photo.formattedDate)"))
        .accessibilityHint(Text("Opens photo detail viewer"))
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .task(id: photo.url) {
            if thumbnail == nil {
                if let fastCached = ThumbnailLoader.shared.cachedImage(for: photo.url) {
                    self.thumbnail = fastCached
                    self.isLoading = false
                    return
                }
                isLoading = true
                let image = await ThumbnailLoader.shared.loadThumbnail(for: photo.url)
                guard !Task.isCancelled else { return }
                self.thumbnail = image
                self.isLoading = false
            }
        }
        .help("\(photo.filename) (\(photo.formattedFileSize))")
    }
}
