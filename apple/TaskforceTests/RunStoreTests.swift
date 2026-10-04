import Auth
import Foundation
import Supabase
import Testing
@testable import Taskforce
@testable import TaskforceKit

/// 실행 상태 저장소: credits 404 → 숨김 · 전송 오류는 앞 값 유지 · 계정이 떠나면 비우고 늦은 결과를 버림 · Start 한 번 · iPhone은 시작하지 않음 ·
/// Stop은 그 할 일의 끝나지 않은 run 전부 · run이 끝나면 알림 · 견본 인자마다 갈래 상태
@Suite(.serialized)
@MainActor
struct RunStoreTests {
    let action = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!

    @Test func creditsNotFoundHidesExecution() async throws {
        let harness = try await RunHarness.make()
        await harness.router.set(credits: .init(status: 404, body: #"{"error":{"code":"not_found","message":"x"}}"#))
        await harness.store.loadCredits()
        #expect(harness.store.credits == .unavailable)
        #expect(!harness.store.isAvailable)
        #expect(harness.store.availability(for: action, signedIn: true, refresh: .live) == .hidden)
        // 쓸 수 없는 계정이면 run을 읽지 않는다
        await harness.store.refreshActive()
        #expect(await harness.router.paths().allSatisfy { !$0.contains("execution_") })
    }

    /// 전송 오류는 앞 값을 그대로 둔다 (항목이 깜빡이지 않게)
    @Test func transportErrorKeepsTheLastValue() async throws {
        let harness = try await RunHarness.make()
        await harness.store.loadCredits()
        #expect(harness.store.summary?.available == 480)
        #expect(harness.store.availability(for: action, signedIn: true, refresh: .live) == .available)
        await harness.router.set(credits: nil)
        await harness.store.loadCredits()
        #expect(harness.store.summary?.available == 480)
        #expect(harness.store.creditsFailed)
        // 이번 달 1일을 UTC ISO 8601로 보낸다
        #expect(await harness.router.queries(path: "/api/v1/credits").allSatisfy { $0["since"]?.hasSuffix("Z") == true })
    }

    /// 로그아웃 직전에 보낸 credits가 로그아웃 뒤에 도착해도 남지 않는다
    @Test func signOutClearsAndDropsLateCredits() async throws {
        let harness = try await RunHarness.make()
        await harness.store.loadCredits()
        await harness.router.set(runs: [Self.runRow(id: 1, state: "running")])
        await harness.store.refreshActive()
        #expect(harness.store.workingActionIDs == [action])

        await harness.router.holdCredits()
        let late = Task { await harness.store.loadCredits() }
        await harness.waitUntil { await harness.router.hasHeldCredits() }
        harness.session.apply(event: .signedOut, session: nil)
        #expect(harness.store.credits == .unknown)
        #expect(harness.store.workingActionIDs.isEmpty)
        await harness.router.releaseCredits()
        await late.value
        #expect(harness.store.credits == .unknown)
        #expect(!harness.store.creditsFailed)
    }

    /// Start는 한 번만 보낸다 (보내는 동안 다시 누르면 무시), 202면 곧바로 갈래 working
    @Test func startSendsOnceAndShowsTheRun() async throws {
        let harness = try await RunHarness.make()
        await harness.store.loadCredits()
        await harness.router.holdCreateRun()
        let first = Task { await harness.store.start(actionID: action, request: "  초안 써 줘 ") }
        await harness.waitUntil { await harness.router.hasHeldCreateRun() }
        #expect(harness.store.starting == [action])
        #expect(await harness.store.start(actionID: action, request: "초안 써 줘") == .ignored)
        await harness.router.releaseCreateRun(body: #"{"run":\#(Self.runRow(id: 1, state: "queued"))}"#)
        guard case .started(let run) = await first.value else {
            Issue.record("시작하지 않음")
            return
        }
        #expect(run.state == .queued)
        #expect(harness.store.starting.isEmpty)
        #expect(harness.store.lane(for: action).state == .working)
        #expect(harness.store.availability(for: action, signedIn: true, refresh: .live) == .disabled(.alreadyRunning))
        let creates = await harness.router.bodies(path: "/api/v1/runs")
        #expect(creates.count == 1)
        #expect(creates.first == ["action_id": action.uuidString.lowercased(), "goal": "draft", "request": "초안 써 줘"])
    }

    @Test func emptyRequestIsNotSent() async throws {
        let harness = try await RunHarness.make()
        #expect(await harness.store.start(actionID: action, request: " \n ") == .ignored)
        #expect(await harness.router.bodies(path: "/api/v1/runs").isEmpty)
    }

    /// iPhone은 run을 시작하지 않는다: 서버를 부르지 않는다
    @Test func iPhoneNeverStarts() async throws {
        let harness = try await RunHarness.make(platform: .iOS)
        await harness.store.loadCredits()
        #expect(harness.store.availability(for: action, signedIn: true, refresh: .live) == .hidden)
        #expect(await harness.store.start(actionID: action, request: "초안") == .ignored)
        #expect(await harness.router.bodies(path: "/api/v1/runs").isEmpty)
    }

    @Test func startConsentNeeded() async throws {
        let harness = try await RunHarness.make()
        await harness.router.set(createRun: .init(status: 409, body: #"{"error":{"code":"conflict","message":"동의 필요"}}"#))
        #expect(await harness.store.start(actionID: action, request: "초안") == .failed(.consentNeeded))
        #expect(harness.store.lane(for: action).state == .none)
    }

    /// Stop: 먼저 새로 읽고 그 할 일의 끝나지 않은 run을 모두 멈춘다 (다른 기기에서 시작한 run 포함, 끝난 run은 보내지 않음)
    @Test func stopStopsEveryOpenRun() async throws {
        let harness = try await RunHarness.make()
        await harness.store.loadCredits()
        await harness.router.set(runs: [
            Self.runRow(id: 1, state: "running", minutes: 5), Self.runRow(id: 2, state: "queued", hold: "credit"), Self.runRow(id: 3, state: "done"),
        ])
        await harness.router.set(stopRun: .init(status: 200, body: #"{"run":\#(Self.runRow(id: 1, state: "stopped"))}"#))
        #expect(await harness.store.stop(actionID: action))
        let stops = await harness.router.paths().filter { $0.hasSuffix("/stop") }
        #expect(stops == ["/api/v1/runs/\(Self.runID(1))/stop", "/api/v1/runs/\(Self.runID(2))/stop"])
        #expect(harness.store.stopping.isEmpty)
    }

    /// 지켜보던 run이 끝나면 한 번 알린다 (부르는 쪽이 `/now`를 다시 받는다). 단계 · 초안도 읽는다
    @Test func finishedRunNotifies() async throws {
        let harness = try await RunHarness.make()
        await harness.store.loadCredits()
        var finished = 0
        harness.store.onRunsFinished = { finished += 1 }
        await harness.router.set(runs: [Self.runRow(id: 1, state: "running")])
        harness.store.watch([action])
        await harness.waitUntil { harness.store.lane(for: harness.action).state == .working }
        #expect(finished == 0)
        await harness.router.set(runs: [Self.runRow(id: 1, state: "done", outcome: "draft_ready")])
        await harness.router.set(artifacts: [Self.artifactRow()])
        await harness.store.refreshWatched()
        #expect(finished == 1)
        #expect(harness.store.lane(for: action).state == .draftReady)
        #expect(harness.store.lane(for: action).drafts.map(\.title) == ["일정 변경 회신"])
        #expect(await harness.router.paths().contains("/rest/v1/execution_steps"))
        harness.store.watch([])
    }

    /// 상세를 credits보다 먼저 지켜봐도, 쓸 수 있음을 알면 곧바로 읽기 시작한다
    @Test func watchingBeforeCreditsStartsOnceAvailable() async throws {
        let harness = try await RunHarness.make()
        await harness.router.set(runs: [Self.runRow(id: 1, state: "running", hold: "credit")])
        harness.store.watch([action])
        #expect(harness.store.lane(for: action).state == .none)
        await harness.store.loadCredits()
        await harness.waitUntil { harness.store.lane(for: harness.action).state == .paused(.credit) }
        harness.store.watch([])
    }

    /// 견본 인자마다 갈래 상태 (U2 Mac 계획 §2)
    @Test(arguments: [
        (SampleRuns.Lane.working, RunLane.State.working, 0),
        (.draftReady, .draftReady, 1),
        (.credit, .paused(.credit), 0),
        (.stoppedFinishing, .stopped(finishing: true, stoppedAt: SampleData.today(14, 20)), 0),
        (.stopped, .stopped(finishing: false, stoppedAt: SampleData.today(14, 20)), 0),
        (.failed, .failed(.rejected), 0),
        (.needsInput, .needsInput(question: "데모는 어느 고객사 대상인가요?"), 0),
        (.needsConnection, .needsConnection(capability: "gmail.send"), 1),
        (.purged, .draftReady, 1),
    ])
    func sampleLanes(_ lane: SampleRuns.Lane, _ expected: RunLane.State, _ drafts: Int) async throws {
        let harness = try await RunHarness.make()
        let fixture = SampleRuns.fixture(lane)
        harness.store.applySample(credits: .available(SampleRuns.laneCredits(lane), checkedAt: Date()), runs: fixture.runs, steps: fixture.steps,
                                  drafts: fixture.drafts)
        let result = harness.store.lane(for: SampleData.demoID)
        #expect(result.state == expected)
        #expect(result.drafts.count == drafts)
        if lane == .purged { #expect(result.drafts.first?.isPurged == true) }
        // 견본은 서버를 부르지 않는다
        await harness.store.refreshWatched()
        _ = await harness.store.stop(actionID: SampleData.demoID)
        #expect(await harness.router.paths().allSatisfy { !$0.contains("execution_") && !$0.contains("/runs") })
    }

    @Test func sampleCreditsMatchFigma() {
        let rows = CreditsRows.make(
            credits: SampleRuns.creditsSummary(), loadFailed: false, checkedAt: SampleData.today(16, 10), pausedRuns: SampleRuns.pausedRuns(),
            titles: [SampleRuns.pausedActionIDs[0]: "QA 시나리오 업데이트"], now: Date()
        )
        #expect(rows.available.value == "0")
        #expect(rows.reserved.value == "12")
        #expect(rows.pending?.value == "Unknown")
        #expect(rows.used.value == "188")
        #expect(rows.paused?.title == "2 paid steps are paused")
    }

    // MARK: 응답 모양

    static func runID(_ n: Int) -> String { String(format: "55555555-5555-4555-8555-%012d", n) }

    static func runRow(id: Int, state: String, hold: String? = nil, outcome: String? = nil, minutes: Int = 0) -> String {
        let quoted: (String?) -> String = { $0.map { "\"\($0)\"" } ?? "null" }
        return """
        {"id":"\(runID(id))","action_id":"11111111-1111-4111-8111-111111111111","goal":"draft","state":"\(state)",\
        "hold_reason":\(quoted(hold)),"outcome":\(quoted(outcome)),"budget_credits":null,\
        "created_at":"2026-10-04T05:\(String(format: "%02d", minutes)):00Z","stopped_at":null}
        """
    }

    static func artifactRow() -> String {
        """
        {"id":"77777777-7777-4777-8777-777777777777","run_id":"\(runID(1))","step_id":"66666666-6666-4666-8666-666666666666",\
        "action_id":"11111111-1111-4111-8111-111111111111","kind":"draft","title":"일정 변경 회신","body":"본문","model":"m",\
        "prompt_version":"draft-v1","retain_until":"2027-01-02T05:00:00Z","body_purged_at":null,"created_at":"2026-10-04T05:01:00Z"}
        """
    }
}

@MainActor
private final class RunHarness {
    let store: RunStore
    let session: SessionStore
    let router: RunStubRouter
    let action = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!

    private init(store: RunStore, session: SessionStore, router: RunStubRouter) {
        self.store = store
        self.session = session
        self.router = router
    }

    static func make(platform: RunPlatform = .macOS) async throws -> RunHarness {
        let user = makeSession(userID: UUID())
        let storage = HarnessSessionStorage(data: try AuthClient.Configuration.jsonEncoder.encode(user))
        let host = "supabase-\(UUID().uuidString.lowercased()).test"
        let apiHost = "api-\(UUID().uuidString.lowercased()).test"
        let router = RunStubRouter()
        await RunStubRegistry.shared.register(router, hosts: [host, apiHost])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RunStubURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        let config = AppConfig(
            supabaseURL: URL(string: "https://\(host)")!, supabaseKey: "test-key", appGroupID: "group.test.taskforce",
            apiBaseURL: URL(string: "https://\(apiHost)")!
        )
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
        return RunHarness(store: RunStore(services: services, session: session, platform: platform), session: session, router: router)
    }

    func waitUntil(_ condition: @MainActor () async -> Bool) async {
        for _ in 0..<200 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(await condition())
    }

    private static func makeSession(userID: UUID) -> Session {
        let user = User(id: userID, appMetadata: [:], userMetadata: [:], aud: "authenticated", email: "\(userID.uuidString)@example.com",
                        createdAt: Date(), updatedAt: Date())
        return Session(accessToken: "access-\(userID)", tokenType: "bearer", expiresIn: 3600,
                       expiresAt: Date().addingTimeInterval(3600).timeIntervalSince1970, refreshToken: "refresh-\(userID)", user: user)
    }
}

private final class HarnessSessionStorage: AuthLocalStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data

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

private struct RunReply: Sendable {
    let status: Int
    let body: String
}

/// 가짜 서버 (API + PostgREST). credits · run 만들기는 붙잡았다 놓을 수 있다
private actor RunStubRouter {
    struct Recorded: Sendable {
        let method: String
        let path: String
        let query: [String: String]
        let body: Data?
    }

    /// nil = 연결 실패
    private var credits: RunReply? = RunReply(status: 200, body: #"{"available":480,"reserved":0,"rate_version":"c3-v1"}"#)
    private var runs: [String] = []
    private var artifacts: [String] = []
    private var createRun = RunReply(status: 500, body: "{}")
    private var stopRun = RunReply(status: 500, body: "{}")
    private var holdingCredits = false
    private var heldCredits: [CheckedContinuation<Void, Never>] = []
    private var holdingCreate = false
    private var heldCreate: [CheckedContinuation<RunReply, Never>] = []
    private var recorded: [Recorded] = []

    func set(credits: RunReply?) { self.credits = credits }
    func set(runs: [String]) { self.runs = runs }
    func set(artifacts: [String]) { self.artifacts = artifacts }
    func set(createRun: RunReply) { self.createRun = createRun }
    func set(stopRun: RunReply) { self.stopRun = stopRun }

    func holdCredits() { holdingCredits = true }
    func hasHeldCredits() -> Bool { !heldCredits.isEmpty }
    func releaseCredits() {
        holdingCredits = false
        heldCredits.forEach { $0.resume() }
        heldCredits = []
    }

    func holdCreateRun() { holdingCreate = true }
    func hasHeldCreateRun() -> Bool { !heldCreate.isEmpty }
    func releaseCreateRun(body: String) {
        holdingCreate = false
        heldCreate.forEach { $0.resume(returning: RunReply(status: 202, body: body)) }
        heldCreate = []
    }

    func paths() -> [String] { recorded.map(\.path) }

    func queries(path: String) -> [[String: String]] { recorded.filter { $0.path == path }.map(\.query) }

    func bodies(path: String) -> [[String: String]] {
        recorded.filter { $0.path == path && $0.method == "POST" }.compactMap { record in
            record.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
        }
    }

    /// nil = 연결 실패
    func response(method: String, path: String, query: [String: String], body: Data?) async -> RunReply? {
        recorded.append(Recorded(method: method, path: path, query: query, body: body))
        switch path {
        case "/api/v1/credits":
            if holdingCredits { await withCheckedContinuation { heldCredits.append($0) } }
            return credits
        case "/api/v1/runs":
            if holdingCreate { return await withCheckedContinuation { heldCreate.append($0) } }
            return createRun
        case _ where path.hasPrefix("/api/v1/runs/") && path.hasSuffix("/stop"):
            return stopRun
        case "/rest/v1/execution_runs":
            return RunReply(status: 200, body: "[\(runs.joined(separator: ","))]")
        case "/rest/v1/execution_artifacts":
            return RunReply(status: 200, body: "[\(artifacts.joined(separator: ","))]")
        default:
            return RunReply(status: path.hasPrefix("/api/") ? 500 : 200, body: path.hasPrefix("/api/") ? "{}" : "[]")
        }
    }
}

private actor RunStubRegistry {
    static let shared = RunStubRegistry()
    private var routers: [String: RunStubRouter] = [:]

    func register(_ router: RunStubRouter, hosts: [String]) {
        for host in hosts { routers[host] = router }
    }

    func router(for host: String) -> RunStubRouter? { routers[host] }
}

private final class RunStubURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".test") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let query = Dictionary(
            (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).compactMap { item in item.value.map { (item.name, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        let method = request.httpMethod ?? "GET"
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read)
        let box = RunProtocolBox(self)
        Task {
            guard let router = await RunStubRegistry.shared.router(for: host),
                  let reply = await router.response(method: method, path: url.path, query: query, body: body)
            else {
                box.fail(URLError(.notConnectedToInternet))
                return
            }
            let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            box.succeed(response, body: Data(reply.body.utf8))
        }
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

// URLProtocolClient는 Sendable이 아니라 한 번만 쓰는 상자로 넘긴다
private final class RunProtocolBox: @unchecked Sendable {
    private var urlProtocol: RunStubURLProtocol?

    init(_ urlProtocol: RunStubURLProtocol) { self.urlProtocol = urlProtocol }

    func succeed(_ response: URLResponse, body: Data) {
        guard let urlProtocol else { return }
        self.urlProtocol = nil
        urlProtocol.client?.urlProtocol(urlProtocol, didReceive: response, cacheStoragePolicy: .notAllowed)
        urlProtocol.client?.urlProtocol(urlProtocol, didLoad: body)
        urlProtocol.client?.urlProtocolDidFinishLoading(urlProtocol)
    }

    func fail(_ error: Error) {
        guard let urlProtocol else { return }
        self.urlProtocol = nil
        urlProtocol.client?.urlProtocol(urlProtocol, didFailWithError: error)
    }
}
