import AppKit
import SwiftUI

/// Sheet for choosing which open windows to put into a layout
struct CaptureSheet: View {
    let request: CaptureRequest

    @Environment(LayoutStore.self) private var store
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var selected = Set<UUID>()
    @AppStorage("saveWindowTitles") private var saveTitles = true
    @AppStorage("saveWindowURLs") private var saveURLs = true

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
            Text(isNewLayout ? L("capture.title_new") : L("capture.title_add"))
                .font(.title2.bold())

            if isNewLayout {
                TextField(L("detail.name_placeholder"), text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            Label(L("capture.config", ["name": request.displayConfig.name]), systemImage: "display")
                .font(.caption)
                .foregroundStyle(.secondary)

            if request.windows.isEmpty {
                emptyView
            } else {
                Text(L("capture.hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle(L("capture.save_titles"), isOn: $saveTitles)
                    .font(.caption)
                Toggle(L("capture.save_urls"), isOn: $saveURLs)
                    .font(.caption)
                List {
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.windows) { w in
                                Toggle(isOn: windowBinding(w.id)) {
                                    HStack(alignment: .top) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(w.title.isEmpty ? L("capture.untitled_window") : w.title)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                            if let url = w.url, saveURLs {
                                                Text(url)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                                    .truncationMode(.middle)
                                            }
                                        }
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
                Button(L("common.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Text(L("capture.selected_count", ["count": String(selected.count)]))
                    .foregroundStyle(.secondary)
                Button(isNewLayout ? L("common.save") : L("common.add")) { save() }
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
                name = L("layout.default_name", ["n": String(store.layouts.count + 1)])
            }
        }
    }

    private var emptyView: some View {
        VStack(spacing: 10) {
            Spacer()
            if Accessibility.isTrusted {
                Text(L("capture.no_windows"))
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                Text(L("capture.need_accessibility"))
                Button(L("capture.allow_in_settings")) {
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

    /// Per-app select all / deselect all. Uses a button instead of a Toggle bound to a computed value,
    /// which used to deselect the whole app when one window was unchecked. Partial selection shows as '−'.
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
        .help(all ? L("capture.deselect_all_app") : L("capture.select_all_app"))
    }

    private func save() {
        let entries = request.windows
            .filter { selected.contains($0.id) }
            .map { $0.makeEntry(includeTitle: saveTitles, includeURL: saveURLs) }
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
