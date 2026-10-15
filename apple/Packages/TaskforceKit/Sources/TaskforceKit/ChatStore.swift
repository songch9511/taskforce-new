import Foundation
import Observation

/// 대화 화면의 한 줄 (사용자 글 · Taskforce 답). 서버가 확인한 것과 아직 확인하지 않은 보내기를 한 목록으로 보인다
public struct ChatTurn: Identifiable, Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        /// 서버가 저장했고 답이 있다 (Taskforce의 말은 늘 이것)
        case sent
        /// 보내는 중 (서버 확인 전): 완료로 보이지 않는다
        case sending
        /// 보내지 못했다 (한 줄 이유). Try again
        case failed(String)
        /// 동의가 먼저 필요하다 (보내지 않았다). Try again
        case needsConsent
        /// 서버가 저장했지만 답이 아직 없다 (마지막 글). Try again
        case noReply
        /// 서버가 저장했지만 뒤에 새 메시지가 있어 답하지 않았다
        case notAnswered

        /// 같은 글을 다시 보낼 수 있나
        public var canRetry: Bool {
            switch self {
            case .failed, .needsConsent, .noReply: true
            default: false
            }
        }
    }

    /// 서버 메시지 id (아직 서버에 없으면 보내기 id = `client_message_id`)
    public let id: UUID
    public let isUser: Bool
    public let text: String
    public let createdAt: Date
    public let status: Status
    /// 이 글의 보내기 id (다시 보내기에 쓴다)
    public let clientMessageID: UUID?
    public let citations: [ChatCitation]
    /// 이 답이 가리키는 기억 (RememberedNote)
    public let rememberedIDs: [UUID]
    /// 보관 기한으로 글이 비워졌다
    public let textDeleted: Bool
    /// 에이전트 대화에서 서버가 계산한 전달 표시 (보낸 응답에서 받은 것. Taskforce 대화의 글은 늘 nil)
    public internal(set) var delivery: AgentDelivery? = nil
}

/// 헤더의 ProjectLink (명시적 선택만: Set by you · No clear link. 자동 추정 없음)
public struct ChatProject: Equatable, Sendable {
    public enum Basis: Equatable, Sendable {
        case user, none

        public var label: String {
            switch self {
            case .user: "Set by you"
            case .none: "No clear link"
            }
        }
    }

    public struct Choice: Equatable, Sendable, Identifiable, Hashable {
        /// nil = Ungrouped (All work)
        public let contextID: UUID?
        public let name: String
        public var id: UUID? { contextID }
    }

    public let contextID: UUID?
    public let name: String
    public let basis: Basis
    public let reason: String
    public let choices: [Choice]
    public let canUndo: Bool
    /// 마지막으로 바꾸지 못한 이유 (한 줄)
    public let message: String?
}

/// Chats 본문이 무엇을 보일까 (읽는 중 · 오프라인 · 실패 · 없음은 서로 다른 화면)
public enum ChatScreen: Equatable, Sendable {
    /// 아무 주장도 하지 않는다 (읽는 중)
    case blank
    case offline
    case failed
    /// 대화 목록 · 대화. 받은 뒤의 문제는 위 Notice 하나
    case ready(problem: WorkLoad.Problem?)
}

/// Chats(⌘3) · New chat(⌘N)의 대화 저장소.
/// - 읽기는 RLS(`conversations` · `conversation_messages` · `work_contexts`), 쓰기는 서버 `/api/v2/conversations`만. 서버가 사실이다:
///   앱이 다시 시작해도 서버 대화를 읽어 마지막 대화 · 범위를 되살린다 (A03). 새 영구 로컬 원문 캐시는 없다
/// - 초안 · 아직 서버에 없는 빈 대화 · 보내는 중인 글은 이 저장소의 **메모리**에만 있다 (계정별, 계정이 떠나거나 앱을 끄면 사라진다)
/// - 보내기: 사용자 글은 `client_message_id` 하나로 한 제출이다. 실패하면 같은 id · 같은 글로 다시 보낸다 (서버가 저장된 쌍을 돌려준다).
///   서버 확인(200) 전에는 완료로 보이지 않고, 늦게 오거나 두 번 온 응답은 메시지 id로 한 번만 반영한다
/// - 계정 경계: `AccountScope`에 붙어 계정이 떠나면 초안 · 목록 · 대기 전송을 모두 비운다. 보낼 때마다(다시 보내기 포함) 서버를 부르기 직전에
///   그 글을 만든 계정 · 세션이 지금도 그대로인지 다시 본다
@MainActor
@Observable
public final class ChatStore {
    public enum Mode: Equatable, Sendable {
        case history, chat
    }

    /// 아직 서버가 확인하지 않은 보내기
    struct PendingTurn: Equatable {
        enum Status: Equatable {
            case sending
            case failed(String)
            case needsConsent
        }

        let id: UUID
        let text: String
        let createdAt: Date
        let owner: AccountScope.Token
        var status: Status
        /// 이 제출에 실린 칩 (같은 제출을 다시 보내면 같은 칩이다: 칩만 다르면 서버가 409)
        var attachments: [ChatAttachment] = []
    }

    struct ChatThread {
        var messages: [ChatMessage] = []
        var pending: [PendingTurn] = []
        var load: WorkLoad = .loading
        /// 로컬에서 메시지를 반영할 때마다 오른다 (오래된 읽기가 새 응답을 덮지 않게)
        var revision = 0
        var textPurged = false

        var isSending: Bool { pending.contains { $0.status == .sending } }
    }

