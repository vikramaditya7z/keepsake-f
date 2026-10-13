//
//  RecycleBinView.swift
//  KeepSake
//
//  Created for V7 Remediation & Follow-up — Two Distinct Recovery Workflows.
//

import SwiftUI

enum RecycleBinTab: String, CaseIterable, Identifiable {
    case falseDetections = "False Detections"
    case removedFromPeople = "Removed from People"

    var id: String { rawValue }
}

struct RecycleBinView: View {
    @ObservedObject var viewModel: PeopleViewModel
    let rootFolderURL: URL?
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTab: RecycleBinTab = .falseDetections

    // Category A state (False Detections)
    @State private var faceToDelete: FaceDisplayModel? = nil
    @State private var showConfirmDeleteSingle: Bool = false
    @State private var showConfirmEmptyBin: Bool = false

    // Category B state (Removed from People)
    @State private var assocToDelete: RemovedAssociationDisplayModel? = nil
    @State private var showConfirmDeleteAssoc: Bool = false
    @State private var showConfirmEmptyAssocBin: Bool = false

    private let columns = [
        GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 16)
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            Divider()

            // Segmented Picker Bar
            tabPickerBar

            Divider()

            // Main Content Area
            if selectedTab == .falseDetections {
                falseDetectionsContent
            } else {
                removedFromPeopleContent
            }

            Divider()

