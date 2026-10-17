import Foundation

// OA D4b-m-1 (D4bm-60 · 61 · 62): 질문이 열리면 그 세션의 Mac이 **로컬 알림**을 보낸다. 서버 원격 알림(APNs)은 없다 — 같은 사용자의 Mac 여럿이 같은 알림을 겹쳐 보내지 않는다
// (비밀값은 그 Mac에서만 답한다). 글은 상태 + 열 곳뿐이다: 제목은 에이전트 이름, 본문은 "Needs your answer"(승인됨). 질문 글 · 이슈 제목 · 세션 이름 · 경로 · 선택지는 싣지 않는다 (DS: "Notifications carry
// a short status and a deep link only, never source text or messages"). userInfo에는 id만 있다. 이 파일은 알림을 보내지 않는다 (Mac의 `AgentNotifications`가 시스템 센터에 건다).

/// 알림 하나의 내용
public struct AgentNotificationPlan: Equatable, Sendable {
    /// 알림 id = 질문 version. 같은 질문은 한 번만 보인다 (같은 id는 센터가 덮어쓴다)
    public let id: String
    public let title: String
    public let body: String
    /// 누르면 열 곳을 알려 주는 값 (id뿐): `NotificationTarget(userInfo:)`가 읽는다
    public let userInfo: [String: String]
}

public enum AgentQuestionNotifications {
    /// userInfo의 `kind` 값 (`NotificationTarget`이 읽는다)
    public static let kind = "agent_question"

    /// 알림 id: 질문 version마다 하나 (`provider_request_id`는 해시로만 쓴다)
    public static func identifier(for key: AgentQuestionKey) -> String {
        "agent-question:\(key.taskID.uuidString.lowercased()):\(AgentQuestionRules.requestDigest(key.requestID))"
    }

    /// 새 질문 → 알림 내용. 제목이 비면(에이전트 이름을 모르면) 앱 이름을 쓴다. 본문은 승인된 "Needs your answer"다 (`AgentQuestionUnapprovedCopy.approved`, 값이 없으면 비어 있다)
    public static func plan(for opened: AgentQuestionOpened, copy: AgentQuestionUnapprovedCopy = AgentQuestionNewCopy.active) -> AgentNotificationPlan {
        AgentNotificationPlan(
            id: identifier(for: opened.key), title: opened.agentName.isEmpty ? "Taskforce" : opened.agentName, body: copy.questionNotificationBody ?? "",
            userInfo: ["kind": kind, "session_id": opened.sessionID.uuidString.lowercased(), "task_id": opened.key.taskID.uuidString.lowercased()]
        )
    }

    /// 보낼까: 권한이 허용돼 있고, 그 카드가 지금 키 표면에 보이지 않을 때만. 거절했거나 아직 안 물었으면 조용히 보내지 않는다 (질문 순간에 시스템 창을 띄우지 않는다)
    public static func shouldPost(permission: PushPermission.Status, isVisibleOnKeySurface: Bool) -> Bool {
        permission == .allowed && !isVisibleOnKeySurface
    }

    /// 이 Mac에 묶인 에이전트 연결이 있으면 "연결"로 센다: 시스템 권한은 그 뒤 한 번만 묻는다 (`PushPermission.shouldRequest`를 그대로 쓴다)
    public static func shouldRequestPermission(status: PushPermission.Status, signedIn: Bool, hasThisMacConnection: Bool, isPresentingOther: Bool) -> Bool {
        PushPermission.shouldRequest(status: status, signedIn: signedIn, hasConnections: hasThisMacConnection, isPresentingOther: isPresentingOther)
    }
}
