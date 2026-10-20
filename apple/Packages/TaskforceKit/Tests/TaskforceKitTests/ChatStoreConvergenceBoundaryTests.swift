import Foundation
import Testing
@testable import TaskforceKit

/// 응답을 비우는 동안 아직 서버에 도착하지 않은 쓰기가 실행될 수 있다.
/// 수렴의 기준은 쓰기를 모두 마친 서버다. Task.yield 횟수는 서버 도착 확인이 아니다.
@MainActor
struct ChatStoreConvergenceBoundaryTests {
    @MainActor private final class Server {
        let id = ChatContractFixtures.conversationID
        var lastMessageAt: TimeInterval = 306
        var messages: [ChatMessage] = []
        var row: ChatConversation {
            ChatConversation(id: id, title: nil, contextID: nil, createdAt: .test(0), lastMessageAt: .test(lastMessageAt), target: .taskforce)
        }

        init() {
            messages = [Chats.message(1, in: id, seq: 1, role: .assistant, text: "before queued POST", at: 306)]
        }

        func post(cmid: UUID, text: String) -> ChatPostedMessage {
            let user = Chats.message(2, in: id, seq: 2, role: .user, text: text, cmid: cmid, at: 4)
            let reply = Chats.message(3, in: id, seq: 3, role: .assistant, text: "after queued POST", replyTo: user.id, at: 4)
            messages += [user, reply]
            // 트랜잭션 시작 시각은 나중에 저장되어도 더 작을 수 있다 (기존 240시드와 같은 계약).
            lastMessageAt = 4
            return ChatPostedMessage(message: user, reply: reply)
        }
    }

    @Test func finalRefreshConvergesAfterAQueuedPostReachesTheServer() async {
        let server = Server()
        let gateway = FakeChatGateway()
        let chat = ChatStore(gateway: gateway, scope: ChatTestAccount.fixedScope())
        let id = server.id
        chat.panelConversations = { [id] }
        gateway.conversationsHandler = { await [server.row] }
        gateway.conversationHandler = { _ in await server.row }
        gateway.messagesHandler = { _ in await server.messages }
        gateway.lastMessagesHandler = { _ in await [id: server.messages.last!] }
        gateway.contextsHandler = { [] }
        await chat.refresh()

        let beforeServerWrite = Latch()
        gateway.postHandler = { _, cmid, text in
            await beforeServerWrite.wait()
            return await server.post(cmid: cmid, text: text)
        }
        let pending = Task { await chat.send("queued", in: id) }
        let arrived = await beforeServerWrite.waitForArrivals(1, timeout: .seconds(5))
        #expect(arrived)
        guard arrived else { await beforeServerWrite.open(); await pending.value; return }

        let beforeDrainRow = server.row
        let beforeDrainMessages = server.messages
        await beforeServerWrite.open()
        await pending.value
        #expect(server.row != beforeDrainRow)
        #expect(server.messages != beforeDrainMessages)
        let finalRow = server.row
        let finalMessages = server.messages

        await chat.refresh()
        await chat.settle()
        let held = chat.conversations.first { $0.id == id }
        // 실제 저장소는 최신 서버와 같다. 아래 최종 기준도 같은 시점이어야 한다.
        #expect(held == server.row)
        #expect(chat.turns(for: id).map(\.text) == server.messages.map(\.text))
        #expect(held?.lastMessageAt == finalRow.lastMessageAt)
        #expect(held == finalRow)
        #expect(chat.turns(for: id).map(\.text) == finalMessages.map(\.text))
    }
}
