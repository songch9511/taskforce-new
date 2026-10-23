#if os(macOS)
import AppKit
import SwiftUI
import TaskforceKit
import TaskforceUI

// Claude 데스크톱 세션 보기 (OA PR-D2, DZ 승인 2026-10-22 `oa-desktop-rail-dz` 시트 2 · 5): 레일의 데스크톱 링이나 Sessions의 줄을 눌러 연다. **읽기 전용(S1)** — 입력창이 없고, Taskforce는 어느 질문에도 답하지 않는다.
// 이 Mac에 있는 기록을 읽어 그대로 보인다. 글 · 경로 · 세션 id를 로그에 남기지 않는다. "via Taskforce"는 없다 (중계가 아직 없다).

/// Claude 세션 패널 창이 SwiftUI에 넘기는 값: 머리 · 본문 · 띠의 높이 (창 높이를 맞춘다) · 나타남
@MainActor
@Observable
final class EdgeClaudeAppPanelPresentation {
    var headHeight: CGFloat = 0
    var bodyHeight: CGFloat = 0
    var footerHeight: CGFloat = 0
    var shown = false
    /// 패널 왼쪽 바깥에 붙는 옆줄 (세션이 돌리는 백그라운드 일, 세션 보기 V1). 창을 왼쪽으로 넓히는 폭도 이것이 정한다
    let pane: SessionSidePaneModel
    /// 단계 묶음 · 줄의 보이는 상태
    let steps = SessionStepsState()
    /// 본문이 다시 계산돼도 대화가 그대로면 타임라인을 다시 만들지 않는다
    @ObservationIgnored let timeline = SessionTimelineMemo<ClaudeTimelineInput, ClaudeTimeline>()

    init(backgroundOpen: any BackgroundTaskOpenStore = InMemoryBackgroundTaskOpenStore()) {
        pane = SessionSidePaneModel(store: backgroundOpen)
    }

    var contentHeight: CGFloat { headHeight + bodyHeight + footerHeight }

    /// 지금 보는 세션 (같으면 아무 일도 없다)
    private(set) var sessionKey: String?

    /// 다른 세션을 연다: 옆줄이 그 세션의 것으로 바뀌고, 열어 둔 줄 · 읽은 본문은 비운다 (줄 id는 세션 안에서만 겹치지 않는다)
    func beginSession(_ key: String) {
        guard key != sessionKey else { return }
        sessionKey = key
        steps.reset()
        timeline.reset()
        pane.attach(session: key)
    }
}

/// Claude 패널 타임라인의 입력 (같으면 같은 타임라인)
struct ClaudeTimelineInput: Equatable {
    var turns: [ClaudeAppTurn]
    var state: SessionRunState
}

/// Claude 패널의 타임라인: 줄 · 단계 · 글 찾기표
struct ClaudeTimeline {
    let data: SessionTimelineData
    let entries: [SessionEntry]
    let turns: [String: ClaudeAppTurn]

    init(_ input: ClaudeTimelineInput) {
        data = SessionTimelineSource.claude(input.turns)
        entries = SessionTimeline.build(data.items, state: input.state)
        turns = Dictionary(input.turns.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }
}

/// Claude 세션 패널 (DS PanelHeader 세션 변형 · 본문 · 띠): 폭 380, 모서리 18, `panel` 재료, 높이는 내용에 맞춰 320–520.
/// - 머리: Claude 마크 · 제목(긴 제목은 끝을 줄임) · Open in Claude(띠가 같은 단추를 가져가면 뺀다), 둘째 줄 "{상태} · {폴더 이름}" (엉뚱한 세션에 가지 않게 하는 확인용)
/// - 본문: 데스크톱에서 친 말은 오른쪽 말풍선, Claude의 말은 패널에 그대로, 도구를 쓴 줄은 한 줄 회색(이름 + description만). 맨 아래가 가장 새 글이고 위 끝에 Show earlier
/// - 띠(입력창 자리): 승인 · 답을 기다릴 때만 제목("Approve in Claude" · "Answer in Claude") + Open in Claude. 승인 · 거절 단추는 없다
/// - 못 읽으면 "Couldn't load this chat" + Try again, Claude에서 닫으면 상태 말이 "Closed in Claude"가 되고 머리가 흐려진다 (대화는 그대로 읽는다)
struct ClaudeAppSessionPanelView: View {
    @Bindable var shell: EdgeShellModel
    @Bindable var presentation: EdgeClaudeAppPanelPresentation

