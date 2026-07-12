import SwiftUI
import MetalKit
import UniformTypeIdentifiers

/// Root view. State lives here; the grid, compare, filmstrip, and input-handling
/// behaviour is split across `ContentView+*.swift` extension files. Those
/// extensions are part of the same type, so members shared across the file
/// boundary are `internal` (not `private`).
struct ContentView: View {
    @EnvironmentObject var session: CullingSession
    @EnvironmentObject var keybindings: KeybindingStore
    @Environment(\.ciContext) var ciContext
    @Environment(\.metalDevice) var metalDevice

    @State var currentTexture: MTLTexture?
    @State var decoder: ImageDecoder?
    @State var prefetchManager: PrefetchManager?
    @State var diskCache: DiskCacheManager?
    @StateObject var buildProgress = PreviewBuildProgress()
    @State var isLoading = false
    @State var showDeleteConfirmation = false
    /// Indices to delete when the confirmation dialog is accepted.
    /// `nil` means "delete the current photo only" (legacy single-file path).
    @State var pendingDeletionIndices: Set<Int>? = nil
    @State var decodeTimeMs: Double = 0
    @State var keyMonitor: Any?
    @State var currentDecodeTask: Task<Void, Never>?
    @State var focusPeakingEnabled = false
    @State var thumbnails: [URL: NSImage] = [:]
    @State var thumbnailLoadTask: Task<Void, Never>?
    @State var zoomScale: CGFloat = 1.0
    @State var panOffset: CGPoint = .zero
    @State var scrollMonitor: Any?
    @State var dragMonitor: Any?
    @State var lastDragPoint: NSPoint?
    @State var showGrid = false
    @State var selectedIndices: Set<Int> = []
    @State var gridFilter: GridFilter = .all
    @State var compareMode = false
    @State var compareIndices: [Int] = []
    @State var compareActiveSlot: Int = 0  // which photo is "active" for rating
    @State var compareTextures: [Int: MTLTexture] = [:]

    enum GridFilter: String, CaseIterable {
        case all = "All"
        case favorites = "♥ Favorites"
        case rejected = "✗ Rejected"
        case rated = "★ Rated"
        case unrated = "Unrated"
    }

    /// Target decode size for full previews — 4K on GPUs that report a working
    /// set (effectively all real hardware), 1080p as a conservative fallback.
    /// Centralised here so every decode path agrees on one size.
    var previewDisplaySize: CGSize {
        let supports4K = (metalDevice?.recommendedMaxWorkingSetSize ?? 0) > 0
        return CGSize(width: supports4K ? 3840 : 1920,
                      height: supports4K ? 2160 : 1080)
    }

    var body: some View {
        ZStack {
            Color(nsColor: NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1.0))
                .ignoresSafeArea()

            if ciContext == nil {
                // Loading screen while CIContext initializes
                VStack(spacing: 16) {
                    Text("Hayate")
                        .font(.system(size: 36, weight: .bold))
                        .foregroundColor(.white)
                    Text("RAW Photo Culling")
                        .font(.system(size: 14))
                        .foregroundColor(.gray)
                    ProgressView()
                        .controlSize(.small)
                        .padding(.top, 8)
                }
            } else if session.files.isEmpty {
                // "Open Folder" prompt
                VStack(spacing: 16) {
                    Text("Hayate")
                        .font(.system(size: 36, weight: .bold))
                        .foregroundColor(.white)
                    Text("RAW Photo Culling")
                        .font(.system(size: 14))
                        .foregroundColor(.gray)

                    Button("Open Folder...") {
                        session.requestOpenFolder()
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else if showGrid {
                gridView
            } else if compareMode {
                compareView
            } else {
                // Single photo view
                if let device = metalDevice {
                    MetalImageView(texture: currentTexture, device: device, zoomScale: zoomScale, panOffset: panOffset)
                }

                // Bottom overlay: filmstrip + status bar
                VStack(spacing: 0) {
                    Spacer()
                    filmstrip
                    statusBar
                }
            }
        }
        .onAppear {
            initializeDecoder()
            installKeyHandler()
        }
        .onChange(of: ciContext != nil) { _, available in
            // Re-initialize decoder when CIContext becomes available (async load)
            if available && decoder == nil {
                initializeDecoder()
            }
        }
        .onDisappear {
            removeKeyHandler()
        }
        .confirmationDialog(
            deletionDialogTitle,
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                if let indices = pendingDeletionIndices {
                    let deleted = session.deleteFilesAtIndices(indices)
                    selectedIndices.removeAll()
                    pendingDeletionIndices = nil
                    if deleted > 0 {
                        loadCurrentImage()
                    }
                } else {
                    _ = session.deleteCurrentFile()
                    loadCurrentImage()
                }
            }
            Button("Cancel", role: .cancel) {
                pendingDeletionIndices = nil
            }
        } message: {
            Text(deletionDialogMessage)
        }
        .onChange(of: session.currentIndex) { _, _ in
            loadCurrentImage()
        }
        .onChange(of: session.openFolderRequest) { _, _ in
            // Defer out of the SwiftUI update cycle — calling NSOpenPanel.runModal()
            // synchronously from within .onChange prevents the panel from appearing.
            DispatchQueue.main.async {
                openFolderDialog()
            }
        }
    }

    // MARK: - Setup

    private func initializeDecoder() {
        guard let ciContext = ciContext, let device = metalDevice else { return }
        let dec = ImageDecoder(ciContext: ciContext, device: device)
        decoder = dec
        let dc = DiskCacheManager(cacheRoot: DiskCacheManager.userConfiguredCacheRoot)
        diskCache = dc
        prefetchManager = PrefetchManager(decoder: dec, device: device, diskCache: dc, buildProgress: buildProgress)
    }

    // MARK: - Deletion dialog

    private var deletionDialogTitle: String {
        if let count = pendingDeletionIndices?.count, count > 1 {
            return "Delete \(count) photos?"
        }
        return "Delete this photo?"
    }

    private var deletionDialogMessage: String {
        if let indices = pendingDeletionIndices {
            if indices.count == 1, let only = indices.first, session.files.indices.contains(only) {
                return session.files[only].lastPathComponent
            }
            return "Move \(indices.count) selected photos to Trash."
        }
        return session.currentFile?.lastPathComponent ?? ""
    }

    // MARK: - Folder handling

    private func openFolderDialog() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a folder containing RAW photos"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        // Only wipe view state if the session successfully switched folders;
        // otherwise we'd clear the screen while still pointing at the old folder.
        guard session.openFolder(url) else { return }
        resetViewState()
        loadCurrentImage()
        startBackgroundBuild()
    }

