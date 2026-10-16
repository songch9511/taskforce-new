#if os(macOS)
import AppKit
import SwiftUI
import TaskforceKit
import TaskforceUI

/// EdgePanel의 자리 (디자인 README › Layout): 380pt 폭, 모서리 18, 내용에 맞춰 520pt까지. 펼친 레일 왼쪽 12pt, 위가 레일과 같다.
enum EdgePanelMetrics {
    static let width: CGFloat = 380
    static let maxHeight: CGFloat = 520
    /// DS `panel-min-height` 320: 결정 화면도 이 아래로 줄지 않는다 (세션 탭이 늘 패널의 평평한 가장자리에 닿는다)
    static let minHeight: CGFloat = 320
    static let radius: CGFloat = TFRadius.lg
    /// 레일과의 간격 (`space-md`)
    static let gap: CGFloat = TFSpace.md
    /// 머리 줄: 위 12 + 제목 20 + 아래 8
    static let headerHeight: CGFloat = 40

    /// 패널 본문의 안쪽 여백. 새 Issues 화면(M1 · M3 · M4)은 디자인대로 좌우 8 · 아래 10(행이 364 폭, 행 안쪽 10이 글 시작을 만든다).
    /// 그 밖의 화면(게이트가 꺼진 All work · Chats · Review)은 지금의 공통 좌우 16 · 아래 12 그대로다
    static func bodyInsets(issueScreens: Bool, view: EdgeShellModel.View) -> EdgeInsets {
        if issueScreens, view == .allWork {
            return EdgeInsets(top: 0, leading: TFSpace.sm, bottom: 10, trailing: TFSpace.sm)
        }
        return EdgeInsets(top: 0, leading: TFSpace.lg, bottom: TFSpace.md, trailing: TFSpace.lg)
    }

    /// 본문(+아래 입력칸) 높이에 맞춘 패널 높이
    static func height(body: CGFloat, footer: CGFloat = 0) -> CGFloat {
        min(maxHeight, max(minHeight, headerHeight + body + footer))
    }

    /// 패널 창의 자리 (화면 좌표, 아래가 0). 오른쪽은 펼친 레일 왼쪽에서 12pt, 위는 레일 위 모서리.
    /// `tab`: 패널 왼쪽에 붙는 SessionTab 띠의 폭 (OA U2: 창이 그만큼 왼쪽으로 넓다. 탭이 없으면 0)
    static func frame(height: CGFloat, railTop: CGFloat, screenMaxX: CGFloat, tab: CGFloat = 0) -> NSRect {
        NSRect(x: screenMaxX - EdgeRailLayout.railWidth - gap - width - tab, y: railTop - height, width: width + tab, height: height)
    }
}

/// 패널 창이 SwiftUI에 넘기는 값: 본문 높이(창 높이를 맞춘다) · 나타남(크기 .975 → 1)
@MainActor
@Observable
final class EdgePanelPresentation {
    var bodyHeight: CGFloat = 0
    /// 아래 입력칸(Chats)의 높이: 패널 높이에 더한다
    var footerHeight: CGFloat = 0
    var shown = false
    /// 패널 왼쪽 SessionTab 띠의 폭 (없으면 0, OA U2): 창 프레임이 그만큼 넓다
    var tabWidth: CGFloat = 0
}

/// 패널 (디자인 EdgePanel): 머리 · 본문 · (입력칸). 자기 탐색이 없고 닫기 버튼도 없다. 한 번에 한 화면.
struct EdgePanelView: View {
    @Bindable var shell: EdgeShellModel
    @Bindable var presentation: EdgePanelPresentation
    /// Chats · Remembered (B3). 없으면 Chats는 빈 화면
    var chat: ChatRuntime?

    /// 대화가 바뀌었는지 보는 서명: 새 글 · 상태가 바뀌면 맨 아래로 내린다
    private struct TranscriptSignature: Equatable {
        let id: UUID?
        let count: Int
        let last: ChatTurn.Status?
    }

    private var transcript: TranscriptSignature {
        guard let chat, shell.view == .chats, let id = chat.chat.currentID else { return TranscriptSignature(id: nil, count: 0, last: nil) }
        let turns = chat.chat.turns(for: id)
        return TranscriptSignature(id: id, count: turns.count, last: turns.last?.status)
    }

