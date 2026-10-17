import SwiftUI

/// 캡슐 레일의 치수 (OA U3 5.1, DS `tokens.json` `rail-*` · `.tf-capsule` · `.tf-rest-bar`). 그리기와 포인터 판정이 같은 값을 쓴다
public enum RailCapsuleMetrics {
    /// 캡슐 폭 (`rail-width`)
    public static let width: CGFloat = 44
    /// 캡슐 사이 · 화면 끝에서의 간격 (`rail-inset`)
    public static let inset: CGFloat = 6
    /// 칸 (`rail-item`, 원)
    public static let item: CGFloat = 32
    /// 칸 사이
    public static let gap: CGFloat = 2
    /// 캡슐 위아래 안쪽
    public static let padding: CGFloat = 6
    /// 모서리 반지름 = 폭의 절반
    public static var radius: CGFloat { width / 2 }
    /// 접힘: 열 전체가 오른쪽 가운데를 기준으로 .72배
    public static let compactScale: CGFloat = 0.72
    /// 쉼 막대 (8 × 48, 반지름 4)
    public static let restBarWidth: CGFloat = 8
    public static let restBarHeight: CGFloat = 48
    public static let restBarRadius: CGFloat = 4
    /// 링: 14pt를 1.286배 = 18
    public static let ringScale: CGFloat = 18.0 / 14.0
    /// 그림자 `0 1px 3px rgba(0,0,0,.28)` + `0 0 0 .5px rgba(255,255,255,.08)`
    public static let shadowOpacity: Double = 0.28
    public static let shadowRadius: CGFloat = 1.5
    public static let shadowOffset: CGFloat = 1
    public static let edgeLineWidth: CGFloat = 0.5
    public static let edgeLineOpacity: Double = 0.08
    /// 그림자가 창 밖으로 잘리지 않게 창이 캡슐 둘레에 더 두는 여유
    public static let shadowRoom: CGFloat = 4
}

/// 검은 캡슐 하나의 바탕: 늘 `bezel` 검정(두 모드 같다) + 부드러운 그림자로 어느 배경 화면에서도 보인다
public struct RailCapsuleBackground: View {
    let radius: CGFloat

    public init(radius: CGFloat = RailCapsuleMetrics.radius) {
        self.radius = radius
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        shape
            .fill(TFColor.bezelBase)
            .overlay(shape.strokeBorder(Color.white.opacity(RailCapsuleMetrics.edgeLineOpacity), lineWidth: RailCapsuleMetrics.edgeLineWidth))
            .shadow(color: .black.opacity(RailCapsuleMetrics.shadowOpacity), radius: RailCapsuleMetrics.shadowRadius, y: RailCapsuleMetrics.shadowOffset)
    }
}

/// Needs-you가 부르는 움직임을 시간으로 돌려 `NeedsYouMotion.Frame`을 내놓는다. 이 뷰가 화면에 들어온 때가 "도착"이다
/// (상태가 바뀌면 이 뷰가 사라지므로 움직임은 그 순간 멈춘다). 디자인 비교 스냅샷은 `RailMotionSnapshot.frozen`으로 쉬는 프레임(크기 1)에서 찍는다
struct NeedsYouAnimation<Content: View>: View {
    let reduceMotion: Bool
    let bell: Bool
    @ViewBuilder let content: (NeedsYouMotion.Frame) -> Content
    @State private var arrived = Date()

    var body: some View {
        if RailMotionSnapshot.isFrozen {
            content(.rest)
        } else {
            TimelineView(.animation) { context in
                content(NeedsYouMotion.frame(elapsed: context.date.timeIntervalSince(arrived), reduceMotion: reduceMotion, bell: bell))
            }
        }
    }
}

/// 디자인 비교 스냅샷만: 움직임을 쉬는 프레임에 세운다 (Release에는 이 값이 없다 — 늘 움직인다)
public enum RailMotionSnapshot {
    #if DEBUG
    nonisolated(unsafe) public static var frozen = false
    #endif

    static var isFrozen: Bool {
        #if DEBUG
        frozen
        #else
        false
        #endif
    }
}
