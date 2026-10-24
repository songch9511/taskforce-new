#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

/// 프로젝트 화면이 세션 행을 펼칠 때 하는 **한 번 읽기** (에이전트 트리 T3m): 본 기록 하나 + 하위 에이전트 메타 훑기 하나로 일 목록을 만든다. 꼬리를 따라가지 않는다.
/// 규칙은 옆줄이 쓰는 `ClaudeAppConversation`과 같아야 하므로 같은 입력에서 같은 목록이 나오는지 직접 대조한다 (갈라지면 빨강)
@MainActor
struct ProjectSessionsTreeTests {
    typealias S = ClaudeAppTranscriptScript
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let id = ExternalSessionFixture.uuid(0xF1)
    private let folder = SubagentCursor(project: "-Users-tester-proj", stamp: Date(timeIntervalSince1970: 1_800_000_100))

    private func tool(_ toolID: String, name: String = "Agent", description: String? = "Review the copy", at seconds: TimeInterval = 5) -> ClaudeAppTurn {
        ClaudeAppTurn(id: "call-\(toolID)", kind: .tool(name: name, description: description), timestamp: t0.addingTimeInterval(seconds), truncated: false, lineOffset: 100, toolUseID: toolID)
    }

    private func meta(_ task: String, parent: String? = nil, depth: Int? = 1, name: String? = "Check a note", tool: String? = nil) -> SubagentMeta {
        SubagentMeta(id: task, parentID: parent, depth: depth, name: name, requestShape: nil, toolUseID: tool)
    }

    private func cursor(background: [BackgroundTaskEvent] = [], outcomes: [ClaudeAppToolOutcome] = []) -> ClaudeAppTranscriptCursor {
        var cursor = ClaudeAppTranscriptCursor(sessionID: id)
        cursor.signals = ClaudeAppTranscriptSignals(failedToolIDs: outcomes.filter(\.failed).map(\.toolUseID), background: background, toolOutcomes: outcomes)
        return cursor
    }

    private func load(_ turns: [ClaudeAppTurn], background: [BackgroundTaskEvent] = [], outcomes: [ClaudeAppToolOutcome] = []) -> ClaudeAppTranscriptLoad {
        .page(ClaudeAppTranscriptPage(turns: turns, cursor: cursor(background: background, outcomes: outcomes), hasEarlier: false, skippedLines: 0))
    }

    /// 두 길(옆줄의 대화 상태 · 한 번 읽기)이 같은 답을 받게 같은 대본을 두 벌 만든다
    private func scripted(_ build: (S) -> Void) -> (S, S) {
        let a = S(), b = S()
        build(a)
        build(b)
        return (a, b)
    }

    @Test func oneReadMakesTheTreeFromTheTranscriptAndTheMetaFolderWithoutFollowingTheTail() {
        let script = S()
        script.queueOpen(load([S.turn(1), tool("tu1", at: 5)], outcomes: [ClaudeAppToolOutcome(toolUseID: "tu1", failed: false, at: t0.addingTimeInterval(40))]))
        script.queueSubagents(.metas([meta("n1", parent: "a1", depth: 2, name: "Nested"), meta("a1", name: "Review the copy", tool: "tu1")], cursor: folder))
        let tasks = ProjectSessionsTree.read(source: script, sessionID: "claude-1", cwd: "/Users/tester/proj")
        #expect(tasks?.tasks.map(\.id).sorted() == ["a1", "n1"])
        #expect(tasks?.tasks.first { $0.id == "a1" }?.status == .done && tasks?.tasks.first { $0.id == "n1" }?.statusUnknown == true)
        #expect(script.openCalls == 1 && script.subagentCalls == 1 && script.newerCalls == 0 && script.earlierCalls == 0, "본 기록 한 번 · 메타 한 번, 꼬리 · 앞 쪽은 읽지 않는다")
        #expect(script.subagentSinces.count == 1 && script.subagentSinces[0] == nil, "처음 읽기: 앞서 본 폴더 시각 없이 전부 훑는다")
    }

