#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

/// 기록 읽기를 대신하는 가짜 (`ClaudeAppTranscriptSource`): 부른 것을 세고, 답을 줄줄이 정해 두고, 메인 스레드에서 불렸는지 본다
final class ClaudeAppTranscriptScript: ClaudeAppTranscriptSource, @unchecked Sendable {
    private let lock = NSLock()
    private var opens: [ClaudeAppTranscriptLoad] = []
    private var earliers: [ClaudeAppTranscriptLoad] = []
    private var newers: [ClaudeAppTranscriptUpdate] = []
    private var _openCalls = 0
    private var _earlierCalls = 0
    private var _newerCalls = 0
    private var _onMain = false
    private var gate: CheckedContinuation<Void, Never>?
    private var holdEarlier = false
    private var _earlierCursors: [ClaudeAppTranscriptCursor] = []
    private var subagentListings: [SubagentListing] = []
    private var _subagentCalls = 0
    private var _subagentSinces: [SubagentCursor?] = []

    /// "Show earlier"가 받은 커서들 (상한에서 앞 줄을 버렸을 때 그 자리를 가리키는지 본다)
    var earlierCursors: [ClaudeAppTranscriptCursor] { lock.withLock { _earlierCursors } }
    var openCalls: Int { lock.withLock { _openCalls } }
    var earlierCalls: Int { lock.withLock { _earlierCalls } }
    var newerCalls: Int { lock.withLock { _newerCalls } }
    /// 읽기가 한 번이라도 메인 스레드에서 불렸다 (파일 읽기는 메인 밖이어야 한다)
    var calledOnMain: Bool { lock.withLock { _onMain } }

    /// 하위 에이전트 메타 훑기가 줄줄이 줄 답 (다 쓰면 마지막 답이 "그대로"다: 한 번도 못 받았으면 폴더 없음)
    func queueSubagents(_ listing: SubagentListing...) { lock.withLock { subagentListings += listing } }
    var subagentCalls: Int { lock.withLock { _subagentCalls } }
    /// 훑을 때마다 받은 "마지막으로 본 폴더의 바뀐 시각"
    var subagentSinces: [SubagentCursor?] { lock.withLock { _subagentSinces } }

    func queueOpen(_ load: ClaudeAppTranscriptLoad...) { lock.withLock { opens += load } }
    func queueEarlier(_ load: ClaudeAppTranscriptLoad...) { lock.withLock { earliers += load } }
    func queueNewer(_ update: ClaudeAppTranscriptUpdate...) { lock.withLock { newers += update } }

    func open(sessionID: String, cwd: String?) -> ClaudeAppTranscriptLoad {
        lock.withLock {
            _openCalls += 1
            if Thread.isMainThread { _onMain = true }
            return opens.isEmpty ? .unreadable : opens.removeFirst()
        }
    }

    func earlier(_ cursor: ClaudeAppTranscriptCursor) -> ClaudeAppTranscriptLoad {
        lock.withLock {
            _earlierCalls += 1
            _earlierCursors.append(cursor)
            if Thread.isMainThread { _onMain = true }
            return earliers.isEmpty ? .unreadable : earliers.removeFirst()
        }
    }

    func newer(_ cursor: ClaudeAppTranscriptCursor) -> ClaudeAppTranscriptUpdate {
        lock.withLock {
            _newerCalls += 1
            if Thread.isMainThread { _onMain = true }
            return newers.isEmpty ? .turns([], cursor: cursor, hasMore: false) : newers.removeFirst()
        }
    }

    func subagents(sessionID: String, cwd: String?, since: SubagentCursor?) -> SubagentListing {
        lock.withLock {
            _subagentCalls += 1
            _subagentSinces.append(since)
            if Thread.isMainThread { _onMain = true }
            if !subagentListings.isEmpty { return subagentListings.removeFirst() }
            return _subagentCalls > 1 ? .unchanged : .missing
        }
    }

    static func turn(_ n: Int, _ kind: ClaudeAppTurn.Kind? = nil) -> ClaudeAppTurn {
        ClaudeAppTurn(id: "t\(n)", kind: kind ?? (n.isMultiple(of: 2) ? .assistant("a\(n)") : .user("u\(n)")))
    }

