import Foundation
import Testing
@testable import TaskforceKit

/// OA U3 11.1 · R-dec-m: 서버 `GET /api/v2/review/decisions` 응답(`REVIEW_DECISIONS_JSON`) · `GET /api/v2/review` 응답(`REVIEW_WITH_AGENTS_JSON`)과 경로 충돌 해소 요청의 디코딩.
/// 세 종류 ref · C3 종류(키 없음) · 모르는 종류 · `decisions: null` · `unavailable` · `complete: false`
struct TaskforceRequestModelsTests {
    typealias Fx = TaskforceRequestFixtures

    /// 픽스처의 한 줄만 바꾼다 (모양은 서버 그대로)
    private func variant(_ edit: (inout [String: Any]) -> Void) throws -> TaskforceReviewResponse {
        var object = try #require(try JSONSerialization.jsonObject(with: Data(Fx.review.utf8)) as? [String: Any])
        edit(&object)
        return try TaskforceJSON.decoder().decode(TaskforceReviewResponse.self, from: JSONSerialization.data(withJSONObject: object))
    }

    @Test func theServerFixtureDecodesInServerOrder() throws {
        let response = try Fx.decode(Fx.review)
        #expect(response.complete && !response.empty && response.decisionsOK)
        let kinds: [TaskforceDecisionKind] = [.agentApproval, .agentQuestion, .agentSecretQuestion, .resultReady, .pathConflict, .confirm]
        #expect(response.decisions?.map(\.kind) == kinds, "서버 순서 그대로")
        let task = "b0000000-0000-4000-8000-000000000001"
        let ids: [String] = [
            "agent_approval:" + task, "agent_question:" + task, "agent_secret_question:" + task,
            "result_ready:d0000000-0000-4000-8000-000000000001", "path_conflict:c0000000-0000-4000-8000-000000000001",
            "confirm:a0000000-0000-4000-8000-000000000007",
        ]
        #expect(response.items.map(\.id) == ids)
    }

    @Test func theThreeDrawnKindsCarryTheirRefAndTheOthersCarryNone() throws {
        let items = try Fx.decode(Fx.review).items
        let result = try #require(items.first { (item: TaskforceDecisionItem) in item.kind == .resultReady })
        let expectedRef = TaskforceResultRef(sessionID: Fx.session, reviewedTurnSeq: 0, lastTurnSeq: 3, changedAt: "2026-10-15T01:00:00.000Z")
        #expect(result.result == expectedRef)
        #expect(result.version == "result:" + Fx.run.uuidString.lowercased() + ":0:3:2")
        let conflictItem = try #require(items.first { (item: TaskforceDecisionItem) in item.kind == .pathConflict })
        let conflict = try #require(conflictItem.conflict)
        #expect(conflict.leaseID == Fx.lease && conflict.conflictVersion == 2 && conflict.holderActionID == Fx.action(6))
        #expect(conflict.holderRunID == Fx.run && conflict.laterRunID == Fx.run && !conflict.released && conflict.stopped)
        let confirm = try #require(items.first { (item: TaskforceDecisionItem) in item.kind == .confirm })
        #expect(confirm.actionID == Fx.action(7) && confirm.result == nil && confirm.conflict == nil)
        // 그리지 않는 종류(질문 셋)의 ref는 읽지도 검사하지도 않는다
        let questionKinds: [TaskforceDecisionKind] = [.agentApproval, .agentQuestion, .agentSecretQuestion]
        let questions = items.filter { questionKinds.contains($0.kind) }
        #expect(questions.count == 3 && questions.allSatisfy { $0.result == nil && $0.conflict == nil && $0.isReadable })
    }

    @Test func onlyConfirmResultAndConflictAreDrawn() {
        let drawn: [TaskforceDecisionKind] = [.confirm, .resultReady, .pathConflict]
        let others: [TaskforceDecisionKind] = [.approval, .reviewFailed, .runInput, .agentQuestion, .suggestion, .blockedDependency, .agentApproval, .agentSecretQuestion]
        #expect(drawn.allSatisfy(\.isDrawn) && others.allSatisfy { !$0.isDrawn && $0.isKnown })
        #expect(!TaskforceDecisionKind.unknown.isDrawn && !TaskforceDecisionKind.unknown.isKnown)
    }

    @Test func nullDecisionsAreUnknownNotEmpty() throws {
        let response = try variant { object in
            object["decisions"] = NSNull()
            object["complete"] = false
            object["sources"] = ["decisions": "unavailable", "suggestions": "ok", "time_zone": "ok"]
        }
        #expect(response.decisions == nil && !response.decisionsOK && !response.complete && response.items.isEmpty)
    }

    @Test func anUnavailableDecisionSourceIsNeverTrusted() throws {
        let response = try variant { object in
            object["sources"] = ["decisions": "unavailable", "suggestions": "ok", "time_zone": "ok"]
        }
        #expect(!response.decisionsOK, "목록이 있어도 원천을 읽지 못했으면 믿지 않는다")
        let unknown = try variant { object in object["sources"] = ["decisions": "partial", "suggestions": "ok", "time_zone": "ok"] }
        #expect(unknown.sources.decisions == .unknown && !unknown.decisionsOK)
    }

