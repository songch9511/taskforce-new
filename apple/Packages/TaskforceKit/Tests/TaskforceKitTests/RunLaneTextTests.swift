import Foundation
import Testing
@testable import TaskforceKit

/// 갈래 카드의 글 (Mac 런처 · iPhone P2 · P9): 상태마다 제목 · 부제, 초안이 있으면 어느 상태든 `View Draft`
struct RunLaneTextTests {
    typealias F = RunFixture
    /// 견본 시각은 서울 기준 2026-10-03 13:00
    let seoul = TimeZone(identifier: "Asia/Seoul")!
    var now: Date { F.start.addingTimeInterval(3_600) }

    func laneText(_ lane: RunLane) -> RunLaneText? {
        RunLaneText.make(lane, now: now, timeZone: seoul)
    }

    @Test func hiddenLaneHasNoText() {
        #expect(laneText(RunLane.state(run: nil, steps: [], artifacts: [])) == nil)
        #expect(laneText(RunLane.state(run: F.run(.unknown), steps: [], artifacts: [])) == nil)
    }

    /// 초안 제목이 제목, VoiceOver는 "Taskforce, Draft ready, …"
    @Test func draftReady() throws {
        let lane = RunLane.state(run: F.run(.done, outcome: .draftReady), steps: [F.plan], artifacts: [F.draft(1)])
        let text = try #require(laneText(lane))
        #expect(text.title == "초안 1")
        #expect(text.subtitle == "AI draft · 13:01")
        #expect(text.spokenState == "Draft ready")
        #expect(text.draft?.id == F.id(201))
    }

    /// 초안이 여럿이면 개수 + 가장 최근 초안
    @Test func severalDrafts() throws {
        let lane = RunLane.state(
            run: F.run(.done, outcome: .draftReady), steps: [], artifacts: [F.draft(1, minutes: 1), F.draft(2, minutes: 20), F.draft(3, minutes: 5)]
        )
        let text = try #require(laneText(lane))
        #expect(text.title == "초안 2")
        #expect(text.subtitle == "3 AI drafts · 13:20")
        #expect(text.draft?.id == F.id(202))
    }

    /// 빈 초안 제목이면 상태를 제목으로 (같은 말을 두 번 읽지 않는다)
    @Test func blankDraftTitle() throws {
        let created = F.start
        let blank = Artifact(
            id: F.id(9), runID: F.id(1), stepID: F.id(8), actionID: F.action, title: "  ", body: "본문", retainUntil: created, createdAt: created
        )
        let text = try #require(laneText(RunLane.state(run: F.run(.done, outcome: .draftReady), steps: [], artifacts: [blank])))
        #expect(text.title == "Draft ready")
        #expect(text.spokenState == nil)
    }

    @Test func working() throws {
        let text = try #require(laneText(RunLane.state(run: F.run(.running), steps: [F.plan], artifacts: [])))
        #expect(text == RunLaneText(title: "Writing draft", subtitle: "Started 13:00"))
    }

    /// M12 크레딧 부족 문장, 다른 막힘은 후보
    @Test(arguments: [
        (RunHoldReason.credit, "Not enough credits. New paid steps are paused."),
        (.needsConnection, "Waiting for a connection."),
        (.blocked, "New steps are on hold."),
        (.actor, "New steps are on hold."),
        (.unknown, "New steps are on hold."),
    ])
    func paused(_ hold: RunHoldReason, _ subtitle: String) throws {
        let text = try #require(laneText(RunLane.state(run: F.run(.running, hold: hold), steps: [], artifacts: [])))
        #expect(text == RunLaneText(title: "Paused", subtitle: subtitle))
    }

    /// P9: 시각은 서버 `stopped_at` (어느 기기에서 멈췄든). 없으면 시각 없이, 부르던 단계가 남았으면 부제
    @Test func stopped() throws {
        let at = F.start.addingTimeInterval(1_200)
        let finishing = try #require(laneText(RunLane.state(run: F.run(.stopped, stoppedAt: at), steps: [F.step(2, .draft, .calling)], artifacts: [])))
        #expect(finishing == RunLaneText(title: "Stop requested 13:20. No new steps will start.", subtitle: "Finishing the current step."))
        let noTime = try #require(laneText(RunLane.state(run: F.run(.stopped), steps: [F.plan], artifacts: [])))
        #expect(noTime == RunLaneText(title: "Stopped. No new steps will start."))
    }

