import Foundation
import Synchronization
import Testing
@testable import TaskforceKit

/// 저장된 대화 목록의 상태 · 쪽 읽기 · 지우기 · 모두 지우기 · 계정 경계 (D3v-m, 계약 27장). 서버는 모두 가짜 닫힘이다 (실제 서버 · Supabase에 닿지 않는다)
@MainActor
struct SavedChatsStoreTests {
    typealias S = SavedChatSamples

    /// 가짜 서버의 한 면: 부른 것을 세고 돌려줄 값을 시험이 정한다
    final class Fake: @unchecked Sendable {
        private let lock = NSLock()
        private var _pages: [[SavedChatRow]] = []
        private var _calls: [(offset: Int, limit: Int)] = []
        private var _deleted: [UUID] = []
        private var _deleteErrors: [any Error] = []
        private var _deleteAllErrors: [any Error] = []
        private var _deleteAllCalls = 0
        private var _readError: (any Error)?
        private var _pageGates: [Int: SavedChatsGate] = [:]

        var calls: [(offset: Int, limit: Int)] { lock.withLock { _calls } }
        var deleted: [UUID] { lock.withLock { _deleted } }
        var deleteAllCalls: Int { lock.withLock { _deleteAllCalls } }

        func setPages(_ pages: [[SavedChatRow]]) { lock.withLock { _pages = pages } }
        func failReads(with error: (any Error)?) { lock.withLock { _readError = error } }
        func failDeletes(_ errors: [any Error]) { lock.withLock { _deleteErrors = errors } }
        func failDeleteAll(_ errors: [any Error]) { lock.withLock { _deleteAllErrors = errors } }
        /// n번째(0부터) 읽기를 문이 열릴 때까지 붙잡는다: 답은 부른 때 정해져 있어서, 풀린 뒤 늦게 오는 옛 답을 만든다
        func hold(call index: Int, with gate: SavedChatsGate) { lock.withLock { _pageGates[index] = gate } }

        func page(_ offset: Int, _ limit: Int) async throws -> [SavedChatRow] {
            let (page, error, gate) = lock.withLock { () -> ([SavedChatRow], (any Error)?, SavedChatsGate?) in
                _calls.append((offset, limit))
                let index = _calls.count - 1
                return (index < _pages.count ? _pages[index] : _pages.last ?? [], _readError, _pageGates[index])
            }
            if let gate { await gate.wait() }
            if let error { throw error }
            return page
        }

        func delete(_ id: UUID) async throws {
            let error = lock.withLock { () -> (any Error)? in
                _deleted.append(id)
                return _deleteErrors.isEmpty ? nil : _deleteErrors.removeFirst()
            }
            if let error { throw error }
        }

        func deleteAll() async throws {
            let error = lock.withLock { () -> (any Error)? in
                _deleteAllCalls += 1
                return _deleteAllErrors.isEmpty ? nil : _deleteAllErrors.removeFirst()
            }
            if let error { throw error }
        }
    }

    private func make(
        _ fake: Fake = Fake(), pageSize: Int = 20, scope: AccountScope = AccountScope(currentAccount: { SavedChatSamples.id(999) }),
        log: @escaping @Sendable (String, String) -> Void = { _, _ in }
    ) -> (SavedChatsStore, Fake, AccountScope) {
        let store = SavedChatsStore(
            scope: scope, readPage: { try await fake.page($0, $1) }, readMessages: { _, _, _ in [] }, deleteChat: { try await fake.delete($0) },
            deleteAll: { try await fake.deleteAll() }, pageSize: pageSize, log: log
        )
        return (store, fake, scope)
    }

    private func rows(_ range: ClosedRange<Int>) -> [SavedChatRow] { range.map { S.row($0) } }

    // MARK: 목록 상태