    @Test func aSuggestionSourceProblemDoesNotMakeTheDecisionsUntrusted() throws {
        let response = try variant { object in
            object["complete"] = false
            object["sources"] = ["decisions": "ok", "suggestions": "unavailable", "time_zone": "ok"]
        }
        #expect(response.decisionsOK && !response.complete, "결정만 읽는다: 제안 원천은 결정 목록의 믿음과 따로다")
    }

    @Test func anUnknownKindIsKeptAsUnknownNotDropped() throws {
        let response = try variant { object in
            var groups = (object["decisions"] as? [[String: Any]]) ?? []
            var group = groups[5]
            group["kind"] = "future_kind"
            var items = group["items"] as? [[String: Any]] ?? []
            items[0]["kind"] = "future_kind"
            group["items"] = items
            groups.append(group)
            object["decisions"] = groups
        }
        #expect(response.decisions?.last?.kind == .unknown)
        #expect(response.decisions?.last?.items.first?.kind == .unknown)
    }

    @Test func aDrawnKindWithoutItsRefIsUnreadable() throws {
        let response = try variant { object in
            var groups = (object["decisions"] as? [[String: Any]]) ?? []
            var items = groups[4]["items"] as? [[String: Any]] ?? []
            items[0].removeValue(forKey: "conflict")
            groups[4]["items"] = items
            var results = groups[3]["items"] as? [[String: Any]] ?? []
            results[0]["result"] = ["session_id": 7]
            groups[3]["items"] = results
            object["decisions"] = groups
        }
        let items = response.items
        #expect(items.first { $0.kind == .pathConflict }?.isReadable == false)
        #expect(items.first { $0.kind == .resultReady }?.isReadable == false, "모양이 틀린 ref도 읽을 수 없는 항목이다")
    }

    @Test func aNullSessionOnAResultIsReadableButHasNoSession() throws {
        let response = try variant { object in
            var groups = (object["decisions"] as? [[String: Any]]) ?? []
            var results = groups[3]["items"] as? [[String: Any]] ?? []
            var ref = results[0]["result"] as? [String: Any] ?? [:]
            ref["session_id"] = NSNull()
            results[0]["result"] = ref
            groups[3]["items"] = results
            object["decisions"] = groups
        }
        let result = try #require(response.items.first { $0.kind == .resultReady })
        #expect(result.isReadable && result.result?.sessionID == nil)
    }

