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
    private var drafts: [UUID: String] = [:]
    var threads: [UUID: ChatThread] = [:]
    private var projectUndo: [UUID: UUID?] = [:]
    private var projectMessage: [UUID: String] = [:]
    /// 사용자가 목록 · 새 대화로 직접 옮겼나 (아니면 목록을 읽은 뒤 마지막 대화로 자동 복원)
    private var navigated = false

    @ObservationIgnored private let gateway: any ChatGateway
    @ObservationIgnored private let scope: AccountScope
    @ObservationIgnored private let memory: MemoryStore?
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var listSequence = 0
    /// 화면 동작이 띄운 읽기들 (테스트가 `settle()`로 기다린다)
    @ObservationIgnored private var background: [Task<Void, Never>] = []

    public init(gateway: any ChatGateway, scope: AccountScope, memory: MemoryStore? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.gateway = gateway
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
        drafts = [:]
        threads = [:]
        projectUndo = [:]
        projectMessage = [:]
        navigated = false
    }

    public func pathChanged(online: Bool) {
        isOnline = online
    }

    // MARK: 보이는 것

    public var entries: [ChatListEntry] {
        ChatHistoryRules.entries(conversations: conversations, locals: locals, previews: previews, drafts: drafts)
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
    public var screen: ChatScreen {
        guard let id = currentID else { return .blank }
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
        currentID.flatMap { threads[$0] }?.pending.contains { $0.status == .needsConsent } ?? false
    }

    public func draft(for id: UUID) -> String { drafts[id] ?? "" }

    public func setDraft(_ text: String, for id: UUID) {
        guard scope.token != nil else { return }
        drafts[id] = text.isEmpty ? nil : text
    }

    /// 지금 대화의 줄들 (서버가 확인한 메시지 + 아직 확인하지 않은 보내기)
    public func turns(for id: UUID) -> [ChatTurn] {
        guard let thread = threads[id] else { return [] }
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
                } else if !messages.contains(where: { $0.replyTo == message.id }) {
                    let hasLater = messages[(index + 1)...].contains { $0.role.isUser }
                    status = hasLater || message.clientMessageID == nil ? .notAnswered : .noReply
                }
                turns.append(ChatTurn(
                    id: message.id, isUser: true, text: message.text, createdAt: message.createdAt, status: status,
                    clientMessageID: message.clientMessageID, citations: [], rememberedIDs: [], textDeleted: deleted
                ))
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

    public func showHistory() {
        navigated = true
        mode = .history
    }

    public func open(_ id: UUID) {
        guard conversations.contains(where: { $0.id == id }) || locals.contains(where: { $0.id == id }) else { return }
        navigated = true
        currentID = id
        mode = .chat
        spawn { await self.loadThread(id) }
    }

    /// 새 대화 (⌘N · square-pen): 손대지 않은 빈 대화가 있으면 그것을 다시 쓴다. 없으면 서버에 아직 없는 빈 대화를 메모리에 만든다
    /// (첫 메시지를 보낼 때 서버에 만든다)
    @discardableResult
    public func newChat() -> UUID {
        navigated = true
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

    // MARK: 읽기

    /// 목록 · 열린 대화를 서버에서 읽는다 (Chats를 열 때 · Try again · 온라인으로 돌아왔을 때)
    public func refresh() async {
        guard let token = scope.token else { return }
        listSequence += 1
        let sequence = listSequence
        if case .loaded = listLoad {} else { listLoad = .loading }
        do {
            async let rows = gateway.conversations()
            async let projects = gateway.workContexts()
            let (chats, named) = try await (rows, projects)
            guard scope.isCurrent(token), sequence == listSequence else { return }
            conversations = chats.filter { $0.archivedAt == nil }
            contexts = Dictionary(named.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            listLoad = .loaded(problem: nil)
            dropThreads(missingFrom: Set(chats.map(\.id)))
            if currentID == nil, !navigated, let latest = entries.first(where: { !$0.isLocal }) {
                // 마지막 대화로 되살린다 (앱을 다시 켠 뒤)
                currentID = latest.id
                mode = .chat
            }
            await loadPreviews(token: token)
            if let id = currentID, conversations.contains(where: { $0.id == id }) { await loadThread(id) }
        } catch {
            guard scope.isCurrent(token), sequence == listSequence, let failure = ReadFailure.from(error, online: isOnline) else { return }
            if case .loaded = listLoad {
                listLoad = .loaded(problem: failure == .offline ? .offline : .failed)
            } else {
                listLoad = failure == .offline ? .offline : .failed
            }
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

    private func loadPreviews(token: AccountScope.Token) async {
        let ids = conversations.filter { !$0.isUntouched }.map(\.id)
        guard !ids.isEmpty, let last = try? await gateway.lastMessages(conversationIDs: ids), scope.isCurrent(token) else { return }
        var next: [UUID: String] = [:]
        for (id, message) in last { next[id] = message.text }
        previews = next
    }

    /// 한 대화의 메시지를 읽는다. 읽는 사이 로컬에서 응답을 반영했으면(`revision`) 오래된 읽기로 덮지 않고 다시 읽는다
    public func loadThread(_ id: UUID) async {
        guard let token = scope.token, conversations.contains(where: { $0.id == id }) else { return }
        if threads[id] == nil { threads[id] = ChatThread() }
        if case .loaded = threads[id]?.load ?? .loading {} else { threads[id]?.load = .loading }
        for _ in 0..<3 {
            let revision = threads[id]?.revision ?? 0
            do {
                let messages = try await gateway.messages(conversationID: id)
                guard scope.isCurrent(token), threads[id] != nil else { return }
                guard threads[id]?.revision == revision else { continue }
                applyServerMessages(messages, to: id)
                threads[id]?.load = .loaded(problem: nil)
                if let memory { await memory.loadReferenced(ids: messages.flatMap(\.rememberedIDs)) }
                return
            } catch {
                guard scope.isCurrent(token), let failure = ReadFailure.from(error, online: isOnline), threads[id] != nil else { return }
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
        threads[id]?.textPurged = conversations.first { $0.id == id }?.textPurgedAt != nil
        // 보내는 중이 아니면서 서버에 이미 저장된 보내기는 기록에서 뺀다 (보내는 중인 것은 응답이 올 때까지 둔다)
        threads[id]?.pending.removeAll { stored.contains($0.id) && $0.status != .sending }
    }

    // MARK: 보내기

    /// 지금 대화에 글을 보낸다. 서버가 확인(200)하기 전에는 "Sending…"이고, 실패하면 같은 글을 Try again으로 다시 보낼 수 있다
    public func send(_ text: String) async {
        guard canCompose, let id = currentID, let token = scope.token, ChatComposerRules.isSendable(text) else { return }
        guard !(threads[id]?.isSending ?? false) else { return }
        let turn = PendingTurn(id: UUID(), text: ChatComposerRules.normalized(text), createdAt: now(), owner: token, status: .sending)
        threads[id, default: ChatThread()].pending.append(turn)
        drafts[id] = nil
        await deliver(turn.id, in: id)
    }

    /// 보내지 못한 글(또는 답이 없는 마지막 글)을 같은 `client_message_id` · 같은 글로 다시 보낸다
    public func retry(_ clientMessageID: UUID) async {
        guard let id = currentID, let token = scope.token, !isUnavailable, !(threads[id]?.isSending ?? false) else { return }
        if let index = threads[id]?.pending.firstIndex(where: { $0.id == clientMessageID }) {
            guard let old = threads[id]?.pending[index], old.owner == token else { return }
            threads[id]?.pending[index].status = .sending
        } else if let message = threads[id]?.messages.last(where: { $0.role.isUser && $0.clientMessageID == clientMessageID }),
                  !(threads[id]?.messages.contains { $0.replyTo == message.id } ?? true) {
            // 서버에 저장됐지만 답이 없는 마지막 글 (앱을 다시 켠 뒤 포함): 저장된 글 그대로
            threads[id]?.pending.append(PendingTurn(id: clientMessageID, text: message.text, createdAt: message.createdAt, owner: token, status: .sending))
        } else {
            return
        }
        await deliver(clientMessageID, in: id)
    }

    /// 기능 꺼짐 안내를 걷고 다시 시도할 수 있게 한다 (Try again)
    public func retryUnavailable() {
        isUnavailable = false
    }

    private func deliver(_ turnID: UUID, in conversationID: UUID) async {
        guard let turn = threads[conversationID]?.pending.first(where: { $0.id == turnID }) else { return }
        // 보내기 직전 (다시 보내기 포함): 이 글을 만든 계정 · 세션이 지금도 그대로인가
        guard scope.isCurrent(turn.owner) else { return }
        do {
            if let local = locals.first(where: { $0.id == conversationID }) {
                let first = threads[conversationID]?.pending.map(\.text).first ?? turn.text
                let created = try await gateway.createConversation(id: conversationID, title: ChatTitle.make(from: first), contextID: local.contextID)
                guard scope.isCurrent(turn.owner), threads[conversationID] != nil else { return }
                locals.removeAll { $0.id == conversationID }
                upsert(created)
            }
            guard scope.isCurrent(turn.owner), threads[conversationID]?.pending.contains(where: { $0.id == turnID }) == true else { return }
            let posted = try await gateway.postChatMessage(conversationID: conversationID, clientMessageID: turnID, text: turn.text)
            guard scope.isCurrent(turn.owner) else { return }
            isUnavailable = false
            apply(posted, to: conversationID)
            if let memory { await memory.loadReferenced(ids: posted.reply.rememberedIDs) }
        } catch {
            guard scope.isCurrent(turn.owner) else { return }
            await failed(error, turnID: turnID, in: conversationID)
        }
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
        threads[id]?.pending.removeAll { $0.id == posted.message.clientMessageID }
        threads[id]?.revision += 1
        previews[id] = posted.reply.text
        if let index = conversations.firstIndex(where: { $0.id == id }) {
            let old = conversations[index]
            conversations[index] = ChatConversation(
                id: old.id, title: old.title, contextID: old.contextID, createdAt: old.createdAt, lastMessageAt: posted.message.createdAt,
                lastReadAt: old.lastReadAt, archivedAt: old.archivedAt, textPurgedAt: old.textPurgedAt
            )
        }
    }

    private func upsert(_ conversation: ChatConversation) {
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[index] = conversation
        } else {
            conversations.append(conversation)
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
        guard let id = currentID, let token = scope.token, !isUnavailable else { return }
        projectMessage[id] = nil
        if let index = locals.firstIndex(where: { $0.id == id }) {
            projectUndo[id] = .some(locals[index].contextID)
            locals[index].contextID = contextID
            return
        }
        guard let chat = conversations.first(where: { $0.id == id }), chat.contextID != contextID else { return }
        do {
            let updated = try await gateway.updateConversation(id: id, contextID: contextID)
            guard scope.isCurrent(token) else { return }
            projectUndo[id] = .some(chat.contextID)
            upsert(updated)
        } catch {
            guard scope.isCurrent(token), ReadFailure.from(error, online: isOnline) != nil else { return }
            if let api = error as? APIError, api.isFeatureOff { isUnavailable = true } else { projectMessage[id] = ReadFailure.userMessage(error) }
        }
    }

    /// 방금 바꾼 프로젝트를 되돌린다 (Undo)
    public func undoProject() async {
        guard let id = currentID, let previous = projectUndo[id] else { return }
        projectUndo[id] = nil
        await chooseProject(previous)
        // 되돌리기 자체는 되돌릴 것이 없다
        projectUndo[id] = nil
    }
}
