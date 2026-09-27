import Foundation
import Testing
@testable import TaskforceKit

struct ActionHistoryTests {
    let today = LocalDate("2026-09-27")!
    let base = Date(timeIntervalSince1970: 1_790_000_000)

    func event(
        _ type: String, before: JSONValue? = nil, after: JSONValue? = nil, source: UUID? = nil, actor: EventActor = .ai,
        at offset: TimeInterval = 0
    ) -> ActionEventRecord {
        ActionEventRecord(
            id: UUID(), actionID: Fixtures.actionID, type: type, before: before, after: after, sourceID: source, actor: actor,
            rule: nil, createdAt: base.addingTimeInterval(offset)
        )
    }

    func evidence(_ quote: String, source: UUID, at offset: TimeInterval, role: EvidenceRole = .updated) -> EvidenceRecord {
        EvidenceRecord(id: UUID(), actionID: Fixtures.actionID, sourceID: source, quote: quote, role: role, createdAt: base.addingTimeInterval(offset))
    }

    func sentence(_ event: ActionEventRecord) -> String {
        ActionHistory.sentence(for: event, today: today)
    }

    @Test func dueChangeWithWeekdays() {
        let e = event("due_changed", before: .object(["due": .string("2026-09-25")]), after: .object(["due": .string("2026-09-28")]))
        #expect(sentence(e) == "기한 변경 9월 25일(금) → 9월 28일(월)")
    }

    @Test func dueClearedAndOtherYear() {
        let e = event("due_changed", before: .object(["due": .string("2027-01-04")]), after: .object(["due": .null]))
        #expect(sentence(e) == "기한 변경 2027년 1월 4일(월) → 없음")
    }

    @Test func aiEventSentences() {
        #expect(sentence(event("created", after: .object(["needs_confirmation": .bool(false)]))) == "할 일로 등록")
        #expect(sentence(event("created", after: .object(["needs_confirmation": .bool(true)]))) == "할 일로 등록 (확인 요청)")
        #expect(sentence(event("owner_changed", before: .object(["owner": .string("unknown")]), after: .object(["owner": .string("me")]))) == "담당 변경 미정 → 나")
        #expect(sentence(event("scope_changed", after: .object(["title": .string("IR 자료 보내기")]))) == "내용 변경 → “IR 자료 보내기”")
        #expect(sentence(event("merged")) == "같은 할 일이 다시 언급됨")
        #expect(sentence(event("completed")) == "완료로 바뀜")
        #expect(sentence(event("dropped")) == "취소됨")
        #expect(sentence(event("reopened")) == "다시 열림")
        #expect(sentence(event("something_new")) == "변경됨")
    }

    @Test func userEventSentences() {
        let edit = event(
            "user_edited",
            before: .object(["due": .string("2026-09-25"), "owner": .string("unknown")]),
            after: .object(["due": .string("2026-09-28"), "owner": .string("me")]),
            actor: .user
        )
        #expect(sentence(edit) == "기한 고침 9월 25일(금) → 9월 28일(월), 담당 고침 미정 → 나")
        #expect(sentence(event("user_edited", after: .object(["status": .string("done")]), actor: .user)) == "완료함")
        #expect(sentence(event("user_edited", after: .object(["title": .string("새 제목")]), actor: .user)) == "제목 고침 → “새 제목”")
        #expect(sentence(event("user_deleted", actor: .user)) == "삭제함")
        #expect(sentence(event("user_confirmed", actor: .user)) == "맞다고 확인함")
        #expect(sentence(event("user_started", actor: .user)) == "시작함")
        #expect(sentence(event("user_reported_missing", actor: .user)) == "빠진 할 일로 신고해 추가함")
    }

    @Test func attachesClosestEvidenceFromSameSource() {
        let sourceA = UUID()
        let sourceB = UUID()
        let events = [
            event("created", source: sourceA, at: 0),
            event("due_changed", before: .object(["due": .string("2026-09-25")]), after: .object(["due": .string("2026-09-28")]), source: sourceB, at: 100),
            event("user_confirmed", actor: .user, at: 200),
        ]
        let evidence = [
            evidence("자료 금요일까지 부탁해요", source: sourceA, at: 0.01, role: .created),
            evidence("월요일로 미룰게요", source: sourceB, at: 100.02),
            evidence("나중 언급", source: sourceB, at: 900),
        ]
        let entries = ActionHistory.entries(events: events, evidence: evidence, today: today)
        #expect(entries.map(\.sentence) == ["맞다고 확인함", "기한 변경 9월 25일(금) → 9월 28일(월)", "할 일로 등록"])
        #expect(entries.map(\.quote) == [nil, "월요일로 미룰게요", "자료 금요일까지 부탁해요"])
        #expect(entries[1].sourceID == sourceB)
        #expect(entries[0].actor == .user)
    }

    @Test func missingReportUsesSourceFromPayload() {
        let source = UUID()
        let e = event("user_reported_missing", after: .object(["stage": .string("not_extracted"), "source_id": .string(source.uuidString.lowercased())]), actor: .user)
        let entries = ActionHistory.entries(events: [e], evidence: [evidence("제가 할게요", source: source, at: 0)], today: today)
        #expect(entries.first?.quote == "제가 할게요")
        #expect(entries.first?.sourceID == source)
    }
}
