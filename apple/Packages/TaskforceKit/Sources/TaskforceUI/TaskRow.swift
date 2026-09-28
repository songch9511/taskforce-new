import SwiftUI
import TaskforceKit

/// Task row의 세 상태 (Figma 4:6 Open · 4:15 Overdue · 4:24 Done)
public enum TaskRowState: Sendable {
    case open, overdue, done
}

/// Task row (Figma 4:34, iPhone): 상태 표시(`TaskStatusMark`) + 제목 + "due · counterpart".
/// 기한 지남은 기한 글자만 빨강, 완료는 검정 체크 원 + 회색 글자(취소선 없음). 착수한 할 일은 반 채운 원. 구분선은 글자 시작점부터 (List가 긋는다).
/// 상태 표시를 누르면 `onToggle` (열린 할 일은 완료, 완료는 다시 열기).
public struct TaskRow<Detail: View>: View {
    public typealias State = TaskRowState

    let title: String
    let meta: TaskMetaLine
    let state: State
    let inProgress: Bool
    let onToggle: () -> Void
    let detail: Detail

    @ScaledMetric(relativeTo: .body) private var checkSize: CGFloat = 22
    @ScaledMetric(relativeTo: .body) private var checkTop: CGFloat = 13

    /// `inProgress`: 착수한 열린 할 일 (완료면 무시)
    public init(
        title: String, meta: TaskMetaLine, state: State, inProgress: Bool = false, onToggle: @escaping () -> Void,
        @ViewBuilder detail: () -> Detail
    ) {
        self.title = title
        self.meta = meta
        self.state = state
        self.inProgress = inProgress
        self.onToggle = onToggle
        self.detail = detail()
    }

    private var mark: TaskStatusMark.State {
        state == .done ? .done : (inProgress ? .inProgress : .toDo)
    }

    public var body: some View {
        HStack(alignment: .top, spacing: TFSpace.md) {
            TaskStatusMark(mark, size: checkSize, tapInsets: EdgeInsets(top: checkTop, leading: 0, bottom: 0, trailing: 0), action: onToggle)

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
    public init(title: String, meta: TaskMetaLine, state: State, inProgress: Bool = false, onToggle: @escaping () -> Void) {
        self.init(title: title, meta: meta, state: state, inProgress: inProgress, onToggle: onToggle) { EmptyView() }
    }
}

#Preview("Task row") {
    List {
        TaskRow(title: "제안서 보내기", meta: TaskMetaLine(due: "Mon"), state: .open) {}
        TaskRow(title: "투자사 IR 자료 업데이트", meta: TaskMetaLine(due: "Thu"), state: .open, inProgress: true) {}
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
