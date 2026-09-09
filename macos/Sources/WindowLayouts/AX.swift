import AppKit
import ApplicationServices

/// One real window as read through the Accessibility API
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

    /// The app's normal windows (dialogs, sheets and floating windows excluded)
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
        case mismatch(actual: CGRect)   // moved, but the app kept a different size/position
        case failed
    }

    static func currentFrame(_ element: AXUIElement) -> CGRect? {
        guard let p = point(element, kAXPositionAttribute), let s = size(element, kAXSizeAttribute) else { return nil }
        return CGRect(origin: p, size: s)
    }

    /// Move the window to the given position/size and read back whether it actually happened.
    /// If not, retry up to 3 times with the order of operations changed (Chromium-based apps
    /// undo a resize that arrives right after a move to a display with a different scale).
    static func place(_ element: AXUIElement, _ frame: CGRect, log: ((String) -> Void)? = nil) -> PlaceOutcome {
        if bool(element, kAXMinimizedAttribute) == true {
            setBool(element, kAXMinimizedAttribute, false)
            usleep(250_000)
        }
        if bool(element, "AXFullScreen") == true {
            log?(L("log.fullscreen_skip"))
            return .failed
        }
        if let before = currentFrame(element) { log?(L("log.place_start", ["from": before.shortDescription, "to": frame.shortDescription])) }

        var anySuccess = false
        for attempt in 1...3 {
            var ok = false
            switch attempt {
            case 1:
                // size → position → size: resize on the current display first, then move
                ok = setSize(element, kAXSizeAttribute, frame.size)
                ok = setPoint(element, kAXPositionAttribute, frame.origin) || ok
                ok = setSize(element, kAXSizeAttribute, frame.size) || ok
            case 2:
                usleep(150_000)
                // position → size → position
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
            log?(L("log.place_attempt", ["attempt": String(attempt), "result": now.shortDescription]) + (match ? " ✓" : ""))
            if match { return .placed }
        }
        guard anySuccess, let now = currentFrame(element) else { return .failed }
        return .mismatch(actual: now)
    }

    /// Kept for older call sites
    @discardableResult
    static func setFrame(_ element: AXUIElement, _ frame: CGRect) -> Bool {
        place(element, frame) != .failed
    }

    /// The page address shown by a browser window (active tab): window → web area (AXWebArea) → AXURL.
    /// Other tabs' addresses are not visible through the Accessibility API.
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

    // MARK: - Reading and writing attributes

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
