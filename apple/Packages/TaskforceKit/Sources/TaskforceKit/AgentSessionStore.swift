import Foundation
import Observation

/// 세션 저장소가 서버와 닿는 면 (읽기 = Supabase RLS select만). 저장소는 이 프로토콜만 안다: 시험은 가짜로 붙잡기 · 실패 · 순서를 다룬다 (실제 연결은 `TaskforceReads`)
public protocol AgentSessionGateway: Sendable {
    func agentSessionSnapshot() async throws -> AgentSessionSnapshot
}

/// 세션 읽기 상태 (OA U2). Issues · 이슈 목록 · 상세 · 세션 패널 · 레일의 링이 같은 것을 본다.
/// - 읽기는 RLS 다섯 표뿐이고 쓰기는 없다 (세션 route 요청은 `AgentSessionEndpoints.swift`, 화면에 걸지 않는다)
/// - 마지막에 시작한 읽기만 반영한다. 계정이 떠나면 모두 비우고 늦은 응답을 버린다 (`AccountScope`)
/// - 다시 읽기는 `AgentSessionReadPolicy`: 열린 task가 있으면 5초마다. 그 밖의 계기(화면 열기 · `actions` 변경 · 온라인 복귀 · 깸)는 부르는 쪽이 `refresh()`를 부른다
/// - 세션 이름 · 대화 id는 사용자 글이라 메모리에만 둔다 (로그 · 디스크 없음)
@MainActor
@Observable
public final class AgentSessionStore {
    public typealias Sleep = @Sendable (TimeInterval) async -> Void

    /// 읽은 값에서 정한 세션들 (만든 시각 순)
    public private(set) var items: [AgentSessionItem] = []
    /// 읽기 상태: 읽는 중 · 받음(+그 뒤 문제) · 오프라인 · 실패. 받은 적이 있으면 실패해도 받은 것을 그대로 둔다
    public private(set) var load: WorkLoad = .loading
    /// 이번 세션에서 서버로부터 읽은 적이 있다
    public private(set) var hasRead = false
    /// 서버 DB에 세션 표가 아직 없다 (마이그레이션 적용 전): 세션이 없는 것이지 실패가 아니다
    public private(set) var readsUnavailable = false
    public private(set) var isOnline = true
    public private(set) var isAsleep = false

    @ObservationIgnored private let gateway: any AgentSessionGateway
    @ObservationIgnored private let scope: AccountScope
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let sleep: Sleep
    @ObservationIgnored private var snapshot: AgentSessionSnapshot?
    /// 세션의 마지막 task가 `completed`로 바뀌는 것을 본 때 (3초 동안 Done 링)
    @ObservationIgnored private var doneObservedAt: [UUID: Date] = [:]
    /// 앞 읽기의 세션별 마지막 턴: 바뀐 것을 알아보는 기준
    @ObservationIgnored private var lastTurns: [UUID: (turn: Int, state: AgentTaskState)] = [:]
    /// 읽기 순번: 읽기를 시작할 때 하나씩 올린다. 마지막에 시작한 읽기만 반영한다
    @ObservationIgnored private var readSequence = 0
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var expiryTask: Task<Void, Never>?

    /// - sleep: 다음 읽기 · Done 만료까지 기다리는 함수 (시험은 손으로 돌린다)
    public init(
        gateway: any AgentSessionGateway, scope: AccountScope, now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping Sleep = { try? await Task.sleep(for: .seconds($0)) }
    ) {
        self.gateway = gateway
        self.scope = scope
        self.now = now
        self.sleep = sleep
        scope.onLeft { [weak self] in self?.reset() }
    }

    /// 계정이 떠남: 모두 비운다 (읽는 중인 요청의 늦은 결과는 `scope.isCurrent`가 버린다)
    public func reset() {
        readSequence += 1
        pollTask?.cancel()
        expiryTask?.cancel()
        pollTask = nil
        expiryTask = nil
        snapshot = nil
        items = []
        doneObservedAt = [:]
        lastTurns = [:]
        load = .loading
        hasRead = false
        readsUnavailable = false
    }

    // MARK: 계기

    /// 연결 경로: 온라인으로 돌아오면 한 번 읽는다 (이미 온라인이면 읽지 않는다)
    public func pathChanged(online: Bool) {
        let cameBack = online && !isOnline
        isOnline = online
        if cameBack { Task { await refresh() } }
    }

    /// Mac이 잠들었다 · 깼다: 자는 동안 5초 읽기가 멈추고, 깨면 한 번 읽는다
    public func setAsleep(_ asleep: Bool) {
        guard asleep != isAsleep else { return }
        isAsleep = asleep
        if asleep {
            pollTask?.cancel()
            pollTask = nil
        } else {
            Task { await refresh() }
        }
    }

