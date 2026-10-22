#if os(macOS) && DEBUG
import Darwin
import Foundation
import Testing
@testable import TaskforceKit

extension ExternalSessionSuites {
    /// 데스크톱 세션의 살아 있음 · 믿음(DT1 · DT3의 Kit 몫)과 상태 원천 맞춰 보기 (PR-D1 Kit, 계약 21.2 DR-S1a): 등록 파일 A를 1초마다, 시작 때와 60초마다
    /// `claude agents --json`과 맞춰 보고, 다르거나 키가 없으면 맞을 때까지 B(agents-json 폴링). **`poll()`은 agents 프로세스를 기다리지 않는다**(맞춰 보기는 poller가 쥔 작업이 돌고 `settle()`이 끝나기를 기다린다).
    /// 간격 · 머무는 시간 · 캐시 나이는 단조 시간이다 (벽시계가 뒤로 가도 얼지 않는다). 시계 · 실행기는 가짜다
    struct ClaudeAppStatusPollerTests {
        typealias F = ExternalSessionFixture
        typealias A = ClaudeAppFixture
        let a = F.uuid(0xA1)
        let b = F.uuid(0xA2)
        let started = Date(timeIntervalSince1970: 1_799_990_000)
        var alive: ExternalSessionProcessFacts.Lookup { .present(start: started, uid: 501) }

        private func withHome<T>(_ body: (ExternalHome) async throws -> T) async throws -> T {
            let home = try ExternalHome()
            defer { home.cleanup() }
            return try await body(home)
        }

        private func write(_ home: ExternalHome, pid: Int, id: String, status: String? = "idle", waitingFor: String? = nil, entrypoint: String? = "claude-desktop", kind: String? = "interactive", procStart: Any? = nil) throws {
            try home.registry(
                pid: pid,
                json: A.registry(pid: pid, id: id, status: status, waitingFor: waitingFor, procStart: procStart ?? started.timeIntervalSince1970, entrypoint: entrypoint, kind: kind)
            )
        }

        private func poller(
            _ home: ExternalHome, clock: ClaudeAppClock, agents: ClaudeAppAgentsStub, lookups: [Int32: ExternalSessionProcessFacts.Lookup]? = nil, own: Set<Int32> = [],
            log: any BridgeLogSink = NoBridgeLog(), fileSystem: ExternalSessionFileSystem = .live
        ) -> ClaudeAppStatusPoller {
            ClaudeAppStatusPoller(
                fileSystem: fileSystem, sessionsDirectory: home.sessions, processFacts: A.facts(lookups: lookups ?? [100: alive, 101: alive, 102: alive]), ownPIDs: { own },
                agents: agents.runner, clock: { clock.now }, uptime: { clock.uptime }, log: log
            )
        }

        /// 한 번 폴하고(맞춰 볼 때가 됐으면 작업을 띄우고), 그 작업이 끝나기를 기다린 뒤, 결과가 반영된 폴을 돌려준다
        private func step(_ poller: ClaudeAppStatusPoller) async -> ClaudeAppStatusPoller.Poll {
            _ = await poller.poll()
            await poller.settle()
            return await poller.poll()
        }

        private func item(_ pid: Int32, _ id: String, _ state: ClaudeAppSessionState) -> ClaudeAgentsItem { ClaudeAgentsItem(pid: pid, sessionID: id, state: state) }

        private func states(_ poll: ClaudeAppStatusPoller.Poll) -> [String: ClaudeAppSessionState] { Dictionary(uniqueKeysWithValues: poll.sessions.map { ($0.id, $0.state) }) }

        // MARK: 시작 때와 60초마다 맞춰 본다

        @Test func theFirstPollReconcilesAtStartAndThenOnlyEveryMinute() async throws {
            try await withHome { home in
                try write(home, pid: 100, id: a, status: "busy")
                let clock = ClaudeAppClock()
                let agents = ClaudeAppAgentsStub([item(100, a, .busy)])
                let poller = poller(home, clock: clock, agents: agents)
                let first = await step(poller)
                #expect(agents.calls == 1, "시작 때 한 번")
                #expect(first.source == .registry && !first.mismatch && first.verified)
                for seconds: TimeInterval in [1, 29, 29] {
                    clock.advance(seconds)
                    _ = await step(poller)
                }
                #expect(agents.calls == 1, "59초 안에는 다시 맞추지 않는다")
                clock.advance(1)
                let again = await step(poller)
                #expect(agents.calls == 2, "60초가 되면 다시")
                #expect(again.source == .registry && again.verified)
            }
        }

