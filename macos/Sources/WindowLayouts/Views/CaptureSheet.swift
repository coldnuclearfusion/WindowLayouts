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
    @AppStorage("saveWindowTitles") private var saveTitles = true

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
                Text("포함할 창을 선택하세요. 앱 이름을 누르면 그 앱의 창을 한꺼번에 켜고 끕니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("창 제목도 저장 (같은 앱의 창이 여러 개일 때 구분하는 데 씀. 끄면 순서로만 찾음)", isOn: $saveTitles)
                    .font(.caption)
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
                            groupHeader(group)
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

    /// 앱 단위 전체 선택/해제. 계산값에 묶인 Toggle 대신 버튼을 써서
    /// 창 하나를 해제할 때 앱 전체가 풀리던 문제를 피한다. 일부만 선택된 상태는 '−'로 표시.
    private func groupHeader(_ group: AppGroup) -> some View {
        let count = group.windows.filter { selected.contains($0.id) }.count
        let all = count == group.windows.count
        return Button {
            for w in group.windows {
                if all { selected.remove(w.id) } else { selected.insert(w.id) }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: all ? "checkmark.square.fill" : (count == 0 ? "square" : "minus.square.fill"))
                    .foregroundStyle(count == 0 ? Color.secondary : Color.accentColor)
                Text(group.name).bold()
                Text("\(count)/\(group.windows.count)")
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .help(all ? "이 앱의 창 모두 해제" : "이 앱의 창 모두 선택")
    }

    private func save() {
        let entries = request.windows
            .filter { selected.contains($0.id) }
            .map { $0.makeEntry(includeTitle: saveTitles) }
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
