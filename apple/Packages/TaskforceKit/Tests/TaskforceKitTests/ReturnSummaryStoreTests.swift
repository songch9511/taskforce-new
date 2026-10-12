import Foundation
import Testing
@testable import TaskforceKit

/// 복귀 요약 저장소 (C3): 읽기 · Clear · 계정 경계. 서버 계약 규칙을 가짜 게이트웨이로 정확히 다룬다.
/// - 읽기: 마지막에 시작한 읽기만 반영 / 기능 꺼짐(404)은 줄을 지우고 아무 말도 하지 않음 / 읽지 못하면 오래된 줄 + Clear 숨김
/// - Clear: 받는 동기 경계에서 계정 · 커서 · 소유 번호를 잡고 보내기 직전에 다시 봄 / 409 · 400 · 응답 유실은 자동 재전송 없이 다시 조회
///   / 성공은 서버 200뿐 / Clear는 읽음일 뿐이라 결정 줄은 남는다
/// - 계정: 같은 UUID 재로그인 · 다른 계정 · 토큰 갱신 · 늦은 읽기 / 늦은 Clear · 옛 정리가 새 진행 표시를 풀지 않음
@MainActor
struct ReturnSummaryStoreTests {
    typealias Fx = ReturnSummaryFx
    let cursor = ReturnSummaryContractFixtures.cursor
    nonisolated static let gateOff = APIError.server(status: 404, code: .notFound, message: APIError.featureOffMessage)

    func make(_ account: ChatTestAccount? = nil) throws -> (store: ReturnSummaryStore, gateway: FakeReturnSummaryGateway, account: ChatTestAccount) {
        let account = try account ?? ChatTestAccount.make()
        let gateway = FakeReturnSummaryGateway()
        gateway.retained = account
        return (ReturnSummaryStore(gateway: gateway, scope: account.scope), gateway, account)
    }

    /// 읽고 → Clear를 받아 보낸다 (화면이 그대로 유효하다고 본다)
    @discardableResult
    func clear(_ store: ReturnSummaryStore, valid: @escaping () -> Bool = { true }) async throws -> ReturnSummaryClearResult {
        let ticket = try #require(store.beginClear())
        return await store.sendClear(ticket, isStillValid: valid)
    }

    // MARK: 읽기

    @Test func aReadShowsWhatTheServerSaidAndWritesNothing() async throws {
        let (store, gateway, _) = try make()
        await store.refresh()
        #expect(store.summary == Fx.withChanges && !store.isStale && !store.readFailed && !store.featureOff)
        #expect(store.content()?.rows.count == 2 && store.content()?.canClear == true)
        #expect(gateway.reads == 1 && gateway.clears.isEmpty, "읽기는 아무것도 읽음 처리하지 않는다")
    }

    /// 404(gate 꺼짐): 이 서버는 아직 이 기능이 없다. 줄을 지우고 아무 말도 하지 않는다 (오류 · Notice 없음)
    @Test func aGateOffServerShowsNothingAndNoError() async throws {
        let (store, gateway, _) = try make()
        gateway.onRead = { _ in throw Self.gateOff }
        await store.refresh()
        #expect(store.summary == nil && store.featureOff && !store.readFailed && !store.isStale)
        #expect(store.content() == nil && store.message == nil)
    }

    @Test func turningTheGateOffDropsTheRowsInsteadOfKeepingOldText() async throws {
        let (store, gateway, _) = try make()
        await store.refresh()
        #expect(store.content() != nil)
        gateway.onRead = { _ in throw Self.gateOff }
        await store.refresh()
        #expect(store.summary == nil && store.content() == nil && !store.isStale)
    }

    @Test func aFailedFirstReadSaysCouldNotLoadAndRetryWorks() async throws {
        let (store, gateway, _) = try make()
        gateway.onRead = { _ in throw APIError.transport("offline") }
        await store.refresh()
        #expect(store.summary == nil && store.readFailed && !store.featureOff)
        #expect(store.content()?.notes == [.couldNotLoad] && store.content()?.rows.isEmpty == true)
        gateway.onRead = { _ in Fx.withChanges }
        await store.refresh()
        #expect(!store.readFailed && store.content()?.rows.count == 2 && store.content()?.notes == [])
    }

