import AppKit
import SwiftUI

struct MenuContent: View {
    @Environment(LayoutStore.self) private var store
    @Environment(AppState.self) private var appState
    @Environment(SystemMonitor.self) private var monitor
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if !monitor.isTrusted {
            Button("손쉬운 사용 권한이 필요합니다…") {
                Accessibility.promptIfNeeded()
                Accessibility.openSystemSettings()
            }
            Divider()
        }

        let groups = store.groups(current: monitor.displayConfig)
        ForEach(groups) { group in
            if group.isCurrent {
                Section("현재 모니터 구성: \(group.configName)") {
                    if group.layouts.isEmpty {
                        Text("이 구성에 저장된 배치가 없습니다")
                    }
                    ForEach(group.layouts) { layout in
                        layoutButton(layout)
                    }
                }
            } else {
                Menu("다른 구성: \(group.configName)") {
                    ForEach(group.layouts) { layout in
                        layoutButton(layout)
                    }
                }
            }
        }

        Divider()

        Button("현재 창 배치 저장…") {
            // 메뉴를 누른 그 순간의 창 상태를 먼저 찍어 두고, 그다음 창을 연다
            appState.captureRequest = CaptureRequest(windows: WindowCapture.currentWindows(), targetLayoutID: nil)
            showMainWindow()
        }
        Button("상세 설정…") {
            showMainWindow()
        }

        Divider()

        Button("종료") {
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
