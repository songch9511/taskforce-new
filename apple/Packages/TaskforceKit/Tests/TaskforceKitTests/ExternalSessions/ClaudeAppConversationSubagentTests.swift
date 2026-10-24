#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

extension ExternalSessionSuites {
    /// 대화 상태가 기록의 하위 에이전트 메타(`subagents/agent-<id>.meta.json`)를 일 목록에 겹치는 규칙 (T1, 검토 뒤 계약 5장). 읽기는 가짜 (`ClaudeAppTranscriptScript`), 실제 기록은 열지 않는다.
    /// 본 기록의 시작 · 끝 줄이 백그라운드 에이전트의 상태를 정하고, 깊이 1 전경 에이전트의 상태는 메타의 `toolUseId`와 같은 id의 도구 호출 · 결과로 정한다 (결과 전 Running, 결과 뒤 Done/Failed).
    /// 상태를 모르는 에이전트는 부모가 목록에 있을 때만 상태 없이 보인다. 파일 읽기는 메인 밖에서 한다
    @MainActor
    struct ClaudeAppConversationSubagentTests {
        typealias F = ExternalSessionFixture
        typealias S = ClaudeAppTranscriptScript
        let id = F.uuid(0xF1)
        private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

        private func make(_ script: ClaudeAppTranscriptSource) -> ClaudeAppConversation {
            ClaudeAppConversation(sessionID: id, cwd: "/Users/tester/proj", source: script, turnLimit: ClaudeAppConversation.maxTurns, sleep: { _ in try? await Task.sleep(for: .milliseconds(10)) })
        }

        private func cursor(background: [BackgroundTaskEvent] = [], outcomes: [ClaudeAppToolOutcome] = []) -> ClaudeAppTranscriptCursor {
            var cursor = ClaudeAppTranscriptCursor(sessionID: id)
            cursor.signals = ClaudeAppTranscriptSignals(failedToolIDs: [], background: background, toolOutcomes: outcomes)
            return cursor
        }

        private func page(_ turns: [ClaudeAppTurn] = [S.turn(1)], background: [BackgroundTaskEvent] = [], outcomes: [ClaudeAppToolOutcome] = []) -> ClaudeAppTranscriptLoad {
            .page(ClaudeAppTranscriptPage(turns: turns, cursor: cursor(background: background, outcomes: outcomes), hasEarlier: false, skippedLines: 0))
        }

        /// 에이전트를 부른 도구 줄 (본 기록의 `tool_use`)
        private func agentCall(_ toolID: String, name: String = "Agent", at seconds: TimeInterval = 5) -> ClaudeAppTurn {
            ClaudeAppTurn(id: "call-\(toolID)", kind: .tool(name: name, description: "Review the copy"), timestamp: t0.addingTimeInterval(seconds), truncated: false, lineOffset: 100, toolUseID: toolID)
        }

