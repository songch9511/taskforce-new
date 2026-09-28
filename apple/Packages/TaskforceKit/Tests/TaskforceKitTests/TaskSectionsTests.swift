import Foundation
import Testing
@testable import TaskforceKit

struct TaskSectionsTests {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    static func id(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))!
    }

    static func action(
        _ n: Int, _ title: String, status: ActionStatus = .open, startedAt: Date? = nil, review: Bool = false
    ) -> ActionSummary {
        ActionSummary(
            id: id(n), title: title, owner: .me, status: status, dueDate: nil, counterpart: nil, needsConfirmation: review,
            confirmReasons: review ? ["기한 확인"] : [], startedAt: startedAt, lastActivityAt: Date(timeIntervalSince1970: 0)
        )
    }

    static func ranked(_ action: ActionSummary) -> RankedAction {
        RankedAction(action: action, score: 1, reasons: [], daysUntilDue: nil)
    }

    static let started = Date(timeIntervalSince1970: 1_700_000_000)
    let proposal = Self.action(1, "제안서 보내기")
    let deck = Self.action(2, "IR 자료 업데이트", startedAt: Self.started)
    let contract = Self.action(3, "계약서 검토")
    let hiring = Self.action(4, "채용 공고 확인", startedAt: Self.started)
    let quote = Self.action(5, "견적서 회신", review: true)
    let notes = Self.action(6, "회의록 정리", status: .done)
    let mail = Self.action(7, "메일 회신", status: .done)

    /// 서버 순서: 제안서 · IR · 계약서 · 채용 / 확인 요청: 견적서 / 오늘 끝냄: 회의록 · 메일 (최근 것이 위)
    var board: TaskBoard {
        TaskBoard(
            now: NowResponse(now: [proposal, deck, contract, hiring].map(Self.ranked), confirmations: [quote], weeklyCheck: nil),
            doneToday: [notes, mail]
        )
    }

    func titles(_ sections: TaskSections, _ group: TaskGroup) -> [String] {
        sections.actions(in: group).map(\.title)
    }

    // MARK: 구역

    @Test func splitsOpenByStartedKeepingServerOrder() {
        let sections = board.sections()
        #expect(titles(sections, .review) == ["견적서 회신"])
        #expect(titles(sections, .inProgress) == ["IR 자료 업데이트", "채용 공고 확인"])
        #expect(titles(sections, .toDo) == ["제안서 보내기", "계약서 검토"])
        #expect(titles(sections, .doneToday) == ["회의록 정리", "메일 회신"])
        #expect(TaskGroup.allCases.map(\.title) == ["Review", "In Progress", "To Do", "Done Today"])
    }

    @Test func openGroupFollowsStartedAt() {
        #expect(TaskGroup.open(proposal) == .toDo)
        #expect(TaskGroup.open(deck) == .inProgress)
    }

    @Test func openListWinsOverStaleDoneList() {
        // 다른 기기에서 다시 연 할 일: 끝낸 목록을 아직 다시 읽기 전
        let staleDone = Self.action(1, "제안서 보내기", status: .done)
        let stale = TaskBoard(now: board.now, doneToday: [staleDone, notes, staleDone, Self.action(8, "열린 것", status: .open)])
        let sections = stale.sections()
        #expect(titles(sections, .toDo) == ["제안서 보내기", "계약서 검토"])
        #expect(titles(sections, .doneToday) == ["회의록 정리"])
    }

    @Test func confirmationNeverLandsInInProgressOrToDo() {
        let odd = TaskBoard(now: NowResponse(now: [Self.ranked(quote), Self.ranked(proposal)], confirmations: [], weeklyCheck: nil))
        let sections = odd.sections()
        #expect(titles(sections, .toDo) == ["제안서 보내기"])
        #expect(sections.inProgress.isEmpty)
    }

    @Test func emptyWhenNothingLoaded() {
        #expect(TaskBoard(now: nil).sections().isEmpty)
        #expect(!board.sections().isEmpty)
    }

    @Test func queryFiltersEveryGroupKeepingOrder() {
        let byTitle = board.sections(matching: " 서 ")
        #expect(titles(byTitle, .toDo) == ["제안서 보내기", "계약서 검토"])
        #expect(titles(byTitle, .review) == ["견적서 회신"])
        #expect(byTitle.inProgress.isEmpty && byTitle.doneToday.isEmpty)

        let reply = board.sections(matching: "회신")
        #expect(titles(reply, .review) == ["견적서 회신"])
        #expect(titles(reply, .doneToday) == ["메일 회신"])
        #expect(reply.toDo.isEmpty && reply.inProgress.isEmpty)

        #expect(board.sections(matching: "  ") == board.sections())
        #expect(board.sections(matching: nil) == board.sections())
    }

    // MARK: 내 변경

    @Test func completingMovesToTopOfDoneToday() {
        let sections = board.applying([proposal.id: TaskChange(proposal, to: .done, at: t0)]).sections()
        #expect(titles(sections, .toDo) == ["계약서 검토"])
        #expect(titles(sections, .doneToday) == ["제안서 보내기", "회의록 정리", "메일 회신"])
        #expect(sections.doneToday[0].status == .done)
        #expect(sections.find(proposal.id)?.group == .doneToday)
    }

    @Test func laterCompletionIsHigher() {
        let sections = board.applying([
            contract.id: TaskChange(contract, to: .done, at: t0.addingTimeInterval(1)),
            deck.id: TaskChange(deck, to: .done, at: t0),
        ]).sections()
        #expect(titles(sections, .doneToday) == ["계약서 검토", "IR 자료 업데이트", "회의록 정리", "메일 회신"])
        #expect(titles(sections, .inProgress) == ["채용 공고 확인"])
    }

    @Test func completedAlreadyInServerDoneIsListedOnce() {
        // 쓰기는 끝났고 두 목록을 다시 읽었지만 아직 내 변경을 지우기 전
        let reloaded = TaskBoard(
            now: NowResponse(now: [deck, contract, hiring].map(Self.ranked), confirmations: [quote], weeklyCheck: nil),
            doneToday: [notes, Self.action(1, "제안서 보내기", status: .done), mail]
        )
        let sections = reloaded.applying([proposal.id: TaskChange(proposal, to: .done, at: t0)]).sections()
        #expect(titles(sections, .doneToday) == ["제안서 보내기", "회의록 정리", "메일 회신"])
    }

    @Test func startingMovesToInProgressAtItsServerPosition() {
        let sections = board.applying([contract.id: TaskChange(contract, to: .inProgress, at: t0)]).sections()
        #expect(titles(sections, .inProgress) == ["IR 자료 업데이트", "계약서 검토", "채용 공고 확인"])
        #expect(titles(sections, .toDo) == ["제안서 보내기"])
        #expect(sections.find(contract.id)?.action.startedAt == t0)
    }

    @Test func startingKeepsTheServerStartTime() {
        let sections = board.applying([deck.id: TaskChange(deck, to: .inProgress, at: t0)]).sections()
        #expect(sections.find(deck.id)?.action.startedAt == Self.started)
    }

    @Test func reopeningMovesDoneBackToTheEndOfItsGroup() {
        let startedDone = Self.action(9, "착수했던 일", status: .done, startedAt: Self.started)
        let withStarted = TaskBoard(now: board.now, doneToday: [notes, startedDone, mail])
        let sections = withStarted.applying([
            notes.id: TaskChange(notes, to: .toDo, at: t0),
            startedDone.id: TaskChange(startedDone, to: .inProgress, at: t0.addingTimeInterval(1)),
        ]).sections()
        #expect(titles(sections, .toDo) == ["제안서 보내기", "계약서 검토", "회의록 정리"])
        #expect(titles(sections, .inProgress) == ["IR 자료 업데이트", "채용 공고 확인", "착수했던 일"])
        #expect(titles(sections, .doneToday) == ["메일 회신"])
        #expect(sections.find(notes.id)?.action.status == .open)
    }

    @Test func undoBeforeTheListReloadsKeepsTheServerPosition() {
        // 완료 → 곧바로 되돌림: 서버 목록에는 아직 열린 채로 있다
        let sections = board.applying([proposal.id: TaskChange(proposal, to: .toDo, at: t0)]).sections()
        #expect(titles(sections, .toDo) == ["제안서 보내기", "계약서 검토"])
        #expect(titles(sections, .doneToday) == ["회의록 정리", "메일 회신"])
    }

    @Test func movingInProgressToToDoClearsTheStartAtItsServerPosition() {
        let sections = board.applying([deck.id: TaskChange(deck, to: .toDo, at: t0)]).sections()
        #expect(titles(sections, .toDo) == ["제안서 보내기", "IR 자료 업데이트", "계약서 검토"])
        #expect(titles(sections, .inProgress) == ["채용 공고 확인"])
        #expect(sections.find(deck.id)?.action.startedAt == nil)
    }

    @Test func movingDoneToAChosenOpenState() {
        // 착수했던 일도 To Do로 고르면 착수 시각을 지우고, 착수 전이던 일도 In Progress로 고르면 그 시각에 착수
        let startedDone = Self.action(9, "착수했던 일", status: .done, startedAt: Self.started)
        let withStarted = TaskBoard(now: board.now, doneToday: [notes, startedDone, mail])
        let sections = withStarted.applying([
            startedDone.id: TaskChange(startedDone, to: .toDo, at: t0),
            notes.id: TaskChange(notes, to: .inProgress, at: t0.addingTimeInterval(1)),
        ]).sections()
        #expect(titles(sections, .toDo) == ["제안서 보내기", "계약서 검토", "착수했던 일"])
        #expect(titles(sections, .inProgress) == ["IR 자료 업데이트", "채용 공고 확인", "회의록 정리"])
        #expect(sections.find(startedDone.id)?.action.startedAt == nil)
        #expect(sections.find(notes.id)?.action.startedAt == t0.addingTimeInterval(1))
        #expect(titles(sections, .doneToday) == ["메일 회신"])
    }

    @Test func reviewIsNeverMovedIntoTheOpenList() {
        let sections = board.applying([quote.id: TaskChange(quote, to: .toDo, at: t0)]).sections()
        #expect(titles(sections, .review) == ["견적서 회신"])
        #expect(titles(sections, .toDo) == ["제안서 보내기", "계약서 검토"])
    }

    @Test func applyingBeforeTheListLoadsChangesNothing() {
        let empty = TaskBoard(now: nil, doneToday: [notes])
        #expect(empty.applying([notes.id: TaskChange(notes, to: .toDo, at: t0)]) == empty)
        #expect(board.applying([:]) == board)
    }

    @Test func findReportsGroupAndCurrentValue() {
        let sections = board.sections()
        #expect(sections.find(quote.id)?.group == .review)
        #expect(sections.find(hiring.id)?.group == .inProgress)
        #expect(sections.find(mail.id)?.action == mail)
        #expect(sections.find(Self.id(99)) == nil)
    }

    // MARK: 삭제 · 되살리기

    @Test func onlyTaskRowsAreDeletable() {
        // Review는 Dismiss가 그 자리다
        #expect(TaskGroup.allCases.filter(\.isDeletable) == [.inProgress, .toDo, .doneToday])
    }

    @Test func deletingRemovesTheRowFromEveryGroup() {
        let sections = board.applying([
            deck.id: .deleting(deck, at: t0),
            contract.id: .deleting(contract, at: t0),
            notes.id: .deleting(notes, at: t0),
        ]).sections()
        #expect(titles(sections, .inProgress) == ["채용 공고 확인"])
        #expect(titles(sections, .toDo) == ["제안서 보내기"])
        #expect(titles(sections, .doneToday) == ["메일 회신"])
        #expect(sections.find(deck.id) == nil)
    }

    @Test func deletingRightAfterCompletingHidesTheStaleOpenRow() {
        // 완료 → 곧바로 Done Today에서 지움: 서버 목록에는 아직 열린 채로 있다 (같은 할 일의 변경은 나중 것 하나만 남는다)
        let completed = proposal.replacing(status: .done, startedAt: nil)
        let sections = board.applying([proposal.id: .deleting(completed, at: t0)]).sections()
        #expect(sections.find(proposal.id) == nil)
        #expect(titles(sections, .toDo) == ["계약서 검토"])
        #expect(titles(sections, .doneToday) == ["회의록 정리", "메일 회신"])
    }

    @Test func restoreEditReopensOrCompletesByTheGroupItWasIn() {
        #expect(TaskUndo(proposal, was: .toDo, change: .deleted).restoreEdit == ActionEdit(status: .open))
        #expect(TaskUndo(deck, was: .inProgress, change: .deleted).restoreEdit == ActionEdit(status: .open))
        #expect(TaskUndo(notes, was: .done, change: .deleted).restoreEdit == ActionEdit(status: .done))
    }

    @Test func restoringAfterTheListReloadedPutsTheRowBackInItsGroup() {
        // 삭제가 반영돼 서버 목록에 없는 할 일: 열린 할 일은 그 구역 끝, Done은 Done Today 맨 위 (다시 읽으면 서버 자리로)
        let reloaded = TaskBoard(
            now: NowResponse(now: [proposal, contract].map(Self.ranked), confirmations: [quote], weeklyCheck: nil),
            doneToday: [mail]
        )
        let sections = reloaded.applying([
            deck.id: TaskUndo(deck, was: .inProgress, change: .deleted).restoring(at: t0),
            hiring.id: TaskUndo(hiring, was: .inProgress, change: .deleted).restoring(at: t0.addingTimeInterval(1)),
            notes.id: TaskUndo(notes, was: .done, change: .deleted).restoring(at: t0.addingTimeInterval(2)),
        ]).sections()
        #expect(titles(sections, .inProgress) == ["IR 자료 업데이트", "채용 공고 확인"])
        // 착수 시각은 지우기 전 값 그대로
        #expect(sections.find(deck.id)?.action.startedAt == Self.started)
        #expect(titles(sections, .doneToday) == ["회의록 정리", "메일 회신"])
        #expect(sections.find(notes.id)?.action.status == .done)
    }

    @Test func restoringBeforeTheListReloadsKeepsTheServerPosition() {
        // 삭제 → 곧바로 되돌림: 서버 목록에는 아직 그 자리에 있다
        let sections = board.applying([contract.id: TaskUndo(contract, was: .toDo, change: .deleted).restoring(at: t0)]).sections()
        #expect(titles(sections, .toDo) == ["제안서 보내기", "계약서 검토"])
    }

    @Test func undoOfferKeepsOnlyTheLatestAndExpiresByItsOwnSerial() {
        var offer = UndoOffer()
        #expect(offer.pending == nil)
        let first = TaskUndo(proposal, was: .toDo, change: .deleted)
        let second = TaskUndo(deck, was: .inProgress, change: .moved)
        offer.offer(first)
        let firstSerial = offer.serial
        offer.offer(second)
        // 먼저 둔 것의 시간이 다 돼도 새로 둔 것은 남는다
        offer.expire(firstSerial)
        #expect(offer.pending == second)
        offer.expire(offer.serial)
        #expect(offer.pending == nil)
        #expect(UndoOffer.window == .seconds(5))
    }

    @Test func undoOfferIsTakenOnce() {
        var offer = UndoOffer()
        let undo = TaskUndo(notes, was: .done, change: .deleted)
        offer.offer(undo)
        #expect(offer.take() == undo)
        #expect(offer.take() == nil)
        offer.offer(undo)
        offer.clear()
        #expect(offer.pending == nil)
    }

    @Test func launcherDeleteShortcutTargetsTaskRowsOnly() {
        // ⌘⌫: 할 일 행(In Progress · To Do · Done Today)은 Delete, Review는 Dismiss, Hand off 행 · 명령은 없음
        let items: [LauncherItem] = [.review(quote), .task(Self.ranked(deck)), .task(Self.ranked(proposal)), .done(notes), .handoff(proposal), .command(.settings)]
        #expect(items.map { $0.group?.isDeletable } == [false, true, true, true, nil, nil])
    }

    // MARK: 진행 상태

    @Test func workStateMatchesGroupsAndServerValues() {
        #expect(WorkState.allCases.map(\.title) == ["To Do", "In Progress", "Done"])
        #expect(WorkState.allCases.map(\.rawValue) == ["to_do", "in_progress", "done"])
        #expect(TaskGroup.allCases.map(WorkState.init) == [nil, .inProgress, .toDo, .done])
        #expect(WorkState.allCases.map(\.group) == [.toDo, .inProgress, .doneToday])
    }

    @Test func tappingTheMarkCompletesOpenAndReopensDone() {
        #expect(WorkState.toggled(from: .toDo, proposal) == .done)
        #expect(WorkState.toggled(from: .inProgress, deck) == .done)
        // 끝내기 전 상태를 기억하면 그리로
        #expect(WorkState.toggled(from: .done, notes, remembered: .inProgress) == .inProgress)
        #expect(WorkState.toggled(from: .done, notes, remembered: .toDo) == .toDo)
        // 모르면 착수 시각으로, 그것도 없으면 To Do
        let startedDone = Self.action(9, "착수했던 일", status: .done, startedAt: Self.started)
        #expect(WorkState.toggled(from: .done, startedDone) == .inProgress)
        #expect(WorkState.toggled(from: .done, notes) == .toDo)
        #expect(WorkState.toggled(from: .done, notes, remembered: .done) == .toDo)
    }

    // MARK: 런처

    @Test func launcherShowsDoneTodayAfterToDo() {
        let sections = LauncherContent.sections(for: .empty, now: board.now, doneToday: board.doneToday, signedIn: true)
        #expect(sections.map(\.title) == ["Review", "In Progress", "To Do", "Done Today", "Commands"])
        #expect(sections[3].items == [.done(notes), .done(mail)])
        #expect(sections[3].items.map(\.id) == ["done-\(notes.id)", "done-\(mail.id)"])
        #expect(sections[3].items.map(\.group) == [.doneToday, .doneToday])
    }

    @Test func launcherQueryPutsDoneTodayBelowAskAndHandoff() {
        let sections = LauncherContent.sections(for: .query("회신"), now: board.now, doneToday: board.doneToday, signedIn: true)
        #expect(sections.map(\.title) == ["Review", nil, "Done Today"])
        #expect(sections[1].items == [.ask("회신"), .handoff(quote)])
        #expect(sections[2].items == [.done(mail)])
    }

    @Test func launcherAddIgnoresDoneToday() {
        // 오늘 끝낸 할 일만 맞으면 Add가 맨 위 (↩ 한 번), 끝낸 할 일은 그 아래
        let sections = LauncherContent.sections(for: .query("회의록"), now: board.now, doneToday: board.doneToday, signedIn: true)
        #expect(sections.flatMap(\.items) == [.addAction("회의록"), .ask("회의록"), .done(notes)])
    }

    @Test func launcherAddAppearsOnceTheOnlyMatchIsCompleted() {
        let applied = board.applying([contract.id: TaskChange(contract, to: .done, at: t0)])
        let sections = LauncherContent.sections(for: .query("계약서"), now: applied.now, doneToday: applied.doneToday, signedIn: true)
        #expect(sections.flatMap(\.items).first == .addAction("계약서"))
        #expect(sections.last?.items.compactMap(\.action?.title) == ["계약서 검토"])
    }
}
