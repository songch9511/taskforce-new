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

    func readFacts() -> ClaudeAppSendFacts { lock.withLock { _factsCalls += 1; return _facts } }
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
        let relay = ClaudeAppRelay(
            configuration: ClaudeAppRelay.Configuration(modDirectory: mod, workDirectory: "/private/tmp/tf-relay-work"), launcher: launcher, makeNonce: { "0123456789abcdef0123456789abcdef" },
            sleep: { await relaySleeper.sleep($0) }
        )
        self.relay = relay
        if !saving { status.queue(.failure(.server(status: 404, code: .notFound, message: ""))) }
        let saverSleeper = saverSleeper
        let clock = clock
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

        @Test func theStatusIsAskedBeforeTheFirstTextReachesTheRelay() async throws {
            let rig = try await ChatRig(preAsk: false)
            let observed = ClaudeAppFlag()
            let launcher = rig.launcher
            rig.status.onCall = {
                if launcher.processes.contains(where: { $0.contents.contains { $0.hasPrefix("/tfsend") } }) { observed.set() }
            }
            #expect(rig.status.calls == 0)
            let chat = rig.service.chat(for: sid)
            await send(chat, "hello")
            #expect(rig.status.calls == 1 && !observed.isSet, "글이 중계에 닿기 전에 저장 켜짐을 물었다")
            #expect(chat.deliveries.first?.state == .sent, "물은 뒤에 보냈다")
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
            #expect(ClaudeAppPeerLine.of(ours, relayPIDs: [4001]) == received)
            #expect(ClaudeAppPeerLine.of(sameNameOtherProcess, relayPIDs: [4001]) == foreign, "tf-relay라는 이름만으로 믿지 않는다")
            #expect(ClaudeAppPeerLine.of(otherPlugin, relayPIDs: [4001]) == foreign)
            #expect(ClaudeAppPeerLine.of(unknown, relayPIDs: [4001]) == foreign)
            #expect(ClaudeAppPeerLine.of(ours, relayPIDs: []) == foreign, "지금 떠 있는 중계가 없으면 앞 실행의 것은 확인할 수 없다")
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
