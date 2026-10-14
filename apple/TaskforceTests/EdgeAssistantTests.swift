import AppKit
import Foundation
import Testing
@testable import Taskforce
@testable import TaskforceKit
@testable import TaskforceUI

/// OA U1의 셸 쪽: 레일 Review 타일(상태 · 툴팁 · 눌렀을 때 · Open) · ⌥ Space · Chats가 패널이 아니라 Assistant 창을 여는 길 · 레일 칸 계산 · 표면 플래그
@MainActor
struct EdgeAssistantTests {
    // MARK: 표면 플래그

    @Test func theAssistantWindowSurfaceIsOnlyForDebugWithTheShellAndNeverForRelease() throws {
        #expect(!EdgeSurfaces.release.assistantWindows, "Release는 늘 꺼짐")
        let store = try TestDefaults()
        defer { store.cleanup() }
        #expect(!EdgeSurfaces.debug(store.defaults).assistantWindows, "셸이 꺼진 Debug는 꺼짐")
        store.defaults.set(true, forKey: EdgeShellFlag.key)
        #expect(EdgeSurfaces.debug(store.defaults).assistantWindows, "Debug는 셸이 켜지면 켜짐")
        store.defaults.set(true, forKey: EdgeSurfaces.releaseKey)
        #expect(!EdgeSurfaces.debug(store.defaults).assistantWindows, "Release 표면을 격리로 보면 창도 없다")
        // 호스트(Debug)에는 -TF_EDGE_SHELL이 없다
        #expect(!EdgeSurfaces.current.assistantWindows)
    }

    // MARK: 타일 상태

    @Test func theTileFollowsTheReviewQueueFirstThenTheSummaryChanges() async throws {
        let rig = try await SummaryRig.make()
        let count = rig.shell.reviewQueue.count
        #expect(count > 0)
        #expect(rig.shell.reviewTileContent == .needsYou(count: count), "복귀 요약을 읽기 전에도 Review 큐가 있으면 needs-you")
        await rig.scriptDefault()
        await rig.store.refresh()
        #expect(rig.shell.reviewTileContent == .needsYou(count: rig.shell.reviewQueue.count) && rig.shell.reviewQueue.count > 0)
    }

    @Test func aQuietTileShowsWhenOnlyChangesWait() async throws {
        let rig = try await SummaryRig.make(reviews: 0)
        #expect(rig.shell.reviewQueue.count == 0)
        await rig.scriptDefault()
        await rig.store.refresh()
        guard case .changes(_, let count)? = rig.shell.reviewTileContent else {
            Issue.record("changes여야 한다: \(String(describing: rig.shell.reviewTileContent))")
            return
        }
        #expect(count > 0)
    }

    @Test func noTileWhenNothingWaitsAndNoneWhenAFlagIsOff() async throws {
        let empty = try await SummaryRig.make(reviews: 0)
        #expect(empty.shell.reviewTileContent == nil, "복귀 요약을 아직 읽지 않았고 큐가 비면 타일이 없다")
        // Review(S4)가 꺼진 셸 · 복귀 요약(C3)이 꺼진 셸에는 타일이 없다
        let noReview = try await SummaryRig.make(review: false)
        await noReview.scriptDefault()
        await noReview.store.refresh()
        #expect(noReview.shell.reviewTileContent == nil)
        let reviewOnly = try await ReviewRig.make()
        #expect(reviewOnly.shell.review != nil && reviewOnly.shell.reviewQueue.count > 0 && reviewOnly.shell.reviewTileContent == nil, "C3가 꺼져 있으면 타일 없음")
    }

    // MARK: 툴팁 · 눌렀을 때 · Open

    @Test func theTooltipAndNameComeFromTheRules() async throws {
        let rig = try await SummaryRig.make()
        await rig.scriptDefault()
        await rig.store.refresh()
        let tooltip = try #require(rig.shell.tileTooltip)
        #expect(tooltip.title == "Review" && tooltip.detail == "· Needs your answer", "화면에는 개수가 없다")
        #expect(rig.shell.tileAccessibilityName == "Review · Needs your answer, \(rig.shell.reviewQueue.count) items")
    }

