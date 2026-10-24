#if os(macOS)
import Foundation
import Testing
@testable import TaskforceKit

/// 하위 에이전트 트리 T1의 순수 규칙: 일에 부모 · 깊이 · 전경 표시가 붙고, 스냅샷은 전경 일을 멈추지 않고, 트리 투영은 **provider가 준 id로만** 선을 긋는다.
/// 부모를 모르거나 믿을 수 없는 일(자기 참조 · 순환 · 이 목록에 없는 부모)은 세션 바로 아래에 다른 표시 없이 둔다 (선을 그리지 않는 것이 곧 "모름"이다)
struct BackgroundTaskTreeTests {
    typealias Event = BackgroundTaskEvent

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private func started(
        _ id: String, parent: String? = nil, depth: Int? = nil, foreground: Bool = false, kind: BackgroundTaskKind = .agent, name: String? = nil, _ seconds: TimeInterval = 0
    ) -> Event {
        .started(taskID: id, toolUseID: nil, kind: kind, name: name ?? "Task \(id)", at: at(seconds), parentID: parent, depth: depth, foreground: foreground)
    }

    private func finished(_ id: String, _ status: BackgroundTaskStatus = .done, _ seconds: TimeInterval = 10) -> Event {
        .finished(taskID: id, kind: .agent, status: status, exitCode: nil, at: at(seconds))
    }

    private func list(_ events: [Event], now: TimeInterval = 500) -> BackgroundTaskList {
        var list = BackgroundTaskList()
        for event in events { list.apply(event, now: at(now)) }
        return list
    }

    private func task(_ list: BackgroundTaskList, _ id: String) -> BackgroundTask? { list.tasks.first { $0.id == id } }

    private func ids(_ rows: [SubagentTreeRow]) -> [String] { rows.map(\.task.id) }

    private func rows(_ list: BackgroundTaskList, _ expansion: SubagentTreeExpansion = SubagentTreeExpansion()) -> [SubagentTreeRow] {
        SubagentTree.rows(for: list, expansion: expansion)
    }

    // MARK: 부모 · 깊이 · 전경

    @Test func aStartedTaskCarriesItsParentDepthAndForegroundFlag() {
        let tasks = list([started("child", parent: "mother", depth: 2, foreground: true)])
        let found = task(tasks, "child")
        #expect(found?.parentID == "mother" && found?.depth == 2 && found?.foreground == true)
        #expect(task(list([started("plain")]), "plain")?.parentID == nil && task(list([started("plain")]), "plain")?.foreground == false)
    }

    @Test func aLateStartFillsOnlyWhatTheTaskDidNotKnowAndNeverChangesAnAlreadyKnownParent() {
        // 스냅샷이 시작 줄보다 먼저 와서 부모를 모른 채 만들어졌다 (C1의 순서)
        var tasks = list([.started(taskID: "child", toolUseID: nil, kind: .agent, name: nil, at: at(1)), started("other", name: "Other")])
        #expect(task(tasks, "child")?.parentID == nil)
        tasks.apply(started("child", parent: "mother", depth: 2, name: "Named later", 2))
        #expect(task(tasks, "child")?.parentID == "mother" && task(tasks, "child")?.depth == 2 && task(tasks, "child")?.name == "Named later")
        tasks.apply(started("child", parent: "someone-else", depth: 3, 3))
        #expect(task(tasks, "child")?.parentID == "mother" && task(tasks, "child")?.depth == 2, "아는 부모는 늦은 줄이 바꾸지 않는다")
    }

    @Test func aFinishThatComesBeforeItsStartKeepsTheEndAndTakesTheParentFromTheLateStart() {
        let tasks = list([finished("child", .done, 30), started("child", parent: "mother", depth: 2, 5)])
        let found = task(tasks, "child")
        #expect(tasks.tasks.count == 1 && found?.status == .done && found?.endedAt == at(30) && found?.parentID == "mother" && found?.depth == 2)
    }

    @Test func aDuplicateStartIsOneTask() {
        let events = [started("a", parent: "p", depth: 2, 1), started("a", parent: "p", depth: 2, 1), started("p", depth: 1, 0)]
        let tasks = list(events + events)
        #expect(tasks.tasks.count == 2)
        #expect(ids(rows(tasks)) == ["p", "a"])
    }

    // MARK: 스냅샷은 전경 일을 멈추지 않는다

