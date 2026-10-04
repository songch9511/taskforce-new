import Foundation
import Observation
import TaskforceKit

/// 실행(U2, docs/EXECUTION.md) 상태: 쓸 수 있는지(credits) · 할 일마다 run · 단계 · 초안 · 멈춘 run · 폴링.
/// 무엇이 사실인지는 서버가 정한다: 여기서는 읽고(`TaskforceReads`, RLS) 쓰기를 보내기만 한다(`APIClient` run 만들기 · 멈추기).
/// - 실행 UI는 `GET /credits`가 200일 때만 보인다. 404면 숨기고, 전송 오류면 마지막 값을 그대로 둔다 (깜빡이지 않게).
/// - iPhone은 run을 시작하지 않는다 (`RunAvailability.canStart`): `start`가 iOS에서는 서버를 부르지 않는다.
/// - run이 끝나면 `onRunsFinished`로 알린다: 부르는 쪽이 `/now`를 다시 받는다 (바뀜 점은 초안 receipt로 서버가 켠다).
/// - 계정이 떠나면(`SessionStore.onSignedOut`) 모두 비우고, 그 전에 보낸 요청의 늦은 결과는 세대 번호로 버린다.
/// - 요청 · 초안 본문 · 질문은 사용자 글이다: 메모리에만 두고 로그 · 저장본 · 디스크 캐시에 남기지 않는다.
/// 화면(Mac 런처 · iPhone 상세)은 U2 Mac PR3 · PR5가 붙인다.
@MainActor
@Observable
final class RunStore {
    /// `GET /credits` 결과
    enum Credits: Equatable {
        /// 아직 모름 (처음 · 계정 전환 뒤): 실행 UI를 숨긴다
        case unknown
        /// 404: 실행을 쓸 수 없는 계정 (숨긴다)
        case unavailable
        case available(CreditsSummary, checkedAt: Date)
    }

    /// 시작 결과
    enum StartResult: Equatable {
        case started(RunSummary)
        case failed(RunStartFailure)
        /// 보내지 않음 (빈 요청 · 보내는 중 · 이 기기는 시작하지 않음)
        case ignored
    }

    /// 초안 링크(`taskforce://artifacts/<id>`)를 읽은 결과
    enum DraftLookup: Equatable {
        case found(Artifact)
        /// 없음 (다른 계정 · 지워진 행): `ArtifactLink.notFoundMessage`
        case notFound
        case failed(String)
    }

    private(set) var credits: Credits = .unknown
    /// 마지막 credits 읽기가 실패함 (앞 값은 그대로 둔다)
    private(set) var creditsFailed = false
    /// 할 일마다 읽은 run (최근 것이 위)
    private(set) var runs: [UUID: [RunSummary]] = [:]
    /// run마다 단계 (차례대로)
    private(set) var steps: [UUID: [StepSummary]] = [:]
    /// 할 일마다 초안 (최근 것이 위)
    private(set) var drafts: [UUID: [Artifact]] = [:]
    /// 끝나지 않은 run 전부 (범위 `Taskforce Working`)
    private(set) var active: [RunSummary] = []
    /// 크레딧이 모자라 멈춘 run (S3)
    private(set) var paused: [RunSummary] = []
    /// `POST /runs`를 보내는 중인 할 일 (두 번 누름 막기)
    private(set) var starting: Set<UUID> = []
    /// 멈추는 중인 할 일
    private(set) var stopping: Set<UUID> = []
    var message: String?
    /// 지켜보던 run이 끝남: `/now`를 다시 받는다
    @ObservationIgnored var onRunsFinished: (() -> Void)?

    let services: AppServices
    let platform: RunPlatform

    /// 지켜보는 할 일 (보이는 상세 · 목록). 비면 폴링하지 않는다
    private(set) var watched: Set<UUID> = []
    private var watchingSince = Date()
    private var pollTask: Task<Void, Never>?
    /// `reset()`마다 오른다: 계정이 떠나기 전에 보낸 요청의 늦은 결과를 버린다
    private var generation = 0

    #if DEBUG
    /// 디자인 비교용 견본을 보여 주는 중 (`SampleData`, 서버를 부르지 않는다)
    var sampleMode = false
    #endif

    init(services: AppServices, session: SessionStore? = nil, platform: RunPlatform = .current) {
        self.services = services
        self.platform = platform
        // 계정이 떠나면 (로그아웃 · 만료 · 계정 삭제 · 전환) 그 자리에서 비운다
        session?.onSignedOut { [weak self] _ in self?.reset() }
    }

