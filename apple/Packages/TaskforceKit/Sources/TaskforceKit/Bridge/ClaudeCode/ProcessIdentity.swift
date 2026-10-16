#if os(macOS)
import Darwin
import Foundation
import Synchronization
import TaskforceAgentWire

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
    /// 답 resume에서 보류 id의 훅을 기다리는 시간 (넘으면 그 spawn을 멈추고 닫힘, 9장 9)
    public var answerTimeout: TimeInterval
    /// 구성원을 끝낸 뒤 지킴이가 구성원 0을 증명하고 스스로 끝나기를 기다리는 시간 (13장 4, 넘으면 unknown)
    public var keeperExit: TimeInterval

    public init(
        orphanInterruptGrace: TimeInterval, orphanKillGrace: TimeInterval, closeTimeout: TimeInterval, exitAfterResult: TimeInterval, drainAfterExit: TimeInterval,
        probeTimeout: TimeInterval, serverTimeout: TimeInterval, answerTimeout: TimeInterval = 10, keeperExit: TimeInterval = 3
    ) {
        self.orphanInterruptGrace = orphanInterruptGrace
        self.orphanKillGrace = orphanKillGrace
        self.closeTimeout = closeTimeout
        self.exitAfterResult = exitAfterResult
        self.drainAfterExit = drainAfterExit
        self.probeTimeout = probeTimeout
        self.serverTimeout = serverTimeout
        self.answerTimeout = answerTimeout
        self.keeperExit = keeperExit
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
    /// disclaim을 켜고 띄웠다 (지킴이, 13장 1)
    let disclaimed: Bool
    let stdinFD: Int32
    let stdoutFD: Int32
    let stderrFD: Int32
    private let reaped = Mutex<ClaudeExitStatus?>(nil)

    init(pid: pid_t, startedAt: Date, disclaimed: Bool, stdinFD: Int32, stdoutFD: Int32, stderrFD: Int32) {
        self.pid = pid
        self.startedAt = startedAt
        self.disclaimed = disclaimed
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

    /// 거뒀으면 그 상태 (막지 않는다)
    var exitStatus: ClaudeExitStatus? { reaped.withLock { $0 } }

    /// 기한 안에 끝나면 거둔 상태, 아니면 nil (`WNOHANG`로 본다)
    func waitForExit(timeout: TimeInterval) -> ClaudeExitStatus? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let done = exitStatus { return done }
            var status: Int32 = 0
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid {
                let low = status & 0x7f
                let value = low == 0 ? ClaudeExitStatus(code: (status >> 8) & 0xff, signal: nil) : ClaudeExitStatus(code: nil, signal: low)
                return reaped.withLock { current in
                    current = current ?? value
                    return current
                }
            }
            if result < 0, errno != EINTR { return exitStatus }
            Thread.sleep(forTimeInterval: 0.02)
        } while Date() < deadline
        return exitStatus
    }
}

/// 지킴이를 거쳐 띄운 `claude` 하나 (13장 1): 지킴이 프로세스(앱의 자식, `claude`의 표준 셋 파이프를 가진다)와 지킴이가 알린 `claude`의 정체
struct ClaudeKeptSpawn {
    let keeper: ClaudeSpawnedProcess
    let keeperID: UInt64
    let claudePID: pid_t
    let claudeID: UInt64
    let claudeStartedAt: Date
    /// 지킴이가 자기 책임 프로세스다 (아니면 구성원을 증명할 수 없다, 13장 5)
    let attributable: Bool
    /// 지킴이 보고의 남은 줄(`exited`)을 읽을 fd
    let reportFD: Int32
}

public enum ClaudeSpawner {
    /// `executable`을 `arguments`로 띄운다 (disclaim 없음: probe · 시험). 환경은 이 사전뿐이다. 실패하면 아무것도 남기지 않고 던진다.
    /// `argv0`: 자식이 보는 이름 (없으면 `executable`). 실행하는 파일은 언제나 `executable`이다 (검사한 realpath로 띄운다, 8장 8)
    public static func spawn(executable: String, argv0: String? = nil, arguments: [String], environment: [String: String], cwd: String) throws -> ClaudeSpawnedProcess {
        try launch(executable: executable, argv0: argv0, arguments: arguments, environment: environment, cwd: cwd, disclaim: false, report: nil)
    }