        @Test func whileTheTwoAgreeTheStateComesFromTheRegistryAtEveryPoll() async throws {
            try await withHome { home in
                try write(home, pid: 100, id: a, status: "busy")
                let clock = ClaudeAppClock()
                let agents = ClaudeAppAgentsStub([item(100, a, .busy)])
                let poller = poller(home, clock: clock, agents: agents)
                #expect(await step(poller).sessions.map(\.state) == [.busy])
                clock.advance(1)
                try write(home, pid: 100, id: a, status: "waiting", waitingFor: "permission prompt")
                let waiting = await poller.poll()
                #expect(waiting.sessions.map(\.state) == [.waiting(.approval)], "1초 폴링은 등록 파일을 바로 읽는다")
                #expect(agents.calls == 1, "그 사이 `claude`를 다시 띄우지 않는다")
                clock.advance(1)
                try write(home, pid: 100, id: a, status: "idle")
                #expect(await poller.poll().sessions.map(\.state) == [.idle])
                #expect(agents.calls == 1)
            }
        }

        // MARK: poll()은 agents 프로세스를 기다리지 않는다 (코드 검토 P2)

        @Test func pollReturnsAtOnceWhileTheAgentsRunIsHeldAndNeverStartsASecondRun() async throws {
            try await withHome { home in
                try write(home, pid: 100, id: a, status: "busy")
                let agents = ClaudeAppAgentsStub([item(100, a, .busy)])
                agents.hold()
                let poller = poller(home, clock: ClaudeAppClock(), agents: agents)
                let finished = ClaudeAppFlag()
                let first = Task {
                    let result = await poller.poll()
                    finished.set()
                    return result
                }
                for _ in 0..<300 where !finished.isSet { try await Task.sleep(for: .milliseconds(10)) }
                let returned = finished.isSet
                if !returned { agents.release() } // 잘못된 코드가 기다리고 있어도 시험은 끝난다
                let firstResult = await first.value
                #expect(returned, "poll()은 붙잡힌 agents 실행을 기다리지 않고 돌아온다")
                #expect(firstResult.source == .registry && !firstResult.verified && firstResult.sessions.map(\.state) == [.busy], "그 사이에는 등록 파일의 값을 준다")
                for _ in 0..<300 where !agents.isHolding { try await Task.sleep(for: .milliseconds(10)) }
                #expect(agents.isHolding, "맞춰 보기는 poller가 쥔 작업으로 돈다")
                // 도는 동안 다시 폴해도 새 실행을 띄우지 않고 바로 돌아온다
                try write(home, pid: 100, id: a, status: "waiting", waitingFor: "input needed")
                let second = await poller.poll()
                #expect(agents.calls == 1)
                #expect(second.sessions.map(\.state) == [.waiting(.answer)])
                agents.release()
                await poller.settle()
                let after = await poller.poll()
                #expect(after.verified && after.source == .registry, "끝난 뒤의 폴이 결과를 반영한다")
                #expect(after.sessions.map(\.state) == [.waiting(.answer)])
                #expect(agents.calls == 1)
            }
        }

        // MARK: 어긋나면 B

        @Test func aMismatchSwitchesToAgentsPollingAndTheAgentsStatusIsShown() async throws {
            try await withHome { home in
                try write(home, pid: 100, id: a, status: "idle")
                let clock = ClaudeAppClock()
                let agents = ClaudeAppAgentsStub([item(100, a, .busy)])
                let poller = poller(home, clock: clock, agents: agents)
                let first = await step(poller)
                #expect(first.source == .agents && first.mismatch && !first.verified)
                #expect(first.sessions.map(\.state) == [.busy], "어긋나는 동안은 문서화된 원천의 값")
                #expect(first.sessions.allSatisfy { $0.statusUpdatedAt == nil }, "B의 상태에는 등록 파일의 시각을 붙이지 않는다 (그 시각은 이 값의 것이 아니다)")
                // B는 몇 초마다만 띄운다 (매초가 아니다)
                clock.advance(1)
                agents.set([item(100, a, .waiting(.answer))])
                #expect(await poller.poll().sessions.map(\.state) == [.busy], "다음 실행 전에는 지난 답")
                #expect(agents.calls == 1)
                clock.advance(2)
                let next = await step(poller)
                #expect(agents.calls == 2, "3초 뒤 다시")
                #expect(next.source == .agents && next.sessions.map(\.state) == [.waiting(.answer)])
                clock.advance(2)
                _ = await step(poller)
                #expect(agents.calls == 2, "아직 3초가 안 됐다")
            }
        }

