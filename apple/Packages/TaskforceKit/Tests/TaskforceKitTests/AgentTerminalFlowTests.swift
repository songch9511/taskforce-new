import Foundation
import Testing
@testable import TaskforceKit

/// 세션 알약 흐름 (OA D4a-03 · 15 · 16, 계약 1.1 7): Open in Terminal은 서버를 먼저 부르고 그다음 터미널을 연다 (미리 조건은 서버 호출 전에), Resume here는 확인 카드를 늘 거친다.
/// 앱의 실제 launcher · 프로세스 검사기는 D4a-2다: 여기는 프로토콜만 있고 시험은 가짜로 순서 · 호출 수를 본다
@MainActor
struct AgentTerminalFlowTests {
    typealias Fx = SessionFx

    final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [String] = []
        var events: [String] { lock.withLock { _events } }
        func add(_ event: String) { lock.withLock { _events.append(event) } }
    }

    final class FakeLauncher: AgentTerminalLauncher, @unchecked Sendable {
        struct Failure: Error {}
        let log: Log
        var canOpenResult = true
        var openFails = false
        init(_ log: Log) { self.log = log }
        func canOpen(sessionID: UUID) async -> Bool {
            log.add("preflight")
            return canOpenResult
        }
        func open(sessionID: UUID) async throws {
            log.add("launcher.open")
            if openFails { throw Failure() }
        }
    }

    final class FakeInspector: AgentProcessInspector, @unchecked Sendable {
        let log: Log
        var found = false
        private let lock = NSLock()
        private var _onMainThread: [Bool] = []
        var onMainThread: [Bool] { lock.withLock { _onMainThread } }
        init(_ log: Log) { self.log = log }
        func hasProcess(resuming sessionID: UUID) async -> Bool {
            log.add("inspect")
            lock.withLock { _onMainThread.append(Thread.isMainThread) }
            return found
        }
    }

    let log = Log()
    let requests = FakeAgentSessionRequests()
    let scope = ChatTestAccount.fixedScope()

    func flow(launcher: FakeLauncher? = nil, inspector: FakeInspector? = nil, scope: AccountScope? = nil) -> AgentSessionPillFlow {
        let flow = AgentSessionPillFlow(requests: requests, launcher: launcher, inspector: inspector ?? NoProcessFoundInspector(), scope: scope ?? self.scope)
        return flow
    }

    func bound(_ state: AgentTaskState? = .idle) -> AgentSessionItem { Fx.item(Fx.snapshot(status: .bound, state: state)) }
    func external() -> AgentSessionItem { Fx.item(Fx.snapshot(status: .external, state: .idle)) }

    func serveOpen() {
        requests.openHandler = { [log] id in
            log.add("server.open")
            return AgentSessionResponse(session: FakeAgentSessionRequests.row(.external, id: id))
        }
    }

    func serveResume() {
        requests.resumeHandler = { [log] id in
            log.add("server.resume")
            return AgentResumeResponse(session: FakeAgentSessionRequests.row(.bound, id: id), startedMessageID: nil)
        }
    }

    // MARK: Open in Terminal

    @Test func openInTerminalChecksThenCallsTheServerThenTheLauncher() async {
        serveOpen()
        let launcher = FakeLauncher(log)
        let reads = Mutex2(0)
        let flow = flow(launcher: launcher)
        flow.onNeedsReread = { reads.value += 1 }
        await flow.press(.openInTerminal(disabledReason: nil), session: bound())
        #expect(log.events == ["preflight", "server.open", "launcher.open"], "미리 조건 → 서버 → launcher")
        #expect(reads.value == 1, "서버가 external로 넘겼다: 세션을 다시 읽는다")
    }

    @Test func aFailedPreflightNeverCallsTheServer() async {
        serveOpen()
        let launcher = FakeLauncher(log)
        launcher.canOpenResult = false
        let flow = flow(launcher: launcher)
        await flow.press(.openInTerminal(disabledReason: nil), session: bound())
        #expect(log.events == ["preflight"] && requests.calls.isEmpty, "실행 파일 · 폴더가 없다: 서버 호출 0")
    }

    @Test func aDisabledPillAndAMissingLauncherDoNothing() async {
        serveOpen()
        let flow1 = flow(launcher: FakeLauncher(log))
        await flow1.press(.openInTerminal(disabledReason: "Turn is running"), session: bound(.running))
        await flow1.press(.openInTerminal(disabledReason: "Answer the question first"), session: bound(.awaitingAnswer))
        let flow2 = flow(launcher: nil)
        await flow2.press(.openInTerminal(disabledReason: nil), session: bound())
        #expect(log.events.isEmpty && requests.calls.isEmpty)
        #expect(flow1.offersOpenInTerminal && !flow2.offersOpenInTerminal, "launcher가 없으면 Open in Terminal 알약을 그리지 않는다")
    }

    @Test func aServerRefusalDoesNotOpenTheTerminalAndReadsAgain() async {
        for code in [APIErrorCode.sessionBusy, .conflict, .busyRetry] {
            let launcher = FakeLauncher(Log())
            requests.openHandler = { _ in throw APIError.server(status: 409, code: code, message: "x") }
            let reads = Mutex2(0)
            let flow = flow(launcher: launcher)
            flow.onNeedsReread = { reads.value += 1 }
            await flow.press(.openInTerminal(disabledReason: nil), session: bound())
            #expect(launcher.log.events == ["preflight"] && reads.value == 1, "409 \(code.rawValue): 터미널을 열지 않고 다시 읽는다")
        }
    }

    /// 서버 뒤 실패: 세션은 `external` 그대로다 (사용자는 Resume here). 되돌리는 요청을 보내지 않는다
    @Test func aLauncherFailureAfterTheServerLeavesTheSessionExternal() async {
        serveOpen()
        let launcher = FakeLauncher(log)
        launcher.openFails = true
        let reads = Mutex2(0)
        let flow = flow(launcher: launcher)
        flow.onNeedsReread = { reads.value += 1 }
        await flow.press(.openInTerminal(disabledReason: nil), session: bound())
        #expect(log.events == ["preflight", "server.open", "launcher.open"])
        #expect(requests.calls.count == 1, "되돌리는 요청이 없다")
        #expect(reads.value == 1, "사실대로 보이도록 다시 읽는다")
    }

    @Test func pressingOpenInTerminalTwiceCallsTheServerOnce() async {
        let latch = Latch()
        requests.openHandler = { id in
            await latch.wait()
            return AgentSessionResponse(session: FakeAgentSessionRequests.row(.external, id: id))
        }
        let flow = flow(launcher: FakeLauncher(log))
        let item = bound()
        async let first: Void = flow.press(.openInTerminal(disabledReason: nil), session: item)
        #expect(await latch.waitForArrivals(1, timeout: .seconds(3)))
        async let second: Void = flow.press(.openInTerminal(disabledReason: nil), session: item)
        #expect(await noSecondRequest(latch), "진행 중인 세션의 두 번째 누름은 서버에 가지 않는다")
        await latch.open()
        _ = await (first, second)
        #expect(requests.calls.count == 1)
    }

    // MARK: Resume here (확인 카드)

    @Test func resumeHereAlwaysShowsTheConfirmCardFirstAndCancelCallsNothing() async {
        serveResume()
        let flow = flow()
        await flow.press(.resumeHere, session: external())
        #expect(flow.resumeCard == AgentSessionPillFlow.ResumeCard(sessionID: external().id, error: nil, busy: false), "눌러도 서버를 부르지 않고 카드를 연다")
        #expect(requests.calls.isEmpty)
        flow.cancelResume()
        #expect(flow.resumeCard == nil && requests.calls.isEmpty)
    }

    @Test func confirmingCallsTheInspectorThenTheServerAndClosesTheCard() async {
        serveResume()
        let inspector = FakeInspector(log)
        let reads = Mutex2(0)
        let flow = flow(inspector: inspector)
        flow.onNeedsReread = { reads.value += 1 }
        await flow.press(.resumeHere, session: external())
        await flow.confirmResume()
        #expect(log.events == ["inspect", "server.resume"], "검사기 → 서버 (못 찾아도 확인 카드는 이미 거쳤다)")
        #expect(flow.resumeCard == nil && reads.value == 1)
        #expect(inspector.onMainThread == [false], "프로세스 검사는 메인 스레드 밖에서 부른다")
    }

    @Test func aFoundProcessKeepsTheSessionExternalWithTheRedLineAndNoServerCall() async {
        serveResume()
        let inspector = FakeInspector(log)
        inspector.found = true
        let flow = flow(inspector: inspector)
        let item = external()
        await flow.press(.resumeHere, session: item)
        await flow.confirmResume()
        #expect(log.events == ["inspect"] && requests.calls.isEmpty, "서버 호출 0")
        #expect(flow.resumeCard == AgentSessionPillFlow.ResumeCard(sessionID: item.id, error: "Close the terminal session first", busy: false))
        // 터미널을 닫고 다시 누르면 된다
        inspector.found = false
        await flow.confirmResume()
        #expect(requests.calls == ["resume:\(item.id.uuidString)"] && flow.resumeCard == nil)
    }

    @Test func pressingResumeTwiceActsOnce() async {
        let latch = Latch()
        requests.resumeHandler = { id in
            await latch.wait()
            return AgentResumeResponse(session: FakeAgentSessionRequests.row(.bound, id: id), startedMessageID: nil)
        }
        let flow = flow()
        await flow.press(.resumeHere, session: external())
        async let first: Void = flow.confirmResume()
        #expect(await latch.waitForArrivals(1, timeout: .seconds(3)))
        #expect(flow.resumeCard?.busy == true)
        async let second: Void = flow.confirmResume()
        #expect(await noSecondRequest(latch), "서버를 부르는 중인 카드의 두 번째 누름은 서버에 가지 않는다")
        await latch.open()
        _ = await (first, second)
        #expect(requests.calls.count == 1 && flow.resumeCard == nil)
    }

    @Test func aRefusalClosesTheCardAndReadsAgainAndOtherFailuresKeepItForARetry() async {
        let reads = Mutex2(0)
        let flow = flow()
        flow.onNeedsReread = { reads.value += 1 }
        requests.resumeHandler = { _ in throw APIError.server(status: 409, code: .conflict, message: "x") }
        await flow.press(.resumeHere, session: external())
        await flow.confirmResume()
        #expect(flow.resumeCard == nil && reads.value == 1, "409: 다른 곳에서 이미 바뀌었다 — 카드를 닫고 다시 읽는다")
        requests.resumeHandler = { _ in throw APIError.transport("x") }
        await flow.press(.resumeHere, session: external())
        await flow.confirmResume()
        #expect(flow.resumeCard == AgentSessionPillFlow.ResumeCard(sessionID: external().id, error: nil, busy: false), "연결 문제: 카드를 두고 다시 누를 수 있다")
        #expect(reads.value == 2)
    }

    /// 확인 카드의 대상이 그 사이 바뀌었으면(세션이 더는 `external`이 아니다) 새로 읽은 값으로 카드를 닫는다: 낡은 카드를 적용하지 않는다
    @Test func aCardForASessionThatIsNoLongerExternalIsReplacedNotApplied() async {
        serveResume()
        let flow = flow()
        let item = external()
        await flow.press(.resumeHere, session: item)
        flow.reconcile(sessions: [bound()])
        #expect(flow.resumeCard == nil, "이미 이어졌다")
        await flow.press(.resumeHere, session: item)
        flow.reconcile(sessions: [])
        #expect(flow.resumeCard == nil, "세션이 없어졌다")
        await flow.press(.resumeHere, session: item)
        flow.reconcile(sessions: [external()])
        #expect(flow.resumeCard != nil, "아직 external이면 그대로")
        await flow.confirmResume()
        #expect(requests.calls.count == 1)
    }

    @Test func aNewCardForAnotherSessionReplacesTheOldOne() async {
        let flow = flow()
        let a = external()
        let otherSnapshot = Fx.snapshot(status: .external, state: .idle)
        var snapshot = otherSnapshot
        snapshot.sessions[0] = Fx.session(2, status: .external)
        snapshot.tasks = []
        let b = Fx.item(snapshot)
        await flow.press(.resumeHere, session: a)
        await flow.press(.resumeHere, session: b)
        #expect(flow.resumeCard?.sessionID == b.id)
    }

    @Test func aLateAnswerAfterAnAccountChangeClosesNothingOfTheNewAccount() async throws {
        let account = try ChatTestAccount.make()
        let latch = Latch()
        requests.resumeHandler = { id in
            await latch.wait()
            return AgentResumeResponse(session: FakeAgentSessionRequests.row(.bound, id: id), startedMessageID: nil)
        }
        let reads = Mutex2(0)
        let flow = flow(scope: account.scope)
        flow.onNeedsReread = { reads.value += 1 }
        await flow.press(.resumeHere, session: external())
        async let pending: Void = flow.confirmResume()
        #expect(await latch.waitForArrivals(1, timeout: .seconds(3)))
        account.session.apply(event: .signedOut, session: nil)
        #expect(flow.resumeCard == nil, "계정이 떠나면 카드를 비운다")
        await latch.open()
        await pending
        #expect(reads.value == 0, "떠난 계정의 늦은 응답은 반영하지 않는다")
    }

    @Test func theCardWordsAreTheDesignWords() {
        #expect(AgentCopy.resumeTitle == "Is the Terminal session closed?" && AgentCopy.resumeMeta == "Queued messages send after you resume")
        #expect(AgentCopy.resumeConfirm == "Resume here" && AgentCopy.cancel == "Cancel" && AgentCopy.closeTerminalFirst == "Close the terminal session first")
    }
}
