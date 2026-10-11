import Auth
import Foundation
import Supabase
import Synchronization
import Testing
@testable import Taskforce
@testable import TaskforceKit
@testable import TaskforceUI

/// 사용자 승인 조건 "S3b gate off → S3 동작 복귀"를 **실제 앱 생성 경로**(`AppRuntime.makeChatRuntime`, `chatRuntime`이 부르는 같은 함수)로 가른다:
/// 기본 / off에서는 범위 멤버십 게이트웨이 · 저장소가 만들어지지 않아 RLS 멤버십 읽기 · 멤버십 쓰기 · ProjectLink 연결이 없고, All work는 S3 그대로(모두 Ungrouped · 기존 검색 · 칩은 All · Ungrouped)다.
/// B3 Chats · Remembered와 Edge 셸은 유지된다. on(`-TF_S3B YES`)에서만 실제 멤버십이 연결된다.
@MainActor
struct S3bGateTests {
    // MARK: 플래그

    /// 테스트 호스트에는 `-TF_S3B`가 없다: 기본은 꺼짐 (Release도 늘 꺼짐)
    @Test func theFlagIsOffByDefault() {
        #expect(!S3bFlag.isEnabled())
        #expect(S3bFlag.key == "TF_S3B")
    }

    /// 저장된 defaults로는 켜지지 않는다: 인자 영역만 (테스트는 전용 suite를 넘긴다)
    @Test func theFlagFollowsAnInjectedSuiteNotTheStoredDefaults() throws {
        let store = try TestDefaults()
        defer { store.cleanup() }
        #expect(!S3bFlag.isEnabled(store.defaults))
        store.defaults.set(true, forKey: S3bFlag.key)
        #expect(S3bFlag.isEnabled(store.defaults))
        store.defaults.set(false, forKey: S3bFlag.key)
        #expect(!S3bFlag.isEnabled(store.defaults))
    }

    /// 두 플래그는 다른 축이다: Edge 셸 플래그가 S3b를 켜지 않는다
    @Test func theEdgeShellFlagDoesNotTurnS3bOn() throws {
        let store = try TestDefaults()
        defer { store.cleanup() }
        store.defaults.set(true, forKey: EdgeShellFlag.key)
        #expect(EdgeShellFlag.isEnabled(store.defaults) && !S3bFlag.isEnabled(store.defaults))
    }

    // MARK: 실제 생성 경로 (견본 서버)

    @Test func theSampleCreationPathMakesNoMembershipStoreWhenOff() throws {
        let account = try AppChatAccount.make()
        let runtime = AppRuntime.makeChatRuntime(session: account.session, services: Self.services().services, sample: true, s3b: false, connectivity: nil)
        #expect(runtime.contexts == nil && runtime.sampleContextGateway == nil)
        // B3 Chats · Remembered는 그대로 만들어진다
        #expect(runtime.sampleGateway != nil)
    }

    @Test func theSampleCreationPathConnectsMembershipsOnlyWhenOn() throws {
        let account = try AppChatAccount.make()
        let runtime = AppRuntime.makeChatRuntime(session: account.session, services: Self.services().services, sample: true, s3b: true, connectivity: nil)
        #expect(runtime.contexts != nil && runtime.sampleContextGateway != nil && runtime.sampleGateway != nil)
    }

    // MARK: 실제 생성 경로 (실서버 게이트웨이, 가짜 네트워크): 멤버십 읽기 · 쓰기 호출이 실제로 나가는지

