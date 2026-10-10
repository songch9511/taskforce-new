import Auth
import Foundation
import Testing
@testable import TaskforceKit
import TaskforceUI
@testable import Taskforce

/// 0.2.0 설정 창 (S1): 플래그 경계 · 탭 · 저장값 옮기기 · 창 제목 · 보이는 주제 · 연결 줄 · 패널 키
@MainActor
struct SettingsWindowFlagTests {
    /// 플래그가 꺼져 있으면(테스트 실행 · Release 전부) Settings 장면은 기존 사이드바 창이다
    @Test func flagOffSelectsTheExistingSettingsView() {
        #expect(!EdgeShellFlag.isEnabled())
        #expect(MacSettingsRootKind.current == .legacy)
        #expect(MacSettingsRoot().kind == .legacy)
        #expect(MacSettingsRootKind(edgeShell: false) == .legacy)
    }

    /// 격리된 suite에서 켤 때만 새 탭 창
    @Test func flagOnSelectsTheTabbedWindow() throws {
        let name = "dev.taskforcelabs.tests.settings-window.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(MacSettingsRootKind(edgeShell: EdgeShellFlag.isEnabled(defaults)) == .legacy)
        defaults.set(true, forKey: EdgeShellFlag.key)
        #expect(MacSettingsRootKind(edgeShell: EdgeShellFlag.isEnabled(defaults)) == .window)
        #expect(MacSettingsRoot(kind: .window).kind == .window)
    }
}

struct SettingsWindowTabTests {
    /// 디자인 순서 그대로: Account · Connections · Execution · Reports · Shortcuts, Lucide 아이콘
    @Test func tabsFollowTheDesignOrder() {
        #expect(SettingsWindowTab.allCases.map(\.title) == ["Account", "Connections", "Execution", "Reports", "Shortcuts"])
        #expect(SettingsWindowTab.allCases.map(\.icon.rawValue) == ["circle-user", "plug", "shield-check", "bell", "keyboard"])
    }

    /// 기존 사이드바가 저장한 값도 받는다 (`settings.tab`). 없음 · 모르는 값 · 자리가 없는 페이지는 첫 탭
    @Test(arguments: [
        (nil, SettingsWindowTab.account),
        ("account", .account),
        ("about", .account),
        ("usage", .account),
        ("taskList", .account),
        ("connections", .connections),
        ("ai", .connections),
        ("keyboardShortcuts", .shortcuts),
        ("shortcut", .shortcuts),
        ("execution", .execution),
        ("reports", .reports),
        ("shortcuts", .shortcuts),
        ("general", .account),
        ("unknown", .account),
        ("", .account),
    ] as [(String?, SettingsWindowTab)])
    func storedValueMapsToATab(stored: String?, tab: SettingsWindowTab) {
        #expect(SettingsWindowTab.tab(stored: stored) == tab)
    }

    /// 탭이 적는 값은 다시 같은 탭으로, 기존 창이 읽어도 깨지지 않는다 (아는 값은 같은 페이지, 새 탭은 기존 기본 Connections)
    @Test func storedValuesRoundTripAndStayReadableByTheOldWindow() {
        for tab in SettingsWindowTab.allCases {
            #expect(SettingsWindowTab.tab(stored: tab.storedValue) == tab)
        }
        #expect(MacSettingsTab.page(stored: SettingsWindowTab.account.storedValue) == .account)
        #expect(MacSettingsTab.page(stored: SettingsWindowTab.connections.storedValue) == .connections)
        #expect(MacSettingsTab.page(stored: SettingsWindowTab.shortcuts.storedValue) == .keyboardShortcuts)
        #expect(MacSettingsTab.page(stored: SettingsWindowTab.execution.storedValue) == .connections)
        #expect(MacSettingsTab.page(stored: SettingsWindowTab.reports.storedValue) == .connections)
    }

    /// `SettingsOpener.open(_:)`은 기존 탭 값을 적는다: More › Settings → Account, More › Connections · 재연결 알림 → Connections
    @Test func openerValuesLandOnTheRightTab() {
        #expect(SettingsWindowTab.tab(stored: MacSettingsTab.account.rawValue) == .account)
        #expect(SettingsWindowTab.tab(stored: MacSettingsTab.connections.rawValue) == .connections)
        for tab in MacSettingsTab.allCases {
            // 어떤 기존 값도 이 창의 탭 하나로 간다 (깨지지 않는다)
            #expect(SettingsWindowTab.allCases.contains(SettingsWindowTab.tab(stored: tab.rawValue)))
        }
    }
}

