import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import Taskforce
@testable import TaskforceKit
@testable import TaskforceUI

/// 새 Issues 화면(OA U2)이 Assistant 창과 만나는 곳: Ask 알약 → 앞 창의 칩 · New session `+` → 새 창 + 범위 칩 + 대상 메뉴 · 열린 패널 둘(이슈 패널 + 탭 + 세션 패널)의 합 옆에 뜨는 첫 창 ·
/// 키 창이 세션 패널 · 메뉴로 옮겨 가도 패널이 접히지 않는 것 · Esc의 차례. 창은 만들되 화면에 올리지 않는다 (`presents = false`). 서버 응답은 가짜(견본 하네스의 렌더 fixture)다
@MainActor
struct AssistantIssueTests {
    typealias Fx = IssueSnapshotData

    @MainActor
    private struct Rig {
        let controller: EdgeShellController
        let runtime: ChatRuntime
        let defaults: TestDefaults

        var shell: EdgeShellModel { controller.shell }
        var manager: AssistantWindowManager { controller.assistant! }
    }

    private func rig(gated: Bool = true) async throws -> Rig {
        let account = try AppChatAccount.make()
        let gateway = IssueSampleGateway()
        let contextGateway = IssueSampleContextGateway()
        let runtime = ChatRuntime(gateway: gateway, contextGateway: contextGateway, scope: account.scope, now: { Date() }, issueScreens: gated)
        let defaults = try TestDefaults()
        let controller = EdgeShellController(
            launcher: LauncherModel(configurationError: "test"), chat: runtime, assistantWindows: true,
            positionStore: AssistantWindowPositionStore(defaults: defaults.defaults)
        )
        controller.assistant?.presents = false
        controller.ignoresExternalDismissal = false
        controller.shell.update(Fx.snapshot(seeds: Fx.seeds))
        if let issues = runtime.issues {
            await runtime.contexts?.refresh()
            await issues.numbers.ensure(Fx.seeds.map { Fx.issue($0.number) })
            await issues.sessions.refresh()
            controller.shell.sessionsChanged()
        }
        return Rig(controller: controller, runtime: runtime, defaults: defaults)
    }

    private let issue139 = AssistantOpenItem(kind: .action, id: Fx.issue(139), title: "Rewrite pricing page copy for the 3-day trial and Lifetime plan", number: 139)

