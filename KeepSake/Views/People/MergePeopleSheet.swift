import SwiftUI

/// Modal sheet to select a target person when merging people.
struct MergePeopleSheet: View {
    let sourcePerson: PersonDisplayModel
    let candidatePeople: [PersonDisplayModel]
    let onMerge: (PersonDisplayModel) -> Void
    let onCancel: () -> Void

    @State private var selectedTarget: PersonDisplayModel?
    @State private var searchQuery: String = ""

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

            // Search Bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search people…", text: $searchQuery)
                    .textFieldStyle(.plain)
                if !searchQuery.isEmpty {
                    Button(action: { searchQuery = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)
            .padding(16)

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

            Divider()

            // Footer / Actions
            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button(action: {
                    if let target = selectedTarget {
                        onMerge(target)
                    }
                }) {
                    Label("Merge People", systemImage: "arrow.triangle.merge")
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedTarget == nil)
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 480, height: 460)
    }
}
