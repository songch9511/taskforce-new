import AppKit
import Foundation
import Testing
@testable import TaskforceKit
@testable import Taskforce

/// 폴더 창을 열지 않는 대역 (이 시험들은 폴더를 고르지 않는다). 실제 `NSOpenPanel` 0
@MainActor
private final class NoFolderPicker: AgentWorkspacePicking {
    func pickFolder(message: String, prompt: String, rejection: String, accepts: @escaping @Sendable (String) -> Bool) async -> String? { nil }
}

/// Settings의 실제 면(`LiveAgentSettingsEnvironment`)과 `BridgeHost` · `BridgeRuntime` (OA Settings › Your agents 6.3 · 14.3): 끊으면 런타임을 놓고 새로 만든다 · 다시 연결은 새 런타임에서 · 실패하면 바뀐 것 0.
/// 가짜 서버 · 가짜 agent · 메모리 자격 · 수동 시계만 쓴다 (실제 `claude` · Keychain · 운영 서버 0)
@MainActor
struct SettingsAgentsHostTests {
    private func environment(_ fixture: HostFixture) -> LiveAgentSettingsEnvironment {
        LiveAgentSettingsEnvironment(host: { fixture.host }, targets: nil, reads: nil, picker: NoFolderPicker(), notify: {})
    }

    private func running(connectAtStart: String? = nil) async throws -> (HostFixture, LiveAgentSettingsEnvironment, FakeBridgeServer.Created) {
        let fixture = HostFixture(connectAtStart: connectAtStart)
        fixture.agent.setScript(.staysRunning())
        await fixture.start()
        let created = try #require(await fixture.message())
        #expect(await fixture.eventually { fixture.agent.startedTurns.count == 1 })
        return (fixture, environment(fixture), created)
    }

    // MARK: 읽기

    @Test func theEnvironmentSeesTheRuntimeAndItsStatusThroughTheHost() async throws {
        let fixture = HostFixture()
        defer { fixture.cleanup() }
        await fixture.start()
        let env = environment(fixture)
        #expect(env.canRunAgents, "bridge가 켜졌고 활성 런타임에 Claude Code adapter가 있다")
        #expect(await fixture.eventually { env.runtimeStatus == .connected })
        let bridge = await env.localBridgeID()
        #expect(bridge?.uuidString.lowercased() == fixture.server.bridgeID(userID: try #require(fixture.user.value)))
        let report = await env.probe()
        #expect(report?.adapter == "agent:claude-code" && report?.installed == true)
    }

    @Test func aBridgeThatIsOffHasNoRuntimeSoTheBuildCannotRunAgents() async throws {
        let fixture = HostFixture(enabled: false)
        defer { fixture.cleanup() }
        await fixture.start()
        let env = environment(fixture)
        #expect(!env.canRunAgents && env.runtimeStatus == nil, "bridge가 꺼진 빌드: 런타임도 없다")
        #expect(await env.connect() == .unavailable && fixture.server.requests.isEmpty, "서버 호출 0")
        #expect(env.folders == nil)
    }

    @Test func theStatusIsClearedWhenTheAccountLeaves() async throws {
        let fixture = HostFixture()
        defer { fixture.cleanup() }
        await fixture.start()
        #expect(await fixture.eventually { fixture.host.statusBoard.status == .connected })
        fixture.user.value = nil
        fixture.epoch.value += 1
        await fixture.host.syncAccount()
        #expect(fixture.host.statusBoard.status == nil && !fixture.host.statusBoard.hasLiveProcess, "떠난 계정의 상태를 새 화면에 주장하지 않는다")
    }

    // MARK: Disconnect this Mac → 런타임 바꾸기 → Reconnect

    @Test func disconnectRevokesAtTheServerEndsTheRunReplacesTheRuntimeAndEndsInNotConnected() async throws {
        let (fixture, env, created) = try await running()
        defer { fixture.cleanup() }
        let old = try #require(fixture.host.activeRuntime)
        let userID = try #require(fixture.user.value)
        let bridge = try #require(fixture.server.bridgeID(userID: userID))
        let clock = fixture.advancingClock()
        let outcome = await env.disconnect()
        clock.cancel()
        #expect(outcome == .disconnected(unresolvedProcesses: 0))
        #expect(fixture.server.bridgeIsActive(bridge) == false, "서버가 폐기를 받았다")
        #expect(fixture.agent.liveRunCount == 0, "감독 밖 writer 0")
        #expect(fixture.host.activeRuntime !== old, "끊은 런타임은 `stopSpawning`이 켜져 다시 쓰지 않는다: 새 런타임이다")
        #expect(await old.status == .stopped, "옛 런타임은 놓았다")
        #expect(fixture.host.runtimeCount == 1, "같은 파티션에 런타임은 하나")
        #expect(await fixture.eventually { fixture.host.statusBoard.status == .revoked }, "새 런타임의 첫 자동 등록은 장치 secret이 없어 403: Not connected · Reconnect")
        let partition = fixture.host.activePartition?.id ?? ""
        #expect(try fixture.credentials.secret(partition: partition) == nil)
        #expect(try fixture.credentials.deviceID(partition: partition) != nil, "device_id는 둔다")
        _ = created
    }

