import CoreGraphics
import Foundation

/// Assistant 창의 자리 · 높이 (OA U1, DS "Assistant window" Geometry · Placement). 좌표는 화면 좌표(아래가 0)이고,
/// 창의 위치는 **왼쪽 위**(top-left)로 다룬다: 높이가 변해도 위 가장자리가 움직이지 않는다.
public enum AssistantWindowGeometry {
    /// `panel-width`와 같다
    public static let width: CGFloat = 380
    /// 내용에 맞추다 이 높이에서 본문이 스크롤한다
    public static let maxHeight: CGFloat = 560
    /// 빈 대화(칩 + 프롬프트뿐)의 바닥 높이 (OA 프레임 61:1864)
    public static let emptyHeight: CGFloat = 440
    /// 열린 패널(또는 레일)과 창 사이
    public static let gap: CGFloat = 12
    public static let cascadeStep: CGFloat = 24
    /// 핸들에 포커스를 두고 화살표 키
    public static let keyboardStep: CGFloat = 8

    public enum Direction: Sendable {
        case left, right, up, down
    }

    /// 첫 창의 왼쪽 위: 열린 패널의 바깥 가장자리에서 왼쪽으로 12pt, 위는 패널과 같다. 패널이 없으면 레일 왼쪽 12pt, 위는 레일과 같다.
    /// panelOuterInset: 패널 바깥 가장자리에 붙는 것(세션 탭)의 폭 — U2가 채운다 (지금은 0)
    public static func firstTopLeft(panelFrame: CGRect?, railFrame: CGRect, panelOuterInset: CGFloat = 0) -> CGPoint {
        if let panelFrame {
            return CGPoint(x: panelFrame.minX - panelOuterInset - gap - width, y: panelFrame.maxY)
        }
        return CGPoint(x: railFrame.minX - gap - width, y: railFrame.maxY)
    }

    /// 새 창은 앞 창에서 24pt 아래 · 왼쪽으로 겹쳐 연다
    public static func cascaded(from topLeft: CGPoint) -> CGPoint {
        CGPoint(x: topLeft.x - cascadeStep, y: topLeft.y - cascadeStep)
    }

    /// 보이는 영역 안으로 넣는다. 레일(펼친 폭 `railWidth`)은 덮지 않는다: 오른쪽 가장자리는 보이는 영역의 오른쪽 − 레일 폭 안쪽이다.
    /// 높이가 보이는 영역보다 크면 위를 맞춘다 (머리가 늘 보인다)
    public static func clamped(topLeft: CGPoint, height: CGFloat, visible: CGRect, railWidth: CGFloat) -> CGPoint {
        let rightLimit = visible.maxX - railWidth - width
        let x = max(visible.minX, min(topLeft.x, rightLimit))
        let y: CGFloat
        if height >= visible.height {
            y = visible.maxY
        } else {
            y = max(visible.minY + height, min(topLeft.y, visible.maxY))
        }
        return CGPoint(x: x, y: y)
    }

    /// 창의 높이: 내용(머리 + 본문 + 입력 영역)에 맞추고 560에서 멈춘다. 빈 대화는 440 아래로 줄지 않는다
    public static func height(content: CGFloat, isEmpty: Bool) -> CGFloat {
        let floor = isEmpty ? emptyHeight : 0
        return min(maxHeight, max(content, floor))
    }

    public static func moved(_ topLeft: CGPoint, by direction: Direction) -> CGPoint {
        switch direction {
        case .left: CGPoint(x: topLeft.x - keyboardStep, y: topLeft.y)
        case .right: CGPoint(x: topLeft.x + keyboardStep, y: topLeft.y)
        case .up: CGPoint(x: topLeft.x, y: topLeft.y + keyboardStep)
        case .down: CGPoint(x: topLeft.x, y: topLeft.y - keyboardStep)
        }
    }
}
