#if os(macOS)
import Foundation
import Observation

/// 데스크톱 세션과 대화하는 기능의 게이트 (PR-D3k, 계약 25.7): **Debug · 내부 배포 빌드에서만 켜지고 Release는 꺼진다.** 꺼진 빌드는 중계 · 입력창 · 올리기 · 지표가 모두 없다 (지금처럼 읽기 전용)
public enum ClaudeAppRelayGate {
    public static func isEnabled(isDebugBuild: Bool, isInternalBuild: Bool) -> Bool {
        isDebugBuild || isInternalBuild
    }
}

/// 기록 속 peer 줄 밑에 보이는 한 줄 (계약 25.4.4, DZ 승인 · Q-D3c): **이 앱 실행이 띄운 중계 프로세스가 보낸 것**(플러그인 `tf-relay` ∧ 검증된 보낸 pid가 이 실행이 띄운 중계 pid ∧ 글의 시각이 그 중계가 떠 있던 때 안)만 "Received · via Taskforce"이고,
/// 그 밖은 중립 표시 "From another session"이다. `tf-relay`라는 이름만으로 믿지 않는다: 앞 실행의 중계 · 다른 프로세스는 우리 사용자의 글이라는 증거가 없다.
/// (2분 유휴로 끝났거나 다시 떠서 pid가 바뀐 이 실행의 앞선 중계는 우리 것이다: 그래서 "지금 떠 있는" 것이 아니라 "이 실행이 띄운" 모든 중계의 pid를 쓴다 — OA PR-D3 검토 P2-4.
/// 다만 pid는 운영체제가 다시 쓰므로 pid마다 띄운 때 ~ 끝난 때를 기억하고 그 밖의 시각 · 시각 없는 글은 우리 것이 아니다 — 재검토 security P3-new-1)
public enum ClaudeAppPeerLine {
    public static func of(_ peer: ClaudeAppPeer, at time: Date?, relayPIDs: ClaudeAppRelayPIDs) -> MessageDeliveryLine {
        let ours = peer.verifiedPeerPID.map { relayPIDs.ran($0, at: time) && peer.isTaskforceRelay(relayPID: $0) } ?? false
        return MessageDeliveryLine(strong: nil, text: ours ? ClaudeAppChatCopy.receivedViaTaskforce : ClaudeAppChatCopy.fromAnotherSession)
    }
}

/// 한 세션의 저장 표시 + 불투명 ref를 만드는 열쇠 (이 Mac의 것): bridge를 모르면 만들 수 없다 (nil)
public struct ClaudeAppChatIdentity: Sendable {
    public var context: ClaudeAppChatContext
    /// 씨앗 → 불투명 ref (Mac 열쇠 HMAC, `ExternalSessionKey.chatRef`)
    public var ref: @Sendable (String) -> String

    public init(context: ClaudeAppChatContext, ref: @escaping @Sendable (String) -> String) {
        self.context = context
        self.ref = ref
    }
}

/// 대화 흐름이 쓰는 바깥 면 (실제 앱은 Mac이 채우고, 시험은 가짜로 채운다)
public struct ClaudeAppChatEnvironment: Sendable {
    public var relay: ClaudeAppRelay
    /// 보내기 전 확인의 사실 (등록 파일 · 프로세스 · 서명을 읽는 막히는 호출: 메인 밖에서 부른다)
    public var facts: @Sendable (String) -> ClaudeAppSendFacts
    /// 대상 세션 기록 읽기 (전달 확인 · 교환 따라가기)
    public var transcript: any ClaudeAppTranscriptSource
    /// 지금 등록 파일이 말하는 세션 (상태 · 끝남을 본다)
    public var session: @MainActor @Sendable (String) -> ClaudeAppSession?
    public var saver: ClaudeAppChatSaver
    /// 저장 표시(bridge id · 이 세션의 ref · 제목)와 ref 열쇠. bridge를 모르면 nil: 올릴 수 없다. **저장이 켜졌을 때만** 부른다
    public var identity: @Sendable (String) async -> ClaudeAppChatIdentity?
    /// 보내기 결과 지표 (`POST claude-app-sent`, 글 0)
    public var report: @Sendable (ClaudeAppSentReport) async -> Void
    public var now: @Sendable () -> Date
    public var sleep: @Sendable (TimeInterval) async -> Void
    public var log: any BridgeLogSink