    private static func launch(
        executable: String, argv0: String?, arguments: [String], environment: [String: String], cwd: String, disclaim: Bool, report: Int32?
    ) throws -> ClaudeSpawnedProcess {
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
        var fds: [(child: Int32, parent: Int32)] = [(0, input[0]), (1, output[1]), (2, errors[1])]
        if let report { fds.append((3, report)) }
        let spawned = AgentSpawn.spawn(executable: executable, argv0: argv0, arguments: arguments, environment: environment, cwd: cwd, fds: fds, disclaim: disclaim)
        close(input[0])
        close(output[1])
        close(errors[1])
        guard let spawned else {
            close(input[1])
            close(output[0])
            close(errors[0])
            throw AgentStartError(.spawnFailed)
        }
        // 커널 시작 시각을 못 읽으면 정체를 만들 수 없다: 지금 시각으로 메우지 않고 멈춘다 (12장 7: 조회 실패를 값으로 바꾸지 않는다)
        guard let started = ClaudeProcessInspector.startTime(pid: spawned.pid) else {
            kill(spawned.pid, SIGKILL)
            var status: Int32 = 0
            while waitpid(spawned.pid, &status, 0) < 0, errno == EINTR {}
            close(input[1])
            close(output[0])
            close(errors[0])
            throw AgentStartError(.spawnFailed)
        }
        return ClaudeSpawnedProcess(pid: spawned.pid, startedAt: started, disclaimed: spawned.disclaimed, stdinFD: input[1], stdoutFD: output[0], stderrFD: errors[0])
    }

    /// 지킴이를 disclaim으로 띄우고, 지킴이가 `claude`를 띄운다 (13장 1). 지킴이의 첫 보고(`started`)로 `claude` pid · unique id를 받아 앱이 다시 대조한다:
    /// 지킴이 · `claude` 둘 다 그 세대를 같은 id로 읽어야 하고 `claude`의 부모가 지킴이여야 한다 (12장 6: 뿌리 id가 전제). 아니면 정체 commit · stdin 전에
    /// `claude`(지킴이가 아직 거두지 않은 자식이라 그 pid는 다른 프로세스가 쓸 수 없다)를 SIGKILL하고 지킴이를 거둔 뒤 던진다
    static func spawnKept(
        keeper: String, ended: URL, executable: String, argv0: String, arguments: [String], environment: [String: String], cwd: String, reportTimeout: TimeInterval = 5
    ) throws -> ClaudeKeptSpawn {
        var report: [Int32] = [-1, -1]
        guard pipe(&report) == 0 else { throw AgentStartError(.spawnFailed) }
        for fd in report { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        let keeperArguments = ["--report-fd", "3", "--ended", ended.path, "--cwd", cwd, "--", executable, argv0] + arguments
        let process: ClaudeSpawnedProcess
        do {
            process = try launch(executable: keeper, argv0: nil, arguments: keeperArguments, environment: environment, cwd: cwd, disclaim: true, report: report[1])
        } catch {
            close(report[0])
            close(report[1])
            throw error
        }
        close(report[1])
        let line = readReportLine(report[0], timeout: reportTimeout)
        if case .started(let claudePID, let claudeID, let keeperID, let attributable)? = line.flatMap(KeeperReport.init(line:)) {
            let lookups = ClaudeProcessInspector.lookups
            if case .present(let keeperNow) = lookups.generation(process.pid), keeperNow.own == keeperID, !keeperNow.zombie {
                if case .present(let claudeNow) = lookups.generation(claudePID), claudeNow.own == claudeID, claudeNow.parentPID == process.pid, !claudeNow.zombie {
                    return ClaudeKeptSpawn(
                        keeper: process, keeperID: keeperID, claudePID: claudePID, claudeID: claudeID, claudeStartedAt: claudeNow.start, attributable: attributable,
                        reportFD: report[0]
                    )
                }
            }
        }
        abort(process, reportFD: report[0], timeout: reportTimeout)
        throw AgentStartError(.spawnFailed)
    }

    /// 정체를 적기 전에 그 spawn을 거둔다: stdin을 닫고(EOF), 지킴이에 SIGTERM(지킴이가 아직 거두지 않은 `claude`를 SIGKILL하고 구성원 0을 증명하고 끝난다),
    /// 기한 안에 끝나지 않으면 지킴이를 SIGKILL하고 거둔다. 지킴이는 앱의 자식이라 거두기 전에는 그 pid를 다른 프로세스가 쓸 수 없다
    static func abort(_ keeper: ClaudeSpawnedProcess, reportFD: Int32, timeout: TimeInterval) {
        keeper.closeStandardStreams()
        close(reportFD)
        kill(keeper.pid, SIGTERM)
        if keeper.waitForExit(timeout: timeout) == nil {
            kill(keeper.pid, SIGKILL)
            _ = keeper.waitForExit()
        }
    }

    /// 보고 한 줄 (기한 안에서, 줄바꿈 전까지). 기한 · EOF · 너무 긴 줄이면 nil
    static func readReportLine(_ fd: Int32, timeout: TimeInterval) -> String? {
        var line = Data()
        let deadline = Date().addingTimeInterval(timeout)
        var byte: UInt8 = 0
        while line.count < 256 {
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { return nil }
            var item = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&item, 1, Int32(max(1, (left * 1000).rounded(.up))))
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { return nil }
            let count = read(fd, &byte, 1)
            if count < 0, errno == EINTR || errno == EAGAIN { continue }
            guard count == 1 else { return nil }
            if byte == 0x0A { return String(decoding: line, as: UTF8.self) }
            line.append(byte)
        }
        return nil
    }
}

