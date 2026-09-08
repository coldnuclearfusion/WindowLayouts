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

/// 저장된 배치의 창 항목들을 실제 창에 짝지어 준다.
enum WindowMatcher {
    static func match(entries: [WindowEntry], windows: [AXWindow]) -> [(entry: WindowEntry, window: AXWindow?)] {
        var available = windows
        var assigned: [UUID: AXWindow] = [:]

        // 1) 제목이 정확히 같은 창
        for e in entries where e.titleMatch != .order && !e.title.isEmpty {
            if let i = available.firstIndex(where: { $0.title == e.title }) {
                assigned[e.id] = available.remove(at: i)
            }
        }

        // 2) 비슷한 제목 (탭 제목처럼 일부만 바뀌는 경우). 점수 높은 짝부터 배정.
        //    모든 창에 공통으로 붙는 단어(앱 이름 등)는 점수 계산에서 뺀다.
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

        // 3) 남은 항목은 남은 창에 순서대로
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

    /// 두 개 이상의 창 제목 모두에 들어 있는 단어들
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
        // 프로세스는 살아 있지만 창이 하나도 없는 앱 (창을 다 닫아도 앱은 남아 있는 macOS 특성)
        let windowless = bundleIDs.filter { id in
            guard !missing.contains(id) else { return false }
            // 브라우저 항목이 전부 주소를 가지고 있으면 주소로 새 창을 열 것이므로 여기서는 제외
            let appEntries = entries.filter { $0.bundleID == id }
            if BrowserSupport.isBrowser(id) && appEntries.allSatisfy(\.hasURL) { return false }
            return runningApps(bundleID: id).allSatisfy { AX.windows(for: $0).isEmpty }
        }
        let needsOpen = missing + windowless
        var skipped = Set<String>()
        // "지금 있는 창만 배치"면 브라우저 페이지도 새 창으로 열지 않는다
        var allowNewWindows = layout.launchPolicy != .runningOnly

        func label(_ bundleID: String) -> String {
            layout.appName(for: bundleID) + (windowless.contains(bundleID) ? L("report.windowless_suffix") : "")
        }

        // 실행 안 된 앱, 창 없는 앱 처리 (요구사항 6)
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

        // 앱별로 창을 짝지어 옮기기
        var placedWindows: [(entry: WindowEntry, window: AXWindow, app: NSRunningApplication)] = []
        for bundleID in bundleIDs where !skipped.contains(bundleID) {
            let apps = runningApps(bundleID: bundleID)
            for app in apps where app.isHidden { app.unhide() }
            var windows = apps.flatMap { AX.windows(for: $0) }
            var appEntries = entries.filter { $0.bundleID == bundleID }
            var matches: [(entry: WindowEntry, window: AXWindow?)] = []

            // 브라우저: 주소가 지정된 항목은 그 페이지 탭이 있는 창을 먼저 찾고, 없으면 새 창으로 연다
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

        // 배치의 창들을 다른 창들 위로 올리기 (표의 위 항목이 가장 앞)
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

    /// 주소가 지정된 브라우저 항목에 쓸 창을 정한다.
    /// 1) AppleScript로 모든 탭을 뒤져 맞는 탭을 활성화 (Safari, Chrome 계열)
    /// 2) 접근성 API로 각 창의 활성 탭 주소 확인 (Firefox 등)
    /// 3) 없으면 새 창으로 열고 창이 생길 때까지 기다림
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
            // AppleScript를 지원하지 않는 브라우저 등: 아래 접근성 경로로
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

    /// 앱 단위로 뒤에서부터 활성화하고 창을 올려서, 마지막에 첫 항목의 앱이 맨 앞에 오게 한다.
    /// 앱을 먼저 활성화해야 AXRaise가 다른 앱 창보다 위로 확실히 올라간다.
    @MainActor
    private func raise(_ placed: [(entry: WindowEntry, window: AXWindow, app: NSRunningApplication)],
                       order: [UUID]) async -> Int {
        let position = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        let sorted = placed.sorted { (position[$0.entry.id] ?? 0) < (position[$1.entry.id] ?? 0) }

        // 앞→뒤 순서를 유지하며 앱별로 묶기 (같은 앱은 첫 등장 위치 기준)
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

    /// 모니터 구성이 저장 당시와 다르면, 창이 있던 모니터를 찾아 그 모니터 기준 상대 위치로 옮기고
    /// 그 모니터가 없으면 주 화면에 놓는다. 화면 밖으로 나가지 않게 잘라 맞춘다.
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

    /// 저장된 항목의 위치/크기를 지금 실제 창 위치로 갱신하고, 모니터 구성도 현재 것으로 바꾼 사본을 돌려준다.
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

    // MARK: - 앱 실행

    private func runningApps(bundleID: String) -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { !$0.isTerminated }
    }

    /// 앱을 실행한다. 이미 실행 중인데 창이 없는 앱(reopen)이면 Dock 아이콘을 눌렀을 때처럼 새 창을 열게 한다.
    private func launch(bundleID: String, reopen: Bool = false) -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = reopen
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
        return true
    }

    /// 방금 실행한 앱들의 창이 생길 때까지 기다린다.
    /// 첫 창은 최대 20초, 창이 더 필요한 경우 추가로 최대 4초.
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

    // MARK: - 물어보기

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