    @Test func hoveringTheTileShowsItsTooltipOnlyWhileTheRailIsExpandedAndThePanelIsClosed() async throws {
        let time = EdgeShellModelTests.ManualTime()
        let harness = try await ReviewHarness.make(reviews: 3, open: 1)
        let store = ReturnSummaryStore(gateway: LiveReturnSummaryGateway(services: harness.services), scope: harness.scope)
        let desk = ReviewDesk(now: harness.store, scope: harness.scope)
        let shell = EdgeShellModel(schedule: time.schedule, clock: time.clock, review: desk, summary: store)
        await harness.store.load()
        shell.update(EdgeWorkSnapshot(
            sections: harness.store.sections, working: [], stopping: [], load: WorkLoad.from(refresh: harness.store.refreshState, hasList: harness.store.response != nil),
            doneSince: harness.store.doneTodaySince, canConnect: false
        ))
        shell.hover(tile: true)
        #expect(shell.hoveredTile && shell.tooltip == nil, "숨은 레일에서는 툴팁이 없다")
        shell.pointer(inside: true)
        time.advance(0.12)
        #expect(shell.isExpanded)
        let tooltip = try #require(shell.tooltip)
        #expect(tooltip.title == "Review" && tooltip.detail == "· Needs your answer")
        shell.openAllWork()
        shell.hover(tile: true)
        #expect(shell.tooltip == nil, "패널이 열려 있으면 레일 툴팁은 끈다")
        shell.hover(control: .allWork)
        #expect(!shell.hoveredTile, "포인터가 다른 칸으로 가면 타일 호버는 풀린다")
    }

    @Test func clickingTheTileOpensTheNewestReviewWhenSomethingWaitsAndTheSummaryOtherwise() async throws {
        let waiting = try await SummaryRig.make()
        await waiting.scriptDefault()
        await waiting.store.refresh()
        waiting.shell.openReviewTile()
        #expect(waiting.shell.panelOpen && waiting.shell.view == .review && waiting.shell.reviewID == waiting.shell.reviewQueue.newest?.id)
        let quiet = try await SummaryRig.make(reviews: 0)
        await quiet.scriptDefault()
        await quiet.store.refresh()
        quiet.shell.openReviewTile()
        #expect(quiet.shell.panelOpen && quiet.shell.view == .allWork, "changes만 있으면 복귀 요약(All work 위 카드)")
        // 타일이 없으면 눌러도 아무 일 없다
        let none = try await SummaryRig.make(reviews: 0)
        none.shell.openReviewTile()
        #expect(!none.shell.panelOpen)
    }

    @Test func theOpenRingShowsWhileTheTilesScreenIsShowing() async throws {
        let rig = try await SummaryRig.make()
        await rig.scriptDefault()
        await rig.store.refresh()
        #expect(!rig.shell.tileOpen)
        rig.shell.openReviewTile()
        #expect(rig.shell.tileOpen, "needs-you: Review가 보이는 동안")
        rig.shell.openAllWork()
        #expect(!rig.shell.tileOpen)
        rig.shell.openNewestReview()
        rig.shell.dismiss()
        #expect(!rig.shell.tileOpen, "패널이 닫히면 Open이 아니다")
        let quiet = try await SummaryRig.make(reviews: 0)
        await quiet.scriptDefault()
        await quiet.store.refresh()
        quiet.shell.openAllWork()
        #expect(quiet.shell.tileOpen, "changes: 복귀 요약이 있는 All work가 보이는 동안")
    }

    // MARK: ⌥ Space

