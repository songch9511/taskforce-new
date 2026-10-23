#if os(macOS) && DEBUG
import Darwin
import Foundation
import Testing
@testable import TaskforceKit

extension ExternalSessionSuites {
    /// 보내기 전 확인 (PR-D3k, 계약 21.2 DR-S2c ①–④ · 25.4.3 ⑤–⑧ · 위협 DT1 · DT3 · DT4): **보낼 때마다** 다시 본다. 순수 판정(`ClaudeAppSendCheck`)과 사실 모으기(`ClaudeAppSendVerifier`: 등록 파일 + 프로세스 사실 + 서명 확인)를 나눠 시험한다.
    /// 실제 `claude` · 실제 등록 파일 · 실제 서명 확인은 부르지 않는다 (가짜 홈 · 가짜 사실)
    struct ClaudeAppSendCheckTests {
        typealias F = ExternalSessionFixture
        typealias A = ClaudeAppFixture
        let id = F.uuid(0xC1)
        let started = Date(timeIntervalSince1970: 1_799_990_000)

        private func session(pid: Int32 = 100, procStart: Date? = nil) -> ClaudeAppSession {
            ClaudeAppSession(id: id, pid: pid, cwd: "/Users/tester/proj", procStart: procStart ?? started, state: .idle, statusUpdatedAt: nil)
        }

        private func facts(
            session: ClaudeAppSession?? = nil, doubled: Bool = false, trusted: Bool = true, writers: ClaudeAppSendFacts.Writers = .none
        ) -> ClaudeAppSendFacts {
            ClaudeAppSendFacts(session: session ?? self.session(), doubled: doubled, processTrusted: trusted, otherWriters: writers)
        }

        private func context(
            viewed: String? = nil, confirmed: ClaudeAppSendContext.Confirmation? = nil, pending: Bool = false, relay: ClaudeAppSendContext.Relay = .ready,
            view: ClaudeAppSendContext.View = .open
        ) -> ClaudeAppSendContext {
            ClaudeAppSendContext(viewedSessionID: viewed ?? id, targetSessionID: id, confirmed: confirmed ?? .init(pid: 100, procStart: started), hasPending: pending, relay: relay, view: view)
        }

        // MARK: 통과

        @Test func aTrustedSingleDesktopSessionThatWasConfirmedForThisProcessMayReceiveTheMessage() {
            #expect(ClaudeAppSendCheck.evaluate(facts: facts(), context: context()) == .allowed)
        }

        @Test func aRelayThatIsNotRunningYetIsStartedByTheSendItself() {
            #expect(ClaudeAppSendCheck.evaluate(facts: facts(), context: context(relay: .notRunning)) == .allowed, "띄우는 것은 보내기의 일이다")
        }

        // MARK: ① 믿을 수 있는 하나뿐인 데스크톱 세션

        @Test func noLiveRegistrationMeansTheSessionIsClosed() {
            #expect(ClaudeAppSendCheck.evaluate(facts: facts(session: .some(nil)), context: context()) == .blocked(.sessionClosed))
        }

        @Test func twoLiveRegistrationsClaimingTheIdAreRefusedAsTwoWritersAndNeitherIsTrusted() {
            // DT1: 같은 id의 가짜 등록 둘 → 보내기 0
            #expect(ClaudeAppSendCheck.evaluate(facts: facts(session: .some(nil), doubled: true), context: context()) == .blocked(.twoWriters))
            #expect(ClaudeAppSendCheck.evaluate(facts: facts(doubled: true), context: context()) == .blocked(.twoWriters), "믿는 항목이 있어도 둘이면 막는다")
        }

        @Test func anExecutableThatIsNotSignedByTheClaudeTeamOrNotUnderTheClaudeAppIsNotTrusted() {
            // DT1: 서명 다른 실행 파일 · 부모가 Claude.app 아님 → 보내기 0
            #expect(ClaudeAppSendCheck.evaluate(facts: facts(trusted: false), context: context()) == .blocked(.notTrusted))
        }

        // MARK: ② 같은 id의 다른 writer

