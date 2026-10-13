#if os(macOS)
import AppKit
import SwiftUI
import TaskforceKit
import TaskforceUI

struct KeyboardShortcutsPane: View {
    @State private var recorder = HotKeyRecorder()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TFSpace.sm) {
                SettingsCard {
                    SettingsRow("Open launcher") {
                        HStack(spacing: TFSpace.sm) {
                            Keycap(recorder.recording == .launcher ? "…" : recorder.launcher.displayLabel)
                            QuietButton(recorder.recording == .launcher ? "Cancel" : "Change") { recorder.toggle(.launcher) }
                            if recorder.launcherUnavailable {
                                QuietButton("Retry") { recorder.retry(.launcher) }
                            }
                            if !recorder.launcher.matches(.default) {
                                QuietButton("Reset") { recorder.resetLauncher() }
                            }
                        }
                    }
                    SettingsDivider()
                    SettingsRow("Open Settings") {
                        HStack(spacing: TFSpace.sm) {
                            Keycap(recorder.recording == .settings ? "…" : recorder.settings?.displayLabel ?? "Not set")
                            QuietButton(recorder.recording == .settings ? "Cancel" : recorder.settings == nil ? "Record" : "Change") {
                                recorder.toggle(.settings)
                            }
                            if recorder.settingsUnavailable, recorder.settings != nil {
                                QuietButton("Retry") { recorder.retry(.settings) }
                            }
                            if recorder.settings != nil {
                                QuietButton("Remove") { recorder.removeSettings() }
                            }
                        }
                    }
                }
                if recorder.launcherUnavailable {
                    Text(HotKeyRecorder.launcherInactive)
                        .font(TFFont.meta).foregroundStyle(TFColor.statusOverdue)
                }
                if recorder.settingsUnavailable {
                    Text(HotKeyRecorder.settingsInactive)
                        .font(TFFont.meta).foregroundStyle(TFColor.statusOverdue)
                }
                Text(recorder.recording == nil ? HotKeyRecorder.footnote : HotKeyRecorder.recordingFootnote)
                    .font(TFFont.meta)
                    .foregroundStyle(TFColor.textSecondary)
                if let message = recorder.message {
                    Text(message).font(TFFont.meta).foregroundStyle(TFColor.statusOverdue)
                }
            }
            .frame(width: MacSettingsView.column, alignment: .leading)
            .padding(.top, 20)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
        .modifier(HotKeyRecorderLifecycle(recorder: recorder))
    }
}

/// 전역 단축키(런처 · 설정 창) 기록: 기록하는 동안 두 단축키를 멈추고, 앱 안 키 이벤트를 받아 바꾼다(실패하면 전 것을 되살린다).
/// 기존 설정 창 `KeyboardShortcutsPane`과 0.2.0 설정 창 Shortcuts 탭이 같이 쓴다
@MainActor
@Observable
final class HotKeyRecorder {
    static let footnote = "These shortcuts work from any app. ⌘, also opens Settings while Taskforce is active."
    static let recordingFootnote = "Press a shortcut with ⌘, ⌥, or ⌃. Press Esc to cancel."
    static let launcherInactive = "Open launcher shortcut is not active. Retry or record a different shortcut."
    static let settingsInactive = "Open Settings shortcut is saved but not active. Another app may be using it. Retry or record a different shortcut."

    private(set) var launcher = HotKeyShortcut.load()
    private(set) var settings = HotKeyShortcut.load(for: .settings)
    private(set) var recording: HotKeyShortcut.Action?
    private(set) var message: String?
    /// `message`가 생긴 단축키 (0.2.0 설정 창은 그 행 아래에 보인다)
    private(set) var messageAction: HotKeyShortcut.Action?
    private(set) var launcherUnavailable = false
    private(set) var settingsUnavailable = false
    @ObservationIgnored private var monitor: Any?

    func toggle(_ action: HotKeyShortcut.Action) {
        let wasRecording = recording == action
        stop()
        guard !wasRecording, let delegate = MacAppDelegate.shared else { return }
        message = nil
        recording = action
        delegate.suspendHotKeys()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, let action = self.recording else { return false }
                if event.keyCode == 53 {
                    self.stop()
                    return true
                }
                guard !event.isARepeat else { return true }
                guard let candidate = HotKeyShortcut(event: event), candidate.isValid else {
                    self.show("Include ⌘, ⌥, or ⌃.", for: action)
                    return true
                }
                // Restore both previous registrations before attempting a transactional replacement.
                self.stop()
                if MacAppDelegate.shared?.changeHotKey(to: candidate, for: action) == true {
                    if action == .launcher { self.launcher = candidate } else { self.settings = candidate }
                } else {
                    self.show("That shortcut is in use. Try another.", for: action)
                }
                self.refresh()
                return true
            }
            return consumed ? nil : event
        }
        if monitor == nil { stop() }
    }

    func resetLauncher() {
        stop()
        if MacAppDelegate.shared?.resetHotKey() == true {
            launcher = .default
            refresh()
        } else {
            show("That shortcut is in use. Your shortcut has not changed.", for: .launcher)
        }
    }

    func removeSettings() {
        stop()
        MacAppDelegate.shared?.removeSettingsHotKey()
        settings = nil
        refresh()
    }

    func refresh() {
        launcherUnavailable = MacAppDelegate.shared?.isHotKeyRegistered(for: .launcher) == false
        settingsUnavailable = settings != nil && MacAppDelegate.shared?.isHotKeyRegistered(for: .settings) == false
    }

    func retry(_ action: HotKeyShortcut.Action) {
        guard let shortcut = action == .launcher ? launcher : settings else { return }
        stop()
        message = nil
        if MacAppDelegate.shared?.changeHotKey(to: shortcut, for: action) != true {
            show("That shortcut is in use. Try another.", for: action)
        }
        refresh()
    }

    func stop() {
        guard recording != nil || monitor != nil else { return }
        let action = recording
        recording = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if MacAppDelegate.shared?.resumeHotKeys() == false {
            show("Could not restore a shortcut. Another app may be using it. Try recording it again.", for: action)
        }
        refresh()
    }

    private func show(_ text: String, for action: HotKeyShortcut.Action?) {
        message = text
        messageAction = action
    }
}

/// 단축키 칸이 보이는 동안: 처음 등록 상태를 읽고, 사라지거나 창 · 앱이 키를 잃으면 기록을 멈춘다
struct HotKeyRecorderLifecycle: ViewModifier {
    let recorder: HotKeyRecorder

    func body(content: Content) -> some View {
        content
            .onAppear { recorder.refresh() }
            .onDisappear { recorder.stop() }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in recorder.stop() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in recorder.stop() }
    }
}
#endif
