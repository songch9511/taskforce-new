#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

extension ExternalSessionSuites {
    /// 대화 상태가 기록의 하위 에이전트 메타(`subagents/agent-<id>.meta.json`)를 일 목록에 겹치는 규칙 (T1). 읽기는 가짜 (`ClaudeAppTranscriptScript`), 실제 기록은 열지 않는다.
    /// 본 기록의 시작 · 끝 줄이 상태를 정하고, 메타는 부모 · 깊이 · 이름을 채우고 본 기록에 없는 에이전트를 "끝 미확인(Stopped)"으로 더한다. 파일 읽기는 메인 밖에서 한다
    @MainActor
    struct ClaudeAppConversationSubagentTests {
        typealias F = ExternalSessionFixture
        typealias S = ClaudeAppTranscriptScript
        let id = F.uuid(0xF1)
        private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

        private func make(_ script: ClaudeAppTranscriptSource) -> ClaudeAppConversation {
            ClaudeAppConversation(sessionID: id, cwd: "/Users/tester/proj", source: script, turnLimit: ClaudeAppConversation.maxTurns, sleep: { _ in try? await Task.sleep(for: .milliseconds(10)) })
        }

        private func cursor(background: [BackgroundTaskEvent] = []) -> ClaudeAppTranscriptCursor {
            var cursor = ClaudeAppTranscriptCursor(sessionID: id)
            cursor.signals = ClaudeAppTranscriptSignals(failedToolIDs: [], background: background)
            return cursor
        }

        private func page(_ turns: [ClaudeAppTurn] = [S.turn(1)], background: [BackgroundTaskEvent] = []) -> ClaudeAppTranscriptLoad {
            .page(ClaudeAppTranscriptPage(turns: turns, cursor: cursor(background: background), hasEarlier: false, skippedLines: 0))
        }

        private func meta(_ task: String, parent: String? = nil, depth: Int? = 1, name: String? = "Check a note") -> SubagentMeta {
            SubagentMeta(id: task, parentID: parent, depth: depth, name: name, requestShape: nil)
        }

        private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while !condition() {
                if ContinuousClock.now > deadline { return false }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return true
        }

        private func task(_ conversation: ClaudeAppConversation, _ id: String) -> BackgroundTask? { conversation.backgroundTasks.tasks.first { $0.id == id } }

        private let stamp1 = Date(timeIntervalSince1970: 1_800_000_100)
        private let stamp2 = Date(timeIntervalSince1970: 1_800_000_200)

        @Test func metaOnlyAgentsAppearUnderTheirParentsAsUnconfirmedAndAreScannedOffTheMainThread() async {
            let script = S()
            script.queueOpen(page())
            script.queueSubagents(.metas([meta("a1", depth: 1, name: "Top"), meta("a2", parent: "a1", depth: 2, name: "Nested")], stamp: stamp1))
            let conversation = make(script)
            conversation.start()
            #expect(await eventually { conversation.backgroundTasks.tasks.count == 2 })
            #expect(task(conversation, "a2")?.parentID == "a1" && task(conversation, "a2")?.depth == 2 && task(conversation, "a2")?.name == "Nested")
            #expect(conversation.backgroundTasks.tasks.allSatisfy { $0.status == .stopped && $0.endedAt == nil && $0.kind == .agent })
            #expect(SubagentTree.rows(for: conversation.backgroundTasks, expansion: SubagentTreeExpansion()).map(\.task.id) == ["a1", "a2"])
            #expect(script.calledOnMain == false, "메타 읽기는 메인 밖에서 한다")
            conversation.stop()
        }

        @Test func anAgentTheTranscriptStartedKeepsRunningUntilItsEndNoticeAndGainsTheParentFromTheMeta() async {
            let script = S()
            let start = BackgroundTaskEvent.started(taskID: "a1", toolUseID: "tu1", kind: .agent, name: nil, at: t0.addingTimeInterval(5))
            script.queueOpen(page(background: [start]))
            script.queueSubagents(.metas([meta("a1", parent: "p0", depth: 2, name: "From the meta")], stamp: stamp1))
            script.queueNewer(.turns([], cursor: cursor(background: [.finished(taskID: "a1", kind: .agent, status: .done, exitCode: nil, at: t0.addingTimeInterval(40))]), hasMore: false))
            let conversation = make(script)
            conversation.start()
            #expect(await eventually { task(conversation, "a1")?.parentID == "p0" })
            #expect(await eventually { task(conversation, "a1")?.status == .done })
            #expect(task(conversation, "a1")?.depth == 2 && task(conversation, "a1")?.endedAt == t0.addingTimeInterval(40) && task(conversation, "a1")?.startedAt == t0.addingTimeInterval(5))
            #expect(task(conversation, "a1")?.name == "From the meta")
            conversation.stop()
        }

        @Test func theNameTheTranscriptsToolStepWroteBeatsTheMetaName() async {
            let script = S()
            let tool = ClaudeAppTurn(id: "t2", kind: .tool(name: "Agent", description: "Named by the tool step"), timestamp: nil, truncated: false, lineOffset: 100, toolUseID: "tu1")
            script.queueOpen(page([S.turn(1), tool], background: [.started(taskID: "a1", toolUseID: "tu1", kind: .agent, name: nil, at: t0)]))
            script.queueSubagents(.metas([meta("a1", name: "From the meta")], stamp: stamp1))
            let conversation = make(script)
            conversation.start()
            #expect(await eventually { task(conversation, "a1")?.name == "Named by the tool step" })
            conversation.stop()
        }

