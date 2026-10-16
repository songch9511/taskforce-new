#if os(macOS)
import AppKit
import Observation
import SwiftUI
import TaskforceKit
import TaskforceUI

/// 창이 SwiftUI에 넘기는 값: 머리 · 본문 · 입력 영역의 높이(창 높이를 맞춘다) · 대상 알약의 자리 · 대상 메뉴가 열려 있나
@MainActor
@Observable
final class AssistantWindowPresentation {
    var headHeight: CGFloat = 0
    var bodyHeight: CGFloat = 0
    var footerHeight: CGFloat = 0
    /// 대상 알약의 자리 (창 좌표, 위가 0). 메뉴가 알약 위에 열린다
    var pillFrame: CGRect = .zero
    var targetMenuOpen = false

    /// 창이 담아야 할 내용의 높이 (머리 + 본문 + 입력 영역)
    var contentHeight: CGFloat { headHeight + bodyHeight + footerHeight }
}

/// 창이 하는 일 (컨트롤러가 채운다)
struct AssistantWindowActions {
    var toggleTargetMenu: () -> Void = {}
    var move: (AssistantWindowGeometry.Direction) -> Void = { _ in }
    /// 동의가 먼저 필요할 때 Connections를 연다
    var openConnections: () -> Void = {}
}

/// 떠 있는 Assistant 창의 내용 (디자인 AssistantWindow): 드래그 핸들 · 머리(대화 이름 · History · New chat) · 본문(대화 또는 History) · 입력 영역(PromptBox).
/// 380pt 폭, 모서리 18, `panel` 재료, 그림자는 창이 그린다 (`shadow-float`). 패널(EdgePanel)이 아니다: 레일 · 탭 · 바깥 클릭으로 닫기가 없다.
/// 본문은 대화(메시지)이고, 창 높이가 560을 넘으면 본문만 스크롤한다. 빈 대화는 칩 + 프롬프트뿐이다
struct AssistantWindowView: View {
    let model: AssistantWindowModel
    let runtime: ChatRuntime
    let presentation: AssistantWindowPresentation
    let reduceMotion: Bool
    var actions = AssistantWindowActions()

    private var chat: ChatStore { runtime.chat }

    /// 대화가 바뀌었는지 보는 서명: 새 글 · 상태가 바뀌면 맨 아래로 내린다
    private struct Signature: Equatable {
        let id: UUID
        let count: Int
        let last: ChatTurn.Status?
        let delivery: AgentDeliveryState?
    }

    private var signature: Signature {
        let turns = chat.turns(for: model.conversationID)
        return Signature(id: model.conversationID, count: turns.count, last: turns.last?.status, delivery: turns.last?.delivery?.state)
    }

