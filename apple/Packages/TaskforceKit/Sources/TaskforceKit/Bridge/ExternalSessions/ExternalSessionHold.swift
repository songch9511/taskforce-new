#if os(macOS)
import Darwin
import Foundation
import TaskforceAgentWire

/// 프로세스 사실 (시험은 가짜로 바꾼다). 판정은 한 번 훑을 때마다 **한 번씩** 이 사실을 모아 `Snapshot`을 만들고, 줄마다 그 스냅샷으로 가린다 (줄 × 프로세스를 훑지 않는다)
public struct ExternalSessionProcessFacts: Sendable {
    public enum Lookup: Equatable, Sendable {
        /// 살아 있다 (좀비 아님): 커널 시작 시각과 소유자
        case present(start: Date, uid: UInt32)
        case gone
        case failed
    }

    public var userID: UInt32
    public var lookup: @Sendable (Int32) -> Lookup
    /// 같은 사용자 프로세스의 argv에서 `--resume <id>` · `-r <id>` · `--session-id <id>` · `--resume=<id>`로 가리킨 세션 id 전부. 프로세스 목록을 못 읽으면 nil
    public var argumentSessionIDs: @Sendable (_ excluding: Set<Int32>) -> Set<String>?
    /// 등록 파일이 없는 `claude` 프로세스(registered 밖)의 cwd 전부 (커널이 준 실제 경로). 프로세스 목록을 못 읽으면 nil
    public var unregisteredClaudeFolders: @Sendable (_ registered: Set<Int32>, _ excluding: Set<Int32>) -> Set<String>?

    public init(
        userID: UInt32, lookup: @escaping @Sendable (Int32) -> Lookup, argumentSessionIDs: @escaping @Sendable (Set<Int32>) -> Set<String>?,
        unregisteredClaudeFolders: @escaping @Sendable (Set<Int32>, Set<Int32>) -> Set<String>?
    ) {
        self.userID = userID
        self.lookup = lookup
        self.argumentSessionIDs = argumentSessionIDs
        self.unregisteredClaudeFolders = unregisteredClaudeFolders
    }

    public static let live = ExternalSessionProcessFacts(
        userID: getuid(), lookup: { Live.lookup($0) }, argumentSessionIDs: { Live.argumentSessionIDs(excluding: $0) },
        unregisteredClaudeFolders: { Live.unregisteredClaudeFolders(registered: $0, excluding: $1) }
    )

    enum Live {
        static func lookup(_ pid: Int32) -> Lookup {
            switch ClaudeProcessInspector.kernel(pid: pid) {
            case .present(let listed): listed.zombie ? .gone : .present(start: listed.start, uid: listed.uid)
            case .gone: .gone
            case .failed: .failed
            }
        }

        static let sessionFlags: Set<String> = ["--resume", "-r", "--session-id"]

        static func argumentSessionIDs(excluding: Set<Int32>) -> Set<String>? {
            guard let pids = AgentProcesses.userPIDs() else { return nil }
            var ids = Set<String>()
            for pid in pids where pid > 1 && pid != getpid() && !excluding.contains(pid) {
                guard let arguments = ClaudeProcessInspector.arguments(pid: pid) else { continue }
                for (flag, value) in zip(arguments, arguments.dropFirst()) where sessionFlags.contains(flag) && ExternalSessionRules.isCanonicalUUID(value) { ids.insert(value) }
                for argument in arguments {
                    for prefix in ["--resume=", "--session-id="] where argument.hasPrefix(prefix) {
                        let value = String(argument.dropFirst(prefix.count))
                        if ExternalSessionRules.isCanonicalUUID(value) { ids.insert(value) }
                    }
                }
            }
            return ids
        }

        /// 실행 파일 이름이 `claude`인 프로세스의 cwd (`PROC_PIDVNODEPATHINFO`)
        static func unregisteredClaudeFolders(registered: Set<Int32>, excluding: Set<Int32>) -> Set<String>? {
            guard let pids = AgentProcesses.userPIDs() else { return nil }
            var folders = Set<String>()
            for pid in pids where pid > 1 && pid != getpid() && !registered.contains(pid) && !excluding.contains(pid) {
                // `proc_pidinfo`가 주는 cwd는 이미 실제 경로다: 다시 파일 시스템으로 풀지 않는다 (보호 폴더 접근 동의 창이 뜨지 않게)
                guard executableName(pid) == "claude", let cwd = currentDirectory(pid) else { continue }
                folders.insert(cwd)
            }
            return folders
        }

        static func executableName(_ pid: Int32) -> String? {
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
            return (ExternalSessionFileSystem.Live.string(fromCString: buffer) as NSString).lastPathComponent
        }

