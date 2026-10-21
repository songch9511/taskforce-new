#if os(macOS) && DEBUG
import Darwin
import Foundation
import Testing
@testable import TaskforceKit

/// 데스크톱 세션 레일 · 대화 읽기 시험의 공용 도구 (PR-D1 Kit). **사용자의 실제 세션은 열지 않는다**: 등록 파일 · 기록 · 경로 · 이메일은 모두 여기서 만든 가짜다.
/// 시험 글(sentinel)은 어느 출력에도 나오면 안 되는 것들이다
enum ClaudeAppFixture {
    typealias F = ExternalSessionFixture

    /// 열면 안 되는 기록 종류에 심은 값 (`attachment`의 session_context · credential_org · prompt_snapshot, `api-request-blob`)
    static let emailSentinel = "sentinel.person@example-org.test"
    static let orgSentinel = "org-00000000-SENTINEL-ORG-ID"
    static let systemPromptSentinel = "SENTINEL-SYSTEM-PROMPT-TEXT"
    static let snapshotSentinel = "SENTINEL-PROMPT-SNAPSHOT-TEXT"
    /// 대화로 해석하지 않는 줄의 글
    static let thinkingSentinel = "SENTINEL-THINKING-TEXT"
    static let wrapperSentinel = "SENTINEL-QUEUED-WRAPPER-TEXT"
    static let taskNotificationSentinel = "SENTINEL-TASK-NOTIFICATION"
    static let metaSentinel = "SENTINEL-META-REMINDER"
    static let sidechainSentinel = "SENTINEL-SIDECHAIN-TEXT"
    static let otherSessionSentinel = "SENTINEL-OTHER-SESSION-TEXT"
    /// 도구의 본문: 접힌 줄에는 나오면 안 되고, 펼칠 때만(`detail`) 나온다
    static let commandSentinel = "SENTINEL-TOOL-COMMAND-BODY"
    static let resultSentinel = "SENTINEL-TOOL-RESULT-BODY"
    /// 등록 파일 · `claude agents --json`의 폴더 · 이름: 값으로 남기지 않는다
    static let cwdSentinel = "SENTINEL-CWD-PATH"
    static let nameSentinel = "SENTINEL-SESSION-NAME"

    /// 어느 쪽에서도 결과에 나오면 안 되는 글
    static let neverShown = [
        emailSentinel, orgSentinel, systemPromptSentinel, snapshotSentinel, thinkingSentinel, wrapperSentinel, taskNotificationSentinel, metaSentinel, sidechainSentinel,
        otherSessionSentinel,
    ]
    static let toolBodies = [commandSentinel, resultSentinel]

    /// 데스크톱 앱이 띄운 `claude`의 등록 파일 (이 Mac에서 본 키 그대로, 값은 가짜). `nil` 값은 그 키를 쓰지 않는다
    static func registry(
        pid: Int, id: String, cwd: String = "/Users/tester/\(cwdSentinel)", status: String? = "idle", waitingFor: String? = nil, statusUpdatedAt: Any? = 1_800_000_000_000,
        procStart: Any? = nil, entrypoint: String? = "claude-desktop", kind: String? = "interactive"
    ) -> String {
        var object: [String: Any] = ["pid": pid, "sessionId": id, "cwd": cwd, "version": "2.1.306", "name": nameSentinel, "updatedAt": 1_800_000_000_000]
        if let status { object["status"] = status }
        if let waitingFor { object["waitingFor"] = waitingFor }
        if let statusUpdatedAt { object["statusUpdatedAt"] = statusUpdatedAt }
        if let procStart { object["procStart"] = procStart }
        if let entrypoint { object["entrypoint"] = entrypoint }
        if let kind { object["kind"] = kind }
        return F.json(object)
    }

    static func facts(lookups: [Int32: ExternalSessionProcessFacts.Lookup], uid: UInt32 = 501) -> ExternalSessionProcessFacts {
        ExternalSessionProcessFacts(userID: uid, lookup: { lookups[$0] ?? .gone }, argumentSessionIDs: { _ in [] }, unregisteredClaudeFolders: { _, _ in [] })
    }

