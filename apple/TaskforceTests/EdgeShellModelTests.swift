import AppKit
import Foundation
import Testing
@testable import Taskforce
@testable import TaskforceKit
@testable import TaskforceUI

/// 0.2.0 Edge 셸 뼈대 (A3): 레일 순서 · 자리 고정 · 숨김/펼침/가는 줄 · 패널 열고 닫기 · Done 3초 · 움직임 줄이기 · 플래그 기본 꺼짐
@MainActor
struct EdgeShellModelTests {
    /// 손으로 돌리는 시계 · 미루어 부르기 (호버 120ms · 떠남 400ms · Done 3초)
    @MainActor
    final class ManualTime {
        private(set) var now: TimeInterval = 0
        private var pending: [(at: TimeInterval, timer: EdgeTimer, work: @MainActor () -> Void)] = []

        var schedule: EdgeSchedule {
            { [unowned self] delay, work in
                let timer = EdgeTimer()
                pending.append((now + delay, timer, work))
                return timer
            }
        }

        var clock: () -> Date { { [unowned self] in Date(timeIntervalSinceReferenceDate: now) } }

        func advance(_ seconds: TimeInterval) {
            now += seconds
            while let next = pending.enumerated().filter({ $0.element.at <= now }).min(by: { $0.element.at < $1.element.at }) {
                pending.remove(at: next.offset)
                if !next.element.timer.isCancelled { next.element.work() }
            }
        }
    }

    static func action(_ n: Int, _ title: String = "", started: Bool = false, due: LocalDate? = nil, status: ActionStatus = .open) -> ActionSummary {
        ActionSummary(
            id: UUID(uuidString: String(format: "E0000000-0000-4000-8000-%012d", n))!, title: title.isEmpty ? "Work \(n)" : title, owner: .me,
            status: status, dueDate: due, counterpart: nil, needsConfirmation: false, confirmReasons: [],
            startedAt: started ? Date(timeIntervalSinceReferenceDate: 0) : nil, lastActivityAt: Date(timeIntervalSinceReferenceDate: 0)
        )
    }

    static func entry(_ n: Int, _ kind: ActivityRing.Kind) -> RailEntry {
        RailEntry(id: action(n).id, title: "Work \(n)", kind: kind, state: .inProgress)
    }

    let time = ManualTime()

    func model(reduceMotion: Bool = false) -> EdgeShellModel {
        EdgeShellModel(reduceMotion: reduceMotion, schedule: time.schedule, clock: time.clock)
    }

    // MARK: 레일 순서 (RailOrdering)

    @Test func firstOrderIsNeedsYouThenRunningThenDoneThenRest() {
        let entries = [Self.entry(1, .waiting), Self.entry(2, .done), Self.entry(3, .running), Self.entry(4, .needsYou), Self.entry(5, .unreachable)]
        let slots = RailOrdering.slots(previous: [], entries: entries)
        // 넷까지: needs you → running · connection lost(들어온 차례) → done. 나머지(waiting)는 빠진다
        #expect(slots.map(\.id) == [4, 3, 5, 2].map { Self.action($0).id })
    }

    @Test func slotsKeepTheirPlaceWhenTheKindChanges() {
        let first = RailOrdering.slots(previous: [], entries: [Self.entry(1, .needsYou), Self.entry(2, .running), Self.entry(3, .running)])
        // running → connection lost · stop requested: 제자리 (D-5 "nothing moves")
        let next = RailOrdering.slots(previous: first.map(\.id), entries: [Self.entry(1, .needsYou), Self.entry(2, .unreachable), Self.entry(3, .stopping)])
        #expect(next.map(\.id) == first.map(\.id))
        #expect(next.map(\.kind) == [.needsYou, .unreachable, .stopping])
        // 앞의 일이 waiting으로 바뀌어도 서로의 순서는 그대로
        let demoted = RailOrdering.slots(previous: next.map(\.id), entries: [Self.entry(1, .waiting), Self.entry(2, .unreachable), Self.entry(3, .stopping)])
        #expect(demoted.map(\.id) == first.map(\.id))
    }

