import AppKit
import Foundation
import Testing
@testable import Taskforce
@testable import TaskforceKit
@testable import TaskforceUI

/// 복귀 요약 JSON (서버 C3 head `6cfd382`의 모양, `handoffs/c3-server-notes.md` "Mac에 넘기는 JSON 계약")
enum SummaryJSON {
    static let cursor = "c3.UnitTestCursor-0123456789"
    static let notFound = "{\"error\":{\"code\":\"not_found\",\"message\":\"없는 경로입니다.\"}}"

    static func change(_ source: String = "run", _ kind: String = "done", detail: String? = "draft_ready", sourceState: String? = nil) -> String {
        "{\"source\":\"\(source)\",\"kind\":\"\(kind)\",\"at\":\"2026-10-12T13:00:00.000000Z\",\"detail\":\(detail.map { "\"\($0)\"" } ?? "null"),\"source_state\":\(sourceState.map { "\"\($0)\"" } ?? "null")}"
    }

    static func item(
        _ id: UUID, title: String, state: String? = "in_progress", status: String = "open", decision: String? = nil, changes: [String] = [],
        next: String? = nil
    ) -> String {
        let decisions = decision.map { "[{\"id\":\"\($0):\(id.uuidString.lowercased())\",\"kind\":\"\($0)\",\"version\":\"d1\",\"urgent\":false}]" } ?? "[]"
        let kinds = decision.map { "[\"\($0)\"]" } ?? "[]"
        let nextKind = decision != nil ? "answer" : (next ?? "open")
        return """
        {"action_id":"\(id.uuidString.lowercased())","title":"\(title)","status":"\(status)","state":\(state.map { "\"\($0)\"" } ?? "null"),"needs_answer":\(decision != nil),"urgent":false,\
        "decisions":\(decisions),"changes":[\(changes.joined(separator: ","))],"next":{"kind":"\(nextKind)","decision_kinds":\(kinds)},"version":"v-\(title.count)-\(changes.count)"}
        """
    }

    static func response(
        _ items: [String], cursor: String? = cursor, since: String? = "2026-10-12T08:00:00.000000Z", complete: Bool = true, changes: String = "ok",
        decisions: String = "ok"
    ) -> FakeReply {
        let baseline = since == nil ? "never_cleared" : "cleared"
        let body = """
        {"generated_at":"2026-10-12T21:00:00.000Z","since":\(since.map { "\"\($0)\"" } ?? "null"),"baseline":"\(baseline)","cursor":\(cursor.map { "\"\($0)\"" } ?? "null"),\
        "complete":\(complete),"empty":\(complete && items.isEmpty),"sources":{"changes":"\(changes)","decisions":"\(decisions)"},"items":[\(items.joined(separator: ","))]}
        """
        return .http(200, Data(body.utf8))
    }

    static let clearOK: FakeReply = .http(200, Data("{\"cleared_through\":\"2026-10-12T20:00:00.000000Z\",\"applied\":true}".utf8))
}

/// 진짜 `NowStore` · `ReviewDesk`(선택) · `ReturnSummaryStore` · `APIClient`를 가짜 네트워크 위에서 (`ReviewHarness`). 셸 모델은 앱의 `followWork`처럼 목록을 옮겨 받는다
@MainActor
struct SummaryRig {
    let harness: ReviewHarness
    let desk: ReviewDesk?
    let store: ReturnSummaryStore
    let shell: EdgeShellModel

    static func make(review: Bool = true, reviews: Int = 3) async throws -> SummaryRig {
        let harness = try await ReviewHarness.make(reviews: reviews, open: 2)
        let store = ReturnSummaryStore(gateway: LiveReturnSummaryGateway(services: harness.services), scope: harness.scope)
        let desk = review ? ReviewDesk(now: harness.store, scope: harness.scope) : nil
        let shell = EdgeShellModel(schedule: { _, _ in EdgeTimer() }, review: desk, summary: store)
        await harness.store.load()
        let rig = SummaryRig(harness: harness, desk: desk, store: store, shell: shell)
        rig.sync()
        return rig
    }

