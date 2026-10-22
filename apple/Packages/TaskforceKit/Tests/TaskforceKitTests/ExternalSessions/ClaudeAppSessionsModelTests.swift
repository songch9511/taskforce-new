#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

/// 손으로 돌리는 폴 · 잠들기 (시험이 순서를 정한다): 폴은 부를 때마다 다음 값을 돌려주고, `hold`면 `release()`까지 붙잡는다
final class ClaudeAppPollScript: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [ClaudeAppStatusPoller.Poll] = []
    private var last = ClaudeAppPollScript.poll([])
    private var _calls = 0
    private var _running = 0
    private var _maxRunning = 0
    private var holdNext = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    var calls: Int { lock.withLock { _calls } }
    /// 동시에 돈 폴의 최대 수: 폴은 한 번에 하나씩 차례로 부른다 (1이어야 한다)
    var maxRunning: Int { lock.withLock { _maxRunning } }

    static func poll(_ sessions: [ClaudeAppSession], doubled: Set<String> = [], unavailable: Bool = false) -> ClaudeAppStatusPoller.Poll {
        ClaudeAppStatusPoller.Poll(sessions: sessions, doubled: doubled, source: .registry, mismatch: false, verified: true, registryUnavailable: unavailable)
    }

    func serve(_ sessions: [ClaudeAppSession], doubled: Set<String> = [], unavailable: Bool = false) {
        lock.withLock { last = Self.poll(sessions, doubled: doubled, unavailable: unavailable) }
    }

    func hold() { lock.withLock { holdNext = true } }

    func release() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            holdNext = false
            defer { waiting = [] }
            return waiting
        }
        for continuation in pending { continuation.resume() }
    }

    var runner: @Sendable () async -> ClaudeAppStatusPoller.Poll {
        { [self] in
            let (value, held) = lock.withLock { () -> (ClaudeAppStatusPoller.Poll, Bool) in
                _calls += 1
                _running += 1
                _maxRunning = max(_maxRunning, _running)
                defer { holdNext = false }
                return (last, holdNext)
            }
            if held { await withCheckedContinuation { continuation in lock.withLock { waiting.append(continuation) } } }
            lock.withLock { _running -= 1 }
            return value
        }
    }
}

/// 루프의 잠들기: 깨우기 전에는 돌아오지 않는다. 취소하면 바로 돌아온다
final class ClaudeAppLoopSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [(id: UUID, delay: TimeInterval, continuation: CheckedContinuation<Void, Never>)] = []
    private var _requested: [TimeInterval] = []

    var requested: [TimeInterval] { lock.withLock { _requested } }
    var pending: Int { lock.withLock { waiters.count } }

    func sleep(_ delay: TimeInterval) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.withLock {
                    _requested.append(delay)
                    waiters.append((id, delay, continuation))
                }
                if Task.isCancelled { cancel(id) }
            }
        } onCancel: {
            cancel(id)
        }
    }

    private func cancel(_ id: UUID) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            guard let index = waiters.firstIndex(where: { $0.id == id }) else { return nil }
            return waiters.remove(at: index).continuation
        }
        continuation?.resume()
    }

    func fire() {
        let next = lock.withLock { () -> CheckedContinuation<Void, Never>? in waiters.isEmpty ? nil : waiters.removeFirst().continuation }
        next?.resume()
    }
}

extension ExternalSessionSuites {
    /// 레일 · Sessions 패널이 읽는 데스크톱 세션의 살아 있는 상태 (PR-D2, 계약 21.2 DR-S1a · 23장): 1초마다 차례로 폴하고, 레일 판정(`ClaudeAppRail`)에 기억을 이어 주고,
    /// 안 연 끝남(done)은 이 Mac에 저장해 다시 켠 뒤에도 남기고 열어 보면 지운다. 실제 `claude` · 실제 등록 파일은 부르지 않는다 (가짜 폴)
    @MainActor
    struct ClaudeAppSessionsModelTests {
        typealias F = ExternalSessionFixture
        let a = F.uuid(0xE1)
        let b = F.uuid(0xE2)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)

