#if os(macOS)
import Foundation
import Testing
@testable import TaskforceKit

/// 세션이 돌리는 백그라운드 일의 상태 기계 (DZ v2 E7–E9 · BG-1~BG-7): 시작 · 끝 · 스냅샷 · 이름 · 순서 · 띠의 말.
/// 기록(Claude 패널)과 스트림(Taskforce 패널)이 같은 사건 값으로 이 목록을 채운다. 사건은 되풀이돼도(앞 쪽을 다시 읽어도) 같은 결과다
struct BackgroundTaskListTests {
    typealias Event = BackgroundTaskEvent

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private func started(_ id: String, tool: String? = nil, kind: BackgroundTaskKind = .command, name: String? = nil, _ seconds: TimeInterval = 0) -> Event {
        .started(taskID: id, toolUseID: tool, kind: kind, name: name, at: at(seconds))
    }

    private func finished(_ id: String, _ status: BackgroundTaskStatus, code: Int? = nil, kind: BackgroundTaskKind? = .command, _ seconds: TimeInterval = 10) -> Event {
        .finished(taskID: id, kind: kind, status: status, exitCode: code, at: at(seconds))
    }

    /// 첫 일 (목록이 비어도 시험이 멈추지 않게 자리 값)
    private func only(_ list: BackgroundTaskList) -> BackgroundTask { list.tasks.first ?? BackgroundTask(id: "missing", kind: .other, name: nil) }

    private func list(_ events: [Event]) -> BackgroundTaskList {
        var list = BackgroundTaskList()
        for event in events { list.apply(event) }
        return list
    }

    // MARK: 시작 · 끝

    @Test func aStartedTaskRunsUntilItsFinish() {
        var tasks = list([started("a", tool: "tu1", name: "Run the dev server", 5)])
        #expect(tasks.tasks.map(\.status) == [.running] && only(tasks).name == "Run the dev server" && only(tasks).startedAt == at(5) && only(tasks).endedAt == nil)
        tasks.apply(finished("a", .done, code: 0, 65))
        #expect(only(tasks).status == .done && only(tasks).exitCode == 0 && only(tasks).endedAt == at(65))
        #expect(only(tasks).duration == 60)
    }

    @Test func aFailedFinishKeepsTheExitCode() {
        let tasks = list([started("a"), finished("a", .failed, code: 3, 12)])
        #expect(only(tasks).status == .failed && only(tasks).exitCode == 3)
    }

    @Test func aFinishWithoutAStartStillMakesATaskWithTheKindItCarries() {
        let tasks = list([finished("a", .done, code: 0, kind: .agent, 30)])
        #expect(tasks.tasks.count == 1 && only(tasks).kind == .agent && only(tasks).startedAt == nil && only(tasks).status == .done)
        #expect(only(tasks).duration == nil, "시작 시각을 모르면 걸린 시간을 지어내지 않는다")
    }

    @Test func theSameEventsAppliedAgainChangeNothing() {
        let events = [started("a", tool: "tu1", 1), started("b", kind: .agent, 2), finished("a", .failed, code: 2, 9), finished("b", .done, kind: .agent, 20)]
        let once = list(events)
        let twice = list(events + events)
        #expect(once == twice)
        #expect(once.tasks.count == 2)
    }

    @Test func aStartAfterAFinishDoesNotReopenTheTask() {
        // 앞 쪽을 나중에 읽으면 시작 줄이 끝 줄보다 늦게 들어올 수 있다
        let tasks = list([finished("a", .done, code: 0, 50), started("a", tool: "tu1", name: "Late name", 5)])
        #expect(tasks.tasks.count == 1 && only(tasks).status == .done && only(tasks).startedAt == at(5) && only(tasks).name == "Late name" && only(tasks).duration == 45)
    }

