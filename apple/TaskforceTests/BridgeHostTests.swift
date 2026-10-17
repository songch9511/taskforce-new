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

    func authorize(workspaceRef: String, session sessionID: String, adapter: String) async -> Bool { workspaceRef == "workspace-fake" }
}

/// `stop()`을 가로채는 깨우기 대역: 런타임이 닫히는 동안(원장이 아직 열려 있는 동안) 시험이 끼어들고 닫기를 늦춘다. 구독은 하지 않는다 (긴 대기로 돈다)
final class InterceptingWake: BridgeWakeSource, @unchecked Sendable {
    private let lock = NSLock()
    private var hook: (@Sendable () async -> Void)?

    func onStop(_ newHook: (@Sendable () async -> Void)?) { lock.withLock { hook = newHook } }

    func start(bridgeID: String) async -> AsyncStream<Void> { AsyncStream { $0.finish() } }

    var isSubscribed: Bool { get async { false } }

    func stop() async { await lock.withLock { hook }?() }
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
    private let wake: (any BridgeWakeSource)?
    /// 런타임을 만들기 전에 시험이 끼어드는 자리 (원장을 여는 동안 계정이 바뀌는 경쟁)
    var onFactory: (@MainActor () async -> Void)?

    init(
        enabled: Bool = true, user: UUID? = UUID(), agent: FakeAgentProcess? = nil, server: FakeBridgeServer? = nil, root: URL? = nil, credentials: InMemoryBridgeCredentialStore? = nil,
        wake: (any BridgeWakeSource)? = nil
    ) {
        let clock = self.clock
        self.enabled = enabled
        self.wake = wake
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
        let wake = self.wake
        return BridgeHost(
            enabled: enabled, apiBaseURL: server.baseURL, storageRoot: root, credentials: credentials, currentUser: { [user] in user.value }, epoch: { [epoch] in epoch.value },
            factory: { [weak self] partition, mode, secrets, onChange in
                await self?.onFactory?()
                let ledger = try BridgeLedger(directory: partition.directory(in: root), now: { clock.now })
                let token = "token-\(partition.userID.uuidString.lowercased())"
                server.addUser(token: token, userID: partition.userID)
                let client = BridgeClient(
                    baseURL: server.baseURL, session: server.makeSession(), expectedUserID: partition.userID,
                    bearer: { BridgeBearer(userID: partition.userID, accessToken: token) }
                )
                return BridgeRuntime(
                    configuration: BridgeRuntimeConfiguration(partition: partition, appVersion: "0.2.0-test", mode: mode), client: client, ledger: ledger,
                    credentials: credentials, adapters: [agent], clock: clock.clock, wake: wake, secrets: secrets, workspaces: HostWorkspaces(), onChange: onChange
                )
            },
            quitPrompt: prompt, reply: { [weak self] value in self?.replies.append(value) }, notificationCenter: center
        )
    }

    /// 앱을 새로 띄운 것처럼 같은 뿌리 · 서버 · 자격으로 새 호스트를 만든다
    func relaunch(agent newAgent: FakeAgentProcess, enabled newEnabled: Bool? = nil) -> HostFixture {
        HostFixture(enabled: newEnabled ?? enabled, user: user.value, agent: newAgent, server: server, root: root, credentials: credentials)
    }

