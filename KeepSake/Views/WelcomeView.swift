import SwiftUI

/// First-launch and empty-library welcome experience for Keepsake.
struct WelcomeView: View {
    let onChooseFolder: () -> Void
    let onDropFolderURL: ((URL) -> Void)?
    var onNavigateToPeople: (() -> Void)? = nil
    var pendingCandidateCount: Int = 0
    var knownPeopleCount: Int = 0

    @State private var isTargetedForDrop: Bool = false

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            // App Icon & Hero Title
            VStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.accentColor.opacity(0.85), Color.blue],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 80, height: 80)
                        .shadow(color: Color.accentColor.opacity(0.35), radius: 12, x: 0, y: 6)

                    Image(systemName: "photo.stack.fill")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 44, height: 44)
                        .foregroundStyle(.white)
                }
                .accessibilityHidden(true)

                Text("Keepsake")
                    .font(.system(size: 34, weight: .bold, design: .rounded))

                Text("Your memories, organized privately.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            // Core Pillars / Value Propositions
            VStack(alignment: .leading, spacing: 18) {
                FeatureRow(
                    icon: "lock.shield.fill",
                    color: .green,
                    title: "100% On-Device & Private",
                    subtitle: "Your photos and personal face data never leave your Mac. Zero cloud uploads or telemetry."
                )

                FeatureRow(
                    icon: "person.2.crop.square.stack.fill",
                    color: .blue,
                    title: "Automatic People Galleries",
                    subtitle: "Local face detection groups matching faces into recognizable people with full renaming and merging controls."
                )

                FeatureRow(
                    icon: "sparkles",
                    color: .orange,
                    title: "Continuous Folder Monitoring",
                    subtitle: "Keepsake automatically notices new or modified photos as you add them to your folders."
                )
            }
            .frame(maxWidth: 440)
            .padding(.horizontal, 16)

            // Primary Action
            VStack(spacing: 12) {
                Button(action: onChooseFolder) {
                    Label("Choose Photo Folder…", systemImage: "folder.badge.plus")
                        .font(.headline)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .shadow(color: Color.accentColor.opacity(0.2), radius: 6, y: 3)
                .accessibilityLabel("Choose Photo Folder")
                .accessibilityHint("Opens native macOS folder picker to select a photo directory")

                if let onNavigateToPeople = onNavigateToPeople {
                    if pendingCandidateCount > 0 {
                        Button(action: onNavigateToPeople) {
                            Label("Review \(pendingCandidateCount) Candidate \(pendingCandidateCount == 1 ? "Suggestion" : "Suggestions")", systemImage: "sparkles")
                                .font(.subheadline.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .tint(.orange)
                        .controlSize(.regular)
                    } else if knownPeopleCount > 0 {
                        Button(action: onNavigateToPeople) {
                            Label("View Known People (\(knownPeopleCount))", systemImage: "person.2.fill")
                                .font(.subheadline)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                    }
                }

                Text("Or drag and drop a folder anywhere into this window")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .stroke(isTargetedForDrop ? Color.accentColor : Color.clear, lineWidth: 3)
                .background(Color(nsColor: .windowBackgroundColor))
        )
        .onDrop(of: ["public.file-url"], isTargeted: $isTargetedForDrop) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url = url else { return }
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                    DispatchQueue.main.async {
                        onDropFolderURL?(url)
                    }
                }
            }
            return true
        }
    }
}

private struct FeatureRow: View {
    let icon: String
    let color: Color
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 28)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
