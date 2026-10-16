import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import Taskforce
@testable import TaskforceKit
@testable import TaskforceUI

/// 세션 패널의 에이전트 동작 (OA D4a-1, 격리 호스트): 머리 알약의 "이 Mac" 규칙 · 알약 → 흐름 연결 · Resume here 확인 카드 · Esc의 차례 · Stop 상태 줄.
/// 서버는 가짜(`AgentChatSampleGateway`: 렌더 fixture)이고 창은 만들되 화면에 올리지 않는다. 실제 서버 · 계정 · 터미널 · `claude` 실행이 없다
@MainActor
struct EdgeSessionActionsTests {
    typealias Data = AgentChatSampleData
    typealias Fx = IssueSnapshotData

    @MainActor
    private struct Rig {
        let controller: EdgeShellController
        let runtime: ChatRuntime
        let gateway: AgentChatSampleGateway
        let defaults: TestDefaults
        /// 계정은 시험이 끝날 때까지 산다 (`AccountScope`는 세션 저장소를 붙들지 않는다)
        let account: AppChatAccount

        var shell: EdgeShellModel { controller.shell }
        var flow: AgentSessionPillFlow { runtime.pillFlow! }
        var sessions: AgentSessionStore { runtime.issues!.sessions }

        func session() throws -> AgentSessionItem { try #require(sessions.items.first { $0.id == Data.sessionID }) }
        func stop() { defaults.cleanup(); controller.assistant?.closeAll() }
    }

    private func rig(_ scene: AgentChatSampleGateway.State, thisMac: UUID? = Data.thisMacBridge) async throws -> Rig {
        let account = try AppChatAccount.make()
        let gateway = AgentChatSampleGateway()
        gateway.state = scene
        let runtime = ChatRuntime(gateway: gateway, contextGateway: IssueSampleContextGateway(), scope: account.scope, now: { Date() }, issueScreens: true)
        let defaults = try TestDefaults()
        let controller = EdgeShellController(
            launcher: LauncherModel(configurationError: "test"), chat: runtime, assistantWindows: true, positionStore: AssistantWindowPositionStore(defaults: defaults.defaults)
        )
        controller.assistant?.presents = false
        controller.ignoresExternalDismissal = false
        controller.shell.localBridgeIDProvider = { thisMac }
        controller.shell.update(Fx.snapshot(seeds: Fx.seeds))
        await runtime.issues?.numbers.ensure(Fx.seeds.map { Fx.issue($0.number) })
        await runtime.issues?.sessions.refresh()
        controller.shell.sessionsChanged()
        await controller.shell.refreshThisMac()
        return Rig(controller: controller, runtime: runtime, gateway: gateway, defaults: defaults, account: account)
    }

