import Foundation
import Testing
@testable import TaskforceKit

/// C — 첫 정상 표시 기준점 확정 (A–D 후속 계약 `handoffs/c3-ad-contract.md` C, 서버 레인이 구현 중이라 가짜 게이트웨이로 시험한다).
/// 정상 표시(디코드 성공 · 변화 원천 ok|truncated · 해석 못 한 변화 없음 · 같은 계정 · 지금 보이는 응답)가 된 **그때** 동기 경계에서 token · 토큰 · 소유 번호를 잡고(`beginBaseline`),
/// 보내기 직전과 모든 await 뒤에 다시 본다 (`sendBaseline`, Clear · P2-M1과 같은 방식). 읽기 실패 · 오래됨 · 겹친 읽기 · 같은 UUID 재로그인 · 화면 소유 상실이면 쓰기 0이고,
/// 409 · 400 · 응답 유실은 자동 재전송 없이 **다음 정상 표시의 새 토큰**으로 한다. 성공 뒤에는 다시 조회한다. 확정은 읽음 표시일 뿐 결정 · 완료가 아니다
@MainActor
struct ReturnSummaryBaselineTests {
    typealias Fx = ReturnSummaryFx
    let token = ReturnSummaryContractFixtures.initToken
    let cursor = ReturnSummaryContractFixtures.cursor

    /// 첫 사용 응답: 한 번도 Clear하지 않았고 기준점도 없다 (since 없음, 서버가 init_token을 준다)
    func firstUse(_ items: [ReturnSummaryItem]? = nil, token: String? = nil, changes: ReturnSummarySourceStatus = .ok, decisions: ReturnSummarySourceStatus = .ok) -> ReturnSummaryResponse {
        bsFirstUse(items, token: token ?? self.token, changes: changes, decisions: decisions)
    }

    func make(_ account: ChatTestAccount? = nil, first: ReturnSummaryResponse? = nil) throws -> (store: ReturnSummaryStore, gateway: FakeReturnSummaryGateway, account: ChatTestAccount) {
        let account = try account ?? ChatTestAccount.make()
        let gateway = FakeReturnSummaryGateway()
        gateway.retained = account
        let response = first ?? firstUse()
        gateway.onRead = { _ in response }
        return (ReturnSummaryStore(gateway: gateway, scope: account.scope), gateway, account)
    }

    /// 이미 기준점이 생긴 뒤의 응답 (토큰 없음)
    var initialized: ReturnSummaryResponse { bsInitialized() }

    // MARK: 정상 표시 → 확정 한 번 → 다시 조회

    @Test func aNormalFirstDisplayConfirmsOnceWithTheTokenVerbatimThenReadsAgain() async throws {
        let (store, gateway, _) = try make()
        await store.refresh()
        gateway.onRead = { _ in bsInitialized() }
        let ticket = try #require(store.beginBaseline())
        #expect(store.isConfirmingBaseline)
        let result = await store.sendBaseline(ticket, isStillValid: { true })
        #expect(result == .initialized)
        #expect(gateway.baselines == [token], "서버가 준 토큰이 그대로 간다")
        #expect(gateway.reads == 2, "성공은 조회로 확인한다")
        #expect(store.summary?.baseline == .initialized && store.summary?.initToken == nil && !store.isConfirmingBaseline)
        #expect(store.beginBaseline() == nil, "기준점이 생겼으니 다시 확정하지 않는다")
        // 확정은 읽음 표시일 뿐이다: Clear도 결정도 보내지 않았다
        #expect(gateway.clears.isEmpty)
        #expect(store.content()?.title == "Changes" && store.content()?.canClear == true)
    }