    func sync() {
        let now = harness.store
        shell.update(EdgeWorkSnapshot(
            sections: now.sections, working: [], stopping: [], load: WorkLoad.from(refresh: now.refreshState, hasList: now.response != nil),
            doneSince: now.doneTodaySince, canConnect: false
        ))
    }

    func id(_ n: Int) -> UUID { ReviewHarness.id(n) }

    /// 서버가 주는 기본 응답: 확인 요청 1(Review 큐에 있음) · 열린 일 101(실행 결과) · 목록에 없는 취소된 일 900
    func scriptDefault() async {
        await harness.server.scriptSummary(SummaryJSON.response([
            SummaryJSON.item(id(1), title: "Review 1", decision: "confirm", changes: [SummaryJSON.change(detail: "review_failed")]),
            SummaryJSON.item(id(101), title: "Open 1", changes: [SummaryJSON.change()], next: "review_result"),
            SummaryJSON.item(id(900), title: "Gone banner", state: nil, status: "dropped", changes: [SummaryJSON.change("action_event", "dropped", detail: nil, sourceState: "available")]),
        ]))
    }
}

struct C3GateTests {
    // MARK: 플래그

    /// 테스트 호스트에는 `-TF_C3`가 없다: 기본은 꺼짐 (Release도 늘 꺼짐)
    @Test func theFlagIsOffByDefault() {
        #expect(!ProcessInfo.processInfo.arguments.contains("-\(C3Flag.key)"))
        #expect(!C3Flag.isEnabled())
        #expect(C3Flag.key == "TF_C3")
    }

    /// 저장된 defaults로는 켜지지 않는다: 인자 영역만 (테스트는 전용 suite를 넘긴다)
    @Test func theFlagFollowsAnInjectedSuiteNotTheStoredDefaults() throws {
        let store = try TestDefaults()
        defer { store.cleanup() }
        #expect(!C3Flag.isEnabled(store.defaults))
        store.defaults.set(true, forKey: C3Flag.key)
        #expect(C3Flag.isEnabled(store.defaults))
        store.defaults.set(false, forKey: C3Flag.key)
        #expect(!C3Flag.isEnabled(store.defaults))
    }

    /// 다른 축이다: Edge 셸 · S3b · S4 플래그가 C3를 켜지 않고, C3가 그것들을 켜지 않는다
    @Test func theOtherFlagsDoNotTurnC3OnAndC3DoesNotTurnThemOn() throws {
        let store = try TestDefaults()
        defer { store.cleanup() }
        store.defaults.set(true, forKey: EdgeShellFlag.key)
        store.defaults.set(true, forKey: S3bFlag.key)
        store.defaults.set(true, forKey: S4Flag.key)
        #expect(EdgeShellFlag.isEnabled(store.defaults) && S3bFlag.isEnabled(store.defaults) && S4Flag.isEnabled(store.defaults) && !C3Flag.isEnabled(store.defaults))
        let only = try TestDefaults()
        defer { only.cleanup() }
        only.defaults.set(true, forKey: C3Flag.key)
        #expect(C3Flag.isEnabled(only.defaults) && !EdgeShellFlag.isEnabled(only.defaults) && !S3bFlag.isEnabled(only.defaults) && !S4Flag.isEnabled(only.defaults))
    }

    // MARK: 실제 생성 경로 (`AppRuntime.returnSummary`가 부르는 같은 함수)

    final class GatewaySpy: ReturnSummaryGateway, @unchecked Sendable {
        private let lock = NSLock()
        private var _reads = 0
        var reads: Int { lock.withLock { _reads } }
        func returnSummary() async throws -> ReturnSummaryResponse {
            lock.withLock { _reads += 1 }
            throw APIError.notSignedIn
        }
        func clearReturnSummary(cursor: String) async throws -> ReturnSummaryClearResponse { throw APIError.notSignedIn }
    }

