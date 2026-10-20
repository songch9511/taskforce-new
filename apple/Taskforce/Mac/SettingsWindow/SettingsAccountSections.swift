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

/// Sign-in 절이 무엇을 보이는지 (줄 · 컨트롤 · 각주). 화면은 이것만 그린다: 시험이 구조를 본다 (사용자 승인 2026-10-19, DZ-1 그림).
/// 이어진 방법이 먼저(Apple · Google · Email 순), 이어지지 않은 Apple · Google은 그 뒤에 Add. 이메일(심사 계정)은 Email 줄만이다.
/// 이메일 로그인이 열려 있으면(`EmailSignInGate`) 실제 주소가 있는 Apple · Google 계정에는 Email 줄이 이어져 있고, 이메일로 만든 계정에는 Apple · Google Add가 있다 (`SignInMethods.rows`).
/// 방식을 모르면(세션에 정보가 없음) 예전 한 줄(`accountLabel` · 이메일 · Sign Out)로 둔다.
struct SignInSectionModel: Equatable {
    enum Control: Equatable {
        case none
        /// 첫 줄 오른쪽 (DS 자리)
        case signOut
        /// 이어지지 않은 Apple · Google. `busy`: 이어 붙이는 중 (스피너뿐, 눌림을 막는다)
        case add(busy: Bool)
    }

    struct Row: Equatable, Identifiable {
        /// 한 줄로 떨어진 옛 모양이면 nil
        let method: SignInMethodRow.Method?
        let label: String
        /// 이어진 방법은 그 로그인의 이메일. 이어 붙이기 오류가 있으면 이어지지 않은 줄의 이 자리에 조용한 회색 한 줄로 보인다
        let detail: String?
        let control: Control
        var id: String { method?.rawValue ?? "account" }
    }

    let rows: [Row]
    let footnote: String

    static func make(
        methods: SignInMethods, accountEmail: String?, busy: SignInMethodRow.Method? = nil, messages: [SignInMethodRow.Method: String] = [:],
        emailSignIn: Bool = EmailSignInGate.isOpen
    ) -> SignInSectionModel {
        let methodRows = methods.rows(accountEmail: accountEmail, emailSignIn: emailSignIn)
        guard !methodRows.isEmpty else {
            return SignInSectionModel(rows: [Row(method: nil, label: methods.accountLabel, detail: accountEmail, control: .signOut)], footnote: AccountCopy.signOutScope)
        }
        var rows: [Row] = []
        for row in methodRows {
            let label = SignInCopy.rowLabel(row.method)
            if row.linked {
                rows.append(Row(method: row.method, label: label, detail: row.email, control: rows.isEmpty ? .signOut : .none))
            } else {
                rows.append(Row(method: row.method, label: label, detail: messages[row.method], control: .add(busy: busy == row.method)))
            }
        }
        // 이어 붙일 방법이 남았을 때만 새 문장이 붙는다: 하나 남으면 "the other one", 둘 남으면(이메일 계정) 둘을 이름으로. 없으면(다 이어짐 · 심사 계정) 지금 문장 하나
        let footnote: String
        switch methodRows.filter(\.canAdd).count {
        case 0: footnote = AccountCopy.signOutScope
        case 1: footnote = "\(AccountCopy.signOutScope) \(SignInCopy.addTheOther)"
        default: footnote = "\(AccountCopy.signOutScope) \(SignInCopy.addEither)"
        }
        return SignInSectionModel(rows: rows, footnote: footnote)
    }
}

/// Sign-in 절의 "Add" 흐름 (Apple · Google을 지금 계정에 이어 붙인다). 흐름 하나만 돌고, 흐름이 도는 사이 계정이 바뀌면 그 결과를 버린다
/// (서버에 쓰기 전에 `SessionStore.link…`가 한 번, 끝난 뒤 여기서 한 번). 데이터는 합치지 않는다.
@MainActor
@Observable
final class SignInAddModel {
    static let shared = SignInAddModel()

