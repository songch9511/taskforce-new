import Foundation
import Testing
@testable import TaskforceKit

/// 실행 모델 디코딩: contract.ts와 같은 이름, 모르는 값은 `.unknown`, 서버 U2 Mac PR1 전 · 뒤 응답 모두 읽는다
struct ExecutionModelTests {
    private func date(_ string: String) -> Date { PostgresTimestamp.parse(string)! }

    @Test func runWithStoppedAt() throws {
        let run = try ExecutionFixtures.decode(RunSummary.self, ExecutionFixtures.stoppedRun)
        #expect(run.id == ExecutionFixtures.runID)
        #expect(run.actionID == Fixtures.actionID)
        #expect(run.goal == "draft")
        #expect(run.state == .stopped)
        #expect(run.holdReason == nil)
        #expect(run.outcome == nil)
        #expect(run.budgetCredits == nil)
        #expect(run.createdAt == date("2026-10-04T05:00:00.123456Z"))
        #expect(run.stoppedAt == date("2026-10-04T05:20:00Z"))
        #expect(!run.isOpen)
    }

    /// 그 전 서버: `stopped_at`이 없어도 읽는다
    @Test func runWithoutStoppedAt() throws {
        let run = try ExecutionFixtures.decode(RunSummary.self, ExecutionFixtures.heldRun)
        #expect(run.state == .running)
        #expect(run.holdReason == .credit)
        #expect(run.budgetCredits == 40)
        #expect(run.stoppedAt == nil)
        #expect(run.isOpen)
    }

    @Test func unknownRunValues() throws {
        let run = try ExecutionFixtures.decode(RunSummary.self, ExecutionFixtures.futureRun)
        #expect(run.state == .unknown)
        #expect(run.holdReason == .unknown)
        #expect(run.outcome == .unknown)
        #expect(run.stoppedAt == nil)
        // 모르는 상태는 끝났다고도, 진행 중이라고도 보지 않는다
        #expect(!run.state.isOpen && !run.state.isFinished)
    }

    @Test(arguments: [
        ("queued", RunState.queued, true), ("running", .running, true), ("waiting_approval", .waitingApproval, true),
        ("done", .done, false), ("failed", .failed, false), ("stopped", .stopped, false),
    ])
    func runStates(_ raw: String, _ state: RunState, _ open: Bool) {
        #expect(RunState(raw: raw) == state)
        #expect(state.isOpen == open)
        #expect(state.isFinished == !open)
    }

    @Test func stepReceiptKeepsKnownKeysAndIgnoresTheRest() throws {
        let step = try ExecutionFixtures.decode(StepSummary.self, ExecutionFixtures.planStep)
        #expect(step.id == ExecutionFixtures.stepID)
        #expect(step.runID == ExecutionFixtures.runID)
        #expect(step.seq == 1)
        #expect(step.kind == .plan)
        #expect(step.state == .called)
        #expect(step.attempt == 0)
        #expect(step.receipt == StepReceipt(decision: .askUser, question: "어느 고객사 데모인가요?", model: "z-ai/glm-5.3-flash", promptVersion: "plan-v2"))
    }

    @Test func oddStepStillDecodes() throws {
        let step = try ExecutionFixtures.decode(StepSummary.self, ExecutionFixtures.oddStep)
        #expect(step.kind == .unknown)
        #expect(step.state == .unknown)
        #expect(step.receipt?.to == nil)
        #expect(step.receipt?.decision == nil)
        #expect(step.receipt?.error == "rejected")
    }

    @Test func artifactAndPurgedArtifact() throws {
        let draft = try ExecutionFixtures.decode(Artifact.self, ExecutionFixtures.artifact)
        #expect(draft.id == ExecutionFixtures.artifactID)
        #expect(draft.stepID == ExecutionFixtures.stepID)
        #expect(draft.title == "일정 변경 회신")
        #expect(draft.body.hasPrefix("민지 님"))
        #expect(draft.promptVersion == "draft-v1")
        #expect(draft.retainUntil == date("2027-01-02T05:00:00Z"))
        #expect(!draft.isPurged)
        let purged = try ExecutionFixtures.decode(Artifact.self, ExecutionFixtures.purgedArtifact)
        #expect(purged.isPurged)
        #expect(purged.body.isEmpty)
        #expect(purged.bodyPurgedAt == date("2026-07-02T03:00:00Z"))
    }

    /// U2 PR6 서버: 세 필드만 → 새 필드는 기본값 (진행 중 0 · 정산 보류 없음 · 사용량 모름 · 받는 중 · 예약 모름)
    @Test func creditsBeforeServerPR1() throws {
        let credits = try ExecutionFixtures.decode(CreditsSummary.self, ExecutionFixtures.creditsBefore)
        #expect(credits == CreditsSummary(available: 480, reserved: 20, rateVersion: "c3-v1"))
        #expect(credits.runningRuns == 0)
        #expect(credits.settling == .none)
        #expect(credits.used == nil)
        #expect(credits.acceptingRuns)
        #expect(credits.draftEstimateCredits == nil)
        #expect(credits.heldForRunning == 20)
        #expect(!credits.hasPending)
        #expect(!credits.isBelowDraftEstimate)
    }

