import Foundation
import Observation

/// 읽기가 왜 안 됐나: 연결이 없다(오프라인) · 그 밖(실패). 취소는 아무 상태도 바꾸지 않는다 (nil)
public enum ReadFailure: Sendable, Equatable {
    case offline, failed

    /// - online: 연결 경로 (`Connectivity`). 끊겨 있으면 어떤 오류도 오프라인으로 본다
    public static func from(_ error: Error, online: Bool) -> ReadFailure? {
        if error is CancellationError { return nil }
        if let urlError = error as? URLError {
            if urlError.code == .cancelled { return nil }
            if Self.offlineCodes.contains(urlError.code) { return .offline }
        }
        if let api = error as? APIError, case .transport = api, !online { return .offline }
        return online ? .failed : .offline
    }

    /// 화면에 보일 한 줄 (영어 틀)
    public static func userMessage(_ error: Error) -> String {
        (error as? APIError)?.userMessage ?? "Something went wrong. Try again in a moment."
    }

    private static let offlineCodes: Set<URLError.Code> = [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff]
}

/// 기억 쓰기 한 번의 결과. 성공은 서버가 200으로 답한 뒤에만 말한다 (낙관적 표시 없음, 409를 성공으로 올리지 않는다)
public enum MemoryWriteResult: Equatable, Sendable {
    /// 200: 서버가 돌려준 지금 상태의 행 (확인 · 정정 · 옮기기는 새 행)
    case applied(MemoryItem)
    /// 잊기 200: 이 항목은 지금 기억이 아니다 (누가 잊었든 같다). 다른 기기가 옮겨서 잊힌 것이면 `refreshed`
    case forgotten
    /// 409 `conflict` (또는 잊기 200이지만 다른 기기가 옮긴 후속 행이 있음): 내 요청이 적용됐는지 알 수 없다 → 지금 상태를 다시 읽어 보였다
    case refreshed
    /// 정책 보류 · 기능 꺼짐 · 없는 항목: 이 동작은 줄 수 없다
    case unavailable
    /// 전송 실패 · 서버 오류 (아무것도 바뀌지 않은 것으로 보이고 다시 할 수 있다)
    case failed
    /// 보내지 않음 (이미 보내는 중 · 계정이 바뀜 · 항목을 모름)
    case ignored
}

/// Settings › Account › Remembered와 대화의 RememberedNote가 함께 쓰는 기억 저장소.
/// - 읽기는 RLS(`memory_items`, 지금 기억 = `superseded_at is null and revoked_at is null`). 범위 사이 우선은 흉내 내지 않는다
/// - 쓰기는 서버 API만. version은 앱이 읽은 행의 것을 그대로 보낸다. 항목마다 한 번에 하나
/// - 409 `conflict`는 "내 요청이 이미 적용됨"과 "다른 기기 · 다른 요청이 먼저 바꿈"을 구분하지 못한다: 성공으로 올리지 않고
///   지금 상태를 다시 읽어 보인 채 `feedback = .conflict`로 둔다 (사용자가 지금 값을 보고 다시 할지 정한다)
/// - 계정 경계: `AccountScope`에 붙어 계정이 떠나면 목록 · 캐시 · 안내를 비우고 늦은 응답을 버린다 (화면이 떠 있는지와 무관)
/// - 읽은 글은 사용자 글이다: 메모리에만 두고 디스크 · 로그에 남기지 않는다
@MainActor
@Observable
public final class MemoryStore {
    public enum Load: Equatable, Sendable {
        case idle, loading, loaded, offline, failed
    }

    /// 한 항목의 쓰기 안내 (화면이 이것만 보고 말한다)
    public enum Feedback: Equatable, Sendable {
        /// 다른 곳에서 바뀌었다 (지금 상태로 다시 읽었다): "This changed somewhere else. It's been refreshed."
        case conflict
        /// 보내지 못했다 (한 줄)
        case failed(String)
        /// 글을 고쳐 써야 저장된다 (Slack 원문 후보를 글자 그대로 저장하려 함)
        case rewriteToSave
        /// 없는 항목 (지워졌거나 남의 것)
        case gone
    }

    /// 노트 하나가 무엇을 보일까
    public enum NoteState: Equatable, Sendable {
        case loading
        case current(MemoryItem)
        /// 잊었거나 대체되었거나 읽을 수 없다: 이유를 지어내지 않는다
        case notRemembered
    }

