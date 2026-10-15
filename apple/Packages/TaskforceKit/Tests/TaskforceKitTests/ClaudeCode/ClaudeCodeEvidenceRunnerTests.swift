#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

/// R1 실행 장치 (OA D3a 4.7): 일회용 폴더만 받고, 요약에는 사건 종류 · 결과 · 시간 · 값 종류 로그만 남는다. 여기서는 가짜 `claude`로만 돌린다
@Suite(.serialized)
struct ClaudeCodeEvidenceRunnerTests {
    func runner(_ fake: FakeClaude) throws -> ClaudeCodeEvidenceRunner {
        try ClaudeCodeEvidenceRunner(
            workspace: fake.workspace, sessionsRoot: fake.box.sessionsRoot, hookServer: fake.server,
            helpers: ClaudeCodeHelpers(hook: try BuiltProducts.url("tf-agent-hook").path, mcp: try BuiltProducts.url("tf-agent-mcp").path),
            locator: ClaudeCodeLocator(candidates: [fake.claude.path], confinedTo: fake.box.root.path), decide: fake.decider.function,
            environment: ["HOME": fake.box.home.path, "USER": NSUserName(), "PATH": "/usr/bin:/bin"]
        )
    }

    @Test func aWorkspaceWithoutTheDisposableMarkerIsRefused() throws {
        let fake = try FakeClaude()
        #expect(throws: ClaudeCodeEvidenceRunner.NotDisposable.self) { try runner(fake) }
    }

    @Test func aQuestionAndAnswerRunIsSummarisedWithoutAnyText() async throws {
        let fake = try FakeClaude()
        fake.box.file(ClaudeCodeEvidenceRunner.disposableMarker)
        try fake.scenario(["runs": [
            ["steps": [["tool": "mcp__tf__ask_user", "id": "toolu_q", "input": FakeClaude.askColor]]],
            ["final_text": "SECRET-REPLY-TEXT"],
        ]])
        let runner = try runner(fake)
        let summary = await runner.run(id: "R1-06", steps: [.turn(text: "SECRET-PROMPT-TEXT", access: .write), .answer(AgentAnswerValue(answers: ["color": .one("blue")]))])
        #expect(summary.steps.map(\.result) == ["started", "delivered"])
        #expect(summary.steps[0].events.contains("question:input"))
        #expect(summary.steps[1].events.contains("turn_completed"))
        let encoded = String(decoding: try JSONEncoder().encode(summary), as: UTF8.self)
        for text in ["SECRET-PROMPT-TEXT", "SECRET-REPLY-TEXT", "blue", fake.workspace, "Which color"] {
            #expect(!encoded.contains(text), "\(text)")
        }
        #expect(summary.log.contains { $0.hasPrefix("tool_gate ") })
    }
}
#endif
