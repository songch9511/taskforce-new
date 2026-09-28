import Foundation
import Observation
import TaskforceKit

/// 지금 할 일 + 확인 요청. 순서 · 이유는 서버가 정하고, 무엇이 바뀌든 `/now`를 다시 불러온다.
/// iPhone 화면과 Mac 런처가 같은 것을 쓴다.
@MainActor
@Observable
final class NowStore {
    private(set) var response: NowResponse?
    private(set) var loadError: String?
    private(set) var loaded = false
    /// 요청 중인 할 일 (버튼을 잠근다)
    private(set) var busy: Set<UUID> = []
    /// 체크를 누른 할 일: 서버 응답을 기다리지 않고 Done으로 보여 준다
    private(set) var completed: Set<UUID> = []
    /// 할 일마다 읽어 둔 근거 (Supabase 직접 읽기)
    private(set) var evidence: [UUID: EvidenceDigest] = [:]
    /// 근거를 읽지 못한 할 일 (계속 "읽는 중"으로 두지 않게)
    private(set) var evidenceFailed: Set<UUID> = []
    var message: String?
    /// 직접 추가 실패 문구. iPhone New Task 시트가 자기 알림으로 보여 준다 (시트가 떠 있는 동안 홈 화면 알림은 뜨지 않는다).
    var addError: String?

    /// 겹쳐 부른 불러오기 중 마지막 것만 반영한다 (늦게 온 옛 응답이 새 응답을 덮지 않게)
    private var loadSequence = 0
    #if DEBUG
    /// 디자인 비교용 견본을 보여 주는 중 (`SampleData`)
    var sampleMode = false

    func applySample(_ response: NowResponse, evidence: [UUID: EvidenceDigest]) {
        self.response = response
        self.evidence = evidence
        loaded = true
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
        loadError = nil
        loaded = false
        busy = []
        completed = []
        evidence = [:]
        evidenceFailed = []
    }

    var confirmations: [ActionSummary] { response?.confirmations ?? [] }
    var tasks: [RankedAction] { response?.now ?? [] }

    func load() async {
        #if DEBUG
        if sampleMode { return }
        #endif
        loadSequence += 1
        let sequence = loadSequence
        do {
            let response = try await services.api.now()
            guard sequence == loadSequence else { return }
            self.response = response
            // 목록에서 사라진 할 일의 Done 표시는 지운다
            let visible = Set(response.now.map(\.id))
            completed.formIntersection(visible)
            loadError = nil
            loaded = true
        } catch is CancellationError {
        } catch {
            guard sequence == loadSequence else { return }
            loadError = error.userMessage
            loaded = true
        }
    }

    /// 체크 = 완료 (PATCH status done). 먼저 Done으로 보여 주고, `lingering`이면 잠시 Done을 보인 뒤 `/now`를 다시 불러 목록에서 뺀다.
    func complete(_ id: UUID, lingering: Bool = true) async {
        guard !completed.contains(id), !busy.contains(id) else { return }
        completed.insert(id)
        busy.insert(id)
        do {
            _ = try await services.api.editAction(id: id, ActionEdit(status: .done))
            busy.remove(id)
            if lingering { try? await Task.sleep(for: .milliseconds(700)) }
        } catch {
            busy.remove(id)
            completed.remove(id)
            message = error.userMessage
        }
        await load()
    }

    /// Done을 다시 누르면 되돌린다 (목록에서 빠지기 전까지)
    func reopen(_ id: UUID) async {
        guard completed.contains(id), !busy.contains(id) else { return }
        await act(id) { try await $0.editAction(id: id, ActionEdit(status: .open)) }
        completed.remove(id)
    }

    /// 확인 요청 Confirm
    func confirm(_ id: UUID) async { await act(id) { try await $0.confirmAction(id: id) } }
    /// 확인 요청 Dismiss = 삭제 (서버가 취소로 둔다)
    func dismiss(_ id: UUID) async { await act(id) { try await $0.deleteAction(id: id) } }
    func start(_ id: UUID) async { await act(id) { try await $0.startAction(id: id) } }

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