    public init(
        relay: ClaudeAppRelay, facts: @escaping @Sendable (String) -> ClaudeAppSendFacts, transcript: any ClaudeAppTranscriptSource,
        session: @escaping @MainActor @Sendable (String) -> ClaudeAppSession?, saver: ClaudeAppChatSaver, identity: @escaping @Sendable (String) async -> ClaudeAppChatIdentity?,
        report: @escaping @Sendable (ClaudeAppSentReport) async -> Void, now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) }, log: any BridgeLogSink = NoBridgeLog()
    ) {
        self.relay = relay
        self.facts = facts
        self.transcript = transcript
        self.session = session
        self.saver = saver
        self.identity = identity
        self.report = report
        self.now = now
        self.sleep = sleep
        self.log = log
    }
}

/// 데스크톱 세션 하나의 입력창 상태 (PR-D3m의 패널이 읽는다): 쓰던 글 · 보낸 글의 전달 줄 · 첫 보내기 확인 · 입력창을 보일지.
/// 글 · 세션 id를 찍지 않는다 (`description`은 칸 수뿐)
@MainActor
@Observable
public final class ClaudeAppSessionChat: CustomStringConvertible, CustomDebugStringConvertible {
    /// 보낸 말 하나와 그 전달 상태 (DZ 시트 4)
    public struct Delivery: Identifiable, Equatable, Sendable {
        public let id: String
        public let text: String
        public internal(set) var state: ClaudeAppDeliveryTracker.State
        /// 기록에서 찾은 우리 줄의 id: 패널이 그 줄 밑에 "Received · via Taskforce"를 그리고 이 말풍선은 지운다
        public internal(set) var matchedTurnID: String?

        /// 화면의 전달 줄
        public var line: MessageDeliveryLine { state.line }
        public var isPending: Bool {
            switch state {
            case .sending, .sent, .queued: true
            case .received, .notSent: false
            }
        }
    }

    public let sessionID: String
    /// 입력창의 글 (정리하기 전)
    public var draft = ""
    public internal(set) var deliveries: [Delivery] = []
    /// C5 확인 카드가 떠 있다 (글은 입력창에 남아 있다)
    public internal(set) var isConfirming = false
    /// 보내기 전 확인이 도는 중이다
    public internal(set) var isChecking = false
    public private(set) var view = ClaudeAppSendContext.View.open
    public private(set) var isVisible = false

    @ObservationIgnored weak var service: ClaudeAppChatService?
    /// C5를 누른 그 프로세스: 같은 세션이어도 프로세스가 바뀌면 다시 묻는다
    @ObservationIgnored var confirmation: ClaudeAppSendContext.Confirmation?
    /// 카드가 물은 프로세스 (확인을 누르면 이것이 `confirmation`이 된다)
    @ObservationIgnored var candidate: ClaudeAppSendContext.Confirmation?

    init(sessionID: String, service: ClaudeAppChatService) {
        self.sessionID = sessionID
        self.service = service
    }

    /// 확인 전 글이 있다 (④ 한 번에 하나)
    public var hasPending: Bool { deliveries.contains(where: \.isPending) }

    /// 입력창이 보이나: 닫힘 · 기록을 못 읽음에서는 없다 (DZ 시트 5)
    public var composerShown: Bool { view == .open }

    /// Enter로 보낼 수 있나: 입력창이 있고, 정리한 글이 1–16,000자이고, 확인 전 글이 없고, 확인 카드 · 확인이 돌고 있지 않다
    public var canSubmit: Bool {
        guard composerShown, !hasPending, !isConfirming, !isChecking, let text = ClaudeAppSendText.normalize(draft) else { return false }
        return ClaudeAppSendText.isSendable(text)
    }

