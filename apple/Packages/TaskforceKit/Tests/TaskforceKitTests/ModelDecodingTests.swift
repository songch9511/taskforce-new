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

    @Test func actionRecordNotesDefaultForOlderRowsAndDecodeWhenPresent() throws {
        let legacy = try decode(ActionRecord.self, """
            {"id":"11111111-1111-4111-8111-111111111111","title":"자료 보내기","scope_summary":null,"owner":"me",
             "counterpart":null,"due_date":null,"status":"open","needs_confirmation":false,"confirm_reasons":[],
             "started_at":null,"last_activity_at":"2026-10-07T00:00:00Z","created_at":"2026-10-01T00:00:00Z"}
            """)
        #expect(legacy.notesMarkdown.isEmpty)
        #expect(legacy.notesRevision == 0)

        let current = try decode(ActionRecord.self, """
            {"id":"11111111-1111-4111-8111-111111111111","title":"자료 보내기","scope_summary":null,"owner":"me",
             "counterpart":null,"due_date":null,"status":"open","needs_confirmation":false,"confirm_reasons":[],
             "started_at":null,"last_activity_at":"2026-10-07T00:00:00Z","created_at":"2026-10-01T00:00:00Z",
             "notes_markdown":"## 다음 단계\\n- [ ] 자료 보내기","notes_revision":6}
            """)
        #expect(current.notesMarkdown == "## 다음 단계\n- [ ] 자료 보내기")
        #expect(current.notesRevision == 6)
    }

    @Test(arguments: [Fixtures.nowOlderServer, Fixtures.nowNullWeeklyCheck])
    func weeklyCheckIsOptional(_ json: String) throws {
        let now = try decode(NowResponse.self, json)
        #expect(now.weeklyCheck == nil)
        #expect(now.now.isEmpty)
    }

    /// U1 PR2 서버(항목의 `changed`, `section_limits`, `failed_sources`)를 지금 앱 모델이 그대로 읽는다: 새 필드는 무시하고 순서 · 값은 같다
    @Test func decodesU1ServerNowWithTodayModel() throws {
        let item = { (id: String, title: String, changed: Bool) in
            """
            { "id": "\(id)", "title": "\(title)", "owner": "me", "status": "open", "due_date": null, "counterpart": null,
              "needs_confirmation": false, "confirm_reasons": [], "started_at": null,
              "last_activity_at": "2026-10-02T09:00:00.000Z", "score": 42, "reasons": ["neglected"], "days_until_due": null,
              "changed": \(changed) }
            """
        }
        let now = try decode(NowResponse.self, """
            { "now": [\(item("11111111-1111-4111-8111-111111111111", "투자 자료 보내기", true)),
                      \(item("33333333-3333-4333-8333-333333333333", "계약서 검토", false))],
              "confirmations": [\(item("44444444-4444-4444-8444-444444444444", "견적서 회신", true))],
              "weekly_check": null,
              "failed_sources": { "count": 0, "latest_at": null, "reason": null },
              "section_limits": { "review": 2, "in_progress": 5, "to_do": 5 } }
            """)
        #expect(now.now.map(\.action.title) == ["투자 자료 보내기", "계약서 검토"])
        #expect(now.now.map(\.score) == [42, 42])
        #expect(now.confirmations.map(\.title) == ["견적서 회신"])
        #expect(now.weeklyCheck == nil)
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
        #expect(handoff.assessment == nil, "Older servers return context without an assessment")
    }

    @Test func decodesAssistedHandoffAssessment() throws {
        let json = ##"{"action_id":"11111111-1111-4111-8111-111111111111","title":"Proposal","markdown":"# Draft","assessment":{"effort":"medium","difficulty":"high","context":"needs_clarification","model":"typesafe/jev-1.13","rubric_version":"handoff-v1"}}"##
        let handoff = try decode(HandoffResponse.self, json)
        #expect(handoff.assessment?.effort == .medium)
        #expect(handoff.assessment?.difficulty == .high)
        #expect(handoff.assessment?.context == .needsClarification)
        #expect(handoff.assessment?.model == "typesafe/jev-1.13")
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

    /// 실행 receipt (U2 PR7): 원문 종류 execution · 근거 executed · 이벤트 주체 agent를 읽는다 (모르면 상세 화면 전체를 못 읽는다)
    @Test func decodesExecutionReceiptRows() throws {
        let source = try #require(try decode([SourceSummary].self, """
            [{ "id": "22222222-2222-4222-8222-222222222222", "kind": "execution", "title": "제안서 초안", "occurred_at": "2026-10-02T05:00:00.123456+00:00",
               "external_url": "taskforce://artifacts/7c2e5f0a-1b3d-4e6f-8a9b-0c1d2e3f4a5b", "created_at": "2026-10-02T05:00:01+00:00",
               "processing_status": "done", "meeting": null }]
            """).first)
        #expect(source.kind == .execution)
        #expect(SourceService.infer(externalURL: source.externalURL, kind: source.kind) == .manual(.execution))
        let evidence = try #require(try decode([EvidenceRecord].self, """
            [{ "id": "aaaaaaaa-0000-4000-8000-000000000003", "action_id": "11111111-1111-4111-8111-111111111111",
               "source_id": "22222222-2222-4222-8222-222222222222", "quote": "초안 저장: 제안서 초안", "role": "executed",
               "created_at": "2026-10-02T05:00:01+00:00" }]
            """).first)
        #expect(evidence.role == .executed)
        let event = try #require(try decode([ActionEventRecord].self, """
            [{ "id": "aaaaaaaa-0000-4000-8000-000000000004", "action_id": "11111111-1111-4111-8111-111111111111", "type": "artifact_created",
               "before": null, "after": { "artifact_id": "7c2e5f0a-1b3d-4e6f-8a9b-0c1d2e3f4a5b" }, "source_id": "22222222-2222-4222-8222-222222222222",
               "actor": "agent", "rule": null, "created_at": "2026-10-02T05:00:01+00:00" }]
            """).first)
        #expect(event.actor == .agent)
        #expect(ActionHistory.sentence(for: event, today: LocalDate("2026-10-02")!) == "초안 저장")
    }

    @Test func sourceColumnsReadMeeting() {
        #expect(SourceSummary.columns.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.contains("meeting"))
        #expect(SourceRecord.columns.hasPrefix(SourceSummary.columns))
    }

    @Test func decodesSourceMeeting() throws {
        let rows = try decode([SourceSummary].self, Fixtures.sourceRowsWithMeeting)
        #expect(rows.count == 6)

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
        // 빈 일정 id는 다른 회의끼리 묶이므로 일정 없음
        #expect(rows[5].meeting == nil)
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