    @Test(arguments: ["generated_at", "complete", "empty", "sources"])
    func aMissingRequiredKeyFailsTheWholeRead(_ key: String) throws {
        var object = try #require(try JSONSerialization.jsonObject(with: Data(Fx.review.utf8)) as? [String: Any])
        object.removeValue(forKey: key)
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) { try TaskforceJSON.decoder().decode(TaskforceReviewResponse.self, from: data) }
    }

    @Test func suggestionsAreNeverRead() throws {
        let response = try variant { object in
            object["suggestions"] = [["anything": ["the app", "does not", "read"]]]
            object["suggestion_batch"] = "not even an object"
        }
        #expect(response.items.count == 6)
    }

    @Test func theResolveRequestIsStrictAndTheResponseDecodes() throws {
        let body = try JSONEncoder().encode(TaskforceResolveConflictRequest(keep: .holder, conflictVersion: 2))
        let sent = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(sent.count == 2 && sent["keep"] as? String == "holder" && sent["conflict_version"] as? Int == 2)
        let expected = try #require(try JSONSerialization.jsonObject(with: Data(Fx.resolveRequest.utf8)) as? [String: Any])
        #expect(NSDictionary(dictionary: sent).isEqual(to: expected), "서버 시험의 요청과 같다")
        let reply = try JSONDecoder().decode(TaskforceResolveConflictResponse.self, from: Data(Fx.resolveResponse.utf8))
        #expect(reply.isResolved)
        let other = try JSONDecoder().decode(TaskforceResolveConflictResponse.self, from: Data(#"{"status":"pending"}"#.utf8))
        #expect(!other.isResolved, "모르는 status는 성공이 아니다")
    }

    @Test func keysOneAndTwoChooseHolderAndLater() {
        #expect(TaskforceConflictKeep(key: 1) == .holder && TaskforceConflictKeep(key: 2) == .later)
        #expect(TaskforceConflictKeep(key: 0) == nil && TaskforceConflictKeep(key: 3) == nil)
        #expect(TaskforceConflictKeep.holder.key == 1 && TaskforceConflictKeep.later.key == 2)
    }

    // MARK: R-dec (읽기 전용 결정 길): `sources`에 `decisions`만 있는 응답

    /// `GET /api/v2/review/decisions`는 `sources`에 `decisions` 하나만 싣는다. 없는 `suggestions` · `time_zone`은 응답을 못 읽게 하지도, 믿을 수 없게 하지도 않는다
    @Test func aDecisionsOnlyResponseDecodesAndTheMissingKeysAreNotIncomplete() throws {
        let response = try Fx.decode(Fx.reviewDecisionsOnly)
        #expect(response.sources.decisions == .ok && response.sources.suggestions == nil && response.sources.timeZone == nil)
        #expect(response.complete && !response.empty && response.decisionsOK)
        #expect(response.items.map(\.kind) == [.resultReady, .confirm])
        #expect(TaskforceRequestRules.isTrustworthy(response, skippedUnknown: false), "믿는 규칙은 `sources.decisions`와 `complete`뿐이다")
    }

    /// R-dec-m: 서버 fixture `REVIEW_DECISIONS_JSON`(앱이 부르는 경로의 응답)이 읽히고, 믿을 수 있고, 종류가 서버 순서대로 맞는다
    @Test func theServerDecisionsFixtureDecodesIsTrustedAndMapsTheKinds() throws {
        let response = try Fx.decode(Fx.reviewDecisions)
        #expect(response.complete && !response.empty && response.sources.decisions == .ok && response.decisionsOK)
        #expect(response.sources.suggestions == nil && response.sources.timeZone == nil, "이 응답은 `sources.decisions` 하나뿐이다")
        #expect(TaskforceRequestRules.isTrustworthy(response, skippedUnknown: false), "믿는 규칙: `complete` · `sources.decisions`")
        let kinds: [TaskforceDecisionKind] = [.agentApproval, .agentQuestion, .agentSecretQuestion, .resultReady, .pathConflict, .confirm]
        #expect(response.decisions?.map(\.kind) == kinds, "서버 순서 그대로")
        #expect(response.items.map(\.kind) == kinds && !kinds.contains(.unknown))
        let task = "b0000000-0000-4000-8000-000000000001"
        #expect(response.items.map(\.id) == [
            "agent_approval:" + task, "agent_question:" + task, "agent_secret_question:" + task,
            "result_ready:d0000000-0000-4000-8000-000000000001", "path_conflict:c0000000-0000-4000-8000-000000000001",
            "confirm:a0000000-0000-4000-8000-000000000007",
        ])
        // 앱이 그리는 종류는 셋이고, 모두 읽을 수 있다 (질문 셋은 그 세션에서만 답한다)
        let drawn = response.items.filter { (item: TaskforceDecisionItem) in item.kind.isDrawn }
        #expect(drawn.map(\.kind) == [.resultReady, .pathConflict, .confirm] && drawn.allSatisfy(\.isReadable))
    }

    /// 읽지 못한 같은 모양은 여전히 믿을 수 없다 (키가 없어서가 아니라 `decisions`가 `unavailable`이라서)
    @Test func aDecisionsOnlyResponseThatCouldNotReadItsSourceIsStillNotTrusted() throws {
        let response = try Fx.decode(Fx.reviewDecisionsOnlyUnavailable)
        #expect(response.sources.decisions == .unavailable && response.sources.suggestions == nil && !response.decisionsOK && !response.complete)
        #expect(!TaskforceRequestRules.isTrustworthy(response, skippedUnknown: false))
    }

    /// 기존 전체 응답(`GET /api/v2/review`)은 그대로 읽힌다: 두 키가 있으면 그 상태가 그대로 나온다
    @Test func theFullResponseStillDecodesUnchangedWithBothKeys() throws {
        let response = try Fx.decode(Fx.review)
        #expect(response.sources == TaskforceReviewSources(decisions: .ok, suggestions: .ok, timeZone: .ok))
        let degraded = try variant { object in
            object["sources"] = ["decisions": "ok", "suggestions": "unavailable", "time_zone": "unavailable"]
            object["complete"] = false
        }
        #expect(degraded.sources.suggestions == .unavailable && degraded.sources.timeZone == .unavailable)
        #expect(degraded.decisionsOK && !degraded.complete, "제안 원천이 `unavailable`이어도 결정 목록은 믿을 수 있다(complete는 서버 값 그대로)")
    }

    /// 한 키만 있어도 읽힌다 (선택 키는 각자 선택이다)
    @Test func eachOptionalSourceKeyIsOptionalOnItsOwn() throws {
        let onlySuggestions = try variant { $0["sources"] = ["decisions": "ok", "suggestions": "ok"] }
        #expect(onlySuggestions.sources.suggestions == .ok && onlySuggestions.sources.timeZone == nil)
        let onlyTimeZone = try variant { $0["sources"] = ["decisions": "ok", "time_zone": "ok"] }
        #expect(onlyTimeZone.sources.suggestions == nil && onlyTimeZone.sources.timeZone == .ok)
        // `decisions`는 선택이 아니다: 없으면 읽을 수 없다
        #expect(throws: (any Error).self) { try self.variant { $0["sources"] = ["suggestions": "ok"] } }
    }
}
