import Foundation
import Testing
import TaskforceKit
@testable import TaskforceUI
#if os(macOS)
import AppKit
#endif

/// 0.2.0 Chats · Remembered 부품 (B3): 순수 규칙 · 접근성 이름 · IME 조합 중 Enter · 금지 문구 · 아이콘 역할
struct ChatComponentTests {
    @Test func contextualPayloadCanDisableSendingWithoutDisablingDraftEditing() {
        #expect(!Composer.canSend(text: "Correctable draft", isDisabled: false, isSending: false, sendEnabled: false))
        #expect(Composer.fieldEnabled(isDisabled: false, blocked: nil))
        #expect(Composer.canSend(text: "Corrected draft", isDisabled: false, isSending: false, sendEnabled: true))
    }

    @Test func composerSendsOnlyRealTextWhenEnabledAndIdle() {
        #expect(Composer.canSend(text: "Hello", isDisabled: false, isSending: false))
        #expect(!Composer.canSend(text: "  \n", isDisabled: false, isSending: false), "빈 글은 보낼 수 없다")
        #expect(!Composer.canSend(text: "Hello", isDisabled: true, isSending: false), "꺼져 있으면 보낼 수 없다")
        #expect(!Composer.canSend(text: "Hello", isDisabled: false, isSending: true), "보내는 중에는 Send가 꺼진다")
        #expect(!Composer.canSend(text: String(repeating: "a", count: 4001), isDisabled: false, isSending: false))
    }

    @Test func statusLineNeverCallsAnUnconfirmedMessageDone() {
        #expect(ChatStatusLine.text(.sent) == nil)
        #expect(ChatStatusLine.text(.sending) == "Sending…")
        #expect(ChatStatusLine.text(.failed("Can't reach the server. Check your connection.")) == "Not sent · Can't reach the server. Check your connection.")
        #expect(ChatStatusLine.text(.needsConsent) == "Not sent")
        #expect(ChatStatusLine.text(.noReply) == "No reply yet")
        #expect(ChatStatusLine.text(.notAnswered) == "Not answered")
        #expect(ChatTurn.Status.failed("x").canRetry && ChatTurn.Status.noReply.canRetry && ChatTurn.Status.needsConsent.canRetry)
        #expect(!ChatTurn.Status.sending.canRetry && !ChatTurn.Status.notAnswered.canRetry && !ChatTurn.Status.sent.canRetry)
    }

