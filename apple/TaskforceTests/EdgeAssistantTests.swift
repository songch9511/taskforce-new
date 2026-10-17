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

    @Test func theAssistantWindowSurfaceNeedsBothTheShellAndChats() {
        func surfaces(shell: Bool, chats: Bool) -> EdgeSurfaces {
            EdgeSurfaces(shell: shell, review: false, summary: false, chats: chats, projects: false, settingsWindow: false)
        }
        #expect(surfaces(shell: true, chats: true).assistantWindows)
        #expect(!surfaces(shell: false, chats: true).assistantWindows, "셸 없이 창만 있을 수 없다")
        #expect(!surfaces(shell: true, chats: false).assistantWindows, "Chats가 꺼지면 창도 없다")
    }

    @Test func theShellUsesWindowsOnlyWhenChatsAreOnToo() {
        func windows(chats: Bool, windows: Bool) -> Bool {
            EdgeShellModel(schedule: { _, _ in EdgeTimer() }, chatsEnabled: chats, windowsEnabled: windows).windowsEnabled
        }
        #expect(windows(chats: true, windows: true))
        #expect(!windows(chats: false, windows: true), "Chats가 꺼진 셸은 창을 켤 수 없다")
        #expect(!windows(chats: true, windows: false))
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

    /// OA U2b: 바뀐 것만 있으면 타일은 없다 (답할 것이 있을 때만 있다)
    @Test func noTileWhenOnlyChangesWait() async throws {
        let rig = try await SummaryRig.make(reviews: 0)
        #expect(rig.shell.reviewQueue.count == 0)
        await rig.scriptDefault()
        await rig.store.refresh()
        #expect(rig.shell.summary?.summary?.hasChangesToClear == true, "시험 전제: 읽음 처리할 변화가 있다")
        #expect(rig.shell.reviewTileContent == nil)
        #expect(rig.shell.tileTooltip == nil && rig.shell.tileAccessibilityName == nil)
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

    @Test func clickingTheTileOpensTheNewestReviewAndNothingElse() async throws {
        let waiting = try await SummaryRig.make()
        await waiting.scriptDefault()
        await waiting.store.refresh()
        waiting.shell.openReviewTile()
        #expect(waiting.shell.panelOpen && waiting.shell.view == .review && waiting.shell.reviewID == waiting.shell.reviewQueue.newest?.id)
        let quiet = try await SummaryRig.make(reviews: 0)
        await quiet.scriptDefault()
        await quiet.store.refresh()
        quiet.shell.openReviewTile()
        #expect(!quiet.shell.panelOpen, "changes만 있으면 타일이 없다: 눌러도 아무 일 없다")
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
        #expect(!quiet.shell.tileOpen, "타일이 없으면 Open도 없다")
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
        let idle = EdgeRailLayout(notchCount: 0, restCount: 0, expanded: false, idle: true, tile: true)
        #expect(!idle.hitsTile(CGPoint(x: idle.tileFrame!.midX, y: idle.tileFrame!.midY)), "가는 줄(idle)은 타일이 아니다")
    }

    @Test func aRailWithATileIsNeverTheIdleNub() async throws {
        let rig = try await SummaryRig.make()
        #expect(rig.shell.reviewTileContent != nil && !rig.shell.isIdle)
        let empty = try await SummaryRig.make(reviews: 0)
        #expect(empty.shell.reviewTileContent == nil && empty.shell.isIdle, "링도 타일도 없으면 가는 줄")
        // 바뀐 것만 있으면 링도 타일도 없다: 가는 줄이다
        let quiet = try await SummaryRig.make(reviews: 0)
        await quiet.scriptDefault()
        await quiet.store.refresh()
        quiet.shell.update(EdgeWorkSnapshot(
            sections: TaskSections(review: [], inProgress: [], toDo: [], doneToday: []), working: [], stopping: [],
            load: WorkLoad.from(refresh: quiet.harness.store.refreshState, hasList: true), doneSince: nil, canConnect: false
        ))
        #expect(quiet.shell.notch.isEmpty && !quiet.shell.isExpanded, "링이 하나도 없고 접혀 있다")
        #expect(quiet.shell.reviewTileContent == nil && quiet.shell.isIdle, "바뀐 것만으로는 타일이 없다")
    }
}

/// OA U2b: ⌘1은 답할 것이 있으면 가장 새 Review 항목, 없고 바뀐 것만 있으면 그 구성에서 복귀 요약이 보이는 곳, 둘 다 없으면 아무것도 하지 않는다.
/// OA U3-40: **Taskforce 대화가 켜진 구성(새 Issues 화면 + S4 + C3)은 ⌘1이 늘 대화를 연다** — 요청이 있으면 서버 순서 첫 요청, 없으면 빈 상태 + 요약 (U2b의 "아무것도 안 함" 두 경우가 사라진다).
/// 게이트 꺼짐 구성(Release 표면 포함)은 U2b 그대로다
@MainActor
struct EdgeCommandOneTests {
    /// U2(새 Issues 화면)까지 켠 셸: Review(S4) + 복귀 요약(C3) + Issues. 요약을 읽은 상태로 만든다
    func issuesRig(reviews: Int, summary: Bool) async throws -> (shell: EdgeShellModel, base: SummaryRig) {
        let harness = try await ReviewHarness.make(reviews: reviews, open: 2)
        let store = ReturnSummaryStore(gateway: LiveReturnSummaryGateway(services: harness.services), scope: harness.scope)
        let desk = ReviewDesk(now: harness.store, scope: harness.scope)
        let issues = IssueRuntime(gateway: IssueSampleGateway(), scope: harness.scope)
        let shell = EdgeShellModel(schedule: { _, _ in EdgeTimer() }, review: desk, summary: store, chatsEnabled: true, windowsEnabled: true, issues: issues, taskforceGate: true)
        await harness.store.load()
        let rig = SummaryRig(harness: harness, desk: desk, store: store, shell: shell)
        rig.sync()
        if summary {
            await rig.scriptDefault()
            await store.refresh()
        }
        return (shell, rig)
    }

    @Test func withSomethingToAnswerItOpensTheNewestReview() async throws {
        let rig = try await SummaryRig.make()
        await rig.scriptDefault()
        await rig.store.refresh()
        rig.shell.openNewestReview()
        #expect(rig.shell.panelOpen && rig.shell.view == .review && rig.shell.reviewID == rig.shell.reviewQueue.newest?.id, "바뀐 것도 있지만 답할 것이 먼저")
        let gated = try await issuesRig(reviews: 3, summary: true)
        gated.shell.openNewestReview()
        #expect(gated.shell.taskforceEnabled && gated.shell.panelOpen && gated.shell.view == .review, "U2 + C3(Taskforce 대화): 대화를 연다 (OA U3-40)")
        #expect(gated.shell.reviewQueue.isEmpty && gated.shell.reviewID == nil, "v1 Review 큐는 이 구성에 없다")
    }

    @Test func withOnlyChangesItOpensWhereTheSummaryIsDrawn() async throws {
        // 게이트가 꺼진 구성(Release 표면 포함): 복귀 요약은 All work 위 카드다
        let rig = try await SummaryRig.make(reviews: 0)
        await rig.scriptDefault()
        await rig.store.refresh()
        #expect(rig.shell.reviewQueue.count == 0 && rig.shell.summaryContent != nil && !rig.shell.issueScreensEnabled)
        rig.shell.openNewestReview()
        #expect(rig.shell.panelOpen && rig.shell.view == .allWork, "All work의 카드")
        // 이미 Review가 열려 있어도 카드가 있는 곳으로 간다
        rig.shell.dismiss()
        rig.shell.openPanel(.review)
        rig.shell.openNewestReview()
        #expect(rig.shell.view == .allWork)
    }

    /// Taskforce 대화가 켜진 구성에서는 대화가 요약이 그려지는 곳이다 (U2b의 "열 곳이 없어 무동작"은 사라졌다, OA U3-40)
    @Test func withOnlyChangesTheTaskforceConversationIsWhereTheSummaryIsDrawn() async throws {
        let rig = try await issuesRig(reviews: 0, summary: true)
        #expect(rig.shell.issueScreensEnabled && rig.shell.summary?.summary?.hasChangesToClear == true && rig.shell.reviewQueue.count == 0)
        rig.shell.openNewestReview()
        #expect(rig.shell.panelOpen && rig.shell.view == .review, "빈 대화 + 요약")
    }

    @Test func withNothingAtAllItDoesNothing() async throws {
        // 목록을 읽었고 답할 것도 바뀐 것도 없다
        let rig = try await SummaryRig.make(reviews: 0)
        rig.shell.openNewestReview()
        #expect(!rig.shell.panelOpen, "빈 \"No decisions waiting\" 화면을 열지 않는다")
        let issues = try await issuesRig(reviews: 0, summary: false)
        issues.shell.openNewestReview()
        #expect(issues.shell.panelOpen && issues.shell.view == .review, "Taskforce 대화: 아무것도 없어도 늘 대화를 연다 (빈 상태, OA U3-40)")
        // 열려 있던 패널도 그대로다
        rig.shell.openAllWork()
        rig.shell.openNewestReview()
        #expect(rig.shell.panelOpen && rig.shell.view == .allWork)
        // 요약 없이 Review만 켜진 셸 (C3 꺼짐)
        let reviewOnly = try await ReviewRig.make(reviews: 0)
        reviewOnly.shell.openNewestReview()
        #expect(!reviewOnly.shell.panelOpen)
    }

    @Test func aListThatHasNotArrivedStillOpensReviewSoItCanSayWhy() async throws {
        let rig = try await SummaryRig.make(reviews: 0)
        let loading = EdgeShellModel(schedule: { _, _ in EdgeTimer() }, review: rig.desk, summary: rig.store)
        loading.openNewestReview()
        #expect(loading.panelOpen && loading.view == .review && loading.reviewScreen == .blank, "읽는 중 · 오프라인 · 읽기 실패는 빈 큐가 아니다")
        loading.update(EdgeWorkSnapshot(load: .offline))
        #expect(loading.reviewScreen == .offline)
    }
}