        private func session(_ id: String, _ state: ClaudeAppSessionState, pid: Int32 = 100) -> ClaudeAppSession {
            ClaudeAppSession(id: id, pid: pid, cwd: nil, procStart: nil, state: state, statusUpdatedAt: nil)
        }

        private func make(
            _ script: ClaudeAppPollScript, sleeper: ClaudeAppLoopSleeper = ClaudeAppLoopSleeper(), done: InMemoryClaudeAppDoneStore = InMemoryClaudeAppDoneStore(),
            clock: ClaudeAppClock = ClaudeAppClock(), scope: AccountScope? = nil
        ) -> ClaudeAppSessionsModel {
            ClaudeAppSessionsModel(
                poll: script.runner, scope: scope, done: done, now: { clock.now }, uptime: { clock.uptime }, sleep: { await sleeper.sleep($0) }
            )
        }

        private func kinds(_ model: ClaudeAppSessionsModel) -> [String: ClaudeAppRailEntry.Kind] { Dictionary(uniqueKeysWithValues: model.rail.map { ($0.id, $0.kind) }) }

        private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while !condition() {
                if ContinuousClock.now > deadline { return false }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return true
        }

        @Test func theNumbersAreTheDocumentedOnes() {
            #expect(ClaudeAppSessionsModel.pollInterval == 1, "레일이 있는 동안 1초마다 (DR-S1a)")
        }

        // MARK: 폴 → 세션 · 레일

        @Test func aPollFillsTheSessionsAndTheRailAndMarksTheFirstPoll() async {
            let script = ClaudeAppPollScript()
            script.serve([session(a, .busy), session(b, .waiting(.approval), pid: 101)], doubled: ["x"])
            let model = make(script)
            #expect(!model.hasPolled && model.sessions.isEmpty && model.rail.isEmpty)
            await model.pollOnce()
            #expect(model.hasPolled)
            #expect(Set(model.sessions.map(\.id)) == [a, b])
            #expect(kinds(model) == [a: .running, b: .needsYou(.approval)])
            #expect(model.doubled == ["x"])
            #expect(model.session(id: a)?.state == .busy && model.session(id: "nope") == nil)
        }

        @Test func anUnreadableRegistryIsSaidAndKeepsNothingOnTheRail() async {
            let script = ClaudeAppPollScript()
            script.serve([session(a, .busy)])
            let model = make(script)
            await model.pollOnce()
            #expect(!model.registryUnavailable)
            script.serve([], unavailable: true)
            await model.pollOnce()
            #expect(model.registryUnavailable && model.sessions.isEmpty && model.rail.isEmpty)
        }

        /// 등록 폴더를 읽을 수 없는 동안은 어떤 세션도 "안 보이는" 것이 아니라 "모르는" 것이다: 기억(끝남 표시)을 건드리지 않는다 (코드 검토 P2)
        @Test func anUnreadableRegistryDoesNotForgetAFinishedSessionAndItStaysStored() async {
            let script = ClaudeAppPollScript()
            let done = InMemoryClaudeAppDoneStore()
            let clock = ClaudeAppClock()
            script.serve([session(a, .busy, pid: 100)])
            let model = make(script, done: done, clock: clock)
            await model.pollOnce()
            clock.advance(1)
            script.serve([session(a, .idle, pid: 100)])
            await model.pollOnce()
            #expect(kinds(model) == [a: .done] && done.load()[a]?.pid == 100)
            let saves = done.saves
            // 읽을 수 없는 폴이 다섯 번 (기다리는 폴 수 `missingGrace`보다 많다)
            script.serve([], unavailable: true)
            for _ in 0..<5 { await model.pollOnce() }
            #expect(model.registryUnavailable && model.rail.isEmpty, "읽을 수 없는 동안은 아무것도 그리지 않는다")
            #expect(done.load()[a]?.pid == 100 && done.saves == saves, "저장해 둔 표시는 그대로이고 다시 쓰지도 않는다")
            // 다시 읽히면 같은 pid의 쉬는 세션: 끝난 링이 그대로 있고 저장도 그대로다
            script.serve([session(a, .idle, pid: 100)])
            await model.pollOnce()
            #expect(!model.registryUnavailable && kinds(model) == [a: .done])
            #expect(done.load()[a]?.pid == 100)
        }

