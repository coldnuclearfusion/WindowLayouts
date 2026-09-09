import AppKit
import ApplicationServices
import Observation

struct ApplyReport {
    let layoutID: UUID
    let layoutName: String
    var placed: [String] = []
    var unmatched: [String] = []
    var launched: [String] = []
    var notRunning: [String] = []
    var failed: [String] = []
    var mismatched: [String] = []
    var notes: [String] = []
    var cancelled = false
    var error: String?

    var headline: String {
        if let error { return error }
        if cancelled { return L("report.cancelled", ["name": layoutName]) }
        var s = L("report.headline", ["name": layoutName, "placed": String(placed.count)])
        if !unmatched.isEmpty { s += L("report.unmatched_suffix", ["count": String(unmatched.count)]) }
        if !mismatched.isEmpty { s += L("report.mismatched_suffix", ["count": String(mismatched.count)]) }
        if !failed.isEmpty { s += L("report.failed_suffix", ["count": String(failed.count)]) }
        return s
    }

    var lines: [String] {
        var l: [String] = notes
        if !launched.isEmpty { l.append(L("report.launched", ["list": launched.joined(separator: ", ")])) }
        if !notRunning.isEmpty { l.append(L("report.not_running", ["list": notRunning.joined(separator: ", ")])) }
        if !unmatched.isEmpty { l.append(L("report.unmatched", ["list": unmatched.joined(separator: ", ")])) }
        if !failed.isEmpty { l.append(L("report.failed", ["list": failed.joined(separator: ", ")])) }
        if !mismatched.isEmpty { l.append(L("report.mismatched", ["list": mismatched.joined(separator: " · ")])) }
        return l
    }
}

/// Matches saved window entries to real windows.
enum WindowMatcher {
    static func match(entries: [WindowEntry], windows: [AXWindow]) -> [(entry: WindowEntry, window: AXWindow?)] {
        var available = windows
        var assigned: [UUID: AXWindow] = [:]

        // 1) exact title match
        for e in entries where e.titleMatch != .order && !e.title.isEmpty {
            if let i = available.firstIndex(where: { $0.title == e.title }) {
                assigned[e.id] = available.remove(at: i)
            }
        }

        // 2) similar titles (for example tab titles that partly changed), best pairs first.
        //    Words shared by all windows (such as the app name) are excluded from the score.
        let boilerplate = commonTokens(of: available.map(\.title))
        var candidates: [(entryIndex: Int, windowIndex: Int, score: Double)] = []
        for (ei, e) in entries.enumerated() where assigned[e.id] == nil && e.titleMatch != .order && !e.title.isEmpty {
            for (wi, w) in available.enumerated() {
                let s = similarity(e.title, w.title, ignoring: boilerplate)
                if s >= 0.3 { candidates.append((ei, wi, s)) }
            }
        }
        candidates.sort { $0.score > $1.score }
        var usedEntries = Set<Int>()
        var usedWindows = Set<Int>()
        for c in candidates where !usedEntries.contains(c.entryIndex) && !usedWindows.contains(c.windowIndex) {
            assigned[entries[c.entryIndex].id] = available[c.windowIndex]
            usedEntries.insert(c.entryIndex)
            usedWindows.insert(c.windowIndex)
        }
        available = available.enumerated().filter { !usedWindows.contains($0.offset) }.map(\.element)

        // 3) remaining entries take the remaining windows in order
        for e in entries where assigned[e.id] == nil && (e.titleMatch != .title || e.title.isEmpty) {
            if !available.isEmpty { assigned[e.id] = available.removeFirst() }
        }
        return entries.map { ($0, assigned[$0.id]) }
    }

