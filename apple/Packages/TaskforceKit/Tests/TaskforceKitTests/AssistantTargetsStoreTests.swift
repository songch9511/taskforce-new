import Foundation
import Testing
@testable import TaskforceKit

/// 대상 목록 저장소 (OA U1): `GET /api/v2/assistant/targets`를 읽어 대상 메뉴의 행으로. 읽기 실패는 마지막 목록을 지키고, 기능이 꺼져 있으면 Taskforce뿐이다
@MainActor
struct AssistantTargetsStoreTests {
    let assistant = FakeAssistantGateway()
    nonisolated static let claudeConnection = UUID(uuidString: "a3333333-3333-4333-8333-333333333333")!
    nonisolated static let codexConnection = UUID(uuidString: "a3333333-3333-4333-8333-333333333334")!
    var claude: UUID { Self.claudeConnection }
    var codex: UUID { Self.codexConnection }

    nonisolated static let served: [AssistantTarget] = [
        .taskforce,
        .agent(.init(adapter: "agent:claude-code", displayName: "Claude Code", connectionID: claudeConnection, state: .unsupported, access: nil)),
        .agent(.init(adapter: "agent:codex", displayName: "Codex", connectionID: codexConnection, state: .ready, access: .readOnly)),
    ]

    func store(canRun: Bool = true, gateway: (any AssistantGateway)? = nil, scope: AccountScope = ChatTestAccount.fixedScope()) -> AssistantTargetsStore {
        AssistantTargetsStore(gateway: gateway ?? assistant, scope: scope, canRunAgents: { canRun })
    }

    @Test func beforeTheFirstReadOnlyTaskforceIsListed() {
        let targets = store()
        #expect(targets.options.map(\.name) == ["Taskforce"] && targets.load == .idle)
    }

    @Test func aReadFillsTheMenuWithAgentsAndTheirStatusWords() async {
        assistant.targetsHandler = { Self.served }
        let targets = store()
        await targets.refresh()
        #expect(targets.load == .loaded)
        #expect(targets.options.map(\.name) == ["Taskforce", "Claude Code", "Codex"])
        #expect(targets.options.map(\.status) == [nil, "Unsupported", "Read only"])
        #expect(targets.adapter(forConnection: codex) == "agent:codex" && targets.adapter(forConnection: UUID()) == nil)
        #expect(targets.mark(forConnection: claude) == .claudeCode && targets.mark(forConnection: UUID()) == .placeholder)
    }

    @Test func theBuildVerdictOverridesEveryAgentStatus() async {
        assistant.targetsHandler = { Self.served }
        let targets = store(canRun: false)
        await targets.refresh()
        #expect(targets.options.map(\.status) == [nil, "Can't run agents in this build", "Can't run agents in this build"])
    }

    @Test func aFailedReadKeepsTheLastListAndSaysSo() async {
        assistant.targetsHandler = { Self.served }
        let targets = store()
        await targets.refresh()
        assistant.targetsHandler = { throw URLError(.notConnectedToInternet) }
        await targets.refresh()
        #expect(targets.load == .failed)
        #expect(targets.options.map(\.name) == ["Taskforce", "Claude Code", "Codex"], "읽지 못해도 마지막으로 읽은 목록을 지킨다")
    }

    @Test func aGateThatIsOffMeansOnlyTaskforce() async {
        assistant.targetsHandler = { Self.served }
        let targets = store()
        await targets.refresh()
        #expect(targets.options.count == 3)
        assistant.targetsHandler = { throw APIError.server(status: 404, code: .notFound, message: APIError.featureOffMessage) }
        await targets.refresh()
        #expect(targets.load == .unavailable && targets.options.map(\.name) == ["Taskforce"])
        // 다시 켜지면 읽는다
        assistant.targetsHandler = { Self.served }
        await targets.refresh()
        #expect(targets.load == .loaded && targets.options.count == 3)
    }

    @Test func theMenuStatusFollowsTheReadFromLoadingToReadyOrFailed() async {
        let latch = Latch()
        assistant.targetsHandler = { await latch.wait(); return Self.served }
        let targets = store()
        #expect(targets.menuStatus == .loading, "읽기 전에는 에이전트 목록이 없다: 기다리는 중")
        let read = Task { await targets.refresh() }
        _ = await latch.waitForArrivals(1, timeout: .seconds(5))
        #expect(targets.menuStatus == .loading && targets.options.map(\.name) == ["Taskforce"])
        await latch.open()
        await read.value
        #expect(targets.menuStatus == .ready && targets.options.count == 3, "읽기가 끝나면 같은 저장소의 에이전트 행이 나타난다")
        assistant.targetsHandler = { throw URLError(.notConnectedToInternet) }
        await targets.refresh()
        #expect(targets.menuStatus == .failed, "마지막 목록이 남아 있어도 실패는 말한다")
        assistant.targetsHandler = { Self.served }
        await targets.refresh()
        #expect(targets.menuStatus == .ready, "다시 읽으면 실패 줄이 사라진다")
    }