    public private(set) var mode: Mode = .history
    public private(set) var currentID: UUID?
    public private(set) var conversations: [ChatConversation] = []
    public private(set) var locals: [LocalChat] = []
    public private(set) var listLoad: WorkLoad = .loading
    /// 서버 gate가 꺼져 있다 (대화 만들기 · 보내기가 404): "실패"가 아니다
    public private(set) var isUnavailable = false
    public private(set) var contexts: [UUID: WorkContext] = [:]
    public private(set) var isOnline = true
    private var previews: [UUID: String] = [:]
    /// 서버에 이름이 없는 대화의 이름: 읽은 첫 사용자 글 (대화 이름은 만들 때만 정할 수 있어, 다른 길로 만든 빈 대화를 다시 쓸 때도 첫 글이 이름으로 보인다)
    private var derivedTitles: [UUID: String] = [:]
    /// 대화마다 읽기를 시작할 때 하나씩 올리는 순번: **마지막에 시작한 읽기만** 반영한다 (늦게 끝난 옛 읽기가 새 읽기 결과를 되돌리지 못한다)
    @ObservationIgnored private var threadReadSeq: [UUID: Int] = [:]
    /// 행을 id로 직접 읽을 때(`readConversation`)마다 올리는 순번: 겹친 직접 읽기는 마지막에 시작한 것만 반영한다.
    /// 글 읽기(`threadReadSeq`)와 따로 둔다: 다른 길의 글 읽기가 시작됐다고 해서 "서버가 없다"는 이 확인이 버려지면 안 된다
    @ObservationIgnored private var rowReadSeq: [UUID: Int] = [:]
    /// 묘비 시계: 서버가 대화를 없다 · 보관했다고 확인할 때마다 하나 오른다 (`confirmGone`)
    @ObservationIgnored private var tombstoneClock = 0
    /// 대화별 묘비: 그 대화를 없다고 확인한 때의 시계값. **읽기를 시작할 때 시계값을 쥐고**, 반영할 때 이 대화의 묘비가 그보다 새것이면(`isStale`)
    /// 그 읽기의 데이터(목록 행 · 직접 읽은 행 · 글 · 미리보기)를 버린다. 확인 뒤에 시작한 읽기(사용자의 Try again · 다시 열기)는 묘비보다 새 세대라 정상으로 반영한다
    @ObservationIgnored private var tombstones: [UUID: Int] = [:]
    /// 대화별 복구: 묘비가 선 뒤 행이 다시 반영된 때의 시계값. 현재 세대는 마지막 묘비 · 복구에서 시작한다 (`generationStart`)
    @ObservationIgnored private var recoveries: [UUID: Int] = [:]
    /// 행이 `conversations`에 들어온 순서표: 새로 읽기가 시작한 뒤에 들어온 행("읽는 사이 생긴 행")을 가린다 (묘비 뒤 Try again이 복구한 행도 포함)
    @ObservationIgnored private var rowStamps: [UUID: Int] = [:]
    @ObservationIgnored private var stampClock = 0
    /// 행을 읽기 시작할 때와 반영할 때 하나씩 올리는 시계, 그리고 대화별로 쥔 행을 반영한 때의 값. 쥔 행을 반영한 뒤에 시작한 읽기는 서버 버전과 상관없이 이긴다
    /// (서버 시각은 뒤로 갈 수 있다: `db_now()`는 트랜잭션 시작 시각이다). 서버 버전은 겹친 읽기 사이의 역전 방어에만 쓴다
    @ObservationIgnored private var rowClock = 0
    @ObservationIgnored private var rowAppliedAt: [UUID: Int] = [:]
    private var drafts: [UUID: String] = [:]
    /// 열린 창들이 보이는 대화 (앱이 정한다). 목록 읽기(⌘3 · 온라인 복귀 · Try again)가 공유 `currentID`뿐 아니라 이들의 글도 다시 읽는다
    @ObservationIgnored public var viewedConversations: () -> Set<UUID> = { [] }
    /// 세션 패널이 보이는 대화 (OA U2, 앱이 정한다). `viewedConversations`와 같이 목록 읽기가 이 글도 다시 읽고, 목록(최근 100 + 빈 20)에 없는 오래된 대화는
    /// 행을 id로 직접 읽어 (패널이 열려 있는 동안) 목록 갱신이 떨어뜨리지 않는다
    @ObservationIgnored public var panelConversations: () -> Set<UUID> = { [] }
    var threads: [UUID: ChatThread] = [:]
    private var projectUndo: [UUID: UUID?] = [:]
    private var projectMessage: [UUID: String] = [:]
    /// 입력칸이 포커스를 가져가야 할 때마다 오른다 (대화를 열었을 때 · 새 대화)
    public private(set) var focusRequest = 0
    /// 사용자가 목록 · 새 대화로 직접 옮겼나 (아니면 목록을 읽은 뒤 마지막 대화로 자동 복원)
    private var navigated = false

    /// 에이전트 대상 전달 표시 (보낸 사용자 메시지 id → 서버가 계산한 표시). 메모리뿐이다
    private var deliveries: [UUID: AgentDelivery] = [:]
    /// 보낸 글의 칩 (client_message_id → 칩): 서버에 저장됐지만 답이 없는 글을 다시 보낼 때 같은 칩을 싣는다
    @ObservationIgnored private var sentChips: [UUID: [ChatAttachment]] = [:]

    @ObservationIgnored private let gateway: any ChatGateway
    /// Assistant 창의 쓰기 (대상 목록 · 대상을 지정한 만들기 · 칩을 실은 보내기). 없으면 칩 없이 Taskforce 대상으로만 보낸다
    @ObservationIgnored public var assistant: (any AssistantGateway)?
    @ObservationIgnored private let scope: AccountScope
    @ObservationIgnored private let memory: MemoryStore?
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var listSequence = 0
    /// 화면 동작이 띄운 읽기들 (테스트가 `settle()`로 기다린다)
    @ObservationIgnored private var background: [Task<Void, Never>] = []

    public init(
        gateway: any ChatGateway, scope: AccountScope, memory: MemoryStore? = nil, now: @escaping @Sendable () -> Date = { Date() },
        assistant: (any AssistantGateway)? = nil
    ) {
        self.gateway = gateway
        self.assistant = assistant
        self.scope = scope
        self.memory = memory
        self.now = now
        scope.onLeft { [weak self] in self?.reset() }
    }

    private func spawn(_ work: @escaping @MainActor () async -> Void) {
        background.removeAll { $0.isCancelled }
        background.append(Task { await work() })
    }

    /// 띄워 둔 읽기가 모두 끝날 때까지 (테스트 · 견본)
    public func settle() async {
        while let task = background.popLast() { await task.value }
    }

    /// 계정이 떠남: 초안 · 목록 · 읽은 글 · 대기 전송을 모두 비운다 (늦은 응답은 `scope.isCurrent`가 버린다)
    public func reset() {
        listSequence += 1
        mode = .history
        currentID = nil
        conversations = []
        locals = []
        listLoad = .loading
        isUnavailable = false
        contexts = [:]
        previews = [:]
        derivedTitles = [:]
        threadReadSeq = [:]
        rowReadSeq = [:]
        tombstones = [:]
        recoveries = [:]
        rowStamps = [:]
        rowAppliedAt = [:]
        drafts = [:]
        threads = [:]
        deliveries = [:]
        sentChips = [:]
        projectUndo = [:]
        projectMessage = [:]
        navigated = false
    }

    public func pathChanged(online: Bool) {
        isOnline = online
    }

    // MARK: 보이는 것

    public var entries: [ChatListEntry] {
        ChatHistoryRules.entries(conversations: conversations, locals: locals, previews: previews, drafts: drafts, titles: derivedTitles)
    }

    /// 목록 화면: 읽는 중이면 아무것도 보이지 않고, 오프라인 · 실패는 각자 화면, 비어 있으면 "No conversations yet."
    public var listScreen: ChatScreen {
        if entries.isEmpty {
            switch listLoad {
            case .loading: return .blank
            case .offline: return .offline
            case .failed: return .failed
            case .loaded(let problem): return .ready(problem: problem)
            }
        }
        if case .loaded(let problem) = listLoad { return .ready(problem: problem) }
        return .ready(problem: nil)
    }

    /// 목록이 비었고 다 읽었다 ("No conversations yet." + New chat, gate가 꺼져 있으면 그 말)
    public var listIsEmpty: Bool {
        if case .loaded = listLoad { return entries.isEmpty }
        return false
    }

    public var currentTitle: String {
        guard let id = currentID else { return ChatCopy.newChat }
        return entries.first { $0.id == id }?.title ?? ChatCopy.newChat
    }

    /// 헤더 제목: 대화 이름, 목록이면 Chat history
    public var headerTitle: String {
        mode == .history ? ChatCopy.historyTitle : currentTitle
    }

    public var composerPlaceholder: String {
        isUnavailable ? ChatCopy.unavailable : ChatCopy.composerPlaceholder
    }

    /// 보낼 수 있는 곳이 있나 (Composer): 열린 대화가 있고 기능이 켜져 있다
    public var canCompose: Bool { mode == .chat && currentID != nil && !isUnavailable }

    public var isSending: Bool {
        currentID.flatMap { threads[$0]?.isSending } ?? false
    }

    /// 지금 대화의 화면: 읽은 글이 없으면 읽기 상태가 화면이고, 글이 있으면 읽은 뒤의 문제는 위 Notice
    public var screen: ChatScreen { screen(for: currentID) }