    @MainActor
    @Test func theCreationPathMakesNoStoreAndNoGatewayUnlessOn() async throws {
        let harness = try await ReviewHarness.make()
        var made = 0
        let spy = GatewaySpy()
        func gateway() -> (any ReturnSummaryGateway)? {
            made += 1
            return spy
        }
        // 기본 · off: 게이트웨이도 저장소도 만들지 않는다
        #expect(AppRuntime.makeReturnSummaryStore(makeGateway: gateway, scope: harness.scope, c3: false) == nil && made == 0)
        #expect(AppRuntime.returnSummary(services: harness.services, scope: harness.scope) == nil, "테스트 실행에는 인자가 없다: 실제 경로는 기본 꺼짐")
        // on이어도 게이트웨이나 계정 경계가 없으면 만들지 않는다
        #expect(AppRuntime.makeReturnSummaryStore(makeGateway: { nil }, scope: harness.scope, c3: true) == nil)
        #expect(AppRuntime.makeReturnSummaryStore(makeGateway: gateway, scope: nil, c3: true) == nil)
        #expect(AppRuntime.returnSummary(services: nil, scope: harness.scope) == nil)
        // on
        let store = try #require(AppRuntime.makeReturnSummaryStore(makeGateway: gateway, scope: harness.scope, c3: true))
        #expect(made == 1 && store.summary == nil && spy.reads == 0, "게이트웨이는 켜졌고 계정 경계가 있을 때 한 번만 만들고, 만들기만으로 서버를 읽지 않는다")
    }

    /// 실제 Edge 컨트롤러가 받은 저장소를 셸에 그대로 넘기고, off면 셸에 아무것도 없다
    @MainActor
    @Test func theControllerHandsTheStoreToTheShellOrNothing() async throws {
        let harness = try await ReviewHarness.make()
        let launcher = LauncherModel(configurationError: "test")
        let off = EdgeShellController(launcher: launcher, chat: nil, review: nil)
        #expect(off.shell.summary == nil && off.shell.summaryContent == nil)
        let store = ReturnSummaryStore(gateway: LiveReturnSummaryGateway(services: harness.services), scope: harness.scope)
        let on = EdgeShellController(launcher: launcher, chat: nil, review: nil, summary: store)
        #expect(on.shell.summary === store && on.shell.summaryContent == nil, "읽기 전에는 아무것도 보이지 않는다")
        #expect(await harness.server.summaryReadCount() == 0)
    }

    /// off: 셸에 요약이 없다. 요약 입구(Clear · 줄 · Try again)는 아무것도 하지 않거나 지금 동작 그대로다 — 서버를 부르지 않는다
    @MainActor
    @Test func offTheShellHasNoSummaryAndEveryEntryIsInert() async throws {
        let harness = try await ReviewHarness.make()
        await harness.store.load()
        let shell = EdgeShellModel(schedule: { _, _ in EdgeTimer() })
        shell.update(EdgeWorkSnapshot(sections: harness.store.sections, working: [], stopping: [], load: .loaded(problem: nil), doneSince: nil, canConnect: false))
        #expect(shell.summary == nil && shell.summaryContent == nil)
        shell.openAllWork()
        #expect(shell.clearSummary() == nil)
        shell.retrySummary()
        // 줄 입구는 지금 All work의 다른 줄과 같다
        shell.openSummaryRow(ReviewHarness.id(101))
        #expect(shell.panelOpen && shell.view == .allWork && shell.currentID == ReviewHarness.id(101))
        let requests = await harness.server.summaryRequests
        let writes = await harness.server.writeCount()
        #expect(requests.isEmpty && writes == 0)
    }