    @Test func theFirstReadShowsCheckingThenRowsAndRowsAreKept() async {
        let fake = Fake()
        fake.setPages([rows(1...3)])
        let (store, _, _) = make(fake)
        #expect(store.phase == .idle && store.sectionState == .checking, "처음 읽기 전에도 \"No sessions\"를 말하지 않는다")
        await store.refresh()
        #expect(store.phase == .ready && store.rows.map(\.id) == (1...3).map { S.id($0) } && store.sectionState == .rows && !store.hasMore)
        #expect(fake.calls.map(\.offset) == [0] && fake.calls.map(\.limit) == [20])
    }

    @Test func aReadyListWithNoRowsHasNoSectionAndNoEmptyState() async {
        // 서버 gate가 꺼져 있으면 읽기가 아무것도 돌려주지 않는다: 절은 그냥 없다 (빈 상태 글 없음)
        let fake = Fake()
        fake.setPages([[]])
        let (store, _, _) = make(fake)
        await store.refresh()
        #expect(store.phase == .ready && store.rows.isEmpty)
        #expect(store.sectionState == .absent, "gate가 꺼져 읽기가 비면 절 머리째 없다. 빈 상태를 보이지 않는다")
        #expect(!store.hasChats)
    }

    @Test func aFailedFirstReadIsTheErrorStateAndTryAgainReadsAgain() async {
        let fake = Fake()
        fake.failReads(with: URLError(.notConnectedToInternet))
        let (store, _, _) = make(fake)
        await store.refresh()
        #expect(store.phase == .failed && store.sectionState == .failed)
        fake.failReads(with: nil)
        fake.setPages([rows(1...2)])
        await store.retry().value
        #expect(store.phase == .ready && store.rows.count == 2 && store.sectionState == .rows)
    }

    @Test func aFailedRefreshKeepsTheRowsAlreadyShown() async {
        let fake = Fake()
        fake.setPages([rows(1...3)])
        let (store, _, _) = make(fake)
        await store.refresh()
        fake.failReads(with: URLError(.timedOut))
        await store.refresh()
        #expect(store.rows.count == 3 && store.sectionState == .rows, "이미 보이는 줄은 읽기 실패로 사라지지 않는다")
    }

    @Test func aRefreshStartsOverAtTheFirstPage() async {
        let fake = Fake()
        fake.setPages([rows(1...20), rows(21...30), rows(1...20)])
        let (store, _, _) = make(fake)
        await store.refresh()
        await store.loadMore()
        #expect(store.rows.count == 30)
        await store.refresh()
        #expect(store.rows.count == 20 && store.hasMore, "열 때마다 처음 쪽부터 다시 읽는다")
        #expect(fake.calls.map(\.offset) == [0, 20, 0])
    }

    // MARK: 쪽 읽기: 20개씩

    @Test func showEarlierReadsTheNextTwentyAndStopsOnAShortPage() async {
        let fake = Fake()
        fake.setPages([rows(1...20), rows(21...40), rows(41...45)])
        let (store, _, _) = make(fake)
        await store.refresh()
        #expect(store.hasMore, "가득 찬 쪽이면 더 있을 수 있다")
        await store.loadMore()
        #expect(store.rows.count == 40 && store.hasMore)
        await store.loadMore()
        #expect(store.rows.count == 45 && !store.hasMore, "짧은 쪽이면 끝이다")
        #expect(fake.calls.map(\.offset) == [0, 20, 40] && fake.calls.allSatisfy { $0.limit == 20 })
        await store.loadMore()
        #expect(fake.calls.count == 3, "더 없으면 읽지 않는다")
    }

    @Test func rowsFromAnOverlappingPageAreNotListedTwice() async {
        // 읽는 사이 새 대화가 생기면 다음 쪽의 첫 줄이 앞 쪽의 끝 줄과 같을 수 있다
        let fake = Fake()
        fake.setPages([rows(1...20), rows(20...25)])
        let (store, _, _) = make(fake)
        await store.refresh()
        await store.loadMore()
        #expect(store.rows.map(\.id) == (1...25).map { S.id($0) })
    }