        @Test func itGoesBackToTheRegistryWhenTheTwoAgreeAgain() async throws {
            try await withHome { home in
                try write(home, pid: 100, id: a, status: "idle")
                let clock = ClaudeAppClock()
                let agents = ClaudeAppAgentsStub([item(100, a, .busy)])
                let poller = poller(home, clock: clock, agents: agents)
                #expect(await step(poller).source == .agents)
                // 등록 파일이 문서의 값과 같아졌다 (같은 시각에 두 곳이 같다)
                try write(home, pid: 100, id: a, status: "busy")
                clock.advance(3)
                let back = await step(poller)
                #expect(back.source == .registry && !back.mismatch && back.verified)
                #expect(agents.calls == 2)
                // 다시 A: 다음 맞춰 보기는 60초 뒤
                clock.advance(30)
                _ = await step(poller)
                #expect(agents.calls == 2)
                clock.advance(30)
                _ = await step(poller)
                #expect(agents.calls == 3)
            }
        }

        @Test func aRegistryWithoutTheStatusKeyIsAMismatchWhenAgentsKnowsTheStatus() async throws {
            try await withHome { home in
                try write(home, pid: 100, id: a, status: nil)
                let agents = ClaudeAppAgentsStub([item(100, a, .waiting(.approval))])
                let result = await step(poller(home, clock: ClaudeAppClock(), agents: agents))
                #expect(result.source == .agents && result.mismatch)
                #expect(result.sessions.map(\.state) == [.waiting(.approval)], "키가 없어도 필요한 상태는 agents에서")
            }
        }

        @Test func aWaitReasonThatDiffersInKindIsAMismatchToo() async throws {
            try await withHome { home in
                try write(home, pid: 100, id: a, status: "waiting", waitingFor: "permission prompt")
                let result = await step(poller(home, clock: ClaudeAppClock(), agents: ClaudeAppAgentsStub([item(100, a, .waiting(.answer))])))
                #expect(result.source == .agents && result.mismatch)
            }
        }

        @Test func anAgentsItemWithoutAStatusProvesNothingAndNeverCausesAMismatch() async throws {
            try await withHome { home in
                try write(home, pid: 100, id: a, status: "busy")
                let result = await step(poller(home, clock: ClaudeAppClock(), agents: ClaudeAppAgentsStub([item(100, a, .unknown)])))
                #expect(result.source == .registry && !result.mismatch && !result.verified, "맞춰 볼 수 없다")
                #expect(result.sessions.map(\.state) == [.busy])
            }
        }

        @Test func inAgentsModeAnInconclusiveRunWithNothingMismatchedGoesBackToTheRegistry() async throws {
            try await withHome { home in
                try write(home, pid: 100, id: a, status: "idle")
                let clock = ClaudeAppClock()
                let agents = ClaudeAppAgentsStub([item(100, a, .busy)])
                let poller = poller(home, clock: clock, agents: agents)
                #expect(await step(poller).source == .agents)
                // 다음 답에는 맞춰 볼 항목이 없다 (상태 없는 항목): 어긋난 것도 없으니 B에 머물 까닭이 없다
                agents.set([item(100, a, .unknown)])
                clock.advance(3)
                let back = await step(poller)
                #expect(back.source == .registry && !back.mismatch && !back.verified)
                #expect(back.sessions.map(\.state) == [.idle], "등록 파일의 값으로 돌아온다")
            }
        }

        // MARK: 맞춰 볼 수 없을 때 · 유령

        @Test func ifTheAgentsListCannotBeReadTheRegistryStaysTheSourceUnverified() async throws {
            try await withHome { home in
                try write(home, pid: 100, id: a, status: "busy")
                let clock = ClaudeAppClock()
                let agents = ClaudeAppAgentsStub(nil)
                let poller = poller(home, clock: clock, agents: agents)
                let result = await step(poller)
                #expect(result.source == .registry && !result.mismatch && !result.verified)
                #expect(result.sessions.map(\.state) == [.busy], "원천을 못 맞춰 봐도 레일은 등록 파일로 간다")
                clock.advance(60)
                agents.set([item(100, a, .busy)])
                #expect(await step(poller).verified, "나중에 읽히면 맞춰 본다")
            }
        }

