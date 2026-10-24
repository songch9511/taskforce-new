import Auth
import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import Taskforce
@testable import TaskforceKit
@testable import TaskforceUI

/// 요청을 붙잡았다 놓는 문 (옛 세션의 요청이 새 세션이 열린 뒤에 끝나게 한다)
private actor AppLatch {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var arrivals = 0
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

/// 가짜 서버 (앱 테스트용 최소판): 응답을 값으로 정한다
private final class AppStubGateway: ChatGateway, @unchecked Sendable {
    /// 있으면 잊기 요청이 이 문이 열릴 때까지 서버에서 기다린다
    var forgetGate: AppLatch?
    var conversationRows: [ChatConversation] = []
    var memoryRows: [MemoryItem] = []
    var sources: [UUID: MemorySource] = [:]
    var calls = Box<[String]>([])
    private func record(_ call: String) { calls.value += [call] }

    func conversations() async throws -> [ChatConversation] { record("conversations"); return conversationRows }
    func lastMessages(conversationIDs: [UUID]) async throws -> [UUID: ChatMessage] { [:] }
    func messages(conversationID: UUID) async throws -> [ChatMessage] { [] }
    func message(id: UUID) async throws -> ChatMessage? { nil }
    func workContexts() async throws -> [WorkContext] { [WorkContext(id: AppFixtures.contextID, name: "Shape launch")] }
    func currentMemoryItems() async throws -> [MemoryItem] { memoryRows.filter(\.isCurrent) }
    func memoryItems(ids: [UUID]) async throws -> [MemoryItem] { memoryRows.filter { ids.contains($0.id) } }
    func memorySource(id: UUID) async throws -> MemorySource? { sources[id] }
    func createConversation(id: UUID, title: String?, contextID: UUID?) async throws -> ChatConversation {
        record("create"); return ChatConversation(id: id, title: title, contextID: contextID, createdAt: Date())
    }
    func updateConversation(id: UUID, contextID: UUID?) async throws -> ChatConversation { throw URLError(.badURL) }
    func postChatMessage(conversationID: UUID, clientMessageID: UUID, text: String) async throws -> ChatPostedMessage { record("post"); throw URLError(.timedOut) }
    func confirmMemory(id: UUID, expectedVersion: Int) async throws -> MemoryItem { throw URLError(.badURL) }
    func editMemory(id: UUID, edit: MemoryEdit) async throws -> MemoryItem { throw URLError(.badURL) }
    func forgetMemory(id: UUID, expectedVersion: Int) async throws -> MemoryItem {
        if let forgetGate { await forgetGate.wait() }
        throw URLError(.badURL)
    }
    func moveMemory(id: UUID, expectedVersion: Int, to target: MemoryTarget) async throws -> MemoryItem { throw URLError(.badURL) }
}


/// 앱 테스트용 계정: 실제 `SessionStore` + 앱 시작 때처럼 먼저 붙은 `AccountScope` (같은 UUID 재로그인 포함)
@MainActor
struct AppChatAccount {
    static let userID = UUID(uuidString: "00000000-0000-4000-8000-0000000000aa")!
    let session: SessionStore
    let scope: AccountScope
    let signedIn: Session

    final class Storage: AuthLocalStorage, @unchecked Sendable {
        private let data: Data
        init(_ session: Session) throws { data = try JSONEncoder().encode(session) }
        func store(key: String, value: Data) throws {}
        func retrieve(key: String) throws -> Data? { data }
        func remove(key: String) throws {}
    }

    static func make() throws -> AppChatAccount {
        let user = User(id: userID, appMetadata: [:], userMetadata: [:], aud: "authenticated", email: "me@example.com", createdAt: Date(), updatedAt: Date())
        let signedIn = Session(accessToken: "a", tokenType: "bearer", expiresIn: 3600, expiresAt: Date().addingTimeInterval(3600).timeIntervalSince1970, refreshToken: "r", user: user)
        let auth = AuthClient(url: URL(string: "https://example.supabase.co/auth/v1")!, localStorage: try Storage(signedIn), autoRefreshToken: false)
        let session = SessionStore(auth: auth)
        let scope = AccountScope()
        scope.bind(to: session)
        session.apply(event: .signedIn, session: signedIn)
        return AppChatAccount(session: session, scope: scope, signedIn: signedIn)
    }

    func relogin() {
        session.apply(event: .signedOut, session: nil)
        session.apply(event: .signedIn, session: signedIn)
    }
}

private enum AppFixtures {
    static let contextID = UUID(uuidString: "09d60000-0000-4000-8000-000000000001")!
    static let sourceID = UUID(uuidString: "b1c10000-0000-4000-8000-000000000001")!
    static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "c1a90000-0000-4000-8000-%012d", n))! }

    static func memory(
        _ n: Int, _ statement: String, origin: MemoryOrigin = .explicit, scope: MemoryScopeKind = .global, context: UUID? = nil, sourceRef: MemorySourceRef? = nil
    ) -> MemoryItem {
        MemoryItem(id: id(n), scopeKind: scope, contextID: context, statement: statement, origin: origin, sourceRef: sourceRef, observedAt: Date(timeIntervalSince1970: 1_791_709_200))
    }

    static func source(accessLost: Bool = false) -> MemorySource {
        let json = """
        {"id":"\(sourceID.uuidString.lowercased())","kind":"doc","title":"Launch brief","occurred_at":"2026-10-10T01:00:00Z","external_url":"https://www.notion.so/launch",
         "created_at":"2026-10-10T01:00:00Z","processing_status":"done","meeting":null,"access_lost_at":\(accessLost ? "\"2026-10-10T03:00:00Z\"" : "null"),
         "raw_text_purged_at":null,"raw_text_purge_reason":null}
        """
        return try! TaskforceJSON.decoder().decode(MemorySource.self, from: Data(json.utf8))
    }
}

