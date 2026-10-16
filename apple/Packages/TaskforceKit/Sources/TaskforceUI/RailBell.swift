import SwiftUI
import TaskforceKit

/// Taskforce bell (OA U3, DS EdgeRail "The Taskforce bell"): 레일 첫 캡슐의 유일한 칸. Lucide `bell` 16pt, 늘 `bezel-ink` 흰색 — 주황이 되지 않는다(얇아 보인다).
/// 요청이 기다리면(`rings`) 도착 bounce 한 번 뒤 2.4초마다 1.12배로 숨쉬고, 얇은 흰 echo 링(1.5pt)이 1.75배로 퍼지며 사라지고,
/// 숨 시작에 위(12%)를 기준으로 ±14° 흔들린다. 움직임 줄이기: 불투명도만. 요청이 0이 되는 순간 멈춘다 (이 모양이 사라진다).
/// 대화가 열려 있으면(`selected`) 칸 원이 `bezel-hover`로 칠해지고 요청이 남아 있으면 계속 울린다. 칠함은 펼친 레일에서만 보인다 (접힘에서는 칸이 없다).
/// 접근성 이름은 "Taskforce · Needs your answer, 2 items" / "Taskforce · Nothing waiting" (`TaskforceBell`), 열려 있으면 선택됨.
public struct RailBell: View {
    let state: TaskforceBell
    let expanded: Bool
    let highlighted: Bool
    let reduceMotion: Bool
    let action: () -> Void

    public init(_ state: TaskforceBell, expanded: Bool, highlighted: Bool = false, reduceMotion: Bool = false, action: @escaping () -> Void) {
        self.state = state
        self.expanded = expanded
        self.highlighted = highlighted
        self.reduceMotion = reduceMotion
        self.action = action
    }

    /// bell 글리프의 크기 (DS `size={16}`, 확대 없음)
    nonisolated public static let glyph: CGFloat = 16

    public var body: some View {
        Button(action: action) {
            bell
                .frame(width: RailCapsuleMetrics.item, height: RailCapsuleMetrics.item)
                .background {
                    Circle().fill(expanded && (state.selected || highlighted) ? TFColor.bezelHover : .clear)
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(state.accessibilityName)
        .accessibilityAddTraits(state.selected ? .isSelected : [])
    }

    @ViewBuilder private var bell: some View {
        let glyph = TFIcon.taskforce.image(size: Self.glyph).foregroundStyle(TFColor.bezelInk)
        if state.rings {
            NeedsYouAnimation(reduceMotion: reduceMotion, bell: true) { frame in
                ZStack {
                    glyph
                        .rotationEffect(.degrees(frame.rotation), anchor: UnitPoint(x: 0.5, y: 0.12))
                        .scaleEffect(frame.scale)
                        .opacity(frame.opacity)
                    if frame.echoOpacity > 0 {
                        // 흰 echo (1.5pt): 숨마다 하나, 밖 5pt에서 1.75배로
                        Circle()
                            .strokeBorder(TFColor.bezelInk, lineWidth: 1.5)
                            .frame(width: (Self.glyph + 10) * frame.echoScale, height: (Self.glyph + 10) * frame.echoScale)
                            .opacity(frame.echoOpacity)
                    }
                }
            }
        } else {
            glyph
        }
    }
}

#Preview("Rail bell") {
    HStack(spacing: 16) {
        VStack(spacing: 6) {
            RailBell(TaskforceBell(rings: true, selected: false, count: 2), expanded: true) {}
            RailBell(TaskforceBell(rings: false, selected: true, count: 0), expanded: true) {}
        }
        .padding(6)
        .background(RailCapsuleBackground())
    }
    .padding(24)
    .background(TFColor.bgCanvas)
}
