import SwiftUI
import TaskforceKit

/// StatusMark (0.2.0 디자인 시스템 Atoms, OA U2): 일의 상태를 모양으로. ○ To Do · ◉ In Progress · ✓ Done. **셋뿐이다**:
/// 기다림 · 검토 중 · 연결 끊김 · 멈춤은 상태가 아니라 제목 옆 활동 글이다 (`TaskStatusMark`의 Review 점선은 이 부품에 없다).
/// 잉크뿐: To Do는 `border/control` 테두리 원, In Progress는 `text/primary` 테두리 + 안쪽 점(50%), Done은 잉크로 채운 원 + 체크. 파랑 · 초록 · 노랑 없음.
/// 크기 16(`md`) · 12(`sm`), 테두리 1.5. 끝낸 행의 제목은 `text/secondary`(취소선 없음, 쓰는 쪽 몫). 접근성 이름은 상태 이름이다.
/// **목록 · 요약 · 상태 줄에서는 In Progress에 표시가 없다** (`blankInProgress`, OA U3-46, DS 2026-10-16): 거의 모든 줄이 진행 중이라 표시가 반복될 뿐이다.
/// 빈 자리(같은 크기)가 제목 정렬을 지키고 접근성 이름은 "In Progress"를 그대로 말한다. Status 속성 · 필터는 늘 세 모양을 다 보인다
/// iPhone · 런처 · 옛 All work는 4종 `TaskStatusMark`를 그대로 쓴다 (이 부품은 새 Issues 화면에서만)
public struct StatusMark: View {
    public enum State: String, CaseIterable, Sendable, Hashable {
        case toDo, inProgress, done

        public var label: String {
            switch self {
            case .toDo: "To Do"
            case .inProgress: "In Progress"
            case .done: "Done"
            }
        }

        public init(_ state: WorkState) {
            switch state {
            case .toDo: self = .toDo
            case .inProgress: self = .inProgress
            case .done: self = .done
            }
        }
    }

    public enum Size: Sendable {
        case md, sm

        public var points: CGFloat { self == .md ? 16 : 12 }
    }

    nonisolated public static let lineWidth: CGFloat = 1.5

    let state: State
    let size: Size
    let blankInProgress: Bool

    public init(_ state: State, size: Size = .md, blankInProgress: Bool = false) {
        self.state = state
        self.size = size
        self.blankInProgress = blankInProgress
    }

    /// 이 상태가 모양을 그리나 (목록의 In Progress만 빈 자리)
    nonisolated public static func drawsMark(_ state: State, blankInProgress: Bool) -> Bool {
        !(blankInProgress && state == .inProgress)
    }

    public var body: some View {
        let side = size.points
        ZStack {
            switch state {
            case .toDo:
                Circle().strokeBorder(TFColor.borderControl, lineWidth: Self.lineWidth)
            case .inProgress:
                if Self.drawsMark(state, blankInProgress: blankInProgress) {
                    Circle().strokeBorder(TFColor.textPrimary, lineWidth: Self.lineWidth)
                    Circle().fill(TFColor.textPrimary).frame(width: side / 2, height: side / 2)
                }
            case .done:
                Circle().fill(TFColor.fillInverse)
                Check()
                    .stroke(TFColor.textInverse, style: StrokeStyle(lineWidth: side * 0.1, lineCap: .round, lineJoin: .round))
                    .frame(width: side, height: side)
            }
        }
        .frame(width: side, height: side)
        .accessibilityElement()
        .accessibilityLabel(state.label)
        .accessibilityAddTraits(.isImage)
    }

    /// 체크 (DS는 16 단위 viewBox의 선 1.6)
    private struct Check: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.width * 0.30, y: rect.height * 0.52))
            path.addLine(to: CGPoint(x: rect.width * 0.44, y: rect.height * 0.66))
            path.addLine(to: CGPoint(x: rect.width * 0.71, y: rect.height * 0.36))
            return path
        }
    }
}

#Preview("StatusMark") {
    HStack(spacing: 20) {
        ForEach(StatusMark.State.allCases, id: \.self) { state in
            VStack(spacing: 8) {
                StatusMark(state)
                StatusMark(state, size: .sm)
                Text(state.label).font(TFFont.footnote).foregroundStyle(TFColor.textSecondary)
            }
        }
    }
    .padding(24)
    .background(TFColor.bgPanel)
}