private final class Box<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value
    init(_ value: Value) { _value = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}

/// Chats(⌘3) · New chat(⌘N) · Esc · 대화 저장소 연결 (B3 PR2). 0.2.0 Edge 셸이 켜진 격리 Debug 실행에서만 쓰인다
@MainActor
struct EdgeChatTests {
    // MARK: 키 · 셸

    @Test func panelKeysIncludeNewChatOnlyWithCommand() {
        #expect(EdgeKeyCommand.of(keyCode: kVK_ANSI_N, flags: .command) == .newChat)
        #expect(EdgeKeyCommand.of(keyCode: kVK_ANSI_3, flags: .command) == .chats)
        #expect(EdgeKeyCommand.of(keyCode: kVK_ANSI_2, flags: .command) == .allWork)
        #expect(EdgeKeyCommand.of(keyCode: kVK_Escape, flags: []) == .escape)
        // 수식키가 없거나 더 붙으면 지나간다 (글자 입력 · 다른 앱 단축키를 먹지 않는다)
        #expect(EdgeKeyCommand.of(keyCode: kVK_ANSI_N, flags: []) == nil)
        #expect(EdgeKeyCommand.of(keyCode: kVK_ANSI_N, flags: [.command, .shift]) == nil)
        #expect(EdgeKeyCommand.of(keyCode: kVK_ANSI_N, flags: [.command, .option]) == nil)
        #expect(EdgeKeyCommand.of(keyCode: kVK_Return, flags: .command) == nil)
    }

    @Test func openingChatsOrStartingANewChatTellsTheChatStore() {
        let shell = EdgeShellModel()
        var events: [String] = []
        shell.onChatsOpened = { events.append("opened") }
        shell.onNewChat = { events.append("new") }
        shell.openChats()
        #expect(shell.panelOpen && shell.view == .chats && events == ["opened"])
        // ⌘N: 패널을 Chats로 열고 새 대화
        shell.openAllWork()
        events = []
        shell.newChat()
        #expect(shell.view == .chats && events == ["opened", "new"])
        // ⌥ Space로 접었다 다시 열면 마지막 화면(Chats)으로 돌아와 마지막 대화를 되살린다
        shell.dismiss()
        events = []
        shell.togglePanel()
        #expect(shell.view == .chats && events == ["opened"])
        // All work는 대화 저장소를 건드리지 않는다
        events = []
        shell.openAllWork()
        #expect(events.isEmpty)
    }

    @Test func escapeLeavesTheChatHistoryBeforeCollapsingThePanel() {
        let shell = EdgeShellModel()
        var inner = true
        shell.onChatEscape = { defer { inner = false }; return inner }
        shell.openChats()
        shell.escape()
        #expect(shell.panelOpen, "안쪽(대화 목록)을 먼저 닫는다")
        shell.escape()
        #expect(!shell.panelOpen)
        // All work에서는 대화 저장소를 묻지 않는다
        inner = true
        shell.openAllWork()
        shell.escape()
        #expect(!shell.panelOpen && inner)
    }

