#if os(macOS)
import AppKit
import SwiftUI
import TaskforceKit
import TaskforceUI

/// EdgePanel의 자리 (디자인 README › Layout): 380pt 폭, 모서리 18, 내용에 맞춰 520pt까지. 펼친 레일 왼쪽 12pt.
/// 노치 레일(Release · 게이트 꺼짐)은 위가 레일과 같고(화면 위에서 120), 캡슐 레일(OA U3)은 오른쪽이 화면 끝 − 62(캡슐 6 + 44 + 12)이며 위는 그대로다 (U3-11).
enum EdgePanelMetrics {
    static let width: CGFloat = 380
    static let maxHeight: CGFloat = 520
    /// DS `panel-min-height` 320: 노치 레일(게이트 꺼짐) 화면은 이 아래로 줄지 않는다. 캡슐 레일 구성은 내용에 맞춘다 (Projects 하나 · 짧은 목록, OA U3-31)
    static let minHeight: CGFloat = 320
    static let radius: CGFloat = TFRadius.lg
    /// 레일과의 간격 (`space-md`)
    static let gap: CGFloat = TFSpace.md
    /// 머리 줄: 위 12 + 제목 20 + 아래 8
    static let headerHeight: CGFloat = 40

    /// 패널 본문의 안쪽 여백. 새 Issues 화면(M1 · M3 · M4)은 디자인대로 좌우 8 · 아래 10(행이 364 폭, 행 안쪽 10이 글 시작을 만든다).
    /// 그 밖의 화면(게이트가 꺼진 All work · Chats · Review)은 지금의 공통 좌우 16 · 아래 12 그대로다
    static func bodyInsets(issueScreens: Bool, view: EdgeShellModel.View) -> EdgeInsets {
        if issueScreens, view == .allWork || view == .sessions {
            return EdgeInsets(top: 0, leading: TFSpace.sm, bottom: 10, trailing: TFSpace.sm)
        }
        return EdgeInsets(top: 0, leading: TFSpace.lg, bottom: TFSpace.md, trailing: TFSpace.lg)
    }

    /// 본문(+아래 입력칸) 높이에 맞춘 패널 높이. `fits`: 바닥 없이 내용에 맞춘다 (캡슐 구성, 520까지)
    static func height(body: CGFloat, footer: CGFloat = 0, fits: Bool = false) -> CGFloat {
        min(maxHeight, max(fits ? 0 : minHeight, headerHeight + body + footer))
    }

    /// 패널 창의 자리 (화면 좌표, 아래가 0). 오른쪽은 펼친 레일 왼쪽에서 12pt, 위는 `railTop`(화면 위에서 120).
    /// `capsule`: 캡슐 레일이면 레일이 화면 끝에서 6 안쪽이라 패널도 그만큼 안쪽이다 (오른쪽 = 화면 끝 − 6 − 44 − 12)
    static func frame(height: CGFloat, railTop: CGFloat, screenMaxX: CGFloat, capsule: Bool = false) -> NSRect {
        NSRect(x: rightEdge(screenMaxX: screenMaxX, capsule: capsule) - width, y: railTop - height, width: width, height: height)
    }

    /// 패널의 오른쪽 가장자리 (화면 좌표): 노치 레일은 끝 − 44 − 12, 캡슐 레일은 끝 − 6 − 44 − 12 = 끝 − 62
    static func rightEdge(screenMaxX: CGFloat, capsule: Bool) -> CGFloat {
        screenMaxX - (capsule ? RailCapsuleMetrics.inset : 0) - EdgeRailLayout.railWidth - gap
    }

    // MARK: 세로 가운데 (OA PR-D2, 사용자 결정 2026-10-22)

