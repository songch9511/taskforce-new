#if os(macOS)
import AppKit
import SwiftUI
import TaskforceKit
import TaskforceUI

/// 세션 패널 창이 SwiftUI에 넘기는 값: 머리 · 본문 · 입력 영역의 높이 (창 높이를 맞춘다) · 나타남
@MainActor
@Observable
final class EdgeSessionPanelPresentation {
    var headHeight: CGFloat = 0
    var bodyHeight: CGFloat = 0
    var footerHeight: CGFloat = 0
    var shown = false
    /// 패널 왼쪽 바깥에 붙는 옆줄 (세션이 돌리는 백그라운드 일, 세션 보기 V1). 창을 왼쪽으로 넓히는 폭도 이것이 정한다
    let pane: SessionSidePaneModel
    /// 단계 묶음 · 줄의 보이는 상태
    let steps = SessionStepsState()
    /// 이 세션이 **이 Mac에서** 돌았을 때만 있다: 이 Mac의 Claude Code 기록을 읽어 도구 단계와 일 목록을 준다 (서버 저장은 후속: 다른 Mac · iPhone에서는 단계가 없다)
    private(set) var local: ClaudeAppConversation?
    /// 그 기록을 가리키는 값 (Claude 세션 id · 세션 cwd): 일의 출력 꼬리도 이것으로 읽는다
    var localTarget: AgentLocalTranscriptTarget?
    /// 위로 올려 읽는 중이 아니다 (맨 아래를 따라간다)
    var scrollPinned = true
    /// 본문이 다시 계산돼도 대화 · 단계가 그대로면 타임라인을 다시 만들지 않는다
    @ObservationIgnored let timeline = SessionTimelineMemo<SessionPanelTimelineInput, SessionPanelTimeline>()

    init(backgroundOpen: any BackgroundTaskOpenStore = InMemoryBackgroundTaskOpenStore()) {
        pane = SessionSidePaneModel(store: backgroundOpen)
    }

    var contentHeight: CGFloat { headHeight + bodyHeight + footerHeight }

    /// 지금 보는 세션 (같으면 아무 일도 없다)
    private(set) var sessionKey: String?

    /// 다른 세션을 연다: 옆줄이 그 세션의 것으로 바뀌고, 이 Mac 기록 연결을 끊고, 위로 올려 읽던 자리 · 열어 둔 줄 · 읽은 본문을 비운다 (줄 id는 세션 안에서만 겹치지 않는다)
    func beginSession(_ key: String) {
        guard key != sessionKey else { return }
        sessionKey = key
        scrollPinned = true
        steps.reset()
        timeline.reset()
        pane.attach(session: key)
        attachLocal(nil)
        localTarget = nil
    }

    /// 이 Mac의 기록 읽기를 붙인다 (다른 세션으로 바뀌면 앞 것은 멈춘다)
    func attachLocal(_ conversation: ClaudeAppConversation?) {
        local?.stop()
        local = conversation
        if shown { conversation?.start() }
    }

    /// 패널이 보이는 동안만 기록의 꼬리를 읽는다
    func followLocal() {
        if shown { local?.start() } else { local?.stop() }
    }
}

/// Taskforce 패널 타임라인의 입력 (같으면 같은 타임라인): 서버 대화의 글 · 이 Mac 기록의 단계 · 진행 상태
struct SessionPanelTimelineInput: Equatable {
    var turns: [ChatTurn]
    var steps: [ClaudeAppTurn]
    var state: SessionRunState
}

/// Taskforce 패널의 타임라인: 줄 · 단계 · 글 찾기표 (서버 글 · 이 Mac 기록의 단계)
struct SessionPanelTimeline {
    let data: SessionTimelineData
    let entries: [SessionEntry]
    let turns: [String: ChatTurn]
    let steps: [String: ClaudeAppTurn]

