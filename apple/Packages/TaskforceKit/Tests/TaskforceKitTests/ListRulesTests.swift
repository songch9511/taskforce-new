import Foundation
import Testing
@testable import TaskforceKit

/// Figma M1 · M13 시간표 (10:42): Review 4 · In Progress 5 · To Do 14 · Done Today 6
enum ListFixture {
    static func id(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))!
    }

    static func action(_ n: Int, status: ActionStatus = .open, started: Bool = false, review: Bool = false, due: LocalDate? = nil) -> ActionSummary {
        ActionSummary(
            id: id(n), title: "할 일 \(n)", owner: .me, status: status, dueDate: due, counterpart: "상대 \(n)", needsConfirmation: review,
            confirmReasons: review ? ["담당 확인"] : [], startedAt: started ? Date(timeIntervalSince1970: 1_700_000_000) : nil,
            lastActivityAt: Date(timeIntervalSince1970: 0)
        )
    }

    static let reviews = (1...4).map { action($0, review: true) }
    static let inProgress = (11...15).map { action($0, started: true) }
    static let toDo = (21...34).map { action($0) }
    static let done = (41...46).map { action($0, status: .done) }

    static let sections = TaskSections(
        review: reviews,
        inProgress: inProgress.map { RankedAction(action: $0, score: 1, reasons: [], daysUntilDue: nil) },
        toDo: toDo.map { RankedAction(action: $0, score: 1, reasons: [], daysUntilDue: nil) },
        doneToday: done
    )

    /// 바뀐 할 일: Review 2 · In Progress 1 · To Do 1 (Done Today는 서버가 보내지 않는다)
    static let changed: Set<UUID> = [id(2), id(3), id(12), id(30)]
}

struct SectionCapsTests {
    let caps = SectionCaps()

    @Test func capsShowAllByDefault() {
        #expect(caps.fold(.review, count: 4) == .all)
        #expect(caps.fold(.inProgress, count: 5) == .all)
        #expect(caps.fold(.toDo, count: 14) == .all)
        #expect(caps.fold(.doneToday, count: 6) == .all)
    }

    @Test func atOrUnderTheLimitShowsAll() {
        #expect(caps.fold(.review, count: 2) == .all)
        #expect(caps.fold(.review, count: 0) == .all)
        #expect(caps.fold(.doneToday, count: 0) == .all)
    }

    @Test func serverLimitsReplaceDefaults() {
        let caps = SectionCaps(limits: SectionLimits(review: 1, inProgress: 3, toDo: 10))
        #expect(caps.fold(.review, count: 4) == .capped(visible: 1, hidden: 3))
        #expect(caps.fold(.inProgress, count: 5) == .capped(visible: 3, hidden: 2))
        #expect(caps.fold(.toDo, count: 14) == .capped(visible: 10, hidden: 4))
    }

    @Test func expandingIsPerSection() {
        var caps = SectionCaps(displayPreferences: SectionDisplayPreferences(review: .five, inProgress: .five, toDo: .five, doneToday: .five))
        caps.expand(.toDo)
        #expect(caps.fold(.toDo, count: 14) == .all)
        #expect(caps.fold(.review, count: 14) == .capped(visible: 5, hidden: 9))
        caps.toggle(.doneToday)
        #expect(caps.fold(.doneToday, count: 6) == .all)
        caps.toggle(.doneToday)
        #expect(caps.fold(.doneToday, count: 6) == .capped(visible: 5, hidden: 1))
        caps.reset()
        #expect(caps.fold(.toDo, count: 14) == .capped(visible: 5, hidden: 9))
    }

    /// 찾는 중 · 범위를 고른 동안에는 접지 않는다 (찾기가 접힌 행도 찾는다)
    @Test(arguments: [("제안서", TaskScope.allTasks), ("", .toDo), ("", .changed), ("", .doneToday), ("x", .review)])
    func searchOrScopeUnfolds(_ query: String, _ scope: TaskScope) {
        for group in TaskGroup.allCases {
            #expect(caps.fold(group, count: 14, query: query, scope: scope) == .all)
        }
    }

    @Test func blankQueryStillFolds() {
        let capped = SectionCaps(displayPreferences: SectionDisplayPreferences(toDo: .five))
        #expect(capped.fold(.toDo, count: 14, query: "  ", scope: .allTasks) == .capped(visible: 5, hidden: 9))
    }

