import Foundation
import Observation

/// Assistant 창 하나의 상태 (OA U1): 창 하나 = 대화 하나. 대화 · 칩 · 대상 · History/대화 본문 · 새 대화.
/// - 글 · 초안 · 보내기는 모두 공유 `ChatStore`에 **대화 id로** 둔다: 창이 여럿이어도 서로의 대화 · 초안 · 칩을 건드리지 않는다
/// - 대상은 대화마다다: 첫 메시지를 보내기 전에는 고를 수 있고, 보낸 뒤에 다른 대상을 고르면 같은 칩을 가진 **새 대화**로 이 창이 바뀐다 (앞 대화는 History에 남는다)
/// - 창이 어느 대화를 보이는지의 관리(상한 · 같은 대화 재사용 · 위치)는 `AssistantWindowRegistry`다. 이 모델은 `rebind`로 묻고 답을 따른다
@MainActor
@Observable
public final class AssistantWindowModel: Identifiable {
    public enum Mode: Equatable, Sendable {
        case chat, history
    }

    public let id: UUID
    public private(set) var conversationID: UUID
    public private(set) var mode: Mode = .chat
    public private(set) var chips = AssistantChipSet()
    /// 입력을 끄는 이유를 직접 정한다 (nil = 정하지 않음, 빈 글 = 기본 문구). 비밀 질문이 열린 대화는 `questions`가 대신 끈다 (아래 `blockedReason`)
    public var blocked: String?
    /// 입력칸이 포커스를 가져가야 할 때마다 오른다 (창을 ⌘3 · ⌘N으로 열 때 · 새 대화)
    public private(set) var focusRequest = 0

    public typealias ReferentMenu = AgentReferentMenu

    /// 열린 후보 고르기 메뉴 (OA D4a-06). 줄 동작(Send again · 후보 · View full)은 `AgentTurnDesk`가 하고 세션 패널과 같이 쓴다
    public var referentMenu: AgentReferentMenu? { desk.referentMenu }
    @ObservationIgnored public let desk: AgentTurnDesk
    /// 에이전트 대화의 Stop · 세션 읽기 (OA D4a-13). 없으면 Stop이 없다 (실제 연결이 없는 런타임 · 견본)
    @ObservationIgnored public var agent: AssistantAgentSupport?

    /// 에이전트의 열린 질문 (OA D4b-m-1): Assistant 창과 세션 패널이 같은 상태를 본다. 없으면 질문 카드가 없다 (견본 · 시험용 가짜 연결)
    @ObservationIgnored public var questions: AgentQuestionStore?

    /// 이 대화가 보내기 전에 고른 작업 폴더를 지운다 (사용자 결정 2026-10-21 · 코드 검토 2026-10-22). 창이 알리는 일만 한다 — 폴더 등록부는 앱의 것이다 (`ChatRuntime.wireFolders`가 잇는다).
    /// 불리는 때: ① 빈 대화의 대상이 바뀌었다 (그 폴더는 옛 대상의 Mac의 것이다) ② 새로 내주는(다시 쓰이는) 빈 대화 ③ 창이 떠나는 빈 새 대화 (버려진 것) ④ 폴더를 적은 새 대화로 창이 못 옮겨 갔다
    @ObservationIgnored public var forgetFolder: (UUID) -> Void = { _ in }

    /// 머리 폴더 메뉴의 "New chat in another folder…"가 실패했을 때의 인라인 한 줄 (이 대화의 것: 다른 대화로 가면 사라진다). 없으면 nil
    public private(set) var folderNoticeText: String?

    @ObservationIgnored let chat: ChatStore
    @ObservationIgnored let targets: AssistantTargetsStore
    @ObservationIgnored private let openElsewhere: () -> Set<UUID>
    @ObservationIgnored private let rebindHandler: (UUID) -> AssistantWindowRegistry.RebindOutcome

