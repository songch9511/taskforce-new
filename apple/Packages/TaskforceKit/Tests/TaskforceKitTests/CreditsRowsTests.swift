import Foundation
import Testing
@testable import TaskforceKit

/// S3 Usage & Credits 행 (Figma 240:1907)
struct CreditsRowsTests {
    typealias F = RunFixture
    let seoul = TimeZone(identifier: "Asia/Seoul")!
    /// 2026-10-04 16:10 (서울)
    var now: Date { PostgresTimestamp.parse("2026-10-04T07:10:00Z")! }
    let qa = UUID(uuidString: "aaaaaaaa-0000-4000-8000-000000000020")!
    let script = UUID(uuidString: "aaaaaaaa-0000-4000-8000-000000000021")!
    var titles: [UUID: String] { [qa: "QA 시나리오 업데이트", script: "데모 스크립트 초안", F.action: "Follow-up 2 to 지훈"] }

    /// Figma 값: Available 0 · Reserved 12 · Pending Unknown · 멈춘 2건 · Used 188
    @Test func figmaValues() {
        let credits = CreditsSummary(
            available: 0, reserved: 32, runningRuns: 1, settling: .init(steps: 1, reserved: 20, actionIDs: [F.action]),
            used: .init(credits: 188, since: CreditsMonth.start(of: now, timeZone: seoul))
        )
        let paused = [F.run(1, .running, hold: .credit, action: qa, minutes: 5), F.run(2, .queued, hold: .credit, action: script, minutes: 1)]
        let rows = CreditsRows.make(credits: credits, loadFailed: false, checkedAt: now, pausedRuns: paused, titles: titles, now: now, timeZone: seoul)
        #expect(rows.available == .init(title: "Available", value: "0", subtitle: "Checked 16:10", isEmphasized: true))
        #expect(rows.reserved == .init(title: "Reserved", value: "12", subtitle: "Held for 1 running task until it finishes"))
        #expect(rows.pending == .init(title: "Pending", value: "Unknown", subtitle: "Follow-up 2 to 지훈 is still being checked"))
        #expect(rows.paused == .init(
            title: "2 AI drafts are paused", subtitle: "QA 시나리오 업데이트, 데모 스크립트 초안. They continue when credits are added."
        ))
        #expect(rows.used == .init(title: "Used", value: "188", subtitle: "Oct 1 – Oct 4"))
        #expect(rows.included == .init(title: "Included in your plan", value: "Not set yet", subtitle: "Pricing is not decided for the beta"))
        #expect(rows.notice == nil)
        #expect(rows.limitNotice == nil)
    }

    @Test func closedRunGateExplainsUnavailableDraftsWithoutSettingPrice() {
        let credits = CreditsSummary(available: 12, reserved: 0, acceptingRuns: false)
        let rows = CreditsRows.make(credits: credits, loadFailed: false, checkedAt: now, pausedRuns: [], titles: [:], now: now, timeZone: seoul)

        #expect(rows.limitNotice == "New AI drafts are temporarily unavailable.")
        #expect(rows.notice == nil)
        #expect(rows.included == .init(title: "Included in your plan", value: "Not set yet", subtitle: "Pricing is not decided for the beta"))
    }

    /// 그 전 서버 (세 필드만): Reserved는 예약 그대로(진행 중 run 수를 몰라 수 없이), Pending · 카드 없음, Used는 "—"
    @Test func beforeServerPR1() {
        let rows = CreditsRows.make(
            credits: CreditsSummary(available: 480, reserved: 20), loadFailed: false, checkedAt: now, pausedRuns: [], titles: [:], now: now,
            timeZone: seoul
        )
        #expect(rows.available.value == "480")
        #expect(rows.reserved == .init(title: "Reserved", value: "20", subtitle: "Held until running tasks finish"))
        #expect(rows.pending == nil)
        #expect(rows.paused == nil)
        #expect(rows.used.value == "—")
        #expect(rows.used.subtitle == "Oct 1 – Oct 4")
    }

    /// 값을 한 번도 받지 못했는데 실패: "—"와 한 줄 (빈 페이지 금지). 받는 중이면 한 줄 없이 "—"
    @Test func notLoaded() {
        let failed = CreditsRows.make(credits: nil, loadFailed: true, checkedAt: nil, pausedRuns: [], titles: [:], now: now, timeZone: seoul)
        #expect(failed.available == .init(title: "Available", value: "—", subtitle: nil, isEmphasized: true))
        #expect(failed.reserved.value == "—")
        #expect(failed.reserved.subtitle == nil)
        #expect(failed.used.value == "—")
        #expect(failed.notice == "Couldn't load credits.")
        #expect(CreditsRows.make(credits: nil, loadFailed: false, checkedAt: nil, pausedRuns: [], titles: [:], now: now, timeZone: seoul).notice == nil)
    }

    /// 앞 값이 있으면 실패해도 그 값 그대로 (Checked 시각이 오래된 값임을 알린다)
    @Test func keepsLastValueOnFailure() {
        let checked = now.addingTimeInterval(-3_600)
        let rows = CreditsRows.make(
            credits: CreditsSummary(available: 7, reserved: 0), loadFailed: true, checkedAt: checked, pausedRuns: [], titles: [:], now: now,
            timeZone: seoul
        )
        #expect(rows.available.value == "7")
        #expect(rows.available.subtitle == "Checked 15:10")
        #expect(rows.notice == nil)
    }

    @Test(arguments: [
        (0, 0, "Nothing held right now"), (1, 20, "Held for 1 running task until it finishes"), (3, 60, "Held for 3 running tasks until they finish"),
        (0, 20, "Held until running tasks finish"),
    ])
    func heldText(_ runs: Int, _ held: Int, _ text: String) {
        #expect(CreditsRows.heldText(runs: runs, held: held) == text)
    }

    @Test func checkingText() {
        #expect(CreditsRows.checkingText([], titles: titles) == "Still being checked")
        #expect(CreditsRows.checkingText([qa], titles: titles) == "QA 시나리오 업데이트 is still being checked")
        #expect(CreditsRows.checkingText([qa, qa], titles: titles) == "QA 시나리오 업데이트 is still being checked")
        #expect(CreditsRows.checkingText([UUID()], titles: titles) == "1 task is still being checked")
        #expect(CreditsRows.checkingText([qa, script], titles: titles) == "2 tasks are still being checked")
    }

    @Test func pausedCard() {
        #expect(CreditsRows.pausedCard([], titles: titles) == nil)
        // 끝난 run · 크레딧 밖의 이유는 세지 않는다
        #expect(CreditsRows.pausedCard([F.run(.stopped, hold: .credit), F.run(2, .running, hold: .actor)], titles: titles) == nil)
        let one = CreditsRows.pausedCard([F.run(.running, hold: .credit, action: qa)], titles: titles)
        #expect(one == .init(title: "1 AI draft is paused", subtitle: "QA 시나리오 업데이트. They continue when credits are added."))
        let unknown = CreditsRows.pausedCard([F.run(.running, hold: .credit, action: UUID())], titles: titles)
        #expect(unknown?.subtitle == "They continue when credits are added.")
    }

    @Test func monthStartAndRange() {
        #expect(CreditsMonth.start(of: now, timeZone: seoul) == PostgresTimestamp.parse("2026-09-30T15:00:00Z"))
        #expect(CreditsMonth.start(of: now, timeZone: TimeZone(secondsFromGMT: 0)!) == PostgresTimestamp.parse("2026-10-01T00:00:00Z"))
        let first = CreditsMonth.start(of: now, timeZone: seoul)
        #expect(CreditsRows.range(from: first, to: first, timeZone: seoul) == "Oct 1")
        #expect(CreditsRows.range(from: first, to: now, timeZone: seoul) == "Oct 1 – Oct 4")
    }

    @Test func clock() {
        let morning = PostgresTimestamp.parse("2026-10-03T23:01:00Z")!
        #expect(CreditsRows.clock(morning, timeZone: seoul) == "8:01")
    }
}