    /// 한 대화의 화면 (Assistant 창은 창마다 대화가 하나라 id로 읽는다)
    public func screen(for id: UUID?) -> ChatScreen {
        guard let id else { return .blank }
        let thread = threads[id]
        let hasContent = !(thread?.messages.isEmpty ?? true) || !(thread?.pending.isEmpty ?? true)
        let isLocal = locals.contains { $0.id == id }
        switch thread?.load ?? .loading {
        case .loading: return hasContent || isLocal ? .ready(problem: nil) : .blank
        case .offline: return hasContent ? .ready(problem: .offline) : .offline
        case .failed: return hasContent ? .ready(problem: .failed) : .failed
        case .loaded(let problem): return .ready(problem: problem)
        }
    }

    /// 동의가 먼저 필요한 글이 있다 (위에 "Allow AI processing to continue")
    public var needsConsent: Bool {
        currentID.map(needsConsent(in:)) ?? false
    }

    public func needsConsent(in id: UUID) -> Bool {
        threads[id]?.pending.contains { $0.status == .needsConsent } ?? false
    }

    public func draft(for id: UUID) -> String { drafts[id] ?? "" }

    /// 쓰던 글이 남은 대화들 (대상을 바꿀 때 새 대화가 이 중 하나를 다시 써서 그 글을 덮지 않게)
    public var draftConversationIDs: Set<UUID> { Set(drafts.keys) }

    public func setDraft(_ text: String, for id: UUID) {
        guard scope.token != nil else { return }
        drafts[id] = text.isEmpty ? nil : text
    }

