#if os(macOS)
import Foundation
import Testing
@testable import TaskforceKit

private final class ChatFixtureConnection: CodexChatConnection, @unchecked Sendable {
    static let source = "11111111-1111-4111-8111-111111111111"
    static let owned = "22222222-2222-4222-8222-222222222222"
    enum Mode { case normal, rejected, disconnected, unsafePolicy }
    let mode: Mode
    private let condition = NSCondition()
    private var messages: [[String: Any]] = []
    private var queue: [Data] = []
    private var closed = false
    init(_ mode: Mode = .normal) { self.mode = mode }
    var written: [[String: Any]] { condition.lock(); defer { condition.unlock() }; return messages }
    func enqueue(_ message: [String: Any]) {
        condition.lock(); defer { condition.unlock() }
        queue.append(try! JSONSerialization.data(withJSONObject: message)); condition.broadcast()
    }
    func write(_ data: Data) throws {
        let message = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        condition.lock(); messages.append(message); condition.unlock()
        guard let method = message["method"] as? String, let id = message["id"] as? Int else { return }
        var result: [String: Any] = [:]
        switch method {
        case "thread/fork", "thread/resume":
            result = ["thread": ["id": Self.owned], "cwd": "/fixture", "approvalPolicy": "on-request", "approvalsReviewer": "user", "sandbox": ["type": mode == .unsafePolicy ? "dangerFullAccess" : "workspaceWrite"]]
        case "turn/start":
            if mode == .disconnected { close(); return }
            if mode == .rejected { enqueue(["id": id, "error": ["code": -1, "message": "fixture"]]); return }
            result = ["turn": ["id": "turn-\(id)"]]
        default: break
        }
        enqueue(["id": id, "result": result])
    }
    func read() throws -> Data {
        condition.lock(); defer { condition.unlock() }
        while queue.isEmpty && !closed { condition.wait() }
        guard !queue.isEmpty else { throw CodexChatSendError.unavailable }
        return queue.removeFirst()
    }
    func close() { condition.lock(); closed = true; condition.broadcast(); condition.unlock() }
}

private final class ChatFixtureConnections: @unchecked Sendable {
    private let lock = NSLock()
    private var connections: [ChatFixtureConnection]
    init(_ connections: [ChatFixtureConnection]) { self.connections = connections }
    func next() -> ChatFixtureConnection { lock.lock(); defer { lock.unlock() }; return connections.removeFirst() }
}