    init(_ input: SessionPanelTimelineInput) {
        data = SessionTimelineSource.chat(input.turns, steps: input.steps)
        entries = SessionTimeline.build(data.items, state: input.state)
        turns = Dictionary(input.turns.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { first, _ in first })
        steps = Dictionary(input.steps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }
}

/// 세션 패널 (OA U2, DS PanelHeader 세션 변형 · SessionPage): 이슈 패널 왼쪽의 두 번째 패널. 머리(에이전트 마크 · "{이름} — #번호" · 알약 자리) · 상태 줄 · 본문(U1 `Message` 그대로) · Composer.
/// - 폭 380, 모서리 18, `panel` 재료, 높이는 내용에 맞춰 320–520. 닫기 버튼은 없다 (Esc · 바깥 클릭 · 다른 세션 · 뒤로)
/// - 알약(Open in Terminal · Resume here)은 **동작이 주어질 때만** 보인다: U2에서는 견본 하네스뿐이고 동작은 D4a다. 상태 줄은 세션의 말 (2.5 표)
/// - Composer는 그 세션의 대화(`conversations.agent_session_id`, 여럿이면 가장 새 것)로 `ChatStore.send(_:in:)`한다. 닫힌 세션은 읽기만 (상태 말 없이 흐리게, Composer 없음). 대화(대상)를 읽기 전에는 Composer가 비활성이다
/// - 읽는 중 = 그리지 않음, 오프라인 · 읽기 실패 = 기존 화면 + Try again
struct SessionPanelView: View {
    @Bindable var shell: EdgeShellModel
    let runtime: ChatRuntime
    @Bindable var presentation: EdgeSessionPanelPresentation

    private var chat: ChatStore { runtime.chat }

