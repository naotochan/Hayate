import Foundation
import AppKit

/// A physical key combination the user typed. Identified by hardware keyCode
/// (layout-independent) and a normalised modifier mask.
struct Shortcut: Codable, Hashable {
    let keyCode: UInt16
    let modifierMask: UInt

    static let relevantModifiers: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) {
        self.keyCode = keyCode
        self.modifierMask = modifiers.intersection(Self.relevantModifiers).rawValue
    }

    init?(event: NSEvent) {
        guard event.type == .keyDown else { return nil }
        self.keyCode = event.keyCode
        self.modifierMask = event.modifierFlags
            .intersection(Self.relevantModifiers)
            .rawValue
    }

    var modifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifierMask)
    }

    /// Human-readable glyphs: ⌘⇧O, J, ⌫, etc.
    var display: String {
        // Shift+/ is the conventional "?" help key — show it as such.
        if keyCode == 44, modifiers == .shift {
            return "?"
        }
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        s += Self.keyName(for: keyCode)
        return s
    }

    private static func keyName(for code: UInt16) -> String {
        // ANSI US layout virtual key codes (HIToolbox/Events.h).
        switch code {
        case 0: return "A"
        case 1: return "S"
        case 2: return "D"
        case 3: return "F"
        case 4: return "H"
        case 5: return "G"
        case 6: return "Z"
        case 7: return "X"
        case 8: return "C"
        case 9: return "V"
        case 11: return "B"
        case 12: return "Q"
        case 13: return "W"
        case 14: return "E"
        case 15: return "R"
        case 16: return "Y"
        case 17: return "T"
        case 31: return "O"
        case 32: return "U"
        case 34: return "I"
        case 35: return "P"
        case 37: return "L"
        case 38: return "J"
        case 40: return "K"
        case 45: return "N"
        case 46: return "M"
        case 36: return "↵"
        case 48: return "⇥"
        case 49: return "Space"
        case 51: return "⌫"
        case 53: return "⎋"
        case 117: return "⌦"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 18: return "1"
        case 19: return "2"
        case 20: return "3"
        case 21: return "4"
        case 22: return "5"
        case 23: return "6"
        case 26: return "7"
        case 28: return "8"
        case 25: return "9"
        case 29: return "0"
        case 44: return "/"
        default: return "key \(code)"
        }
    }
}

/// Rebindable actions. Rating digits, Escape, and Cmd+, are intentionally
/// excluded — those stay hardcoded in the key handler.
enum ActionID: String, Codable, CaseIterable, Identifiable {
    case navigateBack
    case navigateForward
    case toggleFavorite
    case toggleRejected
    case setTriageMaybe
    case toggleGrid
    case toggleCompare
    case toggleFitZoom
    case toggleFocusPeaking
    case toggleCullModeDraft
    case toggleInfo
    case toggleHistogram
    case toggleShortcutsHelp
    case toggleSidebar
    case deletePhoto
    case undo
    case selectAllGrid
    case openFolder
    case pickCompare
    case skipNextBaseline

    var id: String { rawValue }

    var title: String {
        switch self {
        case .navigateBack: return "Previous photo"
        case .navigateForward: return "Next photo"
        case .toggleFavorite: return "Toggle favorite / Keep"
        case .toggleRejected: return "Toggle rejected / Out"
        case .setTriageMaybe: return "Maybe (triage)"
        case .toggleGrid: return "Toggle grid view"
        case .toggleCompare: return "Toggle compare mode"
        case .toggleFitZoom: return "Toggle fit / 2× zoom"
        case .toggleFocusPeaking: return "Toggle focus peaking"
        case .toggleCullModeDraft: return "Toggle draft cull mode"
        case .toggleInfo: return "Toggle info overlay (EXIF)"
        case .toggleHistogram: return "Toggle histogram"
        case .toggleShortcutsHelp: return "Show keyboard shortcuts"
        case .toggleSidebar: return "Toggle folder sidebar"
        case .deletePhoto: return "Move photo to Trash"
        case .undo: return "Undo"
        case .selectAllGrid: return "Select all (grid)"
        case .openFolder: return "Open folder…"
        case .pickCompare: return "Pick active (compare)"
        case .skipNextBaseline: return "Skip to next baseline (compare)"
        }
    }

    enum Category: String, CaseIterable, Identifiable {
        case navigation = "Navigation"
        case rating = "Rating"
        case view = "View"
        case editing = "Editing"
        case file = "File"
        case compareMode = "Compare"

        var id: String { rawValue }
    }

    var category: Category {
        switch self {
        case .navigateBack, .navigateForward: return .navigation
        case .toggleFavorite, .toggleRejected, .setTriageMaybe: return .rating
        case .toggleGrid, .toggleCompare, .toggleFitZoom, .toggleFocusPeaking, .toggleCullModeDraft, .toggleInfo, .toggleHistogram, .toggleShortcutsHelp, .toggleSidebar: return .view
        case .deletePhoto, .undo, .selectAllGrid: return .editing
        case .openFolder: return .file
        case .pickCompare, .skipNextBaseline: return .compareMode
        }
    }
}

