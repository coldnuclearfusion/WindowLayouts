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

    /// windowlayouts://apply?name=배치이름  또는  windowlayouts://apply?id=UUID
    /// 터미널(open "windowlayouts://apply?name=…"), 단축어, 단축키 앱에서 배치를 적용할 때 쓴다.
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
                ApplyLog.write("URL로 요청한 배치를 찾지 못함: \(url.absoluteString)")
                continue
            }
            Task { await LayoutApplier.shared.apply(layout) }
        }
    }
}
