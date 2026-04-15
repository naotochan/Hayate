import XCTest
import AppKit
@testable import Hayate

@MainActor
final class KeybindingsTests: XCTestCase {

    private var store: KeybindingStore!

    override func setUp() async throws {
        // Isolate tests from real UserDefaults so one test's persistence
        // can't leak into the next.
        UserDefaults.standard.removeObject(forKey: KeybindingStore.storageKey)
        store = KeybindingStore()
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: KeybindingStore.storageKey)
        store = nil
    }

    // MARK: - Shortcut encoding

    func testShortcutDisplayNoModifiers() {
        XCTAssertEqual(Shortcut(keyCode: 38).display, "J")
        XCTAssertEqual(Shortcut(keyCode: 49).display, "Space")
        XCTAssertEqual(Shortcut(keyCode: 51).display, "⌫")
    }

    func testShortcutDisplayWithModifiers() {
        let cmdO = Shortcut(keyCode: 31, modifiers: .command)
        XCTAssertEqual(cmdO.display, "⌘O")

        let cmdShiftZ = Shortcut(keyCode: 6, modifiers: [.command, .shift])
        XCTAssertEqual(cmdShiftZ.display, "⇧⌘Z")
    }

    func testShortcutIgnoresIrrelevantModifiers() {
        // NumericPad / function / capsLock should not affect equality.
        let a = Shortcut(keyCode: 38, modifiers: [.command])
        let b = Shortcut(keyCode: 38, modifiers: [.command, .numericPad])
        XCTAssertEqual(a, b, "Only cmd/shift/opt/ctrl should matter for matching")
    }

    // MARK: - Defaults

    func testDefaultsInstalledOnFirstLaunch() {
        XCTAssertEqual(store.bindings[.navigateBack]?.keyCode, 38, "J by default")
        XCTAssertEqual(store.bindings[.navigateForward]?.keyCode, 37, "L by default")
        XCTAssertEqual(store.bindings[.openFolder]?.modifiers, .command)
    }

    // MARK: - Binding and conflict

    func testBindOverwritesPreviousAction() {
        let jKey = Shortcut(keyCode: 38) // J — defaults to navigateBack
        XCTAssertEqual(store.bindings[.navigateBack]?.keyCode, 38)

        // Now bind J to toggleGrid. navigateBack should be cleared.
        store.bind(jKey, to: .toggleGrid)

        XCTAssertEqual(store.bindings[.toggleGrid]?.keyCode, 38)
        XCTAssertNil(store.bindings[.navigateBack], "Conflicting action should be cleared")
    }

    func testBindSameShortcutToSameActionIsNoop() {
        let jKey = Shortcut(keyCode: 38)
        store.bind(jKey, to: .navigateBack)
        XCTAssertEqual(store.bindings[.navigateBack], jKey)
    }

    func testClearRemovesBinding() {
        store.clear(.navigateBack)
        XCTAssertNil(store.bindings[.navigateBack])
    }

    func testResetToDefaults() {
        store.clear(.navigateBack)
        store.bind(Shortcut(keyCode: 17), to: .toggleGrid) // T
        store.resetToDefaults()

        XCTAssertEqual(store.bindings[.navigateBack]?.keyCode, 38)
        XCTAssertEqual(store.bindings[.toggleGrid]?.keyCode, 5, "G by default")
    }

    // MARK: - Persistence

    func testBindingsSurviveReload() {
        let newShortcut = Shortcut(keyCode: 17) // T
        store.bind(newShortcut, to: .toggleGrid)

        let reloaded = KeybindingStore()
        XCTAssertEqual(reloaded.bindings[.toggleGrid], newShortcut)
    }

    func testNewlyAddedActionsGetDefaultsAfterUpgrade() {
        // Simulate an old save that only contains a subset of actions
        // (as if ActionID was extended in a new release).
        let partial: [ActionID: Shortcut] = [
            .navigateBack: Shortcut(keyCode: 38),
        ]
        let data = try! JSONEncoder().encode(partial)
        UserDefaults.standard.set(data, forKey: KeybindingStore.storageKey)

        let reloaded = KeybindingStore()
        XCTAssertEqual(reloaded.bindings[.navigateBack]?.keyCode, 38)
        XCTAssertNotNil(reloaded.bindings[.toggleGrid],
                        "Actions missing from the saved file should fall back to defaults")
    }
}
