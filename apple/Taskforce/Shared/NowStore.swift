import Foundation
import Observation
import TaskforceKit

/// 지금 할 일 + 확인 요청 + 오늘 끝낸 할 일. 순서 · 이유는 서버가 정하고, 무엇이 바뀌든 `/now`와 Done Today를 다시 불러온다.
/// 진행 상태(To Do · In Progress · Done) 바꾸기 · 삭제 · 되살리기는 서버 응답을 기다리지 않고 먼저 보여 준다 (`TaskBoard.applying`).
/// iPhone 화면과 Mac 런처가 같은 것을 쓴다.
/// 저장본(`SavedNowStore`, 제목 · 기한 · 상태만): `session` · `saved`를 주면 `/now`가 성공할 때마다 요청한 계정 폴더에 쓰고,
/// 이번 실행에서 `/now`를 받기 전(오프라인 · 새로고침 실패 · 처음 불러오는 중)에는 그 계정의 저장본을 보인다 (`savedCopy`).
/// 지우기는 계정이 떠날 때 앱이 `SessionStore.onSignedOut`에서 한다 (Mac: `LauncherModel`, iPhone: `Startup.make`).
@MainActor
@Observable
final class NowStore {
    private(set) var response: NowResponse?
    /// 오늘 끝낸 할 일 (Supabase 직접 읽기, 최근 것이 위)
    private(set) var doneToday: [ActionSummary] = []
    private(set) var loadError: String?
    private(set) var loaded = false
    /// 요청 중인 확인 요청 (Confirm · Dismiss 버튼을 잠근다)
    private(set) var busy: Set<UUID> = []
    /// 먼저 보여 주는 내 변경. 쓰기가 끝난 뒤 시작한 불러오기가 반영되면 지운다.
    private var pending: [UUID: Pending] = [:]
    private var changeCount = 0
    /// 할 일마다 쓰기를 차례로 보낸다 (완료 직후 Undo처럼 겹쳐도 보낸 순서대로)
    private var writes: [UUID: (token: Int, task: Task<Void, Never>)] = [:]
    /// 이 기기에서 Done으로 옮긴 할 일의 그 전 상태. ✓를 누르면 그리로 되돌린다.
    private var stateBeforeDone: [UUID: WorkState] = [:]
    /// 할 일마다 읽어 둔 근거 (Supabase 직접 읽기)
    private(set) var evidence: [UUID: EvidenceDigest] = [:]
    /// 제공자 아이콘용 메타데이터만 배치로 읽는다 (인용 · 원문 본문은 읽지 않는다)
    private(set) var sourceServicesByAction: [UUID: [SourceService]] = [:]
    /// Optional metadata can fail without hiding the task list; the launcher offers a retry.
    private(set) var sourceServicesFailed = false
    /// 근거를 읽지 못한 할 일 (계속 "읽는 중"으로 두지 않게)
    private(set) var evidenceFailed: Set<UUID> = []
    /// 현재 읽는 중인 근거 (런처 상세의 진행 상태)
    private(set) var evidenceLoading: Set<UUID> = []
    private var evidenceLoadCounts: [UUID: Int] = [:]
    var message: String?
    /// 직접 추가 실패 문구. iPhone New Task 시트가 자기 알림으로 보여 준다 (시트가 떠 있는 동안 홈 화면 알림은 뜨지 않는다).
    var addError: String?

    /// 연결 · 불러오기 상태 (Figma M15 · M19 · M20, `RefreshTracker`)
    private(set) var refresh = RefreshTracker()
    /// 이번 실행에서 `/now`를 받기 전에 보일 지금 계정의 저장본. `/now`를 받으면 비운다
    private(set) var savedCopy: SavedNow?
    /// 마지막 불러오기가 서버의 401로 실패함 (세션을 확인하지 못함: 다시 시도보다 로그아웃 · 로그인이 답이다)
    private(set) var authFailed = false
    /// `/now`를 새로 받아 반영한 직후 (Mac 런처: 바뀜 점 · seen 기록을 서버 값으로 맞춘다)
    @ObservationIgnored var onLoaded: (() -> Void)?