    var body: some View {
        let scale = TFMotion.panelTransform(shown: presentation.shown, reduceMotion: shell.reduceMotion).scale
        // 옆줄(백그라운드 일)이 있으면 패널의 왼쪽 바깥에 붙는다: 같은 창 · 같은 위 · 같은 높이 (`SessionPanelFrame`)
        SessionPanelFrame(pane: presentation.pane, reduceMotion: shell.reduceMotion) { width in
            Group {
                if let session = shell.openSessionItem {
                    content(session)
                } else {
                    Color.clear
                }
            }
            .frame(width: width)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .scaleEffect(scale, anchor: .topTrailing)
        .animation(TFMotion.move(TFMotion.panelMove, reduceMotion: shell.reduceMotion), value: presentation.shown)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(shell.openSessionItem?.name ?? "Session")
    }

    @ViewBuilder
    private func content(_ session: AgentSessionItem) -> some View {
        VStack(spacing: 0) {
            header(session)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { presentation.headHeight = $0 }
            // 글이 짧으면 머리 바로 아래부터(OA-3), 길면 맨 아래(가장 새 글)에서 시작한다: 보이는 높이를 최소 높이로 줘 위에 붙인다
            GeometryReader { viewport in
                ScrollViewReader { proxy in
                    ScrollView {
                        bodyContent(session)
                            .padding(EdgeInsets(top: TFSpace.xs, leading: TFSpace.lg, bottom: TFSpace.sm, trailing: TFSpace.lg))
                            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { presentation.bodyHeight = $0 }
                            .frame(maxWidth: .infinity, minHeight: viewport.size.height, alignment: .top)
                    }
                    .defaultScrollAnchor(.bottom)
                    .scrollIndicators(.automatic)
                    // 붙어 있던 동안만 새 글을 따라 내려간다: 위로 올려 읽는 중이면 끌어내리지 않는다 (시계 틱은 스크롤을 건드리지 않는다). 새 글로 내용이 늘어난 것은 사용자가 올린 것이 아니다
                    .onScrollGeometryChange(for: SessionScrollSnapshot.self) { geometry in
                        SessionScrollSnapshot(visibleMaxY: geometry.visibleRect.maxY, contentHeight: geometry.contentSize.height, visibleHeight: geometry.visibleRect.height)
                    } action: { old, new in
                        presentation.scrollPinned = SessionScrollPin.next(pinned: presentation.scrollPinned, old: old, new: new)
                    }
                    .onChange(of: signature(session)) {
                        if SessionScrollPin.shouldFollowNewContent(pinned: presentation.scrollPinned) { proxy.scrollTo(AssistantBodyAnchor.bottom, anchor: .bottom) }
                    }
                }
            }
            footer(session)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { presentation.footerHeight = $0 }
        }
        .task(id: session.id) { await prepare(session) }
        // 이 Mac의 기록(단계 · 일)과 어댑터의 일 목록을 옆줄에 먹인다
        .task(id: session.id) { await followLocal(session) }
        .onChange(of: presentation.shown) { presentation.followLocal() }
        .onChange(of: session.isClosed) { _, closed in presentation.pane.setClosed(closed) }
    }

    // MARK: 이 Mac의 기록 · 옆줄

    /// 이 세션이 이 Mac에서 돌아 어댑터가 Claude 세션을 묶었으면 그 기록을 읽는다 (돌았던 세션이 아니면 단계 · 일 목록 없이 말 · 시간 · 복사만). 첫 턴 전이면 묶일 때까지 몇 번 다시 본다.
    /// 어댑터의 `task_*` 줄로 만든 일 목록(`BackgroundTaskBoard`)은 기록의 일 목록과 합쳐 옆줄에 보낸다 (둘 다 이 Mac 안에서만)
    private func followLocal(_ session: AgentSessionItem) async {
        let key = session.id.uuidString.lowercased()
        let presentation = presentation
        let shell = shell
        let runtime = runtime
        presentation.beginSession(key)
        presentation.pane.setClosed(session.isClosed)
        // 꼬리 읽기는 이 Mac의 기록이 묶은 Claude 세션 id · 세션 cwd로만 (아직 모르면 못 읽음)
        presentation.pane.makeTail = { [shell, weak presentation] task in
            guard let target = presentation?.localTarget else { return BackgroundTaskTailModel(taskID: task.id, read: { _ in .unreadable }) }
            return shell.makeBackgroundTail(target.providerSessionID, target.cwd, task)
        }
        let sessionID = session.id
        let follower = SessionLocalFollower(
            find: { await runtime.localTranscriptTarget(sessionID) }, isShown: { presentation.shown },
            taskKey: { shell.openSessionItem?.lastTaskState.map { "\($0)" } },
            onChange: { target in
                presentation.localTarget = target
                presentation.attachLocal(target.map { shell.makeConversation($0.providerSessionID, $0.cwd) })
            }
        )
        let clock = ContinuousClock()
        let started = clock.now
        var lastBoardVersion = -1
        var lastLocal: BackgroundTaskList?
        while !Task.isCancelled {
            let elapsed = clock.now - started
            await follower.tick(now: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
            let board = runtime.backgroundBoard
            let local = presentation.local?.backgroundTasks
            if presentation.shown, board.version != lastBoardVersion || local != lastLocal {
                lastBoardVersion = board.version
                lastLocal = local
                let merged = board.tasks(session: key).merged(with: local ?? BackgroundTaskList())
                if merged != presentation.pane.tasks { presentation.pane.tasks = merged }
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// 머리 제목: "{세션 이름} — #{현재 이슈 번호}" (번호를 못 읽었거나 이슈가 정해지지 않으면 이름만, 지어내지 않는다)
    static func title(for session: AgentSessionItem, number: Int?) -> String {
        guard session.currentIssueID != nil, let label = IssueNumberStore.label(number) else { return session.name }
        return "\(session.name) — \(label)"
    }

    private func header(_ session: AgentSessionItem) -> some View {
        let number = session.currentIssueID.flatMap { shell.issues?.numbers.number(for: $0) }
        return PanelHeader(
            title: Self.title(for: session, number: number), agent: session.agent, pill: pill(for: session),
            status: Self.statusLine(for: session, stop: runtime.stop.presentation(session: session)), dimmed: session.isClosed
        )
    }

    /// 머리의 알약 (OA D4a-03): 동작이 주어졌고, **이 Mac에서 도는 세션**일 때만. Open in Terminal은 launcher가 있을 때만 (실제 launcher는 D4a-2)
    private func pill(for session: AgentSessionItem) -> PanelHeaderPill? {
        guard let action = shell.onSessionPill,
              let spec = Self.pillSpec(for: session, thisMacBridgeID: shell.thisMacBridgeID, offersOpenInTerminal: runtime.pillFlow?.offersOpenInTerminal ?? true) else { return nil }
        return PanelHeaderPill(title: spec.title, disabledReason: spec.disabledReason) { action(spec, session) }
    }

    /// 알약 하나를 그릴지의 규칙: U2의 알약(종류 · 꺼진 이유)이 있고, 이 Mac의 세션이고, Open in Terminal은 launcher가 있을 때만 (없으면 알약이 없다: 동작이 없으면 그리지 않는다)
    static func pillSpec(for session: AgentSessionItem, thisMacBridgeID: UUID?, offersOpenInTerminal: Bool) -> AgentSessionPill? {
        guard let spec = AgentSessionRules.visiblePill(session, thisMacBridgeID: thisMacBridgeID) else { return nil }
        if case .openInTerminal = spec, !offersOpenInTerminal { return nil }
        return spec
    }

    /// 머리 아래 상태 줄: 끝난 세션은 상태 말이 없다 (사용자 결정 2026-10-15: 상태 말 없이 흐리게).
    /// Stop 요청이 있으면 "Stop requested · not confirmed"(U2 2.5 표 그대로), 명령이 남을 수 있으면 승인 전 후보 말이 다음 턴이 시작될 때까지 그 자리다 (D4a-13)
    static func statusLine(for session: AgentSessionItem) -> String? {
        session.line.isEmpty ? nil : session.line
    }

    static func statusLine(for session: AgentSessionItem, stop: AgentStopRules.Presentation) -> String? {
        if let line = stop.line { return line.text }
        return statusLine(for: session)
    }

    /// 입력 영역: 읽은 대화 행이 있어야(= 대상을 알아야) 보낸다. 모르는 동안은 비활성 + 접근성 이유. 닫힌 세션 · 대화가 없는 세션은 읽기만
    enum ComposerState: Equatable {
        case hidden
        case waiting
        case ready(UUID)
    }

    static let waitingHint = "Loading this conversation"

    static func composerState(for session: AgentSessionItem, chat: ChatStore) -> ComposerState {
        guard !session.isClosed, let id = session.conversationID else { return .hidden }
        if chat.isTargetKnown(id) { return .ready(id) }
        // 읽기가 실패했거나(오프라인 · 실패 · 서버에 없음) 오류 화면이 말하는 중이면 Composer를 두지 않는다: 끝나지 않는 로딩 힌트를 달고 기다리지 않는다
        switch chat.screen(for: id) {
        case .offline, .failed: return .hidden
        default: return .waiting
        }
    }

    // MARK: 본문

    /// 동의가 먼저 필요한 글이 있나 (Assistant 창의 "Allow AI processing to continue"와 같은 조건)
    static func showsConsentNotice(chat: ChatStore, conversationID: UUID) -> Bool {
        chat.needsConsent(in: conversationID)
    }

    /// 기능 꺼짐 안내를 보이나 (Assistant 창의 "Chats aren't available yet."와 같은 조건)
    static func showsUnavailableNotice(chat: ChatStore) -> Bool { chat.isUnavailable }

    /// 입력창이 막혔나 (기능이 꺼졌다)
    static func isComposerDisabled(chat: ChatStore) -> Bool { chat.isUnavailable }

    /// 기능 꺼짐 안내의 Try again: 막힘을 풀고 목록을 다시 읽는다 (Assistant 창과 같은 `retryUnavailable()`)
    static func retryUnavailable(_ chat: ChatStore) { chat.retryUnavailable() }

    /// 동의 안내의 단추: 셸의 Connections (Assistant 창의 `openConnections`와 같은 길 — 컨트롤러가 둘 다 `rail.onConnections()`에 잇는다)
    static func openConnections(_ shell: EdgeShellModel) {
        shell.onConnect()
    }

    /// 맨 아래로 내릴 때를 알리는 값: 글 수와 마지막 글(상태 · 전달 표시가 바뀌어도 바뀐다)
    private struct BodySignature: Equatable {
        var count = 0
        var last: ChatTurn?
        /// 이 Mac의 기록에서 읽은 가장 새 단계 (새 단계가 붙어도 따라 내려간다)
        var lastStep: String?
    }

    private func signature(_ session: AgentSessionItem) -> BodySignature {
        let lastStep = presentation.local?.turns.last?.id
        guard let id = session.conversationID else { return BodySignature(lastStep: lastStep) }
        let turns = chat.turns(for: id)
        return BodySignature(count: turns.count, last: turns.last, lastStep: lastStep)
    }

    /// 대화의 줄들: 서버 대화의 글에 이 Mac 기록의 도구 단계를 시각 순으로 끼우고, `SessionTimeline`이 묶기 · 일한 시간 · 답 밑 줄(복사) · 시계를 정한다.
    /// 이 세션이 이 Mac에서 돌지 않았으면 단계 없이 말 · 시간 · 복사만이다 (서버 저장은 후속)
    @ViewBuilder
    private func entries(_ session: AgentSessionItem, conversationID: UUID) -> some View {
        let input = SessionPanelTimelineInput(
            turns: chat.turns(for: conversationID), steps: presentation.local?.turns ?? [],
            state: SessionTimelineSource.runState(task: session.lastTaskState, closed: session.isClosed)
        )
        let timeline = presentation.timeline.value(for: input) { SessionPanelTimeline(input) }
        let byID = timeline.turns
        let local = presentation.local
        let localTurns = timeline.steps
        SessionEntriesView(
            entries: timeline.entries, steps: timeline.data.steps, state: presentation.steps,
            loadDetail: { stepID in
                guard let local, let turn = localTurns[stepID] else { return nil }
                return await local.detail(of: turn)
            },
            item: { id in
                if let turn = byID[id] {
                    AssistantTurnView(turn: turn, runtime: runtime, actions: agentActions(session, conversationID: conversationID), onRetry: { cmid in Task { await chat.retry(cmid, in: conversationID) } })
                }
            }
        )
    }

    @ViewBuilder
    private func bodyContent(_ session: AgentSessionItem) -> some View {
        if let conversationID = session.conversationID {
            switch chat.screen(for: conversationID) {
            case .blank:
                Color.clear.frame(height: 0)
            case .offline:
                PanelEmptyState(.offline) { Button(ChatCopy.tryAgain) { chat.loadConversation(conversationID) }.buttonStyle(TFButtonStyle(.secondary, size: .md)) }
            case .failed:
                PanelEmptyState(title: ChatCopy.couldNotLoadChat) {
                    Button(ChatCopy.tryAgain) { chat.loadConversation(conversationID) }.buttonStyle(TFButtonStyle(.secondary, size: .md))
                }
            case .ready(let problem):
                VStack(alignment: .leading, spacing: TFSpace.md) {
                    if let problem {
                        Notice(title: problem == .offline ? PanelEmptyKind.offline.title : ChatCopy.couldNotLoad) {
                            Button(ChatCopy.tryAgain) { chat.loadConversation(conversationID) }.buttonStyle(TFButtonStyle(.secondary, size: .sm))
                        }
                    }
                    // 서버의 대화 기능이 꺼졌다: Assistant 창과 같은 안내 · 같은 Try again (복구는 성공한 읽기도 확인한다)
                    if Self.showsUnavailableNotice(chat: chat) {
                        Notice(title: ChatCopy.unavailable) {
                            Button(ChatCopy.tryAgain) { Self.retryUnavailable(chat) }.buttonStyle(TFButtonStyle(.secondary))
                        }
                    }
                    // 동의가 먼저 필요하다 (Send again · 후보 고르기가 동의 철회로 거절됐다): Assistant 창과 같은 안내 · 같은 Connections 길
                    if Self.showsConsentNotice(chat: chat, conversationID: conversationID) {
                        Notice(title: ChatCopy.consentNeeded) {
                            Button(ChatCopy.allowAIButton) { Self.openConnections(shell) }.buttonStyle(TFButtonStyle(.secondary))
                        }
                    }
                    entries(session, conversationID: conversationID)
                    Color.clear.frame(height: 1).id(AssistantBodyAnchor.bottom)
                }
            }
        } else if let problem = sessionProblem {
            // 대화를 이을 수 없는 세션: 읽지 못한 사실만 말한다
            PanelEmptyState(title: problem == .offline ? PanelEmptyKind.offline.title : PanelEmptyKind.couldNotLoad.title) {
                Button(ChatCopy.tryAgain) { Task { await shell.issues?.sessions.refresh() } }.buttonStyle(TFButtonStyle(.secondary, size: .md))
            }
        } else {
            Color.clear.frame(height: 0)
        }
    }

    /// 에이전트 대화의 줄 동작 (Assistant 창과 같다): 에이전트 이름 · 그 연결의 대상 상태로 전달 줄을 옮긴다
    private func agentActions(_ session: AgentSessionItem, conversationID: UUID) -> AgentTurnActions {
        let desk = runtime.panelDesk
        let context = AgentDeliveryContext(agentName: session.agentName, targetState: runtime.targets.targetState(forConnection: session.connectionID))
        return AgentTurnActions(
            line: { desk.line(for: $0, context: context) },
            onLink: { turn, link in
                switch link.kind {
                case .sendAgain: Task { await desk.sendAgain(turn, in: conversationID) }
                case .chooseReferent: desk.openReferentMenu(for: turn.id)
                }
            },
            viewFull: { desk.viewFull($0) },
            retry: { turn in Task { await desk.retry(turn, in: conversationID) } },
            referentMenu: desk.referentMenu,
            chooseReferent: { id in Task { await desk.chooseReferent(id, in: conversationID) } },
            candidateLabel: { candidate in
                IssueNumberStore.label(shell.issues?.numbers.number(for: candidate.actionID)).map { "\($0) \(candidate.title)" } ?? candidate.title
            }
        )
    }

    /// 세션 읽기에 문제가 있나 (읽은 적이 있으면 받은 세션은 그대로 둔다)
    private var sessionProblem: WorkLoad.Problem? {
        switch shell.issues?.sessions.load {
        case .offline?: .offline
        case .failed?: .failed
        case .loaded(let problem)?: problem
        default: nil
        }
    }

    // MARK: 입력 영역

    /// 입력 영역 위의 Resume 확인 카드 (질문 카드 자리, 모달이 아니다): 그 세션의 카드가 열려 있을 때만
    @ViewBuilder
    private func confirmCard(_ session: AgentSessionItem) -> some View {
        if let flow = runtime.pillFlow, let card = flow.resumeCard, card.sessionID == session.id {
            ConfirmCard(
                title: AgentCopy.resumeTitle, meta: AgentCopy.resumeMeta, error: card.error, confirmLabel: AgentCopy.resumeConfirm, cancelLabel: AgentCopy.cancel,
                busy: card.busy, onConfirm: { Task { await flow.confirmResume() } }, onCancel: { flow.cancelResume() }
            )
            .padding(EdgeInsets(top: TFSpace.sm, leading: TFSpace.md, bottom: 0, trailing: TFSpace.md))
        }
    }

    /// 입력 영역 위의 질문 카드 (OA D4b-m-1, 확인 카드와 같은 자리): 그 세션의 질문은 여기서만 답한다. 카드가 그 면 높이(최대 520)의 60%를 넘으면 카드 안에서 스크롤한다
    @ViewBuilder
    private func questionCard(_ session: AgentSessionItem) -> some View {
        if let questions = runtime.questions {
            EdgeQuestionCardHost(
                questions: questions, chat: chat, sessionID: session.id, conversationID: session.conversationID,
                maxHeight: EdgePanelMetrics.maxHeight * QuestionCard.maxHeightShare
            )
            .padding(EdgeInsets(top: TFSpace.sm, leading: TFSpace.md, bottom: 0, trailing: TFSpace.md))
        }
    }

    @ViewBuilder
    private func footer(_ session: AgentSessionItem) -> some View {
        VStack(spacing: 0) {
            confirmCard(session)
            questionCard(session)
            composerFooter(session)
        }
    }

    @ViewBuilder
    private func composerFooter(_ session: AgentSessionItem) -> some View {
        switch Self.composerState(for: session, chat: chat) {
        case .hidden:
            // 닫힌 세션은 읽기만 (Composer 없음). 대화를 모르는 세션도 보낼 곳이 없다
            Color.clear.frame(height: TFSpace.sm)
        case .waiting:
            // 대상을 아직 모른다: 보내지 못한다 (확인되지 않은 대상을 Taskforce로 보지 않는다)
            composer(session, conversationID: session.conversationID, disabled: true)
                .accessibilityHint(Self.waitingHint)
        case .ready(let conversationID):
            composer(session, conversationID: conversationID, disabled: Self.isComposerDisabled(chat: chat))
        }
    }

    private func composer(_ session: AgentSessionItem, conversationID: UUID?, disabled: Bool) -> some View {
        Composer(
            text: Binding(
                get: { conversationID.map { chat.draft(for: $0) } ?? "" },
                set: { value in if let conversationID { chat.setDraft(value, for: conversationID) } }
            ),
            placeholder: "Message \(session.agentName)", label: "Message \(session.agentName)", isDisabled: disabled,
            isSending: conversationID.map { chat.isSending(in: $0) } ?? false,
            isRunning: runtime.stop.presentation(session: session).showsStop,
            // 비밀값 질문이 열려 있으면 입력이 꺼진다 ("Answer the question above first"): 여기 쓴 글이 비밀값의 답이 되는 길이 없다
            blocked: runtime.questions?.blocksComposer(session: session.id) == true ? "" : nil,
            onStop: { Task { await runtime.stop.stopSession(session) } },
            onSubmit: { text in if let conversationID { Task { await chat.send(text, in: conversationID) } } }
        )
        .padding(EdgeInsets(top: 10, leading: TFSpace.md, bottom: TFSpace.md, trailing: TFSpace.md))
    }

    /// 열 때: 현재 이슈의 번호를 읽는다 (대화는 셸이 `onLoadSessionConversation`으로 id로 읽는다)
    private func prepare(_ session: AgentSessionItem) async {
        async let thisMac: Void = shell.refreshThisMac()
        if let issue = session.currentIssueID { await shell.issues?.numbers.ensure([issue]) }
        await thisMac
    }
}

/// 세션 패널 창 (OA U2-46): `EdgeKeyPanel`과 같은 종류(borderless · nonactivating)의 두 번째 창. 이슈 패널의 왼쪽 40pt(OA U3-45), 위를 이슈 패널과 맞춘다.
/// 이슈 패널이 열려 있고 세션 패널이 열려 있을 때만 보이고, 높이는 내용에 맞춰 320–520이다
@MainActor
final class EdgeSessionPanelController {
    let shell: EdgeShellModel
    let panel: EdgeKeyPanel
    let presentation: EdgeSessionPanelPresentation
    private let hosting: NSHostingView<SessionPanelView>
    private var generation = 0
    /// 창을 옆줄만큼 왼쪽으로 넓힌 폭의 마지막 값: 바뀌면 움직이지 않고 바로 맞춘다
    private var appliedExtra: CGFloat = 0
    /// 이슈 패널 창의 자리. 세션 패널은 그 왼쪽에 놓인다
    var issuePanelFrame: () -> NSRect? = { nil }

    init(shell: EdgeShellModel, runtime: ChatRuntime) {
        self.shell = shell
        presentation = EdgeSessionPanelPresentation(backgroundOpen: runtime.doneStores.backgroundOpen)
        panel = EdgeKeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: EdgePanelMetrics.width, height: EdgePanelMetrics.minHeight),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false
        )
        hosting = NSHostingView(rootView: SessionPanelView(shell: shell, runtime: runtime, presentation: presentation))
        hosting.sizingOptions = []
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // 그림자는 macOS가 창 모양(둥근 모서리)을 따라 그린다 (`shadow-float`)
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.contentView = hosting
        panel.setAccessibilityLabel("Session")
        wire(runtime)
        // 옆줄이 바뀌면 창 틀을 그 자리에서 맞춘다 (관찰의 한 박자를 기다리지 않는다: 내용이 낡은 창에 잘리지 않게)
        presentation.pane.onWindowChange = { [weak self] in self?.fit() }
    }

    /// 알약 동작 · Esc · 확인 카드 맞추기를 실제 연결에 잇는다 (OA D4a-3): 이 연결이 세션 route를 모르면(견본 · 시험용 가짜) 알약은 그려지지 않는다
    private func wire(_ runtime: ChatRuntime) {
        if let flow = runtime.pillFlow {
            shell.onSessionPill = { pill, session in Task { await flow.press(pill, session: session) } }
            shell.onSessionItemsChanged = { [weak flow] items in flow?.reconcile(sessions: items) }
        }
        // Esc: 열린 옆줄(꼬리 → 목록 → 접힘) → 열린 확인 카드 → 후보 메뉴 → (세션 패널 · 이슈 상세 …)
        let presentation = presentation
        shell.onEscapeSessionOverlay = { [weak runtime] in
            guard let runtime else { return false }
            if presentation.pane.escape() { return true }
            if let flow = runtime.pillFlow, flow.resumeCard != nil, !(flow.resumeCard?.busy ?? false) {
                flow.cancelResume()
                return true
            }
            if runtime.panelDesk.referentMenu != nil {
                runtime.panelDesk.closeReferentMenu()
                return true
            }
            return false
        }
    }

    var isVisible: Bool { panel.isVisible }

    /// 세션 패널 높이: 내용에 맞춰 320–520 (DS EdgePanel · OA-3)
    func height() -> CGFloat {
        min(EdgePanelMetrics.maxHeight, max(EdgePanelMetrics.minHeight, presentation.contentHeight))
    }

    /// 지금 자리: 이슈 패널 왼쪽 40pt, 위 맞춤. 옆줄(띠 36 · 펼침 256)이 있으면 창을 그만큼 왼쪽으로 넓힌다 (오른쪽 · 위 · 높이는 패널과 같다).
    /// 화면 왼쪽 여유가 모자라면 옆줄이 패널 틀 안으로 들어간다 (`SidePaneLayout.plan`)
    func targetFrame() -> NSRect? {
        guard let issue = issuePanelFrame() else { return nil }
        let base = Self.frame(issuePanel: issue, height: height())
        let visibleMinX = EdgeRailPanelController.screen?.visibleFrame.minX ?? base.minX - 10_000
        let room = base.minX - visibleMinX
        if presentation.pane.room != room { presentation.pane.room = room }
        return SidePaneLayout.windowFrame(panel: base, outside: presentation.pane.windowExtra)
    }

    /// 순수한 자리 규칙: 이슈 패널의 왼쪽 가장자리에서 40 떨어진다 (지금 보이는 간격 그대로, OA U3-45)
    nonisolated static func frame(issuePanel: NSRect, height: CGFloat) -> NSRect {
        let right = issuePanel.minX - SessionPanelMetrics.panelGap
        return NSRect(x: right - EdgePanelMetrics.width, y: issuePanel.maxY - height, width: EdgePanelMetrics.width, height: height)
    }

    /// 열었으면 true (이슈 패널이 없으면 false)
    @discardableResult
    func show() -> Bool {
        hosting.layoutSubtreeIfNeeded()
        guard let target = targetFrame() else { return false }
        appliedExtra = presentation.pane.windowExtra
        generation += 1
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.setFrame(target, display: false)
        } else {
            panel.setFrame(target, display: true)
        }
        // 키를 빼앗지 않는다: 눌렀을 때 키 창이 된다 (이슈 패널이 열릴 때의 키를 그대로 둔다)
        panel.orderFrontRegardless()
        presentation.shown = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = TFMotion.panelFade
            panel.animator().alphaValue = 1
        }
        return true
    }

    func hide() {
        guard panel.isVisible else { return }
        generation += 1
        let current = generation
        presentation.shown = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = TFMotion.panelFade
            panel.animator().alphaValue = 0
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(TFMotion.panelFade))
            guard let self, self.generation == current else { return }
            self.panel.orderOut(nil)
        }
    }

    /// 내용 높이 · 이슈 패널 자리가 바뀌면 위를 맞춘 채로 맞춘다. 이슈 패널이 세로 가운데로 다시 갈 때 같은 움직임으로 따라간다 (세션 패널 자신은 가운데로 서지 않는다: 이슈 패널의 위에 맞춘다)
    func fit() {
        guard panel.isVisible, presentation.shown, let target = targetFrame(), target != panel.frame else { return }
        let extra = presentation.pane.windowExtra
        if extra != appliedExtra {
            // 옆줄이 나타나거나 사라지거나 접힘 ↔ 펼침: 창 틀은 움직이지 않고 바로 맞춘다 (안의 두 겹이 크로스페이드한다)
            appliedExtra = extra
            panel.setFrame(target, display: true)
            panel.invalidateShadow()
        } else {
            EdgePanelMotion.move(panel, to: target, reduceMotion: shell.reduceMotion)
        }
    }
}
#endif
