#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

/// Settings › Your agents가 부르는 런타임 함수 (OA Settings › Your agents 6 · 8장): Connect · Reconnect · Disconnect this Mac · 다른 Mac 지우기 · probe 새로 고침 · liveSince.
/// 실제 `claude` · 실제 Keychain · 운영 서버는 0이다: 가짜 서버 · 가짜 agent · 메모리 자격 · 수동 시계만 쓴다
struct AgentSettingsRuntimeTests {
    static let adapter = "agent:claude-code"

    /// 부른 순서와 그 순간의 이 Mac 상태를 적는 줄
    final class OrderLog: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []

        func add(_ line: String) { lock.withLock { items.append(line) } }
        var lines: [String] { lock.withLock { items } }
        func index(of prefix: String) -> Int? { lines.firstIndex { $0.hasPrefix(prefix) } }
    }

    /// 가짜 agent를 감싸 부르는 순서를 적는다 (`stopSpawning` · `interrupt` · `forgetSession` · `refreshProbe`)
    final class RecordingAgent: AgentProcess, @unchecked Sendable {
        let inner: FakeAgentProcess
        let log: OrderLog
        let snapshot: @Sendable () -> String
        private let lock = NSLock()
        private var _refreshes = 0
        private var _onForget: (@Sendable () async -> Void)?

        init(inner: FakeAgentProcess, log: OrderLog, snapshot: @escaping @Sendable () -> String = { "" }) {
            self.inner = inner
            self.log = log
            self.snapshot = snapshot
        }

        var refreshCount: Int { lock.withLock { _refreshes } }
        func onForget(_ hook: (@Sendable () async -> Void)?) { lock.withLock { _onForget = hook } }

        var adapter: String { inner.adapter }
        func attach(_ services: AgentRuntimeServices) { inner.attach(services) }
        func probe() async -> BridgeV1AdapterReport { await inner.probe() }
        func refreshProbe() async {
            lock.withLock { _refreshes += 1 }
            log.add("refreshProbe")
        }
        func supportsVersion(_ version: String?) -> Bool { inner.supportsVersion(version) }
        func startTurn(_ turn: AgentTurnStart, events: AgentEventSink) async throws -> AgentProcessIdentity { try await inner.startTurn(turn, events: events) }
        func deliverAnswer(_ answer: AgentAnswerDelivery, events: AgentEventSink) async throws -> AgentAnswerResult { try await inner.deliverAnswer(answer, events: events) }
        func closeRequest(_ request: AgentRequestRef) async throws { try await inner.closeRequest(request) }
        func interrupt(_ target: AgentTurnRef, scope: AgentCancelScope) async -> AgentInterruptResult {
            log.add("interrupt \(snapshot())")
            return await inner.interrupt(target, scope: scope)
        }
        func liveness(_ identity: AgentProcessIdentity) async -> AgentLiveness { await inner.liveness(identity) }
        func terminateOrphan(_ identity: AgentProcessIdentity) async -> AgentLiveness { await inner.terminateOrphan(identity) }
        func readback(marker: String, session: AgentSessionRef) async -> AgentReadback { await inner.readback(marker: marker, session: session) }
        func sessionRun(_ sessionID: String) async -> AgentSessionRun? { await inner.sessionRun(sessionID) }
        func terminateSessionRun(_ sessionID: String) async -> AgentLiveness { await inner.terminateSessionRun(sessionID) }
        func stopSpawning() async {
            log.add("stopSpawning \(snapshot())")
            await inner.stopSpawning()
        }
        func hasRegisteredRuns() async -> Bool { await inner.hasRegisteredRuns() }
        func forgetSession(_ sessionID: String) async {
            log.add("forgetSession \(snapshot())")
            await inner.forgetSession(sessionID)
            await lock.withLock { _onForget }?()
        }
        func terminalSession(_ sessionID: String) async -> AgentTerminalSession? { await inner.terminalSession(sessionID) }
    }

    /// 한 요청을 붙잡아 두는 문 (진행 중인 등록에 사용자의 Connect가 합쳐지는 경쟁)
    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var waiter: CheckedContinuation<Void, Never>?
        private var opened = false

        func wait() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = lock.withLock { () -> Bool in
                    if opened { return true }
                    waiter = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }

        func open() {
            let pending = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                opened = true
                defer { waiter = nil }
                return waiter
            }
            pending?.resume()
        }
    }

    // MARK: 도우미

    private func advancing(_ h: BridgeHarness) -> Task<Void, Never> {
        Task {
            for _ in 0..<400 {
                if Task.isCancelled { return }
                await h.clock.advance(by: 0.25)
                try? await Task.sleep(for: .milliseconds(3))
            }
        }
    }

    /// 접수한 뒤 계속 도는 턴 하나가 있는 하네스 + 순서 줄
    private func runningHarness(deviceName: (@Sendable () -> String?)? = nil) async throws -> (BridgeHarness, RecordingAgent, OrderLog, FakeBridgeServer.Created) {
        let h = try BridgeHarness(withAdapter: false, deviceName: deviceName)
        let log = OrderLog()
        let credentials = h.credentials
        let partition = h.partition.id
        let agent = RecordingAgent(inner: h.agent, log: log, snapshot: { "secret=\((try? credentials.secret(partition: partition)) != nil)" })
        try await h.restart(adapters: [agent], reopenLedger: false)
        h.agent.setScript(.staysRunning())
        await h.registerFirst()
        let created = h.message()
        await h.runtime.tick()
        #expect(await h.eventually { (await h.command(created.commandID))?.state == .accepted })
        return (h, agent, log, created)
    }

    private func idle(deviceName: (@Sendable () -> String?)? = nil, withAdapter: Bool = true, userID: UUID = UUID()) async throws -> BridgeHarness {
        let h = try BridgeHarness(userID: userID, withAdapter: withAdapter, deviceName: deviceName)
        await h.registerFirst()
        return h
    }

    private func deletes(_ h: BridgeHarness) -> [FakeBridgeServer.Recorded] { h.server.requests("register").filter { $0.method == "DELETE" } }
    private func registers(_ h: BridgeHarness) -> [FakeBridgeServer.Recorded] { h.server.requests("register").filter { $0.method == "POST" } }

    // MARK: Disconnect this Mac: 순서가 계약이다 (6.3)

    @Test func disconnectGoesToTheServerFirstThenEndsForgetsClearsDeletesTheSecretAndMarksRevoked() async throws {
        let (h, agent, log, created) = try await runningHarness()
        let secrets = h.secrets
        let key = LocalSecretKey(taskID: created.taskID, requestID: "req-1")
        await secrets.put(key: key, value: AgentAnswerValue(text: "canary-value"))
        // 세션을 잊는 순간 이 Mac에 값이 새로 생긴다: 그 뒤에도 비워야 한다 (비밀값 비우기는 잊은 다음이다)
        agent.onForget { await secrets.put(key: LocalSecretKey(taskID: created.taskID, requestID: "late"), value: AgentAnswerValue(text: "late-value")) }
        let credentials = h.credentials
        let partition = h.partition.id
        h.server.onRequest = { [log] record in
            guard record.route == "register", record.method == "DELETE" else { return }
            log.add("revoke secret=\((try? credentials.secret(partition: partition)) != nil)")
        }
        let worker = advancing(h)
        let outcome = await h.runtime.disconnect()
        worker.cancel()
        #expect(outcome == .disconnected(unresolvedProcesses: 0))
        let lines = log.lines
        #expect(lines.first == "revoke secret=true", "서버가 먼저다: 그때 이 Mac은 아무것도 바뀌지 않았다 \(lines)")
        let revoke = try #require(log.index(of: "revoke"))
        let stop = try #require(log.index(of: "stopSpawning"))
        let interrupt = try #require(log.index(of: "interrupt"))
        let forget = try #require(log.index(of: "forgetSession"))
        #expect(revoke < stop && stop <= interrupt && interrupt < forget, "폐기 → 끝내기 → 잊기: \(lines)")
        #expect(lines[stop] == "stopSpawning secret=true" && lines[forget] == "forgetSession secret=true", "자격은 잊은 뒤에 지운다")
        #expect(deletes(h).count == 1 && deletes(h)[0].json["bridge_id"] as? String == h.bridgeID)
        #expect(await secrets.hasPending == false, "잊은 뒤에 새로 생긴 값까지 비운다")
        #expect(try credentials.secret(partition: partition) == nil, "장치 secret을 지웠다")
        #expect(try credentials.deviceID(partition: partition) != nil, "device_id는 둔다: 다시 연결이 같은 Mac을 되살린다")
        #expect(await h.runtime.status == .revoked)
        #expect(h.agent.liveRunCount == 0, "끝낸 뒤 감독 밖 writer 0")
        #expect(await h.task(created.taskID)?.alive == false)
        #expect(h.log.lines.contains { $0.hasPrefix("settings_agent_disconnect") && $0.contains("disconnected") }, "로그에는 결과 코드만: \(h.log.lines)")
        // 네트워크가 꺼졌다: 그 뒤에는 어떤 요청도 가지 않는다
        let before = h.server.requests.count
        h.clock.jump(by: 40)
        await h.runtime.tick()
        #expect(h.server.requests.count == before, "끊은 뒤 heartbeat · 목록 0")
    }

    @Test func aRevokeThatFailsChangesNothingOnThisMac() async throws {
        for (label, failure, expected) in [
            ("서버 오류", FakeBridgeServer.Failure(status: 500), AgentSettingsFailure.other),
            ("오프라인", FakeBridgeServer.Failure(status: 0, transport: true), AgentSettingsFailure.offline),
            ("429", FakeBridgeServer.Failure(status: 429, headers: ["Retry-After": "60"]), AgentSettingsFailure.other),
        ] {
            let (h, agent, log, created) = try await runningHarness()
            let credentials = h.credentials
            let partition = h.partition.id
            await h.secrets.put(key: LocalSecretKey(taskID: created.taskID, requestID: "req-1"), value: AgentAnswerValue(text: "keep"))
            h.server.failNext("register", failure)
            let outcome = await h.runtime.disconnect()
            #expect(outcome == .failed(expected), Comment(rawValue: label))
            #expect(log.lines.allSatisfy { $0 == "refreshProbe" || !$0.hasPrefix("stopSpawning") && !$0.hasPrefix("interrupt") && !$0.hasPrefix("forgetSession") }, "\(label): 끝내기 · 잊기 0 \(log.lines)")
            #expect(h.agent.interrupts.isEmpty && h.agent.forgottenSessions.isEmpty && h.agent.liveRunCount == 1, "\(label): 실행이 그대로 돈다")
            #expect(await h.secrets.hasPending, "\(label): 비밀값 그대로")
            #expect(try credentials.secret(partition: partition) != nil, "\(label): 장치 secret 그대로")
            #expect(await h.runtime.status == .connected, "\(label): 상태 그대로")
            _ = agent
            // 끊기가 실패해도 연결은 살아 있다: 다음 heartbeat가 간다
            let beats = h.server.requests("heartbeat").count
            h.clock.jump(by: 40)
            await h.runtime.tick()
            #expect(h.server.requests("heartbeat").count > beats, "\(label): 연결이 그대로 돈다")
            h.agent.killEverything()
        }
    }

    @Test func aServerThatDoesNotKnowTheBridgeStillLetsThisMacCleanUp() async throws {
        let h = try await idle()
        h.server.removeBridge(h.bridgeID)
        let outcome = await h.runtime.disconnect()
        #expect(outcome == .disconnected(unresolvedProcesses: 0), "서버에 이 bridge가 없다: 끊을 연결도 없다")
        #expect(try h.credentials.secret(partition: h.partition.id) == nil)
        #expect(await h.runtime.status == .revoked)
    }

    @Test func aProcessThatCannotBeEndedIsCountedAndTheMacIsStillRevoked() async throws {
        let (h, _, _, _) = try await runningHarness()
        h.agent.setIgnoreInterruptForever(true)
        h.agent.setTerminateResult(.alive)
        let worker = advancing(h)
        let outcome = await h.runtime.disconnect()
        worker.cancel()
        #expect(outcome == .disconnected(unresolvedProcesses: 1), "끝내지 못한 프로세스 수를 돌려준다 (호스트가 런타임을 바로 바꾸지 않는다)")
        #expect(await h.runtime.status == .revoked)
        h.agent.killEverything()
    }

    @Test func aLateRevokeAnswerAfterTheAccountLeftChangesNothingHere() async throws {
        let (h, _, log, created) = try await runningHarness()
        let credentials = h.credentials
        let partition = h.partition.id
        let runtime = h.runtime
        h.server.onRequest = { record in
            // 응답을 기다리는 사이 계정이 떠났다 (런타임이 멈춘다)
            if record.route == "register", record.method == "DELETE" { await runtime.stop() }
        }
        let outcome = await h.runtime.disconnect()
        #expect(outcome == .failed(.other), "늦은 응답은 버린다")
        #expect(!log.lines.contains { $0.hasPrefix("forgetSession") || $0.hasPrefix("interrupt") }, "정리 0: \(log.lines)")
        #expect(try credentials.secret(partition: partition) != nil, "자격을 지우지 않았다")
        #expect(h.agent.forgottenSessions.isEmpty && h.agent.interrupts.isEmpty)
        #expect(await h.task(created.taskID)?.alive == true, "그 계정의 실행은 건드리지 않았다 (돌아오면 다음 heartbeat의 403이 같은 정리를 한다)")
        h.agent.killEverything()
    }

    @Test func overlappingDisconnectsShareOneRevoke() async throws {
        let h = try await idle()
        async let first = h.runtime.disconnect()
        async let second = h.runtime.disconnect()
        let (a, b) = await (first, second)
        #expect(a == .disconnected(unresolvedProcesses: 0) && b == a)
        #expect(deletes(h).count == 1, "폐기는 한 번만 보낸다")
    }

    @Test func thereIsNothingToDisconnectBeforeRegistrationOrAfterTheAccountLeft() async throws {
        let h = try BridgeHarness()
        #expect(await h.runtime.disconnect() == .unavailable, "등록 전")
        #expect(h.server.requests.isEmpty)
        await h.registerFirst()
        await h.runtime.stop()
        #expect(await h.runtime.disconnect() == .unavailable, "멈춘 런타임")
        let drain = try BridgeHarness(mode: .drain)
        #expect(await drain.runtime.disconnect() == .unavailable, "마무리 모드")
    }

    // MARK: 끊은 런타임은 다시 쓰지 않는다 · 새 런타임에서 Reconnect (6.2 · 6.3)

    @Test func theDisconnectedRuntimeNeverConnectsOrReconnectsAgain() async throws {
        let h = try await idle()
        _ = await h.runtime.disconnect()
        let before = h.server.requests.count
        #expect(await h.runtime.connectAgent(Self.adapter) == .unavailable)
        #expect(await h.runtime.reconnectAgent(Self.adapter) == .unavailable, "`stopSpawning`이 켜진 런타임은 다시 쓰지 않는다: 호스트가 새 런타임을 만든다")
        #expect(await h.runtime.reconnect(adapters: [Self.adapter]) == false)
        #expect(h.server.requests.count == before, "서버 호출 0")
    }

    @Test func aNewRuntimeOnTheSamePartitionIsRevokedAtFirstThenReconnectsAndSpawnsAgain() async throws {
        let (h, _, _, created) = try await runningHarness()
        let worker = advancing(h)
        _ = await h.runtime.disconnect()
        worker.cancel()
        #expect(h.agent.startedTurns.count == 1)
        // 호스트가 하는 일: 그 런타임을 놓고 같은 파티션(같은 원장 · 같은 자격 저장소)의 새 런타임을 만든다
        await h.runtime.close()
        try await h.restart(adapters: [h.agent], reopenLedger: true)
        h.agent.setScript(.normal())
        await h.runtime.tick()
        #expect(await h.runtime.status == .revoked, "장치 secret이 없어 첫 자동 등록은 403으로 끝난다 → 화면은 Not connected · Reconnect")
        let registersBefore = registers(h).count
        #expect(registersBefore >= 2 && registers(h).last?.json["reactivate"] as? Bool == false)
        let outcome = await h.runtime.reconnectAgent(Self.adapter)
        #expect(outcome == .connected)
        let reconnect = try #require(registers(h).last)
        #expect(reconnect.json["reactivate"] as? Bool == true && reconnect.json["connect"] as? [String] == [Self.adapter], "reactivate: true + connect를 다시 싣는다")
        #expect(reconnect.json["device_id"] as? String == (try h.credentials.deviceID(partition: h.partition.id)), "같은 Mac(device_id)")
        #expect(await h.runtime.status != .revoked)
        // 옛 stopSpawning이 남지 않는다: 새 턴이 뜬다
        // 옛 세션은 되살아나지 않는다 (D2a Q6): 새 세션의 새 턴이다
        let next = h.message("again", session: UUID().uuidString.lowercased(), task: UUID().uuidString.lowercased(), turn: 1)
        h.clock.jump(by: 6)
        await h.runtime.tick()
        #expect(await h.eventually { h.agent.startedTurns.count == 2 }, "다음 턴 spawn: \(h.server.requests.map(\.route))")
        _ = (created, next)
        h.agent.killEverything()
    }

    @Test func reconnectWorksFromACredentialRejectedRuntime() async throws {
        let h = try await idle()
        h.server.failNext("commands", .init(status: 401, count: 10))
        _ = await h.runtime.poll(wait: 0, reason: .realtime)
        #expect(await h.runtime.status == .credentialRejected)
        h.server.clearFailures()
        #expect(await h.runtime.reconnectAgent(Self.adapter) == .connected)
        let last = try #require(registers(h).last)
        #expect(last.json["reactivate"] as? Bool == true && last.json["connect"] as? [String] == [Self.adapter], "활성 기기에 reactivate: true를 보내면 SQL은 rotated이고 10대 검사도 타지 않는다")
        #expect(await h.runtime.status != .credentialRejected)
    }

    @Test func reconnectRestartsALoopThatEndedWhenAnotherDeviceRevokedThisMac() async throws {
        let h = try BridgeHarness()
        h.agent.setScript(.normal())
        await h.runtime.start()
        let worker = advancing(h)
        #expect(await h.eventually { await h.runtime.status == .connected })
        // 다른 기기가 이 Mac을 폐기했다: 다음 heartbeat의 403이 루프를 끝낸다
        h.server.revoke(bridgeID: h.bridgeID)
        h.clock.jump(by: 40)
        #expect(await h.eventually { await h.runtime.status == .revoked })
        #expect(await h.eventually { await !h.runtime.loopsRunning }, "403으로 루프가 끝났다")
        let outcome = await h.runtime.reconnectAgent(Self.adapter)
        #expect(outcome == .connected)
        #expect(await h.eventually { await h.runtime.loopsRunning }, "되살아난 Mac은 루프를 다시 돈다")
        let last = try #require(registers(h).last)
        #expect(last.json["reactivate"] as? Bool == true && last.json["connect"] as? [String] == [Self.adapter])
        h.message("hello")
        h.server.notifyChange()
        #expect(await h.eventually { h.agent.startedTurns.count == 1 })
        worker.cancel()
        h.agent.killEverything()
    }

    @Test func reconnectWakesARuntimeThatWasWaitingForTheUserWithoutTheThirtySecondWait() async throws {
        let (h, _, _, _) = try await runningHarness()
        _ = await h.runtime.disconnect()
        await h.runtime.close()
        try await h.restart(adapters: [h.agent], reopenLedger: true)
        h.agent.setScript(.normal())
        await h.runtime.start() // 새 런타임의 루프: 첫 등록이 403 → 사용자 행동을 기다린다
        #expect(await h.eventually { await h.runtime.status == .revoked })
        let outcome = await h.runtime.reconnectAgent(Self.adapter)
        #expect(outcome == .connected)
        // 수동 시계는 흐르지 않는다: 30초를 기다리는 루프라면 이 턴은 뜨지 않는다
        h.message("after reconnect", session: UUID().uuidString.lowercased(), task: UUID().uuidString.lowercased(), turn: 1)
        h.server.notifyChange()
        #expect(await h.eventually { h.agent.startedTurns.count == 2 }, "Reconnect가 쉬던 루프를 바로 깨운다: \(h.server.requests.map(\.route))")
        h.agent.killEverything()
    }

    @Test func aReconnectThatJoinedAFailingInFlightRegistrationIsSentAgainAsReactivate() async throws {
        let (h, _, _, _) = try await runningHarness()
        _ = await h.runtime.disconnect()
        await h.runtime.close()
        try await h.restart(adapters: [h.agent], reopenLedger: true)
        h.agent.setScript(.normal())
        let gate = Gate()
        let arrived = Locked(false)
        h.server.onRequest = { record in
            guard record.route == "register", record.method == "POST", !arrived.get() else { return }
            arrived.set(true)
            await gate.wait() // 새 런타임의 처음(자동) 등록을 붙잡아 둔다: 장치 secret이 없어 403이다
        }
        let runtime = h.runtime
        await runtime.start()
        #expect(await h.eventually { arrived.get() })
        let reconnect = Task { await runtime.reconnectAgent(Self.adapter) }
        // pendingConnect가 보이면 Reconnect는 이미 진행 중인 등록에 합쳐졌다 (그 사이에 await가 없다)
        #expect(await h.eventually { await runtime.pendingConnect == [Self.adapter] })
        gate.open()
        let outcome = await reconnect.value
        #expect(outcome == .connected, "합쳐진 등록의 403은 내 요청의 실패가 아니다: reactivate를 한 번 더 보낸다")
        let last = try #require(registers(h).last)
        #expect(last.json["reactivate"] as? Bool == true && last.json["connect"] as? [String] == [Self.adapter])
        #expect(await runtime.pendingConnect.isEmpty)
        h.agent.killEverything()
    }

    // MARK: Connect (6.1)

    @Test func connectRegistersWithConnectOnlyForThatAdapter() async throws {
        let h = try await idle()
        let outcome = await h.runtime.connectAgent(Self.adapter)
        #expect(outcome == .connected)
        let last = try #require(registers(h).last)
        #expect(last.json["connect"] as? [String] == [Self.adapter] && last.json["reactivate"] as? Bool == false)
        #expect(h.log.lines.contains { $0.contains("settings_agent_connect") && $0.contains("connected") })
    }

    @Test func connectNeverCreatesAConnectionForAnAdapterThisBuildDoesNotHave() async throws {
        let h = try await idle(withAdapter: false)
        let before = h.server.requests.count
        #expect(await h.runtime.connectAgent(Self.adapter) == .unavailable)
        #expect(h.server.requests.count == before)
        #expect(h.runtime.hasAdapter(Self.adapter) == false)
    }

    @Test func hasAdapterIsTrueOnlyForTheAdaptersThisRuntimeWasBuiltWith() async throws {
        let h = try BridgeHarness()
        #expect(h.runtime.hasAdapter(Self.adapter) && !h.runtime.hasAdapter("agent:codex"))
    }

    @Test func connectFailuresAreWordedByWhereTheyStopped() async throws {
        // 오프라인 · 서버 오류 · 429
        for (failure, expected) in [
            (FakeBridgeServer.Failure(status: 0, transport: true), AgentConnectOutcome.failed(.offline)),
            (FakeBridgeServer.Failure(status: 500), .failed(.other)),
            (FakeBridgeServer.Failure(status: 429, headers: ["Retry-After": "60"]), .failed(.other)),
        ] {
            let h = try await idle()
            h.server.failNext("register", failure)
            #expect(await h.runtime.connectAgent(Self.adapter) == expected)
            #expect(await h.runtime.pendingConnect.isEmpty, "실패한 Connect를 뒤의 자동 등록에 남기지 않는다 (연결은 사용자 행동으로만)")
        }
        // 10대: 409
        let userID = UUID()
        let full = try BridgeHarness(userID: userID)
        full.server.fillBridges(userID: userID, count: 10)
        await full.registerFirst()
        #expect(await full.runtime.status == .tooManyBridges)
        #expect(await full.runtime.connectAgent(Self.adapter) == .tooManyMacs)
        // 다른 기기가 폐기: 403
        let revoked = try await idle()
        revoked.server.revoke(bridgeID: revoked.bridgeID)
        revoked.clock.jump(by: 40)
        await revoked.runtime.tick()
        #expect(await revoked.runtime.status == .revoked)
        #expect(await revoked.runtime.connectAgent(Self.adapter) == .needsReconnect)
    }

    @Test func aConnectThatJoinedAnInFlightRegistrationIsSentAgainWithTheConnectList() async throws {
        let h = try BridgeHarness()
        let gate = Gate()
        let arrived = Locked(false)
        h.server.onRequest = { record in
            guard record.route == "register", record.method == "POST", !arrived.get() else { return }
            arrived.set(true)
            await gate.wait() // 처음(자동) 등록을 붙잡아 둔다
        }
        let runtime = h.runtime
        let firstTick = Task { await runtime.tick() }
        #expect(await h.eventually { arrived.get() })
        let connect = Task { await runtime.connectAgent(Self.adapter) }
        try await Task.sleep(for: .milliseconds(50))
        gate.open()
        let outcome = await connect.value
        await firstTick.value
        #expect(outcome == .connected)
        let all = registers(h)
        #expect(all.count == 2, "합쳐진 요청에는 connect가 없었다: 한 번 더 보낸다 \(all.map { $0.json["connect"] ?? "-" })")
        #expect(all.last?.json["connect"] as? [String] == [Self.adapter])
        #expect(await h.runtime.pendingConnect.isEmpty)
    }

    // MARK: 다른 Mac 지우기 (6.4)

    @Test func removingAnotherMacRevokesThatBridgeOnlyAndFreesTheSlotWithoutConnecting() async throws {
        let userID = UUID()
        let h = try BridgeHarness(userID: userID)
        h.server.fillBridges(userID: userID, count: 10)
        await h.registerFirst()
        #expect(await h.runtime.status == .tooManyBridges)
        let others = h.server.activeBridgeIDs(userID: userID)
        #expect(others.count == 10)
        let target = try #require(others.first)
        let registerCount = registers(h).count
        let outcome = await h.runtime.removeMac(bridgeID: target.uppercased())
        #expect(outcome == .removed)
        #expect(deletes(h).count == 1 && deletes(h)[0].json["bridge_id"] as? String == target, "사용자 토큰으로 그 Mac만 폐기한다")
        #expect(h.server.bridgeIsActive(target) == false && h.server.activeBridgeIDs(userID: userID).count == 9)
        #expect(await h.runtime.status != .tooManyBridges, "자리가 생겼다: Connect가 다시 열린다")
        #expect(registers(h).count == registerCount, "자동으로 연결하지 않는다")
        #expect(await h.runtime.connectAgent(Self.adapter) == .connected, "사용자가 Connect를 누르면 간다")
    }

    @Test func thisMacIsNeverRemovedThroughTheOtherMacPath() async throws {
        let h = try await idle()
        let before = h.server.requests.count
        #expect(await h.runtime.removeMac(bridgeID: h.bridgeID) == .refused)
        #expect(await h.runtime.removeMac(bridgeID: h.bridgeID.uppercased()) == .refused, "대소문자가 달라도 이 Mac이다")
        #expect(await h.runtime.removeMac(bridgeID: "not-a-uuid") == .refused)
        #expect(h.server.requests.count == before, "서버 호출 0")
        #expect(h.server.bridgeIsActive(h.bridgeID))
    }

    @Test func removingAMacThatFailsAtTheServerChangesNothing() async throws {
        let userID = UUID()
        let h = try BridgeHarness(userID: userID)
        h.server.fillBridges(userID: userID, count: 10)
        await h.registerFirst()
        let target = try #require(h.server.activeBridgeIDs(userID: userID).first)
        h.server.failNext("register", .init(status: 0, transport: true))
        #expect(await h.runtime.removeMac(bridgeID: target) == .failed(.offline))
        h.server.failNext("register", .init(status: 500))
        #expect(await h.runtime.removeMac(bridgeID: target) == .failed(.other))
        let status = await h.runtime.status
        #expect(h.server.bridgeIsActive(target) && status == .tooManyBridges)
    }

    // MARK: probe (8장)

    @Test func theCurrentReportsAreReadWithoutTouchingTheServerReportClock() async throws {
        let h = try BridgeHarness(withAdapter: false)
        let log = OrderLog()
        let agent = RecordingAgent(inner: h.agent, log: log)
        try await h.restart(adapters: [agent], reopenLedger: false)
        await h.registerFirst()
        let requests = h.server.requests.count
        let reports = await h.runtime.adapterReports()
        #expect(reports.map(\.adapter) == [Self.adapter] && reports[0].installed && reports[0].signedIn == .yes)
        #expect(h.server.requests.count == requests && agent.refreshCount == 0, "읽기만 한다: 서버 호출 0 · 캐시 비움 0")
    }

    @Test func refreshClearsTheLoginCacheProbesAndTellsTheServerWhatChanged() async throws {
        let h = try BridgeHarness(withAdapter: false)
        let log = OrderLog()
        let agent = RecordingAgent(inner: h.agent, log: log)
        try await h.restart(adapters: [agent], reopenLedger: false)
        await h.registerFirst()
        h.clock.jump(by: 20) // heartbeat를 보낸 지 오래되지 않은 척하지 않는다
        // Terminal에서 로그인했다 (Claude Code가 `loggedIn: false`였다가 `true`가 된 것의 반대: 여기서는 로그아웃으로 바꿔 서버 보고가 달라지게)
        h.agent.setReport { $0.signedIn = .no }
        let beats = h.server.requests("heartbeat").count
        let reports = await h.runtime.refreshAdapterReports()
        #expect(agent.refreshCount == 1, "로그인 캐시를 비웠다")
        #expect(reports[0].signedIn == .no, "받은 보고를 화면 값으로 낸다")
        let sent = h.server.requests("heartbeat")
        #expect(sent.count == beats + 1, "heartbeat로 서버 보고를 바꾼다")
        let adapters = try #require(sent.last?.json["adapters"] as? [[String: Any]])
        #expect(adapters.first?["signed_in"] as? String == "no", "달라진 보고가 실렸다")
    }

    @Test func refreshIsLimitedToOncePerTenSeconds() async throws {
        let h = try BridgeHarness(withAdapter: false)
        let log = OrderLog()
        let agent = RecordingAgent(inner: h.agent, log: log)
        try await h.restart(adapters: [agent], reopenLedger: false)
        await h.registerFirst()
        _ = await h.runtime.refreshAdapterReports()
        h.agent.setReport { $0.version = "2.1.250" }
        h.clock.jump(by: 9)
        let cached = await h.runtime.refreshAdapterReports()
        #expect(agent.refreshCount == 1 && cached[0].version == "2.1.241", "10초 안의 두 번째는 마지막 보고를 그대로 준다")
        let heartbeats = h.server.requests("heartbeat").count
        h.clock.jump(by: 2)
        let fresh = await h.runtime.refreshAdapterReports()
        #expect(agent.refreshCount == 2 && fresh[0].version == "2.1.250", "10초가 지나면 다시 읽는다")
        #expect(h.server.requests("heartbeat").count == heartbeats + 1)
    }

    @Test func aRevokedRuntimeRefreshesTheReportButSendsNothing() async throws {
        let h = try await idle()
        h.server.revoke(bridgeID: h.bridgeID)
        h.clock.jump(by: 40)
        await h.runtime.tick()
        #expect(await h.runtime.status == .revoked)
        let before = h.server.requests.count
        _ = await h.runtime.refreshAdapterReports()
        #expect(h.server.requests.count == before, "폐기된 Mac은 서버에 보고하지 않는다")
    }

    // MARK: liveSince

    @Test func liveSinceIsTheEarliestStartOfARunThatIsStillAlive() async throws {
        let h = try await idle()
        #expect(await h.runtime.liveSince() == nil, "살아 있는 실행이 없다")
        h.agent.setScript(.staysRunning())
        let created = h.message()
        await h.runtime.tick()
        #expect(await h.eventually { (await h.command(created.commandID))?.state == .accepted })
        let since = try #require(await h.runtime.liveSince())
        let task = try #require(await h.task(created.taskID))
        #expect(since == (task.processStartedAt ?? task.acceptedAt ?? task.updatedAt) && since <= h.clock.now)
        let worker = advancing(h)
        _ = await h.runtime.interruptLiveTurns()
        worker.cancel()
        #expect(await h.runtime.liveSince() == nil, "끝나면 없다")
    }

    // MARK: 자격 저장소

    @Test func deletingTheSecretKeepsTheDeviceID() throws {
        let store = InMemoryBridgeCredentialStore()
        try store.save(deviceID: "device-id-0123456789", partition: "p")
        try store.save(secret: "secret", partition: "p")
        try store.deleteSecret(partition: "p")
        #expect(try store.secret(partition: "p") == nil && store.deviceID(partitionOrNil: "p") == "device-id-0123456789")
    }

    private struct MinimalStore: BridgeCredentialStore {
        func deviceID(partition: String) throws -> String? { nil }
        func secret(partition: String) throws -> String? { nil }
        func save(deviceID: String, partition: String) throws {}
        func save(secret: String, partition: String) throws {}
        func deleteAll(partition: String) throws {}
    }

    @Test func aStoreThatCannotDeleteJustTheSecretRefusesInsteadOfDeletingTheDeviceIDToo() {
        #expect(throws: BridgeCredentialStoreUnsupported.self) { try MinimalStore().deleteSecret(partition: "p") }
    }

    @Test func theKeychainQueryForTheSecretOnlyNamesTheSecretItem() {
        let query = BridgeKeychainQuery.match(partition: "p", kind: .secret)
        #expect(query[kSecAttrAccount as String] as? String == "p:secret", "device_id 항목을 가리키지 않는다")
    }
}

extension InMemoryBridgeCredentialStore {
    fileprivate func deviceID(partitionOrNil partition: String) -> String? { (try? deviceID(partition: partition)) ?? nil }
}
#endif