    @Test func aFailedReadAfterASuccessKeepsRowsButHidesClearAndSaysStale() async throws {
        let (store, gateway, _) = try make()
        await store.refresh()
        gateway.onRead = { _ in throw Failure() }
        await store.refresh()
        #expect(store.isStale && !store.readFailed)
        let shown = store.content()
        #expect(shown?.rows.count == 2 && shown?.canClear == false && shown?.notes == [.couldNotLoad])
        #expect(store.beginClear() == nil, "다시 읽지 못한 줄의 커서로 Clear를 받지 않는다")
        gateway.onRead = { _ in Fx.withChanges }
        await store.refresh()
        #expect(!store.isStale && store.content()?.canClear == true)
    }

    struct Failure: Error {}

    /// 마지막에 시작한 읽기만 반영한다: 늦게 끝난 옛 읽기가 새 상태를 되돌리지 못한다
    @Test func aLateOlderReadNeverOverwritesANewerOne() async throws {
        let (store, gateway, _) = try make()
        let old = Latch()
        let older = Fx.response([Fx.item(1, title: "OLD", changes: [Fx.change()])])
        let newer = Fx.response([Fx.item(2, title: "NEW", changes: [Fx.change()])])
        gateway.onRead = { number in
            if number == 1 {
                await old.wait()
                return older
            }
            return newer
        }
        let first = Task { await store.refresh() }
        await waitForArrival(old)
        await store.refresh()
        #expect(store.summary == newer)
        await old.open()
        await first.value
        #expect(store.summary == newer && store.content()?.rows.map(\.title) == ["NEW"])
    }

    @Test func aLateOlderFailureNeverMarksANewerSuccessStale() async throws {
        let (store, gateway, _) = try make()
        let old = Latch()
        gateway.onRead = { number in
            if number == 1 {
                await old.wait()
                throw Failure()
            }
            return Fx.withChanges
        }
        let first = Task { await store.refresh() }
        await waitForArrival(old)
        await store.refresh()
        await old.open()
        await first.value
        #expect(!store.isStale && !store.readFailed && store.summary == Fx.withChanges)
    }

    @Test func aCancelledReadLeavesTheStateAlone() async throws {
        let (store, gateway, _) = try make()
        await store.refresh()
        gateway.onRead = { _ in throw CancellationError() }
        await store.refresh()
        #expect(!store.isStale && !store.readFailed && store.summary == Fx.withChanges)
    }

    @Test func aMessageFromAnEarlierClearEndsWithTheNextVisit() async throws {
        let (store, gateway, _) = try make()
        await store.refresh()
        gateway.onClear = { _ in throw APIError.server(status: 409, code: .conflict, message: "x") }
        try await clear(store)
        #expect(store.message == "This changed somewhere else. It's been refreshed.")
        await store.refresh()
        #expect(store.message == nil)
    }

    // MARK: Clear

    @Test func clearNeedsALoadedListWithACursorAndSomethingToMarkRead() async throws {
        let (store, gateway, _) = try make()
        #expect(store.beginClear() == nil, "읽기 전")
        gateway.onRead = { _ in Fx.response([Fx.item(1, changes: [Fx.change()])], cursor: nil) }
        await store.refresh()
        #expect(store.beginClear() == nil, "서버가 커서를 주지 않았다")
        gateway.onRead = { _ in Fx.response([Fx.item(1, needsAnswer: true)]) }
        await store.refresh()
        #expect(store.beginClear() == nil, "결정만 있는 줄은 읽음 처리할 것이 없다")
        #expect(gateway.clears.isEmpty)
    }

    @Test func aSuccessfulClearIsTheServers200ThenTheListIsReadAgain() async throws {
        let (store, gateway, _) = try make()
        await store.refresh()
        // Clear 뒤에도 결정이 있는 줄은 남는다 (읽음은 결정이 아니다)
        let afterClear = Fx.response([Fx.item(1, title: "Pricing page", needsAnswer: true)], cursor: "c2.after", since: 0)
        gateway.onRead = { _ in afterClear }
        let result = try await clear(store)
        #expect(result == .cleared(applied: true))
        #expect(gateway.clears == [cursor], "서버가 준 커서가 그대로 간다")
        #expect(gateway.reads == 2, "성공을 조회로 확인한다")
        #expect(store.summary == afterClear && !store.isClearing && store.message == nil)
        let shown = store.content()
        #expect(shown?.rows.map(\.title) == ["Pricing page"] && shown?.rows.first?.needsAnswer == true && shown?.canClear == false)
    }