    var body: some View {
        // 이동(16pt)은 창이 움직이고, 크기(.975 → 1)는 여기서. 움직임 줄이기면 둘 다 없다
        let scale = TFMotion.panelTransform(shown: presentation.shown, reduceMotion: shell.reduceMotion).scale
        let showsTab = shell.showsSessionTab
        // 새 Issues 화면: 패널 왼쪽에 SessionTab 띠가 붙는다. 창이 그만큼 넓고 띠 밖은 투명해 클릭이 뒤로 지나간다
        HStack(alignment: .top, spacing: 0) {
            if showsTab { sessionTab }
            panel
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .scaleEffect(scale, anchor: .topTrailing)
        .animation(TFMotion.move(TFMotion.panelMove, reduceMotion: shell.reduceMotion), value: presentation.shown)
        .onChange(of: showsTab, initial: true) { _, shows in
            presentation.tabWidth = shows ? SessionTabGeometry.expanded.width : 0
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Taskforce")
    }

    /// 패널: 머리 · 본문 · (입력칸). 폭 380, 모서리 18, `panel` 재료
    private var panel: some View {
        let inConversation = shell.view == .chats && chat?.chat.mode == .chat
        return VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    Group {
                        switch shell.view {
                        case .allWork:
                            if shell.issueScreensEnabled { IssuesPanelBody(shell: shell) } else { workList }
                        case .chats:
                            if let chat {
                                ChatPanelBody(runtime: chat, shell: shell)
                            } else {
                                PanelEmptyState(title: Self.noChats)
                            }
                        case .review:
                            // S4 gate가 꺼져 있으면(`review == nil`) 이 화면은 열리지 않는다
                            if let desk = shell.review { ReviewPanelBody(shell: shell, desk: desk) }
                        }
                    }
                    .padding(EdgePanelMetrics.bodyInsets(issueScreens: shell.issueScreensEnabled, view: shell.view))
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { presentation.bodyHeight = $0 }
                }
                .defaultScrollAnchor(inConversation ? .bottom : .top)
                .scrollIndicators(.automatic)
                .onChange(of: transcript) {
                    if inConversation { proxy.scrollTo(EdgeChatScreen.bottomAnchor, anchor: .bottom) }
                }
            }
            if shell.view == .chats, let chat {
                ChatPanelFooter(chat: chat.chat)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { presentation.footerHeight = $0 }
                    .onDisappear { presentation.footerHeight = 0 }
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
    }

    /// 패널 왼쪽 가장자리의 SessionTab (이슈 상세 · 프로젝트 · Ungrouped 목록의 세션). 위는 패널 위에서 40 (필렛 10 포함해 30에서 시작)
    private var sessionTab: some View {
        let plan = shell.tabPlan
        #if DEBUG
        let expanded = shell.tabExpandedForSnapshot
        #else
        let expanded = false
        #endif
        return SessionTab(
            items: plan.shown.map { SessionTabItem($0, current: $0.id == shell.sessionPanelID) }, moreLabel: plan.moreLabel,
            expanded: expanded, reduceMotion: shell.reduceMotion, onOpen: { shell.openSession($0) },
            onMore: { shell.onShowMoreSessions(plan.hidden) }, onNew: { shell.newSession(from: .tab) }
        )
        .padding(.top, SessionTabMetrics.top - SessionTabGeometry.fillet)
    }

    @ViewBuilder
    private var header: some View {
        if shell.view == .chats, let chat {
            ChatPanelHeader(chat: chat.chat)
        } else if shell.view == .review, shell.review != nil {
            ReviewPanelHeader(shell: shell)
        } else if shell.issueScreensEnabled, shell.view == .allWork {
            // 새 Issues 화면: 머리는 지금 연 화면이 정한다. 뒤로는 목록 · 상세에, 직접 추가 `+`는 Done today를 뺀 이슈 목록에 (Add task = 기존 런처)
            PanelHeader(
                title: shell.panelTitle, onBack: shell.nav.canGoBack ? { shell.goBack() } : nil,
                onAdd: addsTask ? { shell.onAddTask() } : nil
            )
        } else {
            PanelHeader(title: shell.view.title)
        }
    }

    /// 머리 `+`(Add task)가 있나: 프로젝트 · Ungrouped 이슈 목록뿐
    private var addsTask: Bool {
        guard case .list(let scope) = shell.nav.current else { return false }
        return shell.issueList(scope)?.allowsAdd ?? false
    }

    /// Chats에 대화가 없음 (이 셸을 대화 저장소 없이 만들었을 때)
    static let noChats = ChatCopy.noConversations

    /// All work (S3): 기존 목록(`/api/v1/now` + 오늘 끝낸 할 일)을 WorkList로. 검색어 · 필터 · 고정은 셸 모델이 가진다.
    /// `shell.workItems`가 시각 신호(`timeEpoch`)를 읽으므로, 열린 채 자정 · 시간대 변경을 지나면 이 화면이 다시 그려져 Done today · today도 새로 정해진다
    private var workList: some View {
        WorkList(
            items: shell.workItems,
            load: shell.work.load,
            syncing: shell.work.syncing,
            filter: Binding(get: { shell.workFilter }, set: { shell.setFilter($0) }),
            filtersOpen: Binding(get: { shell.filtersOpen }, set: { shell.setFiltersOpen($0) }),
            pins: shell.pins,
            currentID: shell.currentID,
            highlightedID: shell.hoveredID,
            today: DueDateFormat.today(),
            projectsProblem: shell.projectsProblem,
            // 복귀 요약(C3): 검색칸 위. C3가 꺼져 있으면(`shell.summary == nil`) 늘 nil이라 지금 All work 그대로다
            summary: shell.summaryContent.map { content in
                AnyView(ReturnSummary(
                    content: content, onOpen: { shell.openSummaryRow($0) }, onClear: { shell.clearSummary() }, onRetry: { shell.retrySummary() }
                ))
            },
            detail: { id in
                // 멤버십을 아직 읽지 못했으면 아무것도 그리지 않는다 (빈 자리도 만들지 않는다)
                guard let store = shell.contexts, store.projectLinks(for: id) != nil else { return nil }
                return AnyView(WorkRowProjectLinks(actionID: id, store: store))
            },
            onOpen: { shell.open(itemID: $0) },
            onPin: { shell.pin($0) },
            onUnpin: { shell.unpin($0) },
            onAddTask: { shell.onAddTask() },
            onConnect: shell.work.canConnect ? { shell.onConnect() } : nil,
            onRetry: { shell.onRetry() }
        )
    }
}

/// 키를 받는 패널 창 (다른 앱을 앞에 둔 채로, Spotlight처럼)
final class EdgeKeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 패널 창: 열 때 투명도 180ms + 오른쪽 16pt에서 260ms(크기 .975 → 1), 닫을 때 거꾸로. 움직임 줄이기면 투명도만.
@MainActor
final class EdgePanelController {
    let shell: EdgeShellModel
    let panel: EdgeKeyPanel
    let presentation = EdgePanelPresentation()
    private let hosting: NSHostingView<EdgePanelView>
    private var generation = 0
    /// 여는 움직임 중 (그동안 높이 맞추기는 끝난 뒤로 미룬다)
    private var opening = false