    @Test func aFinishedTaskNeverGoesBackToRunningAndAnAuthoritativeFinishBeatsStopped() {
        var tasks = list([started("a"), finished("a", .stopped, 5)])
        #expect(only(tasks).status == .stopped)
        tasks.apply(finished("a", .failed, code: 1, 8))
        #expect(only(tasks).status == .failed && only(tasks).exitCode == 1, "알림이 늦게 오면 멈춤을 고친다")
        tasks.apply(finished("a", .stopped, 20))
        #expect(only(tasks).status == .failed, "멈춤은 이미 정해진 끝을 덮지 않는다")
        tasks.apply(started("a"))
        #expect(only(tasks).status == .failed)
    }

    // MARK: 스냅샷 (`background_tasks_changed`)

    @Test func aRunningTaskMissingFromTheSnapshotIsStoppedUnlessItHasFinished() {
        var tasks = list([started("a", 1), started("b", 2), started("c", 3), finished("c", .done, code: 0, 9)])
        tasks.apply(.snapshot(runningTaskIDs: ["b"]))
        #expect(tasks.tasks.first { $0.id == "a" }?.status == .stopped)
        #expect(tasks.tasks.first { $0.id == "b" }?.status == .running)
        #expect(tasks.tasks.first { $0.id == "c" }?.status == .done)
    }

    /// 리뷰 P3: 스냅샷으로 멈춘 일 · 시각 없는 끝은 "지금" 끝난 것이다 (끝 시각이 없으면 "막 끝난 일은 열어 보기 전까지 남는다" 규칙이 거짓이 된다)
    @Test func aTaskStoppedByASnapshotEndsAtTheMomentItWasSeenMissing() {
        var tasks = list([started("a", 1), started("b", 2)])
        tasks.apply(.snapshot(runningTaskIDs: ["b"]), now: at(40))
        let stopped = tasks.tasks.first { $0.id == "a" }
        #expect(stopped?.status == .stopped && stopped?.endedAt == at(40), "멈춘 일은 알아챈 시각에 끝났다")
        #expect(stopped?.duration == 39)
        #expect(tasks.tasks.first { $0.id == "b" }?.endedAt == nil, "도는 일은 끝 시각이 없다")
        // 그 전에 목록을 열어 본 적이 있어도(열어 본 시각 < 멈춘 시각) 막 끝난 일은 본 것이 아니다
        #expect(BackgroundTaskVisibility.isVisible(tasks: tasks.tasks.filter { $0.id == "a" }, openedAt: at(30)))
        #expect(!BackgroundTaskVisibility.isVisible(tasks: tasks.tasks.filter { $0.id == "a" }, openedAt: at(45)))
    }

    @Test func aFinishWithoutATimeEndsAtTheTimeItWasApplied() {
        var tasks = list([started("a", 1)])
        tasks.apply(.finished(taskID: "a", kind: .command, status: .done, exitCode: 0, at: nil), now: at(50))
        #expect(only(tasks).status == .done && only(tasks).endedAt == at(50) && only(tasks).duration == 49)
        // 시작 줄 없이 끝 줄만 온 일도 같다
        tasks.apply(.finished(taskID: "z", kind: .agent, status: .failed, exitCode: nil, at: nil), now: at(70))
        #expect(tasks.tasks.first { $0.id == "z" }?.endedAt == at(70))
    }

    @Test func aFinishTimeThatIsKnownIsNeverReplacedByTheApplyTime() {
        var tasks = list([started("a", 1)])
        tasks.apply(finished("a", .done, code: 0, 20), now: at(99))
        #expect(only(tasks).endedAt == at(20))
        tasks.apply(.snapshot(runningTaskIDs: []), now: at(120))
        #expect(only(tasks).status == .done && only(tasks).endedAt == at(20), "끝난 일은 스냅샷에 없어도 그대로다")
    }