    /// 레일이 여는 패널(Projects · Chats · Sessions, 그리고 데스크톱 링으로 연 Claude 세션 패널)은 **레일의 중심선**에 세로 가운데로 선다: 캡슐 레일의 열은 늘 화면 세로 가운데에서 자라므로(`EdgeRailCapsuleLayout.windowFrame`) 그 중심선은 화면 `midY`다.
    /// More 카드는 가운데로 옮기지 않는다 (⋯ 옆, `RailMoreCardGeometry`). 메인 패널 왼쪽의 세션 패널 · Claude 세션 패널은 메인 패널의 위 맞춤 그대로다.
    /// 아래 모서리 y (화면 좌표, 아래가 0): 중심선 위아래로 높이의 절반씩 두되 **보이는 화면**(메뉴 막대 · Dock 뺀 `visibleFrame`) 안으로 넣는다.
    /// 보이는 화면보다 높은 패널은 위(머리)를 맞춘다: 머리가 잘리지 않고, 넘치는 쪽은 아래다
    static func centeredOriginY(height: CGFloat, centerY: CGFloat, visible: CGRect) -> CGFloat {
        let lowest = visible.minY
        let highest = visible.maxY - height
        guard highest >= lowest else { return highest }
        return min(max(centerY - height / 2, lowest), highest)
    }

    /// 세로 가운데 맞춘 패널 창의 자리: 가로는 지금 그대로(레일 왼쪽 12pt, 폭 380), 세로만 `centeredOriginY`
    static func centeredFrame(height: CGFloat, centerY: CGFloat, visible: CGRect, screenMaxX: CGFloat, capsule: Bool) -> NSRect {
        NSRect(x: rightEdge(screenMaxX: screenMaxX, capsule: capsule) - width, y: centeredOriginY(height: height, centerY: centerY, visible: visible), width: width, height: height)
    }

    /// 열려 있는 동안 높이가 바뀌어 다시 가운데로 가는 움직임의 시간 (패널 페이드와 같다, 움직임 줄이기면 바로)
    static let recenterDuration: TimeInterval = TFMotion.panelFade

    /// 레일이 여는 패널을 세로 가운데로 세우나. 견본의 "전 · 후" 비교만 끈다 (`-TFEdgeSnapshotTopPlacement`, Debug 전용 — Release 바이너리에는 이 인자가 없다: 늘 가운데)
    static var centersRailPanels: Bool {
        #if DEBUG
        return !ProcessInfo.processInfo.arguments.contains("-TFEdgeSnapshotTopPlacement")
        #else
        return true
        #endif
    }
}