    @Test func aFailedShowEarlierKeepsTheListAndCanBeRetried() async {
        let fake = Fake()
        fake.setPages([rows(1...20), rows(21...22)])
        let (store, _, _) = make(fake)
        await store.refresh()
        fake.failReads(with: URLError(.timedOut))
        await store.loadMore()
        #expect(store.rows.count == 20 && store.hasMore && !store.loadingMore)
        fake.failReads(with: nil)
        await store.loadMore()
        #expect(store.rows.count == 22)
    }

    // MARK: 읽는 중인 읽기가 지우기를 덮지 않는다 (재검토 P2)

    /// 붙잡힌 읽기가 가짜 서버에 닿고 연쇄가 끝나도록 충분히 양보한다
    private func settle() async {
        for _ in 0..<40 { await Task.yield() }
    }

    @Test func aDeleteAllWhileTheFirstPageIsLoadingDropsTheLateRead() async {
        let fake = Fake(), gate = SavedChatsGate()
        fake.setPages([rows(1...5)])
        fake.hold(call: 0, with: gate)
        let (store, _, _) = make(fake)
        let read = Task { await store.refresh() }
        await settle()
        await store.deleteAllChats()
        #expect(store.rows.isEmpty && store.deleteAllState == .idle && store.sectionState == .absent)
        await gate.open()
        await read.value
        #expect(store.rows.isEmpty && store.sectionState == .absent && !store.hasChats, "지우기 전에 시작한 읽기가 늦게 와도 지운 대화를 되살리지 않는다")
    }

    @Test func aSingleDeleteWhileTheFirstPageIsLoadingDropsTheLateRead() async {
        let fake = Fake(), gate = SavedChatsGate()
        fake.setPages([rows(1...3), rows(1...3)])
        fake.hold(call: 1, with: gate)
        let (store, _, _) = make(fake)
        await store.refresh()
        let read = Task { await store.refresh() }
        await settle()
        #expect(await store.delete(S.id(2)) == .deleted)
        await gate.open()
        await read.value
        #expect(store.rows.map(\.id) == [S.id(1), S.id(3)], "지우기 전에 시작한 읽기의 옛 목록(지운 줄 포함)을 쓰지 않는다")
    }

    @Test func aDeleteWhileShowEarlierIsReadingDropsThatPageAndTheNextShowEarlierStartsAtTheRightOffset() async {
        let fake = Fake(), gate = SavedChatsGate()
        fake.setPages([rows(1...20), rows(21...40)])
        fake.hold(call: 1, with: gate)
        let (store, _, _) = make(fake)
        await store.refresh()
        let more = Task { await store.loadMore() }
        await settle()
        #expect(store.loadingMore)
        #expect(await store.delete(S.id(5)) == .deleted)
        await gate.open()
        await more.value
        #expect(store.rows.count == 19 && !store.rows.contains { $0.id == S.id(5) } && !store.rows.contains { $0.id == S.id(21) }, "지우기 전에 시작한 다음 쪽(오프셋이 낡았다)은 쓰지 않는다")
        #expect(!store.loadingMore && store.hasMore)
        await store.loadMore()
        #expect(fake.calls.map(\.offset) == [0, 20, 19], "다시 누르면 지운 줄을 뺀 자리에서 읽는다")
    }

