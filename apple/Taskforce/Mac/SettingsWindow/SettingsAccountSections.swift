#if os(macOS)
import AppKit
import SwiftUI
import TaskforceKit
import TaskforceUI

// Settings › Account (디자인 SettingsPage Account): Profile · Sign-in · Delete Account · About · 링크.
// 기존 창의 Account(프로필 · 로그인 계정 · Sign Out · 계정 삭제 · 링크)와 About(빌드 정보)을 옮겼다.
// Plan & usage · Remembered · 구독(Subscription)은 아직 넣지 않는다 (`SettingsWindowHidden`).

/// 이름 · 다른 이름 (서버 PUT /profile). Return을 누르거나 다른 칸 · 탭 · 창을 떠나면 바뀐 것만 저장한다.
/// 편집 상태(칸 · 오류 · 보내는 중인 저장)는 `ProfileDraft`(설정 창 모델)에 있어 이 화면이 사라져도 남는다
struct SettingsProfileSection: View {
    @Environment(SessionStore.self) private var session
    @Environment(AccountStore.self) private var account
    @FocusState private var focus: Field?

    private enum Field: Hashable {
        case name, aliases
    }

    private var draft: ProfileDraft { SettingsWindowModel.shared.profile }

    var body: some View {
        let userID = SettingsWindowSession.accountUserID(session)
        @Bindable var draft = draft
        SettingsSection("Profile", footnote: "Used to find what you promised in meeting notes and messages.") {
            SettingsTrayRow("Name", message: draft.message) {
                TextField("Name", text: $draft.name, prompt: Text("Your name"))
                    .focused($focus, equals: .name)
                    .onSubmit(save)
                    .settingsField(focused: focus == .name)
            }
            SettingsTrayRow("Other names") {
                TextField("Other names", text: $draft.aliases, prompt: Text("Nicknames, English name…"))
                    .focused($focus, equals: .aliases)
                    .onSubmit(save)
                    .settingsField(focused: focus == .aliases)
            }
        }
        .disabled(draft.baseline == nil || draft.userID != userID)
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

    private func follow(_ userID: UUID?) {
        guard let userID else { return }
        draft.follow(userID: userID, profile: account.profile)
    }

    private func save() {
        guard draft.userID == SettingsWindowSession.accountUserID(session) else { return }
        let account = account
        draft.requestSave { name, aliases in
            if await account.saveProfile(name: name, aliases: aliases), let saved = account.profile {
                return .saved(saved)
            }
            // 오류는 그 칸 아래에 둔다 (Connections 탭의 알림으로 다시 뜨지 않게)
            let text = account.message
            account.message = nil
            return .failed(text)
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
