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

    @Test func forgettingASessionClearsItsTasksFromTheBoard() async throws {
        let fake = try FakeClaude()
        fake.board.apply(.started(taskID: "t9", toolUseID: nil, kind: .command, name: "x", at: Date()), session: ClaudeTest.session)
        #expect(fake.board.tasks(session: ClaudeTest.session).tasks.count == 1)
        await fake.process.forgetSession(ClaudeTest.session)
        #expect(await ClaudeReviewProcessTests.waitUntil { fake.board.tasks(session: ClaudeTest.session).tasks.isEmpty }, "세션을 잊으면 그 세션의 일 목록도 비운다")
    }
}
#endif
