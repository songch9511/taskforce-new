#if os(macOS) && DEBUG
import Darwin
import Foundation
import Synchronization
import Testing
import TaskforceAgentWire
@testable import TaskforceKit

/// 재검토 7 — adapter · 소켓 (OA D3a 16장 2 · 3 · 5 · 7 · 1의 adapter 쪽): 다른 훅의 시간 초과와 답 닫기를 한 경계에서(Astra P2), 훅의 남은 시간(sec F5),
/// 등록부의 끝 증명(sec F2), 잠금 자리 없는 세션(sec F7), 종료 뒤 spawn 막기. 가짜 `claude` + 실제로 빌드한 helper · 지킴이. 실제 `claude` 실행 0
@Suite(.serialized)
struct ClaudeRereview7Tests {
    typealias AnswerSlot = ClaudeCodeProcess.AnswerSlot
    let box = ClaudeSandbox()
    static let allow = HookResponse(decision: .allow, reason: "answer")
    static let deny = HookResponse(decision: .deny, reason: "answer_closed")

    /// 훅 요청 한 줄. `remaining`이 있으면 지금부터 그만큼 뒤의 절대 기한을 싣는다 (17장 2)
    static func request(_ toolUseID: String, remaining: TimeInterval? = nil) throws -> Data {
        try HookRequest(
            nonce: HookSocketServerTests.nonce, sessionID: ClaudeTest.session, providerSessionID: "claude-1", hookEvent: "PreToolUse", toolUseID: toolUseID, toolName: "Read",
            toolInput: .object([:]), inputSHA256: "d", permissionMode: "default", cwd: "/c",
            deadlineNS: remaining.map { HookWire.monotonicNow() &+ UInt64(max(0, $0) * 1_000_000_000) }
        ).encodedLine()
    }

    func server() throws -> (HookSocketServer, String) {
        let path = box.root.appending(path: "s/hook.sock").path
        let server = HookSocketServer(path: path, peerUID: HookSocketServer.peerUID)
        try server.start()
        return (server, path)
    }

    static func exchange(_ path: String, _ line: Data) async throws -> HookResponse {
        try await offPool { try HookResponse.decode(line: UnixSocket.exchange(path: path, request: line, deadline: Date().addingTimeInterval(HookWire.budget))) }
    }

    // MARK: 2 (Astra P2) 다른 훅 B의 시간 초과 · 답 훅 A — 두 HookCommit

    /// B의 시간 초과를 정하는 그 자리(슬롯 잠금 안)에서 미전달 답을 닫는다: 그 뒤 A의 allow는 닫힌 슬롯을 보고 answers 없는 deny를 확정한다
    @Test func t2AnotherHooksTimeoutClosesTheAnswerInTheSameBoundary() {
        let slot = AnswerSlot(AgentAnswerValue(text: "blue"))
        let answerHook = HookCommit()
        let otherHook = HookCommit()
        let (won, closed) = slot.timeOut(otherHook)
        #expect(won == nil && closed)
        #expect(slot.signal == .lost && slot.value.text == nil)
        #expect(!otherHook.commit(Self.allow), "B는 시간 초과로 정해졌다")
        #expect(slot.commitAnswer(Self.allow, closed: Self.deny, to: answerHook, at: Date()) == .alreadyClosed)
        #expect(answerHook.timeOut() == Self.deny, "A는 답이 아니라 닫힘 응답을 받았다")
    }

    /// A가 먼저 전달됐으면 B의 시간 초과는 닫지 않는다 (결과 delivered = A가 받은 allow)
    @Test func t2AnAnswerDeliveredBeforeAnotherHooksTimeoutStaysDelivered() {
        let slot = AnswerSlot(AgentAnswerValue(text: "blue"))
        let answerHook = HookCommit()
        let otherHook = HookCommit()
        let at = Date(timeIntervalSince1970: 3)
        #expect(slot.commitAnswer(Self.allow, closed: Self.deny, to: answerHook, at: at) == .delivered)
        let (won, closed) = slot.timeOut(otherHook)
        #expect(won == nil && !closed)
        #expect(slot.signal == .delivered(at))
        #expect(answerHook.timeOut()?.decision == .allow)
    }

    /// B의 처리기가 기한 직전에 먼저 확정했으면 B는 시간 초과가 아니다: 답을 닫지 않는다
    @Test func t2AHookWhoseHandlerAnsweredFirstLeavesTheAnswerOpen() {
        let slot = AnswerSlot(AgentAnswerValue(text: "blue"))
        let otherHook = HookCommit()
        let own = HookResponse(decision: .deny, reason: "outside")
        #expect(otherHook.commit(own))
        let (won, closed) = slot.timeOut(otherHook)
        #expect(won == own && !closed)
        #expect(slot.signal == nil && slot.value.text == "blue")
        #expect(slot.commitAnswer(Self.allow, closed: Self.deny, to: HookCommit(), at: Date()) == .delivered)
    }