    @Test func theHotKeyOpensTheNewestReviewWhenSomethingWaitsOtherwiseTheLastView() async throws {
        let rig = try await SummaryRig.make()
        rig.shell.openAllWork()
        rig.shell.dismiss()
        rig.shell.togglePanel()
        #expect(rig.shell.view == .review && rig.shell.reviewID == rig.shell.reviewQueue.newest?.id, "기다리는 결정이 있으면 마지막 화면이 All work여도 가장 새 Review 항목")
        rig.shell.togglePanel()
        #expect(!rig.shell.panelOpen, "열려 있으면 접는다")
        let empty = try await SummaryRig.make(reviews: 0)
        empty.shell.openAllWork()
        empty.shell.dismiss()
        empty.shell.togglePanel()
        #expect(empty.shell.view == .allWork, "기다리는 것이 없으면 마지막 화면")
        // Review가 꺼진 셸은 결정을 열 수 없다
        let off = EdgeShellModel(schedule: { _, _ in EdgeTimer() })
        off.togglePanel()
        #expect(off.view == .allWork)
    }

    // MARK: Chats는 창이다

    @Test func withWindowsTheChatsEntriesOpenAWindowAndNeverThePanelsChats() {
        let shell = EdgeShellModel(schedule: { _, _ in EdgeTimer() }, chatsEnabled: true, windowsEnabled: true)
        var events: [String] = []
        shell.onChats = { events.append("chats") }
        shell.onNewWindow = { events.append("new") }
        shell.onChatsOpened = { events.append("legacy-opened") }
        shell.onNewChat = { events.append("legacy-new") }
        shell.openChats()
        #expect(events == ["chats"] && !shell.panelOpen, "레일 Chats · ⌘3은 창을 열거나 앞으로 가져온다: 패널은 열리지 않는다")
        shell.newChat()
        #expect(events == ["chats", "new"] && !shell.panelOpen, "⌘N은 새 창")
        shell.openPanel(.chats)
        #expect(!shell.panelOpen && shell.view == .allWork, "패널은 Chats 화면을 열지 않는다")
        shell.openAllWork()
        shell.openChats()
        #expect(shell.view == .allWork && shell.panelOpen, "패널이 열려 있어도 그대로: 패널은 접히지 않는다")
        #expect(events == ["chats", "new", "chats"])
        // 옛 패널 Chats 신호는 오지 않는다
        #expect(!events.contains("legacy-opened") && !events.contains("legacy-new"))
    }

    @Test func withoutWindowsTheOldPanelChatsStillWorksForTheSurfacesThatHaveNoWindows() {
        let shell = EdgeShellModel(schedule: { _, _ in EdgeTimer() }, chatsEnabled: true)
        #expect(!shell.windowsEnabled)
        var opened = 0
        shell.onChatsOpened = { opened += 1 }
        shell.openChats()
        #expect(shell.panelOpen && shell.view == .chats && opened == 1)
    }

    @Test func theRailChatsButtonIsHighlightedWhileAWindowIsFrontmost() {
        let shell = EdgeShellModel(schedule: { _, _ in EdgeTimer() }, chatsEnabled: true, windowsEnabled: true)
        #expect(!shell.assistantWindowFront)
        shell.assistantWindowFront = true
        #expect(shell.assistantWindowFront)
    }

    // MARK: 열린 항목 (auto 칩)

    @Test func theOpenItemIsWhatThePanelShowsAndNothingWhileItIsClosed() async throws {
        let rig = try await SummaryRig.make()
        #expect(rig.shell.openItem == nil)
        let id = rig.id(101)
        rig.shell.open(itemID: id)
        #expect(rig.shell.openItem?.id == id, "All work에서 연 일")
        rig.shell.dismiss()
        #expect(rig.shell.openItem == nil, "패널이 닫히면 열린 항목이 없다 (칩은 그대로 둔다)")
        rig.shell.openReview(itemID: rig.id(1))
        #expect(rig.shell.openItem?.id == rig.id(1) && rig.shell.openItem?.title == rig.shell.shownReview?.title, "Review가 보이는 결정")
        rig.shell.openAllWork()
        #expect(rig.shell.openItem == nil, "All work 목록만 보이면 열린 항목이 없다")
    }

    // MARK: 레일 칸 계산

