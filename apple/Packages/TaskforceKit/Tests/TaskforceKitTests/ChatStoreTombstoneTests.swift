import Foundation
import Testing
@testable import TaskforceKit

/// 서버가 없다 · 보관했다고 확인한 대화(`confirmGone`)는 어느 순서로 응답이 늦게 와도 오류 화면(`.failed`, Try again)에 머문다 (OA U2 · 재검토 반영 3).
/// 같은 원인(확인보다 먼저 시작한 읽기의 늦은 응답이 대화를 되살린다)의 순서를 한 표로 고정한다:
/// - 순서: `refreshFirst` = 새로 읽기가 행을 먼저 반영하고(미리보기 · 글 읽기에서 기다린다) 먼저 시작해 둔 직접 읽기가 나중에 "없다"를 확인한다.
///   `directFirst` = 직접 읽기가 먼저 "없다"를 확인하고, 붙잡혀 있던 새로 읽기의 옛 행 응답이 나중에 도착한다
/// - 행이 오는 길: `chats`(목록) · `extras`(패널 대화를 id로 읽은 행)
/// - 확인: 지웠다(nil) · 보관했다
/// - 늦게 도착하는 것: `row`(행 · 미리보기) · `body`(글) · `emptyBody`(빈 글)
/// 확인 뒤에 시작한 사용자의 Try again은 새 세대라 정상으로 읽는다
struct TombstoneCase: Sendable, CustomTestStringConvertible {
    enum Order: String, CaseIterable, Sendable { case refreshFirst, directFirst }
    enum Via: String, CaseIterable, Sendable { case chats, extras }
    enum Kind: String, CaseIterable, Sendable { case deleted, archived }
    enum Late: String, CaseIterable, Sendable { case row, body, emptyBody }

    let order: Order
    let via: Via
    let kind: Kind
    let late: Late

    var testDescription: String { "\(order.rawValue) · \(via.rawValue) · \(kind.rawValue) · \(late.rawValue)" }

    static let all: [TombstoneCase] = Order.allCases.flatMap { order in
        Via.allCases.flatMap { via in
            Kind.allCases.flatMap { kind in
                Late.allCases.map { late in TombstoneCase(order: order, via: via, kind: kind, late: late) }
            }
        }
    }
}

@MainActor
struct ChatStoreTombstoneTests {
    let gateway = FakeChatGateway()
    let assistant = FakeAssistantGateway()
    let scope = ChatTestAccount.fixedScope()
    let connection = UUID(uuidString: "c0c00000-0000-4000-8000-000000000001")!

