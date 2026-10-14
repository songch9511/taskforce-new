import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import Taskforce
@testable import TaskforceKit
@testable import TaskforceUI

/// 최소 가짜 서버 (창 시험용): 대화 행만 정한다
private final class WindowTestGateway: ChatGateway, @unchecked Sendable {
    nonisolated(unsafe) var rows: [ChatConversation] = []

    func conversations() async throws -> [ChatConversation] { rows }
    func lastMessages(conversationIDs: [UUID]) async throws -> [UUID: ChatMessage] { [:] }
    func messages(conversationID: UUID) async throws -> [ChatMessage] { [] }
    func message(id: UUID) async throws -> ChatMessage? { nil }
    func workContexts() async throws -> [WorkContext] { [] }
    func currentMemoryItems() async throws -> [MemoryItem] { [] }
    func memoryItems(ids: [UUID]) async throws -> [MemoryItem] { [] }
    func memorySource(id: UUID) async throws -> MemorySource? { nil }
    func createConversation(id: UUID, title: String?, contextID: UUID?) async throws -> ChatConversation {
        ChatConversation(id: id, title: title, contextID: contextID, createdAt: Date())
    }
    func updateConversation(id: UUID, contextID: UUID?) async throws -> ChatConversation { throw URLError(.badURL) }
    func postChatMessage(conversationID: UUID, clientMessageID: UUID, text: String) async throws -> ChatPostedMessage { throw URLError(.timedOut) }
    func confirmMemory(id: UUID, expectedVersion: Int) async throws -> MemoryItem { throw URLError(.badURL) }
    func editMemory(id: UUID, edit: MemoryEdit) async throws -> MemoryItem { throw URLError(.badURL) }
    func forgetMemory(id: UUID, expectedVersion: Int) async throws -> MemoryItem { throw URLError(.badURL) }
    func moveMemory(id: UUID, expectedVersion: Int, to target: MemoryTarget) async throws -> MemoryItem { throw URLError(.badURL) }
}

/// Assistant 창 관리자 (OA U1): 첫 창의 자리 · 겹쳐 열기 · 같은 대화 재사용 · 상한 · 위치 기억 · 숨김 / 닫기 · 계정 경계 · 키.
/// 창은 만들되 화면에 올리지 않는다 (`presents = false`): 자리 · 상태만 본다. 위치는 격리 suite에 기억한다 (실사용 설정을 건드리지 않는다)
@MainActor
struct AssistantWindowTests {
    let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
    let rail = CGRect(x: 1396, y: 400, width: 44, height: 319)

    private struct Rig {
        let manager: AssistantWindowManager
        let runtime: ChatRuntime
        let shell: EdgeShellModel
        let gateway: WindowTestGateway
        let account: AppChatAccount
        let defaults: TestDefaults
    }

    private func rig(panel: CGRect? = nil, defaults: TestDefaults? = nil, rows: [ChatConversation] = []) throws -> Rig {
        let gateway = WindowTestGateway()
        gateway.rows = rows
        let account = try AppChatAccount.make()
        let runtime = ChatRuntime(gateway: gateway, scope: account.scope, now: { Date() })
        let shell = EdgeShellModel(schedule: { _, _ in EdgeTimer() }, chatsEnabled: true, windowsEnabled: true)
        let store = try defaults ?? TestDefaults()
        let visible = visible
        let rail = rail
        let manager = AssistantWindowManager(
            runtime: runtime, shell: shell, store: AssistantWindowPositionStore(defaults: store.defaults),
            environment: .init(visibleFrame: { visible }, railFrame: { rail }, panelFrame: { panel }, display: { "1" })
        )
        manager.presents = false
        return Rig(manager: manager, runtime: runtime, shell: shell, gateway: gateway, account: account, defaults: store)
    }

    private func topLeft(_ r: Rig, _ id: UUID) -> CGPoint? { r.manager.controllers[id]?.topLeft }

    /// 서버에 있는 대화 하나 (마지막 메시지가 `age`초 전)
    private func row(_ n: Int, _ title: String, age: TimeInterval = 0) -> ChatConversation {
        let id = UUID(uuidString: String(format: "bcb50000-0000-4000-8000-%012d", n))!
        return ChatConversation(id: id, title: title, createdAt: Date(), lastMessageAt: Date(timeIntervalSinceNow: -age))
    }

    // MARK: 자리