    static func page(_ turns: [ClaudeAppTurn], earlier: Bool = false, sessionID: String = ExternalSessionFixture.uuid(0xF1)) -> ClaudeAppTranscriptLoad {
        .page(ClaudeAppTranscriptPage(turns: turns, cursor: ClaudeAppTranscriptCursor(sessionID: sessionID), hasEarlier: earlier, skippedLines: 0))
    }
}

extension ExternalSessionSuites {
    /// 데스크톱 세션 보기(읽기 전용)의 대화 상태 (PR-D2, 계약 21.3 P4 · P5 · 21.4): 처음 열면 꼬리부터 마지막 200개, "Show earlier"로 앞쪽, 열려 있는 동안 1초마다 새 줄(라이브 꼬리),
    /// 못 읽으면 "Couldn't load this chat" + Try again. 읽기(파일)는 메인 밖에서 한다. **빈 쪽에 `hasEarlier`가 true여도 끝이 아니다** (D1 규칙). 실제 기록은 열지 않는다 (가짜)
    @MainActor
    struct ClaudeAppConversationTests {
        typealias F = ExternalSessionFixture
        typealias S = ClaudeAppTranscriptScript
        let id = F.uuid(0xF1)

        private func make(_ script: S, sleeper: ClaudeAppLoopSleeper = ClaudeAppLoopSleeper(), limit: Int = ClaudeAppConversation.maxTurns) -> ClaudeAppConversation {
            ClaudeAppConversation(sessionID: id, cwd: "/Users/tester/proj", source: script, turnLimit: limit, sleep: { await sleeper.sleep($0) })
        }

        /// 기록 파일 안의 자리(`lineOffset`)가 있는 줄: 상한에서 앞 줄을 버릴 때 "Show earlier"가 그 자리로 이어지는지 본다
        private func placed(_ n: Int, offset: Int64) -> ClaudeAppTurn {
            ClaudeAppTurn(id: "t\(n)", kind: n.isMultiple(of: 2) ? .assistant("a\(n)") : .user("u\(n)"), timestamp: nil, truncated: false, lineOffset: offset, toolUseID: nil)
        }

        private func cursor(earliest: Int64, covered: Int) -> ClaudeAppTranscriptCursor {
            ClaudeAppTranscriptCursor(
                sessionID: id, path: "/tmp/x.jsonl", created: Date(timeIntervalSince1970: 1_800_000_000), earliestOffset: earliest, nextOffset: 1000, coveredBytes: covered, discarding: false, peerIDs: []
            )
        }

        private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while !condition() {
                if ContinuousClock.now > deadline { return false }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return true
        }

        private func ids(_ conversation: ClaudeAppConversation) -> [String] { conversation.turns.map(\.id) }

        @Test func theNumbersAreTheDocumentedOnes() {
            #expect(ClaudeAppConversation.tailInterval == 1, "라이브 꼬리는 1초마다")
            #expect(ClaudeAppConversation.maxEmptyWindowsPerPress == 16, "한 번 누를 때 건너뛴 줄뿐인 창을 이만큼까지 넘어간다")
            #expect(ClaudeAppConversation.maxTurns == 1000, "메모리에 두는 줄은 1000개쯤까지 (보안 P3-4)")
        }

        // MARK: 처음 열기

        @Test func openingReadsTheTailOffTheMainThreadAndShowsTheTurnsOldestFirst() async {
            let script = S()
            script.queueOpen(S.page([S.turn(1), S.turn(2), S.turn(3)], earlier: true))
            let conversation = make(script)
            #expect(conversation.phase == .loading && conversation.turns.isEmpty)
            conversation.start()
            #expect(await eventually { conversation.phase == .ready })
            #expect(ids(conversation) == ["t1", "t2", "t3"] && conversation.hasEarlier)
            #expect(!script.calledOnMain, "파일 읽기는 메인 스레드에서 하지 않는다")
            conversation.stop()
        }

        @Test func anEmptyConversationIsReadyWithNothingToShow() async {
            let script = S()
            script.queueOpen(S.page([]))
            let conversation = make(script)
            conversation.start()
            #expect(await eventually { conversation.phase == .ready })
            #expect(conversation.turns.isEmpty && !conversation.hasEarlier)
            conversation.stop()
        }

