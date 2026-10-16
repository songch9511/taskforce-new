#if os(macOS)
import AppKit
import Observation
import SwiftUI
import TaskforceKit
import TaskforceUI

/// 대화 · 기억 · 범위 멤버십 상태를 한 곳에 묶는다 (`TF_EDGE_SHELL`이 켜진 격리 Debug 실행에서만 만든다, `AppRuntime.chatRuntime`).
/// 앱 시작 때 세션에 한 번 붙어, 패널 · 설정 창이 떠 있는지와 상관없이 로그아웃 · 다른 계정 · 같은 UUID 재로그인에 초안 · 캐시 · 대기 전송을 비운다.
/// 저장 위치: 초안 · 아직 서버에 없는 빈 대화 · 보내는 중인 글 · 읽은 대화 · 기억은 모두 **이 객체의 메모리**뿐이다 (디스크 · UserDefaults 없음).
/// 앱을 끄면 사라지고, 다시 켜면 서버 대화에서 마지막 대화 · 범위를 읽어 되살린다 (A03)
@MainActor
final class ChatRuntime {
    let scope: AccountScope
    let memory: MemoryStore
    let chat: ChatStore
    /// Assistant 창의 대상 목록 (OA U1): 대상 메뉴의 행. 이 빌드가 에이전트를 띄울 수 없으면(샌드박스) 모든 에이전트 행이 "Can't run agents in this build"다
    let targets: AssistantTargetsStore
    /// All work의 실제 범위(프로젝트) 멤버십 (S3b). 없으면 모든 할 일이 Ungrouped (범위를 읽지 않는다)
    let contexts: WorkContextStore?
    /// 새 Issues 화면(OA U2)의 세션 · 이슈 번호 · 이슈 상세 읽기. **게이트가 꺼져 있으면 nil** (`EdgeSurfaces.issueScreens`): 읽기도 타이머도 없다
    let issues: IssueRuntime?
    /// 에이전트 대화의 Stop 요청과 그 결과 (OA D4a-13): Assistant 창 · 세션 패널이 같이 쓴다. 이 연결이 Stop route를 모르면(견본 · 시험용 가짜) 요청이 없다
    let stop: AgentStopStore
    /// Assistant 창의 에이전트 대화 세션을 좁게 읽는다 (OA D4a-13b): 열린 대화의 세션과 그 task만. U2의 `issueScreens` 게이트와 상관없이 창이 열리면 읽는다 — 이 연결이 세션 읽기를 모르면 nil
    let agentTurns: AgentSessionStore?
    /// 세션 패널의 줄 동작 (Send again · 후보 고르기 메뉴 · View full, OA D4a-1): Assistant 창은 창마다 자기 것을 가진다
    let panelDesk: AgentTurnDesk
    /// 세션 패널 머리의 알약 흐름 (OA D4a-03 · 15 · 16): 서버 `open-external` · `resume-here`와 확인 카드. 이 연결이 세션 route를 모르면 nil.
    /// 터미널을 여는 launcher · 프로세스 검사기는 D4a-2가 넣는다 (지금은 launcher가 없어 Open in Terminal 알약이 없고, 검사기는 "못 찾음"이다)
    let pillFlow: AgentSessionPillFlow?
    /// 인용의 원문 링크를 연다 (테스트는 가짜로 바꾼다)
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    #if DEBUG
    /// 견본이면 가짜 서버 (스냅샷이 상태를 바꿔 가며 담는다)
    var sampleGateway: SampleChatGateway?
    var sampleContextGateway: SampleContextGateway?
    #endif
    private var connectivityTask: Task<Void, Never>?
    private var sleepObservers: [NSObjectProtocol] = []

