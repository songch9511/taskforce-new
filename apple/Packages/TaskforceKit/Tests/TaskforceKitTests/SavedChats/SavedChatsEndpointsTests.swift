import Foundation
import Testing
@testable import TaskforceKit

/// 저장된 대화를 지우는 두 route (D3v-m): `DELETE /api/v2/claude-app-chats/{id}`(늘 열려 있다)와 새 `DELETE /api/v2/claude-app-chats`(모두 지우기, 다른 작업자가 병렬로 만든다).
/// 모두 가짜 서버다. 모두 지우기의 답 모양은 모르므로 **어떤 모양이든 실패하지 않는다**
@MainActor
struct SavedChatsEndpointsTests {
    typealias S = SavedChatSamples
    private let one = "DELETE /api/v2/claude-app-chats/\(S.chatA.uuidString.lowercased())"
    private let all = "DELETE /api/v2/claude-app-chats"

    // MARK: 하나 지우기

    @Test func deleteOneIsADeleteOnTheV2RouteWithTheBearerAndNoBody() async throws {
        let rig = SavedChatsRig(routes: [one: [.noContent]])
        try await rig.api.deleteClaudeAppChat(id: S.chatA)
        let sent = try #require(rig.requests.last)
        #expect(sent.method == "DELETE" && sent.path == "/api/v2/claude-app-chats/\(S.chatA.uuidString.lowercased())")
        #expect(sent.headers["Authorization"] == "Bearer token-123" && sent.headers["Content-Type"] == nil)
    }

    @Test func deleteOneKeepsTheStatusAndCodeOfFailuresSoTheStoreCanTellThemApart() async {
        for (status, code) in [(404, "not_found"), (409, "busy_retry"), (500, "internal_error"), (401, "unauthorized")] {
            let rig = SavedChatsRig(routes: [one: [.error(status, code: code)]])
            do {
                try await rig.api.deleteClaudeAppChat(id: S.chatA)
                Issue.record("\(status)인데 던지지 않았다")
            } catch let error as APIError {
                #expect(error.status == status, "\(status) \(code)")
            } catch {
                Issue.record("\(error)")
            }
        }
    }

    // MARK: 모두 지우기: 답 모양에 기대지 않는다

    @Test func deleteAllIsADeleteOnTheCollectionRouteWithTheExplicitAllMarkerAndReadsTheDeletedCountWhenThereIsOne() async throws {
        let rig = SavedChatsRig(routes: [all: [.rows(#"{"deleted":3}"#)]])
        let count = try await rig.api.deleteAllClaudeAppChats()
        #expect(count == 3)
        let sent = try #require(rig.requests.last)
        #expect(sent.method == "DELETE" && sent.path == "/api/v2/claude-app-chats" && sent.headers["Authorization"] == "Bearer token-123")
        #expect(sent.query == ["all": "true"], "서버는 `?all=true` 표시가 없으면 400이다: \(sent.query)")
        #expect(sent.headers["Content-Type"] == nil, "본문 없음")
    }

    @Test func anEmptyAccountAnswersZeroAndThatIsSuccess() async throws {
        let rig = SavedChatsRig(routes: [all: [.rows(#"{"deleted":0}"#)]])
        #expect(try await rig.api.deleteAllClaudeAppChats() == 0)
    }

    @Test func deleteOneNeverCollapsesIntoTheCollectionRouteOrCarriesTheAllMarker() async throws {
        // 주소는 비어 있지 않은 UUID 값으로만 만든다: 빈 id는 모두 지우기 길이 된다
        for id in [S.chatA, UUID(uuidString: "00000000-0000-0000-0000-000000000000")!, UUID()] {
            let rig = SavedChatsRig(routes: ["DELETE /api/v2/claude-app-chats/\(id.uuidString.lowercased())": [.noContent]])
            try await rig.api.deleteClaudeAppChat(id: id)
            let sent = try #require(rig.requests.last)
            #expect(sent.path != "/api/v2/claude-app-chats" && sent.path.hasPrefix("/api/v2/claude-app-chats/") && sent.path.split(separator: "/").last?.count == 36)
            #expect(sent.query.isEmpty, "하나 지우기에는 all 표시가 붙지 않는다: \(sent.query)")
        }
    }

    @Test func deleteAllToleratesEveryAnswerShape() async throws {
        let shapes: [(SavedChatsFakeServer.Reply, Int?)] = [
            (.noContent, nil), (.rows("{}"), nil), (.rows(""), nil), (.rows("not json at all"), nil), (.rows("[]"), nil), (.rows(#"{"deleted":"3"}"#), nil),
            (.rows(#"{"deleted":{"chats":3}}"#), nil), (.rows(#"{"deleted":-1}"#), nil), (.rows(#"{"deleted":0}"#), 0), (.rows(#"{"deleted":12,"extra":true}"#), 12), (.rows("null"), nil),
        ]
        for (reply, expected) in shapes {
            let rig = SavedChatsRig(routes: [all: [reply]])
            let count = try await rig.api.deleteAllClaudeAppChats()
            #expect(count == expected, "\(reply.status) \(reply.body)")
        }
    }

    @Test func deleteAllFailuresThrowWithTheirStatus() async {
        // 서버 계약: 401 · 429(Retry-After) · 409 busy_retry · 500은 아무것도 지우지 못한 실패, `all=true`가 없으면 400. 404는 오지 않는다 (와도 실패다)
        for (status, code) in [(400, "invalid_request"), (401, "unauthorized"), (404, "not_found"), (409, "busy_retry"), (429, "rate_limited"), (500, "internal_error")] {
            let rig = SavedChatsRig(routes: [all: [.error(status, code: code)]])
            do {
                _ = try await rig.api.deleteAllClaudeAppChats()
                Issue.record("\(status)인데 던지지 않았다")
            } catch let error as APIError {
                #expect(error.status == status)
            } catch {
                Issue.record("\(error)")
            }
        }
    }

    // MARK: 실제 연결로 만든 저장소

    @Test func theLiveStoreDeletesOneAndAllThroughTheRightRoutes() async throws {
        let rig = SavedChatsRig(routes: [
            "GET /rest/v1/claude_app_chats": [.rows("[\(S.chatJSON(1))]"), .rows("[]")],
            "GET /rest/v1/bridges": [.rows("[]")],
            "DELETE /api/v2/claude-app-chats/\(S.id(1).uuidString.lowercased())": [.error(409, code: "busy_retry"), .noContent],
            all: [.rows(#"{"deleted":1}"#)],
        ])
        let scope = AccountScope(currentAccount: { S.id(999) })
        let store = SavedChatsLive.store(reads: rig.reads, api: rig.api, thisMac: { nil }, scope: scope)
        await store.refresh()
        #expect(store.rows.count == 1)
        #expect(await store.delete(S.id(1)) == .deleted, "409 busy_retry는 한 번 조용히 다시 보낸다")
        #expect(rig.requests.filter { $0.method == "DELETE" }.count == 2)
        await store.deleteAllChats()
        #expect(rig.requests.last?.line == "DELETE /api/v2/claude-app-chats" && rig.requests.last?.query == ["all": "true"] && store.deleteAllState == .idle)
    }
}
