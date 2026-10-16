import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import Taskforce
@testable import TaskforceKit
@testable import TaskforceUI

/// 손으로 돌리는 잠들기 (질문 보류 · 종료 기다림): 걸린 지연을 `fire()`로 부른다. 취소된 잠들기는 대기열에서 빠진다
final class QuestionTicker: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [(id: UUID, delay: TimeInterval, continuation: CheckedContinuation<Void, Never>)] = []

    var pendingDelays: [TimeInterval] { lock.withLock { waiters.map(\.delay) } }

    func sleep(_ delay: TimeInterval) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.withLock { waiters.append((id, delay, continuation)) }
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
        let next = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            guard !waiters.isEmpty else { return nil }
            return waiters.removeFirst().continuation
        }
        next?.resume()
    }
}

/// 질문 카드 (OA D4b-m-1, 격리 호스트): Assistant 창과 세션 패널이 질문 저장소 하나를 같이 본다. 서버는 가짜(`AgentChatSampleGateway`: 렌더 fixture)이고 창은 만들되 화면에 올리지 않는다.
/// 실제 서버 · 계정 · `claude` 실행 · 시스템 알림 센터가 없다. 보류의 2초는 손으로 돌린다
@MainActor
struct AssistantQuestionTests {
    typealias Data = AgentChatSampleData
    typealias Q = QuestionSampleData
    typealias Fx = IssueSnapshotData

    @MainActor
    struct Rig {
        let controller: EdgeShellController
        let runtime: ChatRuntime
        let gateway: AgentChatSampleGateway
        let ticker: QuestionTicker
        let center: FakeNotificationCenter
        let defaults: TestDefaults
        let account: AppChatAccount

        var shell: EdgeShellModel { controller.shell }
        var manager: AssistantWindowManager { controller.assistant! }
        var questions: AgentQuestionStore { runtime.questions! }
        var chat: ChatStore { runtime.chat }

        func stop() { defaults.cleanup(); controller.assistant?.closeAll() }

        /// 보류 시계가 걸릴 때까지 기다렸다가 돌린다
        func fire() async {
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while ticker.pendingDelays.isEmpty, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
            ticker.fire()
        }
    }

    static func rig(_ scene: AgentChatSampleGateway.State, agentQuestions: Bool = true, issueScreens: Bool = true, secrets: (any LocalSecretAnswerSubmitting)? = nil) async throws -> Rig {
        let account = try AppChatAccount.make()
        let gateway = AgentChatSampleGateway()
        gateway.state = scene
        let ticker = QuestionTicker()
        let center = FakeNotificationCenter()
        let runtime = ChatRuntime(
            gateway: gateway, contextGateway: IssueSampleContextGateway(), scope: account.scope, now: { Date() }, issueScreens: issueScreens, agentQuestions: agentQuestions,
            secretSubmitter: secrets, notificationCenter: center, questionSleep: { await ticker.sleep($0) }
        )
        let defaults = try TestDefaults()
        let controller = EdgeShellController(
            launcher: LauncherModel(configurationError: "test"), chat: runtime, assistantWindows: true, positionStore: AssistantWindowPositionStore(defaults: defaults.defaults)
        )
        controller.assistant?.presents = false
        controller.ignoresExternalDismissal = false
        controller.shell.localBridgeIDProvider = { Data.thisMacBridge }
        controller.shell.update(Fx.snapshot(seeds: Fx.seeds))
        await runtime.targets.refresh()
        await runtime.chat.refresh()
        if issueScreens {
            await runtime.issues?.numbers.ensure(Fx.seeds.map { Fx.issue($0.number) })
            await runtime.issues?.sessions.refresh()
            controller.shell.sessionsChanged()
            await controller.shell.refreshThisMac()
        }
        runtime.questions?.thisMacBridgeID = Data.thisMacBridge
        return Rig(controller: controller, runtime: runtime, gateway: gateway, ticker: ticker, center: center, defaults: defaults, account: account)
    }

    /// 대화를 보이는 창 하나 (세션 · 질문 읽기가 끝난 뒤)
    func open(_ r: Rig) async throws -> AssistantWindowModel {
        let id = try #require(r.manager.openWindow(for: Data.conversationID))
        let model = try #require(r.manager.controllers[id]?.model)
        await r.chat.settle()
        await model.agent?.sessions.refresh()
        await r.questions.settle()
        return model
    }