    /// 소켓은 기한이 지나면 등록의 `timeOut`으로 그 요청을 정한다 (그 경계에서 답을 닫는다): 응답은 시간 초과 deny, 슬롯은 닫혔다
    @Test func t2TheSocketSettlesATimeoutThroughTheRegistration() async throws {
        let (server, path) = try server()
        defer { server.stop() }
        let slot = AnswerSlot(AgentAnswerValue(text: "blue"))
        let settled = Shared(0)
        server.register(nonce: HookSocketServerTests.nonce, HookSocketServer.Registration(agentSessionID: ClaudeTest.session, providerSessionID: "claude-1", committing: { _, _ in
            try? await Task.sleep(for: .seconds(3))
        }, timeOut: { commit, _ in
            settled.mutate { $0 += 1 }
            return slot.timeOut(commit).won
        }))
        let response = try await Self.exchange(path, Self.request("toolu_b"))
        #expect(response.decision == .deny)
        #expect(settled.value == 1)
        #expect(slot.signal == .lost, "B의 시간 초과가 그 자리에서 답을 닫았다")
    }

    // MARK: 3 (sec F5 · 17장 2) 기한 하나

    @Test func t3TheBridgeDecidesBeforeTheHookGivesUp() {
        let started: UInt64 = 100_000_000_000
        let own = started + 1_200_000_000
        #expect(HookSocketServer.deadline(startedNS: started, hookDeadlineNS: nil) == own)
        #expect(HookSocketServer.deadline(startedNS: started, hookDeadlineNS: started + 3_900_000_000) == own, "넉넉하면 자기 예산")
        #expect(HookSocketServer.deadline(startedNS: started, hookDeadlineNS: started + 500_000_000) == started + 200_000_000, "훅 기한 − 0.3초 (보낸 때부터의 절대 기한)")
        #expect(HookSocketServer.deadline(startedNS: started, hookDeadlineNS: 100_000_000) == 0, "이미 지난 기한")
        #expect(HookWire.budget > HookSocketServer.readBudget + HookSocketServer.responseBudget + HookSocketServer.hookMargin, "훅 예산 > bridge 읽기 + 응답 예산")
    }

    /// 훅이 거의 끝나 가면 bridge는 그보다 앞서 시간 초과로 정한다: 늦게 온 처리기의 답은 확정되지 않는다 (= 전달이라고 적히지 않는다)
    @Test func t3ALateHandlerCannotCommitPastTheHooksRemainingTime() async throws {
        let (server, path) = try server()
        defer { server.stop() }
        let late = Shared<Bool?>(nil)
        server.register(nonce: HookSocketServerTests.nonce, HookSocketServer.Registration(agentSessionID: ClaudeTest.session, providerSessionID: "claude-1", committing: { _, commit in
            try? await Task.sleep(for: .milliseconds(500))
            let committed = commit.commit(Self.allow)
            late.mutate { $0 = committed }
        }))
        let started = Date()
        let response = try await Self.exchange(path, Self.request("toolu_q", remaining: 0.4))
        // 훅 기한을 보지 않았다면 처리기의 allow(0.5초)가 bridge 자기 예산(1.2초) 안에 확정돼 돌아왔다: deny + 늦은 확정 거절이 훅 기한으로 정했다는 증거다.
        // 시간은 자기 예산보다 앞이었는지만 본다 (부하에서도 결과가 뒤집히지 않는 상한)
        #expect(response.decision == .deny, "훅이 끊기 전에 시간 초과로 정했다")
        #expect(Date().timeIntervalSince(started) < HookSocketServer.responseBudget, "자기 예산이 아니라 훅 기한으로")
        #expect(await ClaudeRereview5ReproTests.waitUntil(30) { late.value != nil })
        #expect(late.value == false, "기한 뒤의 답은 확정되지 않는다")
    }

    // MARK: 5 → 17장 1 등록부의 틈 (sec `gapThenInternalCloseIsInvisible`)

