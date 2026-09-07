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
    var notes: [String] = []
    var cancelled = false
    var error: String?

    var headline: String {
        if let error { return error }
        if cancelled { return "‘\(layoutName)’ 적용을 취소했습니다." }
        var s = "‘\(layoutName)’ 적용: \(placed.count)개 창 배치됨"
        if !unmatched.isEmpty { s += ", \(unmatched.count)개 창 못 찾음" }
        if !failed.isEmpty { s += ", \(failed.count)개 실패" }
        return s
    }

    var lines: [String] {
        var l: [String] = notes
        if !launched.isEmpty { l.append("실행함: " + launched.joined(separator: ", ")) }
        if !notRunning.isEmpty { l.append("실행하거나 창을 열지 않아 건너뜀: " + notRunning.joined(separator: ", ")) }
        if !unmatched.isEmpty { l.append("맞는 창을 못 찾음: " + unmatched.joined(separator: ", ")) }
        if !failed.isEmpty { l.append("위치 변경 실패: " + failed.joined(separator: ", ")) }
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

        guard Accessibility.isTrusted else {
            Accessibility.promptIfNeeded()
            report.error = "손쉬운 사용 권한이 없어 창을 옮길 수 없습니다."
            lastReport = report
            return
        }

        let entries = layout.windows.filter(\.enabled)
        let bundleIDs = layout.enabledBundleIDs
        let currentConfig = DisplayConfig.current()
        if let saved = layout.displayConfig, !saved.isIdentical(to: currentConfig) {
            report.notes.append("저장 당시 모니터 구성(\(saved.name))과 지금(\(currentConfig.name))이 달라 창 위치를 현재 화면에 맞춰 옮겼습니다.")
        }
        let missing = bundleIDs.filter { runningApps(bundleID: $0).isEmpty }
        // 프로세스는 살아 있지만 창이 하나도 없는 앱 (창을 다 닫아도 앱은 남아 있는 macOS 특성)
        let windowless = bundleIDs.filter { id in
            !missing.contains(id) && runningApps(bundleID: id).allSatisfy { AX.windows(for: $0).isEmpty }
        }
        let needsOpen = missing + windowless
        var skipped = Set<String>()

        func label(_ bundleID: String) -> String {
            layout.appName(for: bundleID) + (windowless.contains(bundleID) ? " (실행 중이지만 창 없음)" : "")
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
                        report.launched.append(layout.appName(for: bundleID) + (reopen ? " (새 창)" : ""))
                        toWait[bundleID] = entries.filter { $0.bundleID == bundleID }.count
                    } else {
                        report.failed.append("\(layout.appName(for: bundleID)) (앱을 찾을 수 없음)")
                        skipped.insert(bundleID)
                    }
                }
                await waitForWindows(toWait)
            } else {
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
            let windows = apps.flatMap { AX.windows(for: $0) }
            let appEntries = entries.filter { $0.bundleID == bundleID }
            for (entry, window) in WindowMatcher.match(entries: appEntries, windows: windows) {
                guard let window else {
                    report.unmatched.append(entry.displayName)
                    continue
                }
                let frame = Self.targetFrame(for: entry, saved: layout.displayConfig, current: currentConfig)
                if AX.setFrame(window.element, frame) {
                    report.placed.append(entry.displayName)
                    if let app = apps.first(where: { $0.processIdentifier == AX.pid(of: window.element) }) {
                        placedWindows.append((entry, window, app))
                    }
                } else {
                    report.failed.append(entry.displayName)
                }
            }
        }

        // 배치의 창들을 다른 창들 위로 올리기 (표의 위 항목이 가장 앞)
        if layout.raiseWindows && !placedWindows.isEmpty {
            let failures = await raise(placedWindows, order: layout.windows.map(\.id))
            if failures > 0 { report.notes.append("\(failures)개 창은 앞으로 올리지 못했습니다.") }
        }

        LayoutStore.shared.lastAppliedID = layout.id
        lastReport = report
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
        alert.messageText = "실행 중이 아니거나 창이 없는 앱이 있습니다"
        alert.informativeText = "‘\(layoutName)’ 배치에 포함된 다음 앱을 실행하거나 새 창을 열어야 합니다.\n\n"
            + names.map { "• \($0)" }.joined(separator: "\n")
        alert.addButton(withTitle: "실행/창 열고 배치")
        alert.addButton(withTitle: "지금 있는 창만 배치")
        let cancel = alert.addButton(withTitle: "취소")
        cancel.keyEquivalent = "\u{1b}"
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "이 배치에서는 다시 묻지 않기"

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
