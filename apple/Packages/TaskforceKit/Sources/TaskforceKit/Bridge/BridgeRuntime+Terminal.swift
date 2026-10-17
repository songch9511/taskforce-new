#if os(macOS)
import Foundation

/// 이 Mac의 터미널이 한 세션을 이어받는 데 필요한 세 값 (OA D4a2-06): Claude 세션 id · 작업 폴더 · 실행 파일 realpath.
/// 모두 이 Mac의 상태(세션 폴더 상태 · 원장 · 등록부)에서 읽은 값이다. 서버가 준 `external_session_id`는 쓰지 않는다
public struct AgentTerminalTarget: Sendable, Equatable {
    public var providerSessionID: String
    public var folder: String
    public var executableRealPath: String

    public init(providerSessionID: String, folder: String, executableRealPath: String) {
        self.providerSessionID = providerSessionID
        self.folder = folder
        self.executableRealPath = executableRealPath
    }
}

extension BridgeRuntime {
    /// 그 Taskforce 세션의 가장 새 task와 그 adapter (이 Mac이 모르는 세션이면 nil)
    private func newestTask(ofSession sessionID: UUID) async -> (task: BridgeTaskRecord, adapter: any AgentProcess)? {
        let wanted = sessionID.uuidString.lowercased()
        // `allTasks`는 최근 것부터
        guard let task = ((try? await ledger.allTasks()) ?? []).first(where: { $0.agentSessionID.lowercased() == wanted }), let adapter = adapters[task.adapter] else { return nil }
        return (task, adapter)
    }

    /// Resume here의 프로세스 검사에 쓰는 Claude 세션 id (D4a2-07): 이 Mac의 세션 폴더 상태가 묶은 id만. 상태가 없으면 nil (검사기는 "못 찾음"으로 답한다)
    public func providerSessionID(forAgentSession sessionID: UUID) async -> String? {
        guard let (task, adapter) = await newestTask(ofSession: sessionID) else { return nil }
        return await adapter.terminalSession(task.agentSessionID)?.providerSessionID
    }

    /// Open in Terminal 미리 조건 + 열 값 (D4a2-06): adapter 상태가 묶였고(`terminalSession`), 이 세션의 작업 폴더가 있고 resolver가 지금도 인정한다.
    /// 하나라도 빠지면 nil — 앱은 서버를 부르지 않는다. 작업 폴더는 이 세션에 이 Mac이 기록한 값(원장)을 resolver에 다시 물어 쓴다 (등록부가 규칙을 다시 본다)
    public func terminalTarget(forAgentSession sessionID: UUID) async -> AgentTerminalTarget? {
        guard let (task, adapter) = await newestTask(ofSession: sessionID), let terminal = await adapter.terminalSession(task.agentSessionID) else { return nil }
        let recorded = ((try? await ledger.allTasks()) ?? []).first { $0.agentSessionID == task.agentSessionID && $0.workspaceRef != nil }?.workspaceRef
        guard let folder = recorded, let resolver = workspaces,
              await resolver.authorize(workspaceRef: folder, session: task.agentSessionID, adapter: task.adapter) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return AgentTerminalTarget(providerSessionID: terminal.providerSessionID, folder: folder, executableRealPath: terminal.executableRealPath)
    }
}
#endif
