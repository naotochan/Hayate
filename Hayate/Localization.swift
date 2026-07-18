import Foundation
import SwiftUI
import AppKit

/// User-facing language preference. Persisted via UserDefaults.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english
    case japanese

    var id: String { rawValue }

    /// Picker labels stay bilingual so either language can find the control.
    var pickerLabel: String {
        switch self {
        case .system: return "System / システム"
        case .english: return "English"
        case .japanese: return "日本語"
        }
    }

    func resolve(preferredLanguages: [String] = Locale.preferredLanguages) -> ResolvedLanguage {
        switch self {
        case .english: return .english
        case .japanese: return .japanese
        case .system:
            let pref = preferredLanguages.first ?? "en"
            return pref.hasPrefix("ja") ? .japanese : .english
        }
    }
}

enum ResolvedLanguage: Equatable {
    case english
    case japanese

    func t(_ english: String, ja japanese: String) -> String {
        self == .japanese ? japanese : english
    }
}

/// In-app JP/EN switching. Injected as an `EnvironmentObject`.
@MainActor
final class LocalizationStore: ObservableObject {
    static let storageKey = "appLanguage"

    @Published var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: Self.storageKey)
        }
    }

    init() {
        let raw = UserDefaults.standard.string(forKey: Self.storageKey) ?? AppLanguage.system.rawValue
        self.language = AppLanguage(rawValue: raw) ?? .system
    }

    var resolved: ResolvedLanguage { language.resolve() }

    var isJapanese: Bool { resolved == .japanese }

    /// Pick the string for the current resolved language.
    func t(_ english: String, ja japanese: String) -> String {
        resolved.t(english, ja: japanese)
    }
}

// MARK: - Appearance

/// Light / Dark / System preference. Persisted via `@AppStorage("appAppearance")`.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    /// `nil` follows the macOS appearance.
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    func label(_ lang: ResolvedLanguage) -> String {
        switch self {
        case .system: return lang.t("System", ja: "システム")
        case .light: return lang.t("Light", ja: "ライト")
        case .dark: return lang.t("Dark", ja: "ダーク")
        }
    }

    /// Sync AppKit with the preference. `preferredColorScheme` alone can leave
    /// window appearance stuck after Light → System, so custom `HayateTheme`
    /// colors and Settings Form chrome stay half light / half dark.
    ///
    /// Must run after `NSApplication` exists (e.g. view `onAppear`) — never
    /// from `App.init()`, where `NSApp` is still nil and force-unwraps crash.
    @MainActor
    func applyToApp() {
        let app = NSApplication.shared
        switch self {
        case .system:
            app.appearance = nil
        case .light:
            app.appearance = NSAppearance(named: .aqua)
        case .dark:
            app.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
