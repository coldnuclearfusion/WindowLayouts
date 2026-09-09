import AppKit
import ApplicationServices

/// One window that was open at capture time
struct CapturedWindow: Identifiable {
    let id = UUID()
    let bundleID: String
    let appName: String
    let title: String
    let frame: CGRect
    let element: AXUIElement
    let displayID: String?
    /// For browser windows, the active tab's address
    let url: String?

    /// With includeTitle false the title is cleared and matching is by order only; with includeURL false the address is not saved.
    func makeEntry(includeTitle: Bool = true, includeURL: Bool = true) -> WindowEntry {
        WindowEntry(bundleID: bundleID, appName: appName,
                    title: includeTitle ? title : "",
                    titleMatch: includeTitle ? .auto : .order,
                    frame: frame, displayID: displayID,
                    url: includeURL ? url : nil)
    }
}

enum WindowCapture {
    /// Collect the normal windows currently on screen, front to back (minimized windows and this app excluded)
    static func currentWindows() -> [CapturedWindow] {
        guard Accessibility.isTrusted else { return [] }
        let myPID = ProcessInfo.processInfo.processIdentifier
        let config = DisplayConfig.current()
        var captured: [CapturedWindow] = []

        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular,
                  app.processIdentifier != myPID,
                  !app.isTerminated else { continue }
            let bundleID = app.bundleIdentifier ?? "pid.\(app.processIdentifier)"
            let name = app.localizedName ?? bundleID
            for w in AX.windows(for: app) where !w.isMinimized && w.frame.width > 1 && w.frame.height > 1 {
                let center = CGPoint(x: w.frame.midX, y: w.frame.midY)
                let display = config.display(containing: center) ?? config.display(containing: w.frame.origin)
                let url = BrowserSupport.isBrowser(bundleID) ? AX.webURL(of: w.element) : nil
                captured.append(CapturedWindow(bundleID: bundleID, appName: name, title: w.title,
                                               frame: w.frame, element: w.element, displayID: display?.id, url: url))
            }
        }

        // Sort by z-order from the window list API (titles aren't used, so no Screen Recording permission needed)
        let zOrder = onScreenWindowOrder()
        func rank(_ w: CapturedWindow, pid: pid_t) -> Int {
            zOrder.firstIndex { $0.pid == pid && $0.bounds.approximatelyEquals(w.frame) } ?? Int.max
        }
        let pidByBundle = Dictionary(NSWorkspace.shared.runningApplications.compactMap { app -> (String, pid_t)? in
            guard let id = app.bundleIdentifier else { return nil }
            return (id, app.processIdentifier)
        }, uniquingKeysWith: { a, _ in a })
        return captured
            .map { (window: $0, rank: rank($0, pid: pidByBundle[$0.bundleID] ?? -1)) }
            .sorted { $0.rank < $1.rank }
            .map(\.window)
    }

    private static func onScreenWindowOrder() -> [(pid: pid_t, bounds: CGRect)] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        return info.compactMap { dict in
            guard let layer = dict[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = dict[kCGWindowOwnerPID as String] as? Int,
                  let boundsDict = dict[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { return nil }
            return (pid_t(pid), bounds)
        }
    }
}

extension CGRect {
    func approximatelyEquals(_ other: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(origin.x - other.origin.x) <= tolerance &&
        abs(origin.y - other.origin.y) <= tolerance &&
        abs(width - other.width) <= tolerance &&
        abs(height - other.height) <= tolerance
    }
}