    /// 패널이 이 세션을 보여 주고 있다: 중계를 미리 띄워 두고 (첫 보내기가 빠르다), 닫으면 쓰는 곳이 없어져 2분 뒤 끝난다
    public func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        service?.visibilityChanged(self)
    }

    /// 보기의 상태 (패널이 알린다): 닫힘 · 기록 못 읽음에서는 입력창이 없다
    public func setView(_ view: ClaudeAppSendContext.View) {
        self.view = view
        if view != .open { cancelConfirmation() }
    }

    /// Enter: 정리한 글을 보내기 전 확인에 부친다. 첫 보내기(이 세션 · 이 프로세스)면 C5 카드가 먼저다
    @discardableResult
    public func submit() -> Task<Void, Never> {
        Task { [weak self] in
            guard let self, canSubmit, let text = ClaudeAppSendText.normalize(draft) else { return }
            await service?.begin(chat: self, text: text, replacing: nil)
        }
    }

    /// C5의 Send: 카드가 물은 프로세스를 확인한 것으로 하고 보낸다 (그 사이 프로세스가 바뀌었으면 보내지 않고 다시 묻는다)
    @discardableResult
    public func confirm() -> Task<Void, Never> {
        Task { [weak self] in
            guard let self, isConfirming, let text = ClaudeAppSendText.normalize(draft) else { return }
            confirmation = candidate
            isConfirming = false
            await service?.begin(chat: self, text: text, replacing: nil)
        }
    }

    /// C5의 Cancel: 글은 입력창에 그대로다
    public func cancelConfirmation() {
        isConfirming = false
        candidate = nil
    }

    /// Send again: 못 보낸 말을 같은 글로 다시 보낸다 (같은 자리에서 새 id로 바뀐다). 닫힌 세션의 말은 다시 보낼 곳이 없다
    @discardableResult
    public func sendAgain(_ id: String) -> Task<Void, Never> {
        Task { [weak self] in
            guard let self, !hasPending, !isChecking, composerShown, let delivery = deliveries.first(where: { $0.id == id }), case .notSent(let reason) = delivery.state, reason.allowsSendAgain else { return }
            await service?.begin(chat: self, text: delivery.text, replacing: id)
        }
    }

    public nonisolated var description: String { "ClaudeAppSessionChat()" }
    public nonisolated var debugDescription: String { description }
}

#if DEBUG
extension ClaudeAppSessionChat {
    /// 견본 · 시험용 (Debug 전용: Release 바이너리에 없다): 보낸 말 하나를 상태째 만든다
    public static func sampleDelivery(id: String = UUID().uuidString.lowercased(), text: String, state: ClaudeAppDeliveryTracker.State, matchedTurnID: String? = nil) -> Delivery {
        Delivery(id: id, text: text, state: state, matchedTurnID: matchedTurnID)
    }

    /// 견본 · 시험용 (Debug 전용): 입력창의 상태를 직접 놓는다 (디자인 비교 그림이 모든 상태를 한 번에 그린다)
    public func setSample(deliveries: [Delivery], confirming: Bool = false, draft: String = "") {
        self.deliveries = deliveries
        isConfirming = confirming
        self.draft = draft
    }
}
#endif

/// 데스크톱 세션과의 대화 흐름 (PR-D3k, 계약 25장): Enter → 정리 → 보내기 전 확인(C5) → 중계 → 전달 상태 기계 → 대상 기록에서 확인 → 교환을 따라가며 저장 행을 올린다 → 보내기 지표.
/// 모든 시계 · 기록 읽기 · 중계 · 서버는 주입된 값이다 (시험은 가짜). **글 · 세션 id · 경로를 로그 · 지표에 남기지 않는다**: 로그는 `claude_app_send {result, reason_code}` 코드뿐이다.
/// - 교환을 따라가는 일은 패널을 닫아도 **Taskforce가 켜져 있는 동안** 계속한다 (30분까지, 계약 25.1). 한 세션에 읽기 하나 (그 세션 기록의 꼬리만)
/// - 1초마다 `tick()`: 대상 상태 → 기록 읽기 → 우리 줄 찾기(= Received) · 저장 행 모으기 → 30초 시계
/// - `shutdown()`: 앱 종료 · 로그아웃 · 게이트 꺼짐: 따라가기 · 중계 · 올리기를 바로 끝낸다 (못 올린 것은 버린다, 디스크 0)
@MainActor
public final class ClaudeAppChatService {
    /// 따라가는 읽기의 한 번에 읽는 쪽 수 (한 tick)
    static let maxReadsPerTick = 8
    /// 한 세션에서 메모리에 두는 줄의 상한
    static let maxFollowedTurns = 4000
    static let tickInterval: TimeInterval = 1

    private final class Active {
        let id: String
        let sessionID: String
        let text: String
        var tracker: ClaudeAppDeliveryTracker
        var relayPID: Int32?
        let sentAt: Date
        let baseline: Set<String>
        /// 보내기 전 기록을 읽지 못해 baseline을 모른다: 보낸 시각 뒤에 쓰인 줄만 우리 것으로 본다 (OA PR-D3 검토 P3-13)
        let baselineUnknown: Bool
        var matchedTurnID: String?
        /// 교환이 끝났다 (더 모으지 않는다)
        var exchangeDone = false
        var seenBusy = false
        var terminalHandled = false
        /// 저장 표시 · ref 열쇠 (저장이 켜져 있을 때 처음 필요한 때 읽는다)
        var identity: ClaudeAppChatIdentity?
        var noBridgeReported = false