    /// - openElsewhere: 다른 창이 보이는 대화들 (새 대화가 그중 하나를 다시 쓰지 않게)
    /// - rebind: 이 창이 다른 대화로 바뀌어도 되는지 레지스트리에 묻는다 (다른 창이 이미 보이면 그 창이 앞으로 가고 이 창은 그대로)
    public init(
        id: UUID = UUID(), conversationID: UUID, chat: ChatStore, targets: AssistantTargetsStore,
        openElsewhere: @escaping () -> Set<UUID> = { [] },
        rebind: @escaping (UUID) -> AssistantWindowRegistry.RebindOutcome = { _ in .rebound }
    ) {
        self.id = id
        self.conversationID = conversationID
        self.chat = chat
        self.targets = targets
        self.openElsewhere = openElsewhere
        rebindHandler = rebind
        desk = AgentTurnDesk(chat: chat)
        chat.ensureLoaded(conversationID)
    }

    // MARK: 보이는 것

    /// 이 대화의 대상 (서버 대화의 에이전트는 연결만 안다)
    public var pick: AssistantTargetPick { chat.pick(for: conversationID) }
    public var toAgent: Bool { pick.isAgent }

    /// 대상 목록에서 이 대화의 행 (목록에 없으면 nil: 꺼진 adapter · 지운 연결 · 아직 못 읽음)
    public var option: AssistantTargetOption? { targets.option(for: pick) }

    /// 대상 알약의 이름
    public var targetName: String {
        option?.name ?? (toAgent ? AgentMarkKind.placeholder.accessibilityName : AssistantTargetRules.taskforceName)
    }

    public var targetMark: AgentMarkKind {
        option?.mark ?? (toAgent ? .placeholder : .taskforce)
    }

    /// 머리 제목: 대화 이름, History면 Chat history. 이름 없는 새 대화는 New chat
    public var title: String {
        mode == .history ? ChatCopy.historyTitle : chat.title(for: conversationID)
    }

    /// 입력을 끄는 이유 (nil = 열려 있음, 빈 글 = 기본 문구 "Answer the question above first"): 직접 정한 이유가 먼저, 아니면 이 대화의 세션에 비밀값 질문이 열려 있을 때 (D4bm-42).
    /// 자유 글이 비밀값의 답이 되는 길은 없다 — 입력창을 끄고, 서버도 막는다
    public var blockedReason: String? {
        if let blocked { return blocked }
        guard toAgent, let session = chat.agentSessionID(for: conversationID), questions?.blocksComposer(session: session) == true else { return nil }
        return ""
    }

    public var isBlocked: Bool { blockedReason != nil }

    /// 이 대화의 세션 (질문이 이 세션에 열린다). 아직 세션이 없는 대화는 nil
    public var sessionID: UUID? { toAgent ? chat.agentSessionID(for: conversationID) : nil }

    // MARK: 에이전트 대화 (OA D4a-1)

    /// 전달 줄을 옮기는 데 쓰는 사실: 에이전트 이름 · 이 대화 연결의 대상 상태(Mac is offline)
    public var deliveryContext: AgentDeliveryContext {
        AgentDeliveryContext(agentName: option?.name, targetState: pick.connectionID.flatMap(targets.targetState(forConnection:)))
    }

    /// 한 줄. 에이전트가 아니거나 전달 표시를 아직 읽지 못했거나 줄이 없는 상태면 nil
    public func deliveryLine(for turn: ChatTurn) -> MessageDeliveryLine? {
        guard toAgent else { return nil }
        return desk.line(for: turn, context: deliveryContext)
    }

    public func canSendAgain(_ turn: ChatTurn) -> Bool {
        toAgent && desk.canSendAgain(turn, in: conversationID)
    }

    /// Send again (서버 메시지 id)
    public func sendAgain(_ turn: ChatTurn) async {
        guard toAgent else { return }
        await desk.sendAgain(turn, in: conversationID)
    }

