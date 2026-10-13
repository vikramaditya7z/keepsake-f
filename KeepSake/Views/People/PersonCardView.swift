import SwiftUI
import AppKit

/// Visual card representing a person/group in the People Gallery.
struct PersonCardView: View {
    let person: PersonDisplayModel
    let onClick: () -> Void
    let onRename: () -> Void
    let onMerge: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: onClick) {
            VStack(spacing: 12) {
                // Face Avatar
                ZStack(alignment: .topTrailing) {
                    FaceCropThumbnailView(
                        faceId: person.representativeFaceId ?? person.id,
                        photoURL: person.representativePhotoURL,
                        boundingBox: person.representativeBoundingBox,
                        size: 110,
                        isCircular: true
                    )
                    .overlay(
                        Circle()
                            .stroke(isHovered ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: isHovered ? 2.5 : 1)
                    )
                    .shadow(color: .black.opacity(isHovered ? 0.2 : 0.08), radius: isHovered ? 8 : 4, x: 0, y: 2)


                }

                // Name & Counts
                VStack(spacing: 4) {
                    Text(person.displayName)
                        .font(.headline)
                        .lineLimit(1)
                        .foregroundStyle(person.customName != nil ? .primary : .secondary)

                    HStack(spacing: 6) {
                        Text("\(person.uniquePhotoCount) \(person.uniquePhotoCount == 1 ? "photo" : "photos")")
                        Text("•")
                        Text("\(person.faceCount) \(person.faceCount == 1 ? "face" : "faces")")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isHovered ? Color(nsColor: .selectedControlColor).opacity(0.15) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isHovered ? Color.accentColor.opacity(0.4) : Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .contextMenu {
            Button(action: onRename) {
                Label("Rename Person…", systemImage: "pencil")
            }

            Button(action: onMerge) {
                Label("Merge with Another Person…", systemImage: "arrow.triangle.merge")
            }

            Divider()

            Button(action: onClick) {
                Label("Open Person Gallery", systemImage: "person.crop.rectangle")
            }
        }
    }
}
