import Foundation
import Testing
@testable import TaskforceKit

/// 열린 질문 → 질문 카드 (OA D4b-m-1, 계약 5장 표 · D4bm-10–17): 종류 · 줄 · 키 · 메타 · 보낼 답. 서버 값을 모양으로 옮길 뿐이다 (앱이 글을 만들지 않는다).
struct AgentQuestionRulesTests {
    typealias F = AgentQuestionFixtures

    private let thisMac = AgentQuestionContext(agentName: "Claude Code", isThisMac: true, macName: nil)
    private let anotherMac = AgentQuestionContext(agentName: "Claude Code", isThisMac: false, macName: "Mina's MacBook Pro")
    private let anotherMacWithoutName = AgentQuestionContext(agentName: "Claude Code", isThisMac: false, macName: nil)

    private func cards(_ json: String, _ context: AgentQuestionContext? = nil) throws -> [AgentQuestionCard] {
        let q = try #require(AgentPendingQuestion(json: Data(json.utf8), taskID: F.taskID))
        return AgentQuestionRules.cards(for: q, context: context ?? thisMac)
    }

    private func card(_ json: String, _ context: AgentQuestionContext? = nil) throws -> AgentQuestionCard {
        try #require(try cards(json, context).first)
    }

    // MARK: 5장 표: 종류

    @Test func theKindFollowsTheFirstMatchingRowOfTheTable() throws {
        #expect(try card(F.single).kind == .single)
        #expect(try card(F.multi).kind == .multi)
        #expect(try card(F.otherThree).kind == .other)
        #expect(try card(F.textOnly).kind == .text)
        #expect(try card(F.approvalEdit).kind == .approval)
        #expect(try card(F.secret).kind == .secret)
        #expect(try card(F.secret, anotherMac).kind == .secretRemote)
    }

    @Test func multiSelectWinsOverAllowOtherAndAnApprovalOrSecretWinsOverBoth() throws {
        let multiOther = F.pending(prompts: [F.prompt(options: [("A", ""), ("B", "")], multi: true, other: true)])
        #expect(try card(multiOther).kind == .multi, "다중 선택이 Other보다 먼저다 (표 순서)")
        let secretWithOptions = F.pending(prompts: [F.prompt(options: [("A", ""), ("B", "")], multi: true, other: true, secret: true)])
        #expect(try card(secretWithOptions).kind == .secret, "비밀값이 다중 선택보다 먼저다")
        #expect(try card(F.pending(prompts: [F.prompt(options: [])])).kind == .text, "선택지 0: 글만")
    }

    // MARK: 줄

    @Test func rowsAreTheOptionsInDataOrderAndOtherComesLast() throws {
        let single = try card(F.single)
        #expect(single.rows.map(\.label) == ["First-month price", "Monthly price", "Yearly total", "Price per month"] && single.rows.allSatisfy { !$0.isOther })
        let other = try card(F.otherThree)
        #expect(other.rows.map(\.label) == ["Pro monthly", "Pro yearly", "Lifetime", "Other"] && other.rows.map(\.isOther) == [false, false, false, true])
        #expect(try card(F.textOnly).rows.isEmpty, "글만 질문은 줄이 없다: 입력 칸 하나")
        #expect(try card(F.multi).rows.map(\.label) == ["Pro monthly", "Pro yearly", "Lifetime"])
    }

    @Test func moreThanFourOptionsAreAllDrawnInDataOrderSoNoAnswerIsHidden() throws {
        let ten = F.pending(prompts: [F.prompt(options: (1...10).map { ("Option \($0)", "") })])
        let c = try card(ten)
        #expect(c.rows.count == 10 && c.rows.first?.label == "Option 1" && c.rows.last?.label == "Option 10", "D4bm-12: 숨기면 답을 못 고른다")
        #expect(!c.showsKeycaps, "다섯 줄 이상은 번호를 그리지 않는다")
        #expect(c.keyedRows == [0, 1, 2, 3], "1–4는 앞 넷 줄")
        let eleventh = try card(F.pending(prompts: [F.prompt(options: (1...10).map { ("Option \($0)", "") }, other: true)]))
        #expect(eleventh.rows.count == 11 && eleventh.rows.last?.isOther == true)
    }

