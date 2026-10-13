import SwiftUI
import TaskforceKit

/// WorkRow (0.2.0 디자인 시스템 Molecules): 목록의 일 한 줄. 상태 표시(○ ◉ ✓) · 제목(고정이면 핀) · 활동 · 수행자 · 기한.
/// - 둘째 줄은 활동이 먼저, 그다음 수행자 ("Running · You"): 잘려도 중요한 것이 남는다
/// - 기한이 지났거나 오늘이면(`urgent`, 앱 표시 규칙 `DueText.isUrgent`) 기한 글자를 `status/overdue` 600으로. 지났으면 접근성 이름에 "overdue"
/// - 끝낸 일은 조용하게(제목 secondary), 취소선 없음. 호버 · 지금 행은 `bg/selected`이고 보조 글자는 `text/secondary-selected`로 대비를 지킨다
/// - 접근성 이름 "Title — State · Activity, due Day". 고정은 값("Pinned")으로 따로 읽는다
public struct WorkRow: View {
    let title: String
    let state: TaskStatusMark.State
    let performer: String?
    let activity: String?
    let due: String?
    let urgent: Bool
    let overdue: Bool
    let pinned: Bool
    let current: Bool
    let highlighted: Bool

    /// - current: 레일에서 연 일 (고른 행) · highlighted: 호버 또는 패널이 열린 채 레일에서 그 일을 가리킴 (표시만)
    public init(
        title: String, state: TaskStatusMark.State, performer: String? = nil, activity: String? = nil, due: String? = nil,
        urgent: Bool = false, overdue: Bool = false, pinned: Bool = false, current: Bool = false, highlighted: Bool = false
    ) {
        self.title = title
        self.state = state
        self.performer = performer
        self.activity = activity
        self.due = due
        self.urgent = urgent
        self.overdue = overdue
        self.pinned = pinned
        self.current = current
        self.highlighted = highlighted
    }

    /// "Title — State · Activity, due Day" (기한이 지났으면 ", overdue, due Day")
    nonisolated public static func accessibilityLabel(title: String, state: TaskStatusMark.State, activity: String?, due: String?, overdue: Bool) -> String {
        var label = "\(title) — \(state.label)"
        if let activity { label += " · \(activity)" }
        if let due { label += overdue ? ", overdue, due \(due)" : ", due \(due)" }
        return label
    }

    /// 둘째 줄: 활동 · 수행자 (둘 다 없으면 nil)
    nonisolated public static func meta(activity: String?, performer: String?) -> String? {
        let parts = [activity, performer].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    public var body: some View {
        let selected = current || highlighted
        let secondary = selected ? TFColor.textSecondarySelected : TFColor.textSecondary
        HStack(alignment: .top, spacing: TFSpace.md) {
            TaskStatusMark(state)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(TFFont.callout)
                        .tracking(-0.24)
                        .foregroundStyle(state == .done ? secondary : TFColor.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if pinned {
                        TFIcon.pin.image(size: 14)
                            .foregroundStyle(secondary)
                    }
                }
                if let meta = Self.meta(activity: activity, performer: performer) {
                    Text(meta)
                        .font(TFFont.footnote)
                        .foregroundStyle(secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let due {
                Text(due)
                    .font(urgent ? TFFont.footnoteEmphasis : TFFont.footnote)
                    .monospacedDigit()
                    .foregroundStyle(urgent ? (selected ? TFColor.statusOverdueSelected : TFColor.statusOverdue) : secondary)
                    .padding(.top, 1)
            }
        }
        .padding(EdgeInsets(top: 10, leading: TFSpace.sm, bottom: 10, trailing: TFSpace.sm))
        .background {
            RoundedRectangle(cornerRadius: TFRadius.md, style: .continuous).fill(selected ? TFColor.bgSelected : .clear)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel(title: title, state: state, activity: activity, due: due, overdue: overdue))
        .accessibilityValue(pinned ? "Pinned" : "")
        .accessibilityAddTraits(current ? .isSelected : [])
    }
}

extension TaskStatusMark.State {
    /// 세 상태 (디자인 StatusMark): To Do ○ · In Progress ◉ · Done ✓
    public init(_ state: WorkState) {
        switch state {
        case .toDo: self = .toDo
        case .inProgress: self = .inProgress
        case .done: self = .done
        }
    }
}

#Preview("Work row") {
    VStack(spacing: 0) {
        WorkRow(title: "Launch design", state: .inProgress, performer: "You", activity: "Running", due: "Fri", pinned: true)
        WorkRow(title: "Pricing page", state: .inProgress, performer: "You", activity: "Needs your answer", due: "Fri", current: true)
        WorkRow(title: "Partner schedule", state: .toDo, performer: "You", due: "Yesterday", urgent: true, overdue: true)
        WorkRow(title: "Launch direction", state: .done, performer: "You", due: "Today")
    }
    .padding(8)
    .frame(width: 380)
    .background(TFColor.bgPanel)
}
