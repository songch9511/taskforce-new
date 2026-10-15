#if os(macOS)
import Darwin
import Foundation
import Synchronization

/// 시간 값 (OA D3a 계약 2.12–2.14). 시험은 짧은 값을 넣는다
public struct ClaudeCodeTiming: Sendable, Equatable {
    /// 고아 끝내기: SIGINT 뒤 기다림 (그다음 SIGKILL)
    public var orphanInterruptGrace: TimeInterval
    /// SIGKILL 뒤 사라짐 확인
    public var orphanKillGrace: TimeInterval
    /// 닫기 모드 spawn이 끝나기를 기다리는 시간 (넘으면 고아 끝내기)
    public var closeTimeout: TimeInterval
    /// `result` 뒤 프로세스가 스스로 끝나기를 기다리는 시간 (넘으면 SIGINT)
    public var exitAfterResult: TimeInterval
    /// 프로세스가 끝난 뒤 stdout 남은 줄을 읽는 시간 (자손이 파이프를 붙잡고 있어도 끝낸다)
    public var drainAfterExit: TimeInterval
    /// `--version` · `auth status`
    public var probeTimeout: TimeInterval
    /// 도구 결정 API 왕복 예산 (D3c-2 3.5: 1.0초). 넘으면 로컬 defer
    public var serverTimeout: TimeInterval

    public init(
        orphanInterruptGrace: TimeInterval, orphanKillGrace: TimeInterval, closeTimeout: TimeInterval, exitAfterResult: TimeInterval, drainAfterExit: TimeInterval,
        probeTimeout: TimeInterval, serverTimeout: TimeInterval
    ) {
        self.orphanInterruptGrace = orphanInterruptGrace
        self.orphanKillGrace = orphanKillGrace
        self.closeTimeout = closeTimeout
        self.exitAfterResult = exitAfterResult
        self.drainAfterExit = drainAfterExit
        self.probeTimeout = probeTimeout
        self.serverTimeout = serverTimeout
    }

    public static let standard = ClaudeCodeTiming(orphanInterruptGrace: 3, orphanKillGrace: 2, closeTimeout: 10, exitAfterResult: 5, drainAfterExit: 2, probeTimeout: 5, serverTimeout: 1)
    /// 시험: 짧은 유예, 넉넉한 서버 예산 (시험 전체가 동시에 돌 때 대본 결정기가 늦게 답해도 시간 초과로 보이지 않게. 1.0초 예산 자체는 결정표 시험이 본다)
    static let testing = ClaudeCodeTiming(orphanInterruptGrace: 0.5, orphanKillGrace: 1, closeTimeout: 5, exitAfterResult: 3, drainAfterExit: 1, probeTimeout: 5, serverTimeout: 5)
}

public struct ClaudeExitStatus: Equatable, Sendable {
    public var code: Int32?
    public var signal: Int32?

    var agentExit: AgentExit { AgentExit(code: code.map(Int.init), signal: signal.map(Int.init)) }
}

/// posix_spawn으로 띄운 자식 하나 (계약 2.5): 새 프로세스 그룹 · 앱 fd 물려주지 않음(`POSIX_SPAWN_CLOEXEC_DEFAULT`) · stdin/stdout/stderr 파이프 · cwd
public final class ClaudeSpawnedProcess: @unchecked Sendable {
    public let pid: pid_t
    /// 커널 시작 시각 (spawn 직후 읽음)
    public let startedAt: Date
    let stdinFD: Int32
    let stdoutFD: Int32
    let stderrFD: Int32
    private let reaped = Mutex<ClaudeExitStatus?>(nil)

    init(pid: pid_t, startedAt: Date, stdinFD: Int32, stdoutFD: Int32, stderrFD: Int32) {
        self.pid = pid
        self.startedAt = startedAt
        self.stdinFD = stdinFD
        self.stdoutFD = stdoutFD
        self.stderrFD = stderrFD
    }

    /// 시험 도우미: 파이프를 쓰지 않을 때 닫는다
    func closeStandardStreams() {
        close(stdinFD)
        close(stdoutFD)
        close(stderrFD)
    }

    /// 끝날 때까지 기다려 거둔다 (한 번만 거둔다. 이미 거뒀으면 그 값)
    public func waitForExit() -> ClaudeExitStatus {
        if let done = reaped.withLock({ $0 }) { return done }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 {
            if errno != EINTR {
                return reaped.withLock { $0 } ?? ClaudeExitStatus(code: nil, signal: nil)
            }
        }
        let low = status & 0x7f
        let result = low == 0 ? ClaudeExitStatus(code: (status >> 8) & 0xff, signal: nil) : ClaudeExitStatus(code: nil, signal: low)
        reaped.withLock { $0 = $0 ?? result }
        return result
    }
}

