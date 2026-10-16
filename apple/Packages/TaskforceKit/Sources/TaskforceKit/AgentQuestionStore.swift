import CryptoKit
import Foundation
import Observation

// OA D4b-m-1 (계약 2.1-1 · 4.3 · 5장): 에이전트의 열린 질문 상태 한 곳. Assistant 창과 세션 패널이 **같은 상태**를 본다 (D4bm-26: 한 쪽에서 고르면 다른 쪽도 같은 접힌 줄이 되고 요청은 하나다).
// - 읽기: 세션 저장소가 읽은 세션 중 `awaiting_answer`인 것(과 카드가 있는 것)의 질문을 RLS로 읽는다. 마지막에 시작한 읽기만 반영한다 (U2 12.1). 읽기가 실패하면 앞 카드를 그대로 둔다.
//   카드를 치우는 것은 질문 읽기(서버)뿐이다: 세션 읽기 하나가 카드를 지우지 않는다.
// - DEC-5 (D4bm-20): 고르는 순간 카드가 접히고(`holding`) 2.0초 뒤에 보낸다. Undo면 서버 호출 0. 보내기 시작부터는 Undo가 없다. 보류는 화면이 아니라 이 상태에 있다 (창 닫기 · 패널 접기는 취소가 아니다).
// - 실패는 카드가 돌아오는 것이다 (4.3 표). 계정이 떠나면 보류 · 질문 상태 · 비밀값을 버리고 늦은 응답도 버린다 (D4bm-23). 종료 때는 비밀값이 아닌 답을 곧바로 보내고 비밀값은 버린다 (D4bm-22).
// - 비밀값(D4bm-43 · 45)은 이 Mac의 `LocalSecretAnswerSubmitting`으로만 간다: 서버 요청에 실리지 않고, 접힌 줄에 보이지 않고, 상태 덤프에 나오지 않는다 (`SecretBox`).
// 질문 글 · 답은 사용자 데이터라 메모리에만 두고 로그에 남기지 않는다 (로그는 코드 이름뿐).

/// 새 질문이 열렸다 (알림의 재료): 글은 싣지 않는다
public struct AgentQuestionOpened: Sendable, Equatable {
    public let key: AgentQuestionKey
    public let sessionID: UUID
    public let agentName: String

    public init(key: AgentQuestionKey, sessionID: UUID, agentName: String) {
        self.key = key
        self.sessionID = sessionID
        self.agentName = agentName
    }
}

@MainActor
@Observable
public final class AgentQuestionStore {
    public typealias Sleep = @Sendable (TimeInterval) async -> Void

    /// 보류 시간 (DEC-5): 고른 뒤 이만큼 기다렸다가 보낸다
    public static let holdSeconds: TimeInterval = 2.0
    /// 종료 때 보낸 답을 기다리는 한도
    public static let quitWait: TimeInterval = 3.0

    public enum Phase: Equatable, Sendable {
        /// 카드가 열려 있다 (실패 줄이 붙을 수 있다)
        case open
        /// 고른 답이 접혀 있다: "Answer sent" + 고른 답 + Undo. 아직 보내지 않았다
        case holding
        /// 보내는 중: 접힌 줄, Undo 없음
        case sending
        /// 서버가 받았다: 접힌 줄, Undo 없음 (질문이 읽기에서 사라지거나 서버 사건 줄이 오면 치운다)
        case sent
    }

    /// 세션 하나의 열린 질문 (한 세션에 열린 질문은 많아야 하나)
    public struct Entry {
        public let sessionID: UUID
        public internal(set) var question: AgentPendingQuestion
        public internal(set) var context: AgentQuestionContext
        /// 단계마다 카드 하나 (여러 질문이면 한 번에 하나)
        public internal(set) var cards: [AgentQuestionCard]
        public internal(set) var conversationID: UUID?
        public internal(set) var step = 0
        public internal(set) var phase: Phase = .open
        /// 접힌 줄의 "고른 답" (비밀값이면 nil)
        public internal(set) var summary: String?
        public internal(set) var failure: AgentQuestionFailure?
        /// 다중 선택에서 체크한 줄
        public internal(set) var checked: Set<Int> = []
        /// Other 줄이 입력 칸으로 열려 있다
        public internal(set) var otherOpen = false
        /// 마지막으로 보낸 입력 글 (실패 · Undo 뒤 다시 보이게). 비밀값은 여기에 없다
        public internal(set) var otherText = ""
        /// 이 질문이 열릴 때의 포커스 요청 수: 그 뒤에 온 요청만 이 질문의 카드가 받는다 (`pendingFocusRequests`)
        public internal(set) var focusBaseline = 0