    /// 잘린 페이지의 Clear는 보인 작업만 읽음 처리한다: 성공을 "모두 처리됨"이라 하지 않고, 다음 조회가 남은 것을 보인다
    @Test func clearingATruncatedPageThenReadingShowsTheRestNeverAllHandled() async throws {
        let (store, gateway, _) = try make()
        let first = Fx.response([Fx.item(1, title: "Shown", changes: [Fx.change()])], cursor: "c3.page1", complete: false, changes: .truncated)
        let rest = Fx.response([Fx.item(2, title: "Hidden until now", changes: [Fx.change(.run, "done", detail: "draft_ready")])], cursor: "c3.page2")
        gateway.onRead = { number in number == 1 ? first : rest }
        await store.refresh()
        #expect(store.content()?.canClear == true && store.content()?.notes == [.someNotShown])
        #expect(try await clear(store) == .cleared(applied: true))
        #expect(gateway.clears == ["c3.page1"])
        #expect(store.summary == rest && store.summary?.isEmpty == false)
        #expect(store.content()?.rows.map(\.title) == ["Hidden until now"] && store.content()?.notes == [] && store.content()?.canClear == true)
    }

    @Test func clearingEverythingLeavesNothingToShowAndNoSentenceAboutIt() async throws {
        let (store, gateway, _) = try make()
        await store.refresh()
        gateway.onRead = { _ in Fx.response([], cursor: "c2.empty") }
        #expect(try await clear(store) == .cleared(applied: true))
        #expect(store.summary?.isEmpty == true && store.content() == nil)
    }

    @Test func appliedFalseIsAlsoASuccess() async throws {
        let (store, gateway, _) = try make()
        await store.refresh()
        gateway.onClear = { _ in ReturnSummaryClearResponse(clearedThrough: .test(0), applied: false) }
        #expect(try await clear(store) == .cleared(applied: false))
        #expect(store.message == nil)
    }

    /// 409: 아무것도 읽음 처리하지 않았다. 자동으로 다시 보내지 않고 다시 조회한다 (새 변화가 보인다)
    @Test func aConflictRefreshesAndNeverResends() async throws {
        let (store, gateway, _) = try make()
        await store.refresh()
        gateway.onClear = { _ in throw APIError.server(status: 409, code: .conflict, message: "변화가 있습니다.") }
        let fresher = Fx.response([Fx.item(3, title: "Late arrival", changes: [Fx.change()])], cursor: "c2.fresh")
        gateway.onRead = { _ in fresher }
        #expect(try await clear(store) == .conflict)
        #expect(gateway.clears == [cursor], "같은 커서를 다시 보내지 않았다")
        #expect(gateway.reads == 2 && store.summary == fresher)
        #expect(store.message == "This changed somewhere else. It's been refreshed.")
        #expect(store.content()?.canClear == true, "새 커서로 사용자가 다시 누를 수 있다")
        #expect(!store.isClearing)
    }

    @Test func aBadCursorRefreshesAndNeverResends() async throws {
        let (store, gateway, _) = try make()
        await store.refresh()
        gateway.onClear = { _ in throw APIError.server(status: 400, code: .invalidRequest, message: "커서") }
        #expect(try await clear(store) == .invalid)
        #expect(gateway.clears.count == 1 && gateway.reads == 2)
        #expect(store.message == APIError.server(status: 400, code: .invalidRequest, message: "").userMessage)
    }

    @Test func aGateOffServerOnClearHidesTheSummaryWithoutAnError() async throws {
        let (store, gateway, _) = try make()
        await store.refresh()
        gateway.onClear = { _ in throw Self.gateOff }
        gateway.onRead = { _ in throw Self.gateOff }
        #expect(try await clear(store) == .unavailable)
        #expect(store.summary == nil && store.content() == nil && store.message == nil)
    }

    @Test func aRejectedClearSaysSoAndChangesNothing() async throws {
        let (store, gateway, _) = try make()
        await store.refresh()
        gateway.onClear = { _ in throw APIError.server(status: 429, code: .rateLimited, message: "") }
        #expect(try await clear(store) == .failed)
        #expect(gateway.reads == 1, "거절은 아무것도 바꾸지 않았다: 다시 읽지 않는다")
        #expect(store.message == APIError.server(status: 429, code: .rateLimited, message: "").userMessage)
        #expect(store.content()?.canClear == true, "같은 줄 · 같은 커서 그대로 (사용자가 다시 누를 수 있다)")
    }

