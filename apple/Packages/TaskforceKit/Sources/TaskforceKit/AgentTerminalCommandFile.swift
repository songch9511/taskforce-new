#if os(macOS)
import Darwin
import Foundation

// Open in Terminal의 `.command` 파일 (OA D4a-15b · D4a2-06). 앱 지원 폴더 `Terminal/<uuid>.command`(0700)를 만들고 기본 처리 앱(Terminal)으로 연다.
// AppleScript도 `open -a Terminal`도 쓰지 않는다: 자동화 권한 창이 늘지 않는다.
//
// 보안 (계약 13.6 · 보안 검토 디스패치):
// - 내용은 정확히 한 줄 명령이다: `cd '<세션 cwd>' && exec '<claude realpath>' --resume '<Claude 세션 id>' --add-dir '<작업 폴더>'`. Claude Code는 대화 기록을 cwd별로 두고 `--add-dir`는 이어받을 때
//   되살아나지 않으므로(코디네이터 결정, 13.10 덧붙임) adapter가 띄운 세션 cwd에서 이어받고 작업 폴더를 다시 준다. `--settings` · `--mcp-config`는 주지 않는다: 터미널은 사용자가 이어받은 것이라
//   Taskforce의 훅 밖이고 사용자 자신의 Claude Code 설정이 적용된다. 네 값 모두 `ClaudeCodeLaunch.quotedForShell`을 거친다 — `'` · 제어 글자(줄바꿈 포함) · NUL이 있으면
//   파일을 만들지 않고 열지도 않는다. 사용자 글 · 경로 원문을 로그에 남기지 않는다
// - 파일은 0700으로 만든다(`O_EXCL`, 다른 사용자가 읽거나 바꿀 수 없다). 폴더도 0700이고 기호 링크이거나 남의 폴더면 쓰지 않는다
// - 값은 이 Mac 상태에서만 온다 (`AgentTerminalTarget`). 서버 `external_session_id`는 쓰지 않는다
// - 지난 파일은 앱 시작 때와 새로 열 때 10분이 넘은 것을 지운다 (터미널이 파일을 읽은 뒤에는 필요 없다)

public enum AgentTerminalCommandError: Error, Equatable, Sendable {
    /// 폴더 · 실행 파일 · 세션 id 중 셸 인용을 통과하지 못한 값이 있다
    case unquotable
    /// `Terminal/` 폴더가 안전하지 않다(기호 링크 · 남의 폴더) 또는 파일을 만들지 못했다
    case storeUnavailable
    /// 터미널(기본 처리 앱)이 파일을 열지 못했다
    case openFailed
}

public enum AgentTerminalCommandFile {
    /// `.command` 내용: 셸 한 줄 (`#!/bin/sh` 아래). 인용 실패(네 값 중 하나라도)면 던진다
    public static func contents(for target: AgentTerminalTarget) throws -> String {
        do {
            let cwd = try ClaudeCodeLaunch.quotedForShell(target.sessionCwd)
            let executable = try ClaudeCodeLaunch.quotedForShell(target.executableRealPath)
            let session = try ClaudeCodeLaunch.quotedForShell(target.providerSessionID)
            let folder = try ClaudeCodeLaunch.quotedForShell(target.folder)
            return "#!/bin/sh\ncd \(cwd) && exec \(executable) --resume \(session) --add-dir \(folder)\n"
        } catch {
            throw AgentTerminalCommandError.unquotable
        }
    }
}

/// `Terminal/` 폴더의 `.command` 파일 (만들기 · 지난 파일 지우기)
public struct AgentTerminalCommandStore: Sendable {
    public static let lifetime: TimeInterval = 600

    public let directory: URL
    private let now: @Sendable () -> Date

    public init(directory: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.now = now
    }

