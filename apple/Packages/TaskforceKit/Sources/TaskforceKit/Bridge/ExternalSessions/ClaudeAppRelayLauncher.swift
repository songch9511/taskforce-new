#if os(macOS)
import Darwin
import Foundation
import Security

/// 실제 중계를 지킴이 아래에서 띄운다 (PR-D3k, 계약 25.4.1): Taskforce가 Claude Code 세션을 띄우는 길(`ClaudeSpawner.spawnKept` · 환경 넷 · 검사한 실제 파일)을 그대로 쓴다.
/// - 자식 환경은 정확히 `HOME` · `PATH` · `LANG` · `USER` (`ClaudeCodeEnvironment`, AC-42)
/// - 실행 파일은 `ClaudeCodeLocator`가 고른 그 `claude` (검사한 realpath로 띄운다). 그 파일이 Anthropic 팀 서명이 아니면 띄우지 않는다 (사용자의 글이 stdin으로 간다)
/// - cwd는 앱 데이터 안의 빈 폴더다 (0700, 사용자 프로젝트가 아니다)
public struct KeptClaudeAppRelayLauncher: ClaudeAppRelayLauncher {
    public enum Failure: Error, Equatable, Sendable {
        case folder, executable, spawn
    }

    private let executable: ClaudeCodeExecutable
    private let keeper: String
    private let endedFile: URL
    private let appEnvironment: [String: String]
    private let keeperExit: TimeInterval
    private let isTrustedExecutable: @Sendable (String) -> Bool

    /// - keeper: 지킴이 실행 파일 (`ClaudeCodeHelpers.inBundle().keeper`)
    /// - endedFile: 지킴이가 끝을 증명해 쓰는 파일 (cwd 안이 아닌 곳, 앱 데이터)
    public init(
        executable: ClaudeCodeExecutable, keeper: String, endedFile: URL, appEnvironment: [String: String] = ProcessInfo.processInfo.environment, keeperExit: TimeInterval = 3,
        isTrustedExecutable: @escaping @Sendable (String) -> Bool = { ClaudeAppExecutableTrust.isSignedByAnthropic(path: $0) }
    ) {
        self.executable = executable
        self.keeper = keeper
        self.endedFile = endedFile
        self.appEnvironment = appEnvironment
        self.keeperExit = keeperExit
        self.isTrustedExecutable = isTrustedExecutable
    }

    public func launch(arguments: [String], cwd: String) async throws -> any ClaudeAppRelayProcess {
        guard Self.prepareFolder(cwd) else { throw Failure.folder }
        guard isTrustedExecutable(executable.realPath) else { throw Failure.executable }
        let environment = ClaudeCodeEnvironment.child(app: appEnvironment, executable: executable)
        let keeper = keeper
        let ended = endedFile
        let real = executable.realPath
        let argv0 = executable.path
        let exit = keeperExit
        let started: Result<ClaudeKeptSpawn, ClaudeKeptFailure> = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                try? FileManager.default.createDirectory(at: ended.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                continuation.resume(
                    returning: ClaudeSpawner.spawnKept(
                        keeper: keeper, ended: ended, executable: real, argv0: argv0, arguments: arguments, environment: environment, cwd: cwd, abortTimeout: exit
                    )
                )
            }
        }
        guard case .success(let kept) = started else { throw Failure.spawn }
        return KeptClaudeAppRelayProcess(kept: kept, keeperExit: exit)
    }

    /// 중계의 cwd: 이 사용자 소유의 빈 폴더 (없으면 0700으로 만든다). 기호 링크 · 일반 폴더 아님은 쓰지 않는다
    static func prepareFolder(_ path: String) -> Bool {
        guard ExternalSessionRules.isPlainAbsolutePath(path) else { return false }
        var info = stat()
        if lstat(path, &info) != 0 {
            guard (try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])) != nil else { return false }
            return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR && info.st_uid == getuid()
        }
        return (info.st_mode & S_IFMT) == S_IFDIR && info.st_uid == getuid() && info.st_mode & 0o022 == 0
    }
}

/// 띄울 때마다 `claude`를 다시 찾는다 (`ClaudeCodeLocator`: 고정 후보 셋 중 처음 **있는** 것, 사용자가 `claude`를 새로 깔거나 지운 것이 다음 보내기에 반영된다). 못 찾거나 검사에 걸리면 띄우지 않는다
public struct LocatingClaudeAppRelayLauncher: ClaudeAppRelayLauncher {
    private let locator: ClaudeCodeLocator
    private let keeper: String
    private let endedFile: URL
    private let appEnvironment: [String: String]
    private let isTrustedExecutable: @Sendable (String) -> Bool

    public init(
        locator: ClaudeCodeLocator, keeper: String, endedFile: URL, appEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        isTrustedExecutable: @escaping @Sendable (String) -> Bool = { ClaudeAppExecutableTrust.isSignedByAnthropic(path: $0) }
    ) {
        self.locator = locator
        self.keeper = keeper
        self.endedFile = endedFile
        self.appEnvironment = appEnvironment
        self.isTrustedExecutable = isTrustedExecutable
    }

    public func launch(arguments: [String], cwd: String) async throws -> any ClaudeAppRelayProcess {
        guard let executable = locator.locate() else { throw KeptClaudeAppRelayLauncher.Failure.executable }
        let launcher = KeptClaudeAppRelayLauncher(
            executable: executable, keeper: keeper, endedFile: endedFile, appEnvironment: appEnvironment, isTrustedExecutable: isTrustedExecutable
        )
        return try await launcher.launch(arguments: arguments, cwd: cwd)
    }
}

