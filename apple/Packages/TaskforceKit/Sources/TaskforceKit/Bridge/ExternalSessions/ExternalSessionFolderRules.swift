#if os(macOS)
import Darwin
import Foundation

/// 외부 세션 목록이 쓰는 작업 폴더 규칙: `WorkspaceFolderRules`의 같은 거절 표를 쓰되 **파일 시스템을 열지 않는다** (글자만 본다).
/// 목록은 사용자가 고르지 않은 폴더(기록 안의 cwd) 수십 개를 판정한다: `stat` · `realpath`가 Documents · Desktop · Downloads 안을 건드리면 macOS가 앱 이름으로 접근 동의 창을 띄운다.
/// Claude Code의 cwd는 이미 실제 경로(`getcwd`)라 글자 판정으로 충분하고, 폴더가 지금도 있는지 · 기호 링크인지는 이어받을 때(사용자 행동) 실제 규칙(`.standard`)이 다시 본다.
public enum ExternalSessionFolderRules {
    /// - protectedRoots: 앱 데이터 · bridge root · 앱 번들 (그 안, 그것을 품는 폴더 모두 거절)
    public static func lexical(
        home: String, protectedRoots: [String], environment: [String: String] = ProcessInfo.processInfo.environment, userID: UInt32 = getuid()
    ) -> WorkspaceFolderRules {
        let facts = WorkspaceFolderRules.Facts(realpath: { $0 }, inspect: { _ in (isDirectory: true, owner: userID) }, userID: userID)
        return WorkspaceFolderRules(
            home: home, extraClaudeConfig: environment["CLAUDE_CONFIG_DIR"], systemRoots: ["/System", "/Library", "/Applications", "/usr", "/bin", "/sbin", "/private"],
            protectedRoots: protectedRoots, facts: facts
        )
    }
}
#endif