            // Safety Footer
            safetyFooter
        }
        .frame(minWidth: 700, minHeight: 520)
        // Confirmation dialogs
        .confirmationDialog(
            "Delete Face Record Permanently?",
            isPresented: $showConfirmDeleteSingle,
            presenting: faceToDelete
        ) { face in
            Button("Delete Permanently", role: .destructive) {
                Task {
                    await viewModel.permanentlyDeleteFace(faceId: face.id, rootFolderURL: rootFolderURL)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { face in
            Text("This permanently removes the detected face record from KeepSake. The original photo \"\(face.filename)\" will not be deleted or modified.")
        }
        .confirmationDialog(
            "Empty False Detections?",
            isPresented: $showConfirmEmptyBin
        ) {
            Button("Delete All Permanently", role: .destructive) {
                Task {
                    await viewModel.emptyRecycleBin(rootFolderURL: rootFolderURL)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Permanently removes \(viewModel.recycleBinFaces.count) false detection records. All original photo files remain completely safe and untouched.")
        }
        .confirmationDialog(
            "Permanently Delete Removed Association?",
            isPresented: $showConfirmDeleteAssoc,
            presenting: assocToDelete
        ) { assoc in
            Button("Delete Permanently", role: .destructive) {
                Task {
                    await viewModel.permanentlyDeleteRemovedAssociation(assoc.id, rootFolderURL: rootFolderURL)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { assoc in
            Text("This permanently discards the history for this removed association from \"\(assoc.personName)\". The face record will be permanently deleted. The original photo \"\(assoc.filename)\" will not be deleted or modified.")
        }
        .confirmationDialog(
            "Empty Removed Associations Bin?",
            isPresented: $showConfirmEmptyAssocBin
        ) {
            Button("Delete All Permanently", role: .destructive) {
                Task {
                    await viewModel.emptyRemovedAssociations(rootFolderURL: rootFolderURL)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Permanently removes \(viewModel.removedAssociations.count) removed association records. All original photo files remain completely safe and untouched.")
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Image(systemName: "trash")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("Recycle Bin")
                        .font(.title2.bold())
                }
                Text("Review false detections and faces removed from people. Original photo files are never modified or deleted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 10) {
                if selectedTab == .falseDetections {
                    if !viewModel.recycleBinFaces.isEmpty {
                        Button("Restore All") {
                            Task {
                                await viewModel.restoreAllRecycleBinFaces(rootFolderURL: rootFolderURL)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button(role: .destructive) {
                            showConfirmEmptyBin = true
                        } label: {
                            Label("Empty Bin", systemImage: "trash.slash")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                } else {
                    if !viewModel.removedAssociations.isEmpty {
                        Button("Restore All to Unassigned") {
                            Task {
                                await viewModel.restoreAllRemovedAssociations(rootFolderURL: rootFolderURL)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button(role: .destructive) {
                            showConfirmEmptyAssocBin = true
                        } label: {
                            Label("Empty Bin", systemImage: "trash.slash")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Tab Picker Bar

    private var tabPickerBar: some View {
        HStack {
            Picker("Recycle Bin Section", selection: $selectedTab) {
                Text("False Detections (\(viewModel.recycleBinFaces.count))")
                    .tag(RecycleBinTab.falseDetections)
                Text("Removed from People (\(viewModel.removedAssociations.count))")
                    .tag(RecycleBinTab.removedFromPeople)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 400)

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Tab 1: False Detections Content

    @ViewBuilder
    private var falseDetectionsContent: some View {
        if viewModel.recycleBinFaces.isEmpty {
            VStack(spacing: 16) {
                Image(systemName: "trash.slash")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary.opacity(0.5))
                Text("No False Detections")
                    .font(.headline)
                Text("Faces marked as \"Not a Face\" or false detections will appear here.\nYou can restore them to unassigned faces at any time.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(40)
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(viewModel.recycleBinFaces) { face in
                        falseDetectionFaceCard(face)
                    }
                }
                .padding(20)
            }
        }
    }

    private func falseDetectionFaceCard(_ face: FaceDisplayModel) -> some View {
        VStack(spacing: 10) {
            FaceCropThumbnailView(
                faceId: face.id,
                photoURL: face.photoURL,
                boundingBox: face.boundingBox,
                size: 90,
                isCircular: true
            )
            .overlay(
                Circle()
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
            )

            VStack(spacing: 2) {
                Text(face.filename)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text("False Detection")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button {
                    Task {
                        await viewModel.restoreFaceFromRecycleBin(faceId: face.id, rootFolderURL: rootFolderURL)
                    }
                } label: {
                    Label("Restore", systemImage: "arrow.uturn.backward")
                        .font(.caption2)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .help("Restore this face to Unassigned Faces")

                Button(role: .destructive) {
                    faceToDelete = face
                    showConfirmDeleteSingle = true
                } label: {
                    Image(systemName: "trash")
                        .font(.caption2)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .help("Permanently delete this face detection record")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }

    // MARK: - Tab 2: Removed from People Content

    @ViewBuilder
    private var removedFromPeopleContent: some View {
        if viewModel.removedAssociations.isEmpty {
            VStack(spacing: 16) {
                Image(systemName: "person.crop.circle.badge.minus")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary.opacity(0.5))
                Text("No Removed Associations")
                    .font(.headline)
                Text("Face associations removed from confirmed people will appear here.\nYou can restore them back to the original person or to Unassigned Faces.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(40)
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(viewModel.removedAssociations) { assoc in
                        removedAssociationCard(assoc)
                    }
                }
                .padding(20)
            }
        }
    }

    private func removedAssociationCard(_ assoc: RemovedAssociationDisplayModel) -> some View {
        let personStillExists = viewModel.people.contains(where: { $0.id == assoc.personId })
        return VStack(spacing: 10) {
            FaceCropThumbnailView(
                faceId: assoc.faceId,
                photoURL: assoc.photoURL,
                boundingBox: assoc.boundingBox,
                size: 90,
                isCircular: true
            )
            .overlay(
                Circle()
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
            )

            VStack(spacing: 2) {
                Text(assoc.filename)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text("Removed from \(assoc.personName)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(assoc.removedAt, style: .date)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            VStack(spacing: 6) {
                if personStillExists {
                    Button {
                        Task {
                            await viewModel.restoreRemovedAssociationToPerson(assoc.id, rootFolderURL: rootFolderURL)
                        }
                    } label: {
                        Label("Restore to \(assoc.personName)", systemImage: "arrow.uturn.backward")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                    .help("Restore this face back to \(assoc.personName)")
                }

                HStack(spacing: 6) {
                    Button {
                        Task {
                            await viewModel.restoreRemovedAssociationToUnassigned(assoc.id, rootFolderURL: rootFolderURL)
                        }
                    } label: {
                        Label("To Unassigned", systemImage: "person.crop.circle.badge.questionmark")
                            .font(.caption2)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .help("Restore this face to Unassigned Faces")

                    Button(role: .destructive) {
                        assocToDelete = assoc
                        showConfirmDeleteAssoc = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption2)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .help("Permanently delete this face record")
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }

    // MARK: - Safety Footer

    private var safetyFooter: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.shield.fill")
                .foregroundStyle(.green)
            Text("Photographs on disk are never deleted or modified.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