    /// 펼침을 포함하면 보이는 행 합계 = 열린 할 일 수 (회귀 ⑤)
    @Test func visibleRowsPlusHiddenEqualOpenCount() {
        let s = ListFixture.sections
        var caps = caps
        let groups: [TaskGroup] = [.review, .inProgress, .toDo]
        func shown() -> Int { groups.reduce(0) { $0 + caps.fold($1, count: s.actions(in: $1).count).visibleCount(of: s.actions(in: $1).count) } }
        func hidden() -> Int {
            groups.reduce(0) {
                if case .capped(_, let hidden) = caps.fold($1, count: s.actions(in: $1).count) { return $0 + hidden }
                return $0
            }
        }
        #expect(shown() + hidden() == 23)
        groups.forEach { caps.expand($0) }
        #expect(shown() == 23)
    }
}

struct TaskScopeTests {
    let s = ListFixture.sections
    let changed = ListFixture.changed

    /// M13 순서 (… Done Today | Waiting on Someone(U5) · Taskforce Working · Changed Since Last Look)
    @Test func titlesMatchFigma() {
        #expect(TaskScope.allCases.map(\.title) == [
            "All Tasks", "Review", "In Progress", "To Do", "Done Today", "Taskforce Working", "Changed Since Last Look",
        ])
    }

    /// M13: All Tasks 23 = 4 + 5 + 14 (Done Today는 세지 않는다)
    @Test func countsPerScope() {
        #expect(TaskScope.allTasks.count(in: s, changed: changed) == 23)
        #expect(TaskScope.review.count(in: s, changed: changed) == 4)
        #expect(TaskScope.inProgress.count(in: s, changed: changed) == 5)
        #expect(TaskScope.toDo.count(in: s, changed: changed) == 14)
        #expect(TaskScope.doneToday.count(in: s, changed: changed) == 6)
        #expect(TaskScope.changed.count(in: s, changed: changed) == 4)
    }

    @Test func allTasksKeepsEverySection() {
        #expect(TaskScope.allTasks.apply(to: s, changed: changed) == s)
    }

    @Test func singleSectionScopes() {
        let review = TaskScope.review.apply(to: s, changed: changed)
        #expect(review.review == s.review)
        #expect(review.inProgress.isEmpty && review.toDo.isEmpty && review.doneToday.isEmpty)
        let done = TaskScope.doneToday.apply(to: s, changed: changed)
        #expect(done.doneToday == s.doneToday)
        #expect(done.review.isEmpty && done.inProgress.isEmpty && done.toDo.isEmpty)
    }

    @Test func changedScopeKeepsServerOrderInEachSection() {
        let scoped = TaskScope.changed.apply(to: s, changed: changed)
        #expect(scoped.review.map(\.id) == [ListFixture.id(2), ListFixture.id(3)])
        #expect(scoped.inProgress.map(\.id) == [ListFixture.id(12)])
        #expect(scoped.toDo.map(\.id) == [ListFixture.id(30)])
        #expect(scoped.doneToday.isEmpty)
    }

    /// 예전 서버(바뀜 없음)에서는 바뀜 범위를 숨긴다. 실행을 쓸 수 없으면(기본) Taskforce Working도 숨긴다 (U1 메뉴 그대로)
    @Test func menuHidesChangedWithoutServerSupport() {
        #expect(TaskScope.menu(tracksChanges: true) == TaskScope.allCases.filter { $0 != .taskforceWorking })
        #expect(!TaskScope.menu(tracksChanges: false).contains(.changed))
        #expect(TaskScope.menu(tracksChanges: false).count == 5)
    }

    /// Taskforce Working은 실행을 쓸 수 있을 때만 (credits 200), Changed 앞
    @Test func menuShowsTaskforceWorkingWhenExecutionIsAvailable() {
        #expect(TaskScope.menu(tracksChanges: true, showsTaskforce: true) == TaskScope.allCases)
        #expect(TaskScope.menu(tracksChanges: true, showsTaskforce: true).suffix(2) == [.taskforceWorking, .changed])
        #expect(TaskScope.menu(tracksChanges: false, showsTaskforce: true).last == .taskforceWorking)
        #expect(!TaskScope.menu(tracksChanges: true, showsTaskforce: false).contains(.taskforceWorking))
    }

    /// 끝나지 않은 run이 있는 열린 할 일: 구역 안 순서 그대로, Done Today는 넣지 않는다
    @Test func taskforceWorkingScope() {
        let working: Set<UUID> = [ListFixture.id(3), ListFixture.id(11), ListFixture.id(25), ListFixture.id(41), UUID()]
        let scoped = TaskScope.taskforceWorking.apply(to: s, changed: changed, working: working)
        #expect(scoped.review.map(\.id) == [ListFixture.id(3)])
        #expect(scoped.inProgress.map(\.id) == [ListFixture.id(11)])
        #expect(scoped.toDo.map(\.id) == [ListFixture.id(25)])
        #expect(scoped.doneToday.isEmpty)
        #expect(TaskScope.taskforceWorking.count(in: s, changed: changed, working: working) == 3)
        #expect(TaskScope.taskforceWorking.count(in: s, changed: changed) == 0)
        #expect(TaskScope.taskforceWorking.groups == [.review, .inProgress, .toDo])
        // 다른 범위는 run과 상관없다
        #expect(TaskScope.review.count(in: s, changed: changed, working: working) == 4)
    }
}

