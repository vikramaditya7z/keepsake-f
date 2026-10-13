import SwiftUI

/// Modal sheet to assign an entire candidate group directly to an existing confirmed person.
struct AssignCandidateGroupSheet: View {
    let candidate: PersonDisplayModel
    let confirmedPeople: [PersonDisplayModel]
    let onAssignToPerson: (UUID) -> Void
    let onCancel: () -> Void

    @State private var selectedTargetId: UUID? = nil
    @State private var searchQuery: String = ""

    var filteredPeople: [PersonDisplayModel] {
        if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return confirmedPeople
        }
        return confirmedPeople.filter { $0.displayName.localizedCaseInsensitiveContains(searchQuery) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                FaceCropThumbnailView(
                    faceId: candidate.representativeFaceId ?? candidate.id,
                    photoURL: candidate.representativePhotoURL,
                    boundingBox: candidate.representativeBoundingBox,
                    size: 54,
                    isCircular: true
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text("Assign Candidate to Person")
                        .font(.headline)
                    Text("\(candidate.faceCount) \(candidate.faceCount == 1 ? "face" : "faces") from \(candidate.uniquePhotoCount) \(candidate.uniquePhotoCount == 1 ? "photo" : "photos")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(16)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            // Search Bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search confirmed people…", text: $searchQuery)
                    .textFieldStyle(.plain)
            }
            .padding(8)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            // People List
            if filteredPeople.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "person.crop.circle.badge.questionmark")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("No confirmed people found.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(filteredPeople) { target in
                            let isSelected = selectedTargetId == target.id

                            Button(action: {
                                selectedTargetId = target.id
                            }) {
                                HStack(spacing: 12) {
                                    FaceCropThumbnailView(
                                        faceId: target.representativeFaceId ?? target.id,
                                        photoURL: target.representativePhotoURL,
                                        boundingBox: target.representativeBoundingBox,
                                        size: 40,
                                        isCircular: true
                                    )

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(target.displayName)
                                            .font(.body)
                                            .fontWeight(.medium)
                                            .foregroundStyle(.primary)

                                        Text("\(target.faceCount) faces • \(target.uniquePhotoCount) photos")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    if isSelected {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(Color.accentColor)
                                            .font(.title3)
                                    }
                                }
                                .padding(10)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(isSelected ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
            }

            Divider()

            // Footer
            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Assign to Person") {
                    if let targetId = selectedTargetId {
                        onAssignToPerson(targetId)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedTargetId == nil)
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 440, height: 460)
    }
}
