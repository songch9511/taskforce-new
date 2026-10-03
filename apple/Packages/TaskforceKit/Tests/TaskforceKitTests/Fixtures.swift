import Foundation
@testable import TaskforceKit

/// contract.ts · Postgres 응답과 같은 모양의 JSON
enum Fixtures {
    static let actionID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    static let sourceID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

    static let actionSummary = """
    {
      "id": "11111111-1111-4111-8111-111111111111",
      "title": "투자 자료 보내기",
      "owner": "me",
      "status": "open",
      "due_date": "2026-09-29",
      "counterpart": "김대표",
      "needs_confirmation": false,
      "confirm_reasons": [],
      "started_at": null,
      "last_activity_at": "2026-09-27T01:02:03.123456+00:00"
    }
    """

    static let nowWithWeeklyCheck = """
    {
      "now": [
        {
          "id": "11111111-1111-4111-8111-111111111111",
          "title": "투자 자료 보내기",
          "owner": "me",
          "status": "open",
          "due_date": "2026-09-29",
          "counterpart": "김대표",
          "needs_confirmation": false,
          "confirm_reasons": [],
          "started_at": "2026-09-26T10:00:00+00:00",
          "last_activity_at": "2026-09-27T01:02:03.123456+00:00",
          "score": 97.5,
          "reasons": ["due_soon", "external", "started", "brand_new_reason"],
          "days_until_due": 2
        },
        {
          "id": "33333333-3333-4333-8333-333333333333",
          "title": "계약서 검토",
          "owner": "unknown",
          "status": "open",
          "due_date": null,
          "counterpart": null,
          "needs_confirmation": false,
          "confirm_reasons": [],
          "started_at": null,
          "last_activity_at": "2026-09-20T01:02:03Z",
          "score": 21,
          "reasons": ["neglected"],
          "days_until_due": null
        }
      ],
      "confirmations": [
        {
          "id": "44444444-4444-4444-8444-444444444444",
          "title": "견적서 회신",
          "owner": "unknown",
          "status": "open",
          "due_date": "2026-10-01",
          "counterpart": null,
          "needs_confirmation": true,
          "confirm_reasons": ["담당 확인", "기한 확인"],
          "started_at": null,
          "last_activity_at": "2026-09-27T00:00:00.5+00:00",
          "score": 40,
          "reasons": ["due_soon"],
          "days_until_due": 4
        }
      ],
      "weekly_check": { "week_start": "2026-09-21" }
    }
    """

    /// weekly_check가 생기기 전 서버
    static let nowOlderServer = """
    { "now": [], "confirmations": [] }
    """

    static let nowNullWeeklyCheck = """
    { "now": [], "confirmations": [], "weekly_check": null }
    """

    /// U1 PR2 뒤 서버: 바뀜(`changed`) · 섹션 기준값(`section_limits`) · 실패 원문(`failed_sources`)
    static let nowDisplayFields = """
    {
      "now": [
        {
          "id": "11111111-1111-4111-8111-111111111111",
          "title": "투자 자료 보내기",
          "owner": "me",
          "status": "open",
          "due_date": "2026-09-29",
          "counterpart": "김대표",
          "needs_confirmation": false,
          "confirm_reasons": [],
          "started_at": null,
          "last_activity_at": "2026-09-27T01:02:03Z",
          "score": 90,
          "reasons": ["due_soon"],
          "days_until_due": 2,
          "changed": true
        },
        {
          "id": "33333333-3333-4333-8333-333333333333",
          "title": "계약서 검토",
          "owner": "me",
          "status": "open",
          "due_date": null,
          "counterpart": null,
          "needs_confirmation": false,
          "confirm_reasons": [],
          "started_at": null,
          "last_activity_at": "2026-09-20T01:02:03Z",
          "score": 21,
          "reasons": [],
          "days_until_due": null,
          "changed": false
        }
      ],
      "confirmations": [
        {
          "id": "44444444-4444-4444-8444-444444444444",
          "title": "견적서 회신",
          "owner": "unknown",
          "status": "open",
          "due_date": null,
          "counterpart": null,
          "needs_confirmation": true,
          "confirm_reasons": ["담당 확인"],
          "started_at": null,
          "last_activity_at": "2026-09-27T00:00:00Z",
          "score": 40,
          "reasons": [],
          "days_until_due": null,
          "changed": true
        }
      ],
      "weekly_check": null,
      "failed_sources": { "count": 2, "latest_at": "2026-10-03T00:46:00.000Z", "reason": "ai_timeout" },
      "section_limits": { "review": 3, "in_progress": 4, "to_do": 6 }
    }
    """

    /// failed_sources는 있지만 바뀜 · 기준값이 아직 없는 서버 (지금 운영)
    static let nowFailedSourcesOnly = """
    {
      "now": [],
      "confirmations": [],
      "weekly_check": null,
      "failed_sources": { "count": 0, "latest_at": null, "reason": null }
    }
    """