        /// 지금 단계의 카드
        public var card: AgentQuestionCard { cards[min(step, cards.count - 1)] }
        public var key: AgentQuestionKey { question.key }
    }

    /// 세션 id → 열린 질문
    public private(set) var entries: [UUID: Entry] = [:]
    /// 이 Mac의 bridge id (모르면 nil → 다른 기기로 본다). 바뀌면 카드를 다시 정한다
    @ObservationIgnored public var thisMacBridgeID: UUID? {
        didSet { if thisMacBridgeID != oldValue { rebuildContexts() } }
    }
    /// 이 Mac의 bridge id를 읽는 길 (앱이 `BridgeHost`에 잇는다). 읽기 앞에 한 번 부른다
    @ObservationIgnored public var thisMacProvider: (@MainActor () async -> UUID?)?
    /// 새 질문이 이 Mac의 세션에서 열렸다 (version마다 한 번)
    @ObservationIgnored public var onOpened: (@MainActor (AgentQuestionOpened) -> Void)?
    /// 질문이 바뀌었거나 답이 갔거나 닫혔다: 그 알림을 지운다
    @ObservationIgnored public var onClosed: (@MainActor ([AgentQuestionKey]) -> Void)?
    /// 서버가 답을 받았다 (세션 · 그 세션의 대화): 대화를 다시 읽어 서버 사건 줄이 보이게 한다
    @ObservationIgnored public var onAnswered: (@MainActor (UUID, UUID?) -> Void)?

    /// 포커스를 카드로 옮기라는 요청 횟수 (세션마다). 링 · 알림으로 세션이 열릴 때, 보낸 글이 `question_open`으로 대기열에 들어갈 때 오른다
    public private(set) var focusRequests: [UUID: Int] = [:]

    @ObservationIgnored private let gateway: (any AgentQuestionGateway)?
    @ObservationIgnored private let scope: AccountScope
    @ObservationIgnored private let secrets: (any LocalSecretAnswerSubmitting)?
    @ObservationIgnored private let sleep: Sleep
    @ObservationIgnored private let log: @Sendable (String) -> Void
    /// 마지막으로 본 세션 항목 (이름 · 연결의 Mac · 대화)
    @ObservationIgnored private var sessions: [UUID: AgentSessionItem] = [:]
    @ObservationIgnored private var collected: [UUID: Collected] = [:]
    @ObservationIgnored private var holds: [UUID: Task<Void, Never>] = [:]
    /// 보내는 중인 전송들: 전송마다 자기 표(id)로 등록하고 자기가 등록한 것만 지운다 (이전 전송의 늦은 끝이 새 전송의 종료 기다림을 지우지 않게)
    @ObservationIgnored private var sendTasks: [UUID: Task<Void, Never>] = [:]
    /// 질문이 열리기 전에 온 포커스 요청이 있는 세션 (그 질문의 카드가 받는다)
    @ObservationIgnored private var focusBeforeEntry: Set<UUID> = []
    /// 읽는 중인 일의 수와 `settle()`을 기다리는 쪽 (읽기 · 이름 읽기)
    @ObservationIgnored private var pendingReads = 0
    @ObservationIgnored private var settleWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var readSequence = 0
    /// 세션마다 마지막으로 반영한 읽기 순번
    @ObservationIgnored private var appliedSequence: [UUID: Int] = [:]
    @ObservationIgnored private var notified: Set<AgentQuestionKey> = []
    @ObservationIgnored private var macNames: [UUID: String] = [:]
    @ObservationIgnored private var nameRequested: Set<UUID> = []
    @ObservationIgnored private var cardFocused: Set<UUID> = []
    /// 세션마다 지금까지 본 가장 큰 "질문 곁 대기열" 수: 늘 때만 포커스를 요청한다
    @ObservationIgnored private var queuedSeen: [UUID: Int] = [:]

