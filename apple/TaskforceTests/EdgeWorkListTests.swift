import Auth
import AppKit
import Foundation
import Supabase
import Testing
@testable import Taskforce
@testable import TaskforceKit
@testable import TaskforceUI

/// 0.2.0 All work (S3)의 셸 상태: 계정이 바뀌면 검색어 · 필터 · 열린 필터 · 고정이 따라 바뀐다, 레일의 All work는 필터를 비운다,
/// Esc는 필터 카드부터, 고정 셋, Done today 날짜 경계, 받은 목록이 없으면 빈 화면이 아니다
@MainActor
struct EdgeWorkListTests {
    static func action(_ n: Int, started: Bool = false, status: ActionStatus = .open) -> ActionSummary {
        EdgeShellModelTests.action(n, started: started, status: status)
    }

    let alice = UUID(uuidString: "A11CE000-0000-4000-8000-000000000001")!
    let bob = UUID(uuidString: "B0B00000-0000-4000-8000-000000000002")!

    func model(store: WorkPinStore = WorkPinStore(defaults: nil)) -> EdgeShellModel {
        let shell = EdgeShellModel(schedule: { _, _ in EdgeTimer() }, clock: { Date() }, pinStore: store)
        shell.update(EdgeWorkSnapshot(open: (1...5).map { Self.action($0) }, load: .loaded(problem: nil)))
        return shell
    }

    // MARK: 계정 경계

    @Test func accountChangeClearsSearchFiltersAndLoadsThatAccountsPins() {
        let shell = model()
        shell.accountChanged(alice)
        shell.setFilter(WorkFilter(query: "launch", status: .toDo))
        shell.setFiltersOpen(true)
        shell.open(itemID: Self.action(2).id)
        shell.pin(Self.action(1).id)
        #expect(shell.pins.ids == [Self.action(1).id])

        // 다른 계정: 전 계정의 검색어 · 필터 · 열린 필터 · 고른 행 · 고정이 남지 않는다
        shell.accountChanged(bob)
        #expect(shell.workFilter == WorkFilter())
        #expect(!shell.filtersOpen)
        #expect(shell.currentID == nil)
        #expect(shell.pins.ids.isEmpty)
        shell.pin(Self.action(3).id)

        // 돌아오면 그 계정의 고정만 (검색어 · 필터는 다시 비어 있다)
        shell.accountChanged(alice)
        #expect(shell.pins.ids == [Self.action(1).id])
        #expect(shell.workFilter == WorkFilter())
        shell.accountChanged(bob)
        #expect(shell.pins.ids == [Self.action(3).id])
    }

    @Test func signedOutHasNoPinsAndCannotPin() {
        let shell = model()
        shell.accountChanged(alice)
        shell.pin(Self.action(1).id)
        shell.accountChanged(nil)
        #expect(shell.pins.ids.isEmpty)
        shell.pin(Self.action(2).id)
        #expect(shell.pins.ids.isEmpty)
        shell.accountChanged(alice)
        #expect(shell.pins.ids == [Self.action(1).id])
    }

    /// 토큰 갱신처럼 같은 계정이면 검색어 · 필터를 그대로 둔다
    @Test func sameAccountKeepsTheState() {
        let shell = model()
        shell.accountChanged(alice)
        shell.setFilter(WorkFilter(query: "report"))
        shell.setFiltersOpen(true)
        shell.accountChanged(alice)
        #expect(shell.workFilter.query == "report")
        #expect(shell.filtersOpen)
    }

    /// 앱을 다시 열어도 그 계정의 고정이 남는다 (계정마다 따로). 디스크 대신 같은 메모리 저장을 두 저장소가 나눠 쓴다
    /// (`~/Library/Preferences`에 파일을 남기지 않는다)
    @Test func pinsSurviveARestartPerAccount() {
        let disk = MemoryPinStorage()
        let first = model(store: WorkPinStore(storage: disk))
        first.accountChanged(alice)
        first.pin(Self.action(4).id)
        let second = model(store: WorkPinStore(storage: disk))
        second.accountChanged(alice)
        #expect(second.pins.ids == [Self.action(4).id])
        second.accountChanged(bob)
        #expect(second.pins.ids.isEmpty)
    }