    var body: some View {
        VStack(spacing: 0) {
            head
            ScrollViewReader { proxy in
                ScrollView {
                    bodyContent
                        .padding(EdgeInsets(top: 0, leading: TFSpace.lg, bottom: TFSpace.sm, trailing: TFSpace.lg))
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { presentation.bodyHeight = $0 }
                }
                .defaultScrollAnchor(model.mode == .chat ? .bottom : .top)
                .scrollIndicators(.automatic)
                .onChange(of: signature) {
                    if model.mode == .chat { proxy.scrollTo(AssistantBodyAnchor.bottom, anchor: .bottom) }
                }
            }
            footer
        }
        .frame(width: AssistantWindowGeometry.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: TFRadius.lg, style: .continuous).fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: TFRadius.lg, style: .continuous).fill(TFColor.bgPanel)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: TFRadius.lg, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Assistant")
        // 열린 에이전트 대화의 세션을 좁게 읽는다 (D4a-13b): 대화가 바뀌거나 첫 전달로 세션이 생기면 다시 읽는다. 열린 task가 있으면 저장소가 5초마다 이어 읽는다
        .task(id: runtime.chat.agentSessionID(for: model.conversationID)) { await model.agent?.sessions.refresh() }
    }

    // MARK: 머리

    private var head: some View {
        VStack(spacing: 0) {
            AssistantDragHandle(onMove: actions.move)
            HStack(spacing: TFSpace.xs) {
                Text(model.title)
                    .font(TFFont.calloutEmphasis)
                    .tracking(-0.24)
                    .foregroundStyle(TFColor.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
                    .help(model.title)
                TFIconButton(.chatHistory, label: ChatCopy.historyTitle, isOn: model.mode == .history) { model.toggleHistory() }
                TFIconButton(.newChat, label: ChatCopy.newChat) { model.newChat() }
            }
            // 머리 위 2 (DS `.tf-awin .tf-panel-head`): 핸들 아래
            .padding(EdgeInsets(top: 2, leading: TFSpace.lg, bottom: TFSpace.sm, trailing: 10))
            .background(AssistantDragRegion())
            if model.mode == .chat, !chat.isUnavailable, let project = chat.project(for: model.conversationID) {
                // 연결된 대화의 프로젝트는 머리에 둔다 (DS: Context appears in the header of linked work and linked chats only)
                ProjectLink(
                    project: project,
                    onChange: { choice in Task { await chat.chooseProject(choice, in: model.conversationID) } },
                    onUndo: { Task { await chat.undoProject(in: model.conversationID) } }
                )
                .padding(.horizontal, TFSpace.lg)
                .padding(.bottom, TFSpace.xs)
            }
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { presentation.headHeight = $0 }
    }

    // MARK: 본문

    @ViewBuilder
    private var bodyContent: some View {
        Group {
            switch model.mode {
            case .history: history
            case .chat: conversation
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var history: some View {
        switch chat.listScreen {
        case .blank:
            // 읽는 중: 아무 주장도 하지 않는다
            Color.clear.frame(height: 0)
        case .offline:
            PanelEmptyState(.offline) { tryAgain(.md) { chat.refreshInBackground() } }
        case .failed:
            PanelEmptyState(title: ChatCopy.couldNotLoad) { tryAgain(.md) { chat.refreshInBackground() } }
        case .ready(let problem):
            VStack(alignment: .leading, spacing: 0) {
                if let problem { problemNotice(problem, retry: { chat.refreshInBackground() }) }
                if chat.listIsEmpty {
                    if chat.isUnavailable {
                        PanelEmptyState(title: ChatCopy.unavailable) { tryAgain(.md) { chat.retryUnavailable() } }
                    } else {
                        PanelEmptyState(title: ChatCopy.noConversations) {
                            Button(ChatCopy.newChat) { model.newChat() }.buttonStyle(TFButtonStyle(.secondary, size: .md))
                        }
                    }
                } else {
                    ChatHistory(
                        entries: model.historyEntries, currentID: model.conversationID, mark: { model.mark(for: $0) },
                        onOpen: { model.openConversation($0) }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var conversation: some View {
        switch chat.screen(for: model.conversationID) {
        case .blank:
            Color.clear.frame(height: 0)
        case .offline:
            PanelEmptyState(.offline) { tryAgain(.md) { chat.ensureLoaded(model.conversationID) } }
        case .failed:
            PanelEmptyState(title: ChatCopy.couldNotLoadChat) { tryAgain(.md) { chat.ensureLoaded(model.conversationID) } }
        case .ready(let problem):
            VStack(alignment: .leading, spacing: TFSpace.md) {
                if let problem { problemNotice(problem, retry: { chat.ensureLoaded(model.conversationID) }) }
                if chat.needsConsent(in: model.conversationID) {
                    Notice(title: ChatCopy.consentNeeded) {
                        Button(ChatCopy.allowAIButton) { actions.openConnections() }.buttonStyle(TFButtonStyle(.secondary))
                    }
                }
                if chat.isUnavailable {
                    Notice(title: ChatCopy.unavailable) {
                        Button(ChatCopy.tryAgain) { chat.retryUnavailable() }.buttonStyle(TFButtonStyle(.secondary))
                    }
                }
                ForEach(chat.turns(for: model.conversationID)) { turn in
                    AssistantTurnView(turn: turn, runtime: runtime, actions: agentActions, onRetry: { cmid in Task { await chat.retry(cmid, in: model.conversationID) } })
                }
                // Stop 뒤의 말 (OA D4a-14): 대화 끝에 이벤트 줄 모양 한 줄 (이 창에서만 보이는 로컬 줄, 서버가 취소 요청을 지우면 사라진다)
                if let line = model.stopLineText { EventLine(line) }
                Color.clear.frame(height: 1).id(AssistantBodyAnchor.bottom)
            }
            .padding(.top, TFSpace.xs)
        }
    }

    /// 에이전트 대화의 줄 동작: 전달 줄 말 · Send again · 후보 고르기 메뉴 · View full (`AssistantWindowModel`이 정하고 이 창은 그린다)
    private var agentActions: AgentTurnActions {
        AgentTurnActions(
            line: { model.deliveryLine(for: $0) },
            onLink: { turn, link in
                switch link.kind {
                case .sendAgain: Task { await model.sendAgain(turn) }
                case .chooseReferent: model.openReferentMenu(for: turn.id)
                }
            },
            viewFull: { model.viewFull($0) },
            retry: { turn in Task { await model.retryDelivery(turn) } },
            referentMenu: model.referentMenu,
            chooseReferent: { id in Task { await model.chooseReferent(id) } },
            candidateLabel: { candidate in
                IssueNumberStore.label(runtime.issues?.numbers.number(for: candidate.actionID)).map { "\($0) \(candidate.title)" } ?? candidate.title
            }
        )
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

    // MARK: 입력 영역

    private var footer: some View {
        // 질문 · 확인 카드 자리는 프롬프트 박스 바로 위 (D4b-m · D4c-3m). 지금은 프롬프트 박스뿐
        VStack(spacing: TFSpace.sm) {
            PromptBox(
                text: Binding(get: { model.draft }, set: { model.setDraft($0) }),
                placeholder: model.placeholder,
                chips: model.chips.chips,
                chipLabel: { model.chipLabel($0) },
                targetName: model.targetName,
                targetMark: model.targetMark,
                targetOpen: presentation.targetMenuOpen,
                isBlocked: model.isBlocked,
                isRunning: model.stopPresentation.showsStop,
                canSend: model.canSend,
                focusRequest: model.focusRequest,
                onSend: { Task { await model.send(model.draft) } },
                onStop: { Task { await model.stop() } },
                onRemoveChip: { model.removeChip($0) },
                onTargetTap: actions.toggleTargetMenu,
                onTargetFrame: { presentation.pillFrame = $0 },
                // 에이전트 대상의 auto 칩은 눌러서 더한다 (D4a-12). 접근성 동작 이름은 새 문구라 승인 전에는 없다
                onActivateChip: model.toAgent ? { model.promoteChip($0) } : nil,
                chipActivationName: { AgentNewCopy.active.addChip($0.label) }
            )
        }
        .padding(EdgeInsets(top: 0, leading: TFSpace.md, bottom: TFSpace.md, trailing: TFSpace.md))
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { presentation.footerHeight = $0 }
    }
}

enum AssistantBodyAnchor {
    static let bottom = "assistant-bottom"
}

// MARK: 드래그

/// 마우스를 누른 곳에서 창을 끈다 (핸들 · 머리의 빈 곳). 그 위의 컨트롤(History · New chat)은 자기 클릭을 받는다
struct AssistantDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragNSView() }
    func updateNSView(_ view: NSView, context: Context) {}

    final class DragNSView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}

/// 36 × 4 핸들 (`border-default`, 위 6pt): 핸들과 머리의 빈 곳이 창을 끈다. 핸들에 포커스를 두고 화살표 키를 누르면 8pt씩 옮긴다
struct AssistantDragHandle: View {
    nonisolated static let height: CGFloat = 14
    let onMove: (AssistantWindowGeometry.Direction) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            AssistantDragRegion()
            Capsule()
                .fill(TFColor.borderDefault)
                .frame(width: 36, height: 4)
                .padding(.top, 6)
        }
        .frame(height: Self.height)
        .overlay {
            if focused {
                RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(TFColor.borderAccent, lineWidth: 2).padding(2)
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.leftArrow) { onMove(.left); return .handled }
        .onKeyPress(.rightArrow) { onMove(.right); return .handled }
        .onKeyPress(.upArrow) { onMove(.up); return .handled }
        .onKeyPress(.downArrow) { onMove(.down); return .handled }
        .accessibilityLabel("Move window")
    }
}
#endif