    private func startBackgroundBuild() {
        guard let prefetchManager = prefetchManager else { return }
        let files = session.files
        let displaySize = previewDisplaySize
        Task {
            await prefetchManager.startBackgroundBuild(files: files, displaySize: displaySize)
        }
    }

    /// Clear all view-local state when switching to a new folder mid-session.
    /// Session-level state (files, entries, undoStack) is reset by `CullingSession.openFolder`.
    /// The `decoder` and `prefetchManager` instances are kept — they're bound to CIContext/device,
    /// not to a specific folder.
    private func resetViewState() {
        // Cancel in-flight work
        currentDecodeTask?.cancel()
        currentDecodeTask = nil
        thumbnailLoadTask?.cancel()
        thumbnailLoadTask = nil

        // Textures / decode results
        currentTexture = nil
        thumbnails.removeAll()
        decodeTimeMs = 0
        isLoading = false

        // Drop cached decodes from the previous folder. Cache keys are absolute URLs,
        // so a not-yet-completed clear() can't cause stale hits in the new folder.
        if let pm = prefetchManager {
            Task { await pm.clear() }
        }

        // Grid / Compare / selection
        showGrid = false
        selectedIndices.removeAll()
        gridFilter = .all
        compareMode = false
        compareIndices.removeAll()
        compareActiveSlot = 0
        compareTextures.removeAll()

        // View helpers
        focusPeakingEnabled = false
    }

    // MARK: - Navigation

    func navigateForward() {
        session.navigateForward()
    }

    func navigateBack() {
        session.navigateBack()
    }

    // MARK: - Image loading

    func loadCurrentImage() {
        // Cancel any in-flight decode. Only the latest navigation matters.
        currentDecodeTask?.cancel()
        // Reset zoom for new photo
        resetZoom()

        guard let file = session.currentFile,
              let decoder = decoder else {
            currentTexture = nil
            return
        }

        // Fire the neighbor prefetch in its own Task so rapid navigation can't
        // cancel it. (Previously this lived at the tail of the decode Task and
        // got wiped on every keystroke during fast culling — neighbors never
        // actually warmed up.)
        if let prefetchManager = prefetchManager {
            let currentIdx = session.currentIndex
            let allFiles = session.files
            let prefetchSize = CGSize(width: 3840, height: 2160)
            Task {
                await prefetchManager.prefetch(
                    currentIndex: currentIdx,
                    files: allFiles,
                    displaySize: prefetchSize
                )
            }
        }

        isLoading = true
        let start = CFAbsoluteTimeGetCurrent()

        currentDecodeTask = Task {
            let displaySize = previewDisplaySize

            if focusPeakingEnabled {
                // Focus peaking: decode directly to texture (not cached)
                if let sendable = await decoder.decodeRAW(url: file, displaySize: displaySize, focusPeaking: true) {
                    guard !Task.isCancelled else { return }
                    currentTexture = sendable.texture
                    decodeTimeMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
                    isLoading = false
                }
                return
            }

            // Unified pipeline: memory → disk → embedded JPEG (partial) → RAW
            guard let prefetchManager = prefetchManager else { return }
            let result = await prefetchManager.loadTexture(for: file, displaySize: displaySize) { partial in
                currentTexture = partial.texture
                decodeTimeMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
            }
            guard !Task.isCancelled, let result = result else { return }
            currentTexture = result.texture
            decodeTimeMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
            isLoading = false
        }
    }

    func loadThumbnail(for url: URL) {
        guard let decoder = decoder else { return }
        let cache = diskCache
        Task.detached(priority: .utility) {
            if let cache = cache, let cgImage = await cache.loadThumbnail(for: url) {
                let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                await MainActor.run { thumbnails[url] = nsImage }
                return
            }

            guard let cgImage = await decoder.extractThumbnail(url: url) else { return }
            let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            await MainActor.run { thumbnails[url] = nsImage }

            if let cache = cache {
                await cache.storeThumbnail(cgImage: cgImage, for: url)
            }
        }
    }
}
