import Foundation
import Testing
@testable import TaskforceKit

/// 서버 JSON 계약 (서버 C3 head `6cfd382`): 응답 해석 · 요청 본문 · v2 경로 · 오류. 서버 모양이 바뀌면 여기서 먼저 깨진다.
/// 핵심: 구조는 엄격하고 모르는 enum은 `.unknown`(= 완전하다고 주장하지 않음)이며, 커서는 불투명 글자 그대로 오간다
struct ReturnSummaryContractTests {
    typealias Fx = ReturnSummaryContractFixtures
    let host = "t\(UUID().uuidString.lowercased().prefix(8)).test"

    func client(status: Int = 200, body: String = "{}") -> APIClient {
        StubProtocol.register(host: host, reply: .init(status: status, body: body))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return APIClient(baseURL: URL(string: "https://\(host)")!, session: URLSession(configuration: configuration), token: { "token-123" })
    }

    var last: StubProtocol.Recorded? { StubProtocol.requests(host: host).last }

    @Test func fixturePinsTheServerHead() {
        #expect(Fx.serverHead.hasPrefix("6cfd382"))
    }

    // MARK: 응답 해석

    @Test func theServerExampleDecodes() throws {
        let response = try Fx.decode(Fx.example())
        #expect(response.baseline == .cleared && response.since != nil && response.cursor == Fx.cursor)
        #expect(response.isComplete && !response.isEmpty && !response.isTruncated && response.sources.changes == .ok && response.sources.decisions == .ok)
        #expect(response.items.map(\.title) == ["확인이 필요한 일", "초안 작성"])
        let ask = response.items[0]
        #expect(ask.actionID == Fx.id(1) && ask.needsAnswer && ask.state == .toDo && ask.status == .open && ask.changes.isEmpty)
        #expect(ask.decisions == [ReturnSummaryDecision(id: "confirm:\(Fx.idString(1))", kind: .confirm, version: "action:\(Fx.idString(1)):4", urgent: false)])
        #expect(ask.next == ReturnSummaryNext(kind: .answer, decisionKinds: [.confirm]) && ask.version == "0a1b2c3d4e5f6071")
        let run = response.items[1]
        #expect(!run.needsAnswer && run.state == .inProgress && run.next.kind == .reviewResult)
        #expect(run.changes.count == 1 && run.changes[0].source == .run && run.changes[0].kind == "done" && run.changes[0].detail == "draft_ready")
        #expect(run.changes[0].sourceState == nil, "run 변화에는 원문 상태가 없다")
        #expect(response.hasChangesToClear)
    }

    /// 마이크로초 UTC 글자(`…123456Z`)는 표시용 시각으로 읽되 정밀도를 거짓으로 늘리지 않는다
    @Test func microsecondTimestampsDecodeForDisplay() throws {
        let response = try Fx.decode(Fx.example(since: "\"2026-10-12T08:00:00.123456Z\""))
        let since = try #require(response.since)
        #expect(abs(since.timeIntervalSince1970 - 1_791_792_000.123456) < 0.001)
    }

    @Test func neverClearedHasNoSinceAndKeepsItsMeaning() throws {
        let response = try Fx.decode(Fx.example(since: nil, baseline: "never_cleared"))
        #expect(response.since == nil && response.baseline == .neverCleared && response.isComplete)
    }

    @Test func aCancelledWorkHasNoStatusMarkState() throws {
        let item = Fx.item(3, title: "Dropped", status: "dropped", state: nil)
        let response = try Fx.decode(Fx.example(items: "[\(item)]"))
        #expect(response.items[0].status == .dropped && response.items[0].state == nil)
    }

    @Test func sourceStatesDecodeAsTokensNeverAsText() throws {
        let changes = "[" + ["available", "deleted", "access_lost", "text_expired"].enumerated().map {
            Fx.change(kind: "scope_changed", at: "2026-10-12T1\($0.offset):00:00.000000Z", sourceState: $0.element)
        }.joined(separator: ",") + "]"
        let response = try Fx.decode(Fx.example(items: "[\(Fx.item(4, changes: changes))]"))
        #expect(response.items[0].changes.map(\.sourceState) == [.available, .deleted, .accessLost, .textExpired])
        #expect(response.isComplete)
    }

    // MARK: 모르는 값은 `.unknown` — 변화를 해석 못 하면 완전하다고 주장하지 않는다 (줄의 표시용 상태는 그렇지 않다)

