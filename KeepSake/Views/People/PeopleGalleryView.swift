import SwiftUI

/// Main gallery view displaying all recognized person groups and unassigned faces.
struct PeopleGalleryView: View {
    @ObservedObject var viewModel: PeopleViewModel
    let rootFolderURL: URL?
    let onOpenClusteringLab: () -> Void

    @State private var showUnassignedSheet: Bool = false
    @State private var searchQuery: String = ""

    private let columns = [
        GridItem(.adaptive(minimum: 180, maximum: 230), spacing: 20)
    ]

    var filteredPeople: [PersonDisplayModel] {
        if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return viewModel.people
        }
        return viewModel.people.filter { $0.displayName.localizedCaseInsensitiveContains(searchQuery) }
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
        .sheet(isPresented: $showUnassignedSheet) {
            UnassignedFacesView(
                unassignedFaces: viewModel.unassignedFaces,
                onAssignFace: { face in
                    showUnassignedSheet = false
                    viewModel.promptAssign(for: face)
                },
                onDismiss: {
                    showUnassignedSheet = false
                }
            )
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

            // Unassigned Faces Badge/Button
            if !viewModel.unassignedFaces.isEmpty {
                Button(action: {
                    showUnassignedSheet = true
                }) {
                    Label("\(viewModel.unassignedFaces.count) Unassigned Faces", systemImage: "person.crop.circle.badge.questionmark")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            // People Count
            Text("\(viewModel.people.count) \(viewModel.people.count == 1 ? "person" : "people")")
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

    @ObservedObject private var settings = AppSettings.shared

    // MARK: - Empty State View

    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "person.3.fill")
                .font(.system(size: 56))
                .foregroundStyle(.secondary.opacity(0.6))
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text("No People Discovered Yet")
                    .font(.title2)
                    .fontWeight(.bold)

                Text("Keepsake automatically discovers people as it scans and indexes faces in your photo library.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }

            if !viewModel.unassignedFaces.isEmpty {
                Button(action: {
                    showUnassignedSheet = true
                }) {
                    Label("View \(viewModel.unassignedFaces.count) Unassigned Faces", systemImage: "person.crop.circle.badge.plus")
                        .font(.headline)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 4)
            }

            if settings.developerModeEnabled {
                Button(action: onOpenClusteringLab) {
                    Label("Open Clustering Lab (Developer)", systemImage: "person.3.sequence.fill")
                        .font(.subheadline)
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
