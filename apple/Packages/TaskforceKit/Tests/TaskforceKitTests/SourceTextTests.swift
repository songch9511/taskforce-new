import Foundation
import Testing
@testable import TaskforceKit

struct SourceTextTests {
    let raw = "주간 회의\n\n김대표: 자료는 금요일까지 부탁해요.\n나: 네, 제가 정리해서\n   보내드릴게요.  \n\n끝"

    @Test func splitsLines() {
        let text = SourceText(raw)
        #expect(text.lines.map(\.text) == ["주간 회의", "", "김대표: 자료는 금요일까지 부탁해요.", "나: 네, 제가 정리해서", "   보내드릴게요.  ", "", "끝"])
        #expect(text.lines[1].isBlank)
        #expect(text.lines.map(\.index) == Array(0..<7))
    }

    @Test func handlesCRLFAndTrailingNewline() {
        let text = SourceText("첫 줄\r\n둘째 줄\r\n")
        #expect(text.lines.map(\.text) == ["첫 줄", "둘째 줄", ""])
        #expect(text.quote(lines: 0...1) == "첫 줄\r\n둘째 줄")
        #expect(SourceText("").lines.map(\.text) == [""])
    }

    @Test func quoteIsVerbatimSubstring() throws {
        let text = SourceText(raw)
        let quote = try #require(text.quote(lines: 3...4))
        #expect(quote == "나: 네, 제가 정리해서\n   보내드릴게요.")
        #expect(raw.contains(quote))
    }

    @Test func quoteTrimsBlankEdges() throws {
        let text = SourceText(raw)
        #expect(text.quote(lines: 1...2) == "김대표: 자료는 금요일까지 부탁해요.")
        #expect(text.quote(lines: 5...5) == nil)
        #expect(text.quote(lines: 5...100) == "끝")
        #expect(text.quote(lines: 50...60) == nil)
    }

    @Test func everyRangeQuoteIsInRawText() {
        let text = SourceText(raw)
        for lower in text.lines.indices {
            for upper in lower..<text.lines.count {
                if let quote = text.quote(lines: lower...upper) {
                    #expect(raw.contains(quote), "\(lower)...\(upper)")
                }
            }
        }
    }

    @Test func findsEvidenceLinesIgnoringPunctuationAndSpacing() {
        let text = SourceText(raw)
        #expect(text.lineIndexes(matching: ["자료는 금요일까지 부탁해요"]) == [2])
        // 줄에 걸친 인용
        #expect(text.lineIndexes(matching: ["제가 정리해서 보내드릴게요"]) == [3, 4])
        // "…"로 이은 인용은 조각마다
        #expect(text.lineIndexes(matching: ["주간 회의 … 끝"]) == [0, 6])
        #expect(text.lineIndexes(matching: ["원문에 없는 말"]).isEmpty)
    }

    @Test func normalizeMatchesServer() {
        #expect(SourceText.normalize("Hello, World! 1+1=2 “따옴표” ₩100") == "helloworld112따옴표100")
    }
}

struct LineSelectionTests {
    @Test func tapFlow() {
        var selection = LineSelection()
        selection.tap(4)
        #expect(selection.range == 4...4)
        selection.tap(2)
        #expect(selection.range == 2...4)
        #expect(selection.contains(3))
        // 범위가 있을 때 누르면 새로 시작
        selection.tap(7)
        #expect(selection.range == 7...7)
        // 같은 줄을 다시 누르면 해제
        selection.tap(7)
        #expect(selection.range == nil)
        #expect(!selection.contains(7))
    }

    @Test func clear() {
        var selection = LineSelection(range: 1...3)
        selection.clear()
        #expect(selection.range == nil)
    }
}
