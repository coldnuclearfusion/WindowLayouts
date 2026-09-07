import AppKit
import SwiftUI

/// 현재 열린 창 중 어떤 것을 배치에 넣을지 고르는 시트 (요구사항 7, 8)
struct CaptureSheet: View {
    let request: CaptureRequest

    @Environment(LayoutStore.self) private var store
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var selected = Set<UUID>()

    private var isNewLayout: Bool { request.targetLayoutID == nil }

    private struct AppGroup: Identifiable {
        let id: String
        let name: String
        let windows: [CapturedWindow]
    }

    private var groups: [AppGroup] {
        var order: [String] = []
        var byApp: [String: [CapturedWindow]] = [:]
        for w in request.windows {
            if byApp[w.bundleID] == nil {
                order.append(w.bundleID)
                byApp[w.bundleID] = []
            }
            byApp[w.bundleID]!.append(w)
        }
        return order.map { AppGroup(id: $0, name: byApp[$0]!.first!.appName, windows: byApp[$0]!) }
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var saveDisabled: Bool {
        selected.isEmpty || (isNewLayout && trimmedName.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNewLayout ? "현재 창 배치 저장" : "현재 열린 창 추가")
                .font(.title2.bold())

            if isNewLayout {
                TextField("배치 이름", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            Label("모니터 구성: \(request.displayConfig.name)", systemImage: "display")
                .font(.caption)
                .foregroundStyle(.secondary)

            if request.windows.isEmpty {
                emptyView
            } else {
                Text("포함할 창을 선택하세요. 앱 이름 옆 체크로 그 앱의 창을 한꺼번에 켜고 끌 수 있습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                List {
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.windows) { w in
                                Toggle(isOn: windowBinding(w.id)) {
                                    HStack {
                                        Text(w.title.isEmpty ? "(제목 없음)" : w.title)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Spacer()
                                        Text(w.frame.shortDescription)
                                            .foregroundStyle(.secondary)
                                            .monospacedDigit()
                                    }
                                }
                            }
                        } header: {
                            Toggle(isOn: groupBinding(group)) {
                                Text(group.name).bold()
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }

            HStack {
                Button("취소") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Text("\(selected.count)개 창 선택됨")
                    .foregroundStyle(.secondary)
                Button(isNewLayout ? "저장" : "추가") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(saveDisabled)
            }
        }
        .padding(20)
        .frame(minWidth: 580, idealWidth: 640, minHeight: 440, idealHeight: 540)
        .onAppear {
            selected = Set(request.windows.map(\.id))
            if isNewLayout {
                name = "배치 \(store.layouts.count + 1)"
            }
        }
    }

    private var emptyView: some View {
        VStack(spacing: 10) {
            Spacer()
            if Accessibility.isTrusted {
                Text("열려 있는 창을 찾지 못했습니다.")
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                Text("창 목록을 읽으려면 손쉬운 사용 권한이 필요합니다.")
                Button("시스템 설정에서 허용하기") {
                    Accessibility.promptIfNeeded()
                    Accessibility.openSystemSettings()
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func windowBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { selected.contains(id) },
            set: { on in if on { selected.insert(id) } else { selected.remove(id) } }
        )
    }

    private func groupBinding(_ group: AppGroup) -> Binding<Bool> {
        Binding(
            get: { group.windows.allSatisfy { selected.contains($0.id) } },
            set: { on in
                for w in group.windows {
                    if on { selected.insert(w.id) } else { selected.remove(w.id) }
                }
            }
        )
    }

    private func save() {
        let entries = request.windows
            .filter { selected.contains($0.id) }
            .map { $0.makeEntry() }
        if let target = request.targetLayoutID {
            store.append(entries, to: target)
        } else {
            let layout = WindowLayout(name: trimmedName, windows: entries, displayConfig: request.displayConfig)
            store.add(layout)
            appState.selection = .layout(layout.id)
        }
        dismiss()
    }
}