    /// 단계마다 모은 답. 비밀값은 `SecretBox`에만 있다 (`Entry`에 두지 않는다)
    private struct Collected {
        var plain: [String: ConversationAnswerValue] = [:]
        var secrets: [String: SecretBox] = [:]
        var displays: [String: String] = [:]

        mutating func remove(_ promptID: String) {
            plain[promptID] = nil
            secrets[promptID] = nil
            displays[promptID] = nil
        }
    }

    /// - gateway: nil이면 읽기 · 답이 없다 (질문 카드가 없는 런타임)
    /// - secrets: 비밀값을 내보내는 곳. 없으면 비밀값 답은 "Couldn't send"로 돌아온다 (실제 구현은 D4b-m-2)
    /// - sleep: 보류 · 종료 기다림의 시계 (시험은 손으로 돌린다)
    public init(
        gateway: (any AgentQuestionGateway)?, scope: AccountScope, secrets: (any LocalSecretAnswerSubmitting)? = nil,
        sleep: @escaping Sleep = { try? await Task.sleep(for: .seconds($0)) }, log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.gateway = gateway
        self.scope = scope
        self.secrets = secrets
        self.sleep = sleep
        self.log = log
        scope.onLeft { [weak self] in self?.reset() }
    }

    // MARK: 보이는 것

    public func entry(session: UUID) -> Entry? { entries[session] }

    /// 비밀값 질문이 열려 있는 동안 그 세션의 composer를 막는다 (D4bm-42): 자유 글이 비밀값의 답이 되는 길은 없다. 보낸 뒤에는 푼다
    public func blocksComposer(session: UUID) -> Bool {
        guard let entry = entries[session] else { return false }
        return entry.question.hasSecret && entry.phase != .sent
    }

    /// 보내기 전/중이거나 접혀 있는 답이 있다 (종료 확인 · 종료 때 보냄의 대상)
    public var hasHeldAnswers: Bool {
        entries.values.contains { $0.phase == .holding || $0.phase == .sending }
    }

    public func focusRequest(session: UUID) -> Int { focusRequests[session] ?? 0 }

    /// 지금 질문의 카드가 새로 받아야 할 포커스 요청 수 (0이면 요청 없음: 카드가 스스로 포커스를 가져가지 않는다, D4bm-31).
    /// 앞 질문 때 누른 링의 요청은 세지 않는다. 질문 읽기가 끝나기 전에 누른 요청은 그 질문의 카드가 받는다
    public func pendingFocusRequests(session: UUID) -> Int {
        guard let entry = entries[session] else { return 0 }
        return max(0, (focusRequests[session] ?? 0) - entry.focusBaseline)
    }

    /// 질문이 열려 있는 동안 보낸 글이 대기열에 들어간 수 (`AgentQuestionRules.queuedBehindQuestion`)가 바뀌었다: **늘 때만** 포커스를 카드로 옮긴다
    /// (DS: "Otherwise it queues and focus moves to the card"). 글이 전달되어 수가 줄 때는 포커스를 훔치지 않는다
    public func noteQueued(count: Int, session: UUID) {
        let before = queuedSeen[session] ?? 0
        queuedSeen[session] = count
        if count > before { requestFocus(session: session) }
    }

    public func requestFocus(session: UUID) {
        focusRequests[session, default: 0] += 1
        if entries[session] == nil { focusBeforeEntry.insert(session) }
    }

    /// 카드(또는 그 줄)가 포커스를 가졌다 · 잃었다. Esc가 Undo가 되는 조건이다 (D4bm-33)
    public func setCardFocus(_ focused: Bool, session: UUID) {
        if focused { cardFocused.insert(session) } else { cardFocused.remove(session) }
    }

