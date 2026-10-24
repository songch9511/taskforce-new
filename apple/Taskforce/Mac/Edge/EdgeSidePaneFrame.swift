#if os(macOS)
import AppKit
import SwiftUI
import TaskforceKit
import TaskforceUI

/// 옆줄이 나타나고 사라질 때 · 접힘 ↔ 펼침의 움직임 (DZ v2 E8 · 움직임): 펼침은 opacity 0 → 1에 translateX(16) · scale(.975) → 없음 (원점 = 맞닿은 가장자리), 띠는 opacity.
/// 움직임 줄이기: transform 없이 opacity만. width · height · padding · margin은 움직이지 않는다 (두 겹이 처음부터 최종 크기로 놓이고 크로스페이드만)
struct SidePaneAppear: ViewModifier {
    let progress: Double
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .opacity(progress)
            .offset(x: reduceMotion ? 0 : TFMotion.panelHiddenOffset * (1 - progress))
            .scaleEffect(reduceMotion ? 1 : TFMotion.panelHiddenScale + (1 - TFMotion.panelHiddenScale) * progress, anchor: .topTrailing)
    }
}

/// Agent sessions use a persistent card canvas with root/child chat overlays.
/// The conversation body stays mounted so transcript discovery and scroll state survive navigation;
/// input footers are mounted only by the panel when `allowsRootInput` is true.
/// Command-only sessions retain the existing side pane below.
/// 두 세션 패널(Claude 읽기 전용 · Taskforce)의 바깥 틀: 패널 재질 면 하나(폭 380 · 모서리 18)와, 백그라운드 일이 있을 때 그 왼쪽 바깥에 붙는 옆줄(띠 36 · 펼침 256).
/// - 옆줄은 패널 창을 왼쪽으로 넓혀(`SessionSidePaneModel.windowExtra`, 컨트롤러가 창 틀을 맞춘다) 같은 창 안에서 그린다: 패널과 같은 위 · 같은 높이, 패널이 움직이면 같이 움직인다
/// - 맞닿은 모서리는 직각이고(패널의 왼쪽 · 옆줄의 오른쪽) 맞닿은 면에는 1px 헤어라인만 있다. 창 그림자는 바깥 3면만이다 (창 모양을 따른다)
/// - 왼쪽 화면 여유가 모자라면: 띠는 패널 틀 안으로 들어가 대화 폭을 줄이고(344), 펼침은 패널의 왼쪽 위로 덮는다 (`SidePaneLayout.plan`)
struct SessionPanelFrame<Panel: View>: View {
    @Bindable var pane: SessionSidePaneModel
    let reduceMotion: Bool
    var root: AgentTreeRoot? = nil
    var childComposer: (TaskforceKit.BackgroundTask) -> AnyView = { _ in AnyView(EmptyView()) }
    /// 패널 내용: 폭(대화 폭)을 받는다
    @ViewBuilder var panel: (CGFloat) -> Panel

    @ViewBuilder
    var body: some View {
        if let root, pane.hasAgentTree {
            treeContent(root)
                .onAppear { pane.onWindowChange?() }
                .onChange(of: pane.canvasWidth) { pane.onWindowChange?() }
        } else {
            legacyContent
        }
    }

    private func treeContent(_ root: AgentTreeRoot) -> some View {
        let stacked = pane.canvasWidth < 700
        let chatWidth = pane.showsTree ? (stacked ? pane.canvasWidth : 320) : EdgePanelMetrics.width
        let treeWidth = stacked ? pane.canvasWidth : pane.canvasWidth - 321
        let treeHeight: CGFloat = stacked ? 260 : min(640, (EdgeRailPanelController.screen?.visibleFrame.height ?? 664) - 24)
        let layout = stacked ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
        return layout {
            VStack(spacing: 0) {
                PanelHeader(title: root.title, agent: root.agent)
                SidePaneClockView(ticking: pane.effective.runningCount > 0) { now in
                    AgentTreeCanvas(root: root, rows: pane.canvasRows, now: now, rootExpanded: $pane.rootExpanded, focusedID: $pane.focusedCardID, onOpen: { id in
                        if let id { pane.openAgentChat(id) } else { pane.selectRootInTree() }
                    }, onToggle: { row in pane.canvasExpansion.toggle(id: row.id, level: row.level) },
                    onCollapse: { pane.openRootChat() }, selectedID: pane.selectedID ?? AgentTreeCanvas.rootID, isActive: pane.showsTree)
                    .id(pane.sessionKey)
                }
            }
            .frame(width: treeWidth)
            .frame(height: treeHeight)
            .frame(width: pane.showsTree ? treeWidth : 0, height: pane.showsTree ? treeHeight : 0)
            .clipped()
            .opacity(pane.showsTree ? 1 : 0)
            .allowsHitTesting(pane.showsTree)
            .accessibilityElement(children: .contain)
            .accessibilityHidden(!pane.showsTree)
            Rectangle().fill(TFColor.borderDefault)
                .frame(width: stacked ? nil : (pane.showsTree ? 1 : 0), height: stacked ? (pane.showsTree ? 1 : 0) : nil)
            VStack(spacing: 0) {
                if !pane.showsTree {
                    HStack {
                        Button { pane.returnToTree() } label: { Label("Back to tree", systemImage: "chevron.left") }
                            .buttonStyle(.plain).font(TFFont.footnoteEmphasis)
                        Spacer()
                    }.padding(TFSpace.lg)
                }
                ZStack {
                    panel(chatWidth)
                        .opacity(pane.allowsRootInput ? 1 : 0)
                        .allowsHitTesting(pane.allowsRootInput)
                        .disabled(!pane.allowsRootInput)
                        .accessibilityElement(children: .contain)
                        .accessibilityHidden(!pane.allowsRootInput)
                    if let task = pane.selected {
                        VStack(spacing: 0) {
                            HStack {
                                Text(task.title).font(TFFont.footnoteEmphasis)
                                    .lineLimit(2).help(task.title)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }.padding(TFSpace.lg)
                            if let tail = pane.tail { SidePaneTail(tail: tail, task: task).id(task.id) }
                            else { Spacer(minLength: 0) }
                            childComposer(task)
                        }
                    }
                }
            }
            .frame(width: chatWidth).frame(maxHeight: .infinity)
        }
        .onChange(of: pane.showsTree) { _, shown in
            guard shown, let focused = pane.focusedCardID else { return }
            pane.focusedCardID = nil
            Task { @MainActor in
                await Task.yield()
                guard pane.showsTree else { return }
                pane.focusedCardID = focused
            }
        }
        .frame(width: pane.showsTree ? pane.canvasWidth : EdgePanelMetrics.width).frame(maxHeight: .infinity)
        .background(TFColor.bgPanel)
        .clipShape(RoundedRectangle(cornerRadius: EdgePanelMetrics.radius))
    }

