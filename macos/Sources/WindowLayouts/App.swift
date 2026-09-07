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
        // 메뉴 바 상주 (요구사항 4, 5)
        MenuBarExtra {
            MenuContent()
                .environment(store)
                .environment(appState)
                .environment(monitor)
        } label: {
            Image(systemName: "macwindow.on.rectangle")
        }
        .menuBarExtraStyle(.menu)

        // 상세 설정 창. 저장된 배치가 하나도 없는 첫 실행에만 자동으로 열린다.
        Window("창 배치", id: MainWindow.windowID) {
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
}
