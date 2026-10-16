import Foundation
import Testing
@testable import TaskforceKit

/// 비밀값 상자는 어떤 길로도 값을 말하지 않는다 (OA D4b-m-1, 계약 7장 · D4bm-45): 글로 찍기 · 디버그 글 · 덤프 · 거울(Mirror) · 문자열 끼워 넣기.
/// 값을 꺼내는 곳은 `reveal()` 하나뿐이다. 저장소 상태 덤프 시험(`AgentQuestionSecretTests.dumped`)은 상자를 담은 값을 보지 못하므로, 상자 자체를 여기서 직접 막는다.
struct AgentQuestionRedactionTests {
    static let canary = "DO_NOT_PRINT_SECRET_D4BM"

    /// 값이 나올 수 있는 모든 글
    private func everyText(of subject: Any) -> [String] {
        var dumped = ""
        dump(subject, to: &dumped)
        var debugPrinted = ""
        debugPrint(subject, to: &debugPrinted)
        var printed = ""
        print(subject, to: &printed)
        return [String(describing: subject), String(reflecting: subject), "\(subject)", dumped, debugPrinted, printed]
    }

    @Test func aSecretBoxNeverPrintsItsValueByAnyRoute() {
        let box = SecretBox(Self.canary)
        for text in everyText(of: box) { #expect(!text.contains(Self.canary), "상자가 값을 말했다: \(text.count)자") }
        #expect(String(describing: box) == "<secret>" && String(reflecting: box) == "<secret>")
    }

    @Test func aSecretBoxIsEmptyToAMirrorAndOnlyRevealGivesTheValueBack() {
        let box = SecretBox(Self.canary)
        #expect(Mirror(reflecting: box).children.isEmpty, "거울에 값이 비친다면 덤프 · 디버거가 값을 보인다")
        #expect(box.reveal() == Self.canary && !box.isEmpty && SecretBox("").isEmpty)
    }

    @Test func aLocalAnswerAndEverythingAroundItNeverPrintsTheSecret() {
        let answer = LocalSecretAnswer(key: AgentQuestionFixtures.key(), answers: ["env": .plain(.text("Staging")), "token": .secret(SecretBox(Self.canary))])
        for text in everyText(of: answer) { #expect(!text.contains(Self.canary)) }
        #expect(Mirror(reflecting: answer).children.isEmpty)
        #expect(answer.revealed()["token"] == .text(Self.canary), "보내는 순간에만 펼쳐진다")
        let outcome = LocalSecretOutcome.failed(.generic)
        for text in everyText(of: outcome) { #expect(!text.contains(Self.canary)) }
    }
}
