import XCTest
@testable import Hayate

@MainActor
final class CullingSessionTests: XCTestCase {

    private var session: CullingSession!
    private var tempDir: URL!
    private var testDefaults: UserDefaults!

    /// Isolated defaults so tests don't pollute the real recent-folders list.
    private func makeSession() -> CullingSession {
        CullingSession(defaults: testDefaults)
    }

    override func setUp() async throws {
        testDefaults = UserDefaults(suiteName: "HayateTests-\(UUID().uuidString)")
        session = makeSession()
        // Create a temp directory with fake files to simulate a folder
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PicSortTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        session = nil
        tempDir = nil
    }

    // MARK: - Helpers

    /// Create dummy files in tempDir and load them into the session.
    /// Uses .jpg extension since we can't easily create real RAW files,
    /// so we test the session logic by injecting files directly.
    private func loadTestFiles(count: Int) {
        var urls: [URL] = []
        for i in 1...count {
            let name = String(format: "IMG_%04d.CR3", i)
            let url = tempDir.appendingPathComponent(name)
            FileManager.default.createFile(atPath: url.path, contents: Data())
            urls.append(url)
        }
        // Inject files directly (bypassing openFolder which filters by UTType)
        session.folderURL = tempDir
        session.files = urls.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        session.currentIndex = 0
    }

    // MARK: - Navigation

    func testNavigationForward() {
        loadTestFiles(count: 5)

        XCTAssertEqual(session.currentIndex, 0)
        session.navigateForward()
        XCTAssertEqual(session.currentIndex, 1)
        session.navigateForward()
        XCTAssertEqual(session.currentIndex, 2)
    }

    func testNavigationForwardClampsAtEnd() {
        loadTestFiles(count: 3)

        session.currentIndex = 2
        session.navigateForward()
        XCTAssertEqual(session.currentIndex, 2, "Should not go past last file")
    }

    func testNavigationBack() {
        loadTestFiles(count: 5)
        session.currentIndex = 3

        session.navigateBack()
        XCTAssertEqual(session.currentIndex, 2)
    }

    func testNavigationBackClampsAtStart() {
        loadTestFiles(count: 3)

        session.navigateBack()
        XCTAssertEqual(session.currentIndex, 0, "Should not go below 0")
    }

    func testCurrentFile() {
        loadTestFiles(count: 3)
        XCTAssertEqual(session.currentFile?.lastPathComponent, "IMG_0001.CR3")

        session.currentIndex = 2
        XCTAssertEqual(session.currentFile?.lastPathComponent, "IMG_0003.CR3")
    }

    func testCurrentFileEmptyList() {
        XCTAssertNil(session.currentFile)
    }

    // MARK: - Rating

    func testSetRating() {
        loadTestFiles(count: 3)

        session.setRating(3)
        XCTAssertEqual(session.currentEntry?.rating, 3)
    }

    func testSetRatingClampsRange() {
        loadTestFiles(count: 1)

        session.setRating(10)
        XCTAssertEqual(session.currentEntry?.rating, 5, "Rating should clamp to 5")

        session.setRating(-1)
        XCTAssertEqual(session.currentEntry?.rating, 0, "Rating should clamp to 0")
    }

    func testSetRatingZeroClears() {
        loadTestFiles(count: 1)

        session.setRating(4)
        XCTAssertEqual(session.currentEntry?.rating, 4)

        session.setRating(0)
        XCTAssertEqual(session.currentEntry?.rating, 0)
    }

    func testBatchSetRating() {
        loadTestFiles(count: 5)

        session.setRatingForIndices(Set([0, 2, 4]), rating: 3)

        XCTAssertEqual(session.entries["IMG_0001.CR3"]?.rating, 3)
        XCTAssertNil(session.entries["IMG_0002.CR3"]?.rating)
        XCTAssertEqual(session.entries["IMG_0003.CR3"]?.rating, 3)
        XCTAssertNil(session.entries["IMG_0004.CR3"]?.rating)
        XCTAssertEqual(session.entries["IMG_0005.CR3"]?.rating, 3)
    }

    // MARK: - Favorite

    func testToggleFavorite() {
        loadTestFiles(count: 1)

        session.toggleFavorite()
        XCTAssertTrue(session.currentEntry?.isFavorite == true)

        session.toggleFavorite()
        XCTAssertTrue(session.currentEntry?.isFavorite == false)
    }

    func testFavoriteExclusiveWithReject() {
        loadTestFiles(count: 1)

        // Reject first
        session.toggleRejected()
        XCTAssertTrue(session.currentEntry?.isRejected == true)

        // Favorite should clear reject
        session.toggleFavorite()
        XCTAssertTrue(session.currentEntry?.isFavorite == true)
        XCTAssertTrue(session.currentEntry?.isRejected == false)
    }