    /// 접힌 줄(sent)을 치워도 되는가: 서버가 같은 질문의 사건 줄을 대화에 썼다 (열쇠 `answer:<task id>:<sha256 hex(provider_request_id)>`, D4bm-25).
    /// 그 뒤로는 서버 사건 줄이 기록이다 — 같은 답을 두 번 말하지 않는다
    public func isRecorded(_ entry: Entry, eventKeys: Set<String>) -> Bool {
        entry.phase == .sent && eventKeys.contains(Self.sentEventKey(entry.key))
    }

    /// 서버가 답을 받을 때 대화에 쓰는 사건 줄의 `external_event_id`
    nonisolated public static func sentEventKey(_ key: AgentQuestionKey) -> String {
        "answer:\(key.taskID.uuidString.lowercased()):\(AgentQuestionRules.requestDigest(key.requestID))"
    }

    // MARK: 읽기

    /// 세션 저장소가 새로 읽은 세션들 (U2 전체 저장소 · Assistant 창의 좁은 저장소가 부른다). 질문을 기다리는 세션과 카드가 있는 세션의 질문을 서버에서 읽는다
    public func sessionsRead(_ items: [AgentSessionItem]) {
        guard scope.token != nil else { return }
        var wanted: Set<UUID> = []
        for item in items {
            sessions[item.id] = item
            if item.lastTaskState == .awaitingAnswer, !item.isClosed {
                wanted.insert(item.id)
            } else if entries[item.id] != nil {
                // 서버에 다시 묻는다: 카드를 치우는 것은 질문 읽기뿐이다
                wanted.insert(item.id)
            }
        }
        rebuildContexts()
        guard !wanted.isEmpty else { return }
        startRead(wanted)
    }

    private func startRead(_ sessionIDs: Set<UUID>) {
        track { await self.refresh(sessionIDs: sessionIDs) }
    }

    private func track(_ work: @escaping @MainActor () async -> Void) {
        pendingReads += 1
        Task {
            await work()
            pendingReads -= 1
            if pendingReads == 0 {
                let waiters = settleWaiters
                settleWaiters = []
                for waiter in waiters { waiter.resume() }
            }
        }
    }

    /// 읽기와 이름 읽기가 모두 끝날 때까지 (시험 · 견본). 보내는 중인 요청은 기다리지 않는다
    public func settle() async {
        guard pendingReads > 0 else { return }
        await withCheckedContinuation { settleWaiters.append($0) }
    }

    /// 그 세션들의 열린 질문을 읽어 반영한다. 마지막에 시작한 읽기만 반영하고, 실패하면 앞 카드를 그대로 둔다
    public func refresh(sessionIDs: Set<UUID>) async {
        guard let gateway, let token = scope.token, !sessionIDs.isEmpty else { return }
        readSequence += 1
        let sequence = readSequence
        if let thisMacProvider, let id = await thisMacProvider(), id != thisMacBridgeID { thisMacBridgeID = id }
        let records: [AgentQuestionRecord]
        do {
            records = try await gateway.openQuestions(sessionIDs: sessionIDs)
        } catch {
            return
        }
        guard scope.isCurrent(token) else { return }
        apply(records, requested: sessionIDs, sequence: sequence)
    }

    private func apply(_ records: [AgentQuestionRecord], requested: Set<UUID>, sequence: Int) {
        for session in requested {
            guard sequence > (appliedSequence[session] ?? 0) else { continue }
            appliedSequence[session] = sequence
            let record = records.filter { $0.sessionID == session && $0.question != nil }.max { ($0.turnSeq ?? 0) < ($1.turnSeq ?? 0) }
            if let question = record?.question {
                upsert(question, session: session)
            } else {
                focusBeforeEntry.remove(session)
                remove(session: session)
            }
        }
    }

    private func context(for session: UUID) -> AgentQuestionContext {
        guard let item = sessions[session] else { return AgentQuestionContext(agentName: "", isThisMac: false) }
        return AgentQuestionContext(
            agentName: item.agentName, isThisMac: AgentSessionRules.isOnThisMac(item, thisMacBridgeID: thisMacBridgeID),
            macName: item.connectionBridgeID.flatMap { macNames[$0] }
        )
    }

