import AppKit
import Auth
import Carbon.HIToolbox
import Foundation
import Supabase
import Testing
@testable import Taskforce
@testable import TaskforceKit

/// Mac 런처 셸 (U1 PR4): 범위 · 펼침 · seen · 저장본 · 오프라인(M20) · 키
@Suite(.serialized)
@MainActor
struct LauncherShellModelTests {
    /// 범위를 바꿔도 고르던 행이 새 목록에 있으면 그 행, 없으면 같은 자리 (`reselect`), 패널에서 돌아오면 본 행 (`rowAfterBack`)
    @Test func scopeKeepsTheSelectionRules() async throws {
        let harness = try await ShellHarness.make(now: ShellNow.body(reviews: ["R1"], toDo: ["T1", "T2"]))
        let model = harness.model
        let t2 = try #require(model.items.firstIndex { $0.action?.title == "T2" })
        model.select(t2)

        model.chooseScope(.toDo)
        #expect(model.scope == .toDo)
        #expect(model.selectedItem?.action?.title == "T2")
        #expect(model.items.allSatisfy { $0.group == .toDo })

        // T2가 없는 범위: 같은 자리 (끝을 넘지 않게)
        model.chooseScope(.review)
        #expect(model.selectedItem?.action?.title == "R1")

        // ⌘K 패널에서 돌아오면 본 할 일의 행
        model.chooseScope(.allTasks)
        let t1 = try #require(model.items.firstIndex { $0.action?.title == "T1" })
        model.select(t1)
        model.openActions()
        #expect(model.screen.isActions)
        model.back()
        #expect(model.screen == .list)
        #expect(model.selectedItem?.action?.title == "T1")
    }

    /// `Show N More` 줄에서 ↩: 그 섹션을 펼치고 처음 드러난 행을 고른다
    @Test func returnOnShowMoreExpands() async throws {
        let harness = try await ShellHarness.make(now: ShellNow.body(toDo: ["T1", "T2", "T3"], limits: (2, 5, 1)))
        let model = harness.model
        let more = try #require(model.items.firstIndex { if case .showMore(.toDo, 2) = $0 { true } else { false } })
        model.select(more)
        #expect(model.handleKey(.key(kVK_Return)))
        #expect(!model.items.contains { if case .showMore(.toDo, _) = $0 { true } else { false } })
        #expect(model.items.compactMap(\.action?.title) == ["T1", "T2", "T3"])
        #expect(model.selectedItem?.action?.title == "T2")
    }