    /// 변화(source · kind · detail · source_state) · 변화 원천의 상태 · 응답 수준의 값을 읽지 못하면 완전하지 않고 빈 상태가 아니다
    @Test func unknownChangeValuesAndSourceStatusesMakeTheSummaryIncomplete() throws {
        func incomplete(_ json: String, uninterpretable: Bool = false) throws {
            let response = try Fx.decode(json)
            #expect(!response.isComplete && !response.isEmpty, "\(json.prefix(80))")
            #expect(response.hasUninterpretableChange == uninterpretable, "\(json.prefix(80))")
        }
        try incomplete(Fx.example(baseline: "someday"))
        try incomplete(Fx.example(changes: "partial"))
        try incomplete(Fx.example(decisions: "maybe"))
        try incomplete(Fx.example(items: "[\(Fx.item(1, changes: "[\(Fx.change(source: "carrier_pigeon"))]"))]"), uninterpretable: true)
        try incomplete(Fx.example(items: "[\(Fx.item(1, changes: "[\(Fx.change(sourceState: "vanished"))]"))]"), uninterpretable: true)
        try incomplete(Fx.example(items: "[\(Fx.item(1, changes: "[\(Fx.change(kind: "teleported"))]"))]"), uninterpretable: true)
        try incomplete(Fx.example(items: "[\(Fx.item(1, changes: "[\(Fx.change(source: "run", kind: "done", detail: "mystery", sourceState: nil))]"))]"), uninterpretable: true)
        try incomplete(Fx.example(items: "[\(Fx.item(1, changes: "[\(Fx.change(source: "message", kind: "gossip", sourceState: nil))]"))]"), uninterpretable: true)
    }

    /// 줄의 표시용 값(status · state · next · 결정 종류)을 몰라도 변화는 그대로 해석된다: 완전성을 해치지 않는다 (마크 · 라우팅만 비어 있다)
    @Test func unknownRowMetadataDoesNotMakeTheSummaryIncomplete() throws {
        for json in [
            Fx.example(items: "[\(Fx.item(1, status: "paused"))]"),
            Fx.example(items: "[\(Fx.item(1, state: "blocked"))]"),
            Fx.example(items: "[\(Fx.item(1, next: "celebrate"))]"),
            Fx.example(items: "[\(Fx.item(1, needsAnswer: true, decisionKind: "telepathy"))]"),
        ] {
            let response = try Fx.decode(json)
            #expect(response.isComplete && !response.hasUninterpretableChange, "\(json.prefix(80))")
        }
    }

    @Test func unknownValuesAreReadAsUnknownNotAsTheNearestKnownOne() throws {
        let response = try Fx.decode(Fx.example(baseline: "someday", changes: "partial", decisions: "maybe", items: "[\(Fx.item(1, status: "paused", state: "blocked", next: "celebrate"))]"))
        #expect(response.baseline == .unknown && response.sources == .init(changes: .unknown, decisions: .unknown))
        #expect(response.items[0].status == .unknown && response.items[0].state == .unknown && response.items[0].next.kind == .unknown)
    }

    /// 모르는 변화 토큰(`kind` 문자열)은 디코딩을 깨지 않는다: 줄은 남고 문구는 없고, 해석 못 한 변화다
    @Test func anUnknownChangeKindTokenKeepsTheRowAndHasNoText() throws {
        let item = Fx.item(5, changes: "[\(Fx.change(kind: "teleported"))]")
        let response = try Fx.decode(Fx.example(items: "[\(item)]"))
        #expect(response.items[0].changes[0].kind == "teleported" && !response.isComplete && response.hasUninterpretableChange)
        #expect(ReturnSummaryCopy.change(response.items[0].changes[0]) == nil)
    }

    // MARK: C — 첫 정상 표시 기준점 (A–D 후속 계약: `baseline: initialized` · `init_token` · baseline 확정)