    /// 응답을 받지 못했다: 서버가 읽음 처리했는지 모른다. 성공을 말하지 않고 자동 재전송 없이 다시 조회해 지금 상태를 보인다
    @Test func aLostResponseIsNotASuccessAndIsNeverResent() async throws {
        let (store, gateway, _) = try make()
        await store.refresh()
        gateway.onClear = { _ in throw APIError.transport("connection lost") }
        #expect(try await clear(store) == .unconfirmed)
        #expect(gateway.clears.count == 1, "자동 재전송 없음")
        #expect(gateway.reads == 2)
        // 다시 읽은 결과가 줄을 그대로 보이면 새 커서로 사용자가 다시 누를 수 있다
        #expect(store.content()?.rows.count == 2 && store.content()?.canClear == true)
    }

    @Test func aLostResponseThenAFailedRereadLeavesNoCursorToResend() async throws {
        let (store, gateway, _) = try make()
        await store.refresh()
        gateway.onClear = { _ in throw APIError.transport("connection lost") }
        gateway.onRead = { _ in throw Failure() }
        #expect(try await clear(store) == .unconfirmed)
        #expect(store.isStale && store.content()?.canClear == false && store.beginClear() == nil)
        #expect(store.content()?.notes == [.couldNotLoad])
        #expect(gateway.clears.count == 1)
    }

    @Test func aServerErrorOnClearIsAlsoUnconfirmed() async throws {
        let (store, gateway, _) = try make()
        await store.refresh()
        gateway.onClear = { _ in throw APIError.server(status: 500, code: .internalError, message: "x") }
        #expect(try await clear(store) == .unconfirmed)
        gateway.onClear = { _ in throw APIError.decoding("garbled") }
        await store.refresh()
        #expect(try await clear(store) == .unconfirmed)
    }

    /// 겹친 Clear: 보내는 중이면 받지 않는다 (반복 클릭 · 중복 → 요청 하나)
    @Test func onlyOneClearAtATime() async throws {
        let (store, gateway, _) = try make()
        await store.refresh()
        let hold = Latch()
        gateway.onClear = { _ in
            await hold.wait()
            return ReturnSummaryClearResponse(clearedThrough: .test(0), applied: true)
        }
        let ticket = try #require(store.beginClear())
        #expect(store.isClearing && store.beginClear() == nil)
        let sending = Task { await store.sendClear(ticket, isStillValid: { true }) }
        await waitForArrival(hold)
        #expect(store.isClearing && store.beginClear() == nil && store.content()?.isClearing == true)
        await hold.open()
        _ = await sending.value
        #expect(gateway.clears.count == 1 && !store.isClearing)
    }

    /// 쓴 커서는 새 조회가 실제로 반영되기 전에는 다시 받지 않는다: Clear 뒤 조회가 더 새 읽기에 밀려 버려져도 옛 줄의 옛 커서로 다시 보내지 못한다
    @Test func aSpentCursorIsNotOfferedAgainBeforeTheNewReadLands() async throws {
        let (store, gateway, _) = try make()
        await store.refresh()
        let afterClear = Latch()
        let newerVisit = Latch()
        gateway.onRead = { number in
            if number == 2 { await afterClear.wait() }
            if number == 3 { await newerVisit.wait() }
            return Fx.withChanges
        }
        let ticket = try #require(store.beginClear())
        let sending = Task { await store.sendClear(ticket, isStillValid: { true }) }
        await waitForArrival(afterClear)
        let visit = Task { await store.refresh() }
        await waitForArrival(newerVisit)
        await afterClear.open()
        #expect(await sending.value == .cleared(applied: true))
        #expect(!store.isClearing && store.beginClear() == nil, "옛 줄 · 옛 커서로 다시 보내지 않는다")
        #expect(store.content()?.canClear == false)
        await newerVisit.open()
        await visit.value
        #expect(store.beginClear() != nil, "새 조회가 반영되면 새 커서로 다시 받을 수 있다")
    }

    /// 보내기 직전 확인: 화면이 더는 그 소유가 아니면 쓰기 0 (그리고 진행 표시는 거둔다)
    @Test func ifTheScreenNoLongerOwnsTheClearNothingIsSent() async throws {
        let (store, gateway, _) = try make()
        await store.refresh()
        let ticket = try #require(store.beginClear())
        let result = await store.sendClear(ticket, isStillValid: { false })
        #expect(result == .ignored && gateway.clears.isEmpty && !store.isClearing)
        #expect(store.beginClear() != nil, "다시 받을 수 있다")
    }

