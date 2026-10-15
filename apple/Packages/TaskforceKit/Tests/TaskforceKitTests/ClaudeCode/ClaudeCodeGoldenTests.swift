#if os(macOS)
import Foundation
import Testing
@testable import TaskforceKit

/// 서버 쪽 시험이 읽는 골든 (OA D3a 계약 4.5): S0 stream-json을 매퍼에 먹이고, 런타임이 사건을 봉투에 싣는 것과 같은 방식(번호 · 자르기 · 질문 상한)으로
/// D2a 사건 JSON을 만든다. `Fixtures/bridge-v1/claude-code-events.json`과 같아야 한다 (서버 `swift-fixtures.test.ts`가 zod로, `tests/db/claude-code-s0-events.test.ts`가 PGlite로 적용한다).
/// 파일을 다시 만들려면 `TF_WRITE_CLAUDE_GOLDEN=1 swift test --filter ClaudeCodeGoldenTests`
struct ClaudeCodeGoldenTests {
    static let session = ClaudeTest.session
    static let task = ClaudeTest.task
    static let externalTask = "0e09f680-f476-4f2e-96d9-670f24599f6d:1"
    static let start = Date(timeIntervalSince1970: 1_791_866_343)

    struct Sequence {
        let name: String
        let events: [AgentEvent]
        let firstSeq: Int
    }

    static func mapped(
        _ fixture: String, mode: ClaudeMapperConfig.Mode, pending: ClaudePendingDeferred? = nil, extraAnswered: [String: String] = [:], interruptRequested: Bool = false
    ) throws -> [AgentEvent] {
        let lines = try ClaudeTest.fixture(fixture)
        var facts = ClaudeSpawnFacts()
        facts.toolNames = ClaudeTest.toolUses(in: lines).merging(extraAnswered) { first, _ in first }
        facts.answered = Set(facts.toolNames.keys)
        facts.pending = pending
        var mapper = ClaudeEventMapper(config: ClaudeMapperConfig(
            mode: mode, expectedSessionID: nil, expectedTools: nil, expectedCwd: nil, requireSessionStart: false, workspaceRealPath: "/Users/u/proj",
            versionSupported: { ClaudeCodeSupport.supports($0) }
        ))
        if interruptRequested { mapper.markInterruptRequested() }
        var actions: [ClaudeMapperAction] = []
        var now = start
        for line in lines {
            now = now.addingTimeInterval(0.1)
            if let event = ClaudeStreamParser.parse(line) { actions += mapper.consume(event, facts: facts, now: now) }
        }
        actions += mapper.finish()
        return actions.compactMap { if case .emit(let event) = $0 { event } else { nil } }
    }

    static func colorQuestion(_ id: String) -> ClaudePendingDeferred {
        let question = AgentQuestion(providerRequestID: id, kind: .input, structured: true, text: "Which color?", items: [
            AgentQuestionItem(id: "color", header: "Color", text: "Which color?", options: [AgentQuestionOption(label: "red", description: ""), AgentQuestionOption(label: "blue", description: "")]),
        ])
        return ClaudePendingDeferred(id: id, kind: .input, inputSHA256: "d", toolName: "mcp__tf__ask_user", question: question)
    }

    static func sequences() throws -> [Sequence] {
        let approval = ClaudeToolGate.approvalQuestion(id: "toolu_01RT8MqssFmM3xiqAbQwBWp5", tool: "Write", relPath: "b.txt", command: nil)
        return [
            Sequence(name: "trivial_turn", events: try mapped("r2-lt1-trivial-1", mode: .turn(newSessionID: "2c4bde0f-3c30-4976-80df-ce1603668f72")), firstSeq: 1),
            Sequence(name: "ask_turn", events: try mapped("r3-cc11-1-tools-allowlist-mcp", mode: .turn(newSessionID: "0e09f680-f476-4f2e-96d9-670f24599f6d"),
                                                          pending: colorQuestion("toolu_01BHLsvBzENgVdhX2qSAFRSm")), firstSeq: 1),
            // 답 resume (ask_turn 다음): 보류 id에 답을 준 순간 `.progress`(결정기가 낸다), 그 뒤 stream. ask_turn이 seq 1–3을 썼다
            Sequence(name: "answer_resume", events: [.progress] + (try mapped("r3-cc9-3-resume-deny-stale-question", mode: .answer(requestID: "toolu_015m7x9cBb7pQSBmH54iJqch"),
                                                                                extraAnswered: ["toolu_015m7x9cBb7pQSBmH54iJqch": "mcp__tf__ask_user"])), firstSeq: 4),
            Sequence(name: "approval_turn", events: try mapped("r3-cc9-1-two-deferred-writes", mode: .turn(newSessionID: nil),
                                                               pending: ClaudePendingDeferred(id: approval.providerRequestID, kind: .approval, inputSHA256: "d", toolName: "Write", question: approval)), firstSeq: 1),
            Sequence(name: "sign_in_needed", events: try mapped("r2-cc8-empty-home-after-login", mode: .turn(newSessionID: nil)), firstSeq: 1),
            Sequence(name: "cancelled", events: try mapped("r2-cc4-sigint-sleep", mode: .turn(newSessionID: nil), interruptRequested: true), firstSeq: 1),
        ]
    }

