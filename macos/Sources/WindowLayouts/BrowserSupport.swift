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

    // MARK: - Profiles (Chrome)

    private static let chromeFamily: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary", "com.google.Chrome.dev",
    ]
    /// Chrome's own name in window titles. With several profiles Chrome ends every window title with
    /// " - <name> - <profile>" (for example "Docs - Chrome - Work"); with a single profile only with " - <name>".
    private static let chromeTitleNames = [
        "Google Chrome Canary", "Google Chrome Beta", "Google Chrome Dev", "Google Chrome",
        "Chrome Canary", "Chrome Beta", "Chrome Dev", "Chrome",
    ]

    static func supportsProfiles(_ bundleID: String) -> Bool { chromeFamily.contains(bundleID) }

    /// The profile a browser window belongs to, read from the end of its title; nil when the title names none
    static func profile(fromTitle title: String, bundleID: String) -> String? {
        guard supportsProfiles(bundleID) else { return nil }
        if chromeTitleNames.contains(where: { title.hasSuffix(" - " + $0) }) { return nil }
        var last: Range<String.Index>?
        for name in chromeTitleNames {
            if let r = title.range(of: " - \(name) - ", options: .backwards), last.map({ r.lowerBound > $0.lowerBound }) ?? true {
                last = r
            }
        }
        guard let last else { return nil }
        let profile = title[last.upperBound...].trimmingCharacters(in: .whitespaces)
        return profile.isEmpty ? nil : profile
    }

    /// The menus of an app's menu bar: each menu's title and its items (title and element). Only reads the menus.
    static func menus(of app: NSRunningApplication) -> [(title: String, items: [(title: String, element: AXUIElement)])] {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 1.0)
        guard let barValue = AX.copyAttribute(appElement, kAXMenuBarAttribute),
              CFGetTypeID(barValue) == AXUIElementGetTypeID() else { return [] }
        let bar = barValue as! AXUIElement
        var result: [(title: String, items: [(title: String, element: AXUIElement)])] = []
        for barItem in (AX.copyAttribute(bar, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
            for menu in (AX.copyAttribute(barItem, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
                let items = ((AX.copyAttribute(menu, kAXChildrenAttribute) as? [AXUIElement]) ?? []).map {
                    (title: AX.string($0, kAXTitleAttribute) ?? "", element: $0)
                }
                result.append((AX.string(barItem, kAXTitleAttribute) ?? "", items))
            }
        }
        return result
    }

    /// The menu that lists the browser's profiles (Chrome's "Profiles" menu): the one with the most items whose title
    /// passes `isProfile`. Only reads the menu; nothing is opened or chosen.
    static func profileMenu(of app: NSRunningApplication, matching isProfile: (String) -> Bool)
        -> (title: String, items: [(title: String, element: AXUIElement)])? {
        var best: (title: String, items: [(title: String, element: AXUIElement)], hits: Int)?
        for menu in menus(of: app) {
            let hits = menu.items.filter { isProfile($0.title) }.count
            if hits > 0, hits > (best?.hits ?? 0) { best = (menu.title, menu.items, hits) }
        }
        return best.map { ($0.title, $0.items) }
    }

    static func profileMenu(of app: NSRunningApplication, listing names: Set<String>)
        -> (title: String, items: [(title: String, element: AXUIElement)])? {
        names.isEmpty ? nil : profileMenu(of: app, matching: { names.contains($0) })
    }

    /// The Profiles menu item for a profile name as window titles show it. The menu may add an account domain,
    /// as in "Work (example.com)", so a unique "name (" prefix is accepted too.
    static func profileMenuItem(of app: NSRunningApplication, named name: String) -> AXUIElement? {
        func fits(_ title: String) -> Bool { title == name || title.hasPrefix(name + " (") }
        guard let menu = profileMenu(of: app, matching: fits) else { return nil }
        if let exact = menu.items.first(where: { $0.title == name }) { return exact.element }
        let prefixed = menu.items.filter { $0.title.hasPrefix(name + " (") }
        return prefixed.count == 1 ? prefixed[0].element : nil
    }

    /// File › New Window, found by its shortcut (⌘N, no other modifier) so that the menu language does not matter
    static func newWindowMenuItem(of app: NSRunningApplication) -> AXUIElement? {
        for menu in menus(of: app) {
            for item in menu.items {
                guard AX.string(item.element, kAXMenuItemCmdCharAttribute)?.uppercased() == "N" else { continue }
                let modifiers = (AX.copyAttribute(item.element, kAXMenuItemCmdModifiersAttribute) as? NSNumber)?.intValue
                if modifiers == 0 { return item.element }
            }
        }
        return nil
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
        // The separators are built from character ids before the tell block. Inside it the word "tab" belongs to the
        // browser's own vocabulary (its tab class): `"W" & tab` yields "Wtab" there, which made every line unparseable
        // and the tab list silently empty.
        let source = """
        set fieldSep to (character id 9)
        set lineSep to (character id 10)
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
                set out to out & "W" & fieldSep & (id of w as text) & fieldSep & bstr & fieldSep & wname & lineSep
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
                    set out to out & "T" & fieldSep & i & fieldSep & (i = a) & fieldSep & turl & fieldSep & ttitle & lineSep
                end repeat
            end repeat
            return out
        end tell
        """
        let text = try run(source)
        let windows = parse(text)
        // Output that does not parse must not pass for "no windows open"
        if windows.isEmpty, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ScriptError.failed("tab list could not be parsed: \(text.prefix(80))")
        }
        return windows
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

    /// Pair each scripted window with its Accessibility window, one to one (scripted index → window).
    /// The browser's window name is no use for this: Chrome shortens long titles with "…", and the Accessibility
    /// title carries suffixes such as " - Chrome - <profile>". So the screen frame decides, and the active tab's
    /// title tells apart windows that share a frame (or report none). Done once, before any tab is switched.
    static func pair(_ scripted: [Window], with axWindows: [AXWindow]) -> [Int: AXWindow] {
        var candidates: [(score: Int, si: Int, ai: Int)] = []
        for (si, w) in scripted.enumerated() {
            for (ai, ax) in axWindows.enumerated() {
                var titleFits = !w.name.isEmpty && ax.title == w.name
                if !titleFits, let active = w.activeTab, !active.title.isEmpty { titleFits = ax.title.hasPrefix(active.title) }
                if let b = w.bounds {
                    // A window with a known frame only pairs with a window at that frame; a title alone could be a coincidence
                    guard ax.frame.approximatelyEquals(b, tolerance: 4) else { continue }
                    candidates.append((titleFits ? 3 : 2, si, ai))
                } else if titleFits {
                    candidates.append((1, si, ai))
                }
            }
        }
        // Best evidence first; equal evidence keeps both lists' order (front to back)
        candidates.sort { ($1.score, $0.si, $0.ai) < ($0.score, $1.si, $1.ai) }
        var result: [Int: AXWindow] = [:]
        var usedAX = Set<Int>()
        for c in candidates where result[c.si] == nil && !usedAX.contains(c.ai) {
            result[c.si] = axWindows[c.ai]
            usedAX.insert(c.ai)
        }
        return result
    }

    /// Which tab to use for a row of the layout: the best-scoring one (score 0 = no match) in a window that is still free.
    /// `eligible(i)`: whether scripted window i may be used for this row at all (for example its profile).
    /// `availability(i)` for scripted window i: true = free, false = another row already uses it, nil = unknown
    /// (no Accessibility window paired). Tabs in used windows are never chosen: pulling one to the front would take
    /// the window away from the row that has it. Ties prefer a window known to be free, then the tab that is already
    /// active (no switching needed), then the earlier window and tab.
    static func chooseTab(in windows: [Window], eligible: (Int) -> Bool = { _ in true }, availability: (Int) -> Bool?,
                          score: (Tab) -> Double) -> (choice: (window: Int, tab: Int)?, matchInUsedWindow: Bool) {
        var best: (rank: (Double, Int, Int), window: Int, tab: Int)?
        var matchInUsedWindow = false
        for (wi, w) in windows.enumerated() where eligible(wi) {
            let available = availability(wi)
            for (ti, t) in w.tabs.enumerated() {
                let s = score(t)
                guard s > 0 else { continue }
                if available == false {
                    matchInUsedWindow = true
                    continue
                }
                let rank = (s, available == true ? 1 : 0, t.isActive ? 1 : 0)
                if best == nil || rank > best!.rank { best = (rank, wi, ti) }
            }
        }
        return (best.map { ($0.window, $0.tab) }, matchInUsedWindow)
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

    // MARK: - Checking tab access

    /// Read-only check written to the apply log, triggered with `open "windowlayouts://check-tabs"`: for every running
    /// browser whose tabs can be listed, how many windows and tabs AppleScript reports and which Accessibility window
    /// each scripted window corresponds to. Nothing is moved, activated or opened.
    static func logTabCheck() {
        ApplyLog.write(L("log.check_start"))
        let label = L("log.check_label")
        let browsers = NSWorkspace.shared.runningApplications.filter { app in
            !app.isTerminated && app.bundleIdentifier.map(canListTabs) == true
        }
        if browsers.isEmpty {
            ApplyLog.write(L("log.check_none"))
            return
        }
        for app in browsers {
            let name = app.localizedName ?? app.bundleIdentifier ?? ""
            do {
                let listed = try listWindows(app: app)
                ApplyLog.write(L("log.tabs_listed", ["window": label, "app": name, "windows": String(listed.count),
                                                     "tabs": String(listed.reduce(0) { $0 + $1.tabs.count })]))
                let axWindows = AX.windows(for: app)
                let paired = pair(listed, with: axWindows)
                for (i, w) in listed.enumerated() {
                    var args = ["app": name, "name": w.name, "bounds": w.bounds?.shortDescription ?? "–",
                                "tabs": String(w.tabs.count), "index": w.activeTab.map { String($0.index) } ?? "–",
                                "urls": String(w.tabs.filter { !$0.url.isEmpty }.count),
                                "titles": String(w.tabs.filter { !$0.title.isEmpty }.count)]
                    if let match = paired[i] {
                        args["title"] = match.title
                        args["frame"] = match.frame.shortDescription
                        ApplyLog.write(L("log.check_window", args))
                    } else {
                        args["count"] = String(axWindows.count)
                        ApplyLog.write(L("log.check_window_unmapped", args))
                    }
                }
                if let bundleID = app.bundleIdentifier, supportsProfiles(bundleID) {
                    var profiles: [String] = []
                    for w in axWindows {
                        if let p = profile(fromTitle: w.title, bundleID: bundleID), !profiles.contains(p) { profiles.append(p) }
                    }
                    ApplyLog.write(L("log.check_profiles", ["app": name, "list": profiles.isEmpty ? "–" : profiles.joined(separator: ", ")]))
                    if !profiles.isEmpty {
                        if let menu = profileMenu(of: app, listing: Set(profiles)) {
                            let list = menu.items.map { $0.title.isEmpty ? "—" : $0.title }.joined(separator: " | ")
                            ApplyLog.write(L("log.check_profile_menu", ["app": name, "menu": menu.title, "list": list]))
                        } else {
                            ApplyLog.write(L("log.check_profile_menu_missing", ["app": name]))
                        }
                    }
                }
            } catch ScriptError.notPermitted {
                ApplyLog.write(L("log.script_not_permitted", ["window": label, "app": name]))
            } catch {
                let message = (error as? ScriptError)?.message ?? error.localizedDescription
                ApplyLog.write(L("log.script_failed", ["window": label, "error": message]))
            }
        }
    }

    /// Show a page in a window: replace an empty new tab, or else open the page in a new tab of that window
    static func showPage(_ url: String, windowID: Int, app: NSRunningApplication) throws {
        guard let bundleID = app.bundleIdentifier, kind(of: bundleID) == .chromiumScriptable else { return }
        let escaped = url.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application id "\(bundleID)"
            set w to window id \(windowID)
            set u to ""
            try
                set u to URL of active tab of w
            end try
            if u is "" or u starts with "chrome://newtab" or u starts with "chrome://new-tab-page" or u starts with "about:blank" then
                set URL of active tab of w to "\(escaped)"
            else
                make new tab at end of tabs of w with properties {URL:"\(escaped)"}
                set active tab index of w to (count of tabs of w)
            end if
        end tell
        """
        _ = try run(source)
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
