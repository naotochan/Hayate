@preconcurrency import Metal
import Foundation
import CoreGraphics

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

    struct CacheEntry {
        let texture: MTLTexture
        let isRAW: Bool
    }

    init(decoder: ImageDecoder, device: MTLDevice, diskCache: DiskCacheManager? = nil) {
        self.decoder = decoder
        self.diskCache = diskCache
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
    /// Returns the texture on hit, nil on miss.
    func textureFromDiskCache(for url: URL) async -> SendableTexture? {
        guard let diskCache = diskCache else { return nil }
        guard let cgImage = await diskCache.loadPreview(for: url) else { return nil }
        guard let sendable = await decoder.cgImageToTexture(cgImage) else { return nil }
        store(texture: sendable.texture, for: url, isRAW: true)
        return sendable
    }

    /// Store a texture in memory and persist to disk cache as HEIF.
    /// Used by ContentView after a RAW decode so the result survives across sessions.
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
            let diskCache = self.diskCache
            let size = displaySize

            activeTasks[url] = Task {
                // 1. Try disk cache first (~20-50ms)
                if let diskCache = diskCache,
                   let cgImage = await diskCache.loadPreview(for: url),
                   let sendable = await decoder.cgImageToTexture(cgImage) {
                    await self.store(texture: sendable.texture, for: url, isRAW: true)
                    await self.removeActiveTask(for: url)
                    return
                }

                // 2. JPEG for instant availability
                if let jpeg = await decoder.extractJPEG(url: url),
                   let sendable = await decoder.cgImageToTexture(jpeg) {
                    await self.store(texture: sendable.texture, for: url, isRAW: false)
                }

                // 3. Full RAW decode → CGImage → texture + disk
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

    /// Clear the memory cache and cancel all tasks.
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
