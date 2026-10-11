import Foundation
import Supabase
import Testing
@testable import TaskforceKit

/// S3b 저장소: 실제 서버 규칙을 흉내 내는 `FakeContextServer`로 읽기 · 조건부 쓰기 · Undo(`change`의 역연산) · 409 · 응답 유실 · 다른 기기 변경 · 늦은 읽기 · gate 꺼짐을 가른다.
/// 성공은 200뿐이고, 409 · 응답 유실 뒤에는 자동으로 다시 보내지 않고 RLS로 다시 읽는다
@MainActor
struct WorkContextStoreTests {
    let shape = ContextFx.context(1, "Shape launch", version: 3)
    let acme = ContextFx.context(2, "Acme website", version: 5)
    let old = ContextFx.context(3, "Old project", archived: true, version: 2)
    let a = WorkListTests.id(1)
    let b = WorkListTests.id(2)

    func make(_ contexts: [WorkContext]? = nil) -> (store: WorkContextStore, server: FakeContextServer) {
        let server = FakeContextServer(contexts: contexts ?? [shape, acme, old])
        return (WorkContextStore(gateway: server, scope: ChatTestAccount.fixedScope()), server)
    }

    func links(_ store: WorkContextStore, _ action: UUID) -> [String] {
        store.index.memberships(of: action).links.map { "\($0.project.name):\($0.origin)" }
    }

    // MARK: 읽기

    @Test func notReadYetClaimsNothing() async {
        let (store, _) = make()
        #expect(store.index.memberships(of: a) == .unknown)
        #expect(store.projectLinks(for: a) == nil)
        #expect(store.load == .loading && !store.hasRead)
    }

    /// 범위(version)를 먼저 읽고 멤버를 나중에 읽는다: 그 사이 바뀌면 version이 낡아 쓰기가 409로 막힌다 (반대 순서면 새 version으로 낡은 화면을 덮어쓸 수 있다)
    @Test func contextsAreReadBeforeMembers() async {
        let (store, server) = make()
        await store.refresh()
        #expect(server.calls == [.contexts, .members])
        #expect(store.load == .loaded(problem: nil) && store.hasRead)
    }

    @Test func readsBuildTheRealIndexFromContextsAndCurrentMembers() async {
        let (store, server) = make()
        server.seed(shape.id, a, origin: .user)
        server.seed(acme.id, a, origin: .auto)
        server.seed(acme.id, b, origin: .inferred, confidence: 0.7)
        server.seed(shape.id, b, origin: .user, removed: true)
        await store.refresh()
        #expect(links(store, a) == ["Acme website:auto", "Shape launch:user"])
        #expect(store.index.memberships(of: b).links.isEmpty && store.index.memberships(of: b).candidates.map(\.project.name) == ["Acme website"])
        #expect(store.members.count == 3, "뺀 행은 읽지 않는다 (서버 질의가 거른다) / 거르지 못해도 앱이 버린다")
        #expect(store.activeProjects.map(\.name) == ["Acme website", "Shape launch"], "고를 수 있는 범위는 active만, 이름 순")
    }

    @Test func offlineAndFailedReadsAreDifferentFromNone() async {
        let (store, server) = make()
        server.failReads(URLError(.notConnectedToInternet))
        await store.refresh()
        #expect(store.load == .offline && store.problem == .offline)
        #expect(store.index.memberships(of: a) == .unknown, "읽지 못했으면 Ungrouped라고도 말하지 않는다")
        server.failReads(APIError.server(status: 500, code: .internalError, message: "x"))
        await store.refresh()
        #expect(store.load == .failed && store.problem == .failed)
        server.failReads(nil)
        await store.refresh()
        #expect(store.load == .loaded(problem: nil) && store.index.memberships(of: a) == .none)
    }

    /// 받은 적이 있으면 이후 실패해도 받은 것을 그대로 두고 문제만 보인다
    @Test func aFailedRefreshKeepsTheLastReadAndReportsTheProblem() async {
        let (store, server) = make()
        server.seed(shape.id, a, origin: .user)
        await store.refresh()
        server.failReads(URLError(.notConnectedToInternet))
        await store.refresh()
        #expect(store.load == .loaded(problem: .offline) && store.problem == .offline)
        #expect(links(store, a) == ["Shape launch:user"])
    }