    @Test func aSnapshotStopsMissingBackgroundTasksButNeverAForegroundOne() {
        var tasks = list([started("bg", depth: 1, 1), started("fg", parent: "bg", depth: 2, foreground: true, 2), started("fg-top", depth: 1, foreground: true, 3)])
        tasks.apply(.snapshot(runningTaskIDs: []), now: at(40))
        #expect(task(tasks, "bg")?.status == .stopped && task(tasks, "bg")?.endedAt == at(40))
        #expect(task(tasks, "fg")?.status == .running && task(tasks, "fg")?.endedAt == nil, "스냅샷은 백그라운드 일만 싣는다")
        #expect(task(tasks, "fg-top")?.status == .running)
    }

    @Test func aForegroundTaskEndsByItsFinishAndStaysDoneAfterLaterSnapshots() {
        var tasks = list([started("fg", depth: 1, foreground: true, 1)])
        tasks.apply(.snapshot(runningTaskIDs: []), now: at(5))
        #expect(task(tasks, "fg")?.status == .running)
        tasks.apply(finished("fg", .done, 8))
        #expect(task(tasks, "fg")?.status == .done && task(tasks, "fg")?.endedAt == at(8))
        tasks.apply(.snapshot(runningTaskIDs: []), now: at(60))
        #expect(task(tasks, "fg")?.status == .done)
    }

    @Test func aForegroundTaskKilledIsStoppedNeverDone() {
        let tasks = list([started("fg", depth: 1, foreground: true, 1), finished("fg", .stopped, 12)])
        #expect(task(tasks, "fg")?.status == .stopped)
    }

    @Test func collectingTheProcessStopsARunningForegroundTaskAndNothingElse() {
        var tasks = list([started("fg", foreground: true, 1), started("bg", 2), started("other", foreground: true, 3), finished("done-fg", .done)])
        tasks.stopRunning(["fg", "done-fg"], now: at(90))
        #expect(task(tasks, "fg")?.status == .stopped && task(tasks, "fg")?.endedAt == at(90))
        #expect(task(tasks, "bg")?.status == .running && task(tasks, "other")?.status == .running)
        #expect(task(tasks, "done-fg")?.status == .done)
    }

    // MARK: 트리 투영

    @Test func depthTwoUnderOneOfTwoConcurrentParentsHangsUnderThatParentOnly() {
        let tasks = list([started("a", depth: 1, 1), started("b", depth: 1, 2), started("n", parent: "a", depth: 2, foreground: true, 3)])
        let shown = rows(tasks)
        #expect(ids(shown) == ["b", "a", "n"], "형제(a · b) 안의 순서는 새것 먼저, 자식은 부모 바로 아래")
        #expect(shown.map(\.level) == [0, 0, 1])
    }

    @Test func siblingsAreOrderedRunningThenFailedThenTheRestNewestFirstAndOnlyAmongSiblings() {
        let tasks = list([
            started("old-done", depth: 1, 1), finished("old-done", .done, 20), started("run-old", depth: 1, 2), started("run-new", depth: 1, 9), started("bad", depth: 1, 4), finished("bad", .failed, 30),
            started("p", depth: 1, 5), started("c-done", parent: "p", depth: 2, 6), finished("c-done", .done, 15), started("c-run", parent: "p", depth: 2, 7),
        ])
        let shown = rows(tasks, SubagentTreeExpansion())
        let roots = shown.filter { $0.level == 0 }.map(\.task.id)
        #expect(roots == ["run-new", "p", "run-old", "bad", "old-done"], "도는 것(새것 먼저) → 실패 → 그 밖")
        let children = shown.filter { $0.level == 1 }.map(\.task.id)
        #expect(children == ["c-run", "c-done"], "자식은 부모 안에서만 같은 규칙으로 정렬한다")
        // 부모는 자식보다 앞에 오고, 실패한 형제가 있어도 자식이 다른 부모 밑으로 가지 않는다
        let p = shown.firstIndex { $0.task.id == "p" } ?? -1
        #expect(shown[p + 1].task.id == "c-run" && shown[p + 2].task.id == "c-done")
    }

    @Test func aSelfReferenceIsPlacedDirectlyUnderTheSession() {
        let tasks = list([started("loop", parent: "loop", depth: 2, 1), started("other", depth: 1, 2)])
        #expect(rows(tasks).allSatisfy { $0.level == 0 })
        #expect(rows(tasks).count == 2)
    }

