#if os(macOS)
import Foundation
import Testing
@testable import TaskforceKit

/// OA D4b-m-2 (계약 16.5, D4bm-14 인계 · D4bm2-06): 승인 카드 글을 DS 모양으로. 바뀌는 것은 질문 줄(머리)과 앞붙이뿐이다:
/// Edit "Allow Claude Code to edit this file?" + `Edit · 경로` · Write "Allow Claude Code to write this file?"(사용자 승인) + `Write · 경로` · 그 밖 "Allow Claude Code to run this command?" + `Run · 명령`.
/// 보이게 바꾸기 · 300 스칼라 · 가리기 · 사유 줄은 그대로다 (앞붙이는 가리기 · 보이기 **뒤에** 붙는다)
struct ClaudeApprovalCopyTests {
    private static let tools: [(tool: String, header: String, prefix: String, path: Bool)] = [
        ("Edit", "Allow Claude Code to edit this file?", "Edit · ", true),
        ("Write", "Allow Claude Code to write this file?", "Write · ", true),
        ("Bash", "Allow Claude Code to run this command?", "Run · ", false),
        ("Anything", "Allow Claude Code to run this command?", "Run · ", false),
    ]

    private func card(_ tool: String, _ value: String, reason: String? = nil) -> AgentQuestion {
        let isFile = tool == "Edit" || tool == "Write"
        return ClaudeToolGate.approvalQuestion(id: "toolu_a", tool: tool, relPath: isFile ? value : nil, command: isFile ? nil : value, reason: reason)
    }

    @Test func eachToolHasItsOwnQuestionLineAndPreviewPrefixWithAndWithoutAReason() {
        for item in Self.tools {
            let plain = card(item.tool, "src/a.txt")
            #expect(plain.kind == .approval && plain.structured)
            #expect(plain.items.count == 1 && plain.items[0].id == "approval" && plain.items[0].header == item.header, "\(item.tool): 질문 줄")
            #expect(plain.text == item.prefix + "src/a.txt" && plain.items[0].text == plain.text, "\(item.tool): 글 = 미리보기 한 줄")
            #expect(plain.items[0].options.map(\.label) == ["Allow", "Deny"])
            let withReason = card(item.tool, "src/a.txt", reason: ClaudeCardReason.hardLink)
            #expect(withReason.text == item.prefix + "src/a.txt\n" + ClaudeCardReason.hardLink, "\(item.tool): 사유는 둘째 줄")
            #expect(withReason.items[0].header == item.header)
        }
    }

    @Test func theConstantsAreTheApprovedWords() {
        #expect(ClaudeApprovalCopy.editHeader == "Allow Claude Code to edit this file?")
        #expect(ClaudeApprovalCopy.writeHeader == "Allow Claude Code to write this file?")
        #expect(ClaudeApprovalCopy.runHeader == "Allow Claude Code to run this command?")
        #expect([ClaudeApprovalCopy.editPrefix, ClaudeApprovalCopy.writePrefix, ClaudeApprovalCopy.runPrefix] == ["Edit · ", "Write · ", "Run · "])
    }

    @Test func theThreeReasonLinesStayAsApproved() {
        #expect(ClaudeCardReason.hardLink == "File has other links")
        #expect(ClaudeCardReason.unknownInput == "Unrecognized tool options")
        #expect(ClaudeCardReason.secretInCommand == "Contains a secret value")
    }

    @Test func theHeaderIsShortAndTheWholeCardNeverReachesTheOutboxCut() {
        for item in Self.tools {
            let worst = card(item.tool, String(repeating: "\u{0301}", count: 5000) + String(repeating: "あ", count: 5000), reason: ClaudeCardReason.secretInCommand)
            #expect(worst.items[0].header.unicodeScalars.count <= 40 && worst.items[0].header.utf8.count <= 200, "\(item.tool): 머리 ≤ 200")
            let visibleBudget = item.prefix.unicodeScalars.count + 300 + 1 + ClaudeCardReason.secretInCommand.unicodeScalars.count
            #expect(worst.text.unicodeScalars.count <= visibleBudget + 10, "\(item.tool): 카드 전체 \(worst.text.unicodeScalars.count)")
            guard case .fits(let sent, let map) = Outbox.fit(question: worst, taskID: "00000000-0000-0000-0000-000000000000", observedAt: Date()) else {
                Issue.record("\(item.tool): 카드가 질문 모양에 담기지 않는다")
                continue
            }
            #expect(map.isEmpty && sent.questions[0].text == worst.text && sent.questions[0].header == item.header, "\(item.tool): 4,000 자르기에 닿지 않는다")
        }
    }

    @Test func theThreeHundredScalarBoundaryAndTheHiddenCountAreUnchanged() {
        let exact = String(repeating: "b", count: 300)
        #expect(card("Bash", exact).text == "Run · " + exact, "300은 그대로")
        let over = String(repeating: "a", count: 350)
        #expect(card("Bash", over).text == "Run · " + String(repeating: "a", count: 212) + "…(+58)…" + String(repeating: "a", count: 80))
        let path = String(repeating: "p", count: 301)
        #expect(card("Edit", path).text == "Edit · " + String(repeating: "p", count: 212) + "…(+9)…" + String(repeating: "p", count: 80), "경로도 같은 상한")
    }

    @Test func theVisibleFormsAreStillAppliedBeforeThePrefixIsAttached() {
        #expect(card("Bash", "a\nb\tc").text == "Run · a⏎b⇥c")
        #expect(card("Bash", "e" + String(repeating: "\u{0301}", count: 3) + "x").text == "Run · e" + #"\u{0301}"# + "×3x", "결합 표시 ×N")
        #expect(card("Bash", "ls\u{3000}a").text == "Run · ls␠a", "빈칸 표기")
        #expect(card("Bash", "ls \u{115F}\u{3164}\u{2800} x").text == "Run · ls␠×5x")
        // 앞붙이의 공백이 명령 앞의 빈칸과 한 덩어리가 되지 않는다: 앞붙이는 보이기 **뒤에** 붙는다
        #expect(card("Bash", "\u{3000}\u{3000}ls").text == "Run · ␠×2ls")
        #expect(card("Write", "a⏎b\u{202E}.txt").text == #"Write · a⏎b\u{202E}.txt"#)
    }

    @Test func aMaskedCommandStaysMaskedInTheNewCard() {
        let masked = ClaudeToolGate.approvalQuestion(id: "t", tool: "Bash", relPath: nil, command: "cat [redacted]", reason: ClaudeCardReason.secretInCommand)
        #expect(masked.text == "Run · cat [redacted]\n" + ClaudeCardReason.secretInCommand)
        #expect(masked.items[0].header == "Allow Claude Code to run this command?")
    }
}
#endif