    /// 런타임 `handleAdapterEvent` · `appendTaskEvent`와 같은 봉투: task 사건은 `<task>:<seq>`, `session_bound`는 세션 번호 `<session>:s<n>`(seq · 외부 작업 id 없음).
    /// `inputReached`(로컬 전용) · `ended`(서버 사건 아님)는 싣지 않는다
    static func encode(_ sequence: Sequence) throws -> [Any] {
        var seq = sequence.firstSeq - 1
        var sessionNumber = 0
        var observed = start
        var out: [Any] = []
        for event in sequence.events {
            observed = observed.addingTimeInterval(1)
            let body: BridgeV1Event.Body
            switch event {
            case .inputReached, .ended: continue
            case .sessionBound(let external, let workspace): body = .sessionBound(externalSessionID: external, workspaceRef: workspace)
            case .accepted: body = .accepted
            case .progress: body = .progress
            case .message(let text): body = .message(text: Outbox.fit(text: text).sent)
            case .question(let question):
                guard case .fits(let fitted, _) = Outbox.fit(question: question, taskID: task, observedAt: observed) else { throw CocoaError(.coderInvalidValue) }
                body = .question(text: Outbox.fit(text: question.text).sent, fitted)
            case .artifact(let path, let hash, let summary): body = .artifact(path: path, hash: hash, summary: summary)
            case .turnCompleted: body = .turnCompleted
            case .failed(let reason): body = .failed(reason)
            case .cancelled: body = .cancelled
            }
            let sessionLevel: Bool
            if case .sessionBound = body { sessionLevel = true } else { sessionLevel = false }
            let eventID: String
            let number: Int?
            if sessionLevel {
                sessionNumber += 1
                eventID = "\(session):s\(sessionNumber)"
                number = nil
            } else {
                seq += 1
                eventID = "\(task):\(seq)"
                number = seq
            }
            let envelope = BridgeV1Event(adapter: "agent:claude-code", sessionID: session, taskID: task, externalTaskID: sessionLevel ? nil : externalTask, eventID: eventID,
                                         seq: number, turnSeq: 1, observedAt: observed, body: body)
            out.append(try JSONSerialization.jsonObject(with: TaskforceJSON.encoder().encode(envelope)))
        }
        return out
    }

    static func golden() throws -> [String: Any] {
        var byName: [String: Any] = [:]
        for sequence in try sequences() { byName[sequence.name] = try encode(sequence) }
        return [
            "note": "Generated by ClaudeCodeGoldenTests from Fixtures/claude-code-2.1.241 (S0). Placeholder ids: session \(session), task \(task).",
            "session_id": session, "task_id": task, "sequences": byName,
        ]
    }

    static var fileURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Fixtures/bridge-v1/claude-code-events.json")
    }

    @Test func theGoldenEventsMatchTheCheckedInFixture() throws {
        let generated = try Self.golden()
        if ProcessInfo.processInfo.environment["TF_WRITE_CLAUDE_GOLDEN"] == "1" {
            var data = try JSONSerialization.data(withJSONObject: generated, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            data.append(0x0A)
            try data.write(to: Self.fileURL)
        }
        let url = try #require(Bundle.module.url(forResource: "bridge-v1/claude-code-events", withExtension: "json"))
        let stored = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? NSDictionary)
        #expect(stored == generated as NSDictionary)
    }

    @Test func theSequencesTellTheExpectedStory() throws {
        let all = Dictionary(uniqueKeysWithValues: try Self.sequences().map { ($0.name, $0.events.filter { $0 != .inputReached }) })
        #expect(all["trivial_turn"] == [.sessionBound(externalSessionID: "2c4bde0f-3c30-4976-80df-ce1603668f72", workspaceRef: "/Users/u/proj"), .accepted, .message(text: "OK"), .turnCompleted])
        #expect(all["ask_turn"]?.last == .question(Self.colorQuestion("toolu_01BHLsvBzENgVdhX2qSAFRSm").question))
        #expect(all["answer_resume"]?.last == .turnCompleted)
        #expect(all["approval_turn"]?.last.map { if case .question(let q) = $0 { q.kind == .approval } else { false } } == true)
        #expect(all["sign_in_needed"] == [.failed(.signInNeeded)])
        #expect(all["cancelled"]?.last == .cancelled)
    }

    /// `claude-code-adapter.json`: 서버 registry와 대조할 Mac 상수 (TS가 `AGENT_REGISTRY["agent:claude-code"].version_range`와 비교한다)
    @Test func theAdapterFixtureCarriesTheMacConstants() throws {
        let url = try #require(Bundle.module.url(forResource: "bridge-v1/claude-code-adapter", withExtension: "json"))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(object["adapter"] as? String == ClaudeCodeSupport.adapterID)
        #expect(object["version_range"] as? String == ClaudeCodeSupport.versionRange)
        #expect(object["tools_write"] as? [String] == ClaudeCodeSupport.tools(for: .write))
        #expect(object["tools_read_only"] as? [String] == ClaudeCodeSupport.tools(for: .readOnly))
        #expect(object["cancel_scope"] as? String == "turn_and_processes")
        // 재구성하는 명령 이름 = 서버 `COMMAND_FLAGS` 키 (TS가 같은 파일로 서버 목록과 대조한다, 8장 3)
        #expect(object["readonly_commands"] as? [String] == CommandRebuild.allowedCommands)
    }
}
#endif
