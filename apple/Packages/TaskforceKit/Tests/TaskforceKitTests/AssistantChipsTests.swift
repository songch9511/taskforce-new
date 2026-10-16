import Foundation
import Testing
@testable import TaskforceKit

/// 맥락 칩 (OA U1): auto는 연 항목을 따라다니고 보낸 뒤 added가 된다 · 에이전트로는 auto를 보내지 않는다 · 20개 · 제거는 이 대화에서 유지.
/// 자리표시 글 규칙도 여기서 고정한다 (칩이 하나면 그 이름, 여럿이면 these, 에이전트는 Message …)
struct AssistantChipsTests {
    func item(_ n: Int, _ title: String = "Rewrite pricing page copy", number: Int? = nil) -> AssistantChip {
        AssistantChip(kind: .action, itemID: UUID(uuidString: String(format: "c1000000-0000-4000-8000-%012d", n))!, origin: .auto, title: title, number: number)
    }

    // MARK: auto는 연 항목을 따라간다

    @Test func theAutoChipFollowsTheOpenItemUntilAMessageIsSent() {
        var chips = AssistantChipSet()
        chips.follow(item(1, "Pricing"))
        #expect(chips.chips.map(\.title) == ["Pricing"] && chips.chips[0].origin == .auto)
        chips.follow(item(2, "Onboarding"))
        #expect(chips.chips.map(\.title) == ["Onboarding"], "보내기 전에는 다른 항목을 열면 그 항목으로 옮겨 간다")
        chips.follow(nil)
        #expect(chips.chips.map(\.title) == ["Onboarding"], "열린 항목이 없어졌다고 칩이 사라지지 않는다 (패널을 접어도 그대로)")
    }

    @Test func followingTheSameItemTwiceChangesNothing() {
        var chips = AssistantChipSet()
        chips.follow(item(1))
        let before = chips
        chips.follow(item(1))
        #expect(chips == before)
    }

    @Test func aSentAutoChipBecomesAddedAndStopsFollowing() {
        var chips = AssistantChipSet()
        chips.follow(item(1, "Pricing"))
        chips.didSend(toAgent: false)
        #expect(chips.chips.map(\.origin) == [.added], "보낸 뒤에는 added로 남는다")
        chips.follow(item(2, "Onboarding"))
        #expect(chips.chips.map(\.title) == ["Pricing", "Onboarding"], "added 칩은 따라가지 않는다: 새 항목은 새 auto 칩")
        #expect(chips.chips.map(\.origin) == [.added, .auto])
    }

    @Test func followingAnItemThatIsAlreadyAChipAddsNothing() {
        var chips = AssistantChipSet()
        chips.follow(item(1, "Pricing"))
        chips.didSend(toAgent: false)
        chips.follow(item(1, "Pricing"))
        #expect(chips.chips.count == 1 && chips.chips[0].origin == .added, "이미 칩인 항목은 다시 auto로 생기지 않는다")
    }

    // MARK: 제거 · 에이전트 대상

    @Test func aRemovedAutoChipStaysRemovedForThisConversation() {
        var chips = AssistantChipSet()
        let first = item(1, "Pricing")
        chips.follow(first)
        chips.remove(first.id)
        #expect(chips.chips.isEmpty)
        chips.follow(first)
        #expect(chips.chips.isEmpty, "제거는 이 대화에서 유지된다: 같은 항목이 다시 auto로 돌아오지 않는다")
        chips.follow(item(2, "Onboarding"))
        #expect(chips.chips.map(\.title) == ["Onboarding"], "다른 항목은 따라간다")
    }