    @Test func chatItemAndQuoteNamesJoinOnlyWhatExists() {
        #expect(ChatItem.accessibilityLabel(title: "Pricing copy check", date: "Oct 8", preview: "Draft · Can you compare plan B with")
            == "Pricing copy check, Oct 8, Draft · Can you compare plan B with")
        #expect(ChatItem.accessibilityLabel(title: "New chat", date: "Oct 8", preview: nil) == "New chat, Oct 8")
        #expect(SourceQuote.metaLine(from: "Jordan Lee", place: "Gmail", time: "Today 10:42") == "Jordan Lee · Gmail · Today 10:42")
        // 채팅에서 한 말: 서비스 마크 없이 "You · Chat · 시각"
        #expect(SourceQuote.metaLine(from: "You", place: "Chat", time: "Today 10:24") == "You · Chat · Today 10:24")
        #expect(SourceQuote.metaLine(from: nil, place: nil, time: nil).isEmpty)
    }

    /// 추정 전용 각주는 지금 기억인 inferred에만: 원문이 지워진 observed는 흐리게 보이지만 각주가 없다
    @Test func inferredFootnoteIsOnlyForCurrentInferredItems() {
        func content(origin: MemoryOrigin, current: Bool = true, tentative: Bool) -> RememberedDetail.Content {
            RememberedDetail.Content(
                statement: "s", isTentative: tentative, isCurrent: current, kind: "k", scopeName: "All work", when: "Oct 6", source: .hidden,
                isInferred: origin == .inferred
            )
        }
        let note = "Inferred items are not used in any work until you confirm them."
        #expect(RememberedDetail.footnote(for: content(origin: .inferred, tentative: true)) == note)
        // 원문이 지워진 observed: 흐린 글은 유지(isTentative), 각주는 없다
        let purged = content(origin: .observed, tentative: true)
        #expect(purged.isTentative && RememberedDetail.footnote(for: purged) == nil)
        #expect(RememberedDetail.footnote(for: content(origin: .explicit, tentative: false)) == nil)
        #expect(RememberedDetail.footnote(for: content(origin: .observed, tentative: false)) == nil)
        // 지금 기억이 아닌 추정에는 없다
        #expect(RememberedDetail.footnote(for: content(origin: .inferred, current: false, tentative: true)) == nil)
    }

    @Test func iconsComeFromTheRoleTable() {
        #expect(TFIcon.newChat.rawValue == "square-pen" && TFIcon.chatHistory.rawValue == "history")
        #expect(TFIcon.send.rawValue == "arrow-up" && TFIcon.project.rawValue == "folder" && TFIcon.popupButton.rawValue == "chevrons-up-down")
    }

    /// 화면에 쓰지 않는 말 · 자산: "All caught up" · "Nothing here" · Claude/Anthropic · 색 점 글리프 · SF Symbol · 색으로 채운 점 (S3 방식을 새 파일까지)
    @Test func newComponentSourcesAvoidBannedCopyAndAssets() throws {
        let dot = try NSRegularExpression(pattern: #"(Circle|Ellipse)\(\)\s*\.(fill|foregroundStyle|foregroundColor)"#)
        let systemColor = try NSRegularExpression(pattern: #"Color\.(green|yellow|orange|blue|red|purple|pink|mint|teal)\b|\.(green|yellow|orange|blue|purple)\b"#)
        for file in Self.drawnFiles {
            let source = try WorkComponentTests.source(file)
            let literals = WorkComponentTests.literals(in: source)
            #expect(!literals.isEmpty, "\(file)")
            for literal in literals {
                let phrase = ["caught up", "nothing here", "claude", "anthropic"].first { literal.localizedCaseInsensitiveContains($0) }
                #expect(phrase == nil, "\(file): \(literal)")
                let glyph = ["●", "•", "◦", "🔴", "🟢", "🟡", "🔵", "✨", "…!"].first { literal.contains($0) }
                #expect(glyph == nil, "\(file): \(literal)")
            }
            let code = WorkComponentTests.code(source)
            let range = NSRange(code.startIndex..., in: code)
            #expect(!code.contains("Image(systemName:") && !code.contains("systemImage:"), "\(file)")
            #expect(dot.firstMatch(in: code, range: range) == nil, "\(file)")
            #expect(systemColor.firstMatch(in: code, range: range) == nil, "\(file)")
            // 인용에 밑줄을 긋지 않는다
            #expect(!code.contains(".underline("), "\(file)")
        }
    }

    static let drawnFiles = ["ChatComponents.swift", "RememberedComponents.swift", "ProjectLink.swift"]
}

/// 에이전트 대화의 부품 (OA D4a-1): 전달 줄(링크 포함) · 이벤트 줄 · Composer의 Stop
struct AgentChatComponentTests {
    typealias Link = MessageDeliveryLine.Link

    @Test func theDeliveryLineIsOneAccessibleElementAndTheLinkIsItsOwnControl() {
        let line = MessageDeliveryLine(strong: "Not sent", text: "Access not verified", link: Link(.sendAgain, "Send again"))
        #expect(MessageDeliveryView.accessibilityName(line) == "Not sent · Access not verified", "전달 줄 = combined")
        #expect(MessageDeliveryView.linkAccessibilityName(line) == "Send again", "링크는 따로 누르는 동작이다")
        #expect(MessageDeliveryView.linkAccessibilityName(MessageDeliveryLine(strong: nil, text: "Sent")) == nil)
    }

    /// DS `.tf-delivery`: 오른쪽 맞춤으로 감싸는 flex. 글이 길면 링크가 다음 줄로 내려가고 두 줄 모두 오른쪽 끝에 붙는다 (열 간격 8)
    @Test func theWrapLayoutAlignsEveryRowToTheTrailingEdgeWithAnEightPointGap() {
        let text = CGSize(width: 120, height: 18)
        let link = CGSize(width: 60, height: 18)
        let wide = TrailingWrapLayout.place(sizes: [text, link], width: 400, spacing: 8)
        #expect(wide.frames == [CGRect(x: 212, y: 0, width: 120, height: 18), CGRect(x: 340, y: 0, width: 60, height: 18)], "한 줄: 링크가 오른쪽 끝")
        #expect(wide.height == 18)
        let narrow = TrailingWrapLayout.place(sizes: [text, link], width: 150, spacing: 8)
        #expect(narrow.frames == [CGRect(x: 30, y: 0, width: 120, height: 18), CGRect(x: 90, y: 18, width: 60, height: 18)], "링크가 다음 줄, 둘 다 오른쪽 맞춤")
        #expect(narrow.height == 36)
        let textOnly = TrailingWrapLayout.place(sizes: [text], width: 400, spacing: 8)
        #expect(textOnly.frames == [CGRect(x: 280, y: 0, width: 120, height: 18)])
        #expect(TrailingWrapLayout.place(sizes: [], width: 400, spacing: 8).height == 0)
    }

    @Test func anEventLineIsOneTruncatedFootnoteOfTheServersWords() throws {
        #expect(EventLine.accessibilityName("Opened in Terminal") == "Opened in Terminal")
        let code = WorkComponentTests.code(try WorkComponentTests.source("ChatComponents.swift"))
        #expect(code.contains("EventLine"))
        #expect(EventLine.lineLimit == 1, "긴 서버 이벤트 글은 한 줄 끝 줄임")
    }

    @Test func theComposersCircleBecomesStopWhileWorkRunsAndStillSendsOnEnter() {
        #expect(Composer.sendLabel(running: false, isSending: false) == "Send")
        #expect(Composer.sendLabel(running: false, isSending: true) == "Sending")
        #expect(Composer.sendLabel(running: true, isSending: false) == "Stop new steps", "접근성 이름")
        #expect(Composer.sendLabel(running: true, isSending: true) == "Stop new steps", "Stop이 이긴다")
        // Stop 중에도 글을 쓰고 Enter로 보낼 수 있다 (그 메시지는 대기열에 들어간다)
        #expect(Composer.canSend(text: "Also update the refund wording", isDisabled: false, isSending: false))
        #expect(Composer.circleStopsInsteadOfSending(running: true) && !Composer.circleStopsInsteadOfSending(running: false))
        #expect(PromptBox.sendLabel(running: true) == "Stop new steps")
    }

    @Test func aViewFullLinkIsOnlyForACutReplyThatThisMacHasAndTheCutReplyEndsWithAnEllipsis() {
        func turn(text: String = "Draft v2 covers the Pro monthly", truncated: Bool, canView: Bool = false, full: String? = nil) -> ChatTurn {
            ChatTurn(
                id: UUID(), isUser: false, text: text, createdAt: Date(), status: .sent, clientMessageID: nil, isTruncated: truncated, canViewFull: canView, fullText: full
            )
        }
        #expect(MessageViewFull.shownText(turn(truncated: true)) == "Draft v2 covers the Pro monthly…", "잘린 답은 말줄임표로 끝난다")
        #expect(MessageViewFull.shownText(turn(truncated: false)) == "Draft v2 covers the Pro monthly")
        #expect(MessageViewFull.shownText(turn(truncated: true, canView: true, full: "The whole reply.")) == "The whole reply.", "펼치면 전문")
        #expect(MessageViewFull.shownText(turn(text: "cut…", truncated: true)) == "cut…", "이미 말줄임표면 더하지 않는다")
        #expect(MessageViewFull.showsLink(turn(truncated: true, canView: true)))
        #expect(!MessageViewFull.showsLink(turn(truncated: true)), "이 Mac에 전문이 없으면 링크가 없다")
        #expect(!MessageViewFull.showsLink(turn(truncated: true, canView: true, full: "x")), "펼친 뒤에는 링크가 사라진다")
        #expect(!MessageViewFull.showsLink(turn(truncated: false, canView: true)), "자르지 않은 글에는 링크가 없다")
        #expect(MessageViewFull.title == "View full")
    }
}

#if os(macOS)
/// IME 조합 중에는 Enter가 조합을 확정할 뿐 글을 보내지 않는다 (한글 · 일본어). 진짜 `NSTextView`의 marked text로 확인한다
@MainActor
struct ComposerIMETests {
    final class Submissions {
        var count = 0
    }

    func makeEditor() throws -> (coordinator: ComposerTextField.Coordinator, field: ComposerNSTextField, editor: NSTextView, submissions: Submissions) {
        let submissions = Submissions()
        let composer = ComposerTextField(
            text: .constant(""), placeholder: "Ask Taskforce…", label: "Reply to Taskforce", isEnabled: true, focusRequest: 0, onFocusChange: { _ in },
            onSubmit: { submissions.count += 1 }
        )
        let coordinator = composer.makeCoordinator()
        let field = ComposerNSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.delegate = coordinator
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 60), styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView?.addSubview(field)
        window.makeFirstResponder(field)
        let editor = try #require(field.currentEditor() as? NSTextView)
        return (coordinator, field, editor, submissions)
    }

    @Test func enterDuringCompositionDoesNotSend() throws {
        let (coordinator, field, editor, submissions) = try makeEditor()
        editor.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
        let handled = coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        #expect(!handled && submissions.count == 0, "조합 중 Enter는 조합 확정에 쓰이고 보내지 않는다")
        // 조합이 끝나면 Enter가 보낸다
        editor.unmarkText()
        #expect(!editor.hasMarkedText())
        let sent = coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        #expect(sent && submissions.count == 1)
    }

    /// 포커스가 와도 쓰던 초안을 전부 선택하지 않는다 (다음 글자가 초안을 지우지 않게): 커서는 글 끝
    @Test func focusKeepsTheDraftAndPutsTheCaretAtTheEnd() throws {
        let (_, field, editor, _) = try makeEditor()
        field.stringValue = "Can you compare plan B with"
        field.placeCaretAtEnd()
        #expect(editor.selectedRange == NSRange(location: field.stringValue.utf16.count, length: 0))
        // 조합 중에는 커서를 옮기지 않는다
        editor.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let before = editor.selectedRange
        field.placeCaretAtEnd()
        #expect(editor.selectedRange == before)
    }

    @Test func onlyReturnSubmitsNotOtherCommands() throws {
        let (coordinator, field, editor, submissions) = try makeEditor()
        #expect(!coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveLeft(_:))))
        #expect(!coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(submissions.count == 0)
        #expect(ComposerKeyRule.shouldSubmit(selector: #selector(NSResponder.insertNewline(_:)), hasMarkedText: false))
        #expect(!ComposerKeyRule.shouldSubmit(selector: #selector(NSResponder.insertNewline(_:)), hasMarkedText: true))
    }
}
#endif