@MainActor
struct SettingsWindowModelTests {
    @Test func titleIsTheTabOrTheOpenDetail() {
        let model = SettingsWindowModel()
        #expect(model.title(on: .connections) == "Connections")
        model.open(.privacy)
        #expect(model.title(on: .connections) == "Privacy & AI Data")
        // 다른 탭에는 이 상세가 보이지 않는다 (상세는 탭을 더하지 않는다)
        #expect(model.title(on: .account) == "Account")
        #expect(model.detail(on: .account) == nil)
        model.open(.connection(.google))
        #expect(model.title(on: .connections) == "Google")
        model.open(.connection(.gmail))
        #expect(model.title(on: .connections) == "Gmail")
        model.close()
        #expect(model.title(on: .connections) == "Connections")
    }

    /// 확인은 한 번에 하나: 상세를 열거나 닫으면(Back · 탭 바꾸기 · 창 밖에서 열기) 닫힌다
    @Test func navigationClosesAnOpenConfirmation() {
        let model = SettingsWindowModel()
        model.confirming = .deleteAccount
        model.open(.connection(.slack))
        #expect(model.confirming == nil)
        model.confirming = .disconnect(.slack)
        model.close()
        #expect(model.confirming == nil)
        #expect(model.detail == nil)
    }
}

struct SettingsProfileFieldTests {
    static let profile = Profile(displayName: "Alex Kim", aliases: ["Alex", "AK"], emails: ["alex@example.com"], aiConsentAt: nil, reportsConsent: false)

    /// 저장할 때와 같은 다듬기로 비교한다: 공백 · 같은 별칭은 바뀐 것이 아니다 (손대지 않은 칸은 새 프로필을 따라간다)
    @Test func untouchedFieldsMatchTheirProfile() {
        #expect(ProfileDraft.matches(name: "Alex Kim", aliases: "Alex, AK", profile: Self.profile))
        #expect(ProfileDraft.matches(name: "  Alex Kim ", aliases: "Alex,AK, ", profile: Self.profile))
        #expect(ProfileDraft.matches(name: "Alex Kim", aliases: "Alex, AK, Alex Kim", profile: Self.profile))
    }

    /// 이름 · 별칭을 바꾸거나 지우면 저장할 것이 있다
    @Test func editedFieldsDiffer() {
        #expect(!ProfileDraft.matches(name: "Alex", aliases: "Alex, AK", profile: Self.profile))
        #expect(!ProfileDraft.matches(name: "Alex Kim", aliases: "Alex", profile: Self.profile))
        #expect(!ProfileDraft.matches(name: "", aliases: "Alex, AK", profile: Self.profile))
    }
}

/// 손으로 응답하는 PUT /profile: 요청을 받아 두고, 테스트가 차례로 답한다 (응답이 늦는 경우).
/// 요청마다 그때 로그인해 있던 계정을 적는다 (`writes`, 서버는 그 계정의 토큰으로 쓴다)
@MainActor
final class FakeProfileServer {
    private(set) var requests: [String] = []
    private(set) var writes: [(account: UUID?, name: String)] = []
    private var waiting: [CheckedContinuation<ProfileSaveOutcome, Never>] = []
    private let accounts: ProfileTestAccounts?

    init(accounts: ProfileTestAccounts? = nil) {
        self.accounts = accounts
    }

    var save: ProfileDraft.Save {
        { [self] name, _ in
            await withCheckedContinuation { continuation in
                requests.append(name)
                writes.append((accounts?.current, name))
                waiting.append(continuation)
            }
        }
    }

    /// 가장 오래 기다린 요청에 답하고, 그 뒤 이어지는 일(다시 저장)이 돌게 한다
    func respond(_ outcome: ProfileSaveOutcome) async {
        guard !waiting.isEmpty else {
            Issue.record("No profile request is waiting")
            return
        }
        waiting.removeFirst().resume(returning: outcome)
        await settle()
    }

    func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }
}

/// 실제 `SessionStore`를 이 기기 저장소만으로 로그인 · 로그아웃한다 (인증 서버 · 네트워크 없음, `apply`로 이벤트를 넣는다)
@MainActor
final class ProfileTestAccounts {
    private let storage = ProfileTestAuthStorage()
    let session: SessionStore