    // MARK: 읽기 값

    /// 실행을 쓸 수 있는 계정의 마지막 credits (모름 · 404면 nil)
    var summary: CreditsSummary? {
        if case .available(let summary, _) = credits { summary } else { nil }
    }

    var checkedAt: Date? {
        if case .available(_, let checkedAt) = credits { checkedAt } else { nil }
    }

    /// 실행 UI를 보일지 (credits 200)
    var isAvailable: Bool { summary != nil }

    /// 끝나지 않은 run이 있는 할 일 (`TaskScope.taskforceWorking`)
    var workingActionIDs: Set<UUID> {
        Set(knownRuns.filter(\.isOpen).map(\.actionID))
    }

    /// 상세의 Taskforce 갈래
    func lane(for actionID: UUID) -> RunLane {
        let latest = RunSummary.latestByAction(runs(for: actionID))[actionID]
        return RunLane.state(run: latest, steps: latest.flatMap { steps[$0.id] } ?? [], artifacts: drafts[actionID] ?? [])
    }

    /// `Run with AI…`를 보일지 · 켤지
    func availability(for actionID: UUID, signedIn: Bool, refresh: RefreshState) -> RunAvailability {
        RunAvailability.evaluate(
            platform: platform, credits: summary, signedIn: signedIn, refresh: refresh, hasOpenRun: !stopTargets(for: actionID).isEmpty
        )
    }

    /// `Stop Taskforce` 대상 (아는 run 중 그 할 일의 끝나지 않은 것)
    func stopTargets(for actionID: UUID) -> [UUID] {
        RunStop.targets(actionID: actionID, runs: runs(for: actionID))
    }

    /// S3 행 (`titles`: 앱 목록의 할 일 제목)
    func creditsRows(titles: [UUID: String], now: Date = Date()) -> CreditsRows {
        CreditsRows.make(credits: summary, loadFailed: creditsFailed, checkedAt: checkedAt, pausedRuns: paused, titles: titles, now: now)
    }

    /// 그 할 일에 대해 아는 run (상세에서 읽은 것 + 끝나지 않은 run 목록, 같은 run은 한 번)
    private func runs(for actionID: UUID) -> [RunSummary] {
        merged(runs[actionID] ?? [], active.filter { $0.actionID == actionID })
    }

    private var knownRuns: [RunSummary] {
        merged(runs.values.flatMap { $0 }, active)
    }

    /// 같은 run은 먼저 온 쪽(더 최근에 읽은 쪽을 앞에 둔다)
    private func merged(_ first: [RunSummary], _ second: [RunSummary]) -> [RunSummary] {
        var seen = Set<UUID>()
        return (first + second).filter { seen.insert($0.id).inserted }
    }

    // MARK: 불러오기

    /// 로그아웃 · 계정 전환 뒤
    func reset() {
        #if DEBUG
        if sampleMode { return }
        #endif
        generation += 1
        pollTask?.cancel()
        pollTask = nil
        credits = .unknown
        creditsFailed = false
        runs = [:]
        steps = [:]
        drafts = [:]
        active = []
        paused = []
        starting = []
        stopping = []
        message = nil
        watched = []
    }

    /// `GET /credits?since=<이번 달 1일>`. 404면 숨기고, 다른 실패면 앞 값을 둔다
    func loadCredits(now: Date = Date()) async {
        #if DEBUG
        if sampleMode { return }
        #endif
        let generation = generation
        do {
            let result = try await services.api.credits(since: CreditsMonth.start(of: now))
            guard generation == self.generation else { return }
            creditsFailed = false
            if let result {
                let wasAvailable = isAvailable
                credits = .available(result, checkedAt: Date())
                // 쓸 수 있음을 막 알았으면 지켜보던 할 일을 읽기 시작한다 (`watch`가 credits보다 먼저 불렸을 때)
                if !wasAvailable, !watched.isEmpty { restartPolling() }
            } else {
                credits = .unavailable
                pollTask?.cancel()
            }
        } catch is CancellationError {
        } catch {
            guard generation == self.generation else { return }
            creditsFailed = true
        }
    }

