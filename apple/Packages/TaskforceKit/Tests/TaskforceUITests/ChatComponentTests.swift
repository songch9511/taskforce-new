import Foundation
import Testing
import TaskforceKit
@testable import TaskforceUI
#if os(macOS)
import AppKit
#endif

/// 0.2.0 Chats · Remembered 부품 (B3): 순수 규칙 · 접근성 이름 · IME 조합 중 Enter · 금지 문구 · 아이콘 역할
struct ChatComponentTests {
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
