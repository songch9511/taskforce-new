import Foundation

// OA D4b-m-1 (D4bm-30 · 32 · 33, DS QuestionCard "Keys"): 질문 카드의 키 규칙. 화면 없는 순수 함수다 — 카드(SwiftUI)는 눌린 키와 포커스를 이 함수에 묻고 답대로 저장소를 부른다.
// - 1–4는 **카드(또는 그 줄)에 포커스가 있을 때만** 답한다. 입력 칸(Other · 비밀값)에 포커스가 있으면 숫자는 글자다. composer에 쓰는 글은 카드에 답하지 않는다.
// - 번호가 안 보여도(줄이 넷이 아니어도) 키는 동작한다. 앞 넷 줄에만 닿는다.
// - Return = 포커스된 줄 고르기(단일 · 승인) / 다중은 체크한 것 보내기 / 입력 칸은 보내기. Space = 다중의 체크 켜고 끄기. ↑↓ = 줄 사이.
// - ⌘ · ⌃ · ⌥가 눌리면 카드의 일이 아니다 (단축키를 가로채지 않는다).

public enum AgentQuestionKeyboard {
    public enum Key: Equatable, Sendable {
        case digit(Int)
        case `return`
        case space
        case escape
        case up
        case down
    }

    /// 포커스가 어디 있나
    public enum Focus: Equatable, Sendable {
        /// 카드 자체
        case card
        /// 줄 하나 (선택지 · 체크 상자 · Other 줄)
        case row(Int)
        /// 입력 칸 (Other 입력 · 글만 · 비밀값)
        case field
    }

    public enum Action: Equatable, Sendable {
        case choose(Int)
        case toggle(Int)
        case sendChecked
        case submitField
        case moveFocus(Int)
        case cancelOther
        case undo
        case none
    }

    public struct Context: Sendable {
        public var card: AgentQuestionCard
        public var phase: AgentQuestionStore.Phase
        public var focus: Focus
        public var checkedCount: Int
        public var otherOpen: Bool
        /// 입력 칸에 글이 있다 (비어 있으면 Return이 보내지 않는다)
        public var fieldHasText: Bool

        public init(card: AgentQuestionCard, phase: AgentQuestionStore.Phase, focus: Focus, checkedCount: Int = 0, otherOpen: Bool = false, fieldHasText: Bool = false) {
            self.card = card
            self.phase = phase
            self.focus = focus
            self.checkedCount = checkedCount
            self.otherOpen = otherOpen
            self.fieldHasText = fieldHasText
        }
    }

    /// 누른 키 → 할 일. `modified`는 ⌘ · ⌃ · ⌥가 함께 눌렸다
    public static func resolve(_ key: Key, modified: Bool = false, _ context: Context) -> Action {
        guard !modified, context.card.kind != .secretRemote else { return .none }
        // 접힌 줄: Esc만 (Undo). 보내는 중 · 보낸 뒤에는 Undo도 없다
        guard context.phase == .open else {
            return key == .escape && context.phase == .holding ? .undo : .none
        }
        if context.focus == .field { return resolveInField(key, context) }
        switch key {
        case .digit(let number):
            guard (1...4).contains(number), context.card.keyedRows.contains(number - 1) else { return .none }
            return .choose(number - 1)
        case .up: return hasRows(context) ? .moveFocus(-1) : .none
        case .down: return hasRows(context) ? .moveFocus(1) : .none
        case .return:
            switch context.card.kind {
            case .single, .other, .approval:
                if case .row(let index) = context.focus { return .choose(index) }
                return .none
            case .multi:
                return context.checkedCount > 0 ? .sendChecked : .none
            case .text, .secret, .secretRemote:
                return .none
            }
        case .space:
            guard case .row(let index) = context.focus else { return .none }
            switch context.card.kind {
            case .multi: return .toggle(index)
            case .single, .other, .approval: return .choose(index)
            case .text, .secret, .secretRemote: return .none
            }
        case .escape:
            return context.otherOpen ? .cancelOther : .none
        }
    }

    private static func hasRows(_ context: Context) -> Bool {
        switch context.card.kind {
        case .single, .other, .approval, .multi: !context.card.rows.isEmpty
        case .text, .secret, .secretRemote: false
        }
    }

    /// 입력 칸에 포커스가 있다: 숫자 · Space는 글자다. Return은 보내기, Esc는 Other 칸을 줄로 되돌린다
    private static func resolveInField(_ key: Key, _ context: Context) -> Action {
        switch key {
        case .return: return context.fieldHasText ? .submitField : .none
        case .escape: return context.otherOpen ? .cancelOther : .none
        case .digit, .space, .up, .down: return .none
        }
    }
}
