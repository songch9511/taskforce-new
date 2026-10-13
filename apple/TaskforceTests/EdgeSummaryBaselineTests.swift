import Foundation
import Testing
@testable import Taskforce
@testable import TaskforceKit
@testable import TaskforceUI

/// C — 첫 정상 표시 기준점 확정을 진짜 셸 경로로 (`EdgeShellModel` · `ReturnSummaryStore` · `APIClient` + 가짜 네트워크, A–D 후속 계약 `handoffs/c3-ad-contract.md` C).
/// 정상 표시가 된 그때 동기 경계에서 계정 token · 서버 토큰 · All work 방문(`allWorkPresentation`)을 잡고 보내기 직전에 다시 본다 (Clear · P2-M1과 같은 방식).
/// 읽기 실패 · 닫힘 · Chats 갔다 오기 · 겹친 읽기 · 같은 UUID 재로그인이면 쓰기 0, 이미 나간 요청은 정직한 결과, 409 · 응답 유실은 자동 재전송 없이 다음 정상 표시의 새 토큰으로
@MainActor
struct EdgeSummaryBaselineTests {
    static let token = "i1.MAC-TEST-TOKEN"
    static let tokenPath = "/api/v2/return-summary/baseline"

    func change() -> String { SummaryJSON.change("action_event", "due_changed", detail: nil, sourceState: "available") }

    func firstUse(_ rig: SummaryRig, token: String? = token, changes: String = "ok", changeJSON: String? = nil, baseline: String? = nil, cursor: String? = SummaryJSON.cursor) -> FakeReply {
        SummaryJSON.response(
            [SummaryJSON.item(rig.id(101), title: "Open 1", changes: [changeJSON ?? change()])], cursor: cursor, since: nil, baseline: baseline, initToken: token,
            complete: changes == "ok", changes: changes
        )
    }

    func initialized(_ rig: SummaryRig) -> FakeReply {
        SummaryJSON.response([SummaryJSON.item(rig.id(101), title: "Open 1", changes: [change()])], since: nil, baseline: "initialized")
    }

    /// 서버로 나간 확정 수가 `count`가 되고 진행이 끝날 때까지 기다린다
    func settled(_ rig: SummaryRig, posts count: Int) async -> Bool {
        await rig.harness.wait { await rig.harness.server.baselineTokens().count == count && !rig.store.isConfirmingBaseline }
    }

