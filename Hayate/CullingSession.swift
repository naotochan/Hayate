import AppKit
import Foundation
import UniformTypeIdentifiers

/// Manages the culling session state: file list, ratings, favorites, JSON persistence, and undo.
@MainActor
class CullingSession: ObservableObject {
    /// All RAW file URLs in the current folder, sorted by name.
    @Published var files: [URL] = []
    /// Current photo index.
    @Published var currentIndex: Int = 0
    /// Photo metadata keyed by file name.
    @Published var entries: [String: PhotoEntry] = [:]
    /// The folder currently open.
    @Published var folderURL: URL?

    /// Trigger value; bumped to request the UI to show the Open Folder dialog.
    /// ContentView observes this via `.onChange` and presents `NSOpenPanel`.
    @Published var openFolderRequest: UUID = UUID()

    /// A specific folder the UI should open (recent-folders menu, drag & drop).
    /// ContentView observes this and runs the shared open-folder flow.
    @Published var directOpenRequest: URL?

    /// Recently opened folders, most recent first (persisted to UserDefaults).
    @Published private(set) var recentFolders: [URL] = []

    static let recentFoldersKey = "recentFolders"
    static let maxRecentFolders = 10

    /// Undo stack (session-only, lost on quit).
    private var undoStack: [UndoAction] = []