    @Test func anAgentTargetDoesNotSendAutoChipsAndKeepsThemDashed() {
        var chips = AssistantChipSet()
        chips.follow(item(1, "Pricing"))
        chips.add(item(2, "Onboarding"))
        chips.didSend(toAgent: true)
        #expect(chips.chips.map(\.origin) == [.auto, .added], "에이전트로 안 간 auto 칩은 auto 그대로")
        #expect(chips.label(for: chips.chips[0], toAgent: true) == "Pricing · Not sent")
        #expect(chips.label(for: chips.chips[1], toAgent: true) == "Onboarding", "added 칩은 접미사가 없다")
        #expect(chips.label(for: chips.chips[0], toAgent: false) == "Pricing", "Taskforce 대상은 접미사가 없다")
    }

    @Test func chipsSendInOrderWithTheirOrigin() {
        var chips = AssistantChipSet()
        chips.follow(item(1, "Pricing"))
        chips.add(AssistantChip(kind: .context, itemID: UUID(uuidString: "a7777777-7777-4777-8777-777777777777")!, origin: .added, title: "Shape launch"))
        let sent = chips.attachments
        #expect(sent.map(\.origin) == [.auto, .added])
        #expect(sent.map(\.kind) == [.action, .context])
        #expect(sent.count == chips.chips.count)
    }

    // MARK: 20개 · 이름

    @Test func atMostTwentyChips() {
        var chips = AssistantChipSet()
        for n in 1...20 {
            let accepted = chips.add(item(n, "Item \(n)").asAdded)
            #expect(accepted)
        }
        #expect(chips.chips.count == 20 && chips.isFull)
        let twentyFirst = chips.add(item(21).asAdded)
        #expect(!twentyFirst, "스물한째는 받지 않는다")
        #expect(chips.chips.count == 20)
        chips.follow(item(22, "Over"))
        #expect(chips.chips.count == 20 && !chips.chips.contains { $0.title == "Over" }, "auto 칩도 20을 넘지 않는다")
        #expect(ChatAttachment.maxPerMessage == AssistantChipSet.capacity, "서버 한도와 같다")
    }

    @Test func aChipLeadsWithTheIssueNumberWhenThereIsOne() {
        #expect(item(1, "Rewrite pricing page copy", number: 139).label == "#139 Rewrite pricing page copy")
        #expect(item(1, "Rewrite pricing page copy").label == "Rewrite pricing page copy")
    }

    @Test func chipIDsNameTheKindAndTheItem() {
        let a = item(1)
        let sameItemOtherKind = AssistantChip(kind: .context, itemID: a.itemID, origin: .added, title: "x")
        #expect(a.id != sameItemOtherKind.id, "종류가 다르면 다른 칩")
        #expect(a.id == item(1).id)
    }

    // MARK: 자리표시

    @Test func placeholderNamesWhatIsAttached() {
        let one = [item(1, "Rewrite pricing page copy", number: 139)]
        let two = [item(1), item(2)]
        #expect(AssistantPromptRules.placeholder(chips: [], target: .taskforce, targetName: "Taskforce", blocked: nil) == "Ask Taskforce")
        #expect(AssistantPromptRules.placeholder(chips: one, target: .taskforce, targetName: "Taskforce", blocked: nil) == "Ask about #139", "이슈는 번호가 이름이다 (DS)")
        #expect(AssistantPromptRules.placeholder(chips: [item(1, "Pricing")], target: .taskforce, targetName: "Taskforce", blocked: nil) == "Ask about Pricing")
        #expect(AssistantPromptRules.placeholder(chips: two, target: .taskforce, targetName: "Taskforce", blocked: nil) == "Ask about these")
    }

    @Test func anAgentTargetSaysMessageAndTheAgentName() {
        let claude = AssistantTargetPick.agent(adapter: "agent:claude-code", connectionID: nil)
        let codex = AssistantTargetPick.agent(adapter: "agent:codex", connectionID: nil)
        #expect(AssistantPromptRules.placeholder(chips: [], target: claude, targetName: "Claude Code", blocked: nil) == "Message Claude Code")
        #expect(AssistantPromptRules.placeholder(chips: [], target: codex, targetName: "Codex", blocked: nil) == "Message Codex")
        // 칩이 있어도 에이전트 대상은 "Message …" (auto 칩은 보내지 않으니 "about"이라 하지 않는다)
        #expect(AssistantPromptRules.placeholder(chips: [item(1), item(2)], target: codex, targetName: "Codex", blocked: nil) == "Message Codex")
    }

