import Foundation
import Testing
@testable import TaskforceKit

/// 0.2.0 All work (S3): 묶음 순서 · 서버 순서 유지 · 검색 × 프로젝트 × 상태 × Waiting · 고정 셋 · 불러오기 상태 · Done today 날짜 경계
struct WorkListTests {
    static func action(
        _ n: Int, _ title: String = "", owner: ActionOwner = .me, started: Bool = false, status: ActionStatus = .open,
        needsConfirmation: Bool = false, reasons: [String] = []
    ) -> ActionSummary {
        ActionSummary(
            id: id(n), title: title.isEmpty ? "Work \(n)" : title, owner: owner, status: status, dueDate: nil, counterpart: nil,
            needsConfirmation: needsConfirmation, confirmReasons: reasons, startedAt: started ? Date(timeIntervalSince1970: 0) : nil,
            lastActivityAt: Date(timeIntervalSince1970: 0)
        )
    }

    static func id(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "F0000000-0000-4000-8000-%012d", n))!
    }

    static func item(
        _ n: Int, _ title: String = "", project: String? = nil, state: WorkState = .toDo, performer: String? = nil,
        activity: String? = nil, waiting: Bool = false
    ) -> WorkItem {
        WorkItem(
            action: action(n, title, status: state == .done ? .done : .open), state: state, project: project, performer: performer,
            activity: activity, waiting: waiting
        )
    }

    /// 디자인 WorkList 견본과 같은 모양 (프로젝트가 있는 미래 데이터: S3b가 채울 때도 같은 규칙)
    static let designed: [WorkItem] = [
        item(1, "Launch design", project: "Shape launch", state: .inProgress, performer: "Design agent", activity: "Revising"),
        item(2, "Pricing page", project: "Shape launch", state: .inProgress, performer: "Coding agent + AI review", activity: "Needs your direction"),
        item(3, "Website brief", project: "Acme website", state: .inProgress, performer: "Mail · Alex", activity: "Waiting for assets", waiting: true),
        item(4, "Onboarding copy", project: "Shape launch", state: .toDo, performer: "Writing agent", activity: "Ready to start"),
        item(5, "September invoice", state: .inProgress, performer: "Mail · Finance", activity: "Waiting for reply", waiting: true),
        item(6, "Portfolio case study", state: .toDo, performer: "You", activity: "Ready to start"),
        item(7, "Launch direction", project: "Shape launch", state: .done, performer: "You"),
    ]

    func ids(_ groups: [WorkListGroup]) -> [[Int]] {
        groups.map { $0.items.map { item in (1...99).first { Self.id($0) == item.id } ?? -1 } }
    }

    // MARK: 묶음 · 순서

    @Test func groupsByProjectThenUngroupedThenQuietDoneToday() {
        let groups = WorkListLayout.groups(Self.designed, filter: WorkFilter(), pinned: [])
        #expect(groups.map(\.title) == ["Shape launch", "Acme website", "Ungrouped", "Done today"])
        #expect(ids(groups) == [[1, 2, 4], [3], [5, 6], [7]])
        // 묶음 이름에 개수가 없다
        for group in groups { #expect(group.title.rangeOfCharacter(from: .decimalDigits) == nil) }
    }

    @Test func projectChipsAreAllThenProjectsThenUngrouped() {
        #expect(WorkListLayout.projectOptions(Self.designed).map(\.title) == ["All", "Shape launch", "Acme website", "Ungrouped"])
    }

    /// 지금 `actions`에는 프로젝트가 없다: 모두 Ungrouped, 프로젝트 칩은 All · Ungrouped뿐 (프로젝트를 지어내지 않는다)
    @Test func currentDataHasNoProjectsSoEverythingIsUngrouped() {
        let items = WorkItem.list(
            reviews: [Self.action(1, needsConfirmation: true)], open: [Self.action(2), Self.action(3, started: true)],
            doneToday: [Self.action(4, status: .done)]
        )
        #expect(items.allSatisfy { $0.project == nil })
        let groups = WorkListLayout.groups(items, filter: WorkFilter(), pinned: [])
        #expect(groups.map(\.title) == ["Ungrouped", "Done today"])
        #expect(WorkListLayout.projectOptions(items) == [.all, .ungrouped])
    }

    /// 서버 순서 그대로: 확인 요청 → 열린 할 일 → 오늘 끝낸 할 일, 같은 할 일은 한 번만
    @Test func itemsKeepTheServerOrder() {
        let items = WorkItem.list(
            reviews: [Self.action(5, needsConfirmation: true)], open: [Self.action(2), Self.action(9), Self.action(5)],
            doneToday: [Self.action(7, status: .done), Self.action(2, status: .done)]
        )
        #expect(items.map(\.id) == [5, 2, 9, 7].map(Self.id))
    }

    @Test func activityChangesNeverReorderRows() {
        let open = [Self.action(1), Self.action(2, started: true), Self.action(3)]
        let idle = WorkItem.list(reviews: [], open: open, doneToday: [])
        let busy = WorkItem.list(reviews: [], open: open, doneToday: [], working: [Self.id(3), Self.id(2)], stopping: [Self.id(2)])
        #expect(busy.map(\.activity) == [nil, WorkActivity.stopRequested, WorkActivity.running])
        let before = WorkListLayout.groups(idle, filter: WorkFilter(), pinned: [Self.id(2)])
        let after = WorkListLayout.groups(busy, filter: WorkFilter(), pinned: [Self.id(2)])
        #expect(ids(before) == ids(after))
    }

    /// Review는 상태가 아니라 활동이다 (디자인 StatusMark 세 상태)
    @Test func reviewIsActivityTextNotAState() {
        let items = WorkItem.list(
            reviews: [Self.action(1, started: true, needsConfirmation: true), Self.action(2, needsConfirmation: true)], open: [], doneToday: [],
            working: [Self.id(1)]
        )
        #expect(items.map(\.state) == [.inProgress, .toDo])
        #expect(items.map(\.activity) == [WorkActivity.needsAnswer, WorkActivity.needsAnswer])
    }

    /// 수행자는 담당 값에서만: 나면 "You", 모름이면 없음
    @Test func performerComesFromTheOwnerOnly() {
        let items = WorkItem.list(reviews: [], open: [Self.action(1, owner: .me), Self.action(2, owner: .unknown)], doneToday: [])
        #expect(items.map(\.performer) == ["You", nil])
        #expect(WorkActivity.needsAnswer == "Needs your answer")
    }

    /// 담당을 묻는 확인 요청("Not sure it's yours")은 owner가 me여도 "You"라고 단정하지 않는다 (리뷰 F1)
    @Test func ownerInQuestionHasNoPerformer() {
        let items = WorkItem.list(
            reviews: [
                Self.action(1, needsConfirmation: true, reasons: ["판정 확인: NOT_MY_ACTION", "기한 확인"]),
                Self.action(2, needsConfirmation: true, reasons: ["담당 확인"]),
                Self.action(3, needsConfirmation: true, reasons: ["판정 확인: TENTATIVE, NOT_MY_ACTION"]),
                // 담당이 아닌 이유는 수행자를 그대로 둔다
                Self.action(4, needsConfirmation: true, reasons: ["기한 확인", "병합 확인 (55%)"]),
                Self.action(5, needsConfirmation: true, reasons: ["판정 확인: ALREADY_DONE"]),
            ],
            open: [], doneToday: []
        )
        #expect(items.map(\.performer) == [nil, nil, nil, "You", "You"])
        // 앱의 이유 분류(`ConfirmReasonText`)와 같은 판단: 그 이유들이 "Not sure it's yours"로 읽힌다
        #expect(ConfirmReasonText.label(["판정 확인: NOT_MY_ACTION"]) == "Not sure it's yours")
        #expect(ConfirmReasonText.label(["담당 확인"]) == "Not sure it's yours")
        #expect(ConfirmReasonText.questionsOwner(["판정 확인: NOT_MY_ACTION"]))
        #expect(ConfirmReasonText.questionsOwner(["담당 확인"]))
        #expect(!ConfirmReasonText.questionsOwner(["기한 확인", "판정 확인: INFO_ONLY"]))
    }

    /// 지금 데이터에는 기다림의 근거가 없다: Waiting 필터는 아무것도 고르지 않는다
    @Test func waitingIsNeverInventedFromCurrentData() {
        let items = WorkItem.list(
            reviews: [Self.action(1, needsConfirmation: true)], open: [Self.action(2, owner: .unknown), Self.action(3, started: true)],
            doneToday: [Self.action(4, status: .done)], working: [Self.id(3)]
        )
        #expect(items.allSatisfy { !$0.waiting })
        #expect(WorkListLayout.groups(items, filter: WorkFilter(status: .waiting), pinned: []).isEmpty)
    }

    // MARK: 검색 · 필터

    @Test func searchCoversTitleProjectPerformerAndActivity() {
        func found(_ query: String) -> [[Int]] { ids(WorkListLayout.groups(Self.designed, filter: WorkFilter(query: query), pinned: [])) }
        #expect(found("pricing") == [[2]])
        #expect(found("acme") == [[3]])
        #expect(found("coding agent") == [[2]])
        #expect(found("waiting for") == [[3], [5]])
        // 단어는 모두 맞아야 하고 대소문자는 가리지 않는다
        #expect(found("SHAPE ready") == [[4]])
        #expect(found("ungrouped portfolio") == [[6]])
        #expect(found("nothing like this").isEmpty)
    }

    @Test func projectAndStatusFiltersCombineWithSearch() {
        func found(_ filter: WorkFilter) -> [[Int]] { ids(WorkListLayout.groups(Self.designed, filter: filter, pinned: [])) }
        #expect(found(WorkFilter(project: .project("Shape launch"))) == [[1, 2, 4], [7]])
        #expect(found(WorkFilter(project: .ungrouped)) == [[5, 6]])
        #expect(found(WorkFilter(status: .inProgress)) == [[1, 2], [3], [5]])
        #expect(found(WorkFilter(status: .toDo)) == [[4], [6]])
        #expect(found(WorkFilter(status: .done)) == [[7]])
        // Waiting은 기다림 조건으로 거르고 상태는 그대로 둔다
        #expect(found(WorkFilter(status: .waiting)) == [[3], [5]])
        #expect(found(WorkFilter(project: .project("Acme website"), status: .waiting)) == [[3]])
        #expect(found(WorkFilter(query: "invoice", project: .ungrouped, status: .waiting)) == [[5]])
        #expect(found(WorkFilter(query: "invoice", project: .project("Shape launch"))).isEmpty)
        #expect(found(WorkFilter(project: .ungrouped, status: .done)).isEmpty)
    }

    @Test func activeFiltersReadAsOneLineAndClearKeepsTheSearch() {
        var filter = WorkFilter(query: "launch", project: .project("Shape launch"), status: .waiting)
        #expect(filter.activeLabels == ["Shape launch", "Waiting"])
        #expect(filter.hasActiveFilters)
        filter.clearFilters()
        #expect(filter == WorkFilter(query: "launch"))
        #expect(filter.activeLabels.isEmpty && !filter.hasActiveFilters)
        #expect(WorkFilter(status: .done).activeLabels == ["Done"])
        #expect(WorkStatusFilter.allCases.map(\.title) == ["All", "In Progress", "To Do", "Waiting", "Done"])
    }

    // MARK: 고정

    @Test func pinnedWorkLeadsItsOwnGroupKeepingTheirOrder() {
        let pinned: Set<UUID> = [Self.id(4), Self.id(2), Self.id(6), Self.id(7)]
        let groups = WorkListLayout.groups(Self.designed, filter: WorkFilter(), pinned: pinned)
        #expect(ids(groups) == [[2, 4, 1], [3], [6, 5], [7]])
    }

    @Test func pinsStopAtThreeAndNeverDuplicate() {
        let known = Set((1...6).map(Self.id))
        var pins = WorkPins()
        let first = pins.pin(Self.id(1), known: known)
        // 이미 고정한 일을 또 고정해도 겹치지 않는다
        let again = pins.pin(Self.id(1), known: known)
        #expect(first && again)
        #expect(pins.ids == [Self.id(1)])
        let second = pins.pin(Self.id(2), known: known)
        let third = pins.pin(Self.id(3), known: known)
        #expect(second && third)
        // 넷째는 안 된다 (지금 고정은 그대로)
        #expect(!pins.canPin(Self.id(4), known: known))
        let fourth = pins.pin(Self.id(4), known: known)
        #expect(!fourth)
        #expect(pins.ids == [1, 2, 3].map(Self.id))
        // 고정을 하나 풀면 다시 된다
        pins.unpin(Self.id(2))
        let afterUnpin = pins.pin(Self.id(4), known: known)
        #expect(afterUnpin)
        #expect(pins.ids == [1, 3, 4].map(Self.id))
        // 목록에 없는 일은 고정하지 않는다
        let unknown = pins.pin(Self.id(50), known: known)
        #expect(!unknown)
    }

    /// 목록에서 사라진 일(지움 · 다른 기기에서 끝남)의 옛 고정은 자리를 차지하지 않고, 새로 고정할 때 비운다
    @Test func pinsOfVanishedWorkFreeTheirPlace() {
        var pins = WorkPins([Self.id(1), Self.id(2), Self.id(3)])
        let known: Set<UUID> = [Self.id(2), Self.id(5)]
        #expect(pins.shown(in: [Self.item(2), Self.item(5)]) == [Self.id(2)])
        #expect(pins.canPin(Self.id(5), known: known))
        let pinned = pins.pin(Self.id(5), known: known)
        #expect(pinned)
        #expect(pins.ids == [Self.id(2), Self.id(5)])
    }

    @Test func savedPinsAreCleanedOnLoad() {
        let pins = WorkPins([Self.id(1), Self.id(1), Self.id(2), Self.id(3), Self.id(4)])
        #expect(pins.ids == [1, 2, 3].map(Self.id))
    }

    // MARK: 불러오기 상태

    /// 이번 실행의 목록이 없으면 빈 화면이 아니라 읽는 중 · 오프라인 · 실패다 (할 일이 없다고 말하지 않는다)
    @Test func loadStatesStayDistinct() {
        let at = Date(timeIntervalSince1970: 1_000)
        #expect(WorkLoad.from(refresh: .loading, hasList: false) == .loading)
        #expect(WorkLoad.from(refresh: .loading, hasList: true) == .loaded(problem: nil))
        #expect(WorkLoad.from(refresh: .live, hasList: true) == .loaded(problem: nil))
        #expect(WorkLoad.from(refresh: .live, hasList: false) == .loading)
        #expect(WorkLoad.from(refresh: .offlineEmpty(since: at), hasList: false) == .offline)
        // 저장본만 있는 오프라인도 이번 실행의 목록이 아니다
        #expect(WorkLoad.from(refresh: .offlineSaved(since: at, savedAt: at), hasList: false) == .offline)
        #expect(WorkLoad.from(refresh: .offlineSaved(since: at, savedAt: at), hasList: true) == .loaded(problem: .offline))
        #expect(WorkLoad.from(refresh: .refreshFailed(at: at, savedAt: nil), hasList: false) == .failed)
        #expect(WorkLoad.from(refresh: .refreshFailed(at: at, savedAt: at), hasList: true) == .loaded(problem: .failed))
    }

    // MARK: 본문 (빈 목록 · 동기화 중)

    /// 첫 동기화 중 빈 목록이면 "할 일이 없다"고 말하지 않는다 (리뷰 F2)
    @Test func emptyListWhileSyncingMakesNoClaim() {
        #expect(WorkListScreen.of(load: .loaded(problem: nil), isEmpty: true, syncing: true) == .waitingForSync(problem: nil))
        #expect(WorkListScreen.of(load: .loaded(problem: .offline), isEmpty: true, syncing: true) == .waitingForSync(problem: .offline))
        #expect(WorkListScreen.of(load: .loaded(problem: nil), isEmpty: true, syncing: false) == .noWork(problem: nil))
        // 목록이 있으면 동기화 중이어도 목록
        #expect(WorkListScreen.of(load: .loaded(problem: nil), isEmpty: false, syncing: true) == .list(problem: nil))
        #expect(WorkListScreen.of(load: .loaded(problem: .failed), isEmpty: false, syncing: false) == .list(problem: .failed))
        // 목록이 없으면 동기화와 상관없이 읽는 중 · 오프라인 · 실패
        #expect(WorkListScreen.of(load: .loading, isEmpty: true, syncing: true) == .blank)
        #expect(WorkListScreen.of(load: .offline, isEmpty: true, syncing: false) == .offline)
        #expect(WorkListScreen.of(load: .failed, isEmpty: true, syncing: true) == .failed)
    }

    // MARK: Done today 날짜 경계 (기기 시간대)

    static func calendar(_ identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        return calendar
    }

    static func date(_ text: String) -> Date {
        try! Date(text, strategy: .iso8601)
    }

    @Test func doneTodayHoldsUntilLocalMidnight() {
        let seoul = Self.calendar("Asia/Seoul")
        // 10/10 KST에 읽은 목록 (그날 0시 = 10/09 15:00Z)
        let since = seoul.startOfDay(for: Self.date("2026-10-10T05:00:00Z"))
        #expect(since == Self.date("2026-10-09T15:00:00Z"))
        #expect(DoneTodayWindow.isCurrent(since: since, now: Self.date("2026-10-09T15:00:00Z"), calendar: seoul))
        // 자정 1초 전까지는 오늘
        #expect(DoneTodayWindow.isCurrent(since: since, now: Self.date("2026-10-10T14:59:59Z"), calendar: seoul))
        // 자정이 지나면 다시 읽을 때까지 Done today가 없다
        #expect(!DoneTodayWindow.isCurrent(since: since, now: Self.date("2026-10-10T15:00:00Z"), calendar: seoul))
        #expect(!DoneTodayWindow.isCurrent(since: nil, now: Self.date("2026-10-10T05:00:00Z"), calendar: seoul))
    }

    /// 기기 시간대가 바뀌면 그 시간대의 오늘로 다시 정한다 (KST에서 읽은 목록을 PDT에서 오늘이라 하지 않는다)
    @Test func doneTodayFollowsTheDeviceTimeZone() {
        let seoul = Self.calendar("Asia/Seoul")
        let losAngeles = Self.calendar("America/Los_Angeles")
        let now = Self.date("2026-10-10T05:00:00Z")
        let since = seoul.startOfDay(for: now)
        #expect(!DoneTodayWindow.isCurrent(since: since, now: now, calendar: losAngeles))
        #expect(DoneTodayWindow.isCurrent(since: losAngeles.startOfDay(for: now), now: now, calendar: losAngeles))
    }
}

