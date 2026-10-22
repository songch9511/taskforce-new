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
    /// 링이 나타나고 사라지는 시간
    public static let ringFade: Double = 0.16
    /// Done이 머무는 시간: 끝남을 시간으로 내리는 옛 모드(노치 레일 · Assistant 창의 좁은 저장소)만 쓴다.
    /// 캡슐 레일(새 Issues 화면)의 끝난 링은 이 시간과 상관없이 사용자가 열어 볼 때까지 남는다 (OA PR-D2, 계약 23장)
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

    // MARK: Needs you가 부르는 움직임 (DS README › Motion "Needs you looks at you", OA U3 5.3)

    /// 도착: 스프링 한 번 (scale .6 → 1.18 → .96 → 1, 520ms). SwiftUI `.spring(response: 0.35, dampingFraction: 0.55)`
    public static let needsYouArrive: Double = 0.52
    /// 그 뒤 숨쉬기 주기: 1 → 1.12 → 1을 2.4초마다 (ease-in-out)
    public static let needsYouBreath: Double = 2.4
}

/// Needs-you 링과 Taskforce bell의 움직임을 한 곳에서 계산한다 (DS bundle.css `tf-needs-arrive` · `tf-needs-breathe` · `tf-needs-echo` · `tf-bell-ring` · `tf-needs-fade`).
/// 시각 `elapsed`(도착한 뒤 지난 초)에서 한 장면을 낸다. 다른 것은 부르려고 움직이지 않는다.
/// 움직임 줄이기: 크기 · 각도 · echo가 없고 불투명도만 1 → .45 → 1을 2.4초마다 숨쉰다.
public enum NeedsYouMotion {
    public struct Frame: Equatable, Sendable {
        public var scale: Double = 1
        public var opacity: Double = 1
        /// echo 링의 크기와 불투명도 (숨마다 하나가 1.75배로 퍼지며 사라진다)
        public var echoScale: Double = 1
        public var echoOpacity: Double = 0
        /// bell만: 위쪽(12%)을 기준으로 흔들리는 각도(도)
        public var rotation: Double = 0

        /// 가만히 있는 프레임 (움직임을 끈 스냅샷 · 시작 전)
        public static let rest = Frame()
    }

    /// ease-in-out (cubic-bezier(.42, 0, .58, 1)의 가까운 근사: smoothstep)
    static func smooth(_ x: Double) -> Double {
        let t = min(max(x, 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// 키프레임 사이를 smoothstep으로 잇는다
    static func keyframes(_ points: [(at: Double, value: Double)], at x: Double) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        if x <= first.at { return first.value }
        if x >= last.at { return last.value }
        for index in 1..<points.count where x <= points[index].at {
            let a = points[index - 1], b = points[index]
            return a.value + (b.value - a.value) * smooth((x - a.at) / (b.at - a.at))
        }
        return last.value
    }

    /// 도착 (0 … 0.52초): scale .6 → 1.18 (45%) → .96 (72%) → 1, 불투명도 0 → 1
    static func arrival(_ x: Double) -> (scale: Double, opacity: Double) {
        let u = x / TFMotion.needsYouArrive
        return (
            keyframes([(0, 0.6), (0.45, 1.18), (0.72, 0.96), (1, 1)], at: u),
            min(max(u / 0.45, 0), 1)
        )
    }

    /// bell 흔들림 (숨 시작에서 주기의 30% 안): 0 → -14 → 12 → -8 → 5 → -2 → 0도
    static func swing(_ u: Double) -> Double {
        keyframes([(0, 0), (0.05, -14), (0.10, 12), (0.15, -8), (0.20, 5), (0.25, -2), (0.30, 0), (1, 0)], at: u)
    }

    public static func frame(elapsed: Double, reduceMotion: Bool, bell: Bool) -> Frame {
        guard elapsed >= 0 else { return .rest }
        let period = TFMotion.needsYouBreath
        if reduceMotion {
            // 불투명도만: 1 → .45 → 1 (2.4초, 도착 바운스 없음)
            let u = elapsed.truncatingRemainder(dividingBy: period) / period
            let half = u <= 0.5 ? u / 0.5 : (1 - u) / 0.5
            return Frame(opacity: 1 - 0.55 * smooth(half))
        }
        if elapsed < TFMotion.needsYouArrive {
            let arrived = arrival(elapsed)
            return Frame(scale: arrived.scale, opacity: arrived.opacity)
        }
        let u = (elapsed - TFMotion.needsYouArrive).truncatingRemainder(dividingBy: period) / period
        let half = u <= 0.5 ? u / 0.5 : (1 - u) / 0.5
        var frame = Frame(scale: 1 + 0.12 * smooth(half))
        if u < 0.7 {
            let p = u / 0.7
            frame.echoScale = 1 + 0.75 * (1 - (1 - p) * (1 - p))
            frame.echoOpacity = 0.6 * (1 - p)
        } else {
            frame.echoScale = 1.75
            frame.echoOpacity = 0
        }
        if bell { frame.rotation = swing(u) }
        return frame
    }
}