struct SeenTrackerTests {
    let a = ListFixture.id(1)
    let b = ListFixture.id(2)
    let c = ListFixture.id(3)

    /// 바뀐 행을 골랐다가 다른 행으로 옮기면 한 번 보내고 점을 지운다
    @Test func leavingAChangedRowSendsOnce() {
        var tracker = SeenTracker()
        let changed: Set<UUID> = [a]
        let sent = tracker.select(a, changed: changed)
        #expect(sent == nil)
        #expect(tracker.showsDot(a, changed: changed))
        let sent2 = tracker.select(b, changed: changed)
        #expect(sent2 == a)
        #expect(!tracker.showsDot(a, changed: changed))
        let sent3 = tracker.select(a, changed: changed)
        #expect(sent3 == nil)
        let sent4 = tracker.select(b, changed: changed)
        #expect(sent4 == nil)
    }

    /// 화살표로 지나가기만 해도 본 것으로 친다
    @Test func arrowingThroughCounts() {
        var tracker = SeenTracker()
        let changed: Set<UUID> = [b]
        var sent: [UUID] = []
        for id in [a, b, c] {
            if let seen = tracker.select(id, changed: changed) { sent.append(seen) }
        }
        #expect(sent == [b])
    }

    @Test func unchangedRowsNeverSend() {
        var tracker = SeenTracker()
        let sent = tracker.select(a, changed: [])
        #expect(sent == nil)
        let sent2 = tracker.select(b, changed: [])
        #expect(sent2 == nil)
        let sent3 = tracker.select(nil, changed: [])
        #expect(sent3 == nil)
    }

    /// 런처가 닫혀 선택이 없어져도 떠난 것으로 친다
    @Test func closingSends() {
        var tracker = SeenTracker()
        _ = tracker.select(a, changed: [a])
        let sent = tracker.select(nil, changed: [a])
        #expect(sent == a)
    }

    /// 보내기가 실패해도 다시 보내지 않는다. 다음 `/now`가 아직 바뀜이라 하면 점이 다시 보인다
    @Test func nextNowIsTheTruth() {
        var tracker = SeenTracker()
        _ = tracker.select(a, changed: [a])
        _ = tracker.select(b, changed: [a])
        #expect(!tracker.showsDot(a, changed: [a]))
        let sent = tracker.select(c, changed: [a])
        #expect(sent == nil)
        tracker.refreshed(changed: [a])
        #expect(tracker.showsDot(a, changed: [a]))
        tracker.refreshed(changed: [])
        #expect(!tracker.showsDot(a, changed: []))
    }

    /// 고른 행이 새 `/now`에서 바뀜이 아니면 떠날 때 보내지 않는다
    @Test func refreshClearsAStaleSelection() {
        var tracker = SeenTracker()
        _ = tracker.select(a, changed: [a])
        tracker.refreshed(changed: [])
        let sent = tracker.select(b, changed: [])
        #expect(sent == nil)
    }

    /// 고른 채로 있는 행이 새 `/now`에서 바뀜이 되면, 떠날 때 보낸다 (상세가 보였으므로)
    @Test func selectedRowThatBecomesChangedSendsOnLeave() {
        var tracker = SeenTracker()
        let none = tracker.select(a, changed: [])
        #expect(none == nil)
        tracker.refreshed(changed: [a], selected: a)
        let sent = tracker.select(b, changed: [a])
        #expect(sent == a)
    }

    /// iPhone: 열면 바로 보낸다 (한 번)
    @Test func openingSendsImmediately() {
        var tracker = SeenTracker()
        let sent = tracker.open(a, changed: [a])
        #expect(sent == a)
        let sent2 = tracker.open(a, changed: [a])
        #expect(sent2 == nil)
        let sent3 = tracker.open(b, changed: [a])
        #expect(sent3 == nil)
        #expect(!tracker.showsDot(a, changed: [a]))
    }

