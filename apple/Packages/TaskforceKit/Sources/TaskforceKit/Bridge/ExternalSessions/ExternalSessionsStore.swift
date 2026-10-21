#if os(macOS)
import Foundation
import Observation

/// 레일 점의 기준 시각 "목록을 마지막으로 연 때" (앱 안에만 기억한다: 서버 · 지표에 가지 않는다)
public protocol ExternalSessionSeenStore: Sendable {
    var lastOpened: Date? { get }
    func setLastOpened(_ date: Date)
}

/// `UserDefaults`가 하는 일의 좁은 면 (시험은 실제 설정 도메인을 만들지 않으려고 사전으로 바꾼다)
public protocol ExternalSessionDefaults: AnyObject, Sendable {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: ExternalSessionDefaults {}

public final class UserDefaultsExternalSessionSeenStore: ExternalSessionSeenStore, @unchecked Sendable {
    public static let key = "taskforce.externalSessions.lastOpened"
    private let defaults: any ExternalSessionDefaults

    public init(defaults: any ExternalSessionDefaults = UserDefaults.standard) { self.defaults = defaults }

    public var lastOpened: Date? { (defaults.object(forKey: Self.key) as? Double).map { Date(timeIntervalSince1970: $0) } }
    public func setLastOpened(_ date: Date) { defaults.set(date.timeIntervalSince1970, forKey: Self.key) }
}

public final class InMemoryExternalSessionSeenStore: ExternalSessionSeenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date?

    public init(_ value: Date? = nil) { self.value = value }

    public var lastOpened: Date? { lock.withLock { value } }
    public func setLastOpened(_ date: Date) { lock.withLock { value = date } }
}

/// 레일 "On this Mac" 항목 · 패널의 상태 (OA 외부 세션 PR1, 계약 8 · 17장). 화면이 읽는 값과 언제 훑을지만 정한다. 판정 · 읽기는 `ExternalSessionScanner`가 한다.
///
/// - 언제 훑나: 레일이 펼쳐질 때 한 번(점을 위해) · 패널이 열릴 때 한 번 + 열려 있는 동안 10초마다 (ES-06). 겹친 훑기는 하나로 합친다
/// - 처음 읽는 동안만 `checking`이다. 그다음 열 때는 마지막 목록을 바로 보이고 뒤에서 고친다
/// - 점(`hasNew`): 마지막으로 목록을 연 뒤 새로 생긴 세션이 있다. 목록을 열면 지운다. 앱이 처음 훑을 때 있던 세션은 새것이 아니다
/// - 서버에는 훑을 때마다 읽은 결과(없음 포함, 읽지 못한 때는 빼고)를 알린다. 속도 조절 · 물러남은 `ExternalSessionReporter`가 하고, 목록 자체는 서버에 기대지 않는다 (서버가 꺼 둔 길이어도 목록은 그대로 보인다).
///   보고는 훑을 때 잡은 계정 · bridge(`ExternalSessionScan.origin`)와 함께 나간다
/// - "보임" 지표는 패널이 행 1개 이상으로 열린 날, **UTC 날짜마다 한 번** 서버에 닿았을 때만 그날을 적는다. 실패는 `shownRetryInterval` 뒤 다음 훑기에서 다시 (서버도 하루 한 번으로 거른다)
/// - 계정이 떠나면 비우고, 그 사이 시작한 훑기의 늦은 답은 쓰지 않는다
/// - 실패한 상태에서 "Try again"(`retry()`)은 곧바로 Checking…으로 바꾸고 다시 훑는다. `~/.claude`가 없는데 설치 여부를 모르면 "설치 안 됨"이라고 하지 않는다 (probe가 없다고 했을 때만)
@MainActor
@Observable
public final class ExternalSessionsStore {
    public enum Phase: Equatable, Sendable {
        case idle
        /// 처음 읽는 중 ("Checking…")
        case checking
        case ready
        /// 최근 세션이 없다 ("No recent Claude Code sessions")
        case empty
        /// 이 Mac에 Claude Code가 없다 ("Claude Code isn't installed")
        case notInstalled
        /// 읽지 못했다 ("Couldn't check sessions")
        case failed
    }

    public private(set) var phase: Phase = .idle
    public private(set) var rows: [ExternalSessionRow] = []
    /// 마지막으로 목록을 연 뒤 새 세션이 생겼다 (레일 입구의 흰 점)
    public private(set) var hasNew = false
    public private(set) var isOpen = false
    /// 훑는 중이다 (시험이 끝나기를 기다린다)
    var isScanning: Bool { inFlight != nil }

