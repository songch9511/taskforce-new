#if os(macOS)
import AppKit
import SwiftUI
import TaskforceKit
import TaskforceUI

// Settings › Execution · Reports · Shortcuts. 지금 실제로 있는 것만 보인다:
// - Execution: Run with AI를 이 계정이 쓸 수 있는지 (기존 `GET /credits` 200 · 404). 정책 · 외부 비용은 데이터가 없어 넣지 않는다
// - Reports: 이 Mac의 알림 권한 (읽기 전용, 꺼져 있으면 시스템 설정으로). 보고 설정(H2)은 저장 · 보내는 곳이 아직 없다
// - Shortcuts: 기존 전역 단축키 기록(런처 · 설정 창) + Edge 패널에서 지금 동작하는 키

/// Execution › Run with AI: 이 계정에서 쓸 수 있는지 (읽기 전용). 값은 `RunStore.credits`가 정한다
struct SettingsRunWithAISection: View {
    @Environment(RunStore.self) private var runs

    static let footnote = "Run with AI writes a draft only when you start it on a task. Settings for work that runs without asking come in a later update."

    var body: some View {
        SettingsSection("Run with AI", footnote: Self.footnote) {
            SettingsTrayRow("On this account") {
                SettingsValue(Self.availability(runs.credits, failed: runs.creditsFailed))
            }
        }
    }

    /// 모름은 모름으로 쓴다 (읽는 중 · 읽기 실패를 "Not available"로 쓰지 않는다)
    static func availability(_ credits: RunStore.Credits, failed: Bool) -> String {
        switch credits {
        case .available: "Available"
        case .unavailable: "Not available"
        case .unknown: failed ? "Couldn't check" : "Checking…"
        }
    }
}

/// Reports › Notifications: 이 Mac의 알림 권한. 꺼져 있으면 시스템 설정(밖, ↗)을 연다
struct SettingsNotificationsSection: View {
    @State private var status: PushPermission.Status?

    static let footnote = "Daily report settings come in a later update."
    /// 시스템 설정 › 알림
    static let systemSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!

    var body: some View {
        SettingsSection("Notifications", footnote: Self.footnote) {
            SettingsTrayRow("On this Mac") {
                SettingsValue(Self.permission(status))
            }
            if status == .denied {
                SettingsTrayRow("Notification settings", external: true, onOpen: {
                    NSWorkspace.shared.open(Self.systemSettingsURL)
                })
            }
        }
        .task { status = await PushCenter.status() }
        // 시스템 설정에서 바꾸고 돌아오면 다시 읽는다
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { status = await PushCenter.status() }
        }
    }

    static func permission(_ status: PushPermission.Status?) -> String {
        switch status {
        case nil: "Checking…"
        case .allowed?: "Allowed"
        case .denied?: "Off"
        case .notDetermined?: "Not asked yet"
        }
    }
}

/// Shortcuts › Launcher: 전역 단축키 둘 (기존 Keyboard Shortcuts와 같은 기록 · 등록, `HotKeyRecorder`).
/// 칸을 누르고 단축키를 누른다(Esc 취소). Reset은 기본값과 다를 때만: 런처는 ⌥Space로, 설정 창은 없음으로. 오류는 그 행 아래
struct SettingsLauncherShortcutsSection: View {
    @State private var recorder = HotKeyRecorder()

    var body: some View {
        SettingsSection("Launcher", footnote: recorder.recording == nil ? HotKeyRecorder.footnote : HotKeyRecorder.recordingFootnote) {
            SettingsTrayRow("Open launcher", message: message(for: .launcher)) {
                HStack(spacing: TFSpace.xxs) {
                    ShortcutRecorder(keys: recorder.launcher.keyCaps, recording: recorder.recording == .launcher) {
                        recorder.toggle(.launcher)
                    }
                    .accessibilityLabel("Open launcher")
                    if !recorder.launcher.matches(.default), recorder.recording != .launcher {
                        TFIconButton(.reset, label: "Reset to default") { recorder.resetLauncher() }
                    }
                    if recorder.launcherUnavailable {
                        Button("Retry") { recorder.retry(.launcher) }
                            .buttonStyle(TFButtonStyle())
                    }
                }
            }
            SettingsTrayRow("Open Settings", message: message(for: .settings)) {
                HStack(spacing: TFSpace.xxs) {
                    ShortcutRecorder(keys: recorder.settings?.keyCaps, recording: recorder.recording == .settings) {
                        recorder.toggle(.settings)
                    }
                    .accessibilityLabel("Open Settings")
                    if recorder.settings != nil, recorder.recording != .settings {
                        TFIconButton(.reset, label: "Reset to default") { recorder.removeSettings() }
                    }
                    if recorder.settingsUnavailable, recorder.settings != nil {
                        Button("Retry") { recorder.retry(.settings) }
                            .buttonStyle(TFButtonStyle())
                    }
                }
            }
        }
        .modifier(HotKeyRecorderLifecycle(recorder: recorder))
    }

    /// 그 단축키의 등록 실패 · 기록 오류 (어느 단축키인지 모르는 오류는 런처 행에)
    private func message(for action: HotKeyShortcut.Action) -> String? {
        var lines: [String] = []
        if action == .launcher, recorder.launcherUnavailable { lines.append(HotKeyRecorder.launcherInactive) }
        if action == .settings, recorder.settingsUnavailable { lines.append(HotKeyRecorder.settingsInactive) }
        if let message = recorder.message, (recorder.messageAction ?? .launcher) == action { lines.append(message) }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

/// Shortcuts › In the panel: Edge 패널에서 지금 동작하는 키 (읽기 전용 KeyCombo)
struct SettingsPanelKeysSection: View {
    var body: some View {
        SettingsSection("In the panel") {
            ForEach(SettingsPanelKeys.rows, id: \.label) { row in
                SettingsTrayRow(row.label) {
                    KeyCombo(row.keys)
                }
            }
        }
    }
}
#endif
