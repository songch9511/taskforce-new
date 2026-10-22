import Foundation
import Observation

/// 세션 저장소가 서버와 닿는 면 (읽기 = Supabase RLS select만). 저장소는 이 프로토콜만 안다: 시험은 가짜로 붙잡기 · 실패 · 순서를 다룬다 (실제 연결은 `TaskforceReads`)
public protocol AgentSessionGateway: Sendable {
    func agentSessionSnapshot() async throws -> AgentSessionSnapshot
    /// 그 세션들만 좁게 읽는다 (OA D4a-13b: Assistant 창이 열린 에이전트 대화의 세션과 그 task). 기본 구현은 전체를 읽어 거른다 (좁게 읽는 길이 없는 가짜)
    func agentSessionSnapshot(sessionIDs: Set<UUID>) async throws -> AgentSessionSnapshot
}

extension AgentSessionGateway {
    public func agentSessionSnapshot(sessionIDs: Set<UUID>) async throws -> AgentSessionSnapshot {
        var snapshot = try await agentSessionSnapshot()
        snapshot.sessions = snapshot.sessions.filter { sessionIDs.contains($0.id) }
        snapshot.tasks = snapshot.tasks.filter { sessionIDs.contains($0.agentSessionID) }
        snapshot.runs = snapshot.runs.filter { $0.agentSessionID.map(sessionIDs.contains) ?? false }
        snapshot.conversations = snapshot.conversations.filter { sessionIDs.contains($0.agentSessionID) }
        return snapshot
    }
}

