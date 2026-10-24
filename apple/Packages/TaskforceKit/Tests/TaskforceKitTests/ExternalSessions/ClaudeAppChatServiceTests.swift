#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

/// 움직이는 가짜 기록: 줄을 덧붙이면 `newer`가 새 줄을 준다 (커서의 `nextOffset`을 줄 번호로 쓴다). 실제 파일은 읽지 않는다
final class LiveTranscript: ClaudeAppTranscriptSource, @unchecked Sendable {
    private let lock = NSLock()
    private var turns: [ClaudeAppTurn] = []
    private var _mode: String?
    private var _unreadable = false
    private var _opens = 0

    var opens: Int { lock.withLock { _opens } }
    func append(_ turn: ClaudeAppTurn...) { lock.withLock { turns += turn } }
    func setMode(_ mode: String?) { lock.withLock { _mode = mode } }
    func setUnreadable(_ value: Bool) { lock.withLock { _unreadable = value } }

    private func cursor(_ sessionID: String, at index: Int) -> ClaudeAppTranscriptCursor {
        var cursor = ClaudeAppTranscriptCursor(
            sessionID: sessionID, path: "/fake", created: Date(timeIntervalSince1970: 1), earliestOffset: 0, nextOffset: Int64(index), coveredBytes: 0, discarding: false, peerIDs: []
        )
        cursor.permissionMode = _mode
        return cursor
    }

    func open(sessionID: String, cwd: String?) -> ClaudeAppTranscriptLoad {
        lock.withLock {
            _opens += 1
            guard !_unreadable else { return .unreadable }
            return .page(ClaudeAppTranscriptPage(turns: turns, cursor: cursor(sessionID, at: turns.count), hasEarlier: false, skippedLines: 0))
        }
    }

    func earlier(_ cursor: ClaudeAppTranscriptCursor) -> ClaudeAppTranscriptLoad { .unreadable }

    func newer(_ cursor: ClaudeAppTranscriptCursor) -> ClaudeAppTranscriptUpdate {
        lock.withLock {
            guard !_unreadable else { return .unreadable }
            let from = Int(cursor.nextOffset)
            return .turns(Array(turns[min(from, turns.count)...]), cursor: self.cursor(cursor.sessionID, at: turns.count), hasMore: false)
        }
    }
}

/// 서버로 간 보내기 지표를 모은다
final class ReportLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _all: [ClaudeAppSentReport] = []
    func add(_ report: ClaudeAppSentReport) { lock.withLock { _all.append(report) } }
    var all: [ClaudeAppSentReport] { lock.withLock { _all } }
}

/// 시험이 바꾸는 바깥 세상 (등록 파일의 세션 · 보내기 전 확인의 사실 · bridge id): 동기 · 비동기 쪽에서 모두 읽는다
final class RigWorld: @unchecked Sendable {
    private let lock = NSLock()
    private var _session: ClaudeAppSession?
    private var _facts: ClaudeAppSendFacts
    private var _bridge: UUID?
    private var _factsCalls = 0

    static let started = Date(timeIntervalSince1970: 1_799_990_000)

    static func session(pid: Int32 = 100, id: String = ChatRigIDs.session, state: ClaudeAppSessionState = .idle) -> ClaudeAppSession {
        ClaudeAppSession(id: id, pid: pid, cwd: "/Users/tester/proj", procStart: started, state: state, statusUpdatedAt: nil)
    }

    init() {
        _session = Self.session()
        _facts = ClaudeAppSendFacts(session: Self.session(), doubled: false, processTrusted: true, otherWriters: .none)
        _bridge = UUID(uuidString: "11111111-2222-4333-8444-555555555555")
    }

    var session: ClaudeAppSession? {
        get { lock.withLock { _session } }
        set { lock.withLock { _session = newValue } }
    }

    var facts: ClaudeAppSendFacts {
        get { lock.withLock { _facts } }
        set { lock.withLock { _facts = newValue } }
    }

    var bridge: UUID? {
        get { lock.withLock { _bridge } }
        set { lock.withLock { _bridge = newValue } }
    }

    /// 다음 읽기들이 차례로 받을 사실 (모자라면 `facts`): 확인한 뒤 · 보내기 직전에 사실이 달라지는 경우를 만든다 (TOCTOU)
    func script(_ next: ClaudeAppSendFacts...) { lock.withLock { _factsScript += next } }
    private var _factsScript: [ClaudeAppSendFacts] = []
    private var _factsGate: DispatchSemaphore?

    /// 사실 읽기를 붙들어 둔다 (`releaseFacts()`까지 읽는 쪽이 멈춘다): 읽는 도중에 계정이 떠나는 경우를 만든다
    func holdFacts() { lock.withLock { _factsGate = DispatchSemaphore(value: 0) } }

    func releaseFacts() {
        let gate = lock.withLock { () -> DispatchSemaphore? in
            defer { _factsGate = nil }
            return _factsGate
        }
        for _ in 0..<8 { gate?.signal() }
    }

    func readFacts() -> ClaudeAppSendFacts {
        let gate = lock.withLock { () -> DispatchSemaphore? in
            _factsCalls += 1
            return _factsGate
        }
        gate?.wait()
        return lock.withLock { _factsScript.isEmpty ? _facts : _factsScript.removeFirst() }
    }

    var factsCalls: Int { lock.withLock { _factsCalls } }

    /// 세션의 상태를 바꾼다 (등록 파일 · 확인 사실이 같이 바뀐다)
    func setState(_ state: ClaudeAppSessionState) {
        lock.withLock {
            _session?.state = state
            _facts.session?.state = state
        }
    }

    /// 프로세스가 끝났다 (등록이 사라진다)
    func end() {
        lock.withLock {
            _session = nil
            _facts.session = nil
        }
    }

    /// 다른 프로세스가 같은 id로 뜬다 (pid가 바뀐다)
    func restart(pid: Int32) {
        lock.withLock {
            _session = Self.session(pid: pid)
            _facts.session = Self.session(pid: pid)
        }
    }
}

enum ChatRigIDs {
    static let session = ExternalSessionFixture.uuid(0xE1)
    static let other = ExternalSessionFixture.uuid(0xE2)
}

/// 한 세션 · 한 중계의 채팅 시험 장치: 가짜 중계 프로세스 · 움직이는 기록 · 가짜 서버 · 손으로 흘리는 시계. 실제 `claude` · 실제 기록 · 실제 서버는 0
@MainActor
final class ChatRig {
    let world = RigWorld()
    let clock = ClaudeAppClock()
    let launcher: FakeRelayLauncher
    let relaySleeper = ClaudeAppManualSleeper()
    let saverSleeper = ClaudeAppManualSleeper()
    let loopSleeper = ClaudeAppManualSleeper()
    let transcript = LiveTranscript()
    let put = ClaudeAppPutScript()
    let status = ClaudeAppStatusScript()
    let reports = ReportLog()
    let log = RelayLog()
    let key = ExternalSessionKey(bytes: Data(repeating: 9, count: 32))
    let mod: String
    let relay: ClaudeAppRelay
    let saver: ClaudeAppChatSaver
    let service: ClaudeAppChatService

    /// - preAsk: 시작하면서 저장 켜짐을 묻는다 (아니면 첫 보내기가 묻는다)
    init(saving: Bool = true, preAsk: Bool = true, launcher: FakeRelayLauncher = FakeRelayLauncher()) async throws {
        self.launcher = launcher
        let mod = try ClaudeAppModFixture.copy()
        self.mod = mod
        let relaySleeper = relaySleeper
        let clock = clock
        let relay = ClaudeAppRelay(
            configuration: ClaudeAppRelay.Configuration(modDirectory: mod, workDirectory: "/private/tmp/tf-relay-work"), launcher: launcher, makeNonce: { "0123456789abcdef0123456789abcdef" },
            sleep: { await relaySleeper.sleep($0) }, now: { clock.now }
        )
        self.relay = relay
        if !saving { status.queue(.failure(.server(status: 404, code: .notFound, message: ""))) }
        let saverSleeper = saverSleeper
        let saver = ClaudeAppChatSaver(status: status.status, put: put.put, now: { clock.now }, sleep: { await saverSleeper.sleep($0) }, log: log)
        self.saver = saver
        let world = world
        let key = key
        let reports = reports
        let loopSleeper = loopSleeper
        service = ClaudeAppChatService(
            environment: ClaudeAppChatEnvironment(
                relay: relay, facts: { _ in world.readFacts() }, transcript: transcript, session: { _ in world.session }, saver: saver,
                identity: { sessionID in
                    world.bridge.map { ClaudeAppChatIdentity(context: ClaudeAppChatContext(bridgeID: $0, sessionRef: key.ref(forSessionID: sessionID), title: "Title"), ref: { key.chatRef($0) }) }
                },
                report: { reports.add($0) }, now: { clock.now }, sleep: { await loopSleeper.sleep($0) }, log: log
            )
        )
        if preAsk { _ = await saver.refresh() }
    }

