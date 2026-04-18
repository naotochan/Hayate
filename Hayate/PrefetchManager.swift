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

    /// Get a cached texture for the given URL (memory only). Returns nil if not cached.
    func cachedTexture(for url: URL) -> SendableTexture? {
        if let entry = cache[url] {
            touchAccess(url)
            return SendableTexture(texture: entry.texture)
        }
        return nil
    }

    /// Whether the cache contains a RAW-decoded texture (not just JPEG) for this URL.
    func hasRAWTexture(for url: URL) -> Bool {
        cache[url]?.isRAW == true
    }

    /// Store a texture in the memory cache, evicting LRU entries if necessary.
    func store(texture: MTLTexture, for url: URL, isRAW: Bool) {
        if let existing = cache[url], existing.isRAW && !isRAW {
            return
        }

        cache[url] = CacheEntry(texture: texture, isRAW: isRAW)
        touchAccess(url)
        evictIfNeeded()
    }

    // MARK: - Disk cache integration

    /// Try loading a preview from disk cache, converting to texture and storing in memory.
    func textureFromDiskCache(for url: URL) async -> SendableTexture? {
        guard let diskCache = diskCache else { return nil }
        guard let cgImage = await diskCache.loadPreview(for: url) else { return nil }
        guard let sendable = await decoder.cgImageToTexture(cgImage) else { return nil }
        store(texture: sendable.texture, for: url, isRAW: true)
        return sendable
    }

    /// Store a texture in memory and persist to disk cache as HEIF.
    func storeAndPersist(texture: MTLTexture, cgImage: CGImage, for url: URL) {
        store(texture: texture, for: url, isRAW: true)
        if let diskCache = diskCache {
            let urlCopy = url
            Task.detached(priority: .utility) {
                await diskCache.store(cgImage: cgImage, for: urlCopy)
            }
        }
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
        for index in lower...upper {
            targetURLs.insert(files[index])
        }

        for (url, task) in activeTasks {
            if !targetURLs.contains(url) {
                task.cancel()
                activeTasks[url] = nil
            }
        }

        for url in targetURLs {
            if cache[url] != nil || activeTasks[url] != nil {
                continue
            }

            let decoder = self.decoder
            let diskCache = self.diskCache
            let size = displaySize

            activeTasks[url] = Task {
                if let diskCache = diskCache,
                   let cgImage = await diskCache.loadPreview(for: url),
                   let sendable = await decoder.cgImageToTexture(cgImage) {
                    await self.store(texture: sendable.texture, for: url, isRAW: true)
                    await self.removeActiveTask(for: url)
                    return
                }

                if let jpeg = await decoder.extractJPEG(url: url),
                   let sendable = await decoder.cgImageToTexture(jpeg) {
                    await self.store(texture: sendable.texture, for: url, isRAW: false)
                }

                if !Task.isCancelled {
                    if let cgImage = await decoder.decodeRAWToCGImage(url: url, displaySize: size) {
                        if let sendable = await decoder.cgImageToTexture(cgImage) {
                            await self.store(texture: sendable.texture, for: url, isRAW: true)
                        }
                        if let diskCache = diskCache {
                            Task.detached(priority: .utility) {
                                await diskCache.store(cgImage: cgImage, for: url)
                            }
                        }
                    }
                }

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
