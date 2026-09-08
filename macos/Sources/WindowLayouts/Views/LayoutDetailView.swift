import AppKit
import SwiftUI

struct LayoutDetailView: View {
    @Environment(LayoutStore.self) private var store
    @Environment(AppState.self) private var appState
    @Environment(SystemMonitor.self) private var monitor
    let layoutID: UUID

    @State private var selection = Set<UUID>()
    @State private var refreshMessage: String?
    private var applier: LayoutApplier { LayoutApplier.shared }

    private var layout: WindowLayout {
        store.layout(id: layoutID) ?? WindowLayout(name: "")
    }

    private var layoutBinding: Binding<WindowLayout> {
        store.binding(for: layoutID)
    }

    private func entry(_ id: UUID) -> Binding<WindowEntry> {
        store.entryBinding(layoutID: layoutID, entryID: id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                TextField("배치 이름", text: layoutBinding.name)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3)
                Button {
                    Task { await applier.apply(layout) }
                } label: {
                    Label("지금 적용", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(applier.isApplying || layout.windows.isEmpty)
            }

            HStack {
                Picker("실행 중이 아니거나 창이 없는 앱이 있을 때:", selection: layoutBinding.launchPolicy) {
                    ForEach(LaunchPolicy.allCases) { policy in
                        Text(policy.label).tag(policy)
                    }
                }
                .fixedSize()
                Spacer()
            }

            Toggle("적용할 때 이 창들을 다른 창들 위로 올리기 (표의 위 항목이 가장 앞)", isOn: layoutBinding.raiseWindows)

            displayConfigRow

            Table(layout.windows, selection: $selection) {
                TableColumn("") { row in
                    Toggle("", isOn: entry(row.id).enabled).labelsHidden()
                }
                .width(24)

                TableColumn("앱") { row in
                    Text(row.appName)
                        .foregroundStyle(row.enabled ? .primary : .secondary)
                }
                .width(min: 90, ideal: 120)

                TableColumn("창 제목 (찾을 때 사용)") { row in
                    TextField("", text: entry(row.id).title)
                        .textFieldStyle(.plain)
                }
                .width(min: 150, ideal: 240)

                TableColumn("페이지 주소 (브라우저)") { row in
                    TextField("", text: urlBinding(row.id))
                        .textFieldStyle(.plain)
                        .disabled(!BrowserSupport.isBrowser(row.bundleID))
                        .help(BrowserSupport.isBrowser(row.bundleID)
                              ? "이 주소의 탭이 있는 창을 이 자리에 두고, 없으면 새 창으로 엽니다"
                              : "브라우저 창에만 씁니다")
                }
                .width(min: 120, ideal: 200)

                TableColumn("찾기") { row in
                    Picker("", selection: entry(row.id).titleMatch) {
                        ForEach(TitleMatch.allCases) { m in
                            Text(m.label).tag(m)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                }
                .width(min: 70, ideal: 80)

                TableColumn("모니터") { row in
                    Text(layout.displayConfig?.display(withID: row.displayID)?.name ?? "–")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .width(min: 70, ideal: 110)

                TableColumn("X") { row in numberField(entry(row.id).x) }.width(min: 50, ideal: 60)
                TableColumn("Y") { row in numberField(entry(row.id).y) }.width(min: 50, ideal: 60)
                TableColumn("너비") { row in numberField(entry(row.id).width) }.width(min: 50, ideal: 60)
                TableColumn("높이") { row in numberField(entry(row.id).height) }.width(min: 50, ideal: 60)
            }

            HStack(spacing: 10) {
                Button {
                    appState.captureRequest = CaptureRequest(windows: WindowCapture.currentWindows(), targetLayoutID: layoutID)
                } label: {
                    Label("현재 열린 창 추가…", systemImage: "plus")
                }
                Button {
                    let result = applier.refreshedFrames(layout)
                    store.replace(result.layout)
                    refreshMessage = "\(result.updated)개 창의 위치를 현재 상태로 갱신하고, 모니터 구성을 현재 것으로 바꿨습니다."
                } label: {
                    Label("현재 위치로 갱신", systemImage: "arrow.clockwise")
                }
                .help("저장된 창들을 지금 열린 창에서 찾아 위치와 크기를 다시 읽습니다")
                Button(role: .destructive) {
                    store.removeEntries(selection, from: layoutID)
                    selection.removeAll()
                } label: {
                    Label("선택 삭제", systemImage: "trash")
                }
                .disabled(selection.isEmpty)
                Button {
                    if let id = selection.first { store.moveEntry(id, by: -1, in: layoutID) }
                } label: {
                    Image(systemName: "chevron.up")
                }
                .help("선택한 창을 한 칸 앞으로")
                .disabled(selection.count != 1)
                Button {
                    if let id = selection.first { store.moveEntry(id, by: 1, in: layoutID) }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .help("선택한 창을 한 칸 뒤로")
                .disabled(selection.count != 1)
                Spacer()
                Text("\(layout.windows.count)개 창 · 좌표는 주 화면 왼쪽 위가 (0, 0)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let refreshMessage {
                Text(refreshMessage).font(.caption).foregroundStyle(.secondary)
            }

            if let report = applier.lastReport, report.layoutID == layoutID {
                ReportView(report: report)
            }
        }
        .padding(16)
        .navigationTitle(layout.name)
    }

    private var displayConfigRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "display")
                .foregroundStyle(.secondary)
            if let saved = layout.displayConfig {
                Text("모니터 구성: \(saved.name)")
                if saved.isIdentical(to: monitor.displayConfig) {
                    Text("현재와 같음")
                        .foregroundStyle(.secondary)
                } else if saved.hasSameDisplays(as: monitor.displayConfig) {
                    Text("같은 모니터지만 배열이 달라, 적용할 때 위치를 맞춥니다")
                        .foregroundStyle(.orange)
                } else {
                    Text("현재 구성과 달라, 적용할 때 창이 있던 모니터를 찾아 위치를 맞춥니다")
                        .foregroundStyle(.orange)
                }
            } else {
                Text("모니터 구성: 무관 (모든 구성에서 표시, 좌표 그대로 적용)")
            }
            Spacer()
            Menu("변경") {
                Button("현재 모니터 구성으로 지정") {
                    store.setDisplayConfig(monitor.displayConfig, for: layoutID)
                }
                Button("구성 무관으로 지정") {
                    store.setDisplayConfig(nil, for: layoutID)
                }
            }
            .fixedSize()
        }
        .font(.callout)
    }

    private func urlBinding(_ id: UUID) -> Binding<String> {
        let e = entry(id)
        return Binding(
            get: { e.wrappedValue.url ?? "" },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                e.wrappedValue.url = trimmed.isEmpty ? nil : trimmed
            }
        )
    }

    private func numberField(_ value: Binding<Double>) -> some View {
        TextField("", value: value, format: .number.precision(.fractionLength(0)))
            .textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
    }
}

struct ReportView: View {
    let report: ApplyReport

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(report.headline).bold()
            ForEach(report.lines, id: \.self) { line in
                Text(line).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}