    @Test func panelHeightIncludesTheComposerAtTheFoot() {
        // 머리 40 + 본문 + 입력칸. DS `panel-min-height` 320 아래로는 줄지 않는다 (F-2: 옛 값은 120)
        #expect(EdgePanelMetrics.minHeight == 320)
        #expect(EdgePanelMetrics.height(body: 300) == 340)
        #expect(EdgePanelMetrics.height(body: 300, footer: 54) == 394)
        #expect(EdgePanelMetrics.height(body: 100, footer: 54) == EdgePanelMetrics.minHeight, "짧은 본문은 최소 높이")
        #expect(EdgePanelMetrics.height(body: 2_000, footer: 54) == EdgePanelMetrics.maxHeight)
    }

    // MARK: 대화 저장소 연결

    private func runtime(_ gateway: AppStubGateway = AppStubGateway()) throws -> (runtime: ChatRuntime, account: AppChatAccount) {
        let account = try AppChatAccount.make()
        let runtime = ChatRuntime(gateway: gateway, scope: account.scope, now: { Date() })
        return (runtime, account)
    }

    /// 앱 시작 때 세션에 붙은 저장소는 패널 · 설정 창이 없어도 계정이 떠나면 초안 · 대기 전송 · 기억을 비운다
    @Test func theRuntimeClearsPrivateStateWhenTheAccountLeavesWithoutAnyViews() async throws {
        let gateway = AppStubGateway()
        gateway.memoryRows = [AppFixtures.memory(1, "Keeps pricing-page FAQs short")]
        let (runtime, account) = try runtime(gateway)
        await runtime.memory.loadList()
        let id = runtime.chat.newChat()
        runtime.chat.setDraft("private draft", for: id)
        await runtime.chat.send("will fail")
        #expect(runtime.memory.items.count == 1 && runtime.chat.turns(for: id).count == 1)
        account.relogin()
        #expect(runtime.memory.items.isEmpty && runtime.chat.entries.isEmpty && runtime.chat.draft(for: id) == "")
        #expect(runtime.chat.turns(for: id).isEmpty && runtime.chat.currentID == nil)
    }

    @Test func settingsDetailClosesWhenTheAccountLeaves() throws {
        let model = SettingsWindowModel()
        let (runtime, account) = try runtime()
        model.bind(to: runtime)
        let memoryID = AppFixtures.id(1)
        model.open(.memory(memoryID))
        #expect(model.detail(on: .account) == .memory(memoryID))
        account.relogin()
        #expect(model.detail == nil, "다른 세션에 옛 기억 상세가 남지 않는다")
    }

    // MARK: Settings › Account › Remembered

    @Test func rememberedDetailsAreOnTheAccountTabWithTheDesignBackNames() {
        #expect(SettingsWindowDetail.remembered.tab == .account && SettingsWindowDetail.memory(UUID()).tab == .account)
        #expect(SettingsWindowDetail.remembered.title == "Remembered" && SettingsWindowDetail.memory(UUID()).title == "Remembered")
        #expect(SettingsWindowDetail.remembered.backTitle(tab: .account) == "Account")
        #expect(SettingsWindowDetail.memory(UUID()).backTitle(tab: .account) == "Remembered")
        #expect(SettingsWindowDetail.privacy.backTitle(tab: .connections) == "Connections")
    }

    @Test func backFromAMemoryGoesToTheListNotTheTab() {
        let model = SettingsWindowModel()
        model.open(.memory(UUID()))
        model.back()
        #expect(model.detail == .remembered)
        model.back()
        #expect(model.detail == nil)
    }

    @Test func rememberedRowIsOnlyForSignedInAccounts() {
        #expect(SettingsWindowTab.account.sections(.signedIn).contains(.remembered))
        #expect(!SettingsWindowTab.account.sections(.signedOut).contains(.remembered))
        #expect(!SettingsWindowTab.account.sections(.loading).contains(.remembered))
        #expect(SettingsWindowSection.remembered.title == nil, "제목 없는 트레이가 앞 주제에 이어진다")
    }