        @Test func aTranscriptThatCannotBeReadIsFailedAndTryAgainReadsItAgain() async {
            let script = S()
            script.queueOpen(.unreadable, S.page([S.turn(1)]))
            let conversation = make(script)
            conversation.start()
            #expect(await eventually { conversation.phase == .failed })
            #expect(conversation.turns.isEmpty)
            conversation.retry()
            #expect(conversation.phase == .loading, "Try again은 곧바로 읽는 중이 된다")
            #expect(await eventually { conversation.phase == .ready })
            #expect(ids(conversation) == ["t1"])
            #expect(script.openCalls == 2)
            conversation.stop()
        }

        // MARK: 라이브 꼬리

        @Test func theLiveTailAppendsNewTurnsEverySecondAndKeepsTheOrder() async {
            let script = S()
            let sleeper = ClaudeAppLoopSleeper()
            script.queueOpen(S.page([S.turn(1)]))
            script.queueNewer(.turns([S.turn(2), S.turn(3)], cursor: ClaudeAppTranscriptCursor(sessionID: id), hasMore: false))
            let conversation = make(script, sleeper: sleeper)
            conversation.start()
            #expect(await eventually { sleeper.pending == 1 && script.newerCalls == 1 })
            #expect(ids(conversation) == ["t1", "t2", "t3"])
            #expect(sleeper.requested == [1])
            script.queueNewer(.turns([S.turn(4)], cursor: ClaudeAppTranscriptCursor(sessionID: id), hasMore: false))
            sleeper.fire()
            #expect(await eventually { script.newerCalls == 2 && ids(conversation).count == 4 })
            #expect(ids(conversation) == ["t1", "t2", "t3", "t4"])
            conversation.stop()
        }

        @Test func moreAvailableReadsTheNextWindowAtOnceWithoutWaiting() async {
            let script = S()
            let sleeper = ClaudeAppLoopSleeper()
            script.queueOpen(S.page([S.turn(1)]))
            script.queueNewer(
                .turns([S.turn(2)], cursor: ClaudeAppTranscriptCursor(sessionID: id), hasMore: true),
                .turns([S.turn(3)], cursor: ClaudeAppTranscriptCursor(sessionID: id), hasMore: false)
            )
            let conversation = make(script, sleeper: sleeper)
            conversation.start()
            #expect(await eventually { ids(conversation) == ["t1", "t2", "t3"] && sleeper.pending == 1 })
            #expect(sleeper.requested == [1], "남은 것이 있으면 잠들기 전에 바로 이어 읽는다")
            conversation.stop()
        }

        @Test func aTurnThatArrivesTwiceIsShownOnce() async {
            let script = S()
            let sleeper = ClaudeAppLoopSleeper()
            script.queueOpen(S.page([S.turn(1), S.turn(2)]))
            script.queueNewer(.turns([S.turn(2), S.turn(3)], cursor: ClaudeAppTranscriptCursor(sessionID: id), hasMore: false))
            let conversation = make(script, sleeper: sleeper)
            conversation.start()
            #expect(await eventually { ids(conversation) == ["t1", "t2", "t3"] })
            conversation.stop()
        }

        @Test func aFileThatShrankOrWasReplacedIsReadAgainFromTheTail() async {
            let script = S()
            let sleeper = ClaudeAppLoopSleeper()
            script.queueOpen(S.page([S.turn(1), S.turn(2)]), S.page([S.turn(10), S.turn(11)], earlier: true))
            script.queueNewer(.reset)
            let conversation = make(script, sleeper: sleeper)
            conversation.start()
            #expect(await eventually { ids(conversation) == ["t10", "t11"] })
            #expect(conversation.hasEarlier && conversation.phase == .ready)
            #expect(script.openCalls == 2)
            conversation.stop()
        }

        @Test func aTailThatBecomesUnreadableIsFailedWithTryAgain() async {
            let script = S()
            let sleeper = ClaudeAppLoopSleeper()
            script.queueOpen(S.page([S.turn(1)]), S.page([S.turn(1), S.turn(2)]))
            script.queueNewer(.unreadable)
            let conversation = make(script, sleeper: sleeper)
            conversation.start()
            #expect(await eventually { conversation.phase == .failed })
            #expect(await eventually { sleeper.pending == 0 }, "실패하면 꼬리를 멈춘다")
            conversation.retry()
            #expect(await eventually { conversation.phase == .ready && ids(conversation) == ["t1", "t2"] })
            conversation.stop()
        }