    @Test func theFirstWindowOpensTwelveLeftOfTheRailWhenNoPanelIsOpen() throws {
        let r = try rig()
        defer { r.defaults.cleanup() }
        let id = try #require(r.manager.openNewWindow())
        let point = try #require(topLeft(r, id))
        #expect(point.x == rail.minX - 12 - AssistantWindowGeometry.width)
        #expect(point.y == rail.maxY, "위는 레일과 같다")
        let frame = try #require(r.manager.controllers[id]?.panel.frame)
        #expect(frame.width == 380 && frame.maxY == point.y && frame.minX == point.x, "위 가장자리 기준으로 앉는다")
        #expect(frame.height == AssistantWindowGeometry.emptyHeight, "빈 대화는 440")
    }

    @Test func theFirstWindowOpensTwelveLeftOfTheOpenPanelAndTopAlignedWithIt() throws {
        let panel = CGRect(x: 1440 - 44 - 12 - 380, y: 380, width: 380, height: 339)
        let r = try rig(panel: panel)
        defer { r.defaults.cleanup() }
        let id = try #require(r.manager.openNewWindow())
        let point = try #require(topLeft(r, id))
        #expect(point.x == panel.minX - 12 - 380 && point.y == panel.maxY)
    }

    @Test func eachNewWindowCascadesTwentyFourDownAndLeftFromTheFrontOne() throws {
        let r = try rig()
        defer { r.defaults.cleanup() }
        let first = try #require(r.manager.openNewWindow())
        let second = try #require(r.manager.openNewWindow())
        let a = try #require(topLeft(r, first)), b = try #require(topLeft(r, second))
        #expect(second != first)
        #expect(b == CGPoint(x: a.x - 24, y: a.y - 24))
        let third = try #require(r.manager.openNewWindow())
        let c = try #require(topLeft(r, third))
        #expect(c == CGPoint(x: b.x - 24, y: b.y - 24), "가장 앞 창(방금 연 창)에서")
    }

    @Test func aWindowNeverCoversTheRailOrLeavesTheScreen() throws {
        let r = try rig()
        defer { r.defaults.cleanup() }
        let id = try #require(r.manager.openNewWindow())
        let controller = try #require(r.manager.controllers[id])
        controller.place(topLeft: CGPoint(x: 1300, y: 900))
        #expect(controller.panel.frame.maxX <= rail.minX, "레일을 덮지 않는다")
        #expect(controller.panel.frame.maxY <= visible.maxY && controller.panel.frame.minY >= visible.minY)
    }

    // MARK: 한 창 = 한 대화 · 상한

    @Test func openingAConversationThatHasAWindowBringsThatWindowForward() throws {
        let rows = [row(1, "Pricing")]
        let r = try rig(rows: rows)
        defer { r.defaults.cleanup() }
        let first = try #require(r.manager.openWindow(for: rows[0].id))
        let other = try #require(r.manager.openNewWindow())
        #expect(r.manager.registry.frontmost == other)
        let again = try #require(r.manager.openWindow(for: rows[0].id))
        #expect(again == first && r.manager.controllers.count == 2, "같은 대화의 창은 하나")
        #expect(r.manager.registry.frontmost == first)
    }

