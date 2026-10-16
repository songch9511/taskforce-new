import CoreGraphics
import Foundation

/// SessionTab의 바깥 치수 (OA U2-06 · 44, DS SessionTab README): 접힘 폭 24, 펼침 폭 36. 펼친 탭은 아무것도 덮지 않으니 두 번째 패널은 40 이상 떨어뜨린다
public enum SessionTabMetrics {
    public static let collapsedWidth: CGFloat = 24
    public static let expandedWidth: CGFloat = 36
    /// 탭 패널의 평평한 왼쪽 가장자리 위에서 탭 시작까지 (DS `top` 기본값)
    public static let top: CGFloat = 40
    /// 세션 패널은 탭이 붙은 패널의 왼쪽 40 (DS "≥ 40")
    public static let panelGap: CGFloat = 40
    /// 한 번에 보이는 세션
    public static let limit = AgentSessionRules.tabLimit
}

extension AssistantWindowGeometry {
    /// 열린 패널 창들(이슈 패널 + 그 왼쪽 탭 + 세션 패널)의 합. 하나도 없으면 nil. 첫 Assistant 창은 이 바깥 가장자리에서 왼쪽 12다
    public static func panelsFrame(_ frames: [CGRect]) -> CGRect? {
        guard let first = frames.first else { return nil }
        return frames.dropFirst().reduce(first) { $0.union($1) }
    }
}