    /// 지금 대화의 줄들 (서버가 확인한 메시지 + 아직 확인하지 않은 보내기)
    public func turns(for id: UUID) -> [ChatTurn] {
        guard let thread = threads[id] else { return [] }
        // 에이전트 대화의 답은 비동기로 쓰인다: 답이 아직 없다고 "No reply yet"을 말하지 않는다 (전달 표시가 그 자리를 맡는다)
        let isAgent = conversationTarget(for: id).isAgent
        let pending = Dictionary(thread.pending.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var used: Set<UUID> = []
        var turns: [ChatTurn] = []
        let messages = thread.messages.sorted { $0.seq < $1.seq }
        for (index, message) in messages.enumerated() {
            let deleted = message.text.isEmpty && thread.textPurged
            if message.role.isUser {
                var status = ChatTurn.Status.sent
                if let cmid = message.clientMessageID, let turn = pending[cmid] {
                    status = Self.status(of: turn)
                    used.insert(cmid)
                } else if !isAgent, !messages.contains(where: { $0.replyTo == message.id }) {
                    let hasLater = messages[(index + 1)...].contains { $0.role.isUser }
                    status = hasLater || message.clientMessageID == nil ? .notAnswered : .noReply
                }
                var turn = ChatTurn(
                    id: message.id, isUser: true, text: message.text, createdAt: message.createdAt, status: status,
                    clientMessageID: message.clientMessageID, citations: [], rememberedIDs: [], textDeleted: deleted
                )
                turn.delivery = deliveries[message.id]
                turns.append(turn)
            } else {
                turns.append(ChatTurn(
                    id: message.id, isUser: false, text: message.text, createdAt: message.createdAt, status: .sent, clientMessageID: nil,
                    citations: message.content?.citations ?? [], rememberedIDs: message.rememberedIDs, textDeleted: deleted
                ))
            }
        }
        for turn in thread.pending.sorted(by: { $0.createdAt < $1.createdAt }) where !used.contains(turn.id) {
            turns.append(ChatTurn(
                id: turn.id, isUser: true, text: turn.text, createdAt: turn.createdAt, status: Self.status(of: turn), clientMessageID: turn.id,
                citations: [], rememberedIDs: [], textDeleted: false
            ))
        }
        return turns
    }

    private static func status(of turn: PendingTurn) -> ChatTurn.Status {
        switch turn.status {
        case .sending: .sending
        case .failed(let message): .failed(message)
        case .needsConsent: .needsConsent
        }
    }

    /// 헤더의 ProjectLink. 고를 프로젝트도 이 대화의 프로젝트도 없으면 보이지 않는다 ("Context appears in the header of linked ... chats only")
    public func project(for id: UUID) -> ChatProject? {
        let contextID: UUID?
        if let chat = conversations.first(where: { $0.id == id }) {
            contextID = chat.contextID
        } else if let local = locals.first(where: { $0.id == id }) {
            contextID = local.contextID
        } else {
            return nil
        }
        let active = contexts.values.filter(\.isActive).sorted { ($0.name, $0.id.uuidString) < ($1.name, $1.id.uuidString) }
        guard contextID != nil || !active.isEmpty else { return nil }
        var choices = [ChatProject.Choice(contextID: nil, name: ChatCopy.projectUngrouped)]
        choices += active.map { ChatProject.Choice(contextID: $0.id, name: $0.name) }
        let name = contextID.map { contexts[$0]?.name ?? MemoryCopy.unnamedProject } ?? ChatCopy.projectUngrouped
        if let contextID, !choices.contains(where: { $0.contextID == contextID }) {
            choices.append(ChatProject.Choice(contextID: contextID, name: name))
        }
        return ChatProject(
            contextID: contextID, name: name, basis: contextID == nil ? .none : .user,
            reason: contextID == nil ? ChatCopy.projectReasonNone : ChatCopy.projectReasonUser, choices: choices,
            canUndo: projectUndo[id] != nil, message: projectMessage[id]
        )
    }

    // MARK: 열기 · 옮기기

    /// 레일의 Chats(⌘3): 마지막 대화로 돌아간다 (이번 실행에서 연 적 없으면 서버 대화에서 마지막 것을 읽어 되살린다). 대화가 하나도 없으면 목록
    public func openChats() {
        mode = currentID == nil ? .history : .chat
        if mode == .chat { focusRequest += 1 }
        spawn { await self.refresh() }
    }

    /// 헤더의 history 아이콘: 목록 ↔ 대화
    public func toggleHistory() {
        navigated = true
        if mode == .history {
            if currentID != nil { mode = .chat }
        } else {
            mode = .history
            spawn { await self.refresh() }
        }
    }

    /// Esc: 목록을 보는 중이면 대화로 돌아간다 (열린 대화가 있을 때). 처리했으면 true — 아니면 패널이 접힌다
    public func escapeInner() -> Bool {
        guard mode == .history, currentID != nil else { return false }
        mode = .chat
        focusRequest += 1
        return true
    }

    public func showHistory() {
        navigated = true
        mode = .history
    }

    public func open(_ id: UUID) {
        guard conversations.contains(where: { $0.id == id }) || locals.contains(where: { $0.id == id }) else { return }
        navigated = true
        currentID = id
        mode = .chat
        focusRequest += 1
        spawn { await self.loadThread(id) }
    }

    /// 새 대화 (⌘N · square-pen): 손대지 않은 빈 대화가 있으면 그것을 다시 쓴다. 없으면 서버에 아직 없는 빈 대화를 메모리에 만든다
    /// (첫 메시지를 보낼 때 서버에 만든다)
    @discardableResult
    public func newChat() -> UUID {
        navigated = true
        focusRequest += 1
        let occupied = Set(threads.filter { !$0.value.pending.isEmpty }.keys)
        if let reused = ChatHistoryRules.reusableEmptyChat(current: currentID, conversations: conversations, locals: locals, occupied: occupied) {
            currentID = reused
            mode = .chat
            if conversations.contains(where: { $0.id == reused }) { spawn { await self.loadThread(reused) } }
            return reused
        }
        let chat = LocalChat(createdAt: now())
        locals.append(chat)
        threads[chat.id] = ChatThread(load: .loaded(problem: nil))
        currentID = chat.id
        mode = .chat
        return chat.id
    }

    // MARK: Assistant 창 (OA U1)
    // 창마다 대화가 하나라 위의 `currentID` · `mode`(패널의 한 대화)와 따로 논다: 아래는 모두 대화 id를 받고 `currentID` · `mode` · `focusRequest`를 바꾸지 않는다.

    /// 대화의 대상. 서버에 아직 없는 대화는 고른 대상, 서버 대화는 행의 대상 열 (열이 없는 옛 행 · 모르는 대화는 Taskforce)
    public func conversationTarget(for id: UUID) -> ChatConversationTarget {
        if let local = locals.first(where: { $0.id == id }) {
            guard case .agent(_, let connectionID) = local.target else { return .taskforce }
            return ChatConversationTarget(kind: .agent, agentConnectionID: connectionID)
        }
        return conversations.first { $0.id == id }?.target ?? .taskforce
    }

    /// 대화의 대상을 대상 고르기의 말로. 서버 대화의 에이전트는 adapter를 모른다(빈 글자): 연결 id로 대상 목록의 행을 찾는다
    public func pick(for id: UUID) -> AssistantTargetPick {
        if let local = locals.first(where: { $0.id == id }) { return local.target }
        let target = conversationTarget(for: id)
        return target.isAgent ? .agent(adapter: "", connectionID: target.agentConnectionID) : .taskforce
    }

    public func isLocalChat(_ id: UUID) -> Bool { locals.contains { $0.id == id } }

    /// 첫 메시지를 보내기 전의 대화만 대상을 바꿀 수 있다. 서버에 있는 대화의 대상은 바뀌지 않는다 (같은 id 다른 대상은 서버가 409)
    public func setLocalTarget(_ pick: AssistantTargetPick, for id: UUID) {
        guard let index = locals.firstIndex(where: { $0.id == id }) else { return }
        locals[index].target = pick
    }

    /// 메시지가 한 번이라도 있었거나 보내는 중이다 (대상 고르기가 새 대화를 열지 정하는 데 쓴다)
    public func hasMessages(_ id: UUID) -> Bool {
        let thread = threads[id]
        if !(thread?.pending.isEmpty ?? true) { return true }
        if let chat = conversations.first(where: { $0.id == id }) { return !chat.isUntouched || !(thread?.messages.isEmpty ?? true) }
        return false
    }

    /// 서버에 있는 가장 새 대화 (⌘3으로 첫 창을 열 때 되돌아갈 대화). 아직 서버에 없는 빈 대화는 아니다
    public var lastConversationID: UUID? {
        entries.first { !$0.isLocal }?.id
    }

    /// 한 대화의 이름 (이름이 없으면 New chat)
    public func title(for id: UUID) -> String {
        entries.first { $0.id == id }?.title ?? ChatCopy.newChat
    }

    /// 이 대화의 대상을 안다: 서버에 아직 없는 새 대화(고른 대상)이거나 읽은 행이 있다. **대상을 모르는 대화는 Taskforce로 보지 않는다**
    /// (에이전트 대화에 Taskforce 길로 보내면 서버가 `reply: null`로 접수한 것을 디코딩 오류로 읽는다)
    public func isTargetKnown(_ id: UUID) -> Bool {
        locals.contains { $0.id == id } || conversations.contains { $0.id == id }
    }

    public func canCompose(in id: UUID?) -> Bool {
        guard let id else { return false }
        return !isUnavailable && isTargetKnown(id)
    }

    /// 이 글을 지금 보낼 수 있나: 보낼 곳이 있고, 로그인해 있고, 글이 보낼 수 있는 것이고, 이 대화가 보내는 중이 아니다
    public func canSend(_ text: String, in id: UUID) -> Bool {
        canCompose(in: id) && scope.token != nil && ChatComposerRules.isSendable(text) && !isSending(in: id)
    }

    /// 대화 목록을 읽는다 (History를 열 때): 끝을 기다리지 않는다
    public func refreshInBackground() {
        spawn { await self.refresh() }
    }

    public func isSending(in id: UUID) -> Bool { threads[id]?.isSending ?? false }

    /// 서버에 있는 대화의 글을 읽는다. 창이 대화를 열 때 부른다 (저장소의 현재 대화 · 모드는 그대로)
    public func ensureLoaded(_ id: UUID) {
        guard conversations.contains(where: { $0.id == id }) else { return }
        spawn { await self.loadThread(id) }
    }

    /// 대화 id만 아는 곳(세션 패널)용: 끝을 기다리지 않는다. 읽기는 `readConversation`
    public func loadConversation(_ id: UUID) {
        spawn { await self.readConversation(id) }
    }

    /// 대화 id만 아는 곳(세션 패널)용 (OA U2): 행을 모르면 **id로 직접 읽고**(History 목록에 기대지 않는다) 글을 읽는다. 저장소의 현재 대화 · 모드는 그대로.
    /// 행을 못 읽었거나(오프라인 · 실패) 서버에 없거나 보관한 대화면 빈 화면이 아니라 그 오류 상태다 (`screen(for:)`: Try again이 이 함수를 다시 부른다)
    public func readConversation(_ id: UUID) async {
        guard let token = scope.token else { return }
        if !isTargetKnown(id) {
            let started = tombstoneClock
            let readStart = tickRow()
            let rowSeq = (rowReadSeq[id] ?? 0) + 1
            rowReadSeq[id] = rowSeq
            threadReadSeq[id] = (threadReadSeq[id] ?? 0) + 1   // 이미 나가 있던 글 읽기는 이 읽기가 대신한다
            if threads[id] == nil { threads[id] = ChatThread() }
            threads[id]?.load = .loading
            do {
                let row = try await gateway.conversation(id: id)
                guard scope.isCurrent(token), rowReadSeq[id] == rowSeq else { return }
                guard let row, row.archivedAt == nil else {
                    // 부정 응답(없다 · 보관): 현재 세대가 시작한 뒤에 시작한 읽기만 반영한다 (Try again 복구는 늦은 부정 응답에 지워지지 않는다)
                    guard !isNegativeStale(id, since: started) else { return }
                    confirmGone(id)
                    return
                }
                guard !isStale(id, since: started) else { return }
                applyRead(row, readStartedAt: readStart)
            } catch {
                guard scope.isCurrent(token), rowReadSeq[id] == rowSeq, !isStale(id, since: started), let failure = ReadFailure.from(error, online: isOnline) else { return }
                if failure == .unavailable {
                    isUnavailable = true
                    threads[id]?.load = .loaded(problem: nil)
                } else {
                    threads[id]?.load = failure == .offline ? .offline : .failed
                }
                return
            }
        }
        await loadThread(id)
    }

    /// 새 대화 하나를 마련한다 (⌘N · SquarePen · 대상 바꾸기). 손대지 않은 빈 대화가 있으면 그것을 다시 쓴다 — 단 `excluding`(다른 창이 쥔 대화)은 빼고,
    /// 서버에 이미 있는 빈 대화는 대상이 같을 때만 쓴다 (서버 대화의 대상은 바뀌지 않는다). 없으면 서버에 아직 없는 빈 대화를 메모리에 만든다 (첫 메시지를 보낼 때 서버에 만든다)
    @discardableResult
    public func reserveNewChat(target: AssistantTargetPick, excluding: Set<UUID>) -> UUID {
        let occupied = Set(threads.filter { !$0.value.pending.isEmpty }.keys).union(excluding)
        let compatible = conversations.filter { Self.canReuse($0.target, for: target) }
        if let reused = ChatHistoryRules.reusableEmptyChat(current: nil, conversations: compatible, locals: locals, occupied: occupied) {
            if locals.contains(where: { $0.id == reused }) {
                setLocalTarget(target, for: reused)
            } else {
                ensureLoaded(reused)
            }
            return reused
        }
        let chat = LocalChat(createdAt: now(), target: target)
        locals.append(chat)
        threads[chat.id] = ChatThread(load: .loaded(problem: nil))
        return chat.id
    }

    private static func canReuse(_ existing: ChatConversationTarget, for pick: AssistantTargetPick) -> Bool {
        switch pick {
        case .taskforce: existing.kind == .taskforce
        case .agent(_, let connectionID): existing.isAgent && connectionID != nil && existing.agentConnectionID == connectionID
        }
    }

    /// 보낸 글에 서버가 계산해 준 전달 표시 (에이전트 대화)
    public func delivery(forMessage id: UUID) -> AgentDelivery? { deliveries[id] }

    var deliveryCount: Int { deliveries.count }

    // MARK: 읽기

    /// 목록 · 열린 대화를 서버에서 읽는다 (Chats를 열 때 · Try again · 온라인으로 돌아왔을 때)
    public func refresh() async {
        guard let token = scope.token else { return }
        listSequence += 1
        let sequence = listSequence
        let started = tombstoneClock
        if case .loaded = listLoad {} else { listLoad = .loading }
        // 읽는 사이 이 기기가 만든 · 복구한 대화(첫 보내기 · Try again)는 그 읽기에 없을 수 있다: 서버가 지운 것이 아니다 (이 순서표보다 새로 들어온 행)
        let startedStamp = stampClock
        let listReadStart = tickRow()
        do {
            async let rows = gateway.conversations()
            async let projects = gateway.workContexts()
            let (chats, named) = try await (rows, projects)
            // 세션 패널이 보이는 대화 중 이 목록(최근 100 + 빈 20)에 없는 것은 id로 직접 읽어 남긴다
            let listed = Set(chats.map(\.id))
            let panelReadStart = tickRow()
            let (panelRows, gone, kept) = await readPanelRows(missingFrom: listed)
            guard scope.isCurrent(token), sequence == listSequence else { return }
            // 서버가 없다 · 보관했다고 확인한 패널 대화: 행 · 본문 · 대상을 지우고 오류 화면(다시 시도)으로 둔다 (일시 실패와 다르다). 직접 읽기와 같은 길이다
            // 부정 응답은 현재 세대가 시작한 뒤에 시작한 읽기만 반영한다 (그 사이 Try again이 복구했으면 이 옛 응답이 복구를 지우지 못한다)
            for id in gone where !isNegativeStale(id, since: started) { confirmGone(id) }
            // 이 새로 읽기를 시작한 뒤에 다른 길(직접 읽기)이 없다고 확인한 대화는, 이 응답(목록 · id로 읽은 행)에 있어도 반영하지 않는다.
            // 행은 응답이 끝난 순서가 아니라 서버 버전 순서다: 쥔 행이 더 새 버전이면 응답 행 대신 쥔 행을 둔다
            let held = Dictionary(conversations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var appliedIDs: [UUID] = []
            let pick: (ChatConversation, Int) -> ChatConversation = { row, readStart in
                if let heldRow = held[row.id], !self.shouldApply(row, over: heldRow, readStartedAt: readStart) { return heldRow }
                appliedIDs.append(row.id)
                return row
            }
            let fresh: [ChatConversation] = chats.filter { !isStale($0.id, since: started) }
            let listedRows: [ChatConversation] = fresh.filter { $0.archivedAt == nil }.map { pick($0, listReadStart) }
            let extras: [ChatConversation] = panelRows.filter { !isStale($0.id, since: started) }.map { pick($0, panelReadStart) }
            // 잠깐 못 읽은 패널 대화: 지금 쥔 행을 그대로 둔다 (읽기 전에 알던 행의 옛 사본이 아니라)
            let keptRows: [ChatConversation] = conversations.filter { kept.contains($0.id) }
            let live = Set(fresh.map(\.id)).union(extras.map(\.id)).union(keptRows.map(\.id))
            let createdMeanwhile: [ChatConversation] = conversations.filter { (rowStamps[$0.id] ?? 0) > startedStamp && !live.contains($0.id) }
            replaceConversations(listedRows + extras + keptRows + createdMeanwhile)
            for id in appliedIDs { rowAppliedAt[id] = tickRow() }
            contexts = Dictionary(named.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            listLoad = .loaded(problem: nil)
            dropThreads(missingFrom: live.union(createdMeanwhile.map(\.id)).union(panelConversations()))
            if currentID == nil, !navigated, let latest = entries.first(where: { !$0.isLocal }) {
                // 마지막 대화로 되살린다 (앱을 다시 켠 뒤)
                currentID = latest.id
                mode = .chat
                focusRequest += 1
            }
            await loadPreviews(token: token, sequence: sequence, started: started)
            await loadShownThreads()
        } catch {
            guard scope.isCurrent(token), sequence == listSequence, let failure = ReadFailure.from(error, online: isOnline) else { return }
            if failure == .unavailable {
                // 서버에 대화 테이블이 아직 없다: 실패가 아니라 기능이 아직 없는 것 ("Chats aren't available yet.")
                isUnavailable = true
                listLoad = .loaded(problem: nil)
            } else if case .loaded = listLoad {
                listLoad = .loaded(problem: failure == .offline ? .offline : .failed)
            } else {
                listLoad = failure == .offline ? .offline : .failed
            }
        }
    }

    /// 세션 패널이 보이는 대화 중 목록에 없는 것의 행을 id로 읽는다. 서버가 없다 · 보관했다고 확인하면 `gone`(오류 화면), 잠깐 못 읽으면 아는 행을 그대로 둔다
    private func readPanelRows(missingFrom listed: Set<UUID>) async -> (rows: [ChatConversation], gone: Set<UUID>, kept: Set<UUID>) {
        let ids = panelConversations().subtracting(listed).subtracting(locals.map(\.id)).sorted { $0.uuidString < $1.uuidString }
        guard !ids.isEmpty else { return ([], [], []) }
        let knownIDs = Set(conversations.map(\.id))
        enum Outcome: Sendable {
            case row(ChatConversation)
            case gone(UUID)
            case keep(UUID)
            case unknown
        }
        return await withTaskGroup(of: Outcome.self) { group in
            for id in ids {
                group.addTask { [gateway] in
                    do {
                        guard let row = try await gateway.conversation(id: id), row.archivedAt == nil else { return .gone(id) }
                        return .row(row)
                    } catch {
                        return knownIDs.contains(id) ? .keep(id) : .unknown
                    }
                }
            }
            var rows: [ChatConversation] = []
            var gone: Set<UUID> = []
            var kept: Set<UUID> = []
            for await outcome in group {
                switch outcome {
                case .row(let row): rows.append(row)
                case .gone(let id): gone.insert(id)
                case .keep(let id): kept.insert(id)
                case .unknown: break
                }
            }
            return (rows, gone, kept)
        }
    }

    /// 서버가 없다 · 보관했다고 확인한 대화 (새로 읽기와 직접 읽기가 같은 길을 쓴다): 행 · 본문 · 대상 · 미리보기를 지우고 오류 화면(`.failed`, Try again)으로 둔다.
    /// 묘비를 세워, 이 확인보다 먼저 시작한 읽기의 늦은 응답이 이 대화를 되살리지 못하게 한다 (`isStale`). 사용자의 Try again · 다시 열기(`readConversation`)는 새 세대로 시작한다
    private func confirmGone(_ id: UUID) {
        tombstoneClock += 1
        tombstones[id] = tombstoneClock
        conversations.removeAll { $0.id == id }
        rowStamps[id] = nil
        rowAppliedAt[id] = nil
        previews[id] = nil
        derivedTitles[id] = nil
        threads[id] = ChatThread()
        threads[id]?.load = .failed
    }

    /// 읽기를 시작한 뒤(`started` = 그때의 묘비 시계) 이 대화가 없다고 확인됐나: 그렇다면 그 읽기의 데이터는 반영하지 않는다
    private func isStale(_ id: UUID, since started: Int) -> Bool {
        (tombstones[id] ?? 0) > started
    }

    /// 이 대화의 현재 세대가 시작한 시계값: 마지막 묘비(없다고 확인) 또는 복구(묘비 뒤 행이 다시 반영)
    private func generationStart(_ id: UUID) -> Int {
        max(tombstones[id] ?? 0, recoveries[id] ?? 0)
    }

    /// 부정 응답(없다 · 보관)이 현재 세대보다 먼저 시작했나: 그렇다면 반영하지 않는다
    private func isNegativeStale(_ id: UUID, since started: Int) -> Bool {
        generationStart(id) > started
    }

    /// 묘비가 선 대화에 행이 다시 반영됐다(Try again · 확인 뒤 시작한 새로 읽기): 새 세대가 시작한다. 이전에 시작한 부정 응답은 이 복구를 지우지 못한다
    private func noteRecovery(_ id: UUID) {
        guard let gone = tombstones[id], (recoveries[id] ?? 0) < gone else { return }
        tombstoneClock += 1
        recoveries[id] = tombstoneClock
    }

    private func tickRow() -> Int {
        rowClock += 1
        return rowClock
    }

    /// 이 읽기의 행을 쥔 행 대신 반영해도 되나: 쥔 행을 반영한 **뒤에** 시작한 읽기는 늘 이긴다 (서버 시각이 뒤로 갈 수 있어 그 새 읽기를 영원히 거절하면 수렴하지 못한다).
    /// 쥔 행을 반영하기 전에 시작한 읽기(겹친 읽기)는 서버 버전이 더 낮으면 반영하지 않는다: 늦게 끝난 옛 응답이 더 새 행을 덮지 못한다
    private func shouldApply(_ row: ChatConversation, over held: ChatConversation, readStartedAt: Int) -> Bool {
        readStartedAt > (rowAppliedAt[row.id] ?? 0) || row.rowVersion >= held.rowVersion
    }

    /// 내가 쓴 뒤 서버가 돌려준 행(범위 PATCH)을 반영한다: 쓴 값(프로젝트 등)은 늘 반영하되, 겹친 읽기가 이미 더 새 버전을 쥐게 했다면(쓰기를 보내고 응답이 오는 사이)
    /// 그 행의 시각 · 읽음 · 글 비움은 쥔 것을 지킨다 (옛 응답이 첫 글의 시각을 되돌려 New chat이 글이 있는 대화를 빈 대화로 다시 쓰지 않게)
    private func applyWrite(_ row: ChatConversation, startedAt: Int) {
        guard let held = conversations.first(where: { $0.id == row.id }), !shouldApply(row, over: held, readStartedAt: startedAt) else {
            upsert(row)
            return
        }
        upsert(ChatConversation(
            id: row.id, title: row.title, contextID: row.contextID, createdAt: row.createdAt, lastMessageAt: held.lastMessageAt,
            lastReadAt: held.lastReadAt, archivedAt: row.archivedAt, textPurgedAt: held.textPurgedAt, target: row.target
        ))
    }

    /// 읽은 행(직접 읽기)을 반영한다 (`shouldApply`)
    private func applyRead(_ row: ChatConversation, readStartedAt: Int) {
        if let held = conversations.first(where: { $0.id == row.id }), !shouldApply(row, over: held, readStartedAt: readStartedAt) { return }
        upsert(row)
        noteRecovery(row.id)
    }

    /// 새로 읽은 목록 · 행으로 `conversations`를 바꾼다 (들어온 행에 순서표를 붙이고 나간 행은 뗀다)
    private func replaceConversations(_ rows: [ChatConversation]) {
        let before = Set(conversations.map(\.id))
        let after = Set(rows.map(\.id))
        for id in before.subtracting(after) { rowStamps[id] = nil }
        for row in rows where !before.contains(row.id) {
            stampClock += 1
            rowStamps[row.id] = stampClock
            noteRecovery(row.id)
        }
        conversations = rows
    }

    /// 지금 보이는 대화들의 글을 읽는다: 공유 `currentID`와 창들 · 세션 패널이 보이는 대화 (서버에 있는 것만, 겹치지 않게)
    private func loadShownThreads() async {
        var shown = viewedConversations().union(panelConversations())
        if let id = currentID { shown.insert(id) }
        let ids = shown.filter { id in conversations.contains { $0.id == id } }.sorted { $0.uuidString < $1.uuidString }
        guard !ids.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for id in ids { group.addTask { await self.loadThread(id) } }
        }
    }

    /// 다른 곳에서 지운 · 보관한 대화는 열려 있어도 닫는다 (서버가 사실이다)
    private func dropThreads(missingFrom live: Set<UUID>) {
        let localIDs = Set(locals.map(\.id))
        for id in threads.keys where !live.contains(id) && !localIDs.contains(id) { threads[id] = nil }
        if let current = currentID, !live.contains(current), !localIDs.contains(current) {
            currentID = nil
            if mode == .chat { mode = .history }
        }
    }

    private func loadPreviews(token: AccountScope.Token, sequence: Int, started: Int) async {
        let ids = conversations.filter { !$0.isUntouched }.map(\.id)
        guard !ids.isEmpty, let last = try? await gateway.lastMessages(conversationIDs: ids), scope.isCurrent(token), sequence == listSequence else { return }
        var next: [UUID: String] = [:]
        for (id, message) in last where !isStale(id, since: started) { next[id] = message.text }
        previews = next
    }

    /// 한 대화의 메시지를 읽는다.
    /// - 읽는 사이 로컬에서 응답을 반영했으면(`revision`) 오래된 읽기로 덮지 않고 다시 읽는다 (POST 결과 보호)
    /// - 같은 대화의 읽기가 겹치면 **마지막에 시작한 읽기만** 반영한다 (`threadReadSeq`): 늦게 끝난 옛 읽기가 새 읽기를 되돌리지 않는다.
    ///   다른 대화의 읽기는 서로 막지 않는다. 계정이 바뀌었으면 어느 쪽도 반영하지 않는다
    public func loadThread(_ id: UUID) async {
        guard let token = scope.token, conversations.contains(where: { $0.id == id }) else { return }
        let started = tombstoneClock
        let seq = (threadReadSeq[id] ?? 0) + 1
        threadReadSeq[id] = seq
        if threads[id] == nil { threads[id] = ChatThread() }
        if case .loaded = threads[id]?.load ?? .loading {} else { threads[id]?.load = .loading }
        for _ in 0..<3 {
            let revision = threads[id]?.revision ?? 0
            do {
                let messages = try await gateway.messages(conversationID: id)
                guard scope.isCurrent(token), threads[id] != nil, threadReadSeq[id] == seq, !isStale(id, since: started) else { return }
                guard threads[id]?.revision == revision else { continue }
                applyServerMessages(messages, to: id)
                threads[id]?.load = .loaded(problem: nil)
                if let memory { await memory.loadReferenced(ids: messages.flatMap(\.rememberedIDs)) }
                return
            } catch {
                guard scope.isCurrent(token), threadReadSeq[id] == seq, !isStale(id, since: started), let failure = ReadFailure.from(error, online: isOnline), threads[id] != nil else { return }
                if failure == .unavailable {
                    isUnavailable = true
                    threads[id]?.load = .loaded(problem: nil)
                    return
                }
                let hasContent = !(threads[id]?.messages.isEmpty ?? true)
                let problem: WorkLoad.Problem = failure == .offline ? .offline : .failed
                threads[id]?.load = hasContent ? .loaded(problem: problem) : (failure == .offline ? .offline : .failed)
                return
            }
        }
    }

    /// 서버가 사실이다: 읽은 메시지로 바꾼다. 서버에 저장된 글의 보내기 기록은 지운다 (답이 없으면 줄이 Try again을 준다)
    private func applyServerMessages(_ messages: [ChatMessage], to id: UUID) {
        let stored = Set(messages.compactMap(\.clientMessageID))
        threads[id]?.messages = messages
        deriveTitle(for: id)
        threads[id]?.textPurged = conversations.first { $0.id == id }?.textPurgedAt != nil
        // 보내는 중이 아니면서 서버에 이미 저장된 보내기는 기록에서 뺀다 (보내는 중인 것은 응답이 올 때까지 둔다)
        threads[id]?.pending.removeAll { stored.contains($0.id) && $0.status != .sending }
    }

    // MARK: 보내기

    /// 지금 대화에 글을 보낸다. 서버가 확인(200)하기 전에는 "Sending…"이고, 실패하면 같은 글을 Try again으로 다시 보낼 수 있다
    public func send(_ text: String) async {
        guard canCompose, let id = currentID else { return }
        await send(text, in: id)
    }

    /// 한 대화에 글을 보낸다 (Assistant 창). 칩은 이 제출에 실려 같은 제출을 다시 보내도 같다. 에이전트 대상이면 응답은 전달 표시뿐이다
    public func send(_ text: String, in id: UUID, attachments: [ChatAttachment] = []) async {
        guard canCompose(in: id), let token = scope.token, ChatComposerRules.isSendable(text) else { return }
        guard !(threads[id]?.isSending ?? false) else { return }
        let turn = PendingTurn(id: UUID(), text: ChatComposerRules.normalized(text), createdAt: now(), owner: token, status: .sending, attachments: attachments)
        threads[id, default: ChatThread()].pending.append(turn)
        sentChips[turn.id] = attachments
        drafts[id] = nil
        await deliver(turn.id, in: id)
    }

    /// 보내지 못한 글(또는 답이 없는 마지막 글)을 같은 `client_message_id` · 같은 글로 다시 보낸다
    public func retry(_ clientMessageID: UUID) async {
        guard let id = currentID else { return }
        await retry(clientMessageID, in: id)
    }

    public func retry(_ clientMessageID: UUID, in id: UUID) async {
        guard let token = scope.token, !(threads[id]?.isSending ?? false) else { return }
        // 사용자가 직접 다시 시도했다: 꺼짐 안내를 걷고 서버에 다시 묻는다 (아직 꺼져 있으면 다시 404로 알게 된다)
        isUnavailable = false
        if let index = threads[id]?.pending.firstIndex(where: { $0.id == clientMessageID }) {
            guard let old = threads[id]?.pending[index], old.owner == token else { return }
            threads[id]?.pending[index].status = .sending
        } else if let message = threads[id]?.messages.last(where: { $0.role.isUser && $0.clientMessageID == clientMessageID }),
                  !(threads[id]?.messages.contains { $0.replyTo == message.id } ?? true) {
            // 서버에 저장됐지만 답이 없는 마지막 글 (앱을 다시 켠 뒤 포함): 저장된 글 그대로
            threads[id]?.pending.append(PendingTurn(
                id: clientMessageID, text: message.text, createdAt: message.createdAt, owner: token, status: .sending, attachments: sentChips[clientMessageID] ?? []
            ))
        } else {
            return
        }
        await deliver(clientMessageID, in: id)
    }

    /// 기능 꺼짐 안내를 걷고 다시 시도할 수 있게 한다 (Try again): 목록도 다시 읽는다
    public func retryUnavailable() {
        isUnavailable = false
        spawn { await self.refresh() }
    }

    private func deliver(_ turnID: UUID, in conversationID: UUID) async {
        guard let turn = threads[conversationID]?.pending.first(where: { $0.id == turnID }) else { return }
        // 보내기 직전 (다시 보내기 포함): 이 글을 만든 계정 · 세션이 지금도 그대로인가
        guard scope.isCurrent(turn.owner) else { return }
        do {
            if let local = locals.first(where: { $0.id == conversationID }) {
                let first = threads[conversationID]?.pending.map(\.text).first ?? turn.text
                let title = ChatTitle.make(from: first)
                let created: ChatConversation
                switch local.target {
                case .taskforce:
                    created = try await gateway.createConversation(id: conversationID, title: title, contextID: local.contextID)
                case .agent(_, let connectionID):
                    // 연결이 없는 에이전트는 대화를 만들 곳이 없다: 서버를 부르지 않고 이유를 말한다 (대상 메뉴의 "Not connected"와 같은 말)
                    guard let connectionID, let assistant else {
                        if let index = threads[conversationID]?.pending.firstIndex(where: { $0.id == turnID }) {
                            threads[conversationID]?.pending[index].status = .failed(ChatCopy.agentNotConnected)
                        }
                        return
                    }
                    let response = try await assistant.createConversation(
                        id: conversationID, title: title, contextID: local.contextID, target: .agent(connectionID: connectionID)
                    )
                    let row = response.conversation
                    created = ChatConversation(
                        id: row.id, title: row.title, contextID: row.contextID, createdAt: row.createdAt, lastMessageAt: row.lastMessageAt,
                        lastReadAt: row.lastReadAt, archivedAt: row.archivedAt, textPurgedAt: row.textPurgedAt, target: response.target
                    )
                }
                guard scope.isCurrent(turn.owner), threads[conversationID] != nil else { return }
                locals.removeAll { $0.id == conversationID }
                upsert(created)
            }
            guard scope.isCurrent(turn.owner), threads[conversationID]?.pending.contains(where: { $0.id == turnID }) == true else { return }
            if conversationTarget(for: conversationID).isAgent {
                guard let assistant else { return }
                let posted = try await assistant.postAgentMessage(
                    conversationID: conversationID, clientMessageID: turnID, text: turn.text, attachments: turn.attachments
                )
                guard scope.isCurrent(turn.owner) else { return }
                isUnavailable = false
                applyAgent(posted, to: conversationID)
            } else {
                let posted: ChatPostedMessage
                if !turn.attachments.isEmpty, let assistant {
                    posted = try await assistant.postChatMessage(conversationID: conversationID, clientMessageID: turnID, text: turn.text, attachments: turn.attachments)
                } else {
                    posted = try await gateway.postChatMessage(conversationID: conversationID, clientMessageID: turnID, text: turn.text)
                }
                guard scope.isCurrent(turn.owner) else { return }
                isUnavailable = false
                apply(posted, to: conversationID)
                if let memory { await memory.loadReferenced(ids: posted.reply.rememberedIDs) }
            }
        } catch {
            guard scope.isCurrent(turn.owner) else { return }
            await failed(error, turnID: turnID, in: conversationID)
        }
    }

    /// 에이전트 대상 보내기의 응답: 사용자 글 + 전달 표시. 답은 비동기로 대화에 쓰이므로 지금은 `reply`가 없다 (있으면 같이 반영한다).
    /// 두 번 온 응답 · 늦게 온 응답도 메시지 id로 한 번만 반영한다
    private func applyAgent(_ posted: AgentPostedMessage, to id: UUID) {
        guard threads[id] != nil else { return }
        var messages = threads[id]?.messages ?? []
        for message in [posted.message] + (posted.reply.map { [$0] } ?? []) {
            if let index = messages.firstIndex(where: { $0.id == message.id }) {
                messages[index] = message
            } else {
                messages.append(message)
            }
        }
        threads[id]?.messages = messages.sorted { $0.seq < $1.seq }
        deriveTitle(for: id)
        threads[id]?.pending.removeAll { $0.id == posted.message.clientMessageID }
        threads[id]?.revision += 1
        deliveries[posted.message.id] = posted.delivery
        previews[id] = (posted.reply ?? posted.message).text
        touchLastMessage(of: id, at: posted.message.createdAt)
    }

    /// 보낸 글이 서버에 저장됐다: 쥔 행의 마지막 시각을 바꾼다. 내 쓰기도 쥔 행을 바꾼 일이라 반영 시계를 올린다 —
    /// 그 전에 시작한 읽기의 늦은 응답(글이 저장되기 전의 빈 행)은 서버 버전 검사를 다시 받아 이 행을 되돌리지 못한다
    private func touchLastMessage(of id: UUID, at date: Date) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        rowAppliedAt[id] = tickRow()
        let old = conversations[index]
        conversations[index] = ChatConversation(
            id: old.id, title: old.title, contextID: old.contextID, createdAt: old.createdAt, lastMessageAt: date,
            lastReadAt: old.lastReadAt, archivedAt: old.archivedAt, textPurgedAt: old.textPurgedAt, target: old.target
        )
    }

    /// 서버 확인(200): 사용자 글 + 답을 메시지 id로 한 번만 반영한다 (두 번 온 응답 · 늦게 온 응답 · 다른 대화로 옮긴 뒤 온 응답도 같다)
    private func apply(_ posted: ChatPostedMessage, to id: UUID) {
        guard threads[id] != nil else { return }
        var messages = threads[id]?.messages ?? []
        for message in [posted.message, posted.reply] {
            if let index = messages.firstIndex(where: { $0.id == message.id }) {
                messages[index] = message
            } else {
                messages.append(message)
            }
        }
        threads[id]?.messages = messages.sorted { $0.seq < $1.seq }
        deriveTitle(for: id)
        threads[id]?.pending.removeAll { $0.id == posted.message.clientMessageID }
        threads[id]?.revision += 1
        previews[id] = posted.reply.text
        touchLastMessage(of: id, at: posted.message.createdAt)
    }

    /// 이름이 없는 대화는 읽은 첫 사용자 글로 이름을 보인다
    private func deriveTitle(for id: UUID) {
        guard conversations.first(where: { $0.id == id })?.title?.isEmpty ?? true,
              let first = threads[id]?.messages.sorted(by: { $0.seq < $1.seq }).first(where: { $0.role.isUser && !$0.text.isEmpty }),
              let title = ChatTitle.make(from: first.text) else { return }
        derivedTitles[id] = title
    }

    private func upsert(_ conversation: ChatConversation) {
        rowAppliedAt[conversation.id] = tickRow()
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[index] = conversation
        } else {
            conversations.append(conversation)
            stampClock += 1
            rowStamps[conversation.id] = stampClock
        }
    }

