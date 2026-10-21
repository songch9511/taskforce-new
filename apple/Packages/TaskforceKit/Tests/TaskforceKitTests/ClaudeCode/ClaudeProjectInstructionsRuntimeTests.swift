#if os(macOS) && DEBUG
import Darwin
import Foundation
import Testing
import TaskforceAgentWire
@testable import TaskforceKit

/// 작업 폴더의 CLAUDE.md가 **띄운 `claude`의 인자**로 가는가 (가짜 `claude`가 받은 `--append-system-prompt`를 보고서에 남긴다).
/// 새 세션 · 다음 턴 · 답 resume 모두 같다. 읽을 수 없는 파일은 조용히 건너뛰고 턴은 그대로 돈다. 글 · 경로는 로그에 남지 않는다
@Suite(.serialized)
struct ClaudeProjectInstructionsRuntimeTests {
    static let marker = "PROJECT-RULE-4f9c"

    @Test func aNewTurnAndAResumedTurnBothCarryTheWorkspaceInstructions() async throws {
        let fake = try FakeClaude()
        fake.box.file("CLAUDE.md", "Always say \(Self.marker).")
        try fake.scenario(["runs": [["steps": [["text": "One"]]], ["steps": [["text": "Two"]]]]])
        let first = EventLog()
        let identity = try await fake.turn(events: first)
        #expect(await first.wait { FakeClaude.ended($0) })
        let second = EventLog()
        _ = try await fake.turn("Next", task: "7a5c0001-0000-4000-8000-000000000002", external: FakeClaude.providerSession(identity), events: second)
        #expect(await second.wait { FakeClaude.ended($0) })
        #expect(second.contains(.turnCompleted))
        #expect(fake.report(0)?["project_instructions"] as? Bool == true, "새 세션")
        #expect(fake.report(1)?["resume"] as? Bool == true && fake.report(1)?["project_instructions"] as? Bool == true, "다음 턴(resume)")
    }

    @Test func anAnswerResumeCarriesThemToo() async throws {
        let fake = try FakeClaude()
        fake.box.file(".claude/CLAUDE.md", "Always say \(Self.marker).")
        try fake.scenario(["runs": [
            ["steps": [["tool": "mcp__tf__ask_user", "id": "toolu_q1", "input": FakeClaude.askColor]]],
            ["final_text": "Blue it is."],
        ]])
        let first = EventLog()
        let identity = try await fake.turn(events: first)
        #expect(await first.wait { FakeClaude.ended($0) })
        let second = EventLog()
        _ = try await fake.answer("toolu_q1", kind: .input, value: AgentAnswerValue(answers: ["color": .one("blue")]), external: FakeClaude.providerSession(identity), events: second)
        #expect(await second.wait { FakeClaude.ended($0) })
        #expect(second.contains(.turnCompleted))
        #expect(fake.report(0)?["project_instructions"] as? Bool == true)
        #expect(fake.report(1)?["stdin_bytes"] as? Int == 0 && fake.report(1)?["project_instructions"] as? Bool == true, "답 resume")
    }

    @Test func aWorkspaceWithoutInstructionsRunsTheSameTurnWithoutThem() async throws {
        let fake = try FakeClaude()
        try fake.scenario(["runs": [["steps": [["text": "Hello"]]]]])
        let events = EventLog()
        _ = try await fake.turn(events: events)
        #expect(await events.wait { FakeClaude.ended($0) })
        #expect(events.contains(.turnCompleted))
        #expect(fake.report(0)?["project_instructions"] as? Bool == false)
        #expect(!fake.log.events.contains("claude_instructions_skipped"), "없는 파일은 로그에도 남지 않는다")
    }

    @Test func anUnreadableFileIsSkippedSilentlyAndTheTurnStillRuns() async throws {
        let fake = try FakeClaude()
        fake.box.file("secret.md", in: fake.box.outside, "OUTSIDE-\(Self.marker)")
        fake.box.link("CLAUDE.md", to: fake.box.outside.appending(path: "secret.md"))
        try fake.scenario(["runs": [["steps": [["text": "Hello"]]]]])
        let events = EventLog()
        _ = try await fake.turn(events: events)
        #expect(await events.wait { FakeClaude.ended($0) })
        #expect(events.contains(.turnCompleted))
        #expect(fake.report(0)?["project_instructions"] as? Bool == false)
        #expect(fake.log.lines.contains("claude_instructions_skipped count=count(1) why=code(\"unusable\")"), "고정 코드 하나 · 건너뛴 수만")
        for line in fake.log.lines {
            #expect(!line.contains(Self.marker) && !line.contains("CLAUDE") && !line.contains(fake.workspace) && !line.contains("secret"), "\(line)")
        }
    }

    @Test func aFullSizeFilePassesThroughTheKeeperAsOneArgumentAndTheCutIsLogged() async throws {
        let fake = try FakeClaude()
        fake.box.file("CLAUDE.md", String(repeating: "x", count: 70_000))
        fake.box.file(".claude/CLAUDE.md", "second")
        try fake.scenario(["runs": [["steps": [["text": "Hello"]]]]])
        let events = EventLog()
        _ = try await fake.turn(events: events)
        #expect(await events.wait { FakeClaude.ended($0) })
        #expect(events.contains(.turnCompleted))
        #expect(fake.report(0)?["project_instructions"] as? Bool == true)
        #expect(fake.log.lines.contains("claude_instructions bytes=count(65536) cut=count(1) files=count(1)"), "64 KiB에서 잘렸고 둘째 파일은 못 들어왔다")
    }

    @Test func theLogNeverHoldsTheFileTextTheNameOrThePath() async throws {
        let fake = try FakeClaude()
        fake.box.file("CLAUDE.md", "Always say \(Self.marker).")
        fake.box.file("secret.md", in: fake.box.outside, "OUTSIDE-\(Self.marker)")
        fake.box.link(".claude", to: fake.box.outside)
        try fake.scenario(["runs": [["steps": [["text": "Hello"]]]]])
        let events = EventLog()
        _ = try await fake.turn(events: events)
        #expect(await events.wait { FakeClaude.ended($0) })
        #expect(fake.report(0)?["project_instructions"] as? Bool == true)
        #expect(fake.log.events.contains("claude_instructions"), "읽은 수만 남긴다")
        for line in fake.log.lines {
            #expect(!line.contains(Self.marker) && !line.contains("CLAUDE") && !line.contains(fake.workspace) && !line.contains("secret"), "\(line)")
        }
        // 서버로 가는 사건에도 글이 없다
        for event in events.all {
            #expect(!"\(event)".contains(Self.marker), "\(event)")
        }
    }
}
#endif
