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

    /// 창을 주어진 위치/크기로 옮긴다. 최소화되어 있으면 먼저 복원한다.
    @discardableResult
    static func setFrame(_ element: AXUIElement, _ frame: CGRect) -> Bool {
        if bool(element, kAXMinimizedAttribute) == true {
            setBool(element, kAXMinimizedAttribute, false)
            usleep(250_000)
        }
        if bool(element, "AXFullScreen") == true {
            return false // 전체 화면 창은 건드리지 않음
        }
        // 위치 → 크기 → 위치 순서로 두 번 설정: 크기가 바뀌면서 위치가 밀리는 앱 대응
        let p1 = setPoint(element, kAXPositionAttribute, frame.origin)
        let s = setSize(element, kAXSizeAttribute, frame.size)
        let p2 = setPoint(element, kAXPositionAttribute, frame.origin)
        return (p1 || p2) && s
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
