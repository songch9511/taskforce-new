#if os(macOS)
import SwiftUI
import TaskforceKit
import TaskforceUI

/// Taskforce 대화의 머리 (OA U3, 디자인 TaskforcePage): 제목은 늘 "Taskforce"다. 요청이 둘 이상이면 steps — 지금 요청의 위치 (6pt 점, 24pt 누름, ← →).
/// 점은 제목이 잘리지 않는 만큼(380 폭에서 10)까지 그리고, 넘으면 지금 요청이 가운데 오게 창을 민다. 항목 제목은 본문 첫 줄로 늘 보인다.
/// 점은 render 때의 id 목록을 들고 있다: 누른 점은 목록이 그사이 바뀌었어도 그 점이 가리키던 요청으로 간다. 닫기 버튼은 없다
struct TaskforcePanelHeader: View {
    let shell: EdgeShellModel

    var body: some View {
        let queue = shell.taskforceQueue
        let ids = queue.ids
        let current = shell.taskforceShownID.flatMap { queue.index(of: $0) }
        PanelHeader(
            title: TaskforceCopy.title,
            steps: current.map { PanelHeader.Steps(count: queue.count, current: $0, style: .request) },
            onStep: { index in
                guard ids.indices.contains(index) else { return }
                shell.showTaskforceRequest(ids[index])
            }
        )
    }
}

/// Taskforce 대화의 본문: 요청 카드 하나(한 번에 하나, 말풍선 없는 전폭 메시지) + 끝에 복귀 요약 메시지(변화만).
/// 요청이 없으면 "No decisions waiting" + Next 한 줄 (Now가 비면 Projects 버튼). 읽는 중 · 오프라인 · 읽기 실패는 지금 S4 화면 그대로다 (새 문구 없음).
/// 이 화면을 여는 것 · 읽는 것 · 단계를 옮기는 것은 어떤 답도 아니다. 답은 사용자가 고른 것(클릭 · 1/2 키)만 보낸다
struct TaskforcePanelBody: View {
    let shell: EdgeShellModel
    let desk: ReviewDesk
    @Environment(\.openURL) private var openURL

    private var store: TaskforceRequestStore? { shell.taskforceStore }

