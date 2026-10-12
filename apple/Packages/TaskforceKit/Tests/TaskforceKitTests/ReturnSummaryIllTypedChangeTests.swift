import Foundation
import Testing
@testable import TaskforceKit

/// P2-M2 — 타입이 틀리거나 모르는 변화 필드를 **지우지 않는다**. 실제 서버 JSON → 실제 디코더(`TaskforceJSON`) → 저장소 읽기 → 표시 → Clear · 기준점 확정의 한 길에서 시험한다.
/// 변화 하나가 아래 중 하나면 앱이 말로 옮기지 못하는 변화(`Some changes couldn't be shown`)이고, 표시는 남기며 Clear · 첫 정상 표시 확정은 막는다:
/// - run `done`의 `detail`이 숫자 · 객체 · 배열 · bool (예전에는 `try?`가 nil로 지워 `Processing finished`로 보였다)
/// - run · message의 `source_state`가 모르는 값 (action_event만 쓰는 필드다)
/// - action_event(또는 message)의 `detail`이 값을 가졌다 (계약상 null이다)
/// 그 반대로 정말 없는 값(null · 키 없음) · 정상 메시지 · 정상 잘림 · 결정 읽기 실패 · 모르는 결정 종류는 안전한 변화의 Clear · 확정을 막지 않는다.
@MainActor
struct ReturnSummaryIllTypedChangeTests {
    typealias Fx = ReturnSummaryContractFixtures

    /// 한 JSON 응답을 읽은 저장소 (게이트웨이는 같은 실제 디코더로 JSON을 읽어 돌려준다)
    func store(_ json: String) async throws -> ReturnSummaryStore {
        let account = try ChatTestAccount.make()
        let gateway = FakeReturnSummaryGateway()
        gateway.retained = account
        gateway.onRead = { _ in try Fx.decode(json) }
        let store = ReturnSummaryStore(gateway: gateway, scope: account.scope)
        await store.refresh()
        return store
    }

    struct Probe {
        let content: ReturnSummaryContent?
        let rowDetail: String?
        let clearAllowed: Bool
        let baselineAllowed: Bool
    }

    /// 변화 하나를 (이미 Clear한 사용자의 응답)에서는 Clear로, (첫 사용 응답)에서는 기준점 확정으로 받아 본다
    func probe(_ change: String, changes: String = "ok", decisions: String = "ok", needsAnswer: Bool = false, decisionKind: String = "confirm") async throws -> Probe {
        let items = "[\(Fx.item(1, needsAnswer: needsAnswer, decisionKind: decisionKind, changes: "[\(change)]"))]"
        let cleared = try await store(Fx.example(baseline: "cleared", complete: changes == "ok" && decisions == "ok", changes: changes, decisions: decisions, items: items))
        let first = try await store(Fx.example(
            since: nil, baseline: "never_cleared", initToken: Fx.initToken, complete: changes == "ok" && decisions == "ok", changes: changes, decisions: decisions, items: items
        ))
        let content = cleared.content()
        return Probe(
            content: content, rowDetail: content?.rows.first?.detail, clearAllowed: cleared.beginClear() != nil, baselineAllowed: first.beginBaseline() != nil
        )
    }

    // MARK: 디코드: 지우지 않고 해석 못 한 변화로 둔다

    @Test func anIllTypedDetailIsKeptAsMalformedNotErasedToNothing() throws {
        for (name, raw) in [("number", "42"), ("object", "{\"outcome\":\"draft_ready\"}"), ("array", "[\"draft_ready\"]"), ("bool", "true"), ("float", "1.5")] {
            let change = try Fx.decode(Fx.example(items: "[\(Fx.item(1, changes: "[\(Fx.change(source: "run", kind: "done", sourceState: nil, detailJSON: raw))]"))]")).items[0].changes[0]
            #expect(change.isMalformed && !change.isInterpretable && ReturnSummaryCopy.change(change) == nil, "\(name)")
        }
    }

    @Test func aNonStringKindIsMalformedToo() throws {
        for raw in ["7", "{}", "[]", "false"] {
            let response = try Fx.decode(Fx.example(items: "[\(Fx.item(1, changes: "[\(Fx.change(kindJSON: raw))]"))]"))
            #expect(response.items[0].changes[0].isMalformed && response.hasUninterpretableChange && !response.canMarkChangesRead, "\(raw)")
        }
    }

    @Test func reallyAbsentValuesAreNotMalformed() throws {
        let nullDetail = try Fx.decode(Fx.example(items: "[\(Fx.item(1, changes: "[\(Fx.change(source: "run", kind: "done", sourceState: nil))]"))]")).items[0].changes[0]
        let missingDetail = try Fx.decode(Fx.example(items: "[\(Fx.item(1, changes: "[\(Fx.change(source: "run", kind: "done", sourceState: nil, omitDetail: true))]"))]")).items[0].changes[0]
        for change in [nullDetail, missingDetail] {
            #expect(!change.isMalformed && change.detail == nil && change.isInterpretable)
            #expect(ReturnSummaryCopy.change(change) == ReturnSummaryCopy.runProcessingFinished)
        }
    }

