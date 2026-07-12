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

    /// Trigger for the export sheet (File > Export Picks…).
    @Published var exportRequest: UUID?

    /// Progress of a running (or just-finished) export. nil when idle.
    @Published var exportProgress: ExportProgress?

    /// Recently opened folders, most recent first (persisted to UserDefaults).
    @Published private(set) var recentFolders: [URL] = []

    static let recentFoldersKey = "recentFolders"
    static let maxRecentFolders = 10

    /// Undo stack (session-only, lost on quit).
    private var undoStack: [UndoAction] = []

    /// Entries loaded from JSON whose files aren't in the current scan
    /// (moved away, partial mount). Preserved verbatim on save.
    private var orphanedEntries: [String: PhotoEntry] = [:]

    private let defaults: UserDefaults
    /// nonisolated(unsafe): written once in init, read once in deinit —
    /// never accessed concurrently.
    private nonisolated(unsafe) var terminateObserver: (any NSObjectProtocol)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let paths = defaults.stringArray(forKey: Self.recentFoldersKey) {
            recentFolders = paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
        }
        // Persist the browsing position (lastIndex) on quit — ratings are
        // saved on every change, but plain navigation isn't.
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.saveJSON()
            }
        }
    }

    deinit {
        if let terminateObserver {
            NotificationCenter.default.removeObserver(terminateObserver)
        }
    }

    /// Supported RAW UTTypes that CIRAWFilter can handle.
    nonisolated static let rawUTTypes: Set<UTType> = [
        .rawImage,
        UTType("com.canon.cr3-raw-image"),
        UTType("com.canon.cr2-raw-image"),
        UTType("com.nikon.nef-raw-image"),
        UTType("com.sony.arw-raw-image"),
        UTType("com.adobe.raw-image"),
        UTType("public.camera-raw-image"),
    ].compactMap { $0 }.reduce(into: Set<UTType>()) { $0.insert($1) }

    /// Select which files a folder scan should show: every RAW, plus JPEGs
    /// that have no RAW twin with the same basename. RAW+JPEG shooting thus
    /// lists only the RAW, while JPEG-only shots still appear.
    nonisolated static func selectPhotoFiles(from contents: [URL]) -> [URL] {
        var raws: [URL] = []
        var jpegs: [URL] = []
        for url in contents {
            guard let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType else { continue }
            if rawUTTypes.contains(where: { type.conforms(to: $0) }) {
                raws.append(url)
            } else if type.conforms(to: .jpeg) {
                jpegs.append(url)
            }
        }
        let rawBasenames = Set(raws.map { $0.deletingPathExtension().lastPathComponent })
        let soloJPEGs = jpegs.filter { !rawBasenames.contains($0.deletingPathExtension().lastPathComponent) }
        return (raws + soloJPEGs).sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }

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

    /// Ask the UI to present the export sheet.
    func requestExport() {
        exportRequest = UUID()
    }

    // MARK: - Export

    struct ExportProgress: Equatable {
        var completed: Int
        var total: Int
        var failed: Int
        var finished: Bool
    }

    private var exportTask: Task<Void, Never>?

    /// Stop a running export after the file currently being copied/moved.
    func cancelExport() {
        exportTask?.cancel()
    }

    /// Copy or move every file matching `predicate` into `destination`,
    /// publishing progress along the way. File I/O runs off the main actor.
    /// Hayate-written XMP sidecars travel with their photo. A move reloads
    /// the folder through the UI on completion (moved files leave the
    /// session; their entries survive as orphans in .hayate.json).
    func exportPicks(where predicate: (PhotoEntry?) -> Bool, to destination: URL, move: Bool) {
        // One export at a time.
        if let progress = exportProgress, !progress.finished { return }

        let targets = files.filter { predicate(entries[$0.lastPathComponent]) }
        guard !targets.isEmpty else { return }
        exportProgress = ExportProgress(completed: 0, total: targets.count, failed: 0, finished: false)
        let sourceFolder = folderURL

        exportTask = Task.detached(priority: .userInitiated) { [weak self] in
            let fm = FileManager.default
            var completed = 0
            var failed = 0
            for src in targets {
                guard !Task.isCancelled else { break }
                let dst = destination.appendingPathComponent(src.lastPathComponent)
                do {
                    // Never overwrite an existing file at the destination.
                    if fm.fileExists(atPath: dst.path) { throw CocoaError(.fileWriteFileExists) }
                    if move {
                        try fm.moveItem(at: src, to: dst)
                    } else {
                        try fm.copyItem(at: src, to: dst)
                    }
                    // Bring Hayate's sidecar along so ratings follow the file.
                    let srcXMP = src.deletingPathExtension().appendingPathExtension("xmp")
                    let dstXMP = dst.deletingPathExtension().appendingPathExtension("xmp")
                    if let content = try? String(contentsOf: srcXMP, encoding: .utf8),
                       content.contains(Self.xmpToolkitTag),
                       !fm.fileExists(atPath: dstXMP.path) {
                        if move {
                            try? fm.moveItem(at: srcXMP, to: dstXMP)
                        } else {
                            try? fm.copyItem(at: srcXMP, to: dstXMP)
                        }
                    }
                } catch {
                    failed += 1
                }
                completed += 1
                let progress = ExportProgress(completed: completed, total: targets.count, failed: failed, finished: false)
                await MainActor.run { [weak self] in self?.exportProgress = progress }
            }

            let final = ExportProgress(completed: completed, total: targets.count, failed: failed, finished: true)
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                self.exportProgress = final
                // Reload through the UI (directOpenRequest) so ContentView
                // resets textures/caches too — but only if the user is still
                // looking at the folder we exported from.
                if move, let folder = sourceFolder, self.folderURL == folder {
                    self.requestOpen(folder: folder)
                }
            }
        }
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

        // Scan before mutating any state so a failed open leaves the current
        // session (and its JSON) untouched.
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.contentTypeKey],
            options: [.skipsHiddenFiles]
        ) else { return false }

        // Persist the previous folder's position before switching away.
        if folderURL != nil {
            saveJSON()
        }

        folderURL = url
        undoStack.removeAll()
        addToRecents(url)

        files = Self.selectPhotoFiles(from: contents)

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
        defaults.set(paths, forKey: Self.recentFoldersKey)
    }

    /// Drop a folder from the recents list (e.g. it no longer exists).
    func removeFromRecents(_ url: URL) {
        let paths = recentFolders.map(\.path).filter { $0 != url.path }
        recentFolders = paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
        defaults.set(paths, forKey: Self.recentFoldersKey)
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
        writeXMPSidecar(forFileNamed: fileName)
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
        writeXMPSidecar(forFileNamed: fileName)
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
        writeXMPSidecar(forFileNamed: fileName)
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
            trashXMPSidecar(for: file)
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
        trashXMPSidecar(for: file)

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

        // Keep the sidecar in sync with the reverted state.
        switch action {
        case .ratingChange(let fileName, _),
             .favoriteChange(let fileName, _),
             .rejectedChange(let fileName, _):
            writeXMPSidecar(forFileNamed: fileName)
        case .deletion:
            break
        }

        saveJSON()
    }

    // MARK: - XMP Sidecar

    /// Serial queue for sidecar file I/O: keeps it off the main actor (batch
    /// operations touch one file per photo) while preserving write order for
    /// rapid changes to the same photo.
    private nonisolated static let xmpQueue = DispatchQueue(label: "com.hayate.xmp", qos: .utility)

    /// Marker identifying sidecars Hayate wrote. Files without it (Lightroom /
    /// Capture One sidecars carrying develop settings) are never modified.
    private nonisolated static let xmpToolkitTag = "x:xmptk=\"Hayate\""

    /// Test hook: block until all queued sidecar writes/trashes have finished.
    nonisolated static func flushXMPQueue() {
        xmpQueue.sync { }
    }

    /// Write (or refresh) a `<basename>.xmp` sidecar next to the RAW so
    /// Lightroom / Capture One can pick up ratings. Opt-in via Settings.
    /// Convention: rejected → xmp:Rating="-1" (Bridge), favorite → xmp:Label="Red".
    private func writeXMPSidecar(forFileNamed fileName: String) {
        guard defaults.bool(forKey: "writeXMPSidecars"), let folderURL = folderURL else { return }

        let rawURL = folderURL.appendingPathComponent(fileName)
        let xmpURL = rawURL.deletingPathExtension().appendingPathExtension("xmp")

        let entry = entries[fileName]
        let rating = entry?.rating ?? 0
        let isFavorite = entry?.isFavorite ?? false
        let isRejected = entry?.isRejected ?? false
        let hasState = rating > 0 || isFavorite || isRejected

        var attributes = "xmp:Rating=\"\(isRejected ? -1 : rating)\""
        if isFavorite {
            attributes += "\n   xmp:Label=\"Red\""
        }

        let xmp = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/" \(Self.xmpToolkitTag)>
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
           xmlns:xmp="http://ns.adobe.com/xap/1.0/"
           \(attributes)/>
         </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """

        Self.xmpQueue.async {
            let fm = FileManager.default
            if fm.fileExists(atPath: xmpURL.path) {
                // Never overwrite a sidecar another app created — Lightroom
                // and Capture One keep develop settings in theirs.
                guard let existing = try? String(contentsOf: xmpURL, encoding: .utf8),
                      existing.contains(Self.xmpToolkitTag) else { return }
            } else if !hasState {
                // Nothing to record and no stale sidecar to reset.
                return
            }
            try? Data(xmp.utf8).write(to: xmpURL, options: .atomic)
        }
    }

    /// Move a photo's Hayate-written sidecar to the Trash along with the
    /// photo itself. Foreign sidecars are left in place.
    private func trashXMPSidecar(for url: URL) {
        let xmpURL = url.deletingPathExtension().appendingPathExtension("xmp")
        Self.xmpQueue.async {
            guard let existing = try? String(contentsOf: xmpURL, encoding: .utf8),
                  existing.contains(Self.xmpToolkitTag) else { return }
            try? FileManager.default.trashItem(at: xmpURL, resultingItemURL: nil)
        }
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
            orphanedEntries = [:]
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

        // Split off entries whose files aren't visible right now (moved away,
        // partially mounted card, …). They are kept out of the UI but merged
        // back on save — otherwise merely opening and closing the folder in
        // that state would permanently erase their ratings.
        let fileNames = Set(files.map(\.lastPathComponent))
        entries = decoded.filter { fileNames.contains($0.key) }
        orphanedEntries = decoded.filter { !fileNames.contains($0.key) }

        // Resume where the user left off
        if let last = lastIndex, files.indices.contains(last) {
            currentIndex = last
        }
    }

    private func saveJSON() {
        guard let url = jsonURL else { return }

        // Only save entries that have non-default values
        let toSave = entries.filter { $0.value.rating > 0 || $0.value.isFavorite || $0.value.isRejected }

        // Merge back entries for files that weren't visible during this session.
        let all = toSave.merging(orphanedEntries) { current, _ in current }

        // Don't create a dotfile (position-only) in folders where the user
        // never rated anything — browsing alone shouldn't litter NAS/SD media.
        if all.isEmpty && !FileManager.default.fileExists(atPath: url.path) {
            return
        }

        let session = SessionData(entries: all, lastIndex: currentIndex)
        guard let data = try? JSONEncoder().encode(session) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