    @Test func theTileTakesTheFirstSlotAndPushesEverythingElseOneStepDown() {
        let plain = EdgeRailLayout(notchCount: 2, restCount: 1, expanded: true, idle: false)
        let tiled = EdgeRailLayout(notchCount: 2, restCount: 1, expanded: true, idle: false, tile: true)
        let step = EdgeRailLayout.item + EdgeRailLayout.gap
        #expect(tiled.tileFrame == CGRect(x: plain.notchFrame(0).minX, y: plain.notchFrame(0).minY, width: 32, height: 32), "맨 위, 링이 있던 자리")
        #expect(tiled.notchFrame(0).minY == plain.notchFrame(0).minY + step)
        #expect(tiled.notchFrame(1).minY == plain.notchFrame(1).minY + step)
        #expect(tiled.restFrame(0).minY == plain.restFrame(0).minY + step)
        #expect(tiled.controlFrame(.allWork).minY == plain.controlFrame(.allWork).minY + step)
        #expect(tiled.controlFrame(.more).minY == plain.controlFrame(.more).minY + step)
        #expect(tiled.ruleY == plain.ruleY + step)
        #expect(tiled.railRect.height == plain.railRect.height + step, "레일은 타일 하나만큼 길다")
        #expect(tiled.moreHeight == plain.moreHeight, "펼친 부분의 높이는 그대로")
        #expect(tiled.railRect.maxY <= EdgeRailLayout.windowHeight)
        // 타일이 없으면 지금 그대로
        #expect(plain.tileFrame == nil && !plain.tile)
    }

    @Test func theHiddenNotchCarriesTheShrunkTileAndTheRingsBelowIt() {
        let plain = EdgeRailLayout(notchCount: 3, restCount: 0, expanded: false, idle: false)
        let tiled = EdgeRailLayout(notchCount: 3, restCount: 0, expanded: false, idle: false, tile: true)
        let step = EdgeRailLayout.item + EdgeRailLayout.gap
        #expect(tiled.railRect.height == plain.railRect.height + step)
        #expect(tiled.tileFrame?.minX == tiled.notchFrame(0).minX, "타일과 링은 같은 줄에 서서 노치 가운데로 모인다")
        #expect(tiled.notchShift == plain.notchShift)
    }

    @Test func windowHeightFitsTheFullestRailTheTileAddsOneSlot() {
        let full = EdgeRailLayout(notchCount: 3, restCount: 1, expanded: true, idle: false, tile: true)
        #expect(full.railRect.maxY + EdgeRailLayout.fillet <= EdgeRailLayout.windowHeight)
        let step = EdgeRailLayout.item + EdgeRailLayout.gap
        let before = EdgeRailLayout.top + EdgeRailLayout.padding + 4 * step + EdgeRailLayout.ruleBlock + EdgeRailLayout.gap + 3 * EdgeRailLayout.item
            + 2 * EdgeRailLayout.gap + EdgeRailLayout.padding + EdgeRailLayout.fillet
        #expect(EdgeRailLayout.windowHeight == before + step)
    }

    @Test func thePointerFindsTheTileAndTheRingsMoveDownWithIt() {
        let tiled = EdgeRailLayout(notchCount: 1, restCount: 0, expanded: true, idle: false, tile: true)
        let tileCenter = CGPoint(x: tiled.tileFrame!.midX, y: tiled.tileFrame!.midY)
        #expect(tiled.hitsTile(tileCenter))
        #expect(tiled.hit(tileCenter, slots: []).control == nil)
        let entry = EdgeShellModelTests.entry(1, .running)
        let ringCenter = CGPoint(x: tiled.notchFrame(0).midX, y: tiled.notchFrame(0).midY)
        #expect(tiled.hit(ringCenter, slots: [entry]).item == entry.id && !tiled.hitsTile(ringCenter))
        let plain = EdgeRailLayout(notchCount: 1, restCount: 0, expanded: true, idle: false)
        #expect(!plain.hitsTile(tileCenter), "타일이 없으면 그 자리는 타일이 아니다")
    }

    @Test func aRailWithATileIsNeverTheIdleNub() async throws {
        let rig = try await SummaryRig.make()
        #expect(rig.shell.reviewTileContent != nil && !rig.shell.isIdle)
        let empty = try await SummaryRig.make(reviews: 0)
        #expect(empty.shell.reviewTileContent == nil && empty.shell.isIdle, "링도 타일도 없으면 가는 줄")
    }
}
