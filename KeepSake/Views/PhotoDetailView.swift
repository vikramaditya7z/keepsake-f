import SwiftUI
import AppKit

enum PhotoFinderError: LocalizedError, Equatable {
    case invalidURL(String)
    case fileNotFound(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let name):
            return "Cannot resolve a valid file path for \"\(name)\"."
        case .fileNotFound(let path):
            return "The photo file could not be found at:\n\(path)"
        }
    }
}

enum PhotoFinderHelper {
    static func resolveAndValidateFileURL(for photo: PhotoItem, fileManager: FileManager = .default) -> Result<URL, PhotoFinderError> {
        let fileURL = photo.url.standardizedFileURL
        guard fileURL.isFileURL, !fileURL.path.isEmpty else {
            return .failure(.invalidURL(photo.filename))
        }
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return .failure(.fileNotFound(fileURL.path))
        }
        return .success(fileURL)
    }

    @discardableResult
    static func revealInFinder(for photo: PhotoItem, fileManager: FileManager = .default, opener: (([URL]) -> Void)? = nil) -> Result<URL, PhotoFinderError> {
        let result = resolveAndValidateFileURL(for: photo, fileManager: fileManager)
        if case .success(let fileURL) = result {
            if let opener = opener {
                opener([fileURL])
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            }
        }
        return result
    }
}

struct PhotoDetailView: View {
    let photo: PhotoItem
    let onDismiss: () -> Void
    let onPrevious: () -> Void
    let onNext: () -> Void
    let hasPrevious: Bool
    let hasNext: Bool

    @ObservedObject private var settings = AppSettings.shared
    @State private var fullImage: NSImage?
    @State private var isLoadingImage: Bool = true
    @State private var imageDimensions: CGSize?
    @State private var detectedFaces: [DetectedFace] = []
    @State private var isDetectingFaces: Bool = false
    @State private var showFaceOverlay: Bool = AppSettings.shared.showFaceOverlaysByDefault
    @State private var showRecognitionLab: Bool = false
    @State private var errorMessage: String?
    @State private var showErrorAlert: Bool = false

    private let faceDetector: any FaceDetectionServiceProtocol = VisionFaceDetectionService()

