import SwiftUI
import TaskforceKit

/// Task row의 세 상태 (Figma 4:6 Open · 4:15 Overdue · 4:24 Done)
public enum TaskRowState: Sendable {
    case open, overdue, done
}

/// Task row (Figma 4:34, iPhone): 체크 원 + 제목 + "due · counterpart".
/// 기한 지남은 기한 글자만 빨강, 완료는 검정 원 + 회색 글자(취소선 없음). 구분선은 글자 시작점부터 (List가 긋는다).
public struct TaskRow<Detail: View>: View {
    public typealias State = TaskRowState

    let title: String
    let meta: TaskMetaLine
    let state: State
    let onToggle: () -> Void
    let detail: Detail

    @ScaledMetric(relativeTo: .body) private var checkSize: CGFloat = 22
    @ScaledMetric(relativeTo: .body) private var checkTop: CGFloat = 13

    public init(title: String, meta: TaskMetaLine, state: State, onToggle: @escaping () -> Void, @ViewBuilder detail: () -> Detail) {
        self.title = title
        self.meta = meta
        self.state = state
        self.onToggle = onToggle
        self.detail = detail()
    }

    public var body: some View {
        HStack(alignment: .top, spacing: TFSpace.md) {
            Button(action: onToggle) {
                CheckCircle(done: state == .done, size: checkSize)
                    .padding(.top, checkTop)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(state == .done ? "Completed" : "Complete")
            .accessibilityAddTraits(state == .done ? .isSelected : [])

            VStack(alignment: .leading, spacing: TFSpace.xxs) {
                Text(title)
                    .font(TFFont.body)
                    .foregroundStyle(state == .done ? TFColor.textSecondary : TFColor.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                if !meta.isEmpty {
                    metaLine
                }
                // 펼친 근거 (부르는 쪽이 위 간격을 준다)
                detail
            }
            .padding(.vertical, TFSpace.md)
            #if os(iOS)
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            #endif
        }
    }

    private var metaLine: some View {
        HStack(spacing: TFSpace.xs) {
            if let due = meta.due {
                Text(due)
                    .foregroundStyle(state == .overdue ? TFColor.statusOverdue : TFColor.textSecondary)
                    .fixedSize()
            }
            if let counterpart = meta.counterpart {
                if meta.showsSeparator {
                    Text("·").fixedSize()
                }
                Text(counterpart)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .font(TFFont.footnote)
        .foregroundStyle(TFColor.textSecondary)
        .lineLimit(1)
    }
}

extension TaskRow where Detail == EmptyView {
    public init(title: String, meta: TaskMetaLine, state: State, onToggle: @escaping () -> Void) {
        self.init(title: title, meta: meta, state: state, onToggle: onToggle) { EmptyView() }
    }
}

/// 22pt 체크 원: 1.5pt border/control, 완료는 fill/inverse + 체크 (text/inverse)
struct CheckCircle: View {
    let done: Bool
    let size: CGFloat

    var body: some View {
        ZStack {
            if done {
                Circle().fill(TFColor.fillInverse)
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(TFColor.textInverse)
            } else {
                Circle().strokeBorder(TFColor.borderControl, lineWidth: 1.5)
            }
        }
        .frame(width: size, height: size)
    }
}

#Preview("Task row") {
    List {
        TaskRow(title: "제안서 보내기", meta: TaskMetaLine(due: "Mon"), state: .open) {}
        TaskRow(title: "계약서 검토 의견 전달", meta: TaskMetaLine(due: "Yesterday", counterpart: "김대표", showCounterpart: true), state: .overdue) {}
        TaskRow(title: "제안서 보내기", meta: TaskMetaLine(due: "Mon"), state: .done) {}
        TaskRow(title: "기한이 없는 할 일 제목이 아주 길어서 두 줄로 넘어가는 경우 한글 단어 단위 줄바꿈을 확인합니다", meta: TaskMetaLine(due: nil), state: .open) {}
        TaskRow(
            title: "Share feedback on the contract",
            meta: TaskMetaLine(due: "Wed", counterpart: "A very long counterpart name that must truncate", showCounterpart: true),
            state: .open
        ) {} detail: {
            EvidenceView(service: .notion, quote: "Can you share feedback by Wednesday?", when: "Sep 22", source: "Weekly sync")
        }
    }
    .listStyle(.plain)
}