        init(id: String, sessionID: String, text: String, startedAt: Date, baseline: Set<String>, baselineUnknown: Bool) {
            self.id = id
            self.sessionID = sessionID
            self.text = text
            self.sentAt = startedAt
            self.baseline = baseline
            self.baselineUnknown = baselineUnknown
            tracker = ClaudeAppDeliveryTracker(startedAt: startedAt)
        }
    }

    /// 한 세션 기록의 꼬리 읽기 (패널과 따로: 패널을 닫아도 계속한다)
    private final class Follower {
        let sessionID: String
        var cursor: ClaudeAppTranscriptCursor?
        var turns: [ClaudeAppTurn] = []
        /// 마지막 읽기가 끝까지 읽었다 (③ 턴 끝 판정)
        var readComplete = true
        var absent = 0

        init(sessionID: String) { self.sessionID = sessionID }
    }

    private let environment: ClaudeAppChatEnvironment
    /// 앱 종료 직전에 메인 밖에서 중계만 끝내는 데 쓴다 (`stopRelayForQuit`)
    private nonisolated let quitRelay: ClaudeAppRelay
    private var chats: [String: ClaudeAppSessionChat] = [:]
    private var actives: [String: [Active]] = [:]
    private var followers: [String: Follower] = [:]
    private var loop: Task<Void, Never>?
    private var ticking = false
    private var isShutDown = false
    private var interestOwners = Set<String>()
    private var interestChain: Task<Void, Never>?
    /// 계정 세대 (OA PR-D3 검토 P3-6): `accountLeft()`가 올린다. 보내기 · 읽기 · 올리기 · 미리 띄우기는 시작할 때의 값을 쥐고 있다가 기다림이 끝날 때마다 같은지 보고, 다르면 그만둔다 — 떠난 계정의 글이 다음 계정으로 가지 않는다
    private var epoch = 0
    /// 저장 켜짐 확인 (처음 한 번): 보내기는 이것을 기다리지 않고, 교환을 모을 때만 답을 기다린다
    private var askTask: Task<Void, Never>?

    public init(environment: ClaudeAppChatEnvironment) {
        self.environment = environment
        quitRelay = environment.relay
        let weakGaveUp: @Sendable (String) -> Void = { [weak self] id in Task { @MainActor in self?.uploadGaveUp(exchangeID: id) } }
        Task { await environment.saver.setGaveUpHandler(weakGaveUp) }
    }

    /// 중계 프로세스의 pid (레일 · 목록 · 다른 writer 확인이 뺀다)
    public var relayPIDs: ClaudeAppRelayPIDs { environment.relay.pids }

    /// 기록의 한 줄 밑의 표시 (peer 줄이 아니면 nil): **이 앱 실행이 띄운 중계**가 보낸 것만 "Received · via Taskforce", 그 밖은 "From another session".
    /// - 중계가 2분 유휴로 끝났거나 다시 떠서 pid가 바뀌어도 앞서 띄운 중계가 떠 있던 동안 쓴 글은 그대로 우리 것이다 (`ClaudeAppRelayPIDs.ran(_:at:)`: pid마다 띄운 때 ~ 끝난 때). 시각이 없는 줄은 우리 것이 아니다
    /// - 이 보내기로 기록에서 확인된 줄(`matchedTurnID`)은 pid를 몰라도 우리 것이다
    /// - 읽는 값은 모두 관찰된다 (pid 집합 · 보낸 말): pid가 바뀌면 그린 쪽이 다시 그려진다 (OA PR-D3 검토 P2-4)
    public func peerLine(for turn: ClaudeAppTurn, in sessionID: String) -> MessageDeliveryLine? {
        guard case .peer(_, let peer) = turn.kind else { return nil }
        let matched = chats[sessionID]?.deliveries.contains { $0.matchedTurnID == turn.id } == true
        if matched { return MessageDeliveryLine(strong: nil, text: ClaudeAppChatCopy.receivedViaTaskforce) }
        return ClaudeAppPeerLine.of(peer, at: turn.timestamp, relayPIDs: environment.relay.pids)
    }

    public func chat(for sessionID: String) -> ClaudeAppSessionChat {
        if let existing = chats[sessionID] { return existing }
        let made = ClaudeAppSessionChat(sessionID: sessionID, service: self)
        chats[sessionID] = made
        return made
    }

    // MARK: 보이는 동안 (중계를 미리 띄운다)

    fileprivate func visibilityChanged(_ chat: ClaudeAppSessionChat) {
        guard !isShutDown else { return }
        setInterest("view:\(chat.sessionID)", chat.isVisible)
        if chat.isVisible {
            let relay = environment.relay
            let started = epoch
            // 줄 서 있는 동안 계정이 떠났으면 띄우지 않는다 (OA PR-D3 검토 P3-9)
            Task { [weak self] in
                guard let self, epoch == started, !isShutDown else { return }
                await relay.prepare()
            }
        }
    }