    init() {
        let auth = AuthClient(
            url: URL(string: "https://profile-boundary.invalid/auth/v1")!, localStorage: storage,
            fetch: { _ in
                Issue.record("Test must not contact an auth server")
                throw URLError(.badURL)
            },
            autoRefreshToken: false
        )
        session = SessionStore(auth: auth)
    }

    convenience init(signedIn userID: UUID) throws {
        self.init()
        try signIn(userID)
    }

    var current: UUID? {
        if case .signedIn(let userID, _) = session.state { userID } else { nil }
    }

    func signIn(_ userID: UUID) throws {
        let user = User(id: userID, appMetadata: [:], userMetadata: [:], aud: "authenticated", email: "\(userID.uuidString)@example.com",
                        createdAt: Date(), updatedAt: Date())
        let value = Session(accessToken: "access-\(userID)", tokenType: "bearer", expiresIn: 3600,
                            expiresAt: Date().addingTimeInterval(3600).timeIntervalSince1970, refreshToken: "refresh-\(userID)", user: user)
        try storage.store(key: "session", value: AuthClient.Configuration.jsonEncoder.encode(value))
        session.apply(event: .signedIn, session: value)
    }

    func signOut() {
        storage.clear()
        session.apply(event: .signedOut, session: nil)
    }
}

private final class ProfileTestAuthStorage: AuthLocalStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?

    func store(key: String, value: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        data = value
    }

    func retrieve(key: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return data
    }

    func remove(key: String) throws {}

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        data = nil
    }
}

/// Account › Profile 저장 흐름 (모델 · 흐름 테스트: 실제 포인터 · 키보드 · VoiceOver 확인이 아니다).
/// 뷰는 Return · 다른 칸으로 옮김 · 탭 · 창을 떠남(onDisappear)에 `requestSave`, 창이 보일 때 · 프로필이 바뀔 때 `follow`를 부른다.
/// 앱처럼 실제 `SessionStore`에 붙인다(`bind`, 앱은 실행할 때 붙인다)
@MainActor
struct SettingsProfileSaveFlowTests {
    static let user = UUID()

    static func profile(_ name: String) -> Profile {
        Profile(displayName: name, aliases: [], emails: ["alex@example.com"], aiConsentAt: nil, reportsConsent: false)
    }

    /// A → B 저장(응답 늦음) → 칸을 A로 되돌림 → 다른 칸으로 옮김: B가 저장된 뒤 A를 다시 저장한다
    @Test func revertedDraftIsSavedAfterBlur() async throws {
        let accounts = try ProfileTestAccounts(signedIn: Self.user)
        let server = FakeProfileServer(accounts: accounts)
        let draft = ProfileDraft()
        draft.bind(to: accounts.session)
        draft.follow(userID: Self.user, profile: Self.profile("Alex"))
        draft.name = "Bea"
        draft.requestSave(using: server.save)
        await server.settle()
        #expect(server.requests == ["Bea"])
        draft.name = "Alex"
        draft.requestSave(using: server.save)
        await server.respond(.saved(Self.profile("Bea")))
        #expect(server.requests == ["Bea", "Alex"])
        await server.respond(.saved(Self.profile("Alex")))
        #expect(draft.baseline == Self.profile("Alex"))
        #expect(draft.name == "Alex" && !draft.isDirty && !draft.saving)
    }

    /// 같은 순서에서 칸을 되돌린 뒤 탭을 옮김(onDisappear) · 돌아옴(follow), 그사이 저장소가 B를 먼저 받음: 칸은 A로 남고 A를 저장한다
    @Test func revertedDraftIsSavedAfterTabSwitch() async throws {
        let accounts = try ProfileTestAccounts(signedIn: Self.user)
        let server = FakeProfileServer(accounts: accounts)
        let draft = ProfileDraft()
        draft.bind(to: accounts.session)
        draft.follow(userID: Self.user, profile: Self.profile("Alex"))
        draft.name = "Bea"
        draft.requestSave(using: server.save)
        await server.settle()
        draft.name = "Alex"
        draft.requestSave(using: server.save)
        draft.follow(userID: Self.user, profile: Self.profile("Alex"))
        #expect(draft.name == "Alex")
        // `AccountStore.saveProfile`은 답하기 전에 저장된 프로필을 둔다 (onChange → follow)
        draft.follow(userID: Self.user, profile: Self.profile("Bea"))
        #expect(draft.name == "Alex")
        await server.respond(.saved(Self.profile("Bea")))
        #expect(server.requests == ["Bea", "Alex"])
        await server.respond(.saved(Self.profile("Alex")))
        draft.follow(userID: Self.user, profile: Self.profile("Alex"))
        #expect(draft.name == "Alex" && draft.baseline == Self.profile("Alex") && !draft.isDirty)
    }