public enum ClaudeSpawner {
    /// `executable`을 `arguments`로 띄운다. 환경은 이 사전뿐이다. 실패하면 아무것도 남기지 않고 던진다
    public static func spawn(executable: String, arguments: [String], environment: [String: String], cwd: String) throws -> ClaudeSpawnedProcess {
        var input: [Int32] = [-1, -1]
        var output: [Int32] = [-1, -1]
        var errors: [Int32] = [-1, -1]
        func closeAll() { for fd in input + output + errors where fd >= 0 { close(fd) } }
        guard pipe(&input) == 0, pipe(&output) == 0, pipe(&errors) == 0 else {
            closeAll()
            throw AgentStartError(.spawnFailed)
        }
        for fd in input + output + errors { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        // 자식이 먼저 끝나도 앱이 SIGPIPE로 죽지 않게 (쓰기는 EPIPE로 끝난다)
        _ = fcntl(input[1], F_SETNOSIGPIPE, 1)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, input[0], 0)
        posix_spawn_file_actions_adddup2(&actions, output[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errors[1], 2)
        posix_spawn_file_actions_addchdir_np(&actions, cwd)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        let flags = POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&attributes, Int16(flags))
        posix_spawnattr_setpgroup(&attributes, 0)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for signal in [SIGINT, SIGTERM, SIGPIPE, SIGHUP, SIGQUIT, SIGCHLD] { sigaddset(&defaults, signal) }
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for pointer in argv { free(pointer) }
            for pointer in envp { free(pointer) }
        }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        close(input[0])
        close(output[1])
        close(errors[1])
        guard status == 0, pid > 0 else {
            close(input[1])
            close(output[0])
            close(errors[0])
            throw AgentStartError(.spawnFailed)
        }
        let started = ClaudeProcessInspector.startTime(pid: pid) ?? Date()
        return ClaudeSpawnedProcess(pid: pid, startedAt: started, stdinFD: input[1], stdoutFD: output[0], stderrFD: errors[0])
    }
}

/// 정체 확인 · 신호 (계약 2.14): pid > 1 + 커널 시작 시각 1ms 안 + 소유자 uid + argv의 `--settings …/config/<marker>.settings.json`.
/// 신호마다 정체를 다시 본다. SIGTERM은 쓰지 않는다 (13.2 :513, Q12)
public enum ClaudeProcessInspector {
    enum Kernel {
        case running(start: Date, uid: uid_t, zombie: Bool, group: pid_t)
        case gone
        case unreadable
    }