    @Test func aTranscriptThatCannotBeOpenedGivesNothing() {
        let script = S()
        #expect(ProjectSessionsTree.read(source: script, sessionID: "x", cwd: nil) == nil)
        #expect(script.subagentCalls == 0, "본 기록을 못 열었으면 메타도 훑지 않는다")
    }

    @Test func aMissingOrUntrustedMetaFolderLeavesJustWhatTheTranscriptKnows() {
        let start = BackgroundTaskEvent.started(taskID: "bg1", toolUseID: nil, kind: .agent, name: "Background research", at: t0)
        for listing in [SubagentListing.missing, .unreadable] {
            let script = S()
            script.queueOpen(load([S.turn(1)], background: [start]))
            script.queueSubagents(listing)
            let tasks = ProjectSessionsTree.read(source: script, sessionID: "x", cwd: nil)
            #expect(tasks?.tasks.map(\.id) == ["bg1"])
        }
    }

    @Test func theNameTheToolStepWroteIsUsedForABackgroundAgent() {
        let script = S()
        script.queueOpen(load(
            [S.turn(1), tool("tuBG", description: "Background research")],
            background: [.started(taskID: "bg1", toolUseID: "tuBG", kind: .agent, name: nil, at: t0)]
        ))
        script.queueSubagents(.missing)
        #expect(ProjectSessionsTree.read(source: script, sessionID: "x", cwd: nil)?.tasks.first?.name == "Background research")
    }

    // MARK: 옆줄의 규칙과 같다

    @Test func theOneShotReadGivesTheSameListAsTheSidePanesConversationState() async {
        func build(_ script: S) {
            let outcomes = [
                ClaudeAppToolOutcome(toolUseID: "tu1", failed: false, at: t0.addingTimeInterval(40)),
                ClaudeAppToolOutcome(toolUseID: "tu2", failed: true, at: t0.addingTimeInterval(50)),
                ClaudeAppToolOutcome(toolUseID: "tuB", failed: true, at: t0.addingTimeInterval(60)),
                ClaudeAppToolOutcome(toolUseID: "tuX", failed: false, at: t0.addingTimeInterval(70)),
                ClaudeAppToolOutcome(toolUseID: "tuY", failed: true, at: t0.addingTimeInterval(80)),
            ]
            let background = [BackgroundTaskEvent.started(taskID: "bg1", toolUseID: "tuBG", kind: .agent, name: nil, at: t0.addingTimeInterval(8))]
            script.queueOpen(load(
                [S.turn(1), tool("tu1", at: 5), tool("tu2", name: "Task", at: 6), tool("tuB", name: "Bash", description: "Run the build", at: 7), tool("tuBG", description: "Background research", at: 8), tool("tu3", at: 9)],
                background: background, outcomes: outcomes
            ))
            script.queueSubagents(.metas([
                meta("m1", tool: "tu1"), meta("m2", tool: "tu2"), meta("m3", tool: "tu3"), meta("mX", tool: "tuX"), meta("mY", tool: "tuY"), meta("mZ", tool: "never-seen"),
                meta("n1", parent: "m1", depth: 2, name: "Nested"), meta("n2", parent: "bg1", depth: 2, name: "Under the background one"), meta("lost", parent: "ghost", depth: 2),
            ], cursor: folder))
        }
        let (forConversation, forReader) = scripted(build)
        let conversation = ClaudeAppConversation(sessionID: id, cwd: "/Users/tester/proj", source: forConversation, sleep: { _ in try? await Task.sleep(for: .milliseconds(10)) })
        conversation.start()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while forConversation.subagentCalls < 1 || conversation.backgroundTasks.tasks.isEmpty, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        try? await Task.sleep(for: .milliseconds(30))
        conversation.stop()
        let expected = conversation.backgroundTasks
        #expect(expected.tasks.count >= 6, "대조할 만큼 풍부한 입력이다")
        #expect(ProjectSessionsTree.read(source: forReader, sessionID: id, cwd: "/Users/tester/proj") == expected, "옆줄과 같은 규칙: 같은 입력에서 같은 목록")
    }
}
#endif
