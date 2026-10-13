import SwiftUI

/// Gallery view displaying detected faces that have not been assigned to any person group,
/// with full interactive multi-select and bulk assignment workflows.
struct UnassignedFacesView: View {
    @ObservedObject var viewModel: PeopleViewModel
    let rootFolderURL: URL?
    let onDismiss: () -> Void

    @State private var hoveredFaceId: UUID?
    @State private var showBulkAssignModal: Bool = false
    @State private var showBulkCreateAlert: Bool = false
    @State private var bulkCreateNameText: String = ""

    private let columns = [
        GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 16)
    ]

    private var selectedCount: Int {
        viewModel.selectedUnassignedFaceIds.count
    }

    private var hasCannotLinkConflict: Bool {
        let selectedFaces = viewModel.unassignedFaces.filter { viewModel.selectedUnassignedFaceIds.contains($0.id) }
        let photoIds = selectedFaces.map { $0.photoId }
        return Set(photoIds).count < photoIds.count
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerBar

            Divider()

            // Conflict Warning Banner if multiple faces from same photo selected
            if hasCannotLinkConflict {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.blue)
                    Text("Some selected faces share the same photograph. They will be split into separate candidate groups automatically when restored to Suggestions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(Color.blue.opacity(0.08))

                Divider()
            }

            // Selection Action Bar (when in selection mode or when faces are selected)
            if viewModel.isSelectingUnassigned {
                selectionToolbar
                Divider()
            }

            if viewModel.unassignedFaces.isEmpty {
                emptyState
            } else {
                facesGrid
            }
        }
        .frame(minWidth: 640, minHeight: 520)
        .sheet(isPresented: $showBulkAssignModal) {
            bulkAssignSheet
        }
        .alert("Create Person from Selected Faces", isPresented: $showBulkCreateAlert) {
            TextField("Person Name", text: $bulkCreateNameText)
            Button("Create Person") {
                let name = bulkCreateNameText.trimmingCharacters(in: .whitespacesAndNewlines)
                Task {
                    await viewModel.bulkCreatePersonFromSelectedFaces(
                        name: name.isEmpty ? nil : name,
                        rootFolderURL: rootFolderURL
                    )
                    bulkCreateNameText = ""
                }
            }
            Button("Cancel", role: .cancel) {
                bulkCreateNameText = ""
            }
        } message: {
            Text("Create a new person with \(selectedCount) confirmed \(selectedCount == 1 ? "face" : "faces").")
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Unassigned Faces")
                    .font(.title2)
                    .fontWeight(.bold)
                Text("\(viewModel.unassignedFaces.count) detected \(viewModel.unassignedFaces.count == 1 ? "face" : "faces") awaiting identity assignment in this folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !viewModel.unassignedFaces.isEmpty {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        viewModel.isSelectingUnassigned.toggle()
                        if !viewModel.isSelectingUnassigned {
                            viewModel.clearUnassignedSelection()
                        }
                    }
                }) {
                    Label(viewModel.isSelectingUnassigned ? "Done" : "Select", systemImage: viewModel.isSelectingUnassigned ? "checkmark" : "checklist")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(20)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Selection Toolbar

    private var selectionToolbar: some View {
        HStack(spacing: 12) {
            Button(action: {
                if selectedCount == viewModel.unassignedFaces.count {
                    viewModel.clearUnassignedSelection()
                } else {
                    viewModel.selectAllUnassignedFaces()
                }
            }) {
                Text(selectedCount == viewModel.unassignedFaces.count ? "Deselect All" : "Select All (\(viewModel.unassignedFaces.count))")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Text("\(selectedCount) selected")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(selectedCount > 0 ? Color.accentColor : Color.secondary)

            Spacer()

            Button(action: {
                showBulkAssignModal = true
            }) {
                Label("Assign to Person…", systemImage: "person.crop.circle.badge.plus")
                    .font(.caption)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(selectedCount == 0 || hasCannotLinkConflict || viewModel.people.isEmpty)

            Button(action: {
                showBulkCreateAlert = true
            }) {
                Label("Create New Person…", systemImage: "person.badge.plus")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(selectedCount == 0 || hasCannotLinkConflict)

            Button {
                Task {
                    await viewModel.bulkRestoreSelectedFacesToSuggestions(rootFolderURL: rootFolderURL)
                }
            } label: {
                Label("Restore to Suggestions", systemImage: "sparkles")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(selectedCount == 0)
            .help("Restore selected faces to Suggestions as a candidate group for review")

            Button(role: .destructive) {
                Task {
                    await viewModel.bulkExcludeSelectedFaces(rootFolderURL: rootFolderURL)
                }
            } label: {
                Label("Not a Face", systemImage: "trash")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(selectedCount == 0)
            .help("Mark selected faces as false detections and move them to Recycle Bin")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("All detected faces have been assigned to people.")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Faces Grid

    private var facesGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(viewModel.unassignedFaces) { face in
                    let isSelected = viewModel.isUnassignedFaceSelected(face.id)
                    let isHovered = hoveredFaceId == face.id

                    VStack(spacing: 8) {
                        ZStack(alignment: .topTrailing) {
                            FaceCropThumbnailView(
                                faceId: face.id,
                                photoURL: face.photoURL,
                                boundingBox: face.boundingBox,
                                size: 100,
                                isCircular: true
                            )
                            .overlay(
                                Circle()
                                    .stroke(
                                        isSelected ? Color.accentColor : (isHovered ? Color.accentColor.opacity(0.6) : Color(nsColor: .separatorColor)),
                                        lineWidth: isSelected ? 3 : 1
                                    )
                            )

                            if viewModel.isSelectingUnassigned {
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                                    .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                                    .offset(x: 4, y: -4)
                            }
                        }

                        Text(face.filename)
                            .font(.caption)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)

                        if !viewModel.isSelectingUnassigned {
                            HStack(spacing: 4) {
                                Button(action: {
                                    viewModel.promptAssign(for: face)
                                }) {
                                    Label("Assign…", systemImage: "person.crop.circle.badge.plus")
                                        .font(.caption2)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)

                                Button {
                                    Task {
                                        await viewModel.restoreFaceToSuggestions(faceId: face.id, rootFolderURL: rootFolderURL)
                                    }
                                } label: {
                                    Image(systemName: "sparkles")
                                        .font(.caption2)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .help("Restore this face to Suggestions for review and assignment")

                                Button(role: .destructive) {
                                    Task {
                                        await viewModel.excludeUnassignedFace(faceId: face.id, rootFolderURL: rootFolderURL)
                                    }
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.caption2)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .help("Mark as Not a Face (move to Recycle Bin)")
                            }
                        }
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(isSelected ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if viewModel.isSelectingUnassigned {
                            viewModel.toggleSelectUnassignedFace(face.id)
                        }
                    }
                    .contextMenu {
                        Button {
                            viewModel.promptAssign(for: face)
                        } label: {
                            Label("Assign to Person…", systemImage: "person.crop.circle.badge.plus")
                        }

                        Button {
                            Task {
                                await viewModel.restoreFaceToSuggestions(faceId: face.id, rootFolderURL: rootFolderURL)
                            }
                        } label: {
                            Label("Restore to Suggestions", systemImage: "sparkles")
                        }

                        Button(role: .destructive) {
                            Task {
                                await viewModel.excludeUnassignedFace(faceId: face.id, rootFolderURL: rootFolderURL)
                            }
                        } label: {
                            Label("Not a Face (Move to Recycle Bin)", systemImage: "trash")
                        }
                    }
                    .onHover { h in
                        hoveredFaceId = h ? face.id : nil
                    }
                }
            }
            .padding(20)
        }
    }

    // MARK: - Bulk Assign Sheet

    @State private var bulkTargetPersonId: UUID? = nil
    @State private var bulkSearchQuery: String = ""

    private var filteredBulkTargets: [PersonDisplayModel] {
        let trimmed = bulkSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return viewModel.people }
        return viewModel.people.filter { $0.displayName.localizedCaseInsensitiveContains(trimmed) }
    }

    private var bulkAssignSheet: some View {
        VStack(spacing: 0) {
            // Sheet Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Assign \(selectedCount) Faces to Person")
                        .font(.headline)
                    Text("Select a person from your library to receive the selected faces.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: { showBulkAssignModal = false }) {
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
                TextField("Search people…", text: $bulkSearchQuery)
                    .textFieldStyle(.plain)
            }
            .padding(8)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)
            .padding(16)

            // Targets List
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(filteredBulkTargets) { target in
                        let isSelected = bulkTargetPersonId == target.id
                        Button(action: {
                            bulkTargetPersonId = target.id
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
                                    Text("\(target.uniquePhotoCount) photos • \(target.faceCount) faces")
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

            Divider()

            // Sheet Footer
            HStack {
                Button("Cancel") {
                    showBulkAssignModal = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Assign \(selectedCount) Faces") {
                    if let targetId = bulkTargetPersonId {
                        Task {
                            await viewModel.bulkAssignSelectedFaces(
                                toTargetPersonId: targetId,
                                rootFolderURL: rootFolderURL
                            )
                            showBulkAssignModal = false
                            bulkTargetPersonId = nil
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(bulkTargetPersonId == nil)
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 440, height: 420)
    }
}