    func cleanup() async {
        await service.shutdown()
        ClaudeAppModFixture.cleanup(mod)
    }

    /// 우리 중계가 보낸 글이 기록에 나타난다
    func relayLine(_ text: String, id: String = "L1", messageID: String = "msg-1", pid: Int32 = 4001, at seconds: TimeInterval = 1) -> ClaudeAppTurn {
        ClaudeAppTurn(id: id, kind: .peer(text, ClaudeAppPeer(plugin: "tf-relay", verifiedPeerPID: pid, messageID: messageID)), timestamp: clock.now.addingTimeInterval(seconds))
    }

    func reply(_ text: String, id: String = "A1") -> ClaudeAppTurn { ClaudeAppTurn(id: id, kind: .assistant(text), timestamp: clock.now.addingTimeInterval(2)) }
}

extension ExternalSessionSuites {
    /// 데스크톱 세션과의 대화 흐름 전체 (PR-D3k, 계약 25장): 입력창의 글 → 보내기 전 확인 · C5 → 중계 → 전달 상태 → 기록에서 확인 → 서버 저장 · 지표.
    /// 실제 `claude` · 실제 기록 · 실제 서버는 부르지 않는다 (가짜 중계 프로세스 · 움직이는 기록 · 가짜 서버 · 손으로 흘리는 시계)
    @MainActor
    struct ClaudeAppChatServiceTests {
        let sid = ChatRigIDs.session

        /// 보내기가 끝날 때까지 (Enter → 확인 → 보냄) 한 번에 밀어 준다
        private func send(_ chat: ClaudeAppSessionChat, _ text: String, confirm: Bool = true) async {
            chat.draft = text
            await chat.submit().value
            if confirm, chat.isConfirming { await chat.confirm().value }
        }

        private func finishExchange(_ rig: ChatRig) {
            rig.transcript.append(ClaudeAppTurn(id: "U-desktop", kind: .user("typed later on the desktop"), timestamp: rig.clock.now.addingTimeInterval(9)))
        }

        @Test func contextualAcceptanceWaitsForConfirmationAndFiresOnceAtDeliveryPlacement() async throws {
            let rig = try await ChatRig()
            let chat = rig.service.chat(for: sid)
            chat.draft = "Main draft"
            var accepted = 0
            await chat.submitMessage("Context", onAccepted: {
                accepted += 1
                #expect(chat.deliveries.count == 1 && chat.deliveries.first?.text == "Context")
            }).value
            #expect(chat.isConfirming && accepted == 0)
            rig.world.restart(pid: 333)
            await chat.confirm().value
            #expect(chat.isConfirming && accepted == 0)
            await chat.confirm().value
            await chat.confirm().value
            #expect(accepted == 1 && chat.draft == "Main draft")
            await rig.cleanup()
        }

        @Test func contextualAcceptanceIsDiscardedOnCancelButFiresForANotSentDelivery() async throws {
            let rig = try await ChatRig()
            let chat = rig.service.chat(for: sid)
            var cancelled = 0
            await chat.submitMessage("Cancel context", onAccepted: { cancelled += 1 }).value
            chat.cancelConfirmation()
            await chat.confirm().value
            #expect(cancelled == 0 && chat.deliveries.isEmpty)
            rig.world.facts = ClaudeAppSendFacts(session: nil, doubled: true, processTrusted: false, otherWriters: .none)
            var blocked = 0
            await chat.submitMessage("Blocked context", onAccepted: { blocked += 1 }).value
            #expect(blocked == 1 && cancelled == 0 && chat.deliveries.first?.state == .notSent(.twoWriters))
            await rig.cleanup()
        }

        @Test func contextualConfirmationUsesCapturedTextAndPreservesAnEditedMainDraft() async throws {
            let rig = try await ChatRig()
            let chat = rig.service.chat(for: sid)
            chat.draft = "Unfinished Main draft"
            #expect(chat.canSubmitMessage("  Selected agent: check links  "))
            await chat.submitMessage("  Selected agent: check links  ").value
            #expect(chat.isConfirming && rig.launcher.launches.isEmpty)
            chat.draft = "Main draft edited while confirming"
            await chat.confirm().value
            #expect(chat.draft == "Main draft edited while confirming")
            #expect(chat.deliveries.map(\.text) == ["Selected agent: check links"])
            #expect(rig.launcher.processes[0].contents.last == "/tfsend \(sid)\nSelected agent: check links")
            await rig.cleanup()
        }

        @Test func cancellingContextualConfirmationForgetsItsTextAndKeepsNormalSubmitBehavior() async throws {
            let rig = try await ChatRig()
            let chat = rig.service.chat(for: sid)
            chat.draft = "Main draft"
            await chat.submitMessage("Selected agent context").value
            chat.cancelConfirmation()
            await chat.confirm().value
            #expect(chat.draft == "Main draft" && chat.deliveries.isEmpty && rig.launcher.launches.isEmpty)
            await chat.submit().value
            await chat.confirm().value
            #expect(chat.draft.isEmpty && chat.deliveries.map(\.text) == ["Main draft"])
            await rig.cleanup()
        }

        @Test func blockedContextualSubmissionDoesNotReachTheRelayOrClearMainDraft() async throws {
            let rig = try await ChatRig()
            let chat = rig.service.chat(for: sid)
            chat.draft = "Main draft"
            rig.world.facts = ClaudeAppSendFacts(session: nil, doubled: true, processTrusted: false, otherWriters: .none)
            await chat.submitMessage("Selected agent context").value
            #expect(chat.draft == "Main draft")
            #expect(chat.deliveries.map(\.state) == [.notSent(.twoWriters)])
            #expect(rig.launcher.launches.isEmpty)
            await rig.cleanup()
        }

        @Test func retryingABlockedContextualMessageConfirmsItsTextAndReplacesItsOwnRow() async throws {
            let rig = try await ChatRig()
            let chat = rig.service.chat(for: sid)
            chat.draft = "Main draft"
            rig.world.facts = ClaudeAppSendFacts(session: nil, doubled: true, processTrusted: false, otherWriters: .none)
            await chat.submitMessage("Selected agent context").value
            let blocked = try #require(chat.deliveries.first)
            rig.world.facts = ClaudeAppSendFacts(session: rig.world.session, doubled: false, processTrusted: true, otherWriters: .none)
            await chat.sendAgain(blocked.id).value
            #expect(chat.isConfirming && rig.launcher.launches.isEmpty)
            await chat.confirm().value
            #expect(chat.deliveries.count == 1 && chat.deliveries.first?.id != blocked.id)
            #expect(chat.deliveries.first?.text == "Selected agent context" && chat.draft == "Main draft")
            #expect(rig.launcher.processes[0].contents.last == "/tfsend \(sid)\nSelected agent context")
            await rig.cleanup()
        }

        @Test func contextualSubmissionKeepsExistingTextAndViewGates() async throws {
            let rig = try await ChatRig()
            let chat = rig.service.chat(for: sid)
            chat.draft = "Main draft"
            for text in ["", "  \n", String(repeating: "x", count: 16_001)] {
                #expect(!chat.canSubmitMessage(text))
                await chat.submitMessage(text).value
            }
            for view in [ClaudeAppSendContext.View.closed, .unreadable] {
                chat.setView(view)
                #expect(!chat.canSubmitMessage("context"))
                await chat.submitMessage("context").value
            }
            #expect(chat.deliveries.isEmpty && rig.launcher.launches.isEmpty && chat.draft == "Main draft")
            await rig.cleanup()
        }