    /// default / off / on 생성 경로 대조: 요약 저장소만 다르고(on은 아직 읽지 않았다) 셸이 보이는 것은 모두 같다 — C3는 읽기 전까지 지금 화면을 바꾸지 않는다
    @MainActor
    @Test func defaultOffAndOnLookTheSameUntilTheFirstRead() async throws {
        let harness = try await ReviewHarness.make(reviews: 3, open: 2)
        await harness.store.load()
        let work = EdgeWorkSnapshot(sections: harness.store.sections, working: [], stopping: [], load: .loaded(problem: nil), doneSince: nil, canConnect: false)
        let store = ReturnSummaryStore(gateway: LiveReturnSummaryGateway(services: harness.services), scope: harness.scope)
        let shells = [
            EdgeShellModel(schedule: { _, _ in EdgeTimer() }),
            EdgeShellModel(schedule: { _, _ in EdgeTimer() }, summary: nil),
            EdgeShellModel(schedule: { _, _ in EdgeTimer() }, summary: store),
        ]
        func state(_ shell: EdgeShellModel) -> [String] {
            shell.update(work)
            shell.openAllWork()
            shell.open(itemID: ReviewHarness.id(101))
            return [
                "\(shell.view)", "\(shell.panelOpen)", "\(String(describing: shell.currentID))", shell.slots.map { "\($0.id)\($0.kind)" }.joined(separator: ","),
                shell.workItems.map { "\($0.id)\($0.state)" }.joined(separator: ","), "\(shell.reviewQueue.ids)", "\(shell.summaryContent == nil)",
            ]
        }
        let results = shells.map(state)
        #expect(results[0] == results[1] && results[1] == results[2])
        #expect(await harness.server.summaryRequests.isEmpty)
    }
}

@MainActor
struct EdgeSummaryTests {
    // MARK: 읽기 (진짜 APIClient)

    @Test func theRealClientReadsTheV2RouteWithABearerTokenAndShowsRows() async throws {
        let rig = try await SummaryRig.make()
        await rig.scriptDefault()
        await rig.store.refresh()
        let requests = await rig.harness.server.summaryRequests
        #expect(requests.count == 1 && requests[0].method == "GET" && requests[0].path == "/api/v2/return-summary" && requests[0].body == nil)
        #expect(requests[0].authorization == "Bearer access-\(ReviewHarness.userID)")
        let content = try #require(rig.shell.summaryContent)
        #expect(content.rows.map(\.title) == ["Review 1", "Open 1", "Gone banner"])
        #expect(content.rows.map(\.canOpen) == [true, true, false], "목록에 없는 작업은 열 곳이 없다")
        #expect(content.rows.first?.detail == "Needs your answer · Review failed" && content.rows[1].detail == "Draft ready · Next: review the result")
        #expect(content.title.hasPrefix("Since "), "마지막 Clear 시각이 있으면 Since …")
        #expect(content.canClear)
    }

    @Test func aGateOffServerShowsNothingAndNoMessage() async throws {
        let rig = try await SummaryRig.make()
        await rig.harness.server.scriptSummary(.http(404, Data(SummaryJSON.notFound.utf8)))
        await rig.store.refresh()
        #expect(rig.shell.summaryContent == nil && rig.store.message == nil && rig.store.featureOff && !rig.store.readFailed)
    }

    @Test func aCompleteEmptyResponseShowsNothing() async throws {
        let rig = try await SummaryRig.make()
        await rig.harness.server.scriptSummary(SummaryJSON.response([]))
        await rig.store.refresh()
        #expect(rig.store.summary?.isEmpty == true && rig.shell.summaryContent == nil)
    }

    @Test func anUnavailableOrTruncatedResponseIsNeverTreatedAsEmpty() async throws {
        let rig = try await SummaryRig.make()
        await rig.harness.server.scriptSummary(SummaryJSON.response([], cursor: nil, complete: false, changes: "unavailable"))
        await rig.store.refresh()
        #expect(rig.shell.summaryContent?.notes == [.couldNotLoad] && rig.shell.summaryContent?.canClear == false)
        await rig.harness.server.scriptSummary(SummaryJSON.response([SummaryJSON.item(rig.id(101), title: "Open 1", changes: [SummaryJSON.change()])], complete: false, changes: "truncated"))
        await rig.store.refresh()
        let truncated = try #require(rig.shell.summaryContent)
        #expect(truncated.rows.count == 1 && truncated.notes == [.someNotShown] && truncated.canClear, "서버가 커서를 주면 잘려도 Clear는 보인다")
    }