    /// 맨 아래로 내릴 때를 알리는 값: 가장 새 글의 id와 글 수가 아니라 끝 글만 본다 (Show earlier로 앞이 늘 때는 그대로 두려고)
    private struct TailSignature: Equatable {
        var last: String?
        var phase: ClaudeAppConversation.Phase
    }

    private enum Anchor {
        static let bottom = "claude-app-bottom"
    }

    /// 맨 아래에서 이만큼(pt) 안이면 "맨 아래에 붙어 있다"로 본다
    static let pinnedSlack: CGFloat = SessionScrollPin.slack

    var body: some View {
        let scale = TFMotion.panelTransform(shown: presentation.shown, reduceMotion: shell.reduceMotion).scale
        // 옆줄(백그라운드 일)이 있으면 패널의 왼쪽 바깥에 붙는다: 같은 창 · 같은 위 · 같은 높이 (`SessionPanelFrame`)
        SessionPanelFrame(pane: presentation.pane, reduceMotion: shell.reduceMotion) { width in
            Group {
                if let id = shell.desktopPanelID, let conversation = shell.desktopConversation {
                    content(id, conversation)
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
        .accessibilityLabel(shell.desktopPanelID.map { shell.desktopTitle($0) } ?? AgentMarkKind.claudeCode.accessibilityName)
    }

    @ViewBuilder
    private func content(_ id: String, _ conversation: ClaudeAppConversation) -> some View {
        let status = shell.desktop?.liveStatus(for: id)
        let closed = shell.desktop?.viewingClosed == true
        let band = closed ? nil : status?.band
        VStack(spacing: 0) {
            header(id, status: status, closed: closed, showsOpen: band == nil)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { presentation.headHeight = $0 }
            // 글이 짧으면 머리 바로 아래부터, 길면 맨 아래(가장 새 글)에서 시작한다: 보이는 높이를 최소 높이로 줘 위에 붙인다
            GeometryReader { viewport in
                ScrollViewReader { proxy in
                    ScrollView {
                        transcript(id, conversation, status: status, closed: closed)
                            .padding(EdgeInsets(top: TFSpace.xs, leading: TFSpace.lg, bottom: TFSpace.sm, trailing: TFSpace.lg))
                            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { presentation.bodyHeight = $0 }
                            .frame(maxWidth: .infinity, minHeight: viewport.size.height, alignment: .top)
                    }
                    .defaultScrollAnchor(.bottom)
                    .scrollIndicators(.automatic)
                    // "Show earlier"로 창을 넓힌 뒤 펴기 전의 첫 줄을 위에 붙잡는다 (`SessionEntriesView`)
                    .environment(\.sessionScrollToEntry, SessionScrollTo { id in proxy.scrollTo(id, anchor: .top) })
                    // 맨 아래에 붙어 있는지 대화 상태에 알린다: 위로 거슬러 읽는 중에는 라이브 줄이 붙어도 위쪽 줄을 버리지 않는다 (`ClaudeAppConversation.pinnedToBottom`).
                    // 새 글로 내용이 늘어난 것은 사용자가 올린 것이 아니다 (`SessionScrollPin`): 붙어 있던 동안만 새 글을 따라 내려가고, 위로 올려 읽는 중이면 끌어내리지 않는다
                    .onScrollGeometryChange(for: SessionScrollSnapshot.self) { geometry in
                        SessionScrollSnapshot(visibleMaxY: geometry.visibleRect.maxY, contentHeight: geometry.contentSize.height, visibleHeight: geometry.visibleRect.height)
                    } action: { old, new in
                        conversation.pinnedToBottom = SessionScrollPin.next(pinned: conversation.pinnedToBottom, old: old, new: new)
                    }
                    .onChange(of: TailSignature(last: conversation.turns.last?.id, phase: conversation.phase)) {
                        if SessionScrollPin.shouldFollowNewContent(pinned: conversation.pinnedToBottom) { proxy.scrollTo(Anchor.bottom, anchor: .bottom) }
                    }
                }
            }
            footer(id, band: band)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { presentation.footerHeight = $0 }
        }
        // 옆줄(백그라운드 일): 이 세션의 일 목록을 먹이고, 닫힌 세션이면 돌던 일을 멈춘 것으로 하고, 꼬리 읽기는 이 세션의 이 Mac 기록 · 임시 폴더에서
        .task(id: id) {
            presentation.beginSession(id)
            presentation.pane.makeTail = { [weak shell] task in
                let cwd = shell?.desktop?.session(id: id)?.cwd ?? shell?.desktopRow(id)?.folderPath
                return (shell?.makeBackgroundTail ?? EdgeShellModel.liveBackgroundTail)(id, cwd, task)
            }
            presentation.pane.tasks = conversation.backgroundTasks
            presentation.pane.setClosed(closed)
        }
        .onChange(of: conversation.backgroundTasks) { _, tasks in presentation.pane.tasks = tasks }
        .onChange(of: closed) { _, closed in presentation.pane.setClosed(closed) }
    }

    // MARK: 머리

    private func header(_ id: String, status: ClaudeAppLiveStatus?, closed: Bool, showsOpen: Bool) -> some View {
        PanelHeader(
            title: shell.desktopTitle(id), agent: .claudeCode,
            pill: showsOpen && !closed ? PanelHeaderPill(title: ClaudeAppCopy.openInClaude) { shell.openDesktopInClaude(id) } : nil,
            status: Self.statusLine(status: status, closed: closed, folder: shell.desktopFolderName(id)), dimmed: closed
        )
    }

    /// 머리 둘째 줄: "{상태 말} · {폴더 이름}". 상태를 모르면(아직 읽는 중) 폴더 이름만, 둘 다 모르면 줄이 없다
    static func statusLine(status: ClaudeAppLiveStatus?, closed: Bool, folder: String?) -> String? {
        let word = closed ? ClaudeAppCopy.closedInClaude : status?.word
        let line = [word, folder].compactMap { $0 }.joined(separator: " · ")
        return line.isEmpty ? nil : line
    }

    // MARK: 본문

    @ViewBuilder
    private func transcript(_ id: String, _ conversation: ClaudeAppConversation, status: ClaudeAppLiveStatus?, closed: Bool) -> some View {
        switch conversation.phase {
        case .loading:
            Color.clear.frame(height: 0)
        case .failed:
            PanelEmptyState(title: ClaudeAppCopy.couldNotLoadChat) {
                Button(ClaudeAppCopy.tryAgain) { conversation.retry() }.buttonStyle(TFButtonStyle(.secondary, size: .md))
            }
        case .ready:
            // 단계 묶기 · 일한 시간 · 답 밑 줄(복사) · 도는 중 시계: 두 패널이 같은 순수 규칙(`SessionTimeline`)을 쓴다
            let input = ClaudeTimelineInput(turns: conversation.turns, state: SessionTimelineSource.runState(status, closed: closed))
            let timeline = presentation.timeline.value(for: input) { ClaudeTimeline(input) }
            let turns = timeline.turns
            VStack(alignment: .leading, spacing: 0) {
                // "Show earlier"는 본문이 맨 위에 하나만 세운다: 먼저 이미 읽어 둔 줄 중 창(가장 새 150줄) 밖의 것을 펴고, 다 폈으면 이 대화의 앞 쪽 기록을 읽는다
                SessionEntriesView(
                    entries: timeline.entries, steps: timeline.data.steps, state: presentation.steps,
                    earlierPage: SessionEarlierPage(available: conversation.hasEarlier, loading: conversation.loadingEarlier, load: { conversation.showEarlier() }),
                    loadDetail: { stepID in
                        guard let turn = turns[stepID] else { return nil }
                        return await conversation.detail(of: turn)
                    },
                    item: { itemID in
                        if let turn = turns[itemID] { ClaudeAppTurnView(turn: turn) }
                    }
                )
                Color.clear.frame(height: 1).id(Anchor.bottom)
            }
        }
    }

    // MARK: 띠 (입력창 자리)

    @ViewBuilder
    private func footer(_ id: String, band: ClaudeAppPanelBand?) -> some View {
        if let band {
            Notice(icon: band == .approve ? .execution : .talk, title: band.title) {
                Button(ClaudeAppCopy.openInClaude) { shell.openDesktopInClaude(id) }.buttonStyle(TFButtonStyle(.secondary, size: .sm))
            }
            .padding(EdgeInsets(top: TFSpace.sm, leading: TFSpace.md, bottom: TFSpace.md, trailing: TFSpace.md))
        } else {
            Color.clear.frame(height: TFSpace.sm)
        }
    }
}

/// 대화 한 줄 (읽기 전용): 데스크톱에서 친 말 · 다른 세션이 보낸 말은 오른쪽 말풍선, Claude의 말은 그대로, 도구 줄은 "이름 · description" 한 줄 회색
struct ClaudeAppTurnView: View {
    let turn: ClaudeAppTurn

    var body: some View {
        switch turn.kind {
        case .user(let text), .peer(let text, _):
            Message(isUser: true) { MessageText(Self.shown(text, truncated: turn.truncated)) }
        case .assistant(let text):
            // 안전한 부분만 그린다 (코드 블록 · 인라인 코드 · 목록 · 굵게): 링크 · 표 · 이미지 · HTML은 쓴 그대로 글자다
            Message(isUser: false) { SessionMarkdownView(source: Self.shown(text, truncated: turn.truncated)) }
        case .tool(let name, let description):
            EventLine(Self.toolLine(name: name, description: description))
        }
    }

    static func toolLine(name: String, description: String?) -> String {
        guard let description, !description.isEmpty else { return name }
        return "\(name) · \(description)"
    }

    /// 상한에서 잘린 글은 끝에 말줄임을 붙인다
    static func shown(_ text: String, truncated: Bool) -> String {
        truncated ? text + "…" : text
    }
}

/// Claude 세션 패널 창: `EdgeKeyPanel`과 같은 종류(borderless · nonactivating)의 창.
/// - Sessions 패널이 떠 있으면(`view == .sessions`) 그 왼쪽에 선다 (세션 패널과 같은 자리 규칙, OA U3-45)
/// - 레일의 링으로 열면(`view == .claudeApp`) 이슈 패널 없이 한 패널만 레일 옆, 다른 레일 패널처럼 레일 중심선에 세로 가운데로 선다 (DR-S1d · 사용자 결정 2026-10-22). 이때만 키 창이 된다 (Esc가 닿도록)
@MainActor
final class EdgeClaudeAppPanelController {
    let shell: EdgeShellModel
    let panel: EdgeKeyPanel
    let presentation: EdgeClaudeAppPanelPresentation
    private let hosting: NSHostingView<ClaudeAppSessionPanelView>
    private var generation = 0
    /// 창을 옆줄만큼 왼쪽으로 넓힌 폭의 마지막 값: 바뀌면 움직이지 않고 바로 맞춘다 (옆줄은 두 겹이 처음부터 최종 크기로 놓이고 크로스페이드만)
    private var appliedExtra: CGFloat = 0
    /// 메인 패널 창의 마지막으로 정해진 자리 (보이는 동안만). Sessions 옆에 설 때 그 왼쪽에 놓는다
    var mainPanelFrame: () -> NSRect? = { nil }

    /// - backgroundOpen: 백그라운드 일 옆줄의 "열어 본 시각" 저장소 (실제 앱은 영속, 시험 호스트 · 견본은 메모리)
    init(shell: EdgeShellModel, backgroundOpen: any BackgroundTaskOpenStore = InMemoryBackgroundTaskOpenStore()) {
        self.shell = shell
        presentation = EdgeClaudeAppPanelPresentation(backgroundOpen: backgroundOpen)
        panel = EdgeKeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: EdgePanelMetrics.width, height: EdgePanelMetrics.minHeight),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false
        )
        hosting = NSHostingView(rootView: ClaudeAppSessionPanelView(shell: shell, presentation: presentation))
        hosting.sizingOptions = []
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.contentView = hosting
        panel.setAccessibilityLabel(AgentMarkKind.claudeCode.accessibilityName)
        // Esc: 옆줄이 열려 있으면 꼬리 → 목록 → 접힘을 먼저 (그다음 패널)
        let presentation = presentation
        shell.onEscapeDesktopPane = { presentation.pane.escape() }
        // 옆줄이 바뀌면 창 틀을 그 자리에서 맞춘다 (관찰의 한 박자를 기다리지 않는다: 내용이 낡은 창에 잘리지 않게)
        presentation.pane.onWindowChange = { [weak self] in self?.fit() }
    }

    var isVisible: Bool { panel.isVisible }

    /// 레일 옆 한 패널인가 (Sessions 옆이 아니라)
    private var standalone: Bool { shell.view == .claudeApp }

    /// 높이: 내용에 맞춰 320–520 (세션 패널과 같다)
    func height() -> CGFloat {
        min(EdgePanelMetrics.maxHeight, max(EdgePanelMetrics.minHeight, presentation.contentHeight))
    }

    /// 레일 전체의 세로 가운데 (`EdgeRailPanelController.centerLineY`): 컨트롤러가 레일에 잇는다. 레일 창이 안 떠 있으면(nil) 화면 `midY`다
    var railCenterY: () -> CGFloat? = { nil }

    /// 지금 자리. Sessions 옆이면 메인 패널 왼쪽 (메인 패널 창이 아직 없으면 nil), 레일 옆 한 패널이면 다른 레일 패널처럼 레일 중심선에 세로 가운데로
    /// (OA PR-D2, 사용자 결정 2026-10-22: 보이는 화면 안으로 같은 규칙. `-TFEdgeSnapshotTopPlacement`만 옛 위 맞춤)
    /// 옆줄을 뺀 패널 자신의 자리 (폭 380)
    func panelFrame() -> NSRect? {
        if standalone {
            guard let screen = EdgeRailPanelController.screen else { return nil }
            guard EdgePanelMetrics.centersRailPanels else {
                return EdgePanelMetrics.frame(height: height(), railTop: EdgeRailPanelController.railTop(on: screen), screenMaxX: screen.frame.maxX, capsule: true)
            }
            return EdgePanelMetrics.centeredFrame(
                height: height(), centerY: railCenterY() ?? EdgeRailPanelController.railCenterY(on: screen), visible: screen.visibleFrame, screenMaxX: screen.frame.maxX, capsule: true
            )
        }
        guard let main = mainPanelFrame() else { return nil }
        return EdgeSessionPanelController.frame(issuePanel: main, height: height())
    }

    /// 창의 자리: 패널 자리에 옆줄(띠 36 · 펼침 256)을 더해 왼쪽으로 넓힌다 — 오른쪽(레일 쪽) · 위 · 높이는 패널과 같다 (DZ v2 E11).
    /// 화면 왼쪽 여유(`visibleFrame`)를 모델에 알려 모자라면 옆줄이 패널 틀 안으로 들어가게 한다
    func targetFrame() -> NSRect? {
        guard let base = panelFrame() else { return nil }
        let visibleMinX = EdgeRailPanelController.screen?.visibleFrame.minX ?? base.minX - 10_000
        let room = base.minX - visibleMinX
        if presentation.pane.room != room { presentation.pane.room = room }
        return SidePaneLayout.windowFrame(panel: base, outside: presentation.pane.windowExtra)
    }

    /// 열었으면 true (자리를 못 정하면 false)
    @discardableResult
    func show() -> Bool {
        hosting.layoutSubtreeIfNeeded()
        guard let target = targetFrame() else { return false }
        appliedExtra = presentation.pane.windowExtra
        generation += 1
        if !panel.isVisible {
            panel.alphaValue = 0
            let start = standalone && !shell.reduceMotion ? target.offsetBy(dx: TFMotion.panelHiddenOffset, dy: 0) : target
            panel.setFrame(start, display: false)
        }
        if standalone {
            panel.makeKeyAndOrderFront(nil)
        } else {
            // Sessions의 키를 빼앗지 않는다: 눌렀을 때 키 창이 된다
            panel.orderFrontRegardless()
        }
        presentation.shown = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = TFMotion.panelFade
            panel.animator().alphaValue = 1
        }
        if panel.frame != target {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = standalone && !shell.reduceMotion ? TFMotion.panelMove : 0
                panel.animator().setFrame(target, display: true)
            }
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

    /// 내용 높이 · 메인 패널 자리가 바뀌면 위를 맞춘 채로 맞춘다 (메인 패널이 세로 가운데로 다시 갈 때 같은 움직임으로 따라간다)
    func fit() {
        guard panel.isVisible, presentation.shown, let target = targetFrame(), !EdgePanelMotion.isSameFrame(target, panel.frame) else { return }
        let extra = presentation.pane.windowExtra
        if extra != appliedExtra {
            // 옆줄이 나타나거나 사라지거나 접힘 ↔ 펼침: 창 틀은 움직이지 않고 바로 맞춘다 (안의 두 겹이 크로스페이드한다). 그림자는 새 모양을 따른다
            appliedExtra = extra
            panel.setFrame(target, display: true)
            panel.invalidateShadow()
        } else {
            EdgePanelMotion.move(panel, to: target, reduceMotion: shell.reduceMotion)
        }
    }
}
#endif
