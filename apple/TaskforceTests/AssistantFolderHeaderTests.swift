import AppKit
import Foundation
import Testing
import TaskforceKit
@testable import Taskforce
@testable import TaskforceUI

/// Assistant 창 머리의 작업 폴더 (사용자 결정 2026-10-21, 격리 호스트): 에이전트 대화에 폴더가 적혀 있으면 머리에 폴더 이름(툴팁에 경로)이 보이고,
/// 거기서 **다른 폴더의 새 대화**를 연다 (세션의 폴더는 세션을 연 뒤 바뀌지 않는다). 폴더 창은 가짜 패널이고 서버는 가짜 게이트웨이다 — 실제 `NSOpenPanel` · 서버 · `claude` 0.
/// 창은 만들되 화면에 올리지 않는다 (`presents = false`; 끌기 시험은 화면 밖 `orderFront`)
@MainActor
struct AssistantFolderHeaderTests {
    typealias Data = AgentChatSampleData

    // MARK: 시험 도구

    /// 임시 홈 + 폴더 등록부 + 가짜 폴더 창
    @MainActor
    private struct Folders {
        let temp: URL
        let home: String
        let registry: WorkspaceRegistry
        let panel: WorkspacePickerTests.FakePanel

        init() throws {
            temp = FileManager.default.temporaryDirectory.appending(path: "folder-header-\(UUID().uuidString)", directoryHint: .isDirectory)
            home = temp.appending(path: "home").path
            for name in ["client-a", "client-b", "client-c/sub"] { try FileManager.default.createDirectory(atPath: home + "/Documents/" + name, withIntermediateDirectories: true) }
            try FileManager.default.createDirectory(at: temp.appending(path: "p"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            registry = WorkspaceRegistry(file: temp.appending(path: "p/workspaces.json"), rules: WorkspaceFolderRules(home: home, systemRoots: []))
            panel = WorkspacePickerTests.FakePanel(choice: nil)
        }

        func path(_ name: String) -> String { home + "/Documents/" + name }
        func real(_ name: String) -> String { GateFileSystem.realpath(path(name)) ?? path(name) }
        func cleanup() { try? FileManager.default.removeItem(at: temp) }

        func install(in runtime: ChatRuntime) {
            runtime.workspacePicker = panel
            let registry = registry
            runtime.workspaceAsking = { AgentWorkspaceAsking(folders: registry, isThisMac: { _ in true }) }
            let homes = [home, GateFileSystem.realpath(home) ?? home]
            runtime.workspaceHomes = { homes }
        }
    }

    // MARK: 모델만 (런타임)

    @MainActor
    private struct ModelRig {
        let runtime: ChatRuntime
        let model: AssistantWindowModel
        let folders: Folders
        let conversation: UUID
        let account: AppChatAccount
        var chat: ChatStore { runtime.chat }
    }

    /// 이 Mac의 에이전트 대화 하나 (아직 아무것도 보내지 않았다), 초안 "ship it"
    private func modelRig() throws -> ModelRig {
        let folders = try Folders()
        let account = try AppChatAccount.make()
        let runtime = ChatRuntime(gateway: AgentChatSampleGateway(), contextGateway: IssueSampleContextGateway(), scope: account.scope, now: { Date() }, issueScreens: true)
        folders.install(in: runtime)
        let conversation = runtime.chat.reserveNewChat(target: .agent(adapter: "agent:claude-code", connectionID: UUID()), excluding: [])
        let model = AssistantWindowModel(conversationID: conversation, chat: runtime.chat, targets: runtime.targets)
        model.setDraft("ship it")
        return ModelRig(runtime: runtime, model: model, folders: folders, conversation: conversation, account: account)
    }

    // MARK: 머리에 보이는 것 (런타임이 정한다)

    @Test func nothingIsShownBeforeAFolderIsChosenAndNothingForATaskforceConversation() throws {
        let r = try modelRig()
        defer { r.folders.cleanup() }
        #expect(r.runtime.folderLine(for: r.model) == nil, "폴더를 고르기 전에는 머리에 아무것도 더하지 않는다")
        let taskforce = r.chat.reserveNewChat(target: .taskforce, excluding: [r.conversation])
        try r.folders.registry.setPending(r.folders.path("client-a"), conversation: taskforce)
        let plain = AssistantWindowModel(conversationID: taskforce, chat: r.chat, targets: r.runtime.targets)
        #expect(r.runtime.folderLine(for: plain) == nil, "Taskforce 대화에는 작업 폴더가 없다")
    }

    @Test func theFolderTheConversationChoseIsShownWithItsNameAndTheHomeAbbreviatedPath() throws {
        let r = try modelRig()
        defer { r.folders.cleanup() }
        try r.folders.registry.setPending(r.folders.path("client-a"), conversation: r.conversation)
        let line = try #require(r.runtime.folderLine(for: r.model))
        #expect(line.name == "client-a" && line.tooltip == "~/Documents/client-a")
    }

    @Test func withoutAnActiveRegistryOrOnAnotherMacNothingIsShown() throws {
        let r = try modelRig()
        defer { r.folders.cleanup() }
        try r.folders.registry.setPending(r.folders.path("client-a"), conversation: r.conversation)
        r.runtime.workspaceAsking = { nil }
        #expect(r.runtime.folderLine(for: r.model) == nil, "등록부가 없으면 (bridge 꺼짐 · 계정 없음) 아무것도 보이지 않는다")
        // 다른 Mac의 세션: 이 Mac의 등록부에 그 세션의 핀도 이 대화의 폴더도 없다
        r.folders.install(in: r.runtime)
        let other = AssistantWindowModel(conversationID: r.chat.reserveNewChat(target: .agent(adapter: "agent:claude-code", connectionID: UUID()), excluding: [r.conversation]), chat: r.chat, targets: r.runtime.targets)
        #expect(r.runtime.folderLine(for: other) == nil)
    }

    // MARK: 메뉴 동작 = 폴더를 고르고 새 대화

    @Test func theMenuActionAsksForAFolderThenOpensAFreshConversationOfTheSameAgentBoundToIt() async throws {
        let r = try modelRig()
        defer { r.folders.cleanup() }
        r.folders.panel.choice = r.folders.path("client-a")
        await r.runtime.sendFromWindow(r.model)   // 첫 보내기: 폴더를 묻고 보낸다
        let original = r.conversation
        let target = r.model.pick
        #expect(r.chat.turns(for: original).count == 1 && r.folders.registry.pending(conversation: original) == r.folders.real("client-a"))

        r.model.setDraft("typed but not sent")
        r.folders.panel.choice = r.folders.path("client-b")
        await r.runtime.startChatInAnotherFolder(r.model)

        let fresh = r.model.conversationID
        #expect(fresh != original, "이 창이 새 대화로 간다")
        #expect(r.model.pick.isSame(as: target) && r.model.toAgent, "같은 에이전트 · 같은 연결")
        #expect(r.folders.registry.pending(conversation: fresh) == r.folders.real("client-b"), "새 대화에 고른 폴더가 적혔다")
        #expect(r.folders.registry.pending(conversation: original) == r.folders.real("client-a"), "옛 대화의 폴더는 그대로다")
        #expect(r.chat.turns(for: original).count == 1 && r.chat.draft(for: original) == "typed but not sent", "옛 대화의 글 · 초안도 그대로")
        #expect(r.chat.turns(for: fresh).isEmpty && r.model.draft.isEmpty && r.model.mode == .chat, "새 대화는 비어 있고 입력할 준비다")
        #expect(r.folders.panel.asked.map(\.message) == ["Choose a folder for this session", "Choose a folder for this session"], "승인된 폴더 창 문구 그대로")
        #expect(r.folders.panel.asked.map(\.prompt) == ["Choose", "Choose"])
        let shown = try #require(r.runtime.folderLine(for: r.model))
        #expect(shown.name == "client-b" && shown.tooltip == "~/Documents/client-b", "머리가 새 폴더를 보인다")
        // 옛 대화로 돌아가면 옛 폴더가 보인다
        r.model.openConversation(original)
        #expect(r.runtime.folderLine(for: r.model)?.name == "client-a")
    }

    @Test func theFirstSendInTheNewConversationDoesNotAskAgainAndSendsToTheChosenFolder() async throws {
        let r = try modelRig()
        defer { r.folders.cleanup() }
        r.folders.panel.choice = r.folders.path("client-b")
        await r.runtime.startChatInAnotherFolder(r.model)
        #expect(r.folders.panel.asked.count == 1)
        r.model.setDraft("hello in b")
        await r.runtime.sendFromWindow(r.model)
        #expect(r.folders.panel.asked.count == 1, "이 대화는 이미 폴더를 골랐다: 다시 묻지 않는다")
        #expect(r.chat.turns(for: r.model.conversationID).count == 1 && r.model.draft.isEmpty, "보냈다")
    }

    @Test func aProjectChipWithoutAFolderAddedLaterDoesNotAskForAnotherFolder() async throws {
        let r = try modelRig()
        defer { r.folders.cleanup() }
        r.folders.panel.choice = r.folders.path("client-b")
        await r.runtime.startChatInAnotherFolder(r.model)
        r.model.addChip(AssistantChip(kind: .context, itemID: UUID(), origin: .added, title: "Acme"))
        r.model.setDraft("with a project chip")
        await r.runtime.sendFromWindow(r.model)
        #expect(r.folders.panel.asked.count == 1, "대화가 고른 폴더가 먼저다: 프로젝트의 폴더를 또 묻지 않는다")
        #expect(r.chat.turns(for: r.model.conversationID).count == 1)
    }

    @Test func cancellingTheFolderPanelChangesNothingAtAll() async throws {
        let r = try modelRig()
        defer { r.folders.cleanup() }
        r.folders.panel.choice = r.folders.path("client-a")
        await r.runtime.sendFromWindow(r.model)
        let original = r.conversation
        r.model.setDraft("still here")
        r.model.addChip(AssistantChip(kind: .action, itemID: UUID(), origin: .added, title: "Pricing"))
        let fileBefore = try Foundation.Data(contentsOf: r.folders.registry.file)
        r.folders.panel.choice = nil
        await r.runtime.startChatInAnotherFolder(r.model)
        #expect(r.folders.panel.asked.count == 2, "폴더 창은 열었다")
        #expect(r.model.conversationID == original && r.model.draft == "still here" && r.model.chips.chips.count == 1, "취소 = 아무것도 바뀌지 않는다")
        #expect(try Foundation.Data(contentsOf: r.folders.registry.file) == fileBefore, "등록부 파일도 그대로")
    }

    @Test func aFolderThePanelRejectsChangesNothing() async throws {
        let r = try modelRig()
        defer { r.folders.cleanup() }
        let project = UUID()
        try r.folders.registry.setFolder(r.folders.path("client-c"), forProject: project)
        let fileBefore = try Foundation.Data(contentsOf: r.folders.registry.file)
        for rejected in [r.folders.home, r.folders.path("client-c/sub")] {   // 홈 자체 · 다른 프로젝트의 폴더 안
            r.folders.panel.choice = rejected
            await r.runtime.startChatInAnotherFolder(r.model)
        }
        #expect(r.folders.panel.rejections.count == 2 && r.model.conversationID == r.conversation)
        #expect(try Foundation.Data(contentsOf: r.folders.registry.file) == fileBefore)
    }

    @Test func nothingIsWrittenWhenTheAccountTheConversationOrTheTargetChangesWhileThePanelIsOpen() async throws {
        func openPanelThenChange(_ change: @MainActor (ModelRig) -> Void) async throws -> ModelRig {
            let r = try modelRig()
            r.folders.panel.choice = r.folders.path("client-b")
            r.folders.panel.holds = true
            let runtime = r.runtime
            let model = r.model
            let asking = Task { @MainActor in await runtime.startChatInAnotherFolder(model) }
            while r.folders.panel.asked.isEmpty { await Task.yield() }
            change(r)
            r.folders.panel.release()
            await asking.value
            return r
        }
        let left = try await openPanelThenChange { $0.runtime.scope.accountLeft() }
        defer { left.folders.cleanup() }
        #expect(!FileManager.default.fileExists(atPath: left.folders.registry.file.path) && left.model.conversationID == left.conversation, "계정이 떠났다")
        let switched = try await openPanelThenChange { $0.model.newChat() }
        defer { switched.folders.cleanup() }
        #expect(!FileManager.default.fileExists(atPath: switched.folders.registry.file.path), "다른 대화로 바뀌었다")
        let retargeted = try await openPanelThenChange { $0.chat.setLocalTarget(.taskforce, for: $0.conversation) }
        defer { retargeted.folders.cleanup() }
        #expect(!FileManager.default.fileExists(atPath: retargeted.folders.registry.file.path) && retargeted.model.conversationID == retargeted.conversation, "대상이 바뀌었다")
        // 에이전트에서 에이전트로 바뀐 경우: 여전히 에이전트 대화라 모델의 가드만으로는 못 막는다 — 보내려던 곳이 아니다
        let otherAgentChat = try await openPanelThenChange { r in
            let other = r.chat.reserveNewChat(target: .agent(adapter: "agent:claude-code", connectionID: UUID()), excluding: [r.conversation])
            r.model.openConversation(other)
        }
        defer { otherAgentChat.folders.cleanup() }
        #expect(!FileManager.default.fileExists(atPath: otherAgentChat.folders.registry.file.path) && otherAgentChat.model.conversationID != otherAgentChat.conversation, "다른 에이전트 대화로 바뀌었다")
        let otherAgent = try await openPanelThenChange { $0.chat.setLocalTarget(.agent(adapter: "agent:codex", connectionID: UUID()), for: $0.conversation) }
        defer { otherAgent.folders.cleanup() }
        #expect(!FileManager.default.fileExists(atPath: otherAgent.folders.registry.file.path) && otherAgent.model.conversationID == otherAgent.conversation, "다른 에이전트로 바뀌었다")
    }

    @Test func aSecondPressWhileThePanelIsOpenDoesNothing() async throws {
        let r = try modelRig()
        defer { r.folders.cleanup() }
        r.folders.panel.choice = r.folders.path("client-b")
        r.folders.panel.holds = true
        let runtime = r.runtime
        let model = r.model
        let first = Task { @MainActor in await runtime.startChatInAnotherFolder(model) }
        while r.folders.panel.asked.isEmpty { await Task.yield() }
        await r.runtime.startChatInAnotherFolder(r.model)
        #expect(r.folders.panel.asked.count == 1, "한 창만")
        // 폴더 창이 떠 있는 동안의 보내기도 같은 창을 쓴다: 보내지 않는다 (글은 입력 칸에 그대로)
        await r.runtime.sendFromWindow(r.model)
        #expect(r.chat.turns(for: r.conversation).isEmpty && r.model.draft == "ship it")
        r.folders.panel.release()
        await first.value
        #expect(r.model.conversationID != r.conversation)
    }

    @Test func aTaskforceConversationOrAMissingRegistryNeverOpensThePanel() async throws {
        let r = try modelRig()
        defer { r.folders.cleanup() }
        r.folders.panel.choice = r.folders.path("client-b")
        let taskforce = r.chat.reserveNewChat(target: .taskforce, excluding: [r.conversation])
        await r.runtime.startChatInAnotherFolder(AssistantWindowModel(conversationID: taskforce, chat: r.chat, targets: r.runtime.targets))
        r.runtime.workspaceAsking = { nil }
        await r.runtime.startChatInAnotherFolder(r.model)
        #expect(r.folders.panel.asked.isEmpty && r.model.conversationID == r.conversation)
    }

    // MARK: 실제 창: 머리의 폴더 컨트롤과 끌기

    @MainActor
    private struct WindowRig {
        let controller: EdgeShellController
        let runtime: ChatRuntime
        let defaults: TestDefaults
        let account: AppChatAccount
        let folders: Folders
        let model: AssistantWindowModel
        let window: AssistantWindowController
        var manager: AssistantWindowManager { controller.assistant! }

        func cleanup() {
            window.panel.orderOut(nil)
            manager.closeAll()
            defaults.cleanup()
            folders.cleanup()
        }
    }

    /// 에이전트 대화(견본: 세션이 이 Mac에 있다) 하나를 보이는 창. `pinned`면 그 세션의 핀에 그 폴더가 적혀 있다
    private func windowRig(pinned: String? = nil, taskforce: Bool = false) async throws -> WindowRig {
        let folders = try Folders()
        let account = try AppChatAccount.make()
        let gateway = AgentChatSampleGateway()
        gateway.state = Data.inFlight()
        let runtime = ChatRuntime(gateway: gateway, contextGateway: IssueSampleContextGateway(), scope: account.scope, now: { Date() }, issueScreens: true)
        folders.install(in: runtime)
        if let pinned { try folders.registry.pin(session: Data.sessionID.uuidString, to: folders.path(pinned)) }
        let defaults = try TestDefaults()
        let controller = EdgeShellController(
            launcher: LauncherModel(configurationError: "test"), chat: runtime, assistantWindows: true, positionStore: AssistantWindowPositionStore(defaults: defaults.defaults)
        )
        controller.assistant?.presents = false
        await runtime.targets.refresh()
        await runtime.chat.refresh()
        let manager = try #require(controller.assistant)
        let conversation = taskforce ? runtime.chat.reserveNewChat(target: .taskforce, excluding: []) : Data.conversationID
        let id = try #require(manager.openWindow(for: conversation))
        let window = try #require(manager.controllers[id])
        await runtime.chat.settle()
        return WindowRig(controller: controller, runtime: runtime, defaults: defaults, account: account, folders: folders, model: window.model, window: window)
    }

    /// 창을 (화면 밖이 아니어도 가려지지 않게 올리지 않고) 레이아웃해서 SwiftUI가 머리 · 입력 영역의 높이를 알릴 때까지 기다린다
    private func layOut(_ window: AssistantWindowController) async throws {
        window.panel.orderFront(nil)
        for _ in 0..<200 {
            window.panel.contentView?.layoutSubtreeIfNeeded()
            if window.presentation.headHeight > 0, window.presentation.footerHeight > 0 { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// 창 안의 한 점(위가 0)을 누르면 받는 뷰
    private func hit(_ window: AssistantWindowController, x: CGFloat, y: CGFloat) -> NSView? {
        guard let content = window.panel.contentView else { return nil }
        let inWindow = NSPoint(x: x, y: window.panel.frame.height - y)
        return content.hitTest(content.convert(content.convert(inWindow, from: nil), to: content.superview))
    }

    @Test func theHeaderGrowsByTheFolderControlOnlyWhenTheConversationHasAFolder() async throws {
        let plain = try await windowRig()
        defer { plain.cleanup() }
        try await layOut(plain.window)
        let without = plain.window.presentation.headHeight
        #expect(plain.runtime.folderLine(for: plain.model) == nil)

        let pinned = try await windowRig(pinned: "client-a")
        defer { pinned.cleanup() }
        try await layOut(pinned.window)
        let with = pinned.window.presentation.headHeight
        #expect(with > without + 20, "머리가 폴더 컨트롤 한 줄만큼 커진다: \(without) → \(with)")

        // History 화면에서는 폴더 줄이 없다 (프로젝트 줄처럼 대화 머리의 것): 폴더가 없는 창의 History 머리와 같다
        func historyHead(_ r: WindowRig) async throws -> CGFloat {
            let before = r.window.presentation.headHeight
            r.model.toggleHistory()
            for _ in 0..<200 where r.window.presentation.headHeight == before {
                r.window.panel.contentView?.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
            return r.window.presentation.headHeight
        }
        let plainHistory = try await historyHead(plain)
        let pinnedHistory = try await historyHead(pinned)
        #expect(plainHistory < without && pinnedHistory == plainHistory, "History: 폴더 줄 없음 (\(plainHistory) · \(pinnedHistory))")
    }

    @Test func aTaskforceConversationWindowHasNoFolderControlEvenWithAFolderRecordedForIt() async throws {
        let plain = try await windowRig()
        defer { plain.cleanup() }
        try await layOut(plain.window)
        let taskforce = try await windowRig(taskforce: true)
        defer { taskforce.cleanup() }
        try taskforce.folders.registry.setPending(taskforce.folders.path("client-a"), conversation: taskforce.model.conversationID)
        try await layOut(taskforce.window)
        #expect(taskforce.window.presentation.headHeight == plain.window.presentation.headHeight)
    }

    @Test func theFolderControlTakesItsOwnPressesWhileTheRestOfTheHeaderStillDragsTheWindow() async throws {
        let r = try await windowRig(pinned: "client-a")
        defer { r.cleanup() }
        try await layOut(r.window)
        let width = r.window.panel.frame.width
        // 폴더 줄은 제목 줄 바로 아래다: 핸들 14 + 제목 줄(위 2 · 단추 28 · 아래 8) = 52 → 컨트롤(26)의 가운데는 위에서 65
        let rowY: CGFloat = 14 + 38 + 13
        // 컨트롤 위의 누름은 끌기 뷰가 아니다 (컨트롤이 받는다)
        for x in [24.0, 40.0, 56.0] {
            #expect(!(hit(r.window, x: x, y: rowY) is AssistantDragRegion.DragNSView), "컨트롤 위 (\(x), \(rowY))는 창을 끌지 않는다")
        }
        // 컨트롤 오른쪽의 빈 곳 · 제목 줄 · 핸들은 계속 창을 끈다
        for x in [width - 40, width / 2 + 60] {
            #expect(hit(r.window, x: x, y: rowY) is AssistantDragRegion.DragNSView, "폴더 줄의 빈 곳 (\(x), \(rowY))은 창을 끈다")
        }
        #expect(hit(r.window, x: 200, y: 34) is AssistantDragRegion.DragNSView, "제목 줄")
        #expect(hit(r.window, x: width / 2, y: 8) is AssistantDragRegion.DragNSView, "핸들")
    }

    /// 창 안의 한 점에서의 왼쪽 마우스 이벤트 (위가 0)
    private func mouseEvent(_ type: NSEvent.EventType, _ window: AssistantWindowController, x: CGFloat, y: CGFloat) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type, location: NSPoint(x: x, y: window.panel.frame.height - y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
    }

    @Test func pressingTheEmptyPartOfTheFolderRowMovesTheWindowJustLikeTheTitleRow() async throws {
        let r = try await windowRig(pinned: "client-a")
        defer { r.cleanup() }
        try await layOut(r.window)
        let panel = r.window.panel
        let rowY: CGFloat = 14 + 38 + 13
        let view = try #require(hit(r.window, x: panel.frame.width - 40, y: rowY) as? AssistantDragRegion.DragNSView)
        let before = panel.frame.origin
        // 누른 곳 → (+40, −20) → (+90, −50) → 놓음 (화면 좌표, 아래가 0): 시험이 실제 끌기 따라가기(`AssistantMouseTracker`)를 그대로 돈다
        var queue = [CGPoint(x: 500, y: 500), CGPoint(x: 540, y: 480), CGPoint(x: 590, y: 450), CGPoint(x: 590, y: 450)]
        view.tracker.locate = { _ in queue.removeFirst() }
        view.tracker.timeout = 2
        view.tracker.buttonIsDown = { true }
        for type in [NSEvent.EventType.leftMouseDragged, .leftMouseDragged, .leftMouseUp] {
            NSApp.postEvent(try mouseEvent(type, r.window, x: 0, y: 0), atStart: false)
        }
        view.mouseDown(with: try mouseEvent(.leftMouseDown, r.window, x: panel.frame.width - 40, y: rowY))
        #expect(panel.frame.origin == CGPoint(x: before.x + 90, y: before.y - 50), "폴더 줄의 빈 곳을 끌면 창이 마우스를 따라간다")
    }
}
