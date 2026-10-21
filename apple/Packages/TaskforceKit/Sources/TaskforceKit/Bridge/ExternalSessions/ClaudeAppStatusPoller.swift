#if os(macOS)
import Foundation

/// 데스크톱 세션 상태의 원천 맞춰 보기 (PR-D1 Kit, 계약 21.2 DR-S1a). 등록 파일(A)은 부르는 쪽이 1초마다 `poll()`로 읽고, 시작 때와 60초마다 `claude agents --json`(문서화된 원천)과 맞춰 본다.
/// 다르거나 키가 없으면 맞을 때까지 `claude agents --json`을 몇 초마다 부르는 B로 간다 (등록 파일은 문서에 없는 내부 형식이라 형식이 바뀌면 조용히 B로 간다). 시계 · 실행기는 주입한다 (시험은 가짜).
///
/// - 줄(어느 세션이 레일에 오르나)은 늘 등록 파일 + 살아 있음 검사가 정한다. agents-json은 상태 값만 준다: 등록 파일에 없는 세션 · pid가 다른 항목은 줄이 되지도, 상태가 되지도 않는다
/// - 맞춰 볼 때는 실행 전 · 후 두 번 읽은 등록 값 중 하나와 같으면 같다고 본다 (실행하는 사이 바뀐 것은 어긋남이 아니다)
/// - `claude`는 한 번에 하나만 돈다. 살아 있는 데스크톱 세션이 없으면 맞춰 볼 것이 없어 띄우지 않는다
/// - 로그는 `claude_app_status {source, mismatch}` 코드뿐이다: id · 폴더 · 이름 · 제목 없음
public actor ClaudeAppStatusPoller {
    public enum Source: String, Sendable {
        case registry
        case agents
    }

    public struct Poll: Equatable, Sendable {
        public var sessions: [ClaudeAppSession]
        /// 살아 있는 등록이 둘 이상인 id (믿지 않는다, `sessions`에 없다)
        public var doubled: Set<String>
        /// 지금 상태 값을 읽는 원천
        public var source: Source
        /// 마지막 맞춰 보기에서 등록 파일이 문서화된 원천과 달랐고 아직 같아지지 않았다 (`source == .agents`)
        public var mismatch: Bool
        /// 마지막 맞춰 보기에서 둘이 같았다 (맞춰 볼 수 없었으면 false)
        public var verified: Bool
        public var registryUnavailable: Bool
    }

    /// A에서 맞춰 보는 간격
    public static let reconcileInterval: TimeInterval = 60
    /// B에서 `claude agents --json`을 부르는 간격
    public static let agentsPollInterval: TimeInterval = 3

    enum Verdict: Equatable {
        case match
        case mismatch
        /// 맞춰 볼 수 있는 세션이 없다 (agents가 모르는 세션 · 상태 없는 항목 · 같은 id가 둘)
        case inconclusive
    }

    private let fileSystem: ExternalSessionFileSystem
    private let sessionsDirectory: String
    private let processFacts: ExternalSessionProcessFacts
    private let ownPIDs: @Sendable () -> Set<Int32>
    private let agents: @Sendable () async -> [ClaudeAgentsItem]?
    private let clock: @Sendable () -> Date
    private let log: any BridgeLogSink

    private var source: Source = .registry
    private var mismatch = false
    private var verified = false
    private var lastRun: Date?
    private var cached: [ClaudeAgentsItem]?
    private var running = false

    /// - sessionsDirectory: `~/.claude/sessions`
    /// - agents: `claude agents --json` 한 번 (실제 앱은 `ClaudeAgentsLister.list`). 못 읽으면 nil
    public init(
        fileSystem: ExternalSessionFileSystem = .live, sessionsDirectory: String, processFacts: ExternalSessionProcessFacts = .live,
        ownPIDs: @escaping @Sendable () -> Set<Int32> = { [] }, agents: @escaping @Sendable () async -> [ClaudeAgentsItem]?, clock: @escaping @Sendable () -> Date = { Date() },
        log: any BridgeLogSink = NoBridgeLog()
    ) {
        self.fileSystem = fileSystem
        self.sessionsDirectory = sessionsDirectory
        self.processFacts = processFacts
        self.ownPIDs = ownPIDs
        self.agents = agents
        self.clock = clock
        self.log = log
    }

    public func poll() async -> Poll {
        let now = clock()
        var live = readLive(at: now)
        let interval = source == .registry ? Self.reconcileInterval : Self.agentsPollInterval
        let due = lastRun.map { now.timeIntervalSince($0) >= interval } ?? true
        if due, !running, !live.sessions.isEmpty {
            running = true
            let items = await agents()
            running = false
            let after = readLive(at: clock())
            lastRun = now
            cached = items
            if let items {
                switch Self.compare(before: live.sessions, after: after.sessions, agents: items) {
                case .mismatch:
                    source = .agents
                    mismatch = true
                    verified = false
                case .match:
                    source = .registry
                    mismatch = false
                    verified = true
                case .inconclusive:
                    verified = false
                }
            } else {
                verified = false
            }
            live = after
            log.log("claude_app_status", ["source": .code(source.rawValue), "mismatch": .count(mismatch ? 1 : 0)])
        }
        let sessions: [ClaudeAppSession]
        switch source {
        case .registry:
            sessions = live.sessions
        case .agents:
            let known = cached
            sessions = live.sessions.map { session in
                var copy = session
                copy.state = Self.state(of: session, in: known)
                return copy
            }
        }
        return Poll(sessions: sessions, doubled: live.doubled, source: source, mismatch: mismatch, verified: verified, registryUnavailable: live.registryUnavailable)
    }

    private func readLive(at now: Date) -> ClaudeAppLiveSessions {
        ClaudeAppLiveSessions.read(fileSystem: fileSystem, sessionsDirectory: sessionsDirectory, facts: processFacts, ownPIDs: ownPIDs(), now: now)
    }

    /// B의 상태: agents 목록에서 **같은 id · 같은 pid인 항목이 정확히 하나**일 때만 그 값. 그 밖은 모른다
    static func state(of session: ClaudeAppSession, in items: [ClaudeAgentsItem]?) -> ClaudeAppSessionState {
        guard let items else { return .unknown }
        let named = items.filter { $0.sessionID == session.id }
        guard named.count == 1, let item = named.first, item.pid == session.pid else { return .unknown }
        return item.state
    }

    /// 등록 파일의 값(실행 전 · 후)과 agents의 값을 세션마다 맞춰 본다. 하나라도 어긋나면 어긋남, 맞춰 볼 수 있는 것이 하나도 없으면 판단 못 함
    static func compare(before: [ClaudeAppSession], after: [ClaudeAppSession], agents: [ClaudeAgentsItem]) -> Verdict {
        let first = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { current, _ in current })
        let second = Dictionary(after.map { ($0.id, $0) }, uniquingKeysWith: { current, _ in current })
        var agreed = 0
        for id in Set(first.keys).union(second.keys) {
            let named = agents.filter { $0.sessionID == id }
            let pids = [first[id]?.pid, second[id]?.pid].compactMap { $0 }
            // 같은 id가 둘이거나(어느 쪽이 거짓인지 모른다) 다른 pid의 항목이거나 상태가 없는 항목은 맞춰 볼 수 없다
            guard named.count == 1, let item = named.first, pids.contains(item.pid), item.state != .unknown else { continue }
            if [first[id]?.state, second[id]?.state].compactMap({ $0 }).contains(item.state) {
                agreed += 1
            } else {
                return .mismatch
            }
        }
        return agreed > 0 ? .match : .inconclusive
    }
}
#endif
