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
    /// 답 resume에서 보류 id의 훅을 기다리는 시간 (넘으면 그 spawn을 멈추고 닫힘, 9장 9)
    public var answerTimeout: TimeInterval

    public init(
        orphanInterruptGrace: TimeInterval, orphanKillGrace: TimeInterval, closeTimeout: TimeInterval, exitAfterResult: TimeInterval, drainAfterExit: TimeInterval,
        probeTimeout: TimeInterval, serverTimeout: TimeInterval, answerTimeout: TimeInterval = 10
    ) {
        self.orphanInterruptGrace = orphanInterruptGrace
        self.orphanKillGrace = orphanKillGrace
        self.closeTimeout = closeTimeout
        self.exitAfterResult = exitAfterResult
        self.drainAfterExit = drainAfterExit
        self.probeTimeout = probeTimeout
        self.serverTimeout = serverTimeout
        self.answerTimeout = answerTimeout
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
    /// `executable`을 `arguments`로 띄운다. 환경은 이 사전뿐이다. 실패하면 아무것도 남기지 않고 던진다.
    /// `argv0`: 자식이 보는 이름 (없으면 `executable`). 실행하는 파일은 언제나 `executable`이다 (검사한 realpath로 띄운다, 8장 8)
    public static func spawn(executable: String, argv0: String? = nil, arguments: [String], environment: [String: String], cwd: String) throws -> ClaudeSpawnedProcess {
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

        let argv = ([argv0 ?? executable] + arguments).map { strdup($0) } + [nil]
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
        /// 그 프로세스는 끝났다 (없음 · 좀비). 자손이 남아 있을 수 있지만 그 pid의 그룹은 믿지 않는다 (10장 1: 혈통 · marker로만 찾는다)
        case absent
        /// 그 pid를 다른 프로세스가 쓴다 (시작 시각 · 사용자 다름): 그 프로세스는 끝났고, 그 pid의 그룹은 우리 것이 아니다
        case replaced
        /// 확인할 수 없다 (pid 없음 · ≤ 1 · 읽기 실패 · marker 없음): 끝났다고도 살아 있다고도 하지 않는다
        case unprovable
    }

    static func check(_ identity: AgentProcessIdentity) -> Check {
        guard let raw = identity.pid, raw > 1, raw <= Int(Int32.max), UUID(uuidString: identity.processMarker) != nil else { return .unprovable }
        let pid = pid_t(raw)
        switch kernel(pid: pid) {
        case .gone: return .absent
        case .unreadable: return .unprovable
        case .running(let start, let uid, let zombie, _):
            if abs(start.timeIntervalSince(identity.startedAt)) > 0.001 || uid != getuid() { return .replaced }
            if zombie { return .absent }
            guard let arguments = arguments(pid: pid) else { return .unprovable }
            return hasMarker(arguments, identity.processMarker) ? .same : .unprovable
        }
    }

    /// spawn marker 환경 변수 (9장 4): spawn마다 그 spawn id. 자손이 물려받는다 (세션을 떠난 Bash 자손 포함).
    /// macOS 26.5에서는 남의 프로세스 환경을 읽을 수 없어 이것만으로는 찾지 못한다: 혈통(`ClaudeLineage`)이 주로 찾는다 (정정 제안 9-4)
    public static let markerKey = "TASKFORCE_SPAWN_ID"

    /// 프로세스 한 세대를 한 번에 읽은 것 (10장 2): 시작 시각 · 부모 pid · 그룹 · 사용자 · 상태와 커널 unique id가 같은 프로세스의 것이다.
    /// unique id는 부팅 안에서 다시 쓰지 않고 exec해도 그대로다. 부모 id는 fork · 마지막 exec 때의 부모다: 그 뒤 부모가 끝나 launchd로 옮겨져도 · setsid해도
    /// 그대로지만, 부모가 끝난 뒤 exec하면 launchd(1)가 된다 (notes 증거)
    struct Generation: Equatable {
        let pid: pid_t
        /// 커널 시작 시각 (초 · 마이크로초 그대로)
        let startSeconds: UInt64
        let startMicros: UInt64
        let parentPID: pid_t
        let group: pid_t
        let uid: uid_t
        let zombie: Bool
        let own: UInt64
        let parent: UInt64

        var start: Date { Date(timeIntervalSince1970: TimeInterval(startSeconds) + TimeInterval(startMicros) / 1_000_000) }
    }

    /// `proc_pidinfo(PROC_PIDT_BSDINFOWITHUNIQID = 18, arg 1 = 좀비도)`: `struct proc_bsdinfo`(136바이트) 뒤에 `struct proc_uniqidentifierinfo`
    /// (uuid 16 · uniqueid 8 · puniqueid 8 · idversion 4 · 예비 20 = 56바이트). 커널이 한 프로세스를 잡고 둘을 함께 채운다.
    /// SDK 공개 머리에 없는 flavor라 돌려준 크기가 맞을 때만 믿는다 (정정 제안 9-4)
    static func generation(pid: pid_t) -> Generation? {
        guard pid > 0 else { return nil }
        let bsd = MemoryLayout<proc_bsdinfo>.size
        let total = bsd + 56
        var buffer = [UInt8](repeating: 0, count: total)
        guard proc_pidinfo(pid, 18, 1, &buffer, Int32(total)) == Int32(total) else { return nil }
        let info = buffer.withUnsafeBytes { $0.loadUnaligned(as: proc_bsdinfo.self) }
        let own = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: bsd + 16, as: UInt64.self) }
        let parent = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: bsd + 24, as: UInt64.self) }
        guard own > 1, info.pbi_pid == UInt32(bitPattern: pid) else { return nil }
        return Generation(
            pid: pid, startSeconds: info.pbi_start_tvsec, startMicros: info.pbi_start_tvusec, parentPID: pid_t(bitPattern: info.pbi_ppid), group: pid_t(bitPattern: info.pbi_pgid),
            uid: info.pbi_uid, zombie: info.pbi_status == UInt32(SZOMB), own: own, parent: parent
        )
    }

    /// 커널 unique id (그 프로세스 · 부모)
    static func uniqueIDs(pid: pid_t) -> (own: UInt64, parent: UInt64)? {
        generation(pid: pid).map { ($0.own, $0.parent) }
    }

    /// 이번 부팅의 id (`kern.bootsessionuuid`, 10장 3). 벽시계와 무관하다
    static func bootSessionID() -> String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1, size < 128 else { return nil }
        var chars = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &chars, &size, nil, 0) == 0 else { return nil }
        let value = String(decoding: chars.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return UUID(uuidString: value) != nil ? value : nil
    }

    /// 신호를 보낼 확인된 프로세스 하나: pid + 그 세대의 unique id (보내기 직전에 다시 대조한다)
    struct Member: Equatable {
        let pid: pid_t
        let uniqueID: UInt64
    }

    /// 확인된 프로세스에만 신호를 보낸다: 보내기 직전에 그 pid의 unique id · 사용자가 그대로이고 좀비가 아닐 때만 (그 사이 pid가 재사용됐을 수 있다, 9장 5)
    static func signalVerified(_ members: [Member], _ signal: Int32) {
        for member in members {
            guard let now = generation(pid: member.pid), now.own == member.uniqueID, !now.zombie, now.uid == getuid() else { continue }
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

    /// 그 spawn의 그룹 id를 믿을 수 있을 때만 (10장 1): 부모가 살아 있고(`same`) 그룹 리더일 때. 부모가 없거나(`absent`) · pid가 재사용됐거나(`replaced`) ·
    /// 확인할 수 없으면 그 pid의 그룹은 이미 남의 것일 수 있다 (앱이 멈춘 사이 다른 그룹이 같은 pid를 썼을 수 있다): 혈통과 marker만 쓴다
    static func ownedGroup(_ identity: AgentProcessIdentity, _ parent: Check) -> pid_t? {
        guard parent == .same, let raw = identity.pid, raw > 1, raw <= Int(Int32.max) else { return nil }
        let pid = pid_t(raw)
        if case .running(_, _, _, let leader) = kernel(pid: pid), leader == pid { return pid }
        return nil
    }

    /// 그 spawn의 살아 있는 자손 (부모 자신은 빼고, 9장 4 정정 · 10장 1–3). 뿌리보다 뒤에 만들어진(unique id가 큰) 이 사용자 프로세스 중
    /// ① 자기 id나 부모 id가 혈통에 있거나(세션을 떠난 · 부모가 끝난 자손도) ② 부모가 지금 살아 있는 자손이거나 ③ 믿을 수 있는 그 그룹에 들었거나(살아 있는 리더)
    /// ④ 환경에 `TASKFORCE_SPAWN_ID=<spawn id>`가 보이는 것(그 환경을 읽을 수 있는 OS에서만). 소속은 한 번에 읽은 한 세대의 값으로만 정하고, 목록의 시작 시각과
    /// 다르면(그 사이 pid가 재사용됐다) 그 후보를 버린다. 찾은 것은 혈통에 더한다 (좀비도: 그 자식을 찾는 데 쓴다). 다른 부팅의 혈통이면 훑지 않는다(끝).
    /// 좀비는 끝난 것으로 본다. 목록을 읽지 못하면 nil (끝났다고 보지 않는다)
    static func descendants(_ identity: AgentProcessIdentity, lineage: ClaudeLineage, processes: [kinfo_proc]? = nil) -> [Member]? {
        if lineage.fromOtherBoot { return [] }
        guard let processes = processes ?? userProcessInfos() else { return nil }
        let root = identity.pid.map { pid_t(truncatingIfNeeded: $0) }
        let parentCheck = check(identity)
        if parentCheck == .same { lineage.seed(identity) }
        let group = ownedGroup(identity, parentCheck)
        let rootID = lineage.rootID
        let needle = markerKey + "=" + identity.processMarker
        let me = getpid()
        struct Candidate {
            let generation: Generation
            let marked: Bool
        }
        var pending: [Candidate] = processes.compactMap { info in
            let pid = info.kp_proc.p_pid
            guard pid > 1, pid != me, pid != root, info.kp_eproc.e_ucred.cr_uid == getuid() else { return nil }
            // 같은 세대만 (10장 2): 목록이 본 시작 시각과 한 번에 읽은 세대의 시작 시각이 같아야 그 소속 · id가 한 프로세스의 것이다
            let listed = info.kp_proc.p_un.__p_starttime
            guard let generation = generation(pid: pid), generation.uid == getuid(),
                  Int64(generation.startSeconds) == Int64(listed.tv_sec), Int64(generation.startMicros) == Int64(listed.tv_usec) else { return nil }
            // 자손은 뿌리보다 뒤에 만들어진다 (10장 3: 벽시계가 아니라 unique id 순서)
            if let rootID, generation.own <= rootID { return nil }
            let marked = !generation.zombie && lineage.marked(generation.own) { procArgs(pid: pid)?.environment.contains(needle) == true }
            return Candidate(generation: generation, marked: marked)
        }.sorted { $0.generation.own < $1.generation.own }
        var parents: Set<pid_t> = parentCheck == .same ? root.map { [$0] } ?? [] : []
        var result: [Member] = []
        var progress = true
        while progress {
            progress = false
            pending.removeAll { candidate in
                let generation = candidate.generation
                // 전에 본 그 프로세스이거나(부모 id는 마지막 exec 때의 부모라, 부모가 끝난 뒤 exec하면 launchd 것이 된다) 본 프로세스의 자식
                let byLineage = lineage.contains(generation.own) || lineage.contains(generation.parent)
                guard byLineage || parents.contains(generation.parentPID) || (group != nil && generation.group == group) || candidate.marked else { return false }
                lineage.insert(generation.own)
                if !generation.zombie {
                    parents.insert(generation.pid)
                    result.append(Member(pid: generation.pid, uniqueID: generation.own))
                }
                progress = true
                return true
            }
        }
        lineage.save()
        return result
    }

    /// 부모가 끝났고(다른 프로세스가 그 pid를 쓰더라도) 자손도 하나 없다
    static func allGone(_ identity: AgentProcessIdentity, _ lineage: ClaudeLineage) -> Bool {
        switch check(identity) {
        case .same, .unprovable: return false
        case .absent, .replaced: return descendants(identity, lineage: lineage)?.isEmpty == true
        }
    }

    /// argv에 `--settings <…>/config/<marker>.settings.json`이 있나
    static func hasMarker(_ arguments: [String], _ marker: String) -> Bool {
        let suffix = "/config/\(marker).settings.json"
        return zip(arguments, arguments.dropFirst()).contains { $0 == "--settings" && $1.hasSuffix(suffix) }
    }

    /// 부모가 끝났어도 자손(혈통 · 그룹 · marker)이 살아 있으면 `alive`다 (8장 13 · 9장 4: 자손까지 끝나야 끝).
    /// `lineage`가 없으면 지금 부모(정체가 그대로일 때)에서 시작한다
    public static func liveness(_ identity: AgentProcessIdentity, lineage: ClaudeLineage? = nil) -> AgentLiveness {
        // 다른 부팅의 spawn은 훑지 않고 끝이다 (10장 1)
        if lineage?.fromOtherBoot == true { return .ended(AgentExit(code: nil)) }
        switch check(identity) {
        case .same: return .alive
        case .unprovable: return .unknown
        case .absent, .replaced:
            guard let members = descendants(identity, lineage: lineage ?? ClaudeLineage.seeded(identity)) else { return .unknown }
            return members.isEmpty ? .ended(AgentExit(code: nil)) : .alive
        }
    }

    /// 정체를 확인한 뒤 SIGINT. 보냈으면 true
    @discardableResult
    public static func interrupt(_ identity: AgentProcessIdentity) -> Bool {
        guard check(identity) == .same, let pid = identity.pid else { return false }
        return kill(pid_t(pid), SIGINT) == 0
    }

    /// 고아 끝내기 · Stop 올리기 (막힘 호출, 메인 스레드 밖에서): 부모(정체 확인) · 자손(혈통 · 그룹 · marker로 확인한 pid 하나씩)에 SIGINT → 유예 →
    /// (다시 확인) SIGKILL → 유예 → 확인. 부모와 자손이 모두 사라진 것을 확인했을 때만 `.ended` (8장 13 · 9장 4), 끝내지 못했으면 `.alive`, 확인할 수 없으면 `.unknown`.
    /// `killpg`는 쓰지 않는다: 신호는 확인한 pid에만 간다 (9장 5). `lineage`가 없으면 신호 전에 지금 부모에서 시작한다 (부모가 먼저 끝나도 그 자식을 찾는다)
    public static func terminate(_ identity: AgentProcessIdentity, timing: ClaudeCodeTiming, lineage: ClaudeLineage? = nil) -> AgentLiveness {
        // 다른 부팅의 spawn은 훑지도 신호를 보내지도 않는다: 이미 끝났다 (10장 1)
        if lineage?.fromOtherBoot == true { return .ended(AgentExit(code: nil)) }
        let initial = check(identity)
        if initial == .unprovable { return .unknown }
        guard let raw = identity.pid else { return .unknown }
        let pid = pid_t(raw)
        let lineage = lineage ?? ClaudeLineage.seeded(identity)
        if initial != .same {
            // 부모는 이미 없다: 남은 자손만 본다
            guard let members = descendants(identity, lineage: lineage) else { return .unknown }
            if members.isEmpty { return .ended(AgentExit(code: nil)) }
        }
        signalAll(identity, lineage, parent: pid, SIGINT)
        if waitAllGone(identity, lineage, timeout: timing.orphanInterruptGrace) { return .ended(AgentExit(code: nil, signal: Int(SIGINT))) }
        if check(identity) == .unprovable { return .unknown }
        signalAll(identity, lineage, parent: pid, SIGKILL)
        if waitAllGone(identity, lineage, timeout: timing.orphanKillGrace) { return .ended(AgentExit(code: nil, signal: Int(SIGKILL))) }
        if check(identity) == .same || descendants(identity, lineage: lineage)?.isEmpty == false { return .alive }
        return .unknown
    }

    /// 부모(정체가 그대로일 때) · 확인한 자손에 신호. 자손을 먼저 훑는다 (부모가 끝나기 전에 그 자식을 혈통에 넣는다)
    static func signalAll(_ identity: AgentProcessIdentity, _ lineage: ClaudeLineage, parent pid: pid_t, _ signal: Int32) {
        let members = descendants(identity, lineage: lineage)
        if check(identity) == .same { kill(pid, signal) }
        if let members { signalVerified(members, signal) }
    }

    static func waitAllGone(_ identity: AgentProcessIdentity, _ lineage: ClaudeLineage, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if allGone(identity, lineage) { return true }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        return allGone(identity, lineage)
    }

    /// 감독하던 자식을 거둔 뒤 남은 자손(혈통 · 그룹 · marker)을 끝낸다 (막힘 호출, 8장 13 · 9장 4): SIGINT → 유예 → SIGKILL. 남은 것이 없거나 다 끝났으면 true
    static func endDescendants(_ identity: AgentProcessIdentity, lineage: ClaudeLineage, timing: ClaudeCodeTiming) -> Bool {
        guard let members = descendants(identity, lineage: lineage) else { return false }
        if members.isEmpty { return true }
        signalVerified(members, SIGINT)
        if waitAllGone(identity, lineage, timeout: timing.orphanInterruptGrace) { return true }
        signalVerified(descendants(identity, lineage: lineage) ?? [], SIGKILL)
        return waitAllGone(identity, lineage, timeout: timing.orphanKillGrace)
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
