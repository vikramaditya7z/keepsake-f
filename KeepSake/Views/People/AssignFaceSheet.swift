import SwiftUI

/// Modal sheet to assign or move an individual face to an existing or new person.
struct AssignFaceSheet: View {
    let face: FaceDisplayModel
    let candidatePeople: [PersonDisplayModel]
    let onAssignToGroup: (UUID) -> Void
    let onCreateNewPerson: (String?) -> Void
    let onCancel: () -> Void

    @State private var selectedTargetId: UUID?
    @State private var isCreatingNew: Bool = false
    @State private var newPersonName: String = ""
    @State private var searchQuery: String = ""

    var filteredCandidates: [PersonDisplayModel] {
        let others = candidatePeople.filter { $0.id != face.assignedGroupId }
        if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return others
        }
        return others.filter { $0.displayName.localizedCaseInsensitiveContains(searchQuery) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                FaceCropThumbnailView(
                    faceId: face.id,
                    photoURL: face.photoURL,
                    boundingBox: face.boundingBox,
                    size: 50,
                    isCircular: true
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(face.assignedGroupId != nil ? "Move Face" : "Assign Face")
                        .font(.headline)
                    Text("From **\(face.filename)**")
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

            // Mode Picker: Existing Person vs New Person
            Picker("Mode", selection: $isCreatingNew) {
                Text("Existing Person").tag(false)
                Text("Create New Person").tag(true)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)

            if isCreatingNew {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Enter a name for the new person:")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    TextField("e.g. Grandma, Sarah, Alex", text: $newPersonName)
                        .textFieldStyle(.roundedBorder)

                    Spacer()
                }
                .padding(16)
                .frame(maxHeight: .infinity)
            } else {
                // Search Bar
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search existing people…", text: $searchQuery)
                        .textFieldStyle(.plain)
                }
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)

                // List
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(filteredCandidates) { target in
                            let isSelected = selectedTargetId == target.id
                            Button(action: {
                                selectedTargetId = target.id
                            }) {
                                HStack(spacing: 12) {
                                    FaceCropThumbnailView(
                                        faceId: target.representativeFaceId ?? target.id,
                                        photoURL: target.representativePhotoURL,
                                        boundingBox: target.representativeBoundingBox,
                                        size: 38,
                                        isCircular: true
                                    )

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(target.displayName)
                                            .font(.subheadline)
                                            .fontWeight(.medium)
                                        Text("\(target.uniquePhotoCount) photos")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    if isSelected {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                                .padding(8)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(isSelected ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
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

            // Actions
            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)

                Spacer()

                if isCreatingNew {
                    Button("Create Person") {
                        onCreateNewPerson(newPersonName)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(newPersonName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Assign to Person") {
                        if let targetId = selectedTargetId {
                            onAssignToGroup(targetId)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedTargetId == nil)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 440, height: 420)
    }
}
