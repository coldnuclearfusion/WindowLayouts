import Foundation
import CoreGraphics

/// What to do when an app in the layout isn't running
enum LaunchPolicy: String, Codable, CaseIterable, Identifiable {
    case ask
    case launchMissing
    case runningOnly

    var id: String { rawValue }

    var label: String {
        L("policy.\(rawValue)")
    }
}

/// How to find which of an app's several windows an entry refers to
enum TitleMatch: String, Codable, CaseIterable, Identifiable {
    case auto    // by title first, then by order
    case title   // only a window whose title matches
    case order   // ignore the title, by order only

    var id: String { rawValue }

    var label: String {
        L("match.\(rawValue)")
    }
}


/// One monitor (AX coordinates: the main display's top-left is (0,0))
struct DisplayInfo: Codable, Hashable, Identifiable {
    var id: String        // display UUID that survives reboots (otherwise name + resolution)
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

/// Which monitors are connected and how they are arranged
struct DisplayConfig: Codable, Hashable {
    var displays: [DisplayInfo]

    var ids: Set<String> { Set(displays.map(\.id)) }

    /// Key for the set of connected monitors (arrangement ignored)
    var key: String { displays.map(\.id).sorted().joined(separator: "+") }

    /// Display name such as "Built-in Display + LG ULTRAFINE"
    var name: String {
        let ordered = displays.sorted { ($0.isMain ? 0 : 1, $0.x) < ($1.isMain ? 0 : 1, $1.x) }
        var counts: [String: Int] = [:]
        var order: [String] = []
        for d in ordered {
            if counts[d.name] == nil { order.append(d.name) }
            counts[d.name, default: 0] += 1
        }
        if order.isEmpty { return L("display.none") }
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

    /// Same set of monitors (the arrangement may differ)
    func hasSameDisplays(as other: DisplayConfig) -> Bool { ids == other.ids }

    /// Same monitors and the same arrangement
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
    /// The monitor this window was on when saved (DisplayInfo.id); used to fit positions when the setup changed
    var displayID: String?
    /// For browser windows: the page to show here. Takes precedence over the title when finding the window; opens a new window if none has it
    var url: String?

    init(id: UUID = UUID(),
         bundleID: String,
         appName: String,
         title: String,
         titleMatch: TitleMatch = .auto,
         frame: CGRect,
         enabled: Bool = true,
         displayID: String? = nil,
         url: String? = nil) {
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
        self.url = url
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
        let detail = title.isEmpty ? (url ?? "") : title
        return detail.isEmpty ? appName : "\(appName) – \(detail)"
    }

    var hasURL: Bool {
        !(url ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }

    enum CodingKeys: String, CodingKey {
        case id, bundleID, appName, title, titleMatch, x, y, width, height, enabled, displayID, url
    }

    // Lenient decoding so hand-edited JSON with missing keys still loads
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
        url = try c.decodeIfPresent(String.self, forKey: .url)
    }
}

struct WindowLayout: Identifiable, Hashable, Codable {
    var id: UUID
    var name: String
    var launchPolicy: LaunchPolicy
    var windows: [WindowEntry]
    /// Monitor setup at save time. nil means an "any setup" layout that shows under every setup
    var displayConfig: DisplayConfig?
    /// Whether to raise the layout's windows above the others when applying (earlier entries end up higher)
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

    /// App bundle IDs in order of appearance (enabled windows only)
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
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? L("layout.untitled")
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