        @Test func contextualConfirmationSurvivesPidReconfirmationWithoutReadingMainDraft() async throws {
            let rig = try await ChatRig()
            let chat = rig.service.chat(for: sid)
            chat.draft = "Main draft"
            await chat.submitMessage("Selected agent context").value
            rig.world.restart(pid: 333)
            await chat.confirm().value
            #expect(chat.isConfirming && chat.deliveries.isEmpty)
            await chat.confirm().value
            #expect(chat.deliveries.map(\.text) == ["Selected agent context"] && chat.draft == "Main draft")
            await rig.cleanup()
        }

        @Test func aQueuedContextualSubmitCannotAdoptTheNextAccountsEpoch() async throws {
            let rig = try await ChatRig()
            let oldChat = rig.service.chat(for: sid)
            let session = try #require(rig.world.session)
            oldChat.confirmation = ClaudeAppSendContext.Confirmation(pid: session.pid, procStart: session.procStart)
            oldChat.draft = "Old account Main draft"
            var accepted = 0
            let queued = oldChat.submitMessage("Old account selected agent context", onAccepted: { accepted += 1 })
            await rig.service.accountLeft()
            let fresh = rig.service.chat(for: sid)
            await queued.value
            #expect(oldChat !== fresh && accepted == 0)
            #expect(oldChat.deliveries.isEmpty && !oldChat.isConfirming)
            #expect(fresh.deliveries.isEmpty && !fresh.isConfirming && fresh.draft.isEmpty)
            #expect(rig.launcher.launches.isEmpty && rig.reports.all.isEmpty)
            // Keeping a reference to the old object cannot restore its sending rights.
            await oldChat.submitMessage("Another stale context").value
            #expect(oldChat.deliveries.isEmpty && rig.launcher.launches.isEmpty)
            await rig.cleanup()
        }

        @Test func leavingTheViewOrAccountAndShutdownCancelContextualConfirmation() async throws {
            let rig = try await ChatRig()
            var chat = rig.service.chat(for: sid)
            chat.draft = "Main draft"
            await chat.submitMessage("Context before closed view").value
            chat.setView(.closed)
            chat.setView(.open)
            await chat.confirm().value
            #expect(!chat.isConfirming && chat.draft == "Main draft" && chat.deliveries.isEmpty)
            await chat.submitMessage("Context before account leave").value
            await rig.service.accountLeft()
            await chat.confirm().value
            #expect(!chat.isConfirming && chat.deliveries.isEmpty)
            chat = rig.service.chat(for: sid)
            await chat.submitMessage("Context before shutdown").value
            await rig.service.shutdown()
            await chat.confirm().value
            #expect(!chat.isConfirming && chat.deliveries.isEmpty && rig.launcher.launches.isEmpty)
            await rig.cleanup()
        }

        // MARK: 정상 흐름 (저장 켜짐)

        @Test func theFirstSendAsksForConfirmationThenSendsAndTheTranscriptLineMakesItReceivedAndSavedWithItsReply() async throws {
            let rig = try await ChatRig()
            let chat = rig.service.chat(for: sid)
            chat.draft = "  Mention the new tests/db file  \n"
            #expect(chat.canSubmit)
            await chat.submit().value
            #expect(chat.isConfirming && chat.deliveries.isEmpty, "C5: 첫 보내기는 확인이 먼저다")
            #expect(rig.launcher.launches.isEmpty, "확인 전에는 중계로 아무것도 가지 않는다")
            #expect(chat.draft == "  Mention the new tests/db file  \n", "쓴 글은 입력창에 남는다")
            await chat.confirm().value
            #expect(!chat.isConfirming && chat.draft.isEmpty)
            #expect(chat.deliveries.map(\.text) == ["Mention the new tests/db file"], "정리한 글 그대로")
            #expect(chat.deliveries.first?.state == .sent)
            #expect(rig.launcher.processes[0].contents.last == "/tfsend \(sid)\nMention the new tests/db file")
            // 기록에 우리 줄 · 답이 나타난다
            rig.transcript.append(rig.relayLine("Mention the new tests/db file"), rig.reply("Done: the tests are mentioned."))
            await rig.service.tick()
            #expect(chat.deliveries.first?.state == .received && chat.deliveries.first?.matchedTurnID == "L1")
            #expect(chat.deliveries.first?.line == MessageDeliveryLine(strong: nil, text: "Received · via Taskforce"))
            finishExchange(rig)
            await rig.service.tick()
            rig.saverSleeper.advance(2)
            #expect(await relayEventually { rig.put.requests.count == 1 })
            let messages = rig.put.requests[0].messages
            #expect(messages.map(\.role) == ["user", "assistant"] && messages.map(\.body) == ["Mention the new tests/db file", "Done: the tests are mentioned."])
            #expect(messages[1].replyToRef == messages[0].macRef)
            #expect(rig.reports.all.isEmpty, "저장이 켜져 있으면 서버가 저장 함수에서 센다: 지표 route를 부르지 않는다")
            await rig.cleanup()
        }

        @Test func withSavingOffTheReceivedMetricGoesToTheRouteAndNothingIsPut() async throws {
            let rig = try await ChatRig(saving: false)
            let chat = rig.service.chat(for: sid)
            await send(chat, "hello")
            rig.transcript.append(rig.relayLine("hello"), rig.reply("hi"))
            await rig.service.tick()
            #expect(chat.deliveries.first?.state == .received)
            #expect(await relayEventually { rig.reports.all == [.received] })
            finishExchange(rig)
            await rig.service.tick()
            rig.saverSleeper.advance(600)
            try await Task.sleep(for: .milliseconds(40))
            #expect(rig.put.requests.isEmpty, "DT14: 저장이 꺼져 있으면 서버로 글이 가지 않는다")
            #expect(rig.reports.all == [.received], "한 번만")
            await rig.cleanup()
        }

        // MARK: C5 — 세션마다 한 번

        @Test func theConfirmCardIsOnlyForTheFirstSendOfASessionAndAgainWhenTheProcessChanged() async throws {
            let rig = try await ChatRig()
            let chat = rig.service.chat(for: sid)
            await send(chat, "one")
            rig.transcript.append(rig.relayLine("one"))
            await rig.service.tick()
            #expect(chat.deliveries[0].state == .received)
            chat.draft = "two"
            await chat.submit().value
            #expect(!chat.isConfirming && chat.deliveries.count == 2, "같은 세션의 두 번째는 확인 없이 간다")
            rig.transcript.append(rig.relayLine("two", id: "L2", messageID: "msg-2"))
            await rig.service.tick()
            // DT3: 보기를 연 뒤 대상 프로세스가 바뀌었다 → 다시 확인 줄
            rig.world.restart(pid: 222)
            chat.draft = "three"
            await chat.submit().value
            #expect(chat.isConfirming && chat.deliveries.count == 2, "pid가 바뀌었으면 다시 묻는다")
            await rig.cleanup()
        }

        @Test func anotherSessionAsksForItsOwnConfirmation() async throws {
            let rig = try await ChatRig()
            let first = rig.service.chat(for: sid)
            await send(first, "one")
            let other = rig.service.chat(for: ChatRigIDs.other)
            other.draft = "hello there"
            rig.world.facts = ClaudeAppSendFacts(session: RigWorld.session(id: ChatRigIDs.other), doubled: false, processTrusted: true, otherWriters: .none)
            await other.submit().value
            #expect(other.isConfirming, "확인은 세션마다 한 번이다")
            await rig.cleanup()
        }

        @Test func cancellingTheConfirmationKeepsTheDraftAndSendsNothing() async throws {
            let rig = try await ChatRig()
            let chat = rig.service.chat(for: sid)
            chat.draft = "hold on"
            await chat.submit().value
            chat.cancelConfirmation()
            #expect(!chat.isConfirming && chat.draft == "hold on" && chat.deliveries.isEmpty)
            #expect(rig.launcher.launches.isEmpty && rig.reports.all.isEmpty)
            await rig.cleanup()
        }

