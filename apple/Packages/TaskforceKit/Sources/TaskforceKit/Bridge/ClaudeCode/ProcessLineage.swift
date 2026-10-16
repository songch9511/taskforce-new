#if os(macOS)
import Darwin
import Foundation
import Synchronization
import TaskforceAgentWire

/// 한 spawn의 기록 (OA D3a 13장 · 12장 5–8): 그 spawn의 지킴이(pid · unique id)와 `claude`(뿌리) id, 지킴이가 책임 프로세스로 가를 수 있나.
///
/// 구성원과 끝은 지킴이가 본다 (13장 2–3): 지킴이는 구성원이 0이 될 때까지 살고, 0을 증명한 뒤 끝 기록 `<spawn id>.keeper`를 쓰고 정상 종료한다.
/// 앱의 끝 = (지킴이가 사라짐 ∧ 그 지킴이의 끝 기록) 또는 (앱이 부모로서 받은 지킴이 정상 종료). 그 밖은 unknown(잠금).
/// 파일 `<sessionsRoot>/lineage/<spawn id>.lineage`(0600, 형식 4): 형식 · 부팅 id(`kern.bootsessionuuid`) · `keeper <id> <pid>` · `root <id> <pid>` ·
/// `responsible yes|no`. 지킴이를 띄우기 전에 정체 자리 `pending`(형식 · 부팅 id · `pending`)을 먼저 쓰고(14장 1: 세션 잠금이 가리키는 기록), 띄운 직후 한 번 원자적으로
/// 정체로 바꾼다 (못 쓰거나 지킴이 · 뿌리 id를 모르면 띄우지 않은 것으로 하고 끝을 증명할 때까지 잠금을 남긴다, 12장 6). 잘린 줄이 있으면 읽지 못함(12장 5).
/// 앱이 끝을 확정하면 `<spawn id>.ended`를 쓰고 혈통 파일 · 지킴이 기록을 지운다 (12장 8: `load`가 끝 기록을 먼저 본다). 다른 부팅의 파일이면 그 spawn은
/// 이미 끝났다. 파일이 있어야 할 spawn인데 없거나 읽지 못하면 증거가 없다 → unknown. 글 · 경로 · 명령은 적지 않는다: 숫자뿐이다
public final class ClaudeLineage: Sendable {
    /// 파일에서 읽은 것
    enum Evidence: Equatable {
        /// 이제 띄우는 spawn (파일은 곧 쓴다)
        case memory
        /// 이번 부팅의 파일
        case thisBoot
        /// 다른 부팅의 파일: 그 spawn은 끝났다
        case otherBoot
        /// 끝을 확정해 둔 기록
        case ended
        /// 있어야 할 파일이 없거나 읽지 못했다: 끝을 증명할 수 없다
        case missing
    }

    /// 지킴이 하나 (13장 1)
    struct Keeper: Equatable, Sendable {
        let pid: pid_t
        let uniqueID: UInt64
    }

    struct Record: Equatable, Sendable {
        var keeper: Keeper
        /// `claude`의 unique id · pid
        var root: UInt64
        var rootPID: pid_t
        /// 지킴이가 자기 책임 프로세스다 (13장 5)
        var attributable: Bool
    }

    struct State {
        var record: Record?
        /// 끝을 확정했다 (지킴이 정상 종료 · 끝 기록 · `forget`)
        var ended = false
        /// 앱이 부모로서 지킴이의 비정상 종료를 받았다 (13장 3: unknown)
        var keeperFailed = false
    }

    private let state = Mutex(State())
    let file: URL?
    let evidence: Evidence

    var fromOtherBoot: Bool { evidence == .otherBoot }
    /// 끝이라는 증거가 이미 있다 (다른 부팅 · 끝 기록 · 이 객체가 끝을 확정함)
    var provenEnded: Bool { evidence == .otherBoot || evidence == .ended || state.withLock { $0.ended } }
    /// 증거가 있어야 할 혈통인가 (있어야 할 파일이 없으면 아니다)
    var hasEvidence: Bool { evidence != .missing }
    var keeper: Keeper? { state.withLock { $0.record?.keeper } }
    var rootID: UInt64? { state.withLock { $0.record?.root } }
    var attributable: Bool { state.withLock { $0.record?.attributable ?? false } }
    /// 지킴이로 구성원을 가를 수 있다: 지킴이를 알고, 자기 책임 프로세스이고, 비정상 종료를 받지 않았다. 아니면 끝을 증명하지 않고 구성원에 신호도 보내지 않는다
    var provable: Bool { state.withLock { $0.record.map { $0.attributable } == true && !$0.keeperFailed } }

