import Foundation
import Synchronization
import Testing
@testable import TaskforceKit

/// 저장된 대화 하나를 읽는 보기의 상태 · 쪽 읽기 · 지우기 흐름 (D3v-m, DZ 시트 2 · 3): 읽기 전용, 지우기는 확인을 거쳐야 보내고 Undo가 없다
@MainActor
struct SavedChatDetailModelTests {
    typealias S = SavedChatSamples

    /// 메시지 전체(오래된 것부터)에서 `offset`부터 새 것 순으로 `limit`개를 돌려주는 가짜 읽기 (서버의 `order said_at.desc` + range)
    final class Chat: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [SavedChatMessageRecord]
        private var _calls: [(offset: Int, limit: Int)] = []
        private var _fail: (any Error)?
        private var _gate: SavedChatsGate?
        init(count: Int) {
            all = (1...max(count, 1)).prefix(count).map { S.messageRecord($0, role: $0.isMultiple(of: 2) ? "assistant" : "user", body: "m\($0)", at: Date(timeIntervalSince1970: 1_800_000_000 + Double($0) * 60), seq: Int64($0)) }
        }

        var calls: [(offset: Int, limit: Int)] { lock.withLock { _calls } }
        func fail(_ error: (any Error)?) { lock.withLock { _fail = error } }
        /// 읽기를 문이 열릴 때까지 붙잡는다 (nil이면 푼다)
        func hold(with gate: SavedChatsGate?) { lock.withLock { _gate = gate } }
        /// 다른 기기에서 지웠다: 말이 하나도 남지 않는다
        func removeAll() { lock.withLock { all = [] } }
        /// 모르는 역할의 말만 남는다 (더 새 서버의 새 역할)
        func replaceWithUnknownRoles() { lock.withLock { all = [S.messageRecord(1, role: "system", body: "x")] } }