    /// 리뷰 P3: `task_updated`(상태만)가 `task_notification`(끝낸 코드 · 종류)보다 먼저 온다. 늦게 온 값은 비어 있던 칸을 채운다
    @Test func theExitCodeAndKindAreFilledInWhenALaterLineBringsThemAfterTheTaskFinished() {
        var tasks = list([started("a", kind: .other, 1)])
        tasks.apply(.finished(taskID: "a", kind: nil, status: .failed, exitCode: nil, at: at(10)), now: at(10))
        #expect(only(tasks).status == .failed && only(tasks).exitCode == nil && only(tasks).kind == .other)
        tasks.apply(.finished(taskID: "a", kind: .command, status: .failed, exitCode: 3, at: at(11)), now: at(11))
        #expect(only(tasks).exitCode == 3 && only(tasks).kind == .command && only(tasks).endedAt == at(10), "끝 시각은 먼저 안 값이 이긴다")
        tasks.apply(.finished(taskID: "a", kind: .agent, status: .failed, exitCode: 9, at: at(12)), now: at(12))
        #expect(only(tasks).exitCode == 3 && only(tasks).kind == .command, "이미 있는 값은 덮지 않는다")
    }

    @Test func aLateExitCodeOfADifferentOutcomeIsNotBorrowed() {
        var tasks = list([started("a", 1), finished("a", .done, code: nil, kind: nil, 10)])
        tasks.apply(.finished(taskID: "a", kind: .command, status: .failed, exitCode: 7, at: at(11)), now: at(11))
        #expect(only(tasks).status == .done && only(tasks).exitCode == nil, "다른 끝의 코드는 가져오지 않는다 (끝난 상태는 알림으로만 고친다)")
        tasks.apply(.finished(taskID: "a", kind: .command, status: .done, exitCode: 0, at: at(12)), now: at(12))
        #expect(only(tasks).exitCode == 0)
    }

    @Test func aSnapshotAfterTheFinishNeverTurnsADoneTaskIntoAStoppedOne() {
        // 실측(2.1.308): task_updated → task_notification → background_tasks_changed [남은 일] 순서다
        var tasks = list([started("a", 1), started("b", 2)])
        tasks.apply(finished("a", .done, code: nil, kind: nil, 20), now: at(20))
        tasks.apply(.finished(taskID: "a", kind: .command, status: .done, exitCode: 0, at: at(20)), now: at(20))
        tasks.apply(.snapshot(runningTaskIDs: ["b"]), now: at(20))
        #expect(tasks.tasks.first { $0.id == "a" }?.status == .done && tasks.tasks.first { $0.id == "a" }?.exitCode == 0)
        #expect(tasks.tasks.first { $0.id == "b" }?.status == .running)
        tasks.apply(.snapshot(runningTaskIDs: []), now: at(40))
        #expect(tasks.tasks.first { $0.id == "b" }?.status == .stopped && tasks.tasks.first { $0.id == "b" }?.endedAt == at(40))
    }

    @Test func aSnapshotNamingAnUnknownTaskDoesNotMakeOne() {
        var tasks = BackgroundTaskList()
        tasks.apply(.snapshot(runningTaskIDs: ["ghost"]))
        #expect(tasks.tasks.isEmpty, "스냅샷의 이름만으로는 일의 종류 · 이름을 모른다")
    }

    // MARK: 이름

    @Test func namesAreResolvedFromTheToolStepByToolUseIdAndNeverOverwriteAKnownName() {
        var tasks = list([started("a", tool: "tu1"), started("b", tool: "tu2", name: "Known"), started("c")])
        tasks.resolveNames { toolID in ["tu1": "Run the dev server", "tu2": "Other"][toolID] }
        #expect(tasks.tasks.map(\.name) == ["Run the dev server", "Known", nil])
    }

    @Test func theTitleIsTheNameOrTheToolNameForItsKind() {
        #expect(BackgroundTask(id: "a", kind: .command, name: "Run it").title == "Run it")
        #expect(BackgroundTask(id: "a", kind: .command, name: nil).title == "Bash")
        #expect(BackgroundTask(id: "a", kind: .agent, name: " ").title == "Agent", "공백뿐인 이름은 이름이 아니다")
        #expect(BackgroundTask(id: "a", kind: .other, name: nil).title == "Task")
    }