    /// `claude agents --json`의 한 항목 (실제 키: `pid cwd kind startedAt sessionId name status`, 멈춘 세션은 `waitingFor`). 폴더 · 이름은 가짜 글자다
    static func agentsJSON(_ items: [(pid: Int, id: String, status: String?, waitingFor: String?)]) -> Data {
        let objects: [[String: Any]] = items.map { item in
            var object: [String: Any] = ["pid": item.pid, "cwd": "/Users/tester/\(cwdSentinel)", "kind": "interactive", "startedAt": 1_799_990_000_000, "sessionId": item.id, "name": nameSentinel]
            if let status = item.status { object["status"] = status }
            if let waitingFor = item.waitingFor { object["waitingFor"] = waitingFor }
            return object
        }
        return (try? JSONSerialization.data(withJSONObject: objects, options: [.sortedKeys])) ?? Data()
    }
}

/// 손으로 흘리는 시계 (읽기 쉬운 값 하나)
final class ClaudeAppClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) { current = start }

    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
    func set(_ date: Date) { lock.withLock { current = date } }
}

/// `claude agents --json`를 대신하는 가짜 실행기: 부른 횟수를 세고, 정해 둔 답을 주고, 돌고 있는 동안 세상을 바꾸거나 붙잡힐 수 있다
final class ClaudeAppAgentsStub: @unchecked Sendable {
    private let lock = NSLock()
    private var answer: [ClaudeAgentsItem]?
    private var count = 0
    private var during: (@Sendable () -> Void)?
    private var gate: CheckedContinuation<Void, Never>?
    private var holdNext = false
    private var holding = false
    private var entered = false

    init(_ answer: [ClaudeAgentsItem]? = []) { self.answer = answer }

    var calls: Int { lock.withLock { count } }
    func set(_ items: [ClaudeAgentsItem]?) { lock.withLock { answer = items } }
    func onRun(_ body: @escaping @Sendable () -> Void) { lock.withLock { during = body } }
    /// 다음 호출 **하나**를 `release()`까지 붙잡는다 (그 사이 들어오는 다른 호출은 붙잡지 않는다: 잘못된 코드가 두 번째를 띄워도 시험이 멈추지 않고 횟수로 드러난다)
    func hold() { lock.withLock { holdNext = true } }
    var isHolding: Bool { lock.withLock { entered } }
    func release() {
        let waiting: CheckedContinuation<Void, Never>? = lock.withLock {
            holding = false
            defer { gate = nil }
            return gate
        }
        waiting?.resume()
    }

    var runner: @Sendable () async -> [ClaudeAgentsItem]? {
        { [self] in
            let (body, mustHold): ((@Sendable () -> Void)?, Bool) = lock.withLock {
                count += 1
                let hold = holdNext
                if hold {
                    holdNext = false
                    holding = true
                }
                return (during, hold)
            }
            body?()
            if mustHold {
                lock.withLock { entered = true }
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    let resumeNow: Bool = lock.withLock {
                        if holding {
                            gate = continuation
                            return false
                        }
                        return true
                    }
                    if resumeNow { continuation.resume() }
                }
                lock.withLock { entered = false }
            }
            return lock.withLock { answer }
        }
    }
}

/// 이 시험들이 쓰는 기록 파일 줄 만들기 (실제 줄 키를 줄인 것)
enum ClaudeAppLine {
    typealias F = ExternalSessionFixture

    static func user(id: String, text: String, timestamp: String = "2026-10-22T01:00:01.000Z") -> String {
        F.json(["type": "user", "sessionId": id, "uuid": UUID().uuidString.lowercased(), "timestamp": timestamp, "message": ["role": "user", "content": text], "isSidechain": false])
    }

    static func assistant(id: String, text: String, timestamp: String = "2026-10-22T01:00:02.000Z") -> String {
        F.json([
            "type": "assistant", "sessionId": id, "uuid": UUID().uuidString.lowercased(), "timestamp": timestamp, "isSidechain": false,
            "message": ["role": "assistant", "content": [["type": "text", "text": text]]],
        ])
    }

    static func tool(id: String, toolID: String, name: String, input: [String: Any]) -> String {
        F.json([
            "type": "assistant", "sessionId": id, "uuid": UUID().uuidString.lowercased(), "timestamp": "2026-10-22T01:00:03.000Z", "isSidechain": false,
            "message": ["role": "assistant", "content": [["type": "tool_use", "id": toolID, "name": name, "input": input]]],
        ])
    }

    static func toolResult(id: String, toolID: String, text: String) -> String {
        F.json([
            "type": "user", "sessionId": id, "uuid": UUID().uuidString.lowercased(), "timestamp": "2026-10-22T01:00:04.000Z", "isSidechain": false,
            "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": toolID, "content": text]]],
        ])
    }
}
#endif
