import Foundation
import Testing
@testable import Taskforce
@testable import TaskforceKit

/// `NowStore.act`(Confirm · Dismiss가 거치는 쓰기)를 진짜 `APIClient`로 부르고, 계정이 바뀌는 사이의 busy를 가른다 (S4)
@Suite(.serialized)
@MainActor
struct NowStoreReviewTests {
    // MARK: 지금 동작 (구 소비자: 구 런처가 `confirm` · `dismiss`를 그대로 부른다)

    @Test func confirmSendsOneRequestThenReloadsTheList() async throws {
        let harness = try await ReviewHarness.make()
        await harness.store.load()
        #expect(harness.store.sections.review.map(\.id) == (1...3).map(ReviewHarness.id))

        await harness.store.confirm(ReviewHarness.id(2))

        #expect(await harness.server.writeCount("confirm", for: ReviewHarness.id(2)) == 1)
        #expect(harness.store.sections.review.map(\.id) == [1, 3].map(ReviewHarness.id), "서버가 받은 뒤 다시 읽은 목록")
        #expect(harness.store.busy.isEmpty && harness.store.message == nil)
    }

    @Test func dismissIsADeleteAndAFailureKeepsTheItemWithAMessage() async throws {
        let harness = try await ReviewHarness.make()
        await harness.store.load()
        await harness.server.script(ReviewHarness.id(1), .reject(409, "conflict"))

        await harness.store.dismiss(ReviewHarness.id(1))

        #expect(await harness.server.writeCount("delete", for: ReviewHarness.id(1)) == 0, "거절된 요청은 서버가 적용하지 않았다")
        #expect(await harness.server.arrived(ReviewHarness.id(1)) == 1)
        #expect(harness.store.message == "This changed somewhere else. It's been refreshed.")
        #expect(harness.store.sections.review.map(\.id).contains(ReviewHarness.id(1)), "목록은 다시 읽은 지금 상태")
        #expect(harness.store.busy.isEmpty)
    }

    // MARK: 계정이 바뀌는 사이

    /// 같은 UUID로 다시 로그인한 뒤 새 세션이 같은 할 일에 새 요청을 잡았는데, 옛 요청이 늦게 끝나면 옛 요청의 `defer`가 새 요청의 busy를 지웠다
    @Test func anOldWriteFinishingLateDoesNotReleaseTheNewSessionsBusy() async throws {
        let harness = try await ReviewHarness.make()
        let id = ReviewHarness.id(1)
        await harness.store.load()
        await harness.server.hold(id)

        let old = Task { await harness.store.confirm(id) }
        #expect(await harness.wait { await harness.server.arrived(id) == 1 })
        #expect(harness.store.busy.contains(id))

        harness.reloginSameUser()
        #expect(harness.store.busy.isEmpty, "계정이 떠나면 busy는 비워진다")
        await harness.store.load()
        let new = Task { await harness.store.confirm(id) }
        #expect(await harness.wait { await harness.server.arrived(id) == 2 })
        #expect(harness.store.busy.contains(id))

        await harness.server.releaseNext(id)
        await old.value
        #expect(harness.store.busy.contains(id), "옛 요청이 끝나도 새 세션의 요청은 아직 진행 중이다")

        await harness.server.release(id)
        await new.value
        #expect(harness.store.busy.isEmpty)
    }
}

// MARK: Review 답 (S4): 결과 · 항목당 요청 하나 · 정직한 실패 · 계정 경계

@Suite(.serialized)
@MainActor
struct NowStoreAnswerReviewTests {
    static let id1 = ReviewHarness.id(1)

    // MARK: 성공

    @Test func aConfirmIsOneWriteAndTheItemLeavesReviewAfterTheServerTookIt() async throws {
        let harness = try await ReviewHarness.make()
        await harness.store.load()

        let result = await harness.store.answerReview(Self.id1, .confirm)

        #expect(result == .applied)
        #expect(await harness.server.writeCount("confirm", for: Self.id1) == 1 && harness.store.busy.isEmpty)
        #expect(harness.store.sections.review.map(\.id) == [2, 3].map(ReviewHarness.id))
        #expect(harness.store.message == nil, "Review의 안내는 호출한 쪽이 한다: 구 런처의 message를 건드리지 않는다")
    }

    @Test func aDismissIsOneDelete() async throws {
        let harness = try await ReviewHarness.make()
        await harness.store.load()

        #expect(await harness.store.answerReview(Self.id1, .dismiss) == .applied)

        #expect(await harness.server.writeCount("delete", for: Self.id1) == 1)
        #expect(await harness.server.writeCount("confirm") == 0)
        #expect(!harness.store.sections.review.map(\.id).contains(Self.id1))
    }

    // MARK: 항목당 요청 하나