    /// 같은 순서에서 칸을 되돌리고 창을 닫음(onDisappear, 다시 보이지 않음): 응답 뒤 A를 저장하고, 다시 열면 A
    @Test func revertedDraftIsSavedAfterWindowClose() async throws {
        let accounts = try ProfileTestAccounts(signedIn: Self.user)
        let server = FakeProfileServer(accounts: accounts)
        let draft = ProfileDraft()
        draft.bind(to: accounts.session)
        draft.follow(userID: Self.user, profile: Self.profile("Alex"))
        draft.name = "Bea"
        draft.requestSave(using: server.save)
        await server.settle()
        draft.name = "Alex"
        draft.requestSave(using: server.save)
        await server.respond(.saved(Self.profile("Bea")))
        #expect(server.requests == ["Bea", "Alex"])
        await server.respond(.saved(Self.profile("Alex")))
        draft.follow(userID: Self.user, profile: Self.profile("Alex"))
        #expect(draft.name == "Alex" && !draft.isDirty && draft.message == nil)
    }

    /// 응답을 기다리는 사이 칸을 바꾸기만 하고 떠나지 않아도, 응답 뒤 지금 칸과 다시 맞춘다
    @Test func responseReconcilesWithTheCurrentDraft() async throws {
        let accounts = try ProfileTestAccounts(signedIn: Self.user)
        let server = FakeProfileServer(accounts: accounts)
        let draft = ProfileDraft()
        draft.bind(to: accounts.session)
        draft.follow(userID: Self.user, profile: Self.profile("Alex"))
        draft.name = "Bea"
        draft.requestSave(using: server.save)
        await server.settle()
        draft.name = "Cy"
        await server.respond(.saved(Self.profile("Bea")))
        #expect(server.requests == ["Bea", "Cy"])
        await server.respond(.saved(Self.profile("Cy")))
        #expect(!draft.isDirty && !draft.saving)
    }

    /// 늦게 실패하고 사용자가 탭을 떠났다 돌아와도 칸과 오류가 남는다. 다시 떠나면 다시 보낸다
    @Test func failedSaveKeepsDraftAndErrorAcrossTabSwitch() async throws {
        let accounts = try ProfileTestAccounts(signedIn: Self.user)
        let server = FakeProfileServer(accounts: accounts)
        let draft = ProfileDraft()
        draft.bind(to: accounts.session)
        draft.follow(userID: Self.user, profile: Self.profile("Alex"))
        draft.name = "Bea"
        draft.requestSave(using: server.save)
        await server.settle()
        await server.respond(.failed("You're offline. Try again when you're connected."))
        #expect(draft.name == "Bea" && draft.isDirty)
        #expect(draft.message == "You're offline. Try again when you're connected.")
        // 탭으로 돌아옴: 저장소의 프로필은 여전히 A
        draft.follow(userID: Self.user, profile: Self.profile("Alex"))
        #expect(draft.name == "Bea" && draft.message == "You're offline. Try again when you're connected.")
        draft.requestSave(using: server.save)
        await server.settle()
        #expect(server.requests == ["Bea", "Bea"])
        await server.respond(.saved(Self.profile("Bea")))
        #expect(draft.message == nil && !draft.isDirty)
    }

    /// 오류 글이 없는 실패도 말로 보인다. 실패 뒤에는 다시 저장하라는 뜻이 있을 때만 한 번 더 보낸다 (끝없이 보내지 않는다)
    @Test func failureRetriesOnlyWhenAskedAgain() async throws {
        let accounts = try ProfileTestAccounts(signedIn: Self.user)
        let server = FakeProfileServer(accounts: accounts)
        let draft = ProfileDraft()
        draft.bind(to: accounts.session)
        draft.follow(userID: Self.user, profile: Self.profile("Alex"))
        draft.name = "Bea"
        draft.requestSave(using: server.save)
        await server.settle()
        await server.respond(.failed(nil))
        #expect(draft.message == ProfileDraft.failedMessage)
        #expect(server.requests == ["Bea"])
        draft.name = "Cy"
        draft.requestSave(using: server.save)
        await server.settle()
        draft.requestSave(using: server.save)
        await server.respond(.failed(nil))
        #expect(server.requests == ["Bea", "Cy", "Cy"])
        await server.respond(.failed(nil))
        #expect(server.requests == ["Bea", "Cy", "Cy"])
        #expect(draft.name == "Cy" && draft.isDirty && !draft.saving)
    }

