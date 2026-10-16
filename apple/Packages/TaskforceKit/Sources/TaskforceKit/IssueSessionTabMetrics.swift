import CoreGraphics
import Foundation

/// 세션 패널의 자리 (OA U2-06, U3-45): 세션 패널은 이슈 패널 본체의 왼쪽 40에 놓인다 (지금 보이는 간격 그대로, U2-06 "≥ 40").
/// DS SessionPage 미리보기는 46이다 — `.tf-screen > .tf-panel`의 6을 빼먹은 값으로 보여 따르지 않는다 (U3 DZ 8)
public enum SessionPanelMetrics {
    public static let panelGap: CGFloat = 40
}

extension AssistantWindowGeometry {
    /// 열린 패널 창들(이슈 패널 + 그 왼쪽 세션 패널)의 합. 하나도 없으면 nil. 첫 Assistant 창은 이 바깥 가장자리에서 왼쪽 12다
    public static func panelsFrame(_ frames: [CGRect]) -> CGRect? {
        guard let first = frames.first else { return nil }
        return frames.dropFirst().reduce(first) { $0.union($1) }
    }
}
