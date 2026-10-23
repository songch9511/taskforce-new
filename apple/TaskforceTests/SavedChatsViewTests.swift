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
    private func lay(_ view: some View) {
        let hosting = NSHostingView(rootView: view.frame(width: 340))
        hosting.frame = NSRect(x: 0, y: 0, width: 340, height: 400)
        hosting.layoutSubtreeIfNeeded()
        _ = hosting.fittingSize
        hosting.layoutSubtreeIfNeeded()
    }

    @Test func aReplyIsDrawnThroughTheSafeMarkdownRendererLikeTheSessionView() {
        let source = "**Lifetime** card: `price` only — unique-\(UUID().uuidString)"
        let cache = SessionMarkdownCache.shared
        let before = cache.lookups
        lay(SavedChatItemView(item: .reply(markdown: source, time: "09:41"), dayLabel: nil))
        #expect(cache.lookups > before, "답 글이 안전한 서식의 해석 판을 지나지 않았다: 서식을 끈 것이다")
        #expect(SavedChatItem.reply(markdown: source, time: "x").rendersMarkdown)
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

    @Test func theDayLineAndTheReplyFooterDrawWithoutFailing() {
        lay(SavedChatItemView(item: .reply(markdown: "hi", time: "09:41"), dayLabel: "Yesterday"))
        lay(SavedChatItemView(item: .sent(text: "hi"), dayLabel: nil))
        lay(SavedChatItemView(item: nil, dayLabel: nil))
    }
}
