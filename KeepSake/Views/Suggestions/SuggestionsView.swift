import SwiftUI

/// Dedicated workspace for reviewing candidate face group suggestions proposed by identity clustering.
struct SuggestionsView: View {
    @ObservedObject var viewModel: PeopleViewModel
    let rootFolderURL: URL?
    var onChooseFolder: (() -> Void)? = nil

    private let columns = [
        GridItem(.adaptive(minimum: 180, maximum: 230), spacing: 20)
    ]

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
                    // Header / Subheader
                    suggestionsSubHeader

                    Divider()

                    // Main Content
                    if viewModel.candidateGroups.isEmpty {
                        emptyStateView
                    } else {
                        candidateGridScroll
                    }
                }
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .task(id: rootFolderURL) {
            await viewModel.loadData(rootFolderURL: rootFolderURL)
        }
        .sheet(isPresented: $viewModel.showAssignCandidateGroupSheet) {
            if let candidate = viewModel.candidateGroupToAssign {
                AssignCandidateGroupSheet(
                    candidate: candidate,
                    confirmedPeople: viewModel.people,
                    onAssignToPerson: { targetId in
                        Task {
                            await viewModel.assignCandidateGroup(candidate, toTargetPersonId: targetId, rootFolderURL: rootFolderURL)
                        }
                    },
                    onCancel: {
                        viewModel.showAssignCandidateGroupSheet = false
                        viewModel.candidateGroupToAssign = nil
                    }
                )
            }
        }
        .alert("Confirm Person Identity", isPresented: $viewModel.isConfirmingCandidate) {
            TextField("Person Name", text: $viewModel.confirmCandidateName)
            Button("Confirm") {
                if let cand = viewModel.candidateToConfirm {
                    let name = viewModel.confirmCandidateName.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task {
                        await viewModel.confirmCandidate(
                            candidate: cand,
                            name: name.isEmpty ? nil : name,
                            rootFolderURL: rootFolderURL
                        )
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                viewModel.isConfirmingCandidate = false
                viewModel.candidateToConfirm = nil
            }
        } message: {
            if let cand = viewModel.candidateToConfirm {
                Text("Confirm this suggestion (\(cand.faceCount) faces across \(cand.uniquePhotoCount) photos) as a recognized person identity:")
            }
        }
    }

    // MARK: - Sub Header

    private var suggestionsSubHeader: some View {
        HStack(spacing: 16) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Color.accentColor)
                Text("Candidate Suggestions")
                    .font(.headline)
            }

            Spacer()

            if !viewModel.candidateGroups.isEmpty {
                Text("\(viewModel.candidateGroups.count) pending review")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Grid Scroll

    private var candidateGridScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Review and confirm discovered face clusters as recognized people, or assign them to existing profiles.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(viewModel.candidateGroups) { candidate in
                        CandidateReviewCardView(
                            candidate: candidate,
                            onConfirm: {
                                viewModel.promptConfirmCandidate(for: candidate)
                            },
                            onAssign: {
                                viewModel.promptAssignCandidateGroup(candidate)
                            },
                            onReject: {
                                Task {
                                    await viewModel.rejectCandidate(candidate: candidate, rootFolderURL: rootFolderURL)
                                }
                            },
                            onClick: {
                                Task {
                                    await viewModel.selectPerson(candidate, rootFolderURL: rootFolderURL)
                                }
                            }
                        )
                    }
                }
            }
            .padding(24)
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 20) {
            if rootFolderURL == nil {
                Image(systemName: "folder.badge.questionmark")
                    .font(.system(size: 56))
                    .foregroundStyle(.secondary.opacity(0.6))

                VStack(spacing: 8) {
                    Text("No Folder Selected")
                        .font(.title2)
                        .fontWeight(.bold)

                    Text("Choose a folder to scan photos and discover face suggestions for review.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }

                if let onChooseFolder = onChooseFolder {
                    Button("Choose Folder…", action: onChooseFolder)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .padding(.top, 4)
                }
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.green.opacity(0.8))

                VStack(spacing: 8) {
                    Text("All Suggestions Reviewed")
                        .font(.title2)
                        .fontWeight(.bold)

                    Text("Keepsake has no pending identity suggestions for the active folder. New suggestions will appear here automatically as more faces are scanned and clustered.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