    static func tokens(_ s: String) -> Set<String> {
        Set(s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty })
    }

    /// Words that appear in every one of two or more window titles
    static func commonTokens(of titles: [String]) -> Set<String> {
        guard titles.count >= 2 else { return [] }
        return titles.dropFirst().reduce(tokens(titles[0])) { $0.intersection(tokens($1)) }
    }

    static func similarity(_ a: String, _ b: String, ignoring boilerplate: Set<String> = []) -> Double {
        let la = a.lowercased(), lb = b.lowercased()
        if la == lb { return 1 }
        let ta = tokens(la).subtracting(boilerplate)
        let tb = tokens(lb).subtracting(boilerplate)
        guard !ta.isEmpty, !tb.isEmpty else { return 0 }
        if la.contains(lb) || lb.contains(la) { return 0.9 }
        return Double(ta.intersection(tb).count) / Double(min(ta.count, tb.count))
    }
}

@Observable
final class LayoutApplier {
    static let shared = LayoutApplier()

    var isApplying = false
    var lastReport: ApplyReport?

    private enum MissingChoice {
        case launch(remember: Bool)
        case skip(remember: Bool)
        case cancel
    }

    @MainActor
    func apply(_ layout: WindowLayout) async {
        guard !isApplying else { return }
        isApplying = true
        defer { isApplying = false }

        var report = ApplyReport(layoutID: layout.id, layoutName: layout.name)
        ApplyLog.write(L("log.start", ["name": layout.name, "policy": layout.launchPolicy.rawValue, "raise": String(layout.raiseWindows)]))
        defer { ApplyLog.write(L("log.end", ["summary": "\(lastReport?.headline ?? "") \(lastReport?.lines.joined(separator: " | ") ?? "")"])) }

        guard Accessibility.isTrusted else {
            Accessibility.promptIfNeeded()
            report.error = L("report.no_accessibility")
            lastReport = report
            return
        }

        let entries = layout.windows.filter(\.enabled)
        let bundleIDs = layout.enabledBundleIDs
        let currentConfig = DisplayConfig.current()
        ApplyLog.write(L("log.monitors", ["list": currentConfig.displays.map { "\($0.name) \($0.frame.shortDescription)\($0.isMain ? L("log.main_suffix") : "")" }.joined(separator: " / ")]))
        if let saved = layout.displayConfig, !saved.isIdentical(to: currentConfig) {
            report.notes.append(L("report.config_differs", ["saved": saved.name, "current": currentConfig.name]))
        }
        let missing = bundleIDs.filter { runningApps(bundleID: $0).isEmpty }
        // Apps whose process is alive but that have no window (macOS keeps apps running after the last window closes)
        let windowless = bundleIDs.filter { id in
            guard !missing.contains(id) else { return false }
            // If every browser entry has an address, the addresses will open new windows, so skip here
            let appEntries = entries.filter { $0.bundleID == id }
            if BrowserSupport.isBrowser(id) && appEntries.allSatisfy(\.hasURL) { return false }
            return runningApps(bundleID: id).allSatisfy { AX.windows(for: $0).isEmpty }
        }
        let needsOpen = missing + windowless
        var skipped = Set<String>()
        // "Only place existing windows" also means no new windows for browser pages
        var allowNewWindows = layout.launchPolicy != .runningOnly

        func label(_ bundleID: String) -> String {
            layout.appName(for: bundleID) + (windowless.contains(bundleID) ? L("report.windowless_suffix") : "")
        }

        // Apps that aren't running or have no window (requirement 6)
        if !needsOpen.isEmpty {
            var policy = layout.launchPolicy
            if policy == .ask {
                switch askAboutMissing(needsOpen.map(label), layoutName: layout.name) {
                case .launch(let remember):
                    policy = .launchMissing
                    if remember { LayoutStore.shared.setLaunchPolicy(.launchMissing, for: layout.id) }
                case .skip(let remember):
                    policy = .runningOnly
                    if remember { LayoutStore.shared.setLaunchPolicy(.runningOnly, for: layout.id) }
                case .cancel:
                    report.cancelled = true
                    lastReport = report
                    return
                }
            }

            if policy == .launchMissing {
                var toWait: [String: Int] = [:]
                for bundleID in needsOpen {
                    let reopen = windowless.contains(bundleID)
                    if launch(bundleID: bundleID, reopen: reopen) {
                        report.launched.append(layout.appName(for: bundleID) + (reopen ? L("report.new_window_suffix") : ""))
                        toWait[bundleID] = entries.filter { $0.bundleID == bundleID }.count
                    } else {
                        report.failed.append(L("report.app_not_found", ["app": layout.appName(for: bundleID)]))
                        skipped.insert(bundleID)
                    }
                }
                await waitForWindows(toWait)
            } else {
                allowNewWindows = false
                for bundleID in needsOpen {
                    skipped.insert(bundleID)
                    report.notRunning.append(label(bundleID))
                }
            }
        }

        // Match and move windows per app
        var placedWindows: [(entry: WindowEntry, window: AXWindow, app: NSRunningApplication)] = []
        for bundleID in bundleIDs where !skipped.contains(bundleID) {
            let apps = runningApps(bundleID: bundleID)
            for app in apps where app.isHidden { app.unhide() }
            var windows = apps.flatMap { AX.windows(for: $0) }
            var appEntries = entries.filter { $0.bundleID == bundleID }
            var matches: [(entry: WindowEntry, window: AXWindow?)] = []

            // Browsers: entries with an address first look for the window that has that tab, otherwise open a new window
            if BrowserSupport.isBrowser(bundleID), let app = apps.first {
                for entry in appEntries where entry.hasURL {
                    let result = await resolveBrowserWindow(for: entry, app: app, windows: windows,
                                                            allowNewWindow: allowNewWindows)
                    if let note = result.note, !report.notes.contains(note) { report.notes.append(note) }
                    if let window = result.window {
                        matches.append((entry, window))
                        windows.removeAll { AX.isSame($0.element, window.element) }
                        appEntries.removeAll { $0.id == entry.id }
                    }
                }
            }
            matches += WindowMatcher.match(entries: appEntries, windows: windows)

            for (entry, window) in matches {
                guard let window else {
                    report.unmatched.append(entry.displayName)
                    ApplyLog.write(L("log.no_match", ["window": entry.displayName, "count": String(windows.count)]))
                    continue
                }
                let frame = Self.targetFrame(for: entry, saved: layout.displayConfig, current: currentConfig)
                ApplyLog.write(L("log.assigned", ["window": entry.displayName, "title": window.title]))
                let outcome = AX.place(window.element, frame) { ApplyLog.write("[\(entry.displayName)] \($0)") }
                switch outcome {
                case .placed, .mismatch:
                    report.placed.append(entry.displayName)
                    if case .mismatch(let actual) = outcome {
                        report.mismatched.append(L("report.mismatch_item", ["window": entry.displayName, "requested": frame.shortDescription, "actual": actual.shortDescription]))
                    }
                    if let app = apps.first(where: { $0.processIdentifier == AX.pid(of: window.element) }) {
                        placedWindows.append((entry, window, app))
                    }
                case .failed:
                    report.failed.append(entry.displayName)
                }
            }
        }

        // Raise the layout's windows above the others (top row ends up in front)
        if layout.raiseWindows && !placedWindows.isEmpty {
            let failures = await raise(placedWindows, order: layout.windows.map(\.id))
            if failures > 0 { report.notes.append(L("report.raise_failed", ["count": String(failures)])) }
        }

        LayoutStore.shared.lastAppliedID = layout.id
        lastReport = report
    }

