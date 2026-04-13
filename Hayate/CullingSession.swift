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

    /// Undo stack (session-only, lost on quit).
    private var undoStack: [UndoAction] = []

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

    /// Open a folder and scan for RAW files.
    /// - Returns: `true` if the folder was opened (security scope granted). `false` means
    ///            no session state was mutated, so callers should leave the UI alone.
    @discardableResult
    func openFolder(_ url: URL) -> Bool {
        guard url.startAccessingSecurityScopedResource() else { return false }
        defer { url.stopAccessingSecurityScopedResource() }

        folderURL = url
        undoStack.removeAll()

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

        // Load existing JSON
        loadJSON()
        return true
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

    // MARK: - Batch Operations

    func setRatingForIndices(_ indices: Set<Int>, rating: Int) {
        for index in indices where files.indices.contains(index) {
            let fileName = files[index].lastPathComponent
            let oldRating = entries[fileName]?.rating ?? 0
            undoStack.append(.ratingChange(fileName: fileName, oldRating: oldRating))
            var entry = entries[fileName] ?? PhotoEntry(fileName: fileName)
            entry.rating = max(0, min(5, rating))
            entries[fileName] = entry
        }
        saveJSON()
    }

    func toggleFavoriteForIndices(_ indices: Set<Int>) {
        for index in indices where files.indices.contains(index) {
            let fileName = files[index].lastPathComponent
            let oldFav = entries[fileName]?.isFavorite ?? false
            let oldRej = entries[fileName]?.isRejected ?? false
            undoStack.append(.favoriteChange(fileName: fileName, oldValue: oldFav))
            var entry = entries[fileName] ?? PhotoEntry(fileName: fileName)
            entry.isFavorite = !entry.isFavorite
            // Exclusive: turning on favorite clears rejected
            if entry.isFavorite && entry.isRejected {
                undoStack.append(.rejectedChange(fileName: fileName, oldValue: oldRej))
                entry.isRejected = false
            }
            entries[fileName] = entry
        }
        saveJSON()
    }

    func toggleRejectedForIndices(_ indices: Set<Int>) {
        for index in indices where files.indices.contains(index) {
            let fileName = files[index].lastPathComponent
            let oldRej = entries[fileName]?.isRejected ?? false
            let oldFav = entries[fileName]?.isFavorite ?? false
            undoStack.append(.rejectedChange(fileName: fileName, oldValue: oldRej))
            var entry = entries[fileName] ?? PhotoEntry(fileName: fileName)
            entry.isRejected = !entry.isRejected
            // Exclusive: turning on rejected clears favorite
            if entry.isRejected && entry.isFavorite {
                undoStack.append(.favoriteChange(fileName: fileName, oldValue: oldFav))
                entry.isFavorite = false
            }
            entries[fileName] = entry
        }
        saveJSON()
    }

    // MARK: - Rating & Favorite

    func setRating(_ rating: Int) {
        guard let file = currentFile else { return }
        let fileName = file.lastPathComponent
        let oldRating = entries[fileName]?.rating ?? 0

        undoStack.append(.ratingChange(fileName: fileName, oldRating: oldRating))

        var entry = entries[fileName] ?? PhotoEntry(fileName: fileName)
        entry.rating = max(0, min(5, rating))
        entries[fileName] = entry

        saveJSON()
    }

    func toggleFavorite() {
        guard let file = currentFile else { return }
        let fileName = file.lastPathComponent
        let oldFav = entries[fileName]?.isFavorite ?? false
        let oldRej = entries[fileName]?.isRejected ?? false

        undoStack.append(.favoriteChange(fileName: fileName, oldValue: oldFav))

        var entry = entries[fileName] ?? PhotoEntry(fileName: fileName)
        entry.isFavorite = !entry.isFavorite
        // Exclusive: turning on favorite clears rejected
        if entry.isFavorite && entry.isRejected {
            undoStack.append(.rejectedChange(fileName: fileName, oldValue: oldRej))
            entry.isRejected = false
        }
        entries[fileName] = entry

        saveJSON()
    }

    func toggleRejected() {
        guard let file = currentFile else { return }
        let fileName = file.lastPathComponent
        let oldRej = entries[fileName]?.isRejected ?? false
        let oldFav = entries[fileName]?.isFavorite ?? false

        undoStack.append(.rejectedChange(fileName: fileName, oldValue: oldRej))

        var entry = entries[fileName] ?? PhotoEntry(fileName: fileName)
        entry.isRejected = !entry.isRejected
        // Exclusive: turning on rejected clears favorite
        if entry.isRejected && entry.isFavorite {
            undoStack.append(.favoriteChange(fileName: fileName, oldValue: oldFav))
            entry.isFavorite = false
        }
        entries[fileName] = entry

        saveJSON()
    }

    // MARK: - Deletion

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

    private func loadJSON() {
        guard let url = jsonURL,
              let data = try? Data(contentsOf: url) else {
            entries = [:]
            return
        }

        let decoded = (try? JSONDecoder().decode([String: PhotoEntry].self, from: data)) ?? [:]

        // Remove orphan entries (files that no longer exist)
        let fileNames = Set(files.map(\.lastPathComponent))
        entries = decoded.filter { fileNames.contains($0.key) }
    }

    private func saveJSON() {
        guard let url = jsonURL else { return }

        // Only save entries that have non-default values
        let toSave = entries.filter { $0.value.rating > 0 || $0.value.isFavorite || $0.value.isRejected }

        guard let data = try? JSONEncoder().encode(toSave) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
