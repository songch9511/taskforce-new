import Foundation
import Testing
@testable import TaskforceKit

/// 서버 JSON 계약 (서버 head `7328e93`): 응답 해석 · 요청 본문 · v2 경로 · 오류 코드. 서버 모양이 바뀌면 여기서 먼저 깨진다
struct ChatContractTests {
    let host = "t\(UUID().uuidString.lowercased().prefix(8)).test"

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

    // MARK: 응답 해석

    @Test func fixturePinsTheServerHead() {
        #expect(ChatContractFixtures.serverHead.hasPrefix("7328e93"))
        #expect(ChatContractFixtures.serverBase.hasPrefix("aa017bd"))
    }

    @Test func confirmedItemDecodesTheNewCurrentRow() throws {
        let item = try TaskforceJSON.decoder().decode(MemoryItemResponse.self, from: Data(ChatContractFixtures.confirmed.utf8)).item
        #expect(item.id == ChatContractFixtures.id(2))
        #expect(item.origin == .explicit && item.scopeKind == .context && item.contextID == ChatContractFixtures.contextID)
        #expect(item.statement == "출시는 목요일인 듯")
        #expect(item.sourceRef?.sourceID == ChatContractFixtures.sourceID && item.sourceRef?.quote == "출시는 목요일")
        #expect(item.isCurrent && !item.isUnconfirmedInference && item.version == 1)
    }

    @Test func forgottenItemIsNotCurrentButStillReadable() throws {
        let item = try TaskforceJSON.decoder().decode(MemoryItemResponse.self, from: Data(ChatContractFixtures.forgotten.utf8)).item
        #expect(item.revokedAt != nil && !item.isCurrent && item.version == 2)
    }

    /// 옮긴 행은 `value.moved_from`이 옛 행 id다 (정정 `superseded_*`와 다르다)
    @Test func movedItemPointsAtItsSource() throws {
        let item = try TaskforceJSON.decoder().decode(MemoryItemResponse.self, from: Data(ChatContractFixtures.moved.utf8)).item
        #expect(item.movedFrom == ChatContractFixtures.id(1))
        #expect(item.supersededAt == nil && item.isCurrent)
    }

    @Test func postedPairDecodesMessagesCitationsAndRemembered() throws {
        let memory = ChatContractFixtures.id(2)
        let body = ChatContractFixtures.posted(clientMessageID: UUID(), memory: [memory])
        let posted = try TaskforceJSON.decoder().decode(ChatPostedMessage.self, from: Data(body.utf8))
        #expect(posted.message.role == .user && posted.reply.role == .assistant)
        #expect(posted.reply.replyTo == posted.message.id)
        #expect(posted.reply.rememberedIDs == [memory])
        #expect(posted.reply.refs.contextIDs == [ChatContractFixtures.contextID])
        let citation = try #require(posted.reply.content?.citations.first)
        #expect(citation.quote == "Ship on Thursday" && citation.sourceTitle == "Launch brief")
        #expect(citation.externalURL?.host == "www.notion.so")
        #expect(posted.message.clientMessageID != nil)
    }

    /// 모르는 값은 목록 전체를 못 읽게 하지 않는다 (가장 덜 주장하는 쪽으로)
    @Test func unknownValuesDoNotBreakDecoding() throws {
        let row = ChatContractFixtures.forgotten
            .replacingOccurrences(of: "\"origin\":\"explicit\"", with: "\"origin\":\"telepathy\"")
            .replacingOccurrences(of: "\"scope_kind\":\"global\"", with: "\"scope_kind\":\"galaxy\"")
        let item = try TaskforceJSON.decoder().decode(MemoryItemResponse.self, from: Data(row.utf8)).item
        #expect(item.origin == .other("telepathy") && item.scopeKind == .other("galaxy"))
        // 확인은 줄 수 없고(추정만), 범위는 옮길 수 없다
        #expect(!MemoryText.canConfirm(item) && !MemoryText.canChangeScope(item))
        #expect(MemoryText.kind(item.origin) == "Telepathy")
    }

    // MARK: 요청 (v2 경로 · 본문)

