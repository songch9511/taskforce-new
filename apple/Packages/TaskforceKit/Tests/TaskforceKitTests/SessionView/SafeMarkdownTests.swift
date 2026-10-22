#if os(macOS)
import Foundation
import Testing
@testable import TaskforceKit

/// 답의 글 표시 (DZ v2 E1 · E4, 사용자 승인 "안전한 부분만 그림"): 코드 블록 · 인라인 코드 · 목록 · 굵게만 그린다. 링크 · 표 · 이미지 · HTML은 쓴 그대로 글자다.
/// 이 파서의 값에는 링크 · 첨부를 담을 자리가 **없다**: 어떤 글을 줘도 열리는 것이 만들어질 수 없다. 복사는 이 파서를 거치지 않는 원문이다
struct SafeMarkdownTests {
    typealias B = SafeMarkdown.Block
    typealias I = SafeMarkdown.Inline

    private func plain(_ text: String) -> [I] { [.text(text)] }

    // MARK: 문단 · 줄

    @Test func plainTextIsOneParagraphAndBlankLinesSplitParagraphs() {
        #expect(SafeMarkdown.parse("Hello there") == [.paragraph(plain("Hello there"))])
        #expect(SafeMarkdown.parse("One\n\nTwo") == [.paragraph(plain("One")), .paragraph(plain("Two"))])
        #expect(SafeMarkdown.parse("One\n\n\n\nTwo") == [.paragraph(plain("One")), .paragraph(plain("Two"))])
    }

    @Test func lineBreaksInsideAParagraphAreKept() {
        #expect(SafeMarkdown.parse("Line one\nLine two") == [.paragraph(plain("Line one\nLine two"))])
    }

    @Test func emptyAndWhitespaceOnlyTextHasNoBlocks() {
        #expect(SafeMarkdown.parse("").isEmpty)
        #expect(SafeMarkdown.parse(" \n\n \t\n").isEmpty)
    }

    @Test func windowsLineEndingsAreTreatedAsNewlines() {
        #expect(SafeMarkdown.parse("A\r\n\r\nB") == [.paragraph(plain("A")), .paragraph(plain("B"))])
    }

    // MARK: 코드 블록 (E4)

    @Test func aFencedBlockIsCodeWithItsLanguageAndNoSyntaxColourData() {
        let source = "Before\n```json\n{ \"a\": 1 }\n```\nAfter"
        #expect(SafeMarkdown.parse(source) == [.paragraph(plain("Before")), .code(language: "json", text: "{ \"a\": 1 }"), .paragraph(plain("After"))])
    }

    @Test func aFenceWithoutALanguageHasNone() {
        #expect(SafeMarkdown.parse("```\nnpm run lint:copy\n```") == [.code(language: nil, text: "npm run lint:copy")])
    }

    @Test func theCodeKeepsItsBlankLinesIndentationAndMarkdownLookalikes() {
        let code = "  indented\n\n**not bold** and `not code`\n- not a list\n[a](http://x)"
        #expect(SafeMarkdown.parse("```\n\(code)\n```") == [.code(language: nil, text: code)])
    }

    @Test func anUnterminatedFenceRunsToTheEndOfTheText() {
        #expect(SafeMarkdown.parse("```swift\nlet a = 1\nlet b = 2") == [.code(language: "swift", text: "let a = 1\nlet b = 2")])
    }

    @Test func aTildeFenceAndALongerFenceAreClosedByTheSameKind() {
        #expect(SafeMarkdown.parse("~~~\na\n~~~") == [.code(language: nil, text: "a")])
        #expect(SafeMarkdown.parse("````\n```\ninner\n```\n````") == [.code(language: nil, text: "```\ninner\n```")], "안쪽의 짧은 울타리는 닫지 못한다")
        #expect(SafeMarkdown.parse("```\na\n~~~\nb\n```") == [.code(language: nil, text: "a\n~~~\nb")], "다른 종류의 울타리는 닫지 못한다")
    }

    @Test func aFenceWithJunkAfterItIsNotAClosingFence() {
        #expect(SafeMarkdown.parse("```\na\n``` not closing\nb\n```") == [.code(language: nil, text: "a\n``` not closing\nb")])
    }

