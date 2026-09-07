import AppKit
import Observation
import SwiftUI

enum SidebarItem: Hashable {
    case layout(UUID)
    case general
}

struct CaptureRequest: Identifiable {
    let id = UUID()
    var windows: [CapturedWindow]
    /// nil이면 새 배치로 저장, 값이 있으면 그 배치에 창 추가
    var targetLayoutID: UUID?
    var displayConfig: DisplayConfig = .current()
}

@Observable
final class AppState {
    static let shared = AppState()
    var selection: SidebarItem?
    var captureRequest: CaptureRequest?
}

struct MainWindow: View {
    static let windowID = "main"

    @Environment(LayoutStore.self) private var store
    @Environment(AppState.self) private var appState
    @Environment(SystemMonitor.self) private var monitor
    @State private var pendingDelete: WindowLayout?

    var body: some View {
        @Bindable var appState = appState
        NavigationSplitView {
            List(selection: $appState.selection) {
                ForEach(store.groups(current: monitor.displayConfig)) { group in
                    Section {
                        if group.layouts.isEmpty {
                            Text("저장된 배치가 없습니다")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(group.layouts) { layout in
                            layoutRow(layout)
                        }
                        .onMove { from, to in
                            store.move(within: group.layouts.map(\.id), fromOffsets: from, toOffset: to)
                        }
                    } header: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.isCurrent ? "현재 모니터 구성" : "다른 모니터 구성")
                            Text(group.configName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
                Section {
                    Label("일반 설정", systemImage: "gearshape")
                        .tag(SidebarItem.general)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 340)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        appState.captureRequest = CaptureRequest(windows: WindowCapture.currentWindows(), targetLayoutID: nil)
                    } label: {
                        Label("현재 창 배치 저장", systemImage: "plus")
                    }
                    .help("현재 열린 창들을 새 배치로 저장")
                }
            }
        } detail: {
            detailView
        }
        .frame(minWidth: 900, minHeight: 520)
        .sheet(item: $appState.captureRequest) { request in
            CaptureSheet(request: request)
                .environment(store)
                .environment(appState)
        }
        .confirmationDialog(
            "‘\(pendingDelete?.name ?? "")’ 배치를 삭제할까요?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("삭제", role: .destructive) {
                if let layout = pendingDelete {
                    if appState.selection == .layout(layout.id) { appState.selection = nil }
                    store.remove(id: layout.id)
                }
                pendingDelete = nil
            }
            Button("취소", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("이 작업은 되돌릴 수 없습니다.")
        }
    }

    private func layoutRow(_ layout: WindowLayout) -> some View {
        Label(layout.name, systemImage: "macwindow.on.rectangle")
            .tag(SidebarItem.layout(layout.id))
            .contextMenu {
                Button("적용") { Task { await LayoutApplier.shared.apply(layout) } }
                Button("복제") {
                    if let copy = store.duplicate(id: layout.id) {
                        appState.selection = .layout(copy.id)
                    }
                }
                Divider()
                Button("삭제…", role: .destructive) { pendingDelete = layout }
            }
    }

    @ViewBuilder
    private var detailView: some View {
        switch appState.selection {
        case .layout(let id):
            if store.layout(id: id) != nil {
                LayoutDetailView(layoutID: id).id(id)
            } else {
                placeholder
            }
        case .general:
            GeneralSettingsView()
        case nil:
            placeholder
        }
    }

    private var placeholder: some View {
        ContentUnavailableView(
            "배치를 선택하세요",
            systemImage: "macwindow.on.rectangle",
            description: Text("왼쪽 목록에서 배치를 고르거나, + 버튼으로 현재 창 배치를 저장하세요.")
        )
    }
}