        @Test func anotherProcessHoldingTheSameSessionIsTwoWritersAndAnUnreadableProcessListBlocksToo() {
            #expect(ClaudeAppSendCheck.evaluate(facts: facts(writers: .found), context: context()) == .blocked(.twoWriters))
            #expect(ClaudeAppSendCheck.evaluate(facts: facts(writers: .unknown), context: context()) == .blocked(.writersUnknown), "모르면 막는다")
        }

        // MARK: ⑥ 패널이 보던 세션 = 보낼 세션 · ③ pid가 바뀌면 다시 확인

        @Test func aPanelThatShowsAnotherSessionThanTheTargetNeverSends() {
            // DT3: 패널을 다른 세션으로 바꾼 직후 Enter → 보내기 0
            #expect(ClaudeAppSendCheck.evaluate(facts: facts(), context: context(viewed: F.uuid(0xC2))) == .blocked(.idMismatch))
        }

        @Test func theConfirmCardIsAskedForTheFirstSendAndAgainWhenTheProcessChanged() {
            let never = ClaudeAppSendContext(viewedSessionID: id, targetSessionID: id, confirmed: nil, hasPending: false, relay: .ready, view: .open)
            #expect(ClaudeAppSendCheck.evaluate(facts: facts(), context: never) == .needsConfirmation, "세션마다 처음 한 번")
            // DT3: pid가 바뀌었다 (확인했던 프로세스가 아니다) → 다시 확인 줄
            #expect(ClaudeAppSendCheck.evaluate(facts: facts(session: .some(session(pid: 222))), context: context()) == .needsConfirmation)
            // 같은 pid라도 시작 시각이 다르면(pid 재사용) 다른 프로세스다
            #expect(ClaudeAppSendCheck.evaluate(facts: facts(session: .some(session(procStart: started.addingTimeInterval(500)))), context: context()) == .needsConfirmation)
            #expect(ClaudeAppSendCheck.evaluate(facts: facts(), context: context(confirmed: .init(pid: 100, procStart: started))) == .allowed)
        }

        // MARK: ④ 확인 전 글은 하나

        @Test func aSecondMessageWaitsUntilTheFirstOneIsSettled() {
            #expect(ClaudeAppSendCheck.evaluate(facts: facts(), context: context(pending: true)) == .blocked(.pending))
        }

        // MARK: ⑤ 중계

        @Test func aRelayWhoseIdentityChangedOrWhichIsOffForThisRunBlocks() {
            #expect(ClaudeAppSendCheck.evaluate(facts: facts(), context: context(relay: .mismatch)) == .blocked(.relayMismatch))
            #expect(ClaudeAppSendCheck.evaluate(facts: facts(), context: context(relay: .unavailable)) == .blocked(.unavailable))
        }

        // MARK: ⑦ 닫힘 · 기록 못 읽음

        @Test func aClosedOrUnreadableViewHasNoInput() {
            #expect(ClaudeAppSendCheck.evaluate(facts: facts(), context: context(view: .closed)) == .blocked(.sessionClosed))
            #expect(ClaudeAppSendCheck.evaluate(facts: facts(), context: context(view: .unreadable)) == .blocked(.unreadable))
        }

        // MARK: 우선순위 · 이유 매핑

        @Test func theChecksRunInAFixedOrderSoTheMostSpecificReasonWins() {
            // 닫힘이 모든 것에 앞선다 (중계가 꺼져 있어도 · 다른 writer · 확인 전 글이 있어도)
            #expect(ClaudeAppSendCheck.evaluate(facts: facts(session: .some(nil), writers: .found), context: context(pending: true, relay: .unavailable, view: .closed)) == .blocked(.sessionClosed))
            #expect(ClaudeAppSendCheck.evaluate(facts: facts(session: .some(nil), writers: .found), context: context(pending: true)) == .blocked(.sessionClosed), "등록이 없으면 닫힘")
            // 중계가 이 실행에서 꺼졌으면 세션 사실을 보기 전에 막는다
            #expect(ClaudeAppSendCheck.evaluate(facts: facts(trusted: false, writers: .found), context: context(pending: true, relay: .unavailable)) == .blocked(.unavailable))
            // 서명이 틀리면 writer 검사보다 먼저
            #expect(ClaudeAppSendCheck.evaluate(facts: facts(trusted: false, writers: .found), context: context()) == .blocked(.notTrusted))
            // writer가 pending · 확인보다 먼저
            #expect(ClaudeAppSendCheck.evaluate(facts: facts(writers: .found), context: context(confirmed: nil, pending: true)) == .blocked(.twoWriters))
            // pending이 확인보다 먼저
            let never = ClaudeAppSendContext(viewedSessionID: id, targetSessionID: id, confirmed: nil, hasPending: true, relay: .ready, view: .open)
            #expect(ClaudeAppSendCheck.evaluate(facts: facts(), context: never) == .blocked(.pending))
        }