    @Test func aFailedFirstReadIsFailedNotLoadingAndAFeatureThatIsOffIsJustTaskforce() async {
        assistant.targetsHandler = { throw URLError(.timedOut) }
        let failing = store()
        await failing.refresh()
        #expect(failing.menuStatus == .failed && failing.options.map(\.name) == ["Taskforce"])
        assistant.targetsHandler = { throw APIError.server(status: 404, code: .notFound, message: APIError.featureOffMessage) }
        let off = store()
        await off.refresh()
        #expect(off.menuStatus == .ready, "기능이 꺼진 것은 실패가 아니다: Taskforce뿐")
        let none = AssistantTargetsStore(gateway: nil, scope: ChatTestAccount.fixedScope(), canRunAgents: { true })
        #expect(none.menuStatus == .ready, "게이트웨이가 없으면 기다릴 것도 없다")
    }

    @Test func withoutAGatewayThereIsNothingToReadAndNothingIsCalled() async {
        let targets = AssistantTargetsStore(gateway: nil, scope: ChatTestAccount.fixedScope(), canRunAgents: { true })
        await targets.refresh()
        #expect(targets.options.map(\.name) == ["Taskforce"] && assistant.calls.isEmpty && targets.load == .unavailable)
    }

    @Test func aGatewayGivenLaterIsUsedByTheNextRead() async {
        let targets = AssistantTargetsStore(gateway: nil, scope: ChatTestAccount.fixedScope(), canRunAgents: { true })
        await targets.refresh()
        #expect(targets.load == .unavailable)
        assistant.targetsHandler = { Self.served }
        targets.gateway = assistant
        await targets.refresh()
        #expect(targets.load == .loaded && targets.options.count == 3)
    }

    @Test func overlappingReadsShareOneRequest() async {
        let latch = Latch()
        assistant.targetsHandler = {
            await latch.wait()
            return [.taskforce]
        }
        let targets = store()
        async let first: Void = targets.refresh()
        async let second: Void = targets.refresh()
        _ = await latch.waitForArrivals(1, timeout: .seconds(5))
        await latch.open()
        _ = await (first, second)
        #expect(assistant.calls(prefix: "targets").count == 1)
    }

    @Test func theMenuFindsTheRowOfAPick() async {
        assistant.targetsHandler = { Self.served }
        let targets = store()
        await targets.refresh()
        #expect(targets.option(for: .taskforce)?.name == "Taskforce")
        #expect(targets.option(for: .agent(adapter: "", connectionID: codex))?.name == "Codex")
        #expect(targets.option(for: .agent(adapter: "agent:codex", connectionID: nil))?.name == "Codex")
        #expect(targets.option(for: .agent(adapter: "agent:gone", connectionID: nil)) == nil)
    }

    @Test func aDeviceNameFromTheResolverSeparatesTwoRowsOfOneAdapter() async {
        let other = UUID()
        assistant.targetsHandler = {
            [
                .taskforce,
                .agent(.init(adapter: "agent:codex", displayName: "Codex", connectionID: Self.codexConnection, state: .ready, access: .write)),
                .agent(.init(adapter: "agent:codex", displayName: "Codex", connectionID: other, state: .ready, access: .write)),
            ]
        }
        let targets = store()
        targets.deviceName = { $0 == other ? "MacBook Pro" : nil }
        await targets.refresh()
        #expect(targets.options.map(\.deviceName) == [nil, nil, "MacBook Pro"])
    }

    @Test func leavingTheAccountForgetsTheList() async throws {
        let account = try ChatTestAccount.make()
        assistant.targetsHandler = { Self.served }
        let targets = AssistantTargetsStore(gateway: assistant, scope: account.scope, canRunAgents: { true })
        await targets.refresh()
        #expect(targets.options.count == 3)
        account.session.apply(event: .signedOut, session: nil)
        #expect(targets.options.map(\.name) == ["Taskforce"] && targets.load == .idle)
    }

    @Test func aLateAnswerFromAnotherAccountIsDropped() async throws {
        let account = try ChatTestAccount.make()
        let latch = Latch()
        assistant.targetsHandler = {
            await latch.wait()
            return Self.served
        }
        let targets = AssistantTargetsStore(gateway: assistant, scope: account.scope, canRunAgents: { true })
        let read = Task { await targets.refresh() }
        _ = await latch.waitForArrivals(1, timeout: .seconds(5))
        account.relogin()
        await latch.open()
        await read.value
        #expect(targets.options.map(\.name) == ["Taskforce"], "그 사이 계정이 바뀌었으면 늦게 온 목록은 쓰지 않는다")
    }
}