    init() {
        if let paths = UserDefaults.standard.stringArray(forKey: Self.recentFoldersKey) {
            recentFolders = paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
        }
        // Persist the browsing position (lastIndex) on quit — ratings are
        // saved on every change, but plain navigation isn't.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.saveJSON()
            }
        }
    }

    /// Supported RAW UTTypes that CIRAWFilter can handle.
    static let rawUTTypes: Set<UTType> = [
        .rawImage,
        UTType("com.canon.cr3-raw-image"),
        UTType("com.canon.cr2-raw-image"),
        UTType("com.nikon.nef-raw-image"),
        UTType("com.sony.arw-raw-image"),
        UTType("com.adobe.raw-image"),
        UTType("public.camera-raw-image"),
    ].compactMap { $0 }.reduce(into: Set<UTType>()) { $0.insert($1) }

    struct PhotoEntry: Codable {
        let fileName: String
        var rating: Int       // 0-5 (0 = unrated)
        var isFavorite: Bool
        var isRejected: Bool

        init(fileName: String, rating: Int = 0, isFavorite: Bool = false, isRejected: Bool = false) {
            self.fileName = fileName
            self.rating = rating
            self.isFavorite = isFavorite
            self.isRejected = isRejected
        }
    }

    enum UndoAction {
        case ratingChange(fileName: String, oldRating: Int)
        case favoriteChange(fileName: String, oldValue: Bool)
        case rejectedChange(fileName: String, oldValue: Bool)
        case deletion(url: URL, index: Int, entry: PhotoEntry?)
    }

    // MARK: - Folder Loading

    /// Request the UI to present the folder picker. Menus, buttons, and keyboard
    /// shortcuts all route through here so there's a single path into the dialog.
    func requestOpenFolder() {
        openFolderRequest = UUID()
    }

    /// Ask the UI to open this specific folder (recent-folders menu, drag & drop).
    func requestOpen(folder url: URL) {
        directOpenRequest = url
    }

    /// Open a folder and scan for RAW files.
    /// - Returns: `true` if the folder was opened (readable). `false` means
    ///            no session state was mutated, so callers should leave the UI alone.
    @discardableResult
    func openFolder(_ url: URL) -> Bool {
        // NSOpenPanel URLs carry a security scope; URLs built from stored paths
        // or drag & drop don't, and startAccessing returns false for those.
        // The app isn't sandboxed, so readability is the real gate.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.isReadableFile(atPath: url.path) else { return false }

        // Persist the previous folder's position before switching away.
        if folderURL != nil {
            saveJSON()
        }

        folderURL = url
        undoStack.removeAll()
        addToRecents(url)

        // Scan for RAW files
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.contentTypeKey],
            options: [.skipsHiddenFiles]
        ) else {
            files = []
            entries = [:]
            currentIndex = 0
            return true
        }

        files = contents.filter { fileURL in
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.contentTypeKey]),
                  let contentType = resourceValues.contentType else {
                return false
            }
            return Self.rawUTTypes.contains(where: { contentType.conforms(to: $0) })
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        currentIndex = 0

        // Load existing JSON (may restore lastIndex)
        loadJSON()
        return true
    }

    /// Move `url` to the front of the recent-folders list and persist it.
    private func addToRecents(_ url: URL) {
        var paths = [url.path] + recentFolders.map(\.path).filter { $0 != url.path }
        if paths.count > Self.maxRecentFolders {
            paths = Array(paths.prefix(Self.maxRecentFolders))
        }
        recentFolders = paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
        UserDefaults.standard.set(paths, forKey: Self.recentFoldersKey)
    }

    // MARK: - Navigation

    var currentFile: URL? {
        guard !files.isEmpty, files.indices.contains(currentIndex) else { return nil }
        return files[currentIndex]
    }

    var currentEntry: PhotoEntry? {
        guard let file = currentFile else { return nil }
        return entries[file.lastPathComponent]
    }

    func navigateForward() {
        guard currentIndex < files.count - 1 else { return }
        currentIndex += 1
    }

    func navigateBack() {
        guard currentIndex > 0 else { return }
        currentIndex -= 1
    }

    // MARK: - Rating & Favorite (single)

    func setRating(_ rating: Int) {
        guard let file = currentFile else { return }
        applyRating(rating, toFileNamed: file.lastPathComponent)
        saveJSON()
    }

    func toggleFavorite() {
        guard let file = currentFile else { return }
        applyToggleFavorite(toFileNamed: file.lastPathComponent)
        saveJSON()
    }

    func toggleRejected() {
        guard let file = currentFile else { return }
        applyToggleRejected(toFileNamed: file.lastPathComponent)
        saveJSON()
    }

    // MARK: - Batch Operations

    func setRatingForIndices(_ indices: Set<Int>, rating: Int) {
        forEachFileName(in: indices) { applyRating(rating, toFileNamed: $0) }
        saveJSON()
    }

    func toggleFavoriteForIndices(_ indices: Set<Int>) {
        forEachFileName(in: indices) { applyToggleFavorite(toFileNamed: $0) }
        saveJSON()
    }

    func toggleRejectedForIndices(_ indices: Set<Int>) {
        forEachFileName(in: indices) { applyToggleRejected(toFileNamed: $0) }
        saveJSON()
    }

    // MARK: - Mutation primitives

    /// Run `body` for each valid index's file name. Callers persist afterwards.
    private func forEachFileName(in indices: Set<Int>, _ body: (String) -> Void) {
        for index in indices where files.indices.contains(index) {
            body(files[index].lastPathComponent)
        }
    }

    /// Set a rating, recording the prior value for undo. Does not persist.
    private func applyRating(_ rating: Int, toFileNamed fileName: String) {
        let oldRating = entries[fileName]?.rating ?? 0
        undoStack.append(.ratingChange(fileName: fileName, oldRating: oldRating))
        var entry = entries[fileName] ?? PhotoEntry(fileName: fileName)
        entry.rating = max(0, min(5, rating))
        entries[fileName] = entry
    }

    /// Toggle favorite; turning it on clears rejected (mutually exclusive).
    /// Pushes favoriteChange first, then rejectedChange if clearing. Does not persist.
    private func applyToggleFavorite(toFileNamed fileName: String) {
        let oldFav = entries[fileName]?.isFavorite ?? false
        let oldRej = entries[fileName]?.isRejected ?? false
        undoStack.append(.favoriteChange(fileName: fileName, oldValue: oldFav))
        var entry = entries[fileName] ?? PhotoEntry(fileName: fileName)
        entry.isFavorite = !entry.isFavorite
        if entry.isFavorite && entry.isRejected {
            undoStack.append(.rejectedChange(fileName: fileName, oldValue: oldRej))
            entry.isRejected = false
        }
        entries[fileName] = entry
    }

    /// Toggle rejected; turning it on clears favorite (mutually exclusive).
    /// Pushes rejectedChange first, then favoriteChange if clearing. Does not persist.
    private func applyToggleRejected(toFileNamed fileName: String) {
        let oldRej = entries[fileName]?.isRejected ?? false
        let oldFav = entries[fileName]?.isFavorite ?? false
        undoStack.append(.rejectedChange(fileName: fileName, oldValue: oldRej))
        var entry = entries[fileName] ?? PhotoEntry(fileName: fileName)
        entry.isRejected = !entry.isRejected
        if entry.isRejected && entry.isFavorite {
            undoStack.append(.favoriteChange(fileName: fileName, oldValue: oldFav))
            entry.isFavorite = false
        }
        entries[fileName] = entry
    }

    // MARK: - Deletion

    /// Move the given indices to Trash. Indices are processed back-to-front so
    /// earlier indices stay valid as later ones are removed.
    /// - Returns: number of files successfully trashed.
    @discardableResult
    func deleteFilesAtIndices(_ indices: Set<Int>) -> Int {
        let sorted = indices.filter { files.indices.contains($0) }.sorted(by: >)
        var deleted = 0
        // Track how the deletions affect currentIndex so the displayed photo
        // stays on the same file when possible (or snaps to the nearest
        // survivor if the current photo itself was in the set).
        var currentRemoved = false
        var droppedBeforeCurrent = 0
        for index in sorted {
            let file = files[index]
            let fileName = file.lastPathComponent
            do {
                try FileManager.default.trashItem(at: file, resultingItemURL: nil)
            } catch {
                continue
            }
            undoStack.append(.deletion(url: file, index: index, entry: entries[fileName]))
            entries[fileName] = nil
            files.remove(at: index)
            deleted += 1
            if index == currentIndex {
                currentRemoved = true
            } else if index < currentIndex {
                droppedBeforeCurrent += 1
            }
        }

        if files.isEmpty {
            currentIndex = 0
        } else {
            // Shift down by the number of removed predecessors so the same
            // file stays selected; if the current file itself was removed,
            // fall through to clamping below (which lands on the next file).
            currentIndex -= droppedBeforeCurrent
            if currentRemoved && currentIndex >= files.count {
                currentIndex = files.count - 1
            }
            currentIndex = max(0, min(currentIndex, files.count - 1))
        }

        if deleted > 0 {
            saveJSON()
        }
        return deleted
    }

    func deleteCurrentFile() -> Bool {
        guard let file = currentFile else { return false }
        let fileName = file.lastPathComponent
        let entry = entries[fileName]
        let index = currentIndex

        do {
            try FileManager.default.trashItem(at: file, resultingItemURL: nil)
        } catch {
            return false
        }

        undoStack.append(.deletion(url: file, index: index, entry: entry))

        entries[fileName] = nil
        files.remove(at: index)

        // Adjust index
        if currentIndex >= files.count {
            currentIndex = max(0, files.count - 1)
        }

        saveJSON()
        return true
    }

    // MARK: - Undo

    func undo() {
        guard let action = undoStack.popLast() else { return }

        switch action {
        case .ratingChange(let fileName, let oldRating):
            if var entry = entries[fileName] {
                entry.rating = oldRating
                entries[fileName] = entry
            }

        case .favoriteChange(let fileName, let oldValue):
            if var entry = entries[fileName] {
                entry.isFavorite = oldValue
                entries[fileName] = entry
            }

        case .rejectedChange(let fileName, let oldValue):
            if var entry = entries[fileName] {
                entry.isRejected = oldValue
                entries[fileName] = entry
            }

        case .deletion:
            // File deletion undo is not supported (trashed items can be recovered via Finder)
            break
        }

        saveJSON()
    }

    // MARK: - JSON Persistence

    private var jsonURL: URL? {
        folderURL?.appendingPathComponent(".hayate.json")
    }

    /// Current on-disk format: entries plus the last browsing position.
    /// The legacy format was a bare `[String: PhotoEntry]` dictionary.
    private struct SessionData: Codable {
        var entries: [String: PhotoEntry]
        var lastIndex: Int?
    }

    private func loadJSON() {
        guard let url = jsonURL,
              let data = try? Data(contentsOf: url) else {
            entries = [:]
            return
        }

        let decoded: [String: PhotoEntry]
        var lastIndex: Int?
        if let session = try? JSONDecoder().decode(SessionData.self, from: data) {
            decoded = session.entries
            lastIndex = session.lastIndex
        } else {
            // Legacy format: bare entries dictionary
            decoded = (try? JSONDecoder().decode([String: PhotoEntry].self, from: data)) ?? [:]
        }

        // Remove orphan entries (files that no longer exist)
        let fileNames = Set(files.map(\.lastPathComponent))
        entries = decoded.filter { fileNames.contains($0.key) }

        // Resume where the user left off
        if let last = lastIndex, files.indices.contains(last) {
            currentIndex = last
        }
    }

    private func saveJSON() {
        guard let url = jsonURL else { return }

        // Only save entries that have non-default values
        let toSave = entries.filter { $0.value.rating > 0 || $0.value.isFavorite || $0.value.isRejected }

        // Don't create a dotfile in folders the user merely opened at the
        // first photo without rating anything.
        if toSave.isEmpty && currentIndex == 0 && !FileManager.default.fileExists(atPath: url.path) {
            return
        }

        let session = SessionData(entries: toSave, lastIndex: currentIndex)
        guard let data = try? JSONEncoder().encode(session) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