    static func services() -> (services: AppServices, host: String) {
        let host = "s3b-\(UUID().uuidString.lowercased().prefix(8)).test"
        S3bStubProtocol.reset(host: host)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [S3bStubProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        let config = AppConfig(
            supabaseURL: URL(string: "https://\(host)")!, supabaseKey: "test-public-key", appGroupID: "group.test.taskforce",
            apiBaseURL: URL(string: "https://\(host)/api")!
        )
        let supabase = SupabaseClient(
            supabaseURL: config.supabaseURL, supabaseKey: config.supabaseKey,
            options: SupabaseClientOptions(auth: .init(storage: S3bEmptyAuthStorage(), autoRefreshToken: false), global: .init(session: urlSession))
        )
        return (AppServices(config: config, supabase: supabase, session: urlSession), host)
    }

    /// off: 멤버십을 읽을 저장소가 없다 → 열어도 · 다시 읽어도 `context_members` 읽기와 `/contexts/…/members` 쓰기가 한 번도 나가지 않는다
    @Test func offNeverReadsMembershipsOrWritesThem() async throws {
        let account = try AppChatAccount.make()
        let (services, host) = Self.services()
        let runtime = AppRuntime.makeChatRuntime(session: account.session, services: services, sample: false, s3b: false, connectivity: nil)
        #expect(runtime.contexts == nil)
        // 셸이 같은 것을 받아 S3처럼 그린다: 모두 Ungrouped, 칩은 All · Ungrouped, 프로젝트 문제 없음
        let shell = EdgeShellModel(schedule: { _, _ in EdgeTimer() }, clock: { Date() }, contexts: runtime.contexts)
        shell.update(EdgeWorkSnapshot(open: (10...12).map(EdgeWorkContextsTests.action), load: .loaded(problem: nil)))
        #expect(WorkListLayout.groups(shell.workItems, filter: WorkFilter(), pinned: []).map(\.title) == ["Ungrouped"])
        #expect(WorkListLayout.projectOptions(shell.workItems) == [.all, .ungrouped] && shell.projectsProblem == nil)
        #expect(!WorkListLayout.groups(shell.workItems, filter: WorkFilter(query: "work 11"), pinned: []).isEmpty, "기존 검색 그대로")
        // B3 Chats는 그대로 읽는다 (대화 목록 읽기는 나가지만 멤버십은 아니다)
        await runtime.chat.refresh()
        let paths = S3bStubProtocol.paths(host: host)
        #expect(paths.contains { $0.hasSuffix("/rest/v1/conversations") })
        #expect(!paths.contains { $0.hasSuffix("/rest/v1/context_members") }, "멤버십 읽기 0")
        #expect(!paths.contains { $0.contains("/contexts/") }, "멤버십 쓰기 0")
    }

    /// on: 같은 경로가 실제 멤버십 읽기를 연결한다 (RLS `work_contexts` · `context_members`)
    @Test func onReadsTheRealMembershipTables() async throws {
        let account = try AppChatAccount.make()
        let (services, host) = Self.services()
        let runtime = AppRuntime.makeChatRuntime(session: account.session, services: services, sample: false, s3b: true, connectivity: nil)
        let store = try #require(runtime.contexts)
        await store.refresh()
        let paths = S3bStubProtocol.paths(host: host)
        #expect(paths.contains { $0.hasSuffix("/rest/v1/work_contexts") } && paths.contains { $0.hasSuffix("/rest/v1/context_members") })
        #expect(store.hasRead && store.members.count == 1, "읽은 멤버 행이 실제 origin으로 매핑된다")
        let origin = store.members.first?.origin
        #expect(origin == .auto)
        #expect(store.index.memberships(of: S3bStubProtocol.actionID).links.map(\.origin) == [.auto])
    }
}

// MARK: 가짜 네트워크

/// 경로마다 답하고 부른 경로를 남긴다: REST `work_contexts` · `context_members`에는 행 하나씩, 나머지는 빈 목록
final class S3bStubProtocol: URLProtocol {
    static let actionID = UUID(uuidString: "5A000000-0000-4000-8000-000000000012")!
    static let contextID = UUID(uuidString: "09D60000-0000-4000-8000-000000000001")!
    private static let state = Mutex<[String: [String]]>([:])

    static func reset(host: String) { state.withLock { $0[host] = [] } }
    static func paths(host: String) -> [String] { state.withLock { $0[host] ?? [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        Self.state.withLock { $0[url.host ?? "", default: []].append(url.path) }
        let body: String
        switch url.lastPathComponent {
        case "work_contexts":
            body = "[{\"id\":\"\(Self.contextID.uuidString.lowercased())\",\"name\":\"Shape launch\",\"kind\":\"project\",\"status\":\"active\",\"context_version\":3,\"last_activity_at\":null}]"
        case "context_members":
            body = "[{\"id\":\"d1e50000-0000-4000-8000-000000000001\",\"context_id\":\"\(Self.contextID.uuidString.lowercased())\",\"member_kind\":\"action\",\"action_id\":\"\(Self.actionID.uuidString.lowercased())\",\"origin\":\"auto\",\"confidence\":null,\"removed_at\":null}]"
        default:
            body = "[]"
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

struct S3bEmptyAuthStorage: AuthLocalStorage {
    func store(key: String, value: Data) throws {}
    func retrieve(key: String) throws -> Data? { nil }
    func remove(key: String) throws {}
}
