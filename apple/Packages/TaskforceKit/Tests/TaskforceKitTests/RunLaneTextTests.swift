import Foundation
import Testing
@testable import TaskforceKit

/// 갈래 카드의 글 (Mac 런처 · iPhone P2 · P9): 상태마다 제목 · 부제, 초안이 있으면 어느 상태든 `View Draft`.
/// 따로 적지 않은 사례는 iPhone 글 (Mac만 다른 것은 `macDifferences`)
struct RunLaneTextTests {
    typealias F = RunFixture
    /// 견본 시각은 서울 기준 2026-10-03 13:00
    let seoul = TimeZone(identifier: "Asia/Seoul")!
    var now: Date { F.start.addingTimeInterval(3_600) }

    func laneText(_ lane: RunLane, platform: RunPlatform = .iOS) -> RunLaneText? {
        RunLaneText.make(lane, platform: platform, now: now, timeZone: seoul)
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

    /// M12 크레딧 부족 문장, 다른 막힘은 후보 (Mac 갈래와 같은 말, iPhone은 `Run with AI`라는 말을 쓰지 않는다)
    @Test(arguments: [
        (RunHoldReason.credit, "Draft paused", "Not enough credits. New paid steps are paused." as String?),
        (.needsConnection, "Paused", "Needs a connection to continue."),
        (.blocked, "Paused", "New steps are paused for now."),
        (.actor, "Paused", "New steps are paused for now."),
        (.unknown, "Paused", nil),
    ])
    func paused(_ hold: RunHoldReason, _ title: String, _ subtitle: String?) throws {
        let text = try #require(laneText(RunLane.state(run: F.run(.running, hold: hold), steps: [], artifacts: [])))
        #expect(text == RunLaneText(title: title, subtitle: subtitle))
        #expect(!text.title.contains("Run with AI") && !(text.subtitle ?? "").contains("Run with AI"))
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

    @Test(arguments: [
        ("gmail.send", "Connect Gmail to continue."), ("calendar.write", "Connect Google Calendar to continue."),
        ("fax.send", "Connect a service to continue."),
    ])
    func needsConnection(_ capability: String, _ subtitle: String) throws {
        let step = F.step(1, .plan, .called, StepReceipt(decision: .needsConnection, capability: capability))
        let text = try #require(laneText(RunLane.state(run: F.run(.done, outcome: .needsConnection), steps: [step], artifacts: [])))
        #expect(text == RunLaneText(title: "Needs a connection", subtitle: subtitle))
    }

    @Test(arguments: [
        ("consent", "AI processing was turned off." as String?), ("rejected", "The AI provider declined this request."),
        ("retries_exhausted", "Stopped after too many retries."), ("action_missing", "The task was deleted."), ("brand_new", nil),
    ])
    func failed(_ error: String, _ subtitle: String?) throws {
        let step = F.step(2, .draft, .failed, StepReceipt(error: error))
        let text = try #require(laneText(RunLane.state(run: F.run(.failed), steps: [F.plan, step], artifacts: [])))
        #expect(text == RunLaneText(title: "Couldn't finish the draft", subtitle: subtitle))
    }

    @Test func finishedWithoutDraft() throws {
        let done = F.step(1, .plan, .called, StepReceipt(decision: .done))
        #expect(laneText(RunLane.state(run: F.run(.done), steps: [done], artifacts: [])) == RunLaneText(title: "No draft needed"))
    }

    /// 기기마다 다른 것 둘: 멈춤 문장의 시각(Mac은 액션 바), 실행 주체 밖 문장(`Run with AI`는 Mac에만). 나머지는 같다
    @Test func macDifferences() throws {
        let at = F.start.addingTimeInterval(1_200)
        let stopped = RunLane.state(run: F.run(.stopped, stoppedAt: at), steps: [F.step(2, .draft, .calling)], artifacts: [])
        #expect(laneText(stopped, platform: .macOS) == RunLaneText(title: "Stopped. No new steps will start.", subtitle: "Finishing the current step."))
        #expect(laneText(stopped, platform: .iOS)?.title == "Stop requested 13:20. No new steps will start.")
        let actor = RunLane.state(run: F.run(.running, hold: .actor), steps: [], artifacts: [])
        #expect(laneText(actor, platform: .macOS)?.subtitle == "Run with AI isn't available for this account.")
        #expect(laneText(actor, platform: .iOS)?.subtitle == "New steps are paused for now.")
        let credit = RunLane.state(run: F.run(.running, hold: .credit), steps: [], artifacts: [F.draft(1)])
        #expect(laneText(credit, platform: .macOS) == laneText(credit, platform: .iOS))
    }

    /// Mac 액션 바 `Stop requested 14:20` (M17, 서버 `stopped_at`이 없으면 없음) · 상태가 바뀔 때 낭독
    @Test func macStopBarAndAnnouncements() {
        let at = F.start.addingTimeInterval(1_200)
        let stopped = RunLane.state(run: F.run(.stopped, stoppedAt: at), steps: [], artifacts: [])
        #expect(RunLaneText.stopRequested(stopped, now: now, timeZone: seoul) == "Stop requested 13:20")
        #expect(RunLaneText.stopRequested(RunLane.state(run: F.run(.stopped), steps: [], artifacts: []), now: now, timeZone: seoul) == nil)
        #expect(RunLaneText.stopRequested(RunLane.state(run: F.run(.running), steps: [], artifacts: []), now: now, timeZone: seoul) == nil)
        #expect(RunLaneText.announcement(.draftReady) == "Draft ready")
        #expect(RunLaneText.announcement(.stopped(finishing: false, stoppedAt: at)) == "Stop requested")
        #expect(RunLaneText.announcement(.stopped(finishing: true, stoppedAt: nil)) == "Stopped")
        #expect(RunLaneText.announcement(.working) == nil)
    }

    /// 오늘은 시각만 (P9 `Stop requested 14:20.`, 상태 줄과 같은 "8:01" 모양), 그 전은 날짜 (Mac 갈래와 같다)
    @Test func clock() {
        #expect(RunLaneText.clock(F.start, now: now, timeZone: seoul) == "13:00")
        #expect(RunLaneText.clock(F.start.addingTimeInterval(-5 * 3_600), now: now, timeZone: seoul) == "8:00")
        #expect(RunLaneText.clock(F.start.addingTimeInterval(-86_400), now: now, timeZone: seoul) == "Oct 2")
        #expect(RunLaneText.clock(F.start.addingTimeInterval(-86_400 * 5), now: now, timeZone: seoul) == "Sep 28")
        // 오늘이 아닌 멈춤은 날짜로 ("Stop requested Oct 2. No new steps will start.")
        let lane = RunLane.state(run: F.run(.stopped, stoppedAt: F.start.addingTimeInterval(-86_400)), steps: [], artifacts: [])
        #expect(laneText(lane)?.title == "Stop requested Oct 2. No new steps will start.")
    }
}

/// iPhone 상세의 원문: 실행 receipt(초안 저장 기록)는 원문 슬립 · `Open in <서비스>` · Show All에서 뺀다 (초안은 갈래 `View Draft`)
struct ReceiptLinesTests {
    @Test func receiptsAreNotSourceLines() {
        let notion = UUID()
        let receipt = UUID()
        let original = EvidenceLine(
            id: UUID(), quote: "금요일 데모는 제가 준비할게요.", sourceID: notion, sourceTitle: "제품 회의록", occurredAt: Date(timeIntervalSince1970: 100),
            externalURL: URL(string: "https://www.notion.so/sample"), service: .notion
        )
        let saved = EvidenceLine(
            id: UUID(), quote: "초안 저장: 데모 예상 질문", sourceID: receipt, sourceTitle: "초안", occurredAt: Date(timeIntervalSince1970: 200),
            externalURL: URL(string: "taskforce://artifacts/77777777-7777-4777-8777-777777777777"), service: .manual(.execution)
        )
        // receipt가 가장 최근 근거여도 맨 앞 · 여는 링크는 원문
        let digest = EvidenceDigest(lines: [original, saved])
        #expect(digest.lead?.sourceID == receipt)
        let sources = digest.withoutReceipts
        #expect(sources.lines.map(\.sourceID) == [notion])
        #expect(sources.lead?.sourceID == notion)
        #expect(sources.openLink?.service == .notion)
        #expect(EvidenceDigest(lines: [saved]).withoutReceipts.isEmpty)
    }

    /// 근거에서 만든 줄은 들어온 순서 그대로 둔다 (다시 줄 세우지 않는다): 원문 시각이 늦어도 먼저 들어온 근거가 위
    @Test func keepsArrivalOrder() throws {
        let rows = """
        [{"id": "22222222-2222-4222-8222-000000000001", "kind": "doc", "title": "늦게 쓴 문서", "occurred_at": "2026-09-30T00:00:00+00:00",
          "external_url": "https://www.notion.so/a", "created_at": "2026-09-30T00:00:00+00:00", "processing_status": "done"},
         {"id": "22222222-2222-4222-8222-000000000002", "kind": "doc", "title": "먼저 쓴 문서", "occurred_at": "2026-09-01T00:00:00+00:00",
          "external_url": "https://www.notion.so/b", "created_at": "2026-09-01T00:00:00+00:00", "processing_status": "done"}]
        """
        let decoded = try TaskforceJSON.decoder().decode([SourceSummary].self, from: Data(rows.utf8))
        let sources = Dictionary(uniqueKeysWithValues: decoded.map { ($0.id, $0) })
        func record(_ source: SourceSummary, _ quote: String, at seconds: TimeInterval) -> EvidenceRecord {
            EvidenceRecord(id: UUID(), actionID: UUID(), sourceID: source.id, quote: quote, role: .created, createdAt: Date(timeIntervalSince1970: seconds))
        }
        // 늦게 쓴 문서의 근거가 먼저 들어왔다
        let evidence = [record(decoded[0], "먼저 들어온 근거", at: 1_000), record(decoded[1], "나중에 들어온 근거", at: 2_000)]
        let digest = EvidenceDigest(evidence: evidence, sources: sources)
        #expect(digest.withoutReceipts.lines.map(\.quote) == digest.lines.map(\.quote))
        #expect(digest.withoutReceipts.lead?.quote == digest.lead?.quote)
    }
}
