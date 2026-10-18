import AppKit
import ApplicationServices
import Observation

/// Watches the windows that the last apply placed. The applied layout keeps its check in the menu only while every one
/// of them is where the apply left it: moving, resizing, minimizing or closing one removes the check, and putting the
/// window back brings the check back. Window order and tabs are not watched. Positions are compared every two seconds,
/// off the main thread, and the placements are kept in UserDefaults so the check survives restarts.
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
    /// Bumped whenever the placements change, so that a check still running for old ones is ignored
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var checking = false
    @ObservationIgnored private let queue = DispatchQueue(label: "WindowLayouts.PlacementWatcher", qos: .utility)

    private static let defaultsKey = "lastAppliedPlacements"
    static let tolerance: CGFloat = 4
    private static let interval: TimeInterval = 2
    /// Some apps adjust a frame right after it was set; the reference frames are read after this delay
    private static let settleDelay: TimeInterval = 1

    // MARK: - Driven by the applier

    /// An apply is about to move windows: nothing is watched (and nothing is checked) until it finishes
    func stop() {
        generation += 1
        timer?.invalidate()
        timer = nil
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
            placements = newPlacements
            elements = newElements
            save()
            inPlace = !newPlacements.isEmpty
            startTimer()
        }
    }

    /// At launch: watch the placements saved by the last apply. For a layout applied by a version that did not save
    /// them, its target frames stand in. The windows are looked for on every check, so apps that are still starting
    /// are picked up when their windows appear.
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
        startTimer()
        check()
    }

    // MARK: - Checking

    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in self?.check() }
        RunLoop.main.add(t, forMode: .common)       // keeps running while a menu is open
        timer = t
    }

    private func check() {
        guard !checking else { return }
        guard let layoutID = LayoutStore.shared.lastAppliedID, !placements.isEmpty else {
            timer?.invalidate()
            timer = nil
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
                guard gen == generation else { return }
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