    /// 끝나지 않은 run · 멈춘 run (범위 개수 · S3). 실행을 쓸 수 없으면 읽지 않는다. 실패하면 앞 값을 둔다
    func refreshActive() async {
        #if DEBUG
        if sampleMode { return }
        #endif
        guard isAvailable else { return }
        let generation = generation
        let reads = services.reads
        async let open = try? reads.activeRuns()
        async let held = try? reads.pausedRuns()
        let (openRuns, heldRuns) = await (open, held)
        guard generation == self.generation else { return }
        if let openRuns { active = openRuns }
        if let heldRuns { paused = heldRuns }
    }

    /// 보이는 할 일을 지켜본다 (런처 상세 · iPhone 상세). 곧바로 읽고, 끝나지 않은 run이 있는 동안 `RunPolling` 간격으로 다시 읽는다.
    /// 빈 집합이면 그만 본다 (런처를 닫음 · 앱이 뒤로 감)
    func watch(_ actionIDs: Set<UUID>) {
        guard actionIDs != watched else { return }
        watched = actionIDs
        watchingSince = Date()
        pollTask?.cancel()
        pollTask = nil
        guard !actionIDs.isEmpty else { return }
        pollTask = Task { [weak self] in
            await self?.refreshWatched()
            await self?.poll()
        }
    }

    /// Realtime `actions` 신호 (초안 receipt가 Action을 바꾼다): 지켜보는 할 일과 끝나지 않은 run을 다시 읽는다
    func actionsChanged() async {
        await refreshWatched()
        await refreshActive()
    }

    private func poll() async {
        while !Task.isCancelled {
            let open = watched.flatMap { runs(for: $0) }
            guard let interval = RunPolling.interval(openRuns: open, watchingSince: watchingSince, now: Date()) else { return }
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            await refreshWatched()
        }
    }

    /// 지켜보는 할 일의 run · 최신 run의 단계 · 초안을 읽는다. 지켜보던 run이 끝났으면 `/now` · credits · 끝나지 않은 run을 다시 읽는다
    func refreshWatched() async {
        #if DEBUG
        if sampleMode { return }
        #endif
        guard isAvailable, !watched.isEmpty else { return }
        let generation = generation
        let ids = Array(watched)
        let before = ids.flatMap { runs(for: $0) }
        guard let fresh = try? await services.reads.latestRuns(actionIDs: ids), generation == self.generation else { return }
        let grouped = Dictionary(grouping: fresh, by: \.actionID)
        for id in ids { runs[id] = grouped[id] ?? [] }
        // 끝나지 않은 run 목록에서도 끝난 run을 뺀다 (범위 개수가 바로 맞게)
        let finishedIDs = Set(fresh.filter { !$0.isOpen }.map(\.id))
        active.removeAll { finishedIDs.contains($0.id) }
        await withTaskGroup(of: Void.self) { group in
            for (actionID, latest) in RunSummary.latestByAction(fresh) {
                group.addTask { await self.loadSteps(runID: latest.id, generation: generation) }
                group.addTask { await self.loadDrafts(actionID: actionID, generation: generation) }
            }
        }
        guard generation == self.generation else { return }
        if RunPolling.finished(before: before, after: fresh) {
            onRunsFinished?()
            await loadCredits()
            await refreshActive()
        }
    }

    private func loadSteps(runID: UUID, generation: Int) async {
        guard let rows = try? await services.reads.steps(runID: runID), generation == self.generation else { return }
        steps[runID] = rows
    }

    private func loadDrafts(actionID: UUID, generation: Int) async {
        guard let rows = try? await services.reads.artifacts(actionID: actionID), generation == self.generation else { return }
        drafts[actionID] = rows
    }

    // MARK: 쓰기

    /// `Run with AI` Start: `POST /runs` 한 번. 보내는 동안 같은 할 일의 Start는 무시한다.
    /// 202면 그 run을 곧바로 갈래에 보이고(잔액이 모자라면 곧 `paused credit`이 된다) 빠르게 다시 읽는다
    func start(actionID: UUID, request: String) async -> StartResult {
        guard RunAvailability.canStart(platform), !starting.contains(actionID),
              !CreateRunRequest(actionID: actionID, request: request).isEmpty
        else { return .ignored }
        starting.insert(actionID)
        defer { starting.remove(actionID) }
        #if DEBUG
        if sampleMode { return .started(startSample(actionID: actionID)) }
        #endif
        let generation = generation
        do {
            let run = try await services.api.createRun(actionID: actionID, request: request)
            guard generation == self.generation else { return .ignored }
            runs[actionID] = [run] + (runs[actionID] ?? []).filter { $0.id != run.id }
            active = [run] + active.filter { $0.id != run.id }
            if watched.contains(actionID) { restartPolling() }
            return .started(run)
        } catch is CancellationError {
            return .ignored
        } catch {
            guard generation == self.generation else { return .ignored }
            return .failed(RunStartFailure(error as? APIError ?? .unexpectedStatus(0)))
        }
    }

