#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

/// 세션 보기 V1이 대화 상태에 더하는 것: 실패 표시 붙이기 · 펼친 도구의 본문 · 백그라운드 일 목록 (DZ v2). 읽기는 가짜 (`ClaudeAppTranscriptScript`), 실제 기록은 열지 않는다
extension ExternalSessionSuites {
    @MainActor
    struct ClaudeAppConversationStepsTests {
        typealias F = ExternalSessionFixture
        typealias S = ClaudeAppTranscriptScript
        let id = F.uuid(0xF1)
        private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

        private func make(_ script: ClaudeAppTranscriptSource, limit: Int = ClaudeAppConversation.maxTurns) -> ClaudeAppConversation {
            ClaudeAppConversation(sessionID: id, cwd: "/Users/tester/proj", source: script, turnLimit: limit, sleep: { _ in try? await Task.sleep(for: .milliseconds(10)) })
        }

        private func tool(_ n: Int, toolID: String, name: String = "Bash", description: String? = nil) -> ClaudeAppTurn {
            ClaudeAppTurn(id: "t\(n)", kind: .tool(name: name, description: description), timestamp: nil, truncated: false, lineOffset: Int64(n * 100), toolUseID: toolID)
        }

        private func cursor(failed: [String] = [], background: [BackgroundTaskEvent] = []) -> ClaudeAppTranscriptCursor {
            var cursor = ClaudeAppTranscriptCursor(sessionID: id)
            cursor.signals = ClaudeAppTranscriptSignals(failedToolIDs: failed, background: background)
            return cursor
        }

        private func page(_ turns: [ClaudeAppTurn], earlier: Bool = false, failed: [String] = [], background: [BackgroundTaskEvent] = []) -> ClaudeAppTranscriptLoad {
            .page(ClaudeAppTranscriptPage(turns: turns, cursor: cursor(failed: failed, background: background), hasEarlier: earlier, skippedLines: 0))
        }

        private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while !condition() {
                if ContinuousClock.now > deadline { return false }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return true
        }

        // MARK: 실패 표시

        @Test func aFailedResultMarksItsToolTurnAndOnlyThat() async {
            let script = S()
            script.queueOpen(page([S.turn(1), tool(2, toolID: "a"), tool(3, toolID: "b")], failed: ["a"]))
            let conversation = make(script)
            conversation.start()
            #expect(await eventually { conversation.phase == .ready })
            #expect(conversation.turns.map(\.failed) == [false, true, false])
            conversation.stop()
        }

        @Test func aFailureThatArrivesInALaterTailReadMarksAnAlreadyShownTool() async {
            let script = S()
            script.queueOpen(page([S.turn(1), tool(2, toolID: "a")]))
            script.queueNewer(.turns([], cursor: cursor(failed: ["a"]), hasMore: false))
            let conversation = make(script)
            conversation.start()
            #expect(await eventually { conversation.turns.last?.failed == true })
            conversation.stop()
        }

        @Test func aFailureKnownBeforeItsToolIsLoadedMarksTheToolWhenAnEarlierPageBringsIt() async {
            let script = S()
            script.queueOpen(page([S.turn(5), tool(6, toolID: "late")], earlier: true, failed: ["old"]))
            script.queueEarlier(page([tool(1, toolID: "old"), S.turn(2)]))
            let conversation = make(script)
            conversation.start()
            #expect(await eventually { conversation.phase == .ready })
            conversation.showEarlier()
            #expect(await eventually { conversation.turns.count == 4 })
            #expect(conversation.turns.first { $0.id == "t1" }?.failed == true)
            #expect(conversation.turns.first { $0.id == "t6" }?.failed == false)
            conversation.stop()
        }

        @Test func tryAgainForgetsTheFailuresOfTheOldReading() async {
            let script = S()
            script.queueOpen(page([tool(1, toolID: "a")], failed: ["a"]), page([tool(1, toolID: "a")]))
            let conversation = make(script)
            conversation.start()
            #expect(await eventually { conversation.turns.first?.failed == true })
            conversation.retry()
            #expect(await eventually { conversation.phase == .ready })
            #expect(conversation.turns.first?.failed == false, "다시 읽은 기록에 실패가 없으면 표시도 없다")
            conversation.stop()
        }

        @Test func theRememberedFailuresAreBounded() async {
            let script = S()
            let ids = (0..<(ClaudeAppConversation.maxRememberedFailures + 500)).map { "f\($0)" }
            script.queueOpen(page([S.turn(1)], failed: ids))
            let conversation = make(script)
            conversation.start()
            #expect(await eventually { conversation.phase == .ready })
            #expect(conversation.rememberedFailureCount <= ClaudeAppConversation.maxRememberedFailures)
            conversation.stop()
        }

