import SwiftUI

/// State line (0.2.0 디자인 시스템 Molecules): 일 머리 아래 한 줄. 상태 표시(○ ◉ ✓) 다음에 지금 일어나는 일을 말로.
/// 숫자가 들어갈 자리도 말로 쓴다("Other work still running"). 개수는 접근성 이름에만.
public struct StateLine: View {
    let state: TaskStatusMark.State
    let text: String

    public init(_ state: TaskStatusMark.State, _ text: String) {
        self.state = state
        self.text = text
    }

    public var body: some View {
        HStack(spacing: 10) {
            TaskStatusMark(state)
            Text(text)
                .font(TFFont.footnote)
                .foregroundStyle(TFColor.textSecondary)
                .lineLimit(2)
        }
        .padding(.top, 2)
        .padding(.bottom, TFSpace.md)
        .accessibilityElement(children: .combine)
    }
}

#Preview("State line") {
    VStack(alignment: .leading) {
        StateLine(.inProgress, "Connection lost · progress unknown · Other work still running")
        StateLine(.done, "Passed review")
    }
    .padding()
    .frame(width: 380)
    .background(TFColor.bgPanel)
}
