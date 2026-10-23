#if os(macOS) && DEBUG
import Darwin
import Foundation
import Testing
import TaskforceAgentWire
@testable import TaskforceKit

/// 어댑터가 읽은 `task_*` 줄이 이 Mac의 판(`BackgroundTaskBoard`)에 닿고, 서버로 가는 사건은 늘지 않는다 (DZ v2 · Taskforce 패널). 가짜 `claude`가 돌고 있는 명령(`sleep`)을 흉내 낸다
@Suite(.serialized)
struct ClaudeBackgroundTaskProcessTests {
    @Test func aRunningCommandLandsOnTheBoardAndAStopEndsItAsStoppedWithNothingNewForTheServer() async throws {
        let fake = try FakeClaude()
        fake.allowReadonlyCat("notes.md")
        try fake.scenario(["runs": [["steps": [["tool": "Bash", "id": "toolu_b", "input": ["command": "cat notes.md"], "sleep": 30]]]]])
        let events = EventLog()
        let identity = try await fake.turn(events: events)
        #expect(await ClaudeReviewProcessTests.waitUntil { fake.board.tasks(session: ClaudeTest.session).tasks.first?.status == .running })
        let running = try #require(fake.board.tasks(session: ClaudeTest.session).tasks.first)
        #expect(running.id == "t1" && running.kind == .command && running.toolUseID == "toolu_b" && running.name == nil, "이름은 모델이 쓴 글만: 없으면 비워 둔다")
        let result = await fake.process.interrupt(AgentTurnRef(taskID: ClaudeTest.task, sessionID: ClaudeTest.session, identity: identity), scope: .turnAndProcesses)
        #expect(result == .signalled)
        #expect(await events.wait { FakeClaude.ended($0) })
        let stopped = try #require(fake.board.tasks(session: ClaudeTest.session).tasks.first)
        #expect(stopped.status == .stopped && stopped.exitCode == nil)
        #expect(events.contains(.cancelled), "서버로 가는 사건은 지금과 같다")
    }

    /// 리뷰 P1: 일이 도는 채로 spawn이 끝나면(여기서는 SIGINT를 듣지 않는 CLI가 끝내진다: 끝 알림이 없다) 그 일은 영영 Running으로 남았다.
    /// spawn이 거둬질 때 그 세션의 아직 도는 일은 그 시각에 멈춘 것이다 (끝을 증명한 뒤 · `ended` 사건 전에)
    @Test func aTaskStillRunningWhenTheProcessIsReapedIsStoppedAtThatMoment() async throws {
        let fake = try FakeClaude()
        fake.allowReadonlyCat("notes.md")
        try fake.scenario(["runs": [["ignore_sigint": true, "steps": [["tool": "Bash", "id": "toolu_b", "input": ["command": "cat notes.md"], "sleep": 30]]]]])
        let events = EventLog()
        let identity = try await fake.turn(events: events)
        #expect(await ClaudeReviewProcessTests.waitUntil { fake.board.tasks(session: ClaudeTest.session).tasks.first?.status == .running })
        let before = Date()
        let result = await fake.process.interrupt(AgentTurnRef(taskID: ClaudeTest.task, sessionID: ClaudeTest.session, identity: identity), scope: .turnAndProcesses)
        #expect(result == .signalled)
        #expect(await events.wait(timeout: 60) { FakeClaude.ended($0) })
        let tasks = fake.board.tasks(session: ClaudeTest.session)
        let task = try #require(tasks.tasks.first)
        #expect(tasks.runningCount == 0 && task.status == .stopped && task.exitCode == nil, "끝난 spawn의 일은 도는 일이 아니다")
        let end = try #require(task.endedAt, "끝 시각이 있어야 막 끝난 일 규칙이 선다")
        #expect(end >= before && end <= Date(), "거둬진 시각")
    }

    /// 재검토: 거둬지는 spawn이 **시작한** 일만 멈춘다. 같은 세션 판에 이 spawn이 시작하지 않은 도는 일(앞 spawn · 다른 원천)이 있으면 그대로 둔다
    @Test func reapingASpawnStopsOnlyTheTasksThatSpawnStarted() async throws {
        let fake = try FakeClaude()
        fake.allowReadonlyCat("notes.md")
        let earlier = Date().addingTimeInterval(-60)
        fake.board.apply(.started(taskID: "earlier-bk", toolUseID: nil, kind: .command, name: "Started before this spawn", at: earlier), session: ClaudeTest.session)
        try fake.scenario(["runs": [["ignore_sigint": true, "steps": [["tool": "Bash", "id": "toolu_b", "input": ["command": "cat notes.md"], "sleep": 30]]]]])
        let events = EventLog()
        let identity = try await fake.turn(events: events)
        #expect(await ClaudeReviewProcessTests.waitUntil { fake.board.tasks(session: ClaudeTest.session).tasks.contains { $0.id == "t1" && $0.status == .running } })
        let result = await fake.process.interrupt(AgentTurnRef(taskID: ClaudeTest.task, sessionID: ClaudeTest.session, identity: identity), scope: .turnAndProcesses)
        #expect(result == .signalled)
        #expect(await events.wait(timeout: 60) { FakeClaude.ended($0) })
        let tasks = fake.board.tasks(session: ClaudeTest.session).tasks
        #expect(tasks.first { $0.id == "t1" }?.status == .stopped, "이 spawn이 시작한 일은 멈춘다")
        let other = try #require(tasks.first { $0.id == "earlier-bk" })
        #expect(other.status == .running && other.endedAt == nil, "이 spawn이 시작하지 않은 일은 건드리지 않는다")
    }

    @Test func forgettingASessionClearsItsTasksFromTheBoard() async throws {
        let fake = try FakeClaude()
        fake.board.apply(.started(taskID: "t9", toolUseID: nil, kind: .command, name: "x", at: Date()), session: ClaudeTest.session)
        #expect(fake.board.tasks(session: ClaudeTest.session).tasks.count == 1)
        await fake.process.forgetSession(ClaudeTest.session)
        #expect(await ClaudeReviewProcessTests.waitUntil { fake.board.tasks(session: ClaudeTest.session).tasks.isEmpty }, "세션을 잊으면 그 세션의 일 목록도 비운다")
    }
}
#endif
