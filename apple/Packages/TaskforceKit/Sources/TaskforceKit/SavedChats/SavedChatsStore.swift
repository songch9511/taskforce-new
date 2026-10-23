import Foundation
import Observation
import Supabase

/// 지운 결과 (하나)
public enum SavedChatDeleteOutcome: Equatable, Sendable {
    case deleted
    case failed(AgentQuestionFailure)
}

/// Sessions 절의 모양 (순수 값)
public struct SavedChatsSection: Equatable, Sendable {
    public var state: SavedChatsStore.SectionState
    public var fold: SavedChatRules.Fold
    /// 펴져 있고 더 읽을 쪽이 있으면 끝에 "Show earlier"
    public var showsEarlier: Bool

    public init(state: SavedChatsStore.SectionState, fold: SavedChatRules.Fold, showsEarlier: Bool) {
        self.state = state
        self.fold = fold
        self.showsEarlier = showsEarlier
    }
}

/// Sessions의 Saved chats 절 · Settings › Account의 모두 지우기가 같이 읽는 저장소 (OA D3v-m, 계약 27장).
/// - 읽기: Supabase 직접(RLS, `SavedChatsLive`), 20개씩 (`range`). 열 때마다 처음 쪽부터 다시 읽는다 (다른 기기에서 지우거나 늘었을 수 있다)
/// - 지우기: 서버 API로만 (`DELETE /api/v2/claude-app-chats/{id}` — 늘 열려 있다 · 새 `DELETE /api/v2/claude-app-chats`). **바로 지운다: 되돌리기(Undo)가 없다** (서버가 바로 지우고 묘비로 같은 말의 재저장도 막는다)
/// - 서버 gate가 꺼져 읽기가 비면 절은 그냥 없다 (빈 상태 글 없음). 읽는 중 · 읽기 실패만 절 안의 한 줄이다
/// - 계정이 떠나면 비우고(`AccountScope`), 그 사이 시작한 읽기 · 지우기의 늦은 답은 쓰지 않는다
/// - 로그는 코드뿐이다 (제목 · 글 · id · 주소 0)
@MainActor
@Observable
public final class SavedChatsStore {
    public enum Phase: Equatable, Sendable { case idle, loading, ready, failed }

    /// Sessions의 절이 무엇을 보이나
    public enum SectionState: Equatable, Sendable {
        /// 절이 없다 (읽었는데 비었다: 서버 gate가 꺼졌거나 저장된 대화가 없다)
        case absent
        /// 처음 읽는 중: "Checking…"
        case checking
        /// 읽지 못했다: "Couldn't load saved chats" + Try again
        case failed
        case rows
    }

    public enum DeleteAllState: Equatable, Sendable {
        case idle
        /// 지우는 중: 같은 요청은 한 번만 간다
        case deleting
        /// 지우지 못했다: "Couldn't delete" + 승인된 이유 줄 + Try again. 서버의 모두 지우기는 원자적이라 일부만 지워지지 않는다 (실패 = 아무것도 지우지 못했다)
        case failed(AgentQuestionFailure)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var rows: [SavedChatRow] = []
    /// 더 읽을 쪽이 있을 수 있다 (가득 찬 쪽을 받았다)
    public private(set) var hasMore = false
    public private(set) var loadingMore = false
    public private(set) var deleteAllState: DeleteAllState = .idle

    @ObservationIgnored private let scope: AccountScope
    @ObservationIgnored private let readPage: SavedChatsLive.ReadPage
    @ObservationIgnored private let readMessages: SavedChatsLive.ReadMessages
    @ObservationIgnored private let deleteChat: @Sendable (UUID) async throws -> Void
    @ObservationIgnored private let deleteAll: @Sendable () async throws -> Void
    @ObservationIgnored private let pageSize: Int
    @ObservationIgnored private let log: @Sendable (_ event: String, _ code: String) -> Void
    /// 계정이 떠날 때마다 오른다: 그 전에 시작한 일의 늦은 답은 쓰지 않는다
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshSerial = 0
    /// 서버 목록에서 다음 쪽이 시작하는 자리 (지운 줄은 뺀다)
    @ObservationIgnored private var nextOffset = 0
    @ObservationIgnored private var deletes: [UUID: Task<SavedChatDeleteOutcome, Never>] = [:]

    public init(
        scope: AccountScope, readPage: @escaping SavedChatsLive.ReadPage, readMessages: @escaping SavedChatsLive.ReadMessages,
        deleteChat: @escaping @Sendable (UUID) async throws -> Void, deleteAll: @escaping @Sendable () async throws -> Void,
        pageSize: Int = SavedChatRules.pageSize, log: @escaping @Sendable (_ event: String, _ code: String) -> Void = { _, _ in }
    ) {
        self.scope = scope
        self.readPage = readPage
        self.readMessages = readMessages
        self.deleteChat = deleteChat
        self.deleteAll = deleteAll
        self.pageSize = max(1, pageSize)
        self.log = log
        scope.onLeft { [weak self] in self?.reset() }
    }

    /// 저장된 대화가 하나라도 보인다 (Settings의 모두 지우기 줄이 보일지)
    public var hasChats: Bool { !rows.isEmpty }