    // MARK: 차단: 표시는 남고 Clear · 확정은 막힌다

    /// 해석 못 한 변화 (이름 · 변화 JSON). 어느 것도 정상 문구로 바뀌지 않는다
    var blocked: [(String, String)] {
        [
            ("run done · detail number", Fx.change(source: "run", kind: "done", sourceState: nil, detailJSON: "42")),
            ("run done · detail object", Fx.change(source: "run", kind: "done", sourceState: nil, detailJSON: "{\"outcome\":\"draft_ready\"}")),
            ("run done · detail array", Fx.change(source: "run", kind: "done", sourceState: nil, detailJSON: "[\"agent_done\"]")),
            ("run done · detail bool", Fx.change(source: "run", kind: "done", sourceState: nil, detailJSON: "true")),
            ("run done · detail unknown outcome", Fx.change(source: "run", kind: "done", detail: "mystery", sourceState: nil)),
            ("run failed · detail object", Fx.change(source: "run", kind: "failed", sourceState: nil, detailJSON: "{}")),
            ("run done · source_state future_state", Fx.change(source: "run", kind: "done", detail: "draft_ready", sourceState: "future_state")),
            ("run done · source_state deleted", Fx.change(source: "run", kind: "done", detail: "draft_ready", sourceState: "deleted")),
            ("run done · source_state number", Fx.change(source: "run", kind: "done", detail: "draft_ready", sourceStateJSON: "3")),
            ("run failed · source_state future_state", Fx.change(source: "run", kind: "failed", sourceState: "future_state")),
            ("message assistant · source_state future_state", Fx.change(source: "message", kind: "assistant", sourceState: "future_state")),
            ("message event · source_state number", Fx.change(source: "message", kind: "event", sourceStateJSON: "3")),
            ("message assistant · detail text", Fx.change(source: "message", kind: "assistant", detail: "future_detail", sourceState: nil)),
            ("message event · detail number", Fx.change(source: "message", kind: "event", sourceState: nil, detailJSON: "1")),
            ("action_event · detail future_detail", Fx.change(kind: "due_changed", detail: "future_detail")),
            ("action_event · detail number", Fx.change(kind: "owner_changed", sourceState: "available", detailJSON: "42")),
            ("action_event · detail object", Fx.change(kind: "completed", sourceState: "deleted", detailJSON: "{\"x\":1}")),
            ("action_event · source_state unknown", Fx.change(kind: "due_changed", sourceState: "vanished")),
            ("action_event · source_state number", Fx.change(kind: "due_changed", sourceStateJSON: "5")),
            ("action_event · unknown kind", Fx.change(kind: "teleported")),
            ("unknown source", Fx.change(source: "carrier_pigeon")),
            ("non-string kind", Fx.change(kindJSON: "7")),
        ]
    }

    @Test func everyUninterpretableChangeIsKeptOnScreenAndBlocksClearAndTheBaseline() async throws {
        for (name, change) in blocked {
            let result = try await probe(change)
            #expect(result.content?.rows.count == 1, "\(name): 줄은 남는다")
            #expect(result.content?.notes.contains(.couldNotShow) == true, "\(name): Some changes couldn't be shown")
            #expect(result.content?.canClear == false && !result.clearAllowed, "\(name): Clear 막힘")
            #expect(!result.baselineAllowed, "\(name): 첫 정상 표시 확정 막힘")
            // 어떤 정상 문구로도 바뀌지 않는다
            #expect(result.rowDetail == nil, "\(name): 문구 없음, 실제: \(result.rowDetail ?? "nil")")
        }
    }

    @Test func anIllTypedRunDetailIsNeverShownAsProcessingFinishedOrAsAKnownOutcome() async throws {
        for raw in ["42", "{\"outcome\":\"draft_ready\"}", "[\"draft_ready\"]", "false"] {
            let result = try await probe(Fx.change(source: "run", kind: "done", sourceState: nil, detailJSON: raw))
            let shown = result.rowDetail ?? ""
            for phrase in [ReturnSummaryCopy.runProcessingFinished, ReturnSummaryCopy.runDraftReady, ReturnSummaryCopy.runResultReady] {
                #expect(!shown.contains(phrase), "\(raw): \(phrase)")
            }
            #expect(!result.clearAllowed && !result.baselineAllowed, "\(raw)")
        }
    }

    @Test func aSafeChangeNextToAnUninterpretableOneStaysSpokenButStillBlocks() async throws {
        let safe = Fx.change(kind: "due_changed", at: "2026-10-12T09:00:00.000000Z")
        let bad = Fx.change(source: "run", kind: "done", at: "2026-10-12T10:00:00.000000Z", sourceState: nil, detailJSON: "42")
        let result = try await probe("\(safe),\(bad)")
        #expect(result.rowDetail == ReturnSummaryCopy.actionEventDueChanged)
        #expect(result.content?.notes.contains(.couldNotShow) == true && !result.clearAllowed && !result.baselineAllowed)
    }