    @Test func aLanguageNameIsKeptOnlyWhenItLooksLikeOne() {
        #expect(SafeMarkdown.parse("```c++\nx\n```") == [.code(language: "c++", text: "x")])
        #expect(SafeMarkdown.parse("```json title=\"a\"\nx\n```") == [.code(language: "json", text: "x")], "첫 낱말만")
        #expect(SafeMarkdown.parse("```<script>alert(1)</script>\nx\n```") == [.code(language: nil, text: "x")])
        #expect(SafeMarkdown.parse("```\(String(repeating: "l", count: 40))\nx\n```") == [.code(language: nil, text: "x")], "너무 긴 이름은 언어가 아니다")
        // 짧아도 주소 · 태그 · 링크 문법의 글자가 든 이름은 언어가 아니다 (길이가 아니라 글자로 막는다)
        for hostile in ["javascript:x", "a/b", "x<y>", "[x](y)", "a(b)", "http://x.y", "a@b", "a=b", "ab/c"] {
            #expect(SafeMarkdown.parse("```\(hostile)\nx\n```") == [.code(language: nil, text: "x")], "언어 이름 \(hostile)")
        }
        #expect(SafeMarkdown.parse("```objective-c\nx\n```") == [.code(language: "objective-c", text: "x")])
        #expect(SafeMarkdown.parse("```c#\nx\n```") == [.code(language: "c#", text: "x")])
        #expect(SafeMarkdown.parse("```f_sharp.v2\nx\n```") == [.code(language: "f_sharp.v2", text: "x")])
    }

    @Test func anEmptyFencedBlockIsEmptyCode() {
        #expect(SafeMarkdown.parse("```\n```") == [.code(language: nil, text: "")])
    }

    @Test func aFenceMayBeIndentedUpToThreeSpaces() {
        #expect(SafeMarkdown.parse("   ```\nx\n   ```") == [.code(language: nil, text: "x")])
        #expect(SafeMarkdown.parse("    ```\nx") == [.paragraph(plain("```\nx"))], "네 칸 들여쓰기는 울타리가 아니다 (문단은 앞뒤 공백만 자른다)")
    }

    // MARK: 인라인 코드 · 굵게

    @Test func inlineCodeIsASpanAndItsContentIsNotInterpreted() {
        #expect(SafeMarkdown.parse("Use `npm run lint` now") == [.paragraph([.text("Use "), .code("npm run lint"), .text(" now")])])
        #expect(SafeMarkdown.parse("Keep `**raw**` as is") == [.paragraph([.text("Keep "), .code("**raw**"), .text(" as is")])])
    }

    @Test func aDoubleBacktickSpanMayContainASingleBacktick() {
        #expect(SafeMarkdown.parse("``a`b``") == [.paragraph([.code("a`b")])])
    }

    @Test func anUnmatchedBacktickStaysLiteral() {
        #expect(SafeMarkdown.parse("a ` b") == [.paragraph(plain("a ` b"))])
        #expect(SafeMarkdown.parse("a ``b` c") == [.paragraph(plain("a ``b` c"))])
    }

    @Test func boldIsBetweenDoubleAsterisksAndMayHoldInlineCode() {
        #expect(SafeMarkdown.parse("This is **3 days** only") == [.paragraph([.text("This is "), .bold([.text("3 days")]), .text(" only")])])
        #expect(SafeMarkdown.parse("**`Lifetime`** card") == [.paragraph([.bold([.code("Lifetime")]), .text(" card")])])
    }

    @Test func unbalancedOrEmptyBoldStaysLiteral() {
        #expect(SafeMarkdown.parse("a ** b") == [.paragraph(plain("a ** b"))])
        #expect(SafeMarkdown.parse("**open only") == [.paragraph(plain("**open only"))])
        #expect(SafeMarkdown.parse("****") == [.paragraph(plain("****"))])
        #expect(SafeMarkdown.parse("2 ** 3 ** 4") == [.paragraph(plain("2 ** 3 ** 4"))], "공백으로 둘러싸인 별은 굵게가 아니다")
    }

    @Test func singleAsterisksAndUnderscoresAreNotItalicAndStayLiteral() {
        #expect(SafeMarkdown.parse("*one* and _two_ and snake_case_name") == [.paragraph(plain("*one* and _two_ and snake_case_name"))])
        #expect(SafeMarkdown.parse("__bold?__") == [.paragraph(plain("__bold?__"))])
    }

