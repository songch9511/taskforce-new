import Foundation
import Supabase

// Settings › Your agents › Macs (이 계정의 Mac이 10대일 때, OA Settings › Your agents 6.4): `bridges`를 RLS로 읽어 active Mac만, 마지막으로 본 때가 오래된 순으로 보인다.
// 읽는 열은 `id · device_name · last_heartbeat_at · app_version`뿐이다 (`secret_hash` · `heartbeat_result`는 열 권한이 막는다). 이름은 표시용 글자다 — 어떤 판정 · 조인 · 열쇠에도 쓰지 않는다.

/// 이 계정의 Mac 하나 (`bridges` 행)
public struct AgentMacRecord: Decodable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let deviceName: String?
    public let lastHeartbeatAt: Date?
    public let appVersion: String?

    public init(id: UUID, deviceName: String?, lastHeartbeatAt: Date?, appVersion: String? = nil) {
        self.id = id
        self.deviceName = deviceName
        self.lastHeartbeatAt = lastHeartbeatAt
        self.appVersion = appVersion
    }

    public static let columns = "id, device_name, last_heartbeat_at, app_version"

    enum CodingKeys: String, CodingKey {
        case id
        case deviceName = "device_name"
        case lastHeartbeatAt = "last_heartbeat_at"
        case appVersion = "app_version"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        deviceName = try c.decodeIfPresent(String.self, forKey: .deviceName)
        appVersion = try c.decodeIfPresent(String.self, forKey: .appVersion)
        // 날짜는 읽을 수 있는 모양이 아니면 모르는 것으로 둔다 (한 행이 목록을 막지 않는다)
        if let raw = try c.decodeIfPresent(String.self, forKey: .lastHeartbeatAt) {
            lastHeartbeatAt = PostgresTimestamp.parse(raw)
        } else {
            lastHeartbeatAt = nil
        }
    }
}

/// Macs 목록의 규칙 (순수)
public enum AgentSettingsMacs {
    /// 보이는 Mac들: 이 Mac은 뺀다 (10대 안에 이 Mac이 없다 — 이 Mac은 `Disconnect this Mac`으로만 끊는다), 마지막으로 본 때가 오래된 순 (본 적 없는 Mac이 맨 위), 같으면 id 순
    public static func rows(_ records: [AgentMacRecord], excluding thisMac: UUID?) -> [AgentMacRecord] {
        records.filter { $0.id != thisMac }.sorted {
            switch ($0.lastHeartbeatAt, $1.lastHeartbeatAt) {
            case (nil, nil): $0.id.uuidString < $1.id.uuidString
            case (nil, _): true
            case (_, nil): false
            case (let a?, let b?): a == b ? $0.id.uuidString < $1.id.uuidString : a < b
            }
        }
    }

    /// 줄 이름: 이름이 없으면 "Mac" (짐작하지 않는다)
    public static func title(_ record: AgentMacRecord) -> String {
        record.deviceName.flatMap { $0.isEmpty ? nil : $0 } ?? AgentSettingsCopy.unnamedMac
    }

    /// 줄 설명 "Last seen 4 min ago". 본 적을 모르면 설명을 두지 않는다 (새 문구를 만들지 않는다)
    public static func detail(_ record: AgentMacRecord, now: Date = Date()) -> String? {
        record.lastHeartbeatAt.map { AgentSettingsCopy.lastSeen(WhenText.relative($0, now: now)) }
    }
}

extension TaskforceReads {
    /// 이 계정의 active Mac (RLS: 내 `bridges` 행만, 폐기된 Mac은 거른다)
    public func activeBridges() async throws -> [AgentMacRecord] {
        try await rows(supabase.from("bridges").select(AgentMacRecord.columns).eq("status", value: "active"))
    }
}
