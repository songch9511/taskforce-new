import SwiftUI
import TaskforceKit

extension ActivityRing.Kind {
    /// 세션의 링 → 링 부품의 종류 (Kit은 그리지 않는다)
    public init(_ ring: AgentSessionRing) {
        switch ring {
        case .needsYou: self = .needsYou
        case .unreachable: self = .unreachable
        case .stopping: self = .stopping
        case .running: self = .running
        case .done: self = .done
        case .waiting: self = .waiting
        case .idle: self = .idle
        }
    }
}

/// Activity ring (0.2.0 디자인 시스템 Atoms): 일 하나가 지금 무엇을 하는지. 검은 레일(bezel) 위에서만 쓴다.
/// 업무 상태(`TaskStatusMark`: To Do · In Progress · Done)가 아니다. 뜻은 색이 아니라 움직임과 모양이 전한다.
/// - running: `status/activity` 호가 돈다 (1.1초에 한 바퀴). 에이전트가 일하는 중
/// - stopping: Stop new steps를 요청했고 아직 확인 전. 회색 호가 느리게 돈다 (2.4초). 아직 일하고 있을 수 있다
/// - unreachable: Mac 연결이 끊겨 진행을 모른다. 회색 반 링이 멈춰 있다. 사람을 기다리는 `waiting`과 섞지 않는다
/// - needsYou: 닫힌 링 (2.5 선). 그 세션의 에이전트가 당신의 답을 기다린다. 점을 넣지 않는다 (In Progress ◉와 겹친다)
///   옛 모양(`classic`)은 형광펜 노랑, 캡슐 레일 모양(`capsule`, OA U3)은 `needs-you` 주황이고 원반이 없다 (DS "Rings never fill")
/// - waiting: 회색 점선 링. 사람 · 서비스의 답을 기다린다
/// - done: 흰 링 + 체크, 3초 동안 (캡슐 레일 모양은 `done` 초록 링 + 초록 체크)
/// - idle: 멈춘 링 (아무것도 돌지 않고 기다리지 않는다). 레일에는 오르지 않는다 (이슈 상세의 Sessions 목록이 말한다)
/// 움직임 줄이기: running은 반 링, stopping은 3/4 링으로 멈춰 서로 구분된다.
/// **ground**: `bezel`(기본, 검은 레일 · 14/18pt)과 `light`(패널 위 · 12/18pt, 선은 2pt 고정). 빛 위에서는 트랙 `border/default`, running 호 `status/activity`,
/// needs-you는 `marker` 원반 + `text/primary` 2pt 링, done은 `text/primary` 링(체크 없음), idle은 `status/step-inactive`, waiting · unreachable · stopping의 호는 `text/secondary`
/// (캡슐 모양에서는 needs-you · done이 각자의 색 링 하나뿐이다: 원반도 잉크 링도 없다)
/// **look**(OA U3-14): `classic`(기본)은 지금 모양이다 — Release 레일이 이것을 쓴다. `capsule`은 새 캡슐 레일의 모양과 움직임이다
public struct ActivityRing: View {
    public enum Kind: String, CaseIterable, Sendable {
        case running, stopping, unreachable, needsYou, waiting, done, idle

