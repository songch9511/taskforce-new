import Foundation
import Testing
@testable import TaskforceKit

struct LauncherTests {
    let now = try! TaskforceJSON.decoder().decode(NowResponse.self, from: Data(Fixtures.nowWithWeeklyCheck.utf8))

    // MARK: 입력 모드

    @Test func emptyAndWhitespaceIsEmpty() {
        #expect(LauncherInput.mode(for: "") == .empty)
        #expect(LauncherInput.mode(for: "   \n  ") == .empty)
    }

    @Test func shortTextIsQueryTrimmed() {
        #expect(LauncherInput.mode(for: "  투자 자료 ") == .query("투자 자료"))
    }

    @Test func multiLineIsPasteEvenWhenShort() {
        #expect(LauncherInput.mode(for: "김대표: 금요일까지\n나: 네") == .paste("김대표: 금요일까지\n나: 네"))
        #expect(LauncherInput.mode(for: "a\r\nb") == .paste("a\r\nb"))
    }

    @Test func longSingleLineIsPaste() {
        let exactly = String(repeating: "가", count: LauncherInput.longTextThreshold)
        #expect(LauncherInput.mode(for: exactly) == .query(exactly))
        let longer = exactly + "나"
        #expect(LauncherInput.mode(for: longer) == .paste(longer))
    }

    // MARK: 구역

    @Test func emptyShowsReviewNowCommandsInServerOrder() {
        let sections = LauncherContent.sections(for: .empty, now: now, signedIn: true)
        #expect(sections.map(\.title) == ["Review", "Now", "Commands"])
        #expect(sections[0].items.map(\.id) == ["review-44444444-4444-4444-8444-444444444444"])
        // 서버가 준 순서 그대로
        #expect(sections[1].items.compactMap(\.action?.title) == ["투자 자료 보내기", "계약서 검토"])
        #expect(sections[2].items == LauncherCommand.allCases.map(LauncherItem.command))
    }

    @Test func emptySectionsAreDropped() {
        let sections = LauncherContent.sections(for: .empty, now: nil, signedIn: true)
        #expect(sections.map(\.title) == ["Commands"])
    }

    @Test func queryFiltersTasksThenAskThenHandoffTopMatch() {
        let sections = LauncherContent.sections(for: .query("자료"), now: now, signedIn: true)
        #expect(sections.map(\.title) == ["Now", nil])
        #expect(sections[0].items.compactMap(\.action?.title) == ["투자 자료 보내기"])
        guard case .ask("자료") = sections[1].items[0] else {
            Issue.record("Ask가 있어야 함")
            return
        }
        #expect(sections[1].items[1] == .handoff(now.now[0].action))
    }

    @Test func queryWithoutMatchOffersAddThenAsk() {
        let sections = LauncherContent.sections(for: .query("없는말"), now: now, signedIn: true)
        #expect(sections.flatMap(\.items) == [.addAction("없는말"), .ask("없는말")])
    }

    // MARK: 직접 추가

    func addTitle(_ text: String, now: NowResponse? = nil, signedIn: Bool = true) -> String? {
        LauncherAdd.title(for: LauncherInput.mode(for: text), now: now ?? self.now, signedIn: signedIn)
    }

    @Test func addUsesTrimmedQueryWhenNothingMatches() {
        #expect(addTitle("  Send deck to Mina  ") == "Send deck to Mina")
    }

