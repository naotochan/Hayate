import XCTest
@testable import Hayate

@MainActor
final class LocalizationTests: XCTestCase {

    // MARK: - System language resolution

    func testSystemResolvesJapanese() {
        XCTAssertEqual(AppLanguage.system.resolve(preferredLanguages: ["ja-JP"]), .japanese)
    }

    func testSystemResolvesEnglish() {
        XCTAssertEqual(AppLanguage.system.resolve(preferredLanguages: ["en-US"]), .english)
    }

    func testSystemResolvesSimplifiedChinese() {
        XCTAssertEqual(AppLanguage.system.resolve(preferredLanguages: ["zh-Hans"]), .chineseSimplified)
        XCTAssertEqual(AppLanguage.system.resolve(preferredLanguages: ["zh-Hans-CN"]), .chineseSimplified)
    }

    func testSystemResolvesTraditionalChinese() {
        XCTAssertEqual(AppLanguage.system.resolve(preferredLanguages: ["zh-Hant"]), .chineseTraditional)
        XCTAssertEqual(AppLanguage.system.resolve(preferredLanguages: ["zh-TW"]), .chineseTraditional)
        XCTAssertEqual(AppLanguage.system.resolve(preferredLanguages: ["zh-HK"]), .chineseTraditional)
        XCTAssertEqual(AppLanguage.system.resolve(preferredLanguages: ["zh-MO"]), .chineseTraditional)
    }

    func testSystemResolvesRemainingLanguages() {
        let expectations: [(String, ResolvedLanguage)] = [
            ("ko-KR", .korean),
            ("es-ES", .spanish),
            ("fr-FR", .french),
            ("de-DE", .german),
            ("pt-BR", .portuguese),
            ("it-IT", .italian),
            ("ru-RU", .russian),
            ("nl-NL", .dutch),
            ("pl-PL", .polish),
            ("tr-TR", .turkish),
            ("id-ID", .indonesian),
            ("vi-VN", .vietnamese),
        ]
        for (tag, expected) in expectations {
            XCTAssertEqual(
                AppLanguage.system.resolve(preferredLanguages: [tag]),
                expected,
                "Expected \(tag) to resolve to \(expected)"
            )
        }
    }

    func testUnknownLocaleFallsBackToEnglish() {
        XCTAssertEqual(AppLanguage.system.resolve(preferredLanguages: ["xx-XX"]), .english)
        XCTAssertEqual(AppLanguage.system.resolve(preferredLanguages: []), .english)
    }

    func testConcreteLanguagesIgnorePreferredLanguages() {
        // A concrete AppLanguage selection should not consult the system locale at all.
        XCTAssertEqual(AppLanguage.japanese.resolve(preferredLanguages: ["en-US"]), .japanese)
        XCTAssertEqual(AppLanguage.korean.resolve(preferredLanguages: ["fr-FR"]), .korean)
    }

    // MARK: - t() bilingual source of truth

    func testEnglishReturnsEnglishLiteral() {
        XCTAssertEqual(ResolvedLanguage.english.t("Cancel", ja: "キャンセル"), "Cancel")
    }

    func testJapaneseReturnsJapaneseLiteral() {
        XCTAssertEqual(ResolvedLanguage.japanese.t("Cancel", ja: "キャンセル"), "キャンセル")
    }

    // MARK: - Catalog lookups

    func testCatalogReturnsTranslationForKnownKeyAcrossLanguages() {
        let cases: [(ResolvedLanguage, String)] = [
            (.chineseSimplified, "取消"),
            (.chineseTraditional, "取消"),
            (.korean, "취소"),
            (.spanish, "Cancelar"),
            (.french, "Annuler"),
            (.german, "Abbrechen"),
        ]
        for (language, expected) in cases {
            XCTAssertEqual(
                language.t("Cancel", ja: "キャンセル"),
                expected,
                "Expected \(language) catalog entry for \"Cancel\" to be \(expected)"
            )
        }
    }

