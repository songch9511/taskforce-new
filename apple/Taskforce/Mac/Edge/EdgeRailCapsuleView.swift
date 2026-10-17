#if os(macOS)
import SwiftUI
import TaskforceKit
import TaskforceUI

/// 캡슐 레일 (OA U3, 디자인 EdgeRail): 늘 `bezel` 검정의 캡슐 셋 — ① Taskforce bell ② 살아 있는 세션 링과 `+` ③ Projects · Chats · More.
/// 한 구역은 한 캡슐이고 캡슐 사이에 구분선이 없다. 열은 늘 창의 세로 가운데에서 자라며(`EdgeRailCapsuleLayout`) 접힘은 열 전체가 오른쪽 가운데를 기준으로 .72배가 된다.
/// 투명한 곳은 그리지 않아 클릭이 아래 앱으로 간다. 움직임 줄이기면 접힘 ↔ 펼침 · 열 가운데 맞추기는 바로 바뀌고 캡슐이 나고 지는 것은 불투명도만 움직인다.
struct EdgeRailCapsuleView: View {
    @Bindable var shell: EdgeShellModel
    let onMore: (CGRect) -> Void
    /// More 카드가 닫히면 VoiceOver 포커스가 ⋯로 돌아온다 (OA U3 16.1)
    @AccessibilityFocusState private var moreFocused: Bool
    @AccessibilityFocusState private var otherFocused: Bool

    private var slide: Animation? { TFMotion.move(TFMotion.railSlide, reduceMotion: shell.reduceMotion) }

    /// 캡슐이 나고 지는 것: 불투명도 160ms (움직임 줄이기에서도 그대로)
    private var fade: AnyTransition { .opacity.animation(TFMotion.ease(TFMotion.ringFade)) }

    var body: some View {
        let layout = shell.capsuleLayout
        ZStack(alignment: .topLeading) {
            if let bar = layout.restBarDrawn {
                RoundedRectangle(cornerRadius: RailCapsuleMetrics.restBarRadius, style: .continuous)
                    .fill(TFColor.bezelBase)
                    .overlay(RoundedRectangle(cornerRadius: RailCapsuleMetrics.restBarRadius, style: .continuous).strokeBorder(Color.white.opacity(RailCapsuleMetrics.edgeLineOpacity), lineWidth: RailCapsuleMetrics.edgeLineWidth))
                    .shadow(color: .black.opacity(RailCapsuleMetrics.shadowOpacity), radius: RailCapsuleMetrics.shadowRadius, y: RailCapsuleMetrics.shadowOffset)
                    .frame(width: bar.width, height: bar.height)
                    .offset(x: bar.minX, y: bar.minY)
                    .transition(fade)
                    .accessibilityHidden(true)
            }
            // ① bell
            if let capsule = layout.bellCapsuleDrawn, let item = layout.bellItemDrawn, let bell = shell.taskforceBell {
                capsuleBackground(capsule)
                RailBell(bell, expanded: layout.expanded, highlighted: shell.railBellHoverLit, selectionShown: shell.railBellSelectionShown, reduceMotion: shell.reduceMotion) {
                    shell.openTaskforce()
                }
                .offset(x: item.minX, y: item.minY)
                .transition(fade)
            }
            // ② 살아 있는 세션 링과 New session `+`
            if let capsule = layout.sessionsCapsuleDrawn {
                capsuleBackground(capsule)
                ForEach(Array(visibleRings(layout).enumerated()), id: \.element.id) { index, entry in
                    if let frame = layout.ringDrawn(index) {
                        ring(entry, layout: layout).offset(x: frame.minX, y: frame.minY)
                    }
                }
                if let frame = layout.plusDrawn {
                    RailButton(icon: .addTask, label: EdgeShellModel.newSessionLabel, highlighted: shell.railPlusLit, circular: true) {
                        shell.newSession(from: .rail)
                    }
                    .offset(x: frame.minX, y: frame.minY)
                    .accessibilityHidden(!layout.expanded)
                    .transition(fade)
                }
            }
            // ③ Projects · Chats · More
            if let capsule = layout.thirdCapsuleDrawn {
                capsuleBackground(capsule)
                ForEach(shell.controls, id: \.self) { control in
                    if let frame = layout.controlDrawn(control) {
                        RailButton(icon: shell.railIcon(for: control), label: shell.label(for: control), highlighted: highlighted(control), circular: true) {
                            switch control {
                            case .allWork: shell.openAllWork()
                            case .chats: shell.openChats()
                            case .more: onMore(layout.controlFrame(control) ?? frame)
                            }
                        }
                        .accessibilityFocused(control == .more ? $moreFocused : $otherFocused)
                        // 포커스는 ⋯ 칸 자신이 받는다: 칸이 그려져 있지 않으면(접힌 레일) 받지 못하고 알리지도 않는다
                        .onChange(of: shell.moreFocusSerial) { _, serial in
                            guard control == .more else { return }
                            moreFocused = true
                            shell.moreFocusLanded(serial)
                        }
                        .offset(x: frame.minX, y: frame.minY)
                    }
                }
            }
        }
        .frame(width: EdgeRailCapsuleLayout.windowWidth, height: EdgeRailCapsuleLayout.windowHeight, alignment: .topLeading)
        // 열 전체가 오른쪽 가운데를 기준으로 줄어든다 (접힘 .72배): 자리는 바뀌지 않고 transform만 바뀐다
        .scaleEffect(layout.scale, anchor: UnitPoint(x: layout.anchor.x / EdgeRailCapsuleLayout.windowWidth, y: 0.5))
        .animation(slide, value: layout)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(shell.railAccessibilityLabel)
    }

    private func capsuleBackground(_ frame: CGRect) -> some View {
        RailCapsuleBackground()
            .frame(width: frame.width, height: frame.height)
            .offset(x: frame.minX, y: frame.minY)
            .transition(fade)
            .accessibilityHidden(true)
    }

    /// 지금 모양에서 보이는 링: 접힘은 노치(앞의 셋), 펼침은 칸 전체
    private func visibleRings(_ layout: EdgeRailCapsuleLayout) -> [RailEntry] {
        Array((layout.expanded ? shell.slots : shell.notch).prefix(layout.shownRings))
    }

    private func ring(_ entry: RailEntry, layout: EdgeRailCapsuleLayout) -> some View {
        RailItem(
            kind: entry.kind, title: entry.title, state: entry.state, activity: entry.activity, expanded: layout.expanded,
            highlighted: shell.railRingLit(entry.id),
            reduceMotion: shell.reduceMotion, look: .capsule
        ) {
            shell.openRailEntry(entry)
        }
        .transition(fade)
    }

    private func highlighted(_ control: EdgeShellModel.Control) -> Bool {
        shell.railControlHighlighted(control)
    }
}
#endif
