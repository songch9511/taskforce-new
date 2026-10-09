#if os(macOS)
import AuthenticationServices
import SwiftUI
import TaskforceKit
import TaskforceUI

// Settings › Connections (디자인 SettingsPage Connections · ConnectionsPage): AI processing → Sources → More services.
// 기존 창의 Connections(`ConnectionsView`)와 Privacy & AI Data(`ConsentSettingsView`)를 옮겼다. 같은 `AccountStore`를 쓴다.
// Your agents(Claude Code)는 에이전트 adapter gate가 꺼져 있어 넣지 않는다. 연결 상세의 Capabilities · Behavior는 데이터가 없어 넣지 않는다.

/// 외부 AI 처리 동의 스위치 (`Use AI on new sources`: 처리방침 · 심사 문서가 부르는 이름 그대로).
/// 켜기 → 동의 화면(Allow를 눌러야 동의), 끄기 → 트레이 안에서 철회 확인 (`ConsentSwitch`). 각주는 지금 상태의 결과.
/// Privacy & AI Data 상세에도 같은 스위치를 둔다(`inDetail`, 제목 · 상세 줄 없이): 동의 문구의 철회 경로가 그 이름을 가리킨다
struct SettingsAIProcessingSection: View {
    var inDetail = false
    @Environment(AccountStore.self) private var account
    @State private var prompting = false
    @State private var withdrawing = false

    private var model: SettingsWindowModel { .shared }

    var body: some View {
        SettingsSection(inDetail ? nil : "AI processing", footnote: ConsentSettingsView.switchDetail(hasConsent: account.hasConsent)) {
            if model.confirming == .withdrawConsent {
                ConfirmRow(
                    "Withdraw AI processing?", detail: "\(ConsentSettingsView.withdrawMessage) Your tasks and drafts stay.",
                    confirmLabel: "Withdraw", busy: withdrawing, onConfirm: withdraw, onCancel: { model.confirming = nil }
                )
            } else {
                SettingsTrayRow(ConsentSettingsView.switchTitle) {
                    Toggle(ConsentSettingsView.switchTitle, isOn: useAI)
                        .labelsHidden()
                        .toggleStyle(.tf)
                        .disabled(!account.consentKnown || withdrawing)
                }
            }
            if !inDetail {
                SettingsTrayRow("Privacy & AI Data", onOpen: { model.open(.privacy) })
            }
        }
        .task { await account.load() }
        .sheet(isPresented: $prompting) {
            ConsentPrompt()
        }
    }