    /// Try again (Send again · 후보 고르기가 거절되거나 막혔을 때의 오류 줄 · 동의 안내)
    public func retryDelivery(_ turn: ChatTurn) async {
        guard toAgent else { return }
        await desk.retry(turn, in: conversationID)
    }

    public func openReferentMenu(for messageID: UUID) {
        desk.openReferentMenu(for: messageID)
    }

    public func closeReferentMenu() {
        desk.closeReferentMenu()
    }

    /// 후보 하나를 고른다 (`POST …/referent`): 메뉴는 닫힌다
    public func chooseReferent(_ actionID: UUID) async {
        await desk.chooseReferent(actionID, in: conversationID)
    }

    public func viewFull(_ turn: ChatTurn) {
        desk.viewFull(turn)
    }

    /// 이 대화의 세션 (좁게 읽은 값, 아직 읽기 전이면 nil)
    public var sessionItem: AgentSessionItem? {
        guard toAgent, let id = chat.agentSessionID(for: conversationID) else { return nil }
        return agent?.sessions.item(id: id)
    }

    /// 보내기 원이 Stop인가 · Stop 뒤 말 (D4a-13 표)
    public var stopPresentation: AgentStopRules.Presentation {
        agent?.stop.presentation(session: sessionItem) ?? AgentStopRules.Presentation(showsStop: false, line: nil)
    }

    /// 대화 끝에 이벤트 줄 모양으로 보이는 Stop 말 (D4a-14)
    public var stopLineText: String? { stopPresentation.line?.text }

    /// Stop: `POST /api/v2/conversations/{id}/stop`. 두 번 눌러도 한 번
    public func stop() async {
        guard toAgent, let agent else { return }
        await agent.stop.stopConversation(conversationID, session: sessionItem)
    }

    /// 손대지 않은 새 창: 서버에 없는 빈 대화에 쓴 글 · 칩 · 입력이 없다 (⌘3으로 막 연 창이 목록을 읽은 뒤 마지막 대화로 되살려져도 되는가)
    public var isPristine: Bool {
        mode == .chat && chat.isLocalChat(conversationID) && !chat.hasMessages(conversationID) && draft.isEmpty && chips.chips.isEmpty && !isBlocked
            && pick == .taskforce
    }

    public var placeholder: String {
        AssistantPromptRules.placeholder(chips: chips.chips, target: pick, targetName: targetName, blocked: blockedReason)
    }

    /// 빈 대화(칩 + 프롬프트뿐): 창 높이의 바닥 440이 걸린다. History 본문은 아니다
    public var isEmptyConversation: Bool {
        mode == .chat && !chat.hasMessages(conversationID)
    }

    public var draft: String { chat.draft(for: conversationID) }

    public func setDraft(_ text: String) {
        chat.setDraft(text, for: conversationID)
    }

    public var canSend: Bool { canSend(draft) }

    public func canSend(_ text: String) -> Bool {
        !isBlocked && chat.canSend(text, in: conversationID)
    }

    public func chipLabel(_ chip: AssistantChip) -> String {
        chips.label(for: chip, toAgent: toAgent)
    }

    public var historyEntries: [ChatListEntry] { chat.entries }

    /// History 줄의 마크: 에이전트 대화에만 (연결의 adapter로, 모르면 점선 사각형). Taskforce 대화는 nil
    public func mark(for entry: ChatListEntry) -> AgentMarkKind? {
        guard entry.target.isAgent else { return nil }
        if let adapter = entry.localAdapter { return AgentMarkKind.of(adapter: adapter) }
        return entry.target.agentConnectionID.map(targets.mark(forConnection:)) ?? .placeholder
    }

    // MARK: 칩

    /// 패널에서 열린 항목을 auto 칩이 따라간다
    public func followOpenItem(_ item: AssistantChip?) {
        chips.follow(item)
    }

    public func addChip(_ chip: AssistantChip) {
        chips.add(chip)
    }

