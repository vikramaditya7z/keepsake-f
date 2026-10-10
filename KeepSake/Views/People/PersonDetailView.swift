import SwiftUI

/// Sort order options for photos in the Person Detail view.
enum PersonPhotoSortOrder: String, CaseIterable, Identifiable {
    case dateDescending = "Newest First"
    case dateAscending = "Oldest First"
    case nameAscending = "Filename (A-Z)"

    var id: String { rawValue }
}

/// Detailed view showing all photos and face crops associated with a specific person.
struct PersonDetailView: View {
    @ObservedObject var viewModel: PeopleViewModel
    let rootFolderURL: URL?
    let onBack: () -> Void

    @State private var isEditingNameInline: Bool = false
    @State private var inlineNameText: String = ""
    @State private var hoveredFaceId: UUID?
    @State private var showUngroupConfirmation: Bool = false
    @State private var faceToRemove: UUID?
    @State private var photoSortOrder: PersonPhotoSortOrder = .dateDescending
    @State private var photoSearchText: String = ""

    private let faceColumns = [
        GridItem(.adaptive(minimum: 130, maximum: 160), spacing: 14)
    ]

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // Top Navigation Bar
                topNavBar

                Divider()

                // Hero Header (Avatar + Name + Stats)
                heroHeader

                Divider()

                // Segmented Content Tab (Photos vs Faces)
                tabPicker

