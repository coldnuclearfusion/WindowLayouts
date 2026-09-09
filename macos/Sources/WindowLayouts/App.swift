import AppKit
import ApplicationServices
import SwiftUI

@main
struct WindowLayoutsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let store = LayoutStore.shared
    private let appState = AppState.shared
    private let monitor = SystemMonitor.shared

    var body: some Scene {
        // Menu bar presence (requirements 4, 5)
        MenuBarExtra {
            MenuContent()
                .environment(store)
                .environment(appState)
                .environment(monitor)
        } label: {
            Image(systemName: "macwindow.on.rectangle")
        }
        .menuBarExtraStyle(.menu)

        // Settings window. Opens automatically only on the first launch, when no layouts are saved yet.
        Window("WindowLayouts", id: MainWindow.windowID) {
            MainWindow()
                .environment(store)
                .environment(appState)
                .environment(monitor)
        }
        .defaultSize(width: 980, height: 620)
        .defaultLaunchBehavior(store.layouts.isEmpty ? .presented : .suppressed)
        .restorationBehavior(.disabled)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let defaults = UserDefaults.standard
        if !Accessibility.isTrusted && !defaults.bool(forKey: "didPromptAccessibility") {
            defaults.set(true, forKey: "didPromptAccessibility")
            Accessibility.promptIfNeeded()
        }
        if LayoutStore.shared.layouts.isEmpty {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// windowlayouts://apply?name=<layout name>  or  windowlayouts://apply?id=<UUID>
    /// Used to apply a layout from a terminal (open "windowlayouts://apply?name=…"), Shortcuts, or a hotkey app.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard url.scheme?.lowercased() == "windowlayouts", url.host?.lowercased() == "apply" else { continue }
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let name = items.first { $0.name == "name" }?.value
            let id = items.first { $0.name == "id" }?.value
            let store = LayoutStore.shared
            guard let layout = store.layouts.first(where: {
                ($0.id.uuidString.caseInsensitiveCompare(id ?? "") == .orderedSame) || (name != nil && $0.name == name)
            }) else {
                ApplyLog.write(L("log.url_not_found", ["url": url.absoluteString]))
                continue
            }
            Task { await LayoutApplier.shared.apply(layout) }
        }
    }
}
