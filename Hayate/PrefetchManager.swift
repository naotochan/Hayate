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

    /// Store a texture in memory and persist to disk cache as full-quality HEIF.
    private func storeAndPersist(texture: MTLTexture, cgImage: CGImage, for url: URL) {
        store(texture: texture, for: url, isRAW: true)
        if let diskCache = diskCache {
            let urlCopy = url
            Task.detached(priority: .utility) {
                await diskCache.store(cgImage: cgImage, for: urlCopy, isFullQuality: true)
            }
        }
    }

    // MARK: - Unified load pipeline

    /// Load a texture for `url` through the fallback chain:
    /// memory cache → disk cache → embedded JPEG → full RAW decode.
    ///
    /// Each stage's result is stored in the memory cache; RAW decodes are also
    /// persisted to the disk cache. `onPartial` fires with the embedded-JPEG
    /// texture so callers can display it while the RAW decode finishes.
    /// Returns nil if every stage fails or the task is cancelled.
    func loadTexture(
        for url: URL,
        displaySize: CGSize,
        onPartial: (@MainActor @Sendable (SendableTexture) -> Void)? = nil
    ) async -> SendableTexture? {
        // L1: memory cache (instant). A JPEG-only entry is shown immediately
        // but still falls through for the RAW upgrade.
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

        return await performLoad(
            for: url,
            displaySize: displaySize,
            onPartial: onPartial,
            partialShown: partialShown
        )
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
        var partialShown = partialShown

        // L2: disk cache (~20-50ms). Full-quality entries are final; draft
        // (embedded JPEG) entries are shown immediately then upgraded via L3b.
        if let diskCache = diskCache,
           let cached = await diskCache.loadPreview(for: url),
           let sendable = await decoder.cgImageToTexture(cached.image) {
            guard !Task.isCancelled else { return nil }
            if cached.isFullQuality {
                store(texture: sendable.texture, for: url, isRAW: true)
                return sendable
            }
            store(texture: sendable.texture, for: url, isRAW: false)
            if let onPartial { await onPartial(sendable) }
            partialShown = true
        }
        guard !Task.isCancelled else { return nil }

        // L3a: embedded JPEG for instant feedback (skip if L1/L2 already showed one)
        if !partialShown,
           let jpeg = await decoder.extractJPEG(url: url),
           let sendable = await decoder.cgImageToTexture(jpeg) {
            guard !Task.isCancelled else { return nil }
            store(texture: sendable.texture, for: url, isRAW: false)
            if let onPartial { await onPartial(sendable) }
        }

        guard !Task.isCancelled else { return nil }

        // L3b: full RAW decode, persisted to the disk cache (upgrades any draft)
        guard let cgImage = await decoder.decodeRAWToCGImage(url: url, displaySize: displaySize),
              let sendable = await decoder.cgImageToTexture(cgImage) else {
            // RAW failed — keep a draft texture if we already have one.
            if let entry = cache[url] {
                return SendableTexture(texture: entry.texture)
            }
            return nil
        }
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

        // Keep the current photo's in-flight task alive even though it's not a
        // prefetch target — the UI's loadTexture may be joining it right now.
        let currentURL = files.indices.contains(currentIndex) ? files[currentIndex] : nil
        for (url, task) in activeTasks {
            if !targetURLs.contains(url) && url != currentURL {
                task.cancel()
                activeTasks[url] = nil
            }
        }

        // Cap how many neighbor loads we start at once. Extra URLs stay cold
        // until the next navigation; DecodeLimiter also gates CIRAWFilter.
        let maxNewPrefetch = 3
        var started = 0
        for url in targetURLs {
            let warmEnough = cache[url]?.isRAW == true
            if warmEnough || activeTasks[url] != nil {
                continue
            }
            guard started < maxNewPrefetch else { break }

            let size = displaySize
            // performLoad, not loadTexture: loadTexture joins activeTasks, so
            // calling it from the task registered there would await itself.
            let hasJPEGEntry = cache[url] != nil

            activeTasks[url] = Task {
                _ = await self.performLoad(
                    for: url,
                    displaySize: size,
                    partialShown: hasJPEGEntry
                )
                await self.removeActiveTask(for: url)
            }
            started += 1
        }
    }

    // MARK: - Background build

    /// Start building disk cache previews for all files in the background.
    /// Cancels any previous background build. Skips files already cached on disk.
    ///
    /// Software fast path: uses embedded JPEG only (no CIRAWFilter). Full RAW
    /// still runs on demand for the current photo and prefetch neighbours.
    /// Work is ordered outward from `focusIndex` so the filmstrip near the
    /// cursor fills first.
    func startBackgroundBuild(files: [URL], displaySize: CGSize, focusIndex: Int = 0) {
        backgroundBuildTask?.cancel()

        guard let diskCache = diskCache else { return }

        let decoder = self.decoder
        let progress = self.buildProgress
        // displaySize kept in the signature for call-site stability; draft
        // extracts ignore it (embedded preview size is file-defined).
        _ = displaySize

        backgroundBuildTask = Task.detached(priority: .utility) {
            let missingPreviewSet = Set(await diskCache.uncachedURLs(from: files))
            let missingThumbSet = Set(await diskCache.uncachedThumbnailURLs(from: files))
            let ordered = Self.radialOrder(files: files, focusIndex: focusIndex)
                .filter { missingPreviewSet.contains($0) || missingThumbSet.contains($0) }
            guard !ordered.isEmpty else { return }

            await MainActor.run {
                progress.total = ordered.count
                progress.completed = 0
                progress.isBuilding = true
            }

            // Modest parallelism: embedded JPEG extract is cheap and ImageIO
            // scales well; the actor-serialized disk writes keep IO calm.
            let parallel = 4
            var next = 0
            while next < ordered.count {
                guard !Task.isCancelled else { break }
                let end = min(next + parallel, ordered.count)
                let batch = Array(ordered[next..<end])
                next = end

                await withTaskGroup(of: Void.self) { group in
                    for url in batch {
                        let needPreview = missingPreviewSet.contains(url)
                        let needThumb = missingThumbSet.contains(url)
                        group.addTask {
                            guard !Task.isCancelled else { return }

                            if let jpeg = await decoder.extractJPEG(url: url) {
                                if needPreview {
                                    await diskCache.store(cgImage: jpeg, for: url, isFullQuality: false)
                                }
                                if needThumb {
                                    let thumb = decoder.downscaledCGImage(jpeg, maxPixelSize: 400) ?? jpeg
                                    await diskCache.storeThumbnail(cgImage: thumb, for: url)
                                }
                                return
                            }

                            // No embedded preview — fall back to a cheap thumb extract only.
                            if needThumb, let thumb = await decoder.extractThumbnail(url: url) {
                                await diskCache.storeThumbnail(cgImage: thumb, for: url)
                            }
                        }
                    }
                }

                let completed = next
                await MainActor.run {
                    progress.completed = completed
                }
            }

            await MainActor.run {
                progress.isBuilding = false
            }
        }
    }

    /// Current file first, then ±1, ±2, … so visible neighbours warm earliest.
    nonisolated static func radialOrder(files: [URL], focusIndex: Int) -> [URL] {
        let count = files.count
        guard count > 0 else { return [] }
        let focus = min(max(0, focusIndex), count - 1)
        var ordered: [URL] = []
        ordered.reserveCapacity(count)
        ordered.append(files[focus])
        var distance = 1
        while ordered.count < count {
            let right = focus + distance
            let left = focus - distance
            if right < count { ordered.append(files[right]) }
            if left >= 0 { ordered.append(files[left]) }
            distance += 1
        }
        return ordered
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
