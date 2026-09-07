import AppKit
import ApplicationServices
import Observation

extension DisplayConfig {
    /// 지금 연결된 모니터 구성 (AX 좌표계: 주 화면 왼쪽 위가 (0,0), 아래로 y 증가)
    static func current() -> DisplayConfig {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return DisplayConfig(displays: []) }
        let primaryHeight = primary.frame.height
        var displays: [DisplayInfo] = []
        for screen in screens {
            let f = screen.frame
            let axFrame = CGRect(x: f.origin.x, y: primaryHeight - f.maxY, width: f.width, height: f.height)
            var id: String?
            if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
               let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() {
                id = CFUUIDCreateString(nil, uuid) as String
            }
            displays.append(DisplayInfo(
                id: id ?? "\(screen.localizedName)-\(Int(f.width))x\(Int(f.height))",
                name: screen.localizedName,
                frame: axFrame,
                isMain: screen == primary
            ))
        }
        return DisplayConfig(displays: displays)
    }
}

/// 손쉬운 사용 권한과 모니터 연결 상태를 감시해서 UI가 즉시 따라오게 한다.
@Observable
final class SystemMonitor {
    static let shared = SystemMonitor()

    var isTrusted = Accessibility.isTrusted
    var displayConfig = DisplayConfig.current()

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observers: [Any] = []

    init() {
        // 메뉴가 열려 있는 동안에도 돌도록 common 모드에 등록
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        // 시스템 설정에서 손쉬운 사용 목록이 바뀌면 오는 알림
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.refresh() }
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refresh()
        })
    }

    func refresh() {
        let trusted = Accessibility.isTrusted
        if trusted != isTrusted { isTrusted = trusted }
        let config = DisplayConfig.current()
        if config != displayConfig { displayConfig = config }
    }
}