    @Test func aRefreshWhileShowEarlierIsReadingDropsThatPageSoTheListNeverSkipsAhead() async {
        let fake = Fake(), gate = SavedChatsGate()
        fake.setPages([rows(1...20), rows(21...40), rows(1...20), rows(21...40)])
        fake.hold(call: 1, with: gate)
        let (store, _, _) = make(fake)
        await store.refresh()
        let more = Task { await store.loadMore() }
        await settle()
        await store.refresh()
        #expect(store.rows.map(\.id) == (1...20).map { S.id($0) })
        await gate.open()
        await more.value
        #expect(store.rows.map(\.id) == (1...20).map { S.id($0) } && !store.loadingMore, "새로 읽은 목록 뒤에 옛 쪽을 붙이지 않는다 (1–20 다음 21–40이 아니라 다른 자리의 쪽이 붙는 일)")
        await store.loadMore()
        #expect(store.rows.map(\.id) == (1...40).map { S.id($0) } && fake.calls.map(\.offset) == [0, 20, 0, 20], "다음 Show earlier는 새 목록 바로 뒤에서 읽는다")
    }

    @Test func aLostDeleteAllAnswerWhileARefreshIsInFlightReadsFreshAndIgnoresTheOlderRead() async {
        // 모두 지우기는 서버에서 끝났는데 답을 잃었고, 그 전에 시작한 옛 읽기(지우기 전 목록)가 아직 돈다: 실패 길은 그 읽기를 기다리지 않고 새로 읽는다
        let fake = Fake(), gate = SavedChatsGate()
        fake.setPages([rows(1...5), rows(1...5), []])
        fake.hold(call: 1, with: gate)
        fake.failDeleteAll([APIError.transport("offline")])
        let (store, _, _) = make(fake)
        await store.refresh()
        let older = Task { await store.refresh() }
        await settle()
        let all = Task { await store.deleteAllChats() }
        await settle()
        await gate.open()
        await all.value
        await older.value
        #expect(fake.calls.count == 3, "옛 읽기에 합쳐지지 않고 새로 한 번 읽었다")
        #expect(store.rows.isEmpty && store.deleteAllState == .idle, "새로 읽은 목록이 비었으니 성공이다 (옛 읽기의 1–5가 아니다)")
    }

    @Test func twoOverlappingRefreshesReadTheFirstPageOnce() async {
        let fake = Fake(), gate = SavedChatsGate()
        fake.setPages([rows(1...3)])
        fake.hold(call: 0, with: gate)
        let (store, _, _) = make(fake)
        let first = Task { await store.refresh() }
        await settle()
        let second = Task { await store.refresh() }
        await settle()
        await gate.open()
        await first.value
        await second.value
        #expect(fake.calls.count == 1 && store.rows.count == 3, "겹쳐 읽지 않는다")
    }

    @Test func theListChangedHookFiresWheneverTheRowsChange() async {
        // 열어 둔 보기가 목록에서 빠졌는지 보게 하는 신호: 읽기가 쓰일 때 · 지울 때 · 모두 지울 때 · 계정이 떠날 때
        let fake = Fake(), hits = SavedChatsCounter()
        fake.setPages([rows(1...20), rows(21...22)])
        let (store, _, scope) = make(fake)
        store.onListChanged = { hits.hit() }
        await store.refresh()
        #expect(hits.count == 1)
        await store.loadMore()
        #expect(hits.count == 2)
        _ = await store.delete(S.id(3))
        #expect(hits.count == 3)
        await store.deleteAllChats()
        #expect(hits.count == 4)
        scope.accountLeft()
        #expect(hits.count == 5)
    }

    @Test func aDroppedLateReadDoesNotFireTheListChangedHook() async {
        let fake = Fake(), gate = SavedChatsGate(), hits = SavedChatsCounter()
        fake.setPages([rows(1...3)])
        fake.hold(call: 0, with: gate)
        let (store, _, _) = make(fake)
        store.onListChanged = { hits.hit() }
        let read = Task { await store.refresh() }
        await settle()
        await store.deleteAllChats()
        let afterDeleteAll = hits.count
        await gate.open()
        await read.value
        #expect(hits.count == afterDeleteAll, "버린 읽기는 목록을 바꾸지 않았으니 알리지 않는다")
    }

    // MARK: 절 모양: 처음 셋 · Show all · Show earlier