/// M8 `Use` 칩: 서버 `context.ts`와 같은 거르기 · 순서 · 수 (같은 fixture: `context.test.ts`)
struct DraftSourcesTests {
    let base = Date(timeIntervalSince1970: 1_791_000_000)

    func source(_ n: Int, kind: SourceKind = .email, title: String? = nil, url: String? = "https://mail.google.com/mail/u/0/#inbox/\(UUID())") -> SourceSummary {
        let row: [String: Any] = [
            "id": id(n).uuidString, "kind": kind.rawValue, "title": title ?? "원문 \(n)", "occurred_at": "2026-10-01T01:00:00Z",
            "external_url": url ?? NSNull(), "created_at": "2026-10-01T01:00:00Z", "processing_status": "done", "meeting": NSNull(),
        ]
        let data = try! JSONSerialization.data(withJSONObject: row)
        return try! TaskforceJSON.decoder().decode(SourceSummary.self, from: data)
    }

    func evidence(_ n: Int, source: Int, quote: String = "근거 구절", role: EvidenceRole = .created, minutes: Double) -> EvidenceRecord {
        EvidenceRecord(id: id(100 + n), actionID: RunFixture.action, sourceID: id(source), quote: quote, role: role, createdAt: base.addingTimeInterval(minutes * 60))
    }

