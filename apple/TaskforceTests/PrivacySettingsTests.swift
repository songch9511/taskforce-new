import Auth
import Foundation
import Supabase
import Testing
@testable import Taskforce
@testable import TaskforceKit

/// 설정 Privacy & AI Data (U2 Mac PR4, D9a-1 동의 경로)
struct PrivacySettingsTests {
    /// `Use AI on new sources`: 켜기 → 동의 화면(Allow를 눌러야 동의), 끄기 → 철회 확인. 같은 상태 · 동의 상태를 모르면 아무것도 하지 않는다
    @Test(arguments: [
        (true, false, true, ConsentSwitch.prompt),
        (false, true, true, .confirmWithdraw),
        (true, true, true, .none),
        (false, false, true, .none),
        (true, false, false, .none),
        (false, true, false, .none),
    ])
    func switchOpensPromptOrWithdrawConfirmation(on: Bool, hasConsent: Bool, known: Bool, expected: ConsentSwitch) {
        #expect(ConsentSwitch.change(to: on, hasConsent: hasConsent, known: known) == expected)
    }

    /// 철회 경로는 Mac · iPhone 모두 처리방침 4장 · 11장과 같은 "Settings > Privacy & AI Data"
    @Test func withdrawPathMatchesThePolicy() {
        #expect(ConsentDetails.settingsPath == "Settings > Privacy & AI Data")
        #expect(ConsentDetails.withdraw.contains(ConsentDetails.settingsPath))
    }

    /// D9a-1 초안 4장이 요구하는 것이 동의 문구에 빠지지 않는다 (문장을 고쳐도 이 내용은 남아야 한다, PR4 본문 대조표)
    @Test func consentCopyCoversTheD9a1Items() {
        // 132: 초안 목적 · 받는 사람에게 보내지 않음
        #expect(ConsentDetails.purpose.contains("write drafts you start"))
        #expect(ConsentDetails.purpose.contains("never sent to the people they're for"))
        // 140: Ask에 초안 기록
        #expect(ConsentDetails.sent.contains("including draft records"))
        // 141: 초안 때 보내는 것, Slack 원문 · 인용 제외와 Slack 할 일 자체 값
        for item in ["Your request", "title, status, owner, due date, and counterpart", "nearby source text", "earlier drafts"] {
            #expect(ConsentDetails.drafts.contains(item), "\(item)")
        }
        #expect(ConsentDetails.drafts.contains("Text and quotes from Slack are left out"))
        #expect(ConsentDetails.drafts.contains("a task from Slack still sends"))
        // 152 · 153: 동의 없으면 처리 · 초안 없음, 진행 중 초안은 다음 AI 요청 전에 멈춤, 있던 것은 남음
        #expect(ConsentDetails.withdraw.contains("doesn't write drafts"))
        #expect(ConsentDetails.withdraw.contains("stops before its next AI request"))
        #expect(ConsentDetails.withdraw.contains("Existing tasks and drafts stay"))
        // 154: Hand off to AI는 보내지 않음
        #expect(ConsentDetails.sent.contains("Hand off to AI"))
    }
}

/// 설정 사이드바의 Usage & Credits 가용성: 로그인 상태 × `RunStore.credits`
struct SettingsExecutionTests {
    static let summary = CreditsSummary(available: 0, reserved: 0, rateVersion: "c3-v1")

    @Test func signedOutIsUnavailable() {
        #expect(MacSettingsTab.Execution(signedIn: false, credits: .available(Self.summary, checkedAt: Date())) == .unavailable)
        #expect(MacSettingsTab.Execution(signedIn: false, credits: .unknown) == .unavailable)
    }

    /// 앱을 막 열어 세션을 읽는 중이거나 credits를 아직 모르면 모름 (저장된 Usage 페이지를 떨어뜨리지 않는다)
    @Test func loadingSessionOrUnknownCreditsIsUnknown() {
        #expect(MacSettingsTab.Execution(signedIn: nil, credits: .unknown) == .unknown)
        #expect(MacSettingsTab.Execution(signedIn: nil, credits: .unavailable) == .unknown)
        #expect(MacSettingsTab.Execution(signedIn: true, credits: .unknown) == .unknown)
    }

    @Test func signedInFollowsCredits() {
        #expect(MacSettingsTab.Execution(signedIn: true, credits: .unavailable) == .unavailable)
        #expect(MacSettingsTab.Execution(signedIn: true, credits: .available(Self.summary, checkedAt: Date())) == .available)
    }
}