        /// VoiceOver 이름 (레일 항목은 "제목 · 상태 · 활동"으로 감싼다)
        public var accessibilityLabel: String {
            switch self {
            case .running: "Running"
            case .stopping: "Stop requested"
            case .unreachable: "Connection lost"
            case .needsYou: "Needs your answer"
            case .waiting: "Waiting"
            case .done: "Done just now"
            case .idle: "Idle"
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
        /// 숨은 레일 노치 14pt (빛 위 12pt)
        case small
        /// 펼친 레일 18pt
        case medium

        func points(on ground: Ground) -> CGFloat {
            switch (self, ground) {
            case (.small, .bezel): 14
            case (.small, .light): 12
            case (.medium, _): 18
            }
        }
    }

    public enum Ground: Sendable {
        /// 검은 레일 (기본)
        case bezel
        /// 패널 (빛 위)
        case light
    }

    /// 링의 모양 (OA U3-14). 기본은 지금 모양이다
    public enum Look: Sendable, Hashable {
        case classic
        case capsule
    }

    let kind: Kind
    let size: Size
    let ground: Ground
    let look: Look
    /// 시스템 설정 대신 쓸 움직임 줄이기 값 (nil이면 시스템 설정). `accessibilityReduceMotion` 환경값은 덮어쓸 수 없어서
    /// 레일 모델 · 디자인 비교 스냅샷이 같은 값을 넘긴다
    let reduceMotionOverride: Bool?
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    private var reduceMotion: Bool { reduceMotionOverride ?? systemReduceMotion }

    public init(_ kind: Kind, size: Size = .small, ground: Ground = .bezel, reduceMotion: Bool? = nil, look: Look = .classic) {
        self.kind = kind
        self.size = size
        self.ground = ground
        self.look = look
        reduceMotionOverride = reduceMotion
    }

    private var points: CGFloat { size.points(on: ground) }
    /// 디자인 시스템은 16 단위 viewBox에 반지름 6.5 · 선 2로 그린다. 빛 위에서는 선이 어느 크기에서나 2pt다
    private var unit: CGFloat { points / 16 }
    private var inset: CGFloat { ground == .light ? 1 : 1.5 * unit }
    private var line: CGFloat { ground == .light ? 2 : 2 * unit }

    public var body: some View {
        Group {
            if look == .capsule, kind == .needsYou {
                // 도착 bounce 뒤 2.4초마다 숨쉬고 echo 링이 퍼진다 (움직임 줄이기: 불투명도만)
                NeedsYouAnimation(reduceMotion: reduceMotion, bell: false) { frame in
                    ZStack {
                        ZStack {
                            track
                        }
                        .scaleEffect(frame.scale)
                        .opacity(frame.opacity)
                        if frame.echoOpacity > 0 {
                            Circle()
                                .strokeBorder(TFColor.needsYou, lineWidth: 1.5)
                                .frame(width: (points - 2 * inset) * frame.echoScale, height: (points - 2 * inset) * frame.echoScale)
                                .opacity(frame.echoOpacity)
                        }
                    }
                    .frame(width: points, height: points)
                }
            } else {
                ZStack {
                    track
                    arc
                    if kind == .done, ground == .bezel { check }
                }
            }
        }
        .frame(width: points, height: points)
        .accessibilityElement()
        .accessibilityLabel(kind.accessibilityLabel)
    }

    @ViewBuilder private var track: some View {
        let ring = Circle().inset(by: inset)
        if ground == .light {
            lightTrack(ring)
        } else {
            bezelTrack(ring)
        }
    }

    /// 빛 위: 트랙은 `border/default`, needs-you는 원반, done · idle은 한 색 링
    @ViewBuilder private func lightTrack(_ ring: Circle.InsetShape) -> some View {
        switch kind {
        case .needsYou:
            if look == .capsule {
                ring.stroke(TFColor.needsYou, lineWidth: line)
            } else {
                ring.fill(TFColor.fillMarker)
                ring.stroke(TFColor.textPrimary, lineWidth: line)
            }
        case .done:
            ring.stroke(look == .capsule ? TFColor.done : TFColor.textPrimary, lineWidth: line)
        case .idle:
            ring.stroke(TFColor.statusStepInactive, lineWidth: line)
        case .waiting:
            let circumference = 2 * Double.pi * (points / 2 - inset)
            ring.stroke(TFColor.textSecondary, style: StrokeStyle(lineWidth: line, lineCap: .round, dash: [circumference * 0.02, circumference * 0.064]))
        default:
            ring.stroke(TFColor.borderDefault, lineWidth: line)
        }
    }

    @ViewBuilder private func bezelTrack(_ ring: Circle.InsetShape) -> some View {
        switch kind {
        case .needsYou:
            ring.stroke(look == .capsule ? TFColor.needsYou : TFColor.fillMarker, lineWidth: 2.5 * unit)
        case .done:
            ring.stroke(look == .capsule ? TFColor.done : TFColor.bezelInk, lineWidth: line)
        case .waiting:
            let circumference = 2 * Double.pi * 6.5 * unit
            ring.stroke(TFColor.bezelInkSecondary, style: StrokeStyle(lineWidth: line, lineCap: .round, dash: [circumference * 0.02, circumference * 0.064]))
        case .idle:
            ring.stroke(TFColor.bezelInkSecondary, lineWidth: line)
        default:
            ring.stroke(TFColor.bezelTrack, lineWidth: line)
        }
    }

    @ViewBuilder private var arc: some View {
        if let length = kind.arcLength(reduceMotion: reduceMotion) {
            let color = kind == .running ? TFColor.statusActivity : (ground == .light ? TFColor.textSecondary : TFColor.bezelInkSecondary)
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
        .stroke(look == .capsule ? TFColor.done : TFColor.bezelInk, style: StrokeStyle(lineWidth: 1.75 * unit, lineCap: .round, lineJoin: .round))
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
