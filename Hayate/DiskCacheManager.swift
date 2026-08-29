import Foundation
import CryptoKit
import ImageIO
import SQLite3
import UniformTypeIdentifiers
import os.signpost

/// Actor that manages the on-disk preview cache backed by SQLite metadata.
///
/// Cache layout:
/// ```
/// <cacheRoot>/
/// ├── index.sqlite
/// ├── display/
/// │   └── ab/
/// │       └── cd1234…ef.heic
/// └── thumb/
///     └── ab/
///         └── cd1234…ef.heic
/// ```
///
/// Cached files keep the historical `.heic` extension, but draft/thumbnail
/// content is JPEG — readers sniff content, so the extension is cosmetic.
///
/// Cache key = SHA256(canonicalPath + "|" + mtime + "|" + size), first 16 hex chars.
/// Canonical path = symlinks resolved + standardized, so /var vs /private/var
/// and trailing-slash variants of the same file share one key.
/// Sharded into subdirectories by the first 2 characters of the key.
actor DiskCacheManager {
    /// Wraps an SQLite handle so it gets closed automatically when the actor is deallocated.
    private final class SQLiteHandle {
        var pointer: OpaquePointer?
        init(_ pointer: OpaquePointer?) { self.pointer = pointer }
        deinit { if let p = pointer { sqlite3_close(p) } }
    }

    private let cacheRoot: URL
    private let displayDir: URL
    private let thumbDir: URL
    private let dbHandle: SQLiteHandle
    private var db: OpaquePointer? { dbHandle.pointer }
    private let signpostLog = OSLog(subsystem: "com.hayate", category: "DiskCache")

    /// Default cache location: ~/Library/Caches/com.hayate/previews
    static var defaultCacheRoot: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appendingPathComponent("com.hayate/previews", isDirectory: true)
    }

    /// Read the user-configured cache root from UserDefaults, falling back to the default.
    static var userConfiguredCacheRoot: URL {
        // Settings' "Reset" writes an empty string — treat it as unset. A
        // bogus root makes the SQLite index unopenable and silently disables
        // persistence (every launch rebuilt every preview).
        if let path = UserDefaults.standard.string(forKey: "previewCacheLocation"),
           !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }
        return defaultCacheRoot
    }

    /// Cache size limit in bytes from UserDefaults. 0 = unlimited.
    static var userConfiguredSizeLimit: Int64 {
        let gb = UserDefaults.standard.integer(forKey: "previewCacheSizeLimitGB")
        if gb == 0 { return 0 }
        return Int64(gb) * 1_073_741_824
    }

    init(cacheRoot: URL? = nil) {
        let requested = cacheRoot ?? Self.defaultCacheRoot
        var root = requested
        var db = Self.openIndex(at: root)
        if db == nil, root != Self.defaultCacheRoot {
            // An unusable custom location (deleted volume, unwritable, empty
            // path from Settings' Reset) must not silently kill persistence —
            // without the index every launch rebuilds every preview.
            os_log(.error, log: Self.log, "Preview cache at %{public}@ is unusable; falling back to the default location", root.path)
            root = Self.defaultCacheRoot
            db = Self.openIndex(at: root)
        }
        if db == nil {
            os_log(.fault, log: Self.log, "Preview cache index could not be opened at %{public}@ — previews will not persist this session", root.path)
        }

        self.cacheRoot = root
        self.displayDir = root.appendingPathComponent("display", isDirectory: true)
        self.thumbDir = root.appendingPathComponent("thumb", isDirectory: true)
        self.dbHandle = SQLiteHandle(db)
    }

    private static let log = OSLog(subsystem: "com.hayate", category: "DiskCache")

    /// Create the cache directories and open/migrate the SQLite index at
    /// `root`. Returns nil (after logging) when the database cannot be opened.
    private static func openIndex(at root: URL) -> OpaquePointer? {
        let displayDir = root.appendingPathComponent("display", isDirectory: true)
        let thumbDir = root.appendingPathComponent("thumb", isDirectory: true)
        try? FileManager.default.createDirectory(at: displayDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: thumbDir, withIntermediateDirectories: true)

        var dbHandle: OpaquePointer?
        let dbPath = root.appendingPathComponent("index.sqlite").path
        guard sqlite3_open_v2(dbPath, &dbHandle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            os_log(.error, log: log, "sqlite open failed at %{public}@: %{public}@", dbPath, dbHandle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error")
            if let dbHandle { sqlite3_close(dbHandle) }
            return nil
        }

        // A previous Hayate instance may still hold the WAL while exiting.
        // Wait briefly instead of failing: failed reads make every file look
        // uncached and trigger a full preview rebuild on each launch. Kept
        // short — this actor sits on the viewer's critical path.
        sqlite3_busy_timeout(dbHandle, 1_000)

        let tableSQL = """
        CREATE TABLE IF NOT EXISTS %@ (
            key TEXT PRIMARY KEY,
            source_path TEXT NOT NULL,
            source_mtime REAL NOT NULL,
            source_size INTEGER NOT NULL,
            file_size INTEGER NOT NULL DEFAULT 0,
            last_access_at REAL NOT NULL,
            created_at REAL NOT NULL
        )
        """
        sqlite3_exec(dbHandle, String(format: tableSQL, "previews"), nil, nil, nil)
        sqlite3_exec(dbHandle, String(format: tableSQL, "thumbnails"), nil, nil, nil)

        // Draft (embedded JPEG) vs full-quality (CIRAW) preview, added after
        // the first shipped schema. A blind ALTER whose failure went ignored
        // broke every preview insert for the process lifetime ("no such
        // column"), so check first and log failures.
        var columnCheck: OpaquePointer?
        let hasFullQuality = sqlite3_prepare_v2(dbHandle, "SELECT is_full_quality FROM previews LIMIT 0", -1, &columnCheck, nil) == SQLITE_OK
        sqlite3_finalize(columnCheck)
        if !hasFullQuality,
           sqlite3_exec(dbHandle, "ALTER TABLE previews ADD COLUMN is_full_quality INTEGER NOT NULL DEFAULT 1", nil, nil, nil) != SQLITE_OK {
            os_log(.error, log: log, "is_full_quality migration failed: %{public}@", String(cString: sqlite3_errmsg(dbHandle)))
        }

        sqlite3_exec(dbHandle, "PRAGMA journal_mode=WAL", nil, nil, nil)
        return dbHandle
    }

    // MARK: - Public API

    /// Disk preview plus whether it came from a full RAW decode (`true`) or a
    /// fast embedded-JPEG draft (`false`). Drafts are shown immediately but
    /// the load pipeline still upgrades to CIRAWFilter when the user views them.
    struct CachedPreview {
        let image: CGImage
        let isFullQuality: Bool
    }

    /// Load a cached preview from disk. Returns nil on miss.
    /// Updates `last_access_at` on hit for LRU tracking.
    func loadPreview(for url: URL) -> CachedPreview? {
        let signpostID = OSSignpostID(log: signpostLog)
        os_signpost(.begin, log: signpostLog, name: "loadPreview", signpostID: signpostID)
        defer { os_signpost(.end, log: signpostLog, name: "loadPreview", signpostID: signpostID) }

        guard let key = cacheKey(for: url) else { return nil }
        let filePath = heifPath(for: key, dir: displayDir)

        guard FileManager.default.fileExists(atPath: filePath.path) else {
            deleteEntry(key: key, table: "previews")
            return nil
        }

        touchEntryThrottled(key: key, table: "previews")

        guard let source = CGImageSourceCreateWithURL(filePath as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        return CachedPreview(image: image, isFullQuality: previewIsFullQuality(key: key))
    }

    /// Store a CGImage in the disk cache. Encoding runs off-actor so
    /// concurrent `loadPreview` calls are not blocked behind other stores.
    /// - Draft (`isFullQuality: false`) is skipped when any preview already exists.
    /// - Full quality replaces a draft, and is a no-op when a full preview exists.
    func store(cgImage: CGImage, for url: URL, isFullQuality: Bool = true) async {
        let signpostID = OSSignpostID(log: signpostLog)
        os_signpost(.begin, log: signpostLog, name: "storePreview", signpostID: signpostID)
        defer { os_signpost(.end, log: signpostLog, name: "storePreview", signpostID: signpostID) }

        guard let key = cacheKey(for: url) else { return }

        // Phase A: fast policy check on actor (do not delete existing files yet).
        if let existingFull = previewIsFullQualityIfPresent(key: key) {
            if existingFull { return }
            if !isFullQuality { return }
        }

        let filePath = heifPath(for: key, dir: displayDir)
        let shardDir = filePath.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: shardDir, withIntermediateDirectories: true)
        let tempURL = shardDir.appendingPathComponent("\(UUID().uuidString).heic")
        let quality = isFullQuality ? 0.85 : 0.80

        // Phase B: expensive encode off actor. Drafts encode as JPEG (fast,
        // interim quality); only full RAW renders pay for HEIF.
        os_signpost(.begin, log: signpostLog, name: "storePreviewEncode", signpostID: signpostID)
        let encoded = await Task.detached(priority: .utility) {
            Self.writeEncoded(cgImage: cgImage, to: tempURL, type: isFullQuality ? .heic : .jpeg, quality: quality)
        }.value
        os_signpost(.end, log: signpostLog, name: "storePreviewEncode", signpostID: signpostID)

        guard encoded else {
            try? FileManager.default.removeItem(at: tempURL)
            os_log(.error, log: signpostLog, "preview encode failed for %{public}@", url.lastPathComponent)
            return
        }

        // Phase C: commit on actor — re-check policy after encode suspension.
        if let existingFull = previewIsFullQualityIfPresent(key: key) {
            if existingFull {
                try? FileManager.default.removeItem(at: tempURL)
                return
            }
            if !isFullQuality {
                try? FileManager.default.removeItem(at: tempURL)
                return
            }
            // Upgrade draft → full: clear the stale row before re-insert.
            deleteEntry(key: key, table: "previews")
        }

        try? FileManager.default.createDirectory(at: shardDir, withIntermediateDirectories: true)
        // Clear crash-orphaned files with no DB row (moveItem won't clobber).
        try? FileManager.default.removeItem(at: filePath)
        do {
            try FileManager.default.moveItem(at: tempURL, to: filePath)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            os_log(.error, log: signpostLog, "cache store move failed for %{public}@: %{public}@", url.lastPathComponent, error.localizedDescription)
            return
        }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: filePath.path)[.size] as? Int64) ?? 0
        insertPreviewEntry(key: key, url: url, fileSize: fileSize, isFullQuality: isFullQuality)

        let limit = Self.userConfiguredSizeLimit
        if limit > 0 {
            evict(maxBytes: limit)
        }
    }

    /// The root directory of this cache (for display in Settings).
    var cacheRootURL: URL { cacheRoot }

    /// Number of cached preview entries.
    func entryCount() -> Int {
        guard let db = db else { return 0 }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM previews", -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// Check whether a preview exists for the given URL.
    func exists(for url: URL) -> Bool {
        guard let key = cacheKey(for: url) else { return false }
        return entryExists(key: key, table: "previews")
    }

    /// Filter a list of URLs to only those missing from the disk cache.
    /// One index query total — per-file SELECTs made a large folder occupy
    /// this actor (blocking the viewer's loads behind it) on every launch.
    func uncachedURLs(from urls: [URL]) -> [URL] {
        let existing = allKeys(table: "previews")
        return urls.filter { url in
            guard let key = cacheKey(for: url) else { return true }
            return !existing.contains(key)
        }
    }

    /// Total size of all cached files (display + thumb) in bytes.
    func totalSize() -> Int64 {
        guard let db = db else { return 0 }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT COALESCE((SELECT SUM(file_size) FROM previews), 0) + COALESCE((SELECT SUM(file_size) FROM thumbnails), 0)"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int64(stmt, 0)
    }

    /// Evict oldest entries (display first, then thumb) until total size is under `maxBytes`.
    /// Freed bytes are tracked locally instead of re-querying SUM(file_size)
    /// per entry — on a large cache that O(N) re-query loop occupied this
    /// actor long enough to stall the viewer.
    func evict(maxBytes: Int64) {
        var remaining = totalSize()
        guard remaining > maxBytes else { return }
        var evicted = 0
        var lastAttempted: String?
        while remaining > maxBytes {
            var key = oldestEntry(table: "previews")
            var table = "previews"
            var dir = displayDir
            if key == nil {
                key = oldestEntry(table: "thumbnails")
                table = "thumbnails"
                dir = thumbDir
            }
            guard let victim = key else { break }
            // A failed delete (e.g. locked DB) would otherwise re-select the
            // same row forever.
            guard victim != lastAttempted else { break }
            lastAttempted = victim

            let filePath = heifPath(for: victim, dir: dir)
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: filePath.path)[.size] as? Int64) ?? 0
            try? FileManager.default.removeItem(at: filePath)
            deleteEntry(key: victim, table: table)
            remaining -= fileSize
            evicted += 1
        }
        if evicted > 0 {
            os_log(.default, log: signpostLog, "cache evicted %d entries to fit %lld-byte limit", evicted, maxBytes)
        }
    }

    /// Delete all cached data (display + thumb) and reset the database.
    func clear() {
        if let db = db {
            sqlite3_exec(db, "DELETE FROM previews", nil, nil, nil)
            sqlite3_exec(db, "DELETE FROM thumbnails", nil, nil, nil)
        }
        try? FileManager.default.removeItem(at: displayDir)
        try? FileManager.default.createDirectory(at: displayDir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: thumbDir)
        try? FileManager.default.createDirectory(at: thumbDir, withIntermediateDirectories: true)
    }

    // MARK: - Thumbnail API

    func loadThumbnail(for url: URL) -> CGImage? {
        guard let key = cacheKey(for: url) else { return nil }
        let filePath = heifPath(for: key, dir: thumbDir)

        guard FileManager.default.fileExists(atPath: filePath.path) else {
            deleteEntry(key: key, table: "thumbnails")
            return nil
        }

        touchEntryThrottled(key: key, table: "thumbnails")

        guard let source = CGImageSourceCreateWithURL(filePath as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        return image
    }

    /// Store a sidebar thumbnail. Encoding runs off-actor like `store`.
    func storeThumbnail(cgImage: CGImage, for url: URL) async {
        guard let key = cacheKey(for: url) else { return }
        guard !entryExists(key: key, table: "thumbnails") else { return }

        let filePath = heifPath(for: key, dir: thumbDir)
        let shardDir = filePath.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: shardDir, withIntermediateDirectories: true)
        let tempURL = shardDir.appendingPathComponent("\(UUID().uuidString).heic")

        let encoded = await Task.detached(priority: .utility) {
            Self.writeEncoded(cgImage: cgImage, to: tempURL, type: .jpeg, quality: 0.8)
        }.value

        guard encoded else {
            try? FileManager.default.removeItem(at: tempURL)
            os_log(.error, log: signpostLog, "preview encode failed for %{public}@", url.lastPathComponent)
            return
        }

        // Re-check after encode suspension — another store may have committed.
        guard !entryExists(key: key, table: "thumbnails") else {
            try? FileManager.default.removeItem(at: tempURL)
            return
        }

        try? FileManager.default.createDirectory(at: shardDir, withIntermediateDirectories: true)
        // Clear crash-orphaned files with no DB row (moveItem won't clobber).
        try? FileManager.default.removeItem(at: filePath)
        do {
            try FileManager.default.moveItem(at: tempURL, to: filePath)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            os_log(.error, log: signpostLog, "cache store move failed for %{public}@: %{public}@", url.lastPathComponent, error.localizedDescription)
            return
        }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: filePath.path)[.size] as? Int64) ?? 0
        insertEntry(key: key, url: url, fileSize: fileSize, table: "thumbnails")

        let limit = Self.userConfiguredSizeLimit
        if limit > 0 {
            evict(maxBytes: limit)
        }
    }

    func thumbnailExists(for url: URL) -> Bool {
        guard let key = cacheKey(for: url) else { return false }
        return entryExists(key: key, table: "thumbnails")
    }

    func uncachedThumbnailURLs(from urls: [URL]) -> [URL] {
        let existing = allKeys(table: "thumbnails")
        return urls.filter { url in
            guard let key = cacheKey(for: url) else { return true }
            return !existing.contains(key)
        }
    }

    // MARK: - Cache key

    private func cacheKey(for url: URL) -> String? {
        // Canonicalize so the same file keys identically whether its URL came
        // from the Open panel (/private/var/…), recents (URL(fileURLWithPath:)
        // keeps /var/…), symlinks, or a trailing slash.
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attrs[.size] as? UInt64) ?? 0
        let input = "\(path)|\(mtime)|\(size)"
        let hash = SHA256.hash(data: Data(input.utf8))
        return hash.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - File paths

    private func heifPath(for key: String, dir: URL) -> URL {
        let shard = String(key.prefix(2))
        return dir
            .appendingPathComponent(shard, isDirectory: true)
            .appendingPathComponent("\(key).heic")
    }

    // MARK: - Image I/O

    /// Encode a CGImage for the cache. Drafts and thumbnails use JPEG:
    /// several times faster to encode than HEIF, and drafts are
    /// interim-quality by design. Full RAW renders keep HEIF for size.
    /// The `.heic` file extension is historical — a key's file may hold
    /// either codec across draft→full upgrades; readers sniff content.
    @discardableResult
    private static func writeEncoded(cgImage: CGImage, to url: URL, type: UTType, quality: Double) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL,
            type.identifier as CFString,
            1,
            nil
        ) else { return false }

        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(dest, cgImage, options as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }

    // MARK: - SQLite

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// All keys in a table, fetched in a single query.
    private func allKeys(table: String) -> Set<String> {
        guard let db = db else { return [] }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT key FROM \(table)", -1, &stmt, nil) == SQLITE_OK else {
            os_log(.error, log: signpostLog, "allKeys prepare failed on %{public}@: %{public}@", table, String(cString: sqlite3_errmsg(db)))
            return []
        }
        var keys = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(stmt, 0) {
                keys.insert(String(cString: cStr))
            }
        }
        return keys
    }

    private func entryExists(key: String, table: String) -> Bool {
        guard let db = db else { return false }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT 1 FROM \(table) WHERE key = ?1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        sqlite3_bind_text(stmt, 1, key, -1, Self.sqliteTransient)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private func insertEntry(key: String, url: URL, fileSize: Int64, table: String) {
        guard let db = db else { return }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attrs?[.size] as? Int64) ?? 0
        let now = Date().timeIntervalSince1970

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "INSERT OR REPLACE INTO \(table) (key, source_path, source_mtime, source_size, file_size, last_access_at, created_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            os_log(.error, log: signpostLog, "cache insert prepare failed: %{public}@", String(cString: sqlite3_errmsg(db)))
            return
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, key, -1, transient)
        sqlite3_bind_text(stmt, 2, url.path, -1, transient)
        sqlite3_bind_double(stmt, 3, mtime)
        sqlite3_bind_int64(stmt, 4, size)
        sqlite3_bind_int64(stmt, 5, fileSize)
        sqlite3_bind_double(stmt, 6, now)
        sqlite3_bind_double(stmt, 7, now)
        let stepResult = sqlite3_step(stmt)
        if stepResult != SQLITE_DONE {
            os_log(.error, log: signpostLog, "cache insert step failed (%d): %{public}@", stepResult, String(cString: sqlite3_errmsg(db)))
        }
    }

    private func insertPreviewEntry(key: String, url: URL, fileSize: Int64, isFullQuality: Bool) {
        guard let db = db else { return }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attrs?[.size] as? Int64) ?? 0
        let now = Date().timeIntervalSince1970

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = """
        INSERT OR REPLACE INTO previews
        (key, source_path, source_mtime, source_size, file_size, last_access_at, created_at, is_full_quality)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            os_log(.error, log: signpostLog, "cache insert prepare failed: %{public}@", String(cString: sqlite3_errmsg(db)))
            return
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, key, -1, transient)
        sqlite3_bind_text(stmt, 2, url.path, -1, transient)
        sqlite3_bind_double(stmt, 3, mtime)
        sqlite3_bind_int64(stmt, 4, size)
        sqlite3_bind_int64(stmt, 5, fileSize)
        sqlite3_bind_double(stmt, 6, now)
        sqlite3_bind_double(stmt, 7, now)
        sqlite3_bind_int(stmt, 8, isFullQuality ? 1 : 0)
        let stepResult = sqlite3_step(stmt)
        if stepResult != SQLITE_DONE {
            os_log(.error, log: signpostLog, "cache insert step failed (%d): %{public}@", stepResult, String(cString: sqlite3_errmsg(db)))
        }
    }

    /// `nil` = no row; otherwise the stored `is_full_quality` flag.
    private func previewIsFullQualityIfPresent(key: String) -> Bool? {
        guard let db = db else { return nil }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT is_full_quality FROM previews WHERE key = ?1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, key, -1, Self.sqliteTransient)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_int(stmt, 0) != 0
    }

    private func previewIsFullQuality(key: String) -> Bool {
        previewIsFullQualityIfPresent(key: key) ?? true
    }

    /// Last touch per "table|key" this session. LRU bookkeeping writes once
    /// per key per hour instead of on every view — the viewer path must not
    /// take a WAL write lock per photo.
    private var recentTouches: [String: Date] = [:]

    private func touchEntryThrottled(key: String, table: String) {
        let id = "\(table)|\(key)"
        let now = Date()
        if let last = recentTouches[id], now.timeIntervalSince(last) < 3_600 { return }
        if recentTouches.count > 10_000 { recentTouches.removeAll() }
        recentTouches[id] = now
        touchEntry(key: key, table: table)
    }

    private func touchEntry(key: String, table: String) {
        guard let db = db else { return }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "UPDATE \(table) SET last_access_at = ?1 WHERE key = ?2"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
        sqlite3_bind_text(stmt, 2, key, -1, Self.sqliteTransient)
        sqlite3_step(stmt)
    }

    private func deleteEntry(key: String, table: String) {
        guard let db = db else { return }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "DELETE FROM \(table) WHERE key = ?1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, key, -1, Self.sqliteTransient)
        sqlite3_step(stmt)
    }

    private func oldestEntry(table: String) -> String? {
        guard let db = db else { return nil }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT key FROM \(table) ORDER BY last_access_at ASC LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let cStr = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: cStr)
    }
}
