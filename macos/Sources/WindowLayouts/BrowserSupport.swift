import AppKit
import ApplicationServices

/// Finding a browser window by page address or tab title, or opening a page in a new window.
/// - Safari and Chromium browsers (Chrome/Edge/Brave/Vivaldi): AppleScript can enumerate every tab of every window,
///   so tabs hidden behind other tabs are found and activated (needs the Automation permission once).
/// - Firefox and other browsers without AppleScript: only the active tab's address of each window is visible through Accessibility.
enum BrowserSupport {
    enum Kind { case safari, chromiumScriptable, chromiumBinary, firefox }

    private static let safari: Set<String> = ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]
    private static let chromiumScriptable: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary",
        "com.microsoft.edgemac", "com.brave.Browser", "com.vivaldi.Vivaldi",
    ]
    private static let chromiumBinary: Set<String> = ["com.operasoftware.Opera", "company.thebrowser.Browser"]
    private static let firefox: Set<String> = [
        "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly", "app.zen-browser.zen",
    ]

    static func kind(of bundleID: String) -> Kind? {
        if safari.contains(bundleID) { return .safari }
        if chromiumScriptable.contains(bundleID) { return .chromiumScriptable }
        if chromiumBinary.contains(bundleID) { return .chromiumBinary }
        if firefox.contains(bundleID) { return .firefox }
        return nil
    }

    static func isBrowser(_ bundleID: String) -> Bool { kind(of: bundleID) != nil }

    /// Whether every tab of every window can be listed (AppleScript)
    static func canListTabs(_ bundleID: String) -> Bool {
        switch kind(of: bundleID) {
        case .safari, .chromiumScriptable: return true
        default: return false
        }
    }

    // MARK: - Address comparison

    /// Normalization for comparison: lowercase scheme/host, strip www., trailing / and the #fragment
    static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hash = s.firstIndex(of: "#") { s = String(s[..<hash]) }
        guard let comps = URLComponents(string: s), let host = comps.host else {
            return s.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        var h = host.lowercased()
        if h.hasPrefix("www.") { h.removeFirst(4) }
        var path = comps.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        let query = comps.percentEncodedQuery.map { "?" + $0 } ?? ""
        return h + path + query
    }

    /// The saved address matches an open tab when it is a prefix of the tab's address.
    /// Example: saved "youtube.com" ↔ tab "https://www.youtube.com/watch?v=…" → match
    static func matches(saved: String, candidate: String) -> Bool {
        let a = normalize(saved), b = normalize(candidate)
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        guard b.hasPrefix(a) else { return false }
        let next = b[b.index(b.startIndex, offsetBy: a.count)]
        return next == "/" || next == "?" || next == "&"
    }

    // MARK: - Title comparison

    /// How well a saved window title describes a tab, ignoring words that belong to the browser itself
    /// (for example "Google Chrome" in "YouTube - Google Chrome"). 1 = same words, 0.9 = one contains the other, else Jaccard overlap.
    static func titleScore(saved: String, tabTitle: String, ignoring boilerplate: Set<String>) -> Double {
        let a = WindowMatcher.tokens(saved).subtracting(boilerplate)
        let b = WindowMatcher.tokens(tabTitle).subtracting(boilerplate)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b { return 1 }
        if a.isSubset(of: b) || b.isSubset(of: a) { return 0.9 }
        return Double(a.intersection(b).count) / Double(a.union(b).count)
    }

    /// Minimum titleScore for switching to a tab (stricter than window matching because switching tabs is visible)
    static let titleThreshold = 0.5

    // MARK: - Listing tabs with AppleScript

    struct Tab {
        let index: Int          // 1-based, as AppleScript counts
        let url: String
        let title: String
        var isActive: Bool
    }

    struct Window {
        let id: Int
        let name: String        // window title as the browser reports it
        let bounds: CGRect?     // screen frame, when the browser reports one
        var tabs: [Tab]

        var activeTab: Tab? { tabs.first { $0.isActive } }
    }

    enum ScriptError: Error {
        case notPermitted
        case failed(String)

        var message: String {
            switch self {
            case .notPermitted: return "not permitted (-1743)"
            case .failed(let s): return s
            }
        }
    }

    /// Every window with every tab. Lines: "W<tab>id<tab>l,t,r,b<tab>name" then "T<tab>index<tab>active<tab>url<tab>title" per tab.
    static func listWindows(app: NSRunningApplication) throws -> [Window] {
        guard let bundleID = app.bundleIdentifier, let kind = kind(of: bundleID) else { return [] }
        let activeIndex: String
        let tabTitle: String
        switch kind {
        case .safari:
            activeIndex = "index of current tab of w"
            tabTitle = "name of t"
        case .chromiumScriptable:
            activeIndex = "active tab index of w"
            tabTitle = "title of t"
        default:
            return []
        }
        let source = """
        tell application id "\(bundleID)"
            set out to ""
            repeat with w in windows
                set a to 0
                try
                    set a to \(activeIndex)
                end try
                set bstr to ""
                try
                    set b to bounds of w
                    set bstr to (item 1 of b as text) & "," & (item 2 of b as text) & "," & (item 3 of b as text) & "," & (item 4 of b as text)
                end try
                set wname to ""
                try
                    set wname to name of w as text
                end try
                set out to out & "W" & tab & (id of w as text) & tab & bstr & tab & wname & linefeed
                set i to 0
                repeat with t in tabs of w
                    set i to i + 1
                    set turl to ""
                    try
                        set turl to URL of t as text
                    end try
                    set ttitle to ""
                    try
                        set ttitle to \(tabTitle) as text
                    end try
                    set out to out & "T" & tab & i & tab & (i = a) & tab & turl & tab & ttitle & linefeed
                end repeat
            end repeat
            return out
        end tell
        """
        return parse(try run(source))
    }

    static func parse(_ text: String) -> [Window] {
        var windows: [Window] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("W\t") {
                let parts = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
                guard parts.count >= 3, let id = Int(parts[1]) else { continue }
                let numbers = parts[2].split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                let bounds = numbers.count == 4
                    ? CGRect(x: numbers[0], y: numbers[1], width: numbers[2] - numbers[0], height: numbers[3] - numbers[1])
                    : nil
                let name = parts.count > 3 ? String(parts[3]) : ""
                windows.append(Window(id: id, name: name, bounds: bounds, tabs: []))
            } else if line.hasPrefix("T\t"), !windows.isEmpty {
                let parts = line.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false)
                guard parts.count >= 4, let index = Int(parts[1]) else { continue }
                let title = parts.count > 4 ? String(parts[4]) : ""
                windows[windows.count - 1].tabs.append(
                    Tab(index: index, url: String(parts[3]), title: title, isActive: parts[2] == "true"))
            }
        }
        return windows
    }

    /// Make the tab the active one of its window
    static func activate(windowID: Int, tabIndex: Int, app: NSRunningApplication) throws {
        guard let bundleID = app.bundleIdentifier, let kind = kind(of: bundleID) else { return }
        let source: String
        switch kind {
        case .safari:
            source = """
            tell application id "\(bundleID)"
                set w to window id \(windowID)
                set current tab of w to tab \(tabIndex) of w
            end tell
            """
        case .chromiumScriptable:
            source = """
            tell application id "\(bundleID)"
                set w to window id \(windowID)
                set active tab index of w to \(tabIndex)
            end tell
            """
        default:
            return
        }
        _ = try run(source)
    }

    /// The Accessibility window that corresponds to a scripted window: same title first, then same screen frame,
    /// then a title that starts with the active tab's title.
    static func axWindow(for window: Window, among candidates: [AXWindow]) -> AXWindow? {
        let byName = window.name.isEmpty ? [] : candidates.filter { $0.title == window.name }
        if byName.count == 1 { return byName[0] }
        if byName.count > 1, let b = window.bounds,
           let w = byName.first(where: { $0.frame.approximatelyEquals(b, tolerance: 4) }) { return w }
        if let b = window.bounds, let w = candidates.first(where: { $0.frame.approximatelyEquals(b, tolerance: 4) }) { return w }
        if let first = byName.first { return first }
        if let active = window.activeTab, !active.title.isEmpty,
           let w = candidates.first(where: { $0.title.hasPrefix(active.title) }) { return w }
        return nil
    }

    private static func run(_ source: String) throws -> String {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { throw ScriptError.failed("could not create script") }
        let result = script.executeAndReturnError(&error)
        if let error {
            let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            if code == -1743 { throw ScriptError.notPermitted }   // errAEEventNotPermitted
            throw ScriptError.failed((error[NSAppleScript.errorMessage] as? String) ?? "code \(code)")
        }
        return result.stringValue ?? ""
    }

    // MARK: - Opening a new window

    /// Open the URL in a new window. Returns only whether the request was sent; the caller waits for the window.
    static func openInNewWindow(_ url: String, app: NSRunningApplication) -> Bool {
        guard let bundleID = app.bundleIdentifier, let kind = kind(of: bundleID),
              let appURL = app.bundleURL else { return false }
        switch kind {
        case .safari:
            let escaped = url.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let source = """
            tell application id "\(bundleID)"
                make new document with properties {URL:"\(escaped)"}
            end tell
            """
            return (try? run(source)) != nil
        case .chromiumScriptable, .chromiumBinary, .firefox:
            // Running the executable again with --new-window makes the running instance open a new window
            guard let exec = Bundle(url: appURL)?.executableURL else { return false }
            let process = Process()
            process.executableURL = exec
            process.arguments = ["--new-window", url]
            process.standardOutput = nil
            process.standardError = nil
            do {
                try process.run()
                return true
            } catch {
                return false
            }
        }
    }
}
