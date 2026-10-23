import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Taskforce
@testable import TaskforceKit
@testable import TaskforceUI

/// 저장된 Claude 데스크톱 대화의 Mac 쪽 (OA D3v-m, 계약 27장 · DZ `oa-desktop-chat-view-dz`): Sessions의 Saved chats 절 · 읽기 전용 패널 · 하나 지우기 · 게이트.
/// 서버 · Supabase · 이 Mac의 Claude 기록에 닿지 않는다: 읽기 · 지우기는 모두 가짜 닫힘이고 계정은 견본 계정이다
@MainActor
struct SavedChatsMacTests {
    typealias X = EdgeExternalSessionsTests

    nonisolated static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "cccccccc-0000-4000-8000-%012x", n))! }

    nonisolated static func row(_ n: Int, title: String? = nil, device: String? = "Daniel's MacBook Air", minutesAgo: Double = 12) -> SavedChatRow {
        SavedChatRow(id: id(n), title: title ?? "Chat \(n)", lastMessageAt: Date().addingTimeInterval(-minutesAgo * 60), deviceName: device)
    }

    nonisolated static func message(_ n: Int, role: String = "user", body: String = "hi", tools: [String] = [], at: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> SavedChatMessageRecord {
        SavedChatMessageRecord(
            id: UUID(uuidString: String(format: "dddddddd-0000-4000-8000-%012x", n))!, role: role, body: body, truncated: false, toolNames: tools,
            saidAt: at.addingTimeInterval(Double(n) * 60), seq: Int64(n)
        )
    }

    /// 지우기를 붙잡는 문
    actor Gate {
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            opened = true
            waiters.forEach { $0.resume() }
            waiters = []
        }
    }

    /// 가짜 서버 한 면: 읽기 쪽 · 지우기를 세고 돌려줄 값을 시험이 정한다
    final class Backend: @unchecked Sendable {
        private let lock = NSLock()
        private var _pages: [[SavedChatRow]]
        private var _calls = 0
        private var _messageReads = 0
        private var _messages: [UUID: [SavedChatMessageRecord]] = [:]
        private var _messageError: (any Error)?
        private var _deleted: [UUID] = []
        private var _deleteError: (any Error)?
        private var _deleteAllCalls = 0
        private var _deleteAllError: (any Error)?
        var deleteGate: Gate?
        /// 목록 읽기를 붙잡는다 (읽는 중 · 견본) · 목록 읽기를 실패시킨다
        var pageGate: Gate?
        private var _pageError: (any Error)?

        init(pages: [[SavedChatRow]]) { _pages = pages }

        func failPages(_ error: (any Error)?) { lock.withLock { _pageError = error } }

        /// 말 읽기를 붙잡는다 (읽는 중 견본)
        var messageGate: Gate?

        func readMessagesAsync(_ chat: UUID, _ offset: Int, _ limit: Int) async throws -> [SavedChatMessageRecord] {
            if let gate = lock.withLock({ messageGate }) { await gate.wait() }
            return try readMessages(chat, offset, limit)
        }

        func pageAsync(_ offset: Int, _ limit: Int) async throws -> [SavedChatRow] {
            let (gate, error) = lock.withLock { (pageGate, _pageError) }
            if let gate { await gate.wait() }
            if let error { throw error }
            return page(offset, limit)
        }

        var calls: Int { lock.withLock { _calls } }
        /// 말 읽기를 부른 횟수 (보기가 다시 읽었는지)
        var messageReads: Int { lock.withLock { _messageReads } }
        var deleted: [UUID] { lock.withLock { _deleted } }
        var deleteAllCalls: Int { lock.withLock { _deleteAllCalls } }
        func setPages(_ pages: [[SavedChatRow]]) { lock.withLock { _pages = pages } }
        func setMessages(_ messages: [SavedChatMessageRecord], for chat: UUID) { lock.withLock { _messages[chat] = messages } }
        func failMessages(_ error: (any Error)?) { lock.withLock { _messageError = error } }
        func failDelete(_ error: (any Error)?) { lock.withLock { _deleteError = error } }
        func failDeleteAll(_ error: (any Error)?) { lock.withLock { _deleteAllError = error } }

        func page(_ offset: Int, _ limit: Int) -> [SavedChatRow] {
            lock.withLock {
                _calls += 1
                return _pages.isEmpty ? [] : _pages[min(_calls - 1, _pages.count - 1)]
            }
        }

        func readMessages(_ chat: UUID, _ offset: Int, _ limit: Int) throws -> [SavedChatMessageRecord] {
            try lock.withLock {
                _messageReads += 1
                if let _messageError { throw _messageError }
                let newestFirst = Array((_messages[chat] ?? []).reversed())
                guard offset < newestFirst.count else { return [] }
                return Array(newestFirst[offset..<min(offset + limit, newestFirst.count)])
            }
        }

        func delete(_ id: UUID) async throws {
            let (gate, error) = lock.withLock { () -> (Gate?, (any Error)?) in
                _deleted.append(id)
                return (deleteGate, _deleteError)
            }
            if let gate { await gate.wait() }
            if let error { throw error }
        }

        func deleteAll() throws {
            try lock.withLock {
                _deleteAllCalls += 1
                if let _deleteAllError { throw _deleteAllError }
            }
        }
    }

    static func store(_ backend: Backend, scope: AccountScope, pageSize: Int = 20) -> SavedChatsStore {
        SavedChatsStore(
            scope: scope, readPage: { try await backend.pageAsync($0, $1) }, readMessages: { try await backend.readMessagesAsync($0, $1, $2) }, deleteChat: { try await backend.delete($0) },
            deleteAll: { try backend.deleteAll() }, pageSize: pageSize
        )
    }

    struct Rig {
        let base: X.Rig
        let store: SavedChatsStore
        let backend: Backend
        var shell: EdgeShellModel { base.shell }
    }

    /// 목록 게이트가 켜진 셸 + 저장된 대화가 읽혀 있는 저장소. Sessions는 열지 않았다
    func rig(rows: [SavedChatRow] = (1...5).map { row($0) }, gated: Bool = true, hasList: Bool = true, signedIn: Bool = true) async -> Rig {
        let scope = AccountScope(currentAccount: { SampleData.userID })
        let backend = Backend(pages: [rows])
        let store = Self.store(backend, scope: scope)
        let base = X().make(gated: gated, store: hasList, signedIn: signedIn, scope: scope, savedChats: store)
        await store.refresh()
        return Rig(base: base, store: store, backend: backend)
    }

    /// 열린 보기의 읽기가 끝나기를 기다린다
    private func opened(_ r: Rig, _ n: Int, confirmDelete: Bool = false) async -> SavedChatDetailModel? {
        r.backend.setMessages([Self.message(1, role: "user", body: "first"), Self.message(2, role: "assistant", body: "second", tools: ["Read"])], for: Self.id(n))
        r.shell.openSessions()
        r.shell.openSavedChat(Self.id(n), confirmDelete: confirmDelete)
        guard let detail = r.shell.savedChatDetail else { return nil }
        _ = await X().until { detail.phase != .loading }
        return detail
    }

    // MARK: 게이트: 목록과 같다 · 중계 게이트와 상관없다

    @Test func theSavedChatsStoreFollowsTheSameGateAsTheMacList() async {
        let on = await rig()
        #expect(on.shell.savedChats != nil && on.shell.savedChatsVisible)
        #expect(await rig(gated: false).shell.savedChats == nil, "새 Issues 화면이 꺼진 셸은 저장소를 들지 않는다")
        #expect(await rig(hasList: false).shell.savedChats == nil, "목록(BridgeFlag)이 없으면 저장된 대화도 없다")
        let signedOut = await rig(signedIn: false)
        #expect(signedOut.shell.savedChats != nil && !signedOut.shell.savedChatsVisible, "로그인하지 않았으면 보이지 않는다")
    }

    @Test func readOnlyViewingDoesNotNeedTheRelayGate() async {
        let r = await rig()
        #expect(r.shell.desktopChat == nil, "중계(입력창)가 없는 빌드다")
        let detail = await opened(r, 2)
        #expect(detail != nil && r.shell.savedChatPanelShown, "읽기 전용 보기는 중계 게이트와 상관없이 열린다")
    }

    @Test func theRuntimeMakesNothingWithoutServicesOrTheFlagOrTheIssueScreens() {
        let scope = AccountScope(currentAccount: { SampleData.userID })
        #expect(SavedChatsRuntime.make(services: nil, scope: scope, issueScreens: true, bridgeEnabled: true) == nil, "서비스(로그인 연결)가 없다")
        #expect(SavedChatsRuntime.make(services: nil, scope: nil, issueScreens: true, bridgeEnabled: true) == nil)
        #expect(SavedChatsRuntime.make(services: nil, scope: scope, issueScreens: false, bridgeEnabled: true) == nil)
        #expect(SavedChatsRuntime.make(services: nil, scope: scope, issueScreens: true, bridgeEnabled: false) == nil)
    }

    // MARK: Sessions 패널의 절

    private func sections() -> (SessionsSection<SessionsTaskforceRow>, SessionsSection<SessionsMacRow>) {
        (
            SessionsPanelRules.taskforce([], issueNumber: { _ in nil }, now: Date(), expanded: false),
            SessionsPanelRules.onThisMac([], live: { _ in nil }, now: Date(), expanded: false)
        )
    }

    @Test func noSessionsOnlyWhenEverySectionIncludingSavedChatsIsReadAndEmpty() {
        let (taskforce, mac) = sections()
        func plan(_ saved: SavedChatsStore.SectionState) -> SessionsPanelBody.Plan {
            SessionsPanelBody.plan(taskforce: taskforce, mac: mac, phase: .empty, taskforceRead: true, saved: saved)
        }
        #expect(plan(.absent).noSessions, "세션도 저장된 대화도 없다")
        for saved in [SavedChatsStore.SectionState.rows, .checking, .failed] {
            let p = plan(saved)
            #expect(!p.noSessions && p.saved == saved, "저장된 대화 절이 보이면 \"No sessions\"가 아니다: \(saved)")
        }
        #expect(SessionsPanelBody.plan(taskforce: taskforce, mac: mac, phase: .empty, taskforceRead: true).saved == .absent, "저장소가 없는 셸은 절이 없다")
    }

    @Test func aReadThatCameBackEmptyBecauseTheServerGateIsOffHasNoSectionAndNoEmptyState() async {
        let r = await rig(rows: [])
        #expect(r.store.phase == .ready && r.store.rows.isEmpty)
        let state = r.store.section(expanded: false).state
        #expect(state == .absent, "gate가 꺼져 읽기가 비면 절이 그냥 없다")
        let (taskforce, mac) = sections()
        let plan = SessionsPanelBody.plan(taskforce: taskforce, mac: mac, phase: .empty, taskforceRead: true, saved: state)
        #expect(plan.noSessions && plan.saved == .absent, "세션도 없으면 패널은 \"No sessions\" 하나")
        // 다른 절이 있어도 Saved chats의 빈 상태 글은 없다
        let withRows = SessionsPanelBody.plan(taskforce: taskforce, mac: mac, phase: .empty, taskforceRead: false, saved: state)
        #expect(!withRows.noSessions && withRows.saved == .absent)
    }

    @Test func openingTheSessionsPanelReadsTheSavedChatsEachTime() async {
        let r = await rig()
        let before = r.backend.calls
        r.shell.openSessions()
        #expect(await X().until { r.backend.calls == before + 1 })
        r.shell.dismiss()
        r.shell.openSessions()
        #expect(await X().until { r.backend.calls == before + 2 }, "열 때마다 처음 쪽부터 다시 읽는다")
        r.shell.openAllWork()
        let after = r.backend.calls
        try? await Task.sleep(for: .milliseconds(50))
        #expect(r.backend.calls == after, "Sessions가 아니면 읽지 않는다")
    }

    @Test func showAllStartsFoldedEachTimeSessionsOpensAndSaysThreeRowsFirst() async {
        let r = await rig(rows: (1...8).map { Self.row($0) })
        r.shell.openSessions()
        #expect(!r.shell.savedChatsExpanded)
        #expect(r.store.section(expanded: r.shell.savedChatsExpanded).fold.visible.count == 3, "처음엔 셋")
        r.shell.savedChatsExpanded = true
        #expect(r.store.section(expanded: r.shell.savedChatsExpanded).fold.visible.count == 8, "Show all이면 읽어 둔 것 모두")
        r.shell.dismiss()
        r.shell.openSessions()
        #expect(!r.shell.savedChatsExpanded, "다시 열면 접힌 채로 시작한다")
    }

    // MARK: 읽기 패널 열기 · 닫기

    @Test func aRowOpensTheReadOnlyPanelLeftOfSessionsAndTheSameRowClosesIt() async {
        let r = await rig()
        let detail = await opened(r, 2)
        #expect(r.shell.savedChatPanelID == Self.id(2) && r.shell.savedChatPanelShown && detail?.chat.id == Self.id(2))
        #expect(detail?.phase == .ready && detail?.messages.map(\.body) == ["first", "second"])
        r.shell.openSavedChat(Self.id(2))
        #expect(r.shell.savedChatPanelID == nil && !r.shell.savedChatPanelShown && r.shell.savedChatDetail == nil, "같은 줄을 다시 누르면 닫는다")
        r.shell.openSavedChat(Self.id(3))
        r.shell.openSavedChat(Self.id(4))
        #expect(r.shell.savedChatPanelID == Self.id(4), "다른 줄은 그 대화로 바뀐다")
    }

    @Test func theLeftPanelIsOneAtATimeSavedChatDesktopSessionAndTaskforceSession() async {
        let desktop = await EdgeSessionsTests().rig(
            sessions: .basic, rows: [1], live: [EdgeSessionsTests.live(1, .busy)], savedChats: Self.store(Backend(pages: [(1...3).map { Self.row($0) }]), scope: AccountScope(currentAccount: { SampleData.userID }))
        )
        let shell = desktop.shell
        await shell.savedChats?.refresh()
        shell.openSessions()
        shell.openSavedChat(Self.id(1))
        #expect(shell.savedChatPanelID == Self.id(1))
        shell.openDesktopSession(EdgeSessionsTests.id(1), from: .list)
        #expect(shell.desktopPanelID == EdgeSessionsTests.id(1) && shell.savedChatPanelID == nil, "데스크톱 세션 보기가 열리면 저장된 대화는 닫힌다")
        shell.openSavedChat(Self.id(1))
        #expect(shell.savedChatPanelID == Self.id(1) && shell.desktopPanelID == nil, "저장된 대화가 열리면 데스크톱 세션 보기는 닫힌다")
        let taskforceRow = shell.issues?.sessions.items.first?.id
        if let taskforceRow {
            shell.openSessionRow(taskforceRow)
            #expect(shell.sessionPanelID == taskforceRow && shell.savedChatPanelID == nil, "Taskforce 세션 패널이 열리면 저장된 대화는 닫힌다")
            shell.openSavedChat(Self.id(2))
            #expect(shell.savedChatPanelID == Self.id(2) && shell.sessionPanelID == nil)
        } else {
            Issue.record("견본 Taskforce 세션이 없다")
        }
    }

    @Test func openingOutsideSessionsOrAnUnknownChatDoesNothing() async {
        let r = await rig()
        r.shell.openSavedChat(Self.id(1))
        #expect(r.shell.savedChatPanelID == nil, "패널이 닫혀 있으면 열리지 않는다")
        r.shell.openSessions()
        r.shell.openSavedChat(Self.id(99))
        #expect(r.shell.savedChatPanelID == nil, "목록에 없는 대화는 열지 않는다")
        r.shell.openAllWork()
        r.shell.openSavedChat(Self.id(1))
        #expect(r.shell.savedChatPanelID == nil, "Sessions가 아닌 화면에서는 열리지 않는다")
        let off = await rig(hasList: false)
        off.shell.openSessions()
        off.shell.openSavedChat(Self.id(1))
        #expect(off.shell.savedChatPanelID == nil && off.shell.savedChatDetail == nil, "저장소가 없는 셸은 연결이 없다")
    }

    @Test func leavingSessionsOrChangingTheAccountClosesItAndDismissKeepsItForTheNextOpen() async {
        let r = await rig()
        _ = await opened(r, 2)
        r.shell.dismiss()
        #expect(r.shell.savedChatPanelID == Self.id(2) && !r.shell.savedChatPanelShown, "접어도 남아 ⌥ Space로 다시 열면 마지막 화면이다")
        r.shell.openSessions()
        #expect(r.shell.savedChatPanelShown)
        r.shell.openAllWork()
        #expect(r.shell.savedChatPanelID == nil && r.shell.savedChatDetail == nil, "다른 화면으로 가면 닫는다")
        _ = await opened(r, 3)
        r.shell.accountChanged(nil)
        #expect(r.shell.savedChatPanelID == nil && r.shell.savedChatDetail == nil, "계정이 바뀌면 비운다")
    }

    @Test func aChatDeletedElsewhereClosesThePanelAndRefreshesTheList() async {
        let r = await rig()
        r.backend.setMessages([], for: Self.id(2))
        // 지금부터 서버 목록에는 그 대화가 없다 (다른 기기에서 지웠다)
        r.backend.setPages([(1...5).filter { $0 != 2 }.map { Self.row($0) }])
        r.shell.openSessions()
        r.shell.openSavedChat(Self.id(2))
        #expect(await X().until { r.shell.savedChatPanelID == nil }, "다른 기기에서 이미 지운 대화를 열어 둔 경우도 패널이 닫힌다")
        #expect(await X().until { !r.store.rows.contains { $0.id == Self.id(2) } }, "줄도 목록에서 빠진다")
    }

    // MARK: 지운 대화가 메모리에서 되살아나지 않는다 (재검토 P1)

    @Test func deleteAllWhileSessionsIsCollapsedDoesNotBringTheOpenChatBackWhenSessionsOpensAgain() async {
        // 대화를 연 채 Settings로 가면(Sessions가 접힌다) 열어 둔 id와 보기가 남는다: 모두 지운 뒤 다시 열면 옛 글이 메모리에서 보였다
        let r = await rig()
        let detail = await opened(r, 2)
        #expect(detail?.messages.count == 2)
        r.shell.dismiss()
        #expect(r.shell.savedChatPanelID == Self.id(2), "접어도 열어 둔 대화는 남는다 (지우기 전에는)")
        await r.store.deleteAllChats()
        #expect(r.store.rows.isEmpty)
        #expect(r.shell.savedChatPanelID == nil && r.shell.savedChatDetail == nil, "모두 지우기가 성공하면 열어 둔 대화는 닫힌다: 접혀 있는 동안에도")
        r.backend.setPages([[]])
        r.shell.openSessions()
        #expect(r.shell.savedChatPanelID == nil && r.shell.savedChatDetail == nil && !r.shell.savedChatPanelShown, "다시 열어도 지운 대화는 없다")
    }

    @Test func deleteAllWhileThePanelIsStillShownClosesIt() async {
        let r = await rig()
        _ = await opened(r, 2)
        #expect(r.shell.savedChatPanelShown)
        await r.store.deleteAllChats()
        #expect(r.shell.savedChatPanelID == nil && !r.shell.savedChatPanelShown && r.shell.savedChatDetail == nil)
    }

    @Test func aChatDeletedOnAnotherDeviceWhileSessionsWasCollapsedIsGoneOnceTheListIsReadAgain() async {
        let r = await rig()
        _ = await opened(r, 2)
        r.shell.dismiss()
        r.backend.setPages([(1...5).filter { $0 != 2 }.map { Self.row($0) }])
        r.backend.setMessages([], for: Self.id(2))
        r.shell.openSessions()
        #expect(await X().until { r.shell.savedChatPanelID == nil && r.shell.savedChatDetail == nil }, "다시 읽은 목록에 없는 대화는 열어 둔 채로 두지 않는다")
        #expect(!r.store.rows.contains { $0.id == Self.id(2) })
    }

    @Test func aChatBeyondTheFirstPageIsNotClosedJustBecauseTheFreshFirstPageDoesNotHoldIt() async {
        // 목록이 더 있으면(가득 찬 쪽) 다시 읽은 첫 쪽에 없다고 지워진 것은 아니다: 그 대화 스스로 읽어 본다
        let r = await rig(rows: (1...20).map { Self.row($0) })
        r.backend.setPages([(1...20).map { Self.row($0) }, (21...40).map { Self.row($0) }, (1...20).map { Self.row($0) }])
        await r.store.loadMore()
        #expect(r.store.rows.count == 40)
        let detail = await opened(r, 30)
        #expect(detail?.phase == .ready)
        r.shell.dismiss()
        r.shell.openSessions()
        #expect(await X().until { r.store.rows.count == 20 }, "다시 열면 처음 쪽만 읽는다")
        #expect(await X().until { detail?.phase == .ready && detail?.messages.count == 2 })
        #expect(r.shell.savedChatPanelID == Self.id(30) && r.shell.savedChatPanelShown, "첫 쪽에 없어도 그 대화는 아직 있다 (더 읽을 쪽이 있다)")
    }

    @Test func aChatBeyondTheFirstPageDeletedElsewhereClosesThroughItsOwnReload() async {
        let r = await rig(rows: (1...20).map { Self.row($0) })
        r.backend.setPages([(1...20).map { Self.row($0) }, (21...40).map { Self.row($0) }, (1...20).map { Self.row($0) }])
        await r.store.loadMore()
        _ = await opened(r, 30)
        r.shell.dismiss()
        r.backend.setMessages([], for: Self.id(30))
        r.shell.openSessions()
        #expect(await X().until { r.shell.savedChatPanelID == nil }, "더 읽을 쪽이 있어 목록으로는 모르지만, 보기가 다시 읽으면 말이 없어 지운 대화로 드러난다")
    }

    @Test func showingThePanelAgainReloadsTheOpenChatAndNeverShowsTheOldTextMeanwhile() async {
        let r = await rig()
        let detail = await opened(r, 2)
        #expect(detail?.messages.map(\.body) == ["first", "second"])
        r.shell.dismiss()
        r.backend.setMessages([Self.message(1, role: "user", body: "first"), Self.message(2, role: "assistant", body: "second"), Self.message(3, role: "assistant", body: "third")], for: Self.id(2))
        let gate = Gate()
        r.backend.messageGate = gate
        r.shell.openSessions()
        #expect(r.shell.savedChatDetail === detail)
        #expect(detail?.phase == .loading && detail?.messages.isEmpty == true, "다시 보이는 즉시 메모리의 옛 글을 비우고 읽는 중이다")
        await gate.open()
        #expect(await X().until { detail?.messages.count == 3 }, "다시 읽은 새 글이 보인다")
    }

    @Test func aPanelThatStaysShownIsNotReloadedAgain() async {
        let r = await rig()
        let detail = await opened(r, 2)
        let before = r.backend.messageReads
        r.shell.openSessions()
        r.shell.openSessions()
        for _ in 0..<20 { await Task.yield() }
        #expect(detail?.phase == .ready && r.backend.messageReads == before, "계속 보이는 패널은 다시 읽지 않는다 (보이게 될 때만)")
    }

    // MARK: 지우기: 오른쪽 클릭 → 읽기 패널 + 확인 카드 → 결과

    @Test func theContextMenuDeleteOpensTheChatAndAsksInPlaceWithoutDeleting() async {
        let r = await rig()
        let detail = await opened(r, 2, confirmDelete: true)
        #expect(r.shell.savedChatPanelID == Self.id(2) && detail?.deleteState == .confirming, "그 대화를 열어 확인 카드를 그 자리에 띄운다")
        for _ in 0..<20 { await Task.yield() }
        #expect(r.backend.deleted.isEmpty && detail?.deleteState == .confirming, "메뉴의 Delete는 바로 지우지 않는다 (시간이 지나도)")
        // 이미 열려 있는 대화의 메뉴 Delete는 닫지 않고 카드만 띄운다
        r.shell.openSavedChat(Self.id(3))
        r.shell.openSavedChat(Self.id(3), confirmDelete: true)
        #expect(r.shell.savedChatPanelID == Self.id(3) && r.shell.savedChatDetail?.deleteState == .confirming)
    }

    @Test func theHeaderDeleteAsksFirstAndTheCardDeletesNowThenClosesTheViewAndDropsTheRow() async {
        let r = await rig()
        let detail = try? #require(await opened(r, 2))
        detail?.requestDelete()
        #expect(detail?.deleteState == .confirming && r.backend.deleted.isEmpty, "머리의 Delete도 확인 카드가 먼저다")
        await detail?.confirmDelete()
        #expect(r.backend.deleted == [Self.id(2)], "확인하면 서버에 바로 보낸다 (되돌리기 시간 없음)")
        #expect(r.shell.savedChatPanelID == nil && r.shell.savedChatDetail == nil, "패널이 닫힌다")
        #expect(!r.store.rows.contains { $0.id == Self.id(2) } && r.store.rows.count == 4, "줄이 빠진다")
    }

    @Test func aFailedDeleteKeepsThePanelRowAndTheCardWithTheReason() async {
        let r = await rig()
        r.backend.failDelete(APIError.transport("offline"))
        let detail = try? #require(await opened(r, 2, confirmDelete: true))
        await detail?.confirmDelete()
        #expect(detail?.deleteState == .failed(.offline) && r.shell.savedChatPanelID == Self.id(2) && r.store.rows.count == 5)
        r.backend.failDelete(nil)
        await detail?.confirmDelete()
        #expect(r.shell.savedChatPanelID == nil && r.store.rows.count == 4, "Try again이 다시 보낸다")
    }

    @Test func escapeClosesTheCardThenThePanelThenSessionsAndIsIgnoredWhileDeleting() async {
        let r = await rig()
        _ = await opened(r, 2, confirmDelete: true)
        r.shell.escape()
        #expect(r.shell.savedChatDetail?.deleteState == DeleteStateNone.value && r.shell.savedChatPanelID == Self.id(2) && r.shell.panelOpen, "Esc는 카드를 먼저 닫는다")
        r.shell.escape()
        #expect(r.shell.savedChatPanelID == nil && r.shell.panelOpen && r.shell.view == .sessions, "다음 Esc는 읽기 패널만")
        r.shell.escape()
        #expect(!r.shell.panelOpen, "그다음 Esc가 Sessions를 접는다")

        // 지우는 중에는 Esc가 아무것도 되돌리지 않는다
        let gate = Gate()
        r.backend.deleteGate = gate
        let detail = await opened(r, 3, confirmDelete: true)
        let running = Task { await detail?.confirmDelete() }
        #expect(await X().until { detail?.deleteState == .deleting })
        r.shell.escape()
        #expect(r.shell.savedChatPanelID == Self.id(3) && detail?.deleteState == .deleting)
        await gate.open()
        await running.value
        #expect(r.shell.savedChatPanelID == nil)
    }

    @Test func dismissingThePanelWithTheCardUpAsksAgainNextTimeInsteadOfRemembering() async {
        let r = await rig()
        let detail = await opened(r, 2, confirmDelete: true)
        r.shell.dismiss()
        #expect(detail?.deleteState == DeleteStateNone.value, "접으면 확인 카드는 닫힌다 (다시 열 때 바로 지울 수 있는 카드가 남지 않는다)")
        #expect(r.backend.deleted.isEmpty)
    }

    /// `SavedChatDetailModel.DeleteState.none`을 값으로 (`Optional`의 `.none`과 헷갈리지 않게)
    enum DeleteStateNone {
        static let value: SavedChatDetailModel.DeleteState? = SavedChatDetailModel.DeleteState.none
    }

    // MARK: 패널의 모양 (순수한 계획)

    private func plan(_ detail: SavedChatDetailModel) -> SavedChatPanelPlan {
        SavedChatPanelPlan.make(detail: detail, now: Date(), timeZone: .current)
    }

    @Test func theHeaderIsTheTitleOneDeleteButtonAndDeviceThenDate() async {
        let r = await rig(rows: [Self.row(1, title: "Pricing copy draft", device: "Daniel's MacBook Air"), Self.row(2, title: "x", device: nil)])
        let detail = try? #require(await opened(r, 1))
        let p = detail.map(plan)
        #expect(p?.title == "Pricing copy draft" && p?.headerAction == "Delete", "머리 단추는 Delete 하나")
        #expect(p?.statusLine.hasPrefix("Daniel's MacBook Air · ") == true)
        #expect(p?.body == .messages && p?.footer == SavedChatPanelPlan.Footer.none, "입력창도 Open in Claude도 없다: 아래는 카드 아니면 빈 자리")
        let unnamed = try? #require(await opened(r, 2))
        #expect(unnamed.map(plan)?.statusLine.contains("·") == false, "이 Mac이거나 이름이 없으면 날짜만")
    }

    @Test func anUntitledChatIsCalledUntitled() async {
        let r = await rig(rows: [SavedChatRow(id: Self.id(1), title: nil, lastMessageAt: Date(), deviceName: nil)])
        let detail = try? #require(await opened(r, 1))
        #expect(detail.map(plan)?.title == "Untitled")
    }

    @Test func theBodyStatesAreCheckingFailedAndMessages() async {
        let r = await rig()
        r.shell.openSessions()
        r.backend.failMessages(URLError(.notConnectedToInternet))
        r.shell.openSavedChat(Self.id(1))
        let detail = try? #require(r.shell.savedChatDetail)
        #expect(detail.map(plan)?.body == .loading("Checking…") || detail?.phase == .failed, "읽는 중 \"Checking…\"")
        _ = await X().until { detail?.phase == .failed }
        #expect(detail.map(plan)?.body == .failed(title: "Couldn't load this chat", retry: "Try again"))
        r.backend.failMessages(nil)
        r.backend.setMessages([Self.message(1)], for: Self.id(1))
        detail?.retry()
        #expect(await X().until { detail?.phase == .ready })
        #expect(detail.map(plan)?.body == .messages)
    }

    @Test func theDeleteCardsSayExactlyTheApprovedWordsAndNeverOfferUndo() async {
        let r = await rig()
        let detail = try? #require(await opened(r, 2, confirmDelete: true))
        guard let detail else { return }
        let confirm = plan(detail).footer
        #expect(confirm == .card(.init(
            title: "Delete this chat?", detail: "Chat 2", meta: "Deletes the saved copy from all your devices", confirmLabel: "Delete", cancelLabel: "Cancel", busy: false
        )))
        // 지우는 중: 같은 카드가 바쁘다 (서버는 지우지 못하고 끝난다)
        let gate = Gate()
        r.backend.deleteGate = gate
        r.backend.failDelete(APIError.server(status: 500, code: .internalError, message: "x"))
        let running = Task { await detail.confirmDelete() }
        #expect(await X().until { detail.deleteState == .deleting })
        #expect(plan(detail).footer == .card(.init(
            title: "Delete this chat?", detail: "Chat 2", meta: "Deletes the saved copy from all your devices", confirmLabel: "Delete", cancelLabel: "Cancel", busy: true
        )))
        await gate.open()
        await running.value
        // 실패: 굵은 첫 말 + 승인된 이유 줄, 단추는 Try again · Cancel
        #expect(plan(detail).footer == .card(.init(
            title: "Couldn't delete", detail: "Something went wrong. Try again in a moment.", meta: nil, confirmLabel: "Try again", cancelLabel: "Cancel", busy: false
        )))
        for state in [confirm, plan(detail).footer] {
            if case .card(let card) = state {
                let words = [card.title, card.detail, card.meta, card.confirmLabel, card.cancelLabel].compactMap { $0 }.joined(separator: " ").lowercased()
                #expect(!words.contains("undo") && !words.contains("saved to your account") && !words.contains("saving"))
            }
        }
    }

    @Test func offlineFailureUsesTheOfflineReasonLine() async {
        let r = await rig()
        r.backend.failDelete(APIError.transport("x"))
        let detail = try? #require(await opened(r, 2, confirmDelete: true))
        await detail?.confirmDelete()
        if case .card(let card)? = detail.map(plan)?.footer { #expect(card.detail == "You're offline. Try again.") } else { Issue.record("실패 카드가 아니다") }
    }

    @Test func thePanelPlanHasNoComposerAndNoUndoCase() {
        // 계획의 아래 자리는 둘뿐이다: 비어 있거나 확인 · 실패 카드. 입력창 · Undo 갈래가 없다 (갈래를 더하면 이 시험이 깨진다)
        let none = SavedChatPanelPlan.Footer.none
        let card = SavedChatPanelPlan.Footer.card(.init(title: "", detail: nil, meta: nil, confirmLabel: "", cancelLabel: "", busy: false))
        for footer in [none, card] {
            switch footer {
            case .none, .card: break
            }
        }
        let words = SavedChatsCopy.approved + [SavedChatsCopy.delete]
        #expect(!words.joined().lowercased().contains("undo"))
    }
}
