import AppKit
import Combine
import ServiceManagement
import SwiftUI

struct GeneralSettingsView: View {
    @Environment(LayoutStore.self) private var store
    @Environment(SystemMonitor.self) private var monitor

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginError: String?
    @State private var syncingToggle = false

    private let ticker = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        @Bindable var l10n = L10n.shared
        Form {
            Section(L("general.language")) {
                Picker(L("general.language"), selection: $l10n.setting) {
                    Text(L("general.language_system")).tag(L10n.systemOption)
                    ForEach(l10n.languages, id: \.code) { lang in
                        Text(lang.name).tag(lang.code)
                    }
                }
                Text(L("general.language_note"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L("general.startup")) {
                Toggle(L("general.launch_at_login"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        guard !syncingToggle else { return }
                        setLaunchAtLogin(on)
                    }
                if loginStatus == .requiresApproval {
                    HStack {
                        Text(L("general.login_needs_approval"))
                            .foregroundStyle(.secondary)
                        Button(L("general.open_login_items")) { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                if let loginError {
                    Text(loginError).foregroundStyle(.red).font(.caption)
                }
                Text(L("general.app_location_hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L("general.permission")) {
                let trusted = monitor.isTrusted
                HStack {
                    Image(systemName: trusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(trusted ? .green : .orange)
                    Text(trusted ? L("general.accessibility_ok") : L("general.accessibility_needed"))
                    Spacer()
                    if !trusted {
                        Button(L("general.open_system_settings")) {
                            Accessibility.promptIfNeeded()
                            Accessibility.openSystemSettings()
                        }
                    }
                }
                if !trusted {
                    Text(L("general.accessibility_stale_hint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section(L("general.monitors")) {
                LabeledContent(L("general.current_config")) { Text(monitor.displayConfig.name) }
                ForEach(monitor.displayConfig.displays) { d in
                    Text("\(d.name)\(d.isMain ? L("display.main_suffix") : "") · \(d.frame.shortDescription)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(L("general.monitors_note"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L("general.data")) {
                LabeledContent(L("general.file")) {
                    Text(store.fileURL.path)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
                HStack {
                    Button(L("general.open_file")) { NSWorkspace.shared.open(store.fileURL) }
                    Button(L("general.reveal_file")) { NSWorkspace.shared.activateFileViewerSelecting([store.fileURL]) }
                    Button(L("general.reload")) { store.reload() }
                    Button(L("general.open_log")) { NSWorkspace.shared.open(ApplyLog.url) }
                }
                Text(L("general.cli_hint", ["command": "open \"windowlayouts://apply?name=NAME\""]))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(L("general.json_hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let err = store.loadError {
                    Text(err).foregroundStyle(.red).font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(L("sidebar.general"))
        .onReceive(ticker) { _ in
            loginStatus = SMAppService.mainApp.status
            let enabled = loginStatus == .enabled
            if enabled != launchAtLogin {
                syncingToggle = true
                launchAtLogin = enabled
                syncingToggle = false
            }
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
        } catch {
            loginError = L("general.login_error", ["error": error.localizedDescription])
        }
        loginStatus = SMAppService.mainApp.status
        let enabled = loginStatus == .enabled
        if enabled != launchAtLogin {
            syncingToggle = true
            launchAtLogin = enabled
            syncingToggle = false
        }
    }
}
