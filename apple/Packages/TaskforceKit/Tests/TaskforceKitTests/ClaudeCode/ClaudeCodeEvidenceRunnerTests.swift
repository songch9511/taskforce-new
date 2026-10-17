#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

/// R1 실행 장치 (OA D3a 4.7): 일회용 폴더만 받고, 요약에는 사건 종류 · 결과 · 시간 · 값 종류 로그만 남는다. 여기서는 가짜 `claude`로만 돌린다
@Suite(.serialized)
struct ClaudeCodeEvidenceRunnerTests {
    /// 단계마다 끝을 기다리는 상한 (실제 실행은 600초): 실패해도 그 안에 끝나고 아래 진단을 남긴다 (18장)
    static let stepTimeout: TimeInterval = 45

    func runner(_ fake: FakeClaude) throws -> ClaudeCodeEvidenceRunner {
        try ClaudeCodeEvidenceRunner(
            workspace: fake.workspace, sessionsRoot: fake.box.sessionsRoot, hookServer: fake.server,
            helpers: fake.helpers,
            locator: ClaudeCodeLocator(candidates: [fake.claude.path], confinedTo: fake.box.root.path), decide: fake.decider.function,
            environment: ["HOME": fake.box.home.path, "USER": NSUserName(), "PATH": "/usr/bin:/bin"], timing: fake.timing, stepTimeout: Self.stepTimeout
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
        // 단계가 끝(`ended`)을 내지 않았으면 기다린 상한과 값 종류 로그(글 0)를 남긴다: 어디서 멈췄는지 바로 보인다
        for (index, step) in summary.steps.enumerated() where !step.events.contains(where: { $0.hasPrefix("ended:") }) {
            Issue.record("단계 \(index) (\(step.kind) · \(step.result))가 \(Self.stepTimeout)초 안에 끝나지 않았다: 사건 \(step.events), 로그 \(summary.log)")
        }
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