    @Test func rememberedListScreensAreDistinct() {
        #expect(SettingsRememberedList.screen(load: .idle, isEmpty: true) == .blank)
        #expect(SettingsRememberedList.screen(load: .loading, isEmpty: true) == .blank)
        #expect(SettingsRememberedList.screen(load: .offline, isEmpty: true) == .offline)
        #expect(SettingsRememberedList.screen(load: .failed, isEmpty: true) == .failed)
        #expect(SettingsRememberedList.screen(load: .unavailable, isEmpty: true) == .unavailable, "서버에 아직 없는 기능은 실패도 비어 있음도 아니다")
        #expect(SettingsRememberedList.screen(load: .loaded, isEmpty: true) == .empty)
        #expect(SettingsRememberedList.screen(load: .loaded, isEmpty: false) == .list)
        // 받은 행이 있으면 그 뒤의 읽기 실패가 목록을 가리지 않는다
        #expect(SettingsRememberedList.screen(load: .failed, isEmpty: false) == .list)
    }

    /// 상세는 서버가 정한 사실만: 추정은 Confirm과 각주, explicit은 범위 popup, 출처 접근 상실이면 Confirm이 없다
    /// 잊기가 끝난 뒤 창은 요청을 시작한 세션 · 화면일 때만 바뀐다 (Codex f9c5362: 옛 세션의 완료가 새 세션의 상세를 뒤로 보내지 않는다)
    @Test func forgetFollowUpOnlyTouchesTheWindowThatStartedIt() {
        let followUp = SettingsMemoryDetail.forgetFollowUp
        // 같은 세션 · 같은 화면: 잊었으면 목록으로, 그 밖에는 제자리 확인만 닫는다 (동작은 전과 같다)
        #expect(followUp(.forgotten, true, true, true) == .back)
        for other in [MemoryWriteResult.refreshed, .unavailable, .failed, .ignored] {
            #expect(followUp(other, true, true, true) == .clearConfirmation)
        }
        // 세션이 바뀌었으면(저장소는 `.ignored`, 옛 코드는 `.forgotten`도) 새 세션의 화면 · 확인을 건드리지 않는다
        for result in [MemoryWriteResult.forgotten, .ignored, .refreshed, .unavailable, .failed] {
            #expect(followUp(result, false, true, true) == .leaveAlone, "\(result)")
        }
        // 같은 세션이어도 그 사이 다른 상세로 옮겼으면 뒤로 보내지 않고, 다른 확인을 열었으면 닫지 않는다
        #expect(followUp(.forgotten, true, false, true) == .leaveAlone)
        #expect(followUp(.refreshed, true, true, false) == .leaveAlone)
    }

    /// 실제 창 모델과 저장소로: 옛 세션의 잊기가 늦게 끝나도 새 세션이 연 상세 · 확인은 그대로다
    @Test func anOldSessionsForgetDoesNotMoveTheNewSessionsDetail() async throws {
        let gateway = AppStubGateway()
        let forgotten = AppFixtures.memory(1, "Keeps pricing-page FAQs short")
        gateway.memoryRows = [forgotten]
        let model = SettingsWindowModel()
        let (runtime, account) = try runtime(gateway)
        model.bind(to: runtime)
        await runtime.memory.loadList()
        model.open(.memory(forgotten.id))
        model.confirming = .forgetMemory(forgotten.id)
        let started = runtime.scope.token
        let gate = AppLatch()
        gateway.forgetGate = gate
        let forgetting = Task { await runtime.memory.forget(forgotten.id) }
        while await gate.arrivals == 0 { await Task.yield() }
        // 요청이 서버에서 기다리는 동안 같은 사용자가 다시 로그인해 다른 상세 · 확인을 연다
        account.relogin()
        let other = AppFixtures.id(2)
        model.open(.memory(other))
        model.confirming = .forgetMemory(other)
        await gate.open()
        let result = await forgetting.value
        let follow = SettingsMemoryDetail.forgetFollowUp(
            result, sessionIsCurrent: started.map(runtime.scope.isCurrent) ?? false,
            stillShowing: model.detail == .memory(forgotten.id), stillConfirming: model.confirming == .forgetMemory(forgotten.id)
        )
        #expect(result == .ignored && follow == .leaveAlone)
        #expect(model.detail == .memory(other) && model.confirming == .forgetMemory(other))
    }

