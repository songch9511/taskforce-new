import Foundation
import Testing
@testable import TaskforceKit

struct SourceStackTests {
    @Test(arguments: [
        ("https://www.notion.so/abc", SourceKind.meeting, SourceService.notion),
        ("https://acme.notion.site/abc", .doc, .notion),
        ("https://acme.slack.com/archives/C1/p123", .message, .slack),
        ("https://mail.google.com/mail/u/0/#inbox/abc", .email, .gmail),
        // 서버가 Gmail 원문에 붙이는 링크 (lib/connectors/gmail/message.ts gmailThreadUrl)
        ("https://mail.google.com/mail/?authuser=me%40company.dev#all/18c2f0a1b2c3d4e5", .email, .gmail),
        ("https://meet.google.com/abc-defg-hij", .meeting, .googleMeet),
        ("https://docs.google.com/document/d/abc", .meeting, .googleMeet),
        ("https://docs.google.com/document/d/abc", .doc, .manual(.doc)),
        ("https://example.com/x", .note, .manual(.note)),
        ("https://notnotion.so/x", .note, .manual(.note)),
    ])
    func infersServiceFromLink(_ url: String, _ kind: SourceKind, _ expected: SourceService) {
        #expect(SourceService.infer(externalURL: URL(string: url), kind: kind) == expected)
    }

    @Test func noLinkIsManual() {
        #expect(SourceService.infer(externalURL: nil, kind: .email) == .manual(.email))
    }

    @Test func mediumStackShowsEachServiceOnce() {
        #expect(SourceStackLayout.medium([.notion, .slack, .notion]) == .init(icons: [.notion, .slack], more: 0))
        #expect(SourceStackLayout.medium([.notion, .slack, .gmail]) == .init(icons: [.notion, .slack, .gmail], more: 0))
    }

    @Test func mediumStackCollapsesFourOrMore() {
        let result = SourceStackLayout.medium([.notion, .slack, .gmail, .googleMeet, .manual(.note), .notion])
        #expect(result == .init(icons: [.notion, .slack, .gmail], more: 2))
    }

    @Test func smallStackCountsEveryOtherSource() {
        #expect(SourceStackLayout.small(others: []) == .init(icons: [], more: 0))
        #expect(SourceStackLayout.small(others: [.slack]) == .init(icons: [.slack], more: 0))
        #expect(SourceStackLayout.small(others: [.slack, .gmail]) == .init(icons: [.slack, .gmail], more: 0))
        // 외 5곳 = 아이콘 2 + "+3"
        #expect(SourceStackLayout.small(others: [.slack, .gmail, .notion, .slack, .googleMeet]) == .init(icons: [.slack, .gmail], more: 3))
        // 같은 서비스 두 곳: 아이콘 하나 + "+1"
        #expect(SourceStackLayout.small(others: [.notion, .notion]) == .init(icons: [.notion], more: 1))
    }

    // MARK: 근거 고르기

    func evidence(_ id: Int, source: UUID, quote: String, at seconds: TimeInterval) -> EvidenceRecord {
        EvidenceRecord(
            id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", id))!,
            actionID: Fixtures.actionID,
            sourceID: source,
            quote: quote,
            role: .created,
            createdAt: Date(timeIntervalSince1970: seconds)
        )
    }

    @Test func digestLeadsWithNewestAndListsOldestFirst() throws {
        let notionSource = try TaskforceJSON.decoder().decode([SourceSummary].self, from: Data(Fixtures.sourceRow.utf8))[0]
        let slackID = UUID()
        let manualID = UUID()
        let digest = EvidenceDigest(
            evidence: [
                evidence(3, source: slackID, quote: "월요일도 괜찮아요", at: 300),
                evidence(1, source: notionSource.id, quote: "금요일까지 보낼게요", at: 100),
                evidence(2, source: notionSource.id, quote: "금요일까지 보낼게요", at: 200),
                evidence(4, source: manualID, quote: "다음 주로", at: 400),
            ],
            sources: [notionSource.id: notionSource]
        )
        // 같은 원문 같은 구절은 한 번
        #expect(digest.lines.map(\.quote) == ["금요일까지 보낼게요", "월요일도 괜찮아요", "다음 주로"])
        #expect(digest.lines[0].service == .notion)
        #expect(digest.lines[0].sourceTitle == "주간 회의")
        #expect(digest.lead?.quote == "다음 주로")
        // 맨 앞 근거의 원문을 뺀 나머지, 처음 들어온 순서
        #expect(digest.otherSources == [.notion, .manual(.note)])
    }

    @Test func emptyDigest() {
        let digest = EvidenceDigest(evidence: [], sources: [:])
        #expect(digest.isEmpty && digest.lead == nil && digest.otherSources.isEmpty)
    }