    func testMissingCatalogKeyFallsBackToEnglish() {
        let bogusKey = "This string will never be in the catalog \(UUID().uuidString)"
        XCTAssertEqual(
            ResolvedLanguage.spanish.t(bogusKey, ja: "存在しない文字列"),
            bogusKey,
            "A missing catalog entry should fall back to the English source string"
        )
    }

    func testEveryConcreteNonBilingualLanguageHasNoMissingKeysForCoreStrings() {
        // Spot-check a handful of core keys across every catalog language —
        // a miss here means the key/format string drifted from the catalog.
        // Assert an actual catalog hit rather than "result != English key":
        // some loanwords (e.g. German "Export") are intentionally identical
        // to the English source, which would make that comparison a false miss.
        let keys = ["Cancel", "Export", "Skip", "Done", "Next", "Language"]
        for language in ResolvedLanguage.allCases where language != .english && language != .japanese {
            for key in keys {
                XCTAssertNotNil(
                    L10nCatalog.string(key, language: language),
                    "\(language) is missing a catalog entry for \"\(key)\""
                )
            }
        }
    }

    // MARK: - Format overload

    func testFormatOverloadInterpolatesJapanese() {
        XCTAssertEqual(
            ResolvedLanguage.japanese.t("Delete %d photos?", ja: "%d 枚の写真を削除しますか？", 3),
            "3 枚の写真を削除しますか？"
        )
    }

    func testFormatOverloadInterpolatesEnglish() {
        XCTAssertEqual(
            ResolvedLanguage.english.t("Delete %d photos?", ja: "%d 枚の写真を削除しますか？", 3),
            "Delete 3 photos?"
        )
    }

    func testFormatOverloadInterpolatesOtherLanguage() {
        XCTAssertEqual(
            ResolvedLanguage.spanish.t("Delete %d photos?", ja: "%d 枚の写真を削除しますか？", 3),
            "¿Eliminar 3 fotos?"
        )
    }

    func testLocalizationStoreFormatOverloadMatchesResolvedLanguage() {
        UserDefaults.standard.removeObject(forKey: LocalizationStore.storageKey)
        let store = LocalizationStore()
        store.language = .french
        XCTAssertEqual(
            store.t("Delete %d photos?", ja: "%d 枚の写真を削除しますか？", 5),
            "Supprimer 5 photos ?"
        )
        UserDefaults.standard.removeObject(forKey: LocalizationStore.storageKey)
    }

    // MARK: - AppLanguage raw values

    func testAppLanguageRawValuesRoundTrip() {
        for language in AppLanguage.allCases {
            let raw = language.rawValue
            XCTAssertEqual(AppLanguage(rawValue: raw), language, "Round-trip failed for \(raw)")
        }
    }

    func testAppLanguageRawValueCount() {
        // system + english + japanese + 14 new languages.
        XCTAssertEqual(AppLanguage.allCases.count, 17)
    }

    // MARK: - Picker labels

    func testPickerLabelsAreEndonyms() {
        let expectations: [(AppLanguage, String)] = [
            (.english, "English"),
            (.japanese, "日本語"),
            (.chineseSimplified, "简体中文"),
            (.chineseTraditional, "繁體中文"),
            (.korean, "한국어"),
            (.spanish, "Español"),
            (.french, "Français"),
            (.german, "Deutsch"),
            (.portuguese, "Português"),
            (.italian, "Italiano"),
            (.russian, "Русский"),
            (.dutch, "Nederlands"),
            (.polish, "Polski"),
            (.turkish, "Türkçe"),
            (.indonesian, "Bahasa Indonesia"),
            (.vietnamese, "Tiếng Việt"),
        ]
        for (language, expected) in expectations {
            XCTAssertEqual(language.pickerLabel(resolved: .english), expected)
        }
    }

    func testSystemPickerLabelFollowsResolvedLanguage() {
        XCTAssertEqual(AppLanguage.system.pickerLabel(resolved: .english), "System")
        XCTAssertEqual(AppLanguage.system.pickerLabel(resolved: .japanese), "システム")
    }
}