    @ObservationIgnored private let scope: AccountScope
    @ObservationIgnored private let scan: @Sendable () async -> ExternalSessionScan
    @ObservationIgnored private let isInstalled: @Sendable () async -> Bool?
    @ObservationIgnored private let report: @Sendable (_ rows: [ExternalSessionRow], _ origin: ExternalSessionOrigin?) async -> Void
    /// 서버에 닿았으면 true (같은 날 두 번째라 서버가 조용히 넘긴 것도 닿은 것)
    @ObservationIgnored private let shown: @Sendable (_ rowsBucket: String, _ heldBucket: String) async -> Bool
    @ObservationIgnored private let recheckHold: @Sendable (String) async -> ExternalSessionStatus?
    @ObservationIgnored private let log: any BridgeLogSink
    @ObservationIgnored private let seen: any ExternalSessionSeenStore
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let pollInterval: TimeInterval
    @ObservationIgnored private var inFlight: Task<Void, Never>?
    @ObservationIgnored private var polling: Task<Void, Never>?
    /// 보임 지표가 서버에 닿은 마지막 UTC 날 (1970-01-01부터 센 일 수). UTC 날짜마다 한 번 보낸다 (서버도 하루 한 번으로 거른다)
    @ObservationIgnored private var lastShownDay: Int?
    @ObservationIgnored private var shownInFlight = false
    @ObservationIgnored private var lastShownAttempt: Date?
    /// 마지막으로 훑기를 마친 시각 (레일이 펼쳐질 때의 훑기를 아끼는 데 쓴다)
    @ObservationIgnored private var lastScanEnded: Date?
    /// 레일이 펼쳐질 때의 훑기 간격: 호버를 거듭해도 이 안에서는 다시 훑지 않는다
    public static let railScanInterval: TimeInterval = 5
    /// 보임 지표가 서버에 닿지 못했을 때 다시 보내기까지의 간격
    public static let shownRetryInterval: TimeInterval = 60

    public init(
        scope: AccountScope, scan: @escaping @Sendable () async -> ExternalSessionScan, isInstalled: @escaping @Sendable () async -> Bool? = { nil },
        report: @escaping @Sendable ([ExternalSessionRow], ExternalSessionOrigin?) async -> Void = { _, _ in }, shown: @escaping @Sendable (String, String) async -> Bool = { _, _ in true },
        recheck: @escaping @Sendable (String) async -> ExternalSessionStatus? = { _ in nil },
        seen: any ExternalSessionSeenStore, now: @escaping @Sendable () -> Date = { Date() }, pollInterval: TimeInterval = 10, log: any BridgeLogSink = NoBridgeLog()
    ) {
        self.scope = scope
        self.scan = scan
        self.isInstalled = isInstalled
        self.report = report
        self.shown = shown
        self.recheckHold = recheck
        self.seen = seen
        self.now = now
        self.pollInterval = pollInterval
        self.log = log
        scope.onLeft { [weak self] in self?.reset() }
    }

    public func reset() {
        inFlight?.cancel()
        inFlight = nil
        polling?.cancel()
        polling = nil
        phase = .idle
        rows = []
        hasNew = false
        isOpen = false
        lastShownDay = nil
        shownInFlight = false
        lastShownAttempt = nil
        lastScanEnded = nil
    }

    /// 레일이 펼쳐졌다: 점을 위해 한 번 훑는다 (패널이 열려 있으면 이미 훑고 있다)
    public func railExpanded() {
        guard !isOpen else { return }
        if let lastScanEnded, now().timeIntervalSince(lastScanEnded) < Self.railScanInterval { return }
        Task { await refresh() }
    }

    /// 패널을 열었다: 점을 지우고, 한 번 훑고, 열려 있는 동안 10초마다 다시 본다
    public func panelOpened() {
        isOpen = true
        hasNew = false
        seen.setLastOpened(now())
        if phase == .idle { phase = .checking }
        Task { await refresh() }
        polling?.cancel()
        let interval = pollInterval
        polling = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }

    public func panelClosed() {
        isOpen = false
        polling?.cancel()
        polling = nil
        // 열려 있는 동안 본 세션은 새것이 아니다
        seen.setLastOpened(now())
        hasNew = false
    }

    /// "Try again": 실패한 상태면 곧바로 Checking…으로 바꾸고 다시 훑는다 (목록이 있으면 그대로 두고 뒤에서 고친다)
    public func retry() {
        if phase == .failed { phase = .checking }
        Task { await refresh() }
    }

    /// 열기 직전(F4): 훑은 뒤 누가 그 세션을 쥐었는지 그 세션 하나만 다시 본다. 확인할 길이 없거나 모르면 nil — 부른 쪽이 막는다 (fail-closed)
    public func recheck(_ id: String) async -> ExternalSessionStatus? {
        await recheckHold(id)
    }