    /// 에이전트 대상에서 auto 칩을 눌렀다: added가 된다 (D4a-12). Taskforce 대상에서는 바뀌지 않는다 (보낸 뒤에야 added가 된다)
    public func promoteChip(_ chipID: String) {
        guard toAgent else { return }
        chips.promote(chipID)
    }

    public func removeChip(_ chipID: String) {
        chips.remove(chipID)
    }

    // MARK: 보내기

    /// 글을 보낸다. 칩은 보내는 순간의 그대로 실린다 (auto는 origin auto로). 보낸 뒤 Taskforce 대상이면 auto 칩이 added로 남고, 에이전트 대상이면 auto 그대로다
    public func send(_ text: String) async {
        guard canSend(text) else { return }
        let attachments = chips.attachments
        let agentTarget = toAgent
        chips.didSend(toAgent: agentTarget)
        await chat.send(text, in: conversationID, attachments: attachments)
        // 에이전트에게 보냈다: 턴이 시작됐을 수 있다 — 이 대화의 세션을 다시 읽어 Stop 원이 서게 한다
        if agentTarget { await agent?.sessions.refresh() }
    }

    // MARK: 대상

    /// 대상 알약 메뉴에서 고름. 첫 메시지 전의 대화는 대상만 바뀌고, 글이 있는(또는 서버에 있는) 대화는 같은 칩을 가진 새 대화로 이 창이 바뀐다
    public func chooseTarget(_ option: AssistantTargetOption) {
        let wanted = option.pick
        guard !pick.isSame(as: wanted) else { return }
        let current = conversationID
        if chat.isLocalChat(current), !chat.hasMessages(current) {
            chat.setLocalTarget(wanted, for: current)
            // 이 빈 대화가 고른 폴더는 옛 대상의 것이다 (다른 Mac의 에이전트로 바꾸면 이 Mac의 폴더가 그 대화에 남으면 안 된다)
            forgetFolder(current)
            return
        }
        let text = chat.draft(for: current)
        // 쓰던 글이 남은 다른 대화는 다시 쓰지 않는다: 이 창의 글이 따라오며 그 글을 덮는다
        let fresh = chat.reserveNewChat(target: wanted, excluding: openElsewhere().union([current]).union(chat.draftConversationIDs))
        forgetFolder(fresh)
        guard case .rebound = rebindHandler(fresh) else { return }
        conversationID = fresh
        folderNoticeText = nil
        mode = .chat
        // 쓰던 글은 새 대화로 따라온다 (대상 바꾸기가 쓰던 글을 버리지 않는다)
        if !text.isEmpty {
            chat.setDraft(text, for: fresh)
            chat.setDraft("", for: current)
        }
        chat.ensureLoaded(fresh)
        requestFocus()
    }

    // MARK: 새 대화 · History

    /// SquarePen: 같은 창에서 새 대화 (Taskforce가 기본 대상, 칩은 비운다). 손대지 않은 빈 대화는 다시 쓴다
    public func newChat() {
        mode = .chat
        let fresh = chat.reserveNewChat(target: .taskforce, excluding: openElsewhere())
        // 다시 쓰이는 빈 대화에 옛 폴더가 남아 있을 수 있다 (새 대화는 폴더 없이 시작한다)
        forgetFolder(fresh)
        if fresh != conversationID {
            guard case .rebound = rebindHandler(fresh) else { return }
            let left = conversationID
            conversationID = fresh
            folderNoticeText = nil
            chips = AssistantChipSet()
            abandonIfEmptyLocal(left)
        }
        requestFocus()
    }

    /// 창이 떠난 빈 새 대화(서버에 없고 글이 없다)에 적힌 폴더는 버린다: 아무도 쓰지 않을 항목이 등록부에 남지 않게. 보낸 대화의 폴더(세션 핀의 기록)는 건드리지 않는다
    private func abandonIfEmptyLocal(_ id: UUID) {
        if chat.isLocalChat(id), !chat.hasMessages(id) { forgetFolder(id) }
    }