/// 정체 확인 · 신호 (계약 2.14): pid > 1 + 커널 시작 시각 1ms 안 + 소유자 uid + argv의 `--settings …/config/<marker>.settings.json`.
/// 신호마다 정체를 다시 본다. SIGTERM은 쓰지 않는다 (13.2 :513, Q12). 구성원 · 끝은 지킴이로 본다 (13장)
public enum ClaudeProcessInspector {
    /// `KERN_PROC_PID`로 읽은 한 프로세스 (시작 시각은 초 · 마이크로초 그대로)
    struct Listed: Equatable, Sendable {
        let startSeconds: Int64
        let startMicros: Int64
        let uid: uid_t
        let zombie: Bool
        let group: pid_t

        var start: Date { Date(timeIntervalSince1970: TimeInterval(startSeconds) + TimeInterval(startMicros) / 1_000_000) }
    }

    static func kernel(pid: pid_t) -> ProcessLookup<Listed> {
        guard pid > 0 else { return .failed }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else { return errno == ESRCH ? .gone : .failed }
        guard size > 0, info.kp_proc.p_pid == pid else { return .gone }
        let start = info.kp_proc.p_un.__p_starttime
        return .present(Listed(
            startSeconds: Int64(start.tv_sec), startMicros: Int64(start.tv_usec), uid: info.kp_eproc.e_ucred.cr_uid, zombie: info.kp_proc.p_stat == SZOMB,
            group: info.kp_eproc.e_pgid
        ))
    }

    public static func startTime(pid: pid_t) -> Date? {
        if case .present(let listed) = kernel(pid: pid) { return listed.start }
        return nil
    }

    /// 구성원 훑기가 쓰는 조회 (12장 7). 시험이 실패 · 사라짐을 끼워 넣는다 (`$lookups.withValue`). GCD 스레드에서는 언제나 실제 조회다
    @TaskLocal static var lookups = KeeperMembers.Lookups.live

    /// `KERN_PROCARGS2`: argc, 실행 경로, 그 뒤 argv (같은 사용자 프로세스만 읽힌다)
    static func arguments(pid: pid_t) -> [String]? {
        procArgs(pid: pid)?.arguments
    }

    /// `KERN_PROCARGS2`의 argv와 그 뒤 환경 (`KEY=value`, 빈 글자에서 끝). 읽지 못하면 nil
    static func procArgs(pid: pid_t) -> (arguments: [String], environment: [String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 } // 실행 경로
        while index < size, buffer[index] == 0 { index += 1 } // 채움
        func next() -> String {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            defer { index += 1 }
            return String(decoding: buffer[start..<index], as: UTF8.self)
        }
        var arguments: [String] = []
        while arguments.count < Int(argc), index < size { arguments.append(next()) }
        var environment: [String] = []
        while index < size {
            let entry = next()
            if entry.isEmpty { break }
            environment.append(entry)
        }
        return (arguments, environment)
    }

    enum Check: Equatable {
        case same
        /// 그 프로세스는 끝났다 (없음 · 좀비)
        case absent
        /// 그 pid를 다른 프로세스가 쓴다 (시작 시각 · 사용자 다름): 그 프로세스는 끝났다
        case replaced
        /// 확인할 수 없다 (pid 없음 · ≤ 1 · 읽기 실패 · marker 없음): 끝났다고도 살아 있다고도 하지 않는다
        case unprovable
    }

    static func check(_ identity: AgentProcessIdentity) -> Check {
        guard let raw = identity.pid, raw > 1, raw <= Int(Int32.max), UUID(uuidString: identity.processMarker) != nil else { return .unprovable }
        let pid = pid_t(raw)
        switch kernel(pid: pid) {
        case .gone: return .absent
        case .failed: return .unprovable
        case .present(let listed):
            if abs(listed.start.timeIntervalSince(identity.startedAt)) > 0.001 || listed.uid != getuid() { return .replaced }
            if listed.zombie { return .absent }
            guard let arguments = arguments(pid: pid) else { return .unprovable }
            return hasMarker(arguments, identity.processMarker) ? .same : .unprovable
        }
    }

