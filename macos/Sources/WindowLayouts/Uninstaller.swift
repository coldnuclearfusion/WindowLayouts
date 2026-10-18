import AppKit
import ServiceManagement

/// Removing WindowLayouts from this Mac (General › Remove). The app is not sandboxed, so it moves its own files itself.
/// Everything goes to the Trash; nothing is deleted outright.
/// - Clean up: settings and caches of older versions, i.e. of identifiers ending in ".WindowLayouts" other than this one.
/// - Uninstall: turns off launch at login and resets the app's privacy permissions (Accessibility, Automation), then
///   moves its settings, the saved layouts and apply log (unless the user keeps them) and the app itself to the Trash.
/// `open "windowlayouts://check-uninstall"` writes both plans to the apply log without moving anything.
enum Uninstaller {
    enum Mode { case uninstall, leftovers }

    struct Plan {
        /// Settings and caches
        var items: [URL] = []
        /// ~/Library/Application Support/WindowLayouts: the saved layouts and the apply log (uninstall only)
        var dataFolder: URL?
        /// The app bundle, moved last (uninstall only)
        var app: URL?

        var all: [URL] { items + (dataFolder.map { [$0] } ?? []) + (app.map { [$0] } ?? []) }
    }

    /// Identifiers of this app: the current one and those of older versions all end in ".WindowLayouts"
    static func isFamily(_ identifier: String) -> Bool {
        let parts = identifier.split(separator: ".")
        return parts.count >= 2 && parts.last == "WindowLayouts"
    }

    static func makePlan(_ mode: Mode) -> Plan {
        let fm = FileManager.default
        let library = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        let current = Bundle.main.bundleIdentifier ?? ""
        func wanted(_ identifier: String) -> Bool {
            isFamily(identifier) && (mode == .uninstall || identifier != current)
        }
        func entries(_ folder: String) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: library.appendingPathComponent(folder).path)) ?? []).sorted()
        }

        var plan = Plan()
        for name in entries("Preferences") where name.hasSuffix(".plist") && wanted(String(name.dropLast(6))) {
            plan.items.append(library.appendingPathComponent("Preferences/\(name)"))
        }
        for folder in ["Caches", "HTTPStorages", "WebKit"] {
            for name in entries(folder) where wanted(name) {
                plan.items.append(library.appendingPathComponent("\(folder)/\(name)"))
            }
        }
        for name in entries("Saved Application State") where name.hasSuffix(".savedState")
            && wanted(String(name.dropLast(11))) {
            plan.items.append(library.appendingPathComponent("Saved Application State/\(name)"))
        }
        if mode == .uninstall {
            let data = LayoutStore.shared.directoryURL
            if fm.fileExists(atPath: data.path) { plan.dataFolder = data }
            plan.app = Bundle.main.bundleURL
        }
        return plan
    }

    // MARK: - Running

    @MainActor
    static func run(_ mode: Mode) {
        let plan = makePlan(mode)
        let appName = L("app.name")
        if mode == .leftovers && plan.items.isEmpty {
            alert(L("remove.cleanup_nothing"), "", buttons: [L("common.ok")])
            return
        }

        let confirm = NSAlert()
        switch mode {
        case .uninstall:
            confirm.messageText = L("remove.uninstall_title", ["app": appName])
            confirm.informativeText = L("remove.uninstall_body", ["count": String(plan.all.count)]) + "\n\n" + listing(plan.all)
            confirm.alertStyle = .critical
            confirm.addButton(withTitle: L("remove.uninstall_confirm"))
            if plan.dataFolder != nil {
                confirm.showsSuppressionButton = true
                confirm.suppressionButton?.title = L("remove.keep_layouts")
                confirm.suppressionButton?.state = .off
            }
        case .leftovers:
            confirm.messageText = L("remove.cleanup_title")
            confirm.informativeText = L("remove.cleanup_body", ["count": String(plan.items.count)]) + "\n\n" + listing(plan.items)
            confirm.addButton(withTitle: L("remove.cleanup_confirm"))
        }
        confirm.addButton(withTitle: L("common.cancel")).keyEquivalent = "\u{1b}"
        NSApp.activate(ignoringOtherApps: true)
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        let keepData = confirm.suppressionButton?.state == .on

        var targets = plan.items
        var permissionsReset = true
        if mode == .uninstall {
            PlacementWatcher.shared.stop()
            try? SMAppService.mainApp.unregister()
            permissionsReset = resetPermissions()
            if let data = plan.dataFolder, !keepData { targets.append(data) }
            if let app = plan.app { targets.append(app) }
        }
        var moved = 0
        var failed: [String] = []
        for url in targets {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                moved += 1
            } catch {
                failed.append(shortPath(url))
            }
        }
        if mode == .uninstall, let identifier = Bundle.main.bundleIdentifier {
            // The settings file is in the Trash; drop what the preferences daemon still holds so it is not written back
            UserDefaults.standard.removePersistentDomain(forName: identifier)
        }

        var report = L("remove.done_body", ["count": String(moved)])
        if !failed.isEmpty { report += "\n\n" + L("remove.done_failed", ["list": failed.joined(separator: "\n")]) }
        if !permissionsReset { report += "\n\n" + L("remove.done_permissions", ["app": appName]) }
        if mode == .uninstall { report += "\n\n" + L("remove.done_quit") }
        alert(L("remove.done_title"), report, buttons: [L("common.ok")])
        if mode == .uninstall { NSApp.terminate(nil) }
    }

    /// Removes this app's entries from the privacy settings (Accessibility, Automation and the rest) with tccutil
    private static func resetPermissions() -> Bool {
        guard let identifier = Bundle.main.bundleIdentifier else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "All", identifier]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    // MARK: - Preview and helpers

    /// Read-only: both plans, written to the apply log
    static func logPreview() {
        for (mode, name) in [(Mode.leftovers, L("log.remove_mode_cleanup")), (Mode.uninstall, L("log.remove_mode_uninstall"))] {
            ApplyLog.write(L("log.remove_preview", ["mode": name]))
            for url in makePlan(mode).all {
                ApplyLog.write(L("log.remove_item", ["path": shortPath(url)]))
            }
        }
    }

    @discardableResult
    @MainActor
    private static func alert(_ title: String, _ text: String, buttons: [String]) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        buttons.forEach { alert.addButton(withTitle: $0) }
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal()
    }

    private static func listing(_ items: [URL]) -> String {
        let shown = items.prefix(12).map { "• " + shortPath($0) }
        let rest = items.count - shown.count
        return (shown + (rest > 0 ? [L("remove.more", ["count": String(rest)])] : [])).joined(separator: "\n")
    }

    static func shortPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    }
}