    /// - `fresh`: 이제 띄우는 spawn (파일은 곧 쓴다). 아니면 `file`을 읽는다 (다시 뜬 앱의 확인 · 끝내기)
    /// - `boot`: 이번 부팅 id (못 읽으면 nil: 파일을 대조할 수 없어 증거 없음)
    init(file: URL? = nil, fresh: Bool = false, boot: () -> String? = { AgentProcesses.bootSessionID() }) {
        self.file = file
        guard let file, !fresh else {
            evidence = .memory
            return
        }
        switch Self.load(file, boot: boot()) {
        case .thisBoot(let record):
            evidence = .thisBoot
            state.withLock { $0.record = record }
        case .pending:
            // 이번 부팅에 띄우려던 spawn인데 정체를 적지 못했다: 지킴이를 모르니 끝을 증명할 수 없다 (unknown, 14장 1)
            evidence = .thisBoot
        case .ended: evidence = .ended
        case .otherBoot: evidence = .otherBoot
        case .unreadable: evidence = .missing
        }
    }

    /// 띄운 지킴이 · `claude`를 적는다 (그다음 `save`)
    func adopt(_ record: Record) {
        state.withLock { $0.record = record }
    }

    /// 지킴이를 띄우기 전의 정체 자리 (14장 1): 형식 · 부팅 id · `pending`. 이제 띄우는 spawn에만, 부팅 id를 못 읽으면 쓰지 않는다
    func savePending() -> Bool {
        guard let file, evidence == .memory, let boot = AgentProcesses.bootSessionID() else { return false }
        return Self.write([Self.header, "boot " + boot, "pending"], to: file) && Self.load(file, boot: boot) == .pending
    }

    /// 원자적 쓰기 (0600). 지킴이 · 뿌리를 모르거나 부팅 id를 못 읽으면 쓰지 않는다
    @discardableResult
    func save() -> Bool {
        guard let file, evidence == .memory || evidence == .thisBoot, let record = state.withLock({ $0.record }), let boot = AgentProcesses.bootSessionID() else { return false }
        return Self.write([
            Self.header, "boot " + boot, "keeper \(record.keeper.uniqueID) \(record.keeper.pid)", "root \(record.root) \(record.rootPID)",
            "responsible " + (record.attributable ? "yes" : "no"),
        ], to: file)
    }

    /// 파일이 이번 부팅의 이 지킴이 · 뿌리로 읽히나 (띄운 직후 확인, 11장 2 · 12장 6)
    var isRecorded: Bool {
        guard let file, let record = state.withLock({ $0.record }) else { return false }
        if case .thisBoot(let read) = Self.load(file), read == record { return true }
        return false
    }

    /// 앱이 부모로서 지킴이를 거뒀다 (13장 3): 0으로 끝났으면(구성원 0 증명 · 끝 기록) 끝, 아니면 unknown
    func keeperExited(_ status: ClaudeExitStatus) {
        state.withLock {
            if status.code == KeeperMain.Exit.ended.rawValue, status.signal == nil {
                $0.ended = true
            } else {
                $0.keeperFailed = true
            }
        }
    }

    /// 그 지킴이가 이번 부팅에 쓴 끝 기록이 있다 (또는 그 뒤 앱이 이미 확정해 지킴이 기록을 끝 기록으로 바꿔 두었다)
    func keeperRecorded() -> Bool {
        guard let file, let keeper else { return false }
        if Self.load(file) == .ended { return true }
        guard let record = KeeperRecord.read(Self.keeperFile(file)), let boot = AgentProcesses.bootSessionID() else { return false }
        return record.keeperID == keeper.uniqueID && record.boot == boot
    }