    @Test func repeatedOrCompetingAnswersWhileOneIsInFlightSendNothing() async throws {
        let harness = try await ReviewHarness.make()
        await harness.store.load()
        await harness.server.hold(Self.id1)

        let first = Task { await harness.store.answerReview(Self.id1, .confirm) }
        #expect(await harness.wait { await harness.server.arrived(Self.id1) == 1 })
        // 반복 키 · 중복 클릭 · 다른 답: 모두 보내지 않는다
        #expect(await harness.store.answerReview(Self.id1, .confirm) == .ignored)
        #expect(await harness.store.answerReview(Self.id1, .dismiss) == .ignored)
        #expect(await harness.store.answerReview(Self.id1, .confirm) == .ignored)

        await harness.server.release(Self.id1)
        #expect(await first.value == .applied)
        #expect(await harness.server.arrived(Self.id1) == 1)
        #expect(await harness.server.writeCount(for: Self.id1) == 1)
        #expect(harness.store.busy.isEmpty)
    }

    @Test func otherItemsAreNotBlockedByAnItemInFlight() async throws {
        let harness = try await ReviewHarness.make()
        await harness.store.load()
        await harness.server.hold(Self.id1)

        let first = Task { await harness.store.answerReview(Self.id1, .confirm) }
        #expect(await harness.wait { await harness.server.arrived(Self.id1) == 1 })
        #expect(await harness.store.answerReview(ReviewHarness.id(2), .dismiss) == .applied)
        await harness.server.release(Self.id1)
        #expect(await first.value == .applied)
        #expect(await harness.server.writeCount() == 2)
    }

    // MARK: 200 뒤, 더 새 목록 전

    @Test func anAnsweredItemStaysOutOfReviewEvenIfTheReloadAfterwardFails() async throws {
        let harness = try await ReviewHarness.make()
        await harness.store.load()
        await harness.server.setNow(.lose)

        let result = await harness.store.answerReview(Self.id1, .confirm)

        // 서버는 받았다. 다시 읽기가 실패해 가진 목록은 이 답보다 오래됐지만, 이미 처리한 항목에 다시 답할 수 있게 두지 않는다
        #expect(result == .applied)
        #expect(harness.store.response?.confirmations.map(\.id).contains(Self.id1) == true, "가진 목록은 옛 것")
        #expect(!harness.store.sections.review.map(\.id).contains(Self.id1))
    }

    @Test func aNewerListIsTheTruthEvenIfTheItemIsBackInReview() async throws {
        let harness = try await ReviewHarness.make()
        await harness.store.load()
        await harness.server.setNow(.lose)
        #expect(await harness.store.answerReview(Self.id1, .confirm) == .applied)
        #expect(!harness.store.sections.review.map(\.id).contains(Self.id1))

        // 그 사이 서버가 같은 할 일을 다시 확인 요청으로 올렸다 (새 원문): 더 새 목록이 말한다
        await harness.server.setNow(.ok)
        await harness.server.reflag(Self.id1, at: Date(timeIntervalSince1970: 1_792_000_000))
        await harness.store.load()
        #expect(harness.store.sections.review.map(\.id).contains(Self.id1), "새 목록이 오면 그 목록이 진실이다")
    }

    // MARK: 정직한 실패 (자동으로 다시 보내지 않는다)

    @Test(arguments: [
        (409, "conflict", "This changed somewhere else. It's been refreshed."),
        (404, "not_found", "Not found. It may have been removed."),
        (429, "rate_limited", "Too many requests. Try again in a moment."),
        (403, "forbidden", "Something went wrong. Try again in a moment."),
    ])
    func aServerRefusalIsNotAppliedAndIsNeverResent(status: Int, code: String, text: String) async throws {
        let harness = try await ReviewHarness.make()
        await harness.store.load()
        await harness.server.script(Self.id1, .reject(status, code))
        let readsBefore = await harness.server.nowRequests

        let result = await harness.store.answerReview(Self.id1, .confirm)

        #expect(result == .rejected(text))
        // 지금 상태를 다시 읽었고, 항목은 그대로 (적용되지 않았다)
        #expect(await harness.server.nowRequests == readsBefore + 1)
        #expect(harness.store.sections.review.map(\.id).contains(Self.id1))
        #expect(harness.store.busy.isEmpty && harness.store.message == nil)
        try await Task.sleep(for: .milliseconds(80))
        #expect(await harness.server.arrived(Self.id1) == 1, "자동 재전송 없음")
        #expect(await harness.server.writeCount() == 0)
    }

    @Test func aLostResponseIsUnverifiedEvenWhenTheItemThenLeavesTheList() async throws {
        let harness = try await ReviewHarness.make()
        await harness.store.load()
        await harness.server.script(Self.id1, .applyThenLose)

        let result = await harness.store.answerReview(Self.id1, .confirm)

        // 서버는 적용했지만 앱은 알 수 없다: 성공이라고 하지 않는다. 다시 읽은 목록에서 항목이 없어진 것은 내 요청의 성공 증거가 아니다
        #expect(result == .unverified)
        #expect(!harness.store.sections.review.map(\.id).contains(Self.id1))
        try await Task.sleep(for: .milliseconds(80))
        #expect(await harness.server.arrived(Self.id1) == 1, "자동 재전송 없음")
    }

