import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Taskforce
@testable import TaskforceKit
@testable import TaskforceUI

/// 저장된 대화 읽기 패널의 말이 어떤 글로 그려지나 (OA D3v-m, 계약 27장 Q-D3v4): 답은 **세션 보기와 같은 안전한 서식**(`SessionMarkdownView` → `SafeMarkdown`, 링크 없음), 보낸 말은 쓴 그대로.
/// SwiftUI는 접근성 클라이언트가 없으면 글 노드를 만들지 않으므로(`SessionViewReviewMacTests`) 그리는 길을 본다: 안전한 서식의 해석 판(`SessionMarkdownCache`)을 지나가는가
@MainActor
struct SavedChatsViewTests {
    /// 그려 보고 맞춘 높이를 돌려준다
    @discardableResult
    private func lay(_ view: some View) -> CGFloat {
        let hosting = NSHostingView(rootView: view.frame(width: 340))
        hosting.frame = NSRect(x: 0, y: 0, width: 340, height: 400)
        hosting.layoutSubtreeIfNeeded()
        let height = hosting.fittingSize.height
        hosting.layoutSubtreeIfNeeded()
        return height
    }

    @Test func aReplyIsDrawnThroughTheSafeMarkdownRendererLikeTheSessionView() {
        let source = "**Lifetime** card: `price` only — unique-\(UUID().uuidString)"
        let cache = SessionMarkdownCache.shared
        let before = cache.lookups
        lay(SavedChatItemView(item: .reply(markdown: source, copyText: source, time: "09:41"), dayLabel: nil))
        #expect(cache.lookups > before, "답 글이 안전한 서식의 해석 판을 지나지 않았다: 서식을 끈 것이다")
        #expect(SavedChatItem.reply(markdown: source, copyText: source, time: "x").rendersMarkdown)
    }

    @Test func aSentMessageIsLiteralTextAndNeverGoesThroughMarkdown() {
        let cache = SessionMarkdownCache.shared
        let before = cache.lookups
        lay(SavedChatItemView(item: .sent(text: "**not bold** `not code` unique-\(UUID().uuidString)"), dayLabel: "Oct 21"))
        #expect(cache.lookups == before, "보낸 말은 쓴 그대로다 (서식 없음)")
        #expect(!SavedChatItem.sent(text: "x").rendersMarkdown)
    }

    @Test func linksInAReplyAreNotRenderedAsLinks() {
        // 같은 해석기를 쓰므로 링크는 글자 그대로다 (모델이 쓴 글이 링크로 그려지면 피싱 · 추적 경로가 된다, 22장 보안 검토 P3-2)
        let blocks = SafeMarkdown.parse("see [the docs](https://example.com/phish) now")
        guard case .paragraph(let inlines)? = blocks.first else { Issue.record("문단이 아니다"); return }
        let attributed = SessionMarkdownRender.attributed(inlines, bold: false)
        #expect(!attributed.runs.contains { $0.link != nil }, "링크 속성이 없다")
    }

    @Test func theDayLineStandsAboveAnItemAndTheReplyFooterStandsBelowItsText() {
        let reply = SavedChatItem.reply(markdown: "hi", copyText: "hi", time: "09:41")
        let withDay = lay(SavedChatItemView(item: reply, dayLabel: "Yesterday"))
        let plain = lay(SavedChatItemView(item: reply, dayLabel: nil))
        let textOnly = lay(Message(isUser: false) { SessionMarkdownView(source: "hi") })
        #expect(withDay > plain + 10, "날짜 줄이 위에 서서 높이를 더한다 (\(withDay) vs \(plain))")
        #expect(plain >= textOnly + 28, "답 밑에 시각 · Copy 줄(28)이 선다 (\(plain) vs \(textOnly))")
        let sent = lay(SavedChatItemView(item: .sent(text: "hi"), dayLabel: nil))
        #expect(sent > 0 && lay(SavedChatItemView(item: .sent(text: "hi"), dayLabel: "Today")) > sent + 10, "보낸 말 위에도 날짜 줄")
        #expect(lay(SavedChatItemView(item: nil, dayLabel: nil)) == 0, "그릴 것이 없으면 자리도 없다")
    }

    @Test func aRepliesCopyButtonCopiesTheRawStoredBodyNotTheEllipsisThatIsDrawn() {
        let item = SavedChatItem.reply(markdown: "cut off here…", copyText: "cut off here", time: "09:41")
        let reply = SavedChatItemView.replyView(item, revealed: false)
        #expect(reply?.markdown == "cut off here…" && reply?.time == "09:41", "그리는 글은 말줄임이 붙은 그대로")
        #expect(reply?.copyButton.text == "cut off here", "복사 단추는 저장된 원문을 복사한다: 그림용 말줄임을 가져가지 않는다")
        #expect(SavedChatItemView.replyView(.sent(text: "x"), revealed: false) == nil && SavedChatItemView.replyView(nil, revealed: false) == nil, "답이 아니면 복사 줄이 없다")
    }
}