        /// `stop()`은 루프의 표를 올린다: 폴이 도는 사이 루프가 멈췄으면 그 폴의 늦은 결과를 반영하지 않는다
        @Test func aLoopThatWasStoppedWhileAPollWasInFlightDropsThatPoll() async {
            let script = ClaudeAppPollScript()
            script.serve([session(a, .busy)])
            let model = make(script)
            script.hold()
            let inFlight = Task { await model.pollOnce() }
            #expect(await eventually { script.calls == 1 })
            model.stop()
            script.release()
            await inFlight.value
            #expect(!model.hasPolled && model.rail.isEmpty && model.sessions.isEmpty, "멈춘 뒤에 도착한 폴 결과는 반영하지 않는다 (코드 검토 P3)")
            // 다시 폴하면 정상으로 반영된다
            await model.pollOnce()
            #expect(model.hasPolled && kinds(model) == [a: .running])
        }

        // MARK: 끝남은 열어 볼 때까지

        @Test func aFinishedSessionStaysDoneUntilItIsOpenedAndItIsSavedForARelaunch() async {
            let script = ClaudeAppPollScript()
            let done = InMemoryClaudeAppDoneStore()
            let clock = ClaudeAppClock()
            script.serve([session(a, .busy, pid: 100), session(b, .busy, pid: 200)])
            let model = make(script, done: done, clock: clock)
            await model.pollOnce()
            clock.advance(1)
            script.serve([session(a, .idle, pid: 100), session(b, .busy, pid: 200)])
            await model.pollOnce()
            #expect(kinds(model) == [a: .done, b: .running])
            #expect(done.load().keys.sorted() == [a], "안 연 끝남만 저장한다")
            // 타이머가 없다
            clock.advance(3600)
            script.serve([session(a, .idle, pid: 100), session(b, .busy, pid: 200)])
            await model.pollOnce()
            #expect(kinds(model)[a] == .done)
            // 앱을 다시 켰다: 같은 저장본, 그 프로세스는 아직 쉬고 있다
            let relaunched = make(script, done: done, clock: ClaudeAppClock())
            script.serve([session(a, .idle, pid: 100)])
            await relaunched.pollOnce()
            #expect(kinds(relaunched) == [a: .done], "다시 켠 뒤에도 열어 보기 전까지 초록이다")
            // 열어 보면 그 자리에서 내리고 저장본에서도 지운다
            relaunched.markOpened(a)
            #expect(relaunched.rail.isEmpty, "다음 폴을 기다리지 않는다")
            #expect(done.load().isEmpty)
            await relaunched.pollOnce()
            #expect(relaunched.rail.isEmpty, "다시 오르지 않는다")
            let third = make(script, done: done, clock: ClaudeAppClock())
            await third.pollOnce()
            #expect(third.rail.isEmpty, "열어 본 것은 다시 켜도 남지 않는다")
        }

        @Test func aNewTurnReplacesTheDoneWithRunningAndItsFinishIsDoneAgain() async {
            let script = ClaudeAppPollScript()
            let clock = ClaudeAppClock()
            script.serve([session(a, .busy)])
            let model = make(script, clock: clock)
            await model.pollOnce()
            clock.advance(1)
            script.serve([session(a, .idle)])
            await model.pollOnce()
            #expect(kinds(model) == [a: .done])
            clock.advance(1)
            script.serve([session(a, .busy)])
            await model.pollOnce()
            #expect(kinds(model) == [a: .running])
            clock.advance(5)
            script.serve([session(a, .idle)])
            await model.pollOnce()
            #expect(kinds(model) == [a: .done])
        }

        @Test func aSessionTheUserIsViewingNeverShowsDoneWhenItFinishes() async {
            let script = ClaudeAppPollScript()
            let clock = ClaudeAppClock()
            script.serve([session(a, .busy), session(b, .busy, pid: 101)])
            let model = make(script, clock: clock)
            await model.pollOnce()
            model.setViewing(a)
            clock.advance(1)
            script.serve([session(a, .idle), session(b, .idle, pid: 101)])
            await model.pollOnce()
            #expect(kinds(model) == [b: .done], "보고 있던 a가 끝난 것은 알릴 일이 아니다")
            model.setViewing(nil)
            await model.pollOnce()
            #expect(kinds(model) == [b: .done], "다 본 뒤에도 a의 done은 생기지 않는다")
        }