    @Test func everyChatAndMemoryWriteGoesToV2() async throws {
        let id = ChatContractFixtures.id(1)
        let api = client(body: ChatContractFixtures.confirmed)
        _ = try await api.confirmMemory(id: id, expectedVersion: 3)
        #expect(last?.url.path == "/api/v2/memory/\(id.lowercased)/confirm")
        #expect(last?.method == "POST")
        #expect(try json(last?.body) as NSDictionary == ["expected_version": 3])

        _ = try await api.forgetMemory(id: id, expectedVersion: 4)
        #expect(last?.url.path == "/api/v2/memory/\(id.lowercased)/forget")

        _ = try await api.editMemory(id: id, edit: MemoryEdit(expectedVersion: 1, statement: "배포는 목요일"))
        #expect(last?.url.path == "/api/v2/memory/\(id.lowercased)")
        #expect(last?.method == "PATCH")

        _ = try await api.moveMemory(id: id, expectedVersion: 2, to: .global)
        #expect(last?.url.path == "/api/v2/memory/\(id.lowercased)/scope")
        #expect(last?.headers["Authorization"] == "Bearer token-123")
    }

    @Test func moveBodySendsScopeKindAndContext() async throws {
        let id = ChatContractFixtures.id(1)
        let api = client(body: ChatContractFixtures.moved)
        _ = try await api.moveMemory(id: id, expectedVersion: 1, to: .context(ChatContractFixtures.contextID))
        #expect(try json(last?.body) as NSDictionary == [
            "expected_version": 1, "scope_kind": "context", "context_id": ChatContractFixtures.contextID.lowercased,
        ])
        // 전체로: context_id를 보내지 않는다 (서버가 null로 읽는다)
        _ = try await api.moveMemory(id: id, expectedVersion: 1, to: .global)
        #expect(try json(last?.body) as NSDictionary == ["expected_version": 1, "scope_kind": "global"])
    }

    /// 정정 요청: `value`는 생략 = 옛 값 상속, 비우려면 `{}` (`null`은 서버가 400), `valid_*`만 `null` = 비움
    @Test func editBodyNeverSendsNullValue() throws {
        func body(_ edit: MemoryEdit) throws -> [String: Any] {
            let data = try TaskforceJSON.encoder().encode(edit)
            return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        let inherit = try body(MemoryEdit(expectedVersion: 1, statement: "배포는 목요일"))
        #expect(Set(inherit.keys) == ["expected_version", "statement"])
        #expect(inherit["value"] == nil)

        let cleared = try body(MemoryEdit(expectedVersion: 1, statement: "x", value: .clear))
        #expect((cleared["value"] as? [String: Any])?.isEmpty == true)
        #expect(!(cleared["value"] is NSNull))

        let replaced = try body(MemoryEdit(expectedVersion: 1, statement: "x", value: .set(["day": .string("thu")])))
        #expect((replaced["value"] as? [String: String]) == ["day": "thu"])

        let dates = try body(MemoryEdit(expectedVersion: 2, statement: "x", validFrom: .clear, validUntil: .set("2026-10-20T00:00:00+09:00")))
        #expect(dates["valid_from"] is NSNull)
        #expect(dates["valid_until"] as? String == "2026-10-20T00:00:00+09:00")
        #expect(dates["value"] == nil)
    }

    @Test func conversationWritesCarryTheClientChosenIDs() async throws {
        let conversationID = ChatContractFixtures.conversationID
        let api = client(status: 201, body: ChatContractFixtures.conversation)
        let created = try await api.createConversation(id: conversationID, title: "Pricing FAQ")
        #expect(created.id == conversationID && created.contextID == ChatContractFixtures.contextID)
        #expect(last?.url.path == "/api/v2/conversations")
        #expect(try json(last?.body) as NSDictionary == ["id": conversationID.lowercased, "title": "Pricing FAQ", "context_id": NSNull()])

        _ = try await api.updateConversation(id: conversationID, contextID: nil)
        #expect(last?.url.path == "/api/v2/conversations/\(conversationID.lowercased)")
        #expect(last?.method == "PATCH")
        #expect(try json(last?.body) as NSDictionary == ["context_id": NSNull()])

        _ = try await api.updateConversation(id: conversationID, contextID: ChatContractFixtures.contextID)
        #expect(try json(last?.body) as NSDictionary == ["context_id": ChatContractFixtures.contextID.lowercased])
    }

    @Test func postedMessageSendsTheSameSubmissionIDAndWaitsForTheAnswer() async throws {
        let cmid = UUID()
        let api = client(body: ChatContractFixtures.posted(clientMessageID: cmid))
        let posted = try await api.postChatMessage(conversationID: ChatContractFixtures.conversationID, clientMessageID: cmid, text: "Use the shorter FAQ")
        #expect(posted.message.clientMessageID == cmid)
        #expect(last?.url.path == "/api/v2/conversations/\(ChatContractFixtures.conversationID.lowercased)/messages")
        #expect(try json(last?.body) as NSDictionary == ["client_message_id": cmid.lowercased, "text": "Use the shorter FAQ"])
        // 서버는 모델 호출까지 60초 기다린다
        #expect((last?.timeout ?? 0) >= 65)
    }

    /// v1 경로는 그대로다 (동결)
    @Test func v1RequestsStayOnV1() async throws {
        let api = client(body: #"{"now":[],"confirmations":[],"weekly_check":null}"#)
        _ = try await api.now()
        #expect(last?.url.path == "/api/v1/now")
    }

    // MARK: 오류

    @Test func v2ReasonCodesAreNotMistakenForConflicts() async throws {
        let confirm = client(status: 409, body: ChatContractFixtures.error("confirm_unavailable"))
        do {
            _ = try await confirm.confirmMemory(id: UUID(), expectedVersion: 1)
            Issue.record("성공으로 읽힘")
        } catch let error as APIError {
            #expect(error.isConfirmUnavailable && !error.isConflict && !error.isScopeUnavailable)
        }
        let scopeAPI = client(status: 409, body: ChatContractFixtures.error("scope_unavailable"))
        do {
            _ = try await scopeAPI.moveMemory(id: UUID(), expectedVersion: 1, to: .global)
            Issue.record("성공으로 읽힘")
        } catch let error as APIError {
            #expect(error.isScopeUnavailable && !error.isConflict && !error.isConfirmUnavailable)
        }
        // version 충돌은 conflict
        let conflict = client(status: 409, body: ChatContractFixtures.error("conflict", "그 사이 기억이 바뀌었습니다."))
        do {
            _ = try await conflict.forgetMemory(id: UUID(), expectedVersion: 1)
            Issue.record("성공으로 읽힘")
        } catch let error as APIError {
            #expect(error.isConflict && !error.isConfirmUnavailable && !error.isChatConsentRequired)
        }
    }

    /// gate 꺼짐(404 "없는 경로입니다.")은 없는 대화 · 기억(다른 404)과 다르다 — 기능 꺼짐을 실패로 꾸미지 않는다
    @Test func featureOffIsNotMissingTargetOrFailure() async throws {
        let off = client(status: 404, body: ChatContractFixtures.error("not_found", "없는 경로입니다."))
        do {
            _ = try await off.createConversation(id: UUID(), title: nil)
            Issue.record("성공으로 읽힘")
        } catch let error as APIError {
            #expect(error.isFeatureOff && !error.isMissingTarget)
        }
        let missing = client(status: 404, body: ChatContractFixtures.error("not_found", "기억이 없습니다."))
        do {
            _ = try await missing.forgetMemory(id: UUID(), expectedVersion: 1)
            Issue.record("성공으로 읽힘")
        } catch let error as APIError {
            #expect(error.isMissingTarget && !error.isFeatureOff)
        }
        // route가 없는 옛 서버의 HTML 404도 기능 꺼짐
        #expect(APIError.unexpectedStatus(404).isFeatureOff)
        #expect(!APIError.unexpectedStatus(500).isFeatureOff)
    }

    /// 메시지 보내기의 409: 동의 전만 메시지로 가른다 (나머지는 서버가 다시 읽어 맞춘다)
    @Test func chatConsentIsTheOnlyConflictTheAppCanNameByMessage() async throws {
        let consent = client(status: 409, body: ChatContractFixtures.error("conflict", "외부 AI 처리 동의가 필요해요."))
        do {
            _ = try await consent.postChatMessage(conversationID: UUID(), clientMessageID: UUID(), text: "hi")
            Issue.record("성공으로 읽힘")
        } catch let error as APIError {
            #expect(error.isChatConsentRequired && error.isConflict)
        }
        let inProgress = client(status: 409, body: ChatContractFixtures.error("conflict", "같은 메시지를 처리하고 있습니다."))
        do {
            _ = try await inProgress.postChatMessage(conversationID: UUID(), clientMessageID: UUID(), text: "hi")
            Issue.record("성공으로 읽힘")
        } catch let error as APIError {
            #expect(!error.isChatConsentRequired && error.isConflict)
        }
    }
}
