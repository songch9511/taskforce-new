import SwiftUI

/// Activity ring (0.2.0 디자인 시스템 Atoms): 일 하나가 지금 무엇을 하는지. 검은 레일(bezel) 위에서만 쓴다.
/// 업무 상태(`TaskStatusMark`: To Do · In Progress · Done)가 아니다. 뜻은 색이 아니라 움직임과 모양이 전한다.
/// - running: `status/activity` 호가 돈다 (1.1초에 한 바퀴). 에이전트가 일하는 중
/// - stopping: Stop new steps를 요청했고 아직 확인 전. 회색 호가 느리게 돈다 (2.4초). 아직 일하고 있을 수 있다
/// - unreachable: Mac 연결이 끊겨 진행을 모른다. 회색 반 링이 멈춰 있다. 사람을 기다리는 `waiting`과 섞지 않는다
/// - needsYou: 닫힌 형광펜 링 (2.5 선). 결정이 기다린다. 점을 넣지 않는다 (In Progress ◉와 겹친다)
/// - waiting: 회색 점선 링. 사람 · 서비스의 답을 기다린다
/// - done: 흰 링 + 체크, 3초 동안
/// 움직임 줄이기: running은 반 링, stopping은 3/4 링으로 멈춰 서로 구분된다.
public struct ActivityRing: View {
    public enum Kind: String, CaseIterable, Sendable {
        case running, stopping, unreachable, needsYou, waiting, done

        /// VoiceOver 이름 (레일 항목은 "제목 · 상태 · 활동"으로 감싼다)
        public var accessibilityLabel: String {
            switch self {
            case .running: "Running"
            case .stopping: "Stop requested"
            case .unreachable: "Connection lost"
            case .needsYou: "Needs your answer"
            case .waiting: "Waiting"
            case .done: "Done just now"
            }
        }

        /// 한 바퀴 시간(초). nil이면 움직이지 않는다
        public var period: Double? {
            switch self {
            case .running: 1.1
            case .stopping: 2.4
            default: nil
            }
        }

        /// 호 길이 (원 둘레 비율). nil이면 호가 없다
        public func arcLength(reduceMotion: Bool) -> Double? {
            switch self {
            case .running: reduceMotion ? 0.55 : 0.3
            case .stopping: reduceMotion ? 0.75 : 0.3
            case .unreachable: 0.5
            default: nil
            }
        }
    }

    public enum Size: Sendable {
        /// 숨은 레일 노치 14pt
        case small
        /// 펼친 레일 18pt
        case medium

        var points: CGFloat { self == .small ? 14 : 18 }
    }

    let kind: Kind
    let size: Size
    /// 시스템 설정 대신 쓸 움직임 줄이기 값 (nil이면 시스템 설정). `accessibilityReduceMotion` 환경값은 덮어쓸 수 없어서
    /// 레일 모델 · 디자인 비교 스냅샷이 같은 값을 넘긴다
    let reduceMotionOverride: Bool?
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    private var reduceMotion: Bool { reduceMotionOverride ?? systemReduceMotion }

    public init(_ kind: Kind, size: Size = .small, reduceMotion: Bool? = nil) {
        self.kind = kind
        self.size = size
        reduceMotionOverride = reduceMotion
    }

    /// 디자인 시스템은 16 단위 viewBox에 반지름 6.5 · 선 2로 그린다
    private var unit: CGFloat { size.points / 16 }
    private var inset: CGFloat { 1.5 * unit }
    private var line: CGFloat { 2 * unit }

    public var body: some View {
        ZStack {
            track
            arc
            if kind == .done { check }
        }
        .frame(width: size.points, height: size.points)
        .accessibilityElement()
        .accessibilityLabel(kind.accessibilityLabel)
    }

    @ViewBuilder private var track: some View {
        let ring = Circle().inset(by: inset)
        switch kind {
        case .needsYou:
            ring.stroke(TFColor.fillMarker, lineWidth: 2.5 * unit)
        case .done:
            ring.stroke(TFColor.bezelInk, lineWidth: line)
        case .waiting:
            let circumference = 2 * Double.pi * 6.5 * unit
            ring.stroke(TFColor.bezelInkSecondary, style: StrokeStyle(lineWidth: line, lineCap: .round, dash: [circumference * 0.02, circumference * 0.064]))
        default:
            ring.stroke(TFColor.bezelTrack, lineWidth: line)
        }
    }

    @ViewBuilder private var arc: some View {
        if let length = kind.arcLength(reduceMotion: reduceMotion) {
            let color = kind == .running ? TFColor.statusActivity : TFColor.bezelInkSecondary
            let shape = Circle()
                .inset(by: inset)
                .trim(from: 0, to: length)
                .stroke(color, style: StrokeStyle(lineWidth: line, lineCap: .round))
            if let period = kind.period, !reduceMotion {
                TimelineView(.animation) { context in
                    let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
                    shape.rotationEffect(.degrees(-90 + turn * 360))
                }
            } else {
                shape.rotationEffect(.degrees(-90))
            }
        }
    }

    /// viewBox 좌표 (5.3, 8.2) → (7.2, 10) → (10.7, 6.2)
    private var check: some View {
        Path { path in
            path.move(to: CGPoint(x: 5.3 * unit, y: 8.2 * unit))
            path.addLine(to: CGPoint(x: 7.2 * unit, y: 10 * unit))
            path.addLine(to: CGPoint(x: 10.7 * unit, y: 6.2 * unit))
        }
        .stroke(TFColor.bezelInk, style: StrokeStyle(lineWidth: 1.75 * unit, lineCap: .round, lineJoin: .round))
    }
}

#Preview("Activity ring") {
    HStack(spacing: 24) {
        ForEach(ActivityRing.Kind.allCases, id: \.self) { kind in
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    ActivityRing(kind)
                    ActivityRing(kind, size: .medium)
                }
                Text(kind.accessibilityLabel).font(TFFont.meta).foregroundStyle(TFColor.bezelInk)
            }
        }
    }
    .padding(24)
    .background(TFColor.bezelBase)
}