    @Test func keycapsShowOnlyWhenTheQuestionHasExactlyFourRows() throws {
        #expect(try card(F.single).showsKeycaps, "선택지 넷")
        #expect(try card(F.otherThree).showsKeycaps, "선택지 셋 + Other = 넷")
        #expect(try !card(F.singleThree).showsKeycaps)
        #expect(try !card(F.approvalEdit).showsKeycaps, "승인은 두 줄: 번호 없음 (D4bm-12)")
        #expect(try !card(F.multi).showsKeycaps, "다중은 체크 상자")
        let two = F.pending(prompts: [F.prompt(options: [("A", ""), ("B", "")], other: true)])
        #expect(try !card(two).showsKeycaps, "줄 셋")
        let fiveWithOther = F.pending(prompts: [F.prompt(options: (1...4).map { ("Option \($0)", "") }, other: true)])
        #expect(try !card(fiveWithOther).showsKeycaps, "줄 다섯 (넷 + Other): 번호 없음")
    }

    @Test func keysOneToFourReachTheFirstFourRowsWhetherOrNotTheyAreDrawn() throws {
        #expect(try card(F.singleThree).keyedRows == [0, 1, 2], "번호가 안 보여도 키는 동작한다")
        #expect(try card(F.single).keyedRows == [0, 1, 2, 3])
        #expect(try card(F.otherThree).keyedRows == [0, 1, 2, 3], "넷째 키 = Other")
        #expect(try card(F.approvalEdit).keyedRows == [0, 1])
        #expect(try card(F.multi).keyedRows.isEmpty, "다중은 체크 상자: 번호 키가 없다")
        #expect(try card(F.textOnly).keyedRows.isEmpty && card(F.secret).keyedRows.isEmpty)
    }

    @Test func anOptionDescriptionIsKeptAsTheRowHintAndNeverAsAFootnote() throws {
        let c = try card(F.singleWithDescriptions)
        #expect(c.rows.map(\.hint) == ["Drop the Lifetime section for Thursday", nil], "도움말 · 접근성 힌트로만 (D4bm-13)")
    }

    // MARK: 질문 줄 · 메타

    @Test func anInputQuestionShowsItsTextAndTheHeaderAsTheMetaWithNoMadeUpWords() throws {
        let c = try card(F.single)
        #expect(c.title == "Which price should lead the yearly card?" && c.meta == "outside the brief")
        let noHeader = try card(F.textOnly)
        #expect(noHeader.title == "What should the banner say?" && noHeader.meta == nil, "header가 비면 줄이 없다")
        let any = [try card(F.single), try card(F.multi), try card(F.otherThree), try card(F.textOnly), try card(F.approvalEdit)]
        #expect(any.allSatisfy { $0.meta?.contains("Needs your answer") != true }, "메타에 Needs your answer를 쓰지 않는다 (DS 2026-10-16)")
    }

    @Test func severalQuestionsShowOneAtATimeWithPositionBeforeTheHeader() throws {
        let all = try cards(F.several)
        #expect(all.count == 3 && all.map(\.promptID) == ["price", "plans", "banner"])
        #expect(all.map { $0.position?.current } == [1, 2, 3] && all.allSatisfy { $0.position?.total == 3 })
        #expect(all.map(\.meta) == ["1 of 3 · outside the brief", "2 of 3 · Choose any", "3 of 3"])
        #expect(all.map(\.kind) == [.single, .multi, .text], "각 질문은 자기 종류를 가진다")
        #expect(try card(F.single).position == nil, "질문이 하나면 위치가 없다")
    }

    @Test func anApprovalShowsTheHeaderAsTheQuestionTheFirstLineAsThePreviewAndTheReasonInTheMeta() throws {
        let edit = try card(F.approvalEdit)
        #expect(edit.title == "Allow Claude Code to edit this file?" && edit.preview == "Edit · src/content/pricing.mdx")
        #expect(edit.meta == "Claude Code", "에이전트 이름, 사유가 없으면 그것만")
        let run = try card(F.approvalRunWithReason)
        #expect(run.title == "Allow Claude Code to run this command?" && run.preview == "Run · npm run build" && run.meta == "Claude Code · Contains a secret value")
        #expect(run.rows.map(\.label) == ["Allow", "Deny"])
    }

    @Test func anApprovalPreviewIsOnlyTheFirstLineEvenWhenTheCommandHasMore() throws {
        let q = F.pending(prompts: [F.prompt(id: "approval", text: "Run · a ⏎ b\nreason line\nthird line", header: "Allow Claude Code to run this command?", options: [("Allow", ""), ("Deny", "")])], kind: "approval")
        let c = try card(q)
        #expect(c.preview == "Run · a ⏎ b" && c.meta == "Claude Code · reason line", "둘째 줄이 사유다")
    }

    // MARK: 비밀값