    /// spawn marker 환경 변수 (9장 4): spawn마다 그 spawn id. `claude` 환경에 그대로 둔다 (구성원은 지킴이로 찾는다, 13장)
    public static let markerKey = "TASKFORCE_SPAWN_ID"

    typealias Generation = ProcessGeneration

    static func generation(pid: pid_t) -> ProcessLookup<ProcessGeneration> {
        AgentProcesses.generation(pid: pid)
    }

    /// 커널 unique id (그 프로세스 · 부모). 읽은 세대가 있을 때만
    static func uniqueIDs(pid: pid_t) -> (own: UInt64, parent: UInt64)? {
        if case .present(let generation) = generation(pid: pid) { return (generation.own, generation.parent) }
        return nil
    }

    static func bootSessionID() -> String? {
        AgentProcesses.bootSessionID()
    }

    /// 신호를 보낼 확인된 프로세스 하나: pid + 그 세대의 unique id (보내기 직전에 다시 대조한다)
    struct Member: Equatable {
        let pid: pid_t
        let uniqueID: UInt64
    }

    /// 확인된 프로세스에만 신호를 보낸다: 보내기 직전에 그 pid의 unique id · 사용자가 그대로이고 좀비가 아닐 때만 (그 사이 pid가 재사용됐을 수 있다, 9장 5)
    static func signalVerified(_ members: [Member], _ signal: Int32) {
        for member in members {
            guard case .present(let now) = generation(pid: member.pid), now.own == member.uniqueID, !now.zombie, now.uid == getuid() else { continue }
            kill(member.pid, signal)
        }
    }