        @Test func aSessionThatAgentsSucceededWithoutListingButBothRegistryReadsHaveIsAGhost() async throws {
            try await withHome { home in
                try write(home, pid: 100, id: a, status: "busy")
                try write(home, pid: 101, id: b, status: "busy")
                let clock = ClaudeAppClock()
                let agents = ClaudeAppAgentsStub([item(101, b, .busy)])
                let poller = poller(home, clock: clock, agents: agents)
                let result = await step(poller)
                #expect(states(result)[a] == .unknown, "문서화된 목록이 모르는 세션의 등록 파일은 믿지 않는다 (유령)")
                #expect(states(result)[b] == .busy)
                #expect(result.source == .registry && result.verified, "유령 하나가 나머지를 B로 보내지 않는다")
                // 다음 맞춰 보기 전에는 그대로, 목록에 올라오면 돌아온다
                clock.advance(1)
                #expect(states(await poller.poll())[a] == .unknown)
                agents.set([item(100, a, .busy), item(101, b, .busy)])
                clock.advance(59)
                #expect(states(await step(poller))[a] == .busy)
            }
        }

        @Test func aSessionThatAppearedWhileAgentsWasRunningIsNotAGhost() async throws {
            try await withHome { home in
                try write(home, pid: 100, id: a, status: "busy")
                let agents = ClaudeAppAgentsStub([item(100, a, .busy)])
                // 실행되는 사이 새 세션이 등록됐다: 실행 전 읽기에는 없었으니 agents가 모르는 것이 당연하다
                agents.onRun { try? self.write(home, pid: 101, id: self.b, status: "busy") }
                let result = await step(poller(home, clock: ClaudeAppClock(), agents: agents))
                #expect(states(result)[b] == .busy)
            }
        }

        @Test func aChangeDuringTheAgentsRunIsNotAMismatch() async throws {
            try await withHome { home in
                try write(home, pid: 100, id: a, status: "idle")
                let agents = ClaudeAppAgentsStub([item(100, a, .busy)])
                // 실행되는 사이 등록 파일이 busy로 바뀐다: 답(busy)은 실행 뒤의 값과 같다
                agents.onRun { try? home.registry(pid: 100, json: A.registry(pid: 100, id: self.a, status: "busy", procStart: self.started.timeIntervalSince1970)) }
                let after = await step(poller(home, clock: ClaudeAppClock(), agents: agents))
                #expect(after.source == .registry && !after.mismatch && after.verified)
            }
            try await withHome { home in
                try write(home, pid: 100, id: a, status: "idle")
                let agents = ClaudeAppAgentsStub([item(100, a, .idle)])
                // 반대로: 답(idle)은 실행 전의 값과 같고 그 사이 busy로 바뀌었다
                agents.onRun { try? home.registry(pid: 100, json: A.registry(pid: 100, id: self.a, status: "busy", procStart: self.started.timeIntervalSince1970)) }
                let before = await step(poller(home, clock: ClaudeAppClock(), agents: agents))
                #expect(before.source == .registry && !before.mismatch && before.verified)
            }
        }

        @Test func aMismatchOnOneSessionSwitchesEvenWhenAnotherAgrees() async throws {
            try await withHome { home in
                try write(home, pid: 100, id: a, status: "busy")
                try write(home, pid: 101, id: b, status: "idle")
                let agents = ClaudeAppAgentsStub([item(100, a, .busy), item(101, b, .waiting(.approval))])
                let result = await step(poller(home, clock: ClaudeAppClock(), agents: agents))
                #expect(result.source == .agents && result.mismatch)
                #expect(Set(result.sessions.map(\.state)) == [.busy, .waiting(.approval)])
            }
        }

        // MARK: agents는 줄을 만들지 못한다

        @Test func theAgentsListNeverAddsASessionTheRegistryDoesNotVouchFor() async throws {
            try await withHome { home in
                try write(home, pid: 100, id: a, status: "idle")
                // 등록 파일에 없는 세션 · 등록의 pid와 다른 pid로 나온 항목
                let agents = ClaudeAppAgentsStub([item(100, a, .busy), item(555, F.uuid(0xEE), .busy), item(999, b, .busy)])
                try write(home, pid: 101, id: b, status: "idle")
                let result = await step(poller(home, clock: ClaudeAppClock(), agents: agents))
                #expect(result.source == .agents)
                #expect(result.sessions.map(\.id).sorted() == [a, b].sorted(), "줄은 등록 파일 + 살아 있음이 정한다")
                #expect(states(result)[a] == .busy)
                #expect(states(result)[b] == .unknown, "pid가 다른 항목은 그 세션의 상태가 아니다")
            }
        }

