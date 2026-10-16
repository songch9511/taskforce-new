import Foundation
import Testing
@testable import TaskforceKit

/// OA U3 11.1 · 계약 6장: 읽기 순서 · 계정 경계 · 경로 충돌 해소의 2초 보류 (주입 시계) · 409 자동 재시도 0
@MainActor
struct TaskforceRequestStoreTests {
    typealias Fx = TaskforceStoreFx

    private func make(
        gateway: FakeTaskforceGateway? = nil
    ) -> (store: TaskforceRequestStore, gateway: FakeTaskforceGateway, clock: TaskforceManualClock, account: TaskforceTestAccount) {
        let account = TaskforceTestAccount()
        let clock = TaskforceManualClock()
        let gateway = gateway ?? FakeTaskforceGateway(review: { _ in Fx.response }, details: { _ in [Fx.Fx.lease: Fx.detail] })
        let store = TaskforceRequestStore(gateway: gateway, scope: account.scope, schedule: clock.schedule)
        return (store, gateway, clock, account)
    }

    // MARK: 읽기

    @Test func refreshPublishesTheResponseAndReadsTheConflictDetailsForConflictsOnly() async {
        let (store, gateway, _, _) = make()
        await store.refresh()
        #expect(store.response?.items.count == 6 && store.readProblem == nil && !store.featureOff)
        #expect(store.conflicts[Fx.Fx.lease] == Fx.detail && !store.conflictDetailsMissing)
        #expect(gateway.reviewCalls == 1 && gateway.detailCalls == 1)
        // 충돌이 없는 응답은 상세를 부르지 않는다
        gateway.setReview { _ in Fx.responseWithoutTheConflict }
        await store.refresh()
        #expect(gateway.detailCalls == 1 && store.conflicts.isEmpty)
    }

    @Test func nothingIsReadWithoutALoggedInAccount() async {
        let (store, gateway, _, account) = make()
        account.user = nil
        await store.refresh()
        #expect(gateway.reviewCalls == 0 && store.response == nil)
    }

    @Test func onlyTheLastStartedReadIsApplied() async {
        let gate = TaskforceGate()
        let gateway = FakeTaskforceGateway(review: { call in
            if call == 1 {
                await gate.wait()
                return TaskforceReviewResponse(decisions: [])
            }
            return Fx.response
        }, details: { _ in [Fx.Fx.lease: Fx.detail] })
        let (store, _, _, _) = make(gateway: gateway)
        let first = Task { await store.refresh() }
        while gateway.reviewCalls < 1 { await Task.yield() }
        await store.refresh()
        #expect(store.response?.items.count == 6)
        gate.open()
        await first.value
        #expect(store.response?.items.count == 6, "늦게 끝난 옛 읽기가 새 상태를 되돌리지 못한다")
    }

    @Test func aFailedReadKeepsTheLastResponseAndRaisesTheProblem() async {
        let (store, gateway, _, _) = make()
        await store.refresh()
        gateway.setReview { _ in throw APIError.unexpectedStatus(500) }
        await store.refresh()
        #expect(store.response?.items.count == 6 && store.readProblem == .failed)
        gateway.setReview { _ in Fx.response }
        await store.refresh()
        #expect(store.readProblem == nil)
    }

    @Test func aTransportErrorIsOfflineOnlyWhileOffline() async {
        let (store, gateway, _, _) = make()
        gateway.setReview { _ in throw APIError.transport("The Internet connection appears to be offline.") }
        await store.refresh()
        #expect(store.readProblem == .failed, "온라인인데 끊겼으면 오프라인이라 하지 않는다")
        store.pathChanged(online: false)
        await store.refresh()
        #expect(store.readProblem == .offline)
    }

    @Test func aFeatureOffServerIsNotTrustedAndSaysSo() async {
        let (store, gateway, _, _) = make()
        gateway.setReview { _ in throw APIError.server(status: 404, code: .notFound, message: "없는 경로입니다.") }
        await store.refresh()
        #expect(store.featureOff && store.readProblem == .failed && store.response == nil)
        gateway.setReview { _ in Fx.response }
        await store.refresh()
        #expect(!store.featureOff && store.readProblem == nil)
    }

    @Test func comingBackOnlineReadsAgainOnlyAfterAReadHappened() async {
        let (store, gateway, _, _) = make()
        store.pathChanged(online: false)
        store.pathChanged(online: true)
        await Task.yield()
        #expect(gateway.reviewCalls == 0, "아직 읽은 적이 없으면 화면이 연다")
        await store.refresh()
        store.pathChanged(online: false)
        store.pathChanged(online: true)
        while gateway.reviewCalls < 2 { await Task.yield() }
        #expect(gateway.reviewCalls == 2)
    }