    /// 중계를 쓰는 곳이 하나라도 있는 동안 중계를 끝내지 않는다 (순서를 지켜 `retain` · `release`를 한 줄로 부른다)
    private func setInterest(_ owner: String, _ on: Bool) {
        let before = !interestOwners.isEmpty
        if on { interestOwners.insert(owner) } else { interestOwners.remove(owner) }
        let after = !interestOwners.isEmpty
        guard before != after else { return }
        let relay = environment.relay
        let previous = interestChain
        let started = epoch
        interestChain = Task { [weak self] in
            await previous?.value
            // 떠난 계정이 걸어 둔 `retain`은 버린다 (`release`는 그대로: 끝내는 쪽이다)
            if after {
                guard let self, epoch == started, !isShutDown else { return }
                await relay.retain()
            } else {
                await relay.release()
            }
        }
    }

    // MARK: 보내기

    /// 정리한 글을 보낸다: 확인 사실을 모으고(메인 밖) → 보내기 전 확인 → (C5 카드 | 막힘 줄 | 보냄)
    fileprivate func begin(chat: ClaudeAppSessionChat, text: String, replacing replaced: String?) async {
        guard !isShutDown else { return }
        let sessionID = chat.sessionID
        let started = epoch
        chat.isChecking = true
        defer { chat.isChecking = false }
        let facts = await detached { [environment] in environment.facts(sessionID) }
        // 기다리는 동안 계정이 떠났으면 이 입력창은 이미 남의 것이 아니다: 아무것도 만들지 않는다 (카드 · 막힘 줄 · 보내기 모두)
        guard !isShutDown, epoch == started, chat.composerShown else { return }
        var readiness = await environment.relay.readiness()
        guard epoch == started else { return }
        // 띄운 뒤 정체가 바뀐 중계는 보내기가 새로 띄운다 (⑤: 안 되면 Not received)
        if readiness == .mismatch { readiness = .notRunning }
        let context = ClaudeAppSendContext(confirmed: chat.confirmation, hasPending: chat.hasPending && replaced == nil, relay: readiness, view: chat.view)
        switch ClaudeAppSendCheck.evaluate(facts: facts, context: context) {
        case .needsConfirmation:
            chat.candidate = facts.session.map { ClaudeAppSendContext.Confirmation(pid: $0.pid, procStart: $0.procStart) }
            chat.isConfirming = true
        case .blocked(let block):
            guard let reason = block.notSentReason else { return }
            let delivery = ClaudeAppSessionChat.Delivery(id: UUID().uuidString.lowercased(), text: text, state: .notSent(reason), matchedTurnID: nil)
            place(delivery, in: chat, replacing: replaced)
            if replaced == nil { chat.draft = "" }
            noteTerminal(.notSent(reason))
        case .allowed:
            await send(chat: chat, text: text, replacing: replaced, facts: facts, epoch: started)
        }
    }

    /// 쓰기 직전의 확인 (TOCTOU, DT1 · DT3 · DT9): 중계의 한 번에 하나 구간 안에서, 중계가 준비된 뒤 · 글을 쓰기 전에 대상을 다시 읽는다.
    /// 프로세스(pid · 시작 시각) · 서명 · 다른 writer · 등록 하나 · 등록 폴더 읽기 중 하나라도 처음 확인과 다르면 보내지 않는다 (Not received).
    /// **계정 세대도 본다** (OA PR-D3 재검토 security P3-c): 로그아웃이 중계를 끝내기 전이라도 세대가 먼저 오르므로, 시작할 때의 세대(`started`)와 다르면 거짓이다 — 대상을 읽기 전에 한 번, 읽은 뒤에 한 번
    func recheck(sessionID: String, original: ClaudeAppSendFacts, epoch started: Int) -> @Sendable () async -> Bool {
        let environment = environment
        return { [weak self] in
            guard await self?.isCurrent(epoch: started) == true else { return false }
            let latest = await Task.detached(priority: .userInitiated) { environment.facts(sessionID) }.value
            guard await self?.isCurrent(epoch: started) == true else { return false }
            guard let before = original.session, let now = latest.session else { return false }
            return !latest.doubled && !latest.registryUnavailable && latest.processTrusted && latest.otherWriters == .none && now.pid == before.pid && now.procStart == before.procStart
        }
    }

    /// 시작할 때의 계정 세대 그대로이고 꺼지지 않았다
    private func isCurrent(epoch started: Int) -> Bool { !isShutDown && epoch == started }

