#if os(macOS)
import AppKit
import Carbon.HIToolbox
import TaskforceKit
import TaskforceUI

/// 셸 컨트롤러가 질문 카드와 만나는 곳 (OA D4b-m-1): 카드가 키 표면에 보이는지, 링 · 알림으로 그 세션의 카드로 가기, Esc 순서.
/// 숫자 · Return · Space · 방향키는 카드(SwiftUI)가 포커스를 보고 직접 듣는다 (`AgentQuestionKeyboard`). Esc만 AppKit 키 모니터가 먼저 받으므로 여기서 질문을 먼저 본다
extension EdgeShellController {
    /// 질문 저장소를 셸 · 알림에 잇는다 (게이트가 꺼져 질문 저장소가 없으면 아무것도 잇지 않는다)
    func wireQuestions() {
        guard let chat, let questions = chat.questions else { return }
        shell.questions = questions
        // 카드가 지금 키 표면에 보이면 알림을 보내지 않는다 (D4bm-60): 키 창이 그 세션의 세션 패널이거나 Assistant 창이다
        chat.isQuestionVisible = { [weak self] session in self?.isQuestionVisible(session) ?? false }
        shell.onFocusQuestion = { [weak self] session in self?.focusQuestion(session) }
    }

    /// 그 세션의 카드가 지금 키 표면에 보이나: 앱이 앞에 있고, 키 창이 그 세션의 세션 패널이거나 그 세션 대화의 Assistant 창이다
    func isQuestionVisible(_ session: UUID) -> Bool {
        guard NSApp.isActive else { return false }
        if let panel = sessionPanel, panel.panel.isVisible, panel.panel.isKeyWindow, shell.sessionPanelShown, shell.openSessionItem?.id == session { return true }
        return assistant?.isShowing(session: session) ?? false
    }

    /// 사용자의 동작(링 클릭 · 알림 누름)으로 열린 세션의 창을 키 창으로 만든다: 카드가 포커스를 받고 1–4가 동작하게. 창이 스스로 키를 가져가지는 않는다
    func focusQuestion(_ session: UUID) {
        guard let sessionPanel, shell.sessionPanelShown, shell.openSessionItem?.id == session else { return }
        sessionPanel.panel.makeKey()
    }

    /// 알림을 눌렀다 · 링을 눌렀다: 그 세션의 카드로 간다. 새 Issues 화면이 켜져 있으면 세션 패널로, 아니면 그 대화의 Assistant 창으로 (D4bm-63). 게이트가 꺼졌으면 앱만 연다
    func openQuestion(sessionID: UUID) {
        guard let questions = chat?.questions else { return }
        if shell.issues != nil {
            shell.openQuestion(session: sessionID)
        } else if let assistant, let conversation = questions.entry(session: sessionID)?.conversationID {
            assistant.showQuestion(session: sessionID, conversation: conversation)
        }
    }

    /// 키 모니터의 맨 앞 (OA D4b-m-1, D4bm-33): Esc가 열린 Other 입력 칸이나 보류 중인 답(카드에 포커스)에 먼저 닿는다. 처리했으면 true.
    /// 키 모니터가 이미 이슈 패널 · 세션 패널의 키만 여기로 보낸다. 한글 · 일본어 조합 중인 Esc는 조합을 취소하는 것이라 지나간다
    func handleQuestionKey(_ event: NSEvent) -> Bool {
        guard let questions = chat?.questions, Int(event.keyCode) == kVK_Escape,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
              let sessionPanel, shell.sessionPanelShown, !shell.menuOpen, let session = shell.openSessionItem?.id else { return false }
        if (sessionPanel.panel.firstResponder as? NSTextView)?.hasMarkedText() == true { return false }
        return questions.escape(session: session)
    }
}
#endif
