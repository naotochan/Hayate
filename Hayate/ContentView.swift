import SwiftUI
import MetalKit
import UniformTypeIdentifiers

/// Caps concurrent disk-cache reads + ImageIO thumb extraction so fast grid
/// scroll cannot flood the DiskCacheManager actor with hundreds of tasks.
private enum ThumbnailIO {
    static let limiter = DecodeLimiter(maxConcurrent: 6)
}

/// Pending thumbs and flush scheduling live in a reference type so enqueueing
/// completions does not mutate `@State` until a batched flush merges into
/// `thumbnails` / `thumbnailOrder`.
@MainActor
final class ThumbnailPendingBuffer {
    private var pending: [URL: NSImage] = [:]
    var flushScheduled = false

    func contains(_ url: URL) -> Bool { pending[url] != nil }

    func enqueue(_ image: NSImage, for url: URL) {
        pending[url] = image
    }

    func takeBatch() -> [URL: NSImage] {
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        return batch
    }

    func clear() {
        pending.removeAll()
        flushScheduled = false
    }
}

/// Root view. State lives here; the grid, compare, filmstrip, and input-handling
/// behaviour is split across `ContentView+*.swift` extension files. Those
/// extensions are part of the same type, so members shared across the file
/// boundary are `internal` (not `private`).
struct ContentView: View {
    @EnvironmentObject var session: CullingSession
    @EnvironmentObject var keybindings: KeybindingStore
    @EnvironmentObject var L: LocalizationStore
    @Environment(\.ciContext) var ciContext
    @Environment(\.metalDevice) var metalDevice
    @Environment(\.openWindow) var openWindow

    @State var currentTexture: MTLTexture?
    @State var decoder: ImageDecoder?
    @State var prefetchManager: PrefetchManager?
    @State var diskCache: DiskCacheManager?
    @StateObject var buildProgress = PreviewBuildProgress()
    @State var isLoading = false
    /// True when the current photo's decode pipeline returned nil (corrupt / unsupported).
    @State var imageLoadFailed = false
    /// Short-lived toast for folder open failures etc.
    @State var statusBanner: String?
    @State var statusBannerTask: Task<Void, Never>?
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
    /// Keyboard shortcuts cheat sheet (? key).
    @State var showShortcutsHelp = false
    /// First-launch / on-demand welcome guide.
    @State var showOnboarding = false
    @AppStorage("hasCompletedOnboarding") var hasCompletedOnboarding = false
    /// A folder is currently being dragged over the window (drop feedback).
    @State var isDropTargeted = false
    /// Cursor-style folder sidebar (Pinned + Recent).
    @AppStorage("sidebarVisible") var sidebarVisible = true
    /// Export sheet (File > Export Picks…).
    @State var showExportSheet = false
    /// True while switching folders so `onChange(of: currentIndex)` doesn't
    /// race a second decode against the intentional post-clear load.
    @State var isOpeningFolder = false
    /// Generation token so a delayed background build from folder A can't
    /// start after the user has already opened folder B.
    @State var folderOpenGeneration = 0
    @State var thumbnails: [URL: NSImage] = [:]
    /// Insertion order of `thumbnails` keys, oldest first, for capped eviction.
    @State var thumbnailOrder: [URL] = []
    /// Batched enqueue target; only `thumbnails` / `thumbnailOrder` `@State` flush.
    @State var thumbnailPending = ThumbnailPendingBuffer()
    /// In-flight thumbnail loads keyed by file URL. Cells cancel on disappear so
    /// fast scrolling can't flood the disk-cache actor with stale reads.
    @State var thumbnailTasks: [URL: (task: Task<Void, Never>, token: UUID)] = [:]