    /// 저장 켜짐 확인을 (처음 한 번) 시작한다: **기다리지 않는다** — 보내기는 저장과 무관하다 (§25.4.3 ⑧). 올리는 길은 확인이 켜짐이라고 답한 뒤에만 생긴다
    private func startAsking() {
        guard askTask == nil else { return }
        let saver = environment.saver
        askTask = Task { await saver.ensureAsked() }
    }

    private func send(chat: ClaudeAppSessionChat, text: String, replacing replaced: String?, facts: ClaudeAppSendFacts, epoch started: Int) async {
        let sessionID = chat.sessionID
        let id = UUID().uuidString.lowercased()
        // 보내기 **전에** 기록을 열어 둔다: 이미 있던 줄은 이번 보내기의 것이 아니다. 못 열면 baseline을 모른다 (보낸 시각 뒤의 줄만 우리 것)
        let follower = followers[sessionID] ?? Follower(sessionID: sessionID)
        followers[sessionID] = follower
        await openOrCatchUp(follower, cwd: facts.session?.cwd ?? environment.session(sessionID)?.cwd)
        guard epoch == started, !isShutDown else { return }
        let active = Active(
            id: id, sessionID: sessionID, text: text, startedAt: environment.now(), baseline: Set(follower.turns.map(\.id)), baselineUnknown: follower.cursor == nil
        )
        actives[sessionID, default: []].append(active)
        setInterest("follow:\(sessionID)", true)
        place(ClaudeAppSessionChat.Delivery(id: id, text: text, state: .sending, matchedTurnID: nil), in: chat, replacing: replaced)
        if replaced == nil { chat.draft = "" }
        ensureLoop()
        // 저장 켜짐 확인은 보내기와 나란히 간다 (기다리지 않는다)
        startAsking()
        let result = await environment.relay.send(sessionID: sessionID, text: text, recheck: recheck(sessionID: sessionID, original: facts, epoch: started))
        guard !isShutDown, epoch == started else { return }
        switch result {
        case .delivered(let relayPID):
            active.relayPID = relayPID
            active.tracker.apply(.relayAccepted, at: environment.now())
        case .notDelivered(let reason):
            active.tracker.apply(.relayRefused(reason), at: environment.now())
        }
        publish(active, in: chat)
        await settleIfFinished(active, in: chat)
    }

    private func place(_ delivery: ClaudeAppSessionChat.Delivery, in chat: ClaudeAppSessionChat, replacing replaced: String?) {
        if let replaced, let index = chat.deliveries.firstIndex(where: { $0.id == replaced }) {
            chat.deliveries[index] = delivery
        } else {
            chat.deliveries.append(delivery)
        }
    }

    private func publish(_ active: Active, in chat: ClaudeAppSessionChat) {
        guard let index = chat.deliveries.firstIndex(where: { $0.id == active.id }) else { return }
        chat.deliveries[index].state = active.tracker.state
        chat.deliveries[index].matchedTurnID = active.matchedTurnID
    }

    // MARK: 1초 tick