    @Test func theSectionOffersShowEarlierWhenThereAreThreeOrFewerRowsButMore() async {
        // 지우고 나면 한 쪽이 가득 찼던 목록이 셋 이하로 줄 수 있다: Show all이 없으니 Show earlier가 유일한 길이다
        let fake = Fake()
        fake.setPages([rows(1...3)])
        let (store, _, _) = make(fake, pageSize: 3)
        await store.refresh()
        #expect(store.hasMore)
        let folded = store.section(expanded: false)
        #expect(!folded.fold.togglesFold && folded.showsEarlier, "셋 이하이고 더 있으면 접힘과 상관없이 끝에 Show earlier")
        #expect(store.section(expanded: true).showsEarlier)
        fake.setPages([rows(1...3), rows(4...6)])
        await store.loadMore()
        let more = store.section(expanded: false)
        #expect(store.hasMore && more.fold.togglesFold && !more.fold.expanded && !more.showsEarlier, "여섯 줄이 되어 접히면 펴기 전에는 없다")
        #expect(store.section(expanded: true).showsEarlier)
        let short = Fake()
        short.setPages([rows(1...2)])
        let (lone, _, _) = make(short, pageSize: 3)
        await lone.refresh()
        #expect(!lone.hasMore && !lone.section(expanded: false).showsEarlier, "더 없으면 없다")
    }

    @Test func theSectionFoldsToThreeAndOffersShowEarlierOnlyWhenOpenAndThereIsMore() async {
        let fake = Fake()
        fake.setPages([rows(1...20)])
        let (store, _, _) = make(fake)
        await store.refresh()
        let folded = store.section(expanded: false)
        #expect(folded.state == .rows && folded.fold.visible.count == 3 && folded.fold.togglesFold && !folded.showsEarlier, "접혀 있으면 Show earlier는 없다")
        let open = store.section(expanded: true)
        #expect(open.fold.visible.count == 20 && open.fold.expanded && open.showsEarlier, "펴고 더 있으면 끝에 Show earlier")
        fake.setPages([rows(1...20), rows(21...22)])
        await store.loadMore()
        let end = store.section(expanded: true)
        #expect(end.fold.visible.count == 22 && !end.showsEarlier)
    }

    @Test func theSectionHasNoRowsWhileCheckingOrFailedAndOnlyItsState() async {
        let (store, _, _) = make()
        #expect(store.section(expanded: false) == SavedChatsSection(state: .checking, fold: SavedChatRules.fold([], expanded: false), showsEarlier: false))
    }

    // MARK: 계정 경계

    @Test func anAccountSwitchClearsTheListTheMoreFlagAndTheDeleteAllState() async {
        let fake = Fake()
        fake.setPages([rows(1...20)])
        fake.failDeleteAll([APIError.transport("offline")])
        let (store, _, scope) = make(fake)
        await store.refresh()
        await store.deleteAllChats()
        #expect(store.rows.count == 20 && store.hasMore && store.deleteAllState == .failed(.offline))
        scope.accountLeft()
        #expect(store.phase == .idle && store.rows.isEmpty && !store.hasMore && store.deleteAllState == .idle && store.sectionState == .checking, "다른 계정에 앞 계정의 대화가 남지 않는다")
    }

    @Test func aLateReadFromTheOldAccountIsNotShownAfterTheSwitch() async {
        // 읽기가 끝나기 전에 계정이 떠난다: 읽기를 막아 두었다가 풀면 그 줄이 새 계정 목록에 들어가지 않는다
        let gate = SavedChatsGate()
        let scope = AccountScope(currentAccount: { S.id(999) })
        let store = SavedChatsStore(
            scope: scope, readPage: { _, _ in await gate.wait(); return (1...3).map { S.row($0) } }, readMessages: { _, _, _ in [] }, deleteChat: { _ in }, deleteAll: {}, pageSize: 20
        )
        let read = Task { await store.refresh() }
        await settle()
        scope.accountLeft()
        await gate.open()
        await read.value
        #expect(store.rows.isEmpty && store.phase == .idle, "계정이 바뀐 뒤 늦게 온 읽기는 버린다")
    }

