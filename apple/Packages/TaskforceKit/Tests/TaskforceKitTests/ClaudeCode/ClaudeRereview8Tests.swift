#if os(macOS) && DEBUG
import Darwin
import Foundation
import Synchronization
import Testing
import TaskforceAgentWire
@testable import TaskforceKit

/// 재검토 8 — adapter · 소켓 (OA D3a 17장 1 · 2 · 3): 실행 등록부 하나(Astra P1-1 · P1-2, sec `gapThenInternalCloseIsInvisible`), 기한 하나(Astra P2 · sec F5 · S8-2),
/// 질문을 받은 쪽의 닫기가 자기를 기다리지 않음(sec S8-3). 가짜 `claude` + 실제로 빌드한 helper · 지킴이. 실제 `claude` 실행 0
@Suite(.serialized)
struct ClaudeRereview8Tests {
    let box = ClaudeSandbox()
    static let allow = HookResponse(decision: .allow, reason: "answer")

    func harness(_ fake: FakeClaude) async throws -> BridgeHarness {
        let harness = try BridgeHarness(withAdapter: false, workspace: fake.workspace)
        try await harness.restart(adapters: [fake.process], reopenLedger: false)
        fake.process.attach(AgentRuntimeServices(decideTool: fake.decider.function))
        await harness.registerFirst()
        return harness
    }

    /// 열린 요청을 상태 파일에 적지 못하게 해 끝날 때 그 요청을 내부 닫기로 닫게 한다
    static func forceInternalClose(_ fake: FakeClaude) throws {
        let folder = try ClaudeSessionFolder.prepare(sessionsRoot: fake.box.sessionsRoot, agentSessionID: ClaudeTest.session)
        try FileManager.default.createDirectory(at: folder.root.appending(path: "state.json"), withIntermediateDirectories: true)
    }

    // MARK: 1 (Astra P1-1) 내부 닫기 틈

