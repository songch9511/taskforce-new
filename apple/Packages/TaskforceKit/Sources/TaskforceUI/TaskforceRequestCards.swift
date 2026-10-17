import SwiftUI
import TaskforceKit

/// Taskforce 요청 카드 (OA U3, DS TaskforcePage · FileConflictPage): Taskforce 대화에 한 번에 하나 보이는 요청의 본문.
/// - **Result ready**: `Card` "Result ready" 안에 그 세션의 `SessionRow` 하나. 누르면 그 이슈 상세와 세션 패널이 열린다. "Review result" 버튼은 E1c가 카드 안에 넣는다 —
///   그 전에는 버튼 없는 카드다 (U3-26, DZ). "Later"는 없다: 요청은 처리될 때까지 남는다
/// - **File conflict**: 질문 "Which session keeps {파일}?" → 메타 "File conflict · {경로}" → `Card` 안에 세션 둘(먼저 쓴 쪽 위, 상태 앞 "Touched first") → 답 "Keep {세션}" 1 · 2.
///   고르면 답이 잠기고 고른 답에 check, 아래에 "Answer sent" + Undo 한 줄(2초 보류)이 선다. 보낸 뒤에는 Undo가 없다. 경로는 가운데를 줄이지 않고 줄을 바꾼다
/// 값과 동작만 받는다: 무엇을 보일지는 Kit(`TaskforceRequestRules`)가 정한다.

public struct TaskforceResultCard: View {
    let session: AgentSessionItem
    let onOpen: () -> Void

    public init(session: AgentSessionItem, onOpen: @escaping () -> Void) {
        self.session = session
        self.onOpen = onOpen
    }

    public var body: some View {
        Card(title: TaskforceCopy.resultReady) {
            SessionRow(session, onOpen: onOpen)
        }
        .accessibilityElement(children: .contain)
    }
}

/// 충돌 카드의 한 세션: 세션 항목과 그 줄에 쓸 상태 말
public struct TaskforceConflictSide {
    public let session: AgentSessionItem
    /// "Touched first · Running" · "Stop requested · not confirmed" 같은 상태 줄 (비면 줄이 없다)
    public let line: String

    public init(session: AgentSessionItem, line: String) {
        self.session = session
        self.line = line
    }

    /// 먼저 쓴 쪽 줄의 상태 (`Touched first · {세션 상태}`)
    public static func first(_ session: AgentSessionItem) -> TaskforceConflictSide {
        TaskforceConflictSide(session: session, line: TaskforceCopy.touchedFirst(line: session.line))
    }
}

public struct TaskforceConflictCard: View {
    let path: String
    let first: TaskforceConflictSide
    let second: TaskforceConflictSide
    /// 고른 답과 그 단계 (없으면 아직 고르지 않았다)
    let chosen: TaskforceAnswer?
    /// 오프라인이면 답을 잠근다 (나중에 보내려고 모아 두지 않는다)
    let canAnswer: Bool
    let note: String?
    let onAnswer: (TaskforceConflictKeep) -> Void
    let onUndo: () -> Void
    let onOpenSession: (UUID) -> Void

    public init(
        path: String, first: TaskforceConflictSide, second: TaskforceConflictSide, chosen: TaskforceAnswer?, canAnswer: Bool = true, note: String? = nil,
        onAnswer: @escaping (TaskforceConflictKeep) -> Void, onUndo: @escaping () -> Void, onOpenSession: @escaping (UUID) -> Void = { _ in }
    ) {
        self.path = path
        self.first = first
        self.second = second
        self.chosen = chosen
        self.canAnswer = canAnswer
        self.note = note
        self.onAnswer = onAnswer
        self.onUndo = onUndo
        self.onOpenSession = onOpenSession
    }

    /// 답 두 줄의 단계: 고르기 전에는 누를 수 있고, 고른 뒤에는 고른 답에 check, 나머지는 잠긴다
    nonisolated public static func phase(for keep: TaskforceConflictKeep, chosen: TaskforceAnswer?, canAnswer: Bool) -> AnswerOption.Phase {
        guard let chosen else { return canAnswer ? .ready : .locked }
        return chosen.keep == keep ? .chosen : .locked
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(TaskforceCopy.whichSessionKeeps(path: path))
                .font(TFFont.headline)
                .tracking(-0.374)
                .foregroundStyle(TFColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
                .padding(.bottom, 2)
                .accessibilityAddTraits(.isHeader)
            Text(TaskforceCopy.fileConflict(path: path))
                .font(TFFont.footnote)
                .foregroundStyle(TFColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, TFSpace.md)
            Card {
                VStack(spacing: 2) {
                    row(first)
                    row(second)
                }
                .padding(.vertical, 4)
            }
            VStack(spacing: DecisionBlock<EmptyView>.answerGap) {
                answer(.holder, session: first.session)
                answer(.later, session: second.session)
            }
            .padding(.top, TFSpace.md)
            if let chosen {
                sentLine(canUndo: chosen.phase == .holding)
            }
            if let note {
                Text(note)
                    .font(TFFont.footnote)
                    .foregroundStyle(TFColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, TFSpace.md)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Decision")
    }

    private func row(_ side: TaskforceConflictSide) -> some View {
        SessionRow(
            name: side.session.name, agent: side.session.agent, line: side.line,
            accessibilityName: side.line.isEmpty ? "\(side.session.name) — \(side.session.agentName)" : "\(side.session.name) — \(side.session.agentName) — \(side.line)",
            dimmed: side.session.isClosed, onOpen: { onOpenSession(side.session.id) }
        )
    }

    private func answer(_ keep: TaskforceConflictKeep, session: AgentSessionItem) -> some View {
        AnswerOption(
            index: keep.key, label: TaskforceCopy.keep(session.name), phase: Self.phase(for: keep, chosen: chosen, canAnswer: canAnswer)
        ) { onAnswer(keep) }
    }

    /// DS `.tf-outcome`: 위 1pt 구분선, 위 12 · 안쪽 위 8, check 14 + "Answer sent" + (보류 안에서만) Undo
    private func sentLine(canUndo: Bool) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(TFColor.borderDefault).frame(height: 1)
            HStack(spacing: TFSpace.sm) {
                TFIcon.check.image(size: 14).foregroundStyle(TFColor.textPrimary)
                Text(TaskforceCopy.answerSent)
                    .font(TFFont.footnote)
                    .foregroundStyle(TFColor.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if canUndo {
                    Button(TaskforceCopy.undo, action: onUndo).buttonStyle(TFButtonStyle(.text, size: .sm))
                }
            }
            .padding(.top, TFSpace.sm)
        }
        .padding(.top, TFSpace.md)
        .accessibilityElement(children: .contain)
    }
}
