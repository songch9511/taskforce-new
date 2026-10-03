import Foundation
import Testing
@testable import TaskforceKit

/// U1 PR2의 `/now` 표시 필드(`changed` · `section_limits`) · 실패 원문(`failed_sources`)을 예전 · 새 서버 모두에서 읽는다 (회귀 ③)
struct NowDisplayFieldsTests {
    func decode(_ json: String) throws -> NowResponse {
        try TaskforceJSON.decoder().decode(NowResponse.self, from: Data(json.utf8))
    }

    static let reviewID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
    static let contractID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!

    @Test func newServerFieldsDecode() throws {
        let now = try decode(Fixtures.nowDisplayFields)
        #expect(now.now.map(\.changed) == [true, false])
        #expect(now.changedConfirmations == [Self.reviewID])
        #expect(now.changedIDs == [Fixtures.actionID, Self.reviewID])
        #expect(now.tracksChanges)
        #expect(now.sectionLimits == SectionLimits(review: 3, inProgress: 4, toDo: 6))
        #expect(now.failedSources.count == 2)
        #expect(now.failedSources.reason == .aiTimeout)
        #expect(now.failedSources.latestAt == PostgresTimestamp.parse("2026-10-03T00:46:00.000Z"))
        // 확인 요청은 그대로 ActionSummary로 읽는다
        #expect(now.confirmations.first?.confirmReasons == ["담당 확인"])
    }

    @Test(arguments: [Fixtures.nowOlderServer, Fixtures.nowNullWeeklyCheck, Fixtures.nowWithWeeklyCheck, Fixtures.nowFailedSourcesOnly])
    func olderServerGetsDefaults(_ json: String) throws {
        let now = try decode(json)
        #expect(now.now.allSatisfy { !$0.changed })
        #expect(now.changedIDs.isEmpty)
        #expect(!now.tracksChanges)
        #expect(now.sectionLimits == .standard)
        #expect(now.failedSources.count == 0)
    }

    @Test func standardLimitsMatchFigma() {
        #expect(SectionLimits.standard == SectionLimits(review: 2, inProgress: 5, toDo: 5))
    }

    /// 기준값 하나가 어긋나면 그 섹션만 기본값, 모양이 통째로 어긋나도 목록은 읽는다
    @Test(arguments: [
        (#"{"review": 0, "in_progress": -1, "to_do": 7}"#, SectionLimits(review: 2, inProgress: 5, toDo: 7)),
        (#"{"review": "3", "to_do": 4}"#, SectionLimits(review: 2, inProgress: 5, toDo: 4)),
        (#"{}"#, SectionLimits.standard),
        (#""wide""#, SectionLimits.standard),
        ("null", SectionLimits.standard),
    ])
    func malformedLimitsFallBack(_ limits: String, _ expected: SectionLimits) throws {
        let now = try decode(#"{"now": [], "confirmations": [], "weekly_check": null, "section_limits": \#(limits)}"#)
        #expect(now.sectionLimits == expected)
    }

    @Test func malformedFailedSourcesAndChangedDoNotBreakTheList() throws {
        let json = """
        {
          "now": [{
            "id": "11111111-1111-4111-8111-111111111111", "title": "투자 자료 보내기", "owner": "me", "status": "open",
            "due_date": null, "counterpart": null, "needs_confirmation": false, "confirm_reasons": [], "started_at": null,
            "last_activity_at": "2026-09-27T01:02:03Z", "score": 1, "reasons": [], "days_until_due": null, "changed": "yes"
          }],
          "confirmations": [],
          "weekly_check": null,
          "failed_sources": { "count": "many" }
        }
        """
        let now = try decode(json)
        #expect(now.now.count == 1)
        #expect(now.now[0].changed == false)
        #expect(now.failedSources == .empty)
    }

    @Test func unknownFailureReasonIsNil() throws {
        let now = try decode(#"{"now": [], "confirmations": [], "weekly_check": null, "failed_sources": {"count": 1, "latest_at": null, "reason": "new_reason"}}"#)
        #expect(now.failedSources.count == 1)
        #expect(now.failedSources.reason == nil)
    }

    /// 먼저 보여 주는 내 변경을 얹어도 바뀜 · 기준값 · 실패 원문은 그대로 남는다
    @Test func boardApplyingKeepsDisplayFields() throws {
        let now = try decode(Fixtures.nowDisplayFields)
        let target = try #require(now.now.first?.action)
        let board = TaskBoard(now: now).applying([target.id: TaskChange(target, to: .inProgress, at: Date())])
        let applied = try #require(board.now)
        #expect(applied.sectionLimits == now.sectionLimits)
        #expect(applied.failedSources == now.failedSources)
        #expect(applied.changedIDs == now.changedIDs)
        #expect(applied.tracksChanges)
        #expect(applied.now.first?.action.startedAt != nil)
        #expect(applied.now.first?.changed == true)
    }
}