    /// 바뀐 행을 골랐다가 떠나면 seen 한 번. 다시 와서 떠나도 다시 보내지 않고, 점은 바로 지운다
    @Test func seenIsSentOnceWhenLeavingAChangedRow() async throws {
        let harness = try await ShellHarness.make(now: ShellNow.body(toDo: ["T1", "T2"], changed: ["T1"]))
        let model = harness.model
        model.prepareForShow()
        // 연 뒤의 다시 불러오기가 끝난 뒤에 시작한다 (새 `/now`는 보낸 기록을 비운다)
        await harness.waitUntil { await harness.router.nowRequests() >= 2 }
        try await Task.sleep(for: .milliseconds(100))
        let t1 = try #require(model.items.first { $0.action?.title == "T1" }?.action?.id)
        #expect(model.showsDot(t1))
        model.select(0)
        model.syncSeen()
        #expect(await harness.router.seenIDs().isEmpty)

        model.move(1)
        model.syncSeen()
        await harness.waitUntil { await harness.router.seenIDs() == [t1] }
        #expect(!model.showsDot(t1))

        model.move(-1)
        model.syncSeen()
        model.move(1)
        model.syncSeen()
        model.didHide()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await harness.router.seenIDs() == [t1])
    }

    /// 이번 실행에서 받은 목록도 저장본도 없이 오프라인이면 M20, 연결이 돌아오면 목록을 다시 불러온다
    @Test func offlineWithoutSavedCopyShowsM20ThenReloadsOnReconnect() async throws {
        let harness = try await ShellHarness.make(now: nil)
        let model = harness.model
        #expect(model.now?.response == nil)
        #expect(model.savedList == nil)

        harness.connectivity.yield(false)
        await harness.waitUntil { model.refreshState.isOffline }
        #expect(model.bodyState == .offlineEmpty)
        #expect(model.statusText?.hasPrefix("Offline since ") == true)
        #expect(!model.showsSavedTasks)

        await harness.router.setNow(ShellNow.body(toDo: ["T1"]))
        harness.connectivity.yield(true)
        await harness.waitUntil { model.now?.response != nil }
        #expect(model.bodyState == .list)
        #expect(model.statusText == nil)
    }

    /// ⌘R: 다시 불러온다 (M19 `Try Again`)
    @Test func commandRReloads() async throws {
        let harness = try await ShellHarness.make(now: nil)
        let model = harness.model
        #expect(model.secondaryAction == LauncherModel.BarAction(title: "Try Again", keys: "⌘R"))
        let before = await harness.router.nowRequests()
        #expect(model.handleKey(.key(kVK_ANSI_R, command: true)))
        await harness.waitUntil { await harness.router.nowRequests() > before }
    }

    /// esc는 범위 메뉴가 열려 있으면 메뉴만 닫는다. 그다음 esc는 지금처럼 런처를 닫는다
    @Test func escapeClosesTheScopeMenuFirst() async throws {
        let harness = try await ShellHarness.make(now: ShellNow.body(toDo: ["T1"]))
        let model = harness.model
        var closed = false
        model.close = { closed = true }
        #expect(model.handleKey(.key(kVK_ANSI_P, command: true)))
        #expect(model.scopeMenuSelection == 0)
        #expect(model.handleKey(.key(kVK_DownArrow)))
        #expect(model.scopeMenuSelection == 1)
        #expect(model.handleKey(.key(kVK_Escape)))
        #expect(model.scopeMenuSelection == nil)
        #expect(model.scope == .allTasks)
        #expect(!closed)
        #expect(model.handleKey(.key(kVK_Escape)))
        #expect(closed)
    }

    /// 범위 메뉴에서 ↩: 고른 범위로
    @Test func returnInTheScopeMenuChoosesTheScope() async throws {
        let harness = try await ShellHarness.make(now: ShellNow.body(reviews: ["R1"], toDo: ["T1"]))
        let model = harness.model
        model.toggleScopeMenu()
        model.selectScopeMenuRow(model.scopeChoices.firstIndex(of: .toDo) ?? 0)
        #expect(model.primaryAction == LauncherModel.BarAction(title: "Show To Do", keys: "↩"))
        #expect(model.handleKey(.key(kVK_Return)))
        #expect(model.scope == .toDo)
        #expect(model.scopeMenuSelection == nil)
        #expect(model.count(for: .allTasks) == 2)
    }

    /// 할 일 행 ↩: 원문 링크가 없으면 ⌘K 패널 (전과 같다)
    @Test func returnOnATaskWithoutALinkOpensActions() async throws {
        let harness = try await ShellHarness.make(now: ShellNow.body(toDo: ["T1"]))
        let model = harness.model
        model.select(0)
        #expect(model.handleKey(.key(kVK_Return)))
        await harness.waitUntil { model.screen.isActions }
    }

    /// `/now`를 받으면 요청한 계정의 저장본을 남기고, 로그아웃하면 지운다
    @Test func savedCopyIsWrittenForTheAccountAndDeletedOnSignOut() async throws {
        let harness = try await ShellHarness.make(now: ShellNow.body(reviews: ["R1"], toDo: ["T1"]))
        let account = harness.firstAccount
        let copy = try #require(harness.saved.load(account: account))
        #expect(copy.tasks.map(\.title) == ["R1", "T1"])

        harness.session.apply(event: .signedOut, session: nil)
        #expect(harness.saved.load(account: account) == nil)
        #expect(!FileManager.default.fileExists(atPath: harness.saved.root.path))
    }

    /// 로그아웃 직전에 보낸 `/now`가 로그아웃 뒤에 와도 저장본을 다시 쓰지 않는다
    @Test func lateNowAfterSignOutIsNotSaved() async throws {
        let harness = try await ShellHarness.make(now: nil)
        let account = harness.firstAccount
        await harness.router.setNow(ShellNow.body(toDo: ["Private"]))
        await harness.router.holdNow()
        let now = try #require(harness.model.now)
        let read = Task { await now.load() }
        await harness.waitUntil { await harness.router.hasPendingNow() }

        harness.session.apply(event: .signedOut, session: nil)
        await harness.router.releaseNow()
        _ = await read.value

        #expect(harness.saved.load(account: account) == nil)
        #expect(now.response == nil)
    }

    /// 앱을 열 때 다른 계정의 저장본은 지우고, 이번 실행에서 `/now`를 받기 전에는 지금 계정의 저장본을 보인다 (M15 · M19)
    @Test func launchPrunesOtherAccountsAndShowsTheCurrentSavedCopy() async throws {
        let other = UUID()
        let first = UUID()
        let saved = ShellHarness.temporaryStore()
        let copy = SavedNow(
            sections: TaskBoard(now: try ShellNow.decode(ShellNow.body(toDo: ["Saved T1"]))).sections(),
            savedAt: Date(timeIntervalSince1970: 1_791_000_000)
        )
        try saved.save(copy, account: other)
        try saved.save(copy, account: first)

        let harness = try await ShellHarness.make(now: nil, firstAccount: first, saved: saved)
        #expect(saved.load(account: other) == nil)
        #expect(harness.model.savedList == copy)
        #expect(harness.model.showsSavedTasks)
        #expect(harness.model.items.contains { if case .saved(let row) = $0 { row.task.title == "Saved T1" } else { false } })
        #expect(harness.model.bodyState == .list)
    }
}