        @Test func thePidThatChangedBetweenTheCardAndTheAnswerAsksAgainInsteadOfSending() async throws {
            let rig = try await ChatRig()
            let chat = rig.service.chat(for: sid)
            chat.draft = "careful"
            await chat.submit().value
            #expect(chat.isConfirming)
            rig.world.restart(pid: 333)
            await chat.confirm().value
            #expect(chat.isConfirming && chat.deliveries.isEmpty && rig.launcher.processes.allSatisfy { !$0.contents.contains { $0.contains("careful") } }, "확인한 프로세스가 아니면 보내지 않는다")
            await chat.confirm().value
            #expect(chat.deliveries.count == 1, "새 프로세스를 보고 다시 누르면 간다")
            await rig.cleanup()
        }

        // MARK: 막힘

        @Test func twoWritersIsAnImmediateNotSentWithSendAgainAndTheMetricAndNothingGoesToTheRelay() async throws {
            let rig = try await ChatRig()
            let chat = rig.service.chat(for: sid)
            rig.world.facts = ClaudeAppSendFacts(session: nil, doubled: true, processTrusted: false, otherWriters: .none)
            chat.draft = "hello"
            await chat.submit().value
            #expect(chat.deliveries.map(\.state) == [.notSent(.twoWriters)] && !chat.isConfirming)
            #expect(chat.deliveries.first?.line == MessageDeliveryLine(strong: "Not sent", text: "Running in two places", link: .init(.sendAgain, "Send again")))
            #expect(rig.launcher.launches.isEmpty, "DT1: 보내기 0")
            #expect(await relayEventually { rig.reports.all == [.notSent(.twoWriters)] })
            await rig.cleanup()
        }

        @Test func aClosedSessionIsNotSentAndOffersNoSendAgain() async throws {
            let rig = try await ChatRig()
            let chat = rig.service.chat(for: sid)
            rig.world.end()
            chat.draft = "anyone there"
            await chat.submit().value
            #expect(chat.deliveries.first?.line == MessageDeliveryLine(strong: "Not sent", text: "Session closed"))
            #expect(rig.launcher.launches.isEmpty)
            #expect(await relayEventually { rig.reports.all == [.notSent(.sessionClosed)] })
            await rig.cleanup()
        }

        @Test func aSecondSendWaitsWhileTheFirstIsUnsettledAndTheComposerSaysSo() async throws {
            let rig = try await ChatRig()
            let chat = rig.service.chat(for: sid)
            await send(chat, "first")
            #expect(chat.hasPending && !chat.canSubmit)
            chat.draft = "second"
            #expect(!chat.canSubmit, "한 번에 하나")
            await chat.submit().value
            #expect(chat.deliveries.count == 1 && chat.draft == "second", "아무 일도 없다")
            rig.transcript.append(rig.relayLine("first"))
            await rig.service.tick()
            #expect(!chat.hasPending && chat.canSubmit, "확인되면 다음 글을 쓸 수 있다")
            await rig.cleanup()
        }

        @Test func aClosedOrUnreadableViewHasNoComposerAndNothingIsSent() async throws {
            let rig = try await ChatRig()
            let chat = rig.service.chat(for: sid)
            chat.draft = "hello"
            for view in [ClaudeAppSendContext.View.closed, .unreadable] {
                chat.setView(view)
                #expect(!chat.composerShown && !chat.canSubmit)
                await chat.submit().value
                #expect(chat.deliveries.isEmpty && !chat.isConfirming && rig.launcher.launches.isEmpty)
            }
            chat.setView(.open)
            #expect(chat.composerShown && chat.canSubmit)
            await rig.cleanup()
        }

        @Test func aTextThatIsEmptyAfterCleaningOrTooLongCannotBeSubmitted() async throws {
            let rig = try await ChatRig()
            let chat = rig.service.chat(for: sid)
            for text in ["", "   \n", "\u{200B}", String(repeating: "x", count: 16_001)] {
                chat.draft = text
                #expect(!chat.canSubmit, "\(text.count)")
            }
            chat.draft = String(repeating: "x", count: 16_000)
            #expect(chat.canSubmit)
            await rig.cleanup()
        }

        // MARK: Queued · 시간 초과 · 끝남

        @Test func whileTheTargetWaitsForApprovalTheLineIsQueuedAndTheClockStopsUntilTheLineAppears() async throws {
            let rig = try await ChatRig()
            let chat = rig.service.chat(for: sid)
            await send(chat, "use the wake handler")
            rig.world.setState(.waiting(.approval))
            await rig.service.tick()
            #expect(chat.deliveries.first?.state == .queued(.approval))
            #expect(chat.deliveries.first?.line == MessageDeliveryLine(strong: nil, text: "Queued · Needs approval in Claude"))
            rig.clock.advance(300)
            await rig.service.tick()
            #expect(chat.deliveries.first?.state == .queued(.approval), "기다리는 동안은 시간 초과가 없다")
            rig.world.setState(.busy)
            rig.transcript.append(rig.relayLine("use the wake handler"))
            await rig.service.tick()
            #expect(chat.deliveries.first?.state == .received)
            await rig.cleanup()
        }

        @Test func thirtySecondsWithoutTheLineIsNotReceivedAndTheMetricSaysSo() async throws {
            let rig = try await ChatRig()
            let chat = rig.service.chat(for: sid)
            await send(chat, "hello")
            rig.clock.advance(29)
            await rig.service.tick()
            #expect(chat.deliveries.first?.state == .sent)
            rig.clock.advance(1)
            await rig.service.tick()
            #expect(chat.deliveries.first?.state == .notSent(.notReceived))
            #expect(chat.deliveries.first?.line.link != nil)
            #expect(await relayEventually { rig.reports.all == [.notSent(.notReceived)] })
            await rig.cleanup()
        }

        @Test func aTranscriptThatSaysBypassTurnsTheTimeoutIntoTheBypassReason() async throws {
            let rig = try await ChatRig()
            rig.transcript.setMode("bypassPermissions")
            let chat = rig.service.chat(for: sid)
            await send(chat, "hello")
            rig.clock.advance(31)
            await rig.service.tick()
            #expect(chat.deliveries.first?.state == .notSent(.bypass))
            #expect(chat.deliveries.first?.line.text == "Session is in Bypass mode")
            #expect(await relayEventually { rig.reports.all == [.notSent(.bypass)] })
            await rig.cleanup()
        }

        @Test func theTargetEndingBeforeTheLineIsSessionClosedAfterTheRegistryStaysEmpty() async throws {
            let rig = try await ChatRig()
            let chat = rig.service.chat(for: sid)
            await send(chat, "hello")
            rig.world.end()
            await rig.service.tick()
            await rig.service.tick()
            #expect(chat.deliveries.first?.state == .sent, "한두 번 안 보인 것은 읽기가 흔들린 것이다")
            await rig.service.tick()
            #expect(chat.deliveries.first?.state == .notSent(.sessionClosed))
            #expect(chat.deliveries.first?.line.link == nil)
            #expect(await relayEventually { rig.reports.all == [.notSent(.sessionClosed)] })
            await rig.cleanup()
        }

        @Test func aRelayThatCannotBeLaunchedIsNotSentWithTheNotReceivedWordsAndTheRelayFailedMetric() async throws {
            let launcher = FakeRelayLauncher()
            launcher.failNext(2)
            let rig = try await ChatRig(launcher: launcher)
            let chat = rig.service.chat(for: sid)
            await send(chat, "hello")
            #expect(chat.deliveries.first?.state == .notSent(.relayFailed))
            #expect(chat.deliveries.first?.line == MessageDeliveryLine(strong: "Not sent", text: "Not received", link: .init(.sendAgain, "Send again")))
            #expect(await relayEventually { rig.reports.all == [.notSent(.relayFailed)] })
            await rig.cleanup()
        }

        // MARK: 다시 보내기

