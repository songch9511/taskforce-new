#if os(macOS)
import Foundation

/// 단조 시간 (초): 간격 · 머무는 시간 · 캐시 나이를 잰다. 벽시계는 사용자가 바꾸거나 NTP가 고쳐서 뒤로도 갈 수 있다 — 그러면 벽시계로 잰 간격이 얼거나 줄어든다.
/// `ContinuousClock`이라 잠든 시간도 센다 (깨면 맞춰 볼 때가 된 것으로 본다)
public enum ClaudeAppMonotonic {
    private static let base = ContinuousClock.now

    public static func now() -> TimeInterval {
        let elapsed = ContinuousClock.now - base
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }
}

/// 데스크톱 세션 상태의 원천 맞춰 보기 (PR-D1 Kit, 계약 21.2 DR-S1a). 등록 파일(A)은 부르는 쪽이 1초마다 `poll()`로 읽고, 시작 때와 60초마다 `claude agents --json`(문서화된 원천)과 맞춰 본다.
/// 다르거나 키가 없으면 맞을 때까지 `claude agents --json`을 몇 초마다 부르는 B로 간다 (등록 파일은 문서에 없는 내부 형식이라 형식이 바뀌면 조용히 B로 간다). 시계 · 실행기는 주입한다 (시험은 가짜).
///
/// - **`poll()`은 agents 프로세스를 기다리지 않는다.** 맞춰 보기는 poller가 쥔 하위 작업이 돌고, 끝나면 결과를 이 actor에 저장한다. `poll()`은 그 사이에도 바로 지금의 등록 파일 값(또는 마지막 agents 답)으로 돌아온다.
///   부르는 쪽(D2)은 `poll()`을 **한 번에 하나씩, 차례로** 부른다 (이전 호출이 돌아온 뒤에 다음 호출)
/// - 간격 · 캐시 나이는 단조 시간이다 (`uptime`). 벽시계(`clock`)는 등록 파일 값이 믿을 범위인지 보는 데만 쓴다
/// - 줄(어느 세션이 레일에 오르나)은 늘 등록 파일 + 살아 있음 검사가 정한다. agents-json은 상태 값만 준다: 등록 파일에 없는 세션 · pid가 다른 항목은 줄이 되지도, 상태가 되지도 않는다.
///   반대로 agents가 **성공했는데 모르는** 세션(실행 전 · 후 두 번의 등록 읽기에 다 있었다)은 유령으로 보고 상태를 unknown으로 둔다
/// - 맞춰 볼 때는 실행 전 · 후 두 번 읽은 등록 값 중 하나와 같으면 같다고 본다 (실행하는 사이 바뀐 것은 어긋남이 아니다)
/// - B: 어긋남이 계속되면 간격이 3 · 3 · 6 · 12 · 15(상한)초로 벌어진다. 맞춰 볼 수 없는 결과(어긋난 것은 없다)가 나오면 A로 돌아간다. B의 상태는 `(간격 + 기한)`의 두 배보다 오래된 답이면 unknown이다.
///   B의 상태에는 등록 파일의 `statusUpdatedAt`을 붙이지 않는다 (그 시각은 agents 값의 것이 아니다)
/// - `claude`는 한 번에 하나만 돈다. 살아 있는 데스크톱 세션이 없으면 맞춰 볼 것이 없어 띄우지 않는다
/// - 폴 비용: 등록 폴더는 목록만 매번 보고, 크기 · 수정 시각이 같은 파일은 다시 열지 않는다 (지금 레일에 있는 데스크톱 세션의 파일만 늘 다시 읽는다)
/// - 로그는 `claude_app_status {source, mismatch}` 코드뿐이다: id · 폴더 · 이름 · 제목 없음
public actor ClaudeAppStatusPoller {
    public enum Source: String, Sendable {
        case registry
        case agents
    }

    public struct Poll: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        public var sessions: [ClaudeAppSession]
        /// 살아 있는 등록이 둘 이상인 id (믿지 않는다, `sessions`에 없다). **비어 있다고 다른 writer가 없다는 뜻은 아니다** (보내기 전 확인은 PR-D3가 따로 한다)
        public var doubled: Set<String>
        /// 지금 상태 값을 읽는 원천
        public var source: Source
        /// 마지막 맞춰 보기에서 등록 파일이 문서화된 원천과 달랐고 아직 같아지지 않았다 (`source == .agents`)
        public var mismatch: Bool
        /// 마지막 맞춰 보기에서 둘이 같았다 (맞춰 볼 수 없었으면 false)
        public var verified: Bool
        public var registryUnavailable: Bool

        public init(sessions: [ClaudeAppSession], doubled: Set<String>, source: Source, mismatch: Bool, verified: Bool, registryUnavailable: Bool) {
            self.sessions = sessions
            self.doubled = doubled
            self.source = source
            self.mismatch = mismatch
            self.verified = verified
            self.registryUnavailable = registryUnavailable
        }

        /// 개수와 원천만 말한다: 세션 id · pid · 폴더를 찍지 않는다
        public var description: String {
            "ClaudeAppStatusPoller.Poll(source: \(source.rawValue), sessions: \(sessions.count), doubled: \(doubled.count), mismatch: \(mismatch), verified: \(verified), registryUnavailable: \(registryUnavailable))"
        }

        public var debugDescription: String { description }
    }

    /// A에서 맞춰 보는 간격
    public static let reconcileInterval: TimeInterval = 60
    /// B에서 `claude agents --json`을 부르는 첫 간격
    public static let agentsPollInterval: TimeInterval = 3
    /// 어긋남이 계속될 때 B의 간격 상한
    public static let agentsMaxInterval: TimeInterval = 15

    enum Verdict: Equatable {
        case match
        case mismatch
        /// 맞춰 볼 수 있는 세션이 없다 (agents가 상태를 안 준 항목 · 같은 id가 둘 · pid가 다른 항목 · 유령뿐)
        case inconclusive
    }

    private let fileSystem: ExternalSessionFileSystem
    private let sessionsDirectory: String
    private let processFacts: ExternalSessionProcessFacts
    private let ownPIDs: @Sendable () -> Set<Int32>
    private let agents: @Sendable () async -> [ClaudeAgentsItem]?
    private let clock: @Sendable () -> Date
    private let uptime: @Sendable () -> TimeInterval
    private let agentsTimeout: TimeInterval
    private let log: any BridgeLogSink

    private var source: Source = .registry
    private var mismatch = false
    private var verified = false
    private var mismatchRuns = 0
    /// 마지막으로 agents 실행을 띄운 단조 시각
    private var lastRun: TimeInterval?
    private var cached: [ClaudeAgentsItem]?
    private var cachedAt: TimeInterval?
    /// agents가 성공했는데 모르는 세션들 (다음 맞춰 보기까지)
    private var ghosts: Set<String> = []
    private var run: Task<Void, Never>?
    private var reuse = ExternalSessionRegistry.Reuse()
    private var knownDesktopPIDs: Set<Int32> = []

    /// - sessionsDirectory: `~/.claude/sessions`
    /// - agents: `claude agents --json` 한 번 (실제 앱은 `ClaudeAgentsLister.live(…).list`). 못 읽으면 nil
    /// - clock: 벽시계 (등록 파일 값이 믿을 범위인지 보는 데만). uptime: 단조 시간 (간격 · 캐시 나이)
    public init(
        fileSystem: ExternalSessionFileSystem = .live, sessionsDirectory: String, processFacts: ExternalSessionProcessFacts = .live,
        ownPIDs: @escaping @Sendable () -> Set<Int32> = { [] }, agents: @escaping @Sendable () async -> [ClaudeAgentsItem]?, clock: @escaping @Sendable () -> Date = { Date() },
        uptime: @escaping @Sendable () -> TimeInterval = { ClaudeAppMonotonic.now() }, agentsTimeout: TimeInterval = ClaudeAgentsLister.defaultTimeout, log: any BridgeLogSink = NoBridgeLog()
    ) {
        self.fileSystem = fileSystem
        self.sessionsDirectory = sessionsDirectory
        self.processFacts = processFacts
        self.ownPIDs = ownPIDs
        self.agents = agents
        self.clock = clock
        self.uptime = uptime
        self.agentsTimeout = agentsTimeout
        self.log = log
    }

    /// 지금의 줄과 상태. 맞춰 볼 때가 됐으면 하위 작업을 띄우지만 **그 작업을 기다리지 않는다** (결과는 이후 폴에 반영된다)
    public func poll() async -> Poll {
        let live = readLive()
        startReconcileIfDue(live)
        return output(live)
    }

    /// 돌고 있는 맞춰 보기가 끝나기를 기다린다 (시험 · 종료 정리용: 앱의 폴 순서에는 쓰지 않는다)
    func settle() async {
        await run?.value
    }

    // MARK: 읽기 · 맞춰 보기

    private func readLive() -> ClaudeAppLiveSessions {
        let result = ClaudeAppLiveSessions.read(
            fileSystem: fileSystem, sessionsDirectory: sessionsDirectory, facts: processFacts, ownPIDs: ownPIDs(), now: clock(), reuse: &reuse, alwaysRead: knownDesktopPIDs
        )
        knownDesktopPIDs = Set(result.sessions.map(\.pid))
        return result
    }

    /// B의 간격: 3 · 3 · 6 · 12 · 15(상한)초. A는 60초
    private var currentInterval: TimeInterval {
        guard source == .agents else { return Self.reconcileInterval }
        let doublings = max(0, mismatchRuns - 2)
        return min(Self.agentsMaxInterval, Self.agentsPollInterval * pow(2, Double(min(doublings, 10))))
    }

    private func startReconcileIfDue(_ live: ClaudeAppLiveSessions) {
        guard run == nil, !live.sessions.isEmpty else { return }
        let now = uptime()
        if let lastRun, now - lastRun < currentInterval { return }
        lastRun = now
        let before = live.sessions
        let agents = agents
        run = Task { [weak self] in
            let items = await agents()
            await self?.finish(items: items, before: before)
        }
    }

    /// 하위 작업이 돌아왔다: 실행 뒤의 등록 읽기와 맞춰 보고 원천을 정한다
    private func finish(items: [ClaudeAgentsItem]?, before: [ClaudeAppSession]) {
        let after = readLive()
        cached = items
        cachedAt = items == nil ? nil : uptime()
        if let items {
            let result = Self.compare(before: before, after: after.sessions, agents: items)
            ghosts = result.ghosts
            switch result.verdict {
            case .mismatch:
                mismatchRuns += 1
                source = .agents
                mismatch = true
                verified = false
            case .match:
                mismatchRuns = 0
                source = .registry
                mismatch = false
                verified = true
            case .inconclusive:
                // 어긋난 것이 없는데 B에 머물 까닭이 없다
                if source == .agents {
                    source = .registry
                    mismatch = false
                    mismatchRuns = 0
                }
                verified = false
            }
        } else {
            verified = false
        }
        run = nil
        log.log("claude_app_status", ["source": .code(source.rawValue), "mismatch": .count(mismatch ? 1 : 0)])
    }

    private func output(_ live: ClaudeAppLiveSessions) -> Poll {
        let sessions: [ClaudeAppSession]
        switch source {
        case .registry:
            sessions = live.sessions.map { session in
                guard ghosts.contains(session.id) else { return session }
                var ghost = session
                ghost.state = .unknown
                return ghost
            }
        case .agents:
            // 너무 오래된 답(실행이 끝나지 않는다)은 쓰지 않는다
            let staleAfter = 2 * (currentInterval + agentsTimeout)
            let fresh = cachedAt.map { uptime() - $0 <= staleAfter } ?? false
            let items = fresh ? cached : nil
            sessions = live.sessions.map { session in
                var copy = session
                copy.state = ghosts.contains(session.id) ? .unknown : Self.state(of: session, in: items)
                copy.statusUpdatedAt = nil
                return copy
            }
        }
        return Poll(sessions: sessions, doubled: live.doubled, source: source, mismatch: mismatch, verified: verified, registryUnavailable: live.registryUnavailable)
    }

    // MARK: 순수한 부분

    /// B의 상태: agents 목록에서 **같은 id · 같은 pid인 항목이 정확히 하나**일 때만 그 값. 그 밖은 모른다
    static func state(of session: ClaudeAppSession, in items: [ClaudeAgentsItem]?) -> ClaudeAppSessionState {
        guard let items else { return .unknown }
        let named = items.filter { $0.sessionID == session.id }
        guard named.count == 1, let item = named.first, item.pid == session.pid else { return .unknown }
        return item.state
    }

    /// 등록 파일의 값(실행 전 · 후)과 agents의 값을 세션마다 맞춰 본다. 하나라도 어긋나면 어긋남, 맞춰 볼 수 있는 것이 하나도 없으면 판단 못 함.
    /// 유령 = agents가 성공했는데 그 id가 없고, 실행 전 · 후 두 번의 등록 읽기에 다 있던 세션
    static func compare(before: [ClaudeAppSession], after: [ClaudeAppSession], agents: [ClaudeAgentsItem]) -> (verdict: Verdict, ghosts: Set<String>) {
        let first = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { current, _ in current })
        let second = Dictionary(after.map { ($0.id, $0) }, uniquingKeysWith: { current, _ in current })
        var agreed = 0
        var differs = false
        var ghosts = Set<String>()
        for id in Set(first.keys).union(second.keys) {
            let named = agents.filter { $0.sessionID == id }
            if named.isEmpty {
                // 실행 중에 등록된 세션은 한쪽 읽기에만 있다: 유령이 아니다
                if first[id] != nil, second[id] != nil { ghosts.insert(id) }
                continue
            }
            let pids = [first[id]?.pid, second[id]?.pid].compactMap { $0 }
            // 같은 id가 둘이거나(어느 쪽이 거짓인지 모른다) 다른 pid의 항목이거나 상태가 없는 항목은 맞춰 볼 수 없다
            guard named.count == 1, let item = named.first, pids.contains(item.pid), item.state != .unknown else { continue }
            if [first[id]?.state, second[id]?.state].compactMap({ $0 }).contains(item.state) {
                agreed += 1
            } else {
                differs = true
            }
        }
        return (differs ? .mismatch : (agreed > 0 ? .match : .inconclusive), ghosts)
    }
}
#endif