    // MARK: Clear (진짜 APIClient, 읽음 처리일 뿐)

    @Test func clickingClearSendsTheCursorVerbatimThenReadsAgainAndNothingElse() async throws {
        let rig = try await SummaryRig.make()
        await rig.scriptDefault()
        await rig.store.refresh()
        rig.shell.openAllWork()
        let nowReads = await rig.harness.server.nowRequests
        await rig.harness.server.scriptSummary(
            SummaryJSON.response([SummaryJSON.item(rig.id(1), title: "Review 1", decision: "confirm")], cursor: "c3.after")
        )
        let task = try #require(rig.shell.clearSummary())
        #expect(rig.store.isClearing && rig.shell.clearSummary() == nil, "보내는 중에는 받지 않는다")
        #expect(await task.value == .cleared(applied: true))
        let requests = await rig.harness.server.summaryRequests
        #expect(requests.map(\.method) == ["GET", "POST", "GET"])
        #expect(requests[1].path == "/api/v2/return-summary/clear" && requests[1].authorization == "Bearer access-\(ReviewHarness.userID)")
        #expect(await rig.harness.server.clearCursors() == [SummaryJSON.cursor])
        #expect(await rig.harness.server.writeCount() == 0, "Clear는 결정 · Action을 바꾸지 않는다")
        #expect(await rig.harness.server.nowRequests == nowReads, "Clear는 /now를 다시 읽지도 않는다")
        // 읽음은 결정이 아니다: Clear 뒤에도 Needs your answer 줄은 남는다 (Clear 버튼은 없다)
        let after = try #require(rig.shell.summaryContent)
        #expect(after.rows.map(\.title) == ["Review 1"] && after.rows.first?.needsAnswer == true && !after.canClear && !rig.store.isClearing)
        #expect(rig.harness.store.sections.review.map(\.id) == [rig.id(1), rig.id(2), rig.id(3)], "Review 큐는 그대로")
    }

    @Test func clearIsOnlyHeardOnAllWorkWithAnOpenPanel() async throws {
        let rig = try await SummaryRig.make()
        await rig.scriptDefault()
        await rig.store.refresh()
        #expect(rig.shell.clearSummary() == nil, "패널이 닫혀 있다")
        rig.shell.openChats()
        #expect(rig.shell.clearSummary() == nil, "All work가 아니다")
        rig.shell.openAllWork()
        let task = try #require(rig.shell.clearSummary())
        #expect(await task.value == .cleared(applied: true))
    }

    /// 받는 동기 경계에서 예약된 Clear가 보내기 전에 패널이 닫히면 쓰기 0 (진행 표시도 거둔다)
    @Test func aClearQueuedBeforeThePanelClosesSendsNothing() async throws {
        let rig = try await SummaryRig.make()
        await rig.scriptDefault()
        await rig.store.refresh()
        rig.shell.openAllWork()
        let task = try #require(rig.shell.clearSummary())
        rig.shell.dismiss()
        #expect(await task.value == .ignored)
        #expect(await rig.harness.server.clearCursors().isEmpty && !rig.store.isClearing)
        // 다시 열면 다시 누를 수 있다 (옛 선택이 새 상태로 나가지 않았다)
        rig.shell.openAllWork()
        let again = try #require(rig.shell.clearSummary())
        #expect(await again.value == .cleared(applied: true))
        #expect(await rig.harness.server.clearCursors() == [SummaryJSON.cursor], "나간 것은 다시 연 뒤의 선택 하나뿐")
    }