    /// 끝을 확정한 뒤: 끝 기록(`<id>.ended`)을 쓰고 혈통 파일 · 지킴이 기록을 지운다 (그 뒤의 확인도 끝이다, 11장 1 · 12장 8)
    func forget() {
        state.withLock { current in
            current.ended = true
            guard let file, evidence != .otherBoot, evidence != .ended else { return }
            if let boot = AgentProcesses.bootSessionID() { _ = Self.write([Self.header, "boot " + boot, "ended"], to: Self.endedFile(file)) }
            // 끝 기록을 쓰지 못했으면 혈통 파일만 지운다: 그 뒤의 확인은 증거가 없어 unknown이다 (끝이라고 하지 않는다)
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: Self.keeperFile(file))
        }
    }

    static func write(_ lines: [String], to file: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return true
        } catch {
            return false
        }
    }

    static let header = "taskforce-lineage 4"

    /// 앱의 끝 기록 (`<spawn id>.ended`, 12장 8)
    static func endedFile(_ file: URL) -> URL {
        file.deletingPathExtension().appendingPathExtension("ended")
    }

    /// 지킴이의 끝 기록 (`<spawn id>.keeper`, 13장 3)
    static func keeperFile(_ file: URL) -> URL {
        file.deletingPathExtension().appendingPathExtension("keeper")
    }

    enum Loaded: Equatable {
        case thisBoot(Record)
        /// 이번 부팅의 정체 자리 (지킴이를 띄우기 전, 14장 1)
        case pending
        case ended
        case otherBoot
        case unreadable
    }

    /// 끝 기록(`<id>.ended`)을 먼저 보고, 없으면 혈통 파일. 형식이 맞는 것만: 모든 줄이 줄바꿈으로 끝나고(잘린 줄이 있으면 읽지 못함, 12장 5) 지킴이 · 뿌리 id가 있어야 한다.
    /// 부팅 id가 `boot`와 다르면 `otherBoot`(정체 자리여도: 그 부팅의 프로세스는 모두 끝났다), 부팅 id를 못 읽으면 `unreadable`
    static func load(_ file: URL, boot: String? = AgentProcesses.bootSessionID()) -> Loaded {
        let ended = endedFile(file)
        if FileManager.default.fileExists(atPath: ended.path) {
            guard let lines = lines(ended), lines.count == 3, lines[2] == "ended" else { return .unreadable }
            return bootOf(lines, boot) ?? .ended
        }
        guard let lines = lines(file) else { return .unreadable }
        if let other = bootOf(lines, boot) { return other }
        if lines.count == 3, lines[2] == "pending" { return .pending }
        guard lines.count == 5 else { return .unreadable }
        func number(_ text: Substring) -> UInt64? {
            guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }), let value = UInt64(text) else { return nil }
            return value
        }
        /// `<id> <pid>`: id > 1, pid > 1
        func entry(_ line: String, _ prefix: String) -> (id: UInt64, pid: pid_t)? {
            guard line.hasPrefix(prefix) else { return nil }
            let parts = line.dropFirst(prefix.count).split(separator: " ", omittingEmptySubsequences: false)
            guard parts.count == 2, let id = number(parts[0]), id > 1, let pid = number(parts[1]), pid > 1, pid <= UInt64(Int32.max) else { return nil }
            return (id, pid_t(pid))
        }
        guard let keeper = entry(lines[2], "keeper "), let root = entry(lines[3], "root "), root.id > keeper.id else { return .unreadable }
        let attributable: Bool
        switch lines[4] {
        case "responsible yes": attributable = true
        case "responsible no": attributable = false
        default: return .unreadable
        }
        return .thisBoot(Record(keeper: Keeper(pid: keeper.pid, uniqueID: keeper.id), root: root.id, rootPID: root.pid, attributable: attributable))
    }

    /// 줄 목록 (머리 확인). 마지막 줄바꿈 뒤에 글이 있으면(잘린 줄) nil
    private static func lines(_ file: URL) -> [String]? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.removeLast().isEmpty, lines.count >= 2, lines[0] == header, lines[1].hasPrefix("boot ") else { return nil }
        return lines
    }

    /// 머리의 부팅 id가 이번 부팅이면 nil, 다르면 `otherBoot`, 읽지 못하면 `unreadable`
    private static func bootOf(_ lines: [String], _ boot: String?) -> Loaded? {
        let written = String(lines[1].dropFirst(5))
        guard UUID(uuidString: written) != nil, let boot else { return .unreadable }
        return written == boot ? nil : .otherBoot
    }

    /// 앱이 뜰 때 (11장 1, 결정 11-1): 다시 부팅했다는 것은 그 부팅의 프로세스가 모두 끝났다는 증명이다. 확인된 다른 부팅의 혈통 파일은 이번 부팅의
    /// 끝 기록(`<id>.ended`)으로 바꾸고 혈통 파일 · 지킴이 기록을 지운다. 부팅 id를 못 읽으면 아무것도 바꾸지 않는다.
    /// 끝 기록은 task 정리를 adapter가 알 길이 없어 지우지 않는다 (숫자 · 부팅 id뿐, 계정 삭제가 파티션째 지운다)
    static func purge(directory: URL, boot: String? = AgentProcesses.bootSessionID()) {
        guard let boot, let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasSuffix(".lineage") {
            let file = directory.appending(path: name)
            if load(file, boot: boot) == .otherBoot, write([header, "boot " + boot, "ended"], to: endedFile(file)) {
                try? FileManager.default.removeItem(at: file)
                try? FileManager.default.removeItem(at: keeperFile(file))
            }
        }
        // 다른 부팅의 세션 잠금도 그 부팅의 프로세스가 모두 끝났다는 뜻이다 (14장 1)
        for name in names where name.hasSuffix(".lock") {
            let file = directory.appending(path: name)
            if ClaudeSessionLock.read(file, boot: boot) == .otherBoot { try? FileManager.default.removeItem(at: file) }
        }
    }
}