    /// 계정이 떠나면(로그아웃 · 다른 계정) 이 Mac의 고정을 모두 지운다. 실제 `SessionStore`를 이 기기 저장소만으로 로그인 · 로그아웃 (리뷰 L5)
    @Test func pinsAreRemovedWhenTheAccountLeaves() throws {
        let accounts = try ProfileTestAccounts(signedIn: alice)
        let store = WorkPinStore(storage: MemoryPinStorage())
        EdgeShellController.removePinsWhenAccountLeaves(accounts.session, store: store)
        store.save(WorkPins([Self.action(1).id]), account: alice)
        // 같은 계정의 토큰 갱신 같은 것은 지우지 않는다
        try accounts.signIn(alice)
        #expect(store.load(account: alice).ids == [Self.action(1).id])
        accounts.signOut()
        #expect(store.load(account: alice).ids.isEmpty)
        // 다른 계정으로 바꿔도 전 계정 고정은 남지 않는다
        try accounts.signIn(bob)
        store.save(WorkPins([Self.action(2).id]), account: bob)
        try accounts.signIn(alice)
        #expect(store.load(account: bob).ids.isEmpty)
    }

    // MARK: 고정

    @Test func shellPinsAtMostThreeOfTheListedWork() {
        let shell = model()
        shell.accountChanged(alice)
        for n in 1...4 { shell.pin(Self.action(n).id) }
        #expect(shell.pins.ids == (1...3).map { Self.action($0).id })
        // 목록에 없는 일은 고정하지 않는다
        shell.unpin(Self.action(2).id)
        shell.pin(Self.action(99).id)
        #expect(shell.pins.ids == [Self.action(1).id, Self.action(3).id])
        // 고정한 일은 그 묶음 맨 앞
        let groups = WorkListLayout.groups(shell.workItems, filter: shell.workFilter, pinned: shell.pins.shown(in: shell.workItems))
        #expect(groups.first?.items.prefix(2).map(\.id) == [Self.action(1).id, Self.action(3).id])
    }

    // MARK: 열기 · 키

    /// 레일에서 연 일이 남은 검색어 · 필터에 가리면 비우고 연다. 가리지 않으면 그대로 둔다 (리뷰 M1)
    @Test func openingAnItemClearsFiltersThatHideIt() {
        let shell = EdgeShellModel(schedule: { _, _ in EdgeTimer() }, clock: { Date() })
        let running = Self.action(1, started: true)
        shell.update(EdgeWorkSnapshot(open: [running, Self.action(2)], working: [running.id], load: .loaded(problem: nil)))
        shell.openAllWork()
        shell.setFilter(WorkFilter(status: .done))
        shell.setFiltersOpen(true)
        shell.open(itemID: running.id)
        #expect(shell.currentID == running.id)
        #expect(shell.workFilter == WorkFilter())
        let groups = WorkListLayout.groups(shell.workItems, filter: shell.workFilter, pinned: [])
        #expect(groups.flatMap(\.items).contains { $0.id == running.id })
        // 검색어가 가려도 비운다
        shell.setFilter(WorkFilter(query: "nothing like this"))
        shell.open(itemID: running.id)
        #expect(shell.workFilter == WorkFilter())
        // 이미 보이면 사용자가 고른 필터를 그대로 둔다
        shell.setFilter(WorkFilter(status: .inProgress))
        shell.open(itemID: running.id)
        #expect(shell.workFilter == WorkFilter(status: .inProgress))
    }

