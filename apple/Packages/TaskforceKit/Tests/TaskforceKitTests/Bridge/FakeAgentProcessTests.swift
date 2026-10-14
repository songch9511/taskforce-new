#if os(macOS) && DEBUG
import Darwin
import Foundation
import Testing
@testable import TaskforceKit

/// 가짜 agent 자체 (OA D2b 계약 2.4 · 4.1 K15): F1–F12 대본이 약속대로 움직인다
struct FakeAgentProcessTests {
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [AgentEvent] = []

        func add(_ event: AgentEvent) { lock.withLock { list.append(event) } }
        var events: [AgentEvent] { lock.withLock { list } }
        var sink: AgentEventSink { AgentEventSink { [self] event, _ in add(event) } }
    }

    private func turn(_ text: String = "hi", task: String = "t1") -> AgentTurnStart {
        AgentTurnStart(
            taskID: task, sessionID: "s1", turnSeq: 1, adapter: "agent:claude-code", externalSessionID: nil, workspaceRef: "ws", resume: false, access: .write,
            policyMode: .manual, marker: "marker-\(task)", text: text
        )
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    @Test func f1ANormalTurnEmitsTheDocumentedSequenceAndEnds() async throws {
        let agent = FakeAgentProcess(clock: .system)
        let collector = Collector()
        _ = try await agent.startTurn(turn(), events: collector.sink)
        #expect(await eventually { collector.events.count == 6 })
        #expect(collector.events == [
            .sessionBound(externalSessionID: "fake-session-1", workspaceRef: "workspace-fake"), .accepted, .progress, .message(text: "done"), .turnCompleted, .ended(AgentExit(code: 0)),
        ])
        #expect(agent.startedTurns.first?.text == "hi" && agent.startedTurns.first?.marker == "marker-t1")
    }

    @Test func f2AQuestionWaitsForTheAnswerThenFinishes() async throws {
        let agent = FakeAgentProcess(clock: .system)
        let question = AgentQuestion(providerRequestID: "r1", kind: .input, structured: true, text: "Which?", items: [AgentQuestionItem(id: "q", header: "", text: "", options: [])])
        agent.setScript(.asking(question))
        let collector = Collector()
        let identity = try await agent.startTurn(turn(), events: collector.sink)
        #expect(await eventually { collector.events.contains(.question(question)) })
        try await Task.sleep(for: .milliseconds(50))
        #expect(!collector.events.contains(.turnCompleted), "답이 오기 전에는 끝나지 않는다")
        let delivery = AgentAnswerDelivery(
            taskID: "t1", sessionID: "s1", turnSeq: 1, adapter: "agent:claude-code", externalSessionID: nil, workspaceRef: nil, marker: "marker-t1", access: .write, policyMode: .manual,
            requestID: "r1", kind: .input, structured: true, value: AgentAnswerValue(answers: ["q": .one("a")])
        )
        let result = try await agent.deliverAnswer(delivery, events: collector.sink)
        #expect(result == .delivered(identity))
        #expect(await eventually { collector.events.last == .ended(AgentExit(code: 0)) })
        #expect(agent.deliveredAnswers.first?.value.answers == ["q": .one("a")])
    }

    @Test func f3APreAcceptanceFailureNeverAccepts() async throws {
        let agent = FakeAgentProcess(clock: .system)
        agent.setScript(.failsBeforeAcceptance(.signInNeeded))
        let collector = Collector()
        _ = try await agent.startTurn(turn(), events: collector.sink)
        #expect(await eventually { collector.events.count == 2 })
        #expect(collector.events == [.failed(.signInNeeded), .ended(AgentExit(code: 1))])
    }

    @Test func f4DyingMidTurnEndsWithoutATerminalEvent() async throws {
        let agent = FakeAgentProcess(clock: .system)
        agent.setScript(.diesMidTurn())
        let collector = Collector()
        _ = try await agent.startTurn(turn(), events: collector.sink)
        #expect(await eventually { collector.events.last == .ended(AgentExit(code: nil, signal: 9)) })
        #expect(!collector.events.contains(.turnCompleted) && !collector.events.contains(.failed(nil)))
    }

    @Test func f5ASlowStartWaitsOnTheInjectedClock() async throws {
        let clock = ManualBridgeClock()
        let agent = FakeAgentProcess(clock: clock.clock)
        agent.setScript(.slowStart(400))
        let collector = Collector()
        _ = try await agent.startTurn(turn(), events: collector.sink)
        #expect(await eventually { clock.sleeperCount == 1 })
        #expect(collector.events.isEmpty)
        await clock.advance(by: 399)
        #expect(collector.events.isEmpty)
        await clock.advance(by: 2)
        #expect(await eventually { collector.events.contains(.accepted) })
    }

    @Test func f6AnInterruptEndsTheRunOrIsIgnoredForAWhile() async throws {
        let clock = ManualBridgeClock()
        let agent = FakeAgentProcess(clock: clock.clock)
        agent.setScript(.staysRunning())
        let collector = Collector()
        let identity = try await agent.startTurn(turn(), events: collector.sink)
        #expect(await eventually { collector.events.contains(.progress) })
        let ref = AgentTurnRef(taskID: "t1", sessionID: "s1", identity: identity)
        #expect(await agent.interrupt(ref, scope: .turnAndProcesses) == .signalled)
        #expect(await eventually { collector.events.last == .ended(AgentExit(code: nil, signal: 2)) })
        #expect(await agent.interrupt(ref, scope: .turn) == .notRunning)
        // 중단을 무시하는 모드
        let slow = FakeAgentProcess(clock: clock.clock)
        slow.setScript(.staysRunning())
        slow.setIgnoreInterrupt(for: 30)
        let second = Collector()
        let secondIdentity = try await slow.startTurn(turn(task: "t2"), events: second.sink)
        #expect(await eventually { second.events.contains(.progress) })
        #expect(await slow.interrupt(AgentTurnRef(taskID: "t2", sessionID: "s1", identity: secondIdentity), scope: .turn) == .signalled)
        #expect(!second.events.contains { if case .ended = $0 { true } else { false } }, "신호를 받고도 계속 돈다")
        #expect(await eventually { clock.sleeperCount >= 2 }, "대본 대기 + 중단 무시 대기")
        await clock.advance(by: 31)
        #expect(await eventually { second.events.last == .ended(AgentExit(code: nil, signal: 2)) })
    }

    /// AgentProcess 규칙 (검토 반영 2 8장 2): 작업 폴더 없이는 띄우지도 닫지도 않는다
    @Test func startingOrClosingWithoutAWorkspaceThrowsSpawnFailed() async throws {
        let agent = FakeAgentProcess(clock: .system)
        var noFolder = turn()
        noFolder.workspaceRef = nil
        await #expect(throws: AgentStartError(.spawnFailed)) { _ = try await agent.startTurn(noFolder, events: Collector().sink) }
        #expect(agent.liveRunCount == 0, "띄우지 않았다")
        await #expect(throws: AgentStartError(.spawnFailed)) {
            try await agent.closeRequest(AgentRequestRef(taskID: "t1", sessionID: "s1", requestID: "r1", externalSessionID: "ext", workspaceRef: nil))
        }
        let delivery = AgentAnswerDelivery(
            taskID: "t1", sessionID: "s1", turnSeq: 1, adapter: "agent:claude-code", externalSessionID: nil, workspaceRef: "ws", marker: "m", access: .write, policyMode: .manual,
            requestID: "r1", kind: .input, structured: false, value: AgentAnswerValue(text: "x")
        )
        #expect(try await agent.deliverAnswer(delivery, events: Collector().sink) != .requestClosed, "닫지 못했으므로 닫힌 요청으로 기록하지 않는다")
    }

    @Test func f7AndF8AClosedRequestIsRecordedAndAnAnswerToItIsReportedClosed() async throws {
        let agent = FakeAgentProcess(clock: .system)
        try await agent.closeRequest(AgentRequestRef(taskID: "t1", sessionID: "s1", requestID: "r9", externalSessionID: nil, workspaceRef: "ws"))
        #expect(agent.closedRequests.map(\.requestID) == ["r9"])
        let delivery = AgentAnswerDelivery(
            taskID: "t1", sessionID: "s1", turnSeq: 1, adapter: "agent:claude-code", externalSessionID: nil, workspaceRef: nil, marker: "m", access: .write, policyMode: .manual,
            requestID: "r9", kind: .input, structured: false, value: AgentAnswerValue(text: "x")
        )
        #expect(try await agent.deliverAnswer(delivery, events: Collector().sink) == .requestClosed)
        #expect(agent.deliveredAnswers.isEmpty)
    }

    @Test func f9ABurstEmitsAHundredFiftyOrMoreEvents() async throws {
        let agent = FakeAgentProcess(clock: .system)
        agent.setScript(.burst(count: 150))
        let collector = Collector()
        _ = try await agent.startTurn(turn(), events: collector.sink)
        #expect(await eventually { collector.events.count >= 153 })
        #expect(collector.events.filter { $0 == .progress }.count == 150)
    }

    @Test func f10ASubprocessIsARealProcessWithAPidAndStartTimeThatSurvivesTheRuntimeAndCanBeEnded() async throws {
        let agent = FakeAgentProcess(clock: .system)
        agent.setSubprocess(true)
        agent.setScript(.staysRunning())
        defer { agent.killEverything() }
        let identity = try await agent.startTurn(turn(), events: Collector().sink)
        let pid = try #require(identity.pid)
        #expect(FakeAgentProcess.processExists(pid: pid, startedAt: identity.startedAt))
        #expect(!FakeAgentProcess.processExists(pid: pid, startedAt: identity.startedAt.addingTimeInterval(-60)), "pid 재사용은 시작 시각으로 가른다")
        let orphans = agent.abandon()
        #expect(orphans.map(\.pid) == [pid])
        #expect(FakeAgentProcess.processExists(pid: pid, startedAt: identity.startedAt), "버려도 프로세스는 산다 (고아)")
        let restarted = FakeAgentProcess(clock: .system)
        #expect(await restarted.liveness(identity) == .alive)
        #expect(await restarted.terminateOrphan(identity) == .ended(AgentExit(code: nil, signal: 15)))
        #expect(!FakeAgentProcess.processExists(pid: pid, startedAt: identity.startedAt))
        #expect(await restarted.liveness(identity) == .ended(AgentExit(code: nil)))
    }

    @Test func f11TheProbeReportCanBeChanged() async throws {
        let agent = FakeAgentProcess(clock: .system)
        #expect(await agent.probe() == BridgeV1AdapterReport(adapter: "agent:claude-code", installed: true, version: "2.1.241", signedIn: .yes, managedSettings: false))
        agent.setReport { $0.installed = false; $0.version = nil }
        #expect(await agent.probe().installed == false)
        agent.setVersionSupport { $0 == "2.1.241" }
        #expect(agent.supportsVersion("2.1.241") && !agent.supportsVersion("3.0.0"))
    }

    @Test func f12TheReadbackModeIsConfigurable() async throws {
        let agent = FakeAgentProcess(clock: .system)
        let session = AgentSessionRef(sessionID: "s1", externalSessionID: nil, workspaceRef: nil)
        #expect(await agent.readback(marker: "m", session: session) == .unsupported)
        for mode in [AgentReadback.received, .notReceived(processEnded: true), .unknown] {
            agent.setReadback(mode)
            #expect(await agent.readback(marker: "m", session: session) == mode)
        }
    }

    @Test func aStartErrorThrowsBeforeAnythingRuns() async throws {
        let agent = FakeAgentProcess(clock: .system)
        agent.setStartError(AgentStartError(.spawnFailed))
        await #expect(throws: AgentStartError.self) { _ = try await agent.startTurn(turn(), events: Collector().sink) }
        #expect(agent.liveRunCount == 0)
    }
}
#endif