    /// - issueScreens: 새 Issues 화면을 켜는가 (기본은 이 실행의 게이트 `EdgeSurfaces.issueScreens`). 켜져 있어도 이 연결이 `IssueScreensGateway`를 따르지 않으면(견본 · 시험용 가짜) 만들지 않는다
    init(
        gateway: any ChatGateway, contextGateway: (any ContextGateway)? = nil, scope: AccountScope = AccountScope(),
        now: @escaping @Sendable () -> Date = { Date() }, issueScreens: Bool = EdgeSurfaces.issueScreensForThisRun
    ) {
        #if DEBUG
        // 견본 하네스(`-TFEdgeSnapshotIssues`)는 세션 · 번호 · 상세와 프로젝트 아이콘이 있는 견본 서버를 읽는다 (실서버 · 기존 견본은 그대로)
        let gateway = issueScreens ? IssueSnapshotData.gateway(replacing: gateway) : gateway
        #endif
        self.scope = scope
        memory = MemoryStore(gateway: gateway, scope: scope)
        // 대상 목록 · 칩을 실은 보내기는 실제 연결(`LiveChatGateway`)만 가진다. 견본 · 시험용 가짜는 Taskforce 대상으로만 보낸다
        let assistant = gateway as? any AssistantGateway
        chat = ChatStore(gateway: gateway, scope: scope, memory: memory, now: now, assistant: assistant)
        targets = AssistantTargetsStore(gateway: assistant, scope: scope, canRunAgents: { !AgentRuntimeEnvironment.isSandboxed() })
        // 에이전트 대화의 쓰기 · 읽기(Send again · 후보 · Stop · 전달 읽기)와 세션 route도 실제 연결만 가진다 (`as?`, OA D4a-20b)
        let conversationRoutes = gateway as? any AgentConversationGateway
        let sessionRoutes = gateway as? any AgentSessionRequests
        chat.agentConversation = conversationRoutes
        panelDesk = AgentTurnDesk(chat: chat)
        stop = AgentStopStore(conversations: conversationRoutes, sessions: sessionRoutes, scope: scope)
        // launcher는 D4a-2가 넣는다: 지금은 없다 (Open in Terminal 알약을 그리지 않는다). 견본(`-TFEdgeSnapshotAgentChat`)만 터미널을 열지 않는 가짜를 달아 알약 모양을 Figma와 맞춰 본다
        #if DEBUG
        let launcher: (any AgentTerminalLauncher)? = AgentChatSnapshot.isEnabled ? SnapshotTerminalLauncher() : nil
        #else
        let launcher: (any AgentTerminalLauncher)? = nil
        #endif
        pillFlow = sessionRoutes.map { AgentSessionPillFlow(requests: $0, launcher: launcher, scope: scope) }
        let sessionReads = gateway as? any AgentSessionGateway
        let chatForFocus = chat
        agentTurns = sessionReads.map { AgentSessionStore(gateway: $0, scope: scope, now: now, focus: { chatForFocus.viewedAgentSessionIDs() }) }
        // View full: 이 Mac의 bridge 원장에서 서버 열쇠로 전문을 찾는다 (다른 Mac의 세션이거나 정리됐으면 없다). bridge가 꺼져 있으면 링크가 없다
        chat.fullTextLookup = { key in
            guard let runtime = await MainActor.run(body: { BridgeHost.shared?.activeRuntime }) else { return nil }
            return await runtime.fullText(forServerKey: key)
        }
        #if DEBUG
        // 견본 하네스(`-TFEdgeSnapshotIssues`)는 프로젝트 아이콘 · 긴 이름이 있는 견본 범위를 읽는다 (실서버 · 기존 견본은 그대로)
        let contextGateway = issueScreens ? IssueSnapshotData.contextGateway(replacing: contextGateway) : contextGateway
        #endif
        contexts = contextGateway.map { WorkContextStore(gateway: $0, scope: scope) }
        issues = issueScreens ? (gateway as? any IssueScreensGateway).map { IssueRuntime(gateway: $0, scope: scope, now: now) } : nil
        // Stop · 알약이 끝나면 세션을 다시 읽는다 (서버가 사실이다): 좁은 저장소와, 켜져 있으면 U2의 전체 저장소
        let narrow = agentTurns
        let full = issues?.sessions
        stop.onChanged = { Task { @MainActor in
            await narrow?.refresh()
            await full?.refresh()
        } }
        // 턴을 시작할 수 있는 모든 입구(패널 보내기 · Assistant 창 보내기 · Send again · 후보 고르기)가 세션을 다시 읽게 한다:
        // 쉬는 세션(열린 task 없음)은 5초 읽기가 돌지 않아, 다시 읽지 않으면 Stop 원이 서지 않는다
        chat.onAgentTurnMayStart = { Task { @MainActor in
            await narrow?.refresh()
            await full?.refresh()
        } }
        pillFlow?.onNeedsReread = { Task { @MainActor in
            await narrow?.refresh()
            await full?.refresh()
        } }
        followSleep()
    }

    /// 잠자기: 자는 동안 전달 읽기 · 세션 읽기 5초 시계가 멈추고, 깨면 한 번 읽는다 (OA D4a-10 · U2-35). 세션 패널이 켜진 구성은 컨트롤러가 U2 저장소를 따로 잇는다
    private func followSleep() {
        let center = NSWorkspace.shared.notificationCenter
        let chat = chat
        let narrow = agentTurns
        sleepObservers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    chat.setAsleep(true)
                    narrow?.setAsleep(true)
                }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    chat.setAsleep(false)
                    narrow?.setAsleep(false)
                }
            },
        ]
    }

    /// 연결 경로를 두 저장소에 알린다 (오프라인에서 돌아오면 대화 목록을 다시 읽는다)
    func followConnectivity(_ updates: AsyncStream<Bool>) {
        connectivityTask?.cancel()
        connectivityTask = Task { [weak self] in
            var wasOnline = true
            for await online in updates {
                guard let self else { return }
                chat.pathChanged(online: online)
                agentTurns?.pathChanged(online: online)
                memory.pathChanged(online: online)
                contexts?.pathChanged(online: online)
                issues?.pathChanged(online: online)
                if online, !wasOnline {
                    await chat.refresh()
                    await contexts?.refresh()
                }
                wasOnline = online
            }
        }
    }
}

