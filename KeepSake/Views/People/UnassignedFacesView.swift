import SwiftUI

/// Gallery view displaying detected faces that have not been assigned to any person group.
struct UnassignedFacesView: View {
    let unassignedFaces: [FaceDisplayModel]
    let onAssignFace: (FaceDisplayModel) -> Void
    let onDismiss: () -> Void

    @State private var hoveredFaceId: UUID?

    private let columns = [
        GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 16)
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Unassigned Faces")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("\(unassignedFaces.count) detected \(unassignedFaces.count == 1 ? "face" : "faces") not yet assigned to any person.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(20)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            if unassignedFaces.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.tint)
                    Text("All detected faces have been assigned to people.")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(unassignedFaces) { face in
                            let isHovered = hoveredFaceId == face.id
                            VStack(spacing: 8) {
                                FaceCropThumbnailView(
                                    faceId: face.id,
                                    photoURL: face.photoURL,
                                    boundingBox: face.boundingBox,
                                    size: 100,
                                    isCircular: true
                                )
                                .overlay(
                                    Circle()
                                        .stroke(isHovered ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: isHovered ? 2 : 1)
                                )

                                Text(face.filename)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .foregroundStyle(.secondary)

                                Button(action: {
                                    onAssignFace(face)
                                }) {
                                    Label("Assign…", systemImage: "person.crop.circle.badge.plus")
                                        .font(.caption2)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                            )
                            .onHover { h in
                                hoveredFaceId = h ? face.id : nil
                            }
                        }
                    }
                    .padding(20)
                }
            }
        }
        .frame(minWidth: 540, minHeight: 440)
    }
}
