import AppKit
import SwiftUI

struct MenuContent: View {
    @Environment(LayoutStore.self) private var store
    @Environment(AppState.self) private var appState
    @Environment(SystemMonitor.self) private var monitor
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if !monitor.isTrusted {
            Button(L("menu.need_accessibility")) {
                Accessibility.promptIfNeeded()
                Accessibility.openSystemSettings()
            }
            Divider()
        }

        let groups = store.groups(current: monitor.displayConfig)
        ForEach(groups) { group in
            if group.isCurrent {
                Section(L("menu.current_config", ["name": group.configName])) {
                    if group.layouts.isEmpty {
                        Text(L("menu.no_layouts_in_config"))
                    }
                    ForEach(group.layouts) { layout in
                        layoutButton(layout)
                    }
                }
            } else {
                Menu(L("menu.other_config", ["name": group.configName])) {
                    ForEach(group.layouts) { layout in
                        layoutButton(layout)
                    }
                }
            }
        }

        Divider()

        Button(L("menu.save_current")) {
            // Capture the window state at the moment the menu was clicked, then open the window
            appState.captureRequest = CaptureRequest(windows: WindowCapture.currentWindows(), targetLayoutID: nil)
            showMainWindow()
        }
        Button(L("menu.settings")) {
            showMainWindow()
        }

        Divider()

        Button(L("menu.quit")) {
            NSApp.terminate(nil)
        }
    }

    private func layoutButton(_ layout: WindowLayout) -> some View {
        Button {
            Task { await LayoutApplier.shared.apply(layout) }
        } label: {
            if store.lastAppliedID == layout.id {
                Label(layout.name, systemImage: "checkmark")
            } else {
                Text(layout.name)
            }
        }
        .disabled(LayoutApplier.shared.isApplying)
    }

    private func showMainWindow() {
        openWindow(id: MainWindow.windowID)
        NSApp.activate(ignoringOtherApps: true)
    }
}