        /// 꼬리가 한 번 못 읽어 `failed`가 된 뒤 패널을 닫았다 다시 열면 이어서 따라간다: 꼬리를 읽는 데 성공하면 다시 `ready`다 (코드 검토 P3)
        @Test func aSuccessfulTailReadMakesAFailedConversationReadyAgain() async {
            let script = S()
            let sleeper = ClaudeAppLoopSleeper()
            script.queueOpen(S.page([S.turn(1)]))
            script.queueNewer(.unreadable, .turns([S.turn(2)], cursor: ClaudeAppTranscriptCursor(sessionID: id), hasMore: false))
            let conversation = make(script, sleeper: sleeper)
            conversation.start()
            #expect(await eventually { conversation.phase == .failed })
            conversation.stop()
            conversation.start()
            #expect(await eventually { script.newerCalls == 2 && ids(conversation) == ["t1", "t2"] })
            #expect(conversation.phase == .ready, "꼬리를 읽었으니 못 읽음이 아니다")
            conversation.stop()
        }

        // MARK: 메모리의 줄 수 상한 (보안 P3-4)

        @Test func theLiveTailKeepsAtMostTheLimitAndDropsTheOldestAndOffersShowEarlier() async {
            let script = S()
            let sleeper = ClaudeAppLoopSleeper()
            script.queueOpen(S.page([S.turn(1), S.turn(2), S.turn(3)]))
            script.queueNewer(.turns([S.turn(4), S.turn(5), S.turn(6)], cursor: ClaudeAppTranscriptCursor(sessionID: id), hasMore: false))
            let conversation = make(script, sleeper: sleeper, limit: 4)
            conversation.start()
            #expect(await eventually { script.newerCalls == 1 && ids(conversation).count == 4 })
            #expect(ids(conversation) == ["t3", "t4", "t5", "t6"], "넘친 만큼 오래된 줄부터 버린다")
            #expect(conversation.hasEarlier, "버린 앞이 있으니 Show earlier를 보인다")
            script.queueNewer(.turns([S.turn(7)], cursor: ClaudeAppTranscriptCursor(sessionID: id), hasMore: false))
            sleeper.fire()
            #expect(await eventually { ids(conversation) == ["t4", "t5", "t6", "t7"] }, "더 붙어도 상한을 넘지 않는다")
            conversation.stop()
        }

        @Test func aWindowUnderTheLimitIsNeverTrimmedAndHasNoEarlierOfItsOwn() async {
            let script = S()
            let sleeper = ClaudeAppLoopSleeper()
            script.queueOpen(S.page([S.turn(1), S.turn(2)]))
            script.queueNewer(.turns([S.turn(3), S.turn(4)], cursor: ClaudeAppTranscriptCursor(sessionID: id), hasMore: false))
            let conversation = make(script, sleeper: sleeper, limit: 4)
            conversation.start()
            #expect(await eventually { ids(conversation) == ["t1", "t2", "t3", "t4"] })
            #expect(!conversation.hasEarlier, "상한까지는 버리지 않는다")
            conversation.stop()
        }

        /// 위로 거슬러 읽는 중(맨 아래에 붙어 있지 않다)에는 위쪽 줄을 버리지 않는다: 읽던 글이 사라지거나 밀리지 않게. 맨 아래로 돌아오면 그때 맞춘다
        @Test func theLiveTailTrimsOnlyWhileThePanelIsPinnedToTheBottom() async {
            let script = S()
            let sleeper = ClaudeAppLoopSleeper()
            script.queueOpen(S.page([S.turn(1), S.turn(2), S.turn(3)]))
            script.queueNewer(.turns([S.turn(4), S.turn(5), S.turn(6)], cursor: ClaudeAppTranscriptCursor(sessionID: id), hasMore: false))
            let conversation = make(script, sleeper: sleeper, limit: 4)
            #expect(conversation.pinnedToBottom, "처음에는 맨 아래에 붙어 있다")
            conversation.pinnedToBottom = false
            conversation.start()
            #expect(await eventually { script.newerCalls == 1 && ids(conversation).count == 6 })
            #expect(ids(conversation) == ["t1", "t2", "t3", "t4", "t5", "t6"] && !conversation.hasEarlier, "맨 아래에 없으면 상한을 넘어도 버리지 않는다")
            conversation.pinnedToBottom = true
            #expect(ids(conversation) == ["t3", "t4", "t5", "t6"] && conversation.hasEarlier, "맨 아래로 돌아오면 상한에 맞춘다")
            conversation.stop()
        }