        // MARK: 줄 · 패널이 쓰는 상태 말

        @Test func theLiveStatusIsWhatTheRowAndTheHeaderSayAndUnknownIsNone() async {
            let script = ClaudeAppPollScript()
            let clock = ClaudeAppClock()
            let c = F.uuid(0xE3), d = F.uuid(0xE4), e = F.uuid(0xE5)
            script.serve([session(a, .busy), session(b, .waiting(.approval), pid: 101), session(c, .waiting(.answer), pid: 102), session(d, .idle, pid: 103), session(e, .unknown, pid: 104)])
            let model = make(script, clock: clock)
            await model.pollOnce()
            #expect(model.liveStatus(for: a) == .running)
            #expect(model.liveStatus(for: b) == .needsApproval)
            #expect(model.liveStatus(for: c) == .needsAnswer)
            #expect(model.liveStatus(for: d) == .idle)
            #expect(model.liveStatus(for: e) == nil, "상태를 모르면 말하지 않는다")
            #expect(model.liveStatus(for: F.uuid(0xEF)) == nil, "살아 있지 않으면 없다")
            // 끝나면 done, 열어 보면 idle
            clock.advance(1)
            script.serve([session(a, .idle), session(b, .waiting(.approval), pid: 101), session(c, .waiting(.answer), pid: 102), session(d, .idle, pid: 103), session(e, .unknown, pid: 104)])
            await model.pollOnce()
            #expect(model.liveStatus(for: a) == .done)
            model.markOpened(a)
            #expect(model.liveStatus(for: a) == .idle)
        }

        @Test func theLiveStatusMapsToTheRingAndTheApprovedWords() {
            #expect(ClaudeAppLiveStatus.running.ring == .running && ClaudeAppLiveStatus.needsApproval.ring == .needsYou && ClaudeAppLiveStatus.needsAnswer.ring == .needsYou)
            #expect(ClaudeAppLiveStatus.done.ring == .done && ClaudeAppLiveStatus.idle.ring == .idle)
            #expect(ClaudeAppLiveStatus.running.word == "Running in Claude" && ClaudeAppLiveStatus.needsApproval.word == "Needs approval in Claude")
            #expect(ClaudeAppLiveStatus.needsAnswer.word == "Needs your answer in Claude" && ClaudeAppLiveStatus.done.word == "Done" && ClaudeAppLiveStatus.idle.word == "Idle")
            #expect(ClaudeAppLiveStatus.needsApproval.band == .approve && ClaudeAppLiveStatus.needsAnswer.band == .answer)
            #expect([ClaudeAppLiveStatus.running, .done, .idle].allSatisfy { $0.band == nil })
        }

        // MARK: 보고 있는 세션이 닫혔나 ("Closed in Claude")

        @Test func theViewedSessionIsClosedOnlyAfterItWasMissingForThreePollsInARow() async {
            let script = ClaudeAppPollScript()
            script.serve([session(a, .busy), session(b, .busy, pid: 101)])
            let model = make(script)
            await model.pollOnce()
            model.setViewing(a)
            #expect(!model.viewingClosed)
            script.serve([session(b, .busy, pid: 101)])
            for expected in [false, false, true] {
                await model.pollOnce()
                #expect(model.viewingClosed == expected, "한두 번 안 보이는 것은 읽기가 흔들린 것이다 (두 번까지 기다린다)")
            }
            // 다시 보이면 닫힘이 아니다
            script.serve([session(a, .idle), session(b, .busy, pid: 101)])
            await model.pollOnce()
            #expect(!model.viewingClosed)
        }