    @Test func missingConflictDetailsKeepThePreviousOnesAndDistrustTheResponse() async {
        let (store, gateway, _, _) = make()
        await store.refresh()
        gateway.setDetails { _ in throw APIError.unexpectedStatus(500) }
        await store.refresh()
        #expect(store.conflictDetailsMissing && store.conflicts[Fx.Fx.lease] == Fx.detail, "전에 읽은 상세는 그대로")
        let visible = store.visible(confirmable: [Fx.Fx.action(7)], knownSessions: [Fx.holderSession, Fx.laterSession])
        #expect(!store.isTrustworthy(visible), "상세를 못 읽었으면 비었다고 말하지 않는다")
        gateway.setDetails { _ in [:] }
        await store.refresh()
        #expect(store.conflictDetailsMissing, "일부만 읽어도 마찬가지다")
    }

    @Test func theVisibleListFollowsTheServerAndTheTrustFollowsTheResponse() async {
        let (store, _, _, _) = make()
        let before = store.visible(confirmable: [], knownSessions: [])
        #expect(before.requests.isEmpty && !store.isTrustworthy(before), "응답이 없으면 아무것도 믿지 않는다")
        await store.refresh()
        let visible = store.visible(confirmable: [Fx.Fx.action(7)], knownSessions: [Fx.holderSession, Fx.laterSession])
        #expect(visible.requests.map(\.kind) == [.resultReady, .pathConflict, .confirm] && store.isTrustworthy(visible))
    }

    // MARK: 계정 경계

    @Test func leavingTheAccountClearsEverythingAndDropsLateResponses() async {
        let gate = TaskforceGate()
        let gateway = FakeTaskforceGateway(review: { call in
            if call == 2 { await gate.wait() }
            return Fx.response
        }, details: { _ in [Fx.Fx.lease: Fx.detail] })
        let (store, _, _, account) = make(gateway: gateway)
        await store.refresh()
        let late = Task { await store.refresh() }
        while gateway.reviewCalls < 2 { await Task.yield() }
        account.scope.accountLeft()
        #expect(store.response == nil && store.conflicts.isEmpty && store.answers.isEmpty && store.notice == nil)
        gate.open()
        await late.value
        #expect(store.response == nil, "바뀐 뒤 도착한 응답은 버린다")
    }

    // MARK: 답 (경로 충돌 해소)

    @Test func choosingStartsATwoSecondHoldAndUndoSendsNothing() async {
        let (store, gateway, clock, _) = make()
        await store.refresh()
        #expect(store.choose(.holder, for: Fx.conflictID))
        #expect(clock.scheduled == [2] && store.answers[Fx.conflictID]?.phase == .holding && store.answers[Fx.conflictID]?.keep == .holder)
        clock.advance(1.9)
        store.undo(Fx.conflictID)
        clock.advance(10)
        #expect(gateway.resolves.isEmpty && store.answers.isEmpty && clock.pending == 0, "2초 안 Undo → 요청 0")
        #expect(clock.cancelled == 1)
    }

    @Test func aHoldThatReachesTwoSecondsSendsExactlyOneResolve() async throws {
        let (store, gateway, clock, _) = make()
        await store.refresh()
        #expect(store.choose(.later, for: Fx.conflictID))
        clock.advance(1.99)
        #expect(gateway.resolves.isEmpty, "2초 전에는 보내지 않는다")
        clock.advance(0.02)
        let send = try #require(store.lastSend)
        let result = await send.value
        #expect(result == .resolved)
        #expect(gateway.resolves == [.init(leaseID: Fx.Fx.lease, keep: .later, conflictVersion: 2)], "ref의 lease · keep · conflict_version 그대로")
        #expect(store.answers[Fx.conflictID] == nil, "해소 뒤 새로 읽고 기록을 지운다")
        #expect(gateway.reviewCalls == 2, "해소 뒤 다시 읽기 한 번")
    }

    @Test func pressingTwiceOrSwitchingTheAnswerWhileHoldingStillSendsOnce() async throws {
        let (store, gateway, clock, _) = make()
        await store.refresh()
        #expect(store.choose(.holder, for: Fx.conflictID))
        #expect(!store.choose(.holder, for: Fx.conflictID), "같은 답을 두 번 눌러도 하나")
        #expect(!store.choose(.later, for: Fx.conflictID), "다른 답으로 바꿔 눌러도 하나 (답은 잠겨 있다)")
        clock.advance(2)
        _ = await store.lastSend?.value
        #expect(gateway.resolves.count == 1 && gateway.resolves.first?.keep == .holder)
    }