    @Test func aBlockedPromptSaysWhyAndANamedReasonReplacesIt() {
        #expect(AssistantPromptRules.placeholder(chips: [item(1)], target: .taskforce, targetName: "Taskforce", blocked: "") == "Answer the question above first")
        #expect(AssistantPromptRules.placeholder(chips: [], target: .taskforce, targetName: "Taskforce", blocked: "Waiting for the Mac") == "Waiting for the Mac")
        #expect(AssistantPromptRules.blockedDefault == "Answer the question above first")
    }

    @Test func aNewChatWithoutANameIsCalledNewChat() {
        #expect(AssistantPromptRules.untitled == "New chat")
    }
}

private extension AssistantChip {
    var asAdded: AssistantChip {
        AssistantChip(kind: kind, itemID: itemID, origin: .added, title: title, number: number)
    }
}

/// 에이전트 대상의 auto 칩 누르기 (OA D4a-12, 계약 v3 2.3): 사용자가 누르면 added가 된다. " · Not sent" 꼬리가 없어지고 보낼 칩이 된다
struct AssistantChipPromoteTests {
    func item(_ n: Int, _ title: String = "Rewrite pricing page copy", number: Int? = 139) -> AssistantChip {
        AssistantChip(kind: .action, itemID: UUID(uuidString: String(format: "c1000000-0000-4000-8000-%012d", n))!, origin: .auto, title: title, number: number)
    }

    @Test func pressingAnAutoChipMakesItAddedAndTheTailGoesAway() {
        var chips = AssistantChipSet()
        chips.follow(item(1))
        let id = chips.chips[0].id
        #expect(chips.label(for: chips.chips[0], toAgent: true) == "#139 Rewrite pricing page copy · Not sent")
        let promoted = chips.promote(id)
        #expect(promoted)
        #expect(chips.chips[0].origin == .added)
        #expect(chips.label(for: chips.chips[0], toAgent: true) == "#139 Rewrite pricing page copy", "꼬리 · Not sent가 없어진다")
        #expect(chips.attachments.map(\.origin) == [.added], "보낼 때 added로 간다")
    }

    @Test func pressingAnAddedChipOrAnUnknownChipChangesNothing() {
        var chips = AssistantChipSet()
        chips.add(item(1))
        let before = chips
        let again = chips.promote(chips.chips[0].id)
        let unknown = chips.promote("action:00000000-0000-4000-8000-000000000000")
        #expect(!again && !unknown, "이미 added인 칩 · 없는 칩")
        #expect(chips == before)
    }

    /// 눌러서 added가 된 칩은 더는 따라다니지 않는다: 다른 항목을 열면 새 auto 칩이 생긴다 (칩 수가 가득 차지 않았을 때)
    @Test func aPromotedChipStopsFollowingAndANewAutoChipTakesItsPlace() {
        var chips = AssistantChipSet()
        chips.follow(item(1, "Pricing"))
        chips.promote(chips.chips[0].id)
        chips.follow(item(2, "Onboarding"))
        #expect(chips.chips.map(\.title) == ["Pricing", "Onboarding"] && chips.chips.map(\.origin) == [.added, .auto])
    }

    @Test func aRemovedChipThatWasPromotedMayComeBackAsAutoOnlyIfNeverDismissedAsAuto() {
        var chips = AssistantChipSet()
        chips.follow(item(1, "Pricing"))
        let id = chips.chips[0].id
        chips.promote(id)
        chips.remove(id)
        chips.follow(item(1, "Pricing"))
        #expect(chips.chips.map(\.origin) == [.auto], "added를 ×로 뺀 항목은 다시 열면 auto로 따라올 수 있다 (auto를 뺀 것만 기억한다)")
    }
}