/// Composer의 막힘 (OA D4b-m-1, DS Composer "Blocked"): 비밀값 질문이 위에 열려 있다
struct ComposerBlockedTests {
    @Test func aBlockedComposerCannotSendAndItsFieldIsOff() {
        #expect(!Composer.canSend(text: "Hello", isDisabled: false, isSending: false, blocked: ""), "여기 쓴 글이 비밀값의 답이 되는 길이 없다")
        #expect(Composer.canSend(text: "Hello", isDisabled: false, isSending: false, blocked: nil))
        #expect(!Composer.fieldEnabled(isDisabled: false, blocked: "") && Composer.fieldEnabled(isDisabled: false, blocked: nil) && !Composer.fieldEnabled(isDisabled: true, blocked: nil))
    }

    @Test func theBlockedPlaceholderIsTheStandardWordsUnlessAnotherIsGiven() {
        #expect(Composer.placeholder(base: "Message Claude Code", blocked: nil) == "Message Claude Code")
        #expect(Composer.placeholder(base: "Message Claude Code", blocked: "") == "Answer the question above first")
        #expect(Composer.placeholder(base: "Message Claude Code", blocked: "Wait for the token") == "Wait for the token")
    }

    @Test func theCircleIsQuietWhenBlockedButStopStaysAvailableWhileAnAgentRuns() {
        #expect(Composer.circleIsQuiet(blocked: "", running: false))
        #expect(!Composer.circleIsQuiet(blocked: "", running: true), "Stop은 막힘과 상관없이 쓸 수 있다")
        #expect(!Composer.circleIsQuiet(blocked: nil, running: false))
        #expect(Composer.sendLabel(running: true, isSending: false) == "Stop new steps")
    }
}


