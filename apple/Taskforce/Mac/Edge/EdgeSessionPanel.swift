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

    var contentHeight: CGFloat { headHeight + bodyHeight + footerHeight }
}

/// 세션 패널 (OA U2, DS PanelHeader 세션 변형 · SessionPage): 이슈 패널 왼쪽의 두 번째 패널. 머리(에이전트 마크 · "{이름} — #번호" · 알약 자리) · 상태 줄 · 본문(U1 `Message` 그대로) · Composer.
/// - 폭 380, 모서리 18, `panel` 재료, 높이는 내용에 맞춰 320–520. 닫기 버튼은 없다 (Esc · 바깥 클릭 · 다른 세션 · 뒤로)
/// - 알약(Open in Terminal · Resume here)은 **동작이 주어질 때만** 보인다: U2에서는 견본 하네스뿐이고 동작은 D4a다. 상태 줄은 세션의 말 (2.5 표)
/// - Composer는 그 세션의 대화(`conversations.agent_session_id`, 여럿이면 가장 새 것)로 `ChatStore.send(_:in:)`한다. 닫힌 세션은 읽기만 (상태 줄 "Closed", Composer 없음)
/// - 읽는 중 = 그리지 않음, 오프라인 · 읽기 실패 = 기존 화면 + Try again
struct SessionPanelView: View {
    @Bindable var shell: EdgeShellModel
    let runtime: ChatRuntime
    @Bindable var presentation: EdgeSessionPanelPresentation

    private var chat: ChatStore { runtime.chat }