    @Test(arguments: [FakeWrite.loseBeforeApply, .applyWithGarbage, .applyThenServerError])
    func anUnreadableOrFailedResponseIsUnverifiedAndNotResent(behavior: FakeWrite) async throws {
        let harness = try await ReviewHarness.make()
        await harness.store.load()
        await harness.server.script(Self.id1, behavior)

        #expect(await harness.store.answerReview(Self.id1, .dismiss) == .unverified)

        #expect(harness.store.busy.isEmpty)
        try await Task.sleep(for: .milliseconds(80))
        #expect(await harness.server.arrived(Self.id1) == 1)
        // 서버가 받았을 수도 있으니 항목은 다시 읽은 목록이 말하는 대로다
        let applied = await harness.server.writeCount(for: Self.id1) == 1
        #expect(harness.store.sections.review.map(\.id).contains(Self.id1) == !applied)
    }

    @Test func aUserCanAnswerAgainAfterAFailureButOnlyByChoosingAgain() async throws {
        let harness = try await ReviewHarness.make()
        await harness.store.load()
        await harness.server.script(Self.id1, .loseBeforeApply)

        #expect(await harness.store.answerReview(Self.id1, .confirm) == .unverified)
        #expect(await harness.server.arrived(Self.id1) == 1)
        // 사용자가 다시 골랐다: 새 요청 하나
        #expect(await harness.store.answerReview(Self.id1, .confirm) == .applied)
        #expect(await harness.server.arrived(Self.id1) == 2)
        #expect(await harness.server.writeCount("confirm", for: Self.id1) == 1)
    }

    // MARK: 계정 · 세션 경계

    @Test(arguments: [false, true])
    func anOldAnswerFinishingAfterANewSessionIsIgnoredAndLeavesTheNewSessionAlone(differentAccount: Bool) async throws {
        let harness = try await ReviewHarness.make()
        await harness.store.load()
        await harness.server.hold(Self.id1)

        let old = Task { await harness.store.answerReview(Self.id1, .confirm) }
        #expect(await harness.wait { await harness.server.arrived(Self.id1) == 1 })
        if differentAccount { try harness.switchAccount() } else { harness.reloginSameUser() }
        #expect(harness.store.busy.isEmpty && harness.store.response == nil, "계정이 떠나면 비워진다")
        await harness.store.load()
        let new = Task { await harness.store.answerReview(Self.id1, .dismiss) }
        #expect(await harness.wait { await harness.server.arrived(Self.id1) == 2 })

        await harness.server.releaseNext(Self.id1)
        #expect(await old.value == .ignored, "옛 요청의 결과는 새 세션에 반영되지 않는다")
        #expect(harness.store.busy.contains(Self.id1), "새 요청의 busy는 그대로")
        #expect(harness.store.sections.review.map(\.id).contains(Self.id1), "옛 요청의 200이 새 세션의 목록에서 항목을 빼지 않는다")
        #expect(harness.store.message == nil)
        // 새 세션은 같은 할 일에 겹쳐 보내지 않는다
        #expect(await harness.store.answerReview(Self.id1, .confirm) == .ignored)

        await harness.server.release(Self.id1)
        #expect(await new.value == .applied)
        #expect(harness.store.busy.isEmpty)
    }

    @Test func aTokenRefreshKeepsTheInFlightAnswer() async throws {
        let harness = try await ReviewHarness.make()
        await harness.store.load()
        await harness.server.hold(Self.id1)

        let task = Task { await harness.store.answerReview(Self.id1, .confirm) }
        #expect(await harness.wait { await harness.server.arrived(Self.id1) == 1 })
        try harness.refreshToken()
        #expect(harness.store.busy.contains(Self.id1) && harness.store.response != nil, "같은 계정의 토큰 갱신은 계정이 떠난 것이 아니다")

        await harness.server.release(Self.id1)
        #expect(await task.value == .applied)
        #expect(!harness.store.sections.review.map(\.id).contains(Self.id1))
    }

    @Test func signingOutWhileTheFollowUpReadIsInFlightLeavesNothingBehind() async throws {
        let harness = try await ReviewHarness.make()
        await harness.store.load()
        await harness.server.holdNowReads()

        let task = Task { await harness.store.answerReview(Self.id1, .confirm) }
        #expect(await harness.wait { await harness.server.pendingNowReads() == 1 })
        harness.signOut()
        await harness.server.releaseNowReads()

        #expect(await task.value == .ignored)
        #expect(harness.store.response == nil && harness.store.sections.review.isEmpty && harness.store.busy.isEmpty, "떠난 계정의 목록이 되돌아오지 않는다")
    }

    @Test func theAnsweredMarkIsPerSessionAndDoesNotHideAnItemForTheNextSession() async throws {
        let harness = try await ReviewHarness.make()
        await harness.store.load()
        await harness.server.setNow(.lose)
        #expect(await harness.store.answerReview(Self.id1, .confirm) == .applied)
        #expect(!harness.store.sections.review.map(\.id).contains(Self.id1))

        harness.reloginSameUser()
        await harness.server.setNow(.ok)
        await harness.server.reflag(Self.id1, at: Date(timeIntervalSince1970: 1_792_000_000))
        await harness.store.load()
        #expect(harness.store.sections.review.map(\.id).contains(Self.id1), "새 세션은 옛 세션의 답 표시에 가려지지 않는다")
    }
}