    public var sectionState: SectionState {
        switch phase {
        case .idle, .loading: rows.isEmpty ? .checking : .rows
        case .failed: rows.isEmpty ? .failed : .rows
        case .ready: rows.isEmpty ? .absent : .rows
        }
    }

    /// Sessions 절이 그리는 것: 상태 · 접힌 줄 · 끝의 Show earlier
    public func section(expanded: Bool) -> SavedChatsSection {
        let fold = SavedChatRules.fold(rows, expanded: expanded)
        return SavedChatsSection(state: sectionState, fold: fold, showsEarlier: fold.expanded && hasMore)
    }

    /// 계정이 떠난다: 비우고, 돌던 읽기 · 지우기의 늦은 답을 막는다
    public func reset() {
        generation += 1
        refreshTask?.cancel()
        refreshTask = nil
        deletes = [:]
        phase = .idle
        rows = []
        hasMore = false
        loadingMore = false
        nextOffset = 0
        deleteAllState = .idle
    }

    // MARK: 읽기

    /// 처음 쪽부터 다시 읽는다. 이미 읽는 중이면 그 읽기를 기다린다 (겹쳐 읽지 않는다). 이미 보이는 줄이 있으면 읽기 실패로 지우지 않는다
    public func refresh() async {
        if let refreshTask {
            await refreshTask.value
            return
        }
        refreshSerial += 1
        let serial = refreshSerial
        let task = Task { await self.readFirstPage() }
        refreshTask = task
        await task.value
        if refreshSerial == serial { refreshTask = nil }
    }

    private func readFirstPage() async {
        let started = generation
        if rows.isEmpty { phase = .loading }
        do {
            let page = try await readPage(0, pageSize)
            guard started == generation else { return }
            rows = Self.unique(page, after: [])
            nextOffset = page.count
            hasMore = page.count >= pageSize
            phase = .ready
        } catch {
            guard started == generation, !(error is CancellationError) else { return }
            log("saved_chats_load_failed", Self.code(error))
            phase = .failed
        }
    }

    /// Try again: 곧바로 다시 읽는다 (읽는 중 상태로)
    @discardableResult
    public func retry() -> Task<Void, Never> {
        Task { await refresh() }
    }

    /// Sessions 패널이 열렸다: 처음 쪽부터 다시 읽는다
    public func panelOpened() {
        Task { await refresh() }
    }

    /// 끝의 Show earlier: 다음 20개. 더 없으면 읽지 않는다
    public func loadMore() async {
        guard hasMore, !loadingMore, !rows.isEmpty, phase != .loading else { return }
        let started = generation
        loadingMore = true
        do {
            let page = try await readPage(nextOffset, pageSize)
            guard started == generation else { return }
            rows += Self.unique(page, after: rows)
            nextOffset += page.count
            hasMore = page.count >= pageSize
        } catch {
            guard started == generation, !(error is CancellationError) else { return }
            log("saved_chats_more_failed", Self.code(error))
        }
        if started == generation { loadingMore = false }
    }

    /// 읽는 사이 새 대화가 생겨 다음 쪽의 앞이 앞 쪽의 끝과 겹칠 수 있다: 이미 있는 줄은 더하지 않는다
    private static func unique(_ page: [SavedChatRow], after existing: [SavedChatRow]) -> [SavedChatRow] {
        var seen = Set(existing.map(\.id))
        return page.filter { seen.insert($0.id).inserted }
    }

    // MARK: 하나 지우기

    /// 서버에 바로 보낸다 (되돌리기 시간 없음). 이미 없으면(404) 지운 것으로 본다: 다른 기기에서 지운 대화도 줄이 빠진다.
    /// 잠금 경합(409 `busy_retry`)은 한 번 조용히 다시 보낸다. 같은 대화를 두 번 눌러도 한 번만 보낸다
    public func delete(_ id: UUID) async -> SavedChatDeleteOutcome {
        if let running = deletes[id] { return await running.value }
        let task = Task { await self.sendDelete(id) }
        deletes[id] = task
        return await task.value
    }

    private func sendDelete(_ id: UUID) async -> SavedChatDeleteOutcome {
        defer { deletes[id] = nil }
        let started = generation
        var retried = false
        while true {
            do {
                try await deleteChat(id)
                removeLocally(id, ifStill: started)
                return .deleted
            } catch {
                switch Self.classifyDelete(error) {
                case .alreadyGone:
                    removeLocally(id, ifStill: started)
                    return .deleted
                case .retry where !retried:
                    retried = true
                case .retry:
                    log("saved_chat_delete_failed", Self.code(error))
                    return .failed(.generic)
                case .failed(let reason):
                    log("saved_chat_delete_failed", Self.code(error))
                    return .failed(reason)
                }
            }
        }
    }

    private func removeLocally(_ id: UUID, ifStill started: Int) {
        guard started == generation, rows.contains(where: { $0.id == id }) else { return }
        rows.removeAll { $0.id == id }
        nextOffset = max(0, nextOffset - 1)
    }

    // MARK: 모두 지우기