    func testBatchFavorite() {
        loadTestFiles(count: 3)

        session.toggleFavoriteForIndices(Set([0, 2]))
        XCTAssertTrue(session.entries["IMG_0001.CR3"]?.isFavorite == true)
        XCTAssertNil(session.entries["IMG_0002.CR3"])
        XCTAssertTrue(session.entries["IMG_0003.CR3"]?.isFavorite == true)
    }

    // MARK: - Reject

    func testToggleRejected() {
        loadTestFiles(count: 1)

        session.toggleRejected()
        XCTAssertTrue(session.currentEntry?.isRejected == true)

        session.toggleRejected()
        XCTAssertTrue(session.currentEntry?.isRejected == false)
    }

    func testRejectExclusiveWithFavorite() {
        loadTestFiles(count: 1)

        // Favorite first
        session.toggleFavorite()
        XCTAssertTrue(session.currentEntry?.isFavorite == true)

        // Reject should clear favorite
        session.toggleRejected()
        XCTAssertTrue(session.currentEntry?.isRejected == true)
        XCTAssertTrue(session.currentEntry?.isFavorite == false)
    }

    func testBatchRejectExclusiveWithFavorite() {
        loadTestFiles(count: 3)

        // Favorite first
        session.toggleFavoriteForIndices(Set([0, 1, 2]))
        // Reject should clear favorites
        session.toggleRejectedForIndices(Set([0, 1, 2]))

        for name in ["IMG_0001.CR3", "IMG_0002.CR3", "IMG_0003.CR3"] {
            XCTAssertTrue(session.entries[name]?.isRejected == true)
            XCTAssertTrue(session.entries[name]?.isFavorite == false, "\(name) favorite should be cleared")
        }
    }

    // MARK: - Undo

    func testUndoRating() {
        loadTestFiles(count: 1)

        session.setRating(4)
        XCTAssertEqual(session.currentEntry?.rating, 4)

        session.undo()
        XCTAssertEqual(session.currentEntry?.rating, 0)
    }

    func testUndoFavorite() {
        loadTestFiles(count: 1)

        session.toggleFavorite()
        XCTAssertTrue(session.currentEntry?.isFavorite == true)

        session.undo()
        XCTAssertTrue(session.currentEntry?.isFavorite == false)
    }

    func testUndoRejected() {
        loadTestFiles(count: 1)

        session.toggleRejected()
        XCTAssertTrue(session.currentEntry?.isRejected == true)

        session.undo()
        XCTAssertTrue(session.currentEntry?.isRejected == false)
    }

    func testUndoMultipleActions() {
        loadTestFiles(count: 1)

        session.setRating(3)
        session.toggleFavorite()
        session.setRating(5)

        session.undo()
        XCTAssertEqual(session.currentEntry?.rating, 3)

        session.undo()
        XCTAssertTrue(session.currentEntry?.isFavorite == false)

        session.undo()
        XCTAssertEqual(session.currentEntry?.rating, 0)
    }

    func testUndoOnEmptyStackDoesNothing() {
        loadTestFiles(count: 1)
        session.undo() // Should not crash
        XCTAssertNil(session.currentEntry)
    }

    // MARK: - Deletion

    func testDeleteCurrentFile() {
        loadTestFiles(count: 3)

        let deleted = session.deleteCurrentFile()
        XCTAssertTrue(deleted)
        XCTAssertEqual(session.files.count, 2)
        XCTAssertEqual(session.currentIndex, 0)
    }

    func testDeleteLastFileAdjustsIndex() {
        loadTestFiles(count: 3)
        session.currentIndex = 2

        let deleted = session.deleteCurrentFile()
        XCTAssertTrue(deleted)
        XCTAssertEqual(session.files.count, 2)
        XCTAssertEqual(session.currentIndex, 1, "Index should move back after deleting last item")
    }

    func testDeleteRemovesEntry() {
        loadTestFiles(count: 2)
        session.setRating(5)

        let fileName = session.currentFile!.lastPathComponent
        _ = session.deleteCurrentFile()

        XCTAssertNil(session.entries[fileName], "Entry should be removed on delete")
    }

