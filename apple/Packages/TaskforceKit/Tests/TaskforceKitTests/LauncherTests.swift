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

    @Test func emptyShowsReviewInProgressToDoCommands() {
        let sections = LauncherContent.sections(for: .empty, now: now, signedIn: true)
        #expect(sections.map(\.title) == ["Review", "In Progress", "To Do", "Commands"])
        #expect(sections[0].items.map(\.id) == ["review-44444444-4444-4444-8444-444444444444"])
        // 착수한 것은 In Progress, 나머지는 To Do
        #expect(sections[1].items.compactMap(\.action?.title) == ["투자 자료 보내기"])
        #expect(sections[2].items.compactMap(\.action?.title) == ["계약서 검토"])
        #expect(sections[3].items == LauncherCommand.allCases.map(LauncherItem.command))
        #expect(sections.flatMap(\.items).compactMap(\.group) == [.review, .inProgress, .toDo])
    }

    @Test func emptySectionsAreDropped() {
        let sections = LauncherContent.sections(for: .empty, now: nil, signedIn: true)
        #expect(sections.map(\.title) == ["Commands"])
    }

    @Test func queryFiltersTasksThenAskThenHandoffTopMatch() {
        let sections = LauncherContent.sections(for: .query("자료"), now: now, signedIn: true)
        #expect(sections.map(\.title) == ["In Progress", nil])
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
            .command(.quit),
        ])
    }

    @Test func existingListsReviewThenNowMatchesInServerOrder() {
        #expect(LauncherAdd.existing(matching: "서", in: now).map(\.title) == ["견적서 회신", "계약서 검토"])
        #expect(LauncherAdd.existing(matching: " 자료 ", in: now).map(\.title) == ["투자 자료 보내기"])
        // 상대 이름도 맞는 것으로 본다 (런처 찾기와 같다)
        #expect(LauncherAdd.existing(matching: "김대표", in: now).map(\.title) == ["투자 자료 보내기"])
    }

    @Test func existingIsEmptyForBlankUnmatchedOrUnloaded() {
        #expect(LauncherAdd.existing(matching: "", in: now).isEmpty)
        #expect(LauncherAdd.existing(matching: "  \n", in: now).isEmpty)
        #expect(LauncherAdd.existing(matching: "없는말", in: now).isEmpty)
        #expect(LauncherAdd.existing(matching: "자료", in: nil).isEmpty)
    }

    @Test func existingListsAnActionOnce() {
        let review = now.confirmations[0]
        let both = NowResponse(
            now: [RankedAction(action: review, score: 1, reasons: [], daysUntilDue: nil)], confirmations: [review], weeklyCheck: nil
        )
        #expect(LauncherAdd.existing(matching: review.title, in: both) == [review])
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
        #expect(sections.flatMap(\.items) == [.command(.quit)])
    }

    /// Google 클라이언트 설정이 있으면 Google이 먼저, Apple 계정은 계속 쓸 수 있고 이메일은 맨 아래
    @Test func signedOutShowsGoogleFirstWhenConfigured() {
        let sections = LauncherContent.sections(for: .empty, now: nil, signedIn: false, googleSignIn: true)
        #expect(sections.flatMap(\.items) == [.signInWithGoogle, .command(.quit)])
        #expect(LauncherContent.sections(for: .empty, now: now, signedIn: true, googleSignIn: true).flatMap(\.items).contains(.signInWithGoogle) == false)
    }

    @Test func missingConsentAddsAllowRowOnTopWithoutHidingTheList() {
        let sections = LauncherContent.sections(for: .empty, now: now, signedIn: true, needsConsent: true)
        #expect(sections.first?.items == [.allowAI])
        #expect(sections.map(\.title) == [nil, "Review", "In Progress", "To Do", "Commands"])
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

    // MARK: ⌘⌫

    @Test func deleteKeyRepeatIsIgnored() {
        let guardian = LauncherDeleteGuard()
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(guardian.allows(isRepeat: false, at: now))
        #expect(!guardian.allows(isRepeat: true, at: now))
    }

    /// 안내를 ⌘⌫로 닫은 직후 한 번 더 누른 ⌘⌫는 다음 줄(Review · 할 일)에 닿지 않는다
    @Test func deleteRightAfterNoticeDismissalIsIgnored() {
        var guardian = LauncherDeleteGuard()
        let now = Date(timeIntervalSince1970: 1_000_000)
        guardian.noticeDismissed(at: now)
        #expect(!guardian.allows(isRepeat: false, at: now.addingTimeInterval(0.2)))
        #expect(!guardian.allows(isRepeat: false, at: now.addingTimeInterval(LauncherDeleteGuard.settle - 0.01)))
        #expect(guardian.allows(isRepeat: false, at: now.addingTimeInterval(LauncherDeleteGuard.settle)))
        #expect(!guardian.allows(isRepeat: true, at: now.addingTimeInterval(5)))
    }

    // MARK: ↩ · ⌘↩

    private func effect(_ place: LauncherReturn.Place, command: Bool = false, isRepeat: Bool = false) -> LauncherReturn.Effect {
        LauncherReturn.effect(at: place, command: command, isRepeat: isRepeat)
    }

    /// Review 행의 ↩는 확정하지 않고 근거를 펼친다. 확정은 ⌘↩
    @Test func returnOnReviewRowShowsSourcesAndCommandReturnConfirms() {
        let review = LauncherItem.review(now.confirmations[0])
        #expect(effect(.list(review)) == .showSources)
        #expect(effect(.list(review), command: true) == .confirm)
    }

    /// 펼침 · ⌘K 패널의 ↩는 지금처럼 (⌘K 패널 열기 · 고른 줄 실행), ⌘↩는 고른 줄과 상관없이 확정
    @Test func returnOnReviewDetailOrActionsKeepsPrimaryAndCommandReturnConfirms() {
        #expect(effect(.task(.review)) == .primary)
        #expect(effect(.task(.review), command: true) == .confirm)
    }

    /// 누르고 있어 반복된 ↩ · ⌘↩는 어느 화면에서나 아무것도 하지 않는다
    /// (펼침 → 패널로 이어지거나, 확정 뒤 완료 화면 · 목록 첫 줄에 닿지 않게)
    @Test func repeatedReturnIsIgnoredEverywhere() {
        let places: [LauncherReturn.Place] = [
            .list(.review(now.confirmations[0])), .task(.review),
            .list(.task(now.now[0])), .list(.policyNotice(PolicyNotice(
                kind: .updated, version: "v", effectiveDate: LocalDate("2026-09-30")!,
                url: PolicyLinks(ko: URL(string: "https://example.com/ko")!, en: URL(string: "https://example.com/en")!)
            ))), .list(nil), .task(.toDo), .other,
        ]
        for place in places {
            #expect(effect(place, isRepeat: true) == .ignore)
            #expect(effect(place, command: true, isRepeat: true) == .ignore)
        }
    }

    /// 목록의 할 일 행(In Progress · To Do · Done Today) ↩ · ⌘↩는 원문 열기 (U1 PR4, Figma M1 `Open in Notion ↩`. 링크가 없으면 앱이 ⌘K 패널)
    @Test func returnOnTaskRowOpensSource() {
        let places: [LauncherReturn.Place] = [.list(.task(now.now[0])), .list(.done(now.now[0].action))]
        for place in places {
            #expect(effect(place) == .openSource)
            #expect(effect(place, command: true) == .openSource)
            #expect(effect(place, isRepeat: true) == .ignore)
        }
    }

    /// 새로 누른 ↩ · ⌘↩는 다른 행 · 화면에서 지금까지의 기본 동작 (확정하지 않는다)
    @Test func returnElsewhereKeepsPrimary() {
        let places: [LauncherReturn.Place] = [
            .list(.command(.settings)), .list(.ask("자료")), .list(nil),
            .list(.showMore(.toDo, hidden: 2)), .list(.doneToday(count: 1, expanded: false)),
            // Review 할 일을 넘기는 Hand off 행은 Review 행이 아니다
            .list(.handoff(now.confirmations[0])),
            .task(.toDo), .task(.inProgress), .task(.doneToday), .other,
        ]
        for place in places {
            #expect(effect(place) == .primary)
            #expect(effect(place, command: true) == .primary)
        }
    }

    /// 목록이 새로 오면 고르던 행을 그대로 가리킨다. 그 행이 사라졌으면 같은 자리
    @Test func refreshedListKeepsTheSelectedRow() {
        let items = LauncherContent.sections(for: .empty, now: now, signedIn: true).flatMap(\.items)
        #expect(LauncherContent.reselect(items[2].id, in: items, at: 0) == 2)
        #expect(LauncherContent.reselect("task-gone", in: items, at: 2) == 2)
        #expect(LauncherContent.reselect("task-gone", in: items, at: 99) == items.count - 1)
        #expect(LauncherContent.reselect(nil, in: [], at: 3) == 0)
    }

    private func action(_ title: String, review: Bool = false) -> ActionSummary {
        ActionSummary(
            id: UUID(), title: title, owner: .me, status: .open, dueDate: nil, counterpart: nil,
            needsConfirmation: review, confirmReasons: review ? ["담당 확인"] : [], startedAt: nil, lastActivityAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func items(reviews: [ActionSummary], toDo: [ActionSummary]) -> [LauncherItem] {
        let board = NowResponse(
            now: toDo.map { RankedAction(action: $0, score: 1, reasons: [], daysUntilDue: nil) }, confirmations: reviews, weeklyCheck: nil
        )
        return LauncherContent.sections(for: .empty, now: board, signedIn: true).flatMap(\.items)
    }

    /// 펼침 · 패널에서 돌아오면 본 할 일의 행 (그 자리의 다른 행이 아니라)
    @Test func goingBackSelectsTheViewedRow() {
        let (a, b, task) = (action("A", review: true), action("B", review: true), action("T"))
        let list = items(reviews: [a, b], toDo: [task])
        #expect(LauncherContent.rowAfterBack(viewing: b.id, in: list, near: 1) == 1)
        #expect(LauncherContent.rowAfterBack(viewing: task.id, in: list, near: 2) == 2)
        // 떠날 때 적어 둔 자리가 다른 행(맨 위 A)이어도 본 할 일 B의 행 — ⌘K → Open source → 알림 → esc (S1)
        #expect(LauncherContent.rowAfterBack(viewing: b.id, in: list, near: 0) == 1)
    }

    /// 보는 사이 위에 Review가 새로 들어와도 본 할 일의 행 (S2: 같은 자리의 새 Review가 아니라)
    @Test func goingBackFollowsTheViewedRowAfterARefresh() {
        let (task, fresh) = (action("T"), action("새 Review", review: true))
        let before = items(reviews: [], toDo: [task])
        #expect(before.firstIndex { $0.action?.id == task.id } == 0)
        let after = items(reviews: [fresh], toDo: [task])
        #expect(LauncherContent.rowAfterBack(viewing: task.id, in: after, near: 0) == 1)
    }

    /// 본 할 일이 사라졌으면(다른 기기에서 확정) Review가 아니라 가장 가까운 할 일 행, 할 일 행이 없으면 고른 줄 없음 (A2)
    @Test func goingBackAfterTheViewedRowVanishedNeverLandsOnAReview() {
        let gone = UUID()
        let (a, b, c) = (action("A", review: true), action("B", review: true), action("C", review: true))
        let (t1, t2) = (action("T1"), action("T2"))
        let list = items(reviews: [a, b, c], toDo: [t1, t2])
        // 떠날 때 자리 1(Review 사이) → 가장 가까운 할 일 행 T1(3)
        #expect(LauncherContent.rowAfterBack(viewing: gone, in: list, near: 1) == 3)
        #expect(LauncherContent.rowAfterBack(viewing: gone, in: list, near: 4) == 4)
        #expect(list[3].group == .toDo)
        // Review와 명령뿐이면 고른 줄 없음
        #expect(LauncherContent.rowAfterBack(viewing: gone, in: items(reviews: [a, b], toDo: []), near: 0) == nil)
    }

    /// 본 할 일이 없으면(물어보기 답 등) 맨 위. Hand off 행이 아니라 그 할 일의 행을 고른다
    @Test func goingBackWithoutAViewedItemSelectsTheTop() {
        let list = LauncherContent.sections(for: .query("자료"), now: now, signedIn: true).flatMap(\.items)
        #expect(LauncherContent.rowAfterBack(viewing: nil, in: list, near: 3) == 0)
        let handoff = list.firstIndex { if case .handoff = $0 { true } else { false } }
        #expect(handoff != nil)
        #expect(LauncherContent.rowAfterBack(viewing: now.now[0].action.id, in: list, near: handoff ?? 0) == 0)
    }
}