        @Test func twoAgentsItemsForOneIDLeaveItUnknown() async throws {
            try await withHome { home in
                try write(home, pid: 100, id: a, status: "idle")
                let agents = ClaudeAppAgentsStub([item(100, a, .busy), item(100, a, .idle)])
                let result = await step(poller(home, clock: ClaudeAppClock(), agents: agents))
                #expect(result.sessions.map(\.state).allSatisfy { $0 == .idle }, "둘 중 하나는 거짓이다: 맞춰 보지 않고 등록 값을 쓴다")
                #expect(result.source == .registry && !result.mismatch)
            }
        }

        @Test func inAgentsModeTwoItemsForOneIDLeaveItsStateUnknown() async throws {
            try await withHome { home in
                try write(home, pid: 100, id: a, status: "idle")
                try write(home, pid: 101, id: b, status: "idle")
                let clock = ClaudeAppClock()
                // b가 어긋나 B로 간다. a는 항목이 둘: 어느 쪽이 맞는지 모른다 (B에서도 첫 항목을 고르지 않는다)
                let agents = ClaudeAppAgentsStub([item(100, a, .busy), item(100, a, .idle), item(101, b, .busy)])
                let poller = poller(home, clock: clock, agents: agents)
                let result = await step(poller)
                #expect(result.source == .agents)
                #expect(states(result)[a] == .unknown)
                #expect(states(result)[b] == .busy)
            }
        }

        @Test func aLaterFailureToReadTheAgentsListMakesTheRegistryUnverifiedAgain() async throws {
            try await withHome { home in
                try write(home, pid: 100, id: a, status: "busy")
                let clock = ClaudeAppClock()
                let agents = ClaudeAppAgentsStub([item(100, a, .busy)])
                let poller = poller(home, clock: clock, agents: agents)
                #expect(await step(poller).verified)
                agents.set(nil)
                clock.advance(60)
                let later = await step(poller)
                #expect(!later.verified && later.source == .registry && !later.mismatch, "맞춰 본 것이 지금도 맞다고 말하지 않는다")
            }
        }

        @Test func inAgentsModeWithoutAnyAnswerNothingIsOnTheRailButNothingCrashes() async throws {
            try await withHome { home in
                try write(home, pid: 100, id: a, status: "idle")
                let clock = ClaudeAppClock()
                let agents = ClaudeAppAgentsStub([item(100, a, .busy)])
                let poller = poller(home, clock: clock, agents: agents)
                #expect(await step(poller).source == .agents)
                agents.set(nil)
                clock.advance(3)
                let none = await step(poller)
                #expect(none.source == .agents)
                #expect(none.sessions.map(\.state) == [.unknown], "어긋난 등록 파일을 믿지 않는다: 줄은 있고 상태는 모른다")
            }
        }

        // MARK: 단조 시간 · 오래된 캐시 · 물러나기 (코드 검토 P2 · P3)

        @Test func aBackwardWallClockDoesNotFreezeTheReconcileIntervalsInEitherSource() async throws {
            try await withHome { home in
                try write(home, pid: 100, id: a, status: "idle")
                let clock = ClaudeAppClock()
                let agents = ClaudeAppAgentsStub([item(100, a, .busy)])
                let poller = poller(home, clock: clock, agents: agents)
                #expect(await step(poller).source == .agents)
                // B: 벽시계가 한 시간 뒤로 갔다. 3초(단조)가 지나면 다시 부른다
                clock.jumpWall(by: -3600)
                clock.advance(3)
                _ = await step(poller)
                #expect(agents.calls == 2, "B의 간격은 단조 시간이다")
                // A로 돌아와도 같다
                try write(home, pid: 100, id: a, status: "busy")
                clock.jumpWall(by: -3600)
                clock.advance(3)
                #expect(await step(poller).source == .registry)
                let calls = agents.calls
                clock.jumpWall(by: -7200)
                clock.advance(60)
                _ = await step(poller)
                #expect(agents.calls == calls + 1, "A의 60초도 단조 시간이다")
                // 반대로 벽시계가 훌쩍 앞서가도 일찍 부르지 않는다
                clock.jumpWall(by: 86_400)
                clock.advance(10)
                _ = await step(poller)
                #expect(agents.calls == calls + 1)
            }
        }