        @Test func aMissingPollInTheMiddleResetsTheCountAndAnUnreadableRegistryIsNeverClosed() async {
            let script = ClaudeAppPollScript()
            script.serve([session(a, .busy)])
            let model = make(script)
            await model.pollOnce()
            model.setViewing(a)
            script.serve([])
            await model.pollOnce()
            await model.pollOnce()
            script.serve([session(a, .busy)])
            await model.pollOnce()
            script.serve([])
            await model.pollOnce()
            await model.pollOnce()
            #expect(!model.viewingClosed, "두 번 안 보이다 보인 뒤의 두 번은 새로 센다")
            // 등록 폴더를 읽을 수 없는 동안은 닫혔는지 모른다: 세지 않는다
            script.serve([], unavailable: true)
            for _ in 0..<6 { await model.pollOnce() }
            #expect(!model.viewingClosed)
        }

        @Test func choosingAnotherSessionOrNoneForgetsTheClosedState() async {
            let script = ClaudeAppPollScript()
            script.serve([session(b, .busy, pid: 101)])
            let model = make(script)
            await model.pollOnce()
            model.setViewing(a)
            for _ in 0..<3 { await model.pollOnce() }
            #expect(model.viewingClosed)
            model.setViewing(b)
            #expect(!model.viewingClosed)
            model.setViewing(a)
            #expect(!model.viewingClosed, "다시 고르면 처음부터 센다")
            model.setViewing(nil)
            for _ in 0..<5 { await model.pollOnce() }
            #expect(!model.viewingClosed, "보는 세션이 없으면 닫힘도 없다")
        }

        @Test func openingAnIdleSessionThatWasNeverDoneChangesNothing() async {
            let script = ClaudeAppPollScript()
            script.serve([session(a, .idle)])
            let done = InMemoryClaudeAppDoneStore()
            let model = make(script, done: done)
            await model.pollOnce()
            model.markOpened(a)
            model.markOpened("not-a-known-session")
            #expect(model.rail.isEmpty && done.load().isEmpty && done.saves == 0)
        }

        @Test func theStoreIsOnlyWrittenWhenTheMarksChange() async {
            let script = ClaudeAppPollScript()
            let done = InMemoryClaudeAppDoneStore()
            let clock = ClaudeAppClock()
            script.serve([session(a, .busy)])
            let model = make(script, done: done, clock: clock)
            await model.pollOnce()
            #expect(done.saves == 0, "일하는 중에는 쓸 것이 없다")
            clock.advance(1)
            script.serve([session(a, .idle)])
            for _ in 0..<5 {
                await model.pollOnce()
                clock.advance(1)
            }
            #expect(done.saves == 1, "같은 표시를 1초마다 다시 쓰지 않는다")
        }

        @Test func leavingTheAccountClearsTheRailAndWhatWasSaved() async {
            let script = ClaudeAppPollScript()
            let done = InMemoryClaudeAppDoneStore()
            let clock = ClaudeAppClock()
            let user = UUID()
            let scope = AccountScope(currentAccount: { user })
            script.serve([session(a, .busy)])
            let model = make(script, done: done, clock: clock, scope: scope)
            await model.pollOnce()
            clock.advance(1)
            script.serve([session(a, .idle)])
            await model.pollOnce()
            #expect(!model.rail.isEmpty && !done.load().isEmpty)
            scope.accountLeft()
            #expect(model.rail.isEmpty && model.sessions.isEmpty && !model.hasPolled)
            #expect(done.load().isEmpty, "다른 계정에 옛 계정의 표시를 남기지 않는다")
            // 로그아웃 뒤의 폴이 옛 표시를 되살리지 않는다
            await model.pollOnce()
            #expect(model.rail.isEmpty)
        }

        // MARK: 끝남 표시의 주인 계정 (보안 P3-1)

        private let me = UUID(uuidString: "0B0B0B0B-0000-4000-8000-000000000002")!
        private let other = UUID(uuidString: "0A0A0A0A-0000-4000-8000-000000000001")!