        private func meta(_ task: String, parent: String? = nil, depth: Int? = 1, name: String? = "Check a note", tool: String? = nil) -> SubagentMeta {
            SubagentMeta(id: task, parentID: parent, depth: depth, name: name, requestShape: nil, toolUseID: tool)
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

        private let cursor1 = SubagentCursor(project: "-Users-tester-proj", stamp: Date(timeIntervalSince1970: 1_800_000_100))
        private let cursor2 = SubagentCursor(project: "-Users-tester-proj", stamp: Date(timeIntervalSince1970: 1_800_000_200))

        // MARK: 깊이 1 전경 에이전트: 본 기록의 짝

        @Test func aForegroundAgentRunsFromItsCallUntilItsResultAndThenIsDoneAtTheResultLinesTime() async {
            let script = S()
            script.queueOpen(page([S.turn(1), agentCall("tu1", at: 5)]))
            script.queueSubagents(.metas([meta("a1", depth: 1, name: "Review the copy", tool: "tu1")], cursor: cursor1))
            script.queueNewer(.turns([], cursor: cursor(outcomes: [ClaudeAppToolOutcome(toolUseID: "tu1", failed: false, at: t0.addingTimeInterval(40))]), hasMore: false))
            let conversation = make(script)
            conversation.start()
            #expect(await eventually { task(conversation, "a1") != nil }, "결과 전에는 호출 줄을 본 에이전트가 도는 중으로 보인다")
            #expect(await eventually { task(conversation, "a1")?.status == .done })
            let found = task(conversation, "a1")
            #expect(found?.startedAt == t0.addingTimeInterval(5) && found?.endedAt == t0.addingTimeInterval(40) && found?.foreground == true && found?.depth == 1 && found?.parentID == nil)
            conversation.stop()
        }

        @Test func aFailedResultMakesItFailedAndATaskCallIsAlsoACall() async {
            let script = S()
            script.queueOpen(page([S.turn(1), agentCall("tu1", name: "Task", at: 5)], outcomes: [ClaudeAppToolOutcome(toolUseID: "tu1", failed: true, at: t0.addingTimeInterval(20))]))
            script.queueSubagents(.metas([meta("a1", tool: "tu1")], cursor: cursor1))
            let conversation = make(script)
            conversation.start()
            #expect(await eventually { task(conversation, "a1")?.status == .failed })
            #expect(task(conversation, "a1")?.endedAt == t0.addingTimeInterval(20) && task(conversation, "a1")?.startedAt == t0.addingTimeInterval(5))
            conversation.stop()
        }

        @Test func aCallNeverSeenMakesNoLineSoAnOldSessionWithManyFinishedAgentsShowsNothing() async {
            let script = S()
            script.queueOpen(page([S.turn(1), agentCall("someone-else")]))
            script.queueSubagents(.metas((0..<30).map { meta("old\($0)", depth: 1, tool: "tu-old\($0)") }, cursor: cursor1))
            let conversation = make(script)
            conversation.start()
            #expect(await eventually { script.subagentCalls >= 2 })
            #expect(conversation.backgroundTasks.tasks.isEmpty, "호출 · 결과를 못 본 에이전트는 도는 중도 끝남도 아니다: 줄이 없다")
            conversation.stop()
        }

        @Test func aResultWhoseCallLineIsOutsideTheWindowThatWasReadStillEndsTheAgent() async {
            let script = S()
            // 처음 읽은 창에는 결과만 있다 (호출 줄은 창 앞): 결과가 있으니 끝난 에이전트다, 시작 시각만 모른다
            script.queueOpen(page([S.turn(5)], outcomes: [ClaudeAppToolOutcome(toolUseID: "tu1", failed: false, at: t0.addingTimeInterval(40))]))
            script.queueSubagents(.metas([meta("a1", tool: "tu1")], cursor: cursor1))
            let conversation = make(script)
            conversation.start()
            #expect(await eventually { task(conversation, "a1")?.status == .done })
            #expect(task(conversation, "a1")?.startedAt == nil)
            conversation.stop()
        }

        @Test func aNestedChildHangsUnderItsForegroundParentWithoutAStatusWord() async {
            let script = S()
            script.queueOpen(page([S.turn(1), agentCall("tu1", at: 5)]))
            script.queueSubagents(.metas([meta("n1", parent: "a1", depth: 2, name: "Nested"), meta("a1", depth: 1, name: "Parent", tool: "tu1")], cursor: cursor1))
            let conversation = make(script)
            conversation.start()
            #expect(await eventually { conversation.backgroundTasks.tasks.count == 2 })
            #expect(task(conversation, "a1")?.status == .running)
            let nested = task(conversation, "n1")
            #expect(nested?.statusUnknown == true && nested?.parentID == "a1" && nested?.meta(now: t0) == "Agent")
            #expect(SubagentTree.rows(for: conversation.backgroundTasks, expansion: SubagentTreeExpansion()).map(\.task.id) == ["a1", "n1"])
            conversation.stop()
        }

        @Test func aChildOfAParentThatIsNotOnTheListHasNoLine() async {
            let script = S()
            script.queueOpen(page())
            script.queueSubagents(.metas([meta("n1", parent: "ghost", depth: 2)], cursor: cursor1))
            let conversation = make(script)
            conversation.start()
            #expect(await eventually { script.subagentCalls >= 2 })
            #expect(conversation.backgroundTasks.tasks.isEmpty)
            conversation.stop()
        }

        // MARK: 본 기록이 아는 백그라운드 에이전트

        @Test func anAgentTheTranscriptStartedKeepsRunningUntilItsEndNoticeAndGainsTheParentFromTheMeta() async {
            let script = S()
            let start = BackgroundTaskEvent.started(taskID: "a1", toolUseID: "tu1", kind: .agent, name: nil, at: t0.addingTimeInterval(5))
            script.queueOpen(page(background: [start]))
            script.queueSubagents(.metas([meta("a1", parent: "p0", depth: 2, name: "From the meta")], cursor: cursor1))
            script.queueNewer(.turns([], cursor: cursor(background: [.finished(taskID: "a1", kind: .agent, status: .done, exitCode: nil, at: t0.addingTimeInterval(40))]), hasMore: false))
            let conversation = make(script)
            conversation.start()
            #expect(await eventually { task(conversation, "a1")?.parentID == "p0" })
            #expect(await eventually { task(conversation, "a1")?.status == .done })
            #expect(task(conversation, "a1")?.depth == 2 && task(conversation, "a1")?.endedAt == t0.addingTimeInterval(40) && task(conversation, "a1")?.startedAt == t0.addingTimeInterval(5))
            #expect(task(conversation, "a1")?.name == "From the meta")
            conversation.stop()
        }

        @Test func anAsyncLaunchResultIsNotAnEndSoABackgroundAgentWithAResultLineStaysRunning() async {
            let script = S()
            // 본 기록: 호출 줄 + 비동기 시작 줄(이 줄은 끝 사실로 나오지 않는다 = outcomes 비어 있음) → 끝 알림 전까지 Running
            let start = BackgroundTaskEvent.started(taskID: "a1", toolUseID: "tu1", kind: .agent, name: nil, at: t0.addingTimeInterval(6))
            script.queueOpen(page([S.turn(1), agentCall("tu1", at: 5)], background: [start], outcomes: []))
            script.queueSubagents(.metas([meta("a1", depth: 1, tool: "tu1")], cursor: cursor1))
            let conversation = make(script)
            conversation.start()
            #expect(await eventually { script.subagentCalls >= 2 })
            #expect(task(conversation, "a1")?.status == .running && conversation.backgroundTasks.tasks.count == 1)
            conversation.stop()
        }

        @Test func theNameTheTranscriptsToolStepWroteBeatsTheMetaName() async {
            let script = S()
            let tool = ClaudeAppTurn(id: "t2", kind: .tool(name: "Agent", description: "Named by the tool step"), timestamp: nil, truncated: false, lineOffset: 100, toolUseID: "tu1")
            script.queueOpen(page([S.turn(1), tool], background: [.started(taskID: "a1", toolUseID: "tu1", kind: .agent, name: nil, at: t0)]))
            script.queueSubagents(.metas([meta("a1", name: "From the meta")], cursor: cursor1))
            let conversation = make(script)
            conversation.start()
            #expect(await eventually { task(conversation, "a1")?.name == "Named by the tool step" })
            conversation.stop()
        }

        // MARK: 훑기

        @Test func aNewAgentThatShowsUpLaterIsFoundOnTheNextTailReadAndTheLastCursorIsHandedBack() async {
            let script = S()
            script.queueOpen(page([S.turn(1), agentCall("tu1", at: 5), agentCall("tu2", at: 6)]))
            script.queueSubagents(.metas([meta("a1", tool: "tu1")], cursor: cursor1), .metas([meta("a1", tool: "tu1"), meta("a2", tool: "tu2")], cursor: cursor2))
            let conversation = make(script)
            conversation.start()
            #expect(await eventually { conversation.backgroundTasks.tasks.count == 2 })
            #expect(script.subagentSinces.first.map { $0 == nil } == true, "처음 훑기는 이전 자리가 없다")
            #expect(script.subagentSinces.dropFirst().first == .some(cursor1), "다음 훑기는 앞에서 본 자리를 건넨다")
            conversation.stop()
        }

        @Test func anUnchangedFolderKeepsTheTasksAndAMissingOrUnreadableFolderClearsThem() async {
            let script = S()
            script.queueOpen(page([S.turn(1), agentCall("tu1", at: 5), agentCall("tu2", at: 6)]))
            script.queueSubagents(.metas([meta("a1", tool: "tu1"), meta("a2", tool: "tu2")], cursor: cursor1), .unchanged, .unchanged)
            let conversation = make(script)
            conversation.start()
            #expect(await eventually { conversation.backgroundTasks.tasks.count == 2 })
            #expect(await eventually { script.subagentCalls >= 3 })
            #expect(conversation.backgroundTasks.tasks.count == 2, "그대로면 그대로")
            script.queueSubagents(.unreadable)
            #expect(await eventually { conversation.backgroundTasks.tasks.isEmpty }, "믿을 수 없게 된 폴더의 값은 남기지 않는다")
            script.queueSubagents(.metas([meta("a1", tool: "tu1")], cursor: cursor2))
            #expect(await eventually { conversation.backgroundTasks.tasks.count == 1 })
            script.queueSubagents(.missing)
            #expect(await eventually { conversation.backgroundTasks.tasks.isEmpty }, "폴더가 사라졌으면 에이전트도 없다")
            conversation.stop()
        }

        @Test func aFolderThatBecomesUnreadableAlsoForgetsTheCursorSoTheNextScanReadsInFull() async {
            let script = S()
            script.queueOpen(page([S.turn(1), agentCall("tu1", at: 5)]))
            script.queueSubagents(.metas([meta("a1", tool: "tu1")], cursor: cursor1), .unreadable, .metas([meta("a1", tool: "tu1")], cursor: cursor1))
            let conversation = make(script)
            conversation.start()
            #expect(await eventually { script.subagentCalls >= 3 })
            #expect(script.subagentSinces.prefix(3).map { $0 } == [nil, .some(cursor1), nil], "믿을 수 없던 뒤에는 이전 자리를 건네지 않는다")
            #expect(await eventually { conversation.backgroundTasks.tasks.count == 1 })
            conversation.stop()
        }

        @Test func tryAgainStartsTheAgentsOverAndForgetsTheCursor() async {
            let script = S()
            script.queueOpen(page([S.turn(1), agentCall("tu1", at: 5)]), page())
            script.queueSubagents(.metas([meta("a1", tool: "tu1")], cursor: cursor1))
            let conversation = make(script)
            conversation.start()
            #expect(await eventually { conversation.backgroundTasks.tasks.count == 1 })
            conversation.retry()
            // 가짜는 이제부터 "그대로"만 답한다: 예전 에이전트가 남아 있으면 지우지 않은 것이다
            #expect(await eventually { conversation.phase == .ready && conversation.backgroundTasks.tasks.isEmpty })
            #expect(await eventually { script.subagentSinces.last == .some(nil) }, "다시 읽을 때는 이전 자리 없이 통째로")
            conversation.stop()
        }

        @Test func metaReadingIsDoneOffTheMainThread() async {
            let script = S()
            script.queueOpen(page())
            script.queueSubagents(.metas([], cursor: cursor1))
            let conversation = make(script)
            conversation.start()
            #expect(await eventually { script.subagentCalls >= 2 })
            #expect(script.calledOnMain == false, "메타 읽기는 메인 밖에서 한다")
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
            script.queueOpen(page([S.turn(1), agentCall("tu1", at: 5)]))
            script.queueSubagents(.missing)
            script.queueNewer(.turns([], cursor: cursor(), hasMore: false), .turns([S.turn(2)], cursor: cursor(), hasMore: false))
            script.queueSubagents(.metas([meta("a1", tool: "tu1")], cursor: cursor1))
            let conversation = make(script)
            conversation.start()
            #expect(await eventually { conversation.backgroundTasks.tasks.count == 1 }, "새 줄이 오자 바로 찾아 에이전트를 만났다")
            conversation.stop()
        }

        // MARK: 장부 (T1 후속 1번): Agent가 아닌 도구의 실패는 Agent 호출 장부를 밀어내지 못한다

        /// 오류로 끝난 결과는 어떤 도구의 것이든 신호로 온다 (`failedToolIDs` · `toolOutcomes`). 호출 줄을 Agent로 본 id의 결과만 장부에 적어야 2048칸 장부에서 진짜 Agent 호출이 밀리지 않는다
        @Test func manyFailedResultsOfOtherToolsNeverPushARealAgentCallOutOfTheLedger() async {
            let script = S()
            script.queueOpen(page([S.turn(1), agentCall("tuA", at: 5)]))
            script.queueSubagents(.metas([meta("a1", tool: "tuA")], cursor: cursor1))
            let count = ClaudeAppConversation.maxRememberedAgentCalls + 200
            let ids = (0..<count).map { "bash\($0)" }
            var failed = cursor()
            failed.signals = ClaudeAppTranscriptSignals(failedToolIDs: ids, background: [], toolOutcomes: ids.map { ClaudeAppToolOutcome(toolUseID: $0, failed: true, at: t0.addingTimeInterval(10)) })
            script.queueNewer(.turns([], cursor: failed, hasMore: false))
            let conversation = make(script)
            conversation.start()
            #expect(await eventually { task(conversation, "a1")?.status == .running }, "호출 줄을 본 에이전트가 도는 중으로 보인다")
            #expect(await eventually { conversation.rememberedFailureCount > 0 }, "Agent가 아닌 도구의 실패 결과가 들어왔다")
            #expect(task(conversation, "a1")?.status == .running, "도구 실패가 많이 와도 Agent 호출은 장부에 남아 있다")
            conversation.stop()
        }

        /// 호출 줄이 읽은 창 밖(앞 쪽)에 있는 에이전트의 실패 결과가 먼저 온 경우: 지금처럼 실패한 에이전트로 보이고(시작 시각만 모른다), 앞 쪽 기록을 읽어 호출 줄이 들어오면 시작 시각이 채워진다 (결과 시각 그대로). 따로 둔 실패가 이 길을 잃지 않는다
        @Test func aFailedResultThatCameBeforeItsCallLineFailsTheAgentOnceTheCallLineIsRead() async {
            let script = S()
            let first = ClaudeAppTranscriptPage(turns: [S.turn(5)], cursor: cursor(outcomes: [ClaudeAppToolOutcome(toolUseID: "tuA", failed: true, at: t0.addingTimeInterval(20))]), hasEarlier: true, skippedLines: 0)
            script.queueOpen(.page(first))
            script.queueSubagents(.metas([meta("a1", tool: "tuA")], cursor: cursor1))
            script.queueEarlier(.page(ClaudeAppTranscriptPage(turns: [agentCall("tuA", at: 5)], cursor: cursor(), hasEarlier: false, skippedLines: 0)))
            let conversation = make(script)
            conversation.start()
            #expect(await eventually { conversation.phase == .ready && script.subagentCalls >= 1 })
            #expect(await eventually { task(conversation, "a1")?.status == .failed }, "호출 줄이 창 밖이어도 실패한 결과는 그 에이전트의 실패다 (지금까지와 같다)")
            #expect(task(conversation, "a1")?.startedAt == nil, "시작 시각은 호출 줄을 읽어야 안다")
            conversation.showEarlier()
            #expect(await eventually { task(conversation, "a1")?.startedAt == t0.addingTimeInterval(5) })
            let found = task(conversation, "a1")
            #expect(found?.startedAt == t0.addingTimeInterval(5) && found?.endedAt == t0.addingTimeInterval(20))
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
