import AppKit
import ApplicationServices
import Observation

/// Watches the windows that the last apply placed. The applied layout keeps its check in the menu only while every one
/// of them is where the apply left it: moving, resizing, minimizing or closing one removes the check, and putting the
/// window back brings the check back. Window order and tabs are not watched.
///
/// Nothing is polled. macOS reports, through Accessibility observers, every move, resize, minimize, restore and close
/// of the watched apps' windows and every new window; NSWorkspace reports apps starting and quitting. After a burst of
/// such events (a window being dragged) the windows are compared once, off the main thread. The placements are kept
/// in UserDefaults, so after a restart the check comes back once the apps have reopened their windows in place.
@Observable
final class PlacementWatcher {
    static let shared = PlacementWatcher()

    /// Whether all windows placed by the last apply are still where they were put
    private(set) var inPlace = false

    struct Placement: Codable, Equatable {
        var bundleID: String
        var x: Double
        var y: Double
        var width: Double
        var height: Double

        init(bundleID: String, frame: CGRect) {
            self.bundleID = bundleID
            x = frame.minX
            y = frame.minY
            width = frame.width
            height = frame.height
        }

        var frame: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    }

    @ObservationIgnored private var placements: [Placement] = []
    /// Parallel to placements: the window watched for each one, nil while it is not known
    @ObservationIgnored private var elements: [AXUIElement?] = []
    /// Bumped whenever the placements change, so that a comparison still running for old ones is ignored
    @ObservationIgnored private var generation = 0
    /// One Accessibility observer per watched process
    @ObservationIgnored private var observers: [pid_t: AXObserver] = [:]
    /// Windows whose events are reported, and registrations macOS refused (for the status report)
    @ObservationIgnored private var registeredWindows = 0
    @ObservationIgnored private var failedRegistrations = 0
    @ObservationIgnored private var pendingCheck: DispatchWorkItem?
    @ObservationIgnored private var checking = false
    @ObservationIgnored private var checkAgain = false
    @ObservationIgnored private let queue = DispatchQueue(label: "WindowLayouts.PlacementWatcher", qos: .utility)

    private static let defaultsKey = "lastAppliedPlacements"
    static let tolerance: CGFloat = 4
    /// Some apps adjust a frame right after it was set; the reference frames are read after this delay
    private static let settleDelay: TimeInterval = 1
    /// Events arrive in bursts while a window is dragged; the windows are compared once they pause this long
    private static let quietDelay: TimeInterval = 0.3
    private static let windowNotifications = [
        kAXMovedNotification, kAXResizedNotification, kAXWindowMiniaturizedNotification,
        kAXWindowDeminiaturizedNotification, kAXUIElementDestroyedNotification,
    ]