    /// 폴더 메뉴가 실패한 일을 이 대화에 한 줄로 보인다 (승인된 글만: 부르는 쪽이 정한다)
    public func showFolderNotice(_ text: String) {
        folderNoticeText = text
    }

    public func clearFolderNotice() {
        folderNoticeText = nil
    }

    /// 대화 머리 폴더 메뉴의 "New chat in another folder…" (사용자 결정 2026-10-21): 같은 에이전트의 **새 대화**를 이 창에 연다. Claude 세션의 폴더는 세션을 연 뒤 바뀌지 않으므로
    /// 다른 폴더는 새 대화로 연다 — 이 대화는 글 · 초안 · 폴더 모두 그대로다 (초안도 따라오지 않는다).
    /// `bindFolder`가 새 대화 id에 고른 폴더를 적는다: **던지면 아무것도 바꾸지 않는다** (새 대화는 서버에 없는 빈 대화라 남아도 다음 새 대화가 다시 쓴다).
    /// 쓰던 글이 있는 대화 · 다른 창이 보이는 대화 · 이 대화는 다시 쓰지 않는다. 이미 세션이 있는 대화(서버의 빈 대화를 다시 쓰게 된 경우)에는 폴더를 적지 않는다 — 그 세션의 폴더는 핀이다.
    /// 폴더를 적은 뒤 창이 못 옮겨 가면 그 폴더를 지운다 (새 대화에 고아로 남지 않게). 옮겨 갔으면 떠나는 빈 새 대화의 폴더도 버린다.
    /// 연 뒤는 `newChat()`처럼 칩을 비우고 입력칸에 포커스를 준다. 열었으면 true
    @discardableResult
    public func startAgentChat(bindFolder: (UUID) throws -> Void) -> Bool {
        guard toAgent else { return false }
        let current = conversationID
        let fresh = chat.reserveNewChat(target: option?.pick ?? pick, excluding: openElsewhere().union([current]).union(chat.draftConversationIDs))
        guard chat.agentSessionID(for: fresh) == nil else { return false }
        do { try bindFolder(fresh) } catch { return false }
        guard case .rebound = rebindHandler(fresh) else {
            forgetFolder(fresh)
            return false
        }
        conversationID = fresh
        folderNoticeText = nil
        mode = .chat
        chips = AssistantChipSet()
        chat.ensureLoaded(fresh)
        requestFocus()
        abandonIfEmptyLocal(current)
        return true
    }

    public func toggleHistory() {
        if mode == .chat {
            mode = .history
            chat.refreshInBackground()
        } else {
            mode = .chat
            requestFocus()
        }
    }

    /// History에서 대화를 연다. 그 대화를 다른 창이 이미 보이면 그 창이 앞으로 가고 이 창은 그대로다
    public func openConversation(_ id: UUID) {
        if id == conversationID {
            mode = .chat
            requestFocus()
            return
        }
        guard case .rebound = rebindHandler(id) else { return }
        let left = conversationID
        conversationID = id
        folderNoticeText = nil
        mode = .chat
        chips = AssistantChipSet()
        chat.ensureLoaded(id)
        requestFocus()
        abandonIfEmptyLocal(left)
    }

    /// Esc: 열린 후보 메뉴 → 안쪽(History)을 먼저 닫는다. 처리했으면 true — 아니면 창이 숨는다
    public func escapeInner() -> Bool {
        if referentMenu != nil {
            desk.closeReferentMenu()
            return true
        }
        guard mode == .history else { return false }
        mode = .chat
        requestFocus()
        return true
    }

    public func requestFocus() {
        focusRequest += 1
    }
}

/// Assistant 창이 에이전트 대화에서 쓰는 것 (OA D4a-13): Stop 요청 저장소와 열린 대화의 세션을 좁게 읽는 저장소
public struct AssistantAgentSupport {
    public let stop: AgentStopStore
    public let sessions: AgentSessionStore

    public init(stop: AgentStopStore, sessions: AgentSessionStore) {
        self.stop = stop
        self.sessions = sessions
    }
}