        /// 그래도 메모리는 막는다: 맨 아래에 없어도 상한의 두 배를 넘으면 오래된 줄을 버린다
        @Test func aWindowPastTwiceTheLimitIsTrimmedEvenWhileThePanelIsNotPinned() async {
            let script = S()
            let sleeper = ClaudeAppLoopSleeper()
            script.queueOpen(S.page([S.turn(1), S.turn(2), S.turn(3)]))
            script.queueNewer(.turns((4...9).map { S.turn($0) }, cursor: ClaudeAppTranscriptCursor(sessionID: id), hasMore: false))
            let conversation = make(script, sleeper: sleeper, limit: 4)
            conversation.pinnedToBottom = false
            conversation.start()
            #expect(await eventually { script.newerCalls == 1 && !ids(conversation).isEmpty && ids(conversation).last == "t9" })
            #expect(ids(conversation) == ["t6", "t7", "t8", "t9"] && conversation.hasEarlier, "9줄은 상한 4의 두 배(8)를 넘는다: 상한까지 줄인다")
            conversation.stop()
        }

        /// 버린 줄을 "Show earlier"가 다시 읽을 수 있어야 한다: 커서의 가장 앞 자리가 남은 가장 앞 줄로 옮겨 가고 (그 사이에 구멍이 없다), 버린 줄의 id는 다시 보일 수 있다
        @Test func droppingTheOldestMovesTheCursorSoShowEarlierReadsTheDroppedLinesAgain() async {
            let script = S()
            let sleeper = ClaudeAppLoopSleeper()
            script.queueOpen(.page(ClaudeAppTranscriptPage(
                turns: [placed(1, offset: 100), placed(2, offset: 200), placed(3, offset: 300)], cursor: cursor(earliest: 100, covered: 500), hasEarlier: true, skippedLines: 0
            )))
            script.queueNewer(.turns([placed(4, offset: 400), placed(5, offset: 500)], cursor: cursor(earliest: 100, covered: 500), hasMore: false))
            script.queueEarlier(S.page([S.turn(1), S.turn(2)], earlier: false))
            let conversation = make(script, sleeper: sleeper, limit: 3)
            conversation.start()
            #expect(await eventually { script.newerCalls == 1 && ids(conversation) == ["t3", "t4", "t5"] })
            conversation.showEarlier()
            #expect(await eventually { script.earlierCalls == 1 && !conversation.loadingEarlier })
            let sent = script.earlierCursors[0]
            #expect(sent.earliestOffset == 300, "남은 가장 앞 줄(t3)의 자리부터 앞을 읽는다")
            #expect(sent.coveredBytes == 300, "버린 줄의 몫(200바이트)은 읽기 총량에서 돌려받는다")
            #expect(ids(conversation) == ["t1", "t2", "t3", "t4", "t5"], "버린 줄이 다시 읽혀 앞에 붙는다 (중복으로 걸러지지 않는다)")
            conversation.stop()
        }

        @Test func stoppingEndsTheTailAndStartingAgainDoesNotReopenAReadyConversation() async {
            let script = S()
            let sleeper = ClaudeAppLoopSleeper()
            script.queueOpen(S.page([S.turn(1)]))
            let conversation = make(script, sleeper: sleeper)
            conversation.start()
            conversation.start()
            #expect(await eventually { sleeper.pending == 1 })
            #expect(script.openCalls == 1, "시작을 두 번 불러도 한 번만 연다")
            conversation.stop()
            #expect(await eventually { sleeper.pending == 0 })
            let calls = script.newerCalls
            sleeper.fire()
            try? await Task.sleep(for: .milliseconds(40))
            #expect(script.newerCalls == calls, "멈춘 뒤에는 읽지 않는다")
        }

        // MARK: Show earlier

