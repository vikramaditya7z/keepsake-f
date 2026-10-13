import SwiftUI

/// Main gallery view displaying all confirmed recognized people.
struct PeopleGalleryView: View {
    @ObservedObject var viewModel: PeopleViewModel
    let rootFolderURL: URL?
    let onOpenClusteringLab: () -> Void
    var onChooseFolder: (() -> Void)? = nil

    @State private var searchQuery: String = ""

    private let columns = [
        GridItem(.adaptive(minimum: 180, maximum: 230), spacing: 20)
    ]

    var filteredPeople: [PersonDisplayModel] {
        let basePeople = rootFolderURL != nil
            ? viewModel.people.filter { $0.faceCount > 0 || $0.uniquePhotoCount > 0 }
            : viewModel.people

        if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return basePeople
        }
        return basePeople.filter { $0.displayName.localizedCaseInsensitiveContains(searchQuery) }
    }

    var body: some View {
        ZStack {
            if let selected = viewModel.selectedPerson {
                PersonDetailView(
                    viewModel: viewModel,
                    rootFolderURL: rootFolderURL,
                    onBack: {
                        viewModel.clearSelection()
                    }
                )
            } else {
                VStack(spacing: 0) {
                    // Sub-Header Bar with Search & Quick Stats
                    gallerySubHeader

                    Divider()

                    // Gallery Content
                    if viewModel.people.isEmpty {
                        emptyStateView
                    } else if filteredPeople.isEmpty {
                        noSearchResultsView
                    } else {
                        mainGalleryScroll
                    }
                }
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .task(id: rootFolderURL) {
            await viewModel.loadData(rootFolderURL: rootFolderURL)
        }
        .onAppear {
            Task {
                await viewModel.loadData(rootFolderURL: rootFolderURL)
            }
        }
        .sheet(isPresented: $viewModel.showMergeSheet) {
            if let source = viewModel.personToMerge {
                MergePeopleSheet(
                    sourcePerson: source,
                    candidatePeople: viewModel.people,
                    onMerge: { target in
                        Task {
                            await viewModel.mergePerson(source: source, into: target, rootFolderURL: rootFolderURL)
                        }
                    },
                    onCancel: {
                        viewModel.showMergeSheet = false
                        viewModel.personToMerge = nil
                    }
                )
            }
        }
        .sheet(isPresented: $viewModel.showAssignSheet) {
            if let face = viewModel.faceToAssign {
                AssignFaceSheet(
                    face: face,
                    candidatePeople: viewModel.people,
                    onAssignToGroup: { targetId in
                        Task {
                            await viewModel.assignFace(faceId: face.id, toTargetGroupId: targetId, rootFolderURL: rootFolderURL)
                        }
                    },
                    onCreateNewPerson: { name in
                        Task {
                            await viewModel.createPersonFromFace(faceId: face.id, name: name, rootFolderURL: rootFolderURL)
                        }
                    },
                    onCancel: {
                        viewModel.showAssignSheet = false
                        viewModel.faceToAssign = nil
                    }
                )
            }
        }
        .alert("Rename Person", isPresented: $viewModel.isRenaming) {
            TextField("Name", text: $viewModel.renamingText)
            Button("Save") {
                Task {
                    await viewModel.confirmRename(rootFolderURL: rootFolderURL)
                }
            }
            Button("Cancel", role: .cancel) {
                viewModel.isRenaming = false
                viewModel.personToRename = nil
            }
        } message: {
            if let person = viewModel.personToRename {
                Text("Enter a new name for \(person.displayName):")
            }
        }
    }

    // MARK: - Sub Header

    private var gallerySubHeader: some View {
        HStack(spacing: 16) {
            // Search Field
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
            .padding(7)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)
            .frame(maxWidth: 260)

            Spacer()

            // People Count
            Text("\(filteredPeople.count) \(filteredPeople.count == 1 ? "person" : "people")")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Main Gallery Scroll

    private var mainGalleryScroll: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(filteredPeople) { person in
                    PersonCardView(
                        person: person,
                        onClick: {
                            Task {
                                await viewModel.selectPerson(person, rootFolderURL: rootFolderURL)
                            }
                        },
                        onRename: {
                            viewModel.promptRename(for: person)
                        },
                        onMerge: {
                            viewModel.promptMerge(for: person)
                        }
                    )
                }
            }
            .padding(24)
        }
    }

    // MARK: - No Search Results

    private var noSearchResultsView: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)

            Text("No people matching \"\(searchQuery)\"")
                .font(.headline)
                .foregroundStyle(.secondary)

            Button("Clear Search") {
                searchQuery = ""
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    @ObservedObject private var settings = AppSettings.shared

    // MARK: - Empty State View

    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "person.2.slash")
                .font(.system(size: 56))
                .foregroundStyle(.secondary.opacity(0.6))
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text("No Confirmed People Yet")
                    .font(.title2)
                    .fontWeight(.bold)

                Text("Keepsake discovers identities as faces are scanned and indexed. Review candidate suggestions in the Suggestions tab to confirm and name people.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            if let onChooseFolder = onChooseFolder, rootFolderURL == nil {
                Button(action: onChooseFolder) {
                    Label("Choose Photo Folder to Scan…", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 4)
            }

            if settings.developerModeEnabled {
                Button(action: onOpenClusteringLab) {
                    Label("Open Clustering Lab (Developer)", systemImage: "person.3.sequence.fill")
                }
                .buttonStyle(.bordered)
                .tint(.indigo)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

/// Visual card for reviewing a candidate face group suggestion.
struct CandidateReviewCardView: View {
    let candidate: PersonDisplayModel
    let onConfirm: () -> Void
    let onAssign: () -> Void
    let onReject: () -> Void
    let onClick: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        VStack(spacing: 12) {
            // Face Avatar
            ZStack {
                FaceCropThumbnailView(
                    faceId: candidate.representativeFaceId ?? candidate.id,
                    photoURL: candidate.representativePhotoURL,
                    boundingBox: candidate.representativeBoundingBox,
                    size: 90,
                    isCircular: true
                )
                .overlay(
                    Circle()
                        .stroke(Color.accentColor.opacity(0.8), style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
                )
                .shadow(color: .black.opacity(isHovered ? 0.18 : 0.08), radius: isHovered ? 6 : 3, x: 0, y: 2)
            }

            // Title & Counts
            VStack(spacing: 3) {
                Text(candidate.displayName)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text("\(candidate.faceCount) \(candidate.faceCount == 1 ? "face" : "faces")")
                    Text("•")
                    Text("\(candidate.uniquePhotoCount) \(candidate.uniquePhotoCount == 1 ? "photo" : "photos")")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            // Action Buttons
            HStack(spacing: 6) {
                Button(action: onConfirm) {
                    Label("Confirm", systemImage: "checkmark")
                        .font(.caption.bold())
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button(action: onAssign) {
                    Image(systemName: "person.crop.circle.badge.plus")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Assign to existing confirmed person")

                Button(action: onReject) {
                    Image(systemName: "xmark")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Reject suggestion")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .padding(.horizontal, 10)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture {
            onClick()
        }
        .contextMenu {
            Button {
                onConfirm()
            } label: {
                Label("Confirm Suggestion…", systemImage: "checkmark")
            }

            Button {
                onAssign()
            } label: {
                Label("Assign to Existing Person…", systemImage: "person.crop.circle.badge.plus")
            }

            Button(role: .destructive) {
                onReject()
            } label: {
                Label("Reject Suggestion", systemImage: "xmark")
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isHovered ? Color(nsColor: .selectedControlColor).opacity(0.12) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isHovered ? Color.accentColor : Color.accentColor.opacity(0.25), lineWidth: 1)
        )
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
