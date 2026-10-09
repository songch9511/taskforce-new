#if os(macOS)
import AppKit
import SwiftUI
import TaskforceKit
import TaskforceUI

// Settings › Account (디자인 SettingsPage Account): Profile · Sign-in · Delete Account · About · 링크.
// 기존 창의 Account(프로필 · 로그인 계정 · Sign Out · 계정 삭제 · 링크)와 About(빌드 정보)을 옮겼다.
// Plan & usage · Remembered · 구독(Subscription)은 아직 넣지 않는다 (`SettingsWindowHidden`).

/// 이름 · 다른 이름 (서버 PUT /profile). Return을 누르거나 다른 칸 · 탭으로 옮기면 바뀐 것만 저장한다.
/// 칸은 그 칸을 채운 프로필(`baseline`)과 비교한다: 손대지 않은 칸은 새로 읽은 프로필을 따라가고(다른 기기 · 늦은 응답),
/// 손댄 칸은 저장할 때까지 덮지 않는다. 처음 채우기 전에는 칸을 끈다 (기존 Save와 같다: 읽지 못한 프로필로 저장하면 이메일 목록이 지워진다).
/// 저장하는 사이 또 바꾸면 그 저장이 끝난 뒤 한 번 더 저장한다
struct SettingsProfileSection: View {
    @Environment(SessionStore.self) private var session
    @Environment(AccountStore.self) private var account
    @State private var name = ""
    @State private var aliases = ""
    /// 칸을 채운 프로필과 그 사용자
    @State private var baseline: Profile?
    @State private var baselineFor: UUID?
    @State private var saving = false
    @State private var saveAgain = false
    @State private var message: String?
    @FocusState private var focus: Field?

    private enum Field: Hashable {
        case name, aliases
    }

    var body: some View {
        let userID = SettingsWindowSession.accountUserID(session)
        SettingsSection("Profile", footnote: "Used to find what you promised in meeting notes and messages.") {
            SettingsTrayRow("Name", message: message) {
                TextField("Name", text: $name, prompt: Text("Your name"))
                    .focused($focus, equals: .name)
                    .onSubmit(save)
                    .settingsField(focused: focus == .name)
            }
            SettingsTrayRow("Other names") {
                TextField("Other names", text: $aliases, prompt: Text("Nicknames, English name…"))
                    .focused($focus, equals: .aliases)
                    .onSubmit(save)
                    .settingsField(focused: focus == .aliases)
            }
        }
        .disabled(baseline == nil || baselineFor != userID)
        .onAppear { follow(userID) }
        .task(id: userID) {
            guard userID != nil else { return }
            await account.load()
            // 계정이 바뀌어 취소됐으면 전 계정으로 칸을 채우지 않는다
            guard !Task.isCancelled else { return }
            follow(userID)
        }
        .onChange(of: account.profile) { follow(userID) }
        .onChange(of: focus) { old, _ in
            if old != nil { save() }
        }
        .onDisappear { save() }
    }

    private func fieldsMatch(_ profile: Profile) -> Bool {
        Self.fieldsMatch(name: name, aliases: aliases, profile: profile)
    }

    /// 칸이 그 프로필과 같은 값인지 (저장할 때와 같은 다듬기: 앞뒤 공백 · 이름과 같은 별칭 · 중복)
    nonisolated static func fieldsMatch(name: String, aliases: String, profile: Profile) -> Bool {
        let edited = Profile.edited(name: name, aliases: Profile.aliases(fromList: aliases), keeping: profile)
        return edited.displayName == profile.displayName && edited.aliases == profile.aliases
    }

    /// 지금 프로필로 칸을 채운다. 사용자가 손댄 칸은 그대로 둔다 (계정이 바뀌면 처음부터)
    private func follow(_ userID: UUID?) {
        guard let userID, let profile = account.profile else { return }
        if baselineFor != userID {
            baselineFor = userID
            baseline = nil
        }
        if let baseline, !fieldsMatch(baseline) { return }
        baseline = profile
        name = profile.displayName ?? ""
        aliases = profile.aliases.joined(separator: ", ")
    }

    private func save() {
        guard let baseline, baselineFor == SettingsWindowSession.accountUserID(session) else { return }
        guard !fieldsMatch(baseline) else {
            message = nil
            return
        }
        let list = Profile.aliases(fromList: aliases)
        guard Profile.edited(name: name, aliases: list, keeping: baseline).displayName != nil else {
            message = "Add your name."
            return
        }
        guard !saving else {
            saveAgain = true
            return
        }
        saving = true
        Task {
            if await account.saveProfile(name: name, aliases: list), let saved = account.profile {
                self.baseline = saved
                message = nil
            } else {
                message = account.message
                account.message = nil
            }
            saving = false
            if saveAgain {
                saveAgain = false
                save()
            }
        }
    }
}

