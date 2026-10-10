import Foundation
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