    /// 레일의 All work(⌘2)는 검색어 · 필터를 비우고 연다. ⌥ Space로 다시 열면 그대로 (접어도 남는다)
    @Test func allWorkFromTheRailOpensWithFiltersCleared() {
        let shell = model()
        shell.openAllWork()
        shell.setFilter(WorkFilter(query: "deck", project: .ungrouped, status: .waiting))
        shell.setFiltersOpen(true)
        shell.dismiss()
        shell.togglePanel()
        #expect(shell.workFilter.query == "deck" && shell.filtersOpen)
        shell.openAllWork()
        #expect(shell.workFilter == WorkFilter())
        #expect(!shell.filtersOpen)
    }

    /// Esc: 열린 필터 카드를 먼저 닫고, 다음 Esc가 패널을 접는다
    @Test func escapeClosesTheFilterCardBeforeThePanel() {
        let shell = model()
        shell.openAllWork()
        shell.setFiltersOpen(true)
        shell.escape()
        #expect(shell.panelOpen && !shell.filtersOpen)
        shell.escape()
        #expect(!shell.panelOpen)
        // 필터가 닫혀 있으면 바로 접는다
        shell.openAllWork()
        shell.escape()
        #expect(!shell.panelOpen)
    }

    // MARK: 데이터

    /// Done today는 읽은 날이 기기 시간대의 오늘일 때만: 자정이 지나면 다시 읽을 때까지 없다
    @Test func doneTodayDisappearsAfterLocalMidnightUntilReloaded() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Seoul"))
        let readAt = try Date("2026-10-10T14:30:00Z", strategy: .iso8601)
        let since = calendar.startOfDay(for: readAt)
        let work = EdgeWorkSnapshot(open: [Self.action(1)], doneToday: [Self.action(2, status: .done)], load: .loaded(problem: nil), doneSince: since)
        #expect(work.items(now: readAt, calendar: calendar).map(\.state) == [.toDo, .done])
        let afterMidnight = try Date("2026-10-10T15:00:01Z", strategy: .iso8601)
        #expect(work.items(now: afterMidnight, calendar: calendar).map(\.state) == [.toDo])
        // 읽은 날을 모르면 Done today가 없다
        #expect(EdgeWorkSnapshot(doneToday: [Self.action(2, status: .done)]).items(now: readAt, calendar: calendar).isEmpty)
    }

    // MARK: 시각이 바뀜 (Codex 최종 delta P2): 열린 채 기다리는 패널
    // 가짜 시계 · 달력 · NotificationCenter만 쓴다 (실제 시스템 시계 · 시간대는 바꾸지 않는다). `withObservationTracking`이 패널(SwiftUI)이 하는 읽기를 대신한다

    /// 손으로 돌리는 시각 · 달력
    final class FakeTime: @unchecked Sendable {
        var now: Date
        var calendar: Calendar

        init(now: Date, timeZone: TimeZone) {
            self.now = now
            calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
        }
    }

    /// 관찰 콜백 · 감시 알림이 불린 수와 차례
    final class Probe: @unchecked Sendable {
        var changes = 0
        var events: [String] = []
    }

    struct Mounted {
        let shell: EdgeShellModel
        let time: FakeTime
        let center: CountingCenter
        let workspace: CountingCenter
        let probe: Probe
        let watcher: EdgeTimeWatcher
    }

    /// 읽은 날(Done today 하나 + 열린 일 하나)을 보이는 모델 + 시간 신호를 모델에 올리는 감시자 (컨트롤러가 하는 배선)
    func mounted(readAt: String = "2026-10-10T14:30:00Z", timeZone: String = "Asia/Seoul") throws -> Mounted {
        let time = FakeTime(now: try Date(readAt, strategy: .iso8601), timeZone: try #require(TimeZone(identifier: timeZone)))
        let shell = EdgeShellModel(schedule: { _, _ in EdgeTimer() }, clock: { time.now }, calendar: { time.calendar })
        shell.update(Self.readWork(since: time.calendar.startOfDay(for: time.now)))
        let probe = Probe()
        let center = CountingCenter()
        let workspace = CountingCenter()
        let watcher = EdgeTimeWatcher(center: center, workspaceCenter: workspace, queue: nil, resetTimeZone: { probe.events.append("reset") }) {
            probe.events.append("changed")
            shell.timeChanged()
        }
        watcher.start()
        return Mounted(shell: shell, time: time, center: center, workspace: workspace, probe: probe, watcher: watcher)
    }

    static func readWork(since: Date) -> EdgeWorkSnapshot {
        EdgeWorkSnapshot(open: [action(1)], doneToday: [action(2, status: .done)], load: .loaded(problem: nil), doneSince: since)
    }

    /// 열린 채 자정을 넘는다: 관련 없는 상태 변화가 없어도 날짜 변경 알림 하나로 패널의 읽기가 무효가 되고, 새 값에는 지난 Done today가 없다
    @Test func mountedPanelFollowsLocalMidnightWithoutAnyOtherChange() throws {
        let m = try mounted()
        let observed = Probe()
        let before = withObservationTracking { m.shell.workItems.map(\.state) } onChange: { observed.changes += 1 }
        #expect(before == [.toDo, .done])

        // 시계만 자정을 넘긴다: 신호가 없으면 다시 계산하지 않는다 (폴링 · 타이머 없음)
        m.time.now = try Date("2026-10-10T15:00:01Z", strategy: .iso8601)
        #expect(observed.changes == 0)

        m.center.post(name: .NSCalendarDayChanged, object: nil)
        #expect(observed.changes == 1)
        #expect(m.shell.workItems.map(\.state) == [.toDo])
        // 목록은 다시 읽지 않았다: 받은 목록(work)은 그대로고 보이는 줄만 다시 계산했다
        #expect(m.shell.work.doneToday.map(\.id) == [Self.action(2).id])

        // 허용된 새로 읽기(받은 목록의 doneSince가 새 날)가 오면 오늘 끝낸 일이 다시 보인다
        m.shell.update(Self.readWork(since: m.time.calendar.startOfDay(for: m.time.now)))
        #expect(m.shell.workItems.map(\.state) == [.toDo, .done])
    }

    /// 시간대가 바뀐다: 같은 시각이 다른 날이 되면 지난 Done today를 뺀다. 캐시된 시스템 시간대를 먼저 비운 뒤 알린다
    @Test func timeZoneChangeInvalidatesMountedPanelAfterResettingTheCachedZone() throws {
        let m = try mounted(readAt: "2026-10-10T03:00:00Z") // 서울 12:00
        let observed = Probe()
        let before = withObservationTracking { m.shell.workItems.map(\.state) } onChange: { observed.changes += 1 }
        #expect(before == [.toDo, .done])

        m.time.calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles")) // 같은 시각이 로스앤젤레스에서는 전날 20시
        #expect(observed.changes == 0)
        m.center.post(name: .NSSystemTimeZoneDidChange, object: nil)
        #expect(observed.changes == 1)
        #expect(m.probe.events == ["reset", "changed"])
        #expect(m.shell.workItems.map(\.state) == [.toDo])
    }

    /// 시스템 시계를 고치거나 Mac이 깨어나도 같다 (자정을 자는 동안 넘었을 수 있다)
    @Test func systemClockChangeAndWakeInvalidateToo() throws {
        for signal in ["clock", "wake"] {
            let m = try mounted()
            let observed = Probe()
            let before = withObservationTracking { m.shell.workItems.map(\.state) } onChange: { observed.changes += 1 }
            #expect(before == [.toDo, .done], Comment(rawValue: signal))
            m.time.now = try Date("2026-10-11T01:00:00Z", strategy: .iso8601)
            if signal == "clock" {
                m.center.post(name: .NSSystemClockDidChange, object: nil)
            } else {
                m.workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
            }
            #expect(observed.changes == 1, Comment(rawValue: signal))
            #expect(m.shell.workItems.map(\.state) == [.toDo], Comment(rawValue: signal))
            #expect(m.probe.events == ["changed"], Comment(rawValue: signal))
        }
    }

    /// 구독은 켜면 한 번만 걸리고, 멈추거나 해제하면 모두 걷힌다 (다시 켜도 겹치지 않는다)
    @Test func observersAreRegisteredOnceAndRemovedOnStopAndRelease() {
        let center = CountingCenter()
        let workspace = CountingCenter()
        let probe = Probe()
        var watcher: EdgeTimeWatcher? = EdgeTimeWatcher(center: center, workspaceCenter: workspace, queue: nil, resetTimeZone: {}) { probe.changes += 1 }
        func postAll() {
            for name in [Notification.Name.NSCalendarDayChanged, .NSSystemTimeZoneDidChange, .NSSystemClockDidChange] { center.post(name: name, object: nil) }
            workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        }
        #expect(center.active == 0 && workspace.active == 0)
        #expect(watcher?.isWatching == false)
        postAll()
        #expect(probe.changes == 0)

        watcher?.start()
        watcher?.start() // 겹쳐 불려도 한 번만 건다
        #expect(watcher?.isWatching == true)
        #expect(center.active == 3 && workspace.active == 1)
        postAll()
        #expect(probe.changes == 4)

        watcher?.stop()
        watcher?.stop()
        #expect(watcher?.isWatching == false)
        #expect(center.active == 0 && workspace.active == 0)
        postAll()
        #expect(probe.changes == 4)

        watcher?.start() // 멈춘 뒤 다시 켜도 알림 하나에 콜백 하나
        #expect(center.active == 3 && workspace.active == 1)
        center.post(name: .NSCalendarDayChanged, object: nil)
        #expect(probe.changes == 5)

        watcher = nil // 해제하면 걷힌다
        #expect(center.active == 0 && workspace.active == 0)
        postAll()
        #expect(probe.changes == 5)
    }

    /// 다른 스레드가 올린 알림이 main 큐에 들어간 채 아직 돌지 않았을 때 정지하면, 정지 뒤에 돌지 않는다 (걷힌 관찰자의 대기 중인 블록은 Foundation이 돌리지 않는다).
    /// Foundation은 큐 관찰자에게 알림을 넣고 그 블록이 끝날 때까지 올린 쪽을 기다린다. main이 막혀 있는 동안은 큐에 있을 뿐이다
    @Test func notificationQueuedBeforeStopDoesNotRunAfterIt() async throws {
        let center = CountingCenter()
        let probe = Probe()
        let watcher = EdgeTimeWatcher(center: center, workspaceCenter: CountingCenter(), queue: .main, resetTimeZone: {}) { probe.changes += 1 }
        watcher.start()
        Self.postFromBackgroundWhileMainIsBlocked(center)
        #expect(probe.changes == 0) // 큐에 들어갔을 뿐 main이 막혀 있어 아직 돌지 않았다
        watcher.stop()
        try await Task.sleep(for: .milliseconds(200))
        #expect(probe.changes == 0)

        watcher.start() // 다시 켜면 정상으로 돈다 (main 스레드에서 올리면 바로 돈다)
        center.post(name: .NSCalendarDayChanged, object: nil)
        #expect(probe.changes == 1)
        watcher.stop()
    }

    /// 다른 스레드에서 날짜 변경 알림을 올리게 하고, 큐에 들어갈 때까지 main을 막은 채 기다린다
    nonisolated static func postFromBackgroundWhileMainIsBlocked(_ center: NotificationCenter) {
        let thread = Thread { center.post(name: .NSCalendarDayChanged, object: nil) }
        thread.start()
        Thread.sleep(forTimeInterval: 0.1)
    }

    /// 연결을 읽기 전에는 Connect a source를 보이지 않는다. 읽었고 active 연결이 없을 때만 (리뷰 L11)
    @Test func connectASourceOnlyWhenNoActiveConnectionIsKnown() {
        func record(_ status: ConnectionStatus) -> ConnectionRecord {
            ConnectionRecord(id: UUID(), provider: "notion", displayName: "Acme", status: status, lastSyncedAt: nil, lastError: nil)
        }
        #expect(!EdgeWorkSnapshot.canConnect(connectionsLoaded: false, connections: []))
        #expect(EdgeWorkSnapshot.canConnect(connectionsLoaded: true, connections: []))
        #expect(EdgeWorkSnapshot.canConnect(connectionsLoaded: true, connections: [record(.revoked)]))
        #expect(!EdgeWorkSnapshot.canConnect(connectionsLoaded: true, connections: [record(.revoked), record(.active)]))
    }

    /// 받은 목록이 비었는데 연결이 동기화 중이면 할 일 없음 화면이 아니다 (리뷰 F2). 끝나 동기화가 아니면 그때 할 일 없음
    @Test func emptyListWhileSyncingIsNotNoWork() {
        let syncing = EdgeWorkSnapshot(load: .loaded(problem: nil), syncing: true)
        #expect(WorkListScreen.of(load: syncing.load, isEmpty: syncing.items(now: Date()).isEmpty, syncing: syncing.syncing) == .waitingForSync(problem: nil))
        let done = EdgeWorkSnapshot(load: .loaded(problem: nil), syncing: false)
        #expect(WorkListScreen.of(load: done.load, isEmpty: done.items(now: Date()).isEmpty, syncing: done.syncing) == .noWork(problem: nil))
        let sections = TaskSections(review: [], inProgress: [], toDo: [], doneToday: [])
        #expect(EdgeWorkSnapshot(sections: sections, working: [], stopping: [], load: .loaded(problem: nil), doneSince: nil, canConnect: false, syncing: true).syncing)
    }

    /// S3가 그리는 Edge 파일의 글자에 금지 문구 · 로고 이름이 없다 (리뷰 L2)
    @Test func edgeSourcesAvoidBannedCopy() throws {
        let edge = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Taskforce/Mac/Edge")
        for file in ["EdgePanel.swift", "EdgeShell.swift", "EdgeShellModel.swift", "EdgeRailPanel.swift"] {
            let literals = BannedCopy.literals(in: try String(contentsOf: edge.appending(path: file), encoding: .utf8))
            #expect(!literals.isEmpty, "\(file)")
            for literal in literals {
                #expect(BannedCopy.violation(in: literal) == nil, "\(file): \(literal)")
            }
        }
    }

    // MARK: 연결 코드 (리뷰 후속 N2 · N3 · N4)

    /// 동기화 따라 읽기는 하나만 돌고, 조건이 거짓이 되면(패널이 안 보임 · 동기화 끝) 스스로 취소한다 (N3)
    @Test func syncFollowerRunsOnceAndStopsItself() async {
        final class Box {
            var started = 0
            var cancelled = false
        }
        let box = Box()
        let follower = EdgeSyncFollower()
        let follow: @MainActor () async -> Void = {
            box.started += 1
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            box.cancelled = true
        }
        follower.update(shouldFollow: true, follow: follow)
        follower.update(shouldFollow: true, follow: follow)
        for _ in 0..<20 { await Task.yield() }
        #expect(box.started == 1)
        #expect(follower.isFollowing)
        follower.update(shouldFollow: false, follow: follow)
        #expect(!follower.isFollowing)
        for _ in 0..<200 where !box.cancelled { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(box.cancelled)
        // 따라 읽기가 스스로 끝나면(동기화 끝) 다음에 다시 켤 수 있다
        follower.update(shouldFollow: true) {}
        for _ in 0..<200 where follower.isFollowing { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(!follower.isFollowing)
    }

    /// 동기화가 끝난 뒤 다시 읽기는 이미 읽는 중이거나 끝난 뒤 받은 목록이 있으면 하지 않는다 (N2, 구 런처 화면과 겹치지 않게)
    @Test func reloadAfterSyncSkipsOverlappingLoads() {
        let finishedAt = Date(timeIntervalSince1970: 1_000)
        #expect(EdgeShellController.needsReloadAfterSync(RefreshTracker(), finishedAt: finishedAt))
        var loading = RefreshTracker()
        loading.loadStarted()
        #expect(!EdgeShellController.needsReloadAfterSync(loading, finishedAt: finishedAt))
        var fresh = RefreshTracker()
        fresh.loadSucceeded(at: finishedAt.addingTimeInterval(1))
        #expect(!EdgeShellController.needsReloadAfterSync(fresh, finishedAt: finishedAt))
        var stale = RefreshTracker()
        stale.loadSucceeded(at: finishedAt.addingTimeInterval(-10))
        #expect(EdgeShellController.needsReloadAfterSync(stale, finishedAt: finishedAt))
    }

    /// 패널 열기 · 로그인은 이미 읽는 중이면 겹쳐 읽지 않지만, Try again은 늘 새로 읽는다 (리뷰 R2: 취소된 읽기가 "읽는 중"으로 남아도)
    @Test func tryAgainAlwaysReadsTheList() {
        #expect(EdgeShellController.readsList(.retry, isLoading: true))
        #expect(EdgeShellController.readsList(.retry, isLoading: false))
        #expect(!EdgeShellController.readsList(.refresh, isLoading: true))
        #expect(EdgeShellController.readsList(.refresh, isLoading: false))
    }

    /// 첫 고정 정리(`prune`)는 로그인 상태를 안 뒤에만: 읽는 중이면 미룬다
    @Test func firstPinPruneWaitsForTheSession() {
        #expect(EdgeShellController.knownAccount(nil) == nil)
        #expect(EdgeShellController.knownAccount(.loading) == nil)
        #expect(EdgeShellController.knownAccount(.signedOut) == .some(nil))
        #expect(EdgeShellController.knownAccount(.signedIn(userID: alice, email: nil)) == .some(alice))
    }

    /// 연결 상태에서 syncing · Connect a source를 옮긴다 (N4: `snapshot`). 견본 값을 넣고 서버는 부르지 않는다
    @Test func snapshotReadsSyncingAndConnectFromTheAccount() throws {
        let services = try Self.offlineServices()
        let session = ProfileTestAccounts().session
        let now = NowStore(services: services)
        now.applySample(NowResponse(now: [], confirmations: [], weeklyCheck: nil), doneToday: [], evidence: [:])
        let syncing = ConnectionRecord(
            id: UUID(), provider: "notion", displayName: "Acme", status: .active, lastSyncedAt: nil, lastError: nil, syncStartedAt: Date()
        )
        let busy = AccountStore(services: services, session: session)
        busy.useSampleData(connections: [syncing])
        let work = EdgeShellController.snapshot(now: now, runs: nil, account: busy)
        #expect(work.syncing && !work.canConnect)
        #expect(work.load == .loaded(problem: nil))
        #expect(WorkListScreen.of(load: work.load, isEmpty: work.items(now: Date()).isEmpty, syncing: work.syncing) == .waitingForSync(problem: nil))
        // 연결을 읽었고 없음 → Connect a source
        let none = AccountStore(services: services, session: session)
        none.useSampleData(connections: [])
        #expect(EdgeShellController.snapshot(now: now, runs: nil, account: none).canConnect)
        // 아직 읽지 않음 · 계정 저장소 없음 → 보이지 않음
        let unread = AccountStore(services: services, session: session)
        #expect(!EdgeShellController.snapshot(now: now, runs: nil, account: unread).canConnect)
        #expect(!EdgeShellController.snapshot(now: now, runs: nil, account: nil).canConnect)
        #expect(EdgeShellController.snapshot(now: nil, runs: nil, account: busy) == .empty)
    }

    /// 네트워크 없는 서비스 (`.invalid` 주소, 견본 값만 쓰는 테스트용)
    static func offlineServices() throws -> AppServices {
        let config = AppConfig(
            supabaseURL: URL(string: "https://edge-worklist.invalid")!, supabaseKey: "test-key", appGroupID: "group.test.taskforce",
            apiBaseURL: URL(string: "https://edge-worklist-api.invalid")!
        )
        let urlSession = URLSession(configuration: .ephemeral)
        let supabase = SupabaseClient(
            supabaseURL: config.supabaseURL, supabaseKey: config.supabaseKey,
            options: SupabaseClientOptions(auth: .init(storage: EmptyAuthStorage(), autoRefreshToken: false), global: .init(session: urlSession))
        )
        return AppServices(config: config, supabase: supabase, session: urlSession)
    }

    /// 서버 이유(기한 빨강)는 열린 할 일에서 옮겨 온다. 수행자는 담당 값에서만
    @Test func snapshotCarriesServerReasonsAndOwnerOnly() {
        let late = RankedAction(action: Self.action(1, started: true), score: 9, reasons: [.overdue], daysUntilDue: -1)
        let soon = RankedAction(action: Self.action(2), score: 1, reasons: [.dueSoon], daysUntilDue: 2)
        let sections = TaskSections(review: [], inProgress: [late], toDo: [soon], doneToday: [])
        let work = EdgeWorkSnapshot(sections: sections, working: [], stopping: [], load: .loaded(problem: nil), doneSince: nil, canConnect: true)
        let items = work.items(now: Date())
        #expect(items.map(\.reasons) == [[.overdue], [.dueSoon]])
        #expect(items.map(\.performer) == ["You", "You"])
        #expect(work.canConnect)
    }
}

/// 걸린 구독 수를 세는 알림 센터 (구독이 걷혔는지 본다). 시스템 알림 센터가 아니라 시험용 인스턴스다
final class CountingCenter: NotificationCenter, @unchecked Sendable {
    private var tokens: Set<ObjectIdentifier> = []
    var active: Int { tokens.count }

    override func addObserver(forName name: NSNotification.Name?, object obj: Any?, queue: OperationQueue?, using block: @escaping @Sendable (Notification) -> Void) -> any NSObjectProtocol {
        let token = super.addObserver(forName: name, object: obj, queue: queue, using: block)
        tokens.insert(ObjectIdentifier(token))
        return token
    }

    override func removeObserver(_ observer: Any) {
        tokens.remove(ObjectIdentifier(observer as AnyObject))
        super.removeObserver(observer)
    }
}

/// 화면 글자 검사: 소스의 문자열 글자(주석 제외)에서 디자인이 금지한 말 · 색 점 글리프 · Claude 이름을 찾는다
enum BannedCopy {
    static let phrases = ["caught up", "nothing here", "claude", "anthropic"]
    static let glyphs = ["●", "•", "◦", "🔴", "🟢", "🟡", "🔵", "✨"]

    /// 주석 줄을 뺀 줄들의 "…" 글자
    static func literals(in source: String) -> [String] {
        let code = source.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        let regex = try! NSRegularExpression(pattern: #""(?:[^"\\\n]|\\.)*""#)
        return regex.matches(in: code, range: NSRange(code.startIndex..., in: code)).compactMap { Range($0.range, in: code).map { String(code[$0]) } }
    }

    static func violation(in literal: String) -> String? {
        phrases.first { literal.localizedCaseInsensitiveContains($0) } ?? glyphs.first { literal.contains($0) }
    }
}

/// 세션을 두지 않는 인증 저장소 (키체인을 건드리지 않는다)
private final class EmptyAuthStorage: AuthLocalStorage, @unchecked Sendable {
    func store(key: String, value: Data) throws {}
    func retrieve(key: String) throws -> Data? { nil }
    func remove(key: String) throws {}
}