        @Test func sendAgainSendsTheSameTextAsANewDeliveryInPlaceOfTheFailedOne() async throws {
            let rig = try await ChatRig()
            let chat = rig.service.chat(for: sid)
            await send(chat, "retry me")
            rig.clock.advance(31)
            await rig.service.tick()
            let failed = try #require(chat.deliveries.first)
            #expect(failed.state == .notSent(.notReceived))
            await chat.sendAgain(failed.id).value
            #expect(chat.deliveries.count == 1, "같은 자리에서 바뀐다")
            #expect(chat.deliveries[0].id != failed.id && chat.deliveries[0].text == "retry me" && chat.deliveries[0].state == .sent)
            #expect(rig.launcher.processes[0].contents.filter { $0.hasPrefix("/tfsend") }.count == 2)
            await rig.cleanup()
        }

        // MARK: 같은 글을 두 번

        @Test func sendingTheSameTextTwiceMatchesTheNewLineNotTheOldOne() async throws {
            let rig = try await ChatRig()
            let chat = rig.service.chat(for: sid)
            await send(chat, "OK")
            rig.transcript.append(rig.relayLine("OK", id: "L1", messageID: "m1"), rig.reply("first answer", id: "A1"))
            await rig.service.tick()
            #expect(chat.deliveries[0].matchedTurnID == "L1")
            finishExchange(rig)
            await rig.service.tick()
            chat.draft = "OK"
            await chat.submit().value
            #expect(chat.deliveries.count == 2 && chat.deliveries[1].state == .sent, "앞의 줄이 있어도 새 글은 아직 확인 전이다")
            await rig.service.tick()
            #expect(chat.deliveries[1].state == .sent)
            rig.transcript.append(rig.relayLine("OK", id: "L2", messageID: "m2"))
            await rig.service.tick()
            #expect(chat.deliveries[1].matchedTurnID == "L2")
            await rig.cleanup()
        }

        // MARK: 패널을 닫아도 교환을 따라간다

        @Test func theExchangeIsFollowedAfterThePanelClosesAndEndsAtTheNextDesktopLineWithNothingBeyondIt() async throws {
            let rig = try await ChatRig()
            let chat = rig.service.chat(for: sid)
            chat.setVisible(true)
            await send(chat, "ask")
            chat.setVisible(false)
            rig.transcript.append(rig.relayLine("ask"), rig.reply("answer one", id: "A1"))
            await rig.service.tick()
            rig.transcript.append(rig.reply("answer two", id: "A2"))
            await rig.service.tick()
            rig.transcript.append(ClaudeAppTurn(id: "U1", kind: .user("SENTINEL-typed-on-desktop")), rig.reply("SENTINEL-answer-to-desktop", id: "A3"))
            await rig.service.tick()
            rig.saverSleeper.advance(2)
            #expect(await relayEventually { !rig.put.requests.isEmpty })
            let bodies = rig.put.requests.flatMap(\.messages).map(\.body)
            #expect(bodies == ["ask", "answer one", "answer two"], "데스크톱에서 친 말 이후는 올리지 않는다")
            #expect(!bodies.joined().contains("SENTINEL"))
            await rig.cleanup()
        }

        @Test func theRelayIsReleasedWhenNothingFollowsAndThePanelIsClosedSoItStopsTwoMinutesLater() async throws {
            let rig = try await ChatRig()
            let chat = rig.service.chat(for: sid)
            chat.setVisible(true)
            await send(chat, "ask")
            rig.transcript.append(rig.relayLine("ask"), rig.reply("answer"))
            await rig.service.tick()
            chat.setVisible(false)
            finishExchange(rig)
            await rig.service.tick()
            #expect(await relayEventually { rig.relaySleeper.requested.contains(120) }, "쓰는 곳이 없어졌다: 2분 시계가 돈다")
            rig.relaySleeper.advance(120)
            #expect(await relayEventually { rig.launcher.processes[0].isStopped })
            await rig.cleanup()
        }

        // MARK: 저장 (업로더)

        @Test func whenTheUploaderGivesUpTheReceivedMetricSaysNotUploaded() async throws {
            let rig = try await ChatRig()
            rig.put.queue(repeating: .retry, count: 100)
            let chat = rig.service.chat(for: sid)
            await send(chat, "hello")
            rig.transcript.append(rig.relayLine("hello"), rig.reply("hi"))
            finishExchange(rig)
            await rig.service.tick()
            for _ in 0..<80 {
                rig.clock.advance(10)
                rig.saverSleeper.advance(10)
                try await Task.sleep(for: .milliseconds(3))
            }
            #expect(await relayEventually { rig.reports.all == [.receivedButNotUploaded] })
            await rig.cleanup()
        }

        @Test func withoutABridgeIdNothingIsUploadedAndTheReceivedMetricSaysNotUploaded() async throws {
            let rig = try await ChatRig()
            rig.world.bridge = nil
            let chat = rig.service.chat(for: sid)
            await send(chat, "hello")
            rig.transcript.append(rig.relayLine("hello"), rig.reply("hi"))
            await rig.service.tick()
            finishExchange(rig)
            await rig.service.tick()
            rig.saverSleeper.advance(5)
            try await Task.sleep(for: .milliseconds(40))
            #expect(rig.put.requests.isEmpty)
            #expect(await relayEventually { rig.reports.all == [.receivedButNotUploaded] })
            await rig.cleanup()
        }

        // MARK: 글이 안 새는 곳

        @Test func reportsLogsAndRelayLaunchValuesNeverCarryTheText() async throws {
            let rig = try await ChatRig(saving: false)
            let chat = rig.service.chat(for: sid)
            await send(chat, "SENTINEL-USER-TEXT")
            rig.clock.advance(31)
            await rig.service.tick()
            #expect(await relayEventually { !rig.reports.all.isEmpty })
            #expect(!"\(rig.reports.all)".contains("SENTINEL"))
            #expect(!rig.log.text.contains("SENTINEL") && !rig.log.text.contains(sid))
            #expect(rig.log.events("claude_app_send").allSatisfy { Set($0.keys) == ["result", "reason_code"] || Set($0.keys) == ["result"] })
            #expect(rig.launcher.launches.allSatisfy { !"\($0.arguments)".contains("SENTINEL") })
            await rig.cleanup()
        }

        // MARK: 끝냄

        @Test func shutdownStopsTheFollowersTheRelayAndTheUploaderAtOnce() async throws {
            let rig = try await ChatRig()
            let chat = rig.service.chat(for: sid)
            chat.setVisible(true)
            await send(chat, "hello")
            await rig.service.shutdown()
            #expect(rig.launcher.processes[0].isStopped)
            await rig.service.tick()
            rig.transcript.append(rig.relayLine("hello"), rig.reply("hi"))
            await rig.service.tick()
            rig.saverSleeper.advance(10)
            try await Task.sleep(for: .milliseconds(40))
            #expect(rig.put.requests.isEmpty, "끝낸 뒤에는 서버로 가는 것이 없다")
            #expect(await !rig.saver.isSaving)
            ClaudeAppModFixture.cleanup(rig.mod)
        }

        @Test func accountLeftEndsEverythingForgetsTheChatsAndTheServiceWorksForTheNextAccount() async throws {
            let rig = try await ChatRig()
            let chat = rig.service.chat(for: sid)
            chat.draft = "unsent draft of the old account"
            await send(chat, "hello")
            await rig.service.accountLeft()
            #expect(rig.launcher.processes[0].isStopped)
            let fresh = rig.service.chat(for: sid)
            #expect(fresh !== chat && fresh.deliveries.isEmpty && fresh.draft.isEmpty && !fresh.isConfirming, "이 계정의 입력 상태는 남지 않는다")
            await send(fresh, "from the next account")
            #expect(fresh.deliveries.count == 1 && rig.launcher.launches.count == 2, "서비스는 다음 계정으로 다시 쓴다")
            await rig.cleanup()
        }