    private func upsert(_ question: AgentPendingQuestion, session: UUID) {
        let context = context(for: session)
        let cards = AgentQuestionRules.cards(for: question, context: context)
        if var entry = entries[session], entry.question.key == question.key {
            entry.question = question
            entry.context = context
            entry.cards = cards
            entry.step = min(entry.step, cards.count - 1)
            entries[session] = entry
            fetchMacNameIfNeeded(session: session)
            return
        }
        if let old = entries[session] { discard(old, session: session) }
        var created = Entry(sessionID: session, question: question, context: context, cards: cards, conversationID: sessions[session]?.conversationID)
        let requests = focusRequests[session] ?? 0
        created.focusBaseline = focusBeforeEntry.remove(session) != nil ? max(requests - 1, 0) : requests
        entries[session] = created
        fetchMacNameIfNeeded(session: session)
        if context.isThisMac, notified.insert(question.key).inserted {
            onOpened?(AgentQuestionOpened(key: question.key, sessionID: session, agentName: context.agentName))
        }
    }

    /// 카드를 치운다 (질문이 읽기에서 사라졌다): 보류 · 모은 답 · 비밀값을 버리고 알림을 지운다. 보내는 중이면 그 요청의 끝은 따로 처리한다
    private func remove(session: UUID) {
        guard let entry = entries[session] else { return }
        discard(entry, session: session)
        entries[session] = nil
    }

    private func discard(_ entry: Entry, session: UUID) {
        holds[session]?.cancel()
        holds[session] = nil
        collected[session] = nil
        cardFocused.remove(session)
        onClosed?([entry.key])
    }

    /// 이 Mac의 bridge id · Mac 이름이 새로 알려졌다: 카드의 종류(secret ↔ secretRemote)와 이름을 다시 정한다
    private func rebuildContexts() {
        for (session, var entry) in entries {
            let context = context(for: session)
            guard context != entry.context else { continue }
            entry.context = context
            entry.cards = AgentQuestionRules.cards(for: entry.question, context: context)
            entry.step = min(entry.step, entry.cards.count - 1)
            entries[session] = entry
            fetchMacNameIfNeeded(session: session)
        }
    }

    /// 다른 Mac의 비밀값 카드가 "Answer on <이름>"을 말하려면 그 Mac의 이름이 필요하다 (`bridges.device_name`). 한 번만 읽는다
    private func fetchMacNameIfNeeded(session: UUID) {
        guard let gateway, let entry = entries[session], entry.question.hasSecret, !entry.context.isThisMac,
              let bridge = sessions[session]?.connectionBridgeID, macNames[bridge] == nil, nameRequested.insert(bridge).inserted,
              let token = scope.token else { return }
        track {
            let name = try? await gateway.deviceName(bridgeID: bridge)
            guard self.scope.isCurrent(token), let name, !name.isEmpty else { return }
            self.macNames[bridge] = name
            self.rebuildContexts()
        }
    }

    // MARK: 입력

    /// 줄 하나를 골랐다 (단일 · 승인 · Other의 선택지). Other 줄은 입력 칸을 연다
    public func choose(row: Int, session: UUID) {
        guard var entry = entries[session], entry.phase == .open else { return }
        let card = entry.card
        switch card.kind {
        case .other where card.rows.indices.contains(row) && card.rows[row].isOther:
            entry.otherOpen = true
            entry.failure = nil
            entries[session] = entry
        case .single, .other, .approval:
            submit(.row(row), session: session)
        case .multi, .text, .secret, .secretRemote:
            return
        }
    }

    /// 다중 선택의 체크를 켜고 끈다
    public func toggle(row: Int, session: UUID) {
        guard var entry = entries[session], entry.phase == .open, entry.card.kind == .multi, entry.card.rows.indices.contains(row) else { return }
        if !entry.checked.insert(row).inserted { entry.checked.remove(row) }
        entry.failure = nil
        entries[session] = entry
    }

    /// 체크한 줄을 보낸다 (하나라도 체크되기 전에는 아무 일도 없다)
    public func sendChecked(session: UUID) {
        guard let entry = entries[session], entry.phase == .open, entry.card.kind == .multi, !entry.checked.isEmpty else { return }
        submit(.rows(entry.checked), session: session)
    }