    @Test func theFirstUseResponseCarriesAnOpaqueInitToken() throws {
        let first = try Fx.decode(Fx.example(since: nil, baseline: "never_cleared", initToken: Fx.initToken))
        #expect(first.baseline == .neverCleared && first.initToken == Fx.initToken && first.isComplete)
        // 빈 첫 화면에도 발급된다
        let empty = try Fx.decode(Fx.example(since: nil, baseline: "never_cleared", initToken: Fx.initToken, complete: true, empty: true, items: "[]"))
        #expect(empty.isEmpty && empty.initToken == Fx.initToken)
        // 기준점이 있으면 (initialized · cleared) 토큰이 없다
        let initialized = try Fx.decode(Fx.example(since: nil, baseline: "initialized"))
        #expect(initialized.baseline == .initialized && initialized.initToken == nil && initialized.isComplete)
        let cleared = try Fx.decode(Fx.example())
        #expect(cleared.baseline == .cleared && cleared.initToken == nil)
        // 옛 서버(`init_token` 키가 없다)도 읽는다
        let legacy = try Fx.decode("""
        {"generated_at":"2026-10-12T21:00:00.000Z","since":null,"baseline":"never_cleared","cursor":null,"complete":true,"empty":true,"sources":{"changes":"ok","decisions":"ok"},"items":[]}
        """)
        #expect(legacy.initToken == nil && legacy.baseline == .neverCleared)
    }

    @Test func theBaselineConfirmIsAPostOnTheV2PathWithTheTokenVerbatimAndNothingElse() async throws {
        let odd = "i1.dG9rZW4/+==_-.x" + String(repeating: "Zz9", count: 3_000)
        let api = client(body: Fx.baselineInitialized)
        let response = try await api.confirmReturnSummaryBaseline(initToken: odd)
        #expect(response == ReturnSummaryBaselineResponse(status: .initialized, applied: true))
        #expect(last?.url.path == "/api/v2/return-summary/baseline" && last?.method == "POST")
        #expect(last?.headers["Authorization"] == "Bearer token-123" && last?.url.query == nil)
        let body = try #require(last?.body)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object as NSDictionary == ["init_token": odd], "그 밖의 키 · 시각이 없고 토큰은 자르지 않는다")
    }

    @Test func alreadyInitializedIsASuccessfulResponseAndAnUnknownStatusDoesNotBreakDecoding() async throws {
        let already = try await client(body: Fx.baselineAlready).confirmReturnSummaryBaseline(initToken: Fx.initToken)
        #expect(already == ReturnSummaryBaselineResponse(status: .alreadyInitialized, applied: false))
        let odd = try await client(body: "{\"status\":\"rebased\",\"applied\":true}").confirmReturnSummaryBaseline(initToken: Fx.initToken)
        #expect(odd.status == .unknown)
        await #expect(throws: APIError.self) { try await client(body: "{\"status\":\"initialized\"}").confirmReturnSummaryBaseline(initToken: Fx.initToken) }
    }

    @Test func baselineErrorsMapToWhatTheServerMeans() async {
        func failure(_ status: Int, _ code: String, _ message: String) async -> APIError? {
            let api = client(status: status, body: ChatContractFixtures.error(code, message))
            do {
                _ = try await api.confirmReturnSummaryBaseline(initToken: Fx.initToken)
                return nil
            } catch {
                return error as? APIError
            }
        }
        let off = await failure(404, "not_found", "없는 경로입니다.")
        #expect(off?.isFeatureOff == true)
        let conflict = await failure(409, "conflict", "기준점 범위가 달라졌습니다.")
        #expect(conflict?.isConflict == true)
        let invalid = await failure(400, "invalid_request", "토큰이 올바르지 않습니다.")
        #expect(invalid?.status == 400 && invalid?.isConflict == false)
        let broken = await failure(500, "internal_error", "x")
        #expect(broken?.status == 500)
    }

    // MARK: 구조는 엄격하다 (틀리면 읽지 못한 것이지 빈 상태가 아니다)

    @Test func aBrokenStructureFailsToDecode() {
        #expect(throws: (any Error).self) { try Fx.decode("{\"generated_at\":\"2026-10-12T21:00:00.000Z\"}") }
        #expect(throws: (any Error).self) { try Fx.decode(Fx.example(items: "[{\"action_id\":\"\(Fx.idString(1))\"}]")) }
        #expect(throws: (any Error).self) { try Fx.decode(Fx.example(items: "[\(Fx.item(1, changes: "[\(Fx.change(at: "yesterday-ish"))]"))]")) }
        #expect(throws: (any Error).self) { try Fx.decode(Fx.example(items: "[\(Fx.item(1).replacingOccurrences(of: Fx.idString(1), with: "not-a-uuid"))]")) }
        #expect(throws: (any Error).self) { try Fx.decode("[]") }
    }

    // MARK: 완전성 · 빈 상태