// MARK: - 하네스

extension LauncherModel.Screen {
    var isActions: Bool {
        if case .actions = self { true } else { false }
    }
}

extension NSEvent {
    static func key(_ code: Int, command: Bool = false) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: command ? [.command] : [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(code)
        )!
    }
}

/// `/now` 응답 본문
enum ShellNow {
    static func body(
        reviews: [String] = [], toDo: [String] = [], changed: Set<String> = [], limits: (Int, Int, Int) = (2, 5, 5)
    ) -> Data {
        func row(_ title: String, review: Bool, index: Int) -> String {
            let id = String(format: "00000000-0000-4000-8000-%012d", (review ? 100 : 200) + index)
            let ranked = review ? "" : #","score":1,"reasons":[],"days_until_due":null"#
            return """
            {"id":"\(id)","title":"\(title)","owner":"me","status":"open","due_date":null,"counterpart":null,\
            "needs_confirmation":\(review),"confirm_reasons":\(review ? #"["담당 확인"]"# : "[]"),"started_at":null,\
            "last_activity_at":"2026-09-29T10:00:00Z","changed":\(changed.contains(title))\(ranked)}
            """
        }
        let now = toDo.enumerated().map { row($1, review: false, index: $0) }.joined(separator: ",")
        let confirmations = reviews.enumerated().map { row($1, review: true, index: $0) }.joined(separator: ",")
        return Data("""
        {"now":[\(now)],"confirmations":[\(confirmations)],\
        "section_limits":{"review":\(limits.0),"in_progress":\(limits.1),"to_do":\(limits.2)}}
        """.utf8)
    }

    static func decode(_ data: Data) throws -> NowResponse {
        try TaskforceJSON.decoder().decode(NowResponse.self, from: data)
    }
}

@MainActor
private final class ShellHarness {
    let model: LauncherModel
    let session: SessionStore
    let router: ShellRouter
    let saved: SavedNowStore
    let connectivity: AsyncStream<Bool>.Continuation
    let firstAccount: UUID
    private let storage: ShellSessionStorage
    private let urlSession: URLSession

    private init(
        model: LauncherModel, session: SessionStore, router: ShellRouter, saved: SavedNowStore,
        connectivity: AsyncStream<Bool>.Continuation, firstAccount: UUID, storage: ShellSessionStorage, urlSession: URLSession
    ) {
        self.model = model
        self.session = session
        self.router = router
        self.saved = saved
        self.connectivity = connectivity
        self.firstAccount = firstAccount
        self.storage = storage
        self.urlSession = urlSession
    }

    static func temporaryStore() -> SavedNowStore {
        SavedNowStore(root: FileManager.default.temporaryDirectory.appending(path: "LauncherShell-\(UUID().uuidString)", directoryHint: .isDirectory))
    }

    /// `now`가 nil이면 `/now`는 500 (첫 목록 없음)
    static func make(now: Data?, firstAccount: UUID = UUID(), saved: SavedNowStore? = nil) async throws -> ShellHarness {
        let firstSession = shellSession(userID: firstAccount)
        let storage = ShellSessionStorage(data: try AuthClient.Configuration.jsonEncoder.encode(firstSession))
        let host = "supabase-\(UUID().uuidString.lowercased()).test"
        let apiHost = "api-\(UUID().uuidString.lowercased()).test"
        let router = ShellRouter(now: now)
        await ShellRouterRegistry.shared.register(router, for: host)
        await ShellRouterRegistry.shared.register(router, for: apiHost)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ShellStubURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        let config = AppConfig(
            supabaseURL: URL(string: "https://\(host)")!, supabaseKey: "test-key", appGroupID: "group.test.taskforce",
            apiBaseURL: URL(string: "https://\(apiHost)")!
        )
        let supabase = SupabaseClient(
            supabaseURL: config.supabaseURL,
            supabaseKey: config.supabaseKey,
            options: SupabaseClientOptions(
                auth: .init(storage: storage, autoRefreshToken: false, emitLocalSessionAsInitialSession: true),
                global: .init(session: urlSession)
            )
        )
        let session = SessionStore(auth: supabase.auth)
        session.apply(event: .signedIn, session: firstSession)
        let services = AppServices(config: config, supabase: supabase, session: urlSession)
        let account = AccountStore(services: services, session: session)
        let store = saved ?? temporaryStore()
        let (stream, continuation) = AsyncStream<Bool>.makeStream()
        let model = LauncherModel(session: session, services: services, account: account, saved: store, connectivity: stream)
        model.sessionChanged()
        for _ in 0..<200 where model.now?.loaded != true {
            try await Task.sleep(for: .milliseconds(10))
        }
        return ShellHarness(
            model: model, session: session, router: router, saved: store, connectivity: continuation, firstAccount: firstAccount,
            storage: storage, urlSession: urlSession
        )
    }