    /// 멈춤 · 실패 · needs_*에도 앞서 만든 초안은 `View Draft` (A39)
    @Test func draftsSurviveOtherStates() throws {
        let stopped = try #require(laneText(RunLane.state(run: F.run(.stopped), steps: [], artifacts: [F.draft(1)])))
        #expect(stopped.draft?.id == F.id(201))
        #expect(stopped.spokenState == nil)
        let failed = try #require(laneText(RunLane.state(run: F.run(.failed), steps: [], artifacts: [F.draft(1)])))
        #expect(failed.draft?.id == F.id(201))
        let asking = try #require(laneText(RunLane.state(run: F.run(.done, outcome: .needsInput), steps: [], artifacts: [F.draft(1)])))
        #expect(asking.draft?.id == F.id(201))
    }

    @Test func needsInput() throws {
        let ask = F.step(1, .plan, .called, StepReceipt(decision: .askUser, question: "어느 고객사인가요?"))
        let asked = try #require(laneText(RunLane.state(run: F.run(.done, outcome: .needsInput), steps: [ask], artifacts: [])))
        #expect(asked == RunLaneText(title: "Taskforce has a question", subtitle: "어느 고객사인가요?"))
        // 90일 정리로 질문이 지워짐
        let purged = try #require(laneText(RunLane.state(run: F.run(.done, outcome: .needsInput), steps: [], artifacts: [])))
        #expect(purged.subtitle == "Question deleted after 90 days.")
    }

    @Test(arguments: [("gmail.send", "Connect Gmail to continue." as String?), ("slack.post", "Connect Slack to continue."), ("fax.send", nil)])
    func needsConnection(_ capability: String, _ subtitle: String?) throws {
        let step = F.step(1, .plan, .called, StepReceipt(decision: .needsConnection, capability: capability))
        let text = try #require(laneText(RunLane.state(run: F.run(.done, outcome: .needsConnection), steps: [step], artifacts: [])))
        #expect(text == RunLaneText(title: "Connection needed", subtitle: subtitle))
    }

    @Test(arguments: [
        ("consent", "AI processing was turned off." as String?), ("rejected", "The AI provider declined the request."),
        ("retries_exhausted", "Stopped after several tries."), ("action_missing", "The task was deleted."), ("brand_new", nil),
    ])
    func failed(_ error: String, _ subtitle: String?) throws {
        let step = F.step(2, .draft, .failed, StepReceipt(error: error))
        let text = try #require(laneText(RunLane.state(run: F.run(.failed), steps: [F.plan, step], artifacts: [])))
        #expect(text == RunLaneText(title: "Couldn’t finish the draft", subtitle: subtitle))
    }

    @Test func finishedWithoutDraft() throws {
        let done = F.step(1, .plan, .called, StepReceipt(decision: .done))
        #expect(laneText(RunLane.state(run: F.run(.done), steps: [done], artifacts: [])) == RunLaneText(title: "Finished without a draft"))
    }

    /// 오늘은 시각만 (P9 `Stop requested 14:20.`), 어제는 `Yesterday 13:00`, 그 전은 날짜
    @Test func clock() {
        #expect(RunLaneText.clock(F.start, now: now, timeZone: seoul) == "13:00")
        #expect(RunLaneText.clock(F.start.addingTimeInterval(-86_400), now: now, timeZone: seoul) == "Yesterday 13:00")
        #expect(RunLaneText.clock(F.start.addingTimeInterval(-86_400 * 5), now: now, timeZone: seoul) == "Sep 28")
    }
}

/// iPhone 행 누르기: 실행을 쓸 수 있는 계정만 상세, 나머지는 U1 PR5b 그대로 근거 펼치기 (운영 회귀 0)
struct PhoneRowTapTests {
    @Test func detailOnlyWhenExecutionIsAvailable() {
        #expect(PhoneHome.rowTap(executionAvailable: true) == .openDetail)
        #expect(PhoneHome.rowTap(executionAvailable: false) == .expandSource)
    }
}
