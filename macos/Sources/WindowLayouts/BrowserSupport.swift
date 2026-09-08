import AppKit
import ApplicationServices

/// 브라우저 창을 페이지 주소로 찾거나 새 창으로 여는 기능.
/// - Safari, Chrome 계열(Chrome/Edge/Brave/Vivaldi): AppleScript로 모든 창의 모든 탭을 훑을 수 있어
///   뒤에 숨은 탭도 찾아서 활성화한다 (처음 한 번 "자동화" 권한 허용 필요).
/// - Firefox 등 AppleScript가 없는 브라우저: 접근성 API로 각 창의 활성 탭 주소만 볼 수 있다.
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

    // MARK: - 주소 비교

    /// 비교용 정규화: 소문자 스킴/호스트, www. 제거, 끝의 / 와 #조각 제거
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

    /// 저장된 주소가 열린 탭 주소의 앞부분과 같으면 같은 페이지로 본다.
    /// 예: 저장 "youtube.com" ↔ 탭 "https://www.youtube.com/watch?v=…" → 일치
    static func matches(saved: String, candidate: String) -> Bool {
        let a = normalize(saved), b = normalize(candidate)
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        guard b.hasPrefix(a) else { return false }
        let next = b[b.index(b.startIndex, offsetBy: a.count)]
        return next == "/" || next == "?" || next == "&"
    }

    // MARK: - AppleScript로 탭 찾기

    struct TabHit {
        let windowID: Int
        let tabIndex: Int
        let url: String
    }

    enum ScriptError: Error { case notPermitted, failed(String) }

    /// 모든 창의 모든 탭 (windowID, tabIndex, url)
    static func listTabs(app: NSRunningApplication) throws -> [TabHit] {
        guard let bundleID = app.bundleIdentifier, let kind = kind(of: bundleID) else { return [] }
        let source: String
        switch kind {
        case .safari:
            source = """
            tell application id "\(bundleID)"
                set out to ""
                repeat with w in windows
                    set i to 0
                    repeat with t in tabs of w
                        set i to i + 1
                        set out to out & (id of w) & tab & i & tab & (URL of t) & linefeed
                    end repeat
                end repeat
                return out
            end tell
            """
        case .chromiumScriptable:
            source = """
            tell application id "\(bundleID)"
                set out to ""
                repeat with w in windows
                    set i to 0
                    repeat with t in tabs of w
                        set i to i + 1
                        set out to out & (id of w) & tab & i & tab & (URL of t) & linefeed
                    end repeat
                end repeat
                return out
            end tell
            """
        default:
            return []
        }
        let text = try run(source)
        return text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let w = Int(parts[0]), let i = Int(parts[1]) else { return nil }
            return TabHit(windowID: w, tabIndex: i, url: String(parts[2]))
        }
    }

    /// 탭을 활성화하고 그 창의 화면 좌표(bounds)를 돌려준다
    static func activate(_ hit: TabHit, app: NSRunningApplication) throws -> CGRect? {
        guard let bundleID = app.bundleIdentifier, let kind = kind(of: bundleID) else { return nil }
        let source: String
        switch kind {
        case .safari:
            source = """
            tell application id "\(bundleID)"
                set w to window id \(hit.windowID)
                set current tab of w to tab \(hit.tabIndex) of w
                set b to bounds of w
                return (item 1 of b as text) & "," & (item 2 of b as text) & "," & (item 3 of b as text) & "," & (item 4 of b as text)
            end tell
            """
        case .chromiumScriptable:
            source = """
            tell application id "\(bundleID)"
                set w to window id \(hit.windowID)
                set active tab index of w to \(hit.tabIndex)
                set b to bounds of w
                return (item 1 of b as text) & "," & (item 2 of b as text) & "," & (item 3 of b as text) & "," & (item 4 of b as text)
            end tell
            """
        default:
            return nil
        }
        let text = try run(source)
        let n = text.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard n.count == 4 else { return nil }
        return CGRect(x: n[0], y: n[1], width: n[2] - n[0], height: n[3] - n[1])
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

    // MARK: - 새 창으로 열기

    /// 새 창에 URL을 연다. 성공 여부만 돌려주고, 창이 생기는 건 호출한 쪽에서 기다린다.
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
            // 실행 파일을 --new-window 로 다시 부르면 이미 실행 중인 인스턴스가 새 창을 연다
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
