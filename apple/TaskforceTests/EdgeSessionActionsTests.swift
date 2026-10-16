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
