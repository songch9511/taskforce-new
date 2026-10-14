#if os(macOS)
import Foundation
@testable import TaskforceKit

/// 시험이 만든 임시 폴더. 실사용 Application Support · 설정 · Keychain은 건드리지 않는다 (계약 0.3-7)
final class TempDirectory: @unchecked Sendable {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory.appending(path: "bridge-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func appending(_ path: String) -> URL { url.appending(path: path) }
}

enum BridgeTest {
    /// 밀리초가 정확한 기준 시각 (원장은 밀리초 정수로 적는다)
    static let t0 = Date(timeIntervalSince1970: 1_760_400_000)

    static func command(
        _ id: String = "c0000000-0000-4000-8000-000000000001", kind: String = "message", session: String = "5e551011-0000-4000-8000-000000000001",
        task: String = "7a5c0001-0000-4000-8000-000000000001", turn: Int = 1, cursor: Int = 1, state: BridgeCommandState = .seen, at: Date = t0
    ) -> BridgeCommandRecord {
        BridgeCommandRecord(commandID: id, kind: kind, agentSessionID: session, agentTaskID: task, turnSeq: turn, cursor: cursor, state: state, stateAt: at)
    }

    static func task(
        _ id: String = "7a5c0001-0000-4000-8000-000000000001", session: String = "5e551011-0000-4000-8000-000000000001",
        adapter: String = "agent:claude-code", turn: Int = 1, at: Date = t0
    ) -> BridgeTaskRecord {
        BridgeTaskRecord(agentTaskID: id, agentSessionID: session, adapter: adapter, turnSeq: turn, updatedAt: at)
    }

    /// 원장 시험용 사건 만들기: 번호가 들어간 가짜 JSON
    static func build(
        type: String = "message", text: String? = nil, full: String? = nil, at: Date = t0
    ) -> @Sendable (Int?, String) throws -> BuiltEvent {
        { seq, eventID in
            BuiltEvent(
                type: type, json: "{\"event_id\":\"\(eventID)\",\"seq\":\(seq.map(String.init) ?? "null"),\"text\":\"\(text ?? "")\"}", observedAt: at,
                fullText: full
            )
        }
    }

    /// 파일 바이트(DB · WAL · SHM)에 글이 있는지 (비밀값 · 사용자 메시지 글이 디스크에 남지 않는다는 감시)
    static func diskBytesContain(_ needle: String, in directory: URL) -> Bool {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let target = Data(needle.utf8)
        for file in files {
            guard let data = try? Data(contentsOf: file) else { continue }
            if data.range(of: target) != nil { return true }
        }
        return false
    }
}
#endif