    func id(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "dddddddd-0000-4000-8000-%012d", n))!
    }

    func table(_ sources: [SourceSummary]) -> [UUID: SourceSummary] {
        Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
    }

    /// `context.test.ts` "원문 수 상한을 넘은 원문은 빼고 센다": 8개 → 6개
    @Test func capsAtSixSources() {
        let sources = (0..<8).map { source($0) }
        let evidence = (0..<8).map { self.evidence($0, source: $0, minutes: Double($0)) }
        let chips = DraftSources.make(evidence: evidence, sources: table(sources))
        #expect(chips.count == DraftSources.limit)
        #expect(DraftSources.limit == 6)
        // 최근 근거부터
        #expect(chips.map(\.id) == [7, 6, 5, 4, 3, 2].map(id))
    }

    /// `context.test.ts` "Slack 원문의 인용 · 본문 · 관련자는 하나도 넣지 않는다" + 실행 receipt
    @Test func dropsSlackRemovedQuotesAndReceipts() {
        let mail = source(1, title: "일정 변경 요청")
        let slack = source(2, kind: .message, title: "#제작팀", url: "https://acme.slack.com/archives/C1/p1")
        let purged = source(3, kind: .message, title: "Slack", url: nil)
        let receipt = source(4, kind: .execution, title: "일정 변경 회신", url: "taskforce://artifacts/a1")
        let evidence = [
            self.evidence(1, source: 1, quote: "납품일을 10월 16일로 미룰 수 있을까요?", minutes: 1),
            self.evidence(2, source: 2, quote: "일정 변경은 제가 회신할게요", minutes: 2),
            self.evidence(3, source: 3, quote: RemovedQuote.slackDisconnected, minutes: 3),
            self.evidence(4, source: 4, quote: "초안 저장: 일정 변경 회신", role: .executed, minutes: 4),
            self.evidence(5, source: 4, quote: "초안 저장: 일정 변경 회신", minutes: 5),
            // 원문을 찾을 수 없는 근거 (서버도 뺀다)
            self.evidence(6, source: 99, minutes: 6),
            self.evidence(7, source: 1, quote: "", minutes: 7),
        ]
        let chips = DraftSources.make(evidence: evidence, sources: table([mail, slack, purged, receipt]))
        #expect(chips == [DraftSource(id: id(1), title: "일정 변경 요청", service: .gmail)])
    }

    /// 서버처럼 receipt가 아닌 근거 중 최근 40개만 본다 (receipt 근거가 많아도 원문 근거 자리를 빼앗지 않는다)
    @Test func readsTheLatestFortyNonReceiptEvidence() {
        let old = source(1, title: "오래된 메일")
        let receipt = source(2, kind: .execution, title: "초안", url: "taskforce://artifacts/a1")
        let recent = source(3, title: "최근 메일")
        var evidence = [self.evidence(0, source: 1, minutes: 0)]
        evidence += (1...40).map { self.evidence($0, source: 3, quote: "구절 \($0)", minutes: Double($0)) }
        evidence += (41...90).map { self.evidence($0, source: 2, quote: "초안 저장: 초안", role: .executed, minutes: Double($0)) }
        let chips = DraftSources.make(evidence: evidence, sources: table([old, receipt, recent]))
        #expect(chips.map(\.id) == [id(3)])
    }

    /// 같은 원문은 한 번 (가장 최근 근거의 자리), 이름이 없으면 종류 이름
    @Test func oneChipPerSource() {
        let notes = source(1, kind: .meeting, title: "제품 회의록", url: "https://www.notion.so/meeting")
        let memo = source(2, kind: .note, title: "  ", url: nil)
        let evidence = [
            self.evidence(1, source: 1, minutes: 1), self.evidence(2, source: 2, minutes: 2), self.evidence(3, source: 1, quote: "다른 구절", minutes: 3),
        ]
        let chips = DraftSources.make(evidence: evidence, sources: table([notes, memo]))
        #expect(chips == [
            DraftSource(id: id(1), title: "제품 회의록", service: .notion),
            DraftSource(id: id(2), title: "Note", service: .manual(.note)),
        ])
    }
}