        @Test func aNewAgentThatShowsUpLaterIsFoundOnTheNextTailReadAndTheLastStampIsHandedBack() async {
            let script = S()
            script.queueOpen(page())
            script.queueSubagents(.metas([meta("a1")], stamp: stamp1), .metas([meta("a1"), meta("a2", parent: "a1", depth: 2)], stamp: stamp2))
            let conversation = make(script)
            conversation.start()
            #expect(await eventually { conversation.backgroundTasks.tasks.count == 2 })
            #expect(script.subagentSinces.first.map { $0 == nil } == true, "처음 훑기는 이전 자리가 없다")
            #expect(script.subagentSinces.dropFirst().first == .some(stamp1), "다음 훑기는 앞에서 본 폴더의 시각을 건넨다")
            conversation.stop()
        }

        @Test func anUnchangedFolderKeepsTheTasksAndAMissingOrUnreadableFolderClearsThem() async {
            let script = S()
            script.queueOpen(page())
            script.queueSubagents(.metas([meta("a1"), meta("a2")], stamp: stamp1), .unchanged, .unchanged)
            let conversation = make(script)
            conversation.start()
            #expect(await eventually { conversation.backgroundTasks.tasks.count == 2 })
            #expect(await eventually { script.subagentCalls >= 3 })
            #expect(conversation.backgroundTasks.tasks.count == 2, "그대로면 그대로")
            script.queueSubagents(.unreadable)
            #expect(await eventually { conversation.backgroundTasks.tasks.isEmpty }, "믿을 수 없게 된 폴더의 값은 남기지 않는다")
            script.queueSubagents(.metas([meta("a1")], stamp: stamp2))
            #expect(await eventually { conversation.backgroundTasks.tasks.count == 1 })
            script.queueSubagents(.missing)
            #expect(await eventually { conversation.backgroundTasks.tasks.isEmpty }, "폴더가 사라졌으면 에이전트도 없다")
            conversation.stop()
        }

        @Test func aFolderThatBecomesUnreadableAlsoForgetsTheStampSoTheNextScanReadsInFull() async {
            let script = S()
            script.queueOpen(page())
            script.queueSubagents(.metas([meta("a1")], stamp: stamp1), .unreadable, .metas([meta("a1")], stamp: stamp1))
            let conversation = make(script)
            conversation.start()
            #expect(await eventually { script.subagentCalls >= 3 })
            #expect(script.subagentSinces.prefix(3).map { $0 } == [nil, .some(stamp1), nil], "믿을 수 없던 뒤에는 이전 자리를 건네지 않는다")
            #expect(await eventually { conversation.backgroundTasks.tasks.count == 1 })
            conversation.stop()
        }

        @Test func tryAgainStartsTheAgentsOverAndForgetsTheStamp() async {
            let script = S()
            script.queueOpen(page(), page())
            script.queueSubagents(.metas([meta("a1")], stamp: stamp1))
            let conversation = make(script)
            conversation.start()
            #expect(await eventually { conversation.backgroundTasks.tasks.count == 1 })
            conversation.retry()
            // 가짜는 이제부터 "그대로"만 답한다: 예전 에이전트가 남아 있으면 지우지 않은 것이다
            #expect(await eventually { conversation.phase == .ready && conversation.backgroundTasks.tasks.isEmpty })
            #expect(await eventually { script.subagentSinces.last == .some(nil) }, "다시 읽을 때는 이전 자리 없이 통째로")
            conversation.stop()
        }

        @Test func aSessionWithoutAnyAgentFolderIsNotSearchedEverySecond() async {
            let script = S()
            script.queueOpen(page())
            script.queueSubagents(.missing)
            let conversation = make(script)
            conversation.start()
            #expect(await eventually { script.newerCalls >= 40 })
            conversation.stop()
            #expect(script.subagentCalls <= 1 + script.newerCalls / ClaudeAppConversation.missingScanEvery + 1, "없는 폴더는 몇 번에 한 번만 찾는다: \(script.subagentCalls) / \(script.newerCalls)")
            #expect(script.subagentCalls >= 3, "그래도 찾기는 계속한다")
        }

        @Test func aNewLineInTheTranscriptMakesAMissingFolderBeSearchedAtOnce() async {
            let script = S()
            script.queueOpen(page())
            script.queueSubagents(.missing)
            script.queueNewer(.turns([], cursor: cursor(), hasMore: false), .turns([S.turn(2)], cursor: cursor(), hasMore: false))
            script.queueSubagents(.metas([meta("a1")], stamp: stamp1))
            let conversation = make(script)
            conversation.start()
            #expect(await eventually { conversation.backgroundTasks.tasks.count == 1 }, "새 줄이 오자 바로 찾아 에이전트를 만났다")
            conversation.stop()
        }

        @Test func aSourceThatKnowsNothingAboutAgentsLeavesTheTaskListAsItWas() async {
            final class Plain: ClaudeAppTranscriptSource, @unchecked Sendable {
                func open(sessionID: String, cwd: String?) -> ClaudeAppTranscriptLoad { .page(ClaudeAppTranscriptPage(turns: [ClaudeAppTranscriptScript.turn(1)], cursor: ClaudeAppTranscriptCursor(sessionID: ExternalSessionFixture.uuid(0xF1)), hasEarlier: false, skippedLines: 0)) }
                func earlier(_ cursor: ClaudeAppTranscriptCursor) -> ClaudeAppTranscriptLoad { .unreadable }
                func newer(_ cursor: ClaudeAppTranscriptCursor) -> ClaudeAppTranscriptUpdate { .turns([], cursor: cursor, hasMore: false) }
            }
            let conversation = make(Plain())
            conversation.start()
            #expect(await eventually { conversation.phase == .ready })
            #expect(conversation.backgroundTasks.tasks.isEmpty)
            conversation.stop()
        }
    }
}
#endif
