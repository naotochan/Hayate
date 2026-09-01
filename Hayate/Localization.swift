import Foundation
import SwiftUI
import AppKit

/// User-facing language preference. Persisted via UserDefaults.
///
/// Raw values are stable — do not renumber/rename existing cases; UserDefaults
/// already has them on disk for every installed user.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english
    case japanese
    case chineseSimplified
    case chineseTraditional
    case korean
    case spanish
    case french
    case german
    case portuguese
    case italian
    case russian
    case dutch
    case polish
    case turkish
    case indonesian
    case vietnamese

    var id: String { rawValue }

    /// Picker label. Every concrete language shows its own endonym; `system`
    /// tracks the currently resolved language so the menu itself stays legible.
    func pickerLabel(resolved: ResolvedLanguage) -> String {
        switch self {
        case .system: return resolved.t("System", ja: "システム")
        case .english: return "English"
        case .japanese: return "日本語"
        case .chineseSimplified: return "简体中文"
        case .chineseTraditional: return "繁體中文"
        case .korean: return "한국어"
        case .spanish: return "Español"
        case .french: return "Français"
        case .german: return "Deutsch"
        case .portuguese: return "Português"
        case .italian: return "Italiano"
        case .russian: return "Русский"
        case .dutch: return "Nederlands"
        case .polish: return "Polski"
        case .turkish: return "Türkçe"
        case .indonesian: return "Bahasa Indonesia"
        case .vietnamese: return "Tiếng Việt"
        }
    }

    func resolve(preferredLanguages: [String] = Locale.preferredLanguages) -> ResolvedLanguage {
        switch self {
        case .system: return Self.resolveSystem(preferredLanguages: preferredLanguages)
        case .english: return .english
        case .japanese: return .japanese
        case .chineseSimplified: return .chineseSimplified
        case .chineseTraditional: return .chineseTraditional
        case .korean: return .korean
        case .spanish: return .spanish
        case .french: return .french
        case .german: return .german
        case .portuguese: return .portuguese
        case .italian: return .italian
        case .russian: return .russian
        case .dutch: return .dutch
        case .polish: return .polish
        case .turkish: return .turkish
        case .indonesian: return .indonesian
        case .vietnamese: return .vietnamese
        }
    }

    /// Maps the first preferred BCP-47 language tag (e.g. "zh-Hant-TW") to a
    /// `ResolvedLanguage`. Only the primary subtag drives the switch, except
    /// for Chinese, where script/region distinguish Simplified vs Traditional.
    private static func resolveSystem(preferredLanguages: [String]) -> ResolvedLanguage {
        guard let tag = preferredLanguages.first, !tag.isEmpty else { return .english }
        let lower = tag.lowercased()
        let primary = lower.split(separator: "-").first.map(String.init) ?? lower

        switch primary {
        case "ja": return .japanese
        case "zh":
            let isTraditional = lower.contains("hant")
                || lower.hasSuffix("-tw") || lower.contains("-tw-")
                || lower.hasSuffix("-hk") || lower.contains("-hk-")
                || lower.hasSuffix("-mo") || lower.contains("-mo-")
            return isTraditional ? .chineseTraditional : .chineseSimplified
        case "ko": return .korean
        case "es": return .spanish
        case "fr": return .french
        case "de": return .german
        case "pt": return .portuguese
        case "it": return .italian
        case "ru": return .russian
        case "nl": return .dutch
        case "pl": return .polish
        case "tr": return .turkish
        case "id": return .indonesian
        case "vi": return .vietnamese
        default: return .english
        }
    }
}

/// Every language the app can render. `english` and `japanese` are the
/// bilingual source-of-truth pair every call site already provides; every
/// other case looks up the English key in `L10nCatalog`.
enum ResolvedLanguage: String, CaseIterable, Hashable {
    case english
    case japanese
    case chineseSimplified
    case chineseTraditional
    case korean
    case spanish
    case french
    case german
    case portuguese
    case italian
    case russian
    case dutch
    case polish
    case turkish
    case indonesian
    case vietnamese

    /// Pick the string for this language. English and Japanese come straight
    /// from the call site; every other language resolves through
    /// `L10nCatalog`, falling back to English when a key is missing.
    func t(_ english: String, ja japanese: String) -> String {
        switch self {
        case .english: return english
        case .japanese: return japanese
        default: return L10nCatalog.string(english, language: self) ?? english
        }
    }

    /// Format-string overload for call sites that used to interpolate
    /// straight into the English/Japanese literals. `arguments` apply to
    /// whichever template `t` resolves to — the English source, the JA
    /// literal, and every catalog entry for that key must all use the same
    /// `%d` / `%@` (or positional `%1$@`) order.
    func t(_ english: String, ja japanese: String, _ arguments: CVarArg...) -> String {
        String(format: t(english, ja: japanese), locale: formatLocale, arguments: arguments)
    }