    @Test func theKindWordAndTheStatusWordsAreTheApprovedOnes() {
        #expect(BackgroundTaskKind.command.word == "Command" && BackgroundTaskKind.agent.word == "Agent" && BackgroundTaskKind.other.word == "Task")
        #expect(BackgroundTaskStatus.running.word == "Running" && BackgroundTaskStatus.done.word == "Done" && BackgroundTaskStatus.failed.word == "Failed" && BackgroundTaskStatus.stopped.word == "Stopped")
    }

    // MARK: 순서 · 띠의 말

    @Test func theListIsRunningThenFailedThenTheRestAndTheNewestComeFirstWithinEach() {
        let tasks = list([
            started("done-old", 1), finished("done-old", .done, code: 0, 20),
            started("run-old", 2), started("run-new", 30),
            started("failed", 3), finished("failed", .failed, code: 1, 25),
            started("done-new", 4), finished("done-new", .done, code: 0, 40),
            started("stopped", 5), finished("stopped", .stopped, 35),
        ])
        #expect(tasks.ordered.map(\.id) == ["run-new", "run-old", "failed", "done-new", "stopped", "done-old"])
    }

    @Test func theStripWordIsRunningThenFailedThenStoppedThenDone() {
        #expect(list([started("a"), started("b"), finished("b", .failed, code: 1)]).stripStatus == .running, "도는 일이 있으면 Running")
        #expect(list([started("a"), finished("a", .failed, code: 1), started("b"), finished("b", .done, code: 0)]).stripStatus == .failed)
        #expect(list([started("a"), finished("a", .stopped), started("b"), finished("b", .done, code: 0)]).stripStatus == .stopped)
        #expect(list([started("a"), finished("a", .done, code: 0)]).stripStatus == .done)
        #expect(BackgroundTaskList().stripStatus == nil)
    }

    @Test func theAccessibleNameCountsTheRunningOnesOnlyThereAndNeverOnScreen() {
        #expect(list([started("a"), started("b")]).accessibleName == "Background tasks, 2 running")
        #expect(list([started("a"), finished("a", .done, code: 0)]).accessibleName == "Background tasks, Done")
        #expect(list([started("a"), finished("a", .failed, code: 1)]).accessibleName == "Background tasks, Failed")
        #expect(BackgroundTaskList().accessibleName == "Background tasks")
        #expect(list([started("a")]).runningCount == 1)
    }

    @Test func aRowReadsKindStatusAndTimeInOneLine() {
        let task = BackgroundTask(id: "a", kind: .command, name: "Run", status: .failed, exitCode: 3, startedAt: at(0), endedAt: at(12))
        #expect(task.meta(now: at(100)) == "Command · Failed · Exit code 3 · 12s")
        let running = BackgroundTask(id: "b", kind: .agent, name: "Audit", status: .running, startedAt: at(0))
        #expect(running.meta(now: at(134)) == "Agent · Running · 2:14")
        let done = BackgroundTask(id: "c", kind: .command, name: "x", status: .done, exitCode: 0, startedAt: at(0), endedAt: at(252))
        #expect(done.meta(now: at(900)) == "Command · Done · 4m 12s")
        let unknownStart = BackgroundTask(id: "d", kind: .other, name: nil, status: .running)
        #expect(unknownStart.meta(now: at(900)) == "Task · Running", "시작을 모르면 시간을 지어내지 않는다")
        let stopped = BackgroundTask(id: "e", kind: .command, name: "x", status: .stopped, startedAt: at(0), endedAt: at(70))
        #expect(stopped.meta(now: at(900)) == "Command · Stopped · 1m 10s")
        let failedNoCode = BackgroundTask(id: "f", kind: .agent, name: "x", status: .failed, startedAt: at(0), endedAt: at(9))
        #expect(failedNoCode.meta(now: at(900)) == "Agent · Failed · 9s", "끝낸 코드를 모르면 코드 말을 쓰지 않는다")
        #expect(task.accessibleName(now: at(100)) == "Command, Run, Failed")
    }