    @Test func onlyACompleteResponseWithNoItemsIsEmpty() throws {
        let empty = try Fx.decode(Fx.example(complete: true, empty: true, items: "[]"))
        #expect(empty.isComplete && empty.isEmpty)
        // 서버가 empty라 해도 두 원천이 ok가 아니면 비어 있다고 하지 않는다
        for (changes, decisions) in [("unavailable", "ok"), ("ok", "unavailable"), ("truncated", "ok")] {
            let response = try Fx.decode(Fx.example(complete: true, empty: true, changes: changes, decisions: decisions, items: "[]"))
            #expect(!response.isEmpty && !response.isComplete, "\(changes)/\(decisions)")
        }
        // complete:false · 줄이 있는 empty:true 같은 모순은 비어 있다고 하지 않는다
        #expect(try !Fx.decode(Fx.example(complete: false, empty: true, items: "[]")).isEmpty)
        #expect(try !Fx.decode(Fx.example(complete: true, empty: true)).isEmpty)
        #expect(try !Fx.decode(Fx.example(complete: true, empty: false, items: "[]")).isEmpty)
    }

    /// 서버 head `6cfd382`(P2-C): 잘려도 커서가 있다 — 그 커서는 보인 작업만 읽음 처리한다. 커서가 `null`인 것은 변화 원천을 읽지 못했을 때뿐이다.
    /// 앱은 `truncated`로 Clear를 짐작하지 않고 커서만 본다 (앞 head `9546daa`의 `truncated + cursor: null`도 같은 규칙으로 Clear 없음)
    @Test func truncationIsReadFromSourcesAndTheCursorIsReadOnItsOwn() throws {
        let truncated = try Fx.decode(Fx.example(complete: false, changes: "truncated"))
        #expect(truncated.isTruncated && truncated.cursor == Fx.cursor && !truncated.isComplete && !truncated.isEmpty)
        let unavailable = try Fx.decode(Fx.example(cursor: nil, complete: false, changes: "unavailable"))
        #expect(!unavailable.isTruncated && unavailable.cursor == nil && !unavailable.isComplete && !unavailable.isEmpty)
        let olderHead = try Fx.decode(Fx.example(cursor: nil, complete: false, changes: "truncated"))
        #expect(olderHead.isTruncated && olderHead.cursor == nil)
        #expect(ReturnSummaryPresentation.canClear(truncated, isStale: false, cursorSpent: false), "잘림에서 짐작하지 않고 커서가 있으면 보인다")
        #expect(!ReturnSummaryPresentation.canClear(unavailable, isStale: false, cursorSpent: false))
        #expect(!ReturnSummaryPresentation.canClear(olderHead, isStale: false, cursorSpent: false), "커서가 없으면 잘림이어도 보이지 않는다")
    }

    /// 커서는 `c3.`로 시작하는 최대 10,000자 불투명 글자다. 접두어 · 길이를 앱이 알지도 자르지도 않는다 (서버가 낸 글자 그대로 읽고 보낸다)
    @Test func aLongOpaqueCursorSurvivesDecodingAndIsNeverLengthTruncated() async throws {
        let long = "c3." + String(repeating: "Ab0_-", count: 1_999) + "Z"   // 3 + 9,995 + 1 = 9,999자
        #expect(long.count == 9_999)
        let response = try Fx.decode(Fx.example(cursor: long, complete: false, changes: "truncated"))
        #expect(response.cursor == long)
        let api = client(body: Fx.clearResponse)
        _ = try await api.clearReturnSummary(cursor: long)
        let body = try #require(last?.body)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["cursor"] as? String == long && (object["cursor"] as? String)?.count == 9_999)
        // 이전 판의 접두어(c2.)도 앱은 열어 보지 않는다: 서버가 판단한다 (옛 커서는 400)
        let old = "c2.WyJvbGQiXQ"
        _ = try await api.clearReturnSummary(cursor: old)
        #expect((try JSONSerialization.jsonObject(with: try #require(last?.body)) as? [String: Any])?["cursor"] as? String == old)
    }

    // MARK: 요청 (v2 경로 · Bearer · 본문)

    @Test func readIsAGetOnTheV2PathWithABearerToken() async throws {
        let api = client(body: Fx.example())
        let response = try await api.returnSummary()
        #expect(response.items.count == 2)
        #expect(last?.url.path == "/api/v2/return-summary" && last?.method == "GET")
        #expect(last?.headers["Authorization"] == "Bearer token-123" && last?.body == nil)
        #expect(last?.url.query == nil, "조회에 클라이언트 시각 · 질의가 없다")
    }