    /// 호출 순서를 세는 작은 도구 (붙잡힌 호출과 그다음 호출을 가른다)
    private final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func next() -> Int { lock.withLock { count += 1; return count } }
    }

    func store() -> ChatStore {
        let chat = ChatStore(gateway: gateway, scope: scope, now: { .test(500) })
        chat.assistant = assistant
        return chat
    }

    func agentRow(_ n: Int, last: TimeInterval? = 10, archived: Bool = false, title: String? = nil, contextID: UUID? = nil) -> ChatConversation {
        ChatConversation(
            id: ChatContractFixtures.id(n, prefix: "bcb50000"), title: title, contextID: contextID, createdAt: .test(0), lastMessageAt: last.map { .test($0) }, archivedAt: archived ? .test(1) : nil,
            target: ChatConversationTarget(kind: .agent, agentConnectionID: connection, agentSessionID: ChatContractFixtures.id(n, prefix: "5e550000"))
        )
    }

    func message(_ n: Int, in id: UUID, _ text: String) -> ChatMessage {
        Chats.message(n, in: id, seq: n, role: .assistant, text: text, at: Double(n))
    }

    // MARK: 표

    @Test(arguments: TombstoneCase.all)
    func aConfirmedGoneConversationStaysTheErrorScreenWhateverArrivesLate(_ c: TombstoneCase) async {
        let listed = agentRow(1, last: 100)
        let old = agentRow(2, last: 1)
        let confirmation: ChatConversation? = c.kind == .archived ? agentRow(2, last: 1, archived: true) : nil
        let body: [ChatMessage] = c.late == .emptyBody ? [] : [message(7, in: old.id, "late body")]
        let stalePreview = message(8, in: old.id, "stale preview")
        let chat = store()
        chat.panelConversations = { [old.id] }
        let rowLatch = Latch()      // 새로 읽기의 응답(행 · 미리보기 · 글)을 붙잡는다
        let directLatch = Latch()   // refreshFirst: 직접 읽기의 응답을 붙잡는다
        let calls = CallCounter()
        let oldID = old.id
        gateway.lastMessagesHandler = { _ in [:] }

        switch c.order {
        case .directFirst:
            // 새로 읽기의 옛 행 응답이 붙잡혀 있다 (chats: 목록 응답, extras: id로 읽은 행). 직접 읽기는 바로 "없다"를 확인한다
            gateway.conversationsHandler = { [via = c.via] in
                if via == .chats {
                    await rowLatch.wait()
                    return [listed, old]
                }
                return [listed]
            }
            gateway.conversationHandler = { [via = c.via] _ in
                if via == .extras, calls.next() == 1 {
                    await rowLatch.wait()
                    return old
                }
                return confirmation
            }
            // 늦게 오는 것이 글이면 글 응답도 붙잡는다 (옛 구조에서는 늦은 행이 글 읽기를 시작시키고 그 응답이 화면을 되살렸다)
            let bodyLatch = Latch()
            let holdsBody = c.late != .row
            gateway.messagesHandler = { id in
                guard id == oldID else { return [] }
                if holdsBody { await bodyLatch.wait() }
                return body
            }
            let refresh = Task { await chat.refresh() }
            #expect(await rowLatch.waitForArrivals(1, timeout: .seconds(5)), "새로 읽기의 응답이 붙잡혀 있다")
            await chat.readConversation(old.id)
            #expect(chat.screen(for: old.id) == .failed, "직접 읽기가 먼저 없다고 확인했다")
            await rowLatch.open()
            if holdsBody {
                // 새 구조는 묘비 때문에 글 읽기 자체를 시작하지 않는다: 도착이 없어도 짧게 기다린 뒤 풀어 준다
                _ = await bodyLatch.waitForArrivals(1, timeout: .milliseconds(120))
                await bodyLatch.open()
            }
            await refresh.value
            await chat.settle()

        case .refreshFirst:
            // 직접 읽기가 행을 모르는 채 먼저 나가 응답을 기다린다. 새로 읽기가 행을 먼저 반영하고 (row: 미리보기, body: 글 읽기)에서 기다린다
            gateway.conversationsHandler = { [via = c.via] in via == .chats ? [listed, old] : [listed] }
            gateway.conversationHandler = { _ in
                if calls.next() == 1 {
                    await directLatch.wait()
                    return confirmation
                }
                return old
            }
            switch c.late {
            case .row:
                gateway.lastMessagesHandler = { _ in
                    await rowLatch.wait()
                    return [oldID: stalePreview]
                }
                gateway.messagesHandler = { id in id == oldID ? body : [] }
            case .body, .emptyBody:
                gateway.messagesHandler = { id in
                    guard id == oldID else { return [] }
                    await rowLatch.wait()
                    return body
                }
            }
            let direct = Task { await chat.readConversation(old.id) }
            #expect(await directLatch.waitForArrivals(1, timeout: .seconds(5)), "직접 읽기가 응답을 기다린다")
            let refresh = Task { await chat.refresh() }
            #expect(await rowLatch.waitForArrivals(1, timeout: .seconds(5)), "새로 읽기가 행을 반영하고 기다린다")
            #expect(chat.isTargetKnown(old.id), "새로 읽기가 행을 먼저 반영했다")
            await directLatch.open()
            await direct.value
            #expect(chat.screen(for: old.id) == .failed && !chat.isTargetKnown(old.id), "직접 읽기가 나중에 없다고 확인해 행을 지웠다")
            await rowLatch.open()
            await refresh.value
            await chat.settle()
        }

        #expect(chat.screen(for: old.id) == .failed, "오류 화면 + Try again이 그대로다")
        #expect(chat.turns(for: old.id).isEmpty && !chat.isTargetKnown(old.id) && !chat.canCompose(in: old.id), "본문 · 행 · 대상 · 보내기 모두 없다 (Composer가 열리지 않는다)")

        // 확인 뒤 사용자의 Try again: 새 세대라 정상으로 읽는다
        gateway.conversationHandler = { _ in old }
        gateway.messagesHandler = { id in id == oldID ? [Chats.message(9, in: oldID, seq: 9, role: .assistant, text: "back", at: 9)] : [] }
        gateway.lastMessagesHandler = { _ in [:] }
        await chat.readConversation(old.id)
        #expect(chat.screen(for: old.id) == .ready(problem: nil) && chat.isTargetKnown(old.id), "Try again은 다시 읽는다")
        #expect(chat.turns(for: old.id).map(\.text) == ["back"])
        #expect(chat.entries.first { $0.id == old.id }?.preview != .message("stale preview"), "옛 미리보기가 되살아나지 않는다")
    }

    // MARK: 서버 버전 순서 · 늦은 부정 응답 (6차 재검토)

    /// 1. 새로 읽기의 id 읽기 응답(없다 · 보관)이 붙잡혀 있는 사이 직접 읽기가 없다고 확인했고, 사용자의 Try again이 행 · 글을 복구했다.
    /// 그 뒤에 도착한 옛 부정 응답은 현재 세대보다 먼저 시작한 읽기라 복구를 지우지 못한다
    private func lateNegativeAfterRecovery(archived: Bool) async {
        let listed = agentRow(1, last: 100)
        let old = agentRow(2, last: 1)
        let confirmation: ChatConversation? = archived ? agentRow(2, last: 1, archived: true) : nil
        let chat = store()
        chat.panelConversations = { [old.id] }
        let oldID = old.id
        let latch = Latch()
        let calls = CallCounter()
        gateway.conversationsHandler = { [listed] }
        gateway.conversationHandler = { _ in
            switch calls.next() {
            case 1:             // 새로 읽기의 id 읽기: 붙잡힌 옛 부정 응답
                await latch.wait()
                return confirmation
            case 2:             // 직접 읽기: 없다고 확인
                return confirmation
            default:            // Try again: 이제 있다
                return old
            }
        }
        gateway.messagesHandler = { id in id == oldID ? [Chats.message(9, in: oldID, seq: 9, role: .assistant, text: "back", at: 9)] : [] }
        gateway.lastMessagesHandler = { _ in [:] }
        let refresh = Task { await chat.refresh() }
        #expect(await latch.waitForArrivals(1, timeout: .seconds(5)), "새로 읽기의 id 읽기 응답이 붙잡혀 있다")
        await chat.readConversation(oldID)
        #expect(chat.screen(for: oldID) == .failed, "직접 읽기가 없다고 확인했다")
        await chat.readConversation(oldID)
        #expect(chat.screen(for: oldID) == .ready(problem: nil) && chat.isTargetKnown(oldID) && chat.turns(for: oldID).map(\.text) == ["back"], "Try again이 복구했다")
        await latch.open()
        await refresh.value
        await chat.settle()
        #expect(chat.screen(for: oldID) == .ready(problem: nil), "늦은 옛 부정 응답이 복구를 지우지 않는다")
        #expect(chat.isTargetKnown(oldID) && chat.canCompose(in: oldID) && chat.turns(for: oldID).map(\.text) == ["back"])
    }

    @Test func aLateDeletedResponseDoesNotWipeATryAgainRecovery() async {
        await lateNegativeAfterRecovery(archived: false)
    }

    @Test func aLateArchivedResponseDoesNotWipeATryAgainRecovery() async {
        await lateNegativeAfterRecovery(archived: true)
    }

    /// 1'. 확인 **뒤에** 시작했지만 복구보다 먼저 시작한 부정 응답도 복구를 지우지 못한다: 복구가 새 세대를 시작하기 때문이다
    /// (`viaRefresh`: 늦은 부정 응답이 새로 읽기의 id 읽기 응답인가, 아니면 두 번째 직접 읽기의 응답인가. `recoveredByRefresh`: 복구가 새로 읽기인가, 사용자의 Try again인가)
    private func lateNegativeStartedBetweenConfirmationAndRecovery(viaRefresh: Bool, recoveredByRefresh: Bool) async {
        let listed = agentRow(1, last: 100)
        let old = agentRow(2, last: 1)
        let chat = store()
        chat.panelConversations = { [old.id] }
        let oldID = old.id
        let latch = Latch()
        let calls = CallCounter()
        gateway.conversationsHandler = { [listed] }
        gateway.conversationHandler = { _ in
            switch calls.next() {
            case 1:             // 직접 읽기: 없다고 확인 (묘비)
                return nil
            case 2:             // 확인 뒤에 시작한 읽기: 부정 응답이 붙잡힌다
                await latch.wait()
                return nil
            default:            // Try again: 이제 있다
                return old
            }
        }
        gateway.messagesHandler = { id in id == oldID ? [Chats.message(9, in: oldID, seq: 9, role: .assistant, text: "back", at: 9)] : [] }
        gateway.lastMessagesHandler = { _ in [:] }
        await chat.readConversation(oldID)
        #expect(chat.screen(for: oldID) == .failed, "직접 읽기가 없다고 확인했다 (묘비)")
        let late = Task { viaRefresh ? await chat.refresh() : await chat.readConversation(oldID) }
        #expect(await latch.waitForArrivals(1, timeout: .seconds(5)), "확인 뒤에 시작한 읽기의 부정 응답이 붙잡혀 있다")
        if recoveredByRefresh {
            await chat.refresh()                // 확인 뒤에 시작한 새로 읽기가 행을 다시 읽어 복구한다
        } else {
            await chat.readConversation(oldID)  // Try again: 복구
        }
        #expect(chat.screen(for: oldID) == .ready(problem: nil) && chat.isTargetKnown(oldID), "복구했다")
        await latch.open()
        await late.value
        await chat.settle()
        #expect(chat.screen(for: oldID) == .ready(problem: nil) && chat.isTargetKnown(oldID) && chat.canCompose(in: oldID), "복구 전에 시작한 부정 응답이 복구를 지우지 않는다")
        #expect(chat.turns(for: oldID).map(\.text) == ["back"])
    }

    @Test(arguments: [true, false], [true, false])
    func aNegativeResponseStartedBeforeTheRecoveryDoesNotWipeIt(viaRefresh: Bool, recoveredByRefresh: Bool) async {
        await lateNegativeStartedBetweenConfirmationAndRecovery(viaRefresh: viaRefresh, recoveredByRefresh: recoveredByRefresh)
    }

    /// 2. 행을 모르는 직접 읽기 D가 기다리는 사이 새로 읽기 R0이 행을 확보했고, R1이 시작했다(그때 행을 안다). D가 없다고 확인하고 Try again이 복구한 뒤
    /// R1의 옛 활성 행이 도착한다: 옛 행은 버리고, 복구한 현재 행은 R1의 목록 교체에서도 남는다 (본문만 남고 대상이 없는 Composer 대기가 되지 않는다)
    @Test func aRecoveredRowSurvivesTheListReplacementOfARefreshThatStartedBeforeTheConfirmation() async {
        let listed = agentRow(1, last: 100)
        let oldRow = agentRow(2, last: 1, title: "old title")
        let freshRow = agentRow(2, last: 5, title: "fresh title")
        let chat = store()
        chat.panelConversations = { [oldRow.id] }
        let oldID = oldRow.id
        let dLatch = Latch()
        let r1Latch = Latch()
        let rowCalls = CallCounter()
        let listCalls = CallCounter()
        gateway.conversationHandler = { _ in
            if rowCalls.next() == 1 {   // 행을 모르는 직접 읽기: 붙잡힌 부정 응답
                await dLatch.wait()
                return nil
            }
            return freshRow             // Try again: 있다
        }
        gateway.conversationsHandler = {
            if listCalls.next() == 1 { return [listed, oldRow] }   // R0: 행을 확보한다
            await r1Latch.wait()                                    // R1: 붙잡힌 옛 응답
            return [listed, oldRow]
        }
        gateway.messagesHandler = { id in id == oldID ? [Chats.message(9, in: oldID, seq: 9, role: .assistant, text: "back", at: 9)] : [] }
        gateway.lastMessagesHandler = { _ in [:] }
        let direct = Task { await chat.readConversation(oldID) }
        #expect(await dLatch.waitForArrivals(1, timeout: .seconds(5)), "직접 읽기가 응답을 기다린다 (행을 모른다)")
        await chat.refresh()    // R0
        #expect(chat.isTargetKnown(oldID), "R0이 행을 확보했다")
        let r1 = Task { await chat.refresh() }
        #expect(await r1Latch.waitForArrivals(1, timeout: .seconds(5)), "R1이 시작해 기다린다 (그때 행을 안다)")
        await dLatch.open()
        await direct.value
        #expect(chat.screen(for: oldID) == .failed && !chat.isTargetKnown(oldID), "직접 읽기가 없다고 확인했다")
        await chat.readConversation(oldID)     // Try again
        #expect(chat.isTargetKnown(oldID) && chat.screen(for: oldID) == .ready(problem: nil), "Try again이 복구했다")
        await r1Latch.open()
        await r1.value
        await chat.settle()
        #expect(chat.isTargetKnown(oldID) && chat.canCompose(in: oldID), "복구한 행이 R1의 목록 교체에서 사라지지 않는다 (Composer가 대상 없이 기다리지 않는다)")
        #expect(chat.screen(for: oldID) == .ready(problem: nil) && chat.turns(for: oldID).map(\.text) == ["back"])
        #expect(chat.entries.first { $0.id == oldID }?.title == "fresh title", "옛 행(옛 이름)이 복구한 행을 덮지 않는다")
    }

    /// 3. 직접 읽기가 `last_message_at`이 없는 옛 행 응답을 기다리는 사이 첫 메시지가 저장되고 새로 읽기가 최신 행 · 글을 반영했다.
    /// 늦게 온 옛 행이 최신 행을 덮으면 메시지가 있는 대화가 "빈 대화"로 보여 재사용 대상이 된다: 서버 버전이 더 새로운 행을 쥐고 있으면 그것을 둔다
    @Test func aLateDirectReadRowWithoutAnyMessageDoesNotOverwriteANewerRow() async {
        let listed = agentRow(1, last: 100)
        let emptyRow = agentRow(2, last: nil)
        let newer = agentRow(2, last: 50)
        let chat = store()
        chat.panelConversations = { [emptyRow.id] }
        let oldID = emptyRow.id
        let latch = Latch()
        gateway.conversationHandler = { _ in
            await latch.wait()
            return emptyRow     // 옛 응답: 메시지가 없던 때의 행
        }
        gateway.conversationsHandler = { [listed, newer] }
        gateway.messagesHandler = { id in id == oldID ? [Chats.message(9, in: oldID, seq: 9, role: .assistant, text: "first message", at: 9)] : [] }
        gateway.lastMessagesHandler = { _ in [:] }
        let direct = Task { await chat.readConversation(oldID) }
        #expect(await latch.waitForArrivals(1, timeout: .seconds(5)), "직접 읽기가 옛 응답을 기다린다")
        await chat.refresh()
        #expect(chat.conversations.first { $0.id == oldID }?.lastMessageAt == .test(50), "새로 읽기가 최신 행을 반영했다")
        await latch.open()
        await direct.value
        await chat.settle()
        #expect(chat.conversations.first { $0.id == oldID }?.lastMessageAt == .test(50), "늦은 옛 행이 최신 행의 시각을 되돌리지 않는다")
        #expect(chat.conversations.first { $0.id == oldID }?.isUntouched == false, "메시지가 있는 대화가 빈 대화로 보이지 않는다")
        #expect(chat.screen(for: oldID) == .ready(problem: nil) && chat.turns(for: oldID).map(\.text) == ["first message"])
    }

    /// 겹친 읽기의 역전 방어: 쥔 행을 반영하기 **전에** 시작한 읽기의 응답이 서버 버전이 더 낮으면 쥔 행을 둔다 (목록 교체 · id로 읽은 행 모두)
    private func overlappingOlderResponse(viaList: Bool) async {
        let listed = agentRow(1, last: 100)
        let held = agentRow(2, last: 50, title: "held")
        let older = agentRow(2, last: 10, title: "older")
        let chat = store()
        let id = held.id
        chat.panelConversations = { [id] }
        let latch = Latch()
        let calls = CallCounter()
        gateway.conversationsHandler = {
            if viaList {
                await latch.wait()          // 먼저 시작한 새로 읽기의 목록 응답이 붙잡힌다 (옛 행)
                return [listed, older]
            }
            return [listed]
        }
        gateway.conversationHandler = { _ in
            if !viaList, calls.next() == 1 {
                await latch.wait()          // 먼저 시작한 새로 읽기의 id 읽기 응답이 붙잡힌다 (옛 행)
                return older
            }
            return held                     // 그사이 시작한 직접 읽기: 최신 행
        }
        gateway.messagesHandler = { _ in [] }
        gateway.lastMessagesHandler = { _ in [:] }
        let refresh = Task { await chat.refresh() }
        #expect(await latch.waitForArrivals(1, timeout: .seconds(5)), "먼저 시작한 읽기의 응답이 붙잡혀 있다")
        await chat.readConversation(id)
        #expect(chat.conversations.first { $0.id == id }?.title == "held", "직접 읽기가 최신 행을 반영했다")
        await latch.open()
        await refresh.value
        await chat.settle()
        #expect(chat.conversations.first { $0.id == id }?.title == "held" && chat.conversations.first { $0.id == id }?.lastMessageAt == .test(50), "겹친 옛 응답(버전이 낮다)이 쥔 행을 덮지 않는다")
    }

    @Test func anOverlappingOlderListResponseDoesNotOverwriteTheHeldRow() async {
        await overlappingOlderResponse(viaList: true)
    }

    @Test func anOverlappingOlderByIDResponseDoesNotOverwriteTheHeldRow() async {
        await overlappingOlderResponse(viaList: false)
    }

    /// 서버 시각은 뒤로 갈 수 있다 (`db_now()`는 트랜잭션 시작 시각이고 Stop이 메시지 잠금을 기다리는 사이 새 POST가 커밋될 수 있다):
    /// 앱이 `last_message_at`=t20 행을 쥔 뒤 서버가 `{t10, 새 프로젝트}`를 돌려준다. 쥔 행을 반영한 **뒤에** 시작한 읽기는 늘 이겨 수렴한다 (되풀이해도)
    private func freshReadAfterBackwardsTimestamp(viaList: Bool) async {
        let listed = agentRow(1, last: 100)
        let projectA = ChatContractFixtures.id(41, prefix: "c0170000")
        let projectB = ChatContractFixtures.id(42, prefix: "c0170000")
        let held = agentRow(2, last: 20, title: "held", contextID: projectA)
        let backwards = agentRow(2, last: 10, title: "held", contextID: projectB)
        let chat = store()
        let id = held.id
        gateway.conversationHandler = { _ in held }
        gateway.conversationsHandler = { [listed] }
        gateway.messagesHandler = { _ in [] }
        gateway.lastMessagesHandler = { _ in [:] }
        await chat.readConversation(id)
        #expect(chat.conversations.first { $0.id == id }?.lastMessageAt == .test(20) && chat.conversations.first { $0.id == id }?.contextID == projectA)
        // 서버: 시각이 t10으로 되돌아가고 다른 기기가 프로젝트를 바꿨다
        if viaList {
            gateway.conversationsHandler = { [listed, backwards] }
        } else {
            chat.panelConversations = { [id] }
            gateway.conversationHandler = { _ in backwards }
        }
        for _ in 0..<2 {
            await chat.refresh()
            let row = chat.conversations.first { $0.id == id }
            #expect(row?.contextID == projectB && row?.lastMessageAt == .test(10), "새 읽기가 서버의 행으로 수렴한다 (시각이 뒤로 갔어도 영원히 거절하지 않는다)")
        }
    }

    @Test func aFreshListReadConvergesEvenWhenTheServerTimestampWentBackwards() async {
        await freshReadAfterBackwardsTimestamp(viaList: true)
    }

    @Test func aFreshByIDReadConvergesEvenWhenTheServerTimestampWentBackwards() async {
        await freshReadAfterBackwardsTimestamp(viaList: false)
    }

    // MARK: 확인 뒤 Try again이 읽은 것은 옛 응답이 덮지 않는다

    /// 새로 읽기의 옛 행 응답(옛 이름)이 붙잡혀 있는 사이 직접 읽기가 "없다"를 확인하고, 사용자의 Try again이 새 행(새 이름)을 읽어 열었다.
    /// 그 뒤에 도착한 옛 응답은 묘비가 그대로라 버려진다 (Try again은 묘비를 걷는 것이 아니라 새 세대로 시작한다)
    @Test func anOldResponseStaysDroppedAfterTheTryAgainHasLoaded() async {
        let listed = agentRow(1, last: 100)
        let oldRow = agentRow(2, last: 1, title: "stale title")
        let freshRow = agentRow(2, last: 1, title: "fresh title")
        let chat = store()
        chat.panelConversations = { [oldRow.id] }
        let oldID = oldRow.id
        let latch = Latch()
        gateway.conversationsHandler = {
            await latch.wait()
            return [listed, oldRow]
        }
        let calls = CallCounter()
        gateway.conversationHandler = { _ in calls.next() == 1 ? nil : freshRow }
        gateway.messagesHandler = { id in id == oldID ? [Chats.message(9, in: oldID, seq: 9, role: .assistant, text: "fresh body", at: 9)] : [] }
        gateway.lastMessagesHandler = { _ in [:] }
        let refresh = Task { await chat.refresh() }
        #expect(await latch.waitForArrivals(1, timeout: .seconds(5)))
        await chat.readConversation(oldID)
        #expect(chat.screen(for: oldID) == .failed, "먼저 없다고 확인했다")
        await chat.readConversation(oldID)
        #expect(chat.screen(for: oldID) == .ready(problem: nil) && chat.turns(for: oldID).map(\.text) == ["fresh body"], "Try again이 새 행 · 글을 읽었다")
        #expect(chat.entries.first { $0.id == oldID }?.title == "fresh title")
        await latch.open()
        await refresh.value
        await chat.settle()
        #expect(chat.entries.first { $0.id == oldID }?.title == "fresh title", "늦은 옛 행(옛 이름)이 새로 읽은 행을 덮지 않는다")
        #expect(chat.screen(for: oldID) == .ready(problem: nil) && chat.turns(for: oldID).map(\.text) == ["fresh body"])
        #expect(chat.conversations.filter { $0.id == oldID }.count == 1)
    }
}