    private struct BrowserResolution {
        var window: AXWindow?
        var note: String?
    }

    /// Pick the window for a browser entry that has an address.
    /// 1) AppleScript: search every tab and activate the match (Safari, Chromium browsers)
    /// 2) Accessibility: check each window's active tab address (Firefox and others)
    /// 3) Otherwise open a new window and wait for it to appear
    @MainActor
    private func resolveBrowserWindow(for entry: WindowEntry, app: NSRunningApplication,
                                      windows: [AXWindow], allowNewWindow: Bool) async -> BrowserResolution {
        let url = (entry.url ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var scriptingNote: String?

        do {
            let hits = try BrowserSupport.listTabs(app: app)
            if let hit = hits.first(where: { BrowserSupport.matches(saved: url, candidate: $0.url) }),
               let bounds = try BrowserSupport.activate(hit, app: app) {
                let fresh = AX.windows(for: app)
                let candidates = fresh.filter { $0.frame.approximatelyEquals(bounds, tolerance: 4) }
                if let w = candidates.first(where: { c in windows.contains { AX.isSame($0.element, c.element) } })
                    ?? candidates.first {
                    return BrowserResolution(window: w, note: nil)
                }
            }
        } catch BrowserSupport.ScriptError.notPermitted {
            scriptingNote = L("report.automation_hint", ["app": entry.appName])
        } catch {
            // Browsers without AppleScript support etc.: fall through to the Accessibility path
        }

        for w in windows {
            if let current = AX.webURL(of: w.element), BrowserSupport.matches(saved: url, candidate: current) {
                return BrowserResolution(window: w, note: scriptingNote)
            }
        }

        guard allowNewWindow else { return BrowserResolution(window: nil, note: scriptingNote) }
        let before = AX.windows(for: app).map(\.element)
        guard BrowserSupport.openInNewWindow(url, app: app) else {
            return BrowserResolution(window: nil, note: L("report.new_window_failed", ["app": entry.appName, "url": url]))
        }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(300))
            let now = AX.windows(for: app)
            if let fresh = now.first(where: { w in !before.contains { AX.isSame($0, w.element) } }) {
                try? await Task.sleep(for: .milliseconds(300))
                return BrowserResolution(window: fresh, note: scriptingNote)
            }
        }
        return BrowserResolution(window: nil,
                                 note: L("report.new_window_timeout", ["app": entry.appName, "url": url]))
    }

    /// Activate apps from back to front and raise their windows, so the first entry's app ends up in front.
    /// Activating the app first makes AXRaise reliably put the window above other apps' windows.
    @MainActor
    private func raise(_ placed: [(entry: WindowEntry, window: AXWindow, app: NSRunningApplication)],
                       order: [UUID]) async -> Int {
        let position = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        let sorted = placed.sorted { (position[$0.entry.id] ?? 0) < (position[$1.entry.id] ?? 0) }

        // Group by app while keeping front-to-back order (an app's position is where it first appears)
        var groups: [(app: NSRunningApplication, items: [(entry: WindowEntry, window: AXWindow, app: NSRunningApplication)])] = []
        for item in sorted {
            if let i = groups.firstIndex(where: { $0.app.processIdentifier == item.app.processIdentifier }) {
                groups[i].items.append(item)
            } else {
                groups.append((item.app, [item]))
            }
        }

        var failures = 0
        for group in groups.reversed() {
            if !group.app.activate(from: .current, options: []) {
                group.app.activate(options: [])
            }
            try? await Task.sleep(for: .milliseconds(80))
            for item in group.items.reversed() {
                if AXUIElementPerformAction(item.window.element, kAXRaiseAction as CFString) != .success {
                    failures += 1
                }
                try? await Task.sleep(for: .milliseconds(30))
            }
        }
        return failures
    }

    /// If the monitor setup differs from when the layout was saved, move the window relative to the monitor it was on;
    /// if that monitor is gone, put it on the main display. Clamp so it stays on screen.
    static func targetFrame(for entry: WindowEntry, saved: DisplayConfig?, current: DisplayConfig) -> CGRect {
        guard let saved, !saved.isIdentical(to: current), let currentMain = current.main else { return entry.frame }
        let center = CGPoint(x: entry.frame.midX, y: entry.frame.midY)
        guard let savedDisplay = saved.display(withID: entry.displayID)
                ?? saved.display(containing: center)
                ?? saved.main else { return entry.frame }
        let target = current.display(withID: savedDisplay.id) ?? currentMain
        var frame = entry.frame
        frame.origin.x = target.x + (entry.x - savedDisplay.x)
        frame.origin.y = target.y + (entry.y - savedDisplay.y)
        frame.size.width = min(frame.width, target.width)
        frame.size.height = min(frame.height, target.height)
        frame.origin.x = max(target.x, min(frame.origin.x, target.frame.maxX - frame.width))
        frame.origin.y = max(target.y, min(frame.origin.y, target.frame.maxY - frame.height))
        return frame
    }

    /// Returns a copy with the saved entries updated to the current window positions and the monitor setup set to the current one.
    func refreshedFrames(_ layout: WindowLayout) -> (layout: WindowLayout, updated: Int) {
        var copy = layout
        var updated = 0
        let config = DisplayConfig.current()
        copy.displayConfig = config
        let grouped = Dictionary(grouping: layout.windows.indices) { layout.windows[$0].bundleID }
        for (bundleID, indices) in grouped {
            let windows = runningApps(bundleID: bundleID).flatMap { AX.windows(for: $0) }
            let entries = indices.map { layout.windows[$0] }
            for (i, match) in zip(indices, WindowMatcher.match(entries: entries, windows: windows)) {
                if let w = match.window {
                    copy.windows[i].frame = w.frame
                    let center = CGPoint(x: w.frame.midX, y: w.frame.midY)
                    copy.windows[i].displayID = config.display(containing: center)?.id
                    updated += 1
                }
            }
        }
        return (copy, updated)
    }

    // MARK: - Launching apps

    private func runningApps(bundleID: String) -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { !$0.isTerminated }
    }

    /// Launch the app. For a running app without windows (reopen), this makes it open a window as if its Dock icon was clicked.
    private func launch(bundleID: String, reopen: Bool = false) -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = reopen
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
        return true
    }

    /// Wait for the windows of just-launched apps to appear.
    /// Up to 20 s for the first window, and up to 4 more seconds when more windows are needed.
    private func waitForWindows(_ needed: [String: Int]) async {
        guard !needed.isEmpty else { return }
        var pending = Set(needed.keys)
        let deadline = Date().addingTimeInterval(20)
        while !pending.isEmpty && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(400))
            for bundleID in pending {
                let apps = runningApps(bundleID: bundleID)
                guard !apps.isEmpty, apps.allSatisfy(\.isFinishedLaunching) else { continue }
                if !apps.flatMap({ AX.windows(for: $0) }).isEmpty { pending.remove(bundleID) }
            }
        }
        let extraDeadline = Date().addingTimeInterval(4)
        var short = Set(needed.filter { $0.value > 1 }.keys)
        while !short.isEmpty && Date() < extraDeadline {
            try? await Task.sleep(for: .milliseconds(400))
            for bundleID in short {
                let count = runningApps(bundleID: bundleID).flatMap { AX.windows(for: $0) }.count
                if count >= needed[bundleID, default: 1] { short.remove(bundleID) }
            }
        }
        try? await Task.sleep(for: .milliseconds(500))
    }

    // MARK: - Asking the user

    @MainActor
    private func askAboutMissing(_ names: [String], layoutName: String) -> MissingChoice {
        let alert = NSAlert()
        alert.messageText = L("ask.title")
        alert.informativeText = L("ask.message", ["name": layoutName]) + "\n\n"
            + names.map { "• \($0)" }.joined(separator: "\n")
        alert.addButton(withTitle: L("ask.launch"))
        alert.addButton(withTitle: L("ask.skip"))
        let cancel = alert.addButton(withTitle: L("common.cancel"))
        cancel.keyEquivalent = "\u{1b}"
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = L("ask.remember")

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        let remember = alert.suppressionButton?.state == .on
        switch response {
        case .alertFirstButtonReturn: return .launch(remember: remember)
        case .alertSecondButtonReturn: return .skip(remember: remember)
        default: return .cancel
        }
    }
}