    @Test func creditsAfterServerPR1() throws {
        let credits = try ExecutionFixtures.decode(CreditsSummary.self, ExecutionFixtures.creditsAfter)
        #expect(credits.available == 0)
        #expect(credits.runningRuns == 1)
        #expect(credits.settling == .init(steps: 1, reserved: 20, actionIDs: [Fixtures.actionID]))
        #expect(credits.used == .init(credits: 188, since: date("2026-09-30T15:00:00Z")))
        #expect(!credits.acceptingRuns)
        #expect(credits.draftEstimateCredits == 20)
        // S3 Reserved = 예약 − 정산 보류, Pending = Unknown
        #expect(credits.heldForRunning == 12)
        #expect(credits.hasPending)
        #expect(credits.isBelowDraftEstimate)
    }

    @Test func creditsWithMalformedNewFields() throws {
        let credits = try ExecutionFixtures.decode(CreditsSummary.self, ExecutionFixtures.creditsOdd)
        #expect(credits.available == 5)
        #expect(credits.rateVersion == nil)
        #expect(credits.runningRuns == 0)
        #expect(credits.settling == .init(steps: 0, reserved: 3, actionIDs: [Fixtures.actionID]))
        #expect(credits.used == nil)
        #expect(credits.acceptingRuns)
        #expect(credits.draftEstimateCredits == nil)
    }

    /// 예산(`budget_credits`)은 보내지 않는다: 잔액만 본다
    @Test func createRunRequestBody() throws {
        let request = CreateRunRequest(actionID: Fixtures.actionID, request: "  견적 회신 메일 초안 써 줘\n")
        #expect(!request.isEmpty)
        let data = try TaskforceJSON.encoder().encode(request)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(object == ["action_id": "11111111-1111-4111-8111-111111111111", "goal": "draft", "request": "견적 회신 메일 초안 써 줘"])
    }

    @Test func createRunRequestTrimsAndCaps() {
        #expect(CreateRunRequest(actionID: Fixtures.actionID, request: " \n\t ").isEmpty)
        let long = CreateRunRequest(actionID: Fixtures.actionID, request: String(repeating: "가", count: 2_100))
        #expect(long.request.count == CreateRunRequest.maxRequestLength)
    }

    @Test(arguments: [
        (409, "conflict", RunStartFailure.consentNeeded, nil as String?),
        (404, "not_found", .unavailable, "Run with AI isn't available right now."),
        (429, "rate_limited", .rateLimited, "Too many runs. Try again later."),
    ])
    func startFailures(_ status: Int, _ code: String, _ expected: RunStartFailure, _ message: String?) {
        let error = APIClient.error(status: status, data: Data(#"{"error":{"code":"\#(code)","message":"서버 설명"}}"#.utf8))
        let failure = RunStartFailure(error)
        #expect(failure == expected)
        #expect(failure.message == message)
        // 서버의 한국어 설명은 보이지 않는다
        #expect(failure.message?.contains("서버") != true)
    }

    /// 서버 zod처럼 UTF-16 단위로 2000, 글자 중간에서 자르지 않음. U+FEFF도 공백으로 뺀다 (JS `trim`)
    @Test func createRunRequestCountsUTF16LikeTheServer() {
        let emoji = CreateRunRequest(actionID: Fixtures.actionID, request: String(repeating: "👍", count: 1_500))
        #expect(emoji.request.utf16.count == 2_000)
        #expect(emoji.request.count == 1_000)
        let odd = CreateRunRequest(actionID: Fixtures.actionID, request: "a" + String(repeating: "👍", count: 1_500))
        #expect(odd.request.utf16.count == 1_999)
        #expect(CreateRunRequest(actionID: Fixtures.actionID, request: " \u{FEFF} \n").isEmpty)
        #expect(CreateRunRequest(actionID: Fixtures.actionID, request: "\u{FEFF}초안\u{FEFF}").request == "초안")
    }

    /// 형식 없는 404(앞단 · 옛 서버)도 쓸 수 없음
    @Test func plainNotFoundIsUnavailable() {
        #expect(RunStartFailure(APIClient.error(status: 404, data: Data("<html>".utf8))) == .unavailable)
    }

    @Test func otherStartFailureUsesTheGeneralLine() {
        let failure = RunStartFailure(.transport("offline"))
        #expect(failure == .other(.transport("offline")))
        #expect(failure.message == "Can't reach the server. Check your connection.")
    }
}