    private func key(_ code: Int, _ characters: String) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: UInt16(code)
        ))
    }

    /// 조건이 설 때까지 기다린다 (양보 횟수로 짐작하지 않는다). 안전망 3초
    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    /// 이슈 패널 위에 세션 패널을 연다 (탭이 붙은 화면)
    private func openPanel(_ r: Rig) async throws {
        r.shell.openAllWork()
        r.shell.openIssue(Fx.issue(139))
        r.shell.openSession(Data.sessionID)
        #expect(r.shell.sessionPanelID == Data.sessionID)
        _ = try r.session()
    }

    /// 세션 패널이 대화를 보이는 것처럼: 대화 목록 · 글 · 전달 줄을 읽는다
    private func openConversation(_ r: Rig) async {
        r.runtime.chat.panelConversations = { [Data.conversationID] }
        await r.runtime.chat.refresh()
        await r.runtime.chat.settle()
    }

    // MARK: 알약은 이 Mac의 세션에만 (D4a-03)

    @Test func thePillShowsOnlyForASessionOnThisMacAndOpenInTerminalOnlyWhenTheAppCanOpenOne() async throws {
        let external = try await rig(Data.events())
        defer { external.stop() }
        let resume = try external.session()
        #expect(resume.pill == .resumeHere && resume.connectionBridgeID == Data.thisMacBridge)
        #expect(SessionPanelView.pillSpec(for: resume, thisMacBridgeID: Data.thisMacBridge, offersOpenInTerminal: false) == .resumeHere, "Resume here는 launcher가 없어도 있다")
        #expect(SessionPanelView.pillSpec(for: resume, thisMacBridgeID: Data.otherMacBridge, offersOpenInTerminal: true) == nil, "다른 Mac의 세션에는 알약이 없다")
        #expect(SessionPanelView.pillSpec(for: resume, thisMacBridgeID: nil, offersOpenInTerminal: true) == nil, "이 Mac을 모르면 없다 (모르는 것을 같다고 하지 않는다)")

        let bound = try await rig(Data.inFlight())
        defer { bound.stop() }
        let open = try bound.session()
        #expect(SessionPanelView.pillSpec(for: open, thisMacBridgeID: Data.thisMacBridge, offersOpenInTerminal: true) == .openInTerminal(disabledReason: nil))
        #expect(SessionPanelView.pillSpec(for: open, thisMacBridgeID: Data.thisMacBridge, offersOpenInTerminal: false) == nil, "launcher가 없으면 동작이 없다: 그리지 않는다")

        let elsewhere = try await rig(Data.state(AgentChatSampleData.Thread(), bridge: Data.otherMacBridge))
        defer { elsewhere.stop() }
        let remote = try elsewhere.session()
        #expect(remote.connectionBridgeID == Data.otherMacBridge)
        #expect(SessionPanelView.pillSpec(for: remote, thisMacBridgeID: Data.thisMacBridge, offersOpenInTerminal: true) == nil)
    }

    @Test func thisMacIsTheLocalBridgeAndNothingWhenTheBridgeIsOff() async throws {
        let r = try await rig(Data.events())
        defer { r.stop() }
        #expect(r.shell.thisMacBridgeID == Data.thisMacBridge, "패널을 열 때 이 Mac의 bridge id를 읽는다")
        r.shell.localBridgeIDProvider = { nil }
        await r.shell.refreshThisMac()
        #expect(r.shell.thisMacBridgeID == nil, "bridge가 꺼졌으면 알약이 없다")
    }

    @Test func theLauncherIsNotThereYetSoOpenInTerminalIsNeverOffered() async throws {
        let r = try await rig(Data.inFlight())
        defer { r.stop() }
        #expect(!r.flow.offersOpenInTerminal, "D4a-1: 실제 launcher는 D4a-2")
    }

    // MARK: Resume here

    @Test func theSessionPanelWiresThePillToTheFlowAndAskingNeverTouchesTheServer() async throws {
        let r = try await rig(Data.events())
        defer { r.stop() }
        let action = try #require(r.shell.onSessionPill, "세션 route를 아는 연결이면 알약에 동작이 있다")
        action(.resumeHere, try r.session())
        #expect(await eventually { r.flow.resumeCard?.sessionID == Data.sessionID })
        #expect(r.gateway.calls(prefix: "resumeHere").isEmpty && r.gateway.calls(prefix: "openExternal").isEmpty, "확인 카드는 서버를 부르지 않는다")
    }

    @Test func confirmingTheCardSendsOneResumeAndTheSessionGoesBack() async throws {
        let r = try await rig(Data.events())
        defer { r.stop() }
        r.flow.askResume(try r.session())
        async let first: Void = r.flow.confirmResume()
        async let second: Void = r.flow.confirmResume()
        _ = await (first, second)
        #expect(r.gateway.calls(prefix: "resumeHere") == ["resumeHere:\(Data.sessionID.uuidString)"], "두 번 눌러도 요청은 하나")
        #expect(r.flow.resumeCard == nil)
        #expect(await eventually { r.sessions.items.first?.status == .bound }, "다시 읽어 서버 상태를 보인다 (서버가 사실이다)")
    }

    @Test func aStaleCardClosesWhenTheSessionIsNoLongerInTerminal() async throws {
        let r = try await rig(Data.events())
        defer { r.stop() }
        r.flow.askResume(try r.session())
        // 다른 곳에서 이미 돌아왔다: 새로 읽은 세션이 external이 아니면 카드를 닫는다
        r.gateway.update { state in
            guard let old = state.sessions.sessions.first else { return }
            state.sessions.sessions = [AgentSessionRecord(
                id: old.id, connectionID: old.connectionID, displayName: old.displayName, status: .bound, isPendingFirstTurn: old.isPendingFirstTurn,
                lastTurnSeq: old.lastTurnSeq, createdAt: old.createdAt, updatedAt: Date()
            )]
        }
        await r.sessions.refresh()
        r.shell.sessionsChanged()
        #expect(r.flow.resumeCard == nil, "낡은 카드를 적용하지 않는다")
    }

    // MARK: Esc의 차례

    @Test func escapeClosesTheConfirmCardBeforeTheSessionPanelAndTheKeyNeverConfirms() async throws {
        let r = try await rig(Data.events())
        defer { r.stop() }
        try await openPanel(r)
        r.flow.askResume(try r.session())
        #expect(r.flow.resumeCard != nil)
        // Return은 셸이 듣지 않는다: 카드의 키는 카드가 키를 가졌을 때만 간다 (서버 0)
        #expect(!r.controller.handleKey(try key(kVK_Return, "\r")))
        #expect(r.gateway.calls(prefix: "resumeHere").isEmpty && r.flow.resumeCard != nil)
        #expect(r.controller.handleKey(try key(kVK_Escape, "\u{1b}")))
        #expect(r.flow.resumeCard == nil && r.shell.sessionPanelID == Data.sessionID, "먼저 카드만 닫는다")
        #expect(r.controller.handleKey(try key(kVK_Escape, "\u{1b}")))
        #expect(r.shell.sessionPanelID == nil && r.shell.panelOpen, "다음 Esc가 세션 패널을 닫는다")
    }

    @Test func escapeClosesTheReferentMenuBeforeTheSessionPanel() async throws {
        let r = try await rig(Data.queued())
        AgentNewCopy.isPreviewing = true
        defer { AgentNewCopy.isPreviewing = false; r.stop() }
        try await openPanel(r)
        await r.runtime.chat.loadThread(Data.conversationID)
        await r.runtime.chat.settle()
        let ambiguous = try #require(r.runtime.chat.turns(for: Data.conversationID).first { $0.delivery?.state == .needsReferent })
        r.runtime.panelDesk.openReferentMenu(for: ambiguous.id)
        #expect(r.runtime.panelDesk.referentMenu?.messageID == ambiguous.id)
        #expect(r.controller.handleKey(try key(kVK_Escape, "\u{1b}")))
        #expect(r.runtime.panelDesk.referentMenu == nil && r.shell.sessionPanelID == Data.sessionID, "먼저 후보 메뉴만 닫는다")
        #expect(r.controller.handleKey(try key(kVK_Escape, "\u{1b}")))
        #expect(r.shell.sessionPanelID == nil)
    }

    // MARK: 새 턴이 시작되면 세션을 다시 읽는다

    /// 쉬는 세션(열린 task 없음)에는 5초 읽기가 돌지 않는다: 세션 패널의 입력칸으로 새 턴을 시작해도 다시 읽지 않으면 Stop 원이 서지 않는다
    @Test func aTurnStartedFromThePanelComposerRaisesStopWithoutWaitingForAPoll() async throws {
        let r = try await rig(Data.inFlight())
        defer { r.stop() }
        #expect(!r.runtime.stop.presentation(session: try r.session()).showsStop, "쉬는 세션: Stop이 없다")
        await openConversation(r)
        await r.runtime.chat.send("Also update the refund window wording", in: Data.conversationID)
        #expect(await eventually { r.sessions.items.first?.hasOpenTask == true }, "보낸 뒤 세션을 다시 읽어 열린 task를 안다")
        #expect(r.runtime.stop.presentation(session: try r.session()).showsStop, "Stop 원")
    }

    @Test func sendAgainAndAReferentPickFromThePanelAlsoReadTheSessionAgain() async throws {
        let r = try await rig(Data.waiting())
        defer { r.stop() }
        await openConversation(r)
        let failed = try #require(r.runtime.chat.turns(for: Data.conversationID).first { $0.delivery?.state == .notSent })
        r.gateway.deliverReply = AgentDelivery(state: .sent)
        #expect(!(try r.session()).hasOpenTask)
        await r.runtime.panelDesk.sendAgain(failed, in: Data.conversationID)
        #expect(await eventually { r.sessions.items.first?.hasOpenTask == true }, "Send again 뒤 세션을 다시 읽는다")
    }

    // MARK: 거절된 재전송: 세션 패널도 같은 동의 안내 · Connections

    private final class Counter {
        var value = 0
    }

    /// 동의 철회 뒤 세션 패널의 Send again이 409로 거절되면 Assistant 창과 같은 동의 안내(Allow AI processing to continue)가 뜨고, 단추가 Connections로 간다
    @Test func aConsentRefusalOnAPanelResendShowsTheSameConsentNoticeAndConnectionsOpens() async throws {
        let r = try await rig(Data.waiting())
        defer { r.stop() }
        await openConversation(r)
        let chat = r.runtime.chat
        let failed = try #require(chat.turns(for: Data.conversationID).first { $0.delivery?.state == .notSent })
        #expect(!SessionPanelView.showsConsentNotice(chat: chat, conversationID: Data.conversationID), "거절 전에는 안내가 없다")
        r.gateway.deliverFailure = APIError.server(status: 409, code: .conflict, message: APIError.consentRequiredMessage)
        await r.runtime.panelDesk.sendAgain(failed, in: Data.conversationID)
        let refused = try #require(chat.turns(for: Data.conversationID).first { $0.id == failed.id })
        #expect(refused.status == .needsConsent && refused.showsStatusLine)
        #expect(SessionPanelView.showsConsentNotice(chat: chat, conversationID: Data.conversationID), "Assistant 창과 같은 동의 안내가 패널에도 뜬다")
        let opened = Counter()
        r.shell.onConnect = { opened.value += 1 }
        SessionPanelView.openConnections(r.shell)
        #expect(opened.value == 1, "단추는 창과 같은 길(셸의 Connections)로 간다")
        // 동의한 뒤 Try again
        r.gateway.deliverFailure = nil
        await r.runtime.panelDesk.retry(refused, in: Data.conversationID)
        #expect(!SessionPanelView.showsConsentNotice(chat: chat, conversationID: Data.conversationID))
    }

    // MARK: 기능 꺼짐: 세션 패널의 안내 · 복구

    /// 재전송이 기능 꺼짐으로 실패하면 Assistant 창과 같은 안내("Chats aren't available yet." + Try again)가 패널에도 뜨고 입력이 막힌다.
    /// 서버가 돌아와 성공한 읽기가 accepted를 확인하면 입력이 돌아온다 (안내만 지우고 막힌 채로 두지 않는다)
    @Test func aFeatureOffResendShowsTheUnavailableNoticeInThePanelAndARecoveringReadReEnablesTheComposer() async throws {
        let r = try await rig(Data.waiting())
        defer { r.stop() }
        await openConversation(r)
        let chat = r.runtime.chat
        let failed = try #require(chat.turns(for: Data.conversationID).first { $0.delivery?.state == .notSent })
        #expect(!SessionPanelView.showsUnavailableNotice(chat: chat) && !SessionPanelView.isComposerDisabled(chat: chat))
        let off = APIError.server(status: 404, code: .notFound, message: APIError.featureOffMessage)
        r.gateway.deliverFailure = off
        r.gateway.deliveriesFailure = off
        await r.runtime.panelDesk.sendAgain(failed, in: Data.conversationID)
        await chat.settle()
        #expect(SessionPanelView.showsUnavailableNotice(chat: chat) && SessionPanelView.isComposerDisabled(chat: chat), "패널에도 기능 꺼짐 안내가 뜨고 입력이 막힌다")
        // 서버가 돌아왔고 다른 기기가 이미 보냈다
        r.gateway.deliverFailure = nil
        r.gateway.deliveriesFailure = nil
        r.gateway.update { $0.deliveries[failed.id] = AgentDelivery(state: .accepted) }
        await chat.refreshDeliveries(Data.conversationID)
        #expect(!SessionPanelView.showsUnavailableNotice(chat: chat) && !SessionPanelView.isComposerDisabled(chat: chat), "성공한 읽기가 복구를 확인했다")
        let after = try #require(chat.turns(for: Data.conversationID).first { $0.id == failed.id })
        #expect(after.status == .sent && after.delivery?.state == .accepted)
    }

    /// 읽기가 아직 돌아오지 않았어도 안내의 Try again이 막힘을 풀고 다시 읽는다 (Assistant 창의 `retryUnavailable()`과 같은 길)
    @Test func theUnavailableNoticeInThePanelHasTheSameTryAgain() async throws {
        let r = try await rig(Data.waiting())
        defer { r.stop() }
        await openConversation(r)
        let chat = r.runtime.chat
        let failed = try #require(chat.turns(for: Data.conversationID).first { $0.delivery?.state == .notSent })
        let off = APIError.server(status: 404, code: .notFound, message: APIError.featureOffMessage)
        r.gateway.deliverFailure = off
        r.gateway.deliveriesFailure = off
        await r.runtime.panelDesk.sendAgain(failed, in: Data.conversationID)
        #expect(SessionPanelView.showsUnavailableNotice(chat: chat))
        SessionPanelView.retryUnavailable(chat)
        #expect(!SessionPanelView.showsUnavailableNotice(chat: chat), "Try again이 막힘을 바로 푼다")
        await chat.settle()
    }

    // MARK: Stop

    @Test func theSessionPanelStopsThroughTheSessionRouteOnceAndTheStatusLineSaysRequested() async throws {
        let r = try await rig(Data.running())
        defer { r.stop() }
        let session = try r.session()
        #expect(r.runtime.stop.presentation(session: session).showsStop, "열린 task: Composer 원이 Stop")
        #expect(SessionPanelView.statusLine(for: session, stop: r.runtime.stop.presentation(session: session)) == SessionPanelView.statusLine(for: session))
        await r.runtime.stop.stopSession(session)
        await r.runtime.stop.stopSession(session)
        #expect(r.gateway.calls(prefix: "stopSession") == ["stopSession:\(Data.sessionID.uuidString)"], "세션 패널은 세션 route, 이미 요청했으면 다시 보내지 않는다")
        #expect(r.gateway.calls(prefix: "stopConversation").isEmpty)
        let shown = r.runtime.stop.presentation(session: session)
        #expect(shown == AgentStopRules.Presentation(showsStop: true, line: .requested))
        #expect(SessionPanelView.statusLine(for: session, stop: shown) == "Stop requested · not confirmed", "U2 2.5 표 그대로")
    }

    @Test func mayContinueIsTheUnapprovedWordAndItNeverShowsOutsideThePreview() async throws {
        let r = try await rig(Data.running())
        defer { AgentNewCopy.isPreviewing = false; r.stop() }
        r.gateway.stopConfirms = true
        r.gateway.stopMayContinue = true
        let session = try r.session()
        await r.runtime.stop.stopSession(session)
        #expect(await eventually { r.sessions.items.first?.lastTaskState == .cancelled }, "Stop이 끝나면 저장소가 스스로 다시 읽는다")
        let after = try r.session()
        let shown = r.runtime.stop.presentation(session: after)
        #expect(shown == AgentStopRules.Presentation(showsStop: false, line: .mayContinue))
        #expect(SessionPanelView.statusLine(for: after, stop: shown) == SessionPanelView.statusLine(for: after), "승인 전: 그 말은 앱에서 보이지 않는다")
        AgentNewCopy.isPreviewing = true
        #expect(SessionPanelView.statusLine(for: after, stop: shown) == "Stopped · commands may still be running", "견본 · 시험에서만")
    }
}