    @ViewBuilder
    private var legacyContent: some View {
        let plan = pane.plan
        let attached = plan.outside > 0
        HStack(spacing: 0) {
            if plan.outside > 0 {
                side(overlaying: false)
                    .frame(width: plan.outside)
                    .frame(maxHeight: .infinity)
                    .transition(.opacity)
            }
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    if plan.cut > 0 {
                        SidePaneStrip(model: pane)
                            .frame(width: plan.cut)
                            .overlay(alignment: .trailing) { Rectangle().fill(TFColor.borderDefault).frame(width: 1) }
                            .transition(.opacity)
                    }
                    panel(EdgePanelMetrics.width - plan.cut)
                }
                if plan.overlay {
                    side(overlaying: true)
                        .frame(width: SidePaneLayout.paneWidth)
                        .frame(maxHeight: .infinity)
                        .transition(.opacity)
                }
            }
            .frame(width: EdgePanelMetrics.width)
            .frame(maxHeight: .infinity, alignment: .top)
            .background {
                ZStack {
                    SidePaneShapes.panel(attachedLeading: attached).fill(.ultraThinMaterial)
                    SidePaneShapes.panel(attachedLeading: attached).fill(TFColor.bgPanel)
                }
            }
            .clipShape(SidePaneShapes.panel(attachedLeading: attached))
        }
        // 옆줄이 처음 나타나거나 사라질 때만 불투명도로 (그때 레이아웃에서 바뀌는 것은 옆줄이 서는 자리뿐이다). 폭 · 높이 · 안쪽 여백은 움직이지 않는다 (DZ v2 E8): 창 틀은 모델이 바뀐 자리에서 바로 맞춰지고 내용은 처음부터 최종 크기다
        .animation(TFMotion.ease(TFMotion.panelFade), value: Appearance(attached: attached, overlay: plan.overlay))
        // 창이 모델을 따라오지 못한 한 박자에도 패널(레일 쪽 가장자리)은 제자리다: 오른쪽 끝에 붙인다
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
    }

    /// 옆줄 한 겹이 나타나거나 사라지는 경우 (바깥 옆줄 · 자리가 모자랄 때 덮는 펼침)
    private struct Appearance: Equatable {
        var attached: Bool
        var overlay: Bool
    }

    /// 바깥의 옆줄 한 겹 (접힘이면 띠, 펼침이면 옆줄): 면은 같고 안만 바뀐다.
    /// 접힘 ↔ 펼침의 움직임(불투명도 · 이동 · 크기 조정)은 이 안쪽 두 겹에만 건다: 바깥 틀의 폭은 애니메이션이 닿지 않는다
    private func side(overlaying: Bool) -> some View {
        SidePaneSurface(overlaying: overlaying) {
            ZStack {
                if pane.expanded {
                    SidePaneBody(model: pane, reduceMotion: reduceMotion)
                        .transition(.modifier(active: SidePaneAppear(progress: 0, reduceMotion: reduceMotion), identity: SidePaneAppear(progress: 1, reduceMotion: reduceMotion)))
                } else {
                    SidePaneStrip(model: pane)
                        .transition(.opacity)
                }
            }
            .animation(TFMotion.move(TFMotion.panelMove, reduceMotion: reduceMotion), value: pane.expanded)
        }
    }
}
#endif