    func testBatchDeleteRemovesAllSelected() {
        loadTestFiles(count: 5)
        // Mark a few as rejected and rate one of the survivors so we can
        // verify entries are pruned together with files.
        session.setRatingForIndices(Set([0, 2, 4]), rating: 3)

        let deleted = session.deleteFilesAtIndices(Set([0, 2, 4]))

        XCTAssertEqual(deleted, 3)
        XCTAssertEqual(session.files.count, 2)
        XCTAssertEqual(session.files.map(\.lastPathComponent), ["IMG_0002.CR3", "IMG_0004.CR3"])
        XCTAssertNil(session.entries["IMG_0001.CR3"], "Deleted entries should be pruned")
        XCTAssertNil(session.entries["IMG_0003.CR3"])
        XCTAssertNil(session.entries["IMG_0005.CR3"])
    }

    func testBatchDeleteClampsCurrentIndex() {
        loadTestFiles(count: 4)
        session.currentIndex = 3

        let deleted = session.deleteFilesAtIndices(Set([2, 3]))

        XCTAssertEqual(deleted, 2)
        XCTAssertEqual(session.files.count, 2)
        XCTAssertEqual(session.currentIndex, 1, "currentIndex should clamp into the new range")
    }

    func testBatchDeletePredecessorsPreservesCurrent() {
        loadTestFiles(count: 5)
        session.currentIndex = 3 // IMG_0004.CR3

        let deleted = session.deleteFilesAtIndices(Set([0, 1]))

        XCTAssertEqual(deleted, 2)
        XCTAssertEqual(session.files.count, 3)
        XCTAssertEqual(session.currentIndex, 1, "currentIndex should shift down by deleted predecessors")
        XCTAssertEqual(session.currentFile?.lastPathComponent, "IMG_0004.CR3", "Should still display the same file")
    }

    func testBatchDeleteEmptiesFolder() {
        loadTestFiles(count: 2)

        let deleted = session.deleteFilesAtIndices(Set([0, 1]))

        XCTAssertEqual(deleted, 2)
        XCTAssertTrue(session.files.isEmpty)
        XCTAssertEqual(session.currentIndex, 0)
    }

    // MARK: - JSON Persistence

    /// Mirror of CullingSession's on-disk format (the type itself is private).
    private struct SessionData: Codable {
        var entries: [String: CullingSession.PhotoEntry]
        var lastIndex: Int?
    }

