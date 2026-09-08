import Foundation
import Observation

/// 다국어 문자열. 번들의 strings.json(공통 파일 shared/strings.json 복사본)에서 읽는다.
/// 언어 설정: "system"(시스템 언어 따라가기) 또는 언어 코드. UserDefaults "language"에 저장.
@Observable
final class L10n {
    static let shared = L10n()
    static let systemOption = "system"

    /// 지원 언어 코드와 각 언어로 쓴 이름 (strings.json의 languages)
    private(set) var languages: [(code: String, name: String)] = []
    private var table: [String: [String: String]] = [:]

    /// 설정값: "system" 또는 언어 코드
    var setting: String {
        didSet {
            UserDefaults.standard.set(setting, forKey: "language")
            resolved = L10n.resolve(setting, available: languages.map(\.code))
        }
    }

    /// 실제로 쓰는 언어 코드
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

    /// 시스템 언어를 지원 언어 중 하나로 맞춘다. 중국어는 간체로 통일.
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

    /// 키에 해당하는 문자열. {name} 자리에 인자를 넣는다. 없으면 영어, 그것도 없으면 키를 돌려준다.
    func t(_ key: String, _ args: [String: String] = [:]) -> String {
        let entry = table[key]
        var text = entry?[resolved] ?? entry?["en"] ?? key
        for (k, v) in args {
            text = text.replacingOccurrences(of: "{\(k)}", with: v)
        }
        return text
    }
}

/// 짧은 호출용
@inline(__always) func L(_ key: String, _ args: [String: String] = [:]) -> String {
    L10n.shared.t(key, args)
}
