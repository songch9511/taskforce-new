#if os(macOS)
import Darwin
import Foundation
import Synchronization

/// 한 spawn의 혈통 (OA D3a 9장 4, 정정 제안 9-4): 그 spawn에서 나온 프로세스를 커널 unique id로 기억한다.
///
/// 계약은 spawn marker 환경 변수를 `KERN_PROCARGS2`로 읽어 자손을 찾으라고 했지만, macOS 26.5에서는 같은 사용자 · 샌드박스 밖이라도 남의 프로세스 환경이 비어 온다
/// (notes 정정 제안 9-4 증거). 그래서 커널 계보를 쓴다: 프로세스마다 부팅 안에서 다시 쓰지 않는 unique id가 있고(exec해도 그대로), 자식은 fork · exec 때의
/// 부모 id를 갖는다 (그 뒤 부모가 끝나 launchd로 옮겨져도, setsid로 세션을 떠나도 그대로다). 그래서 한 번 본 프로세스와 그 자식은 언제든 찾는다.
/// 남는 틈: 한 번도 못 본 중간 프로세스가 자식을 만들고 끝나거나, 자식이 부모가 끝난 뒤에 exec하면(부모 id가 launchd 것이 된다) 그 자식은 놓친다.
/// 감독하는 동안 본 프로세스마다 `NOTE_FORK`를 걸어 새 자식이 생기는 순간 다시 훑고(아니면 0.1초마다), 거두기 전의 좀비도 본다.
/// 본 id는 `<sessionsRoot>/lineage/<spawn id>.lineage`에도 적는다 (앱이 다시 떠도 고아 정리가 쓴다). 부팅이 다르면 그 파일은 쓰지 않는다 (id는 부팅마다 새로 센다).
/// 글 · 경로 · 명령은 적지 않는다: 숫자뿐이다
public final class ClaudeLineage: Sendable {
    struct Key: Hashable {
        let pid: pid_t
        let start: Date
    }

    struct State {
        var ids: Set<UInt64> = []
        /// 환경을 읽어 marker가 없던 프로세스: 다시 읽지 않는다
        var unmarked: Set<Key> = []
        var dirty = false
        var stopped = false
    }

    private let state = Mutex(State())
    let file: URL?

    /// `file`이 있고 이번 부팅에 적힌 것이면 그 id로 시작한다
    init(file: URL? = nil) {
        self.file = file
        if let file, let saved = Self.load(file) { state.withLock { $0.ids = saved } }
    }

    /// 지금 정체가 그대로인 부모(`same`)에서 시작한다 (감독 밖: 다시 뜬 앱의 고아 정리, 시험)
    static func seeded(_ identity: AgentProcessIdentity, file: URL? = nil) -> ClaudeLineage {
        let lineage = ClaudeLineage(file: file)
        if ClaudeProcessInspector.check(identity) == .same, let raw = identity.pid { lineage.seed(pid_t(raw)) }
        return lineage
    }

    /// 띄운 프로세스 자신 (거두기 전이라 그 pid는 다른 프로세스가 쓸 수 없다)
    func seed(_ pid: pid_t) {
        if let ids = ClaudeProcessInspector.uniqueIDs(pid: pid) { insert(ids.own) }
    }

    func contains(_ id: UInt64) -> Bool {
        state.withLock { $0.ids.contains(id) }
    }

    func insert(_ id: UInt64) {
        state.withLock { if $0.ids.insert(id).inserted { $0.dirty = true } }
    }

    /// 환경에 marker가 있나 (프로세스마다 한 번만 읽는다)
    func marked(_ member: ClaudeProcessInspector.Member, read: () -> Bool) -> Bool {
        let key = Key(pid: member.pid, start: member.start)
        if state.withLock({ $0.unmarked.contains(key) }) { return false }
        if read() { return true }
        state.withLock { _ = $0.unmarked.insert(key) }
        return false
    }

    var isStopped: Bool { state.withLock { $0.stopped } }

    /// 새로 본 id가 있으면 파일에 적는다 (원자적 쓰기, 0600). 첫 줄은 부팅 시각
    func save() {
        guard let file else { return }
        state.withLock { current in
            guard current.dirty, !current.stopped, let boot = ClaudeProcessInspector.bootTime() else { return }
            let lines = ["taskforce-lineage 1", Self.stamp(boot)] + current.ids.sorted().map { String($0) }
            let directory = file.deletingLastPathComponent()
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                current.dirty = false
            } catch {
                // 적지 못하면 다음 훑기에서 다시 적는다 (메모리의 혈통은 그대로 쓴다)
            }
        }
    }

    /// 끝을 증명한 뒤: 지켜보기를 멈추고 파일을 지운다 (그 뒤로는 적지 않는다)
    func forget() {
        state.withLock { current in
            current.stopped = true
            if let file { try? FileManager.default.removeItem(at: file) }
        }
    }

    static func stamp(_ boot: Date) -> String {
        "boot " + String(Int64((boot.timeIntervalSince1970 * 1_000_000).rounded()))
    }

    /// 형식이 맞고 이번 부팅에 적힌 파일만 (숫자 줄만 받는다)
    static func load(_ file: URL) -> Set<UInt64>? {
        guard let boot = ClaudeProcessInspector.bootTime(), let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard lines.count >= 2, lines[0] == "taskforce-lineage 1", lines[1] == stamp(boot) else { return nil }
        var ids = Set<UInt64>()
        for line in lines.dropFirst(2) {
            guard line.allSatisfy(\.isASCII), let id = UInt64(line), id > 1 else { return nil }
            ids.insert(id)
        }
        return ids
    }

    /// 감독하는 동안 지켜본다 (막히는 스레드 하나): 본 프로세스마다 `NOTE_FORK`를 걸어 새 자식이 생기면 바로 다시 훑는다. 아니면 0.1초마다. `forget()`까지
    func watch(_ identity: AgentProcessIdentity) {
        guard let raw = identity.pid, raw > 1, raw <= Int(Int32.max) else { return }
        let queue = kqueue()
        guard queue >= 0 else { return }
        let thread = Thread { [self] in
            var watched = Set<pid_t>()
            // `kevent`는 함수와 구조체가 같은 이름이다: 인자 형을 적어 함수로 풀리게 한다
            let fork = UInt32(NOTE_FORK)
            let exit = UInt32(NOTE_EXIT)
            let noEvents: UnsafeMutablePointer<Darwin.kevent>? = nil
            let noChanges: UnsafePointer<Darwin.kevent>? = nil
            let noWait: UnsafePointer<timespec>? = nil
            func follow(_ pid: pid_t) {
                guard !watched.contains(pid) else { return }
                var change = Darwin.kevent(ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_CLEAR), fflags: fork | exit, data: 0, udata: nil)
                let added: Int32 = kevent(queue, &change, 1, noEvents, 0, noWait)
                if added == 0 { watched.insert(pid) }
            }
            follow(pid_t(raw))
            var events = [Darwin.kevent](repeating: Darwin.kevent(), count: 32)
            while !isStopped {
                for member in ClaudeProcessInspector.descendants(identity, lineage: self) ?? [] { follow(member.pid) }
                var timeout = timespec(tv_sec: 0, tv_nsec: 100_000_000)
                let capacity: Int32 = 32
                let count: Int32 = kevent(queue, noChanges, 0, &events, capacity, &timeout)
                for event in events.prefix(max(0, Int(count))) where event.fflags & exit != 0 { watched.remove(pid_t(event.ident)) }
            }
            close(queue)
        }
        thread.qualityOfService = .userInitiated
        thread.start()
    }
}
#endif
