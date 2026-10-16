#if os(macOS)
import CryptoKit
import Foundation

// View full의 원장 찾기 (OA D4a-17, DS Message "View full"): 서버는 에이전트 글을 20,000자 · 32KB에서 자르고 전문은 이 Mac의 원장(`full_texts`)에 둔다.
// 서버가 그 글 행에 붙인 열쇠(`conversation_messages.external_event_id`)는 `agent-message:<run_id>:<sha256 hex(bridge 사건 id)>`다
// (`20261116000000_agent_events.sql:416`: `'agent-message:' || v_run.id || ':' || encode(sha256(convert_to(event_id,'UTF8')),'hex')`).
// 원장 표는 바꾸지 않는다: 열쇠의 해시는 사건 id의 해시라서, 전문을 쥔 `full_texts`의 사건 id를 해시해 열쇠와 맞는 것의 전문을 읽는다 (task가 정리된 뒤에도 전문이 남는 동안 찾는다).
// 원장은 계정(파티션)마다 파일이 따로라 다른 계정의 전문은 찾아지지 않는다. 한 달 정리로 지워진 글 · 자르지 않은 글 · 이 Mac이 모르는 사건은 nil이다 (링크가 없다).
// run id는 원장에 없다: 사건 id가 task id를 담아 이미 유일하다.

extension BridgeLedger {
    private static let keyPrefix = "agent-message"

    /// 서버 열쇠 만들기 (`run_id`와 bridge 사건 id)
    public static func serverKey(runID: String, eventID: String) -> String {
        "\(keyPrefix):\(runID):\(sha256Hex(eventID))"
    }

    /// 서버 열쇠 읽기. `agent-message:<run id>:<소문자 hex 64자>` 꼴이 아니면 nil
    public static func parseServerKey(_ key: String) -> (runID: String, eventHash: String)? {
        let parts = key.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == keyPrefix, !parts[1].isEmpty, parts[2].count == 64,
              parts[2].utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }) else { return nil }
        return (parts[1], parts[2])
    }

    static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 서버 열쇠에 맞는 사건의 잘린 글 전문. 없으면 nil.
    /// 보관은 task 7일 · 전문 30일이라 task가 정리된 뒤(8–29일)에도 전문은 남는다: task를 세어 사건 id를 복원하지 않고 **`full_texts`의 사건 id를 직접** 해시해 맞춘다.
    /// (원장 본체의 비공개 연결은 건드리지 않는다: 같은 파일을 읽기 전용으로 따로 열어 사건 id 열만 읽는다 — WAL이라 쓰는 연결과 함께 읽을 수 있다. 글은 맞는 사건 하나만 읽는다)
    public func fullText(forServerKey key: String) async throws -> String? {
        guard let parsed = Self.parseServerKey(key) else { return nil }
        let reader = try SQLiteDatabase(path: fileURL.path, readOnly: true)
        defer { reader.close() }
        let eventIDs = try reader.rows("SELECT event_id FROM full_texts") { $0.requiredText(0) }
        guard let eventID = eventIDs.first(where: { Self.sha256Hex($0) == parsed.eventHash }) else { return nil }
        return try fullText(eventID: eventID)
    }
}
#endif