        @Test func showEarlierPrependsTheOlderTurnsAndStopsOfferingWhenThereIsNoMore() async {
            let script = S()
            script.queueOpen(S.page([S.turn(5), S.turn(6)], earlier: true))
            script.queueEarlier(S.page([S.turn(3), S.turn(4)], earlier: true), S.page([S.turn(1), S.turn(2)], earlier: false))
            let conversation = make(script)
            conversation.start()
            #expect(await eventually { conversation.phase == .ready })
            conversation.showEarlier()
            #expect(await eventually { ids(conversation) == ["t3", "t4", "t5", "t6"] && !conversation.loadingEarlier })
            #expect(conversation.hasEarlier)
            conversation.showEarlier()
            #expect(await eventually { ids(conversation) == ["t1", "t2", "t3", "t4", "t5", "t6"] && !conversation.loadingEarlier })
            #expect(!conversation.hasEarlier, "처음까지 읽었으면 Show earlier는 없다")
            conversation.showEarlier()
            try? await Task.sleep(for: .milliseconds(30))
            #expect(script.earlierCalls == 2, "더 읽을 것이 없으면 읽지 않는다")
            conversation.stop()
        }

        @Test func anEmptyWindowThatHasMoreBeforeItIsNotTheEndSoItKeepsGoingUpToTheLimit() async {
            let script = S()
            script.queueOpen(S.page([S.turn(9)], earlier: true))
            script.queueEarlier(S.page([], earlier: true), S.page([], earlier: true), S.page([S.turn(7), S.turn(8)], earlier: true))
            let conversation = make(script)
            conversation.start()
            #expect(await eventually { conversation.phase == .ready })
            conversation.showEarlier()
            #expect(await eventually { ids(conversation) == ["t7", "t8", "t9"] && !conversation.loadingEarlier })
            #expect(script.earlierCalls == 3, "건너뛴 줄뿐인 창은 한 번 누른 안에서 넘어간다")
            #expect(conversation.hasEarlier)
        }

        @Test func aRunOfEmptyWindowsStopsAtTheLimitAndStillOffersShowEarlier() async {
            let script = S()
            script.queueOpen(S.page([S.turn(9)], earlier: true))
            for _ in 0..<(ClaudeAppConversation.maxEmptyWindowsPerPress + 5) { script.queueEarlier(S.page([], earlier: true)) }
            let conversation = make(script)
            conversation.start()
            #expect(await eventually { conversation.phase == .ready })
            conversation.showEarlier()
            #expect(await eventually { !conversation.loadingEarlier && script.earlierCalls == ClaudeAppConversation.maxEmptyWindowsPerPress })
            #expect(conversation.hasEarlier && ids(conversation) == ["t9"], "끝이 아니다: 다시 누르면 더 앞으로 간다")
        }

        @Test func showEarlierWhileItIsAlreadyLoadingDoesNotStartASecondRead() async {
            let script = S()
            script.queueOpen(S.page([S.turn(9)], earlier: true))
            script.queueEarlier(S.page([S.turn(8)], earlier: false))
            let conversation = make(script)
            conversation.start()
            #expect(await eventually { conversation.phase == .ready })
            conversation.showEarlier()
            conversation.showEarlier()
            #expect(await eventually { ids(conversation) == ["t8", "t9"] && !conversation.loadingEarlier })
            #expect(script.earlierCalls == 1)
        }

        @Test func anEarlierPageThatCannotBeReadIsFailed() async {
            let script = S()
            script.queueOpen(S.page([S.turn(9)], earlier: true))
            script.queueEarlier(.unreadable)
            let conversation = make(script)
            conversation.start()
            #expect(await eventually { conversation.phase == .ready })
            conversation.showEarlier()
            #expect(await eventually { conversation.phase == .failed })
        }

        // MARK: 값의 모양

        @Test func theConversationPrintsNoTextOrID() async {
            let script = S()
            script.queueOpen(S.page([S.turn(1, .user("SENTINEL-USER-TEXT")), S.turn(2, .assistant("SENTINEL-ASSISTANT-TEXT"))]))
            let conversation = make(script)
            conversation.start()
            #expect(await eventually { conversation.phase == .ready })
            for value in [String(describing: conversation), String(reflecting: conversation)] {
                #expect(!value.contains("SENTINEL") && !value.contains(id), "\(value)")
            }
            conversation.stop()
        }
    }
}
#endif