    @Test func addHidesWhenReviewOrNowMatches() {
        #expect(addTitle("자료") == nil)
        #expect(addTitle("김대표") == nil)
        #expect(addTitle("견적서") == nil)
        #expect(LauncherContent.sections(for: .query("자료"), now: now, signedIn: true).flatMap(\.items).allSatisfy {
            if case .addAction = $0 { return false }
            return true
        })
    }

    @Test func addHidesForEmptyPasteSignedOutOrUnloadedList() {
        #expect(addTitle("") == nil)
        #expect(addTitle("   ") == nil)
        #expect(addTitle("Send deck\nto Mina") == nil)
        #expect(addTitle(String(repeating: "a", count: LauncherInput.longTextThreshold + 1)) == nil)
        #expect(addTitle("Send deck to Mina", signedIn: false) == nil)
        #expect(LauncherAdd.title(for: .query("Send deck to Mina"), now: nil, signedIn: true) == nil)
        #expect(LauncherContent.sections(for: .query("Send deck"), now: now, signedIn: false).flatMap(\.items) == [
            .signIn, .signInWithEmail, .command(.quit),
        ])
    }

    @Test func addTitleIsCappedAt200UTF16WithoutSplittingCharacters() {
        let exactly = String(repeating: "a", count: LauncherAdd.maxTitleLength)
        #expect(addTitle(exactly) == exactly)
        #expect(LauncherAdd.capped(exactly + "b") == exactly)
        // 이모지는 UTF-16 두 칸: 반으로 자르지 않는다
        let emoji = LauncherAdd.capped("a" + String(repeating: "😀", count: 150))
        #expect(emoji == "a" + String(repeating: "😀", count: 99))
        #expect(LauncherAdd.capped(String(repeating: "a", count: 199) + " b") == String(repeating: "a", count: 199))
    }

    @Test func queryMatchesCounterpartAndCommands() {
        let byCounterpart = LauncherContent.sections(for: .query("김대표"), now: now, signedIn: true)
        #expect(byCounterpart.first?.items.compactMap(\.action?.title) == ["투자 자료 보내기"])
        let command = LauncherContent.sections(for: .query("conn"), now: now, signedIn: true)
        #expect(command.last?.items == [.command(.connections)])
    }

    @Test func reviewMatchBecomesHandoffWhenNoTaskMatches() {
        let sections = LauncherContent.sections(for: .query("견적서"), now: now, signedIn: true)
        #expect(sections.map(\.title) == ["Review", nil])
        #expect(sections[1].items.last == .handoff(now.confirmations[0]))
    }

    @Test func pasteOffersSendAsSourceFirst() {
        let text = "회의록\n김대표: 금요일까지"
        let sections = LauncherContent.sections(for: .paste(text), now: now, signedIn: true)
        #expect(sections.flatMap(\.items) == [.sendAsSource(text), .ask(text)])
    }

    @Test func pasteTooLongToAskOffersOnlySend() {
        let text = String(repeating: "가", count: LauncherContent.askMaxLength + 1)
        #expect(LauncherContent.sections(for: .paste(text), now: now, signedIn: true).flatMap(\.items) == [.sendAsSource(text)])
        let fits = String(repeating: "가", count: LauncherContent.askMaxLength)
        #expect(LauncherContent.sections(for: .paste(fits), now: now, signedIn: true).flatMap(\.items) == [.sendAsSource(fits), .ask(fits)])
    }

    @Test func signedOutShowsSignInOnly() {
        let sections = LauncherContent.sections(for: .query("자료"), now: now, signedIn: false)
        #expect(sections.flatMap(\.items) == [.signIn, .signInWithEmail, .command(.quit)])
    }

    @Test func missingConsentAddsAllowRowOnTopWithoutHidingTheList() {
        let sections = LauncherContent.sections(for: .empty, now: now, signedIn: true, needsConsent: true)
        #expect(sections.first?.items == [.allowAI])
        #expect(sections.map(\.title) == [nil, "Review", "Now", "Commands"])
        // 찾는 중에는 끼어들지 않는다
        #expect(!LauncherContent.sections(for: .query("자료"), now: now, signedIn: true, needsConsent: true).flatMap(\.items).contains(.allowAI))
    }

    @Test func selectionStopsAtEnds() {
        #expect(LauncherContent.move(0, by: -1, count: 3) == 0)
        #expect(LauncherContent.move(1, by: 1, count: 3) == 2)
        #expect(LauncherContent.move(2, by: 1, count: 3) == 2)
        #expect(LauncherContent.move(5, by: 0, count: 3) == 2)
        #expect(LauncherContent.move(0, by: 1, count: 0) == 0)
    }

    // MARK: 기한 고르기

    let today = LocalDate(year: 2026, month: 9, day: 28)!

    @Test func dueChoicesPutNoDueFirstWhenAdding() {
        let week = (0...6).map { LauncherDue.Choice.date(today.adding(days: $0)) }
        #expect(LauncherDue.choices(today: today, adding: true) == [.clear] + week)
        #expect(LauncherDue.choices(today: today, adding: false) == week + [.clear])
    }

    @Test func otherDateStaysAsItsOwnRowInDateOrder() {
        let later = today.adding(days: 20)
        let choices = LauncherDue.choices(today: today, adding: true, keeping: later)
        #expect(choices.count == 9)
        #expect(choices.last == .date(later))
        #expect(LauncherDue.index(of: later, in: choices) == 8)

        let past = today.adding(days: -3)
        let withPast = LauncherDue.choices(today: today, adding: true, keeping: past)
        #expect(withPast[0] == .clear)
        #expect(withPast[1] == .date(past))
        #expect(LauncherDue.index(of: past, in: withPast) == 1)
    }

    @Test func presetDueIsNotDuplicated() {
        let friday = today.adding(days: 4)
        let choices = LauncherDue.choices(today: today, adding: true, keeping: friday)
        #expect(choices == LauncherDue.choices(today: today, adding: true))
        #expect(LauncherDue.index(of: friday, in: choices) == 5)
        #expect(LauncherDue.index(of: nil, in: choices) == 0)
        // 목록에 없는 기한이면 맨 위
        #expect(LauncherDue.index(of: today.adding(days: 30), in: choices) == 0)
    }

    // MARK: 거르기

    @Test func filterNeedsEveryWordAndIgnoresCase() {
        #expect(TaskFilter.matches(text: "Send the Proposal to Alex", query: "proposal alex"))
        #expect(!TaskFilter.matches(text: "Send the Proposal to Alex", query: "proposal bob"))
        #expect(TaskFilter.matches(text: "Café deck", query: "cafe"))
        #expect(TaskFilter.matches(text: "ＩＲ 자료", query: "ir"))
        #expect(TaskFilter.matches(text: "anything", query: "  "))
    }

    // MARK: 붙여 넣은 원문

    @Test func pastedMultiLineIsNoteTitledByFirstLine() throws {
        let request = try #require(PastedSource.request(for: "\n  주간 회의  \n김대표: 금요일까지\n"))
        #expect(request.kind == .note)
        #expect(request.title == "주간 회의")
        #expect(request.text == "주간 회의  \n김대표: 금요일까지")
    }

    @Test func pastedSingleLineIsMessage() throws {
        let request = try #require(PastedSource.request(for: "금요일까지 자료 보내 주세요"))
        #expect(request.kind == .message)
        #expect(request.title == "금요일까지 자료 보내 주세요")
    }

    @Test func pastedTitleIsCappedAndEmptyOrHugeIsRejected() throws {
        let long = String(repeating: "a", count: 300)
        #expect(try #require(PastedSource.request(for: long)).title?.count == PastedSource.maxTitleLength)
        #expect(PastedSource.request(for: "  \n ") == nil)
        #expect(PastedSource.request(for: String(repeating: "a", count: CreateSourceRequest.maxTextLength + 1)) == nil)
    }

    // MARK: app_opened 30분

    /// 차례로 부르고 보낸 결과
    func sends(_ offsets: [TimeInterval]) -> [Bool] {
        var throttle = LauncherOpenThrottle()
        let start = Date(timeIntervalSince1970: 1_000_000)
        return offsets.map { throttle.shouldSend(at: start.addingTimeInterval($0)) }
    }

    @Test func launcherOpenIsThrottledTo30Minutes() {
        #expect(sends([0, 60, 29 * 60, 30 * 60, 31 * 60]) == [true, false, false, true, false])
    }

    @Test func clockGoingBackSendsAgain() {
        #expect(sends([0, -3600]) == [true, true])
    }
}
