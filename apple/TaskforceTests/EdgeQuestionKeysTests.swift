import AppKit
import Carbon.HIToolbox
import Foundation
import SwiftUI
import Testing
@testable import Taskforce
@testable import TaskforceKit
@testable import TaskforceUI

/// 질문 카드가 실제 AppKit 이벤트를 받는 길 (OA D4b-m-1, D4bm-30 · 32): 화면 밖(-10000)의 창에 카드를 올려 키를 `NSWindow.sendEvent`로 보낸다.
/// 1–4는 카드(또는 줄)에 포커스가 있을 때만, 입력 칸에서는 글자, 번호가 안 보여도 키는 동작, Return · Space · ↑↓. 규칙 표는 Kit의 `AgentQuestionKeyboardTests`가 고정하고 여기는 SwiftUI 연결을 본다
@MainActor
struct EdgeQuestionKeysTests {
    final class Calls {
        var chosen: [Int] = []
        var toggled: [Int] = []
        var sendChecked = 0
        var texts: [String] = []
        var secrets: [String] = []
        var undo = 0
        var closeOther = 0
        var focus: [Bool] = []
    }

    @MainActor
    struct Harness {
        let window: NSWindow
        let calls: Calls
        let model: Model
        @Observable
        final class Model {
            var focusRequest = 0
            /// 아래 입력칸(composer를 대신한다)이 포커스를 가져가라는 요청: 실제 창에서는 입력칸이 처음 포커스를 가진다
            var composerFocus = 1
            var composerText = ""
            var checked: Set<Int> = []
            var otherOpen = false
            var status: QuestionCard.Status = .open
            /// 카드가 아직 도착하지 않았다 (false → true로 바꾸면 도착)
            var cardVisible = true
        }

        func send(_ characters: String, code: Int, flags: NSEvent.ModifierFlags = []) {
            guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(code)
            ) else { return }
            window.sendEvent(event)
        }

