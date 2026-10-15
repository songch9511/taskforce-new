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

    func agentRow(_ n: Int, last: TimeInterval = 10, archived: Bool = false, title: String? = nil) -> ChatConversation {
        ChatConversation(
            id: ChatContractFixtures.id(n, prefix: "bcb50000"), title: title, createdAt: .test(0), lastMessageAt: .test(last), archivedAt: archived ? .test(1) : nil,
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
            gateway.messagesHandler = { id in id == oldID ? body : [] }
            let refresh = Task { await chat.refresh() }
            #expect(await rowLatch.waitForArrivals(1, timeout: .seconds(5)), "새로 읽기의 응답이 붙잡혀 있다")
            await chat.readConversation(old.id)
            #expect(chat.screen(for: old.id) == .failed, "직접 읽기가 먼저 없다고 확인했다")
            await rowLatch.open()
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
