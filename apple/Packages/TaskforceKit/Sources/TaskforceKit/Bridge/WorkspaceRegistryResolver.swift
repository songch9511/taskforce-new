#if os(macOS)
import Foundation

/// 등록부로 작업 폴더를 정하는 resolver (OA D4a2-02 · 03 · 04). 사용자 폴더를 짐작하지 않는다: 이 Mac에서 사용자가 고른 폴더만 쓰고, 찾지 못하면 nil이다
/// (런타임이 접수 전 `spawn_failed`로 닫는다, "Session didn't start").
///
/// 세션 → 폴더 찾기 순서:
/// 1. **세션 핀** (등록부 `sessions`): 있으면 그것이 전부다. 세션을 연 뒤 이슈가 다른 프로젝트로 옮겨져도 그 세션은 핀 폴더를 쓴다. 핀 폴더가 사라졌거나 규칙을 어기게 됐으면 다른 폴더로 넘어가지 않고 nil이다
/// 2. **대화 핀** (`pending`): RLS로 이 세션에 이어진 대화를 읽고, Ungrouped 대화가 보내기 전에 고른 폴더를 본다
/// 3. **프로젝트** (`projects`): RLS로 이 세션의 run이 가리키는 이슈를 읽고, 그 이슈의 **확인된** 멤버십(origin user · auto, inferred 제외)의 프로젝트 폴더를 본다.
///    프로젝트가 여럿이면 id 순으로 폴더가 있는 첫 프로젝트다
/// 4. 없으면 nil
/// 2·3에서 찾으면 그 세션에 핀을 꽂는다. RLS 읽기가 실패해도 짐작하지 않는다 (nil).
///
/// `authorize`는 서버가 명령에 실어 보낸 값(런타임이 불투명 id를 경로로 바꾼 것)이 **이 세션의 핀 폴더**일 때만 인정한다 — 등록부에 있는 다른 폴더라도
/// 다른 세션의 폴더면 거절이다. 쓰기 직전에 규칙(`WorkspaceFolderRules`)을 다시 본다.
public final class RegistryWorkspaceResolver: WorkspaceResolver {
    public let registry: WorkspaceRegistry
    private let sessions: any AgentSessionGateway
    private let contexts: any ContextGateway
    private let log: any BridgeLogSink

    public init(registry: WorkspaceRegistry, sessions: any AgentSessionGateway, contexts: any ContextGateway, log: any BridgeLogSink = NoBridgeLog()) {
        self.registry = registry
        self.sessions = sessions
        self.contexts = contexts
        self.log = log
    }

    /// 규칙을 지금 다시 통과하는 폴더면 그 realpath
    private func usable(_ path: String) -> String? {
        if case .success(let real) = registry.rules.validate(path) { return real }
        return nil
    }

    /// 세션에 핀을 꽂고 **성공해서 읽힌 실제 핀**만 돌려준다. 저장하지 못하면 nil로 닫는다: 핀 없이 띄우면 다음 턴이 `authorize`에서 거절되고 핀을 다시 만들 길도 없다
    private func pinned(_ sessionID: String, to path: String) -> String? {
        do { try registry.pin(session: sessionID, to: path) } catch {
            log.log("workspace_pin_failed", [:])
            return nil
        }
        return registry.pinned(session: sessionID).flatMap(usable)
    }

    public func workspace(forSession sessionID: String, adapter: String) async -> String? {
        if let pinned = registry.pinned(session: sessionID) { return usable(pinned) }
        guard let session = UUID(uuidString: sessionID) else { return nil }
        let snapshot: AgentSessionSnapshot
        do {
            snapshot = try await sessions.agentSessionSnapshot(sessionIDs: [session])
        } catch {
            log.log("workspace_read_failed", ["step": .code("session")])
            return nil
        }
        // 2. 대화 핀
        for conversation in snapshot.conversations where conversation.agentSessionID == session {
            if let path = registry.pending(conversation: conversation.id), let real = usable(path) { return pinned(sessionID, to: real) }
        }
        // 3. 프로젝트
        let actions = Set(snapshot.runs.filter { $0.agentSessionID == session }.map(\.actionID))
        guard !actions.isEmpty else { return nil }
        let members: [ContextMember]
        do {
            members = try await contexts.contextMembers()
        } catch {
            log.log("workspace_read_failed", ["step": .code("context")])
            return nil
        }
        let projects = Set(members.filter { member in member.isConfirmed && member.actionID.map(actions.contains) == true }.map(\.contextID))
        for project in projects.sorted(by: { $0.uuidString < $1.uuidString }) {
            if let path = registry.folder(forProject: project), let real = usable(path) { return pinned(sessionID, to: real) }
        }
        return nil
    }

    public func authorize(workspaceRef: String, session sessionID: String, adapter: String) async -> Bool {
        guard let pinned = registry.pinned(session: sessionID), let allowed = usable(pinned), let candidate = registry.rules.facts.realpath(workspaceRef) else { return false }
        return candidate == allowed
    }

    public var recognizesRecordedPaths: Bool { false }

    public func workspaceRef(forPath path: String) async -> String? { registry.ref(forPath: path) }

    public func workspacePath(forRef ref: String) async -> String? { registry.path(forRef: ref) }
}
#endif