    /// 겹쳐 부른 불러오기 중 마지막 것만 반영한다 (늦게 온 옛 응답이 새 응답을 덮지 않게)
    private var loadSequence = 0
    /// `reset()`마다 오른다: 로그아웃 · 계정 전환 전에 보낸 요청의 늦은 결과(근거 · 오류 문구 · 클립보드)를 버린다
    private var generation = 0
    @ObservationIgnored private var sourceServicesTask: Task<Void, Never>?

    private struct Pending {
        let change: TaskChange
        let token: Int
        /// 이 번호 이상의 불러오기가 반영되면 지운다 (쓰기가 끝난 뒤 시작한 불러오기). 쓰는 중이면 nil
        var settledBy: Int?
    }

    #if DEBUG
    /// 디자인 비교용 견본을 보여 주는 중 (`SampleData`)
    var sampleMode = false

    func applySample(
        _ response: NowResponse, doneToday: [ActionSummary], evidence: [UUID: EvidenceDigest],
        sourceServices: [UUID: [SourceService]] = [:]
    ) {
        self.response = response
        self.doneToday = doneToday
        self.evidence = evidence
        sourceServicesByAction = sourceServices
        loaded = true
    }

    /// 견본: 저장본 · 연결 상태 (`-TFSampleOffline` · `-TFSampleRefreshFailed` · `-TFSampleNoSaved` · `-TFSampleLoading`).
    /// 목록(`response`)은 비우고 저장본만 보인다 (이번 실행에서 `/now`를 받기 전)
    func applySampleState(saved copy: SavedNow?, offlineSince: Date?, failedAt: Date?) {
        response = nil
        doneToday = []
        loaded = false
        savedCopy = copy
        if let copy { refresh.restoredSaved(savedAt: copy.savedAt) }
        if let offlineSince { refresh.pathChanged(online: false, at: offlineSince) }
        if let failedAt {
            refresh.loadStarted()
            refresh.loadFailed(at: failedAt)
        }
    }

    /// 견본: 이번 실행에서 받은 목록을 둔 채 끊김 (`-TFSampleOfflineLoaded`)
    func applySampleOffline(loadedAt: Date, since: Date) {
        refresh.loadSucceeded(at: loadedAt)
        refresh.pathChanged(online: false, at: since)
    }

    /// 견본: 서버 없이 진행 상태 바꾸기를 바로 목록에 반영한다
    private func commitSample() {
        let board = self.board
        response = board.now
        doneToday = board.doneToday
        pending = [:]
    }
    #endif
    let services: AppServices
    /// 저장본을 쓸 계정을 정한다 (없으면 저장본을 쓰지 않는다)
    private let session: SessionStore?
    private let saved: SavedNowStore?

    init(services: AppServices, session: SessionStore? = nil, saved: SavedNowStore? = nil) {
        self.services = services
        self.session = session
        self.saved = saved
    }

    var refreshState: RefreshState { refresh.state }

    /// 로그인한 계정 (저장본을 읽고 쓰는 기준)
    private var signedInAccount: UUID? {
        if case .signedIn(let userID, _) = session?.state { userID } else { nil }
    }

    /// 로그아웃 · 계정 전환 뒤 (Mac 런처는 이 저장소 하나를 계속 쓴다)
    func reset() {
        #if DEBUG
        if sampleMode { return }
        #endif
        generation += 1
        loadSequence += 1
        sourceServicesTask?.cancel()
        sourceServicesTask = nil
        response = nil
        doneToday = []
        loadError = nil
        loaded = false
        busy = []
        pending = [:]
        writes = [:]
        stateBeforeDone = [:]
        evidence = [:]
        sourceServicesByAction = [:]
        sourceServicesFailed = false
        evidenceFailed = []
        evidenceLoading = []
        evidenceLoadCounts = [:]
        message = nil
        addError = nil
        refresh.reset()
        savedCopy = nil
        authFailed = false
    }

    /// 지금 계정의 저장본을 읽어 둔다 (이번 실행에서 `/now`를 받기 전에 보인다). 로그인 · 계정 전환 직후 `reset()` 뒤에 부른다
    func restoreSaved() {
        #if DEBUG
        // 견본은 이 기기의 실제 저장본을 읽지 않는다 (견본 스크린샷에 실제 할 일 제목이 섞이지 않게)
        if sampleMode { return }
        #endif
        guard response == nil, let saved, let account = signedInAccount, let copy = saved.load(account: account) else { return }
        savedCopy = copy
        refresh.restoredSaved(savedAt: copy.savedAt)
    }

