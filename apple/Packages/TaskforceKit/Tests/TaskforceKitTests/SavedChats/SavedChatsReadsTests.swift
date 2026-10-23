import Foundation
import Testing
@testable import TaskforceKit

/// 저장된 대화의 직접 읽기 (D3v-m, 계약 27장 · `docs/agent-gateway.md` 22장): 두 표와 `bridges`의 `device_name`을 RLS로 읽는다. 열 · 순서 · 쪽(`range`) · 디코드 · 없는 표
struct SavedChatsReadsTests {
    typealias S = SavedChatSamples

    // MARK: 디코드

    @Test func aChatRowDecodesWithMicrosecondTimesAndANullTitle() async throws {
        let rig = SavedChatsRig(routes: ["GET /rest/v1/claude_app_chats": [.rows("[\(S.chatJSON(1, title: "Pricing copy draft")),\(S.chatJSON(2, title: nil))]")]])
        let records = try await rig.reads.savedChats(offset: 0, limit: 20)
        #expect(records.map(\.title) == ["Pricing copy draft", nil])
        #expect(records.first?.id == S.id(1) && records.first?.bridgeID == S.macOther)
        #expect(records.first?.lastMessageAt == PostgresTimestamp.parse("2026-10-22T09:41:05.123456+00:00"))
    }

    @Test func aMessageRowDecodesTheToolNamesTheTruncatedFlagAndTheOrderColumns() async throws {
        let json = "[\(S.messageJSON(1, role: "assistant", body: "Done **now**", tools: ["Read", "mcp__srv__tool"], seq: 7, truncated: true))]"
        let rig = SavedChatsRig(routes: ["GET /rest/v1/claude_app_chat_messages": [.rows(json)]])
        let records = try await rig.reads.savedChatMessages(chatID: S.chatA, offset: 0, limit: 40)
        let record = try #require(records.first)
        #expect(record.role == "assistant" && record.body == "Done **now**" && record.truncated && record.toolNames == ["Read", "mcp__srv__tool"] && record.seq == 7)
        #expect(record.saidAt == PostgresTimestamp.parse("2026-10-22T09:41:05+00:00"))
    }

    @Test func aMessageRowWithoutToolNamesOrTruncatedStillDecodes() async throws {
        let json = #"[{"id":"dddddddd-0000-4000-8000-000000000001","role":"user","body":"hi","said_at":"2026-10-22T09:41:05+00:00","seq":1}]"#
        let rig = SavedChatsRig(routes: ["GET /rest/v1/claude_app_chat_messages": [.rows(json)]])
        let record = try #require(try await rig.reads.savedChatMessages(chatID: S.chatA, offset: 0, limit: 40).first)
        #expect(record.toolNames.isEmpty && !record.truncated)
    }

    // MARK: 질의 모양

    @Test func theChatListIsNewestFirstPagedWithRangeAndReadsOnlyTheFourColumns() async throws {
        let rig = SavedChatsRig(routes: ["GET /rest/v1/claude_app_chats": [.rows("[]")]])
        _ = try await rig.reads.savedChats(offset: 20, limit: 20)
        let request = try #require(rig.requests.last)
        #expect(request.query["select"] == "id,bridge_id,title,last_message_at", "본문 · session_ref는 읽지 않는다: \(request.query)")
        #expect(request.query["order"]?.hasPrefix("last_message_at.desc") == true && request.query["order"]?.contains(",id.desc") == true, "새 대화가 위, 같은 시각은 id로: \(request.query)")
        #expect(request.query["offset"] == "20" && request.query["limit"] == "20", "한 번에 20개: \(request.query)")
    }

    @Test func theMessagesOfOneChatAreReadNewestFirstWithTheChatFilterAndRange() async throws {
        let rig = SavedChatsRig(routes: ["GET /rest/v1/claude_app_chat_messages": [.rows("[]")]])
        _ = try await rig.reads.savedChatMessages(chatID: S.chatA, offset: 40, limit: 40)
        let request = try #require(rig.requests.last)
        #expect(request.query["chat_id"] == "eq.\(S.chatA.uuidString.lowercased())")
        #expect(request.query["select"] == "id,role,body,truncated,tool_names,said_at,seq", "mac_ref · reply_to는 읽지 않는다: \(request.query)")
        #expect(request.query["order"]?.hasPrefix("said_at.desc") == true && request.query["order"]?.contains(",seq.desc") == true, "새 말이 먼저(쪽마다 거꾸로 이어 붙인다): \(request.query)")
        #expect(request.query["offset"] == "40" && request.query["limit"] == "40")
    }