/// D9a-1 "기기 사본": 계정이 이 Mac을 떠나면(로그아웃 · 만료 · 이 기기나 다른 기기에서 계정 삭제) 저장본을 지운다.
/// 다른 기기에서 지운 계정은 이 기기의 다음 API 401 → 인증 서버 `user_not_found` → 이 기기 세션만 지움 → `signedOut`으로 온다
/// (`AuthSessionRaceTests.unauthorizedForADeletedAccountSignsOutThisDeviceAndCleansUp`). 토큰 갱신이 실패해도 SDK가 세션을 지우고 `signedOut`을 보낸다.
/// 여기서는 그 `signedOut`이 Mac 런처가 등록한 정리로 저장본 파일을 지우는지 본다
@Suite(.serialized)
@MainActor
struct DeviceCopyTests {
    @Test func signedOutEventRemovesTheMacSavedCopy() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "saved-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let saved = SavedNowStore(root: root)
        let user = Self.session(userID: UUID())
        let storage = CopyTestStorage(data: try AuthClient.Configuration.jsonEncoder.encode(user))
        let config = AppConfig(
            supabaseURL: URL(string: "https://device-copy.invalid")!, supabaseKey: "test-key", appGroupID: "group.test.taskforce",
            apiBaseURL: URL(string: "https://device-copy-api.invalid")!
        )
        let urlSession = URLSession(configuration: .ephemeral)
        let supabase = SupabaseClient(
            supabaseURL: config.supabaseURL, supabaseKey: config.supabaseKey,
            options: SupabaseClientOptions(
                auth: .init(storage: storage, autoRefreshToken: false, emitLocalSessionAsInitialSession: true),
                global: .init(session: urlSession)
            )
        )
        let session = SessionStore(auth: supabase.auth)
        session.apply(event: .signedIn, session: user)
        let services = AppServices(config: config, supabase: supabase, session: urlSession)
        let model = LauncherModel(session: session, services: services, account: AccountStore(services: services, session: session), saved: saved)
        try saved.save(SavedNow(savedAt: Date(), tasks: [SavedNow.Task(title: "Private title", dueDate: nil, status: .toDo)]), account: user.user.id)
        #expect(saved.load(account: user.user.id) != nil)

        session.apply(event: .signedOut, session: nil)

        #expect(saved.load(account: user.user.id) == nil)
        #expect(model.signedInUserID == nil)
    }

    private static func session(userID: UUID) -> Session {
        let user = User(id: userID, appMetadata: [:], userMetadata: [:], aud: "authenticated", email: "\(userID.uuidString)@example.com",
                        createdAt: Date(), updatedAt: Date())
        return Session(accessToken: "access-\(userID)", tokenType: "bearer", expiresIn: 3600,
                       expiresAt: Date().addingTimeInterval(3600).timeIntervalSince1970, refreshToken: "refresh-\(userID)", user: user)
    }
}

private final class CopyTestStorage: AuthLocalStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?

    init(data: Data) { self.data = data }

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

    /// 저장소 키 정리(옛 키 지우기)에 세션이 지워지지 않게 아무것도 하지 않는다 (`LauncherModelSessionTests`와 같다)
    func remove(key: String) throws {}
}

