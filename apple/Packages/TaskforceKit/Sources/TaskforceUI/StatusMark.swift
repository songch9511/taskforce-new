import SwiftUI
import TaskforceKit

/// StatusMark (0.2.0 디자인 시스템 Atoms, OA U2): 일의 상태를 모양으로. ○ To Do · ◉ In Progress · ✓ Done. **셋뿐이다**:
/// 기다림 · 검토 중 · 연결 끊김 · 멈춤은 상태가 아니라 제목 옆 활동 글이다 (`TaskStatusMark`의 Review 점선은 이 부품에 없다).
/// 잉크뿐: To Do는 `border/control` 테두리 원, In Progress는 `text/primary` 테두리 + 안쪽 점(50%), Done은 잉크로 채운 원 + 체크. 파랑 · 초록 · 노랑 없음.
/// 크기 16(`md`) · 12(`sm`), 테두리 1.5. 끝낸 행의 제목은 `text/secondary`(취소선 없음, 쓰는 쪽 몫). 접근성 이름은 상태 이름이다.
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

    public init(_ state: State, size: Size = .md) {
        self.state = state
        self.size = size
    }

    public var body: some View {
        let side = size.points
        ZStack {
            switch state {
            case .toDo:
                Circle().strokeBorder(TFColor.borderControl, lineWidth: Self.lineWidth)
            case .inProgress:
                Circle().strokeBorder(TFColor.textPrimary, lineWidth: Self.lineWidth)
                Circle().fill(TFColor.textPrimary).frame(width: side / 2, height: side / 2)
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