        static func currentDirectory(_ pid: Int32) -> String? {
            var info = proc_vnodepathinfo()
            let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
            return withUnsafePointer(to: &info.pvi_cdir.vip_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
        }
    }
}

/// 그 세션을 이미 쥔 곳이 있나 (OA 외부 세션 PR1, 계약 5.4). **모르면 막는다(fail-closed).**
/// 신호 순서: ① 세션 등록 파일(pid가 살아 있고 같은 사용자이고 시작 시각이 `procStart`와 1초 안 — 시간대 없는 `lstart`는 이 Mac · UTC 두 가지로 읽는다) ② argv ③ 같은 cwd의 등록 안 된 `claude` ④ 기록이 60초 안에 쓰임.
/// ⑤ 백그라운드(agent view)는 R7 전까지 등록 파일의 `kind`만 본다.
enum ExternalSessionHold {
    enum Result: Equatable, Sendable {
        case free
        case held(ExternalSessionHolder)
        /// 판정을 못 했다 (신호를 읽지 못했고 쥔 것도 못 찾았다): 막는다
        case unknown
        /// 등록 파일의 cwd가 기록의 cwd와 다르다: 판정하지 않고 "읽을 수 없음" (5.3-3)
        case cwdMismatch
    }

    static let recentWindow: TimeInterval = 60
    /// pid 재사용을 가리는 시작 시각 허용 오차 (계약: 1초 안)
    static let startTolerance: TimeInterval = 1

    struct LiveEntry: Equatable, Sendable {
        var sessionID: String
        var holder: ExternalSessionHolder
        var cwd: String?
    }

    /// 한 번 훑을 때 모은 사실
    struct Snapshot: Sendable {
        var live: [LiveEntry]
        var registryUnavailable: Bool
        var argumentIDs: Set<String>?
        var claudeFolders: Set<String>?
        var now: Date
    }

    static func snapshot(
        facts: ExternalSessionProcessFacts, fileSystem: ExternalSessionFileSystem, sessionsDirectory: String, ownPIDs: Set<Int32>, now: Date, localZone: TimeZone = .current
    ) -> Snapshot {
        var live: [LiveEntry] = []
        var registeredPIDs = Set<Int32>()
        var unavailable = false
        switch ExternalSessionRegistry.read(fileSystem: fileSystem, sessionsDirectory: sessionsDirectory, now: now, localZone: localZone) {
        case .unavailable:
            unavailable = true
        case .entries(let entries):
            for entry in entries {
                registeredPIDs.insert(entry.pid)
                guard !ownPIDs.contains(entry.pid), isAlive(entry, facts: facts) else { continue }
                live.append(LiveEntry(sessionID: entry.sessionID, holder: holder(entry), cwd: entry.cwd))
            }
        }
        return Snapshot(
            live: live, registryUnavailable: unavailable, argumentIDs: facts.argumentSessionIDs(ownPIDs),
            claudeFolders: facts.unregisteredClaudeFolders(registeredPIDs, ownPIDs), now: now
        )
    }

    /// 살아 있다 · 같은 사용자 · 시작 시각이 맞다 (pid 재사용이면 stale). 시작 시각을 모르거나 조회가 실패하면 살아 있는 것으로 본다 (fail-closed).
    /// 시간대 없는 `lstart` 글은 두 가지로 읽었다 (`procStartAlternate`): 어느 쪽이든 1초 안이면 같은 프로세스다. 둘 다 아니어야 pid 재사용이다
    static func isAlive(_ entry: ExternalSessionRegistry.Entry, facts: ExternalSessionProcessFacts) -> Bool {
        switch facts.lookup(entry.pid) {
        case .gone: return false
        case .failed: return true
        case .present(let start, let uid):
            guard uid == facts.userID else { return false }
            guard let recorded = entry.procStart else { return true }
            return [recorded, entry.procStartAlternate].compactMap { $0 }.contains { abs(start.timeIntervalSince($0)) <= startTolerance }
        }
    }

    static func holder(_ entry: ExternalSessionRegistry.Entry) -> ExternalSessionHolder {
        if entry.kind?.lowercased().contains("background") == true { return .background }
        switch entry.entrypoint {
        case "claude-desktop": return .claudeApp
        case "cli": return .terminal
        default: return .unknown
        }
    }

    /// - cwd: 기록의 cwd (글자 그대로, 모르면 nil). 파일 시스템으로 열지 않는다
    static func decide(id: String, cwd: String?, modified: Date, snapshot: Snapshot) -> Result {
        let mine = snapshot.live.filter { $0.sessionID == id }
        if !mine.isEmpty {
            if let cwd, mine.contains(where: { $0.cwd != nil && $0.cwd != cwd }) { return .cwdMismatch }
            let order: [ExternalSessionHolder] = [.claudeApp, .terminal, .background, .unknown]
            if let holder = order.first(where: { holder in mine.contains { $0.holder == holder } }) { return .held(holder) }
        }
        if snapshot.argumentIDs?.contains(id) == true { return .held(.terminal) }
        if let cwd, snapshot.claudeFolders?.contains(cwd) == true { return .held(.unknown) }
        // 방금 쓰였다 (미래 시각도 방금으로 본다)
        if snapshot.now.timeIntervalSince(modified) < recentWindow { return .held(.unknown) }
        if snapshot.registryUnavailable || snapshot.argumentIDs == nil || snapshot.claudeFolders == nil { return .unknown }
        return .free
    }
}
#endif