    @Test func newcomersTakeTheirPriorityPlaceWithoutReorderingOthers() {
        let first = RailOrdering.slots(previous: [], entries: [Self.entry(1, .needsYou), Self.entry(2, .running)])
        // 새 needs you는 있던 needs you 뒤, running 앞. 새 running은 running 뒤
        let next = RailOrdering.slots(previous: first.map(\.id), entries: [
            Self.entry(1, .needsYou), Self.entry(2, .running), Self.entry(3, .running), Self.entry(4, .needsYou),
        ])
        #expect(next.map(\.id) == [1, 4, 2, 3].map { Self.action($0).id })
        // 다섯째는 끝에서 빠진다
        let full = RailOrdering.slots(previous: next.map(\.id), entries: next + [Self.entry(5, .done)])
        #expect(full.count == RailOrdering.capacity)
        #expect(!full.contains { $0.id == Self.action(5).id })
    }

    @Test func leavingItemsCloseTheGapKeepingOrder() {
        let first = RailOrdering.slots(previous: [], entries: [Self.entry(1, .needsYou), Self.entry(2, .running), Self.entry(3, .done)])
        let next = RailOrdering.slots(previous: first.map(\.id), entries: [Self.entry(3, .done), Self.entry(1, .needsYou)])
        #expect(next.map(\.id) == [1, 3].map { Self.action($0).id })
    }

    @Test func notchShowsLeadKindsOnlyUpToThree() {
        let slots = RailOrdering.slots(previous: [], entries: [
            Self.entry(1, .needsYou), Self.entry(2, .running), Self.entry(3, .done), Self.entry(4, .needsYou),
        ])
        #expect(RailOrdering.notch(slots).count == 3)
        let waitingFirst = [Self.entry(1, .waiting), Self.entry(2, .running)]
        #expect(RailOrdering.notch(waitingFirst).isEmpty)
    }

    @Test func countsLiveInTheAccessibleNameOnly() {
        let label = RailOrdering.accessibilityLabel([
            Self.entry(1, .needsYou), Self.entry(2, .running), Self.entry(3, .unreachable), Self.entry(4, .needsYou),
        ])
        #expect(label == "Taskforce — 1 running, 2 need you, 1 unreachable")
        #expect(RailOrdering.accessibilityLabel([Self.entry(1, .needsYou)]) == "Taskforce — 0 running, 1 needs you")
    }

    @Test func railCountsEveryLiveItemNotOnlyTheFourSlots() {
        let shell = model()
        let reviews = (1...3).map { n in
            ActionSummary(
                id: Self.action(n).id, title: "Review \(n)", owner: .me, status: .open, dueDate: nil, counterpart: nil,
                needsConfirmation: true, confirmReasons: [], startedAt: nil, lastActivityAt: Date(timeIntervalSinceReferenceDate: 0)
            )
        }
        let running = (4...6).map { Self.action($0, started: true) }
        shell.update(EdgeWorkSnapshot(review: reviews, open: running, working: Set(running.map(\.id))))
        #expect(shell.slots.count == 4)
        #expect(shell.railAccessibilityLabel == "Taskforce — 3 running, 3 need you")
    }

    @Test func railItemNameIsTitleStateActivity() {
        let entry = RailEntry(id: UUID(), title: "Pricing page", kind: .running, state: .inProgress, activity: "AI reviewing")
        #expect(entry.accessibilityLabel == "Pricing page · In Progress · AI reviewing")
        // 활동 글이 없으면 링의 말
        #expect(RailEntry(id: UUID(), title: "Launch", kind: .unreachable, state: .inProgress).activity == "Connection lost")
    }

    // MARK: 데이터 → 레일