        // MARK: 펼친 도구의 본문

        private final class DetailSource: ClaudeAppTranscriptSource, @unchecked Sendable {
            private let lock = NSLock()
            private var _calledOnMain = false
            private var _asked: [String] = []
            let answer: ClaudeAppToolDetail?
            let turns: [ClaudeAppTurn]

            init(turns: [ClaudeAppTurn], answer: ClaudeAppToolDetail?) {
                self.turns = turns
                self.answer = answer
            }

            var calledOnMain: Bool { lock.withLock { _calledOnMain } }
            var asked: [String] { lock.withLock { _asked } }

            func open(sessionID: String, cwd: String?) -> ClaudeAppTranscriptLoad {
                .page(ClaudeAppTranscriptPage(turns: turns, cursor: ClaudeAppTranscriptCursor(sessionID: sessionID), hasEarlier: false, skippedLines: 0))
            }

            func earlier(_ cursor: ClaudeAppTranscriptCursor) -> ClaudeAppTranscriptLoad { .unreadable }
            func newer(_ cursor: ClaudeAppTranscriptCursor) -> ClaudeAppTranscriptUpdate { .turns([], cursor: cursor, hasMore: false) }

            func detail(of turn: ClaudeAppTurn, cursor: ClaudeAppTranscriptCursor) -> ClaudeAppToolDetail? {
                lock.withLock {
                    if Thread.isMainThread { _calledOnMain = true }
                    _asked.append(turn.id)
                }
                return answer
            }
        }

        @Test func expandingAToolReadsItsBodyOffTheMainThreadThroughTheSource() async {
            let source = DetailSource(turns: [S.turn(1), tool(2, toolID: "a")], answer: ClaudeAppToolDetail(input: "{ }", result: "ok", truncated: false))
            let conversation = make(source)
            conversation.start()
            #expect(await eventually { conversation.phase == .ready })
            let found = await conversation.detail(of: conversation.turns[1])
            #expect(found == ClaudeAppToolDetail(input: "{ }", result: "ok", truncated: false))
            #expect(source.asked == ["t2"] && !source.calledOnMain)
            conversation.stop()
        }

        @Test func aTurnThatIsNotAToolOrAConversationNotReadYetHasNoBody() async {
            let source = DetailSource(turns: [S.turn(1)], answer: ClaudeAppToolDetail(input: "x", result: nil, truncated: false))
            let conversation = make(source)
            #expect(await conversation.detail(of: tool(2, toolID: "a")) == nil, "아직 읽지 않았다")
            conversation.start()
            #expect(await eventually { conversation.phase == .ready })
            #expect(await conversation.detail(of: conversation.turns[0]) == nil, "도구 줄이 아니다")
            #expect(source.asked.isEmpty)
            conversation.stop()
        }

        @Test func aSourceThatDoesNotKnowHowToExpandAnswersNothing() async {
            let script = S()
            script.queueOpen(page([tool(1, toolID: "a")]))
            let conversation = make(script)
            conversation.start()
            #expect(await eventually { conversation.phase == .ready })
            #expect(await conversation.detail(of: conversation.turns[0]) == nil)
            conversation.stop()
        }

        // MARK: 백그라운드 일

        private func started(_ task: String, tool: String?, kind: BackgroundTaskKind = .command, _ seconds: TimeInterval = 5) -> BackgroundTaskEvent {
            .started(taskID: task, toolUseID: tool, kind: kind, name: nil, at: t0.addingTimeInterval(seconds))
        }

        private func finished(_ task: String, _ status: BackgroundTaskStatus, code: Int?, kind: BackgroundTaskKind? = .command, _ seconds: TimeInterval = 65) -> BackgroundTaskEvent {
            .finished(taskID: task, kind: kind, status: status, exitCode: code, at: t0.addingTimeInterval(seconds))
        }

        @Test func aStartAndAnEndBuildTheTaskListAndTheNameComesFromTheToolStep() async {
            let script = S()
            script.queueOpen(page([S.turn(1), tool(2, toolID: "tu1", description: "Run the dev server")], background: [started("bk1", tool: "tu1")]))
            script.queueNewer(.turns([], cursor: cursor(background: [finished("bk1", .done, code: 0)]), hasMore: false))
            let conversation = make(script)
            conversation.start()
            #expect(await eventually { conversation.backgroundTasks.tasks.first?.status == .done })
            let task = conversation.backgroundTasks.tasks[0]
            #expect(task.id == "bk1" && task.name == "Run the dev server" && task.exitCode == 0 && task.duration == 60)
            conversation.stop()
        }