    /// 내부 닫기 직전(턴 spawn은 끝을 증명했지만 따라올 닫기가 정해져 등록부에 있다): 세션의 지금 실행은 살아 있다 (17장 1이 16장 5를 대신한다 —
    /// 이 틈에 끝이라고 하면 런타임이 감독을 내리고 뒤이은 내부 닫기가 생존 판단 밖이 된다)
    @Test func t5ARegisteredSpawnWithAFollowUpCloseStaysAliveForTheSession() async throws {
        let seen = Mutex<AgentSessionRun?>(nil)
        let holder = Mutex<ClaudeCodeProcess?>(nil)
        let hooks = ClaudeCodeTestHooks(beforeFinishClose: {
            guard let process = holder.withLock({ $0 }) else { return }
            let run = await process.sessionRun(ClaudeTest.session)
            seen.withLock { $0 = run }
        })
        let fake = try FakeClaude(hooks: hooks)
        holder.withLock { $0 = fake.process }
        try fake.scenario(["runs": [["steps": [["tool": "mcp__tf__ask_user", "id": "toolu_q", "input": FakeClaude.askColor]]], ["steps": [["text": "close"]]]]])
        // 열린 요청을 상태 파일에 적지 못하게: 끝날 때 그 요청을 닫기 모드로 닫는다 (내부 닫기)
        let folder = try ClaudeSessionFolder.prepare(sessionsRoot: fake.box.sessionsRoot, agentSessionID: ClaudeTest.session)
        try FileManager.default.createDirectory(at: folder.root.appending(path: "state.json"), withIntermediateDirectories: true)
        let events = EventLog()
        _ = try await fake.turn(events: events)
        // 턴 + 내부 닫기의 끝 증명까지 (포기 상한만: 맞으면 바로 돌아온다. 붐비는 Kit 전체 실행에서 15초를 넘겼다, 19장)
        #expect(await events.wait { FakeClaude.ended($0) })
        let run = try #require(seen.withLock { $0 }, "내부 닫기 직전에 물었다")
        #expect(run.liveness == .alive)
        #expect(await fake.process.sessionRun(ClaudeTest.session)?.liveness == .ended(AgentExit(code: nil)), "내부 닫기까지 끝난 뒤에는 끝")
    }

    // MARK: 7 (sec F7) 잠금 자리 없는 세션

    @Test func t7ASessionWithoutALockPlaceHasNoRun() async {
        let adapter = ClaudeRereview3ReproTests.adapter(box)
        #expect(await adapter.sessionRun("not-a-uuid")?.liveness == .ended(AgentExit(code: nil)))
        #expect(await adapter.terminateSessionRun("not-a-uuid") == .ended(AgentExit(code: nil)))
    }

    // MARK: 1 종료 뒤 spawn 막기 (adapter)

    /// 종료가 시작되면 턴 · 답 · 닫기 어느 것도 띄우지 않는다 (프로세스 0, 잠금 0)
    @Test func t1NoSpawnStartsAfterShutdownBegins() async throws {
        let fake = try FakeClaude()
        try fake.scenario(["runs": [["steps": [["text": "never"]]]]])
        await fake.process.stopSpawning()
        await #expect(throws: AgentStartError(.spawnFailed)) { _ = try await fake.turn(events: EventLog()) }
        let ref = AgentRequestRef(taskID: ClaudeTest.task, sessionID: ClaudeTest.session, requestID: "toolu_q", externalSessionID: UUID().uuidString.lowercased(), workspaceRef: fake.workspace)
        await #expect(throws: AgentStartError(.spawnFailed)) { try await fake.process.closeRequest(ref) }
        #expect(fake.report(0) == nil, "가짜 claude가 한 번도 뜨지 않았다")
        let lock = try #require(ClaudeSessionLock.file(sessionsRoot: fake.box.sessionsRoot, session: ClaudeTest.session))
        #expect(ClaudeSessionLock.read(lock) == .none)
    }

    /// 종료가 시작된 뒤 끝나는 턴의 내부 닫기도 띄우지 않는다
    @Test func t1AnInternalCloseIsNotSpawnedAfterShutdownBegins() async throws {
        let holder = Mutex<ClaudeCodeProcess?>(nil)
        let hooks = ClaudeCodeTestHooks(beforeFinishClose: {
            await holder.withLock({ $0 })?.stopSpawning()
        })
        let fake = try FakeClaude(hooks: hooks)
        holder.withLock { $0 = fake.process }
        try fake.scenario(["runs": [["steps": [["tool": "mcp__tf__ask_user", "id": "toolu_q", "input": FakeClaude.askColor]]], ["steps": [["text": "close"]]]]])
        let folder = try ClaudeSessionFolder.prepare(sessionsRoot: fake.box.sessionsRoot, agentSessionID: ClaudeTest.session)
        try FileManager.default.createDirectory(at: folder.root.appending(path: "state.json"), withIntermediateDirectories: true)
        let events = EventLog()
        _ = try await fake.turn(events: events)
        #expect(await events.wait { FakeClaude.ended($0) })
        #expect(fake.report(1) == nil, "닫기 spawn 0")
    }
}
#endif