    static func kernel(pid: pid_t) -> Kernel {
        guard pid > 0 else { return .unreadable }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else { return errno == ESRCH ? .gone : .unreadable }
        guard size > 0, info.kp_proc.p_pid == pid else { return .gone }
        let start = info.kp_proc.p_un.__p_starttime
        return .running(
            start: Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000), uid: info.kp_eproc.e_ucred.cr_uid,
            zombie: info.kp_proc.p_stat == SZOMB, group: info.kp_eproc.e_pgid
        )
    }

    public static func startTime(pid: pid_t) -> Date? {
        if case .running(let start, _, _, _) = kernel(pid: pid) { return start }
        return nil
    }

    /// `KERN_PROCARGS2`: argc, 실행 경로, 그 뒤 argv (같은 사용자 프로세스만 읽힌다)
    static func arguments(pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 } // 실행 경로
        while index < size, buffer[index] == 0 { index += 1 } // 채움
        var result: [String] = []
        while result.count < Int(argc), index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            result.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return result
    }

    enum Check: Equatable {
        case same
        /// 없다 · 좀비 · 다른 시작 시각 · 다른 사용자: 그 프로세스는 끝났다
        case gone
        /// 확인할 수 없다 (pid 없음 · ≤ 1 · 읽기 실패 · marker 없음): 끝났다고도 살아 있다고도 하지 않는다
        case unprovable
    }

    static func check(_ identity: AgentProcessIdentity) -> Check {
        guard let raw = identity.pid, raw > 1, raw <= Int(Int32.max), UUID(uuidString: identity.processMarker) != nil else { return .unprovable }
        let pid = pid_t(raw)
        switch kernel(pid: pid) {
        case .gone: return .gone
        case .unreadable: return .unprovable
        case .running(let start, let uid, let zombie, _):
            if zombie || abs(start.timeIntervalSince(identity.startedAt)) > 0.001 || uid != getuid() { return .gone }
            guard let arguments = arguments(pid: pid) else { return .unprovable }
            return hasMarker(arguments, identity.processMarker) ? .same : .unprovable
        }
    }

    /// argv에 `--settings <…>/config/<marker>.settings.json`이 있나
    static func hasMarker(_ arguments: [String], _ marker: String) -> Bool {
        let suffix = "/config/\(marker).settings.json"
        return zip(arguments, arguments.dropFirst()).contains { $0 == "--settings" && $1.hasSuffix(suffix) }
    }

    public static func liveness(_ identity: AgentProcessIdentity) -> AgentLiveness {
        switch check(identity) {
        case .same: .alive
        case .gone: .ended(AgentExit(code: nil))
        case .unprovable: .unknown
        }
    }

    /// 정체를 확인한 뒤 SIGINT. 보냈으면 true
    @discardableResult
    public static func interrupt(_ identity: AgentProcessIdentity) -> Bool {
        guard check(identity) == .same, let pid = identity.pid else { return false }
        return kill(pid_t(pid), SIGINT) == 0
    }

    /// 고아 끝내기 (막힘 호출, 메인 스레드 밖에서): SIGINT → 유예 → (다시 확인) 그룹 · 프로세스 SIGKILL → 유예 → 확인.
    /// 사라진 것을 확인했을 때만 `.ended`, 끝내지 못했으면 `.alive`, 확인할 수 없으면 `.unknown`
    public static func terminate(_ identity: AgentProcessIdentity, timing: ClaudeCodeTiming) -> AgentLiveness {
        switch check(identity) {
        case .gone: return .ended(AgentExit(code: nil))
        case .unprovable: return .unknown
        case .same: break
        }
        guard let raw = identity.pid else { return .unknown }
        let pid = pid_t(raw)
        kill(pid, SIGINT)
        if waitGone(identity, timeout: timing.orphanInterruptGrace) { return .ended(AgentExit(code: nil, signal: Int(SIGINT))) }
        guard check(identity) == .same else { return check(identity) == .gone ? .ended(AgentExit(code: nil, signal: Int(SIGINT))) : .unknown }
        if case .running(_, _, _, let group) = kernel(pid: pid), group == pid { killpg(pid, SIGKILL) }
        kill(pid, SIGKILL)
        if waitGone(identity, timeout: timing.orphanKillGrace) { return .ended(AgentExit(code: nil, signal: Int(SIGKILL))) }
        return check(identity) == .same ? .alive : .unknown
    }

    static func waitGone(_ identity: AgentProcessIdentity, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if check(identity) == .gone { return true }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        return check(identity) == .gone
    }

    /// 시험 정리: 그룹째 SIGKILL하고 거둔다
    static func forceKill(_ process: ClaudeSpawnedProcess) -> ClaudeExitStatus {
        killpg(process.pid, SIGKILL)
        kill(process.pid, SIGKILL)
        return process.waitForExit()
    }
}

/// 외부 프로세스 찾기 (ONE-TF-13 보조, 계약 3.8 :231): 같은 사용자 프로세스의 argv에 `--resume <id>` · `-r <id>` · `--session-id <id>`가 있나.
/// 못 찾은 것은 증명이 아니다 (D4a가 확인 창과 함께 쓴다)
public enum ClaudeCodeProcessScanner {
    public static func hasProcess(resuming id: String) -> Bool {
        let flags: Set<String> = ["--resume", "-r", "--session-id"]
        for pid in userProcesses() where pid != getpid() {
            guard let arguments = ClaudeProcessInspector.arguments(pid: pid) else { continue }
            if zip(arguments, arguments.dropFirst()).contains(where: { flags.contains($0) && $1 == id }) { return true }
            if arguments.contains(where: { $0 == "--resume=\(id)" || $0 == "--session-id=\(id)" }) { return true }
        }
        return false
    }

    static func userProcesses() -> [pid_t] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: getuid())]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let count = size / MemoryLayout<kinfo_proc>.stride + 16
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: count)
        size = count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &processes, &size, nil, 0) == 0 else { return [] }
        return processes.prefix(size / MemoryLayout<kinfo_proc>.stride).map(\.kp_proc.p_pid).filter { $0 > 1 }
    }
}
#endif