/// 고정 저장: 계정마다 따로, id만. 테스트는 메모리 저장으로 `~/Library/Preferences`에 파일을 남기지 않는다 (리뷰 L3)
@MainActor
struct WorkPinStoreTests {
    @Test func pinsAreKeptPerAccount() {
        let disk = MemoryPinStorage()
        let store = WorkPinStore(storage: disk)
        let alice = UUID(), bob = UUID()
        store.save(WorkPins([WorkListTests.id(1), WorkListTests.id(2)]), account: alice)
        #expect(store.load(account: alice).ids == [WorkListTests.id(1), WorkListTests.id(2)])
        #expect(store.load(account: bob).ids.isEmpty)
        // 다른 저장소(앱을 다시 연 것)도 같은 값을 읽는다
        #expect(WorkPinStore(storage: disk).load(account: alice).ids == [WorkListTests.id(1), WorkListTests.id(2)])
        // 할 일 id만 적는다
        #expect(disk.values == [WorkPinStore.key(alice): [WorkListTests.id(1), WorkListTests.id(2)].map { $0.uuidString.lowercased() }])
        store.save(WorkPins(), account: alice)
        #expect(disk.values.isEmpty)
    }

    /// 계정이 떠나면 모두 지우고, 앱을 열 때 지금 계정 것만 남긴다 (`SavedNowStore`와 같은 정리, 리뷰 L5)
    @Test func pinsAreRemovedLikeTheSavedCopy() {
        let disk = MemoryPinStorage()
        let store = WorkPinStore(storage: disk)
        let alice = UUID(), bob = UUID()
        store.save(WorkPins([WorkListTests.id(1)]), account: alice)
        store.save(WorkPins([WorkListTests.id(2)]), account: bob)
        disk.set(["keep"], forKey: "unrelated")
        store.prune(keeping: bob)
        #expect(store.load(account: alice).ids.isEmpty)
        #expect(store.load(account: bob).ids == [WorkListTests.id(2)])
        store.save(WorkPins([WorkListTests.id(1)]), account: alice)
        store.removeAll()
        #expect(store.load(account: alice).ids.isEmpty && store.load(account: bob).ids.isEmpty)
        // 고정 말고 다른 키는 건드리지 않는다
        #expect(disk.values == ["unrelated": ["keep"]])
        store.save(WorkPins([WorkListTests.id(3)]), account: alice)
        store.prune(keeping: nil)
        #expect(store.load(account: alice).ids.isEmpty)
    }

    @Test func memoryStoreNeverTouchesDisk() {
        let store = WorkPinStore(defaults: nil)
        let account = UUID()
        store.save(WorkPins([WorkListTests.id(3)]), account: account)
        #expect(store.load(account: account).ids == [WorkListTests.id(3)])
        #expect(store.load(account: UUID()).ids.isEmpty)
        #expect(WorkPinStore.suiteName(bundleID: "dev.example.app") == "dev.example.app.work-pins")
    }
}