    // MARK: 하나 지우기 (바로 지운다: Undo 없음)

    @Test func deleteSendsTheRequestNowAndRemovesTheRowOnSuccess() async {
        let fake = Fake()
        fake.setPages([rows(1...3)])
        let (store, _, _) = make(fake)
        await store.refresh()
        let outcome = await store.delete(S.id(2))
        #expect(outcome == .deleted)
        #expect(fake.deleted == [S.id(2)], "기다림 없이 바로 서버에 보낸다 (되돌리기 시간 없음)")
        #expect(store.rows.map(\.id) == [S.id(1), S.id(3)])
    }

    @Test func deleteIsSentWithoutAnyWaitingSoThereIsNoTimeToUndo() async {
        let fake = Fake()
        fake.setPages([rows(1...2)])
        let (store, _, _) = make(fake)
        await store.refresh()
        let running = Task { await store.delete(S.id(1)) }
        // 시계를 기다리지 않고 몇 번 양보하는 것만으로 서버에 가 있다: 되돌리기 시간(지연)이 끼어 있지 않다
        for _ in 0..<20 { await Task.yield() }
        #expect(fake.deleted == [S.id(1)], "지우기가 지연되지 않았다")
        #expect(await running.value == .deleted)
    }

    @Test func aNotFoundAnswerMeansItIsAlreadyGoneAndCountsAsDeleted() async {
        let fake = Fake()
        fake.setPages([rows(1...2)])
        fake.failDeletes([APIError.server(status: 404, code: .notFound, message: "x")])
        let (store, _, _) = make(fake)
        await store.refresh()
        #expect(await store.delete(S.id(1)) == .deleted)
        #expect(store.rows.map(\.id) == [S.id(2)], "다른 기기에서 이미 지운 대화도 줄이 빠진다")
    }

    @Test func aBusyRetryIsSentAgainOnceQuietlyAndThenSucceeds() async {
        let fake = Fake()
        fake.setPages([rows(1...2)])
        fake.failDeletes([APIError.server(status: 409, code: .busyRetry, message: "x")])
        let (store, _, _) = make(fake)
        await store.refresh()
        #expect(await store.delete(S.id(1)) == .deleted)
        #expect(fake.deleted == [S.id(1), S.id(1)], "한 번 조용히 다시 보낸다")
        #expect(store.rows.count == 1)
    }

    @Test func aBusyRetryIsNotSentAgainOnceTheAccountHasLeft() async {
        // 계정이 떠난 뒤 늦게 온 409로 앞 계정의 지우기를 새 로그인에서 다시 보내지 않는다
        let gate = SavedChatsGate(), counter = SavedChatsCounter()
        let scope = AccountScope(currentAccount: { S.id(999) })
        let store = SavedChatsStore(
            scope: scope, readPage: { _, _ in (1...2).map { S.row($0) } }, readMessages: { _, _, _ in [] },
            deleteChat: { _ in
                counter.hit()
                await gate.wait()
                throw APIError.server(status: 409, code: .busyRetry, message: "x")
            },
            deleteAll: {}, pageSize: 20
        )
        await store.refresh()
        let running = Task { await store.delete(S.id(1)) }
        for _ in 0..<40 { await Task.yield() }
        #expect(counter.count == 1)
        scope.accountLeft()
        await gate.open()
        let outcome = await running.value
        #expect(counter.count == 1, "계정이 바뀌었으니 다시 보내지 않는다")
        #expect(outcome == .failed(.generic))
    }

