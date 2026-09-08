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
                            Text(L("sidebar.no_layouts"))
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
                            Text(group.isCurrent ? L("sidebar.current_config_header") : L("sidebar.other_config_header"))
                            Text(group.configName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
                Section {
                    Label(L("sidebar.general"), systemImage: "gearshape")
                        .tag(SidebarItem.general)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 340)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        appState.captureRequest = CaptureRequest(windows: WindowCapture.currentWindows(), targetLayoutID: nil)
                    } label: {
                        Label(L("sidebar.save_button"), systemImage: "plus")
                    }
                    .help(L("sidebar.save_tooltip"))
                }
            }
        } detail: {
            detailView
        }
        .navigationTitle(L("app.name"))
        .frame(minWidth: 900, minHeight: 520)
        .sheet(item: $appState.captureRequest) { request in
            CaptureSheet(request: request)
                .environment(store)
                .environment(appState)
        }
        .confirmationDialog(
            L("delete.title", ["name": pendingDelete?.name ?? ""]),
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button(L("delete.confirm"), role: .destructive) {
                if let layout = pendingDelete {
                    if appState.selection == .layout(layout.id) { appState.selection = nil }
                    store.remove(id: layout.id)
                }
                pendingDelete = nil
            }
            Button(L("common.cancel"), role: .cancel) { pendingDelete = nil }
        } message: {
            Text(L("delete.message"))
        }
    }

    private func layoutRow(_ layout: WindowLayout) -> some View {
        Label(layout.name, systemImage: "macwindow.on.rectangle")
            .tag(SidebarItem.layout(layout.id))
            .contextMenu {
                Button(L("context.apply")) { Task { await LayoutApplier.shared.apply(layout) } }
                Button(L("context.duplicate")) {
                    if let copy = store.duplicate(id: layout.id) {
                        appState.selection = .layout(copy.id)
                    }
                }
                Divider()
                Button(L("context.delete"), role: .destructive) { pendingDelete = layout }
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
            L("sidebar.placeholder_title"),
            systemImage: "macwindow.on.rectangle",
            description: Text(L("sidebar.placeholder_body"))
        )
    }
}