    var body: some View {
        let scale = TFMotion.panelTransform(shown: presentation.shown, reduceMotion: shell.reduceMotion).scale
        Group {
            if let session = shell.openSessionItem {
                content(session)
            } else {
                Color.clear
            }
        }
        .frame(width: EdgePanelMetrics.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: EdgePanelMetrics.radius, style: .continuous).fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: EdgePanelMetrics.radius, style: .continuous).fill(TFColor.bgPanel)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: EdgePanelMetrics.radius, style: .continuous))
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
                            .padding(EdgeInsets(top: TFSpace.xs, leading: TFSpace.md, bottom: TFSpace.sm, trailing: TFSpace.md))
                            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { presentation.bodyHeight = $0 }
                            .frame(maxWidth: .infinity, minHeight: viewport.size.height, alignment: .top)
                    }
                    .defaultScrollAnchor(.bottom)
                    .scrollIndicators(.automatic)
                    .onChange(of: signature(session)) { proxy.scrollTo(AssistantBodyAnchor.bottom, anchor: .bottom) }
                }
            }
            footer(session)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { presentation.footerHeight = $0 }
        }
        .task(id: session.id) { await prepare(session) }
    }

    /// 머리 제목: "{세션 이름} — #{현재 이슈 번호}" (번호를 못 읽었거나 이슈가 정해지지 않으면 이름만, 지어내지 않는다)
    static func title(for session: AgentSessionItem, number: Int?) -> String {
        guard session.currentIssueID != nil, let label = IssueNumberStore.label(number) else { return session.name }
        return "\(session.name) — \(label)"
    }

    private func header(_ session: AgentSessionItem) -> some View {
        let number = session.currentIssueID.flatMap { shell.issues?.numbers.number(for: $0) }
        var pill: PanelHeaderPill?
        if let spec = session.pill, let action = shell.onSessionPill {
            pill = PanelHeaderPill(title: spec.title, disabledReason: spec.disabledReason) { action(spec, session) }
        }
        return PanelHeader(title: Self.title(for: session, number: number), agent: session.agent, pill: pill, status: session.line)
    }

    // MARK: 본문

    /// 맨 아래로 내릴 때를 알리는 값: 글 수와 마지막 글(상태 · 전달 표시가 바뀌어도 바뀐다)
    private struct BodySignature: Equatable {
        var count = 0
        var last: ChatTurn?
    }

    private func signature(_ session: AgentSessionItem) -> BodySignature {
        guard let id = session.conversationID else { return BodySignature() }
        let turns = chat.turns(for: id)
        return BodySignature(count: turns.count, last: turns.last)
    }

    @ViewBuilder
    private func bodyContent(_ session: AgentSessionItem) -> some View {
        if let conversationID = session.conversationID {
            switch chat.screen(for: conversationID) {
            case .blank:
                Color.clear.frame(height: 0)
            case .offline:
                PanelEmptyState(.offline) { Button(ChatCopy.tryAgain) { chat.ensureLoaded(conversationID) }.buttonStyle(TFButtonStyle(.secondary, size: .md)) }
            case .failed:
                PanelEmptyState(title: ChatCopy.couldNotLoadChat) {
                    Button(ChatCopy.tryAgain) { chat.ensureLoaded(conversationID) }.buttonStyle(TFButtonStyle(.secondary, size: .md))
                }
            case .ready(let problem):
                VStack(alignment: .leading, spacing: TFSpace.md) {
                    if let problem {
                        Notice(title: problem == .offline ? PanelEmptyKind.offline.title : ChatCopy.couldNotLoad) {
                            Button(ChatCopy.tryAgain) { chat.ensureLoaded(conversationID) }.buttonStyle(TFButtonStyle(.secondary, size: .sm))
                        }
                    }
                    ForEach(chat.turns(for: conversationID)) { turn in
                        AssistantTurnView(turn: turn, runtime: runtime, onRetry: { cmid in Task { await chat.retry(cmid, in: conversationID) } })
                    }
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

    @ViewBuilder
    private func footer(_ session: AgentSessionItem) -> some View {
        // 닫힌 세션은 읽기만 (Composer 없음). 대화를 모르는 세션도 보낼 곳이 없다
        if !session.isClosed, let conversationID = session.conversationID {
            Composer(
                text: Binding(get: { chat.draft(for: conversationID) }, set: { chat.setDraft($0, for: conversationID) }),
                placeholder: "Message \(session.agentName)", label: "Message \(session.agentName)", isDisabled: chat.isUnavailable,
                isSending: chat.isSending(in: conversationID),
                onSubmit: { text in Task { await chat.send(text, in: conversationID) } }
            )
            .padding(EdgeInsets(top: 10, leading: TFSpace.md, bottom: TFSpace.md, trailing: TFSpace.md))
        } else {
            Color.clear.frame(height: TFSpace.sm)
        }
    }

    /// 열 때: 이 세션의 대화를 읽고 현재 이슈의 번호를 읽는다
    private func prepare(_ session: AgentSessionItem) async {
        if let conversationID = session.conversationID {
            // 대화 목록에 아직 없으면(앱을 연 뒤 처음 · 방금 만든 세션) 목록을 먼저 읽고 글을 읽는다
            chat.ensureLoadedReadingListFirst(conversationID)
        } else {
            chat.refreshInBackground()
        }
        if let issue = session.currentIssueID { await shell.issues?.numbers.ensure([issue]) }
    }
}

/// 세션 패널 창 (OA U2-46): `EdgeKeyPanel`과 같은 종류(borderless · nonactivating)의 두 번째 창. 탭이 붙은 이슈 패널의 왼쪽 40pt, 위를 이슈 패널과 맞춘다.
/// 이슈 패널이 열려 있고 세션 패널이 열려 있을 때만 보이고, 높이는 내용에 맞춰 320–520이다
@MainActor
final class EdgeSessionPanelController {
    let shell: EdgeShellModel
    let panel: EdgeKeyPanel
    let presentation = EdgeSessionPanelPresentation()
    private let hosting: NSHostingView<SessionPanelView>
    private var generation = 0
    /// 이슈 패널 창의 자리 (탭 띠 포함). 세션 패널은 그 왼쪽에 놓인다
    var issuePanelFrame: () -> NSRect? = { nil }

    init(shell: EdgeShellModel, runtime: ChatRuntime) {
        self.shell = shell
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
    }

    var isVisible: Bool { panel.isVisible }

    /// 세션 패널 높이: 내용에 맞춰 320–520 (DS EdgePanel · OA-3)
    func height() -> CGFloat {
        min(EdgePanelMetrics.maxHeight, max(EdgePanelMetrics.minHeight, presentation.contentHeight))
    }

    /// 지금 자리: 이슈 패널(탭 띠 포함) 왼쪽 4pt (= 이슈 패널 본체에서 40pt), 위 맞춤
    func targetFrame() -> NSRect? {
        guard let issue = issuePanelFrame() else { return nil }
        return Self.frame(issuePanel: issue, height: height())
    }

    /// 순수한 자리 규칙: 이슈 패널 창(탭 띠 36 포함)의 왼쪽 가장자리에서 탭 폭 만큼 빼고 40 떨어진다 = 창 왼쪽에서 4
    nonisolated static func frame(issuePanel: NSRect, height: CGFloat) -> NSRect {
        let right = issuePanel.minX - (SessionTabMetrics.panelGap - SessionTabMetrics.expandedWidth)
        return NSRect(x: right - EdgePanelMetrics.width, y: issuePanel.maxY - height, width: EdgePanelMetrics.width, height: height)
    }

    /// 열었으면 true (이슈 패널이 없으면 false)
    @discardableResult
    func show() -> Bool {
        hosting.layoutSubtreeIfNeeded()
        guard let target = targetFrame() else { return false }
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

    /// 내용 높이 · 이슈 패널 자리가 바뀌면 위를 맞춘 채로 높이만 맞춘다
    func fit() {
        guard panel.isVisible, presentation.shown, let target = targetFrame(), target != panel.frame else { return }
        panel.setFrame(target, display: true)
        panel.invalidateShadow()
    }
}
#endif