    @Test func entriesComeFromReviewsAndRunningWork() {
        let review = ActionSummary(
            id: Self.action(1).id, title: "Confirm owner", owner: .me, status: .open, dueDate: nil, counterpart: nil,
            needsConfirmation: true, confirmReasons: [], startedAt: nil, lastActivityAt: Date(timeIntervalSinceReferenceDate: 0)
        )
        let running = Self.action(2, started: true)
        let stopping = Self.action(3, started: true)
        let idle = Self.action(4)
        let work = EdgeWorkSnapshot(review: [review], open: [running, stopping, idle], working: [running.id, stopping.id], stopping: [stopping.id])
        let entries = EdgeShellModel.entries(work, recentlyDone: [:])
        #expect(entries.map(\.kind) == [.needsYou, .running, .stopping])
        #expect(entries.map(\.id) == [review.id, running.id, stopping.id])
        #expect(entries[2].activity == "Stop requested · not confirmed")
        // run이 없는 열린 일은 레일에 오르지 않는다 (활동이 있는 일만)
        #expect(!entries.contains { $0.id == idle.id })
    }

    @Test func workThatFinishesOnTheRailShowsDoneForThreeSeconds() {
        let shell = model()
        let item = Self.action(1, started: true)
        shell.update(EdgeWorkSnapshot(open: [item], working: [item.id], load: .loaded(problem: nil)))
        #expect(shell.slots.map(\.kind) == [.running])
        let done = Self.action(1, started: true, status: .done)
        time.advance(1)
        shell.update(EdgeWorkSnapshot(doneToday: [done], load: .loaded(problem: nil)))
        #expect(shell.slots.map(\.kind) == [.done])
        #expect(shell.slots.first?.id == item.id)
        time.advance(2.9)
        #expect(shell.slots.map(\.kind) == [.done])
        time.advance(0.2)
        #expect(shell.slots.isEmpty)
        // 레일에 없던 일이 끝나면 Done을 띄우지 않는다
        shell.update(EdgeWorkSnapshot(doneToday: [done, Self.action(9, status: .done)], load: .loaded(problem: nil)))
        #expect(shell.slots.isEmpty)
    }

    // MARK: 숨김 · 펼침 · 가는 줄

    @Test func hoverExpandsAfter120msAndHidesAfter400ms() {
        let shell = model()
        shell.update(EdgeWorkSnapshot(review: [], open: [Self.action(1)], working: [Self.action(1).id]))
        #expect(!shell.isExpanded)
        shell.pointer(inside: true)
        time.advance(0.1)
        #expect(!shell.isExpanded)
        time.advance(0.03)
        #expect(shell.isExpanded)
        shell.pointer(inside: false)
        time.advance(0.39)
        #expect(shell.isExpanded)
        time.advance(0.02)
        #expect(!shell.isExpanded)
    }

    @Test func passingOverTheNotchDoesNotExpand() {
        let shell = model()
        shell.pointer(inside: true)
        time.advance(0.05)
        shell.pointer(inside: false)
        time.advance(1)
        #expect(!shell.isExpanded)
    }

    @Test func returningWithin400msKeepsTheRailOpen() {
        let shell = model()
        shell.pointer(inside: true)
        time.advance(0.2)
        shell.pointer(inside: false)
        time.advance(0.3)
        shell.pointer(inside: true)
        time.advance(1)
        #expect(shell.isExpanded)
    }

    @Test func idleSliverWhenNothingIsLive() {
        let shell = model()
        #expect(shell.isIdle)
        shell.pointer(inside: true)
        time.advance(0.2)
        // 가는 줄도 호버 대상: 펼치면 All work · Chats · More
        #expect(!shell.isIdle)
        #expect(shell.isExpanded)
    }

    // MARK: 패널

    @Test func panelKeepsTheRailExpandedAndTurnsTooltipsOff() {
        let shell = model()
        let item = Self.action(1)
        shell.update(EdgeWorkSnapshot(open: [item], working: [item.id]))
        shell.pointer(inside: true)
        time.advance(0.2)
        shell.hover(item: item.id)
        #expect(shell.tooltip?.title == "Work 1")
        #expect(shell.tooltip?.detail == "· To Do · Running")
        shell.openAllWork()
        #expect(shell.tooltip == nil)
        shell.pointer(inside: false)
        time.advance(1)
        #expect(shell.isExpanded)
        shell.dismiss()
        #expect(!shell.panelOpen)
        #expect(!shell.isExpanded)
    }