    func key(_ code: Int, _ characters: String) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: UInt16(code)
        ))
    }

    func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    var session: UUID { Data.sessionID }

    // MARK: Assistant 창

    @Test func aSessionWaitingForAnAnswerGetsItsCardInTheWindowThroughTheSharedStore() async throws {
        let r = try await Self.rig(Q.world(Q.single))
        defer { r.stop() }
        let model = try await open(r)
        let entry = try #require(r.questions.entry(session: session))
        #expect(entry.card.kind == .single && entry.phase == .open && entry.card.showsKeycaps)
        #expect(model.questions === r.questions && model.sessionID == session && !model.isBlocked, "일반 질문은 composer를 막지 않는다")
        #expect(r.gateway.calls(prefix: "openQuestions").count >= 1, "질문 읽기는 서버(RLS)에서")
    }

    @Test func aSecretQuestionBlocksTheWindowsPromptBoxWithTheStandardWords() async throws {
        let r = try await Self.rig(Q.world(Q.secret))
        defer { r.stop() }
        let model = try await open(r)
        #expect(r.questions.entry(session: session)?.card.kind == .secret)
        #expect(model.isBlocked && model.placeholder == "Answer the question above first" && !model.canSend("a token typed in the composer"))
    }

    @Test func aSecretQuestionOnAnotherMacShowsTheRemoteCardWithTheMacNameAndAlsoBlocks() async throws {
        let r = try await Self.rig(Q.world(Q.secret, bridge: Data.otherMacBridge, names: [Data.otherMacBridge: "Mina's MacBook Pro"]))
        defer { r.stop() }
        let model = try await open(r)
        #expect(await eventually { r.questions.entry(session: session)?.card.macName == "Mina's MacBook Pro" })
        #expect(r.questions.entry(session: session)?.card.kind == .secretRemote && model.isBlocked)
    }

    @Test func pickingARowFoldsAtOnceHoldsTwoSecondsAndSendsOneRequest() async throws {
        let r = try await Self.rig(Q.world(Q.single))
        defer { r.stop() }
        _ = try await open(r)
        r.questions.choose(row: 2, session: session)
        #expect(r.questions.entry(session: session)?.phase == .holding && r.gateway.calls(prefix: "answer:").isEmpty)
        r.questions.choose(row: 1, session: session)
        await r.fire()
        #expect(await eventually { r.questions.entry(session: session)?.phase == .sent })
        #expect(r.gateway.calls(prefix: "answer:") == ["answer:\(Q.task.uuidString):\(Q.request)"], "두 번 눌러도 요청은 하나")
        #expect(r.questions.entry(session: session)?.summary == "Yearly total")
    }

    @Test func undoInsideTheWindowSendsNothingAndTheCardComesBack() async throws {
        let r = try await Self.rig(Q.world(Q.single))
        defer { r.stop() }
        _ = try await open(r)
        r.questions.choose(row: 0, session: session)
        r.questions.undo(session: session)
        #expect(r.questions.entry(session: session)?.phase == .open && r.ticker.pendingDelays.isEmpty)
        try? await Task.sleep(for: .milliseconds(80))
        #expect(r.gateway.calls(prefix: "answer:").isEmpty)
    }

    @Test func aFailedSendBringsTheCardBackWithTheOfflineReason() async throws {
        let r = try await Self.rig(Q.world(Q.single))
        defer { r.stop() }
        _ = try await open(r)
        r.gateway.answerFailure = APIError.transport("offline")
        r.questions.choose(row: 0, session: session)
        await r.fire()
        #expect(await eventually { r.questions.entry(session: session)?.failure == .offline })
        #expect(r.questions.entry(session: session)?.phase == .open)
    }

    @Test func theServersAnsweredLineReplacesTheSentRowAfterTheConversationIsReread() async throws {
        let r = try await Self.rig(Q.world(Q.single))
        defer { r.stop() }
        r.gateway.closesOnAnswer = true
        _ = try await open(r)
        r.questions.choose(row: 0, session: session)
        await r.fire()
        #expect(await eventually { r.chat.eventKeys(in: Data.conversationID).contains(AgentQuestionStore.sentEventKey(AgentQuestionKey(taskID: Q.task, requestID: Q.request))) },
                "서버가 사건 줄을 썼고 앱이 그 대화를 다시 읽었다")
        // 다음 읽기에서 질문이 사라졌다: 카드 자리가 비었다
        await r.questions.settle()
        #expect(await eventually { r.questions.entry(session: session) == nil })
        #expect(r.chat.turns(for: Data.conversationID).contains { $0.isEvent && $0.text == "Answered" })
    }

    @Test func twoWindowsOnTheSameSessionShareOneStateAndOneRequest() async throws {
        let r = try await Self.rig(Q.world(Q.single))
        defer { r.stop() }
        let first = try await open(r)
        let second = try #require(r.manager.openWindow(for: Data.conversationID), "같은 대화는 그 창을 앞으로 가져온다")
        #expect(r.manager.controllers.count == 1 && second == r.manager.registry.frontmost)
        #expect(first.questions === r.questions)
        r.questions.choose(row: 0, session: session)
        r.questions.choose(row: 0, session: session)
        await r.fire()
        #expect(await eventually { r.questions.entry(session: session)?.phase == .sent })
        #expect(r.gateway.calls(prefix: "answer:").count == 1)
    }

    // MARK: Esc의 차례

    @Test func escapeInTheWindowClosesTheOtherFieldFirstThenUndoesWhileFocusedThenHidesTheWindow() async throws {
        let r = try await Self.rig(Q.world(Q.other))
        defer { r.stop() }
        _ = try await open(r)
        let id = try #require(r.manager.controllers.keys.first)
        r.questions.choose(row: 3, session: session)
        #expect(r.questions.entry(session: session)?.otherOpen == true)
        #expect(r.manager.perform(.escape, in: id) && r.questions.entry(session: session)?.otherOpen == false && r.manager.registry.frontmost == id, "① Other 입력 칸 → 줄로 (창은 숨지 않는다)")
        r.questions.choose(row: 0, session: session)
        r.questions.setCardFocus(true, session: session)
        #expect(r.manager.perform(.escape, in: id) && r.questions.entry(session: session)?.phase == .open && r.manager.registry.frontmost == id, "② 보류 중이고 카드에 포커스면 Undo")
        #expect(r.manager.perform(.escape, in: id) && r.manager.registry.frontmost == nil, "③ 그다음 지금 순서: 창이 숨는다")
    }

    @Test func escapeDoesNotUndoAHeldAnswerWhenTheCardHasNoFocus() async throws {
        let r = try await Self.rig(Q.world(Q.single))
        defer { r.stop() }
        _ = try await open(r)
        let id = try #require(r.manager.controllers.keys.first)
        r.questions.choose(row: 0, session: session)
        #expect(r.manager.perform(.escape, in: id) && r.manager.registry.frontmost == nil, "카드에 포커스가 없으면 Undo가 아니라 창이 숨는다")
        #expect(r.questions.entry(session: session)?.phase == .holding, "숨어도 보류는 그대로다 (사용자는 이미 답했다)")
        await r.fire()
        #expect(await eventually { r.gateway.calls(prefix: "answer:").count == 1 }, "창이 숨어도 2초 뒤 그대로 보낸다")
    }

    @Test func escapeInTheSessionPanelClosesTheOtherFieldThenUndoesThenFallsBackToThePanelOrder() async throws {
        let r = try await Self.rig(Q.world(Q.other))
        defer { r.stop() }
        r.shell.openAllWork()
        r.shell.openIssue(Fx.issue(139))
        r.shell.openSession(session)
        await r.runtime.issues?.sessions.refresh()
        await r.questions.settle()
        #expect(r.shell.sessionPanelID == session && r.questions.entry(session: session) != nil)
        r.questions.choose(row: 3, session: session)
        #expect(r.controller.handleKey(try key(kVK_Escape, "\u{1b}")) && r.questions.entry(session: session)?.otherOpen == false && r.shell.sessionPanelID == session, "먼저 Other 칸만")
        r.questions.choose(row: 1, session: session)
        r.questions.setCardFocus(true, session: session)
        #expect(r.controller.handleKey(try key(kVK_Escape, "\u{1b}")) && r.questions.entry(session: session)?.phase == .open && r.shell.sessionPanelID == session, "그다음 Undo")
        #expect(r.controller.handleKey(try key(kVK_Escape, "\u{1b}")) && r.shell.sessionPanelID == nil, "그다음 지금 순서: 세션 패널이 닫힌다")
        #expect(r.gateway.calls(prefix: "answer:").isEmpty)
    }

    /// 세션 패널이 열린 채 보류 중인 답과 카드 포커스가 있는 상태
    private func heldInThePanel(_ r: Rig) async throws {
        r.shell.openAllWork()
        r.shell.openIssue(Fx.issue(139))
        r.shell.openSession(session)
        await r.runtime.issues?.sessions.refresh()
        await r.questions.settle()
        #expect(r.shell.sessionPanelID == session && r.questions.entry(session: session) != nil)
        r.questions.choose(row: 1, session: session)
        r.questions.setCardFocus(true, session: session)
        #expect(r.questions.entry(session: session)?.phase == .holding)
    }

    @Test func escapeBelongsToAnOpenMenuBeforeTheQuestion() async throws {
        let r = try await Self.rig(Q.world(Q.single))
        defer { r.stop() }
        try await heldInThePanel(r)
        r.shell.setMenuOpen(true)
        #expect(!r.controller.handleQuestionKey(try key(kVK_Escape, "\u{1b}")), "열린 메뉴가 Esc를 먼저 받는다: 질문은 지나간다")
        #expect(r.questions.entry(session: session)?.phase == .holding, "보류 중인 답을 되돌리지 않는다")
        r.shell.setMenuOpen(false)
        #expect(r.controller.handleQuestionKey(try key(kVK_Escape, "\u{1b}")) && r.questions.entry(session: session)?.phase == .open, "메뉴가 닫히면 Esc는 Undo")
    }

    /// 한글 · 일본어 조합 중인 입력칸(필드 에디터): 조합 글이 있다
    final class ComposingTextView: NSTextView {
        var composing = true
        override func hasMarkedText() -> Bool { composing }
    }

    @Test func escapeWhileComposingKoreanTextCancelsTheCompositionNotTheAnswer() async throws {
        let r = try await Self.rig(Q.world(Q.single))
        defer { r.stop() }
        try await heldInThePanel(r)
        let panel = try #require(r.controller.sessionPanel?.panel)
        let field = ComposingTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        panel.contentView?.addSubview(field)
        #expect(panel.makeFirstResponder(field))
        #expect(!r.controller.handleQuestionKey(try key(kVK_Escape, "\u{1b}")), "조합 중인 Esc는 조합을 취소하는 것이라 질문은 지나간다")
        #expect(r.questions.entry(session: session)?.phase == .holding, "조합을 끝내려는 Esc가 답을 되돌리지 않는다")
        field.composing = false
        #expect(r.controller.handleQuestionKey(try key(kVK_Escape, "\u{1b}")) && r.questions.entry(session: session)?.phase == .open, "조합이 없으면 Esc는 Undo")
        field.removeFromSuperview()
    }

    // MARK: 게이트

    @Test func withTheGateOffThereIsNoQuestionEntranceAtAll() async throws {
        let r = try await Self.rig(Q.world(Q.single), agentQuestions: false)
        defer { r.stop() }
        #expect(r.runtime.questions == nil && r.runtime.notifications == nil)
        let id = try #require(r.manager.openWindow(for: Data.conversationID))
        let model = try #require(r.manager.controllers[id]?.model)
        await r.chat.settle()
        await model.agent?.sessions.refresh()
        #expect(model.questions == nil && !model.isBlocked && r.shell.questions == nil)
        #expect(r.gateway.calls(prefix: "openQuestions").isEmpty, "질문을 읽지 않는다")
        #expect(!r.controller.handleKey(try key(kVK_Escape, "\u{1b}")) || r.shell.panelOpen == false)
    }

    @Test func aGatewayWithoutQuestionRoutesHasNoCardsEvenWhenTheGateIsOn() async throws {
        let account = try AppChatAccount.make()
        let runtime = ChatRuntime(gateway: SampleChatGateway(), scope: account.scope, agentQuestions: true, notificationCenter: FakeNotificationCenter())
        #expect(runtime.questions == nil, "견본 · 시험용 가짜 연결은 질문 route를 모른다")
    }

    @Test func theSurfaceValueIsTheShellAndChatsAndNeverForRelease() throws {
        #expect(!EdgeSurfaces.release.agentQuestions, "Release는 늘 꺼짐: 질문 읽기 · 카드 · 알림 · 키 입구가 없다")
        func surfaces(shell: Bool, chats: Bool) -> EdgeSurfaces {
            EdgeSurfaces(shell: shell, review: false, summary: false, chats: chats, projects: false, settingsWindow: false)
        }
        #expect(surfaces(shell: true, chats: true).agentQuestions)
        #expect(!surfaces(shell: true, chats: false).agentQuestions && !surfaces(shell: false, chats: true).agentQuestions)
        let store = try TestDefaults()
        defer { store.cleanup() }
        #expect(!EdgeSurfaces.debug(store.defaults).agentQuestions)
        store.defaults.set(true, forKey: EdgeShellFlag.key)
        #expect(EdgeSurfaces.debug(store.defaults).agentQuestions)
        store.defaults.set(true, forKey: EdgeSurfaces.releaseKey)
        #expect(!EdgeSurfaces.debug(store.defaults).agentQuestions, "Release 표면을 격리로 봐도 질문 카드는 없다")
        #expect(!EdgeSurfaces.current.agentQuestions, "호스트(Debug)에는 -TF_EDGE_SHELL이 없다")
    }

    // MARK: 링 · 알림으로 그 세션의 카드로

    @Test func clickingANeedsYouRingOpensThatIssuesDetailAndThatSessionsPanelAndFocusesTheCard() async throws {
        let r = try await Self.rig(Q.world(Q.single))
        defer { r.stop() }
        await r.questions.settle()
        let entry = try #require(r.shell.slots.first { $0.kind == .needsYou && $0.id == Fx.issue(139) })
        var focused: [UUID] = []
        r.shell.onFocusQuestion = { focused.append($0) }
        r.shell.openRailEntry(entry)
        #expect(r.shell.panelOpen && r.shell.view == .allWork && r.shell.nav.detailID == Fx.issue(139))
        #expect(r.shell.sessionPanelID == session && focused == [session], "그 세션 패널이 열리고 카드로 포커스를 옮기라고 알린다")
        #expect(r.questions.focusRequest(session: session) == 1)
        r.shell.openRailEntry(entry)
        #expect(r.shell.sessionPanelID == session, "다시 눌러도 닫지 않는다 (카드를 가리지 않는다)")
        #expect(r.shell.view == .allWork, "질문은 Review에 없다: Review를 열지 않는다")
    }

    @Test func aNotificationTapGoesToTheSessionPanelWhenIssueScreensAreOnElseToTheWindow() async throws {
        let r = try await Self.rig(Q.world(Q.single))
        defer { r.stop() }
        await r.questions.settle()
        r.controller.openQuestion(sessionID: session)
        #expect(r.shell.sessionPanelID == session && r.questions.focusRequest(session: session) == 1)
        let windows = try await Self.rig(Q.world(Q.single), issueScreens: false)
        defer { windows.stop() }
        // 새 Issues 화면이 꺼진 구성: 그 대화의 Assistant 창으로
        windows.questions.sessionsRead([QFxItem.make()])
        await windows.questions.settle()
        windows.controller.openQuestion(sessionID: session)
        #expect(windows.manager.controllers.count == 1 && windows.questions.focusRequest(session: session) == 1)
    }
}

/// 이 Mac의 세션 항목 하나 (질문 저장소에 직접 알릴 때)
enum QFxItem {
    static func make() -> AgentSessionItem {
        AgentSessionItem(
            id: AgentChatSampleData.sessionID, name: "Pricing copy draft", agent: .claudeCode, agentName: "Claude Code", connectionID: IssueSnapshotData.claude, status: .bound, ring: .needsYou, line: "",
            createdAt: Date(), updatedAt: Date(), issueIDs: [IssueSnapshotData.issue(139)], currentIssueID: IssueSnapshotData.issue(139), conversationID: AgentChatSampleData.conversationID,
            hasOpenTask: true, pill: nil, connectionBridgeID: AgentChatSampleData.thisMacBridge, lastTaskState: .awaitingAnswer, cancelRequested: false, turnSeq: 1
        )
    }
}