        @Test func anAgentsAnswerInSourceBThatIsTooOldBecomesUnknown() async throws {
            try await withHome { home in
                try write(home, pid: 100, id: a, status: "idle")
                let clock = ClaudeAppClock()
                let agents = ClaudeAppAgentsStub([item(100, a, .busy)])
                let poller = poller(home, clock: clock, agents: agents)
                #expect(await step(poller).sessions.map(\.state) == [.busy])
                // 다음 실행이 끝나지 않는다 (프로세스가 붙잡혔다): 지난 답은 (간격 + 기한)의 두 배(16초)까지만 믿는다
                agents.hold()
                clock.advance(3)
                _ = await poller.poll()
                clock.advance(10)
                #expect(await poller.poll().sessions.map(\.state) == [.busy], "13초: 아직 믿는다")
                clock.advance(4)
                #expect(await poller.poll().sessions.map(\.state) == [.unknown], "17초: 너무 오래됐다")
                agents.release()
                await poller.settle()
            }
        }

        @Test func repeatedMismatchesBackOffUpToACap() async throws {
            try await withHome { home in
                try write(home, pid: 100, id: a, status: "idle")
                let clock = ClaudeAppClock()
                let agents = ClaudeAppAgentsStub([item(100, a, .busy)])
                let poller = poller(home, clock: clock, agents: agents)
                // 어긋남이 계속되면 간격이 3 · 3 · 6 · 12 · 15(상한)초로 벌어진다: 실행은 0 · 3 · 6 · 12 · 24 · 39 · 54초에
                let expected: [Int: Int] = [0: 1, 3: 2, 6: 3, 9: 3, 11: 3, 12: 4, 23: 4, 24: 5, 38: 5, 39: 6, 53: 6, 54: 7]
                var elapsed = 0
                for second in expected.keys.sorted() {
                    clock.advance(TimeInterval(second - elapsed))
                    elapsed = second
                    _ = await step(poller)
                    #expect(agents.calls == expected[second], "\(second)초")
                }
            }
        }

        // MARK: 맞춰 볼 것이 없으면 띄우지 않는다

        @Test func noLiveDesktopSessionMeansNoAgentsCallAndOneAppearingStartsOne() async throws {
            try await withHome { home in
                let clock = ClaudeAppClock()
                let agents = ClaudeAppAgentsStub([])
                let poller = poller(home, clock: clock, agents: agents)
                for _ in 0..<5 {
                    _ = await step(poller)
                    clock.advance(30)
                }
                // 데스크톱이 아닌 세션 · 끝난 프로세스의 남은 파일도 맞춰 볼 것이 아니다
                try write(home, pid: 101, id: b, status: "busy", entrypoint: "cli")
                try write(home, pid: 5000, id: F.uuid(0xA9), status: "busy")
                _ = await step(poller)
                #expect(agents.calls == 0, "살아 있는 데스크톱 세션이 없으면 `claude`를 띄우지 않는다")
                try write(home, pid: 100, id: a, status: "busy")
                agents.set([item(100, a, .busy)])
                let result = await step(poller)
                #expect(agents.calls == 1 && result.verified)
            }
        }

        // MARK: DT1 · DT3의 Kit 몫: 살아 있고 하나뿐인 데스크톱 등록만

        private func live(_ home: ExternalHome, lookups: [Int32: ExternalSessionProcessFacts.Lookup], own: Set<Int32> = [], uid: UInt32 = 501) -> ClaudeAppLiveSessions {
            ClaudeAppLiveSessions.read(
                fileSystem: .live, sessionsDirectory: home.sessions, facts: A.facts(lookups: lookups, uid: uid), ownPIDs: own, now: Date(timeIntervalSince1970: 1_800_000_000)
            )
        }

        @Test func twoLiveRegistryEntriesForOneIDAreNotTrusted() async throws {
            try await withHome { home in
                try write(home, pid: 100, id: a, status: "busy")
                try write(home, pid: 101, id: a, status: "busy")
                try write(home, pid: 102, id: b, status: "busy")
                let result = live(home, lookups: [100: alive, 101: alive, 102: alive])
                #expect(result.sessions.map(\.id) == [b], "같은 id를 내세운 둘은 어느 쪽도 믿지 않는다")
                #expect(result.doubled == [a], "두 곳에서 도는 것으로 알린다")
            }
        }

        @Test func aSecondEntryOfAnotherEntrypointForTheSameIDIsAlsoTwoPlaces() async throws {
            try await withHome { home in
                try write(home, pid: 100, id: a, status: "busy")
                try write(home, pid: 101, id: a, status: "busy", entrypoint: "cli")
                let result = live(home, lookups: [100: alive, 101: alive])
                #expect(result.sessions.isEmpty && result.doubled == [a])
            }
        }

        @Test func aDeadSecondEntryDoesNotMakeTheLiveOneDoubtful() async throws {
            try await withHome { home in
                try write(home, pid: 100, id: a, status: "busy")
                try write(home, pid: 101, id: a, status: "busy")
                let result = live(home, lookups: [100: alive])
                #expect(result.sessions.map(\.id) == [a] && result.doubled.isEmpty, "끝난 프로세스의 남은 파일은 쥔 곳이 아니다")
            }
        }

