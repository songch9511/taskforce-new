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

/// 대상 목록을 돌려주는 가짜 (읽기만 한다)
private final class StubTargetsGateway: AssistantGateway, @unchecked Sendable {
    nonisolated(unsafe) var reply: @Sendable () async throws -> [AssistantTarget] = { [.taskforce] }
    func targets() async throws -> [AssistantTarget] { try await reply() }
    func createConversation(id: UUID, title: String?, contextID: UUID?, target: ChatTarget) async throws -> ChatCreatedConversation { throw URLError(.badURL) }
    func postChatMessage(conversationID: UUID, clientMessageID: UUID, text: String, attachments: [ChatAttachment]) async throws -> ChatPostedMessage { throw URLError(.badURL) }
    func postAgentMessage(conversationID: UUID, clientMessageID: UUID, text: String, attachments: [ChatAttachment]) async throws -> AgentPostedMessage { throw URLError(.badURL) }
}

/// 열 때까지 읽기를 붙잡는 문
private actor ReadGate {
    private(set) var arrivals = 0
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        arrivals += 1
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
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

    private func rig(
        panel: CGRect? = nil, defaults: TestDefaults? = nil, rows: [ChatConversation] = [], shell customShell: EdgeShellModel? = nil,
        extraScreens: [AssistantScreen] = []
    ) throws -> Rig {
        let gateway = WindowTestGateway()
        gateway.rows = rows
        let account = try AppChatAccount.make()
        let runtime = ChatRuntime(gateway: gateway, scope: account.scope, now: { Date() })
        let shell = customShell ?? EdgeShellModel(schedule: { _, _ in EdgeTimer() }, chatsEnabled: true, windowsEnabled: true)
        let store = try defaults ?? TestDefaults()
        let visible = visible
        let rail = rail
        let manager = AssistantWindowManager(
            runtime: runtime, shell: shell, store: AssistantWindowPositionStore(defaults: store.defaults),
            environment: .init(visibleFrame: { visible }, railFrame: { rail }, panelFrame: { panel }, display: { "1" }, extraScreens: { extraScreens })
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

    @Test func aNewWindowStartsWithThePanelsOpenItemAsItsAutoChip() async throws {
        let summary = try await SummaryRig.make()
        let item = summary.id(101)
        summary.shell.open(itemID: item)
        #expect(summary.shell.openItem?.id == item)
        let r = try rig(shell: summary.shell)
        defer { r.defaults.cleanup() }
        let id = try #require(r.manager.openNewWindow())
        let chips = try #require(r.manager.controllers[id]?.model.chips.chips)
        #expect(chips.count == 1 && chips[0].itemID == item && chips[0].origin == .auto, "열 때 패널에 열린 항목이 바로 auto 칩이다 (열린 뒤 바뀔 때만이 아니라)")
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

    @Test func historyOpeningAChatAHiddenWindowShowsBringsThatWindowBackVisible() throws {
        let rows = [row(1, "A", age: 20), row(2, "B", age: 10)]
        let r = try rig(rows: rows)
        defer { r.defaults.cleanup() }
        let a = try #require(r.manager.openWindow(for: rows[0].id))
        let b = try #require(r.manager.openWindow(for: rows[1].id))
        r.manager.hide(b)
        #expect(r.manager.registry.isHidden(b) && r.manager.registry.frontmost == a)
        let modelA = try #require(r.manager.controllers[a]?.model)
        let shown = try #require(r.manager.controllers[b]).generation
        modelA.openConversation(rows[1].id)
        #expect(!r.manager.registry.isHidden(b) && r.manager.registry.frontmost == b, "숨은 창이 그 대화를 쥐고 있으면 그 창이 다시 보이고 앞으로 온다")
        let afterwards = try #require(r.manager.controllers[b]).generation
        #expect(afterwards > shown, "화면에도 다시 올린다 (show가 불렸다)")
        #expect(modelA.conversationID == rows[0].id)
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

    @Test func escapeGoesToTheMenuThenTheImeThenTheInnerScreenAndOnlyThenHides() {
        var asked = 0
        func step(menu: Bool, composing: Bool, inner: Bool) -> AssistantWindowManager.EscapeStep {
            AssistantWindowManager.escapeStep(menuOpen: menu, composing: composing, leaveInner: { asked += 1; return inner })
        }
        #expect(step(menu: true, composing: true, inner: true) == .closeMenu && asked == 0, "대상 메뉴가 열려 있으면 메뉴만 닫는다 (안쪽 화면은 건드리지 않는다)")
        #expect(step(menu: false, composing: true, inner: true) == .passThrough && asked == 0, "IME 조합 중인 Esc는 조합 취소다: 지나간다")
        #expect(step(menu: false, composing: false, inner: true) == .leftInner && asked == 1, "History면 대화로 먼저")
        #expect(step(menu: false, composing: false, inner: false) == .hide && asked == 2, "그 밖에는 창을 숨긴다")
    }

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
    @Test func losingTheKeyToAnAssistantWindowKeepsThePanelButAnyOtherKeyWindowFoldsIt() async throws {
        let launcher = LauncherModel(configurationError: "test")
        let account = try AppChatAccount.make()
        let runtime = ChatRuntime(gateway: WindowTestGateway(), scope: account.scope, now: { Date() })
        let store = try TestDefaults()
        defer { store.cleanup() }
        let controller = EdgeShellController(launcher: launcher, chat: runtime, assistantWindows: true, positionStore: AssistantWindowPositionStore(defaults: store.defaults))
        controller.assistant?.presents = false
        controller.ignoresExternalDismissal = false
        controller.shell.openAllWork()
        let id = try #require(controller.assistant?.openNewWindow())
        let window = try #require(controller.assistant?.controllers[id]?.panel)
        let resigned = Notification(name: NSWindow.didResignKeyNotification)
        controller.keyWindow = { window }
        controller.windowDidResignKey(resigned)
        for _ in 0..<10 { await Task.yield() }
        #expect(controller.shell.panelOpen, "키가 이 앱의 Assistant 창으로 옮겨 간 것은 패널을 잃은 것이 아니다")
        controller.keyWindow = { nil }
        controller.windowDidResignKey(resigned)
        for _ in 0..<10 { await Task.yield() }
        #expect(!controller.shell.panelOpen, "키가 다른 곳(다른 앱 · 창 없음)으로 가면 접는다")
        controller.assistant?.closeAll()
    }
    // MARK: 검토 반영 (Astra 독립 검토)

    @Test func theChatStoreReadsTheConversationsTheWindowsShow() throws {
        let rows = [row(1, "A", age: 20), row(2, "B", age: 10)]
        let r = try rig(rows: rows)
        defer { r.defaults.cleanup() }
        #expect(r.runtime.chat.viewedConversations().isEmpty)
        let a = try #require(r.manager.openWindow(for: rows[0].id))
        let b = try #require(r.manager.openWindow(for: rows[1].id))
        #expect(r.runtime.chat.viewedConversations() == [rows[0].id, rows[1].id], "⌘3 · 온라인 복귀의 읽기가 이 대화들을 다시 읽는다")
        r.manager.close(a)
        #expect(r.runtime.chat.viewedConversations() == [rows[1].id])
        _ = b
    }

    @Test func aTargetMenuClosesWhenAnotherWindowOpensOnTop() throws {
        let r = try rig()
        defer { r.defaults.cleanup() }
        let a = try #require(r.manager.openNewWindow())
        let controller = try #require(r.manager.controllers[a])
        controller.toggleTargetMenu()
        #expect(controller.targetMenu.isOpen && controller.presentation.targetMenuOpen)
        _ = try #require(r.manager.openNewWindow())
        #expect(!controller.targetMenu.isOpen && !controller.presentation.targetMenuOpen, "⌘N으로 새 창이 뜨면 이전 창의 메뉴는 닫힌다")
    }

    @Test func aTargetMenuClosesWhenAnExistingWindowIsBroughtForward() throws {
        let rows = [row(1, "A", age: 20), row(2, "B", age: 10)]
        let r = try rig(rows: rows)
        defer { r.defaults.cleanup() }
        let a = try #require(r.manager.openWindow(for: rows[0].id))
        let b = try #require(r.manager.openWindow(for: rows[1].id))
        let controller = try #require(r.manager.controllers[a])
        r.manager.bringForward(a)
        controller.toggleTargetMenu()
        #expect(controller.targetMenu.isOpen)
        r.manager.bringForward(b)
        #expect(!controller.targetMenu.isOpen)
    }

    @Test func aTargetMenuOnlyHandlesKeysThatCameToItsOwnWindowAndClosesWhenItLosesTheKey() throws {
        let r = try rig()
        defer { r.defaults.cleanup() }
        let a = try #require(r.manager.openNewWindow())
        let other = try #require(r.manager.openNewWindow())
        let controller = try #require(r.manager.controllers[a])
        let otherWindow = try #require(r.manager.controllers[other]).panel
        controller.toggleTargetMenu()
        let menu = controller.targetMenu
        let menuWindow = try #require(menu.window)
        var picked: [String] = []
        menu.model?.onPick = { picked.append($0.name) }
        func key(_ code: UInt16, in window: NSWindow) throws -> NSEvent {
            try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: code
            ))
        }
        let downElsewhere = try key(125, in: otherWindow), returnElsewhere = try key(36, in: otherWindow)
        let downHere = try key(125, in: menuWindow), returnHere = try key(36, in: menuWindow)
        #expect(!menu.handle(downElsewhere) && !menu.handle(returnElsewhere), "다른 창의 키는 가로채지 않는다")
        #expect(picked.isEmpty)
        #expect(menu.handle(downHere), "자기 창의 ↓은 처리한다")
        #expect(menu.handle(returnHere) && picked == ["Taskforce"], "자기 창의 Return은 짚은 행을 고른다")
        // 키를 잃으면 닫힌다
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: menuWindow)
        #expect(!menu.isOpen && !controller.presentation.targetMenuOpen)
    }

    @Test func theTargetMenuOfAWindowFollowsTheTargetStoreWhileItIsOpen() async throws {
        let r = try rig()
        defer { r.defaults.cleanup() }
        let stub = StubTargetsGateway()
        let gate = ReadGate()
        stub.reply = {
            await gate.wait()
            return [.taskforce, .agent(.init(adapter: "agent:codex", displayName: "Codex", connectionID: UUID(), state: .ready, access: .write))]
        }
        r.runtime.targets.gateway = stub
        let id = try #require(r.manager.openNewWindow())
        let controller = try #require(r.manager.controllers[id])
        controller.toggleTargetMenu()
        let model = try #require(controller.targetMenu.model)
        #expect(model.status == .loading && model.options.map(\.name) == ["Taskforce"], "읽는 중에 연 메뉴")
        for _ in 0..<1000 where await gate.arrivals == 0 { await Task.yield() }
        await gate.open()
        for _ in 0..<500 where model.status != .ready { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(model.status == .ready && model.options.map(\.name) == ["Taskforce", "Codex"], "끝난 뒤 열려 있는 메뉴에 에이전트 행이 나타난다")
        stub.reply = { throw URLError(.notConnectedToInternet) }
        await r.runtime.targets.refresh()
        #expect(model.status == .failed, "실패는 숨기지 않는다")
        controller.targetMenu.dismiss()
    }

    @Test func historyRebindAppliesTheOtherConversationsSavedPosition() throws {
        let rows = [row(1, "A", age: 20), row(2, "B", age: 10)]
        let r = try rig(rows: rows)
        defer { r.defaults.cleanup() }
        let b = try #require(r.manager.openWindow(for: rows[1].id))
        let bController = try #require(r.manager.controllers[b])
        bController.move(by: .left)
        bController.move(by: .up)
        let saved = bController.topLeft
        r.manager.close(b)
        let a = try #require(r.manager.openWindow(for: rows[0].id))
        let aController = try #require(r.manager.controllers[a])
        #expect(aController.topLeft != saved)
        aController.model.openConversation(rows[1].id)
        #expect(aController.model.conversationID == rows[1].id && aController.topLeft == saved, "History로 연 대화의 저장 위치로 간다")
        // 저장 위치가 없는 대화는 지금 자리 그대로
        let place = aController.topLeft
        aController.model.newChat()
        #expect(aController.topLeft == place)
    }

    @Test func aMouseDragIsClampedOnceTheMouseIsUpAndOnlyThenSaved() async throws {
        let r = try rig()
        defer { r.defaults.cleanup() }
        let id = try #require(r.manager.openNewWindow())
        let controller = try #require(r.manager.controllers[id])
        let conversation = try #require(r.manager.registry.conversationID(of: id))
        controller.moveSettleDelay = .milliseconds(1)
        var down = true
        controller.mouseIsDown = { down }
        try? await Task.sleep(for: .milliseconds(50))   // 창을 연 직후의 높이 맞춤이 끝난 뒤에 끈다
        controller.panel.setFrameOrigin(CGPoint(x: 1380, y: 300))
        controller.windowDidMove(Notification(name: NSWindow.didMoveNotification))
        try? await Task.sleep(for: .milliseconds(60))
        #expect(controller.panel.frame.maxX > rail.minX, "마우스를 누르고 있는 동안은 따라온다 (끌리는 창을 되돌리지 않는다)")
        #expect(AssistantWindowPositionStore(defaults: r.defaults.defaults).load().position(conversation: conversation, display: "1") == nil, "끝나기 전에는 저장하지 않는다")
        down = false
        func savedPosition() -> CGPoint? {
            AssistantWindowPositionStore(defaults: r.defaults.defaults).load().position(conversation: conversation, display: "1")
        }
        for _ in 0..<400 where savedPosition() == nil { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(controller.panel.frame.maxX <= rail.minX, "마우스를 놓으면 레일 밖으로 들어간다")
        let saved = try #require(savedPosition())
        #expect(saved == controller.topLeft && saved.x + AssistantWindowGeometry.width <= rail.minX, "보정한 자리를 저장한다")
        #expect(controller.desiredTopLeft == controller.topLeft, "보정한 자리가 새 바람이다 (끌던 밖의 자리가 남지 않는다)")
    }

    @Test func aWindowOnASecondScreenIsClampedAndSavedAgainstThatScreen() throws {
        let side = AssistantScreen(id: "2", visible: CGRect(x: 1440, y: 100, width: 1920, height: 1000))
        let r = try rig(extraScreens: [side])
        defer { r.defaults.cleanup() }
        let id = try #require(r.manager.openNewWindow())
        let controller = try #require(r.manager.controllers[id])
        let conversation = try #require(r.manager.registry.conversationID(of: id))
        controller.place(topLeft: CGPoint(x: 2800, y: 900))
        #expect(controller.topLeft == CGPoint(x: 2800, y: 900), "보조 화면의 창을 주 화면으로 끌어오지 않는다")
        controller.applyFrame()
        #expect(controller.topLeft == CGPoint(x: 2800, y: 900), "높이를 다시 맞춰도 그 자리")
        controller.place(topLeft: CGPoint(x: side.visible.maxX - 380, y: 900))
        #expect(controller.topLeft.x == side.visible.maxX - 380, "레일은 주 화면에만 있다: 보조 화면은 오른쪽 끝까지")
        controller.move(by: .left)
        let saved = AssistantWindowPositionStore(defaults: r.defaults.defaults).load()
        #expect(saved.position(conversation: conversation, display: "2") == controller.topLeft && saved.position(conversation: conversation, display: "1") == nil, "그 창이 있는 화면의 키로 저장한다")
        let before = controller.topLeft
        r.manager.bringForward(id)
        #expect(controller.topLeft == before, "앞으로 가져와도 주 화면으로 되돌리지 않는다")
        // 주 화면에서는 레일을 덮지 않는다
        controller.place(topLeft: CGPoint(x: 1100, y: 900))
        #expect(controller.panel.frame.maxX <= rail.minX, "주 화면 쪽에 더 걸친 창은 레일을 덮지 않는다")
    }
    @Test func aWindowReopensAtTheSavedSpotOnTheScreenOfTheFrontWindow() throws {
        let side = AssistantScreen(id: "2", visible: CGRect(x: 1440, y: 100, width: 1920, height: 1000))
        let rows = [row(1, "A", age: 20)]
        let r = try rig(rows: rows, extraScreens: [side])
        defer { r.defaults.cleanup() }
        let first = try #require(r.manager.openWindow(for: rows[0].id))
        let controller = try #require(r.manager.controllers[first])
        controller.place(topLeft: CGPoint(x: 2400, y: 900))
        controller.move(by: .left)
        let saved = controller.topLeft
        r.manager.close(first)
        // 앞 창이 보조 화면에 있다: 그 대화는 그 화면에서 기억한 자리로 다시 열린다
        let front = try #require(r.manager.openNewWindow())
        try #require(r.manager.controllers[front]).place(topLeft: CGPoint(x: 3000, y: 800))
        let reopened = try #require(r.manager.openWindow(for: rows[0].id))
        #expect(r.manager.controllers[reopened]?.topLeft == saved, "앞 창의 화면에서 찾은 기억")
    }
    // MARK: 검토 반영 2 (Astra 재검토)

    @Test func historyRebindRestoresTheSavedPositionOnceTheNewConversationsOwnHeightIsLaidOut() throws {
        let rows = [row(1, "A", age: 20)]
        let r = try rig(rows: rows)
        defer { r.defaults.cleanup() }
        // B: 빈 새 대화(높이 440). 화면 아래 끝(위 가장자리 440)에 두고 옮겨 저장한다
        let b = try #require(r.manager.openNewWindow())
        let bController = try #require(r.manager.controllers[b])
        let bConversation = try #require(r.manager.registry.conversationID(of: b))
        bController.place(topLeft: CGPoint(x: 500, y: 440))
        bController.move(by: .left)
        let saved = bController.topLeft
        #expect(saved.y == 440 && bController.panel.frame.height == 440)
        r.manager.close(b)
        // A: 글이 있는 긴 대화(높이 560)
        let a = try #require(r.manager.openWindow(for: rows[0].id))
        let aController = try #require(r.manager.controllers[a])
        aController.presentation.bodyHeight = 600
        aController.place(topLeft: CGPoint(x: 900, y: 800))
        #expect(aController.panel.frame.height == 560)
        aController.model.openConversation(bConversation)
        #expect(aController.desiredTopLeft == saved, "저장 위치는 바라는 자리로 남는다 (앞 대화 높이로 보정된 값이 원본이 되지 않는다)")
        // B의 높이가 반영되면 저장 위치(440)여야 한다
        aController.presentation.bodyHeight = 0
        aController.applyFrame()
        #expect(aController.panel.frame.height == 440)
        #expect(aController.topLeft == saved, "앞 대화의 높이로 보정한 자리가 아니라 B의 저장 위치")
        #expect(aController.panel.frame.minY == 0)
    }

    @Test func aHeightChangeRestoresTheDesiredSpotAfterAnEarlierHeightPushedTheWindowAway() throws {
        let r = try rig()
        defer { r.defaults.cleanup() }
        let id = try #require(r.manager.openNewWindow())
        let controller = try #require(r.manager.controllers[id])
        // 560pt 높이일 때 화면 아래 끝(위 가장자리 440)을 바라면 위 가장자리가 560으로 밀린다
        controller.presentation.bodyHeight = 600
        controller.place(topLeft: CGPoint(x: 500, y: 440))
        #expect(controller.panel.frame.height == 560 && controller.topLeft.y == 560 && controller.desiredTopLeft.y == 440)
        // 높이가 440으로 줄면(다른 대화의 높이) 바라던 자리로 돌아온다
        controller.presentation.bodyHeight = 0
        controller.applyFrame()
        #expect(controller.panel.frame.height == 440 && controller.topLeft.y == 440, "밀려난 자리가 굳지 않는다")
        // 사용자가 옮긴 자리가 새 바람이다: 경계에 막혀 못 간 만큼은 바람에 남기지 않는다 (아래 끝에서 ↓)
        controller.move(by: .down)
        #expect(controller.topLeft.y == 440 && controller.desiredTopLeft == controller.topLeft, "보정된 자리가 새 바람")
    }

    @Test func aHeightChangeStaysOnTheScreenTheWindowWasOnEvenWhenItWouldOverlapAnotherMore() async throws {
        // 세로로 쌓인 두 화면: 위 화면은 y 875 ..< 1750
        let upper = AssistantScreen(id: "2", visible: CGRect(x: 0, y: 875, width: 1440, height: 875))
        let rows = [row(1, "A", age: 20)]
        let r = try rig(rows: rows, extraScreens: [upper])
        defer { r.defaults.cleanup() }
        await r.runtime.chat.refresh()   // 글이 있는 대화: 빈 대화의 바닥 높이(440)가 걸리지 않는다
        let id = try #require(r.manager.openWindow(for: rows[0].id))
        let controller = try #require(r.manager.controllers[id])
        // 창 높이 = 머리 + 본문 + 입력 영역: 220pt로 맞춘다
        controller.presentation.headHeight = 0
        controller.presentation.bodyHeight = 220
        controller.presentation.footerHeight = 0
        controller.place(topLeft: CGPoint(x: 500, y: 875 + 220))
        #expect(controller.panel.frame.height == 220 && controller.panel.frame.minY == 875 && controller.currentScreenID == "2", "위 화면 아래 끝의 220pt 창")
        controller.presentation.bodyHeight = 600
        controller.applyFrame()
        #expect(controller.panel.frame.height == 560)
        #expect(controller.currentScreenID == "2" && controller.panel.frame.minY >= 875, "아래 화면과 더 많이 겹쳐도 위 화면 안에서 위로 밀려 자란다")
        let expectedTop: CGFloat = 875 + 560
        #expect(controller.topLeft.y == expectedTop, "위 화면 아래 끝(875)에서 560 높이가 위 화면 안에 들어오게 위 가장자리가 올라간다")
        // 실제 이동은 목적지의 화면을 따른다
        controller.place(topLeft: CGPoint(x: 500, y: 500))
        #expect(controller.currentScreenID == "1" && controller.panel.frame.minY >= 0 && controller.panel.frame.maxY <= 875)
    }
}
