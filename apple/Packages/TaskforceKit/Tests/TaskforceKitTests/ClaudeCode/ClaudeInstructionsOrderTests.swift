#if os(macOS) && DEBUG
import Foundation
import Synchronization
import Testing
import TaskforceAgentWire
@testable import TaskforceKit

/// 프로젝트 지침(CLAUDE.md) 읽기는 막힐 수 있는 일이라 **세션이 비었는지 보기 전에** 끝낸다 (검토 P1): 비었다고 본 뒤 등록까지 await가 끼면
/// 같은 세션에 writer가 둘 생기고(닫기 + 턴), 그 틈에 `forgetSession`이 방금 심은 비밀값 가리개를 지운다. 읽기를 hook으로 늦춰 그 틈을 연다
@Suite(.serialized)
struct ClaudeInstructionsOrderTests {
    static let secret = "CANARY-SECRET-7f3a1c"

    @Test func aSlowReadCannotLetACloseAndATurnRunAtTheSameTimeOnOneSession() async throws {
        let calls = Mutex<Int>(0)
        let hooks = ClaudeCodeTestHooks(beforeInstructionsRead: {
            let n = calls.withLock { count -> Int in
                count += 1
                return count
            }
            // 1번째 = 첫 턴(빠름), 2번째 = 닫기(느림), 3번째 = 다음 턴(빠름)
            if n == 2 { try? await Task.sleep(for: .milliseconds(400)) }
        })
        let fake = try FakeClaude(hooks: hooks)
        fake.box.file("CLAUDE.md", "Rule A")
        try fake.scenario(["runs": [
            ["steps": [["tool": "mcp__tf__ask_user", "id": "toolu_q", "input": FakeClaude.askColor]]],
            ["final_text": "next", "linger_after_result": 0.8],
            [:],
        ]])
        let first = EventLog()
        let identity = try await fake.turn(events: first)
        #expect(await first.wait { FakeClaude.ended($0) })
        let session = FakeClaude.providerSession(identity)
        let ref = AgentRequestRef(taskID: ClaudeTest.task, sessionID: ClaudeTest.session, requestID: "toolu_q", externalSessionID: session, workspaceRef: fake.workspace)
        let process = fake.process
        let close = Task { try await process.closeRequest(ref) }
        // 닫기가 읽기를 시작한 뒤에 다음 턴을 부른다
        for _ in 0..<200 where calls.withLock({ $0 }) < 2 { try await Task.sleep(for: .milliseconds(5)) }
        let second = EventLog()
        let next = Task { _ = try? await fake.turn("Next", task: "7a5c0001-0000-4000-8000-000000000002", external: session, events: second) }
        #expect(await second.wait(timeout: 60) { FakeClaude.ended($0) })
        try await close.value
        await next.value
        let reports = (1...2).compactMap { fake.report($0) }
        let closeRun = try #require(reports.first { $0["stdin_bytes"] as? Int == 0 })
        let turnRun = try #require(reports.first { ($0["stdin_bytes"] as? Int ?? 0) > 0 })
        let closeStarted = try #require(closeRun["started_at"] as? Double)
        let closeEnded = try #require(closeRun["ended_at"] as? Double)
        let turnStarted = try #require(turnRun["started_at"] as? Double)
        let turnEnded = try #require(turnRun["ended_at"] as? Double)
        #expect(closeStarted >= turnEnded || turnStarted >= closeEnded, "두 실행의 구간이 겹치지 않는다 (writer 하나)")
    }

    @Test func aSlowReadCannotLetForgetSessionClearTheRedactorOfAnAnswerThatIsAboutToLaunch() async throws {
        let holder = Mutex<ClaudeCodeProcess?>(nil)
        let calls = Mutex<Int>(0)
        let hooks = ClaudeCodeTestHooks(beforeInstructionsRead: {
            let n = calls.withLock { count -> Int in
                count += 1
                return count
            }
            // 2번째 = 답 resume: 읽는 틈에 세션을 잊게 한다
            if n == 2 {
                await holder.withLock({ $0 })?.forgetSession(ClaudeTest.session)
                try? await Task.sleep(for: .milliseconds(150))
            }
        })
        let fake = try FakeClaude(hooks: hooks)
        holder.withLock { $0 = fake.process }
        fake.box.file("CLAUDE.md", "Rule A")
        try fake.scenario(["runs": [
            ["steps": [["tool": "mcp__tf__ask_user", "id": "toolu_secret", "input": ["questions": [["id": "key", "header": "Key", "text": "Paste the API key", "secret": true]]]]]],
            ["final_text": "Your key \(Self.secret) is set."],
        ]])
        let first = EventLog()
        let identity = try await fake.turn(events: first)
        #expect(await first.wait { FakeClaude.ended($0) })
        let answered = EventLog()
        let result = try await fake.answer("toolu_secret", kind: .input, value: AgentAnswerValue(text: Self.secret), external: FakeClaude.providerSession(identity), events: answered)
        guard case .delivered = result else {
            Issue.record("\(result)")
            return
        }
        #expect(await answered.wait { FakeClaude.ended($0) })
        let messages = answered.all.compactMap { event -> String? in if case .message(let text) = event { text } else { nil } }
        #expect(messages.contains { $0.contains("[redacted]") }, "되말한 비밀값은 가려서 나간다")
        #expect(!messages.contains { $0.contains(Self.secret) }, "가리개가 읽는 틈에 지워지지 않았다")
    }
}
#endif
