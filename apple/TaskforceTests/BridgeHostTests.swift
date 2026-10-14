import AppKit
import Foundation
import Testing
import TaskforceKit
@testable import Taskforce

/// 상자: 시험이 값을 바꾸는 작은 공유 값
final class HostBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// 새 세션의 작업 폴더 (D4a가 정하기 전의 시험용 값)
struct HostWorkspaces: WorkspaceResolver {
    func workspace(forSession sessionID: String, adapter: String) async -> String? { "workspace-fake" }
}

/// 종료 확인 대역: 시험이 답을 정하고 몇 번 물었는지 센다
@MainActor
final class ScriptedPrompt: BridgeQuitPrompting {
    var answer = true
    private(set) var asked = 0

    func confirmQuit() async -> Bool {
        asked += 1
        return answer
    }
}

/// `BridgeHost` + 가짜 서버 · 가짜 agent · 수동 시계 · 임시 원장 뿌리 (OA D2b 계약 4.2: 격리 Mac 호스트).
/// 실사용 Application Support · Keychain · 설정은 건드리지 않는다: 뿌리는 임시 폴더, 자격은 메모리 저장소, 네트워크는 `URLProtocol` 가짜 서버뿐이다
@MainActor
final class HostFixture {
    let clock = ManualBridgeClock()
    let server: FakeBridgeServer
    let root: URL
    let credentials: InMemoryBridgeCredentialStore
    let agent: FakeAgentProcess
    let user: HostBox<UUID?>
    let epoch = HostBox(0)
    let prompt = ScriptedPrompt()
    let center = NotificationCenter()
    private(set) var replies: [Bool] = []
    private(set) var host: BridgeHost!
    private let enabled: Bool

    init(enabled: Bool = true, user: UUID? = UUID(), agent: FakeAgentProcess? = nil, server: FakeBridgeServer? = nil, root: URL? = nil, credentials: InMemoryBridgeCredentialStore? = nil) {
        let clock = self.clock
        self.enabled = enabled
        self.server = server ?? FakeBridgeServer(clock: { clock.now })
        self.root = root ?? FileManager.default.temporaryDirectory.appending(path: "bridge-host-\(UUID().uuidString)", directoryHint: .isDirectory)
        self.agent = agent ?? FakeAgentProcess(clock: clock.clock)
        self.user = HostBox(user)
        self.credentials = credentials ?? InMemoryBridgeCredentialStore()
        host = makeHost()
    }

    private func makeHost() -> BridgeHost {
        let server = self.server
        let root = self.root
        let clock = self.clock
        let agent = self.agent
        let credentials = self.credentials
        return BridgeHost(
            enabled: enabled, apiBaseURL: server.baseURL, storageRoot: root, credentials: credentials, currentUser: { [user] in user.value }, epoch: { [epoch] in epoch.value },
            factory: { partition, mode, secrets, onChange in
                let ledger = try BridgeLedger(directory: partition.directory(in: root), now: { clock.now })
                let token = "token-\(partition.userID.uuidString.lowercased())"
                server.addUser(token: token, userID: partition.userID)
                let client = BridgeClient(
                    baseURL: server.baseURL, session: server.makeSession(), expectedUserID: partition.userID,
                    bearer: { BridgeBearer(userID: partition.userID, accessToken: token) }
                )
                return BridgeRuntime(
                    configuration: BridgeRuntimeConfiguration(partition: partition, appVersion: "0.2.0-test", mode: mode), client: client, ledger: ledger,
                    credentials: credentials, adapters: [agent], clock: clock.clock, secrets: secrets, workspaces: HostWorkspaces(), onChange: onChange
                )
            },
            quitPrompt: prompt, reply: { [weak self] value in self?.replies.append(value) }, notificationCenter: center
        )
    }

    /// 앱을 새로 띄운 것처럼 같은 뿌리 · 서버 · 자격으로 새 호스트를 만든다
    func relaunch(agent newAgent: FakeAgentProcess) -> HostFixture {
        HostFixture(enabled: enabled, user: user.value, agent: newAgent, server: server, root: root, credentials: credentials)
    }

    func start() async {
        host.start()
        await host.syncAccount()
    }