    /// 연결 경로가 바뀜. 오프라인에서 돌아왔으면 true (부르는 쪽이 다시 불러온다)
    @discardableResult
    func pathChanged(online: Bool, at date: Date = Date()) -> Bool {
        refresh.pathChanged(online: online, at: date)
    }

    /// 방금 받은 `/now`를 그 요청을 보낸 계정의 저장본으로 남긴다.
    /// 쓰는 순간(main actor)에 아직 그 계정이 로그인해 있고 그사이 `reset()`이 없었을 때만: 로그아웃 뒤 늦게 온 `/now`가 다시 쓰지 않게
    private func writeSaved(account: UUID?, generation: Int) {
        guard let saved, let account, generation == self.generation, account == signedInAccount else { return }
        let copy = SavedNow(sections: TaskBoard(now: response, doneToday: doneToday).sections(), savedAt: Date())
        // 서명하지 않은 빌드 등 App Group에 쓸 수 없으면 저장본 없이 둔다
        try? saved.save(copy, account: account)
    }

    /// 서버에서 읽은 목록 + 먼저 보여 주는 내 변경
    var board: TaskBoard {
        TaskBoard(now: response, doneToday: doneToday).applying(pending.mapValues(\.change))
    }

    /// Review · In Progress · To Do · Done Today
    var sections: TaskSections { board.sections() }

    func load() async {
        #if DEBUG
        if sampleMode { return }
        #endif
        loadSequence += 1
        let sequence = loadSequence
        sourceServicesTask?.cancel()
        sourceServicesTask = nil
        // 이 요청을 보낸 계정 (받은 목록은 이 계정의 저장본으로만 남긴다)
        let account = signedInAccount
        let generation = generation
        let reads = services.reads
        refresh.loadStarted()
        // 오늘 끝낸 할 일은 읽지 못해도 목록은 보여 준다 (전에 읽은 것을 둔다)
        async let doneRows = try? reads.allDoneToday(since: Calendar.current.startOfDay(for: Date()))
        do {
            let response = try await services.api.now()
            let done = await doneRows
            guard sequence == loadSequence else { return }
            self.response = response
            if let done {
                doneToday = done
                // 두 목록을 모두 새로 읽었으면 반영된 내 변경은 지운다
                pending = pending.filter { $0.value.settledBy.map { $0 > sequence } ?? true }
            }
            let actionIDs = response.now.map { $0.action.id } + response.confirmations.map(\.id) + doneToday.map(\.id)
            loadSourceServices(actionIDs: actionIDs, account: account, generation: generation, sequence: sequence)
            loadError = nil
            authFailed = false
            loaded = true
            refresh.loadSucceeded(at: Date())
            savedCopy = nil
            writeSaved(account: account, generation: generation)
            onLoaded?()
        } catch is CancellationError {
        } catch {
            guard sequence == loadSequence else { return }
            loadError = error.userMessage
            if case .server(_, .unauthorized, _)? = error as? APIError { authFailed = true } else { authFailed = false }
            loaded = true
            refresh.loadFailed(at: Date())
        }
    }

    /// Load source-service metadata outside the list request so rows appear promptly.
    /// Both request generation and signed-in account are checked before applying results.
    private func loadSourceServices(actionIDs: [UUID], account: UUID?, generation: Int, sequence: Int) {
        guard !actionIDs.isEmpty else {
            sourceServicesByAction = [:]
            sourceServicesFailed = false
            return
        }
        sourceServicesFailed = false
        let reads = services.reads
        sourceServicesTask = Task { [weak self] in
            do {
                let servicesByAction = try await reads.actionSourceServices(actionIDs: actionIDs)
                guard let self, !Task.isCancelled,
                      generation == self.generation, sequence == self.loadSequence, account == self.signedInAccount else { return }
                self.sourceServicesByAction = servicesByAction
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled,
                      generation == self.generation, sequence == self.loadSequence, account == self.signedInAccount else { return }
                self.sourceServicesFailed = true
            }
        }
    }