        @Test func aTaskWhoseToolStepIsInAnEarlierPageGetsItsNameWhenThatPageIsRead() async {
            let script = S()
            script.queueOpen(page([S.turn(5)], earlier: true, background: [started("bk1", tool: "tu1")]))
            script.queueEarlier(page([tool(1, toolID: "tu1", description: "Watch the unit tests")]))
            let conversation = make(script)
            conversation.start()
            #expect(await eventually { conversation.backgroundTasks.tasks.count == 1 })
            #expect(conversation.backgroundTasks.tasks[0].name == nil && conversation.backgroundTasks.tasks[0].title == "Bash")
            conversation.showEarlier()
            #expect(await eventually { conversation.backgroundTasks.tasks.first?.name == "Watch the unit tests" })
            conversation.stop()
        }

        @Test func aToolStepWithoutADescriptionLeavesTheTaskNameEmptySoTheToolNameShows() async {
            let script = S()
            script.queueOpen(page([tool(1, toolID: "tu1")], background: [started("bk1", tool: "tu1")]))
            let conversation = make(script)
            conversation.start()
            #expect(await eventually { conversation.backgroundTasks.tasks.count == 1 })
            #expect(conversation.backgroundTasks.tasks[0].name == nil && conversation.backgroundTasks.tasks[0].title == "Bash")
            conversation.stop()
        }

        @Test func theSameEventsReadAgainByAnEarlierWindowDoNotDuplicateTasks() async {
            let script = S()
            let events = [started("bk1", tool: "tu1"), finished("bk1", .failed, code: 3)]
            script.queueOpen(page([S.turn(5)], earlier: true, background: events))
            script.queueEarlier(page([S.turn(1)], background: events))
            let conversation = make(script)
            conversation.start()
            #expect(await eventually { conversation.phase == .ready })
            conversation.showEarlier()
            #expect(await eventually { conversation.turns.count == 2 })
            #expect(conversation.backgroundTasks.tasks.count == 1 && conversation.backgroundTasks.tasks[0].status == .failed && conversation.backgroundTasks.tasks[0].exitCode == 3)
            conversation.stop()
        }

        @Test func tryAgainStartsTheTaskListOver() async {
            let script = S()
            script.queueOpen(page([S.turn(1)], background: [started("bk1", tool: nil)]), page([S.turn(1)]))
            let conversation = make(script)
            conversation.start()
            #expect(await eventually { conversation.backgroundTasks.tasks.count == 1 })
            conversation.retry()
            #expect(await eventually { conversation.phase == .ready })
            #expect(conversation.backgroundTasks.tasks.isEmpty)
            conversation.stop()
        }

        @Test func aResetOfTheTranscriptRebuildsTheTaskListFromTheNewWindow() async {
            let script = S()
            script.queueOpen(page([S.turn(1)], background: [started("bk1", tool: nil)]), page([S.turn(1)], background: [started("bk2", tool: nil)]))
            script.queueNewer(.reset)
            let conversation = make(script)
            conversation.start()
            #expect(await eventually { conversation.backgroundTasks.tasks.map(\.id) == ["bk2"] })
            conversation.stop()
        }

        @Test func theNamesAreKeptWhenTheOldTurnsAreTrimmedAwayAtTheMemoryLimit() async {
            let script = S()
            script.queueOpen(page([tool(1, toolID: "tu1", description: "Run the dev server")], background: [started("bk1", tool: "tu1")]))
            script.queueNewer(.turns([S.turn(2), S.turn(3), S.turn(4)], cursor: cursor(), hasMore: false))
            let conversation = make(script, limit: 2)
            conversation.start()
            #expect(await eventually { conversation.turns.count == 2 })
            #expect(conversation.backgroundTasks.tasks.first?.name == "Run the dev server", "이름은 일이 처음 보였을 때 정해진다: 줄이 버려져도 남는다")
            conversation.stop()
        }

        @Test func theValuesNeverPrintIdsOrNames() async {
            let script = S()
            script.queueOpen(page([tool(1, toolID: "secret-tool", description: "A private name")], background: [started("secret-task", tool: "secret-tool")]))
            let conversation = make(script)
            conversation.start()
            #expect(await eventually { conversation.backgroundTasks.tasks.count == 1 })
            let text = String(describing: conversation) + String(reflecting: conversation) + String(describing: conversation.backgroundTasks) + String(reflecting: conversation.turns[0])
            #expect(!text.contains("secret-tool") && !text.contains("secret-task") && !text.contains("A private name"))
            conversation.stop()
        }
    }
}
#endif
