import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Taskforce
@testable import TaskforceKit
@testable import TaskforceUI

/// 클립보드를 대신하는 가짜 (실제 클립보드를 건드리지 않는다)
final class RecordingPasteboard: SessionPasteboarding, @unchecked Sendable {
    private let lock = NSLock()
    private var _copies: [String] = []
    var copies: [String] { lock.withLock { _copies } }
    func copy(_ text: String) { lock.withLock { _copies.append(text) } }
}

/// 세션 보기 V1의 Mac 쪽 (DZ oa-session-view-dz v2): 복사 · 안전한 마크다운 그리기 · 단계 상태 · 옆줄(자리 · 모델 · 꼬리) · 두 세션 패널의 창 틀.
/// 이 Mac의 실제 Claude 기록 · 임시 폴더 · 클립보드 · 서버를 읽거나 쓰지 않는다 (가짜 읽기 · 가짜 클립보드 · 메모리 저장소)
@MainActor
struct SessionViewMacTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    /// 시계를 손으로 가르치는 도구: 잠들기를 풀어 줄 때까지 기다린다
    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private var _sleeps = 0
        var sleeps: Int { lock.withLock { _sleeps } }

        func sleep(_ seconds: TimeInterval) async {
            // 세는 것과 줄 서는 것을 한 번에: 센 뒤에 푸는 쪽이 이 잠들기를 놓치지 않는다
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.withLock {
                    _sleeps += 1
                    waiting.append(continuation)
                }
            }
        }

        /// 가장 먼저 잠든 하나만 깨운다
        func releaseOldest() {
            let first = lock.withLock { () -> CheckedContinuation<Void, Never>? in waiting.isEmpty ? nil : waiting.removeFirst() }
            first?.resume()
        }

        func release() {
            let current = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                defer { waiting = [] }
                return waiting
            }
            current.forEach { $0.resume() }
        }
    }

    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    // MARK: 복사 (E4 · E5)

    @Test func copyWritesTheRawTextAndShowsCopiedUntilTheTimerEnds() async {
        let gate = Gate()
        let feedback = SessionCopyFeedback(sleep: { await gate.sleep($0) })
        let pasteboard = RecordingPasteboard()
        let raw = "Both **cards** say `3 days`:\n\n```json\n{ \"days\": 3 }\n```"
        feedback.copy(raw, to: pasteboard)
        #expect(pasteboard.copies == [raw], "보이는 모양이 아니라 마크다운 원문")
        #expect(feedback.copied)
        #expect(await eventually { gate.sleeps == 1 })
        gate.release()
        #expect(await eventually { !feedback.copied }, "정해진 시간 뒤에 돌아온다")
        #expect(SessionCopyFeedback.duration == 1.5)
    }

    @Test func copyingAgainRestartsTheFeedbackAndEmptyTextCopiesNothing() async {
        let gate = Gate()
        let feedback = SessionCopyFeedback(sleep: { await gate.sleep($0) })
        let pasteboard = RecordingPasteboard()
        feedback.copy("one", to: pasteboard)
        #expect(await eventually { gate.sleeps == 1 })
        feedback.copy("two", to: pasteboard)
        #expect(pasteboard.copies == ["one", "two"] && feedback.copied)
        #expect(await eventually { gate.sleeps == 2 })
        gate.releaseOldest()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(feedback.copied, "첫 복사의 시간이 끝나도 두 번째 복사의 피드백은 그대로다 (다시 시작했다)")
        gate.release()
        #expect(await eventually { !feedback.copied })
        let before = pasteboard.copies.count
        feedback.copy("", to: pasteboard)
        #expect(pasteboard.copies.count == before && !feedback.copied, "빈 글로 클립보드를 지우지 않는다")
    }

    @Test func theCopyIconIsAlwaysThereInACodeBlockAndOnlyRevealedUnderAnAnswer() {
        typealias B = SessionCopyButton
        #expect(B.isVisible(alwaysVisible: true, revealed: false, focused: false, copied: false), "코드 블록은 늘 보인다")
        #expect(!B.isVisible(alwaysVisible: false, revealed: false, focused: false, copied: false), "답 밑은 평상시 숨는다")
        #expect(B.isVisible(alwaysVisible: false, revealed: true, focused: false, copied: false), "답 위에 마우스")
        #expect(B.isVisible(alwaysVisible: false, revealed: false, focused: true, copied: false), "키보드 포커스")
        #expect(B.isVisible(alwaysVisible: false, revealed: false, focused: false, copied: true), "복사 직후")
    }

    // MARK: 안전한 마크다운 (E1)

    @Test func renderedTextNeverHasALinkWhateverTheSourceSays() {
        let hostile = "[x](javascript:alert(1)) ![y](file:///etc/passwd) <a href=\"https://x\">z</a> https://a.b `c` **b** mailto:a@b.c [**bold** `code`](https://example.com)"
        for block in SafeMarkdown.parse(hostile) {
            guard case .paragraph(let inlines) = block else { continue }
            let attributed = SessionMarkdownRender.attributed(inlines)
            #expect(attributed.runs.allSatisfy { $0.link == nil }, "링크 속성을 만들 길이 없다")
            #expect(String(attributed.characters).contains("javascript:alert(1)"), "글자로는 그대로 남는다")
        }
    }

    @Test func inlineCodeAndBoldKeepTheirOwnLooksAndPlainTextKeepsNone() {
        let inlines: [SafeMarkdown.Inline] = [.text("plain "), .code("code"), .text(" "), .bold([.text("bold")])]
        let attributed = SessionMarkdownRender.attributed(inlines)
        let runs = Array(attributed.runs)
        #expect(runs.count == 4)
        #expect(runs[0].font == nil && runs[0].backgroundColor == nil)
        #expect(runs[1].font != nil && runs[1].backgroundColor != nil, "인라인 코드: mono + 필드 바탕")
        #expect(runs[3].font != nil && runs[3].backgroundColor == nil, "굵게: 굵은 글꼴만")
        let heading = SessionMarkdownRender.attributed([.text("Lifetime")], bold: true)
        #expect(heading.runs.allSatisfy { $0.font != nil }, "제목은 굵기만 바뀐다")
    }

    @Test func listMarkersAreADotOrTheNumberWrittenByTheAuthor() {
        let bullet = SafeMarkdown.ListItem(depth: 0, number: nil, inlines: [])
        let numbered = SafeMarkdown.ListItem(depth: 0, number: 7, inlines: [])
        #expect(SessionMarkdownRender.marker(bullet, ordered: false, position: 1) == "•")
        #expect(SessionMarkdownRender.marker(numbered, ordered: true, position: 1) == "7.")
        #expect(SessionMarkdownRender.marker(bullet, ordered: true, position: 3) == "3.")
    }

    @Test func aLongCodeBlockFoldsOnlyWhenTheBodyIsTallerThanTenLines() {
        #expect(!SessionCodeBlockView.isLong(naturalHeight: 0))
        #expect(!SessionCodeBlockView.isLong(naturalHeight: SessionCodeBlockView.collapsedHeight))
        #expect(SessionCodeBlockView.isLong(naturalHeight: SessionCodeBlockView.collapsedHeight + 2))
        #expect(SessionCodeBlockView.collapsedHeight == 180 && SessionCodeBlockView.fadeHeight == 36)
    }

    // MARK: 단계 상태 (E3 · E4)

    private func run(_ id: String, steps: Int, live: Bool = false) -> SessionStepRun {
        SessionStepRun(id: id, stepIDs: (0..<steps).map { "\(id)-\($0)" }, label: "Read · Grep", isGroup: steps >= SessionTimeline.groupThreshold, isLive: live)
    }

    @Test func aGroupIsOpenWhileItsTurnRunsAndFoldsAfterwardsUnlessTheUserChose() {
        let state = SessionStepsState()
        let live = run("g", steps: 5, live: true)
        #expect(state.isOpen(live))
        let finished = run("g", steps: 5, live: false)
        #expect(!state.isOpen(finished), "끝나면 접힌다")
        state.toggle(finished)
        #expect(state.isOpen(finished) && state.isOpen(live))
        state.toggle(live)
        #expect(!state.isOpen(live) && !state.isOpen(finished), "사용자가 닫은 것은 도는 중에도 닫힌 채다")
    }

    @Test func anOpenGroupShowsTheLastSixStepsAndShowAllRevealsTheRest() {
        let state = SessionStepsState()
        let big = run("g", steps: 61)
        #expect(state.visibleSteps(big) == Array(big.stepIDs.suffix(6)) && state.hidesSteps(big))
        state.toggleShowAll(big)
        #expect(state.visibleSteps(big) == big.stepIDs && !state.hidesSteps(big) && state.isShowingAll(big))
        state.toggleShowAll(big)
        #expect(state.visibleSteps(big).count == 6, "Show less")
        let small = run("s", steps: 5)
        #expect(state.visibleSteps(small) == small.stepIDs && !state.hidesSteps(small), "여섯 이하는 가리지 않는다")
    }

    @Test func openingAStepReadsItsBodyOnceAndKeepsItForTheNextOpen() async {
        let state = SessionStepsState()
        var loads = 0
        let detail = ClaudeAppToolDetail(input: "{ }", result: "ok", truncated: false)
        let load: (String) async -> ClaudeAppToolDetail? = { _ in
            loads += 1
            return detail
        }
        state.toggle(step: "a", load: load)
        #expect(state.isOpen(step: "a") && state.details["a"] == .loading)
        #expect(await eventually { state.details["a"] == .loaded(detail) })
        state.toggle(step: "a", load: load)
        #expect(!state.isOpen(step: "a"))
        state.toggle(step: "a", load: load)
        #expect(state.isOpen(step: "a") && loads == 1, "이미 읽은 본문은 다시 읽지 않는다")
    }

    @Test func aStepWhoseBodyCannotBeReadShowsNothing() async {
        let state = SessionStepsState()
        state.toggle(step: "a", load: { _ in nil })
        #expect(await eventually { state.details["a"] == SessionStepsState.Detail.none })
    }

    @Test func theReadBodiesAreBounded() async {
        let state = SessionStepsState()
        for n in 0..<(SessionStepsState.maxDetails + 20) { state.toggle(step: "s\(n)", load: { _ in ClaudeAppToolDetail(input: "i", result: nil, truncated: false) }) }
        #expect(await eventually { state.details.count <= SessionStepsState.maxDetails })
    }

    @Test func theGapsBetweenEntriesFollowTheFourEightGrid() {
        typealias E = SessionEntriesView<EmptyView>
        let item = SessionEntry.item("a")
        let footer = SessionEntry.footer(SessionFooter(id: "f", workedFor: nil, copyText: "x"))
        let clock = SessionEntry.clock(SessionClock(id: "c", since: Date()))
        #expect(E.gap(before: item, at: 0) == 0 && E.gap(before: footer, at: 0) == 0, "첫 항목 위는 0")
        #expect(E.gap(before: item, at: 1) == TFSpace.md && E.gap(before: .steps(run("g", steps: 2)), at: 3) == TFSpace.md)
        #expect(E.gap(before: footer, at: 2) == TFSpace.xs && E.gap(before: clock, at: 5) == TFSpace.xs, "답 밑 줄 · 시계는 바로 밑 4")
        // 사용자 결정(2026-10-23): "Worked for"는 답 위에 선다
        let above = SessionEntry.footer(SessionFooter(id: "w", workedFor: 30, copyText: nil, aboveAnswer: true))
        let turnEnd = SessionEntry.footer(SessionFooter(id: "e", workedFor: 30, copyText: nil))
        #expect(E.gap(before: above, at: 2) == TFSpace.md, "답 위 시간 줄은 앞 블록과 12 떨어진다")
        #expect(E.gap(before: turnEnd, at: 2) == TFSpace.xs, "답 없는 턴의 끝 시간 줄은 바로 밑 4 (그대로)")
        #expect(E.gap(before: item, at: 3, previous: above) == TFSpace.xs, "시간 줄 바로 뒤의 답은 시간 줄에 4로 붙는다")
        #expect(E.gap(before: item, at: 3, previous: turnEnd) == TFSpace.md && E.gap(before: item, at: 3, previous: footer) == TFSpace.md, "다른 줄 뒤의 말은 블록 사이 12")
        #expect(E.gap(before: item, at: 3, previous: item) == TFSpace.md && E.gap(before: item, at: 0, previous: above) == 0)
    }

    // MARK: 옆줄의 자리 (E11)

    @Test func theSidePaneStandsOutsideWhenThereIsRoomAndInsideOrOverTheItselfWhenThereIsNot() {
        typealias L = SidePaneLayout
        #expect(L.plan(visible: false, expanded: false, room: 1000) == .none)
        #expect(L.plan(visible: true, expanded: false, room: 1000) == L.Plan(outside: 36, cut: 0, overlay: false))
        #expect(L.plan(visible: true, expanded: false, room: 36) == L.Plan(outside: 36, cut: 0, overlay: false), "딱 36이면 바깥")
        #expect(L.plan(visible: true, expanded: false, room: 35) == L.Plan(outside: 0, cut: 36, overlay: false), "36보다 작으면 띠도 패널 틀 안")
        #expect(L.plan(visible: true, expanded: true, room: 1000) == L.Plan(outside: 256, cut: 0, overlay: false))
        #expect(L.plan(visible: true, expanded: true, room: 256) == L.Plan(outside: 256, cut: 0, overlay: false))
        #expect(L.plan(visible: true, expanded: true, room: 255) == L.Plan(outside: 0, cut: 0, overlay: true), "256보다 작으면 펼침은 패널 위로 덮는다")
        #expect(L.plan(visible: true, expanded: true, room: 100).overlay && L.plan(visible: true, expanded: true, room: 100).outside == 0)
        #expect(L.stripWidth == 36 && L.paneWidth == 256)
    }

    @Test func theWindowGrowsToTheLeftOnlyWithTheSameRightEdgeTopAndHeight() {
        let panel = NSRect(x: 900, y: 300, width: 380, height: 440)
        let strip = SidePaneLayout.windowFrame(panel: panel, outside: 36)
        #expect(strip == NSRect(x: 864, y: 300, width: 416, height: 440))
        #expect(strip.maxX == panel.maxX && strip.maxY == panel.maxY && strip.minY == panel.minY)
        #expect(SidePaneLayout.windowFrame(panel: panel, outside: 0) == panel)
        #expect(SidePaneLayout.windowFrame(panel: panel, outside: 256).width == 636)
    }

    // MARK: 옆줄 모델 (E7 · E8 · 열린 질문 7)

    private func model(_ store: any BackgroundTaskOpenStore = InMemoryBackgroundTaskOpenStore(), now: Box = Box()) -> SessionSidePaneModel {
        let model = SessionSidePaneModel(store: store, clock: { now.value })
        model.attach(session: "s1")
        return model
    }

    final class Box: @unchecked Sendable {
        var value = Date(timeIntervalSince1970: 1_800_000_100)
        /// 도는 중인가 (꼬리 읽기를 계속할지 정하는 시험용 스위치)
        var flag = true
    }

    private func list(_ events: [BackgroundTaskEvent]) -> BackgroundTaskList {
        var list = BackgroundTaskList()
        for event in events { list.apply(event) }
        return list
    }

    private func started(_ id: String, _ seconds: TimeInterval = 0) -> BackgroundTaskEvent { .started(taskID: id, toolUseID: nil, kind: .command, name: "Run \(id)", at: at(seconds)) }
    private func finished(_ id: String, _ status: BackgroundTaskStatus = .done, _ seconds: TimeInterval = 10) -> BackgroundTaskEvent {
        .finished(taskID: id, kind: .command, status: status, exitCode: status == .failed ? 3 : 0, at: at(seconds))
    }

    @Test func noTasksNoStripAndARunningTaskShowsTheStripWithoutAnythingOpen() {
        let pane = model()
        #expect(!pane.visible && pane.windowExtra == 0)
        pane.tasks = list([started("a")])
        #expect(pane.visible && !pane.expanded && pane.windowExtra == 36)
    }

    @Test func aFinishedTaskStaysUntilTheListIsOpenedOnceAndThenFoldingMakesTheStripGo() {
        let now = Box()
        let store = InMemoryBackgroundTaskOpenStore()
        let pane = model(store, now: now)
        pane.tasks = list([started("a", 0), finished("a", .failed, 5)])
        #expect(pane.visible, "막 끝난 일은 열어 보기 전까지 남는다")
        pane.expand()
        #expect(pane.expanded && pane.windowExtra == 256 && store.openedAt(session: "s1") == now.value, "열어 본 시각은 이 Mac에 저장")
        pane.collapse()
        #expect(!pane.visible && pane.windowExtra == 0, "열어 보고 접으면 사라진다")
        pane.tasks = list([started("a", 0), finished("a", .failed, 5), started("b", 400)])
        #expect(pane.visible, "새 일이 시작되면 다시 나타난다")
    }

    @Test func theOpenedTimeSurvivesANewModelOverTheSameStore() {
        let store = InMemoryBackgroundTaskOpenStore()
        let first = model(store)
        first.tasks = list([started("a", 0), finished("a", .done, 5)])
        first.expand()
        first.collapse()
        let second = model(store)
        second.tasks = list([started("a", 0), finished("a", .done, 5)])
        #expect(!second.visible, "다시 열어도(앱을 다시 켜도) 본 것은 다시 나타나지 않는다")
    }

    @Test func switchingTheSessionStartsFoldedAndEmptyWithThatSessionsOpenedTime() {
        let store = InMemoryBackgroundTaskOpenStore()
        store.markOpened(session: "s2", at: at(1_000))
        let pane = model(store)
        pane.tasks = list([started("a")])
        pane.expand()
        pane.attach(session: "s2")
        #expect(!pane.expanded && pane.tasks.tasks.isEmpty && pane.openedAt == at(1_000) && pane.selectedID == nil)
    }

    @Test func aClosedSessionStopsTheTasksThatWereRunningAtTheMomentItClosed() {
        let now = Box()
        let pane = model(now: now)
        pane.tasks = list([started("a"), started("b"), finished("b")])
        pane.setClosed(true)
        let closedAt = now.value
        now.value = at(9_999)
        #expect(pane.effective.tasks.first { $0.id == "a" }?.status == .stopped && pane.effective.tasks.first { $0.id == "a" }?.endedAt == closedAt)
        #expect(pane.effective.tasks.first { $0.id == "b" }?.status == .done)
        pane.setClosed(false)
        #expect(pane.effective.tasks.first { $0.id == "a" }?.status == .running)
    }

    @Test func escapeClosesTheTailThenTheListThenFoldsAndOnlyThenLeavesTheKeyToThePanel() {
        let pane = model()
        pane.tasks = list([started("a")])
        #expect(!pane.escape(), "접혀 있으면 패널이 받는다")
        pane.expand()
        pane.select("a")
        #expect(pane.selectedID == "a")
        #expect(pane.escape() && pane.selectedID == nil && pane.expanded, "꼬리 → 목록")
        #expect(pane.escape() && !pane.expanded, "목록 → 접힘")
        #expect(!pane.escape())
    }

    @Test func aTaskCanBeOpenedOnlyWhileExpandedAndOnlyIfItIsInTheList() {
        let pane = model()
        pane.tasks = list([started("a")])
        pane.select("a")
        #expect(pane.selectedID == nil, "접혀 있을 때는 열 수 없다")
        pane.expand()
        pane.select("ghost")
        #expect(pane.selectedID == nil)
        pane.select("a")
        #expect(pane.selected?.id == "a")
    }

    @Test func openingATaskMakesItsTailAndGoingBackStopsAndDropsIt() async {
        let pane = model()
        pane.tasks = list([started("a")])
        let gate = Gate()
        var made: [String] = []
        pane.makeTail = { task in
            made.append(task.id)
            return BackgroundTaskTailModel(taskID: task.id, read: { _ in .output(.text("out", hasEarlier: false)) }, pause: { _ in await gate.sleep(1) })
        }
        pane.expand()
        pane.select("a")
        #expect(made == ["a"])
        let tail = pane.tail
        #expect(await eventually { tail?.state == .text("out", hasEarlier: false) })
        pane.back()
        #expect(pane.tail == nil && pane.selectedID == nil)
        gate.release()
        pane.select("a")
        pane.collapse()
        #expect(pane.tail == nil, "접으면 꼬리도 버린다")
    }

    @Test func aPaneWithoutATailReaderStillOpensTheTaskButHasNoOutput() {
        let pane = model()
        pane.tasks = list([started("a")])
        pane.expand()
        pane.select("a")
        #expect(pane.selectedID == "a" && pane.tail == nil)
    }

    // MARK: 출력 꼬리 모델 (E10)

    @Test func theResultMapsToTheScreenStates() {
        typealias T = BackgroundTaskTailModel
        #expect(T.state(for: .output(.text("hi", hasEarlier: true)), running: true) == .text("hi", hasEarlier: true))
        #expect(T.state(for: .output(.text("", hasEarlier: false)), running: true) == .empty)
        #expect(T.state(for: .output(.agent([], hasEarlier: false)), running: false) == .empty)
        #expect(T.state(for: .missing, running: true) == .empty, "막 시작한 일은 아직 출력이 없다")
        #expect(T.state(for: .missing, running: false) == .unavailable, "끝났는데 파일이 없다: 지워졌다")
        #expect(T.state(for: .unreadable, running: true) == .unavailable)
        let turn = ClaudeAppTurn(id: "t", kind: .assistant("hi"))
        #expect(T.state(for: .output(.agent([turn], hasEarlier: false)), running: true) == .agent([turn], hasEarlier: false))
    }

    @Test func aRunningTasksTailIsReadAgainAndAFinishedOneIsReadOnce() async {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var _reads = 0
            var reads: Int { lock.withLock { _reads } }
            func hit() { lock.withLock { _reads += 1 } }
        }
        let counter = Counter()
        let running = Box()
        let tail = BackgroundTaskTailModel(taskID: "a", read: { _ in
            counter.hit()
            return .output(.text("line \(counter.reads)", hasEarlier: false))
        }, pause: { _ in })
        tail.start { running.flag }
        #expect(await eventually { counter.reads >= 3 }, "도는 일은 이어 읽는다")
        running.flag = false
        let settled = counter.reads
        try? await Task.sleep(for: .milliseconds(50))
        #expect(counter.reads <= settled + 1, "끝나면 멈춘다")
        tail.stop()
        let finishedOnce = Counter()
        let finished = BackgroundTaskTailModel(taskID: "b", read: { _ in
            finishedOnce.hit()
            return .output(.text("done", hasEarlier: false))
        }, pause: { _ in })
        finished.start { false }
        #expect(await eventually { finished.state == .text("done", hasEarlier: false) })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(finishedOnce.reads == 1)
    }

    @Test func showEarlierWidensTheWindowByFourUpToTheCapAndRetryReadsAgain() async {
        final class Windows: @unchecked Sendable {
            private let lock = NSLock()
            private var _seen: [Int] = []
            var seen: [Int] { lock.withLock { _seen } }
            func hit(_ window: Int) { lock.withLock { _seen.append(window) } }
        }
        let windows = Windows()
        let tail = BackgroundTaskTailModel(taskID: "a", read: { window in
            windows.hit(window)
            return window < BackgroundTaskTail.Limits.standard.maxTailBytes ? .output(.text("x", hasEarlier: true)) : .unreadable
        }, pause: { _ in })
        #expect(tail.window == 16 << 10)
        tail.showEarlier()
        #expect(tail.window == 64 << 10)
        tail.showEarlier()
        #expect(tail.window == 256 << 10, "16 KiB → 64 KiB → 256 KiB (보안 P3: 상한은 256 KiB)")
        tail.showEarlier()
        #expect(tail.window == 256 << 10, "상한을 넘지 않는다")
        #expect(await eventually { tail.state == .unavailable })
        let before = windows.seen.count
        tail.retry()
        #expect(tail.state == .loading)
        #expect(await eventually { windows.seen.count > before })
    }

    // MARK: 두 세션 패널의 창 틀 (E11)

    @Test func theClaudePanelWindowGrowsLeftByTheSidePaneAndKeepsItsRightEdgeTopAndHeight() async throws {
        guard let screen = EdgeRailPanelController.screen else { return }
        let w = await EdgeSessionsTests().rig(rows: [1], live: [EdgeSessionsTests.live(1, .busy)])
        let claude = EdgeClaudeAppPanelController(shell: w.shell)
        w.shell.openRailEntry(w.shell.slots.first { $0.source == .claudeApp(sessionID: EdgeSessionsTests.id(1)) }!)
        claude.presentation.headHeight = 40
        claude.presentation.bodyHeight = 300
        let base = try #require(claude.panelFrame())
        #expect(try #require(claude.targetFrame()) == base, "일이 없으면 지금 그대로")
        let pane = claude.presentation.pane
        pane.attach(session: EdgeSessionsTests.id(1))
        pane.tasks = list([started("a")])
        let strip = try #require(claude.targetFrame())
        #expect(strip.width == base.width + 36 && strip.maxX == base.maxX && strip.minY == base.minY && strip.maxY == base.maxY)
        #expect(pane.room == base.minX - screen.visibleFrame.minX, "화면 왼쪽 여유를 모델에 알린다")
        pane.expand()
        let wide = try #require(claude.targetFrame())
        #expect(wide.width == base.width + 256 && wide.maxX == base.maxX && wide.height == base.height)
        pane.collapse()
        #expect(try #require(claude.targetFrame()).width == base.width + 36)
        w.shell.dismiss()
    }

    @Test func escapeFoldsTheClaudeSidePaneBeforeItClosesThePanel() async throws {
        let w = await EdgeSessionsTests().rig(rows: [1], live: [EdgeSessionsTests.live(1, .busy)])
        let claude = EdgeClaudeAppPanelController(shell: w.shell)
        w.shell.openRailEntry(w.shell.slots.first { $0.source == .claudeApp(sessionID: EdgeSessionsTests.id(1)) }!)
        #expect(w.shell.view == .claudeApp)
        let pane = claude.presentation.pane
        pane.attach(session: EdgeSessionsTests.id(1))
        pane.tasks = list([started("a")])
        pane.expand()
        w.shell.escape()
        #expect(!pane.expanded && w.shell.panelOpen, "Esc 한 번: 옆줄만 접는다")
        w.shell.escape()
        #expect(!w.shell.panelOpen, "그다음에 패널")
    }

    @Test func theTaskforcePanelWindowGrowsLeftByTheSidePaneAndEscapeFoldsItFirst() async throws {
        guard let screen = EdgeRailPanelController.screen else { return }
        let rig = EdgeExternalSessionsTests().make()
        let runtime = ChatRuntime(gateway: IssueSampleGateway(), scope: rig.scope, now: { Date() }, issueScreens: false)
        let controller = EdgeSessionPanelController(shell: rig.shell, runtime: runtime)
        let issuePanel = NSRect(x: screen.visibleFrame.minX + 1100, y: screen.visibleFrame.minY + 200, width: 380, height: 440)
        controller.issuePanelFrame = { issuePanel }
        controller.presentation.headHeight = 40
        controller.presentation.bodyHeight = 300
        let base = EdgeSessionPanelController.frame(issuePanel: issuePanel, height: controller.height())
        #expect(try #require(controller.targetFrame()) == base, "일이 없으면 지금 그대로")
        let pane = controller.presentation.pane
        pane.attach(session: "s1")
        pane.tasks = list([started("a")])
        let strip = try #require(controller.targetFrame())
        #expect(strip.width == base.width + 36 && strip.maxX == base.maxX && strip.minY == base.minY && strip.maxY == base.maxY, "오른쪽 · 위 · 높이는 패널과 같다")
        #expect(pane.room == base.minX - screen.visibleFrame.minX)
        pane.expand()
        #expect(try #require(controller.targetFrame()).width == base.width + 256)
        pane.select("a")
        #expect(rig.shell.onEscapeSessionOverlay() == true && pane.selectedID == nil && pane.expanded, "Esc: 꼬리 먼저")
        #expect(rig.shell.onEscapeSessionOverlay() == true && !pane.expanded, "다음은 접기")
        #expect(rig.shell.onEscapeSessionOverlay() == false, "옆줄이 접히면 패널에 넘긴다")
    }

    // MARK: 그리기 (실제 뷰를 만들어 본다: 런타임 단언 · 빈 크기를 잡는다)

    @Test func theEntriesViewDrawsGroupsStepsFootersAndTheClockInOneColumn() async throws {
        let steps = (0..<8).map { SessionTimelineItem(id: "s\($0)", role: .step, time: at(Double($0)), stepName: $0.isMultiple(of: 2) ? "Read" : "Grep") }
        let items = [SessionTimelineItem(id: "u", role: .user, time: at(0))] + steps + [SessionTimelineItem(id: "a", role: .assistant, time: at(90), text: "Done with `code` and **bold**.")]
        let entries = SessionTimeline.build(items, state: .finished)
        var infos: [String: SessionStepInfo] = [:]
        for step in steps { infos[step.id] = SessionStepInfo(name: step.stepName ?? "", target: "pricing.mdx", failed: step.id == "s3", canExpand: true) }
        let state = SessionStepsState()
        if case .steps(let run)? = entries.compactMap({ if case .steps = $0 { $0 } else { nil } }).first { state.toggle(run) }
        let view = SessionEntriesView(entries: entries, steps: infos, state: state, item: { id in
            if id == "a" { SessionMarkdownView(source: "Done with `code` and **bold**.\n\n```json\n{ \"a\": 1 }\n```\n\n- one\n- two") } else { Text("ask").font(TFFont.callout) }
        })
        .padding(16)
        .frame(width: 380)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 380, height: 600)
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        #expect(size.width > 0 && size.height > 100)
        let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        #expect(rep.pixelsWide > 0)
    }

    @Test func theSidePaneSurfaceDrawsTheStripTheListAndTheTailAtTheirDesignedWidths() async throws {
        let pane = model()
        pane.tasks = list([started("a", 0), started("b", 5), finished("b", .failed, 20)])
        pane.makeTail = { task in BackgroundTaskTailModel(taskID: task.id, read: { _ in .output(.text("> next dev\nready", hasEarlier: false)) }, pause: { _ in }) }
        func draw(width: CGFloat) throws -> NSBitmapImageRep {
            let view = SessionPanelFrame(pane: pane, reduceMotion: true) { content in
                Text("panel").frame(width: content).frame(maxHeight: .infinity)
            }
            .frame(width: width, height: 420)
            let hosting = NSHostingView(rootView: view)
            hosting.frame = NSRect(x: 0, y: 0, width: width, height: 420)
            hosting.layoutSubtreeIfNeeded()
            let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            return rep
        }
        #expect(try draw(width: 380 + 36).pixelsWide > 0)
        pane.expand()
        #expect(try draw(width: 380 + 256).pixelsWide > 0)
        pane.select("a")
        #expect(await eventually { pane.tail?.state == .text("> next dev\nready", hasEarlier: false) })
        #expect(try draw(width: 380 + 256).pixelsWide > 0)
    }
}