    var body: some View {
        VStack(alignment: .leading, spacing: TFSpace.md) {
            switch shell.taskforceScreen {
            case .blank:
                // 읽는 중: 아무 주장도 하지 않는다
                Color.clear.frame(height: 0)
            case .offline:
                PanelEmptyState(.offline) { tryAgain(.md) }
            case .failed:
                PanelEmptyState(.couldNotLoad) { tryAgain(.md) }
            case .incomplete(let problem):
                problemNotice(problem)
                goneNotice
                summary
            case .empty(let problem):
                if let problem { problemNotice(problem) }
                goneNotice
                emptyConversation
                summary
            case .request(let problem):
                if let problem { problemNotice(problem) }
                goneNotice
                if let request = shell.shownTaskforceRequest {
                    Message(isUser: false) { card(request) }
                }
                summary
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    // MARK: 요청 카드

    @ViewBuilder
    private func card(_ request: TaskforceRequest) -> some View {
        switch request.kind {
        case .confirm:
            if let action = shell.shownReview { confirmCard(action) }
        case .resultReady:
            if let session = request.result?.sessionID.flatMap({ shell.issues?.sessions.item(id: $0) }) {
                TaskforceResultCard(session: session, onOpen: { shell.openTaskforceSession(session.id) })
                    .id(request.id)
            }
        case .pathConflict:
            conflictCard(request)
        }
    }

    /// confirm: 지금 DecisionBlock 그대로 — 메타는 확인된 프로젝트 이름만(없으면 줄이 없다), 사실 줄은 항목 제목 · 기한, 번호 글은 없다(키는 그대로 답한다).
    /// 답은 v1 경로(곧바로 보냄)이고 누른 답은 render 때의 id에만 간다
    private func confirmCard(_ action: ActionSummary) -> some View {
        let id = action.id
        let presentation = shell.reviewPresentation
        let canAnswer = shell.taskforceScreen.canAnswer
        let sending = desk.sending[id]
        let memberships = shell.contexts?.index.memberships(of: id) ?? .unknown
        let today = DueDateFormat.today()
        var facts: [DecisionBlock<ReviewSourceView>.Fact] = [.init(action.title, .subject)]
        if let due = ReviewCopy.due(action, today: today) {
            facts.append(.init(due, DueText.isUrgent(due: action.dueDate, reasons: [], today: today) ? .urgent : .value))
        }
        let answers = ReviewAnswer.allCases.map { answer in
            DecisionBlock<ReviewSourceView>.Answer(
                index: answer.key, label: answer.label,
                phase: sending == answer ? .sending : (sending != nil || !canAnswer ? .locked : .ready)
            )
        }
        return DecisionBlock(
            meta: TaskforceCopy.confirmMeta(memberships: memberships), question: ReviewCopy.question(action), facts: facts, answers: answers,
            note: desk.notice.flatMap { $0.id == id ? $0.text : nil }, quietKeys: true,
            onAnswer: { key in
                guard let answer = ReviewAnswer(key: key) else { return }
                shell.answer(answer, for: id)
            }
        ) {
            ReviewSourceView(
                source: desk.source(for: id), open: { openURL($0) },
                retry: { Task { await desk.retrySource(for: action, presentation: presentation) } }
            )
        }
        // 이 항목의 근거를 확인한다 (읽기일 뿐 해결이 아니다). 항목이 달라지거나 이 대화에 다시 들어오면 다시
        .task(id: SourceKey(id: id, activity: action.lastActivityAt, presentation: presentation)) {
            await desk.loadSource(for: action, presentation: presentation)
        }
        .id("confirm:\(id)")
    }

    private struct SourceKey: Hashable {
        let id: UUID
        let activity: Date
        let presentation: Int
    }

    /// 경로 충돌: 질문 · 메타 · 두 세션 · 답 둘. 고르면 2초 보류(Answer sent + Undo) 뒤 해소를 보낸다
    @ViewBuilder
    private func conflictCard(_ request: TaskforceRequest) -> some View {
        if let sides = shell.taskforceConflictSides(request), let version = request.conflict?.conflictVersion {
            // 카드가 그려질 때의 version · 두 세션: 선택이 도착하기 전에 충돌이 바뀌었으면 저장소가 거절한다 (옛 카드의 선택이 새 충돌에 적용되지 않는다)
            let rendered = TaskforceRenderedConflict(conflictVersion: version, holderSessionID: sides.first.id, laterSessionID: sides.second.id)
            TaskforceConflictCard(
                path: sides.path, first: .first(sides.first), second: TaskforceConflictSide(session: sides.second, line: sides.second.line),
                chosen: store?.answers[request.id], canAnswer: shell.taskforceScreen.canAnswer, note: store?.notice(for: request.id),
                onAnswer: { keep in shell.answerConflict(keep, for: request.id, rendered: rendered) },
                onUndo: { shell.undoConflict(request.id) },
                onOpenSession: { shell.openTaskforceSession($0) }
            )
            .id(request.id)
        }
    }

    // MARK: 빈 상태 · 요약 · 안내

    /// 마지막 답 뒤: "No decisions waiting" + Next 한 줄 (Now의 첫 항목), Now가 비면 Projects 버튼
    @ViewBuilder
    private var emptyConversation: some View {
        PanelEmptyState(.noDecisions)
        if let next = shell.taskforceNext {
            VStack(alignment: .leading, spacing: 0) {
                GroupLabel(TaskforceCopy.next)
                IssueRow(next, onOpen: { shell.open(itemID: next.id) })
            }
        } else {
            HStack {
                Spacer(minLength: 0)
                Button(TaskforceCopy.projects) { shell.openAllWork() }.buttonStyle(TFButtonStyle(.secondary, size: .md))
                Spacer(minLength: 0)
            }
        }
    }

    /// 끝 메시지: 변화만 보이는 복귀 요약. Clear는 읽음 처리일 뿐이고 요청을 해결하지 않는다
    @ViewBuilder
    private var summary: some View {
        if let content = shell.taskforceSummaryContent {
            Message(isUser: false) {
                ReturnSummary(
                    content: content, onOpen: { shell.openSummaryRow($0) }, onClear: { shell.clearSummary() }, onRetry: { shell.retrySummary() }
                )
            }
        }
    }

    /// 결과를 확인하지 못했거나 거절된 해소의 안내가 그 요청이 목록에서 사라진 뒤에도 남는다: 사라졌다는 사실이 성공 증거가 아니다
    @ViewBuilder
    private var goneNotice: some View {
        let queue = shell.taskforceQueue
        if let store, let notice = store.notice, !queue.contains(notice.id) {
            Notice(icon: .paused, title: notice.text)
        } else if let notice = desk.notice, queue.request(forAction: notice.id) == nil {
            Notice(icon: .paused, title: notice.text)
        }
    }

    private func problemNotice(_ problem: WorkLoad.Problem) -> some View {
        Notice(title: problem == .offline ? PanelEmptyKind.offline.title : PanelEmptyKind.couldNotLoad.title) {
            tryAgain(.sm)
        }
    }

    private func tryAgain(_ size: TFButtonStyle.Size) -> some View {
        Button(TaskforceCopy.tryAgain) { shell.taskforceTryAgain() }.buttonStyle(TFButtonStyle(.secondary, size: size))
    }
}

extension TaskforceRequestQueue {
    /// 이 업무(v1 확인 요청의 id)를 말하는 확인 요청
    func request(forAction action: UUID) -> TaskforceRequest? {
        requests.first { $0.kind == .confirm && $0.actionID == action }
    }
}
#endif