    static let missingCreated = """
    { "status": "created", "action": \(actionSummary), "stage": "judge_rejected" }
    """

    static let missingAlreadyTracked = """
    { "status": "already_tracked", "action": \(actionSummary), "stage": null }
    """

    static let handoff = """
    { "action_id": "11111111-1111-4111-8111-111111111111", "title": "투자 자료 보내기", "markdown": "# 투자 자료 보내기\\n- 근거" }
    """

    static let eventRows = """
    [
      {
        "id": "aaaaaaaa-0000-4000-8000-000000000001",
        "action_id": "11111111-1111-4111-8111-111111111111",
        "type": "due_changed",
        "before": { "due": "2026-09-25" },
        "after": { "due": "2026-09-28" },
        "source_id": "22222222-2222-4222-8222-222222222222",
        "actor": "ai",
        "rule": "rule0+rule4",
        "created_at": "2026-09-24T03:00:00.000123+00:00"
      },
      {
        "id": "aaaaaaaa-0000-4000-8000-000000000002",
        "action_id": "11111111-1111-4111-8111-111111111111",
        "type": "user_confirmed",
        "before": { "confirm_reasons": ["담당 확인"] },
        "after": { "confirm_reasons": [] },
        "source_id": null,
        "actor": "user",
        "rule": "user",
        "created_at": "2026-09-25T03:00:00+00:00"
      }
    ]
    """

    static let sourceRow = """
    [{
      "id": "22222222-2222-4222-8222-222222222222",
      "kind": "meeting",
      "title": "주간 회의",
      "occurred_at": "2026-09-24T02:00:00+00:00",
      "external_url": "https://www.notion.so/abc",
      "created_at": "2026-09-24T02:10:00.654321+00:00",
      "processing_status": "done",
      "raw_text": "김대표: 자료 금요일까지 부탁해요\\n나: 네, 보내드릴게요"
    }]
    """

    /// `sources.meeting`이 있는 행 · null · 없음 · 모양이 어긋남 · 제목 없음 · 빈 id (SourceSummary.columns, google-integration.md 2-7)
    static let sourceRowsWithMeeting = """
    [
      {
        "id": "33333333-3333-4333-8333-000000000001",
        "kind": "meeting",
        "title": "Proposal review",
        "occurred_at": "2026-10-01T00:30:00+00:00",
        "external_url": "https://www.notion.so/proposal",
        "created_at": "2026-09-30T02:00:00.123456+00:00",
        "processing_status": "done",
        "meeting": {
          "calendar_event_id": "evt-1",
          "title": "Proposal review — Acme",
          "start": "2026-09-30T01:00:00.000Z",
          "end": "2026-09-30T02:00:00.000Z"
        }
      },
      {
        "id": "33333333-3333-4333-8333-000000000002",
        "kind": "meeting",
        "title": "Google Meet · 2026-09-30 10:00",
        "occurred_at": "2026-09-30T01:01:00+00:00",
        "external_url": "https://docs.google.com/document/d/abc/view",
        "created_at": "2026-09-30T02:30:00+00:00",
        "processing_status": "done",
        "meeting": null
      },
      {
        "id": "33333333-3333-4333-8333-000000000003",
        "kind": "message",
        "title": "#sales",
        "occurred_at": "2026-09-30T03:00:00+00:00",
        "external_url": "https://acme.slack.com/archives/C1/p1",
        "created_at": "2026-09-30T03:01:00+00:00",
        "processing_status": "done"
      },
      {
        "id": "33333333-3333-4333-8333-000000000004",
        "kind": "meeting",
        "title": "주간 회의",
        "occurred_at": "2026-09-30T04:00:00+00:00",
        "external_url": "https://www.notion.so/weekly",
        "created_at": "2026-09-30T04:10:00+00:00",
        "processing_status": "done",
        "meeting": { "calendar_event_id": "evt-2", "title": "Weekly" }
      },
      {
        "id": "33333333-3333-4333-8333-000000000005",
        "kind": "meeting",
        "title": "주간 회의",
        "occurred_at": "2026-09-30T05:20:00+00:00",
        "external_url": "https://www.notion.so/weekly2",
        "created_at": "2026-09-30T05:10:00+00:00",
        "processing_status": "done",
        "meeting": { "calendar_event_id": "evt-3", "title": "  ", "start": "2026-09-30T05:00:00.000Z", "end": "2026-09-30T05:30:00.000Z" }
      },
      {
        "id": "33333333-3333-4333-8333-000000000006",
        "kind": "meeting",
        "title": "Standup",
        "occurred_at": "2026-09-30T06:00:00+00:00",
        "external_url": "https://www.notion.so/standup",
        "created_at": "2026-09-30T06:10:00+00:00",
        "processing_status": "done",
        "meeting": { "calendar_event_id": "", "title": "Standup", "start": "2026-09-30T06:00:00.000Z", "end": "2026-09-30T06:15:00.000Z" }
      }
    ]
    """
}