    @Test func hotKeyTogglesTheLastView() {
        let shell = model()
        shell.togglePanel()
        #expect(shell.panelOpen && shell.view == .allWork)
        shell.openChats()
        shell.togglePanel()
        #expect(!shell.panelOpen)
        shell.togglePanel()
        #expect(shell.panelOpen && shell.view == .chats)
    }

    @Test func openingAnItemShowsItInAllWorkAndAllWorkClearsIt() {
        let shell = model()
        let id = Self.action(1).id
        shell.open(itemID: id)
        #expect(shell.view == .allWork && shell.currentID == id)
        shell.openAllWork()
        #expect(shell.currentID == nil)
    }

    @Test func escapeCollapsesButKeepsTheRailWhileThePointerIsOnIt() {
        let shell = model()
        shell.pointer(inside: true)
        time.advance(0.2)
        shell.openAllWork()
        shell.dismiss()
        #expect(!shell.panelOpen)
        #expect(shell.isExpanded)
    }

    @Test func moreMenuKeepsTheRailOpenUntilItCloses() {
        let shell = model()
        shell.pointer(inside: true)
        time.advance(0.2)
        shell.setMenuOpen(true)
        shell.pointer(inside: false)
        time.advance(1)
        #expect(shell.isExpanded)
        shell.setMenuOpen(false)
        #expect(!shell.isExpanded)
    }

    // MARK: 움직임 줄이기 · 자리

    @Test func reduceMotionMeansOpacityOnly() {
        #expect(TFMotion.panelTransform(shown: false, reduceMotion: true) == (0, 1))
        #expect(TFMotion.panelTransform(shown: false, reduceMotion: false) == (16, 0.975))
        #expect(TFMotion.panelTransform(shown: true, reduceMotion: false) == (0, 1))
        #expect(TFMotion.move(TFMotion.railSlide, reduceMotion: true) == nil)
        #expect(TFMotion.move(TFMotion.railSlide, reduceMotion: false) != nil)
        #expect(model(reduceMotion: true).reduceMotion)
    }

    @Test func railGeometryFollowsTheDesign() {
        let hidden = EdgeRailLayout(notchCount: 2, restCount: 1, expanded: false, idle: false)
        #expect(hidden.shift == 19)
        #expect(hidden.notchShift == 9.5)
        #expect(hidden.hitRect.width == 25)
        // 숨은 레일: 위아래 6 + 링 34씩
        let hiddenHeight: CGFloat = 12 + 2 * 34
        #expect(hidden.railRect.height == hiddenHeight)
        let expanded = EdgeRailLayout(notchCount: 2, restCount: 1, expanded: true, idle: false)
        #expect(expanded.shift == 0)
        #expect(expanded.hitRect.width == 44)
        // 펼침은 아래로만 자란다 (위 모서리 · 노치 링 자리는 그대로)
        #expect(expanded.railRect.minY == hidden.railRect.minY)
        #expect(expanded.notchFrame(1).minY == hidden.notchFrame(1).minY)
        // 위아래 6 + 링 셋(34씩) + 구분선 13 + 간격 2 + 고정 칸 셋(32, 사이 2)
        let expandedHeight: CGFloat = 229
        #expect(expanded.railRect.height == expandedHeight)
        let idle = EdgeRailLayout(notchCount: 0, restCount: 0, expanded: false, idle: true)
        #expect(idle.shift == 38)
        #expect(idle.railRect.height == 36)
        // 가장 큰 레일도 창에 들어간다
        let largest = EdgeRailLayout(notchCount: 3, restCount: 1, expanded: true, idle: false)
        #expect(largest.railRect.maxY + EdgeRailLayout.fillet <= EdgeRailLayout.windowHeight)
    }