    @Test func aTaskStillRunningWhenTheSessionClosesIsStoppedAndTheRestKeepTheirEnd() {
        let tasks = list([started("a", 1), started("b", 2), finished("b", .done, code: 0, 9)])
        let closed = tasks.closed(at: at(60))
        #expect(closed.tasks.first { $0.id == "a" }?.status == .stopped && closed.tasks.first { $0.id == "a" }?.endedAt == at(60))
        #expect(closed.tasks.first { $0.id == "b" }?.status == .done)
        #expect(tasks.tasks.first { $0.id == "a" }?.status == .running, "원본은 그대로다")
    }

    // MARK: 한도

    @Test func theListIsBoundedAndDropsTheOldestFinishedFirst() {
        var tasks = BackgroundTaskList()
        for n in 0..<(BackgroundTaskList.maxTasks + 40) {
            tasks.apply(started("t\(n)", Double(n)))
            if n % 2 == 0 { tasks.apply(finished("t\(n)", .done, code: 0, Double(n) + 0.5)) }
        }
        #expect(tasks.tasks.count == BackgroundTaskList.maxTasks)
        #expect(tasks.tasks.contains { $0.id == "t\(BackgroundTaskList.maxTasks + 39)" }, "가장 새 일은 남는다")
        #expect(tasks.runningCount > 0)
        #expect(tasks.tasks.filter { $0.status == .running }.count == tasks.runningCount)
    }

    @Test func hostileIdsAndNamesAreStoredAsPlainBoundedText() {
        let tasks = list([.started(taskID: "a", toolUseID: nil, kind: .command, name: String(repeating: "n", count: 5000) + "\u{202E}\n", at: t0)])
        #expect((only(tasks).name ?? "").count <= ExternalSessionRules.maxTitleUTF16)
        #expect(!(only(tasks).name ?? "").unicodeScalars.contains("\u{202E}") && !(only(tasks).name ?? "").contains("\n"))
    }

    @Test func descriptionNeverPrintsIdsNamesOrCommands() {
        let tasks = list([started("secret-task-id", tool: "secret-tool-id", name: "A private name")])
        let text = String(describing: tasks) + String(reflecting: tasks) + String(describing: only(tasks)) + String(reflecting: only(tasks))
        #expect(!text.contains("secret-task-id") && !text.contains("secret-tool-id") && !text.contains("A private name"))
    }
}