    @Test func reconnectOnTheNewRuntimeConnectsAgainAndTheNextTurnSpawns() async throws {
        let (fixture, env, _) = try await running()
        defer { fixture.cleanup() }
        let clock = fixture.advancingClock()
        _ = await env.disconnect()
        clock.cancel()
        #expect(await fixture.eventually { fixture.host.statusBoard.status == .revoked })
        fixture.agent.setScript(.normal())
        let before = fixture.server.requests("register").count
        let outcome = await env.reconnect()
        #expect(outcome == .connected)
        let last = try #require(fixture.server.requests("register").last)
        #expect(fixture.server.requests("register").count == before + 1 && last.json["reactivate"] as? Bool == true && last.json["connect"] as? [String] == ["agent:claude-code"])
        #expect(await fixture.eventually { fixture.host.statusBoard.status == .connected })
        // 옛 stopSpawning이 남지 않는다: 새 세션의 새 턴이 뜬다
        await fixture.message("again", session: UUID().uuidString.lowercased(), task: UUID().uuidString.lowercased())
        #expect(await fixture.eventually { fixture.agent.startedTurns.count == 2 }, "다음 턴 spawn: \(fixture.server.requests.map(\.route))")
    }

    @Test func aFailedRevokeChangesNothingTheSameRuntimeKeepsRunning() async throws {
        let (fixture, env, _) = try await running()
        defer { fixture.cleanup() }
        let old = try #require(fixture.host.activeRuntime)
        fixture.server.failNext("register", .init(status: 500))
        #expect(await env.disconnect() == .failed(.other))
        #expect(fixture.host.activeRuntime === old, "바꾸지 않았다")
        #expect(await old.status == .connected && fixture.agent.liveRunCount == 1 && fixture.agent.interrupts.isEmpty)
        fixture.server.failNext("register", .init(status: 0, transport: true))
        #expect(await env.disconnect() == .failed(.offline))
        #expect(fixture.host.activeRuntime === old)
    }

    @Test func theDebugConnectArgumentDoesNotReconnectAfterTheUserDisconnected() async throws {
        let (fixture, env, _) = try await running(connectAtStart: "agent:claude-code")
        defer { fixture.cleanup() }
        func connects() -> Int { fixture.server.requests("register").filter { ($0.json["connect"] as? [String])?.isEmpty == false }.count }
        #expect(await fixture.eventually { connects() == 1 }, "시작 때 한 번")
        let connectsBefore = connects()
        let clock = fixture.advancingClock()
        _ = await env.disconnect()
        clock.cancel()
        #expect(await fixture.eventually { fixture.host.statusBoard.status == .revoked })
        try? await Task.sleep(for: .milliseconds(300))
        let connectsAfter = connects()
        #expect(connectsAfter == connectsBefore, "사용자가 끊은 뒤 새 런타임이 인자로 다시 연결하지 않는다")
        #expect(fixture.host.statusBoard.status == .revoked)
    }

    @Test func aProcessThatCannotBeEndedKeepsTheOldRuntimeAndReconnectRefusesUntilItIsGone() async throws {
        let (fixture, env, _) = try await running()
        defer { fixture.cleanup() }
        let old = try #require(fixture.host.activeRuntime)
        fixture.agent.setIgnoreInterruptForever(true)
        fixture.agent.setTerminateResult(.alive)
        let clock = fixture.advancingClock()
        let outcome = await env.disconnect()
        #expect(outcome == .disconnected(unresolvedProcesses: 1), "끝내지 못한 프로세스 수")
        #expect(fixture.host.activeRuntime === old, "감독 밖 writer를 아는 유일한 원장이라 바로 놓지 않는다")
        #expect(await old.status == .revoked, "끝내지 못한 프로세스가 남은 런타임은 멈추지 않는다 (감독을 이어 간다)")
        #expect(await env.reconnect() == .unavailable, "끝나지 않았으면 Reconnect는 실패 줄로 끝난다 (옛 런타임은 다시 쓰지 않는다)")
        #expect(fixture.host.activeRuntime === old)
        // 프로세스가 사라졌다: 다음 Reconnect가 남은 것을 다시 끝내 보고 새 런타임으로 바꾼다
        fixture.agent.setTerminateResult(nil)
        fixture.agent.setScript(.normal())
        #expect(await env.reconnect() == .connected)
        clock.cancel()
        #expect(fixture.host.activeRuntime !== old && fixture.host.runtimeCount == 1)
    }