    @Test func truncationPlusAnUninterpretableChangeSaysBothAndStillBlocks() async throws {
        let result = try await probe(Fx.change(source: "message", kind: "assistant", sourceState: "future_state"), changes: "truncated")
        #expect(result.content?.notes == [.couldNotShow, .moreAvailable])
        #expect(!result.clearAllowed && !result.baselineAllowed)
    }

    // MARK: 통제군: 안전한 변화의 Clear · 확정은 막히지 않는다

    var safe: [(String, String, String?)] {
        [
            ("run done · detail null", Fx.change(source: "run", kind: "done", sourceState: nil), ReturnSummaryCopy.runProcessingFinished),
            ("run done · detail key absent", Fx.change(source: "run", kind: "done", sourceState: nil, omitDetail: true), ReturnSummaryCopy.runProcessingFinished),
            ("run done · draft_ready", Fx.change(source: "run", kind: "done", detail: "draft_ready", sourceState: nil), ReturnSummaryCopy.runDraftReady),
            ("run done · agent_done", Fx.change(source: "run", kind: "done", detail: "agent_done", sourceState: nil), ReturnSummaryCopy.runResultReady),
            ("run done · review_failed", Fx.change(source: "run", kind: "done", detail: "review_failed", sourceState: nil), ReturnSummaryCopy.runNeedsRevision),
            ("run done · source_state available", Fx.change(source: "run", kind: "done", detail: "draft_ready", sourceState: "available"), ReturnSummaryCopy.runDraftReady),
            ("run failed · detail null", Fx.change(source: "run", kind: "failed", sourceState: nil), ReturnSummaryCopy.runFailed),
            ("run failed · outcome text (the server fills run.outcome on both)", Fx.change(source: "run", kind: "failed", detail: "draft_ready", sourceState: nil), ReturnSummaryCopy.runFailed),
            ("message assistant", Fx.change(source: "message", kind: "assistant", sourceState: nil), ReturnSummaryCopy.messageAssistant),
            ("message event", Fx.change(source: "message", kind: "event", sourceState: nil), ReturnSummaryCopy.messageEvent),
            ("message assistant · detail key absent", Fx.change(source: "message", kind: "assistant", sourceState: nil, omitDetail: true), ReturnSummaryCopy.messageAssistant),
            ("action_event due_changed", Fx.change(kind: "due_changed"), ReturnSummaryCopy.actionEventDueChanged),
            ("action_event · source_state null", Fx.change(kind: "owner_changed", sourceState: nil), ReturnSummaryCopy.actionEventOwnerChanged),
            ("action_event deleted source", Fx.change(kind: "scope_changed", sourceState: "deleted"), ReturnSummaryCopy.actionEventTitleChanged + " · " + ReturnSummaryCopy.sourceDeleted),
            ("action_event access lost", Fx.change(kind: "merged", sourceState: "access_lost"), ReturnSummaryCopy.actionEventUpdatedFromSource + " · " + ReturnSummaryCopy.sourceUnavailable),
            ("action_event text expired", Fx.change(kind: "completed", sourceState: "text_expired"), ReturnSummaryCopy.actionEventCompleted + " · " + ReturnSummaryCopy.sourceExpired),
            ("action_event · detail key absent", Fx.change(kind: "reopened", omitDetail: true), ReturnSummaryCopy.actionEventReopened),
        ]
    }

    @Test func safeChangesStillAllowClearAndTheBaseline() async throws {
        for (name, change, phrase) in safe {
            let result = try await probe(change)
            #expect(result.rowDetail == phrase, "\(name): \(result.rowDetail ?? "nil")")
            #expect(result.content?.notes.contains(.couldNotShow) == false, "\(name)")
            #expect(result.content?.canClear == true && result.clearAllowed, "\(name): Clear 가능")
            #expect(result.baselineAllowed, "\(name): 확정 가능")
        }
    }

    @Test func aNormalTruncatedPageStillAllowsClearAndTheBaseline() async throws {
        let result = try await probe(Fx.change(source: "message", kind: "assistant", sourceState: nil), changes: "truncated")
        #expect(result.content?.notes == [.moreAvailable])
        #expect(result.clearAllowed && result.baselineAllowed)
    }

    @Test func aDecisionsReadFailureOrAnUnknownDecisionKindStillAllowsClearAndTheBaseline() async throws {
        let change = Fx.change(source: "message", kind: "assistant", sourceState: nil)
        let unavailable = try await probe(change, decisions: "unavailable")
        #expect(unavailable.content?.notes == [.couldNotLoadQuestions] && unavailable.clearAllowed && unavailable.baselineAllowed)
        let unknownKind = try await probe(change, needsAnswer: true, decisionKind: "telepathy")
        #expect(unknownKind.clearAllowed && unknownKind.baselineAllowed && unknownKind.content?.notes.contains(.couldNotShow) == false)
    }
}
