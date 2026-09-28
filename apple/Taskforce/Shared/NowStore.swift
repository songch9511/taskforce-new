import Foundation
import Observation
import TaskforceKit

/// 지금 할 일 + 확인 요청 + 오늘 끝낸 할 일. 순서 · 이유는 서버가 정하고, 무엇이 바뀌든 `/now`와 Done Today를 다시 불러온다.
/// 완료 · 착수 · 다시 열기는 서버 응답을 기다리지 않고 먼저 옮겨 보여 준다 (`TaskBoard.applying`).
/// iPhone 화면과 Mac 런처가 같은 것을 쓴다.
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
    /// 할 일마다 읽어 둔 근거 (Supabase 직접 읽기)
    private(set) var evidence: [UUID: EvidenceDigest] = [:]
    /// 근거를 읽지 못한 할 일 (계속 "읽는 중"으로 두지 않게)
    private(set) var evidenceFailed: Set<UUID> = []
    var message: String?
    /// 직접 추가 실패 문구. iPhone New Task 시트가 자기 알림으로 보여 준다 (시트가 떠 있는 동안 홈 화면 알림은 뜨지 않는다).
    var addError: String?

    /// 겹쳐 부른 불러오기 중 마지막 것만 반영한다 (늦게 온 옛 응답이 새 응답을 덮지 않게)
    private var loadSequence = 0

    private struct Pending {
        let change: TaskChange
        let token: Int
        /// 이 번호 이상의 불러오기가 반영되면 지운다 (쓰기가 끝난 뒤 시작한 불러오기). 쓰는 중이면 nil
        var settledBy: Int?
    }

    #if DEBUG
    /// 디자인 비교용 견본을 보여 주는 중 (`SampleData`)
    var sampleMode = false

    func applySample(_ response: NowResponse, doneToday: [ActionSummary], evidence: [UUID: EvidenceDigest]) {
        self.response = response
        self.doneToday = doneToday
        self.evidence = evidence
        loaded = true
    }

    /// 견본: 서버 없이 완료 · 착수 · 다시 열기를 바로 목록에 반영한다
    private func commitSample() {
        let board = self.board
        response = board.now
        doneToday = board.doneToday
        pending = [:]
    }
    #endif
    let services: AppServices

    init(services: AppServices) {
        self.services = services
    }

    /// 로그아웃 · 계정 전환 뒤 (Mac 런처는 이 저장소 하나를 계속 쓴다)
    func reset() {
        #if DEBUG
        if sampleMode { return }
        #endif
        loadSequence += 1
        response = nil
        doneToday = []
        loadError = nil
        loaded = false
        busy = []
        pending = [:]
        writes = [:]
        evidence = [:]
        evidenceFailed = []
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
        let reads = services.reads
        // 오늘 끝낸 할 일은 읽지 못해도 목록은 보여 준다 (전에 읽은 것을 둔다)
        async let doneRows = try? reads.doneToday(since: Calendar.current.startOfDay(for: Date()))
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
            loadError = nil
            loaded = true
        } catch is CancellationError {
        } catch {
            guard sequence == loadSequence else { return }
            loadError = error.userMessage
            loaded = true
        }
    }

    /// 완료 (PATCH status done): 곧바로 Done Today 맨 위로 옮겨 보여 준다. To Do · In Progress만.
    /// 돌려받은 작업은 서버에 쓰고 목록을 다시 읽을 때까지 (실패하면 제자리로 돌리고 `message`).
    @discardableResult
    func complete(_ id: UUID) -> Task<Void, Never>? {
        guard let found = sections.find(id), found.group == .toDo || found.group == .inProgress else { return nil }
        return write(id, .completed(found.action, at: Date())) { try await $0.editAction(id: id, ActionEdit(status: .done)) }
    }

    /// 다시 열기 (PATCH status open): Done Today에서 열린 목록으로. Done Today만.
    @discardableResult
    func reopen(_ id: UUID) -> Task<Void, Never>? {
        guard let found = sections.find(id), found.group == .doneToday else { return nil }
        return write(id, .reopened(found.action, at: Date())) { try await $0.editAction(id: id, ActionEdit(status: .open)) }
    }

    /// 착수 (POST start): 곧바로 In Progress로. To Do만.
    @discardableResult
    func start(_ id: UUID) -> Task<Void, Never>? {
        guard sections.find(id)?.group == .toDo else { return nil }
        return write(id, .started(at: Date())) { try await $0.startAction(id: id) }
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
        let task = Task {
            await previous?.value
            do {
                _ = try await call(api)
                // 이제부터 시작하는 불러오기가 반영되면 지운다
                if pending[id]?.token == token { pending[id]?.settledBy = loadSequence + 1 }
            } catch {
                if pending[id]?.token == token { pending[id] = nil }
                message = error.userMessage
            }
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
        do {
            _ = try await services.api.createAction(title: title, dueDate: due)
        } catch {
            addError = error.userMessage
            return false
        }
        await load()
        return true
    }

    /// 주간 질문 (PRD 지표 5: 그림자 목록)
    func answerWeekly(_ answer: WeeklyCheckAnswer) async {
        guard let prompt = response?.weeklyCheck else { return }
        do {
            try await services.api.answerWeeklyCheck(weekStart: prompt.weekStart, answer: answer)
        } catch {
            message = error.userMessage
        }
        await load()
    }

    /// AI에게 넘기기: 맥락 · 근거 문서를 받아 클립보드에 복사한다
    func handoff(_ id: UUID) async -> Bool {
        busy.insert(id)
        defer { busy.remove(id) }
        do {
            let response = try await services.api.handoff(id: id)
            Clipboard.copy(response.markdown)
            return true
        } catch {
            message = error.userMessage
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
        evidenceFailed.remove(id)
        do {
            let detail = try await services.reads.actionDetail(id: id)
            let digest = EvidenceDigest(evidence: detail.evidence, sources: detail.sources)
            evidence[id] = digest
            return digest
        } catch is CancellationError {
            return nil
        } catch {
            evidenceFailed.insert(id)
            return nil
        }
    }

    private func act(_ id: UUID, _ call: (APIClient) async throws -> ActionSummary) async {
        busy.insert(id)
        defer { busy.remove(id) }
        do {
            _ = try await call(services.api)
        } catch {
            message = error.userMessage
        }
        await load()
    }
}