    /// 서버 DB에 범위 테이블이 아직 없다 (마이그레이션 전): 실패가 아니라 멤버십이 없는 것이다
    @Test func missingTablesAreNoMembershipsNotAFailure() async {
        let (store, server) = make()
        server.failReads(PostgrestError(code: "PGRST205", message: "Could not find the table 'public.work_contexts'"))
        await store.refresh()
        #expect(store.load == .loaded(problem: nil) && store.readsUnavailable && store.problem == nil)
        #expect(store.index.memberships(of: a) == .none)
    }

    // MARK: 넣기 · 빼기 · 바꾸기 (200만 성공)

    @Test func addSendsTheReadVersionAndShowsSetByYouAfterOnly200() async {
        let (store, server) = make()
        await store.refresh()
        let result = await store.add(a, to: shape.id)
        #expect(result == .applied(canUndo: true))
        #expect(server.writes == [.change(context: shape.id, op: .add, action: a, version: 3)], "RLS로 읽은 context_version이 조건이다")
        #expect(links(store, a) == ["Shape launch:user"])
        #expect(store.contexts[shape.id]?.contextVersion == 4, "다음 요청은 200이 준 version을 쓴다")
        #expect(store.projectLinks(for: a)?.first?.basis == .user)
    }

    @Test func removeKeepsARemovedRowSoNoAutoRuleCanReAddIt() async {
        let (store, server) = make()
        server.seed(shape.id, a, origin: .user)
        await store.refresh()
        let result = await store.remove(a, from: shape.id)
        #expect(result == .applied(canUndo: true))
        #expect(store.index.memberships(of: a) == .none)
        #expect(server.row(shape.id, a)?.removed == true, "행이 남고 뺀 표시가 선다")
    }

    @Test func moveIsOneRequestWithBothVersionsAndLeavesOtherMembershipsAlone() async {
        let (store, server) = make()
        server.seed(shape.id, a, origin: .user)
        server.seed(acme.id, b, origin: .user)
        await store.refresh()
        let result = await store.move(a, from: shape.id, to: acme.id)
        #expect(result == .applied(canUndo: true))
        #expect(server.writes == [.move(action: a, from: shape.id, to: acme.id, toVersion: 5, fromVersion: 3)])
        #expect(links(store, a) == ["Acme website:user"])
        #expect(links(store, b) == ["Acme website:user"], "다른 할 일은 그대로")
    }

    // MARK: Undo = change의 역연산

    /// 처음 A만: A → B 뒤 Undo는 B → A 이동 (added B · removed A 둘 다 있으므로)
    @Test func undoOfAMoveFromOnlyAMovesBack() async {
        let (store, server) = make()
        server.seed(shape.id, a, origin: .user)
        await store.refresh()
        await store.move(a, from: shape.id, to: acme.id)
        #expect(store.canUndo(a))
        let moved = (shape: server.version(shape.id), acme: server.version(acme.id))
        let result = await store.undoLast(a)
        #expect(result == .applied(canUndo: false), "Undo는 한 단계: Undo의 응답에 다시 Undo를 걸지 않는다")
        #expect(server.writes.last == .move(action: a, from: acme.id, to: shape.id, toVersion: moved.shape, fromVersion: moved.acme), "그 change의 version이 조건")
        #expect(links(store, a) == ["Shape launch:user"] && !store.canUndo(a))
    }

