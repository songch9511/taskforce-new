#if os(macOS)
import AppKit
import SwiftUI
import TaskforceKit
import TaskforceUI

struct KeyboardShortcutsPane: View {
    @State private var launcher = HotKeyShortcut.load()
    @State private var settings = HotKeyShortcut.load(for: .settings)
    @State private var recording: HotKeyShortcut.Action?
    @State private var monitor: Any?
    @State private var message: String?
    @State private var launcherUnavailable = false
    @State private var settingsUnavailable = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TFSpace.sm) {
                SettingsCard {
                    SettingsRow("Open launcher") {
                        HStack(spacing: TFSpace.sm) {
                            Keycap(recording == .launcher ? "…" : launcher.displayLabel)
                            QuietButton(recording == .launcher ? "Cancel" : "Change") { toggle(.launcher) }
                            if launcherUnavailable {
                                QuietButton("Retry") { retry(.launcher, shortcut: launcher) }
                            }
                            if !launcher.matches(.default) {
                                QuietButton("Reset") {
                                    stop()
                                    if MacAppDelegate.shared?.resetHotKey() == true {
                                        launcher = .default
                                        refreshRegistrationStatus()
                                    } else {
                                        message = "That shortcut is in use. Your shortcut has not changed."
                                    }
                                }
                            }
                        }
                    }
                    SettingsDivider()
                    SettingsRow("Open Settings") {
                        HStack(spacing: TFSpace.sm) {
                            Keycap(recording == .settings ? "…" : settings?.displayLabel ?? "Not set")
                            QuietButton(recording == .settings ? "Cancel" : settings == nil ? "Record" : "Change") {
                                toggle(.settings)
                            }
                            if settingsUnavailable, let settings {
                                QuietButton("Retry") { retry(.settings, shortcut: settings) }
                            }
                            if settings != nil {
                                QuietButton("Remove") {
                                    stop()
                                    MacAppDelegate.shared?.removeSettingsHotKey()
                                    settings = nil
                                    refreshRegistrationStatus()
                                }
                            }
                        }
                    }
                }
                if launcherUnavailable {
                    Text("Open launcher shortcut is not active. Retry or record a different shortcut.")
                        .font(TFFont.meta).foregroundStyle(TFColor.statusOverdue)
                }
                if settingsUnavailable {
                    Text("Open Settings shortcut is saved but not active. Another app may be using it. Retry or record a different shortcut.")
                        .font(TFFont.meta).foregroundStyle(TFColor.statusOverdue)
                }
                Text(recording == nil
                     ? "These shortcuts work from any app. ⌘, also opens Settings while Taskforce is active."
                     : "Press a shortcut with ⌘, ⌥, or ⌃. Press Esc to cancel.")
                    .font(TFFont.meta)
                    .foregroundStyle(TFColor.textSecondary)
                if let message {
                    Text(message).font(TFFont.meta).foregroundStyle(TFColor.statusOverdue)
                }
            }
            .frame(width: MacSettingsView.column, alignment: .leading)
            .padding(.top, 20)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
        .onAppear { refreshRegistrationStatus() }
        .onDisappear { stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in stop() }
    }

    private func toggle(_ action: HotKeyShortcut.Action) {
        let wasRecording = recording == action
        stop()
        guard !wasRecording, let delegate = MacAppDelegate.shared else { return }
        message = nil
        recording = action
        delegate.suspendHotKeys()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let action = recording else { return false }
                if event.keyCode == 53 {
                    stop()
                    return true
                }
                guard !event.isARepeat else { return true }
                guard let candidate = HotKeyShortcut(event: event), candidate.isValid else {
                    message = "Include ⌘, ⌥, or ⌃."
                    return true
                }
                // Restore both previous registrations before attempting a transactional replacement.
                stop()
                if MacAppDelegate.shared?.changeHotKey(to: candidate, for: action) == true {
                    if action == .launcher { launcher = candidate } else { settings = candidate }
                } else {
                    message = "That shortcut is in use. Try another."
                }
                refreshRegistrationStatus()
                return true
            }
            return consumed ? nil : event
        }
        if monitor == nil { stop() }
    }

    private func refreshRegistrationStatus() {
        launcherUnavailable = MacAppDelegate.shared?.isHotKeyRegistered(for: .launcher) == false
        settingsUnavailable = settings != nil && MacAppDelegate.shared?.isHotKeyRegistered(for: .settings) == false
    }

    private func retry(_ action: HotKeyShortcut.Action, shortcut: HotKeyShortcut) {
        stop()
        message = nil
        if MacAppDelegate.shared?.changeHotKey(to: shortcut, for: action) != true {
            message = "That shortcut is in use. Try another."
        }
        refreshRegistrationStatus()
    }

    private func stop() {
        guard recording != nil || monitor != nil else { return }
        recording = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if MacAppDelegate.shared?.resumeHotKeys() == false {
            message = "Could not restore a shortcut. Another app may be using it. Try recording it again."
        }
        refreshRegistrationStatus()
    }
}
#endif
