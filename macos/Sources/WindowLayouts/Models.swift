import Foundation
import CoreGraphics

/// 배치에 포함된 앱이 실행 중이 아닐 때 어떻게 할지
enum LaunchPolicy: String, Codable, CaseIterable, Identifiable {
    case ask
    case launchMissing
    case runningOnly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ask: return "매번 물어보기"
        case .launchMissing: return "실행 안 된 앱은 실행하기"
        case .runningOnly: return "실행 중인 앱만 배치"
        }
    }
}

/// 같은 앱의 여러 창 중 어떤 창인지 찾는 방법
enum TitleMatch: String, Codable, CaseIterable, Identifiable {
    case auto    // 제목으로 먼저 찾고, 없으면 순서로
    case title   // 제목이 맞는 창만
    case order   // 제목 무시, 순서로만

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "자동"
        case .title: return "제목만"
        case .order: return "순서만"
        }
    }
}


/// 모니터 하나 (좌표는 주 화면 왼쪽 위가 (0,0)인 AX 좌표계)
struct DisplayInfo: Codable, Hashable, Identifiable {
    var id: String        // 재부팅 후에도 유지되는 디스플레이 UUID (없으면 이름+해상도)
    var name: String
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var isMain: Bool

    init(id: String, name: String, frame: CGRect, isMain: Bool) {
        self.id = id
        self.name = name
        self.x = frame.origin.x
        self.y = frame.origin.y
        self.width = frame.width
        self.height = frame.height
        self.isMain = isMain
    }

    var frame: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    enum CodingKeys: String, CodingKey { case id, name, x, y, width, height, isMain }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 0
        y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 0
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? 0
        height = try c.decodeIfPresent(Double.self, forKey: .height) ?? 0
        isMain = try c.decodeIfPresent(Bool.self, forKey: .isMain) ?? false
    }
}

/// 어떤 모니터들이 어떻게 연결되어 있는지
struct DisplayConfig: Codable, Hashable {
    var displays: [DisplayInfo]

    var ids: Set<String> { Set(displays.map(\.id)) }

    /// 연결된 모니터 집합을 나타내는 키 (배치 순서는 무시)
    var key: String { displays.map(\.id).sorted().joined(separator: "+") }

    /// "내장 디스플레이 + LG ULTRAFINE" 같은 표시용 이름
    var name: String {
        let ordered = displays.sorted { ($0.isMain ? 0 : 1, $0.x) < ($1.isMain ? 0 : 1, $1.x) }
        var counts: [String: Int] = [:]
        var order: [String] = []
        for d in ordered {
            if counts[d.name] == nil { order.append(d.name) }
            counts[d.name, default: 0] += 1
        }
        if order.isEmpty { return "모니터 없음" }
        return order.map { counts[$0]! > 1 ? "\($0) ×\(counts[$0]!)" : $0 }.joined(separator: " + ")
    }

    var main: DisplayInfo? { displays.first { $0.isMain } ?? displays.first }

    func display(withID id: String?) -> DisplayInfo? {
        guard let id else { return nil }
        return displays.first { $0.id == id }
    }

    func display(containing point: CGPoint) -> DisplayInfo? {
        displays.first { $0.frame.contains(point) }
    }

    /// 같은 모니터들이 연결되어 있는가 (위치 배열은 달라도 됨)
    func hasSameDisplays(as other: DisplayConfig) -> Bool { ids == other.ids }

    /// 모니터 집합과 배열까지 완전히 같은가
    func isIdentical(to other: DisplayConfig) -> Bool {
        displays.sorted { $0.id < $1.id } == other.displays.sorted { $0.id < $1.id }
    }
}

struct WindowEntry: Identifiable, Hashable, Codable {
    var id: UUID
    var bundleID: String
    var appName: String
    var title: String
    var titleMatch: TitleMatch
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var enabled: Bool
    /// 저장 당시 이 창이 있던 모니터 (DisplayInfo.id). 모니터 구성이 바뀌었을 때 위치를 맞추는 데 씀
    var displayID: String?