    private(set) var busy: SignInMethodRow.Method?
    private(set) var messages: [SignInMethodRow.Method: String] = [:]
    /// 줄 · 오류가 속한 계정. 다른 계정이 되면 모두 비운다 (`follow` · `attach`)
    private var owner: UUID?
    /// 계정이 바뀔 때마다(로그아웃 포함) 오른다: 돌고 있던 흐름이 끝나도 새 계정(같은 계정으로 다시 로그인했어도)의 상태를 건드리지 않게
    private(set) var generation = 0
    /// 이미 계정 이탈을 듣고 있는 세션 (겹쳐 붙이지 않는다)
    @ObservationIgnored private var attached: Set<ObjectIdentifier> = []

    /// 토큰을 받는 입구 (시험은 가짜로 바꾼다: 실제 Apple · Google 창에 닿지 않는다)
    @ObservationIgnored var authorizeApple: @MainActor () async -> AppleSignInFlow.Authorization<AppleSignInFlow.SignInToken> = { await AppleSignInFlow.shared.authorizeSignIn(step: .link) }
    @ObservationIgnored var authorizeGoogle: @MainActor () async -> GoogleSignInFlow.Authorization = { await GoogleSignInFlow.authorize(step: .link) }
    /// 이어 붙이지 못한 Google 로그인은 이 기기에서 지운다 (다음 시도는 계정 고르기부터)
    @ObservationIgnored var discardGoogle: @MainActor () -> Void = { GoogleSignInFlow.signOut() }

    init() {}

    /// 계정이 이 기기를 떠날 때마다(로그아웃 · 만료 · 삭제 · 다른 계정으로 전환) 모델을 비운다. 설정 창이 로그인 화면으로 바뀌어 이 절이 사라져도 듣는다
    /// (그러지 않으면 로그아웃 때 `busy`가 남아, 같은 계정으로 다시 들어와도 Add가 잠긴다: 검토 1 P2)
    func attach(to session: SessionStore) {
        guard attached.insert(ObjectIdentifier(session)).inserted else { return }
        session.onSignedOut { [weak self] _ in self?.reset() }
    }

    private func reset() {
        owner = nil
        generation += 1
        busy = nil
        messages = [:]
    }

    /// 화면이 보이는 계정이 바뀌면 비운다
    func follow(userID: UUID?) {
        guard owner != userID else { return }
        reset()
        owner = userID
    }

    func add(_ method: SignInMethodRow.Method, session: SessionStore) async {
        guard busy == nil, method != .email, case .signedIn(let userID, _) = session.state else { return }
        follow(userID: userID)
        let started = generation
        busy = method
        messages[method] = nil
        let result: SessionStore.LinkResult?
        switch method {
        case .apple:
            switch await authorizeApple() {
            case .value(let token):
                // 창이 떠 있는 사이 계정이 떠났다 돌아왔다면(같은 계정이어도) 이 흐름은 낡았다: 이어 붙이지 않는다
                guard generation == started else { return }
                result = await session.linkApple(idToken: token.idToken, nonce: token.nonce, expectedUserID: userID)
                Self.record(.apple, result)
            case .canceled: result = nil
            case .failed: result = .failed
            }
        case .google:
            switch await authorizeGoogle() {
            case .tokens(let idToken, let accessToken, let nonce):
                guard generation == started else { discardGoogle(); return }
                result = await session.linkGoogle(idToken: idToken, accessToken: accessToken, nonce: nonce, expectedUserID: userID)
                Self.record(.google, result)
                if result != .linked { discardGoogle() }
            case .canceled, .unavailable: result = nil
            case .noAnchor, .noToken, .failed: result = .failed
            }
        case .email:
            return
        }
        // 흐름이 도는 사이 계정이 바뀌었으면 결과를 버린다 (새 계정의 줄 · 오류에 섞이지 않게)
        guard generation == started, case .signedIn(let now, _) = session.state, now == userID else { return }
        busy = nil
        if let result, let message = SignInCopy.addMessage(for: result, method: method) { messages[method] = message }
    }