    @Test func pointerHitsOnlyVisibleCells() {
        let slots = [Self.entry(1, .needsYou), Self.entry(2, .running), Self.entry(3, .waiting)]
        let hidden = EdgeRailLayout(notchCount: 2, restCount: 1, expanded: false, idle: false)
        #expect(hidden.hit(CGPoint(x: hidden.notchFrame(0).midX, y: hidden.notchFrame(0).midY), slots: slots).item == slots[0].id)
        // 숨은 레일에서는 펼친 칸 · 고정 칸을 누를 수 없다
        #expect(hidden.hit(CGPoint(x: hidden.restFrame(0).midX, y: hidden.restFrame(0).midY), slots: slots).item == nil)
        #expect(hidden.hit(CGPoint(x: 5, y: hidden.notchFrame(0).midY), slots: slots).item == nil)
        let expanded = EdgeRailLayout(notchCount: 2, restCount: 1, expanded: true, idle: false)
        let more = expanded.controlFrame(.more)
        #expect(expanded.hit(CGPoint(x: more.midX, y: more.midY), slots: slots).control == .more)
        #expect(expanded.hit(CGPoint(x: expanded.restFrame(0).midX, y: expanded.restFrame(0).midY), slots: slots).item == slots[2].id)
    }

    @Test func panelSitsLeftOfTheRailTopAligned() {
        #expect(EdgePanelMetrics.height(body: 10) == EdgePanelMetrics.minHeight)
        #expect(EdgePanelMetrics.height(body: 300) == 340)
        #expect(EdgePanelMetrics.height(body: 2_000) == 520)
        let frame = EdgePanelMetrics.frame(height: 300, railTop: 900, screenMaxX: 1_512)
        let rightEdge: CGFloat = 1_512 - 44 - 12
        #expect(frame.maxX == rightEdge)
        #expect(frame.width == 380)
        #expect(frame.maxY == 900)
    }

    // MARK: 목록 · 문구

    @Test func workRowNameMentionsOverdueOnlyInTheAccessibleName() {
        #expect(WorkRow.accessibilityLabel(title: "Pricing page", state: .inProgress, activity: "Running", due: "Fri", overdue: false)
            == "Pricing page — In Progress · Running, due Fri")
        #expect(WorkRow.accessibilityLabel(title: "Report", state: .toDo, activity: nil, due: "Oct 8", overdue: true)
            == "Report — To Do, overdue, due Oct 8")
    }

    /// 빈 화면 제목은 디자인 그대로, "caught up"은 없다. All work 패널의 머리는 "Your work"(디자인 WorkPage), 레일 칸 이름은 All work
    @Test func emptyScreensUseTheDesignTitlesNeverAllCaughtUp() {
        #expect(PanelEmptyKind.noWork.title == "Nothing on your plate yet.")
        #expect(EdgePanelView.noChats == "No conversations yet.")
        for title in PanelEmptyKind.allCases.map(\.title) + [EdgePanelView.noChats] {
            #expect(!title.localizedCaseInsensitiveContains("caught up"))
        }
        #expect(EdgeShellModel.View.allCases.map(\.title) == ["Your work", "Chats"])
        #expect(EdgeShellModel.Control.allCases.map(\.label) == ["All work", "Chats", "More"])
    }

    // MARK: 플래그

    /// 앱은 launch argument로만 켠다: 테스트 실행(인자 없음)에서는 꺼져 있다
    @Test func edgeShellIsOffWithoutTheLaunchArgument() {
        #expect(!ProcessInfo.processInfo.arguments.contains("-\(EdgeShellFlag.key)"))
        #expect(!EdgeShellFlag.isEnabled())
    }

    @Test func edgeShellIsOffUnlessTurnedOnInAnIsolatedSuite() throws {
        let name = "dev.taskforcelabs.tests.edge-shell.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(!EdgeShellFlag.isEnabled(defaults))
        defaults.set("NO", forKey: EdgeShellFlag.key)
        #expect(!EdgeShellFlag.isEnabled(defaults))
        defaults.set(true, forKey: EdgeShellFlag.key)
        #expect(EdgeShellFlag.isEnabled(defaults))
    }
}