    /// 계정이 바뀌면 칸을 새 계정으로 채우고, 전 계정의 늦은 응답은 버린다
    @Test func accountSwitchDropsTheOldDraftAndLateResponse() async throws {
        let accounts = try ProfileTestAccounts(signedIn: Self.user)
        let server = FakeProfileServer(accounts: accounts)
        let draft = ProfileDraft()
        draft.bind(to: accounts.session)
        draft.follow(userID: Self.user, profile: Self.profile("Alex"))
        draft.name = "Bea"
        draft.requestSave(using: server.save)
        await server.settle()
        let other = UUID()
        draft.follow(userID: other, profile: Self.profile("Dana"))
        #expect(draft.name == "Dana" && !draft.saving)
        await server.respond(.saved(Self.profile("Bea")))
        #expect(draft.baseline == Self.profile("Dana") && draft.name == "Dana")
        #expect(server.requests == ["Bea"])
    }

    /// 빈 이름은 보내지 않고 고칠 길을 말한다
    @Test func emptyNameIsNotSent() async throws {
        let accounts = try ProfileTestAccounts(signedIn: Self.user)
        let server = FakeProfileServer(accounts: accounts)
        let draft = ProfileDraft()
        draft.bind(to: accounts.session)
        draft.follow(userID: Self.user, profile: Self.profile("Alex"))
        draft.name = "  "
        draft.requestSave(using: server.save)
        await server.settle()
        #expect(server.requests.isEmpty)
        #expect(draft.message == ProfileDraft.emptyNameMessage)
    }
}

/// 프로필 칸의 계정 경계 (모델 · 픽스처 테스트: 실제 로그인 · 포인터 · 키보드 · VoiceOver 확인이 아니다).
/// Account 화면이 없는 동안(다른 탭 · 창을 닫음) 계정이 떠나거나 바뀌어도, 전 계정의 칸 · 오류 · 남은 저장은 지워지고
/// 다른 계정 · 다른 세션으로는 하나도 쓰지 않는다. 여기서는 `follow`를 다른 계정으로 부르지 않는다 (화면이 없는 실제 길)
@MainActor
struct SettingsProfileAccountBoundaryTests {
    static let u = UUID()
    static let v = UUID()

    static func profile(_ name: String) -> Profile {
        SettingsProfileSaveFlowTests.profile(name)
    }

    /// U: A → B 저장(응답 늦음) → 칸을 C로 바꾸고 탭을 떠남(저장 뜻이 남음)
    static func pendingEdit() throws -> (ProfileTestAccounts, FakeProfileServer, ProfileDraft) {
        let accounts = try ProfileTestAccounts(signedIn: u)
        let server = FakeProfileServer(accounts: accounts)
        let draft = ProfileDraft()
        draft.bind(to: accounts.session)
        draft.follow(userID: u, profile: profile("Alex"))
        draft.name = "Bea"
        draft.requestSave(using: server.save)
        return (accounts, server, draft)
    }

    static func expectCleared(_ draft: ProfileDraft) {
        #expect(draft.name.isEmpty && draft.aliases.isEmpty)
        #expect(draft.baseline == nil && draft.message == nil && !draft.saving && !draft.isDirty)
    }

    /// 다른 탭에 있는 동안 U → V. U의 늦은 응답이 실패로 와도(저장소가 버린 응답) V로 C를 보내지 않는다
    @Test func delayedFailureAfterSwitchingAccountsOnAnotherTabWritesNothingForV() async throws {
        let (accounts, server, draft) = try Self.pendingEdit()
        await server.settle()
        draft.name = "Cy"
        draft.requestSave(using: server.save)
        accounts.signOut()
        try accounts.signIn(Self.v)
        Self.expectCleared(draft)
        await server.respond(.failed(nil))
        await server.settle()
        #expect(server.writes.map(\.account) == [Self.u])
        #expect(server.requests == ["Bea"])
        Self.expectCleared(draft)
    }