        @Test func eachBlockMapsToTheNotSentReasonTheComposerShowsOrToNone() {
            typealias B = ClaudeAppSendBlock
            #expect(B.twoWriters.notSentReason == .twoWriters)
            #expect(B.sessionClosed.notSentReason == .sessionClosed)
            #expect(B.notTrusted.notSentReason == .notReceived && B.writersUnknown.notSentReason == .notReceived)
            #expect(B.unavailable.notSentReason == .relayFailed && B.relayMismatch.notSentReason == .relayFailed)
            #expect(B.pending.notSentReason == nil && B.idMismatch.notSentReason == nil && B.unreadable.notSentReason == nil, "줄 없이 막는다 (입력창이 없거나 한 번에 하나)")
        }

        // MARK: 사실 모으기 (가짜 홈 · 가짜 사실)

        private func withHome<T>(_ body: (ExternalHome) throws -> T) throws -> T {
            let home = try ExternalHome()
            defer { home.cleanup() }
            return try body(home)
        }

        private func write(_ home: ExternalHome, pid: Int, id: String, entrypoint: String? = "claude-desktop", cwd: String = "/Users/tester/proj") throws {
            try home.registry(pid: pid, json: A.registry(pid: pid, id: id, cwd: cwd, procStart: started.timeIntervalSince1970, entrypoint: entrypoint))
        }

        private func verifier(
            _ home: ExternalHome, trusted: @escaping @Sendable (Int32) -> Bool = { _ in true }, arguments: Set<String>? = [], folders: Set<String>? = [],
            lookups: [Int32: ExternalSessionProcessFacts.Lookup]? = nil, own: Set<Int32> = []
        ) -> ClaudeAppSendVerifier {
            let alive = ExternalSessionProcessFacts.Lookup.present(start: started, uid: 501)
            let facts = ExternalSessionProcessFacts(
                userID: 501, lookup: { (lookups ?? [100: alive, 101: alive, 102: alive])[$0] ?? .gone }, argumentSessionIDs: { _ in arguments }, unregisteredClaudeFolders: { _, _ in folders }
            )
            return ClaudeAppSendVerifier(
                fileSystem: .live, sessionsDirectory: home.sessions, processFacts: facts, trust: ClaudeAppProcessTrust(isTrusted: trusted), ownPIDs: { own }, clock: { Date(timeIntervalSince1970: 1_800_000_000) }
            )
        }

        @Test func theVerifierReadsTheRegistryAgainEverySendAndFindsOneTrustedEntry() throws {
            try withHome { home in
                try write(home, pid: 100, id: id)
                let found = verifier(home).facts(for: id)
                #expect(found.session?.pid == 100 && !found.doubled && found.processTrusted && found.otherWriters == .none)
                // 매번 다시 읽는다: 프로세스가 끝나면 다음 확인에서 사라진다
                let gone = verifier(home, lookups: [:]).facts(for: id)
                #expect(gone.session == nil && !gone.doubled)
            }
        }

        @Test func twoLiveRegistrationsForOneIdOrATerminalEntryAreNotTrusted() throws {
            try withHome { home in
                try write(home, pid: 100, id: id)
                try write(home, pid: 101, id: id)
                let doubled = verifier(home).facts(for: id)
                #expect(doubled.session == nil && doubled.doubled, "DT1: 같은 id 등록 둘")
            }
            try withHome { home in
                try write(home, pid: 100, id: id, entrypoint: "cli")
                #expect(verifier(home).facts(for: id).session == nil, "터미널이 쥔 세션은 데스크톱 대화 대상이 아니다")
            }
        }

