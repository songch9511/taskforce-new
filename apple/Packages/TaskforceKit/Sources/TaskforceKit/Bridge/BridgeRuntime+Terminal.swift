#if os(macOS)
import Foundation

/// 이 Mac의 터미널이 한 세션을 이어받는 데 필요한 네 값 (OA D4a2-06 + 코디네이터 결정 13.10 덧붙임): Claude 세션 id · 작업 폴더 · 실행 파일 realpath · 세션 cwd.
/// 이어받기는 adapter가 띄운 **세션 cwd**에서 하고(대화 기록이 cwd별이다) 작업 폴더는 `--add-dir`로 다시 준다.
/// 모두 이 Mac의 상태(세션 폴더 상태 · 원장 · 등록부)에서 읽은 값이다. 서버가 준 `external_session_id`는 쓰지 않는다
public struct AgentTerminalTarget: Sendable, Equatable {
    public var providerSessionID: String
    public var folder: String
    public var executableRealPath: String
    public var sessionCwd: String

    public init(providerSessionID: String, folder: String, executableRealPath: String, sessionCwd: String) {
        self.providerSessionID = providerSessionID
        self.folder = folder
        self.executableRealPath = executableRealPath
        self.sessionCwd = sessionCwd
    }
}

/// 세션 보기가 이 Mac의 Claude Code 기록을 읽는 데 필요한 두 값 (세션 보기 V1): Claude 세션 id · 그 세션을 띄운 세션 cwd. 이 Mac의 세션 폴더 상태에서만 온다
/// (서버가 준 `external_session_id`는 쓰지 않는다). 글 · 경로를 찍지 않는다
public struct AgentLocalTranscriptTarget: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public var providerSessionID: String
    public var cwd: String

    public init(providerSessionID: String, cwd: String) {
        self.providerSessionID = providerSessionID
        self.cwd = cwd
    }

    public var description: String { "AgentLocalTranscriptTarget()" }
    public var debugDescription: String { description }
}

extension BridgeRuntime {
    /// 그 Taskforce 세션의 가장 새 task와 그 adapter (이 Mac이 모르는 세션이면 nil)
    private func newestTask(ofSession sessionID: UUID) async -> (task: BridgeTaskRecord, adapter: any AgentProcess)? {
        let wanted = sessionID.uuidString.lowercased()
        // `allTasks`는 최근 것부터
        guard let task = ((try? await ledger.allTasks()) ?? []).first(where: { $0.agentSessionID.lowercased() == wanted }), let adapter = adapters[task.adapter] else { return nil }
        return (task, adapter)
    }

    /// 세션 보기(Taskforce 패널)가 이 Mac의 Claude Code 기록을 읽을 값: 그 세션이 **이 Mac에서** 돌아 adapter 상태가 묶었을 때만 (다른 Mac의 세션 · 첫 턴 전이면 nil: 단계는 그 Mac에서만 보인다).
    /// 터미널 열기와 달리 지금 돌고 있어도 준다 (읽기만 한다)
    public func localTranscriptTarget(forAgentSession sessionID: UUID) async -> AgentLocalTranscriptTarget? {
        guard let (task, adapter) = await newestTask(ofSession: sessionID), let terminal = await adapter.terminalSession(task.agentSessionID) else { return nil }
        return AgentLocalTranscriptTarget(providerSessionID: terminal.providerSessionID, cwd: terminal.sessionCwd)
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
        // 읽지 못하면 이 Mac의 실행 상태를 모른다: 열지 않는다 (`?? []`로 "실행 없음"을 만들지 않는다)
        guard let allTasks = try? await ledger.allTasks() else { return nil }
        let sessionTasks = allTasks.filter { $0.agentSessionID == task.agentSessionID }
        // 깊은 방어 (보안 I1): 이 Mac이 아직 돌고 있다고 보거나(`alive` · 감독 중) 중단을 증명하지 못한(`unproven`) 실행이 있으면 터미널로 넘기지 않는다 — 서버 `busy`에만 기대지 않는다
        guard !sessionTasks.contains(where: { $0.alive || $0.cancelState == "unproven" || supervised[$0.agentTaskID] != nil }) else { return nil }
        let recorded = sessionTasks.first { $0.workspaceRef != nil }?.workspaceRef
        guard let folder = recorded, let resolver = workspaces,
              await resolver.authorize(workspaceRef: folder, session: task.agentSessionID, adapter: task.adapter) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return AgentTerminalTarget(providerSessionID: terminal.providerSessionID, folder: folder, executableRealPath: terminal.executableRealPath, sessionCwd: terminal.sessionCwd)
    }
}
#endif
