import AuthenticationServices
import SwiftUI
import TaskforceKit
import TaskforceUI

// 연결 · 외부 AI 처리 동의 · 프로필 화면. Figma에 없는 화면이라 Apple 기본 부품(Form)과 Taskforce 토큰 · 부품으로만 구성한다.
// iPhone은 계정 시트에서, Mac은 설정 창에서 같은 화면을 쓴다.

/// 연결 목록: 1단계는 바로 연결, 2단계는 "Want this"
struct ConnectionsView: View {
    @Environment(AccountStore.self) private var account
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var confirmingGoogle = false
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
            ConnectionProvider.google.displayName,
            isPresented: $confirmingGoogle,
            titleVisibility: .visible
        ) {
            Button("Continue") { start(.google) }
        } message: {
            Text(ConnectionProvider.google.readsBeforeConnecting.joined(separator: "\n"))
        }
        .confirmationDialog(
            "Disconnect?",
            isPresented: Binding(get: { disconnecting != nil }, set: { if !$0 { disconnecting = nil } }),
            titleVisibility: .visible,
            presenting: disconnecting
        ) { record in
            Button("Disconnect", role: .destructive) { Task { await account.disconnect(record) } }
        } message: { _ in
            Text("Tasks already found stay.")
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
            confirmingGoogle = true
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
            case .needsReconnect:
                Button("Reconnect", action: onConnect)
                    .buttonStyle(.bordered)
            case .connected(let record), .syncFailed(let record):
                Menu {
                    // 동기화 중에 눌러도 된다: 서버가 429로 답하면 오류 없이 "Syncing…" 그대로
                    Button("Sync Now", action: onSync)
                        .disabled(sending)
                    Button("Disconnect", role: .destructive) { onDisconnect(record) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(TFColor.textSecondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("More")
            }
        }
    }
}

/// 외부 AI 처리 동의 내용 (App Store 5.1.2(i)): 무엇을 · 어디로 · 학습 안 함 · 철회
struct ConsentDetails: View {
    var body: some View {
        VStack(alignment: .leading, spacing: TFSpace.lg) {
            item("doc.text", "What's sent", "Text from the sources you connect: meeting notes, messages, and emails.")
            item("arrow.up.right", "Where it goes", "OpenRouter and the AI model providers it routes to, with zero data retention.")
            item("nosign", "Not for training", "Your data is never used to train AI models.")
            item("arrow.uturn.backward", "Withdraw anytime", "Turn this off in Settings. Taskforce then stops sending anything.")
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

/// 첫 연결 전에 띄우는 동의 화면
struct ConsentPrompt: View {
    @Environment(AccountStore.self) private var account
    @Environment(\.dismiss) private var dismiss
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: TFSpace.xl) {
            ScrollView {
                VStack(alignment: .leading, spacing: TFSpace.xl) {
                    Text("AI processing")
                        .font(TFFont.title)
                        .foregroundStyle(TFColor.textPrimary)
                    ConsentDetails()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
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
        .frame(width: 420, height: 440)
        #endif
    }
}

/// 설정의 동의 화면: 내용 + 지금 상태 + 동의 / 철회
struct ConsentSettingsView: View {
    @Environment(AccountStore.self) private var account
    @State private var confirmingWithdraw = false

    var body: some View {
        @Bindable var account = account
        Form {
            Section {
                ConsentDetails()
                    .padding(.vertical, TFSpace.xs)
            }
            Section {
                if account.hasConsent {
                    if let date = account.profile?.aiConsentAt, date > .distantPast {
                        LabeledContent("Allowed", value: WhenText.label(date))
                    }
                    Button("Withdraw", role: .destructive) { confirmingWithdraw = true }
                } else {
                    Button("Allow") { Task { await account.giveConsent() } }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("AI processing")
        .task { await account.load() }
        .confirmationDialog("Withdraw AI processing?", isPresented: $confirmingWithdraw, titleVisibility: .visible) {
            Button("Withdraw", role: .destructive) { Task { await account.withdrawConsent() } }
        } message: {
            Text("Taskforce stops reading new sources until you allow it again.")
        }
        .messageAlert($account.message)
    }
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