    @Test func alreadyInitializedIsASuccessToo() async throws {
        let (store, gateway, _) = try make()
        await store.refresh()
        gateway.onBaseline = { _ in ReturnSummaryBaselineResponse(status: .alreadyInitialized, applied: false) }
        gateway.onRead = { _ in bsInitialized() }
        let result = await store.sendBaseline(try #require(store.beginBaseline()), isStillValid: { true })
        #expect(result == .alreadyInitialized && gateway.reads == 2 && store.summary?.baseline == .initialized)
    }

    @Test func anUnknownConfirmStatusIsNotClaimedAsSuccessButTheServerTruthIsRead() async throws {
        let (store, gateway, _) = try make()
        await store.refresh()
        gateway.onBaseline = { _ in ReturnSummaryBaselineResponse(status: .unknown, applied: true) }
        let result = await store.sendBaseline(try #require(store.beginBaseline()), isStillValid: { true })
        #expect(result == .unconfirmed && gateway.reads == 2)
    }

    @Test func anEmptyFirstScreenConfirmsToo() async throws {
        let (store, gateway, _) = try make(first: firstUse([]))
        await store.refresh()
        #expect(store.summary?.isEmpty == true && store.content() == nil)
        let result = await store.sendBaseline(try #require(store.beginBaseline()), isStillValid: { true })
        #expect(result == .initialized && gateway.baselines == [token])
    }

    @Test func aTruncatedNormalPageAndADecisionProblemStillConfirm() async throws {
        let (store, _, _) = try make(first: firstUse(changes: .truncated))
        await store.refresh()
        #expect(store.beginBaseline() != nil)
        let (second, _, _) = try make(first: firstUse(decisions: .unavailable))
        await second.refresh()
        #expect(second.beginBaseline() != nil, "결정 읽기 실패는 정상 표시를 막지 않는다")
    }

    // MARK: 정상 표시가 아니면 쓰기 0

    @Test func noTokenOrNoNeverClearedMeansNothingToConfirm() async throws {
        for response in [
            Fx.response([Fx.item(1, changes: [Fx.change()])], since: nil, baseline: .neverCleared, initToken: nil),
            Fx.response([Fx.item(1, changes: [Fx.change()])], baseline: .cleared, initToken: token),
            Fx.response([Fx.item(1, changes: [Fx.change()])], since: nil, baseline: .initialized, initToken: token),
        ] {
            let (store, gateway, _) = try make(first: response)
            await store.refresh()
            #expect(store.beginBaseline() == nil && gateway.baselines.isEmpty, "\(response.baseline)")
        }
    }

    @Test func anAbnormalDisplayNeverConfirms() async throws {
        let uninterpretable = firstUse([Fx.item(1, changes: [Fx.change(.run, "done", detail: "mystery")])])
        let (a, ga, _) = try make(first: uninterpretable)
        await a.refresh()
        #expect(a.beginBaseline() == nil && ga.baselines.isEmpty, "해석 못 한 변화가 보이는 응답")
        let (b, gb, _) = try make(first: firstUse(changes: .unavailable))
        await b.refresh()
        #expect(b.beginBaseline() == nil && gb.baselines.isEmpty, "변화 원천을 읽지 못함")
        let (c, gc, _) = try make(first: firstUse(changes: .unknown))
        await c.refresh()
        #expect(c.beginBaseline() == nil && gc.baselines.isEmpty, "변화 원천을 모름")
        // 읽기 실패 · 기능 꺼짐: 응답이 없다
        let failing = try make()
        failing.gateway.onRead = { _ in throw APIError.transport("down") }
        await failing.store.refresh()
        #expect(failing.store.beginBaseline() == nil && failing.gateway.baselines.isEmpty)
        let off = try make()
        off.gateway.onRead = { _ in throw APIError.server(status: 404, code: .notFound, message: APIError.featureOffMessage) }
        await off.store.refresh()
        #expect(off.store.beginBaseline() == nil)
    }

    /// 받은 뒤 다시 읽지 못했다: 지금 보이는 것이 그 응답이라고 말할 수 없다 → 쓰기 0
    @Test func aStaleDisplayNeverConfirms() async throws {
        let (store, gateway, _) = try make()
        await store.refresh()
        let ticket = try #require(store.beginBaseline())
        gateway.onRead = { _ in throw APIError.transport("down") }
        await store.refresh()
        #expect(store.isStale)
        #expect(await store.sendBaseline(ticket, isStillValid: { true }) == .ignored && gateway.baselines.isEmpty)
        #expect(store.beginBaseline() == nil)
    }

    /// 한 응답에 시도는 한 번이다 (받으면 소비한다): 보내지 못했어도 같은 응답으로 다시 받지 않는다 — 다음 정상 표시(새 조회)에서만
    @Test func eachDisplayedResponseGetsOneAttempt() async throws {
        let (store, gateway, _) = try make()
        await store.refresh()
        let ticket = try #require(store.beginBaseline())
        #expect(store.beginBaseline() == nil, "이미 확정을 받았다")
        _ = await store.sendBaseline(ticket, isStillValid: { false })
        #expect(gateway.baselines.isEmpty && !store.isConfirmingBaseline)
        #expect(store.beginBaseline() == nil, "보내지 못했어도 같은 응답으로 다시 받지 않는다")
        await store.refresh()
        #expect(store.beginBaseline() != nil, "새 조회의 새 응답은 다시 정상 표시다")
    }

    // MARK: 화면 · 겹친 읽기 · 같은 UUID 재로그인

    @Test func ifTheScreenNoLongerOwnsTheDisplayNothingIsSent() async throws {
        let (store, gateway, _) = try make()
        await store.refresh()
        let ticket = try #require(store.beginBaseline())
        #expect(await store.sendBaseline(ticket, isStillValid: { false }) == .ignored)
        #expect(gateway.baselines.isEmpty && gateway.reads == 1 && !store.isConfirmingBaseline)
    }

    /// 겹친 읽기: 받은 뒤 더 새 응답이 반영됐다 → 옛 토큰은 새 토큰으로 바뀌었다. 옛 토큰으로 보내지 않는다
    @Test func aNewerResponseBetweenBeginAndSendDropsTheOldToken() async throws {
        let (store, gateway, _) = try make()
        await store.refresh()
        let ticket = try #require(store.beginBaseline())
        let newer = bsFirstUse(token: "i1.NEWER-TOKEN")
        gateway.onRead = { _ in newer }
        await store.refresh()
        #expect(await store.sendBaseline(ticket, isStillValid: { true }) == .ignored)
        #expect(gateway.baselines.isEmpty, "옛 토큰은 나가지 않았다")
        let fresh = try #require(store.beginBaseline())
        #expect(await store.sendBaseline(fresh, isStillValid: { true }) == .initialized)
        #expect(gateway.baselines == ["i1.NEWER-TOKEN"])
    }

    /// 겹쳐 시작한 두 읽기: 늦게 끝난 옛 읽기는 반영되지 않으므로 그 토큰은 후보도 되지 않는다
    @Test func aLateOlderReadNeverBecomesTheDisplayedTokenForConfirm() async throws {
        let (store, gateway, _) = try make()
        let held = Latch()
        let older = firstUse(token: "i1.OLDER")
        let newer = firstUse(token: "i1.NEWER")
        gateway.onRead = { number in
            if number == 1 {
                await held.wait()
                return older
            }
            return newer
        }
        let first = Task { await store.refresh() }
        await waitForArrival(held)
        await store.refresh()
        await held.open()
        await first.value
        let ticket = try #require(store.beginBaseline())
        #expect(await store.sendBaseline(ticket, isStillValid: { true }) == .initialized)
        #expect(gateway.baselines == ["i1.NEWER"])
    }

    @Test func reloggingInBeforeTheSendWritesNothingUnderTheNewSession() async throws {
        let (store, gateway, account) = try make()
        await store.refresh()
        let ticket = try #require(store.beginBaseline())
        account.relogin()
        #expect(await store.sendBaseline(ticket, isStillValid: { true }) == .ignored)
        #expect(gateway.baselines.isEmpty && !store.isConfirmingBaseline)
        // 새 세션이 같은 응답(같은 토큰)을 다시 읽었어도 옛 세션의 선택은 나가지 않는다
        await store.refresh()
        #expect(await store.sendBaseline(ticket, isStillValid: { true }) == .ignored && gateway.baselines.isEmpty)
        #expect(store.beginBaseline() != nil, "새 세션은 자기 선택을 따로 받는다")
    }

    @Test func aTokenRefreshKeepsTheSameSessionsTicket() async throws {
        let (store, gateway, account) = try make()
        await store.refresh()
        let ticket = try #require(store.beginBaseline())
        let epoch = account.scope.epoch
        account.session.apply(event: .tokenRefreshed, session: account.signedIn)
        #expect(account.scope.epoch == epoch)
        #expect(await store.sendBaseline(ticket, isStillValid: { true }) == .initialized && gateway.baselines == [token])
    }

    /// Clear를 보내는 중에는 받지 않는다 (겹친 읽음 표시를 만들지 않는다)
    @Test func noBaselineWhileAClearIsInFlight() async throws {
        let (store, gateway, _) = try make(first: Fx.response([Fx.item(1, changes: [Fx.change()])], since: nil, baseline: .neverCleared, initToken: token))
        await store.refresh()
        let clearTicket = try #require(store.beginClear())
        #expect(store.beginBaseline() == nil)
        _ = await store.sendClear(clearTicket, isStillValid: { false })
        #expect(gateway.baselines.isEmpty)
    }

    // MARK: 이미 나간 요청의 정직한 결과 · 옛 defer

    /// 서버로 나간 뒤에는 화면이 바뀌어도(방문 · 패널) 취소하지 않는다: 정직한 결과를 돌려주고 다시 조회한다
    @Test func aRequestAlreadySentReportsItsHonestResultEvenIfTheScreenMovesOn() async throws {
        let (store, gateway, _) = try make()
        await store.refresh()
        let hold = Latch()
        gateway.onBaseline = { _ in
            await hold.wait()
            return ReturnSummaryBaselineResponse(status: .initialized, applied: true)
        }
        let valid = ValidityBox(true)
        let ticket = try #require(store.beginBaseline())
        let sending = Task { await store.sendBaseline(ticket, isStillValid: { valid.value }) }
        await waitForArrival(hold)
        valid.value = false
        gateway.onRead = { _ in bsInitialized() }
        await hold.open()
        #expect(await sending.value == .initialized, "나간 요청을 조용히 버리지 않는다")
        #expect(gateway.reads == 2 && store.summary?.baseline == .initialized)
    }

    @Test func aLateSuccessAfterTheAccountLeftIsDropped() async throws {
        let (store, gateway, account) = try make()
        await store.refresh()
        let hold = Latch()
        gateway.onBaseline = { _ in
            await hold.wait()
            return ReturnSummaryBaselineResponse(status: .initialized, applied: true)
        }
        let ticket = try #require(store.beginBaseline())
        let sending = Task { await store.sendBaseline(ticket, isStillValid: { true }) }
        await waitForArrival(hold)
        let reads = gateway.reads
        account.relogin()
        await hold.open()
        #expect(await sending.value == .ignored)
        #expect(gateway.reads == reads, "옛 세션의 성공이 새 세션의 읽기를 일으키지 않는다")
        #expect(store.summary == nil && !store.isConfirmingBaseline)
    }

    /// 옛 요청이 늦게 끝나도 새 세션이 잡은 진행 표시를 풀지 못한다
    @Test func anOldConfirmFinishingLateDoesNotReleaseTheNewSessionsBusy() async throws {
        let (store, gateway, account) = try make()
        await store.refresh()
        let old = Latch()
        let fresh = Latch()
        let oldToken = token
        gateway.onBaseline = { sent in
            if sent == oldToken { await old.wait() } else { await fresh.wait() }
            return ReturnSummaryBaselineResponse(status: .initialized, applied: true)
        }
        let oldTicket = try #require(store.beginBaseline())
        let oldSend = Task { await store.sendBaseline(oldTicket, isStillValid: { true }) }
        await waitForArrival(old)
        account.relogin()
        let newSessionToken = "i1.NEW-SESSION"
        gateway.onRead = { _ in bsFirstUse(token: newSessionToken) }
        await store.refresh()
        let newTicket = try #require(store.beginBaseline())
        let newSend = Task { await store.sendBaseline(newTicket, isStillValid: { true }) }
        await waitForArrival(fresh)
        #expect(store.isConfirmingBaseline)
        await old.open()
        _ = await oldSend.value
        #expect(store.isConfirmingBaseline, "옛 요청의 정리가 새 요청의 진행 표시를 지우지 않는다")
        #expect(store.beginBaseline() == nil)
        gateway.onRead = { _ in bsInitialized() }
        await fresh.open()
        #expect(await newSend.value == .initialized && !store.isConfirmingBaseline)
    }

    // MARK: 409 · 400 · 응답 유실 · 거절 — 자동 재전송 없이 다음 정상 표시의 새 토큰으로

    @Test func aConflictIsNeverResentAndTheNextNormalDisplayUsesANewToken() async throws {
        let (store, gateway, _) = try make()
        await store.refresh()
        gateway.onBaseline = { _ in throw APIError.server(status: 409, code: .conflict, message: "범위가 달라졌습니다.") }
        let result = await store.sendBaseline(try #require(store.beginBaseline()), isStillValid: { true })
        #expect(result == .conflict)
        #expect(gateway.baselines == [token], "자동 재전송 없음")
        #expect(gateway.reads == 1, "충돌 뒤 바로 다시 조회하지도 않는다 (다음 정상 표시에서)")
        #expect(!store.isConfirmingBaseline && store.beginBaseline() == nil, "같은 응답 · 같은 토큰으로 다시 받지 않는다")
        // 다음 정상 표시: 새 조회가 새 토큰을 준다 → 다시 확정할 수 있다
        gateway.onRead = { _ in bsFirstUse(token: "i1.SECOND") }
        gateway.onBaseline = { _ in ReturnSummaryBaselineResponse(status: .initialized, applied: true) }
        await store.refresh()
        let again = await store.sendBaseline(try #require(store.beginBaseline()), isStillValid: { true })
        #expect(again == .initialized && gateway.baselines == [token, "i1.SECOND"])
    }

    @Test func aLostResponseIsNotASuccessAndIsNeverResent() async throws {
        for failure: Error in [APIError.transport("lost"), APIError.decoding("garbled"), APIError.server(status: 500, code: .internalError, message: "x")] {
            let (store, gateway, _) = try make()
            await store.refresh()
            gateway.onBaseline = { _ in throw failure }
            #expect(await store.sendBaseline(try #require(store.beginBaseline()), isStillValid: { true }) == .unconfirmed)
            #expect(gateway.baselines.count == 1 && gateway.reads == 1)
            #expect(store.beginBaseline() == nil)
        }
    }

    @Test func aBadTokenARejectionAndAGateOffAreHonest() async throws {
        let (a, ga, _) = try make()
        await a.refresh()
        ga.onBaseline = { _ in throw APIError.server(status: 400, code: .invalidRequest, message: "토큰") }
        #expect(await a.sendBaseline(try #require(a.beginBaseline()), isStillValid: { true }) == .invalid)
        #expect(ga.baselines.count == 1 && ga.reads == 1)

        let (b, gb, _) = try make()
        await b.refresh()
        gb.onBaseline = { _ in throw APIError.server(status: 429, code: .rateLimited, message: "") }
        #expect(await b.sendBaseline(try #require(b.beginBaseline()), isStillValid: { true }) == .failed)

        let (c, gc, _) = try make()
        await c.refresh()
        gc.onBaseline = { _ in throw APIError.server(status: 404, code: .notFound, message: APIError.featureOffMessage) }
        #expect(await c.sendBaseline(try #require(c.beginBaseline()), isStillValid: { true }) == .unavailable)
        #expect(c.summary == nil && c.content() == nil, "이 서버는 아직 이 기능이 없다: 조용히 지운다")
    }

    // MARK: 표시 시점 알림

    /// 읽기가 반영될 때만 (그 응답이 보일 수 있게 된 때) 알린다: 버려진 읽기 · 실패한 읽기는 알리지 않는다
    @Test func theStoreAnnouncesADisplayOnlyWhenAReadIsApplied() async throws {
        let (store, gateway, _) = try make()
        var announced = 0
        store.onDisplayed = { announced += 1 }
        await store.refresh()
        #expect(announced == 1)
        gateway.onRead = { _ in throw APIError.transport("down") }
        await store.refresh()
        #expect(announced == 1, "실패한 읽기는 표시가 아니다")
        gateway.onRead = { _ in throw CancellationError() }
        await store.refresh()
        #expect(announced == 1)
        // 겹친 읽기: 늦게 끝난 옛 읽기는 반영되지 않으므로 알리지 않는다
        let held = Latch()
        gateway.onRead = { number in
            if number == 4 {
                await held.wait()
            }
            return bsFirstUse(token: "i1.\(number)")
        }
        let older = Task { await store.refresh() }
        await waitForArrival(held)
        await store.refresh()
        #expect(announced == 2)
        await held.open()
        await older.value
        #expect(announced == 2)
    }
}

/// 첫 사용 응답 (닫힌 closure 안에서도 부르는 순수 함수)
func bsFirstUse(
    _ items: [ReturnSummaryItem]? = nil, token: String = ReturnSummaryContractFixtures.initToken, changes: ReturnSummarySourceStatus = .ok,
    decisions: ReturnSummarySourceStatus = .ok
) -> ReturnSummaryResponse {
    let rows = items ?? [ReturnSummaryFx.item(1, changes: [ReturnSummaryFx.change()])]
    return ReturnSummaryFx.response(
        rows, since: nil, baseline: .neverCleared, initToken: token, complete: changes == .ok && decisions == .ok, changes: changes, decisions: decisions
    )
}

/// 기준점이 생긴 뒤의 응답 (토큰 없음)
func bsInitialized() -> ReturnSummaryResponse {
    ReturnSummaryFx.response([ReturnSummaryFx.item(1, changes: [ReturnSummaryFx.change()])], since: nil, baseline: .initialized)
}

/// 시험이 중간에 값을 바꾸는 상자 (보내기 직전 확인이 읽는 값)
final class ValidityBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