    /// P2-M1 (Codex 통합 검토): 한 방문에서 받은 Clear가 다음 방문에서 나가면 안 된다. 받는 경계에서 All work **방문**의 소유(`allWorkPresentation`)를 잡고 보내기 직전에 다시 본다 —
    /// "지금 All work가 보이는가"만으로는 닫았다 다시 열거나 Chats에 갔다 돌아온 새 방문을 가르지 못한다 (S4 `reviewPresentation`과 같은 방식)
    @Test func aClearQueuedInOneVisitIsNotSentInTheNextVisitAfterDismissAndReopen() async throws {
        let rig = try await SummaryRig.make()
        await rig.scriptDefault()
        await rig.store.refresh()
        rig.shell.openAllWork()
        let task = try #require(rig.shell.clearSummary())
        // await 없이: 닫았다가 곧바로 다시 연다
        rig.shell.dismiss()
        rig.shell.openAllWork()
        #expect(await task.value == .ignored)
        #expect(await rig.harness.server.clearCursors().isEmpty && !rig.store.isClearing)
        let requests = await rig.harness.server.summaryRequests
        #expect(requests.allSatisfy { $0.method == "GET" })
    }

    @Test func aClearQueuedInOneVisitIsNotSentAfterChatsAndBackToAllWork() async throws {
        let rig = try await SummaryRig.make()
        await rig.scriptDefault()
        await rig.store.refresh()
        rig.shell.openAllWork()
        let task = try #require(rig.shell.clearSummary())
        rig.shell.openChats()
        rig.shell.openAllWork()
        #expect(await task.value == .ignored)
        #expect(await rig.harness.server.clearCursors().isEmpty && !rig.store.isClearing)
    }

    /// 대조: 같은 방문 안의 움직임(⌘2를 한 번 더, 줄 열기)은 방문을 바꾸지 않는다 → 정확히 한 번 나간다
    @Test func aClearQueuedAndFollowedByOrdinaryMovesInTheSameVisitIsSentOnce() async throws {
        let rig = try await SummaryRig.make()
        await rig.scriptDefault()
        await rig.store.refresh()
        rig.shell.openAllWork()
        let task = try #require(rig.shell.clearSummary())
        rig.shell.open(itemID: rig.id(101))
        rig.shell.openAllWork()
        #expect(await task.value == .cleared(applied: true))
        #expect(await rig.harness.server.clearCursors() == [SummaryJSON.cursor])
    }

    @Test func aClearQueuedBeforeAnotherViewTookTheScreenSendsNothing() async throws {
        let rig = try await SummaryRig.make()
        await rig.scriptDefault()
        await rig.store.refresh()
        rig.shell.openAllWork()
        let task = try #require(rig.shell.clearSummary())
        rig.shell.openChats()
        #expect(await task.value == .ignored)
        #expect(await rig.harness.server.clearCursors().isEmpty)
    }

    /// 같은 UUID 재로그인: 예약된 선택은 새 세션으로 나가지 않는다
    @Test func aClearQueuedBeforeAReloginSendsNothingUnderTheNewSession() async throws {
        let rig = try await SummaryRig.make()
        await rig.scriptDefault()
        await rig.store.refresh()
        rig.shell.openAllWork()
        let task = try #require(rig.shell.clearSummary())
        rig.harness.reloginSameUser()
        #expect(await task.value == .ignored)
        #expect(await rig.harness.server.clearCursors().isEmpty && rig.store.summary == nil && rig.shell.summaryContent == nil)
    }

    /// 이미 서버로 나간 Clear의 늦은 응답은 새 세션에 반영되지 않는다 (다시 읽지도 않는다)
    @Test func aClearThatOutlivesTheSessionIsDropped() async throws {
        let rig = try await SummaryRig.make()
        await rig.scriptDefault()
        await rig.store.refresh()
        rig.shell.openAllWork()
        await rig.harness.server.holdClearRequests()
        let task = try #require(rig.shell.clearSummary())
        #expect(await rig.harness.wait { await rig.harness.server.pendingClears() == 1 })
        let reads = await rig.harness.server.summaryReadCount()
        rig.harness.reloginSameUser()
        await rig.harness.server.releaseClears()
        #expect(await task.value == .ignored)
        #expect(await rig.harness.server.summaryReadCount() == reads, "옛 세션의 응답이 새 읽기를 일으키지 않는다")
        #expect(rig.store.summary == nil && rig.store.message == nil && !rig.store.isClearing)
    }

