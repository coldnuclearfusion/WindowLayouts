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
        Form {
            Section("시작") {
                Toggle("로그인할 때 자동으로 실행", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        guard !syncingToggle else { return }
                        setLaunchAtLogin(on)
                    }
                if loginStatus == .requiresApproval {
                    HStack {
                        Text("시스템 설정 › 일반 › 로그인 항목에서 허용해야 합니다.")
                            .foregroundStyle(.secondary)
                        Button("로그인 항목 열기") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                if let loginError {
                    Text(loginError).foregroundStyle(.red).font(.caption)
                }
                Text("앱을 /Applications 에 두고 켜는 것을 권장합니다. 앱 위치를 옮기면 다시 켜야 합니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("권한") {
                let trusted = monitor.isTrusted
                HStack {
                    Image(systemName: trusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(trusted ? .green : .orange)
                    Text(trusted
                         ? "손쉬운 사용 권한이 허용되어 있습니다."
                         : "창을 읽고 옮기려면 손쉬운 사용 권한이 필요합니다.")
                    Spacer()
                    if !trusted {
                        Button("시스템 설정 열기") {
                            Accessibility.promptIfNeeded()
                            Accessibility.openSystemSettings()
                        }
                    }
                }
                if !trusted {
                    Text("시스템 설정에서 스위치가 이미 켜져 있는데도 이 메시지가 보이면, 목록에서 WindowLayouts를 선택해 −로 지운 뒤 다시 추가하세요. 앱을 다시 빌드하면 서명이 바뀌어 매번 이렇게 됩니다. 한 번만 하려면 README의 ‘서명’ 항목처럼 로컬 인증서를 만들어 두세요.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("모니터") {
                LabeledContent("현재 구성") { Text(monitor.displayConfig.name) }
                ForEach(monitor.displayConfig.displays) { d in
                    Text("\(d.name)\(d.isMain ? " (주 화면)" : "") · \(d.frame.shortDescription)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("배치는 저장 당시 모니터 구성과 함께 기록됩니다. 메뉴와 목록에서 현재 구성에 맞는 배치가 먼저 나오고, 다른 구성의 배치를 적용하면 창이 있던 모니터를 찾아 위치를 맞춥니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("배치 데이터") {
                LabeledContent("파일") {
                    Text(store.fileURL.path)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
                HStack {
                    Button("파일 열기") { NSWorkspace.shared.open(store.fileURL) }
                    Button("Finder에서 보기") { NSWorkspace.shared.activateFileViewerSelecting([store.fileURL]) }
                    Button("다시 읽기") { store.reload() }
                }
                Text("JSON 파일을 직접 편집해 저장하면 앱이 자동으로 다시 읽습니다. 창 항목의 x, y, width, height, title, titleMatch(auto/title/order), enabled 를 고칠 수 있습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let err = store.loadError {
                    Text(err).foregroundStyle(.red).font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("일반 설정")
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
            loginError = "설정 실패: \(error.localizedDescription)"
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