    /// Cap on the in-memory thumbnail dictionary. ~0.5 MB per 400px thumbnail,
    /// so 600 entries ≈ 300 MB worst case. Evicted thumbnails reload on demand
    /// via the placeholder's onAppear.
    static let thumbnailCacheLimit = 600
    @State var zoomScale: CGFloat = 1.0
    @State var panOffset: CGPoint = .zero
    /// Latest `MTKView.drawableSize` from the primary image view (physical pixels).
    @State var metalDrawableSize: CGSize = .zero
    /// When true, re-apply 1:1 zoom after full-res texture swap (preview → full).
    @State var isOneToOneZoomTarget = false
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
    @State var burstGroups: [BurstGroup] = []
    /// Burst start indices (`BurstGroup.id`) expanded in the grid.
    @State var expandedBurstIDs: Set<Int> = []
    @State var captureDateTask: Task<Void, Never>?
    /// Gap (minutes) between shots that draws a scene separator in the grid. 0 = off.
    @AppStorage("sceneGapMinutes") var sceneGapMinutes = 15
    /// Collapse rapid-fire bursts into one grid cell (All filter only).
    @AppStorage("burstGroupingEnabled") var burstGroupingEnabled = true
    /// Max adjacent capture-time gap (seconds) within one burst. 0 = off.
    @AppStorage("burstGapSeconds") var burstGapSeconds = 2
    /// Advance to the next photo automatically after rating/favorite/reject.
    @AppStorage("autoAdvance") var autoAdvance = false
    /// J/L (and arrows) skip photos that already have a decision.
    @AppStorage("navigateUndecidedOnly") var navigateUndecidedOnly = false
    /// Filmstrip / grid: desaturate non-favorites so Keep photos stand out.
    /// The main Metal viewer always stays full color.
    @AppStorage("colorizeKeepOnly") var colorizeKeepOnly = true
    /// Keep / Maybe / Out instead of 1–5 stars (stored via favorite / rating / reject).
    @AppStorage("cullingProfileTriage") var cullingProfileTriage = true
    /// Grid hints from on-device sharpness / face-quality scores (folder-relative).
    @AppStorage("assistedCullingEnabled") var assistedCullingEnabled = true
    @StateObject var photoAnalysisStore = PhotoAnalysisStore()
    @State var compareMode = false
    @State var compareIndices: [Int] = []
    @State var compareActiveSlot: Int = 0  // which photo is "active" for rating
    @State var compareTextures: [Int: MTLTexture] = [:]
    @State var surveyMode = false
    @State var surveyIndices: [Int] = []
    @State var surveyActiveSlot: Int = 0
    @State var surveyTextures: [Int: MTLTexture] = [:]
    /// Bumped on enter/exit so in-flight survey texture loads can't repopulate after clear.
    @State var surveyTextureGeneration: UInt = 0
    @State var surveyTextureLoadTask: Task<Void, Never>?

    enum GridFilter: String, CaseIterable {
        case all
        case favorites
        case rejected
        case rated
        case unrated
        case keep
        case maybe
        case out
        case undecided

        static func visible(triage: Bool) -> [GridFilter] {
            triage
                ? [.all, .keep, .maybe, .out, .undecided]
                : [.all, .favorites, .rejected, .rated, .unrated]
        }

