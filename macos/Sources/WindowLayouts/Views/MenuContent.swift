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
                        layoutItem(layout)
                    }
                }
            } else {
                Menu(L("menu.other_config", ["name": group.configName])) {
                    ForEach(group.layouts) { layout in
                        layoutItem(layout)
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

    /// The layout applied last gets the menu's own check mark. A Toggle is what SwiftUI turns into a menu item with
    /// that state; a Label with a "checkmark" image only became the item's icon, which the menu did not show as a check.
    /// Choosing an item always applies the layout, the checked one included (that puts its windows back in place).
    private func layoutItem(_ layout: WindowLayout) -> some View {
        Toggle(layout.name, isOn: Binding(
            get: { store.lastAppliedID == layout.id },
            set: { _ in Task { await LayoutApplier.shared.apply(layout) } }
        ))
        .disabled(LayoutApplier.shared.isApplying)
    }

    private func showMainWindow() {
        openWindow(id: MainWindow.windowID)
        NSApp.activate(ignoringOtherApps: true)
    }
}