    public func openOther(session: UUID) {
        guard var entry = entries[session], entry.phase == .open, entry.card.kind == .other else { return }
        entry.otherOpen = true
        entries[session] = entry
    }

    public func closeOther(session: UUID) {
        guard var entry = entries[session], entry.otherOpen else { return }
        entry.otherOpen = false
        entries[session] = entry
    }

    /// 입력한 글을 보낸다 (Other 칸 · 글만 질문). 빈 글은 답이 아니다
    public func submitText(_ text: String, session: UUID) {
        guard let entry = entries[session], entry.phase == .open, entry.card.kind == .text || (entry.card.kind == .other && entry.otherOpen) else { return }
        submit(.text(text), session: session)
    }

    /// 비밀값을 보낸다. 값은 마스크 칸에서 한 번 읽어 넘기고 칸은 곧바로 비운다 (호출한 쪽): 여기서는 보류 동안만 메모리에 둔다
    public func submitSecret(_ box: SecretBox, session: UUID) {
        guard let entry = entries[session], entry.phase == .open, entry.card.kind == .secret else { return }
        submit(.secret(box), session: session)
    }

    private func submit(_ pick: AgentQuestionPick, session: UUID) {
        guard var entry = entries[session], entry.phase == .open, let answer = AgentQuestionRules.answer(for: entry.card, pick: pick) else { return }
        let card = entry.card
        var gathered = collected[session] ?? Collected()
        switch answer.value {
        case .plain(let value): gathered.plain[card.promptID] = value
        case .secret(let box): gathered.secrets[card.promptID] = box
        }
        gathered.displays[card.promptID] = answer.display
        collected[session] = gathered
        entry.failure = nil
        if case .text(let text) = pick { entry.otherText = AgentQuestionRules.clamped(text) }
        if entry.step < entry.cards.count - 1 {
            // 앞 질문의 답은 앱에만 쌓는다: 보류도 요청도 마지막 답에서 시작한다 (D4bm-16)
            entry.step += 1
            entry.checked = []
            entry.otherOpen = false
            entry.otherText = ""
            entries[session] = entry
            return
        }
        entry.phase = .holding
        let shown = entry.question.prompts.compactMap { gathered.displays[$0.id] }
        entry.summary = shown.isEmpty ? nil : shown.joined(separator: " · ")
        entries[session] = entry
        startHold(session: session, key: entry.key)
    }

    /// Undo · 실패 · 종료로 카드가 열린 상태로 돌아간다. 비밀값이 있는 요청은 **모든 비밀값을 지우고** 첫 비밀값 단계로 돌아가 거기서부터 다시 받는다
    /// (앞 단계의 일반 답은 둔다): 앞 단계 비밀값이 재조회 뒤에도 남아 재제출에 쓰이면 안 된다. 비밀값이 없는 요청은 마지막 답만 지우고 마지막 질문으로 돌아간다
    private func rewind(_ entry: inout Entry, session: UUID) {
        let prompts = entry.question.prompts
        if entry.question.hasSecret, let first = prompts.firstIndex(where: \.secret) {
            for prompt in prompts[first...] { collected[session]?.remove(prompt.id) }
            entry.step = min(first, entry.cards.count - 1)
            entry.checked = []
            entry.otherOpen = false
            entry.otherText = ""
        } else {
            collected[session]?.remove(entry.card.promptID)
        }
        entry.phase = .open
        entry.summary = nil
    }

    /// Undo: 보류 안에서만. 서버 호출은 없다. 여러 질문이면 마지막 질문으로 돌아가고 앞 답은 둔다 (비밀값이 섞였으면 `rewind`)
    public func undo(session: UUID) {
        guard var entry = entries[session], entry.phase == .holding else { return }
        holds[session]?.cancel()
        holds[session] = nil
        rewind(&entry, session: session)
        entries[session] = entry
    }