    init(shell: EdgeShellModel, chat: ChatRuntime? = nil) {
        self.shell = shell
        panel = EdgeKeyPanel(
            // 새 Issues 화면이 켜진 셸은 SessionTab 띠(36)만큼 넓다. 꺼져 있으면 지금 그대로 380
            contentRect: NSRect(x: 0, y: 0, width: EdgePanelMetrics.width + (shell.issueScreensEnabled ? SessionTabGeometry.expanded.width : 0), height: EdgePanelMetrics.maxHeight),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        hosting = NSHostingView(rootView: EdgePanelView(shell: shell, presentation: presentation, chat: chat))
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
    }

    var isVisible: Bool { panel.isVisible }

    /// 지금 본문에 맞는 자리
    private func targetFrame() -> NSRect? {
        guard let screen = EdgeRailPanelController.screen else { return nil }
        return EdgePanelMetrics.frame(
            height: EdgePanelMetrics.height(body: presentation.bodyHeight, footer: presentation.footerHeight),
            railTop: EdgeRailPanelController.railTop(on: screen),
            screenMaxX: screen.frame.maxX,
            tab: presentation.tabWidth
        )
    }

    /// 열었으면 true (화면을 찾지 못하면 false)
    @discardableResult
    func show() -> Bool {
        // 처음 열 때도 본문 높이를 알고 자리를 잡는다
        hosting.layoutSubtreeIfNeeded()
        guard let target = targetFrame() else { return false }
        generation += 1
        let current = generation
        let reduceMotion = shell.reduceMotion
        // 닫히는 중에 다시 열면 지금 모습에서 이어서 연다 (투명도 · 자리를 처음으로 되돌리지 않는다)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.setFrame(reduceMotion ? target : target.offsetBy(dx: TFMotion.panelHiddenOffset, dy: 0), display: false)
        }
        panel.makeKeyAndOrderFront(nil)
        presentation.shown = true
        opening = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = TFMotion.panelFade
            context.timingFunction = Self.timing
            panel.animator().alphaValue = 1
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0 : TFMotion.panelMove
            context.timingFunction = Self.timing
            panel.animator().setFrame(target, display: true)
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == current else { return }
                self.opening = false
                self.fitToContent()
                self.panel.invalidateShadow()
            }
        }
        return true
    }

    func hide() {
        guard panel.isVisible else { return }
        generation += 1
        let current = generation
        let reduceMotion = shell.reduceMotion
        opening = false
        presentation.shown = false
        let frame = panel.frame
        NSAnimationContext.runAnimationGroup { context in
            context.duration = TFMotion.panelFade
            context.timingFunction = Self.timing
            panel.animator().alphaValue = 0
        }
        if !reduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = TFMotion.panelMove
                context.timingFunction = Self.timing
                panel.animator().setFrame(frame.offsetBy(dx: TFMotion.panelHiddenOffset, dy: 0), display: true)
            }
        }
        // 가장 긴 움직임이 끝나면 창을 내린다. 그 사이 다시 열었으면 둔다
        let longest = reduceMotion ? TFMotion.panelFade : TFMotion.panelMove
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(longest))
            guard let self, self.generation == current else { return }
            self.panel.orderOut(nil)
        }
    }

    /// 본문 높이가 바뀌면 위 모서리를 둔 채로 높이만 맞춘다
    func fitToContent() {
        guard !opening, panel.isVisible, presentation.shown, let target = targetFrame(), target != panel.frame else { return }
        panel.setFrame(target, display: true)
        panel.invalidateShadow()
    }

    private static let timing = CAMediaTimingFunction(
        controlPoints: Float(TFMotion.easeControlPoints.x1), Float(TFMotion.easeControlPoints.y1),
        Float(TFMotion.easeControlPoints.x2), Float(TFMotion.easeControlPoints.y2)
    )
}
#endif