    /// 지금 기억, 새 것이 위
    public private(set) var items: [MemoryItem] = []
    public private(set) var contexts: [UUID: WorkContext] = [:]
    public private(set) var load: Load = .idle
    /// gate(`MEMORY_ENABLED`)가 꺼져 쓰기가 막혀 있다 (읽기는 된다)
    public private(set) var writesUnavailable = false
    /// 서버 정책 보류로 감춘 동작 (이번 실행 동안, 행 id별)
    public private(set) var hidingConfirm: Set<UUID> = []
    public private(set) var hidingScope: Set<UUID> = []
    public private(set) var busy: Set<UUID> = []
    public private(set) var feedback: [UUID: Feedback] = [:]
    /// 노트가 가리키는 행 (정정 · 잊음으로 지금 기억이 아닌 것도)
    public private(set) var referenced: [UUID: MemoryItem] = [:]
    private var missing: Set<UUID> = []
    /// 이번 실행에서 서버가 대체한 행 → 새 행 (정정 · 확인 · 옮기기의 200)
    private var successors: [UUID: UUID] = [:]
    private var sourceLookups: [UUID: MemorySourceRules.Lookup] = [:]
    public private(set) var isOnline = true

    @ObservationIgnored private let gateway: any ChatGateway
    @ObservationIgnored private let scope: AccountScope
    @ObservationIgnored private var listSequence = 0

    public init(gateway: any ChatGateway, scope: AccountScope) {
        self.gateway = gateway
        self.scope = scope
        scope.onLeft { [weak self] in self?.reset() }
    }

    /// 계정이 떠남: 모두 비운다 (읽는 중인 요청의 늦은 결과는 `scope.isCurrent`가 버린다)
    public func reset() {
        listSequence += 1
        items = []
        contexts = [:]
        load = .idle
        writesUnavailable = false
        hidingConfirm = []
        hidingScope = []
        busy = []
        feedback = [:]
        referenced = [:]
        missing = []
        successors = [:]
        sourceLookups = [:]
    }

    public func pathChanged(online: Bool) {
        isOnline = online
    }

    // MARK: 읽기

    /// 목록 읽기 (Settings를 열 때 · Try again · 쓰기 뒤). 받은 목록이 있으면 실패해도 그대로 둔다
    public func loadList() async {
        guard let token = scope.token else { return }
        listSequence += 1
        let sequence = listSequence
        if items.isEmpty { load = .loading }
        do {
            async let current = gateway.currentMemoryItems()
            async let named = gateway.workContexts()
            let (rows, projects) = try await (current, named)
            guard scope.isCurrent(token), sequence == listSequence else { return }
            items = Self.sorted(rows.filter(\.isCurrent))
            contexts = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            load = .loaded
        } catch {
            guard scope.isCurrent(token), sequence == listSequence, let failure = ReadFailure.from(error, online: isOnline) else { return }
            // 받은 목록이 있으면 그대로 두고, 없을 때만 실패 화면
            if items.isEmpty || load != .loaded { load = failure == .offline ? .offline : .failed }
        }
    }

    /// 대화 노트가 가리키는 행을 읽는다 (잊은 · 정정된 행도). 정정으로 대체된 행은 후속 행을 세 번까지 따라간다
    public func loadReferenced(ids: [UUID]) async {
        guard let token = scope.token, !ids.isEmpty else { return }
        var pending = Array(Set(ids))
        var hops = 0
        do {
            while !pending.isEmpty, hops < 4 {
                let rows = try await gateway.memoryItems(ids: pending)
                guard scope.isCurrent(token) else { return }
                let found = Set(rows.map(\.id))
                for row in rows { referenced[row.id] = row }
                missing.formUnion(pending.filter { !found.contains($0) })
                // 대체된 행의 후속 행을 따라간다
                pending = rows.compactMap { $0.supersededAt != nil ? $0.supersededBy : nil }.filter { referenced[$0] == nil && !missing.contains($0) }
                hops += 1
            }
            // 범위 이름은 노트의 둘째 줄에 쓴다 (목록을 읽지 않은 채 대화만 열었을 때)
            if contexts.isEmpty { try await readContextNames(token: token) }
            // 확인 전 추정은 출처 원문 상태를 읽어 둔다: 접근 상실 · 글 지워짐 · Slack 유래면 Confirm을 미리 감춘다
            for id in ids.map(resolve) {
                if let row = item(id), row.isUnconfirmedInference, row.sourceRef?.sourceID != nil, sourceLookups[row.id] == nil {
                    await loadSource(for: row)
                }
            }
        } catch {
            // 읽지 못한 노트는 읽는 중으로 둔다 (다음에 다시 읽는다). 아무것도 지어내지 않는다
        }
    }

