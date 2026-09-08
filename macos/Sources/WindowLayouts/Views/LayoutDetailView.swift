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
                TextField(L("detail.name_placeholder"), text: layoutBinding.name)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3)
                Button {
                    Task { await applier.apply(layout) }
                } label: {
                    Label(L("detail.apply_now"), systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(applier.isApplying || layout.windows.isEmpty)
            }

            HStack {
                Picker(L("detail.policy_label"), selection: layoutBinding.launchPolicy) {
                    ForEach(LaunchPolicy.allCases) { policy in
                        Text(policy.label).tag(policy)
                    }
                }
                .fixedSize()
                Spacer()
            }

            Toggle(L("detail.raise"), isOn: layoutBinding.raiseWindows)

            displayConfigRow

            Table(layout.windows, selection: $selection) {
                TableColumn("") { row in
                    Toggle("", isOn: entry(row.id).enabled).labelsHidden()
                }
                .width(24)

                TableColumn(L("column.app")) { row in
                    Text(row.appName)
                        .foregroundStyle(row.enabled ? .primary : .secondary)
                }
                .width(min: 90, ideal: 120)

                TableColumn(L("column.title")) { row in
                    TextField("", text: entry(row.id).title)
                        .textFieldStyle(.plain)
                }
                .width(min: 150, ideal: 240)

                TableColumn(L("column.url")) { row in
                    TextField("", text: urlBinding(row.id))
                        .textFieldStyle(.plain)
                        .disabled(!BrowserSupport.isBrowser(row.bundleID))
                        .help(BrowserSupport.isBrowser(row.bundleID) ? L("column.url_help_browser") : L("column.url_help_other"))
                }
                .width(min: 120, ideal: 200)

                TableColumn(L("column.match")) { row in
                    Picker("", selection: entry(row.id).titleMatch) {
                        ForEach(TitleMatch.allCases) { m in
                            Text(m.label).tag(m)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                }
                .width(min: 70, ideal: 80)

                TableColumn(L("column.monitor")) { row in
                    Text(layout.displayConfig?.display(withID: row.displayID)?.name ?? "–")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .width(min: 70, ideal: 110)

                TableColumn(L("column.x")) { row in numberField(entry(row.id).x) }.width(min: 50, ideal: 60)
                TableColumn(L("column.y")) { row in numberField(entry(row.id).y) }.width(min: 50, ideal: 60)
                TableColumn(L("column.width")) { row in numberField(entry(row.id).width) }.width(min: 50, ideal: 60)
                TableColumn(L("column.height")) { row in numberField(entry(row.id).height) }.width(min: 50, ideal: 60)
            }

            HStack(spacing: 10) {
                Button {
                    appState.captureRequest = CaptureRequest(windows: WindowCapture.currentWindows(), targetLayoutID: layoutID)
                } label: {
                    Label(L("detail.add_windows"), systemImage: "plus")
                }
                Button {
                    let result = applier.refreshedFrames(layout)
                    store.replace(result.layout)
                    refreshMessage = L("detail.refreshed", ["count": String(result.updated)])
                } label: {
                    Label(L("detail.refresh"), systemImage: "arrow.clockwise")
                }
                .help(L("detail.refresh_help"))
                Button(role: .destructive) {
                    store.removeEntries(selection, from: layoutID)
                    selection.removeAll()
                } label: {
                    Label(L("detail.delete_selected"), systemImage: "trash")
                }
                .disabled(selection.isEmpty)
                Button {
                    if let id = selection.first { store.moveEntry(id, by: -1, in: layoutID) }
                } label: {
                    Image(systemName: "chevron.up")
                }
                .help(L("detail.move_up_help"))
                .disabled(selection.count != 1)
                Button {
                    if let id = selection.first { store.moveEntry(id, by: 1, in: layoutID) }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .help(L("detail.move_down_help"))
                .disabled(selection.count != 1)
                Spacer()
                Text(L("detail.count", ["count": String(layout.windows.count)]))
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
                Text(L("display.config", ["name": saved.name]))
                if saved.isIdentical(to: monitor.displayConfig) {
                    Text(L("display.same"))
                        .foregroundStyle(.secondary)
                } else if saved.hasSameDisplays(as: monitor.displayConfig) {
                    Text(L("display.rearranged"))
                        .foregroundStyle(.orange)
                } else {
                    Text(L("display.different"))
                        .foregroundStyle(.orange)
                }
            } else {
                Text(L("display.any"))
            }
            Spacer()
            Menu(L("common.change")) {
                Button(L("display.set_current")) {
                    store.setDisplayConfig(monitor.displayConfig, for: layoutID)
                }
                Button(L("display.set_any")) {
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