    // MARK: 목록

    @Test func bulletsAreAListWhoseItemsKeepTheirInlineText() {
        let source = "- Trial card: **3 days**\n- Lifetime card"
        #expect(SafeMarkdown.parse(source) == [.list(ordered: false, items: [
            SafeMarkdown.ListItem(depth: 0, number: nil, inlines: [.text("Trial card: "), .bold([.text("3 days")])]),
            SafeMarkdown.ListItem(depth: 0, number: nil, inlines: plain("Lifetime card")),
        ])])
        #expect(SafeMarkdown.parse("* a\n+ b") == [.list(ordered: false, items: [
            SafeMarkdown.ListItem(depth: 0, number: nil, inlines: plain("a")), SafeMarkdown.ListItem(depth: 0, number: nil, inlines: plain("b")),
        ])])
    }

    @Test func numberedItemsKeepTheirNumbers() {
        let parsed = SafeMarkdown.parse("1. First\n2) Second\n10. Tenth")
        #expect(parsed == [.list(ordered: true, items: [
            SafeMarkdown.ListItem(depth: 0, number: 1, inlines: plain("First")),
            SafeMarkdown.ListItem(depth: 0, number: 2, inlines: plain("Second")),
            SafeMarkdown.ListItem(depth: 0, number: 10, inlines: plain("Tenth")),
        ])])
    }

    @Test func indentedItemsAreNestedOneOrTwoLevelsAndNoDeeper() {
        let parsed = SafeMarkdown.parse("- a\n  - b\n    - c\n          - d")
        guard case .list(_, let items)? = parsed.first else {
            Issue.record("목록이 아니다")
            return
        }
        #expect(items.map(\.depth) == [0, 1, 2, 2])
    }

    @Test func aListIsEndedByABlankLineAndAParagraphAfterItIsAParagraph() {
        let parsed = SafeMarkdown.parse("- a\n- b\n\nAfter the list")
        #expect(parsed.count == 2)
        #expect(parsed.last == .paragraph(plain("After the list")))
    }

    @Test func aWrappedLineBelongsToTheItemAbove() {
        let parsed = SafeMarkdown.parse("- first line\n  continues here\n- second")
        guard case .list(_, let items)? = parsed.first else {
            Issue.record("목록이 아니다")
            return
        }
        #expect(items.count == 2)
        #expect(items.first?.inlines == plain("first line\ncontinues here"))
    }

    @Test func aDashWithoutASpaceIsNotAListAndAnOrdinaryNumberIsNotEither() {
        #expect(SafeMarkdown.parse("-not a list") == [.paragraph(plain("-not a list"))])
        #expect(SafeMarkdown.parse("3.5 days") == [.paragraph(plain("3.5 days"))])
        #expect(SafeMarkdown.parse("2026. a year") == [.list(ordered: true, items: [SafeMarkdown.ListItem(depth: 0, number: 2026, inlines: plain("a year"))])])
    }

    @Test func aHugeNumberIsNotAListNumberSoItCannotOverflow() {
        let parsed = SafeMarkdown.parse("99999999999999999999. big")
        #expect(parsed == [.paragraph(plain("99999999999999999999. big"))])
    }

    // MARK: 제목

    @Test func aHeadingIsBoldTextOnlyWithoutASizeChange() {
        #expect(SafeMarkdown.parse("### Lifetime") == [.heading(plain("Lifetime"))])
        #expect(SafeMarkdown.parse("# One\ntext") == [.heading(plain("One")), .paragraph(plain("text"))])
        #expect(SafeMarkdown.parse("####### seven") == [.paragraph(plain("####### seven"))], "여섯 개까지만 제목이다")
        #expect(SafeMarkdown.parse("#nospace") == [.paragraph(plain("#nospace"))])
    }

    // MARK: 링크 · 표 · 이미지 · HTML은 쓴 그대로

    @Test func linksTablesImagesAndHTMLStayExactlyAsWritten() {
        let link = "See [the docs](https://example.com/a?b=c) or https://example.com or <https://example.com>"
        #expect(SafeMarkdown.parse(link) == [.paragraph(plain(link))])
        let image = "![alt](https://example.com/x.png)"
        #expect(SafeMarkdown.parse(image) == [.paragraph(plain(image))])
        let html = "<a href=\"https://x\">hi</a> <img src=x onerror=alert(1)> <script>x</script>"
        #expect(SafeMarkdown.parse(html) == [.paragraph(plain(html))])
        let table = "| a | b |\n|---|---|\n| 1 | 2 |"
        #expect(SafeMarkdown.parse(table) == [.paragraph(plain(table))])
        let quote = "> quoted\n> more"
        #expect(SafeMarkdown.parse(quote) == [.paragraph(plain(quote))])
    }

    @Test func aLinkWithBoldOrCodeInsideItsTextIsStillOnlyText() {
        // 링크 문법 안의 굵게 · 코드는 해석한다(글자 모양일 뿐이다): 링크가 만들어지는 길은 아니다
        let blocks = SafeMarkdown.parse("[**bold** `code`](https://example.com)")
        #expect(blocks == [.paragraph([.text("["), .bold([.text("bold")]), .text(" "), .code("code"), .text("](https://example.com)")])])
    }

    @Test func theOutputCanHoldNothingButTextCodeAndBold() {
        // 구성상 링크 · 첨부 칸이 없다: 낯선 글을 줘도 모든 인라인은 이 셋이다
        let hostile = "[x](javascript:alert(1)) ![y](file:///etc/passwd) <a href=\"x\">z</a> `c` **b** https://a.b mailto:a@b.c"
        for block in SafeMarkdown.parse(hostile) {
            guard case .paragraph(let inlines) = block else {
                Issue.record("문단이 아니다")
                continue
            }
            for inline in inlines {
                switch inline {
                case .text, .code, .bold: continue
                }
            }
        }
        #expect(SafeMarkdown.plainText(of: SafeMarkdown.parse(hostile)).contains("javascript:alert(1)"), "글자로는 그대로 남는다")
    }

    // MARK: 한도 · 안전

    @Test func anOverlongParagraphIsLeftAsPlainTextSoParsingStaysLinear() {
        let long = "`" + String(repeating: "a", count: SafeMarkdown.maxInlineBytes + 10) + "` end"
        let parsed = SafeMarkdown.parse(long)
        #expect(parsed == [.paragraph(plain(long))])
    }

    @Test func hostileInputsAreParsedQuicklyAndNeverCrash() {
        let clock = ContinuousClock()
        let started = clock.now
        let inputs: [String] = [
            String(repeating: "`", count: 100_000), String(repeating: "``` ", count: 25_000), String(repeating: "**", count: 50_000), String(repeating: "- ", count: 50_000),
            String(repeating: "1. ", count: 50_000), String(repeating: "#", count: 100_000), String(repeating: "`a ", count: 40_000), String(repeating: "**a ", count: 40_000),
            String(repeating: "\n", count: 150_000), String(repeating: "  - x\n", count: 25_000), String(repeating: "```\n", count: 30_000), String(repeating: "[", count: 100_000),
            String(repeating: "\u{202E}", count: 50_000), String(repeating: "😀", count: 50_000), "\0\0\0" + String(repeating: "x", count: 50_000),
        ]
        for input in inputs { _ = SafeMarkdown.parse(input) }
        #expect(clock.now - started < .seconds(30), "한 번의 파싱은 입력 길이에 비례해야 한다 (디버그 빌드 · 바쁜 기계에서도 넉넉한 상한)")
    }

    @Test func parsingNeverLosesTextThatIsNotMarkup() {
        let source = "Plain words, 한국어도 그대로, emoji 😀, and punctuation: (a) [b] {c} <d> & e."
        #expect(SafeMarkdown.plainText(of: SafeMarkdown.parse(source)) == source)
    }

    @Test func copyUsesTheRawSourceNotTheParsedShape() {
        // 복사는 파서를 거치지 않는다: 호출하는 쪽은 원문을 그대로 쓴다 (파서 값에서 되돌리지 않는다)
        let source = "Both **cards** say `3 days`:\n\n```json\n{ \"days\": 3 }\n```"
        #expect(SafeMarkdown.codeTexts(in: SafeMarkdown.parse(source)) == ["{ \"days\": 3 }"], "코드 블록 복사는 울타리 줄 없는 글자만")
    }
}
#endif
