#if os(macOS) && DEBUG
import Foundation
import TaskforceKit

/// Debug 전용 작업 폴더 resolver (OA D3a Q14, Release에는 없다): 실제 Claude Code adapter의 R2 확인(로컬 스택)에서만 쓴다.
/// 사용자 폴더를 짐작하지 않는다 — 아래를 모두 만족하는 폴더 하나만 받는다:
/// - 서버 주소가 loopback (로컬 스택)
/// - 표식 파일 `.taskforce-disposable`이 있는 디렉터리이고 소유자가 이 사용자
/// - 그 폴더와 조상 어디에도 `.git`이 없다 (저장소 밖)
/// - `~/.claude` 안이 아니다
/// 실제 폴더 고르기 화면과 레지스트리는 D4a 몫이다 (Release는 resolver가 없어 새 세션이 `spawn_failed`)
struct DisposableWorkspaces: WorkspaceResolver {
    static let marker = ".taskforce-disposable"

    let path: String

    /// 조건을 모두 만족할 때만 만든다
    static func make(path raw: String?, apiBaseURL: URL, home: String) -> DisposableWorkspaces? {
        guard BridgeEndpointPolicy.isLoopback(apiBaseURL), let raw, raw.hasPrefix("/"), let real = GateFileSystem.realpath(raw) else { return nil }
        var info = stat()
        guard stat(real, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else { return nil }
        guard FileManager.default.fileExists(atPath: real + "/" + marker) else { return nil }
        let claudeHome = GateFileSystem.realpath(home + "/.claude") ?? (home + "/.claude")
        guard !GateFileSystem.isInside(real, root: claudeHome) else { return nil }
        var folder = URL(fileURLWithPath: real, isDirectory: true)
        while true {
            if FileManager.default.fileExists(atPath: folder.appending(path: ".git").path) { return nil }
            let parent = folder.deletingLastPathComponent()
            if parent.path == folder.path { break }
            folder = parent
        }
        return DisposableWorkspaces(path: real)
    }

    func workspace(forSession sessionID: String, adapter: String) async -> String? { path }

    func authorize(workspaceRef: String, session sessionID: String, adapter: String) async -> Bool {
        GateFileSystem.realpath(workspaceRef) == path
    }
}
#endif