/// 실행 파일 서명 확인: Anthropic PBC(Developer ID, 팀 `Q6L2SF6YDW`)가 서명한 파일인가 (정적 확인)
public enum ClaudeAppExecutableTrust {
    public static func isSignedByAnthropic(path: String) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, SecCSFlags(), &code) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(ClaudeAppProcessTrust.teamIdentifier)\""
        guard SecRequirementCreateWithString(text as CFString, SecCSFlags(), &requirement) == errSecSuccess, let requirement else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(), requirement) == errSecSuccess
    }
}

/// 지킴이가 띄운 중계 `claude` 하나의 stdin · stdout (`ClaudeKeptSpawn`). stdout은 줄로 나눠 스트림으로 내고, 끝나면 스트림이 끝난다.
/// `stop()`은 stdin을 닫고 지킴이를 거둔다 (`ClaudeSpawner.abort`: 지킴이가 `claude`를 끝내고 구성원 0을 증명하고 0으로 끝나야 끝이다)
final class KeptClaudeAppRelayProcess: ClaudeAppRelayProcess, @unchecked Sendable {
    private let kept: ClaudeKeptSpawn
    private let keeperExit: TimeInterval
    let lines: AsyncStream<Data>
    private let stopFlag = ClaudeCodeProcess.Flag()
    private let readerDone = DispatchSemaphore(value: 0)
    private let writeQueue = DispatchQueue(label: "dev.taskforce.claude-app-relay.stdin")
    private let state = NSLock()
    private var stopping = false

    var pid: Int32 { kept.claudePID }
    var startedAt: Date? { kept.claudeStartedAt }

    init(kept: ClaudeKeptSpawn, keeperExit: TimeInterval) {
        self.kept = kept
        self.keeperExit = keeperExit
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        lines = stream
        let output = kept.keeper.stdoutFD
        let errors = kept.keeper.stderrFD
        let stop = stopFlag
        let done = readerDone
        DispatchQueue.global(qos: .userInitiated).async {
            ClaudeCodeProcess.readLines(fd: output, stop: stop) { item in
                // 너무 긴 줄은 버린다 (줄 하나가 답이면 명령이 시간 초과로 끝난다)
                if case .line(let data) = item { continuation.yield(data) }
            }
            continuation.finish()
            done.signal()
        }
        DispatchQueue.global(qos: .utility).async {
            // stderr는 읽어 버린다 (바이트 수도 남기지 않는다: 글이 섞일 수 있다)
            var sink = [UInt8](repeating: 0, count: 8192)
            while !stop.isSet {
                var item = pollfd(fd: errors, events: Int16(POLLIN), revents: 0)
                let ready = poll(&item, 1, 200)
                if ready < 0, errno == EINTR { continue }
                guard ready > 0 else { continue }
                if read(errors, &sink, sink.count) <= 0 { break }
            }
        }
    }

    /// 끝냈다 (`stop()`): 이 뒤로는 stdin fd에 쓰지 않는다. 지킴이를 거두면 fd가 닫히고 그 번호는 곧 다른 파일이 쓴다 — 줄 서 있던 쓰기가 그 번호로 가면 글이 엉뚱한 곳에 들어간다 (OA PR-D3 검토 P3-8)
    private let closeLock = NSLock()
    private var closedForWrites = false

    private func isClosedForWrites() -> Bool { closeLock.withLock { closedForWrites } }

    func write(_ data: Data) async -> Bool {
        let fd = kept.keeper.stdinFD
        return await withCheckedContinuation { continuation in
            writeQueue.async { [self] in
                // 줄 서 있는 동안 끝났을 수 있다: 닫힌 뒤에는 `write(2)`를 부르지 않는다
                let closed: @Sendable () -> Bool = { [self] in isClosedForWrites() }
                continuation.resume(returning: !closed() && Self.writeAll(fd: fd, data, closed: closed))
            }
        }
    }

    private static func writeAll(fd: Int32, _ data: Data, closed: () -> Bool) -> Bool {
        var offset = 0
        return data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return true }
            while offset < raw.count {
                if closed() { return false }
                let count = Darwin.write(fd, base + offset, raw.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN {
                        var item = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                        _ = poll(&item, 1, 200)
                        continue
                    }
                    return false
                }
                offset += count
            }
            return true
        }
    }

    func stop() async {
        let first = state.withLock { () -> Bool in
            defer { stopping = true }
            return !stopping
        }
        guard first else { return }
        // 쓰기를 먼저 닫는다: 이 뒤로 들어오는 쓰기는 하지 않고, 쓰는 중인 쓰기는 다음 반복에서 물러난다
        closeLock.withLock { closedForWrites = true }
        // 읽기 스레드가 먼저 물러난다 (fd를 닫는 동안 읽지 않게)
        stopFlag.set()
        let done = readerDone
        let kept = kept
        let exit = keeperExit
        let writes = writeQueue
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                _ = done.wait(timeout: .now() + 2)
                // 줄 서 있던 쓰기가 모두 지나간 뒤에 fd를 닫는다 (닫힌 fd 번호에 쓰는 쓰기가 없다)
                writes.sync {}
                _ = ClaudeSpawner.abort(kept.keeper, reportFD: kept.reportFD, timeout: exit)
                continuation.resume()
            }
        }
    }

    func identityMatches() -> Bool {
        guard case .present(let listed) = ClaudeProcessInspector.kernel(pid: kept.claudePID), !listed.zombie, listed.uid == getuid() else { return false }
        return abs(listed.start.timeIntervalSince(kept.claudeStartedAt)) <= 0.001
    }
}
#endif