    private func failed(_ error: Error, turnID: UUID, in conversationID: UUID) async {
        guard let index = threads[conversationID]?.pending.firstIndex(where: { $0.id == turnID }) else { return }
        guard ReadFailure.from(error, online: isOnline) != nil else {
            // 취소: 보내는 중으로 남기지 않는다 (다시 보낼 수 있게)
            threads[conversationID]?.pending[index].status = .failed(ReadFailure.userMessage(error))
            return
        }
        if let api = error as? APIError {
            if api.isFeatureOff {
                isUnavailable = true
                threads[conversationID]?.pending[index].status = .failed(ChatCopy.unavailable)
                return
            }
            if api.isChatConsentRequired {
                threads[conversationID]?.pending[index].status = .needsConsent
                return
            }
        }
        threads[conversationID]?.pending[index].status = .failed(ReadFailure.userMessage(error))
        // 응답을 못 받았거나(전송 오류) 409(처리 중 · 뒤 메시지 · 다른 글)면 서버는 이미 저장했을 수 있다: 서버가 사실이다 → 읽어서 맞춘다
        let isTransport: Bool = { if case .transport = error as? APIError { true } else { error is URLError } }()
        if isTransport || (error as? APIError)?.isConflict == true, conversations.contains(where: { $0.id == conversationID }) {
            await loadThread(conversationID)
        }
    }

