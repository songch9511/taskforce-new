#if os(macOS)
import SwiftUI
import TaskforceKit
import TaskforceUI

/// 에이전트 질문 카드를 두 화면(Assistant 창 · 세션 패널)에 같은 모양으로 올리는 자리 (OA D4b-m-1, D4bm-04 · 26): 프롬프트 박스(또는 Composer) 바로 위, 확인 카드(`ConfirmCard`)와 같은 자리다.
/// 상태는 모두 `AgentQuestionStore`에 있다 — 한 화면에서 고르면 다른 화면도 같은 접힌 줄이 되고 요청은 하나다. 이 뷰는 읽어 그리고, 누른 것을 저장소에 넘길 뿐이다.
/// 그 세션의 마지막 task가 `awaiting_answer`이고 `pending_question`이 읽혔을 때만 보인다 (Review에는 없다)
struct EdgeQuestionCardHost: View {
    let questions: AgentQuestionStore
    let chat: ChatStore
    let sessionID: UUID
    let conversationID: UUID?
    /// 카드가 이 높이를 넘으면 카드 안에서 스크롤한다 (그 면 높이의 60%, D4bm-17)
    let maxHeight: CGFloat

    /// 질문 곁에서 대기열에 든 글 수: 늘면 포커스가 카드로 간다 (D4bm-31)
    private var queued: Int {
        conversationID.map { AgentQuestionRules.queuedBehindQuestion(chat.turns(for: $0)) } ?? 0
    }

    /// 접힌 줄을 치워도 되는가: 서버가 같은 질문의 사건 줄을 이 대화에 썼다 (D4bm-25)
    private func isRecorded(_ entry: AgentQuestionStore.Entry) -> Bool {
        guard let conversationID else { return false }
        return questions.isRecorded(entry, eventKeys: chat.eventKeys(in: conversationID))
    }

    static func status(_ phase: AgentQuestionStore.Phase) -> QuestionCard.Status {
        switch phase {
        case .open: .open
        case .holding: .holding
        case .sending, .sent: .sent
        }
    }

    var body: some View {
        Group {
            if let entry = questions.entry(session: sessionID), !isRecorded(entry) {
                QuestionCard(
                    card: entry.card, status: Self.status(entry.phase), summary: entry.summary, failure: entry.failure, checked: entry.checked, otherOpen: entry.otherOpen,
                    initialText: entry.otherText, remoteRow: AgentQuestionNewCopy.active.remoteRow(macName: entry.card.macName),
                    focusRequest: questions.focusRequest(session: sessionID), maxHeight: maxHeight, actions: actions
                )
                // 질문 · 단계가 바뀌면 새 카드다 (쓰던 칸이 다음 질문으로 넘어가지 않게)
                .id("\(entry.key.requestID)#\(entry.step)")
                .transition(.opacity)
            }
        }
        .onChange(of: queued) { _, count in questions.noteQueued(count: count, session: sessionID) }
        .accessibilityElement(children: .contain)
    }

    private var actions: QuestionCardActions {
        QuestionCardActions(
            onChoose: { questions.choose(row: $0, session: sessionID) },
            onToggle: { questions.toggle(row: $0, session: sessionID) },
            onSendChecked: { questions.sendChecked(session: sessionID) },
            onSubmitText: { questions.submitText($0, session: sessionID) },
            onSubmitSecret: { questions.submitSecret($0, session: sessionID) },
            onCloseOther: { questions.closeOther(session: sessionID) },
            onUndo: { questions.undo(session: sessionID) },
            onFocusChange: { questions.setCardFocus($0, session: sessionID) }
        )
    }
}
#endif