    /// 창을 닫은 동안 U → V. U의 늦은 응답이 성공으로 와도 V로 다시 맞추지 않고, 칸은 V의 것이 아니다
    @Test func delayedSuccessAfterSwitchingAccountsWithTheWindowClosedWritesNothingForV() async throws {
        let (accounts, server, draft) = try Self.pendingEdit()
        await server.settle()
        draft.name = "Cy"
        draft.requestSave(using: server.save)
        // 다른 계정으로 바로 전환 (로그아웃 이벤트 없이)
        try accounts.signIn(Self.v)
        await server.respond(.saved(Self.profile("Bea")))
        await server.settle()
        #expect(server.writes.map(\.account) == [Self.u])
        Self.expectCleared(draft)
        // 창을 다시 열면 V의 프로필로 채운다
        draft.follow(userID: Self.v, profile: Self.profile("Dana"))
        #expect(draft.name == "Dana" && !draft.isDirty && draft.message == nil)
    }

    /// 같은 사용자가 로그아웃했다 다시 로그인해도 다른 세션이다: 전 세션의 칸 · 남은 저장은 보내지 않는다
    @Test func sameUserSigningBackInDropsTheOldSessionsDraft() async throws {
        let (accounts, server, draft) = try Self.pendingEdit()
        await server.settle()
        draft.name = "Cy"
        draft.requestSave(using: server.save)
        accounts.signOut()
        try accounts.signIn(Self.u)
        await server.respond(.failed(nil))
        await server.settle()
        #expect(server.requests == ["Bea"])
        Self.expectCleared(draft)
        // 새 세션에서 Account를 열고 고치면 그대로 저장된다
        draft.follow(userID: Self.u, profile: Self.profile("Alex"))
        draft.name = "Dee"
        draft.requestSave(using: server.save)
        await server.settle()
        #expect(server.requests == ["Bea", "Dee"])
        #expect(server.writes.allSatisfy { $0.account == Self.u })
    }

    /// 실패 오류와 쓰던 칸은 Account 화면이 없어도 로그아웃하면 지워진다. 그 뒤 V로 쓰는 것은 없다
    @Test func signOutClearsTheDraftAndErrorWithoutTheAccountView() async throws {
        let (accounts, server, draft) = try Self.pendingEdit()
        await server.settle()
        await server.respond(.failed("You're offline. Try again when you're connected."))
        #expect(draft.message != nil && draft.name == "Bea")
        accounts.signOut()
        Self.expectCleared(draft)
        try accounts.signIn(Self.v)
        draft.requestSave(using: server.save)
        await server.settle()
        #expect(server.writes.map(\.account) == [Self.u])
    }

    /// 저장을 시작한 직후(보내기 전) 계정이 떠나면 보내지 않는다: 보낼 때마다 주인 계정 · 세션을 다시 본다
    @Test func queuedSaveIsNotSentAfterTheAccountLeaves() async throws {
        let (accounts, server, draft) = try Self.pendingEdit()
        accounts.signOut()
        await server.settle()
        #expect(server.writes.isEmpty)
        Self.expectCleared(draft)
    }
}

struct SettingsWindowSectionTests {
    @Test func accountShowsProfileSignInDeleteAboutAndLinks() {
        #expect(SettingsWindowTab.account.sections(.signedIn) == [.profile, .signIn, .remembered, .deleteAccount, .about, .legal])
        // 로그아웃 · 읽는 중: 로그인 자리 · About · 링크 (프로필 · 삭제는 없다)
        #expect(SettingsWindowTab.account.sections(.signedOut) == [.signIn, .about, .legal])
        #expect(SettingsWindowTab.account.sections(.loading) == [.signIn, .about, .legal])
    }

    @Test func connectionsOpensWithAIProcessingThenSources() {
        #expect(SettingsWindowTab.connections.sections(.signedIn) == [.aiProcessing, .sources, .moreServices])
        #expect(SettingsWindowTab.connections.sections(.signedOut) == [.signInRequired])
        #expect(SettingsWindowTab.execution.sections(.signedIn) == [.runWithAI])
        #expect(SettingsWindowTab.execution.sections(.loading) == [.signInRequired])
    }

    @Test func reportsAndShortcutsDoNotNeedSignIn() {
        for access in [SettingsWindowAccess.signedIn, .signedOut, .loading] {
            #expect(SettingsWindowTab.reports.sections(access) == [.notifications])
            #expect(SettingsWindowTab.shortcuts.sections(access) == [.launcher, .panelKeys])
        }
    }