        /// OA PR-D3 검토 P2-3 (§25.4.3 ⑧): 저장 켜짐 확인은 보내기를 막지 않는다 — 처음 한 번 부르되 기다리지 않는다. 올리는 길은 확인이 켜짐이라고 답한 뒤에만 있다 (그 전에는 PUT 0)
        @Test func theSendDoesNotWaitForTheStatusAndNothingIsPutBeforeItAnswers() async throws {
            let rig = try await ChatRig(preAsk: false)
            rig.status.hold()
            #expect(rig.status.calls == 0, "만들기만 해서는 서버를 부르지 않는다")
            let chat = rig.service.chat(for: sid)
            await send(chat, "hello")
            #expect(chat.deliveries.first?.state == .sent, "status가 아직 답하지 않아도 보냈다")
            #expect(rig.launcher.processes.first?.contents.contains { $0.hasPrefix("/tfsend") } == true)
            rig.transcript.append(rig.relayLine("hello"), rig.reply("hi"))
            finishExchange(rig)
            let ticking = Task { await rig.service.tick() }
            try await Task.sleep(for: .milliseconds(60))
            rig.saverSleeper.advance(5)
            try await Task.sleep(for: .milliseconds(40))
            #expect(rig.put.requests.isEmpty, "status가 답하기 전에는 올리지 않는다")
            rig.status.release()
            await ticking.value
            #expect(rig.status.calls == 1, "처음 한 번만 물었다")
            rig.saverSleeper.advance(2)
            #expect(await relayEventually { rig.put.requests.count == 1 }, "켜짐이라고 답한 뒤에는 그 교환이 올라간다 (받았다는 지표는 저장 함수가 센다)")
            #expect(rig.put.requests.first?.messages.map(\.body) == ["hello", "hi"] && rig.reports.all.isEmpty)
            await rig.cleanup()
        }

        // MARK: 글 없는 경계 (OA PR-D3 검토 P2-1, DT11)

        @Test func aPromptTypedOnTheDesktopMidTurnEndsTheExchangeAndItsAnswerIsNeverUploaded() async throws {
            let rig = try await ChatRig()
            let chat = rig.service.chat(for: sid)
            await send(chat, "ask")
            rig.transcript.append(rig.relayLine("ask"), rig.reply("answer before the boundary", id: "A1"))
            await rig.service.tick()
            rig.transcript.append(ClaudeAppTurn(id: "B1", kind: .boundary, timestamp: rig.clock.now.addingTimeInterval(5)), rig.reply("SENTINEL-answer-to-the-desktop-prompt", id: "A2"))
            await rig.service.tick()
            rig.saverSleeper.advance(2)
            #expect(await relayEventually { !rig.put.requests.isEmpty })
            try await Task.sleep(for: .milliseconds(40))
            let bodies = rig.put.requests.flatMap(\.messages).map(\.body)
            #expect(bodies == ["ask", "answer before the boundary"], "경계 뒤의 답은 우리가 보낸 말에 대한 답이 아니다")
            #expect(!bodies.joined().contains("SENTINEL"))
            await rig.cleanup()
        }

        // MARK: 쓰기 직전에 다시 확인 (OA PR-D3 검토 P2-2, TOCTOU · DT1 · DT3 · DT9)

        @Test func theTargetIsReadAgainRightBeforeTheWriteAndAnythingThatChangedMeansNothingIsSent() async throws {
            let ok = ClaudeAppSendFacts(session: RigWorld.session(), doubled: false, processTrusted: true, otherWriters: .none)
            let changes: [(String, ClaudeAppSendFacts)] = [
                ("대상 프로세스가 바뀌었다", ClaudeAppSendFacts(session: RigWorld.session(pid: 222), doubled: false, processTrusted: true, otherWriters: .none)),
                ("다른 writer가 생겼다", ClaudeAppSendFacts(session: RigWorld.session(), doubled: false, processTrusted: true, otherWriters: .found)),
                ("writer를 알 수 없다", ClaudeAppSendFacts(session: RigWorld.session(), doubled: false, processTrusted: true, otherWriters: .unknown)),
                ("서명 · 조상이 맞지 않는다", ClaudeAppSendFacts(session: RigWorld.session(), doubled: false, processTrusted: false, otherWriters: .none)),
                ("같은 id의 등록이 둘이 됐다", ClaudeAppSendFacts(session: nil, doubled: true, processTrusted: false, otherWriters: .none)),
                ("등록이 사라졌다", ClaudeAppSendFacts(session: nil, doubled: false, processTrusted: false, otherWriters: .none)),
                ("등록 폴더를 읽을 수 없다", ClaudeAppSendFacts(session: nil, doubled: false, processTrusted: false, otherWriters: .none, registryUnavailable: true)),
            ]
            for (why, changed) in changes {
                let rig = try await ChatRig()
                let chat = rig.service.chat(for: sid)
                chat.draft = "careful with this one"
                await chat.submit().value
                #expect(chat.isConfirming, "\(why): 먼저 C5")
                rig.world.script(ok, changed)    // 확인을 누른 뒤의 확인은 그대로, 쓰기 직전의 확인에서 달라진다
                await chat.confirm().value
                #expect(chat.deliveries.map(\.state) == [.notSent(.notReceived)], "\(why)")
                #expect(rig.launcher.processes.allSatisfy { !$0.contents.contains { $0.hasPrefix("/tfsend") } }, "\(why): 글이 중계로 가지 않았다")
                #expect(await relayEventually { rig.reports.all == [.notSent(.notReceived)] }, "\(why)")
                await rig.cleanup()
            }
            // 달라진 것이 없으면 간다
            let rig = try await ChatRig()
            let chat = rig.service.chat(for: sid)
            chat.draft = "all good"
            await chat.submit().value
            rig.world.script(ok, ok)
            await chat.confirm().value
            #expect(chat.deliveries.first?.state == .sent)
            await rig.cleanup()
        }

        // MARK: 계정 세대 (OA PR-D3 검토 P3-6) · 떠난 뒤의 중계 (P3-9)

        @Test func anAccountThatLeavesWhileTheFactsAreBeingReadNeverGetsItsTextSentOrAnythingShown() async throws {
            let rig = try await ChatRig()
            let chat = rig.service.chat(for: sid)
            chat.draft = "text of the account that is leaving"
            rig.world.holdFacts()
            let submitting = chat.submit()
            #expect(await relayEventually { rig.world.factsCalls == 1 }, "사실을 읽는 중이다")
            await rig.service.accountLeft()
            rig.world.releaseFacts()
            await submitting.value
            #expect(!chat.isConfirming && chat.deliveries.isEmpty, "떠난 계정의 입력 상태에는 아무것도 생기지 않는다")
            #expect(rig.launcher.launches.isEmpty && rig.reports.all.isEmpty)
            let next = rig.service.chat(for: sid)
            #expect(next !== chat && next.deliveries.isEmpty && !next.isConfirming && next.draft.isEmpty, "다음 계정에는 아무것도 넘어가지 않는다")
            await rig.cleanup()
        }

        @Test func aRelayPrepareQueuedBeforeTheAccountLeftNeverLaunchesTheRelayAfterwards() async throws {
            let rig = try await ChatRig()
            let chat = rig.service.chat(for: sid)
            chat.setVisible(true)
            await rig.service.accountLeft()
            try await Task.sleep(for: .milliseconds(150))
            #expect(rig.launcher.launches.isEmpty, "떠난 계정이 걸어 둔 미리 띄우기는 버려진다")
            await rig.cleanup()
        }

        /// OA PR-D3 재검토 security P3-c: 쓰기 직전 확인(`recheck`) 자체가 계정 세대를 본다. 로그아웃이 중계를 끝내기 전이라도(세대가 먼저 오른다) 확인이 거짓이어야 글이 나가지 않는다.
        /// (중계가 이미 끝났는지는 따로 본다: 이 시험은 확인 클로저 하나만 부른다)
        @Test func theRecheckBeforeTheWriteFailsOnceTheAccountEpochChangedAndDoesNotEvenReadTheTarget() async throws {
            let rig = try await ChatRig()
            let original = rig.world.facts
            let check = rig.service.recheck(sessionID: sid, original: original, epoch: 0)
            #expect(await check(), "아무것도 달라지지 않았으면 통과한다 (이 확인이 없으면 아래 '거짓'은 뜻이 없다)")
            let reads = rig.world.factsCalls
            await rig.service.accountLeft()
            #expect(await check() == false, "계정이 떠났다: 글을 쓰지 않는다")
            #expect(rig.world.factsCalls == reads, "떠난 계정을 위해 대상을 다시 읽지도 않는다")
            await rig.cleanup()
        }