    /// 받은 뒤 더 새 읽기가 줄을 바꿨다: 사용자가 본 커서가 아니다 → 옛 커서로 보내지 않는다
    @Test func aNewerReadBetweenTheClickAndTheSendDropsTheOldCursor() async throws {
        let (store, gateway, _) = try make()
        await store.refresh()
        let ticket = try #require(store.beginClear())
        gateway.onRead = { _ in Fx.response([Fx.item(9, changes: [Fx.change()])], cursor: "c2.newer") }
        await store.refresh()
        let result = await store.sendClear(ticket, isStillValid: { true })
        #expect(result == .ignored && gateway.clears.isEmpty && !store.isClearing)
        #expect(store.summary?.cursor == "c2.newer")
    }

    // MARK: 계정 경계 (B3 `MemoryStore` · S3b `WorkContextStore` · S4 `ReviewDesk` 방식)

    @Test func logoutClearsEverythingAndShowsNothing() async throws {
        let (store, _, account) = try make()
        await store.refresh()
        account.session.apply(event: .signedOut, session: nil)
        #expect(store.summary == nil && store.content() == nil && !store.isStale && !store.readFailed && !store.featureOff)
        #expect(store.beginClear() == nil)
    }

    @Test func reloggingInAsTheSameUserStartsFresh() async throws {
        let (store, gateway, account) = try make()
        await store.refresh()
        let before = gateway.reads
        account.relogin()
        #expect(store.summary == nil && store.content() == nil && store.message == nil)
        #expect(gateway.reads == before, "재로그인이 스스로 읽지는 않는다")
    }

    @Test func anotherAccountNeverSeesTheFirstAccountsSummary() async throws {
        let (store, _, account) = try make()
        await store.refresh()
        let second = ChatTestAccount.session(userID: UUID())
        try account.storage.save(second)
        account.session.apply(event: .signedIn, session: second)
        #expect(store.summary == nil && store.content() == nil)
        #expect(account.scope.token?.userID == second.user.id)
    }

    @Test func tokenRefreshKeepsTheSameSessionsData() async throws {
        let (store, _, account) = try make()
        await store.refresh()
        let epoch = account.scope.epoch
        account.session.apply(event: .tokenRefreshed, session: account.signedIn)
        account.session.apply(event: .initialSession, session: account.signedIn)
        #expect(account.scope.epoch == epoch && store.summary == Fx.withChanges && store.content()?.canClear == true)
    }

    /// 화면이 없는 사이 계정이 바뀌어도(패널이 닫혀 있어도) 저장소는 앱 시작 때 붙은 scope로 비운다
    @Test func switchingWhileTheScreenIsAbsentStillResets() async throws {
        let (store, _, account) = try make()
        await store.refresh()
        account.relogin()
        let ticket = store.beginClear()
        #expect(ticket == nil && store.summary == nil)
    }

    /// 계정이 떠난 뒤 늦게 끝난 읽기는 새 세션에 반영되지 않는다
    @Test func aReadThatOutlivesTheSessionIsDropped() async throws {
        let (store, gateway, account) = try make()
        let latch = Latch()
        gateway.onRead = { _ in
            await latch.wait()
            return Fx.withChanges
        }
        let reading = Task { await store.refresh() }
        await waitForArrival(latch)
        account.relogin()
        await latch.open()
        await reading.value
        #expect(store.summary == nil && store.content() == nil && !store.readFailed)
    }

    @Test func aFailureThatOutlivesTheSessionIsDropped() async throws {
        let (store, gateway, account) = try make()
        let latch = Latch()
        gateway.onRead = { _ in
            await latch.wait()
            throw Failure()
        }
        let reading = Task { await store.refresh() }
        await waitForArrival(latch)
        account.relogin()
        await latch.open()
        await reading.value
        #expect(!store.readFailed && !store.isStale && !store.featureOff)
    }

    /// 쓰기 Task가 예약된 뒤 시작하기 전에 같은 UUID 재로그인: 받을 때 잡은 token이 달라져 쓰기 0
    @Test func aClearTicketTakenBeforeAReloginSendsNothing() async throws {
        let (store, gateway, account) = try make()
        await store.refresh()
        let ticket = try #require(store.beginClear())
        account.relogin()
        let result = await store.sendClear(ticket, isStillValid: { true })
        #expect(result == .ignored && gateway.clears.isEmpty && !store.isClearing)
    }