    /// 클릭 뒤(F4 · 보안 검토 P2-1): **호출 뒤에 시작하는** 훑기가 끝나기를 기다린다. `refresh()`는 이미 훑는 중이면 그 훑기를 그대로 쓰는데, 그 훑기는 클릭 전에 시작해서
    /// 클릭 뒤의 일(터미널이 쥠 · 데스크톱이 쥠)을 못 볼 수 있다. 도는 훑기가 있으면 그것이 끝나기를 기다린 뒤 새로 시작한다
    public func refreshFresh() async {
        if let stale = inFlight {
            await stale.value
            // 끝난 훑기가 아직 치워지지 않았을 수 있다 (`refresh()`가 마저 정리하기 전): 그대로 두면 `refresh()`가 끝난 훑기를 다시 쓴다
            if inFlight == stale { inFlight = nil }
        }
        await refresh()
    }

    /// 한 번 훑는다. 이미 훑는 중이면 그것이 끝나기를 기다린다
    public func refresh() async {
        if let inFlight {
            await inFlight.value
            return
        }
        let token = scope.token
        let task = Task { [weak self] in
            await self?.run(token: token)
            return ()
        }
        inFlight = task
        await task.value
        if inFlight == task { inFlight = nil }
    }

    private func run(token: AccountScope.Token?) async {
        if phase == .idle { phase = .checking }
        let installed = await isInstalled()
        if installed == false {
            guard isCurrent(token) else { return }
            rows = []
            phase = .notInstalled
            hasNew = false
            return
        }
        let result = await scan()
        guard isCurrent(token), !Task.isCancelled else { return }
        lastScanEnded = now()
        apply(result, installed: installed)
        // 읽은 결과(없음 포함)만 올린다: ~/.claude가 없으면 빈 목록이라 서버에 남은 옛 행도 지워진다. 읽지 못한 때는 올리지 않는다 (잠깐의 실패가 서버 목록을 비우지 않게)
        if result.failure != .unreadable {
            let current = rows
            let send = report
            let origin = result.origin
            Task { await send(current, origin) }
        }
    }

    private func isCurrent(_ token: AccountScope.Token?) -> Bool {
        guard let token else { return scope.token == nil }
        return scope.isCurrent(token)
    }

    private func apply(_ result: ExternalSessionScan, installed: Bool?) {
        switch result.failure {
        case .unreadable?:
            rows = []
            phase = .failed
            hasNew = false
            log.log("external_sessions_scan_failed", ["cause": .code("unreadable")])
            return
        case .notFound?:
            // ~/.claude가 없다. 설치 여부는 probe가 따로 말한다(없다고 했으면 훑지도 않았다): 모르면 "설치 안 됨"이라고 하지 않는다
            rows = []
            phase = .empty
            hasNew = false
            return
        case nil:
            break
        }
        rows = result.rows
        phase = rows.isEmpty ? .empty : .ready
        let current = now()
        // 앱이 처음 훑을 때 있던 세션은 새것이 아니다: 기준을 지금으로 둔다
        let baseline = seen.lastOpened ?? current
        if seen.lastOpened == nil { seen.setLastOpened(current) }
        hasNew = !isOpen && rows.contains { $0.status != .inTaskforce && $0.created > baseline }
        if isOpen, !rows.isEmpty { sendShownIfDue(at: current) }
    }

    /// 보임 지표: 목록이 행 1개 이상으로 열린 날, UTC 날짜마다 한 번. 서버에 닿았을 때만 그날을 적는다 (실패는 `shownRetryInterval` 뒤 다음 훑기에서 다시)
    private func sendShownIfDue(at current: Date) {
        let day = Int((current.timeIntervalSince1970 / 86_400).rounded(.down))
        guard lastShownDay != day, !shownInFlight else { return }
        if let lastShownAttempt, current.timeIntervalSince(lastShownAttempt) < Self.shownRetryInterval { return }
        shownInFlight = true
        lastShownAttempt = current
        let buckets = (ExternalSessionRules.rowsBucket(rows.count), ExternalSessionRules.heldBucket(rows.filter { if case .held = $0.status { true } else { false } }.count))
        let send = shown
        let token = scope.token
        Task { [weak self] in
            let reached = await send(buckets.0, buckets.1)
            guard let self, isCurrent(token) else { return }
            shownInFlight = false
            if reached {
                lastShownDay = day
            } else {
                log.log("external_sessions_shown_failed", [:])
            }
        }
    }
}
#endif