        func settle() async { try? await Task.sleep(for: .milliseconds(120)) }
        func close() { window.orderOut(nil) }
    }

    struct Root: View {
        let spec: AgentQuestionCard
        let calls: Calls
        let model: Harness.Model

        var body: some View {
            VStack(spacing: 8) {
                if model.cardVisible { questionCard }
                ComposerTextField(
                    text: Binding(get: { model.composerText }, set: { model.composerText = $0 }), placeholder: "Message", label: "Message", isEnabled: true,
                    focusRequest: model.composerFocus, onFocusChange: { _ in }, onSubmit: {}
                )
                .frame(height: 24)
            }
            .frame(width: 356)
        }

        private var questionCard: some View {
            QuestionCard(
                card: spec, status: model.status, summary: "A", checked: model.checked, otherOpen: model.otherOpen, focusRequest: model.focusRequest,
                actions: QuestionCardActions(
                    onChoose: { calls.chosen.append($0) }, onToggle: { calls.toggled.append($0) }, onSendChecked: { calls.sendChecked += 1 }, onSubmitText: { calls.texts.append($0) }, onSubmitSecret: { calls.secrets.append($0.reveal()) },
                    onCloseOther: { calls.closeOther += 1 }, onUndo: { calls.undo += 1 }, onFocusChange: { calls.focus.append($0) }
                )
            )
        }
    }

    private func card(_ kind: AgentQuestionCard.Kind, rows: [String] = [], other: Bool = false) -> AgentQuestionCard {
        AgentQuestionCard(
            promptID: "q1", kind: kind, title: "Which price should lead the yearly card?",
            rows: rows.enumerated().map { .init(label: $0.element, isOther: other && $0.offset == rows.count - 1) }
        )
    }

    private func harness(_ card: AgentQuestionCard, cardVisible: Bool = true) async -> Harness {
        let calls = Calls()
        let model = Harness.Model()
        model.cardVisible = cardVisible
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 380, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: Root(spec: card, calls: calls, model: model))
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        let h = Harness(window: window, calls: calls, model: model)
        await h.settle()
        return h
    }

    /// 카드로 포커스를 옮긴다 (링 · 알림으로 세션이 열릴 때와 같은 길: `focusRequest`)
    private func focusCard(_ h: Harness) async {
        h.model.focusRequest += 1
        await h.settle()
    }

    @Test func digitsAnswerOnlyAfterTheCardHasFocusAndNotBefore() async throws {
        let h = await harness(card(.single, rows: ["A", "B", "C", "D"]))
        defer { h.close() }
        h.send("2", code: kVK_ANSI_2)
        await h.settle()
        #expect(h.calls.chosen.isEmpty, "포커스가 없으면 1–4는 카드의 일이 아니다")
        await focusCard(h)
        h.send("2", code: kVK_ANSI_2)
        await h.settle()
        #expect(h.calls.chosen == [1], "카드에 포커스가 있으면 2는 둘째 줄")
        h.send("4", code: kVK_ANSI_4)
        h.send("5", code: kVK_ANSI_5)
        await h.settle()
        #expect(h.calls.chosen == [1, 3])
    }

    @Test func keysWorkWithoutNumbersAndCommandOptionControlStayFree() async throws {
        let h = await harness(card(.single, rows: ["A", "B", "C"]))
        defer { h.close() }
        await focusCard(h)
        h.send("1", code: kVK_ANSI_1, flags: .command)
        h.send("1", code: kVK_ANSI_1, flags: .option)
        await h.settle()
        #expect(h.calls.chosen.isEmpty, "⌘1은 카드가 아니라 단축키다")
        h.send("3", code: kVK_ANSI_3)
        await h.settle()
        #expect(h.calls.chosen == [2], "번호가 안 보여도 키는 동작한다")
    }

    @Test func multiSelectSpaceTogglesTheFocusedRowAndReturnSendsOnlyWithAChecked() async throws {
        let h = await harness(card(.multi, rows: ["A", "B", "C"]))
        defer { h.close() }
        await focusCard(h)
        h.send("\r", code: kVK_Return)
        await h.settle()
        #expect(h.calls.sendChecked == 0, "하나라도 체크되기 전까지 Return은 보내지 않는다")
        h.send("1", code: kVK_ANSI_1)
        await h.settle()
        #expect(h.calls.chosen.isEmpty && h.calls.toggled.isEmpty, "다중은 체크 상자: 번호 키가 없다")
        h.model.checked = [0]
        await h.settle()
        h.send("\r", code: kVK_Return)
        await h.settle()
        #expect(h.calls.sendChecked == 1)
    }

    @Test func arrowKeysMoveTheFocusedRowAndReturnChoosesIt() async throws {
        let h = await harness(card(.single, rows: ["A", "B", "C"]))
        defer { h.close() }
        await focusCard(h)
        h.send("\u{F701}", code: kVK_DownArrow)
        await h.settle()
        h.send("\u{F701}", code: kVK_DownArrow)
        await h.settle()
        h.send("\r", code: kVK_Return)
        await h.settle()
        #expect(h.calls.chosen == [1], "↓↓ → 둘째 줄: 첫 ↓가 첫째 줄에 닿고 둘째 ↓가 둘째 줄로 간다")
    }

    @Test func aFoldedCardAnswersNothingExceptUndoOnEscapeWhileHeld() async throws {
        let h = await harness(card(.single, rows: ["A", "B", "C", "D"]))
        defer { h.close() }
        await focusCard(h)
        h.model.status = .holding
        await h.settle()
        h.send("2", code: kVK_ANSI_2)
        h.send("\r", code: kVK_Return)
        await h.settle()
        #expect(h.calls.chosen.isEmpty, "접힌 뒤에는 답할 수 없다")
    }

    @Test func digitsTypedIntoTheOtherFieldAreTextAndReturnSendsThem() async throws {
        let h = await harness(card(.other, rows: ["A", "B", "Other"], other: true))
        defer { h.close() }
        h.model.otherOpen = true
        await h.settle()
        h.send("2", code: kVK_ANSI_2)
        await h.settle()
        #expect(h.calls.chosen.isEmpty, "입력 칸에 포커스가 있으면 숫자는 글자다")
        h.send("\r", code: kVK_Return)
        await h.settle()
        #expect(h.calls.texts == ["2"] && h.calls.chosen.isEmpty, "Return이 쓴 글을 보낸다")
    }

    @Test func aSecretIsReadOnceFromTheMaskedFieldAndTheFieldIsClearedAtOnce() async throws {
        let h = await harness(card(.secret))
        defer { h.close() }
        await focusCard(h)
        for digit in ["4", "2"] { h.send(digit, code: digit == "4" ? kVK_ANSI_4 : kVK_ANSI_2) }
        await h.settle()
        #expect(h.calls.chosen.isEmpty && h.calls.secrets.isEmpty)
        h.send("\r", code: kVK_Return)
        await h.settle()
        #expect(h.calls.secrets == ["42"], "마스크 칸에서 한 번 읽는다")
        h.send("\r", code: kVK_Return)
        await h.settle()
        #expect(h.calls.secrets == ["42"], "칸은 곧바로 비워졌다: 다시 Return해도 보낼 값이 없다")
    }

    // MARK: 검토 1: 새 입력 카드는 요청 없이 포커스를 가져가지 않는다 (D4bm-31)

    /// 지금 글을 받는 칸. 필드 에디터는 창에서 하나를 같이 쓰므로(`NSTextField`끼리) 에디터가 아니라 그 에디터가 편집 중인 칸으로 비교한다
    private func focusedField(_ window: NSWindow) -> NSView? {
        let responder = window.firstResponder
        if let editor = responder as? NSTextView, let control = editor.delegate as? NSView { return control }
        return responder as? NSView
    }

    @Test(arguments: [AgentQuestionCard.Kind.text, .secret])
    func anInputCardArrivingWhileTheComposerHasFocusLeavesFocusWhereItIs(kind: AgentQuestionCard.Kind) async throws {
        let h = await harness(card(kind), cardVisible: false)
        defer { h.close() }
        let composer = try #require(focusedField(h.window), "composer 입력 중이다")
        h.model.cardVisible = true
        await h.settle()
        #expect(focusedField(h.window) === composer, "카드가 도착해도 쓰던 composer에 포커스가 남는다 (\(kind))")
    }

    @Test(arguments: [AgentQuestionCard.Kind.text, .secret])
    func anInputCardThatWasAskedToTakeFocusStillTakesIt(kind: AgentQuestionCard.Kind) async throws {
        let h = await harness(card(kind), cardVisible: false)
        defer { h.close() }
        let composer = try #require(focusedField(h.window))
        h.model.focusRequest = 1
        h.model.cardVisible = true
        await h.settle()
        #expect(focusedField(h.window) !== composer, "요청이 있으면(링 · 알림) 입력 칸이 포커스를 받는다 (\(kind))")
    }
}