    /// Esc: ① Other 입력 칸이면 줄로 되돌린다 ② 보류 중이고 카드에 포커스가 있으면 Undo. 처리했으면 true — 아니면 호출한 쪽의 차례로 넘어간다 (D4bm-33)
    public func escape(session: UUID) -> Bool {
        guard let entry = entries[session] else { return false }
        if entry.phase == .open, entry.otherOpen {
            closeOther(session: session)
            return true
        }
        if entry.phase == .holding, cardFocused.contains(session) {
            undo(session: session)
            return true
        }
        return false
    }

    // MARK: 보류 · 보내기

    private func startHold(session: UUID, key: AgentQuestionKey) {
        holds[session]?.cancel()
        let sleep = sleep
        holds[session] = Task { [weak self] in
            await sleep(Self.holdSeconds)
            guard !Task.isCancelled, let self else { return }
            self.holdElapsed(session: session, key: key)
        }
    }

    private func holdElapsed(session: UUID, key: AgentQuestionKey) {
        holds[session] = nil
        guard let entry = entries[session], entry.key == key, entry.phase == .holding, let token = scope.token else { return }
        beginSend(session: session, key: key, token: token)
    }

    @discardableResult
    private func beginSend(session: UUID, key: AgentQuestionKey, token: AccountScope.Token) -> Task<Void, Never> {
        var entry = entries[session]!
        entry.phase = .sending
        entries[session] = entry
        let conversation = entry.conversationID
        let payload = Payload.make(entry: entry, gathered: collected[session] ?? Collected())
        let sendID = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            let result = await self.deliver(payload)
            self.finish(result, sendID: sendID, session: session, key: key, token: token, conversation: conversation)
        }
        sendTasks[sendID] = task
        return task
    }

    /// 보낼 것: 서버 요청, 또는 이 Mac에만 두는 답 (비밀값이 섞인 요청, D4bm-43)
    private enum Payload {
        case server(taskID: UUID, request: AgentAnswerRequest)
        case local(LocalSecretAnswer)
        case missing

        static func make(entry: Entry, gathered: Collected) -> Payload {
            if AgentQuestionRules.deliversLocally(entry.question) {
                var answers: [String: LocalSecretAnswer.Value] = gathered.plain.mapValues { .plain($0) }
                for (id, box) in gathered.secrets { answers[id] = .secret(box) }
                guard Set(answers.keys) == Set(entry.question.prompts.map(\.id)) else { return .missing }
                return .local(LocalSecretAnswer(key: entry.key, answers: answers))
            }
            guard let request = AgentQuestionRules.request(for: entry.question, collected: gathered.plain) else { return .missing }
            return .server(taskID: entry.key.taskID, request: request)
        }
    }

    private enum Sent {
        case sent
        case clearAndReread
        case failed(AgentQuestionFailure)
    }

    private func deliver(_ payload: Payload) async -> Sent {
        switch payload {
        case .missing:
            return .failed(.generic)
        case .local(let answer):
            guard let secrets else { return .failed(.generic) }
            switch await secrets.submit(answer) {
            case .sent: return .sent
            case .questionClosed: return .clearAndReread
            case .failed(let failure): return .failed(failure)
            case .unavailable: return .failed(.generic)
            }
        case .server(let taskID, let request):
            guard let gateway else { return .failed(.generic) }
            // busy_retry만 같은 요청을 한 번 다시 보낸다 (서버가 "다시 보내도 된다"고 정했다). 같은 답은 서버가 duplicate로 모은다
            for attempt in 0..<2 {
                do {
                    _ = try await gateway.answerQuestion(taskID: taskID, request: request)
                    return .sent
                } catch {
                    switch AgentQuestionAnswerResult.of(error) {
                    case .sent: return .sent
                    case .retryOnce: if attempt == 1 { return .failed(.generic) }
                    case .clearAndReread: return .clearAndReread
                    case .failed(let failure):
                        if let api = error as? APIError, api.agentCode == .secretRequiresLocal { log("question_answer_secret_requires_local") }
                        return .failed(failure)
                    }
                }
            }
            return .failed(.generic)
        }
    }

    private func finish(_ result: Sent, sendID: UUID, session: UUID, key: AgentQuestionKey, token: AccountScope.Token, conversation: UUID?) {
        sendTasks[sendID] = nil
        guard scope.isCurrent(token) else { return }
        if case .sent = result { onAnswered?(session, conversation) }
        // 보내는 동안 질문이 바뀌었거나 읽기에서 사라졌다: 그 요청의 결과를 새 카드에 적용하지 않는다
        guard var entry = entries[session], entry.key == key else { return }
        switch result {
        case .sent:
            entry.phase = .sent
            entries[session] = entry
            collected[session] = nil
            onClosed?([key])
            startRead([session])
        case .clearAndReread:
            discard(entry, session: session)
            entries[session] = nil
            startRead([session])
        case .failed(let failure):
            // 카드가 돌아온다: 마지막 답은 지우고 사용자가 다시 고른다 (체크 · 입력한 글은 남긴다, 비밀값은 모두 버린다: `rewind`)
            rewind(&entry, session: session)
            entry.failure = failure
            entries[session] = entry
        }
    }

    // MARK: 종료

    /// 앱 종료: 보류 중인 비밀값이 아닌 답은 곧바로 보내고 끝나거나 `timeout`초가 지날 때까지 기다린다. **비밀값 답은 보내지 않고 값을 버린다**
    /// (질문은 열린 채 남고 다음 실행에서 다시 묻는다, D4bm-22): 값은 이 Mac의 메모리에만 있어 종료 뒤에는 전달할 수 없다
    public func flushForQuit(timeout: TimeInterval = AgentQuestionStore.quitWait) async {
        guard let token = scope.token else { return }
        for (session, entry) in entries where entry.phase == .holding {
            holds[session]?.cancel()
            holds[session] = nil
            if entry.question.hasSecret {
                var back = entry
                rewind(&back, session: session)
                entries[session] = back
            } else {
                beginSend(session: session, key: entry.key, token: token)
            }
        }
        let pending = Array(sendTasks.values)
        guard !pending.isEmpty else { return }
        let sleep = sleep
        // 보낸 답이 모두 끝나거나 한도가 지나면 먼저 오는 쪽에서 돌아온다 (느린 서버를 끝까지 기다리지 않는다: 작업 그룹은 느린 쪽도 기다리므로 쓰지 않는다)
        let race = QuitRace()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            race.arm(continuation)
            let timer = Task {
                await sleep(timeout)
                race.finish()
            }
            race.setTimer(timer)
            Task {
                for task in pending { await task.value }
                race.finish()
            }
        }
    }

    /// 종료 기다림의 경주: 처음 끝낸 쪽이 이어 가고, 남은 시계는 걷는다
    private final class QuitRace: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var timer: Task<Void, Never>?
        private var finished = false

        func arm(_ continuation: CheckedContinuation<Void, Never>) {
            lock.withLock { self.continuation = continuation }
        }

        func setTimer(_ timer: Task<Void, Never>) {
            let cancelNow = lock.withLock { () -> Bool in
                self.timer = timer
                return finished
            }
            if cancelNow { timer.cancel() }
        }

        func finish() {
            let (continuation, timer) = lock.withLock { () -> (CheckedContinuation<Void, Never>?, Task<Void, Never>?) in
                guard !finished else { return (nil, nil) }
                finished = true
                defer { self.continuation = nil }
                return (self.continuation, self.timer)
            }
            timer?.cancel()
            continuation?.resume()
        }
    }

    // MARK: 계정 경계

    /// 계정이 떠남: 보류 · 질문 상태 · 모은 답 · 비밀값을 버린다. 늦게 오는 읽기 · 응답은 `scope.isCurrent`가 버린다
    public func reset() {
        readSequence += 1
        let closing = entries.values.map(\.key)
        for task in holds.values { task.cancel() }
        holds = [:]
        for task in sendTasks.values { task.cancel() }
        sendTasks = [:]
        collected = [:]
        entries = [:]
        sessions = [:]
        appliedSequence = [:]
        notified = []
        macNames = [:]
        nameRequested = []
        cardFocused = []
        queuedSeen = [:]
        focusRequests = [:]
        focusBeforeEntry = []
        if !closing.isEmpty { onClosed?(closing) }
    }
}