    // MARK: 프로젝트 (명시적 선택)

    /// 헤더 ProjectLink에서 고른 프로젝트 (nil = Ungrouped). 서버 대화면 `PATCH`, 아직 서버에 없는 대화면 만들 때 보낸다. 자동 추정은 없다
    public func chooseProject(_ contextID: UUID?) async {
        guard let id = currentID else { return }
        await chooseProject(contextID, in: id)
    }

    /// 한 대화의 프로젝트 (Assistant 창의 머리 ProjectLink)
    public func chooseProject(_ contextID: UUID?, in id: UUID) async {
        guard let token = scope.token, !isUnavailable else { return }
        projectMessage[id] = nil
        if let index = locals.firstIndex(where: { $0.id == id }) {
            projectUndo[id] = .some(locals[index].contextID)
            locals[index].contextID = contextID
            return
        }
        guard let chat = conversations.first(where: { $0.id == id }), chat.contextID != contextID else { return }
        let writeStart = tickRow()
        let started = tombstoneClock
        do {
            let updated = try await gateway.updateConversation(id: id, contextID: contextID)
            // 쓰는 사이 서버가 없다고 확인한 대화는 이 응답의 행으로 되살리지 않는다 (묘비)
            guard scope.isCurrent(token), !isStale(id, since: started) else { return }
            projectUndo[id] = .some(chat.contextID)
            // 범위를 바꾸는 PATCH 응답은 대상 열을 주지 않을 수 있다: 아는 대상을 지키지 않으면 에이전트 대화가 Taskforce로 보인다
            applyWrite(updated.with(target: chat.target), startedAt: writeStart)
        } catch {
            guard scope.isCurrent(token), ReadFailure.from(error, online: isOnline) != nil else { return }
            if let api = error as? APIError, api.isFeatureOff { isUnavailable = true } else { projectMessage[id] = ReadFailure.userMessage(error) }
        }
    }

    /// 방금 바꾼 프로젝트를 되돌린다 (Undo)
    public func undoProject() async {
        guard let id = currentID else { return }
        await undoProject(in: id)
    }

    public func undoProject(in id: UUID) async {
        guard let previous = projectUndo[id] else { return }
        projectUndo[id] = nil
        await chooseProject(previous, in: id)
        // 되돌리기 자체는 되돌릴 것이 없다
        projectUndo[id] = nil
    }
}