    func eventually(timeout: TimeInterval = 8, _ condition: @MainActor () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    /// 등록이 끝나 서버에 이 사용자의 bridge가 생겼다
    func waitForBridge() async -> String? {
        guard let userID = user.value else { return nil }
        _ = await eventually { server.bridgeID(userID: userID) != nil }
        return server.bridgeID(userID: userID)
    }

    @discardableResult
    func message(_ text: String = "work", session: String = "5e551011-0000-4000-8000-000000000001", task: String = UUID().uuidString.lowercased()) async -> FakeBridgeServer.Created? {
        guard let bridgeID = await waitForBridge() else { return nil }
        let created = server.enqueueMessage(bridgeID: bridgeID, sessionID: session, taskID: task, text: text)
        server.notifyChange() // Realtime이 없는 호스트: 긴 대기를 끝낸다
        return created
    }

    func cleanup() {
        agent.killEverything()
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
struct BridgeHostTests {
    private func runningFixture(subprocess: Bool = false) async throws -> (HostFixture, FakeBridgeServer.Created) {
        let fixture = HostFixture()
        fixture.agent.setSubprocess(subprocess)
        fixture.agent.setScript(.staysRunning())
        await fixture.start()
        let created = try #require(await fixture.message())
        let started = await fixture.eventually { fixture.agent.startedTurns.count == 1 }
        #expect(started, "요청: \(fixture.server.requests.map(\.route)) 서버 task: \(fixture.server.taskState(created.taskID) ?? "-")")
        #expect(await fixture.eventually { fixture.host.isBusy })
        return (fixture, created)
    }

    // MARK: 꺼짐 · 마무리 모드 (M1 · 2.14)

    @Test func whenOffAndThereIsNothingToFinishNoRuntimeAndNoRequestsExist() async throws {
        let fixture = HostFixture(enabled: false)
        defer { fixture.cleanup() }
        await fixture.start()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(fixture.host.runtimeCount == 0 && fixture.host.activeRuntime == nil)
        #expect(fixture.server.requests.isEmpty && fixture.server.registerAttempts == 0)
        #expect(fixture.host.terminationReply() == .terminateNow)
    }

    @Test func whenOffButTheLedgerHasWorkLeftTheHostRunsADrainRuntime() async throws {
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
        #expect(fixture.host.runtimeCount == 1)
        #expect(await fixture.host.activeRuntime?.status != nil)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(fixture.server.registerAttempts == 0, "마무리 모드는 새로 등록하지 않는다")
    }

    // MARK: M2 — 종료 확인

    @Test func aQuietHostTerminatesAtOnceWithoutAsking() async throws {
        let fixture = HostFixture()
        defer { fixture.cleanup() }
        await fixture.start()
        _ = await fixture.waitForBridge()
        #expect(fixture.host.terminationReply() == .terminateNow)
        #expect(fixture.prompt.asked == 0 && fixture.replies.isEmpty)
    }

    @Test func quitStopsTheLiveTurnReportsCancelledDrainsTheOutboxAndReplies() async throws {
        let (fixture, created) = try await runningFixture()
        defer { fixture.cleanup() }
        #expect(fixture.host.terminationReply() == .terminateLater)
        #expect(await fixture.eventually { fixture.replies == [true] })
        #expect(fixture.prompt.asked == 1)
        #expect(fixture.agent.interrupts.count == 1)
        #expect(fixture.server.taskState(created.taskID) == "cancelled")
        #expect(await fixture.host.activeRuntime?.status == .stopped)
        #expect(await fixture.host.activeRuntime?.isBusy() == false)
    }

    @Test func cancellingTheQuitChangesNothing() async throws {
        let (fixture, created) = try await runningFixture()
        defer { fixture.cleanup() }
        fixture.prompt.answer = false
        #expect(fixture.host.terminationReply() == .terminateLater)
        #expect(await fixture.eventually { fixture.replies == [false] })
        #expect(fixture.agent.interrupts.isEmpty)
        #expect(fixture.host.isBusy)
        #expect(fixture.server.taskState(created.taskID) != "cancelled")
        #expect(await fixture.host.activeRuntime?.status != .stopped)
    }

    @Test func aSecretAnswerWaitingInMemoryAloneCountsAsBusy() async throws {
        let fixture = HostFixture()
        defer { fixture.cleanup() }
        await fixture.start()
        _ = await fixture.waitForBridge()
        #expect(!fixture.host.isBusy)
        let secrets = try #require(fixture.host.activeSecrets)
        await secrets.put(requestID: "req", value: AgentAnswerValue(text: "x"))
        #expect(await fixture.eventually { fixture.host.isBusy })
        #expect(fixture.host.terminationReply() == .terminateLater)
        #expect(await fixture.eventually { fixture.prompt.asked == 1 })
        _ = await secrets.take(requestID: "req")
        #expect(await fixture.eventually { !fixture.host.isBusy })
    }

    // MARK: M3 — 업데이트 재시작

    @Test func relaunchIsBlockedWhileATurnRunsAndPostponedUntilItIsIdleExactlyOnce() async throws {
        let (fixture, created) = try await runningFixture()
        defer {
            fixture.cleanup()
            UpdateRelaunchPolicy.resetForTesting()
        }
        #expect(!UpdateRelaunchPolicy.allowsRelaunchNow())
        var resumed = 0
        #expect(UpdateRelaunchPolicy.postponeRelaunchWhileBusy { resumed += 1 }, "바쁘면 미룬다")
        #expect(resumed == 0)
        // 턴이 끝난다 (사용자가 Stop)
        _ = await fixture.agent.interrupt(AgentTurnRef(taskID: created.taskID, sessionID: created.sessionID, identity: nil), scope: .turn)
        #expect(await fixture.eventually { !fixture.host.isBusy })
        #expect(await fixture.eventually { resumed == 1 })
        #expect(UpdateRelaunchPolicy.allowsRelaunchNow())
        #expect(!UpdateRelaunchPolicy.postponeRelaunchWhileBusy { resumed += 1 }, "한가하면 바로 진행")
        UpdateRelaunchPolicy.busyChanged(false)
        #expect(resumed == 1, "미룬 블록은 한 번만 불린다")
    }

    @Test func withoutAHostRelaunchIsAlwaysAllowed() {
        UpdateRelaunchPolicy.resetForTesting()
        #expect(UpdateRelaunchPolicy.allowsRelaunchNow())
        #expect(!UpdateRelaunchPolicy.postponeRelaunchWhileBusy {})
    }

    // MARK: M4 — 절전 · 깨어남

    @Test func sleepAndWakeNotificationsStopAndRestartTheRuntime() async throws {
        let fixture = HostFixture()
        defer { fixture.cleanup() }
        await fixture.start()
        _ = await fixture.waitForBridge()
        #expect(await fixture.eventually { fixture.server.requests("commands").count >= 1 })
        fixture.center.post(name: NSWorkspace.willSleepNotification, object: nil)
        #expect(await fixture.eventually { await fixture.host.activeRuntime?.status == .sleeping })
        let count = fixture.server.requests.count
        await fixture.clock.advance(by: 120)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(fixture.server.requests.count == count, "잠든 동안 요청 0")
        fixture.center.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(await fixture.eventually { fixture.server.requests.count > count })
        #expect(fixture.server.requests.dropFirst(count).first?.route == "heartbeat", "깨어난 뒤 첫 요청은 heartbeat")
    }

    // MARK: M5 — 계정

    @Test func theRuntimeFollowsTheAccountAndTheSameAccountReturnsToTheSamePartition() async throws {
        let fixture = HostFixture()
        defer { fixture.cleanup() }
        let alice = try #require(fixture.user.value)
        await fixture.start()
        let alicePartition = try #require(fixture.host.activePartition)
        #expect(alicePartition.userID == alice)
        _ = await fixture.waitForBridge()
        // 로그아웃: 런타임을 멈춘다
        fixture.user.value = nil
        fixture.epoch.value += 1
        await fixture.host.syncAccount()
        #expect(fixture.host.activeRuntime == nil)
        let count = fixture.server.requests.count
        await fixture.clock.advance(by: 120)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(fixture.server.requests.count == count, "계정이 떠났으면 요청 0")
        // 다른 계정: 새 파티션
        let bob = UUID()
        fixture.user.value = bob
        fixture.epoch.value += 1
        await fixture.host.syncAccount()
        let bobPartition = try #require(fixture.host.activePartition)
        #expect(bobPartition.id != alicePartition.id && bobPartition.userID == bob)
        // 같은 계정으로 다시: 같은 파티션 (원장 폴더가 이어진다)
        fixture.user.value = nil
        fixture.epoch.value += 1
        await fixture.host.syncAccount()
        fixture.user.value = alice
        fixture.epoch.value += 1
        await fixture.host.syncAccount()
        #expect(fixture.host.activePartition?.id == alicePartition.id)
        #expect(FileManager.default.fileExists(atPath: alicePartition.directory(in: fixture.root).path))
        #expect(alicePartition.directory(in: fixture.root) != bobPartition.directory(in: fixture.root))
    }

    @Test func aReloginOfTheSameUserRestartsTheRuntimeOnTheSamePartition() async throws {
        let fixture = HostFixture()
        defer { fixture.cleanup() }
        await fixture.start()
        _ = await fixture.waitForBridge()
        let first = try #require(fixture.host.activeRuntime)
        let partition = try #require(fixture.host.activePartition)
        // 세션 만료 뒤 재로그인: 사용자는 같지만 계정이 이 기기를 한 번 떠났다 (epoch가 오른다)
        fixture.epoch.value += 1
        await fixture.host.syncAccount()
        let second = try #require(fixture.host.activeRuntime)
        #expect(second !== first, "떠난 계정의 런타임은 멈추고 새 세대의 런타임이 이어 받는다")
        #expect(await first.status == .stopped)
        #expect(fixture.host.activePartition?.id == partition.id)
        #expect(fixture.host.runtimeCount == 1)
    }

    @Test func aTurnThatIsStillRunningWhenTheAccountLeavesKeepsBeingSupervisedWithoutTheNetwork() async throws {
        let (fixture, created) = try await runningFixture()
        defer { fixture.cleanup() }
        let alice = try #require(fixture.user.value)
        fixture.user.value = nil
        fixture.epoch.value += 1
        await fixture.host.syncAccount()
        #expect(fixture.host.activeRuntime == nil)
        #expect(fixture.host.runtimeCount == 1 && fixture.host.isBusy, "살아 있는 턴이 있어 남겨 둔다")
        let count = fixture.server.requests.count
        // 같은 사용자가 돌아오면 남아 있는 런타임을 이어 쓴다 (감독 중인 실행을 고아로 끝내지 않는다)
        fixture.user.value = alice
        fixture.epoch.value += 1
        await fixture.host.syncAccount()
        #expect(fixture.host.runtimeCount == 1)
        #expect(await fixture.eventually { fixture.server.requests.count > count })
        #expect(fixture.agent.terminatedOrphans.isEmpty)
        #expect(fixture.agent.startedTurns.count == 1)
        #expect(fixture.server.taskState(created.taskID) != "cancelled")
    }

    // MARK: M6 — 계정 삭제

    @Test func deletingTheAccountInterruptsTurnsAndRemovesThePartitionFolderAndCredentials() async throws {
        let (fixture, _) = try await runningFixture()
        defer { fixture.cleanup() }
        let userID = try #require(fixture.user.value)
        let partition = try #require(fixture.host.activePartition)
        #expect(FileManager.default.fileExists(atPath: partition.directory(in: fixture.root).path))
        #expect(try fixture.credentials.secret(partition: partition.id) != nil)
        await fixture.host.accountDeleted(userID: userID)
        #expect(!FileManager.default.fileExists(atPath: partition.directory(in: fixture.root).path))
        #expect(try fixture.credentials.secret(partition: partition.id) == nil && fixture.credentials.deviceID(partition: partition.id) == nil)
        #expect(fixture.agent.interrupts.count == 1)
        #expect(fixture.host.runtimeCount == 0 && !fixture.host.isBusy)
    }

    @Test func deletingTheAccountLeavesOtherPartitionsAlone() async throws {
        let fixture = HostFixture()
        defer { fixture.cleanup() }
        await fixture.start()
        _ = await fixture.waitForBridge()
        let other = UUID()
        let otherPartition = BridgePartition(apiBaseURL: fixture.server.baseURL, userID: other)
        let ledger = try BridgeLedger(directory: otherPartition.directory(in: fixture.root))
        await ledger.close()
        try fixture.credentials.save(secret: "other-secret", partition: otherPartition.id)
        await fixture.host.accountDeleted(userID: try #require(fixture.user.value))
        #expect(FileManager.default.fileExists(atPath: otherPartition.directory(in: fixture.root).path))
        #expect(try fixture.credentials.secret(partition: otherPartition.id) == "other-secret")
    }

    // MARK: M7 — 격리

    @Test func nothingIsWrittenToTheRealApplicationSupport() async throws {
        let (fixture, _) = try await runningFixture()
        defer { fixture.cleanup() }
        #expect(fixture.root.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        for bundleID in [Bundle.main.bundleIdentifier ?? "", "dev.taskforcelabs.taskforce", "dev.taskforcelabs.unittest.taskforce"] where !bundleID.isEmpty {
            let real = try #require(BridgeStorage.defaultRoot(bundleID: bundleID))
            #expect(!FileManager.default.fileExists(atPath: real.path), "\(bundleID)의 실제 Bridge 폴더 생성 0")
        }
    }

    // MARK: M9 — 가짜 agent 하위 프로세스 + 디스크 원장으로 ONE-TF 한 번 더

    @Test func oneTF15b_afterAForcedQuitTheNewAppEndsTheOrphanSettlesFromTheLedgerAndRunsNothingTwice() async throws {
        let (first, created) = try await runningFixture(subprocess: true)
        defer { first.cleanup() }
        // 접수 · 진행 사건이 원장에 적히고 서버에 닿은 뒤에 강제 종료한다 (아니면 접수 전 종료라 정산 결과가 달라진다).
        // 사건은 250ms 모아 보내므로 수동 시계를 조금씩 보낸다
        var reported = false
        for _ in 0..<80 where !reported {
            try? await Task.sleep(for: .milliseconds(25))
            await first.clock.advance(by: 0.3)
            reported = first.server.taskState(created.taskID) == "running"
        }
        #expect(reported, "서버 task: \(first.server.taskState(created.taskID) ?? "-")")
        let orphans = first.agent.abandon()
        #expect(orphans.count == 1)
        await first.host.activeRuntime?.abandonForTest()
        first.host.stopObserving()
        let orphan = try #require(orphans.first)
        let orphanPid = try #require(orphan.pid)
        #expect(FakeAgentProcess.isProcessAlive(pid: orphanPid, startedAt: orphan.startedAt))
        // 같은 세션의 다음 메시지가 기다린다
        let userID = try #require(first.user.value)
        let bridgeID = try #require(first.server.bridgeID(userID: userID))
        let second = first.server.enqueueMessage(bridgeID: bridgeID, sessionID: created.sessionID, taskID: "7a5c0001-0000-4000-8000-0000000000a2", turnSeq: 2, text: "second")
        first.server.notifyChange()
        let newAgent = FakeAgentProcess(clock: first.clock.clock)
        let alive = HostBox<Bool?>(nil)
        newAgent.onStart { _ in alive.value = FakeAgentProcess.isProcessAlive(pid: orphanPid, startedAt: orphan.startedAt) }
        let relaunched = first.relaunch(agent: newAgent)
        await relaunched.start()
        #expect(await relaunched.eventually { newAgent.terminatedOrphans.count == 1 })
        #expect(!FakeAgentProcess.isProcessAlive(pid: orphanPid, startedAt: orphan.startedAt), "고아를 끝냈다")
        #expect(await relaunched.eventually { first.server.taskState(created.taskID) == "cancelled" }, "접수 뒤였으니 원장으로 정산: cancelled (서버 task: \(first.server.taskState(created.taskID) ?? "-"))")
        #expect(first.server.commandLeaseCount(created.commandID) == 1, "재dispatch 0")
        #expect(await relaunched.eventually { newAgent.startedTurns.count == 1 })
        #expect(newAgent.startedTurns.first?.text == "second" && alive.value == false, "같은 세션 프로세스 동시 2개 0")
        _ = second
    }

    @Test func oneTF04a_aLostLeaseResponseIsRecoveredByReplayAndTheCommandRunsOnce() async throws {
        let fixture = HostFixture()
        defer { fixture.cleanup() }
        fixture.agent.setScript(.normal())
        await fixture.start()
        _ = await fixture.waitForBridge()
        #expect(await fixture.eventually { fixture.server.requests("commands").count >= 1 })
        fixture.server.dropResponseOnce(route: "ack")
        let created = try #require(await fixture.message())
        // 응답이 유실됐다: 다음 목록에서 leased_by_me로 보이면 replay로 첫 실행
        for _ in 0..<12 where fixture.agent.startedTurns.isEmpty {
            await fixture.clock.advance(by: 6)
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(await fixture.eventually { fixture.agent.startedTurns.count == 1 })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(fixture.agent.startedTurns.count == 1)
        #expect(fixture.server.commandLeaseCount(created.commandID) == 2)
    }
}
