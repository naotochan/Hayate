import XCTest
@testable import Hayate

@MainActor
final class CullingSessionTests: XCTestCase {

    private var session: CullingSession!
    private var tempDir: URL!

    override func setUp() async throws {
        session = CullingSession()
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

    // MARK: - JSON Persistence

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
              let decoded = try? JSONDecoder().decode([String: CullingSession.PhotoEntry].self, from: data) else {
            XCTFail("Could not read JSON")
            return
        }

        XCTAssertEqual(decoded["IMG_0001.CR3"]?.rating, 4)
        XCTAssertTrue(decoded["IMG_0002.CR3"]?.isFavorite == true)
        XCTAssertTrue(decoded["IMG_0003.CR3"]?.isRejected == true)
    }

    func testJSONOnlySavesNonDefault() {
        loadTestFiles(count: 3)

        // Only rate one file
        session.setRating(3)

        let jsonURL = tempDir.appendingPathComponent(".hayate.json")
        guard let data = try? Data(contentsOf: jsonURL),
              let decoded = try? JSONDecoder().decode([String: CullingSession.PhotoEntry].self, from: data) else {
            XCTFail("Could not read JSON")
            return
        }

        XCTAssertEqual(decoded.count, 1, "Only non-default entries should be saved")
        XCTAssertNotNil(decoded["IMG_0001.CR3"])
    }

    // MARK: - PhotoEntry

    func testPhotoEntryDefaults() {
        let entry = CullingSession.PhotoEntry(fileName: "test.CR3")
        XCTAssertEqual(entry.rating, 0)
        XCTAssertFalse(entry.isFavorite)
        XCTAssertFalse(entry.isRejected)
    }
}
