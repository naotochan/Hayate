import Foundation
import CryptoKit
import ImageIO
import SQLite3
import UniformTypeIdentifiers
import os.signpost

/// Actor that manages on-disk HEIF preview cache backed by SQLite metadata.
///
/// Cache layout:
/// ```
/// <cacheRoot>/
/// ├── index.sqlite
/// └── display/
///     └── ab/
///         └── cd1234…ef.heic
/// ```
///
/// Cache key = SHA256(absolutePath + "|" + mtime + "|" + size), first 16 hex chars.
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
        if let path = UserDefaults.standard.string(forKey: "previewCacheLocation") {
            return URL(fileURLWithPath: path, isDirectory: true)
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
        let root = cacheRoot ?? Self.defaultCacheRoot
        self.cacheRoot = root
        self.displayDir = root.appendingPathComponent("display", isDirectory: true)

        try? FileManager.default.createDirectory(at: displayDir, withIntermediateDirectories: true)

        var dbHandle: OpaquePointer?
        let dbPath = root.appendingPathComponent("index.sqlite").path
        if sqlite3_open_v2(dbPath, &dbHandle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK {
            let createSQL = """
            CREATE TABLE IF NOT EXISTS previews (
                key TEXT PRIMARY KEY,
                source_path TEXT NOT NULL,
                source_mtime REAL NOT NULL,
                source_size INTEGER NOT NULL,
                file_size INTEGER NOT NULL DEFAULT 0,
                last_access_at REAL NOT NULL,
                created_at REAL NOT NULL
            )
            """
            sqlite3_exec(dbHandle, createSQL, nil, nil, nil)
            sqlite3_exec(dbHandle, "PRAGMA journal_mode=WAL", nil, nil, nil)
        }
        self.dbHandle = SQLiteHandle(dbHandle)
    }

    // MARK: - Public API

    /// Load a cached preview HEIF from disk. Returns nil on miss.
    /// Updates `last_access_at` on hit for LRU tracking.
    func loadPreview(for url: URL) -> CGImage? {
        let signpostID = OSSignpostID(log: signpostLog)
        os_signpost(.begin, log: signpostLog, name: "loadPreview", signpostID: signpostID)
        defer { os_signpost(.end, log: signpostLog, name: "loadPreview", signpostID: signpostID) }

        guard let key = cacheKey(for: url) else { return nil }
        let filePath = heifPath(for: key)

        guard FileManager.default.fileExists(atPath: filePath.path) else {
            deleteEntry(key: key)
            return nil
        }

        touchEntry(key: key)

        guard let source = CGImageSourceCreateWithURL(filePath as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        return image
    }

    /// Store a CGImage as HEIF on disk. Skips if already cached.
    func store(cgImage: CGImage, for url: URL) {
        let signpostID = OSSignpostID(log: signpostLog)
        os_signpost(.begin, log: signpostLog, name: "storePreview", signpostID: signpostID)
        defer { os_signpost(.end, log: signpostLog, name: "storePreview", signpostID: signpostID) }

        guard let key = cacheKey(for: url) else { return }
        guard !entryExists(key: key) else { return }

        let filePath = heifPath(for: key)
        let shardDir = filePath.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: shardDir, withIntermediateDirectories: true)

        guard writeHEIF(cgImage: cgImage, to: filePath) else { return }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: filePath.path)[.size] as? Int64) ?? 0
        insertEntry(key: key, url: url, fileSize: fileSize)

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
        return entryExists(key: key)
    }

    /// Total size of cached preview files in bytes.
    func totalSize() -> Int64 {
        guard let db = db else { return 0 }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT COALESCE(SUM(file_size), 0) FROM previews", -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int64(stmt, 0)
    }

    /// Evict oldest entries until total size is under `maxBytes`.
    func evict(maxBytes: Int64) {
        while totalSize() > maxBytes {
            guard let oldest = oldestEntry() else { break }
            let filePath = heifPath(for: oldest)
            try? FileManager.default.removeItem(at: filePath)
            deleteEntry(key: oldest)
        }
    }

    /// Delete all cached previews and reset the database.
    func clear() {
        if let db = db {
            sqlite3_exec(db, "DELETE FROM previews", nil, nil, nil)
        }
        try? FileManager.default.removeItem(at: displayDir)
        try? FileManager.default.createDirectory(at: displayDir, withIntermediateDirectories: true)
    }

    // MARK: - Cache key

    private func cacheKey(for url: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attrs[.size] as? UInt64) ?? 0
        let input = "\(url.path)|\(mtime)|\(size)"
        let hash = SHA256.hash(data: Data(input.utf8))
        return hash.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - File paths

    private func heifPath(for key: String) -> URL {
        let shard = String(key.prefix(2))
        return displayDir
            .appendingPathComponent(shard, isDirectory: true)
            .appendingPathComponent("\(key).heic")
    }

    // MARK: - HEIF I/O

    @discardableResult
    private func writeHEIF(cgImage: CGImage, to url: URL) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.heic.identifier as CFString,
            1,
            nil
        ) else { return false }

        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.85
        ]
        CGImageDestinationAddImage(dest, cgImage, options as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }

    // MARK: - SQLite

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func entryExists(key: String) -> Bool {
        guard let db = db else { return false }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM previews WHERE key = ?1", -1, &stmt, nil) == SQLITE_OK else { return false }
        sqlite3_bind_text(stmt, 1, key, -1, Self.sqliteTransient)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private func insertEntry(key: String, url: URL, fileSize: Int64) {
        guard let db = db else { return }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attrs?[.size] as? Int64) ?? 0
        let now = Date().timeIntervalSince1970

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "INSERT OR REPLACE INTO previews (key, source_path, source_mtime, source_size, file_size, last_access_at, created_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, key, -1, transient)
        sqlite3_bind_text(stmt, 2, url.path, -1, transient)
        sqlite3_bind_double(stmt, 3, mtime)
        sqlite3_bind_int64(stmt, 4, size)
        sqlite3_bind_int64(stmt, 5, fileSize)
        sqlite3_bind_double(stmt, 6, now)
        sqlite3_bind_double(stmt, 7, now)
        sqlite3_step(stmt)
    }

    private func touchEntry(key: String) {
        guard let db = db else { return }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "UPDATE previews SET last_access_at = ?1 WHERE key = ?2"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
        sqlite3_bind_text(stmt, 2, key, -1, Self.sqliteTransient)
        sqlite3_step(stmt)
    }

    private func deleteEntry(key: String) {
        guard let db = db else { return }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "DELETE FROM previews WHERE key = ?1", -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, key, -1, Self.sqliteTransient)
        sqlite3_step(stmt)
    }

    private func oldestEntry() -> String? {
        guard let db = db else { return nil }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT key FROM previews ORDER BY last_access_at ASC LIMIT 1", -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let cStr = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: cStr)
    }
}
