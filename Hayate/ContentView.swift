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
    /// EXIF info overlay (I key).
    @State var showInfo = false
    @State var currentEXIF: EXIFInfo?
    /// Histogram overlay (H key).
    @State var showHistogram = false
    @State var histogramData: HistogramData?
    /// Export sheet (File > Export Picks…).
    @State var showExportSheet = false
    @State var thumbnails: [URL: NSImage] = [:]
    /// Insertion order of `thumbnails` keys, oldest first, for capped eviction.
    @State var thumbnailOrder: [URL] = []
    @State var thumbnailLoadTask: Task<Void, Never>?

    /// Cap on the in-memory thumbnail dictionary. ~0.5 MB per 400px thumbnail,
    /// so 600 entries ≈ 300 MB worst case. Evicted thumbnails reload on demand
    /// via the placeholder's onAppear.
    static let thumbnailCacheLimit = 600
    @State var zoomScale: CGFloat = 1.0
    @State var panOffset: CGPoint = .zero
    /// In-flight full-resolution decode for zoom. `fullResURL` marks the file
    /// being decoded (retrigger guard); `fullResDisplayedURL` marks the file
    /// whose full-res texture actually sits in `currentTexture` — only then
    /// must the preview pipeline avoid downgrading it.
    @State var fullResTask: Task<Void, Never>?
    @State var fullResURL: URL?
    @State var fullResDisplayedURL: URL?
    @State var scrollMonitor: Any?
    @State var dragMonitor: Any?
    @State var lastDragPoint: NSPoint?
    @State var showGrid = false
    @State var selectedIndices: Set<Int> = []
    @State var gridFilter: GridFilter = .all
    /// Approximate column count of the adaptive grid, for ↑↓ row navigation.
    @State var gridColumnCount = 5
    /// File indices that start a new scene (EXIF time gap). Empty when off / loading.
    @State var sceneStartIndices: Set<Int> = []
    @State var captureDateTask: Task<Void, Never>?
    /// Gap (minutes) between shots that draws a scene separator in the grid. 0 = off.
    @AppStorage("sceneGapMinutes") var sceneGapMinutes = 15
    /// Advance to the next photo automatically after rating/favorite/reject.
    @AppStorage("autoAdvance") var autoAdvance = false
    /// Draft cull mode: stop at embedded JPEG / disk cache; full RAW only for
    /// focus peaking and zoom. Maximises navigation throughput.
    @AppStorage("cullModeDraft") var cullModeDraft = false
    /// Filmstrip / grid: desaturate non-favorites so Keep photos stand out.
    /// The main Metal viewer always stays full color.
    @AppStorage("colorizeKeepOnly") var colorizeKeepOnly = true
    /// Keep / Maybe / Out instead of 1–5 stars (stored via favorite / rating / reject).
    @AppStorage("cullingProfileTriage") var cullingProfileTriage = true
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
        case keep = "Keep"
        case maybe = "Maybe"
        case out = "Out"
        case undecided = "Undecided"

        static func visible(triage: Bool) -> [GridFilter] {
            triage
                ? [.all, .keep, .maybe, .out, .undecided]
                : [.all, .favorites, .rejected, .rated, .unrated]
        }
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
                HayateBrandScreen(mode: .loading)
            } else if session.files.isEmpty {
                HayateBrandScreen(mode: .empty(onOpen: { session.requestOpenFolder() }))
            } else if showGrid {
                gridView
            } else if compareMode {
                compareView
            } else {
                // Single photo view
                if let device = metalDevice {
                    MetalImageView(texture: currentTexture, device: device, zoomScale: zoomScale, panOffset: panOffset)
                }

                // Top-left overlay: EXIF info (I key)
                if showInfo {
                    VStack {
                        HStack {
                            exifOverlay
                            Spacer()
                        }
                        Spacer()
                    }
                }

                // Top-right overlay: histogram (H key)
                if showHistogram, let histogramData = histogramData {
                    VStack {
                        HStack {
                            Spacer()
                            HistogramView(data: histogramData)
                                .padding(12)
                        }
                        Spacer()
                    }
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
        .onChange(of: session.directOpenRequest) { _, url in
            guard let url = url else { return }
            session.directOpenRequest = nil
            openFolderAndReload(url)
        }
        .onChange(of: session.exportRequest) { _, request in
            guard request != nil, !session.files.isEmpty else { return }
            showExportSheet = true
        }
        .onChange(of: decodeTimeMs) { _, _ in
            // decodeTimeMs bumps on every texture swap in loadCurrentImage —
            // cheap signal to keep the histogram in sync with the display.
            if showHistogram {
                updateHistogram()
            }
        }
        .onChange(of: cullModeDraft) { _, draft in
            // Switching modes mid-session: reload the current photo and
            // restart (or quiet) the background preview builder.
            if !session.files.isEmpty {
                loadCurrentImage()
                if draft {
                    Task { await prefetchManager?.stopBackgroundBuild() }
                } else {
                    startBackgroundBuild()
                }
            }
        }
        .sheet(isPresented: $showExportSheet) {
            ExportSheet(onBulkDelete: {
                // The displayed photo may have been trashed; currentIndex can
                // keep its numeric value after reindexing, so onChange alone
                // won't reload.
                selectedIndices.removeAll()
                loadCurrentImage()
            })
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil),
                      (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return }
                DispatchQueue.main.async {
                    openFolderAndReload(url)
                }
            }
            return true
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
        openFolderAndReload(url)
    }

    /// Shared open-folder flow used by the dialog, the recent-folders menu,
    /// and drag & drop. Only wipes view state if the session successfully
    /// switched folders; otherwise the screen keeps showing the old folder.
    func openFolderAndReload(_ url: URL) {
        guard session.openFolder(url) else {
            // Deleted or unmounted folder from the recents menu — drop it.
            session.removeFromRecents(url)
            return
        }
        resetViewState()
        loadCurrentImage()
        startBackgroundBuild()
    }

    func startBackgroundBuild() {
        guard let prefetchManager = prefetchManager else { return }
        let files = session.files
        let displaySize = previewDisplaySize
        let draft = cullModeDraft
        Task {
            await prefetchManager.startBackgroundBuild(files: files, displaySize: displaySize, draft: draft)
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
        cancelFullResolutionLoad()
        thumbnailLoadTask?.cancel()
        thumbnailLoadTask = nil
        captureDateTask?.cancel()
        captureDateTask = nil
        sceneStartIndices = []

        // Textures / decode results
        currentTexture = nil
        thumbnails.removeAll()
        thumbnailOrder.removeAll()
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
        showInfo = false
        currentEXIF = nil
        showHistogram = false
        histogramData = nil
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
        cancelFullResolutionLoad()
        // Reset zoom for new photo
        resetZoom()

        guard let file = session.currentFile,
              let decoder = decoder else {
            currentTexture = nil
            return
        }

        if showInfo {
            loadEXIF()
        }

        // Fire the neighbor prefetch in its own Task so rapid navigation can't
        // cancel it. (Previously this lived at the tail of the decode Task and
        // got wiped on every keystroke during fast culling — neighbors never
        // actually warmed up.)
        if let prefetchManager = prefetchManager {
            let currentIdx = session.currentIndex
            let allFiles = session.files
            let prefetchSize = previewDisplaySize
            let draft = cullModeDraft
            Task {
                await prefetchManager.prefetch(
                    currentIndex: currentIdx,
                    files: allFiles,
                    displaySize: prefetchSize,
                    draft: draft
                )
            }
        }

        isLoading = true
        let start = CFAbsoluteTimeGetCurrent()

        currentDecodeTask = Task {
            let displaySize = previewDisplaySize

            if focusPeakingEnabled {
                // Focus peaking always needs a full RAW decode (even in Draft).
                if let sendable = await decoder.decodeRAW(url: file, displaySize: displaySize, focusPeaking: true) {
                    guard !Task.isCancelled else { return }
                    currentTexture = sendable.texture
                    decodeTimeMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
                    isLoading = false
                } else if !Task.isCancelled {
                    // Decode failed — don't leave the spinner on.
                    isLoading = false
                }
                return
            }

            // Unified pipeline: memory → disk → embedded JPEG [(partial) → RAW]
            // Draft stops after JPEG; Full continues to RAW.
            guard let prefetchManager = prefetchManager else { return }
            let draft = cullModeDraft
            let result = await prefetchManager.loadTexture(for: file, displaySize: displaySize, draft: draft) { partial in
                // Defensive: don't overwrite a newer photo if this task was
                // cancelled while hopping to the main actor, and don't
                // downgrade a full-resolution texture the user zoomed into.
                guard !Task.isCancelled, fullResDisplayedURL != file else { return }
                currentTexture = partial.texture
                decodeTimeMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
            }
            guard !Task.isCancelled else { return }
            guard let result = result else {
                // Every stage failed (corrupt file etc.) — don't leave the
                // spinner on forever. Cancelled tasks return above; a newer
                // load owns the UI state in that case.
                isLoading = false
                return
            }
            if fullResDisplayedURL != file {
                currentTexture = result.texture
            }
            decodeTimeMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
            isLoading = false
        }
    }

    // MARK: - EXIF overlay

    @ViewBuilder
    var exifOverlay: some View {
        if let info = currentEXIF {
            VStack(alignment: .leading, spacing: 4) {
                if let camera = info.camera {
                    Text(camera).fontWeight(.semibold)
                }
                if let lens = info.lens {
                    Text(lens)
                }
                if !info.exposureLine.isEmpty {
                    Text(info.exposureLine.joined(separator: "  "))
                }
                if let date = info.dateTaken {
                    Text(date).foregroundColor(.gray)
                }
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(.white)
            .padding(10)
            .background(Color.black.opacity(0.65))
            .cornerRadius(6)
            .padding(12)
        }
    }

    /// Fetch EXIF for the current photo (called on toggle and on navigation
    /// while the overlay is visible).
    func loadEXIF() {
        guard let file = session.currentFile, let decoder = decoder else {
            currentEXIF = nil
            return
        }
        Task {
            let info = await decoder.extractEXIF(url: file)
            // Ignore late results after further navigation.
            if session.currentFile == file {
                currentEXIF = info
            }
        }
    }

    // MARK: - Histogram

    /// Recompute the histogram from the currently displayed texture.
    func updateHistogram() {
        guard showHistogram, let texture = currentTexture, let decoder = decoder else {
            histogramData = nil
            return
        }
        let sendable = SendableTexture(texture: texture)
        let file = session.currentFile
        Task {
            let data = await decoder.computeHistogram(texture: sendable)
            // Only apply if the histogram is still showing and the user
            // hasn't navigated away (results can complete out of order).
            if showHistogram, session.currentFile == file {
                histogramData = data
            }
        }
    }

    // MARK: - Full-resolution zoom

    /// Decode the current photo at full resolution when zoomed in, swapping it
    /// into `currentTexture` when ready. No-op if already loaded or loading for
    /// this file. The texture is intentionally not cached — full-res textures
    /// are large (~200 MB for 45 MP) and only one is alive at a time.
    func loadFullResolutionIfNeeded() {
        guard zoomScale > 1.01, !focusPeakingEnabled, !showGrid, !compareMode,
              let file = session.currentFile,
              let decoder = decoder,
              fullResURL != file else { return }
        fullResTask?.cancel()
        fullResURL = file
        fullResTask = Task {
            guard let sendable = await decoder.decodeRAWFullResolution(url: file) else {
                if !Task.isCancelled { fullResURL = nil }  // allow retry on next zoom event
                return
            }
            guard !Task.isCancelled, session.currentFile == file, zoomScale > 1.01 else {
                fullResURL = nil
                return
            }
            fullResDisplayedURL = file
            currentTexture = sendable.texture
        }
    }

    private func cancelFullResolutionLoad() {
        fullResTask?.cancel()
        fullResTask = nil
        fullResURL = nil
        fullResDisplayedURL = nil
    }

    func loadThumbnail(for url: URL) {
        guard let decoder = decoder else { return }
        let cache = diskCache
        Task.detached(priority: .utility) {
            if let cache = cache, let cgImage = await cache.loadThumbnail(for: url) {
                let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                await MainActor.run { storeThumbnail(nsImage, for: url) }
                return
            }

            guard let cgImage = await decoder.extractThumbnail(url: url) else { return }
            let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            await MainActor.run { storeThumbnail(nsImage, for: url) }

            if let cache = cache {
                await cache.storeThumbnail(cgImage: cgImage, for: url)
            }
        }
    }

    /// Insert into the thumbnail dictionary, evicting the oldest entries once
    /// the cap is exceeded so large folders can't grow it unbounded.
    private func storeThumbnail(_ image: NSImage, for url: URL) {
        if thumbnails[url] == nil { thumbnailOrder.append(url) }
        thumbnails[url] = image
        while thumbnailOrder.count > Self.thumbnailCacheLimit {
            thumbnails[thumbnailOrder.removeFirst()] = nil
        }
    }
}