    func waitUntil(_ condition: @MainActor () async -> Bool) async {
        for _ in 0..<200 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(await condition())
    }
}

private final class ShellSessionStorage: AuthLocalStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data

    init(data: Data) {
        self.data = data
    }

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
}

private struct ShellResponse: Sendable {
    let status: Int
    let body: Data
}

private actor ShellRouter {
    private var now: Data?
    private var nowCount = 0
    private var seen: [UUID] = []
    private var holding = false
    private var held: [CheckedContinuation<ShellResponse, Never>] = []

    init(now: Data?) {
        self.now = now
    }

    func response(method: String, path: String) async -> ShellResponse {
        if path == "/api/v1/now" {
            nowCount += 1
            if holding { return await withCheckedContinuation { held.append($0) } }
            return currentNow()
        }
        if method == "POST", path.hasPrefix("/api/v1/actions/"), path.hasSuffix("/seen") {
            let id = path.dropFirst("/api/v1/actions/".count).dropLast("/seen".count)
            if let uuid = UUID(uuidString: String(id)) { seen.append(uuid) }
            return ShellResponse(status: 204, body: Data())
        }
        if path.hasPrefix("/api/v1/") {
            return ShellResponse(status: 500, body: Data("{}".utf8))
        }
        return ShellResponse(status: 200, body: Data("[]".utf8))
    }

    private func currentNow() -> ShellResponse {
        guard let now else { return ShellResponse(status: 500, body: Data("{}".utf8)) }
        return ShellResponse(status: 200, body: now)
    }

    func setNow(_ data: Data?) { now = data }
    func nowRequests() -> Int { nowCount }
    func seenIDs() -> [UUID] { seen }
    func holdNow() { holding = true }
    func hasPendingNow() -> Bool { !held.isEmpty }

    func releaseNow() {
        holding = false
        let response = currentNow()
        for continuation in held { continuation.resume(returning: response) }
        held = []
    }
}

private actor ShellRouterRegistry {
    static let shared = ShellRouterRegistry()
    private var routers: [String: ShellRouter] = [:]

    func register(_ router: ShellRouter, for host: String) {
        routers[host] = router
    }

    func router(for host: String) -> ShellRouter? {
        routers[host]
    }
}

private final class ShellStubURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".test") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let method = request.httpMethod ?? "GET"
        let path = url.path
        let box = ShellCompletion(self)
        Task {
            guard let router = await ShellRouterRegistry.shared.router(for: host) else {
                box.fail(URLError(.cannotFindHost))
                return
            }
            let result = await router.response(method: method, path: path)
            let response = HTTPURLResponse(url: url, statusCode: result.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            box.succeed(response, body: result.body)
        }
    }

    override func stopLoading() {}
}

// URLProtocolClient is not Sendable, so the task uses this one-shot unchecked box to retain the protocol.
private final class ShellCompletion: @unchecked Sendable {
    private var urlProtocol: ShellStubURLProtocol?

    init(_ urlProtocol: ShellStubURLProtocol) {
        self.urlProtocol = urlProtocol
    }

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

private func shellSession(userID: UUID) -> Session {
    let user = User(
        id: userID, appMetadata: [:], userMetadata: [:], aud: "authenticated", email: "\(userID.uuidString)@example.com",
        createdAt: Date(), updatedAt: Date()
    )
    let lifetime: TimeInterval = 3600
    return Session(
        accessToken: "access-\(userID)", tokenType: "bearer", expiresIn: lifetime,
        expiresAt: Date().addingTimeInterval(lifetime).timeIntervalSince1970, refreshToken: "refresh-\(userID)", user: user
    )
}