    @Test func atMostEightWindowsAndTheNinthRaisesTheLeastRecentlyUsed() throws {
        let r = try rig()
        defer { r.defaults.cleanup() }
        var ids: [UUID] = []
        for _ in 0..<8 { ids.append(try #require(r.manager.openNewWindow())) }
        #expect(r.manager.controllers.count == 8)
        let ninth = try #require(r.manager.openNewWindow())
        #expect(r.manager.controllers.count == 8, "아홉째 창은 만들지 않는다")
        #expect(ninth == ids[0], "가장 오래 쓰지 않은 창이 앞으로 온다")
        #expect(r.manager.registry.frontmost == ids[0])
    }

    @Test func twoNewWindowsAreTwoDifferentChatsAndAnEmptyChatNoOtherWindowHoldsIsReused() throws {
        let r = try rig()
        defer { r.defaults.cleanup() }
        let first = try #require(r.manager.openNewWindow())
        let second = try #require(r.manager.openNewWindow())
        let a = try #require(r.manager.controllers[first]?.model.conversationID)
        let b = try #require(r.manager.controllers[second]?.model.conversationID)
        #expect(a != b, "⌘N을 두 번 눌러도 같은 빈 대화를 두 창이 쥐지 않는다")
        r.manager.close(first)
        let third = try #require(r.manager.openNewWindow())
        #expect(r.manager.controllers[third]?.model.conversationID == a, "닫은 창의 빈 대화는 다시 쓴다")
    }

    // MARK: 숨기기 · 닫기

    @Test func escapeHidesAndKeepsTheDraftTheChipsAndThePositionAndChatsShowsItAgain() throws {
        let r = try rig()
        defer { r.defaults.cleanup() }
        let id = try #require(r.manager.openNewWindow())
        let model = try #require(r.manager.controllers[id]?.model)
        model.setDraft("half written")
        model.followOpenItem(AssistantChip(kind: .action, itemID: UUID(), origin: .auto, title: "Pricing"))
        let before = try #require(topLeft(r, id))
        #expect(r.manager.perform(.escape, in: id))
        #expect(r.manager.registry.isHidden(id) && r.shell.assistantWindowFront == false)
        #expect(model.draft == "half written" && model.chips.chips.count == 1 && topLeft(r, id) == before)
        // 레일 Chats · ⌘3: 숨은 창이 다시 보인다 (새 창이 아니다)
        let shown = r.manager.showChats()
        #expect(shown == id && !r.manager.registry.isHidden(id) && r.manager.controllers.count == 1 && r.shell.assistantWindowFront)
    }

    @Test func escapeLeavesTheHistoryFirstThenHidesTheWindow() throws {
        let r = try rig()
        defer { r.defaults.cleanup() }
        let id = try #require(r.manager.openNewWindow())
        let model = try #require(r.manager.controllers[id]?.model)
        model.toggleHistory()
        #expect(r.manager.perform(.escape, in: id) && model.mode == .chat && !r.manager.registry.isHidden(id), "Esc는 안쪽 History를 먼저 닫는다")
        #expect(r.manager.perform(.escape, in: id) && r.manager.registry.isHidden(id))
    }

    @Test func commandWClosesTheWindowAndTheChatStaysInHistory() throws {
        let r = try rig()
        defer { r.defaults.cleanup() }
        let id = try #require(r.manager.openNewWindow())
        let model = try #require(r.manager.controllers[id]?.model)
        let conversation = model.conversationID
        model.setDraft("keep this")
        #expect(r.manager.perform(.close, in: id))
        #expect(r.manager.controllers[id] == nil && r.manager.registry.windowIDs.isEmpty)
        #expect(r.runtime.chat.entries.contains { $0.id == conversation }, "대화는 Chat history에 남는다")
        #expect(r.runtime.chat.draft(for: conversation) == "keep this", "닫아도 초안은 지워지지 않는다")
    }

    @Test func theChatsButtonIsLitOnlyWhileAWindowIsVisible() throws {
        let r = try rig()
        defer { r.defaults.cleanup() }
        #expect(!r.shell.assistantWindowFront)
        let id = try #require(r.manager.openNewWindow())
        #expect(r.shell.assistantWindowFront)
        r.manager.hide(id)
        #expect(!r.shell.assistantWindowFront)
        r.manager.bringForward(id)
        #expect(r.shell.assistantWindowFront)
        r.manager.close(id)
        #expect(!r.shell.assistantWindowFront)
    }

    // MARK: 위치 기억

    @Test func aWindowRemembersItsPositionPerConversationAcrossRestartsOnAnIsolatedSuite() throws {
        let r = try rig()
        defer { r.defaults.cleanup() }
        let id = try #require(r.manager.openNewWindow())
        let conversation = try #require(r.manager.controllers[id]?.model.conversationID)
        let controller = try #require(r.manager.controllers[id])
        controller.move(by: .left)
        controller.move(by: .down)
        let moved = controller.topLeft
        // 앱을 다시 켠 것처럼 새 관리자 (같은 suite)
        let again = AssistantWindowManager(
            runtime: r.runtime, shell: r.shell, store: AssistantWindowPositionStore(defaults: r.defaults.defaults),
            environment: .init(visibleFrame: { visible }, railFrame: { rail }, panelFrame: { nil }, display: { "1" })
        )
        again.presents = false
        let reopened = try #require(again.openWindow(for: conversation))
        #expect(again.controllers[reopened]?.topLeft == moved, "그 대화의 기억된 위치")
        // 다른 화면에서는 기억이 없다
        let elsewhere = AssistantWindowManager(
            runtime: r.runtime, shell: r.shell, store: AssistantWindowPositionStore(defaults: r.defaults.defaults),
            environment: .init(visibleFrame: { visible }, railFrame: { rail }, panelFrame: { nil }, display: { "2" })
        )
        elsewhere.presents = false
        let other = try #require(elsewhere.openWindow(for: conversation))
        #expect(elsewhere.controllers[other]?.topLeft != moved)
    }

    // MARK: 계정 · 열린 항목

    @Test func leavingTheAccountClosesEveryWindowAndForgetsTheirPositions() throws {
        let r = try rig()
        defer { r.defaults.cleanup() }
        r.manager.start()
        defer { r.manager.stop() }
        let id = try #require(r.manager.openNewWindow())
        try #require(r.manager.controllers[id]).move(by: .left)
        #expect(r.defaults.defaults.data(forKey: AssistantWindowPositionStore.key) != nil)
        _ = try #require(r.manager.openNewWindow())
        r.account.scope.accountLeft()
        #expect(r.manager.controllers.isEmpty && r.manager.registry.windowIDs.isEmpty)
        #expect(r.defaults.defaults.data(forKey: AssistantWindowPositionStore.key) == nil, "대화 id는 그 계정의 것이다: 위치 기억도 지운다")
        #expect(!r.shell.assistantWindowFront)
    }

    @Test func theFrontWindowFollowsTheOpenItemAndTheOthersKeepTheirChips() throws {
        let r = try rig()
        defer { r.defaults.cleanup() }
        let back = try #require(r.manager.openNewWindow())
        let front = try #require(r.manager.openNewWindow())
        let pricing = (id: UUID(), title: "Pricing")
        let onboarding = (id: UUID(), title: "Onboarding")
        r.manager.controllers[front]?.model.followOpenItem(AssistantWindowManager.chip(for: pricing))
        r.manager.controllers[back]?.model.followOpenItem(AssistantWindowManager.chip(for: pricing))
        r.manager.controllers[front]?.model.followOpenItem(AssistantWindowManager.chip(for: onboarding))
        #expect(r.manager.controllers[front]?.model.chips.chips.map(\.title) == ["Onboarding"])
        #expect(r.manager.controllers[back]?.model.chips.chips.map(\.title) == ["Pricing"])
    }

    // MARK: 대화 바꾸기 · 되살리기

    @Test func historyOpeningAChatAnotherWindowShowsRaisesThatWindowAndLeavesThisOne() async throws {
        let rows = [row(1, "A", age: 20), row(2, "B", age: 10)]
        let r = try rig(rows: rows)
        defer { r.defaults.cleanup() }
        let a = try #require(r.manager.openWindow(for: rows[0].id))
        let b = try #require(r.manager.openWindow(for: rows[1].id))
        let modelA = try #require(r.manager.controllers[a]?.model)
        #expect(r.manager.registry.frontmost == b)
        modelA.openConversation(rows[1].id)
        #expect(modelA.conversationID == rows[0].id, "B를 다른 창이 쥐고 있어 이 창은 그대로")
        #expect(r.manager.registry.frontmost == b && r.manager.controllers.count == 2)
        // 쥐지 않은 대화로는 이 창이 바뀐다
        let third = row(3, "C")
        r.gateway.rows.append(third)
        await r.runtime.chat.refresh()
        modelA.openConversation(third.id)
        #expect(modelA.conversationID == third.id && r.manager.registry.conversationID(of: a) == third.id)
    }

    @Test func chatsOpensTheLastConversationWhenThereIsOne() async throws {
        let rows = [row(1, "Older", age: 20), row(2, "Latest", age: 10)]
        let r = try rig(rows: rows)
        defer { r.defaults.cleanup() }
        await r.runtime.chat.refresh()
        let id = try #require(r.manager.showChats())
        #expect(r.manager.controllers[id]?.model.conversationID == rows[1].id)
    }

    @Test func aWindowOpenedBeforeTheListWasReadComesBackToTheLastChatIfTheUserDidNotTouchIt() async throws {
        let rows = [row(2, "Latest", age: 10)]
        let r = try rig(rows: rows)
        defer { r.defaults.cleanup() }
        let id = try #require(r.manager.showChats())
        let model = try #require(r.manager.controllers[id]?.model)
        #expect(model.isPristine)
        for _ in 0..<200 where model.conversationID != rows[0].id { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(model.conversationID == rows[0].id, "목록을 읽은 뒤에도 손대지 않은 새 창이면 마지막 대화로")
        // 쓰던 글이 있으면 되살리지 않는다
        let busy = try rig(rows: rows)
        defer { busy.defaults.cleanup() }
        let busyID = try #require(busy.manager.showChats())
        let busyModel = try #require(busy.manager.controllers[busyID]?.model)
        busyModel.setDraft("typing")
        let typed = busyModel.conversationID
        try? await Task.sleep(for: .milliseconds(300))
        #expect(busyModel.conversationID == typed && !busyModel.isPristine)
    }

    // MARK: 키

    @Test func theKeysAWindowListensToAreEscapeCommandWAndTheFourShellCommands() {
        func intent(_ code: Int, _ flags: NSEvent.ModifierFlags = []) -> AssistantWindowManager.KeyIntent? {
            AssistantWindowManager.KeyIntent.of(keyCode: code, flags: flags)
        }
        #expect(intent(kVK_Escape) == .escape)
        #expect(intent(kVK_ANSI_W, .command) == .close)
        #expect(intent(kVK_ANSI_W) == nil && intent(kVK_ANSI_W, [.command, .shift]) == nil)
        #expect(intent(kVK_ANSI_1, .command) == .review && intent(kVK_ANSI_2, .command) == .allWork)
        #expect(intent(kVK_ANSI_3, .command) == .chats && intent(kVK_ANSI_N, .command) == .newChat)
        #expect(intent(kVK_ANSI_3) == nil, "수정 키 없는 3은 글자다")
        #expect(intent(kVK_ANSI_A, .command) == nil)
    }

    @Test func theShellCommandsFromAWindowGoToTheShell() throws {
        let r = try rig()
        defer { r.defaults.cleanup() }
        var events: [String] = []
        r.shell.onChats = { events.append("chats") }
        r.shell.onNewWindow = { events.append("new") }
        let id = try #require(r.manager.openNewWindow())
        #expect(r.manager.perform(.chats, in: id) && r.manager.perform(.newChat, in: id))
        #expect(events == ["chats", "new"])
        #expect(r.manager.perform(.allWork, in: id) && r.shell.panelOpen && r.shell.view == .allWork)
        #expect(!r.manager.perform(.review, in: id), "Review가 꺼져 있으면 ⌘1은 지나간다")
        #expect(!r.manager.perform(.escape, in: UUID()), "없는 창의 키는 처리하지 않는다")
    }

    // MARK: 컨트롤러

    @Test func theControllerBuildsTheManagerOnlyWhenWindowsAreOnAndChatsExist() throws {
        let launcher = LauncherModel(configurationError: "test")
        let account = try AppChatAccount.make()
        let runtime = ChatRuntime(gateway: WindowTestGateway(), scope: account.scope, now: { Date() })
        let store = try TestDefaults()
        defer { store.cleanup() }
        let off = EdgeShellController(launcher: launcher, chat: runtime, assistantWindows: false)
        #expect(off.assistant == nil && !off.shell.windowsEnabled, "창이 없는 구성은 지금 그대로(패널의 Chats)")
        let none = EdgeShellController(launcher: launcher, chat: nil, assistantWindows: true)
        #expect(none.assistant == nil && !none.shell.windowsEnabled, "Chats 런타임이 없으면(Release) 창도 없다")
        let on = EdgeShellController(launcher: launcher, chat: runtime, assistantWindows: true, positionStore: AssistantWindowPositionStore(defaults: store.defaults))
        #expect(on.assistant != nil && on.shell.windowsEnabled)
        on.assistant?.presents = false
        // ⌘3 · ⌘N은 패널의 Chats가 아니라 창이다
        let key3 = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil, characters: "3", charactersIgnoringModifiers: "3",
            isARepeat: false, keyCode: UInt16(kVK_ANSI_3)
        ))
        #expect(on.handleKey(key3))
        #expect(on.shell.view != .chats && !on.shell.panelOpen, "패널은 열리지 않는다")
        #expect(on.assistant?.controllers.count == 1)
        let keyN = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil, characters: "n", charactersIgnoringModifiers: "n",
            isARepeat: false, keyCode: UInt16(kVK_ANSI_N)
        ))
        #expect(on.handleKey(keyN))
        #expect(on.assistant?.controllers.count == 2, "⌘N은 새 창")
        on.assistant?.closeAll()
    }

    @Test func thePanelStaysOpenWhenAnAssistantWindowTakesTheKey() throws {
        let launcher = LauncherModel(configurationError: "test")
        let account = try AppChatAccount.make()
        let runtime = ChatRuntime(gateway: WindowTestGateway(), scope: account.scope, now: { Date() })
        let store = try TestDefaults()
        defer { store.cleanup() }
        let controller = EdgeShellController(launcher: launcher, chat: runtime, assistantWindows: true, positionStore: AssistantWindowPositionStore(defaults: store.defaults))
        controller.assistant?.presents = false
        controller.shell.openAllWork()
        let id = try #require(controller.assistant?.openNewWindow())
        let window = try #require(controller.assistant?.controllers[id]?.panel)
        #expect(controller.assistant?.owns(window) == true, "창은 패널 밖 클릭으로 세지 않는다")
        #expect(controller.assistant?.owns(controller.panel.panel) == false && controller.assistant?.owns(nil) == false)
        #expect(controller.shell.panelOpen, "창을 열어도 패널은 접히지 않는다")
        controller.assistant?.closeAll()
    }
}
