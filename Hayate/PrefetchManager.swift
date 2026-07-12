@preconcurrency import Metal
import Foundation
import CoreGraphics

/// Observable progress for background preview generation.
/// Updated by PrefetchManager, observed by ContentView.
@MainActor
class PreviewBuildProgress: ObservableObject {
    @Published var completed: Int = 0
    @Published var total: Int = 0
    @Published var isBuilding: Bool = false

    func reset() {
        completed = 0
        total = 0
        isBuilding = false
    }
}

/// Actor that manages prefetching of adjacent images and an LRU texture cache.
/// Prefetches N±prefetchRadius relative to the current index.
///
/// Three-layer cache hierarchy:
/// 1. Memory (MTLTexture) — instant, limited by GPU working set
/// 2. Disk (HEIF via DiskCacheManager) — ~20-50ms load, persists across sessions
/// 3. RAW decode (CIRAWFilter) — 200-500ms, always available
actor PrefetchManager {
    /// How many neighbours to warm up on each side of the current index.
    static let prefetchRadius = 5

    private let decoder: ImageDecoder
    private let maxCacheSize: Int
    private let diskCache: DiskCacheManager?

    /// Cached textures keyed by file URL.
    private var cache: [URL: CacheEntry] = [:]
    /// Access order for LRU eviction. Most recent at the end.
    private var accessOrder: [URL] = []

    /// Currently running prefetch tasks, keyed by URL.
    private var activeTasks: [URL: Task<Void, Never>] = [:]

    /// Background preview build task — cancelled on folder change.
    private var backgroundBuildTask: Task<Void, Never>?

    /// Progress object updated during background builds.
    let buildProgress: PreviewBuildProgress

    struct CacheEntry {
        let texture: MTLTexture
        let isRAW: Bool
    }

    init(decoder: ImageDecoder, device: MTLDevice, diskCache: DiskCacheManager? = nil, buildProgress: PreviewBuildProgress) {
        self.decoder = decoder
        self.diskCache = diskCache
        self.buildProgress = buildProgress
        let recommended = device.recommendedMaxWorkingSetSize
        let perTexture: UInt64 = 3840 * 2160 * 4
        let dynamicMax = Int(recommended / 2 / perTexture)
        self.maxCacheSize = max(10, min(dynamicMax, 40))
    }

    // MARK: - Memory cache

    /// Store a texture in the memory cache, evicting LRU entries if necessary.
    private func store(texture: MTLTexture, for url: URL, isRAW: Bool) {
        if let existing = cache[url], existing.isRAW && !isRAW {
            return
        }

        cache[url] = CacheEntry(texture: texture, isRAW: isRAW)
        touchAccess(url)
        evictIfNeeded()
    }

    /// Store a texture in memory and persist to disk cache as HEIF.
    private func storeAndPersist(texture: MTLTexture, cgImage: CGImage, for url: URL) {
        store(texture: texture, for: url, isRAW: true)
        if let diskCache = diskCache {
            let urlCopy = url
            Task.detached(priority: .utility) {
                await diskCache.store(cgImage: cgImage, for: urlCopy)
            }
        }
    }

    // MARK: - Unified load pipeline

    /// Load a texture for `url` through the full fallback chain:
    /// memory cache → disk cache → embedded JPEG → full RAW decode.
    /// Each stage's result is stored in the memory cache; RAW decodes are also
    /// persisted to the disk cache. `onPartial` fires with the embedded-JPEG
    /// texture so callers can display it while the RAW decode finishes.
    /// Returns nil if every stage fails or the surrounding task is cancelled.
    func loadTexture(
        for url: URL,
        displaySize: CGSize,
        onPartial: (@MainActor @Sendable (SendableTexture) -> Void)? = nil
    ) async -> SendableTexture? {
        // L1: memory cache (instant). A JPEG-only entry is shown immediately
        // but still falls through to L2/L3b for the full-quality upgrade.
        var partialShown = false
        if let entry = cache[url] {
            touchAccess(url)
            let sendable = SendableTexture(texture: entry.texture)
            if entry.isRAW { return sendable }
            guard !Task.isCancelled else { return nil }
            if let onPartial { await onPartial(sendable) }
            partialShown = true
        }

        // A prefetch may already be decoding this URL. Wait for it and reuse
        // its cached result instead of running the same RAW decode twice.
        if let active = activeTasks[url] {
            await active.value
            guard !Task.isCancelled else { return nil }
            if let entry = cache[url] {
                touchAccess(url)
                let sendable = SendableTexture(texture: entry.texture)
                if entry.isRAW { return sendable }
                if !partialShown, let onPartial { await onPartial(sendable) }
                partialShown = true
            }
        }

        return await performLoad(for: url, displaySize: displaySize, onPartial: onPartial, partialShown: partialShown)
    }

    /// Slow path of the pipeline: disk cache → embedded JPEG → full RAW.
    /// `partialShown` suppresses the JPEG stage when a partial is already
    /// displayed (or already sitting in the memory cache).
    private func performLoad(
        for url: URL,
        displaySize: CGSize,
        onPartial: (@MainActor @Sendable (SendableTexture) -> Void)? = nil,
        partialShown: Bool = false
    ) async -> SendableTexture? {
        // L2: disk cache (~20-50ms) — also upgrades a JPEG-only memory entry
        if let diskCache = diskCache,
           let cgImage = await diskCache.loadPreview(for: url),
           let sendable = await decoder.cgImageToTexture(cgImage) {
            guard !Task.isCancelled else { return nil }
            store(texture: sendable.texture, for: url, isRAW: true)
            return sendable
        }
        guard !Task.isCancelled else { return nil }

        // L3a: embedded JPEG for instant feedback (skip if L1 already showed one)
        if !partialShown,
           let jpeg = await decoder.extractJPEG(url: url),
           let sendable = await decoder.cgImageToTexture(jpeg) {
            guard !Task.isCancelled else { return nil }
            store(texture: sendable.texture, for: url, isRAW: false)
            if let onPartial { await onPartial(sendable) }
        }

        guard !Task.isCancelled else { return nil }

        // L3b: full RAW decode, persisted to the disk cache
        guard let cgImage = await decoder.decodeRAWToCGImage(url: url, displaySize: displaySize),
              let sendable = await decoder.cgImageToTexture(cgImage) else { return nil }
        guard !Task.isCancelled else { return nil }
        storeAndPersist(texture: sendable.texture, cgImage: cgImage, for: url)
        return sendable
    }

    // MARK: - Prefetch

    /// Trigger prefetch for N±prefetchRadius around currentIndex.
    func prefetch(
        currentIndex: Int,
        files: [URL],
        displaySize: CGSize
    ) {
        guard !files.isEmpty else { return }

        var targetURLs: Set<URL> = []

        let radius = Self.prefetchRadius
        let lower = max(0, currentIndex - radius)
        let upper = min(files.count - 1, currentIndex + radius)
        // Skip the current photo itself: the UI's own loadTexture call decodes
        // and caches it, so prefetching it would duplicate the work.
        for index in lower...upper where index != currentIndex {
            targetURLs.insert(files[index])
        }

        for (url, task) in activeTasks {
            if !targetURLs.contains(url) {
                task.cancel()
                activeTasks[url] = nil
            }
        }

        for url in targetURLs {
            if cache[url]?.isRAW == true || activeTasks[url] != nil {
                continue
            }

            let size = displaySize
            // performLoad, not loadTexture: loadTexture joins activeTasks, so
            // calling it from the task registered there would await itself.
            let hasJPEGEntry = cache[url] != nil

            activeTasks[url] = Task {
                _ = await self.performLoad(for: url, displaySize: size, partialShown: hasJPEGEntry)
                await self.removeActiveTask(for: url)
            }
        }
    }

    // MARK: - Background build

    /// Start building disk cache previews for all files in the background.
    /// Cancels any previous background build. Skips files already cached on disk.
    func startBackgroundBuild(files: [URL], displaySize: CGSize) {
        backgroundBuildTask?.cancel()

        guard let diskCache = diskCache else { return }

        let decoder = self.decoder
        let progress = self.buildProgress

        backgroundBuildTask = Task.detached(priority: .background) {
            let missingPreviews = await diskCache.uncachedURLs(from: files)
            let missingThumbs = await diskCache.uncachedThumbnailURLs(from: files)

            let totalWork = missingPreviews.count + missingThumbs.count
            guard totalWork > 0 else { return }

            await MainActor.run {
                progress.total = totalWork
                progress.completed = 0
                progress.isBuilding = true
            }

            for url in missingPreviews {
                guard !Task.isCancelled else { break }

                if let cgImage = await decoder.decodeRAWToCGImage(url: url, displaySize: displaySize, priority: .background) {
                    await diskCache.store(cgImage: cgImage, for: url)
                }

                await MainActor.run {
                    progress.completed += 1
                }
            }

            for url in missingThumbs {
                guard !Task.isCancelled else { break }

                if let cgImage = await decoder.extractThumbnail(url: url) {
                    await diskCache.storeThumbnail(cgImage: cgImage, for: url)
                }

                await MainActor.run {
                    progress.completed += 1
                }
            }

            await MainActor.run {
                progress.isBuilding = false
            }
        }
    }

    /// Cancel any in-progress background build.
    func stopBackgroundBuild() {
        backgroundBuildTask?.cancel()
        backgroundBuildTask = nil
        Task { @MainActor in
            buildProgress.reset()
        }
    }

    /// Clear the memory cache and cancel all tasks.
    func clear() {
        for (_, task) in activeTasks {
            task.cancel()
        }
        activeTasks.removeAll()
        cache.removeAll()
        accessOrder.removeAll()
        stopBackgroundBuild()
    }

    // MARK: - Private

    private func removeActiveTask(for url: URL) {
        activeTasks[url] = nil
    }

    private func touchAccess(_ url: URL) {
        accessOrder.removeAll { $0 == url }
        accessOrder.append(url)
    }

    private func evictIfNeeded() {
        while cache.count > maxCacheSize, let oldest = accessOrder.first {
            cache[oldest] = nil
            accessOrder.removeFirst()
        }
    }
}