    @Test func resetForgetsEverything() {
        var tracker = SeenTracker()
        _ = tracker.select(a, changed: [a])
        _ = tracker.select(b, changed: [a])
        tracker.reset()
        #expect(tracker.viewing == nil)
        #expect(tracker.showsDot(a, changed: [a]))
    }
}

struct RefreshTrackerTests {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func firstLoad() {
        var tracker = RefreshTracker()
        #expect(tracker.state == .loading)
        tracker.loadStarted()
        #expect(tracker.state == .loading)
        tracker.loadSucceeded(at: t0)
        #expect(tracker.state == .live)
        #expect(!tracker.isLoading)
    }

    /// M20: 오프라인 + 저장본 없음
    @Test func offlineWithNothingSaved() {
        var tracker = RefreshTracker()
        let reload = tracker.pathChanged(online: false, at: t0)
        #expect(!reload)
        #expect(tracker.state == .offlineEmpty(since: t0))
        tracker.loadFailed(at: t0.addingTimeInterval(1))
        #expect(tracker.state == .offlineEmpty(since: t0))
    }

    /// M15 · P10: 오프라인 + 저장본 (앱을 오프라인으로 열었다)
    @Test func offlineWithSavedCopy() {
        var tracker = RefreshTracker()
        let saved = t0.addingTimeInterval(-3600)
        tracker.restoredSaved(savedAt: saved)
        tracker.pathChanged(online: false, at: t0)
        #expect(tracker.state == .offlineSaved(since: t0, savedAt: saved))
    }

    /// 이번 실행에서 받은 목록이 있으면 오프라인 때 그 시각을 보인다
    @Test func goingOfflineAfterALiveLoad() {
        var tracker = RefreshTracker()
        tracker.loadSucceeded(at: t0)
        tracker.pathChanged(online: false, at: t0.addingTimeInterval(60))
        #expect(tracker.state == .offlineSaved(since: t0.addingTimeInterval(60), savedAt: t0))
        #expect(tracker.state.isOffline)
    }

    /// 연결이 돌아오면 다시 불러온다 (한 번만)
    @Test func reconnectAsksForReload() {
        var tracker = RefreshTracker()
        tracker.pathChanged(online: false, at: t0)
        let reload = tracker.pathChanged(online: true, at: t0.addingTimeInterval(5))
        #expect(reload)
        let reload2 = tracker.pathChanged(online: true, at: t0.addingTimeInterval(6))
        #expect(!reload2)
        #expect(tracker.offlineSince == nil)
        #expect(tracker.state == .loading)
    }

    /// 연결이 돌아오면 지난 "Couldn't refresh"는 보이지 않는다 (곧 다시 불러온다)
    @Test func reconnectClearsAnOldFailure() {
        var tracker = RefreshTracker()
        tracker.loadSucceeded(at: t0)
        tracker.loadFailed(at: t0.addingTimeInterval(60))
        tracker.pathChanged(online: false, at: t0.addingTimeInterval(120))
        tracker.pathChanged(online: true, at: t0.addingTimeInterval(180))
        #expect(tracker.failedAt == nil)
        #expect(tracker.state == .live)
    }

    /// M19: 온라인인데 실패 → "Couldn't refresh at 10:46. Showing 10:31."
    @Test func refreshFailedKeepsTheShownList() {
        var tracker = RefreshTracker()
        let shown = t0
        let failed = t0.addingTimeInterval(15 * 60)
        tracker.loadSucceeded(at: shown)
        tracker.loadStarted()
        tracker.loadFailed(at: failed)
        #expect(tracker.state == .refreshFailed(at: failed, savedAt: shown))
        tracker.loadSucceeded(at: failed.addingTimeInterval(30))
        #expect(tracker.state == .live)
    }

    @Test func refreshFailedWithNothingToShow() {
        var tracker = RefreshTracker()
        tracker.loadFailed(at: t0)
        #expect(tracker.state == .refreshFailed(at: t0, savedAt: nil))
    }

    @Test func savedCopyNeverReplacesALiveList() {
        var tracker = RefreshTracker()
        tracker.loadSucceeded(at: t0)
        tracker.restoredSaved(savedAt: t0.addingTimeInterval(-60))
        #expect(tracker.shownAt == t0)
    }

    @Test func resetKeepsConnectivityOnly() {
        var tracker = RefreshTracker()
        tracker.loadSucceeded(at: t0)
        tracker.pathChanged(online: false, at: t0)
        tracker.reset()
        #expect(tracker.state == .offlineEmpty(since: t0))
    }
}