        @Test func doneMarksOfAnotherAccountAreForgottenWhenThisAccountPolls() async {
            let script = ClaudeAppPollScript()
            let done = InMemoryClaudeAppDoneStore()
            done.save([a: ClaudeAppDoneMark(pid: 100, at: t0)])
            done.setOwner(other)
            script.serve([session(a, .idle, pid: 100)])
            let model = make(script, done: done, scope: AccountScope(currentAccount: { [me] in me }))
            await model.pollOnce()
            #expect(model.rail.isEmpty, "다른 계정의 끝남 표시는 이 계정의 링이 아니다")
            #expect(done.load().isEmpty && done.owner == me, "저장해 둔 것도 지우고 이 계정을 주인으로 적는다")
        }

        @Test func marksWithAnUnknownOwnerAreForgottenToo() async {
            let script = ClaudeAppPollScript()
            let done = InMemoryClaudeAppDoneStore()
            done.save([a: ClaudeAppDoneMark(pid: 100, at: t0)])
            script.serve([session(a, .idle, pid: 100)])
            let model = make(script, done: done, scope: AccountScope(currentAccount: { [me] in me }))
            await model.pollOnce()
            #expect(model.rail.isEmpty && done.load().isEmpty && done.owner == me, "주인을 모르는 표시는 이 계정의 것이라고 믿지 않는다")
        }

        @Test func marksOfThisAccountSurviveARelaunchAndTheOwnerStaysSet() async {
            let script = ClaudeAppPollScript()
            let done = InMemoryClaudeAppDoneStore()
            done.save([a: ClaudeAppDoneMark(pid: 100, at: t0)])
            done.setOwner(me)
            script.serve([session(a, .idle, pid: 100)])
            let model = make(script, done: done, scope: AccountScope(currentAccount: { [me] in me }))
            await model.pollOnce()
            #expect(kinds(model) == [a: .done] && done.load()[a]?.pid == 100 && done.owner == me)
        }

        @Test func aFreshStoreIsStampedWithTheAccountSoTheNextLaunchKeepsItsMarks() async {
            let script = ClaudeAppPollScript()
            let done = InMemoryClaudeAppDoneStore()
            let clock = ClaudeAppClock()
            script.serve([session(a, .busy, pid: 100)])
            let model = make(script, done: done, clock: clock, scope: AccountScope(currentAccount: { [me] in me }))
            await model.pollOnce()
            clock.advance(1)
            script.serve([session(a, .idle, pid: 100)])
            await model.pollOnce()
            #expect(done.load()[a]?.pid == 100 && done.owner == me)
            // 같은 계정으로 다시 켜면 표시가 남는다
            let relaunched = make(script, done: done, scope: AccountScope(currentAccount: { [me] in me }))
            await relaunched.pollOnce()
            #expect(kinds(relaunched) == [a: .done])
        }

        /// 셸이 계정을 알게 되면(처음 로그인) 폴을 기다리지 않고 부른다: 다른 계정의 표시는 그 자리에서 사라진다
        @Test func adoptingAnAccountDropsAnotherAccountsMarksAtOnce() async {
            let script = ClaudeAppPollScript()
            let done = InMemoryClaudeAppDoneStore()
            done.save([a: ClaudeAppDoneMark(pid: 100, at: t0)])
            done.setOwner(other)
            let model = make(script, done: done)
            model.adopt(account: me)
            #expect(done.load().isEmpty && done.owner == me)
            script.serve([session(a, .idle, pid: 100)])
            await model.pollOnce()
            #expect(model.rail.isEmpty, "되살릴 표시가 없다")
            model.adopt(account: me)
            #expect(done.owner == me, "같은 계정을 다시 알려도 아무 일이 없다")
        }

        @Test func leavingTheAccountForgetsTheOwnerToo() async {
            let script = ClaudeAppPollScript()
            let done = InMemoryClaudeAppDoneStore()
            let scope = AccountScope(currentAccount: { [me] in me })
            let model = make(script, done: done, scope: scope)
            model.adopt(account: me)
            #expect(done.owner == me)
            scope.accountLeft()
            #expect(done.owner == nil && done.load().isEmpty)
        }