    @Test func everyMemberOfACycleIsPlacedDirectlyUnderTheSessionAndTheirChildrenStayUnderThem() {
        let tasks = list([started("a", parent: "b", depth: 2, 1), started("b", parent: "a", depth: 2, 2), started("tail", parent: "a", depth: 3, 3), started("solo", depth: 1, 4)])
        let shown = rows(tasks, expandAll)
        #expect(shown.count == 4, "순환이 있어도 모든 일이 한 번씩 보인다")
        #expect(shown.first { $0.task.id == "a" }?.level == 0 && shown.first { $0.task.id == "b" }?.level == 0)
        #expect(shown.first { $0.task.id == "tail" }?.level == 1, "순환 밖의 자식은 부모 아래에 남는다")
        let a = shown.firstIndex { $0.task.id == "a" } ?? -1
        #expect(shown[a + 1].task.id == "tail")
    }

    @Test func aParentThatIsNotInThisSessionsListPlacesTheChildDirectlyUnderTheSession() {
        // 다른 세션의 일 id · 아직 오지 않은 시작 · 256개 상한으로 밀려난 부모: 이 목록에 없으면 선을 긋지 않는다
        let tasks = list([started("orphan", parent: "from-another-session", depth: 2, 1)])
        let shown = rows(tasks)
        #expect(ids(shown) == ["orphan"] && shown[0].level == 0)
        // 부모가 나중에 오면 선이 생긴다
        var later = tasks
        later.apply(started("from-another-session", depth: 1, 0))
        #expect(rows(later).first { $0.task.id == "orphan" }?.level == 1)
    }

    @Test func aDeepChainKeepsItsLevelsWhenExpanded() {
        let chain = (0..<6).map { index in started("n\(index)", parent: index == 0 ? nil : "n\(index - 1)", depth: index + 1, Double(index)) }
        let shown = rows(list(chain), expandAll)
        #expect(ids(shown) == ["n0", "n1", "n2", "n3", "n4", "n5"] && shown.map(\.level) == [0, 1, 2, 3, 4, 5])
    }

    @Test func theTwoHundredFiftySixCapKeepsTheTreeConsistentWhenAParentIsDropped() {
        // 가장 오래된 끝난 일부터 버린다: 부모가 버려지면 자식은 세션 바로 아래로 올라온다 (없는 부모로 선을 긋지 않는다)
        var events: [Event] = [started("root", depth: 1, 0), finished("root", .done, 1)]
        for index in 0..<BackgroundTaskList.maxTasks { events.append(started("c\(index)", parent: "root", depth: 2, Double(index + 2))) }
        let tasks = list(events)
        #expect(tasks.tasks.count == BackgroundTaskList.maxTasks)
        #expect(task(tasks, "root") == nil, "끝난 가장 오래된 일이 먼저 버려진다")
        let shown = rows(tasks, expandAll)
        #expect(shown.count == BackgroundTaskList.maxTasks && shown.allSatisfy { $0.level == 0 })
    }

    @Test func theTreeIsRebuiltFromTheListSoTheSameEventsGiveTheSameRows() {
        let events = [started("a", depth: 1, 1), started("n", parent: "a", depth: 2, 2), started("m", parent: "a", depth: 2, 3)]
        #expect(rows(list(events)) == rows(list(events + events)))
    }

    // MARK: 펼침 · 접힘

    private var expandAll: SubagentTreeExpansion { SubagentTreeExpansion(visibleLevels: 100) }

    @Test func byDefaultTwoLevelsAreShownAndDeeperBranchesAreFolded() {
        let tasks = list([started("a", depth: 1, 1), started("b", parent: "a", depth: 2, 2), started("c", parent: "b", depth: 3, 3), started("d", parent: "c", depth: 4, 4)])
        let shown = rows(tasks)
        #expect(ids(shown) == ["a", "b"], "세션 바로 아래와 그 자식까지: 2단계")
        #expect(shown[0].isExpanded && shown[0].hasChildren)
        #expect(!shown[1].isExpanded && shown[1].hasChildren)
        #expect(shown[1].branchSummary == "Running 2", "접힌 분기 아래의 도는 일(c · d)을 센다")
    }

    @Test func aFoldedBranchEndsWithTheCountsOfRunningAndFailedBelowItInExistingWordsOnly() {
        let tasks = list([
            started("a", depth: 1, 1), started("b", parent: "a", depth: 2, 2), started("r1", parent: "b", depth: 3, 3), started("r2", parent: "b", depth: 3, 4), started("f1", parent: "r1", depth: 4, 5),
            finished("f1", .failed, 9), started("ok", parent: "b", depth: 3, 6), finished("ok", .done, 10),
        ])
        let folded = rows(tasks).first { $0.task.id == "b" }
        #expect(folded?.isExpanded == false)
        #expect(folded?.branchSummary == "Running 2 · Failed 1", "아래 모든 단계의 도는 일 · 실패를 센다")
        #expect(folded?.branchSummary.map { $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == " " || $0 == "·" } } == true)
    }