/// Persists the action→shortcut mapping and answers "which action does this
/// NSEvent invoke?" for the key handler.
@MainActor
final class KeybindingStore: ObservableObject {
    static let storageKey = "keybindings.v1"

    @Published private(set) var bindings: [ActionID: Shortcut] = [:]
    private var reverseMap: [Shortcut: ActionID] = [:]

    /// The defaults match the shortcuts hardcoded into ContentView prior to
    /// the configurable-shortcuts feature landing.
    static let defaults: [ActionID: Shortcut] = [
        .navigateBack: Shortcut(keyCode: 38),                           // J
        .navigateForward: Shortcut(keyCode: 37),                        // L
        .toggleFavorite: Shortcut(keyCode: 40),                         // K (Keep)
        .toggleRejected: Shortcut(keyCode: 31),                         // O (Out) — plain O; ⌘O stays Open Folder
        .setTriageMaybe: Shortcut(keyCode: 46),                         // M (Maybe)
        .toggleGrid: Shortcut(keyCode: 5),                              // G
        .toggleCompare: Shortcut(keyCode: 8),                           // C
        .toggleFitZoom: Shortcut(keyCode: 49),                          // Space
        .toggleFocusPeaking: Shortcut(keyCode: 3),                      // F
        .toggleCullModeDraft: Shortcut(keyCode: 2),                     // D
        .toggleInfo: Shortcut(keyCode: 34),                             // I
        .toggleHistogram: Shortcut(keyCode: 4),                         // H
        // Display-only default — actual help trigger is character-based ("?" / "/")
        // in ContentView+Input so JIS and US keyboards both work.
        .toggleShortcutsHelp: Shortcut(keyCode: 44, modifiers: .shift), // ?
        .toggleSidebar: Shortcut(keyCode: 11, modifiers: .command),     // ⌘B
        .deletePhoto: Shortcut(keyCode: 51),                            // ⌫
        .undo: Shortcut(keyCode: 6, modifiers: .command),               // ⌘Z
        .selectAllGrid: Shortcut(keyCode: 0, modifiers: .command),      // ⌘A
        .openFolder: Shortcut(keyCode: 31, modifiers: .command),        // ⌘O
        .pickCompare: Shortcut(keyCode: 36),                            // Return
        .skipNextBaseline: Shortcut(keyCode: 48),                       // Tab
    ]

    init() {
        load()
    }

    /// Returns the action bound to this event, if any.
    func action(for event: NSEvent) -> ActionID? {
        guard let sc = Shortcut(event: event) else { return nil }
        return reverseMap[sc]
    }

    /// Bind `shortcut` to `action`. Any previous action that owned this
    /// shortcut is cleared (overwrite policy).
    func bind(_ shortcut: Shortcut, to action: ActionID) {
        if let existing = reverseMap[shortcut], existing != action {
            bindings[existing] = nil
        }
        bindings[action] = shortcut
        rebuildReverseMap()
        save()
    }

    /// Remove the binding for `action`. The action becomes unbound until
    /// the user records a new shortcut or resets to defaults.
    func clear(_ action: ActionID) {
        bindings[action] = nil
        rebuildReverseMap()
        save()
    }

    func resetToDefaults() {
        bindings = Self.defaults
        rebuildReverseMap()
        save()
    }

    // MARK: - Persistence

    private func load() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([ActionID: Shortcut].self, from: data) {
            // Saved bindings win. Defaults only fill actions introduced after
            // the user's last save — and never with a shortcut the user has
            // assigned elsewhere, otherwise two actions would share one key
            // and fire nondeterministically.
            var merged = decoded
            let taken = Set(decoded.values)
            for (action, shortcut) in Self.defaults
            where merged[action] == nil && !taken.contains(shortcut) {
                merged[action] = shortcut
            }
            bindings = merged
            rebuildReverseMap()
            migrateTriageKeysPXtoKMOIfNeeded()
            return
        } else {
            bindings = Self.defaults
        }
        rebuildReverseMap()
    }

    /// One-shot: old defaults used P/X for Keep/Out; move to K/M/O for
    /// right-hand triage. Skips if the user rebound those actions.
    private func migrateTriageKeysPXtoKMOIfNeeded() {
        let flag = "keybindings.triageKMO.migrated"
        let ud = UserDefaults.standard
        guard !ud.bool(forKey: flag) else { return }

        let oldP = Shortcut(keyCode: 35) // P
        let oldX = Shortcut(keyCode: 7)  // X
        let newK = Shortcut(keyCode: 40) // K
        let newO = Shortcut(keyCode: 31) // O
        let taken = Set(bindings.values)
        var changed = false

        if bindings[.toggleFavorite] == oldP, !taken.contains(newK) {
            bindings[.toggleFavorite] = newK
            changed = true
        }
        if bindings[.toggleRejected] == oldX, !taken.contains(newO) {
            bindings[.toggleRejected] = newO
            changed = true
        }

        ud.set(true, forKey: flag)
        if changed {
            rebuildReverseMap()
            save()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(bindings) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    private func rebuildReverseMap() {
        var map: [Shortcut: ActionID] = [:]
        for (action, shortcut) in bindings {
            map[shortcut] = action
        }
        reverseMap = map
    }
}
