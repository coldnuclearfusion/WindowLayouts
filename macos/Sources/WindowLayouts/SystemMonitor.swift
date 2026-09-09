import AppKit
import ApplicationServices
import Observation

extension DisplayConfig {
    /// The currently connected monitors (AX coordinates: main display's top-left is (0,0), y grows downward)
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

/// Watches the Accessibility permission and the display configuration so the UI follows immediately.
@Observable
final class SystemMonitor {
    static let shared = SystemMonitor()

    var isTrusted = Accessibility.isTrusted
    var displayConfig = DisplayConfig.current()

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observers: [Any] = []

    init() {
        // Run in common modes so the timer keeps firing while a menu is open
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        // Posted when the Accessibility list in System Settings changes
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