    @Test func aRequestThatIsNotAConflictInTheResponseCannotBeAnswered() async {
        let (store, gateway, clock, _) = make()
        #expect(!store.choose(.holder, for: Fx.conflictID), "응답이 없다")
        await store.refresh()
        #expect(!store.choose(.holder, for: "confirm:\(Fx.Fx.action(7).uuidString.lowercased())"), "충돌이 아니다")
        #expect(!store.choose(.holder, for: "path_conflict:nope"))
        clock.advance(5)
        #expect(gateway.resolves.isEmpty && store.answers.isEmpty)
    }

    @Test func switchingTheAccountDuringTheHoldSendsNothing() async {
        let (store, gateway, clock, account) = make()
        await store.refresh()
        #expect(store.choose(.holder, for: Fx.conflictID))
        account.scope.accountLeft()
        clock.advance(5)
        #expect(gateway.resolves.isEmpty && store.answers.isEmpty && clock.pending == 0, "계정 전환 → 0")
        // 같은 UUID의 재로그인도 새 세션이다
        let (store2, gateway2, clock2, account2) = make()
        await store2.refresh()
        #expect(store2.choose(.holder, for: Fx.conflictID))
        account2.scope.accountLeft()
        clock2.advance(5)
        #expect(gateway2.resolves.isEmpty)
    }

    @Test func aVersionChangeDuringTheHoldDropsTheHoldAndShowsTheNewCard() async {
        let (store, gateway, clock, _) = make()
        await store.refresh()
        #expect(store.choose(.holder, for: Fx.conflictID))
        gateway.setReview { _ in Fx.response(conflictVersion: 3) }
        await store.refresh()
        #expect(store.answers[Fx.conflictID] == nil && clock.cancelled == 1, "보류 중 그 요청 version이 바뀜 → 보류가 풀린다")
        clock.advance(5)
        #expect(gateway.resolves.isEmpty, "→ 0")
        // 새 카드: 새 version으로 다시 고를 수 있다
        #expect(store.choose(.later, for: Fx.conflictID))
        clock.advance(2)
        _ = await store.lastSend?.value
        #expect(gateway.resolves == [.init(leaseID: Fx.Fx.lease, keep: .later, conflictVersion: 3)])
    }

    @Test func aRequestResolvedElsewhereDuringTheHoldSendsNothing() async {
        let (store, gateway, clock, _) = make()
        await store.refresh()
        #expect(store.choose(.holder, for: Fx.conflictID))
        gateway.setReview { _ in Fx.responseWithoutTheConflict }
        await store.refresh()
        clock.advance(5)
        #expect(gateway.resolves.isEmpty && store.answers.isEmpty)
    }

    @Test func anUnreadDecisionSourceDoesNotDropTheHoldButTheSendRechecks() async {
        let (store, gateway, clock, _) = make()
        await store.refresh()
        #expect(store.choose(.holder, for: Fx.conflictID))
        gateway.setReview { _ in TaskforceReviewResponse(complete: false, sources: .init(decisions: .unavailable), decisions: nil) }
        await store.refresh()
        #expect(store.answers[Fx.conflictID]?.phase == .holding, "결정 원천을 못 읽은 것은 요청이 없다는 뜻이 아니다")
        clock.advance(2)
        _ = await store.lastSend?.value
        #expect(gateway.resolves.isEmpty, "보낼 때 요청이 보이지 않으면 쓰기 0")
    }

    @Test func conflictVersionBoundariesAreOneAndTheDatabaseIntegerMax() async {
        for version in [1, 2_147_483_647] {
            let (store, gateway, clock, _) = make()
            gateway.setReview { _ in Fx.response(conflictVersion: version) }
            await store.refresh()
            #expect(store.choose(.holder, for: Fx.conflictID))
            clock.advance(2)
            _ = await store.lastSend?.value
            #expect(gateway.resolves.map(\.conflictVersion) == [version])
        }
        for version in [0, 2_147_483_648, -1] {
            let (store, gateway, clock, _) = make()
            gateway.setReview { _ in Fx.response(conflictVersion: version) }
            await store.refresh()
            #expect(!store.choose(.holder, for: Fx.conflictID), "경계 밖 \(version)은 보내지 않는다")
            clock.advance(5)
            #expect(gateway.resolves.isEmpty)
        }
    }

    @Test func aConflictResponseNeverTriggersAnAutomaticRetry() async {
        let (store, gateway, clock, _) = make()
        gateway.setResolve { _ in throw APIError.server(status: 409, code: .conflict, message: "그 사이 바뀌었습니다") }
        await store.refresh()
        let readsBefore = gateway.reviewCalls
        #expect(store.choose(.holder, for: Fx.conflictID))
        clock.advance(2)
        let result = await store.lastSend?.value
        #expect(result == .conflict)
        clock.advance(30)
        _ = await store.lastSend?.value
        #expect(gateway.resolves.count == 1, "409 뒤 자동 재시도 0")
        #expect(gateway.reviewCalls == readsBefore + 1, "대신 다시 읽는다 (한 번)")
        #expect(store.notice(for: Fx.conflictID) == ReviewCopy.conflict)
        #expect(store.answers.isEmpty)
    }