    /// 이 사용자의 모든 프로세스 (`KERN_PROC_UID`). 읽지 못하면 nil
    static func userProcessInfos() -> [kinfo_proc]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: getuid())]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return nil }
        if size == 0 { return [] }
        let count = size / MemoryLayout<kinfo_proc>.stride + 16
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: count)
        size = count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &processes, &size, nil, 0) == 0 else { return nil }
        return Array(processes.prefix(size / MemoryLayout<kinfo_proc>.stride))
    }

    // MARK: 지킴이 (13장)

    enum KeeperState: Equatable {
        /// 그 pid의 지금 세대가 지킴이 id이고 끝나지 않았다
        case alive
        /// 지킴이는 끝났다 (없음 · 좀비 · 다른 프로세스가 그 pid를 쓴다)
        case gone
        /// 확인할 수 없다
        case failed
    }

    static func keeperState(_ keeper: ClaudeLineage.Keeper) -> KeeperState {
        switch lookups.generation(keeper.pid) {
        case .present(let now): now.own == keeper.uniqueID && !now.zombie ? .alive : .gone
        case .gone: .gone
        case .failed: .failed
        }
    }

    /// 지킴이의 구성원 (13장 2: 책임 프로세스가 지킴이 ∧ unique id > 지킴이 id, 지킴이가 그 pid로 살아 있을 때만). 찾은 것은 불완전한 훑기여도 신호 대상이다.
    /// 지킴이가 없거나 목록을 읽지 못하면 nil
    static func members(_ keeper: ClaudeLineage.Keeper) -> [Member]? {
        KeeperMembers.scan(keeperPID: keeper.pid, keeperID: keeper.uniqueID, lookups: lookups)?.members.map { Member(pid: $0.pid, uniqueID: $0.own) }
    }

    /// 끝 판정 (13장 3): 끝 = (지킴이가 사라짐 ∧ 그 지킴이의 끝 기록) 또는 (앱이 부모로서 받은 지킴이 정상 종료, `lineage.keeperExited`). `claude`가 정체 그대로면 `alive`,
    /// 지킴이가 살아 있으면 `alive`(구성원이 있거나 곧 끝난다). 그 밖(지킴이가 기록 없이 사라짐 · 비정상 종료 · 확인 못 함 · 혈통 없음) = `unknown`(잠금)
    public static func liveness(_ identity: AgentProcessIdentity, lineage: ClaudeLineage? = nil) -> AgentLiveness {
        if lineage?.provenEnded == true { return .ended(AgentExit(code: nil)) }
        if check(identity) == .same { return .alive }
        guard let lineage, let keeper = lineage.keeper else { return .unknown }
        switch keeperState(keeper) {
        case .alive: return .alive
        case .failed: return .unknown
        case .gone:
            guard lineage.keeperRecorded() else { return .unknown }
            return .ended(AgentExit(code: nil))
        }
    }

    /// 정체를 확인한 뒤 SIGINT. 보냈으면 true
    @discardableResult
    public static func interrupt(_ identity: AgentProcessIdentity) -> Bool {
        guard check(identity) == .same, let pid = identity.pid else { return false }
        return kill(pid_t(pid), SIGINT) == 0
    }

    /// Stop 올리기 · 고아 끝내기 (막힘 호출, 메인 스레드 밖에서, 13장 4): `claude`(정체 확인) + 구성원(책임 프로세스 = 지킴이, pid마다 unique id 대조)에 SIGINT →
    /// 유예 → SIGKILL, 그 뒤 지킴이가 구성원 0을 증명하고 스스로 끝나기를 기다린다(`keeperExit`, 넘으면 `unknown`). 지킴이에는 신호를 보내지 않는다(앱이 마지막에만).
    /// 구성원을 증명할 수 없는 혈통(지킴이 없음 · 책임 함수 물러남 · 지킴이 비정상 종료)이면 정체를 확인한 `claude`에만 신호를 보내고 `unknown`이다 (13장 5)
    public static func terminate(_ identity: AgentProcessIdentity, timing: ClaudeCodeTiming, lineage: ClaudeLineage?) -> AgentLiveness {
        if lineage?.provenEnded == true { return .ended(AgentExit(code: nil)) }
        let keeper = lineage?.provable == true ? lineage?.keeper : nil
        func signal(_ number: Int32) {
            if check(identity) == .same, let raw = identity.pid { kill(pid_t(raw), number) }
            if let keeper, let members = members(keeper) { signalVerified(members, number) }
        }
        if let ended = settled(identity, lineage, keeper) { return ended }
        // 증명할 길도 신호를 보낼 확인된 프로세스도 없다
        if keeper == nil, check(identity) != .same { return .unknown }
        signal(SIGINT)
        if let ended = wait(identity, lineage, keeper, timeout: timing.orphanInterruptGrace) { return ended.signalled(SIGINT) }
        signal(SIGKILL)
        if let ended = wait(identity, lineage, keeper, timeout: timing.orphanKillGrace + (keeper == nil ? 0 : timing.keeperExit)) { return ended.signalled(SIGKILL) }
        return check(identity) == .same ? .alive : .unknown
    }

    /// 끝이 정해졌으면 그 값: 끝 기록 · 정상 종료가 있으면 `ended`, 지킴이가 기록 없이 사라졌으면 `unknown`. `claude`나 지킴이가 아직 살아 있으면 nil
    static func settled(_ identity: AgentProcessIdentity, _ lineage: ClaudeLineage?, _ keeper: ClaudeLineage.Keeper?) -> AgentLiveness? {
        if lineage?.provenEnded == true { return .ended(AgentExit(code: nil)) }
        if check(identity) == .same { return nil }
        guard let lineage, let keeper else { return nil }
        switch keeperState(keeper) {
        case .alive, .failed: return nil
        case .gone: return lineage.keeperRecorded() ? .ended(AgentExit(code: nil)) : .unknown
        }
    }

    static func wait(_ identity: AgentProcessIdentity, _ lineage: ClaudeLineage?, _ keeper: ClaudeLineage.Keeper?, timeout: TimeInterval) -> AgentLiveness? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let result = settled(identity, lineage, keeper) { return result }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        return settled(identity, lineage, keeper)
    }

    /// argv에 `--settings <…>/config/<marker>.settings.json`이 있나
    static func hasMarker(_ arguments: [String], _ marker: String) -> Bool {
        let suffix = "/config/\(marker).settings.json"
        return zip(arguments, arguments.dropFirst()).contains { $0 == "--settings" && $1.hasSuffix(suffix) }
    }

    /// 시험 정리: 그룹째 SIGKILL하고 거둔다
    static func forceKill(_ process: ClaudeSpawnedProcess) -> ClaudeExitStatus {
        killpg(process.pid, SIGKILL)
        kill(process.pid, SIGKILL)
        return process.waitForExit()
    }
}

private extension AgentLiveness {
    /// 끝이면 그 신호로 끝낸 것으로 적는다
    func signalled(_ signal: Int32) -> AgentLiveness {
        if case .ended = self { return .ended(AgentExit(code: nil, signal: Int(signal))) }
        return self
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
        (AgentProcesses.userPIDs() ?? []).filter { $0 > 1 }
    }
}
#endif