        @Test func theRecheckAlsoFailsWhenTheAccountLeavesWhileTheTargetIsBeingRead() async throws {
            let rig = try await ChatRig()
            let check = rig.service.recheck(sessionID: sid, original: rig.world.facts, epoch: 0)
            let reads = rig.world.factsCalls
            rig.world.holdFacts()
            let running = Task { await check() }
            #expect(await relayEventually { rig.world.factsCalls == reads + 1 }, "대상을 읽는 중이다")
            await rig.service.accountLeft()
            rig.world.releaseFacts()
            #expect(await running.value == false, "읽는 동안 계정이 떠났다: 읽은 값이 같아도 쓰지 않는다")
            await rig.cleanup()
        }

        @Test func afterTheQuitShutdownTheRelayIsNeverStartedAgain() async throws {
            let rig = try await ChatRig()
            let chat = rig.service.chat(for: sid)
            await send(chat, "before quitting")
            rig.service.stopRelayForQuit(timeout: 5)
            #expect(rig.launcher.processes.first?.isStopped == true)
            chat.setVisible(true)
            let again = rig.service.chat(for: ChatRigIDs.other)
            again.setVisible(true)
            try await Task.sleep(for: .milliseconds(150))
            #expect(rig.launcher.launches.count == 1, "종료가 정해진 뒤에는 미리 띄우기도 보내기도 중계를 다시 띄우지 않는다")
            #expect(await rig.relay.send(sessionID: sid, text: "too late") == .notDelivered(.relayFailed))
            #expect(rig.launcher.launches.count == 1)
            await rig.cleanup()
        }

        // MARK: 우리 글은 "다른 세션"으로 바뀌지 않는다 (OA PR-D3 검토 P2-4)

        @Test func ourOwnLineKeepsItsReceivedLineAfterTheRelayStoppedOrWasReplacedWhileAForeignPidDoesNot() async throws {
            let rig = try await ChatRig()
            let chat = rig.service.chat(for: sid)
            await send(chat, "ask")
            rig.transcript.append(rig.relayLine("ask"))
            await rig.service.tick()
            let ours = rig.relayLine("ask")
            // 이 보내기로 확인된 줄이 아닌 앞선 줄(다른 id)도 pid로 알아본다: 중계(4001)가 떠 있던 동안 쓴 글이다
            let earlier = rig.relayLine("an earlier message", id: "L77", messageID: "m77", pid: 4001)
            rig.clock.advance(30)
            await rig.relay.shutdown()
            #expect(rig.service.relayPIDs.current.isEmpty)
            let received = MessageDeliveryLine(strong: nil, text: "Received · via Taskforce")
            let foreign = MessageDeliveryLine(strong: nil, text: "From another session")
            #expect(rig.service.peerLine(for: ours, in: sid) == received, "중계가 멈춘 뒤에도 이 실행이 띄운 중계가 보낸 글이다")
            #expect(rig.service.peerLine(for: earlier, in: sid) == received, "pid로 알아본다: 지금 떠 있는 중계가 아니어도 이 실행이 띄운 pid다")
            // 다른 중계(pid 4002)가 떠도 앞 중계의 글은 그대로
            await send(rig.service.chat(for: ChatRigIDs.other), "second")
            #expect(rig.service.peerLine(for: earlier, in: sid) == received)
            #expect(rig.service.peerLine(for: rig.relayLine("x", id: "L9", messageID: "m9", pid: 9999), in: sid) == foreign, "이 실행이 띄운 적 없는 pid는 우리 것이 아니다")
            let named = ClaudeAppTurn(id: "L1", kind: .peer("ask", ClaudeAppPeer(plugin: nil, verifiedPeerPID: nil, messageID: nil)))
            #expect(rig.service.peerLine(for: named, in: sid) == received, "이 보내기로 기록에서 확인된 줄은 pid를 몰라도 우리 것이다")
            #expect(rig.service.peerLine(for: ClaudeAppTurn(id: "A1", kind: .assistant("hi")), in: sid) == nil, "peer 줄이 아니면 줄이 없다")
            await rig.cleanup()
        }

        @Test func theRelayPIDSetIsObservableSoThePeerLinesRedrawWhenItChangesAndKeepsEveryPIDLaunchedThisRun() {
            let pids = ClaudeAppRelayPIDs()
            let fired = ClaudeAppFlag()
            withObservationTracking { _ = pids.launched } onChange: { fired.set() }
            pids.set([4001])
            #expect(fired.isSet, "pid가 바뀌면 그린 쪽이 다시 그려진다")
            pids.set([])
            pids.set([4002])
            #expect(pids.current == [4002] && pids.launched == [4001, 4002], "이 실행이 띄운 모든 중계 pid를 기억한다")
        }

        // MARK: pid가 우리 것이던 때 (OA PR-D3 재검토 security P3-new-1 · code P3-R3)

        /// pid는 운영체제가 다시 쓴다: 우리 중계가 끝난 뒤 같은 pid를 받은 다른 프로세스가 `tf-relay`를 흉내 내 보낸 글을 우리 것으로 보면 안 된다.
        /// 그래서 pid마다 **띄운 때 ~ 끝난 때**를 기억하고, 글의 시각이 그 안에 있을 때만 우리 것이다. 시각이 없으면 우리 것이 아니다
        @Test func aPIDCountsAsOurRelayOnlyForTheTimeItRanAndALineWithoutATimeNeverCounts() {
            let pids = ClaudeAppRelayPIDs()
            let t0 = Date(timeIntervalSince1970: 1_800_000_000)
            func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }
            pids.set([4001], at: t0)
            #expect(pids.ran(4001, at: at(30)), "떠 있는 동안")
            #expect(pids.ran(4001, at: at(10_000)), "아직 떠 있다: 끝이 열려 있다")
            #expect(!pids.ran(4001, at: at(-1)), "띄우기 전의 글은 우리 중계의 글이 아니다 (앞 실행 · 다른 프로세스)")
            #expect(!pids.ran(4001, at: nil), "시각이 없으면 우리 것이 아니다")
            #expect(!pids.ran(9999, at: at(30)), "띄운 적 없는 pid")
            pids.set([], at: at(100))
            #expect(pids.ran(4001, at: at(100)) && pids.ran(4001, at: at(101)), "끝난 순간 · 직후 1초는 같은 중계의 글이다 (기록에 적히는 시각의 어긋남)")
            #expect(!pids.ran(4001, at: at(110)), "끝난 뒤의 글은 같은 pid라도 우리 것이 아니다")
            pids.set([4001], at: at(500))
            #expect(!pids.ran(4001, at: at(300)), "두 번 떠 있던 사이는 아니다")
            #expect(pids.ran(4001, at: at(501)) && pids.ran(4001, at: at(50)), "각 시기는 따로 센다")
            pids.set([4001, 4002], at: at(600))
            #expect(pids.ran(4001, at: at(550)) && !pids.ran(4002, at: at(550)) && pids.ran(4002, at: at(601)), "이미 떠 있는 pid의 시기는 그대로, 새 pid만 새로 센다")
        }

        @Test func theRelayRecordsWhenEachOfItsProcessesRanFromItsOwnClock() async throws {
            let clock = ClaudeAppClock()
            let launcher = FakeRelayLauncher()
            let sleeper = ClaudeAppManualSleeper()
            let mod = try ClaudeAppModFixture.copy()
            defer { ClaudeAppModFixture.cleanup(mod) }
            let relay = ClaudeAppRelay(
                configuration: ClaudeAppRelay.Configuration(modDirectory: mod, workDirectory: "/private/tmp/tf-relay-work"), launcher: launcher, makeNonce: { "0123456789abcdef0123456789abcdef" },
                sleep: { await sleeper.sleep($0) }, now: { clock.now }
            )
            let launchedAt = clock.now
            #expect(await relay.send(sessionID: sid, text: "one") == .delivered(relayPID: 4001))
            clock.advance(60)
            await relay.shutdown()
            let stoppedAt = clock.now
            clock.advance(600)
            #expect(relay.pids.ran(4001, at: launchedAt.addingTimeInterval(30)), "떠 있던 동안")
            #expect(!relay.pids.ran(4001, at: launchedAt.addingTimeInterval(-5)), "띄우기 전")
            #expect(!relay.pids.ran(4001, at: stoppedAt.addingTimeInterval(20)), "끝난 뒤")
        }

