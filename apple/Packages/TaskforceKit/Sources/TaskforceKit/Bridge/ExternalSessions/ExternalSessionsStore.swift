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
/// - 서버에는 훑을 때마다 목록을 알린다(속도 조절은 `ExternalSessionReporter`). "보임" 지표는 패널이 행 1개 이상으로 보인 첫 순간 한 번 (서버가 하루 한 번으로 거른다)
/// - 계정이 떠나면 비우고, 그 사이 시작한 훑기의 늦은 답은 쓰지 않는다
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
    @ObservationIgnored private let report: @Sendable ([ExternalSessionRow]) async -> Void
    @ObservationIgnored private let shown: @Sendable (_ rowsBucket: String, _ heldBucket: String) async -> Void
    @ObservationIgnored private let seen: any ExternalSessionSeenStore
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let pollInterval: TimeInterval
    @ObservationIgnored private var inFlight: Task<Void, Never>?
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private var shownSent = false

    public init(
        scope: AccountScope, scan: @escaping @Sendable () async -> ExternalSessionScan, isInstalled: @escaping @Sendable () async -> Bool? = { nil },
        report: @escaping @Sendable ([ExternalSessionRow]) async -> Void = { _ in }, shown: @escaping @Sendable (String, String) async -> Void = { _, _ in },
        seen: any ExternalSessionSeenStore, now: @escaping @Sendable () -> Date = { Date() }, pollInterval: TimeInterval = 10
    ) {
        self.scope = scope
        self.scan = scan
        self.isInstalled = isInstalled
        self.report = report
        self.shown = shown
        self.seen = seen
        self.now = now
        self.pollInterval = pollInterval
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
        shownSent = false
    }

    /// 레일이 펼쳐졌다: 점을 위해 한 번 훑는다 (패널이 열려 있으면 이미 훑고 있다)
    public func railExpanded() {
        guard !isOpen else { return }
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
        apply(result, installed: installed)
        if result.failure == nil {
            let current = rows
            let send = report
            Task { await send(current) }
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
            return
        case .notFound?:
            rows = []
            phase = installed == true ? .empty : .notInstalled
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
        if isOpen, !rows.isEmpty, !shownSent {
            shownSent = true
            let buckets = (ExternalSessionRules.rowsBucket(rows.count), ExternalSessionRules.heldBucket(rows.filter { if case .held = $0.status { true } else { false } }.count))
            let send = shown
            Task { await send(buckets.0, buckets.1) }
        }
    }
}
#endif
