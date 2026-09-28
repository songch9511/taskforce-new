import SwiftUI
import TaskforceKit

/// Task status (Figma "Task status": To Do · In Progress · Done · Review): 할 일 행 왼쪽의 상태 표시. iPhone Task row · Mac Launcher row 공용.
/// 모두 잉크(fill/inverse)와 border/control로만 그린다 (accent는 선택된 런처 행에만 쓴다).
/// - To Do: border/control 테두리 원
/// - In Progress: 잉크 테두리 + 왼쪽 반 채움
/// - Done: 잉크로 채운 원 + 흰 체크
/// - Review: border/control 점선 원 (누를 수 없음)
///
/// `action`을 주면 누를 수 있다: To Do · In Progress는 완료, Done은 다시 열기. Review는 `action`이 있어도 누를 수 없다.
/// `tapInsets`: 표시 둘레의 여백. 누르는 영역에 들어간다 (iPhone Task row는 제목 첫 줄에 맞춘 위 여백까지 누를 수 있다).
public struct TaskStatusMark: View {
    public enum State: String, CaseIterable, Sendable, Hashable {
        case toDo, inProgress, done, review

        public init(_ group: TaskGroup) {
            switch group {
            case .review: self = .review
            case .inProgress: self = .inProgress
            case .toDo: self = .toDo
            case .doneToday: self = .done
            }
        }

        var label: String {
            switch self {
            case .toDo: "To Do"
            case .inProgress: "In Progress"
            case .done: "Done"
            case .review: "Review"
            }
        }
    }

    let state: State
    let size: CGFloat
    let tapInsets: EdgeInsets
    let action: (() -> Void)?

    public init(_ state: State, size: CGFloat = 16, tapInsets: EdgeInsets = EdgeInsets(), action: (() -> Void)? = nil) {
        self.state = state
        self.size = size
        self.tapInsets = tapInsets
        self.action = action
    }

    public var body: some View {
        if let action, state != .review {
            Button(action: action) {
                mark
                    .padding(tapInsets)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(state == .done ? "Reopen" : "Complete")
            .accessibilityValue(state.label)
            .accessibilityAddTraits(state == .done ? .isSelected : [])
        } else {
            mark
                .padding(tapInsets)
                .accessibilityLabel(state.label)
        }
    }

    private var lineWidth: CGFloat { 1.5 }

    private var mark: some View {
        ZStack {
            switch state {
            case .toDo:
                Circle().strokeBorder(TFColor.borderControl, lineWidth: lineWidth)
            case .inProgress:
                Circle().strokeBorder(TFColor.fillInverse, lineWidth: lineWidth)
                Circle()
                    .fill(TFColor.fillInverse)
                    .padding(max(3, size * 0.18))
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: size / 2)
                    }
            case .done:
                Circle().fill(TFColor.fillInverse)
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(TFColor.textInverse)
            case .review:
                let dash = size * Double.pi / 12
                Circle().strokeBorder(TFColor.borderControl, style: StrokeStyle(lineWidth: lineWidth, dash: [dash * 0.6, dash * 0.4]))
            }
        }
        .frame(width: size, height: size)
    }
}

#Preview("Task status") {
    VStack(alignment: .leading, spacing: 16) {
        ForEach([CGFloat(16), 22], id: \.self) { size in
            HStack(spacing: 16) {
                ForEach(TaskStatusMark.State.allCases, id: \.self) { state in
                    VStack(spacing: 6) {
                        TaskStatusMark(state, size: size) {}
                        Text(state.label).font(TFFont.footnote).foregroundStyle(TFColor.textSecondary)
                    }
                }
            }
        }
    }
    .padding()
}