    /// 새 세션이 같은 줄 · 같은 커서를 다시 읽었어도 옛 세션에서 받은 선택은 새 세션으로 나가지 않는다 (줄 · 커서가 같아 보여도 계정 token · 소유 번호가 다른 세션이다)
    @Test func anOldSessionsTicketIsNotSentEvenIfTheNewSessionReadsTheSameCursor() async throws {
        let (store, gateway, account) = try make()
        await store.refresh()
        let ticket = try #require(store.beginClear())
        account.relogin()
        await store.refresh()
        #expect(store.summary?.cursor == cursor, "새 세션이 같은 커서를 읽었다")
        let result = await store.sendClear(ticket, isStillValid: { true })
        #expect(result == .ignored && gateway.clears.isEmpty)
        #expect(store.beginClear() != nil, "새 세션은 자기 선택을 따로 받을 수 있다")
    }

    /// 이미 서버로 나간 Clear의 늦은 200은 새 세션에 반영되지 않는다 (다시 읽지도, 메시지도, 성공 표시도 없다)
    @Test func aClearThatOutlivesTheSessionIsDropped() async throws {
        let (store, gateway, account) = try make()
        await store.refresh()
        let hold = Latch()
        gateway.onClear = { _ in
            await hold.wait()
            return ReturnSummaryClearResponse(clearedThrough: .test(0), applied: true)
        }
        let ticket = try #require(store.beginClear())
        let sending = Task { await store.sendClear(ticket, isStillValid: { true }) }
        await waitForArrival(hold)
        let reads = gateway.reads
        account.relogin()
        await hold.open()
        let result = await sending.value
        #expect(result == .ignored)
        #expect(gateway.reads == reads, "옛 세션의 성공이 새 세션의 읽기를 일으키지 않는다")
        #expect(store.summary == nil && store.message == nil && !store.isClearing)
    }

    /// 옛 Clear가 늦게 끝나도 새 세션이 잡은 진행 표시를 풀지 못한다
    @Test func anOldClearFinishingLateDoesNotReleaseTheNewSessionsBusy() async throws {
        let (store, gateway, account) = try make()
        await store.refresh()
        let old = Latch()
        let fresh = Latch()
        let oldCursor = cursor
        gateway.onClear = { sent in
            if sent == oldCursor { await old.wait() } else { await fresh.wait() }
            return ReturnSummaryClearResponse(clearedThrough: .test(0), applied: true)
        }
        let oldTicket = try #require(store.beginClear())
        let oldSend = Task { await store.sendClear(oldTicket, isStillValid: { true }) }
        await waitForArrival(old)
        account.relogin()
        // 새 세션이 같은 UUID로 다시 읽고 새 Clear를 잡는다
        gateway.onRead = { _ in Fx.response([Fx.item(5, changes: [Fx.change()])], cursor: "c2.new-session") }
        await store.refresh()
        let newTicket = try #require(store.beginClear())
        let newSend = Task { await store.sendClear(newTicket, isStillValid: { true }) }
        await waitForArrival(fresh)
        #expect(store.isClearing)
        await old.open()
        _ = await oldSend.value
        #expect(store.isClearing, "옛 요청의 정리가 새 요청의 진행 표시를 지우지 않는다")
        #expect(store.beginClear() == nil, "새 요청이 진행 중이다: 셋째 요청은 받지 않는다")
        await fresh.open()
        #expect(await newSend.value == .cleared(applied: true))
        #expect(!store.isClearing)
    }

    /// Clear 200과 후속 읽기 사이에 계정이 떠나도 어떤 결과도 새 세션에 반영하지 않는다 (모든 await 뒤 다시 본다)
    @Test func theAccountLeavingBetweenTheClearAndTheRereadDropsTheResult() async throws {
        let (store, gateway, account) = try make()
        await store.refresh()
        let reread = Latch()
        gateway.onRead = { number in
            if number >= 2 { await reread.wait() }
            return Fx.response([], cursor: "c2.empty")
        }
        let ticket = try #require(store.beginClear())
        let sending = Task { await store.sendClear(ticket, isStillValid: { true }) }
        await waitForArrival(reread)
        account.relogin()
        await reread.open()
        #expect(await sending.value == .ignored)
        #expect(store.summary == nil && store.message == nil && !store.isClearing)
    }
}