    /// `Stop Taskforce`: 그 할 일의 끝나지 않은 run을 모두 멈춘다 (다른 기기 · 웹에서 시작한 run 포함, 먼저 새로 읽는다).
    /// 이미 끝났거나 없는 run(404)은 그대로 둔다. 하나라도 보내지 못했으면 false + `message`.
    /// 앱에서 할 일을 Delete · Done하기 전에도 부른다 (`RunStop`)
    @discardableResult
    func stop(actionID: UUID) async -> Bool {
        #if DEBUG
        if sampleMode {
            stopSample(actionID: actionID)
            return true
        }
        #endif
        let generation = generation
        stopping.insert(actionID)
        defer { stopping.remove(actionID) }
        if let fresh = try? await services.reads.latestRuns(actionIDs: [actionID]) {
            guard generation == self.generation else { return false }
            runs[actionID] = fresh
        }
        var allSent = true
        for runID in stopTargets(for: actionID) {
            do {
                let run = try await services.api.stopRun(id: runID)
                guard generation == self.generation else { return false }
                replace(run)
            } catch let error as APIError where error.status == 404 {
                guard generation == self.generation else { return false }
                active.removeAll { $0.id == runID }
            } catch {
                guard generation == self.generation else { return false }
                allSent = false
                message = error.userMessage
            }
        }
        if watched.contains(actionID) { restartPolling() }
        return allSent
    }

    /// 초안 링크를 연다: 읽어 둔 초안이 있으면 그것, 없으면 RLS로 읽는다
    func draft(id: UUID) async -> DraftLookup {
        if let cached = drafts.values.lazy.flatMap({ $0 }).first(where: { $0.id == id }) { return .found(cached) }
        #if DEBUG
        if sampleMode { return .notFound }
        #endif
        let generation = generation
        do {
            let found = try await services.reads.artifact(id: id)
            guard generation == self.generation else { return .notFound }
            return found.map(DraftLookup.found) ?? .notFound
        } catch {
            return .failed(error.userMessage)
        }
    }

    /// 서버가 돌려준 run으로 바꾼다 (상세에서 읽지 않은 run이면 앞에 넣는다)
    private func replace(_ run: RunSummary) {
        let known = runs[run.actionID] ?? []
        runs[run.actionID] = known.contains { $0.id == run.id } ? known.map { $0.id == run.id ? run : $0 } : [run] + known
        if run.isOpen {
            active = active.map { $0.id == run.id ? run : $0 }
        } else {
            active.removeAll { $0.id == run.id }
        }
    }

    private func restartPolling() {
        watchingSince = Date()
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            await self?.refreshWatched()
            await self?.poll()
        }
    }

    #if DEBUG
    /// 견본으로 채운다 (`SampleData`)
    func applySample(
        credits: Credits, runs: [RunSummary], steps: [StepSummary], drafts: [Artifact], paused: [RunSummary] = []
    ) {
        sampleMode = true
        self.credits = credits
        self.runs = Dictionary(grouping: runs, by: \.actionID)
        self.steps = Dictionary(grouping: steps, by: \.runID)
        self.drafts = Dictionary(grouping: drafts.sorted { $0.createdAt > $1.createdAt }, by: \.actionID)
        active = runs.filter(\.isOpen)
        self.paused = paused
    }

    private func startSample(actionID: UUID) -> RunSummary {
        let run = RunSummary(id: UUID(), actionID: actionID, state: .running, createdAt: Date())
        runs[actionID] = [run] + (runs[actionID] ?? [])
        active.insert(run, at: 0)
        return run
    }

    private func stopSample(actionID: UUID) {
        for runID in stopTargets(for: actionID) {
            guard let run = runs[actionID]?.first(where: { $0.id == runID }) ?? active.first(where: { $0.id == runID }) else { continue }
            replace(RunSummary(
                id: run.id, actionID: run.actionID, goal: run.goal, state: .stopped, holdReason: run.holdReason, outcome: run.outcome,
                budgetCredits: run.budgetCredits, createdAt: run.createdAt, stoppedAt: Date()
            ))
        }
    }
    #endif
}
