import Foundation
import Testing
@testable import TaskforceKit

struct ModelDecodingTests {
    func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try TaskforceJSON.decoder().decode(T.self, from: Data(json.utf8))
    }

    @Test func decodesNowResponseInServerOrder() throws {
        let now = try decode(NowResponse.self, Fixtures.nowWithWeeklyCheck)
        #expect(now.now.map(\.action.title) == ["투자 자료 보내기", "계약서 검토"])
        let first = try #require(now.now.first)
        #expect(first.action.id == Fixtures.actionID)
        #expect(first.action.dueDate == LocalDate("2026-09-29"))
        #expect(first.action.counterpart == "김대표")
        #expect(first.action.startedAt != nil)
        #expect(first.score == 97.5)
        #expect(first.daysUntilDue == 2)
        // 모르는 이유는 버린다
        #expect(first.reasons == [.dueSoon, .external, .started])

        #expect(now.now[1].action.dueDate == nil)
        #expect(now.now[1].action.owner == .unknown)
        #expect(now.now[1].daysUntilDue == nil)

        let confirmation = try #require(now.confirmations.first)
        #expect(confirmation.needsConfirmation)
        #expect(confirmation.confirmReasons == ["담당 확인", "기한 확인"])
        #expect(now.weeklyCheck == WeeklyCheckPrompt(weekStart: LocalDate(year: 2026, month: 9, day: 21)!))
    }

    @Test(arguments: [Fixtures.nowOlderServer, Fixtures.nowNullWeeklyCheck])
    func weeklyCheckIsOptional(_ json: String) throws {
        let now = try decode(NowResponse.self, json)
        #expect(now.weeklyCheck == nil)
        #expect(now.now.isEmpty)
    }

    @Test func decodesMissingReport() throws {
        let created = try decode(MissingReportResponse.self, Fixtures.missingCreated)
        #expect(created.status == .created)
        #expect(created.stage == .judgeRejected)
        #expect(created.action.id == Fixtures.actionID)

        let tracked = try decode(MissingReportResponse.self, Fixtures.missingAlreadyTracked)
        #expect(tracked.status == .alreadyTracked)
        #expect(tracked.stage == nil)
    }

    @Test func decodesHandoff() throws {
        let handoff = try decode(HandoffResponse.self, Fixtures.handoff)
        #expect(handoff.actionID == Fixtures.actionID)
        #expect(handoff.markdown.hasPrefix("# 투자 자료 보내기\n"))
    }

    @Test func decodesEventRowsWithJSONB() throws {
        let events = try decode([ActionEventRecord].self, Fixtures.eventRows)
        #expect(events[0].type == "due_changed")
        #expect(events[0].before?["due"]?.stringValue == "2026-09-25")
        #expect(events[0].sourceID == Fixtures.sourceID)
        #expect(events[0].actor == .ai)
        #expect(events[1].sourceID == nil)
        #expect(events[1].after?["confirm_reasons"] == .array([]))
    }

    @Test func decodesSourceRow() throws {
        let rows = try decode([SourceRecord].self, Fixtures.sourceRow)
        let source = try #require(rows.first)
        #expect(source.summary.kind == .meeting)
        #expect(source.summary.processingStatus == .done)
        #expect(source.summary.externalURL?.host == "www.notion.so")
        #expect(source.rawText.contains("\n"))
        // meeting 열이 없는 응답(옛 행 모양)도 읽는다
        #expect(source.summary.meeting == nil)
    }

    @Test func sourceColumnsReadMeeting() {
        #expect(SourceSummary.columns.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.contains("meeting"))
        #expect(SourceRecord.columns.hasPrefix(SourceSummary.columns))
    }

    @Test func decodesSourceMeeting() throws {
        let rows = try decode([SourceSummary].self, Fixtures.sourceRowsWithMeeting)
        #expect(rows.count == 5)

        let meeting = try #require(rows[0].meeting)
        #expect(meeting.calendarEventID == "evt-1")
        #expect(meeting.title == "Proposal review — Acme")
        #expect(meeting.start == Date(timeIntervalSince1970: 1_790_730_000)) // 2026-09-30T01:00:00Z
        #expect(meeting.end == meeting.start.addingTimeInterval(3_600))

        // null · 열 없음 → 일정 없음
        #expect(rows[1].meeting == nil)
        #expect(rows[2].meeting == nil)
        // 모양이 어긋난 일정(시각 없음)은 버리고 원문은 읽는다
        #expect(rows[3].meeting == nil)
        #expect(rows[3].title == "주간 회의")
        // 빈 제목은 없는 것으로
        #expect(rows[4].meeting?.calendarEventID == "evt-3")
        #expect(rows[4].meeting?.title == nil)
    }

    @Test func encodesEditWithExplicitNullDue() throws {
        let data = try TaskforceJSON.encoder().encode(ActionEdit(due: .clear, owner: .me))
        #expect(String(decoding: data, as: UTF8.self) == #"{"due_date":null,"owner":"me"}"#)

        let set = try TaskforceJSON.encoder().encode(ActionEdit(title: "새 제목", due: .set(LocalDate("2026-10-02")!)))
        #expect(String(decoding: set, as: UTF8.self) == #"{"due_date":"2026-10-02","title":"새 제목"}"#)

        let status = try TaskforceJSON.encoder().encode(ActionEdit(status: .done))
        #expect(String(decoding: status, as: UTF8.self) == #"{"status":"done"}"#)
    }
}

