import AuthenticationServices
import SwiftUI
import TaskforceKit
import TaskforceUI

// 연결 · 외부 AI 처리 동의 · 프로필 화면. Figma에 없는 화면이라 Apple 기본 부품(Form)과 Taskforce 토큰 · 부품으로만 구성한다.
// iPhone은 계정 시트에서, Mac은 설정 창에서 같은 화면을 쓴다.

/// iPhone 계정 시트와 Mac 설정 Account가 같이 쓰는 문구
enum AccountCopy {
    /// Sign Out 아래 한 줄: 이 기기만 로그아웃한다 (`SessionStore.signOut`, `.local`). 다른 기기의 세션은 그대로다
    static let signOutScope = "Sign Out applies only to this device."
}

/// 연결 목록: 1단계는 바로 연결, 2단계는 "Want this"
struct ConnectionsView: View {
    @Environment(AccountStore.self) private var account
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    /// 연결 전에 읽는 것을 먼저 보여 주는 서비스 (Google · Slack)
    @State private var confirming: ConnectionProvider?
    @State private var disconnecting: ConnectionRecord?

    var body: some View {
        @Bindable var account = account
        Form {
            Section {
                ForEach(ConnectionProvider.stageOne) { provider in
                    ConnectionRow(
                        provider: provider,
                        state: account.state(for: provider),
                        comingSoon: account.comingSoon.contains(provider),
                        connecting: account.connecting == provider,
                        syncing: account.isSyncing(provider),
                        sending: account.syncing,
                        onConnect: { connect(provider) },
                        onSync: { Task { await account.sync() } },
                        onDisconnect: { disconnecting = $0 }
                    )
                }
            }
            Section("More") {
                ForEach(ConnectionProvider.stageTwo) { provider in
                    HStack {
                        Text(provider.displayName)
                            .foregroundStyle(TFColor.textPrimary)
                        Spacer()
                        if account.requested.contains(provider) {
                            Text("Requested")
                                .font(TFFont.footnote)
                                .foregroundStyle(TFColor.textSecondary)
                        } else {
                            Button("Want this") { Task { await account.request(provider) } }
                                .buttonStyle(.bordered)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Connections")
        .task { await account.load() }
        // 동기화 중인 동안 몇 초마다 다시 읽는다 (이 화면이 보이는 동안만)
        .task(id: account.anySyncing) {
            guard account.anySyncing else { return }
            await account.followSync()
        }
        .confirmationDialog(
            confirming?.displayName ?? "",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            titleVisibility: .visible,
            presenting: confirming
        ) { provider in
            Button("Continue") { start(provider) }
        } message: { provider in
            Text(provider.readsBeforeConnecting.joined(separator: "\n"))
        }
        .confirmationDialog(
            "Disconnect?",
            isPresented: Binding(get: { disconnecting != nil }, set: { if !$0 { disconnecting = nil } }),
            titleVisibility: .visible,
            presenting: disconnecting
        ) { record in
            Button("Disconnect", role: .destructive) { Task { await account.disconnect(record) } }
        } message: { record in
            Text(ConnectionProvider.disconnectNote(for: record.provider))
        }
        .sheet(isPresented: $account.showsConsent, onDismiss: { account.declineConsent() }) {
            ConsentPrompt()
        }
        // 동의가 끝나면 이 화면의 브라우저 세션으로 이어서 연결한다
        .onChange(of: account.resumeProvider) { _, provider in
            guard let provider else { return }
            account.resumeProvider = nil
            connect(provider)
        }
        .messageAlert($account.message)
    }

    private func connect(_ provider: ConnectionProvider) {
        if !provider.readsBeforeConnecting.isEmpty, !account.needsConsent {
            confirming = provider
        } else {
            start(provider)
        }
    }

    private func start(_ provider: ConnectionProvider) {
        Task { await account.connect(provider, using: webAuthenticationSession) }
    }
}

/// 1단계 서비스 한 줄: 로고 + 이름 + 상태 + 동작
private struct ConnectionRow: View {
    let provider: ConnectionProvider
    let state: ConnectionState
    let comingSoon: Bool
    let connecting: Bool
    /// 서버가 이 연결을 동기화하는 중 (또는 연결 · Sync Now 직후)
    let syncing: Bool
    /// Sync Now 요청을 보내는 중
    let sending: Bool
    let onConnect: () -> Void
    let onSync: () -> Void
    let onDisconnect: (ConnectionRecord) -> Void

    var body: some View {
        HStack(spacing: TFSpace.md) {
            if let logo = provider.logo {
                SourceIcon(logo)
            }
            VStack(alignment: .leading, spacing: TFSpace.xxs) {
                Text(provider.displayName)
                    .foregroundStyle(TFColor.textPrimary)
                if let status = state.statusLine(for: provider, syncing: syncing, comingSoon: comingSoon) {
                    HStack(spacing: TFSpace.xs) {
                        if status.showsProgress {
                            ProgressView()
                                .controlSize(.mini)
                        }
                        Text(status.text)
                            .lineLimit(2)
                    }
                    .font(TFFont.footnote)
                    .foregroundStyle(status.isAlert ? TFColor.statusOverdue : TFColor.textSecondary)
                }
            }
            Spacer(minLength: TFSpace.sm)
            trailing
        }
    }

    private func moreMenu<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        Menu(content: content) {
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(TFColor.textSecondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("More")
    }

    @ViewBuilder
    private var trailing: some View {
        if connecting {
            ProgressView().controlSize(.small)
        } else {
            switch state {
            case .notConnected:
                if !comingSoon {
                    Button("Connect", action: onConnect)
                        .buttonStyle(.bordered)
                }
            case .needsReconnect(let record):
                // 끊긴 연결도 지울 수 있다 (Slack에서 앱을 지워 남은 연결 기록)
                HStack(spacing: TFSpace.sm) {
                    Button("Reconnect", action: onConnect)
                        .buttonStyle(.bordered)
                    moreMenu {
                        Button("Disconnect", role: .destructive) { onDisconnect(record) }
                    }
                }
            case .connected(let record), .syncFailed(let record):
                moreMenu {
                    // 동기화 중에 눌러도 된다: 서버가 429로 답하면 오류 없이 "Syncing…" 그대로
                    Button("Sync Now", action: onSync)
                        .disabled(sending)
                    Button("Disconnect", role: .destructive) { onDisconnect(record) }
                }
            }
        }
    }
}

/// 외부 AI 처리 동의 내용 (App Store 5.1.2(i)): 무엇을 · 누구에게 · 어떻게 지키나 · 철회.
/// 처리방침 4장 · 7장 표와 같은 내용 · 이름을 쓴다(docs/go-live/app-store.md 5장, D9a-1 초안 4장 "What we send" · "Consent and withdrawal").
/// 공급자 · 보내는 것이 바뀌면 처리방침과 함께 고친다.
struct ConsentDetails: View {
    /// 철회 경로: Mac 설정 사이드바 · iPhone 설정 시트 모두 같은 이름 (처리방침 4장 · 11장 "app → Settings → Privacy & AI Data")
    static let settingsPath = "Settings > Privacy & AI Data"

    static let purpose = "To find your tasks and write drafts you start, Taskforce sends the text you connect or paste in to third-party AI models. Drafts are only saved in Taskforce, never sent to the people they're for or added to your connected services."
    static let sent = "Notes, documents, transcripts, messages, and email you connect or paste in, with the names and email addresses of people in them. Your name, nicknames, and email addresses, so the AI can recognize you. Your task titles and quotes. Questions you ask, with related tasks and quotes, including draft records. Hand off to AI only shows text for you to copy; Taskforce doesn't send it."
    static let drafts = "Your request. The task's title, status, owner, due date, and counterpart. Its quotes with nearby source text, and those sources' type, title, date, and the names and email addresses of people in them. Your name (or the first part of your email). Instructions and titles of earlier drafts for the same request. Text and quotes from Slack are left out; a task from Slack still sends its own title, status, owner, due date, and counterpart."
    static let receivers = "OpenRouter (USA), which routes each request to Fireworks, Together AI, DeepInfra, Microsoft Azure, or TypeSafe (all USA)."
    static let protection = "AI providers process your text to make an answer. Taskforce asks them not to use it for training or keep it after a request. If no provider meets those conditions, Taskforce won't send the request. Taskforce stores your sources, tasks, and drafts separately under its own retention policy."
    static let withdraw = "Turn this off in \(settingsPath). Without it, Taskforce doesn't send or process your sources and doesn't write drafts: no new tasks are found, and a draft in progress stops before its next AI request. Existing tasks and drafts stay."

    var body: some View {
        VStack(alignment: .leading, spacing: TFSpace.lg) {
            Text(Self.purpose)
                .font(TFFont.callout)
                .foregroundStyle(TFColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            item("doc.text", "What's sent", Self.sent)
            item("square.and.pencil", "For drafts you start", Self.drafts)
            item("arrow.up.right", "Who receives it", Self.receivers)
            item("lock.shield", "How it's protected", Self.protection)
            item("arrow.uturn.backward", "Withdraw anytime", Self.withdraw)
            LegalLinksRow()
                .font(TFFont.footnote)
                .padding(.leading, 20 + TFSpace.md)
        }
    }

    private func item(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: TFSpace.md) {
            Image(systemName: symbol)
                .font(TFFont.callout.weight(.semibold))
                .foregroundStyle(TFColor.textPrimary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: TFSpace.xxs) {
                Text(title)
                    .font(TFFont.headline)
                    .foregroundStyle(TFColor.textPrimary)
                Text(detail)
                    .font(TFFont.callout)
                    .foregroundStyle(TFColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// 첫 연결 전에 띄우는 동의 화면 (설정의 `Use AI on new sources`를 켤 때도)
struct ConsentPrompt: View {
    @Environment(AccountStore.self) private var account
    @Environment(\.dismiss) private var dismiss
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: TFSpace.xl) {
            ScrollView {
                VStack(alignment: .leading, spacing: TFSpace.xl) {
                    Text("Privacy & AI Data")
                        .font(TFFont.title)
                        .foregroundStyle(TFColor.textPrimary)
                    ConsentDetails()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.visible)
            HStack(spacing: TFSpace.sm) {
                Button("Allow") {
                    working = true
                    Task {
                        await account.giveConsent()
                        working = false
                        if account.hasConsent { dismiss() }
                    }
                }
                .buttonStyle(CapsuleButtonStyle(.primary))
                Button("Not Now") {
                    account.declineConsent()
                    dismiss()
                }
                .buttonStyle(CapsuleButtonStyle(.secondary))
            }
            .disabled(working)
        }
        .padding(TFSpace.xl)
        .background(TFColor.bgCanvas)
        #if os(iOS)
        .presentationDetents([.large])
        #else
        // 설정 창(760×480) 안에 들어가게. 알리는 내용은 스크롤하고 Allow · Not Now는 아래에 고정 (5.1.2(i), 사용자 결정 2026-10-03)
        .frame(width: 460, height: 440)
        #endif
    }
}

/// `Use AI on new sources` 스위치를 바꾸려 할 때 할 일. 동의는 이어지는 화면이 바꾼다: 켜기는 동의 화면에서 Allow를 눌러야, 끄기는 철회를 확인해야
enum ConsentSwitch: Equatable {
    /// 켜기: 동의 화면 (`ConsentPrompt`)
    case prompt
    /// 끄기: 철회 확인
    case confirmWithdraw
    /// 바꿀 것 없음 (이미 그 상태 · 동의 상태를 모름)
    case none

    /// `known`: 동의 상태를 안다 (`AccountStore.consentKnown`). 모르면 바꾸지 않는다
    static func change(to on: Bool, hasConsent: Bool, known: Bool) -> ConsentSwitch {
        guard known, on != hasConsent else { return .none }
        return on ? .prompt : .confirmWithdraw
    }
}

/// 설정 Privacy & AI Data (Figma S7 269:5822 `Section · AI`): `Use AI on new sources` 스위치 · AI providers + 그 아래 동의 내용(5.1.2(i) 공개).
/// S7의 Stored data · Support access는 U4. Mac은 설정 카드, iPhone은 설정 시트의 Form
struct ConsentSettingsView: View {
    @Environment(AccountStore.self) private var account
    @Environment(\.openURL) private var openURL
    @State private var prompting = false
    @State private var confirmingWithdraw = false
    @State private var withdrawing = false

    static let pageDescription = "What Taskforce sends to AI, and what it keeps."
    static let switchTitle = "Use AI on new sources"
    static let providersTitle = "AI providers"
    static let providersDetail = "Taskforce asks AI providers not to use your text for training or keep it after a request. If no provider meets those conditions, we don't send your request."

    var body: some View {
        @Bindable var account = account
        content
            .task { await account.load() }
            .sheet(isPresented: $prompting) {
                ConsentPrompt()
            }
            .confirmationDialog("Withdraw AI processing?", isPresented: $confirmingWithdraw, titleVisibility: .visible) {
                Button("Withdraw", role: .destructive) { withdraw() }
            } message: {
                Text("Taskforce stops reading new sources and writing drafts until you allow it again.")
            }
            .messageAlert($account.message)
    }

    /// 켜져 있으면 끄는 결과를, 꺼져 있으면 지금 상태를 (Figma S7 · S7c)
    private var switchDetail: String {
        account.hasConsent
            ? "Turning this off stops new tasks from sources and new drafts. Your tasks and drafts stay."
            : "New sources aren't read and no drafts are written. Your tasks and drafts stay."
    }

    private var useAI: Binding<Bool> {
        Binding(
            get: { account.hasConsent },
            set: { on in
                switch ConsentSwitch.change(to: on, hasConsent: account.hasConsent, known: account.consentKnown) {
                case .prompt: prompting = true
                case .confirmWithdraw: confirmingWithdraw = true
                case .none: break
                }
            }
        )
    }

    private func withdraw() {
        withdrawing = true
        Task {
            await account.withdrawConsent()
            withdrawing = false
        }
    }

    #if os(macOS)
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(Self.pageDescription)
                    .font(TFFont.footnote)
                    .foregroundStyle(TFColor.textSecondary)
                VStack(alignment: .leading, spacing: 10) {
                    Text("AI")
                        .font(TFFont.footnoteEmphasis)
                        .foregroundStyle(TFColor.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    SettingsCard {
                        SettingsRow(Self.switchTitle, subtitle: switchDetail) {
                            Toggle(Self.switchTitle, isOn: useAI)
                                .toggleStyle(.switch)
                                .labelsHidden()
                                .controlSize(.mini)
                                .tint(TFColor.fillAccent)
                                .disabled(!account.consentKnown || withdrawing)
                        }
                        SettingsDivider()
                        SettingsRow(Self.providersTitle, subtitle: Self.providersDetail) {
                            QuietButton("View Policy") { openURL(LegalLinks.privacy) }
                        }
                    }
                }
                SettingsCard {
                    ConsentDetails()
                        .padding(TFSpace.lg)
                }
            }
            .frame(width: MacSettingsView.column, alignment: .leading)
            .padding(.top, 20)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
    }
    #else
    private var content: some View {
        Form {
            Section {
                Toggle(isOn: useAI) {
                    Text(Self.switchTitle)
                    Text(switchDetail)
                }
                .tint(TFColor.fillAccent)
                .disabled(!account.consentKnown || withdrawing)
                LabeledContent {
                    Button("View Policy") { openURL(LegalLinks.privacy) }
                } label: {
                    Text(Self.providersTitle)
                    Text(Self.providersDetail)
                }
            } header: {
                Text(Self.pageDescription)
                    .textCase(nil)
            }
            Section {
                ConsentDetails()
                    .padding(.vertical, TFSpace.xs)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Privacy & AI Data")
    }
    #endif
}

/// 이름 · 다른 이름: 원문 속 "나"를 알아보는 데 쓴다 (서버 PUT /profile)
struct ProfileForm: View {
    @Environment(AccountStore.self) private var account
    @Environment(\.dismiss) private var dismiss
    /// 저장하면 닫을지 (첫 실행 시트)
    var dismissOnSave = false

    @State private var name = ""
    @State private var aliases = ""
    @State private var saving = false
    @State private var filled = false

    var body: some View {
        @Bindable var account = account
        Form {
            Section {
                TextField("Name", text: $name)
                #if os(iOS)
                    .textContentType(.name)
                #endif
                TextField("Other names", text: $aliases, prompt: Text("Nicknames, English name…"))
            } footer: {
                Text("Used to find what you promised in meeting notes and messages.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Profile")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(saving || account.profile == nil || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .task {
            if account.profile == nil { await account.load() }
            fill()
        }
        .onChange(of: account.profile) { fill() }
        .messageAlert($account.message)
    }

    private func fill() {
        guard !filled, let profile = account.profile else { return }
        filled = true
        name = profile.displayName ?? ""
        aliases = profile.aliases.joined(separator: ", ")
    }

    private func save() {
        saving = true
        Task {
            let saved = await account.saveProfile(name: name, aliases: Profile.aliases(fromList: aliases))
            saving = false
            if saved, dismissOnSave { dismiss() }
        }
    }
}