    /// 몇 번 양보해도 아무것도 나가지 않는다 (쓰기 0)
    func quiet(_ rig: SummaryRig) async -> Int {
        for _ in 0..<60 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(60))
        return await rig.harness.server.baselineTokens().count
    }

    // MARK: 정상 표시 → 확정 한 번 → 다시 조회

    @Test func aNormalFirstDisplayConfirmsOnceThroughTheRealShellThenReadsAgain() async throws {
        let rig = try await SummaryRig.make(review: false)
        let nowReads = await rig.harness.server.nowRequests
        await rig.harness.server.scriptSummary(firstUse(rig), initialized(rig))
        rig.shell.openAllWork()
        await rig.store.refresh()
        #expect(await settled(rig, posts: 1))
        let requests = await rig.harness.server.summaryRequests
        #expect(requests.map(\.method) == ["GET", "POST", "GET"], "읽고 → 확정 → 다시 읽는다")
        #expect(requests[1].path == Self.tokenPath && requests[1].authorization == "Bearer access-\(ReviewHarness.userID)")
        let body = try #require(requests[1].body)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        #expect(object as NSDictionary == ["init_token": Self.token], "서버가 준 토큰 그대로, 다른 키 · 시각 없음")
        #expect(rig.store.summary?.baseline == .initialized && rig.store.summary?.initToken == nil)
        // 읽음 표시일 뿐이다: Clear도 결정도 보내지 않았고 /now도 다시 읽지 않았다
        let clearCursors = await rig.harness.server.clearCursors()
        let writes = await rig.harness.server.writeCount()
        #expect(clearCursors.isEmpty && writes == 0)
        #expect(await rig.harness.server.nowRequests == nowReads)
        #expect(rig.shell.summaryContent?.title == "Changes")
    }

    /// 빈 첫 화면(완전하고 줄이 없음)도 정상 표시다
    @Test func anEmptyFirstScreenConfirmsToo() async throws {
        let rig = try await SummaryRig.make(review: false)
        await rig.harness.server.scriptSummary(SummaryJSON.response([], since: nil, initToken: Self.token))
        rig.shell.openAllWork()
        await rig.store.refresh()
        #expect(await settled(rig, posts: 1) && rig.shell.summaryContent == nil)
    }

    @Test func aTruncatedNormalPageStillConfirms() async throws {
        let rig = try await SummaryRig.make(review: false)
        await rig.harness.server.scriptSummary(firstUse(rig, changes: "truncated"), initialized(rig))
        rig.shell.openAllWork()
        await rig.store.refresh()
        #expect(await settled(rig, posts: 1))
    }

    // MARK: 정상 표시가 아니면 쓰기 0

    @Test func anAbnormalDisplayNeverSendsAnything() async throws {
        let cases: [(String, FakeReply)] = try await {
            let rig = try await SummaryRig.make(review: false)
            return [
                ("no token", firstUse(rig, token: nil)),
                ("changes unavailable", firstUse(rig, token: Self.token, changes: "unavailable", cursor: nil)),
                ("uninterpretable change shown", firstUse(rig, changeJSON: SummaryJSON.change("run", "done", detail: "mystery"))),
                ("a cleared user with a stray token", firstUse(rig, baseline: "cleared")),
                ("already initialized with a stray token", firstUse(rig, baseline: "initialized")),
                ("server error", .http(500, Data(SummaryJSON.notFound.utf8))),
                ("feature off", .http(404, Data(SummaryJSON.notFound.utf8))),
            ]
        }()
        for (name, reply) in cases {
            let rig = try await SummaryRig.make(review: false)
            await rig.harness.server.scriptSummary(reply)
            rig.shell.openAllWork()
            await rig.store.refresh()
            #expect(await quiet(rig) == 0, "\(name)")
        }
    }

    // MARK: P2-M2 — 타입이 틀리거나 모르는 변화 필드는 지우지 않는다 (진짜 APIClient · 디코더 · 셸 경로)

    /// 해석 못 한 변화: 줄은 남고 `Some changes couldn't be shown`, Clear는 받지 않고, 첫 정상 표시 확정도 나가지 않는다
    @Test func illTypedOrUnknownChangeFieldsAreKeptButNeverClearedNorConfirmed() async throws {
        let blocked: [(String, String)] = [
            ("run done · detail number", SummaryJSON.rawChange("run", "done", detail: "42")),
            ("run done · detail object", SummaryJSON.rawChange("run", "done", detail: "{\"outcome\":\"draft_ready\"}")),
            ("run failed · detail unknown outcome", SummaryJSON.rawChange("run", "failed", detail: "\"future_outcome\"")),
            ("run done · source_state future_state", SummaryJSON.rawChange("run", "done", detail: "\"draft_ready\"", sourceState: "\"future_state\"")),
            ("message · source_state future_state", SummaryJSON.rawChange("message", "assistant", sourceState: "\"future_state\"")),
            ("action_event · detail future_detail", SummaryJSON.rawChange("action_event", "due_changed", detail: "\"future_detail\"", sourceState: "\"available\"")),
        ]
        for (name, raw) in blocked {
            let cleared = try await SummaryRig.make(review: false)
            await cleared.harness.server.scriptSummary(SummaryJSON.response([SummaryJSON.item(cleared.id(101), title: "Open 1", changes: [raw])]))
            cleared.shell.openAllWork()
            await cleared.store.refresh()
            let content = cleared.shell.summaryContent
            #expect(content?.rows.count == 1 && content?.notes.contains(.couldNotShow) == true && content?.canClear == false, "\(name)")
            #expect(content?.rows.first?.detail == nil, "\(name): 정상 문구로 바뀌지 않는다")
            #expect(cleared.shell.clearSummary() == nil, "\(name): Clear 받지 않음")
            #expect(await cleared.harness.server.clearCursors().isEmpty, "\(name): Clear 쓰기 0")

            let first = try await SummaryRig.make(review: false)
            await first.harness.server.scriptSummary(firstUse(first, changeJSON: raw))
            first.shell.openAllWork()
            await first.store.refresh()
            #expect(await quiet(first) == 0, "\(name): 확정 쓰기 0")
        }
    }

    /// 통제군: 정말 없는 값(null) · 정상 메시지는 안전한 변화다 — Clear도 확정도 막히지 않는다
    @Test func safeChangesStillClearAndConfirmThroughTheRealShell() async throws {
        let safe: [(String, String, String)] = [
            ("run done · detail null", SummaryJSON.rawChange("run", "done"), "Processing finished"),
            ("message assistant", SummaryJSON.rawChange("message", "assistant"), "New reply"),
            ("run failed · known outcome", SummaryJSON.rawChange("run", "failed", detail: "\"draft_ready\""), "Couldn't finish the draft"),
        ]
        for (name, raw, phrase) in safe {
            let cleared = try await SummaryRig.make(review: false)
            await cleared.harness.server.scriptSummary(SummaryJSON.response([SummaryJSON.item(cleared.id(101), title: "Open 1", changes: [raw])]))
            cleared.shell.openAllWork()
            await cleared.store.refresh()
            #expect(cleared.shell.summaryContent?.rows.first?.detail == phrase && cleared.shell.summaryContent?.canClear == true, "\(name)")
            let task = try #require(cleared.shell.clearSummary(), "\(name): Clear 받음")
            #expect(await task.value == .cleared(applied: true), "\(name)")
            #expect(await cleared.harness.server.clearCursors() == [SummaryJSON.cursor], "\(name)")

            let first = try await SummaryRig.make(review: false)
            await first.harness.server.scriptSummary(firstUse(first, changeJSON: raw), initialized(first))
            first.shell.openAllWork()
            await first.store.refresh()
            #expect(await settled(first, posts: 1), "\(name): 확정 나감")
        }
    }

    // MARK: 표시 시점 · 방문

    /// 패널이 닫혀 있는 동안 반영된 응답은 보이지 않았다: 확정을 받지 않는다. All work로 들어오는 그때가 표시 시점이다
    @Test func aResponseThatAppliedWhileThePanelWasClosedConfirmsOnlyWhenItIsFirstShown() async throws {
        let rig = try await SummaryRig.make(review: false)
        await rig.harness.server.scriptSummary(firstUse(rig), initialized(rig))
        await rig.store.refresh()
        #expect(await quiet(rig) == 0, "패널이 닫혀 있다")
        rig.shell.openAllWork()
        #expect(await settled(rig, posts: 1))
    }

    @Test func aResponseThatAppliedOnChatsConfirmsOnlyWhenAllWorkIsShown() async throws {
        let rig = try await SummaryRig.make(review: false)
        await rig.harness.server.scriptSummary(firstUse(rig), initialized(rig))
        rig.shell.openChats()
        await rig.store.refresh()
        #expect(await quiet(rig) == 0, "Chats가 보이는 중이다")
        rig.shell.openAllWork()
        #expect(await settled(rig, posts: 1))
    }

    /// 표시 시점에 받아 예약된 확정이 보내기 전에 패널이 닫히면 쓰기 0 — 다시 열어도 같은 응답으로 다시 받지 않는다
    @Test func aConfirmQueuedBeforeThePanelClosesSendsNothing() async throws {
        let rig = try await SummaryRig.make(review: false)
        await rig.harness.server.scriptSummary(firstUse(rig), initialized(rig))
        rig.shell.openAllWork()
        await rig.store.refresh()
        rig.shell.dismiss()
        #expect(await quiet(rig) == 0 && !rig.store.isConfirmingBaseline)
        rig.shell.openAllWork()
        #expect(await quiet(rig) == 0, "같은 응답은 한 번만 받는다")
    }

    /// P2-M1과 같은 경계: 받은 직후 await 없이 닫았다 다시 열거나 Chats에 갔다 돌아와도 앞 방문에서 받은 확정은 새 방문에서 나가지 않는다
    @Test func aConfirmQueuedInOneVisitIsNotSentInTheNextVisit() async throws {
        let reopen = try await SummaryRig.make(review: false)
        await reopen.harness.server.scriptSummary(firstUse(reopen), initialized(reopen))
        reopen.shell.openAllWork()
        await reopen.store.refresh()
        reopen.shell.dismiss()
        reopen.shell.openAllWork()
        #expect(await quiet(reopen) == 0, "닫았다 다시 연 새 방문")

        let chats = try await SummaryRig.make(review: false)
        await chats.harness.server.scriptSummary(firstUse(chats), initialized(chats))
        chats.shell.openAllWork()
        await chats.store.refresh()
        chats.shell.openChats()
        chats.shell.openAllWork()
        #expect(await quiet(chats) == 0, "Chats에 갔다 돌아온 새 방문")
    }

    /// 대조: 같은 방문 안의 움직임(⌘2를 한 번 더 · 줄 열기)은 방문을 바꾸지 않는다 → 정확히 한 번 나간다
    @Test func ordinaryMovesInTheSameVisitStillSendExactlyOnce() async throws {
        let rig = try await SummaryRig.make(review: false)
        await rig.harness.server.scriptSummary(firstUse(rig), initialized(rig))
        rig.shell.openAllWork()
        await rig.store.refresh()
        rig.shell.open(itemID: rig.id(101))
        rig.shell.openAllWork()
        #expect(await settled(rig, posts: 1))
        #expect(await rig.harness.server.baselineTokens() == [Self.token])
    }

    // MARK: 같은 UUID 재로그인 · 늦은 쓰기 · 옛 defer

    @Test func aConfirmQueuedBeforeAReloginSendsNothingUnderTheNewSession() async throws {
        let rig = try await SummaryRig.make(review: false)
        await rig.harness.server.scriptSummary(firstUse(rig), initialized(rig))
        rig.shell.openAllWork()
        await rig.store.refresh()
        rig.harness.reloginSameUser()
        #expect(await quiet(rig) == 0 && rig.store.summary == nil)
    }

    /// 이미 서버로 나간 확정은 화면이 닫혀도 취소하지 않는다: 정직한 결과(성공)를 받고 다시 조회한다
    @Test func aRequestAlreadySentReportsItsHonestResultEvenIfThePanelCloses() async throws {
        let rig = try await SummaryRig.make(review: false)
        await rig.harness.server.scriptSummary(firstUse(rig), initialized(rig))
        await rig.harness.server.holdBaselineRequests()
        rig.shell.openAllWork()
        await rig.store.refresh()
        #expect(await rig.harness.wait { await rig.harness.server.pendingBaselines() == 1 })
        rig.shell.dismiss()
        await rig.harness.server.releaseBaselines()
        #expect(await rig.harness.wait { rig.store.summary?.baseline == .initialized && !rig.store.isConfirmingBaseline })
        #expect(await rig.harness.server.summaryReadCount() == 2, "나간 요청을 조용히 버리지 않고 결과를 조회로 확인했다")
        #expect(await rig.harness.server.baselineTokens() == [Self.token])
    }

    @Test func aLateSuccessAfterAReloginIsDroppedAndTheOldDeferNeverReleasesTheNewBusy() async throws {
        let rig = try await SummaryRig.make(review: false)
        await rig.harness.server.scriptSummary(firstUse(rig, token: "i1.OLD"), firstUse(rig, token: "i1.NEW"), initialized(rig))
        await rig.harness.server.holdBaselineRequests()
        rig.shell.openAllWork()
        await rig.store.refresh()
        #expect(await rig.harness.wait { await rig.harness.server.pendingBaselines() == 1 })
        // 같은 UUID로 다시 로그인: 새 세션이 같은 패널에서 새 읽기를 하고 자기 확정을 받는다
        rig.harness.reloginSameUser()
        await rig.store.refresh()
        #expect(await rig.harness.wait { await rig.harness.server.pendingBaselines() == 2 })
        let readsBefore = await rig.harness.server.summaryReadCount()
        // 옛 요청만 먼저 돌려준다: 새 세션의 진행 표시를 풀지 못하고 새 세션의 읽기를 일으키지도 않는다
        await rig.harness.server.releaseBaselines(1)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(rig.store.isConfirmingBaseline, "옛 요청의 정리가 새 요청의 진행 표시를 지우지 않는다")
        #expect(await rig.harness.server.summaryReadCount() == readsBefore, "옛 세션의 응답이 새 읽기를 일으키지 않는다")
        await rig.harness.server.releaseBaselines()
        #expect(await rig.harness.wait { !rig.store.isConfirmingBaseline && rig.store.summary?.baseline == .initialized })
        #expect(await rig.harness.server.baselineTokens() == ["i1.OLD", "i1.NEW"])
    }

    // MARK: 409 · 응답 유실 — 자동 재전송 없이 다음 정상 표시의 새 토큰으로

    @Test func aConflictIsNeverResentAndTheNextNormalDisplayUsesANewToken() async throws {
        let rig = try await SummaryRig.make(review: false)
        await rig.harness.server.scriptSummary(firstUse(rig, token: "i1.FIRST"), firstUse(rig, token: "i1.SECOND"), initialized(rig))
        await rig.harness.server.scriptBaseline(.http(409, Data("{\"error\":{\"code\":\"conflict\",\"message\":\"기준점 범위가 달라졌습니다.\"}}".utf8)))
        rig.shell.openAllWork()
        await rig.store.refresh()
        #expect(await settled(rig, posts: 1))
        #expect(await quiet(rig) == 1, "자동 재전송 없음")
        #expect(await rig.harness.server.summaryReadCount() == 1, "충돌 뒤 바로 다시 조회하지도 않는다")
        await rig.harness.server.scriptBaseline()
        // 다음 정상 표시: 새 방문이 새 조회로 새 토큰을 받는다
        await rig.store.refresh()
        #expect(await settled(rig, posts: 2))
        #expect(await rig.harness.server.baselineTokens() == ["i1.FIRST", "i1.SECOND"])
    }

    @Test func aLostResponseIsNeverResent() async throws {
        let rig = try await SummaryRig.make(review: false)
        await rig.harness.server.scriptSummary(firstUse(rig), initialized(rig))
        await rig.harness.server.scriptBaseline(.fail(.networkConnectionLost))
        rig.shell.openAllWork()
        await rig.store.refresh()
        #expect(await settled(rig, posts: 1))
        #expect(await quiet(rig) == 1)
        #expect(rig.store.summary?.baseline == .neverCleared, "성공을 주장하지 않는다: 보이는 응답 그대로")
    }
}
