import Foundation
import Testing
@testable import TaskforceKit

/// 서버 JSON 계약 fixture: 서버 C3 head `6cfd382` (`handoffs/c3-server-notes.md` "Mac에 넘기는 JSON 계약", P2-C 반영본) + A–D 후속 계약
/// (`handoffs/c3-ad-contract.md` C: `baseline: initialized` · `init_token` · `POST /api/v2/return-summary/baseline`, 서버 레인이 구현 중이라 가짜 전송으로만 시험한다).
/// 이 head의 서버는 **잘려도(`truncated`) 커서를 낸다** (그 커서는 보인 작업만 읽음 처리한다). 커서는 `null`이 되는 것은 변화 원천을 읽지 못했을 때(`unavailable`)뿐이다.
/// 커서는 `c3.`로 시작하는 불투명 글자이고 최대 10,000자다. 앱은 열지도 자르지도 않고 그대로 돌려준다 (앞 head `9546daa`의 `truncated + cursor: null`도 같은 규칙으로 읽는다).
/// 이 모양이 바뀌면 `ReturnSummaryContractTests`가 먼저 깨진다.
enum ReturnSummaryContractFixtures {
    static let serverHead = "6cfd3821e1a48527002366756715bb69cb326071"
    static let cursor = "c3.WyIxMTExLi4uIiwiMjAyNi0xMC0xMlQwODowMDowMC4wMDAwMDBaIiwiYWJjIiwwLG51bGxd"

    static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "a1c30000-0000-4000-8000-%012d", n))! }
    static func idString(_ n: Int) -> String { id(n).uuidString.lowercased() }

    /// 서버 notes 예시 그대로의 모양 (Needs your answer 줄 + 실행 결과 줄)
    static let initToken = "i1.dG9rZW4tZm9yLXRoZS1maXJzdC1kaXNwbGF5"

    static func example(
        since: String? = "\"2026-10-12T08:00:00.000000Z\"", baseline: String = "cleared", cursor: String? = cursor, initToken: String? = nil,
        complete: Bool = true, empty: Bool = false, changes: String = "ok", decisions: String = "ok", items: String? = nil
    ) -> String {
        let cursorJSON = cursor.map { "\"\($0)\"" } ?? "null"
        let initJSON = initToken.map { "\"\($0)\"" } ?? "null"
        return """
        {"generated_at":"2026-10-12T21:00:00.000Z","since":\(since ?? "null"),"baseline":"\(baseline)","cursor":\(cursorJSON),"init_token":\(initJSON),
         "complete":\(complete),"empty":\(empty),"sources":{"changes":"\(changes)","decisions":"\(decisions)"},
         "items":\(items ?? defaultItems)}
        """
    }

    static let defaultItems = """
    [{"action_id":"\(idString(1))","title":"확인이 필요한 일","status":"open","state":"to_do","needs_answer":true,"urgent":false,
      "decisions":[{"id":"confirm:\(idString(1))","kind":"confirm","version":"action:\(idString(1)):4","urgent":false}],
      "changes":[],"next":{"kind":"answer","decision_kinds":["confirm"]},"version":"0a1b2c3d4e5f6071"},
     {"action_id":"\(idString(2))","title":"초안 작성","status":"open","state":"in_progress","needs_answer":false,"urgent":false,"decisions":[],
      "changes":[{"source":"run","kind":"done","at":"2026-10-12T13:00:00.000000Z","detail":"draft_ready","source_state":null}],
      "next":{"kind":"review_result","decision_kinds":[]},"version":"7c6b5a4938271605"}]
    """

    static func item(
        _ n: Int, title: String = "Pricing page", status: String = "open", state: String? = "in_progress", needsAnswer: Bool = false,
        decisionKind: String = "confirm", changes: String = "[]", next: String = "open", version: String = "v1"
    ) -> String {
        let decisions = needsAnswer
            ? "[{\"id\":\"\(decisionKind):\(idString(n))\",\"kind\":\"\(decisionKind)\",\"version\":\"d1\",\"urgent\":false}]" : "[]"
        let nextKind = needsAnswer ? "answer" : next
        let kinds = needsAnswer ? "[\"\(decisionKind)\"]" : "[]"
        return """
        {"action_id":"\(idString(n))","title":"\(title)","status":"\(status)","state":\(state.map { "\"\($0)\"" } ?? "null"),"needs_answer":\(needsAnswer),"urgent":false,
         "decisions":\(decisions),"changes":\(changes),"next":{"kind":"\(nextKind)","decision_kinds":\(kinds)},"version":"\(version)"}
        """
    }

    /// 변화 하나의 JSON. `kindJSON` · `detailJSON` · `sourceStateJSON`은 값을 **글자 그대로** 싣는다 (타입이 틀린 값 — 숫자 · 객체 · 배열 — 을 실제 JSON으로 시험한다). `omitDetail`은 `detail` 키 자체를 뺀다
    static func change(
        source: String = "action_event", kind: String = "due_changed", at: String = "2026-10-12T10:00:00.000000Z", detail: String? = nil,
        sourceState: String? = "available", kindJSON: String? = nil, detailJSON: String? = nil, sourceStateJSON: String? = nil, omitDetail: Bool = false
    ) -> String {
        let kindValue = kindJSON ?? "\"\(kind)\""
        let detailValue = detailJSON ?? detail.map { "\"\($0)\"" } ?? "null"
        let stateValue = sourceStateJSON ?? sourceState.map { "\"\($0)\"" } ?? "null"
        let detailPair = omitDetail ? "" : ",\"detail\":\(detailValue)"
        return """
        {"source":"\(source)","kind":\(kindValue),"at":"\(at)"\(detailPair),"source_state":\(stateValue)}
        """
    }

    static func decode(_ json: String) throws -> ReturnSummaryResponse {
        try TaskforceJSON.decoder().decode(ReturnSummaryResponse.self, from: Data(json.utf8))
    }

    static let clearResponse = "{\"cleared_through\":\"2026-10-12T20:00:00.000000Z\",\"applied\":true}"
    static let baselineInitialized = "{\"status\":\"initialized\",\"applied\":true}"
    static let baselineAlready = "{\"status\":\"already_initialized\",\"applied\":false}"
}