    @Test func tokenRefreshDoesNotDropTheSummary() async throws {
        let rig = try await SummaryRig.make()
        await rig.scriptDefault()
        await rig.store.refresh()
        try rig.harness.refreshToken()
        #expect(rig.store.summary != nil && rig.shell.summaryContent?.rows.count == 3)
    }

    @Test func aConflictRefreshesAndNeverResends() async throws {
        let rig = try await SummaryRig.make()
        await rig.scriptDefault()
        await rig.store.refresh()
        rig.shell.openAllWork()
        await rig.harness.server.scriptClear(.http(409, Data("{\"error\":{\"code\":\"conflict\",\"message\":\"변화가 있습니다.\"}}".utf8)))
        await rig.harness.server.scriptSummary(
            SummaryJSON.response([SummaryJSON.item(rig.id(101), title: "Open 1", changes: [SummaryJSON.change("action_event", "due_changed", detail: nil, sourceState: "available")])], cursor: "c3.fresh")
        )
        #expect(await rig.shell.clearSummary()?.value == .conflict)
        #expect(await rig.harness.server.clearCursors() == [SummaryJSON.cursor], "자동 재전송 없음")
        let content = try #require(rig.shell.summaryContent)
        #expect(content.message == "This changed somewhere else. It's been refreshed.")
        #expect(content.rows.map(\.title) == ["Open 1"] && content.canClear, "새 변화가 남아 있고 새 커서로 다시 누를 수 있다")
        #expect(await rig.harness.server.writeCount() == 0)
    }

    // MARK: 줄 열기 (S4 Review 연결은 이미 지원되는 범위만)

    @Test func aConfirmRowOpensItsReviewWhenS4IsOn() async throws {
        let rig = try await SummaryRig.make(review: true)
        await rig.scriptDefault()
        await rig.store.refresh()
        rig.shell.openSummaryRow(rig.id(1))
        #expect(rig.shell.panelOpen && rig.shell.view == .review && rig.shell.shownReview?.id == rig.id(1))
        #expect(await rig.harness.server.writeCount() == 0, "열기는 어떤 답도 아니다")
        // 결정이 없는 줄은 그 작업을 연다 (일 상세는 아직 없다)
        rig.shell.openSummaryRow(rig.id(101))
        #expect(rig.shell.view == .allWork && rig.shell.currentID == rig.id(101))
    }

    @Test func aConfirmRowOpensTheWorkWhenS4IsOff() async throws {
        let rig = try await SummaryRig.make(review: false)
        await rig.scriptDefault()
        await rig.store.refresh()
        rig.shell.openSummaryRow(rig.id(1))
        #expect(rig.shell.view == .allWork && rig.shell.currentID == rig.id(1) && rig.shell.review == nil)
    }

    /// Review가 답할 수 없는 결정(approval · review_failed · run_input)은 S4b의 몫이다: 그 작업을 연다
    @Test func aDecisionReviewCannotAnswerOpensTheWorkNotReview() async throws {
        let rig = try await SummaryRig.make(review: true)
        await rig.harness.server.scriptSummary(SummaryJSON.response([SummaryJSON.item(rig.id(2), title: "Review 2", decision: "approval")]))
        await rig.store.refresh()
        rig.shell.openSummaryRow(rig.id(2))
        #expect(rig.shell.view == .allWork && rig.shell.currentID == rig.id(2))
    }

    @Test func answeringInReviewReadsTheSummaryAgainSoNeedsYourAnswerIsNotStale() async throws {
        let rig = try await SummaryRig.make(review: true)
        await rig.scriptDefault()
        await rig.store.refresh()
        let reads = await rig.harness.server.summaryReadCount()
        rig.shell.openReview(itemID: rig.id(2))
        let answer = try #require(rig.shell.answer(.confirm, for: rig.id(2)))
        #expect(await answer.value == .applied)
        #expect(await rig.harness.server.summaryReadCount() == reads + 1)
        #expect(await rig.harness.server.summaryRequests.allSatisfy { $0.method == "GET" }, "답한 뒤의 요약 읽기는 읽음 처리가 아니다")
    }
}