                // Tab Content Area
                if viewModel.selectedDetailTab == .photos {
                    photosContent
                } else {
                    facesContent
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))

            // Photo Detail Viewer (Reusing existing PhotoDetailView)
            if let photo = viewModel.selectedPhotoForDetail {
                PhotoDetailView(
                    photo: photo,
                    onDismiss: {
                        viewModel.selectedPhotoForDetail = nil
                    },
                    onPrevious: {
                        viewModel.selectPreviousPhoto()
                    },
                    onNext: {
                        viewModel.selectNextPhoto()
                    },
                    hasPrevious: viewModel.hasPreviousPhoto,
                    hasNext: viewModel.hasNextPhoto
                )
                .transition(.opacity)
            }
        }
        .confirmationDialog(
            "Ungroup Person",
            isPresented: $showUngroupConfirmation,
            titleVisibility: .visible
        ) {
            Button("Ungroup Person", role: .destructive) {
                Task {
                    await viewModel.deleteSelectedPerson(rootFolderURL: rootFolderURL)
                    onBack()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let person = viewModel.selectedPerson {
                Text("Are you sure you want to ungroup \"\(person.displayName)\"? Their faces will become unassigned.")
            }
        }
    }

    // MARK: - Top Navigation Bar

    private var topNavBar: some View {
        HStack(spacing: 12) {
            Button(action: onBack) {
                Label("All People", systemImage: "chevron.left")
                    .font(.subheadline)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)

            Spacer()

            if let person = viewModel.selectedPerson {
                Button(action: {
                    viewModel.promptRename(for: person)
                }) {
                    Label("Rename", systemImage: "pencil")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(action: {
                    viewModel.promptMerge(for: person)
                }) {
                    Label("Merge…", systemImage: "arrow.triangle.merge")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Menu {
                    Button(role: .destructive, action: {
                        showUngroupConfirmation = true
                    }) {
                        Label("Ungroup Person…", systemImage: "person.slash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Hero Header

    private var heroHeader: some View {
        HStack(spacing: 20) {
            if let person = viewModel.selectedPerson {
                FaceCropThumbnailView(
                    faceId: person.representativeFaceId ?? person.id,
                    photoURL: person.representativePhotoURL,
                    boundingBox: person.representativeBoundingBox,
                    size: 96,
                    isCircular: true
                )
                .overlay(Circle().stroke(Color.accentColor.opacity(0.6), lineWidth: 2))
                .shadow(color: .black.opacity(0.1), radius: 6, x: 0, y: 2)

                VStack(alignment: .leading, spacing: 6) {
                    if isEditingNameInline {
                        HStack(spacing: 8) {
                            TextField("Name", text: $inlineNameText)
                                .textFieldStyle(.roundedBorder)
                                .font(.title2)
                                .frame(maxWidth: 240)
                                .onSubmit {
                                    saveInlineName()
                                }

                            Button("Save") {
                                saveInlineName()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)

                            Button("Cancel") {
                                isEditingNameInline = false
                            }
                            .buttonStyle(.plain)
                            .controlSize(.small)
                        }
                    } else {
                        HStack(spacing: 8) {
                            Text(person.displayName)
                                .font(.title)
                                .fontWeight(.bold)

                            Button(action: {
                                inlineNameText = person.customName ?? ""
                                isEditingNameInline = true
                            }) {
                                Image(systemName: "pencil.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Edit name")
                        }
                    }

                    HStack(spacing: 10) {
                        Label("\(person.uniquePhotoCount) \(person.uniquePhotoCount == 1 ? "photo" : "photos")", systemImage: "photo")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                            .foregroundStyle(Color.accentColor)

                        Label("\(person.faceCount) \(person.faceCount == 1 ? "face" : "faces")", systemImage: "face.smiling")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.secondary.opacity(0.12)))
                            .foregroundStyle(.secondary)

                        if person.faceCount > 1 {
                            Label("Avg match: \(Int(person.averageSimilarity * 100))%", systemImage: "chart.bar.fill")
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.green.opacity(0.12)))
                                .foregroundStyle(.green)
                        }
                    }
                }

                Spacer()
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Tab Picker

    private var tabPicker: some View {
        HStack {
            Picker("View", selection: $viewModel.selectedDetailTab) {
                ForEach(PersonDetailTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 200)

            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Photos Content

    private var displayedPhotos: [PhotoItem] {
        var items = viewModel.selectedPersonPhotos
        let trimmed = photoSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let lower = trimmed.lowercased()
            items = items.filter { $0.filename.lowercased().contains(lower) }
        }
        switch photoSortOrder {
        case .dateDescending:
            items.sort { ($0.dateModified ?? Date.distantPast) > ($1.dateModified ?? Date.distantPast) }
        case .dateAscending:
            items.sort { ($0.dateModified ?? Date.distantPast) < ($1.dateModified ?? Date.distantPast) }
        case .nameAscending:
            items.sort { $0.filename.localizedCaseInsensitiveCompare($1.filename) == .orderedAscending }
        }
        return items
    }

    @ViewBuilder
    private var photosContent: some View {
        VStack(spacing: 0) {
            // Sort & Filter Toolbar
            if !viewModel.selectedPersonPhotos.isEmpty {
                HStack(spacing: 12) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Search photos…", text: $photoSearchText)
                            .textFieldStyle(.plain)
                        if !photoSearchText.isEmpty {
                            Button(action: { photoSearchText = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
                    .frame(maxWidth: 200)

                    Spacer()

                    Picker("Sort", selection: $photoSortOrder) {
                        ForEach(PersonPhotoSortOrder.allCases) { order in
                            Text(order.rawValue).tag(order)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 140)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
                .background(Color(nsColor: .windowBackgroundColor))

                Divider()
            }

            if displayedPhotos.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text(viewModel.selectedPersonPhotos.isEmpty ? "No photos found for this person." : "No photos matching filter.")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                PhotoGridView(photos: displayedPhotos) { photo in
                    viewModel.selectedPhotoForDetail = photo
                }
            }
        }
    }

    // MARK: - Faces Content

    @ViewBuilder
    private var facesContent: some View {
        Group {
            if viewModel.selectedPersonFaces.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "face.dashed")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("No face crops recorded.")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: faceColumns, spacing: 16) {
                        ForEach(viewModel.selectedPersonFaces) { face in
                            let isHovered = hoveredFaceId == face.id
                            VStack(spacing: 8) {
                                FaceCropThumbnailView(
                                    faceId: face.id,
                                    photoURL: face.photoURL,
                                    boundingBox: face.boundingBox,
                                    size: 90,
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

                                HStack(spacing: 6) {
                                    if let currentPerson = viewModel.selectedPerson {
                                        let isCurrentRep = face.id == currentPerson.representativeFaceId
                                        Button(action: {
                                            Task {
                                                await viewModel.setRepresentativeFace(for: currentPerson, faceId: face.id, rootFolderURL: rootFolderURL)
                                            }
                                        }) {
                                            Image(systemName: isCurrentRep ? "star.fill" : "star")
                                                .foregroundStyle(isCurrentRep ? .yellow : .secondary)
                                                .help(isCurrentRep ? "Current Key Thumbnail" : "Set as Key Thumbnail")
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.mini)
                                        .accessibilityLabel("Set as Key Thumbnail")
                                    }

                                    Button(action: {
                                        viewModel.promptAssign(for: face)
                                    }) {
                                        Image(systemName: "arrow.right.circle")
                                            .help("Move to another person")
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.mini)
                                    .accessibilityLabel("Move face to another person")

                                    Button(role: .destructive, action: {
                                        faceToRemove = face.id
                                    }) {
                                        Image(systemName: "minus.circle")
                                            .help("Remove face from this person")
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.mini)
                                    .accessibilityLabel("Remove face from person")
                                }
                            }
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                            )
                            .onHover { h in
                                hoveredFaceId = h ? face.id : nil
                            }
                        }
                    }
                    .padding(24)
                }
            }
        }
        .confirmationDialog(
            "Remove Face",
            isPresented: Binding(
                get: { faceToRemove != nil },
                set: { if !$0 { faceToRemove = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove Face", role: .destructive) {
                if let faceId = faceToRemove {
                    Task {
                        await viewModel.removeFaceFromSelectedPerson(faceId: faceId, rootFolderURL: rootFolderURL)
                        faceToRemove = nil
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                faceToRemove = nil
            }
        } message: {
            Text("Are you sure you want to remove this face from \(viewModel.selectedPerson?.displayName ?? "this person")? It will be moved to Unassigned Faces.")
        }
    }

    private func saveInlineName() {
        guard let person = viewModel.selectedPerson else { return }
        Task {
            await viewModel.renamePerson(person, newName: inlineNameText, rootFolderURL: rootFolderURL)
            isEditingNameInline = false
        }
    }
}