/// 세션 읽기 상태 (OA U2). Issues · 이슈 목록 · 상세 · 세션 패널 · 레일의 링이 같은 것을 본다.
/// - 읽기는 RLS 다섯 표뿐이고 쓰기는 없다 (세션 route 요청은 `AgentSessionEndpoints.swift`, 화면에 걸지 않는다)
/// - 마지막에 시작한 읽기만 반영한다. 계정이 떠나면 모두 비우고 늦은 응답을 버린다 (`AccountScope`)
/// - 다시 읽기는 `AgentSessionReadPolicy`: 열린 task가 있으면 5초마다. 그 밖의 계기(화면 열기 · `actions` 변경 · 온라인 복귀 · 깸)는 부르는 쪽이 `refresh()`를 부른다
/// - **좁게 읽기**(`focus`, OA D4a-13b): Assistant 창은 U2의 `issueScreens` 게이트 없이도 열린다. 에이전트 대화가 열려 있으면 그 대화의 세션과 task만 좁게 읽는 저장소를 따로 둔다 (같은 규칙 · 같은 다시 읽기).
///   `focus`가 주어지면 그 세션들만 읽고, 비어 있으면 읽지 않는다
/// - 세션 이름 · 대화 id는 사용자 글이라 메모리에만 둔다 (로그 · 디스크 없음)
/// - **끝남(Done)**: 기본은 `doneHold`(3초) 동안이다 (Assistant 창의 좁은 저장소). `done` 저장소를 주면(레일 · Sessions 패널의 U2 저장소, OA PR-D2 계약 23장) **사용자가 열어 볼 때까지** 남는다:
///   마지막 task가 `completed`로 바뀌는 것을 본 세션의 표시를 이 Mac에 저장해(id · 본 시각뿐) 다시 켠 뒤에도 남기고, `markOpened`가 지운다. 새 턴이 오면(더는 completed가 아니면) 표시도 지운다
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
    @ObservationIgnored private let focus: (@MainActor @Sendable () -> Set<UUID>)?
    /// 아직 안 연 끝남을 저장하는 곳. 없으면 끝남은 3초뿐이다
    @ObservationIgnored private var doneStore: (any RailDoneStore)?
    @ObservationIgnored private var snapshot: AgentSessionSnapshot?
    /// 세션의 마지막 task가 `completed`로 바뀌는 것을 본 때 (3초 동안 Done 링, `done` 저장소가 있으면 열어 볼 때까지)
    @ObservationIgnored private var doneObservedAt: [UUID: Date] = [:]
    /// 앞 읽기의 세션별 마지막 턴: 바뀐 것을 알아보는 기준
    @ObservationIgnored private var lastTurns: [UUID: (turn: Int, state: AgentTaskState)] = [:]
    /// 읽기 순번: 읽기를 시작할 때 하나씩 올린다. 마지막에 시작한 읽기만 반영한다
    @ObservationIgnored private var readSequence = 0
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    /// 새로 읽은 세션을 반영했다 (OA D4b-m-1): 질문 저장소가 질문을 기다리는 세션의 질문을 서버에서 읽는다. Done 만료로 항목만 다시 정할 때는 부르지 않는다
    @ObservationIgnored public var onApplied: (@MainActor ([AgentSessionItem]) -> Void)?

    /// - sleep: 다음 읽기 · Done 만료까지 기다리는 함수 (시험은 손으로 돌린다)
    /// - done: 아직 안 연 끝남을 저장하는 곳 (열어 볼 때까지 남기는 저장소만 준다). 저장본이 있으면 다시 켠 뒤에도 그 세션은 첫 읽기에서 done이다
    public init(
        gateway: any AgentSessionGateway, scope: AccountScope, now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping Sleep = { try? await Task.sleep(for: .seconds($0)) }, focus: (@MainActor @Sendable () -> Set<UUID>)? = nil,
        done: (any RailDoneStore)? = nil
    ) {
        self.gateway = gateway
        self.scope = scope
        self.now = now
        self.sleep = sleep
        self.focus = focus
        doneStore = done
        if let done { doneObservedAt = done.load().sessions }
        scope.onLeft { [weak self] in self?.reset() }
    }

    /// 이미 만들어진 저장소를 "열 때까지" 모양으로 올린다 (셸 컨트롤러가 실제 앱 경로에서 부른다: 이 저장소는 `ChatRuntime`이 만든다). 저장해 둔 표시를 읽어 와 지금 completed인 세션만 done으로 되살린다.
    /// 이미 올렸으면(처음 준 저장소가 이긴다) 아무 일도 없다
    public func useDoneStore(_ store: any RailDoneStore) {
        guard doneStore == nil else { return }
        doneStore = store
        var saved = store.load().sessions
        // 읽은 적이 있으면 지금 completed가 아닌 세션의 옛 표시는 버린다 (읽은 적이 없으면 첫 읽기가 같은 일을 한다)
        if hasRead { saved = saved.filter { lastTurns[$0.key]?.state == .completed } }
        doneObservedAt = saved
        if saved != store.load().sessions { saveDone() }
        rebuild()
    }

    /// 저장해 둔 표시가 이 계정의 것이 아니었다 (보안 P3-1: 다시 켠 뒤 로그인한 계정이 저장본의 주인과 다르다): 되살린 끝남 표시를 메모리에서 버린다.
    /// 저장소는 건드리지 않는다 — 저장본은 셸이 비운다 (같은 저장소를 이슈 칸과 나눠 쓴다). 새 턴이 끝나면 다시 done이 된다
    public func discardRestoredDone() {
        guard doneStore != nil, !doneObservedAt.isEmpty else { return }
        doneObservedAt = [:]
        rebuild()
    }

    /// 계정이 떠남: 모두 비운다 (읽는 중인 요청의 늦은 결과는 `scope.isCurrent`가 버린다). 저장해 둔 끝남 표시도 지운다: 다른 계정에 남지 않는다
    public func reset() {
        readSequence += 1
        pollTask?.cancel()
        expiryTask?.cancel()
        pollTask = nil
        expiryTask = nil
        snapshot = nil
        items = []
        doneObservedAt = [:]
        doneStore?.clear()
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
        // 좁게 읽는 저장소: 열린 에이전트 대화가 없으면 읽지 않는다 (다음 읽기 때 초점이 생기면 읽는다)
        let focused = focus?()
        if let focused, focused.isEmpty { return }
        readSequence += 1
        let sequence = readSequence
        if !hasRead { load = .loading }
        do {
            let fresh: AgentSessionSnapshot
            if let focused { fresh = try await gateway.agentSessionSnapshot(sessionIDs: focused) } else { fresh = try await gateway.agentSessionSnapshot() }
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
        let saved = doneObservedAt
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
        if doneObservedAt != saved { saveDone() }
        snapshot = fresh
        hasRead = true
        rebuild()
        onApplied?(items)
    }

    /// 지금 시각으로 항목을 다시 정한다 (Done 3초가 지났을 때)
    public func rebuild() {
        guard let snapshot else { return }
        items = AgentSessionRules.items(snapshot: snapshot, doneObservedAt: doneObservedAt, now: now(), untilOpened: doneStore != nil)
        scheduleExpiry()
    }

    // MARK: 열어 봄

    /// 사용자가 이 세션들을 열었다 (세션 패널 · 링 · Sessions의 줄): 끝남 표시를 지우고 그 자리에서 항목을 다시 정한다 (다음 읽기를 기다리지 않는다).
    /// 표시가 없거나 모르는 세션이면 아무 일도 없다. 같은 완료는 다시 오르지 않고, 새 턴이 끝나야 다시 done이다
    public func markOpened(_ ids: Set<UUID>) {
        let before = doneObservedAt
        for id in ids { doneObservedAt[id] = nil }
        guard doneObservedAt != before else { return }
        saveDone()
        rebuild()
    }

    public func markOpened(_ id: UUID) {
        markOpened([id])
    }

    /// 저장소를 준 구성만 저장한다. 세션 칸만 고친다 (이슈 칸은 셸의 몫)
    private func saveDone() {
        guard let doneStore else { return }
        let sessions = doneObservedAt
        doneStore.update { $0.sessions = sessions }
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
        // 열어 볼 때까지 남기는 구성에는 만료가 없다
        guard doneStore == nil else { return }
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
