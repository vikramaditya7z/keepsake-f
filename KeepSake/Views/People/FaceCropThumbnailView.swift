import SwiftUI
import AppKit

/// Asynchronously loads and renders a cropped face thumbnail with memory caching.
struct FaceCropThumbnailView: View {
    let faceId: UUID
    let photoURL: URL?
    let boundingBox: CGRect?
    var size: CGFloat = 80
    var isCircular: Bool = true

    @State private var image: NSImage?
    @State private var isLoading: Bool = false

    var body: some View {
        ZStack {
            if let image = image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(shape)
            } else if isLoading {
                ZStack {
                    shapeFill
                    ProgressView()
                        .controlSize(.small)
                }
                .frame(width: size, height: size)
            } else {
                ZStack {
                    shapeFill
                    Image(systemName: "person.fill")
                        .font(.system(size: size * 0.42))
                        .foregroundStyle(.secondary)
                }
                .frame(width: size, height: size)
            }
        }
        .task(id: "\(faceId.uuidString)_\(photoURL?.path ?? "")") {
            await loadCrop()
        }
    }

    @ViewBuilder
    private var shapeFill: some View {
        if isCircular {
            Circle().fill(Color(nsColor: .controlBackgroundColor))
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        }
    }

    private var shape: AnyShape {
        if isCircular {
            return AnyShape(Circle())
        } else {
            return AnyShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func loadCrop() async {
        guard let url = photoURL, let box = boundingBox else {
            return
        }
        isLoading = true
        image = await FaceCropLoader.shared.loadFaceCrop(faceId: faceId, photoURL: url, boundingBox: box)
        isLoading = false
    }
}