        @Test func theSigningAndParentCheckRunsOnTheTargetPidAndItsAnswerIsKept() throws {
            try withHome { home in
                try write(home, pid: 100, id: id)
                let asked = ClaudeAppFlag()
                let untrusted = verifier(home, trusted: { pid in
                    if pid == 100 { asked.set() }
                    return false
                }).facts(for: id)
                #expect(asked.isSet && untrusted.session != nil && !untrusted.processTrusted, "DT1: 서명 다른 실행 파일 · 부모가 Claude.app이 아님")
            }
        }

        @Test func anotherProcessNamingTheSessionOrSittingInItsFolderIsAnotherWriterAndAnUnreadableProcessListIsUnknown() throws {
            try withHome { home in
                try write(home, pid: 100, id: id)
                #expect(verifier(home, arguments: [id]).facts(for: id).otherWriters == .found, "--resume <id>")
                #expect(verifier(home, folders: ["/Users/tester/proj"]).facts(for: id).otherWriters == .found, "같은 폴더의 등록 없는 claude")
                #expect(verifier(home, folders: ["/Users/tester/elsewhere"]).facts(for: id).otherWriters == .none)
                #expect(verifier(home, arguments: nil).facts(for: id).otherWriters == .unknown)
                #expect(verifier(home, folders: nil).facts(for: id).otherWriters == .unknown)
            }
        }

        /// 우리가 띄운 프로세스(중계)의 pid가 "다른 writer 찾기"에 자기 것으로 넘어간다 (DT13: 중계는 다른 writer로 세어지지 않는다).
        /// `--resume`을 보는 쪽은 대상 pid도 함께 뺀다
        @Test func ourOwnRelayPIDIsHandedToBothOtherWriterLookupsAsOurOwn() throws {
            final class Seen: @unchecked Sendable {
                private let lock = NSLock()
                private var _arguments: Set<Int32> = []
                private var _folders: Set<Int32> = []
                var arguments: Set<Int32> { lock.withLock { _arguments } }
                var folders: Set<Int32> { lock.withLock { _folders } }
                func argumentsExcluded(_ pids: Set<Int32>) { lock.withLock { _arguments = pids } }
                func foldersExcluded(_ pids: Set<Int32>) { lock.withLock { _folders = pids } }
            }
            try withHome { home in
                try write(home, pid: 100, id: id)
                let seen = Seen()
                let alive = ExternalSessionProcessFacts.Lookup.present(start: started, uid: 501)
                let facts = ExternalSessionProcessFacts(
                    userID: 501, lookup: { $0 == 100 ? alive : .gone }, argumentSessionIDs: { seen.argumentsExcluded($0); return [] },
                    unregisteredClaudeFolders: { _, excluding in seen.foldersExcluded(excluding); return [] }
                )
                let verifier = ClaudeAppSendVerifier(
                    fileSystem: .live, sessionsDirectory: home.sessions, processFacts: facts, trust: ClaudeAppProcessTrust(isTrusted: { _ in true }), ownPIDs: { [4001] },
                    clock: { Date(timeIntervalSince1970: 1_800_000_000) }
                )
                #expect(verifier.facts(for: id).otherWriters == .none)
                #expect(seen.arguments == [4001, 100], "argv 훑기는 우리 pid와 대상 pid를 뺀다")
                #expect(seen.folders == [4001], "같은 폴더의 등록 없는 claude 훑기는 우리 pid를 뺀다")
            }
        }

        @Test func theLiveTrustCheckDoesNotTrustThisTestProcessOrAMissingOne() {
            #expect(!ClaudeAppProcessTrust.live.isTrusted(getpid()), "Claude.app의 자식이 아니다")
            #expect(!ClaudeAppProcessTrust.live.isTrusted(0) && !ClaudeAppProcessTrust.live.isTrusted(-1) && !ClaudeAppProcessTrust.live.isTrusted(Int32.max))
        }
    }
}
#endif
