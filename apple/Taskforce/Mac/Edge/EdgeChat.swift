#if os(macOS)
import AppKit
import Observation
import SwiftUI
import TaskforceKit
import TaskforceUI

/// 대화 · 기억 상태를 한 곳에 묶는다 (`TF_EDGE_SHELL`이 켜진 격리 Debug 실행에서만 만든다, `AppRuntime.chatRuntime`).
/// 앱 시작 때 세션에 한 번 붙어, 패널 · 설정 창이 떠 있는지와 상관없이 로그아웃 · 다른 계정 · 같은 UUID 재로그인에 초안 · 캐시 · 대기 전송을 비운다.
/// 저장 위치: 초안 · 아직 서버에 없는 빈 대화 · 보내는 중인 글 · 읽은 대화 · 기억은 모두 **이 객체의 메모리**뿐이다 (디스크 · UserDefaults 없음).
/// 앱을 끄면 사라지고, 다시 켜면 서버 대화에서 마지막 대화 · 범위를 읽어 되살린다 (A03)
@MainActor
final class ChatRuntime {
    let scope: AccountScope
    let memory: MemoryStore
    let chat: ChatStore
    /// 인용의 원문 링크를 연다 (테스트는 가짜로 바꾼다)
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    #if DEBUG
    /// 견본이면 가짜 서버 (스냅샷이 상태를 바꿔 가며 담는다)
    var sampleGateway: SampleChatGateway?
    #endif
    private var connectivityTask: Task<Void, Never>?

    init(gateway: any ChatGateway, scope: AccountScope = AccountScope(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.scope = scope
        memory = MemoryStore(gateway: gateway, scope: scope)
        chat = ChatStore(gateway: gateway, scope: scope, memory: memory, now: now)
    }

    /// 연결 경로를 두 저장소에 알린다 (오프라인에서 돌아오면 대화 목록을 다시 읽는다)
    func followConnectivity(_ updates: AsyncStream<Bool>) {
        connectivityTask?.cancel()
        connectivityTask = Task { [weak self] in
            var wasOnline = true
            for await online in updates {
                guard let self else { return }
                chat.pathChanged(online: online)
                memory.pathChanged(online: online)
                if online, !wasOnline { await chat.refresh() }
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
