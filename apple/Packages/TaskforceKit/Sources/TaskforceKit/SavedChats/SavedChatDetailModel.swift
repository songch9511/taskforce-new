import Foundation
import Observation

/// 저장된 대화 하나를 읽는 보기 (OA D3v-m, DZ 시트 2 · 3). **읽기 전용**이다: 입력창이 없고 Taskforce는 어떤 말에도 답하지 않는다.
/// - 말은 쪽(`range`)으로 **새 것부터** 읽고 오래된 것이 위로 놓인다. 한 쪽보다 길면 "Show earlier"가 앞 쪽을 읽는다. 총 `maxMessages`까지만 든다 (긴 답이 쌓여 메모리를 채우지 않게)
/// - 첫 쪽이 비면 그 대화는 다른 기기에서 이미 지워진 것이다 (`gone`): 보기가 닫힌다
/// - 지우기는 **확인 카드를 거쳐야 보낸다** (`requestDelete` → `confirmDelete`). 서버가 바로 지운다: Undo가 없다. 성공하면 줄이 빠지고 보기가 닫힌다
/// - 닫으면(`stop`) 도는 읽기의 늦은 답은 쓰지 않는다. 글은 메모리에만 두고 로그에 남기지 않는다
@MainActor
@Observable
public final class SavedChatDetailModel {
    public enum Phase: Equatable, Sendable {
        /// 처음 읽는 중: "Checking…"
        case loading
        case ready
        /// 읽지 못했다: "Couldn't load this chat" + Try again
        case failed
        /// 다른 기기에서 이미 지운 대화
        case gone
    }

    public enum DeleteState: Equatable, Sendable {
        case none
        /// 확인 카드: "Delete this chat?"
        case confirming
        /// 지우는 중 (두 번 눌러도 한 번)
        case deleting
        /// 지우지 못했다: "Couldn't delete" + 이유 + Try again
        case failed(AgentQuestionFailure)
    }

    public let chat: SavedChatRow
    public private(set) var phase: Phase = .loading
    /// 오래된 것이 위 (`said_at`, `seq`)
    public private(set) var messages: [SavedChatMessage] = []
    public private(set) var hasEarlier = false
    public private(set) var loadingEarlier = false
    public private(set) var deleteState: DeleteState = .none

    @ObservationIgnored private let pageSize: Int
    @ObservationIgnored private let maxMessages: Int
    @ObservationIgnored private let read: @Sendable (_ offset: Int, _ limit: Int) async throws -> [SavedChatMessageRecord]
    @ObservationIgnored private let delete: @MainActor () async -> SavedChatDeleteOutcome
    @ObservationIgnored private let onGone: @MainActor () -> Void
    @ObservationIgnored private let onDeleted: @MainActor () -> Void
    @ObservationIgnored private let log: @Sendable (_ event: String, _ code: String) -> Void
    /// 지금까지 읽은 서버 쪽의 말 수 (다음 쪽의 `offset`)
    @ObservationIgnored private var readCount = 0
    /// 닫을 때마다 오른다: 그 전에 시작한 읽기의 늦은 답을 막는다
    @ObservationIgnored private var generation = 0

    init(
        chat: SavedChatRow, pageSize: Int, maxMessages: Int, read: @escaping @Sendable (Int, Int) async throws -> [SavedChatMessageRecord],
        delete: @escaping @MainActor () async -> SavedChatDeleteOutcome, onGone: @escaping @MainActor () -> Void, onDeleted: @escaping @MainActor () -> Void,
        log: @escaping @Sendable (String, String) -> Void
    ) {
        self.chat = chat
        self.pageSize = max(1, pageSize)
        self.maxMessages = max(1, maxMessages)
        self.read = read
        self.delete = delete
        self.onGone = onGone
        self.onDeleted = onDeleted
        self.log = log
    }

    // MARK: 읽기

    /// 처음 쪽 (가장 새 말들)을 읽는다. 지금 보기의 주인(`generation`)이 바뀌지 않은 동안만 쓴다
    public func load() async {
        let started = generation
        if phase != .ready { phase = .loading }
        do {
            let records = try await read(0, pageSize)
            guard started == generation else { return }
            readCount = records.count
            let ordered = SavedChatMessages.ordered(records)
            guard !ordered.isEmpty else {
                // 대화가 있으면 말이 하나는 있다: 비었으면 다른 기기에서 이미 지웠다
                phase = .gone
                messages = []
                hasEarlier = false
                onGone()
                return
            }
            messages = ordered
            hasEarlier = records.count >= pageSize && readCount < maxMessages
            phase = .ready
        } catch {
            guard started == generation, !(error is CancellationError) else { return }
            log("saved_chat_load_failed", SavedChatsStore.code(error))
            phase = .failed
        }
    }

    /// Try again
    @discardableResult
    public func retry() -> Task<Void, Never> {
        Task { await load() }
    }

    /// 위의 "Show earlier": 앞 쪽을 읽어 맨 위에 붙인다. 한 번에 하나만 돈다. 읽지 못하면 보이는 것은 그대로 두고 다시 누를 수 있다
    public func showEarlier() async {
        guard phase == .ready, hasEarlier, !loadingEarlier else { return }
        let started = generation
        loadingEarlier = true
        defer { if started == generation { loadingEarlier = false } }
        do {
            let room = maxMessages - readCount
            let records = try await read(readCount, min(pageSize, max(room, 0)))
            guard started == generation else { return }
            readCount += records.count
            let known = Set(messages.map(\.id))
            let older = SavedChatMessages.ordered(records).filter { !known.contains($0.id) }
            messages = older + messages
            hasEarlier = records.count >= pageSize && readCount < maxMessages
        } catch {
            guard started == generation, !(error is CancellationError) else { return }
            log("saved_chat_more_failed", SavedChatsStore.code(error))
        }
    }

    /// 보기를 닫는다: 도는 읽기의 늦은 답은 쓰지 않는다
    public func stop() {
        generation += 1
        loadingEarlier = false
    }

    // MARK: 지우기: 확인 → 지우는 중 → 결과 (Undo 없음)

    /// 머리의 Delete · 오른쪽 클릭 메뉴의 Delete: **바로 지우지 않고** 확인 카드를 띄운다 (이미 묻는 중 · 지우는 중이면 그대로)
    public func requestDelete() {
        guard deleteState == .none else { return }
        deleteState = .confirming
    }

    /// Cancel · Esc: 확인 · 실패 카드를 닫는다. 지우는 중에는 되돌릴 수 없다
    public func cancelDelete() {
        switch deleteState {
        case .confirming, .failed: deleteState = .none
        case .none, .deleting: break
        }
    }

    /// 카드의 Delete · Try again: 서버에 바로 보낸다. **확인 카드가 떠 있는 동안(또는 실패 뒤)에만** 보낸다. 두 번 눌러도 한 번이다.
    /// 성공하면 줄이 빠지고(`delete`가 한다) 보기가 닫힌다 (`onDeleted`)
    public func confirmDelete() async {
        switch deleteState {
        case .confirming, .failed: break
        case .none, .deleting: return
        }
        deleteState = .deleting
        let started = generation
        let outcome = await delete()
        switch outcome {
        case .deleted:
            deleteState = .none
            // 닫은 보기가 닫힌 뒤에도 알리는 일은 없다 (패널이 이미 다른 대화로 바뀌었을 수 있다)
            if started == generation { onDeleted() }
        case .failed(let reason):
            deleteState = .failed(reason)
        }
    }
}