    private func key(_ code: Int, _ characters: String, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: UInt16(code)
        ))
    }

    // MARK: 연결

    @Test func theControllerWiresAskAndNewSessionOnlyWhenGated() async throws {
        let on = try await rig()
        defer { on.defaults.cleanup(); on.manager.closeAll() }
        #expect(on.shell.issueScreensEnabled && on.controller.sessionPanel != nil)
        let off = try await rig(gated: false)
        defer { off.defaults.cleanup(); off.manager.closeAll() }
        #expect(!off.shell.issueScreensEnabled && off.controller.sessionPanel == nil, "게이트가 꺼지면 세션 패널 창도 없다")
        off.shell.onAsk(issue139)
        off.shell.onNewSession(issue139)
        #expect(off.manager.controllers.isEmpty, "꺼진 셸은 Ask · New session을 연결하지 않는다")
    }

    // MARK: Ask · New session

    @Test func askAddsTheItemToTheFrontWindowAsAnAddedChip() async throws {
        let r = try await rig()
        defer { r.defaults.cleanup(); r.manager.closeAll() }
        let front = try #require(r.manager.openNewWindow())
        r.shell.onAsk(issue139)
        let chips = try #require(r.manager.controllers[front]?.model.chips.chips)
        #expect(chips.map(\.itemID) == [issue139.id] && chips.first?.origin == .added && chips.first?.number == 139 && chips.first?.kind == .action)
        r.shell.onAsk(AssistantOpenItem(kind: .agentSession, id: Fx.session(1), title: "Pricing copy draft"))
        r.shell.onAsk(AssistantOpenItem(kind: .context, id: Fx.taskforce, title: "Taskforce 0.2.0"))
        let kinds = try #require(r.manager.controllers[front]?.model.chips.chips.map(\.kind))
        #expect(kinds == [.action, .agentSession, .context], "세 종류 모두 칩이 된다")
        #expect(r.manager.controllers.count == 1, "앞 창이 있으면 새 창을 열지 않는다")
    }

    @Test func askOpensAWindowWhenThereIsNone() async throws {
        let r = try await rig()
        defer { r.defaults.cleanup(); r.manager.closeAll() }
        #expect(r.manager.controllers.isEmpty)
        r.shell.onAsk(issue139)
        #expect(r.manager.controllers.count == 1)
        let model = try #require(r.manager.controllers.values.first?.model)
        #expect(model.chips.chips.map(\.itemID) == [issue139.id])
    }

    @Test func aNewSessionOpensAFreshWindowWithTheScopeChipAndTheTargetMenuOpen() async throws {
        let r = try await rig()
        defer { r.defaults.cleanup(); r.manager.closeAll() }
        let existing = try #require(r.manager.openNewWindow())
        r.shell.onNewSession(issue139)
        #expect(r.manager.controllers.count == 2, "새 창이다 (앞 창을 쓰지 않는다)")
        let fresh = try #require(r.manager.controllers.first { $0.key != existing }?.value)
        #expect(fresh.model.chips.chips.map(\.itemID) == [issue139.id] && fresh.model.chips.chips.first?.origin == .added)
        #expect(fresh.targetMenu.isOpen && fresh.presentation.targetMenuOpen, "대상 메뉴가 열려 있다")
        #expect(r.manager.controllers[existing]?.model.chips.chips.isEmpty == true, "앞 창의 칩은 그대로")
    }

    @Test func aNewSessionWithoutAScopeOpensAWindowWithNoChip() async throws {
        let r = try await rig()
        defer { r.defaults.cleanup(); r.manager.closeAll() }
        r.shell.onNewSession(nil)
        let model = try #require(r.manager.controllers.values.first?.model)
        #expect(r.manager.controllers.count == 1 && model.chips.chips.isEmpty)
    }

    @Test func aWindowOpenedWhileAnIssueIsOpenFollowsItAsTheAutoChipWithItsNumber() async throws {
        let r = try await rig()
        defer { r.defaults.cleanup(); r.manager.closeAll() }
        r.shell.openAllWork()
        r.shell.openIssue(Fx.issue(139))
        let id = try #require(r.manager.openNewWindow())
        let chip = try #require(r.manager.controllers[id]?.model.chips.chips.first)
        #expect(chip.itemID == Fx.issue(139) && chip.origin == .auto && chip.kind == .action && chip.number == 139, "열 때 패널의 항목이 auto 칩 (이슈는 번호 앞)")
        r.shell.openSession(Fx.session(1))
        #expect(AssistantWindowManager.chip(for: try #require(r.shell.openItem)).kind == .agentSession)
    }

    // MARK: 첫 창의 자리

    @Test func theFirstWindowOpensTwelveLeftOfTheUnionOfTheIssuePanelWithItsTabAndTheSessionPanel() throws {
        let account = try AppChatAccount.make()
        let defaults = try TestDefaults()
        defer { defaults.cleanup() }
        let issue = EdgePanelMetrics.frame(height: 440, railTop: 800, screenMaxX: 1440, tab: SessionTabGeometry.expanded.width)
        let session = EdgeSessionPanelController.frame(issuePanel: issue, height: 380)
        let union = try #require(AssistantWindowGeometry.panelsFrame([issue, session]))
        #expect(union.minX == session.minX && union.maxX == issue.maxX && union.maxY == issue.maxY)
        let runtime = ChatRuntime(gateway: IssueSampleGateway(), scope: account.scope, now: { Date() }, issueScreens: false)
        let shell = EdgeShellModel(schedule: { _, _ in EdgeTimer() }, chatsEnabled: true, windowsEnabled: true)
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let rail = CGRect(x: 1396, y: 400, width: 44, height: 353)
        let manager = AssistantWindowManager(
            runtime: runtime, shell: shell, store: AssistantWindowPositionStore(defaults: defaults.defaults),
            environment: .init(visibleFrame: { visible }, railFrame: { rail }, panelFrame: { union }, display: { "1" }, extraScreens: { [] })
        )
        manager.presents = false
        let id = try #require(manager.openNewWindow())
        let point = try #require(manager.controllers[id]?.topLeft)
        #expect(point.x == union.minX - 12 - AssistantWindowGeometry.width, "탭 · 세션 패널까지 합친 바깥 가장자리에서 12")
        #expect(point.y == union.maxY, "위는 패널과 같다")
        manager.closeAll()
    }

    // MARK: 키 · 포커스

    @Test func escapeClosesTheSessionPanelFirstAndThenGoesBack() async throws {
        let r = try await rig()
        defer { r.defaults.cleanup(); r.manager.closeAll() }
        r.shell.openAllWork()
        r.shell.openIssue(Fx.issue(139))
        r.shell.openSession(Fx.session(1))
        #expect(r.controller.handleKey(try key(kVK_Escape, "\u{1b}")))
        #expect(r.shell.sessionPanelID == nil && r.shell.nav.detailID == Fx.issue(139) && r.shell.panelOpen)
        #expect(r.controller.handleKey(try key(kVK_Escape, "\u{1b}")))
        #expect(r.shell.nav.current == .projects && r.shell.panelOpen, "그다음 상세에서 뒤로")
        #expect(r.controller.handleKey(try key(kVK_Escape, "\u{1b}")))
        #expect(!r.shell.panelOpen, "맨 앞 화면에서는 패널을 접는다")
    }

    @Test func commandTwoGoesToProjectsFromTheIssueDetail() async throws {
        let r = try await rig()
        defer { r.defaults.cleanup(); r.manager.closeAll() }
        r.shell.openAllWork()
        r.shell.openIssue(Fx.issue(139))
        r.shell.openSession(Fx.session(1))
        #expect(r.controller.handleKey(try key(kVK_ANSI_2, "2", flags: .command)))
        #expect(r.shell.nav.current == .projects && r.shell.sessionPanelID == nil && r.shell.panelOpen)
    }

    @Test func theKeyMovingToTheSessionPanelOrItsMenuKeepsThePanelAndAnythingElseFoldsIt() async throws {
        let r = try await rig()
        defer { r.defaults.cleanup(); r.manager.closeAll() }
        let session = try #require(r.controller.sessionPanel?.panel)
        let resigned = Notification(name: NSWindow.didResignKeyNotification)
        r.shell.openAllWork()
        r.shell.openIssue(Fx.issue(139))
        r.controller.keyWindow = { session }
        r.controller.windowDidResignKey(resigned)
        for _ in 0..<10 { await Task.yield() }
        #expect(r.shell.panelOpen, "키가 세션 패널로 옮겨 간 것은 패널을 잃은 것이 아니다")
        r.controller.keyWindow = { r.controller.panel.panel }
        r.controller.windowDidResignKey(resigned)
        for _ in 0..<10 { await Task.yield() }
        #expect(r.shell.panelOpen, "이슈 패널로 돌아온 것도 마찬가지")
        r.controller.keyWindow = { nil }
        r.controller.windowDidResignKey(resigned)
        for _ in 0..<10 { await Task.yield() }
        #expect(!r.shell.panelOpen, "다른 곳으로 가면 접는다")
    }

    @Test func openingAMoreMenuHoldsThePanelOpenWhileItIsUp() async throws {
        let r = try await rig()
        defer { r.defaults.cleanup(); r.manager.closeAll() }
        r.shell.openAllWork()
        r.shell.setMenuOpen(true)
        r.controller.keyWindow = { nil }
        r.controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
        for _ in 0..<10 { await Task.yield() }
        #expect(r.shell.panelOpen, "More 메뉴를 연 동안은 키를 잃어도 접지 않는다")
    }
}