    @Test func deviceNamesAreAskedByIdInChunksAndOnlyTheNameColumns() async throws {
        let ids = (0..<150).map { _ in UUID() }
        let json = #"[{"id":"\#(ids[0].uuidString.lowercased())","device_name":"Studio"},{"id":"\#(ids[1].uuidString.lowercased())","device_name":null}]"#
        let rig = SavedChatsRig(routes: ["GET /rest/v1/bridges": [.rows(json), .rows("[]")]])
        let names = try await rig.reads.savedChatDeviceNames(bridgeIDs: ids + [ids[0]])
        #expect(names == [ids[0]: "Studio"], "이름이 없는(null) Mac은 이름을 모르는 것이다")
        let requests = rig.requests.filter { $0.path == "/rest/v1/bridges" }
        #expect(requests.count == 2, "중복을 빼고 150개를 100개씩 두 번: \(requests.count)")
        for request in requests {
            #expect(request.query["select"] == "id,device_name", "secret_hash · heartbeat 열은 읽지 않는다")
            #expect(request.query["id"]?.hasPrefix("in.(") == true)
        }
    }

    @Test func askingForNoDeviceNamesReadsNothing() async throws {
        let rig = SavedChatsRig()
        #expect(try await rig.reads.savedChatDeviceNames(bridgeIDs: []).isEmpty)
        #expect(rig.requests.isEmpty)
    }

    // MARK: 합친 줄 (live 읽기)

    @Test func theLivePageJoinsDeviceNamesAndDropsTheNameOfThisMac() async throws {
        let rig = SavedChatsRig(routes: [
            "GET /rest/v1/claude_app_chats": [.rows("[\(S.chatJSON(1, title: "A", bridge: S.macThis)),\(S.chatJSON(2, title: nil, bridge: S.macOther))]")],
            "GET /rest/v1/bridges": [.rows(#"[{"id":"\#(S.macThis.uuidString.lowercased())","device_name":"This one"},{"id":"\#(S.macOther.uuidString.lowercased())","device_name":"Daniel's MacBook Pro"}]"#)],
        ])
        let page = SavedChatsLive.readPage(reads: rig.reads, thisMac: { S.macThis })
        let rows = try await page(0, 20)
        #expect(rows.map(\.deviceName) == [nil, "Daniel's MacBook Pro"], "이 Mac이 보낸 것은 기기 이름을 반복하지 않는다")
        #expect(rows.map(\.title) == ["A", nil])
    }

    @Test func aFailedDeviceNameReadDoesNotFailTheList() async throws {
        let rig = SavedChatsRig(routes: [
            "GET /rest/v1/claude_app_chats": [.rows("[\(S.chatJSON(1))]")],
            "GET /rest/v1/bridges": [.error(500, code: "internal_error")],
        ])
        let rows = try await SavedChatsLive.readPage(reads: rig.reads, thisMac: { nil })(0, 20)
        #expect(rows.count == 1 && rows.first?.deviceName == nil, "이름을 모르면 시각만 보인다")
    }

    // MARK: 서버 gate · 없는 표

    @Test func aMissingTableMeansNoSavedChatsNotAnError() async throws {
        for reply in [SavedChatsFakeServer.Reply.missingTable, .init(status: 404, body: #"{"code":"42P01","message":"relation does not exist"}"#)] {
            let rig = SavedChatsRig(routes: ["GET /rest/v1/claude_app_chats": [reply]])
            let rows = try await SavedChatsLive.readPage(reads: rig.reads, thisMac: { nil })(0, 20)
            #expect(rows.isEmpty, "마이그레이션 전 DB · 꺼진 서버에서는 절이 그냥 없다: \(reply.status) \(reply.body)")
        }
    }

    @Test func otherReadFailuresStayErrorsSoTheSectionCanSayCouldNotLoad() async {
        for reply in [SavedChatsFakeServer.Reply(status: 500, body: #"{"code":"XX000","message":"boom"}"#), .init(status: 401, body: #"{"message":"JWT expired"}"#)] {
            let rig = SavedChatsRig(routes: ["GET /rest/v1/claude_app_chats": [reply]])
            await #expect(throws: (any Error).self) { _ = try await SavedChatsLive.readPage(reads: rig.reads, thisMac: { nil })(0, 20) }
        }
    }

    @Test func aMissingMessagesTableIsAnEmptyChatSoThePanelClosesAsGone() async throws {
        let rig = SavedChatsRig(routes: ["GET /rest/v1/claude_app_chat_messages": [.missingTable]])
        let records = try await SavedChatsLive.readMessages(reads: rig.reads)(S.chatA, 0, 40)
        #expect(records.isEmpty)
    }
}
