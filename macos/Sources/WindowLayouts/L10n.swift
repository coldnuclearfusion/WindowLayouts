import Foundation
import Observation

/// UI strings. Reads strings.json from the bundle (a copy of the shared shared/strings.json).
/// Language setting: "system" (follow the system language) or a language code, stored in UserDefaults "language".
@Observable
final class L10n {
    static let shared = L10n()
    static let systemOption = "system"

    /// Supported language codes with their names in their own language (the languages entry of strings.json)
    private(set) var languages: [(code: String, name: String)] = []
    private var table: [String: [String: String]] = [:]

    /// The setting: "system" or a language code
    var setting: String {
        didSet {
            UserDefaults.standard.set(setting, forKey: "language")
            resolved = L10n.resolve(setting, available: languages.map(\.code))
        }
    }

    /// The language actually in use
    private(set) var resolved: String = "en"

    private init() {
        setting = UserDefaults.standard.string(forKey: "language") ?? L10n.systemOption
        load()
        resolved = L10n.resolve(setting, available: languages.map(\.code))
    }

    private func load() {
        guard let url = Bundle.main.url(forResource: "strings", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let langs = root["languages"] as? [String: String] {
            let order = ["ko", "en", "ja", "zh-Hans"]
            languages = langs.keys.sorted { (order.firstIndex(of: $0) ?? 99) < (order.firstIndex(of: $1) ?? 99) }
                .map { ($0, langs[$0] ?? $0) }
        }
        if let strings = root["strings"] as? [String: [String: String]] {
            table = strings
        }
    }

    /// Map the system language to one of the supported languages. Chinese maps to Simplified.
    static func resolve(_ setting: String, available: [String]) -> String {
        if setting != systemOption, available.contains(setting) { return setting }
        for lang in Locale.preferredLanguages {
            let lower = lang.lowercased()
            if lower.hasPrefix("ko"), available.contains("ko") { return "ko" }
            if lower.hasPrefix("ja"), available.contains("ja") { return "ja" }
            if lower.hasPrefix("zh"), available.contains("zh-Hans") { return "zh-Hans" }
            if lower.hasPrefix("en"), available.contains("en") { return "en" }
        }
        return available.contains("en") ? "en" : (available.first ?? "en")
    }

    /// The string for a key, with arguments substituted into {name} placeholders. Falls back to English, then to the key.
    func t(_ key: String, _ args: [String: String] = [:]) -> String {
        let entry = table[key]
        var text = entry?[resolved] ?? entry?["en"] ?? key
        for (k, v) in args {
            text = text.replacingOccurrences(of: "{\(k)}", with: v)
        }
        return text
    }
}

/// Short form
@inline(__always) func L(_ key: String, _ args: [String: String] = [:]) -> String {
    L10n.shared.t(key, args)
}
