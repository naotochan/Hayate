@preconcurrency import Metal
import Foundation

/// Actor that manages prefetching of adjacent images and an LRU texture cache.
/// Prefetches N±prefetchRadius relative to the current index.
/// Cache holds up to `maxCacheSize` display-resolution MTLTextures.
actor PrefetchManager {
    /// How many neighbours to warm up on each side of the current index.
    /// At 5, rapid J/L navigation stays warm for ~10 photos before the decode
    /// pipeline has to catch up.
    static let prefetchRadius = 5

    private let decoder: ImageDecoder
    private let maxCacheSize: Int

    /// Cached textures keyed by file URL.
    private var cache: [URL: CacheEntry] = [:]
    /// Access order for LRU eviction. Most recent at the end.
    private var accessOrder: [URL] = []

    /// Currently running prefetch tasks, keyed by URL.
    private var activeTasks: [URL: Task<Void, Never>] = [:]

    struct CacheEntry {
        let texture: MTLTexture
        let isRAW: Bool // true = full RAW decode, false = JPEG thumbnail
    }

    init(decoder: ImageDecoder, device: MTLDevice) {
        self.decoder = decoder
        // Each display-res texture (~3840x2160 BGRA) is ~33MB. Cap at half of the
        // recommended working set, bounded [10, 40]. 40 textures ≈ 1.3GB — enough
        // for the ±5 prefetch window plus a generous recently-viewed buffer for
        // back-and-forth culling.
        let recommended = device.recommendedMaxWorkingSetSize
        let perTexture: UInt64 = 3840 * 2160 * 4
        let dynamicMax = Int(recommended / 2 / perTexture)
        self.maxCacheSize = max(10, min(dynamicMax, 40))
    }

    /// Get a cached texture for the given URL. Returns nil if not cached.
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

    /// Store a texture in the cache, evicting LRU entries if necessary.
    func store(texture: MTLTexture, for url: URL, isRAW: Bool) {
        // Don't downgrade RAW to JPEG
        if let existing = cache[url], existing.isRAW && !isRAW {
            return
        }

        cache[url] = CacheEntry(texture: texture, isRAW: isRAW)
        touchAccess(url)
        evictIfNeeded()
    }

    /// Trigger prefetch for N±prefetchRadius around currentIndex.
    /// Cancels any prefetch tasks for URLs no longer in the prefetch window.
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

        // Cancel tasks for URLs outside the window
        for (url, task) in activeTasks {
            if !targetURLs.contains(url) {
                task.cancel()
                activeTasks[url] = nil
            }
        }

        // Start prefetch for uncached targets
        for url in targetURLs {
            if cache[url] != nil || activeTasks[url] != nil {
                continue
            }

            let decoder = self.decoder
            let size = displaySize

            activeTasks[url] = Task {
                // First, try JPEG for instant availability
                if let jpeg = await decoder.extractJPEG(url: url),
                   let sendable = await decoder.cgImageToTexture(jpeg) {
                    await self.store(texture: sendable.texture, for: url, isRAW: false)
                }

                // Then decode full RAW
                if !Task.isCancelled {
                    if let sendable = await decoder.decodeRAW(url: url, displaySize: size) {
                        await self.store(texture: sendable.texture, for: url, isRAW: true)
                    }
                }

                await self.removeActiveTask(for: url)
            }
        }
    }

    /// Clear the entire cache and cancel all tasks.
    func clear() {
        for (_, task) in activeTasks {
            task.cancel()
        }
        activeTasks.removeAll()
        cache.removeAll()
        accessOrder.removeAll()
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