struct ActionEditChangesTests {
    let current = (title: "자료 보내기", due: LocalDate("2026-09-29"), owner: ActionOwner.unknown)

    @Test func nothingChanged() {
        #expect(ActionEdit.changes(title: " 자료 보내기 ", due: LocalDate("2026-09-29"), owner: nil, from: current).isEmpty)
        #expect(ActionEdit.changes(title: "자료 보내기", due: LocalDate("2026-09-29"), owner: .unknown, from: current).isEmpty)
    }

    @Test func onlyChangedFields() {
        let edit = ActionEdit.changes(title: "IR 자료 보내기", due: nil, owner: .me, from: current)
        #expect(edit == ActionEdit(title: "IR 자료 보내기", due: .clear, owner: .me))
        #expect(ActionEdit.changes(title: "자료 보내기", due: LocalDate("2026-10-02"), owner: nil, from: current) == ActionEdit(due: .set(LocalDate("2026-10-02")!)))
    }

    @Test func blankTitleIsIgnored() {
        #expect(ActionEdit.changes(title: "   ", due: LocalDate("2026-09-29"), owner: .other, from: current) == ActionEdit(owner: .other))
    }
}

struct TimestampTests {
    let expected = Date(timeIntervalSince1970: 1_790_470_923) // 2026-09-27T01:02:03Z

    @Test(arguments: [
        "2026-09-27T01:02:03Z",
        "2026-09-27T01:02:03+00:00",
        "2026-09-27T01:02:03+00",
        "2026-09-27 01:02:03+00",
        "2026-09-27T10:02:03+09:00",
        "2026-09-26T20:02:03-0500",
        "2026-09-27T01:02:03",
    ])
    func parsesVariants(_ string: String) throws {
        #expect(try #require(PostgresTimestamp.parse(string)) == expected)
    }

    @Test func keepsMicroseconds() throws {
        let date = try #require(PostgresTimestamp.parse("2026-09-27T01:02:03.123456+00:00"))
        #expect(abs(date.timeIntervalSince(expected) - 0.123456) < 0.000_01)
    }

    @Test(arguments: ["", "2026-09-27", "2026-13-01T00:00:00Z", "yesterday", "2026-09-27T01:02:03+0"])
    func rejectsGarbage(_ string: String) {
        #expect(PostgresTimestamp.parse(string) == nil)
    }

    @Test func localDate() throws {
        let date = try #require(LocalDate("2026-09-29"))
        #expect(date.description == "2026-09-29")
        #expect(date.weekday == 3) // 화요일
        #expect(LocalDate("2026-02-30") == nil)
        #expect(LocalDate("2026-9-29") == nil)
        #expect(date.adding(days: 3) == LocalDate("2026-10-02"))
        #expect(date.days(since: LocalDate("2026-09-27")!) == 2)
    }

    @Test func localDateFromInstantUsesTimeZone() {
        // 2026-09-27 16:00 UTC = 2026-09-28 01:00 KST
        let instant = Date(timeIntervalSince1970: 1_790_524_800)
        #expect(LocalDate(date: instant, timeZone: DueDateFormat.seoul) == LocalDate("2026-09-28"))
        #expect(LocalDate(date: instant, timeZone: TimeZone(secondsFromGMT: 0)!) == LocalDate("2026-09-27"))
    }
}