    /// 진행 상태 바꾸기 (`POST progress`): 곧바로 그 구역으로 옮겨 보여 준다 (Done은 Done Today 맨 위).
    /// In Progress · To Do · Done Today의 할 일만 (Review는 확인이 먼저). 지금 상태와 같으면 아무것도 하지 않는다.
    /// 돌려받은 작업은 서버에 쓰고 목록을 다시 읽을 때까지 (실패하면 제자리로 돌리고 `message`).
    @discardableResult
    func move(_ id: UUID, to state: WorkState) -> Task<Void, Never>? {
        guard let found = sections.find(id), let current = WorkState(found.group), current != state else { return nil }
        stateBeforeDone[id] = state == .done ? current : nil
        return write(id, TaskChange(found.action, to: state, at: Date())) { try await $0.setProgress(id, state: state) }
    }

    /// 지금 상태 (Review · 목록에 없음은 nil)
    func state(of id: UUID) -> WorkState? {
        sections.find(id).flatMap { WorkState($0.group) }
    }

    /// 상태 표시를 누르면 갈 상태: 열린 할 일은 Done, 끝낸 할 일은 끝내기 전 상태 (`WorkState.toggled`)
    func toggleTarget(_ id: UUID) -> WorkState? {
        guard let found = sections.find(id), let current = WorkState(found.group) else { return nil }
        return WorkState.toggled(from: current, found.action, remembered: stateBeforeDone[id])
    }

    /// 상태 표시를 누름
    @discardableResult
    func toggle(_ id: UUID) -> Task<Void, Never>? {
        guard let target = toggleTarget(id) else { return nil }
        return move(id, to: target)
    }

    /// 삭제 (`DELETE /actions/:id`, 서버는 취소로 두고 이력을 남긴다): 곧바로 목록에서 뺀다.
    /// In Progress · To Do · Done Today의 할 일만 (Review는 Dismiss). 되살릴 값과 쓰기 작업을 돌려준다 (실패하면 제자리로 돌리고 `message`).
    func delete(_ id: UUID) -> (undo: TaskUndo, write: Task<Void, Never>)? {
        guard let found = sections.find(id), found.group.isDeletable, let state = WorkState(found.group) else { return nil }
        let task = write(id, .deleting(found.action, at: Date())) { try await $0.deleteAction(id: id) }
        return (TaskUndo(found.action, was: state, change: .deleted), task)
    }

    /// 삭제 되돌리기 (`PATCH /actions/:id` status): 지우기 전 구역으로 곧바로 되살린다 (`TaskUndo.restoreEdit`)
    @discardableResult
    func restore(_ undo: TaskUndo) -> Task<Void, Never> {
        let id = undo.action.id
        let edit = undo.restoreEdit
        return write(id, undo.restoring(at: Date())) { try await $0.editAction(id: id, edit) }
    }

    private func write(
        _ id: UUID, _ change: TaskChange, _ call: @escaping @Sendable (APIClient) async throws -> ActionSummary
    ) -> Task<Void, Never> {
        changeCount += 1
        let token = changeCount
        pending[id] = Pending(change: change, token: token)
        #if DEBUG
        if sampleMode {
            commitSample()
            return Task {}
        }
        #endif
        let previous = writes[id]?.task
        let api = services.api
        let generation = generation
        let task = Task {
            await previous?.value
            // 로그아웃 · 계정 전환 뒤에는 전 계정의 남은 쓰기를 보내지 않고, 끝난 쓰기의 결과도 알리지 않는다
            guard generation == self.generation else { return }
            do {
                _ = try await call(api)
                // 이제부터 시작하는 불러오기가 반영되면 지운다
                if pending[id]?.token == token { pending[id]?.settledBy = loadSequence + 1 }
            } catch {
                if pending[id]?.token == token { pending[id] = nil }
                if generation == self.generation { message = error.userMessage }
            }
            guard generation == self.generation else { return }
            if writes[id]?.token == token { writes[id] = nil }
            await load()
        }
        writes[id] = (token, task)
        return task
    }