    private func ensureLoop() {
        guard loop == nil, !isShutDown else { return }
        let sleep = environment.sleep
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await sleep(Self.tickInterval)
                guard !Task.isCancelled, let self else { return }
                await self.tick()
            }
        }
    }

    /// 따라가는 모든 세션을 한 번씩 본다 (루프가 1초마다 부른다. 시험은 시계를 올리고 직접 부른다)
    public func tick() async {
        guard !isShutDown, !ticking else { return }
        ticking = true
        defer { ticking = false }
        for sessionID in actives.keys.sorted() { await tick(sessionID) }
        if actives.isEmpty {
            loop?.cancel()
            loop = nil
        }
    }

    private func tick(_ sessionID: String) async {
        guard let follower = followers[sessionID], let list = actives[sessionID], !list.isEmpty else { return }
        let started = epoch
        let session = environment.session(sessionID)
        follower.absent = session == nil ? follower.absent + 1 : 0
        let closed = follower.absent > ClaudeAppRail.missingGrace
        await read(follower, cwd: session?.cwd)
        guard epoch == started else { return }
        let mode = follower.cursor?.permissionMode
        for active in list {
            let now = environment.now()
            if active.tracker.isPending { active.tracker.apply(.target(session?.state), at: now) }
            if active.matchedTurnID != nil, session?.state == .busy { active.seenBusy = true }
            await collect(active, follower: follower, session: session, closed: closed, now: now)
            guard epoch == started else { return }
            if active.tracker.isPending {
                if closed { active.tracker.apply(.targetClosed, at: now) }
                active.tracker.apply(.tick(permissionMode: mode), at: now)
            }
            if let chat = chats[sessionID] { publish(active, in: chat); await settleIfFinished(active, in: chat) }
        }
    }

    /// 대상 기록에서 우리 줄을 찾고(= Received) 그 교환의 저장 행을 모은다
    private func collect(_ active: Active, follower: Follower, session: ClaudeAppSession?, closed: Bool, now: Date) async {
        guard let relayPID = active.relayPID, !active.exchangeDone else { return }
        let ended = active.matchedTurnID != nil && (closed || (active.seenBusy && session?.state == .idle && follower.readComplete))
        let started = epoch
        // 저장 켜짐 확인의 답을 기다린다 (보내기는 기다리지 않았다: 시간 제한이 있는 호출이라 오래 걸리지 않는다). 답이 오기 전에는 올리는 길이 없다
        await askTask?.value
        guard epoch == started else { return }
        // 저장이 켜져 있을 때만 이 세션의 저장 표시 · ref 열쇠가 필요하다 (꺼져 있으면 서버에 관한 것은 아무것도 읽지 않는다: DT14)
        let saving = await environment.saver.isSaving
        if saving, active.identity == nil { active.identity = await environment.identity(active.sessionID) }
        guard epoch == started else { return }
        // 열쇠를 아직 모르면 행은 쓰지 않는다 (받았는지 찾는 데만 쓴다): 씨앗 그대로를 돌려주는 자리 값
        let plain: @Sendable (String) -> String = { seed in seed }
        let ref: @Sendable (String) -> String = active.identity.map(\.ref) ?? plain
        let exchange = ClaudeAppExchangeCollector.collect(
            ClaudeAppExchangeInput(
                sessionID: active.sessionID, turns: follower.turns, relayPID: relayPID, sentText: active.text, sentAt: active.sentAt, now: now, turnEnded: ended, baseline: active.baseline,
                baselineUnknown: active.baselineUnknown, ref: ref
            )
        )
        guard let matched = exchange.matchedTurnID else { return }
        if active.matchedTurnID == nil {
            active.matchedTurnID = matched
            active.tracker.apply(.transcriptReceived, at: now)
            noteTerminal(.received)
            // "Received"가 된 순간의 지표: 저장이 꺼져 있으면 이 route가 센다 (켜져 있으면 서버의 저장 함수가 센다)
            if !saving { report(.received) }
        }
        if saving { await upload(exchange, active: active) }
        if exchange.finished != nil {
            active.exchangeDone = true
            // bridge를 끝내 몰랐다: 올릴 수 없었다. 서버가 세지 못하니 "받았지만 올리지 못했다"를 한 번 알린다
            if saving, active.identity == nil, !active.noBridgeReported {
                active.noBridgeReported = true
                report(.receivedButNotUploaded)
            }
        }
    }

    /// 저장이 켜져 있으면 행을 올릴 줄에 세운다 (bridge를 모르면 아직 못 올린다: 다음 tick에 다시 읽는다)
    private func upload(_ exchange: ClaudeAppExchange, active: Active) async {
        guard let identity = active.identity else { return }
        await environment.saver.enqueue(ClaudeAppChatBatch(exchangeID: active.id, context: identity.context, rows: exchange.rows))
    }

    /// 올리기를 포기했다: 그 교환의 사용자 행이 이미 올라갔으면 서버가 `received`를 센 것이다 — 다시 세지 않는다 (OA PR-D3 검토 P3-12). 사용자 행조차 못 올렸을 때만 "받았지만 올리지 못했다"를 알린다
    private func uploadGaveUp(exchangeID: String) {
        guard !isShutDown else { return }
        let saver = environment.saver
        let started = epoch
        Task { [weak self] in
            let counted = await saver.userRowSaved(exchangeID)
            guard let self, !counted, !isShutDown, epoch == started else { return }
            report(.receivedButNotUploaded)
        }
    }

    // MARK: 끝난 것

    /// 끝난 전달이면 지표 · 로그를 한 번 남기고 따라갈 것이 없으면 정리한다
    private func settleIfFinished(_ active: Active, in chat: ClaudeAppSessionChat) async {
        if case .notSent(let reason) = active.tracker.state, !active.terminalHandled {
            active.terminalHandled = true
            active.exchangeDone = true
            noteTerminal(.notSent(reason))
        }
        if active.tracker.state == .received { active.terminalHandled = true }
        let finished: Bool = {
            switch active.tracker.state {
            case .notSent: true
            case .received: active.exchangeDone
            case .sending, .sent, .queued: false
            }
        }()
        guard finished else { return }
        retire(active)
    }

    private func retire(_ active: Active) {
        actives[active.sessionID]?.removeAll { $0 === active }
        guard actives[active.sessionID]?.isEmpty ?? true else { return }
        actives[active.sessionID] = nil
        followers[active.sessionID] = nil
        setInterest("follow:\(active.sessionID)", false)
    }

    /// 로그 · 지표: 결과 코드뿐 (글 · id 0)
    private func noteTerminal(_ state: ClaudeAppDeliveryTracker.State) {
        switch state {
        case .received:
            environment.log.log("claude_app_send", ["result": .code("received")])
        case .notSent(let reason):
            environment.log.log("claude_app_send", ["result": .code("not_sent"), "reason_code": .code(reason.code)])
            report(.notSent(reason))
        case .sending, .sent, .queued: break
        }
    }

    private func report(_ report: ClaudeAppSentReport) {
        let send = environment.report
        Task { await send(report) }
    }

    // MARK: 기록 읽기

    private func detached<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await Task.detached(priority: .userInitiated, operation: work).value
    }

    /// 보내기 전: 아직 안 열었으면 꼬리를 열고, 열었으면 지금까지의 새 줄을 읽어 따라잡는다
    private func openOrCatchUp(_ follower: Follower, cwd: String?) async {
        if follower.cursor == nil {
            await open(follower, cwd: cwd)
        } else {
            await read(follower, cwd: cwd)
        }
    }

    private func open(_ follower: Follower, cwd: String?) async {
        let source = environment.transcript
        let sessionID = follower.sessionID
        let load = await detached { source.open(sessionID: sessionID, cwd: cwd) }
        guard case .page(let page) = load else { return }
        follower.cursor = page.cursor
        follower.turns = page.turns
        follower.readComplete = true
    }

    private func read(_ follower: Follower, cwd: String?) async {
        guard let first = follower.cursor else {
            // 열지 못했다: 이번 tick에 다시 열어 본다
            await open(follower, cwd: cwd)
            return
        }
        let source = environment.transcript
        var cursor = first
        for _ in 0..<Self.maxReadsPerTick {
            let current = cursor
            let update = await detached { source.newer(current) }
            switch update {
            case .turns(let more, let next, let hasMore):
                follower.turns += more
                cursor = next
                follower.cursor = next
                follower.readComplete = !hasMore
                if follower.turns.count > Self.maxFollowedTurns { follower.turns.removeFirst(follower.turns.count - Self.maxFollowedTurns) }
                if !hasMore { return }
            case .reset:
                follower.cursor = nil
                await open(follower, cwd: cwd)
                return
            case .unreadable:
                return
            }
        }
        follower.readComplete = false
    }

    // MARK: 끝냄

    /// 앱 종료 · 게이트 꺼짐: 따라가기 · 중계 · 올리기를 바로 끝낸다 (못 올린 것은 버린다). 이 서비스는 다시 쓰지 않는다
    public func shutdown() async {
        isShutDown = true
        epoch += 1
        await stopEverything(terminal: true)
    }

    /// 앱 종료 직전(`applicationWillTerminate`): 중계 프로세스를 막힘 있게 끝낸다 (최대 `timeout`초: 메인을 오래 잡지 않는다). 메인에서 불러도 된다 — 메인이 아닌 중계 actor만 기다린다
    public nonisolated func stopRelayForQuit(timeout: TimeInterval = 2) {
        let relay = quitRelay
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            // 종료는 끝이다: 줄 서 있던 미리 띄우기 · 보내기가 이 뒤에 중계를 되살리지 못한다 (OA PR-D3 검토 P3-9)
            await relay.shutdown(terminal: true)
            done.signal()
        }
        _ = done.wait(timeout: .now() + timeout)
    }

    /// 로그아웃 · 계정 바뀜: 하던 일을 모두 끝내고 이 계정의 입력 상태(쓰던 글 · 보낸 말)를 버린다. 서비스는 다음 계정으로 다시 쓴다
    public func accountLeft() async {
        // 세대를 먼저 올린다 (기다리는 중인 보내기 · 읽기 · 올리기 · 미리 띄우기가 깨어나면 이 값이 달라 그만둔다)
        epoch += 1
        askTask = nil
        chats = [:]
        await stopEverything(terminal: false)
    }

    private func stopEverything(terminal: Bool) async {
        loop?.cancel()
        loop = nil
        actives = [:]
        followers = [:]
        interestOwners = []
        interestChain?.cancel()
        interestChain = nil
        await environment.relay.shutdown(terminal: terminal)
        await environment.saver.clear()
    }
}
#endif
