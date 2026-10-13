import SwiftUI

/// 움직임 (0.2.0 디자인 시스템 README › Motion). 이징은 하나: `--tf-ease` = cubic-bezier(.22, 1, .36, 1) (지수 감속).
/// transform · opacity · 배경색 · 그림자 · 행 펼침만 움직이고, 너비 · 높이 · 여백은 움직이지 않는다.
/// 움직임 줄이기: 투명도만 바뀐다 (패널은 밀려 들어오지 않고, 레일은 미끄러지지 않는다). 링은 `ActivityRing`이 멈춘 모양으로 그린다.
public enum TFMotion {
    /// cubic-bezier(.22, 1, .36, 1)의 제어점
    public static let easeControlPoints: (x1: Double, y1: Double, x2: Double, y2: Double) = (0.22, 1, 0.36, 1)

    /// 패널: 투명도 180ms, 이동 · 크기 260ms (`translateX(16px) scale(.975)`에서, 기준점은 레일 쪽 위 모서리)
    public static let panelFade: Double = 0.18
    public static let panelMove: Double = 0.26
    public static let panelHiddenOffset: CGFloat = 16
    public static let panelHiddenScale: CGFloat = 0.975

    /// 레일: 노치에 120ms 머물면 펼치고, 220ms 동안 미끄러져 나오며, 떠나고 400ms 뒤 숨는다 (패널이 열려 있으면 숨지 않는다)
    public static let railHoverDelay: Double = 0.12
    public static let railSlide: Double = 0.22
    public static let railLeaveDelay: Double = 0.4
    /// 링이 나타나고 사라지는 시간 · Done이 머무는 시간
    public static let ringFade: Double = 0.16
    public static let doneHold: Double = 3
    /// 링 한 바퀴: Running 1.1초 · Stop requested 2.4초 (`ActivityRing.Kind.period`와 같다)
    public static let runningTurn: Double = 1.1
    public static let stoppingTurn: Double = 2.4

    /// Disclosure 꺾쇠 200ms, 누름 .98, 호버 120ms
    public static let disclosureFlip: Double = 0.2
    public static let pressScale: CGFloat = 0.98
    public static let hoverFade: Double = 0.12

    /// 디자인 이징으로 `duration`초
    public static func ease(_ duration: Double) -> Animation {
        .timingCurve(easeControlPoints.x1, easeControlPoints.y1, easeControlPoints.x2, easeControlPoints.y2, duration: duration)
    }

    /// 패널이 숨은 자리의 이동 · 크기. 움직임 줄이기면 제자리에서 투명도만 바뀐다
    public static func panelTransform(shown: Bool, reduceMotion: Bool) -> (offset: CGFloat, scale: CGFloat) {
        guard !shown, !reduceMotion else { return (0, 1) }
        return (panelHiddenOffset, panelHiddenScale)
    }

    /// 레일 미끄러짐 · 패널 이동 애니메이션. 움직임 줄이기면 없음(바로 바뀐다)
    public static func move(_ duration: Double, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : ease(duration)
    }
}