    /// 이어 붙인 결과 코드를 로그에 남긴다 (`SignInLog`: 코드만)
    private static func record(_ provider: SignInLog.Provider, _ result: SessionStore.LinkResult?) {
        switch result {
        case .linked: SignInLog.record(provider, .link, .ok)
        case .belongsToAnotherAccount: SignInLog.record(provider, .link, .failed("belongs_to_another_account"))
        case .failed: SignInLog.record(provider, .link, .failed("link"))
        case nil: break
        }
    }

    #if DEBUG
    /// 견본(`-TFSettingsSnapshotSignIn`): 이어 붙이는 중 · 오류 줄을 흐름 없이 보인다
    func debugForce(busy: SignInMethodRow.Method?, messages: [SignInMethodRow.Method: String]) {
        self.busy = busy
        self.messages = messages
    }

    /// 견본 계정의 로그인 방법 · 이메일 (실제 세션을 쓰지 않는다)
    var sampleAccount: (methods: SignInMethods, email: String?)?
    #endif
}

/// 로그인 계정 · Sign Out (이 기기만). 로그아웃이면 로그인 화면, 세션을 읽는 중이면 진행 표시.
/// 방법마다 한 줄(Apple · Google · Email)과 없는 쪽의 Add (`SignInSectionModel`)
struct SettingsSignInSection: View {
    @Environment(SessionStore.self) private var session
    private var add: SignInAddModel { .shared }

    var body: some View {
        switch SettingsWindowSession.access(session) {
        case .signedIn:
            signedIn
        case .signedOut:
            SettingsSignInPanel()
        case .loading:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, minHeight: 80)
        }
    }

    private var methods: SignInMethods {
        #if DEBUG
        if let sample = add.sampleAccount { return sample.methods }
        #endif
        return session.signInMethods
    }

    private var accountEmail: String? {
        #if DEBUG
        if let sample = add.sampleAccount { return sample.email }
        #endif
        return SettingsWindowSession.email(session)
    }

    private var signedIn: some View {
        let model = SignInSectionModel.make(methods: methods, accountEmail: accountEmail, busy: add.busy, messages: add.messages)
        return SettingsSection("Sign-in", footnote: model.footnote) {
            ForEach(model.rows) { row in
                SettingsTrayRow(row.label, detail: row.detail) {
                    switch row.control {
                    case .none:
                        EmptyView()
                    case .signOut:
                        Button("Sign Out") {
                            Task {
                                // 세션이 남아 있을 때 이 기기를 알림에서 뺀다
                                await PushCenter.shared.unregister()
                                await session.signOut()
                            }
                        }
                        .buttonStyle(TFButtonStyle())
                    case .add(let busy):
                        if let method = row.method {
                            AgentActionButton(SignInCopy.addButton, busy: busy, accessibilityName: "\(SignInCopy.addButton) \(row.label)") {
                                Task { await add.add(method, session: session) }
                            }
                        }
                    }
                }
            }
        }
        .onAppear { add.attach(to: session) }
        .task(id: SettingsWindowSession.signedInUserID(session)) { add.follow(userID: SettingsWindowSession.signedInUserID(session)) }
    }
}

/// 로그인 화면 (기존 `SignInView`, S2가 온보딩과 함께 다시 그린다). 로그인이 필요한 탭에서도 쓴다
struct SettingsSignInPanel: View {
    var body: some View {
        SignInView()
            .clipShape(RoundedRectangle(cornerRadius: TFRadius.md, style: .continuous))
    }
}

/// 계정 삭제: 트레이 안에서 확인한다 (Cancel이 먼저, 보조 줄은 무엇이 남고 사라지는지 — 기존 확인 문구에서 막는 두 조각만 뺐다).
/// Apple 재확인이 필요한 계정은 확인 뒤 브라우저 창에서 한 번 더 확인받는다 (`AccountDeletion`). 막지 않는다
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
                    Button("Delete…") { model.confirming = .deleteAccount }
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