/// 열려 있는 패널 창의 자리를 부드럽게 옮긴다 (내용 높이가 바뀌어 다시 가운데로 갈 때 튀지 않게). 메인 패널 · 세션 패널 · Claude 세션 패널이 같은 길을 쓴다
@MainActor
enum EdgePanelMotion {
    /// 0.5pt보다 작은 차이는 움직이지 않는다
    static func move(_ window: NSWindow, to target: NSRect, reduceMotion: Bool) {
        let frame = window.frame
        guard abs(frame.minX - target.minX) > 0.5 || abs(frame.minY - target.minY) > 0.5 || abs(frame.width - target.width) > 0.5 || abs(frame.height - target.height) > 0.5 else { return }
        if reduceMotion || !window.isVisible {
            window.setFrame(target, display: true)
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = EdgePanelMetrics.recenterDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().setFrame(target, display: true)
            }
        }
        window.invalidateShadow()
    }

    /// 1pt보다 작은 차이는 같은 틀이다: 두 세션 패널의 `fit()`이 쓴다. 안에서 재는 높이가 소수점만 흔들려도 창을 다시 맞추지(움직이지) 않는다 (#187 핫픽스: 흔들리는 높이가 창 맞춤을 되먹임으로 부르지 않게)
    static func isSameFrame(_ a: NSRect, _ b: NSRect) -> Bool {
        abs(a.minX - b.minX) < 1 && abs(a.minY - b.minY) < 1 && abs(a.width - b.width) < 1 && abs(a.height - b.height) < 1
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
        panel
            .frame(maxHeight: .infinity, alignment: .top)
            .scaleEffect(scale, anchor: .topTrailing)
            .animation(TFMotion.move(TFMotion.panelMove, reduceMotion: shell.reduceMotion), value: presentation.shown)
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
                        case .sessions:
                            SessionsPanelBody(shell: shell)
                        case .claudeApp:
                            // 이 화면의 본문은 레일 옆 Claude 세션 패널 창이 그린다 (메인 패널 창은 이때 뜨지 않는다)
                            Color.clear.frame(height: 0)
                        case .review:
                            // S4 gate가 꺼져 있으면(`review == nil`) 이 화면은 열리지 않는다. Taskforce 대화가 켜진 구성은 요청 카드 한 장 + 끝의 요약이다
                            if let desk = shell.review {
                                if shell.taskforceEnabled {
                                    TaskforcePanelBody(shell: shell, desk: desk)
                                } else {
                                    ReviewPanelBody(shell: shell, desk: desk)
                                }
                            }
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

    @ViewBuilder
    private var header: some View {
        if shell.view == .chats, let chat {
            ChatPanelHeader(chat: chat.chat)
        } else if shell.view == .review, shell.review != nil {
            if shell.taskforceEnabled { TaskforcePanelHeader(shell: shell) } else { ReviewPanelHeader(shell: shell) }
        } else if shell.issueScreensEnabled, shell.view == .allWork {
            // The header follows the current screen; back returns to the list.
            PanelHeader(
                title: shell.panelTitle, onBack: shell.nav.canGoBack ? { shell.goBack() } : nil
            )
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

    /// 지금 본문에 맞는 자리 (여는 움직임 중에도 끝에 닿을 자리: Sessions 왼쪽 패널이 이 자리를 기준으로 선다).
    /// 캡슐 레일(새 Issues 화면)은 레일 중심선에 세로 가운데로 서고 보이는 화면 안으로 들어온다 (`EdgePanelMetrics.centeredFrame`). 노치 레일(Release · 게이트 꺼짐)은 지금 그대로 위가 화면 위에서 120이다
    func targetFrame() -> NSRect? {
        guard let screen = EdgeRailPanelController.screen else { return nil }
        let height = EdgePanelMetrics.height(body: presentation.bodyHeight, footer: presentation.footerHeight, fits: shell.issueScreensEnabled)
        if shell.issueScreensEnabled, EdgePanelMetrics.centersRailPanels {
            return EdgePanelMetrics.centeredFrame(
                height: height, centerY: railCenterY() ?? EdgeRailPanelController.railCenterY(on: screen), visible: screen.visibleFrame, screenMaxX: screen.frame.maxX, capsule: true
            )
        }
        return EdgePanelMetrics.frame(height: height, railTop: EdgeRailPanelController.railTop(on: screen), screenMaxX: screen.frame.maxX, capsule: shell.issueScreensEnabled)
    }

    /// 레일 전체의 세로 가운데 (`EdgeRailPanelController.centerLineY`): 컨트롤러가 레일에 잇는다. 레일 창이 안 떠 있으면(nil) 화면 `midY`다
    var railCenterY: () -> CGFloat? = { nil }

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

    /// 본문 높이가 바뀌면 높이를 맞추고 다시 가운데로 간다 (캡슐 레일: 위아래로 절반씩 부드럽게, 노치 레일: 위 모서리를 둔 채)
    func fitToContent() {
        guard !opening, panel.isVisible, presentation.shown, let target = targetFrame(), target != panel.frame else { return }
        EdgePanelMotion.move(panel, to: target, reduceMotion: shell.reduceMotion)
    }

    private static let timing = CAMediaTimingFunction(
        controlPoints: Float(TFMotion.easeControlPoints.x1), Float(TFMotion.easeControlPoints.y1),
        Float(TFMotion.easeControlPoints.x2), Float(TFMotion.easeControlPoints.y2)
    )
}
#endif