    @Test func whenTheLeftoverProcessEndsByItselfTheHostReplacesTheRuntimeWithoutAReconnect() async throws {
        let fixture = HostFixture()
        defer { fixture.cleanup() }
        // 5000초 뒤 스스로 끝나는 실행 (수동 시계를 넘기면 끝난다)
        fixture.agent.setScript(.init([
            .sessionBound(external: "fake-session-1", workspace: "workspace-fake"), .accepted, .progress, .wait(5000), .end(AgentExit(code: 0)),
        ]))
        await fixture.start()
        _ = try #require(await fixture.message())
        #expect(await fixture.eventually { fixture.agent.startedTurns.count == 1 })
        let env = environment(fixture)
        let old = try #require(fixture.host.activeRuntime)
        fixture.agent.setIgnoreInterruptForever(true)
        fixture.agent.setTerminateResult(.alive)
        let clock = fixture.advancingClock()
        #expect(await env.disconnect() == .disconnected(unresolvedProcesses: 1))
        #expect(fixture.host.activeRuntime === old, "끝내지 못한 프로세스가 남아 바로 바꾸지 않는다")
        // 프로세스가 스스로 끝났다: Reconnect를 누르지 않아도 호스트가 보류했던 런타임을 바꾼다
        fixture.clock.jump(by: 6000)
        let replaced = await fixture.eventually { fixture.host.activeRuntime !== old && fixture.host.runtimeCount == 1 }
        clock.cancel()
        #expect(replaced, "끝난 뒤 이어서 바꾼다")
    }

    // MARK: 마무리 모드

    @Test func aDrainRuntimeIsNeverHandedToTheSettingsActions() async throws {
        let fixture = HostFixture(enabled: false)
        defer { fixture.cleanup() }
        let userID = try #require(fixture.user.value)
        let partition = BridgePartition(apiBaseURL: fixture.server.baseURL, userID: userID)
        let ledger = try BridgeLedger(directory: partition.directory(in: fixture.root))
        try await ledger.saveCommand(BridgeCommandRecord(
            commandID: "c1", kind: "message", agentSessionID: "s", agentTaskID: "t", turnSeq: 1, cursor: 1, state: .leased, stateAt: fixture.clock.now
        ))
        await ledger.close()
        await fixture.start()
        #expect(fixture.host.runtimeCount == 1 && fixture.host.activeRuntime != nil, "마무리 모드 런타임이 있다")
        #expect(fixture.host.activeAgentRuntime == nil, "마무리 모드는 새 등록 · Connect 0이라 설정 동작에 내주지 않는다")
        let env = environment(fixture)
        #expect(!env.canRunAgents)
        #expect(await env.connect() == .unavailable && fixture.server.registerAttempts == 0)
    }

    // MARK: 다른 Mac 지우기 (6.4)

    @Test func removingAnotherMacThroughTheEnvironmentFreesTheSlotAndTheUserConnects() async throws {
        let userID = UUID()
        let fixture = HostFixture(user: userID)
        defer { fixture.cleanup() }
        fixture.server.fillBridges(userID: userID, count: 10)
        await fixture.start()
        let env = environment(fixture)
        #expect(await fixture.eventually { fixture.host.statusBoard.status == .tooManyBridges })
        let target = try #require(fixture.server.activeBridgeIDs(userID: userID).first)
        let registers = fixture.server.requests("register").count
        #expect(await env.removeMac(try #require(UUID(uuidString: target))) == .removed)
        #expect(fixture.server.bridgeIsActive(target) == false)
        #expect(await fixture.eventually { fixture.host.statusBoard.status != .tooManyBridges })
        #expect(await env.connect() == .connected, "사용자가 Connect를 누르면 간다")
        #expect(fixture.server.requests("register").count > registers)
    }

    @Test func thisMacCannotBeRemovedThroughTheOtherMacPath() async throws {
        let fixture = HostFixture()
        defer { fixture.cleanup() }
        await fixture.start()
        let bridge = try #require(await fixture.waitForBridge())
        let env = environment(fixture)
        #expect(await env.removeMac(try #require(UUID(uuidString: bridge))) == .refused)
        #expect(fixture.server.bridgeIsActive(bridge))
    }
}