    private init() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            self?.appLaunched(note)
        }
        workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            self?.appTerminated(note)
        }
        // Displays added, removed or rearranged: macOS moves windows around
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            self?.scheduleCheck(after: 1)
        }
    }

    // MARK: - Driven by the applier

    /// An apply is about to move windows: nothing is watched (and nothing is checked) until it finishes
    func stop() {
        generation += 1
        pendingCheck?.cancel()
        pendingCheck = nil
        unobserveAll()
        placements = []
        elements = []
        inPlace = false
    }

    /// An apply finished: watch the windows it placed, at the frames they have once the apps have settled
    func start(with placed: [(bundleID: String, element: AXUIElement)]) {
        stop()
        save()
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay) { [self] in
            guard gen == generation else { return }
            var newPlacements: [Placement] = []
            var newElements: [AXUIElement?] = []
            for item in placed {
                guard let frame = AX.currentFrame(item.element) else { continue }
                newPlacements.append(Placement(bundleID: item.bundleID, frame: frame))
                newElements.append(item.element)
            }
            begin(newPlacements, newElements)
        }
    }

    /// A layout was just saved from the open windows, or refreshed to them: it is the current layout now. Its windows
    /// are watched at the frames that were saved, so the check stays off if one of them has moved in the meantime.
    func adopt(_ windows: [(bundleID: String, element: AXUIElement, frame: CGRect)]) {
        stop()
        begin(windows.map { Placement(bundleID: $0.bundleID, frame: $0.frame) }, windows.map { $0.element })
    }

    /// Open windows were added to the current layout: watch them as well
    func extend(with windows: [(bundleID: String, element: AXUIElement, frame: CGRect)]) {
        guard !windows.isEmpty else { return }
        generation += 1
        begin(placements + windows.map { Placement(bundleID: $0.bundleID, frame: $0.frame) },
              elements + windows.map { $0.element })
    }

    private func begin(_ newPlacements: [Placement], _ newElements: [AXUIElement?]) {
        placements = newPlacements
        elements = newElements
        save()
        observeApps()
        check()
    }

    /// At launch: watch the placements saved by the last apply. For a layout applied by a version that did not save
    /// them, its target frames stand in. Windows that are not there yet are found when they appear.
    func restore() {
        guard let id = LayoutStore.shared.lastAppliedID, let layout = LayoutStore.shared.layout(id: id) else { return }
        var restored = load()
        if restored.isEmpty {
            let config = DisplayConfig.current()
            restored = layout.windows.filter(\.enabled).map {
                Placement(bundleID: $0.bundleID,
                          frame: LayoutApplier.targetFrame(for: $0, saved: layout.displayConfig, current: config))
            }
        }
        generation += 1
        placements = restored
        elements = Array(repeating: nil, count: restored.count)
        observeApps()
        check()
        // Right after launch (or a change of the app's identity) Accessibility may not answer yet, so that no window is
        // found or registered; look again a couple of times. Windows found then are registered for events.
        for delay in [3.0, 15.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.scheduleCheck(after: 0) }
        }
    }

    // MARK: - Events

    private func observeApps() {
        for bundleID in Set(placements.map(\.bundleID)) {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) where !app.isTerminated {
                observe(pid: app.processIdentifier)
            }
        }
    }

    /// Ask macOS to report the app's new windows, and moves, resizes, minimizes, restores and closes of its windows
    private func observe(pid: pid_t) {
        guard observers[pid] == nil else { return }
        var created: AXObserver?
        let status = AXObserverCreate(pid, { _, element, notification, refcon in
            guard let refcon else { return }
            Unmanaged<PlacementWatcher>.fromOpaque(refcon).takeUnretainedValue().received(notification as String, element)
        }, &created)
        guard status == .success, let observer = created else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(observer, AXUIElementCreateApplication(pid), kAXWindowCreatedNotification as CFString, refcon)
        for window in AX.windows(pid: pid) { register(window.element, with: observer) }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        observers[pid] = observer
    }

    private func register(_ window: AXUIElement, with observer: AXObserver) {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var failed = false
        var added = false
        for name in Self.windowNotifications {
            switch AXObserverAddNotification(observer, window, name as CFString, refcon) {
            case .success: added = true
            case .notificationAlreadyRegistered: break
            default: failed = true
            }
        }
        if failed { failedRegistrations += 1 } else if added { registeredWindows += 1 }
    }

    private func unobserveAll() {
        for observer in observers.values {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observers.removeAll()
        registeredWindows = 0
        failedRegistrations = 0
    }

    /// Called on the main thread (the observers' run loop)
    private func received(_ notification: String, _ element: AXUIElement) {
        if notification == kAXWindowCreatedNotification as String {
            var pid: pid_t = 0
            if AXUIElementGetPid(element, &pid) == .success, let observer = observers[pid] {
                register(element, with: observer)
            }
        }
        scheduleCheck()
    }

    private func appLaunched(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleID = app.bundleIdentifier, placements.contains(where: { $0.bundleID == bundleID }) else { return }
        observe(pid: app.processIdentifier)
        scheduleCheck(after: 1)
    }

    private func appTerminated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let observer = observers.removeValue(forKey: app.processIdentifier) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        scheduleCheck()
    }

    // MARK: - Comparing

    private func scheduleCheck(after delay: TimeInterval = PlacementWatcher.quietDelay) {
        guard !placements.isEmpty else { return }
        pendingCheck?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.check() }
        pendingCheck = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func check() {
        if checking {
            checkAgain = true
            return
        }
        guard let layoutID = LayoutStore.shared.lastAppliedID else {
            stop()      // the layout was deleted
            return
        }
        guard !placements.isEmpty else {
            inPlace = false
            return
        }
        checking = true
        let gen = generation
        let currentPlacements = placements
        let currentElements = elements
        var pids: [String: [pid_t]] = [:]       // gathered here, on the main thread
        for bundleID in Set(currentPlacements.map(\.bundleID)) {
            pids[bundleID] = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { !$0.isTerminated }
                .map(\.processIdentifier)
        }
        queue.async { [self] in
            let result = Self.evaluate(currentPlacements, currentElements, pids: pids)
            DispatchQueue.main.async { [self] in
                checking = false
                if checkAgain {
                    checkAgain = false
                    scheduleCheck()
                }
                guard gen == generation else { return }
                // Windows found again (after a restart, or reopened) also need their events registered
                for (i, element) in result.elements.enumerated() {
                    guard let element, i >= elements.count || elements[i].map({ !CFEqual($0, element) }) ?? true else { continue }
                    var pid: pid_t = 0
                    guard AXUIElementGetPid(element, &pid) == .success else { continue }
                    if observers[pid] == nil { observe(pid: pid) }
                    if let observer = observers[pid] { register(element, with: observer) }
                }
                elements = result.elements
                guard result.inPlace != inPlace else { return }
                inPlace = result.inPlace
                let name = LayoutStore.shared.layout(id: layoutID)?.name ?? ""
                if result.inPlace {
                    ApplyLog.write(L("log.check_on", ["name": name]))
                } else {
                    let bundleID = result.firstOff ?? ""
                    let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName
                        ?? LayoutStore.shared.layout(id: layoutID)?.appName(for: bundleID) ?? bundleID
                    ApplyLog.write(L("log.check_off", ["name": name, "app": app]))
                }
            }
        }
    }

    struct Evaluation {
        var elements: [AXUIElement?]
        var inPlace: Bool
        /// App of the first placement found out of place
        var firstOff: String?
    }

    /// Compare every placement with its window. A window that is gone (or not known yet) is looked for again among
    /// that app's windows at the placed frame, so a restored or reopened window counts once it is back in place.
    static func evaluate(_ placements: [Placement], _ elements: [AXUIElement?], pids: [String: [pid_t]]) -> Evaluation {
        var elements = elements
        var used = elements.compactMap { $0 }
        var allInPlace = true
        var firstOff: String?
        func off(_ p: Placement) {
            allInPlace = false
            if firstOff == nil { firstOff = p.bundleID }
        }
        for (i, p) in placements.enumerated() {
            if let element = elements[i] {
                if let frame = AX.currentFrame(element) {
                    let minimized = AX.bool(element, kAXMinimizedAttribute) ?? false
                    if !minimized && frame.approximatelyEquals(p.frame, tolerance: tolerance) { continue }
                    off(p)
                    continue
                }
                // closed (or not answering): forget it and look for the window again below
                elements[i] = nil
                used.removeAll { CFEqual($0, element) }
            }
            let candidates = (pids[p.bundleID] ?? []).flatMap { AX.windows(pid: $0) }
            if let w = candidates.first(where: { c in
                !c.isMinimized && c.frame.approximatelyEquals(p.frame, tolerance: tolerance)
                    && !used.contains { CFEqual($0, c.element) }
            }) {
                elements[i] = w.element
                used.append(w.element)
                continue
            }
            off(p)
        }
        return Evaluation(elements: elements, inPlace: allInPlace && !placements.isEmpty, firstOff: firstOff)
    }

    // MARK: - Status report

    /// Read-only report for `open "windowlayouts://check-placement"`: each watched window and whether it is in place
    func logStatus() {
        guard let id = LayoutStore.shared.lastAppliedID, let layout = LayoutStore.shared.layout(id: id) else {
            ApplyLog.write(L("log.placement_none"))
            return
        }
        ApplyLog.write(L("log.placement_start", ["name": layout.name, "count": String(placements.count),
                                                 "state": inPlace ? L("log.placement_checked") : L("log.placement_unchecked")]))
        ApplyLog.write(L("log.placement_observing", ["apps": String(observers.count), "windows": String(registeredWindows),
                                                     "failed": String(failedRegistrations)]))
        for (i, p) in placements.enumerated() {
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: p.bundleID).filter { !$0.isTerminated }
            let app = apps.first?.localizedName ?? layout.appName(for: p.bundleID)
            let state: String
            if i < elements.count, let element = elements[i], let frame = AX.currentFrame(element) {
                if AX.bool(element, kAXMinimizedAttribute) ?? false {
                    state = L("log.placement_minimized")
                } else if frame.approximatelyEquals(p.frame, tolerance: Self.tolerance) {
                    state = L("log.placement_in_place")
                } else {
                    state = L("log.placement_moved", ["frame": frame.shortDescription])
                }
            } else {
                let windows = apps.flatMap { AX.windows(for: $0) }
                if windows.isEmpty {
                    state = L("log.placement_no_window")
                } else if windows.contains(where: { !$0.isMinimized && $0.frame.approximatelyEquals(p.frame, tolerance: Self.tolerance) }) {
                    state = L("log.placement_found")
                } else {
                    state = L("log.placement_elsewhere", ["frames": windows.prefix(4).map(\.frame.shortDescription).joined(separator: ", ")])
                }
            }
            ApplyLog.write(L("log.placement_item", ["app": app, "frame": p.frame.shortDescription, "state": state]))
        }
    }

    // MARK: - Saved placements

    private func save() {
        let data = try? JSONEncoder().encode(placements)
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    private func load() -> [Placement] {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let saved = try? JSONDecoder().decode([Placement].self, from: data) else { return [] }
        return saved
    }
}
