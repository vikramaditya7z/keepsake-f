import SwiftUI

/// First-launch onboarding and setup modal allowing users to:
/// 1. Choose their photo library folder.
/// 2. Set up face recognition using local Buffalo S ONNX conversion or Core ML import.
/// 3. Defer or dismiss setup to browse immediately, with the ability to reopen anytime from Settings.
struct ModelSetupSheet: View {
    @ObservedObject var modelManager = ModelManager.shared
    @ObservedObject var settings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss

    var selectedFolderURL: URL? = nil
    var onChooseFolder: (() -> Void)? = nil
    var onSetupCompleted: (() -> Void)? = nil

    @State private var showInstructions: Bool = false

    private let converterRepoURL = URL(string: "https://github.com/devin-lai/onnx2coreml")!

    init(
        selectedFolderURL: URL? = nil,
        onChooseFolder: (() -> Void)? = nil,
        onSetupCompleted: (() -> Void)? = nil
    ) {
        self.selectedFolderURL = selectedFolderURL
        self.onChooseFolder = onChooseFolder
        self.onSetupCompleted = onSetupCompleted
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header with App Icon and Greeting
            VStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 38))
                    .foregroundStyle(Color.accentColor)
                    .padding(.top, 20)

                Text("Welcome to KeepSake")
                    .font(.title2.weight(.bold))

                Text("Complete these two steps to start organizing and recognizing faces in your photos, or continue now and set them up later.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }
            .padding(.bottom, 16)

            Divider()

            // Main Content Area
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // Step 1: Photo Folder Selection
                    photoFolderStepCard

                    // Step 2: Face Recognition Model Setup
                    faceRecognitionStepCard

                    // Deferral & Privacy Info
                    infoNoticeCard

                    // Attribution & Specifications Footer Link
                    HStack {
                        Link(destination: converterRepoURL) {
                            HStack(spacing: 5) {
                                Image(systemName: "arrow.up.right.square")
                                Text("Powered by onnx2coreml (BSD-3-Clause)")
                            }
                        }
                        .buttonStyle(.link)
                        .font(.caption)

                        Spacer()

                        Button("Technical Specifications…") {
                            showInstructions = true
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 4)
                }
                .padding(20)
            }

            Divider()

            // Footer Action Bar
            footerBar
        }
        .frame(width: 620, height: 580)
        .sheet(isPresented: $showInstructions) {
            ModelInstructionsSheet()
        }
    }

    // MARK: - Step 1: Photo Folder Selection Card

    private var photoFolderStepCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .font(.title3)
                    .foregroundStyle(.tint)

                Text("Step 1: Choose Your Photo Folder")
                    .font(.headline)

                Spacer()

                if selectedFolderURL != nil {
                    Label("Selected", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                }
            }

            Text("Select a folder on your Mac containing your photographs (JPEG, PNG, HEIC). KeepSake indexes your photos entirely on this device — your library is never uploaded anywhere.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let folderURL = selectedFolderURL {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(folderURL.lastPathComponent)
                            .font(.subheadline.weight(.semibold))
                        Text(folderURL.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Button("Change Folder…") {
                        onChooseFolder?()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(10)
                .background(Color.green.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Button(action: {
                    onChooseFolder?()
                }) {
                    Label("Choose Photo Folder…", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Step 2: Face Recognition Model Card

    private var faceRecognitionStepCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "cpu.fill")
                    .font(.title3)
                    .foregroundStyle(.tint)

                Text("Step 2: Set Up Face Recognition")
                    .font(.headline)

                Spacer()

                if modelManager.hasUserInstalledModel {
                    Label("Ready", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                }
            }

            Text("To detect and cluster people across your photos, KeepSake needs a Buffalo S recognition model (w600k_mbf.onnx). Select your ONNX model, and KeepSake will convert and install it locally on your Mac.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if modelManager.status.isConverting {
                conversionProgressView
            } else if modelManager.hasUserInstalledModel, case .ready(let name, _, _) = modelManager.status {
                readyStatusCard(modelName: name)
            } else {
                HStack(spacing: 12) {
                    Button(action: {
                        modelManager.chooseONNXModel()
                    }) {
                        Label("Choose ONNX Model…", systemImage: "bolt.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(modelManager.isValidating)

                    Button("Import Core ML…") {
                        modelManager.chooseModel()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .disabled(modelManager.isValidating)
                }

                if case .error(let message) = modelManager.status {
                    errorCard(message: message)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Info Notice Card

    private var infoNoticeCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("You can complete either step now or later. If you continue without face recognition, you can still browse photos, and setup can be reopened at any time from Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Footer Bar

    private var footerBar: some View {
        HStack(spacing: 12) {
            Button("Set Up Later") {
                completeAndDismiss()
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .disabled(modelManager.status.isConverting)

            Spacer()

            if modelManager.status.isConverting {
                Button("Cancel Conversion") {
                    modelManager.cancelConversion()
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            } else if modelManager.hasUserInstalledModel || selectedFolderURL != nil {
                Button("Get Started") {
                    completeAndDismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            } else {
                Button("Continue to KeepSake") {
                    completeAndDismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func completeAndDismiss() {
        settings.hasCompletedOnboarding = true
        settings.hasCompletedModelSetup = true
        onSetupCompleted?()
        dismiss()
    }

    // MARK: - Subviews

    private var conversionProgressView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.blue)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Converting Model to Core ML…")
                        .font(.subheadline.weight(.semibold))
                    Text(modelManager.conversionMessage.isEmpty ? "Processing layers..." : modelManager.conversionMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(Int(modelManager.conversionProgress * 100))%")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: modelManager.conversionProgress, total: 1.0)
                .progressViewStyle(.linear)

            Text("Conversion runs 100% locally on your Mac. No internet connection or command-line tools are required.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color.blue.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func readyStatusCard(modelName: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)

            VStack(alignment: .leading, spacing: 3) {
                Text("Face Recognition Ready")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.green)

                Text(modelName)
                    .font(.caption)
                    .foregroundStyle(.primary)

                Text("Converted and installed locally. Photos will be recognized using 512-D neural embeddings.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Replace…") {
                modelManager.chooseONNXModel()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(12)
        .background(Color.green.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func errorCard(message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.red)

            VStack(alignment: .leading, spacing: 2) {
                Text("Conversion or Installation Failed")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.red)

                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color.red.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// Detailed specification sheet explaining model compatibility and conversion.
struct ModelInstructionsSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let converterURL = URL(string: "https://github.com/devin-lai/onnx2coreml")!

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Model Conversion & Technical Details")
                    .font(.headline)
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Section {
                        Text("KeepSake includes an integrated converter based on onnx2coreml to transform standard InsightFace ONNX models directly into native Apple Core ML packages.")
                            .font(.body)
                    }

                    Section(header: Text("Supported Model Architecture").font(.headline)) {
                        VStack(alignment: .leading, spacing: 8) {
                            bulletPoint(title: "Architecture", desc: "InsightFace MobileFaceNet / buffalo_s (w600k_mbf.onnx).")
                            bulletPoint(title: "Input Tensor", desc: "112×112 planar RGB. Dynamic batch dimension is automatically fixed to 1 during conversion.")
                            bulletPoint(title: "Output Embedding", desc: "512-dimensional float vector.")
                            bulletPoint(title: "Target Output", desc: "Apple Core ML Package (.mlpackage) with FP16 precision.")
                        }
                    }

                    Section(header: Text("Converter Engine & License").font(.headline)) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Conversion is powered locally by onnx2coreml (BSD-3-Clause License) and Apple coremltools.")
                                .font(.subheadline)

                            Link(destination: converterURL) {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.up.right.square")
                                    Text("View onnx2coreml on GitHub")
                                        .fontWeight(.medium)
                                }
                            }
                            .font(.caption)
                        }
                    }

                    Section(header: Text("Licensing & Privacy").font(.headline)) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("• 100% Local Inference: All conversion and face recognition execute strictly on your Mac without external server connections.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("• Model Licenses: Pretrained weights are governed by their respective authors' licenses, independent of KeepSake's software license.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section(header: Text("Managing Models Later").font(.headline)) {
                        Text("You can inspect, replace, reload, or clear your installed model at any time from KeepSake Settings → Model tab.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 540, height: 480)
    }

    private func bulletPoint(title: String, desc: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•")
                .fontWeight(.bold)
            Text("**\(title):** \(desc)")
                .font(.subheadline)
        }
    }
}
