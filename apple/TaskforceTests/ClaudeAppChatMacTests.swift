import AppKit
import Foundation
import SwiftUI
import Synchronization
import Testing
@testable import Taskforce
@testable import TaskforceKit
@testable import TaskforceUI

/// 서버를 대신하는 가짜 (경로별 답 + 받은 요청 기록). 실제 서버 · 네트워크는 부르지 않는다
private final class DeskChatServerProtocol: URLProtocol, @unchecked Sendable {
    struct Recorded: Sendable {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data?
    }

    struct Reply: Sendable {
        let status: Int
        let body: String
    }

    private static let state = Mutex<(replies: [String: [String: Reply]], requests: [String: [Recorded]])>(([:], [:]))

    /// 경로 → 답. 정하지 않은 경로는 404
    static func register(host: String, replies: [String: Reply]) {
        state.withLock { $0.replies[host] = replies }
    }

    static func requests(host: String) -> [Recorded] { state.withLock { $0.requests[host] ?? [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let recorded = Recorded(
            method: request.httpMethod ?? "GET", path: url.path, headers: request.allHTTPHeaderFields ?? [:], body: request.httpBody ?? request.httpBodyStream.map(Self.read)
        )
        let reply = Self.state.withLock { state -> Reply in
            state.requests[url.host ?? "", default: []].append(recorded)
            return state.replies[url.host ?? ""]?[url.path] ?? Reply(status: 404, body: "")
        }
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
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

/// 띄우기를 늘 거절하는 가짜 (실제 `claude`를 띄우지 않는다). 시도한 횟수를 센다
final class DeskChatRefusingLauncher: ClaudeAppRelayLauncher, @unchecked Sendable {
    private let lock = NSLock()
    private var _launches = 0
    var launches: Int { lock.withLock { _launches } }

    func launch(arguments: [String], cwd: String) async throws -> any ClaudeAppRelayProcess {
        lock.withLock { _launches += 1 }
        throw CocoaError(.fileNoSuchFile)
    }
}

/// 중계가 있는 대화 흐름 (띄우기는 늘 거절: 프로세스가 뜨지 않는다). 시험 · 촬영이 함께 쓴다
@MainActor
struct DeskChatHarness {
    let service: ClaudeAppChatService
    let relay: ClaudeAppRelay
    let launcher: DeskChatRefusingLauncher

    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "tf-chat-mac-\(UUID().uuidString.lowercased())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func make() throws -> DeskChatHarness {
        let launcher = DeskChatRefusingLauncher()
        let relay = ClaudeAppRelay(
            configuration: ClaudeAppRelay.Configuration(modDirectory: ClaudeAppChatRuntime.modDirectory(), workDirectory: try temporaryDirectory().path), launcher: launcher,
            pids: ClaudeAppRelayPIDs()
        )
        let saver = ClaudeAppChatSaver(status: { ClaudeAppChatsStatus(save: false) }, put: { _ in .retry })
        let service = ClaudeAppChatService(
            environment: ClaudeAppChatEnvironment(
                relay: relay, facts: { _ in ClaudeAppSendFacts(session: nil, doubled: false, processTrusted: false, otherWriters: .none) }, transcript: TranscriptFake(),
                session: { _ in nil }, saver: saver, identity: { _ in nil }, report: { _ in }
            )
        )
        return DeskChatHarness(service: service, relay: relay, launcher: launcher)
    }
}

/// 데스크톱 세션과의 대화 흐름의 Mac 쪽 (OA PR-D3m): 번들 안 mod · 중계 자리 · 입력창 자리 판단 · 전달 말풍선 · 서버 연결 · 패널에 올린 모습.
/// 이 Mac의 실제 Claude 기록 · 프로세스 · 서버를 읽거나 쓰지 않는다 (가짜 중계 띄우기 · 가짜 기록 · 가짜 서버 · 임시 폴더)
@MainActor
struct ClaudeAppChatMacTests {
    typealias Sessions = EdgeSessionsTests

    // MARK: 도구

    private func eventually(_ seconds: Double = 3, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    private func temporaryDirectory() throws -> URL { try DeskChatHarness.temporaryDirectory() }

    private func api(replies: [String: DeskChatServerProtocol.Reply]) -> (client: APIClient, host: String) {
        let host = "t\(UUID().uuidString.lowercased().prefix(8)).test"
        DeskChatServerProtocol.register(host: host, replies: replies)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeskChatServerProtocol.self]
        return (APIClient(baseURL: URL(string: "https://\(host)")!, session: URLSession(configuration: configuration), token: { "token-test" }), host)
    }

    private func harness() throws -> DeskChatHarness { try DeskChatHarness.make() }

    private func entry(_ shell: EdgeShellModel, _ n: Int) -> RailEntry? {
        shell.slots.first { $0.source == .claudeApp(sessionID: Sessions.id(n)) }
    }

    // MARK: 게이트 · 번들 · 자리

    @Test func theGateIsOnForDebugAndInternalBuildsAndOffForReleaseAndThisHostIsDebug() {
        #expect(ClaudeAppRelayGate.isEnabled(isDebugBuild: true, isInternalBuild: false))
        #expect(ClaudeAppRelayGate.isEnabled(isDebugBuild: false, isInternalBuild: true))
        #expect(!ClaudeAppRelayGate.isEnabled(isDebugBuild: false, isInternalBuild: false), "Release는 늘 꺼짐")
        #expect(ClaudeAppChatRuntime.enabledForThisRun == (EdgeSurfaces.isDebugBuild || InternalBuildFlag.isEnabled(info: Bundle.main.infoDictionary)))
    }

    @Test func theAppBundleCarriesExactlyTheModTheHashesPin() {
        let directory = ClaudeAppChatRuntime.modDirectory()
        #expect(directory.hasSuffix("/Contents/Resources/tf-relay"), "서명된 번들 안 읽기 전용 경로")
        #expect(ClaudeAppRelayMod.verify(directory: directory) == .ok, "번들의 세 파일이 상수 SHA-256과 같고 다른 파일(`tests/` 포함)이 없다")
        // 번들 안의 읽기 전용 mod를 고치면 띄우기 전에 거절한다 (임시 복사본을 한 글자 바꿔 본다)
        guard let copy = try? temporaryDirectory().appending(path: "tf-relay", directoryHint: .isDirectory) else {
            Issue.record("임시 폴더를 만들 수 없다")
            return
        }
        #expect((try? FileManager.default.copyItem(atPath: directory, toPath: copy.path)) != nil)
        #expect(ClaudeAppRelayMod.verify(directory: copy.path) == .ok)
        let register = copy.appending(path: "hooks/register.js")
        #expect((try? (String(contentsOf: register, encoding: .utf8) + "\n// x").write(to: register, atomically: true, encoding: .utf8)) != nil)
        #expect(ClaudeAppRelayMod.verify(directory: copy.path) == .mismatch("hooks/register.js"))
    }

    @Test func theRelayFoldersLiveUnderTheBundleIDInAppDataAndNothingIsCreated() throws {
        let support = try temporaryDirectory()
        let folders = try #require(ClaudeAppChatRuntime.relayFolders(supportDirectory: support))
        let bundleID = try #require(Bundle.main.bundleIdentifier)
        let base = support.appending(path: bundleID, directoryHint: .isDirectory).appending(path: "claude-app-relay", directoryHint: .isDirectory)
        #expect(folders.work == base.appending(path: "cwd", directoryHint: .isDirectory).path && folders.ended == base.appending(path: "relay.ended"))
        #expect(bundleID.hasPrefix("dev.taskforcelabs.unittest"), "시험 호스트는 실사용 앱의 폴더를 쓰지 않는다")
        #expect((try FileManager.default.contentsOfDirectory(atPath: support.path)).isEmpty, "자리를 계산할 뿐 폴더를 만들지 않는다 (띄울 때 지킴이가 만든다)")
    }

    @Test func theReleaseBranchMakesNoChatFlowAndTheGatedBranchMakesOneWithoutStartingAnything() throws {
        let scope = AccountScope(currentAccount: { SampleData.userID })
        let store = EdgeExternalSessionsTests().make().store
        let home = try temporaryDirectory().path
        let off = ClaudeAppRuntime.make(
            services: EdgeExternalSessionsTests.services, scope: scope, externalSessions: store, home: home, done: InMemoryClaudeAppDoneStore(), chatEnabled: false
        )
        #expect(off != nil && off?.chat == nil, "게이트가 꺼진 빌드는 데스크톱 링은 그대로고 대화 흐름이 없다 (읽기 전용 그대로)")
        let on = ClaudeAppRuntime.make(
            services: EdgeExternalSessionsTests.services, scope: scope, externalSessions: store, home: home, done: InMemoryClaudeAppDoneStore(), chatEnabled: true
        )
        #expect(on?.chat != nil)
        #expect(on?.chat?.relayPIDs === ClaudeAppRelayPIDs.shared, "레일 · 목록이 빼는 값과 중계가 쓰는 값이 같은 하나다")
        #expect(ClaudeAppRuntime.make(services: nil, scope: scope, externalSessions: store, home: home, done: InMemoryClaudeAppDoneStore(), chatEnabled: true) == nil)
    }

    // MARK: 입력창 자리 판단 (DZ 시트 2 · 3 · 4 · 5)

    @Test func theFooterPlanShowsTheConfirmCardTheBandAndTheComposerInThatOrderAndNeverAnApproveButton() {
        typealias Plan = ClaudeAppFooterPlan
        let open: (composerShown: Bool, isConfirming: Bool) = (true, false)
        #expect(Plan.of(band: nil, chat: open) == Plan(confirm: false, band: nil, composer: true), "평소: 입력창")
        #expect(Plan.of(band: nil, chat: (true, true)) == Plan(confirm: true, band: nil, composer: true), "첫 보내기: 확인 카드가 위, 입력창은 그대로")
        #expect(Plan.of(band: .approve, chat: open) == Plan(confirm: false, band: .approve, composer: true), "승인을 기다려도 입력창은 열려 있다 (Queued로 간다)")
        #expect(Plan.of(band: .answer, chat: open) == Plan(confirm: false, band: .answer, composer: true))
        #expect(Plan.of(band: nil, chat: (false, false)) == Plan(confirm: false, band: nil, composer: false), "닫힘 · 기록 못 읽음: 입력창 없음")
        #expect(Plan.of(band: nil, chat: (false, true)).confirm == false, "입력창이 없으면 확인 카드도 없다")
        #expect(Plan.of(band: .approve, chat: nil) == Plan(confirm: false, band: .approve, composer: false), "Release: 읽기 전용 띠 그대로")
        #expect(Plan.of(band: nil, chat: nil) == Plan(confirm: false, band: nil, composer: false))
        #expect(Plan.bandButtons == ["Open in Claude"], "띠의 단추는 하나: Taskforce는 어느 질문 · 권한에도 답하지 않는다")
        let words = Plan.bandButtons.joined(separator: " ").lowercased()
        #expect(!words.contains("approve") && !words.contains("deny") && !words.contains("allow") && !words.contains("reject"))
    }

    @Test func aReceivedBubbleGivesWayOnceItsTranscriptLineIsShownAndEverythingElseStays() {
        func delivery(_ state: ClaudeAppDeliveryTracker.State, matched: String? = nil) -> ClaudeAppSessionChat.Delivery {
            ClaudeAppSessionChat.sampleDelivery(text: "x", state: state, matchedTurnID: matched)
        }
        let all = [
            delivery(.sending), delivery(.sent), delivery(.queued(.approval)), delivery(.notSent(.bypass)), delivery(.received, matched: "L1"), delivery(.received, matched: "L2"),
            delivery(.received, matched: nil),
        ]
        let shown = ClaudeAppDeliveryBubbles.visible(all, shownTurnIDs: ["L1"])
        #expect(shown.count == 6 && !shown.contains { $0.matchedTurnID == "L1" }, "기록에 그 줄이 보이면 말풍선은 사라지고 기록의 줄이 이어받는다")
        #expect(ClaudeAppDeliveryBubbles.visible(all, shownTurnIDs: []).count == 7, "아직 기록에 안 보이면 모두 남는다")
        #expect(ClaudeAppDeliveryBubbles.visible([], shownTurnIDs: ["L1"]).isEmpty)
    }

    // MARK: 서버 연결

    @Test func theServerIsNotCalledBeforeTheFirstSendAndABlockedSendReportsOnlyTheResultAndTheReasonCode() async throws {
        let (client, host) = api(replies: ["/api/v2/external-sessions/claude-app-sent": .init(status: 204, body: "")])
        let relay = ClaudeAppRelay(
            configuration: ClaudeAppRelay.Configuration(modDirectory: ClaudeAppChatRuntime.modDirectory(), workDirectory: try temporaryDirectory().path), launcher: DeskChatRefusingLauncher(),
            pids: ClaudeAppRelayPIDs()
        )
        let desktop = ClaudeAppSessionsModel(poll: { DeskScript().poll() }, done: InMemoryClaudeAppDoneStore())
        let scope = AccountScope(currentAccount: { SampleData.userID })
        let home = try temporaryDirectory().path
        let service = ClaudeAppChatRuntime.makeService(relay: relay, api: client, scope: scope, desktop: desktop, externalSessions: nil, home: home, log: NoBridgeLog())
        let chat = service.chat(for: Sessions.id(1))
        chat.setVisible(true)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(DeskChatServerProtocol.requests(host: host).isEmpty, "보이기만 해서는 서버를 부르지 않는다 (저장 켜짐 확인도 지표도 첫 글부터)")
        // 이 Mac에 그 세션의 등록이 없다(임시 홈): 보내기 전 확인이 막는다 → Not sent · 닫힘, 지표는 결과 + 이유 코드뿐
        chat.draft = "SECRET-DRAFT-TEXT"
        await chat.submit().value
        #expect(chat.deliveries.count == 1 && chat.draft.isEmpty)
        let state = try #require(chat.deliveries.first?.state)
        guard case .notSent(let reason) = state else {
            Issue.record("막혔는데 Not sent가 아니다")
            return
        }
        #expect(await eventually { DeskChatServerProtocol.requests(host: host).count == 1 })
        let sent = try #require(DeskChatServerProtocol.requests(host: host).last)
        #expect(sent.method == "POST" && sent.path == "/api/v2/external-sessions/claude-app-sent" && sent.headers["Authorization"] == "Bearer token-test")
        let body = try #require(sent.body)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(object == ["result": "not_sent", "reason": reason.code], "글 · 세션 id · 경로가 없다")
        #expect(!String(decoding: body, as: UTF8.self).contains("SECRET"))
        #expect(!DeskChatServerProtocol.requests(host: host).contains { $0.path.contains("claude-app-chats") }, "막힌 글은 저장 켜짐을 묻지도 올리지도 않는다")
        await service.shutdown()
    }

    @Test func theSaverAsksTheStatusRouteAndUploadsToThePutRouteWithTheBearerWhenSavingIsOn() async throws {
        let (client, host) = api(replies: [
            "/api/v2/claude-app-chats/status": .init(status: 200, body: #"{"save":true,"max_batch":20,"max_bytes":262144}"#),
            "/api/v2/claude-app-chats": .init(status: 200, body: #"{"chat_id":"22222222-2222-4333-8444-555555555555","saved":1,"existing":0,"orphan":0}"#),
        ])
        let saver = ClaudeAppChatRuntime.makeSaver(api: client, log: NoBridgeLog(), sleep: { _ in try? await Task.sleep(for: .milliseconds(10)) })
        #expect(DeskChatServerProtocol.requests(host: host).isEmpty, "만든 것만으로는 서버를 부르지 않는다")
        #expect(await saver.refresh() == false)
        #expect(await saver.isSaving)
        let status = try #require(DeskChatServerProtocol.requests(host: host).last)
        #expect(status.method == "GET" && status.path == "/api/v2/claude-app-chats/status" && status.headers["Authorization"] == "Bearer token-test" && status.body == nil)
        let context = ClaudeAppChatContext(bridgeID: UUID(uuidString: "11111111-2222-4333-8444-555555555555")!, sessionRef: String(repeating: "c", count: 64), title: nil)
        let row = ClaudeAppChatRow(macRef: String(repeating: "1", count: 64), role: .user, replyToRef: nil, body: "hi", truncated: false, saidAt: Date(timeIntervalSince1970: 1_800_000_000), toolNames: [])
        await saver.enqueue(ClaudeAppChatBatch(exchangeID: "e1", context: context, rows: [row]))
        #expect(await eventually { DeskChatServerProtocol.requests(host: host).contains { $0.method == "PUT" } })
        let put = try #require(DeskChatServerProtocol.requests(host: host).first { $0.method == "PUT" })
        #expect(put.path == "/api/v2/claude-app-chats" && put.headers["Authorization"] == "Bearer token-test")
        let putBody = try #require(put.body)
        let object = try #require(try JSONSerialization.jsonObject(with: putBody) as? [String: Any])
        #expect(Set(object.keys) == ["bridge_id", "session_ref", "messages"], "제목을 모르면 칸을 뺀다")
        await saver.clear()
    }

    @Test func aNotFoundStatusMeansStoringIsOffSoNothingIsEverUploaded() async throws {
        let (client, host) = api(replies: [:])
        let saver = ClaudeAppChatRuntime.makeSaver(api: client, log: NoBridgeLog(), sleep: { _ in try? await Task.sleep(for: .milliseconds(10)) })
        #expect(await saver.refresh() == false)
        #expect(await !saver.isSaving, "404 = 꺼짐 · 명단 밖: 업로더를 만들지 않는다 (DT14)")
        let context = ClaudeAppChatContext(bridgeID: UUID(), sessionRef: String(repeating: "c", count: 64), title: nil)
        let row = ClaudeAppChatRow(macRef: String(repeating: "1", count: 64), role: .user, replyToRef: nil, body: "hi", truncated: false, saidAt: Date(), toolNames: [])
        await saver.enqueue(ClaudeAppChatBatch(exchangeID: "e1", context: context, rows: [row]))
        try? await Task.sleep(for: .milliseconds(200))
        #expect(DeskChatServerProtocol.requests(host: host).allSatisfy { $0.method == "GET" }, "글은 서버로 한 바이트도 가지 않는다")
    }

    @Test func leavingTheAccountDropsTheDraftAndTheSentMessagesAndHandsOutAFreshChat() async throws {
        let (client, _) = api(replies: [:])
        let relay = ClaudeAppRelay(
            configuration: ClaudeAppRelay.Configuration(modDirectory: ClaudeAppChatRuntime.modDirectory(), workDirectory: try temporaryDirectory().path), launcher: DeskChatRefusingLauncher(),
            pids: ClaudeAppRelayPIDs()
        )
        let desktop = ClaudeAppSessionsModel(poll: { DeskScript().poll() }, done: InMemoryClaudeAppDoneStore())
        let scope = AccountScope(currentAccount: { SampleData.userID })
        let service = ClaudeAppChatRuntime.makeService(relay: relay, api: client, scope: scope, desktop: desktop, externalSessions: nil, home: try temporaryDirectory().path, log: NoBridgeLog())
        let before = service.chat(for: Sessions.id(1))
        before.draft = "a draft of the first account"
        scope.accountLeft()
        #expect(await eventually { service.chat(for: Sessions.id(1)) !== before })
        let after = service.chat(for: Sessions.id(1))
        #expect(after.draft.isEmpty && after.deliveries.isEmpty, "다음 계정에 쓰던 글이 넘어가지 않는다")
        await service.shutdown()
    }

    // MARK: peer 줄 밑의 표시

    @Test func onlyAMessageFromTheRunningRelayIsReceivedViaTaskforceEverythingElseIsFromAnotherSession() throws {
        let h = try harness()
        h.relay.pids.set([4001])
        let ours = ClaudeAppPeer(plugin: "tf-relay", verifiedPeerPID: 4001, messageID: "m1")
        #expect(h.service.peerLine(for: ours).text == "Received · via Taskforce")
        for foreign in [
            ClaudeAppPeer(plugin: "tf-relay", verifiedPeerPID: 4002, messageID: "m2"),
            ClaudeAppPeer(plugin: "other", verifiedPeerPID: 4001, messageID: "m3"),
            ClaudeAppPeer(plugin: nil, verifiedPeerPID: nil, messageID: nil),
        ] {
            #expect(h.service.peerLine(for: foreign).text == "From another session", "이름만 같은 것 · 앞 실행의 중계 · 증거 없는 것은 우리 사용자의 글이 아니다")
        }
        h.relay.pids.set([])
        #expect(h.service.peerLine(for: ours).text == "From another session", "중계가 떠 있지 않으면 같은 pid도 우리 것이라 하지 않는다")
    }

    @Test func aPeerBubbleGrowsByTheLineUnderItOnlyWhenThereIsAChatFlow() {
        let turn = ClaudeAppTurn(id: "p1", kind: .peer("Please also run the tests", ClaudeAppPeer(plugin: "x", verifiedPeerPID: 1, messageID: "m")))
        func height(_ line: MessageDeliveryLine?) -> CGFloat {
            let hosting = NSHostingView(rootView: ClaudeAppTurnView(turn: turn, peerLine: line).frame(width: 340))
            hosting.frame = NSRect(x: 0, y: 0, width: 340, height: 400)
            hosting.layoutSubtreeIfNeeded()
            return hosting.fittingSize.height
        }
        let plain = height(nil)
        let withLine = height(MessageDeliveryLine(strong: nil, text: "From another session"))
        #expect(withLine > plain + 8, "Release(줄 없음)는 지금 그대로, 대화 흐름이 있는 빌드는 말풍선 밑에 한 줄 (\(plain) → \(withLine))")
    }

    // MARK: 패널 안

    /// 실제 패널 내용(`ClaudeAppSessionPanelView`)을 창에 올려 그린다. 입력창 자리 높이를 돌려준다
    private func render(_ r: Sessions.Rig, wait: @MainActor () -> Bool = { true }) async throws -> EdgeClaudeAppPanelPresentation {
        let presentation = EdgeClaudeAppPanelPresentation()
        presentation.shown = true
        let hosting = NSHostingView(rootView: ClaudeAppSessionPanelView(shell: r.shell, presentation: presentation))
        hosting.frame = NSRect(x: 0, y: 0, width: 380, height: 520)
        let panel = EdgeKeyPanel(contentRect: hosting.frame, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        panel.contentView = hosting
        panel.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        _ = await eventually { presentation.headHeight > 0 && r.shell.desktopConversation?.phase != .loading && wait() }
        try? await Task.sleep(for: .milliseconds(150))
        panel.orderOut(nil)
        return presentation
    }

    @Test func thePanelHasAComposerOnlyInABuildWithTheChatFlowAndTheReleaseFooterStaysAsItWas() async throws {
        let release = await Sessions().rig(rows: [1], live: [Sessions.live(1, .busy)])
        release.shell.openRailEntry(try #require(entry(release.shell, 1)))
        let plain = try await render(release)
        release.shell.dismiss()
        #expect(plain.footerHeight == TFSpace.sm, "게이트가 꺼진 빌드: 입력창 자리에는 아래 여백뿐 (읽기 전용 그대로)")

        let h = try harness()
        let gated = await Sessions().rig(rows: [1], live: [Sessions.live(1, .busy)], chat: h.service)
        gated.shell.openRailEntry(try #require(entry(gated.shell, 1)))
        let withChat = try await render(gated)
        #expect(withChat.footerHeight > 50, "입력창이 선다 (\(withChat.footerHeight))")
        gated.shell.dismiss()
    }

    @Test func anApprovalBandKeepsItsOnlyButtonAndTheComposerStaysOpenBelowIt() async throws {
        let release = await Sessions().rig(rows: [1], live: [Sessions.live(1, .waiting(.approval))])
        release.shell.openRailEntry(try #require(entry(release.shell, 1)))
        let band = try await render(release)
        release.shell.dismiss()
        let h = try harness()
        let gated = await Sessions().rig(rows: [1], live: [Sessions.live(1, .waiting(.approval))], chat: h.service)
        gated.shell.openRailEntry(try #require(entry(gated.shell, 1)))
        let both = try await render(gated)
        gated.shell.dismiss()
        #expect(both.footerHeight > band.footerHeight + 40, "띠 밑에 입력창: 띠만 있을 때보다 입력창만큼 높다 (\(band.footerHeight) → \(both.footerHeight))")
        #expect(h.service.chat(for: Sessions.id(1)).composerShown)
    }

    @Test func aClosedOrUnreadableSessionHasNoComposerAndTheViewStateReachesTheChatFlow() async throws {
        let h = try harness()
        let closed = await Sessions().rig(rows: [1], live: [Sessions.live(1, .busy)], chat: h.service)
        closed.shell.openRailEntry(try #require(entry(closed.shell, 1)))
        let open = try await render(closed)
        #expect(h.service.chat(for: Sessions.id(1)).view == .open && open.footerHeight > 50)
        for _ in 0..<5 { await closed.poll([]) }
        #expect(closed.desktop.viewingClosed)
        let shut = try await render(closed, wait: { h.service.chat(for: Sessions.id(1)).view == .closed })
        let chat = h.service.chat(for: Sessions.id(1))
        #expect(chat.view == .closed && !chat.composerShown && shut.footerHeight == TFSpace.sm, "Claude에서 닫으면 입력창이 사라진다")
        closed.shell.dismiss()

        let h2 = try harness()
        let broken = await Sessions().rig(rows: [2], live: [Sessions.live(2, .busy)], chat: h2.service)
        broken.transcript.unreadable = true
        broken.shell.openRailEntry(try #require(entry(broken.shell, 2)))
        let failed = try await render(broken, wait: { h2.service.chat(for: Sessions.id(2)).view == .unreadable })
        let brokenChat = h2.service.chat(for: Sessions.id(2))
        #expect(brokenChat.view == .unreadable && !brokenChat.composerShown && failed.footerHeight == TFSpace.sm, "기록을 못 읽으면 입력창이 없다")
        broken.shell.dismiss()
    }

    @Test func theComposerIsShownWhileThePanelShowsTheSessionAndFollowsTheSessionTheRailOpens() async throws {
        let h = try harness()
        let r = await Sessions().rig(rows: [1, 2], live: [Sessions.live(1, .busy), Sessions.live(2, .busy)], chat: h.service)
        let one = h.service.chat(for: Sessions.id(1)), two = h.service.chat(for: Sessions.id(2))
        #expect(!one.isVisible && !two.isVisible, "패널을 열기 전에는 중계도 입력창도 쓰지 않는다")
        r.shell.openRailEntry(try #require(entry(r.shell, 1)))
        #expect(one.isVisible && !two.isVisible)
        r.shell.openRailEntry(try #require(entry(r.shell, 2)))
        #expect(!one.isVisible && two.isVisible, "다른 링을 열면 이전 세션의 입력창은 접힌다")
        #expect(await eventually { h.launcher.launches >= 1 }, "보이면 중계를 미리 띄워 둔다 (첫 보내기가 빠르다)")
        r.shell.dismiss()
        #expect(!one.isVisible && !two.isVisible, "패널을 접으면 쓰는 곳이 없어진다 (2분 뒤 중계가 끝난다)")
    }
}