    private func readContextNames(token: AccountScope.Token) async throws {
        let projects = try await gateway.workContexts()
        guard scope.isCurrent(token) else { return }
        contexts = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    static func sorted(_ rows: [MemoryItem]) -> [MemoryItem] {
        rows.sorted { ($0.observedAt, $0.id.uuidString) > ($1.observedAt, $1.id.uuidString) }
    }

    // MARK: 조회

    /// 가장 최근에 읽은 그 id의 행 (목록 → 노트 캐시)
    public func item(_ id: UUID) -> MemoryItem? {
        items.first { $0.id == id } ?? referenced[id]
    }

    /// 서버가 대체한 행을 따라가 지금 보이는 id (정정 · 확인 · 옮기기 뒤 상세가 새 행을 따라간다)
    public func resolve(_ id: UUID) -> UUID {
        var current = id
        var seen: Set<UUID> = [id]
        while let next = successors[current], seen.insert(next).inserted { current = next }
        return current
    }

    /// 대화 노트의 상태: 가리키는 행(또는 후속 행)이 지금 기억이면 그것, 아니면 지금 기억이 아니다
    public func noteState(for id: UUID) -> NoteState {
        var current = resolve(id)
        var seen: Set<UUID> = []
        while seen.insert(current).inserted {
            guard let row = item(current) else { return missing.contains(current) ? .notRemembered : .loading }
            if row.isCurrent { return .current(row) }
            // 범위를 옮겨 잊힌 행이면 옮긴 후속 행 (다른 기기가 옮긴 것도): 그 사실은 아직 기억이다
            if row.supersededAt == nil, let moved = items.first(where: { $0.movedFrom == row.id }) {
                current = moved.id
                continue
            }
            // 대체된 행이면 후속 행, 잊은 행이면 끝
            guard row.supersededAt != nil, let next = row.supersededBy else { return .notRemembered }
            current = next
        }
        return .notRemembered
    }

    public func isBusy(_ id: UUID) -> Bool { busy.contains(resolve(id)) }

    public func feedback(for id: UUID) -> Feedback? { feedback[resolve(id)] }

    public func clearFeedback(for id: UUID) {
        feedback[resolve(id)] = nil
    }

    /// Confirm을 줄 수 있나: 지금 기억인 추정이고, 서버가 보류하지 않았고, 출처 원문이 접근 상실 · 글 지워짐 · Slack 유래가 아니다
    public func canConfirm(_ item: MemoryItem) -> Bool {
        !writesUnavailable && !hidingConfirm.contains(item.id) && MemoryText.canConfirm(item)
            && MemorySourceRules.allowsConfirm(item: item, lookup: sourceLookups[item.id])
    }

    public func canChangeScope(_ item: MemoryItem) -> Bool {
        !writesUnavailable && !hidingScope.contains(item.id) && MemoryText.canChangeScope(item)
    }

    // MARK: 출처 (상세)

    public func sourceDisplay(for item: MemoryItem) -> MemorySourceDisplay {
        MemorySourceRules.display(item: item, lookup: sourceLookups[item.id] ?? (needsLookup(item) ? .loading : .loaded(message: nil, source: nil)))
    }

    private func needsLookup(_ item: MemoryItem) -> Bool {
        item.sourceRef?.messageID != nil || item.sourceRef?.sourceID != nil
    }

    /// 출처 원문 · 메시지를 읽는다 (상세를 열 때 · Try again). 지워졌으면 없다고 읽힌다 (옛 인용을 다시 보이지 않는다)
    public func loadSource(for item: MemoryItem) async {
        guard let token = scope.token, needsLookup(item), let ref = item.sourceRef else { return }
        if sourceLookups[item.id] == nil || sourceLookups[item.id] == .failed { sourceLookups[item.id] = .loading }
        do {
            var message: ChatMessage?
            var source: MemorySource?
            if let id = ref.messageID { message = try await gateway.message(id: id) }
            if let id = ref.sourceID { source = try await gateway.memorySource(id: id) }
            guard scope.isCurrent(token) else { return }
            sourceLookups[item.id] = .loaded(message: message, source: source)
        } catch {
            guard scope.isCurrent(token), ReadFailure.from(error, online: isOnline) != nil else { return }
            sourceLookups[item.id] = .failed
        }
    }

    // MARK: 쓰기

    /// 추정 확인 (사용자의 명시적 요청뿐). 200이면 새 explicit 행
    @discardableResult
    public func confirm(_ id: UUID) async -> MemoryWriteResult {
        await write(id, kind: .confirm) { gateway, row in try await gateway.confirmMemory(id: row.id, expectedVersion: row.version) }
    }

    /// 글 정정. 200이면 새 explicit 행 (범위는 그대로)
    @discardableResult
    public func edit(_ id: UUID, statement: String) async -> MemoryWriteResult {
        guard let text = MemoryText.editedStatement(statement) else { return .ignored }
        return await write(id, kind: .edit) { gateway, row in
            try await gateway.editMemory(id: row.id, edit: MemoryEdit(expectedVersion: row.version, statement: text))
        }
    }

    /// 잊기. 200은 "이 항목은 지금 기억이 아니다"일 뿐이다 (누가 잊었는지는 모른다)
    @discardableResult
    public func forget(_ id: UUID) async -> MemoryWriteResult {
        await write(id, kind: .forget) { gateway, row in try await gateway.forgetMemory(id: row.id, expectedVersion: row.version) }
    }

    /// 범위 옮기기 (explicit만, 전체 ↔ 내 active 프로젝트). 200이면 새 행
    @discardableResult
    public func move(_ id: UUID, to target: MemoryTarget) async -> MemoryWriteResult {
        await write(id, kind: .move) { gateway, row in try await gateway.moveMemory(id: row.id, expectedVersion: row.version, to: target) }
    }

    private enum WriteKind { case confirm, edit, forget, move }

    private func write(
        _ requestedID: UUID, kind: WriteKind, _ send: (any ChatGateway, MemoryItem) async throws -> MemoryItem
    ) async -> MemoryWriteResult {
        let id = resolve(requestedID)
        guard let token = scope.token, !busy.contains(id), !writesUnavailable, let row = item(id), row.isCurrent else { return .ignored }
        busy.insert(id)
        feedback[id] = nil
        defer { busy.remove(id) }
        do {
            let response = try await send(gateway, row)
            guard scope.isCurrent(token) else { return .ignored }
            return await applied(response, replacing: row, kind: kind)
        } catch let error as APIError {
            guard scope.isCurrent(token) else { return .ignored }
            return await failed(error, row: row, kind: kind)
        } catch {
            guard scope.isCurrent(token), ReadFailure.from(error, online: isOnline) != nil else { return .ignored }
            feedback[id] = .failed(ReadFailure.userMessage(error))
            return .failed
        }
    }

    private func applied(_ response: MemoryItem, replacing row: MemoryItem, kind: WriteKind) async -> MemoryWriteResult {
        if kind == .forget {
            // 같은 요청을 다시 보내도 200이다. 다른 기기가 옮겨서 잊힌 것이면 옮긴 후속 행이 지금 기억으로 남아 있다:
            // 그때는 잊었다고 말하지 않고 지금 상태를 다시 읽어 보인다
            referenced[row.id] = response
            await loadList()
            if items.contains(where: { $0.movedFrom == row.id }) {
                feedback[row.id] = .conflict
                return .refreshed
            }
            items.removeAll { $0.id == row.id }
            return .forgotten
        }
        // 확인 · 정정 · 옮기기: 응답의 새 행이 지금 상태다
        successors[row.id] = response.id
        referenced[response.id] = response
        items.removeAll { $0.id == row.id }
        if !items.contains(where: { $0.id == response.id }) { items = Self.sorted(items + [response]) }
        // 서버 상태와 맞춘다 (실패해도 방금 받은 행은 그대로)
        Task { await loadList() }
        return .applied(response)
    }

    private func failed(_ error: APIError, row: MemoryItem, kind: WriteKind) async -> MemoryWriteResult {
        if error.isFeatureOff {
            writesUnavailable = true
            return .unavailable
        }
        if error.isConfirmUnavailable {
            if kind == .edit {
                // 글자 그대로는 저장할 수 없다: 글을 고쳐 써야 한다 (Edit는 막히지 않는다)
                feedback[row.id] = .rewriteToSave
            } else {
                // 이 항목의 Confirm을 감춘 채 지금 상태를 다시 읽어 보인다 (성공 표시 0, 실패로 꾸미지 않는다)
                hidingConfirm.insert(row.id)
                await refresh(row.id)
                await loadSource(for: row)
            }
            return .unavailable
        }
        if error.isScopeUnavailable {
            hidingScope.insert(row.id)
            return .unavailable
        }
        if error.isMissingTarget {
            feedback[row.id] = .gone
            await loadList()
            return .unavailable
        }
        if error.isConflict {
            // 성공으로 올리지 않는다: 다른 기기의 같은 모양 후속 행과 구별할 근거가 없다. 지금 상태를 읽어 보인다
            feedback[row.id] = .conflict
            await refresh(row.id)
            return .refreshed
        }
        feedback[row.id] = .failed(error.userMessage)
        return .failed
    }

    /// 충돌 뒤: 목록과 그 행을 다시 읽는다 (지금 기억이 아니게 됐으면 그렇게 보인다)
    private func refresh(_ id: UUID) async {
        await loadList()
        await loadReferenced(ids: [id])
    }
}
