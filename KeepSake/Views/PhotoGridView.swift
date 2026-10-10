import SwiftUI

struct PhotoGridView: View {
    let photos: [PhotoItem]
    let onSelectPhoto: (PhotoItem) -> Void

    @ObservedObject private var settings = AppSettings.shared

    private var columns: [GridItem] {
        let size = CGFloat(settings.gridThumbnailSize)
        return [
            GridItem(.adaptive(minimum: size, maximum: size * 1.4), spacing: 12)
        ]
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(photos) { photo in
                    PhotoThumbnailView(photo: photo) {
                        onSelectPhoto(photo)
                    }
                }
            }
            .padding(16)
        }
    }
}
