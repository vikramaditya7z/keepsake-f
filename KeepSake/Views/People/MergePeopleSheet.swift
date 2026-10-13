import SwiftUI

/// Modal sheet to select a target person when merging people, with side-by-side preview and explicit confirmation.
struct MergePeopleSheet: View {
    let sourcePerson: PersonDisplayModel
    let candidatePeople: [PersonDisplayModel]
    let onMerge: (PersonDisplayModel) -> Void
    let onCancel: () -> Void

    @State private var selectedTarget: PersonDisplayModel?
    @State private var searchQuery: String = ""
    @State private var showConfirmAlert: Bool = false

    var filteredCandidates: [PersonDisplayModel] {
        let others = candidatePeople.filter { $0.id != sourcePerson.id }
        if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return others
        }
        return others.filter { $0.displayName.localizedCaseInsensitiveContains(searchQuery) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Merge Person")
                        .font(.headline)
                    Text("Merge **\(sourcePerson.displayName)** into another person. All photos and faces will be unified under the target person.")
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

            // Source Person Summary Banner
            HStack(spacing: 12) {
                FaceCropThumbnailView(
                    faceId: sourcePerson.representativeFaceId ?? sourcePerson.id,
                    photoURL: sourcePerson.representativePhotoURL,
                    boundingBox: sourcePerson.representativeBoundingBox,
                    size: 38,
                    isCircular: true
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text("Source: **\(sourcePerson.displayName)**")
                        .font(.subheadline)
                    Text("\(sourcePerson.uniquePhotoCount) photos • \(sourcePerson.faceCount) faces will be merged")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))

            Divider()

            // Search Bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search target person…", text: $searchQuery)
                    .textFieldStyle(.plain)
                if !searchQuery.isEmpty {
                    Button(action: { searchQuery = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            // Candidate List
            if filteredCandidates.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "person.slash")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No other people available to merge with.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filteredCandidates) { target in
                            let isSelected = selectedTarget?.id == target.id
                            Button(action: {
                                selectedTarget = target
                            }) {
                                HStack(spacing: 12) {
                                    FaceCropThumbnailView(
                                        faceId: target.representativeFaceId ?? target.id,
                                        photoURL: target.representativePhotoURL,
                                        boundingBox: target.representativeBoundingBox,
                                        size: 44,
                                        isCircular: true
                                    )

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(target.displayName)
                                            .font(.headline)
                                        Text("\(target.uniquePhotoCount) photos • \(target.faceCount) faces")
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
                                        .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
            }

            // Preview Panel when target is selected
            if let target = selectedTarget {
                Divider()
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Resulting Person Preview:")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Text("**\(target.displayName)** will retain **\(sourcePerson.faceCount + target.faceCount) faces**")
                            .font(.caption)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.08))
            }

            Divider()

            // Footer / Actions
            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button(action: {
                    showConfirmAlert = true
                }) {
                    Label("Merge into Target", systemImage: "arrow.triangle.merge")
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedTarget == nil)
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 500, height: 500)
        .confirmationDialog(
            "Confirm Identity Merge",
            isPresented: $showConfirmAlert,
            titleVisibility: .visible
        ) {
            Button("Merge and Deactivate Source", role: .destructive) {
                if let target = selectedTarget {
                    onMerge(target)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let target = selectedTarget {
                Text("Merge \"\(sourcePerson.displayName)\" into \"\(target.displayName)\"?\n\nAll \(sourcePerson.faceCount) confirmed faces will be unified under \(target.displayName). \"\(sourcePerson.displayName)\" will be removed as an independent person.")
            }
        }
    }
}
