#if os(macOS)
import Darwin
import Foundation
import TaskforceAgentWire

public struct ClaudeCommandOutput: Equatable, Sendable {
    public var exitCode: Int32
    public var stdout: Data

    public init(exitCode: Int32, stdout: Data) {
        self.exitCode = exitCode
        self.stdout = stdout
    }
}

/// 짧은 명령 하나 (`--version` · `auth status`)를 돌린다. 실패 · 시간 초과면 nil
public typealias ClaudeCommandRunner = @Sendable (_ executable: ClaudeCodeExecutable, _ arguments: [String], _ timeout: TimeInterval) async -> ClaudeCommandOutput?

/// 설치 · 버전 · 로그인 · managed settings (OA D3a 계약 2.15). **자격 값은 읽지 않는다** (I16): `auth status`에서 `loggedIn`만 본다.
/// 캐시(Q10): 버전은 실행 파일의 (realpath, 수정 시각, 크기)가 같으면 다시 쓰고, 로그인은 5분 · `sign_in_needed` 결과를 보면 버린다 (런타임이 spawn마다 probe를 부른다)
public actor ClaudeCodeProbe {
    public static let managedSettingsPath = "/Library/Application Support/ClaudeCode/managed-settings.json"
    static let loginCacheSeconds: TimeInterval = 300

    let locator: ClaudeCodeLocator
    let runner: ClaudeCommandRunner
    let managedSettingsPath: String
    let now: @Sendable () -> Date
    let timeout: TimeInterval
    let log: any BridgeLogSink

    private var version: (key: String, value: String?)?
    private var login: (at: Date, value: BridgeV1SignedIn)?

    public init(
        locator: ClaudeCodeLocator, runner: @escaping ClaudeCommandRunner, managedSettingsPath: String = ClaudeCodeProbe.managedSettingsPath,
        now: @escaping @Sendable () -> Date = { Date() }, timeout: TimeInterval = 5, log: any BridgeLogSink = NoBridgeLog()
    ) {
        self.locator = locator
        self.runner = runner
        self.managedSettingsPath = managedSettingsPath
        self.now = now
        self.timeout = timeout
        self.log = log
    }

    public func report() async -> BridgeV1AdapterReport {
        let managed = FileManager.default.fileExists(atPath: managedSettingsPath)
        guard let executable = locator.locate() else {
            log.log("claude_probe", ["installed": .count(0), "version_ok": .count(0), "signed_in": .code("unknown"), "managed": .count(managed ? 1 : 0)])
            return BridgeV1AdapterReport(adapter: ClaudeCodeSupport.adapterID, installed: false, version: nil, signedIn: .unknown, managedSettings: managed)
        }
        let versionValue = await currentVersion(executable)
        let signedIn = await currentLogin(executable)
        log.log("claude_probe", [
            "installed": .count(1), "version_ok": .count(ClaudeCodeSupport.supports(versionValue) ? 1 : 0), "signed_in": .code(signedIn.rawValue), "managed": .count(managed ? 1 : 0),
        ])
        return BridgeV1AdapterReport(adapter: ClaudeCodeSupport.adapterID, installed: true, version: versionValue, signedIn: signedIn, managedSettings: managed)
    }

    /// 로그인 없음으로 끝난 턴을 봤다: 다음 probe는 다시 묻는다
    public func invalidateLogin() {
        login = nil
    }

    private func currentVersion(_ executable: ClaudeCodeExecutable) async -> String? {
        var info = stat()
        let key = stat(executable.realPath, &info) == 0
            ? "\(executable.realPath)|\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)|\(info.st_size)"
            : executable.realPath
        if let version, version.key == key { return version.value }
        let output = await runner(executable, ["--version"], timeout)
        let value = output.flatMap { $0.exitCode == 0 ? Self.parseVersion($0.stdout) : nil }
        // 읽지 못한 값은 캐시하지 않는다 (다음 probe가 다시 묻는다)
        if value != nil { version = (key, value) }
        return value
    }

    private func currentLogin(_ executable: ClaudeCodeExecutable) async -> BridgeV1SignedIn {
        if let login, now().timeIntervalSince(login.at) < Self.loginCacheSeconds { return login.value }
        let output = await runner(executable, ["auth", "status"], timeout)
        let value = output.map { Self.parseLoggedIn($0.stdout) } ?? .unknown
        if value != .unknown { login = (now(), value) } else { login = nil }
        return value
    }

    /// `--version` 첫 낱말이 `X.Y.Z` 숫자 셋일 때만
    public static func parseVersion(_ stdout: Data) -> String? {
        guard let first = String(decoding: stdout.prefix(256), as: UTF8.self).split(whereSeparator: { $0.isWhitespace }).first.map(String.init),
              ClaudeCodeSupport.numbers(first) != nil else { return nil }
        return first
    }

    /// `auth status` JSON의 `loggedIn`만 (참거짓이 아니면 unknown). 다른 필드는 읽지 않고 버린다
    public static func parseLoggedIn(_ stdout: Data) -> BridgeV1SignedIn {
        guard stdout.count <= 64 * 1024, let value = try? WireJSON.parse(stdout), let flag = value["loggedIn"]?.boolValue else { return .unknown }
        return flag ? .yes : .no
    }

    /// 실제로 돌리는 쪽: 자식 환경 넷 · 임시 cwd · 시간 초과 (stdout은 64KB까지, stderr는 버린다)
    public static func liveRunner(environment: [String: String], cwd: @escaping @Sendable () -> String) -> ClaudeCommandRunner {
        { executable, arguments, timeout in
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: run(executable: executable, arguments: arguments, environment: ClaudeCodeEnvironment.child(app: environment, executable: executable), cwd: cwd(), timeout: timeout))
                }
            }
        }
    }

    static func run(executable: ClaudeCodeExecutable, arguments: [String], environment: [String: String], cwd: String, timeout: TimeInterval) -> ClaudeCommandOutput? {
        guard let process = try? ClaudeSpawner.spawn(executable: executable.path, arguments: arguments, environment: environment, cwd: cwd) else { return nil }
        close(process.stdinFD)
        let deadline = Date().addingTimeInterval(timeout)
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        var timedOut = false
        let errors = process.stderrFD
        DispatchQueue.global(qos: .utility).async {
            var sink = [UInt8](repeating: 0, count: 4096)
            while read(errors, &sink, sink.count) > 0 {}
            close(errors)
        }
        while true {
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else {
                timedOut = true
                break
            }
            var item = pollfd(fd: process.stdoutFD, events: Int16(POLLIN), revents: 0)
            let ready = poll(&item, 1, Int32(max(1, (left * 1000).rounded(.up))))
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { continue }
            let count = buffer.withUnsafeMutableBufferPointer { read(process.stdoutFD, $0.baseAddress!, $0.count) }
            if count > 0 {
                if output.count < 64 * 1024 { output.append(contentsOf: buffer[0..<count]) }
            } else if count < 0, errno == EINTR || errno == EAGAIN {
                continue
            } else {
                break
            }
        }
        close(process.stdoutFD)
        if timedOut {
            killpg(process.pid, SIGKILL)
            kill(process.pid, SIGKILL)
        }
        let status = process.waitForExit()
        guard !timedOut, let code = status.code else { return nil }
        return ClaudeCommandOutput(exitCode: code, stdout: output)
    }
}
#endif