/// 로그인 계정 · Sign Out (이 기기만). 로그아웃이면 로그인 화면, 세션을 읽는 중이면 진행 표시
struct SettingsSignInSection: View {
    @Environment(SessionStore.self) private var session

    var body: some View {
        switch SettingsWindowSession.access(session) {
        case .signedIn:
            SettingsSection("Sign-in", footnote: AccountCopy.signOutScope) {
                SettingsTrayRow(session.signInMethods.accountLabel, detail: SettingsWindowSession.email(session)) {
                    Button("Sign Out") {
                        Task {
                            // 세션이 남아 있을 때 이 기기를 알림에서 뺀다
                            await PushCenter.shared.unregister()
                            await session.signOut()
                        }
                    }
                    .buttonStyle(TFButtonStyle())
                }
            }
        case .signedOut:
            SettingsSignInPanel()
        case .loading:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, minHeight: 80)
        }
    }
}

/// 로그인 화면 (기존 `SignInView`, S2가 온보딩과 함께 다시 그린다). 로그인이 필요한 탭에서도 쓴다
struct SettingsSignInPanel: View {
    var body: some View {
        SignInView()
            .clipShape(RoundedRectangle(cornerRadius: TFRadius.md, style: .continuous))
    }
}

/// 계정 삭제: 트레이 안에서 확인한다 (Cancel이 먼저, 보조 줄은 무엇이 남고 사라지는지 — 기존 확인 문구 그대로).
/// Apple 재확인이 필요한 계정은 확인 전에 막고 이유를 알린다 (기존과 같다)
struct SettingsDeleteAccountSection: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.services) private var services
    @State private var deleting = false
    @State private var message: String?

    private var model: SettingsWindowModel { .shared }

    var body: some View {
        SettingsSection {
            if model.confirming == .deleteAccount {
                ConfirmRow(
                    "Delete your account?", detail: AccountDeletion.confirmationMessage, confirmLabel: "Delete Account", busy: deleting,
                    onConfirm: delete, onCancel: { model.confirming = nil }
                )
            } else {
                SettingsTrayRow("Delete Account") {
                    Button("Delete…") {
                        if session.signInMethods.needsAppleReauthorization {
                            message = AccountDeletion.unavailableMessage
                        } else {
                            model.confirming = .deleteAccount
                        }
                    }
                    .buttonStyle(TFButtonStyle())
                    .disabled(deleting)
                }
            }
        }
        .messageAlert($message)
    }

    private func delete() {
        guard let services, !deleting else { return }
        deleting = true
        Task {
            message = await AccountDeletion.delete(services: services, session: session)
            deleting = false
            model.confirming = nil
        }
    }
}

/// 빌드 정보 (기존 About 페이지): 버그를 알릴 때 쓴다. 로그인과 상관없이 보인다
struct SettingsAboutSection: View {
    private let info = AboutBuildInfo.current
    @State private var copied = false

    var body: some View {
        SettingsSection("About") {
            row("Version", info.version)
            row("Build", info.build)
            row("Release channel", info.releaseChannel)
            row("Source commit", info.sourceCommit)
            row("Built (UTC)", info.buildTimeUTC)
            SettingsTrayRow("Build info") {
                Button(copied ? "Copied" : "Copy") {
                    info.copy(to: .general)
                    copied = true
                }
                .buttonStyle(TFButtonStyle())
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        SettingsTrayRow(label) {
            SettingsValue(value)
                .monospacedDigit()
                .textSelection(.enabled)
                .help(value)
        }
    }
}

/// 처리방침 · 약관 · 연락처 · 웹사이트 · GitHub 글자 링크 (앞 주제와 12, 디자인 `.tf-window-body > .tf-actions`). 링크 색은 `text/link`
struct SettingsLegalLinks: View {
    var body: some View {
        HStack(spacing: TFSpace.lg) {
            LegalLinksRow()
            Link("Contact", destination: AccountDeletion.contactURL)
            Link("Website", destination: AboutSettingsPane.websiteURL)
            Link("GitHub", destination: AboutSettingsPane.githubURL)
        }
        .buttonStyle(.plain)
        .font(TFFont.footnote)
        .foregroundStyle(TFColor.textLink)
        .padding(.horizontal, TFSpace.xs)
        .padding(.top, SettingsWindowLayout.followOnPull)
    }
}

extension SettingsWindowLayout {
    /// 제목 없이 이어지는 것은 앞 것과 12 (본문 간격 24에서 뺀다)
    static let followOnPull: CGFloat = -12
}
#endif
