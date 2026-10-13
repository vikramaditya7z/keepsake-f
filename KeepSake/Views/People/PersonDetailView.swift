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
    @State private var faceToUnassign: UUID?
    @State private var faceToRecycleBin: UUID?
    @State private var faceToExclude: UUID?
    @State private var photoSortOrder: PersonPhotoSortOrder = .dateDescending

    private let faceColumns = [
        GridItem(.adaptive(minimum: 130, maximum: 160), spacing: 14)
    ]

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // Top Navigation Bar
                topNavBar

                Divider()

                // Candidate Review Banner if suggestion
                if viewModel.selectedPerson?.reviewStatus == .candidateSuggestion {
                    candidateReviewBanner
                    Divider()
                }

                // Hero Header (Avatar + Name + Stats)
                heroHeader

                Divider()

                // Segmented Content Tab (Photos vs Faces)
                tabPicker

                Divider()

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
            "Remove Person",
            isPresented: $showUngroupConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove Person", role: .destructive) {
                if let person = viewModel.selectedPerson {
                    Task {
                        await viewModel.removePerson(person, rootFolderURL: rootFolderURL)
                        onBack()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let person = viewModel.selectedPerson {
                Text("Are you sure you want to remove \"\(person.displayName)\" from the central database? Their confirmed faces will become unassigned. Original photo files will not be deleted.")
            }
        }
    }

    // MARK: - Candidate Review Banner

    private var candidateReviewBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.title2)
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("Candidate Suggestion Awaiting Review")
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)
                Text("Review photos and faces below. You can remove individual mismatched faces before confirming.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let person = viewModel.selectedPerson {
                Button("Confirm Suggestion…") {
                    viewModel.promptConfirmCandidate(for: person)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button("Assign to Person…") {
                    viewModel.promptAssignCandidateGroup(person)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Reject") {
                    Task {
                        await viewModel.rejectCandidate(candidate: person, rootFolderURL: rootFolderURL)
                        onBack()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color.accentColor.opacity(0.1))
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

            if let person = viewModel.selectedPerson, person.reviewStatus == .confirmed {
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
                        Label("Remove Person…", systemImage: "person.slash")
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
                .overlay(alignment: .topTrailing) {
                    if person.coverFaceId != nil {
                        Image(systemName: "star.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(4)
                            .background(Circle().fill(Color.orange))
                            .offset(x: 4, y: -4)
                            .shadow(radius: 2)
                    }
                }
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

            if viewModel.selectedDetailTab == .photos && !viewModel.selectedPersonPhotos.isEmpty {
                Picker("Sort", selection: $photoSortOrder) {
                    ForEach(PersonPhotoSortOrder.allCases) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 140)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Photos Content

    private var displayedPhotos: [PhotoItem] {
        var items = viewModel.selectedPersonPhotos
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
            if displayedPhotos.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("No photos found for this person.")
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
                            let currentPerson = viewModel.selectedPerson
                            let isCover = (currentPerson != nil) && ((face.id == currentPerson!.coverFaceId) || (currentPerson!.coverFaceId == nil && face.id == currentPerson!.representativeFaceId))

                            VStack(spacing: 8) {
                                ZStack(alignment: .topTrailing) {
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

                                    if isCover && currentPerson?.reviewStatus == .confirmed {
                                        Image(systemName: "star.fill")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(.white)
                                            .padding(4)
                                            .background(Circle().fill(Color.orange))
                                            .offset(x: 4, y: -4)
                                            .shadow(color: .black.opacity(0.2), radius: 2, x: 0, y: 1)
                                    }
                                }

                                Text(face.filename)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .foregroundStyle(.secondary)

                                HStack(spacing: 6) {
                                    if let currentPerson = currentPerson {
                                        if currentPerson.reviewStatus == .candidateSuggestion {
                                            Button(action: {
                                                viewModel.promptAssign(for: face)
                                            }) {
                                                Label("Assign…", systemImage: "person.crop.circle.badge.plus")
                                                    .font(.caption2)
                                            }
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)
                                            .help("Assign face to an existing confirmed person")

                                            Menu {
                                                Button {
                                                    faceToRemove = face.id
                                                } label: {
                                                    Label("Remove from Suggestion", systemImage: "minus.circle")
                                                }

                                                Button(role: .destructive) {
                                                    faceToExclude = face.id
                                                } label: {
                                                    Label("Not a Face (False Detection)", systemImage: "trash")
                                                }
                                            } label: {
                                                Image(systemName: "ellipsis.circle")
                                                    .font(.system(size: 14))
                                            }
                                            .menuStyle(.borderlessButton)
                                            .menuIndicator(.hidden)
                                            .fixedSize()
                                            .help("More face options")
                                        } else {
                                            Button(action: {
                                                Task {
                                                    await viewModel.setCoverFace(for: currentPerson, faceId: face.id, rootFolderURL: rootFolderURL)
                                                }
                                            }) {
                                                Label(isCover ? "Cover" : "Set Cover", systemImage: isCover ? "star.fill" : "star")
                                                    .font(.caption2.weight(isCover ? .semibold : .regular))
                                            }
                                            .buttonStyle(.bordered)
                                            .tint(isCover ? .orange : nil)
                                            .controlSize(.small)
                                            .help(isCover ? "Current identity cover photo" : "Set as identity cover photo")

                                            Menu {
                                                Section("Identity") {
                                                    Button {
                                                        viewModel.promptAssign(for: face)
                                                    } label: {
                                                        Label("Move to Another Person…", systemImage: "arrow.right.circle")
                                                    }

                                                    Button {
                                                        faceToUnassign = face.id
                                                    } label: {
                                                        Label("Unassign Face", systemImage: "minus.circle")
                                                    }
                                                }

                                                Section("Removal") {
                                                    Button {
                                                        faceToRecycleBin = face.id
                                                    } label: {
                                                        Label("Move Association to Recycle Bin", systemImage: "archivebox")
                                                    }

                                                    Button(role: .destructive) {
                                                        faceToExclude = face.id
                                                    } label: {
                                                        Label("Not a Face (False Detection)", systemImage: "trash")
                                                    }
                                                }
                                            } label: {
                                                Image(systemName: "ellipsis.circle")
                                                    .font(.system(size: 14))
                                            }
                                            .menuStyle(.borderlessButton)
                                            .menuIndicator(.hidden)
                                            .fixedSize()
                                            .help("More face options")
                                        }
                                    }
                                }
                            }
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                            )
                            .contextMenu {
                                if let currentPerson = currentPerson {
                                    if currentPerson.reviewStatus == .candidateSuggestion {
                                        Button {
                                            viewModel.promptAssign(for: face)
                                        } label: {
                                            Label("Assign to Existing Person…", systemImage: "person.crop.circle.badge.plus")
                                        }

                                        Button {
                                            faceToRemove = face.id
                                        } label: {
                                            Label("Remove to Unassigned", systemImage: "minus.circle")
                                        }

                                        Button(role: .destructive) {
                                            faceToExclude = face.id
                                        } label: {
                                            Label("Not a Face (False Detection)", systemImage: "trash")
                                        }
                                    } else {
                                        Button {
                                            Task {
                                                await viewModel.setCoverFace(for: currentPerson, faceId: face.id, rootFolderURL: rootFolderURL)
                                            }
                                        } label: {
                                            Label(isCover ? "Current Cover Photo" : "Set as Cover Photo", systemImage: isCover ? "star.fill" : "star")
                                        }

                                        Divider()

                                        Button {
                                            viewModel.promptAssign(for: face)
                                        } label: {
                                            Label("Move to Another Person…", systemImage: "arrow.right.circle")
                                        }

                                        Button {
                                            faceToUnassign = face.id
                                        } label: {
                                            Label("Unassign Face to Unassigned", systemImage: "minus.circle")
                                        }

                                        Button {
                                            faceToRecycleBin = face.id
                                        } label: {
                                            Label("Move Association to Recycle Bin", systemImage: "archivebox")
                                        }

                                        Button(role: .destructive) {
                                            faceToExclude = face.id
                                        } label: {
                                            Label("Not a Face (False Detection)", systemImage: "trash")
                                        }
                                    }
                                }
                            }
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
            "Remove Face from Suggestion",
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
            Text("Remove this face from the suggested group? It will be moved to Unassigned Faces and will not be included when you confirm this identity.")
        }
        .confirmationDialog(
            "Unassign Face",
            isPresented: Binding(
                get: { faceToUnassign != nil },
                set: { if !$0 { faceToUnassign = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Unassign Face", role: .destructive) {
                if let faceId = faceToUnassign {
                    Task {
                        await viewModel.removeFaceFromSelectedPerson(faceId: faceId, rootFolderURL: rootFolderURL)
                        faceToUnassign = nil
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                faceToUnassign = nil
            }
        } message: {
            Text("Remove this face association and return it to Unassigned Faces? The face will be available to assign to any person.")
        }
        .confirmationDialog(
            "Move Association to Recycle Bin",
            isPresented: Binding(
                get: { faceToRecycleBin != nil },
                set: { if !$0 { faceToRecycleBin = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Move to Recycle Bin", role: .destructive) {
                if let faceId = faceToRecycleBin {
                    Task {
                        await viewModel.removeFaceToRecycleBinFromSelectedPerson(faceId: faceId, rootFolderURL: rootFolderURL)
                        faceToRecycleBin = nil
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                faceToRecycleBin = nil
            }
        } message: {
            Text("Remove this face from \(viewModel.selectedPerson?.displayName ?? "this person") and move the association to the Recycle Bin under \"Removed from People\". You can restore it later. Original photos are never deleted.")
        }
        .confirmationDialog(
            "Mark as False Detection (Not a Face)",
            isPresented: Binding(
                get: { faceToExclude != nil },
                set: { if !$0 { faceToExclude = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Move to Recycle Bin", role: .destructive) {
                if let faceId = faceToExclude {
                    Task {
                        await viewModel.excludeFaceFromSelectedPerson(faceId: faceId, rootFolderURL: rootFolderURL)
                        faceToExclude = nil
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                faceToExclude = nil
            }
        } message: {
            Text("Exclude this detected face and move it to the Recycle Bin under False Detections. Original photograph files will not be deleted or modified.")
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