    @Test func theSummaryLeavesOutAZeroCountAndIsGoneWhenNothingBelowIsRunningOrFailed() {
        func summary(_ tasks: BackgroundTaskList) -> String? { rows(tasks).first { $0.task.id == "b" }?.branchSummary }
        let onlyRunning = list([started("a", depth: 1, 1), started("b", parent: "a", depth: 2, 2), started("c", parent: "b", depth: 3, 3)])
        #expect(summary(onlyRunning) == "Running 1")
        let onlyFailed = list([started("a", depth: 1, 1), started("b", parent: "a", depth: 2, 2), started("c", parent: "b", depth: 3, 3), finished("c", .failed)])
        #expect(summary(onlyFailed) == "Failed 1")
        let quiet = list([started("a", depth: 1, 1), started("b", parent: "a", depth: 2, 2), started("c", parent: "b", depth: 3, 3), finished("c", .done)])
        #expect(summary(quiet) == nil)
        let stoppedOnly = list([started("a", depth: 1, 1), started("b", parent: "a", depth: 2, 2), started("c", parent: "b", depth: 3, 3), finished("c", .stopped)])
        #expect(summary(stoppedOnly) == nil, "멈춘 일은 세지 않는다: 도는 n · 실패 n뿐")
    }

    @Test func anExpandedBranchShowsItsChildrenAndNoSummary() {
        let tasks = list([started("a", depth: 1, 1), started("b", parent: "a", depth: 2, 2), started("c", parent: "b", depth: 3, 3)])
        var expansion = SubagentTreeExpansion()
        expansion.toggle(id: "b", level: 1)
        let shown = rows(tasks, expansion)
        #expect(ids(shown) == ["a", "b", "c"] && shown[1].isExpanded && shown[1].branchSummary == nil)
    }

    @Test func togglingFlipsTheDefaultAndTheChoiceSurvivesTheListChanging() {
        var tasks = list([started("a", depth: 1, 1), started("b", parent: "a", depth: 2, 2)])
        var expansion = SubagentTreeExpansion()
        expansion.toggle(id: "a", level: 0)
        #expect(ids(rows(tasks, expansion)) == ["a"], "펼쳐 있던 줄을 접었다")
        tasks.apply(started("c", parent: "a", depth: 2, 3))
        tasks.apply(finished("b"))
        #expect(ids(rows(tasks, expansion)) == ["a"], "갱신이 와도 고른 접힘은 그대로다")
        expansion.toggle(id: "a", level: 0)
        #expect(Set(ids(rows(tasks, expansion))) == ["a", "b", "c"])
        expansion.toggle(id: "a", level: 0)
        expansion.toggle(id: "a", level: 0)
        #expect(expansion.isExpanded(id: "a", level: 0))
    }

    @Test func aRowWithoutChildrenIsNeverExpandable() {
        let shown = rows(list([started("solo", depth: 1)]))
        #expect(shown[0].hasChildren == false && shown[0].branchSummary == nil)
    }

    @Test func pruningForgetsTheChoicesOfTasksThatAreGone() {
        var expansion = SubagentTreeExpansion()
        for id in ["keep", "gone-1", "gone-2"] { expansion.toggle(id: id, level: 0) }
        #expect(expansion.count == 3)
        expansion.prune(keeping: ["keep"])
        #expect(expansion.count == 1 && !expansion.isExpanded(id: "keep", level: 0), "남긴 일의 고른 접힘은 그대로다")
        expansion.prune(keeping: [])
        #expect(expansion.count == 0 && expansion.isExpanded(id: "keep", level: 0), "일이 사라지면 기본으로 돌아간다")
    }

    // MARK: 값이 글을 담지 않는다

    @Test func rowsAndExpansionNeverPrintNamesOrIds() {
        let tasks = list([started("secret-id", depth: 1, name: "A private name"), started("child-secret", parent: "secret-id", depth: 2, name: "Another private name")])
        let shown = rows(tasks)
        let dump = String(reflecting: shown) + String(describing: shown) + String(reflecting: SubagentTreeExpansion())
        #expect(!dump.contains("secret") && !dump.contains("private"))
    }
}
#endif