    /// 확인 요청 Confirm
    func confirm(_ id: UUID) async { await act(id) { try await $0.confirmAction(id: id) } }
    /// 확인 요청 Dismiss = 삭제 (서버가 취소로 둔다)
    func dismiss(_ id: UUID) async { await act(id) { try await $0.deleteAction(id: id) } }

    func setDue(_ id: UUID, _ due: LocalDate?) async {
        await act(id) { try await $0.editAction(id: id, ActionEdit(due: due.map(ActionEdit.DueChange.set) ?? .clear)) }
    }

    /// 직접 추가 (iPhone New Task): 원문 없이 제목 · 기한만 `POST /actions` 한 뒤 `/now`를 다시 불러 새 할 일이 보이게 한다.
    /// `already_tracked`(원문 없이는 나오지 않는다)도 추가된 것으로 본다. 실패하면 `addError`에 문구를 두고 false.
    func add(title: String, due: LocalDate?) async -> Bool {
        let title = LauncherAdd.capped(title)
        guard !title.isEmpty else { return false }
        #if DEBUG
        if sampleMode {
            try? await Task.sleep(for: .milliseconds(400))
            addSample(title: title, due: due)
            return true
        }
        #endif
        let generation = generation
        do {
            _ = try await services.api.createAction(title: title, dueDate: due)
        } catch {
            if generation == self.generation { addError = error.userMessage }
            return false
        }
        guard generation == self.generation else { return false }
        await load()
        return true
    }

    /// 주간 질문 (PRD 지표 5: 그림자 목록)
    func answerWeekly(_ answer: WeeklyCheckAnswer) async {
        guard let prompt = response?.weeklyCheck else { return }
        let generation = generation
        do {
            try await services.api.answerWeeklyCheck(weekStart: prompt.weekStart, answer: answer)
        } catch {
            if generation == self.generation { message = error.userMessage }
        }
        guard generation == self.generation else { return }
        await load()
    }

    /// AI에게 넘기기: 맥락 · 근거 문서를 받아 클립보드에 복사한다
    func handoff(_ id: UUID) async -> Bool {
        busy.insert(id)
        defer { busy.remove(id) }
        let generation = generation
        do {
            let response = try await services.api.handoff(id: id)
            // 그사이 로그아웃했으면 전 계정의 문서를 클립보드에 두지 않는다
            guard generation == self.generation else { return false }
            Clipboard.copy(response.markdown)
            return true
        } catch {
            if generation == self.generation { message = error.userMessage }
            return false
        }
    }

    /// 근거를 읽어 둔다 (이미 있으면 다시 읽지 않는다, `force`면 다시)
    @discardableResult
    func loadEvidence(_ id: UUID, force: Bool = false) async -> EvidenceDigest? {
        if !force, let cached = evidence[id] { return cached }
        #if DEBUG
        if sampleMode { return nil }
        #endif
        let generation = generation
        evidenceFailed.remove(id)
        evidenceLoadCounts[id, default: 0] += 1
        evidenceLoading.insert(id)
        defer {
            if generation == self.generation, let count = evidenceLoadCounts[id] {
                if count <= 1 {
                    evidenceLoadCounts.removeValue(forKey: id)
                    evidenceLoading.remove(id)
                } else {
                    evidenceLoadCounts[id] = count - 1
                }
            }
        }
        // 읽는 사이 로그아웃 · 계정 전환했으면 전 계정의 근거를 두지 않는다
        do {
            let detail = try await services.reads.actionDetail(id: id)
            guard generation == self.generation else { return nil }
            let digest = EvidenceDigest(evidence: detail.evidence, sources: detail.sources)
            evidence[id] = digest
            sourceServicesByAction[id] = digest.withoutReceipts.services
            return digest
        } catch is CancellationError {
            return nil
        } catch {
            if generation == self.generation { evidenceFailed.insert(id) }
            return nil
        }
    }

    private func act(_ id: UUID, _ call: (APIClient) async throws -> ActionSummary) async {
        busy.insert(id)
        defer { busy.remove(id) }
        let generation = generation
        do {
            _ = try await call(services.api)
        } catch {
            if generation == self.generation { message = error.userMessage }
        }
        guard generation == self.generation else { return }
        await load()
    }
}