    /// 처음 A+B: A → B는 B를 그대로 두고 A만 뺀다. 맹목적 역이동(B → A)을 쓰면 원래 있던 B가 사라진다 → Undo는 A 넣기뿐
    @Test func undoOfAMoveWhenBWasAlreadyAMemberOnlyReAddsA() async {
        let (store, server) = make()
        server.seed(shape.id, a, origin: .user)
        server.seed(acme.id, a, origin: .auto)
        await store.refresh()
        let result = await store.move(a, from: shape.id, to: acme.id)
        #expect(result == .applied(canUndo: true))
        #expect(server.row(acme.id, a)?.origin == .user, "B는 user로 승격되었지만 이미 멤버였다")
        let shapeVersion = server.version(shape.id)
        let undone = await store.undoLast(a)
        #expect(undone == .applied(canUndo: false))
        #expect(server.writes.last == .change(context: shape.id, op: .add, action: a, version: shapeVersion), "역이동이 아니라 A 넣기, A의 version이 조건")
        #expect(links(store, a) == ["Acme website:user", "Shape launch:user"], "원래 있던 B는 남는다")
    }

    @Test func undoOfAnAddRemovesOnlyThatContext() async {
        let (store, server) = make()
        server.seed(acme.id, a, origin: .user)
        await store.refresh()
        await store.add(a, to: shape.id)
        let result = await store.undoLast(a)
        #expect(result == .applied(canUndo: false))
        #expect(links(store, a) == ["Acme website:user"])
        #expect(server.writes.last == .change(context: shape.id, op: .remove, action: a, version: 4))
    }

    @Test func undoOfARemoveReAddsAsSetByYou() async {
        let (store, server) = make()
        server.seed(shape.id, a, origin: .auto)
        await store.refresh()
        await store.remove(a, from: shape.id)
        await store.undoLast(a)
        #expect(links(store, a) == ["Shape launch:user"], "Undo로 돌아온 멤버는 Auto-linked가 아니라 Set by you")
    }

    /// 바뀐 멤버가 없는 요청에는 Undo가 없다
    @Test func nothingChangedMeansNoUndo() async {
        let (store, server) = make()
        server.seed(shape.id, a, origin: .user)
        server.seed(acme.id, b, origin: .auto)
        server.seed(shape.id, b, origin: .inferred, confidence: 0.5)
        await store.refresh()
        // 이미 user 멤버에 add
        #expect(await store.add(a, to: shape.id) == .applied(canUndo: false))
        // auto → user 승격 (이미 멤버였다)
        #expect(await store.add(b, to: acme.id) == .applied(canUndo: false))
        #expect(server.row(acme.id, b)?.origin == .user)
        // 후보를 뺌
        #expect(await store.remove(b, from: shape.id) == .applied(canUndo: false))
        #expect(!store.canUndo(a) && !store.canUndo(b))
        #expect(store.index.memberships(of: b).candidates.isEmpty, "거절한 후보는 다시 보이지 않는다")
    }

    @Test func confirmingACandidateIsAnAddWithAnUndoThatRemovesIt() async {
        let (store, server) = make()
        server.seed(shape.id, a, origin: .inferred, confidence: 0.8)
        await store.refresh()
        #expect(store.index.memberships(of: a).links.isEmpty)
        #expect(await store.add(a, to: shape.id) == .applied(canUndo: true))
        #expect(links(store, a) == ["Shape launch:user"])
        await store.undoLast(a)
        #expect(store.index.memberships(of: a) == .none, "후보를 확인한 것을 Undo하면 후보가 돌아오지 않고 그 범위에서 빠진다")
    }

    /// 후보를 확인하다 충돌하면 안내는 후보 줄에 놓인다 (범위 없음 줄이 아니라)
    @Test func aConflictOnConfirmingACandidateIsShownOnTheCandidateRow() async {
        let (store, server) = make()
        server.seed(shape.id, a, origin: .inferred, confidence: 0.6)
        await store.refresh()
        server.otherDevice(.add, ctx: shape.id, action: b)
        #expect(await store.add(a, to: shape.id) == .conflict)
        let rows = store.projectLinks(for: a) ?? []
        #expect(rows.map(\.basis) == [.none, .candidate] && rows.map(\.message) == [nil, WorkProjectCopy.conflict])
    }