    /// 턴 spawn이 끝을 증명하고 내부 닫기를 띄우기 직전, 깨어난 뒤의 생존 확인이 돌았다: 감독을 내리지 않고(세션의 지금 실행 = 살아 있음) 살아 있는 프로세스로 남는다
    @Test func r1AWakeInTheInternalCloseGapKeepsTheRunLive() async throws {
        let holder = Mutex<BridgeRuntime?>(nil)
        let seen = Mutex<(supervised: Bool, live: Bool)?>(nil)
        let task = Mutex<String?>(nil)
        let hooks = ClaudeCodeTestHooks(beforeFinishClose: {
            guard let runtime = holder.withLock({ $0 }), let taskID = task.withLock({ $0 }) else { return }
            await runtime.refreshLiveness()
            let supervised = await runtime.supervised[taskID] != nil
            let live = await runtime.hasLiveProcess()
            seen.withLock { $0 = (supervised, live) }
        })
        let fake = try FakeClaude(hooks: hooks)
        try fake.scenario(["runs": [["steps": [["tool": "mcp__tf__ask_user", "id": "toolu_q", "input": FakeClaude.askColor]]], ["steps": [["text": "close"]]]]])
        try Self.forceInternalClose(fake)
        let h = try await harness(fake)
        holder.withLock { $0 = h.runtime }
        let created = h.message("Hi")
        task.withLock { $0 = created.taskID }
        await h.runtime.tick()
        #expect(await h.eventually(timeout: 60) {
            let alive = await h.task(created.taskID)?.alive
            return fake.report(1) != nil && alive == false
        })
        let gap = try #require(seen.withLock { $0 }, "틈에서 물었다")
        #expect(gap.supervised, "틈에서 감독을 내리지 않는다")
        #expect(gap.live, "Quit이 확인 없이 끝내지 않는다")
    }

    // MARK: 1 (Astra P1-2) 시작 중인 spawn

    /// 지킴이 시작 보고를 기다리는 턴에 세션 실행 끝내기가 왔다: 정체를 받은 뒤 stdin 전에 멈춘다(메시지 0 바이트) · 끝을 증명할 때까지 기다려 끝으로 답한다
    @Test func r1AStartingSpawnIsStoppedBeforeItsInputAndSettled() async throws {
        let go = box.root.appending(path: "go")
        let slow = box.root.appending(path: "slow-keeper")
        try "#!/bin/sh\nwhile [ ! -e '\(go.path)' ]; do /bin/sleep 0.02; done\nexec '\(try BuiltProducts.url("tf-agent-keeper").path)' \"$@\"\n"
            .write(to: slow, atomically: true, encoding: .utf8)
        #expect(chmod(slow.path, 0o755) == 0)
        let inputs = Mutex<[Int]>([])
        let fake = try FakeClaude(hooks: ClaudeCodeTestHooks(inputBytes: { count in inputs.withLock { $0.append(count) } }), keeper: slow.path)
        try fake.scenario(["runs": [["steps": [["text": "should not run with the message"]]]]])
        let lock = try #require(ClaudeSessionLock.file(sessionsRoot: fake.box.sessionsRoot, session: ClaudeTest.session))
        let events = EventLog()
        let starting = Task { try? await fake.turn(events: events) }
        #expect(await ClaudeRereview5ReproTests.waitUntil(30) { ClaudeSessionLock.read(lock) != .none })
        #expect(await fake.process.sessionRun(ClaudeTest.session)?.liveness == .alive, "시작 중인 spawn도 등록부에 있다")
        #expect(await fake.process.hasRegisteredRuns())
        let process = fake.process
        let ending = Task { await process.terminateSessionRun(ClaudeTest.session) }
        // 끝내기가 actor에 들어가 그 spawn에 `stopped`를 표시할 틈 (actor는 비어 있다: 띄우기는 actor 밖에서 지킴이를 기다린다). 밖에서 볼 수 있는 표시가 없어
        // 넉넉한 틈을 둔다 — 지킴이 시작 보고 기한(5초) 안. 놓쳤다면 아래 `inputs == [0]`이 실패로 알린다 (거짓 통과 없음)
        try await Task.sleep(for: .seconds(1))
        FileManager.default.createFile(atPath: go.path, contents: Data())
        let result = await ending.value
        _ = await starting.value
        #expect(result == .ended(AgentExit(code: nil)), "정산까지 기다렸다")
        #expect(inputs.withLock { $0 } == [0], "정체를 받은 뒤 입력을 건네지 않았다 (빈 stdin)")
        #expect((fake.report(0)?["stdin_bytes"] as? Int) ?? 0 == 0, "가짜가 읽은 입력 0")
        #expect(await process.sessionRun(ClaudeTest.session)?.liveness == .ended(AgentExit(code: nil)))
    }

    /// 따라올 내부 닫기가 정해진 뒤(끝 증명 전) 세션 실행 끝내기가 왔다: 그 닫기는 띄우지 않는다 (follow-up 취소)
    @Test func r1EndingTheSessionRunCancelsTheFollowUpClose() async throws {
        let fake = try FakeClaude()
        try fake.scenario(["runs": [["steps": [["tool": "mcp__tf__ask_user", "id": "toolu_q", "input": FakeClaude.askColor]]], ["steps": [["text": "close"]]]]])
        try Self.forceInternalClose(fake)
        let process = fake.process
        let ending = Shared<Task<AgentLiveness, Never>?>(nil)
        let events = EventLog()
        // 상태 파일에 적지 못해 내부 닫기가 정해지면 `failed`를 낸다: 그 순간 (기다리지 않고) 끝내기를 부른다
        events.before { event in
            guard case .failed = event, ending.value == nil else { return }
            ending.mutate { $0 = Task { await process.terminateSessionRun(ClaudeTest.session) } }
        }
        _ = try await fake.turn(events: events)
        #expect(await events.wait(timeout: 60) { FakeClaude.ended($0) })
        let result = await ending.value?.value
        #expect(result == .ended(AgentExit(code: nil)))
        #expect(fake.report(1) == nil, "내부 닫기 spawn 0")
    }

    // MARK: 3 (sec S8-3) 질문을 받은 쪽의 닫기

    /// 질문 사건을 받는 쪽이 그 자리에서 같은 세션의 그 요청을 닫는다: 끝을 증명한 턴이 세션 자리를 먼저 놓았으므로 자기를 기다리지 않고 바로 닫힌다
    @Test func s3AClosingInsideTheQuestionEmitDoesNotWaitOnItself() async throws {
        let fake = try FakeClaude(timing: .ci)
        try fake.scenario(["runs": [
            ["steps": [["tool": "mcp__tf__ask_user", "id": "toolu_q1", "input": FakeClaude.askColor]]],
            ["steps": [["text": "close"]]],
        ]])
        let events = EventLog()
        let outcome = Shared<(seconds: Double, closed: Bool)?>(nil)
        let process = fake.process
        let workspace = fake.workspace
        let external = Shared<String?>(nil)
        events.before { event in
            guard case .question(let question) = event else { return }
            let started = Date()
            let ref = AgentRequestRef(
                taskID: ClaudeTest.task, sessionID: ClaudeTest.session, requestID: question.providerRequestID, externalSessionID: external.value, workspaceRef: workspace
            )
            let closed = (try? await process.closeRequest(ref)) != nil
            outcome.mutate { $0 = (Date().timeIntervalSince(started), closed) }
        }
        let identity = try await fake.turn(events: events)
        external.mutate { $0 = FakeClaude.providerSession(identity) }
        #expect(await events.wait(timeout: 90) { FakeClaude.ended($0) })
        let result = try #require(outcome.value)
        // 자기를 기다리면 세션 자리가 비지 않아 닫기가 기한 뒤 실패한다(던짐, 재검토 8 red): 닫았다는 것이 자기를 기다리지 않았다는 증거다. 시간은 그 기한 안인지만 본다
        #expect(result.closed, "닫았다 (자기를 기다리지 않았다)")
        #expect(result.seconds < fake.timing.closeTimeout, "닫기 기한 안")
        #expect(fake.report(1) != nil, "닫기 spawn")
    }

    // MARK: 2 (Astra P2 · sec F5 · S8-2) 기한 하나

    func server() throws -> (HookSocketServer, String) {
        let path = box.root.appending(path: "s/hook.sock").path
        let server = HookSocketServer(path: path, peerUID: HookSocketServer.peerUID)
        try server.start()
        return (server, path)
    }

    /// 읽은 때 이미 훅 기한(− 여유)을 넘었다: 처리기를 띄우지 않고 그 자리에서 시간 초과로 정한다(등록의 `timeOut`이 답을 닫는다)
    @Test func s2AnExpiredRequestNeverStartsItsHandler() async throws {
        let (server, path) = try server()
        defer { server.stop() }
        let handled = Shared(0)
        let settled = Shared(0)
        server.register(nonce: HookSocketServerTests.nonce, HookSocketServer.Registration(agentSessionID: ClaudeTest.session, providerSessionID: "claude-1", committing: { _, commit in
            handled.mutate { $0 += 1 }
            _ = commit.commit(Self.allow)
        }, timeOut: { commit, _ in
            settled.mutate { $0 += 1 }
            return commit.timeOut()
        }))
        let line = try HookRequest(
            nonce: HookSocketServerTests.nonce, sessionID: ClaudeTest.session, providerSessionID: "claude-1", hookEvent: "PreToolUse", toolUseID: "toolu_x", toolName: "Read",
            toolInput: .object([:]), inputSHA256: "d", permissionMode: "default", cwd: "/c", deadlineNS: HookWire.monotonicNow() &+ 100_000_000
        ).encodedLine()
        let response = try await offPool { try HookResponse.decode(line: UnixSocket.exchange(path: path, request: line, deadline: Date().addingTimeInterval(HookWire.budget))) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(response.decision == .deny)
        #expect(handled.value == 0, "처리기 0")
        #expect(settled.value == 1)
    }

    /// 확정 경계에서도 기한을 본다: 기한이 지난 확정은 받지 않고 시간 초과로 정한다
    @Test func s2ACommitPastTheDeadlineIsRefused() {
        let late = HookCommit(deadlineNS: HookWire.monotonicNow() - 1)
        #expect(!late.commit(Self.allow))
        #expect(late.timeOut() == nil, "시간 초과로 정해졌다")
        let inTime = HookCommit(deadlineNS: HookWire.monotonicNow() &+ 5_000_000_000)
        #expect(inTime.commit(Self.allow))
        #expect(inTime.timeOut() == Self.allow)
    }

    /// F5 측정 (sec `budgetUnderLoad`): 훅이 기한을 정한 뒤 요청이 늦게 닿고(0.4초) 공유 GCD 풀이 막힘 일로 차 있어도, bridge가 허용하는 가장 늦은 때의 확정은 훅이 받는다 —
    /// 확정했는데 훅이 받지 못한 것(거짓 전달) 0. 기한을 넘긴 확정은 받지 않는다
    @Test func s2NoAnswerIsDeliveredThatTheHookDidNotReceiveUnderLoad() async throws {
        let (server, path) = try server()
        defer { server.stop() }
        let nonce = HookSocketServerTests.nonce
        let committed = Mutex<[String: Bool]>([:])
        let started = Mutex(0)
        let margin = HookSocketServer.hookMargin
        server.register(nonce: nonce, HookSocketServer.Registration(agentSessionID: ClaudeTest.session, providerSessionID: "claude-1", committing: { request, commit in
            started.withLock { $0 += 1 }
            // 셋째마다: 바로 확정 · bridge가 허용하는 가장 늦은 때(훅 기한 − 여유)의 5ms 앞 · 그 30ms 뒤(늦은 처리기)
            let kind = (Int(request.toolUseID.dropFirst(6)) ?? 0) % 3
            if kind != 0, let deadline = request.deadlineNS {
                let target = Double(deadline) / 1e9 - margin + (kind == 2 ? 0.03 : -0.005)
                let wait = target - Double(HookWire.monotonicNow()) / 1e9
                if wait > 0 { try? await Task.sleep(for: .milliseconds(Int(wait * 1000))) }
            }
            let ok = commit.commit(Self.allow)
            committed.withLock { $0[request.toolUseID] = ok }
        }))
        let blocked = DispatchGroup()
        for _ in 0..<16 { DispatchQueue.global(qos: .userInitiated).async(group: blocked) { Thread.sleep(forTimeInterval: 1.5) } }
        // 훅 예산 1.5초 − 늦게 닿기 0.4초: bridge 기한(훅 기한 − 0.3초)이 자기 예산(연결 + 1.2초)보다 앞이다 — 훅 기한으로 정하는 길. 바로 확정할 틈은 0.8초
        let rows = try await offPool { Self.hooks(path: path, nonce: nonce, count: 24, parallel: 6, budget: 1.5, transit: 0.4) }
        // 늦은 처리기는 훅이 돌아온 뒤에도 확정을 시도한다: 시작한 처리기가 모두 시도를 마칠 때까지 (잠깐 쉬기 대신)
        #expect(await ClaudeRereview5ReproTests.waitUntil(30) { committed.withLock { $0.count } == started.withLock { $0 } })
        let commits = committed.withLock { $0 }
        let falseDelivered = rows.filter { commits[$0.id] == true && !$0.allow }.count
        let kind = { (row: HookRow) in (Int(row.id.dropFirst(6)) ?? 0) % 3 }
        let lateDelivered = rows.filter { kind($0) == 2 && commits[$0.id] == true }.count
        #expect(rows.count == 24)
        #expect(falseDelivered == 0, "확정했는데 훅이 받지 못함: \(falseDelivered) / \(rows.count)")
        #expect(lateDelivered == 0, "기한 뒤 확정 0")
        #expect(rows.filter { kind($0) == 0 && $0.allow }.count > 0, "바로 확정한 것은 훅이 받았다 (시험 전제)")
        try await offPool { blocked.wait() }
    }

    struct HookRow: Sendable {
        var id: String
        var allow: Bool
    }

    /// 실제 훅 본체(`HookMain.run`)로 요청을 보낸다: 기한을 정한 뒤 `transit`만큼 늦게 닿게 한다
    static func hooks(path: String, nonce: String, count: Int, parallel: Int, budget: TimeInterval, transit: TimeInterval) -> [HookRow] {
        let rows = Mutex<[HookRow]>([])
        let next = Mutex(0)
        let done = DispatchSemaphore(value: 0)
        for _ in 0..<parallel {
            let thread = Thread {
                while true {
                    let index: Int = next.withLock { value in
                        defer { value += 1 }
                        return value
                    }
                    if index >= count { break }
                    let id = "toolu_\(index)"
                    let stdin = Data(#"{"hook_event_name":"PreToolUse","tool_name":"Read","tool_use_id":"\#(id)","permission_mode":"default","cwd":"/c","session_id":"claude-1","tool_input":{"file_path":"/c/x"}}"#.utf8)
                    let result = HookMain.run(arguments: ["pre-tool-use", "--socket", path, "--session", ClaudeTest.session, "--nonce", nonce], stdin: stdin, connect: { socket, line, deadline in
                        Thread.sleep(forTimeInterval: transit)
                        return try UnixSocket.exchange(path: socket, request: line, deadline: deadline)
                    }, deadline: Date().addingTimeInterval(budget))
                    let allow = String(decoding: result.stdout, as: UTF8.self).contains(#""allow""#)
                    rows.withLock { $0.append(HookRow(id: id, allow: allow)) }
                }
                done.signal()
            }
            thread.start()
        }
        for _ in 0..<parallel { done.wait() }
        return rows.withLock { $0 }
    }
}
#endif