@MainActor
struct GoogleOnlyAccountDeletionTests {
    @Test func appleLinkedAndUnknownIdentityBlockDeletion() {
        let id = UUID()
        let google = SignInMethods(providers: ["google"], primary: "google")
        for providers: Set<String> in [["apple"], ["apple", "google"], []] {
            let fresh = user(id: id, providers: providers)
            #expect(AccountDeletion.deletionBlocker(fresh: fresh, cached: google, expectedID: id, currentID: id) == AccountDeletion.unavailableMessage)
        }
        #expect(AccountDeletion.deletionBlocker(fresh: user(id: id, providers: ["google"]),
            cached: SignInMethods(providers: ["apple"], primary: "apple"), expectedID: id, currentID: id) == AccountDeletion.unavailableMessage)
    }

    @Test func freshGoogleIdentityPermitsDeletionOnlyForTheSameAccount() {
        let id = UUID()
        let fresh = user(id: id, providers: ["google"])
        let cached = SignInMethods(providers: ["google"], primary: "google")
        #expect(AccountDeletion.deletionBlocker(fresh: fresh, cached: cached, expectedID: id, currentID: id) == nil)
        #expect(AccountDeletion.deletionBlocker(fresh: fresh, cached: cached, expectedID: UUID(), currentID: id) != nil)
        #expect(AccountDeletion.deletionBlocker(fresh: fresh, cached: cached, expectedID: id, currentID: UUID()) != nil)
        #expect(AccountDeletion.deletionBlocker(fresh: fresh, cached: cached, expectedID: id, currentID: nil) != nil)
    }

    @Test func contactAndConfirmationExplainTheBlockedPath() {
        #expect(AccountDeletion.contactURL.absoluteString == "mailto:privacy@taskforcelabs.dev")
        #expect(AccountDeletion.unavailableMessage.contains("have not been deleted"))
        #expect(AccountDeletion.unavailableMessage.contains("privacy@taskforcelabs.dev"))
        #expect(AccountDeletion.confirmationMessage.contains("cannot be deleted here"))
        #expect(!AccountDeletion.confirmationMessage.contains("remove Apple"))
    }

    @Test func switchingAccountsWhileDeletionIsPendingPreservesTheNewAccount() async throws {
        let a = makeSession(id: UUID())
        let b = makeSession(id: UUID())
        let storage = CopyTestStorage(data: try AuthClient.Configuration.jsonEncoder.encode(a))
        let auth = AuthClient(url: URL(string: "https://delete-race.invalid/auth/v1")!, localStorage: storage,
            fetch: { _ in Issue.record("Test must not contact an auth server"); throw URLError(.badURL) }, autoRefreshToken: false)
        let session = SessionStore(auth: auth, googleOnly: true)
        session.apply(event: .signedIn, session: a)
        let pending = PendingDeletion()
        var removed: [UUID] = []
        var googleConnected = true
        var localSignOuts = 0
        let deletion = Task {
            await AccountDeletion.delete(session: session, fetchUser: { a.user },
                deleteOnServer: { await pending.waitForResponse() },
                removeSavedData: { removed.append($0) },
                disconnectGoogle: { googleConnected = false },
                accountDeleted: { localSignOuts += 1; session.apply(event: .signedOut, session: nil) })
        }
        await pending.waitUntilRequested()
        try storage.store(key: "session", value: AuthClient.Configuration.jsonEncoder.encode(b))
        session.apply(event: .signedIn, session: b)
        pending.finish()
        #expect(await deletion.value == nil)
        #expect(removed == [a.user.id])
        #expect(session.state == .signedIn(userID: b.user.id, email: b.user.email))
        #expect(auth.currentSession?.user.id == b.user.id)
        #expect(googleConnected)
        #expect(localSignOuts == 0)
    }

    @Test func deletionOfTheCurrentAccountStillClearsLocalAuthentication() async throws {
        let a = makeSession(id: UUID())
        let storage = CopyTestStorage(data: try AuthClient.Configuration.jsonEncoder.encode(a))
        let session = SessionStore(auth: AuthClient(url: URL(string: "https://delete-race.invalid/auth/v1")!,
            localStorage: storage, autoRefreshToken: false), googleOnly: true)
        session.apply(event: .signedIn, session: a)
        var removed: [UUID] = []
        var disconnected = false
        let result = await AccountDeletion.delete(session: session, fetchUser: { a.user }, deleteOnServer: {},
            removeSavedData: { removed.append($0) }, disconnectGoogle: { disconnected = true },
            accountDeleted: { session.apply(event: .signedOut, session: nil) })
        #expect(result == nil)
        #expect(removed == [a.user.id])
        #expect(disconnected)
        #expect(session.state == .signedOut)
    }

    private func makeSession(id: UUID) -> Session {
        Session(accessToken: "access-\(id)", tokenType: "bearer", expiresIn: 3600,
            expiresAt: Date().addingTimeInterval(3600).timeIntervalSince1970, refreshToken: "refresh-\(id)",
            user: user(id: id, providers: ["google"]))
    }

    private func user(id: UUID, providers: Set<String>) -> User {
        User(id: id, appMetadata: ["providers": .array(providers.map { .string($0) })], userMetadata: [:],
            aud: "authenticated", createdAt: Date(), updatedAt: Date())
    }
}

@MainActor
private final class PendingDeletion {
    private var response: CheckedContinuation<Void, Never>?
    private var requested: CheckedContinuation<Void, Never>?

    func waitForResponse() async {
        await withCheckedContinuation { continuation in
            response = continuation
            requested?.resume()
            requested = nil
        }
    }

    func waitUntilRequested() async {
        if response != nil { return }
        await withCheckedContinuation { requested = $0 }
    }

    func finish() {
        response?.resume()
        response = nil
    }
}