    /// Locale used only for `%d` / number formatting inside `String(format:)`
    /// — not a general locale for the rest of the app.
    var formatLocale: Locale {
        switch self {
        case .english: return Locale(identifier: "en")
        case .japanese: return Locale(identifier: "ja")
        case .chineseSimplified: return Locale(identifier: "zh-Hans")
        case .chineseTraditional: return Locale(identifier: "zh-Hant")
        case .korean: return Locale(identifier: "ko")
        case .spanish: return Locale(identifier: "es")
        case .french: return Locale(identifier: "fr")
        case .german: return Locale(identifier: "de")
        case .portuguese: return Locale(identifier: "pt-BR")
        case .italian: return Locale(identifier: "it")
        case .russian: return Locale(identifier: "ru")
        case .dutch: return Locale(identifier: "nl")
        case .polish: return Locale(identifier: "pl")
        case .turkish: return Locale(identifier: "tr")
        case .indonesian: return Locale(identifier: "id")
        case .vietnamese: return Locale(identifier: "vi")
        }
    }

    var isJapanese: Bool { self == .japanese }

    /// Viewer: fit ↔ 1:1 (100%) zoom — one image pixel per physical screen pixel.
    var toggleFitOneToOneZoom: String {
        t("Toggle fit / 1:1 zoom", ja: "フィット / 1:1 ズーム")
    }

    var surveyModeLabel: String {
        t("SURVEY", ja: "サーベイ")
    }

    func surveyFooterHints(triage: Bool) -> String {
        if triage {
            return t(
                "↑↓←→ select  |  K keep  |  O out  |  6–9 labels  |  ⏎ decide  |  ⌘Z undo  |  Esc grid",
                ja: "↑↓←→ 選択  |  K Keep  |  O Out  |  6–9 ラベル  |  ⏎ 決定  |  ⌘Z 戻る  |  Esc グリッド"
            )
        }
        return t(
            "↑↓←→ select  |  K favorite  |  O reject  |  0–5 stars  |  6–9 labels  |  ⏎ decide  |  ⌘Z undo  |  Esc grid",
            ja: "↑↓←→ 選択  |  K お気に入り  |  O リジェクト  |  0–5 星  |  6–9 ラベル  |  ⏎ 決定  |  ⌘Z 戻る  |  Esc グリッド"
        )
    }

    func compareFooterHints(triage: Bool) -> String {
        if triage {
            return t(
                "←→ select  |  ⏎ keep  |  Tab skip  |  ⌘Z undo  |  Esc exit",
                ja: "←→ 選択  |  ⏎ Keep  |  Tab skip  |  ⌘Z 戻る  |  Esc 終了"
            )
        }
        return t(
            "←→ select  |  ⏎ pick  |  Tab skip  |  ⌘Z undo  |  Esc exit",
            ja: "←→ 選択  |  ⏎ Pick  |  Tab skip  |  ⌘Z 戻る  |  Esc 終了"
        )
    }

    /// Shortcut help row for color labels (6 Red … 9 Blue; Purple has no key).
    var colorLabelKeysRow: String {
        t("6 Red / 7 Yellow / 8 Green / 9 Blue", ja: "6 赤 / 7 黄 / 8 緑 / 9 青")
    }

    var needsReviewBadgeLabel: String {
        t("Needs review", ja: "要確認")
    }

    var needsReviewBadgeHelp: String {
        t(
            "Lower sharpness or face quality relative to this folder — for your eyes only.",
            ja: "このフォルダ内でシャープネスまたは顔の品質が低めです。最終判断はあなたが行います。"
        )
    }
}

/// In-app language switching. Injected as an `EnvironmentObject`.
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

    var formatLocale: Locale { resolved.formatLocale }

    /// Format-string overload — see `ResolvedLanguage.t(_:ja:_:)`.
    func t(_ english: String, ja japanese: String, _ arguments: CVarArg...) -> String {
        String(format: t(english, ja: japanese), locale: formatLocale, arguments: arguments)
    }

    var surveyModeLabel: String { resolved.surveyModeLabel }

    func surveyFooterHints(triage: Bool) -> String {
        resolved.surveyFooterHints(triage: triage)
    }

    func compareFooterHints(triage: Bool) -> String {
        resolved.compareFooterHints(triage: triage)
    }

    var colorLabelKeysRow: String { resolved.colorLabelKeysRow }

    var needsReviewBadgeLabel: String { resolved.needsReviewBadgeLabel }

    var needsReviewBadgeHelp: String { resolved.needsReviewBadgeHelp }
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
