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
    /// User-pinned folders for the sidebar (persisted, order preserved).
    @Published private(set) var pinnedFolders: [URL] = []

    static let recentFoldersKey = "recentFolders"
    static let pinnedFoldersKey = "pinnedFolders"
    static let maxRecentFolders = 10
    static let maxPinnedFolders = 20

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
            // Drop ephemeral test / system temp folders that leaked into
            // preferences; keep everything else (including unmounted volumes)
            // so the user can still see the names.
            recentFolders = Self.sanitizeFolderPaths(paths)
            if recentFolders.map(\.path) != paths {
                defaults.set(recentFolders.map(\.path), forKey: Self.recentFoldersKey)
            }
        }
        if let paths = defaults.stringArray(forKey: Self.pinnedFoldersKey) {
            pinnedFolders = Self.sanitizeFolderPaths(paths)
            if pinnedFolders.map(\.path) != paths {
                defaults.set(pinnedFolders.map(\.path), forKey: Self.pinnedFoldersKey)
            }
        }
        // Persist the browsing position (lastFileName / lastIndex) on quit —
        // ratings are saved on every change, but plain navigation isn't.
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

    /// A RAW's hidden JPEG twin (same basename; not shown in the list), if
    /// one exists on disk. Pairs are treated as one photo, so deletion and
    /// move-export take the twin along.
    nonisolated static func jpegTwinURL(for url: URL) -> URL? {
        guard let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType,
              rawUTTypes.contains(where: { type.conforms(to: $0) }) else { return nil }
        let base = url.deletingPathExtension()
        for ext in ["jpg", "JPG", "jpeg", "JPEG"] {
            let candidate = base.appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
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

    /// Three-value culling profile (Keep / Maybe / Out), stored on top of the
    /// existing favorite / rating / reject fields so `.hayate.json` stays compatible.
    enum TriageState: Equatable {
        case undecided
        case keep
        case maybe
        case out

        /// Rating written for Maybe (stars profile still uses the full 1–5 range).
        static let maybeRating = 3

        static func of(_ entry: PhotoEntry?) -> TriageState {
            guard let entry else { return .undecided }
            if entry.isRejected { return .out }
            if entry.isFavorite { return .keep }
            if entry.rating > 0 { return .maybe }
            return .undecided
        }
    }

    enum UndoAction {
        case ratingChange(fileName: String, oldRating: Int)
        case favoriteChange(fileName: String, oldValue: Bool)
        case rejectedChange(fileName: String, oldValue: Bool)
        /// Compound restore for triage (Keep/Maybe/Out) so ⌘Z undoes in one step.
        case entrySnapshot(fileName: String, oldEntry: PhotoEntry?)
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
        let jobs = files.compactMap { src -> (URL, URL)? in
            guard predicate(entries[src.lastPathComponent]) else { return nil }
            return (src, destination)
        }
        startExport(jobs: jobs, move: move)
    }

    /// Place each Keep / Maybe / Out photo into sibling folders of that name
    /// under the current shoot (`…/Keep`, `…/Maybe`, `…/Out`). Undecided
    /// photos stay put. Creates the folders as needed.
    func organizeIntoTriageFolders(move: Bool) {
        guard let root = folderURL else { return }
        let jobs = files.compactMap { src -> (URL, URL)? in
            switch TriageState.of(entries[src.lastPathComponent]) {
            case .keep:
                return (src, root.appendingPathComponent("Keep", isDirectory: true))
            case .maybe:
                return (src, root.appendingPathComponent("Maybe", isDirectory: true))
            case .out:
                return (src, root.appendingPathComponent("Out", isDirectory: true))
            case .undecided:
                return nil
            }
        }
        startExport(jobs: jobs, move: move)
    }

    /// `(source file, destination directory)` pairs.
    private func startExport(jobs: [(URL, URL)], move: Bool) {
        // One export at a time.
        if let progress = exportProgress, !progress.finished { return }
        guard !jobs.isEmpty else { return }

        exportProgress = ExportProgress(completed: 0, total: jobs.count, failed: 0, finished: false)
        let sourceFolder = folderURL

        exportTask = Task.detached(priority: .userInitiated) { [weak self] in
            let fm = FileManager.default
            var completed = 0
            var failed = 0
            for (src, destination) in jobs {
                guard !Task.isCancelled else { break }
                do {
                    try fm.createDirectory(at: destination, withIntermediateDirectories: true)
                    let dst = destination.appendingPathComponent(src.lastPathComponent)
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
                    // A RAW's hidden JPEG twin travels too.
                    if let twin = Self.jpegTwinURL(for: src) {
                        let twinDst = destination.appendingPathComponent(twin.lastPathComponent)
                        if !fm.fileExists(atPath: twinDst.path) {
                            if move {
                                try? fm.moveItem(at: twin, to: twinDst)
                            } else {
                                try? fm.copyItem(at: twin, to: twinDst)
                            }
                        }
                    }
                } catch {
                    failed += 1
                }
                completed += 1
                let progress = ExportProgress(
                    completed: completed,
                    total: jobs.count,
                    failed: failed,
                    finished: false
                )
                await MainActor.run { [weak self] in self?.exportProgress = progress }
            }

            let final = ExportProgress(
                completed: completed,
                total: jobs.count,
                failed: failed,
                finished: true
            )
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

        // Load existing JSON (may restore lastFileName / lastIndex)
        loadJSON()
        return true
    }

    /// Move `url` to the front of the recent-folders list and persist it.
    private func addToRecents(_ url: URL) {
        // Never persist ephemeral test / system temp directories.
        let path = url.path
        guard Self.isPersistableFolderPath(path) else { return }

        var paths = [path] + recentFolders.map(\.path).filter { $0 != path }
        if paths.count > Self.maxRecentFolders {
            paths = Array(paths.prefix(Self.maxRecentFolders))
        }
        recentFolders = paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
        defaults.set(paths, forKey: Self.recentFoldersKey)
    }

    /// Drop a folder from the recents list (e.g. it no longer exists).
    func removeFromRecents(_ url: URL) {
        let path = url.standardizedFileURL.path
        let paths = recentFolders.map(\.path).filter { $0 != path }
        recentFolders = paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
        defaults.set(paths, forKey: Self.recentFoldersKey)
    }

    /// Recent folders excluding the one currently open (path-based, so
    /// trailing-slash / fileURL differences don't hide the list).
    var otherRecentFolders: [URL] {
        let current = folderURL?.standardizedFileURL.path
        return recentFolders.filter { $0.standardizedFileURL.path != current }
    }

    /// Recent folders that aren't already pinned (for the sidebar Recent section).
    var unpinnedRecentFolders: [URL] {
        let pinned = Set(pinnedFolders.map { $0.standardizedFileURL.path })
        return recentFolders.filter { !pinned.contains($0.standardizedFileURL.path) }
    }

    func isPinned(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return pinnedFolders.contains { $0.standardizedFileURL.path == path }
    }

    func pinFolder(_ url: URL) {
        let path = url.standardizedFileURL.path
        guard Self.isPersistableFolderPath(path) else { return }
        guard !isPinned(url) else { return }
        var paths = pinnedFolders.map(\.path) + [path]
        if paths.count > Self.maxPinnedFolders {
            paths = Array(paths.suffix(Self.maxPinnedFolders))
        }
        pinnedFolders = paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
        defaults.set(paths, forKey: Self.pinnedFoldersKey)
    }

    func unpinFolder(_ url: URL) {
        let path = url.standardizedFileURL.path
        let paths = pinnedFolders.map(\.path).filter { $0 != path }
        pinnedFolders = paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
        defaults.set(paths, forKey: Self.pinnedFoldersKey)
    }

    func togglePinned(_ url: URL) {
        if isPinned(url) {
            unpinFolder(url)
        } else {
            pinFolder(url)
        }
    }

    private static func isPersistableFolderPath(_ path: String) -> Bool {
        !path.hasPrefix("/var/folders/") && !path.hasPrefix("/tmp/")
    }

    private static func sanitizeFolderPaths(_ paths: [String]) -> [URL] {
        paths
            .filter { isPersistableFolderPath($0) }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
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

    func navigateForward(undecidedOnly: Bool = false, triageMode: Bool = true) {
        guard let next = nextIndex(
            from: currentIndex,
            step: 1,
            undecidedOnly: undecidedOnly,
            triageMode: triageMode
        ) else { return }
        currentIndex = next
    }

    func navigateBack(undecidedOnly: Bool = false, triageMode: Bool = true) {
        guard let prev = nextIndex(
            from: currentIndex,
            step: -1,
            undecidedOnly: undecidedOnly,
            triageMode: triageMode
        ) else { return }
        currentIndex = prev
    }

    /// Walk `step` (±1) from `from`, optionally skipping photos that already
    /// have a culling decision. Returns nil when nothing in that direction qualifies.
    func nextIndex(
        from: Int,
        step: Int,
        undecidedOnly: Bool,
        triageMode: Bool
    ) -> Int? {
        guard step == 1 || step == -1 else { return nil }
        var i = from + step
        while files.indices.contains(i) {
            if !undecidedOnly || !isDecided(fileNamed: files[i].lastPathComponent, triageMode: triageMode) {
                return i
            }
            i += step
        }
        return nil
    }

    /// Whether the photo already has a decision worth skipping in survey mode.
    func isDecided(fileNamed name: String, triageMode: Bool) -> Bool {
        let entry = entries[name]
        if triageMode {
            return TriageState.of(entry) != .undecided
        }
        guard let entry else { return false }
        return entry.rating > 0 || entry.isFavorite || entry.isRejected
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

    /// Set triage state for the current photo. Tapping the same state again clears to undecided.
    func setTriage(_ state: TriageState) {
        guard let file = currentFile else { return }
        applyTriage(state, toFileNamed: file.lastPathComponent)
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

    func setTriageForIndices(_ indices: Set<Int>, _ state: TriageState) {
        forEachFileName(in: indices) { applyTriage(state, toFileNamed: $0) }
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

    /// Apply an exclusive triage state. Same state again → undecided.
    /// Mapping: Keep→favorite, Out→reject, Maybe→rating 3 (clears the other two).
    private func applyTriage(_ state: TriageState, toFileNamed fileName: String) {
        let previous = entries[fileName]
        let current = TriageState.of(previous)
        let target: TriageState = (current == state && state != .undecided) ? .undecided : state

        undoStack.append(.entrySnapshot(fileName: fileName, oldEntry: previous))

        var entry = previous ?? PhotoEntry(fileName: fileName)
        switch target {
        case .undecided:
            entry.isFavorite = false
            entry.isRejected = false
            entry.rating = 0
        case .keep:
            entry.isFavorite = true
            entry.isRejected = false
            entry.rating = 0
        case .maybe:
            entry.isFavorite = false
            entry.isRejected = false
            entry.rating = TriageState.maybeRating
        case .out:
            entry.isFavorite = false
            entry.isRejected = true
            entry.rating = 0
        }

        if entry.isFavorite || entry.isRejected || entry.rating > 0 {
            entries[fileName] = entry
        } else {
            entries[fileName] = nil
        }
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
            if let twin = Self.jpegTwinURL(for: file) {
                try? FileManager.default.trashItem(at: twin, resultingItemURL: nil)
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
        trashXMPSidecar(for: file)
        if let twin = Self.jpegTwinURL(for: file) {
            try? FileManager.default.trashItem(at: twin, resultingItemURL: nil)
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

        case .entrySnapshot(let fileName, let oldEntry):
            entries[fileName] = oldEntry

        case .deletion:
            // File deletion undo is not supported (trashed items can be recovered via Finder)
            break
        }

        // Keep the sidecar in sync with the reverted state.
        switch action {
        case .ratingChange(let fileName, _),
             .favoriteChange(let fileName, _),
             .rejectedChange(let fileName, _),
             .entrySnapshot(let fileName, _):
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
        } else if rating > 0 {
            // Maybe (triage) — Bridge yellow label so it survives into other apps.
            attributes += "\n   xmp:Label=\"Yellow\""
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
    /// Prefer `lastFileName` (survives inserts/deletes); `lastIndex` is a
    /// legacy fallback. Oldest format was a bare `[String: PhotoEntry]`.
    private struct SessionData: Codable {
        var entries: [String: PhotoEntry]
        var lastIndex: Int?
        var lastFileName: String?
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
        var lastFileName: String?
        if let session = try? JSONDecoder().decode(SessionData.self, from: data) {
            decoded = session.entries
            lastIndex = session.lastIndex
            lastFileName = session.lastFileName
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

        // Resume where the user left off — basename first, then index.
        if let name = lastFileName,
           let idx = files.firstIndex(where: { $0.lastPathComponent == name }) {
            currentIndex = idx
        } else if let last = lastIndex, files.indices.contains(last) {
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

        let lastFileName = files.indices.contains(currentIndex)
            ? files[currentIndex].lastPathComponent
            : nil
        let session = SessionData(
            entries: all,
            lastIndex: currentIndex,
            lastFileName: lastFileName
        )
        guard let data = try? JSONEncoder().encode(session) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
