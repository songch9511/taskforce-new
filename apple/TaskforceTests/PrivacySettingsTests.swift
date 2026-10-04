import Auth
import Foundation
import Supabase
import Testing
@testable import Taskforce
@testable import TaskforceKit

/// 설정 Privacy & AI Data (U2 Mac PR4, D9a-1 동의 경로)
struct PrivacySettingsTests {
    /// `Use AI on new sources`: 켜기 → 동의 화면(Allow를 눌러야 동의), 끄기 → 철회 확인. 같은 상태 · 동의를 아직 읽지 않았으면 아무것도 하지 않는다
    @Test(arguments: [
        (true, false, true, ConsentSwitch.prompt),
        (false, true, true, .confirmWithdraw),
        (true, true, true, .none),
        (false, false, true, .none),
        (true, false, false, .none),
        (false, true, false, .none),
    ])
    func switchOpensPromptOrWithdrawConfirmation(on: Bool, hasConsent: Bool, loaded: Bool, expected: ConsentSwitch) {
        #expect(ConsentSwitch.change(to: on, hasConsent: hasConsent, loaded: loaded) == expected)
    }

    /// 철회 경로는 Mac · iPhone 모두 처리방침 4장 · 11장과 같은 "Settings > Privacy & AI Data"
    @Test func withdrawPathMatchesThePolicy() {
        #expect(ConsentDetails.settingsPath == "Settings > Privacy & AI Data")
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
