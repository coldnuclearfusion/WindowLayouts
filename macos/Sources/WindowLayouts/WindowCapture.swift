import AppKit
import ApplicationServices

/// 저장 시점에 열려 있던 창 하나
struct CapturedWindow: Identifiable {
    let id = UUID()
    let bundleID: String
    let appName: String
    let title: String
    let frame: CGRect
    let element: AXUIElement
    let displayID: String?

    /// includeTitle이 false면 제목을 비우고 "순서만"으로 찾게 저장한다.
    func makeEntry(includeTitle: Bool = true) -> WindowEntry {
        WindowEntry(bundleID: bundleID, appName: appName,
                    title: includeTitle ? title : "",
                    titleMatch: includeTitle ? .auto : .order,
                    frame: frame, displayID: displayID)
    }
}

enum WindowCapture {
    /// 현재 화면에 열려 있는 일반 창들을 앞→뒤 순서로 모은다 (최소화된 창, 이 앱 자신은 제외)
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
                captured.append(CapturedWindow(bundleID: bundleID, appName: name, title: w.title,
                                               frame: w.frame, element: w.element, displayID: display?.id))
            }
        }

        // 창 목록 API로 앞뒤 순서를 얻어 정렬 (제목은 안 쓰므로 화면 기록 권한 불필요)
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
