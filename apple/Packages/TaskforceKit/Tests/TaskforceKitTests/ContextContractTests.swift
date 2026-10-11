import Foundation
import Supabase
import Testing
@testable import TaskforceKit

/// 서버 JSON 계약 (서버 head `0da883a`): 응답 해석 · 요청 본문 · v2 경로 · 오류 · 읽기 질의. 서버 모양이 바뀌면 여기서 먼저 깨진다
struct ContextContractTests {
    let host = "t\(UUID().uuidString.lowercased().prefix(8)).test"
    let shape = ContextFx.id(1)
    let acme = ContextFx.id(2)
    let action = WorkListTests.id(1)

    func client(status: Int = 200, body: String = "{}") -> APIClient {
        StubProtocol.register(host: host, reply: .init(status: status, body: body))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return APIClient(baseURL: URL(string: "https://\(host)")!, session: URLSession(configuration: configuration), token: { "token-123" })
    }

    var last: StubProtocol.Recorded? { StubProtocol.requests(host: host).last }

    func json(_ data: Data?) throws -> [String: Any] {
        let body = try #require(data)
        return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    @Test func fixturePinsTheServerHead() {
        #expect(ContextContractFixtures.serverHead.hasPrefix("0da883a"))
        #expect(ContextContractFixtures.serverBase.hasPrefix("7328e93"))
    }

    // MARK: 응답 해석

    @Test func writeResponseDecodesMemberVersionAndChange() throws {
        let response = try ContextFx.decodeWrite(ContextContractFixtures.write(ctx: shape, action: action, version: 5))
        #expect(response.member.contextID == shape && response.member.actionID == action)
        #expect(response.member.origin == .user && response.member.isConfirmed && !response.member.isRemoved)
        #expect(response.contextVersion == 5)
        #expect(response.change == ContextChange(added: [ContextVersionRef(contextID: shape, contextVersion: 5)]))
        #expect(!response.change.isEmpty)
    }

    @Test func removeResponseKeepsTheRowWithRemovedAt() throws {
        let body = ContextContractFixtures.write(ctx: shape, action: action, version: 6, added: false, removed: true, removedAt: "2026-10-11T10:00:00.123456+00:00")
        let response = try ContextFx.decodeWrite(body)
        #expect(response.member.isRemoved && !response.member.isConfirmed)
        #expect(response.change.removed.map(\.contextID) == [shape] && response.change.added.isEmpty)
    }

    @Test func emptyChangeMeansNothingToUndo() throws {
        let body = ContextContractFixtures.write(ctx: shape, action: action, version: 6, added: false, removed: false)
        #expect(try ContextFx.decodeWrite(body).change.isEmpty)
    }

    @Test func moveResponseCarriesBothRowsAndBothVersions() throws {
        let response = try ContextFx.decodeMove(ContextContractFixtures.move(from: shape, to: acme, action: action, fromVersion: 3, toVersion: 5))
        #expect(response.member.contextID == acme && response.member.isConfirmed)
        #expect(response.fromMember.contextID == shape && response.fromMember.isRemoved)
        #expect(response.contextVersion == 5 && response.fromContextVersion == 3)
        #expect(response.change.added.map(\.contextID) == [acme] && response.change.removed.map(\.contextID) == [shape])
        // 처음 A+B였으면 B는 이미 멤버라 added가 비어 있다
        let already = try ContextFx.decodeMove(ContextContractFixtures.move(from: shape, to: acme, action: action, fromVersion: 3, toVersion: 5, toWasAlreadyMember: true))
        #expect(already.change.added.isEmpty && already.change.removed.map(\.contextID) == [shape])
    }

    /// 모르는 origin은 확인된 멤버가 아니다 / 뺀 행은 시각 형식이 낯설어도 멤버가 아니다 / 서버가 더하는 열은 무시
    @Test func unknownValuesDoNotBreakDecodingOrCountAsMembers() throws {
        func member(origin: String, removedAt: String? = nil, confidence: String = "null") throws -> ContextMember {
            let json = ContextContractFixtures.memberJSON(id: 1, ctx: shape, action: action, origin: origin, confidence: confidence, removedAt: removedAt)
            return try TaskforceJSON.decoder().decode(ContextMember.self, from: Data(json.utf8))
        }
        let telepathy = try member(origin: "telepathy")
        #expect(telepathy.origin == .other("telepathy") && !telepathy.isConfirmed && telepathy.isCandidate)
        let inferred = try member(origin: "inferred", confidence: "0.62")
        #expect(inferred.origin == .inferred && inferred.confidence == 0.62 && !inferred.isConfirmed && inferred.isCandidate)
        let auto = try member(origin: "auto")
        #expect(auto.isConfirmed && !auto.isCandidate)
        let strange = try member(origin: "user", removedAt: "not a timestamp")
        #expect(strange.isRemoved && !strange.isConfirmed, "값이 있으면 뺀 행이다")
    }

    @Test func workContextRowCarriesTheVersionForConditions() throws {
        let rows = """
        [{"id":"\(shape.uuidString.lowercased())","name":"Shape launch","kind":"project","status":"active","context_version":3,"last_activity_at":null},
         {"id":"\(acme.uuidString.lowercased())","name":"Old","kind":"goal","status":"archived","context_version":null,"last_activity_at":null}]
        """
        let contexts = try TaskforceJSON.decoder().decode([WorkContext].self, from: Data(rows.utf8))
        #expect(contexts.map(\.contextVersion) == [3, nil], "읽지 못한 version은 nil: 그 범위에는 쓰지 않는다")
        #expect(WorkContext.columns.contains("context_version"))
    }

    // MARK: 요청 (v2 경로 · 조건 · 본문)

    @Test func addAndRemoveGoToTheContextMembersRouteWithAVersionCondition() async throws {
        let api = client(body: ContextContractFixtures.write(ctx: shape, action: action, version: 5))
        _ = try await api.changeContextMember(contextID: shape, op: .add, actionID: action, expectedVersion: 4)
        #expect(last?.url.path == "/api/v2/contexts/\(shape.lowercased)/members" && last?.method == "POST")
        #expect(last?.headers["Authorization"] == "Bearer token-123")
        #expect(try json(last?.body) as NSDictionary == [
            "op": "add", "member_kind": "action", "member_id": action.lowercased, "expected_context_version": 4,
        ])
        _ = try await api.changeContextMember(contextID: shape, op: .remove, actionID: action, expectedVersion: 7)
        let removeBody = try json(last?.body)
        #expect(removeBody["op"] as? String == "remove" && removeBody["expected_context_version"] as? Int == 7)
    }

    /// 경로 = 도착 범위. 두 범위의 version 조건이 모두 간다. 전체 교체 키는 없다
    @Test func moveGoesToTheDestinationWithBothVersions() async throws {
        let api = client(body: ContextContractFixtures.move(from: shape, to: acme, action: action, fromVersion: 3, toVersion: 5))
        _ = try await api.moveContextMember(actionID: action, from: shape, to: acme, expectedToVersion: 4, expectedFromVersion: 2)
        #expect(last?.url.path == "/api/v2/contexts/\(acme.lowercased)/members/move" && last?.method == "POST")
        #expect(try json(last?.body) as NSDictionary == [
            "member_kind": "action", "member_id": action.lowercased, "from_context_id": shape.lowercased,
            "expected_context_version": 4, "expected_from_context_version": 2,
        ])
    }

    /// 멤버십 쓰기는 이 두 경로뿐이다: 실행 · 승인 · 정책 · run 경로를 부르지 않는다 (D13)
    @Test func membershipWritesNeverTouchExecutionPaths() async throws {
        let api = client(body: ContextContractFixtures.write(ctx: shape, action: action, version: 5))
        _ = try await api.changeContextMember(contextID: shape, op: .add, actionID: action, expectedVersion: 4)
        let moveApi = client(body: ContextContractFixtures.move(from: shape, to: acme, action: action, fromVersion: 3, toVersion: 5))
        _ = try await moveApi.moveContextMember(actionID: action, from: shape, to: acme, expectedToVersion: 4, expectedFromVersion: 2)
        let paths = StubProtocol.requests(host: host).map(\.url.path)
        #expect(paths.allSatisfy { $0.hasPrefix("/api/v2/contexts/") && ($0.hasSuffix("/members") || $0.hasSuffix("/members/move")) })
        for forbidden in ["runs", "approve", "start", "progress", "policy", "handoff", "confirm", "actions"] {
            #expect(paths.allSatisfy { !$0.contains(forbidden) }, "\(forbidden)")
        }
    }

    // MARK: 오류

    @Test func errorsMapToWhatTheServerMeans() async throws {
        func failure(_ status: Int, _ code: String, _ message: String) async -> APIError? {
            let api = client(status: status, body: ChatContractFixtures.error(code, message))
            do {
                _ = try await api.changeContextMember(contextID: shape, op: .add, actionID: action, expectedVersion: 1)
                return nil
            } catch { return error as? APIError }
        }
        let gate = try #require(await failure(404, "not_found", "없는 경로입니다."))
        #expect(gate.isFeatureOff && !gate.isMissingContext && !gate.isMissingAction)
        let context = try #require(await failure(404, "not_found", "범위가 없습니다."))
        #expect(context.isMissingContext && !context.isFeatureOff, "보관된 범위도 같은 404다")
        let work = try #require(await failure(404, "not_found", "할 일이 없습니다."))
        #expect(work.isMissingAction && !work.isMissingContext && !work.isFeatureOff)
        let conflict = try #require(await failure(409, "conflict", "그 사이 범위가 바뀌었습니다. 다시 불러온 뒤 시도해 주세요."))
        #expect(conflict.isConflict)
        // 409는 내 요청이 적용됐다는 뜻이 아니다 (사용자에게는 "다른 곳에서 바뀜 · 다시 읽음")
        #expect(conflict.userMessage == "This changed somewhere else. It's been refreshed.")
    }

    // MARK: 읽기 질의 (RLS 본인 행)

    @Test func membersAreReadWithTheNowMemberFilterAndOnlyActionMembers() async throws {
        let readHost = "ctx-\(UUID().uuidString.lowercased()).supabase.test"
        ChatReadStub.configure(host: readHost, rows: [
            "context_members": "[\(ContextContractFixtures.memberJSON(id: 1, ctx: shape, action: action, origin: "auto")), \(ContextContractFixtures.memberJSON(id: 2, ctx: acme, action: action, origin: "inferred", confidence: "0.4"))]",
        ])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChatReadStub.self]
        let reads = TaskforceReads(supabase: ChatReadsTests.supabase(host: readHost, configuration: configuration))
        let members = try await reads.contextMembers()
        #expect(members.map(\.origin) == [.auto, .inferred] && members.map(\.confidence) == [nil, 0.4])
        let request = try #require(ChatReadStub.requests(host: readHost).last)
        #expect(request.path == "/rest/v1/context_members")
        let q = Dictionary(request.query.compactMap { item in item.value.map { (item.name, $0) } }, uniquingKeysWith: { first, _ in first })
        #expect(q["removed_at"] == "is.null" && q["member_kind"] == "eq.action", "지금 멤버 = removed_at is null, 할 일 멤버만")
        #expect(q["select"] == ContextMember.columns.replacingOccurrences(of: " ", with: "") && q["select"]?.contains("origin") == true && q["select"]?.contains("confidence") == true)
        #expect(q["origin"] == nil, "origin으로 거르지 않는다: 확인된 멤버 / 후보 구분은 읽은 뒤 앱 규칙이 한다")
    }
}

extension ChatReadsTests {
    static func supabase(host: String, configuration: URLSessionConfiguration) -> SupabaseClient {
        SupabaseClient(
            supabaseURL: URL(string: "https://\(host)")!, supabaseKey: "test-public-key",
            options: SupabaseClientOptions(
                auth: .init(storage: ChatEmptyAuthStorage(), autoRefreshToken: false),
                global: .init(session: URLSession(configuration: configuration))
            )
        )
    }
}