        /// Product filter chrome — keep English in both languages.
        var title: String {
            switch self {
            case .all: return "All"
            case .favorites: return "♥ Favorites"
            case .rejected: return "✗ Rejected"
            case .rated: return "★ Rated"
            case .unrated: return "Unrated"
            case .keep: return "Keep"
            case .maybe: return "Maybe"
            case .out: return "Out"
            case .undecided: return "Undecided"
            }
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
            HStack(spacing: 0) {
                if ciContext != nil {
                    FolderSidebar(
                        isOpen: sidebarVisible,
                        onToggle: { sidebarVisible.toggle() },
                        onOpenFolder: { session.requestOpenFolder() },
                        onSelect: { session.requestOpen(folder: $0) },
                        onExport: { session.requestExport() },
                        onAfterTrashOut: {
                            selectedIndices.removeAll()
                            loadCurrentImage()
                        },
                        onShowShortcuts: {
                            showOnboarding = false
                            showShortcutsHelp = true
                        }
                    )
                }

                ZStack {
                    HayateTheme.canvas
                        .ignoresSafeArea()

                if ciContext == nil {
                    HayateBrandScreen(mode: .loading)
                } else if session.files.isEmpty {
                    HayateBrandScreen(
                        mode: .empty(
                            onOpen: { session.requestOpenFolder() },
                            recentFolders: session.recentFolders,
                            onOpenRecent: { session.requestOpen(folder: $0) },
                            message: session.folderURL.map { url in
                                "No photos in “\(url.lastPathComponent)”"
                            }
                        ),
                        dropTargeted: isDropTargeted
                    )
                } else if showGrid {
                    gridView
                } else if compareMode {
                    compareView
                } else if surveyMode {
                    surveyView
                } else {
                    // Single photo view
                    if let device = metalDevice {
                        MetalImageView(
                            texture: currentTexture,
                            device: device,
                            zoomScale: zoomScale,
                            panOffset: panOffset,
                            reportedDrawableSize: $metalDrawableSize
                        )
                    }

                    if imageLoadFailed, currentTexture == nil, !isLoading {
                        VStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 28, weight: .medium))
                                .foregroundColor(HayateTheme.fg(0.55))
                            Text("Couldn't load this photo")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(HayateTheme.fg(0.75))
                            if let name = session.currentFile?.lastPathComponent {
                                Text(name)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(HayateTheme.fg(0.4))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .padding(24)
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

                    if showShortcutsHelp {
                        ShortcutsHelpOverlay(
                            bindings: keybindings.bindings,
                            triageMode: cullingProfileTriage,
                            onDismiss: { showShortcutsHelp = false }
                        )
                    }

                    if let statusBanner {
                        VStack {
                            Text(statusBanner)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(HayateTheme.fg(0.92))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(HayateTheme.wash(0.22))
                                .cornerRadius(8)
                                .padding(.top, 12)
                            Spacer()
                        }
                        .transition(.opacity)
                        .allowsHitTesting(false)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

        }
        .overlayPreferenceValue(OnboardingAnchorKey.self) { anchors in
            GeometryReader { proxy in
                if showOnboarding {
                    let frames = anchors.mapValues { proxy[$0] }
                    OnboardingOverlay(
                        bindings: keybindings.bindings,
                        frames: frames,
                        onDismiss: {
                            showOnboarding = false
                            hasCompletedOnboarding = true
                        }
                    )
                }
            }
        }
        .onAppear {
            initializeDecoder()
            installKeyHandler()
            // Dock-reopen insurance: the delegate calls this when the process
            // is alive but has no windows to show.
            (NSApplication.shared.delegate as? AppDelegate)?.openMainWindow = {
                openWindow(id: HayateApp.mainWindowID)
            }
            if !hasCompletedOnboarding {
                sidebarVisible = true
                showOnboarding = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showOnboarding)) { _ in
            showShortcutsHelp = false
            sidebarVisible = true
            showOnboarding = true
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
            Button(L.t("Move to Trash", ja: "ゴミ箱に移す"), role: .destructive) {
                if let indices = pendingDeletionIndices {
                    let deleted = session.deleteFilesAtIndices(indices)
                    selectedIndices.removeAll()
                    pendingDeletionIndices = nil
                    if deleted > 0 {
                        if surveyMode {
                            exitSurveyMode(returnToGrid: true)
                        } else {
                            loadCurrentImage()
                        }
                    }
                } else {
                    let deleted = session.deleteCurrentFile()
                    if deleted {
                        if surveyMode {
                            exitSurveyMode(returnToGrid: true)
                        } else {
                            loadCurrentImage()
                        }
                    }
                }
            }
            Button(L.t("Cancel", ja: "キャンセル"), role: .cancel) {
                pendingDeletionIndices = nil
            }
        } message: {
            Text(deletionDialogMessage)
        }
        .onChange(of: session.currentIndex) { _, _ in
            guard !isOpeningFolder else { return }
            // Compare/survey share zoom across panes — skip reload here so slot moves don't reset zoom.
            guard !surveyMode, !compareMode else { return }
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
        .onChange(of: assistedCullingEnabled) { _, enabled in
            if enabled {
                startPhotoAnalysis()
            } else {
                stopPhotoAnalysis()
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
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            guard !providers.isEmpty else { return false }
            Task { @MainActor in
                var folders: [URL] = []
                for provider in providers {
                    guard let url = await Self.loadDroppedFileURL(from: provider),
                          (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                    else { continue }
                    folders.append(url)
                }
                openFoldersAndReload(folders)
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
            return L.t("Delete \(count) photos?", ja: "\(count) 枚の写真を削除しますか？")
        }
        return L.t("Delete this photo?", ja: "この写真を削除しますか？")
    }

    private var deletionDialogMessage: String {
        if let indices = pendingDeletionIndices {
            if indices.count == 1, let only = indices.first, session.files.indices.contains(only) {
                return session.files[only].lastPathComponent
            }
            return L.t(
                "Move \(indices.count) selected photos to Trash.",
                ja: "選択中の \(indices.count) 枚をゴミ箱に移します。"
            )
        }
        return session.currentFile?.lastPathComponent ?? ""
    }

    // MARK: - Folder handling

    private func openFolderDialog() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = L.t(
            "Select folders containing RAW photos",
            ja: "RAW写真が入ったフォルダを選んでください（複数可）"
        )

        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        openFoldersAndReload(panel.urls)
    }

    /// Open the first folder for culling; register any additional folders as
    /// independent Recents so the sidebar can switch between them.
    func openFoldersAndReload(_ urls: [URL]) {
        var seen = Set<String>()
        let folders = urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
        guard let first = folders.first else { return }
        if folders.count > 1 {
            session.rememberFolders(Array(folders.dropFirst()))
        }
        openFolderAndReload(first)
    }

    /// Resolve a dropped file URL from an `NSItemProvider` (Data or URL payload).
    private static func loadDroppedFileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let direct = item as? URL {
                    url = direct
                } else {
                    url = nil
                }
                continuation.resume(returning: url)
            }
        }
    }

    /// Shared open-folder flow used by the dialog, the recent-folders menu,
    /// and drag & drop. Only wipes view state if the session successfully
    /// switched folders; otherwise the screen keeps showing the old folder.
    func openFolderAndReload(_ url: URL) {
        guard session.openFolder(url) else {
            // Only drop from Recents when the folder itself is gone but its
            // parent volume is still mounted. Unmounted drives stay listed.
            let parent = url.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: parent.path) {
                session.removeFromRecents(url)
            }
            flashStatusBanner("Couldn't open “\(url.lastPathComponent)”")
            return
        }

        // Suppress index onChange while we reset + await cache clear, otherwise
        // loadJSON's restored index fires a decode that clear() immediately cancels.
        isOpeningFolder = true
        folderOpenGeneration += 1
        let generation = folderOpenGeneration
        resetViewState()

        let filesEmpty = session.files.isEmpty
        let pm = prefetchManager
        Task {
            // Finish cancelling the previous folder before any new decode/build.
            await pm?.clear()
            await MainActor.run {
                guard generation == folderOpenGeneration else { return }
                isOpeningFolder = false
                guard !filesEmpty else { return }
                loadCurrentImage()
            }
            // Let the current photo (and filmstrip thumbs) claim decode slots
            // before the whole-folder background builder starts.
            try? await Task.sleep(nanoseconds: 400_000_000)
            await MainActor.run {
                guard generation == folderOpenGeneration, !session.files.isEmpty else { return }
                startBackgroundBuild()
                startPhotoAnalysis()
            }
        }
    }

    func flashStatusBanner(_ message: String) {
        statusBannerTask?.cancel()
        statusBanner = message
        statusBannerTask = Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            statusBanner = nil
        }
    }

    func startBackgroundBuild() {
        guard let prefetchManager = prefetchManager else { return }
        let files = session.files
        let displaySize = previewDisplaySize
        let focusIndex = session.currentIndex
        Task {
            await prefetchManager.startBackgroundBuild(
                files: files,
                displaySize: displaySize,
                focusIndex: focusIndex
            )
        }
    }

    func startPhotoAnalysis() {
        guard let decoder else { return }
        photoAnalysisStore.start(
            generation: folderOpenGeneration,
            enabled: assistedCullingEnabled,
            files: session.files,
            focusIndex: session.currentIndex,
            decoder: decoder
        )
    }

    func stopPhotoAnalysis() {
        photoAnalysisStore.stop()
    }

    /// Clear all view-local state when switching to a new folder mid-session.
    /// Session-level state (files, entries, undoStack) is reset by `CullingSession.openFolder`.
    /// The `decoder` and `prefetchManager` instances are kept — they're bound to CIContext/device,
    /// not to a specific folder.
    ///
    /// Prefetch/disk memory clear is awaited by `openFolderAndReload` — do not
    /// fire it here as a fire-and-forget Task (that raced the new folder's load).
    private func resetViewState() {
        // Cancel in-flight work
        currentDecodeTask?.cancel()
        currentDecodeTask = nil
        cancelFullResolutionLoad()
        for entry in thumbnailTasks.values { entry.task.cancel() }
        thumbnailTasks.removeAll()
        captureDateTask?.cancel()
        captureDateTask = nil
        stopPhotoAnalysis()
        sceneStartIndices = []
        burstGroups = []
        expandedBurstIDs = []

        // Textures / decode results
        currentTexture = nil
        thumbnails.removeAll()
        thumbnailOrder.removeAll()
        thumbnailPending.clear()
        decodeTimeMs = 0
        isLoading = false
        imageLoadFailed = false
        statusBannerTask?.cancel()
        statusBannerTask = nil
        statusBanner = nil

        // Grid / Compare / selection
        showGrid = false
        selectedIndices.removeAll()
        gridFilter = .all
        compareMode = false
        compareIndices.removeAll()
        compareActiveSlot = 0
        compareTextures.removeAll()
        surveyMode = false
        surveyIndices.removeAll()
        surveyActiveSlot = 0
        surveyTextures.removeAll()
        surveyTextureLoadTask?.cancel()
        surveyTextureLoadTask = nil
        surveyTextureGeneration &+= 1

        // View helpers
        focusPeakingEnabled = false
        showInfo = false
        currentEXIF = nil
        showHistogram = false
        histogramData = nil
        showShortcutsHelp = false
        showOnboarding = false
    }

    // MARK: - Navigation

    func navigateForward() {
        session.navigateForward(
            undecidedOnly: navigateUndecidedOnly,
            triageMode: cullingProfileTriage
        )
    }

    func navigateBack() {
        session.navigateBack(
            undecidedOnly: navigateUndecidedOnly,
            triageMode: cullingProfileTriage
        )
    }

    // MARK: - Image loading

    func loadCurrentImage() {
        // Cancel any in-flight decode. Only the latest navigation matters.
        currentDecodeTask?.cancel()
        cancelFullResolutionLoad()
        // Reset zoom for new photo
        resetZoom()

        guard let file = session.currentFile else {
            currentTexture = nil
            return
        }
        guard decoder != nil else {
            currentTexture = nil
            return
        }

        if showInfo {
            loadEXIF()
        }

        isLoading = true
        imageLoadFailed = false
        let start = CFAbsoluteTimeGetCurrent()

        // Start the visible photo before neighbor prefetch so it wins the
        // limited CIRAWFilter slots on large folders.
        currentDecodeTask = Task {
            let displaySize = previewDisplaySize

            if focusPeakingEnabled {
                if let sendable = await loadFocusPeakingTexture(
                    for: file,
                    displaySize: displaySize,
                    onPartial: { partial in
                        guard !Task.isCancelled, fullResDisplayedURL != file else { return }
                        currentTexture = partial.texture
                        decodeTimeMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
                        imageLoadFailed = false
                    }
                ) {
                    guard !Task.isCancelled else { return }
                    if fullResDisplayedURL != file {
                        currentTexture = sendable.texture
                    }
                    decodeTimeMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
                    isLoading = false
                    imageLoadFailed = false
                } else if !Task.isCancelled {
                    // Decode failed — don't leave the spinner on.
                    currentTexture = nil
                    isLoading = false
                    imageLoadFailed = true
                }
                return
            }

            // Unified pipeline: memory → disk → embedded JPEG (partial) → RAW
            guard let prefetchManager = prefetchManager else {
                isLoading = false
                imageLoadFailed = true
                return
            }
            let result = await prefetchManager.loadTexture(for: file, displaySize: displaySize) { partial in
                // Defensive: don't overwrite a newer photo if this task was
                // cancelled while hopping to the main actor, and don't
                // downgrade a full-resolution texture the user zoomed into.
                guard !Task.isCancelled, fullResDisplayedURL != file else { return }
                currentTexture = partial.texture
                decodeTimeMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
                imageLoadFailed = false
            }
            guard !Task.isCancelled else { return }
            guard let result = result else {
                // Every stage failed (corrupt file etc.) — don't leave the
                // spinner on forever. Cancelled tasks return above; a newer
                // load owns the UI state in that case.
                if currentTexture == nil {
                    imageLoadFailed = true
                }
                isLoading = false
                return
            }
            if fullResDisplayedURL != file {
                currentTexture = result.texture
            }
            decodeTimeMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
            isLoading = false
            imageLoadFailed = false
        }

        // Fire neighbor prefetch in its own Task so rapid navigation can't
        // cancel it with the decode Task — but only after the current load
        // has been scheduled.
        if let prefetchManager = prefetchManager {
            let currentIdx = session.currentIndex
            let allFiles = session.files
            let prefetchSize = previewDisplaySize
            Task {
                await prefetchManager.prefetch(
                    currentIndex: currentIdx,
                    files: allFiles,
                    displaySize: prefetchSize
                )
            }
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

    /// Load a display-sized texture with focus peaking derived from cached
    /// display or full-resolution decodes when possible.
    func loadFocusPeakingTexture(
        for url: URL,
        displaySize: CGSize,
        onPartial: (@MainActor @Sendable (SendableTexture) -> Void)? = nil
    ) async -> SendableTexture? {
        guard let decoder = decoder, let prefetchManager = prefetchManager else { return nil }

        if let base = await prefetchManager.cachedDisplayTexture(for: url),
           let peaked = await decoder.applyFocusPeaking(to: base, displaySize: displaySize) {
            return peaked
        }
        if let base = await prefetchManager.cachedFullResolution(for: url),
           let peaked = await decoder.applyFocusPeaking(to: base, displaySize: displaySize) {
            return peaked
        }

        guard let base = await prefetchManager.loadTexture(
            for: url,
            displaySize: displaySize,
            onPartial: onPartial
        ) else {
            return nil
        }
        return await decoder.applyFocusPeaking(to: base, displaySize: displaySize)
    }

    /// Decode the current photo at full resolution when zoomed in, swapping it
    /// into `currentTexture` when ready. Reuses the PrefetchManager full-res LRU
    /// so zoom-out → zoom-in on the same photo does not re-decode.
    func loadFullResolutionIfNeeded() {
        guard zoomScale > 1.001, !focusPeakingEnabled, !showGrid, !compareMode, !surveyMode,
              let file = session.currentFile,
              let prefetchManager = prefetchManager else { return }
        if fullResDisplayedURL == file { return }
        guard fullResURL != file else { return }
        fullResTask?.cancel()
        fullResURL = file
        fullResTask = Task {
            guard let sendable = await prefetchManager.loadFullResolution(for: file) else {
                if !Task.isCancelled { fullResURL = nil }  // allow retry on next zoom event
                return
            }
            guard !Task.isCancelled, session.currentFile == file, zoomScale > 1.001 else {
                fullResURL = nil
                return
            }
            fullResDisplayedURL = file
            currentTexture = sendable.texture
            syncOneToOneZoomAfterFullResLoad()
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
        guard thumbnails[url] == nil, !thumbnailPending.contains(url) else { return }
        guard thumbnailTasks[url] == nil else { return }
        let cache = diskCache
        let token = UUID()

        let task = Task.detached(priority: .utility) {
            let loaded: (cgImage: CGImage, needsWarming: Bool)? =
                await ThumbnailIO.limiter.withPermit(tier: .high) { () -> (cgImage: CGImage, needsWarming: Bool)? in
                    if Task.isCancelled { return nil }
                    if let cache = cache, let cgImage = await cache.loadThumbnail(for: url) {
                        return (cgImage, false)
                    }
                    if Task.isCancelled { return nil }
                    if let cgImage = await decoder.extractThumbnail(url: url) {
                        return (cgImage, true)
                    }
                    return nil
                } ?? nil

            guard let loaded, !Task.isCancelled else {
                await MainActor.run { removeThumbnailTask(for: url, token: token) }
                return
            }

            let nsImage = NSImage(
                cgImage: loaded.cgImage,
                size: NSSize(width: loaded.cgImage.width, height: loaded.cgImage.height)
            )
            await MainActor.run { storeThumbnail(nsImage, for: url) }

            // Unregister before disk warming so the placeholder→Image swap's
            // onDisappear self-cancel can't kill the warming write.
            await MainActor.run { removeThumbnailTask(for: url, token: token) }

            if let cache = cache, loaded.needsWarming, !Task.isCancelled {
                await cache.storeThumbnail(cgImage: loaded.cgImage, for: url)
            }
        }

        thumbnailTasks[url] = (task, token)
    }

    func cancelThumbnailLoad(for url: URL) {
        thumbnailTasks.removeValue(forKey: url)?.task.cancel()
    }

    private func removeThumbnailTask(for url: URL, token: UUID) {
        if thumbnailTasks[url]?.token == token {
            thumbnailTasks.removeValue(forKey: url)
        }
    }

    /// Enqueue a loaded thumb; a single MainActor flush merges the batch so
    /// many completions in one runloop tick don't each trigger a full re-render.
    private func storeThumbnail(_ image: NSImage, for url: URL) {
        thumbnailPending.enqueue(image, for: url)
        scheduleThumbnailFlush()
    }

    private func scheduleThumbnailFlush() {
        guard !thumbnailPending.flushScheduled else { return }
        thumbnailPending.flushScheduled = true
        Task { @MainActor in
            await Task.yield()
            flushPendingThumbnails()
        }
    }

    private func flushPendingThumbnails() {
        thumbnailPending.flushScheduled = false
        let batch = thumbnailPending.takeBatch()
        guard !batch.isEmpty else { return }
        for (url, image) in batch {
            if thumbnails[url] == nil { thumbnailOrder.append(url) }
            thumbnails[url] = image
        }
        while thumbnailOrder.count > Self.thumbnailCacheLimit {
            thumbnails[thumbnailOrder.removeFirst()] = nil
        }
    }
}
