import Foundation

@main
struct AppLanguageChecks {
    static func main() throws {
        let path = CommandLine.arguments.dropFirst().first
            ?? ".build/DerivedData/Build/Products/Debug/ScreenTake.app"
        let bundle = Bundle(url: URL(fileURLWithPath: path))!
        let languages = AppLanguage.allCases.filter { $0 != .system }
        precondition(languages.count == 9)
        let expected = ["en": "Settings", "ko": "설정", "ja": "設定", "zh-Hans": "设置",
                        "zh-Hant": "設定", "es": "Ajustes", "fr": "Réglages",
                        "de": "Einstellungen", "pt": "Configurações"]
        var referenceKeys: Set<String>?
        for language in languages {
            precondition(AppLanguage.text("Settings", language: language, bundle: bundle) == expected[language.rawValue])
            precondition(AppLanguage.text("recording-test.mov", language: language, bundle: bundle) == "recording-test.mov")
            let url = bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil,
                                 localization: language.rawValue)!
            let table = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as! [String: String]
            let keys = Set(table.keys)
            if let referenceKeys { precondition(keys == referenceKeys, "Missing translations: \(language)") }
            else { referenceKeys = keys }
            precondition(table.values.allSatisfy { !$0.isEmpty })
            for key in ["Language", "App language", "Follow System", "Smooth Transition",
                        "Hide Browser Toolbar", "Apply Changes", "Show Camera"] {
                precondition(table[key] != nil)
            }
        }
        for (preferences, expectedCode) in [(["ko-KR"], "ko"), (["ja-JP"], "ja"),
                                            (["zh-CN"], "zh-Hans"), (["zh-TW"], "zh-Hant"),
                                            (["pt-BR"], "pt"), (["fr-CA"], "fr"),
                                            (["xx", "de-DE"], "de"), (["xx"], "en")] {
            precondition(AppLanguage.system.resolvedCode(preferredLanguages: preferences) == expectedCode,
                         "Wrong system fallback for \(preferences)")
        }
        let suite = "ScreenTake-language-checks-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        precondition(AppLanguage.preference(in: defaults) == .system)
        defaults.set("ko", forKey: AppLanguage.defaultsKey)
        precondition(AppLanguage.preference(in: UserDefaults(suiteName: suite)!) == .korean)
        defaults.set("unknown", forKey: AppLanguage.defaultsKey)
        precondition(AppLanguage.preference(in: defaults) == .system)
        print("PASS: all nine locales, matching catalog keys, language resolution, persistence, and verbatim fallback")
    }
}
