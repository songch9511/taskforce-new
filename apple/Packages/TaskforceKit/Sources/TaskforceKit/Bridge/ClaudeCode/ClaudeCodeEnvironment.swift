#if os(macOS)
import Darwin
import Foundation

/// 찾은 `claude` 실행 파일
public struct ClaudeCodeExecutable: Equatable, Sendable {
    /// 후보 경로 그대로 (링크일 수 있다). 이 경로로 띄운다
    public var path: String
    /// 그 경로의 realpath (검사한 파일)
    public var realPath: String
    /// 후보가 있는 폴더 (링크 그대로). 자식 PATH의 맨 앞
    public var directory: String

    public init(path: String, realPath: String, directory: String) {
        self.path = path
        self.realPath = realPath
        self.directory = directory
    }
}

/// `claude` 찾기 (OA D3a Q7, 계약 2.5): 고정 후보 셋 중 처음 **있는** 것. 그 realpath가 일반 파일 · 실행 가능 · 소유자 = 이 사용자나 root ·
/// 그룹/모두 쓰기 불가일 때만 쓴다 (처음 있는 후보가 검사에 실패하면 다음 후보로 넘어가지 않는다). 셸 설정을 실행해 PATH를 얻지 않는다
public struct ClaudeCodeLocator: Sendable, Equatable {
    public var candidates: [String]
    /// 시험 전용: 찾은 파일의 realpath가 이 폴더 안이어야 한다 (시험이 실제 사용자의 `claude`를 띄우지 않게, 계약 0.3-6 · G33). 실제 앱은 nil
    public var confinedTo: String?

    public init(candidates: [String], confinedTo: String? = nil) {
        self.candidates = candidates
        self.confinedTo = confinedTo
    }

    public static func standardCandidates(home: String) -> [String] {
        [home + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
    }

    public static func standard(home: String) -> ClaudeCodeLocator {
        ClaudeCodeLocator(candidates: standardCandidates(home: home))
    }

    public func locate() -> ClaudeCodeExecutable? {
        for candidate in candidates where candidate.hasPrefix("/") {
            guard let real = GateFileSystem.realpath(candidate) else { continue } // 없는 후보 (끊어진 링크 포함)
            if let root = confinedTo.flatMap(GateFileSystem.realpath), !GateFileSystem.isInside(real, root: root) { return nil }
            var info = stat()
            guard stat(real, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_mode & 0o111 != 0, info.st_mode & 0o022 == 0,
                  info.st_uid == getuid() || info.st_uid == 0 else { return nil }
            return ClaudeCodeExecutable(path: candidate, realPath: real, directory: (candidate as NSString).deletingLastPathComponent)
        }
        return nil
    }
}

/// 자식 환경 (AC-42, 계약 2.5): 정확히 `HOME` · `PATH` · `LANG` · `USER`. `ANTHROPIC_*` · `CLAUDE_*` · `DYLD_*` · 그 밖 0
public enum ClaudeCodeEnvironment {
    public static func child(app: [String: String], executable: ClaudeCodeExecutable) -> [String: String] {
        let base = AgentChildEnvironment.allowlisted(from: app)
        let account = Self.account()
        let home = base["HOME"] ?? account.home
        let user = base["USER"] ?? account.user
        return ["HOME": home, "USER": user, "LANG": lang(base["LANG"]), "PATH": path(executableDirectory: executable.directory, home: home)]
    }

    /// `<찾은 claude 폴더>:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin` (중복 제거). 13.4.1-1 ①의 "넘긴 PATH"가 이것이다
    public static func path(executableDirectory: String, home: String) -> String {
        var seen = Set<String>()
        return [executableDirectory, home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
            .filter { seen.insert($0).inserted }
            .joined(separator: ":")
    }

    /// `^[A-Za-z]{2,3}(_[A-Z]{2})?\.UTF-8$`이면 그 값, 아니면 `en_US.UTF-8` (Finder · Dock으로 뜬 앱에는 보통 없다)
    static func lang(_ value: String?) -> String {
        guard let value, value.wholeMatch(of: /[A-Za-z]{2,3}(_[A-Z]{2})?\.UTF-8/) != nil else { return "en_US.UTF-8" }
        return value
    }

    /// 앱 환경에 없으면 계정 정보 (`getpwuid(getuid())`)
    static func account() -> (home: String, user: String) {
        guard let entry = getpwuid(getuid()) else { return (NSHomeDirectory(), NSUserName()) }
        return (String(cString: entry.pointee.pw_dir), String(cString: entry.pointee.pw_name))
    }
}
#endif