    var body: some View {
        ZStack {
            Color.black.opacity(0.88)
                .ignoresSafeArea()
                .onTapGesture {
                    onDismiss()
                }

            VStack(spacing: 0) {
                // Top Toolbar
                topToolbar

                // Main Image & Face Overlay Area
                ZStack {
                    if let image = fullImage, let dims = imageDimensions {
                        GeometryReader { geometry in
                            ZStack {
                                // Underlying Photo
                                Image(nsImage: image)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: geometry.size.width, height: geometry.size.height)
                                    .accessibilityLabel(Text("Photo: \(photo.filename)"))

                                // Face Detection Overlays
                                if showFaceOverlay && !detectedFaces.isEmpty {
                                    ForEach(detectedFaces) { face in
                                        let rect = CoordinateConverter.convertVisionBoundingBox(
                                            face.boundingBox,
                                            imageSize: dims,
                                            containerSize: geometry.size
                                        )

                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .stroke(Color.yellow, lineWidth: 2.5)
                                            .background(
                                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                    .fill(Color.yellow.opacity(0.12))
                                            )
                                            .shadow(color: .black.opacity(0.7), radius: 4, x: 0, y: 1)
                                            .frame(width: max(0, rect.width), height: max(0, rect.height))
                                            .position(x: rect.midX, y: rect.midY)
                                            .accessibilityLabel(Text("Detected Face"))
                                    }
                                }
                            }
                        }
                        .padding(20)
                    } else if isLoadingImage {
                        VStack(spacing: 12) {
                            ProgressView()
                                .controlSize(.large)
                            Text("Loading photo…")
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.8))
                        }
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "photo.badge.exclamationmark")
                                .font(.system(size: 40))
                                .foregroundStyle(.white.opacity(0.6))
                            Text("Unable to load photo")
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.8))
                        }
                    }

                    // Navigation Overlay Buttons
                    navigationButtons
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: photo.url) {
            await loadPhotoAndDetectFaces()
        }
        .sheet(isPresented: $showRecognitionLab) {
            FaceRecognitionExperimentView(
                photo: photo,
                detectedFaces: detectedFaces,
                onDismiss: {
                    showRecognitionLab = false
                }
            )
        }
        .alert("Unable to Show in Finder", isPresented: $showErrorAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            if let msg = errorMessage {
                Text(msg)
            }
        }
    }

    // MARK: - Top Toolbar

    private var topToolbar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(photo.filename)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)

                HStack(spacing: 12) {
                    Text(photo.formattedFileSize)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))

                    if let dims = imageDimensions {
                        Text("\(Int(dims.width)) × \(Int(dims.height))")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                    }

                    Text(photo.formattedDate)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }

            Spacer()

            // Face Detection Status Indicator
            HStack(spacing: 8) {
                if isDetectingFaces {
                    ProgressView()
                        .controlSize(.small)
                    Text("Detecting faces…")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.8))
                } else if !detectedFaces.isEmpty {
                    Label(
                        detectedFaces.count == 1 ? "1 face detected" : "\(detectedFaces.count) faces detected",
                        systemImage: "face.smiling"
                    )
                    .font(.subheadline)
                    .foregroundStyle(.yellow)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.yellow.opacity(0.2)))

                    Button(action: {
                        showFaceOverlay.toggle()
                    }) {
                        Image(systemName: showFaceOverlay ? "eye.fill" : "eye.slash.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("b", modifiers: [])
                    .help(showFaceOverlay ? "Hide Face Bounding Boxes (B)" : "Show Face Bounding Boxes (B)")
                    .accessibilityLabel("Toggle face boxes")

                    if settings.developerModeEnabled {
                        Button(action: {
                            showRecognitionLab = true
                        }) {
                            Label("Recognition Lab", systemImage: "cpu")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .tint(.purple)
                        .help("Open Face Recognition Experiment Lab (Developer)")
                    }
                } else if !isLoadingImage {
                    Text("No faces detected")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.white.opacity(0.1)))
                }
            }
            .padding(.trailing, 16)

            // Show in Finder
            Button(action: revealInFinder) {
                Image(systemName: "folder")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.white.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .help("Show in Finder")
            .accessibilityLabel("Show in Finder")
            .padding(.trailing, 10)

            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                .font(.system(size: 24))
                .foregroundStyle(.white.opacity(0.8))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close (Esc)")
            .accessibilityLabel("Close photo viewer")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color.black.opacity(0.55))
    }

    // MARK: - Navigation Buttons

    private var navigationButtons: some View {
        HStack {
            if hasPrevious {
                Button(action: onPrevious) {
                    Image(systemName: "chevron.left.circle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.white.opacity(0.75))
                        .background(Circle().fill(Color.black.opacity(0.4)))
                }
                .buttonStyle(.plain)
                .padding(.leading, 16)
                .keyboardShortcut(.leftArrow, modifiers: [])
                .help("Previous Photo (←)")
            }

            Spacer()

            if hasNext {
                Button(action: onNext) {
                    Image(systemName: "chevron.right.circle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.white.opacity(0.75))
                        .background(Circle().fill(Color.black.opacity(0.4)))
                }
                .buttonStyle(.plain)
                .padding(.trailing, 16)
                .keyboardShortcut(.rightArrow, modifiers: [])
                .help("Next Photo (→)")
            }
        }
    }

    // MARK: - Loading & Detection

    private func loadPhotoAndDetectFaces() async {
        isLoadingImage = true
        isDetectingFaces = true
        fullImage = nil
        imageDimensions = nil
        detectedFaces = []

        // 1. Load full resolution display image
        let image = await ThumbnailLoader.shared.loadFullImage(for: photo.url)
        self.fullImage = image

        if let image = image {
            self.imageDimensions = CGSize(width: image.size.width, height: image.size.height)
        }
        self.isLoadingImage = false

        // 2. Perform Apple Vision Face Detection
        do {
            let faces = try await faceDetector.detectFaces(in: photo.url)
            self.detectedFaces = faces
        } catch {
            print("Face detection failed for \(photo.filename): \(error.localizedDescription)")
            self.detectedFaces = []
        }
        self.isDetectingFaces = false
    }

    // MARK: - Finder Integration

    private func revealInFinder() {
        let result = PhotoFinderHelper.revealInFinder(for: photo)
        if case .failure(let error) = result {
            errorMessage = error.localizedDescription
            showErrorAlert = true
        }
    }
}
