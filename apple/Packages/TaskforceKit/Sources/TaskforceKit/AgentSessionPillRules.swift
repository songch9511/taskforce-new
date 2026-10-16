import Foundation

// 세션 알약을 어느 Mac에 보이나 (OA D4a-03, 계약 3.1): 터미널은 그 세션이 도는 Mac에서만 열 수 있다. 알약은 그 세션 연결의 `agent_connections.bridge_id`가 이 Mac의 bridge id와
// 같을 때만 보인다 — 서버 변경 없이 RLS로 읽는다. 다른 Mac이거나 `bridge_id`가 null이거나 이 Mac이 bridge를 켜지 않았으면 알약이 없다 (U2 규칙 "동작이 없으면 그리지 않는다").
// 알약의 종류 · 꺼진 이유는 U2의 `AgentSessionRules.pill`이 정한 그대로다.

extension AgentSessionRules {
    /// 이 세션이 이 Mac에서 도는가 (둘 다 알 때만 같다고 한다: 모르는 것을 같다고 하지 않는다)
    public static func isOnThisMac(_ item: AgentSessionItem, thisMacBridgeID: UUID?) -> Bool {
        guard let thisMacBridgeID, let bridgeID = item.connectionBridgeID else { return false }
        return bridgeID == thisMacBridgeID
    }

    /// 머리에 그릴 알약: U2의 알약이 있고 이 Mac의 세션일 때만
    public static func visiblePill(_ item: AgentSessionItem, thisMacBridgeID: UUID?) -> AgentSessionPill? {
        isOnThisMac(item, thisMacBridgeID: thisMacBridgeID) ? item.pill : nil
    }
}