    private var useAI: Binding<Bool> {
        Binding(
            get: { account.hasConsent },
            set: { on in
                switch ConsentSwitch.change(to: on, hasConsent: account.hasConsent, known: account.consentKnown) {
                case .prompt: prompting = true
                case .confirmWithdraw: model.confirming = .withdrawConsent
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
            model.confirming = nil
        }
    }
}

/// Connections › Privacy & AI Data: 동의 스위치, 그 아래 무엇을 · 누구에게 보내고 어떻게 지키나 · 철회
/// (App Store 5.1.2(i), `ConsentDetails` 그대로)
struct SettingsPrivacyDetail: View {
    var body: some View {
        SettingsAIProcessingSection(inDetail: true)
        SettingsSection {
            ConsentDetails()
                .padding(TFSpace.md)
        }
    }
}

/// 1단계 서비스 넷: 마크 · 이름 · 계정 · 상태 말 · 동작 하나. 연결 기록이 있으면 줄이 상세를 연다
struct SettingsSourcesSection: View {
    @Environment(AccountStore.self) private var account

    private var model: SettingsWindowModel { .shared }

    var body: some View {
        SettingsSection("Sources") {
            ForEach(ConnectionProvider.stageOne) { provider in
                let line = SettingsConnectionLine.make(
                    provider: provider, state: account.state(for: provider), syncing: account.isSyncing(provider),
                    comingSoon: account.comingSoon.contains(provider), connecting: account.connecting == provider
                )
                let open: (() -> Void)? = line.opens ? { model.open(.connection(provider)) } : nil
                if let action = line.action {
                    SettingsTrayRow(line.name, aside: line.aside, detail: line.detail, attention: line.attention, onOpen: open) {
                        SettingsSourceMark(provider: provider)
                    } control: {
                        Button(action.title) { model.connectRequest = provider }
                            .buttonStyle(TFButtonStyle(line.attention ? .primary : .secondary))
                            .disabled(account.connecting != nil)
                    }
                } else {
                    SettingsTrayRow(line.name, aside: line.aside, detail: line.detail, attention: line.attention, onOpen: open) {
                        SettingsSourceMark(provider: provider)
                    } control: {
                        EmptyView()
                    }
                }
            }
        }
        .task { await account.load() }
        // 동기화 중인 동안 몇 초마다 다시 읽는다 (이 화면이 보이는 동안만)
        .task(id: account.anySyncing) {
            guard account.anySyncing else { return }
            await account.followSync()
        }
    }
}

/// 서비스 마크 (Simple Icons 단색, `SourceIcon`)
private struct SettingsSourceMark: View {
    let provider: ConnectionProvider

    var body: some View {
        if let logo = provider.logo {
            SourceIcon(logo)
        }
    }
}

/// 2단계 서비스: 마크 없이 이름만, 요청 하나로 수요를 모은다 (`POST /connection-requests`, 기존 "Want this")
struct SettingsMoreServicesSection: View {
    @Environment(AccountStore.self) private var account

    var body: some View {
        let requested = ConnectionProvider.stageTwo.filter { account.requested.contains($0) }
        SettingsSection(footnote: SettingsConnectionLine.comingLater) {
            SettingsTrayRow("More services", detail: requested.isEmpty ? nil : "Requested: \(requested.map(\.displayName).joined(separator: ", "))") {
                Menu {
                    ForEach(ConnectionProvider.stageTwo) { provider in
                        if account.requested.contains(provider) {
                            Button {} label: { Label(provider.displayName, systemImage: "checkmark") }
                                .disabled(true)
                        } else {
                            Button(provider.displayName) { Task { await account.request(provider) } }
                        }
                    }
                } label: {
                    Text("Request one…")
                }
                .menuStyle(.button)
                .buttonStyle(TFButtonStyle())
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
    }
}

/// Connections › 서비스 하나: 머리(마크 · 이름 · 계정 · 상태 · 동작) · Sync Now · Disconnect(트레이 안에서 확인).
/// 연결 기록이 사라지면(끊음 · 다른 기기) 탭으로 돌아간다
struct SettingsConnectionDetail: View {
    let provider: ConnectionProvider
    @Environment(AccountStore.self) private var account
    @State private var disconnecting = false

    private var model: SettingsWindowModel { .shared }

    var body: some View {
        let state = account.state(for: provider)
        let line = SettingsConnectionLine.make(
            provider: provider, state: state, syncing: account.isSyncing(provider),
            comingSoon: account.comingSoon.contains(provider), connecting: account.connecting == provider
        )
        VStack(alignment: .leading, spacing: SettingsWindowLayout.topicGap) {
            header(line)
                .padding(.top, SettingsWindowLayout.followOnPull)
            if Self.canSync(state) {
                // 서버는 붙은 연결을 모두 동기화한다 (기존 Sync Now, 최대 4분)
                SettingsSection {
                    SettingsTrayRow("Sync all connections", detail: line.detail, attention: line.attention) {
                        Button("Sync Now") { Task { await account.sync() } }
                            .buttonStyle(TFButtonStyle())
                            .disabled(account.syncing)
                    }
                }
            }
            if let record = state.record {
                SettingsSection {
                    if model.confirming == .disconnect(provider) {
                        ConfirmRow(
                            "Disconnect \(line.name)?", detail: SettingsConnectionLine.disconnectDetail(provider), confirmLabel: "Disconnect",
                            busy: disconnecting, onConfirm: { disconnect(record) }, onCancel: { model.confirming = nil }
                        )
                    } else {
                        SettingsTrayRow("Disconnect") {
                            Button("Disconnect…") { model.confirming = .disconnect(provider) }
                                .buttonStyle(TFButtonStyle())
                                .disabled(disconnecting)
                        }
                    }
                }
            }
        }
        .task(id: state.isConnected) {
            if !state.isConnected, !disconnecting { model.close() }
        }
    }

    /// Sync Now는 연결이 살아 있을 때만 (기존 ··· 메뉴와 같다: 다시 연결이 필요하면 Reconnect · Disconnect만)
    static func canSync(_ state: ConnectionState) -> Bool {
        switch state {
        case .connected, .syncFailed: true
        case .notConnected, .needsReconnect: false
        }
    }

    /// ConnectionHeader: 마크 20 · 이름 17 semibold · 계정과 상태, 동작 하나 (다시 연결이 필요하면 잉크 Reconnect)
    private func header(_ line: SettingsConnectionLine) -> some View {
        HStack(spacing: TFSpace.md) {
            SettingsSourceMark(provider: provider)
            VStack(alignment: .leading, spacing: 2) {
                Text(line.name)
                    .font(TFFont.headline)
                    .foregroundStyle(TFColor.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text([line.aside, line.detail].compactMap { $0 }.joined(separator: " · "))
                    .font(line.attention ? TFFont.footnoteEmphasis : TFFont.footnote)
                    .foregroundStyle(line.attention ? TFColor.textPrimary : TFColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let action = line.action {
                Button(action.title) { model.connectRequest = provider }
                    .buttonStyle(TFButtonStyle(line.attention ? .primary : .secondary))
                    .disabled(account.connecting != nil)
            }
        }
        .padding(.horizontal, TFSpace.md)
    }

    private func disconnect(_ record: ConnectionRecord) {
        disconnecting = true
        Task {
            await account.disconnect(record)
            disconnecting = false
            model.close()
        }
    }
}

/// Connections 탭의 연결 흐름 (기존 `ConnectionsView`와 같다): Google · Gmail · Slack은 읽는 것을 먼저 보여 주고(Continue),
/// 동의가 필요하면 동의 화면, 동의 뒤 이 화면의 브라우저 세션으로 이어서 연결한다. 오류는 알림 하나.
/// Connections 탭이 보일 때만 켠다(`active`): 다른 탭에서는 동의 화면이 뜨지 않는다 (기존 창도 Connections 페이지에서만 띄운다)
struct ConnectionFlow: ViewModifier {
    let active: Bool
    @Environment(AccountStore.self) private var account
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var confirming: ConnectionProvider?

    private var model: SettingsWindowModel { .shared }

    func body(content: Content) -> some View {
        @Bindable var account = account
        content
            .onChange(of: model.connectRequest) { _, provider in
                guard let provider else { return }
                model.connectRequest = nil
                guard active else { return }
                connect(provider)
            }
            .confirmationDialog(
                confirming?.displayName ?? "",
                isPresented: Binding(get: { active && confirming != nil }, set: { if !$0 { confirming = nil } }),
                titleVisibility: .visible,
                presenting: confirming
            ) { provider in
                Button("Continue") { start(provider) }
            } message: { provider in
                Text(provider.readsBeforeConnecting.joined(separator: "\n"))
            }
            .sheet(
                isPresented: Binding(get: { active && account.showsConsent }, set: { account.showsConsent = $0 }),
                onDismiss: { account.declineConsent() }
            ) {
                ConsentPrompt()
            }
            // 동의가 끝나면 이 화면의 브라우저 세션으로 이어서 연결한다
            .onChange(of: account.resumeProvider) { _, provider in
                guard active, let provider else { return }
                account.resumeProvider = nil
                connect(provider)
            }
            .messageAlert(Binding(get: { active ? account.message : nil }, set: { account.message = $0 }))
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
#endif