    /// 수동 시계를 조금씩 흘려 보내는 일꾼: 유예(3초)를 기다리는 종료 · 삭제 경로가 멈추지 않게
    func advancingClock() -> Task<Void, Never> {
        Task { [clock] in
            for _ in 0..<400 {
                if Task.isCancelled { return }
                await clock.advance(by: 0.25)
                try? await Task.sleep(for: .milliseconds(3))
            }
        }
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
        let key = LocalSecretKey(taskID: UUID().uuidString, requestID: "req")
        await secrets.put(key: key, value: AgentAnswerValue(text: "x"))
        #expect(await fixture.eventually { fixture.host.isBusy })
        #expect(fixture.host.terminationReply() == .terminateLater)
        #expect(await fixture.eventually { fixture.prompt.asked == 1 })
        _ = await secrets.take(key: key)
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
        // `terminateOrphan`을 부른 직후에는 신호가 아직 닿는 중일 수 있다: 끝날 때까지 기다린다
        #expect(await relaunched.eventually { !FakeAgentProcess.isProcessAlive(pid: orphanPid, startedAt: orphan.startedAt) }, "고아를 끝냈다")
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

    // MARK: 독립 검토 반영 (계약 7장): 마무리 모드 놓기 · 감독 밖 writer 0 · 겹치는 sync · 확인 못 한 고아

    @Test func aDrainRuntimeThatFinishedItsWorkIsReleasedByTheHost() async throws {
        // 켜진 호스트로 등록하고 서버에 닿지 못한 사건 하나를 원장에 남긴 채 내려간다
        let first = HostFixture()
        defer { first.cleanup() }
        await first.start()
        _ = await first.waitForBridge()
        // 등록 결과(bridge id)가 원장에 적힌 뒤에 내려간다: 첫 heartbeat 요청은 그 뒤에 나간다 (아니면 새 앱이 bridge id를 몰라 마무리를 못 한다)
        #expect(await first.eventually { first.server.requests("heartbeat").count >= 1 })
        let userID = try #require(first.user.value)
        let partition = BridgePartition(apiBaseURL: first.server.baseURL, userID: userID)
        await first.host.activeRuntime?.abandonForTest()
        first.host.stopObserving()
        let ledger = try BridgeLedger(directory: partition.directory(in: first.root), now: { first.clock.now })
        try await ledger.saveTask(BridgeTaskRecord(agentTaskID: "7a5c0001-0000-4000-8000-0000000000d1", agentSessionID: "5e551011-0000-4000-8000-0000000000d1", adapter: "agent:claude-code", turnSeq: 1, updatedAt: first.clock.now))
        _ = try await ledger.appendEvent(
            taskID: "7a5c0001-0000-4000-8000-0000000000d1", numbering: .taskSequence,
            build: { seq, eventID in BuiltEvent(type: "progress", json: "{\"event_id\":\"\(eventID)\"}", observedAt: Date(timeIntervalSince1970: 1_760_400_000)) }, update: { _ in }
        )
        await ledger.close()
        // 꺼진 새 앱: 마무리 모드로 올라와 사건을 보내고(서버는 이 task를 모른다) 할 일이 없어지면 멈춘다
        let relaunched = first.relaunch(agent: FakeAgentProcess(clock: first.clock.clock), enabled: false)
        await relaunched.start()
        #expect(relaunched.host.runtimeCount == 1 || relaunched.host.runtimeCount == 0)
        let deadline = Date().addingTimeInterval(8)
        while relaunched.host.runtimeCount > 0, Date() < deadline {
            await relaunched.clock.advance(by: 31)
            try? await Task.sleep(for: .milliseconds(25))
        }
        #expect(relaunched.host.runtimeCount == 0, "끝난 마무리 런타임은 호스트가 놓는다")
        #expect(relaunched.host.activeRuntime == nil)
        relaunched.host.stopObserving()
    }

    @Test func anIdleTurnWhoseProcessIsStillAliveIsEndedOnQuitWithoutAskingForConfirmation() async throws {
        let fixture = HostFixture()
        defer { fixture.cleanup() }
        // 턴은 끝났는데(`idle`) 프로세스는 남아 있다 (오래 사는 app-server 모양)
        fixture.agent.setScript(FakeAgentProcess.Script([.sessionBound(external: "fake-session-1", workspace: "workspace-fake"), .accepted, .progress, .message("done"), .turnCompleted, .wait(100_000)]))
        await fixture.start()
        let created = try #require(await fixture.message())
        #expect(await fixture.eventually { fixture.server.taskState(created.taskID) == "idle" || fixture.agent.startedTurns.count == 1 })
        #expect(await fixture.eventually { fixture.host.hasLiveProcess })
        #expect(await fixture.eventually { !fixture.host.isBusy }, "턴이 끝났으니 바쁘지 않다")
        #expect(fixture.agent.liveRunCount == 1)
        #expect(fixture.host.terminationReply() == .terminateLater, "프로세스가 남아 있으면 그냥 종료하지 않는다")
        let worker = fixture.advancingClock()
        #expect(await fixture.eventually { fixture.replies == [true] })
        worker.cancel()
        #expect(fixture.prompt.asked == 0, "한가한 종료는 확인 창 없이")
        #expect(fixture.agent.liveRunCount == 0, "감독 밖 writer를 남기지 않는다")
    }

    @Test func quitEndsARunThatIgnoresTheInterruptSignal() async throws {
        let (fixture, created) = try await runningFixture()
        defer { fixture.cleanup() }
        fixture.agent.setIgnoreInterruptForever(true)
        #expect(fixture.host.terminationReply() == .terminateLater)
        let worker = fixture.advancingClock()
        #expect(await fixture.eventually { fixture.replies == [true] })
        worker.cancel()
        #expect(fixture.prompt.asked == 1)
        #expect(fixture.agent.interrupts.count == 1, "먼저 중단 신호")
        #expect(fixture.agent.terminatedOrphans.count == 1, "신호를 무시해서 유예 뒤 terminateOrphan으로 끝냈다")
        #expect(fixture.agent.liveRunCount == 0)
        #expect(fixture.server.taskState(created.taskID) == "cancelled")
    }

    @Test func deletingTheAccountEndsARunThatIgnoresTheInterruptSignalBeforeTheLedgerIsRemoved() async throws {
        let (fixture, _) = try await runningFixture()
        defer { fixture.cleanup() }
        fixture.agent.setIgnoreInterruptForever(true)
        let userID = try #require(fixture.user.value)
        let partition = try #require(fixture.host.activePartition)
        let worker = fixture.advancingClock()
        let result = await fixture.host.accountDeleted(userID: userID)
        worker.cancel()
        #expect(fixture.agent.liveRunCount == 0, "원장을 지우기 전에 감독 밖 writer를 남기지 않는다")
        #expect(fixture.agent.terminatedOrphans.count == 1)
        #expect(result.isComplete, "지운 결과를 알린다")
        #expect(!FileManager.default.fileExists(atPath: partition.directory(in: fixture.root).path))
    }

    @Test func overlappingSyncsApplyInOrderAndEndOnTheLatestAccount() async throws {
        let fixture = HostFixture()
        defer { fixture.cleanup() }
        let alice = try #require(fixture.user.value)
        let bob = UUID()
        await fixture.start()
        _ = await fixture.waitForBridge()
        // 두 번 바뀐 계정을 겹쳐서 sync한다: 호출은 차례로 돌고 마지막 사용자에 맞춰진다
        fixture.user.value = bob
        fixture.epoch.value += 1
        async let first: Void = fixture.host.syncAccount()
        fixture.user.value = alice
        fixture.epoch.value += 1
        async let second: Void = fixture.host.syncAccount()
        fixture.user.value = bob
        fixture.epoch.value += 1
        async let third: Void = fixture.host.syncAccount()
        _ = await (first, second, third)
        #expect(fixture.host.activePartition?.userID == bob)
        #expect(fixture.host.runtimeCount == 1, "런타임이 섞이거나 겹치지 않는다")
    }

    @Test func aRuntimeBuiltWhileTheAccountChangedIsNeverStartedForTheOldAccount() async throws {
        let fixture = HostFixture()
        defer { fixture.cleanup() }
        let bob = UUID()
        fixture.onFactory = { [fixture] in
            // 원장을 여는 사이 계정이 바뀐다 (딱 한 번)
            fixture.onFactory = nil
            fixture.user.value = bob
            fixture.epoch.value += 1
        }
        // `start()`는 부르지 않는다 (대기 중인 sync가 없다): 첫 sync 하나가 끝난 직후의 상태를 본다
        await fixture.host.syncAccount()
        #expect(fixture.host.runtimeCount == 0 && fixture.host.activeRuntime == nil, "바뀐 계정 몫이 아닌 런타임은 올리지 않는다")
        try? await Task.sleep(for: .milliseconds(150))
        #expect(fixture.server.registerAttempts == 0, "처음 계정으로는 등록하지 않았다")
        // 다음 sync가 바뀐 계정으로 맞춘다
        await fixture.host.syncAccount()
        #expect(fixture.host.activePartition?.userID == bob, "바뀐 계정으로 맞춰진다")
        #expect(fixture.host.runtimeCount == 1)
        #expect(await fixture.eventually { fixture.server.bridgeID(userID: bob) != nil })
        #expect(fixture.server.registerAttempts == 1)
    }

    @Test func aSecondSyncWaitsUntilTheFirstOneIsDone() async throws {
        let fixture = HostFixture()
        defer { fixture.cleanup() }
        let bob = UUID()
        let open = HostBox(false)
        let calls = HostBox(0)
        fixture.onFactory = {
            let number = calls.value
            calls.value += 1
            if number == 0 { while !open.value { try? await Task.sleep(for: .milliseconds(5)) } } // 첫 런타임을 만드는 중에 멈춘다
        }
        let first = Task { await fixture.host.syncAccount() }
        #expect(await fixture.eventually { calls.value == 1 }, "첫 sync가 런타임을 만드는 중")
        fixture.user.value = bob
        fixture.epoch.value += 1
        let second = Task { await fixture.host.syncAccount() }
        try? await Task.sleep(for: .milliseconds(150))
        #expect(calls.value == 1, "앞 sync가 끝나기 전에는 다음 sync가 런타임을 만들지 않는다")
        open.value = true
        await first.value
        await second.value
        #expect(fixture.host.activePartition?.userID == bob)
        #expect(fixture.host.runtimeCount == 1, "런타임이 섞이거나 겹치지 않는다")
    }

    @Test func anUnverifiedOrphanNeverBlocksTheUpdateRelaunchButKeepsTheSessionBlocked() async throws {
        let fixture = HostFixture()
        defer { fixture.cleanup() }
        fixture.agent.setScript(.staysRunning())
        await fixture.start()
        let created = try #require(await fixture.message())
        #expect(await fixture.eventually { fixture.agent.startedTurns.count == 1 })
        #expect(await fixture.eventually { fixture.server.taskState(created.taskID) != "dispatched" || fixture.host.isBusy })
        // 앱이 강제 종료된 것처럼 버리고 새 호스트가 올라온다. adapter는 이 실행의 끝을 증명하지 못한다
        _ = fixture.agent.abandon()
        await fixture.host.activeRuntime?.abandonForTest()
        fixture.host.stopObserving()
        let newAgent = FakeAgentProcess(clock: fixture.clock.clock)
        newAgent.setLiveness(.unknown)
        let relaunched = fixture.relaunch(agent: newAgent)
        defer { UpdateRelaunchPolicy.resetForTesting() }
        await relaunched.start()
        #expect(await relaunched.eventually { relaunched.host.activeRuntime != nil })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!relaunched.host.isBusy, "끝을 증명하지 못한 고아는 Sparkle 재시작을 막지 않는다")
        #expect(UpdateRelaunchPolicy.allowsRelaunchNow())
        #expect(relaunched.host.hasLiveProcess, "그래도 원장은 살아 있다고 안다")
        relaunched.host.stopObserving()
    }

    // MARK: 독립 검토 반영 2 (계약 8장): 놓기와 재개의 경합 · 계정 삭제가 끝내지 못한 프로세스

    /// 떠난 계정의 마지막 턴이 끝나 런타임이 놓일 차례가 된 순간(`releaseHook`)에 `body`가 끼어든다. 훅이 돈 뒤 돌려준다
    private func releaseWhile(_ fixture: HostFixture, _ created: FakeBridgeServer.Created, _ body: @escaping @MainActor (BridgeRuntime) async -> Void) async throws -> BridgeRuntime {
        let runtime = try #require(fixture.host.activeRuntime)
        let ran = HostBox(false)
        fixture.host.releaseHook = { [fixture] in
            fixture.host.releaseHook = nil
            ran.value = true
            await body(runtime)
        }
        fixture.user.value = nil
        fixture.epoch.value += 1
        await fixture.host.syncAccount() // 런타임은 멈추지만 턴이 살아 있어 남는다
        #expect(fixture.host.runtimeCount == 1)
        _ = await fixture.agent.interrupt(AgentTurnRef(taskID: created.taskID, sessionID: created.sessionID, identity: nil), scope: .turn) // 마지막 턴이 끝난다
        #expect(await fixture.eventually { ran.value }, "놓을 차례가 왔다")
        return runtime
    }

    @Test func aSameAccountThatReturnsWhileTheRuntimeIsBeingReleasedKeepsItsRuntime() async throws {
        let (fixture, created) = try await runningFixture()
        defer { fixture.cleanup() }
        let alice = try #require(fixture.user.value)
        let runtime = try await releaseWhile(fixture, created) { [fixture] _ in
            fixture.user.value = alice
            fixture.epoch.value += 1
            await fixture.host.syncAccount()
        }
        try? await Task.sleep(for: .milliseconds(150))
        #expect(fixture.host.activeRuntime === runtime, "돌아온 계정의 런타임을 닫지 않는다")
        #expect(await runtime.status != .stopped)
        #expect(fixture.host.runtimeCount == 1)
        let count = fixture.server.requests.count
        await fixture.clock.advance(by: 31)
        _ = await fixture.eventually { fixture.server.requests.count > count }
        #expect(fixture.server.requests.count > count, "다시 켜진 런타임이 계속 돈다")
    }

    @Test func aRuntimeThatIsRunningAgainIsNotReleasedEvenWhenTheAccountPointerIsClear() async throws {
        let (fixture, created) = try await runningFixture()
        defer { fixture.cleanup() }
        let runtime = try await releaseWhile(fixture, created) { runtime in await runtime.resume() }
        try? await Task.sleep(for: .milliseconds(150))
        #expect(await runtime.status != .stopped, "멈춰 있지 않은 런타임은 놓지 않는다")
        #expect(fixture.host.runtimeCount == 1)
    }

    @Test func aRuntimeIsReleasedOnlyWhenItIsStoppedAndNoLongerActiveOrDraining() {
        for status in [BridgeStatus.stopped, .connected, .connecting, .offline, .sleeping, .revoked, .tooManyBridges, .credentialRejected, .notStarted] {
            for active in [false, true] {
                for drain in [false, true] {
                    let expected = status == .stopped && (!active || drain)
                    #expect(BridgeHost.mayRelease(status: status, partitionIsActive: active, drain: drain) == expected, "\(status) active=\(active) drain=\(drain)")
                }
            }
        }
    }

    @Test func anAccountThatReturnsWhileTheOldRuntimeIsStillClosingOpensItsLedgerOnlyAfterTheCloseIsDone() async throws {
        let wake = InterceptingWake()
        let fixture = HostFixture(wake: wake)
        defer { fixture.cleanup() }
        fixture.agent.setScript(.staysRunning())
        await fixture.start()
        let created = try #require(await fixture.message())
        #expect(await fixture.eventually { fixture.agent.startedTurns.count == 1 })
        let alice = try #require(fixture.user.value)
        let directory = BridgePartition(apiBaseURL: fixture.server.baseURL, userID: alice).directory(in: fixture.root)
        let probes = HostBox<[Bool]>([])
        fixture.onFactory = {
            // 새 런타임이 원장을 열기 직전: 옛 런타임이 같은 원장을 아직 열고 있으면 안 된다
            do {
                let probe = try BridgeLedger(directory: directory)
                await probe.close()
                probes.value.append(true)
            } catch {
                probes.value.append(false)
            }
        }
        fixture.user.value = nil
        fixture.epoch.value += 1
        await fixture.host.syncAccount() // 떠난다: 턴이 살아 있어 런타임은 남는다
        #expect(fixture.host.runtimeCount == 1)
        // 이제부터 런타임이 닫히는 동안(깨우기 대역의 stop) 계정이 돌아온다. 닫기는 느리다
        wake.onStop { [fixture] in
            wake.onStop(nil)
            fixture.user.value = alice
            fixture.epoch.value += 1
            Task { @MainActor in await fixture.host.syncAccount() }
            try? await Task.sleep(for: .milliseconds(300))
        }
        _ = await fixture.agent.interrupt(AgentTurnRef(taskID: created.taskID, sessionID: created.sessionID, identity: nil), scope: .turn) // 마지막 턴이 끝난다 -> 놓는다
        #expect(await fixture.eventually { probes.value.count == 1 }, "돌아온 계정이 새 런타임을 만든다")
        #expect(probes.value == [true], "옛 런타임이 원장을 닫은 뒤에 연다: \(probes.value)")
        #expect(await fixture.eventually { fixture.host.activeRuntime != nil })
        let active = try #require(fixture.host.activeRuntime)
        try? await Task.sleep(for: .milliseconds(200))
        #expect(await active.status != .stopped, "돌아온 계정의 런타임이 살아 있다")
        #expect(fixture.host.runtimeCount == 1)
    }

    @Test func deletingTheAccountReportsARunItCouldNotEnd() async throws {
        let (fixture, _) = try await runningFixture()
        defer { fixture.cleanup() }
        fixture.agent.setIgnoreInterruptForever(true)
        fixture.agent.setTerminateResult(.alive) // 강제 종료도 듣지 않는다
        let userID = try #require(fixture.user.value)
        let partition = try #require(fixture.host.activePartition)
        let worker = fixture.advancingClock()
        let result = await fixture.host.accountDeleted(userID: userID)
        worker.cancel()
        #expect(result.unterminatedProcesses == 1, "끝내지 못한 프로세스 수를 알린다")
        #expect(!result.isComplete, "남은 프로세스가 있는데 정리가 끝난 것으로 보이지 않는다")
        #expect(result.folderRemoved && result.credentialsRemoved, "사용자 데이터는 그래도 지운다")
        #expect(!FileManager.default.fileExists(atPath: partition.directory(in: fixture.root).path))
    }
}
