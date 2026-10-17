import Foundation
import Testing
@testable import TaskforceKit

/// 질문 카드의 키 규칙 (OA D4b-m-1, D4bm-30 · 32 · 33): 1–4는 카드(또는 줄)에 포커스가 있을 때만, 입력 칸에서는 글자, 번호가 안 보여도 키는 동작, Return · Space · ↑↓ · Esc
struct AgentQuestionKeyboardTests {
    typealias F = AgentQuestionFixtures
    typealias K = AgentQuestionKeyboard

    private func card(_ json: String, mac: Bool = true) throws -> AgentQuestionCard {
        let q = try #require(AgentPendingQuestion(json: Data(json.utf8), taskID: F.taskID))
        return try #require(AgentQuestionRules.cards(for: q, context: AgentQuestionContext(agentName: "Claude Code", isThisMac: mac)).first)
    }

    private func resolve(_ key: K.Key, _ card: AgentQuestionCard, focus: K.Focus = .card, phase: AgentQuestionStore.Phase = .open, checked: Int = 0, otherOpen: Bool = false, text: Bool = false, modified: Bool = false) -> K.Action {
        K.resolve(key, modified: modified, K.Context(card: card, phase: phase, focus: focus, checkedCount: checked, otherOpen: otherOpen, fieldHasText: text))
    }

    @Test func digitsOneToFourAnswerWhileTheCardOrARowHasFocus() throws {
        let four = try card(F.single)
        for number in 1...4 {
            #expect(resolve(.digit(number), four, focus: .card) == .choose(number - 1))
            #expect(resolve(.digit(number), four, focus: .row(0)) == .choose(number - 1), "줄에 포커스가 있어도")
        }
        #expect(resolve(.digit(5), four) == .none && resolve(.digit(0), four) == .none)
    }

    @Test func keysWorkEvenWhenTheNumbersAreNotDrawn() throws {
        let three = try card(F.singleThree)
        #expect(!three.showsKeycaps)
        #expect(resolve(.digit(1), three) == .choose(0) && resolve(.digit(3), three) == .choose(2))
        #expect(resolve(.digit(4), three) == .none, "없는 줄")
        let approval = try card(F.approvalEdit)
        #expect(resolve(.digit(1), approval) == .choose(0) && resolve(.digit(2), approval) == .choose(1) && resolve(.digit(3), approval) == .none)
    }

    @Test func moreThanFourRowsOnlyTheFirstFourAreKeyed() throws {
        let ten = try card(F.pending(prompts: [F.prompt(options: (1...10).map { ("Option \($0)", "") })]))
        #expect(resolve(.digit(4), ten) == .choose(3) && resolve(.digit(5), ten) == .none)
    }

    @Test func theFourthKeyIsTheOtherRowWhenThereAreThreeOptions() throws {
        let other = try card(F.otherThree)
        #expect(resolve(.digit(4), other) == .choose(3), "Other 줄을 고르면 저장소가 입력 칸을 연다")
    }

    @Test func digitsAreTextWhileAnInputFieldHasFocus() throws {
        let other = try card(F.otherThree)
        let secret = try card(F.secret)
        let text = try card(F.textOnly)
        for (c, open) in [(other, true), (secret, false), (text, false)] {
            for number in 1...4 { #expect(resolve(.digit(number), c, focus: .field, otherOpen: open, text: true) == .none, "\(c.kind)") }
            #expect(resolve(.space, c, focus: .field, otherOpen: open, text: true) == .none)
        }
    }

    @Test func returnSendsAFieldOnlyWhenItHasText() throws {
        let secret = try card(F.secret)
        #expect(resolve(.return, secret, focus: .field, text: true) == .submitField)
        #expect(resolve(.return, secret, focus: .field, text: false) == .none)
        let other = try card(F.otherThree)
        #expect(resolve(.return, other, focus: .field, otherOpen: true, text: true) == .submitField)
    }

    @Test func returnChoosesTheFocusedRowAndOtherwiseDoesNothingOnPickCards() throws {
        let single = try card(F.single)
        #expect(resolve(.return, single, focus: .row(2)) == .choose(2))
        #expect(resolve(.return, single, focus: .card) == .none, "고른 줄이 없으면 Return은 답이 아니다")
        let approval = try card(F.approvalEdit)
        #expect(resolve(.return, approval, focus: .row(1)) == .choose(1))
    }

    @Test func multiSelectUsesSpaceToToggleAndReturnToSendOnlyWithAChecked() throws {
        let multi = try card(F.multi)
        #expect(resolve(.space, multi, focus: .row(1)) == .toggle(1))
        #expect(resolve(.space, multi, focus: .card) == .none)
        #expect(resolve(.return, multi, focus: .row(0), checked: 0) == .none, "하나라도 체크되기 전까지 꺼져 있다")
        #expect(resolve(.return, multi, focus: .row(0), checked: 2) == .sendChecked)
        #expect(resolve(.digit(1), multi) == .none, "다중은 체크 상자: 번호 키가 없다")
    }

    @Test func spaceOnAPickRowChoosesItLikeAButton() throws {
        let single = try card(F.single)
        #expect(resolve(.space, single, focus: .row(3)) == .choose(3))
    }

    @Test func arrowsMoveBetweenRowsOnlyWhereThereAreRows() throws {
        let single = try card(F.single)
        let multi = try card(F.multi)
        let secret = try card(F.secret)
        let text = try card(F.textOnly)
        #expect(resolve(.down, single) == .moveFocus(1) && resolve(.up, single) == .moveFocus(-1))
        #expect(resolve(.down, multi) == .moveFocus(1))
        #expect(resolve(.down, secret) == .none && resolve(.up, text) == .none)
    }

    @Test func escapeClosesTheOtherFieldFromTheFieldOrFromARow() throws {
        let other = try card(F.otherThree)
        #expect(resolve(.escape, other, focus: .field, otherOpen: true, text: true) == .cancelOther)
        #expect(resolve(.escape, other, focus: .row(0), otherOpen: true) == .cancelOther)
        #expect(resolve(.escape, other, focus: .row(0), otherOpen: false) == .none, "열린 것이 없으면 Esc는 지나간다")
        #expect(resolve(.escape, try card(F.secret), focus: .field) == .none)
    }

    @Test func aFoldedCardOnlyAnswersEscapeAndOnlyWhileHeld() throws {
        let single = try card(F.single)
        #expect(resolve(.escape, single, phase: .holding) == .undo)
        for phase in [AgentQuestionStore.Phase.sending, .sent] {
            #expect(resolve(.escape, single, phase: phase) == .none, "보내기 시작부터는 Undo가 없다")
        }
        for phase in [AgentQuestionStore.Phase.holding, .sending, .sent] {
            #expect(resolve(.digit(1), single, phase: phase) == .none && resolve(.return, single, focus: .row(0), phase: phase) == .none, "접힌 뒤에는 답할 수 없다")
        }
    }

    @Test func commandControlOrOptionKeepsTheKeyForTheShortcut() throws {
        let single = try card(F.single)
        #expect(resolve(.digit(1), single, modified: true) == .none, "⌘1은 카드의 일이 아니다")
        #expect(resolve(.return, single, focus: .row(0), modified: true) == .none)
    }

    @Test func aRemoteSecretCardAnswersNothing() throws {
        let remote = try card(F.secret, mac: false)
        #expect(remote.kind == .secretRemote)
        for key in [K.Key.digit(1), .return, .space, .escape, .up, .down] { #expect(resolve(key, remote) == .none) }
    }
}