    /// `DELETE /api/v2/claude-app-chats?all=true`를 한 번 보낸다 (같은 요청은 한 번만). 서버는 **원자적**이다: 성공(200 `{deleted: n}`)이면 전부 지워졌고, 실패(401 · 429 · 409 `busy_retry` · 500)면 아무것도 지워지지 않았다.
    /// 그래서 일부만 지워진 상태는 없다: 실패는 "Couldn't delete" + 승인된 이유 줄 + Try again이다 (409도 조용히 다시 보내지 않고 Try again이 한다). 지운 수는 쓰지 않는다 (다른 기기가 저장한 것도 지워 목록과 다를 수 있다).
    /// 답을 잃은 실패(오프라인 등)는 이미 지워졌을 수 있어 목록을 다시 읽어 맞춘다: 하나도 남지 않았으면 성공이다. 답의 모양에는 기대지 않는다 (2xx면 성공)
    public func deleteAllChats() async {
        guard deleteAllState != .deleting else { return }
        deleteAllState = .deleting
        let started = generation
        var failure: AgentQuestionFailure?
        do {
            try await deleteAll()
        } catch {
            log("saved_chats_delete_all_failed", Self.code(error))
            failure = Self.deleteAllFailure(error)
        }
        guard started == generation else { return }
        guard let failure else {
            rows = []
            hasMore = false
            nextOffset = 0
            phase = .ready
            deleteAllState = .idle
            return
        }
        // 실패했다: 그래도 응답만 잃었을 수 있다 (서버는 지웠다). 목록을 다시 읽어 맞춘다: 비어 있으면 성공이고 남아 있으면 실패다
        await refresh()
        guard started == generation else { return }
        deleteAllState = phase == .ready && rows.isEmpty ? .idle : .failed(failure)
    }

    /// 실패 줄을 거둔다 (Settings를 떠나거나 새로 시도할 때)
    public func dismissDeleteAllFailure() {
        if case .failed = deleteAllState { deleteAllState = .idle }
    }

    // MARK: 보기

    /// 저장된 대화 하나를 읽는 보기. 지우기는 이 저장소가 한다 (줄이 빠진다)
    public func makeDetail(
        chat: SavedChatRow, pageSize: Int = 40, maxMessages: Int = 1000, onGone: @escaping @MainActor () -> Void = {}, onDeleted: @escaping @MainActor () -> Void = {}
    ) -> SavedChatDetailModel {
        let readMessages = readMessages
        let id = chat.id
        return SavedChatDetailModel(
            chat: chat, pageSize: pageSize, maxMessages: maxMessages, read: { offset, limit in try await readMessages(id, offset, limit) },
            delete: { [weak self] in await self?.delete(id) ?? .failed(.generic) }, onGone: onGone, onDeleted: onDeleted, log: log
        )
    }

    // MARK: 오류를 코드로

    enum Classification: Equatable {
        case alreadyGone
        case retry
        case failed(AgentQuestionFailure)
    }

    /// 하나 지우기: 404는 이미 없다 · 409 `busy_retry`는 다시 · 네트워크가 안 되면 오프라인 · 그 밖은 일반 이유
    static func classifyDelete(_ error: Error) -> Classification {
        if let api = error as? APIError, case .server(let status, let code, _) = api, status == 404 || code == .notFound { return .alreadyGone }
        return classify(error)
    }

    /// 모두 지우기의 실패 이유 (승인된 두 줄뿐): 네트워크가 안 되면 오프라인, 그 밖은 일반 이유. 409 `busy_retry`(잠금 경합 · 시간 초과)도 일반 이유 + Try again이다 (서버가 같은 요청을 다시 보내도 된다고 한다 — 사용자가 Try again으로 보낸다).
    /// 404는 오지 않는 응답이다 (길이 없는 서버라면 일반 실패)
    static func deleteAllFailure(_ error: Error) -> AgentQuestionFailure {
        if case .failed(let reason) = classify(error) { return reason }
        return .generic
    }

    private static func classify(_ error: Error) -> Classification {
        if let api = error as? APIError {
            switch api {
            case .server(_, .busyRetry, _): return .retry
            case .transport: return .failed(.offline)
            default: return .failed(.generic)
            }
        }
        if let url = error as? URLError {
            return .failed(offlineCodes.contains(url.code) ? .offline : .generic)
        }
        return .failed(.generic)
    }

    private static let offlineCodes: Set<URLError.Code> = [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff]

    /// 로그에 남길 짧은 코드: 오류 글 · 주소 · id는 담지 않는다
    static func code(_ error: Error) -> String {
        if let api = error as? APIError {
            switch api {
            case .server(let status, let code, _): return "http_\(status)_\(code.rawValue)"
            case .unexpectedStatus(let status): return "http_\(status)"
            case .decoding: return "decoding"
            case .transport: return "offline"
            case .notSignedIn: return "not_signed_in"
            }
        }
        if let url = error as? URLError { return offlineCodes.contains(url.code) ? "offline" : "network" }
        if let postgrest = error as? PostgrestError { return "postgrest_\(postgrest.code ?? "none")" }
        return "error"
    }
}