    /// 다른 기기가 원래 있던 B를 지웠어도 A 넣기 Undo는 A의 version만 조건이라 그 결정을 덮지 않는다
    @Test func undoDoesNotOverrideAnotherDevicesDecisionOnTheOtherContext() async {
        let (store, server) = make()
        server.seed(shape.id, a, origin: .user)
        server.seed(acme.id, a, origin: .user)
        await store.refresh()
        await store.move(a, from: shape.id, to: acme.id)
        server.otherDevice(.remove, ctx: acme.id, action: a)
        let undone = await store.undoLast(a)
        // Acme의 version은 올랐지만 A 넣기 Undo는 Shape의 version만 조건이다
        #expect(undone == .applied(canUndo: false))
        #expect(links(store, a) == ["Shape launch:user"], "다른 기기가 지운 B는 되살아나지 않는다")
    }

    // MARK: 409 · 응답 유실 · 다른 기기 변경

    /// 다른 기기가 그 범위를 바꾼 뒤 낡은 화면에서 보낸 요청은 409: 성공으로 올리지 않고 다시 읽고, 자동으로 다시 보내지 않는다
    @Test func aConflictIsRefreshedNotPromotedAndNeverResent() async {
        let (store, server) = make()
        await store.refresh()
        server.otherDevice(.add, ctx: shape.id, action: b)
        let result = await store.add(a, to: shape.id)
        #expect(result == .conflict)
        #expect(store.feedback(for: a) == .conflict && store.feedback(for: a)?.text == "This changed somewhere else. It's been refreshed.")
        #expect(server.writes.count == 1, "자동 재전송 없음")
        #expect(store.index.memberships(of: a) == .none, "내 요청은 적용되지 않았다")
        #expect(links(store, b) == ["Shape launch:user"], "다시 읽어 다른 기기의 변경을 보인다")
        #expect(store.contexts[shape.id]?.contextVersion == server.version(shape.id), "다시 읽어 새 version으로 사용자가 다시 할 수 있다")
        #expect(!store.canUndo(a))
    }

    /// 다시 읽은 지금 상태가 내가 원한 모양이어도 이 요청의 성공이 아니다
    @Test func aStateThatLooksRightAfterAConflictIsStillNotSuccess() async {
        let (store, server) = make()
        await store.refresh()
        server.otherDevice(.add, ctx: shape.id, action: a)
        let result = await store.add(a, to: shape.id)
        #expect(result == .conflict && store.feedback(for: a) == .conflict)
        #expect(links(store, a) == ["Shape launch:user"])
        #expect(!store.canUndo(a), "내가 한 일이 아니므로 되돌릴 것이 없다")
    }

    /// 서버는 처리했는데 응답을 잃었다: 성공으로 표시하지 않고 Undo도 없다. 다시 읽은 서버 상태만 보인다. 같은 본문을 자동으로 다시 보내지 않는다
    @Test func aLostResponseIsUnconfirmedWithNoUndoAndNoResend() async {
        let (store, server) = make()
        await store.refresh()
        server.loseNextResponses()
        let result = await store.add(a, to: shape.id)
        #expect(result == .unconfirmed)
        #expect(store.feedback(for: a) == .unconfirmed)
        #expect(server.writes.count == 1)
        #expect(links(store, a) == ["Shape launch:user"], "서버 상태를 다시 읽어 보인다 (이 요청의 성공 증거는 아니다)")
        #expect(!store.canUndo(a))
        // 사용자가 지금 상태를 보고 다시 하면 새 version으로 간다 (이미 멤버라 바뀐 것 없음)
        #expect(await store.add(a, to: shape.id) == .applied(canUndo: false))
        #expect(server.writes.count == 2)
    }

    @Test func aServerErrorIsAlsoUnconfirmedBecauseItMayHaveCommitted() async {
        let (store, server) = make()
        await store.refresh()
        server.changeOverride = { throw APIError.server(status: 500, code: .internalError, message: "x") }
        #expect(await store.add(a, to: shape.id) == .unconfirmed)
        #expect(store.feedback(for: a) == .unconfirmed)
        #expect(server.reads >= 2, "다시 읽는다")
    }

    @Test func otherRejectionsChangeNothingAndStateTheReason() async {
        let (store, server) = make()
        await store.refresh()
        server.changeOverride = { throw APIError.server(status: 429, code: .rateLimited, message: "x") }
        let before = server.reads
        #expect(await store.add(a, to: shape.id) == .failed)
        #expect(store.feedback(for: a) == .failed("Too many requests. Try again in a moment."))
        #expect(server.reads == before, "아무것도 바뀌지 않았다")
    }