    @Test func detailContentFollowsTheStoreNotAGuess() async throws {
        let gateway = AppStubGateway()
        let ref = MemorySourceRef(sourceID: AppFixtures.sourceID, quote: "Thursday")
        let inferred = AppFixtures.memory(1, "Jordan decides partner dates", origin: .inferred, scope: .context, context: AppFixtures.contextID, sourceRef: ref)
        let explicit = AppFixtures.memory(2, "Keeps FAQs short")
        gateway.memoryRows = [inferred, explicit]
        gateway.sources[AppFixtures.sourceID] = AppFixtures.source()
        let (runtime, account) = try runtime(gateway)
        defer { withExtendedLifetime(account) {} }
        await runtime.memory.loadList()
        await runtime.memory.loadSource(for: inferred)
        let tentative = SettingsMemoryDetail.content(for: inferred, memory: runtime.memory)
        #expect(tentative.isTentative && tentative.canConfirm && tentative.kind == "Inferred · Unconfirmed")
        #expect(tentative.isInferred && RememberedDetail.footnote(for: tentative) != nil)
        #expect(tentative.scopeChoices.isEmpty, "추정의 범위는 바꿀 수 없다 (읽기 전용 Value)")
        #expect(tentative.scopeName == "Shape launch")
        guard case .quote(let quote) = tentative.source else {
            Issue.record("출처 인용이 아님")
            return
        }
        #expect(quote.text == "Thursday" && quote.service == .notion)
        let plain = SettingsMemoryDetail.content(for: explicit, memory: runtime.memory)
        #expect(!plain.canConfirm && !plain.isTentative && plain.scopeChoices.map(\.name) == ["All work", "Shape launch"])
        #expect(plain.selectedScope == .global && plain.source == .hidden)
        #expect(!plain.isInferred && RememberedDetail.footnote(for: plain) == nil)
        // 원문이 지워진 observed(지금 기억): 흐린 글은 그대로, 추정 각주는 없다
        let purged = MemoryItem(id: AppFixtures.id(3), statement: "", origin: .observed, observedAt: Date(timeIntervalSince1970: 1_791_709_200), sourcePurged: true, version: 2)
        gateway.memoryRows.append(purged)
        await runtime.memory.loadList()
        let purgedContent = SettingsMemoryDetail.content(for: purged, memory: runtime.memory)
        #expect(purgedContent.isTentative && !purgedContent.isInferred && purgedContent.isCurrent)
        #expect(RememberedDetail.footnote(for: purgedContent) == nil && purgedContent.statement == "Original text deleted")
        // 접근을 잃은 출처: Confirm이 없고 원문을 열 수 없다고 말한다
        gateway.sources[AppFixtures.sourceID] = AppFixtures.source(accessLost: true)
        await runtime.memory.loadSource(for: inferred)
        let lost = SettingsMemoryDetail.content(for: inferred, memory: runtime.memory)
        #expect(!lost.canConfirm && lost.source == .unavailable("Can't open the original"))
    }

    /// 화면에 쓰지 않는 말 · 자산 (S3 방식을 앱 쪽 새 파일까지, 글은 대부분 `ChatCopy` · `MemoryCopy` 상수라 그쪽은 `nothingInTheCopyIsBanned`가 본다): "All caught up" · "Nothing here" · Claude/Anthropic · 색 점 · SF Symbol 아이콘
    @Test func appSourcesAvoidBannedCopyAndAssets() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Taskforce/Mac")
        let files = ["Edge/EdgeChat.swift", "SettingsWindow/SettingsRememberedSections.swift"]
        let literal = try NSRegularExpression(pattern: #""(?:[^"\\\n]|\\.)*""#)
        for file in files {
            let source = try String(contentsOf: root.appending(path: file), encoding: .utf8)
            let code = source.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            let literals = literal.matches(in: code, range: NSRange(code.startIndex..., in: code)).compactMap { Range($0.range, in: code).map { String(code[$0]) } }
            for text in literals {
                for banned in ["caught up", "nothing here", "claude", "anthropic", "●", "•", "✨"] {
                    #expect(!text.localizedCaseInsensitiveContains(banned), "\(file): \(text)")
                }
            }
            #expect(!code.contains("Image(systemName:") && !code.contains("systemImage:"), "\(file)")
        }
    }
}

@Suite("Retired launcher entrypoints")
struct RetiredLauncherEntrypointTests {
    @Test func appEntrypointsNeverConstructTheLegacyPanel() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Taskforce/Mac")
        let source = try String(contentsOf: root.appending(path: "MacAppDelegate.swift"), encoding: .utf8)
        #expect(!source.contains("LauncherPanelController("))
        #expect(!source.contains("Button(\"Open Launcher\")"))
        #expect(!source.contains("launcher.show()"))
        #expect(source.contains("Button(\"Open Taskforce\")"))
        #expect(source.contains("edge.shell.open(itemID: id)"))
        #expect(source.contains("SettingsOpener.open(.account)"))
        #expect(!source.contains("EdgeTaskFlow"))
    }
}