/// PromptBox의 보내기 원 (OA D4b-m-1, DS PromptBox "Blocked" · "Running"): 비밀값 질문으로 막혀도 에이전트가 실행 중이면 Stop은 살아 있다
struct PromptBoxBlockedTests {
    @Test func stopDrawsLiveWhileBlockedAndRunning() {
        #expect(!PromptBox.circleIsQuiet(blocked: true, running: true), "막힘 + 실행 중: Stop은 조용한 모양이 아니다")
        #expect(!PromptBox.circleIsQuiet(blocked: false, running: true))
    }

    @Test func blockedAndNotRunningStaysQuiet() {
        #expect(PromptBox.circleIsQuiet(blocked: true, running: false), "막힘 + 멈춤: bg/selected 원 + 회색 화살표")
        #expect(!PromptBox.circleIsQuiet(blocked: false, running: false), "막히지 않으면 조용한 모양이 아니다 (보낼 수 없으면 35%로 흐려질 뿐)")
    }

    @Test func theSameRuleAsTheComposerCircle() {
        for blocked in [false, true] {
            for running in [false, true] {
                #expect(PromptBox.circleIsQuiet(blocked: blocked, running: running) == Composer.circleIsQuiet(blocked: blocked ? "" : nil, running: running))
            }
        }
    }
}