    /// 다른 기기 변경 뒤의 늦은 Undo의 409도 같은 처리: 다시 읽고 충돌 표시, 다시 보내지 않는다
    @Test func aLateUndoAfterAnotherDeviceChangeIsAConflictAndConsumed() async {
        let (store, server) = make()
        server.seed(shape.id, a, origin: .user)
        await store.refresh()
        await store.move(a, from: shape.id, to: acme.id)
        server.otherDevice(.add, ctx: acme.id, action: b)
        let writes = server.writes.count
        let result = await store.undoLast(a)
        #expect(result == .conflict && store.feedback(for: a) == .conflict)
        #expect(server.writes.count == writes + 1, "Undo는 한 번만 보낸다")
        #expect(!store.canUndo(a))
        #expect(await store.undoLast(a) == .ignored)
        #expect(links(store, a) == ["Acme website:user"], "되돌려지지 않았다")
    }

    // MARK: 한 번에 하나 · 조건을 모를 때

    @Test func onlyOneRequestPerActionAtATime() async {
        let (store, server) = make()
        await store.refresh()
        let latch = Latch()
        server.holdWrites(latch)
        let first = Task { await store.add(a, to: shape.id) }
        while await latch.arrivals == 0 { await Task.yield() }
        #expect(store.isBusy(a))
        // 두 번째 · 세 번째 요청은 서버에 닿지 않는다 (붙잡힌 첫 요청 하나만 도착해 있다)
        let second = Task { await store.add(a, to: acme.id) }
        let third = Task { await store.remove(a, from: shape.id) }
        for _ in 0..<100 { await Task.yield() }
        #expect(await latch.arrivals == 1)
        #expect(store.projectLinks(for: a)?.allSatisfy { $0.isBusy } == true)
        // 다른 할 일은 막지 않는다
        #expect(!store.isBusy(b))
        await latch.open()
        #expect(await second.value == .ignored)
        #expect(await third.value == .ignored)
        #expect(await first.value == .applied(canUndo: true))
        #expect(server.writes.count == 1 && !store.isBusy(a))
    }

    @Test func aContextWithoutAReadVersionIsNeverWrittenTo() async {
        let (store, server) = make([ContextFx.context(1, "Shape launch", version: nil), acme])
        await store.refresh()
        #expect(await store.add(a, to: shape.id) == .ignored)
        #expect(server.writes.isEmpty)
        #expect(await store.add(a, to: acme.id) != .ignored)
    }

    // MARK: 보관된 범위 · 지워진 범위

    @Test func archivedContextsAreReadOnlyInTheApp() async {
        let (store, server) = make()
        server.seed(old.id, a, origin: .user)
        await store.refresh()
        #expect(await store.add(a, to: old.id) == .ignored)
        #expect(await store.remove(a, from: old.id) == .ignored)
        #expect(await store.move(a, from: old.id, to: shape.id) == .ignored)
        #expect(await store.move(a, from: shape.id, to: old.id) == .ignored)
        #expect(server.writes.isEmpty)
        let link = store.projectLinks(for: a)?.first
        #expect(link?.isArchived == true && link?.choices.isEmpty == true && link?.note == WorkProjectCopy.archivedNote)
        #expect(link?.meta == "Project · Set by you · Archived")
        #expect(!store.activeProjects.contains { $0.id == old.id })
    }

    /// 화면을 보는 사이 서버에서 보관됐다: 서버가 404 → 그대로 실패로 꾸미지 않고 "보관됐거나 없음"과 다시 읽은 읽기 전용 상태
    @Test func aContextArchivedMeanwhileIsReportedAndRefreshedToReadOnly() async {
        let (store, server) = make()
        server.seed(shape.id, a, origin: .user)
        await store.refresh()
        server.archive(shape.id)
        let result = await store.remove(a, from: shape.id)
        #expect(result == .unavailable)
        #expect(store.feedback(for: a) == .contextGone && store.feedback(for: a)?.text == WorkProjectCopy.contextGone)
        #expect(store.projectLinks(for: a)?.first?.isArchived == true && store.projectLinks(for: a)?.first?.choices.isEmpty == true)
        #expect(!store.writesUnavailable, "다른 범위의 쓰기는 막지 않는다")
    }