struct CodexChatSenderTests {
    let root = ChatFixtureConnection.source
    private func sender(_ fixture: ChatFixtureConnection, managed: String? = nil) -> CodexChatSender {
        CodexChatSender(factory: { fixture }, managedThreadID: managed, workingDirectory: { _ in "/fixture" })
    }
    @Test func forksOnceAndSendsExactTextOnlyToOwnedThread() async throws {
        let fixture = ChatFixtureConnection(); let sender = sender(fixture)
        let text = "한글 \"quoted\"\n$(never-shell)"
        let receipt = try await sender.send(threadID: root, text: text)
        #expect(receipt.threadID == ChatFixtureConnection.owned)
        let messages = fixture.written
        #expect(messages.compactMap { $0["method"] as? String } == ["initialize", "initialized", "thread/fork", "turn/start"])
        let fork = try #require(messages[2]["params"] as? [String: Any])
        #expect(fork["threadId"] as? String == root)
        #expect(fork["approvalPolicy"] as? String == "on-request")
        #expect(fork["sandbox"] as? String == "workspace-write")
        #expect(fork["approvalsReviewer"] as? String == "user")
        let params = try #require(messages[3]["params"] as? [String: Any])
        #expect(Set(params.keys) == ["threadId", "input"])
        #expect(params["threadId"] as? String == ChatFixtureConnection.owned)
        #expect((params["input"] as? [[String: Any]])?.first?["text"] as? String == text)
        await sender.stop()
    }
    @Test func resumesSavedOwnedThreadButNeverSource() async throws {
        let fixture = ChatFixtureConnection(); let sender = sender(fixture, managed: ChatFixtureConnection.owned)
        _ = try await sender.send(threadID: root, text: "test")
        #expect(fixture.written.contains { $0["method"] as? String == "thread/resume" })
        #expect(!fixture.written.contains { $0["method"] as? String == "thread/fork" })
        await sender.stop()
    }
    @Test func invalidIDAndBlankTextDoNotConnect() async {
        let sender = CodexChatSender(factory: { Issue.record("Must not connect"); throw CodexChatSendError.unavailable }, workingDirectory: { _ in "/fixture" })
        await #expect(throws: CodexChatSendError.sessionUnavailable) { try await sender.send(threadID: "../bad", text: "test") }
        await #expect(throws: CodexChatSendError.rejected) { try await sender.send(threadID: root, text: " \n") }
        await #expect(throws: CodexChatSendError.rejected) { try await sender.send(threadID: root, text: String(repeating: "x", count: 32_769)) }
    }
    @Test func disconnectAfterTurnWriteIsUnknownAndCannotRetry() async {
        let fixture = ChatFixtureConnection(.disconnected); let sender = sender(fixture)
        await #expect(throws: CodexChatSendError.deliveryUnknown) { try await sender.send(threadID: root, text: "test") }
        await #expect(throws: CodexChatSendError.rejected) { try await sender.send(threadID: root, text: "test") }
        #expect(fixture.written.filter { $0["method"] as? String == "turn/start" }.count == 1)
        await sender.stop()
    }
    @Test func matchingServerErrorIsRejected() async {
        let fixture = ChatFixtureConnection(.rejected); let sender = sender(fixture)
        await #expect(throws: CodexChatSendError.rejected) { try await sender.send(threadID: root, text: "test") }
        await sender.stop()
    }
    @Test func unsafeReturnedPolicyNeverStartsTurn() async {
        let fixture = ChatFixtureConnection(.unsafePolicy); let sender = sender(fixture)
        await #expect(throws: CodexChatSendError.sessionUnavailable) { try await sender.send(threadID: root, text: "test") }
        #expect(!fixture.written.contains { $0["method"] as? String == "turn/start" })
        await sender.stop()
    }
    @Test func approvalWaitsForExplicitReplyAndResolvesOnlyItsID() async throws {
        let fixture = ChatFixtureConnection(); let sender = sender(fixture)
        _ = try await sender.send(threadID: root, text: "test")
        fixture.enqueue(["method": "error", "params": ["threadId": ChatFixtureConnection.owned, "willRetry": true]])
        fixture.enqueue(["id": "approval-fixture", "method": "item/commandExecution/requestApproval", "params": ["command": "fixture-command", "threadId": ChatFixtureConnection.owned, "turnId": "turn-3"]])
        var events = sender.events.makeAsyncIterator()
        _ = await events.next()
        guard case .approval(let id, let kind, let summary) = await events.next() else { Issue.record("Missing approval"); await sender.stop(); return }
        #expect(kind == "command"); #expect(summary == "fixture-command")
        try await sender.interrupt()
        #expect(!fixture.written.contains { $0["result"] != nil })
        try await sender.respond(requestID: id, response: .deny)
        let reply = try #require(fixture.written.last)
        #expect(reply["id"] as? String == "approval-fixture")
        #expect((reply["result"] as? [String: String])?["decision"] == "decline")
        await #expect(throws: CodexChatSendError.rejected) { try await sender.respond(requestID: id, response: .approve) }
        await sender.stop()
    }
    @Test func disconnectedApprovalCannotAuthorizeReusedServerRequestID() async throws {
        let first = ChatFixtureConnection(); let second = ChatFixtureConnection()
        let channels = ChatFixtureConnections([first, second])
        let sender = CodexChatSender(factory: { channels.next() }, workingDirectory: { _ in "/fixture" })
        let initial = try await sender.send(threadID: root, text: "first")
        var events = sender.events.makeAsyncIterator()
        _ = await events.next()
        first.enqueue(["id": 91, "method": "item/commandExecution/requestApproval", "params": ["threadId": initial.threadID, "turnId": initial.turnID, "command": "first-command"]])
        guard case .approval(let staleID, _, _) = await events.next() else { Issue.record("Missing approval"); await sender.stop(); return }
        first.close()
        #expect(await events.next() == .requestResolved(id: staleID))
        #expect(await events.next() == .failure(.unavailable))
        let resumed = try await sender.send(threadID: root, text: "second")
        _ = await events.next()
        second.enqueue(["id": 91, "method": "item/commandExecution/requestApproval", "params": ["threadId": resumed.threadID, "turnId": resumed.turnID, "command": "second-command"]])
        guard case .approval(let currentID, _, _) = await events.next() else { Issue.record("Missing new approval"); await sender.stop(); return }
        #expect(currentID != staleID)
        await #expect(throws: CodexChatSendError.rejected) { try await sender.respond(requestID: staleID, response: .approve) }
        #expect(!second.written.contains { $0["result"] != nil })
        try await sender.respond(requestID: currentID, response: .deny)
        await sender.stop()
    }
    @Test func customHomeIsValidatedWithoutPassingOtherEnvironment() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: home) }
        let executable = ClaudeCodeExecutable(path: "/fixture/codex", realPath: "/fixture/codex", directory: "/fixture")
        let environment = try CodexChatEnvironment.child(app: ["CODEX_HOME": home.path, "OPENAI_API_KEY": "fixture-secret"], executable: executable)
        let canonicalHome = try #require(ExternalSessionFileSystem.live.realpath(home.path))
        #expect(environment["CODEX_HOME"] == canonicalHome)
        #expect(environment["OPENAI_API_KEY"] == nil)
        #expect(throws: CodexChatSendError.unavailable) { try CodexChatEnvironment.child(app: ["CODEX_HOME": "relative"], executable: executable) }
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: home.path)
        #expect(throws: CodexChatSendError.unavailable) { try CodexChatEnvironment.child(app: ["CODEX_HOME": home.path], executable: executable) }
    }
    @Test func shortJSONLArrivesBeforeServerClosesOrFillsReadBuffer() async throws {
        let output = Pipe()
        let connection = CodexStdioConnection(output: output)
        let finished = DispatchSemaphore(value: 0)
        let result = Task.detached {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
                DispatchQueue.global().async {
                    do { continuation.resume(returning: try connection.read()) }
                    catch { continuation.resume(throwing: error) }
                    finished.signal()
                }
            }
        }
        try output.fileHandleForWriting.write(contentsOf: Data("{\"id\":1}\n".utf8))
        let deliveredWhileOpen = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: finished.wait(timeout: .now() + 2) == .success)
            }
        }
        // Always release a broken filling read too, so a regression fails rather than hangs.
        try output.fileHandleForWriting.close()
        #expect(deliveredWhileOpen)
        #expect(try await result.value == Data("{\"id\":1}".utf8))
        connection.close()
    }
    @Test func compactionProgressIsScopedAndClearedWhenTurnEnds() async throws {
        let fixture = ChatFixtureConnection(); let sender = sender(fixture)
        let receipt = try await sender.send(threadID: root, text: "test")
        var events = sender.events.makeAsyncIterator()
        #expect(await events.next() == .managedThread(receipt.threadID))
        fixture.enqueue(["method": "item/started", "params": ["threadId": root, "item": ["type": "contextCompaction"]]])
        fixture.enqueue(["method": "item/started", "params": ["threadId": receipt.threadID, "item": ["type": "contextCompaction"]]])
        #expect(await events.next() == .contextCompaction(true))
        fixture.enqueue(["method": "turn/completed", "params": ["threadId": receipt.threadID, "turn": ["id": receipt.turnID, "status": "completed"]]])
        #expect(await events.next() == .contextCompaction(false))
        #expect(await events.next() == .turnCompleted(threadID: receipt.threadID, turnID: receipt.turnID))
        await sender.stop()
    }
    @Test func interruptTargetsOnlyManagedTurn() async throws {
        let fixture = ChatFixtureConnection(); let sender = sender(fixture)
        let receipt = try await sender.send(threadID: root, text: "test")
        try await sender.interrupt()
        let params = try #require(fixture.written.last?["params"] as? [String: String])
        #expect(params == ["threadId": receipt.threadID, "turnId": receipt.turnID])
        await sender.stop()
    }
}
#endif
