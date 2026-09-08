import AppKit
import ApplicationServices

/// Accessibility API로 읽은 실제 창 하나
struct AXWindow {
    let element: AXUIElement
    let title: String
    let frame: CGRect
    let isMinimized: Bool
}

enum AX {
    private static let excludedSubroles: Set<String> = [
        kAXDialogSubrole,
        kAXSystemDialogSubrole,
        kAXFloatingWindowSubrole,
        kAXSystemFloatingWindowSubrole,
        "AXSheet",
        "AXPopover",
    ]

    /// 앱의 일반 창 목록 (대화상자, 시트, 플로팅 창은 제외)
    static func windows(for app: NSRunningApplication) -> [AXWindow] {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 1.0)
        guard let raw = copyAttribute(appElement, kAXWindowsAttribute),
              let list = raw as? [AXUIElement] else { return [] }

        var result: [AXWindow] = []
        for element in list {
            AXUIElementSetMessagingTimeout(element, 1.0)
            let subrole = string(element, kAXSubroleAttribute) ?? ""
            if excludedSubroles.contains(subrole) { continue }
            guard let origin = point(element, kAXPositionAttribute),
                  let size = size(element, kAXSizeAttribute) else { continue }
            let title = string(element, kAXTitleAttribute) ?? ""
            let minimized = bool(element, kAXMinimizedAttribute) ?? false
            result.append(AXWindow(element: element,
                                   title: title,
                                   frame: CGRect(origin: origin, size: size),
                                   isMinimized: minimized))
        }
        return result
    }

    enum PlaceOutcome: Equatable {
        case placed
        case mismatch(actual: CGRect)   // 옮기긴 했지만 앱이 크기/위치를 다르게 잡음
        case failed
    }

    static func currentFrame(_ element: AXUIElement) -> CGRect? {
        guard let p = point(element, kAXPositionAttribute), let s = size(element, kAXSizeAttribute) else { return nil }
        return CGRect(origin: p, size: s)
    }

    /// 창을 주어진 위치/크기로 옮기고, 실제로 그렇게 됐는지 읽어서 확인한다.
    /// 안 맞으면 순서를 바꿔 가며 최대 3번 시도한다 (다른 배율의 화면으로 옮길 때
    /// Chromium 계열 앱이 크기 변경을 되돌리는 경우 대응).
    static func place(_ element: AXUIElement, _ frame: CGRect, log: ((String) -> Void)? = nil) -> PlaceOutcome {
        if bool(element, kAXMinimizedAttribute) == true {
            setBool(element, kAXMinimizedAttribute, false)
            usleep(250_000)
        }
        if bool(element, "AXFullScreen") == true {
            log?("전체 화면 창이라 건너뜀")
            return .failed
        }
        if let before = currentFrame(element) { log?("시작 \(before.shortDescription) → 목표 \(frame.shortDescription)") }

        var anySuccess = false
        for attempt in 1...3 {
            var ok = false
            switch attempt {
            case 1:
                // 크기 → 위치 → 크기: 지금 있는 화면에서 크기를 먼저 맞춘 뒤 옮긴다
                ok = setSize(element, kAXSizeAttribute, frame.size)
                ok = setPoint(element, kAXPositionAttribute, frame.origin) || ok
                ok = setSize(element, kAXSizeAttribute, frame.size) || ok
            case 2:
                usleep(150_000)
                // 위치 → 크기 → 위치
                ok = setPoint(element, kAXPositionAttribute, frame.origin)
                ok = setSize(element, kAXSizeAttribute, frame.size) || ok
                ok = setPoint(element, kAXPositionAttribute, frame.origin) || ok
            default:
                usleep(300_000)
                ok = setSize(element, kAXSizeAttribute, frame.size)
                ok = setPoint(element, kAXPositionAttribute, frame.origin) || ok
            }
            anySuccess = anySuccess || ok
            usleep(60_000)
            guard let now = currentFrame(element) else { continue }
            let match = now.approximatelyEquals(frame, tolerance: 2)
            log?("시도 \(attempt): 결과 \(now.shortDescription)\(match ? " ✓" : "")")
            if match { return .placed }
        }
        guard anySuccess, let now = currentFrame(element) else { return .failed }
        return .mismatch(actual: now)
    }

    /// 예전 호출 호환용
    @discardableResult
    static func setFrame(_ element: AXUIElement, _ frame: CGRect) -> Bool {
        place(element, frame) != .failed
    }

    /// 브라우저 창이 보여주는 페이지 주소 (활성 탭). 창 → 웹 영역(AXWebArea)의 AXURL을 찾는다.
    /// 다른 탭의 주소는 접근성 API로 볼 수 없다.
    static func webURL(of window: AXUIElement, maxDepth: Int = 16, maxNodes: Int = 1500) -> String? {
        if let doc = string(window, kAXDocumentAttribute), doc.hasPrefix("http") { return doc }
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var visited = 0
        while !queue.isEmpty && visited < maxNodes {
            let (element, depth) = queue.removeFirst()
            visited += 1
            let role = string(element, kAXRoleAttribute) ?? ""
            if role == "AXWebArea" {
                if let u = urlString(element, "AXURL") { return u }
                if let d = string(element, kAXDocumentAttribute) { return d }
                continue
            }
            guard depth < maxDepth,
                  let children = copyAttribute(element, kAXChildrenAttribute) as? [AXUIElement] else { continue }
            queue.append(contentsOf: children.map { ($0, depth + 1) })
        }
        return nil
    }

    static func urlString(_ element: AXUIElement, _ attribute: String) -> String? {
        guard let v = copyAttribute(element, attribute) else { return nil }
        if let u = v as? URL { return u.absoluteString }
        if let u = v as? NSURL { return u.absoluteString }
        if let s = v as? String { return s }
        return nil
    }

    static func isSame(_ a: AXUIElement, _ b: AXUIElement) -> Bool {
        CFEqual(a, b)
    }

    static func pid(of element: AXUIElement) -> pid_t {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : 0
    }

    // MARK: - 속성 읽기/쓰기

    static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard err == .success else { return nil }
        return value
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        copyAttribute(element, attribute) as? String
    }

    static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        guard let v = copyAttribute(element, attribute) else { return nil }
        if CFGetTypeID(v) == CFBooleanGetTypeID() {
            return CFBooleanGetValue((v as! CFBoolean))
        }
        return (v as? NSNumber)?.boolValue
    }

    static func point(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        guard let v = copyAttribute(element, attribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
    }

    static func size(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        guard let v = copyAttribute(element, attribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
    }

    @discardableResult
    static func setPoint(_ element: AXUIElement, _ attribute: String, _ value: CGPoint) -> Bool {
        var v = value
        guard let axValue = AXValueCreate(.cgPoint, &v) else { return false }
        return AXUIElementSetAttributeValue(element, attribute as CFString, axValue) == .success
    }

    @discardableResult
    static func setSize(_ element: AXUIElement, _ attribute: String, _ value: CGSize) -> Bool {
        var v = value
        guard let axValue = AXValueCreate(.cgSize, &v) else { return false }
        return AXUIElementSetAttributeValue(element, attribute as CFString, axValue) == .success
    }

    @discardableResult
    static func setBool(_ element: AXUIElement, _ attribute: String, _ value: Bool) -> Bool {
        AXUIElementSetAttributeValue(element, attribute as CFString, value ? kCFBooleanTrue : kCFBooleanFalse) == .success
    }
}