    // MARK: 일정이 붙은 회의 원문 (google-integration.md 3장 근거 줄 · Sources)

    /// Notion 회의록(evt-1) · Meet 전사(일정 없음) · Slack · 제목 없는 일정(evt-3)
    func meetingSources() throws -> [UUID: SourceSummary] {
        let rows = try TaskforceJSON.decoder().decode([SourceSummary].self, from: Data(Fixtures.sourceRowsWithMeeting.utf8))
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
    }

    @Test func evidenceLineShowsMeetingTitleAndDate() throws {
        let sources = try meetingSources()
        let notion = UUID(uuidString: "33333333-3333-4333-8333-000000000001")!
        let slack = UUID(uuidString: "33333333-3333-4333-8333-000000000003")!
        let untitled = UUID(uuidString: "33333333-3333-4333-8333-000000000005")!
        // 근거가 들어온 순서: 제목 없는 일정 → Notion 회의록 → Slack (원문 시점 · 일정 시작 순서와 모두 다르다)
        let digest = EvidenceDigest(
            evidence: [
                evidence(1, source: untitled, quote: "다음 주로", at: 100),
                evidence(2, source: notion, quote: "I'll send the revised proposal by Friday", at: 200),
                evidence(3, source: slack, quote: "Wednesday works too", at: 300),
            ],
            sources: sources
        )
        // 순서는 그대로 근거가 들어온 순서 (일정 시작으로 다시 줄 세우지 않는다)
        #expect(digest.lines.map(\.sourceID) == [untitled, notion, slack])
        #expect(digest.lead?.sourceID == slack)

        // 회의록은 다음 날 만들어졌지만(Oct 1) When은 일정 시작 (Sep 30)
        let meetingLine = digest.lines[1]
        #expect(meetingLine.meeting?.calendarEventID == "evt-1")
        #expect(meetingLine.displayTitle == "Proposal review — Acme")
        #expect(meetingLine.displayDate == sources[notion]?.meeting?.start)
        #expect(meetingLine.displayDate != meetingLine.occurredAt)
        // "Sep 30 · Proposal review — Acme"
        let utc = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_790_730_000 + 5 * 86_400)
        #expect(WhenText.label(try #require(meetingLine.displayDate), now: now, timeZone: utc) == "Sep 30")
        #expect(WhenText.label(try #require(meetingLine.occurredAt), now: now, timeZone: utc) == "Oct 1")

        // 일정이 없으면 원문 그대로
        let slackLine = digest.lines[2]
        #expect(slackLine.meeting == nil)
        #expect(slackLine.displayTitle == "#sales")
        #expect(slackLine.displayDate == sources[slack]?.occurredAt)

        // 제목 없는 일정: 날짜는 일정 시작(05:00, 원문은 05:20), 이름은 원문 제목
        #expect(digest.lines[0].displayTitle == "주간 회의")
        #expect(digest.lines[0].displayDate == sources[untitled]?.meeting?.start)
        #expect(digest.lines[0].displayDate != sources[untitled]?.occurredAt)
    }

    func line(_ n: Int, meeting eventID: String?) -> EvidenceLine {
        EvidenceLine(
            id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))!, quote: "q\(n)", sourceID: UUID(), sourceTitle: nil,
            occurredAt: Date(timeIntervalSince1970: Double(n)), externalURL: nil, service: .notion,
            meeting: eventID.map { SourceMeeting(calendarEventID: $0, title: "M", start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 60)) }
        )
    }

    @Test func sourcesGroupSameMeetingTogether() {
        // Notion 회의록(evt-1) · Slack · Meet 전사(evt-1) · 다른 회의(evt-2) · 메일
        let lines = [line(1, meeting: "evt-1"), line(2, meeting: nil), line(3, meeting: "evt-1"), line(4, meeting: "evt-2"), line(5, meeting: nil)]
        let groups = EvidenceGroup.grouped(lines)
        // 같은 회의는 처음 나온 자리에 모으고, 나머지 순서는 그대로
        #expect(groups.map { $0.lines.map(\.quote) } == [["q1", "q3"], ["q2"], ["q4"], ["q5"]])
        #expect(groups[0].meeting?.calendarEventID == "evt-1")
        #expect(groups[1].meeting == nil)
        #expect(groups.map(\.id) == [lines[0].id, lines[1].id, lines[3].id, lines[4].id])
    }

    @Test func sourcesWithoutMeetingStayOnePerLine() {
        let lines = [line(1, meeting: nil), line(2, meeting: nil)]
        #expect(EvidenceGroup.grouped(lines).map(\.lines.count) == [1, 1])
        #expect(EvidenceGroup.grouped([]).isEmpty)
    }
}
