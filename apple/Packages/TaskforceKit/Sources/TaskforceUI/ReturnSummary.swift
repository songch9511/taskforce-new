import SwiftUI
import TaskforceKit

/// ReturnSummary (0.2.0 디자인 시스템 Organisms, 결정 D-12): 떠나 있던 동안 바뀐 것 — 결과 · 결정 · 다음 행동. 채팅을 다시 읽지 않아도 된다.
/// `WorkList`의 `summary` 자리(검색칸 위)에 놓는다. `Card` 제목은 `Since <since>`, 끝에 글자 버튼 `Clear`.
/// - 줄 하나 = 작업 하나: StatusMark · 제목 · 변화. `Needs your answer`는 형광펜(Highlight)이고 ` · 변화`가 이어진다. 다음 행동은 "Next: …".
/// - 줄을 누르면 그 작업으로 간다. 열 곳이 없는 줄(목록에 없는 작업)은 누를 수 없다 (› 없음).
/// - **숫자가 없다.** Clear는 읽음 처리일 뿐이다 (해결 · 승인 · 완료 · 거절이 아니다): 결정 줄은 Clear 뒤에도 남는다. 답할 결정이 있으면 ⌥ Space는 여전히 Review를 먼저 연다.
/// - 비어 있다는 문구가 없다. 읽지 못했거나 일부만 보일 때(`notes`)는 줄 밑에서 그렇게 말한다 — 비어 있는 것이 아니라 모르는 것이다.
/// 값과 동작만 받는다: 무엇을 보일지는 `ReturnSummaryContent`(Kit)가 정한다.
public struct ReturnSummary: View {
    let content: ReturnSummaryContent
    let onOpen: (UUID) -> Void
    let onClear: () -> Void
    let onRetry: () -> Void

    public init(content: ReturnSummaryContent, onOpen: @escaping (UUID) -> Void = { _ in }, onClear: @escaping () -> Void = {}, onRetry: @escaping () -> Void = {}) {
        self.content = content
        self.onOpen = onOpen
        self.onClear = onClear
        self.onRetry = onRetry
    }

    /// 줄의 접근성 이름: "In Progress, 제목, Needs your answer · 변화" (앞 마크 · 제목 · 보조 글을 한 번에)
    nonisolated public static func accessibilityLabel(_ row: ReturnSummaryRow) -> String {
        ([row.progress.flatMap(Self.stateName), row.title, row.detail] as [String?]).compactMap { $0 }.joined(separator: ", ")
    }

    nonisolated static func stateName(_ progress: ReturnSummaryProgress) -> String? {
        switch progress {
        case .toDo: TaskStatusMark.State.toDo.label
        case .inProgress: TaskStatusMark.State.inProgress.label
        case .done: TaskStatusMark.State.done.label
        case .unknown: nil
        }
    }

    nonisolated static func mark(_ progress: ReturnSummaryProgress?) -> TaskStatusMark.State? {
        switch progress {
        case .toDo?: .toDo
        case .inProgress?: .inProgress
        case .done?: .done
        case .unknown?, nil: nil
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: TFSpace.sm) {
            if content.showsCard { card }
            ForEach(Array(content.notes.enumerated()), id: \.offset) { _, note in
                Notice(title: note.text) {
                    if note.offersRetry {
                        Button(ReturnSummaryCopy.tryAgain, action: onRetry).buttonStyle(TFButtonStyle(.secondary, size: .sm))
                    }
                }
            }
            if let message = content.message {
                Text(message)
                    .font(TFFont.meta)
                    .foregroundStyle(TFColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, SettingsTray.separatorInset)
            }
        }
        // 디자인 `.tf-return { margin: 0 0 12px }`
        .padding(.bottom, TFSpace.md)
        .accessibilityElement(children: .contain)
    }

    private var card: some View {
        Card(title: content.title, action: {
            if content.canClear {
                Button(ReturnSummaryCopy.clear, action: onClear)
                    .buttonStyle(TFButtonStyle(.text, size: .sm))
                    .disabled(content.isClearing)
                    // 디자인 `.tf-card-title > .tf-btn { margin: -6px -4px -4px 0 }`: 버튼이 캡션 줄을 키우지 않는다
                    .padding(.trailing, -4)
                    .padding(.vertical, -4)
            }
        }, content: {
            CardRows(hasLead: true) {
                ForEach(content.rows) { row in
                    CardRow(
                        title: row.title, detail: row.detail.map { MarkerText.attributed($0, highlighting: row.highlight) },
                        onOpen: row.canOpen ? { onOpen(row.id) } : nil,
                        lead: {
                            if let state = Self.mark(row.progress) {
                                TaskStatusMark(state)
                            } else {
                                // 표시가 없는 줄(취소된 작업)도 글자 자리를 맞춘다
                                Color.clear.frame(width: 16, height: 16).accessibilityHidden(true)
                            }
                        },
                        control: { EmptyView() }
                    )
                    .accessibilityLabel(Self.accessibilityLabel(row))
                }
            }
        })
    }
}

#Preview("ReturnSummary") {
    // 디자인 SSOT의 견본 줄 (제목 · 상태 · 변화)
    let rows = [
        ReturnSummaryRow(id: UUID(), title: "Pricing page", progress: .inProgress, needsAnswer: true, detail: "Needs your answer · Review failed"),
        ReturnSummaryRow(id: UUID(), title: "Launch design", progress: .inProgress, needsAnswer: false, detail: "Draft ready · Next: review the result"),
        ReturnSummaryRow(id: UUID(), title: "Partner schedule", progress: .inProgress, needsAnswer: false, detail: "Due date changed"),
        ReturnSummaryRow(id: UUID(), title: "Launch direction", progress: .done, needsAnswer: false, detail: "Completed"),
        ReturnSummaryRow(id: UUID(), title: "Old site banner", progress: nil, needsAnswer: false, detail: "Canceled", canOpen: false),
    ]
    VStack(alignment: .leading, spacing: 0) {
        ReturnSummary(content: ReturnSummaryContent(title: "Since yesterday 18:40", rows: rows, canClear: true))
        ReturnSummary(content: ReturnSummaryContent(
            title: "Changes", rows: Array(rows.prefix(2)), notes: [.someNotShown, .couldNotLoadDecisions], canClear: true, message: "This changed somewhere else. It's been refreshed."
        ))
        ReturnSummary(content: ReturnSummaryContent(title: "Changes", rows: [], notes: [.couldNotLoad]))
    }
    .padding(16)
    .frame(width: 380)
    .background(TFColor.bgPanel)
}