    @Test func aContextDeletedMeanwhileDropsItsGroupAfterTheRefresh() async {
        let (store, server) = make()
        server.seed(shape.id, a, origin: .user)
        await store.refresh()
        server.deleteContext(shape.id)
        #expect(await store.add(b, to: shape.id) == .unavailable)
        #expect(store.index.memberships(of: a) == .none && store.contexts[shape.id] == nil)
    }

    // MARK: 서버 gate 꺼짐

    @Test func aGateOffServerIsNotDressedUpAsAFailure() async {
        let (store, server) = make()
        server.seed(shape.id, a, origin: .user)
        await store.refresh()
        server.setGateOff()
        let result = await store.remove(a, from: shape.id)
        #expect(result == .unavailable && store.writesUnavailable)
        #expect(store.feedback(for: a) == nil, "실패 안내가 아니다")
        #expect(links(store, a) == ["Shape launch:user"], "읽기는 그대로")
        let link = store.projectLinks(for: a)?.first
        #expect(link?.choices.isEmpty == true && link?.note == WorkProjectCopy.writesUnavailable)
        // 이후 쓰기는 서버를 부르지 않는다
        let calls = server.writes.count
        #expect(await store.add(b, to: acme.id) == .ignored)
        #expect(server.writes.count == calls)
    }

    // MARK: 늦은 읽기 (old-after-new)

    @Test func theLastStartedReadWinsOverALateOlderOne() async {
        let (store, server) = make()
        server.seed(shape.id, a, origin: .user)
        await store.refresh()
        let latch = Latch()
        server.holdReads(latch)
        let older = Task { await store.refresh() }
        while await latch.arrivals == 0 { await Task.yield() }
        // 읽는 사이 서버가 바뀌고 더 늦게 시작한 읽기가 먼저 끝난다
        server.holdReads(nil)
        server.otherDevice(.remove, ctx: shape.id, action: a)
        await store.refresh()
        #expect(store.index.memberships(of: a) == .none)
        await latch.open()
        await older.value
        #expect(store.index.memberships(of: a) == .none, "늦게 끝난 옛 읽기는 새 상태를 되돌리지 못한다")
    }

    /// 쓰기 200을 반영하면 그 전에 시작한 읽기는 버려진다 (옛 읽기가 방금 쓴 멤버를 지우지 못한다)
    @Test func aWriteInvalidatesReadsStartedBeforeIt() async {
        let (store, server) = make()
        await store.refresh()
        let latch = Latch()
        server.holdReads(latch)
        let older = Task { await store.refresh() }
        while await latch.arrivals == 0 { await Task.yield() }
        server.holdReads(nil)
        await store.add(a, to: shape.id)
        #expect(links(store, a) == ["Shape launch:user"])
        await latch.open()
        await older.value
        #expect(links(store, a) == ["Shape launch:user"], "옛 읽기(쓰기 전 상태)는 반영되지 않는다")
    }

    // MARK: 한 할 일이 여러 범위

    @Test func perMembershipChoicesNeverCollapseMultipleProjectsIntoOne() async {
        let (store, server) = make()
        server.seed(shape.id, a, origin: .user)
        server.seed(acme.id, a, origin: .auto)
        await store.refresh()
        let rows = store.projectLinks(for: a) ?? []
        #expect(rows.map(\.name) == ["Acme website", "Shape launch"])
        #expect(rows.map(\.basis) == [.auto, .user])
        // 둘이라 "빼기" 선택지는 어느 범위에서 빼는지 말한다
        #expect(rows[0].choices.map(\.name) == ["Remove from Acme website", "Acme website"])
        // 이미 확인된 범위는 바꾸기 대상에 없다
        #expect(rows[1].choices.map(\.name) == ["Remove from Shape launch", "Shape launch"])
    }
}
