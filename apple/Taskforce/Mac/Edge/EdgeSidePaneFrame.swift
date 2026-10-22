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

/// 두 세션 패널(Claude 읽기 전용 · Taskforce)의 바깥 틀: 패널 재질 면 하나(폭 380 · 모서리 18)와, 백그라운드 일이 있을 때 그 왼쪽 바깥에 붙는 옆줄(띠 36 · 펼침 256).
/// - 옆줄은 패널 창을 왼쪽으로 넓혀(`SessionSidePaneModel.windowExtra`, 컨트롤러가 창 틀을 맞춘다) 같은 창 안에서 그린다: 패널과 같은 위 · 같은 높이, 패널이 움직이면 같이 움직인다
/// - 맞닿은 모서리는 직각이고(패널의 왼쪽 · 옆줄의 오른쪽) 맞닿은 면에는 1px 헤어라인만 있다. 창 그림자는 바깥 3면만이다 (창 모양을 따른다)
/// - 왼쪽 화면 여유가 모자라면: 띠는 패널 틀 안으로 들어가 대화 폭을 줄이고(344), 펼침은 패널의 왼쪽 위로 덮는다 (`SidePaneLayout.plan`)
struct SessionPanelFrame<Panel: View>: View {
    @Bindable var pane: SessionSidePaneModel
    let reduceMotion: Bool
    /// 패널 내용: 폭(대화 폭)을 받는다
    @ViewBuilder var panel: (CGFloat) -> Panel

    var body: some View {
        let plan = pane.plan
        let attached = plan.outside > 0
        HStack(spacing: 0) {
            if plan.outside > 0 {
                side(overlaying: false)
                    .frame(width: plan.outside)
                    .frame(maxHeight: .infinity)
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
        .animation(TFMotion.move(TFMotion.panelMove, reduceMotion: reduceMotion), value: pane.expanded)
    }

    /// 바깥의 옆줄 한 겹 (접힘이면 띠, 펼침이면 옆줄): 면은 같고 안만 바뀐다
    private func side(overlaying: Bool) -> some View {
        SidePaneSurface(overlaying: overlaying) {
            ZStack {
                if pane.expanded {
                    SidePaneBody(model: pane)
                        .transition(.modifier(active: SidePaneAppear(progress: 0, reduceMotion: reduceMotion), identity: SidePaneAppear(progress: 1, reduceMotion: reduceMotion)))
                } else {
                    SidePaneStrip(model: pane)
                        .transition(.opacity)
                }
            }
        }
    }
}
#endif