        func read(_ offset: Int, _ limit: Int) async throws -> [SavedChatMessageRecord] {
            if let gate = lock.withLock({ _gate }) { await gate.wait() }
            return try lock.withLock {
                _calls.append((offset, limit))
                if let _fail { throw _fail }
                let newestFirst = Array(all.reversed())
                guard offset < newestFirst.count else { return [] }
                return Array(newestFirst[offset..<min(offset + limit, newestFirst.count)])
            }
        }
    }

    final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var _gone = 0, _deleted = 0
        var gone: Int { lock.withLock { _gone } }
        var deleted: Int { lock.withLock { _deleted } }
        func markGone() { lock.withLock { _gone += 1 } }
        func markDeleted() { lock.withLock { _deleted += 1 } }
    }

    private func make(
        chat: Chat, pageSize: Int = 40, cap: Int = 1000, deleteError: (any Error)? = nil, deleteHits: SavedChatsCounter = SavedChatsCounter(), sink: Sink = Sink(), deleteGate: SavedChatsGate? = nil
    ) -> (SavedChatDetailModel, SavedChatsStore) {
        let scope = AccountScope(currentAccount: { S.id(999) })
        let store = SavedChatsStore(
            scope: scope, readPage: { _, _ in [S.row(1)] }, readMessages: { _, o, l in try await chat.read(o, l) },
            deleteChat: { _ in
                deleteHits.hit()
                if let deleteGate { await deleteGate.wait() }
                if let deleteError { throw deleteError }
            },
            deleteAll: {}, pageSize: 20
        )
        let model = store.makeDetail(chat: S.row(1, title: "Pricing copy draft"), pageSize: pageSize, maxMessages: cap, onGone: { sink.markGone() }, onDeleted: { sink.markDeleted() })
        return (model, store)
    }

    // MARK: 읽기

    @Test func theNewestPageIsReadFirstAndShownOldestFirst() async {
        let chat = Chat(count: 5)
        let (model, _) = make(chat: chat, pageSize: 3)
        #expect(model.phase == .loading)
        await model.load()
        #expect(model.phase == .ready)
        #expect(model.messages.map(\.body) == ["m3", "m4", "m5"], "가장 새 셋을, 오래된 것이 위로")
        #expect(model.hasEarlier && !model.loadingEarlier)
        #expect(chat.calls.map(\.offset) == [0] && chat.calls.map(\.limit) == [3])
    }

    @Test func showEarlierPrependsTheOlderPageAndEndsOnAShortPage() async {
        let chat = Chat(count: 5)
        let (model, _) = make(chat: chat, pageSize: 3)
        await model.load()
        await model.showEarlier()
        #expect(model.messages.map(\.body) == ["m1", "m2", "m3", "m4", "m5"] && !model.hasEarlier, "짧은 쪽이면 더 이른 글이 없다")
        #expect(chat.calls.map(\.offset) == [0, 3])
        await model.showEarlier()
        #expect(chat.calls.count == 2, "더 없으면 읽지 않는다")
    }

    @Test func aChatThatFitsOnePageHasNoShowEarlier() async {
        let (model, _) = make(chat: Chat(count: 2), pageSize: 40)
        await model.load()
        #expect(model.messages.count == 2 && !model.hasEarlier)
    }

    @Test func aFailedReadIsTheCouldNotLoadStateAndRetryReadsAgain() async {
        let chat = Chat(count: 2)
        chat.fail(URLError(.notConnectedToInternet))
        let (model, _) = make(chat: chat)
        await model.load()
        #expect(model.phase == .failed && model.messages.isEmpty)
        chat.fail(nil)
        await model.retry().value
        #expect(model.phase == .ready && model.messages.count == 2)
    }

    @Test func aFailedShowEarlierKeepsWhatIsShownAndCanBeTriedAgain() async {
        let chat = Chat(count: 5)
        let (model, _) = make(chat: chat, pageSize: 3)
        await model.load()
        chat.fail(URLError(.timedOut))
        await model.showEarlier()
        #expect(model.phase == .ready && model.messages.count == 3 && model.hasEarlier && !model.loadingEarlier)
        chat.fail(nil)
        await model.showEarlier()
        #expect(model.messages.count == 5)
    }

    @Test func aChatWithNoMessagesWasDeletedElsewhereSoTheViewClosesOnce() async {
        let sink = Sink()
        let (model, _) = make(chat: Chat(count: 0), sink: sink)
        await model.load()
        #expect(model.phase == .gone && sink.gone == 1, "다른 기기에서 이미 지운 대화를 열어 둔 경우도 패널이 닫힌다")
    }

    @Test func aChatWhoseMessagesAreAllOfUnknownRolesIsNotGoneItJustShowsNothingYet() async {
        // 지운 대화와 모르는 역할만 있는 대화는 다르다: 비었는지는 받은 기록으로 본다 (거른 뒤 말이 아니다)
        let chat = Chat(count: 1), sink = Sink()
        chat.replaceWithUnknownRoles()
        let (model, _) = make(chat: chat, sink: sink)
        await model.load()
        #expect(model.phase == .ready && model.messages.isEmpty && sink.gone == 0, "읽은 기록이 있으면 대화는 있다")
    }

    // MARK: 다시 보일 때 다시 읽는다 (재검토 P1)

    private func settle() async {
        for _ in 0..<40 { await Task.yield() }
    }

    @Test func reloadStartsOverFromTheLoadingStateWithoutTheOldMessagesAndReadsTheNewestPageAgain() async {
        let chat = Chat(count: 5), gate = SavedChatsGate()
        let (model, _) = make(chat: chat, pageSize: 3)
        await model.load()
        #expect(model.messages.map(\.body) == ["m3", "m4", "m5"])
        chat.hold(with: gate)
        let reloading = model.reload()
        #expect(model.phase == .loading && model.messages.isEmpty && !model.hasEarlier, "부르는 즉시(읽기가 끝나기 전에) 메모리에 있던 옛 글을 비운다: 다시 보일 때 옛 글이 한 프레임도 보이지 않는다")
        await settle()
        #expect(model.phase == .loading && model.messages.isEmpty, "읽는 동안도")
        await gate.open()
        await reloading.value
        #expect(model.phase == .ready && model.messages.map(\.body) == ["m3", "m4", "m5"])
        #expect(chat.calls.map(\.offset) == [0, 0])
    }

    @Test func reloadOfAChatDeletedMeanwhileIsGoneAndClosesTheView() async {
        let chat = Chat(count: 2), sink = Sink()
        let (model, _) = make(chat: chat, sink: sink)
        await model.load()
        chat.removeAll()
        await model.reload().value
        #expect(model.phase == .gone && model.messages.isEmpty && sink.gone == 1, "다른 기기에서 지운 대화는 다시 읽을 때 드러난다")
    }

    @Test func reloadDiscardsALateShowEarlierThatStartedBeforeIt() async {
        let chat = Chat(count: 5), gate = SavedChatsGate()
        let (model, _) = make(chat: chat, pageSize: 3)
        await model.load()
        chat.hold(with: gate)
        let earlier = Task { await model.showEarlier() }
        await settle()
        let reloading = model.reload()
        await settle()
        await gate.open()
        await earlier.value
        await reloading.value
        #expect(model.messages.map(\.body) == ["m3", "m4", "m5"] && !model.loadingEarlier, "다시 읽기 전에 시작한 앞 쪽은 새 목록에 붙지 않는다")
    }

    @Test func theMessagesAreCappedSoAVeryLongChatCannotFillTheMemory() async {
        let chat = Chat(count: 10)
        let (model, _) = make(chat: chat, pageSize: 4, cap: 8)
        await model.load()
        await model.showEarlier()
        #expect(model.messages.count == 8 && !model.hasEarlier, "상한에 닿으면 더 이른 글을 읽지 않는다")
    }

    @Test func stoppingDiscardsALateRead() async {
        let gate = SavedChatsGate()
        let scope = AccountScope(currentAccount: { S.id(999) })
        let store = SavedChatsStore(
            scope: scope, readPage: { _, _ in [] }, readMessages: { _, _, _ in await gate.wait(); return [S.messageRecord(1)] }, deleteChat: { _ in }, deleteAll: {}, pageSize: 20
        )
        let model = store.makeDetail(chat: S.row(1), pageSize: 40, maxMessages: 1000, onGone: {}, onDeleted: {})
        let read = Task { await model.load() }
        await Task.yield()
        model.stop()
        await gate.open()
        await read.value
        #expect(model.messages.isEmpty, "닫은 보기에 늦은 답을 쓰지 않는다")
    }

    // MARK: 지우기: 확인 → 지우는 중 → 결과 (되돌리기 없음)

    @Test func deleteAsksFirstAndSendsNothingUntilTheCardIsConfirmed() async {
        let hits = SavedChatsCounter()
        let (model, _) = make(chat: Chat(count: 2), deleteHits: hits)
        await model.load()
        #expect(model.deleteState == .none)
        model.requestDelete()
        #expect(model.deleteState == .confirming)
        // 시간이 지나도(작업이 돌아도) 카드가 확인되기 전에는 아무것도 가지 않는다
        for _ in 0..<20 { await Task.yield() }
        #expect(model.deleteState == .confirming && hits.count == 0, "Delete를 눌러도 확인 카드가 먼저다: 바로 지우지 않는다")
        model.cancelDelete()
        for _ in 0..<20 { await Task.yield() }
        #expect(model.deleteState == .none && hits.count == 0)
    }

    @Test func confirmingWithoutAskingFirstDoesNothing() async {
        let hits = SavedChatsCounter()
        let (model, _) = make(chat: Chat(count: 2), deleteHits: hits)
        await model.load()
        await model.confirmDelete()
        #expect(hits.count == 0 && model.deleteState == .none, "확인 카드 없이는 지울 길이 없다")
    }

    @Test func confirmDeletesNowRemovesTheRowAndClosesTheView() async {
        let hits = SavedChatsCounter()
        let sink = Sink()
        let (model, store) = make(chat: Chat(count: 2), deleteHits: hits, sink: sink)
        await store.refresh()
        #expect(store.rows.count == 1)
        await model.load()
        model.requestDelete()
        await model.confirmDelete()
        #expect(hits.count == 1, "서버가 바로 지운다: 기다리는 시간 · Undo가 없다")
        #expect(sink.deleted == 1 && store.rows.isEmpty, "줄이 빠지고 보기가 닫힌다")
        #expect(model.deleteState == .none)
    }

    @Test func theConfirmedDeleteReachesTheServerWithoutAnyWaiting() async {
        let hits = SavedChatsCounter()
        let (model, store) = make(chat: Chat(count: 2), deleteHits: hits)
        await store.refresh()
        await model.load()
        model.requestDelete()
        let running = Task { await model.confirmDelete() }
        for _ in 0..<20 { await Task.yield() }
        #expect(hits.count == 1, "확인하면 기다림 없이 바로 간다 (되돌리기 시간 없음)")
        await running.value
    }

    @Test func aFailureShowsTheReasonAndTryAgainSendsItAgain() async {
        let hits = SavedChatsCounter()
        let (model, store) = make(chat: Chat(count: 2), deleteError: APIError.transport("offline"), deleteHits: hits)
        await store.refresh()
        await model.load()
        model.requestDelete()
        await model.confirmDelete()
        #expect(model.deleteState == .failed(.offline) && store.rows.count == 1, "지우지 못했다: 줄 · 보기가 그대로")
        await model.confirmDelete()
        #expect(hits.count == 2, "Try again이 같은 지우기를 다시 보낸다")
        model.cancelDelete()
        #expect(model.deleteState == .none)
    }

    @Test func pressingDeleteWhileItIsRunningSendsOnce() async {
        let gate = SavedChatsGate()
        let hits = SavedChatsCounter()
        let (model, store) = make(chat: Chat(count: 2), deleteHits: hits, deleteGate: gate)
        await model.load()
        model.requestDelete()
        let first = Task { await model.confirmDelete() }
        await Task.yield()
        #expect(model.deleteState == .deleting)
        await model.confirmDelete()
        model.cancelDelete()
        #expect(model.deleteState == .deleting, "지우는 중에는 취소로 되돌릴 수 없다")
        await gate.open()
        await first.value
        #expect(hits.count == 1)
        withExtendedLifetime(store) {}
    }

    @Test func requestingDeleteWhileAlreadyAskingDoesNotRestartTheCard() async {
        let (model, _) = make(chat: Chat(count: 2))
        await model.load()
        model.requestDelete()
        model.requestDelete()
        #expect(model.deleteState == .confirming)
    }
}