    @Test func clearSendsTheCursorVerbatimAndNothingElse() async throws {
        // 서버가 낸 글자는 어떤 문자가 들어 있어도 그대로 간다 (열지 않고, 자르지 않고, 시각으로 바꾸지 않는다)
        let odd = "c2.WyJhIiwi/+==_-.x"
        let api = client(body: Fx.clearResponse)
        let response = try await api.clearReturnSummary(cursor: odd)
        #expect(response.applied && response.clearedThrough > .distantPast)
        #expect(last?.url.path == "/api/v2/return-summary/clear" && last?.method == "POST")
        let body = try #require(last?.body)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object as NSDictionary == ["cursor": odd], "그 밖의 키 · 시각이 없다")
    }

    @Test func clearAppliedFalseIsStillASuccessfulResponse() async throws {
        let api = client(body: "{\"cleared_through\":\"2026-10-12T20:00:00.000000Z\",\"applied\":false}")
        #expect(try await api.clearReturnSummary(cursor: Fx.cursor).applied == false)
    }

    @Test func aBrokenClearBodyIsNotASuccess() async {
        let api = client(body: "{\"applied\":true}")
        await #expect(throws: APIError.self) { try await api.clearReturnSummary(cursor: Fx.cursor) }
    }

    /// 두 경로는 읽음 처리 · 조회뿐이다: 실행 · 승인 · 결정 · 정책 경로를 부르지 않는다
    @Test func summaryCallsNeverTouchDecisionOrExecutionPaths() async throws {
        let read = client(body: Fx.example())
        _ = try await read.returnSummary()
        let clear = client(body: Fx.clearResponse)
        _ = try await clear.clearReturnSummary(cursor: Fx.cursor)
        let baseline = client(body: Fx.baselineInitialized)
        _ = try await baseline.confirmReturnSummaryBaseline(initToken: Fx.initToken)
        let allPaths = StubProtocol.requests(host: host).map(\.url.path)
        #expect(Set(allPaths) == ["/api/v2/return-summary", "/api/v2/return-summary/clear", "/api/v2/return-summary/baseline"])
        for forbidden in ["runs", "approve", "start", "progress", "policy", "handoff", "confirm", "actions", "seen", "review", "suggestions"] {
            #expect(allPaths.allSatisfy { !$0.contains(forbidden) }, "\(forbidden)")
        }
    }

    // MARK: 오류 (게이트 꺼짐 · 충돌 · 잘못된 커서)

    @Test func errorsMapToWhatTheServerMeans() async {
        func failure(_ status: Int, _ code: String, _ message: String, clear: Bool = false) async -> APIError? {
            let api = client(status: status, body: ChatContractFixtures.error(code, message))
            do {
                if clear { _ = try await api.clearReturnSummary(cursor: Fx.cursor) } else { _ = try await api.returnSummary() }
                return nil
            } catch {
                return error as? APIError
            }
        }
        // gate REVIEW_V2_ENABLED 꺼짐: 두 경로 모두 404 "없는 경로입니다." = 이 서버는 아직 이 기능이 없다 (오류가 아니다)
        let off = await failure(404, "not_found", "없는 경로입니다.")
        #expect(off?.isFeatureOff == true)
        let offClear = await failure(404, "not_found", "없는 경로입니다.", clear: true)
        #expect(offClear?.isFeatureOff == true)
        // Clear 409: 조회한 뒤 범위가 달라졌다 (아무것도 읽음 처리하지 않았다)
        let conflict = await failure(409, "conflict", "변화가 있습니다.", clear: true)
        #expect(conflict?.isConflict == true && conflict?.isFeatureOff == false)
        // Clear 400: 모양이 틀린 · 미래 · 남의 · 옛 커서
        let invalid = await failure(400, "invalid_request", "커서가 올바르지 않습니다.", clear: true)
        #expect(invalid?.status == 400 && invalid?.isConflict == false)
        let unauthorized = await failure(401, "unauthorized", "로그인이 필요합니다.")
        #expect(unauthorized?.status == 401 && unauthorized?.isFeatureOff == false)
        let broken = await failure(500, "internal_error", "x", clear: true)
        #expect(broken?.status == 500)
    }

    @Test func aMissingRouteWithoutAnErrorBodyIsFeatureOffToo() async {
        let api = client(status: 404, body: "<html>not found</html>")
        do {
            _ = try await api.returnSummary()
            Issue.record("404는 던져야 한다")
        } catch {
            #expect((error as? APIError)?.isFeatureOff == true)
        }
    }
}