    /// 0700 파일을 만들어 `contents`를 쓴다. 폴더가 없으면 0700으로 만들고, 기호 링크이거나 남의 폴더이면 던진다
    public func write(_ contents: String) throws -> URL {
        try prepareDirectory()
        let file = directory.appending(path: UUID().uuidString.lowercased() + ".command")
        let descriptor = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o700)
        guard descriptor >= 0 else { throw AgentTerminalCommandError.storeUnavailable }
        var succeeded = false
        defer {
            close(descriptor)
            if !succeeded { unlink(file.path) }
        }
        guard fchmod(descriptor, 0o700) == 0 else { throw AgentTerminalCommandError.storeUnavailable }
        let data = Data(contents.utf8)
        let written = data.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if count < 0 { if errno == EINTR { continue }; return false }
                offset += count
            }
            return true
        }
        guard written else { throw AgentTerminalCommandError.storeUnavailable }
        succeeded = true
        return file
    }

    /// 10분이 넘은 `.command` 파일을 지운다 (이 폴더 안의 일반 파일만, 기호 링크는 따라가지 않는다). 지운 수를 돌려준다
    @discardableResult
    public func sweep() -> Int {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return 0 }
        let cutoff = now().addingTimeInterval(-Self.lifetime)
        var removed = 0
        for name in names where name.hasSuffix(".command") {
            let path = directory.appending(path: name).path
            var info = stat()
            guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid() else { continue }
            let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
            if modified < cutoff, unlink(path) == 0 { removed += 1 }
        }
        return removed
    }

    private func prepareDirectory() throws {
        var info = stat()
        if lstat(directory.path, &info) != 0 {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            } catch {
                throw AgentTerminalCommandError.storeUnavailable
            }
            guard lstat(directory.path, &info) == 0 else { throw AgentTerminalCommandError.storeUnavailable }
        }
        // 기호 링크가 아닌 내 폴더만. 모드가 0700이 아니면 바로잡는다
        guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else { throw AgentTerminalCommandError.storeUnavailable }
        if info.st_mode & 0o777 != 0o700, chmod(directory.path, 0o700) != 0 { throw AgentTerminalCommandError.storeUnavailable }
    }
}

/// 만든 파일을 연다 (실제는 `NSWorkspace`: 기본 처리 앱). 시험은 가짜로 바꾼다 — 시험이 실제 터미널을 열지 않는다
public protocol AgentTerminalOpening: Sendable {
    /// 열었으면 true
    func open(_ file: URL) async -> Bool
}

/// `AgentTerminalLauncher`의 실제 구현 (D4a2-06). 값은 `target`이 이 Mac 상태에서 읽어 준다
public struct CommandFileTerminalLauncher: AgentTerminalLauncher {
    private let target: @Sendable (UUID) async -> AgentTerminalTarget?
    private let store: AgentTerminalCommandStore
    private let opener: any AgentTerminalOpening

    public init(target: @escaping @Sendable (UUID) async -> AgentTerminalTarget?, store: AgentTerminalCommandStore, opener: any AgentTerminalOpening) {
        self.target = target
        self.store = store
        self.opener = opener
    }

    /// 미리 조건: 이 Mac 상태가 묶였고(Claude 세션 id) · 작업 폴더가 있고 · 실행 파일을 찾았고 · 셸 인용을 통과한다. 하나라도 아니면 false — 서버 호출은 0이다
    public func canOpen(sessionID: UUID) async -> Bool {
        guard let found = await target(sessionID) else { return false }
        return (try? AgentTerminalCommandFile.contents(for: found)) != nil
    }

    public func open(sessionID: UUID) async throws {
        guard let found = await target(sessionID) else { throw AgentTerminalCommandError.unquotable }
        let contents = try AgentTerminalCommandFile.contents(for: found)
        store.sweep()
        let file = try store.write(contents)
        guard await opener.open(file) else {
            // 열지 못한 파일을 남기지 않는다
            try? FileManager.default.removeItem(at: file)
            throw AgentTerminalCommandError.openFailed
        }
    }
}
#endif
