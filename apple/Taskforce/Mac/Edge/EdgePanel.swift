#if os(macOS)
import AppKit
import SwiftUI
import TaskforceKit
import TaskforceUI

/// EdgePanel의 자리 (디자인 README › Layout): 380pt 폭, 모서리 18, 내용에 맞춰 520pt까지. 펼친 레일 왼쪽 12pt, 위가 레일과 같다.
enum EdgePanelMetrics {
    static let width: CGFloat = 380
    static let maxHeight: CGFloat = 520
    static let minHeight: CGFloat = 120
    static let radius: CGFloat = TFRadius.lg
    /// 레일과의 간격 (`space-md`)
    static let gap: CGFloat = TFSpace.md
    /// 머리 줄: 위 12 + 제목 20 + 아래 8
    static let headerHeight: CGFloat = 40

    /// 본문(+아래 입력칸) 높이에 맞춘 패널 높이
    static func height(body: CGFloat, footer: CGFloat = 0) -> CGFloat {
        min(maxHeight, max(minHeight, headerHeight + body + footer))
    }

    /// 패널 창의 자리 (화면 좌표, 아래가 0). 오른쪽은 펼친 레일 왼쪽에서 12pt, 위는 레일 위 모서리
    static func frame(height: CGFloat, railTop: CGFloat, screenMaxX: CGFloat) -> NSRect {
        NSRect(x: screenMaxX - EdgeRailLayout.railWidth - gap - width, y: railTop - height, width: width, height: height)
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
        let inConversation = shell.view == .chats && chat?.chat.mode == .chat
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    Group {
                        switch shell.view {
                        case .allWork:
                            workList
                        case .chats:
                            if let chat {
                                ChatPanelBody(runtime: chat, shell: shell)
                            } else {
                                PanelEmptyState(title: Self.noChats)
                            }
                        }
                    }
                    .padding(EdgeInsets(top: 0, leading: TFSpace.lg, bottom: TFSpace.md, trailing: TFSpace.lg))
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
        .scaleEffect(scale, anchor: .topTrailing)
        .animation(TFMotion.move(TFMotion.panelMove, reduceMotion: shell.reduceMotion), value: presentation.shown)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Taskforce")
    }

    @ViewBuilder
    private var header: some View {
        if shell.view == .chats, let chat {
            ChatPanelHeader(chat: chat.chat)
        } else {
            PanelHeader(title: shell.view.title)
        }
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
            contentRect: NSRect(x: 0, y: 0, width: EdgePanelMetrics.width, height: EdgePanelMetrics.maxHeight),
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
            screenMaxX: screen.frame.maxX
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
