@preconcurrency import Metal
import Foundation

/// Actor that manages prefetching of adjacent images and an LRU texture cache.
/// Prefetches N-1 and N+1 relative to the current index.
/// Cache holds up to `maxCacheSize` display-resolution MTLTextures.
actor PrefetchManager {
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
        // Dynamically size cache based on GPU memory.
        // Each display-res texture (~3840x2160 BGRA) is ~33MB.
        // Reserve at most 25% of recommended working set for cache.
        let recommended = device.recommendedMaxWorkingSetSize
        let perTexture: UInt64 = 3840 * 2160 * 4 // ~33MB
        let dynamicMax = Int(recommended / 4 / perTexture)
        self.maxCacheSize = max(3, min(dynamicMax, 10))
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

    /// Trigger prefetch for N-1 and N+1 around currentIndex.
    /// Cancels any prefetch tasks for URLs no longer in the prefetch window.
    func prefetch(
        currentIndex: Int,
        files: [URL],
        displaySize: CGSize
    ) {
        guard !files.isEmpty else { return }

        var targetURLs: Set<URL> = []

        // N-1
        if currentIndex > 0 {
            targetURLs.insert(files[currentIndex - 1])
        }
        // N+1
        if currentIndex < files.count - 1 {
            targetURLs.insert(files[currentIndex + 1])
        }
        // Current (always keep)
        targetURLs.insert(files[currentIndex])

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