    @Test func aSecretQuestionOnThisMacHasAMaskedFieldAndTheStaysOnThisMacMeta() throws {
        let c = try card(F.secret)
        #expect(c.kind == .secret && c.title == "Enter the staging deploy token" && c.meta == "Stays on this Mac" && c.rows.isEmpty)
        let withHeader = try card(F.pending(prompts: [F.prompt(text: "Token?", header: "Deploy", options: [], secret: true)]))
        #expect(withHeader.meta == "Deploy · Stays on this Mac")
    }

    @Test func aSecretQuestionOnAnotherDeviceIsOneDisplayOnlyCardNamingTheMac() throws {
        let c = try cards(F.secret, anotherMac)
        #expect(c.count == 1 && c[0].kind == .secretRemote && c[0].meta == "Can't be entered here" && c[0].macName == "Mina's MacBook Pro")
        // 비밀값이 섞인 여러 질문도 다른 기기에는 카드 하나다 (답 route가 409라 어떤 질문도 여기서 답할 수 없다)
        let mixed = try cards(F.secretMixed, anotherMac)
        #expect(mixed.count == 1 && mixed[0].kind == .secretRemote && mixed[0].title == "Enter the deploy token", "비밀값 질문의 글")
    }

    @Test func aRemoteSecretWithoutAKnownMacNameHasNoNameYet() throws {
        let c = try card(F.secret, anotherMacWithoutName)
        #expect(c.kind == .secretRemote && c.macName == nil, "대체 문구는 화면이 정한다 (승인 전 상수)")
    }

    @Test func aMixedRequestOnThisMacKeepsEachQuestionItsOwnKindAndSendsEverythingLocally() throws {
        let all = try cards(F.secretMixed)
        #expect(all.map(\.kind) == [.single, .secret])
        let q = try #require(AgentPendingQuestion(json: Data(F.secretMixed.utf8), taskID: F.taskID))
        #expect(AgentQuestionRules.deliversLocally(q), "D4bm-43: 비밀값이 아닌 줄의 답도 서버로 가지 않는다")
        let plain = try #require(AgentPendingQuestion(json: Data(F.several.utf8), taskID: F.taskID))
        #expect(!AgentQuestionRules.deliversLocally(plain))
    }

    // MARK: 보낼 답

    @Test func pickingARowAnswersWithItsLabelAndShowsItAsTheChosenAnswer() throws {
        let c = try card(F.single)
        let answer = try #require(AgentQuestionRules.answer(for: c, pick: .row(2)))
        #expect(answer.value == .plain(.text("Yearly total")) && answer.display == "Yearly total")
        #expect(AgentQuestionRules.answer(for: c, pick: .row(4)) == nil && AgentQuestionRules.answer(for: c, pick: .row(-1)) == nil, "없는 줄")
    }

    @Test func anApprovalAnswersAllowOrDenyByRowOrderNotByLabel() throws {
        let c = try card(F.approvalEdit)
        #expect(AgentQuestionRules.answer(for: c, pick: .row(0))?.value == .plain(.text("allow")))
        #expect(AgentQuestionRules.answer(for: c, pick: .row(1))?.value == .plain(.text("deny")))
        #expect(AgentQuestionRules.answer(for: c, pick: .row(0))?.display == "Allow" && AgentQuestionRules.answer(for: c, pick: .row(1))?.display == "Deny")
        #expect(AgentQuestionRules.answer(for: c, pick: .text("allow")) == nil, "승인에는 자유 글이 없다")
    }

    @Test func theOtherRowIsNotAnAnswerByItselfButTypedTextIs() throws {
        let c = try card(F.otherThree)
        #expect(AgentQuestionRules.answer(for: c, pick: .row(3)) == nil, "Other를 고르면 입력 칸이 열릴 뿐이다")
        #expect(AgentQuestionRules.answer(for: c, pick: .row(1))?.value == .plain(.text("Pro yearly")))
        #expect(AgentQuestionRules.answer(for: c, pick: .text("Lifetime, first"))?.value == .plain(.text("Lifetime, first")))
        #expect(AgentQuestionRules.answer(for: try card(F.single), pick: .text("typed")) == nil, "Other가 없는 질문에는 자유 글이 없다")
    }

    @Test func aTextOnlyQuestionAnswersWithTheTypedText() throws {
        let c = try card(F.textOnly)
        #expect(AgentQuestionRules.answer(for: c, pick: .text("Start free"))?.display == "Start free")
        #expect(AgentQuestionRules.answer(for: c, pick: .row(0)) == nil)
    }

