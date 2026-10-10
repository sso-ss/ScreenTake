import Foundation
import SwiftUI

/// Interface preference only; project data and media are never translated.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case korean = "ko"
    case japanese = "ja"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case spanish = "es"
    case french = "fr"
    case german = "de"
    case portuguese = "pt"

    static let defaultsKey = "appLanguage"
    var id: String { rawValue }

    /// Keep language names readable even after selecting an unfamiliar language.
    var nativeName: String {
        switch self {
        case .system: return "Follow System"
        case .english: return "English"
        case .korean: return "한국어"
        case .japanese: return "日本語"
        case .simplifiedChinese: return "简体中文"
        case .traditionalChinese: return "繁體中文"
        case .spanish: return "Español"
        case .french: return "Français"
        case .german: return "Deutsch"
        case .portuguese: return "Português"
        }
    }

    static var current: Self {
        preference(in: .standard)
    }

    static func preference(in defaults: UserDefaults) -> Self {
        Self(rawValue: defaults.string(forKey: defaultsKey) ?? "") ?? .system
    }

    func resolvedCode(preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        guard self == .system else { return rawValue }
        return Bundle.preferredLocalizations(from: Self.allCases.filter { $0 != .system }.map(\.rawValue),
                                             forPreferences: preferredLanguages).first ?? "en"
    }

    var locale: Locale { Locale(identifier: resolvedCode()) }

    static func text(_ key: String, language: Self = current, bundle: Bundle = .main) -> String {
        let code = language.resolvedCode()
        guard let path = bundle.path(forResource: code, ofType: "lproj"),
              let localized = Bundle(path: path) else { return key }
        return localized.localizedString(forKey: key, value: key, table: "Localizable")
    }
}

extension View {
    func localizedAccessibilityLabel(_ text: String) -> some View {
        accessibilityLabel(Text(LocalizedStringKey(text)))
    }

    func localizedAccessibilityValue(_ text: String) -> some View {
        accessibilityValue(Text(LocalizedStringKey(text)))
    }
}