/// Chats 화면 (디자인 ChatPage · ChatHistory): 머리(제목 · 새 대화 · history) · 본문(목록 또는 대화) · 입력칸.
/// 읽는 중 · 오프라인 · 실패 · 없음 · 기능 꺼짐은 서로 다른 화면이다. 업무 · 원문이 없어도 상담은 된다 (Composer는 늘 열려 있다).
enum EdgeChatScreen {
    static let bottomAnchor = "chat-bottom"
}

struct ChatPanelHeader: View {
    let chat: ChatStore

    var body: some View {
        PanelHeader(
            title: chat.headerTitle, onNewChat: { _ = chat.newChat() }, historyOpen: chat.mode == .history, onHistory: { chat.toggleHistory() }
        )
    }
}

struct ChatPanelBody: View {
    let runtime: ChatRuntime
    let shell: EdgeShellModel
    private var chat: ChatStore { runtime.chat }

    var body: some View {
        Group {
            switch chat.mode {
            case .history: history
            case .chat: conversation
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: 목록

    @ViewBuilder
    private var history: some View {
        switch chat.listScreen {
        case .blank:
            // 읽는 중: 아무 주장도 하지 않는다
            Color.clear.frame(height: 0)
        case .offline:
            PanelEmptyState(.offline) { tryAgain(.md) { Task { await chat.refresh() } } }
        case .failed:
            PanelEmptyState(title: ChatCopy.couldNotLoad) { tryAgain(.md) { Task { await chat.refresh() } } }
        case .ready(let problem):
            VStack(alignment: .leading, spacing: 0) {
                if let problem { problemNotice(problem, retry: { Task { await chat.refresh() } }) }
                if chat.listIsEmpty {
                    emptyHistory
                } else {
                    ChatHistory(entries: chat.entries, currentID: chat.currentID, onOpen: { chat.open($0) })
                }
            }
        }
    }

    @ViewBuilder
    private var emptyHistory: some View {
        if chat.isUnavailable {
            // 서버에서 꺼져 있다: 실패가 아니다
            PanelEmptyState(title: ChatCopy.unavailable) { tryAgain(.md) { chat.retryUnavailable() } }
        } else {
            PanelEmptyState(title: ChatCopy.noConversations) {
                Button(ChatCopy.newChat) { _ = chat.newChat() }.buttonStyle(TFButtonStyle(.secondary, size: .md))
            }
        }
    }

    // MARK: 대화

    @ViewBuilder
    private var conversation: some View {
        switch chat.screen {
        case .blank:
            Color.clear.frame(height: 0)
        case .offline:
            PanelEmptyState(.offline) { tryAgain(.md) { reloadThread() } }
        case .failed:
            PanelEmptyState(title: ChatCopy.couldNotLoadChat) { tryAgain(.md) { reloadThread() } }
        case .ready(let problem):
            if let id = chat.currentID {
                VStack(alignment: .leading, spacing: TFSpace.md) {
                    if let problem { problemNotice(problem, retry: reloadThread) }
                    if chat.needsConsent {
                        Notice(title: ChatCopy.consentNeeded) {
                            Button(ChatCopy.allowAIButton) { shell.onConnect() }.buttonStyle(TFButtonStyle(.secondary))
                        }
                    }
                    if chat.isUnavailable {
                        Notice(title: ChatCopy.unavailable) {
                            Button(ChatCopy.tryAgain) { chat.retryUnavailable() }.buttonStyle(TFButtonStyle(.secondary))
                        }
                    }
                    if !chat.isUnavailable, let project = chat.project(for: id) {
                        ProjectLink(project: project, onChange: { choice in Task { await chat.chooseProject(choice) } }, onUndo: { Task { await chat.undoProject() } })
                    }
                    ForEach(chat.turns(for: id)) { turn in
                        ChatTurnView(turn: turn, runtime: runtime, onRetry: { cmid in Task { await chat.retry(cmid) } })
                    }
                    Color.clear.frame(height: 1).id(EdgeChatScreen.bottomAnchor)
                }
                .padding(.top, TFSpace.xs)
            }
        }
    }

    private func reloadThread() {
        guard let id = chat.currentID else { return }
        Task { await chat.loadThread(id) }
    }

    private func problemNotice(_ problem: WorkLoad.Problem, retry: @escaping () -> Void) -> some View {
        Notice(title: problem == .offline ? PanelEmptyKind.offline.title : ChatCopy.couldNotLoad) {
            tryAgain(.sm, action: retry)
        }
        .padding(.bottom, TFSpace.sm)
    }

    private func tryAgain(_ size: TFButtonStyle.Size, action: @escaping () -> Void) -> some View {
        Button(ChatCopy.tryAgain, action: action).buttonStyle(TFButtonStyle(.secondary, size: size))
    }
}

/// 대화의 한 줄: 사용자 글(+상태 한 줄) 또는 Taskforce의 말(+인용 · 기억 노트)
struct ChatTurnView: View {
    let turn: ChatTurn
    let runtime: ChatRuntime
    let onRetry: (UUID) -> Void

    var body: some View {
        if turn.isUser {
            VStack(alignment: .leading, spacing: TFSpace.xs) {
                Message(isUser: true) { MessageText(turn.text, isDeleted: turn.textDeleted) }
                ChatStatusLine(status: turn.status, onRetry: { turn.clientMessageID.map(onRetry) })
            }
            .accessibilityElement(children: .contain)
        } else {
            VStack(alignment: .leading, spacing: TFSpace.sm) {
                Message(isUser: false) {
                    VStack(alignment: .leading, spacing: TFSpace.sm) {
                        MessageText(turn.text, isDeleted: turn.textDeleted)
                        ForEach(Array(turn.citations.enumerated()), id: \.offset) { _, citation in
                            CitationView(citation: citation, open: runtime.openURL)
                        }
                    }
                }
                ForEach(turn.rememberedIDs, id: \.self) { id in
                    RememberedNoteHost(id: id, memory: runtime.memory)
                }
            }
        }
    }
}

/// 답의 근거 인용: 원문 그대로, 서비스의 마크 · 원문 이름 · 시각 (밑줄 없음). Slack 연결을 끊어 지운 인용은 기존 문구로
struct CitationView: View {
    let citation: ChatCitation
    let open: (URL) -> Void

    var body: some View {
        let kind = SourceKind(rawValue: citation.sourceKind) ?? .note
        let service = SourceService.infer(externalURL: citation.externalURL, kind: kind)
        let removed = RemovedQuote.isRemoved(citation.quote)
        SourceQuote(
            service: service, place: citation.sourceTitle, time: citation.occurredAt.map { WhenText.label($0) },
            text: removed ? RemovedQuote.label : citation.quote, openTitle: service.openTitle,
            onOpen: removed ? nil : citation.externalURL.map { url in { open(url) } }
        )
    }
}

/// 답 아래 RememberedNote: `refs.memory_item_ids`가 가리키는 기억을 RLS로 읽은 지금 상태로 보인다. 성공은 서버 응답 뒤에만
struct RememberedNoteHost: View {
    let id: UUID
    let memory: MemoryStore

    var body: some View {
        switch memory.noteState(for: id) {
        case .loading:
            Color.clear.frame(height: 0)
        case .notRemembered:
            RememberedNote(content: nil, onConfirm: {}, onEdit: { _ in }, onForget: {})
        case .current(let item):
            let key = item.id
            RememberedNote(
                content: RememberedNote.Content(
                    statement: MemoryText.statement(item), meta: MemoryText.meta(item, contexts: memory.contexts, withTime: false),
                    isTentative: MemoryText.isTentative(item), canConfirm: memory.canConfirm(item), canChange: true, isBusy: memory.isBusy(key),
                    message: memory.feedback(for: key)?.text, writesUnavailable: memory.writesUnavailable
                ),
                onConfirm: { Task { await memory.confirm(key) } },
                onEdit: { text in Task { await memory.edit(key, statement: text) } },
                onForget: { Task { await memory.forget(key) } }
            )
            .id(key)
        }
    }
}

/// 패널 아래 입력칸 (대화 중일 때만). 초안은 대화마다 이 저장소의 메모리에 있고, 패널을 접거나 화면을 옮겨도 지워지지 않는다
struct ChatPanelFooter: View {
    let chat: ChatStore

    var body: some View {
        if chat.mode == .chat, let id = chat.currentID {
            Composer(
                text: Binding(get: { chat.draft(for: id) }, set: { chat.setDraft($0, for: id) }), placeholder: chat.composerPlaceholder,
                isDisabled: !chat.canCompose, isSending: chat.isSending, focusRequest: chat.focusRequest, onSubmit: { text in Task { await chat.send(text) } }
            )
            .id(id)
            .padding(EdgeInsets(top: 0, leading: TFSpace.lg, bottom: 14, trailing: TFSpace.lg))
        }
    }
}
#endif