    @Test func aSecondBusyRetryIsAFailureWithTheGenericReasonAndTheRowStays() async {
        let fake = Fake()
        fake.setPages([rows(1...2)])
        let busy = APIError.server(status: 409, code: .busyRetry, message: "x")
        fake.failDeletes([busy, busy])
        let (store, _, _) = make(fake)
        await store.refresh()
        #expect(await store.delete(S.id(1)) == .failed(.generic))
        #expect(fake.deleted.count == 2 && store.rows.count == 2)
    }

    @Test func offlineAndOtherFailuresMapToTheApprovedReasonLines() async {
        let cases: [(any Error, AgentQuestionFailure)] = [
            (APIError.transport("offline"), .offline), (URLError(.notConnectedToInternet), .offline), (URLError(.networkConnectionLost), .offline),
            (APIError.server(status: 500, code: .internalError, message: "x"), .generic), (APIError.unexpectedStatus(502), .generic),
            (APIError.notSignedIn, .generic), (APIError.server(status: 401, code: .unauthorized, message: "x"), .generic), (APIError.decoding("x"), .generic),
        ]
        for (error, expected) in cases {
            let fake = Fake()
            fake.setPages([rows(1...1)])
            fake.failDeletes([error])
            let (store, _, _) = make(fake)
            await store.refresh()
            #expect(await store.delete(S.id(1)) == .failed(expected), "\(error)")
            #expect(store.rows.count == 1)
        }
        #expect(AgentQuestionFailure.offline.reason == "You're offline. Try again." && AgentQuestionFailure.generic.reason == "Something went wrong. Try again in a moment.")
    }

    @Test func pressingDeleteTwiceSendsOneRequest() async {
        let gate = SavedChatsGate()
        let counter = SavedChatsCounter()
        let scope = AccountScope(currentAccount: { S.id(999) })
        let store = SavedChatsStore(
            scope: scope, readPage: { _, _ in (1...2).map { S.row($0) } }, readMessages: { _, _, _ in [] }, deleteChat: { _ in counter.hit(); await gate.wait() }, deleteAll: {}, pageSize: 20
        )
        await store.refresh()
        let first = Task { await store.delete(S.id(1)) }
        await Task.yield()
        let second = Task { await store.delete(S.id(1)) }
        await Task.yield()
        await gate.open()
        let firstOutcome = await first.value
        let secondOutcome = await second.value
        #expect(firstOutcome == .deleted && secondOutcome == .deleted)
        #expect(counter.count == 1, "두 번 눌러도 한 번 지운다")
    }

    // MARK: 모두 지우기

    @Test func deleteAllClearsTheListWhenTheServerSaysOk() async {
        let fake = Fake()
        fake.setPages([rows(1...5)])
        let (store, _, _) = make(fake)
        await store.refresh()
        await store.deleteAllChats()
        #expect(fake.deleteAllCalls == 1)
        #expect(store.rows.isEmpty && !store.hasMore && store.deleteAllState == .idle && store.sectionState == .absent)
    }

    @Test func aFailedDeleteAllRereadsTheListAndKeepsTheFailureWithTheReason() async {
        let fake = Fake()
        fake.setPages([rows(1...5), rows(3...5)])
        fake.failDeleteAll([APIError.transport("offline")])
        let (store, _, _) = make(fake)
        await store.refresh()
        await store.deleteAllChats()
        #expect(store.deleteAllState == .failed(.offline), "\(store.deleteAllState)")
        #expect(store.rows.count == 3, "남은 것을 다시 읽어 보인다")
        store.dismissDeleteAllFailure()
        #expect(store.deleteAllState == .idle)
    }

    @Test func aFailedDeleteAllWhoseRereadIsEmptyEverythingWasDeletedSoItIsSuccess() async {
        let fake = Fake()
        fake.setPages([rows(1...3), []])
        fake.failDeleteAll([APIError.server(status: 500, code: .internalError, message: "x")])
        let (store, _, _) = make(fake)
        await store.refresh()
        await store.deleteAllChats()
        #expect(store.deleteAllState == .idle && store.rows.isEmpty)
    }

