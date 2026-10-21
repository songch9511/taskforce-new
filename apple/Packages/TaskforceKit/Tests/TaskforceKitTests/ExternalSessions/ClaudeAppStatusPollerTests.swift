#if os(macOS) && DEBUG
import Darwin
import Foundation
import Testing
@testable import TaskforceKit

extension ExternalSessionSuites {
    /// 데스크톱 세션의 살아 있음 · 믿음(DT1 · DT3의 Kit 몫)과 상태 원천 맞춰 보기 (PR-D1 Kit, 계약 21.2 DR-S1a): 등록 파일 A를 1초마다, 시작 때와 60초마다
    /// `claude agents --json`과 맞춰 보고, 다르거나 키가 없으면 맞을 때까지 B(agents-json 폴링). 시계 · 실행기는 가짜다
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
            log: any BridgeLogSink = NoBridgeLog()
        ) -> ClaudeAppStatusPoller {
            ClaudeAppStatusPoller(
                fileSystem: .live, sessionsDirectory: home.sessions, processFacts: A.facts(lookups: lookups ?? [100: alive, 101: alive, 102: alive]), ownPIDs: { own },
                agents: agents.runner, clock: { clock.now }, log: log
            )
        }

        private func item(_ pid: Int32, _ id: String, _ state: ClaudeAppSessionState) -> ClaudeAgentsItem { ClaudeAgentsItem(pid: pid, sessionID: id, state: state) }

        // MARK: 시작 때와 60초마다 맞춰 본다

        @Test func theFirstPollReconcilesAtStartAndThenOnlyEveryMinute() async throws {
            try await withHome { home in
                try write(home, pid: 100, id: a, status: "busy")
                let clock = ClaudeAppClock()
                let agents = ClaudeAppAgentsStub([item(100, a, .busy)])
                let poller = poller(home, clock: clock, agents: agents)
                let first = await poller.poll()
                #expect(agents.calls == 1, "시작 때 한 번")
                #expect(first.source == .registry && !first.mismatch && first.verified)
                for step: TimeInterval in [1, 29, 29] {
                    clock.advance(step)
                    _ = await poller.poll()
                }
                #expect(agents.calls == 1, "59초 안에는 다시 맞추지 않는다")
                clock.advance(1)
                let again = await poller.poll()
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
                #expect(await poller.poll().sessions.map(\.state) == [.busy])
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

        // MARK: 어긋나면 B

        @Test func aMismatchSwitchesToAgentsPollingAndTheAgentsStatusIsShown() async throws {
            try await withHome { home in
                try write(home, pid: 100, id: a, status: "idle")
                let clock = ClaudeAppClock()
                let agents = ClaudeAppAgentsStub([item(100, a, .busy)])
                let poller = poller(home, clock: clock, agents: agents)
                let first = await poller.poll()
                #expect(first.source == .agents && first.mismatch && !first.verified)
                #expect(first.sessions.map(\.state) == [.busy], "어긋나는 동안은 문서화된 원천의 값")
                // B는 몇 초마다만 띄운다 (매초가 아니다)
                clock.advance(1)
                agents.set([item(100, a, .waiting(.answer))])
                #expect(await poller.poll().sessions.map(\.state) == [.busy], "다음 실행 전에는 지난 답")
                #expect(agents.calls == 1)
                clock.advance(2)
                let next = await poller.poll()
                #expect(agents.calls == 2, "3초 뒤 다시")
                #expect(next.source == .agents && next.sessions.map(\.state) == [.waiting(.answer)])
                clock.advance(2.9)
                _ = await poller.poll()
                #expect(agents.calls == 2)
            }
        }

        @Test func itGoesBackToTheRegistryWhenTheTwoAgreeAgain() async throws {
            try await withHome { home in
                try write(home, pid: 100, id: a, status: "idle")
                let clock = ClaudeAppClock()
                let agents = ClaudeAppAgentsStub([item(100, a, .busy)])
                let poller = poller(home, clock: clock, agents: agents)
                #expect(await poller.poll().source == .agents)
                // 등록 파일이 문서의 값과 같아졌다 (같은 시각에 두 곳이 같다)
                try write(home, pid: 100, id: a, status: "busy")
                clock.advance(3)
                let back = await poller.poll()
                #expect(back.source == .registry && !back.mismatch && back.verified)
                #expect(agents.calls == 2)
                // 다시 A: 다음 맞춰 보기는 60초 뒤
                clock.advance(30)
                _ = await poller.poll()
                #expect(agents.calls == 2)
                clock.advance(30)
                _ = await poller.poll()
                #expect(agents.calls == 3)
            }
        }

        @Test func aRegistryWithoutTheStatusKeyIsAMismatchWhenAgentsKnowsTheStatus() async throws {
            try await withHome { home in
                try write(home, pid: 100, id: a, status: nil)
                let clock = ClaudeAppClock()
                let agents = ClaudeAppAgentsStub([item(100, a, .waiting(.approval))])
                let result = await poller(home, clock: clock, agents: agents).poll()
                #expect(result.source == .agents && result.mismatch)
                #expect(result.sessions.map(\.state) == [.waiting(.approval)], "키가 없어도 필요한 상태는 agents에서")
            }
        }

        @Test func aWaitReasonThatDiffersInKindIsAMismatchToo() async throws {
            try await withHome { home in
                try write(home, pid: 100, id: a, status: "waiting", waitingFor: "permission prompt")
                let result = await poller(home, clock: ClaudeAppClock(), agents: ClaudeAppAgentsStub([item(100, a, .waiting(.answer))])).poll()
                #expect(result.source == .agents && result.mismatch)
            }
        }

        @Test func anAgentsItemWithoutAStatusProvesNothingAndNeverCausesAMismatch() async throws {
            try await withHome { home in
                try write(home, pid: 100, id: a, status: "busy")
                let result = await poller(home, clock: ClaudeAppClock(), agents: ClaudeAppAgentsStub([item(100, a, .unknown)])).poll()
                #expect(result.source == .registry && !result.mismatch && !result.verified, "맞춰 볼 수 없다")
                #expect(result.sessions.map(\.state) == [.busy])
            }
        }

        // MARK: 맞춰 볼 수 없을 때

        @Test func ifTheAgentsListCannotBeReadTheRegistryStaysTheSourceUnverified() async throws {
            try await withHome { home in
                try write(home, pid: 100, id: a, status: "busy")
                let clock = ClaudeAppClock()
                let agents = ClaudeAppAgentsStub(nil)
                let poller = poller(home, clock: clock, agents: agents)
                let result = await poller.poll()
                #expect(result.source == .registry && !result.mismatch && !result.verified)
                #expect(result.sessions.map(\.state) == [.busy], "원천을 못 맞춰 봐도 레일은 등록 파일로 간다")
                clock.advance(60)
                agents.set([item(100, a, .busy)])
                #expect(await poller.poll().verified, "나중에 읽히면 맞춰 본다")
            }
        }

        @Test func aSessionTheAgentsListDoesNotKnowIsNotComparedAndNeverMakesAMismatch() async throws {
            try await withHome { home in
                try write(home, pid: 100, id: a, status: "busy")
                let result = await poller(home, clock: ClaudeAppClock(), agents: ClaudeAppAgentsStub([])).poll()
                #expect(result.source == .registry && !result.mismatch && !result.verified)
            }
        }

        @Test func aChangeDuringTheAgentsRunIsNotAMismatch() async throws {
            try await withHome { home in
                try write(home, pid: 100, id: a, status: "idle")
                let agents = ClaudeAppAgentsStub([item(100, a, .busy)])
                // 실행되는 사이 등록 파일이 busy로 바뀐다: 답(busy)은 실행 뒤의 값과 같다
                agents.onRun { try? home.registry(pid: 100, json: A.registry(pid: 100, id: self.a, status: "busy", procStart: self.started.timeIntervalSince1970)) }
                let after = await poller(home, clock: ClaudeAppClock(), agents: agents).poll()
                #expect(after.source == .registry && !after.mismatch && after.verified)
            }
            try await withHome { home in
                try write(home, pid: 100, id: a, status: "idle")
                let agents = ClaudeAppAgentsStub([item(100, a, .idle)])
                // 반대로: 답(idle)은 실행 전의 값과 같고 그 사이 busy로 바뀌었다
                agents.onRun { try? home.registry(pid: 100, json: A.registry(pid: 100, id: self.a, status: "busy", procStart: self.started.timeIntervalSince1970)) }
                let before = await poller(home, clock: ClaudeAppClock(), agents: agents).poll()
                #expect(before.source == .registry && !before.mismatch && before.verified)
            }
        }

        @Test func aMismatchOnOneSessionSwitchesEvenWhenAnotherAgrees() async throws {
            try await withHome { home in
                try write(home, pid: 100, id: a, status: "busy")
                try write(home, pid: 101, id: b, status: "idle")
                let agents = ClaudeAppAgentsStub([item(100, a, .busy), item(101, b, .waiting(.approval))])
                let result = await poller(home, clock: ClaudeAppClock(), agents: agents).poll()
                #expect(result.source == .agents && result.mismatch)
                #expect(Set(result.sessions.map(\.state)) == [.busy, .waiting(.approval)])
            }
        }

        // MARK: agents는 줄을 만들지 못한다

        @Test func theAgentsListNeverAddsASessionTheRegistryDoesNotVouchFor() async throws {
            try await withHome { home in
                try write(home, pid: 100, id: a, status: "idle")
                // 등록 파일에 없는 세션 · 데스크톱이 아닌 항목 · 등록의 pid와 다른 pid로 나온 항목
                let agents = ClaudeAppAgentsStub([item(100, a, .busy), item(555, F.uuid(0xEE), .busy), item(999, b, .busy)])
                try write(home, pid: 101, id: b, status: "idle")
                let result = await poller(home, clock: ClaudeAppClock(), agents: agents).poll()
                #expect(result.source == .agents)
                #expect(result.sessions.map(\.id).sorted() == [a, b].sorted(), "줄은 등록 파일 + 살아 있음이 정한다")
                let byID = Dictionary(uniqueKeysWithValues: result.sessions.map { ($0.id, $0.state) })
                #expect(byID[a] == .busy)
                #expect(byID[b] == .unknown, "pid가 다른 항목은 그 세션의 상태가 아니다")
            }
        }

        @Test func twoAgentsItemsForOneIDLeaveItUnknown() async throws {
            try await withHome { home in
                try write(home, pid: 100, id: a, status: "idle")
                let agents = ClaudeAppAgentsStub([item(100, a, .busy), item(100, a, .idle)])
                let result = await poller(home, clock: ClaudeAppClock(), agents: agents).poll()
                #expect(result.sessions.map(\.state).allSatisfy { $0 == .idle }, "둘 중 하나는 거짓이다: 맞춰 보지 않고 등록 값을 쓴다")
                #expect(result.source == .registry && !result.mismatch)
            }
        }

        @Test func inAgentsModeTwoItemsForOneIDLeaveItsStateUnknown() async throws {
            try await withHome { home in
                try write(home, pid: 100, id: a, status: "idle")
                let clock = ClaudeAppClock()
                let agents = ClaudeAppAgentsStub([item(100, a, .busy)])
                let poller = poller(home, clock: clock, agents: agents)
                #expect(await poller.poll().sessions.map(\.state) == [.busy])
                // 같은 id의 항목이 둘: 어느 쪽이 맞는지 모른다 (B에서도 첫 항목을 고르지 않는다)
                agents.set([item(100, a, .busy), item(100, a, .idle)])
                clock.advance(3)
                let result = await poller.poll()
                #expect(result.source == .agents)
                #expect(result.sessions.map(\.state) == [.unknown])
            }
        }

        @Test func aLaterFailureToReadTheAgentsListMakesTheRegistryUnverifiedAgain() async throws {
            try await withHome { home in
                try write(home, pid: 100, id: a, status: "busy")
                let clock = ClaudeAppClock()
                let agents = ClaudeAppAgentsStub([item(100, a, .busy)])
                let poller = poller(home, clock: clock, agents: agents)
                #expect(await poller.poll().verified)
                agents.set(nil)
                clock.advance(60)
                let later = await poller.poll()
                #expect(!later.verified && later.source == .registry && !later.mismatch, "맞춰 본 것이 지금도 맞다고 말하지 않는다")
            }
        }

        @Test func inAgentsModeWithoutAnyAnswerNothingIsOnTheRailButNothingCrashes() async throws {
            try await withHome { home in
                try write(home, pid: 100, id: a, status: "idle")
                let clock = ClaudeAppClock()
                let agents = ClaudeAppAgentsStub([item(100, a, .busy)])
                let poller = poller(home, clock: clock, agents: agents)
                #expect(await poller.poll().source == .agents)
                agents.set(nil)
                clock.advance(3)
                let none = await poller.poll()
                #expect(none.source == .agents)
                #expect(none.sessions.map(\.state) == [.unknown], "어긋난 등록 파일을 믿지 않는다: 줄은 있고 상태는 모른다")
            }
        }

        // MARK: 한 번에 하나

        @Test func aSecondPollWhileAnAgentsRunIsInFlightDoesNotStartAnother() async throws {
            try await withHome { home in
                try write(home, pid: 100, id: a, status: "busy")
                let agents = ClaudeAppAgentsStub([item(100, a, .busy)])
                agents.hold()
                let poller = poller(home, clock: ClaudeAppClock(), agents: agents)
                let first = Task { await poller.poll() }
                for _ in 0..<200 where !agents.isHolding { try await Task.sleep(for: .milliseconds(10)) }
                #expect(agents.isHolding)
                let second = await poller.poll()
                #expect(agents.calls == 1, "도는 실행이 있으면 새로 띄우지 않는다")
                #expect(second.sessions.map(\.state) == [.busy], "그동안에도 등록 파일은 읽는다")
                agents.release()
                let result = await first.value
                #expect(result.verified && agents.calls == 1)
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

        // MARK: 관찰

        @Test func theLogCarriesOnlyTheSourceAndWhetherTheyDifferNeverAnIDOrFolderOrName() async throws {
            try await withHome { home in
                try write(home, pid: 100, id: a, status: "idle")
                let log = RecordingLog()
                let clock = ClaudeAppClock()
                let agents = ClaudeAppAgentsStub([item(100, a, .busy)])
                let poller = poller(home, clock: clock, agents: agents, log: log)
                _ = await poller.poll()
                try write(home, pid: 100, id: a, status: "busy")
                clock.advance(3)
                _ = await poller.poll()
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

        @Test func anUnreadableRegistryGivesNoSessionsAndTheSourceStaysTheRegistry() async throws {
            try await withHome { home in
                try "not json".write(toFile: home.sessions + "/100.json", atomically: false, encoding: .utf8)
                let result = await poller(home, clock: ClaudeAppClock(), agents: ClaudeAppAgentsStub([])).poll()
                #expect(result.sessions.isEmpty && result.registryUnavailable)
                #expect(result.source == .registry)
            }
        }
    }
}
#endif
