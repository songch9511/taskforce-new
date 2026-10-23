#if os(macOS)
import Foundation

/// 이어받은 세션을 다루는 adapter의 면 (OA 외부 세션 PR2m, 계약 6장 · 20장). 런타임이 **로컬 Resume here 확인**에서만 부르는 쓰기(`bindAttached`)와,
/// 명령 길이 읽는 값(`isAttached` · `attachedSince` · `externalHold`)을 나눈다. 모두 이 Mac의 세션 폴더 상태 · 메모리에서만 온다 — 서버가 준 값은 쓰지 않는다
public protocol AttachableSessionAdapter: AgentProcess {
    /// 세션 폴더 상태에 `origin: attached` · `bound = true` · 그 Claude id를 쓴다 (`ClaudeSessionState.writeAttached`: 이미 묶인 폴더를 다른 id로 덮지 않는다).
    /// 다른 agent 세션이 이미 같은 Claude id를 쥐고 있으면 쓰지 않는다 (한 Claude 세션에 writer 하나)
    func bindAttached(agentSessionID: String, providerSessionID: String, at: Date) async -> ClaudeSessionState.AttachWrite
    /// 이 agent 세션이 이 Mac의 로컬 Resume here로 이어받은 세션인가
    func isAttached(agentSession sessionID: String) async -> Bool
    /// 이어받은 시각 (이어받은 세션이 아니면 nil)
    func attachedSince(agentSession sessionID: String) async -> Date?
    /// 마지막으로 "다른 곳에서 쥐고 있어" 막았던 이유 (다음 검사가 통과하면 nil)
    func externalHold(forAgentSession sessionID: String) async -> ExternalWriterVerdict?
    /// 지금 그 Claude 세션을 쥔 곳이 있나: 턴마다 하는 검사와 같은 검사기로 본다 (이어받기 확인 직전의 판정)
    func probeExternalWriter(providerSessionID: String, workspace: String) async -> ExternalWriterVerdict
}

extension ClaudeCodeProcess: AttachableSessionAdapter {
    public func bindAttached(agentSessionID: String, providerSessionID: String, at date: Date) -> ClaudeSessionState.AttachWrite {
        guard !spawningStopped, ExternalSessionRules.isCanonicalUUID(providerSessionID),
              let folder = ClaudeSessionFolder.locate(sessionsRoot: sessionsRoot, agentSessionID: agentSessionID) else { return .refused }
        // 다른 agent 세션 폴더가 이미 이 Claude id를 쥐고 있으면 두 Taskforce 세션이 한 Claude 세션을 쓰게 된다: 덮지 않고 거절한다
        let siblings = (try? FileManager.default.contentsOfDirectory(at: sessionsRoot, includingPropertiesForKeys: nil)) ?? []
        for other in siblings where other.lastPathComponent != folder.root.lastPathComponent && UUID(uuidString: other.lastPathComponent) != nil {
            if ClaudeSessionState.load(from: other).providerSessionID == providerSessionID { return .refused }
        }
        guard (try? ClaudeSessionFolder.prepare(sessionsRoot: sessionsRoot, agentSessionID: agentSessionID)) != nil else { return .refused }
        return ClaudeSessionState.writeAttached(providerSessionID: providerSessionID, at: date, in: folder.root)
    }

    public func isAttached(agentSession sessionID: String) -> Bool {
        attachedState(sessionID) != nil
    }

    public func attachedSince(agentSession sessionID: String) -> Date? {
        attachedState(sessionID)?.attachedAt
    }

    public func externalHold(forAgentSession sessionID: String) -> ExternalWriterVerdict? {
        externalHolds[sessionID]
    }

    public func probeExternalWriter(providerSessionID: String, workspace: String) async -> ExternalWriterVerdict {
        guard !spawningStopped, let externalWriters else { return .unknown }
        let own = Set(registeredSpawnPIDs())
        return await externalWriters.check(sessionID: providerSessionID, workspace: workspace, ownPIDs: own, ownLastActivity: nil)
    }

    /// 묶인 이어받은 세션의 상태 (아니면 nil). 세션 폴더를 만들지 않고 읽기만 한다
    private func attachedState(_ sessionID: String) -> ClaudeSessionState? {
        guard let folder = ClaudeSessionFolder.locate(sessionsRoot: sessionsRoot, agentSessionID: sessionID) else { return nil }
        let state = ClaudeSessionState.load(from: folder.root)
        return state.origin == .attached && state.bound ? state : nil
    }
}
#endif