/// 세션 잠금 (OA D3a 14장 1–2, 원칙: 띄우기 전에 디스크 잠금, 끝을 증명할 때만 해제). 모든 spawn(턴 · 답 · 닫기)은 지킴이를 띄우기 전에
/// `<sessionsRoot>/lineage/<세션 id>.lock`(원자적 · 0600)에 형식 · 부팅 id · 이번 spawn id를 적는다. 그 spawn의 지킴이 · `claude` 정체 자리는 같은 폴더의 혈통 파일이다.
/// 같은 세션의 다음 writer는 앱이 다시 떠도 원장 `alive`가 아니라 이 잠금과 그 혈통으로 앞 spawn의 끝을 본다. 다른 부팅의 잠금은 지워도 된다. 숫자 · id뿐
enum ClaudeSessionLock {
    static let header = "taskforce-session-lock 1"

    enum Read: Equatable {
        case none
        case otherBoot
        case spawn(String)
        /// 있는데 읽지 못했다: 끝을 증명할 수 없다 (unknown)
        case unreadable
    }

    static func file(sessionsRoot: URL, session: String) -> URL? {
        guard UUID(uuidString: session) != nil else { return nil }
        return sessionsRoot.appending(path: "lineage", directoryHint: .isDirectory).appending(path: "\(session.lowercased()).lock")
    }

    static func write(_ file: URL, spawnID: String) -> Bool {
        guard let boot = AgentProcesses.bootSessionID() else { return false }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            return false
        }
        return AgentFile.writeAtomically([header, "boot " + boot, "spawn " + spawnID].joined(separator: "\n") + "\n", to: file) && read(file, boot: boot) == .spawn(spawnID)
    }

    static func read(_ file: URL, boot: String? = AgentProcesses.bootSessionID()) -> Read {
        var info = stat()
        guard lstat(file.path, &info) == 0 else { return errno == ENOENT ? .none : .unreadable }
        guard (info.st_mode & S_IFMT) == S_IFREG, let text = try? String(contentsOf: file, encoding: .utf8) else { return .unreadable }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.removeLast().isEmpty, lines.count == 3, lines[0] == header, lines[1].hasPrefix("boot "), lines[2].hasPrefix("spawn ") else { return .unreadable }
        let written = String(lines[1].dropFirst(5))
        let spawnID = String(lines[2].dropFirst(6))
        guard UUID(uuidString: written) != nil, UUID(uuidString: spawnID) != nil, let boot else { return .unreadable }
        return written == boot ? .spawn(spawnID) : .otherBoot
    }

    /// 그 spawn의 잠금일 때만 지운다 (그 뒤에 쓴 다른 spawn의 잠금은 그대로)
    static func release(_ file: URL, spawnID: String) {
        if read(file) == .spawn(spawnID) { try? FileManager.default.removeItem(at: file) }
    }
}
#endif