    @Test func emptyOrBlankTextIsNotAnAnswer() throws {
        let c = try card(F.textOnly)
        for blank in ["", "   ", "\n\t "] { #expect(AgentQuestionRules.answer(for: c, pick: .text(blank)) == nil, "\(blank.debugDescription)") }
    }

    @Test func typedTextStopsAtTwoThousandUnicodeScalars() throws {
        #expect(AgentQuestionRules.maxTextScalars == 2_000)
        let c = try card(F.textOnly)
        let exact = String(repeating: "가", count: 2_000)
        #expect(AgentQuestionRules.answer(for: c, pick: .text(exact))?.value == .plain(.text(exact)))
        let over = String(repeating: "가", count: 2_001)
        #expect(AgentQuestionRules.answer(for: c, pick: .text(over))?.value == .plain(.text(exact)), "그 뒤 입력은 받지 않는다")
        #expect(AgentQuestionRules.clamped(over).unicodeScalars.count == 2_000)
        // 서버는 유니코드 스칼라로 센다: 결합 글자 · 이모지도 스칼라 단위
        let emoji = String(repeating: "👩🏽‍💻", count: 700)
        #expect(AgentQuestionRules.clamped(emoji).unicodeScalars.count == 2_000)
        #expect(AgentQuestionRules.clamped("short") == "short")
    }

    @Test func multiSelectAnswersTheCheckedLabelsInRowOrderAndNeedsAtLeastOne() throws {
        let c = try card(F.multi)
        let answer = try #require(AgentQuestionRules.answer(for: c, pick: .rows([2, 0])))
        #expect(answer.value == .plain(.choices(["Pro monthly", "Lifetime"])) && answer.display == "Pro monthly, Lifetime")
        #expect(AgentQuestionRules.answer(for: c, pick: .rows([])) == nil, "하나라도 체크되기 전까지 보내지 않는다")
        #expect(AgentQuestionRules.answer(for: c, pick: .rows([7])) == nil, "없는 줄")
        #expect(AgentQuestionRules.answer(for: c, pick: .row(0)) == nil, "다중에 한 줄 고르기는 없다")
    }

    @Test func multiSelectHoldsAtMostTenChoices() throws {
        let ten = F.pending(prompts: [F.prompt(options: (1...10).map { ("Option \($0)", "") }, multi: true)])
        let c = try card(ten)
        #expect(AgentQuestionRules.answer(for: c, pick: .rows(Set(0..<10)))?.value == .plain(.choices((1...10).map { "Option \($0)" })))
    }

    @Test func aSecretAnswerCarriesTheBoxAndShowsNothing() throws {
        let c = try card(F.secret)
        let box = SecretBox("DO_NOT_STORE_SECRET_D4BM")
        let answer = try #require(AgentQuestionRules.answer(for: c, pick: .secret(box)))
        #expect(answer.display == nil, "Answer sent에 값을 보이지 않는다 (D4bm-45)")
        guard case .secret(let held) = answer.value else { Issue.record("secret value expected"); return }
        #expect(held.reveal() == "DO_NOT_STORE_SECRET_D4BM")
        #expect(AgentQuestionRules.answer(for: c, pick: .secret(SecretBox(""))) == nil, "빈 값은 보내지 않는다")
        #expect(AgentQuestionRules.answer(for: c, pick: .text("typed")) == nil)
    }

    @Test func aRemoteSecretCardCanNeverBeAnswered() throws {
        let c = try card(F.secret, anotherMac)
        for pick in [AgentQuestionPick.row(0), .text("x"), .rows([0]), .secret(SecretBox("x"))] {
            #expect(AgentQuestionRules.answer(for: c, pick: pick) == nil)
        }
    }

    // MARK: 요청 본문

    @Test func theServerAnswerMapsEveryQuestionIDToItsValueInOneRequest() throws {
        let q = try #require(AgentPendingQuestion(json: Data(F.several.utf8), taskID: F.taskID))
        let collected: [String: ConversationAnswerValue] = ["price": .text("Yearly total"), "plans": .choices(["Lifetime"]), "banner": .text("Start free")]
        let request = try #require(AgentQuestionRules.request(for: q, collected: collected))
        #expect(request.providerRequestID == F.requestID && request.answers == collected)
        #expect(AgentQuestionRules.request(for: q, collected: ["price": .text("Yearly total")]) == nil, "모든 질문의 답이 모이기 전에는 요청이 없다")
    }

    @Test func aRequestNeverCarriesAnAnswerForAnUnknownQuestionID() throws {
        let q = try #require(AgentPendingQuestion(json: Data(F.single.utf8), taskID: F.taskID))
        #expect(AgentQuestionRules.request(for: q, collected: ["q1": .text("A"), "zzz": .text("B")]) == nil)
    }
}