    // MARK: 읽기

    /// 다시 읽는다 (화면을 열 때 · `actions` 변경 · 온라인 복귀 · 깸 · 5초). 받은 것이 있으면 실패해도 그대로 둔다. 마지막에 시작한 읽기만 반영한다
    public func refresh() async {
        guard let token = scope.token else { return }
        readSequence += 1
        let sequence = readSequence
        if !hasRead { load = .loading }
        do {
            let fresh = try await gateway.agentSessionSnapshot()
            guard scope.isCurrent(token), sequence == readSequence else { return }
            apply(fresh)
            readsUnavailable = false
            load = .loaded(problem: nil)
        } catch {
            guard scope.isCurrent(token), sequence == readSequence, let failure = ReadFailure.from(error, online: isOnline) else { return }
            if failure == .unavailable {
                // 서버에 세션 표가 아직 없다: 실패가 아니라 세션이 없는 것이다
                apply(.empty)
                readsUnavailable = true
                load = .loaded(problem: nil)
            } else if hasRead {
                load = .loaded(problem: failure == .offline ? .offline : .failed)
            } else {
                load = failure == .offline ? .offline : .failed
            }
        }
        reschedule()
    }

    private func apply(_ fresh: AgentSessionSnapshot) {
        let current = now()
        // 마지막 task가 `completed`로 바뀌는 것을 이번에 처음 본 세션만 "방금 끝남"이다 (처음 읽을 때 이미 끝나 있던 것은 아니다)
        var turns: [UUID: (turn: Int, state: AgentTaskState)] = [:]
        for session in fresh.sessions {
            guard let task = AgentSessionRules.lastTask(of: session.id, in: fresh.tasks), let turn = task.turnSeq else { continue }
            turns[session.id] = (turn, task.state)
            guard hasRead, task.state == .completed, let before = lastTurns[session.id] else { continue }
            if before.turn != turn || before.state != .completed { doneObservedAt[session.id] = current }
        }
        lastTurns = turns
        doneObservedAt = doneObservedAt.filter { id, _ in turns[id]?.state == .completed }
        snapshot = fresh
        hasRead = true
        rebuild()
    }

    /// 지금 시각으로 항목을 다시 정한다 (Done 3초가 지났을 때)
    public func rebuild() {
        guard let snapshot else { return }
        items = AgentSessionRules.items(snapshot: snapshot, doneObservedAt: doneObservedAt, now: now())
        scheduleExpiry()
    }

    // MARK: 시계

    /// 열린 task가 있으면 5초 뒤 다시 읽는다. 없거나 잠자면 걸지 않는다
    private func reschedule() {
        pollTask?.cancel()
        pollTask = nil
        guard let delay = AgentSessionReadPolicy.pollInterval(items: items, asleep: isAsleep) else { return }
        let sleep = sleep
        pollTask = Task { [weak self] in
            await sleep(delay)
            guard !Task.isCancelled, let self else { return }
            await self.refresh()
        }
    }

    /// 방금 끝남(Done)이 3초 뒤 풀린다. **미래의 만료만** 예약한다: 이미 지난 것은 걷어 낸다 (먼저 끝난 세션의 지난 시각이 남아 다음 만료를 막으면
    /// 폴링이 멈춘 뒤에도 둘째의 Done이 계속 남는다)
    private func scheduleExpiry() {
        expiryTask?.cancel()
        expiryTask = nil
        let current = now()
        doneObservedAt = doneObservedAt.filter { current.timeIntervalSince($0.value) < AgentSessionRules.doneHold }
        guard let earliest = doneObservedAt.values.min() else { return }
        let remaining = AgentSessionRules.doneHold - current.timeIntervalSince(earliest)
        guard remaining > 0 else { return }
        let sleep = sleep
        expiryTask = Task { [weak self] in
            await sleep(remaining)
            guard !Task.isCancelled, let self else { return }
            self.rebuild()
        }
    }

    // MARK: 보이는 것

    /// 이 이슈들의 세션 (탭 · Sessions 목록)
    public func sessions(of issues: Set<UUID>) -> [AgentSessionItem] {
        AgentSessionRules.sessions(of: issues, in: items)
    }

    /// 한 이슈의 링 하나 (v1 run · 확인 요청의 링과 그 이슈 세션들의 링 중 먼저인 것)
    public func ring(of issue: UUID, v1: AgentSessionRing?) -> AgentSessionRing? {
        AgentSessionRules.issueRing(v1: v1, sessions: sessions(of: [issue]))
    }

    public func item(id: UUID) -> AgentSessionItem? {
        items.first { $0.id == id }
    }
}