/// "열어 본 뒤까지 남는다" (DZ v2 E7 · 열린 질문 7): 띠는 도는 일이 있거나, 막 끝난 일을 사용자가 아직 열어 보지 않았을 때만 있다. 열어 본 시각은 이 Mac에만 둔다
struct BackgroundTaskVisibilityTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private func task(_ id: String, _ status: BackgroundTaskStatus, start: TimeInterval? = 0, end: TimeInterval? = nil) -> BackgroundTask {
        BackgroundTask(id: id, kind: .command, name: nil, status: status, startedAt: start.map(at), endedAt: end.map(at))
    }

    @Test func noTasksNoStrip() {
        #expect(!BackgroundTaskVisibility.isVisible(tasks: [], openedAt: nil))
        #expect(!BackgroundTaskVisibility.isVisible(tasks: [], openedAt: at(5)))
    }

    @Test func aRunningTaskAlwaysShowsTheStripEvenAfterItWasOpened() {
        #expect(BackgroundTaskVisibility.isVisible(tasks: [task("a", .running)], openedAt: nil))
        #expect(BackgroundTaskVisibility.isVisible(tasks: [task("a", .running)], openedAt: at(1_000)))
    }

    @Test func aFinishedTaskStaysUntilTheListIsOpenedOnce() {
        let done = [task("a", .done, end: 50)]
        #expect(BackgroundTaskVisibility.isVisible(tasks: done, openedAt: nil))
        #expect(BackgroundTaskVisibility.isVisible(tasks: done, openedAt: at(40)), "열어 본 뒤에 끝난 일은 새 것이다")
        #expect(!BackgroundTaskVisibility.isVisible(tasks: done, openedAt: at(60)))
        #expect(!BackgroundTaskVisibility.isVisible(tasks: done, openedAt: at(50)), "끝난 순간에 연 것은 본 것이다")
    }

    @Test func aNewTaskAfterTheOpenBringsTheStripBackAndTheLatestEndDecides() {
        let tasks = [task("old", .failed, end: 20), task("new", .done, end: 90)]
        #expect(BackgroundTaskVisibility.isVisible(tasks: tasks, openedAt: at(60)))
        #expect(!BackgroundTaskVisibility.isVisible(tasks: tasks, openedAt: at(100)))
        #expect(BackgroundTaskVisibility.isVisible(tasks: tasks + [task("run", .running)], openedAt: at(100)))
    }

    @Test func aFinishedTaskWithoutAnEndTimeCountsAsUnseenOnlyUntilTheFirstOpen() {
        let done = [task("a", .stopped, end: nil)]
        #expect(BackgroundTaskVisibility.isVisible(tasks: done, openedAt: nil))
        #expect(!BackgroundTaskVisibility.isVisible(tasks: done, openedAt: at(1)))
    }

    // MARK: 저장 (이 Mac)

    @Test func theMemoryStoreRemembersTheOpenTimePerSessionAndForgetsOnClear() {
        let store = InMemoryBackgroundTaskOpenStore()
        #expect(store.openedAt(session: "s1") == nil)
        store.markOpened(session: "s1", at: at(5))
        store.markOpened(session: "s2", at: at(9))
        #expect(store.openedAt(session: "s1") == at(5) && store.openedAt(session: "s2") == at(9))
        store.markOpened(session: "s1", at: at(20))
        #expect(store.openedAt(session: "s1") == at(20))
        store.clear()
        #expect(store.openedAt(session: "s1") == nil)
    }

    @Test func theDefaultsStoreSurvivesANewInstanceAndKeepsOnlyTheNewestSessions() {
        let defaults = FakeRailDefaults()
        let first = UserDefaultsBackgroundTaskOpenStore(defaults: defaults)
        first.markOpened(session: "s1", at: at(5))
        #expect(UserDefaultsBackgroundTaskOpenStore(defaults: defaults).openedAt(session: "s1") == at(5))
        for n in 0..<(UserDefaultsBackgroundTaskOpenStore.maxSessions + 10) { first.markOpened(session: "n\(n)", at: at(Double(100 + n))) }
        let reloaded = UserDefaultsBackgroundTaskOpenStore(defaults: defaults)
        #expect(reloaded.openedAt(session: "s1") == nil, "가장 오래된 표시부터 버린다")
        #expect(reloaded.openedAt(session: "n\(UserDefaultsBackgroundTaskOpenStore.maxSessions + 9)") != nil)
        reloaded.clear()
        #expect(UserDefaultsBackgroundTaskOpenStore(defaults: defaults).openedAt(session: "n3") == nil)
    }

    @Test func aBrokenSavedValueStartsEmptyAndIsNotACrash() {
        let defaults = FakeRailDefaults()
        defaults.set(Data("not json".utf8), forKey: UserDefaultsBackgroundTaskOpenStore.key)
        #expect(UserDefaultsBackgroundTaskOpenStore(defaults: defaults).openedAt(session: "s1") == nil)
        defaults.set("a string", forKey: UserDefaultsBackgroundTaskOpenStore.key)
        #expect(UserDefaultsBackgroundTaskOpenStore(defaults: defaults).openedAt(session: "s1") == nil)
    }
}
#endif