/// 모델을 직접 만드는 도우미 (저장소 · 표시 규칙 시험)
enum ReturnSummaryFx {
    static func id(_ n: Int) -> UUID { ReturnSummaryContractFixtures.id(n) }

    static func change(
        _ source: ReturnSummaryChangeSource = .actionEvent, _ kind: String = "due_changed", detail: String? = nil,
        sourceState: ReturnSummarySourceState? = .available, at: TimeInterval = 0
    ) -> ReturnSummaryChange {
        ReturnSummaryChange(source: source, kind: kind, at: .test(at), detail: detail, sourceState: source == .actionEvent ? sourceState : nil)
    }

    static func item(
        _ n: Int, title: String = "Pricing page", state: ReturnSummaryProgress? = .inProgress, needsAnswer: Bool = false,
        changes: [ReturnSummaryChange] = [], next: ReturnSummaryNextKind? = nil, version: String = "v1"
    ) -> ReturnSummaryItem {
        let decisions = needsAnswer ? [ReturnSummaryDecision(id: "confirm:\(n)", kind: .confirm, version: "d1", urgent: false)] : []
        let kind = next ?? (needsAnswer ? .answer : .open)
        return ReturnSummaryItem(
            actionID: id(n), title: title, state: state, needsAnswer: needsAnswer, decisions: decisions, changes: changes,
            next: ReturnSummaryNext(kind: kind, decisionKinds: needsAnswer ? [.confirm] : []), version: version
        )
    }

    static func response(
        _ items: [ReturnSummaryItem], cursor: String? = ReturnSummaryContractFixtures.cursor, since: TimeInterval? = -3_600,
        baseline: ReturnSummaryBaseline = .cleared, initToken: String? = nil, complete: Bool = true, empty: Bool? = nil, changes: ReturnSummarySourceStatus = .ok,
        decisions: ReturnSummarySourceStatus = .ok
    ) -> ReturnSummaryResponse {
        ReturnSummaryResponse(
            generatedAt: .test(0), since: since.map { .test($0) }, baseline: baseline, cursor: cursor, initToken: initToken, complete: complete,
            empty: empty ?? (complete && items.isEmpty), sources: .init(changes: changes, decisions: decisions), items: items
        )
    }

    /// 변화가 있는 줄 둘 (Clear가 보이는 기본 응답)
    static var withChanges: ReturnSummaryResponse {
        response([
            item(1, title: "Pricing page", needsAnswer: true, changes: [change(.run, "done", detail: "review_failed")]),
            item(2, title: "Launch design", changes: [change(.run, "done", detail: "draft_ready")], next: .reviewResult),
        ])
    }
}

/// 가짜 `ReturnSummaryGateway`: 읽기 · Clear 응답을 시험이 정하고(붙잡기 포함) 부른 것을 남긴다
final class FakeReturnSummaryGateway: ReturnSummaryGateway, @unchecked Sendable {
    struct Failure: Error {}

    private let lock = NSLock()
    private var _reads = 0
    private var _clears: [String] = []
    private var _baselines: [String] = []
    /// 읽기마다 부르는 응답 (몇 번째 읽기인지 1부터). 기본은 `withChanges`
    var onRead: @Sendable (Int) async throws -> ReturnSummaryResponse = { _ in ReturnSummaryFx.withChanges }
    var onClear: @Sendable (String) async throws -> ReturnSummaryClearResponse = { _ in ReturnSummaryClearResponse(clearedThrough: .test(0), applied: true) }
    var onBaseline: @Sendable (String) async throws -> ReturnSummaryBaselineResponse = { _ in ReturnSummaryBaselineResponse(status: .initialized, applied: true) }

    /// 시험이 만든 계정(`SessionStore`)을 시험이 끝날 때까지 붙든다: `AccountScope`는 세션을 약하게 잡는다
    var retained: Any?

    var reads: Int { lock.withLock { _reads } }
    var clears: [String] { lock.withLock { _clears } }
    /// 첫 정상 표시 확정으로 보낸 토큰들 (순서대로)
    var baselines: [String] { lock.withLock { _baselines } }

    func returnSummary() async throws -> ReturnSummaryResponse {
        let number = lock.withLock { () -> Int in
            _reads += 1
            return _reads
        }
        return try await onRead(number)
    }

    func clearReturnSummary(cursor: String) async throws -> ReturnSummaryClearResponse {
        lock.withLock { _clears.append(cursor) }
        return try await onClear(cursor)
    }

    func confirmReturnSummaryBaseline(initToken: String) async throws -> ReturnSummaryBaselineResponse {
        lock.withLock { _baselines.append(initToken) }
        return try await onBaseline(initToken)
    }
}

/// 붙잡은 요청이 `count`개 도착할 때까지 양보한다. 오지 않으면 영원히 돌지 않고 시험을 실패시킨다
func waitForArrival(_ latch: Latch, _ count: Int = 1, sourceLocation: SourceLocation = #_sourceLocation) async {
    for _ in 0..<50_000 {
        if await latch.arrivals >= count { return }
        await Task.yield()
    }
    Issue.record("붙잡은 요청이 도착하지 않았다", sourceLocation: sourceLocation)
}
