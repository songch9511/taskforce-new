#if os(macOS)
import AppKit
import SwiftUI
import TaskforceKit
import TaskforceUI

/// Mac 설정 창: Account · Connections · AI data · Shortcut. iPhone과 같은 연결 · 동의 화면을 쓴다.
struct MacSettingsView: View {
    @Environment(SessionStore.self) private var session
    @Environment(AccountStore.self) private var account
    @AppStorage(SettingsOpener.tabKey) private var tab = MacSettingsTab.account.rawValue

    var body: some View {
        TabView(selection: $tab) {
            Tab("Account", systemImage: "person.crop.circle", value: MacSettingsTab.account.rawValue) {
                MacAccountPane()
            }
            Tab("Connections", systemImage: "link", value: MacSettingsTab.connections.rawValue) {
                signedInOnly { ConnectionsView() }
            }
            Tab("AI data", systemImage: "hand.raised", value: MacSettingsTab.ai.rawValue) {
                signedInOnly { ConsentSettingsView() }
            }
            Tab("Shortcut", systemImage: "keyboard", value: MacSettingsTab.shortcut.rawValue) {
                HotKeyPane()
            }
        }
        // AI data 탭의 알리는 내용과 Allow · Withdraw가 한 화면에 보이게
        .frame(width: 540, height: 620)
    }

    @ViewBuilder
    private func signedInOnly<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if case .signedIn = session.state {
            content()
        } else {
            SignInView()
        }
    }
}

/// 계정: 로그인 · 프로필(이름 · 다른 이름) · 로그아웃 · 계정 삭제
private struct MacAccountPane: View {
    @Environment(SessionStore.self) private var session
    @Environment(AccountStore.self) private var account
    @Environment(\.services) private var services
    @State private var name = ""
    @State private var aliases = ""
    @State private var filledFor: UUID?
    @State private var saving = false
    @State private var confirmingDelete = false
    @State private var deleting = false
    @State private var message: String?

    var body: some View {
        switch session.state {
        case .signedIn(let userID, let email):
            form(userID: userID, email: email)
        case .signedOut:
            SignInView()
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func form(userID: UUID, email: String?) -> some View {
        Form {
            Section {
                TextField("Name", text: $name)
                TextField("Other names", text: $aliases, prompt: Text("Nicknames, English name…"))
                HStack {
                    Spacer()
                    Button("Save") { save() }
                        .disabled(saving || account.profile == nil || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Profile")
            } footer: {
                Text("Used to find what you promised in meeting notes and messages.")
            }
            Section {
                if let email {
                    LabeledContent(session.signInMethods.accountLabel, value: email)
                }
                HStack {
                    Button("Sign Out") {
                        Task {
                            // 세션이 남아 있을 때 이 기기를 알림에서 뺀다
                            await PushCenter.shared.unregister()
                            await session.signOut()
                        }
                    }
                    Spacer()
                    Button("Delete Account…", role: .destructive) { confirmingDelete = true }
                        .disabled(deleting)
                }
            }
            Section {
                LegalLinksRow()
            }
        }
        .formStyle(.grouped)
        .task(id: userID) {
            await account.load()
            fill(for: userID)
        }
        .onChange(of: account.profile) { fill(for: userID) }
        .confirmationDialog("Delete your account?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Account", role: .destructive) { deleteAccount() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your sources, tasks, and history are deleted right away. This can't be undone.")
        }
        .messageAlert($message)
    }

    private func fill(for userID: UUID) {
        guard filledFor != userID, let profile = account.profile else { return }
        filledFor = userID
        name = profile.displayName ?? ""
        aliases = profile.aliases.joined(separator: ", ")
    }

    private func save() {
        saving = true
        Task {
            if !(await account.saveProfile(name: name, aliases: Profile.aliases(fromList: aliases))) {
                message = account.message
                account.message = nil
            }
            saving = false
        }
    }

    private func deleteAccount() {
        guard let services else { return }
        deleting = true
        Task {
            message = await AccountDeletion.delete(services: services, session: session)
            deleting = false
        }
    }
}

/// 런처 단축키 (기본 ⌥Space). 다른 앱이 이미 쓰는 조합이면 이전 것을 그대로 둔다.
private struct HotKeyPane: View {
    @State private var shortcut = HotKeyShortcut.load()
    @State private var recording = false
    @State private var monitor: Any?
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Open launcher") {
                    HStack(spacing: TFSpace.sm) {
                        Keycap(recording ? "…" : shortcut.displayLabel)
                        Button(recording ? "Press a shortcut" : "Change") { recording ? stop() : record() }
                        if shortcut != .default {
                            Button("Reset") {
                                MacAppDelegate.shared?.resetHotKey()
                                shortcut = .default
                            }
                        }
                    }
                }
            } footer: {
                if let message {
                    Text(message).foregroundStyle(TFColor.statusOverdue)
                }
            }
        }
        .formStyle(.grouped)
        .onDisappear { stop() }
    }

    private func record() {
        message = nil
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard recording else { return false }
                if event.keyCode == 53 {  // esc: 그만
                    stop()
                    return true
                }
                guard let candidate = HotKeyShortcut(event: event), candidate.isValid else {
                    message = "Include ⌘, ⌥, or ⌃."
                    return true
                }
                if MacAppDelegate.shared?.changeHotKey(to: candidate) == true {
                    shortcut = candidate
                } else {
                    message = "That shortcut is in use. Try another."
                }
                stop()
                return true
            }
            return consumed ? nil : event
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
#endif
