#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

/// R1 실행 장치 (OA D3a 4.7): 일회용 폴더만 받고, 요약에는 사건 종류 · 결과 · 시간 · 값 종류 로그만 남는다. 여기서는 가짜 `claude`로만 돌린다
@Suite(.serialized)
struct ClaudeCodeEvidenceRunnerTests {
    /// 단계마다 끝을 기다리는 상한 (실제 실행은 600초): 실패해도 그 안에 끝나고 아래 진단을 남긴다 (18장)
    static let stepTimeout: TimeInterval = 45

    func runner(_ fake: FakeClaude, workspace: String? = nil, helpers: ClaudeCodeHelpers? = nil) throws -> ClaudeCodeEvidenceRunner {
        try ClaudeCodeEvidenceRunner(
            workspace: workspace ?? fake.workspace, sessionsRoot: fake.box.sessionsRoot, hookServer: fake.server,
            helpers: helpers ?? fake.helpers,
            locator: ClaudeCodeLocator(candidates: [fake.claude.path], confinedTo: fake.box.root.path), decide: fake.decider.function,
            environment: ["HOME": fake.box.home.path, "USER": NSUserName(), "PATH": "/usr/bin:/bin"], timing: fake.timing, stepTimeout: Self.stepTimeout
        )
    }

    @Test func aWorkspaceWithoutTheDisposableMarkerIsRefused() throws {
        let fake = try FakeClaude()
        #expect(throws: ClaudeCodeEvidenceRunner.NotDisposable.self) { try runner(fake) }
    }

    /// R1-01 실패의 원인: 지킴이 helper가 `~/Documents` 안에 있었다. 지킴이는 disclaim으로 자기 책임 프로세스라 macOS가 그 이름으로 폴더 접근을 묻고(TCC 확인 창),
    /// 답이 올 때까지 막혀 첫 보고가 기한(5초)을 넘긴다 → `spawn_failed`. 보호 폴더 안 helper · 작업 폴더는 실제 실행 전에 거절한다
    @Test func helpersOrAWorkspaceInAProtectedFolderAreRefusedBeforeAnyRealRun() throws {
        let fake = try FakeClaude()
        fake.box.file(ClaudeCodeEvidenceRunner.disposableMarker)
        for folder in ["Documents", "Desktop", "Downloads", "Library/Mobile Documents", "Documents/Life Design/helpers"] {
            let keeper = fake.box.file("\(folder)/tf-agent-keeper", in: fake.box.home)
            let moved = ClaudeCodeHelpers(hook: fake.helpers.hook, mcp: fake.helpers.mcp, keeper: keeper.path)
            #expect(throws: ClaudeCodeEvidenceRunner.ProtectedFolder.self, "\(folder)") { try runner(fake, helpers: moved) }
            let hook = ClaudeCodeHelpers(hook: keeper.path, mcp: fake.helpers.mcp, keeper: fake.helpers.keeper)
            #expect(throws: ClaudeCodeEvidenceRunner.ProtectedFolder.self, "\(folder) hook") { try runner(fake, helpers: hook) }
        }
        let marker = fake.box.file(ClaudeCodeEvidenceRunner.disposableMarker, in: fake.box.home.appending(path: "Documents/proj"))
        #expect(throws: ClaudeCodeEvidenceRunner.ProtectedFolder.self) { try runner(fake, workspace: marker.deletingLastPathComponent().path) }
        // 보호 폴더가 아닌 이름 (접두어만 같다) · 홈 밖은 거절하지 않는다
        let near = fake.box.file("Documents-old/tf-agent-keeper", in: fake.box.home)
        _ = try runner(fake, helpers: ClaudeCodeHelpers(hook: fake.helpers.hook, mcp: fake.helpers.mcp, keeper: near.path))
        _ = try runner(fake)
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
