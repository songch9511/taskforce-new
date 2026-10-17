#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import Testing
import TaskforceKit
@testable import TaskforceUI

/// QuestionCard (OA D4b-m-1, DS Molecules): 일곱 종류 · 세 상태의 접근성 이름 · Keycap 규칙 · 값을 다시 보이지 않는 비밀값 · 빨강이 아닌 실패 줄 · 키 풀이
struct QuestionCardTests {
    private func card(_ kind: AgentQuestionCard.Kind, rows: [String] = [], meta: String? = nil, hint: String? = nil, preview: String? = nil, title: String = "Which price should lead the yearly card?") -> AgentQuestionCard {
        AgentQuestionCard(
            promptID: "q1", kind: kind, title: title, meta: meta,
            rows: rows.enumerated().map { .init(label: $0.element, hint: $0.offset == 0 ? hint : nil, isOther: kind == .other && $0.offset == rows.count - 1) }, preview: preview
        )
    }

    private var four: AgentQuestionCard { card(.single, rows: ["First-month price", "Monthly price", "Yearly total", "Price per month"]) }
    private var three: AgentQuestionCard { card(.single, rows: ["Pro monthly", "Pro yearly", "Lifetime"]) }

    // MARK: 이름 · 번호

    @Test func everyKindHasTheQuestionAsItsAccessibleName() {
        for kind in [AgentQuestionCard.Kind.single, .multi, .other, .text, .approval, .secret, .secretRemote] {
            #expect(QuestionCard.accessibilityName(card(kind, title: "A question")) == "A question", "\(kind)")
        }
    }

    @Test func numbersShowOnlyWhenThereAreFourRowsAndNeverElseAndTheHintSaysThePressKey() {
        #expect((0..<4).map { QuestionCard.keycap(card: four, index: $0) } == ["1", "2", "3", "4"])
        #expect((0..<3).allSatisfy { QuestionCard.keycap(card: three, index: $0) == nil }, "번호가 안 보여도 키는 동작한다")
        #expect(QuestionCard.rowHint(card: four, index: 1) == "Press 2")
        #expect(QuestionCard.rowHint(card: three, index: 1) == nil)
        let withHint = card(.single, rows: ["Trim the scope", "Keep the scope"], hint: "Drop the Lifetime section for Thursday")
        #expect(QuestionCard.rowHint(card: withHint, index: 0) == "Drop the Lifetime section for Thursday", "설명은 도움말 · 접근성 힌트로만 (화면에 그리지 않는다)")
    }

    @Test func multiHasNoNumbersAndItsSendIsOffUntilOneIsChecked() {
        let multi = card(.multi, rows: ["A", "B", "C", "D"])
        #expect(QuestionCard.keycap(card: multi, index: 0) == nil)
        #expect(!QuestionCard.sendEnabled(kind: .multi, checkedCount: 0, hasText: false))
        #expect(QuestionCard.sendEnabled(kind: .multi, checkedCount: 1, hasText: false))
        #expect(!QuestionCard.sendEnabled(kind: .other, checkedCount: 0, hasText: false) && QuestionCard.sendEnabled(kind: .other, checkedCount: 0, hasText: true))
        #expect(!QuestionCard.sendEnabled(kind: .secret, checkedCount: 0, hasText: false) && QuestionCard.sendEnabled(kind: .secret, checkedCount: 0, hasText: true))
        #expect(!QuestionCard.sendEnabled(kind: .secretRemote, checkedCount: 3, hasText: true) && !QuestionCard.sendEnabled(kind: .single, checkedCount: 3, hasText: true))
    }

    // MARK: 접힌 줄 · 실패 줄

    @Test func theFoldedRowSaysAnswerSentThenTheChosenAnswerAndNeverASecret() {
        #expect(QuestionCard.foldedName(summary: "Yearly total") == "Answer sent. Yearly total")
        #expect(QuestionCard.foldedName(summary: nil) == "Answer sent", "비밀값이면 값이 없다")
        #expect(QuestionCard.phase(.open) == .open && QuestionCard.phase(.holding) == .holding && QuestionCard.phase(.sent) == .sent)
    }

    @Test func theFailureLineIsBoldCouldntSendThenTheReasonAndIsNotRed() {
        let offline = QuestionCard.failureLine(.offline)
        #expect(offline.lead == "Couldn't send" && offline.reason == " · You're offline. Try again.")
        let general = QuestionCard.failureLine(.generic)
        #expect(general.reason == " · Something went wrong. Try again in a moment.")
        // 빨강은 기한 · 입력 오류뿐이다: 이 줄은 text/primary (굵게) + 보조색
        #expect(ConfirmCard.errorColor == TFColor.statusOverdue, "빨강 토큰은 ConfirmCard의 입력 오류에만 쓴다 (실패 줄은 쓰지 않는다)")
    }

    // MARK: 키 풀이

    @Test func digitsReturnSpaceEscapeAndArrowsMapToTheRulesKeys() {
        func key(_ characters: String, _ equivalent: KeyEquivalent? = nil) -> AgentQuestionKeyboard.Key? {
            QuestionCard.keyboardKey(key: equivalent ?? KeyEquivalent(characters.first ?? " "), characters: characters)
        }
        #expect(key("1") == .digit(1) && key("4") == .digit(4))
        #expect(key("a") == nil && key("12") == nil)
        #expect(key("\r", .return) == .return)
        #expect(key(" ", .space) == .space)
        #expect(key("\u{1B}", .escape) == .escape)
        #expect(key("", .upArrow) == .up && key("", .downArrow) == .down)
    }

    // MARK: 크기 · 번들

    @Test func theCardScrollsInsideItselfPastSixtyPercentOfItsSurface() {
        #expect(QuestionCard.maxHeightShare == 0.6)
    }

    @MainActor @Test func everyKindRendersWithoutCrashing() {
        let kinds: [(AgentQuestionCard.Kind, [String])] = [(.single, ["A", "B", "C", "D"]), (.multi, ["A", "B"]), (.other, ["A", "B", "Other"]), (.text, []), (.approval, ["Allow", "Deny"]), (.secret, []), (.secretRemote, [])]
        for (kind, rows) in kinds {
            for status in [QuestionCard.Status.open, .holding, .sent] {
                let view = QuestionCard(
                    card: card(kind, rows: rows, preview: kind == .approval ? "Edit src/content/pricing.mdx" : nil), status: status, summary: status == .open ? nil : "A", failure: status == .open ? .offline : nil,
                    checked: [0], otherOpen: kind == .other, remoteRow: "Answer on Mina's MacBook Pro", maxHeight: 200
                )
                let host = NSHostingView(rootView: view.frame(width: 356))
                host.frame = NSRect(x: 0, y: 0, width: 356, height: 600)
                host.layoutSubtreeIfNeeded()
                #expect(host.fittingSize.height > 20, "\(kind) \(status)")
            }
        }
    }
}
#endif