    @Test func aBusyRetryOrAnyServerFailureOfDeleteAllIsOneFailureWithTryAgainNotASilentRetry() async {
        // 서버의 모두 지우기는 원자적이다: 409 `busy_retry`(잠금 경합 · 시간 초과) · 429 · 500은 아무것도 지우지 못한 실패다 → "Couldn't delete" + 이유 + Try again (조용히 다시 보내지 않는다)
        let cases: [(any Error, AgentQuestionFailure)] = [
            (APIError.server(status: 409, code: .busyRetry, message: "x"), .generic), (APIError.server(status: 429, code: .rateLimited, message: "x"), .generic),
            (APIError.server(status: 500, code: .internalError, message: "x"), .generic), (APIError.server(status: 401, code: .unauthorized, message: "x"), .generic),
            (APIError.server(status: 404, code: .notFound, message: "x"), .generic), (APIError.transport("offline"), .offline), (URLError(.notConnectedToInternet), .offline),
        ]
        for (error, expected) in cases {
            let fake = Fake()
            fake.setPages([rows(1...3), rows(1...3)])
            fake.failDeleteAll([error])
            let (store, _, _) = make(fake)
            await store.refresh()
            await store.deleteAllChats()
            #expect(fake.deleteAllCalls == 1, "한 번만 보낸다 (조용한 재시도 없음): \(error)")
            #expect(store.deleteAllState == .failed(expected) && store.rows.count == 3, "\(error)")
        }
    }

    @Test func deleteAllTryAgainSendsTheSameRequestAgainAfterAFailure() async {
        let again = Fake()
        again.setPages([rows(1...3), rows(1...3), []])
        again.failDeleteAll([APIError.transport("offline")])
        let (second, _, _) = make(again)
        await second.refresh()
        await second.deleteAllChats()
        #expect(second.deleteAllState == .failed(.offline))
        await second.deleteAllChats()
        #expect(again.deleteAllCalls == 2 && second.deleteAllState == .idle && second.rows.isEmpty, "Try again이 다시 보낸다")
    }

    @Test func pressingDeleteAllTwiceSendsOneRequest() async {
        let gate = SavedChatsGate()
        let counter = SavedChatsCounter()
        let scope = AccountScope(currentAccount: { S.id(999) })
        let store = SavedChatsStore(
            scope: scope, readPage: { _, _ in (1...2).map { S.row($0) } }, readMessages: { _, _, _ in [] }, deleteChat: { _ in }, deleteAll: { counter.hit(); await gate.wait() }, pageSize: 20
        )
        await store.refresh()
        let first = Task { await store.deleteAllChats() }
        await Task.yield()
        #expect(store.deleteAllState == .deleting)
        await store.deleteAllChats()
        await gate.open()
        await first.value
        #expect(counter.count == 1)
    }

    // MARK: 로그: 코드뿐

    @Test func logsCarryOnlyCodesNeverTitlesOrIds() async {
        let logged = Mutex<[String]>([])
        let fake = Fake()
        fake.setPages([[S.row(1, title: "Secret pricing plan")]])
        fake.failDeletes([APIError.transport("https://x/api/v2/claude-app-chats/\(S.id(1))")])
        let (store, _, _) = make(fake, log: { event, code in logged.withLock { $0.append("\(event) \(code)") } })
        await store.refresh()
        fake.failReads(with: URLError(.timedOut))
        await store.refresh()
        fake.failReads(with: nil)
        _ = await store.delete(S.id(1))
        let text = logged.withLock { $0.joined(separator: "\n") }
        #expect(!text.isEmpty, "실패는 코드로 남긴다")
        #expect(!text.contains("Secret") && !text.contains(S.id(1).uuidString.lowercased()) && !text.contains("https"), "\(text)")
    }
}

/// 시험이 풀 때까지 기다리게 하는 문
actor SavedChatsGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

final class SavedChatsCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func hit() { lock.withLock { value += 1 } }
}