        @Test func aReusedPidOrAnotherUsersProcessIsNotLive() async throws {
            try await withHome { home in
                try write(home, pid: 100, id: a, status: "busy")
                try write(home, pid: 101, id: b, status: "busy")
                try write(home, pid: 102, id: F.uuid(0xA3), status: "busy")
                let result = live(home, lookups: [
                    100: .present(start: started.addingTimeInterval(500), uid: 501), // 같은 pid가 다른 시작 시각으로 다시 쓰였다 (procStart 어긋남)
                    101: .present(start: started, uid: 0), // 다른 사용자
                    102: .gone,
                ])
                #expect(result.sessions.isEmpty, "pid · uid · procStart가 맞지 않으면 살아 있는 세션이 아니다")
            }
        }

        @Test func theStartTimeToleranceIsTheSameOneSecondAsTheHoldLogic() async throws {
            try await withHome { home in
                try write(home, pid: 100, id: a, status: "busy")
                #expect(live(home, lookups: [100: .present(start: started.addingTimeInterval(0.9), uid: 501)]).sessions.map(\.id) == [a])
                #expect(live(home, lookups: [100: .present(start: started.addingTimeInterval(1.1), uid: 501)]).sessions.isEmpty)
            }
        }

        @Test func onlyTheClaudeDesktopEntrypointIsOnTheRail() async throws {
            try await withHome { home in
                try write(home, pid: 100, id: a, status: "busy")
                try write(home, pid: 101, id: b, status: "busy", entrypoint: "cli")
                try write(home, pid: 102, id: F.uuid(0xA3), status: "busy", entrypoint: "claude-vscode")
                try write(home, pid: 103, id: F.uuid(0xA4), status: "busy", entrypoint: nil)
                try write(home, pid: 104, id: F.uuid(0xA5), status: "busy", kind: "background")
                try write(home, pid: 105, id: F.uuid(0xA6), status: "busy", entrypoint: "sdk-cli")
                let facts = Dictionary(uniqueKeysWithValues: (100...105).map { (Int32($0), alive) })
                #expect(live(home, lookups: facts).sessions.map(\.id) == [a])
            }
        }

        @Test func ourOwnProcessesAreNotOnTheRail() async throws {
            try await withHome { home in
                try write(home, pid: 100, id: a, status: "busy")
                #expect(live(home, lookups: [100: alive], own: [100]).sessions.isEmpty)
                #expect(live(home, lookups: [100: alive]).sessions.map(\.id) == [a])
            }
        }

        @Test func aSymlinkedOrOversizedRegistryFileGivesNoSession() async throws {
            try await withHome { home in
                let outside = home.root + "/outside.json"
                try A.registry(pid: 100, id: a, status: "busy", procStart: started.timeIntervalSince1970).write(toFile: outside, atomically: false, encoding: .utf8)
                try home.link(home.sessions + "/100.json", to: outside)
                let big = A.registry(pid: 101, id: b, status: "busy") + String(repeating: " ", count: 70_000)
                try big.write(toFile: home.sessions + "/101.json", atomically: false, encoding: .utf8)
                let result = live(home, lookups: [100: alive, 101: alive])
                #expect(result.sessions.isEmpty)
                #expect(result.registryUnavailable, "읽을 수 있는 것이 하나도 없다")
            }
        }

        @Test func theSessionKeepsItsStatusTimeAndPidAndIsSortedByID() async throws {
            try await withHome { home in
                try write(home, pid: 101, id: b, status: "busy")
                try write(home, pid: 100, id: a, status: "waiting", waitingFor: "input needed")
                let result = live(home, lookups: [100: alive, 101: alive])
                #expect(result.sessions.map(\.id) == [a, b])
                #expect(result.sessions.map(\.pid) == [100, 101])
                #expect(result.sessions.map(\.state) == [.waiting(.answer), .busy])
                #expect(result.sessions.allSatisfy { $0.statusUpdatedAt == Date(timeIntervalSince1970: 1_800_000_000) })
            }
        }

        // MARK: 폴 비용: 바뀌지 않은 파일은 다시 읽지 않는다 (코드 검토 P3)

