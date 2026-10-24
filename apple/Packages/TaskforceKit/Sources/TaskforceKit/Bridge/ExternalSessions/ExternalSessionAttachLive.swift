#if os(macOS)
import Foundation
import Supabase

// 이어받기 흐름이 실제 서버 · 이 Mac에서 읽는 것들 (OA 외부 세션 PR2m). 서버 변경 없이 기존 읽기(RLS select · 대상 목록 · 이어받기 route)만 쓴다.

/// `agent_sessions` 행 중 이어받기 확정이 대조하는 세 칸 (열 권한은 `AgentSessionRecord.columns`와 같다)
private struct AttachedSessionRow: Decodable {
    let id: UUID
    let connectionID: UUID
    let externalSessionID: String

    enum CodingKeys: String, CodingKey {
        case id
        case connectionID = "connection_id"
        case externalSessionID = "external_session_id"
    }
}

extension TaskforceReads {
    /// 이어받기 응답이 가리킨 세션 행을 RLS로 읽는다: 연결과 외부 세션 id (서버 응답의 `session`에는 외부 id가 없다, 계약 20장 2). 읽지 못했거나 행이 없으면 nil — 부른 쪽이 거절한다
    public func attachedSessionBinding(id: UUID) async -> (connectionID: UUID, externalSessionID: String)? {
        guard let found: [AttachedSessionRow] = try? await rows(
            supabase.from("agent_sessions").select("id, connection_id, external_session_id").eq("id", value: id.lowercased).limit(1)
        ), let row = found.first, row.id == id else { return nil }
        return (row.connectionID, row.externalSessionID)
    }
}

extension AssistantTargetsStore {
    /// 이 Mac의 Claude Code 대상 (대상 목록에서 `bridge_id`가 이 Mac인 Claude Code 연결). 목록을 새로 읽는다.
    /// 읽지 못했으면 nil(모른다). 이 Mac의 연결이 없으면 `connectionID: nil` + "Not connected". 연결이 있고 `ready`가 아니면 그 대상 단어(Offline · Sign in needed · Unsupported), `ready`면 단어 없음
    public func attachTarget(bridgeID: UUID) async -> ExternalSessionAttachTarget? {
        await refresh()
        guard load == .loaded else { return nil }
        for case .agent(let agent) in targets where agent.adapter == ClaudeCodeSupport.adapterID && agent.bridgeID == bridgeID {
            guard let connection = agent.connectionID else { continue }
            let word = agent.state == .ready ? nil : (AssistantTargetRules.statusWord(state: agent.state, access: agent.access) ?? AgentCopy.notConnected)
            return ExternalSessionAttachTarget(connectionID: connection, word: word)
        }
        return ExternalSessionAttachTarget(connectionID: nil, word: AgentCopy.notConnected)
    }
}

extension ExternalSessionAttachServer {
    /// 실제 앱의 면: 사용자 토큰으로 이어받기 route · 서버 열림 확인, RLS로 세션 행 읽기, 대상 목록. bridge id는 이 Mac의 런타임이 준다 (등록 전이면 nil)
    public static func live(
        api: APIClient, reads: TaskforceReads, targets: AssistantTargetsStore, bridgeID: @escaping @Sendable () async -> UUID?
    ) -> ExternalSessionAttachServer {
        ExternalSessionAttachServer(
            bridgeID: bridgeID,
            availability: { await api.agentAttachAvailability() },
            target: { bridge in await targets.attachTarget(bridgeID: bridge) },
            attach: { bridge, adapter, id, ref in try await api.attachAgentSession(bridgeID: bridge, adapter: adapter, externalSessionID: id, workspaceRef: ref) },
            readSession: { id in await reads.attachedSessionBinding(id: id) }
        )
    }
}
#endif