        @Test func aLineFromTheSamePIDOutsideTheTimeTheRelayRanOrWithoutATimeIsFromAnotherSessionUnlessThisSendConfirmedIt() async throws {
            let rig = try await ChatRig()
            let chat = rig.service.chat(for: sid)
            await send(chat, "ask")
            rig.clock.advance(100)
            let during = rig.relayLine("during", id: "L5", messageID: "m5", pid: 4001, at: -50)
            let beforeLaunch = rig.relayLine("before", id: "L6", messageID: "m6", pid: 4001, at: -150)
            await rig.relay.shutdown()
            rig.clock.advance(60)
            let afterStop = rig.relayLine("after", id: "L7", messageID: "m7", pid: 4001, at: -10)
            let noTime = ClaudeAppTurn(id: "L8", kind: .peer("x", ClaudeAppPeer(plugin: "tf-relay", verifiedPeerPID: 4001, messageID: "m8")), timestamp: nil)
            let received = MessageDeliveryLine(strong: nil, text: "Received · via Taskforce")
            let foreign = MessageDeliveryLine(strong: nil, text: "From another session")
            #expect(rig.service.peerLine(for: during, in: sid) == received, "중계가 떠 있던 동안의 글")
            #expect(rig.service.peerLine(for: beforeLaunch, in: sid) == foreign, "띄우기 전의 글: 같은 pid를 쓰던 다른 프로세스일 수 있다")
            #expect(rig.service.peerLine(for: afterStop, in: sid) == foreign, "끝난 뒤의 글: 같은 pid를 받은 다른 프로세스일 수 있다")
            #expect(rig.service.peerLine(for: noTime, in: sid) == foreign, "시각이 없으면 우리 것이 아니다")
            rig.transcript.append(rig.relayLine("ask", id: "Lmatched", messageID: "m-ok", pid: 4001, at: -120))
            await rig.service.tick()
            let matched = ClaudeAppTurn(id: "Lmatched", kind: .peer("ask", ClaudeAppPeer(plugin: nil, verifiedPeerPID: nil, messageID: nil)), timestamp: nil)
            #expect(chat.deliveries.first?.matchedTurnID == "Lmatched")
            #expect(rig.service.peerLine(for: matched, in: sid) == received, "이 보내기로 기록에서 확인된 줄은 시각이 없어도 우리 것이다")
            await rig.cleanup()
        }

        // MARK: 이미 센 글 (OA PR-D3 검토 P3-12)

        @Test func whenTheUploaderGivesUpAfterTheUserRowWasSavedTheReceivedMetricIsNotReportedTwice() async throws {
            let rig = try await ChatRig()
            rig.put.queue(.saved(chatID: UUID()))
            rig.put.queue(repeating: .retry, count: 100)
            let chat = rig.service.chat(for: sid)
            await send(chat, "hello")
            rig.transcript.append(rig.relayLine("hello"), rig.reply("first answer", id: "A1"))
            await rig.service.tick()
            rig.saverSleeper.advance(2)
            #expect(await relayEventually { rig.put.requests.count == 1 }, "사용자 행이 먼저 올라갔다")
            rig.transcript.append(rig.reply("second answer", id: "A2"))
            await rig.service.tick()
            finishExchange(rig)
            await rig.service.tick()
            for _ in 0..<80 {
                rig.clock.advance(10)
                rig.saverSleeper.advance(10)
                try await Task.sleep(for: .milliseconds(3))
            }
            #expect(await relayEventually { rig.put.requests.count > 1 }, "뒤의 답 행은 다시 시도했다")
            try await Task.sleep(for: .milliseconds(60))
            #expect(rig.reports.all.isEmpty, "사용자 행은 서버가 이미 `received`로 셌다: 답 행을 포기해도 다시 세지 않는다")
            await rig.cleanup()
        }

        // MARK: 모르는 baseline (OA PR-D3 검토 P3-13)

        @Test func ifTheTranscriptCouldNotBeOpenedBeforeTheSendAnEarlierIdenticalLineFromTheSameRelayIsNotTaken() async throws {
            let rig = try await ChatRig()
            rig.transcript.append(rig.relayLine("OK", id: "Lold", messageID: "m-old", pid: 4001, at: -50))
            rig.transcript.setUnreadable(true)
            let chat = rig.service.chat(for: sid)
            await send(chat, "OK")
            rig.transcript.setUnreadable(false)
            await rig.service.tick()
            #expect(chat.deliveries.first?.state == .sent && chat.deliveries.first?.matchedTurnID == nil, "보내기 전에 기록에 있던 같은 글은 이번 것이 아니다")
            rig.transcript.append(rig.relayLine("OK", id: "Lnew", messageID: "m-new", pid: 4001, at: 3))
            await rig.service.tick()
            #expect(chat.deliveries.first?.state == .received && chat.deliveries.first?.matchedTurnID == "Lnew")
            await rig.cleanup()
        }

        // MARK: peer 줄의 표시

        @Test func aPeerLineIsReceivedViaTaskforceOnlyForOurRelayProcessAndOtherwiseFromAnotherSession() {
            let ours = ClaudeAppPeer(plugin: "tf-relay", verifiedPeerPID: 4001, messageID: "m")
            let sameNameOtherProcess = ClaudeAppPeer(plugin: "tf-relay", verifiedPeerPID: 9999, messageID: "m")
            let otherPlugin = ClaudeAppPeer(plugin: "someone", verifiedPeerPID: 4001, messageID: "m")
            let unknown = ClaudeAppPeer(plugin: nil, verifiedPeerPID: nil, messageID: nil)
            let received = MessageDeliveryLine(strong: nil, text: "Received · via Taskforce")
            let foreign = MessageDeliveryLine(strong: nil, text: "From another session")
            let time = Date(timeIntervalSince1970: 1_800_000_050)
            let running = ClaudeAppRelayPIDs()
            running.set([4001], at: Date(timeIntervalSince1970: 1_800_000_000))
            #expect(ClaudeAppPeerLine.of(ours, at: time, relayPIDs: running) == received)
            #expect(ClaudeAppPeerLine.of(sameNameOtherProcess, at: time, relayPIDs: running) == foreign, "tf-relay라는 이름만으로 믿지 않는다")
            #expect(ClaudeAppPeerLine.of(otherPlugin, at: time, relayPIDs: running) == foreign)
            #expect(ClaudeAppPeerLine.of(unknown, at: time, relayPIDs: running) == foreign)
            #expect(ClaudeAppPeerLine.of(ours, at: nil, relayPIDs: running) == foreign, "시각이 없으면 우리 것이 아니다")
            #expect(ClaudeAppPeerLine.of(ours, at: time, relayPIDs: ClaudeAppRelayPIDs()) == foreign, "이 실행이 띄운 중계가 없으면 앞 실행의 것은 확인할 수 없다")
        }

        // MARK: 게이트

        @Test func theGateIsOnInDebugAndInternalBuildsAndOffInRelease() {
            #expect(ClaudeAppRelayGate.isEnabled(isDebugBuild: true, isInternalBuild: false))
            #expect(ClaudeAppRelayGate.isEnabled(isDebugBuild: false, isInternalBuild: true))
            #expect(ClaudeAppRelayGate.isEnabled(isDebugBuild: true, isInternalBuild: true))
            #expect(!ClaudeAppRelayGate.isEnabled(isDebugBuild: false, isInternalBuild: false), "릴리스는 늘 꺼짐")
        }
    }
}
#endif
