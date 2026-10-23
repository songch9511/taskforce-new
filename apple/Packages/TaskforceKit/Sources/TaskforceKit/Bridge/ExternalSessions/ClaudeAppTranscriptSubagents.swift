#if os(macOS)
import Foundation

extension ClaudeAppTranscriptReader {
    /// 세션 폴더의 `subagents/`에서 하위 에이전트 메타를 읽는다 (에이전트 트리 T1). **폴더 사슬 검사는 `BackgroundTaskTail`의 것과 같은 함수다** (새로 흉내 내지 않는다):
    /// 모든 폴더가 이 uid의 진짜 폴더이고 그룹/모두가 쓸 수 없어야 하며, 이름은 `agent-<id>.meta.json`뿐, 256개까지, 파일은 4 KiB까지 `ExternalSessionFileSystem.read`로 읽는다
    public func subagents(sessionID: String, cwd: String?, since: Date? = nil) -> SubagentListing {
        BackgroundTaskTail(fileSystem: fileSystem, claudeDirectory: claudeDirectory).subagents(sessionID: sessionID, cwd: cwd, since: since)
    }
}
#endif