    /// 연결되지 않은 것은 보이지 않는다 (소유자 규칙): 어느 탭 · 로그인 상태에서도 숨긴 주제의 제목이 없다
    @Test func gatedTopicsStayHidden() {
        let hidden = Set(SettingsWindowHidden.allCases.map(\.rawValue))
        #expect(hidden.isSuperset(of: [
            "Plan & usage", "Usage & Credits", "Subscription", "Your agents", "Default for new work",
            "Spending outside Taskforce", "Delivery", "Task List",
        ]))
        for tab in SettingsWindowTab.allCases {
            for access in [SettingsWindowAccess.signedIn, .signedOut, .loading] {
                let titles = Set(tab.sections(access).compactMap(\.title))
                #expect(titles.isDisjoint(with: hidden), "\(tab) \(access)")
            }
        }
        #expect(SettingsWindowHidden.yourAgents.tab == .connections)
        #expect(SettingsWindowHidden.planAndUsage.tab == .account)
        #expect(SettingsWindowHidden.externalCosts.tab == .execution)
        #expect(SettingsWindowHidden.reportsDelivery.tab == .reports)
        #expect(SettingsWindowHidden.allCases.allSatisfy { !$0.reason.isEmpty })
    }

    /// 제목 없는 주제는 앞 주제에 이어진다 (삭제는 Sign-in 아래, More services는 Sources 아래, 링크는 About 아래)
    @Test func untitledTopicsFollowATitledOne() {
        for tab in SettingsWindowTab.allCases {
            let sections = tab.sections(.signedIn)
            for (index, section) in sections.enumerated() where section.title == nil && section != .signInRequired {
                #expect(index > 0, "\(section)")
            }
        }
    }
}

@MainActor
struct SettingsConnectionLineTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func record(_ provider: ConnectionProvider, name: String? = nil, status: ConnectionStatus = .active, synced: Date? = nil) -> ConnectionRecord {
        ConnectionRecord(id: UUID(), provider: provider.rawValue, displayName: name, status: status, lastSyncedAt: synced, lastError: nil)
    }

    static func line(
        _ provider: ConnectionProvider, _ state: ConnectionState, syncing: Bool = false, comingSoon: Bool = false, connecting: Bool = false
    ) -> SettingsConnectionLine {
        SettingsConnectionLine.make(provider: provider, state: state, syncing: syncing, comingSoon: comingSoon, connecting: connecting, now: now)
    }

    @Test func notConnectedServicesOfferConnect() {
        let notion = Self.line(.notion, .notConnected)
        #expect(notion.name == "Notion")
        #expect(notion.aside == nil)
        #expect(notion.detail == "Not connected")
        #expect(notion.action == .connect)
        #expect(!notion.attention && !notion.opens)
        // Google은 이름 + 범위, Gmail은 Beta 안내
        let google = Self.line(.google, .notConnected)
        #expect(google.name == "Google" && google.aside == "Calendar · Meet")
        #expect(Self.line(.gmail, .notConnected).detail == "Not connected · Beta · Reconnect every 7 days")
        #expect(Self.line(.slack, .notConnected).name == "Slack")
    }

    @Test func connectedServicesShowTheAccountAndLastSync() {
        let synced = Self.now.addingTimeInterval(-600)
        let notion = Self.line(.notion, .connected(Self.record(.notion, name: "Acme", synced: synced)))
        #expect(notion.aside == "Acme")
        #expect(notion.detail == "Synced 10 min ago")
        #expect(notion.action == nil && notion.opens && !notion.attention)
        #expect(Self.line(.notion, .connected(Self.record(.notion))).detail == "Connected")
        // Google 계정은 범위 대신 상태 뒤에
        let google = Self.line(.google, .connected(Self.record(.google, name: "alex@example.com", synced: synced)))
        #expect(google.aside == "Calendar · Meet")
        #expect(google.detail == "Synced 10 min ago · alex@example.com")
        #expect(Self.line(.notion, .connected(Self.record(.notion)), syncing: true).detail == "Syncing…")
    }

    /// 사용자가 할 일이 있는 상태는 굵게, Reconnect는 잉크 버튼 (색은 더하지 않는다)
    @Test func attentionStatesAreWordsAndOneAction() {
        let reconnect = Self.line(.gmail, .needsReconnect(Self.record(.gmail, status: .reauth)))
        #expect(reconnect.detail == "Reconnect to keep syncing · Beta · Reconnect every 7 days")
        #expect(reconnect.attention && reconnect.action == .reconnect && reconnect.opens)
        let failed = Self.line(.slack, .syncFailed(Self.record(.slack, status: .error)))
        #expect(failed.detail == "Last sync failed")
        #expect(failed.attention && failed.action == nil && failed.opens)
        // 실패했어도 다시 동기화 중이면 진행 중이라고 쓴다
        let retrying = Self.line(.slack, .syncFailed(Self.record(.slack, status: .error)), syncing: true)
        #expect(retrying.detail == "Syncing…" && !retrying.attention)
    }

    @Test func connectingAndComingSoon() {
        let waiting = Self.line(.notion, .notConnected, connecting: true)
        #expect(waiting.detail == "Waiting for Notion…" && waiting.busy && waiting.action == .connect)
        let soon = Self.line(.slack, .notConnected, comingSoon: true)
        #expect(soon.detail == "Coming soon" && soon.action == nil)
    }

    /// Disconnect 확인은 무엇이 멈추고 무엇이 남는지 말한다 (Slack은 원문도 지운다)
    @Test func disconnectSaysWhatStays() {
        #expect(SettingsConnectionLine.disconnectDetail(.gmail) == "Taskforce stops reading Gmail. Tasks already found stay.")
        #expect(SettingsConnectionLine.disconnectDetail(.slack) == "Taskforce stops reading Slack. Slack messages are removed from Taskforce. Tasks stay.")
        #expect(SettingsConnectionLine.disconnectDetail(.google) == "Taskforce stops reading Google. Tasks already found stay.")
    }

    @Test func moreServicesNamesWhatComesLater() {
        #expect(SettingsConnectionLine.comingLater == "Coming later: Microsoft 365, Zoom, GitHub, Linear and Jira.")
    }

    /// Sync Now는 연결이 살아 있을 때만 (다시 연결이 필요하면 Reconnect · Disconnect만)
    @Test func syncNeedsALiveConnection() {
        #expect(SettingsConnectionDetail.canSync(.connected(Self.record(.notion))))
        #expect(SettingsConnectionDetail.canSync(.syncFailed(Self.record(.notion, status: .error))))
        #expect(!SettingsConnectionDetail.canSync(.needsReconnect(Self.record(.notion, status: .revoked))))
        #expect(!SettingsConnectionDetail.canSync(.notConnected))
    }
}