        /// 폴이 도는 사이 계정이 떠났다: 그 폴의 늦은 결과(옛 계정의 세션)를 새 계정의 레일에 올리지 않는다
        @Test func aPollThatWasInFlightWhenTheAccountLeftIsDropped() async {
            let script = ClaudeAppPollScript()
            let done = InMemoryClaudeAppDoneStore()
            let user = UUID()
            let scope = AccountScope(currentAccount: { user })
            script.serve([session(a, .busy)])
            let model = make(script, done: done, scope: scope)
            script.hold()
            let inFlight = Task { await model.pollOnce() }
            #expect(await eventually { script.calls == 1 })
            scope.accountLeft()
            script.release()
            await inFlight.value
            #expect(model.rail.isEmpty && model.sessions.isEmpty && !model.hasPolled, "옛 계정의 늦은 폴 결과가 남지 않는다")
            #expect(done.load().isEmpty)
        }

        // MARK: 폴 루프

        @Test func theLoopPollsOneAtATimeAndWaitsOneSecondBetweenPolls() async {
            let script = ClaudeAppPollScript()
            let sleeper = ClaudeAppLoopSleeper()
            script.serve([session(a, .busy)])
            let model = make(script, sleeper: sleeper)
            model.start()
            #expect(await eventually { script.calls == 1 && sleeper.pending == 1 })
            #expect(sleeper.requested == [1])
            sleeper.fire()
            #expect(await eventually { script.calls == 2 && sleeper.pending == 1 })
            model.stop()
            #expect(script.maxRunning == 1, "폴은 한 번에 하나씩 차례로 부른다 (겹쳐 부르지 않는다)")
        }

        @Test func aSlowPollIsNeverOverlappedByTheNextOne() async {
            let script = ClaudeAppPollScript()
            let sleeper = ClaudeAppLoopSleeper()
            script.serve([session(a, .busy)])
            script.hold()
            let model = make(script, sleeper: sleeper)
            model.start()
            #expect(await eventually { script.calls == 1 })
            // 첫 폴이 붙잡힌 동안 잠들기는 시작하지 않는다 → 다음 폴도 없다
            try? await Task.sleep(for: .milliseconds(80))
            #expect(script.calls == 1 && sleeper.requested.isEmpty && script.maxRunning == 1)
            script.release()
            #expect(await eventually { sleeper.pending == 1 })
            model.stop()
            #expect(script.maxRunning == 1)
        }

        @Test func startTwiceRunsOneLoopAndStopEndsIt() async {
            let script = ClaudeAppPollScript()
            let sleeper = ClaudeAppLoopSleeper()
            script.serve([session(a, .busy)])
            let model = make(script, sleeper: sleeper)
            model.start()
            model.start()
            #expect(await eventually { script.calls == 1 && sleeper.pending == 1 })
            try? await Task.sleep(for: .milliseconds(40))
            #expect(script.calls == 1 && sleeper.pending == 1, "루프는 하나뿐이다")
            model.stop()
            #expect(await eventually { sleeper.pending == 0 })
            sleeper.fire()
            try? await Task.sleep(for: .milliseconds(40))
            #expect(script.calls == 1, "멈춘 뒤에는 폴하지 않는다")
            // 다시 시작할 수 있다
            model.start()
            #expect(await eventually { script.calls == 2 })
            model.stop()
        }

        @Test func aModelThatIsDroppedEndsItsLoop() async {
            let script = ClaudeAppPollScript()
            let sleeper = ClaudeAppLoopSleeper()
            script.serve([session(a, .busy)])
            weak var weakModel: ClaudeAppSessionsModel?
            do {
                let model = make(script, sleeper: sleeper)
                weakModel = model
                model.start()
                #expect(await eventually { sleeper.pending == 1 })
            }
            #expect(await eventually { weakModel == nil }, "루프가 모델을 붙잡지 않는다")
            sleeper.fire()
        }

        // MARK: 값의 모양

        @Test func theModelPrintsNoIDOrPid() async {
            let script = ClaudeAppPollScript()
            script.serve([session(a, .busy, pid: 4242)])
            let model = make(script)
            await model.pollOnce()
            for value in [String(describing: model), String(reflecting: model)] { #expect(!value.contains(a) && !value.contains("4242"), "\(value)") }
        }
    }
}

extension ExternalSessionSuites {
    /// 데스크톱 끝남 표시의 저장 (이 Mac에만: 세션 id · pid · 본 시각뿐)
    struct ClaudeAppDoneStoreTests {
        typealias F = ExternalSessionFixture
        let a = F.uuid(0xE1)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)

