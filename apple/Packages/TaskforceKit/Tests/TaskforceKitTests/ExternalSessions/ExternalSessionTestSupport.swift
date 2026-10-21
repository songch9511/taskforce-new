#if os(macOS) && DEBUG
import Darwin
import Foundation
@testable import TaskforceKit

/// 외부 세션 시험의 가짜 홈 (임시 폴더 안의 `.claude`). **사용자의 실제 기록은 열지 않는다**: 모든 줄 · 제목 · 경로는 여기서 만든 가짜다.
/// 폴더는 시험이 끝나면 지운다 (`ExternalSessionTestSupport.withHome`)
/// 외부 세션 시험은 모두 이 부모 아래에서 한 번에 하나씩 돈다: 임시 폴더 · 프로세스 · 파일 수백 개를 쓰는 시험이 전체 시험이 느린 기계에서 다른 시간 민감 시험(3초 래치 등)을 굶기지 않게
@Suite(.serialized) enum ExternalSessionSuites {}

final class ExternalHome: @unchecked Sendable {
    let root: String
    /// 가짜 `$HOME` (realpath)
    let home: String
    var claude: String { home + "/.claude" }
    var projects: String { claude + "/projects" }
    var sessions: String { claude + "/sessions" }

    init() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("tf-ext-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = GateFileSystem.realpath(base.path) ?? base.path
        home = root + "/home"
        try FileManager.default.createDirectory(atPath: projects, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: sessions, withIntermediateDirectories: true)
    }

    func cleanup() { try? FileManager.default.removeItem(atPath: root) }

    func directory(_ name: String) throws -> String {
        let path = projects + "/" + name
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    /// `projects/<디렉터리>/<id>.jsonl`을 만든다 (줄은 이미 JSON 글). 수정 시각을 정할 수 있다
    @discardableResult
    func transcript(directory: String, id: String, lines: [String], modified: Date? = nil, pad: Int = 0) throws -> String {
        let dir = try self.directory(directory)
        let path = dir + "/" + id + ".jsonl"
        var text = lines.joined(separator: "\n") + "\n"
        if pad > 0 { text += String(repeating: "x", count: pad) }
        try text.write(toFile: path, atomically: false, encoding: .utf8)
        if let modified { try setModified(path, modified) }
        return path
    }

    func setModified(_ path: String, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
    }

    func registry(pid: Int, json: String) throws {
        try json.write(toFile: sessions + "/\(pid).json", atomically: false, encoding: .utf8)
    }

    func link(_ path: String, to target: String) throws {
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target)
    }
}

enum ExternalSessionFixture {
    static let userSentinel = "SENTINEL-USER-PROMPT-TEXT"
    static let assistantSentinel = "SENTINEL-ASSISTANT-REPLY-TEXT"
    static let lastPromptSentinel = "SENTINEL-LAST-PROMPT-TEXT"
    static let sentinels = [userSentinel, assistantSentinel, lastPromptSentinel]

    static func uuid(_ n: Int) -> String { String(format: "5e5e5e5e-0000-4000-8000-%012x", n) }

    static func json(_ object: [String: Any]) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data(), as: UTF8.self)
    }

    /// 대화 줄 (사용자 글 · 어시스턴트 글): 머리 정보 칸(sessionId · cwd · entrypoint · version)도 같이 든다 (실제 기록 줄 키, OB-4)
    static func user(id: String, cwd: String?, entrypoint: String? = "cli", version: String? = "2.1.304", text: String = userSentinel) -> String {
        var object: [String: Any] = ["type": "user", "sessionId": id, "message": ["role": "user", "content": text], "timestamp": "2026-10-21T09:00:00.000Z"]
        if let cwd { object["cwd"] = cwd }
        if let entrypoint { object["entrypoint"] = entrypoint }
        if let version { object["version"] = version }
        return json(object)
    }

    static func assistant(id: String, text: String = assistantSentinel) -> String {
        json(["type": "assistant", "sessionId": id, "message": ["role": "assistant", "content": [["type": "text", "text": text]]]])
    }

    static func lastPrompt(id: String, text: String = lastPromptSentinel) -> String { json(["type": "last-prompt", "sessionId": id, "lastPrompt": text]) }
    static func customTitle(id: String?, _ title: String) -> String { json(["type": "custom-title", "customTitle": title].merging(id.map { ["sessionId": $0] } ?? [:]) { $1 }) }
    static func agentName(id: String?, _ name: String) -> String { json(["type": "agent-name", "agentName": name].merging(id.map { ["sessionId": $0] } ?? [:]) { $1 }) }
}

/// 파일 시스템 호출을 기록하는 감싸기 (T8 허용 목록 · T3 읽은 바이트)
final class RecordingFileSystem: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var listed: [String] = []
    /// 나열 호출마다 (경로, 요청한 상한, 돌려준 항목 수)
    private(set) var listCalls: [(path: String, limit: Int, returned: Int)] = []
    private(set) var statted: [String] = []
    private(set) var resolved: [String] = []
    private(set) var reads: [(path: String, offset: Int64, length: Int, returned: Int)] = []
    let base: ExternalSessionFileSystem

    init(_ base: ExternalSessionFileSystem = .live) { self.base = base }

    var fileSystem: ExternalSessionFileSystem {
        ExternalSessionFileSystem(
            userID: base.userID,
            realpath: { [self] path in
                lock.lock()
                resolved.append(path)
                lock.unlock()
                return base.realpath(path)
            },
            lstat: { [self] path in
                lock.lock()
                statted.append(path)
                lock.unlock()
                return base.lstat(path)
            },
            list: { [self] path, limit in
                let result = base.list(path, limit)
                var returned = 0
                if case .entries(let items) = result { returned = items.count }
                lock.lock()
                listed.append(path)
                listCalls.append((path, limit, returned))
                lock.unlock()
                return result
            },
            read: { [self] path, offset, length in
                let data = base.read(path, offset, length)
                lock.lock()
                reads.append((path, offset, length, data?.count ?? 0))
                lock.unlock()
                return data
            }
        )
    }

    var bytesRead: Int { reads.reduce(0) { $0 + $1.returned } }
}

/// 로그를 모으는 싱크 (이벤트 이름과 값 종류만 남는다: 글 · 경로 · id를 넣을 자리가 없다)
final class RecordingLog: BridgeLogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(event: String, fields: [String: BridgeLogValue])] = []

    var events: [(event: String, fields: [String: BridgeLogValue])] { lock.withLock { recorded } }

    func log(_ event: String, _ fields: [String: BridgeLogValue]) { lock.withLock { recorded.append((event, fields)) } }
}

/// 화면에 찍힐 수 있는 모든 글(설명 · 필드)에 시험 글(sentinel)이 없다
func expectNoSentinel(in value: Any, _ comment: Comment? = nil, sourceLocation: SourceLocation = #_sourceLocation) {
    var dump = ""
    Swift.dump(value, to: &dump)
    let text = dump + String(describing: value) + String(reflecting: value)
    for sentinel in ExternalSessionFixture.sentinels { #expect(!text.contains(sentinel), comment, sourceLocation: sourceLocation) }
}

import Testing

extension Result {
    var isFailure: Bool {
        if case .failure = self { true } else { false }
    }
}
#endif