        @Test func betweenPollsOnlyTheKnownLiveDesktopFilesAndChangedOnesAreReadAgain() async throws {
            try await withHome { home in
                try write(home, pid: 100, id: a, status: "busy")
                try write(home, pid: 101, id: b, status: "busy", entrypoint: "cli")
                try write(home, pid: 102, id: F.uuid(0xA3), status: "idle")
                let recording = RecordingFileSystem()
                let clock = ClaudeAppClock()
                let agents = ClaudeAppAgentsStub([item(100, a, .busy)])
                let poller = poller(home, clock: clock, agents: agents, lookups: [100: alive, 101: alive], fileSystem: recording.fileSystem)
                _ = await step(poller)
                #expect(recording.reads.count >= 3, "처음에는 모두 읽는다")
                let mark = recording.reads.count
                clock.advance(1)
                let second = await poller.poll()
                let newReads = recording.reads[mark...].map(\.path)
                #expect(newReads == [home.sessions + "/100.json"], "바뀌지 않은 다른 파일은 다시 읽지 않고, 살아 있는 데스크톱 세션의 파일만 다시 읽는다: \(newReads.count)")
                #expect(second.sessions.map(\.id) == [a])
                // 다른 파일이 바뀌면(크기 · 수정 시각) 그것도 다시 읽는다
                try home.registry(pid: 101, json: A.registry(pid: 101, id: b, status: "idle", entrypoint: "cli", kind: "interactive") + " ")
                let mark2 = recording.reads.count
                clock.advance(1)
                _ = await poller.poll()
                #expect(Set(recording.reads[mark2...].map(\.path)) == [home.sessions + "/100.json", home.sessions + "/101.json"])
                // 새 파일(새 세션)은 읽는다
                try write(home, pid: 103, id: F.uuid(0xA4), status: "busy")
                let mark3 = recording.reads.count
                clock.advance(1)
                _ = await poller.poll()
                #expect(recording.reads[mark3...].map(\.path).contains(home.sessions + "/103.json"))
            }
        }

        // MARK: 관찰 · 값의 모양

        @Test func theLogCarriesOnlyTheSourceAndWhetherTheyDifferNeverAnIDOrFolderOrName() async throws {
            try await withHome { home in
                try write(home, pid: 100, id: a, status: "idle")
                let log = RecordingLog()
                let clock = ClaudeAppClock()
                let agents = ClaudeAppAgentsStub([item(100, a, .busy)])
                let poller = poller(home, clock: clock, agents: agents, log: log)
                _ = await step(poller)
                try write(home, pid: 100, id: a, status: "busy")
                clock.advance(3)
                _ = await step(poller)
                let events = log.events
                #expect(events.map(\.event) == ["claude_app_status", "claude_app_status"])
                #expect(events.map { $0.fields["source"] } == [.code("agents"), .code("registry")])
                #expect(events.map { $0.fields["mismatch"] } == [.count(1), .count(0)])
                for event in events {
                    #expect(Set(event.fields.keys) == ["source", "mismatch"])
                    let text = String(describing: event.fields)
                    #expect(!text.contains(A.cwdSentinel) && !text.contains(A.nameSentinel) && !text.contains(a))
                }
            }
        }

        @Test func thePollAndTheLiveSessionsPrintNoIDPidFolderOrName() async throws {
            try await withHome { home in
                try write(home, pid: 100, id: a, status: "busy")
                try write(home, pid: 101, id: b, status: "busy")
                try write(home, pid: 102, id: b, status: "busy", entrypoint: "cli")
                let liveSessions = live(home, lookups: [100: alive, 101: alive, 102: alive])
                #expect(liveSessions.doubled == [b])
                let poll = ClaudeAppStatusPoller.Poll(sessions: liveSessions.sessions, doubled: liveSessions.doubled, source: .registry, mismatch: false, verified: true, registryUnavailable: false)
                let one = item(100, a, .busy)
                for value in [String(describing: liveSessions), String(reflecting: liveSessions), String(describing: poll), String(reflecting: poll), String(describing: one), String(reflecting: one)] {
                    #expect(!value.contains(a) && !value.contains(b) && !value.contains(A.cwdSentinel) && !value.contains(A.nameSentinel) && !value.contains("100"), "\(value)")
                }
            }
        }

        @Test func anUnreadableRegistryGivesNoSessionsAndTheSourceStaysTheRegistry() async throws {
            try await withHome { home in
                try "not json".write(toFile: home.sessions + "/100.json", atomically: false, encoding: .utf8)
                let result = await step(poller(home, clock: ClaudeAppClock(), agents: ClaudeAppAgentsStub([])))
                #expect(result.sessions.isEmpty && result.registryUnavailable)
                #expect(result.source == .registry)
            }
        }
    }
}
#endif
