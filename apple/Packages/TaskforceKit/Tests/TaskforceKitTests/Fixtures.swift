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
}