    init(id: UUID = UUID(),
         bundleID: String,
         appName: String,
         title: String,
         titleMatch: TitleMatch = .auto,
         frame: CGRect,
         enabled: Bool = true,
         displayID: String? = nil) {
        self.id = id
        self.bundleID = bundleID
        self.appName = appName
        self.title = title
        self.titleMatch = titleMatch
        self.x = frame.origin.x.rounded()
        self.y = frame.origin.y.rounded()
        self.width = frame.size.width.rounded()
        self.height = frame.size.height.rounded()
        self.enabled = enabled
        self.displayID = displayID
    }

    var frame: CGRect {
        get { CGRect(x: x, y: y, width: width, height: height) }
        set {
            x = newValue.origin.x.rounded()
            y = newValue.origin.y.rounded()
            width = newValue.size.width.rounded()
            height = newValue.size.height.rounded()
        }
    }

    var displayName: String {
        title.isEmpty ? appName : "\(appName) – \(title)"
    }

    enum CodingKeys: String, CodingKey {
        case id, bundleID, appName, title, titleMatch, x, y, width, height, enabled, displayID
    }

    // 손으로 편집한 JSON에서 일부 키가 빠져 있어도 읽을 수 있도록 관대하게 디코딩
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        bundleID = try c.decode(String.self, forKey: .bundleID)
        appName = try c.decodeIfPresent(String.self, forKey: .appName) ?? bundleID
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        titleMatch = try c.decodeIfPresent(TitleMatch.self, forKey: .titleMatch) ?? .auto
        x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 0
        y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 0
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? 800
        height = try c.decodeIfPresent(Double.self, forKey: .height) ?? 600
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        displayID = try c.decodeIfPresent(String.self, forKey: .displayID)
    }
}

struct WindowLayout: Identifiable, Hashable, Codable {
    var id: UUID
    var name: String
    var launchPolicy: LaunchPolicy
    var windows: [WindowEntry]
    /// 저장 당시 모니터 구성. nil이면 모든 구성에서 보이는 "구성 무관" 배치
    var displayConfig: DisplayConfig?
    /// 적용할 때 이 배치의 창들을 다른 창들 위로 올릴지 (windows 배열의 앞 항목이 더 위)
    var raiseWindows: Bool

    init(id: UUID = UUID(), name: String, launchPolicy: LaunchPolicy = .ask,
         windows: [WindowEntry] = [], displayConfig: DisplayConfig? = nil, raiseWindows: Bool = true) {
        self.id = id
        self.name = name
        self.launchPolicy = launchPolicy
        self.windows = windows
        self.displayConfig = displayConfig
        self.raiseWindows = raiseWindows
    }

    /// 등장 순서를 유지한 앱 bundle ID 목록 (활성화된 창만)
    var enabledBundleIDs: [String] {
        var seen = Set<String>()
        return windows.filter(\.enabled).compactMap { seen.insert($0.bundleID).inserted ? $0.bundleID : nil }
    }

    func appName(for bundleID: String) -> String {
        windows.first { $0.bundleID == bundleID }?.appName ?? bundleID
    }

    enum CodingKeys: String, CodingKey {
        case id, name, launchPolicy, windows, displayConfig, raiseWindows
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "이름 없음"
        launchPolicy = try c.decodeIfPresent(LaunchPolicy.self, forKey: .launchPolicy) ?? .ask
        windows = try c.decodeIfPresent([WindowEntry].self, forKey: .windows) ?? []
        displayConfig = try c.decodeIfPresent(DisplayConfig.self, forKey: .displayConfig)
        raiseWindows = try c.decodeIfPresent(Bool.self, forKey: .raiseWindows) ?? true
    }
}

struct LayoutFile: Codable {
    var version: Int = 1
    var layouts: [WindowLayout]

    enum CodingKeys: String, CodingKey { case version, layouts }

    init(layouts: [WindowLayout]) {
        self.layouts = layouts
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        layouts = try c.decodeIfPresent([WindowLayout].self, forKey: .layouts) ?? []
    }
}

extension CGRect {
    var shortDescription: String {
        "\(Int(width))×\(Int(height)) @ (\(Int(origin.x)), \(Int(origin.y)))"
    }
}