    func testJSONRoundTrip() {
        loadTestFiles(count: 3)

        session.setRating(4)
        session.navigateForward()
        session.toggleFavorite()
        session.navigateForward()
        session.toggleRejected()

        // Write JSON manually using the same path convention
        let jsonURL = tempDir.appendingPathComponent(".hayate.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: jsonURL.path), "JSON file should exist")

        // Read it back
        guard let data = try? Data(contentsOf: jsonURL),
              let decoded = try? JSONDecoder().decode(SessionData.self, from: data) else {
            XCTFail("Could not read JSON")
            return
        }

        XCTAssertEqual(decoded.entries["IMG_0001.CR3"]?.rating, 4)
        XCTAssertTrue(decoded.entries["IMG_0002.CR3"]?.isFavorite == true)
        XCTAssertTrue(decoded.entries["IMG_0003.CR3"]?.isRejected == true)
        XCTAssertEqual(decoded.lastIndex, 2, "Position at save time should be persisted")
    }

    func testJSONOnlySavesNonDefault() {
        loadTestFiles(count: 3)

        // Only rate one file
        session.setRating(3)

        let jsonURL = tempDir.appendingPathComponent(".hayate.json")
        guard let data = try? Data(contentsOf: jsonURL),
              let decoded = try? JSONDecoder().decode(SessionData.self, from: data) else {
            XCTFail("Could not read JSON")
            return
        }

        XCTAssertEqual(decoded.entries.count, 1, "Only non-default entries should be saved")
        XCTAssertNotNil(decoded.entries["IMG_0001.CR3"])
    }

    func testJSONLegacyFormatMigration() {
        // Write the pre-lastIndex format: a bare entries dictionary.
        loadTestFiles(count: 3)
        let legacy = ["IMG_0002.CR3": CullingSession.PhotoEntry(fileName: "IMG_0002.CR3", rating: 5)]
        let jsonURL = tempDir.appendingPathComponent(".hayate.json")
        try? JSONEncoder().encode(legacy).write(to: jsonURL)

        // Open in a fresh session: re-opening via `session` would first persist
        // its current (empty) state over the legacy file we just wrote.
        let fresh = makeSession()
        fresh.openFolder(tempDir)
        XCTAssertEqual(fresh.entries["IMG_0002.CR3"]?.rating, 5)
        XCTAssertEqual(fresh.currentIndex, 0, "Legacy format has no lastIndex")
    }

    func testJSONRestoresLastIndex() {
        loadTestFiles(count: 5)

        session.currentIndex = 3
        session.setRating(2)  // triggers save with lastIndex = 3

        // Re-open the same folder in a fresh session
        let fresh = makeSession()
        fresh.openFolder(tempDir)
        XCTAssertEqual(fresh.currentIndex, 3, "Should resume at the saved position")
    }

    // MARK: - RAW+JPEG pairing

    func testSelectPhotoFilesPrefersRAWOverJPEGTwin() {
        let names = ["IMG_0001.CR3", "IMG_0001.JPG", "IMG_0002.JPG", "IMG_0003.NEF", "notes.txt"]
        for name in names {
            FileManager.default.createFile(
                atPath: tempDir.appendingPathComponent(name).path, contents: Data())
        }
        let contents = names.map { tempDir.appendingPathComponent($0) }

        let selected = CullingSession.selectPhotoFiles(from: contents).map(\.lastPathComponent)

        // RAW wins over its JPEG twin; solo JPEGs stay; non-images drop.
        XCTAssertEqual(selected, ["IMG_0001.CR3", "IMG_0002.JPG", "IMG_0003.NEF"])
    }

    // MARK: - XMP Sidecar

    func testXMPSidecarWrittenWhenEnabled() {
        testDefaults.set(true, forKey: "writeXMPSidecars")
        loadTestFiles(count: 2)

        session.setRating(4)
        CullingSession.flushXMPQueue()

        let xmpURL = tempDir.appendingPathComponent("IMG_0001.xmp")
        XCTAssertTrue(FileManager.default.fileExists(atPath: xmpURL.path))
        let content = (try? String(contentsOf: xmpURL, encoding: .utf8)) ?? ""
        XCTAssertTrue(content.contains("xmp:Rating=\"4\""))

        // Rejected → -1, favorite → Red label
        session.navigateForward()
        session.toggleRejected()
        CullingSession.flushXMPQueue()
        let xmp2URL = tempDir.appendingPathComponent("IMG_0002.xmp")
        var content2 = (try? String(contentsOf: xmp2URL, encoding: .utf8)) ?? ""
        XCTAssertTrue(content2.contains("xmp:Rating=\"-1\""))

        session.toggleFavorite()  // clears rejected, sets favorite
        CullingSession.flushXMPQueue()
        content2 = (try? String(contentsOf: xmp2URL, encoding: .utf8)) ?? ""
        XCTAssertTrue(content2.contains("xmp:Label=\"Red\""))
        XCTAssertTrue(content2.contains("xmp:Rating=\"0\""))
    }

    func testXMPSidecarLeavesForeignFilesAlone() {
        testDefaults.set(true, forKey: "writeXMPSidecars")
        loadTestFiles(count: 1)

        // Simulate a Lightroom sidecar (no Hayate toolkit tag).
        let xmpURL = tempDir.appendingPathComponent("IMG_0001.xmp")
        let foreign = "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\" x:xmptk=\"Adobe XMP Core\">develop settings</x:xmpmeta>"
        try? Data(foreign.utf8).write(to: xmpURL)

        session.setRating(4)
        CullingSession.flushXMPQueue()

        let content = (try? String(contentsOf: xmpURL, encoding: .utf8)) ?? ""
        XCTAssertEqual(content, foreign, "Foreign sidecars must never be modified")

        // And deletion must not trash it either.
        _ = session.deleteCurrentFile()
        CullingSession.flushXMPQueue()
        XCTAssertTrue(FileManager.default.fileExists(atPath: xmpURL.path))
    }

    func testXMPSidecarNotWrittenWhenDisabled() {
        loadTestFiles(count: 1)
        session.setRating(5)
        CullingSession.flushXMPQueue()
        let xmpURL = tempDir.appendingPathComponent("IMG_0001.xmp")
        XCTAssertFalse(FileManager.default.fileExists(atPath: xmpURL.path))
    }

    func testXMPSidecarTrashedWithPhoto() {
        testDefaults.set(true, forKey: "writeXMPSidecars")
        loadTestFiles(count: 1)
        session.setRating(3)
        CullingSession.flushXMPQueue()

        let xmpURL = tempDir.appendingPathComponent("IMG_0001.xmp")
        XCTAssertTrue(FileManager.default.fileExists(atPath: xmpURL.path))

        XCTAssertTrue(session.deleteCurrentFile())
        CullingSession.flushXMPQueue()
        XCTAssertFalse(FileManager.default.fileExists(atPath: xmpURL.path), "Sidecar should be trashed with the photo")
    }

    // MARK: - PhotoEntry

    func testPhotoEntryDefaults() {
        let entry = CullingSession.PhotoEntry(fileName: "test.CR3")
        XCTAssertEqual(entry.rating, 0)
        XCTAssertFalse(entry.isFavorite)
        XCTAssertFalse(entry.isRejected)
    }
}
