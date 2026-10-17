#if os(macOS)
import Foundation
import Testing
@testable import TaskforceKit

/// `POST /api/v1/bridge/tool-decision`의 Swift 짝 (OA D3a 계약 3.1 · 2.17, D3c-2 3.2). 요청 · 응답 픽스처는 서버 zod로도 대조한다 (`swift-fixtures.test.ts`)
struct BridgeV1ToolDecisionTests {
    static let bridgeID = "b1111111-1111-4111-8111-111111111111"
    static let secret = "c2VjcmV0c2VjcmV0c2VjcmV0c2VjcmV0c2VjcmV0MTI"
    static let user = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!

    static func fixture(_ name: String) throws -> [String: Any] {
        let url = try #require(Bundle.module.url(forResource: "bridge-v1/\(name)", withExtension: "json"))
        return try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    static func query(_ call: BridgeV1ToolCall) -> BridgeV1ToolDecisionQuery {
        BridgeV1ToolDecisionQuery(agentSessionID: ClaudeTest.session, agentTaskID: ClaudeTest.task, turnSeq: 3, workspaceRealPath: "/Users/u/proj", call: call)
    }

    static let calls: [String: BridgeV1ToolCall] = [
        "claude_bash": .claudeBash(toolUseID: "toolu_01", permissionMode: "default", cwd: "/Users/u/proj", command: "ls -la src", runInBackground: false, dangerouslyDisableSandbox: false),
        "claude_write": .claudeWrite(toolUseID: "toolu_02", permissionMode: "default", tool: "Write", target: BridgeV1ToolTarget(realPath: "/Users/u/proj/src/a.txt", relPath: "src/a.txt")),
        "codex_command": .codexCommand(providerRequestID: "item-1:approval", cwd: "/Users/u/proj", command: "/bin/zsh -lc 'ls src'", commandActions: ["listFiles"], firstForItem: true),
        "codex_file_change": .codexFileChange(providerRequestID: "item-2:approval", targets: [BridgeV1ToolTarget(realPath: "/Users/u/proj/b.txt", relPath: "b.txt")], firstForItem: true),
    ]

    @Test func requestsEncodeExactlyLikeTheFixture() throws {
        let fixture = try Self.fixture("tool-decision-request")
        for (name, call) in Self.calls {
            let encoded = try TaskforceJSON.encoder().encode(BridgeV1ToolDecisionRequest(bridgeID: Self.bridgeID, query: Self.query(call)))
            let ours = try #require(try JSONSerialization.jsonObject(with: encoded) as? NSDictionary)
            let expected = try #require(fixture[name] as? NSDictionary)
            #expect(ours == expected, "\(name)")
        }
    }

    @Test func responsesDecodeIncludingUnknownReasonsAndFlags() throws {
        let fixture = try Self.fixture("tool-decision-response")
        func decode(_ name: String) throws -> BridgeV1ToolDecisionResponse {
            let value = try #require(fixture[name])
            return try TaskforceJSON.decoder().decode(BridgeV1ToolDecisionResponse.self, from: JSONSerialization.data(withJSONObject: value))
        }
        let readonly = try decode("allow_readonly")
        #expect(readonly.decision == .allow && readonly.reason == .readonlyCommand)
        #expect(readonly.parse == BridgeV1ToolDecisionParse(wrapper: "none", argv: ["ls", "-la", "src"], paths: [.init(index: 2, absolute: "/Users/u/proj/src")], implicitCwd: false))
        let deny = try decode("deny_path_in_use")
        #expect(deny.decision == .deny && deny.reason == .pathInUse && deny.agentNote != nil && deny.holder == BridgeV1ToolDecisionHolder(actionNumber: 139, relPath: "pricing.mdx"))
        let defer_ = try decode("defer_manual_write")
        #expect(defer_.decision == .defer && defer_.reason == .manualWrite && defer_.cardFlags.isEmpty)
        let future = try decode("future_values")
        #expect(future.decision == .unknown("ask_later") && future.reason == .unknown("new_reason") && future.cardFlags == ["new_flag"])
        #expect(!future.isUnderstood)
        #expect(readonly.isUnderstood && deny.isUnderstood && defer_.isUnderstood)
    }

    @Test func theClientLimitsMatchTheServerSchema() {
        #expect(BridgeV1ToolDecisionLimits.fits(Self.query(Self.calls["claude_bash"]!)))
        let longCommand = Self.query(.claudeBash(toolUseID: "t", permissionMode: "default", cwd: "/w", command: String(repeating: "a", count: 4097), runInBackground: false, dangerouslyDisableSandbox: false))
        #expect(!BridgeV1ToolDecisionLimits.fits(longCommand))
        let longPath = Self.query(.claudeWrite(toolUseID: "t", permissionMode: "default", tool: "Write", target: BridgeV1ToolTarget(realPath: "/" + String(repeating: "a", count: 1000), relPath: "a")))
        #expect(!BridgeV1ToolDecisionLimits.fits(longPath))
        for bad in ["relative", "/a/../b", "/a/./b", "/a//b", "/a/\u{1}b", "/a/"] {
            #expect(!BridgeV1ToolDecisionLimits.isRealPath(bad), "\(bad)")
        }
        #expect(BridgeV1ToolDecisionLimits.isRealPath("/"))
        var workspace = Self.query(Self.calls["claude_bash"]!)
        workspace.workspaceRealPath = "/" + String(repeating: "가", count: 500)
        #expect(!BridgeV1ToolDecisionLimits.fits(workspace))
        var notGUID = Self.query(Self.calls["claude_bash"]!)
        notGUID.agentTaskID = "task-1"
        #expect(!BridgeV1ToolDecisionLimits.fits(notGUID))
    }

    // MARK: BridgeClient.toolDecision (기존 route 함수와 같은 모양)

    @Test func theClientPostsWithTheDeviceSecretAndAOneSecondTimeout() async throws {
        let host = "\(UUID().uuidString.lowercased()).stub.test"
        let body = try JSONSerialization.data(withJSONObject: try #require(Self.fixture("tool-decision-response")["defer_manual_write"]))
        StubURLProtocol.install(host: host) { _ in StubURLProtocol.Reply(status: 200, body: body) }
        let client = BridgeClient(baseURL: URL(string: "https://\(host)")!, session: StubURLProtocol.session(), expectedUserID: Self.user, bearer: { BridgeBearer(userID: Self.user, accessToken: "jwt") })
        let response = try await client.toolDecision(BridgeV1ToolDecisionRequest(bridgeID: Self.bridgeID, query: Self.query(Self.calls["claude_write"]!)), secret: Self.secret, timeout: 1.0)
        #expect(response.reason == .manualWrite)
        let captured = try #require(StubURLProtocol.captured(host: host).first)
        #expect(captured.request.url?.path() == "/api/v1/bridge/tool-decision" && captured.request.httpMethod == "POST")
        #expect(captured.request.value(forHTTPHeaderField: "X-Taskforce-Bridge-Secret") == Self.secret)
        #expect(captured.request.timeoutInterval == 1.0)
        #expect(!String(decoding: captured.body, as: UTF8.self).contains("content"))
    }

    @Test func theRuntimeMapsAForbiddenMacToRevokedAndEverythingElseToUnavailable() async throws {
        for (status, expected) in [(403, AgentToolDecisionError.revoked), (401, .unavailable), (500, .unavailable), (404, .unavailable), (429, .unavailable)] {
            let host = "\(UUID().uuidString.lowercased()).stub.test"
            StubURLProtocol.install(host: host) { _ in StubURLProtocol.Reply(status: status, body: Data("{}".utf8)) }
            let runtime = try await DecisionRuntime(host: host).runtime
            await #expect(throws: expected) { try await runtime.decideTool(Self.query(Self.calls["claude_write"]!)) }
        }
    }

    @Test func theRuntimeDoesNotAskBeforeItIsRegistered() async throws {
        let host = "\(UUID().uuidString.lowercased()).stub.test"
        StubURLProtocol.install(host: host) { _ in
            Issue.record("must not call the server without a bridge id")
            return StubURLProtocol.Reply(status: 200)
        }
        let runtime = try await DecisionRuntime(host: host, registered: false).runtime
        await #expect(throws: AgentToolDecisionError.unavailable) { try await runtime.decideTool(Self.query(Self.calls["claude_write"]!)) }
    }

    @Test func theRuntimeAttachesTheDeciderToEveryAdapterOnce() async throws {
        let probe = AttachProbe()
        let host = "\(UUID().uuidString.lowercased()).stub.test"
        let body = try JSONSerialization.data(withJSONObject: try #require(Self.fixture("tool-decision-response")["defer_manual_write"]))
        StubURLProtocol.install(host: host) { _ in StubURLProtocol.Reply(status: 200, body: body) }
        let holder = try await DecisionRuntime(host: host, adapters: [probe])
        #expect(probe.attachCount == 1)
        let services = try #require(probe.services)
        let response = try await services.decideTool(Self.query(Self.calls["claude_write"]!))
        #expect(response.reason == .manualWrite)
        let sent = try #require(StubURLProtocol.captured(host: host).first)
        let json = try #require(try JSONSerialization.jsonObject(with: sent.body) as? [String: Any])
        #expect(json["bridge_id"] as? String == Self.bridgeID)
        _ = holder
    }
}

/// 등록된 것으로 꾸민 런타임 (원장 meta에 bridge id, 메모리 자격에 secret)
struct DecisionRuntime {
    let temp = TempDirectory()
    let runtime: BridgeRuntime

    init(host: String, registered: Bool = true, adapters: [any AgentProcess] = []) async throws {
        let user = BridgeV1ToolDecisionTests.user
        let partition = BridgePartition(apiOrigin: "https://\(host)", userID: user)
        let ledger = try BridgeLedger(directory: partition.directory(in: temp.url))
        let credentials = InMemoryBridgeCredentialStore()
        if registered {
            try await ledger.updateMeta { $0.bridgeID = BridgeV1ToolDecisionTests.bridgeID }
            try credentials.save(secret: BridgeV1ToolDecisionTests.secret, partition: partition.id)
        }
        let client = BridgeClient(baseURL: URL(string: "https://\(host)")!, session: StubURLProtocol.session(), expectedUserID: user, bearer: { BridgeBearer(userID: user, accessToken: "jwt") })
        runtime = BridgeRuntime(configuration: BridgeRuntimeConfiguration(partition: partition, appVersion: "0.2.0-test"), client: client, ledger: ledger, credentials: credentials, adapters: adapters)
        await runtime.recover()
    }
}

/// `attach`를 몇 번 받았는지 세는 adapter 대역
final class AttachProbe: AgentProcess, @unchecked Sendable {
    private let lock = NSLock()
    private var attached: [AgentRuntimeServices] = []
    let adapter = "agent:probe"

    var attachCount: Int { lock.withLock { attached.count } }
    var services: AgentRuntimeServices? { lock.withLock { attached.last } }

    func attach(_ services: AgentRuntimeServices) { lock.withLock { attached.append(services) } }
    func probe() async -> BridgeV1AdapterReport { BridgeV1AdapterReport(adapter: adapter, installed: true, version: nil, signedIn: .unknown, managedSettings: false) }
    func startTurn(_ turn: AgentTurnStart, events: AgentEventSink) async throws -> AgentProcessIdentity { throw AgentStartError(.spawnFailed) }
    func deliverAnswer(_ answer: AgentAnswerDelivery, events: AgentEventSink) async throws -> AgentAnswerResult { .requestClosed }
    func closeRequest(_ request: AgentRequestRef) async throws {}
    func interrupt(_ target: AgentTurnRef, scope: AgentCancelScope) async -> AgentInterruptResult { .notRunning }
    func liveness(_ identity: AgentProcessIdentity) async -> AgentLiveness { .unknown }
    func terminateOrphan(_ identity: AgentProcessIdentity) async -> AgentLiveness { .unknown }
}
#endif