    @Test(arguments: [
        (404, APIErrorCode.notFound, TaskforceResolveResult.conflict),
        (400, APIErrorCode.invalidRequest, .rejected),
        (500, APIErrorCode.internalError, .unconfirmed),
    ])
    func eachFailureStatusIsReadBackAndNeverRetried(_ status: Int, _ code: APIErrorCode, _ expected: TaskforceResolveResult) async {
        let (store, gateway, clock, _) = make()
        gateway.setResolve { _ in throw APIError.server(status: status, code: code, message: "x") }
        await store.refresh()
        #expect(store.choose(.later, for: Fx.conflictID))
        clock.advance(2)
        let result = await store.lastSend?.value
        #expect(result == expected)
        #expect(gateway.resolves.count == 1 && store.answers.isEmpty && store.notice != nil)
        if expected == .unconfirmed { #expect(store.notice(for: Fx.conflictID) == ReviewCopy.unverified) }
    }

    @Test func aLostResponseIsUnconfirmedAndRereadsInsteadOfClaimingSuccess() async {
        let (store, gateway, clock, _) = make()
        gateway.setResolve { _ in throw APIError.transport("network connection lost") }
        await store.refresh()
        #expect(store.choose(.holder, for: Fx.conflictID))
        clock.advance(2)
        let result = await store.lastSend?.value
        #expect(result == .unconfirmed && store.notice(for: Fx.conflictID) == ReviewCopy.unverified)
        #expect(gateway.resolves.count == 1 && gateway.reviewCalls == 2)
    }

    @Test func anUnknownStatusInA200IsNotASuccess() async {
        let (store, gateway, clock, _) = make()
        gateway.setResolve { _ in try JSONDecoder().decode(TaskforceResolveConflictResponse.self, from: Data(#"{"status":"queued"}"#.utf8)) }
        await store.refresh()
        #expect(store.choose(.holder, for: Fx.conflictID))
        clock.advance(2)
        let result = await store.lastSend?.value
        #expect(result == .unconfirmed && store.notice(for: Fx.conflictID) == ReviewCopy.unverified)
    }

    @Test func aResolveAnsweredAfterTheAccountLeftIsDroppedWithoutTouchingTheNewSession() async {
        let gate = TaskforceGate()
        let (store, gateway, clock, account) = make()
        gateway.setResolve { _ in
            await gate.wait()
            return .resolved
        }
        await store.refresh()
        #expect(store.choose(.holder, for: Fx.conflictID))
        clock.advance(2)
        while gateway.resolves.isEmpty { await Task.yield() }
        account.scope.accountLeft()
        gate.open()
        let result = await store.lastSend?.value
        #expect(result == .ignored)
        #expect(store.notice == nil && store.answers.isEmpty && store.response == nil, "옛 요청의 결과가 새 세션을 건드리지 않는다")
    }

    @Test func undoAfterTheHoldHasNoEffect() async {
        let (store, gateway, clock, _) = make()
        let gate = TaskforceGate()
        gateway.setResolve { _ in
            await gate.wait()
            return .resolved
        }
        await store.refresh()
        #expect(store.choose(.holder, for: Fx.conflictID))
        clock.advance(2)
        while gateway.resolves.isEmpty { await Task.yield() }
        #expect(store.answers[Fx.conflictID]?.phase == .sending)
        store.undo(Fx.conflictID)
        #expect(store.answers[Fx.conflictID]?.phase == .sending, "보낸 뒤에는 Undo가 없다")
        gate.open()
        _ = await store.lastSend?.value
    }

    @Test func theNoticeSurvivesTheRequestLeavingTheList() async {
        let (store, gateway, clock, _) = make()
        gateway.setResolve { _ in throw APIError.server(status: 409, code: .conflict, message: "x") }
        await store.refresh()
        #expect(store.choose(.holder, for: Fx.conflictID))
        gateway.setReview { _ in Fx.responseWithoutTheConflict }
        clock.advance(2)
        _ = await store.lastSend?.value
        // 요청이 사라졌어도 안내는 남는다: 사라졌다는 사실은 내 요청의 성공 증거가 아니다
        #expect(store.response?.items.contains { $0.id == Fx.conflictID } == false)
        #expect(store.notice(for: Fx.conflictID) == ReviewCopy.conflict)
        store.clearNotice()
        #expect(store.notice == nil)
    }
}