        @Test func theInMemoryStoreRoundTripsAndCountsWrites() {
            let store = InMemoryClaudeAppDoneStore()
            #expect(store.load().isEmpty && store.saves == 0)
            store.save([a: ClaudeAppDoneMark(pid: 100, at: t0)])
            #expect(store.load() == [a: ClaudeAppDoneMark(pid: 100, at: t0)] && store.saves == 1)
            store.clear()
            #expect(store.load().isEmpty)
        }

        @Test func theUserDefaultsStoreKeepsOneJSONKeyAndReadsItBackAfterARelaunch() throws {
            let defaults = FakeRailDefaults()
            UserDefaultsClaudeAppDoneStore(defaults: defaults).save([a: ClaudeAppDoneMark(pid: 100, at: t0)])
            #expect(defaults.keys == [UserDefaultsClaudeAppDoneStore.key])
            #expect(UserDefaultsClaudeAppDoneStore(defaults: defaults).load() == [a: ClaudeAppDoneMark(pid: 100, at: t0)])
            let data = try #require(defaults.object(forKey: UserDefaultsClaudeAppDoneStore.key) as? Data)
            let text = String(decoding: data, as: UTF8.self)
            for forbidden in ["cwd", "title", "name", "path"] { #expect(!text.contains(forbidden), "\(forbidden)") }
        }

        @Test func unreadableDataGivesNothingAndNeverCrashes() {
            let defaults = FakeRailDefaults()
            let store = UserDefaultsClaudeAppDoneStore(defaults: defaults)
            for bad: Any in [Data("nope".utf8), Data(), "text", 7, Data("[]".utf8), Data(#"{"x":{"pid":"a"}}"#.utf8)] {
                defaults.set(bad, forKey: UserDefaultsClaudeAppDoneStore.key)
                #expect(store.load().isEmpty, "\(type(of: bad))")
            }
        }

        @Test func clearLeavesNoSavedValue() {
            let defaults = FakeRailDefaults()
            let store = UserDefaultsClaudeAppDoneStore(defaults: defaults)
            store.save([a: ClaudeAppDoneMark(pid: 1, at: t0)])
            store.setOwner(UUID())
            store.clear()
            #expect(defaults.object(forKey: UserDefaultsClaudeAppDoneStore.key) == nil && store.load().isEmpty)
            #expect(defaults.keys.isEmpty && store.owner == nil, "주인도 함께 지운다")
        }

        /// 표시의 주인 계정 (보안 P3-1): 소문자 UUID 한 글자열이 따로 하나. 읽을 수 없으면 모른다(nil)
        @Test func theOwnerIsOneLowercaseUUIDStringAndUnreadableMeansUnknown() {
            let owner = UUID(uuidString: "0B0B0B0B-0000-4000-8000-000000000002")!
            let memory = InMemoryClaudeAppDoneStore()
            #expect(memory.owner == nil)
            memory.setOwner(owner)
            #expect(memory.owner == owner)
            memory.setOwner(nil)
            #expect(memory.owner == nil)
            let defaults = FakeRailDefaults()
            let store = UserDefaultsClaudeAppDoneStore(defaults: defaults)
            store.setOwner(owner)
            #expect(defaults.keys == [UserDefaultsClaudeAppDoneStore.ownerKey])
            #expect(defaults.object(forKey: UserDefaultsClaudeAppDoneStore.ownerKey) as? String == owner.uuidString.lowercased())
            #expect(UserDefaultsClaudeAppDoneStore(defaults: defaults).owner == owner, "다시 켠 뒤에도 읽는다")
            for bad: Any in ["nope", 7, Data("x".utf8), ""] {
                defaults.set(bad, forKey: UserDefaultsClaudeAppDoneStore.ownerKey)
                #expect(store.owner == nil, "\(type(of: bad))")
            }
            store.setOwner(nil)
            #expect(defaults.object(forKey: UserDefaultsClaudeAppDoneStore.ownerKey) == nil)
        }
    }
}
#endif