@MainActor
struct SettingsWindowReadOnlyValueTests {
    /// Edge 패널에서 지금 동작하는 키만 (⌘2 All work · ⌘3 Chats · ⌘N New chat). ⌘1 · 1–3은 그 화면이 생길 때
    @Test func panelKeysAreOnlyTheOnesThatWork() {
        let rows = SettingsPanelKeys.rows
        #expect(rows.map(\.label) == ["All work", "Chats", "New chat"])
        #expect(rows.map(\.keys) == [["⌘", "2"], ["⌘", "3"], ["⌘", "N"]])
        #expect(SettingsPanelKeys.keyCaps("⌥Space") == ["⌥", "Space"])
        #expect(SettingsPanelKeys.keyCaps("⇧⌘K") == ["⇧", "⌘", "K"])
    }

    /// Run with AI: 모름은 모름으로 (읽는 중 · 읽기 실패를 "Not available"로 쓰지 않는다)
    @Test func runWithAIAvailabilityStatesUncertaintyExactly() {
        let summary = CreditsSummary(available: 0, reserved: 0, rateVersion: "c3-v1")
        #expect(SettingsRunWithAISection.availability(.available(summary, checkedAt: Date()), failed: false) == "Available")
        #expect(SettingsRunWithAISection.availability(.unavailable, failed: false) == "Not available")
        #expect(SettingsRunWithAISection.availability(.unknown, failed: false) == "Checking…")
        #expect(SettingsRunWithAISection.availability(.unknown, failed: true) == "Couldn't check")
    }

    @Test func notificationPermissionIsWords() {
        #expect(SettingsNotificationsSection.permission(nil) == "Checking…")
        #expect(SettingsNotificationsSection.permission(.allowed) == "Allowed")
        #expect(SettingsNotificationsSection.permission(.denied) == "Off")
        #expect(SettingsNotificationsSection.permission(.notDetermined) == "Not asked yet")
    }
}
